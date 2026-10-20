#!/bin/bash
# tests/scst_reconfig_fault_gate.sh <writer> <idle-lun-id>
#
# Verifies the SCST reconfiguration gate in tools/lun_pool.sh
# (scst_quiet_begin).  A write to an SCST management file suspends every LUN
# on the target until every command already admitted finishes, for up to 90 s.
# A frozen guest's write does not finish, and on 2026-10-19 at 19:14:14Z one
# bind stalled every cluster on the host for 49 s that way.  Every node on the
# host self-fenced.
#
#   1. <writer>, a running guest logged in to its LUN with nothing mounted
#      from it, writes that LUN continuously with O_DIRECT.  This destroys the
#      LUN's contents, so the writer's LUN is freed at the end and its next
#      run binds and formats a LUN afresh.
#   2. The writer is frozen through `tools/lun_pool.sh fault` while a write is
#      in flight.  The writer's sessions at the target must hold at least one
#      active command, or the lap measures nothing (NOREACH).
#   3. `tools/lun_pool.sh free <idle-lun-id>` is run with the gate's wait cut
#      to GATE_S.  The LUN must be the kept LUN of an idle group: its release
#      empties its initiator group, which is an SCST reconfiguration.
#
# PASS when all of these hold:
#   - `faults` names the frozen writer;
#   - the free is refused, naming the writer, within GATE_S + 30 s;
#   - the host kernel log since the mark has no scst_suspend_activity line;
#   - after the thaw, the same free succeeds.
#
# Budget: boot of a powered-off writer (60 s) + write start 5 s + GATE_S
# (20 s) + the release's logouts to powered-off nodes (ssh ConnectTimeout 10 s)
# + 30 s margin for the free's own work.
set -u
cd "$(dirname "$0")/.." || exit 2
X=${1:?usage: $0 <writer> <idle-lun-id>}
IDLE=$(printf %02d "$((10#${2:?usage: $0 <writer> <idle-lun-id>}))")
GATE_S=${GATE_S:-20}
SSH=tools/mxfs_sshpass.sh
VIRSH="virsh -c qemu:///system"
T=/sys/kernel/scst_tgt/targets/iscsi
OUT=tests/evidence/scst_gate_$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUT"
fails=0
ck() { if [ "$2" = "$3" ]; then echo "  PASS $1"; else echo "  FAIL $1 got=$2 want=$3"; fails=$((fails + 1)); fi; }
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null; }

line=$(tools/lun_pool.sh lookup --nodes "$(tools/lun_pool.sh status | awk -v x="$X" '$5 ~ "(^|,)" x "(,|$)" {print $5}' | head -1)")
WID=$(sed -n 's/.* id=\([0-9]*\) .*/\1/p' <<<"$line")
WTGT=$(sed -n 's/.* target=\([^ ]*\) .*/\1/p' <<<"$line")
WDEV=$(sed -n 's/.* dev=\([^ ]*\) .*/\1/p' <<<"$line")
[ -n "$WID" ] && [ -n "$WDEV" ] || { echo "RESULT: ABORT reason=no LUN bound to $X"; exit 1; }
[ "$WID" != "$IDLE" ] || { echo "RESULT: ABORT reason=the idle LUN is the writer's"; exit 1; }
echo "=== scst_reconfig_fault_gate writer=$X lun$WID ($WDEV) idle=lun$IDLE gate=${GATE_S}s out=$OUT"
rs 15 "$X" "grep -c ' mxfs ' /proc/mounts" | grep -qx 0 || { echo "RESULT: ABORT reason=$X has mxfs mounted"; exit 1; }
rs 15 "$X" "test -b $WDEV" || { echo "RESULT: ABORT reason=$X has no $WDEV"; exit 1; }

trap 'timeout 30 $VIRSH resume "$X" >/dev/null 2>&1' EXIT
mark="SCSTGATE-$(date -u +%H%M%S)-$$"
echo "$mark" | sudo tee /dev/kmsg >/dev/null
since=$(date '+%Y-%m-%d %H:%M:%S')
rs 15 "$X" "nohup setsid dd if=/dev/zero of=$WDEV bs=1M count=20000 oflag=direct > /dev/null 2>&1 < /dev/null & echo \$! > /run/scstgate_dd.pid"
sleep 5
tools/lun_pool.sh fault timeout 30 $VIRSH suspend "$X" || { echo "RESULT: ABORT reason=freeze failed"; exit 1; }
sleep 2
act=0
for s in $(sudo ls "$T/$WTGT/sessions" 2>/dev/null | grep -v '^mgmt$'); do
    a=$(sudo cat "$T/$WTGT/sessions/$s/active_commands" 2>/dev/null | head -1)
    echo "  INFO session $s active_commands=${a:-?}"
    act=$((act + ${a:-0}))
done
[ "$act" -ge 1 ] || { echo "RESULT: NOREACH reason=the frozen writer holds no command at the target"; exit 1; }
f=$(tools/lun_pool.sh faults); echo "$f" > "$OUT/faults.txt"
ck "faults names the frozen writer" "$(grep -cx "paused $X" <<<"$f")" 1
t0=$SECONDS
MXFS_SCST_QUIET_WAIT_S=$GATE_S tools/lun_pool.sh free "$IDLE" > "$OUT/free_frozen.txt" 2>&1; rc=$?
el=$((SECONDS - t0))
echo "  INFO free while frozen: rc=$rc ${el}s: $(tail -1 "$OUT/free_frozen.txt")"
ck "free refused while the writer is frozen" "$rc" 1
ck "refusal names the writer" "$(grep -c "paused $X" "$OUT/free_frozen.txt")" 1
[ "$el" -le $((GATE_S + 30)) ] && ck "refused in bound" 1 1 || ck "refused in bound (${el}s)" 0 1
timeout 30 journalctl -k --since "$since" --no-pager > "$OUT/host_kmsg.txt" 2>&1
ck "no target-wide suspend while frozen" "$(grep -c 'scst_suspend_activity\|scst_susp_wait' "$OUT/host_kmsg.txt")" 0
timeout 30 $VIRSH resume "$X" >/dev/null 2>&1
trap - EXIT
rs 30 "$X" "kill \$(cat /run/scstgate_dd.pid) 2>/dev/null; true"
sleep 2
tools/lun_pool.sh free "$IDLE" > "$OUT/free_thawed.txt" 2>&1; rc=$?
echo "  INFO free after thaw: rc=$rc: $(tail -1 "$OUT/free_thawed.txt")"
ck "free succeeds after the thaw" "$rc" 0
tools/lun_pool.sh free "$WID" --force > "$OUT/free_writer.txt" 2>&1
echo "  INFO writer's LUN freed (its contents were overwritten): $(tail -1 "$OUT/free_writer.txt")"
[ "$fails" = 0 ] && echo "RESULT: PASS scst_reconfig_fault_gate (evidence $OUT)" || echo "RESULT: FAIL scst_reconfig_fault_gate fails=$fails (evidence $OUT)"
