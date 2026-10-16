#!/bin/bash
#
# platform_node_setup.sh — the after-build steps of a Debian-family platform
# node built with mkosimage (lab/vms.md, lab/README.md "Building a platform's
# verification set" step 3)
#
# Usage: [VCPUS=4] [MEM_GIB=4] scripts/platform_node_setup.sh <node> [node ...]
#
# Per node, in order:
#   1. ACPI and APIC in the persistent definition: mkosimage's libvirt domain
#      has no <features> at all (ubuntu2604, debian12, 2026-10-15), so the
#      guest never sees the power button, every ACPI shutdown runs out its
#      budget and the node is destroyed -- a hard power-off of its
#      filesystems on every stop the VM pool makes
#   2. size: VCPUS and MEM_GIB in the persistent definition, cold-started on it.
#      osimager builds every guest at 2 vCPUs and 2 GiB; an Ubuntu guest of
#      2.3 GiB ran out of memory compiling the module in its DKMS install, so
#      an Ubuntu set is sized like ubuntu2404's (4 and 4).
#   3. apt full-upgrade, then dkms, linux-headers-generic (headers follow every
#      kernel upgrade; DKMS compiles against them), open-iscsi and sg3-utils
#   3b. an iSCSI initiator name of its own: Ubuntu 26.04's live-server image
#      carries open-iscsi with /etc/iscsi/initiatorname.iscsi already written
#      (dated the image's build, 2026-08-26), so every node installed from it
#      has the same name.  The target then sees one initiator for the whole
#      set: each login drops the other node's session (conn error 1020, a
#      device reset per drop) and SCSI PR, which keys on the initiator,
#      refused the mount's RESERVE.  A name older than the node's
#      /etc/machine-id (written by its own install) came from the image and is
#      regenerated with iscsi-iname; a name the node made itself is kept, so
#      a rerun never changes it.  A LUN bound before this must be bound
#      again (scripts/platform_lab.sh).
#   4. a reboot when the upgrade asks for one, so the node runs the kernel the
#      upgrade installed
#   5. the node's os, kernel and the packages above reported, and the node shut
#      off: the VM pool starts it for the steps that use it
#
# Budgets: ACPI shutdown ~5-10 s -> SHUTDOWN_S=90, then destroy; an Ubuntu
# 26.04 node answered ssh within seconds of its start (vm_reclaim_disk.sh,
# 2026-10-15), BOOT_S=240 as vm_reclaim_disk.sh allows a rig guest; the
# upgrade and installs are ~25 packages plus the toolchain dkms pulls in,
# ~200 MB from the mirror and a 2-4 min unpack on 4 vCPUs -> APT_S=480.
#
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/tools/mxfs_lab.sh"
SSH="$HERE/tools/mxfs_sshpass.sh"
VIRSH="virsh -c qemu:///system"
VCPUS="${VCPUS:-4}"
MEM_GIB="${MEM_GIB:-4}"
SHUTDOWN_S=90
BOOT_S=240
APT_S=480

