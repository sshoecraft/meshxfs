---
name: compiled-vsphere-esxi-pr-reset-freeze-traps-and-platform-build-helpers
description: Lab traps: vSphere pRDM PR key+reset, freeze detect, glibc helpers, harness grading, dnsmasq.d, PVE bio BUG, rpm preun, igrab UAF, capped captures
metadata:
  type: feedback
tags: [compiled, vsphere, esxi, prdm, pr-key, wsfc, multi-writer, freeze, glibc, platform-build, harness, measurement-integrity, rig, recovery-blocked, dnsmasq, iscsi, scst, lun-pool, withdrawn, pve, kernel-version, packaging, evidence, drbd]
---

Lab, rig and release-path traps where a result looked like a defect, a proof or a finished release and was not. Four bodies of lessons folded into one article: (A) the vSphere/ESXi lab, (B) harness grading and rig restoration, (C) rig/lab configuration with two withdrawn findings, (D) Proxmox/DRBD/packaging drift, object-lifetime and evidence/measurement traps. Thread: a PASS, a FAIL or a clean rig gate proves nothing until the harness is shown to have measured the property, on the real target.

## A. vSphere/ESXi lab

Running MeshXFS on the vSphere lab (ESXi 8.0.2, nested under Workstation on clyde; AlmaLinux 9.8 guests vstest1/vstest2, glibc 2.34): what ESXi does to SCSI persistent reservations and resets, how to freeze-diagnose a guest, what not to assert about VMware from memory, and the platform-build trap that made a CAW test grade PASS wrongly.

### pRDM power-off and reset behaviour  `trap-esxi-prdm-poweroff-drops-pr-key-and-guest-reset-success-is-esxi-not-array`

Measured on ESXi 8.0.2, physical-mode RDM of an SCST LUN on a physical-bus-sharing pvscsi controller, one VM per ESXi host (session fe2609ab).

- **Power-off removes the VM's registration.** `govc vm.power -off -force` on vstest2: PR generation 0x3a -> 0x3c within 3 s, vstest2's key gone, not restored at power-on (`tools/vsphere_poweroff_key_probe.sh`, `tests/evidence/vsphere/probe-rdm-poweroff-key.txt`). MeshXFS's death fence then sees KEY_ABSENT_UNPROVEN and refuses the slice, by design. `crash_audit` on an RDM board therefore FAILs (no "foreign replay of" verdict) - the designed refusal, not a harness gap. Queue: D-VSPHERE-RDM-POWEROFF-UNREGISTERS-KEY-RECOVERY-REFUSED.
- **A guest's reset is not an array witness.** `sg_reset -d`/`-b` from the guest does reach SCST as `TM fn LUN_RESET` from the ESXi initiator (`-H` sends nothing), but with clyde dropping that ESXi host's 3260 traffic the guest's `sg_reset -d` still returned rc=0 in 5 ms with no TMF at the target (`tools/vsphere_reset_witness_probe.sh`). Do not propose "accept the pvscsi reset as the LU-reset witness".
- SCST logs every TM fn at default trace level in clyde's dmesg (`scst_rx_mgmt_fn ... TM fn LUN_RESET`), so a forwarded TMF can be checked without turning a trace flag on.
- Clustered VMDK: vCenter refuses it (NotSupported) on iSCSI VMFS and on a Workstation-shared disk (transport `parallel`, ATS unsupported). VMware supports it on FC, and on NVMe/TCP only from 8.0 U3; Linux nvmet has no fused commands, so it cannot be the NVMe backing either.
- In-guest iSCSI (`direct`) avoids all of this: the key belongs to the guest's own nexus and survives the power-off, so PREEMPT AND ABORT names it.

### Search before asserting VMware behaviour  `feedback-web-search-vmware-behaviour-before-asserting-it-multi-writer-wsfc`

User, 2026-10-13, after I said from memory that "Microsoft clusters don't use multi-writer": "That's fully incorrect. I have seen lots of Microsoft clusters. In fact, I built one that I built file clusters using a multi-writer disk." Then: "do a web search before assuming."

