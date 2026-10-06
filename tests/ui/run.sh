#!/bin/sh
# Test runner for router/wgcui.sh (installer + web-UI action handler) against fake
# wgc.sh/mount/umount/flock (tests/ui/stubs) and the wg/ip/... stubs (tests/stubs).
# Usage: sh tests/ui/run.sh [Uxx ...]      (TEST_SH=dash selects the shell under test)
# Prints "ok N - Uxx title" / "not ok N - Uxx title" (+ "#   reason" lines), then "# pass=X fail=Y".
#
# What the assertions accept:
#  - status.js: tunnels is an array of 5 objects in slot order (tunnels[N-1]) or an object keyed "1".."5";
#    last.{action,target,rc,message}; a refusal text may be in last.message, last.error or error.
#  - "no wgc.sh call" = no call except `wgc.sh status ...` (building status.js needs those).

HERE=$(cd "$(dirname "$0")" && pwd) || exit 2
ROOT=$(dirname "$(dirname "$HERE")")
FIX="$HERE/fixtures"
SCRIPT=${WGCUI_SCRIPT_UNDER_TEST:-$ROOT/router/wgcui.sh}
REAL_MKTEMP=$(command -v mktemp) || exit 2
BASEPATH=$PATH
PATH="$HERE/stubs:$ROOT/tests/stubs:$PATH"
export PATH

ALL="U01 U02 U03 U04 U05 U06 U07 U08 U09 U10 U11 U12 U13 U14 U15 U16 U17 U18 U19 U20 U21 U22 U23 U24 U25 U26 U27 U28 U29 U30 U31 U32 U33 U34 U35 U36 U37 U38 U39 U40 U41 U42 U43 U44 U45 U46 U47"

title() {
    case "$1" in
    U01) echo "install: page, title, menu line, mount, post-mount, status.js; no service-event line" ;;
    U02) echo "install twice: same state, one menu line, one post-mount line" ;;
    U03) echo "foreign user1.asp: page goes to user2.asp" ;;
    U04) echo "enable-events: one service-event line, .bak, idempotent" ;;
    U05) echo "mount restores a deleted menu line, changes nothing else" ;;
    U06) echo "service_event without keys: no action, rc 2, exit 0" ;;
    U07) echo "refresh: full status.js, keys deleted, status 1..5 only" ;;
    U08) echo "unknown action refused, no wgc.sh call, keys deleted" ;;
    U09) echo "bad target (6, all;cmd) refused, no wgc.sh call" ;;
    U10) echo "bad seconds (9, 99999, 300\$(id)) refused, no wgc.sh call" ;;
    U11) echo "level ro refuses start; set-level full allows it" ;;
    U12) echo "saveconf: file 600, decoded %-codes, key deleted, check 1, no .prev" ;;
    U13) echo "saveconf refused by check: old conf restored byte for byte" ;;
    U14) echo "saveconf: 5000 bytes, 0x01 byte, target 7 refused, nothing written" ;;
    U15) echo "saverules at full: rules written, check all then start of the running tunnel" ;;
    U16) echo "saverules refused by check: old rules restored, no start all" ;;
    U17) echo "saverules at ro: rules written, check all, no start all" ;;
    U18) echo "deleteconf 2: stop 2, wgc2.conf gone" ;;
    U19) echo "confirm, stop all, check 3: one call each" ;;
    U20) echo "hostile leases and syslog: valid JSON, sanitized names and log" ;;
    U21) echo "DEGRADED status: state degraded, missing list" ;;
    U22) echo "live uilock: busy, keys deleted, no wgc.sh call, lock untouched" ;;
    U23) echo "pending_try from wgc.pending and a __watchdog process" ;;
    U24) echo "foreign wgcui_ key ignored, all wgcui_ keys deleted, others intact" ;;
    U25) echo "install without the VPNClient line: menu entry after SwitchCtrl" ;;
    U26) echo "refresh reports rx/tx of an existing interface" ;;
    U27) echo "rules line with trailing comment is shown and survives saverules without the comment" ;;
    U28) echo "kill -9 in the middle of saveconf: next run restores the old conf, no .prev, lock gone" ;;
    U29) echo "settings file is a symlink: refused, target untouched" ;;
    U31) echo "decoding: only %25 %7C %0A; leading/trailing | survives; %41 stays literal" ;;
    U32) echo "install without a menu anchor: no page, no title left behind" ;;
    U33) echo "no wgcui_ keys: settings file inode and mtime unchanged" ;;
    U34) echo "logger is not called for refresh, is called for start" ;;
    U35) echo ".prev is restored only with the marker, never when oversized" ;;
    U36) echo "failed install without anchors keeps our existing menu line" ;;
    U37) echo "rules line with 4 fields is skipped and counted in rules_skipped" ;;
    U38) echo "wgcui_len must equal the encoded value length (saveconf and saverules)" ;;
    U39) echo "status.js foreign_settings: all non-wgcui_ settings, escaped" ;;
    U40) echo "saverules at full starts only tunnels whose interface exists" ;;
    U41) echo "endpoint of a down tunnel comes from check" ;;
    U42) echo "exit IP: one ministun lookup after start and one per refresh" ;;
    U43) echo "exit IP: failing ministun tries both servers, garbage gives empty, no ministun gives no lookup, tunnel down: no lookup" ;;
    U44) echo "exit IP: exitip action is unknown, stop removes the cache" ;;
    U45) echo "static guard: no command/type/hash builtin used (absent from the router ash)" ;;
    U46) echo "rule metadata: #off, name and desc from the trailing comment, rules_skipped" ;;
    U47) echo "saverules at ro keeps comments and #off byte for byte, check all once, no start" ;;
    U30) echo "install + enable-events + uninstall leaves nothing, touches no wgc files" ;;
    esac
}

# ---------- JSON ----------

# Flattens JSON (after stripping "var wgcui = " and the trailing ";") into lines "path=value"
# (strings keep their quotes and raw escapes). Exit 1 on any syntax error.
JFLAT='
function ws(   c) {
    while (pos <= n) { c = substr(s, pos, 1); if (c == " " || c == "\t" || c == "\n" || c == "\r") pos++; else break }
}
function str(   c, t, st) {
    pos++; st = pos
    while (1) {
        if (pos > n) { bad = 1; return "" }
        c = substr(s, pos, 1)
        if (c == "\"") {
            t = substr(s, st, pos - st); pos++
            if (t ~ /[[:cntrl:]]/) bad = 1
            return t
        }
        if (c == "\\") {
            c = substr(s, pos + 1, 1)
            if (c == "u") {
                if (substr(s, pos + 2, 4) !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) { bad = 1; return "" }
                pos += 6; continue
            }
            if (c == "" || index("\"\\/bfnrt", c) == 0) { bad = 1; return "" }
            pos += 2; continue
        }
        pos++
    }
}
function val(path,   c, k, i, m) {
    ws(); c = substr(s, pos, 1)
    if (c == "{") {
        pos++; ws()
        if (substr(s, pos, 1) == "}") { pos++; print path "={}"; return }
        while (!bad) {
            ws(); if (substr(s, pos, 1) != "\"") { bad = 1; return }
            k = str(); if (bad) return
            ws(); if (substr(s, pos, 1) != ":") { bad = 1; return }
            pos++; val((path == "" ? k : path "." k)); if (bad) return
            ws(); c = substr(s, pos, 1); pos++
            if (c == ",") continue
            if (c == "}") return
            bad = 1; return
        }
        return
    }
    if (c == "[") {
        pos++; ws()
        if (substr(s, pos, 1) == "]") { pos++; print path "=[]"; return }
        i = 0
        while (!bad) {
            val(path "[" i "]"); if (bad) return
            i++
            ws(); c = substr(s, pos, 1); pos++
            if (c == ",") continue
            if (c == "]") return
            bad = 1; return
        }
        return
    }
    if (c == "\"") { k = str(); if (!bad) print path "=\"" k "\""; return }
    m = substr(s, pos)
    if (match(m, /^(true|false|null)/)) { print path "=" substr(m, 1, RLENGTH); pos += RLENGTH; return }
    if (match(m, /^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?/)) { print path "=" substr(m, 1, RLENGTH); pos += RLENGTH; return }
    bad = 1
}
{ s = s $0 "\n" }
END {
    if (!sub(/^[ \t\n]*var[ \t]+wgcui[ \t]*=[ \t]*/, "", s)) exit 1
    if (!sub(/;[ \t\n]*$/, "", s)) exit 1
    n = length(s); pos = 1; bad = 0
    val("")
    ws()
    if (pos <= n) bad = 1
    exit bad
}'

jflat() { awk "$JFLAT"; }

HAVE_PY=0
if command -v python3 >/dev/null 2>&1; then HAVE_PY=1; fi

# json_valid FILE: awk parser always; on a host with python3 also json.load (both must accept)
json_valid() {
    [ -f "$1" ] || return 1
    jflat < "$1" > /dev/null 2>&1 || return 1
    if [ "$HAVE_PY" = 1 ]; then
        tr '\n' ' ' < "$1" | sed -e 's/^ *var wgcui *= *//' -e 's/; *$//' | python3 -c 'import json,sys; json.load(sys.stdin)' > /dev/null 2>&1 || return 1
    fi
    return 0
}

