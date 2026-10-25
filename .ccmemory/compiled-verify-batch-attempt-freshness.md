---
name: compiled-verify-batch-attempt-freshness
description: Assorted defects.py/rig-lane gates: verify batch freshness vs freeze, remove --fixed prerequisites and reviewer checks, lap design, lane queue and bo…
metadata:
  type: feedback
tags: [compiled, defects, verify, release-candidate, tools, release-gate, release-reviewer, lap-design, rig_lane, lanes, harness_batch, trap]
---

Assorted group (merged articles sharing no single topic beyond the release-gate and rig-lane tooling): (1) when a defects.py verification batch can still be applied; (2) how `tools/defects.py remove --fixed` is gated and what to check before dispatching release-reviewer; (3) lap design (one directory per worker); (4) lane queue files under tests/evidence/lanes/ and `harness_batch.py --board` prep. Absorbed articles: `compiled-defects-remove-fixed-prerequisites` (sections 2-3, 5-7 and lap design 3, lane queue label 4a) and `compiled-rig-lane-queue-copy-trap` (sections 4b-4c). Source slugs they themselves cited are kept below as plain slugs.

# 1. Verify batch freshness vs freeze

- A verification batch can only be applied (`propose verify`) while the attempt its laps ran on is current; after a re-freeze it is dead. `verify-batch-must-be-applied-on-the-attempt-it-ran`
- `tools/defects.py` `unplanned_variant` (:994-996) treats any lap stamped before the candidate's current attempt began (`criteria.attempt_began`) as run on another tree. So a `verify` proposal for a batch whose laps ran on an earlier attempt of the same version is rejected. Case: review P20261024-b148a3 rejected b20261023-756620 (6 of 6 PASS on attempt 2026-10-23T20:41:09Z), proposed after seven later freezes. `verify-batch-must-be-applied-on-the-attempt-it-ran`
- Laps that ran after their attempt was marked INVALID (drift) also do not count, even before the next freeze. `verify-batch-must-be-applied-on-the-attempt-it-ran`
- An APPLIED verify (batch state `passed`) is not re-checked against the attempt at `remove --fixed` (cmd_remove only checks kind/state and the control link), so applied verifies survive later freezes. `verify-batch-must-be-applied-on-the-attempt-it-ran`
- How to apply: before `tools/release_candidate.py create` freezes a new attempt, propose and get reviewed a `verify` for every verification batch that passed on the current attempt. Never leave a passed batch unapplied across a freeze, or it must be rerun (and its control re-shown on the new build via a fresh control or a checkable `--transfer`). `verify-batch-must-be-applied-on-the-attempt-it-ran`

# 2. Defect-queue workflow: gates and checks before release-reviewer (`compiled-defects-remove-fixed-prerequisites`)

Source of this section: `remove-fixed-needs-reproducer-and-approved-verify-first`. Each review costs about 340K tokens, the same whether it approves or rejects, so the check is cheaper than the rejection (`compiled-verify-and-removal-review-cell-coverage`).

## 2a. remove --fixed needs a reproducer and an applied verify

`tools/defects.py remove <id> --fixed --control C --fixon F --approval P` refused even after the release-reviewer approved the remove-fixed proposal (P20261024-f84fc6, 2026-10-24), for two reasons:

- `no reproducer: name the test that reaches the cause (update --reproducer)`
- `<fixon> is not a verification batch that passed (defects.py verify)`

`defects.py verify <id> --batch F --approval P` then refused: `proposal P... is for remove-fixed, not verify`. The removal applies only after a verify proposal (`propose verify --record --batch --at --argument --evidence`) has been reviewed in its own right.

How to apply: before dispatching the reviewer for a removal, (1) run `update <id> --reproducer "..."`, then (2) file both `propose verify` for the fix-on batch and `propose remove-fixed`, and send both proposal ids to ONE release-reviewer call. That saves a review round trip. (Caveat from 2b: the reproducer/verify pair filed together can go to one reviewer call, but the removal can only be applied after the verify has been applied.)

## 2b. Order: verify first, then remove, and where the verify lap runs

`compiled-defect-removal-verify-order-and-lap-location` (source `removal-needs-applied-verify-and-a-lap-where-the-defect-lives`): four `remove --fixed` proposals were rejected in one sitting (2026-10-23, P20261023-9b6f3f, -1bcf31, -b32dc8, -7bd24f).

