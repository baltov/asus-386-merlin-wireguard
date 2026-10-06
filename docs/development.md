# Development

This script changes the routing and the firewall of a router people depend on. Most of what follows is about making sure a mistake costs a `stop` or a reboot and never a factory reset.

## Trying changes on your own router

**RAM first.** Copy a new version to `/tmp/wgc/` (directory 700, confs 600), run `sh -n` on it, run `check`, then `wgc.sh try <N> <seconds>`. Only install to `/jffs` after the trial looked right. Until the `firewall-start` line exists, a reboot undoes everything.

**Snapshot before and after.** Save `ip -4 rule show`, `ip -4 route show table main` and `iptables-save` (without counters) before a trial. After `stop`, the diff must be empty.

**Keep a way back.** Have a saved settings file and a copy of `/jffs` before you start, and know how to turn off JFFS custom scripts from the web UI (Administration, System) in case a hook misbehaves at boot.

**One step per trial.** If it works, the next step gets its own trial.

The script must never do any of these, and a test run shouldn't either:

- flash firmware, `mtd`, `nvram set`, `nvram commit`, `nvram erase`, factory reset;
- `reboot`, `service restart_*`, `service stop_*`;
- `iptables -F`, `-X`, `-P`, `iptables-restore`, `ip rule flush`, `ip route flush`;
- add an `ip rule` outside priorities 11300-11899, or a route without `table 121`..`125`;
- change the main table's default route, the LAN and WAN interfaces, the firmware's VPN interfaces and tables, or VPN Director's rules;
- touch SSH, the router password or the admin user;
- add an `ACCEPT` rule anywhere; in `INPUT`, `FORWARD` and `raw PREROUTING` only `DROP` with `-i wgcN`;
- install or remove packages, or unload kernel modules;
- overwrite a file in `/jffs/scripts`. Appending one line that ends in `# wgc`, after a backup copy, is the only change allowed there.

The script only touches interfaces `wgc1`..`wgc5`, tables 121-125, `ip rule` priorities 11300-11899 and `iptables` rules that mention `wgcN`. `check_settings` refuses environment settings that would move it outside those ranges; keep it that way.

## Secrets

- Real confs and router backups stay out of the repository and out of bug reports.
- `PrivateKey` and `PresharedKey` must never reach a log, argv, stdout, stderr or a test. To show the structure of a conf, blank the keys with `sed` first.
- Tests use the made-up keys in `tests/fixtures/` and `tests/ui/page/fixtures/conf-fake.conf`.

## Code rules

