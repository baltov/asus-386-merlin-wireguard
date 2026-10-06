#!/bin/sh
# wgc.sh - WireGuard client tunnels wgc1..wgc5 with policy-routing rules
# for Asuswrt-Merlin (BusyBox ash). How it works, the numbering and the
# reasons behind the ip rule / iptables layout: docs/design.md.
#
#   wgc.sh check   [N|all]            validate conf(s) + rules, print summary
#   wgc.sh start   [N|all]            bring tunnel(s) up, (re)apply rules
#   wgc.sh stop    [N|all]            remove everything created for the tunnel(s)
#   wgc.sh status  [N|all]            0 up+handshake, 1 down, 3 stale handshake
#   wgc.sh try     [N|all] [seconds]  start, auto-stop unless confirmed
#   wgc.sh confirm                    cancel the pending auto-stop
#
# External commands (all present on the router): awk logger sort head cut tr
# wc date sed grep printf sleep kill cat rm mv chmod mkdir rmdir md5sum dd,
# plus ip wg iptables modprobe. No mktemp, od or id there.

LC_ALL=C
export LC_ALL
umask 077
set -f
PATH="$PATH:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# ---------------------------------------------------------------- settings

WGC_DIR=${WGC_DIR:-}
WGC_LAN_IF=${WGC_LAN_IF:-br0}
WGC_RUN_DIR=${WGC_RUN_DIR:-/tmp/wgc.run}
WGC_PRIO_BASE=${WGC_PRIO_BASE:-11300}
WGC_TABLE_BASE=${WGC_TABLE_BASE:-120}
WGC_HANDSHAKE_MAX=${WGC_HANDSHAKE_MAX:-180}

WGC_TRY_DEFAULT=300      # seconds before "try" stops the tunnel(s)
WGC_TRY_MIN=10
WGC_TRY_MAX=3600
WGC_LOCK_TRIES=60        # one-second attempts to get the lock
WGC_LOCK_TRIES_WD=300    # same, for the try watchdog
WGC_LOCK_TRIES_WGC=600   # stop: total polls while the holder is a live wgc.sh
WGC_DEL_MAX=200          # bound for every "ip rule del until it fails" loop
WGC_IPT_DEL_MAX=50       # bound for iptables deletions per chain and pass
WGC_IPT_PASSES=10        # bound for iptables list/delete passes
WGC_FILE_MAX=65536       # bytes per conf / rules file
# Hard limits (docs/development.md): the configurable bases must stay inside them.
WGC_PRIO_MIN=11300
WGC_PRIO_LIMIT=11899
WGC_TABLE_MIN=121
WGC_TABLE_LIMIT=125
WGC_IPT_RULES="raw input forward markout markin masq mssout mssin"
WGC_IPT_CHAINS="raw:PREROUTING filter:INPUT filter:FORWARD nat:POSTROUTING mangle:FORWARD mangle:PREROUTING"

