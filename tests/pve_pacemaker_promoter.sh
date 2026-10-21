#!/bin/bash
# pve_pacemaker_promoter.sh — GitHub issue #3 on the tester's own stack: a
# Proxmox VE pair on MXFS-over-DRBD where Pacemaker also manages DRBD (a
# promotable ocf:linbit:drbd clone promoting both nodes, as the tester's
# p_drbd-clone did), running the boot program as it was before 0.90.132
# refused that setup.  Participant 0 is then shut down on purpose
# (`systemctl poweroff`), as proxmox01 was.
#
# What it answers: on the guide's setup participant 1 carries on through a
# clean shutdown of participant 0 (tests/pve_pair_failover.sh p0-poweroff).
# The issue's log shows participant 1 restarted and then waited for
# participant 0.  Does Pacemaker managing DRBD turn the clean shutdown into a
# loss that participant 1 loses on the tie-break?  The script measures and
# reports; it grades nothing about the hypothesis:
#     RESULT: OBSERVED p1_restarted=<0|1> p1_fence_lines=<n> p0_down_s=<s> ...
# and keeps both hosts' journals around the shutdown.  It fails (RESULT: FAIL)
# only when it cannot set up or measure, or when the pair does not come back
# whole on this tree's boot program after Pacemaker is removed.
#
# Usage: PVE_PAIR="<addr> <addr>" CONTROL=<boot program> \
#        PVE_POWER_ON='virsh -c qemu:///system start {name}' tests/pve_pacemaker_promoter.sh
#   CONTROL      the mxfs-drbd-fence-self to run during the measurement: the one
#                before the fix (the fixed one refuses to start under Pacemaker)
#   RES / MNT    DRBD resource and mount point (default mxfs, /mnt/shared)
# The pair must be up as tests/pve_pair_failover.sh requires.  Virtual
# machines only: the hosts are powered off and on.  Pacemaker runs with
# stonith-enabled=false (the nested pair has no fence device for it) and
# no-quorum-policy=ignore: the tester's proxmox02 was quorate alone after its
# restart, and a pair whose lone node loses quorum would add a Pacemaker stop
# on participant 1 that their cluster did not have.
#
# Evidence: tests/evidence/pve_pacemaker_promoter/<UTC stamp>/
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSHP="$REPO/tools/mxfs_sshpass.sh"
read -r -a PAIR <<<"${PVE_PAIR:?PVE_PAIR=\"<addr> <addr>\"}"
[ "${#PAIR[@]}" = 2 ] || { echo "PVE_PAIR must name two hosts"; exit 2; }
CONTROL=${CONTROL:?CONTROL=<the boot program to measure>}
[ -s "$CONTROL" ] || { echo "CONTROL=$CONTROL is not a file"; exit 2; }
: "${PVE_POWER_ON:?PVE_POWER_ON=<command that powers a host on, {name} = its name>}"
RES=${RES:-mxfs}
MNT=${MNT:-/mnt/shared}
# apt: Pacemaker 3 and its libraries from Debian (~15 MB), and dpkg
APT_BUDGET=300
# From pacemaker's start to both nodes online: corosync is already up, the
# DC election waits dc-deadtime (20 s): ~25 s, twice over, rounded up.
ONLINE_BUDGET=60
# From the clone's creation to both nodes Promoted: a probe and a promote on
# each, seconds; the cluster-recheck interval (10 s) bounds a retry.
PROMOTE_BUDGET=60
# From `systemctl poweroff` to the host off.  On the guide's setup 18 s
# (p0-poweroff, 0.90.132).  Here Pacemaker stops its resources first, and a
# demote it cannot complete (MXFS holds the device) escalates on its own
# clock, so this is the observation bound, not a prediction: a host still up
# at it is reported as such, with its state.
POWEROFF_BUDGET=600
# How long participant 1 is watched once participant 0 is off: a loss is
# noticed within 2 x ping-int + ping-timeout (~7 s), a lost tie-break restarts
# the host 10 s after it; three times that.
HOLD_S=60
BOOT_BUDGET=300
# From this tree's units started on both to both mounted (MOUNT_BUDGET of
# scripts/pve_pair_update.sh), and once more for a host that restarted and
# waits for its peer.
REJOIN_BUDGET=600
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
EVID="$REPO/tests/evidence/pve_pacemaker_promoter/$STAMP"
mkdir -p "$EVID" || exit 1
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$EVID/log"; }
die() { say "RESULT: FAIL $*"; exit 1; }
on() {  # <host> <cmd> [timeout]
    timeout "${3:-60}" "$SSHP" "$1" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$'
    return "${PIPESTATUS[0]}"
}
if python3 -I -c 'import ipaddress, sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]) < ipaddress.ip_address(sys.argv[2]) else 1)' "${PAIR[0]}" "${PAIR[1]}"; then
    P0=${PAIR[0]}; P1=${PAIR[1]}