# the validator must not pass garbage: self-check before any test runs
selfcheck_json() {
    d=$("$REAL_MKTEMP" -d "${TMPDIR:-/tmp}/wgcui-jsc.XXXXXX") || exit 2
    printf '%s\n' 'var wgcui = {"a":[1,"x\"y\\z",{"b":null,"c":true}],"d":{}};' > "$d/good"
    ok=1
    json_valid "$d/good" || ok=0
    for bad in 'var wgcui = {"a":[1,};' 'var wgcui = {"a":"x"y"};' 'var wgcui = {"a":1};x' 'var wgcui = {"a":1}' 'x = {"a":1};' 'var wgcui = {"a":"\q"};' 'var wgcui = {"a":1,};'; do
        printf '%s\n' "$bad" > "$d/bad"
        if json_valid "$d/bad"; then ok=0; fi
    done
    printf 'var wgcui = {"a":"x\001y"};\n' > "$d/bad"
    if json_valid "$d/bad"; then ok=0; fi
    rm -rf "$d"
    [ "$ok" = 1 ] || { echo "runner error: JSON validator self-check failed" >&2; exit 2; }
}
selfcheck_json

# ---------- environment ----------

HOLDER= FAKE=

setup() {
    T=$("$REAL_MKTEMP" -d "${TMPDIR:-/tmp}/wgcui-test.XXXXXX") || exit 2
    export STUB_LOG="$T/stub.log" STUB_STATE="$T/state" STUB_WGC_DIR="$T/wgcreply"
    export WGC_DIR="$T/conf" WGC_RUN_DIR="$T/run" WGCUI_SETTINGS="$T/settings" WGCUI_WWW="$T/www"
    export WGCUI_MENUTREE="$T/menuTree.js" WGCUI_MENUTREE_SRC="$T/menuTree.src.js" WGCUI_SCRIPTS="$T/scripts"
    export WGCUI_LEASES="$T/leases" WGCUI_SYSLOG="$T/syslog" WGCUI_LOCKFILE="$T/addonwebui.lock"
    unset WGCUI_WEBDIR WGCUI_TITLE STUB_FAIL STUB_STUN_OUT STUB_ENDPOINT STUB_HANDSHAKE STUB_WG_RX STUB_WG_TX STUB_SLEEP STUB_SLEEP_LONG
    SJS="$WGCUI_WWW/wgc/status.js"
    mkdir -p "$STUB_STATE" "$STUB_WGC_DIR" "$WGC_DIR" "$WGC_RUN_DIR" "$WGCUI_WWW" "$WGCUI_SCRIPTS"
    : > "$STUB_LOG"; : > "$T/unsupported"; : > "$STUB_STATE/links"
    # stub wgc.sh the handler will call by full path
    cp "$HERE/stubs/wgc.sh" "$WGC_DIR/wgc.sh"; chmod 755 "$WGC_DIR/wgc.sh"
    # the page: the real one when it exists, otherwise some file (install only needs "some file")
    if [ -f "$ROOT/router/wgcui.asp" ]; then cp "$ROOT/router/wgcui.asp" "$WGC_DIR/wgcui.asp"
    else printf '%s\n' '<html><body>placeholder wgcui page</body></html>' > "$WGC_DIR/wgcui.asp"; fi
    printf '%s\n' 'uidivstats_version_local v3.0.4' 'uiscribe_version_local v2.1' > "$WGCUI_SETTINGS"
    cp "$WGCUI_SETTINGS" "$T/settings.seed"
    cp "$FIX/menuTree.js" "$WGCUI_MENUTREE"; cp "$FIX/menuTree.js" "$WGCUI_MENUTREE_SRC"
    printf '%s\n' '#!/bin/sh' '/jffs/scripts/other-addon mount # foreign' '/opt/bin/something start' > "$WGCUI_SCRIPTS/post-mount"
    printf '%s\n' '#!/bin/sh' 'if [ "$2" = "wg_manager" ]; then /jffs/scripts/wg_manager.sh "$@" & fi # foreign' 'logger "service event $*"' > "$WGCUI_SCRIPTS/service-event"
    printf '%s\n' '#!/bin/sh' '/jffs/scripts/skynet firewall # foreign' 'echo fw-start' > "$WGCUI_SCRIPTS/firewall-start"
    for f in post-mount service-event firewall-start; do cp "$WGCUI_SCRIPTS/$f" "$T/$f.seed"; done
    : > "$WGCUI_LEASES"; : > "$WGCUI_SYSLOG"
}

holder_start() { holder_stop; /bin/sleep 60 & HOLDER=$!; }
holder_stop() {
    if [ -n "$HOLDER" ]; then kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; fi
    HOLDER=
}
fake_stop() {
    if [ -n "$FAKE" ]; then kill "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null; fi
    FAKE=
}
cleanup() { holder_stop; fake_stop; [ -n "$T" ] && rm -rf "$T"; T=; }
trap 'cleanup; exit 130' INT TERM

# ---------- helpers ----------

# run the script under test; sets RC, output in $T/out
run() {
    ${TEST_SH:-sh} "$SCRIPT" "$@" > "$T/out" 2>&1
    RC=$?
}
run_ev() { run service_event start wgcui; }

fail() {
    TFAIL=1
    REASONS="$REASONS#   $1
"
}
assert_rc() { [ "$RC" = "$1" ] || fail "$2: exit code $RC, expected $1"; }

