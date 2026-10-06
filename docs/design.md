# Design

Two scripts and a page. `router/wgc.sh` is the engine: it owns the tunnels, the routing rules and the firewall rules. `router/wgcui.sh` installs a page into the Merlin web UI and runs the actions the page sends. `router/wgcui.asp` is the page. The page never does anything `wgc.sh` can't do from SSH, and `wgc.sh` knows nothing about the page.

## What the engine owns

Everything is numbered off two bases, `WGC_TABLE_BASE` (120) and `WGC_PRIO_BASE` (B, 11300). For tunnel N:

| Thing | Value | N = 1 with defaults |
|---|---|---|
| interface | `wgcN` | `wgc1` |
| routing table | `WGC_TABLE_BASE + N` | 121 |
| shared rule, one for all tunnels | priority B | 11300 |
| endpoint rule | priority B + N | 11301 |
| rules from the `rules` file, in file order | B + 100*N ... B + 100*N + 98 | 11400-11498 |
| iptables | 8 rules, each with `-i wgcN` or `-o wgcN` | |

The bases can be changed from the environment, but `check_settings` refuses any value that would put a priority outside 11300-11899 or a table outside 121-125. `WGC_LAN_IF` must look like an interface name (`[a-z][a-z0-9]`, at most 15 characters) and may not be `lo` or start with `wgc`.

The whole range sits after VPN Director, whose rules end at 11209. If a Director rule and a tunnel rule both match, the Director rule wins.

The main table and its default route are never touched. Every `ip route` the script runs carries `table 12N`. That is also why a tunnel without rules carries nothing: no rule points into its table.

### The shared rule

```
ip -4 rule add from all lookup main suppress_prefixlength 0 priority 11300
```

This looks up the main table but ignores its default route. Anything with a more specific route in main (the LAN, the OpenVPN server subnet, the WAN subnet) is resolved there before any tunnel rule is consulted. Only traffic that would have gone out the default route falls through to the tunnel rules. There is one such rule for all tunnels; `start` adds it if it is missing and `stop` removes it only when no `wgc1`..`wgc5` interface is left. `start` checks for it twice, once before the endpoint rule and again right before the tunnel rules.

### The endpoint pin

```
ip -4 rule add to <endpoint ip> lookup main priority 11300+N
```

With `AllowedIPs = 0.0.0.0/0` the tunnel's table has a default route. Without this rule the encrypted packets to the peer could match a tunnel rule and be routed into the tunnel they belong to. The endpoint IP comes from `wg show wgcN endpoints` after `wg setconf`, so a host name in the conf works: `wg` has already resolved it. If `wg` reports anything other than one `IPv4:port`, `start` fails and rolls back.

### Tunnel rules and `iif br0`

```
ip -4 rule add iif br0 [from S] [to D] lookup 12N priority P
```

`iif` is the first selector of every tunnel rule. Only packets that arrive from the LAN bridge can match, so traffic that the router itself originates (SSH replies, the web UI, DNS forwarding, NTP, the OpenVPN clients) never enters a tunnel. Three things follow from that:

- `wgc1 any any` is allowed and means every device on the LAN, for everything the tunnel carries.
- A source equal to the router's own LAN address is refused, since it could never match anyway and only makes sense as a mistake.
- A source must lie entirely inside the LAN and a destination may not overlap the LAN in either direction.

The table of a tunnel holds only the IPv4 networks from `AllowedIPs`. A rule with destination `any` on a split-tunnel conf therefore carries only those networks; everything else misses in the table and continues down the rule list to the normal path.

### The eight iptables rules

```
raw    PREROUTING  -i wgcN -s <LAN network> -j DROP
filter INPUT       -i wgcN -m state --state NEW,INVALID -j DROP
filter FORWARD     -i wgcN -m state --state NEW,INVALID -j DROP
mangle FORWARD     -o wgcN -j MARK --set-xmark 0x01/0x7
mangle PREROUTING  -i wgcN -j MARK --set-xmark 0x01/0x7
nat    POSTROUTING -o wgcN -j MASQUERADE
mangle FORWARD     -o wgcN -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
mangle FORWARD     -i wgcN -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```