else
    P0=${PAIR[1]}; P1=${PAIR[0]}
fi
STATE_CMD='dev=$(drbdadm sh-dev '"$RES"' 2>/dev/null)
m=$(awk -v d="$dev" '\''$1 == d && $3 == "mxfs" {print $2}'\'' /proc/mounts | head -1)
echo "unit=$(systemctl is-active mxfs-drbd@'"$RES"') mnt=${m:-none} role=$(drbdadm role '"$RES"' 2>/dev/null) cs=$(drbdadm cstate '"$RES"' 2>/dev/null) ds=$(drbdadm dstate '"$RES"' 2>/dev/null) boot=$(cat /proc/sys/kernel/random/boot_id)"'
state() { on "$1" "$STATE_CMD" 20 | grep '^unit='; }
field() { sed -n "s/.* $2=\([^ ]*\).*/\1/p; s/^$2=\([^ ]*\).*/\1/p" <<<"$1" | head -1; }
pair_ok() {
    [ "$(field "$1" unit)" = active ] && [ "$(field "$1" mnt)" = "$MNT" ] \
        && [ "$(field "$1" role)" = Primary/Primary ] && [ "$(field "$1" cs)" = Connected ] \
        && [ "$(field "$1" ds)" = UpToDate/UpToDate ]
}
for h in "$P0" "$P1"; do
    [ "$(on "$h" 'systemd-detect-virt --vm' 15 | tail -1)" != none ] || die "$h is not a virtual machine"
    s=$(state "$h"); pair_ok "$s" || die "$h is not up as half of the pair: ${s:-no answer}"
done
declare -A NAME
NAME[$P0]=$(on "$P0" hostname 10); NAME[$P1]=$(on "$P1" hostname 10)
say "pacemaker promoter: participant 0 $P0 (${NAME[$P0]}), participant 1 $P1 (${NAME[$P1]}); control $CONTROL (sha256 $(sha256sum "$CONTROL" | cut -c1-16)); evidence $EVID"

# Pacemaker on both, on Proxmox's own corosync, promoting DRBD on both
for h in "$P0" "$P1"; do
    on "$h" "dpkg -s pacemaker >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive timeout $APT_BUDGET apt-get -y -q install pacemaker >/dev/null 2>&1; dpkg-query -W pacemaker; command -v cibadmin >/dev/null && echo PKG_OK" $((APT_BUDGET + 30)) > "$EVID/pkg.$h"
    grep -q PKG_OK "$EVID/pkg.$h" || die "pacemaker on $h: $(tail -2 "$EVID/pkg.$h" | tr '\n' ' ')"
done
for h in "$P0" "$P1"; do
    timeout 30 "$SSHP" "$h" "cat > /usr/sbin/mxfs-drbd-fence-self.new && chmod 755 /usr/sbin/mxfs-drbd-fence-self.new && mv /usr/sbin/mxfs-drbd-fence-self.new /usr/sbin/mxfs-drbd-fence-self" < "$CONTROL" \
        || die "installing the control program on $h"
