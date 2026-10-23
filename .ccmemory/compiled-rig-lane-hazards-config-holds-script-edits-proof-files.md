---
name: compiled-rig-lane-hazards-config-holds-script-edits-proof-files
description: Assorted tail (one note): rig_lane.sh config holds incl. host-only --at, never edit a running lane's script, save proof output to a cited file
metadata:
  type: feedback
tags: [compiled, rig-lane, release-gate, harness]
---

Assorted tail group of one note: three traps in running release-gate batches through `scripts/rig_lane.sh` lanes, seen on attempt 12 of 0.90.134, session 47 of ccloop run 9aa0fe9b. Source: `trap-a-lane-holds-every-configuration-its-queue-names-and-reads-its-script-by-offset`.

## 1. A host-only lane holds the configurations its `--at` names

`scripts/rig_lane.sh` greps its queue for `run.sh <config>` and `--at <config>` and flocks `/tmp/mxfs_lane.<config>.lock` for each one before step 1. A lane that refuses writes `refused: configuration X is held by another lane` and exits 3.

- A local tooling lane (harness laps that touch no node, e.g. `tests/release_step_cell_lap.py` batches with `--at 2/net/mesh/direct`) took 2/net/mesh/direct for its whole 35 minutes. The g2 rig lane started 2 s later, whose EUI-64 contract steps also named 2/net/mesh/direct, was refused outright: none of its steps ran.
- The hold is taken at lane start, before any `scripts/lane_after.sh` step, so lane_after cannot sequence two lanes that name the same configuration.
- Apply: before launching several lanes at once, list each queue's configurations (`grep -oE '(run\.sh|--at)[[:space:]]+[0-9]+/[^[:space:]]+'`) and make them disjoint. Split a rig queue's steps that share a configuration with a host-only lane into their own queue, started after that lane's DONE file exists.

## 2. Never edit a script while a lane is executing it

bash reads a running script incrementally by file offset. An in-place edit (the Edit tool writes in place) that shifts the bytes after the running loop makes the lane run whatever text now sits at its old offset when the loop ends. Wait for every lane's `DONE` before editing `scripts/rig_lane.sh` or any script a lane step is running. A `harness_batch.py control --revert` applies its diff with patch, which replaces the file, so a running bash keeps the old inode; a hand edit does not.

## 3. Cite a proof only from a saved file

`tools/harness_batch.py proof <control> <attempt>.files.json` prints to stdout only. A verify proposal that quoted "proof HOLDS" was approved anyway, but the reviewer re-did all four checks itself and noted the result was in no cited file (data/reviews/P20261023-7ac76d.md). Run it as `... proof <batch> <files.json> > tests/evidence/controls/<batch>.proof.txt` and cite that file.
