#!/bin/bash
# tests/clmerge_window_node.sh — the node side of tests/clmerge_window_probe.sh.
# Run on a cluster node from the tree the probe runs from; both roles work in
# one directory of the shared mount and signal each other through it.
#
#   owner <dir> <iters> <hold_s> <syncs>
#       per iteration i: write z<i> and y<i>; create go<i> and wait (5 s at
#       most) for the peer's h<i>, which says the peer holds y<i> open for
#       writing; open z<i> on fd 7; remove z<i> (it joins this node's
#       unlinked list, held here); remove y<i> (it joins the list ahead of
#       z<i>, held by the peer); close fd 7, so z<i>'s inactivation frees it
#       and moves y<i>'s unlinked pointer past it; then <syncs> times, 0.3 s
#       apart, push the whole AIL (a slab cache drop: xfs_reclaim_inodes_nr ->
#       xfs_ail_push_all; syncfs pushes only this node's preferred AG), so the
#       cluster write carrying that pointer goes out while the peer is still
#       writing y<i>; wait out the rest of <hold_s>.  Ends by creating 'done'.
#       With CMW_CLOSE_DROPS=N in the environment the owner also runs N cache
#       drops 50 ms apart in the background across its close of z, so a
#       reclaimable copy of y can be reclaimed while z's free is under way.
#   peer <dir> <hold_s>
#       for each go<i> in turn: open y<i> for appending on fd 8, create h<i>,
#       then for <hold_s> seconds append a line, fdatasync it and push the
#       whole AIL every 0.2 s, so y<i>'s core keeps changing and keeps being
#       written home; close it (the last close, so this node frees y<i>).
#       Leaves when 'done' exists.
#
# CMW_SHAPE=peerfree swaps who frees what, to fn32's shape
# (D-IUNLINK-PREV-OF-PEER-FREED-INODE-STALE-PRECOMMIT-SHUTDOWN): the PEER frees
# a mid-list member z of the owner's unlinked bucket while the OWNER frees z's
# predecessor y off the head and then puts a new inode x at the head, so the
# peer's remove meets a bucket z does not head, with its in-core predecessor
# freed and z's successor v still listed (a tail z would make the stale edit
# an idempotent NULL-to-NULL one, which the precommit lets through).
#   owner <dir> <iters> <hold_s> <syncs>
#       first, this node's unlinked bucket: it removes a file it holds open
#       and reads the bucket back from that remove's P82-ADD line (capped at
#       300 a module load; the lap's prep has just reloaded the module).  The
#       peer finds an unstamped z's bucket from z's number (agino % 64, and
#       ino % 64 is the same: an AG's inode number has at least 6 low bits),
#       and skips the free when that bucket is empty and z heads no other
#       (IFREE-REVALIDATE-SKIP bucket-empty-peer-freeing, xfs_inactive_ifree),
#       so z must be a number of this node's bucket, as fn32's 0x82 was of
#       test2's bucket 2.  Then per iteration i: write v<i>; write z<i> until
#       its number is one of this node's bucket (each miss is renamed f<n>
#       and kept, so the freed numbers come back to z next time); write y<i>
#       and x<i>; create go<i> and wait (5 s at most) for the peer's h<i>,
#       which says the peer holds z<i> open; open v<i> on fd 5, x<i> on fd 6
#       and y<i> on fd 7; remove v<i>, z<i> and y<i>, each joining the head
#       of this node's bucket: y -> z -> v; create r<i>; wait (5 s at most)
#       for the peer's c<i>, which says it is about to make its last close of
#       z<i>; sleep CMW_PRED_CLOSE_MS (default 700) and close fd 7, so this
#       node frees y<i> off the head (z<i> heads the bucket) while the peer's
#       free of z<i> waits for y<i>'s hold; sleep CMW_HEAD_MS (default 700)
#       and remove x<i>, which heads the bucket ahead of z<i>; wait (5 s at
#       most) for the peer's d<i>, which says its close of z<i> returned;
#       sleep CMW_CLOSE_WAIT_S (default 20), which covers the peer's free of
#       z<i>: it runs once the last reference drops, which can come after the
#       close returns (a directory's deferred dcache shrink); close fd 6 and
#       fd 5 (x<i> and v<i>, each freed from the head by then); then the cache
#       drops and the hold padding as above.  The f<n> are removed at the end.
#   peer <dir> <hold_s>
#       for each go<i> in turn: open z<i> for appending, create h<i>, wait
#       (hold_s + 5 s at most) for r<i>; then set z<i>'s times through the open
#       file (a setattr, which takes and keeps the inode's EX: the touch
#       fn32's freer ran), create c<i> and close the file, the last close.  A
#       cluster node inactivates an unlinked inode inline in the context that
#       drops its last reference (xfs_inode_mark_reclaimable): the close when
#       it is the last, else the deferred dcache shrink of the directory's
#       reload, a few ms later; create d<i>.  Its line carries the close's
#       wall time.
#
# Each role prints one line per iteration and a closing tally; the probe keeps
# them as the lap's workload record.
set -u
ROLE=${1:?role owner|peer}; D=${2:?dir}
SHAPE=${CMW_SHAPE:-ownerfree}
case "$SHAPE" in ownerfree|peerfree) ;; *) echo "CMW_SHAPE must be ownerfree or peerfree"; exit 2 ;; esac
PCMS=${CMW_PRED_CLOSE_MS:-700}; HDMS=${CMW_HEAD_MS:-700}; CWS=${CMW_CLOSE_WAIT_S:-20}
for v in "$PCMS" "$HDMS" "$CWS"; do
    case "$v" in ''|*[!0-9]*) echo "CMW_PRED_CLOSE_MS, CMW_HEAD_MS and CMW_CLOSE_WAIT_S must be whole numbers"; exit 2 ;; esac
