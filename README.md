# wgc.sh: WireGuard clients for Asuswrt-Merlin

`wgc.sh` runs up to five WireGuard client tunnels (`wgc1`..`wgc5`) on an Asuswrt-Merlin 386.x router and decides, per LAN device and/or per destination, which traffic goes through which tunnel. You give it standard wg-quick conf files and one small `rules` file; it sets up the interfaces, the policy routing and the firewall rules, and removes all of it again on `stop`. An optional page in the router's web UI lets you upload confs, edit rules and start or stop tunnels without SSH.

It is a single POSIX shell script. It uses the WireGuard module and `wg` tool that the firmware already ships, installs nothing with `opkg`, and does not touch `nvram`, VPN Director or the OpenVPN clients. There is no kill switch, DNS is not redirected and there is no IPv6 (see [Limitations](#limitations)).

How it works inside is in [docs/design.md](docs/design.md). Findings about the firmware that may help other Merlin developers are in [docs/notes.md](docs/notes.md). If you want to change the code, read [docs/development.md](docs/development.md).

## How this compares

**WireGuard Manager (wgm).** Written by Martineau and continued in a fork by ZebMcKayhan; installed through amtm and needs Entware. It downloads its own build of the kernel module for the RT-AC86U (its `getmodules` command). Its client script adds the same two MARK rules this project uses (in `wg_client`: `-t mangle -I FORWARD -o … -j MARK --set-xmark 0x01/0x7` and `-I PREROUTING -i …`), and its main script also turns the Broadcom flow cache off outright (`fc disable` in `wg_manager.sh`). It has its own web page, peer import and policy routing. The main script is over 200 KB; the last commit on the fork I saw is from September 2024. This project uses only the module and `wg` that ship in the firmware, needs no Entware, leaves the flow cache on and relies on the MARK rules alone (measured at line speed, see [Measured results](#measured-results)), and is about 1300 lines of shell with a test suite.

**wireguard-go from Entware.** Several published setup scripts use it. It runs WireGuard in userspace over a TUN device, so the tunnel only exists once the USB drive is mounted, and it is slower than the kernel module. I have not measured it here.

**Hand-written scripts from the forums** (`insmod`, `ip link add`, `wg setconf`, a few `iptables` lines). The same idea as the engine here, usually for one tunnel, without per-device rules, without inbound lock-down, without a removal that restores the previous state, and without tests.

**The native WireGuard client in Asuswrt-Merlin 388.x.** The right answer on routers that get 388. It is not available on 386-only models such as the RT-AC86U, and that is the gap this project fills.

Compared with the alternatives on 386, this project adds per-device and per-destination rules in the style of VPN Director, explicit inbound DROP rules per tunnel, `try` with automatic revert, a `stop` that verifies it left nothing behind, a web page that posts only validated keys and never executes text it receives, and tests that run under BusyBox 1.25.1. It lacks IPv6, DNS through the tunnel, a kill switch, server mode, key generation and QR codes.

## Requirements

- Asuswrt-Merlin 386.x on an HND model whose firmware ships the WireGuard kernel module and the `wg` tool. Check over SSH:

  ```
  find /lib/modules -name wireguard.ko
  which wg
  ```

  Both must print a path. The script has been tested only on an RT-AC86U with 386.14_2 (`wireguard.ko` 1.0.20210124, `wg` 1.0.20200827).
- SSH access and JFFS custom scripts enabled (Administration, System, "Enable JFFS custom scripts and configs" = Yes).
- The LAN on the bridge `br0`. The script reads your LAN network from `br0` itself; another interface can be set with `WGC_LAN_IF`.
- For the web page only: a USB drive. Merlin runs `/jffs/scripts/post-mount` when a USB partition is mounted, and that is where the page puts itself back into the menu after a reboot. Without a USB drive the tunnels still work and the page still installs, but after every reboot you have to run `sh /jffs/addons/wgc/wgcui.sh mount` yourself to get the page back.

## Installation

The examples assume your router is at 192.168.1.1, your LAN is 192.168.1.0/24 and you log in over SSH as `admin`. Replace them with your own values.

### 1. Take backups

Before changing anything, save the router settings (Administration, Restore/Save/Upload Setting, Save setting) and a copy of `/jffs`:

```
ssh admin@192.168.1.1 'tar czf - -C /jffs .' > jffs-backup.tar.gz
```

### 2. Copy the script

From the directory of this repository:

```
ssh admin@192.168.1.1 'mkdir -p /jffs/addons/wgc && chmod 700 /jffs/addons/wgc'
ssh admin@192.168.1.1 'cat > /jffs/addons/wgc/wgc.sh' < router/wgc.sh
ssh admin@192.168.1.1 'chmod 700 /jffs/addons/wgc/wgc.sh'
```

### 3. Add a conf

Each tunnel N (1 to 5) reads `/jffs/addons/wgc/wgcN.conf`. Use the conf your VPN provider or your own WireGuard server gives you, unchanged:

```
ssh admin@192.168.1.1 'cat > /jffs/addons/wgc/wgc1.conf && chmod 600 /jffs/addons/wgc/wgc1.conf' < provider.conf
```

What is used from it and what is ignored is described in [Conf files](#conf-files).

### 4. Write the rules

Create `/jffs/addons/wgc/rules` (mode 600) and say which traffic goes into the tunnel, for example one device:

```
wgc1  192.168.1.50  any
```

The format is described in [The rules file](#the-rules-file). Without rules a tunnel comes up but carries nothing.

### 5. Check, try, confirm

```
/jffs/addons/wgc/wgc.sh check            # validates conf and rules, changes nothing
/jffs/addons/wgc/wgc.sh try 1 300        # start tunnel 1, stop it again after 300 s
/jffs/addons/wgc/wgc.sh status 1         # exit 0: up, protected, recent handshake
/jffs/addons/wgc/wgc.sh confirm          # keep it running
```

`try` exists because a mistake in routing can cut you off from the router. It starts the tunnel and arms a timer; if you don't run `confirm` within the given time, the timer runs `stop` and everything the script created is gone. If your SSH session dies, the router repairs itself. Test from the device in your rules (visit a "what is my IP" page, run a speed test), make sure you can still reach the router, and only then `confirm`.

After `confirm` the tunnel stays up until the next reboot.

### 6. Start at boot

Everything the script creates (interface, routes, rules, firewall rules) lives in RAM and is gone after a reboot. The firmware runs `/jffs/scripts/firewall-start` at boot and every time it rebuilds the firewall, and one line there brings the tunnels back. If the file does not exist yet, create it:

```
[ -f /jffs/scripts/firewall-start ] || { printf '#!/bin/sh\n' > /jffs/scripts/firewall-start; chmod 755 /jffs/scripts/firewall-start; }
echo '/jffs/addons/wgc/wgc.sh start all >/dev/null 2>&1 # wgc' >> /jffs/scripts/firewall-start
```

Keep the line in the foreground (no `&`). The router's `iptables` 1.4.15 has no `-w` lock, so `wgc.sh` should not run at the same time as other scripts that change the firewall.

I add this line only after a tunnel has been confirmed. Until then a reboot is a clean way back.

After a reboot:

```
/jffs/addons/wgc/wgc.sh status all      # 0 for every tunnel
iptables-save | grep -c wgc             # 8 per tunnel
```

### 7. The web page (optional)

```
ssh admin@192.168.1.1 'cat > /jffs/addons/wgc/wgcui.sh && chmod 700 /jffs/addons/wgc/wgcui.sh' < router/wgcui.sh
ssh admin@192.168.1.1 'cat > /jffs/addons/wgc/wgcui.asp' < router/wgcui.asp
```

Then on the router:

```
sh /jffs/addons/wgc/wgcui.sh install
sh /jffs/addons/wgc/wgcui.sh enable-events
sh /jffs/addons/wgc/wgcui.sh set-level full
```

The files must be in `/jffs/addons/wgc/`; the lines added to `/jffs/scripts` use that path.

- `install` copies the page into a free user page slot (`/www/user/userN.asp`), adds "WireGuard Client" to the VPN menu, and adds one line ending in `# wgc` to `/jffs/scripts/post-mount` so the page comes back after a reboot (see Requirements about the USB drive).
- `enable-events` adds one line to `/jffs/scripts/service-event`. Through it the firmware hands the page's actions to `wgcui.sh`. Without it the page shows status only after `install` and its buttons get no answer.
- `set-level full` allows the page to start and stop tunnels and to upload and delete confs. See [Levels](#levels).

Reload the web UI to see the menu entry.

The tools also create a few files of their own: `wgc.sh` keeps its lock and timer state in `/tmp/wgc.run` (RAM only), `wgcui.sh` writes the page data `status.js` into a web directory next to the page, and `.bak` copies of `post-mount` and `service-event` are kept in `/jffs/addons/wgc/` before a line is added to them.

## Conf files

`wgcN.conf` is a normal wg-quick file, as exported by most VPN providers or by your own server. Keys are case-insensitive, `#` starts a comment, Windows line ends are fine.

Used:

- `[Interface]`: `PrivateKey` (required), `Address` (required), `MTU` (default 1420, allowed 1280-1500), `ListenPort`.
- `[Peer]`: `PublicKey`, `AllowedIPs` and `Endpoint` (required), `PresharedKey`, `PersistentKeepalive`.

Ignored: `DNS`, `Table`, `PreUp`, `PostUp`, `PreDown`, `PostDown`, `SaveConfig`, and IPv6 entries in `Address` and `AllowedIPs`.

Any other key is an error. A conf must have exactly one `[Interface]` and exactly one `[Peer]`.

Details:

- One IPv4 address is taken from `Address` and always set as `/32`, whatever prefix the conf gives. An address inside your LAN, or starting with 0, 127 or 224 and above, is refused.
- `AllowedIPs` decides what the tunnel can carry: its IPv4 networks become the routes of the tunnel's own routing table (`0.0.0.0/0` becomes a default route there). At most 64 entries. The main routing table is never changed.
- `Endpoint` is `host:port`; the host may be an IPv4 address or a name.
- A file over 65536 bytes, or with bytes other than printable ASCII, tabs and line ends, is refused.

## The rules file

`/jffs/addons/wgc/rules` holds the rules for all tunnels. A missing file means no rules. Each line has three fields separated by spaces or tabs:

```
<tunnel>  <source>  <destination>
```

- `tunnel` is `wgc1`..`wgc5`.
- `source` is `any`, a LAN address, or a network inside your LAN.
- `destination` is `any`, an IPv4 address or an IPv4 network outside your LAN.

Blank lines and `#` comments (also at the end of a line) are ignored. Examples with a LAN of 192.168.1.0/24:

```
# tunnel  source            destination
wgc1      192.168.1.50      any               # one device, everything the tunnel carries
wgc1      any               198.51.100.0/24   # every device, one destination network
wgc2      192.168.1.51      203.0.113.10      # one device, one destination host
wgc2      192.168.1.64/26   any               # a block of devices
wgc3      any               any               # the whole LAN
```

A comment at the end of a rule can give it a name and a description, written as `name: description`; without a colon the whole comment is the name. The page shows them in the Rules table and writes them back (name up to 40 characters, description up to 120). A line that starts with `#off ` is a rule that is kept but not applied, so you can switch it off without losing it:

```
wgc1 any 203.0.113.10          # Office: route the office host through Germany
#off wgc1 192.168.2.77 any    # TV
```

Any other comment line is ignored, as before.

What a line means depends on the conf as well. Only destinations that the tunnel's `AllowedIPs` covers go into the tunnel; with `any` as destination, a full-tunnel conf (`0.0.0.0/0`) takes all internet traffic of the source, while a conf for a company network only takes that network and everything else goes out normally.

Rules only apply to traffic that comes from the LAN. The router's own traffic (its web UI, SSH, DNS, updates) never goes into a tunnel.

Lines are applied in file order per tunnel. Rules of the firmware's own VPN features are evaluated first and win if they match the same traffic.

Every command that reads the file checks all of it, including lines for other tunnels. One bad line refuses the whole file (exit 2, nothing changed). A line is bad when:

1. the tunnel is not `wgc1`..`wgc5`, there are not exactly three fields, or an address or network is invalid or has host bits set (`192.168.1.5/24`);
2. the source is not `any` and is not entirely inside the LAN;
3. the source is the router's own LAN address;
4. the destination is not `any` and overlaps the LAN;
5. a tunnel has more than 99 rules;
6. the file is over 65536 bytes or has bytes outside printable ASCII.

## Commands

```
usage: wgc.sh check   [N|all]
       wgc.sh start   [N|all]
       wgc.sh stop    [N|all]
       wgc.sh status  [N|all]
       wgc.sh try     [N|all] [seconds]     (seconds 10-3600, default 300)
       wgc.sh confirm
N is 1-5; without N the command applies to all tunnels.
```

That is the output of `wgc.sh help` (also `-h`, `--help`). With no command, an unknown command or N outside 1-5, it goes to stderr with exit 2. For `check`, `start`, `status` and `try`, `all` means every tunnel that has a `wgcN.conf`; for `stop` it means all five.

| Command | What it does | Exit codes |
|---|---|---|
| `check` | validates the confs and `rules`, prints a summary without secrets, changes nothing | 0 ok; 2 error in a file or no conf; 1 LAN network cannot be determined |
| `start` | brings tunnels up and (re)applies their rules; running it again gives the same state | 0; 1 failure (that tunnel fully rolled back); 2 error in a file or no conf, nothing changed |
| `stop` | removes everything created for the tunnel; needs neither conf nor `rules`; verifies the result | 0; 1 something is left or cannot be verified |
| `status` | prints `wg show`, routes, rules and the eight firewall rules | 0, 1 or 3 (below); with several tunnels the worst wins |
| `try` | `start`, then an automatic `stop` after the given seconds unless `confirm` comes first | 0; 1 failure (the target is stopped); 2 bad argument or conf |
| `confirm` | cancels the pending automatic `stop`; says "nothing pending" if there is none | 0; 1 lock busy |

`status`:

- 0: interface up, handshake younger than 180 s (`WGC_HANDSHAKE_MAX`), all routing and firewall rules present.
- 3: everything present, but the handshake is old or there has been none yet.
- 1: interface down, or up with something missing. Then it prints `wgcN: DEGRADED - interface up but missing: ...`.

A few things about `try`: while a `try` for one target is pending, a `try` for another target is refused until you `confirm` or `stop`. The timer survives the SSH session being closed. `try` must be run from the script file, not piped in through stdin, because the timer runs the file again.

Messages also go to the syslog with the tag `wgc`.

## Web page

The page is "WireGuard Client" under VPN in the router menu. Everything it does goes through `wgc.sh`.

Tunnels: one row per slot `wgc1`..`wgc5`.

- **Tunnel**: a coloured dot and the state: `up`, `degraded` (up, but some routing or firewall rule is missing; the missing pieces are listed), `down`, or `empty` when the slot has no conf.
- **Peer**: the endpoint and the first 8 characters of the peer's public key. If the conf fails `check`, the first error is shown here in red.
- **Exit address**: the public address your traffic leaves the VPN with (see below).
- **Handshake** and **Traffic**: time since the last handshake, bytes down and up.
- One button per row: `Upload conf` for an empty slot, `Start` when the tunnel is down, `Stop` when it is up or degraded.
- Under a tunnel that is down there is a small `remove conf`. It asks `remove?`; `yes` becomes clickable after 1 s, `no` backs out. It stops the tunnel and deletes its conf; if the stop fails, the conf is kept.
- The result of an action, an error or an OK, appears in a line under its row.

The exit address is looked up the same way the firmware does it for its OpenVPN clients: a STUN request sent through the tunnel with `ministun` (to `stun.l.google.com:19302`, then `stun.stunprotocol.org`). No web service is contacted. It is looked up when you press Start and on Refresh when the remembered value is missing or older than 10 minutes. Stop forgets it. If the firmware has no `ministun`, the address stays empty.

The address is assigned by the VPN server and can differ between sessions, even with the same server. Refreshing only reads the current address again; it doesn't ask for a new one. If your provider hands out different addresses, you get another one only by Stop and Start.

- Rules: one row per rule. Tick the box to enable or disable the rule, give it an optional name and description, pick the tunnel, the device (from the router's DHCP leases, `any (whole LAN)` or `custom…` for an address or network) and a destination. `Apply rules` writes `rules` and checks it with `wgc.sh check all`. If the check fails, the old file is put back and your rows stay on the page so you can fix them. At level `full` the new rules are then applied to the tunnels that are running; stopped tunnels stay stopped. Rules can only be saved once at least one conf exists. Names and descriptions are kept; other comment lines are lost when the page writes the file, and lines the page cannot show are reported as "N invalid line(s) in rules will be dropped by Apply".
- Log: the last 20 syslog lines from `wgc`.
- The page does not refresh by itself. Use Refresh, or tick "Auto-refresh every 30 s" while you watch it.
- There is no Try button. Trial runs belong in SSH, where the timer protects you. A `try` started there shows up on the page as a bar, `wgcN is on a trial run (max N s)`, with a `Keep it` button that does what `wgc.sh confirm` does.

### Levels

The level is set over SSH with `sh /jffs/addons/wgc/wgcui.sh set-level ro|full`; the page itself cannot change it. Until you set it, the level is `ro`.

- `ro`: the page shows status, refreshes, refreshes exit addresses, and can save and check rules. Saving rules never starts or re-applies anything. All other buttons get "action disabled at level ro".
- `full`: also upload and remove confs, Start, Stop and Keep it, and saving rules re-applies them on running tunnels.

`ro` is a safe way to look at the page on a router where you don't want anything started from the browser.

### Warnings

- Merlin serves the web UI over plain HTTP on the LAN unless you turned on HTTPS. An uploaded conf, private key included, crosses your LAN unencrypted then; the page shows a yellow warning on HTTP. The key is deleted from the add-on settings file right after the handler reads it.
- A conf can be at most 2048 bytes through the page, and all add-on settings together at most 2900 bytes. The firmware silently cuts its add-on settings file at about 3 KB and empties it above about 8 KB, so the page refuses bigger requests instead of losing data. Larger confs can still be copied over SSH.
- The page is protected only by the web UI login, like every Merlin add-on page.

## Removal

Web page only:

```
sh /jffs/addons/wgc/wgcui.sh uninstall
```

It removes the page, the menu entry, the `# wgc` lines in `post-mount` and `service-event` and the page's settings. It leaves `wgc.sh`, the confs, `rules` and the `firewall-start` line alone.

Everything:

```
sh /jffs/addons/wgc/wgcui.sh uninstall           # if the page is installed
/jffs/addons/wgc/wgc.sh stop all
sed -i '/# wgc$/d' /jffs/scripts/firewall-start
rm -rf /jffs/addons/wgc
```

After `stop all`, `ip rule`, the main routing table and `iptables` are back to what they were before the first start.

If something goes wrong:

| Situation | Way back |
|---|---|
| a `try` misbehaves | `wgc.sh stop`, wait for the timer, or reboot |
| SSH lost during a `try` | the timer removes everything; if not, power-cycle the router |
| tunnels confirmed but wrong | `wgc.sh stop all`, or reboot if the `firewall-start` line is not there yet |
| the menu looks broken after `install` | `sh /jffs/addons/wgc/wgcui.sh uninstall`, or reboot |
| the router misbehaves at boot | Administration, System, Enable JFFS custom scripts = No, reboot, then remove the line |
| worst case | restore the settings file and the `/jffs` backup from step 1 |

## Limitations

- IPv4 only. IPv6 entries in a conf are ignored.
- DNS is not redirected. Devices keep using the router's DNS, usually your ISP's resolvers, and the conf's `DNS =` line is ignored. For a privacy VPN this means your ISP still sees which names you look up.
- No kill switch. When a tunnel is down, its devices go out over the normal connection.
- When the firmware rebuilds the firewall, the tunnel's firewall rules are gone until the `firewall-start` line runs again. `status` shows DEGRADED in that gap.
- Deleting `/tmp/wgc.run` by hand while a `try` is pending disarms its timer.
- If a process that is not `wgc.sh` holds the script's lock, `stop` takes it over after about 60 s (10 min if the holder looks like `wgc.sh`). `start`, `try` and `confirm` never do; they print the command to clear the lock.
- Two narrow races remain, both reproducible only with artificial delays: three processes racing for a stale lock can lose a live lock, and a signal during the rename of the pending-`try` file can disarm an earlier `try`.
- Not observed yet over days of uptime with rekeys and firmware firewall restarts. The web page has not been tested on a router without a USB drive.

## Measured results

On an RT-AC86U with 386.14_2 on a 300 Mb/s line, downloading through a full tunnel from a laptop on the LAN:

| Setup | Download | Router CPU idle |
|---|---|---|
| flow cache disabled (`fc disable`) | 314 Mb/s | 20-40 % |
| flow cache on, with the two MARK rules | 320 / 307 / 326 Mb/s | |
| flow cache on, with the two MARK rules, later runs | 317 / 304 / 278 / 294 Mb/s | 17-40 % at the peak |

A split-tunnel conf and a full-tunnel conf also worked side by side for one device: the company networks through `wgc1`, everything else through `wgc2`.

Without the MARK rules a tunnel gets a handshake but stalls after a few packets, because of the Broadcom flow cache. The script marks the tunnel's packets so the flow cache leaves them alone, and hardware acceleration stays on for the rest of the router. See [docs/notes.md](docs/notes.md).

## Development

The test suites run on your computer and never touch a router; how to run them and how they work is in [docs/development.md](docs/development.md).

## License

Apache License 2.0. See [LICENSE](LICENSE).
