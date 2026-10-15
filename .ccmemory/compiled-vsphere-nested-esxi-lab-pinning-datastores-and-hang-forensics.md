---
name: compiled-vsphere-nested-esxi-lab-pinning-datastores-and-hang-forensics
description: Nested ESXi lab on clyde: Workstation CPU pinning via processorN.use, one guest per host, clyde-only NFS datastores, vmss2core+gdb hang forensics
metadata:
  type: project
tags: [compiled, vsphere, esxi, workstation, affinity, vmss2core, nfs, govc]
---

Topic: the vSphere lab on clyde (nested ESXi hosts esxhost1/esxhost2, guests vstest1/vstest2): CPU pinning, guest placement, datastores, and diagnosing a hung guest.

## Hosts and CPU pinning
From `reference-vsphere-nested-hosts-one-busy-guest-per-host-affinity-not-enforced`:
- esxhost1/esxhost2 run as VMware Workstation 17.6.2 VMs on clyde (8 vCPU, 16 GB each; .vmx in ~/vms/vmware/esxhost{,2}/).
- **CPU pinning (verified 2026-10-12):** Workstation on Linux honours `processorN.use = "TRUE"/"FALSE"` in the .vmx, one line per host CPU 0..55; it ignores `sched.cpu.affinity` (an ESXi key, not even in vmware-vmx; Workstation only logs it as DICT). After adding the processorN.use lines and a power cycle, vmware-vmx and every vmx-vcpu-N thread showed `taskset -cp` = 0-7,28-35 (esxhost1, socket 0) and 14-21,42-49 (esxhost2, socket 1). Before, all were 0-55. The .vmx can only be edited with the VM off (Workstation rewrites it at power-off); originals kept as `<vmx>.backup`. vCenter (4 vCPU) is not pinned.
- How found: `strings /usr/lib/vmware/bin/vmware-vmx | grep -i affinity` lists `processor%d.use`, `sched_setaffinity` and "Failed to assign this instance of %s to the desired processors"; web search found nothing. User: "I don't believe that we can't do CPU affinity" — the binary, not the docs, is the authority.
- User decision 2026-10-12: no host service/timer on clyde for VM settings; it goes in the .vmx.
- Locate a vmware-vmx's VM from `/proc/<pid>/fd` or its vCPU count, never its cmdline (clyde mmap_lock wedge).

## Guest placement
- vstest1 on esxhost1, vstest2 on esxhost2, each with a cluster DRS override `enabled=false behavior=manual` (`govc cluster.override.change -vm X -drs-mode manual`). `cluster.override.info` misreports it as "Default (FullyAutomated)"; read `govc object.collect -json /lab/host/lab configurationEx` drsVmConfig.
- Observed before pinning, cause NOT established: two 4-vCPU guests busy on esxhost2 (vstest2 DKMS compile + vstest1 OS install) -> vstest2 soft lockups on all vCPUs 49-166 s. Later vstest2 hung mid-board: memory snapshot showed all vCPUs in timer-interrupt catch-up of an 87 s clock jump (hypervisor did not run the guest), no mxfs on any stack (see technique below). The user rejected "can't run two 4-vCPU VMs on an 8-CPU host"; one guest per host is a precaution. Before trusting any timing from a vstest guest, check both guests' dmesg for soft lockups / clock jumps over the run window.

## Datastores
From `reference-vsphere-lab-datastores-mount-from-clyde-only`. User design (2026-10-12): every vSphere datastore mounts from clyde (192.168.120.1), never from a NAS directly, so the NAS behind clyde's /data can change (.4 QNAP, now .8 DR; clyde moving to Indiana mounts .4 again) without vSphere noticing.
- `iso` datastore = NFS `192.168.120.1:/data/media/cdimages/os`, readWrite on esxhost1/esxhost2. clyde's `/iso` symlinks to the same directory; `/iso/os` and `/iso/packer_cache` are self-referencing symlinks (one directory, not copies).
- clyde re-exports an NFS mount (`/data` is NFS), so the `/etc/exports` line needs `fsid=` (7101) or knfsd refuses it.
- `vms` datastore = `192.168.120.1:/home/steve/vms/vsphere`. `mxfs-shared` = VMFS6 on SCST LUN `iqn.2026-05.local.mxfs:vsphere-01` via `scripts/vsphere_lun.sh`.
- Trap: `govc datastore.create -type nfs` mounts **readOnly** unless `-mode readWrite`; uploads then 404. `govc datastore.info` has no `-host` flag; `govc ls -i <host>` lists the host's children, `govc find -i <cluster> -type h -name <h>` gives the host's own moref. `govc host.esxcli -json` puts rows under lowercase `values`; SCST LUNs show as `eui.` ids, not `naa.`.
- Boot-order gap: `/data` is `noauto` in fstab and nfs-server has no RequiresMountsFor=/data, so after a clyde reboot the iso export is missing until /data is mounted and `exportfs -ra` runs.
- After the NAS behind /data changes, ESXi may hold stale file handles: remount the `iso` datastore on both hosts.

## Technique: hung vSphere guest stacks from a memory snapshot
From `technique-hung-vsphere-guest-stacks-from-a-memory-snapshot-with-vmss2core-and-gdb`. Used 2026-10-12 on a vstest2 hang (AlmaLinux 9.8 5.14.0-687.5.3.el9_8, mxfs mounted). ~15 min; nothing reset.
1. `govc snapshot.create -vm <vm> -m=true -q=false <name>` writes `<vm>-SnapshotN.vmem` (RAM) + `.vmsn` into the VM folder on the `vms` datastore = clyde `/home/steve/vms/vsphere/<vm>/` (root, mode 600). Guest stays hung for more looks. ~60 s for 4 GiB.
2. `vmss2core -N6` makes ONE core with no VMCOREINFO and one NT_PRSTATUS: `crash` (even `--kaslr=auto`) fails "cannot determine base kernel version". Use `vmss2core <vmsn> <vmem>` with NO options: one linear-view core per vCPU (vmss.core0..N), each with that vCPU's registers.
3. KASLR slide: gdb on the core ONLY (no vmlinux loaded, else the banner is read from the file and gives a false 0x0); python loop over slides 0..0x40000000 step 0x200000 reading 13 bytes at `linux_banner + slide` == b"Linux version". Then `add-symbol-file vmlinux -o <slide>` + `core-file vmss.coreN`, `bt`.
4. Debug vmlinux: AlmaLinux `*-debuginfo` repos 404 on repo.almalinux.org; install the two RPMs from `https://vault.almalinux.org/9.8/BaseOS/debug/x86_64/Packages/` (kernel-debuginfo-common-x86_64-<v>, kernel-debuginfo-<v>).
5. `bt` stops at the IRQ stack. Interrupted context = `((struct pt_regs*)<regs arg of sysvec_apic_timer_interrupt>)->ip/sp`. `frame view` does not unwind past it; raw-scan `x/<n>gx <sp>` up to `(sp|0x3fff)+1` and `info symbol` every kernel-text word; count words >= 0xffffffffc0000000 (module range, where mxfs.ko lives). Zero module words = no mxfs on that stack.
- Reading: all vCPUs in `sysvec_apic_timer_interrupt` with `tick_limited_update_jiffies64` far behind the hrtimer `now` (87 s here) = the guest's clock jumped because the hypervisor did not run it; that produces growing "soft lockup ... stuck for N s" on several CPUs and an unanswering guest. Two-CPU-only lockups on the console did NOT mean an in-guest spin. Evidence: /home/steve/src/vstest2-hang-evidence/.
