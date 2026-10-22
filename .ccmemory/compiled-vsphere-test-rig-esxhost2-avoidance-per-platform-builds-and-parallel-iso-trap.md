---
name: compiled-vsphere-test-rig-esxhost2-avoidance-per-platform-builds-and-parallel-iso-trap
description: vSphere rig (esxhost2 lockups, per-platform builds, ISO race) + tauth ledger authority/retention/takeover, lap design, harness capture traps
metadata:
  type: feedback
tags: [compiled, vsphere, esxi, esxhost2, soft-lockup, build, platform, mkosimage, iso, tauth, ledger, takeover, recovery, dlm, retention, mastership, measurement, harness, measurement-integrity, scsi-pr, rig, qnap]
---

# Test-rig and harness lessons: vSphere guest bring-up; tauth ledger authority, retention and takeover; harness capture traps

Merge of two first-tier articles that share only the test-rig/harness theme, not one subject. Part 1: standing up vSphere test guests on a non-rig platform (three lessons from the 2026-10-12 vSphere vstest1/vstest2 AlmaLinux 9 bring-up). Part 2: tauth ledger page authority, takeover and retention, and how to measure them without a vacuous lap, folded from `compiled-tauth-ledger-page-authority-retention-and-takeover`. Eighteen raw notes in all: three in Part 1, fifteen in Part 2 (twelve in the tauth sections, three, via an absorbed compiled article cited where it starts, in the harness capture-traps section).

## Part 1: vSphere test guests (vstest1/vstest2, AlmaLinux 9)

Assorted group (loose): three lessons from the 2026-10-12 vSphere vstest1/vstest2 (AlmaLinux 9) bring-up. Common thread: standing up test guests on a non-rig platform.

### Keep vSphere test guests off esxhost2
Source: `user-esxhost2-has-always-had-soft-lockup-problems-keep-it-off`

User, 2026-10-12: "There was always a problem with ESX2 and the soft lockups. I used to just keep it off." Said after a day of chasing vstest2 soft lockups that a session had first blamed on two guests sharing one host, then on missing CPU affinity.

Measured on esxhost2-hosted guests:
- Soft lockups with two CPUs spinning in smp_call_function_many_cond (IPI from netstamp_clear / drain_vmap_area_work) waiting on a third CPU that sat idle in default_idle and never woke (swapper/N idle-CPU soft lockups): a halted vCPU not being woken, a hypervisor/nesting fault.
- An 87 s guest clock jump with all vCPUs in timer catch-up.
- Persisted after esxhost2 was pinned to its own socket (processorN.use) and the guest ran alone on it. The guest on esxhost1 in the same setup had zero. No mxfs on any stack.
- esxhost2's .vmx differs from esxhost1's only in VNC enabled, firmware=bios, numa.vcpu.maxPerMachineNode=8 (vs 32), and disconnected serial/parallel/sound devices; none confirmed as the cause.

Confirmed by a swap: vstest1 (0 lockups on esxhost1) live-migrated to esxhost2 became unreachable within minutes; its persistent journal (`journalctl -b -1 -k`) held 73 soft lockups, idle CPU3 "stuck for 2631s", the same smp_call_function_many_cond waits, and a last entry stamped five days in the future. vstest2 moved to esxhost1 stopped locking up. The fault follows esxhost2, not the guest. esxhost2 was then put in maintenance and powered off; both guests run on esxhost1.

Apply: put vSphere test guests on esxhost1; if a two-host test is needed, expect esxhost2's guests to soft-lock and check their dmesg before trusting any result from them. Ask before investing more in esxhost2.

### Build driver and tools on the first node of each platform
Source: `feedback-build-driver-and-tools-on-the-first-node-of-each-platform`

User correction (2026-10-12, vSphere vstest1/vstest2 on AlmaLinux 9): "for every platform you were testing on you would build the driver and tools on the 1st node." The procedure had been lost (not in any memory/doc; possibly in an uncommitted-deleted feedback_make_clean.md), and the session instead concluded run.sh "cannot" run on the nodes because /src/mxfs/tools/mkfs_mxfs (built on clyde, glibc 2.39) refuses to start on EL9 (glibc 2.34). The user was alarmed that the procedure was gone.