- Multi-writer VMDKs on a physical-bus-sharing controller were a common WSFC/MSCS shared-disk setup before ESXi 7.0. Broadcom KB 395751: the flag is "no longer supported on MSCS VMs using shared disks starting with ESXi 7.0".
- Since 7.0 the route is the clustered VMDK. ESXi emulates SCSI-3 PR-IN/PR-OUT per VM at the vSCSI layer. Needs a physical-bus-sharing controller, VMFS6 with the datastore's Clustered VMDK capability, eager-zeroed thick disks, an array with ATS and WEAR, and one node per host. KB 313472 (8.x) lists FC and NVMe-oF, not iSCSI.
- Measured on 8.0.2: a multi-writer VMDK answers no PERSISTENT RESERVE (invalid opcode) and no COMPARE AND WRITE, whether its controller has physical bus sharing or none. vCenter refuses `EnableClusteredVmdkSupport` (NotSupported) on the lab's iSCSI-backed VMFS6 datastore.
- A physical-mode RDM with one VM per ESXi host forwards PR per guest, plus COMPARE AND WRITE and FUA. With two VMs on one host they share one I_T nexus.
- Apply: before telling the user how a VMware or other vendor feature behaves, search or measure it; they have deep hands-on VMware experience and an assertion from memory that contradicts it costs credibility. When a probe gives one answer, state exactly which configuration it covered (controller bus sharing, host placement, ESXi version); never generalize to "X doesn't do Y".
- Related: `scripts/vsphere_shared_disks.sh`, `tools/vsphere_clustered_vmdk.py`, `docs/attachment-methods.md` ("pass on VMware").

### Guest freeze: detect from outside, read clocks from a memory image  `technique-vsphere-guest-freeze-detect-from-vmware-log-and-read-guest-clocks-from-memory-image`

Learned on vstest2 (AlmaLinux 9.8, nested ESXi under Workstation on clyde), 2026-10-13.

- **Detect from OUTSIDE the guest.** When a guest stops making progress, VMware Tools' heartbeat to the VMX stops; the VM's `vmware.log` (datastore `vms`, `<vm>/vmware.log`) prints `Tools: Tools heartbeat timeout.` ~20 s in and `Tools: Running status rpc handler: 0 => 1.` on recovery. Trustworthy exactly when the guest's own logs are not (a frozen guest logs nothing). `grep -E 'Tools heartbeat timeout|Running status rpc handler: 0 => 1'` lists every freeze with duration. vstest2 had 14 in 3.5 h, each 4 min 32 s; vstest1 none. A MeshXFS fence on vSphere coinciding with one is the guest freezing, not MXFS losing beats.
- **Reading the cause.** `tools/vsphere_freeze_catch.sh <vm> <max_s>` takes a memory snapshot on the first new timeout line; `sudo vmss2core <vmsn> <vmem>` (NO -N6: that writes a physical-memory core gdb cannot read kernel VAs from) gives per-vCPU linear cores; `tools/vmss_cpu_state.py` prints per-CPU call_single_queue, ksoftirqd, timer base, hrtimer/tick state and the timekeeper. Debuginfo for the exact EL9 kernel: vault.almalinux.org/9.8/BaseOS/debug/x86_64/Packages/; clyde has no rpm2cpio - extract on an EL guest over /src (clyde's /src is the guests' /src). First freeze image: queues empty, but every CPU's last_tick and the timekeeper's xtime stopped at the same instant ~30 s before the snapshot - the guest's clock stopped, the vCPUs were not withheld (vCenter cpu.ready ~150 ms/20 s, costop 0: `tools/vsphere_vm_cpu_samples.sh`).
- **Commands in a guest whose network is dead:** `tools/vsphere_guest_run.sh <vm> '<cmd>'` (VMware Tools channel). TRAP: `govc guest.run` hands the program line to the guest's shell and appends its output redirect at the END, so `bash -c "a; b; c"` passed as words returns only `c`'s output; the tool ships the command base64 and decodes it into one `bash -c` argument. Also a sourced `scripts/vsphere_env.sh` reads the CALLER's $1 as its entry name - pass `lab` explicitly.
- **Do not trust the "fault follows esxhost2" memory as current:** on 2026-10-13 the freezing guest was the one on esxhost1, whose .vmx (user-tuned) carries `monitor_control.virtual_rdtsc = "FALSE"` and `monitor_control.halt_aware = "TRUE"` that esxhost2's lacks.