Each one is added with `iptables -C` first and `-I` only when the check fails, so a repeated `start` never duplicates them.

The tunnel is treated as an untrusted network, the same way the firmware treats its OpenVPN clients (chains `OVPNCI` and `OVPNCF`). The three DROP rules say so explicitly instead of relying on the order of the firmware's chains:

- `raw PREROUTING`: a packet from the tunnel with a LAN source address is dropped before conntrack and before DNAT. On 386.14_2 `rp_filter` is 0 and port forwards create DNAT rules without `-i`, so nothing else would stop it.
- `filter INPUT` and `filter FORWARD`: new and invalid connections from the tunnel to the router or the LAN are dropped. `-I` puts them at the top, in front of the firmware's `--ctstate DNAT -j ACCEPT`.

The script never adds an `ACCEPT`. LAN to tunnel is already allowed by the firmware's `-A FORWARD -i br0 -j ACCEPT`, and replies by `RELATED,ESTABLISHED`.

The two MARK rules are there for the Broadcom flow cache. Without them a tunnel gets a handshake, passes a few packets after each one and then stalls. With `fc disable` everything works, but that turns off acceleration for the whole router. Marking the tunnel's packets in mangle is enough to keep the flow cache away from them and acceleration stays on for everything else. The rules are the ones ZebMcKayhan/WireguardManager uses (`wg_client`, lines 445-446). The stock 386.14_2 firewall has no MARK rules at all, so the low three bits are free; another add-on that marks packets could conflict. Measurements are in [notes.md](notes.md).

MASQUERADE makes LAN traffic leave with the tunnel address. The two TCPMSS rules clamp the MSS in both directions to the tunnel MTU.

All five rules that guard and mark (`raw`, `input`, `forward`, `markout`, `markin`) are in place before `ip link set ... up`. If any of them cannot be added, the interface never comes up.

## `start N`

All validation runs first: the LAN network of `WGC_LAN_IF`, the whole `rules` file, and every targeted conf. Any error is exit 2 before a single changing command. Then, under the lock:

```
modprobe wireguard
ip link show dev wgcN
    missing: ip link add dev wgcN type wireguard ; wg setconf  wgcN <tmp>
    present:                                       wg syncconf wgcN <tmp> ; drop stale addresses and routes
iptables: raw, input, forward, markout, markin      (-C, then -I when missing)
ip -4 address replace <ip>/32 dev wgcN
ip link set dev wgcN mtu <mtu> up
ip -4 route replace <cidr|default> dev wgcN table 12N      (each IPv4 AllowedIPs entry)
wg show wgcN endpoints
shared rule B unless present
ip -4 rule del priority B+N (loop) ; ip -4 rule add to <endpoint> lookup main priority B+N
ip -4 rule del table 12N (loop) ; shared rule check again ; ip -4 rule add iif br0 ... lookup 12N priority P (each line)
iptables: masq, mssout, mssin                       (-C, then -I when missing)
```

`wg syncconf` on an existing interface keeps the session up, which matters because `firewall-start` runs `start all` on every firewall restart. After `syncconf`, any address on the interface that is not the new one and any route in the table that is not in the new `AllowedIPs` is deleted, so a changed conf leaves nothing behind. The "delete until it fails" loops are bounded at 200.

A failure at any step after `modprobe` runs `stop N` and exits 1. Other tunnels are not touched. `start all` carries on with the next tunnel and returns 1 at the end if any failed. Messages go to stdout and to `logger -t wgc`.

### Secrets

`PrivateKey` and `PresharedKey` never appear in argv, stdout, stderr or syslog. The conf is read by awk, which writes the copy for `wg` straight to a temp file: `$WGC_RUN_DIR/.wgcN.<32 hex>`, created under `umask 077` with noclobber (`set -C`), so it never overwrites an existing file or follows a symlink. That copy leaves out the wg-quick-only keys (`Address`, `DNS`, `MTU`, `Table`, the hooks, `SaveConfig`). It is removed on every exit, and `stop N` removes any `.wgcN.*` leftovers. `wg` may quote offending conf lines in its errors, so its stderr is thrown away and only its exit code is reported.