MYPID=$$
case $0 in
/*) SELF=$0 ;;
*) SELF="$(pwd)/$0" ;;
esac

TMPF=          # temp file to remove on exit
CUR_N=         # tunnel being started (rolled back on a signal)
TRY_TARGET=    # target of a running "try" (whole target stopped on failure)
WD_PID=        # watchdog launched by this "try"
LOCK_HELD=
LAN=           # LAN network, network form, e.g. 192.168.2.0/24
LAN_IP=        # router address on the LAN
RULES_ALL=     # validated rules: one "N source destination" per line

# ---------------------------------------------------------------- awk code
# Shared POSIX awk helpers. IPv4 numbers stay below 2^32, exact in doubles.

AWK_LIB='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
# canonical unsigned decimal: digits only, no leading zero, value <= max
function dec(s, max) {
    if (s !~ /^[0-9]+$/ || length(s) > 10) return 0
    if (length(s) > 1 && substr(s, 1, 1) == "0") return 0
    return (s + 0 <= max)
}
function v4ok(s,   a, i) {
    if (s !~ /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/) return 0
    split(s, a, "[.]")
    for (i = 1; i <= 4; i++) if (!dec(a[i], 255)) return 0
    return 1
}
function v4num(s,   a) { split(s, a, "[.]"); return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4] }
function n2ip(n,   a, b, c) {
    a = int(n / 16777216); n -= a * 16777216
    b = int(n / 65536); n -= b * 65536
    c = int(n / 256); n -= c * 256
    return a "." b "." c "." n
}
function netof(n, p) { return n - n % (2 ^ (32 - p)) }
function overlap(n1, p1, n2, p2,   p) { p = (p1 < p2) ? p1 : p2; return netof(n1, p) == netof(n2, p) }
# cidr(s): "a.b.c.d" or "a.b.c.d/p" -> 1 and sets C_N, C_P (32 if absent), C_HASP
function cidr(s,   i, ip, p) {
    i = index(s, "/")
    if (i) { ip = substr(s, 1, i - 1); p = substr(s, i + 1); C_HASP = 1 }
    else { ip = s; p = "32"; C_HASP = 0 }
    if (!v4ok(ip) || !dec(p, 32)) return 0
    C_N = v4num(ip); C_P = p + 0
    return 1
}
function isnet() { return C_N % (2 ^ (32 - C_P)) == 0 }
function b64key(s) { return length(s) == 44 && s ~ /^[A-Za-z0-9+\/]+=$/ }
function lastcolon(s,   i, j) { j = 0; for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == ":") j = i; return j }
# input limits, re-checked while reading (the file may change after the shell check)
function limits() {
    TOT += length($0) + 1
    if (TOT > 65536) { print "err file larger than 65536 bytes"; errs++; LIMIT = 1; exit 2 }
    if ($0 ~ /[^\t\r -~]/) { print "err line " NR ": byte outside printable ASCII"; errs++; LIMIT = 1; exit 2 }
}
'

# Rules file -> "N source destination" lines, or "line X: reason" + exit 2.
RULES_AWK='
BEGIN { cidr(lan); LN = C_N; LP = C_P; RIP = v4num(rip) }
function bad(m) { print "line " NR ": " m; errs++ }
function chk(x, src) {
    if (x == "any") return 1
    if (!cidr(x)) { bad("invalid address or CIDR"); return 0 }
    if (!isnet()) { bad("CIDR has host bits set"); return 0 }
    if (src && !(C_P >= LP && netof(C_N, LP) == LN)) { bad("source is not inside the LAN " lan); return 0 }
    if (src && C_P == 32 && C_N == RIP) { bad("source is the router itself"); return 0 }
    if (!src && overlap(C_N, C_P, LN, LP)) { bad("destination overlaps the LAN " lan); return 0 }
    return 1
}
{
    limits()
    line = $0; sub(/\r$/, "", line)
    c = index(line, "#"); if (c) line = substr(line, 1, c - 1)
    n = split(line, f, " ")
    if (n == 0) next
    if (n != 3) { bad("expected three fields: tunnel source destination"); next }
    if (f[1] !~ /^wgc[1-5]$/) { bad("tunnel must be wgc1..wgc5"); next }
    if (!chk(f[2], 1) || !chk(f[3], 0)) next
    t = substr(f[1], 4)
    if (++cnt[t] == 100) bad("more than 99 rules for " f[1])
    out[++no] = t " " f[2] " " f[3]
}
END { if (LIMIT || errs) exit 2; for (i = 1; i <= no; i++) print out[i] }
'

# wg-quick conf. mode=info: validated non-secret summary ("err ..." lines on
# failure). mode=wg: the copy for "wg setconf" (wg-quick-only keys removed).
# Secrets are printed in mode=wg only, whose stdout is the private temp file.
CONF_AWK='
BEGIN { cidr(lan); LN = C_N; LP = C_P; mtu = 1420 }
function bad(m) { errs++; if (mode == "info") print "err line " NR ": " m }
function badg(m) { errs++; if (mode == "info") print "err " m }
function emit(s) { if (mode == "wg") print s }
function once(k) { if (seen[k]++) { bad("duplicate key"); return 0 } return 1 }
function v6ish(x) { return x ~ /^[0-9A-Fa-f:.]+(\/[0-9]+)?$/ }
function addrs(v,   a, n, i, x, o) {
    n = split(v, a, ",")
    for (i = 1; i <= n; i++) {
        x = trim(a[i])
        if (index(x, ":")) { if (!v6ish(x)) bad("invalid IPv6 Address"); continue }
        if (!cidr(x)) { bad("invalid IPv4 Address"); continue }
        o = int(C_N / 16777216)
        if (o == 0 || o == 127 || o >= 224) { bad("Address is not a usable unicast address"); continue }
        if (overlap(C_N, 32, LN, LP)) { bad("Address is inside the LAN " lan); continue }
        # the prefix from the conf is ignored: always a /32 (no route in main)
        addr = n2ip(C_N) "/32"; na++
    }
}
function allowed(v,   a, n, i, x, keep) {
    n = split(v, a, ","); keep = ""
    for (i = 1; i <= n; i++) {
        x = trim(a[i])
        if (index(x, ":")) {
            if (!v6ish(x)) { bad("invalid IPv6 AllowedIPs entry"); continue }
        } else {
            if (!cidr(x)) { bad("invalid IPv4 AllowedIPs entry"); continue }
            if (!isnet()) { bad("AllowedIPs entry has host bits set"); continue }
            x = n2ip(C_N) "/" C_P
            if (++nr > 64) { if (nr == 65) bad("more than 64 IPv4 AllowedIPs entries"); continue }
            route[nr] = x
        }
        # BusyBox awk reads "name (" as a function call: no "var (expr)" concatenation
        if (keep != "") keep = keep ", "
        keep = keep x
    }
    if (keep != "") emit("AllowedIPs = " keep)
}
function endpoint(v,   j, h, p) {
    j = lastcolon(v)
    if (!j) { bad("Endpoint must be host:port"); return }
    h = substr(v, 1, j - 1); p = substr(v, j + 1)
    if (!dec(p, 65535) || p + 0 < 1) { bad("invalid Endpoint port"); return }
    if (h ~ /^[0-9.]+$/) {
        if (!v4ok(h)) { bad("invalid Endpoint address"); return }
    } else if (length(h) > 253 || h !~ /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/) {
        bad("Endpoint host must be an IPv4 address or a host name"); return
    }
    ep = v; emit("Endpoint = " v)
}
{
    limits()
    line = $0; sub(/\r$/, "", line)
    c = index(line, "#"); if (c) line = substr(line, 1, c - 1)
    line = trim(line)
    if (line == "") next
    if (substr(line, 1, 1) == "[") {
        s = tolower(line)
        if (s == "[interface]") { sec = "i"; if (++ni == 1) emit("[Interface]"); else bad("more than one [Interface]") }
        else if (s == "[peer]") { sec = "p"; if (++np == 1) emit("[Peer]"); else bad("more than one [Peer]") }
        else { sec = "?"; bad("unknown section") }
        next
    }
    e = index(line, "=")
    if (!e) { bad("expected key = value"); next }
    k = tolower(trim(substr(line, 1, e - 1))); v = trim(substr(line, e + 1))
    if (sec == "") { bad("key outside a section"); next }
    if (sec == "?") next
    if (sec == "i") {
        if (k == "privatekey") { if (once(k)) { if (b64key(v)) { emit("PrivateKey = " v); havepriv = 1 } else bad("invalid PrivateKey") } }
        else if (k == "address") addrs(v)
        else if (k == "mtu") { if (once(k)) { if (dec(v, 1500) && v + 0 >= 1280) mtu = v + 0; else bad("MTU must be 1280-1500") } }
        else if (k == "listenport") { if (once(k)) { if (dec(v, 65535) && v + 0 >= 1) emit("ListenPort = " v); else bad("invalid ListenPort") } }
        else if (k ~ /^(dns|table|preup|postup|predown|postdown|saveconfig)$/) { }
        else bad("unsupported key in [Interface]")
    } else {
        if (k == "publickey") { if (once(k)) { if (b64key(v)) { emit("PublicKey = " v); pub = v } else bad("invalid PublicKey") } }
        else if (k == "presharedkey") { if (once(k)) { if (b64key(v)) { emit("PresharedKey = " v); psk = 1 } else bad("invalid PresharedKey") } }
        else if (k == "allowedips") allowed(v)
        else if (k == "endpoint") { if (once(k)) endpoint(v) }
        else if (k == "persistentkeepalive") { if (once(k)) { if (v == "off" || dec(v, 65535)) emit("PersistentKeepalive = " v); else bad("invalid PersistentKeepalive") } }
        else bad("unsupported key in [Peer]")
    }
}
END {
    if (LIMIT) exit 2
    if (ni != 1) badg("need exactly one [Interface] section")
    if (np != 1) badg("need exactly one [Peer] section")
    if (!havepriv) badg("PrivateKey missing")
    if (na != 1) badg("Address needs exactly one IPv4 address")
    if (pub == "") badg("PublicKey missing")
    if (nr < 1) badg("AllowedIPs needs at least one IPv4 network")
    if (ep == "") badg("Endpoint missing")
    if (errs) exit 2
    if (mode == "info") {
        print "addr " addr; print "mtu " mtu; print "pub " pub; print "endpoint " ep
        print "psk " (psk ? "yes" : "no")
        for (i = 1; i <= nr; i++) print "route " route[i]
    }
}
'

# ours(): an "iptables -S" line of chain c whose -i or -o value is interface i,
# whitelisted characters only. The same filter decides deletion and verification.
IPT_FILTER='
function ours(   k) {
    if ($1 != "-A" || $2 != c || $0 ~ /[^A-Za-z0-9_.,:\/+ -]/) return 0
    for (k = 3; k < NF; k++) if (($k == "-i" || $k == "-o") && $(k + 1) == i) return 1
    return 0
}
'

# ---------------------------------------------------------------- output

log_msg() { logger -t wgc "$1" 2>/dev/null; }
say() { printf '%s\n' "$1"; log_msg "$1"; }
warn() { printf '%s\n' "$1" >&2; log_msg "$1"; }

usage() {
    cat <<'EOF'
usage: wgc.sh check   [N|all]
       wgc.sh start   [N|all]
       wgc.sh stop    [N|all]
       wgc.sh status  [N|all]
       wgc.sh try     [N|all] [seconds]     (seconds 10-3600, default 300)
       wgc.sh confirm
N is 1-5; without N the command applies to all tunnels.
EOF
}

die_usage() {
    [ -n "$1" ] && printf 'wgc: %s\n' "$1" >&2
    usage >&2
    exit 2
}

# ---------------------------------------------------------------- helpers

cleanup() {
    if [ -n "$TMPF" ]; then rm -f "$TMPF"; fi
    TMPF=
    lock_release
}

on_signal() {
    trap '' INT TERM HUP
    if [ -n "$TMPF" ]; then rm -f "$TMPF"; fi
    TMPF=
    if [ -n "$TRY_TARGET" ]; then
        warn "try $TRY_TARGET: interrupted, stopping $TRY_TARGET"
        try_abort
    elif [ -n "$CUR_N" ]; then
        warn "wgc$CUR_N: interrupted, rolling back"
        stop_one "$CUR_N"
    elif [ -n "$WD_PID" ]; then
        # watchdog launched but nothing changed yet
        kill -9 "$WD_PID" 2>/dev/null
    fi
    exit 1
}

# canonical decimal within [min, max]
num_in() {
    case $1 in ''|*[!0-9]*|0?*) return 1 ;; esac
    [ ${#1} -le 9 ] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

# last line of defence before a value reaches ip/iptables argv
argsafe() {
    case $1 in ''|-*|*[!0-9./]*) return 1 ;; esac
    return 0
}

rand_hex() {    # 32 hex digits
    local h
    h=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | md5sum | cut -c1-32)
    case $h in *[!0-9a-f]*) return 1 ;; esac
    [ ${#h} -eq 32 ] || return 1
    printf '%s\n' "$h"
}

# create a new file without following or replacing anything (noclobber)
create_new() {
    ( set -C; : > "$1" ) 2>/dev/null
}

check_settings() {
    num_in "$WGC_PRIO_BASE" "$WGC_PRIO_MIN" $((WGC_PRIO_LIMIT - 598)) ||
        die_usage "WGC_PRIO_BASE must keep all priorities within $WGC_PRIO_MIN-$WGC_PRIO_LIMIT"
    num_in "$WGC_TABLE_BASE" $((WGC_TABLE_MIN - 1)) $((WGC_TABLE_LIMIT - 5)) ||
        die_usage "WGC_TABLE_BASE must keep all tables within $WGC_TABLE_MIN-$WGC_TABLE_LIMIT"
    num_in "$WGC_HANDSHAKE_MAX" 1 86400 || die_usage "WGC_HANDSHAKE_MAX must be 1-86400"
    case $WGC_LAN_IF in
    [a-z]|[a-z]*[a-z0-9]) ;;
    *) die_usage "invalid WGC_LAN_IF" ;;
    esac
    case $WGC_LAN_IF in *[!a-z0-9]*) die_usage "invalid WGC_LAN_IF" ;; esac
    [ ${#WGC_LAN_IF} -le 15 ] || die_usage "invalid WGC_LAN_IF"
    # never the loopback or one of our own tunnels
    case $WGC_LAN_IF in lo|wgc*) die_usage "WGC_LAN_IF must be the LAN bridge, not $WGC_LAN_IF" ;; esac
    case $WGC_RUN_DIR in
    /*) ;;
    *) die_usage "WGC_RUN_DIR must be an absolute path" ;;
    esac
    case $WGC_RUN_DIR in *'
'*) die_usage "invalid WGC_RUN_DIR" ;; esac
    if [ -z "$WGC_DIR" ]; then
        WGC_DIR=$(cd "${SELF%/*}" 2>/dev/null && pwd) || die_usage "cannot find the script directory"
    fi
}

# private run dir: created 700; a symlink or non-directory is refused
ensure_run_dir() {
    local d
    d=$WGC_RUN_DIR
    if [ -L "$d" ]; then warn "WGC_RUN_DIR $d is a symlink, nothing changed"; return 1; fi
    if [ ! -e "$d" ]; then
        mkdir -m 700 "$d" 2>/dev/null
    fi
    if [ -L "$d" ] || [ ! -d "$d" ]; then
        warn "WGC_RUN_DIR $d is not a usable directory, nothing changed"
        return 1
    fi
    chmod 700 "$d" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------- lock

# lock_pid_of <dir>: sets LPID to the valid pid stored in <dir>/pid, or empty
lock_pid_of() {
    local f p
    f="$1/pid"
    LPID=
    [ -f "$f" ] && [ ! -L "$f" ] || return 0
    p=
    read -r p < "$f" 2>/dev/null
    if num_in "$p" 1 999999999; then LPID=$p; fi
}

# lock_steal <expected pid|""|any>: take the lock over by atomic rename; a
# racing taker loses the rename and simply retries mkdir
lock_steal() {
    local d g
    d="$WGC_RUN_DIR/lock"
    g="$d.dead.$MYPID"
    rm -rf "$g" 2>/dev/null
    mv "$d" "$g" 2>/dev/null || return 1
    if [ "$1" != any ]; then
        lock_pid_of "$g"
        if [ "$LPID" != "$1" ] && [ ! -e "$d" ]; then
            # it changed hands between our check and the rename: give it back
            mv "$g" "$d" 2>/dev/null && return 1
        fi
    fi
    rm -rf "$g" 2>/dev/null
    return 0
}

token_pending() {   # true while wgc.pending still holds token $1
    pending_read && [ "$P_TOK" = "$1" ]
}

# proc_cmdline PID: printable command line of a live process, or nothing
proc_cmdline() {
    local f
    f="/proc/$1/cmdline"
    [ -r "$f" ] || return 0
    tr '\0' ' ' < "$f" 2>/dev/null | tr -cd 'A-Za-z0-9 ._/=:,+-' | cut -c1-120
}

# lock_acquire <tries> <strict|force> [token] [wgc-tries]
#   strict: give up after the wait (exit 1 for the caller, nothing changed)
#   force:  after the wait take the lock anyway (stop and the try watchdog)
#   token:  give up (return 2) as soon as wgc.pending no longer holds it
#   wgc-tries: force only: total polls while the holder is a live wgc.sh
lock_acquire() {
    local d max mode tok wmax n live final forced cmd desc
    d="$WGC_RUN_DIR/lock"
    max=$1 mode=$2 tok=$3 wmax=${4:-$1}
    n=0 live= final= forced=0
    while :; do
        if [ -n "$tok" ] && ! token_pending "$tok"; then return 2; fi
        if [ ! -e "$d" ] && [ ! -L "$d" ] && mkdir -m 700 "$d" 2>/dev/null; then
            if ( set -C; printf '%s\n' "$MYPID" > "$d/pid" ) 2>/dev/null; then
                LOCK_HELD=1
                return 0
            fi
            rm -rf "$d" 2>/dev/null
            warn "cannot write the lock pid file in $d"
            [ "$mode" = force ] && { warn "proceeding without the lock"; return 0; }
            return 1
        fi
        [ -n "$final" ] && break
        if [ -e "$d" ] || [ -L "$d" ]; then
            if [ -L "$d" ] || [ ! -d "$d" ]; then
                if [ "$mode" = force ] && [ $forced -lt 5 ]; then
                    warn "removing $d: not a lock directory"
                    rm -f "$d"
                    forced=$((forced + 1))
                    continue
                fi
                [ "$mode" = force ] && { warn "proceeding without the lock"; return 0; }
                warn "$d is not a lock directory, nothing changed; recover with: rm -rf $d"
                return 1
            fi
            lock_pid_of "$d"
            if [ -n "$LPID" ]; then
                if kill -0 "$LPID" 2>/dev/null; then
                    live=1
                elif lock_steal "$LPID"; then
                    log_msg "took over a stale lock of pid $LPID"
                    continue
                fi
            fi
        fi
        n=$((n + 1))
        if [ $n -ge "$max" ]; then
            lock_pid_of "$d"
            if [ "$mode" = force ]; then
                if [ $forced -ge 5 ]; then warn "proceeding without the lock"; return 0; fi
                desc="no valid pid"
                if [ -n "$LPID" ] && kill -0 "$LPID" 2>/dev/null; then
                    cmd=$(proc_cmdline "$LPID")
                    case $cmd in
                    *wgc.sh*)
                        # another wgc.sh is working: give it up to wgc-tries polls in total
                        if [ $n -lt "$wmax" ]; then sleep 1; continue; fi
                        desc="pid $LPID (wgc.sh: $cmd)" ;;
                    '') desc="pid $LPID (unknown live process)" ;;
                    *) desc="pid $LPID ($cmd)" ;;
                    esac
                elif [ -n "$LPID" ]; then
                    desc="pid $LPID"
                fi
                forced=$((forced + 1))
                warn "forcing lock held by $desc"
                lock_steal any
                continue
            fi
            # no valid pid for the whole wait: the holder never finished writing it
            if [ -z "$live" ] && [ -z "$LPID" ] && lock_steal ""; then
                final=1
                continue
            fi
            break
        fi
        sleep 1
    done
    warn "another wgc.sh holds the lock, nothing changed; if no wgc.sh is running, recover with: rm -rf $d"
    return 1
}

lock_release() {
    local d
    [ -n "$LOCK_HELD" ] || return 0
    LOCK_HELD=
    d="$WGC_RUN_DIR/lock"
    lock_pid_of "$d"
    [ "$LPID" = "$MYPID" ] || return 0
    rm -f "$d/pid"
    rmdir "$d" 2>/dev/null
}

# ---------------------------------------------------------------- loaders

# LAN network and router address of $WGC_LAN_IF -> $LAN, $LAN_IP
load_lan() {
    local out r
    LAN= LAN_IP=
    out=$(ip -4 -o addr show dev "$WGC_LAN_IF" 2>/dev/null) || return 1
    r=$(printf '%s\n' "$out" | awk "$AWK_LIB"'
        { for (i = 1; i < NF; i++) if ($i == "inet") {
              if (cidr($(i + 1)) && C_HASP && C_P >= 8 && C_P <= 30)
                  print n2ip(netof(C_N, C_P)) "/" C_P, n2ip(C_N)
              exit } }')
    LAN=${r% *} LAN_IP=${r#* }
    if ! argsafe "$LAN" || ! argsafe "$LAN_IP" || [ "$LAN" = "$LAN_IP" ]; then
        LAN= LAN_IP=
        return 1
    fi
}

# size, byte and type limits for a conf / rules file
input_ok() {
    local f what sz bad
    f=$1 what=$2
    if [ ! -f "$f" ]; then warn "$what: $f is not a regular file"; return 1; fi
    if [ ! -r "$f" ]; then warn "$what: $f is not readable"; return 1; fi
    sz=$(wc -c < "$f" | tr -d ' ')
    if ! num_in "$sz" 0 "$WGC_FILE_MAX"; then
        warn "$what: larger than $WGC_FILE_MAX bytes"; return 1
    fi
    bad=$(tr -d '\11\12\15\40-\176' < "$f" | wc -c | tr -d ' ')
    if [ "$bad" != 0 ]; then warn "$what: contains bytes outside printable ASCII"; return 1; fi
    return 0
}

# validate the whole rules file -> $RULES_ALL; missing file = no rules
load_rules() {
    local f out
    f="$WGC_DIR/rules"
    RULES_ALL=
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then return 0; fi
    input_ok "$f" rules || { warn "rules: invalid, nothing changed"; return 2; }
    if ! out=$(awk -v lan="$LAN" -v rip="$LAN_IP" "$AWK_LIB$RULES_AWK" < "$f"); then
        warn "rules: invalid, nothing changed"
        printf '%s\n' "$out" | sed 's/^\(err \)*/rules: /' >&2
        return 2
    fi
    RULES_ALL=$out
}

