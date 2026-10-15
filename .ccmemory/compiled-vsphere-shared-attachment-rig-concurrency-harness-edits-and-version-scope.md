---
name: compiled-vsphere-shared-attachment-rig-concurrency-harness-edits-and-version-scope
description: vSphere rig traps: no vSphere laps beside DRBD verification, no harness edits under a loop, bootTime on reboot, forced swap-hold test, one VMware ver…
metadata:
  type: feedback
tags: [compiled, vsphere, drbd, rig, harness, versioning]
---

Topic: vSphere shared-attachment (multi-writer VMDK, fence=vcenter|manual) rig traps and the version-scope rule for all VMware work. Provenance: ccloop run 8bd0eed0 sessions 6-7, 2026-10-13.

## vSphere laps and DRBD verification share clyde  `trap-vsphere-laps-and-drbd-rig-share-clyde-and-a-harness-edited-under-a-running-loop`
- Nested ESXi guests' datastores are NFS on clyde; the DRBD rig's test1/test2 use clyde's iSCSI pool on the same NVMe (nvme0n1p2).
- With RDM/VMDK laps running, the DRBD `fio_perf` row failed BUDGET_EXHAUSTED (host_disk wms_p95=152.6 ms).
- During `resolve-test` (mxfs loaded on test1 alone for loop-device checks, nothing mounted on DRBD), test1's kernel log went silent 17 s, then test2 shut the DRBD connection and test1's fence handler stonithed test2. Outage and takeover steps never ran. Causality not proven (test2's log died with it), but verification is evidence only on a quiet host.
- Run DRBD release verification with vSphere guests idle, and the reverse.

## Never edit a harness a background loop is executing  `trap-vsphere-laps-and-drbd-rig-share-clyde-and-a-harness-edited-under-a-running-loop`
- The loop calls `tests/vsphere_shared_fence.sh <step>` once per step; bash reads the rest of a script by byte offset after the current command. An Edit inserting bytes before the tail (the `case` dispatch) shifts the offset; a running step can resume mid-line in the dispatch, e.g. at `cmd_baseline`, which reformats the shared disk.
- If edited by mistake, restore the exact previous bytes at once. Edit only between runs.

## rsync rc 23 chained into cd  `trap-vsphere-laps-and-drbd-rig-share-clyde-and-a-harness-edited-under-a-running-loop`
- rsync of the tree returns 23 on root-owned files (`.xfs_fio_baseline.*.json`, `bench.json`). `rsync ... && cd $S && make` then runs `make` in the CURRENT directory (the shared tree). Never chain on rsync's rc into a cd; use `cd $S || exit`.

## runtime.bootTime is not "power-on only"  `trap-vsphere-boottime-changes-on-guest-reboot-and-a-dead-swap-holder-needs-a-forced-hold-to-test`
- Docs and a forum thread said vCenter VirtualMachine `runtime.bootTime` changes only on powered-off -> powered-on. Measured on ESXi 8.0.2 / vCenter (vstest2): guest `systemctl reboot` CHANGED it (15:31:40 -> 15:36:20); `govc vm.power -off` cleared it (None); power-on set it again. vMotion never measured.
- Never use bootTime as proof a boot ended or continued without measuring the exact operation. The shared attachment instead re-tags the VM from inside each new boot (`mxfs_fence_vcenter.py boot`, `mxfs-vcenter-tag.service`), same mechanism as the mount-time arm.

## Testing "a peer died holding the emulated swap lock"  `trap-vsphere-boottime-changes-on-guest-reboot-and-a-dead-swap-holder-needs-a-forced-hold-to-test`
- Random panics hit this window only sometimes (1 of 2 vcenter panic laps, 0 of 5 manual). Deterministic: `HOLD_MS=30000 tests/vsphere_shared_fence.sh kill panic <survivor> <victim>` arms `dbg_drbd_cas_hold_ms` on the victim (next swap sleeps inside the critical section), waits 3 s, panics it.
- PROVE the hold took effect: with per-sector claims a disjoint hold leaves NO trace on the survivor (partial=0 contended=0 in P-DRBD-CAS-STATS fits both "hold disjoint" and "hold never fired"). The harness reads the victim's lock register off the shared disk from the survivor (area_lba from P-SHARED-CAS-ATTACH, sector area+1+victim_index) and decodes raised/want/nranges/ranges (`VICTIM_REG raised=1 nranges=1 ranges=628728+8`). Without that read a green lap is vacuous.
- Why it mattered: before per-sector claims such a death made every survivor swap fail at the 10 s bound; under fence=manual the survivor's heartbeat stopped, its authority lease expired at 62 s and it withdrew before the death was declared (D-SHARED-MANUAL-SWAP-HOLDER-DEATH-WITHDRAWS-SURVIVOR).

## Don't relax the authority lease to fix such a stall  `trap-vsphere-boottime-changes-on-guest-reboot-and-a-dead-swap-holder-needs-a-forced-hold-to-test`
- Tempting because a shared-attachment peer needs a death certificate (VM off / operator) to recover a slice. But the lease also prevents split brain when a frozen peer resumes and finds the survivor's heartbeat stale (both think the other dead and master locks). A lock-free own-heartbeat write is unsafe: peers write a node's heartbeat slot on AGING (settle/withdrawn/guard), not only after a certificate (hb_cas_own_slot comment, 0.60.0). The fix had to be in the lock: per-sector claims (`tests/drbd_cas_lock_model.py --ranges`).

## All VMware work is one version  `feedback-all-vmware-work-is-one-version-0-90-128`
- User, 2026-10-13, after 0.90.128 -> 0.90.129 was bumped to start the manual and vCenter fence methods for multi-writer VMDKs: "NO go back to .128 ... stop revving every 10 seconds ... just do ALL vmware work as .128".
- The open version names the whole platform effort ("VMware: MeshXFS on vSphere, its shared disks and how to fence on them"). A new mechanism that exists to make that platform work (fence method, helper, harness) is part of the same work, even when it touches core code like recovery. Judge "different work" by the user's unit (platform or campaign), not by which subsystem the change lands in.
