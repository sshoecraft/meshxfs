#!/bin/bash
# tests/peer_open_unlinked_chain.sh — D-PEER-OPEN-UNLINKED-CHAIN-REMOVE-FAILS-IFREE-SHUTDOWN-BOTH-NODES:
# two nodes, one unlinked list, on the build in the tree with no test knob.
#
# THE DEFECT (as first seen, on a build carrying a read-only test check): the
# owner A removes a file it holds open (z) and then a file the peer B holds open
# (y), so y joins A's unlinked bucket ahead of z, and closes z.  The free of z
# removes it from that list with the predecessor and successor A's in-core
# chain names.  Two failures were logged, each ending in 'xfs_ifree returned
# error' and a forced shutdown: P-UNLREM-NOPREV (the predecessor was not in
# core on A: A holds no reference to y, the peer is its last closer, and a cache
# drop reclaimed A's copy) and P-UNLREM-BACKREF rc=-22 (an in-core next pointer
# named an inode already freed and off the list), on A and then on B.
#
# WHAT THIS MEASURES.  Whether the same workload (tests/clmerge_window_node.sh,
# the probe's own node side, no knob of any kind) fails that way on this build,
# and when it does, what the platter holds: the LUN image is kept before
# anything touches it again and tools/chk_mxfs reads it.  PUC_INSTR=1 also sets
# the module's `instr` parameter, which makes every remove that has a next
# pointer log P83-UNL-REMCHK (its in-core next against the dinode's on the
# platter, one FUA dinode read per remove) for tracing hypothesis H-U2; it
# changes the remove's timing, so the default is off.
#
# THE GRADES
#   ABORT       prep, srcversion check, knob read-back or mkdir failed
#   VACUOUS     the owner completed no iteration with the peer holding y
#   REPRODUCED  any P-UNLREM-NOPREV, P-UNLREM-BACKREF or 'xfs_ifree returned
#               error' line, or any node failure line, in either node's whole
#               kernel log after the lap's mark
#   PASS        none of those, every iteration acknowledged by the peer, the
#               workload ended on its own, and the cold audit CLEAN errors=0
#   FAIL        none of those lines, but the workload or the cold audit failed
#
# PUC_KNOBS ("name=number ...") sets module parameters on both nodes after the
# prep, reads each back, and ABORTs on a mismatch: the same-build A/B arm.  On a
# reproduction both nodes are mounted again after the image is kept, the way
# the prep mounted them, so the cold audit grades the filesystem their journals
# replay to rather than reading STALE.  Per node the lap also counts the H-U3
# lines: P53-IUNLINK-MISMATCH, P34D-RELOAD-FRESHSRC (ratelimited),
# P-FRESHSRC-IUNL-STALE with grafted=0 and grafted=1, and sig_pre, the
# P53-IUNLINK-MISMATCH lines whose inode a grafted=0 stale line named earlier,
# before that node's first 'xfs_ifree returned error'.  And the H-U4 lines:
# P-UNLPREV-NOTENURE, P-NEXTWR-STALE, P-IUNL-OWED-AT-RELEASE (landed=0 and
# landed=1), P-KEPT-NEXT-STALE (refreshed=0 and refreshed=1), P-UNLPREV-WAIT,
# P-UNLPREV-DEFER and P-IUNL-LAND-FAIL, beside the module's own counters of the
# same events (unlprev_notenure, unlprev_waits, nextwr_stale, iunl_owed_release,
# kept_next_stale, freshsrc_iunl_stale, freshsrc_iunl_overlaid), which the lap
# zeroes after the prep and reads after the settle: a counter still counts a
# line the log dropped.  And the H-U5 lines: P-B6-RELEASE-DIRTY (an
# inactivation deferred for a peer's open holder whose grant release found the
# inode's committed state not at home; drain=0 in the control, drained=1 or
# kept=1 in the fix arm) and P17B-EPOCH-GHOST-SKIP, with ghost_b6, the P17B
# lines whose inode a P-B6-RELEASE-DIRTY line with drained=0 named earlier:
# H-U5's signature.  The module's b6_release_dirty, b6_release_drained and
# b6_release_kept are zeroed and read with the other counters.  And the H-U1
# lines: P-UNLPREV-ABSENT (a mid-list free whose predecessor was absent,
# reclaimable or mid-evict in core; pin=0 in the control, pin=1 in the fix
# arm), beside the module's unlprev_absent and unlprev_pinned.  And the H-U6
# lines: P-CR3-NEEDINACT (a create spinning on a number whose inactivation is
# still running) and P-BUFLOCK-STUCK (a buffer lock held past its bound: the
# AGI of hu4df1's deadlock), beside the module's unlprev_rele_deferred (the
# predecessor references a free handed to the workqueue in the fix arm).  H-U6's
# census: the module's unlprev_rele_inline_last and unlprev_rele_deferred_last
# count the committed frees whose release was the last reference on an
# unlinked predecessor, the only release that can run a nested inactivation
# (released inline in the control arm, handed off in the fix arm), and each
# such release logs P-UNLPREV-RELE-LAST with the releasing task's comm; the
# lap reports the lines whose comm is a kworker (rele_last_worker), the context
# hu4df1's outer free ran in, since a release in the owner's own task leaves no
# owner create to take the freed number meanwhile.  A build without the census
# reports those fields '?'.  And the H-U7 lines: P-RELOAD-NEXT-STALE (a reload
# that kept an unlinked inode whose dinode names another di_next_unlinked than
# the in-core inode; refreshed=0 in the control, refreshed=1 in the fix arm),
# beside the module's reload_next_stale and reload_next_refreshed, and
# sig_next, the P-UNLREM-BACKREF lines whose inode and next pointer an earlier
# refreshed=0 line of the same node named as its kept in-core next: H-U7's
# signature.  A build without H-U7 reports the counters '?'.
# An owner that overran its bound is graded REPRODUCED hung=1: each node's
# D-state tasks and their stacks are kept as <node>_dstacks.txt, and the
# unmount, remount and cold audit, which would block on the wedged mount, are
# not run (the audit reads STALE).  The nodes are left as they are.
# PUC_CLOSE_DROPS=N makes the owner run N cache drops 50 ms apart in the
# background across each close of z (tests/clmerge_window_node.sh
# CMW_CLOSE_DROPS), H-U1's window, with test knob dbg_ifree_midlist_delay_ms
# set through PUC_KNOBS holding z's free while they run.
# And the H-IU1 lines (D-IUNLINK-PREV-OF-PEER-FREED-INODE-STALE-PRECOMMIT-
# SHUTDOWN): P-UNLPREV-MOVED (the predecessor whose hold z's free waited for
# no longer precedes z; moved_freed counts those read back free, fn32's shape),
# P-UNLPREV-REBUILD (a free started over for it, fix arm), and sig_iu1, the
# P53-IUNLINK-MISMATCH lines on an inode that an earlier MOVED line of the same
# node named as the held predecessor: H-IU1's signature, fn32's shutdown.
# Beside them the module's unlprev_held_moved and unlprev_rebuilds.  With
# PUC_KNOBS dbg_unlprev_wait_delay_ms above PUC_HOLD_S, z's free sleeps,
# holding nothing, until the peer's last close has freed y, so every iteration
# meets the window.
#
# PUC_SHAPE=peerfree (tests/clmerge_window_node.sh CMW_SHAPE=peerfree) is
# fn32's own shape, which the default shape cannot make: a peer's last close
# frees nothing the peer did not unlink unless it holds the inode's EX (B4).
# The owner lists v, z and y on its bucket (y -> z -> v), the peer takes z's EX
# with a setattr through its open file and makes the last close, so its free of
# z waits for y's hold (P-UNLPREV-WAIT, held open by dbg_unlprev_wait_delay_ms);
# inside that wait the owner frees y off the head (PUC_PRED_CLOSE_MS after the
# peer's c<i>) and lists x ahead of z (PUC_HEAD_MS later), so the peer's retry
# holds a freed predecessor while z heads nothing.  z is a number of the
# owner's bucket (the owner reads its bucket from its own P82-ADD line first):
# the peer looks for an unstamped z in the bucket z's number names and skips
# the free when that bucket is empty.  After the peer's d<i> (its close
# returned) the owner waits out the peer's free, four tries at the delay each
# plus 5 s, before it frees x and v.  IRESULT grades
# H-IU1 by the unlprev_held_verify value PUC_KNOBS sets:
#   IVACUOUS              no P-UNLPREV-MOVED line and unlprev_held_moved 0
#   ICONTROL-SHOWS-CAUSE  verify=0: a MOVED line, a P53-IUNLINK-MISMATCH on an
#                         inode a MOVED line named (sig_iu1 > 0) and a node
#                         failure line
#   ICONTROL-NO-SHUTDOWN  verify=0: a MOVED line and no such shutdown
#   IPASS                 verify=1: a MOVED line, a P-UNLPREV-REBUILD line, no
#                         P53-IUNLINK-MISMATCH on either node, no node failure
#                         in either capture, cold audit CLEAN errors=0
#   IFAIL                 verify=1: a MOVED line and any of those missing
#   INOARM                PUC_KNOBS does not set unlprev_held_verify
#
# THE LAST FREES RUN AFTER THE WORKLOAD.  The owner frees y<i> after the peer's
# last close, and a free that defers runs from the reaper MXFS_REAP_FIRST_MS
# (5 s) after it was queued, every MXFS_REAP_RETRY_MS (30 s) after that: hu3f1
# shut down 4.8 s after the capture that graded it.  So the lap settles
# PUC_SETTLE_S (default 7: the 5 s first reap, 2 s for the free and its log
# line) before the first capture, and grades from a second capture of the same
# streams taken after the cold audit, whose unmount runs whatever frees remain.
# A reproduction only the second capture shows is graded REPRODUCED (late=1)
# with no image, since the audit has replayed the platter by then; a second
# capture that lost the lap's mark grades FAIL, never PASS.
#
# Budgets (derived): prep and the cold audit are run.sh rows under their own
# manifest budgets (run.sh flips an overrun to FAIL itself, so no outer
# timeout).  An owner iteration is two 4 KiB creates, at most 5 s waiting for
# the peer's open, two removes and a close, PUC_SYNCS cache drops 0.3 s apart,
# padded to PUC_HOLD_S: the workload is bounded by ITERS x (PUC_HOLD_S + 5 +
# PUC_SYNCS x 0.3 + 2) + 60 s (30 iterations at the defaults: 390 s).  The
# unmount of a node whose filesystem shut down is bounded at 60 s, the LUN
# snapshot by tools/lun_pool.sh, and the image's chk_mxfs read at 10 s
# (measured 0.19 s on a kept 20 GiB pool image holding 5254 inodes); the
# stream copy at 120 s per node.  chk_mxfs reads an image whose journal a
# shut-down node left unreplayed as a checkpoint, never a verdict (it says so
# and exits 8); the chain it shows is still the platter's, and the cold audit
# that follows replays and grades.
#
# The peerfree workload's bound per iteration: the 4 KiB creates and their
# stats 2 s, the peer's open 5 s, three removes and r<i> 1 s, the peer's c<i>
# 5 s, PUC_PRED_CLOSE_MS and the close of y 1 s, PUC_HEAD_MS and the remove of
# x 1 s, the peer's d<i> 5 s, the close wait above (the peer's free of z runs
# when its last reference drops, which can follow the close), the closes of x
# and v 2 s, PUC_SYNCS cache drops 0.3 s apart and the markers' removal 1 s,
# padded to PUC_HOLD_S; once per lap the owner's bucket calibration 2 s and
# the search for a z of its bucket, at most 130 creates and renames, 6 s; plus
# 60 s, plus one dead window doubled (124 s) for the iteration whose peer shut
# down: the owner's free of x then waits for the dead peer's EX on z, which
# only its recovery releases.
#
# Usage: tests/peer_open_unlinked_chain.sh <label> [iters=30] [config=2/net/mesh/direct] [group=g2c]
# Env:   PUC_HOLD_S (default 3), PUC_SYNCS (default 3), PUC_INSTR (default 0),
#        PUC_KNOBS (default none), PUC_SETTLE_S (default 7),
#        PUC_CLOSE_DROPS (default 0), PUC_RESET_AFTER (names of PUC_KNOBS
#        knobs set back to 0 when the workload ends, before the settle),
#        PUC_SHAPE (ownerfree, the default, or peerfree),
#        PUC_PRED_CLOSE_MS and PUC_HEAD_MS (peerfree; default 700 each)
# Exit 0 PASS, 1 REPRODUCED or FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}; ITERS=${2:-30}
CONFIG=${3:-2/net/mesh/direct}; GROUP=${4:-g2c}
HOLD=${PUC_HOLD_S:-3}; SYNCS=${PUC_SYNCS:-3}; INSTR=${PUC_INSTR:-0}; KNOBS=${PUC_KNOBS:-}
SETTLE=${PUC_SETTLE_S:-7}; CDROPS=${PUC_CLOSE_DROPS:-0}
SHAPE=${PUC_SHAPE:-ownerfree}; PCMS=${PUC_PRED_CLOSE_MS:-700}; HDMS=${PUC_HEAD_MS:-700}
for v in "$ITERS" "$HOLD" "$SYNCS" "$SETTLE" "$CDROPS" "$PCMS" "$HDMS"; do
    case "$v" in ''|*[!0-9]*) echo "iters, PUC_HOLD_S, PUC_SYNCS, PUC_SETTLE_S, PUC_CLOSE_DROPS, PUC_PRED_CLOSE_MS and PUC_HEAD_MS must be whole numbers"; exit 2 ;; esac
