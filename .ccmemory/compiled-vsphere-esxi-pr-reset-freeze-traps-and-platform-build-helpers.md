---
name: compiled-vsphere-esxi-pr-reset-freeze-traps-and-platform-build-helpers
description: vSphere/ESXi lab traps: pRDM power-off drops PR key, guest reset rc=0 is no array witness, VMware claims need a web search, freeze detection, stale g…
metadata:
  type: feedback
tags: [compiled, vsphere, esxi, prdm, pr-key, wsfc, multi-writer, freeze, glibc, platform-build]
---

Topic: running MeshXFS on the vSphere lab (ESXi 8.0.2, nested under Workstation on clyde; AlmaLinux 9.8 guests vstest1/vstest2, glibc 2.34): what ESXi does to SCSI persistent reservations and resets, how to freeze-diagnose a guest, what not to assert about VMware from memory, and the platform-build trap that made a CAW test grade PASS wrongly.

## pRDM power-off and reset behaviour  `trap-esxi-prdm-poweroff-drops-pr-key-and-guest-reset-success-is-esxi-not-array`

Measured on ESXi 8.0.2, physical-mode RDM of an SCST LUN on a physical-bus-sharing pvscsi controller, one VM per ESXi host (session fe2609ab).

- **Power-off removes the VM's registration.** `govc vm.power -off -force` on vstest2: PR generation 0x3a -> 0x3c within 3 s, vstest2's key gone, not restored at power-on (`tools/vsphere_poweroff_key_probe.sh`, `tests/evidence/vsphere/probe-rdm-poweroff-key.txt`). MeshXFS's death fence then sees KEY_ABSENT_UNPROVEN and refuses the slice, by design. `crash_audit` on an RDM board therefore FAILs (no "foreign replay of" verdict) - the designed refusal, not a harness gap. Queue: D-VSPHERE-RDM-POWEROFF-UNREGISTERS-KEY-RECOVERY-REFUSED.
- **A guest's reset is not an array witness.** `sg_reset -d`/`-b` from the guest does reach SCST as `TM fn LUN_RESET` from the ESXi initiator (`-H` sends nothing), but with clyde dropping that ESXi host's 3260 traffic the guest's `sg_reset -d` still returned rc=0 in 5 ms with no TMF at the target (`tools/vsphere_reset_witness_probe.sh`). Do not propose "accept the pvscsi reset as the LU-reset witness".
- SCST logs every TM fn at default trace level in clyde's dmesg (`scst_rx_mgmt_fn ... TM fn LUN_RESET`), so a forwarded TMF can be checked without turning a trace flag on.
- Clustered VMDK: vCenter refuses it (NotSupported) on iSCSI VMFS and on a Workstation-shared disk (transport `parallel`, ATS unsupported). VMware supports it on FC, and on NVMe/TCP only from 8.0 U3; Linux nvmet has no fused commands, so it cannot be the NVMe backing either.
- In-guest iSCSI (`direct`) avoids all of this: the key belongs to the guest's own nexus and survives the power-off, so PREEMPT AND ABORT names it.

## Search before asserting VMware behaviour  `feedback-web-search-vmware-behaviour-before-asserting-it-multi-writer-wsfc`

User, 2026-10-13, after I said from memory that "Microsoft clusters don't use multi-writer": "That's fully incorrect. I have seen lots of Microsoft clusters. In fact, I built one that I built file clusters using a multi-writer disk." Then: "do a web search before assuming."

- Multi-writer VMDKs on a physical-bus-sharing controller were a common WSFC/MSCS shared-disk setup before ESXi 7.0. Broadcom KB 395751: the flag is "no longer supported on MSCS VMs using shared disks starting with ESXi 7.0".
- Since 7.0 the route is the clustered VMDK. ESXi emulates SCSI-3 PR-IN/PR-OUT per VM at the vSCSI layer. Needs a physical-bus-sharing controller, VMFS6 with the datastore's Clustered VMDK capability, eager-zeroed thick disks, an array with ATS and WEAR, and one node per host. KB 313472 (8.x) lists FC and NVMe-oF, not iSCSI.
- Measured on 8.0.2: a multi-writer VMDK answers no PERSISTENT RESERVE (invalid opcode) and no COMPARE AND WRITE, whether its controller has physical bus sharing or none. vCenter refuses `EnableClusteredVmdkSupport` (NotSupported) on the lab's iSCSI-backed VMFS6 datastore.
- A physical-mode RDM with one VM per ESXi host forwards PR per guest, plus COMPARE AND WRITE and FUA. With two VMs on one host they share one I_T nexus.
- Apply: before telling the user how a VMware or other vendor feature behaves, search or measure it; they have deep hands-on VMware experience and an assertion from memory that contradicts it costs credibility. When a probe gives one answer, state exactly which configuration it covered (controller bus sharing, host placement, ESXi version); never generalize to "X doesn't do Y".
- Related: `scripts/vsphere_shared_disks.sh`, `tools/vsphere_clustered_vmdk.py`, `docs/attachment-methods.md` ("pass on VMware").

