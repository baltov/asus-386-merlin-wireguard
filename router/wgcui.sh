#!/bin/sh
# wgcui.sh - web UI page for wgc.sh on Asuswrt-Merlin (addon page + action handler)
#
#   wgcui.sh install          page + menu + web dir + status.js + post-mount line
#   wgcui.sh enable-events    add the service-event line
#   wgcui.sh set-level ro|full
#   wgcui.sh mount            page + menu only (boot, from post-mount)
#   wgcui.sh status           regenerate status.js
#   wgcui.sh service_event start wgcui   handle one action posted by the page
#   wgcui.sh uninstall        undo install + enable-events
#   wgcui.sh help
#
# Exit codes: 0 ok, 1 runtime error, 2 usage. service_event always exits 0
# (the result is in status.js) except on bad usage.
#
# Security: every value from the settings file is untrusted. The action picks a
# fixed case branch; target/seconds must match strict patterns; conf and rules
# text never enters a shell variable (file -> file only); all wgcui_* keys are
# deleted right after reading, on every path.
#
# External commands: awk cat chmod cp cut date dd grep head kill logger md5sum
# mkdir mv ps rm rmdir sed sleep tr wc, plus flock mount umount (install),
# ip wg (status), ministun (exit address through wgcN, as the firmware's
# gettunnelip.sh does for OpenVPN clients; fixed arguments only).
# The firmware lacks mktemp, od, id, and its ash has no "command" builtin
# ("command -v" fails with rc 127): commands are found by walking PATH.

# ---------------------------------------------------------------- settings
WGC_DIR=${WGC_DIR:-/jffs/addons/wgc}
WGC_RUN_DIR=${WGC_RUN_DIR:-/tmp/wgc.run}
WGCUI_SETTINGS=${WGCUI_SETTINGS:-/jffs/addons/custom_settings.txt}
WGCUI_WWW=${WGCUI_WWW:-/www/user}
WGCUI_WEBDIR=${WGCUI_WEBDIR:-$WGCUI_WWW/wgc}
WGCUI_MENUTREE=${WGCUI_MENUTREE:-/tmp/menuTree.js}
WGCUI_MENUTREE_SRC=${WGCUI_MENUTREE_SRC:-/www/require/modules/menuTree.js}
WGCUI_SCRIPTS=${WGCUI_SCRIPTS:-/jffs/scripts}
WGCUI_LEASES=${WGCUI_LEASES:-/var/lib/misc/dnsmasq.leases}
WGCUI_SYSLOG=${WGCUI_SYSLOG:-}        # empty: the newer of the two below that exists
WGCUI_SYSLOG_DEFAULTS="/tmp/syslog.log /opt/var/log/messages"
WGCUI_LOCKFILE=${WGCUI_LOCKFILE:-/tmp/addonwebui.lock}
WGCUI_TITLE=${WGCUI_TITLE:-WireGuard Client}
WGCUI_STUN_SERVERS=${WGCUI_STUN_SERVERS:-stun.l.google.com:19302 stun.stunprotocol.org}

WGCUI_CONF_MAX=4096       # bytes, decoded conf
WGCUI_RULES_MAX=8192      # bytes, decoded rules
WGCUI_TRY_MIN=10
WGCUI_TRY_MAX=3600
WGCUI_LOG_LINES=20
WGCUI_LOG_WIDTH=200
WGCUI_NAME_WIDTH=32
WGCUI_PREV_MAX=65536      # a larger .prev is never restored automatically
WGCUI_STUN_TIMEOUT=4000   # ministun -t, milliseconds
WGCUI_EXITIP_DROP=3600    # a failed ask drops a cached value older than this
WGCUI_PAGE_MARK='<!-- wgcui-page -->'   # with our .title: an older version of our page

# lines this script owns in /jffs/scripts (fixed paths on the router by design)
PM_LINE='/jffs/addons/wgc/wgcui.sh mount >/dev/null 2>&1 & # wgc'
SE_LINE='if [ "$2" = "wgcui" ]; then /jffs/addons/wgc/wgcui.sh service_event "$@" & fi # wgc'
OUR_LINES_RE='wgcui\.sh.*# wgc$'

LC_ALL=C
export LC_ALL
umask 022
set -f

