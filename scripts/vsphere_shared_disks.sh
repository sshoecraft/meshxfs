#!/bin/bash
#
# vsphere_shared_disks.sh — give the vSphere test guests a disk vSphere itself
# shares between them, and measure what of SCSI reaches the device through it
#
# Usage: scripts/vsphere_shared_disks.sh rdm <device-id> [<vm1> <vm2>]
#        scripts/vsphere_shared_disks.sh vmdk <size> [<vm1> <vm2>]
#        scripts/vsphere_shared_disks.sh probe <rdm|vmdk> [<vm1> <vm2>]
#        scripts/vsphere_shared_disks.sh detach [<vm1> <vm2>]
#
#   rdm    the ESXi device <device-id> (as `esxcli storage core device list`
#          names it, e.g. eui.6661313331363962 from scripts/vsphere_lun.sh) as
#          a PHYSICAL-compatibility RDM: vm1 creates the mapping file, vm2
#          attaches the same mapping, each on a paravirtual SCSI controller
#          with physical bus sharing (the WSFC "cluster across boxes" shape,
#          which passes SCSI reservations to the array)
#   vmdk   an eager-zeroed thick multi-writer VMDK of <size> on datastore DS
#          (mxfs-shared, VMFS6), attached to both with
#          sharing=sharingMultiWriter on a controller whose bus sharing is
#          VMDK_SHARING (default physicalSharing)
#   probe  on each guest, against the shared disk: its identity, the Block
#          Limits VPD (COMPARE AND WRITE length), persistent-reservation
#          capabilities, then the fence MeshXFS depends on: both guests
#          register, vm1 reserves Write Exclusive - Registrants Only and
#          PREEMPT AND ABORTs vm2's key, and vm2's next write must be refused
#          with a reservation conflict; then COMPARE AND WRITE and FUA from each.
#          Prints one PROBE line per measurement and leaves no reservation.
#   detach both disks off both guests (the mapping file and the VMDK kept)
#
# A controller with bus sharing can only be added to a powered-off VM, so rdm,
# vmdk and detach shut both guests down through VMware Tools first and power
# them on afterwards.  The guests are disposable test VMs.
#
# Why a probe and not a board first: MeshXFS's disk transport locks with
# COMPARE AND WRITE, orders with FUA and fences with PREEMPT AND ABORT
# (docs/fencing.md, `scsipr`), and a node no configured method can fence must
# not mount.  Which of those vSphere forwards decides which configurations
# exist on each disk kind, and that is a measurement, not a reading of
# VMware's documentation.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SSH="$HERE/tools/mxfs_sshpass.sh"
DS=${DS:-mxfs-shared}
SHIM=${SHIM:-mxfs-rdm-map}
VMDK_SHARING=${VMDK_SHARING:-physicalSharing}   # the vmdk controller's bus sharing: physicalSharing | virtualSharing | noSharing
# The vmdk's own sharing and file.  A multi-writer VMDK is sharingMultiWriter;
# a clustered VMDK (a datastore with Clustered VMDK enabled, ESXi emulating
# reservations per VM) is sharingNone on a physical-bus-sharing controller.
VMDK_DISK_SHARING=${VMDK_DISK_SHARING:-sharingMultiWriter}
VMDK_NAME=${VMDK_NAME:-mxfs-mw/shared}
PYVMOMI=${PYVMOMI:-/home/steve/.venvs/pyvmomi/bin/python3}   # python3 with pyvmomi (tools/vsphere_rdm_attach.py)
. "$HERE/scripts/vsphere_env.sh" lab || { echo "no vCenter credentials" >&2; exit 2; }
export GOVC_INSECURE=1