[ $# -ge 1 ] || { echo "usage: [VCPUS=4] [MEM_GIB=4] $0 <node> [node ...]" >&2; exit 2; }

say() { echo "[$(date +%T)] $*"; }
on() { local h=$1 t=$2; shift 2; timeout "$t" "$SSH" "$h" "$@" 2>&1 | grep -v -E "^Warning: Permanently|^$|Unauthorized access|authorized user, disconnect|System is booting up"; return "${PIPESTATUS[0]}"; }
state() { $VIRSH domstate "$1" 2>/dev/null | head -1; }

stop() {  # ACPI shutdown, destroy past the budget
    local d=$1 t0
    [ "$(state "$d")" = "shut off" ] && return 0
    $VIRSH shutdown "$d" >/dev/null 2>&1
    t0=$(date +%s)
    while [ "$(state "$d")" != "shut off" ]; do
        if [ $(( $(date +%s) - t0 )) -ge $SHUTDOWN_S ]; then
            say "$d: no ACPI shutdown within ${SHUTDOWN_S} s, destroying"
            $VIRSH destroy "$d" >/dev/null 2>&1
            break
        fi
        sleep 2
    done
}

wait_ssh() {  # <node>: 0 once ssh answers within BOOT_S; sets a= to its address
    local d=$1 t0
    t0=$(date +%s)
    while [ $(( $(date +%s) - t0 )) -lt $BOOT_S ]; do
        # resolved on every attempt: once ACPI is added the guest's NIC is
        # renamed, its DHCP client id changes with it and dnsmasq hands it a
        # new address (ubuntu2604-1: .178 before, .107 after), which the
        # resolver knows only after that lease is taken
        a=$(lab_addr "$d" 2>/dev/null) && on "$a" 10 "echo up" | grep -q up && return 0
        sleep 3
    done
    return 1
}

add_acpi() {  # persistent definition: <features> holds <acpi/> and <apic/>
    local d=$1 x
    x=$(mktemp --suffix=.xml)
    $VIRSH dumpxml --inactive "$d" | python3 -c '
import sys, xml.etree.ElementTree as ET
t = ET.parse(sys.stdin)
r = t.getroot()
f = r.find("features")
if f is None:
    f = ET.SubElement(r, "features")
for name in ("acpi", "apic"):
    if f.find(name) is None:
        ET.SubElement(f, name)
t.write(sys.stdout, encoding="unicode")
' > "$x" && $VIRSH define "$x" >/dev/null
    local rc=$?
    rm -f "$x"
    return $rc
}

fail=0
for d in "$@"; do
    [ -n "$(state "$d")" ] || { say "$d: no such domain"; fail=1; continue; }
    stop "$d"
    add_acpi "$d" || { say "$d: FAILED to add ACPI to its definition"; fail=1; continue; }
    kib=$((MEM_GIB * 1024 * 1024))
    $VIRSH setmaxmem "$d" "$kib" --config >/dev/null \
        && $VIRSH setmem "$d" "$kib" --config >/dev/null \
        && $VIRSH setvcpus "$d" "$VCPUS" --config --maximum >/dev/null \
        && $VIRSH setvcpus "$d" "$VCPUS" --config >/dev/null \
        || { say "$d: FAILED to size it to $VCPUS vCPUs, $MEM_GIB GiB"; fail=1; continue; }
    $VIRSH start "$d" >/dev/null || { say "$d: FAILED to start"; fail=1; continue; }
    a=""
    wait_ssh "$d" || { say "$d: did not answer ssh (last address '$a') within ${BOOT_S} s"; stop "$d"; fail=1; continue; }
    say "$d: up at $a, $VCPUS vCPUs, $MEM_GIB GiB; upgrading"
    on "$a" "$APT_S" 'export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get -y -qq -o Dpkg::Options::=--force-confold full-upgrade \
        && apt-get -y -qq install dkms linux-headers-generic open-iscsi sg3-utils' | tail -5
    rc=${PIPESTATUS[0]}
    [ "$rc" = 0 ] || { say "$d: apt FAILED rc=$rc"; stop "$d"; fail=1; continue; }
    say "$d: $(on "$a" 60 'f=/etc/iscsi/initiatorname.iscsi
        if [ ! -s $f ] || [ $f -ot /etc/machine-id ]; then
            old=$(sed -n "s/^InitiatorName=//p" $f 2>/dev/null)
            echo "InitiatorName=$(iscsi-iname)" > $f && systemctl try-restart iscsid >/dev/null 2>&1
            echo "initiator name regenerated (was ${old:-none}): $(sed -n "s/^InitiatorName=//p" $f)"
        else
            echo "initiator name kept: $(sed -n "s/^InitiatorName=//p" $f)"
        fi' | tr '\n' ' ')"
    if on "$a" 10 "test -f /var/run/reboot-required && echo yes" | grep -q yes; then
        say "$d: the upgrade asks for a reboot"
        stop "$d"
        $VIRSH start "$d" >/dev/null || { say "$d: FAILED to start after the upgrade"; fail=1; continue; }
        wait_ssh "$d" || { say "$d: did not answer ssh after the reboot"; stop "$d"; fail=1; continue; }
    fi
    say "$d: $(on "$a" 30 '. /etc/os-release; k=$(uname -r)
        echo "os=$PRETTY_NAME kernel=$k cpus=$(nproc) mem_mb=$(free -m | awk "/^Mem:/{print \$2}")"
        for p in linux-headers-$k dkms open-iscsi sg3-utils; do
            printf " %s=%s" $p "$(dpkg-query -W -f="\${Version}" $p 2>/dev/null || echo ABSENT)"; done' | tr '\n' ' ')"
    stop "$d"
done
exit $fail