done
msleep() { sleep "$(awk -v m="$1" 'BEGIN { printf "%.3f", m / 1000 }')"; }
case "$ROLE.$SHAPE" in
owner.peerfree)
    ITERS=${3:?iters}; HOLD=${4:?hold_s}; SYNCS=${5:?syncs}
    ok=0; noack=0; noclose=0; nodone=0; fill=0
    head -c 4096 /dev/urandom > "$D/cal" || { echo "owner calibration create_failed"; touch "$D/done"; exit 2; }
    ci=$(stat -c %i "$D/cal"); exec 4< "$D/cal"; rm "$D/cal"; exec 4<&-
    BK=$(dmesg | grep -a "P82-ADD ino=$ci " | tail -1 | sed -n 's/.* bucket=\([0-9]*\) .*/\1/p')
    [ -n "$BK" ] || { echo "owner calibration: no P82-ADD line for ino $ci"; touch "$D/done"; exit 2; }
    echo "owner bucket=$BK (P82-ADD of ino $ci)"
    for i in $(seq 1 "$ITERS"); do
        t0=$SECONDS
        head -c 4096 /dev/urandom > "$D/v$i" || { echo "owner iter $i create_failed"; break; }
        k=0
        while :; do
            head -c 4096 /dev/urandom > "$D/z$i" || { echo "owner iter $i create_failed"; break 2; }
            zi=$(stat -c %i "$D/z$i")
            [ $((zi % 64)) = "$BK" ] && break
            k=$((k + 1)); fill=$((fill + 1)); mv "$D/z$i" "$D/f$fill"
            [ $k -lt 130 ] || { echo "owner iter $i no number of bucket $BK in $k creates"; break 2; }
        done
        head -c 4096 /dev/urandom > "$D/y$i" && head -c 4096 /dev/urandom > "$D/x$i" \
            || { echo "owner iter $i create_failed"; break; }
        vi=$(stat -c %i "$D/v$i"); yi=$(stat -c %i "$D/y$i"); xi=$(stat -c %i "$D/x$i")
        touch "$D/go$i"
        w=0
        until [ -e "$D/h$i" ] || [ $w -ge 100 ]; do sleep 0.05; w=$((w + 1)); done
        if [ ! -e "$D/h$i" ]; then
            noack=$((noack + 1)); echo "owner iter $i v=$vi z=$zi y=$yi x=$xi noack"
            rm -f "$D/v$i" "$D/z$i" "$D/y$i" "$D/x$i" "$D/go$i"; continue
        fi
        exec 5< "$D/v$i" 6< "$D/x$i" 7< "$D/y$i"
        rv=0; rm "$D/v$i" || rv=$?
        rz=0; rm "$D/z$i" || rz=$?
        ry=0; rm "$D/y$i" || ry=$?
        touch "$D/r$i"
        w2=0
        until [ -e "$D/c$i" ] || [ $w2 -ge 100 ]; do sleep 0.05; w2=$((w2 + 1)); done
        [ -e "$D/c$i" ] || noclose=$((noclose + 1))
        msleep "$PCMS"
        exec 7<&-
        msleep "$HDMS"
        rx=0; rm "$D/x$i" || rx=$?
        w3=0
        until [ -e "$D/d$i" ] || [ $w3 -ge 100 ]; do sleep 0.05; w3=$((w3 + 1)); done
        [ -e "$D/d$i" ] || nodone=$((nodone + 1))
        sleep "$CWS"
        exec 6<&- 5<&-
        s=0
        while [ $s -lt "$SYNCS" ]; do sleep 0.3; echo 2 > /proc/sys/vm/drop_caches; s=$((s + 1)); done
        rm -f "$D/go$i" "$D/h$i" "$D/r$i" "$D/c$i" "$D/d$i"
        ok=$((ok + 1))
        echo "owner iter $i v=$vi z=$zi y=$yi x=$xi z_misses=$k rm_v=$rv rm_z=$rz rm_y=$ry rm_x=$rx ack_rounds=$w close_rounds=$w2 done_rounds=$w3 syncs=$s"
        while [ $((SECONDS - t0)) -lt "$HOLD" ]; do sleep 0.2; done
    done
    k=1; while [ $k -le $fill ]; do rm -f "$D/f$k"; k=$((k + 1)); done
    touch "$D/done"
    echo "owner done iters=$ITERS ok=$ok noack=$noack noclose=$noclose nodone=$nodone fill=$fill bucket=$BK"
    ;;
