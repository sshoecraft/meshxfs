---
name: compiled-release-candidate-freeze-drift-traps
description: Assorted single note: files added under tests/tools/scripts during a running candidate drift it; release_candidate.py check sets INVALID; what still…
metadata:
  type: feedback
tags: [compiled, release-candidate, freeze, traps]
---

Assorted group of one note (the clusterer could not fit it to a wider topic): traps around the release-candidate freeze in `tools/release_candidate.py`. Source: `trap-lane-queue-files-under-tests-drift-a-running-candidate`.

## What bit
- Candidate 0.90.134's attempt, frozen 2026-10-23T20:41:09Z, drifted on five ADDED files: `scripts/scst_reload.sh` and four lane queues `tests/lanes/queue_*.txt`, written by a session after the freeze. `trap-lane-queue-files-under-tests-drift-a-running-candidate`
- `tools/release_candidate.py` freezes every file under `tests`, `tools`, `scripts` (FROZEN_DIRS) except the MUTABLE patterns (`tests/evidence/*`, `*.pyc`, `*.o`, `tests/queues/*.state`, ...). `tests/lanes/` is not MUTABLE, so a new queue file there is drift exactly like an edited source file.
- The Edit/Write freeze hook did not stop it: the files were new, written while the session's hook judged them, or through the shell.

## Second trap: `check` is not read-only
- `tools/release_candidate.py check <version>` on drift prints the changes and sets the candidate's state to INVALID in `data/candidates/<version>.json` ("candidate 0.90.134 is now INVALID"). Session 56 ran it to look, and that moved the state.

## What still works on an INVALID attempt (read in tools/defects.py, 2026-10-24)
- `check_batch_lap` (defects.py:989) checks batch state, row, configuration and candidate name, not the candidate's state, so running batch laps continue.
- `cmd_verify` (:1302-1360) does not check it either, and counts laps after `criteria.attempt_began`, which only a new `create` moves.
- A reviewer may still object to evidence from a drifted tree, so cite that the drift touches no file the lap runs.

## How to apply
- Put lane queue files for a running attempt under `tests/evidence/` (MUTABLE), never `tests/lanes/`; land new scripts in the sibling tree for the next freeze.
- Before writing any file into the main tree during an attempt, ask `tools/release_candidate.py frozen <path>`.
- Do not run `check` to look; read the manifest, or run `frozen` per path.