kv() { printf '%s %s\n' "$1" "$2" >> "$WGCUI_SETTINGS"; }
# encode a file like the page does: % -> %25, | -> %7C, CR removed, lines joined by %0A
enc() { awk '{ gsub(/\r/, ""); gsub(/%/, "%25"); gsub(/\|/, "%7C"); if (NR > 1) printf "%%0A"; printf "%s", $0 } END { printf "\n" }'; }
kv_enc_raw() { { printf '%s ' "$1"; enc < "$2"; } >> "$WGCUI_SETTINGS"; }
enc_len() { enc < "$1" | tr -d '\n' | wc -c | tr -d ' '; }
# like the page: the value plus wgcui_len = its byte length
kv_enc() { kv_enc_raw "$1" "$2"; kv wgcui_len "$(enc_len "$2")"; }
reseed() { cp "$T/settings.seed" "$WGCUI_SETTINGS"; : > "$STUB_LOG"; }
set_level() { printf '%s\n' "$1" > "$WGC_DIR/wgcui.level"; }
put_conf() { cp "$ROOT/tests/fixtures/${2:-split}.conf" "$WGC_DIR/wgc$1.conf"; chmod 600 "$WGC_DIR/wgc$1.conf"; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
# drop trailing blank lines (a decoded value may end with one more newline than the original)
norm() { awk 'NF == 0 { b++; next } { for (; b > 0; b--) print ""; print }'; }
same_text() { norm < "$1" > "$T/n1"; norm < "$2" > "$T/n2"; cmp -s "$T/n1" "$T/n2"; }
stub_reply() { printf '%s\n' "$2" > "$STUB_WGC_DIR/$1"; }   # stub_reply check_1.rc 2

# status.js access
jv() { jflat < "$SJS" 2>/dev/null | awk -v p="$1" 'index($0, p "=") == 1 { print substr($0, length(p) + 2); exit }'; }
tv() {    # tv N field: slot N value, tunnels as array (N-1) or object keyed N
    _v=$(jv "tunnels[$(($1 - 1))].$2")
    [ -n "$_v" ] || _v=$(jv "tunnels.$1.$2")
    printf '%s' "$_v"
}
assert_json() { json_valid "$SJS" || fail "$1: status.js missing or not valid JSON"; }
assert_jv() { _g=$(jv "$1"); [ "$_g" = "$2" ] || fail "$3: $1 is '$_g', expected '$2'"; }
assert_tv() { _g=$(tv "$1" "$2"); [ "$_g" = "$3" ] || fail "$4: tunnels[$1].$2 is '$_g', expected '$3'"; }
assert_msg() {    # a text in last.message / last.error / error / message
    jflat < "$SJS" 2>/dev/null | grep -E '^(last\.message|last\.error|error|message)=' | grep -Fq -- "$1" \
        || fail "$2: no message containing '$1' in status.js"
}
assert_notpending() { assert_jv pending false "$1"; }

# wgc.sh calls from the stub log
wcalls() { grep -a '^wgc\.sh ' "$STUB_LOG" 2>/dev/null; }
wactions() { wcalls | grep -v '^wgc\.sh status '; }
assert_noact() {
    _n=$(wactions | wc -l | tr -d ' ')
    [ "$_n" = 0 ] || fail "$1: unexpected wgc.sh call: $(wactions | head -1)"
}
count_call() { wcalls | grep -Fxc -- "wgc.sh $1"; }
assert_called_once() { [ "$(count_call "$1")" = 1 ] || fail "$2: 'wgc.sh $1' called $(count_call "$1") times, expected 1"; }
assert_not_called() { [ "$(count_call "$1")" = 0 ] || fail "$2: 'wgc.sh $1' was called"; }
assert_locked() { grep -aq -- "^flock -x $WGCUI_LOCKFILE " "$STUB_LOG" || fail "$1: no 'flock -x <lockfile> ...' call in the stub log"; }
log_has() { grep -aFxq -- "$1" "$STUB_LOG" || fail "$2: stub log lacks line '$1'"; }

# keys deleted and every other settings line exactly as seeded
assert_keys_gone() {
    _n=$(grep -c '^wgcui_' "$WGCUI_SETTINGS")
    [ "$_n" = 0 ] || fail "$1: $_n wgcui_ line(s) left in settings"
    cmp -s "$WGCUI_SETTINGS" "$T/settings.seed" || fail "$1: foreign settings lines changed"
}
assert_noconf_files() {
    _l=$(ls -A "$WGC_DIR" | grep -E '^wgc[0-9]+\.conf' | head -1)
    [ -z "$_l" ] || fail "$1: conf file written: $_l"
}
menu_count() { grep -c "$1" "$WGCUI_MENUTREE"; }
OUR_LINE() { printf '{url: "user%s.asp", tabName: "WireGuard Client"},' "$1"; }
PM_LINE='/jffs/addons/wgc/wgcui.sh mount >/dev/null 2>&1 & # wgc'
SE_LINE='if [ "$2" = "wgcui" ]; then /jffs/addons/wgc/wgcui.sh service_event "$@" & fi # wgc'
# the line right after the first line containing fixed text $1 in menu
menu_after() { awk -v p="$1" 'f { print; exit } index($0, p) { f = 1 }' "$WGCUI_MENUTREE"; }
snap() {   # state of an installed world without volatile status.js
    { ls -A "$WGCUI_WWW"; cat "$WGCUI_MENUTREE" "$WGCUI_SCRIPTS/post-mount" "$WGCUI_SCRIPTS/service-event"; cat "$WGCUI_WWW"/user*.title 2>/dev/null; } 2>/dev/null
}

# ---------- tests ----------

t_U01() {
    run install; assert_rc 0 "install"
    cmp -s "$WGCUI_WWW/user1.asp" "$WGC_DIR/wgcui.asp" || fail "user1.asp is not a copy of wgcui.asp"
    [ "$(cat "$WGCUI_WWW/user1.title" 2>/dev/null)" = "WireGuard Client" ] || fail "user1.title wrong"
    [ "$(menu_after 'url: "Advanced_VPNClient_Content.asp"')" = "$(OUR_LINE 1)" ] || fail "menu line not right after Advanced_VPNClient_Content.asp"
    [ "$(menu_count 'tabName: "WireGuard Client"')" = 1 ] || fail "menu has $(menu_count 'tabName: "WireGuard Client"') WireGuard Clients lines"
    assert_locked "install"
    log_has "umount $WGCUI_MENUTREE_SRC" "install"
    log_has "mount -o bind $WGCUI_MENUTREE $WGCUI_MENUTREE_SRC" "install"
    [ "$(grep -c '# wgc$' "$WGCUI_SCRIPTS/post-mount")" = 1 ] || fail "post-mount: not exactly one '# wgc' line"
    grep -Fxq -- "$PM_LINE" "$WGCUI_SCRIPTS/post-mount" || fail "post-mount line differs from the expected line"
    [ -f "$WGC_DIR/post-mount.bak" ] || fail "post-mount.bak missing"
    cmp -s "$WGC_DIR/post-mount.bak" "$T/post-mount.seed" || fail "post-mount.bak is not the original"
    grep -v '# wgc$' "$WGCUI_SCRIPTS/post-mount" | cmp -s - "$T/post-mount.seed" || fail "foreign post-mount lines changed"
    assert_json "install"; assert_notpending "install"
    cmp -s "$WGCUI_SCRIPTS/service-event" "$T/service-event.seed" || fail "install touched service-event"
}

t_U02() {
    run install; assert_rc 0 "install 1"
    snap > "$T/s1"
    : > "$STUB_LOG"
    run install; assert_rc 0 "install 2"
    assert_locked "install 2"
    snap > "$T/s2"
    cmp -s "$T/s1" "$T/s2" || fail "state differs after the second install"
    [ "$(menu_count 'tabName: "WireGuard Client"')" = 1 ] || fail "menu has $(menu_count 'tabName: "WireGuard Client"') entries"
    [ "$(grep -c '# wgc$' "$WGCUI_SCRIPTS/post-mount")" = 1 ] || fail "post-mount: not exactly one '# wgc' line"
    [ -f "$WGCUI_WWW/user1.asp" ] && [ ! -f "$WGCUI_WWW/user2.asp" ] || fail "second install moved to another slot"
}

t_U03() {
    printf '%s\n' 'foreign page' > "$WGCUI_WWW/user1.asp"
    run install; assert_rc 0 "install"
    cmp -s "$WGCUI_WWW/user2.asp" "$WGC_DIR/wgcui.asp" || fail "user2.asp is not a copy of wgcui.asp"
    [ "$(cat "$WGCUI_WWW/user1.asp")" = "foreign page" ] || fail "foreign user1.asp was changed"
    [ "$(cat "$WGCUI_WWW/user2.title" 2>/dev/null)" = "WireGuard Client" ] || fail "user2.title wrong"
    grep -Fxq -- "$(OUR_LINE 2)" "$WGCUI_MENUTREE" || fail "menu does not point to user2.asp"
    [ "$(menu_count 'tabName: "WireGuard Client"')" = 1 ] || fail "menu has $(menu_count 'tabName: "WireGuard Client"') entries"
    grep -Fq -- '{url: "user1.asp", tabName: "Diversion"},' "$WGCUI_MENUTREE" || fail "foreign user1.asp menu line was removed"
}

t_U04() {
    run enable-events; assert_rc 0 "enable-events"
    [ "$(grep -Fxc -- "$SE_LINE" "$WGCUI_SCRIPTS/service-event")" = 1 ] || fail "service-event does not have exactly one expected line"
    [ "$(grep -c '# wgc$' "$WGCUI_SCRIPTS/service-event")" = 1 ] || fail "service-event: not exactly one '# wgc' line"
    [ -f "$WGC_DIR/service-event.bak" ] || fail "service-event.bak missing"
    cmp -s "$WGC_DIR/service-event.bak" "$T/service-event.seed" || fail "service-event.bak is not the original"
    grep -v '# wgc$' "$WGCUI_SCRIPTS/service-event" | cmp -s - "$T/service-event.seed" || fail "foreign service-event lines changed"
    run enable-events; assert_rc 0 "enable-events again"
    [ "$(grep -Fxc -- "$SE_LINE" "$WGCUI_SCRIPTS/service-event")" = 1 ] || fail "second run: not exactly one line"
    [ "$(grep -c '# wgc$' "$WGCUI_SCRIPTS/service-event")" = 1 ] || fail "second run: not exactly one '# wgc' line"
}

t_U05() {
    run install; assert_rc 0 "install"
    cp "$WGCUI_MENUTREE" "$T/menu.installed"
    snap > "$T/s1"
    grep -v 'tabName: "WireGuard Client"' "$WGCUI_MENUTREE" > "$T/menu.cut"; cp "$T/menu.cut" "$WGCUI_MENUTREE"
    [ "$(menu_count 'tabName: "WireGuard Client"')" = 0 ] || fail "test setup: line not removed"
    : > "$STUB_LOG"
    run mount; assert_rc 0 "mount"
    cmp -s "$WGCUI_MENUTREE" "$T/menu.installed" || fail "menu is not back to the installed state"
    snap > "$T/s2"
    cmp -s "$T/s1" "$T/s2" || fail "mount changed more than the menu"
    log_has "mount -o bind $WGCUI_MENUTREE $WGCUI_MENUTREE_SRC" "mount"
    assert_locked "mount"
}

t_U06() {
    run_ev; assert_rc 0 "service_event"
    assert_json "no keys"
    assert_jv last.action '""' "no keys"
    assert_jv last.rc 2 "no keys"
    assert_msg "no action" "no keys"
    assert_noact "no keys"
}

t_U07() {
    kv wgcui_action refresh
    run_ev; assert_rc 0 "refresh"
    assert_json "refresh"; assert_notpending "refresh"
    assert_jv version '"1"' "refresh"
    assert_jv last.action '"refresh"' "refresh"
    assert_keys_gone "refresh"
    n=1
    while [ $n -le 5 ]; do
        log_has "wgc.sh status $n" "refresh"
        assert_tv $n state '"noconf"' "refresh"
        assert_tv $n conf false "refresh"
        n=$((n + 1))
    done
    assert_jv pending_try null "refresh"
    assert_noact "refresh"
}

t_U08() {
    set_level full
    kv wgcui_action reboot
    run_ev; assert_rc 0 "reboot"
    assert_json "reboot"
    assert_msg "unknown action" "reboot"
    assert_noact "reboot"
    assert_keys_gone "reboot"
}

t_U09() {
    set_level full
    kv wgcui_action start; kv wgcui_target 6
    run_ev; assert_rc 0 "target 6"
    assert_json "target 6"; assert_msg "target" "target 6"
    assert_noact "target 6"; assert_keys_gone "target 6"
    reseed
    kv wgcui_action start; kv wgcui_target "all;touch $T/pwned"
    run_ev; assert_rc 0 "target all;cmd"
    assert_json "target all;cmd"; assert_msg "target" "target all;cmd"
    assert_noact "target all;cmd"; assert_keys_gone "target all;cmd"
    [ ! -e "$T/pwned" ] || fail "the injected command ran"
}

t_U10() {
    set_level full
    for s in 9 99999 '300$(id)'; do
        reseed
        kv wgcui_action try; kv wgcui_target 1; kv wgcui_seconds "$s"
        run_ev; assert_rc 0 "seconds $s"
        assert_json "seconds $s"; assert_msg "seconds" "seconds $s"
        assert_noact "seconds $s"; assert_keys_gone "seconds $s"
    done
}

t_U11() {
    kv wgcui_action start; kv wgcui_target 1
    run_ev; assert_rc 0 "start at ro"
    assert_json "ro"; assert_msg "level ro" "ro"
    assert_noact "ro"; assert_keys_gone "ro"
    run set-level full; assert_rc 0 "set-level full"
    [ "$(cat "$WGC_DIR/wgcui.level" 2>/dev/null)" = full ] || fail "wgcui.level is not 'full'"
    reseed
    kv wgcui_action start; kv wgcui_target 1
    run_ev; assert_rc 0 "start at full"
    assert_called_once "start 1" "start at full"
    assert_keys_gone "start at full"
}

t_U12() {
    set_level full
    printf '%s\n' '[Interface]' 'PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' 'Address = 10.0.0.2/32' '' '[Peer]' 'PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=' 'AllowedIPs = 0.0.0.0/0' 'Endpoint = 203.0.113.9:51820' > "$T/new.conf"
    stub_reply check_1.rc 0
    kv wgcui_action saveconf; kv wgcui_target 1; kv_enc wgcui_conf "$T/new.conf"
    run_ev; assert_rc 0 "saveconf"
    [ -f "$WGC_DIR/wgc1.conf" ] || fail "wgc1.conf missing"
    [ "$(mode_of "$WGC_DIR/wgc1.conf")" = 600 ] || fail "wgc1.conf mode is $(mode_of "$WGC_DIR/wgc1.conf"), expected 600"
    same_text "$WGC_DIR/wgc1.conf" "$T/new.conf" || fail "wgc1.conf is not the decoded conf"
    grep -aq '%0A' "$WGC_DIR/wgc1.conf" && fail "wgc1.conf still contains %0A"
    assert_keys_gone "saveconf"
    log_has "wgc.sh check 1" "saveconf"
    [ ! -e "$WGC_DIR/wgc1.conf.prev" ] || fail ".prev left behind"
    assert_json "saveconf"; assert_notpending "saveconf"
}

t_U13() {
    set_level full
    put_conf 1 split
    cp "$WGC_DIR/wgc1.conf" "$T/old.conf"
    stub_reply check_1.rc 2; stub_reply check_1.out 'line 3: bad'
    kv wgcui_action saveconf; kv wgcui_target 1; kv_enc wgcui_conf "$ROOT/tests/fixtures/full.conf"
    run_ev; assert_rc 0 "saveconf refused"
    cmp -s "$WGC_DIR/wgc1.conf" "$T/old.conf" || fail "old conf not restored byte for byte"
    assert_json "refused"; assert_msg "line 3: bad" "refused"
    assert_jv last.rc 2 "refused"
    [ ! -e "$WGC_DIR/wgc1.conf.prev" ] || fail ".prev left behind"
    assert_keys_gone "refused"
}

t_U14() {
    set_level full
    { cat "$ROOT/tests/fixtures/split.conf"; awk 'BEGIN { for (i = 0; i < 110; i++) print "# padpadpadpadpadpadpadpadpadpadpadpadpadpadpad" }'; } > "$T/big.conf"
    [ "$(wc -c < "$T/big.conf")" -gt 4096 ] || fail "test setup: conf too small"
    kv wgcui_action saveconf; kv wgcui_target 1; kv_enc wgcui_conf "$T/big.conf"
    run_ev; assert_rc 0 "5000 bytes"
    assert_json "5000 bytes"; assert_noconf_files "5000 bytes"; assert_noact "5000 bytes"; assert_keys_gone "5000 bytes"
    reseed
    { cat "$ROOT/tests/fixtures/split.conf"; printf 'Comment = a\001b\n'; } > "$T/ctl.conf"
    kv wgcui_action saveconf; kv wgcui_target 1; kv_enc wgcui_conf "$T/ctl.conf"
    run_ev; assert_rc 0 "0x01"
    assert_json "0x01"; assert_noconf_files "0x01"; assert_noact "0x01"; assert_keys_gone "0x01"
    reseed
    kv wgcui_action saveconf; kv wgcui_target 7; kv_enc wgcui_conf "$ROOT/tests/fixtures/split.conf"
    run_ev; assert_rc 0 "target 7"
    assert_json "target 7"; assert_msg "target" "target 7"
    assert_noconf_files "target 7"; assert_noact "target 7"; assert_keys_gone "target 7"
}

t_U15() {
    set_level full
    printf '%s\n' 'wgc1 192.168.2.233 any' 'wgc2 192.168.2.0/24 10.0.0.0/8' > "$T/new.rules"
    stub_reply check_all.rc 0
    put_conf 1 split
    printf '%s\n' 'wgc1 up' > "$STUB_STATE/links"
    kv wgcui_action saverules; kv_enc wgcui_rules "$T/new.rules"
    run_ev; assert_rc 0 "saverules"
    [ -f "$WGC_DIR/rules" ] || fail "rules missing"
    same_text "$WGC_DIR/rules" "$T/new.rules" || fail "rules differ from the decoded input"
    a=$(grep -an '^wgc\.sh check all$' "$STUB_LOG" | head -1 | cut -d: -f1)
    b=$(grep -an '^wgc\.sh start 1$' "$STUB_LOG" | head -1 | cut -d: -f1)
    [ -n "$a" ] || fail "no 'check all'"
    [ -n "$b" ] || fail "no 'start 1' (wgc1 is up)"
    [ -z "$a" ] || [ -z "$b" ] || [ "$a" -lt "$b" ] || fail "'start 1' before 'check all'"
    assert_not_called "start all" "saverules"
    assert_keys_gone "saverules"; assert_json "saverules"
}

t_U16() {
    set_level full
    printf '%s\n' 'wgc1 192.168.2.5 any' > "$WGC_DIR/rules"
    cp "$WGC_DIR/rules" "$T/old.rules"
    printf '%s\n' 'wgc1 999.1.1.1 any' 'wgc2 192.168.2.7 any' > "$T/new.rules"
    stub_reply check_all.rc 2; stub_reply check_all.out 'rule 1: bad address'
    kv wgcui_action saverules; kv_enc wgcui_rules "$T/new.rules"
    run_ev; assert_rc 0 "saverules refused"
    cmp -s "$WGC_DIR/rules" "$T/old.rules" || fail "old rules not restored"
    assert_not_called "start all" "refused"
    log_has "wgc.sh check all" "refused"
    assert_json "refused"; assert_msg "rule 1: bad address" "refused"
    assert_keys_gone "refused"
}

t_U17() {
    printf '%s\n' 'wgc1 192.168.2.233 any' > "$T/new.rules"
    stub_reply check_all.rc 0
    kv wgcui_action saverules; kv_enc wgcui_rules "$T/new.rules"
    run_ev; assert_rc 0 "saverules at ro"
    same_text "$WGC_DIR/rules" "$T/new.rules" || fail "rules not written"
    log_has "wgc.sh check all" "ro"
    assert_not_called "start all" "ro"
    assert_keys_gone "ro"; assert_json "ro"
}

t_U18() {
    set_level full
    put_conf 2 full
    kv wgcui_action deleteconf; kv wgcui_target 2
    run_ev; assert_rc 0 "deleteconf"
    assert_called_once "stop 2" "deleteconf"
    [ ! -e "$WGC_DIR/wgc2.conf" ] || fail "wgc2.conf still exists"
    assert_keys_gone "deleteconf"; assert_json "deleteconf"
}

t_U19() {
    set_level full
    kv wgcui_action confirm
    run_ev; assert_rc 0 "confirm"
    assert_called_once "confirm" "confirm"; assert_keys_gone "confirm"
    reseed
    kv wgcui_action stop; kv wgcui_target all
    run_ev; assert_rc 0 "stop all"
    assert_called_once "stop all" "stop all"; assert_keys_gone "stop all"
    reseed
    kv wgcui_action check; kv wgcui_target 3
    run_ev; assert_rc 0 "check 3"
    assert_called_once "check 3" "check 3"; assert_keys_gone "check 3"
    assert_not_called "start 3" "check 3"
    assert_json "check 3"
}

t_U20() {
    cp "$FIX/leases" "$WGCUI_LEASES"; cp "$FIX/syslog" "$WGCUI_SYSLOG"
    kv wgcui_action refresh
    run_ev; assert_rc 0 "refresh"
    assert_json "hostile data"
    [ "$(tr -d '\11\12\15\40-\176' < "$SJS" | wc -c | tr -d ' ')" = 0 ] || fail "status.js has bytes outside TAB/LF/CR/0x20-0x7E"
    grep -q '<script' "$SJS" && fail "raw <script survived in status.js"
    jflat < "$SJS" > "$T/flat" 2>/dev/null
    n=$(grep -c '^devices\[[0-9]*\]\.ip=' "$T/flat")
    [ "$n" = 4 ] || fail "devices has $n entries, expected 4"
    grep -q '^devices\[[0-9]*\]\.name="scriptalert1script"$' "$T/flat" || fail "name <script>... not reduced to scriptalert1script"
    grep -q '^devices\[[0-9]*\]\.name="abcdefghijabcdefghijabcdefghijab"$' "$T/flat" || fail "40-char name not cut to 32"
    grep -q '^devices\[[0-9]*\]\.name="\*"' "$T/flat" && fail "name * kept"
    grep -q '^devices\[[0-9]*\]\.ip="192.168.2.11"$' "$T/flat" || fail "device ip missing"
    n=$(grep -c '^log\[[0-9]*\]=' "$T/flat")
    [ "$n" = 20 ] || fail "log has $n entries, expected 20"
    grep -q '^log\[[0-9]*\]=.*event number 30' "$T/flat" || fail "newest wgc line missing from log"
    grep '^log\[' "$T/flat" | awk 'length($0) > 210 { f = 1 } END { exit f ? 1 : 0 }' || fail "a log entry is longer than 200 characters"
    assert_keys_gone "hostile data"
}

t_U21() {
    set_level full
    put_conf 1 split
    stub_reply status_1.rc 1
    stub_reply status_1.out 'wgc1: DEGRADED - interface up but missing: iptables markin, endpoint rule 11301'
    kv wgcui_action refresh
    run_ev; assert_rc 0 "refresh"
    assert_json "degraded"
    assert_tv 1 state '"degraded"' "degraded"
    assert_tv 1 'missing[0]' '"iptables markin"' "degraded"
    assert_tv 1 'missing[1]' '"endpoint rule 11301"' "degraded"
    [ -z "$(tv 1 'missing[2]')" ] || fail "degraded: more than two missing entries"
}

t_U22() {
    holder_start
    mkdir "$WGC_RUN_DIR/uilock"; echo "$HOLDER" > "$WGC_RUN_DIR/uilock/pid"
    set_level full
    kv wgcui_action start; kv wgcui_target 1
    run_ev; assert_rc 0 "busy"
    assert_json "busy"; assert_jv busy true "busy"
    assert_noact "busy"; assert_keys_gone "busy"
    [ -d "$WGC_RUN_DIR/uilock" ] || fail "live uilock was removed"
    [ "$(cat "$WGC_RUN_DIR/uilock/pid" 2>/dev/null)" = "$HOLDER" ] || fail "live uilock pid changed"
    holder_stop
}

t_U23() {
    tok=0123456789abcdef0123456789abcdef
    printf '%s %s\n' "$tok" 2 > "$WGC_RUN_DIR/wgc.pending"
    mkdir "$T/fake"
    cat > "$T/fake/wgc.sh" <<'EOF'
#!/bin/sh
# stands in for a try watchdog: only its argv matters
trap 'kill $c 2>/dev/null; exit 0' TERM
/bin/sleep 60 &
c=$!
wait
EOF
    sh "$T/fake/wgc.sh" __watchdog "$tok" 2 300 </dev/null >/dev/null 2>&1 &
    FAKE=$!
    /bin/sleep 0.3
    kv wgcui_action refresh
    run_ev; assert_rc 0 "refresh with watchdog"
    assert_json "with watchdog"
    assert_jv pending_try.target '"2"' "with watchdog"
    assert_jv pending_try.seconds 300 "with watchdog"
    fake_stop
    reseed
    kv wgcui_action refresh
    run_ev; assert_rc 0 "refresh without watchdog"
    assert_json "without watchdog"
    assert_jv pending_try.target '"2"' "without watchdog"
    assert_jv pending_try.seconds null "without watchdog"
}

t_U24() {
    kv wgcui_evil x
    kv wgcui_action refresh
    run_ev; assert_rc 0 "refresh with a foreign key"
    log_has "wgc.sh status 1" "refresh"
    assert_noact "refresh"
    assert_json "foreign key"; assert_jv last.action '"refresh"' "foreign key"
    assert_keys_gone "foreign key"
}

t_U25() {
    grep -v 'Advanced_VPNClient_Content' "$FIX/menuTree.js" > "$WGCUI_MENUTREE"
    run install; assert_rc 0 "install"
    [ "$(menu_after 'url: "Advanced_SwitchCtrl_Content.asp"')" = "$(OUR_LINE 1)" ] || fail "fallback: menu line not right after Advanced_SwitchCtrl_Content.asp"
    [ "$(menu_count 'tabName: "WireGuard Client"')" = 1 ] || fail "menu has $(menu_count 'tabName: "WireGuard Client"') entries"
}

t_U26() {
    set_level full
    put_conf 1 split
    printf '%s\n' 'wgc1 up' > "$STUB_STATE/links"
    export STUB_WG_RX=1234 STUB_WG_TX=5678
    stub_reply status_1.out 'wgc1: up'
    kv wgcui_action refresh
    run_ev; assert_rc 0 "refresh"
    assert_json "rx/tx"
    assert_tv 1 rx 1234 "rx/tx"
    assert_tv 1 tx 5678 "rx/tx"
    assert_tv 1 state '"up"' "rx/tx"
}

t_U30() {
    set_level full
    put_conf 1 split
    printf '%s\n' 'wgc1 192.168.2.5 any' > "$WGC_DIR/rules"
    cp "$WGC_DIR/wgc1.conf" "$T/keep.conf"; cp "$WGC_DIR/rules" "$T/keep.rules"; cp "$WGC_DIR/wgc.sh" "$T/keep.wgc.sh"
    run install; assert_rc 0 "install"
    assert_locked "install"
    run enable-events; assert_rc 0 "enable-events"
    [ -f "$WGCUI_WWW/user1.asp" ] || fail "test setup: install did not create user1.asp"
    kv wgcui_action refresh
    : > "$STUB_LOG"
    run uninstall; assert_rc 0 "uninstall"
    assert_locked "uninstall"
    [ ! -e "$WGCUI_WWW/user1.asp" ] || fail "user1.asp left"
    [ ! -e "$WGCUI_WWW/user1.title" ] || fail "user1.title left"
    [ ! -e "$WGCUI_WWW/wgc" ] || fail "webdir left"
    [ "$(menu_count 'tabName: "WireGuard Client"')" = 0 ] || fail "menu still has our line"
    cmp -s "$WGCUI_MENUTREE" "$FIX/menuTree.js" || fail "menu is not back to the original"
    for f in post-mount service-event; do
        [ "$(grep -c '# wgc$' "$WGCUI_SCRIPTS/$f")" = 0 ] || fail "$f still has a '# wgc' line"
        cmp -s "$WGCUI_SCRIPTS/$f" "$T/$f.seed" || fail "$f is not back to the original"
    done
    cmp -s "$WGCUI_SCRIPTS/firewall-start" "$T/firewall-start.seed" || fail "firewall-start changed"
    assert_keys_gone "uninstall"
    [ ! -e "$WGC_DIR/wgcui.level" ] || fail "wgcui.level left"
    cmp -s "$WGC_DIR/wgc.sh" "$T/keep.wgc.sh" || fail "wgc.sh changed"
    cmp -s "$WGC_DIR/wgc1.conf" "$T/keep.conf" || fail "wgc1.conf changed"
    cmp -s "$WGC_DIR/rules" "$T/keep.rules" || fail "rules changed"
}

t_U27() {
    set_level full
    printf '%s\n' 'wgc1 192.168.2.5 any # tv' '# just a comment' > "$WGC_DIR/rules"
    kv wgcui_action refresh
    run_ev; assert_rc 0 "refresh"
    assert_json "rules comment"
    jflat < "$SJS" > "$T/flat" 2>/dev/null
    n=$(grep -c '^rules\[[0-9]*\]\.src=' "$T/flat")
    [ "$n" = 1 ] || fail "rules has $n entries, expected 1"
    grep -q '^rules\[[0-9]*\]\.src="192.168.2.5"$' "$T/flat" || fail "rule source 192.168.2.5 missing"
    grep -q '^rules\[[0-9]*\]\.dst="any"$' "$T/flat" || fail "rule destination any missing"
    reseed
    printf '%s\n' 'wgc1 192.168.2.5 any' > "$T/posted.rules"
    stub_reply check_all.rc 0
    kv wgcui_action saverules; kv_enc wgcui_rules "$T/posted.rules"
    run_ev; assert_rc 0 "saverules"
    same_text "$WGC_DIR/rules" "$T/posted.rules" || fail "rules file is not just the rule without comments"
    grep -q '#' "$WGC_DIR/rules" && fail "a comment survived in rules"
}

t_U28() {
    set_level full
    put_conf 1 split
    cp "$WGC_DIR/wgc1.conf" "$T/old.conf"
    cp "$WGC_DIR/wgc.sh" "$T/plain.wgc.sh"
    cat > "$WGC_DIR/wgc.sh" <<EOF
#!/bin/sh
if [ "\$1" = check ]; then : > "$T/check.started"; /bin/sleep 3; fi
exec sh "$T/plain.wgc.sh" "\$@"
EOF
    chmod 755 "$WGC_DIR/wgc.sh"
    kv wgcui_action saveconf; kv wgcui_target 1; kv_enc wgcui_conf "$ROOT/tests/fixtures/full.conf"
    ${TEST_SH:-sh} "$SCRIPT" service_event start wgcui > "$T/out" 2>&1 &
    hp=$!
    i=0
    while [ ! -f "$T/check.started" ] && [ $i -lt 100 ]; do /bin/sleep 0.1; i=$((i + 1)); done
    [ -f "$T/check.started" ] || fail "handler never reached check"
    kill -9 "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
    /bin/sleep 3.5          # let the orphaned slow check finish
    cp "$T/plain.wgc.sh" "$WGC_DIR/wgc.sh"; chmod 755 "$WGC_DIR/wgc.sh"
    cmp -s "$WGC_DIR/wgc1.conf" "$T/old.conf" && fail "test setup: the new conf was not in place at kill time"
    kv wgcui_action refresh
    run_ev; assert_rc 0 "refresh after kill"
    cmp -s "$WGC_DIR/wgc1.conf" "$T/old.conf" || fail "old conf not restored"
    [ ! -e "$WGC_DIR/wgc1.conf.prev" ] || fail ".prev left behind"
    [ ! -e "$WGC_RUN_DIR/uilock" ] || fail "uilock left behind"
    assert_keys_gone "after kill"
    assert_json "after kill"
}

t_U29() {
    set_level full
    cp "$T/settings.seed" "$T/settings.real"
    printf '%s\n' 'wgcui_action refresh' >> "$T/settings.real"
    cp "$T/settings.real" "$T/settings.copy"
    rm -f "$WGCUI_SETTINGS"; ln -s "$T/settings.real" "$WGCUI_SETTINGS"
    run_ev; assert_rc 0 "symlink settings"
    assert_json "symlink"; assert_msg "symlink" "symlink"
    assert_noact "symlink"
    cmp -s "$T/settings.real" "$T/settings.copy" || fail "the real settings file was changed"
    [ -L "$WGCUI_SETTINGS" ] || fail "the symlink was replaced"
}

t_U31() {
    set_level full
    stub_reply check_1.rc 0
    # (a) the page's own encoding: leading/trailing | and % survive byte for byte
    printf '%s\n' '|lead and trail|' 'a=%41 b=100% c' '||' > "$T/p.conf"
    kv wgcui_action saveconf; kv wgcui_target 1; kv_enc wgcui_conf "$T/p.conf"
    run_ev; assert_rc 0 "round trip"
    same_text "$WGC_DIR/wgc1.conf" "$T/p.conf" || fail "round trip: conf differs from the original"
    assert_keys_gone "round trip"
    # (b) raw value: only %25 %7C %0A decode; %41 and a bare % at the end stay literal
    reseed; rm -f "$WGC_DIR/wgc1.conf"
    kv wgcui_action saveconf; kv wgcui_target 1; kv wgcui_conf '|lead%41%2541%7C%0Atail|%'; kv wgcui_len "$(printf '%s' '|lead%41%2541%7C%0Atail|%' | wc -c | tr -d ' ')"
    run_ev; assert_rc 0 "raw decode"
    printf '%s\n' '|lead%41%41|' 'tail|%' > "$T/want.conf"
    same_text "$WGC_DIR/wgc1.conf" "$T/want.conf" || fail "raw decode: got '$(tr '\n' '/' < "$WGC_DIR/wgc1.conf" 2>/dev/null)', expected '|lead%41%41|/tail|%/'"
    assert_keys_gone "raw decode"
}

t_U32() {
    grep -v -e 'Advanced_VPNClient_Content' -e 'Advanced_SwitchCtrl_Content' "$FIX/menuTree.js" > "$WGCUI_MENUTREE"
    cp "$WGCUI_MENUTREE" "$T/menu.noanchor"
    run install
    [ "$RC" != 0 ] || fail "install succeeded without a menu anchor"
    [ ! -e "$WGCUI_WWW/user1.asp" ] || fail "user1.asp left behind"
    [ ! -e "$WGCUI_WWW/user1.title" ] || fail "user1.title left behind"
    cmp -s "$WGCUI_MENUTREE" "$T/menu.noanchor" || fail "menu changed"
    cmp -s "$WGCUI_SCRIPTS/post-mount" "$T/post-mount.seed" || fail "post-mount changed"
}

t_U33() {
    touch -t 202001010000 "$WGCUI_SETTINGS"
    ls -li "$WGCUI_SETTINGS" > "$T/ls.before"
    run_ev; assert_rc 0 "no keys"
    assert_msg "no action" "no keys"
    ls -li "$WGCUI_SETTINGS" > "$T/ls.after"
    cmp -s "$T/ls.before" "$T/ls.after" || fail "settings file inode/mtime changed: $(cat "$T/ls.before") -> $(cat "$T/ls.after")"
    cmp -s "$WGCUI_SETTINGS" "$T/settings.seed" || fail "settings content changed"
}

t_U34() {
    set_level full
    kv wgcui_action refresh
    run_ev; assert_rc 0 "refresh"
    grep -aq '^logger' "$STUB_LOG" && fail "logger was called for refresh"
    reseed
    kv wgcui_action start; kv wgcui_target 1
    run_ev; assert_rc 0 "start"
    grep -aq '^logger' "$STUB_LOG" || fail "logger was not called for start"
}

t_U35() {
    set_level full
    cp "$ROOT/tests/fixtures/full.conf" "$T/x.conf"      # the "new" (unchecked) conf
    cp "$ROOT/tests/fixtures/split.conf" "$T/y.conf"     # the old one saved in .prev
    # (a) no marker: a .prev is somebody's file, nothing is touched
    cp "$T/x.conf" "$WGC_DIR/wgc1.conf"; chmod 600 "$WGC_DIR/wgc1.conf"; cp "$T/y.conf" "$WGC_DIR/wgc1.conf.prev"
    kv wgcui_action refresh
    run_ev; assert_rc 0 "(a) refresh"
    cmp -s "$WGC_DIR/wgc1.conf" "$T/x.conf" || fail "(a) conf changed without a marker"
    cmp -s "$WGC_DIR/wgc1.conf.prev" "$T/y.conf" || fail "(a) .prev changed without a marker"
    # (b) marker + .prev: restored
    reseed
    printf '%s\n' wgc1.conf > "$WGC_DIR/.inprogress"
    kv wgcui_action refresh
    run_ev; assert_rc 0 "(b) refresh"
    cmp -s "$WGC_DIR/wgc1.conf" "$T/y.conf" || fail "(b) conf not restored from .prev"
    [ ! -e "$WGC_DIR/wgc1.conf.prev" ] || fail "(b) .prev left behind"
    [ ! -e "$WGC_DIR/.inprogress" ] || fail "(b) marker left behind"
    # (c) marker + oversized .prev: not restored, kept, reported
    reseed
    cp "$T/x.conf" "$WGC_DIR/wgc1.conf"
    awk 'BEGIN { for (i = 0; i < 1000; i++) print "# 0123456789012345678901234567890123456789012345678901234567890123456" }' > "$WGC_DIR/wgc1.conf.prev"
    cp "$WGC_DIR/wgc1.conf.prev" "$T/big.prev"
    [ "$(wc -c < "$T/big.prev" | tr -d ' ')" -gt 65536 ] || fail "(c) test setup: .prev too small"
    printf '%s\n' wgc1.conf > "$WGC_DIR/.inprogress"
    kv wgcui_action refresh
    run_ev; assert_rc 0 "(c) refresh"
    cmp -s "$WGC_DIR/wgc1.conf" "$T/x.conf" || fail "(c) conf changed"
    cmp -s "$WGC_DIR/wgc1.conf.prev" "$T/big.prev" || fail "(c) oversized .prev not kept"
    assert_json "(c)"; assert_msg "prev" "(c)"
}

t_U36() {
    run install; assert_rc 0 "install"
    [ "$(menu_count 'tabName: "WireGuard Client"')" = 1 ] || fail "test setup: menu has $(menu_count 'tabName: "WireGuard Client"') entries after install"
    grep -v -e 'Advanced_VPNClient_Content' -e 'Advanced_SwitchCtrl_Content' "$WGCUI_MENUTREE" > "$T/menu.noanchor"
    cp "$T/menu.noanchor" "$WGCUI_MENUTREE"
    run install
    assert_rc 1 "install without anchors"
    [ "$(menu_count 'tabName: "WireGuard Client"')" = 1 ] || fail "our existing menu line was lost or duplicated: $(menu_count 'tabName: "WireGuard Client"') entries"
}

t_U37() {
    printf '%s\n' 'wgc1 192.168.2.5 any' 'wgc2 192.168.2.6 any extra' > "$WGC_DIR/rules"
    kv wgcui_action refresh
    run_ev; assert_rc 0 "refresh"
    assert_json "rules_skipped"
    jflat < "$SJS" > "$T/flat" 2>/dev/null
    n=$(grep -c '^rules\[[0-9]*\]\.src=' "$T/flat")
    [ "$n" = 1 ] || fail "rules has $n entries, expected 1"
    grep -q '^rules\[[0-9]*\]\.src="192.168.2.5"$' "$T/flat" || fail "the valid rule is missing"
    grep -q '192.168.2.6' "$T/flat" && fail "the 4-field line is in status.js"
    assert_jv rules_skipped 1 "4-field line"
    reseed
    printf '%s\n' 'wgc1 192.168.2.5 any' '# comment' '' > "$WGC_DIR/rules"
    kv wgcui_action refresh
    run_ev; assert_rc 0 "refresh 2"
    assert_jv rules_skipped 0 "all lines fine"
}

t_U38() {
    set_level full
    stub_reply check_1.rc 0; stub_reply check_all.rc 0
    printf '%s\n' '[Interface]' 'Address = 10.0.0.2/32' '|pipe|' '100%' > "$T/l.conf"
    printf '%s\n' 'wgc1 192.168.2.5 any' 'wgc2 192.168.2.0/24 10.0.0.0/8' > "$T/l.rules"
    cl=$(enc_len "$T/l.conf"); rl=$(enc_len "$T/l.rules")
    # saveconf: correct length accepted
    kv wgcui_action saveconf; kv wgcui_target 1; kv_enc_raw wgcui_conf "$T/l.conf"; kv wgcui_len "$cl"
    run_ev; assert_rc 0 "saveconf len ok"
    same_text "$WGC_DIR/wgc1.conf" "$T/l.conf" || fail "saveconf with a correct wgcui_len was not accepted"
    assert_keys_gone "saveconf len ok"
    # saveconf: off by one (both ways), missing, garbage
    for v in $((cl + 1)) $((cl - 1)) none 12a; do
        reseed; rm -f "$WGC_DIR/wgc1.conf"
        kv wgcui_action saveconf; kv wgcui_target 1; kv_enc_raw wgcui_conf "$T/l.conf"
        [ "$v" = none ] || kv wgcui_len "$v"
        run_ev; assert_rc 0 "saveconf len $v"
        assert_json "saveconf len $v"
        assert_noconf_files "saveconf len $v"; assert_noact "saveconf len $v"; assert_keys_gone "saveconf len $v"
        case $v in none) ;; *) assert_msg "length" "saveconf len $v" ;; esac
    done
    # saverules: same
    reseed; rm -f "$WGC_DIR/rules"
    kv wgcui_action saverules; kv_enc_raw wgcui_rules "$T/l.rules"; kv wgcui_len "$rl"
    run_ev; assert_rc 0 "saverules len ok"
    same_text "$WGC_DIR/rules" "$T/l.rules" || fail "saverules with a correct wgcui_len was not accepted"
    assert_keys_gone "saverules len ok"
    for v in $((rl + 1)) $((rl - 1)) none 12a; do
        reseed; rm -f "$WGC_DIR/rules"
        kv wgcui_action saverules; kv_enc_raw wgcui_rules "$T/l.rules"
        [ "$v" = none ] || kv wgcui_len "$v"
        run_ev; assert_rc 0 "saverules len $v"
        assert_json "saverules len $v"
        [ ! -e "$WGC_DIR/rules" ] || fail "saverules len $v: rules written"
        assert_noact "saverules len $v"; assert_keys_gone "saverules len $v"
        case $v in none) ;; *) assert_msg "length" "saverules len $v" ;; esac
    done
}

