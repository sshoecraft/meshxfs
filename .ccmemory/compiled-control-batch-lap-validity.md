---
name: compiled-control-batch-lap-validity
description: Control/verification batches: force the trigger every lap, declare 10 laps (10+6 beats 20+4); an Edit mid-batch swaps script text between laps
metadata:
  type: feedback
tags: [compiled, control-batch, verification-batch, harness, rig-lanes, edit-tool]
---

Assorted group: two notes the clusterer could not fit to a larger topic. They share one question, whether a lap of a control or verification batch is a valid trial. The first decides whether each lap is exposed to the trigger and how many laps to declare; the second decides whether every lap runs the same script text when the Edit tool changes a harness file during the batch.

## What a FIXED AND VERIFIED removal needs

- A control batch (fix out, k failures of n) and a verification batch on the frozen candidate, sized from the control. Sizing rule from docs/release-process.md: N = ceil(ln 0.005 / ln(1 - L)), L = 0.005^(1/n) when every control lap failed. `technique-control-lap-make-the-trigger-certain-and-size-10-laps`

## Make the trigger certain, so every control lap fails and every lap is exposed

`technique-control-lap-make-the-trigger-certain-and-size-10-laps`

- A random input: bind a file of fixed bytes over `/dev/urandom` in a private mount namespace: `sudo -n unshare -m sh -c 'mount --bind "$1" /dev/urandom && exec ...'`. `tests/fsx_seed_lap.sh` makes fsx.sh's seed draw 4294967295 every lap; `tests/mkfs_layout_identity.py` fixes mkfs's uuid the same way.
- An abort at a chosen point: the capture gate's `MXFS_FAULT_RSX_NTH=1` fails a harness's first measurement. `tests/recov_bmbt_reuse_abort_lap.sh` runs the gate with a one-entry manifest of its own, so the injected abort lands after the victim's destroy.
- A state the defect needs: put it there in the lap itself. `tests/lun_pool_shutdown_lap.sh` deletes the node records while the nodes are up, then reboots them, so each boot is recordless.
- A trigger that is only likely (a hash-placed master, a random draw left random) makes laps unexposed, and an unexposed PASS is not a trial.

## Sizing the laps

`technique-control-lap-make-the-trigger-certain-and-size-10-laps` With every lap failing:

- 10-lap control: 6 clean verification laps (L = 0.589), 16 laps in all.
- 20-lap control: 4 clean laps (L = 0.767), 24 in all.
- 8-lap control: 8 clean laps, 16 in all.
- 10+6 laps beat 20+4. Declare 10 for a lap that costs minutes; 20 only when laps are seconds long.

## Precheck before declaring

`technique-control-lap-make-the-trigger-certain-and-size-10-laps`

- Run `tools/control_precheck.sh <fix.diff> -- <lap>`: it must pass with the fix in and fail with it out. It reverts with `patch`, which also replaces the file (see the Edit section below for what that does to a lane in flight).
- A fix diff for a fix already in the tree can be rebuilt from a sibling checkout that predates it (/home/steve/src/mxfs-b ... mxfs-g, mxfs-v130), never from git history.

## Editing a harness file while a lane runs: Edit replaces the file by rename

`edit-tool-replaces-file-by-rename-running-bash-keeps-old-copy`

- Measured 2026-10-22: a scratch file's inode was 117179546 before an `Edit` and 117179532 after it. The Edit tool writes a new file and renames it over the old one; it does not rewrite the file in place.
- A bash script already running (a `run.sh` prep, a capture gate lap) holds the old inode open on fd 255 and goes on reading the old text. An Edit to `run.sh` or `tests/capture_fault_gate.sh` while a lane is mid-step does NOT corrupt that step, unlike an in-place write (`sed -i` without a rename, `>` redirection, `cat >>`), where bash's incremental reader can land at a shifted offset.
- Every NEW invocation reads the edited file. A control or verification batch whose laps each start the edited script switches code between laps: lap 1 ran the old text, lap 2 runs the new. If the edit touches what the batch measures, the batch is mixed; wait for the lane, or put the change in after it.
- `tools/harness_batch.py --revert` and `tools/control_precheck.sh` revert with `patch`, which also replaces the file. The same split applies: a process already running keeps the old copy, each new invocation reads the reverted one.
- How to apply: before editing a file a lane is running, ask whether the lane's NEXT invocation must see the old or the new text, not whether the running one will break. To check which processes are mid-run: `ps -o pid,lstart,args -C run.sh` (exact comm, safe on clyde); `ls -l /proc/<pid>/fd/255` shows "(deleted)" when that process runs a replaced copy.
