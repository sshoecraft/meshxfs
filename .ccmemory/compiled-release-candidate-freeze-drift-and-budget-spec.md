---
name: compiled-release-candidate-freeze-drift-and-budget-spec
description: Frozen release candidate: a NEW file in tests/ tools/ scripts/ is drift (INVALID); a row budget lives in manifest AND criteria.json budget_s
metadata:
  type: feedback
tags: [compiled, release-candidate, drift, freeze, budget, criteria, manifest, trap]
---

Assorted tail group (one note the clusterer could not fit to a topic), organised by what it holds: the two things a frozen release candidate (`tools/release_candidate.py`) covers that are easy to miss, and that make it INVALID or mis-grade it. Source: `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget`.

## 1. Adding a file is drift, not only editing one

- `drift()` reports `added: <path>` for any file that joined the frozen set after the freeze. `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget`
- The frozen set is every file under `xfs/ dlm/ pal/ mxfs_clayer/ include/ compat/ tests/ tools/ scripts/ packaging/ frontend/proxmox/ docs/man/`, minus the MUTABLE patterns (`tests/evidence/*`, `*.o`, `__pycache__`, ...), plus `data/` except `criteria.json`, `*.runs.jsonl`, `defects.json`, `proposals.json`, `candidates/`, `reviews/`. `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget`
- Consequence: while a candidate is RUNNING, a new helper script or lap in `tests/` or `tools/` makes it INVALID. `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget`
- Do: write one-off helpers inline (a heredoc in the Bash call) or under `tests/evidence/`; put new laps and tools in the tree only before the freeze. `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget`
- `docs/` (except `docs/man`) is not frozen, so design docs can be written during a run. `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget`

## 2. A board row's budget lives in two places

- `run.sh` enforces the BUDGET_S column of `tests/suite/manifest`. `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget`
- The board's own spec, `budget_s` in `data/criteria.json` (`tools/criteria.py` `budget_of`), is what a lap line prints (`(33s/60s)`) and what grades; it is part of the candidate's frozen spec projection. (`criteria.json` is excluded from the frozen file set in section 1, yet the `budget_s` spec is frozen through the spec projection.) `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget`
- Failure seen: session 19 (run 9aa0fe9b) changed fourkn_merge's manifest budget 60 -> 55 and froze; the laps still showed 60. `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget`
- Do: change both together, before freezing, and check a lap's printed budget. `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget`
