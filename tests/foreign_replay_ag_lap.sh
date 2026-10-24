#!/bin/bash
# foreign_replay_ag_lap.sh — while a survivor replays a dead node's journal
# slice into an allocation group's headers, can a live node change that AG?
#
# WHY THIS EXISTS.  During a foreign replay the surviving node writes the AG
# header blocks (AGF, AGI, the free-space and inode btrees) of the AGs the
# victim held at death, and it holds no grant of its own for them: PROBE-A
# (pal/linux/xfs_buf.c, AG-META-WRITE-NOT-HELD) fires on every such write
# (D-FOREIGN-REPLAY-WRITES-AG-HEADERS-WITHOUT-THE-AG-LOCK).  The code says what
# stands in for the lock: an AG image is applied only for an AG the victim held
# at death (xfs/xfs_log_recover.c, the token verdict against the fence-time
# manifest), and the victim's grant on it stays in force until the
# recovery-complete ladder releases it after the replay (on COMPARE AND WRITE
# its slot bit until mxfs_dlm_caw_purge_node, on the TCP lock manager the
# frozen master-table grant until v5_dead_grants_retire).  On two nodes the
# only peer is the dead one, so nothing tested that a live third node is kept
# out.  This lap does.
#
# SHAPE (four nodes: V the victim, the others survivors):
#   1. prep the group; each node's heartbeat slot from its kernel log.
#   2. V creates NF files, each NF_MB MiB allocated, and syncs: their inodes
#      and blocks are in V's AGs.  Each survivor then changes the mode of its
#      share of them (file i to survivor i mod 3), so it holds those inodes'
#      grants and V's go back.
#   3. V runs a create-and-allocate load in the files' own directory, unsynced,
#      so its journal holds changes to the headers of the AG the files are in
#      (a new directory's inodes go to another AG, and a file's near its
#      directory's); V is destroyed under it.
#   4. At once, each survivor truncates its share to 0, every file of it
#      concurrently (each file's extents freed in the file's AG under that AG's
#      grant), timing every truncate on its own clock.  Concurrent, so every
#      truncate is issued while the replay runs, not only a survivor's first.
#   5. The replayer is the survivor that logs P163-RECOVERY-COMPLETE for V's
#      slot.  Its ladder entry, after the slice replay, is that line's time
#      less its total= ms.  The AGs the replay wrote are the agno= of its
#      PROBE-A lines in the same span.
#   EXPOSED: the replay wrote the header of an AG for which a survivor other
#      than the replayer issued a truncate before the ladder entry.
#   PASS: every such truncate completed at or after the ladder entry (less
#      ERR_MS for the clock offsets); every truncate returned 0; no survivor
#      shut down; the offline chk_mxfs of the volume is clean.
#   FAIL: a live survivor's change to a replayed AG completed before the replay
#      had finished, a truncate failed, a survivor shut down, or chk_mxfs found
#      damage.
#
# Times across nodes: each node's kernel time is turned into its wall clock
# from /proc/uptime and date read together, and every node's wall clock into
# this host's with tests/lib/rig.sh clock_measure (ssh round trip, best of 3).
# ERR_MS covers both.
#
# the budget rule (derived): prep of four nodes, measured 60-95 s, bound 150 +
# geometry and slots 4 x 20 + V's creates (NF x NF_MB MiB allocated, under a
# second) and sync, bound 60 + the survivors' mode changes 3 x 30 + V's load
# start 30 + 4 s of load + detection (17 checks, 34.8 s measured) + recovery
# (7-9 s measured) + the truncates, which wait for it: bound 120 + kernel logs
# 3 x 30 + unmounts 3 x 70 + chk_mxfs of the volume, bound 180 + V back up
# (lab_power, BOOT_S 240) = about 1290 s, plus the wait for the recovery's
# line when the truncates return before it (4b, at most 53 s from the kill) =
# about 1343 s.  Caller bound 1350 s.
#
# Usage: tests/foreign_replay_ag_lap.sh <label>
# Env:   MXFS_NODE_LIST (four nodes, the last the victim), MXFS_CONFIG
#        (4/disk/caw/direct), MXFS_GROUP, NF (48), NF_MB (4), ERR_MS (50)
# Leaves V booted and unformed into the cluster, the survivors unmounted: the
# next lap's prep forms the group again.
# Exit 0 PASS, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}
# the tree root holds run.sh and tools/mxfs_lab.sh both, found from the unresolved path: a draft
# of this lap under tests/evidence, a symbolic link out of the tree, still finds its tree
HERE="$(cd "$(dirname "$0")" && while { [ ! -f run.sh ] || [ ! -f tools/mxfs_lab.sh ]; } && [ "$(pwd)" != / ]; do cd ..; done; pwd)"
[ -f "$HERE/tools/mxfs_lab.sh" ] || { echo "ABORT: no tree root above $0"; exit 2; }
cd "$HERE" || exit 2
export MXFS_NODE_LIST=${MXFS_NODE_LIST:?MXFS_NODE_LIST (four nodes)}
export MXFS_CONFIG=${MXFS_CONFIG:-4/disk/caw/direct}
IFS=, read -r -a ALL <<<"$MXFS_NODE_LIST"
[ "${#ALL[@]}" = 4 ] || { echo "ABORT: MXFS_NODE_LIST names ${#ALL[@]} nodes, the lap needs 4"; exit 2; }
V=${ALL[3]}
SURV=("${ALL[0]}" "${ALL[1]}" "${ALL[2]}")
NF=${NF:-48}
NF_MB=${NF_MB:-4}
ERR_MS=${ERR_MS:-50}
MNT=/mnt/shared
D=$MNT/.fragag_$LABEL
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_fragag_$LABEL
mkdir -p "$OUT"
fails=0
. "$HERE/tests/lib/rig.sh"
MARK="FRAGAG-MARK-$LABEL-$$"
echo "=== foreign_replay_ag_lap label=$LABEL config=$MXFS_CONFIG victim=$V survivors=${SURV[*]} nf=$NF nf_mb=$NF_MB err_ms=$ERR_MS $(date -u +%FT%TZ) ==="
s0=$(date +%s)
el() { echo $(( $(date +%s) - s0 )); }
field(){ grep -aoE "(^| )$2=[^ ]*" "$1" | head -1 | cut -d= -f2; }
abort() { echo "ABORT: $2"; echo "RESULT: ABORT label=$LABEL stage=$1 evidence=$OUT"; exit 2; }

