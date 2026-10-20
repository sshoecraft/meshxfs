#!/bin/bash
# tests/pub_claim_fail_ab.sh <configuration> <group> <X> <Y> [laps] [label]
#
# Directed same-build A/B for
# D-SURVIVOR-DEFERRED-PUBLISH-EX-CLAIM-FAILS-AFTER-60-REMASTER-RETRIES-AT-REJOIN.
#
# Measured on 2/net/mesh/mpath after a fenced peer rejoined: the publish drain
# of a directory's release popped a child this node held EX only locally, its
# on-disk EX claim waited out 60 retries on a full ledger page
# (why[capacity=60]) and failed, and the non-routed arm only logged it
# ('deferred-publish CAW EX failed').  The child was then on no list and held
# no grant, while this node kept serving it as EX from the fast path.
#
# Per lap, in D=/mnt/shared/pcf_<label>/<lap>, X = the creator, Y = the peer:
#   X makes D (synced), Y lists it;
#   X writes f (256 KiB of random bytes, not synced), records its md5 and
#     number, and arms dbg_pub_claim_fail_ino=<number>: the first claim
#     attempt of f fails with -EAGAIN without asking the lock layer (the state
#     the measured claims were left in; the switch clears itself);
#   Y lists D and reads f (its md5 and size): the listing takes D from X, X's
#     release of D runs the publish drain over f and the claim fails;
#   Y appends "Y" to f, then X appends "X" to f, both sync;
#   both read f back.
# MODE=drop (the failed claim itself): the arming above; KNOB pub_claim_retry.
#   REACH: X logs 'deferred-publish CAW EX failed ino=<f>' or
#   'P-PUB-CLAIM-RETRY ino=<f>' after the lap's mark.
#   FAIL (per reached lap): X dropped the claim ('deferred-publish CAW EX
#   failed ino=<f>': the child left with no grant and no authority installed,
#   the measured defect), or a read below is wrong.
# MODE=park (default; the claim still waiting when the drain window ends):
#   instead of dbg_pub_claim_fail_ino, both nodes arm dbg_cap_refuse_ino=<f>
#   dbg_cap_refuse_n=CAPN (default 120): the master refuses the next CAPN
#   grants of f as a full ledger page refuses them, through the real path
#   from the commit on (P-DBG-CAP-REFUSE), which keeps X's claim waiting past
#   the drain's 5 s window while Y asks for f; KNOB dl_capacity_park.
#   REACH: X logs P-PUB-CLAIM-INFLIGHT-AT-RELEASE child=<f> (D went to Y with
#   f's claim in flight) and a node logs P-DBG-CAP-REFUSE ino=<f>.
#   FAIL (per reached lap): a read below is wrong (Y granted f before X's
#   claim reads the image X's write guard held back).
# Both modes, every lap: FAIL if Y's first read differs from X's bytes, or the
#   final file differs between the nodes or from X's bytes + "Y" + "X".
#   A lap without REACH did not exercise the arm (NOREACH).
#
# ARMS: KNOB =1 (the fix) then =0 (the control), LAPS each, set on both nodes
# before an arm and read back after it (a module reload in between puts every
# parameter back: the arm is VOID).
#
# Budget per lap: 8 ssh round trips (~0.3 s each), a 256 KiB write, two small
# appends, syncs and md5 reads (native XFS: milliseconds): ~3 s of work; each
# step is bounded at 15 s (a peer read that waits out a lock-retry budget,
# 9 s, still lands inside it); in park mode Y's first read also waits out the
# 5 s drain window and CAPN refusals (~60 ms each: ~8 s), so that step is
# bounded at 25 s.  Prep 300 s (manifest).
set -u
cd "$(dirname "$0")/.." || exit 1
CFG=${1:?configuration}; G=${2:?rig group}; X=${3:?creator node}; Y=${4:?peer node}
LAPS=${5:-6}; LABEL=${6:-pcf}
MODE=${MODE:-park}
CAPN=${CAPN:-120}
case "$MODE" in
  drop) KNOB=${KNOB:-pub_claim_retry};;
  park) KNOB=${KNOB:-dl_capacity_park};;
  *) echo "RESULT ABORT pcf: MODE=$MODE"; exit 2;;