# validate wgcN.conf -> C_ADDR C_MTU C_PUB C_EP C_PSK C_ROUTES (no secrets)
load_conf() {
    local n f out k v
    n=$1
    f="$WGC_DIR/wgc$n.conf"
    C_ADDR= C_MTU= C_PUB= C_EP= C_PSK= C_ROUTES=
    input_ok "$f" "wgc$n.conf" || { warn "wgc$n: invalid wgc$n.conf, nothing changed"; return 2; }
    if ! out=$(awk -v mode=info -v lan="$LAN" "$AWK_LIB$CONF_AWK" < "$f"); then
        warn "wgc$n: invalid wgc$n.conf, nothing changed"
        printf '%s\n' "$out" | sed "s/^err /wgc$n.conf: /" >&2
        return 2
    fi
    while read -r k v; do
        case $k in
        addr) C_ADDR=$v ;;
        mtu) C_MTU=$v ;;
        pub) C_PUB=$v ;;
        endpoint) C_EP=$v ;;
        psk) C_PSK=$v ;;
        route) C_ROUTES="$C_ROUTES $v" ;;
        esac
    done <<EOF
$out
EOF
    argsafe "$C_ADDR" && argsafe "$C_MTU" || { warn "wgc$n: internal validation error"; return 2; }
    for v in $C_ROUTES; do
        argsafe "$v" || { warn "wgc$n: internal validation error"; return 2; }
    done
    return 0
}

