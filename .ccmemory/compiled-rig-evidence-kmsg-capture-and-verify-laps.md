---
name: compiled-rig-evidence-kmsg-capture-and-verify-laps
description: Rig-config defect evidence: PF_KEEP_KMSG=1 keeps a path row's full kernel log; in-process tauth laps are rejected as verify/removal proof
metadata:
  type: feedback
tags: [compiled, rig, mpath, kernel-log, release-reviewer, verification, tauth, defect-queue]
---

Assorted group (the clusterer's tail, no single subject): two rig-testing notes with one thing in common, the evidence a defect record observed on a rig configuration (multipath/mesh path rows, e.g. 8/net/mesh/mpath) can rest on. Part 1 is how to keep a path row's complete kernel log without editing the harness. Part 2 is why the release-reviewer rejects in-process simulation laps as verify/removal evidence for such a record.

## 1. Keep the unfiltered kernel log of a multipath path row

Goal, from `technique-path-rows-keep-the-unfiltered-kernel-log-with-pf-keep-kmsg`: every kernel line of a path row (path_all_lost, path_fence_degraded, path_fenced_return, path_peer_withdrawn), debug lines included, without a code change.

- The rig already loads the module with `dyndbg=+p` (`tests/setup/prep_node.sh:53-54`), so every `MXFS_LOG_DEBUG` line (one `pr_debug` in `mxfs_pal_vlog`, `pal/linux/kern.c:4803-4823`) and every `mxfs_probe` site prints. `technique-path-rows-keep-the-unfiltered-kernel-log-with-pf-keep-kmsg`
- Each path row follows each node's kernel log unfiltered into `/run/mxfs_pf_kmsg.<run>.<row>` on the node (`tests/mpath/lib.sh:177-180`, `tests/lib/rig.sh:301-305`, `dmesg --follow`).
- The row's own `kern_<node>.txt` is a filtered grep (`tests/mpath/lib.sh:399`), so it misses the takeover phases.
- The whole log is kept as `kmsg_<node>_fromnode.gz` only when the row's own checks failed (`kmsg_keep`, `:233-243`). A PASS deletes it (`:544-554`), and so does a row that run.sh fails on its stall.
- `MXFS_TEST_ENV=PF_KEEP_KMSG=1` (run.sh passes MXFS_TEST_ENV to the row, `run.sh:1593-1595`) keeps the gzip on a PASS too. MXFS_TEST_ENV records the run as a variant, so it grades no candidate, but its failures are still incidents.
- `MXFS_KEEP_ARTIFACTS` does not reach these rows: it is read only in `run_coord`, and path rows go through `run_host`.
- Found 2026-10-23 when the silent-peer-death record claimed no unfiltered trace could be kept without editing the harness. `technique-path-rows-keep-the-unfiltered-kernel-log-with-pf-keep-kmsg`

## 2. In-process simulation laps cannot verify or remove a rig-configuration record

From `trap-in-process-simulation-laps-cannot-verify-a-rig-configuration-record`: a verification or removal batch for a defect observed on a rig configuration (e.g. 8/net/mesh/mpath) is rejected when its laps run the in-process tauth simulation (`tests/tauth/*_test.sh`: four simulated nodes in one process on the lab host, `VMs held for the lap: none`), however clean the statistics.

Seen 2026-10-23 on candidate 0.90.134: verifies P20261023-867053 and P20261023-6664ba and removals P20261023-778a6d and P20261023-6c4c99 (records D-8NETMESH-SURVIVOR-SHUTDOWN-FALSE-FRESH-AG-GRANT-AFTER-TAKEOVER and D-SELF-FENCED-NODE-LEDGER-PUBLISHER-RETRIES-FOREVER-ON-RESERVATION-CONFLICT) were all rejected although controls were 10/10 and fix-on batches 6/6 with exposure. `trap-in-process-simulation-laps-cannot-verify-a-rig-configuration-record`

Why the reviewer refuses `trap-in-process-simulation-laps-cannot-verify-a-rig-configuration-record`:
- the configuration the verify would clear never ran, and no lap loaded the candidate's module (the ledger's build field comes from `modinfo` of a module nobody loaded);
- a simulation whose store never refuses a write cannot produce a RESERVATION CONFLICT loop, so the recorded failure was neither reproduced nor shown gone;
- `tests/tauth/Makefile` omits included headers from some object rules, so the linked binary is not shown to be built from the frozen tree;
- a removal settles every run the record names, so failures in that run the cause does not explain must first be named by another open record.

What passes instead `trap-in-process-simulation-laps-cannot-verify-a-rig-configuration-record`: board-row laps (`harness_batch.py --board`, `MXFS_CANDIDATE` set) at the record's configuration on the candidate's module, a kernel-log probe of the trigger on the node that hits it, and N sized from a control measured there (knob off through `MXFS_EXTRA_MODARGS`, or the fix reverted in a scratch copy of the frozen file list), or an explicit `--transfer` the reviewer can check. Plan the rig laps before spending a lane on simulation laps.