Random values come from `dd if=/dev/urandom bs=16 count=1 | md5sum | cut -c1-32`, because the router has no `mktemp` and no `od`.

## `stop N`

`stop` reads neither the conf nor `rules`, so it works even when they are broken or gone.

```
ip -4 rule del table 12N            (loop)
ip -4 rule del priority B+N         (loop)
iptables purge over six chains
ip link del dev wgcN                (the table's routes go with it)
ip -4 rule del priority B           (loop, only if no wgc1..wgc5 is left)
remove .wgcN.* temp files
verify
```

The iptables purge does not depend on `-C` or on knowing the LAN network. For each of `raw PREROUTING`, `filter INPUT`, `filter FORWARD`, `nat POSTROUTING`, `mangle FORWARD` and `mangle PREROUTING` it lists the chain with `iptables -S`, picks every `-A` line in which `wgcN` is the value of `-i` or `-o` and every character is from `[A-Za-z0-9_.,:/+ -]`, and deletes it with `-D` and the same rule specification. At most 50 deletions per chain per pass, and passes repeat until one deletes nothing, at most 10. This also removes duplicates and rules written with an older LAN network. Because the rules are deleted by the rule specification `iptables -S` prints, the `0x1/0x7` spelling of the MARK rules is not a problem.

The verification uses the same filter: the interface must be gone, `ip -4 rule show` may have no `lookup 12N` and no priority B+N, and no chain may still list a rule for `wgcN`. If anything is left, or a listing fails, `stop` says what and exits 1. `stop` on nothing exits 0. `stop` ignores SIGHUP, so a dropped SSH session can't cut it short. It deletes `wgc.pending` only after a complete stop that covers the pending target.

## `status N`

Prints `wg show wgcN`, the routes in table 12N, the rules for the tunnel and one line per iptables rule (`raw input forward markout markin masq mssout mssin`, each `present` or `MISSING`). Exit 0 needs the interface up, the shared rule, the endpoint rule, all eight iptables rules and a handshake no older than `WGC_HANDSHAKE_MAX` (180 s). Anything missing on an up interface prints `wgcN: DEGRADED - interface up but missing: ...` and exits 1. All present but the handshake is stale, or `0` (never): exit 3.

## `try` and `confirm`

`try` is `start` with a dead man's switch. The order:

1. Refuse (exit 2) unless the script runs from a readable file that contains its own header line, because the timer re-runs that file. Piped through stdin, it can't.
2. Take the lock and validate everything.
3. If a `try` for a different target is pending, refuse with exit 2.
4. Start the timer: `sh wgc.sh __watchdog <token> <target> <seconds> <pid>`, detached, with HUP, INT and TERM already ignored when it is born.
5. The timer creates `.wd.<token>`. `try` waits for that file; if it does not appear, the timer is killed and `try` exits 1 with nothing changed.
6. `wgc.pending` (`<token> <target>`) is replaced atomically: a new noclobber file, then `mv -f` over the old one. Never delete-then-create. Only now is an earlier pending `try` replaced, so a failure in the steps above leaves it armed.
7. `try` removes `.wd.<token>`. That is the commit: the timer only starts counting once it sees the file gone and its token in `wgc.pending`.
8. `start`. On failure or a signal, `try` kills the timer, stops the whole target, removes `wgc.pending` and exits 1.

The timer sleeps, then checks that `wgc.pending` still holds its token. If not, someone ran `confirm` or a newer `try`, and it exits quietly. Otherwise it takes the lock (forcing it after 300 tries), runs `stop` on the target up to three times, 5 s apart, and logs the outcome; on a final failure the log line says to run `wgc.sh stop N`.

`confirm` deletes `wgc.pending`. Exit 0 even when there was nothing pending.

## Locking

