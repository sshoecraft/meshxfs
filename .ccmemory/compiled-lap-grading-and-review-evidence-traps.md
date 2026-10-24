---
name: compiled-lap-grading-and-review-evidence-traps
description: Assorted lap/batch/review traps: infra-proven evidence, helper rc, drafts run.sh root, ESTALE, kmsg ring, fix-switch scope, argv own-rig, probe, VM r…
metadata:
  type: feedback
tags: [compiled, laps, release-review, kmsg, testing, harness_batch, batch_lap, control, MXFS_OWN_RIG, vm_pool, reaper, trap]
---

Assorted group (the clusterer could not fit these to one topic): lessons about how a lap, a lap batch/control, or a review is graded and where its evidence comes from. Part A (five lessons, session 8815bf68, 2026-10-24) covers single laps and reviews; part B (four traps, from `compiled-batch-control-fix-switch-scoping`) covers lap batches and their controls (`tools/defects.py` controls; `tools/harness_batch.py` -> `tools/batch_lap.py` laps) where the batch finishes, records numbers, and the numbers say nothing about the defect under test.

# Part A: laps and review evidence

## Infra-proven proposals need node dmesg and every lock holder named
`technique-infra-proven-proposal-needs-node-kmsg-window-and-every-lock-holder-named`

The release-reviewer rejects an infra-proven proposal whose "no MXFS signature" rests on a harness log being silent. It also rejects one whose blocking lock's holder is unnamed, because an MXFS unmount stalling under the lock cannot be ruled out. The peer_window lap passed on the second try, the lh_master lap only on the third. For an INCOMPLETE lap, what got them approved:
- Each node's own dmesg ring for the window, pulled after the fact: `dmesg --time-format iso | awk '$1 >= "<start>" && $1 < "<end>"'`. Show the ring reaches back to boot, state the capture command, and show any repeated benign line (e.g. one 'reservation conflict' pair per module load) is the baseline at every load.
- Every holder named down the chain: the pool lock (`run.sh` preflight under `lun_pool.sh quiet`) -> the power-up lock (`lab_power.sh up` of each lane) -> for each holder, the host journal's libvirtd 'Domain id=N name=...' and systemd-machined 'terminated' lines, proving the VMs booted from off.
- Re-run every disposition-critical negative yourself (e.g. no other domain started in the window).
- Lane logs give step windows. lab_power's own 'host power-up lock held' line exists only when the caller keeps its output.

## Lap helper `on()` returns grep's rc, not the remote rc
`trap-lap-on-helper-rc-is-greps-not-the-ssh-commands`

tests/fourkn_merge_2node.sh's `on() { timeout ... ssh ... | grep -avE '^Warning:...'; }` returns grep's status: 1 when the killed client printed nothing, 0 when anything printed. A lap testing `rc=124` on that line could never see an overrun and graded every lap VACUOUS (tests/merge_overrun_lap.sh).
- `fuser -m DIR` on a directory that is no longer a mount point counts every user of the root filesystem (~130), and misses a looping bash worker with no file open at that instant.
- Apply: grade overruns from measured walls against the bound, holds from /proc/mounts plus `ps -C <comm>`. Never trust rc through a pipeline without PIPESTATUS.

## A draft run.sh in the drafts tree becomes the lap tree root
`trap-draft-run-sh-in-drafts-tree-becomes-lap-tree-root`

Draft laps under tests/evidence/drafts/tree/tests/ locate the repo by walking up until a run.sh exists. Copying run.sh into drafts/tree (to draft a run.sh fix) made that the root. Three merge-overrun laps aborted in 8 s (no tools/mxfs_lab.sh there) and wrote evidence under drafts/tree/tests/evidence/.
- Apply: root walks use `while { [ ! -f run.sh ] || [ ! -f tools/mxfs_lab.sh ]; } && [ "$(pwd)" != / ]; do cd ..; done`. Before copying run.sh into drafts/tree, check no draft lap there is running or queued.
- Related lane trap: scripts/lane_after.sh picks `ls -dt lanes/<name>_*`, which also matches `<name>_wait.log`. A wait log newer than the lane dir keeps it waiting.

