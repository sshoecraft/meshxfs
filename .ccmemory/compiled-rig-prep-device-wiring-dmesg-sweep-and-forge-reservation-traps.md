---
name: compiled-rig-prep-device-wiring-dmesg-sweep-and-forge-reservation-traps
description: Rig/harness/lap traps: prep device wiring, cumulative dmesg sweeps, forge vs SCSI PR, infra-proven evidence, lap helper rc, batch controls, VM reaper
metadata:
  type: feedback
tags: [compiled, rig, harness, prep, run.sh, dmesg, scsi-pr, laps, release-review, kmsg, harness_batch, batch_lap, MXFS_OWN_RIG, vm_pool, reaper, trap]
---

# Rig wiring and harness verdict traps: prep device identity, cumulative sweeps, raw LUN writes, lap grading and batch controls

Two groups of traps, one shape: a harness, prep step, lap, control or review reports a failure or a pass that comes from rig wiring, tooling or an evidence gap, not from the filesystem. Each is read as rig noise or a harness bug first, and none is ever a reason to widen a timeout or loosen a gate. Part 1 (rig wiring and sweep verdicts) is the original article; Part 2 (laps, reviews, batches and controls) was folded in from `compiled-lap-grading-and-review-evidence-traps` (assorted group: session 8815bf68, 2026-10-24, plus four traps from `compiled-batch-control-fix-switch-scoping`).

# Part 1: rig wiring and harness verdict traps

## Prep fails on device identity: the node or device is not wired for this rig

- **Platform sets made of rig VMs.** The `ubuntu2404` verification set lived on test5..test8 (moved there from test3/test4 after the same trap at 4 nodes). The first 8-node boards (`NODES=8 tests/board_4node_chain.sh ... tcp cawd`) died in 60 s with `PREP FAIL: bad nodes: test5(unmounted) ...` and `NODE_PREP_FAIL: device identity: ...:shared-lun-0 ... absent`. test5..8 held one iSCSI node record, for `plat-ubuntu2404`, and none for `:shared`. `prep_node.sh` refused, which is its job. `NODE_PREP_FAIL: device identity ... absent` is rig wiring, never a filesystem verdict, and `tools/criteria.py` classes it as rig noise. Fix: platform sets are VMs of their own, named `<platform>-N` and never `testN` (`ubuntu2404-1..8`, clones of test5); test5..8 got their platform record deleted, the `mxfs` package purged, and the `:shared` record (`node.startup = automatic`) created and logged in. Before the first board at a new node count, check each rig node has exactly one node record naming `:shared` (`iscsiadm -m node` on test1..testN). `trap-a-platform-set-made-of-rig-vms-is-met-unwired-when-the-rig-grows-to-include-them`
- **The `tcp` condition is wired to a rig that no longer exists on the multipath fleet.** `tcp` is run.sh condition 1 (TCP DLM over the LIO tcm_loop rig, LUN XML-wired into guests as `/dev/sda`); `caw` is condition 4 (dm-multipath, `/dev/mapper/mpatha`). On the multipath fleet `./run.sh 32 tcp prep_cluster` dies in prep_fs with `FS_PREP_FAIL: /dev/sda (sda) is claimed by: dm-1 ... This deployment condition's rig is not wired on this fleet`. The 32/tcp column's 20 PASS cells are from the older rig/build. To exercise TCP DLM on the current fleet: `MXFS_DEV=/dev/mapper/mpatha MXFS_CRIT=/src/mxfs/criteria.tcpmp.json ./run.sh 32 tcp prep_cluster`. `MXFS_CRIT` keeps results off the primary board, because cells are keyed `<N>/<dlm>` with no rig dimension and a different rig would silently overwrite the column in place. The force_transport gate in `d0286_tcp_wedge.sh` / `d0287_remaster_measure.sh` checks transport, not rig, so it is still satisfied. `trap-32-tcp-condition-device-is-xml-sda-use-mxfs-dev-mpatha-and-mxfs-crit`
- **Bare `run.sh prep_cluster` on the 2-node QNAP TCP rig.** `MXFS_FORCE_PREP=1 ./run.sh 2 tcp prep_cluster` without `MXFS_NODE_LIST=test1,test2` and `MXFS_DEV=/dev/disk/by-path/ip-192.168.1.4:3260-iscsi-...-lun-0` picks the fleet default `/dev/sda` and fails in 13-20 s with the same `claimed by: dm-1` error, after it has already unmounted and unloaded the nodes. Every following harness then exits in 1 s with `INFRA: precondition not met (A='<id>' B=' ')`. Three rig steps were wasted. On this rig never call run.sh prep by hand; drive through `tests/sess511_chain_0756.sh <label> <steps>` (11 = held rejoin arm, 12 = delayed sameboot arm 1), which exports both variables. If a one-off prep is unavoidable, export the two first. `trap-bare-run-sh-prep-on-the-qnap-2node-rig-needs-mxfs-dev-and-node-list-exported`