`start`, `stop`, `try` and `confirm` hold `$WGC_RUN_DIR/lock`, a directory created with `mkdir` (atomic) with a `pid` file inside. `check` and `status` don't lock.

- Busy lock: retry once a second, up to 60 times. If the pid in the lock is not alive (`kill -0`), the lock is stale and is taken over by renaming it to `lock.dead.<pid>` and removing that. Only one racer can win the rename; the others go back to `mkdir`.
- `start`, `try` and `confirm` give up after the wait with exit 1, nothing changed, and a message with the exact recovery command (`rm -rf <path to lock>`).
- `stop` and the `try` timer never give up. After the wait they force the lock with a warning in syslog. Before forcing, they read `/proc/<pid>/cmdline` of the holder; if it is a live `wgc.sh`, `stop` waits up to 10 minutes in total. The timer waits 300 tries.
- If `lock` exists but is not a directory, `stop` and the timer remove it and go on.
- The lock is released on every exit, signals included.

## Run directory

`WGC_RUN_DIR` defaults to `/tmp/wgc.run`. It is created with mode 700 if missing. If it is a symlink or not a directory, the command exits 1 with no changes. It holds the lock, `wgc.pending`, the `wg` temp files and the `try` handshake files (`.wd.*`, `.pending.*`). `stop` clears those handshake files unless a `try` for another target still needs them. It all lives in RAM and is gone after a reboot; the `firewall-start` hook starts the tunnels again from the confs.

## Parsing the conf

The conf is parsed by awk (`CONF_AWK`), never sourced. Keys are matched case-insensitively, `#` starts a comment, `\r` at line end is dropped.

- Exactly one `[Interface]` and one `[Peer]`. An unknown section, a key outside a section or a duplicate key is an error.
- `PrivateKey`, `PublicKey` and `PresharedKey` must be 44 base64 characters ending in `=`.
- `Address`: exactly one IPv4 address must remain after IPv6 entries are skipped. It is installed as `/32` whatever prefix the conf gives, so no route to the tunnel subnet appears in main. First octet 0, 127 or 224 and up, or an address inside the LAN, is refused.
- `AllowedIPs`: IPv4 CIDRs without host bits, at most 64. IPv6 entries are syntax-checked and dropped from the routes.
- `Endpoint`: `host:port`, split at the last colon. Host is a valid IPv4 address or a host name of at most 253 characters; port 1-65535.
- `MTU` 1280-1500, default 1420. `ListenPort` 1-65535. `PersistentKeepalive` a number or `off`.
- `DNS`, `Table`, `PreUp`, `PostUp`, `PreDown`, `PostDown`, `SaveConfig` are accepted and ignored. Any other key is an error.

Numbers must be canonical decimals (no leading zeros, no sign, no hex). Both the conf and `rules` are refused if they are not regular files, are larger than 65536 bytes or contain a byte other than tab, CR, LF or 0x20-0x7E. The awk code checks the size and bytes again while reading, in case the file changed after the shell check. Every value that reaches `ip` or `iptables` argv goes through one more check (`argsafe`: digits, dots and slashes only, not starting with `-`).

The CIDR arithmetic is done in awk with doubles; IPv4 values stay below 2^32 and are exact. There is no shell arithmetic over 31 bits.

## Web page

### Pieces

| Project file | On the router | Role |
|---|---|---|
| `router/wgcui.sh` | `/jffs/addons/wgc/wgcui.sh` (700) | `install`, `enable-events`, `set-level`, `mount`, `status`, `service_event`, `uninstall` |
| `router/wgcui.asp` | `/jffs/addons/wgc/wgcui.asp`, copied to `/www/user/userN.asp` | the page |
| | `/www/user/wgc/status.js` | data for the page, written by the handler, served as `/ext/wgc/status.js` |

### Installing into the menu

This follows the Merlin add-on API, the same way other add-ons such as uiDivStats do it.

