#!/bin/bash
# probe_level_lines.sh — do the lines a healthy cluster prints for designed
# paths reach the kernel log at debug level, and never at warning level?
#
# Three lines read to an operator as faults on a working filesystem until
# 0.90.108 moved them to dynamic-debug probes:
#   P-UNPUB-OWNED-META   a new file about to log metadata outside its inode
#                        core takes a real lock grant first (xfs_mxfs_ilock.c)
#   P-STALE-FIN          a freed AG btree buffer with a second, transient
#                        reference at its stale completion (xfs_buf_item.c)
#   P83-UNL-RELOAD /     upstream XFS's "Found unrecovered unlinked inode ...
#   P83-UNL-BUCKET-RELOAD  Initiating recovery" on a cluster mount, where the
#                        inode is a peer's in-flight unlink (xfs_inode.c)
#
# The rig loads the module with every probe on, so a probe's line does reach
# the log here, and `dmesg -x` names the level each record was printed at.
# A tag whose lines are all at debug passes; a tag with any line at another
# level fails; a tag with no line at all was not reached and is reported
# UNREACHED, which is not a pass.  Any "Found unrecovered unlinked inode" on
# a cluster mount fails.
#
# The workloads, on two nodes of one 2/net/mesh/direct cluster:
#   1. tests/agmeta_stale_leak_2node.sh: A fallocates 8 MiB, punches every
#      other block until both free-space btrees split, removes the file (the
#      split blocks are freed: the stale completion path), and B allocates in
#      that AG twice.  The growing file passes its in-core extent capacity
#      while unpublished, which is P-UNPUB-OWNED-META's path.
#   2. held-open unlinks: B opens and unlinks files in a shared directory and
#      holds them open while A creates and unlinks files in the same
#      directory, so the AGI unlinked lists A walks hold B's in-flight
#      unlinked inodes.
#   3. the insert side (xfs_iunlink_reload_next, P83-UNL-RELOAD): a cluster
#      mount keeps each node's unlinks in the AGI bucket its slot names, so a
#      node meets an inode it does not cache at its own bucket's head when it
#      unlinked a file its peer still holds open and has since dropped that
#      inode from memory.  A makes 20 files, B opens and holds them, A unlinks
#      them (their frees wait for B's close), drops its caches, then creates
#      and unlinks 20 more in the same directory: the first of those unlinks
#      inserts ahead of a head A must read from the platter.
#
# derived time budget: prep 2 nodes measured ~90 s (bounded 300 s); lap 1
# healthy wall ~10 s (bounded 120 s by its own harness); lap 2: 400 creates and
# unlinks per node at ~5 ms each = 2 s, holds 20 s, bounded 60 s; captures
# ~10 s; the handle wait adds 45 s and the hold 45 s; lap 3: 40 creates and
# unlinks plus two cache drops ~5 s and a 30 s hold.  Whole run about 270 s,
# bounded 550 s.
#
# Usage: tests/probe_level_lines.sh <label>   (NOPREP=1 reuses the mount)
#        MXFS_GROUP=<g> runs on that rig group (its own nodes and pool LUN,
#        beside other groups' runs) instead of test1,test2 under the whole-rig
#        lock.  PL_CONFIG=<config> (default 2/net/mesh/direct) preps another
#        two-node configuration: run.sh locks each configuration for one group
#        at a time, so a group running beside another on the same
#        configuration is refused.
set -u
LABEL=${1:?label}
PL_CONFIG=${PL_CONFIG:-2/net/mesh/direct}
cd "$(dirname "$0")/.." || exit 2
GROUPARG=()
if [ -n "${MXFS_GROUP:-}" ]; then
    GROUPARG=(--group "$MXFS_GROUP")
    MXFS_NODE_LIST=$(tools/mxfs_lab.sh group "$MXFS_GROUP" | tr -s ' \t' '\n' | grep . | head -2 | paste -sd,) \
        || { echo "RESULT: ABORT label=$LABEL stage=group (no group $MXFS_GROUP)"; exit 2; }
