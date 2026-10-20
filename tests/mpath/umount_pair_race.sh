#!/bin/bash
# tests/mpath/umount_pair_race.sh — the last two nodes of a net/mesh cluster
# unmount together, and the second is still releasing its grants when the
# first has gone.
#
# Measured on 8/net/mesh/mpath (0.90.53, chk_clean unmount judged stuck): the
# later node's shutdown release-all sent each of its ~938 grants to the peer
# that had already left, three attempts 100 ms apart per grant, ~62 s.  Since
# 0.90.54 a master a release could not reach is sent nothing more by that
# release-all (P-RELALL-UNREACHABLE); dl_relall_skip_unreachable=0 is the
# same-build control.
#
# The race is made certain rather than waited for: B (the last node) sleeps
# dl_relall_step_ms after each release of its release-all, so its release-all
# outlasts A's whole unmount, which starts PF_GAP_S later.
#
#   tests/mpath/lap_chain.sh row <N>/net/mesh/mpath <group> <run> tests/mpath/umount_pair_race.sh \
#       --budget 300 --knobs "dl_relall_skip_unreachable=1"     (0 for the control)
#
# THE INCIDENT NEEDS TWO MORE THINGS (its first A/B, uprab on 4/net/mesh/mpath,
# reached neither: B's release-all held 4-5 grants and no send failed).
# PF_HOLD_FILES=N: after the load A creates N empty files in a fresh directory
# and syncs, and B stats every one (a PR grant each) and drops its caches; a
# clean, wire-confirmed PR grant is retained across eviction while the
# filesystem is not unmounting (xfs/xfs_mxfs_evict.c, P6R-RETAIN), so B holds
# about N grants at its release-all, about half of them mastered by A on two
# nodes (the incident's test7 held 938).  PF_GOODBYE_DELAY_MS=D sets B's
# one-shot dbg_goodbye_rx_delay_ms (dlm/v5_mount.c, the GOODBYE case): B's
# receive thread for A sleeps D ms before processing A's GOODBYE, so B's
# release-all sends to a peer that has gone without B having registered its
# departure (the incident's test7 never logged test13's goodbye).  B's DLM
# teardown joins that receive thread (dlm/peer.c, the peer shutdown's join), so
# B's unmount includes the delay in BOTH arms: the unmount bound becomes the
# larger of the release-all's stepping and D, plus the slack, and the arms are
# told apart by B's P-RELALL-WALL (ms, send_failed, skipped), which the row
# reports and bounds on its own: a release-all may take its stepping plus 5 s,
# never 200 ms of retries per grant.
#
# What a PASS claims: B's unmount returned within its bound, and A's within its
# own; B's P-RELALL-WALL line reports the release-all, and its wall is within
# its stepping plus 5 s.  The row leaves both nodes unmounted; the next step must
# prep the group.
#
# derived time budget: gate + warm-up 20 s + load 30 s + stop/verify ~15 s +
# B's stepped release-all (grants x step, ~1000 x 20 ms = 20 s) + slack 30 s
# + readback ~10 s: ~150 s; --budget 300.  With PF_HOLD_FILES=1000 add the
# creates and stats (~30 s) and with PF_GOODBYE_DELAY_MS=60000 the delay (60 s,
# overlapping the release-all): ~240 s, still inside 300.
set -u
ROW=umount_pair_race
. "$(dirname "$0")/lib.sh"
LOAD_S=${PF_LOAD_S:-30}
STEP_MS=${PF_STEP_MS:-20}
GAP_S=${PF_GAP_S:-2}
SLACK_S=${PF_UMOUNT_SLACK_S:-30}
HOLD=${PF_HOLD_FILES:-0}
GDELAY=${PF_GOODBYE_DELAY_MS:-0}
main() {
[ "$N" -ge 2 ] || { why="needs 2 nodes, got $N"; finish FAIL "nodes=$N"; exit 1; }
A=$W; B=$V
pf_start_gate
pf_load_start
sleep "$LOAD_S"
pf_load_stop
pf_verify
if [ "$HOLD" -gt 0 ]; then
    HD=$MNT/upr_hold.$RUN
    rsx 180 "$A" "mkdir -p $HD && cd $HD && for i in \$(seq 1 $HOLD); do : > f\$i; done && sync && echo HOLD_MADE=\$(ls $HD | wc -l)" > "$OUT/hold_$A.txt"
    capture_require "$OUT/hold_$A.txt" '^HOLD_MADE=' "the hold files' create on $A"
    ck "$A made the hold files" "$(sed -n 's/^HOLD_MADE=//p' "$OUT/hold_$A.txt" | tail -1)" "$HOLD"
    rsx 180 "$B" "n=0; for i in \$(seq 1 $HOLD); do stat -c %i $HD/f\$i > /dev/null 2>&1 && n=\$((n+1)); done; sync; echo 3 > /proc/sys/vm/drop_caches; echo HOLD_STATTED=\$n" > "$OUT/hold_$B.txt"
    capture_require "$OUT/hold_$B.txt" '^HOLD_STATTED=' "the hold files' stats on $B"
    ck "$B stat'ed every hold file" "$(sed -n 's/^HOLD_STATTED=//p' "$OUT/hold_$B.txt" | tail -1)" "$HOLD"
fi
echo "$B dl_relall_step_ms want=$STEP_MS got=$(rs 15 "$B" "echo $STEP_MS > /sys/module/mxfs/parameters/dl_relall_step_ms && cat /sys/module/mxfs/parameters/dl_relall_step_ms" | tr -d '\r\n')" >> "$OUT/knobs.txt"
ck "$B took dl_relall_step_ms=$STEP_MS" "$(awk -v b="$B" '$1 == b && $2 == "dl_relall_step_ms" {print $4}' "$OUT/knobs.txt" | tail -1)" "got=$STEP_MS"
if [ "$GDELAY" -gt 0 ]; then
    echo "$B dbg_goodbye_rx_delay_ms want=$GDELAY got=$(rs 15 "$B" "echo $GDELAY > /sys/module/mxfs/parameters/dbg_goodbye_rx_delay_ms && cat /sys/module/mxfs/parameters/dbg_goodbye_rx_delay_ms" | tr -d '\r\n')" >> "$OUT/knobs.txt"
    ck "$B took dbg_goodbye_rx_delay_ms=$GDELAY" "$(awk -v b="$B" '$1 == b && $2 == "dbg_goodbye_rx_delay_ms" {print $4}' "$OUT/knobs.txt" | tail -1)" "got=$GDELAY"
fi
[ "$fails" = 0 ] || { finish FAIL "stage=knobs"; exit 1; }
# B first, A PF_GAP_S later; each unmount timed on its own node, bounded
rsx 200 "$B" "s=\$(date +%s%3N); timeout 180 umount $MNT; r=\$?; echo UMOUNT node=$B rc=\$r ms=\$((\$(date +%s%3N)-s))" > "$OUT/umount_$B.txt" &
pb=$!
sleep "$GAP_S"
rsx 200 "$A" "s=\$(date +%s%3N); timeout 180 umount $MNT; r=\$?; echo UMOUNT node=$A rc=\$r ms=\$((\$(date +%s%3N)-s))" > "$OUT/umount_$A.txt" &
pa=$!
wait "$pa" "$pb"
for n in $A $B; do
    capture_require "$OUT/umount_$n.txt" '^UMOUNT node=' "the unmount of $n"
    echo "  INFO $(grep -a '^UMOUNT ' "$OUT/umount_$n.txt" | tail -1)"
done
rsx 30 "$B" "sed -n '/$PFMARK/,\$p' $KFILE | grep -aE 'P-RELALL-WALL|P-RELALL-UNREACHABLE|P-RELALL-MASTER-UNREACHABLE|P-DBG-GOODBYE-RX-DELAY|P-GOODBYE-RX ' | cut -c1-240; echo FAILED_SENDS=\$(sed -n '/$PFMARK/,\$p' $KFILE | grep -ac 'lock release to node .* failed'); echo READ_DONE" > "$OUT/relall_$B.txt"
capture_require "$OUT/relall_$B.txt" '^READ_DONE$' "the release-all lines of $B"
cat "$OUT/relall_$B.txt" | sed 's/^/  INFO /'
wall=$(sed -n 's/.*P-RELALL-WALL released=\([0-9]*\) ms=\([0-9]*\).*/\1 \2/p' "$OUT/relall_$B.txt" | tail -1)
rel=${wall%% *}; rms=${wall##* }
sfail=$(sed -n 's/.*P-RELALL-WALL .* send_failed=\([0-9]*\) .*/\1/p' "$OUT/relall_$B.txt" | tail -1)
skipped=$(sed -n 's/.*P-RELALL-WALL .* skipped=\([0-9]*\) .*/\1/p' "$OUT/relall_$B.txt" | tail -1)
gdfired=$(grep -ac 'P-DBG-GOODBYE-RX-DELAY' "$OUT/relall_$B.txt")
ck "$B logged its release-all (P-RELALL-WALL)" "$([ -n "$wall" ] && echo yes || echo no)" yes
ck "$B's unmount returned rc 0" "$(sed -n 's/.* rc=\([0-9]*\) .*/\1/p' "$OUT/umount_$B.txt" | tail -1)" 0
ck "$A's unmount returned rc 0" "$(sed -n 's/.* rc=\([0-9]*\) .*/\1/p' "$OUT/umount_$A.txt" | tail -1)" 0
[ "$GDELAY" -gt 0 ] && ck "$B's GOODBYE delay fired (P-DBG-GOODBYE-RX-DELAY)" "$gdfired" 1
# B's teardown joins the receive thread the GOODBYE delay sleeps on, so the
# unmount may take the delay whatever the release-all did
step_ms=$(( ${rel:-0} * STEP_MS ))
floor=$step_ms; [ "$GDELAY" -gt "$floor" ] && floor=$GDELAY
bound=$(( floor + SLACK_S * 1000 ))
cklt "$B's unmount, ms (the larger of its release-all's stepping ${rel:-?} x ${STEP_MS} ms and the GOODBYE delay ${GDELAY} ms, + ${SLACK_S} s)" "$(sed -n 's/.* ms=\([0-9]*\).*/\1/p' "$OUT/umount_$B.txt" | tail -1)" "$bound"
cklt "$B's release-all, ms (its stepping ${rel:-?} x ${STEP_MS} ms + 5 s: no per-grant retries)" "${rms:-999999999}" "$(( step_ms + 5000 ))"
echo "  INFO release-all wall on $B: ${rms:-?} ms for ${rel:-?} grants, send_failed=${sfail:-?} skipped=${skipped:-?} failed_send_lines=$(sed -n 's/^FAILED_SENDS=//p' "$OUT/relall_$B.txt")"
kmsg_stop
trap - EXIT
links_all_up
finish "$([ "$fails" = 0 ] && echo PASS || echo FAIL)" "released=${rel:-?} relall_ms=${rms:-?} send_failed=${sfail:-?} skipped=${skipped:-?} hold_files=$HOLD goodbye_delay_ms=$GDELAY goodbye_delay_fired=$gdfired b_umount_ms=$(sed -n 's/.* ms=\([0-9]*\).*/\1/p' "$OUT/umount_$B.txt" | tail -1) a_umount_ms=$(sed -n 's/.* ms=\([0-9]*\).*/\1/p' "$OUT/umount_$A.txt" | tail -1) knobs=${PF_KNOBS:-none}"
[ "$fails" = 0 ]
}
main 2>&1 | tee "$OUT/row.log"
exit "${PIPESTATUS[0]}"
