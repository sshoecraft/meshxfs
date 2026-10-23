---
name: compiled-incidents-already-named-by-changelog-removals
description: Old criteria.py incidents may already be named by a CHANGELOG removal that couldn't retire them: grep the ISO stamp, then propose retire
metadata:
  type: feedback
tags: [compiled, criteria, incidents, defects, changelog, retire, release-reviewer]
---

Assorted group of one: the clusterer found no sibling for this note, so the article holds a single trap from the defect-queue / `tools/criteria.py incidents` workflow, organised by cause, the miss, and the procedure.

## Why an old incident looks unexplained

- `tools/criteria.py incidents` lists runs that no open record names and no annotation settles.
- A removal (`defects.py remove`) writes `retired_by` only for runs that are already in a run ledger at that moment. For any other run `retire_cells` prints "not in the run ledger; nothing to retire".
- The boards moved into run ledgers on 2026-10-21 (`migrated: 2026-10-21` on the ledger line, `build: null`), after many removals had already happened (the ledger migration came later than the removals). Runs those removals named in `CHANGELOG.md` therefore arrived unretired and look like unexplained failures.

Source: `trap-old-incidents-may-already-be-named-by-a-removal-grep-changelog-for-the-stamp-first`

## The miss: session 9123eb8f's sweep

Evidence file: `tests/evidence/incident_preassert_sweep_20261022T2355Z.txt`.

- Groups f and g (8/disk/caw, 2026-10-19 19:15-19:17Z) were reported as "never reached the ledger, no open record covers them" and queued for new records. `CHANGELOG.md`'s removal of D-RIG-SCST-RECONFIG-SUSPENDS-EVERY-LUN-BEHIND-A-FROZEN-GUESTS-COMMAND (the lab's 49 s SCST suspend) names every one of those runs by config, row and stamp.
- Group b (2/net/mesh/mpath 2026-10-20) was likewise named by the removals of D-TCP-CAPACITY-WAIT-NEVER-ENDS-HANGS-JOIN-FREEZE and D-FAILED-MOUNT-UNWIND-RACES-REAP-WORKER-FREES-AG-AND-HANGS.
- Cost avoided: new records there would have re-opened fixed defects.

Source: `trap-old-incidents-may-already-be-named-by-a-removal-grep-changelog-for-the-stamp-first`

## Apply

1. Before recording an old incident, `grep -n '<ISO stamp>' CHANGELOG.md`. A hit inside a paragraph headed `**Removed from the queue, fixed and verified|disproved: <ID>.**` means the run is accounted for.
2. Settle it with `tools/defects.py propose retire --record <removed ID> --run CONFIG:ROW:ISO ... --argument ... --evidence CHANGELOG.md ...`, have the release-reviewer approve it, then `tools/defects.py retire <ID> --approval <P>`. The tool refuses a record still in the queue, a run already settled, and a run the paragraph does not name by configuration, row and stamp.
3. What does not match: a paragraph in the older format ("D-X is removed from the defect queue", e.g. the 0.90.124 D-DIR-RELOAD-CHILD-INACTIVATION-DEADLOCK entry), and an entry that names the failing row but not its PRE-ASSERT collateral (it does not retire the collateral).
4. The release-reviewer's definition is registered at session start, so a decision kind added mid-session must be spelled out in the reviewer's prompt.

Source: `trap-old-incidents-may-already-be-named-by-a-removal-grep-changelog-for-the-stamp-first`
