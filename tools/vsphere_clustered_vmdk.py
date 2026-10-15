#!/usr/bin/env python3
"""Show or enable clustered-VMDK support on a VMFS datastore.

Usage: tools/vsphere_clustered_vmdk.py status <datastore>
       tools/vsphere_clustered_vmdk.py enable <datastore>

A clustered VMDK is the disk vSphere 7.0+ emulates SCSI-3 persistent
reservations for at the vSCSI layer, per VM, on a physical-bus-sharing
controller: the shared-disk route Windows failover clusters were moved to when
the multi-writer flag stopped carrying reservations.  It needs the datastore's
"Clustered VMDK" capability, which govc cannot read or set.  `status` prints
the datastore's capability.clusteredVmdkSupported (whether ESXi considers it
able) and Datastore.IsClusteredVmdkEnabled() (whether it is on); `enable` calls
HostDatastoreSystem.EnableClusteredVmdkSupport through the first host that
mounts it and prints vCenter's answer verbatim.

Credentials from scripts/vsphere_env.sh (GOVC_URL/USERNAME/PASSWORD); run with
the pyvmomi venv (/home/steve/.venvs/pyvmomi/bin/python3).
"""
import os
import ssl
import sys
from urllib.parse import urlparse

from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("status", "enable"):
        sys.exit(__doc__)
    op, name = sys.argv[1], sys.argv[2]
    url = urlparse(os.environ["GOVC_URL"])
    si = SmartConnect(host=url.hostname, user=os.environ["GOVC_USERNAME"],
                      pwd=os.environ["GOVC_PASSWORD"], sslContext=ssl._create_unverified_context())
    try:
        view = si.content.viewManager.CreateContainerView(si.content.rootFolder, [vim.Datastore], True)
        ds = [d for d in view.view if d.name == name]
        if len(ds) != 1:
            sys.exit(f"vsphere_clustered_vmdk: {len(ds)} datastores named {name}")
        ds = ds[0]
        print(f"datastore={name} type={ds.summary.type} "
              f"clusteredVmdkSupported={getattr(ds.capability, 'clusteredVmdkSupported', None)} "
              f"enabled={ds.IsClusteredVmdkEnabled()}")
        if op == "status":
            return 0
        host = ds.host[0].key
        try:
            host.configManager.datastoreSystem.EnableClusteredVmdkSupport(datastore=ds)
        except vim.fault.VimFault as e:
            print(f"ENABLE_REFUSED via {host.name}: {type(e).__name__}: {e.msg}")
            return 1
        except Exception as e:  # vCenter's answer is the measurement; print it whole
            print(f"ENABLE_REFUSED via {host.name}: {type(e).__name__}: {e}")
            return 1
        print(f"ENABLE_OK via {host.name}: enabled={ds.IsClusteredVmdkEnabled()}")
        return 0
    finally:
        Disconnect(si)


if __name__ == "__main__":
    sys.exit(main())
