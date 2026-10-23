---
name: compiled-scst-sampling-sibling-lap-binaries-and-free-inode-adopt-traps
description: Traps: SCST/sd-inflight probes, sibling make clean, free-image adopt, B4, withdrawal/NULL gate/barrier, harness asserts, PF_KEEP_KMSG, tauth laps
metadata:
  type: feedback
tags: [compiled, scst, caw, lap, sampling, sibling-checkout, reload, adopt, icache, nblocks, verifier, chk_mxfs, inactivation, unlinked-list, repro-design, vacuous-lap, B4, fencing, withdrawal, authority-lease, barrier, harness, measurement-integrity, rig, mpath, kernel-log, release-reviewer, tauth, defect-queue]
---

Traps in MXFS lap/rig work and in the gates, predicates, barriers and assertions those laps exercise. Common thread: the real state sits behind something that looks authoritative and is not. A probe reads idle / `0:0` / CLEAN while a command is held or a block count is corrupt (sections 1 and 3); a sibling-checkout lap depends on the main tree's `tools/` binaries without announcing it (section 2); a repro built around a peer freeing an inode it did not unlink passes structurally vacuous because the peer lacks authority at its last close (section 4); and a predicate, barrier, assertion or verdict is written against the one state, producer, arm or caller its author observed and silently misjudges every other one (sections 5-11). Sections 12-13 cover what evidence a rig-configuration defect record can rest on: how to keep a path row's full kernel log, and why in-process simulation laps are rejected as verify/removal proof. Some are product defects; some are harness attribution errors that look like MXFS defects in the RESULT line.

Provenance: sections 1-4 are the original lap/rig article (sessions 37-39 and 86; four notes the clusterer could not fit to one topic, plus `compiled-peer-last-close-b4-no-authority` absorbed as section 4). Sections 5-11 are absorbed in full from `compiled-fencing-withdrawal-gates-barriers-and-harness-assertion-traps`: product-side traps (5-7), harness and measurement traps (8-10), one planning trap (11). Sections 12-13 are absorbed in full from `compiled-rig-evidence-kmsg-capture-and-verify-laps` (an assorted group: two rig-testing notes sharing only that both concern the evidence a defect record observed on a rig configuration, e.g. 8/net/mesh/mpath, can rest on).

## 1. SCST target-side and node-side sampling blind spots

Source: `trap-scst-target-sampling-blind-spots`. Facts read from the SCST source in `~/src/scst` (session 39, defect `D-CAWMPATH-UMOUNT-RELEASE-ALL-CAW-HELD-57S-BOTH-NODES`), each of which a target-side probe gets wrong if it guesses:

- **Thread names.** A device's per-initiator command threads are created with `"%.10s%d_%d"` (`scst/src/scst_main.c:1722`): the first 10 chars of the device name, the initiator (tgt_dev) index, `_`, the thread number. So pool LUN `mxfspool01`'s threads are `mxfspool010_*`, `mxfspool011_*`, ... (one pool per initiator path). A match on `mxfspool01_*` matches nothing; `mxfspool01*` is right. Global command threads are `scstd<n>`; iscsi-scst's per-connection threads are `iscsird<n>_<m>` / `iscsiwr<n>_<m>`.
- **PERSISTENT RESERVE OUT blocks the whole LUN.** Its cdb entry carries `SCST_SERIALIZED` (`scst/src/scst_lib.c:1197`), and a serialized command calls `scst_block_dev()` (`scst_lib.c:13881-13889`): every other command to that device, from every initiator, waits in the blocked list until it completes. Its execution persists the PR state to a file on the lab host's root filesystem and fsyncs it (`scst_pr_sync_device_file` -> `vfs_fsync`), so under a host write storm one PR OUT holds the LUN for the length of a root-ext4 journal commit. Seen in lap cus1/cus3 stacks: `jbd2_log_wait_commit <- ext4_sync_file <- vfs_fsync <- scst_pr_sync_device_file <- scst_persistent_reserve_out_local`.
- **async=1 hides the wait from the pool threads.** With vdisk_fileio async=1 a pool thread submits a CAW's internal READ16/WRITE16 and goes idle; a completion held elsewhere (kworker, writeback, reclaim) leaves every pool thread sampled idle. Sample all D-state host tasks (`/proc/*/stat` + `/proc/<pid>/stack`, both safe) instead of only the pool.
- **Node side: `/sys/block/sdX/inflight` does not show a COMPARE AND WRITE.** It counts filesystem I/O; a passthrough request (`blk_execute_rq`) is not counted. Lap cus3 read `0:0` on every sd* for the whole 60 s a CAW sat in `blk_execute_rq`. Count `device/iorequest_cnt - device/iodone_cnt` (hex, includes passthrough) and read `device/state`.

