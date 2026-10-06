#!/bin/sh
# Test runner for router/wgc.sh against fake ip/wg/iptables/... (tests/stubs).
# Usage: sh tests/run.sh [Txx ...]      (TEST_SH=dash selects the shell under test)
# Prints "ok N - Txx name" / "not ok N - Txx name" (+ "#   reason" lines), then "# pass=X fail=Y".

HERE=$(cd "$(dirname "$0")" && pwd) || exit 2
ROOT=$(dirname "$HERE")
FIX="$HERE/fixtures"
SCRIPT="$ROOT/router/wgc.sh"
REAL_MKTEMP=$(command -v mktemp) || exit 2
PATH="$HERE/stubs:$PATH"
export PATH

ALL="T01 T02 T03 T04 T05 T06 T07 T08 T09 T10 T11 T12 T13 T14 T15 T16 T17 T18 T19 T20 T21 T22 T23 T24 T25 T26 T27 T28 T29 T30 T31 T32 T33 T34 T35 T36 T37 T38 T39 T40 T41 T42 T43 T44 T45 T46 T47 T48 T49 T50 T51 T52 T53"

title() {
    case "$1" in
    T01) echo "check prints summary, changes nothing" ;;
    T02) echo "start 1: link, address, routes, rules, iptables, order" ;;
    T03) echo "wg conf copy: no Address/DNS/MTU, mode 600, no temp leftovers" ;;
    T04) echo "no private/preshared key in log or output" ;;
    T05) echo "start twice is idempotent (syncconf, single rules)" ;;
    T06) echo "start, stop, stop leaves nothing" ;;
    T07) echo "stop without conf returns 0" ;;
    T08) echo "full tunnel: default route, endpoint rule, device and destination rules" ;;
    T09) echo "no rules: tunnel up, nothing routed, check warns" ;;
    T10) echo "stopping one tunnel leaves the other and the shared rule" ;;
    T11) echo "device + destination rule" ;;
    T12) echo "dangerous or invalid rules are refused with exit 2" ;;
    T13) echo "rules file with blanks, comments, CRLF, tabs" ;;
    T14) echo "invalid rule for another tunnel refuses everything" ;;
    T15) echo "invalid conf variants are refused with exit 2" ;;
    T16) echo "CRLF conf behaves like T02" ;;
    T17) echo "IPv6 entries are skipped" ;;
    T18) echo "endpoint rule uses the resolved IPv4 from wg" ;;
    T19) echo "no usable endpoint: full rollback, exit 1" ;;
    T20) echo "rule add failure: full rollback" ;;
    T21) echo "modprobe failure: exit 1, no link created" ;;
    T22) echo "failed start of one tunnel leaves the other intact" ;;
    T23) echo "changed rules are replaced, not accumulated" ;;
    T24) echo "more than 99 rules for a tunnel is refused" ;;
    T25) echo "try auto-stops after the timeout" ;;
    T26) echo "confirm cancels the auto-stop" ;;
    T27) echo "status exit codes 0/1/3 and worst wins" ;;
    T28) echo "usage errors exit 2" ;;
    T29) echo "only wgc-owned objects are ever touched" ;;
    T30) echo "start all without any conf is refused" ;;
    T31) echo "eight iptables rules, lock-down DROP/MARK before link up, no ACCEPT" ;;
    T32) echo "lock-down rule failure: interface never brought up" ;;
    T33) echo "restart with changed conf drops old address and routes" ;;
    T34) echo "tunnel rules are iif-scoped, shared and endpoint rules are not" ;;
    T35) echo "tunnel address is always /32; bad addresses refused" ;;
    T36) echo "lock: live holder blocks, dead holder is taken over, released" ;;
    T37) echo "try all: failure stops already started tunnels" ;;
    T38) echo "try all: HUP during start leaves nothing behind" ;;
    T39) echo "stop removes extra and duplicate rules without -C" ;;
    T40) echo "stop removes leftover temp files" ;;
    T41) echo "input size and content limits" ;;
    T42) echo "try seconds range and argument syntax" ;;
    T43) echo "WGC_RUN_DIR creation (700) and symlink refusal" ;;
    T44) echo "lock: start gives recovery hint, stop forces a stuck lock" ;;
    T45) echo "try watchdog forces a stuck lock and stops the tunnel" ;;
    T46) echo "stop reports failures, handles more than 50 duplicates" ;;
    T47) echo "status reports DEGRADED when protection is missing" ;;
    T48) echo "try refuses a script read from stdin" ;;
    T50) echo "stop removes leftover .wd/.pending temp files" ;;
    T51) echo "stop leaves foreign iptables rules alone" ;;
    T52) echo "status reports missing MARK rule as DEGRADED markin" ;;
    T53) echo "static guard: no command/type/hash builtin used (absent from the router ash)" ;;
    T49) echo "WGC_LAN_IF lo or wgcN refused before any address lookup" ;;
    esac
}

# ---------- environment ----------

setup() {
    T=$("$REAL_MKTEMP" -d "${TMPDIR:-/tmp}/wgc-test.XXXXXX") || exit 2
    export STUB_LOG="$T/stub.log" STUB_STATE="$T/state" WGC_DIR="$T/conf" WGC_RUN_DIR="$T/run"
    unset STUB_FAIL STUB_ENDPOINT STUB_HANDSHAKE STUB_SLEEP STUB_SLEEP_LONG STUB_DELAY STUB_DELAY_SECS
    unset WGC_LAN_IF WGC_PRIO_BASE WGC_TABLE_BASE WGC_HANDSHAKE_MAX
    reset
}

# fresh, empty world (also used between scenarios inside one test)
reset() {
    rm -rf "$STUB_STATE" "$WGC_DIR" "$WGC_RUN_DIR"
    mkdir -p "$STUB_STATE" "$WGC_DIR" "$WGC_RUN_DIR"
    # keep UNSUPPORTED lines of the world being discarded for the per-test guard
    [ -f "$STUB_LOG" ] && grep -a '^UNSUPPORTED' "$STUB_LOG" >> "$T/unsupported" 2>/dev/null
    : > "$STUB_LOG"
    : > "$T/allout"
    for f in links addrs routes rules iptables; do : > "$STUB_STATE/$f"; done
}

