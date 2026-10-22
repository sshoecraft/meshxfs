---
name: compiled-test-rig-evidence-traps
description: Rig/lab traps: misread evidence (bash local, stale dumps, SCST suspend, clock offsets), vSphere/ESXi rules, frozen-host fencing, common-case focus
metadata:
  type: feedback
tags: [compiled, trap, tests, rig, bash, scst, clocks, realns, cross-node, esxi, vsphere, fencing, drbd, harness, versioning, user-direction]
---

# Test-rig and lab traps: evidence that misreads as an MXFS defect, rig sharing, the vSphere/nested-ESXi lab, and where effort goes

Merged from four compiled articles. (1) The original article: four traps (an assorted tail, not one topic) that each make test/rig evidence read as an MXFS defect when it is not; common thread: a verdict built on evidence that is mis-attributed, mis-timed or mis-scripted. (2) `compiled-cross-node-ordering-realns-clock-offset`: one note on ordering events across rig nodes when the only stamps are the guests' own wall clocks. (3) `compiled-nested-esxi-disposability-frozen-host-fencing-and-common-case-focus`: three notes, all 2026-10-13, on the nested-ESXi / vSphere test setup (esxhost1, esxhost2, vstest1/vstest2) and how much effort its failure corners deserve. (4) `compiled-vsphere-shared-attachment-rig-concurrency-harness-edits-and-version-scope`: vSphere shared-attachment (multi-writer VMDK, fence=vcenter|manual) rig traps and the version-scope rule for all VMware work; provenance ccloop run 8bd0eed0 sessions 6-7, 2026-10-13.

## A. Evidence that reads as an MXFS defect when it is not

### 1. Bash `local` line expands every word before assigning
`trap-bash-local-line-expands-all-words-before-assigning`

- **Trap.** `local K="$1" D="$BASE/r$K"` expands every word of the line before `local` assigns any, so `$K` in the second assignment is the CALLER's `K` (or empty), not `$1`. `bash -c 'f(){ local K="$1" D="r$K"; echo $D; }; K=30; f 21'` prints `D=r30`.
- **Cost.** `tests/suite/dirent_durability.sh` `verify_round` had exactly this line. Every "verify round J" listed the round being created instead, and the final settle judged every pending round against the LAST round's listing. On the 0.90.131 release build it produced a critical "stale directory view" verdict (D-DIRVIEW-NONCONVERGE-SESS25, 8/disk/caw/direct, run 20261019T214738Z-g8): six round directories convicted with one identical missing set, while the kernel log showed every `ls` reading r30 (inode 4194445) and r21-r26 holding all names on the platter. The original sess25 observation (r21-r28 missing the same 28 peers) has the same signature.
- **Tell.** Several DIFFERENT directories/objects convicted with the IDENTICAL missing set, and the probes for the convicted inodes silent while one other inode logs on every check.
- **Apply.** Write `local K="$1"` and `local D="...$K"` as two statements. Sibling bug: a helper that assigns a global loop variable (`K=$1` without `local`) silently rewrites the caller's loop index for the rest of that iteration (`tests/sf_mkdir_storm.sh`). Scanner used: a python pass over tests/scripts `local|declare|export` lines flagging an assignment whose value references a name declared earlier on the same line.

### 2. `*_drc_blkdump_*` dirs in run evidence can be months-old node leftovers
`trap-drc-blkdump-dirs-in-run-evidence-can-be-months-old-node-leftovers`

- **Trap.** `run.sh` (around line 2017) copies `/root/drc_blkdump_*` from each node into the run's artifact directory (e.g. `run_dirent_durability_<RUNID>/test11_drc_blkdump_dsc_node11/dmesg_at_fail.txt`). Those are written by suite rows' failure dumps (`tests/suite/dlm_scaling.sh:98-101`, `dmesg | tail -n 4000`) into the node's `/root`, which survives reboots and module reloads. A run's evidence can hold a dump from a different boot, weeks earlier.
- **Measured 2026-10-19:** `run_dirent_durability_20261019T191246Z-g8/test11_drc_blkdump_dsc_node11/dmesg_at_fail.txt` showed an XFS `Internal error rec.ir_free != frec->ir_free` (inobt/finobt mismatch) and a corruption shutdown, looking like a new integrity failure during the 19:14Z storage outage. It was not: its uptime (16863 s) did not match the node's boot (~1300 s then), and its `realns=` values decode to 2026-08-20 (`date -u -d @<realns/1e9>`), an old dlm_scaling incident already in the queue.
- **Apply.** Before treating any `*_drc_blkdump_*` file as this run's evidence, check its uptimes fit the node's boot in `kernlog_<node>.gz` and that `realns=` decodes to the run's date. Prefer `kernlog_<node>.gz` / `kmsg_<node>_fromnode.gz`, captured per run.