`tests/caw_umount_storm.sh` samples all four ways since session 39. `trap-scst-target-sampling-blind-spots`

## 2. `make clean` / rebuild in the main tree aborts sibling-checkout laps in prep

Source: `trap-main-tree-make-clean-aborts-sibling-lap-prep`. A lap started from a sibling checkout (`~/src/mxfs-b`, `-c`, `-e`) loads the sibling's `mxfs.ko`, but its node-side prep formats the LUN with `/src/mxfs/tools/mkfs_mxfs` and its audit runs `/src/mxfs/tools/chk_mxfs` -- the MAIN tree's binaries (`/src/mxfs` is `~/src/mxfs` over NFS).

- `make clean` in the main tree (it runs `make -C tools clean`) deletes the binaries every sibling lap is about to exec.
- Observed (session 38, 2026-10-17): the main tree was rebuilt at 18:00:16Z between two laps of a sibling queue; the next two laps started their prep inside the ~45 s build and ABORTed at stage=prep with `FS_PREP_FAIL: mkfs_mxfs -f -n 4 /dev/mapper/mpatha returned 127` (command not found). Two A/B laps lost and rerun.
- **How to apply:** before rebuilding the main tree, read every running queue's log (all checkouts, `tests/evidence/lapq_*.log`). Rebuild only when no lap of ANY checkout is in prep or audit, or build tools elsewhere and install them with an atomic rename. A lap's prep is its first ~20-140 s; its audit is near its end.

## 3. `xfs_inode_from_disk` on a FREE dinode adopts only `di_gen` and `di_mode`

Source: `trap-xfs-inode-from-disk-free-image-adopts-only-gen-and-mode`. Upstream `xfs_inode_from_disk` returns right after copying `di_gen` and `di_mode` when the mode is 0 ("If the inode is unused ... we shouldn't mess with the uninitialized part of it"). Upstream only ever fills a freshly zeroed in-core inode, so that is safe there.

- **MXFS adopts into live inodes.** Reloads adopt platter images INTO live in-core inodes (`P116-ZOMBIE-ADOPT`, `P103-RELOAD-REUSE-ADOPT`, the recycle gate). Adopting a peer's FREE image therefore leaves the dead life's `i_nblocks`, `i_disk_size`, data/attr fork state and intent flags (`MXFS_IF_LOCAL_UNLINK`) in core under a mode-0 shell.
- **What it broke** (`D-CREATE-ON-ZOMBIE-SHELL-INHERITS-DEAD-LIFE-NBLOCKS`, found session 37 on lap q6dc1, 2/net/mesh/direct): a create recycled such a shell, the recycle's `P-RECYCLE-SANITIZE` arm was gated on `i_mode != 0`, and `xfs_inode_init` only ASSERTs `i_nblocks == 0` (compiled out). The new empty file's core went home with nblocks 1 and no extents and failed `xfs_dinode_verify` (`xfs_inode_buf.c` 'nextents + naextents == 0 && nblocks != 0') on every node. A new file that got extents carried a silently inflated count.
- **How to apply:**
  - Any code that adopts a free image into an existing in-core inode must reset the in-core fields itself (the `P-RECYCLE-SANITIZE` arm / `mxfs_dlm_reset_inode_for_create` are the existing resets); never assume `xfs_inode_from_disk` did.
  - A cold audit reading CLEAN said nothing about block counts until `chk_mxfs` gained the `P-NBLOCKS-MISMATCH` check (session 37 source): CAW laps pwc1/pwc2 carried this corruption and were judged CLEAN.
  - `+0x80a` of `xfs_dinode_verify.part.0` is the nblocks-without-extents check only for builds of that source; resolve offsets with `nm mxfs.ko | grep 'xfs_dinode_verify\.part\.0$'` then `gdb -batch -ex 'info line *(0x<addr>+0x80a)' mxfs.ko` (gdb cannot parse the `.part.0` name directly).

## 4. A peer's last close does not free an inode another node unlinked (B4 no-authority)

Absorbed from `compiled-peer-last-close-b4-no-authority` (a single-note group the clusterer could not fit to a sibling topic). Its subject is the MXFS authority check that decides which node frees an unlinked inode at inactivation (B4 no-authority), and the repro-design failure that follows from it. Source: `trap-peer-last-close-never-frees-an-inode-it-did-not-unlink-b4-skip`.

