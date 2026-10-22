---
name: trap-verification-batches-count-only-on-a-frozen-candidate-controls-may-run-before
description: release-reviewer rejects a verify batch declared with --build: it must carry --candidate and run after the freeze; control batches may run pre-candid…
metadata:
  type: feedback
---

The release-reviewer rejected proposal P20261022-c75127 (verify of D-PACKAGE-INPUT-LIST-NAMES-ABSENT-MXFS-C-NO-PACKAGE-CAN-BE-BUILT, batch b20261022-1666e5, 4 of 4 exposed PASS laps): the batch was declared with `plan-verify --build <srcversion>` and no `--candidate`, and its laps carried no `MXFS_CANDIDATE`. Review: data/reviews/P20261022-c75127.md.

Why it is wrong:
- A verification batch stops a record blocking a configuration *on a candidate* (docs/release-process.md "What a verification clears"). With no candidate it counts for none, and in the development view it would count on any tree with that module, including one with the fix reverted.
- The module srcversion names only the kernel module. A fix in a script or tool (here `scripts/vm_package_build.sh`) leaves it unchanged, so the control (fix out) and the verify (fix in) ran on the same "build".

The reviewer judged the control batch itself sound (k=20 of 20 with the fix reverted by a hashed diff, on the dev tree, no candidate). So:
- Write every fix and run its control batch on the development tree.
- Freeze the candidate (`tools/release_candidate.py create`) only when every fix is in: any later change makes it INVALID.
- Declare each verification batch with `plan-verify --control <batch> --candidate <version>`; run its laps with `MXFS_CANDIDATE` set, after the freeze. `tools/release_run.py`'s `batches` step runs the open verification batches declared for the candidate.
- A verify clears one configuration only. A record that reaches `*/*/*` keeps blocking every other configuration until it is removed (`remove --fixed` needs that passed verify batch).

The same review noted: a lap bound that is the sum of a script's per-step timeouts is not derived from what the lap takes, and a record's `--reproducer` must name a command that exists (`run.sh` has no `lap:` rows; such laps run through `tools/harness_batch.py` / `tools/batch_lap.py`).