# a live process owned by the test, used as a lock holder (kill -0 works on it for any user)
holder_start() { holder_stop; /bin/sleep 60 & HOLDER=$!; }
holder_stop() {
    if [ -n "$HOLDER" ]; then kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; fi
    HOLDER=
}

cleanup() { holder_stop; [ -n "$T" ] && rm -rf "$T"; T=; }
trap 'cleanup; exit 130' INT TERM

# ---------- helpers ----------

# run the script under test; sets RC, output in $T/out (also appended to $T/allout)
run() {
    ${TEST_SH:-sh} "$SCRIPT" "$@" > "$T/out" 2>&1
    RC=$?
    cat "$T/out" >> "$T/allout"
}

# run the script by feeding it on stdin: sh -s <args> < wgc.sh
run_stdin() {
    if [ ! -f "$SCRIPT" ]; then RC=127; echo "no $SCRIPT" > "$T/out"; return; fi
    ${TEST_SH:-sh} -s "$@" < "$SCRIPT" > "$T/out" 2>&1
    RC=$?
    cat "$T/out" >> "$T/allout"
}
# pids of running watchdogs carrying token $1 (command line "... __watchdog <token> ...").
# Works with procps-style ps and BusyBox ps ("ps w" = no truncation); never matches other suites' processes.
wd_pids() {
    { ps -axo pid=,args= 2>/dev/null || ps w 2>/dev/null || ps 2>/dev/null; } | grep -F -- "__watchdog $1" | grep -v grep | awk '{ print $1 }'
}

put_s1() { cp "$FIX/split.conf" "$WGC_DIR/wgc1.conf"; chmod 600 "$WGC_DIR/wgc1.conf"; }
put_f2() { cp "$FIX/full.conf" "$WGC_DIR/wgc2.conf"; chmod 600 "$WGC_DIR/wgc2.conf"; }
set_rules() { printf '%s\n' "$@" > "$WGC_DIR/rules"; }
crlf() { awk '{ printf "%s\r\n", $0 }'; }

fail() {
    TFAIL=1
    REASONS="$REASONS#   $1
"
}

assert_rc() { [ "$RC" = "$1" ] || fail "$2: exit code $RC, expected $1"; }

assert_out_has() { grep -Fq -- "$1" "$T/out" || fail "$2: output lacks '$1'"; }

# every log line except the read-only forms and logger = a mutating command
mutating() {
    grep -v -E '^(ip link show |ip -4 -o addr show |ip -4 rule show|ip -4 route show |wg show |logger( |$))|^iptables .* -C |^iptables -t [a-z]+ -S ' "$STUB_LOG"
}
mutating_nosleep() { mutating | grep -v '^sleep '; }
assert_nomut() {
    n=$(mutating | wc -l | tr -d ' ')
    [ "$n" = 0 ] || fail "$1: $n mutating command(s), first: $(mutating | head -1)"
}

state_empty() {
    for f in links addrs routes rules iptables; do
        [ ! -s "$STUB_STATE/$f" ] || fail "$1: state/$f not empty: $(head -1 "$STUB_STATE/$f")"
    done
}
snapshot() {
    for f in links addrs routes rules iptables; do echo "== $f"; sort "$STUB_STATE/$f"; done
}
has_line() {      # has_line <statefile> <exact line>
    grep -Fxq -- "$2" "$STUB_STATE/$1" || fail "state/$1 lacks line: $2"
}
no_text() {       # no_text <statefile> <fixed text>
    ! grep -Fq -- "$2" "$STUB_STATE/$1" || fail "state/$1 still contains: $2"
}
count_lines() {   # count_lines <statefile> <n>
    n=$(wc -l < "$STUB_STATE/$1" | tr -d ' ')
    [ "$n" = "$2" ] || fail "state/$1 has $n lines, expected $2"
}
rule_has() {      # rule_has <prio> <fragment> : exactly one rule with that priority, containing fragment
    n=$(grep -c "^$1 " "$STUB_STATE/rules")
    [ "$n" = 1 ] || fail "expected exactly one rule with priority $1, found $n"
    grep "^$1 " "$STUB_STATE/rules" | grep -Fq -- "$2" || fail "rule $1 lacks '$2'"
}
ipt_has() {       # ipt_has <N> : the eight iptables rules of wgcN, once each
    i=wgc$1
    for r in "raw PREROUTING -i $i -s 192.168.2.0/24 -j DROP" \
             "filter INPUT -i $i -m state --state NEW,INVALID -j DROP" \
             "filter FORWARD -i $i -m state --state NEW,INVALID -j DROP" \
             "nat POSTROUTING -o $i -j MASQUERADE" \
             "mangle FORWARD -o $i -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu" \
             "mangle FORWARD -i $i -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu" \
             "mangle FORWARD -o $i -j MARK --set-xmark 0x01/0x7" \
             "mangle PREROUTING -i $i -j MARK --set-xmark 0x01/0x7"
    do
        n=$(grep -Fxc -- "$r" "$STUB_STATE/iptables")
        [ "$n" = 1 ] || fail "iptables rule present $n times (want 1): $r"
    done
}
log_count() { grep -Ec -- "$1" "$STUB_LOG"; }
lineno() { grep -n -E -- "$1" "$STUB_LOG" | head -1 | cut -d: -f1; }
state_val() { cat "$STUB_STATE/$1" 2>/dev/null | tr -d '\n'; }

# S1 + rule "wgc1 192.168.2.0/24 any", fully up
check_up1() {
    has_line links "wgc1 1400 up"
    has_line addrs "10.11.12.8/32 wgc1"
    has_line routes "10.11.12.0/24 dev wgc1 table 121"
    has_line routes "172.31.0.0/16 dev wgc1 table 121"
    count_lines routes 2
    rule_has 11300 "lookup main suppress_prefixlength 0"
    rule_has 11301 "to 203.0.113.10 lookup main"
    rule_has 11400 "from 192.168.2.0/24 lookup 121"
    count_lines rules 3
    ipt_has 1
    count_lines iptables 8
}