case $0 in
/*) SELF=$0 ;;
*) SELF=$(pwd)/$0 ;;
esac
WGC_SH="$WGC_DIR/wgc.sh"
HAVE_LOCK=0
WORK=
CONF_TMP= RULES_TMP=
RB_FILE= RB_PREV= RB_HADPREV=0
IP_FORCE= IP_DONE=    # exit address: slots to ask ("all" = every up tunnel), slots asked
L_ACTION= L_TARGET= L_RC=0 L_WHEN=

# ---------------------------------------------------------------- helpers
warn() { printf '%s\n' "wgcui: $*" >&2; }
die() { warn "$*"; exit 1; }
die_usage() { warn "$*"; usage >&2; exit 2; }

usage() {
    cat <<'EOF'
usage: wgcui.sh install | enable-events | set-level ro|full | mount | status
                | service_event start wgcui | uninstall | help
EOF
}

# every path setting: absolute, one line
check_settings() {
    local v
    for v in "$WGC_DIR" "$WGC_RUN_DIR" "$WGCUI_SETTINGS" "$WGCUI_WWW" "$WGCUI_WEBDIR" \
        "$WGCUI_MENUTREE" "$WGCUI_MENUTREE_SRC" "$WGCUI_SCRIPTS" "$WGCUI_LEASES" "$WGCUI_LOCKFILE"; do
        case $v in
        /?*) ;;
        *) die_usage "paths must be absolute: '$v'" ;;
        esac
        case $v in *'
'*) die_usage "invalid path" ;; esac
    done
    case $WGCUI_SYSLOG in
    ''|/?*) ;;
    *) die_usage "WGCUI_SYSLOG must be an absolute path" ;;
    esac
    case $WGCUI_TITLE in
    ''|*[!A-Za-z0-9\ ._-]*) die_usage "WGCUI_TITLE may only contain A-Z a-z 0-9 space . _ -" ;;
    esac
    [ ${#WGCUI_TITLE} -le 40 ] || die_usage "WGCUI_TITLE is too long"
    case $WGCUI_STUN_SERVERS in *'
'*) die_usage "invalid WGCUI_STUN_SERVERS" ;; esac
    for v in $WGCUI_STUN_SERVERS; do
        printf '%s\n' "$v" | grep -Eq '^[A-Za-z0-9.-]+(:[0-9]{1,5})?$' ||
            die_usage "WGCUI_STUN_SERVERS: invalid server '$v'"
    done
}

# private run dir: created 700; a symlink or non-directory is refused (as wgc.sh)
ensure_run_dir() {
    local d
    d=$WGC_RUN_DIR
    if [ -L "$d" ]; then warn "$d is a symlink"; return 1; fi
    [ -e "$d" ] || mkdir -m 700 "$d" 2>/dev/null
    if [ -L "$d" ] || [ ! -d "$d" ]; then warn "$d is not a usable directory"; return 1; fi
    chmod 700 "$d" 2>/dev/null
    return 0
}

fsize() { wc -c < "$1" | tr -d ' '; }

# true if FILE ends with a newline (or is empty)
ends_nl() {
    local s
    s=$(fsize "$1")
    [ "${s:-0}" -gt 0 ] || return 0
    [ "$(dd if="$1" bs=1 skip=$((s - 1)) count=1 2>/dev/null | wc -l | tr -d ' ')" = 1 ]
}

md5_of() { md5sum < "$1" 2>/dev/null | cut -d' ' -f1; }

# ---------------------------------------------------------------- settings keys
# kcount KEY: number of lines for KEY (KEY is one of our constants)
# settings_ok: a regular file, never a symlink (nothing is read or written through one)
settings_ok() { [ -f "$WGCUI_SETTINGS" ] && [ ! -L "$WGCUI_SETTINGS" ]; }
kcount() {
    settings_ok || { echo 0; return; }
    grep -c "^$1 " "$WGCUI_SETTINGS" 2>/dev/null
}
# kget KEY: first value of KEY, at most 64 characters (validated by the caller)
kget() {
    settings_ok || return 0
    grep "^$1 " "$WGCUI_SETTINGS" 2>/dev/null | head -n 1 | cut -d' ' -f2- | cut -c1-64
}
# kfile KEY OUT: value of KEY, decoded, straight into file OUT (never a variable)
kfile() {
    (
        umask 077
        rm -f "$2" "$2.raw" "$2.len"
        settings_ok || exit 1
        grep "^$1 " "$WGCUI_SETTINGS" 2>/dev/null | head -n 1 | cut -d' ' -f2- > "$2.raw" || exit 1
        # byte length of the encoded value as stored (cut adds the one newline)
        n=$(fsize "$2.raw"); [ "${n:-0}" -gt 0 ] && n=$((n - 1))
        printf '%s\n' "${n:-0}" > "$2.len"
        # bytes allowed in the raw value: TAB, LF, CR, 0x20-0x7E (checked before decoding)
        if [ "$(tr -d '\11\12\15\40-\176' < "$2.raw" | wc -c | tr -d ' ')" != 0 ]; then
            rm -f "$2.raw"; exit 3
        fi
        awk "$DECODE_AWK" "$2.raw" > "$2" || { rm -f "$2.raw" "$2"; exit 1; }
        rm -f "$2.raw"
    )
}
# value encoding of the page: %25 -> %, %7C -> |, %0A -> newline; nothing else
# is decoded (%41, a bare % stay literal); one left-to-right pass, no re-decoding
DECODE_AWK='
{
    s = $0; o = ""
    while ((i = index(s, "%")) > 0) {
        o = o substr(s, 1, i - 1); c = substr(s, i + 1, 2)
        if (c == "25") { o = o "%"; s = substr(s, i + 3) }
        else if (c == "7C") { o = o "|"; s = substr(s, i + 3) }
        else if (c == "0A") { o = o "\n"; s = substr(s, i + 3) }
        else { o = o "%"; s = substr(s, i + 1) }
    }
    print o s
}'
# delete every wgcui_* line (only if there is one); other lines stay byte for byte
del_keys() {
    local f t r
    f=$WGCUI_SETTINGS
    settings_ok || return 0
    grep -q '^wgcui_' "$f" 2>/dev/null || return 0
    t="$f.wgcui.$$"
    rm -f "$t"
    cp -p "$f" "$t" 2>/dev/null || { warn "cannot write next to $f"; return 1; }
    grep -v '^wgcui_' "$f" > "$t"; r=$?
    if [ $r -le 1 ] && mv -f "$t" "$f"; then return 0; fi
    rm -f "$t"
    warn "cannot remove wgcui_ keys from $f"
    return 1
}

# action name for display only: [A-Za-z0-9_-], max 32 characters
sanitize_action() { printf '%s' "$1" | tr -cd 'A-Za-z0-9_-' | cut -c1-32; }

valid_target() { case $1 in [1-5]|all) return 0 ;; esac; return 1; }
valid_slot() { case $1 in [1-5]) return 0 ;; esac; return 1; }
valid_secs() {
    case $1 in
    [1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]) ;;
    *) return 1 ;;
    esac
    [ "$1" -ge "$WGCUI_TRY_MIN" ] && [ "$1" -le "$WGCUI_TRY_MAX" ]
}
# file content checks: size and bytes (TAB, LF, CR, 0x20-0x7E)
content_ok() {   # content_ok FILE MAX NAME -> 0 or prints the reason
    local s
    s=$(fsize "$1")
    if [ "${s:-0}" -gt "$2" ]; then printf '%s\n' "$3 too large (max $2 bytes)"; return 1; fi
    if [ "$(tr -d '\11\12\15\40-\176' < "$1" | wc -c | tr -d ' ')" != 0 ]; then
        printf '%s\n' "$3 contains bytes outside printable ASCII"; return 1
    fi
    return 0
}

# len_ok CLAIMED LENFILE: wgcui_len (1-5 digits) equals the stored encoded length
len_ok() {
    local n
    case $1 in
    [0-9]|[0-9][0-9]|[0-9][0-9][0-9]|[0-9][0-9][0-9][0-9]|[0-9][0-9][0-9][0-9][0-9]) ;;
    *) return 1 ;;
    esac
    n=
    read -r n < "$2" 2>/dev/null
    case $n in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -eq "$n" ]
}

read_level() {
    local l
    l=
    if [ -f "$WGC_DIR/wgcui.level" ] && [ ! -L "$WGC_DIR/wgcui.level" ]; then
        read -r l < "$WGC_DIR/wgcui.level" 2>/dev/null
    fi
    if [ "$l" = full ]; then echo full; else echo ro; fi
}

# ---------------------------------------------------------------- handler lock
# mkdir lock with our pid; a lock whose pid is dead is stale and taken over
ui_lock() {
    local d p q dead
    d="$WGC_RUN_DIR/uilock"
    if mkdir "$d" 2>/dev/null; then
        printf '%s\n' "$$" > "$d/pid"; HAVE_LOCK=1; return 0
    fi
    [ -L "$d" ] && return 1
    [ -d "$d" ] || return 1
    p=
    read -r p < "$d/pid" 2>/dev/null
    if [ -z "$p" ]; then
        # the owner may be between mkdir and writing its pid
        sleep 1
        read -r p < "$d/pid" 2>/dev/null
    fi
    case $p in *[!0-9]*) p= ;; esac
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then return 1; fi
    # stale: atomic takeover by rename; only one racer can move it away
    dead="$d.dead.$$"
    rm -rf "$dead" 2>/dev/null
    if mv "$d" "$dead" 2>/dev/null; then
        q=
        read -r q < "$dead/pid" 2>/dev/null
        if [ "$q" != "$p" ]; then
            # another racer already replaced the stale lock: give its lock back
            [ -e "$d" ] || [ -L "$d" ] || mv "$dead" "$d" 2>/dev/null
            [ -d "$dead" ] && rm -rf "$dead"
            return 1
        fi
        rm -rf "$dead"
    fi
    # winner or loser of the rename: whoever creates the directory owns the lock
    mkdir "$d" 2>/dev/null || return 1
    printf '%s\n' "$$" > "$d/pid"; HAVE_LOCK=1
    return 0
}

# with the lock held, a .prev file is the leftover of a handler that died between
# swapping in a new file and accepting it: the new file was never checked
restore_leftovers() {
    local m f d p sz
    m="$WGC_DIR/.inprogress"
    [ -e "$m" ] || [ -L "$m" ] || return 0
    if [ -L "$m" ] || [ ! -f "$m" ]; then left "$m is not a regular file, nothing restored"; return 0; fi
    f=
    read -r f < "$m" 2>/dev/null
    case $f in
    wgc[1-5].conf|rules) ;;
    *) rm -f "$m"; left "invalid $m removed, nothing restored"; return 0 ;;
    esac
    d="$WGC_DIR/$f" p="$WGC_DIR/$f.prev"
    if [ -L "$d" ] || [ -L "$p" ] || { [ -e "$d" ] && [ ! -f "$d" ]; } || { [ -e "$p" ] && [ ! -f "$p" ]; }; then
        left "interrupted save of $f: $f or $f.prev is not a regular file, nothing restored"; return 0
    fi
    if [ -f "$p" ]; then
        sz=$(fsize "$p")
        if [ "${sz:-0}" -gt "$WGCUI_PREV_MAX" ]; then
            left "interrupted save of $f: $f.prev is larger than $WGCUI_PREV_MAX bytes, not restored; check $f by SSH"
            return 0
        fi
        mv -f "$p" "$d" || { left "interrupted save of $f: cannot restore $f.prev"; return 0; }
        left "interrupted save of $f: previous $f restored"
    else
        # the slot was empty before the interrupted save: drop the unchecked file
        rm -f "$d"
        left "interrupted save of $f: unchecked $f removed"
    fi
    rm -f "$m"
    logger -t wgcui "interrupted save of $f repaired" 2>/dev/null
}
# left TEXT: note about repaired leftovers, shown in last.message of this run
left() { printf '%s\n' "$*" >> "$WORK.left"; }
ui_unlock() {
    local d p
    [ "$HAVE_LOCK" = 1 ] || return 0
    HAVE_LOCK=0
    d="$WGC_RUN_DIR/uilock"
    p=
    read -r p < "$d/pid" 2>/dev/null
    [ "$p" = "$$" ] && rm -rf "$d"
}

# ---------------------------------------------------------------- JSON
# Input: one record per line (all bytes already limited to LF and 0x20-0x7E):
#   O key | A key  open object/array ("-" = no key: root or array element)
#   C              close
#   S key text     string (text may be empty or contain spaces)
#   R key value    raw: integer, true, false or null (anything else -> null)
#   M key          multi-line string: lines "+text" follow, "E" ends it
# Every string goes through esc(): \ -> \\, " -> \", < > -> < >,
# anything outside 0x20-0x7E removed.
JSON_AWK='
function rep(s, f, t,   r, i) {
    r = ""
    while ((i = index(s, f)) > 0) { r = r substr(s, 1, i - 1) t; s = substr(s, i + length(f)) }
    return r s
}
function body(s) {
    gsub(/[^ -~]/, "", s)
    s = rep(s, "\\", "\\\\")
    s = rep(s, "\"", "\\\"")
    s = rep(s, "<", "\\u003c")
    s = rep(s, ">", "\\u003e")
    return s
}
function esc(s) { return "\"" body(s) "\"" }
function key(k) { return (k == "-") ? "" : esc(k) ":" }
function sep() { if (d > 0) { if (!first[d]) printf ","; first[d] = 0 } }
function kv(   r, i) {
    r = substr($0, 3); i = index(r, " ")
    if (i) { K = substr(r, 1, i - 1); V = substr(r, i + 1) } else { K = r; V = "" }
}
BEGIN { d = 0; inm = 0; printf "var wgcui = " }
inm {
    if ($0 == "E") { sep(); printf "%s\"%s\"", key(mk), mv; inm = 0; next }
    if (substr($0, 1, 1) == "+") { if (mn++) mv = mv "\\n"; mv = mv body(substr($0, 2)) }
    next
}
{ op = substr($0, 1, 1) }
op == "O" || op == "A" {
    if (d == 0 && seen) { bad = 1; exit 1 }
    seen = 1; k = substr($0, 3); sep()
    ob = "["; if (op == "O") ob = "{"
    printf "%s%s", key(k), ob
    d++; first[d] = 1; typ[d] = op; next
}
op == "C" {
    if (d < 1) { bad = 1; exit 1 }
    cb = "]"; if (typ[d] == "O") cb = "}"
    printf "%s", cb; d--; next
}
op == "S" { if (d < 1) { bad = 1; exit 1 }; kv(); sep(); printf "%s%s", key(K), esc(V); next }
op == "R" {
    if (d < 1) { bad = 1; exit 1 }
    kv(); if (V !~ /^(-?[0-9]+|true|false|null)$/) V = "null"
    sep(); printf "%s%s", key(K), V; next
}
op == "M" { mk = substr($0, 3); mv = ""; mn = 0; inm = 1; next }
{ bad = 1; exit 1 }
END { if (bad || d != 0 || inm || !seen) exit 1; printf ";\n" }'

# status of slot N from "wgc.sh status N" output: handshake age and missing list
STATUS_AWK='
BEGIN { p = "wgc" n ": "; dg = "DEGRADED - interface up but missing: "; up = "up, last handshake " }
index($0, p) == 1 {
    r = substr($0, length(p) + 1)
    if (index(r, dg) == 1) miss = substr(r, length(dg) + 1)
    else if (index(r, up) == 1) { a = substr(r, length(up) + 1); sub(/s ago.*$/, "", a); if (a ~ /^[0-9]+$/) age = a }
}
END {
    if (st == "up" && rc == 3) age = hsage
    if (st != "up" || age !~ /^[0-9]+$/) age = "null"
    print "R handshake_age " age
    print "A missing"
    if (st == "degraded") {
        m = split(miss, it, ", ")
        for (i = 1; i <= m && i <= 16; i++) if (it[i] != "") print "S - " substr(it[i], 1, 64)
    }
    print "C"
}'

# endpoint/pubkey from "wgc.sh check N" (rc 0), else the first output line as error
CHECK_AWK='
BEGIN { if (wgep ~ /^[][0-9A-Za-z.:-]+$/ && length(wgep) <= 64) ep = wgep }
crc == 0 && $1 == "endpoint" && ep == "" && $2 ~ /^[][0-9A-Za-z.:-]+$/ { ep = substr($2, 1, 64) }
crc == 0 && $1 == "peer" && pk == "" && $2 ~ /^[A-Za-z0-9+\/=]+$/ { pk = substr($2, 1, 64) }
crc != 0 && er == "" && NF { er = $0 }
END {
    print "S endpoint " ep
    print "S pubkey " pk
    print "S check_error " substr(er, 1, 200)
}'

TRANSFER_AWK='
$2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { r += $2; t += $3 }
END { printf "R rx %.0f\nR tx %.0f\n", r, t }'

WD_AWK='
{
    for (i = 1; i + 3 <= NF; i++)
        if ($i == "__watchdog" && $(i + 1) == tok && $(i + 2) == tgt) {
            s = $(i + 3)
            if (s ~ /^[0-9]+$/ && s + 0 >= lo && s + 0 <= hi) { print s + 0; exit }
        }
}'

# rules array + rules_skipped. "#off <rule>" is a disabled rule; other comment
# and blank lines are ignored. After the trailing "# comment" is cut off a rule
# must have exactly 3 fields of the expected shape, else it is counted. The
# comment is "name: description" (no colon: all of it is the name).
RULES_AWK='
function trim(x) { sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); return x }
BEGIN { print "A rules" }
{
    line = $0; en = "true"
    if (line ~ /^[ \t]*#off[ \t]/) { sub(/^[ \t]*#off[ \t]+/, "", line); en = "false" }
    else if (line ~ /^[ \t]*#/) next
    cm = ""; i = index(line, "#")
    if (i) { cm = trim(substr(line, i + 1)); line = substr(line, 1, i - 1) }
    $0 = line
    if (NF == 0) { if (en == "false") sk++; next }
    t = $1; if (t ~ /^[1-5]$/) t = "wgc" t
    if (NF != 3 || t !~ /^wgc[1-5]$/ || $2 !~ /^[0-9A-Za-z.\/:]+$/ || $3 !~ /^[0-9A-Za-z.\/:]+$/ ||
        length($2) > 64 || length($3) > 64 || c >= 256) { sk++; next }
    c++
    j = index(cm, ":")
    if (j) { nm = trim(substr(cm, 1, j - 1)); ds = trim(substr(cm, j + 1)) } else { nm = cm; ds = "" }
    print "O -"; print "S tunnel " t; print "S src " $2; print "S dst " $3
    print "R enabled " en; print "S name " substr(nm, 1, 40); print "S desc " substr(ds, 1, 120); print "C"
}
END { print "C"; print "R rules_skipped " (sk + 0) }'

LEASES_AWK='
{
    ip = $3; mac = $2; nm = $4
    if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) next
    if (mac !~ /^[0-9A-Fa-f:]+$/ || length(mac) > 17) mac = ""
    gsub(/[^A-Za-z0-9._-]/, "", nm)
    nm = substr(nm, 1, w)
    if (++c > 256) exit
    print "O -"; print "S ip " ip; print "S name " nm; print "S mac " mac; print "C"
}'

# foreign_settings: every non-wgcui_ line as key -> rest of the line (first wins)
FOREIGN_AWK='
BEGIN { print "O foreign_settings" }
index($0, "wgcui_") == 1 { next }
{
    i = index($0, " ")
    if (i) { k = substr($0, 1, i - 1); v = substr($0, i + 1) } else { k = $0; v = "" }
    sub(/\r$/, "", v)
    if (k !~ /^[A-Za-z0-9_.-]+$/ || (k in seen) || ++c > 200) next
    seen[k] = 1
    print "S " k " " v
}
END { print "C" }'

LOG_AWK='
index($0, " wgc: ") || index($0, "wgc-") { n++; b[n % m] = $0 }
END {
    s = n - m + 1; if (s < 1) s = 1
    for (i = s; i <= n; i++) { l = b[i % m]; gsub(/[^ -~]/, "", l); print "S - " substr(l, 1, w) }
}'

# ---------------------------------------------------------------- status.js
pick_syslog() {
    local f best
    if [ -n "$WGCUI_SYSLOG" ]; then printf '%s' "$WGCUI_SYSLOG"; return; fi
    best=
    for f in $WGCUI_SYSLOG_DEFAULTS; do
        [ -f "$f" ] || continue
        if [ -z "$best" ] || [ "$f" -nt "$best" ]; then best=$f; fi
    done
    printf '%s' "$best"
}

# find_wd TOKEN TARGET: total seconds from the argv of the running try watchdog
find_wd() {
    local s
    s=$(ps w 2>/dev/null | awk -v tok="$1" -v tgt="$2" -v lo="$WGCUI_TRY_MIN" -v hi="$WGCUI_TRY_MAX" "$WD_AWK")
    if [ -z "$s" ]; then
        s=$(ps -axo pid=,args= 2>/dev/null | awk -v tok="$1" -v tgt="$2" -v lo="$WGCUI_TRY_MIN" -v hi="$WGCUI_TRY_MAX" "$WD_AWK")
    fi
    case $s in ''|*[!0-9]*) s=null ;; esac
    printf '%s' "$s"
}

# have_ministun: ministun is an executable file in PATH (plain sh PATH walk;
# never "command -v", "type" or "hash": the firmware's ash lacks "command")
have_ministun() {
    local d
    [ -x /usr/sbin/ministun ] && return 0
    for d in $(printf '%s' "$PATH" | tr ':' ' '); do
        [ -f "$d/ministun" ] && [ -x "$d/ministun" ] && return 0
    done
    return 1
}

# valid_ipv4 TEXT: dotted quad, each part 0-255 (same shape as the leases check)
valid_ipv4() {
    printf '%s\n' "$1" | awk -F. 'NR == 1 && /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {
        for (i = 1; i <= 4; i++) if (length($i) > 3 || $i + 0 > 255) exit 1
        ok = 1 } END { exit ok ? 0 : 1 }'
}

# read_exitip N: prints "<ip> <age>" from the cache, nothing if none/invalid
read_exitip() {
    local f ip ts now
    f="$WGC_RUN_DIR/wgc$1.exitip"
    [ -f "$f" ] && [ ! -L "$f" ] || return 1
    ip= ts=
    read -r ip ts < "$f" 2>/dev/null
    case $ts in ''|*[!0-9]*) return 1 ;; esac
    valid_ipv4 "$ip" || return 1
    now=$(date +%s)
    [ "$now" -ge "$ts" ] 2>/dev/null || ts=$now
    printf '%s %s\n' "$ip" "$((now - ts))"
}

# fetch_exit_ip N: one ministun lookup through wgcN (caller knows it is up); cache on success,
# on failure drop a cached value older than WGCUI_EXITIP_DROP
fetch_exit_ip() {
    local n f t ip c
    n=$1
    case " $IP_DONE " in *" $n "*) return 0 ;; esac
    IP_DONE="$IP_DONE $n"
    f="$WGC_RUN_DIR/wgc$n.exitip"
    ip=
    # STUN through the tunnel; first server answering with an IPv4 wins
    have_ministun || return 1
    for c in $WGCUI_STUN_SERVERS; do
        ip=
        if t=$(ministun -t "$WGCUI_STUN_TIMEOUT" -c 1 -i "wgc$n" "$c" 2>/dev/null); then
            ip=$(printf '%s\n' "$t" | head -n 3 | tr -d ' \t\r\n' | cut -c1-64)
        fi
        if [ -n "$ip" ] && valid_ipv4 "$ip"; then break; fi
        ip=
    done
    if valid_ipv4 "$ip"; then
        t="$f.tmp.$$"
        rm -f "$t"
        if ( set -C; printf '%s %s\n' "$ip" "$(date +%s)" > "$t" ) 2>/dev/null && mv -f "$t" "$f"; then
            return 0
        fi
        rm -f "$t"
        return 1
    fi
    c=$(read_exitip "$n")
    if [ -n "$c" ] && [ "${c#* }" -gt "$WGCUI_EXITIP_DROP" ]; then rm -f "$f"; fi
    if [ -z "$c" ] && [ -e "$f" ] && [ ! -L "$f" ]; then rm -f "$f"; fi
    return 1
}

# exit address fields of slot N (asks ministun on start/refresh, else the cache). "Up" here is
# what wgc.sh status also checks first: the interface wgcN exists (up or degraded)
exitip_fields() {
    local n c want
    n=$1
    if ip link show dev "wgc$n" >/dev/null 2>&1; then
        want=0
        case " $IP_FORCE " in *" $n "*|*" all "*) want=1 ;; esac
        [ "$want" = 1 ] && fetch_exit_ip "$n"
        c=$(read_exitip "$n")
    else
        c=
    fi
    if [ -n "$c" ]; then
        printf 'S exit_ip %s\nR exit_ip_age %s\n' "${c%% *}" "${c#* }"
    else
        printf '%s\n' 'S exit_ip ' 'R exit_ip_age null'
    fi
}

# gen_body: tunnels, pending_try, rules, devices, log (calls wgc.sh status N x5,
# check N for slots with a conf, wg show transfer/latest-handshakes)
gen_body() {
    local n o rc st conf hs age tok tgt sl wep
    o="$WORK.st"
    printf '%s\n' 'A tunnels'
    for n in 1 2 3 4 5; do
        sh "$WGC_SH" status "$n" > "$o" 2>&1 < /dev/null; rc=$?
        if [ -f "$WGC_DIR/wgc$n.conf" ]; then conf=true; else conf=false; fi
        if [ "$conf" = false ]; then
            st=noconf
        else
            case $rc in
            0|3) st=up ;;
            1) if grep -q "^wgc$n: DEGRADED - " "$o"; then st=degraded; else st=down; fi ;;
            *) st=down ;;
            esac
        fi
        age=
        if [ "$st" = up ] && [ "$rc" = 3 ]; then
            hs=$(wg show "wgc$n" latest-handshakes 2>/dev/null | awk 'NF >= 2 && $2 ~ /^[0-9]+$/ { print $2; exit }')
            case $hs in
            ''|0|*[!0-9]*) ;;
            *) age=$(awk -v now="$(date +%s)" -v h="$hs" 'BEGIN { a = now - h; if (a < 0) a = 0; printf "%.0f\n", a }') ;;
            esac
        fi
        printf 'O -\nR conf %s\nS state %s\n' "$conf" "$st"
        awk -v n="$n" -v rc="$rc" -v st="$st" -v hsage="$age" "$STATUS_AWK" "$o"
        if [ "$st" = up ] || [ "$st" = degraded ]; then
            wg show "wgc$n" transfer 2>/dev/null | awk "$TRANSFER_AWK"
        else
            printf '%s\n' 'R rx 0' 'R tx 0'
        fi
        exitip_fields "$n"
        if [ "$conf" = true ]; then
            sh "$WGC_SH" check "$n" > "$o" 2>&1 < /dev/null; rc=$?
            # endpoint: the live one from wg when the tunnel is up, else check's
            wep=
            if [ "$st" = up ] || [ "$st" = degraded ]; then
                wep=$(wg show "wgc$n" endpoints 2>/dev/null | awk 'NF >= 2 && $2 != "(none)" { print $2; exit }')
            fi
            awk -v crc="$rc" -v wgep="$wep" "$CHECK_AWK" "$o"
        else
            printf '%s\n' 'S endpoint ' 'S pubkey ' 'S check_error '
        fi
        printf '%s\n' 'C'
    done
    printf '%s\n' 'C'
    rm -f "$o"

    # pending try (wgc.pending: "<32 hex> <target>")
    tok= tgt=
    if [ -f "$WGC_RUN_DIR/wgc.pending" ] && [ ! -L "$WGC_RUN_DIR/wgc.pending" ]; then
        read -r tok tgt < "$WGC_RUN_DIR/wgc.pending" 2>/dev/null
        tgt=${tgt%% *}
    fi
    case $tok in ''|*[!0-9a-f]*) tok= ;; esac
    [ ${#tok} -eq 32 ] || tok=
    valid_target "$tgt" || tok=
    if [ -n "$tok" ]; then
        printf 'O pending_try\nS target %s\nR seconds %s\nC\n' "$tgt" "$(find_wd "$tok" "$tgt")"
    else
        printf '%s\n' 'R pending_try null'
    fi

    if [ -f "$WGC_DIR/rules" ]; then awk "$RULES_AWK" "$WGC_DIR/rules"; else awk "$RULES_AWK" /dev/null; fi

    printf '%s\n' 'A devices'
    if [ -f "$WGCUI_LEASES" ]; then awk -v w="$WGCUI_NAME_WIDTH" "$LEASES_AWK" "$WGCUI_LEASES"; fi
    printf '%s\n' 'C'

    if settings_ok; then awk "$FOREIGN_AWK" "$WGCUI_SETTINGS"; else awk "$FOREIGN_AWK" /dev/null; fi

    printf '%s\n' 'A log'
    sl=$(pick_syslog)
    if [ -n "$sl" ] && [ -f "$sl" ]; then
        awk -v m="$WGCUI_LOG_LINES" -v w="$WGCUI_LOG_WIDTH" "$LOG_AWK" "$sl"
    fi
    printf '%s\n' 'C'
}

# the "last" object from L_ACTION L_TARGET L_RC L_WHEN and the message file $WORK.msg
gen_last() {
    local rc
    rc=$L_RC
    printf 'O last\nS action %s\nS target %s\nR rc %s\nM message\n' "$L_ACTION" "$L_TARGET" "$rc"
    if [ -f "$WORK.msg" ] || [ -f "$WORK.left" ]; then
        cat "$WORK.msg" "$WORK.left" 2>/dev/null | awk 'NR > 200 { exit } { print "+" substr($0, 1, 500) }'
    fi
    printf 'E\nR when %s\nC\n' "${L_WHEN:-null}"
}

# render PENDING BUSY BODYFILE LASTFILE: write status.js atomically
render() {
    local out tmp
    out="$WGCUI_WEBDIR/status.js"
    tmp="$out.tmp.$$"
    mkdir -p "$WGCUI_WEBDIR" 2>/dev/null || { warn "cannot create $WGCUI_WEBDIR"; return 1; }
    {
        printf 'O -\nS version 1\nR generated %s\nR pending %s\nR busy %s\n' "$(date +%s)" "$1" "$2"
        cat "$4" "$3"
        printf '%s\n' 'R http_warning true' 'C'
    } | tr -cd '\12\40-\176' | awk "$JSON_AWK" > "$tmp"
    if [ $? -eq 0 ] && [ -s "$tmp" ]; then
        chmod 644 "$tmp" 2>/dev/null
        mv -f "$tmp" "$out" && return 0
    fi
    rm -f "$tmp"
    warn "cannot write $out"
    return 1
}

# full status.js: fresh body (cached for later pending/busy renders)
write_status() {   # write_status PENDING BUSY
    gen_body > "$WORK.body" || return 1
    gen_last > "$WORK.last"
    render "$1" "$2" "$WORK.body" "$WORK.last" || return 1
    mv -f "$WORK.body" "$WGC_RUN_DIR/wgcui.body" 2>/dev/null
    mv -f "$WORK.last" "$WGC_RUN_DIR/wgcui.last" 2>/dev/null
    return 0
}

# status.js from the cached body (no wgc.sh call); no cache -> fresh body when
# BUSY is true or FORCE is given, else nothing is written
write_status_cached() {   # write_status_cached PENDING BUSY [FORCE]
    local b
    b="$WGC_RUN_DIR/wgcui.body"
    gen_last > "$WORK.last"
    if [ ! -f "$b" ] || [ -L "$b" ]; then
        [ "$2" = true ] || [ -n "$3" ] || return 0
        gen_body > "$WORK.body" || return 1
        b="$WORK.body"
    fi
    render "$1" "$2" "$b" "$WORK.last"
}

msg() { printf '%s\n' "$*" > "$WORK.msg"; }

work_clean() {
    [ -n "$WORK" ] || return 0
    rm -f "$WORK.st" "$WORK.body" "$WORK.last" "$WORK.msg" "$WORK.out" "$WORK.left"
}

# ---------------------------------------------------------------- handler
rollback() {
    [ -n "$RB_FILE" ] || return 0
    if [ "$RB_HADPREV" = 1 ]; then
        mv -f "$RB_PREV" "$RB_FILE"
    else
        rm -f "$RB_FILE"
    fi
    RB_FILE=
    rm -f "$WGC_DIR/.inprogress"
}

on_exit() {
    rollback
    del_keys    # no-op when already done; covers a signal before the read
    [ -n "$CONF_TMP" ] && rm -f "$CONF_TMP" "$CONF_TMP.raw" "$CONF_TMP.len"
    [ -n "$RULES_TMP" ] && rm -f "$RULES_TMP" "$RULES_TMP.raw" "$RULES_TMP.len"
    work_clean
    ui_unlock
}

on_signal() {
    trap '' INT TERM HUP
    if [ -n "$RB_FILE" ]; then
        rollback
        printf '%s\n' "interrupted, previous ${RB_KIND:-file} restored" > "$WORK.msg"
    else
        printf '%s\n' "interrupted" > "$WORK.msg"
    fi
    L_RC=1
    write_status_cached false false force
    exit 1
}

run_wgc() {   # output appended to $WORK.out, returns wgc.sh's exit code
    sh "$WGC_SH" "$@" >> "$WORK.out" 2>&1 < /dev/null
}

# swap_in NEW DEST KIND: DEST.prev keeps the old file; rollback() undoes the swap
swap_in() {
    local new dest p
    new=$1 dest=$2
    p="$dest.prev"
    if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -f "$dest" ]; }; then
        msg "$3: $dest is not a regular file, nothing changed"; return 1
    fi
    rm -f "$p"
    RB_HADPREV=0
    if [ -f "$dest" ]; then
        cp -p "$dest" "$p" || { rm -f "$p"; msg "$3: cannot back up $dest, nothing changed"; return 1; }
        RB_HADPREV=1
    fi
    # marker after .prev exists: a marker without .prev always means "slot was empty"
    RB_PREV=$p RB_KIND=$3 RB_FILE=$dest
    if ! printf '%s\n' "${dest##*/}" > "$WGC_DIR/.inprogress"; then
        RB_FILE=; rm -f "$p" "$WGC_DIR/.inprogress"; msg "$3: cannot write $WGC_DIR/.inprogress, nothing changed"; return 1
    fi
    if ! mv -f "$new" "$dest"; then
        rollback; msg "$3: cannot write $dest, nothing changed"; return 1
    fi
    chmod 600 "$dest" 2>/dev/null
    return 0
}
swap_accept() { RB_FILE=; rm -f "$RB_PREV"; rm -f "$WGC_DIR/.inprogress"; }