Common lesson for all three: the `/dev/sda claimed by dm-1` and `device identity ... absent` strings mean the device or node binding is wrong for the rig under test. Check the condition's rig, the exported `MXFS_DEV`/`MXFS_NODE_LIST`, and the iSCSI records before reading anything into the failure.

## Sweep verdicts that count nothing as zero or count the previous run

`tests/tmpfile_churn_kill.sh` (tck) produced two consecutive false FAILs of the node_death_replay board row on 0.27.7 while the FS behaved correctly. Three compounding flaws, all fixed:

1. ssh-timeout counters summed as zero. A `timeout 60 $SSH` sweep that hit rc=124 wrote a bare header with no counters, and `sum()` treated the node as all zeros. A replayer whose ring provably held both victims' "foreign replay of slot N complete" lines gave frc=0 < victims=2, a false FAIL; the same gap can hide a real shutdown on an unreported node, a false PASS. Fix: command hoisted to `TCK_SWEEP_CMD`, one retry pass, then `SWEEP_MISSING` fails the lap closed. An evidence gap is a verdict, never a zero.
2. The `--no-prep` lap greps cumulative dmesg. `arm_prep` clears rings; lap 1 of the board row does not, so the recovery WAIT counted the previous run's replay-complete lines and released at +21 s, before heartbeat expiry (~62 s), unmounting the fleet mid-death-window. frc=0 was then legitimate (recovery never ran) but looked like a real no-replay defect. Fix: `dmesg -C` on every node at `--no-prep` lap start.
3. 36 separate full-ring greps per sweep against a 16 MB printk-flooded ring on a pegged 1-2 vCPU VM exceeded 60 s, which produced the rc=124s in (1). Fix: dump the ring once to `/tmp/tck_ring` and grep the file.

After all three the row passed (316 s / 470 s) with WAIT released at the genuine +77/+79 s and frc=2/2 on both laps.

Rules: any harness that sums per-node counters must fail closed on a missing per-node report; any cumulative-dmesg grep must be windowed by ring clear or marker. Other harnesses with the same shape are suspect across back-to-back runs: `d526_mass_unmount_verify`, `fr_mount_barrier_fail`, `rman_matrix`. Also: run.sh retains fail logs at `/tmp/run_<name>_<RUN_ID>`; the `logs: /tmp/tmp.*` path it prints is deleted at exit, so harvest the `run_*` copy. And `rman_matrix.sh`'s `$1` is the evidence dir, not an arm; `rman_matrix.sh base_shared base_shared base_shared` runs two arms with evidence in `./base_shared`. `trap-a-cumulative-dmesg-sweep-produces-false-verdicts`

## Raw LUN writes are refused unless the writer holds the reservation or nobody does

In `tests/authtail_mount_unwind.sh` lap s91b the survivor was unmounted first and the peer destroyed, and two seconds later the forge ran from the unmounted survivor: `SG_IO write failed: status=24 ...`. `status=%u` is decimal (`tools/recov_forge.c:338`), so 24 = 0x18 = RESERVATION CONFLICT, not the FUA problem named in the first output line (the FUA fallback had already fired and the retry was `fua=0`). The LUN is held WRITE EXCLUSIVE via SCSI PR; only the holder may write. A VM `destroy` kills the guest instantly but the appliance purges the key with the iSCSI session on its own, much longer schedule, so the destroyed peer still held the reservation. Reads are unaffected (`recov_forge dump` and `save` succeeded from the same node), which is what makes it confusing.