prep_t02() { put_s1; set_rules 'wgc1 192.168.2.0/24 any'; }
prep_t08() { put_f2; set_rules 'wgc2 192.168.2.50 any' 'wgc2 any 104.21.0.0/24'; }
prep_t10() { put_s1; put_f2; set_rules 'wgc1 192.168.2.0/24 any' 'wgc2 192.168.2.50 any'; }

# ---------- tests ----------

t_T01() {
    prep_t02
    run check 1
    assert_rc 0 "check 1"
    for s in 10.11.12.8/32 1400 10.11.12.0/24 172.31.0.0/16 121; do assert_out_has "$s" "check 1"; done
    assert_nomut "check 1"
}

t_T02() {
    prep_t02
    run start 1
    assert_rc 0 "start 1"
    check_up1
    [ "$(state_val setconf.verb)" = setconf ] || fail "setconf.verb is '$(state_val setconf.verb)', expected setconf"
    a=$(lineno '^ip .*rule add .*priority 11300$')
    b=$(lineno '^ip .*rule add .*priority 11301$')
    c=$(lineno '^ip .*rule add .*priority 11400$')
    if [ -z "$a" ] || [ -z "$b" ] || [ -z "$c" ]; then
        fail "log lacks rule add for 11300/11301/11400"
    elif [ "$a" -gt "$c" ] || [ "$b" -gt "$c" ]; then
        fail "rule 11400 added before 11300/11301 (lines $a $b $c)"
    fi
}

t_T03() {
    prep_t02
    run start 1
    assert_rc 0 "start 1"
    cp="$STUB_STATE/setconf.copy"
    if [ ! -f "$cp" ]; then fail "wg setconf never received a file"; return; fi
    ! grep -Eiq '^[[:space:]]*(Address|DNS|MTU)[[:space:]]*=' "$cp" || fail "copy still has Address/DNS/MTU"
    for k in PrivateKey PresharedKey PublicKey AllowedIPs Endpoint PersistentKeepalive; do
        grep -Eiq "^[[:space:]]*$k[[:space:]]*=" "$cp" || fail "copy lacks $k"
    done
    [ "$(state_val setconf.mode)" = 600 ] || fail "temp file mode '$(state_val setconf.mode)', expected 600"
    ! grep -rl FAKEPRIV "$WGC_RUN_DIR" > "$T/leak" 2>/dev/null || [ ! -s "$T/leak" ] || fail "key left in run dir: $(cat "$T/leak")"
}

t_T04() {
    prep_t10
    run check all; assert_rc 0 "check all"
    run start all; assert_rc 0 "start all"
    run status all; assert_rc 0 "status all"
    run stop all; assert_rc 0 "stop all"
    [ -s "$STUB_LOG" ] || fail "empty stub log (nothing ran)"
    for k in FAKEPRIV FAKEPSKY FAKEPRV2; do
        ! grep -q "$k" "$STUB_LOG" || fail "$k found in STUB_LOG"
        ! grep -q "$k" "$T/allout" || fail "$k found in command output"
    done
}

t_T05() {
    prep_t02
    run start 1; assert_rc 0 "first start"
    run start 1; assert_rc 0 "second start"
    n=$(log_count '^ip link add ')
    [ "$n" = 1 ] || fail "link add called $n times, expected 1"
    [ "$(state_val setconf.verb)" = syncconf ] || fail "final verb '$(state_val setconf.verb)', expected syncconf"
    check_up1
}

t_T06() {
    prep_t02
    run start 1; assert_rc 0 "start"
    run stop 1; assert_rc 0 "first stop"
    state_empty "after first stop"
    ls -A "$WGC_RUN_DIR" > "$T/leftovers" 2>/dev/null
    [ ! -s "$T/leftovers" ] || fail "WGC_RUN_DIR not empty after stop: $(tr '\n' ' ' < "$T/leftovers")"
    run stop 1; assert_rc 0 "second stop"
    state_empty "after second stop"
}

t_T07() {
    run stop 1; assert_rc 0 "stop 1"
    run stop all; assert_rc 0 "stop all"
}

t_T08() {
    prep_t08
    run start 2
    assert_rc 0 "start 2"
    has_line links "wgc2 1420 up"
    has_line addrs "10.2.0.2/32 wgc2"
    has_line routes "default dev wgc2 table 122"
    count_lines routes 1
    ! grep -v ' table ' "$STUB_STATE/routes" | grep -q . || fail "route without table"
    rule_has 11300 "lookup main suppress_prefixlength 0"
    rule_has 11302 "to 198.51.100.7 lookup main"
    rule_has 11500 "from 192.168.2.50 lookup 122"
    rule_has 11501 "to 104.21.0.0/24 lookup 122"
    count_lines rules 4
    ipt_has 2
}

t_T09() {
    put_f2; : > "$WGC_DIR/rules"
    run start 2
    assert_rc 0 "start 2"
    has_line links "wgc2 1420 up"
    rule_has 11300 "lookup main suppress_prefixlength 0"
    rule_has 11302 "to 198.51.100.7 lookup main"
    count_lines rules 2
    run check 2
    assert_rc 0 "check 2"
    assert_out_has "no rules" "check 2"
}

t_T10() {
    prep_t10
    run start all
    assert_rc 0 "start all"
    has_line links "wgc1 1400 up"
    has_line links "wgc2 1420 up"
    rule_has 11300 "suppress_prefixlength 0"
    run stop 1
    assert_rc 0 "stop 1"
    no_text links wgc1; no_text routes "table 121"; no_text addrs wgc1
    no_text rules "lookup 121"; no_text iptables wgc1
    has_line links "wgc2 1420 up"
    has_line addrs "10.2.0.2/32 wgc2"
    has_line routes "default dev wgc2 table 122"
    rule_has 11300 "suppress_prefixlength 0"
    rule_has 11302 "to 198.51.100.7 lookup main"
    rule_has 11500 "from 192.168.2.50 lookup 122"
    count_lines rules 3
    ipt_has 2
    count_lines iptables 8
    run stop 2
    assert_rc 0 "stop 2"
    state_empty "after stop 2"
}

t_T11() {
    put_s1; set_rules 'wgc1 192.168.2.116 172.31.5.0/24'
    run start 1
    assert_rc 0 "start 1"
    rule_has 11400 "from 192.168.2.116 to 172.31.5.0/24 lookup 121"
}