Order:
- `tools/defects.py remove --fixed` refuses unless the fix-on batch is `passed` (defects.py:1752).
- Only an approved, applied `verify` sets `passed`: `propose verify` -> release-reviewer -> `defects.py verify --batch B --approval P`.
- A `harness_batch.py verify` run leaves the batch `open`; it does not set `passed`.
- So file the verify proposal FIRST, apply it, then file the removal. Filing both at once wastes a review.
- Also check the record has a `reproducer` field (defects.py:1736 refuses without one).

Where the lap runs:
- A harness defect whose failure happens on a rig node is not proven by a host-only lap. Examples: fsx files moved off an mxfs mount to /root; a rejoined victim's loaded module parameters.
- A host-only lap that runs on /dev/shm, or records the argv a node's shell would get, is rejected by the reviewer: the fix never ran on the path the defect lives on (cross-filesystem copy, CAW vs TCP branch, real module load).
- Design the lap to run on the node, on the configuration the failures were seen on.
- File its ledger rows at the configuration it actually ran. A lap that ran MXFS_CONFIG=8/net/mesh/mpath but recorded 2/net/mesh/direct was also cited.
- Host-only laps are fine for defects that live on the host (tools/*.py, criteria/defects logic).

## 2c. Stale pending proposals

Source note `pending-proposal-may-be-stale-read-record-next-first` (article `compiled-pending-proposal-staleness-before-review`).

A proposal left `pending` by an earlier session is not necessarily ready for review. Two verify proposals (P20261023-0344fd, P20261023-495519) sat pending while their records' `next` fields had since been updated after rejected removals, saying the very laps those verifies rest on measured nothing at the configuration (host-only laps, no VM, wrong MXFS_CONFIG). Both release-reviewer runs came back REJECT, two agent runs spent for nothing.

**Why:** the reviewer checks the record's own `next`, and a rejection's findings are written there first; a proposal drafted before it does not know.

**How to apply:** before dispatching release-reviewer on a pending proposal, read the last `=====` section of the record's `next` (and any `data/reviews/` file newer than the proposal). If it says the proposal's batch or lap is unfit, do not send it; rework the lap first. `tools/release_blockers.py --pending` lists the pending ones; `tools/defects.py show <id>` gives the `next`.

## 2d. A verify retires every cell the record names

`compiled-verify-and-removal-review-cell-coverage` (source `verify-proposal-retires-every-cell-at-its-configuration`).

- Applying a verify (`tools/defects.py verify`) calls `retire_cells` for every run the record names at the batch's configuration (tools/defects.py:1292-1295), and the release process counts that as a reviewed disposition. So the release-reviewer checks every such cell, not just the batch.
- Evidence: P20261023-b45350 (open-EFI verify, 2026-10-23) met all five verify checks and was still REJECTED. One cell, a control lap at 2/net/mesh/direct, was a FAIL "elapsed>360s: the harness overran its bound" after a 207 s pair rebuild. Nothing tied that to the defect, so approving would have marked an unexplained timeout as verified. The fix was a record of its own naming that run, then resubmitting the same batch (nothing re-run). Cost: one ~340K-token review.
- Before proposing a verify or a removal, list every cell of the record from data/criteria.runs.jsonl: outcome, reason, measured.
- Any cell whose reason is not this record's cause (bound overrun, stall, mount timeout, another check) first goes to a record of its own (`defects.py add --cell`), or its log must prove this cause.
- A removal's scope is every configuration the record reaches. A record left at its fail-closed default (1/any) needs runs at each lock manager, attachment and node count it claims, or a reviewed narrowing first. Code reading does not count (P20261023-2ed8d3 rejected the last-member-unmount removal for this).

## 2e. remove-fixed rejection checklist

`compiled-remove-fixed-proposal-review-checklist` (source `removal-proposal-must-cover-every-cell-and-fix-site`): read from 13 rejected reviews (`data/reviews/P2026102{2,3}-*.md`, 2026-10-23 sweep). Check every item or the proposal comes back REJECT.

Every cell is retired as `fixed`:
- Each run in the record's `cells` must show THIS cause in its own log.
- A cell whose log shows another failure (a stall, a mount timeout, a different contract check) must first move to the record that owns it, or to a new one. Rejected for this: D-RELEASE-RUN-BOARD-VERDICT's `release:drbd` cell; D-8NETMESH-FALSE-FRESH's 75 s stall + rejoin timeout; D-PRESTEPS' three presteps runs.

Every fix site/hunk is exercised:
- A record holding several sites needs control+verify per site, or a split into records of their own first. Multi-site records seen: LUN pool (single-path, multipath and `--also` logins); EUI64 (rig.sh hunks plus contract 11b and 13j); BOARD-VERDICT (plus a `check_cells` fix).
- The summary text becomes the CHANGELOG line and may state only what was proven.

The control:
- Control = the candidate's source with only the fix reverted, hash-proven. Two accepted forms: in place immediately before a fresh freeze (nothing written in between; `harness_batch.py proof`), or in a copy of the frozen file list.
- A control on a dev tree fails. A control with any lap input changed after it fails.
- A knob control must restore the pre-fix behaviour exactly. `FORCE_MS=0` left the fix's unheld workload in place, so it was rejected.
- The control must reproduce the record's failure with evidence in each failing lap. Laps killed by a bound (rc=124) with no abort/activation line are not the failure.

Exposure and per-op grading:
- Product (kernel/dlm) records need exposure at the configuration cleared, on the candidate's module (board-row laps, kernel-log probe). In-process tauth simulations are supporting evidence only, unless a `--transfer` is accepted.
- Every op in a lap is graded against `stall_limit_s`. A 31 s last-member unmount inside a PASS lap failed the verify.

Ordering: a verify batch must be applied (`defects.py verify` with its own approved proposal) before a removal can use it.

## 2f. The record summary is what gets published

`compiled-defects-removal-changelog-summary-narrowing` (source `trap-removal-changelog-prints-the-record-summary-so-narrow-it-before-proposing`).

- A `tools/defects.py remove --fixed` prints its CHANGELOG entry as the record's **summary** in bold plus `--why` (tools/defects.py:1773); the approved `--cause` is not printed. The release-reviewer therefore rejects a removal whose record summary claims anything the control and fix-on laps did not observe, even when `--cause` and `--argument` were trimmed to the measurement.
- Seen 2026-10-23 (session 900576df's successor): the fsx `/tmp` log record was rejected twice (P20261023-564a5c, P20261023-0a53fb) until `defects.py update -m` replaced the summary with the measured claim; P20261023-44869d then passed with the same batches and nothing re-run. A drafting agent then found five of seven tooling records with over-claiming summaries; each needed the same narrowing.
- Before proposing any removal, read the record's summary next to the control's FAIL lines; if it names a mechanism, a consequence or a scope the laps did not show, `update -m` it to the measured claim first.
- If a failure the summary describes is not what the control reproduced (e.g. the jdt 31 s unmount that prints `ms=` and reaches no grader), open a separate record for it before narrowing, so nothing observed leaves the queue silently.
- The `--why` given at `remove` time is not reviewed but is published: keep it to the measured numbers.
- A removal also needs `--reproducer` set on the record (`update --reproducer`), or `remove` refuses.

## 2g. Old incidents may already be named by a CHANGELOG removal

`compiled-incidents-already-named-by-changelog-removals` (source `trap-old-incidents-may-already-be-named-by-a-removal-grep-changelog-for-the-stamp-first`).

Why an old incident looks unexplained:
- `tools/criteria.py incidents` lists runs that no open record names and no annotation settles.
- A removal (`defects.py remove`) writes `retired_by` only for runs that are already in a run ledger at that moment. For any other run `retire_cells` prints "not in the run ledger; nothing to retire".
- The boards moved into run ledgers on 2026-10-21 (`migrated: 2026-10-21` on the ledger line, `build: null`), after many removals had already happened. Runs those removals named in `CHANGELOG.md` therefore arrived unretired and look like unexplained failures.

The miss: session 9123eb8f's sweep (evidence file `tests/evidence/incident_preassert_sweep_20261022T2355Z.txt`):
- Groups f and g (8/disk/caw, 2026-10-19 19:15-19:17Z) were reported as "never reached the ledger, no open record covers them" and queued for new records. `CHANGELOG.md`'s removal of D-RIG-SCST-RECONFIG-SUSPENDS-EVERY-LUN-BEHIND-A-FROZEN-GUESTS-COMMAND (the lab's 49 s SCST suspend) names every one of those runs by config, row and stamp.
- Group b (2/net/mesh/mpath 2026-10-20) was likewise named by the removals of D-TCP-CAPACITY-WAIT-NEVER-ENDS-HANGS-JOIN-FREEZE and D-FAILED-MOUNT-UNWIND-RACES-REAP-WORKER-FREES-AG-AND-HANGS.
- Cost avoided: new records there would have re-opened fixed defects.

Apply:
1. Before recording an old incident, `grep -n '<ISO stamp>' CHANGELOG.md`. A hit inside a paragraph headed `**Removed from the queue, fixed and verified|disproved: <ID>.**` means the run is accounted for.
2. Settle it with `tools/defects.py propose retire --record <removed ID> --run CONFIG:ROW:ISO ... --argument ... --evidence CHANGELOG.md ...`, have the release-reviewer approve it, then `tools/defects.py retire <ID> --approval <P>`. The tool refuses a record still in the queue, a run already settled, and a run the paragraph does not name by configuration, row and stamp.
3. What does not match: a paragraph in the older format ("D-X is removed from the defect queue", e.g. the 0.90.124 D-DIR-RELOAD-CHILD-INACTIVATION-DEADLOCK entry), and an entry that names the failing row but not its PRE-ASSERT collateral (it does not retire the collateral).
4. The release-reviewer's definition is registered at session start, so a decision kind added mid-session must be spelled out in the reviewer's prompt.

# 3. Lap design: one directory per worker (`compiled-defects-remove-fixed-prerequisites`)

Source: `trap-one-shared-directory-serializes-a-nodes-inode-lock-race-workload` (article `compiled-race-lap-design-per-worker-directories`).

What bit:
- A lap meant to make the cached-AG yield scan (run before every slow-path inode DLM acquire) overlap on one node ran 8 create/unlink workers per node in ONE shared directory: 0 overlaps in 4280 pairs.
- Cause: VFS takes the parent directory's i_rwsem exclusive for create and unlink, so a node's workers queue on it and only one inode-lock acquire per node is ever in flight.
- Context: defect D-YIELD-SCAN-SAVE-RESTORE-OF-AG-BAST-STALL-ITERS-RACES-AND-STICKS-AT-200; prechecks in tests/evidence/lanes/g2_pre_attempt15*_20261024*.

Second trap:
- With a directory per worker index (worker w of both nodes in dir w), scans overlapped once per node in ~2300, and no scan drained inline: an MXFS hot-path scan with nothing to do lasts microseconds, so a save-restore race window stays closed under a natural workload.
- A test-only hold inside the scan (dbg_yield_scan_hold_us, written at runtime on both arms) gave ~720 overlaps per node, and the old code stuck on both nodes.

How to apply:
- For node-local concurrency in a lap, give each worker its own directory; share the directory across nodes, not across a node's workers.
- Count what the lap means to trigger (a counter of calls and of overlaps) before reading a zero result as "fixed".
- A hold that widens a window goes on both arms alike, at runtime (not in the prep's module arguments, which make the lap a variant tools/batch_lap.py refuses to count toward a verification), and is declared in the lap header and the proposal.

# 4. Rig lane queues and board laps

## 4a. Lane queue label reuse overwrites evidence (`compiled-defects-remove-fixed-prerequisites`)

Source article `compiled-lane-queue-label-reuse-overwrites-evidence` (raw note `trap-lane-queue-label-reused-overwrites-an-earlier-attempts-queue-file`).

- Lane queues live at `tests/evidence/lanes/queue_<group>_<label>.txt`. The label (a14, a15, a16, a17, w12, ...) is chosen by each session; nothing reserves it.
- Failure: session 66 (2026-10-24) wrote new queues as `queue_g2_a16.txt` and `queue_host_a16.txt` with Python `open('w')`. Both names already belonged to lanes an earlier session ran (`g2_a16_20261024T010135Z`, `host_a16_20261024T010132Z`). The writes silently replaced committed evidence.
- Recovery: `rig_lane.sh` copies its queue into the lane's own directory at start (`tests/evidence/lanes/<lane>_<stamp>/queue`). The originals were copied back from there and the new queues renamed to an unused label.
- How to apply:
  - Before writing a queue file, `ls tests/evidence/lanes/ | grep _<label>` and pick a label with no queue file and no lane directory.
  - Never write a queue with `open('w')` or `>` to a name you have not checked; the Write tool refuses an unread existing file, which is the safer path.
  - If one is overwritten, its lane directory's `queue` file is the copy that ran.

## 4b. Editing a lane queue file does not change a running lane (`compiled-rig-lane-queue-copy-trap`)

Source `trap-editing-a-lane-queue-file-does-not-change-a-running-lane`.

- A session rewrote a pending verify line in `tests/evidence/lanes/queue_g8b_w12b.txt` (adding `HOLD_A_MS=4000`) while the lane was on step 1, and concluded "the verification line changed before step 2 started".
- `scripts/rig_lane.sh:55` copies the queue into the lane directory at start (`cp "$QUEUE" "$OUT/queue"`) and reads only that copy (`:101 done < "$OUT/queue"`). The verification ran with the old line, `HOLD_A_MS` at its default 8000.
- The next session wrote the verify proposal from the edited original and cited `HOLD_A_MS=4000`. The release-reviewer read the lap logs (`hold_a_ms=8000`) and rejected it (P20261024-0801cb, one review spent).

How to apply:
- A running lane's commands are in `tests/evidence/lanes/<lane>_<stamp>/queue`, never the queue file it was started from. Cite that copy, and read each lap log's own header for the parameters that ran, before writing a proposal.
- To change a step that has not run yet, stop the lane at a step boundary and start a new lane with a new label; an in-place edit of the original has no effect.

## 4c. Board batch on a new module needs a prep step in the lane queue (`compiled-rig-lane-queue-copy-trap`)

Article `compiled-harness-batch-board-lane-prep`, source note `trap-board-batch-on-a-new-module-needs-a-prep-step-in-the-lane-queue`.

Mechanism: `tools/harness_batch.py control|verify ... --board` runs each lap as `MXFS_BATCH=<b> ./run.sh <config> <row>`, a filtered row. A filtered row refuses an unprepped group ("Run './run.sh <config> prep_cluster' first"). harness_batch then stops with "the lap recorded nothing (refused?); stopping", and the verify that follows dies on "no measured rate".

Two ways it bit (2026-10-24, session 67, path_mount_degraded controls, module BE3695D2590A65F742F9816):
1. New module. queue_g2b_w12's control b20261024-544904 at 2/disk/caw/mpath recorded nothing in 21 s, right after a fresh `make modules` + freeze. The queue had been written when the group was prepped on the old module.
2. A failing lap leaves the group down. g4c_w12's control b20261024-239fb6 at 4/disk/caw/mpath ran 3 FAIL laps (late_stall_ms 35-42 s), then lap 4 was refused. A failing path row leaves the victim unmounted, and a board lap never re-forms the group. Every control of a defect that fails a node-killing row hits this after its first exposed lap.

How to apply:
- Before a `--board` control, put `MXFS_EXTRA_MODARGS=<arm's args> MXFS_FORCE_PREP=1 ./run.sh <config> --group <g> prep_cluster`. Before the `--board` verify, put a plain prep, so the marker matches what each arm loads.
- For a control whose laps fail on a row that takes a node down, choose one of:
  - declare the batch yourself with `tools/defects.py batch <id> --kind control ... --leaves-cluster`, so run.sh re-forms the group before every lap, then drive it with `harness_batch.py control --batch <b> --board`;
  - or alternate a prep with `harness_batch.py control --batch <b> --board` (it continues the declared batch until a lap is refused). queue_g4c_w12b.txt and queue_g2b_w12c.txt do this.
- Lane queue files (tests/evidence/lanes/queue_*.txt) are not in the candidate's frozen list, so a queue that has not started can be fixed after a freeze. Never edit a running lane's queue: rig_lane.sh runs its own copy (see 4b).
- A follow-on lane on the same configuration cannot start until the first lane exits, because rig_lane.sh holds each configuration it names for its whole life. Two lanes on overlapping node groups (g4c test7-10 vs g8 test7-14) are not caught by that hold: order them with scripts/lane_after.sh.