# exitip_forget N|all: drop the cached exit address(es)
exitip_forget() {
    local n
    if [ "$1" = all ]; then set -- 1 2 3 4 5; fi
    for n in "$@"; do rm -f "$WGC_RUN_DIR/wgc$n.exitip"; done
}

# reapply_running: "wgc.sh start N" only for tunnels whose interface exists, so
# saving rules never brings up a stopped tunnel (never "start all")
reapply_running() {
    local n r rc done
    rc=0 done=
    for n in 1 2 3 4 5; do
        ip link show dev "wgc$n" >/dev/null 2>&1 || continue
        run_wgc start "$n"; r=$?
        [ $r -eq 0 ] || rc=$r
        done="$done wgc$n"
    done
    if [ -n "$done" ]; then
        printf '%s\n' "rules re-applied on running tunnel(s):$done" >> "$WORK.out"
    else
        printf '%s\n' "no running tunnel, rules saved" >> "$WORK.out"
    fi
    return $rc
}

cmd_service_event() {
    local action target seconds vlen level k n rc reason
    [ $# -eq 2 ] && [ "$1" = start ] && [ "$2" = wgcui ] || die_usage "usage: wgcui.sh service_event start wgcui"
    L_WHEN=$(date +%s)
    if ! ensure_run_dir; then del_keys; exit 0; fi
    WORK="$WGC_RUN_DIR/.wgcui.$$"
    trap 'on_exit' EXIT
    trap 'on_signal' INT TERM HUP

    if ! ui_lock; then
        L_ACTION=$(sanitize_action "$(kget wgcui_action)")
        del_keys
        L_RC=2
        msg "busy: another action is running, nothing done"
        # only while the running handler shows pending:true (or there is no
        # status.js yet): its final write comes later and wins; otherwise the
        # busy note could hide its result
        if [ ! -e "$WGCUI_WEBDIR/status.js" ] || grep -q '"pending":true' "$WGCUI_WEBDIR/status.js" 2>/dev/null; then
            write_status_cached false true
        fi
        exit 0
    fi
    restore_leftovers

    if [ -L "$WGCUI_SETTINGS" ]; then
        L_RC=2
        msg "refused: the settings file $WGCUI_SETTINGS is a symlink"
        logger -t wgcui "refused: $WGCUI_SETTINGS is a symlink" 2>/dev/null
        write_status false false
        exit 0
    fi

    # read, then delete every wgcui_* key before anything else
    CONF_TMP="$WGC_DIR/.wgcui.conf.$$"
    RULES_TMP="$WGC_DIR/.wgcui.rules.$$"
    reason=
    for k in wgcui_action wgcui_target wgcui_seconds wgcui_conf wgcui_rules wgcui_len; do
        n=$(kcount "$k")
        case $n in 0|1) ;; *) reason="duplicate key $k, nothing done" ;; esac
    done
    action=$(kget wgcui_action)
    target=$(kget wgcui_target)
    seconds=$(kget wgcui_seconds)
    vlen=$(kget wgcui_len)
    HAS_CONF=$(kcount wgcui_conf) HAS_RULES=$(kcount wgcui_rules)
    CONF_BAD= RULES_BAD=
    if [ "$HAS_CONF" = 1 ]; then kfile wgcui_conf "$CONF_TMP" || CONF_BAD=1; fi
    if [ "$HAS_RULES" = 1 ]; then kfile wgcui_rules "$RULES_TMP" || RULES_BAD=1; fi
    del_keys

    L_ACTION=$(sanitize_action "$action")
    valid_target "$target" && L_TARGET=$target
    L_RC=2
    level=$(read_level)

    if [ -z "$reason" ]; then
        case $action in
        '') reason="no action given" ;;
        refresh|check|saverules) ;;
        start|stop|try|confirm|saveconf|deleteconf)
            [ "$level" = full ] || reason="action disabled at level ro" ;;
        *) reason="unknown action" ;;
        esac
    fi
    if [ -z "$reason" ]; then
        case $action in
        check|start|stop) valid_target "$target" || reason="invalid target (1-5 or all)" ;;
        try)
            if ! valid_target "$target"; then reason="invalid target (1-5 or all)"
            elif ! valid_secs "$seconds"; then reason="invalid seconds ($WGCUI_TRY_MIN-$WGCUI_TRY_MAX)"
            fi ;;
        deleteconf) valid_slot "$target" || reason="invalid target (1-5)" ;;
        saveconf)
            if ! valid_slot "$target"; then reason="invalid target (1-5)"
            elif [ "$HAS_CONF" != 1 ]; then reason="no conf given"
            elif [ -n "$CONF_BAD" ]; then reason="conf contains bytes outside printable ASCII"
            elif ! len_ok "$vlen" "$CONF_TMP.len"; then reason="conf length mismatch (wgcui_len missing or not the stored length; settings truncated?), nothing written"
            elif ! reason=$(content_ok "$CONF_TMP" "$WGCUI_CONF_MAX" conf); then :
            elif [ "$(fsize "$CONF_TMP")" -le 1 ]; then reason="conf is empty"
            fi ;;
        saverules)
            if [ "$HAS_RULES" != 1 ]; then reason="no rules given"
            elif [ -n "$RULES_BAD" ]; then reason="rules contain bytes outside printable ASCII"
            elif ! len_ok "$vlen" "$RULES_TMP.len"; then reason="rules length mismatch (wgcui_len missing or not the stored length; settings truncated?), nothing written"
            elif ! reason=$(content_ok "$RULES_TMP" "$WGCUI_RULES_MAX" rules); then :
            fi ;;
        esac
    fi
    # unused uploads are dropped right away
    rm -f "$CONF_TMP.len" "$RULES_TMP.len"
    [ "$action" = saveconf ] && [ -z "$reason" ] || { rm -f "$CONF_TMP"; }
    [ "$action" = saverules ] && [ -z "$reason" ] || { rm -f "$RULES_TMP"; }

    if [ -n "$reason" ]; then
        msg "$reason"
        [ "$action" = refresh ] || logger -t wgcui "refused action '$L_ACTION': $reason" 2>/dev/null
        write_status false false
        exit 0
    fi

    # tell the page the action was taken (cached body, no wgc.sh call)
    L_RC=null
    msg "running"
    [ "$action" = refresh ] || write_status_cached true false
    : > "$WORK.out"
    rc=0
    case $action in
    refresh) IP_FORCE=all ;;   # every up tunnel is asked again
    check) run_wgc check "$target"; rc=$? ;;
    start)
        run_wgc start "$target"; rc=$?
        # the status build below asks ministun for each started tunnel that is up
        IP_FORCE=$target ;;
    stop)
        run_wgc stop "$target"; rc=$?
        exitip_forget "$target" ;;
    try) run_wgc try "$target" "$seconds"; rc=$? ;;
    confirm) run_wgc confirm; rc=$? ;;
    deleteconf)
        run_wgc stop "$target"; rc=$?
        exitip_forget "$target"
        if [ $rc -eq 0 ]; then
            rm -f "$WGC_DIR/wgc$target.conf" "$WGC_DIR/wgc$target.conf.prev"
        else
            printf '%s\n' "wgc$target.conf kept: stop failed" >> "$WORK.out"
        fi ;;
    saveconf)
        if swap_in "$CONF_TMP" "$WGC_DIR/wgc$target.conf" conf; then
            CONF_TMP=
            run_wgc check "$target"; rc=$?
            if [ $rc -eq 0 ]; then swap_accept; else rollback; printf '%s\n' "new conf refused, previous state restored" >> "$WORK.out"; fi
        else
            rc=1; cat "$WORK.msg" >> "$WORK.out"
        fi ;;
    saverules)
        if swap_in "$RULES_TMP" "$WGC_DIR/rules" rules; then
            RULES_TMP=
            run_wgc check all; rc=$?
            if [ $rc -ne 0 ]; then
                rollback; printf '%s\n' "new rules refused, previous rules restored" >> "$WORK.out"
            else
                swap_accept
                if [ "$level" = full ]; then reapply_running; rc=$?; fi
            fi
        else
            rc=1; cat "$WORK.msg" >> "$WORK.out"
        fi ;;
    esac
    L_RC=$rc
    mv -f "$WORK.out" "$WORK.msg"
    [ "$action" = refresh ] || logger -t wgcui "action $action ${L_TARGET:+$L_TARGET }rc $rc" 2>/dev/null
    write_status false false
    exit 0
}

