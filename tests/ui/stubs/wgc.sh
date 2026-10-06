#!/bin/sh
# Fake wgc.sh for the wgcui.sh tests. Logs "wgc.sh <args>" to $STUB_LOG.
# Replies come from $STUB_WGC_DIR/<cmd>_<target>.{rc,out}, else <cmd>.{rc,out}
# (e.g. check_1.out, status_2.rc, check_all.rc). Nothing found: rc 0, no output.
# Default for "status N" when neither .rc nor .out exists: prints "wgcN: down", rc 1.
# try/confirm only log. Never touches the network or the system.
printf '%s\n' "wgc.sh $*" >> "${STUB_LOG:?}"
cmd=$1
tgt=$2
D=${STUB_WGC_DIR:-}
pick() {    # pick <ext>: first existing reply file among <cmd>_<tgt>.ext, <cmd>.ext
    [ -n "$D" ] || return 1
    if [ -n "$tgt" ] && [ -f "$D/${cmd}_${tgt}.$1" ]; then printf '%s' "$D/${cmd}_${tgt}.$1"; return 0; fi
    if [ -f "$D/${cmd}.$1" ]; then printf '%s' "$D/${cmd}.$1"; return 0; fi
    return 1
}
rcf=$(pick rc)
outf=$(pick out)
if [ -z "$rcf" ] && [ -z "$outf" ] && [ "$cmd" = status ]; then
    case $tgt in
    [1-5]) printf 'wgc%s: down\n' "$tgt"; exit 1 ;;
    esac
fi
[ -n "$outf" ] && cat "$outf"
rc=0
if [ -n "$rcf" ]; then read -r rc < "$rcf"; fi
exit "${rc:-0}"