Procedure, before any run.sh test on a platform that is not the rig's own OS:
1. Check the marker in `tools/` that says what platform the tree's binaries were compiled for.
2. If different: clean the module and the tools (`make clean` deletes both; `make modules` alone does not rebuild tools).
3. On the FIRST node of the new platform, over the shared /src: build the driver (`mxfs.ko`) and the tools from /src/mxfs.
4. Write the marker naming the platform (OS id/version, kernel, node) it was built on.
5. Going back to the rig (clyde/Ubuntu test1..N): clean and rebuild on clyde, re-mark.

Why: nodes execute mkfs_mxfs, chk_mxfs, caw_verify, fua_verify, fsx etc. from /src/mxfs over NFS, and prep_node.sh loads the repo mxfs.ko when its vermagic matches the node's kernel. Binaries linked on another distro's glibc fail with "version `GLIBC_2.38' not found". Never answer a glibc/ABI mismatch with "we can't test on these nodes"; rebuild on the first node.

### Parallel mkosimage builds of an uncached ISO boot a half-downloaded ISO
Source: `trap-parallel-mkosimage-builds-boot-a-half-downloaded-iso`

Observed 2026-10-12 building vstest1/vstest2 (alma-9-latest on vsphere/lab) in parallel. User saw "vstest1 didnt start and 2 is stuck at grub prompt".
- osimager/packer download straight into `<iso_path>/<name>.iso` (`/iso` = `/data/media/cdimages/os`). The `.iso.lock` beside it is NOT honoured by a second build: the second packer logged "Skipping download, ... already exists in the local cache" while the first was 1.2 GB into a 13.3 GB download.
- On vSphere the `iso` datastore is the same directory and `[iso] packer_cache` is a self-symlink (`packer_cache -> .`), so it also logged "Skipping upload ... already exists in remote cache" and booted the truncated ISO -> GRUB prompt, then hung at "Waiting for IP".
- Rule: when the ISO is not already complete in /iso, build ONE node first (or download the ISO alone), and start the others only after its size is final. Check `ls -la /iso/<name>.iso` against the expected size before a parallel build.
- Recovery: `govc vm.power -off -force <vm>; govc vm.destroy <vm>` fails that packer build out; the downloading build is unaffected.

## Part 2: tauth ledger, page authority, takeover, retention, and how to measure them

Folded from `compiled-tauth-ledger-page-authority-retention-and-takeover`. Central topic: who owns a tauth ledger page, when a dead incarnation's records may be destroyed, and how to measure those paths without a vacuous lap. Chronology is by version where it matters. A second, looser group is folded in at the end of this part: harness captures that observed nothing or the wrong thing (sg_persist filter, wrong-rig device defaults, one transient QNAP mkfs failure); it is not tauth-specific and shares only the "a verdict needs a capture that could have failed" theme with the lap-measurement section.

### Model facts (read from code)

- Page authority is `hdr.auth_node` + `hdr.authority_epoch`, and every transition must name that exact pair (`lpage_mine_locked`, `mxfs_tauth_ledger_prepare`, `tauth_purge_scan_page`). No transition reads a heartbeat slot, so an adopted slot cannot carry a dead victim's authority. Ask what KEYS authority, not where a slot index appears: a survey of slot-indexed fields never terminates. Slot-keyed `holders`/`open_holders` bits fail closed (-EBUSY, never a double grant) and self-heal on the adopter; still check the adopter opens with its own epoch. `technique-establish-a-slot-adoption-cannot-resurrect-an-authority-by-reading-what-keys-the-authority-not-what-indexes-the-state`
- `MXFS_TAUTH_PG_UNOWNED` is set only by mkfs. A page, once touched, stays owned forever and only moves between nodes. Any "pages in use" summary keyed on authority saturates as the filesystem ages; the orphan sweep and node-death takeover select by authority. A fresh-format measurement (live_pages=1) understates an aged one. Measure owned pages after real workloads before designing a summary. `trap-ledger-page-authority-never-returns-to-unowned-so-an-authority-bitmap-saturates`
- Mastership is `active_nodes[page % N]` over the sorted active view (`dlm_page_master_locked`), distinct from authority. A request is answered by the master; a remote requester's lock moves nothing. A dead member stays in the view until its recovery completes, and a clean departure shrinks N and re-maps every page, possibly onto the dead member. `trap-a-ledger-pages-authority-is-its-master-so-a-quiesce-on-another-node-moves-nothing-and-a-departure-re-aligns-every-page`

