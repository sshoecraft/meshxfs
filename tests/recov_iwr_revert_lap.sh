#!/bin/bash
# recov_iwr_revert_lap.sh — does a rejoining node's log recovery write back a
# directory slot it skipped, over a peer's newer image of that directory?
#
# D-4CAWMPATH-PATH-ALL-LOST-A-CHURN-FILE-NO-LONGER-NAMED-ITS-CREATED-INODE.  On
# 4/disk/caw/mpath path_all_lost a survivor's own renamed churn file was gone
# from the shared directory, and the victim's rejoin mount had, in its adopted
# replay of its own slice, skipped the directory's inode (P77-FRINODE
# verdict=SKIP: the platter newer) and then written the WHOLE inode cluster
# holding it (P-IWR-WHOLE why=ops-ra, logged=0x0).  Log recovery reads every
# cluster it replays into through its readahead, so the buffer still carries
# xfs_inode_buf_ra_ops, and on a 512-byte-sector volume such a buffer was sent
# whole instead of through the per-slot mask that never publishes a directory
# slot this node did not log.  Whatever a peer wrote of that cluster between
# the recovery's read and its write is reverted.
#
# The lap makes that window certain instead of lucky:
#   1. A creates names in a fresh directory D; B creates b0 in D and renames it
#      to b0.r (a rename inside a shortform directory logs only the two inodes,
#      so the adopted replay at B's rejoin reaches it rather than refusing it
#      as the prior incarnation's), and forces its log.
#   2. B's next log write fails (log_inject_ioerr) and its filesystem shuts
#      down; A replays B's slice and creates a2 in D.
#   3. B unloads and rejoins with dbg_recov_iwr_hold_n=1: its recovery's write
#      of the first cluster holding a directory waits HOLD_MS before deciding
#      which slots leave the node (P-RECOV-IWR-HOLD).
#   4. Inside the hold A creates `late` in D and unmounts cleanly, so D's image
#      with `late` is on the platter.
#   5. The hold ends; B's mount completes; B lists D from the platter (it is
#      alone, nothing is cached).  Every name A and B made must be there.
# Exposure, printed as one EXPOSED line: B's recovery skipped D (P77-FRINODE
# adopted ino=D verdict=SKIP), the held write carried D's slot, and A's unmount
# with `late` finished inside the hold.  Without all three the lap measured
# nothing and says VACUOUS.
#
# Arm (iwr_ra_partial on both nodes, read back): 1 the fix, 0 the whole write
# (the same-build control).  dino_clobber_check=1 on B's rejoin names a slot
# the write regresses (P-DINO-CLOBBER).
#
# derived time budget, from the steps this lap is built of (tests/
# agmeta_shutdown_retire.sh measured them on this rig): setup and the rename
# ~10 s; B's shutdown and withdrawal settle bounded at 20 s; A's first access
# to D after B's death waits on its replay of B's slice, bounded 60 s; B's
# unmount and rmmod measured ~8 s; B's rejoin is its mount (~10 s) plus
# HOLD_MS; A's create and clean unmount measured ~6 s and must fit inside
# HOLD_MS (15 s default); A's remount ~10 s.  About 90 s in all; the caller
# bounds a lap at 240 s.
#
# Usage: tests/recov_iwr_revert_lap.sh <label> [arm=1]
# Env:   MXFS_NODE_LIST (default test1,test2: the first is A, the survivor; the
#        second is B, the one shut down), MNT=/mnt/shared, KO=/src/mxfs/mxfs.ko,
#        HOLD_MS=15000
# Prints: EXPOSED: ... when the trigger was reached, then one of
#         LAP recov_iwr PASS|FAIL|VACUOUS|ABORT ...
set -u
LABEL=${1:?label}
ARM=${2:-1}
case $ARM in 0|1) ;; *) echo "usage: $0 <label> [arm=0|1]"; exit 2 ;; esac
cd "$(dirname "$0")/.." || exit 2
export MXFS_NODE_LIST=${MXFS_NODE_LIST:-test1,test2}
. "$(dirname "$0")/lib/rig.sh"
mxfs_dev_resolve "${MXFS_NODE_LIST%%,*}"; export MXFS_DEV=$MXFS_DEV_RESOLVED
A=${MXFS_NODE_LIST%%,*}
B=${MXFS_NODE_LIST##*,}
SSH=tools/mxfs_sshpass.sh
MNT=${MNT:-/mnt/shared}
KO=${KO:-/src/mxfs/mxfs.ko}
HOLD_MS=${HOLD_MS:-15000}
# a batch runs the lap again under one label: each lap's directory is its own
NONCE=$(date +%s%N)
D=$MNT/recoviwr_${LABEL}_$NONCE
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_recoviwr_$LABEL
mkdir -p "$OUT"
fails=0
MK="RECOVIWR-$LABEL-$NONCE"
SV=$(modinfo mxfs.ko 2>/dev/null | sed -n 's/^srcversion: *//p')

out() { # <verdict> <text>: the lap's one result line, and its exit code
    echo "LAP recov_iwr $1 label=$LABEL arm=$ARM $2 evidence=$OUT"
    case $1 in PASS) exit 0 ;; FAIL) exit 1 ;; VACUOUS) exit 3 ;; *) exit 2 ;; esac
}
# on any exit, both nodes back at the defaults, so nothing that follows
# inherits this lap's arm, its clobber check or a hold
restore() {
    rs 20 "$B" "echo 0 > /sys/module/mxfs/parameters/dbg_recov_iwr_hold_n; echo 0 > /sys/module/mxfs/parameters/dino_clobber_check" > /dev/null
    for n in $A $B; do rs 20 "$n" "echo 1 > /sys/module/mxfs/parameters/iwr_ra_partial" > /dev/null; done
}
trap restore EXIT