# ---------------------------------------------------------------- web page + menu
# MENU_AWK: drop our menu lines (by our title only: a foreign line is never
# touched, even if it points to the same user page), in mode add insert
# ours after the OpenVPN client line (fallback: Switch Control); exit 3 = no anchor
MENU_AWK='
BEGIN {
    a1 = "url: \"Advanced_VPNClient_Content.asp\", tabName:"
    a2 = "url: \"Advanced_SwitchCtrl_Content.asp\", tabName:"
    mt = "tabName: \"" title "\"}"
    ns = split(slots, sl, " ")
}
{
    if (index($0, mt) > 0) next
    ln[++n] = $0
}
END {
    at = 0
    if (mode == "add") {
        for (i = 1; i <= n && !at; i++) if (index(ln[i], a1) > 0) at = i
        for (i = 1; i <= n && !at; i++) if (index(ln[i], a2) > 0) at = i
        if (!at) exit 3
    }
    for (i = 1; i <= n; i++) {
        print ln[i]
        if (i == at) print "{url: \"user" sl[1] ".asp\", tabName: \"" title "\"},"
    }
}'

# our_slots: slots holding our page (md5 of wgcui.asp first, then the page marker)
our_slots() {
    local i p h out
    h=
    [ -f "$WGC_DIR/wgcui.asp" ] && h=$(md5_of "$WGC_DIR/wgcui.asp")
    out=
    i=1
    while [ $i -le 20 ]; do
        p="$WGCUI_WWW/user$i.asp"
        if [ -f "$p" ] && [ ! -L "$p" ]; then
            if [ -n "$h" ] && [ "$(md5_of "$p")" = "$h" ]; then out="$i $out"
            elif grep -qF -- "$WGCUI_PAGE_MARK" "$p" 2>/dev/null &&
                [ -f "$WGCUI_WWW/user$i.title" ] && [ "$(cat "$WGCUI_WWW/user$i.title" 2>/dev/null)" = "$WGCUI_TITLE" ]; then
                out="$out $i"
            fi
        fi
        i=$((i + 1))
    done
    printf '%s' "$out"
}