done
case "$SHAPE" in ownerfree|peerfree) ;; *) echo "PUC_SHAPE must be ownerfree or peerfree"; exit 2 ;; esac
[ "$SHAPE" = peerfree ] && [ "$CDROPS" -gt 0 ] && { echo "PUC_CLOSE_DROPS belongs to the ownerfree shape"; exit 2; }
# the module's own counts of the H-U1, H-U3, H-U4, H-U5, H-U6 and H-U7 events, zeroed after the prep
CNT="unlprev_notenure unlprev_waits nextwr_stale iunl_owed_release kept_next_stale freshsrc_iunl_stale freshsrc_iunl_overlaid b6_release_dirty b6_release_drained b6_release_kept unlprev_absent unlprev_pinned unlprev_rele_deferred unlprev_rele_inline_last unlprev_rele_deferred_last reload_next_stale reload_next_refreshed unlprev_held_moved unlprev_rebuilds"
case "$INSTR" in 0|1) ;; *) echo "PUC_INSTR must be 0 or 1"; exit 2 ;; esac
for kv in $KNOBS; do
    [[ "$kv" =~ ^[a-z0-9_]+=[0-9]+$ ]] || { echo "PUC_KNOBS words must be name=number, got '$kv'"; exit 2; }
done
# H-IU1's arm and the predecessor-wait test delay, as PUC_KNOBS sets them; the
# peerfree owner's wait for the peer's close covers four tries at the delay
UVERIFY="?"; UDELAY=0
for kv in $KNOBS; do
    case "$kv" in
        unlprev_held_verify=*) UVERIFY=${kv#*=} ;;
        dbg_unlprev_wait_delay_ms=*) UDELAY=${kv#*=} ;;
    esac
done
CWS=$(( (4 * UDELAY + 999) / 1000 + 5 ))
RESET_AFTER=${PUC_RESET_AFTER:-}
for k in $RESET_AFTER; do
    case " $KNOBS" in *" $k="*) ;; *) echo "PUC_RESET_AFTER names '$k', which PUC_KNOBS does not set"; exit 2 ;; esac