# ---- 1. the group, the device, each node's slot
GROUPARG=()
[ -n "${MXFS_GROUP:-}" ] && GROUPARG=(--group "$MXFS_GROUP")
MXFS_FORCE_PREP=1 timeout 150 ./run.sh "$MXFS_CONFIG" "${GROUPARG[@]}" prep_cluster > "$OUT/prep.log" 2>&1
prc=$?
echo "STAGE prep rc=$prc wall=$(el)s  $(grep -am1 'prep OK\|FAIL' "$OUT/prep.log" | cut -c1-140)"
[ $prc = 0 ] || abort prep "prep_cluster rc=$prc"
DEV=$(rs 15 "$V" "awk '\$2 == \"$MNT\" && \$3 == \"mxfs\" {print \$1}' /proc/mounts | head -1" 2>/dev/null | tr -d '\r\n')
[ -n "$DEV" ] || abort device "$V has no mxfs mount at $MNT"
declare -A SLOT
for n in "${ALL[@]}"; do
    measure "$n" 20 "$OUT/${n}_slot.txt" '^SLOT_END$' "$n's heartbeat slot" \
        "echo $MARK > /dev/kmsg; dmesg | grep -a 'claimed heartbeat slot' | tail -1 | sed -n 's/.*claimed heartbeat slot \([0-9]*\).*/SLOT=\1/p'; echo SLOT_END"
    SLOT[$n]=$(field "$OUT/${n}_slot.txt" SLOT)
    [ -n "${SLOT[$n]}" ] || abort slots "cannot read $n's heartbeat slot"
    clock_measure "$n" || abort clocks "cannot read $n's clock"
