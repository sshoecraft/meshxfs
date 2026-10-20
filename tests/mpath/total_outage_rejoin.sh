#!/bin/bash
# tests/mpath/total_outage_rejoin.sh — a fenced node rejoins a cluster whose
# only other member lost its storage and fenced itself meanwhile: does the
# rejoin mount finish, and how long does it take?
#
# Measured on 2/net/mesh/mpath (lap frke3, run 20261019T191249Z-g2e,
# D-FENCED-NODE-SYNC-WEDGED-AND-REJOIN-TIMED-OUT-AFTER-TOTAL-STORAGE-LOSS): the
# row had test18 frozen and fenced when a target-wide storage suspension made
# the survivor test17 fence itself (AUTHORITY_LEASE_EXPIRED); test18's rejoin
# mount after its thaw ran out the row's 45 s bound (rc=124) and a later sync
# waited on its superblock.  Its log ended 64 s into the mount on
# P-BOOT-SCAN-FROZEN 'TOTAL OUTAGE: 2 victim(s)' and P-BOOT-CLAIMED, the
# designed bootstrap of a cluster with no live member (scan window 62.5 s),
# and the capture stopped there.  This row makes that shape on purpose and
# keeps watching until the mount returns:
#
#   1. two nodes, the load on both
#   2. V (the last node) is frozen; S (the first) declares it dead and fences it
#   3. both of S's storage paths are muted (every command hangs, as at a
#      suspended target) until S's kernel log shows it closed its authority
#      or fenced itself, then unmuted
#   4. V is thawed; its clock is stepped back to the host's
#   5. V unmounts and mounts again, timed, with its kernel log followed
#      throughout; then a sync on V, bounded
#   6. S unmounts and mounts again, joining V
#   7. the load on both for 20 s; every file each node acknowledged before
#      the outage, and after the rejoin, reads back from the other
#
# A PASS: V's rejoin mount returned rc 0 within its derived bound, the sync
# after it returned, S rejoined, both loads after the rejoin completed
# operations with no error and no double grant, every acknowledged file reads
# back with its checksum, and at the end both nodes are registered on both
# paths.  V's mount time and its P-BOOT lines are reported whatever the
# verdict.
#
# derived time budget: warm-up 20 s + death window 62 s + fence and replay
# 15-25 s + S's lease running out (measured 29 s after the outage began) +
# V's rejoin: umount ~5 s, a total-outage bootstrap scan of 62.5 s by design,
# recovery of both slices 15-25 s, mount ~10 s (bound 100 s) + sync + S's
# rejoin ~20 s + load 20 s + read-back ~30 s: about 330 s at 2 nodes.
#
# Run directly on a prepared 2/net/mesh/mpath cluster:
#   MXFS_NODES=2 MXFS_NODE_LIST=test17,test18 MXFS_CONFIG=2/net/mesh/mpath \
#     PF_KEEP_KMSG=1 tests/mpath/total_outage_rejoin.sh
set -u
ROW=total_outage_rejoin
. "$(dirname "$0")/lib.sh"
S=$W
# V's rejoin mount: scan window 62.5 s + replay of both slices 25 s + mount 10 s
TO_MOUNT_BOUND_MS=${TO_MOUNT_BOUND_MS:-100000}
kgrep() {  # <node> <ERE>: count of matching lines in its followed log since the mark
    rsx 30 "$1" "sed -n '/$PFMARK/,\$p' $KFILE 2>/dev/null | grep -acE -- '$2'; echo COUNT_READ" | grep -aE '^[0-9]+$' | tail -1
}
load_end() {  # <node>: tell its load to stop and wait for its report (45 s)
    local i=0
    stop_loads "$1"
    while [ $i -lt 45 ] && ! grep -aq '^PATHLOAD ' "$OUT/load_$1/run.out" 2>/dev/null; do sleep 1; i=$((i + 1)); done
    echo "  INFO $1's load: $(grep -a '^PATHLOAD ' "$OUT/load_$1/run.out" 2>/dev/null | tail -1)"
    ck "$1's load ended when told (no operation of it is hung)" "$(grep -ac '^PATHLOAD ' "$OUT/load_$1/run.out" 2>/dev/null)" 1
    mv "$OUT/load_$1/run.out" "$OUT/load_$1/run_outage.out" 2>/dev/null
    mv "$OUT/load_$1/manifest" "$OUT/load_$1/manifest_outage" 2>/dev/null
}
main() {
[ "$N" = 2 ] || { why="needs exactly 2 nodes, got $N"; finish FAIL "nodes=$N"; exit 1; }
PF_DEATH=1
pf_start_gate
pf_load_start
trap 'timeout 30 $VIRSH resume "$V" >/dev/null 2>&1; for k in a b; do scripts/san_net.sh mute "$S" $k off >/dev/null 2>&1; done; stop_loads "$NODES"; links_all_up; kmsg_keep; kmsg_stop' EXIT

# 2. V frozen, fenced by S
tools/lun_pool.sh fault timeout 30 $VIRSH suspend "$V" >/dev/null 2>&1
ck "$V is frozen" "$($VIRSH domstate "$V" 2>/dev/null | head -1)" paused
echo "  INFO $V frozen at $(date -u +%T)"
tf=$(pf_wait_keys 2 110 fenced "$S")
cklt "$S fenced $V: its registrations left the target, seconds after the freeze" "$tf" 111
[ "$fails" = 0 ] || { finish FAIL "stage=fence"; exit 1; }

# 3. S's storage hangs until S stops itself
for k in a b; do scripts/san_net.sh mute "$S" "$k" on >> "$OUT/links.log" || { why="could not mute $S's path $k"; finish FAIL "stage=mute"; exit 1; }; done
TM=$(now_ms)
echo "  INFO $S's paths muted at $(date -u +%T)"
s=$SECONDS; st=0
while [ $((SECONDS - s)) -lt 90 ]; do
    [ "${st:-0}" -gt 0 ] 2>/dev/null && break
    sleep 3
    st=$(kgrep "$S" 'AUTHORITY_LEASE_EXPIRED|P131-SELF-FENCE|P290-AUTH-CLOSED|P-WITHDRAW|hutting down filesystem')
done
echo "  INFO $S stopped itself $((SECONDS - s)) s after its paths were muted (lines: ${st:-unread})"
for k in a b; do scripts/san_net.sh mute "$S" "$k" off >> "$OUT/links.log" || { why="could not unmute $S's path $k"; finish FAIL "stage=unmute"; exit 1; }; done
ck "$S closed its authority or fenced itself while its storage hung (within 90 s)" "$([ "${st:-0}" -gt 0 ] 2>/dev/null && echo yes || echo no)" yes
[ "$fails" = 0 ] || { finish FAIL "stage=outage"; exit 1; }
ru=$(wait_usable "$S" unmuted)
cklt "$S is on 2 usable paths again, seconds" "$ru" 61

# 4. V thawed
timeout 30 $VIRSH resume "$V" >/dev/null 2>&1
ck "$V is running again" "$($VIRSH domstate "$V" 2>/dev/null | head -1)" running
echo "  INFO $V thawed at $(date -u +%T), $(( ($(now_ms) - TM) / 1000 )) s after $S's storage was muted"
clock_resync "$V" || { why="$V's clock could not be stepped after its thaw"; finish ABORT "stage=clock-resync"; exit 2; }
load_end "$V"
load_end "$S"

# 5. V rejoins a cluster with no live member
measure "$V" 400 "$OUT/remount_${V}_rejoin.txt" '^REMOUNT umount_rc=[0-9]+ mount_rc=[0-9]+ ms=[0-9]+ mounted=[01]$' "the rejoin of $V" \
    "s=\$(date +%s%3N); timeout 40 umount $MNT; u=\$?; m0=\$(date +%s%3N); timeout 300 mount -t mxfs $MOPT $DEV $MNT; m=\$?; e=\$(date +%s%3N); grep -q ' $MNT mxfs ' /proc/mounts && k=1 || k=0; echo MOUNT_MS=\$((e-m0)); echo REMOUNT umount_rc=\$u mount_rc=\$m ms=\$((e-s)) mounted=\$k"
mms=$(sed -n 's/^MOUNT_MS=\([0-9]*\)$/\1/p' "$OUT/remount_${V}_rejoin.txt" | head -1)
echo "  INFO $V: $(grep -a '^REMOUNT ' "$OUT/remount_${V}_rejoin.txt" | head -1) mount_ms=${mms:-?}"
rsx 30 "$V" "sed -n '/$PFMARK/,\$p' $KFILE 2>/dev/null | grep -aE 'P-BOOT-|RECOVERY_COMPLETE|recovery complete' | cut -c1-240 | tail -40; echo BOOT_READ" > "$OUT/boot_$V.txt"
sed 's/^/  BOOT /' "$OUT/boot_$V.txt" | grep -v 'BOOT_READ$'
ck "$V's rejoin unmounted and mounted (rc 0, 0)" "$(grep -a '^REMOUNT ' "$OUT/remount_${V}_rejoin.txt" | head -1 | sed 's/ ms=[0-9]*//')" "REMOUNT umount_rc=0 mount_rc=0 mounted=1"
cklt "$V's rejoin mount into a cluster with no live member, ms" "${mms:-999999}" "$TO_MOUNT_BOUND_MS"
measure "$V" 40 "$OUT/sync_$V.txt" '^SYNC rc=[0-9]+ ms=[0-9]+$' "a sync on $V" "s=\$(date +%s%3N); timeout 30 sync; r=\$?; echo SYNC rc=\$r ms=\$((\$(date +%s%3N)-s))"
ck "a sync on $V after its rejoin returned (rc 0, within 30 s)" "$(grep -a '^SYNC ' "$OUT/sync_$V.txt" | head -1 | sed 's/ ms=[0-9]*//')" "SYNC rc=0"
[ "$fails" = 0 ] || { finish FAIL "stage=rejoin"; exit 1; }

# 6. S joins V
measure "$S" 100 "$OUT/remount_${S}_join.txt" '^REMOUNT umount_rc=[0-9]+ mount_rc=[0-9]+ ms=[0-9]+ mounted=[01]$' "the rejoin of $S" \
    "s=\$(date +%s%3N); timeout 40 umount $MNT; u=\$?; timeout 45 mount -t mxfs $MOPT $DEV $MNT; m=\$?; e=\$(date +%s%3N); grep -q ' $MNT mxfs ' /proc/mounts && k=1 || k=0; echo REMOUNT umount_rc=\$u mount_rc=\$m ms=\$((e-s)) mounted=\$k"
echo "  INFO $S: $(grep -a '^REMOUNT ' "$OUT/remount_${S}_join.txt" | head -1)"
ck "$S unmounted and joined $V (rc 0, 0)" "$(grep -a '^REMOUNT ' "$OUT/remount_${S}_join.txt" | head -1 | sed 's/ ms=[0-9]*//')" "REMOUNT umount_rc=0 mount_rc=0 mounted=1"
[ "$fails" = 0 ] || { finish FAIL "stage=join"; exit 1; }

# 7. both run again; every acknowledged file, before the outage and after
ru=$(wait_usable_all rejoined 60)
cklt "both nodes are on 2 usable paths again, seconds" "$ru" 61
keys rejoined
ck "both nodes are registered on both paths ($(( 2 * N )))" "$(grep -c . "$OUT/keys_rejoined.txt")" "$(( 2 * N ))"
for n in $NODES; do mv "$OUT/load_$n/manifest_outage" "$OUT/load_${n}_outage.manifest" 2>/dev/null; done
pf_load_start
pf_load_stop
pf_verify
for n in $NODES; do
    o=$S; [ "$n" = "$S" ] && o=$V
    rsx 120 "$o" "python3 /src/mxfs/tests/mpath/pathload.py verify /src/mxfs/$OUT/load_${n}_outage.manifest" > "$OUT/verify_${n}_outage_on_$o.txt"
    capture_require "$OUT/verify_${n}_outage_on_$o.txt" '^VERIFY files=[0-9]+ ' "the read-back of $n's files from before the outage on $o"
    vl=$(grep -a '^VERIFY ' "$OUT/verify_${n}_outage_on_$o.txt" | tail -1)
    echo "  INFO $n's files from before the outage, read on $o: $vl"
    f=$(sed -n 's/.*files=\([0-9]*\).*/\1/p' <<<"$vl"); acked=$((acked + ${f:-0}))
    ck "$n acknowledged files before the outage (> 0) and $o reads every one with its checksum" "$([ "${f:-0}" -gt 0 ] && echo "$vl" | grep -q " ok=$f bad=0 missing=0" && echo yes || echo no)" yes
done
states end
for n in $NODES; do ck "$n ends on 2 usable paths" "$(usable "$OUT/state_${n}_end.txt")" 2; done
pf_done "victim=$V survivor=$S fenced_s=$tf rejoin_mount_ms=${mms:-?}"
}
main 2>&1 | tee "$OUT/row.log"
exit "${PIPESTATUS[0]}"