t_U39() {
    printf '%s\n' '_Diversion_page user1.asp' 'foreign_quote say "hi" and C:\path' >> "$T/settings.seed"
    cp "$T/settings.seed" "$WGCUI_SETTINGS"
    kv wgcui_evil x
    kv wgcui_action refresh
    run_ev; assert_rc 0 "refresh"
    assert_json "foreign_settings"
    jflat < "$SJS" > "$T/flat" 2>/dev/null
    grep -qxF 'foreign_settings.uidivstats_version_local="v3.0.4"' "$T/flat" || fail "uidivstats_version_local missing"
    grep -qxF 'foreign_settings.uiscribe_version_local="v2.1"' "$T/flat" || fail "uiscribe_version_local missing"
    grep -qxF 'foreign_settings._Diversion_page="user1.asp"' "$T/flat" || fail "_Diversion_page missing"
    grep -qxF 'foreign_settings.foreign_quote="say \"hi\" and C:\\path"' "$T/flat" || fail "value with a quote and a backslash missing or not escaped"
    grep -q '^foreign_settings\.wgcui_' "$T/flat" && fail "a wgcui_ key is in foreign_settings"
    n=$(grep -c '^foreign_settings\.' "$T/flat")
    [ "$n" = 4 ] || fail "foreign_settings has $n keys, expected 4"
    assert_keys_gone "foreign_settings"
}

