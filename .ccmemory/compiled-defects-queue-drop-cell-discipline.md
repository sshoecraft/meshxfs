---
name: compiled-defects-queue-drop-cell-discipline
description: defects.py --drop-cell: a run that failed on two causes stays a cell of both records; move the other failure's account, never drop the cell
metadata:
  type: feedback
tags: [compiled, defects-queue, defects-py, drop-cell, release-gate, presteps, reviewer]
---

Assorted tail: a one-note group the clusterer could not fit to a larger topic. The note is a single lesson about `tools/defects.py` queue bookkeeping: when `--drop-cell` may remove a run from a record, and what to do instead when the run failed for more than one cause. Source: `trap-drop-cell-on-a-run-with-two-causes`.

## Failure mode

A presteps run can fail on several independent causes at once. Worked example, run `1/any:release:presteps:2026-10-21T21:43:30Z` (`trap-drop-cell-on-a-run-with-two-causes`):
- contract 11b FAIL, and a 13b ABORT, both from the contract's own NAA-only forms; AND
- four capture-gate aborts, "no MXFS device basis", from `tests/lib/rig.sh`'s EUI-64 normaliser.

## Rule

When a reviewer says a record "still holds" a failure its fix does not cover, the fix is to move THAT failure's account to the record that owns it: `update --cell` on the owning record, and rescope the first record's evidence to what it claims. Not `--drop-cell` of the run from the first record.

`--drop-why` must be "the run's own evidence that this record's cause did not fail it". Writing "the run fails the same way without this cause" for a run whose other failures ARE this cause is a false statement in the queue, and the next reviewer will find it. Session of 2026-10-23: the cell was dropped, then re-added with a correction note (`trap-drop-cell-on-a-run-with-two-causes`).

## How to apply

- Before `--drop-cell`, list every failure line in the run's own log and assign each to a record. Drop only when none of them is this record's cause.
- A run with failures from two records stays a cell of both; each record's removal argument says which of the run's failures it claims.
- Splitting a reviewer-flagged hunk into its own record with its own switch lets the original record's removal go ahead on the batches it already has. Done for the board-verdict empty-verdict refusal, and for the contract's 11b/13b/13h checks (`trap-drop-cell-on-a-run-with-two-causes`).