### 3. SCST reconfig suspends every LUN behind a frozen guest's command
`trap-scst-reconfig-suspends-every-lun-behind-a-frozen-guests-command`

- **Trap.** A write to any SCST management file (add/del device, LUN, initiator, target enable, allowed_portal) calls `scst_suspend_activity(SCST_SUSPEND_TIMEOUT_USER = 90 s)`: SCST stops admitting commands on EVERY LUN it exports and waits for every already-admitted command to finish (`/src/scst/scst/src/scst_main.c:840`). A guest a test froze (virsh suspend), or whose storage path is cut or muted, holds its in-flight command (state PREP_DONE_CALLED for a WRITE waiting for data-out) until its iSCSI connection times out. For that long every LUN on the host stalls, and every MXFS node self-fences (AUTHORITY_LEASE_EXPIRED).
- **Measured 2026-10-19 19:14:14Z** (session a718c549): a `tools/lun_pool.sh` bind of test29/test30 waited 49 s on one WRITE of test18, which path_fenced_return had frozen 12 s before. The 8-node mpath suite, a 4-node and an 8-node lap and a 2-node fence lap all failed together. Host journal: `scst_suspend_activity:881:Waiting for N active commands`, then `scst_susp_wait: ... still not completed` with a per-command dump naming the session, then `All active commands completed`. sar showed no I/O storm (tps dropped).
- **Apply.**
  - When every cluster on clyde fails at once, grep the host journal for `scst_suspend_activity|scst_susp_wait` before suspecting MXFS or an I/O storm.
  - `tools/lun_pool.sh` gates every reconfiguration (scst_quiet_begin: no paused guest, no storage NIC link down, no netem mute, read from virsh/tc). Every fault injector must go through `tools/lun_pool.sh fault <command>`, or `fault-lock` for a shell-function injector such as QMP. A new test that freezes a guest or cuts a path and skips that gate reopens the race.
  - `tools/lun_pool.sh faults` prints what would hold a reconfiguration back; `tests/scst_reconfig_fault_gate.sh` verifies the gate.
  - A short suspend with nothing stuck is normal (dozens a day); it only hurts when a command cannot finish.

### 4. Frozen-guest uptime stops, so the cross-node offset steps by the freeze
`trap-frozen-guest-uptime-stops-so-cross-node-offset-steps-by-the-freeze`