t_U40() {
    set_level full
    put_conf 1 split; put_conf 2 full
    printf '%s\n' 'wgc1 up' > "$STUB_STATE/links"
    stub_reply check_all.rc 0
    printf '%s\n' 'wgc1 192.168.2.233 any' 'wgc2 192.168.2.0/24 10.0.0.0/8' > "$T/new.rules"
    kv wgcui_action saverules; kv_enc wgcui_rules "$T/new.rules"
    run_ev; assert_rc 0 "saverules"
    a=$(grep -an '^wgc\.sh check all$' "$STUB_LOG" | head -1 | cut -d: -f1)
    b=$(grep -an '^wgc\.sh start 1$' "$STUB_LOG" | head -1 | cut -d: -f1)
    [ -n "$a" ] || fail "no 'check all'"
    [ -n "$b" ] || fail "no 'start 1' (wgc1 exists)"
    [ -z "$a" ] || [ -z "$b" ] || [ "$a" -lt "$b" ] || fail "'start 1' before 'check all'"
    assert_not_called "start 2" "wgc2 has no interface"
    assert_not_called "start all" "saverules"
    assert_jv last.rc 0 "saverules"
    assert_keys_gone "saverules"
    # no interface at all: nothing is started
    reseed; : > "$STUB_STATE/links"
    kv wgcui_action saverules; kv_enc wgcui_rules "$T/new.rules"
    run_ev; assert_rc 0 "saverules without links"
    log_has "wgc.sh check all" "no links"
    n=$(grep -ac '^wgc\.sh start' "$STUB_LOG")
    [ "$n" = 0 ] || fail "no links: $n start call(s)"
    assert_jv last.rc 0 "no links"
}