# pick_slot: first of our slots, else the first free one, else nothing
pick_slot() {
    local s i p
    set -- $(our_slots)
    if [ $# -gt 0 ]; then printf '%s' "$1"; return 0; fi
    i=1
    while [ $i -le 20 ]; do
        p="$WGCUI_WWW/user$i.asp"
        if [ ! -e "$p" ] && [ ! -L "$p" ]; then printf '%s' "$i"; return 0; fi
        i=$((i + 1))
    done
    return 1
}

remount_menu() {
    umount "$WGCUI_MENUTREE_SRC" 2>/dev/null
    mount -o bind "$WGCUI_MENUTREE" "$WGCUI_MENUTREE_SRC" || { warn "mount -o bind of the menu failed"; return 1; }
}

# menu_write MODE SLOTS: rewrite the menu copy; remount only when it changed
menu_write() {
    local t r
    t="$WGCUI_MENUTREE.wgcui.$$"
    rm -f "$t"
    cp -p "$WGCUI_MENUTREE" "$t" 2>/dev/null || { warn "cannot write next to $WGCUI_MENUTREE"; return 1; }
    awk -v mode="$1" -v slots="$2" -v title="$WGCUI_TITLE" "$MENU_AWK" "$WGCUI_MENUTREE" > "$t"; r=$?
    if [ $r -eq 3 ]; then rm -f "$t"; warn "no anchor line for the menu entry in $WGCUI_MENUTREE"; return 1; fi
    if [ $r -ne 0 ] || [ ! -s "$t" ]; then rm -f "$t"; warn "menu edit failed"; return 1; fi
    if [ "$1" = add ] && [ "$(md5_of "$t")" = "$(md5_of "$WGCUI_MENUTREE")" ]; then
        rm -f "$t"; remount_menu; return
    fi
    if [ "$1" = del ] && [ "$(md5_of "$t")" = "$(md5_of "$WGCUI_MENUTREE")" ]; then
        rm -f "$t"; return 0
    fi
    mv -f "$t" "$WGCUI_MENUTREE" || { rm -f "$t"; return 1; }
    remount_menu
}

# runs under flock on $WGCUI_LOCKFILE (internal: __webui mount|unmount)
webui_mount() {
    local s asp mark new_page new_title new_menu had_line
    asp="$WGC_DIR/wgcui.asp"
    [ -f "$asp" ] || { warn "missing $asp"; return 1; }
    s=$(pick_slot) || { warn "no free user page slot"; return 1; }
    mark="tabName: \"$WGCUI_TITLE\"}"
    new_page=0 new_title=0 new_menu=0 had_line=0
    [ -e "$WGCUI_WWW/user$s.asp" ] || new_page=1
    [ -e "$WGCUI_WWW/user$s.title" ] || new_title=1
    [ -f "$WGCUI_MENUTREE" ] || new_menu=1
    [ "$new_menu" = 0 ] && grep -qF -- "$mark" "$WGCUI_MENUTREE" && had_line=1
    if cp -f "$asp" "$WGCUI_WWW/user$s.asp" &&
        printf '%s\n' "$WGCUI_TITLE" > "$WGCUI_WWW/user$s.title" &&
        { [ "$new_menu" = 0 ] || cp -f "$WGCUI_MENUTREE_SRC" "$WGCUI_MENUTREE" || { warn "cannot copy the menu"; false; }; } &&
        menu_write add "$s"; then
        return 0
    fi
    # failed: take back only what this run added
    if [ "$had_line" = 0 ] && [ -f "$WGCUI_MENUTREE" ] && grep -qF -- "$mark" "$WGCUI_MENUTREE"; then
        menu_write del "" || warn "menu entry could not be removed"
    fi
    [ "$new_menu" = 1 ] && rm -f "$WGCUI_MENUTREE"
    [ "$new_page" = 1 ] && rm -f "$WGCUI_WWW/user$s.asp"
    [ "$new_title" = 1 ] && rm -f "$WGCUI_WWW/user$s.title"
    return 1
}

webui_unmount() {
    local s i rc
    s=$(our_slots)
    rc=0
    if [ -f "$WGCUI_MENUTREE" ]; then menu_write del "$s" || rc=1; fi
    for i in $s; do
        rm -f "$WGCUI_WWW/user$i.asp" "$WGCUI_WWW/user$i.title"
    done
    return $rc
}

webui_locked() { flock -x "$WGCUI_LOCKFILE" sh "$SELF" __webui "$1"; }

# ---------------------------------------------------------------- /jffs/scripts lines
# script_add NAME LINE: exactly one of our lines in WGCUI_SCRIPTS/NAME (backup first)
script_add() {
    local f t ours exact
    f="$WGCUI_SCRIPTS/$1"
    if [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then warn "$f is not a regular file"; return 1; fi
    if [ ! -e "$f" ]; then
        mkdir -p "$WGCUI_SCRIPTS" || return 1
        printf '%s\n' '#!/bin/sh' "$2" > "$f" || return 1
        chmod 755 "$f"
        return 0
    fi
    ours=$(grep -c "$OUR_LINES_RE" "$f")
    exact=$(grep -Fxc -- "$2" "$f")
    [ "$ours" = 1 ] && [ "$exact" = 1 ] && return 0
    cp -p "$f" "$WGC_DIR/$1.bak" || { warn "cannot back up $f"; return 1; }
    if [ "$ours" != 0 ]; then script_strip "$1" || return 1; fi
    ends_nl "$f" || printf '\n' >> "$f"
    printf '%s\n' "$2" >> "$f"
}
# script_strip NAME: drop our lines, keep the file (inode, mode) and every other line
script_strip() {
    local f t
    f="$WGCUI_SCRIPTS/$1"
    [ -f "$f" ] && [ ! -L "$f" ] || return 0
    grep -q "$OUR_LINES_RE" "$f" || return 0
    t="$WGC_DIR/.wgcui.$1.$$"
    grep -v "$OUR_LINES_RE" "$f" > "$t"
    [ $? -le 1 ] || { rm -f "$t"; return 1; }
    cat "$t" > "$f" || { rm -f "$t"; return 1; }
    rm -f "$t"
}

# ---------------------------------------------------------------- commands
# status.js outside the handler (install/mount/status): only when the handler is idle
status_now() {
    ensure_run_dir || return 1
    WORK="$WGC_RUN_DIR/.wgcui.$$"
    ui_lock || { warn "an action is running, status.js not rewritten"; return 1; }
    trap 'work_clean; ui_unlock' EXIT
    trap 'exit 1' INT TERM HUP
    L_ACTION= L_TARGET= L_RC=0 L_WHEN=null
    if [ -f "$WGC_RUN_DIR/wgcui.last" ] && [ ! -L "$WGC_RUN_DIR/wgcui.last" ]; then
        gen_body > "$WORK.body" && render false false "$WORK.body" "$WGC_RUN_DIR/wgcui.last" &&
            mv -f "$WORK.body" "$WGC_RUN_DIR/wgcui.body"
    else
        write_status false false
    fi
    rc=$?
    work_clean; ui_unlock
    trap - EXIT INT TERM HUP
    return $rc
}

cmd_install() {
    [ -f "$WGC_DIR/wgcui.asp" ] || die "missing $WGC_DIR/wgcui.asp"
    webui_locked mount || die "page/menu install failed"
    mkdir -p "$WGCUI_WEBDIR" || die "cannot create $WGCUI_WEBDIR"
    status_now || warn "status.js not written"
    script_add post-mount "$PM_LINE" || die "post-mount line not added"
    return 0
}

cmd_mount() {
    webui_locked mount || die "page/menu mount failed"
    # /www/user is tmpfs: after a reboot the page needs a first status.js
    mkdir -p "$WGCUI_WEBDIR" || die "cannot create $WGCUI_WEBDIR"
    [ -f "$WGCUI_WEBDIR/status.js" ] || status_now || warn "status.js not written"
    return 0
}

cmd_uninstall() {
    local rc
    rc=0
    webui_locked unmount || { warn "page/menu removal incomplete"; rc=1; }
    script_strip post-mount || rc=1
    script_strip service-event || rc=1
    if [ -d "$WGCUI_WEBDIR" ] && [ ! -L "$WGCUI_WEBDIR" ]; then
        set +f
        rm -f "$WGCUI_WEBDIR"/status.js "$WGCUI_WEBDIR"/status.js.tmp.*
        set -f
        rmdir "$WGCUI_WEBDIR" 2>/dev/null || { warn "$WGCUI_WEBDIR not empty, left in place"; rc=1; }
    elif [ -L "$WGCUI_WEBDIR" ]; then
        rm -f "$WGCUI_WEBDIR"
    fi
    del_keys || rc=1
    rm -f "$WGC_DIR/wgcui.level"
    if [ -d "$WGC_RUN_DIR" ] && [ ! -L "$WGC_RUN_DIR" ]; then
        rm -f "$WGC_RUN_DIR/wgcui.body" "$WGC_RUN_DIR/wgcui.last"
    fi
    return $rc
}

cmd_set_level() {
    local t
    t="$WGC_DIR/wgcui.level"
    rm -f "$t.tmp.$$"
    printf '%s\n' "$1" > "$t.tmp.$$" && mv -f "$t.tmp.$$" "$t" || { rm -f "$t.tmp.$$"; die "cannot write $t"; }
    chmod 600 "$t" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------- main
main() {
    local cmd
    cmd=${1:-}
    [ $# -gt 0 ] && shift
    case $cmd in
    help|-h|--help) usage; exit 0 ;;
    '') die_usage "missing command" ;;
    esac
    check_settings
    case $cmd in
    install) [ $# -eq 0 ] || die_usage "install takes no arguments"; cmd_install ;;
    enable-events)
        [ $# -eq 0 ] || die_usage "enable-events takes no arguments"
        script_add service-event "$SE_LINE" || die "service-event line not added" ;;
    set-level)
        [ $# -eq 1 ] || die_usage "set-level ro|full"
        case $1 in ro|full) cmd_set_level "$1" ;; *) die_usage "set-level ro|full" ;; esac ;;
    mount) [ $# -eq 0 ] || die_usage "mount takes no arguments"; cmd_mount ;;
    status) [ $# -eq 0 ] || die_usage "status takes no arguments"; status_now || exit 1 ;;
    service_event) cmd_service_event "$@" ;;
    uninstall) [ $# -eq 0 ] || die_usage "uninstall takes no arguments"; cmd_uninstall || exit 1 ;;
    __webui)
        # internal, run by flock with the shared addon lock held
        [ $# -eq 1 ] || exit 2
        case $1 in
        mount) webui_mount || exit 1 ;;
        unmount) webui_unmount || exit 1 ;;
        *) exit 2 ;;
        esac ;;
    *) die_usage "unknown command '$cmd'" ;;
    esac
    exit 0
}

main "$@"