done
echo "STAGE slots: $(for n in "${ALL[@]}"; do printf '%s=%s ' "$n" "${SLOT[$n]}"; done)"
# inode number -> AG: ino >> (agblklog + inopblog), the mkfs-time geometry
# chk_mxfs --geometry prints from a live node without exclusion
measure "$V" 20 "$OUT/geometry.txt" 'agcount' "the volume's geometry" \
    "/src/$(basename "$PWD")/tools/chk_mxfs --geometry $DEV 2>&1"
AGBLKLOG=$(grep -aoE 'agblklog=[0-9]+' "$OUT/geometry.txt" | head -1 | cut -d= -f2)
INOPBLOG=$(grep -aoE 'inopblog=[0-9]+' "$OUT/geometry.txt" | head -1 | cut -d= -f2)
[ -n "$AGBLKLOG" ] && [ -n "$INOPBLOG" ] || abort geometry "no agblklog/inopblog in $OUT/geometry.txt"
AGSHIFT=$(( AGBLKLOG + INOPBLOG ))
echo "STAGE geometry agblklog=$AGBLKLOG inopblog=$INOPBLOG agshift=$AGSHIFT"

# ---- 2. V's files, and each survivor takes the grants of its share
measure "$V" 60 "$OUT/V_files.txt" '^FILES_END$' "V's files" \
    "mkdir -p $D/v || exit 1; i=0; while [ \$i -lt $NF ]; do f=$D/v/f\$i; fallocate -l ${NF_MB}M \$f || break; echo FILE \$i \$(stat -c %i \$f); i=\$((i+1)); done; sync -f $MNT; echo FILES_END"
[ "$(cnt "$OUT/V_files.txt" '^FILE ')" = "$NF" ] || abort files "V made $(cnt "$OUT/V_files.txt" '^FILE ') of $NF files"
declare -A AGOF INOAG
while read -r _ i ino; do INOAG[$i]=$(( ino >> AGSHIFT )); done < <(grep -a '^FILE ' "$OUT/V_files.txt")
echo "STAGE V's files: $NF inodes in AGs $(printf '%s\n' "${INOAG[@]}" | sort -n | uniq -c | awk '{printf "%s(x%s) ", $2, $1}')"
# A truncate frees the file's extents under the grant of the AG that holds them, and
# writes that AG's headers (AGF, the free-space btrees); the inode's own AG gets no
# header write from it.  The inode's AG and its data's AG are not one AG on every
# configuration: on 4/net/mesh/direct two laps of b20261024-0f5859 had every inode in
# AG 11 while V's load (same directory) wrote AGs 3 and 4, and graded VACUOUS by the
# inode's AG.  So each file's extents are read and a truncate is in every AG its
# extents are in.  xfs_io's bmap refuses the mount as a foreign filesystem, so the
# extents come from FIEMAP (filefrag -v, in filesystem blocks); the module's iomap
# adds the envelope ahead of the XFS region to every address
# (pal/linux/xfs_iomap.c, bt_sector_offset), so a block's AG is (physical -
# xfs_data_offset/blocksize) / agblocks, from the geometry read above.
# FRA_MAP=inode maps by the inode's AG, as before: the control.
BSIZE=$(grep -aoE 'blocksize=[0-9]+' "$OUT/geometry.txt" | head -1 | cut -d= -f2)
AGBLOCKS=$(grep -aoE 'agblocks=[0-9]+' "$OUT/geometry.txt" | head -1 | cut -d= -f2)
DATAOFF=$(grep -aoE 'xfs_data_offset=[0-9]+' "$OUT/geometry.txt" | head -1 | cut -d= -f2)
[ -n "$BSIZE" ] && [ -n "$AGBLOCKS" ] && [ -n "$DATAOFF" ] || abort geometry "no blocksize/agblocks/xfs_data_offset in $OUT/geometry.txt"
[ $(( DATAOFF % BSIZE )) = 0 ] || abort geometry "xfs_data_offset $DATAOFF is not a whole number of $BSIZE-byte blocks"
OFFB=$(( DATAOFF / BSIZE ))
measure "$V" 60 "$OUT/V_extents.txt" '^EXT_END$' "V's files' extents" \
    "for i in \$(seq 0 $((NF - 1))); do filefrag -v $D/v/f\$i > /tmp/fragag_ext.txt 2>&1; echo EXTRAW \$i \$(grep -c '^ *[0-9]*:' /tmp/fragag_ext.txt) \$(grep -m1 'blocks of' /tmp/fragag_ext.txt); echo EXT \$i \$(awk -v off=$OFFB -v agb=$AGBLOCKS '\$1 ~ /^[0-9]+:\$/ {p=\$4; sub(/\\.\\.\$/, \"\", p); q=\$5; sub(/:\$/, \"\", q); print int((p - off) / agb); print int((q - off) / agb)}' /tmp/fragag_ext.txt | sort -un | tr '\n' ' '); done; echo EXT_END"