echo "=== recov_iwr_revert_lap label=$LABEL arm=$ARM A=$A B=$B hold_ms=$HOLD_MS tree_sv=$SV $(date -u +%FT%TZ) ==="
pre=$(for n in $A $B; do rs 20 "$n" "grep -c ' $MNT mxfs ' /proc/mounts; cat /sys/module/mxfs/srcversion"; done | tr -d '\n')
[ "$pre" = "1${SV}1${SV}" ] || out ABORT "precondition: both nodes mounted with the tree build (got '$pre')"

# B's module parameters have to be replayed on the rejoin insmod or B comes
# back on a different transport than the cluster it is joining.
PARAMS=$(rs 20 "$B" "for p in force_transport target_cache_protected dead_timeout_ms; do v=\$(cat /sys/module/mxfs/parameters/\$p 2>/dev/null); [ -n \"\$v\" ] && echo -n \"\$p=\$v \"; done")
echo "  INFO $B insmod params for the rejoin: ${PARAMS:-none}"

for n in $A $B; do rs 15 "$n" "echo '$MK' > /dev/kmsg" >/dev/null; done
# The arm, set on the live A and read back; B gets it on its rejoin insmod.
ka=$(rs 20 "$A" "echo $ARM > /sys/module/mxfs/parameters/iwr_ra_partial && cat /sys/module/mxfs/parameters/iwr_ra_partial")
[ "$ka" = "$ARM" ] || out ABORT "iwr_ra_partial on $A read back '$ka', wanted $ARM"

# 1. names in D from both nodes; B's rename is its last durable change to D
rs 60 "$A" "mkdir $D && : > $D/a0 && : > $D/a1 && sync -f $MNT && echo A_SETUP_OK ino=\$(stat -c %i $D)" > "$OUT/setup_$A.txt"
grep -q '^A_SETUP_OK' "$OUT/setup_$A.txt" || out ABORT "A could not create D and its first names ($(head -c 200 "$OUT/setup_$A.txt"))"
DINO=$(sed -n 's/^A_SETUP_OK ino=\([0-9]*\)$/\1/p' "$OUT/setup_$A.txt")
rs 60 "$B" ": > $D/b0 && mv $D/b0 $D/b0.r && sync -f $MNT && echo B_RENAME_OK ino=\$(stat -c %i $D/b0.r) dino=\$(stat -c %i $D)" > "$OUT/rename_$B.txt"
grep -q '^B_RENAME_OK' "$OUT/rename_$B.txt" || out ABORT "B could not create and rename b0 in D ($(head -c 200 "$OUT/rename_$B.txt"))"
echo "  INFO D=$D ino=$DINO; $(cat "$OUT/rename_$B.txt")"

# 2. B's next log write fails; its filesystem shuts down and withdraws
rs 60 "$B" "echo 4 > /sys/module/mxfs/parameters/log_inject_ioerr; : > $MNT/recoviwr_trig_$LABEL 2>/dev/null; sync -f $MNT 2>/dev/null; for i in \$(seq 1 20); do dmesg | sed -n '/$MK/,\$p' | grep -aq 'P-WITHDRAW-DONE\|P163-RECOVERY-COMPLETE\|withdrawal complete' && break; sleep 1; done; echo B_SHUT settled_after=\${i}s left=\$(cat /sys/module/mxfs/parameters/log_inject_ioerr)" > "$OUT/shut_$B.txt"
echo "  INFO $(cat "$OUT/shut_$B.txt")"
rs 30 "$B" "dmesg | sed -n '/$MK/,\$p' | grep -ac 'P-LOG-INJECT-IOERR\|shut down due to log error\|Log I/O Error\|log I/O error'" > "$OUT/shutlines_$B.txt"
shut=$(tr -dc '0-9' < "$OUT/shutlines_$B.txt")
[ "${shut:-0}" -ge 1 ] || out ABORT "the injected log error did not shut B's filesystem down"