- Issue a raw LUN write from a node that is mounted and holds the reservation, or from a state where nobody holds it.
- `tests/d513_fswide_abort_preserves_death.sh` works from an unmounted survivor because it destroys the victim first; the still-mounted survivor fences and takes the reservation, and its own later unmount releases it. Copying its forge step into a harness with a different node order reproduces the failure.
- A cleanup write on the way out (restoring a forged slot) has the same problem and is worse: a terminal forged record left behind refuses every later mount including the next prep. Give it a bounded retry that outlasts the appliance's purge delay, and report tries and wall so a slow purge is visible.

`trap-a-raw-forge-write-to-the-shared-lun-is-refused-while-another-initiator-holds-the-reservation`

# Part 2: laps, reviews, batches and controls (from `compiled-lap-grading-and-review-evidence-traps`)

Lessons about how a lap, a lap batch/control, or a review is graded and where its evidence comes from. Part 2A (five lessons, session 8815bf68, 2026-10-24) covers single laps and reviews; Part 2B (four traps, from `compiled-batch-control-fix-switch-scoping`) covers lap batches and their controls (`tools/defects.py` controls; `tools/harness_batch.py` -> `tools/batch_lap.py` laps) where the batch finishes, records numbers, and the numbers say nothing about the defect under test.

## 2A. Laps and review evidence

### Infra-proven proposals need node dmesg and every lock holder named
`technique-infra-proven-proposal-needs-node-kmsg-window-and-every-lock-holder-named`

The release-reviewer rejects an infra-proven proposal whose "no MXFS signature" rests on a harness log being silent. It also rejects one whose blocking lock's holder is unnamed, because an MXFS unmount stalling under the lock cannot be ruled out. The peer_window lap passed on the second try, the lh_master lap only on the third. For an INCOMPLETE lap, what got them approved:
- Each node's own dmesg ring for the window, pulled after the fact: `dmesg --time-format iso | awk '$1 >= "<start>" && $1 < "<end>"'`. Show the ring reaches back to boot, state the capture command, and show any repeated benign line (e.g. one 'reservation conflict' pair per module load) is the baseline at every load.
- Every holder named down the chain: the pool lock (`run.sh` preflight under `lun_pool.sh quiet`) -> the power-up lock (`lab_power.sh up` of each lane) -> for each holder, the host journal's libvirtd 'Domain id=N name=...' and systemd-machined 'terminated' lines, proving the VMs booted from off.
- Re-run every disposition-critical negative yourself (e.g. no other domain started in the window).
- Lane logs give step windows. lab_power's own 'host power-up lock held' line exists only when the caller keeps its output.

### Lap helper `on()` returns grep's rc, not the remote rc
`trap-lap-on-helper-rc-is-greps-not-the-ssh-commands`

tests/fourkn_merge_2node.sh's `on() { timeout ... ssh ... | grep -avE '^Warning:...'; }` returns grep's status: 1 when the killed client printed nothing, 0 when anything printed. A lap testing `rc=124` on that line could never see an overrun and graded every lap VACUOUS (tests/merge_overrun_lap.sh).
- `fuser -m DIR` on a directory that is no longer a mount point counts every user of the root filesystem (~130), and misses a looping bash worker with no file open at that instant.
- Apply: grade overruns from measured walls against the bound, holds from /proc/mounts plus `ps -C <comm>`. Never trust rc through a pipeline without PIPESTATUS.

### A draft run.sh in the drafts tree becomes the lap tree root
`trap-draft-run-sh-in-drafts-tree-becomes-lap-tree-root`

Draft laps under tests/evidence/drafts/tree/tests/ locate the repo by walking up until a run.sh exists. Copying run.sh into drafts/tree (to draft a run.sh fix) made that the root. Three merge-overrun laps aborted in 8 s (no tools/mxfs_lab.sh there) and wrote evidence under drafts/tree/tests/evidence/.
- Apply: root walks use `while { [ ! -f run.sh ] || [ ! -f tools/mxfs_lab.sh ]; } && [ "$(pwd)" != / ]; do cd ..; done`. Before copying run.sh into drafts/tree, check no draft lap there is running or queued.
- Related lane trap: scripts/lane_after.sh picks `ls -dt lanes/<name>_*`, which also matches `<name>_wait.log`. A wait log newer than the lane dir keeps it waiting.

