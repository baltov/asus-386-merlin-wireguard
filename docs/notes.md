# Notes on the platform

Things I found out about Asuswrt-Merlin 386 on an RT-AC86U while building this. Most of it is not specific to WireGuard and may save another add-on author some time. Everything was observed on 386.14_2; other 386 builds and models may differ.

## Firmware environment

- Linux 4.1.27 aarch64, BusyBox 1.25.1 `ash`, iproute2 5.11, iptables 1.4.15.
- WireGuard ships with the firmware: `wireguard.ko` 1.0.20210124 and `/usr/sbin/wg` 1.0.20200827, which has `syncconf`. There is no `wg-quick`, so anything wg-quick does has to be done by hand.
- The BusyBox build has no `mktemp`, `od` or `id` (checked with `which`). What is there and enough for this project: `awk logger sort head cut tr wc date sed grep printf sleep kill ps cat rm mv chmod ln readlink md5sum hexdump dd mkdir rmdir`, plus `mount`, `umount` and `flock`. Random hex without `od` or `mktemp`: `dd if=/dev/urandom bs=16 count=1 2>/dev/null | md5sum | cut -c1-32`.
- The firmware's `ash` has no `command` builtin: `sh -c 'command -v ls'` prints `sh: command: not found` and exits 127. The `busybox:1.25.1` Docker image does have it, so tests in the container won't catch its use. `type`, `hash` and `which` exist on the router. To test whether an executable exists in a portable way, walk `PATH` and check `-f` and `-x` yourself.
- The firmware finds the public exit address of an OpenVPN client with `gettunnelip.sh`, which runs `ministun` through the tunnel interface and stores the answer in nvram as `vpn_clientN_rip`. `ministun` works for any interface, so an add-on can do the same for its own: `ministun -t 4000 -c 1 -i wgcN stun.l.google.com:19302`.
- `iptables` 1.4.15 predates the `-w` lock. Two scripts changing the firewall at the same time can collide, so hooks in `firewall-start` are best run in the foreground.
- `rp_filter` was 0 on every interface, so the kernel does not drop packets with a spoofed LAN source coming in from a tunnel. Port forwards create DNAT rules without `-i`. Both are reasons to drop LAN-sourced packets from a tunnel explicitly in `raw PREROUTING`.
- The firmware guards its own OpenVPN client tunnels with the chains `OVPNCI` and `OVPNCF`. A WireGuard interface created by a script gets none of that.
- VPN Director rules ended at priority 11209; priorities from 11300 up were free and are evaluated after VPN Director.
- All processes, `init` included, run as the same user, so anything that can write to `/tmp` is effectively root.
- Everything under `/tmp`, `/www/user` included, is RAM and is gone after a reboot.
- A detached background process with HUP ignored survives the SSH session that started it; I tested it with a 60 s `sleep` that wrote to syslog afterwards.

## Flow cache and WireGuard

Symptom: the handshake completes, but data stalls after a few packets.

Cause: the Broadcom flow cache (the hardware acceleration). `fc disable` fixes it for the whole router; two MARK rules per tunnel fix it for the tunnel only:

```
iptables -t mangle -I FORWARD    -o wgcN -j MARK --set-xmark 0x01/0x7
iptables -t mangle -I PREROUTING -i wgcN -j MARK --set-xmark 0x01/0x7
```

On a 300 Mb/s line: 314 Mb/s with `fc disable`; 320 / 307 / 326 and later 317 / 304 / 278 Mb/s with the cache on and the marks; router CPU 17-40 % idle at the peak.

The rules come from ZebMcKayhan/WireguardManager (`wg_client`, lines 445-446). That project also runs `fc disable` (`wg_manager.sh`, line 4142); the marking alone turned out to be enough. The stock firewall had no MARK rules at all, so the low three bits were free. If other add-ons are installed, check `iptables-save` for their marks first.

## iptables -S spelling

`iptables -S` and `iptables-save` print the mark as `--set-xmark 0x1/0x7`, not `0x01/0x7`. It is only spelling: `iptables -C` with `0x01/0x7` finds the rule (exit 0), so a check-then-insert does not duplicate it. If you delete rules by the specification `iptables -S` prints, both spellings go.

## Add-on web pages

**`start_apply.htm` replaces the whole settings file.** An add-on page posts its settings as JSON in the form field `amng_custom`. The firmware writes that JSON as the entire `/jffs/addons/custom_settings.txt`, one `key value` line per key. A page that posts only its own keys wipes the settings of every other add-on. uiDivStats avoids this by loading `<% get_custom_settings(); %>` into the page and posting everything back.

**Size limit of the settings file.** Posting a probe key with values of increasing size and reading the file over SSH after each:

| Value size | Stored |
|---|---|
| 1024 bytes | whole |
| 2048 bytes | whole |
| 4096 bytes | 3027 bytes, silently truncated, no trailing newline |
| 8192 bytes | file empty |
| 16384 bytes | file empty |

The whole file tops out at about 3 KB, and above roughly 8 KB the firmware empties it, taking the other add-ons' settings with it. Keep the payload well below 3 KB and send a length with any large value, so the receiving side can tell a truncated value from a real one.

**`start_apply.htm` reloads the page.** Submitting the form into `hidden_frame` makes the response reload the whole page after `action_wait` seconds: a marker set on `window` disappeared and `performance.now()` started from zero. Posting the same fields with `fetch` (same origin, `application/x-www-form-urlencoded`) is handled the same way by the firmware (the `service-event` runs, the settings are written) and the page stays as it is.

**Missing jQuery breaks scrolling.** A page that does not load `/js/jquery.js` cannot be scrolled. On the router `body` had an inline `overflow: hidden` and `policy_status.EULA` was `"0"`, against `"1"` on the firmware's own pages. The chain:

1. `state.js` loads `httpApi.js` and `asus_policy.js` on every page.
2. `httpApi.js` uses jQuery. If the page doesn't load it, or defines its own global `$`, `httpApi.js:3` throws `$.each is not a function`.
3. `PolicyStatus()` fails and EULA stays `"0"`.
4. `checkPolicy()` creates a `PolicyUpdateModalComponent`, whose constructor sets `body.style.overflow = "hidden"`. The modal itself is 0x0, so nothing on screen explains it.

Fix: load `/js/jquery.js` first in `<head>`, as uiDivStats does, and don't define a global `$`. After that: no inline overflow, EULA `"1"`, no modal, the page scrolls, and the firmware's jQuery is 1.10.2.

**Menu entries.** The menu is `/www/require/modules/menuTree.js`. Add-ons copy it to `/tmp/menuTree.js`, insert their line with `sed`, and bind-mount the copy over the original, all under `flock` on `/tmp/addonwebui.lock`. User pages are `/www/user/user1.asp` .. `user20.asp`, and their data can be served from `/ext/<dir>/` by putting files under `/www/user/<dir>/`. Since `/www/user` is in RAM, a page has to be put back after every reboot; add-ons do that from `post-mount`, which Merlin runs when a USB partition is mounted.

## BusyBox 1.25.1 awk

Two things that work in other awks and break in BusyBox 1.25.1:

- `name (expr)` is read as a call to a function `name`, so a variable can't be concatenated with a parenthesised expression after a space. Build such strings in separate statements.
- `\]` inside a bracket expression doesn't work. Put `]` first instead: `[][0-9A-Za-z.:-]`. A test failed only in the BusyBox container until the class was written that way.

A `busybox:1.25.1` Docker image runs the same `ash` and `awk` and catches both.