die() { echo "vsphere_shared_disks: $*" >&2; exit 1; }
vmpath() { timeout 30 govc find / -type m -name "$1" 2>/dev/null | head -1; }
gssh() { local n=$1; shift; timeout "${GSSH_T:-60}" "$SSH" "$n.vm.localdomain" "$@" 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$'; }

power_state() { timeout 30 govc vm.info -json "$(vmpath "$1")" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtualMachines"][0]["runtime"]["powerState"])'; }

shutdown_vm() {  # guest shutdown, then wait for poweredOff (bounded by a measured guest shutdown, ~15 s, x4)
    local vm=$1 p i
    p=$(vmpath "$vm"); [ -n "$p" ] || die "no VM $vm"
    [ "$(power_state "$vm")" = poweredOff ] && return 0
    gssh "$vm" 'timeout 30 umount /mnt/shared 2>/dev/null; true' >/dev/null
    timeout 30 govc vm.power -s "$p" >/dev/null 2>&1
    for i in $(seq 1 30); do [ "$(power_state "$vm")" = poweredOff ] && return 0; sleep 2; done
    die "$vm did not power off within 60 s of a guest shutdown"
}

start_vm() {  # power on, wait for ssh and /src (measured boot ~20 s; bound 180 s)
    local vm=$1 i
    timeout 120 govc vm.power -on "$(vmpath "$vm")" >/dev/null 2>&1
    for i in $(seq 1 36); do GSSH_T=10 gssh "$vm" 'test -d /src/mxfs && echo UP' | grep -q UP && return 0; sleep 5; done
    die "$vm not reachable 180 s after power-on"
}

# The key of the VM's controller with the given sharing, adding one if none.
controller_with() {  # <vm-path> <sharing>: govc's name for it (pvscsi-<key>), or nothing
    timeout 30 govc device.info -json -vm "$1" 2>/dev/null | python3 -c '
import json, sys
for d in json.load(sys.stdin).get("devices") or []:
    if d.get("sharedBus") == sys.argv[1]:
        print(d["name"]); break
' "$2"
}
shared_controller() {  # <vm> <sharing>
    local vm=$1 want=$2 p
    p=$(vmpath "$vm")
    if [ -z "$(controller_with "$p" "$want")" ]; then
        timeout 60 govc device.scsi.add -vm "$p" -type pvscsi -sharing "$want" >/dev/null || die "$vm: cannot add a $want pvscsi controller"
    fi
    controller_with "$p" "$want"
}

# The shared disk's file on vm1, by backing kind (RDM mapping or flat VMDK on DS).
disk_file() {  # <vm> <rdm|vmdk>
    timeout 30 govc device.info -json -vm "$(vmpath "$1")" 2>/dev/null | python3 -c '
import json, sys
kind = sys.argv[1]
for d in json.load(sys.stdin).get("devices") or []:
    b = d.get("backing") or {}
    f = b.get("fileName") or ""
    if kind == "rdm" and b.get("compatibilityMode") == "physicalMode":
        print(d["name"], f); break
    if kind == "vmdk" and not b.get("compatibilityMode") and f.endswith("] " + sys.argv[2] + ".vmdk"):
        print(d["name"], f); break
' "$2" "$VMDK_NAME"
}

cmd_rdm() {
    local dev=$1 vm1=$2 vm2=$3 c1 c2 f
    shutdown_vm "$vm1"; shutdown_vm "$vm2"
    c1=$(shared_controller "$vm1" physicalSharing); [ -n "$c1" ] || die "$vm1: no physicalSharing controller"
    c2=$(shared_controller "$vm2" physicalSharing); [ -n "$c2" ] || die "$vm2: no physicalSharing controller"
    # The mapping file must live on VMFS, and govc's vm.rdm.attach writes it in
    # the VM's home, which for the test guests is the NFS `vms` datastore
    # ("The operation is not supported on the object").  So a powered-off shim
    # VM homed on DS takes the RDM, the disk is detached keeping the file, and
    # the shim is unregistered (not destroyed: that would delete the mapping).
    f=$(timeout 30 govc datastore.ls -ds "$DS" "$SHIM/" 2>/dev/null | grep -E '^'"$SHIM"'(_[0-9]+)?\.vmdk$' | head -1)
    if [ -n "$f" ]; then
        f="[$DS] $SHIM/$f"
    else
        timeout 120 govc vm.create -ds "$DS" -net "${SHIM_NET:-192.168.120.0:24}" -on=false -m 128 -c 1 -disk.controller pvscsi -g otherGuest64 "$SHIM" >/dev/null || die "cannot create shim VM $SHIM on $DS"
        timeout 120 govc vm.rdm.attach -vm "$(vmpath "$SHIM")" -device "/vmfs/devices/disks/$dev" || die "shim: rdm attach of $dev failed"
        read -r d f <<<"$(disk_file "$SHIM" rdm)"
        [ -n "$f" ] || die "shim: no physical-mode RDM after attach"
        timeout 60 govc device.remove -vm "$(vmpath "$SHIM")" -keep "$d" || die "shim: cannot detach $d"
        timeout 60 govc vm.unregister "$(vmpath "$SHIM")" || die "cannot unregister shim $SHIM"
    fi
    echo "RDM mapping $f"
    # govc can attach an existing file only as a flat VMDK, which vSphere
    # refuses for a mapping; tools/vsphere_rdm_attach.py builds the RDM backing
    local vm c bus
    for vm in "$vm1" "$vm2"; do
        c=$c1; [ "$vm" = "$vm2" ] && c=$c2
        bus=$(timeout 30 govc device.info -json -vm "$(vmpath "$vm")" "$c" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["devices"][0]["busNumber"])')
        [ -n "$bus" ] || die "$vm: no bus number for $c"
        timeout 120 "$PYVMOMI" "$HERE/tools/vsphere_rdm_attach.py" "$vm" "$bus" "$f" "/vmfs/devices/disks/$dev" || die "$vm: RDM attach of $f on bus $bus failed"
    done
    start_vm "$vm1"; start_vm "$vm2"
    echo "RDM_OK device=$dev mapping=$f $vm1:$c1 $vm2:$c2"
}

cmd_vmdk() {
    local size=$1 vm1=$2 vm2=$3 c1 c2 d f
    shutdown_vm "$vm1"; shutdown_vm "$vm2"
    # which of SCSI reaches the guest depends on the controller's bus sharing
    # as well as the disk's multi-writer flag: on a noSharing controller the
    # VMDK answered no PERSISTENT RESERVE at all (probe-vmdk.txt); physical
    # bus sharing is the shared-disk cluster layout (VMDK_SHARING selects)
    c1=$(shared_controller "$vm1" "$VMDK_SHARING"); [ -n "$c1" ] || die "$vm1: no $VMDK_SHARING controller"
    c2=$(shared_controller "$vm2" "$VMDK_SHARING"); [ -n "$c2" ] || die "$vm2: no $VMDK_SHARING controller"
    if [ -z "$(disk_file "$vm1" vmdk)" ] && timeout 30 govc datastore.ls -ds "$DS" "$VMDK_NAME.vmdk" >/dev/null 2>&1; then
        # made by an earlier run and detached since: attach it, do not re-create
        timeout 60 govc vm.disk.attach -vm "$(vmpath "$vm1")" -ds "$DS" -disk "$VMDK_NAME.vmdk" -link=false -controller "$c1" \
            -sharing "$VMDK_DISK_SHARING" -mode independent_persistent || die "$vm1: cannot attach the existing $VMDK_NAME.vmdk"
    fi
    if [ -z "$(disk_file "$vm1" vmdk)" ]; then
        timeout 1800 govc vm.disk.create -vm "$(vmpath "$vm1")" -ds "$DS" -name "$VMDK_NAME" -size "$size" \
            -thick -eager -controller "$c1" -sharing "$VMDK_DISK_SHARING" -mode independent_persistent \
            || die "$vm1: VMDK create failed ($VMDK_DISK_SHARING on $DS)"
    fi
    read -r d f <<<"$(disk_file "$vm1" vmdk)"
    [ -n "$f" ] || die "$vm1: no shared disk after create"
    if [ -z "$(disk_file "$vm2" vmdk)" ]; then
        timeout 60 govc vm.disk.attach -vm "$(vmpath "$vm2")" -ds "$DS" -disk "${f#\[*\] }" -link=false -controller "$c2" \
            -sharing "$VMDK_DISK_SHARING" -mode independent_persistent || die "$vm2: cannot attach $f"
    fi
    start_vm "$vm1"; start_vm "$vm2"
    echo "VMDK_OK file=$f $vm1:$c1 $vm2:$c2"
}

cmd_detach() {
    local vm1=$1 vm2=$2 vm k d f
    shutdown_vm "$vm1"; shutdown_vm "$vm2"
    for vm in "$vm1" "$vm2"; do
        for k in rdm vmdk; do
            read -r d f <<<"$(disk_file "$vm" "$k")"
            [ -n "${d:-}" ] && { timeout 60 govc device.remove -vm "$(vmpath "$vm")" -keep "$d" && echo "$vm: detached $d ($f)"; }
        done
    done
    start_vm "$vm1"; start_vm "$vm2"
}

# The shared disk inside a guest: the one that is neither the boot disk nor an
# iSCSI session's (the in-guest pool LUN), matched by kind.
GUEST_DEV='
kind=@KIND@
for d in $(lsblk -dnro NAME,TYPE | awk "\$2==\"disk\"{print \$1}"); do
  [ -n "$(lsblk -nro MOUNTPOINT /dev/$d | grep -v "^$")" ] && continue
  t=$(lsblk -dnro TRAN /dev/$d); [ "$t" = iscsi ] && continue
  v=$(cat /sys/block/$d/device/vendor 2>/dev/null | tr -d " ")
  if [ "$kind" = rdm ] && [ "$v" = SCST_FIO ]; then echo /dev/$d; exit; fi
  if [ "$kind" = vmdk ] && [ "$v" = VMware ] && [ -z "$(lsblk -nro NAME /dev/$d | sed 1d)" ]; then echo /dev/$d; exit; fi
done'

cmd_probe() {
    local kind=$1 vm1=$2 vm2=$3 d1 d2 lba=4096 out
    d1=$(gssh "$vm1" "${GUEST_DEV//@KIND@/$kind}" | tail -1)
    d2=$(gssh "$vm2" "${GUEST_DEV//@KIND@/$kind}" | tail -1)
    case "$d1$d2" in */dev/*/dev/*) ;; *) die "shared $kind disk not found in a guest ($vm1='$d1' $vm2='$d2')";; esac
    echo "PROBE disk $kind $vm1=$d1 $vm2=$d2"
    for p in "$vm1 $d1" "$vm2 $d2"; do
        set -- $p
        out=$(gssh "$1" "sg_inq $2 | grep -E 'Vendor|Product|Unit serial' | tr -s ' ' | tr '\n' ' '; echo; sg_vpd -p bl $2 2>&1 | grep -i 'compare and write'; sg_persist -n -c $2 2>&1 | tr -s ' ' | tr '\n' ' '")
        echo "PROBE identity $1: $(echo "$out" | head -1)"
        echo "PROBE caw_vpd $1: $(echo "$out" | sed -n 2p)"
        echo "PROBE pr_caps $1: $(echo "$out" | sed -n '3,$p' | tr '\n' ' ' | cut -c1-300)"
    done
    # the fence: register both, vm1 reserves WE-RO (type 5), preempts-and-aborts vm2
    gssh "$vm1" "sg_persist -n --out --register --param-sark=0x1111 $d1 2>&1 | tail -1; echo rc=\${PIPESTATUS[0]}" | sed "s/^/PROBE pr_register $vm1: /"
    gssh "$vm2" "sg_persist -n --out --register --param-sark=0x2222 $d2 2>&1 | tail -1; echo rc=\${PIPESTATUS[0]}" | sed "s/^/PROBE pr_register $vm2: /"
    echo "PROBE pr_keys $vm1 sees: $(gssh "$vm1" "sg_persist -n -k $d1 2>&1 | tr -s ' ' | tr '\n' ' '")"
    echo "PROBE pr_keys $vm2 sees: $(gssh "$vm2" "sg_persist -n -k $d2 2>&1 | tr -s ' ' | tr '\n' ' '")"
    gssh "$vm1" "sg_persist -n --out --reserve --param-rk=0x1111 --prout-type=5 $d1 2>&1 | tail -1; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' ' | sed "s/^/PROBE pr_reserve $vm1: /"; echo
    echo "PROBE pr_write_before $vm2: $(gssh "$vm2" "dd if=/dev/zero of=$d2 bs=512 count=1 seek=$lba oflag=direct 2>&1 | tail -1; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' ')"
    gssh "$vm1" "sg_persist -n --out --preempt-abort --param-rk=0x1111 --param-sark=0x2222 --prout-type=5 $d1 2>&1 | tail -1; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' ' | sed "s/^/PROBE pr_preempt_abort $vm1: /"; echo
    echo "PROBE pr_keys_after $vm1 sees: $(gssh "$vm1" "sg_persist -n -k $d1 2>&1 | tr -s ' ' | tr '\n' ' '")"
    echo "PROBE pr_write_after $vm2 (must be refused): $(gssh "$vm2" "dd if=/dev/zero of=$d2 bs=512 count=1 seek=$lba oflag=direct 2>&1 | tail -1; echo rc=\${PIPESTATUS[0]}; dmesg | grep -i 'reservation conflict' | tail -1" | tr '\n' ' ')"
    echo "PROBE pr_write_after $vm1 (holder, must succeed): $(gssh "$vm1" "dd if=/dev/zero of=$d1 bs=512 count=1 seek=$lba oflag=direct 2>&1 | tail -1; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' ')"
    # leave nothing behind: vm1 clears every registration and the reservation
    gssh "$vm1" "sg_persist -n --out --clear --param-rk=0x1111 $d1 2>&1 | tail -1; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' ' | sed "s/^/PROBE pr_clear $vm1: /"; echo
    echo "PROBE pr_keys_final $vm1 sees: $(gssh "$vm1" "sg_persist -n -k $d1 2>&1 | tr -s ' ' | tr '\n' ' '")"
    for p in "$vm1 $d1 aa" "$vm2 $d2 bb"; do
        set -- $p
        echo "PROBE caw $1: $(gssh "$1" "/src/mxfs/tools/caw_verify write $2 $lba $3 2>&1 | tail -1; echo w=\$?; /src/mxfs/tools/caw_verify read $2 $lba $3 2>&1 | tail -1; echo r=\$?" | tr '\n' ' ')"
        echo "PROBE fua $1: $(gssh "$1" "/src/mxfs/tools/fua_verify write $2 $lba 0x$3 2>&1 | tail -1; echo w=\$?; /src/mxfs/tools/fua_verify read $2 $lba 2>&1 | tail -1; echo r=\$?" | tr '\n' ' ')"
    done
}

op=${1:-}; shift || true
case "$op" in
    rdm)    [ $# -ge 1 ] || die "rdm <device-id>"; cmd_rdm "$1" "${2:-vstest1}" "${3:-vstest2}" ;;
    vmdk)   [ $# -ge 1 ] || die "vmdk <size>"; cmd_vmdk "$1" "${2:-vstest1}" "${3:-vstest2}" ;;
    probe)  [ $# -ge 1 ] || die "probe <rdm|vmdk>"; cmd_probe "$1" "${2:-vstest1}" "${3:-vstest2}" ;;
    detach) cmd_detach "${1:-vstest1}" "${2:-vstest2}" ;;
    *) echo "usage: $0 rdm <device-id> | vmdk <size> | probe <rdm|vmdk> | detach" >&2; exit 2 ;;
esac