grep -a '^EXTRAW ' "$OUT/V_extents.txt" | grep -av "blocks of $BSIZE bytes" | head -1 | grep -q . && \
    abort extents "filefrag reported extents in other than $BSIZE-byte blocks ($OUT/V_extents.txt)"
declare -A EXTAG
while read -r _ i ags; do EXTAG[$i]=$ags; done < <(grep -a '^EXT ' "$OUT/V_extents.txt")
noext=0
for i in $(seq 0 $((NF - 1))); do
    case "${EXTAG[$i]:-}" in ''|*[!0-9\ ]*) noext=$((noext+1)) ;; esac
done
echo "STAGE V's files' data extents in AGs: $(for i in $(seq 0 $((NF - 1))); do echo "${EXTAG[$i]:-none}"; done | tr ' ' '\n' | grep -v '^$' | sort -n | uniq -c | awk '{printf "%s(x%s) ", $2, $1}') (files with no AG read: $noext)"
[ "$noext" = 0 ] || abort extents "$noext of $NF files' extents have no AG read ($OUT/V_extents.txt)"
for i in $(seq 0 $((NF - 1))); do
    if [ "${FRA_MAP:-extent}" = inode ]; then AGOF[$i]=${INOAG[$i]}; else AGOF[$i]=${EXTAG[$i]}; fi
done
echo "STAGE truncates mapped by the $( [ "${FRA_MAP:-extent}" = inode ] && echo "inode's AG (FRA_MAP=inode)" || echo "data extents' AGs" )"
for j in 0 1 2; do
    n=${SURV[$j]}
    list=$(for i in $(seq 0 $((NF - 1))); do [ $((i % 3)) = $j ] && printf '%s ' "$i"; done)
    measure "$n" 30 "$OUT/${n}_take.txt" '^TAKE_END$' "$n takes its share" \
        "ok=0; for i in $list; do chmod 0600 $D/v/f\$i && ok=\$((ok+1)); done; sync -f $MNT; echo TOOK=\$ok; echo TAKE_END"
    ck "$n took its share" "$(field "$OUT/${n}_take.txt" TOOK)" "$(echo $list | wc -w)"
done
[ $fails = 0 ] || abort take "a survivor could not take its share"

# ---- 3. V's unsynced load, and V's death
measure "$V" 30 "$OUT/V_load.txt" '^LOAD_STARTED$' "V's load" \
    "nohup setsid bash -c 'i=0; while :; do fallocate -l 1M $D/v/l\$i; i=\$((i+1)); done' </dev/null >/dev/null 2>&1 & echo LOAD_STARTED"