**The trap.** A node frees an unlinked inode only if it unlinked it itself (`MXFS_IF_LOCAL_UNLINK` / adopted unlink) or holds it EX in `i_dlm_mode`. The inactivation's own raw EX (`P-INACT-EX gmode=5`) does NOT set `i_dlm_mode`, and the last close publishes its open-clear by riding a demote first.

So when node B holds a file open that node A unlinked, B's last close logs `P19-B3DEC ... b4_noauth=1` and `INACT-SKIP-STALE reason=no-authority-unlocked-not-unlinked`, and the free is left to A (its reaper, or A's next drop of a pinned reference).

**What it broke.** Session 86: the directed H-IU1 queue (`tests/peer_open_unlinked_chain.sh`, owner rm z then y, peer holds y and closes it inside z's widened predecessor wait) ran six laps, all PASS, all `held_moved=0`. The peer never freed y, so the race the queue was built to force never happened; the queue measured nothing for its hypothesis.

**How a peer does get authority.** Through EX taken by an operation, then the last reference dropping while that EX is still cached.
- fn32's test1 took the peer's zombie's EX through `touch` (`P6H-ADOPT comm=touch`, then `P9-NLEDGE from_disk old=1 new=0`) and its next iput ran the inactivation with EX held.
- The noino_gen0 workload's lookup/stat loops produce this naturally (lap ifd2: `P-UNLPREV-MOVED ... comm=stat`).

**How to apply.** Before building a repro where one node must free an inode another node unlinked, check that the freeing node will hold `i_dlm_mode == EX` at the inactivation, not just an open file it closes. Grade reach in the harness with a counter that must be > 0, so a structurally vacuous lap reads VACUOUS instead of PASS.

## 5. Product trap: multi-producer state read through one producer's flag (withdrawn predicate)

From `compiled-fencing-withdrawal-gates-barriers-and-harness-assertion-traps`. `v5_lease_member_state_cb` (dlm/v5_mount.c, 0.89.68) answered WITHDRAWN only when `ctx->disklock->auth->state == MXFS_AUTH_CLOSED`. A mount withdraws two ways: (1) authority CLOSED (lease expiry, PR conflict, revocation) via `P290-AUTH-CLOSED` -> withdraw pump -> `mxfs_v5_dlm_withdraw`; (2) forced shutdown (`xfs_do_force_shutdown`, `dbg_dialloc_shutdown`, log I/O error) via `mxfs_v5_dlm_withdraw` -> `mxfs_v5_dlm_poison`, which sets `ctx->withdrawn` and stamps the slot WITHDRAWN but never moves the authority off ADMITTED. Renewals kept saying MEMBER and the peer promoted SUSPECT back to ACTIVE 546 ms after reading the stamp. Fixed in 0.89.69 by reading both (`ctx->withdrawn` / `mxfs_v5_dlm_is_withdrawn`). A lap that drives the other producer measures the consumer's blind spot as the defect. See `trap-a-withdrawn-predicate-that-reads-only-the-authority-object-misses-the-forced-shutdown-withdrawal`.

## 6. Product trap: NULL pointer as permission (teardown gate)

From `compiled-fencing-withdrawal-gates-barriers-and-harness-assertion-traps`. 0.89.20 gated five mutating producers with `if (v5 && !mxfs_v5_dlm_write_admitted(v5))`, and `write_admitted(NULL)` returned true ("not a clustered mount"). `xfs_fs_put_super` sets `mp->m_mxfs_dlm = NULL` before the log cover and unmount record, so the gate answered itself on a node that had stopped proving liveness; `tail_admit=1` on every ordinary unmount. A predicate on pointer liveness answers "is there a context", not "may this proceed". Comments like "NULL it so a queued X no-ops" mean the pointer is being used as a flag with an unplanned third state. Do not move the NULL; make the question answerable for the work's whole life via a property that is never cleared (`mp->m_mxfs_clustered`) plus a refcounted state object that outlives all holders. See `trap-a-gate-that-reads-a-pointer-the-teardown-clears-reads-the-absence-of-the-reference-as-permission`.

## 7. Product trap: a lease-bounded wait is unbounded for a slotless caller (reset barrier)

From `compiled-fencing-withdrawal-gates-barriers-and-harness-assertion-traps`. `mxfs_v5_dlm_lu_reset_barrier` (dlm/v5_mount.c, 0.89.32) exits on `dl->auth->last_ok_ms > reset_issued_ms` or `!mxfs_disklock_authority_ok(dl)`; both derive from a claimed heartbeat slot. The whole-cluster bootstrap owner has no slot by design and beats only the bootstrap record (`v5_boot_hb_fn`), so the loop never exits; `mount` hung and `timeout 240` could not reap it (evidence 20260921T025611Z_bootfull, last line `P307-LURESET-CONVERGE converged=1`). Diagnosable because `P307-LURESET-BARRIER` is logged unconditionally after the loop on both outcomes: its absence proved "never left". Before reusing a wait justified by "the lease is the timeout", enumerate callers and check each holds what each exit reads. Fix: for a slotless owner exit on a bootstrap beat after `reset_issued_ms` or `ctx->boot_hb_lost`. The barrier predates the bootstrap and nothing re-drove the bootstrap through it. See `trap-a-barrier-whose-two-exits-are-both-slot-derived-hangs-forever-for-the-one-caller-that-has-no-slot`.

## 8. Harness trap: arm-specific durable state asserted unconditionally (fence-cut harness)

From `compiled-fencing-withdrawal-gates-barriers-and-harness-assertion-traps`. `tests/fence_crash_cuts.sh:645` asserted `flags=ACTIVE` on the victim slot at cut 1 regardless of arm. The silent arm parks the heartbeat (`dl_inject_hb_pause_ms=150000`); the 30 s authority lease expires, the victim self-fences (`P131-SELF-FENCE`, `AUTHORITY_LEASE_EXPIRED`) and stamps WITHDRAWN. ACTIVE is only what the destroyed (power-cut) arm can leave. The real subject was "prover died before the intent CAS, no RECOVERY_GUARD and no descriptor"; read the resting state per arm, never a single literal. Second instance in two days of a harness naming one node/state as the expected one. Also: never edit a harness script while a sweep is executing it (bash reads by byte offset); the fix waits for the sweep. See `trap-an-expected-durable-state-that-only-one-victim-arm-can-produce-must-not-be-asserted-unconditionally`.

## 9. Harness trap: capture set wider than count set (fence-cut silent arm)

From `compiled-fencing-withdrawal-gates-barriers-and-harness-assertion-traps`. `fence_crash_cuts.sh` silent arm captured `P131-SELF-FENCE` and `P236-SELF-FENCE` into `B_contain.txt` but its `contain=` count omitted both, so a working self-fence read `contain=0` (lap s108a cut 7) while every later fsync returned rc=1. The predicate judging a property must read the same family the capture collects. `wait_for_into` sets its variable to the poll index on success (`0` = first-poll hit) and to the string `timeout` on failure, so a bare `resumed=0` is a hit. A cumulative-fails gate (`[ $fails = 0 ] || ABORT`) names the stage it sits in, not the stage that failed; read the FAIL lines. See `trap-a-containment-assertion-that-counts-a-narrower-pattern-set-than-its-own-capture-fails-a-containment-that-worked`.

## 10. Measurement trap: control reproduced outside the defence window (D-0945)

From `compiled-fencing-withdrawal-gates-barriers-and-harness-assertion-traps`. D-0945 positive control (sess582): with the victim-side poison gate off, the ungated release reached the master 2.65 s after shutdown, but the fence sealed at 2.4 s, so `mxfs_dlm_process_remote_release` refused it (`P-TAUTH-SEALED-RELEASE-REFUSED`) and the manifest held the grant. Reading "gate off, no harm" concludes the gate is unnecessary. When a defect has several lines of defence, a control that reproduces the cause at the wrong time is caught by the next line. Before scoring: (1) measure the primary defence's window with timestamps on both nodes; (2) put the actor inside it deliberately (`echo 2 > /proc/sys/vm/drop_caches` right after the trigger) and prove it with the second-line counter at zero (`sealed_owner_refusals=0`) plus a direct effect (manifest 3 vs 4 entries); (3) report which line answered per arm. Evidence: 20260911T193709Z_d0945ctl_s582a, 20260911T194213Z_d0945ctl_s582b. See `trap-a-cause-reproduced-outside-its-timing-window-lands-in-the-second-defence-and-reads-as-unreachable`.

## 11. Planning trap: a "route closed" verdict expires when the capability is built another way

From `compiled-fencing-withdrawal-gates-barriers-and-harness-assertion-traps`. `D-FENCE-CRASH-MATRIX-UNTESTED` said route 1 (witnessed SCSI LU RESET) was closed because `scsi_ioctl_reset` is unexported and `try_*_reset` are static on 6.8. True for in-kernel reach only. 0.89.33/34 built it through `mxfs_pal_lu_reset_witness()` -> `call_usermodehelper` -> `ioctl(SG_SCSI_RESET ...)` with `retire_basis = completed-target-op`, called from the dead-peer prover; the record was never updated. A feasibility judgement phrased "there is no X" outlives someone building the capability without X. Check whether the capability (grep `lu_reset`, `LURESET`, the fence-kind enum) has an implementation, not whether the named symbol is still missing; when a route is built, sweep the queue for records whose next step was written while it was closed. Mirror of withdrawing a mechanism expiring banked passes (`trap-banked-lap-evidence-stops-describing-the-build-when-an-intervening-change-withdraws-the-mechanism-the-lap-depended-on`). See `trap-a-records-next-step-can-declare-a-route-closed-on-reasoning-a-later-version-made-obsolete-by-building-it-another-way`.

## 12. Keep the unfiltered kernel log of a multipath path row

From `compiled-rig-evidence-kmsg-capture-and-verify-laps`. Goal, from `technique-path-rows-keep-the-unfiltered-kernel-log-with-pf-keep-kmsg`: every kernel line of a path row (path_all_lost, path_fence_degraded, path_fenced_return, path_peer_withdrawn), debug lines included, without a code change.

- The rig already loads the module with `dyndbg=+p` (`tests/setup/prep_node.sh:53-54`), so every `MXFS_LOG_DEBUG` line (one `pr_debug` in `mxfs_pal_vlog`, `pal/linux/kern.c:4803-4823`) and every `mxfs_probe` site prints. `technique-path-rows-keep-the-unfiltered-kernel-log-with-pf-keep-kmsg`
- Each path row follows each node's kernel log unfiltered into `/run/mxfs_pf_kmsg.<run>.<row>` on the node (`tests/mpath/lib.sh:177-180`, `tests/lib/rig.sh:301-305`, `dmesg --follow`).
- The row's own `kern_<node>.txt` is a filtered grep (`tests/mpath/lib.sh:399`), so it misses the takeover phases.
- The whole log is kept as `kmsg_<node>_fromnode.gz` only when the row's own checks failed (`kmsg_keep`, `:233-243`). A PASS deletes it (`:544-554`), and so does a row that run.sh fails on its stall.
- `MXFS_TEST_ENV=PF_KEEP_KMSG=1` (run.sh passes MXFS_TEST_ENV to the row, `run.sh:1593-1595`) keeps the gzip on a PASS too. MXFS_TEST_ENV records the run as a variant, so it grades no candidate, but its failures are still incidents.
- `MXFS_KEEP_ARTIFACTS` does not reach these rows: it is read only in `run_coord`, and path rows go through `run_host`.
- Found 2026-10-23 when the silent-peer-death record claimed no unfiltered trace could be kept without editing the harness. `technique-path-rows-keep-the-unfiltered-kernel-log-with-pf-keep-kmsg`

## 13. In-process simulation laps cannot verify or remove a rig-configuration record

From `compiled-rig-evidence-kmsg-capture-and-verify-laps`, source `trap-in-process-simulation-laps-cannot-verify-a-rig-configuration-record`: a verification or removal batch for a defect observed on a rig configuration (e.g. 8/net/mesh/mpath) is rejected when its laps run the in-process tauth simulation (`tests/tauth/*_test.sh`: four simulated nodes in one process on the lab host, `VMs held for the lap: none`), however clean the statistics.

Seen 2026-10-23 on candidate 0.90.134: verifies P20261023-867053 and P20261023-6664ba and removals P20261023-778a6d and P20261023-6c4c99 (records D-8NETMESH-SURVIVOR-SHUTDOWN-FALSE-FRESH-AG-GRANT-AFTER-TAKEOVER and D-SELF-FENCED-NODE-LEDGER-PUBLISHER-RETRIES-FOREVER-ON-RESERVATION-CONFLICT) were all rejected although controls were 10/10 and fix-on batches 6/6 with exposure.

Why the reviewer refuses:
- the configuration the verify would clear never ran, and no lap loaded the candidate's module (the ledger's build field comes from `modinfo` of a module nobody loaded);
- a simulation whose store never refuses a write cannot produce a RESERVATION CONFLICT loop, so the recorded failure was neither reproduced nor shown gone;
- `tests/tauth/Makefile` omits included headers from some object rules, so the linked binary is not shown to be built from the frozen tree;
- a removal settles every run the record names, so failures in that run the cause does not explain must first be named by another open record.

What passes instead: board-row laps (`harness_batch.py --board`, `MXFS_CANDIDATE` set) at the record's configuration on the candidate's module, a kernel-log probe of the trigger on the node that hits it, and N sized from a control measured there (knob off through `MXFS_EXTRA_MODARGS`, or the fix reverted in a scratch copy of the frozen file list), or an explicit `--transfer` the reviewer can check. Plan the rig laps before spending a lane on simulation laps.