## The VFS retries ESTALE lookups, hiding xfs_lookup give-ups
`trap-vfs-retries-estale-lookup-so-workload-errors-miss-resolver-giveups`

Linux retries a path walk that returned -ESTALE (LOOKUP_REVAL), so a single xfs_lookup give-up is invisible to userspace. Measured on 4/disk/caw/mpath path_mount_degraded, typeflip_relookup_shell_dead=0: 5 shell-dead give-ups on test7, every pathload op ok (err=0).
- P201-RELOOKUP is mxfs_probe_ratelimited, so pairing give-up lines with relookup lines fails past ~10 per burst.
- Apply: a lap grading a lookup/resolver fix must read a module counter of the outcome (atomic_t + module_param_cb with mxfs_dbg_atomic_param_ops, write resets), not the workload's error count or ratelimited probe lines.

## kmsg_<node>_fromnode.gz holds the ring since boot
`trap-kmsg-fromnode-holds-ring-since-boot-count-after-pf-mark`

The path rows' kernel-log follower (tests/lib/rig.sh ~292-305) starts by dumping the node's whole dmesg ring, so `kmsg_<node>_fromnode.gz` in a `board_*` dir holds every line since boot, including earlier rows on the same boot. A fix-off path_mount_degraded run "showed" 10 `why=shell-dead` relookups that need the fix on; they were byte-identical to the previous fix-on run's lines, from before this run's PF-MARK.
- Apply: `zcat f.gz | sed -n '/PF-MARK/,$p'` before counting any probe per run. Plain `grep -r` also skips the .gz files entirely, so use zgrep/zcat.

# Part B: lap batches and controls

Four traps: a fix switch exported past the lap, an own-rig configuration in a probe's argv, a probe that only passing laps print, and the VM-pool reaper powering off unheld nodes. All from `compiled-batch-control-fix-switch-scoping`.

## B1. Fix switch: scope it to the lap command, never export it

Source: `trap-a-fix-switch-exported-to-a-batch-step-also-switches-the-batch-tools`. Scoping a fix switch when running a control batch through `tools/harness_batch.py` (`compiled-batch-control-fix-switch-scoping`).

When a tooling record's fix sits behind an environment switch and its control runs through `tools/harness_batch.py control ... --knob ... -- <lap>`, put the switch on the lap command only:

    python3 tools/harness_batch.py control R --knob "K=0 (...)" ... -- env K=0 tests/<lap>

never `export K=0` on the lane step before it.

Why: several of these switches also govern the machinery that runs and records the control (found while queuing attempt 2026-10-23T15:56:24Z of 0.90.134, lane tests/evidence/lanes/local_a11_tooling_20261023T155735Z):
- `MXFS_HARNESS_BATCH_REREAD=0` makes tools/harness_batch.py itself keep its stale ledger copy, so the control batch would stop after its first lap exactly as the defect did.
- `MXFS_BATCH_LAP_KILLPG=0` and `MXFS_BATCH_LAP_STALL=0` change how tools/batch_lap.py bounds and grades every lap of the batch, the control's own laps included.
- `MXFS_RELEASE_STEP_SETTLE=0` reverts tools/defects.py parse_cell to the first-two-colons split, which mis-parses every `lap:<harness>` cell the batch tools name (row `lap`, stamp `<harness>:...`).

An exported switch measures the fixed tool with broken recording machinery, not the defect. `env K=0` in the lap command scopes it to the code under test; the verification step runs the lap with no switch at all (default on). The g2 lanes of 2026-10-23 already did this for BMBT_SKIP_READS (`-- env ROUNDS=3 BMBT_SKIP_READS=1 ...`); the exported form (`export SR_SHARD_SELECT=0`) is safe only for a switch nothing but the harness reads.

## B2. Own-rig configuration in a probe's argv masks own-rig bugs

Folded from `compiled-criteria-own-rig-flag-argv-trap`; raw source `trap-criteria-import-sets-own-rig-flag-from-any-argv-config` (via `compiled-batch-control-fix-switch-scoping`). A probe or lap carrying an own-rig configuration in `argv` cannot reproduce the orchestrator's environment, because `tools/criteria.py` sets `MXFS_OWN_RIG` from `sys.argv` at import.