# list of tunnel numbers for a target; "all" = those with a conf file
conf_targets() {
    local n list
    if [ "$1" != all ]; then printf '%s\n' "$1"; return; fi
    list=
    for n in 1 2 3 4 5; do
        if [ -e "$WGC_DIR/wgc$n.conf" ] || [ -L "$WGC_DIR/wgc$n.conf" ]; then list="$list $n"; fi
    done
    printf '%s\n' "$list"
}

# shared validation for check/start/try: LAN, rules, every targeted conf
validate_all() {
    local n rc
    load_lan || { warn "cannot determine the LAN network of $WGC_LAN_IF, nothing changed"; return 1; }
    rc=0
    load_rules || rc=2
    for n in $1; do
        load_conf "$n" >/dev/null || rc=2
    done
    return $rc
}

# ---------------------------------------------------------------- iptables / rules

# ipt_rule <check|ensure> <rule> <iface> <lan>
ipt_rule() {
    local op k i t c
    op=$1 k=$2 i=$3
    case $k in
    raw) set -- raw PREROUTING -i "$i" -s "$4" -j DROP ;;
    input) set -- filter INPUT -i "$i" -m state --state NEW,INVALID -j DROP ;;
    forward) set -- filter FORWARD -i "$i" -m state --state NEW,INVALID -j DROP ;;
    masq) set -- nat POSTROUTING -o "$i" -j MASQUERADE ;;
    mssout) set -- mangle FORWARD -o "$i" -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu ;;
    mssin) set -- mangle FORWARD -i "$i" -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu ;;
    # mark tunnel traffic so the Broadcom flow cache leaves it alone
    markout) set -- mangle FORWARD -o "$i" -j MARK --set-xmark 0x01/0x7 ;;
    markin) set -- mangle PREROUTING -i "$i" -j MARK --set-xmark 0x01/0x7 ;;
    *) return 1 ;;
    esac
    t=$1 c=$2
    shift 2
    case $op in
    check) iptables -t "$t" -C "$c" "$@" 2>/dev/null ;;
    ensure) iptables -t "$t" -C "$c" "$@" 2>/dev/null || iptables -t "$t" -I "$c" "$@" ;;
    esac
}

