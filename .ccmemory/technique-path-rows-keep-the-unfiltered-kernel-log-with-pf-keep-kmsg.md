---
name: technique-path-rows-keep-the-unfiltered-kernel-log-with-pf-keep-kmsg
description: Rig loads mxfs with dyndbg=+p; path_* rows follow each node's whole log; MXFS_TEST_ENV=PF_KEEP_KMSG=1 keeps it on a PASS too
metadata:
  type: feedback
---

To get every kernel line of a multipath path row (path_all_lost, path_fence_degraded, path_fenced_return, path_peer_withdrawn), debug lines included, without a code change:

- The rig already loads the module with `dyndbg=+p` (`tests/setup/prep_node.sh:53-54`), so every `MXFS_LOG_DEBUG` line (one `pr_debug` in `mxfs_pal_vlog`, `pal/linux/kern.c:4803-4823`) and every `mxfs_probe` site prints.
- Each path row follows each node's kernel log unfiltered into `/run/mxfs_pf_kmsg.<run>.<row>` on the node (`tests/mpath/lib.sh:177-180`, `tests/lib/rig.sh:301-305`, `dmesg --follow`).
- The row's own `kern_<node>.txt` is a filtered grep (`tests/mpath/lib.sh:399`), so it misses the takeover phases. The whole log is kept as `kmsg_<node>_fromnode.gz` only when the row's own checks failed (`kmsg_keep`, `:233-243`). A PASS deletes it (`:544-554`), and so does a row that run.sh fails on its stall.
- `MXFS_TEST_ENV=PF_KEEP_KMSG=1` (run.sh passes MXFS_TEST_ENV to the row, `run.sh:1593-1595`) keeps the gzip on a PASS too. MXFS_TEST_ENV records the run as a variant, so it grades no candidate, but its failures are still incidents.
- `MXFS_KEEP_ARTIFACTS` does not reach these rows: it is read only in `run_coord`, and path rows go through `run_host`.

Found 2026-10-23 when the silent-peer-death record claimed no unfiltered trace could be kept without editing the harness.
