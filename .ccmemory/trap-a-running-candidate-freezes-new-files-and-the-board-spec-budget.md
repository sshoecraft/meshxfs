---
name: trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget
description: While a release candidate is RUNNING, a NEW file under tests/ tools/ scripts/ is drift (INVALID); a row budget lives in the manifest AND criteria.jso…
metadata:
  type: feedback
---

Two things a frozen release candidate (tools/release_candidate.py) covers that are easy to miss:

1. **Adding a file is drift, not only editing one.** `drift()` reports `added: <path>` for any file that joined the frozen set after the freeze. The frozen set is every file under xfs/ dlm/ pal/ mxfs_clayer/ include/ compat/ tests/ tools/ scripts/ packaging/ frontend/proxmox/ docs/man/ (minus MUTABLE patterns: tests/evidence/*, *.o, __pycache__, ...), plus data/ except criteria.json, *.runs.jsonl, defects.json, proposals.json, candidates/, reviews/. So while a candidate is RUNNING, a new helper script or lap in tests/ or tools/ makes it INVALID. Write one-off helpers inline (a heredoc in the Bash call) or under tests/evidence/; put new laps and tools in the tree only before the freeze. docs/ (except docs/man) is not frozen, so design docs can be written during a run.

2. **A board row's budget lives in two places.** `run.sh` enforces the BUDGET_S column of tests/suite/manifest, but the board's own spec, `budget_s` in data/criteria.json (tools/criteria.py budget_of), is what a lap line prints (`(33s/60s)`) and what grades; it is part of the candidate's frozen spec projection. Session 19 (run 9aa0fe9b) changed fourkn_merge's manifest budget 60 -> 55 and froze; the laps still showed 60. Change both together, before freezing, and check a lap's printed budget.
