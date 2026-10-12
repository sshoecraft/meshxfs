#!/bin/bash
# vm_stall_probe.sh — does preparing a rig node for a mount stall it?
#
# DRBD declares its link lost when a PingAck is 0.5 s late (ping-timeout 5).
# On the six-resource DRBD rig a link fell in exactly the window where
# tests/setup/prep_node.sh brings mxfs.ko to the node: the 88 MB module copied
# from /src over NFS, md5sum'd, then insmod'ed.  This replays those steps on
# NODE, one at a time, while OBSERVER pings NODE every 50 ms, and reports per
# step the longest gap between two replies and how many went unanswered.  A
# gap past 500 ms inside a step is a stall that alone would cost a DRBD link.
#
# Usage: tests/vm_stall_probe.sh <node> <observer>
#   NODE must have no MXFS mounted (the module is loaded and unloaded).
# Env:   PROBE_MODARGS  the insmod arguments (default "force_transport=1";
#                       prep_node.sh's tcp set is "force_transport=1
#                       target_cache_protected=1 log_repeat_limit=0 dyndbg=+p")
#        PROBE_LOADS    how many load/unload cycles (default 1)
# With DRBD resources connected between the two nodes, every link either side
# lost during the probe is listed too ("PingAck did not arrive", a peer that
# shut its meta connection, Connected -> a failure state).
# Evidence: tests/evidence/vm_stall_probe/<UTC stamp>-<node>/
#
# Budget: each step's native cost (an 88 MB NFS copy over the lab bridge
# ~1-2 s, md5sum < 1 s, insmod a few s, rmmod < 1 s) twice over, and 3 s of
# idle before and after as the control: the whole run is bounded at 60 s.
set -u
cd "$(dirname "$0")/.."
REPO=$PWD
. "$REPO/tools/mxfs_lab.sh"
SSH="$REPO/tools/mxfs_sshpass.sh"
NODE=${1:?usage: tests/vm_stall_probe.sh <node> <observer>}
OBS=${2:?usage: tests/vm_stall_probe.sh <node> <observer>}
NA=$(lab_addr "$NODE"); OA=$(lab_addr "$OBS")
OUT=$REPO/tests/evidence/vm_stall_probe/$(date -u +%Y%m%dT%H%M%SZ)-$NODE
mkdir -p "$OUT"
on() { timeout "$2" "$SSH" "$1" "$3" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$'; }

on "$NA" 15 "grep -q ' mxfs ' /proc/mounts && echo MOUNTED" | grep -q MOUNTED \
    && { echo "ABORT: $NODE has MXFS mounted"; exit 2; }
MODARGS=${PROBE_MODARGS:-force_transport=1}
LOADS=${PROBE_LOADS:-1}
[[ "$LOADS" =~ ^[1-9][0-9]?$ ]] || { echo "PROBE_LOADS is 1..99"; exit 2; }
echo "probe: $NODE observed from $OBS, $LOADS load(s) with [$MODARGS]"
LOSS='PingAck did not arrive|meta connection shut down|conn\( Connected -> (NetworkFailure|BrokenPipe|Timeout)'
for h in "$NA" "$OA"; do on "$h" 15 "dmesg | grep -acE '$LOSS'" > "$OUT/loss_before.$h"; done
# a probe of DRBD links needs links: with none Connected a "no loss" is vacuous
CONN=$(on "$NA" 15 "grep -cE '^ *[0-9]+: cs:Connected ' /proc/drbd 2>/dev/null || echo 0")
echo "DRBD links Connected on $NODE before the probe: $CONN"
[ "${CONN:-0}" -ge 1 ] 2>/dev/null || [ "${PROBE_NO_DRBD:-0}" = 1 ] \
    || { echo "ABORT: no DRBD link Connected on $NODE (PROBE_NO_DRBD=1 to probe without DRBD)"; exit 2; }
# NODE pings OBSERVER for the whole probe, so the replies and the steps are
# stamped by one clock (two VMs' clocks disagree, by seconds after a boot).
# A node that stalls sends nothing while it is stalled: the gap shows on its
# own timeline.
# Each cycle: the load (1.1 s measured without dyndbg), the unload, then 3 s
# so that one DRBD ping interval (ping-int 3) passes after it: ~4.2 s, bounded
# at 6.  Plus 10 s for the copy, md5 and the idle control on either side.
PW=$((10 + 6 * LOADS))
on "$NA" $((PW + 20)) "
    ping -D -i 0.05 -w $PW $OA > /root/vm_stall_probe.ping 2>&1 &
    sleep 1
    st() { echo \"STEP \$1 \$(date +%s.%N)\"; }
    mountpoint -q /src || { mkdir -p /src; timeout 20 mount -t nfs 192.168.120.1:/src /src -o rw,vers=4.1,hard,timeo=600,retrans=2,tcp; }
    rmmod mxfs 2>/dev/null; modprobe libcrc32c 2>/dev/null
    echo 3 > /proc/sys/vm/drop_caches
    st idle0; sleep 3
    st copy; cp -f /src/mxfs/mxfs.ko /root/vm_stall_probe.ko
    st md5; md5sum /root/vm_stall_probe.ko >/dev/null
    for i in \$(seq 1 $LOADS); do
        st insmod; insmod /root/vm_stall_probe.ko $MODARGS || echo INSMOD_FAIL
        st rmmod; rmmod mxfs || echo RMMOD_FAIL
        st after; sleep 3
    done
    st idle1; sleep 3
    st end
    rm -f /root/vm_stall_probe.ko
    kill %1 2>/dev/null; wait" > "$OUT/steps"
for h in "$NA" "$OA"; do
    on "$h" 15 "dmesg --time-format iso | grep -aE '$LOSS' | tail -n +\$(( $(cat "$OUT/loss_before.$h") + 1 ))" > "$OUT/loss.$h"
    echo "DRBD links lost during the probe, seen on $h: $(grep -c . "$OUT/loss.$h")"
    sed 's/^/  /' "$OUT/loss.$h"
done
on "$NA" 15 "cat /root/vm_stall_probe.ping" > "$OUT/ping"
grep -a FAIL "$OUT/steps" && echo "note: a step failed (above)"
python3 -I - "$OUT/steps" "$OUT/ping" <<'PY' | tee "$OUT/result"
import re, sys
steps = [(l.split()[1], float(l.split()[2])) for l in open(sys.argv[1]) if l.startswith("STEP ")]
replies = [float(m.group(1)) for m in (re.match(r"\[(\d+\.\d+)\] \d+ bytes from", l) for l in open(sys.argv[2])) if m]
if len(steps) < 2 or not replies:
    print("NO_DATA steps=%d replies=%d" % (len(steps), len(replies)))
    sys.exit(1)
worst = 0.0
for (name, t0), (_, t1) in zip(steps, steps[1:]):
    inside = [r for r in replies if t0 <= r <= t1]
    edges = [t0] + inside + [t1]
    gap = max(b - a for a, b in zip(edges, edges[1:]))
    expect = int((t1 - t0) / 0.05)
    worst = max(worst, gap) if name not in ("idle0", "idle1", "after") else worst
    print("STEP %-7s %6.2f s  replies %4d of ~%4d  max_gap_ms %6.0f%s" % (
        name, t1 - t0, len(inside), expect, gap * 1000, "  STALL>500ms" if gap > 0.5 else ""))
print("RESULT worst_step_gap_ms=%.0f %s" % (worst * 1000, "STALL" if worst > 0.5 else "no stall past 500 ms"))
PY
echo "evidence: $OUT"
