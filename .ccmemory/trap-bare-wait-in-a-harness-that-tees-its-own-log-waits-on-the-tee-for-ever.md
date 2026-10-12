---
name: trap-bare-wait-in-a-harness-that-tees-its-own-log-waits-on-the-tee-for-ever
description: TRAP: `exec > >(tee log)` then a bare `wait` blocks for ever on the tee process substitution; wait on the PIDs you started.
metadata:
  type: feedback
---

A harness that logs itself with `exec > >(tee "$OUT/run.log") 2>&1` and later fans work out with `cmd &` ... `wait` hangs indefinitely: bash (5.1+) counts the process substitution as a child, and `wait` with no arguments waits for it too. The tee never exits while the script runs, so the script never proceeds.

Seen in tests/multi_mount.sh (0.90.120): the per-node writers finished in 0.6 s, both filesystems held every file, and the run sat in `wait` for an hour; it looked exactly like a filesystem hang until the node-side state was read.

Fix: collect `pids+=($!)` for each background job and `wait "${pids[@]}"`. Before diagnosing a "hang" in a harness, check whether the remote work actually finished (files present, no D-state task) — if it did, the hang is local.