### The VFS retries ESTALE lookups, hiding xfs_lookup give-ups
`trap-vfs-retries-estale-lookup-so-workload-errors-miss-resolver-giveups`

Linux retries a path walk that returned -ESTALE (LOOKUP_REVAL), so a single xfs_lookup give-up is invisible to userspace. Measured on 4/disk/caw/mpath path_mount_degraded, typeflip_relookup_shell_dead=0: 5 shell-dead give-ups on test7, every pathload op ok (err=0).
- P201-RELOOKUP is mxfs_probe_ratelimited, so pairing give-up lines with relookup lines fails past ~10 per burst.
- Apply: a lap grading a lookup/resolver fix must read a module counter of the outcome (atomic_t + module_param_cb with mxfs_dbg_atomic_param_ops, write resets), not the workload's error count or ratelimited probe lines.

### kmsg_<node>_fromnode.gz holds the ring since boot
`trap-kmsg-fromnode-holds-ring-since-boot-count-after-pf-mark`

The path rows' kernel-log follower (tests/lib/rig.sh ~292-305) starts by dumping the node's whole dmesg ring, so `kmsg_<node>_fromnode.gz` in a `board_*` dir holds every line since boot, including earlier rows on the same boot. A fix-off path_mount_degraded run "showed" 10 `why=shell-dead` relookups that need the fix on; they were byte-identical to the previous fix-on run's lines, from before this run's PF-MARK.
- Apply: `zcat f.gz | sed -n '/PF-MARK/,$p'` before counting any probe per run. Plain `grep -r` also skips the .gz files entirely, so use zgrep/zcat.

## 2B. Lap batches and controls

Four traps: a fix switch exported past the lap, an own-rig configuration in a probe's argv, a probe that only passing laps print, and the VM-pool reaper powering off unheld nodes. All from `compiled-batch-control-fix-switch-scoping`.

### B1. Fix switch: scope it to the lap command, never export it

Source: `trap-a-fix-switch-exported-to-a-batch-step-also-switches-the-batch-tools`. Scoping a fix switch when running a control batch through `tools/harness_batch.py` (`compiled-batch-control-fix-switch-scoping`).

When a tooling record's fix sits behind an environment switch and its control runs through `tools/harness_batch.py control ... --knob ... -- <lap>`, put the switch on the lap command only:

    python3 tools/harness_batch.py control R --knob "K=0 (...)" ... -- env K=0 tests/<lap>

never `export K=0` on the lane step before it.

Why: several of these switches also govern the machinery that runs and records the control (found while queuing attempt 2026-10-23T15:56:24Z of 0.90.134, lane tests/evidence/lanes/local_a11_tooling_20261023T155735Z):
- `MXFS_HARNESS_BATCH_REREAD=0` makes tools/harness_batch.py itself keep its stale ledger copy, so the control batch would stop after its first lap exactly as the defect did.
- `MXFS_BATCH_LAP_KILLPG=0` and `MXFS_BATCH_LAP_STALL=0` change how tools/batch_lap.py bounds and grades every lap of the batch, the control's own laps included.
- `MXFS_RELEASE_STEP_SETTLE=0` reverts tools/defects.py parse_cell to the first-two-colons split, which mis-parses every `lap:<harness>` cell the batch tools name (row `lap`, stamp `<harness>:...`).

An exported switch measures the fixed tool with broken recording machinery, not the defect. `env K=0` in the lap command scopes it to the code under test; the verification step runs the lap with no switch at all (default on). The g2 lanes of 2026-10-23 already did this for BMBT_SKIP_READS (`-- env ROUNDS=3 BMBT_SKIP_READS=1 ...`); the exported form (`export SR_SHARD_SELECT=0`) is safe only for a switch nothing but the harness reads.

### B2. Own-rig configuration in a probe's argv masks own-rig bugs

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

### B3. A control's probe must be the defect's trigger, not the success marker

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

### B4. run.sh's VM-pool reaper powers off unheld nodes 600 s after run.sh exits

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