# One pass over our six chains: delete (at most 50 per chain) every rule where
# the interface is the value of -i or -o, as listed by "iptables -S" (also
# duplicates and rules with another LAN network). Sets IPT_DELETED.
ipt_pass() {
    local i tc t c out specs line
    i=$1
    IPT_DELETED=0
    for tc in $WGC_IPT_CHAINS; do
        t=${tc%%:*} c=${tc#*:}
        out=$(iptables -t "$t" -S "$c" 2>/dev/null) || continue
        specs=$(printf '%s\n' "$out" | awk -v c="$c" -v i="$i" -v max="$WGC_IPT_DEL_MAX" "$IPT_FILTER"'
            ours() { if (++n > max) exit; s = $0; sub(/^-A [^ ]+ /, "", s); print s }')
        while read -r line; do
            [ -n "$line" ] || continue
            # whitelisted characters only and globbing is off (set -f)
            set -- $line
            if iptables -t "$t" -D "$c" "$@" 2>/dev/null; then IPT_DELETED=$((IPT_DELETED + 1)); fi
        done <<EOF2
$specs
EOF2
    done
}

# repeat passes until one deletes nothing (bounded)
ipt_purge() {
    local pass
    pass=0
    while [ $pass -lt "$WGC_IPT_PASSES" ]; do
        ipt_pass "$1"
        [ "$IPT_DELETED" -gt 0 ] || break
        pass=$((pass + 1))
    done
}

# stop_verify N: sets LEFT to what is still there or cannot be checked
stop_verify() {
    local n i t p tc c out
    n=$1 i=wgc$1
    t=$((WGC_TABLE_BASE + n))
    p=$((WGC_PRIO_BASE + n))
    LEFT=
    if ip link show dev "$i" >/dev/null 2>&1; then LEFT="$LEFT; interface $i still exists"; fi
    if out=$(ip -4 rule show 2>/dev/null); then
        if printf '%s\n' "$out" | awk -v t="$t" -v p="$p:" '
            index($0, p) == 1 { f = 1 }
            { for (k = 1; k < NF; k++) if ($k == "lookup" && $(k + 1) == t) f = 1 }
            END { exit f ? 0 : 1 }'; then
            LEFT="$LEFT; ip rules with lookup $t or priority $p remain"
        fi
    else
        LEFT="$LEFT; cannot verify ip rules (ip -4 rule show failed)"
    fi
    for tc in $WGC_IPT_CHAINS; do
        t=${tc%%:*} c=${tc#*:}
        if out=$(iptables -t "$t" -S "$c" 2>/dev/null); then
            if printf '%s\n' "$out" | awk -v c="$c" -v i="$i" "$IPT_FILTER"'ours() { f = 1 } END { exit f ? 0 : 1 }'; then
                LEFT="$LEFT; iptables rules for $i remain in $t $c"
            fi
        else
            LEFT="$LEFT; cannot verify iptables $t $c (iptables -S failed)"
        fi
    done
    LEFT=${LEFT#; }
    [ -z "$LEFT" ]
}

# rule_del_all <priority|table> <value>: delete until it fails, bounded
rule_del_all() {
    local n
    n=0
    while [ $n -lt $WGC_DEL_MAX ] && ip -4 rule del "$1" "$2" 2>/dev/null; do
        n=$((n + 1))
    done
}

# add the shared rule B unless "ip -4 rule show" already has it
ensure_shared_rule() {
    local out
    out=$(ip -4 rule show) || return 1
    if printf '%s\n' "$out" | awk -v p="$WGC_PRIO_BASE:" 'index($0, p) == 1 { f = 1 } END { exit f ? 0 : 1 }'; then
        return 0
    fi
    ip -4 rule add from all lookup main suppress_prefixlength 0 priority "$WGC_PRIO_BASE"
}

any_wgc_link() {
    local n
    for n in 1 2 3 4 5; do
        if ip link show dev "wgc$n" >/dev/null 2>&1; then return 0; fi
    done
    return 1
}

pending_read() {    # sets P_TOK P_TGT from wgc.pending (validated)
    local f t g
    f="$WGC_RUN_DIR/wgc.pending"
    P_TOK= P_TGT=
    [ -f "$f" ] && [ ! -L "$f" ] || return 1
    t= g=
    read -r t g < "$f" 2>/dev/null
    case $t in ''|*[!0-9a-f]*) return 0 ;; esac
    case $g in all|[1-5]) ;; *) return 0 ;; esac
    P_TOK=$t P_TGT=$g
}

# ---------------------------------------------------------------- tunnel ops

# reconcile_old N: drop addresses and table routes no longer in the conf
reconcile_old() {
    local i t out a r x keep
    i=wgc$1
    t=$((WGC_TABLE_BASE + $1))
    out=$(ip -4 -o addr show dev "$i") || return 1
    for a in $(printf '%s\n' "$out" | awk '{ for (k = 1; k < NF; k++) if ($k == "inet") print $(k + 1) }'); do
        [ "$a" = "$C_ADDR" ] && continue
        argsafe "$a" || continue
        ip -4 address del "$a" dev "$i" || return 1
    done
    out=$(ip -4 route show table "$t") || return 1
    for r in $(printf '%s\n' "$out" | awk 'NF { print $1 }'); do
        [ "$r" = default ] || argsafe "$r" || continue
        keep=
        for x in $C_ROUTES; do
            [ "$x" = 0.0.0.0/0 ] && x=default
            if [ "${x%/32}" = "${r%/32}" ]; then keep=1; break; fi
        done
        [ -n "$keep" ] && continue
        ip -4 route del "$r" dev "$i" table "$t" || return 1
    done
}

# start_steps N: bring one tunnel up in a fixed order (DROP and MARK rules before
# the link goes up, shared and endpoint rules before the tunnel rules);
# returns 1 at the first failure
start_steps() {
    local n i t p k verb out ep s d rn rc f h
    n=$1 i=wgc$1
    t=$((WGC_TABLE_BASE + n))

    if ip link show dev "$i" >/dev/null 2>&1; then
        verb=syncconf
    else
        ip link add dev "$i" type wireguard || { warn "$i: cannot create interface"; return 1; }
        verb=setconf
    fi

    # Secrets go file -> file only: awk reads the conf, writes the 0600 temp file.
    h=$(rand_hex) || { warn "$i: cannot get random bytes"; return 1; }
    f="$WGC_RUN_DIR/.wgc$n.$h"
    create_new "$f" || { warn "$i: cannot create temp file"; return 1; }
    TMPF=$f
    if ! awk -v mode=wg -v lan="$LAN" "$AWK_LIB$CONF_AWK" < "$WGC_DIR/wgc$n.conf" > "$f"; then
        rm -f "$f"; TMPF=; warn "$i: wgc$n.conf changed or became invalid"; return 1
    fi
    # wg may quote offending conf lines on error, so its stderr is discarded
    wg "$verb" "$i" "$f" 2>/dev/null
    rc=$?
    rm -f "$f"; TMPF=
    [ $rc -eq 0 ] || { warn "$i: wg $verb failed (exit $rc)"; return 1; }
    if [ $verb = syncconf ]; then
        reconcile_old "$n" || { warn "$i: cannot remove old addresses or routes"; return 1; }
    fi

    for k in raw input forward markout markin; do
        ipt_rule ensure "$k" "$i" "$LAN" || { warn "$i: cannot install lock-down rule ($k)"; return 1; }
    done

    ip -4 address replace "$C_ADDR" dev "$i" || { warn "$i: cannot set address"; return 1; }
    ip link set dev "$i" mtu "$C_MTU" up || { warn "$i: cannot bring interface up"; return 1; }
    for p in $C_ROUTES; do
        [ "$p" = 0.0.0.0/0 ] && p=default
        ip -4 route replace "$p" dev "$i" table "$t" || { warn "$i: cannot add route to table $t"; return 1; }
    done

    out=$(wg show "$i" endpoints 2>/dev/null) || { warn "$i: cannot read endpoint"; return 1; }
    ep=$(printf '%s\n' "$out" | awk "$AWK_LIB"'
        NF { n++; e = $2 }
        END { if (n != 1) exit 1
              j = lastcolon(e); h = substr(e, 1, j - 1); p = substr(e, j + 1)
              if (!j || !v4ok(h) || !dec(p, 65535)) exit 1
              print h }') || ep=
    argsafe "$ep" || { warn "$i: no usable IPv4 endpoint"; return 1; }

    ensure_shared_rule || { warn "$i: cannot add shared rule $WGC_PRIO_BASE"; return 1; }
    p=$((WGC_PRIO_BASE + n))
    rule_del_all priority "$p"
    ip -4 rule add to "$ep" lookup main priority "$p" || { warn "$i: cannot add endpoint rule"; return 1; }

    rule_del_all table "$t"
    # check again: the shared rule must exist right before any tunnel rule
    ensure_shared_rule || { warn "$i: cannot add shared rule $WGC_PRIO_BASE"; return 1; }
    k=0
    while read -r rn s d; do
        [ "$rn" = "$n" ] || continue
        set -- iif "$WGC_LAN_IF"
        if [ "$s" != any ]; then argsafe "$s" || { warn "$i: bad rule source"; return 1; }; set -- "$@" from "$s"; fi
        if [ "$d" != any ]; then argsafe "$d" || { warn "$i: bad rule destination"; return 1; }; set -- "$@" to "$d"; fi
        p=$((WGC_PRIO_BASE + 100 * n + k))
        ip -4 rule add "$@" lookup "$t" priority "$p" || { warn "$i: cannot add rule $p"; return 1; }
        k=$((k + 1))
    done <<EOF
$RULES_ALL
EOF

    for k in masq mssout mssin; do
        ipt_rule ensure "$k" "$i" "$LAN" || { warn "$i: cannot install iptables rule ($k)"; return 1; }
    done
    return 0
}

start_one() {
    local n cnt
    n=$1
    load_conf "$n" || return 1
    cnt=$(printf '%s\n' "$RULES_ALL" | awk -v n="$n" '$1 == n { c++ } END { print c + 0 }')
    CUR_N=$n
    if start_steps "$n"; then
        CUR_N=
        say "wgc$n: up, table $((WGC_TABLE_BASE + n)), $cnt rule(s)"
        return 0
    fi
    CUR_N=
    warn "wgc$n: start failed, rolling back"
    stop_one "$n"
    return 1
}

# stop_one N: needs neither conf nor rules nor run files; verifies the result.
# Returns 1 (with a message saying what) if anything is left or unverifiable.
stop_one() {
    local n i t f
    n=$1 i=wgc$1
    t=$((WGC_TABLE_BASE + n))
    rule_del_all table "$t"
    rule_del_all priority $((WGC_PRIO_BASE + n))
    ipt_purge "$i"
    if ip link show dev "$i" >/dev/null 2>&1; then
        ip link del dev "$i" 2>/dev/null
    fi
    if ! any_wgc_link; then rule_del_all priority "$WGC_PRIO_BASE"; fi
    # leftover secret temp files of any type (e.g. after SIGKILL); rm never follows a symlink
    if [ -d "$WGC_RUN_DIR" ] && [ ! -L "$WGC_RUN_DIR" ]; then
        set +f
        set -- "$WGC_RUN_DIR"/.wgc"$n".*
        set -f
        for f in "$@"; do
            if [ -e "$f" ] || [ -L "$f" ]; then rm -rf "$f"; fi
        done
    fi
    if stop_verify "$n"; then return 0; fi
    warn "$i: stop incomplete: $LEFT"
    return 1
}

# status_one N -> 0 up, protected, fresh handshake; 1 down or DEGRADED;
# 3 up and protected but stale/no handshake
status_one() {
    local n i t hs k age out miss
    n=$1 i=wgc$1
    t=$((WGC_TABLE_BASE + n))
    if ! ip link show dev "$i" >/dev/null 2>&1; then
        printf '%s\n' "$i: down"
        return 1
    fi
    miss=
    wg show "$i" 2>/dev/null
    printf '%s\n' "routes (table $t):"
    ip -4 route show table "$t" 2>/dev/null
    printf '%s\n' "rules:"
    if out=$(ip -4 rule show 2>/dev/null); then
        printf '%s\n' "$out" | awk -v t="$t" -v p="$((WGC_PRIO_BASE + n)):" -v b="$WGC_PRIO_BASE:" '
            index($0, p) == 1 || index($0, b) == 1 { print; next }
            { for (i = 1; i < NF; i++) if ($i == "lookup" && $(i + 1) == t) { print; next } }'
        printf '%s\n' "$out" | awk -v b="$WGC_PRIO_BASE:" 'index($0, b) == 1 { f = 1 } END { exit !f }' ||
            miss="$miss, shared rule $WGC_PRIO_BASE"
        printf '%s\n' "$out" | awk -v p="$((WGC_PRIO_BASE + n)):" 'index($0, p) == 1 { f = 1 } END { exit !f }' ||
            miss="$miss, endpoint rule $((WGC_PRIO_BASE + n))"
    else
        miss="$miss, ip rules (cannot list)"
    fi
    printf '%s\n' "iptables:"
    [ -n "$LAN" ] || load_lan
    for k in $WGC_IPT_RULES; do
        if [ "$k" = raw ] && [ -z "$LAN" ]; then
            printf '  %-8s %s\n' "$k" "unknown (no LAN network)"
            miss="$miss, iptables $k (LAN network unknown)"
        elif ipt_rule check "$k" "$i" "$LAN"; then
            printf '  %-8s %s\n' "$k" "present"
        else
            printf '  %-8s %s\n' "$k" "MISSING"
            miss="$miss, iptables $k"
        fi
    done
    if [ -n "$miss" ]; then
        printf '%s\n' "$i: DEGRADED - interface up but missing: ${miss#, }"
        return 1
    fi
    hs=$(wg show "$i" latest-handshakes 2>/dev/null | awk 'NF { print $2; exit }')
    case $hs in
    ''|*[!0-9]*) printf '%s\n' "$i: up, handshake unknown"; return 3 ;;
    0) printf '%s\n' "$i: up, no handshake yet"; return 3 ;;
    esac
    age=$(awk -v now="$(date +%s)" -v h="$hs" 'BEGIN { print now - h }')
    if awk -v a="$age" -v m="$WGC_HANDSHAKE_MAX" 'BEGIN { exit (a <= m) ? 0 : 1 }'; then
        printf '%s\n' "$i: up, last handshake ${age}s ago"
        return 0
    fi
    printf '%s\n' "$i: up, handshake stale (${age}s ago)"
    return 3
}