done
for h in "$P0" "$P1"; do on "$h" "rm -f /var/lib/pacemaker/cib/cib*; systemctl start pacemaker && echo STARTED" 60 | grep -q STARTED || die "pacemaker start on $h"; done
out=$(on "$P0" "for i in \$(seq 1 $ONLINE_BUDGET); do crm_mon -1 2>/dev/null | grep -q 'Online: \[ ${NAME[$P0]} ${NAME[$P1]} \]\|Online: \[ ${NAME[$P1]} ${NAME[$P0]} \]' && break; sleep 1; done
    crm_mon -1 2>&1 | grep -a 'Online:'
    crm_attribute -t crm_config -n stonith-enabled -v false && crm_attribute -t crm_config -n start-failure-is-fatal -v false &&
    crm_attribute -t crm_config -n no-quorum-policy -v ignore &&
    crm_attribute -t crm_config -n cluster-recheck-interval -v 10s &&
    cibadmin --create --scope resources --xml-text '<clone id=\"p_drbd-clone\"><meta_attributes id=\"p_drbd-clone-meta\"><nvpair id=\"p_drbd-clone-promotable\" name=\"promotable\" value=\"true\"/><nvpair id=\"p_drbd-clone-pmax\" name=\"promoted-max\" value=\"2\"/><nvpair id=\"p_drbd-clone-pnmax\" name=\"promoted-node-max\" value=\"1\"/><nvpair id=\"p_drbd-clone-cmax\" name=\"clone-max\" value=\"2\"/><nvpair id=\"p_drbd-clone-cnmax\" name=\"clone-node-max\" value=\"1\"/><nvpair id=\"p_drbd-clone-notify\" name=\"notify\" value=\"true\"/></meta_attributes><primitive id=\"p_drbd\" class=\"ocf\" provider=\"linbit\" type=\"drbd\"><instance_attributes id=\"p_drbd-params\"><nvpair id=\"p_drbd-res\" name=\"drbd_resource\" value=\"$RES\"/></instance_attributes><operations><op id=\"p_drbd-mon-p\" name=\"monitor\" interval=\"29s\" role=\"Promoted\"/><op id=\"p_drbd-mon-u\" name=\"monitor\" interval=\"31s\" role=\"Unpromoted\"/></operations></primitive></clone>' && echo RES_OK
    for i in \$(seq 1 $PROMOTE_BUDGET); do crm_mon -1 2>/dev/null | grep -qE 'Promoted: \[ [^ ]+ [^ ]+ \]' && break; sleep 1; done
    crm_mon -1 2>&1 | grep -aE 'Promoted|Unpromoted|Stopped|Failed' | tr -s ' '" $((ONLINE_BUDGET + PROMOTE_BUDGET + 60)))
echo "$out" > "$EVID/pacemaker_setup"
grep -q RES_OK <<<"$out" || die "pacemaker resources: $(tail -3 <<<"$out" | tr '\n' ' ')"
grep -qE 'Promoted: \[ [^ ]+ [^ ]+ \]' <<<"$out" || die "Pacemaker did not promote DRBD $RES on both within ${PROMOTE_BUDGET}s: $(tail -3 <<<"$out" | tr '\n' ' ')"
say "  Pacemaker promotes DRBD $RES on both: $(grep -a 'Promoted' <<<"$out" | head -1)"
for h in "$P0" "$P1"; do s=$(state "$h"); pair_ok "$s" || die "$h is no longer half of the pair under Pacemaker: $s"; done

# a fsynced set on each, for the read-back after
declare -A SUM
for h in "$P0" "$P1"; do
    SUM[$h]=$(on "$h" "d=$MNT/pcmkprom/$STAMP/\$(hostname); mkdir -p \$d && for i in \$(seq 1 32); do head -c 65536 /dev/urandom > \$d/f\$i; done && sync -f \$d && cd \$d && md5sum f* | sort -k2 | md5sum | cut -c1-32" 60)
    [ ${#SUM[$h]} = 32 ] || die "$h could not write its fsynced set: ${SUM[$h]}"
done
b0=$(field "$(state "$P0")" boot); b1=$(field "$(state "$P1")" boot)
say "  sets fsynced on both; shutting $P0 (participant 0) down cleanly"
t0=$(date +%s)
on "$P0" "nohup setsid sh -c 'sleep 1; systemctl poweroff' >/dev/null 2>&1 < /dev/null & echo POWERING_OFF" 15 | grep -q POWERING_OFF || die "could not power $P0 off"
down_s=""
for i in $(seq 1 "$POWEROFF_BUDGET"); do
    ping -c 1 -W 1 "$P0" >/dev/null 2>&1 || { down_s=$(( $(date +%s) - t0 )); break; }
    sleep 1
done
[ -n "$down_s" ] || { say "  $P0 still answers ${POWEROFF_BUDGET}s after systemctl poweroff: $(state "$P0")"; down_s=never; }
say "  $P0 off after ${down_s} s"
p1_restarted=0; first=""
for i in $(seq 1 $((HOLD_S / 5))); do
    s=$(state "$P1")
    if [ -n "$s" ] && [ "$(field "$s" boot)" != "$b1" ]; then p1_restarted=1; break; fi
    [ -z "$s" ] && [ -z "$first" ] && first=$(( $(date +%s) - t0 ))
    sleep 5
done
if [ "$p1_restarted" = 0 ] && [ -n "$first" ]; then
    # it stopped answering: a restart in progress
    for i in $(seq 1 $((BOOT_BUDGET / 5))); do
        s=$(state "$P1"); [ -n "$s" ] && { [ "$(field "$s" boot)" != "$b1" ] && p1_restarted=1; break; }
        sleep 5
    done
fi
say "  $P1 after ${HOLD_S}s: restarted=$p1_restarted (stopped answering at +${first:-never} s): ${s:-no answer}"
[ "$down_s" = never ] || timeout $((BOOT_BUDGET + 60)) bash -c "${PVE_POWER_ON//\{name\}/${NAME[$P0]}}" >>"$EVID/log" 2>&1 || die "could not power $P0 on"
for i in $(seq 1 $((BOOT_BUDGET / 5))); do
    b=$(on "$P0" 'cat /proc/sys/kernel/random/boot_id' 10 | grep -E '^[0-9a-f-]{36}$')
    [ -n "$b" ] && [ "$b" != "$b0" ] && break
    sleep 5
done
[ -n "${b:-}" ] && [ "$b" != "$b0" ] || [ "$down_s" = never ] || die "$P0 did not answer within ${BOOT_BUDGET}s of its power-on"
# both hosts' journals around the shutdown: the boot that ended and the one since
for h in "$P0" "$P1"; do
    for bb in -1 0; do
        on "$h" "journalctl -b $bb --no-pager -o short-iso --since @$((t0 - 60)) | grep -aE 'mxfs|drbd|pacemaker|crmd|controld|execd|fenced|schedulerd|corosync|systemd.*(Stopp|Reached target|Shutting)' | cut -c1-400" 60 > "$EVID/journal.$h.b$bb"
    done
done
fence_lines=$(cat "$EVID/journal.$P1.b-1" "$EVID/journal.$P1.b0" 2>/dev/null | grep -acE 'TIEBREAK|loses the|lost its peer|fence-peer|restarting')
p0_demote=$(grep -acE 'p_drbd_demote|demote.*(error|fail)|Device is held open|State change failed' "$EVID/journal.$P0.b-1" 2>/dev/null)
say "RESULT: OBSERVED p1_restarted=$p1_restarted p1_fence_lines=$fence_lines p0_down_s=$down_s p0_demote_lines=$p0_demote (journals: $EVID/journal.*)"

# Pacemaker out, this tree's boot program back, both units again
for h in "$P0" "$P1"; do
    on "$h" "crm_attribute -t crm_config -n maintenance-mode -v true >/dev/null 2>&1; sleep 2; systemctl disable -q --now pacemaker 2>/dev/null; rm -f /var/lib/pacemaker/cib/cib*; systemctl is-active -q pacemaker && echo STILL_UP || echo PCMK_DOWN" 120 | grep -q PCMK_DOWN || say "  pacemaker would not stop on $h"
    timeout 30 "$SSHP" "$h" "cat > /usr/sbin/mxfs-drbd-fence-self.new && chmod 755 /usr/sbin/mxfs-drbd-fence-self.new && mv /usr/sbin/mxfs-drbd-fence-self.new /usr/sbin/mxfs-drbd-fence-self" < "$REPO/tools/mxfs_drbd_fence_self.py" \
        || die "restoring this tree's boot program on $h"
done
for h in "$P0" "$P1"; do on "$h" "systemctl reset-failed mxfs-drbd@$RES 2>/dev/null; systemctl restart --no-block mxfs-drbd@$RES; echo RESTARTED" 30 > /dev/null; done
t1=$(date +%s); ok=0
while [ $(( $(date +%s) - t1 )) -lt "$REJOIN_BUDGET" ]; do
    s0=$(state "$P0"); s1=$(state "$P1")
    pair_ok "$s0" && pair_ok "$s1" && { ok=1; break; }
    sleep 5
done
[ "$ok" = 1 ] || die "the pair did not come back whole within ${REJOIN_BUDGET}s of Pacemaker's removal: $P0 ${s0:-no answer}; $P1 ${s1:-no answer}"
say "  Pacemaker removed, this tree's boot program on both: the pair whole again in $(( $(date +%s) - t1 )) s"
for r in "$P0" "$P1"; do
    for w in "$P0" "$P1"; do
        got=$(on "$r" "cd $MNT/pcmkprom/$STAMP/${NAME[$w]} && md5sum f* | sort -k2 | md5sum | cut -c1-32" 60)
        [ "$got" = "${SUM[$w]}" ] || die "$r reads $w's fsynced set differently: ${got:-no sum} (written ${SUM[$w]})"
    done
done
say "  every fsynced file of both hosts intact on both"
say "pacemaker promoter: done (RESULT above)"