esac
SSH=tools/mxfs_sshpass.sh
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_pcf_$LABEL
mkdir -p "$OUT"
SB=15
SBY=$SB; [ "$MODE" = park ] && SBY=25
echo "=== pub_claim_fail_ab mode=$MODE cfg=$CFG group=$G X=$X Y=$Y laps=$LAPS knob=$KNOB capn=$CAPN tree=$(pwd) sv=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="
MXFS_FORCE_PREP=1 timeout 300 ./run.sh "$CFG" --group "$G" prep_cluster > "$OUT/prep.log" 2>&1
prc=$?
[ "$prc" = 0 ] || { echo "RESULT ABORT pcf: prep rc=$prc ($OUT/prep.log)"; exit 2; }
B=/mnt/shared/pcf_${LABEL}
timeout $SB $SSH "$X" "mkdir -p $B && sync -f $B" > /dev/null 2>&1
void=0; f_fail=0; f_pass=0; c_fail=0; c_pass=0; noreach=0; lapno=0
PARAM=/sys/module/mxfs/parameters
for v in 1 0; do
  tests/fleet_set_params.sh "$KNOB=$v" "$X,$Y" "$OUT/knobs_${v}_set.txt" > /dev/null 2>&1
  for l in $(seq 1 "$LAPS"); do
    lapno=$((lapno + 1))
    D=$B/$lapno
    mark="PCF-MARK-${LABEL}-${lapno}"
    timeout $SB $SSH "$X" "mkdir $D && sync -f $B" > /dev/null 2>&1
    timeout $SB $SSH "$Y" "ls -l $D > /dev/null" > /dev/null 2>&1
    if [ "$MODE" = drop ]; then
      arm="echo \$i > $PARAM/dbg_pub_claim_fail_ino && echo $mark > /dev/kmsg && echo ino=\$i md5=\$(md5sum < /tmp/pcf_src_$lapno | cut -c1-32) armed=\$(cat $PARAM/dbg_pub_claim_fail_ino)"
    else
      arm="echo $CAPN > $PARAM/dbg_cap_refuse_n && echo \$i > $PARAM/dbg_cap_refuse_ino && echo $mark > /dev/kmsg && echo ino=\$i md5=\$(md5sum < /tmp/pcf_src_$lapno | cut -c1-32) armed=\$(cat $PARAM/dbg_cap_refuse_ino)/\$(cat $PARAM/dbg_cap_refuse_n)"
    fi
    xs=$(timeout $SB $SSH "$X" "head -c 262144 /dev/urandom > /tmp/pcf_src_$lapno && cp /tmp/pcf_src_$lapno $D/f && i=\$(stat -c %i $D/f) && $arm" 2>/dev/null | grep '^ino=')
    ino=$(printf '%s\n' "$xs" | sed -n 's/^ino=\([0-9]*\).*/\1/p')
    md5x=$(printf '%s\n' "$xs" | sed -n 's/.* md5=\([0-9a-f]*\).*/\1/p')
    yarm=""
    [ "$MODE" = park ] && [ -n "$ino" ] && yarm=$(timeout $SB $SSH "$Y" "echo $CAPN > $PARAM/dbg_cap_refuse_n && echo $ino > $PARAM/dbg_cap_refuse_ino && echo $mark > /dev/kmsg && echo yarmed=\$(cat $PARAM/dbg_cap_refuse_ino)/\$(cat $PARAM/dbg_cap_refuse_n)" 2>/dev/null | grep '^yarmed=')
    ys1=$(timeout $SBY $SSH "$Y" "ls -l $D > /dev/null; echo md5=\$(md5sum < $D/f | cut -c1-32) size=\$(stat -c %s $D/f)" 2>/dev/null | grep '^md5=')
    timeout $SB $SSH "$Y" "echo Y >> $D/f && sync -f $D" > /dev/null 2>&1
    timeout $SB $SSH "$X" "echo X >> $D/f && sync -f $D" > /dev/null 2>&1
    want=$(timeout $SB $SSH "$X" "( cat /tmp/pcf_src_$lapno; echo Y; echo X ) | md5sum | cut -c1-32; rm -f /tmp/pcf_src_$lapno" 2>/dev/null | grep -E '^[0-9a-f]{32}$')
    fx=$(timeout $SB $SSH "$X" "md5sum < $D/f | cut -c1-32; echo 0 > $PARAM/dbg_pub_claim_fail_ino; echo 0 > $PARAM/dbg_cap_refuse_ino; dmesg | awk -v m='$mark' 'index(\$0, m) { s = 1; next } s' > /tmp/pcf_kmsg_${lapno}.txt; cat /tmp/pcf_kmsg_${lapno}.txt" 2>/dev/null)
    fy=$(timeout $SB $SSH "$Y" "md5sum < $D/f | cut -c1-32" 2>/dev/null | grep -E '^[0-9a-f]{32}$')
    ky=$(timeout $SB $SSH "$Y" "echo 0 > $PARAM/dbg_cap_refuse_ino; dmesg | awk -v m='$mark' 'index(\$0, m) { s = 1; next } s'" 2>/dev/null)
    printf '%s\n' "$xs" "$yarm" "$ys1" "want=$want fy=$fy" "== X kmsg" "$fx" "== Y kmsg" "$ky" > "$OUT/lap${lapno}.txt"
    md5y1=$(printf '%s\n' "$ys1" | sed -n 's/^md5=\([0-9a-f]*\).*/\1/p')
    finx=$(printf '%s\n' "$fx" | grep -m1 -E '^[0-9a-f]{32}$')
    reach=0; dropped=0; refused=0; parked=0; inflight=0
    if [ -n "$ino" ]; then
      dropped=$(printf '%s\n' "$fx" | grep -c "deferred-publish CAW EX failed ino=$ino ")
      refused=$(printf '%s\n' "$fx" "$ky" | grep -c "P-DBG-CAP-REFUSE ino=$ino ")
      parked=$(printf '%s\n' "$fx" "$ky" | grep -c "P-CAP-PARK type=1 ino=$ino ")
      inflight=$(printf '%s\n' "$fx" | grep -c "P-PUB-CLAIM-INFLIGHT-AT-RELEASE .* child=$ino ")
      if [ "$MODE" = drop ]; then
        reach=$(printf '%s\n' "$fx" | grep -c -E "(deferred-publish CAW EX failed|P-PUB-CLAIM-RETRY) ino=$ino ")
      else
        [ "$inflight" -gt 0 ] && [ "$refused" -gt 0 ] && reach=1
      fi
    fi
    regrant=$(printf '%s\n' "$fx" | grep -c "P-PUB-CLAIM-RETRY-GRANTED ino=$ino ")
    verdict=PASS
    [ -n "$md5x" ] && [ "$md5y1" = "$md5x" ] || verdict=FAIL
    [ -n "$want" ] && [ "$finx" = "$want" ] && [ "$fy" = "$want" ] || verdict=FAIL
    [ "$MODE" = drop ] && [ "$dropped" -gt 0 ] && verdict=FAIL
    [ "$reach" -gt 0 ] || { [ "$verdict" = PASS ] && verdict=NOREACH; }
    echo "  LAP $lapno $KNOB=$v ino=${ino:-?} reach=$reach dropped=$dropped refused=$refused parked=$parked inflight_at_release=$inflight regranted=$regrant y_first=$([ "$md5y1" = "$md5x" ] && echo same || echo DIFF:$(printf '%s' "$ys1" | cut -c1-60)) final_x=$([ "$finx" = "$want" ] && echo ok || echo BAD) final_y=$([ "$fy" = "$want" ] && echo ok || echo BAD) verdict=$verdict"
    case "$v:$verdict" in
      1:PASS) f_pass=$((f_pass+1));; 1:FAIL) f_fail=$((f_fail+1));;
      0:PASS) c_pass=$((c_pass+1));; 0:FAIL) c_fail=$((c_fail+1));;
      *:NOREACH) noreach=$((noreach+1));;
    esac
  done
  tests/fleet_set_params.sh "$KNOB" "$X,$Y" "$OUT/knobs_${v}_after.txt" > /dev/null 2>&1
  got=$(grep -c "$KNOB=$v\b" "$OUT/knobs_${v}_after.txt")
  [ "$got" = 2 ] || { echo "  ARM $KNOB=$v VOID: read back on $got of 2 nodes"; void=$((void+1)); }
done
tests/fleet_set_params.sh "$KNOB=1 dbg_pub_claim_fail_ino=0 dbg_cap_refuse_ino=0 dbg_cap_refuse_n=0" "$X,$Y" "$OUT/knobs_restore.txt" > /dev/null 2>&1
echo "  INFO f_pass=$f_pass f_fail=$f_fail c_pass=$c_pass c_fail=$c_fail noreach=$noreach void=$void evidence=$OUT"
[ "$void" = 0 ] || { echo "RESULT ABORT pcf: $void void arm(s)"; exit 2; }
[ "$f_fail" -gt 0 ] && { echo "RESULT REFUTED pcf: fix arm failed $f_fail reached lap(s)"; exit 1; }
[ "$c_fail" -gt 0 ] && { echo "RESULT SUPPORTED pcf: control failed $c_fail, fix passed $f_pass reached lap(s)"; exit 0; }
echo "RESULT NOREACH pcf: the control never failed (reached control laps: $c_pass)"; exit 3
