---
name: compiled-revert-control-pre-fix-source-and-per-part-switches
description: Revert controls for the release gate: pre-fix source from sibling checkouts (mxfs-v130) when no diff was saved; one switch per fix part (0.90.134)
metadata:
  type: feedback
tags: [compiled, release-gate, revert-control, technique, defects-queue, fix-switch]
---

Assorted-tail group of one note. Its two techniques share one topic: building revert controls (`--revert` controls, fix-out lanes, switched fix parts) for the release gate. Learned in 0.90.134, 2026-10-23. `technique-pre-fix-source-from-sibling-checkouts-and-one-switch-per-part`

## 1. A fix whose diff was never saved: read the old form from a sibling checkout

- A `--revert` control needs "the candidate's source with only the fix reverted", but `git show`/`git log` are not allowed without the owner's direction, and `tests/evidence/controls/` held no diff for the fsx.sh EXIT-trap fix (D-FSX-SH-SENT-FSX-OUTPUT-TO-A-TMP-LOG-ITS-EXIT-TRAP-DELETED). `technique-pre-fix-source-from-sibling-checkouts-and-one-switch-per-part`
- The host keeps older checkouts beside the tree: `/home/steve/src/mxfs-{b,c,d0349,dev,e,f,g,ledger,v130,wt-*}` (also under `/src`). Compare the file across them with `stat -c %y` and `sha256sum`: there, eight copies of `tests/suite/fsx.sh` hashed alike from 2026-06-14 through `mxfs-v130` (0.90.130), the last pre-fix form.
- Build the old side as today's file with ONLY the fix's hunks replaced by the old forms (keep later, unrelated changes, e.g. fsx's `-S "$SEED"`), in the scratchpad: `a/<path>` and `b/<path>`, then `diff -u a/<path> b/<path> > tests/evidence/controls/<record>.fix.diff` and `patch -p1 -R --dry-run` from the tree root. State in the record which checkout and lines the old side came from.
- Precheck with `tools/control_precheck.sh <diff> -- timeout <bound> <lap>`: it reverts, runs, restores and checks the hash. Do not commit while a lane's fix-out step runs (`git status --porcelain` must not show the reverted file).

## 2. One switch over several parts of a fix proves only the first part

- D-RELEASE-RUN-STEP-INCIDENTS-CANNOT-BE-SETTLED had four parts (parse, annotated_run, the command's board choice, run_board) behind one switch. With it off, every disposition was refused at the parse, so the control never reached the other three, and the removal was rejected (`data/reviews/P20261023-463c4c.md`): "Three of the four switched hunks therefore have no measured failure behind them." `technique-pre-fix-source-from-sibling-checkouts-and-one-switch-per-part`
- A part also masks the parts after it in the same command pipeline: with only the routing (run_board) off, `propose --target` failed in check_cells before criteria.py's board choice ran. So that choice needed a switch of its own too (`MXFS_RELEASE_STEP_BOARD`).
- Do: give each part its own switch, run the lap once with each switch off, and confirm in the lap's output that each arm fails at its own code (the refusal text names the site). Then split the record, one per switch, each with its own control and fix-on batch. Evidence: `tests/evidence/release_step_switches_20261023T171448Z` (9, 12, 4 and 4 of 12 refused, one arm per switch).
