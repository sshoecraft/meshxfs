#!/bin/bash
# iwr_refuse_streaks.sh — grade the empty-case refusal streaks of
# tests/noino_gen0_ab.sh laps (H-WW1-R / H-WW1-R2 in
# tests/queues/livefeed_main_*.queue).
#
#   tests/iwr_refuse_streaks.sh <lap-evidence-dir>...
#
# An empty-case refusal (iwr_refuse_empty) completes an inode-cluster write
# with no I/O; pal/linux/xfs_buf.c prints P-IWR-REFUSED for the 1st, 2nd, 4th,
# ... refusal of a buffer's streak (refusals no more than 1 s apart) and
# P-IWR-REFUSE-END with the streak's count and length when the buffer is next
# written (why=partial|whole), read (why=read), refused again after a gap
# (why=gap) or freed (why=freed).  For each node of each lap, from the node's
# kernel stream (<node>_dmesg_stream.gz) from the lap's mark
# (NOINO-GEN0-<label>-<pid>, which tests/noino_gen0_ab.sh writes to every node
# when it zeroes the lap's counters) and its counters (<node>_kmsg.txt), this
# prints:
#   refused     iwr_empty_refused, the node's counter after the workload
#   streaks     P-IWR-REFUSE-END lines, and by why=
#   closed_n    the sum of their n= -- equal to refused when every refusal
#               belongs to a streak that closed by the time of the capture
#   max_ms      the longest streak_ms of a closed streak; max_n its largest n
#   open        refusals not in a closed streak (refused - closed_n)
#   logged0     P-IWR-REFUSED lines with logged=0x0 bli=0x0 (a refusal of a
#               write that owed nothing)
#   unskipped   P-IWR-REFUSED lines whose logged mask has a slot outside skip
#               (logged & ~skip != 0: a refusal while a logged slot was writable)
#   long        closed streaks with streak_ms >= 200 (and >= 30000)
# A stream that does not decompress whole is reported READ-FAILED, and one
# without the lap's mark NO-MARK, never as zeros: a stream starts before its
# lap (it carries the previous lap's tail), so an unscoped count adds another
# lap's streaks to this one's.  Detection only: the queue's rules grade these
# numbers.
set -u
[ $# -ge 1 ] || { echo "usage: $0 <lap-evidence-dir>..." >&2; exit 2; }
for d in "$@"; do
    [ -d "$d" ] || { echo "$d: not a directory"; continue; }
    label=$(basename "$d" | sed -n 's/^.*_noino_gen0_//p')
    for s in "$d"/*_dmesg_stream.gz; do
        [ -f "$s" ] || continue
        n=$(basename "$s" _dmesg_stream.gz)
        if [ -z "$label" ] || ! zcat "$s" 2>/dev/null | grep -aq -- "NOINO-GEN0-$label-"; then
            echo "$(basename "$d") $n NO-MARK"
            continue
        fi
        tmp=$(mktemp)
        if ! zcat "$s" 2>/dev/null | sed -n "/NOINO-GEN0-$label-/,\$p" \
                | grep -a 'P-IWR-REFUSED \|P-IWR-REFUSE-END ' > "$tmp"; then
            # grep exits 1 on no match; a failed zcat is what matters
            if ! zcat "$s" > /dev/null 2>&1; then
                echo "$(basename "$d") $n READ-FAILED"
                rm -f "$tmp"
                continue
            fi
        fi
        refused=$(sed -n 's/^iwr_empty_refused=//p' "$d/${n}_kmsg.txt" 2>/dev/null)
        awk -v lap="$(basename "$d")" -v node="$n" -v refused="${refused:-?}" '
            / P-IWR-REFUSE-END / {
                ends++
                for (i = 1; i <= NF; i++) {
                    split($i, kv, "=")
                    if (kv[1] == "n") nn = kv[2] + 0
                    else if (kv[1] == "streak_ms") ms = kv[2] + 0
                    else if (kv[1] == "why") why[kv[2]]++
                }
                closed += nn
                if (ms > maxms) maxms = ms
                if (nn > maxn) maxn = nn
                if (ms >= 200) long200++
                if (ms >= 30000) long30k++
                next
            }
            / P-IWR-REFUSED / {
                lines++
                if ($0 ~ / logged=0x0 / && $0 ~ / bli=0x0 /) logged0++
                lg = ""; sk = ""
                for (i = 1; i <= NF; i++) {
                    split($i, kv, "=")
                    if (kv[1] == "logged") lg = kv[2]
                    else if (kv[1] == "skip") sk = kv[2]
                }
                if (lg == "" || sk == "") unparsed++
                else if (and(strtonum(lg), compl(strtonum(sk))) != 0) unskipped++
            }
            END {
                w = ""
                for (k in why) w = w k ":" why[k] " "
                open = (refused == "?") ? "?" : refused - closed
                printf "%s %s refused=%s streaks=%d (%s) closed_n=%d open=%s max_ms=%d max_n=%d refused_lines=%d logged0=%d unskipped=%d unparsed=%d long200=%d long30000=%d\n",
                    lap, node, refused, ends, w, closed, open, maxms, maxn,
                    lines, logged0, unskipped, unparsed, long200, long30k
            }' "$tmp"
        rm -f "$tmp"
    done
done
