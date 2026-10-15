---
name: compiled-proxmox-ve-primary-target-vmfs-parity
description: MeshXFS primary target is Proxmox VE as a VMFS-style shared datastore on a SAN LUN; rank work by that, the rest is 1% for now.
metadata:
  type: feedback
tags: [compiled, proxmox, target, vmfs, priorities]
---

Assorted group of one note: the project's primary deployment target. Source: `feedback-proxmox-ve-is-the-primary-target-vmfs-parity`.

## Decision (user, 2026-10-13)
Made after research found VMware's VMFS has the largest installed base of any clustered filesystem (VMware base about 300k-400k customers, ~40-45% of virtualization platforms). Windows Cluster Shared Volumes under Hyper-V is second. Linux GFS2/OCFS2/Veritas CFS are far smaller. `feedback-proxmox-ve-is-the-primary-target-vmfs-parity`

User's reading: VMFS is everywhere only because ESXi ships it by default and there is no alternative. Quote: "I guess we target Proxmox as our primary base. Because Proxmox with MXFS puts it on par with VMware and VMFS." `feedback-proxmox-ve-is-the-primary-target-vmfs-parity`

## How to apply
- Rank work by whether it serves Proxmox VE clusters using MeshXFS as a VMFS-style shared datastore: several PVE hosts on one shared SAN LUN (FC or iSCSI, multipathed in production), holding VM disks, with live migration and HA between hosts. `feedback-proxmox-ve-is-the-primary-target-vmfs-parity`
- Earlier research (Proxmox forum staff, PVE storage docs, PVE 9 SAN guides, array vendors' Linux guides): Proxmox has no supported cluster filesystem. Its supported SAN path is thick LVM, which lost snapshots until PVE 9's volume chains. Production SANs are multipathed (at least two NICs/paths, four as vendor minimum). Proxmox recommends 3+ nodes for HA, or 2 plus a QDevice. Fibre Channel still leads enterprise SAN revenue; iSCSI leads the midmarket. `feedback-proxmox-ve-is-the-primary-target-vmfs-parity`
- Also in the 1% for now: multi-writer VMDK on vSphere, the frozen-hypervisor case, 32 nodes, general Linux app clusters. Record what turns up there; don't lead with it. See feedback-spend-time-on-the-common-case-not-the-rare-corner-case. `feedback-proxmox-ve-is-the-primary-target-vmfs-parity`
- Don't assume which PVE features matter most (live migration, HA, qcow2 snapshots/thin provisioning, backup). Check with the user or research it. `feedback-proxmox-ve-is-the-primary-target-vmfs-parity`