# ---------------------------------------------------------------- commands

cmd_check() {
    local list n rn s d cnt p rc
    list=$(conf_targets "$1")
    [ -n "$list" ] || { warn "no wgcN.conf found in $WGC_DIR"; return 2; }
    validate_all "$list"; rc=$?
    [ $rc -eq 1 ] && return 1
    printf '%s\n' "LAN network: $LAN ($WGC_LAN_IF, router $LAN_IP)"
    for n in $list; do
        load_conf "$n" 2>/dev/null || { printf '%s\n' "wgc$n: INVALID (see errors above)"; continue; }
        printf '%s\n' "wgc$n: OK"
        printf '  %-12s %s\n' interface "wgc$n" address "$C_ADDR" mtu "$C_MTU" \
            table "$((WGC_TABLE_BASE + n))" endpoint "$C_EP" peer "$C_PUB" \
            presharedkey "$C_PSK"
        for p in $C_ROUTES; do printf '  %-12s %s\n' route "$p"; done
        cnt=0
        while read -r rn s d; do
            [ "$rn" = "$n" ] || continue
            p=$((WGC_PRIO_BASE + 100 * n + cnt))
            printf '  %-12s %s\n' "rule $p" "iif $WGC_LAN_IF from $s to $d lookup $((WGC_TABLE_BASE + n))"
            cnt=$((cnt + 1))
        done <<EOF
$RULES_ALL
EOF
        [ $cnt -gt 0 ] || printf '%s\n' "  WARNING: wgc$n has no rules - the tunnel will come up but carry no traffic"
    done
    for n in 1 2 3 4 5; do
        case " $list " in *" $n "*) continue ;; esac
        if printf '%s\n' "$RULES_ALL" | awk -v n="$n" '$1 == n { f = 1 } END { exit !f }'; then
            printf '%s\n' "WARNING: rules exist for wgc$n but it is not checked here"
        fi
    done
    return $rc
}