t_U41() {
    put_conf 1 split
    printf '%s\n' 'wgc1: conf OK' '  interface    wgc1' '  peer         AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' '  endpoint     203.0.113.10:51820' '  allowed      0.0.0.0/0' > "$STUB_WGC_DIR/check_1.out"
    kv wgcui_action refresh
    run_ev; assert_rc 0 "refresh"
    assert_json "endpoint"
    assert_tv 1 state '"down"' "endpoint"
    assert_tv 1 endpoint '"203.0.113.10:51820"' "endpoint"
}

STUN1='ministun -t 4000 -c 1 -i wgc1 stun.l.google.com:19302'
STUN2='ministun -t 4000 -c 1 -i wgc1 stun.stunprotocol.org'
stun_count() { grep -ac '^ministun ' "$STUB_LOG"; }
cache1() { printf '%s' "$WGC_RUN_DIR/wgc1.exitip"; }

t_U42() {
    set_level full
    printf '%s\n' 'wgc1 1400 up' > "$STUB_STATE/links"
    kv wgcui_action start; kv wgcui_target 1
    run_ev; assert_rc 0 "start 1"
    assert_called_once "start 1" "start 1"
    n=$(grep -Fxc -- "$STUN1" "$STUB_LOG")
    [ "$n" = 1 ] || fail "start: '$STUN1' called $n times, expected 1"
    [ "$(stun_count)" = 1 ] || fail "start: $(stun_count) ministun calls, expected 1"
    assert_json "start"
    assert_tv 1 exit_ip '"203.0.113.77"' "start"
    case $(tv 1 exit_ip_age) in ''|*[!0-9]*) fail "start: exit_ip_age is '$(tv 1 exit_ip_age)', expected a number" ;; esac
    [ -f "$(cache1)" ] || fail "start: cache file missing"
    # every refresh looks up again (no cache rule): exactly one more call
    reseed
    kv wgcui_action refresh
    run_ev; assert_rc 0 "refresh"
    [ "$(stun_count)" = 1 ] || fail "refresh: $(stun_count) ministun calls, expected 1"
    assert_tv 1 exit_ip '"203.0.113.77"' "refresh"
}