done
cd "$(dirname "$0")/.." || exit 2
TREE=/src/$(basename "$PWD")
SSH=tools/mxfs_sshpass.sh
read -r A B rest <<< "$(tools/mxfs_lab.sh group "$GROUP")"
[ -n "${A:-}" ] && [ -n "${B:-}" ] || { echo "RESULT: ABORT label=$LABEL -- group $GROUP has no two nodes"; exit 2; }
# run.sh holds the nodes only while it runs; between its calls the workload
# below is invisible to tools/vm_pool.sh, whose idle sweep would shut them off
. tests/lib/runlock.sh
vmhold_take "peer_open_unlinked_chain $LABEL" "$A" "$B" \
    || { echo "RESULT: ABORT label=$LABEL -- could not hold $A $B"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_peer_open_unlinked_$LABEL
mkdir -p "$OUT"
MARK="PEER-OPEN-UNLINKED-$LABEL-$$"
P=/sys/module/mxfs/parameters
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
echo "=== peer_open_unlinked_chain label=$LABEL shape=$SHAPE instr=$INSTR knobs='$KNOBS' hold_s=$HOLD syncs=$SYNCS close_drops=$CDROPS pred_close_ms=$PCMS head_ms=$HDMS close_wait_s=$CWS iters=$ITERS $CONFIG $GROUP [$A $B] build=$(modinfo -F srcversion mxfs.ko) tree=$TREE out=$OUT $(date -u +%FT%TZ) ==="

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 \
    || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }
want=$(modinfo -F srcversion mxfs.ko)
declare -A dev=()
for n in $A $B; do
    sv=$(rs 20 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$sv" = "$want" ] || { echo "RESULT: ABORT label=$LABEL -- $n runs '$sv', not the tree build $want evidence=$OUT"; exit 2; }
    got=$(rs 20 "$n" "echo $INSTR > $P/instr; echo $MARK > /dev/kmsg; cat $P/instr" | tail -1)
    [ "$got" = "$INSTR" ] || { echo "RESULT: ABORT label=$LABEL -- $n's instr read '$got', not $INSTR evidence=$OUT"; exit 2; }
    for kv in $KNOBS; do
        k=${kv%%=*}; v=${kv#*=}
        got=$(rs 20 "$n" "echo $v > $P/$k; cat $P/$k" | tail -1)
        [ "$got" = "$v" ] || { echo "RESULT: ABORT label=$LABEL -- $n's $k read '$got', not $v evidence=$OUT"; exit 2; }
    done
    # a counter this build lacks reads empty and is reported absent; one it has
    # must read 0 after the write that resets it
    got=$(rs 20 "$n" "cd $P && for c in $CNT; do [ -e \$c ] && echo 0 > \$c; printf '%s=%s ' \$c \"\$(cat \$c 2>/dev/null)\"; done; echo" | tail -1)
    for kv in $got; do
        case "$kv" in *=|*=0) ;; *) echo "RESULT: ABORT label=$LABEL -- $n's counter $kv did not reset to 0 evidence=$OUT"; exit 2 ;; esac
    done
    # the device the prep mounted, for the remount before a reproduction's audit
    dev[$n]=$(rs 20 "$n" "awk '\$2 == \"/mnt/shared\" && \$3 == \"mxfs\" {print \$1}' /proc/mounts" | tail -1)
    [ -n "${dev[$n]}" ] || { echo "RESULT: ABORT label=$LABEL -- $n has no mxfs mount at /mnt/shared after the prep evidence=$OUT"; exit 2; }