## Guest freeze: detect from outside, read clocks from a memory image  `technique-vsphere-guest-freeze-detect-from-vmware-log-and-read-guest-clocks-from-memory-image`

Learned on vstest2 (AlmaLinux 9.8, nested ESXi under Workstation on clyde), 2026-10-13.

- **Detect from OUTSIDE the guest.** When a guest stops making progress, VMware Tools' heartbeat to the VMX stops; the VM's `vmware.log` (datastore `vms`, `<vm>/vmware.log`) prints `Tools: Tools heartbeat timeout.` ~20 s in and `Tools: Running status rpc handler: 0 => 1.` on recovery. Trustworthy exactly when the guest's own logs are not (a frozen guest logs nothing). `grep -E 'Tools heartbeat timeout|Running status rpc handler: 0 => 1'` lists every freeze with duration. vstest2 had 14 in 3.5 h, each 4 min 32 s; vstest1 none. A MeshXFS fence on vSphere coinciding with one is the guest freezing, not MXFS losing beats.
- **Reading the cause.** `tools/vsphere_freeze_catch.sh <vm> <max_s>` takes a memory snapshot on the first new timeout line; `sudo vmss2core <vmsn> <vmem>` (NO -N6: that writes a physical-memory core gdb cannot read kernel VAs from) gives per-vCPU linear cores; `tools/vmss_cpu_state.py` prints per-CPU call_single_queue, ksoftirqd, timer base, hrtimer/tick state and the timekeeper. Debuginfo for the exact EL9 kernel: vault.almalinux.org/9.8/BaseOS/debug/x86_64/Packages/; clyde has no rpm2cpio - extract on an EL guest over /src (clyde's /src is the guests' /src). First freeze image: queues empty, but every CPU's last_tick and the timekeeper's xtime stopped at the same instant ~30 s before the snapshot - the guest's clock stopped, the vCPUs were not withheld (vCenter cpu.ready ~150 ms/20 s, costop 0: `tools/vsphere_vm_cpu_samples.sh`).
- **Commands in a guest whose network is dead:** `tools/vsphere_guest_run.sh <vm> '<cmd>'` (VMware Tools channel). TRAP: `govc guest.run` hands the program line to the guest's shell and appends its output redirect at the END, so `bash -c "a; b; c"` passed as words returns only `c`'s output; the tool ships the command base64 and decodes it into one `bash -c` argument. Also a sourced `scripts/vsphere_env.sh` reads the CALLER's $1 as its entry name - pass `lab` explicitly.
- **Do not trust the "fault follows esxhost2" memory as current:** on 2026-10-13 the freezing guest was the one on esxhost1, whose .vmx (user-tuned) carries `monitor_control.virtual_rdtsc = "FALSE"` and `monitor_control.halt_aware = "TRUE"` that esxhost2's lacks.

## Platform rebuild leaves stale single-file helpers  `trap-platform-rebuild-leaves-single-file-helpers-linked-on-clyde`

On the vSphere AlmaLinux 9 guests (glibc 2.34), `dlm_lock_correctness` read `caw=fail` and still graded PASS ("partial: one primitive supported"). COMPARE AND WRITE worked fine on the in-guest iSCSI path to SCST (`sg_inq -p 0xb0` showed max compare-and-write 255 blocks). The probe never ran: `tools/caw_verify` is a single-file program NOT in `tools/Makefile`'s TOOLS, so `make clean` does not delete it; the copy linked on clyde (glibc 2.38) survived `scripts/platform_build.sh` and exited with "version `GLIBC_2.38' not found". The test sent stderr to /dev/null, so the loader failure read as the array refusing the command.

- Same class then: `caw_slotdump`, `recov_forge`, `tests/caw/caw_align_probe`, `tests/fence_inflight/prprobe`. platform_build.sh now builds those, plus `mxfs_mmapio` (`-I include`: caw_slotdump includes `<mxfs/mxfs_super.h>`).
- After any platform switch, sweep the tree: `objdump -T <f> | grep -o 'GLIBC_[0-9.]*' | sort -V | tail -1` over every ELF under tools/, tests/ (excluding tests/evidence), scripts/ and bench/, compared against the node's glibc.
- A new single-file C helper the harness runs must be added to platform_build.sh's helper loop, else the next platform runs a stale binary.
- A grader must tell "tool would not start" (rc 127, or a loader message) apart from "primitive refused", and never grade a failed primitive as PASS on a configuration that needs it.
- Provenance: ccloop run 8bd0eed0, session 3, 2026-10-13.