t_T12() {
    for r in 'wgc1 192.168.2.1 any' 'wgc9 192.168.2.5 any' 'wgc1 10.0.0.5 any' 'wgc1 any 192.168.2.0/25' \
             'wgc1 any 192.168.0.0/16' 'wgc1 192.168.2.300 any' 'wgc1 192.168.2.5'
    do
        reset; put_s1; set_rules "$r"
        run start 1
        assert_rc 2 "rule '$r'"
        assert_nomut "rule '$r'"
    done
}

t_T13() {
    put_s1
    printf '# comment line\r\n\r\nwgc1   192.168.2.50   any   # trailing comment\r\n\n\twgc1\tany\t104.21.0.0/24\r\n' > "$WGC_DIR/rules"
    run start 1
    assert_rc 0 "start 1"
    rule_has 11400 "from 192.168.2.50 lookup 121"
    rule_has 11401 "to 104.21.0.0/24 lookup 121"
    count_lines rules 4
}

t_T14() {
    put_s1; set_rules 'wgc1 192.168.2.0/24 any' 'wgc2 10.0.0.5 any'
    run start 1
    assert_rc 2 "start 1"
    assert_nomut "start 1"
}

t_T15() {
    ok_rules='wgc1 192.168.2.0/24 any'
    for v in nokey noaddr nopeer twopeers noendpoint mtu100 lanaddr; do
        reset; set_rules "$ok_rules"
        f="$WGC_DIR/wgc1.conf"
        case $v in
        nokey) sed '/^PrivateKey/d' "$FIX/split.conf" > "$f" ;;
        noaddr) sed '/^Address/d' "$FIX/split.conf" > "$f" ;;
        nopeer) sed '/^\[Peer\]/,$d' "$FIX/split.conf" > "$f" ;;
        twopeers) { cat "$FIX/split.conf"; printf '\n[Peer]\nPublicKey = FAKEPUBKFAKEPUBKFAKEPUBKFAKEPUBKFAKEPUBKFA1=\nAllowedIPs = 10.9.9.0/24\nEndpoint = 203.0.113.11:51820\n'; } > "$f" ;;
        noendpoint) sed '/^Endpoint/d' "$FIX/split.conf" > "$f" ;;
        mtu100) sed 's/^MTU = .*/MTU = 100/' "$FIX/split.conf" > "$f" ;;
        lanaddr) sed 's|^Address = .*|Address = 192.168.2.9/32|' "$FIX/split.conf" > "$f" ;;
        esac
        run start 1
        assert_rc 2 "conf variant $v"
        assert_nomut "conf variant $v"
    done
    reset; put_s1; set_rules "$ok_rules"
    run start 3
    assert_rc 2 "start 3 without conf"
    assert_nomut "start 3 without conf"
}

t_T16() {
    prep_t02
    crlf < "$FIX/split.conf" > "$WGC_DIR/wgc1.conf"
    run start 1
    assert_rc 0 "start 1"
    check_up1
    [ "$(state_val setconf.verb)" = setconf ] || fail "verb '$(state_val setconf.verb)', expected setconf"
}

t_T17() {
    put_s1; set_rules 'wgc1 192.168.2.0/24 any'
    sed -e 's|^Address = .*|Address = 10.11.12.8/32, fd00::8/128|' \
        -e 's|^AllowedIPs = .*|AllowedIPs = 10.11.12.0/24, fd00::/64|' "$FIX/split.conf" > "$WGC_DIR/wgc1.conf"
    run start 1
    assert_rc 0 "start 1"
    ! grep '^ip ' "$STUB_LOG" | grep -Eq 'fd00|::' || fail "an ip command mentions IPv6"
    count_lines routes 1
    has_line routes "10.11.12.0/24 dev wgc1 table 121"
    count_lines addrs 1
    has_line addrs "10.11.12.8/32 wgc1"
}

t_T18() {
    put_s1; set_rules 'wgc1 192.168.2.0/24 any'
    sed 's|^Endpoint = .*|Endpoint = vpn.example.com:51820|' "$FIX/split.conf" > "$WGC_DIR/wgc1.conf"
    export STUB_ENDPOINT=198.51.100.99:51820
    run start 1
    assert_rc 0 "start 1"
    rule_has 11301 "to 198.51.100.99 lookup main"
}

t_T19() {
    prep_t02
    export STUB_ENDPOINT='(none)'
    run start 1
    assert_rc 1 "start 1"
    state_empty "after failed start"
}

t_T20() {
    prep_t02
    export STUB_FAIL='rule add .*lookup 121'
    run start 1
    assert_rc 1 "start 1"
    state_empty "after failed start"
}

t_T21() {
    prep_t02
    export STUB_FAIL='^modprobe'
    run start 1
    assert_rc 1 "start 1"
    [ "$(log_count '^ip link add ')" = 0 ] || fail "link add was called"
    state_empty "after failed start"
}

t_T22() {
    put_s1; put_f2
    set_rules 'wgc1 192.168.2.0/24 any' 'wgc2 192.168.2.50 any'
    run start 2
    assert_rc 0 "start 2"
    snapshot > "$T/snap2"
    [ -s "$STUB_STATE/links" ] || fail "start 2 produced no state"
    export STUB_FAIL='iptables .*wgc1'
    run start 1
    assert_rc 1 "start 1"
    snapshot > "$T/snap2b"
    cmp -s "$T/snap2" "$T/snap2b" || fail "state differs from after-start-2: $(diff "$T/snap2" "$T/snap2b" | head -8 | tr '\n' '|')"
    no_text links wgc1; no_text iptables wgc1; no_text rules "lookup 121"; no_text routes "table 121"
    rule_has 11300 "suppress_prefixlength 0"
    has_line links "wgc2 1420 up"
}

t_T23() {
    put_s1
    set_rules 'wgc1 192.168.2.50 any'
    run start 1; assert_rc 0 "start with rules A"
    set_rules 'wgc1 192.168.2.60 any' 'wgc1 any 104.21.0.0/24'
    run start 1; assert_rc 0 "start with rules B"
    n=$(grep -c 'lookup 121' "$STUB_STATE/rules")
    [ "$n" = 2 ] || fail "$n rules with lookup 121, expected 2"
    rule_has 11400 "from 192.168.2.60 lookup 121"
    rule_has 11401 "to 104.21.0.0/24 lookup 121"
    no_text rules 192.168.2.50
    n=$(log_count '^ip link add ')
    [ "$n" = 1 ] || fail "link add called $n times, expected 1"
}