sleep 4
measure "$V" 20 "$OUT/V_load_n.txt" '^LOADN=' "V's load is writing" "echo LOADN=\$(ls -f $D/v | grep -c '^l')"
ckge "V's load made files" "$(field "$OUT/V_load_n.txt" LOADN)" 10
[ $fails = 0 ] || abort load "V's load did not run"
virsh -c qemu:///system destroy "$V" > "$OUT/destroy.txt" 2>&1 || abort kill "virsh destroy $V: $(cat "$OUT/destroy.txt")"
T_KILL=$(date +%s%3N)
echo "STAGE $V destroyed at host ms $T_KILL (+$(el)s)"

# ---- 4. the survivors' truncates, all at once
for j in 0 1 2; do
    n=${SURV[$j]}
    list=$(for i in $(seq 0 $((NF - 1))); do [ $((i % 3)) = $j ] && printf '%s ' "$i"; done)
    ( measure "$n" 120 "$OUT/${n}_trunc.txt" '^TRUNC_END$' "$n's truncates" \
        "for i in $list; do ( t0=\$(date +%s%3N); truncate -s 0 $D/v/f\$i; rc=\$?; t1=\$(date +%s%3N); echo OP \$i \$t0 \$t1 \$rc ) & done; wait; echo TRUNC_END" ) > "$OUT/${n}_trunc.out" 2>&1 &
done
wait
for n in "${SURV[@]}"; do
    grep -aq '^ABORT' "$OUT/${n}_trunc.out" && { cat "$OUT/${n}_trunc.out"; abort truncates "$n's truncates were not captured"; }
done
echo "STAGE truncates returned at +$(el)s"

# ---- 4b. the recovery has completed somewhere before the logs are read
# A truncate that needs nothing the victim held returns before the replay ends,
# so the logs read at once could hold no P163-RECOVERY-COMPLETE yet, and the lap
# failed that no survivor replayed
# (D-FOREIGN-REPLAY-AG-LAP-READS-SURVIVOR-LOGS-BEFORE-P163-AND-FINDS-NO-REPLAYER).
# Wait for the line on some survivor, bounded from the kill: detection at the
# longest window a node may run (17 checks, 34.8 s measured) plus twice the
# recovery's measured 7-9 s, 53 s.  None in that bound is an ABORT: the lap
# measured nothing, it is not a verdict on the replay.  LAP_WAIT_P163=0 reads at
# once, as before: the control.
P163_BOUND_MS=53000
if [ "${LAP_WAIT_P163:-1}" != 0 ]; then
    seen=""
    while [ -z "$seen" ]; do
        for n in "${SURV[@]}"; do
            # rs reports filt's status, not the remote command's: read a token
            if rs 10 "$n" "dmesg | sed -n '/$MARK/,\$p' | grep -aq 'P163-RECOVERY-COMPLETE slot=${SLOT[$V]} ' && echo P163_SEEN" | grep -q '^P163_SEEN$'; then
                seen=$n; break
            fi
        done
        [ -n "$seen" ] && break
        [ $(( $(date +%s%3N) - T_KILL )) -ge $P163_BOUND_MS ] && \
            abort recovery "no survivor logged P163-RECOVERY-COMPLETE for $V's slot ${SLOT[$V]} within ${P163_BOUND_MS} ms of the kill"
        sleep 2
    done
    echo "STAGE recovery complete on $seen by +$(( $(date +%s%3N) - T_KILL )) ms after the kill"
fi

# ---- 5. each survivor's kernel log since the mark, on its own clock
for n in "${SURV[@]}"; do
    measure "$n" 30 "$OUT/${n}_kmsg.txt" '^KMSG_END$' "$n's kernel log since the mark" \
        "echo CLK \$(date +%s%3N) \$(cut -d' ' -f1 /proc/uptime); dmesg | sed -n '/$MARK/,\$p' | grep -a 'P163-RECOVERY-COMPLETE\|PROBE-A AG-META-WRITE-NOT-HELD\|PROBE-A-REPLAY\|no longer responding\|Filesystem has been shut down\|Corruption\|BUG:\|Oops' | cut -c1-500; echo KMSG_END"