peer.peerfree)
    HOLD=${3:?hold_s}
    i=1; held=0; fails=0
    while [ -d "$D" ] && [ ! -e "$D/done" ]; do
        if [ ! -e "$D/go$i" ]; then sleep 0.02; continue; fi
        python3 - "$D" "$i" "$HOLD" <<'PY'
import os, sys, time
d, i, hold = sys.argv[1], sys.argv[2], float(sys.argv[3])
try:
    fd = os.open("%s/z%s" % (d, i), os.O_WRONLY | os.O_APPEND)
except OSError as e:
    print("peer iter %s open_failed errno=%d" % (i, e.errno)); sys.exit(1)
open("%s/h%s" % (d, i), "w").close()
end = time.time() + hold + 5
while not os.path.exists("%s/r%s" % (d, i)) and time.time() < end:
    time.sleep(0.02)
seen = os.path.exists("%s/r%s" % (d, i))
def mark(name):
    try:
        open("%s/%s%s" % (d, name, i), "w").close()
        return 0
    except OSError as e:
        return e.errno
urc = 0
try:
    os.utime(fd)
except OSError as e:
    urc = e.errno
crc = mark("c")
t = time.time(); xrc = 0
try:
    os.close(fd)
except OSError as e:
    xrc = e.errno
close_ms = (time.time() - t) * 1000
drc = mark("d")
print("peer iter %s removed_seen=%d utime_errno=%d c_errno=%d close_ms=%.0f close_errno=%d d_errno=%d" % (i, int(seen), urc, crc, close_ms, xrc, drc))
PY
        if [ $? = 0 ]; then held=$((held + 1)); else fails=$((fails + 1)); fi
        i=$((i + 1))
    done
    echo "peer done held=$held open_failed=$fails"
    ;;
owner.ownerfree)
    ITERS=${3:?iters}; HOLD=${4:?hold_s}; SYNCS=${5:?syncs}
    ok=0; noack=0
    for i in $(seq 1 "$ITERS"); do
        t0=$SECONDS
        head -c 4096 /dev/urandom > "$D/z$i" && head -c 4096 /dev/urandom > "$D/y$i" \
            || { echo "owner iter $i create_failed"; break; }
        zi=$(stat -c %i "$D/z$i"); yi=$(stat -c %i "$D/y$i")
        touch "$D/go$i"
        w=0
        until [ -e "$D/h$i" ] || [ $w -ge 100 ]; do sleep 0.05; w=$((w + 1)); done
        if [ ! -e "$D/h$i" ]; then
            noack=$((noack + 1)); echo "owner iter $i z=$zi y=$yi noack"
            rm -f "$D/z$i" "$D/y$i" "$D/go$i"; continue
        fi
        exec 7< "$D/z$i"
        rz=0; rm "$D/z$i" || rz=$?
        ry=0; rm "$D/y$i" || ry=$?
        dp=""
        if [ "${CMW_CLOSE_DROPS:-0}" -gt 0 ]; then
            ( k=0; while [ $k -lt "$CMW_CLOSE_DROPS" ]; do echo 2 > /proc/sys/vm/drop_caches; sleep 0.05; k=$((k + 1)); done ) & dp=$!
        fi
        exec 7<&-
        [ -n "$dp" ] && wait "$dp"
        s=0
        while [ $s -lt "$SYNCS" ]; do sleep 0.3; echo 2 > /proc/sys/vm/drop_caches; s=$((s + 1)); done
        rm -f "$D/go$i" "$D/h$i"
        ok=$((ok + 1))
        echo "owner iter $i z=$zi y=$yi rm_z=$rz rm_y=$ry ack_rounds=$w syncs=$s"
        while [ $((SECONDS - t0)) -lt "$HOLD" ]; do sleep 0.2; done
    done
    touch "$D/done"
    echo "owner done iters=$ITERS ok=$ok noack=$noack"
    ;;
peer.ownerfree)
    HOLD=${3:?hold_s}
    i=1; held=0; writes=0; fails=0
    # a directory that no longer stats is a filesystem that shut down here
    while [ -d "$D" ] && [ ! -e "$D/done" ]; do
        if [ ! -e "$D/go$i" ]; then sleep 0.02; continue; fi
        if ! exec 8>> "$D/y$i"; then
            fails=$((fails + 1)); echo "peer iter $i open_failed"; i=$((i + 1)); continue
        fi
        touch "$D/h$i"
        end=$((SECONDS + HOLD)); n=0
        while [ $SECONDS -lt $end ]; do
            echo "peer $i $n" >&8 && sync -d "$D/y$i" 2>/dev/null
            echo 2 > /proc/sys/vm/drop_caches
            n=$((n + 1)); sleep 0.2
        done
        exec 8>&-
        held=$((held + 1)); writes=$((writes + n))
        echo "peer iter $i writes=$n"
        i=$((i + 1))
    done
    echo "peer done held=$held writes=$writes open_failed=$fails"
    ;;
*)
    echo "role must be owner or peer"; exit 2 ;;
esac