### Retention: dead is not reclaimable

- 0.89.3 (D-0981): the orphan sweep's dead test (off the slot map, not in view) matched a fenced victim whose slice replay was still pending; the sweep retired its records, replay found the manifest entry gone (`P-RMAN-POSTSEAL-MUTATION`), aborted -117 and published a terminal FSWIDE quarantine. Protection interval is "recovery pending and stage < IMAGES_REPLAYED". Enforce at the destructive choke point (`dlm_takeover_page`, -EAGAIN), pre-filter in the sweep for diagnostics; sweep-only protection leaves on-demand takeover open. Never weaken the verdict for a local mutator. Precondition-shaped defects hide behind harness prep (earlier laps always reformatted). `trap-a-dead-authority-is-not-a-reclaimable-one-while-its-slice-replay-still-judges-its-records-against-the-sealed-manifest`
- 0.89.4 (d0356): the 0.89.3 guard read only this node's recovery-pending marker. A prover had written a durable FENCING intent, relinquished and left; the cold-returning victim's mount-time sweep (before any death declaration) saw no marker, took pages over, and a later replay quarantined the AGs. Retention predicates must be authoritative from the DURABLE descriptor, never a per-node volatile marker; unknown protects; a matching ACTIVE record contradicts "dead". Retention is a different question from liveness, so keep it in the reclamation predicate, not the occupancy map. A descriptor nobody advances protecting records forever is correct fail-closed; availability comes from adopting the stranded attempt, never a timeout. Harness assertions must follow the current relinquish-on-departure shape. `trap-a-retention-predicate-built-from-this-nodes-own-death-marker-is-blind-to-a-victim-whose-intent-a-departed-prover-left-standing`
- 0.90.63 to 0.90.64: a hold on victim K's records covered the sweep and takeover but not `dlm_ledger_import_page`, whose "residue of our own slot" rules (EX record under another node id; unaccounted shared bit) are keyed by SLOT, so a node-keyed guard cannot reach them (`slot_retained_cb` added). When adding or debugging a hold, enumerate every retire path: orphan sweep and `dlm_takeover_page`, import own-slot EX and shared residue, `dlm_import_settle`, `mxfs_dlm_ledger_purge_owner`, the completion ladder. Grep the kernel stream for the victim's node id; every retire path logs it. `trap-a-ledger-record-retention-must-be-honoured-by-every-path-that-retires-records-including-the-page-import`
- D-0962 (sess40): `dlm_takeover_page` publishes the page MINE before it retires the departed owner's records, so the grant path can write a record in between. The purge matched `ex_node` only and ate a live incarnation's record, silently. Node ids ARE reused (`boot_resume_node`, `node_id_override`, `takeover_only` flag). Identity is `{node, incarnation}`: match incarnation exactly, spare records of unknown incarnation, and `inc == 0` from a caller means "no incarnation to match", never "ex_inc 0 matches anything". Ledger-layer identity questions are answerable in `tests/tauth/ledger_test.c` (case 17) in seconds, with a non-vacuity assertion. `trap-a-retirement-keyed-on-a-node-id-alone-eats-a-live-tenure-once-the-page-is-servable-before-the-purge`
- 0.90.91 to 0.90.92: `dlm_store_fenced_cb` accepted only `dlm_owner_purged` (this mount's purge) while the takeover judged by the broader `dlm_authority_dead` (purged, settled, or previous era). A writer that died between ticket swap and publish left a ticket the store refused (-EBUSY) forever while the takeover kept judging the page takeable: `P960-STALLED-PAGE ... target{dead=1} ondemand_last{rc=-16}`, mkdir EAGAIN after the 30 s stall, surviving reboots on the physical DRBD pair. Any guard on a step inside a takeover must be at least as permissive as the judgement that started it. When a takeover stalls with dead=1 but a refusal deeper in, compare the two predicates first. Tools: `tools/tauth_page_auth.py <dev> --tickets`, `tests/tauth/abandoned_ticket.sh [control]`, `tests/pve_ticket_pages.sh`; the mesh harness needs `vocc_on` before `node_up` or `dlm_authority_dead` never judges a previous era dead. `trap-a-ledger-ticket-guard-narrower-than-the-takeover-dead-judgement-strands-the-page-forever`

### Lap and measurement design

- A page transition (MXFS_DLM_RETRY_TRANSITION) needs the page's MASTER alive, not its authority. Killing the authority parked at SNAPSHOTTING leaves a dead-but-in-view master; the request goes remote and fails fast (-ENOTCONN/-EHOSTDOWN `P-RBLK-DENY-DEAD-MASTER`) instead of waiting, so the stall lap reports VACUOUS. `dlm_page_ensure_mine` -> `dlm_page_acquire` is reached only on the local-master path. Kill the victim with the guard parked below IMAGES_REPLAYED, then return it as a NEW incarnation so the durable authority is a dead incarnation named by a standing RECOVERY_GUARD while a live master can answer. Before killing a node ask which node must answer, not only who owns. `trap-killing-the-page-authority-makes-the-acquire-fail-fast-so-a-stalled-transition-lap-must-keep-that-authority-alive`
- To make a page "belong" to a node, that node must master it: read `master_self=`, re-read roles after any departure, and expect -107/-112 instead of waits otherwise. Departure during a standing guard is exactly the shape that reaches a refused takeover on a live node (`TDR_BLOCK_REALIGN=1`). `trap-a-ledger-pages-authority-is-its-master-so-a-quiesce-on-another-node-moves-nothing-and-a-departure-re-aligns-every-page`
- A defect whose magnitude is workload residue (D-0962: 7984 pages x ~13 ms = 103 s) stops reproducing once the residue is consumed: 27 pages ran 285 ms, both arms PASSed. Check population before the arms; make the harness print `VACUOUS: cand=N < MIN` rather than pass; raise the creates, never lower the threshold. Build residue on the node that will die with the peer mounted (a lone mount writes no ledger pages). Use a same-build runtime control knob (`dl_recovery_takeover_inline`) rather than an older tree, and assert the control arm reproduces the defect. `handoff_ms` is on `P-COMPLETE-RETIRE-TIMING`, not `P-COMPLETE-TIMING`; an empty field must not read as zero. `trap-a-defect-whose-magnitude-is-workload-residue-stops-reproducing-and-the-lap-reads-as-a-pass`
- Decompose a held barrier with its own timing line before arguing about which part to move: `1 + 22443 + 0 + 71148 + 640 = 94.23 s` vs 94.26 s measured showed the takeover owned 71 s, exposed a second serial 22.4 s whole-ledger purge (its own defect record), and predicted the fixed arm. Split harness assertions so each names the defect that owns it; never widen the threshold. Scope log-derived numbers to the identity (`departed=<victim>/`, include the `-INTERRUPTED` variant, not `tail -1`). A pass that returns early (-EINTR, `shutting_down`) prints no summary; find the early-return path's own line before concluding work was skipped. `technique-decompose-a-held-barrier-with-its-own-timing-line-before-arguing-about-which-part-to-move`
- "The probe fired in the failing arm" is not a discriminator until checked in the passing arm. Counting `P-TAUTH-TAKEOVER-UNDER-JUDGEMENT` by `via=` and by distinct page showed the guard armed identically in hanging and non-hanging arms (~250 pages refused by the bulk sweep); the difference was `via=takeover-ondemand` (one parked request re-asking one page every ~100 ms, 843 lines on 1 page vs 0). Count by the caller field and distinct subject; re-derive a record's stated discriminator from existing captures (`P218-RECOV-OWNED` appeared zero times on the hanging laps) before spending rig laps. `technique-discriminate-two-arms-of-one-guard-by-the-probes-via-field-not-by-whether-the-probe-fired`

### Harness capture traps: sg_persist filter, wrong-rig device defaults, transient QNAP mkfs verify FAIL

Absorbed (into the tauth article, now here) from `compiled-sg-persist-capture-traps-wrong-rig-device-defaults-and-transient-qnap-mkfs-verify-fail` (titled there "sg_persist capture traps, wrong-rig device defaults, and a transient QNAP mkfs verify failure"). Three notes share one theme: a harness reported a verdict about MXFS or the rig from a capture that observed nothing, or observed something other than what the predicate assumed. The third is a one-off rig anomaly kept for its recurrence procedure.

#### 1. A pre-filter is part of the instrument (`trap-sg-persist-says-no-reservation-held-in-capitals-and-a-case-sensitive-filter-throws-the-decisive-line-away`)

- `sg_persist -i -r <dev>` reports an unreserved LUN as `PR generation=0x16d2, there is NO reservation held` (NO capitalised).
- A remote-side `grep -a 'Key=\|type:\|no reservation'` discards that line. The downstream `resv_none()` predicate, even case-insensitive, then inspects a file with the evidence already removed. Case-folding at the predicate cannot repair a case-sensitive capture.
- Cost: lap s87b (fence_late_detection) polled 120 s, never saw the string, exited VACUOUS on a lap where the condition had in fact been reached. About 5 minutes plus a VM boot.
- Rule: grep case-insensitively (`grep -ai`), match on the noun (`reservation held`), and confirm against the tool's real output once rather than what it "would" print.

#### 2. Defaults written on another rig report error text as an observation (`trap-a-harness-hardcoding-one-rigs-device-parses-the-error-text-and-reports-it-as-an-mxfs-observation`)

- `tests/resv_health_detect.sh` and `tests/pr_reservation_ownership_probe.sh` defaulted to `/dev/mapper/mpatha` (CAW multipath rig). On the 2-node TCP rig MXFS is on `/dev/sda`; every `sg_persist` errored.
- The parser found no reservation stanza in the error text and printed `RESERVATION: NONE HELD keys=0 distinct=0`. That asserted MXFS fencing state from a capture of an error message, failed two assertions on a cluster whose reservation was healthy WE-AR with 2 registrants, and the remount step on the same absent device silently left a node unmounted for the rest of the run.
- Non-empty is not the test. The capture was a valid capture of an error. The discriminator must be a shape the tool emits only on success: for `sg_persist`, the `PR generation=` header. Absent header means report `UNKNOWN` and exit non-zero, never `NONE HELD`.
- Scale over 734 scripts in `tests/` and `scripts/`: 101 mention `mpatha`; 21 hardcode `DEV=/dev/mapper/mpatha` with no override; 28 use `${MXFS_DEV:-/dev/mapper/mpatha}`; 39 default to the condition-3 QNAP by-path. 67 are wrong by default on 2/tcp, 21 cannot be pointed at it.
- `run.sh` already resolves per condition (tcp -> `/dev/sda`, caw -> `/dev/mapper/mpatha`, `MXFS_DEV` always overrides); harnesses diverge from it.
- Fix in a harness: take the device from a node's live mount, from the node that stays up when another is unmounted mid-run:
  `DEV="${MXFS_DEV:-}"; [ -n "$DEV" ] || DEV=$(ssh_helper "$OBS" "awk '\$3==\"mxfs\" {print \$1; exit}' /proc/mounts")`, then FATAL exit 2 if still empty.
- General rule: for any default device/path/host, ask which rig it was written on. A default right on one of four rig conditions fails by reporting, not by erroring.

#### 3. QNAP mkfs zero_region verify FAIL right after fleet unmount (`trap-qnap-mkfs-zero-region-verify-fail-transient-right-after-fleet-unmount`)

- Chain s513b prep failed in 13 s: `mkfs.mxfs: zero_region verify FAIL @67119616 byte 2560 = 0x4b`, one second after test1's clean unmount (test2 had shut down on an EDEADLK-NL livelock minutes earlier).
- `sg_persist -k/-r` afterwards: no keys, no reservation, so not the stale-PR-blocks-mkfs shape. Rerun 90 s later prepped fine.
- Offset 0x4001000 lies in the tauth ledger zero_region (`tools/mkfs_mxfs.c:732`). Candidate causes: a ledger write landing after the zero, or a stale read from the QNAP target cache. Not root-caused; one occurrence.
- If it recurs: capture mkfs timestamps against the last node's teardown lines, `dd` the 4 KiB page before the rerun overwrites it, and treat a second occurrence as a ledger-worthy rig defect (silently dropped or reordered writes on the shared LUN threaten integrity of every result on it).

### Common discipline

Never derive a verdict from a capture not proven to contain the tool's success shape; filter case-insensitively on nouns; never let a default encode one rig's device.