### Platform rebuild leaves stale single-file helpers  `trap-platform-rebuild-leaves-single-file-helpers-linked-on-clyde`

On the vSphere AlmaLinux 9 guests (glibc 2.34), `dlm_lock_correctness` read `caw=fail` and still graded PASS ("partial: one primitive supported"). COMPARE AND WRITE worked fine on the in-guest iSCSI path to SCST (`sg_inq -p 0xb0` showed max compare-and-write 255 blocks). The probe never ran: `tools/caw_verify` is a single-file program NOT in `tools/Makefile`'s TOOLS, so `make clean` does not delete it; the copy linked on clyde (glibc 2.38) survived `scripts/platform_build.sh` and exited with "version `GLIBC_2.38' not found". The test sent stderr to /dev/null, so the loader failure read as the array refusing the command.

- Same class then: `caw_slotdump`, `recov_forge`, `tests/caw/caw_align_probe`, `tests/fence_inflight/prprobe`. platform_build.sh now builds those, plus `mxfs_mmapio` (`-I include`: caw_slotdump includes `<mxfs/mxfs_super.h>`).
- After any platform switch, sweep the tree: `objdump -T <f> | grep -o 'GLIBC_[0-9.]*' | sort -V | tail -1` over every ELF under tools/, tests/ (excluding tests/evidence), scripts/ and bench/, compared against the node's glibc.
- A new single-file C helper the harness runs must be added to platform_build.sh's helper loop, else the next platform runs a stale binary.
- A grader must tell "tool would not start" (rc 127, or a loader message) apart from "primitive refused", and never grade a failed primitive as PASS on a configuration that needs it.
- Provenance: ccloop run 8bd0eed0, session 3, 2026-10-13.

## B. Harness traps: survivor-liveness grading, rig restoration, standalone environment

Source: `compiled-harness-liveness-grading-rig-restoration-and-standalone-env-traps`. Three harness traps that make a run FAIL or burn its budget without the product being at fault. Each produced a verdict that looked like a defect and was not.

### Survivor liveness: touch a domain the survivor owns, grade the return, not the success  `trap-grading-a-survivors-liveness-with-an-operation-in-the-dead-nodes-domain-measures-the-designed-fail-fast`

s83, fencing-refusal verification. A check "does the prover still serve after refusing?" did `mkdir -p /mnt/shared/<new>` plus a write and FAILed rc=1. The log line was `P240-QUAR-NSOP-REFUSE op=lookup ino=128 comm=mkdir rc=-5`: the inode belonged to a node whose recovery was BLOCKED, and refusing fast before any transaction is the designed behaviour (the alternative is waiting out an acquire budget).

- "Can the survivor do work?" is asked in a domain the survivor took BEFORE the cut: create the directory and fsync a file into it while healthy, write into it afterwards. With the dead node's domain blocked this returned rc=0 in under a second.
- "Did anything hang?" is the graded question, and it is graded on the operation RETURNING: `timeout N` kill (rc 124) is a hang, any other rc is not. Whether it succeeded is a FINDING to print, since availability cost depends on which domain the caller touched.
- Grading success instead of return converts a designed fail-fast into a failure, and the reflex "loosen the assertion" is how a real hang later passes the same check.

### A harness that takes the rig down restores it on every exit  `trap-a-lap-that-exits-early-after-destroying-the-victim-bills-the-next-lap-for-a-powered-off-node`

