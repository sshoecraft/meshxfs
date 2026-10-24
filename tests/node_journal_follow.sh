#!/bin/bash
# node_journal_follow.sh -- stream rig nodes' journals (kernel and userspace, priority info and
# above) into files on the host, reconnecting across each node's reboots, until a stop file
# appears or the bound runs out.
#
# WHY.  D-DRBD-THIRD-VOTE-RESTORE-POWER-FENCED-LIVE-TEST2-AND-LEFT-IT-INHIBITED: during a
# third_vote lap test1's fence handler powered test2 off while the pair re-formed, and both
# nodes keep a volatile journal, so nothing kept says why.  The DRBD steps reboot and power-cycle
# the nodes, so a capture on the node dies with it; this one lives on the host.  Priority info
# and above leaves out the module's debug probes (mxfs_probe is pr_debug, and the rig loads
# dyndbg=+p), which would otherwise fill the host's disk.
#
# Each connection follows the node's current boot from its start (-b), so a reconnect within
# one boot repeats lines; every connection is delimited by a '=== <time> connect <node>' line.
#
# Usage: node_journal_follow.sh <out dir> <bound s> <node> [<node> ...]
#        touch <out dir>/STOP ends it early.
set -u
cd "$(dirname "$0")" || exit 2
while [ ! -f run.sh ] && [ "$(pwd)" != / ]; do cd ..; done
[ -f run.sh ] || { echo "node_journal_follow: no tree root above $0" >&2; exit 2; }
. tools/mxfs_lab.sh
SSH=tools/mxfs_sshpass.sh
OUT=${1:?out dir}
MAX_S=${2:?bound s}
shift 2
[ $# -ge 1 ] || { echo "node_journal_follow: no node named" >&2; exit 2; }
mkdir -p "$OUT"
end=$((SECONDS + MAX_S))
declare -A PID
echo "$(date -u +%FT%TZ) start bound=${MAX_S}s nodes=$*" >> "$OUT/follow.log"
while [ "$SECONDS" -lt "$end" ] && [ ! -e "$OUT/STOP" ]; do
    for n in "$@"; do
        p=${PID[$n]:-}
        if [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null; then
            a=$(lab_addr "$n")
            left=$((end - SECONDS + 5))
            ( echo "=== $(date -u +%FT%T.%3NZ) connect $n"
              timeout "$left" "$SSH" "$a" "journalctl -b -f -p info -o short-iso-precise" < /dev/null 2>&1 ) >> "$OUT/$n.journal" &
            PID[$n]=$!
        fi
    done
    sleep 3
done
echo "$(date -u +%FT%TZ) end" >> "$OUT/follow.log"
for n in "$@"; do [ -n "${PID[$n]:-}" ] && kill "${PID[$n]}" 2>/dev/null; done
wait