done
D=/mnt/shared/puc.$LABEL
rs 30 "$A" "mkdir -p $D && sync && echo ok" | grep -q ok || { echo "RESULT: ABORT label=$LABEL stage=mkdir evidence=$OUT"; exit 2; }

if [ "$SHAPE" = peerfree ]; then
    # the peerfree bound (derived above the usage line)
    it=$((2 + 5 + 1 + 5 + (PCMS + 999) / 1000 + 1 + (HDMS + 999) / 1000 + 1 + 5 + CWS + 2 + (SYNCS * 300 + 999) / 1000 + 1))
    [ "$it" -lt "$HOLD" ] && it=$HOLD
    WL=$((ITERS * it + 2 + 6 + 60 + 124))
else
    WL=$((ITERS * (HOLD + 5 + (SYNCS * 300 + 999) / 1000 + 2) + 60))
    # the close drops run CDROPS x 50 ms and the close waits for them; +1 s each
    # for a free a test knob holds while they run
    [ "$CDROPS" -gt 0 ] && WL=$((WL + ITERS * ((CDROPS * 50 + 999) / 1000 + 1)))
fi
CMW="CMW_SHAPE=$SHAPE CMW_PRED_CLOSE_MS=$PCMS CMW_HEAD_MS=$HDMS CMW_CLOSE_WAIT_S=$CWS"
echo "workload bound ${WL}s"
timeout $((WL + 10)) "$SSH" "$B" "$CMW bash $TREE/tests/clmerge_window_node.sh peer $D $HOLD" < /dev/null > "$OUT/${B}_peer.log" 2>&1 & pp=$!
timeout "$WL" "$SSH" "$A" "$CMW CMW_CLOSE_DROPS=$CDROPS bash $TREE/tests/clmerge_window_node.sh owner $D $ITERS $HOLD $SYNCS" < /dev/null > "$OUT/${A}_owner.log" 2>&1
orc=$?
# the owner's 'done' ends the peer; an owner whose filesystem shut down prints
# its tally without having made it, so both nodes make it here (touch is
# idempotent, and a peer whose own filesystem shut down leaves on its own)
for n in $A $B; do rs 20 "$n" "touch $D/done" > /dev/null; done
wait $pp; prc=$?
otail=$(grep -a '^owner done ' "$OUT/${A}_owner.log" | tail -1)
ok=$(printf '%s\n' "$otail" | grep -o ' ok=[0-9]*' | cut -d= -f2)
echo "owner rc=$orc (${otail:-no tally: $(tail -1 "$OUT/${A}_owner.log")}) peer rc=$prc ($(tail -1 "$OUT/${B}_peer.log"))"
# An owner that overran its bound is a hang (hu4df1: a nested inactivation and
# a create deadlocked on one AGI), or a pace failure: either way the blocked
# tasks' stacks are the evidence, read from /proc/<pid>/stat and stack, and
# nothing that would block on a wedged mount (the unmount, the remount, the
# cold audit) is run after it.
hung=0
if [ "$orc" = 124 ]; then
    hung=1
    for n in $A $B; do
        rs 60 "$n" "for s in /proc/[0-9]*/stat; do read -r pid comm st rest < \$s 2>/dev/null || continue; [ \"\$st\" = D ] || continue; echo \"== \$pid \$comm\"; cat /proc/\$pid/stack 2>/dev/null; done" > "$OUT/${n}_dstacks.txt"
        echo "$n blocked tasks: $(grep -c '^== ' "$OUT/${n}_dstacks.txt") ($OUT/${n}_dstacks.txt)"
        grep -a '^== ' "$OUT/${n}_dstacks.txt" | head -6
    done
fi
for n in $A $B; do
    rs 20 "$n" "echo 0 > $P/instr; cat $P/instr" > "$OUT/${n}_instr_reset.txt"
    # PUC_RESET_AFTER: knobs of PUC_KNOBS (test delays) set back to 0 here, so
    # the settle's frees and the cold audit's unmount run without them
    for k in $RESET_AFTER; do
        echo "$n $k reset after the workload: $(rs 20 "$n" "echo 0 > $P/$k; cat $P/$k" | tail -1)"
    done
done
# the last frees (see THE LAST FREES RUN AFTER THE WORKLOAD above), then the
# counters, before the cold audit unloads the module
sleep "$SETTLE"
declare -A cnt=()
for n in $A $B; do
    cnt[$n]=$(rs 20 "$n" "cd $P && for c in $CNT; do printf '%s=%s ' \$c \"\$(cat \$c 2>/dev/null || echo ?)\"; done; echo" | tail -1)
    echo "${cnt[$n]}" > "$OUT/${n}_counters.txt"
    echo "$n counters: ${cnt[$n]}"
done
# a counter of either node, summed; '?' when a node's read failed
csum() {
    local c=$1 s=0 n v
    for n in $A $B; do
        v=$(printf '%s\n' "${cnt[$n]}" | tr ' ' '\n' | sed -n "s/^$c=//p")
        case "$v" in ''|*[!0-9]*) echo "?"; return ;; esac
        s=$((s + v))
    done
    echo "$s"
}