s82, `fence_gate_basis.sh`. A non-vacuity check between `virsh destroy` and the restart exited VACUOUS, so test2 stayed off. The next lap spent 48 polls x 5 s = 240 s in `waitboot` on a powered-off node, then `prep_cluster` had to power-cycle it and the lap hit the caller's 580 s timeout at the files stage with a 0-byte `B_files.txt`. A budget failure with no product in it, manufactured by the previous lap's exit path.

- Set a flag at destroy, clear it at restart, `trap` a restorer on EXIT; this covers FAIL, VACUOUS, ABORT and the caller's timeout.
- Ask the hypervisor first: `virsh domstate` answers in milliseconds; if not `running`, start it and say so. Minutes of ssh polling is a budget leak, not a liveness check.
- Generalises: the exit paths that skip restoration are the failing ones, the laps whose evidence is needed next.

### Standalone runs on the QNAP rig need MXFS_DEV exported  `trap-domain-admission-matrix-defaults-to-mpatha-run-standalone-on-qnap-rig-needs-mxfs-dev-exported`

sess517. `tests/domain_admission_matrix.sh` run by hand defaults `DEV=${MXFS_DEV:-/dev/mapper/mpatha}`; the chain script exports the QNAP by-path, a standalone call does not. Result: 9 FAILs, every row `MOUNT_RC=32 WALL=0 NOT_MOUNTED`, `REJOIN_RC=32`, no kernel refusal lines; about 8 minutes of laps wasted. test2 tried to mount mpatha while test1 was up on the QNAP LUN.

- Signature: ALL rows fail including the refusal rows (a real admission bug fails one or two), walls of 0 s, no kernel refusal lines. Not a product fault.
- Fix: the matrix header now prints `dev=`. Any `tests/*.sh` run by hand against the QNAP cluster needs `export MXFS_DEV=/dev/disk/by-path/ip-192.168.1.4:3260-iscsi-iqn.2004-04.com.qnap:ts-453pro:iscsi.target-0.f35772-lun-0 MXFS_NODE_LIST=test1,test2` (same trap as the bare `run.sh` prep, sess513).

### Common thread of B

A FAIL is not a defect until the harness is shown to have measured the property: wrong domain, wrong device, or a rig left in a state by an earlier lap each produce a convincing failure. Check the harness's own preconditions (domain ownership, `dev=`, `domstate`) before reading the product.

## C. Rig/lab configuration traps and withdrawn findings

Source: `compiled-rig-lab-config-traps-and-withdrawn-findings`. Three rig/lab notes: one live trap (dnsmasq config) and two notes retired on 2026-10-01 whose only surviving content is a caution about how the finding was reached.

### Live trap: dnsmasq loads every file in /etc/dnsmasq.d  `trap-a-backup-file-inside-etc-dnsmasq-d-is-loaded-as-config-and-dnsmasq-refuses-to-start`

Version 0.90.39.

- `cp /etc/dnsmasq.d/lab.conf /etc/dnsmasq.d/lab.conf.backup`, edit, `dnsmasq --test` OK, `systemctl restart dnsmasq` FAILED: "illegal repeated keyword at line 3 of /etc/dnsmasq.d/lab.conf.backup". conf-dir reads every file in the directory, so the backup is a second copy of the config.
- The lab DHCP/DNS was down for 7 s until the backup moved to `/etc/dnsmasq.lab.conf.backup`. `dnsmasq --test` passed beforehand; it does not reliably catch this.
- Rule: back up dnsmasq config OUTSIDE `/etc/dnsmasq.d`.
- Why the edit was needed: platform nodes debian13-1/2 and alma9-1/2 had no dhcp-host reservation. debian13-1's lease moved .153 to .152 while the lab file still said .153, so every ssh by address failed; `tools/lun_pool.sh` read no initiator name and debian13's platform round reported "no pool LUN for its verification set" twice. All four nodes are now reserved in `/etc/dnsmasq.d/lab.conf` at the addresses the lab file uses. A missing reservation shows up downstream as a LUN-pool failure, not a network one.

### Withdrawn: "16 MB iSCSI TCP window costs a third of seqW"  `trap-the-16mb-iscsi-tcp-window-tuning-costs-a-third-of-write-throughput-on-the-scst-pool-luns`

