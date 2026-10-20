#!/bin/bash
# tests/mpath/path_fenced_return.sh — F6 of docs/mpath-verification.md: a
# node is fenced while one of its paths is down, and the path comes back.
#
# A fence removes a node's key from the target, and a key is held per path.
# The path that was down when the fence was issued is the one a fence could
# miss, and the one a node could wrongly put its key back on when it returns.
#
#   1. every node runs the load
#   2. the victim's (last node's) path a is taken down and multipathd fails it
#   3. the victim is frozen (virsh suspend): it stops heartbeating without
#      knowing it, with its mount, its queued I/O and its sessions intact
#   4. the others declare it dead and fence it: the target then holds only
#      their registrations
#   5. the victim's path a is restored, and the victim is thawed
#   6. for 40 s the target is sampled: the victim's key must appear on
#      NEITHER path
#   7. the victim must have stopped by itself, a write on it must be refused
#      and return, and nothing it wrote after the fence may be acknowledged
#   8. the victim unmounts, mounts again as a new incarnation and runs the load
#
# What a PASS claims: the victim's registrations left the target within 110 s
# of the freeze; the others resumed within 60 s of that, their longest stall
# under 120 s with no error; after the thaw the target held exactly the
# others' registrations at every sample; the victim's kernel log shows its
# authority closed or the filesystem shut down, its probe write failed and
# returned, its load ended when told, and no fsynced write it started after
# the fence was acknowledged; it unmounted and remounted (rc 0, 0); no other
# node shut down or withdrew; no double grant; at the end every node is
# registered on both paths, and every acknowledged file, the victim's from
# before the freeze included, reads back with its checksum from another node.
#
# derived time budget: warm-up 20 s + path failure 16-20 s + death window
# 62 s + fence and replay 15-25 s + hold 40 s + stop ~10 s + remount ~20 s +
# load 20 s + stop, verify and audit ~10 s per node: about 260 s at 2 nodes.
set -u
ROW=path_fenced_return
. "$(dirname "$0")/lib.sh"
main() {
[ "$N" -ge 2 ] || { why="needs 2 nodes, got $N"; finish FAIL "nodes=$N"; exit 1; }
PF_DEATH=1
PF_STOPS=$V
OTHERS=$(for n in $NODES; do [ "$n" = "$V" ] || printf '%s ' "$n"; done)
pf_start_gate
pf_load_start
trap 'timeout 30 $VIRSH resume "$V" >/dev/null 2>&1; stop_loads "$NODES"; links_all_up; kmsg_keep; kmsg_stop' EXIT

# 2. one path down
link "$V" a down
s=$SECONDS; one=0
while [ $((SECONDS - s)) -lt 40 ]; do
    state "$V" a_failed
    [ "$(usable "$OUT/state_${V}_a_failed.txt")" = 1 ] && { one=1; break; }
    sleep 2
done
ck "multipathd failed $V's path a (within 40 s)" "$one" 1

# 3. frozen
# PF_FREEZE_KNOBS="name=value ...": test-only module parameters written on the
# victim only, immediately before it is frozen, so a one-shot injection (e.g. a
# parked log write, dbg_admit_park_site=log dbg_admit_park_ms=<ms>) is in
# flight across the freeze and the fence.  Read back into knobs_freeze.txt; a
# parameter that did not take fails the row, which would have measured
# something else.
if [ -n "${PF_FREEZE_KNOBS:-}" ]; then
    for kv in $PF_FREEZE_KNOBS; do
        echo "$V ${kv%%=*} want=${kv#*=} got=$(rs 15 "$V" "echo ${kv#*=} > /sys/module/mxfs/parameters/${kv%%=*} && cat /sys/module/mxfs/parameters/${kv%%=*}" 2>/dev/null | tr -d '\r\n')" >> "$OUT/knobs_freeze.txt"
    done
    ck "$V took PF_FREEZE_KNOBS ($PF_FREEZE_KNOBS)" "$(awk '{w=$3; g=$4; sub(/^want=/,"",w); sub(/^got=/,"",g); if (w != g) bad++} END {print bad+0}' "$OUT/knobs_freeze.txt")" 0
fi
# PF_FREEZE_WRITER=<depth>: the victim keeps <depth> 1 MiB O_DIRECT writes in
# flight to a preallocated file on the mount from 3 s before the freeze, so
# commands are queued at the target when the fence's PREEMPT AND ABORT aborts
# them.  A target that aborts them without answering (SCST's iSCSI driver
# does, whatever the Control mode page's TAS bit says) leaves them outstanding
# on the victim, and its unmount at the rejoin
# waits on them.  The writer runs 20 s of guest time (the guest clock stands
# still while it is frozen): ~5 s before the freeze and ~15 s after the thaw,
# well before the rejoin, so whatever it still holds at the rejoin the layer
# below held.
if [ -n "${PF_FREEZE_WRITER:-}" ]; then
    # recorded for the evidence: TAS (Control mode page byte 5, 0x40) as this
    # node's paths read it, page bytes after an 8-byte header (DBD)
    rs 20 "$V" "for p in \$(ls /sys/block/\$(basename \$(readlink -f /dev/mapper/mpatha))/slaves); do echo \"\$p \$(timeout 5 sg_modes -d --page=0x0a -r /dev/\$p 2>/dev/null | od -An -tx1 -v | tr -s ' \n' ' ')\"; done" > "$OUT/freeze_tas.txt" 2>&1
    tasl=""
    while read -r p pl; do
        read -r -a pb <<<"$pl"
        if [ "${#pb[@]}" -ge 14 ]; then tasl+="$p tas=$(( (0x${pb[13]} & 0x40) ? 1 : 0 )); "; else tasl+="$p tas=?; "; fi
    done < "$OUT/freeze_tas.txt"
    echo "  INFO the target's TAS as $V's paths read it before the freeze: $tasl"
    # the writer alone goes to the background: `a && b &` would background the
    # list in a subshell holding the ssh channel until fio exits
    rs 30 "$V" "f=/mnt/shared/pf_freeze_writer_$V; fallocate -l 1G \$f && { nohup setsid fio --name=pfw --filename=\$f --rw=randwrite --bs=1M --iodepth=$PF_FREEZE_WRITER --ioengine=libaio --direct=1 --size=1G --time_based --runtime=20 --continue_on_error=all --output=/run/pf_freeze_writer.txt < /dev/null > /run/pf_freeze_writer.out 2>&1 & echo started; }" > "$OUT/freeze_writer.txt" 2>&1
    ck "$V started the freeze writer (depth $PF_FREEZE_WRITER)" "$(grep -c '^started' "$OUT/freeze_writer.txt")" 1
    sleep 2
    rs 15 "$V" "for p in \$(ls /sys/block/\$(basename \$(readlink -f /dev/mapper/mpatha))/slaves); do echo \$p \$(cat /sys/block/\$p/inflight); done; ps -o pid= -C fio | wc -l" > "$OUT/freeze_writer_inflight.txt" 2>&1
    echo "  INFO $V just before the freeze, per path 'reads writes' in flight, then fio processes: $(tr '\n' ';' < "$OUT/freeze_writer_inflight.txt")"
fi
T0=$(now_ms)
tools/lun_pool.sh fault timeout 30 $VIRSH suspend "$V" >/dev/null 2>&1
ck "$V is frozen" "$($VIRSH domstate "$V" 2>/dev/null | head -1)" paused
echo "  INFO $V frozen at $(date -u +%T) with its path a down"

# 4. fenced
tf=$(pf_wait_keys $(( 2 * (N - 1) )) 110 fenced)
cklt "the others fenced $V: its registrations left the target, seconds after the freeze" "$tf" 111
TF=$(now_ms)
rr=$(pf_resumed "$TF" 60 "$OTHERS")
cklt "every other node's load completed operations again after the fence, seconds" "$rr" 61

# 5. the dead path returns, then the node.  The frozen node's clock stops
# with it, so "after the fence" on its own log is "after the last operation
# it logged before it was frozen" (its log cannot have moved since).
sleep 2
TV=$(( $(pf_last_op_ms "$V") + 1000 ))
link "$V" a up
timeout 30 $VIRSH resume "$V" >/dev/null 2>&1
TT=$(now_ms)
ck "$V is running again" "$($VIRSH domstate "$V" 2>/dev/null | head -1)" running
echo "  INFO $V thawed at $(date -u +%T) with its path a restored"

# 6. refused on both paths
pf_keys_hold $(( 2 * (N - 1) )) 40 after_thaw
state "$V" after_thaw
echo "  INFO $V's paths 40 s after the thaw: $(grep -a '^PATH' "$OUT/state_${V}_after_thaw.txt" | sed 's/reads=.*//' | tr '\n' ' ')"
PF_BOUND_MS=$DEATH_BOUND_MS pf_window fence "$T0" "$(now_ms)" "$OTHERS"

# 7. it stopped
pf_victim_stopped fenced "$TV"
# its clock lost the frozen time; put it right before its new incarnation's
# load is placed against this host's clock, and before the next row
clock_resync "$V" || { why="$V's clock could not be stepped after its thaw"; finish ABORT "stage=clock-resync"; exit 2; }

# 8. a new incarnation
pf_remount "$V" rejoin
[ "$fails" = 0 ] || { finish FAIL "stage=rejoin"; exit 1; }
ru=$(wait_usable "$V" rejoined_paths)
cklt "$V is on 2 usable paths again, seconds" "$ru" 61
pf_load_start "$V"
keys rejoined
ck "every node is registered on both paths once $V is back ($(( 2 * N )))" "$(grep -c . "$OUT/keys_rejoined.txt")" "$(( 2 * N ))"

pf_load_stop "$OTHERS"
stop_loads "$V"
i=0; while [ $i -lt 45 ] && ! grep -aq '^PATHLOAD ' "$OUT/load_$V/run.out" 2>/dev/null; do sleep 1; i=$((i + 1)); done
pl=$(grep -a '^PATHLOAD ' "$OUT/load_$V/run.out" 2>/dev/null | tail -1)
echo "  INFO $V after rejoining: ${pl:-no PATHLOAD line}"
[ -n "$pl" ] || pf_stuck_capture "$V"
ck "$V's load after rejoining completed operations and returned no error" "$(echo "$pl" | grep -c ' err=0 ')" 1
ck "$V: the mutual-exclusion witness saw no double grant after rejoining" "$(sed -n 's/.*double_grant=\([0-9]*\).*/\1/p' <<<"$pl")" 0
PF_VERIFY_ON=$V pf_verify "$OTHERS"
PF_VERIFY_ON=$W pf_verify "$V"
PF_NO_KEYCMP=1 pf_health
pf_done "victim=$V fenced_s=$tf resumed_s=$rr other_stall_ms=$(stall_of fence "$W")"
}
main 2>&1 | tee "$OUT/row.log"
exit "${PIPESTATUS[0]}"