done
# host ms of a kernel line of node n: its [uptime] through the node's CLK line,
# then the node's clock offset
kms() {  # kms <node> <kernel seconds>
    local f="$OUT/$1_kmsg.txt" w u
    read -r _ w u < <(grep -a '^CLK ' "$f" | head -1)
    python3 -c "print(int(round($w - ($u - $2) * 1000 - $(clock_off "$1"))))"
}
R=""; RC_LINE=""
for n in "${SURV[@]}"; do
    l=$(grep -a "P163-RECOVERY-COMPLETE slot=${SLOT[$V]} " "$OUT/${n}_kmsg.txt" | tail -1)
    [ -n "$l" ] && { R=$n; RC_LINE=$l; }
done
[ -n "$R" ] || { echo "  no survivor logged P163-RECOVERY-COMPLETE for $V's slot ${SLOT[$V]}"; fails=$((fails+1)); }
if [ -n "$R" ]; then
    rc_k=$(sed -n 's/^\[ *\([0-9.]*\)\].*/\1/p' <<<"$RC_LINE")
    total=$(grep -aoE 'total=[0-9]+' <<<"$RC_LINE" | cut -d= -f2)
    T_RC=$(kms "$R" "$rc_k")
    T_ENTRY=$(( T_RC - total ))
    echo "STAGE replayer $R: recovery complete at host ms $T_RC (+$(( T_RC - T_KILL )) ms after the kill), ladder entry $T_ENTRY (total=$total)"
    # the AGs the replay wrote: PROBE-A on the replayer between the kill and the ladder entry,
    # PROBE-A-REPLAY where the module reports a replay's image apart (probe_a_replay_apart)
    REPLAY_AGS=$(grep -a 'PROBE-A AG-META-WRITE-NOT-HELD\|PROBE-A-REPLAY' "$OUT/${R}_kmsg.txt" | while read -r line; do
        k=$(sed -n 's/^\[ *\([0-9.]*\)\].*/\1/p' <<<"$line"); t=$(kms "$R" "$k")
        [ "$t" -ge "$T_KILL" ] && [ "$t" -le "$T_ENTRY" ] && grep -aoE 'agno=[0-9]+' <<<"$line" | cut -d= -f2
    done | sort -un | tr '\n' ' ')
    echo "STAGE AGs the replay wrote (PROBE-A on $R): [${REPLAY_AGS}]; its PROBE-A lines recov=1 $(cnt "$OUT/${R}_kmsg.txt" 'PROBE-A AG-META-WRITE-NOT-HELD.* recov=1') recov=0 $(cnt "$OUT/${R}_kmsg.txt" 'PROBE-A AG-META-WRITE-NOT-HELD.* recov=0') replay $(cnt "$OUT/${R}_kmsg.txt" 'PROBE-A-REPLAY')"
fi

# ---- 6. the verdict
exposed=0; early=0; bad=0; tot=0; maxms=0
for j in 0 1 2; do
    n=${SURV[$j]}
    off=$(clock_off "$n")
    while read -r _ i t0 t1 rc; do
        tot=$((tot+1)); [ "$rc" = 0 ] || bad=$((bad+1))
        h0=$(( t0 - off )); h1=$(( t1 - off ))
        [ $((t1 - t0)) -gt $maxms ] && maxms=$((t1 - t0))
        [ -n "$R" ] && [ "$n" != "$R" ] || continue
        inrep=""
        for a in ${AGOF[$i]}; do
            case " $REPLAY_AGS " in *" $a "*) inrep="$inrep $a" ;; esac
        done
        [ -n "$inrep" ] || continue
        if [ "$h0" -lt "$T_ENTRY" ]; then
            exposed=$((exposed+1))
            if [ "$h1" -lt $(( T_ENTRY - ERR_MS )) ]; then
                early=$((early+1))
                echo "  EARLY $n truncated f$i (AG${inrep}) by host ms $h1, $(( T_ENTRY - h1 )) ms before the replay's ladder entry"
            fi
        fi
    done < <(grep -a '^OP ' "$OUT/${n}_trunc.txt")