t_U43() {
    printf '%s\n' 'wgc1 1400 up' > "$STUB_STATE/links"
    # (a) ministun fails: both servers tried
    export STUB_FAIL='^ministun '
    kv wgcui_action refresh
    run_ev; assert_rc 0 "ministun fails"
    unset STUB_FAIL
    assert_json "ministun fails"; assert_tv 1 exit_ip '""' "ministun fails"
    [ "$(stun_count)" = 2 ] || fail "ministun fails: $(stun_count) ministun calls, expected 2"
    grep -Fxq -- "$STUN1" "$STUB_LOG" || fail "ministun fails: first server not tried"
    grep -Fxq -- "$STUN2" "$STUB_LOG" || fail "ministun fails: second server not tried"
    [ ! -e "$(cache1)" ] || fail "ministun fails: cache file written"
    # (b) garbage output, (c) not an address
    for o in '<html>oops' '999.1.1.1'; do
        reseed; rm -f "$(cache1)"
        export STUB_STUN_OUT="$o"
        kv wgcui_action refresh
        run_ev; assert_rc 0 "ministun output $o"
        unset STUB_STUN_OUT
        assert_json "ministun output $o"; assert_tv 1 exit_ip '""' "ministun output $o"
        [ ! -e "$(cache1)" ] || fail "ministun output $o: cache file written"
    done
    # (d) tunnel down: no lookup at all
    reseed; rm -f "$(cache1)"; : > "$STUB_STATE/links"
    kv wgcui_action refresh
    run_ev; assert_rc 0 "tunnel down"
    [ "$(stun_count)" = 0 ] || fail "tunnel down: a lookup was made"
    assert_tv 1 exit_ip '""' "tunnel down"
    # (e) no ministun on PATH: no lookup of any kind, exit_ip empty
    reseed; rm -f "$(cache1)"
    printf '%s\n' 'wgc1 1400 up' > "$STUB_STATE/links"
    mkdir "$T/nomini"
    for f in "$HERE"/stubs/*; do [ "${f##*/}" = ministun ] || cp "$f" "$T/nomini/"; done
    # tripwire: any other lookup tool is logged and fails (never reaches the network)
    printf '%s\n' '#!/bin/sh' 'printf "%s\n" "curl $*" >> "${STUB_LOG:?}"' 'exit 127' > "$T/nomini/curl"; chmod 755 "$T/nomini/curl"
    OLDPATH=$PATH
    PATH="$T/nomini:$ROOT/tests/stubs:$BASEPATH"; export PATH
    kv wgcui_action refresh
    run_ev; assert_rc 0 "no ministun"
    PATH=$OLDPATH; export PATH
    [ "$(stun_count)" = 0 ] || fail "no ministun: ministun was called"
    grep -aq "^curl" "$STUB_LOG" && fail "no ministun: another lookup tool was called"
    assert_json "no ministun"; assert_tv 1 exit_ip '""' "no ministun"
    reseed
    set_level full
    PATH="$T/nomini:$ROOT/tests/stubs:$BASEPATH"; export PATH
    kv wgcui_action start; kv wgcui_target 1
    run_ev; assert_rc 0 "start without ministun"
    PATH=$OLDPATH; export PATH
    assert_json "start without ministun"; assert_tv 1 exit_ip '""' "start without ministun"
    [ "$(stun_count)" = 0 ] || fail "start without ministun: ministun was called"
}

