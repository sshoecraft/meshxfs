---
name: compiled-nested-esxi-disposability-frozen-host-fencing-and-common-case-focus
description: Nested ESXi hosts are disposable; a frozen hypervisor host defeats time-based self-fencing; spend effort on the 99% case, record corner cases briefly.
metadata:
  type: feedback
tags: [compiled, esxi, vsphere, fencing, user-direction]
---

Shared topic: the nested-ESXi / vSphere test setup (esxhost1, esxhost2, vstest1/vstest2) and how much effort its failure corners deserve. All three notes date from 2026-10-13.

## Nested ESXi hosts are disposable
Source: `feedback-nested-esxi-hosts-are-disposable`.

User, after I asked before discarding esxhost1's suspended state: "I don't care if you reset ESX Host 1 or it loses whatever state that it has... these are nested hosts and you saw that I rebuilt ESX Host 2 in about 10 minutes. It's not a big deal if we wipe one of these hosts out."

**How to apply:** the nested ESXi hosts (Workstation VMs in ~/vms/vmware/esxhost{,2}/) and the vSphere guests on them (vstest1/vstest2) are test infrastructure, like the rig VMs. Reset, power-cycle, discard saved state or rebuild as the work needs, without asking first. Say what you did afterwards. vCenter is NOT covered.

**Trap:** never suspend esxhost1 and esxhost2 together. Both attach the Workstation-shared disk `~/vms/vmware/shared-cvmdk/esx-shared-cvmdk.vmdk` on scsi1:0 (independent-persistent, sharedBus virtual). Whichever resumes second fails: "Resuming virtual disk 'scsi1:0' failed. The disk has been modified since ... suspended". Recovery: delete that host's `<vmx-dir>/esxhost-*.vmss` and `.vmem` (named in full) and start it cold; the `.vmx` holds no checkpoint reference. To free their RAM (about 8.5 GB each) without that trap, power them off instead of suspending.

## A frozen hypervisor host defeats time-based self-fencing
Source: `trap-a-frozen-hypervisor-host-defeats-time-based-self-fencing`.

Measured on vstest1/vstest2 (fence=quorum, physical RDM, qnetd on serv), `tests/vsphere_shared_fence.sh freeze host` (Workstation `vmrun pause` of nested ESXi host esxhost2):
- Survivor took the frozen node over at +75 s (kind 30, "loser ended its boot"). After unpause, 4 of the victim's stamped O_DIRECT blocks changed on disk: 3 were commands queued in ESXi at the pause, 1 was a fresh write the resumed guest issued 0.83 s of guest time later.
- Guest CLOCK_BOOTTIME did not advance across the host pause, so its 3 s quorum lease still read valid on resume.
- Its corosync merged back into the membership and never reported inquorate, so the helper never told the kernel to reset.
- The node never reset. Its FS shut down only when its disk heartbeat saw its slot taken (P290-AUTH-WITHDRAW reason=SLOT_TAKEOVER).
- Control: vSphere guest suspend (`govc vm.power -suspend`) gave zero late writes. A suspend drains I/O, so it is NOT a valid test of a freeze; a host pause is.

**Apply:** a fence whose proof is "the deadline passed, so the loser ended itself" (watchdog, lease, quorum loss -> emergency_restart, SBD-style) is defeated by a hypervisor-host freeze. Do not claim it safe on a VM without a storage-side barrier (PR preempt) under it; measure with a host pause, never a guest suspend. DRBD is not exposed: a frozen loser's late writes reach only its own excluded replica.

Defect: D-QUORUM-FROZEN-HOST-LATE-WRITES-AFTER-TAKEOVER. Evidence: tests/evidence/vsphere/quorum-11-freeze-host/.

## Spend time on the common case, not the rare corner case
Source: `feedback-spend-time-on-the-common-case-not-the-rare-corner-case`.

Context: a session spent most of its effort on vSphere fencing corner cases (hypervisor host frozen with no PSOD, made on purpose with a Workstation pause of a nested ESXi host; qnetd lost on both nodes; repeat split laps) while the thing the user cared about, multi-writer VMDK sharing and its 5x create slowdown, sat untouched. The user ran VMware for about 10 years, as team lead for all of HP, and "very very rarely saw a completely frozen VMware host."

User: "I feel like you're getting off on a tangent here, spending a lot of energy on a corner case." Then: "we are not going to spend 99% of our time on the less than 1%. We're going to spend 99% of our time on the 99%."

**Why:** effort is finite. A feature that works in the rare case but is slow or broken in the everyday case is worth nothing to users; chasing the 1% hides 99% problems.

**How to apply:**
- Before a test, design or fix, ask how many real deployments hit it. Make common paths correct and fast first: everyday workloads, ordinary crashes and power-offs, performance against native.
- When a rare failure turns up, record it in a few lines (defect record, one sentence in the doc), tell the user, return to main work. No harnesses, measurements or fixes for it unless asked.
- If unsure whether something is a corner case, ask the user in one line; their field experience outranks a lab worst case.
- This decides where time goes; it does not erase a found defect. The record stays in the queue at the severity and bar the user sets.