Mechanism:
- `tools/criteria.py` runs, at import time (criteria.py:106-113), a scan of `sys.argv[1:]`. If any argument matches `<n>/<class>/<method>/<attach>` and that attachment has its own board (`data/configurations.json` `attaches.<a>.board`, e.g. drbd), it does `os.environ.setdefault("MXFS_OWN_RIG", "1")` and switches CRITERIA to that board.
- That is a property of the PROCESS's command line, not of the call. A probe that imports criteria (directly, or through `tools/release_run.py`, `tools/defects.py`, ...) and passes `2/net/mesh/drbd` as a command-line argument gets the own-rig flag for free, so it cannot observe a bug whose whole shape is "the flag was not set". The orchestrator, `release_run.py start <candidate>`, names no configuration in its argv.

What happened, 0.90.134, D-RELEASE-RUN-BOARD-VERDICT-GRADED-NO-ROW-OF-AN-OWN-RIG-BOARD:
- The lap `tests/release_board_verdict_lap.py` called `board_verdict(cand, sys.argv[3], ...)` in a `python3 -c PROBE root cand 2/net/mesh/drbd board` subprocess.
- The fix-out control b20261022-ec8648 passed 20 of 20 laps (measured nothing). With the inputs moved to environment variables, control b20261022-4233e9 failed 20 of 20 with the fix out, and the fixed tree passes.

Apply:
- A probe or lap that must reproduce the orchestrator's environment passes configurations through env vars or stdin, never argv, and pops `MXFS_OWN_RIG` and `MXFS_CRIT` from the child env.
- Before running a control batch, apply the fix diff in reverse by hand and run ONE lap: if it does not fail, the lap is not measuring the defect. A control that passes is a recorded, closed batch that bounds nothing.

## B3. A control's probe must be the defect's trigger, not the success marker

Folded from `compiled-lap-batch-traps-control-probe-and-vm-reaper`; raw source `trap-control-probe-that-only-passing-laps-print-measures-zero-of-one` (via `compiled-batch-control-fix-switch-scoping`).

What the code does: `tools/defects.py` `exposed()` (around :884). When a batch has a probe, a FAIL lap counts toward the rate only if its `exposure=` count is above 0. `docs/release-process.md` still says "a FAIL counts as exposed". The code is what decides.

What happened (bitten 2026-10-22/23):
- Control `b20261022-172c3f` of `D-JOIN-DURING-TAKEOVER-GATE-PASS-ENDS-BEFORE-ITS-IN-FLIGHT-SAMPLE` used the probe `^GATE join_during_takeover fault: .*fault_line=1`. Only a lap that reached the injection prints that line.
- With the fix out, 9 of 10 laps overran the gate's 228 s bound before ever reaching the injection, so they never printed the probe (exposure 0) and their FAILs were not counted. A probe only passing laps print made a 9-of-10-failing control measure "0 of 1 exposed laps". That bounds nothing, so the verification could not be sized.
- A rerun probed the harness's own trigger line, `INFO A.s lone remount: A_MOUNT_RC=0` (read with `--evidence` from the gate's evidence dir). It counted on both outcomes.

Apply:
- Pick a control's probe from the defect's TRIGGER: a line both a failing and a passing lap print once they have reached the triggering condition. Never pick the success path's own marker.
- Before declaring the batch, run the precheck's fail lap and check that the probe matches its output. If the line lives in a file the lap writes, add `--evidence <glob>`.
- Board rows (`--board`): `run.sh` counts the probe in each node's dmesg since the lap began. A row that logs nothing to the kernel needs a `/dev/kmsg` mark first. Examples: `fourkn_cdb` marks before its FUA write; `fourkn_merge` writes its counts.

## B4. run.sh's VM-pool reaper powers off unheld nodes 600 s after run.sh exits

Folded from `compiled-lap-batch-traps-control-probe-and-vm-reaper`; raw source `trap-run-sh-vm-pool-reaper-powers-off-unheld-nodes-600s-after-it-exits` (via `compiled-batch-control-fix-switch-scoping`).

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