# A reaches D only once it has replayed B's slice; then a2, past B's image of D
rs 70 "$A" "t0=\$(date +%s%N); timeout 60 ls $D > /dev/null && : > $D/a2 && sync -f $MNT && echo A_AFTER_OK ms=\$(( (\$(date +%s%N) - t0) / 1000000 ))" > "$OUT/after_$A.txt"
grep -q '^A_AFTER_OK' "$OUT/after_$A.txt" || out FAIL "A could not reach D after B's death within 60 s ($(head -c 200 "$OUT/after_$A.txt"))"
echo "  INFO $(cat "$OUT/after_$A.txt")"

# 3. B unloads and rejoins with its recovery's directory-cluster write held
rs 120 "$B" "timeout 40 umount -f $MNT 2>/dev/null; timeout 40 umount $MNT 2>/dev/null; urc=\$?; grep -q ' $MNT mxfs ' /proc/mounts && echo B_UNLOAD_FAIL umount_rc=\$urc && exit; timeout 40 rmmod mxfs; echo B_UNLOAD rmmod_rc=\$? loaded=\$(lsmod | grep -c '^mxfs ')" > "$OUT/unload_$B.txt"
grep -q '^B_UNLOAD rmmod_rc=0 loaded=0' "$OUT/unload_$B.txt" || out ABORT "B did not unmount and unload ($(cat "$OUT/unload_$B.txt"))"
rs 40 "$B" "modprobe libcrc32c 2>/dev/null; insmod $KO dyndbg=+p $PARAMS iwr_ra_partial=$ARM dino_clobber_check=1 dbg_recov_iwr_hold_n=1 dbg_recov_iwr_hold_ms=$HOLD_MS && echo INSMOD_OK sv=\$(cat /sys/module/mxfs/srcversion) arm=\$(cat /sys/module/mxfs/parameters/iwr_ra_partial) hold_n=\$(cat /sys/module/mxfs/parameters/dbg_recov_iwr_hold_n); echo '$MK-REJOIN' > /dev/kmsg; mkdir -p $MNT; rm -f /run/recoviwr_mount.$LABEL; nohup setsid sh -c 't0=\$(date +%s%N); timeout 150 mount -t mxfs $MXFS_DEV $MNT; echo \"rc=\$? ms=\$(( (\$(date +%s%N) - t0) / 1000000 ))\" > /run/recoviwr_mount.$LABEL' > /dev/null 2>&1 < /dev/null &" > "$OUT/insmod_$B.txt"
grep -q "^INSMOD_OK sv=$SV arm=$ARM hold_n=1" "$OUT/insmod_$B.txt" || out ABORT "B's rejoin insmod did not take the tree build with the arm and the hold ($(cat "$OUT/insmod_$B.txt"))"

# wait for the hold to begin: B's mount reaches recovery in about 10 s
rs 50 "$B" "for i in \$(seq 1 40); do l=\$(dmesg | sed -n '/$MK-REJOIN/,\$p' | grep -a 'P-RECOV-IWR-HOLD begin' | head -1); [ -n \"\$l\" ] && { echo \"\$l\"; exit; }; [ -f /run/recoviwr_mount.$LABEL ] && { echo NO_HOLD mount_\$(cat /run/recoviwr_mount.$LABEL); exit; }; sleep 1; done; echo NO_HOLD timeout" > "$OUT/hold_$B.txt"
echo "  INFO $(cat "$OUT/hold_$B.txt")"
held_d=0
grep -q 'P-RECOV-IWR-HOLD begin.*dirs=\[\([0-9,]*,\)\?'"$DINO"'[],]' "$OUT/hold_$B.txt" && held_d=1