- POSIX `sh` for BusyBox `ash` 1.25.1. No bashisms: no arrays, `[[ ]]`, `<<<`, `${var//a/b}`, `function`, process substitution. `local` is fine; `ash` and `dash` both have it.
- Only commands the firmware has. `wgc.sh` uses `awk logger sort head cut tr wc date sed grep printf sleep kill ps cat rm mv chmod ln readlink md5sum hexdump dd mkdir rmdir` plus `ip`, `wg`, `iptables`, `modprobe`; `wgcui.sh` adds `mount`, `umount` and `flock`. There is no `mktemp`, `od` or `id`. Anything new has to be checked on a router first.
- Don't use `command`, `type` or `hash` as commands. The firmware's `ash` has no `command` builtin at all (exit 127), although the `busybox:1.25.1` image has one, so the container suite would not notice. To find out whether a program exists, walk `PATH` and test `-f` and `-x`, as `have_ministun` in `wgcui.sh` does. T53 and U45 scan the scripts and fail if any of the three is used as a command.
- No `eval`, no command built from text. Input picks a fixed `case` branch or matches a strict pattern before it reaches argv.
- `start` twice gives the same state as once; `stop` on nothing returns 0.
- A failure in the middle of `start` rolls that tunnel back completely and exits 1.
- An invalid conf or rules file exits 2 before any changing command.
- Names, paths and timeouts are variables at the top of the file.
- Comments and messages in English.
- BusyBox awk has quirks; see [notes.md](notes.md#busybox-1251-awk).

## Tests

```
tests/run.sh                 engine suite, T01..T53
tests/stubs/                 fake ip, wg, iptables, modprobe, logger, sleep; failing mktemp, od, id
tests/fixtures/              split.conf, full.conf (fake keys)
tests/ui/run.sh              handler suite, U01..U47
tests/ui/stubs/              fake wgc.sh, mount, umount, flock
tests/ui/fixtures/           menuTree.js, dnsmasq leases, syslog
tests/ui/page/               Playwright suite for the page (page.spec.mjs, serve.mjs, drive.mjs)
tests/ui/page/fixtures/      status-*.js variants, custom_settings.json, a fake conf, minimal stand-ins for the firmware's JS and CSS
```

Run the shell suites in four modes, one after another:

```
sh tests/run.sh
dash tests/run.sh
TEST_SH=dash sh tests/run.sh
docker run --rm --platform linux/amd64 -v "$PWD/router":/src/router:ro -v "$PWD/tests":/src/tests:ro busybox:1.25.1 \
  sh -c 'mkdir /t && cp -r /src/router /src/tests /t/ && cd /t && sh tests/run.sh'
```

and the same for `tests/ui/run.sh`. A change is done when all of them pass, and the container run counts most. Passing on macOS or with `dash` proves little about the router.

Never run two suites at the same time, not even host and container. T45 kills leftover `wgc.sh` processes and would kill the other run's, and its time budget is tight under emulation.

Single tests: `sh tests/run.sh T05 T31`, `sh tests/ui/run.sh U12`. Output is one `ok`/`not ok` line per test, `#   reason` lines under a failure, and `# pass=X fail=Y`; the exit code is 0 only when nothing failed. `TEST_SH` picks the shell that runs the script under test.

The page suite needs Node 18 or later:

```
cd tests/ui/page
npm ci
npx playwright install chromium
npx playwright test
```

Playwright starts `serve.mjs` on 127.0.0.1:8099 (and HTTPS on 8443 if `openssl` is available) and runs 31 tests in one worker.

### How the stubs work

The engine tests put `tests/stubs` first in `PATH`. Every stub appends its call, `<name> <args>`, to `$STUB_LOG`, and keeps state in files under `$STUB_STATE` (`links`, `addrs`, `routes`, `rules`, `iptables`, and what `wg setconf` received). `ip`, `wg` and `iptables` accept only the forms `wgc.sh` uses; anything else is logged as `UNSUPPORTED ...` and exits 2, and any test whose log has such a line fails. So the stubs check the exact commands, not only the end state.

Knobs:

- `STUB_FAIL='<ERE>'`: a call whose log line matches fails with exit 1 and changes nothing. Used for the rollback tests.
- `STUB_DELAY='<ERE>'`, `STUB_DELAY_SECS`: a matching call really sleeps first. Used to hit signals and races.
- `STUB_ENDPOINT`, `STUB_HANDSHAKE`: what `wg show ... endpoints` and `latest-handshakes` report. `STUB_WG_RX`, `STUB_WG_TX` for `transfer`.
- `STUB_SLEEP`: how long the fake `sleep` really sleeps (default 0). With `STUB_SLEEP_LONG` set, any `sleep` of 10 s or more sleeps that long instead.

A "mutating command" in the assertions is any log line other than the read-only forms (`ip link show`, `ip -4 -o addr show`, `ip -4 rule show`, `ip -4 route show`, `wg show`, `iptables -C`, `iptables -S`) and `logger`. Many tests assert there are none.

The handler tests put `tests/ui/stubs` in front of `tests/stubs`. The fake `wgc.sh` logs its calls and answers from `$STUB_WGC_DIR/<cmd>_<target>.rc` and `.out` (for example `check_1.rc`, `status_2.out`), falling back to `<cmd>.rc`/`.out`, then to exit 0 with no output; `status N` defaults to `wgcN: down` with exit 1. `mount` and `umount` only log; `flock -x <file> cmd...` logs and runs the command. Every `WGC_*` and `WGCUI_*` path points into a temp directory. `status.js` is checked with a small awk JSON parser everywhere, and also with Python's `json` where `python3` exists.

The page tests load `router/wgcui.asp` from `serve.mjs`, which:

- serves the page at `/user1.asp` with `<% get_custom_settings(); %>` replaced by `fixtures/custom_settings.json` (or a per-test override) and other `<% %>` tags removed;
- serves the stand-ins for the firmware's scripts and stylesheets, `/js/jquery.js` included;
- serves `/ext/wgc/status.js` from the selected `fixtures/status-<name>.js`, bumping `generated` after each post;
- records every `POST /start_apply.htm` in `out/posts.jsonl`;
- has test-only endpoints: `POST /__fixture {name}`, `POST /__custom_settings`, `POST /__failnext` (the next post gets HTTP 500), `POST /__reset`, `GET /__posts`.

## A browser session against your router

`tests/ui/page/drive.mjs` opens a visible Chromium with a persistent profile and exposes a small HTTP control server, so you can script a session on a real router from the shell:

```
cd tests/ui/page
node drive.mjs http://192.168.1.1 /tmp/wgc-profile 9300
```

Log in to the router once in that window; the profile keeps the session. Keep the profile directory outside the repository, since it holds the session cookie. When the control server prints `READY`:

```
curl -s 127.0.0.1:9300/status
curl -s -X POST 127.0.0.1:9300/goto  -d '{"url":"http://192.168.1.1/user1.asp"}'
curl -s -X POST 127.0.0.1:9300/shot  -d '{"path":"/tmp/wgc.png","fullPage":true}'
curl -s -X POST 127.0.0.1:9300/text  -d '{"selector":"#top_msg"}'
curl -s -X POST 127.0.0.1:9300/eval  -d '{"js":"document.body.style.overflow"}'
curl -s -X POST 127.0.0.1:9300/quit
```

Use the `userN.asp` slot that `install` picked. Routes: `GET /status`; `POST /goto {url}`, `/shot {path, fullPage}`, `/text {selector}`, `/count {selector}`, `/click {selector}`, `/fill {selector, value}`, `/eval {js}`, `/wait {selector, timeout}`, `/setfile {selector, path}`, `/quit`. The viewport is 1280x900; `DRIVE_VIEWPORT=window` uses the window size instead.

Every button on that page acts on the real router. Start tunnels with `try` over SSH first, and use level `ro` until you trust a change.

## Getting back

| Situation | Way back |
|---|---|
| a trial from RAM | `wgc.sh stop`, wait for the `try` timer, or reboot |
| SSH lost during a trial | the `try` timer removes everything; if not, power-cycle |
| the web page | `sh /jffs/addons/wgc/wgcui.sh uninstall`; broken menu: `umount /www/require/modules/menuTree.js` or reboot |
| a wrong action from the page | `wgc.sh stop all` over SSH |
| permanent install | delete the `# wgc` line from `/jffs/scripts/firewall-start` and the directory `/jffs/addons/wgc/` |
| a hook misbehaves at boot | Administration, System, Enable JFFS custom scripts = No |
| worst case | restore your saved settings file and the `/jffs` copy |
