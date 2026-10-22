#!/bin/bash
# fourkn_lun_shutdown_probe.sh -- does a node logged in to the 4K-native LUN by
# tests/fourkn_lun.sh shut down within scripts/lab_power.sh's bound, and when
# it does not, what holds it?
#
# WHY.  After the two-node merge laps (tests/fourkn_merge_2node.sh), test31 and
# test32 both overran lab_power.sh's 90 s ACPI-shutdown bound and were
# destroyed.  Their journals end with lvm2-monitor.service's stop (vgchange
# --monitor n) started and never finished, after systemd had stopped iscsid and
# the network with the session to the LUN still logged in: fourkn_lun.sh logs a
# node in by hand, so open-iscsi.service, whose stop logs every session out
# before the network goes, was never active on them.  The target closed both
# sessions for want of a reply a minute later.  One node put in that state by
# hand, with nothing else run on it, shut down in 9 s: the state alone did not
# account for the hang.
#
# WHAT IT DOES.  With both nodes logged in to the LUN:
#   - records, per node, the state the shutdown starts from: open-iscsi.service,
#     the iSCSI sessions, LVM's device hints (a devs_hash count that is not the
#     node's block device count, or a /run/lvm/newhints, makes the next LVM
#     command read every block device), whether mxfs is loaded or mounted;
#   - ARM=fix: starts open-iscsi.service first, so its stop logs the session out;
#   - instruments this boot's shutdown and nothing after it: a drop-in under
#     /run runs lvm2-monitor's stop as `vgchange --monitor n -vvvv`, so the
#     journal names each device LVM opens and reads, and when; the console log
#     level goes to 7, so the kernel's lines past journald's end reach the
#     serial console; kernel.sysrq=1;
#   - powers both down at once with lab_power.sh down, as tools/vm_pool.sh idle
#     does; a node still running SYSRQ_S and SYSRQ2_S after the shutdown began
#     gets a sysrq-w through its keyboard, which prints its blocked tasks'
#     stacks to the serial console;
#   - boots both again and keeps the shutdown's journal from the probe's mark
#     and the serial console lines the shutdown added (OUT/<node>_*.txt).
#
# Usage: [ARM=bare|fix] tests/fourkn_lun_shutdown_probe.sh <node1> <node2>
# The nodes are left running.  Exit 0 every node off within the bound, 1 a node
# was destroyed, 2 ABORT.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/tools/mxfs_lab.sh"
SSH="$HERE/tools/mxfs_sshpass.sh"
VIRSH="virsh -c qemu:///system"
N1=${1:?node1}; N2=${2:?node2}
ARM=${ARM:-bare}
case $ARM in bare|fix) ;; *) echo "ARM is bare or fix, not '$ARM'" >&2; exit 2 ;; esac
# lab_power.sh destroys at 90 s; two sysrq-w before that, 30 s apart, say
# whether the same tasks stay blocked
SYSRQ_S=45
SYSRQ2_S=75
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
MARK="FOURKN-SHUTDOWN-$ARM-$STAMP"
OUT=$HERE/tests/evidence/${STAMP}_fourkn_shutdown_$ARM
mkdir -p "$OUT"
exec > >(tee -a "$OUT/probe.log") 2>&1
on() { timeout "$3" "$SSH" "$(lab_addr "$1")" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$'; }
step() { echo "$(date -u +%FT%TZ) $*"; }
abort() { step "ABORT $*"; exit 2; }
serial_log() { timeout 20 $VIRSH dumpxml "$1" 2>/dev/null | grep -oE "log file=['\"][^'\"]*serial[^'\"]*" | head -1 | sed -E "s/log file=['\"]//"; }

PRE='echo "open_iscsi=$(systemctl is-active open-iscsi.service) iscsid=$(systemctl is-active iscsid.service) sessions=$(iscsiadm -m session 2>/dev/null | wc -l)"
iscsiadm -m session 2>/dev/null
echo "iscsi_disks: $(lsblk -dnro NAME,LOG-SEC,TRAN | awk "\$3 == \"iscsi\" {printf \"%s(%s) \", \$1, \$2}")"
echo "lvm_hints_devs=$(sed -n "s/^devs_hash: [0-9]* //p" /run/lvm/hints 2>/dev/null) newhints=$([ -e /run/lvm/newhints ] && echo yes || echo no) block_devs=$(lsblk -nro NAME,TYPE | awk "\$2 == \"disk\" || \$2 == \"part\"" | wc -l)"
echo "mxfs_loaded=$(lsmod | grep -c "^mxfs ") mxfs_mounts=$(grep -c " mxfs " /proc/mounts) up=$(cut -d" " -f1 /proc/uptime)"'

INSTR='mkdir -p /run/systemd/system/lvm2-monitor.service.d
printf "[Service]\nExecStop=\nExecStop=/usr/sbin/lvm vgchange --monitor n -vvvv\n" > /run/systemd/system/lvm2-monitor.service.d/fourkn-probe.conf
systemctl daemon-reload
sysctl -qw kernel.sysrq=1
dmesg -n 7
echo "instr: execstop_vvvv=$(systemctl show -p ExecStop lvm2-monitor.service | grep -c -- "-vvvv") sysrq=$(cat /proc/sys/kernel/sysrq)"
echo MARK > /dev/kmsg
logger -t fourkn-probe MARK'

