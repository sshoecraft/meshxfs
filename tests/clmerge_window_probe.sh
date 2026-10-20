#!/bin/bash
# tests/clmerge_window_probe.sh — does another node's write of an inode slot ever
# land inside the cluster merge's read-to-write window?  Hypothesis H-F1 of
# D-FREED-INODE-HOME-NEVER-PUBLISHED-LIVE-CORE-AFTER-CLEAN-UNMOUNT.
#
# H-F1, written before this probe: an inode-cluster write must carry some slots
# this node does not own: a buffer-logged unlinked pointer (an inactivation
# that frees an unlinked inode moves its predecessor's pointer past it, and the
# predecessor may be a file another node holds open) or an attached inode item
# whose copy-in was refused at NL.  mxfs_iflush_cluster_merge_dirs reads the
# platter and copies its image over every such foreign slot, so what goes out
# is the platter as of that read.  Nothing orders that read and the write
# against the slot owner's own writes, so an owner's write that lands between
# them is overwritten with the older image (a lost update of a committed core).
# The module's test knob dbg_clmerge_recheck (mxfs_clmerge_window_check,
# pal/linux/xfs_buf.c) re-reads each merge-restored slot a write carries just
# before submission and logs P-CLMERGE-WINDOW-HIT when the platter has moved;
# dbg_clmerge_write_delay_ms holds such a write first, to widen the window.
# PREDICTION IF TRUE: with the window widened, P-CLMERGE-WINDOW-HIT lines on the
#   owner for y<i> slots, the peer's image ahead of the outgoing one (disk_cc >
#   out_cc, same generation), and clmerge_win_hits > 0.
# IF FALSE: writes carry merge-restored y<i> slots (clmerge_win_slots > 0) and
#   none of them was rewritten in the window (clmerge_win_hits 0).
#
# THE WORKLOAD (tests/clmerge_window_node.sh): per iteration the owner A
# writes z<i> and y<i>; the peer B opens y<i> for appending; A holds z<i> open,
# removes z<i> and then y<i> (both join A's unlinked list, y<i> ahead of z<i>)
# and closes z<i>, whose inactivation frees it and moves y<i>'s unlinked
# pointer -- a buffer-logged range in y<i>'s cluster on A -- and A pushes its
# whole AIL (a slab cache drop) CMW_SYNCS times 0.3 s apart so that write goes
# out; meanwhile B appends to y<i>, fdatasyncs it and pushes its own AIL every
# 0.2 s for CMW_HOLD_S, so y<i>'s core keeps changing on the platter, then
# closes it and frees it.
#
# THE GRADES
#   ABORT     prep, knob read-back or counter read failed
#   VACUOUS   no write on either node carried a merge-restored slot
#             (clmerge_win_slots 0): the window was not offered
#   HIT       a carried merge-restored slot had been rewritten by another node
#             since the merge's read (clmerge_win_hits > 0): H-F1's window met
#   NOHIT     slots were carried and none had moved; the cold audit and the
#             nodes' kernel logs are reported beside it, and a CORRUPT audit or
#             a node failure makes the lap FAIL whatever the window did
#
# Budgets (derived): prep and the cold audit are run.sh rows under their own
# manifest budgets (run.sh flips an overrun to FAIL itself, so no outer
# timeout).  An owner iteration is two 4 KiB creates, at most 5 s waiting for
# the peer's open, two removes and a close, CMW_SYNCS syncs 0.3 s apart (each
# write the delay knob holds adds CMW_DELAY_MS), padded to CMW_HOLD_S: the
# workload is bounded by ITERS x (CMW_HOLD_S + 5 + CMW_SYNCS x (0.3 +
# 2 x CMW_DELAY_MS/1000) + 2) + 60 s.  Counters and knob resets 20-40 s per
# node; the stream copy 120 s.
#
# Usage: tests/clmerge_window_probe.sh <label> [iters=30] [config=2/net/mesh/direct] [group=g2c]
# Env:   CMW_DELAY_MS (default 200), CMW_HOLD_S (default 3), CMW_SYNCS (default 3),
#        CMW_RECHECK (default 1; 0 runs the workload with the check off, which
#        measures nothing and is graded VACUOUS)
# Exit 0 NOHIT, 1 HIT or FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}; ITERS=${2:-30}
CONFIG=${3:-2/net/mesh/direct}; GROUP=${4:-g2c}
DELAY=${CMW_DELAY_MS:-200}; HOLD=${CMW_HOLD_S:-3}; SYNCS=${CMW_SYNCS:-3}
RECHECK=${CMW_RECHECK:-1}
for v in "$ITERS" "$DELAY" "$HOLD" "$SYNCS"; do
    case "$v" in ''|*[!0-9]*) echo "iters, CMW_DELAY_MS, CMW_HOLD_S and CMW_SYNCS must be whole numbers"; exit 2 ;; esac
