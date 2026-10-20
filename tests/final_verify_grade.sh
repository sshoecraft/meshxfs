#!/bin/bash
# final_verify_grade.sh — grades the final-verification campaign
# (tests/queues/final_verify_*.queue) by the reading rules in those queues'
# headers.
#
#   tests/final_verify_grade.sh <queue-label>... [> table]
#
# Run from the tree the queues ran in (their tests/evidence holds the lap
# consoles and evidence directories).  For every finished lap of each queue
# (tests/evidence/lapq_<label>.log and its lapq_<label>_<n>.console):
#   NODE rows   each node's whole kernel log (<node>_dmesg_stream.gz) after
#               the lap's NOINO-GEN0-<label>- mark, counting every line class
#               the rules name:
#                 fail      the harnesses' node failure pattern (shutdown,
#                           withdraw, self-fence, wedge, session poison, BUG,
#                           Oops, hung task)
#                 clobber   P-DINO-CLOBBER#N with regress >= 1, any path/shape
#                 unlanded  P-IFREE-DEFER-UNLANDED-FATAL
#                 cancel    P-CR3-CANCEL
#                 p53       P53-IUNLINK-MISMATCH
#                 verify    metadata/dinode verifier and in-memory corruption
#                           lines (not named by the rules; counted so a lap
#                           that has one is never read as clean by omission)
#                 cr63held  P-CR63-HELD: a create reset a cached copy of its
#                           number that something else still referenced
#               and, as reach (never a failure), the stale-name guard's lines:
#                 sn_poison P-RELOAD-XINCARN-POISON  sn_adopt  P-RELOAD-XINCARN-ADOPT
#                 sn_lrefuse P-INCARN-LOCKED-REFUSE  sn_reset  P-RESET-CLEARS-POISON
#                 sn_revoke P-REVOKE-REINCARNATED    sn_pskip  P-INACT-POISONED-SKIP
#               and the allocator's held-copy skip:
#                 hs_skip   P-DIALLOC-HELD-SKIP
#   LAP row     PASS only when the cold audit reads CLEAN errors=0, no
#               *RESULT verdict ends in FAIL, every NODE row is all zeros,
#               chk_audit.log has no P-FREE-LIVE-CORE, the workload printed
#               no error (ops_err: any line of the churn, lookup, feed or
#               unlink output that is not its summary, blank or an ssh banner),
#               every knob=value in FVG_KNOBS reads so in each node's
#               post-workload <node>_kmsg.txt, and the lap neither
#               ended ABORT nor overran (rc=124).  An ABORT or overrun is
#               FAIL here; the rules let a rig cause (host preflight, another
#               group's configuration lock, a node that never booted) excuse
#               it only after its own lines are read, which this script does
#               not judge.
#   REACH row   each guard's reach from the lap's *RESULT lines, the fields
#               the rules list.
# The last lines sum the reach over every finished lap and state the
# campaign verdict: PASS only when every finished lap PASSES.  Example lines
# of every nonzero class go to tests/evidence/fvg_<label>.details.
#
# A lap still running (no RESULT line yet) is listed as RUNNING and not read.
# A stream that does not decompress whole is READ-FAILED, never a row of zeros.
set -u -o pipefail
cd "$(dirname "$0")/.." || exit 2
[ $# -gt 0 ] || { echo "usage: $0 <queue-label>..." >&2; exit 2; }
reach_keys="CRESULT:cr_deferred WRESULT:ww_refused SRESULT:rs_live_reuse RRESULT:found ARESULT:found ERESULT:found GRESULT:failed BRESULT:found BRESULT:prevented URESULT:moved NRESULT:recycle_reset RESULT:hf7_reset RESULT:fk_refused RESULT:sc_refused RESULT:pc_rel_waited"
declare -A total
laps=0
failed=0
running=0
for q in "$@"; do
    log=tests/evidence/lapq_$q.log
    [ -r "$log" ] || { echo "no queue log $log" >&2; continue; }
    det=tests/evidence/fvg_$q.details
    : > "$det"
    for con in $(ls tests/evidence/lapq_"$q"_*.console 2>/dev/null | sort -t_ -k3 -n); do
        n=${con##*_}; n=${n%.console}
        hdr=$(head -1 "$con")
        out=$(printf '%s\n' "$hdr" | grep -o 'out=[^ ]*' | head -1 | cut -d= -f2)
        label=$(printf '%s\n' "$hdr" | grep -o 'label=[^ ]*' | head -1 | cut -d= -f2)
        res=$(grep -a '^RESULT' "$con" | tail -1)
        if [ -z "$res" ]; then
            printf 'LAP\t%s\t%s\t%s\tRUNNING\n' "$q" "$n" "${label:-?}"
            running=$((running + 1))
            continue
        fi
        laps=$((laps + 1))
        rc=$(grep -a "QUEUE lap=$n rc=" "$log" | tail -1 | grep -o 'rc=[0-9]*' | cut -d= -f2)
        base=$(printf '%s\n' "$res" | awk '{print $2}')
        audit=$(grep -a '^cold audit: ' "$con" | tail -1 | awk '{print $3 " " $4}')
        fails=$(grep -a '^[A-Z]*RESULT' "$con" | awk '$2 ~ /FAIL$/ {printf "%s%s", s, $2; s=","}')
        why=""
        [ "$audit" = "CLEAN errors=0" ] || why="$why audit=[${audit:-none}]"
        [ -z "$fails" ] || why="$why fail_verdicts=$fails"
        [ "$base" != ABORT ] || why="$why ABORT"
        [ "${rc:-}" != 124 ] || why="$why overran"
        { echo "===== $q lap $n $label rc=${rc:-?}"; grep -a '^[A-Z]*RESULT' "$con"; } >> "$det"
        if [ -z "$out" ] || [ ! -d "$out" ]; then
            printf 'LAP\t%s\t%s\t%s\tFAIL\trc=%s\tNO-EVIDENCE-DIR%s\n' "$q" "$n" "$label" "${rc:-?}" "$why"
            failed=$((failed + 1))
            continue
        fi
        freelive=$(grep -ac 'P-FREE-LIVE-CORE' "$out/chk_audit.log" 2>/dev/null)
        [ -r "$out/chk_audit.log" ] || freelive=NO-AUDIT-LOG
        [ "$freelive" = 0 ] || why="$why chk_audit_freelive=$freelive"
        wlerr=$(cat "$out"/*_churn.out "$out"/*_lookup.out "$out"/*_pfeed.out "$out"/*_punlink.out 2>/dev/null |
            grep -a -v -e '^churn dir=' -e '^lookup dir=' -e '^peer_feed dir=' -e '^peer_unlink dir=' -e '^$' \
                -e '^Warning: Permanently added ' -e '^Unauthorized access to this system' \
                -e '^If you are not an authorized user')
        ops_err=0
        if [ -n "$wlerr" ]; then
            ops_err=$(printf '%s\n' "$wlerr" | wc -l)
            why="$why ops_err=$ops_err"
            printf '%s\n' "$wlerr" | head -5 | sed 's/^/  workload error: /' >> "$det"
        fi
        streams=$(ls "$out"/*_dmesg_stream.gz 2>/dev/null)
        [ -n "$streams" ] || why="$why NO-STREAMS"
        for kv in ${FVG_KNOBS:-}; do
            for s in $streams; do
                node=$(basename "$s" _dmesg_stream.gz)
                got=$(sed -n "s/^${kv%%=*}=//p" "$out/${node}_kmsg.txt" 2>/dev/null | tail -1)
                [ "$got" = "${kv#*=}" ] || why="$why $node:${kv%%=*}=${got:-unread}"
            done
        done
        for s in $streams; do
            node=$(basename "$s" _dmesg_stream.gz)
            row=$(timeout 180 zcat "$s" 2>/dev/null | awk -v L="$label" -v D="$det" -v N="$node" '
                function ex(c, l) { if (++shown[c] <= 3) print "  " N " " c ": " substr(l, 1, 400) >> D }
                !on && index($0, "NOINO-GEN0-" L "-") { on = 1 }
                on && index($0, "NOINO-GEN0-" L "-") { marks++ }
                !on { next }
                index($0, "Shutting down filesystem") || index($0, "P-WITHDRAW") || index($0, "P131-SELF-FENCE") || index($0, "P-INODE-WEDGE ") || index($0, "P-SESSION-POISON") || index($0, "BUG:") || index($0, "Oops") || index($0, "blocked for more than") { c["fail"]++; ex("fail", $0) }
                index($0, "P-DINO-CLOBBER#") && match($0, / regress=[0-9]+/) && substr($0, RSTART + 9, RLENGTH - 9) + 0 >= 1 { c["clobber"]++; ex("clobber", $0) }
                index($0, "P-IFREE-DEFER-UNLANDED-FATAL") { c["unlanded"]++; ex("unlanded", $0) }
                index($0, "P-CR3-CANCEL") { c["cancel"]++; ex("cancel", $0) }
                index($0, "P53-IUNLINK-MISMATCH") { c["p53"]++; ex("p53", $0) }
                index($0, "xfs_dinode_verify") || index($0, "Metadata corruption detected") || index($0, "Corruption of in-memory data") || index($0, "Metadata CRC error") || index($0, "not marked free") { c["verify"]++; ex("verify", $0) }
                index($0, "P-CR63-HELD ") { c["cr63held"]++; ex("cr63held", $0) }
                index($0, "P-DIALLOC-HELD-SKIP ") { r["hs_skip"]++; ex("hs_skip", $0) }
                index($0, "P-RELOAD-XINCARN-POISON") { r["sn_poison"]++; ex("sn_poison", $0) }
                index($0, "P-RELOAD-XINCARN-ADOPT") { r["sn_adopt"]++; ex("sn_adopt", $0) }
                index($0, "P-INCARN-LOCKED-REFUSE") { r["sn_lrefuse"]++; ex("sn_lrefuse", $0) }
                index($0, "P-RESET-CLEARS-POISON") { r["sn_reset"]++; ex("sn_reset", $0) }
                index($0, "P-REVOKE-REINCARNATED") { r["sn_revoke"]++; ex("sn_revoke", $0) }
                index($0, "P-INACT-POISONED-SKIP") { r["sn_pskip"]++; ex("sn_pskip", $0) }
                END {
                    printf "%d", marks + 0
                    split("fail clobber unlanded cancel p53 verify cr63held", k, " ")
                    bad = 0
                    for (i = 1; i <= 7; i++) { printf "\t%s=%d", k[i], c[k[i]] + 0; bad += c[k[i]] + 0 }
                    printf "\tbad=%d", bad
                    split("sn_poison sn_adopt sn_lrefuse sn_reset sn_revoke sn_pskip hs_skip", q, " ")
                    for (i = 1; i <= 7; i++) printf "\t%s=%d", q[i], r[q[i]] + 0
                    printf "\n"
                }')
            rc2=$?
            if [ "$rc2" != 0 ]; then
                row="READ-FAILED rc=$rc2"
                why="$why $node:READ-FAILED"
            else
                case "$row" in
                    0*) why="$why $node:no-mark" ;;
                esac
                b=${row##*bad=}; b=${b%%[!0-9]*}
                [ "$b" = 0 ] || why="$why $node:bad=$b"
                for f in $(printf '%s\n' "$row" | tr '\t' '\n' | grep '^sn_\|^hs_'); do
                    total[${f%%=*}]=$(( ${total[${f%%=*}]:-0} + ${f#*=} ))
                done
            fi
            printf 'NODE\t%s\t%s\t%s\t%s\tmarks=%s\n' "$q" "$n" "$label" "$node" "$row"
        done
        reach=""
        for kv in $reach_keys; do
            p=${kv%%:*}; k=${kv#*:}
            v=$(grep -a "^$p: " "$con" | tail -1 | grep -o " $k=[0-9]*" | head -1 | cut -d= -f2)
            reach="$reach $p.$k=${v:--}"
            [ -n "$v" ] && total[$p.$k]=$(( ${total[$p.$k]:-0} + v ))
        done
        if [ -z "$why" ]; then
            printf 'LAP\t%s\t%s\t%s\tPASS\trc=%s\tbase=%s\taudit=%s\n' "$q" "$n" "$label" "${rc:-?}" "$base" "$audit"
        else
            printf 'LAP\t%s\t%s\t%s\tFAIL\trc=%s\tbase=%s\twhy=%s\n' "$q" "$n" "$label" "${rc:-?}" "$base" "$why"
            failed=$((failed + 1))
        fi
        printf 'REACH\t%s\t%s\t%s\t%s\n' "$q" "$n" "$label" "$reach"
    done
done
sum=""
for kv in $reach_keys; do
    p=${kv%%:*}; k=${kv#*:}
    sum="$sum $p.$k=${total[$p.$k]:-0}"
done
for k in sn_poison sn_adopt sn_lrefuse sn_reset sn_revoke sn_pskip hs_skip; do
    sum="$sum $k=${total[$k]:-0}"
done
printf 'TOTAL\tlaps=%d\tfailed=%d\trunning=%d\t%s\n' "$laps" "$failed" "$running" "$sum"
if [ "$failed" = 0 ] && [ "$laps" -gt 0 ]; then
    echo "CAMPAIGN: every finished lap PASSES ($laps finished, $running running)"
else
    echo "CAMPAIGN: FAIL or EMPTY ($failed of $laps finished laps fail, $running running)"
fi