done
echo "STAGE truncates: $tot of $NF, failed=$bad, in a replayed AG issued during the replay by a non-replayer: $exposed, completed before it ended: $early"
echo "max_stall_ms=$maxms"
if [ -n "$R" ] && [ "$exposed" = 0 ]; then
    echo "  no survivor other than the replayer changed an AG the replay was writing, so nothing here tests the exclusion"
    echo "RESULT: VACUOUS label=$LABEL stage=no-overlap wall=$(el)s evidence=$OUT"
    exposed_vac=1
else
    exposed_vac=0
    [ -n "$R" ] && echo "EXPOSED: $exposed truncate(s) by live survivors in AGs [$REPLAY_AGS] were issued while $R replayed $V's slice"
fi
ck "every survivor truncate was captured" "$tot" "$NF"
ck "every truncate returned 0" "$bad" 0
ck "no live survivor changed a replayed AG before the replay ended" "$early" 0
[ -n "$R" ] && ck "$R reported its replay's AG header images apart (PROBE-A-REPLAY), none as an unheld write" \
    "$(cnt "$OUT/${R}_kmsg.txt" 'PROBE-A AG-META-WRITE-NOT-HELD.* recov=1')" 0
for n in "${SURV[@]}"; do
    # a node that is not replaying writes an AG header only under its own grant
    [ "$n" = "$R" ] || ck "$n (not the replayer) wrote no AG header without its grant" \
        "$(cnt "$OUT/${n}_kmsg.txt" 'PROBE-A AG-META-WRITE-NOT-HELD')" 0
    ck "$n did not shut down" "$(cnt "$OUT/${n}_kmsg.txt" 'Filesystem has been shut down\|Corruption')" 0
    ck "$n: zero BUG / Oops" "$(cnt "$OUT/${n}_kmsg.txt" '[^E]BUG:\|^BUG:\|Oops')" 0
done
# the volume, offline
for n in "${SURV[@]}"; do
    measure "$n" 70 "$OUT/${n}_umount.txt" '^UMOUNT_RC=' "$n's unmount" "timeout 60 umount $MNT; echo UMOUNT_RC=\$?"
    ck "$n unmounted" "$(field "$OUT/${n}_umount.txt" UMOUNT_RC)" 0
done
measure "${SURV[0]}" 180 "$OUT/chk.txt" '^CHK_RC=' "chk_mxfs of the volume" \
    "timeout 170 /src/$(basename "$PWD")/tools/chk_mxfs -n $DEV > /tmp/fragag_chk.txt 2>&1; echo CHK_RC=\$?; tail -5 /tmp/fragag_chk.txt"
ck "chk_mxfs finds the volume clean" "$(field "$OUT/chk.txt" CHK_RC)" 0
scripts/lab_power.sh up "$V" > "$OUT/victim_up.txt" 2>&1 || echo "  INFO $V did not come back up: $(tail -1 "$OUT/victim_up.txt")"

[ "$exposed_vac" = 1 ] && [ $fails = 0 ] && exit 3
if [ $fails = 0 ]; then
    echo "LAP foreign_replay_ag PASS: $exposed live truncate(s) in replayed AGs all waited for the replay ($R, $(( T_ENTRY - T_KILL )) ms after the kill); chk clean"
else
    echo "LAP foreign_replay_ag FAIL: $fails check(s) failed (exposed=$exposed early=$early failed_ops=$bad replayer=${R:-none})"
fi
echo "RESULT: $( [ $fails = 0 ] && echo PASS || echo FAIL ) label=$LABEL fails=$fails wall=$(el)s evidence=$OUT"
[ $fails = 0 ]
