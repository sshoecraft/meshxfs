#!/bin/bash
# fuser_guard_lap.sh -- one lap of D-FUSER-KM-WITHOUT-MOUNT-CHECK-IN-CLOSURE-RACE-AND-DRBD-RESOLVE-TEST.
#
# tests/closure_mount_race.sh (the joiner's departure) and scripts/drbd_rig.sh (the resolve
# test's unmount) killed a mount's users with 'fuser -km $MNT' whether or not $MNT was still a
# mount point.  fuser -m on a directory that is not a mount point names every user of the
# filesystem the directory is on, so on a node whose volume was already unmounted it SIGKILLs
# every process on the root filesystem, sshd and the node's daemons with it.  Both now take
# the command from tests/lib/fuser_guard.sh (fuser_mounted_cmd), which runs the kill only while
# the directory is a mount point.  FUSER_MOUNT_GUARD=0 prints the unguarded kill, as before:
# the control (set it for the whole lap).
#
# SHAPE, on one lab node with nothing of the lap's mounted:
#   1. both harnesses are read for any 'fuser -k' left outside fuser_mounted_cmd (a static
#      check: the lap exercises the helper's text, so a site that kept its own command would
#      not be what the lap measures);
#   2. a directory /mnt/fuserlap.<label> that is not a mount point, a sentinel process (sleep,
#      its working directory /) and the main pids of ssh, systemd-journald, systemd-udevd and
#      iscsid are read;
#   3. the command fuser_mounted_cmd prints for that directory is sent to the node, as the
#      harnesses send it;
#   4. the sentinel and the main pids are read again.
#   EXPOSED  the directory was not a mount point when the command ran (the defect's trigger)
#   PASS     the sentinel is alive and every main pid is unchanged
#   FAIL     the sentinel is gone or a main pid changed (or could not be read: the node's ssh
#            went with them); the node is then powered off and on again (scripts/lab_power.sh),
#            since a killed iscsid stays dead and degrades every later step on the node
#   ABORT    the node is not reachable before the command, the directory is a mount point, or
#            a harness still holds an unguarded 'fuser -k'
#
# Bounds (derived): each ssh read 30 s; the command itself 1 s of settle plus the kill, 30 s;
# a node's power-off and on again after a FAIL, 15 s down and 50 s up (lab_power's own
# measured bounds for one guest), doubled: 130 s.  A caller bounds the lap at
# 4 x 30 + 30 + 130 = 280 s.
#
# Usage: tests/fuser_guard_lap.sh <label> <node>
# Exit 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}; NODE=${2:?node}
HERE="$(cd "$(dirname "$0")" && while { [ ! -f run.sh ] || [ ! -f tools/mxfs_lab.sh ]; } && [ "$(pwd)" != / ]; do cd ..; done; pwd)"
[ -f "$HERE/run.sh" ] || { echo "ABORT: no tree root above $0"; exit 2; }
. "$HERE/tools/mxfs_lab.sh"
. "$HERE/tests/lib/fuser_guard.sh"
SSH="$HERE/tools/mxfs_sshpass.sh"
DIR=/mnt/fuserlap.$LABEL
on() { timeout "$3" "$SSH" "$(lab_addr "$1")" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$'; }
echo "LAP fuser_guard start $(date -u +%FT%TZ) label=$LABEL node=$NODE dir=$DIR FUSER_MOUNT_GUARD=${FUSER_MOUNT_GUARD:-(unset)}"

# 1. no harness keeps a kill of its own
left=$(grep -n 'fuser -k' "$HERE/tests/closure_mount_race.sh" "$HERE/scripts/drbd_rig.sh" | grep -v '^\s*#' | grep -v ':[0-9]*:\s*#')
if [ -n "$left" ]; then
    echo "LAP fuser_guard ABORT: a harness still runs a kill of its own: $(tr '\n' '|' <<<"$left" | cut -c1-300)"
    exit 2
fi
echo "STAGE harnesses: no 'fuser -k' outside fuser_mounted_cmd in tests/closure_mount_race.sh, scripts/drbd_rig.sh"

# 2. the directory, the sentinel and the main pids
SVCS="ssh systemd-journald systemd-udevd iscsid"
state() { on "$NODE" "echo SVCPIDS \$(systemctl show -p MainPID --value $SVCS 2>/dev/null | tr '\n' ' '); s=\$(cat /run/fuserlap.$LABEL.pid 2>/dev/null); [ -n \"\$s\" ] && kill -0 \$s 2>/dev/null && echo SENTINEL alive \$s || echo SENTINEL gone \$s" 30; }
pre=$(on "$NODE" "mkdir -p $DIR; mountpoint -q $DIR && echo DIR_MOUNTED || echo DIR_PLAIN; cd / && setsid nohup sleep 600 >/dev/null 2>&1 < /dev/null & echo \$! > /run/fuserlap.$LABEL.pid; sleep 0.5" 30)
grep -q DIR_PLAIN <<<"$pre" || { echo "LAP fuser_guard ABORT: $DIR on $NODE is a mount point or unreadable: $(tr '\n' '|' <<<"$pre" | cut -c1-200)"; exit 2; }
before=$(state)
b_pids=$(grep -a '^SVCPIDS ' <<<"$before" | tail -1); b_sent=$(grep -a '^SENTINEL ' <<<"$before" | tail -1)
[ -n "$b_pids" ] && grep -q 'SENTINEL alive' <<<"$b_sent" || { echo "LAP fuser_guard ABORT: $NODE's state unreadable before the command: $(tr '\n' '|' <<<"$before" | cut -c1-200)"; exit 2; }
echo "EXPOSED: $DIR is not a mount point on $NODE when the cleanup's command runs"

# 3. the command, as the harnesses send it
CMD="$(fuser_mounted_cmd "$DIR" 1) echo CMD_DONE"
echo "  command: $CMD"
on "$NODE" "$CMD" 30 | tail -2 | sed 's/^/  node: /'
sleep 2

# 4. what is left
after=$(state)
a_pids=$(grep -a '^SVCPIDS ' <<<"$after" | tail -1); a_sent=$(grep -a '^SENTINEL ' <<<"$after" | tail -1)
echo "  $NODE main pids of $SVCS: before [${b_pids#SVCPIDS }] after [${a_pids#SVCPIDS }]; ${b_sent} -> ${a_sent:-unreadable}"
on "$NODE" "s=\$(cat /run/fuserlap.$LABEL.pid 2>/dev/null); [ -n \"\$s\" ] && kill \$s 2>/dev/null; rm -f /run/fuserlap.$LABEL.pid; rmdir $DIR 2>/dev/null; true" 30 >/dev/null
if [ "$b_pids" = "$a_pids" ] && grep -q 'SENTINEL alive' <<<"$a_sent"; then
    echo "LAP fuser_guard PASS: the cleanup's command on $DIR (no mount there) left the sentinel and every main pid of $SVCS as they were"
    exit 0
fi
echo "LAP fuser_guard FAIL: the cleanup's command on $DIR (no mount there) ended processes of the root filesystem on $NODE"
echo "  restoring $NODE: powered off and on again"
timeout 30 "$HERE/scripts/lab_power.sh" down "$NODE" >/dev/null 2>&1
timeout 100 "$HERE/scripts/lab_power.sh" up "$NODE" 2>&1 | tail -1 | sed 's/^/  /'
exit 1