t_U44() {
    set_level full
    printf '%s\n' 'wgc1 1400 up' > "$STUB_STATE/links"
    kv wgcui_action exitip; kv wgcui_target 1
    run_ev; assert_rc 0 "exitip"
    assert_json "exitip"; assert_msg "unknown action" "exitip"
    [ "$(stun_count)" = 0 ] || fail "exitip: ministun was called"
    assert_noact "exitip"; assert_keys_gone "exitip"
    reseed
    kv wgcui_action start; kv wgcui_target 1
    run_ev; assert_rc 0 "start 1"
    [ -f "$(cache1)" ] || fail "start 1: cache file missing"
    reseed
    kv wgcui_action stop; kv wgcui_target 1
    run_ev; assert_rc 0 "stop 1"
    assert_called_once "stop 1" "stop 1"
    [ ! -e "$(cache1)" ] || fail "stop 1: cache file still there"
}

# static guard: the router's ash has no `command`, `type` or `hash` builtin (BusyBox in the container does).
# Prints offending lines (number:text) of $1: comment lines are skipped, the word must be at a command position.
nobuiltin_lines() {
    awk '/^[[:space:]]*#/ { next } { print NR ":" $0 }' "$1" > "$T/nb.in" 2>/dev/null
    grep -E '^[0-9]+:(([^#]*[;&|({`!])|([^#]*[[:space:]])?(then|do|else|if|elif|while|until))?[[:space:]]*(command|type|hash)[[:space:]]' "$T/nb.in"
    [ $? -le 1 ] || echo "0:guard error (grep failed)"
}

t_U45() {
    nobuiltin_lines "$SCRIPT" > "$T/nb.out"
    [ ! -s "$T/nb.out" ] || fail "builtin missing on the router ash used: $(head -8 "$T/nb.out" | tr '\n' '|')"
}

t_U46() {
    printf '%s\n' \
        'wgc1 192.168.1.50 any # TV: Netflix through Germany' \
        '#off wgc2 192.168.1.51 any # Phone: only when travelling' \
        'wgc3 any 198.51.100.0/24' \
        '# plain comment line' \
        '#off wgc9 x' > "$WGC_DIR/rules"
    kv wgcui_action refresh
    run_ev; assert_rc 0 "refresh"
    assert_json "rule metadata"
    jflat < "$SJS" > "$T/flat" 2>/dev/null
    n=$(grep -c '^rules\[[0-9]*\]\.src=' "$T/flat")
    [ "$n" = 3 ] || fail "rules has $n entries, expected 3"
    assert_jv 'rules[0].tunnel' '"wgc1"' "rule 0"; assert_jv 'rules[0].src' '"192.168.1.50"' "rule 0"
    assert_jv 'rules[0].dst' '"any"' "rule 0"; assert_jv 'rules[0].enabled' true "rule 0"
    assert_jv 'rules[0].name' '"TV"' "rule 0"; assert_jv 'rules[0].desc' '"Netflix through Germany"' "rule 0"
    assert_jv 'rules[1].tunnel' '"wgc2"' "rule 1"; assert_jv 'rules[1].src' '"192.168.1.51"' "rule 1"
    assert_jv 'rules[1].dst' '"any"' "rule 1"; assert_jv 'rules[1].enabled' false "rule 1"
    assert_jv 'rules[1].name' '"Phone"' "rule 1"; assert_jv 'rules[1].desc' '"only when travelling"' "rule 1"
    assert_jv 'rules[2].tunnel' '"wgc3"' "rule 2"; assert_jv 'rules[2].src' '"any"' "rule 2"
    assert_jv 'rules[2].dst' '"198.51.100.0/24"' "rule 2"; assert_jv 'rules[2].enabled' true "rule 2"
    assert_jv 'rules[2].name' '""' "rule 2"; assert_jv 'rules[2].desc' '""' "rule 2"
    assert_jv rules_skipped 1 "malformed #off line"
}

t_U47() {
    printf '%s\n' \
        'wgc1 192.168.1.50 any # TV: Netflix through Germany' \
        '#off wgc2 192.168.1.51 any # Phone: only when travelling' \
        'wgc3 any 198.51.100.0/24' \
        '# plain comment line' > "$T/posted.rules"
    put_conf 1 split
    printf '%s\n' 'wgc1 up' > "$STUB_STATE/links"
    stub_reply check_all.rc 0
    kv wgcui_action saverules; kv_enc wgcui_rules "$T/posted.rules"
    run_ev; assert_rc 0 "saverules at ro"
    cmp -s "$WGC_DIR/rules" "$T/posted.rules" || fail "saved rules differ from the posted text (comments or #off lost)"
    assert_called_once "check all" "saverules at ro"
    n=$(grep -ac '^wgc\.sh start' "$STUB_LOG")
    [ "$n" = 0 ] || fail "start was called $n time(s) at level ro"
    assert_keys_gone "saverules at ro"; assert_json "saverules at ro"
}

# ---------- main ----------

if [ $# -gt 0 ]; then SEL="$*"; else SEL="$ALL"; fi
for id in $SEL; do
    case " $ALL " in
    *" $id "*) ;;
    *) echo "unknown test: $id" >&2; exit 2 ;;
    esac
done

TESTNO=0; pass=0; failed=0
for id in $SEL; do
    TESTNO=$((TESTNO + 1))
    setup
    TFAIL=0; REASONS=
    if [ ! -f "$SCRIPT" ]; then
        fail "router/wgcui.sh does not exist"
    else
        "t_$id" 2> "$T/runner.err"
        [ -n "$UIDEBUG" ] && cat "$T/runner.err" >&2
        grep -a '^UNSUPPORTED' "$STUB_LOG" >> "$T/unsupported" 2>/dev/null
        if [ -s "$T/unsupported" ]; then fail "unsupported command used: $(head -1 "$T/unsupported")"; fi
    fi
    cleanup
    if [ "$TFAIL" = 0 ]; then
        pass=$((pass + 1)); echo "ok $TESTNO - $id $(title "$id")"
    else
        failed=$((failed + 1)); echo "not ok $TESTNO - $id $(title "$id")"
        printf '%s' "$REASONS"
    fi
done
echo "# pass=$pass fail=$failed"
[ "$failed" -eq 0 ]