fi
export MXFS_NODE_LIST=${MXFS_NODE_LIST:-test1,test2}
A=${MXFS_NODE_LIST%%,*}
B=${MXFS_NODE_LIST##*,}
# run.sh holds the nodes only while it runs; between its calls the workloads
# below are invisible to tools/vm_pool.sh, whose idle sweep would shut them off
. tests/lib/runlock.sh
vmhold_take "probe_level_lines $LABEL" "$A" "$B" \
    || { echo "RESULT: ABORT label=$LABEL stage=vmhold (could not hold $A $B)"; exit 2; }
MNT=${MXFS_MNT:-/mnt/shared}
SSH=tools/mxfs_sshpass.sh
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_probelevel_$LABEL
mkdir -p "$OUT"
KF=/run/mxfs_probelevel.$LABEL
filt() { grep -av '^Unauthorized\|^Warning:\|^If you\|^$'; }
rs() { timeout "$1" $SSH "$2" "$3" 2>/dev/null | filt; }

SV=$(modinfo mxfs.ko | sed -n 's/^srcversion: *//p')
echo "=== probe_level_lines label=$LABEL sv=$SV config=$PL_CONFIG nodes=$A,$B $(date -u +%FT%TZ) ==="
s=$(date +%s)
if [ "${NOPREP:-0}" != 1 ]; then
    MXFS_FORCE_PREP=1 timeout 300 ./run.sh "$PL_CONFIG" "${GROUPARG[@]}" prep_cluster > "$OUT/prep.log" 2>&1
    prc=$?
    echo "STAGE prep rc=$prc wall=$(( $(date +%s) - s ))s"
    [ $prc != 0 ] && { echo "RESULT: ABORT label=$LABEL stage=prep rc=$prc"; tail -20 "$OUT/prep.log"; exit 2; }
fi
svs=$(for n in $A $B; do rs 20 "$n" "cat /sys/module/mxfs/srcversion"; done | sort -u | tr '\n' ' ')
echo "  INFO srcversion_on_nodes=$svs tree=$SV"
case " $svs " in *" $SV "*) ;; *) echo "RESULT: ABORT label=$LABEL stage=build nodes run a different build ($svs)"; exit 2;; esac

# each tag's call site as the loaded module registers it: a dynamic-debug
# site is a pr_debug; a tag missing from the table is printed some other way
for n in $A $B; do
    rs 20 "$n" "grep -E 'P-UNPUB-OWNED-META|P-STALE-FIN|P83-UNL-RELOAD|P83-UNL-BUCKET-RELOAD' /sys/kernel/debug/dynamic_debug/control" > "$OUT/dyndbg_$n.txt"
done

MARK="PROBELEVEL-MARK-$LABEL-$(date +%s)"
for n in $A $B; do
    rs 20 "$n" "rm -f $KF $KF.pid; nohup dmesg --follow -x < /dev/null > $KF 2>/dev/null & echo \$! > $KF.pid; sleep 1; echo $MARK > /dev/kmsg; echo started"
done
for n in $A $B; do
    c=$(rs 15 "$n" "grep -acF -- '$MARK' $KF" | tr -dc '0-9')
    [ "${c:-0}" -ge 1 ] || { echo "RESULT: ABORT label=$LABEL stage=follow node=$n (the follower does not carry the mark)"; exit 2; }
done

# Lap 1, LAPS1 times.  A second punch loop on A in the same directory (so the
# same AG) runs beside each collapse: its allocations look up the very
# free-space btree blocks the collapse frees, which is how a freed buffer
# can carry a second, transient reference at its stale completion.
l1=$(date +%s)
k=0
while [ "$k" -lt "${LAPS1:-3}" ]; do
    LD=$MNT/agleak_${LABEL}lap$k
    rs 20 "$A" "mkdir -p $LD; nohup sh -c 'end=\$((\$(date +%s) + 25)); j=0; while [ \$(date +%s) -lt \$end ]; do fallocate -l 4M $LD/g\$j 2>/dev/null || break; i=0; while [ \$i -lt 512 ]; do fallocate -p -o \$(( i * 8192 )) -l 4096 $LD/g\$j || break; i=\$((i+1)); done; rm -f $LD/g\$j; j=\$((j+1)); done; echo SIDE-DONE j=\$j' > /run/probelevel_side.out 2>&1 &" >/dev/null
    NOPREP=1 timeout 120 tests/agmeta_stale_leak_2node.sh "${LABEL}lap$k" > "$OUT/lap1_$k.log" 2>&1
    echo "STAGE lap1.$k rc=$? wall=$(( $(date +%s) - l1 ))s"
    sleep 26
    echo "  INFO side loop: $(rs 15 "$A" "cat /run/probelevel_side.out")"
    rs 20 "$A" "rm -rf $LD" >/dev/null
    k=$((k + 1))