Withdrawn 2026-10-01.

- Claimed `scripts/tune_iscsi_tcp.sh`'s 16 MB window on test1-16 cut 4-node net/mesh/direct seqW to 1150-1864 MiB/s versus about 2000 at kernel defaults, on a "quiet host".
- Wrong: every sample ran while clyde carried the user's own workloads and other rig clusters on the same NVMe. An untuned g4 run an hour later read 1018 MiB/s, inside the "tuned" range.
- The tuning's effect on throughput is unmeasured. test1-16 were reset to kernel defaults (socket caps 212992, window 524288) so the rig is uniform with test17-28; that uniformity is a separate reason to leave them there.
- Replacement lesson: trap-a-throughput-yardstick-from-an-idle-host-grades-boards-that-ran-beside-other-clusters-and-the-users-load. A throughput comparison is invalid unless host load is controlled and recorded, and "quiet host" must be verified, not asserted.

### Superseded: whole-rig run after rig_groups setup finds no shared LUN  `trap-a-whole-rig-run-after-rig-groups-setup-finds-no-shared-lun-run-rig-sh-first`

Superseded 2026-10-01.

- `scripts/rig_groups.sh` and the `:shared` target no longer exist. `run.sh` and `tests/board_4node_chain.sh` borrow pool LUNs via `tools/lun_pool.sh`, so no rewiring step is needed before a whole-rig run. See reference-test-luns-come-from-the-pool-tools-lun-pool-sh.
- Still true: binding a node to one target logs it out of every other, so whatever bound it last decides what it sees. The pool's alloc rebinding is now the only thing that does this.

## D. Proxmox target, kernel and packaging drift; lifetime; evidence and measurement

Source: `compiled-pve-kernel-drift-packaging-config-edit-and-measurement-evidence-traps`. Twelve notes the clusterer could not fit to one topic; two themes. (1) Proxmox/DRBD/packaging environment traps, where something works on the rig or the first target and fails on the real one. (2) Evidence and measurement traps, where a capture, counter, or claim looks like proof but is not. A lifetime/refactor-mechanics pair sits between them.

### Proxmox is the target; kernel and packaging drift

- Proxmox VE is the product's reason to exist. A release that does not build, install and mount on the current PVE kernel is not a release, and a "known issue" release-note line is not acceptable: fix it and ship a new version. The rig (test1..test32, clyde) runs Ubuntu 6.8, so a clean rig gate proves nothing about PVE. Check the PVE headers for every kernel symbol a new path uses, and verify on the pve9 VMs before publishing. `feedback-proxmox-is-the-product-target-a-release-that-does-not-build-on-pve-is-not-a-release`
- Linux 7.0 `bio_chain_endio()` is `BUG()`. A bio completion hook that restores `bi_end_io` and calls it directly panics when the bio is a `bio_chain()` piece. This is what `pal/linux/drbd.c` `mxfs_ioq_end_io` did (chained 1 MiB pieces from `mxfs_pal_ioq_admit`). It worked on 6.17.2-1-pve and panicked on 7.0.14-19-pve. Rule: restore the fields and call `bio_endio(bio)`. Test `pal/linux` changes on the 7.0 nested pair as well as the physical 6.17 pair. `trap-a-bio-hook-that-calls-the-restored-bi-end-io-directly-panics-on-linux-7-0-for-a-chained-piece`
- `drbdadm adjust` changes `ping-int` in the config (and `drbdsetup show`), but the live meta socket's receive timeout is only set at connect and after a PingAck. A busy link keeps the old value. A detection-time measurement taken right after an adjust measures the old setting: reconnect first. Detection under traffic can take up to 2 x ping-int + ping-timeout. `trap-drbdadm-adjust-changes-ping-int-in-the-config-but-not-on-the-live-connection`
- RPM reinstall/upgrade runs the new %post before the old %preun. An unconditional `dkms remove` in %preun deleted the just-built module. Gate undo scriptlets on `"$1" = 0` and clean other versions in %post. dpkg orders the other way, so never infer RPM behaviour from the .deb. A harness re-testing a same-version rebuilt candidate must force `--reinstall` and drop the DKMS registration, or it tests the earlier build. `trap-rpm-reinstall-runs-the-old-preun-after-the-new-post`
- A DOTALL `re.sub` meant to drop one section of `/etc/pve/storage.cfg` deleted every section after it (including `nfs: iso`). Drop `(?s)` for line-structured config (or parse sections), diff against the backup before writing a cluster-wide file, and keep the copy-first step. `trap-a-dotall-regex-deleting-one-pve-storage-block-deleted-every-block-after-it`