t_T24() {
    put_s1
    i=1; : > "$WGC_DIR/rules"
    while [ $i -le 100 ]; do echo "wgc1 192.168.2.$((i+1)) any" >> "$WGC_DIR/rules"; i=$((i+1)); done
    run start 1
    assert_rc 2 "start with 100 rules"
    assert_nomut "start with 100 rules"
    # boundary: 99 rules are fine
    reset; put_s1
    i=1; : > "$WGC_DIR/rules"
    while [ $i -le 99 ]; do echo "wgc1 192.168.2.$((i+1)) any" >> "$WGC_DIR/rules"; i=$((i+1)); done
    run start 1
    assert_rc 0 "start with 99 rules"
    rule_has 11400 "from 192.168.2.2 lookup 121"
    rule_has 11498 "from 192.168.2.100 lookup 121"
    count_lines rules 101
}

t_T25() {
    prep_t02
    export STUB_SLEEP=1
    t0=$(date +%s)
    run try 1 10
    t1=$(date +%s)
    assert_rc 0 "try 1 5"
    [ $((t1 - t0)) -lt 3 ] || fail "try took $((t1 - t0)) s, expected to return at once"
    has_line links "wgc1 1400 up"
    [ -f "$WGC_RUN_DIR/wgc.pending" ] || fail "wgc.pending missing after try"
    /bin/sleep 3
    state_empty "after timeout"
    [ ! -e "$WGC_RUN_DIR/wgc.pending" ] || fail "wgc.pending still present after timeout"
}

t_T26() {
    prep_t02
    export STUB_SLEEP=1
    run try 1 10
    assert_rc 0 "try 1 5"
    has_line links "wgc1 1400 up"
    run confirm
    assert_rc 0 "confirm"
    /bin/sleep 3
    has_line links "wgc1 1400 up"
    check_up1
    [ ! -e "$WGC_RUN_DIR/wgc.pending" ] || fail "wgc.pending still present after confirm"
}

t_T27() {
    reset; put_s1; set_rules 'wgc1 192.168.2.0/24 any'
    run start 1; assert_rc 0 "(a) start"
    run status 1; assert_rc 0 "(a) status after start"
    reset; put_s1; set_rules 'wgc1 192.168.2.0/24 any'
    run status 1; assert_rc 1 "(b) status without interface"
    reset; put_s1; set_rules 'wgc1 192.168.2.0/24 any'
    export STUB_HANDSHAKE=0
    run start 1; assert_rc 0 "(c) start"
    run status 1; assert_rc 3 "(c) status with no handshake"
    unset STUB_HANDSHAKE
    reset; prep_t10
    run start 1; assert_rc 0 "(d) start 1"
    run status all; assert_rc 1 "(d) status all, wgc2 down"
}

t_T28() {
    run; assert_rc 2 "no arguments"
    run bogus; assert_rc 2 "bogus"
    run start 6; assert_rc 2 "start 6"
    run start x; assert_rc 2 "start x"
    assert_nomut "usage errors"
}

t_T29() {
    COMB="$T/combined.log"; : > "$COMB"
    prep_t02; run start 1; assert_rc 0 "T02 start"; cat "$STUB_LOG" >> "$COMB"
    reset; prep_t08; run start 2; assert_rc 0 "T08 start"; cat "$STUB_LOG" >> "$COMB"
    reset; prep_t10
    run start all; assert_rc 0 "T10 start all"
    run stop 1; assert_rc 0 "T10 stop 1"
    run stop 2; assert_rc 0 "T10 stop 2"
    cat "$STUB_LOG" >> "$COMB"
    reset; prep_t02
    run start 1; assert_rc 0 "T06 start"
    run stop 1; assert_rc 0 "T06 stop"
    run stop 1; assert_rc 0 "T06 stop again"
    cat "$STUB_LOG" >> "$COMB"
    [ "$(grep -c '^ip .*rule add' "$COMB")" -gt 0 ] || fail "combined log has no rule add"
    bad=$(awk '/^ip .*rule add/ { p = ""; for (i = 1; i < NF; i++) if ($i == "priority") p = $(i+1);
               if (p == "" || p + 0 < 11300 || p + 0 > 11899) print }' "$COMB" | head -1)
    [ -z "$bad" ] || fail "rule add outside 11300-11899: $bad"
    bad=$(grep '^ip .*rule del' "$COMB" | grep -Ev 'priority 113[0-9][0-9]$|table 12[1-5]$' | head -1)
    [ -z "$bad" ] || fail "unexpected rule del: $bad"
    bad=$(grep '^ip .*route replace' "$COMB" | grep -Ev ' table 12[1-5]( |$)' | head -1)
    [ -z "$bad" ] || fail "route replace without table 121-125: $bad"
    bad=$(grep '^iptables ' "$COMB" | grep -Ev ' -S |wgc[1-5]' | head -1)
    [ -z "$bad" ] || fail "iptables line without wgcN: $bad"
    bad=$(grep -v '^logger ' "$COMB" | grep -E 'flush| -F| -X| -P |nvram|service|reboot|rmmod|UNSUPPORTED' | head -1)
    [ -z "$bad" ] || fail "forbidden command: $bad"
}

t_T30() {
    run start all
    assert_rc 2 "start all with no conf"
    assert_nomut "start all with no conf"
}

