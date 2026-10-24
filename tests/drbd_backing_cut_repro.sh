#!/bin/bash
# drbd_backing_cut_repro.sh — does the stock drbd module oops when its backing
# disk goes away under direct reads, on a pair with no MeshXFS on it at all?
#
# D-DRBD-RIG-NODE-OOPS-IN-DRBD-CHANGE-SYNC-ON-AN-LVM-READ-WHOSE-BACKING-BIO-FAILED:
# two rig nodes oopsed at __drbd_change_sync+0x56 in drbd's read completion, an
# 'lvm' O_DIRECT aio read of the DRBD device whose backing bio failed inside its
# own submission (submit_bio_noacct -> bio_endio -> drbd_request_endio ->
# __req_mod).  The review of its removal (data/reviews/P20261024-c64f70.md) asks
# for the direct reproduction with no MeshXFS on the pair at all: no module in
# the boot, no mxfs package, unit or udev rule, DRBD up on pool LUNs, the
# backing path cut by non-MeshXFS means while direct aio reads run on the DRBD
# device.  A block device whose iSCSI session is gone fails every bio inside its
# submission, which is the precondition both oopses share.
#
# Shape.
#   clean  on each node: remove MeshXFS's udev rules, then restart both guests
#          (scripts/lab_power.sh down, up), so the boot the test runs in never
#          loaded the module; checked: kernel taint 0, no mxfs module, no mxfs
#          rule, no mxfs package, no mxfs unit enabled or active
#   luns   one pool LUN per node (tools/lun_pool.sh alloc: single path,
#          512-byte blocks), each held by a process of this script, as
#          scripts/drbd_rig.sh holds them
#   drbd   resource cutrepro on both: no handlers, fencing dont-care, the first
#          1 GiB replicated; create-md, up, connect, N1 primary --force, sync,
#          N2 primary (both Primary, as the rig runs)
#   cut    on N1, with its console at loglevel 8: fio (libaio, O_DIRECT,
#          randread, QD32) and a loop of 'lvm pvscan --cache' on the DRBD
#          device; 5 s in, iscsiadm logs N1 out of its own pool target, which
#          takes its backing disk away
#   read   N1's serial console from before the cut, from the host's copy
#          (/var/log/libvirt/qemu/<N1>-serial.log, which a panicking guest
#          cannot lose), and whether N1 rebooted (boot_id)
#
# RESULT: REPRODUCED when N1's console shows 'BUG: kernel NULL pointer
# dereference' and __drbd_change_sync in the oops, in a boot that was
# untainted with no mxfs module; NOT-REPRODUCED when it shows neither; ABORT
# when a precondition failed.  EXPOSED is printed when N1's backing device was
# gone, or N1 oopsed, while the reads ran.
#
# Bounds, from what each step should take: power-down and power-up are
# lab_power.sh's own (it bounds each guest); a pool allocation 30 s a node; the
# drbd-utils and fio install 120 s (scripts/drbd_rig.sh APT_BUDGET); create-md
# and up 60 s; connect 30 s (CONNECT_BUDGET); 1 GiB synced at a pool LUN's
# ~180 MiB/s in ~6 s, 60 s; the cut 5 s plus fio's 30 s, watched 60 s; a guest
# that panicked reboots after 25 s and answers ssh in 20-120 s, 240 s (BOOT_S).
#
# Usage: tests/drbd_backing_cut_repro.sh <label> <node1> <node2>
# Exit 0 REPRODUCED, 1 NOT-REPRODUCED, 2 ABORT.
set -u
LABEL=${1:?label}; N1=${2:?node1}; N2=${3:?node2}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$HERE
while [ "$REPO" != / ] && [ ! -f "$REPO/tools/mxfs_lab.sh" ]; do REPO=$(dirname "$REPO"); done
[ -f "$REPO/tools/mxfs_lab.sh" ] || { echo "RESULT: ABORT label=$LABEL stage=root (no tools/mxfs_lab.sh above $HERE)"; exit 2; }
cd "$REPO" || exit 2
. tools/mxfs_lab.sh
SSH=tools/mxfs_sshpass.sh
POOL=tools/lun_pool.sh
RES=cutrepro
MINOR=30
PORT=7830
SIZE=1G
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_drbdcut_$LABEL
mkdir -p "$OUT"
exec > >(tee -a "$OUT/run.log") 2>&1
T0=$(date +%s)
el() { echo $(( $(date +%s) - T0 )); }
say() { echo "$(date -u +%FT%TZ) +$(el)s $*"; }
on() { timeout "$3" "$SSH" "$(lab_addr "$1")" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$'; }
abort() { say "ABORT $*"; echo "RESULT: ABORT label=$LABEL stage=$STAGE wall=$(el)s evidence=$OUT"; exit 2; }

declare -A DEV ID TGT
HOLDERS=()
cleanup() {
    local n
    for n in "$N1" "$N2"; do
        on "$n" "drbdadm down $RES >/dev/null 2>&1; rm -f /etc/drbd.d/$RES.res; echo DOWN_OK" 60 > "$OUT/cleanup.$n.txt"
    done
    for n in "$N1" "$N2"; do
        [ -n "${ID[$n]:-}" ] && "$POOL" free "${ID[$n]}" >> "$OUT/cleanup.pool.txt" 2>&1
    done
    [ "${#HOLDERS[@]}" -gt 0 ] && kill "${HOLDERS[@]}" 2>/dev/null
    return 0
}
trap cleanup EXIT

say "=== drbd_backing_cut_repro label=$LABEL N1=$N1 N2=$N2 out=$OUT ==="

# ---- clean: no MeshXFS in the boot the test runs in
STAGE=clean
for n in "$N1" "$N2"; do
    on "$n" "rm -f /etc/udev/rules.d/*mxfs*.rules; udevadm control --reload-rules; echo RULES_LEFT=\$(ls /etc/udev/rules.d /lib/udev/rules.d /usr/lib/udev/rules.d 2>/dev/null | grep -c mxfs)" 30 > "$OUT/clean.$n.txt"
    grep -q '^RULES_LEFT=0$' "$OUT/clean.$n.txt" || abort "$n still has an mxfs udev rule: $(tr '\n' ' ' < "$OUT/clean.$n.txt")"
done
scripts/lab_power.sh down "$N1" "$N2" > "$OUT/power_down.txt" 2>&1 || abort "power-down: $(tail -1 "$OUT/power_down.txt")"
scripts/lab_power.sh up "$N1" "$N2" > "$OUT/power_up.txt" 2>&1 || abort "power-up: $(tail -1 "$OUT/power_up.txt")"
for n in "$N1" "$N2"; do
    on "$n" "echo TAINT=\$(cat /proc/sys/kernel/tainted); echo MXFS_MOD=\$(grep -c '^mxfs ' /proc/modules); echo RULES=\$(ls /etc/udev/rules.d /lib/udev/rules.d /usr/lib/udev/rules.d 2>/dev/null | grep -c mxfs); echo PKGS=\$(dpkg-query -W -f='\${Package} \${Status}\n' 2>/dev/null | grep -c '^mxfs.* installed'); echo UNITS_ENABLED=\$(systemctl list-unit-files 'mxfs*' --state=enabled --no-legend 2>/dev/null | grep -c .); echo UNITS_ACTIVE=\$(systemctl list-units 'mxfs*' --state=active --no-legend 2>/dev/null | grep -c .); echo MXFS_BINS=\$(ls /usr/sbin/mxfs* /usr/local/sbin/mxfs* 2>/dev/null | tr '\n' ' '); echo BOOT_ID=\$(cat /proc/sys/kernel/random/boot_id); uname -r" 30 > "$OUT/state.$n.txt"
    say "$n: $(tr '\n' ' ' < "$OUT/state.$n.txt")"
    for want in TAINT=0 MXFS_MOD=0 RULES=0 PKGS=0 UNITS_ENABLED=0 UNITS_ACTIVE=0; do
        grep -q "^$want\$" "$OUT/state.$n.txt" || abort "$n: want $want, have $(grep "^${want%%=*}=" "$OUT/state.$n.txt")"
    done
done
BOOT1=$(sed -n 's/^BOOT_ID=//p' "$OUT/state.$N1.txt")

# ---- luns: one per node, each held by its own process
STAGE=luns
for n in "$N1" "$N2"; do
    ( exec tail --pid=$$ -f /dev/null ) > /dev/null 2>&1 &
    HOLDERS+=($!)
    line=$(timeout 60 "$POOL" alloc --owner "$!" --what "drbd_backing_cut_repro $LABEL $n" "$n") || abort "no pool LUN for $n"
    echo "$line" >> "$OUT/luns.txt"
    DEV[$n]=$(sed -n 's/.* dev=\([^ ]*\).*/\1/p' <<<"$line")
    ID[$n]=$(sed -n 's/.* id=\([^ ]*\).*/\1/p' <<<"$line")
    TGT[$n]=$(sed -n 's/.* target=\([^ ]*\).*/\1/p' <<<"$line")
    [ -n "${DEV[$n]}" ] && [ -n "${TGT[$n]}" ] || abort "unusable allocation for $n: $line"
    say "$n: lun${ID[$n]} ${DEV[$n]}"
done
PORTAL=$(sed -n 's#.*/ip-\([^-]*\)-iscsi-.*#\1#p' <<<"${DEV[$N1]}")
[ -n "$PORTAL" ] || abort "no portal in ${DEV[$N1]}"

# ---- drbd: the resource, up, connected, both Primary
STAGE=drbd
a1=$(lab_addr "$N1"); a2=$(lab_addr "$N2")
RESFILE="resource $RES {
    net { protocol C; allow-two-primaries yes; after-sb-0pri disconnect; after-sb-1pri disconnect; after-sb-2pri disconnect; ping-int 3; }
    disk { c-plan-ahead 0; resync-rate 1000M; fencing dont-care; size $SIZE; }
    on $N1 { device /dev/drbd$MINOR minor $MINOR; disk \"${DEV[$N1]}\"; address $a1:$PORT; meta-disk internal; }
    on $N2 { device /dev/drbd$MINOR minor $MINOR; disk \"${DEV[$N2]}\"; address $a2:$PORT; meta-disk internal; }
}"
echo "$RESFILE" > "$OUT/$RES.res"
B64=$(base64 -w0 <<<"$RESFILE")
for n in "$N1" "$N2"; do
    on "$n" "command -v drbdadm >/dev/null && command -v fio >/dev/null || { DEBIAN_FRONTEND=noninteractive timeout 110 apt-get install -y -q drbd-utils fio >/dev/null 2>&1; systemctl disable --now drbd >/dev/null 2>&1; }; command -v drbdadm >/dev/null && command -v fio >/dev/null && command -v lvm >/dev/null && echo TOOLS_OK" 120 > "$OUT/tools.$n.txt"
    grep -q TOOLS_OK "$OUT/tools.$n.txt" || abort "$n lacks drbdadm, fio or lvm: $(tail -2 "$OUT/tools.$n.txt" | tr '\n' ' ')"
    on "$n" "modprobe drbd && echo $B64 | base64 -d > /etc/drbd.d/$RES.res && drbdadm -- --force create-md $RES < /dev/null > /tmp/cutrepro_md.log 2>&1 && drbdadm up $RES > /tmp/cutrepro_up.log 2>&1 && echo MD_UP_OK || { tail -3 /tmp/cutrepro_md.log /tmp/cutrepro_up.log; }" 60 > "$OUT/up.$n.txt"
    grep -q MD_UP_OK "$OUT/up.$n.txt" || abort "$n: create-md/up: $(tr '\n' ' ' < "$OUT/up.$n.txt")"
done
on "$N1" "for i in \$(seq 1 30); do [ \"\$(drbdadm cstate $RES)\" = Connected ] && { echo CONNECTED; break; }; sleep 1; done" 40 > "$OUT/connect.txt"
grep -q CONNECTED "$OUT/connect.txt" || abort "not connected in 30 s"
on "$N1" "drbdadm primary --force $RES 2>&1 | tail -1; for i in \$(seq 1 60); do [ \"\$(drbdadm dstate $RES)\" = UpToDate/UpToDate ] && { echo SYNCED; break; }; sleep 1; done" 70 > "$OUT/sync.txt"
grep -q SYNCED "$OUT/sync.txt" || abort "not synced in 60 s: $(tr '\n' ' ' < "$OUT/sync.txt")"
on "$N2" "drbdadm primary $RES 2>&1 | tail -1; drbdadm role $RES" 30 > "$OUT/promote.txt"
on "$N1" "drbdadm role $RES; drbdadm dstate $RES; drbdadm cstate $RES; cat /proc/drbd" 20 > "$OUT/drbd_state_before.txt"
grep -q '^Primary/Primary$' "$OUT/drbd_state_before.txt" || abort "not Primary/Primary: $(tr '\n' ' ' < "$OUT/drbd_state_before.txt")"
say "DRBD $RES Primary/Primary, UpToDate/UpToDate, on lun${ID[$N1]} and lun${ID[$N2]}"

# ---- cut: N1's backing target logged out under direct aio reads
STAGE=cut
SER=/var/log/libvirt/qemu/$N1-serial.log
OFF=$(sudo -n stat -c %s "$SER" 2>/dev/null) || abort "cannot read the size of $SER"
on "$N1" "dmesg -n 8; echo CUT-REPRO-$LABEL > /dev/kmsg; nohup setsid fio --name=cut --filename=/dev/drbd$MINOR --ioengine=libaio --direct=1 --rw=randread --bs=4k --iodepth=32 --time_based --runtime=30 --output=/root/cutrepro_fio.txt > /dev/null 2>&1 < /dev/null & nohup setsid sh -c 'for i in \$(seq 1 300); do lvm pvscan --cache /dev/drbd$MINOR > /dev/null 2>&1; sleep 0.1; done' > /dev/null 2>&1 < /dev/null & sleep 5; echo FIO_RUNNING=\$(ps -o pid= -C fio | grep -c .); echo DEV_BEFORE=\$([ -b ${DEV[$N1]} ] && echo present || echo gone); iscsiadm -m node -T ${TGT[$N1]} -p $PORTAL -u > /dev/null 2>&1; echo LOGOUT_RC=\$?; sleep 3; echo DEV_AFTER=\$([ -b ${DEV[$N1]} ] && echo present || echo gone); echo DSTATE=\$(drbdadm dstate $RES)" 30 > "$OUT/cut.txt"
say "cut: $(tr '\n' ' ' < "$OUT/cut.txt")"
sleep 60
on "$N1" "echo BOOT_ID=\$(cat /proc/sys/kernel/random/boot_id); echo DSTATE=\$(drbdadm dstate $RES); echo TAINT=\$(cat /proc/sys/kernel/tainted); echo MXFS_MOD=\$(grep -c '^mxfs ' /proc/modules); dmesg | sed -n '/CUT-REPRO-$LABEL/,\$p' | tail -60" 20 > "$OUT/after.txt"
if ! grep -q '^BOOT_ID=' "$OUT/after.txt"; then
    say "$N1 does not answer 60 s after the cut; waiting up to 240 s for it to boot again"
    end=$((SECONDS + 240))
    while [ $SECONDS -lt $end ]; do
        on "$N1" "echo BOOT_ID=\$(cat /proc/sys/kernel/random/boot_id)" 10 > "$OUT/after.txt"
        grep -q '^BOOT_ID=' "$OUT/after.txt" && break
        sleep 5
    done
fi
BOOT2=$(sed -n 's/^BOOT_ID=//p' "$OUT/after.txt")
sudo -n tail -c +"$((OFF + 1))" "$SER" | tr -d '\r' > "$OUT/console_$N1.txt"
say "$N1 boot before the cut $BOOT1, after ${BOOT2:-none}; console since the cut: $(wc -l < "$OUT/console_$N1.txt") line(s)"

# ---- verdict
STAGE=verdict
bug=$(grep -ac 'BUG: kernel NULL pointer dereference' "$OUT/console_$N1.txt")
chg=$(grep -ac '__drbd_change_sync' "$OUT/console_$N1.txt")
grep -a 'BUG:\|RIP:\|Comm:\|Tainted\|Modules linked in\|__drbd_change_sync\|__req_mod\|drbd_request_endio\|submit_bio_noacct\|Kernel panic' "$OUT/console_$N1.txt" | head -20 | cut -c1-200
if [ "$bug" -ge 1 ] || grep -q '^DEV_AFTER=gone$' "$OUT/cut.txt"; then
    echo "EXPOSED: $N1's backing device was cut while direct aio reads ran on /dev/drbd$MINOR ($(grep '^FIO_RUNNING=\|^DEV_AFTER=' "$OUT/cut.txt" | tr '\n' ' '))"
fi
if [ "$bug" -ge 1 ] && [ "$chg" -ge 1 ]; then
    tainted=$(grep -a 'Comm:' "$OUT/console_$N1.txt" | head -1)
    modules=$(grep -a 'Modules linked in' "$OUT/console_$N1.txt" | head -1)
    case "$tainted $modules" in
        *mxfs*) echo "RESULT: ABORT label=$LABEL stage=verdict (the oops names mxfs: $modules) evidence=$OUT"; exit 2 ;;
    esac
    echo "RESULT: REPRODUCED label=$LABEL oops=__drbd_change_sync tainted=[$tainted] wall=$(el)s evidence=$OUT"
    exit 0
fi
echo "RESULT: NOT-REPRODUCED label=$LABEL bug_lines=$bug change_sync_lines=$chg boot_changed=$([ "$BOOT1" != "$BOOT2" ] && echo yes || echo no) wall=$(el)s evidence=$OUT"
exit 1
