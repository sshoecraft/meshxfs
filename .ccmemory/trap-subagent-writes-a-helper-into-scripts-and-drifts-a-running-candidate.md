---
name: trap-subagent-writes-a-helper-into-scripts-and-drifts-a-running-candidate
description: A miner/scout told nothing about the freeze wrote its parser to scripts/ (the global "code goes in the repo" rule): an added file drifts a RUNNING ca…
metadata:
  type: feedback
tags: [release-candidate, freeze, drift, subagent, trap]
---

**What bit (session 65, 0.90.134 attempt frozen 2026-10-24T04:13:43Z):** a `miner` subagent asked to parse prep step timings wrote its parser to `scripts/prep_step_stats.py`, because the global rules say anything executable goes in the repo's `tools/`/`scripts/`, never `/tmp`. `tools/release_candidate.py` freezes every file under `tests`, `tools`, `scripts` (FROZEN_DIRS), and an ADDED file there is drift exactly like an edited one: it sets the candidate INVALID at the next check. The Edit/Write freeze hook did not stop it (the agent's write was a new file).

**`release_candidate.py frozen <path>` does not catch it:** it answers 0 only for a path already in the manifest's file list (or non-mutable `data/`); a new file returns 1 ("not frozen") although adding it is drift.

**How to apply:**
- While a candidate is RUNNING, every delegated prompt that might produce a script must say: write no file under `tests/`, `tools/`, `scripts/`, `packaging/` or `run.sh`; put any helper you need under the session scratchpad (or `tests/evidence/`, which is MUTABLE), and say where it is.
- If one slips in, move it out of the frozen dirs at once (before any orchestrator step or `check`), keep it in the scratchpad, and land it under `scripts/` right after the attempt is abandoned.
- After any agent returns, check its report for "I wrote ... new file" before trusting the tree is unchanged.