- Slot: for `user1.asp` .. `user20.asp`, a slot is ours if its md5 equals that of `wgcui.asp`, or if it contains the marker `<!-- wgcui-page -->` and its `.title` file holds our title. Otherwise the first free slot is used. No free slot is exit 1.
- Under `flock` on `/tmp/addonwebui.lock` (the lock all add-ons share): copy the page, write `userN.title` ("WireGuard Client"), copy `/www/require/modules/menuTree.js` to `/tmp/menuTree.js` if there is no copy yet, insert our menu line after the line for `Advanced_VPNClient_Content.asp` (fallback: after `Advanced_SwitchCtrl_Content.asp`), then `umount` and `mount -o bind` the copy over the original. Our menu line is found and removed by our title only, so another add-on's line is never touched.
- `mkdir /www/user/wgc` and a first `status.js`.
- `/jffs/scripts/post-mount` gets `/jffs/addons/wgc/wgcui.sh mount >/dev/null 2>&1 & # wgc`, after a copy to `post-mount.bak`. `/www/user` is on tmpfs, so after a reboot `mount` puts the page, the menu entry and a first `status.js` back.
- If `install` fails halfway, it takes back only what that run added. An existing menu line of ours stays.

`enable-events` adds one line to `/jffs/scripts/service-event`, after a copy to `service-event.bak`:

```
if [ "$2" = "wgcui" ]; then /jffs/addons/wgc/wgcui.sh service_event "$@" & fi # wgc
```

The match on the name is exact. A substring match (`grep -q`) as some add-ons use it would also fire for other names that contain ours.

Both script lines are idempotent: our old lines are removed before the new one is added, other lines keep their bytes and the file keeps its inode and mode. `uninstall` strips our lines from both files, removes the menu line and remounts, deletes the slot's page and title, the web directory, the `wgcui_*` settings and `wgcui.level`. It does not touch `firewall-start`, `wgc.sh`, the confs or `rules`. The `.bak` files are kept on purpose, so install plus uninstall is not byte-identical in the `/jffs/addons/wgc` directory.

### From button to result

1. The page builds one JSON object: all settings of the other add-ons plus its own `wgcui_*` keys. It puts the JSON into the hidden form field `amng_custom`.
2. It posts the hidden fields of the form with `fetch` (same origin, `application/x-www-form-urlencoded`) to `/start_apply.htm`, with `action_script=start_wgcui`, `action_mode=apply`, `action_wait=5`.
3. The firmware replaces `/jffs/addons/custom_settings.txt` with the contents of `amng_custom`, one `key value` line per key, and calls `service-event start wgcui`.
4. The `service-event` line starts `wgcui.sh service_event start wgcui` in the background.
5. The handler takes its own lock, reads its keys, deletes every `wgcui_*` line from the settings file, validates, writes `status.js` with `pending:true`, runs the action, writes `status.js` with `pending:false` and releases the lock.
6. The page reloads `/ext/wgc/status.js` (a `<script>` element with a cache-busting query) once a second until `pending` is false and `generated` has changed, or 30 s have passed. After 30 s it shows "no answer from the router, check with SSH: wgc.sh status all".

The action travels in a key (`wgcui_action`), not in `action_script`. That keeps one `service-event` line with an exact match and one validation path for every action.

### Settings keys

| Key | Value |
|---|---|
| `wgcui_action` | `refresh`, `check`, `saverules` (level `ro` and up); `start`, `stop`, `try`, `confirm`, `saveconf`, `deleteconf` (level `full`) |
| `wgcui_target` | `1`..`5` or `all`; `saveconf` and `deleteconf` take `1`..`5` only |
| `wgcui_seconds` | for `try`: 10-3600, two to four digits, no leading zero |
| `wgcui_conf` | encoded conf text for `saveconf` |
| `wgcui_rules` | encoded rules text for `saverules` |
| `wgcui_len` | byte length of the encoded `wgcui_conf` or `wgcui_rules` value as sent |

The handler checks all of them before anything is used:

- A duplicate of any key: nothing is done.
- Values are read with `grep '^key ' | cut -d' ' -f2-`, at most 64 characters for the short keys.
- The action picks a fixed `case` branch. There is no `eval` and no command is built from text. An unknown action is reported as "unknown action".
- `wgcui_conf` and `wgcui_rules` never go into a shell variable. They go file to file (`grep | cut > raw`, byte check, awk decode > tmp) under `umask 077`.
- The raw value may only hold TAB, LF, CR and 0x20-0x7E. After decoding, a conf may be at most 4096 bytes and rules at most 8192 bytes, with the same byte set. `wgc.sh` checks the contents again.
- `wgcui_len` must equal the stored length of the encoded value. A truncated settings file therefore gives "length mismatch ... settings truncated?" instead of a conf cut in half.
- If the settings file is a symlink, the handler refuses to work and says so in `status.js`.
- Deleting the keys rewrites the file only if it has `wgcui_*` lines; otherwise it stays untouched (inode and mtime). Other lines stay byte for byte.

### Encoding

A setting is one line, so the values need line breaks encoded. The page replaces `%` with `%25`, `|` with `%7C` and LF with `%0A`, and drops CR. The handler decodes exactly those three codes in one left-to-right pass with awk. Anything else, `%41` or a bare `%`, stays literal. The `||||` separator some other add-ons use breaks on values that start or end with `|`.

### Saving a conf or rules

`saveconf N` and `saverules` swap the new file in with a way back:

1. Copy the current file to `<file>.prev` (if there is one).
2. Write the marker `$WGC_DIR/.inprogress` with the file name.
3. `mv -f` the new file into place, mode 600.
4. `wgc.sh check N` (or `check all` for rules).
5. On success delete `.prev` and the marker. On failure put `.prev` back (or delete the new file if the slot was empty) and report the error from `check`.

If the handler is killed between steps 3 and 5, the next handler run finds the marker when it takes the lock and restores `.prev` for exactly that file. Without the marker a `.prev` file is left alone, and a `.prev` over 65536 bytes is never restored automatically.

`saverules` at level `full` then runs `wgc.sh start N` for each tunnel whose interface exists, never `start all`. Saving rules must not bring up a tunnel that was stopped. `deleteconf N` runs `wgc.sh stop N` and deletes `wgcN.conf` only if the stop succeeded.

### Handler lock and busy

The handler locks with `mkdir $WGC_RUN_DIR/uilock` and a pid inside, separate from the `wgc.sh` lock. A stale lock (dead pid) is taken over by atomic rename, as in `wgc.sh`. If the lock is held by a live process, the second action is not run: its keys are deleted and `status.js` gets `busy:true`, but only while the current `status.js` still says `pending:true`. Otherwise the busy note could overwrite the result of the action that was running.

### `status.js`

One assignment, `var wgcui = {...};`, with valid JSON inside. Every string goes through one escape function: `\` and `"` are escaped, `<` and `>` become `\u003c` and `\u003e`, and anything outside 0x20-0x7E is removed.

```
version           "1"
generated         epoch seconds
pending           true while an action runs
busy              true if this action was refused because another one was running
last              { action, target, rc, message, when }   message: output of wgc.sh, up to 200 lines
tunnels[5]        { conf, state, handshake_age, missing[], exit_ip, exit_ip_age, rx, tx, endpoint, pubkey, check_error }
pending_try       { target, seconds } or null
rules[]           { tunnel, src, dst, enabled, name, desc }
rules_skipped     number of lines in rules the page can't show
devices[]         { ip, name, mac }
foreign_settings  { key: value } for every non-wgcui_ line of the settings file
log[]             last 20 syslog lines with " wgc: " or "wgc-", up to 200 characters
http_warning      true
```

Where the fields come from:

- `state`: `noconf` without a conf; otherwise from `wgc.sh status N`. Exit 0 or 3 is `up`, exit 1 with a `DEGRADED` line is `degraded` and `missing` holds the list from that line, anything else is `down`.
- `handshake_age`: from the status line, or from `wg show wgcN latest-handshakes` when the handshake is stale. `null` if there was none.
- `exit_ip`, `exit_ip_age`: the tunnel's public exit address and its age in seconds, from the cache described below. Empty and `null` when the interface does not exist or nothing is cached.
- `rx`, `tx`: `wg show wgcN transfer` when the interface exists, else 0.
- `endpoint`: the live one from `wg show wgcN endpoints` while the tunnel is up, otherwise from the `endpoint` line of `wgc.sh check N`. `pubkey` from the `peer` line of `check`. If `check` fails, `check_error` holds its first line and the page shows it in red.
- `pending_try`: from `wgc.pending`. `seconds` is the total length of the timer, taken from the argv of the running `__watchdog` process, because `wgc.pending` does not record when the `try` started. No such process: `seconds` is `null`.
- `rules`: lines with exactly three fields after the comment is dropped, tunnel `wgc1`..`wgc5`, at most 256. A line starting with `#off ` is read the same way and gets `enabled:false`. A trailing comment is split at the first `:` into `name` and `desc` (no colon: all of it is the name); name at most 40 characters, desc at most 120. Any other comment line is ignored, and other non-empty lines are counted in `rules_skipped`.
- `devices`: from `/var/lib/misc/dnsmasq.leases`. The name is cut down to `[A-Za-z0-9._-]` and 32 characters; at most 256 entries.
- `log`: from the newer of `/tmp/syslog.log` and `/opt/var/log/messages` that exists.

One `refresh` costs five `wgc.sh status` calls plus one `wgc.sh check` per configured slot, plus a STUN lookup for each up tunnel whose cached exit address is missing or stale. While an action runs, the `pending:true` version is written from the cached body of the previous run, without calling `wgc.sh`.

### Exit address

Each tunnel that is up gets its public exit address the way the firmware finds it for its OpenVPN clients: a STUN binding request sent through the tunnel interface.

```
ministun -t 4000 -c 1 -i wgcN stun.l.google.com:19302
```

`WGCUI_STUN_SERVERS` lists the servers tried in order (default `stun.l.google.com:19302 stun.stunprotocol.org`); the first one that answers with an IPv4 address wins. `WGCUI_STUN_TIMEOUT` is the `-t` value in milliseconds (4000). `ministun` is found by walking `PATH` (plus `/usr/sbin`); if it is missing, no lookup happens and the address stays empty.

A successful answer is cached in `$WGC_RUN_DIR/wgcN.exitip` with the time it was taken. The lookup runs:

- after a `start` from the page, for each tunnel that came up;
- on every `refresh`, for each running tunnel.

A failed lookup keeps an older cached value unless it is more than 3600 s old (`WGCUI_EXITIP_DROP`). `stop` and `deleteconf` from the page delete the cache for their target.

The address belongs to the VPN server's NAT. It can change between sessions with the same server, and a refresh only reads the current one again.

### The page

The page follows the layout of the firmware pages: the firmware's stylesheets, `/js/jquery.js` first, then `state.js`, `general.js`, `popup.js`, `help.js`, `tmmenu.js`, `validator.js`, `client_function.js`, and `initial()` calling `show_menu()`. `var custom_settings = <% get_custom_settings(); %>;` gives the page the current settings as a template.

- Data reaches the DOM only through `textContent`, `value` and `createElement`. No `innerHTML` with data, no `eval`, no `document.write`. A device called `<img src=x onerror=...>` shows up as that text.
- The page's own element helper is `byId`, not `$`, so it doesn't shadow jQuery.
- For each post it takes `foreign_settings` from the last `status.js` if there is one, otherwise the `custom_settings` template, drops any `wgcui_*` key from it and adds its own.
- Before posting it checks sizes: the encoded conf or rules value at most 2048 bytes, the whole JSON at most 2900 bytes. Over that it shows "value too large" or "settings too large (N bytes, limit 2900)" and sends nothing.
- Rules are checked for shape only (IPv4 address or CIDR, or `any`). Name and description accept printable ASCII without `#`, and the name no `:`; the handler truncates them to 40 and 120 characters. Whether a rule is allowed is decided by `wgc.sh` on the router.
- The buttons of a row are disabled while an action for that row is pending. A failed POST (HTTP status other than 200) shows "could not reach the router" and enables the buttons again.
- The yellow HTTP warning is shown when `location.protocol` is `http:`.