# Each node's whole kernel log after the mark: the prep starts `dmesg --follow`
# into /root/dmesg.stream on every node and the next lap's prep replaces it.
declare -A nfail=()
tot_np=0; tot_br=0; tot_ie=0; tot_st0=0; tot_st1=0; tot_sig=0; HU3=""; HU4=""; tot_lf=0; HU5=""; tot_g6=0; HU1=""
tot_cr3=0; tot_bls=0; tot_rlw=0; tot_n0=0; tot_n1=0; tot_sn=0; HU7=""
tot_iu1sig=0; HIU1=""; tot_iu1m=0; tot_iu1f=0; tot_iu1r=0; tot_p53=0
for n in $A $B; do
    timeout 120 "$SSH" "$n" "gzip -c /root/dmesg.stream" < /dev/null 2>/dev/null > "$OUT/${n}_dmesg_stream.gz"
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" > "$OUT/${n}_lap.txt"
    echo "$n kernel log: $OUT/${n}_dmesg_stream.gz marks=$(grep -acF -- "$MARK" "$OUT/${n}_lap.txt") lines_after_mark=$(wc -l < "$OUT/${n}_lap.txt")"
    grep -a 'Shutting down filesystem\|P-WITHDRAW\|P131-SELF-FENCE\|P-INODE-WEDGE \|P-SESSION-POISON\|BUG:\|Oops\|blocked for more than' "$OUT/${n}_lap.txt" > "$OUT/${n}_failures.txt"
    grep -a 'P-UNLREM-\|P-UNLPRE-\|xfs_ifree returned error\|P83-UNL-RELOAD \|P84-UNL-RELOAD' "$OUT/${n}_lap.txt" > "$OUT/${n}_unlinked.txt"
    grep -a 'P82-ADD \|P82-REM \|P83-UNL-REMCHK \|P140-RECLAIM-COMMIT ' "$OUT/${n}_lap.txt" > "$OUT/${n}_chain.txt"
    np=$(grep -ac 'P-UNLREM-NOPREV ' "$OUT/${n}_unlinked.txt"); br=$(grep -ac 'P-UNLREM-BACKREF ' "$OUT/${n}_unlinked.txt")
    ie=$(grep -ac 'xfs_ifree returned error' "$OUT/${n}_unlinked.txt"); sds=$(wc -l < "$OUT/${n}_failures.txt")
    echo "$n noprev=$np backref=$br ifree_error=$ie failure_lines=$sds unlinked_lines=$(wc -l < "$OUT/${n}_unlinked.txt") chain_lines=$(wc -l < "$OUT/${n}_chain.txt") remchk_stale=$(grep -ac 'P83-UNL-REMCHK .* STALE=1 ' "$OUT/${n}_chain.txt")"
    grep -a 'P-UNLREM-NOPREV \|P-UNLREM-BACKREF \|xfs_ifree returned error' "$OUT/${n}_unlinked.txt" | head -4 | cut -c1-300
    head -3 "$OUT/${n}_failures.txt" | cut -c1-300
    grep -a 'P-FRESHSRC-IUNL-STALE \|P53-IUNLINK-MISMATCH \|xfs_ifree returned error' "$OUT/${n}_lap.txt" > "$OUT/${n}_hu3.txt"
    p53=$(grep -ac 'P53-IUNLINK-MISMATCH ' "$OUT/${n}_hu3.txt"); p34d=$(grep -ac 'P34D-RELOAD-FRESHSRC ' "$OUT/${n}_lap.txt")
    st0=$(grep -ac 'P-FRESHSRC-IUNL-STALE .* grafted=0 ' "$OUT/${n}_hu3.txt"); st1=$(grep -ac 'P-FRESHSRC-IUNL-STALE .* grafted=1 ' "$OUT/${n}_hu3.txt")
    # a mismatch on an inode an ungrafted stale adopt named earlier, before the
    # node's first failed free: H-U3's signature
    sig=$(python3 - "$OUT/${n}_hu3.txt" <<'PY'
import re, sys
stale = set(); sig = 0
for line in open(sys.argv[1], errors="replace"):
    if "xfs_ifree returned error" in line:
        break
    m = re.search(r"P-FRESHSRC-IUNL-STALE ino=(\d+) .* grafted=0 ", line)
    if m:
        stale.add(int(m.group(1)))
        continue
    m = re.search(r"P53-IUNLINK-MISMATCH ino=0x([0-9a-f]+) ", line)
    if m and int(m.group(1), 16) in stale:
        sig += 1
print(sig)
PY
)
    echo "$n hu3: p53=$p53 p34d=$p34d stale_ungrafted=$st0 stale_grafted=$st1 sig_pre=$sig"
    HU3="$HU3 ${n}_p53=$p53 ${n}_stale0=$st0 ${n}_stale1=$st1 ${n}_sig=$sig"
    grep -a 'P-UNLPREV-\|P-NEXTWR-STALE \|P-IUNL-OWED-AT-RELEASE \|P-KEPT-NEXT-STALE \|P-IUNL-LAND-FAIL ' "$OUT/${n}_lap.txt" > "$OUT/${n}_hu4.txt"
    h4nt=$(grep -ac 'P-UNLPREV-NOTENURE ' "$OUT/${n}_hu4.txt"); h4nw=$(grep -ac 'P-NEXTWR-STALE ' "$OUT/${n}_hu4.txt")
    h4o0=$(grep -ac 'P-IUNL-OWED-AT-RELEASE .* landed=0 ' "$OUT/${n}_hu4.txt"); h4o1=$(grep -ac 'P-IUNL-OWED-AT-RELEASE .* landed=1 ' "$OUT/${n}_hu4.txt")
    h4k0=$(grep -ac 'P-KEPT-NEXT-STALE .* refreshed=0 ' "$OUT/${n}_hu4.txt"); h4k1=$(grep -ac 'P-KEPT-NEXT-STALE .* refreshed=1 ' "$OUT/${n}_hu4.txt")
    h4w=$(grep -ac 'P-UNLPREV-WAIT ' "$OUT/${n}_hu4.txt"); h4d=$(grep -ac 'P-UNLPREV-DEFER ' "$OUT/${n}_hu4.txt")
    h4lf=$(grep -ac 'P-IUNL-LAND-FAIL ' "$OUT/${n}_hu4.txt")
    echo "$n hu4 lines: notenure=$h4nt nextwr_stale=$h4nw owed_landed0=$h4o0 owed_landed1=$h4o1 kept_stale_r0=$h4k0 kept_stale_r1=$h4k1 waits=$h4w defers=$h4d land_fail=$h4lf"
    grep -a 'P-UNLPREV-NOTENURE \|P-NEXTWR-STALE \|P-IUNL-LAND-FAIL \|P-UNLPREV-DEFER ' "$OUT/${n}_hu4.txt" | head -4 | cut -c1-300
    HU4="$HU4 ${n}_h4=$h4nt/$h4nw/$h4o0/$h4o1/$h4k0/$h4k1/$h4w/$h4d/$h4lf"
    tot_lf=$((tot_lf + h4lf))
    grep -a 'P-B6-RELEASE-DIRTY \|P17B-EPOCH-GHOST-SKIP ' "$OUT/${n}_lap.txt" > "$OUT/${n}_hu5.txt"
    h5r=$(grep -ac 'P-B6-RELEASE-DIRTY .* drain=0 ' "$OUT/${n}_hu5.txt"); h5d=$(grep -ac 'P-B6-RELEASE-DIRTY .* drained=1 ' "$OUT/${n}_hu5.txt")
    h5k=$(grep -ac 'P-B6-RELEASE-DIRTY .* kept=1 ' "$OUT/${n}_hu5.txt"); h5g=$(grep -ac 'P17B-EPOCH-GHOST-SKIP ' "$OUT/${n}_hu5.txt")
    # a ghost skip of an inode whose deferred release left its committed
    # state behind: H-U5's signature
    g6=$(python3 - "$OUT/${n}_hu5.txt" <<'PY'
import re, sys
left = set(); n = 0
for line in open(sys.argv[1], errors="replace"):
    m = re.search(r"P-B6-RELEASE-DIRTY ino=(\d+) .* drained=0 ", line)
    if m:
        left.add(m.group(1))
        continue
    m = re.search(r"P17B-EPOCH-GHOST-SKIP ino=(\d+) ", line)
    if m and m.group(1) in left:
        n += 1
print(n)
PY
)
    echo "$n hu5 lines: b6_raw=$h5r b6_drained=$h5d b6_kept=$h5k ghost=$h5g ghost_b6=$g6"
    grep -a 'P-B6-RELEASE-DIRTY ' "$OUT/${n}_hu5.txt" | head -2 | cut -c1-300
    HU5="$HU5 ${n}_h5=$h5r/$h5d/$h5k/$h5g/$g6"
    tot_g6=$((tot_g6 + g6))
    h1a0=$(grep -ac 'P-UNLPREV-ABSENT .* pin=0 ' "$OUT/${n}_lap.txt"); h1a1=$(grep -ac 'P-UNLPREV-ABSENT .* pin=1 ' "$OUT/${n}_lap.txt")
    echo "$n hu1 lines: absent_pin0=$h1a0 absent_pin1=$h1a1"
    grep -a 'P-UNLPREV-ABSENT ' "$OUT/${n}_lap.txt" | head -2 | cut -c1-300
    HU1="$HU1 ${n}_h1=$h1a0/$h1a1"
    # H-U6's signature: a create spinning on a number whose inactivation is
    # still running, and the AGI buffer it holds stuck behind a nested free
    cr3=$(grep -ac 'P-CR3-NEEDINACT ' "$OUT/${n}_lap.txt"); bls=$(grep -ac 'P-BUFLOCK-STUCK ' "$OUT/${n}_lap.txt")
    rl=$(grep -ac 'P-UNLPREV-RELE-LAST ' "$OUT/${n}_lap.txt"); rlw=$(grep -ac 'P-UNLPREV-RELE-LAST .* comm=kworker' "$OUT/${n}_lap.txt")
    echo "$n hu6 lines: cr3_needinact=$cr3 buflock_stuck=$bls rele_last=$rl rele_last_worker=$rlw"
    grep -a -m2 'P-CR3-NEEDINACT \|P-BUFLOCK-STUCK ' "$OUT/${n}_lap.txt" | cut -c1-300
    grep -a -m2 'P-UNLPREV-RELE-LAST ' "$OUT/${n}_lap.txt" | cut -c1-300
    tot_cr3=$((tot_cr3 + cr3)); tot_bls=$((tot_bls + bls)); tot_rlw=$((tot_rlw + rlw))
    # H-U7: a kept reload whose dinode named another next pointer, and a
    # BACKREF on that inode with the in-core next the unrefreshed line kept
    grep -a 'P-RELOAD-NEXT-STALE \|P-UNLREM-BACKREF ' "$OUT/${n}_lap.txt" > "$OUT/${n}_hu7.txt"
    n0=$(grep -ac 'P-RELOAD-NEXT-STALE .* refreshed=0 ' "$OUT/${n}_hu7.txt"); n1=$(grep -ac 'P-RELOAD-NEXT-STALE .* refreshed=1 ' "$OUT/${n}_hu7.txt")
    sn=$(python3 - "$OUT/${n}_hu7.txt" <<'PY'
import re, sys
kept = {}; sig = 0
for line in open(sys.argv[1], errors="replace"):
    m = re.search(r"P-RELOAD-NEXT-STALE ino=(\d+) incore_next=(0x[0-9a-f]+) .* refreshed=0 ", line)
    if m:
        kept[m.group(1)] = m.group(2)
        continue
    m = re.search(r"P-UNLREM-BACKREF ino=(\d+) .* next=(0x[0-9a-f]+) ", line)
    if m and kept.get(m.group(1)) == m.group(2):
        sig += 1
print(sig)
PY
)
    echo "$n hu7 lines: next_stale_r0=$n0 next_stale_r1=$n1 sig_next=$sn"
    grep -a -m2 'P-RELOAD-NEXT-STALE ' "$OUT/${n}_hu7.txt" | cut -c1-300
    HU7="$HU7 ${n}_h7=$n0/$n1/$sn"
    tot_n0=$((tot_n0 + n0)); tot_n1=$((tot_n1 + n1)); tot_sn=$((tot_sn + sn))
    # H-IU1: moved / moved_freed / rebuilds / sig_iu1 (see the header)
    iu1=$(python3 - "$OUT/${n}_lap.txt" <<'PY'
import re, sys
moved = set(); m_lines = m_freed = rebuild = sig = 0
for line in open(sys.argv[1], errors="replace"):
    m = re.search(r"P-UNLPREV-MOVED ino=\d+ agino=0x[0-9a-f]+ prev=(\d+) prev_mode=([0-7]+) ", line)
    if m:
        m_lines += 1
        if int(m.group(2), 8) == 0:
            m_freed += 1
        moved.add(int(m.group(1)))
        continue
    if "P-UNLPREV-REBUILD " in line:
        rebuild += 1
        continue
    m = re.search(r"P53-IUNLINK-MISMATCH ino=0x([0-9a-f]+) ", line)
    if m and int(m.group(1), 16) in moved:
        sig += 1
print("%d/%d/%d/%d" % (m_lines, m_freed, rebuild, sig))
PY
)
    echo "$n hiu1 lines: moved/moved_freed/rebuilds/sig_iu1=$iu1"
    grep -a -m2 'P-UNLPREV-MOVED \|P-UNLPREV-REBUILD ' "$OUT/${n}_lap.txt" | cut -c1-300
    HIU1="$HIU1 ${n}_iu1=$iu1"
    tot_iu1sig=$((tot_iu1sig + ${iu1##*/}))
    IFS=/ read -r i1m i1f i1r i1s <<< "$iu1"
    tot_iu1m=$((tot_iu1m + i1m)); tot_iu1f=$((tot_iu1f + i1f)); tot_iu1r=$((tot_iu1r + i1r))
    tot_p53=$((tot_p53 + p53))
    tot_st0=$((tot_st0 + st0)); tot_st1=$((tot_st1 + st1)); tot_sig=$((tot_sig + sig))
    tot_np=$((tot_np + np)); tot_br=$((tot_br + br)); tot_ie=$((tot_ie + ie))
    [ "$sds" = 0 ] || nfail[$n]=1
done
bad=${#nfail[@]}
hit=$((tot_np + tot_br + tot_ie + bad))
# what the second capture counts from when the audit replaced the stream
MARK2="PEER-OPEN-UNLINKED-$LABEL-$$-POSTCAPTURE"
for n in $A $B; do rs 20 "$n" "echo $MARK2 > /dev/kmsg" > /dev/null; done

# On a reproduction the platter is the evidence: unmount what will unmount
# (a shut-down mount writes nothing more), keep the LUN image before the cold
# audit or any later prep touches it, and read the image itself.
img=none; ichk=none
if [ "$hit" -gt 0 ] && [ "$hung" = 0 ]; then
    for n in $A $B; do
        echo "$n umount rc=$(rs 70 "$n" "timeout 60 umount /mnt/shared; echo \$?" | tail -1) mounted_after=$(rs 20 "$n" "grep -c ' /mnt/shared mxfs ' /proc/mounts" | tail -1)"
    done
    lun=$(tools/lun_pool.sh lookup --nodes "$A,$B" | sed -n 's/.* id=\([0-9]*\) .*/\1/p')
    if [ -n "$lun" ] && img=$(tools/lun_pool.sh snapshot "$lun" "$GROUP-puc-$LABEL"); then
        echo "image kept: $img"
        timeout 10 tools/chk_mxfs -v "$img" > "$OUT/chk_image.txt" 2>&1; crc=$?
        ichk="rc=$crc errors=$(grep -ac 'ERROR' "$OUT/chk_image.txt")"
        echo "image audit (tools/chk_mxfs -v on the kept image, before any replay): $ichk ($OUT/chk_image.txt)"
        grep -a 'ERROR' "$OUT/chk_image.txt" | head -8 | cut -c1-240
    else
        img=none; echo "image NOT kept: no pool LUN bound to [$A $B], or the snapshot was refused"
    fi
    # the cold audit grades what a mount replays the nodes' journals to; run.sh
    # refuses it while the nodes are unmounted, so mount them as the prep did
    for n in $A $B; do
        mrc=$(rs 110 "$n" "timeout 100 mount -t mxfs ${MXFS_MOUNT_OPTS:-} ${dev[$n]} /mnt/shared; echo \$?" | tail -1)
        echo "$n remount rc=$mrc mounted_after=$(rs 20 "$n" "grep -c ' /mnt/shared mxfs ' /proc/mounts" | tail -1)"
    done
fi

since=$(date -u +%FT%TZ)
# a hung lap's audit would block on the wedged mount; its cell then reads STALE
[ "$hung" = 1 ] || ./run.sh "$CONFIG" --group "$GROUP" chk_clean > "$OUT/chk.log" 2>&1
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

# The second capture (THE LAST FREES RUN AFTER THE WORKLOAD above): each node's
# stream again from the lap's mark, its counts against the first capture's; a
# stream the audit replaced has lost the mark, and then the kernel ring after
# MARK2, written just after the first capture, holds the window since.
FPAT='Shutting down filesystem\|P-WITHDRAW\|P131-SELF-FENCE\|P-INODE-WEDGE \|P-SESSION-POISON\|BUG:\|Oops\|blocked for more than'
UPAT='P-UNLREM-NOPREV \|P-UNLREM-BACKREF \|xfs_ifree returned error'
HPAT='P-UNLPREV-NOTENURE \|P-NEXTWR-STALE \|P-IUNL-LAND-FAIL '
late=0; POST=""
for n in $A $B; do
    timeout 120 "$SSH" "$n" "gzip -c /root/dmesg.stream" < /dev/null 2>/dev/null > "$OUT/${n}_dmesg_stream_post.gz"
    src=stream
    zcat "$OUT/${n}_dmesg_stream_post.gz" 2>/dev/null | sed -n "/$MARK/,\$p" > "$OUT/${n}_post.txt"
    if ! grep -qaF -- "$MARK" "$OUT/${n}_post.txt"; then
        src=ring
        rs 60 "$n" "dmesg" | sed -n "/$MARK2/,\$p" > "$OUT/${n}_post.txt"
        grep -qaF -- "$MARK2" "$OUT/${n}_post.txt" || src=missing
    fi
    # only what was logged after the first capture: the stream is append-only,
    # so its first lines from the mark are the first capture's
    case "$src" in
        stream) sed -n "$(( $(wc -l < "$OUT/${n}_lap.txt") + 1 )),\$p" "$OUT/${n}_post.txt" > "$OUT/${n}_post_new.txt" ;;
        ring) cp "$OUT/${n}_post.txt" "$OUT/${n}_post_new.txt" ;;
        *) : > "$OUT/${n}_post_new.txt" ;;
    esac
    pf=$(grep -ac "$FPAT" "$OUT/${n}_post_new.txt"); pu=$(grep -ac "$UPAT" "$OUT/${n}_post_new.txt")
    ph=$(grep -ac "$HPAT" "$OUT/${n}_post_new.txt")
    [ $((pf + pu)) -gt 0 ] && late=1
    tot_lf=$((tot_lf + $(grep -ac 'P-IUNL-LAND-FAIL ' "$OUT/${n}_post_new.txt")))
    tot_p53=$((tot_p53 + $(grep -ac 'P53-IUNLINK-MISMATCH ' "$OUT/${n}_post_new.txt")))
    echo "$n second capture: src=$src new_lines=$(wc -l < "$OUT/${n}_post_new.txt") failure_lines=$pf unlinked_failures=$pu hu4_lines=$ph ($OUT/${n}_post_new.txt)"
    grep -a "$FPAT\|$UPAT\|$HPAT" "$OUT/${n}_post_new.txt" | head -4 | cut -c1-300
    POST="$POST ${n}_post=$src/$pf/$pu/$ph"
done

REP="instr=$INSTR knobs=${KNOBS// /,} hold_s=$HOLD syncs=$SYNCS close_drops=$CDROPS iters=$ITERS owner_rc=$orc peer_rc=$prc ok=${ok:-?} noprev=$tot_np backref=$tot_br ifree_error=$tot_ie node_failures=$bad late=$late notenure=$(csum unlprev_notenure) nextwr_stale=$(csum nextwr_stale) waits=$(csum unlprev_waits) owed=$(csum iunl_owed_release) kept_stale=$(csum kept_next_stale) land_fail=$tot_lf b6_dirty=$(csum b6_release_dirty) b6_drained=$(csum b6_release_drained) b6_kept=$(csum b6_release_kept) ghost_b6=$tot_g6 unlprev_absent=$(csum unlprev_absent) unlprev_pinned=$(csum unlprev_pinned) hung=$hung rele_deferred=$(csum unlprev_rele_deferred) rele_inline_last=$(csum unlprev_rele_inline_last) rele_deferred_last=$(csum unlprev_rele_deferred_last) rele_last_worker=$tot_rlw cr3_needinact=$tot_cr3 buflock_stuck=$tot_bls stale_ungrafted=$tot_st0 stale_grafted=$tot_st1 sig_pre=$tot_sig next_stale=$(csum reload_next_stale) next_refreshed=$(csum reload_next_refreshed) next_stale_r0=$tot_n0 next_stale_r1=$tot_n1 sig_next=$tot_sn held_moved=$(csum unlprev_held_moved) rebuilds=$(csum unlprev_rebuilds) sig_iu1=$tot_iu1sig$HU3$HU4$HU5$HU1$HU7$HIU1$POST image=$img image_audit=$ichk audit=$audit"
# H-IU1's grade (IRESULT in the header); the counter outranks a line the log
# dropped
hm=$(csum unlprev_held_moved)
moved=$tot_iu1m
case "$hm" in ''|*[!0-9]*) ;; *) [ "$hm" -gt "$moved" ] && moved=$hm ;; esac
case "$audit" in CLEAN*errors=0) iaok=1 ;; *) iaok=0 ;; esac
if [ "$UVERIFY" = "?" ]; then ig=INOARM
elif [ "$moved" = 0 ]; then ig=IVACUOUS
elif [ "$UVERIFY" = 0 ]; then
    if [ "$tot_iu1sig" -gt 0 ] && [ $((bad + late)) -gt 0 ]; then ig=ICONTROL-SHOWS-CAUSE; else ig=ICONTROL-NO-SHUTDOWN; fi