t_T31() {
    prep_t02
    run start 1
    assert_rc 0 "start 1"
    count_lines iptables 8
    ipt_has 1
    ! grep -q ACCEPT "$STUB_STATE/iptables" || fail "an ACCEPT rule is present"
    up=$(lineno '^ip link set dev wgc1 ')
    [ -n "$up" ] || fail "log lacks ip link set dev wgc1"
    for r in 'raw -I PREROUTING' 'filter -I INPUT' 'filter -I FORWARD'; do
        t=${r%% *}; rest=${r#* }
        l=$(lineno "^iptables -t $t $rest .*-j DROP")
        if [ -z "$l" ]; then fail "log lacks -I DROP for $t"
        elif [ -n "$up" ] && [ "$l" -gt "$up" ]; then fail "$t DROP inserted after link set up (line $l > $up)"; fi
    done
    for r in 'FORWARD -o wgc1' 'PREROUTING -i wgc1'; do
        l=$(lineno "^iptables -t mangle -I $r -j MARK --set-xmark 0x01/0x7\$")
        if [ -z "$l" ]; then fail "log lacks -I MARK for mangle $r"
        elif [ -n "$up" ] && [ "$l" -gt "$up" ]; then fail "mangle $r MARK inserted after link set up (line $l > $up)"; fi
    done
}

t_T32() {
    prep_t02
    export STUB_FAIL='iptables -t raw'
    run start 1
    assert_rc 1 "start 1"
    state_empty "after failed start"
    [ "$(log_count '^ip link set dev wgc1')" = 0 ] || fail "link was brought up"
}

t_T33() {
    prep_t02
    run start 1; assert_rc 0 "first start"
    sed -e 's|^Address = .*|Address = 10.99.0.8/32|' -e 's|^AllowedIPs = .*|AllowedIPs = 10.99.0.0/24|' "$FIX/split.conf" > "$WGC_DIR/wgc1.conf"
    run start 1; assert_rc 0 "second start"
    count_lines addrs 1; has_line addrs "10.99.0.8/32 wgc1"
    count_lines routes 1; has_line routes "10.99.0.0/24 dev wgc1 table 121"
    n=$(log_count '^ip link add ')
    [ "$n" = 1 ] || fail "link add called $n times, expected 1"
}

t_T34() {
    put_s1; put_f2
    set_rules 'wgc1 192.168.2.0/24 any' 'wgc2 any any'
    run start all
    assert_rc 0 "start all"
    n=$(grep -c 'lookup 12' "$STUB_STATE/rules")
    [ "$n" = 2 ] || fail "$n rules with lookup 12, expected 2"
    ! grep 'lookup 12' "$STUB_STATE/rules" | grep -vq 'iif br0' || fail "tunnel rule without iif br0"
    ! grep -E '^1130[0-9] ' "$STUB_STATE/rules" | grep -q 'iif' || fail "shared/endpoint rule has iif"
    rule_has 11400 "iif br0 from 192.168.2.0/24 lookup 121"
    rule_has 11500 "iif br0 lookup 122"
    ! grep '^11500 ' "$STUB_STATE/rules" | grep -Eq ' (from|to) ' || fail "any any rule has from/to"
    rule_has 11300 "suppress_prefixlength 0"
}

t_T35() {
    put_s1; set_rules 'wgc1 192.168.2.0/24 any'
    sed 's|^Address = .*|Address = 10.11.12.8/24|' "$FIX/split.conf" > "$WGC_DIR/wgc1.conf"
    run start 1
    assert_rc 0 "Address /24"
    count_lines addrs 1; has_line addrs "10.11.12.8/32 wgc1"
    ! grep '^ip ' "$STUB_LOG" | grep -Fq '10.11.12.8/24' || fail "an ip command used the /24 prefix"
    for a in 127.0.0.1/8 0.0.0.5/32 224.0.0.1/4; do
        reset; put_s1; set_rules 'wgc1 192.168.2.0/24 any'
        sed "s|^Address = .*|Address = $a|" "$FIX/split.conf" > "$WGC_DIR/wgc1.conf"
        run start 1
        assert_rc 2 "Address $a"
        assert_nomut "Address $a"
    done
}

t_T36() {
    prep_t02
    export STUB_SLEEP=0
    mkdir "$WGC_RUN_DIR/lock"; echo $$ > "$WGC_RUN_DIR/lock/pid"
    run start 1
    assert_rc 1 "(a) start with live lock"
    n=$(mutating_nosleep | wc -l | tr -d ' ')
    [ "$n" = 0 ] || fail "(a) $n mutating command(s) besides sleep, first: $(mutating_nosleep | head -1)"
    [ -d "$WGC_RUN_DIR/lock" ] || fail "(a) live lock was removed"
    [ "$(cat "$WGC_RUN_DIR/lock/pid" 2>/dev/null)" = "$$" ] || fail "(a) live lock pid changed"
    reset; prep_t02
    p=99999
    while kill -0 $p 2>/dev/null; do p=$((p - 1)); done
    mkdir "$WGC_RUN_DIR/lock"; echo $p > "$WGC_RUN_DIR/lock/pid"
    run start 1
    assert_rc 0 "(b) start with dead holder"
    [ ! -e "$WGC_RUN_DIR/lock" ] || fail "(b) lock still present after start"
    reset; prep_t02
    run start 1; assert_rc 0 "(c) start"
    run stop 1; assert_rc 0 "(c) stop"
    [ ! -e "$WGC_RUN_DIR/lock" ] || fail "(c) lock present after stop"
}

t_T37() {
    prep_t10
    export STUB_FAIL='link add dev wgc2'
    run try all 10
    assert_rc 1 "try all 10"
    state_empty "after failed try"
    [ ! -e "$WGC_RUN_DIR/wgc.pending" ] || fail "wgc.pending left behind"
    [ ! -e "$WGC_RUN_DIR/lock" ] || fail "lock left behind"
}

t_T38() {
    prep_t10
    export STUB_SLEEP=1 STUB_DELAY='link add dev wgc2' STUB_DELAY_SECS=3
    ${TEST_SH:-sh} "$SCRIPT" try all 10 > "$T/out" 2>&1 &
    pid=$!
    i=0
    while [ $i -lt 50 ] && ! grep -q 'ip link add dev wgc2' "$STUB_LOG"; do
        kill -0 $pid 2>/dev/null || break
        /bin/sleep 0.2; i=$((i + 1))
    done
    if grep -q 'ip link add dev wgc2' "$STUB_LOG"; then
        kill -HUP $pid
    else
        fail "never reached ip link add dev wgc2 (script exited or timed out)"
    fi
    wait $pid
    RC=$?
    /bin/sleep 5
    kill -9 $pid 2>/dev/null
    state_empty "after HUP"
    [ -s "$STUB_LOG" ] || fail "empty stub log (nothing ran)"
    [ ! -e "$WGC_RUN_DIR/wgc.pending" ] || fail "wgc.pending left behind"
    [ ! -e "$WGC_RUN_DIR/lock" ] || fail "lock left behind"
}

t_T39() {
    prep_t02
    run start 1; assert_rc 0 "start 1"
    printf '%s\n' 'raw PREROUTING -i wgc1 -s 10.0.0.0/8 -j DROP' 'nat POSTROUTING -o wgc1 -j MASQUERADE' 'mangle PREROUTING -i wgc1 -j MARK --set-xmark 0x01/0x7' >> "$STUB_STATE/iptables"
    export STUB_FAIL=' -C '
    run stop 1
    assert_rc 0 "stop 1"
    count_lines iptables 0
    state_empty "after stop"
}

t_T40() {
    prep_t02
    echo leftover > "$WGC_RUN_DIR/.wgc1.deadbeef"; chmod 600 "$WGC_RUN_DIR/.wgc1.deadbeef"
    run stop 1
    assert_rc 0 "stop 1"
    [ ! -e "$WGC_RUN_DIR/.wgc1.deadbeef" ] || fail "temp file not removed"
}

t_T41() {
    ok_rules='wgc1 192.168.2.0/24 any'
    reset; set_rules "$ok_rules"
    { sed '/^AllowedIPs/d' "$FIX/split.conf"
      awk 'BEGIN { printf "AllowedIPs = "; for (i = 1; i <= 65; i++) printf "%s10.%d.0.0/16", (i > 1 ? ", " : ""), i; print "" }'
    } > "$WGC_DIR/wgc1.conf"
    run start 1; assert_rc 2 "65 AllowedIPs"; assert_nomut "65 AllowedIPs"
    reset; put_s1
    { awk 'BEGIN { for (i = 0; i < 1000; i++) print "# padding line padding line padding line padding line padding line padding" }'
      echo "$ok_rules"; } > "$WGC_DIR/rules"
    run start 1; assert_rc 2 "oversized rules"; assert_nomut "oversized rules"
    reset; set_rules "$ok_rules"
    { cat "$FIX/split.conf"; printf '# bad\001comment\n'; } > "$WGC_DIR/wgc1.conf"
    run start 1; assert_rc 2 "control byte in conf"; assert_nomut "control byte in conf"
    reset; set_rules "$ok_rules"
    mkdir "$WGC_DIR/wgc1.conf"
    run start 1; assert_rc 2 "conf is a directory"; assert_nomut "conf is a directory"
}

t_T42() {
    prep_t02
    export STUB_SLEEP=2
    run try 300; assert_rc 2 "try 300"
    run try 1 5; assert_rc 2 "try 1 5"
    run try 1 99999; assert_rc 2 "try 1 99999"
    assert_nomut "bad try arguments"
    run try 1 30; assert_rc 0 "try 1 30"
    run confirm; assert_rc 0 "confirm"
    run stop 1; assert_rc 0 "stop 1"
    /bin/sleep 3
}

t_T43() {
    prep_t02
    export WGC_RUN_DIR="$T/newrun"
    rm -rf "$WGC_RUN_DIR"
    run start 1
    assert_rc 0 "(a) start with new run dir"
    [ -d "$WGC_RUN_DIR" ] || fail "(a) run dir not created"
    perm=$(ls -ld "$WGC_RUN_DIR" 2>/dev/null | cut -c1-10)
    [ "$perm" = "drwx------" ] || fail "(a) run dir mode '$perm', expected drwx------"
    reset; prep_t02
    export WGC_RUN_DIR="$T/linkrun"
    rm -rf "$WGC_RUN_DIR"; mkdir "$T/realrun"; ln -s "$T/realrun" "$WGC_RUN_DIR"
    : > "$STUB_LOG"
    run start 1
    assert_rc 1 "(b) start with symlinked run dir"
    assert_nomut "(b) symlinked run dir"
}

t_T44() {
    prep_t02
    export STUB_SLEEP=0
    holder_start
    mkdir "$WGC_RUN_DIR/lock"; echo "$HOLDER" > "$WGC_RUN_DIR/lock/pid"
    run start 1
    assert_rc 1 "(a) start with stuck lock"
    n=$(mutating_nosleep | wc -l | tr -d ' ')
    [ "$n" = 0 ] || fail "(a) $n mutating command(s) besides sleep, first: $(mutating_nosleep | head -1)"
    assert_out_has "rm -rf" "(a)"
    assert_out_has "$WGC_RUN_DIR/lock" "(a)"
    [ "$(cat "$WGC_RUN_DIR/lock/pid" 2>/dev/null)" = "$HOLDER" ] || fail "(a) lock was touched"
    reset; prep_t02
    run start 1; assert_rc 0 "(b) start"
    mkdir "$WGC_RUN_DIR/lock"; echo "$HOLDER" > "$WGC_RUN_DIR/lock/pid"
    run stop 1; assert_rc 0 "(b) stop with stuck lock"
    kill -0 "$HOLDER" 2>/dev/null || fail "(b) lock holder process was killed by the script"
    state_empty "(b) after stop"
    ls -A "$WGC_RUN_DIR" > "$T/leftovers" 2>/dev/null
    [ ! -s "$T/leftovers" ] || fail "(b) run dir not empty: $(tr '\n' ' ' < "$T/leftovers")"
    holder_stop
    reset; prep_t02
    run start 1; assert_rc 0 "(c) start"
    : > "$WGC_RUN_DIR/lock"
    run stop 1; assert_rc 0 "(c) stop with lock as a file"
    state_empty "(c) after stop"
    ls -A "$WGC_RUN_DIR" > "$T/leftovers" 2>/dev/null
    [ ! -s "$T/leftovers" ] || fail "(c) run dir not empty: $(tr '\n' ' ' < "$T/leftovers")"
}

t_T45() {
    prep_t02
    export STUB_SLEEP=0.01 STUB_SLEEP_LONG=2
    run try 1 10
    assert_rc 0 "try 1 10"
    # token of our own watchdog: the 32-char hex field of wgc.pending
    tok=$(awk '{ for (i = 1; i <= NF; i++) if (length($i) == 32 && $i ~ /^[0-9a-f]+$/) { print $i; exit } }' "$WGC_RUN_DIR/wgc.pending" 2>/dev/null)
    [ -n "$tok" ] || fail "cannot read the token from wgc.pending"
    holder_start
    mkdir "$WGC_RUN_DIR/lock"; echo "$HOLDER" > "$WGC_RUN_DIR/lock/pid"
    i=0
    while [ $i -lt 30 ]; do
        empty=1
        for f in links addrs routes rules iptables; do [ -s "$STUB_STATE/$f" ] && empty=0; done
        [ $empty = 1 ] && break
        /bin/sleep 0.5; i=$((i + 1))
    done
    holder_stop
    state_empty "after watchdog (waited up to 15 s)"
    [ -s "$STUB_LOG" ] || fail "empty stub log (nothing ran)"
    if [ -n "$tok" ]; then
        i=0
        while [ $i -lt 10 ] && [ -n "$(wd_pids "$tok")" ]; do /bin/sleep 0.5; i=$((i + 1)); done
        p=$(wd_pids "$tok")
        if [ -n "$p" ]; then
            fail "own watchdog still alive: $(echo $p)"
            kill -9 $p 2>/dev/null
        fi
    fi
}

t_T46() {
    prep_t02
    run start 1; assert_rc 0 "(a) start"
    export STUB_FAIL=' -D '
    run stop 1
    assert_rc 1 "(a) stop with failing iptables -D"
    assert_out_has iptables "(a)"
    unset STUB_FAIL
    reset; prep_t02
    run start 1; assert_rc 0 "(b) start"
    export STUB_FAIL='link del dev wgc1'
    run stop 1
    assert_rc 1 "(b) stop with failing link del"
    unset STUB_FAIL
    reset; prep_t02
    run start 1; assert_rc 0 "(c) start"
    : > "$STUB_STATE/iptables"
    i=0; while [ $i -lt 55 ]; do echo 'nat POSTROUTING -o wgc1 -j MASQUERADE' >> "$STUB_STATE/iptables"; i=$((i + 1)); done
    run stop 1
    assert_rc 0 "(c) stop with 55 duplicates"
    count_lines iptables 0
    state_empty "(c) after stop"
}

t_T47() {
    prep_t02
    run start 1; assert_rc 0 "(a) start"
    : > "$STUB_STATE/iptables"
    run status 1
    assert_rc 1 "(a) status without iptables rules"
    assert_out_has DEGRADED "(a)"
    reset; prep_t02
    run start 1; assert_rc 0 "(b) start"
    grep -v '^11300 ' "$STUB_STATE/rules" > "$STUB_STATE/rules.tmp"
    mv "$STUB_STATE/rules.tmp" "$STUB_STATE/rules"
    run status 1
    assert_rc 1 "(b) status without shared rule"
    assert_out_has DEGRADED "(b)"
}

t_T48() {
    prep_t02
    run_stdin try 1 10
    assert_rc 2 "try via stdin"
    assert_nomut "try via stdin"
}

t_T49() {
    for li in lo wgc2; do
        reset; prep_t02
        export WGC_LAN_IF=$li
        run start 1
        assert_rc 2 "WGC_LAN_IF=$li"
        assert_nomut "WGC_LAN_IF=$li"
        [ "$(log_count "addr show dev $li")" = 0 ] || fail "WGC_LAN_IF=$li: script asked for the address of $li"
    done
    unset WGC_LAN_IF
}

t_T50() {
    prep_t02
    run start 1; assert_rc 0 "start 1"
    : > "$WGC_RUN_DIR/.wd.deadbeef"; : > "$WGC_RUN_DIR/.pending.deadbeef"
    run stop 1
    assert_rc 0 "stop 1"
    ls -A "$WGC_RUN_DIR" > "$T/leftovers" 2>/dev/null
    [ ! -s "$T/leftovers" ] || fail "run dir not empty: $(tr '\n' ' ' < "$T/leftovers")"
}

t_T51() {
    prep_t02
    run start 1; assert_rc 0 "start 1"
    foreign='filter INPUT ! -i wgc1 -p udp -j DROP'
    echo "$foreign" >> "$STUB_STATE/iptables"
    run stop 1
    assert_rc 0 "stop 1"
    count_lines iptables 1
    has_line iptables "$foreign"
    ! grep '^iptables ' "$STUB_LOG" | grep -- ' -D ' | grep -Fq -- '! -i wgc1' || fail "stop tried to delete the foreign rule"
}

t_T52() {
    prep_t02
    run start 1; assert_rc 0 "start 1"
    grep -Fxv 'mangle PREROUTING -i wgc1 -j MARK --set-xmark 0x01/0x7' "$STUB_STATE/iptables" > "$STUB_STATE/iptables.tmp"
    mv "$STUB_STATE/iptables.tmp" "$STUB_STATE/iptables"
    count_lines iptables 7
    run status 1
    assert_rc 1 "status without the PREROUTING MARK rule"
    assert_out_has DEGRADED "status"
    assert_out_has markin "status"
}

# static guard: the router's ash has no `command`, `type` or `hash` builtin (BusyBox in the container does).
# Prints offending lines (number:text) of $1: comment lines are skipped, the word must be at a command position.
nobuiltin_lines() {
    awk '/^[[:space:]]*#/ { next } { print NR ":" $0 }' "$1" > "$T/nb.in" 2>/dev/null
    grep -E '^[0-9]+:(([^#]*[;&|({`!])|([^#]*[[:space:]])?(then|do|else|if|elif|while|until))?[[:space:]]*(command|type|hash)[[:space:]]' "$T/nb.in"
    [ $? -le 1 ] || echo "0:guard error (grep failed)"
}

t_T53() {
    nobuiltin_lines "$SCRIPT" > "$T/nb.out"
    [ ! -s "$T/nb.out" ] || fail "builtin missing on the router ash used: $(head -8 "$T/nb.out" | tr '\n' '|')"
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
    "t_$id"
    grep -a '^UNSUPPORTED' "$STUB_LOG" >> "$T/unsupported" 2>/dev/null
    if [ -s "$T/unsupported" ]; then fail "unsupported command used: $(head -1 "$T/unsupported")"; fi
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
