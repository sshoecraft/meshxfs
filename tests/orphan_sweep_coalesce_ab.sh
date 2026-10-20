#!/bin/bash
# orphan_sweep_coalesce_ab.sh — does a lone remount that meets its own settled
# predecessor sweep the ledger once (orphan_sweep_coalesce=1) or twice (=0)?
# (D-MOUNT-RUNS-THE-ORPHAN-SWEEP-TWICE-BACK-TO-BACK)
#
# THE SHAPE.  A node that unmounts as the LAST member keeps its ledger pages
# under its own authority; when it mounts again alone, its previous
# incarnation is a dead authority settled at mount init
# (P-SETTLED-INCARNATION) and the departure worker takes its pages over
# (P-DEPART-WORK).  The mount queues an orphan sweep behind that departure,
# and the departure asks for another as it ends (dlm/v5_mount.c v5_depart_run
# 'if (!r->orphan_sweep) v5_orphan_sweep_queue'), so before the change every
# such mount swept the whole ledger twice and the second sweep found nothing.
# orphan_sweep_coalesce=1 makes the departure's request join the sweep still
# queued (P-ORPHAN-SWEEP-COALESCED), which the worker's FIFO order starts
# after the departure.
#
# THE LAP.  A fresh prep of <config> on <group>; node A (the group's first)
# creates NFILES files while every node is a member, so the ledger records the
# grants (a lone mount records nothing); every other node unmounts; then
# CYCLES times, alternating the knob 0,1,0,1,...: A unmounts as the last
# member, the knob is set on A and read back, A mounts alone, and the lap
# waits for A's departure worker to go quiet (no P-DEPART-WORK* line for
# QUIET_S s) before reading that mount's lines from A's followed kernel log
# (/root/dmesg.stream, started by the prep).  Both arms run on one build, one
# filesystem and one mount history.
#
# PER MOUNT: settled (P-SETTLED-INCARNATION), departs (P-DEPART-WORK, the
# takeover), sweeps (P-DEPART-WORK-ORPHAN-SWEEP), coalesced
# (P-ORPHAN-SWEEP-COALESCED), each sweep's queued_ms/total_ms and its start
# (line time minus total_ms) against the departure's completion line, and the
# mount and unmount walls.
#
# VERDICT (written before the first lap):
#   CONTROL (knob 0) REPRODUCED  every mount with settled>=1 shows sweeps equal
#                                to its departures plus one (the mount's own)
#                                and coalesced=0.
#   FIX (knob 1) PASS            every mount with settled>=1 shows sweeps=1,
#                                coalesced>=1, and its sweep started after the
#                                departure's completion line (within total_ms's
#                                1 ms resolution).
#   VACUOUS                      no mount had settled>=1 (the shape did not
#                                form).
#   Every mount and unmount must return 0 inside its bound in both arms.
#
# BOUNDS (each step's own, from measured walls x2 or the established
# harnesses' derivations): prep 300 s (tests/noino_gen0_ab.sh); creates
# NFILES x 14 ms under members (tests/depart_takeover_unmount.sh) -> bound
# NFILES/25 + 60 s; each departing node's unmount 120 s and A's last-member
# unmount 180 s (same harness); A's lone mount 180 s (same harness); the quiet
# wait: the takeover of ~NFILES/8 pages at ~30 ms each plus two sweeps of a
# 20 GiB LUN (14.7 s each at 1 TiB, linear) -> bound NFILES/8 x 0.03 x 2 +
# QUIET_S + 60 s; knob set/readback and line reads 20 s each.
#
# Usage: tests/orphan_sweep_coalesce_ab.sh <label> [config=2/net/mesh/direct] [group=g2]
# Env:   NFILES (default 2000), CYCLES (default 6), QUIET_S (default 10)
# Exit 0 PASS, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}
CONFIG=${2:-2/net/mesh/direct}; GROUP=${3:-g2}
NFILES=${NFILES:-2000}; CYCLES=${CYCLES:-6}; QUIET_S=${QUIET_S:-10}
case "$NFILES$CYCLES$QUIET_S" in *[!0-9]*) echo "NFILES, CYCLES and QUIET_S must be numbers"; exit 2 ;; esac
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
MNT=/mnt/shared
NN=${CONFIG%%/*}
read -r -a GN <<< "$(tools/mxfs_lab.sh group "$GROUP")"
[ "${#GN[@]}" -ge "$NN" ] && [ "$NN" -ge 2 ] || { echo "RESULT: ABORT label=$LABEL -- group $GROUP has ${#GN[@]} nodes, $CONFIG needs $NN (>= 2)"; exit 2; }
NODES=("${GN[@]:0:$NN}")
A=${NODES[0]}
. tests/lib/runlock.sh
vmhold_take "orphan_sweep_coalesce_ab $LABEL" "${NODES[@]}" \
    || { echo "RESULT: ABORT label=$LABEL -- could not hold ${NODES[*]}"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_orphan_coalesce_$LABEL
mkdir -p "$OUT"
P=/sys/module/mxfs/parameters
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
t0=$(date +%s); el() { echo $(( $(date +%s) - t0 )); }
echo "=== orphan_sweep_coalesce_ab label=$LABEL $CONFIG $GROUP [${NODES[*]}] nfiles=$NFILES cycles=$CYCLES quiet_s=$QUIET_S build=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 \
    || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }
want=$(modinfo -F srcversion mxfs.ko)
for n in "${NODES[@]}"; do
    info=$(rs 20 "$n" "echo sv=\$(cat /sys/module/mxfs/srcversion) m=\$(grep -c ' $MNT mxfs ' /proc/mounts) knob=\$(cat $P/orphan_sweep_coalesce 2>/dev/null)")
    echo "  INFO $n $info"
    [[ "$info" == *"sv=$want "* ]] || { echo "RESULT: ABORT label=$LABEL -- $n does not run the tree build $want ($info) evidence=$OUT"; exit 2; }
    [[ "$info" == *"m=1 "* ]] || { echo "RESULT: ABORT label=$LABEL -- $n is not mounted after the prep ($info) evidence=$OUT"; exit 2; }
    [[ "$info" == *"knob="[01] ]] || { echo "RESULT: ABORT label=$LABEL -- $n has no orphan_sweep_coalesce knob ($info) evidence=$OUT"; exit 2; }
done
DEV=$(rs 20 "$A" "awk '\$2 == \"$MNT\" && \$3 == \"mxfs\" {print \$1}' /proc/mounts" | head -1)
[ -n "$DEV" ] || { echo "RESULT: ABORT label=$LABEL -- no mxfs device on $A's $MNT evidence=$OUT"; exit 2; }
rs 20 "$A" "test -s /root/dmesg.stream && echo ok" | grep -q ok || { echo "RESULT: ABORT label=$LABEL -- $A has no /root/dmesg.stream (the prep starts it) evidence=$OUT"; exit 2; }

# 1. The authority: NFILES creates on A while every node is a member.
D=$MNT/.osc_$LABEL
cb=$(( NFILES / 25 + 60 ))
rs "$cb" "$A" "mkdir -p '$D' && i=0; s=\$(date +%s%N); while [ \$i -lt $NFILES ]; do : > '$D/f'\$i || break; i=\$((i+1)); done; sync; e=\$(date +%s%N); echo CREATED=\$i ms=\$(( (e-s)/1000000 ))" > "$OUT/create.txt"
created=$(grep -ao 'CREATED=[0-9]*' "$OUT/create.txt" | cut -d= -f2)
echo "  INFO $A created ${created:-0}/$NFILES files under $NN members: $(tr '\n' ' ' < "$OUT/create.txt") at +$(el)s"
[ "${created:-0}" = "$NFILES" ] || { echo "RESULT: ABORT label=$LABEL stage=create -- ${created:-0}/$NFILES inside $cb s evidence=$OUT"; exit 2; }
# 2. Every other node leaves, cleanly, so A is the last member.
for n in "${NODES[@]:1}"; do
    u=$(rs 120 "$n" "s=\$(date +%s%N); umount $MNT; rc=\$?; e=\$(date +%s%N); echo UMOUNT_RC=\$rc ms=\$(( (e-s)/1000000 ))")
    echo "  INFO $n unmounted: ${u:-no result} at +$(el)s"
    [[ "$u" == *"UMOUNT_RC=0 "* ]] || { echo "RESULT: ABORT label=$LABEL stage=depart -- $n's unmount: ${u:-no result in 120 s} evidence=$OUT"; exit 2; }
done

qb=$(( NFILES * 6 / 100 + QUIET_S + 60 ))
ctl_n=0; ctl_ok=0; fix_n=0; fix_ok=0; bound_bad=0
for c in $(seq 1 "$CYCLES"); do
    knob=$(( (c + 1) % 2 ))
    u=$(rs 180 "$A" "s=\$(date +%s%N); umount $MNT; rc=\$?; e=\$(date +%s%N); echo UMOUNT_RC=\$rc ms=\$(( (e-s)/1000000 ))")
    [[ "$u" == *"UMOUNT_RC=0 "* ]] || { echo "  FAIL cycle $c: $A's last-member unmount: ${u:-no result in 180 s}"; bound_bad=$((bound_bad + 1)); break; }
    got=$(rs 20 "$A" "echo $knob > $P/orphan_sweep_coalesce; cat $P/orphan_sweep_coalesce" | tail -1)
    [ "$got" = "$knob" ] || { echo "RESULT: ABORT label=$LABEL -- $A's orphan_sweep_coalesce read '$got', not $knob evidence=$OUT"; exit 2; }
    MARK="OSC-$LABEL-$$-c$c"
    rs 20 "$A" "echo $MARK > /dev/kmsg" > /dev/null
    m=$(rs 180 "$A" "s=\$(date +%s%N); mount -t mxfs $DEV $MNT; rc=\$?; e=\$(date +%s%N); echo MOUNT_RC=\$rc ms=\$(( (e-s)/1000000 ))")
    [[ "$m" == *"MOUNT_RC=0 "* ]] || { echo "  FAIL cycle $c: $A's lone mount: ${m:-no result in 180 s}"; bound_bad=$((bound_bad + 1)); break; }
    # the worker is done: its departure line and at least one sweep line are
    # in, and no worker line (P-DEPART-WORK*, or the P-TAUTH-* lines a
    # takeover or sweep prints per page) for QUIET_S s, inside qb.  Counting
    # only P-DEPART-WORK lines (osc4a) read a takeover still retiring pages
    # as quiet, and the next unmount cut it and its sweep short, so every
    # later sweep retired the earlier incarnations' leftover pages instead.
    q=$(rs "$qb" "$A" "last=\$(date +%s); prev=-1; while :; do s=\$(awk '/$MARK/{f=1} f' /root/dmesg.stream | grep -a 'P-DEPART-WORK\|P-TAUTH-'); n=\$(printf '%s\n' \"\$s\" | grep -c .); d=\$(printf '%s\n' \"\$s\" | grep -c 'P-DEPART-WORK node='); w=\$(printf '%s\n' \"\$s\" | grep -c 'P-DEPART-WORK-ORPHAN-SWEEP '); now=\$(date +%s); if [ \"\$n\" != \"\$prev\" ]; then prev=\$n; last=\$now; elif [ \$d -ge 1 ] && [ \$w -ge 1 ] && [ \$((now - last)) -ge $QUIET_S ]; then echo QUIET lines=\$n; break; fi; sleep 1; done")
    [[ "$q" == QUIET* ]] || { echo "  FAIL cycle $c: $A's departure worker did not go quiet inside $qb s"; bound_bad=$((bound_bad + 1)); break; }
    rs 20 "$A" "awk '/$MARK/{f=1} f' /root/dmesg.stream | grep -a 'P-SETTLED-INCARNATION \|P-DEPART-WORK\|P-ORPHAN-SWEEP-COALESCED\|P-TAUTH-ORPHAN-SWEEP \|P-TAUTH-TAKEOVER'" > "$OUT/cycle${c}_k${knob}.txt"
    f="$OUT/cycle${c}_k${knob}.txt"
    settled=$(grep -ac 'P-SETTLED-INCARNATION ' "$f"); departs=$(grep -ac 'P-DEPART-WORK node=' "$f")
    sweeps=$(grep -ac 'P-DEPART-WORK-ORPHAN-SWEEP ' "$f"); coal=$(grep -ac 'P-ORPHAN-SWEEP-COALESCED ' "$f")
    # each line's kernel time; a sweep's start is its time minus total_ms.
    # total_ms is whole milliseconds, so the start is known to 1 ms: osc4b's
    # fix sweeps came out 0.52 and 0.18 ms "before" the departure line they
    # followed on the same worker thread.  Compare within that resolution.
    dep_t=$(grep -a 'P-DEPART-WORK node=' "$f" | tail -1 | sed -n 's/^\[ *\([0-9.]*\)\].*/\1/p')
    first_start=$(grep -a 'P-DEPART-WORK-ORPHAN-SWEEP ' "$f" | head -1 | sed -n 's/^\[ *\([0-9.]*\)\].* total_ms=\([0-9]*\).*/\1 \2/p' | awk '{printf "%.6f", $1 - $2 / 1000}')
    after=na
    [ -n "$dep_t" ] && [ -n "$first_start" ] && after=$(awk -v a="$first_start" -v b="$dep_t" 'BEGIN { print (a >= b - 0.001) ? 1 : 0 }')
    echo "  cycle $c knob=$knob umount: ${u#UMOUNT_RC=} mount: ${m#MOUNT_RC=} settled=$settled departs=$departs sweeps=$sweeps coalesced=$coal sweep_start_after_depart=$after $(grep -ao 'P-DEPART-WORK-ORPHAN-SWEEP rc=[-0-9]* queued_ms=[0-9]* total_ms=[0-9]*' "$f" | sed 's/P-DEPART-WORK-ORPHAN-SWEEP //' | paste -sd'|')"
    grep -a 'P-TAUTH-ORPHAN-SWEEP ' "$f" | sed 's/^/      /' | cut -c1-220
    [ "$settled" -ge 1 ] || continue
    if [ "$knob" = 0 ]; then
        # the mount's own sweep plus one more per settled departure (osc4b
        # cycle 1: two settled departures, three sweeps)
        ctl_n=$((ctl_n + 1)); [ "$departs" -ge 1 ] && [ "$sweeps" = $((departs + 1)) ] && [ "$coal" = 0 ] && ctl_ok=$((ctl_ok + 1))
    else
        fix_n=$((fix_n + 1)); [ "$departs" -ge 1 ] && [ "$sweeps" = 1 ] && [ "$coal" -ge 1 ] && [ "$after" = 1 ] && fix_ok=$((fix_ok + 1))
    fi
done
REP="control_mounts=$ctl_n control_two_sweeps=$ctl_ok fix_mounts=$fix_n fix_one_sweep=$fix_ok bound_failures=$bound_bad"
if [ "$bound_bad" != 0 ]; then
    echo "RESULT: FAIL orphan_sweep_coalesce_ab label=$LABEL $REP -- a mount or unmount failed or overran its bound evidence=$OUT"; exit 1
fi
if [ "$ctl_n" = 0 ] && [ "$fix_n" = 0 ]; then
    echo "RESULT: VACUOUS orphan_sweep_coalesce_ab label=$LABEL $REP -- no lone remount met a settled predecessor evidence=$OUT"; exit 3
fi
if [ "$fix_n" -gt 0 ] && [ "$fix_ok" = "$fix_n" ]; then
    echo "RESULT: PASS orphan_sweep_coalesce_ab label=$LABEL $REP control_reproduced=$([ "$ctl_n" -gt 0 ] && [ "$ctl_ok" = "$ctl_n" ] && echo 1 || echo 0) evidence=$OUT"; exit 0
fi
echo "RESULT: FAIL orphan_sweep_coalesce_ab label=$LABEL $REP evidence=$OUT"; exit 1
