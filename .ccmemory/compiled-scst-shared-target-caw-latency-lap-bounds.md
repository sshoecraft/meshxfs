---
name: compiled-scst-shared-target-caw-latency-lap-bounds
description: Rig timing traps: lanes sharing the one SCST target double CAW latency and overrun tight lap bounds; release-candidate freeze drift from added files/…
metadata:
  type: feedback
tags: [compiled, trap, rig, scst, timing, batch, release-candidate, freeze, drift, subagent]
---

Two rig-trap topics that share no wider subject (merged, not one topic): (A) timing-graded rig laps sharing one SCST target, and (B) the release-candidate freeze in `tools/release_candidate.py` and what drifts a RUNNING candidate. Part B folds `compiled-frozen-release-candidate-subagent-script-drift` (itself folding `compiled-release-candidate-freeze-drift-traps`). Related: [[compiled-make-modules-under-running-lanes-trap]] (building `mxfs.ko` in place under running lanes).

# A. Lanes sharing the SCST target double CAW latency

Source: `trap-lanes-sharing-the-scst-target-double-caw-latency-and-overrun-tight-lap-bounds`.

## Trap

All rig groups reach pool LUNs on ONE SCST target on clyde. When create-heavy lanes run at the same time (a 40000-create stage on disk/caw, a TCP ledger-heavy unmount lap, even a local-disk create loop on a node), every COMPARE AND WRITE another lane issues takes about twice as long. In tests/fourkn_merge_2node.sh the kernel's CAW-ILOCK avg went from ~1.5 ms to 3.0-3.7 ms, the worker from a 7.8 s median to 15.4 s, and its 16 s client bound (WBOUND) cut the other node's half. Lap 104 of a 298-lap verification failed that way and the whole batch was lost (D-FOURKN-MERGE-WORKLOAD-OVERRAN-16S-WHEN-EVERY-CAW-TOOK-TWICE-AS-LONG). `trap-lanes-sharing-the-scst-target-double-caw-latency-and-overrun-tight-lap-bounds`

## How to apply

- Before declaring a long verification batch of a lap whose bound is near 2x its own median wall, check what else will load the target while it runs; keep create-heavy lanes (lmu traces, alloc fills, rsync) off it, or schedule the batch when nothing else runs. `trap-lanes-sharing-the-scst-target-double-caw-latency-and-overrun-tight-lap-bounds`
- When a timing-graded lap fails with no error in its kernel log, compare the per-op CAW latency counters (CAW-ILOCK n/tot_ms/avg_us lines) against a passing lap before suspecting the filesystem, and list every lane running in the window (tests/evidence/lanes/*/summary.log step times). `trap-lanes-sharing-the-scst-target-double-caw-latency-and-overrun-tight-lap-bounds`
- Single-writer creates on 2/disk/caw/direct cost 6-18 ms each (D-SINGLE-WRITER-CREATE-PACE-...), against the ~2.2 ms tests/last_member_umount_lap.sh assumed from the TCP lock manager: a lap bound derived on net/mesh overruns on disk/caw in its setup stage. Derive per lock manager. `trap-lanes-sharing-the-scst-target-double-caw-latency-and-overrun-tight-lap-bounds`
- Do not run your own ad-hoc load probes on rig nodes while another lane's timing-graded batch runs. `trap-lanes-sharing-the-scst-target-double-caw-latency-and-overrun-tight-lap-bounds`

# B. Release-candidate freeze: added files drift a running candidate

From `compiled-frozen-release-candidate-subagent-script-drift`: traps around files added under a frozen directory while a candidate is RUNNING (lane queue files, `check` not read-only, what works on an INVALID attempt).

## Frozen directories and what counts as drift
- `tools/release_candidate.py` freezes every file under `tests`, `tools`, `scripts` (FROZEN_DIRS) except the MUTABLE patterns (`tests/evidence/*`, `*.pyc`, `*.o`, `tests/queues/*.state`, ...). `compiled-release-candidate-freeze-drift-traps`
- An ADDED file in a frozen dir is drift exactly like an edited one: it sets the candidate INVALID at the next check. `tests/lanes/` is not MUTABLE, so a new queue file there is drift.
- The Edit/Write freeze hook did not stop it: the files were new, written while the session's hook judged them, or through the shell. `compiled-release-candidate-freeze-drift-traps`
- `release_candidate.py frozen <path>` does not catch a new file: it answers 0 only for a path already in the manifest's file list (or non-mutable `data/`); a new file returns 1 ("not frozen") although adding it is drift.

## Incident 1: lane queue files (candidate 0.90.134, attempt frozen 2026-10-23T20:41:09Z)
- Drifted on five ADDED files: `scripts/scst_reload.sh` and four lane queues `tests/lanes/queue_*.txt`, written by a session after the freeze. `compiled-release-candidate-freeze-drift-traps` (original note `trap-lane-queue-files-under-tests-drift-a-running-candidate`)

## Incident 2: subagent helper script (session 65, 0.90.134 attempt frozen 2026-10-24T04:13:43Z)
Original note: `trap-subagent-writes-a-helper-into-scripts-and-drifts-a-running-candidate`.
- A `miner` subagent asked to parse prep step timings wrote its parser to `scripts/prep_step_stats.py`, because the global rules say anything executable goes in the repo's `tools/`/`scripts/`, never `/tmp`.
- That file was an ADDED file under a frozen dir: drift, candidate INVALID at the next check.
- The Edit/Write freeze hook did not stop it (the agent's write was a new file).

## `check` is not read-only
- `tools/release_candidate.py check <version>` on drift prints the changes and sets the candidate's state to INVALID in `data/candidates/<version>.json` ("candidate 0.90.134 is now INVALID"). Session 56 ran it to look, and that moved the state. `compiled-release-candidate-freeze-drift-traps`

## What still works on an INVALID attempt (read in tools/defects.py, 2026-10-24)
- `check_batch_lap` (defects.py:989) checks batch state, row, configuration and candidate name, not the candidate's state, so running batch laps continue.
- `cmd_verify` (:1302-1360) does not check it either, and counts laps after `criteria.attempt_began`, which only a new `create` moves.
- A reviewer may still object to evidence from a drifted tree, so cite that the drift touches no file the lap runs. `compiled-release-candidate-freeze-drift-traps`

## How to apply
- While a candidate is RUNNING, every delegated prompt that might produce a script must say: write no file under `tests/`, `tools/`, `scripts/`, `packaging/` or `run.sh`; put any helper you need under the session scratchpad (or `tests/evidence/`, which is MUTABLE), and say where it is.
- Put lane queue files for a running attempt under `tests/evidence/` (MUTABLE), never `tests/lanes/`; land new scripts in the sibling tree for the next freeze. `compiled-release-candidate-freeze-drift-traps`
- Before writing any file into the main tree during an attempt, ask `tools/release_candidate.py frozen <path>` (remembering a new file answers 1 yet is still drift: treat only a MUTABLE-pattern path as safe).
- Do not run `check` to look; read the manifest, or run `frozen` per path. `compiled-release-candidate-freeze-drift-traps`
- If a file slips in, move it out of the frozen dirs at once (before any orchestrator step or `check`), keep it in the scratchpad, and land it under `scripts/` right after the attempt is abandoned.
- After any agent returns, check its report for "I wrote ... new file" before trusting the tree is unchanged.
