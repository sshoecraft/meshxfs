#!/usr/bin/env python3
"""Attach an existing RDM mapping file to a VM as a physical-compatibility RDM.

Usage: tools/vsphere_rdm_attach.py <vm-name> <controller-bus> <mapping-file> <device-path>
  e.g. tools/vsphere_rdm_attach.py vstest1 1 "[mxfs-shared] mxfs-rdm-map/mxfs-rdm-map.vmdk" \
           /vmfs/devices/disks/eui.6661313331363962

govc can create an RDM (vm.rdm.attach) but writes the mapping file into the
VM's home, which must be VMFS, and it can only attach an EXISTING disk file as
a flat VMDK: vSphere refuses that for a mapping ("Incompatible device backing
specified").  Two VMs sharing one RDM need exactly that second step, so this
does it with VMware's SDK: a RawDiskMappingVer1 backing in physicalMode,
naming the mapping file, on the VM's SCSI controller with bus number
<controller-bus>, independent-persistent, at the first free unit.

Credentials come from the environment scripts/vsphere_env.sh exports
(GOVC_URL, GOVC_USERNAME, GOVC_PASSWORD).  Needs pyvmomi; the venv is
/home/steve/.venvs/pyvmomi (python3 -m venv ...; pip install pyvmomi), and
scripts/vsphere_shared_disks.sh runs this with that interpreter.
Prints RDM_ATTACHED <vm> scsi<bus>:<unit> <mapping-file>, exits 1 on failure.
"""
import os
import ssl
import sys
import time
from urllib.parse import urlparse

from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim


def wait(task):
    while task.info.state in (vim.TaskInfo.State.queued, vim.TaskInfo.State.running):
        time.sleep(0.5)
    if task.info.state != vim.TaskInfo.State.success:
        raise RuntimeError(task.info.error.msg if task.info.error else "task failed")


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    name, bus, mapping, device = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    url = urlparse(os.environ["GOVC_URL"])
    ctx = ssl._create_unverified_context()
    si = SmartConnect(host=url.hostname, user=os.environ["GOVC_USERNAME"],
                      pwd=os.environ["GOVC_PASSWORD"], sslContext=ctx)
    try:
        view = si.content.viewManager.CreateContainerView(si.content.rootFolder, [vim.VirtualMachine], True)
        vms = [v for v in view.view if v.name == name]
        if len(vms) != 1:
            sys.exit(f"vsphere_rdm_attach: {len(vms)} VMs named {name}")
        vm = vms[0]
        devs = vm.config.hardware.device
        ctl = [d for d in devs if isinstance(d, vim.vm.device.VirtualSCSIController) and d.busNumber == bus]
        if not ctl:
            sys.exit(f"vsphere_rdm_attach: {name} has no SCSI controller on bus {bus}")
        ctl = ctl[0]
        for d in devs:
            b = getattr(d, "backing", None)
            if isinstance(b, vim.vm.device.VirtualDisk.RawDiskMappingVer1BackingInfo) and b.fileName == mapping:
                print(f"RDM_ATTACHED {name} scsi{bus}:{d.unitNumber} {mapping} (already)")
                return 0
        used = {d.unitNumber for d in devs if getattr(d, "controllerKey", None) == ctl.key}
        unit = next(u for u in range(16) if u != 7 and u not in used)

        backing = vim.vm.device.VirtualDisk.RawDiskMappingVer1BackingInfo()
        backing.fileName = mapping
        backing.deviceName = device
        backing.compatibilityMode = "physicalMode"
        backing.diskMode = "independent_persistent"
        disk = vim.vm.device.VirtualDisk()
        disk.backing = backing
        disk.controllerKey = ctl.key
        disk.unitNumber = unit
        disk.key = -1
        spec = vim.vm.device.VirtualDeviceSpec()
        spec.operation = vim.vm.device.VirtualDeviceSpec.Operation.add
        spec.device = disk
        wait(vm.ReconfigVM_Task(vim.vm.ConfigSpec(deviceChange=[spec])))
        print(f"RDM_ATTACHED {name} scsi{bus}:{unit} {mapping}")
        return 0
    finally:
        Disconnect(si)


if __name__ == "__main__":
    sys.exit(main())