elif [ "$tot_iu1r" -gt 0 ] && [ "$tot_p53" = 0 ] && [ "$bad" = 0 ] && [ "$late" = 0 ] && [ "$hung" = 0 ] && [ "$iaok" = 1 ]; then ig=IPASS
else ig=IFAIL
fi
echo "IRESULT: $ig label=$LABEL shape=$SHAPE unlprev_held_verify=$UVERIFY delay_ms=$UDELAY held_moved=$hm moved_lines=$tot_iu1m moved_freed=$tot_iu1f rebuild_lines=$tot_iu1r sig_iu1=$tot_iu1sig p53=$tot_p53 node_failures=$bad late=$late hung=$hung ok=${ok:-?} audit=$audit evidence=$OUT"
[ "$hung" = 1 ] && { echo "RESULT: REPRODUCED peer_open_unlinked_chain label=$LABEL $REP -- the workload overran its bound (a hang): the nodes are left as they are, blocked tasks in <node>_dstacks.txt evidence=$OUT"; exit 1; }
[ "$hit" -gt 0 ] && { echo "RESULT: REPRODUCED peer_open_unlinked_chain label=$LABEL $REP -- an unlinked-list remove failed or a node failed evidence=$OUT"; exit 1; }
[ "$late" = 1 ] && { echo "RESULT: REPRODUCED peer_open_unlinked_chain label=$LABEL $REP -- an unlinked-list remove failed or a node failed after the first capture (late=1; no image: the audit has replayed the platter) evidence=$OUT"; exit 1; }
case "$POST" in *=missing/*) echo "RESULT: FAIL peer_open_unlinked_chain label=$LABEL $REP -- a node's second capture lost the lap: what ran after the first capture is unseen evidence=$OUT"; exit 1 ;; esac
[ "${ok:-0}" -gt 0 ] || { echo "RESULT: VACUOUS peer_open_unlinked_chain label=$LABEL $REP -- no iteration ran with the peer holding y evidence=$OUT"; exit 3; }
case "$audit" in CLEAN*errors=0) aok=1 ;; *) aok=0 ;; esac
if [ "$aok" = 1 ] && [ "$orc" = 0 ] && [ "$prc" = 0 ] && [ "$ok" = "$ITERS" ]; then
    echo "RESULT: PASS peer_open_unlinked_chain label=$LABEL $REP evidence=$OUT"; exit 0
fi
echo "RESULT: FAIL peer_open_unlinked_chain label=$LABEL $REP -- no remove failed and no node failed, but the workload or the cold audit did evidence=$OUT"; exit 1