done
case "$RECHECK" in 0|1) ;; *) echo "CMW_RECHECK must be 0 or 1"; exit 2 ;; esac
cd "$(dirname "$0")/.." || exit 2
TREE=/src/$(basename "$PWD")
SSH=tools/mxfs_sshpass.sh
read -r A B rest <<< "$(tools/mxfs_lab.sh group "$GROUP")"
[ -n "${A:-}" ] && [ -n "${B:-}" ] || { echo "RESULT: ABORT label=$LABEL -- group $GROUP has no two nodes"; exit 2; }
# run.sh holds the nodes only while it runs; between its calls the workload
# below is invisible to tools/vm_pool.sh, whose idle sweep would shut them off
. tests/lib/runlock.sh
vmhold_take "clmerge_window_probe $LABEL" "$A" "$B" \
    || { echo "RESULT: ABORT label=$LABEL -- could not hold $A $B"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_clmerge_window_$LABEL
mkdir -p "$OUT"
MARK="CLMERGE-WINDOW-$LABEL-$$"
P=/sys/module/mxfs/parameters
CNTS="clmerge_win_writes clmerge_win_slots clmerge_win_hits clmerge_win_readfail"
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
echo "=== clmerge_window_probe label=$LABEL recheck=$RECHECK delay_ms=$DELAY hold_s=$HOLD syncs=$SYNCS iters=$ITERS $CONFIG $GROUP [$A $B] build=$(modinfo -F srcversion mxfs.ko) tree=$TREE out=$OUT $(date -u +%FT%TZ) ==="

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 \
    || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }
want=$(modinfo -F srcversion mxfs.ko)
for n in $A $B; do
    sv=$(rs 20 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$sv" = "$want" ] || { echo "RESULT: ABORT label=$LABEL -- $n runs '$sv', not the tree build $want evidence=$OUT"; exit 2; }
    got=$(rs 20 "$n" "echo $RECHECK > $P/dbg_clmerge_recheck; echo $DELAY > $P/dbg_clmerge_write_delay_ms; for c in $CNTS; do echo 0 > $P/\$c; done; echo $MARK > /dev/kmsg; echo \$(cat $P/dbg_clmerge_recheck)/\$(cat $P/dbg_clmerge_write_delay_ms)/\$(cat $P/clmerge_win_slots)" | tail -1)
    [ "$got" = "$RECHECK/$DELAY/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's dbg_clmerge_recheck/dbg_clmerge_write_delay_ms/clmerge_win_slots read '$got', not $RECHECK/$DELAY/0 (is the build missing a knob?) evidence=$OUT"; exit 2; }
done
D=/mnt/shared/cmw.$LABEL
rs 30 "$A" "mkdir -p $D && sync && echo ok" | grep -q ok || { echo "RESULT: ABORT label=$LABEL stage=mkdir evidence=$OUT"; exit 2; }

WL=$((ITERS * (HOLD + 5 + (SYNCS * (300 + 2 * DELAY) + 999) / 1000 + 2) + 60))
timeout $((WL + 10)) "$SSH" "$B" "bash $TREE/tests/clmerge_window_node.sh peer $D $HOLD" < /dev/null > "$OUT/${B}_peer.log" 2>&1 & pp=$!
timeout "$WL" "$SSH" "$A" "bash $TREE/tests/clmerge_window_node.sh owner $D $ITERS $HOLD $SYNCS" < /dev/null > "$OUT/${A}_owner.log" 2>&1
orc=$?
# the owner's 'done' ends the peer; if the owner never got there, end it here
[ "$orc" = 0 ] || rs 20 "$A" "touch $D/done" > /dev/null
wait $pp; prc=$?
echo "owner rc=$orc ($(tail -1 "$OUT/${A}_owner.log")) peer rc=$prc ($(tail -1 "$OUT/${B}_peer.log"))"

declare -A nfail=()
tot_w=0; tot_s=0; tot_h=0; tot_r=0
for n in $A $B; do
    rs 40 "$n" "for c in $CNTS; do echo \$c=\$(cat $P/\$c 2>/dev/null); done; echo mounted=\$(grep -c ' /mnt/shared mxfs ' /proc/mounts)" > "$OUT/${n}_counters.txt"
    v() { sed -n "s/^$1=//p" "$OUT/${n}_counters.txt"; }
    w=$(v clmerge_win_writes); s=$(v clmerge_win_slots); h=$(v clmerge_win_hits); r=$(v clmerge_win_readfail); mnt=$(v mounted)
    [ -n "$w" ] && [ -n "$s" ] && [ -n "$h" ] && [ -n "$r" ] && [ -n "$mnt" ] \
        || { echo "RESULT: ABORT label=$LABEL -- $n's counters did not read evidence=$OUT"; exit 2; }
    echo "$n window: writes=$w slots=$s hits=$h readfail=$r mounted=$mnt"
    tot_w=$((tot_w + w)); tot_s=$((tot_s + s)); tot_h=$((tot_h + h)); tot_r=$((tot_r + r))
    [ "$mnt" = 1 ] || nfail[$n]=1
done
for n in $A $B; do
    got=$(rs 20 "$n" "echo 0 > $P/dbg_clmerge_write_delay_ms; echo 0 > $P/dbg_clmerge_recheck; echo \$(cat $P/dbg_clmerge_write_delay_ms)/\$(cat $P/dbg_clmerge_recheck)" | tail -1)
    [ "$got" = 0/0 ] || echo "WARN $n's dbg_clmerge_write_delay_ms/dbg_clmerge_recheck read '$got' after the reset; the cold audit's writes would be held"
done

since=$(date -u +%FT%TZ)
./run.sh "$CONFIG" --group "$GROUP" chk_clean > "$OUT/chk.log" 2>&1
audit=$(python3 - data/criteria.json "$CONFIG" "$since" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
for e in d["criteria"]:
    if e.get("id") == "chk_clean":
        cell = (e.get("per_config") or {}).get(sys.argv[2]) or {}
        if str(cell.get("iso", "")) < sys.argv[3]:
            print("STALE"); break
        m = re.search(r"verdict=([A-Z]+).*?errors=(\d+)", str(cell.get("measured", "")))
        print("%s errors=%s" % m.groups() if m else "NONE")
        break
else:
    print("NONE")
PY
)
echo "cold audit: $audit ($OUT/chk.log)"
# The lap's whole kernel log: the prep starts `dmesg --follow` into
# /root/dmesg.stream on every node and the next lap's prep replaces it.
for n in $A $B; do
    timeout 120 "$SSH" "$n" "gzip -c /root/dmesg.stream" < /dev/null 2>/dev/null > "$OUT/${n}_dmesg_stream.gz"
    echo "$n kernel log: $OUT/${n}_dmesg_stream.gz marks=$(zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | grep -acF -- "$MARK")"
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
        | grep -a 'Shutting down filesystem\|P-WITHDRAW\|P131-SELF-FENCE\|P-INODE-WEDGE \|P-SESSION-POISON\|BUG:\|Oops\|blocked for more than' > "$OUT/${n}_failures.txt"
    sds=$(wc -l < "$OUT/${n}_failures.txt")
    echo "$n stream failure lines: $sds ($OUT/${n}_failures.txt)"
    head -3 "$OUT/${n}_failures.txt" | cut -c1-300
    [ "$sds" = 0 ] || nfail[$n]=1
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
        | grep -a 'P-CLMERGE-WINDOW-HIT ' > "$OUT/${n}_window_hits.txt"
    echo "$n P-CLMERGE-WINDOW-HIT lines: $(wc -l < "$OUT/${n}_window_hits.txt")"
    head -5 "$OUT/${n}_window_hits.txt" | cut -c1-400
done
bad=${#nfail[@]}

REP="recheck=$RECHECK delay_ms=$DELAY hold_s=$HOLD syncs=$SYNCS iters=$ITERS owner_rc=$orc peer_rc=$prc writes=$tot_w slots=$tot_s hits=$tot_h readfail=$tot_r"
[ "$tot_s" -gt 0 ] || { echo "RESULT: VACUOUS clmerge_window_probe label=$LABEL $REP audit=$audit node_failures=$bad -- no write carried a merge-restored slot evidence=$OUT"; exit 3; }
[ "$tot_h" -gt 0 ] && { echo "RESULT: HIT clmerge_window_probe label=$LABEL $REP audit=$audit node_failures=$bad -- a merge-restored slot was rewritten by another node inside the window evidence=$OUT"; exit 1; }
case "$audit" in CLEAN*) aok=1 ;; *) aok=0 ;; esac
if [ "$aok" = 1 ] && [ "$bad" = 0 ] && [ "$orc" = 0 ]; then
    echo "RESULT: NOHIT clmerge_window_probe label=$LABEL $REP audit=$audit evidence=$OUT"; exit 0
fi
echo "RESULT: FAIL clmerge_window_probe label=$LABEL $REP audit=$audit node_failures=$bad -- no window hit, but the audit, a node or the workload failed evidence=$OUT"; exit 1