## Decisions and their reasons

**Tunnel rules match `iif br0` only.** The worst thing this script could do is route the router's own traffic into a tunnel: SSH and the web UI would go with it. With `iif` first in every rule that can't happen, whatever the rules file says, and the rules file checks can stay simple.

**Rules sit after VPN Director.** Priorities 11300-11899 come after the Director's range, which ends at 11209. The existing OpenVPN setup keeps working exactly as before, and wins on overlap.

**No ACCEPT rules.** The firmware already allows LAN to anywhere and established replies. Adding only DROPs means a mistake in this script can make the router stricter but never more open.

**Mark instead of disabling the flow cache.** `fc disable` fixes the stall too, but for the whole router. Two MARK rules per tunnel fix it for the tunnel only.

**`start` is idempotent.** `firewall-start` runs on every firewall restart, and the firmware restarts the firewall when it feels like it. `syncconf` on an existing interface and `-C` before every `-I` make a repeated `start` cheap and harmless.

**`stop` relies on nothing.** It needs no conf, no `rules`, no run files and no `-C`. A broken conf or a reboot in the middle must never leave rules that nothing can remove.

**The `firewall-start` line runs in the foreground.** `iptables` 1.4.15 in the firmware predates the `-w` lock, so running `wgc.sh` in parallel with the other lines of `firewall-start` could make concurrent `iptables` calls collide. Whether that actually loses rules was not tested.

**`saverules` only re-applies on running tunnels.** At level `full` it originally ran `wgc.sh start all` after a successful check. That brought up a tunnel that had not been running, and a device started using the VPN just because its rules were saved. Now it runs `start N` only where `ip link show dev wgcN` succeeds and says which tunnels it touched.

**Auto-refresh is off by default.** Every refresh is a post: the firmware rewrites `custom_settings.txt` on JFFS, racing any other add-on that writes it, and the handler makes up to ten `wgc.sh` calls. A 10 s refresh was too much. The checkbox gives one refresh every 30 s while the page is open and visible.

**The page posts with `fetch`, not with the form.** A form submit to `start_apply.htm` into the hidden frame makes the firmware reload the whole page after `action_wait` seconds, losing everything on it. The same request through `fetch` is processed by the firmware the same way and the page stays put.

**The page posts every add-on's settings.** `start_apply.htm` replaces the whole settings file with `amng_custom`. Posting only our keys deletes the settings of every other add-on.

**The page and handler limit sizes far below what `wgc.sh` accepts.** The firmware truncates the settings file at about 3 KB without saying so and empties it above about 8 KB. 2900 bytes leaves some room for the other add-ons, and `wgcui_len` catches a truncation that happens anyway.

**`/js/jquery.js` is loaded first.** The firmware's `state.js` pulls in `httpApi.js` and `asus_policy.js` on every page, and `httpApi` needs jQuery. Without it `PolicyStatus()` throws, the EULA flag stays `"0"`, `checkPolicy()` builds an invisible policy modal and its constructor sets `body.style.overflow = "hidden"`. The page then can't be scrolled.

**A level file instead of a setting.** `ro`/`full` lives in `/jffs/addons/wgc/wgcui.level`, written by `wgcui.sh set-level`, so it can only be changed over SSH. The page can't raise its own level. `ro` is the level for trying the page out: it can save and check rules but can't start anything.

**No Try button.** A trial run is something to do over SSH with the timer as a safety net. The page still shows a pending `try` as `wgcN is on a trial run (max N s)` and offers `Keep it`, which sends `confirm`.

**The exit address comes from STUN, not from a web service.** The firmware already does it this way for its OpenVPN clients, `ministun` is on the router, and nothing outside the VPN provider and a public STUN server learns that the tunnel exists.