# start every tunnel in $1 (validated already, lock held)
apply_start() {
    local n rc
    modprobe wireguard || { warn "modprobe wireguard failed, nothing changed"; return 1; }
    rc=0
    for n in $1; do
        start_one "$n" || rc=1
    done
    return $rc
}

cmd_start() {
    local list
    list=$(conf_targets "$1")
    [ -n "$list" ] || { warn "no wgcN.conf found in $WGC_DIR, nothing to start"; return 2; }
    ensure_run_dir || return 1
    lock_acquire "$WGC_LOCK_TRIES" strict || return 1
    validate_all "$list" || return $?
    apply_start "$list"
}

# run_rm_glob PREFIX: remove $WGC_RUN_DIR/PREFIX* of any type (never follows a symlink)
run_rm_glob() {
    local f
    [ -d "$WGC_RUN_DIR" ] && [ ! -L "$WGC_RUN_DIR" ] || return 0
    set +f
    set -- "$WGC_RUN_DIR"/"$1"*
    set -f
    for f in "$@"; do
        if [ -e "$f" ] || [ -L "$f" ]; then rm -rf "$f"; fi
    done
}

# stop the target (lock held); returns 1 if any tunnel was not fully stopped.
# Drops wgc.pending only after a complete stop that covers its target.
do_stop() {
    local n list rc
    if [ "$1" = all ]; then list="1 2 3 4 5"; else list=$1; fi
    rc=0
    for n in $list; do
        if stop_one "$n"; then say "wgc$n: stopped"; else rc=1; fi
    done
    if [ $rc -eq 0 ] && pending_read && { [ "$1" = all ] || [ "$P_TGT" = "$1" ]; }; then
        rm -f "$WGC_RUN_DIR/wgc.pending"
    fi
    # try leftovers (.wd.*, .pending.*), unless a try for another target
    # is pending: its watchdog may still need them
    if ! pending_read || [ "$1" = all ] || [ "$P_TGT" = "$1" ]; then
        run_rm_glob .wd.
        run_rm_glob .pending.
    fi
    return $rc
}

cmd_stop() {
    ensure_run_dir || return 1
    # a dropped SSH session must not cut a stop short
    trap '' HUP
    lock_acquire "$WGC_LOCK_TRIES" force "" "$WGC_LOCK_TRIES_WGC"
    do_stop "$1"
}

cmd_status() {
    local list n r worst
    list=$(conf_targets "$1")
    [ -n "$list" ] || { printf '%s\n' "no wgcN.conf found in $WGC_DIR"; return 1; }
    worst=0
    for n in $list; do
        status_one "$n"; r=$?
        case $r in
        1) worst=1 ;;
        3) [ $worst -eq 0 ] && worst=3 ;;
        esac
    done
    return $worst
}

# failed or interrupted try: no watchdog needed any more, stop the whole target
try_abort() {
    local tgt
    tgt=$TRY_TARGET
    TRY_TARGET= CUR_N=
    if [ -n "$WD_PID" ]; then kill -9 "$WD_PID" 2>/dev/null; WD_PID=; fi
    # a failed stop reports what is left itself (stderr + logger)
    do_stop "$tgt" >/dev/null
    rm -f "$WGC_RUN_DIR/wgc.pending"
}

# replace wgc.pending atomically: new noclobber file, then rename over the old one
pending_replace() {
    local pf h tmp
    pf="$WGC_RUN_DIR/wgc.pending"
    if [ -d "$pf" ] && [ ! -L "$pf" ]; then warn "$pf is a directory; remove it"; return 1; fi
    # a symlink is never a valid pending file (pending_read ignores it); unlink it
    if [ -L "$pf" ]; then rm -f "$pf"; fi
    h=$(rand_hex) || return 1
    tmp="$WGC_RUN_DIR/.pending.$h"
    create_new "$tmp" || return 1
    TMPF=$tmp
    if ! printf '%s %s\n' "$2" "$1" > "$tmp" || ! mv -f "$tmp" "$pf"; then
        rm -f "$tmp"; TMPF=
        return 1
    fi
    TMPF=
}