- **Trap.** A rig row that freezes a guest (path_fenced_return: virsh suspend, then resume) stops that guest's kernel clock (kvmclock) for the whole freeze. Its uptime does not advance, so the uptime offset between it and any other node is one number before the freeze and another after; the step equals the freeze length.
- **Seen** 0.90.131 lap 9 (board_20261019T141313Z_path_fenced_return): test1-test2 offset was 352.5 s on every protocol pair before the freeze and 396.5 s after, a 44.0 s step against a 14:14:16-14:14:59 freeze. A record built on one offset (388.5 s, taken just after the thaw) placed test2's pre-row mount (incarnation 2128268000, slot claimed before the row's PF-MARK) as a remount after the thaw. It then read the row's own fence of that frozen incarnation as "the rejoined node declared dead 70 s later", and read the injected path-a outage (heartbeat LOCKWAIT 14.4 s) as an unexplained stall. That opened a release-blocking record, D-NETMESH-MPATH-REJOINED-NODE-HEARTBEAT-LOCKWAIT-STALL-DECLARED-DEAD, later DISPROVED.
- **Apply.**
  - Before ordering two nodes' events across a freeze or fence, take offset pairs on BOTH sides: join/MEMBERSHIP before, reconnect/departure after. If they differ, the frozen node's clock stopped; place each event with the offset of its own side.
  - Identify incarnations by node id: the `claimed heartbeat slot N for node <id>` line, compared against the row's PF-MARK. A death declaration names an id; check whether it is the frozen one or the rejoined one before calling it unexpected.
  - Map a heartbeat stall onto links.log (the row's path down/up times) before treating it as a defect. A LOCKWAIT that ends with multipath `Failing path` is the injected outage.

## B. Ordering events across nodes by guest clocks (from `compiled-cross-node-ordering-realns-clock-offset`)

### Trap: guest realns clocks are only loosely synced

The `realns=`/`realms=` fields MXFS probes print are each guest's own CLOCK_REALTIME. Guests on clyde are NTP-synced, but only loosely. They disagree by tens of ms (~20 ms measured below), so a realns-based cross-node order is unreliable for events closer than ~50 ms. `trap-guest-realns-disagree-tens-of-ms-bound-offset-from-causal-pairs`

### Measured case: kwf2 (g2b, test15/test16, 2026-10-18) `trap-guest-realns-disagree-tens-of-ms-bound-offset-from-causal-pairs`

- The realns-derived uptime offset said test16 = test15 - 0.2425 s.
- Two causal pairs bounded it to -0.2228 < d < -0.2207 s:
  - test15's unlock (P70-BP EXIT) must precede test16's grant (P138-ACQ after a 182 ms wait);
  - test16's P6H-HANDOFF must precede test15's P6H-ADOPT (realns put the adopt 20 ms BEFORE the handoff).
- So realns was off by ~20 ms, enough to put a peer's removal after the write that clobbered it, or a grant before the release it waited for.
- Arithmetic on those figures: the bound window is 2.1 ms wide (hence the +-1 ms bound), and the realns-derived -0.2425 s lies 19.7-21.8 ms outside it.
- An earlier session had concluded "offsets differ by 4.7 ms, so stamps compare directly" from realns alone.

### How to apply `trap-guest-realns-disagree-tens-of-ms-bound-offset-from-causal-pairs`

- When an argument depends on the order of two events on different nodes less than ~50 ms apart, do not order them by realns.
- Find at least one pair on each side that the protocol forces into an order: A's unlock -> B's grant that was waiting; B's handoff -> A's adopt; a BAST receive after the request. (kwf2 used one pair per direction.)
- Compute uptime offset bounds from those pairs, and convert with the bounded offset.
- State the bound (+-1 ms here) with the conclusion.

## C. Nested ESXi / vSphere lab: disposability, frozen hosts, effort focus (from `compiled-nested-esxi-disposability-frozen-host-fencing-and-common-case-focus`)

Shared topic: the nested-ESXi / vSphere test setup (esxhost1, esxhost2, vstest1/vstest2) and how much effort its failure corners deserve. All three notes date from 2026-10-13.

### Nested ESXi hosts are disposable
Source: `feedback-nested-esxi-hosts-are-disposable`.

User, after I asked before discarding esxhost1's suspended state: "I don't care if you reset ESX Host 1 or it loses whatever state that it has... these are nested hosts and you saw that I rebuilt ESX Host 2 in about 10 minutes. It's not a big deal if we wipe one of these hosts out."

**How to apply:** the nested ESXi hosts (Workstation VMs in ~/vms/vmware/esxhost{,2}/) and the vSphere guests on them (vstest1/vstest2) are test infrastructure, like the rig VMs. Reset, power-cycle, discard saved state or rebuild as the work needs, without asking first. Say what you did afterwards. vCenter is NOT covered.

**Trap:** never suspend esxhost1 and esxhost2 together. Both attach the Workstation-shared disk `~/vms/vmware/shared-cvmdk/esx-shared-cvmdk.vmdk` on scsi1:0 (independent-persistent, sharedBus virtual). Whichever resumes second fails: "Resuming virtual disk 'scsi1:0' failed. The disk has been modified since ... suspended". Recovery: delete that host's `<vmx-dir>/esxhost-*.vmss` and `.vmem` (named in full) and start it cold; the `.vmx` holds no checkpoint reference. To free their RAM (about 8.5 GB each) without that trap, power them off instead of suspending.

### A frozen hypervisor host defeats time-based self-fencing
Source: `trap-a-frozen-hypervisor-host-defeats-time-based-self-fencing`.

Measured on vstest1/vstest2 (fence=quorum, physical RDM, qnetd on serv), `tests/vsphere_shared_fence.sh freeze host` (Workstation `vmrun pause` of nested ESXi host esxhost2):
- Survivor took the frozen node over at +75 s (kind 30, "loser ended its boot"). After unpause, 4 of the victim's stamped O_DIRECT blocks changed on disk: 3 were commands queued in ESXi at the pause, 1 was a fresh write the resumed guest issued 0.83 s of guest time later.
- Guest CLOCK_BOOTTIME did not advance across the host pause, so its 3 s quorum lease still read valid on resume.
- Its corosync merged back into the membership and never reported inquorate, so the helper never told the kernel to reset.
- The node never reset. Its FS shut down only when its disk heartbeat saw its slot taken (P290-AUTH-WITHDRAW reason=SLOT_TAKEOVER).
- Control: vSphere guest suspend (`govc vm.power -suspend`) gave zero late writes. A suspend drains I/O, so it is NOT a valid test of a freeze; a host pause is.

**Apply:** a fence whose proof is "the deadline passed, so the loser ended itself" (watchdog, lease, quorum loss -> emergency_restart, SBD-style) is defeated by a hypervisor-host freeze. Do not claim it safe on a VM without a storage-side barrier (PR preempt) under it; measure with a host pause, never a guest suspend. DRBD is not exposed: a frozen loser's late writes reach only its own excluded replica.

Defect: D-QUORUM-FROZEN-HOST-LATE-WRITES-AFTER-TAKEOVER. Evidence: tests/evidence/vsphere/quorum-11-freeze-host/.

### Spend time on the common case, not the rare corner case
Source: `feedback-spend-time-on-the-common-case-not-the-rare-corner-case`.

Context: a session spent most of its effort on vSphere fencing corner cases (hypervisor host frozen with no PSOD, made on purpose with a Workstation pause of a nested ESXi host; qnetd lost on both nodes; repeat split laps) while the thing the user cared about, multi-writer VMDK sharing and its 5x create slowdown, sat untouched. The user ran VMware for about 10 years, as team lead for all of HP, and "very very rarely saw a completely frozen VMware host."

User: "I feel like you're getting off on a tangent here, spending a lot of energy on a corner case." Then: "we are not going to spend 99% of our time on the less than 1%. We're going to spend 99% of our time on the 99%."

**Why:** effort is finite. A feature that works in the rare case but is slow or broken in the everyday case is worth nothing to users; chasing the 1% hides 99% problems.

**How to apply:**
- Before a test, design or fix, ask how many real deployments hit it. Make common paths correct and fast first: everyday workloads, ordinary crashes and power-offs, performance against native.
- When a rare failure turns up, record it in a few lines (defect record, one sentence in the doc), tell the user, return to main work. No harnesses, measurements or fixes for it unless asked.
- If unsure whether something is a corner case, ask the user in one line; their field experience outranks a lab worst case.
- This decides where time goes; it does not erase a found defect. The record stays in the queue at the severity and bar the user sets.

## D. vSphere shared-attachment rig traps and the VMware version rule (from `compiled-vsphere-shared-attachment-rig-concurrency-harness-edits-and-version-scope`)

Topic: vSphere shared-attachment (multi-writer VMDK, fence=vcenter|manual) rig traps and the version-scope rule for all VMware work. Provenance: ccloop run 8bd0eed0 sessions 6-7, 2026-10-13.

### vSphere laps and DRBD verification share clyde  `trap-vsphere-laps-and-drbd-rig-share-clyde-and-a-harness-edited-under-a-running-loop`
- Nested ESXi guests' datastores are NFS on clyde; the DRBD rig's test1/test2 use clyde's iSCSI pool on the same NVMe (nvme0n1p2).
- With RDM/VMDK laps running, the DRBD `fio_perf` row failed BUDGET_EXHAUSTED (host_disk wms_p95=152.6 ms).
- During `resolve-test` (mxfs loaded on test1 alone for loop-device checks, nothing mounted on DRBD), test1's kernel log went silent 17 s, then test2 shut the DRBD connection and test1's fence handler stonithed test2. Outage and takeover steps never ran. Causality not proven (test2's log died with it), but verification is evidence only on a quiet host.
- Run DRBD release verification with vSphere guests idle, and the reverse.

### Never edit a harness a background loop is executing  `trap-vsphere-laps-and-drbd-rig-share-clyde-and-a-harness-edited-under-a-running-loop`
- The loop calls `tests/vsphere_shared_fence.sh <step>` once per step; bash reads the rest of a script by byte offset after the current command. An Edit inserting bytes before the tail (the `case` dispatch) shifts the offset; a running step can resume mid-line in the dispatch, e.g. at `cmd_baseline`, which reformats the shared disk.
- If edited by mistake, restore the exact previous bytes at once. Edit only between runs.

### rsync rc 23 chained into cd  `trap-vsphere-laps-and-drbd-rig-share-clyde-and-a-harness-edited-under-a-running-loop`
- rsync of the tree returns 23 on root-owned files (`.xfs_fio_baseline.*.json`, `bench.json`). `rsync ... && cd $S && make` then runs `make` in the CURRENT directory (the shared tree). Never chain on rsync's rc into a cd; use `cd $S || exit`.

### runtime.bootTime is not "power-on only"  `trap-vsphere-boottime-changes-on-guest-reboot-and-a-dead-swap-holder-needs-a-forced-hold-to-test`
- Docs and a forum thread said vCenter VirtualMachine `runtime.bootTime` changes only on powered-off -> powered-on. Measured on ESXi 8.0.2 / vCenter (vstest2): guest `systemctl reboot` CHANGED it (15:31:40 -> 15:36:20); `govc vm.power -off` cleared it (None); power-on set it again. vMotion never measured.
- Never use bootTime as proof a boot ended or continued without measuring the exact operation. The shared attachment instead re-tags the VM from inside each new boot (`mxfs_fence_vcenter.py boot`, `mxfs-vcenter-tag.service`), same mechanism as the mount-time arm.

### Testing "a peer died holding the emulated swap lock"  `trap-vsphere-boottime-changes-on-guest-reboot-and-a-dead-swap-holder-needs-a-forced-hold-to-test`
- Random panics hit this window only sometimes (1 of 2 vcenter panic laps, 0 of 5 manual). Deterministic: `HOLD_MS=30000 tests/vsphere_shared_fence.sh kill panic <survivor> <victim>` arms `dbg_drbd_cas_hold_ms` on the victim (next swap sleeps inside the critical section), waits 3 s, panics it.
- PROVE the hold took effect: with per-sector claims a disjoint hold leaves NO trace on the survivor (partial=0 contended=0 in P-DRBD-CAS-STATS fits both "hold disjoint" and "hold never fired"). The harness reads the victim's lock register off the shared disk from the survivor (area_lba from P-SHARED-CAS-ATTACH, sector area+1+victim_index) and decodes raised/want/nranges/ranges (`VICTIM_REG raised=1 nranges=1 ranges=628728+8`). Without that read a green lap is vacuous.
- Why it mattered: before per-sector claims such a death made every survivor swap fail at the 10 s bound; under fence=manual the survivor's heartbeat stopped, its authority lease expired at 62 s and it withdrew before the death was declared (D-SHARED-MANUAL-SWAP-HOLDER-DEATH-WITHDRAWS-SURVIVOR).

### Don't relax the authority lease to fix such a stall  `trap-vsphere-boottime-changes-on-guest-reboot-and-a-dead-swap-holder-needs-a-forced-hold-to-test`
- Tempting because a shared-attachment peer needs a death certificate (VM off / operator) to recover a slice. But the lease also prevents split brain when a frozen peer resumes and finds the survivor's heartbeat stale (both think the other dead and master locks). A lock-free own-heartbeat write is unsafe: peers write a node's heartbeat slot on AGING (settle/withdrawn/guard), not only after a certificate (hb_cas_own_slot comment, 0.60.0). The fix had to be in the lock: per-sector claims (`tests/drbd_cas_lock_model.py --ranges`).

### All VMware work is one version  `feedback-all-vmware-work-is-one-version-0-90-128`
- User, 2026-10-13, after 0.90.128 -> 0.90.129 was bumped to start the manual and vCenter fence methods for multi-writer VMDKs: "NO go back to .128 ... stop revving every 10 seconds ... just do ALL vmware work as .128".
- The open version names the whole platform effort ("VMware: MeshXFS on vSphere, its shared disks and how to fence on them"). A new mechanism that exists to make that platform work (fence method, helper, harness) is part of the same work, even when it touches core code like recovery. Judge "different work" by the user's unit (platform or campaign), not by which subsystem the change lands in.