done

l2=$(date +%s)
D=$MNT/probelevel_$LABEL
rs 20 "$A" "mkdir -p $D" >/dev/null
# B makes 400 files, writes each one's file handle where A can read it,
# unlinks them and holds them open; A then opens every handle.  On A each
# inode is read from disk with nlink 0 and no in-core unlinked list, and the
# export path reloads its AGI bucket (tests/handle_reopen.py).  bulkstat
# would reach the same reload, but MXFS serves no XFS ioctl except GOINGDOWN
# (xfs/xfs_stubs.c), so a file handle is the user-reachable way in.
# A's iget reads the inode cluster from the platter, and B's unlinks reach it
# only when B writes the inode cores back (its log worker and AIL push, ~30 s).
# Opened sooner, every handle reads nlink 1 and no reload runs (plv7: 400
# opens, both probes UNREACHED), so A waits HANDLE_WAIT_S while B still holds
# the files open.
HF=/src/mxfs/$OUT/handles.txt
HANDLE_WAIT_S=${HANDLE_WAIT_S:-45}
rs 20 "$B" "nohup python3 /src/mxfs/tests/handle_reopen.py make $D 400 $HF /run/probelevel_hold.pid $((HANDLE_WAIT_S + 40)) > /run/probelevel_hold.out 2>&1 &" >/dev/null
i=0
while [ "$i" -lt 30 ] && ! rs 15 "$B" "cat /run/probelevel_hold.out" | grep -q '^HANDLES '; do sleep 1; i=$((i + 1)); done
rs 60 "$A" "python3 -c '
import os
d = \"$D\"
for i in range(400):
    p = os.path.join(d, \"a%04d\" % i)
    fd = os.open(p, os.O_CREAT | os.O_WRONLY, 0o644)
    os.write(fd, b\"y\" * 512)
    os.close(fd)
    os.unlink(p)
print(\"A-DONE\")
'" > "$OUT/lap2_A.txt"
sleep "$HANDLE_WAIT_S"
rs 60 "$A" "python3 /src/mxfs/tests/handle_reopen.py open $MNT $HF 2>&1" > "$OUT/lap2_handles_A.txt"
rs 20 "$B" "cat /run/probelevel_hold.out; echo held_fds=\$(ls /proc/\$(cat /run/probelevel_hold.pid)/fd 2>/dev/null | wc -l)" > "$OUT/lap2_hold_B.txt"
echo "  INFO $(grep -a '^HANDLES' "$OUT/lap2_hold_B.txt") $(grep -a '^HANDLE-OPEN' "$OUT/lap2_handles_A.txt") $(grep -a '^held_fds' "$OUT/lap2_hold_B.txt")"
sleep 45
rs 20 "$A" "rmdir $D" >/dev/null
echo "STAGE lap2 a_done=$(grep -c A-DONE "$OUT/lap2_A.txt") wall=$(( $(date +%s) - l2 ))s"

l3=$(date +%s)
D3=$MNT/probelevel_${LABEL}_own
HOLD3_S=${HOLD3_S:-30}
rs 30 "$A" "mkdir -p $D3 && for i in \$(seq -w 0 19); do echo x > $D3/x\$i; done && sync && echo made" > "$OUT/lap3_make_A.txt"
rs 20 "$B" "nohup python3 -c '
import os, sys, time
d = sys.argv[1]
fds = [os.open(os.path.join(d, \"x%02d\" % i), os.O_RDONLY) for i in range(20)]
print(\"HELD\", len(fds), flush=True)
time.sleep(int(sys.argv[2]))
' $D3 $HOLD3_S > /run/probelevel_hold3.out 2>&1 &" >/dev/null
i=0
while [ "$i" -lt 30 ] && ! rs 15 "$B" "cat /run/probelevel_hold3.out" | grep -q '^HELD 20'; do sleep 1; i=$((i + 1)); done
rs 60 "$A" "for i in \$(seq -w 0 19); do rm -f $D3/x\$i; done; sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2; echo 3 > /proc/sys/vm/drop_caches; for i in \$(seq -w 0 19); do echo y > $D3/y\$i; rm -f $D3/y\$i; done; sync; echo A3-DONE" > "$OUT/lap3_A.txt"
rs 15 "$B" "cat /run/probelevel_hold3.out" > "$OUT/lap3_hold_B.txt"
echo "  INFO lap3 $(grep -a '^made' "$OUT/lap3_make_A.txt") $(grep -a '^HELD' "$OUT/lap3_hold_B.txt") $(grep -a '^A3-DONE' "$OUT/lap3_A.txt")"
sleep $((HOLD3_S + 5))
rs 20 "$A" "rmdir $D3" >/dev/null
echo "STAGE lap3 a_done=$(grep -c A3-DONE "$OUT/lap3_A.txt") wall=$(( $(date +%s) - l3 ))s"

for n in $A $B; do
    rs 15 "$n" "kill \$(cat $KF.pid) 2>/dev/null; rm -f $KF.pid" >/dev/null
    rs 90 "$n" "gzip -c $KF > /src/mxfs/$OUT/kmsg_$n.gz" >/dev/null
    rs 15 "$n" "rm -f $KF" >/dev/null
done

fails=0
for n in $A $B; do
    f=$OUT/kmsg_$n.gz
    [ -s "$f" ] || { echo "RESULT: ABORT label=$LABEL stage=capture node=$n"; exit 2; }
    for t in P-UNPUB-OWNED-META P-STALE-FIN P83-UNL-RELOAD P83-UNL-BUCKET-RELOAD; do
        all=$(zcat "$f" | grep -acF -- "mxfs: $t ")
        dbg=$(zcat "$f" | grep -aF -- "mxfs: $t " | grep -ac '^kern *:debug *: ')
        site=$(grep -c "\"mxfs: $t " "$OUT/dyndbg_$n.txt")
        v=PASS
        [ "$all" = 0 ] && v=UNREACHED
        [ "$all" != "$dbg" ] && { v=FAIL; fails=$((fails + 1)); }
        [ "$site" = 1 ] || { v=FAIL; fails=$((fails + 1)); }
        echo "  TAG node=$n tag=$t lines=$all at_debug=$dbg dyndbg_sites=$site -> $v"
        [ "$all" != "$dbg" ] && zcat "$f" | grep -aF -- "mxfs: $t " | grep -av '^kern *:debug *: ' | head -3 | sed 's/^/    NOT-DEBUG /'
    done
    up=$(zcat "$f" | grep -ac 'Found unrecovered unlinked inode')
    echo "  UPSTREAM node=$n found_unrecovered_lines=$up (want 0 on a cluster mount)"
    [ "$up" = 0 ] || fails=$((fails + 1))
    # lap 3 drives the reload itself: a reloaded member that reads linked is
    # the AGI-corruption shutdown path, never a healthy outcome
    lv=$(zcat "$f" | grep -ac 'mxfs: P84-UNL-RELOAD-LIVE ')
    echo "  RELOAD node=$n reload_ok=$(zcat "$f" | grep -ac 'mxfs: P84-UNL-RELOAD-OK ') reload_live=$lv (want 0)"
    [ "$lv" = 0 ] || fails=$((fails + 1))
done
echo "PROBELEVEL label=$LABEL fails=$fails wall=$(( $(date +%s) - s ))s"
if [ "$fails" = 0 ]; then
    echo "RESULT: PASS label=$LABEL — every line of a reached tag is at debug (UNREACHED tags above are not passes)"
else
    echo "RESULT: FAIL label=$LABEL fails=$fails"
fi
echo "  evidence: $OUT"