echo "=== fourkn_lun_shutdown_probe arm=$ARM nodes=$N1,$N2 mark=$MARK out=$OUT ==="
declare -A SLOG OFF0
for n in "$N1" "$N2"; do
    [ "$(timeout 20 $VIRSH domstate "$n" 2>/dev/null | head -1)" = running ] || abort "$n is not running"
    SLOG[$n]=$(serial_log "$n")
    [ -n "${SLOG[$n]}" ] || abort "$n has no serial console log file in its domain definition"
    if [ "$ARM" = fix ]; then
        r=$(on "$n" "systemctl start open-iscsi.service; systemctl is-active open-iscsi.service" 60 | tail -1)
        [ "$r" = active ] || abort "$n: open-iscsi.service did not start: [$r]"
    fi
    on "$n" "$PRE" 30 > "$OUT/${n}_pre.txt"
    step "PRE $n: $(grep -E '^open_iscsi=|^iscsi_disks|^lvm_hints|^mxfs_loaded' "$OUT/${n}_pre.txt" | tr '\n' ' ')"
    r=$(on "$n" "${INSTR//MARK/$MARK}" 30 | grep '^instr:')
    [ "$r" = "instr: execstop_vvvv=1 sysrq=1" ] || abort "$n not instrumented: [$r]"
    step "OK instrumented $n: $r"
    OFF0[$n]=$(sudo -n stat -c %s "${SLOG[$n]}" 2>/dev/null) || abort "cannot read ${SLOG[$n]}"
done

t0=$SECONDS
"$HERE/scripts/lab_power.sh" down "$N1" "$N2" > "$OUT/lab_power_down.txt" 2>&1 & lp=$!
declare -A SENT
while kill -0 "$lp" 2>/dev/null; do
    el=$(( SECONDS - t0 ))
    for n in "$N1" "$N2"; do
        for at in $SYSRQ_S $SYSRQ2_S; do
            if [ "$el" -ge "$at" ] && [ -z "${SENT[$n.$at]:-}" ]; then
                SENT[$n.$at]=1
                if [ "$(timeout 10 $VIRSH domstate "$n" 2>/dev/null | head -1)" = running ]; then
                    timeout 20 $VIRSH send-key "$n" KEY_LEFTALT KEY_SYSRQ KEY_W >/dev/null 2>&1
                    step "INFO $n still running ${el}s into the shutdown: sysrq-w sent (rc=$?)"
                fi
            fi
        done
    done
    sleep 1
done
wait "$lp"; lprc=$?
cat "$OUT/lab_power_down.txt"
step "INFO lab_power.sh down rc=$lprc wall=$(( SECONDS - t0 ))s"

hung=0
for n in "$N1" "$N2"; do
    sudo -n tail -c +$(( ${OFF0[$n]} + 1 )) "${SLOG[$n]}" > "$OUT/${n}_serial.txt" 2>/dev/null
    if grep -q "$n: still up after" "$OUT/lab_power_down.txt"; then
        step "HUNG $n: destroyed at lab_power.sh's bound"
        hung=$((hung + 1))
    else
        step "OFF $n: $(grep -o "$n: off after [0-9]* s" "$OUT/lab_power_down.txt")"
    fi
done

"$HERE/scripts/lab_power.sh" up "$N1" "$N2" > "$OUT/lab_power_up.txt" 2>&1 || abort "the nodes did not come back: $(tail -2 "$OUT/lab_power_up.txt" | tr '\n' '|')"
for n in "$N1" "$N2"; do
    on "$n" "journalctl -b -1 --no-pager -o short-precise | sed -n '/$MARK/,\$p'" 60 > "$OUT/${n}_journal.txt"
    [ "$(grep -ac "$MARK" "$OUT/${n}_journal.txt")" -ge 1 ] || step "WARN $n's previous-boot journal has no $MARK: it holds nothing of the shutdown"
    j=$OUT/${n}_journal.txt
    step "INFO $n journal: $(wc -l < "$j") lines; network down $(grep -a 'Stopped target network.target' "$j" | head -1 | awk '{print $3}'); lvm2-monitor stopping $(grep -a 'Stopping lvm2-monitor' "$j" | head -1 | awk '{print $3}') stopped $(grep -a 'Stopped lvm2-monitor' "$j" | head -1 | awk '{print $3}'); lvm lines $(grep -ac ' lvm\[' "$j"), naming sda $(grep -a ' lvm\[' "$j" | grep -ac 'sda'); last line $(tail -1 "$j" | cut -c1-160)"
    step "INFO $n last lvm lines: $(grep -a ' lvm\[' "$j" | tail -3 | cut -c1-200 | tr '\n' '|')"
    s=$OUT/${n}_serial.txt
    step "INFO $n serial: $(wc -l < "$s") lines, sysrq $(grep -ac 'sysrq: Show Blocked State' "$s"), blocked tasks $(grep -aoE '^\[ *[0-9.]+\] task:[^ ]+ +state:D' "$s" | awk '{print $2}' | sort | uniq -c | tr '\n' ' ')"
done
echo "=== fourkn_lun_shutdown_probe arm=$ARM: hung=$hung out=$OUT ==="
[ "$hung" -eq 0 ] || exit 1
exit 0
