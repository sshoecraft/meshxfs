---
name: compiled-lap-batch-traps-control-probe-and-vm-reaper
description: Lap-batch traps - control probe must match the defect trigger, not the pass marker; vm_pool reaper powers off unheld nodes 600 s after run.sh exits
metadata:
  type: feedback
tags: [compiled, batches, control, probe, exposure, harness_batch, rig, vm_pool, reaper, batch_lap, lanes, power-off]
---

Assorted group, no single topic: two traps in the rig's lap batches (`tools/defects.py` controls, `tools/harness_batch.py` -> `tools/batch_lap.py` laps). In both, the batch finishes and its numbers say nothing about the defect under test.

## A control's probe must be the defect's trigger, not the success marker

Folded from `trap-control-probe-that-only-passing-laps-print-measures-zero-of-one`.

What the code does: `tools/defects.py` `exposed()` (around :884). When a batch has a probe, a FAIL lap counts toward the rate only if its `exposure=` count is above 0. `docs/release-process.md` still says "a FAIL counts as exposed". The code is what decides.

What happened (bitten 2026-10-22/23):
- Control `b20261022-172c3f` of `D-JOIN-DURING-TAKEOVER-GATE-PASS-ENDS-BEFORE-ITS-IN-FLIGHT-SAMPLE` used the probe `^GATE join_during_takeover fault: .*fault_line=1`. Only a lap that reached the injection prints that line.
- With the fix out, 9 of 10 laps overran the gate's 228 s bound before ever reaching the injection, so they never printed the probe (exposure 0) and their FAILs were not counted. A probe only passing laps print made a 9-of-10-failing control measure "0 of 1 exposed laps". That bounds nothing, so the verification could not be sized.
- A rerun probed the harness's own trigger line, `INFO A.s lone remount: A_MOUNT_RC=0` (read with `--evidence` from the gate's evidence dir). It counted on both outcomes.

Apply:
- Pick a control's probe from the defect's TRIGGER: a line both a failing and a passing lap print once they have reached the triggering condition. Never pick the success path's own marker.
- Before declaring the batch, run the precheck's fail lap and check that the probe matches its output. If the line lives in a file the lap writes, add `--evidence <glob>`.
- Board rows (`--board`): `run.sh` counts the probe in each node's dmesg since the lap began. A row that logs nothing to the kernel needs a `/dev/kmsg` mark first. Examples: `fourkn_cdb` marks before its FUA write; `fourkn_merge` writes its counts.

## run.sh's VM-pool reaper powers off unheld nodes 600 s after run.sh exits

Folded from `trap-run-sh-vm-pool-reaper-powers-off-unheld-nodes-600s-after-it-exits`.

Mechanism:
- Every `run.sh` starts `( setsid tools/vm_pool.sh release --after $$ <its nodes> )` (`run.sh:378`).
- Once that `run.sh` exits, the reaper polls `sudo virsh domstate` every 30 s. If a node stays unheld for the whole grace (600 s), it runs `scripts/lab_power.sh down` on it (`tools/vm_pool.sh:107-122`). It shuts off every node nobody holds, mid-lap.
- "Held" means one of: `run.sh`'s node lock `/tmp/mxfs_node.<vm>.lock`; a vmhold `/tmp/mxfs_vmhold.<vm>.lock` (any flock, shared is enough); the whole-rig run lock.

What happened (bitten 2026-10-23, session 16 of run 9aa0fe9b):
- A lane formed g2 with `run.sh prep_cluster` (ended 00:56:02Z), then ran harness laps through `tools/harness_batch.py` -> `tools/batch_lap.py`, which held nothing.
- At 01:06:05Z, 600 s later, test1/test2 got an ACPI poweroff in the middle of lap 4. Laps 5-10 ended INCOMPLETE ("srcversion != tree ()").

Signature:
- no `sudo virsh shutdown` in the journal (`lab_power.sh` calls virsh without sudo);
- `sudo virsh domstate <vm>` every 30 s for exactly 600 s, then nothing;
- qemu log `terminating on signal 15 from pid <libvirtd>` / `reason=shutdown`;
- a clean systemd poweroff on the serial console.

Apply:
- `tools/batch_lap.py` now holds the VMs named by `MXFS_NODE_LIST` and `MXFS_GROUP` for each lap (`MXFS_BATCH_LAP_HOLD=0` is the control). EXPORT one of those two in any lane that runs batch laps.
- Any other rig work that is not under `run.sh` holds no VM: a lane step running a lap script directly, an ad-hoc ssh probe, a soak. Wrap it in `flock -s /tmp/mxfs_vmhold.<vm>.lock <cmd>`, or source `tests/lib/runlock.sh` and call `vmhold_take`.
- When nodes "power themselves off", check this reaper before suspecting the guard or another session.