# wait until the watchdog has created its ready file (or died)
watchdog_ready() {
    local ack i
    ack=$1
    i=0
    while [ $i -lt 300 ]; do
        [ -e "$ack" ] && return 0
        i=$((i + 1))
    done
    i=0
    while [ $i -lt 10 ]; do
        kill -0 "$WD_PID" 2>/dev/null || return 1
        [ -e "$ack" ] && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

cmd_try() {
    local target secs list tok ack rc
    target=$1 secs=$2
    # the watchdog re-runs this file: it must be a readable file that is this script
    if [ ! -f "$SELF" ] || [ ! -r "$SELF" ] || ! grep -q '^# wgc.sh - WireGuard client tunnels' "$SELF" 2>/dev/null; then
        warn "try needs wgc.sh to be run from its file (not from stdin), nothing changed"
        return 2
    fi
    list=$(conf_targets "$target")
    [ -n "$list" ] || { warn "no wgcN.conf found in $WGC_DIR, nothing to try"; return 2; }
    ensure_run_dir || return 1
    lock_acquire "$WGC_LOCK_TRIES" strict || return 1
    validate_all "$list" || return $?
    if pending_read && [ "$P_TGT" != "$target" ]; then
        warn "another try is pending (${P_TGT:-unknown target}); run confirm or stop first"
        return 2
    fi
    tok=$(rand_hex) || { warn "cannot get random bytes, nothing changed"; return 1; }
    ack="$WGC_RUN_DIR/.wd.$tok"

    export WGC_DIR WGC_RUN_DIR WGC_LAN_IF WGC_PRIO_BASE WGC_TABLE_BASE WGC_HANDSHAKE_MAX
    # the watchdog is born with HUP/INT/TERM ignored, so no window where it can die
    trap '' HUP INT TERM
    sh "$SELF" __watchdog "$tok" "$target" "$secs" "$MYPID" </dev/null >/dev/null 2>&1 &
    WD_PID=$!
    trap on_signal HUP INT TERM
    if ! watchdog_ready "$ack"; then
        kill -9 "$WD_PID" 2>/dev/null; WD_PID=
        rm -f "$ack"
        warn "try $target: the auto-stop timer did not start, nothing changed"
        return 1
    fi
    # Only now replace wgc.pending: a failure above leaves an earlier try armed.
    if ! pending_replace "$target" "$tok"; then
        kill -9 "$WD_PID" 2>/dev/null; WD_PID=
        rm -f "$ack"
        warn "cannot write $WGC_RUN_DIR/wgc.pending, nothing changed"
        return 1
    fi
    TRY_TARGET=$target
    rm -f "$ack"    # commit: the watchdog arms itself now

    apply_start "$list"; rc=$?
    if [ $rc -ne 0 ]; then
        warn "try $target: start failed, stopping $target"
        try_abort
        return 1
    fi
    TRY_TARGET=
    WD_PID=
    say "try: $target will be stopped in ${secs}s unless you run: wgc.sh confirm"
    return 0
}

cmd_confirm() {
    local pf
    pf="$WGC_RUN_DIR/wgc.pending"
    ensure_run_dir || return 1
    lock_acquire "$WGC_LOCK_TRIES" strict || return 1
    if [ -e "$pf" ] || [ -L "$pf" ]; then
        rm -f "$pf" || { warn "cannot remove $pf"; return 1; }
        say "confirmed: auto-stop cancelled"
    else
        say "nothing pending"
    fi
    return 0
}

# detached timer of "try": stop the target unless confirmed or replaced.
# Handshake: we create .wd.<token> ("alive"); try writes wgc.pending, then
# removes .wd.<token> ("committed"). The timer is armed only after that.
cmd_watchdog() {
    local tok target secs trypid k
    tok=$1 target=$2 secs=$3 trypid=$4
    trap '' HUP INT TERM PIPE
    trap cleanup EXIT
    TMPF="$WGC_RUN_DIR/.wd.$tok"
    create_new "$TMPF" || { TMPF=; exit 1; }
    k=0
    while [ -e "$TMPF" ] && [ $k -lt 300 ]; do k=$((k + 1)); done
    k=0
    while [ -e "$TMPF" ]; do
        # try died or hangs: guard whatever wgc.pending says (token check below)
        if ! kill -0 "$trypid" 2>/dev/null || [ $k -ge 120 ]; then break; fi
        sleep 1
        k=$((k + 1))
    done
    rm -f "$TMPF"; TMPF=
    token_pending "$tok" || exit 0
    sleep "$secs"
    token_pending "$tok" || exit 0
    lock_acquire "$WGC_LOCK_TRIES_WD" force "$tok" "$WGC_LOCK_TRIES_WD"
    [ $? -eq 2 ] && exit 0
    token_pending "$tok" || exit 0
    log_msg "try timed out after ${secs}s, stopping $target"
    k=1
    while :; do
        if do_stop "$target" >/dev/null 2>&1; then
            log_msg "try timer: $target stopped (attempt $k)"
            break
        fi
        if [ $k -ge 3 ]; then
            log_msg "try timer: stopping $target FAILED after $k attempts, run: wgc.sh stop $target"
            break
        fi
        log_msg "try timer: stop of $target incomplete (attempt $k), retrying in 5s"
        k=$((k + 1))
        sleep 5
    done
    rm -f "$WGC_RUN_DIR/wgc.pending"
    exit 0
}

# ---------------------------------------------------------------- main

parse_target() {    # "" -> all; all; 1..5; anything else -> usage error
    case $1 in
    '') TARGET=all ;;
    all|[1-5]) TARGET=$1 ;;
    *) die_usage "invalid tunnel '$1' (expected 1-5 or all)" ;;
    esac
}

main() {
    local cmd secs
    [ $# -ge 1 ] || die_usage "missing command"
    cmd=$1
    shift
    case $cmd in
    check|start|stop|status)
        [ $# -le 1 ] || die_usage "too many arguments"
        parse_target "$1"
        ;;
    try)
        [ $# -le 2 ] || die_usage "too many arguments"
        parse_target "$1"
        secs=${2:-$WGC_TRY_DEFAULT}
        num_in "$secs" "$WGC_TRY_MIN" "$WGC_TRY_MAX" || die_usage "seconds must be $WGC_TRY_MIN-$WGC_TRY_MAX"
        ;;
    confirm)
        [ $# -eq 0 ] || die_usage "confirm takes no arguments"
        ;;
    __watchdog)
        [ $# -eq 4 ] || exit 2
        num_in "$4" 1 999999999 || exit 2
        case $1 in *[!0-9a-f]*) exit 2 ;; esac
        [ ${#1} -eq 32 ] || exit 2
        case $2 in all|[1-5]) ;; *) exit 2 ;; esac
        num_in "$3" "$WGC_TRY_MIN" "$WGC_TRY_MAX" || exit 2
        check_settings
        [ -d "$WGC_RUN_DIR" ] && [ ! -L "$WGC_RUN_DIR" ] || exit 1
        cmd_watchdog "$1" "$2" "$3" "$4"
        ;;
    help|-h|--help)
        usage
        exit 0
        ;;
    *)
        die_usage "unknown command '$cmd'"
        ;;
    esac
    check_settings

    trap cleanup EXIT
    trap on_signal INT TERM HUP
    # a closed stdout must never kill the script half-way through a change
    trap '' PIPE

    case $cmd in
    check) cmd_check "$TARGET" ;;
    start) cmd_start "$TARGET" ;;
    stop) cmd_stop "$TARGET" ;;
    status) cmd_status "$TARGET" ;;
    try) cmd_try "$TARGET" "$secs" ;;
    confirm) cmd_confirm ;;
    esac
}

main "$@"
