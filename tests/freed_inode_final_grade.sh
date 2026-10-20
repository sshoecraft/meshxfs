#!/bin/bash
# freed_inode_final_grade.sh — the per-lap counts the final-verification
# queues' verdict rules grade on (tests/queues/freed_inode_final_*.queue).
#
#   tests/freed_inode_final_grade.sh <queue-label>... [> table]
#
# For every finished lap of each queue (tests/evidence/lapq_<label>.log and
# its lapq_<label>_<n>.console) it prints the harness's own verdict line and,
# for each node's whole kernel log (<node>_dmesg_stream.gz in the lap's
# evidence directory), the count after the lap's mark of every line class
# the rules name:
#   CORRUPT   undrained = P-NOINO-UNLOCK-UNDRAINED
#             left_live = P-NOINO-UNLOCK-LEFT-GRANT lifecycle=LIVE cached_mode=5
#             owes_s0 / owes_s1 = P-RECYCLE-RESET-UNDER-NOINO owes=1 at_start=0/1
#             pi0 = P-LOG-MIRROR-PHANTOM / P-LOGWR-DLM-NOGRANT with no publish
#                   claim of the inode in flight: q_inflight=0 where the line
#                   carries it (sampled before the DLM is asked), else
#                   pub_inflight=0 (sampled at the print, after the query, so
#                   a claim that returned while the query ran reads 0)
#             verify = dinode/metadata verifier failure lines
#             freelive = P-FREE-LIVE-CORE
#   UNSTABLE  fail = the harnesses' node failure pattern (shutdown, withdraw,
#             self-fence, wedge, session poison, BUG, Oops, hung task)
#   REACH     wait/keep/takeover/takenover = the dirty-corpse lines,
#             reset = every P-RECYCLE-RESET-UNDER-NOINO, p220d = a tenure ending
#             with logged fields, p119 = a non-EX flush skip
# The harness's own counts read the same streams through several greps; this
# reads each stream once, with every class from the rules, so a class the
# harness's PASS does not gate (left_live, owes_s1, pi0, verify) is counted
# too.  Example lines of every nonzero CORRUPT/UNSTABLE class go to
# tests/evidence/fyg_<label>.details.
#
# A lap still running (no RESULT line yet) is listed as RUNNING and not read.
# A stream that does not decompress whole is READ-FAILED, never a row of zeros.
set -u -o pipefail
cd "$(dirname "$0")/.." || exit 2
[ $# -gt 0 ] || { echo "usage: $0 <queue-label>..." >&2; exit 2; }
printf 'queue\tlap\tlabel\tverdict\taudit\thf11_chain\tzresult\tnode\tmarks\tundrained\tleft_live\towes_s0\towes_s1\tpi0\tverify\tfreelive\tfail\twait\tkeep\ttakeover\ttakenover\treset\tp220d\tp119\n'
for q in "$@"; do
    log=tests/evidence/lapq_$q.log
    [ -r "$log" ] || { echo "no queue log $log" >&2; continue; }
    det=tests/evidence/fyg_$q.details
    : > "$det"
    for con in $(ls tests/evidence/lapq_"$q"_*.console 2>/dev/null | sort -t_ -k3 -n); do
        n=${con##*_}; n=${n%.console}
        hdr=$(head -1 "$con")
        out=$(printf '%s\n' "$hdr" | grep -o 'out=[^ ]*' | head -1 | cut -d= -f2)
        label=$(printf '%s\n' "$hdr" | grep -o 'label=[^ ]*' | head -1 | cut -d= -f2)
        res=$(grep -a '^RESULT' "$con" | tail -1)
        if [ -z "$res" ]; then
            printf '%s\t%s\t%s\tRUNNING\n' "$q" "$n" "${label:-?}"
            continue
        fi
        verdict=$(printf '%s\n' "$res" | awk '{print $2}')
        # the console's own audit line: a VACUOUS line of the noino harness
        # does not carry audit=, and the line also gives the error count
        audit=$(grep -a '^cold audit: ' "$con" | tail -1 | awk '{print $3 "/" $4}')
        chain=$(printf '%s\n' "$res" | grep -o 'hf11_chain=[0-9]*' | cut -d= -f2)
        zres=$(grep -a '^ZRESULT' "$con" | tail -1 | awk '{print $2}')
        { echo "===== $q lap $n $label"; echo "$res"; grep -a '^ZRESULT' "$con" | tail -1; } >> "$det"
        if [ -z "$out" ] || [ ! -d "$out" ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tNO-EVIDENCE-DIR\n' "$q" "$n" "$label" "$verdict" "${audit:--}" "${chain:--}" "${zres:--}"
            continue
        fi
        streams=$(ls "$out"/*_dmesg_stream.gz 2>/dev/null)
        [ -n "$streams" ] || { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tNO-STREAMS\n' "$q" "$n" "$label" "$verdict" "${audit:--}" "${chain:--}" "${zres:--}"; continue; }
        for s in $streams; do
            node=$(basename "$s" _dmesg_stream.gz)
            row=$(timeout 120 zcat "$s" 2>/dev/null | awk -v L="$label" -v D="$det" -v N="$node" '
                function ex(c, l) { if (++shown[c] <= 3) print "  " N " " c ": " substr(l, 1, 400) >> D }
                !on && (index($0, "NOINO-GEN0-" L "-") || index($0, "PEER-LAST-CLOSER-" L "-")) { on = 1 }
                on && (index($0, "NOINO-GEN0-" L "-") || index($0, "PEER-LAST-CLOSER-" L "-")) { marks++ }
                !on { next }
                index($0, "P-NOINO-UNLOCK-UNDRAINED") { c["undrained"]++; ex("undrained", $0) }
                index($0, "P-NOINO-UNLOCK-LEFT-GRANT") && index($0, "lifecycle=LIVE") && index($0, "cached_mode=5") { c["left_live"]++; ex("left_live", $0) }
                index($0, "P-RECYCLE-RESET-UNDER-NOINO") {
                    c["reset"]++
                    if (index($0, " owes=1 at_start=0")) { c["owes_s0"]++; ex("owes_s0", $0) }
                    if (index($0, " owes=1 at_start=1")) { c["owes_s1"]++; ex("owes_s1", $0) }
                }
                (index($0, "P-LOG-MIRROR-PHANTOM") || index($0, "P-LOGWR-DLM-NOGRANT")) && (index($0, " q_inflight=") ? index($0, " q_inflight=0 ") : index($0, " pub_inflight=0")) { c["pi0"]++; ex("pi0", $0) }
                index($0, "xfs_dinode_verify") || index($0, "Metadata corruption detected") || index($0, "Corruption of in-memory data") || index($0, "Metadata CRC error") { c["verify"]++; ex("verify", $0) }
                index($0, "P-FREE-LIVE-CORE") { c["freelive"]++; ex("freelive", $0) }
                index($0, "Shutting down filesystem") || index($0, "P-WITHDRAW") || index($0, "P131-SELF-FENCE") || index($0, "P-INODE-WEDGE ") || index($0, "P-SESSION-POISON") || index($0, "BUG:") || index($0, "Oops") || index($0, "blocked for more than") { c["fail"]++; ex("fail", $0) }
                index($0, "P-RECYCLE-DIRTY-WAIT ") { c["wait"]++ }
                index($0, "P-RECYCLE-DIRTY-KEEP ") { c["keep"]++ }
                index($0, "P-RECYCLE-DIRTY-TAKEOVER ") { c["takeover"]++ }
                index($0, "P-NOINO-TAKEN-OVER ") { c["takenover"]++ }
                index($0, "P220-EPOCH-LEDGER-OPEN") && match($0, /ili_f=0x[0-9a-f]+/) && substr($0, RSTART, RLENGTH) != "ili_f=0x0" { c["p220d"]++ }
                index($0, "P119-NONEX-FLUSH-SKIP") { c["p119"]++ }
                END {
                    printf "%d", marks + 0
                    split("undrained left_live owes_s0 owes_s1 pi0 verify freelive fail wait keep takeover takenover reset p220d p119", k, " ")
                    for (i = 1; i <= 15; i++) printf "\t%d", c[k[i]] + 0
                    printf "\n"
                }')
            rc=$?
            [ "$rc" = 0 ] || row="READ-FAILED rc=$rc"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$q" "$n" "$label" "$verdict" "${audit:--}" "${chain:--}" "${zres:--}" "$node" "$row"
        done
    done
done