### Lifetime and refactor mechanics

- `xfs_iget_cache_miss`'s `out_destroy` frees an uninserted inode ignoring `i_count`, so an `igrab` held by async work does not keep it alive. Embedded BAST works are reaped with `cancel_work_sync`; a separately allocated item such as `mxfs_incarn_poison` runs on freed memory (`BUG_ON(I_CLEAR)` at `iput+0x1c5`, node panic). Before queuing work that holds an inode ref, check the inode is radix-current under `mxfs_ici_lock`. Fixed in 0.89.75. `trap-an-igrab-held-by-async-work-does-not-keep-an-uninserted-iget-miss-inode-alive`
- To split a giant C function, use `scripts/extract_block.py` (libclang 18.1.8 in a venv, kernel flags from the object's .cmd). Traps found building it: libclang offsets are bytes (read/write latin-1); macro-argument tokens report expansion location (use spelling location); a macro using its argument twice yields duplicate DeclRefExprs (dedupe); the first arm of `rc ? WARN : INFO` is not always the success arm. After any tool change, `tests/extract_block_selftest.sh` must print RESULT PASS. `technique-split-a-giant-c-function-with-extract-block-and-its-selftest`

### Evidence and measurement traps

- A capture feeding a verdict must save the verdict-bearing lines uncapped and cap only the chatter, in a separate grep. `dmesg | grep ... | head -80` kept 80 SHELL-ADOPTED lines and none of the 12 CORRUPT lines, so the `reason=` field was lost. A count is not the evidence; the line with its fields is. `trap-a-capped-dmesg-capture-drops-the-verdict-lines-behind-the-chatter-and-the-reason-field-is-lost`
- A lap that exercises a new refusal proves a deleted branch is gone only if it records the predicates the deleted branch would have read (ledger state, boot/nexus predicate). Otherwise the old build may have refused too. One lap reaches one antecedent; inspection covers the rest. Assert absence of authority, not absence of the retired class; a post-hoc disk read cannot exclude minted-used-overwritten, so instrument the minting/publication sites. `trap-a-lap-that-exercises-the-new-refusal-proves-nothing-unless-it-captures-the-predicates-the-deleted-branch-would-have-read`
- A record's "refuses with no fallback" claim is a control-flow claim. Check the refusing function's call-site count and whether its refusal path writes the verdict later branches test; a refusal that only logs is a fall-through. The next-step field of a record over-reports what is closed, so re-derive reachability claims from the tree. `technique-before-believing-a-record-that-says-a-leg-refuses-with-no-fallback-check-whether-the-refusal-mutates-the-verdict`
- A per-second poller whose command blocks through an outage (iSCSI holds the in-flight command through session recovery) reports one unanswered second for a 16 s outage. Measure an outage as the largest gap between consecutive poll timestamps, never as a count of errored polls. A reconnect bound is `replacement_timeout` (120 s). `trap-a-per-second-poller-whose-command-blocks-through-an-outage-reports-one-unanswered-second-for-the-whole-outage`
- A budgeted probe's Nth printed line is not the Nth event (`dropped <= 8 || dropped % 64 == 0`), so taking the 9th DROP line scored latency -8 s on a correct build. Score the detector's own fields (`unanswered_ms=`, `bound_ms=`) instead. `trap-the-nth-printed-line-of-a-budgeted-probe-is-not-the-nth-event`