# 4. inside the hold: A creates `late` and unmounts cleanly
rs 60 "$A" "t0=\$(date +%s%N); : > $D/late && sync -f $MNT && timeout 40 umount $MNT; urc=\$?; echo A_LATE_UNMOUNT umount_rc=\$urc ms=\$(( (\$(date +%s%N) - t0) / 1000000 )) mounted=\$(grep -c ' $MNT mxfs ' /proc/mounts)" > "$OUT/late_$A.txt"
echo "  INFO $(cat "$OUT/late_$A.txt")"
# A's unmount is inside the hold only if B has not yet ended it, read on B now
rs 20 "$B" "dmesg | sed -n '/$MK-REJOIN/,\$p' | grep -ac 'P-RECOV-IWR-HOLD end'" > "$OUT/hold_open_$B.txt"
echo "  INFO hold end lines on $B when A's unmount returned: $(cat "$OUT/hold_open_$B.txt")"
# 5. B's mount completes once the hold ends
rs $(( HOLD_MS / 1000 + 60 )) "$B" "for i in \$(seq 1 $(( HOLD_MS / 1000 + 50 ))); do [ -f /run/recoviwr_mount.$LABEL ] && break; sleep 1; done; echo B_MOUNT \$(cat /run/recoviwr_mount.$LABEL 2>/dev/null || echo rc=none) mounted=\$(grep -c ' $MNT mxfs ' /proc/mounts); dmesg | sed -n '/$MK-REJOIN/,\$p'" > "$OUT/rejoin_dmesg_$B.txt"
echo "  INFO $(grep -a '^B_MOUNT ' "$OUT/rejoin_dmesg_$B.txt")"
grep -aq '^B_MOUNT rc=0 .*mounted=1' "$OUT/rejoin_dmesg_$B.txt" || { fails=$((fails+1)); echo "  FAIL B did not rejoin (mount rc 0, mounted)"; }

skip_d=$(grep -a "P77-FRINODE adopted ino=$DINO " "$OUT/rejoin_dmesg_$B.txt" | grep -ac 'verdict=SKIP')
hold_end=$(grep -ac 'P-RECOV-IWR-HOLD end' "$OUT/rejoin_dmesg_$B.txt")
late_in=0
grep -q '^A_LATE_UNMOUNT umount_rc=0 .*mounted=0' "$OUT/late_$A.txt" &&
    [ "$(tr -dc '0-9' < "$OUT/hold_open_$B.txt")" = 0 ] && late_in=1
whole=$(grep -a "P-IWR-WHOLE why=ops-ra" "$OUT/rejoin_dmesg_$B.txt" | grep -ac "ino=$DINO ")
clob=$(grep -ac 'P-DINO-CLOBBER' "$OUT/rejoin_dmesg_$B.txt")
cored=$(grep -a 'P56-CORESIDENT-DIR-SKIP' "$OUT/rejoin_dmesg_$B.txt" | grep -ac "img_ino=$DINO ")
echo "  MEASURE p77_skip_D=$skip_d held_D=$held_d hold_end=$hold_end late_inside_hold=$late_in whole_ra_writes_with_D=$whole dir_slot_skips_D=$cored clobber_lines=$clob"
grep -a 'P-DINO-CLOBBER\|P-IWR-WHOLE why=ops-ra\|P77-FRINODE adopted' "$OUT/rejoin_dmesg_$B.txt" | head -6 | cut -c1-220 | sed 's/^/      /'

# the names, read on B from the platter: B is alone and holds nothing cached
rs 30 "$B" "ls -1 $D 2>&1 | sort | tr '\n' ' '" > "$OUT/names_$B.txt"
names=$(cat "$OUT/names_$B.txt")
echo "  INFO names on $B: $names"
missing=""
for f in a0 a1 a2 b0.r late; do
    case " $names " in *" $f "*) ;; *) missing="$missing $f" ;; esac
done

# restore the pair for the next lap: A mounts again; the hold knob is spent
rs 160 "$A" "mkdir -p $MNT; timeout 150 mount -t mxfs $MXFS_DEV $MNT; echo A_REMOUNT rc=\$? mounted=\$(grep -c ' $MNT mxfs ' /proc/mounts)" > "$OUT/remount_$A.txt"
echo "  INFO $(cat "$OUT/remount_$A.txt")"
rs 30 "$A" "ls -1 $D 2>&1 | sort | tr '\n' ' '" > "$OUT/names_$A.txt"
echo "  INFO names on $A after its remount: $(cat "$OUT/names_$A.txt")"
rs 30 "$B" "rm -f $MNT/recoviwr_trig_$LABEL" > /dev/null

if [ "$skip_d" -ge 1 ] && [ "$held_d" = 1 ] && [ "$late_in" = 1 ]; then
    echo "EXPOSED: B's recovery skipped D (ino $DINO), held the write of its cluster ${HOLD_MS} ms, and A's unmount with 'late' in D finished inside the hold"
else
    out VACUOUS "the trigger was not reached: p77_skip_D=$skip_d held_D=$held_d late_inside_hold=$late_in"
fi
[ -z "$missing" ] || { fails=$((fails+1)); echo "  FAIL names missing from D on the platter after B's rejoin:$missing (whole_ra_writes_with_D=$whole clobber_lines=$clob)"; }
[ $fails = 0 ] || out FAIL "fails=$fails missing=[${missing# }] whole_ra_writes_with_D=$whole clobber_lines=$clob"
out PASS "every name A and B made in D is on the platter after B's rejoin (dir_slot_skips_D=$cored whole_ra_writes_with_D=$whole)"
