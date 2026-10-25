---
name: compiled-lab-rig-scheduling-clone-and-address-pin-traps
description: Rig traps: DKMS oversubscription, virt-clone serial log, stale addr pins, SCST-shared CAW latency vs lap bounds, release-candidate freeze drift.
metadata:
  type: feedback
tags: [compiled, rig, lab, libvirt, dkms, release, scst, timing, release-candidate, freeze, drift, subagent]
---

Rig and release-candidate traps, merged from two articles that share no single subject (assorted): (I) building and powering the multi-node lab rig (scheduling, cloned VM config, stale address pins), (II) timing-graded rig laps sharing one SCST target, (III) the release-candidate freeze and what drifts a RUNNING candidate. Part II and III are folded from `compiled-scst-shared-target-caw-latency-lap-bounds`, which itself folded `compiled-frozen-release-candidate-subagent-script-drift` and `compiled-release-candidate-freeze-drift-traps`. Related: [[compiled-make-modules-under-running-lanes-trap]] (building `mxfs.ko` in place under running lanes).

# I. Building and powering the lab rig

Three traps, each a case of the rig's configuration silently disagreeing with the host or the resolver. The first is a scheduling error; the other two are stale or copied configuration.

## Host oversubscription: concurrent DKMS compiles
Source: `trap-two-8-node-platform-sets-compiling-dkms-at-once-oversubscribe-clyde-and-overrun-the-install-budget` (0.90.36).
- The packaged round's install step is a DKMS compile of the whole module on every guest. It is budgeted per guest at 45 core-minutes on a 4-vCPU guest, which is 660 s (`tests/packaged_round.sh`).
- `tests/full_verify.sh` (POWER=1) ran two platform sets per group. At 8 nodes, rhel9 and ubuntu2404 compiled together: 16 guests x 4 vCPUs = 64 vCPUs on clyde's 56 cores.
- Six of eight alma9 nodes were still in the %post DKMS build at 660 s (rc 124, `install_*.log` ends at "Running scriptlet"), and the round failed. At 4 nodes the same pairing is 32 vCPUs and installed in 426-527 s.
- Fix: one set per group at 8 nodes, `PLATFORM_GROUPS="pve9 debian13 rhel9 ubuntu2404"`.
- Do not widen INSTALL_S. The per-guest budget is right and the schedule oversubscribed the host. At any new node count, compute concurrent compile vCPUs (sets x nodes x 4) against `nproc` on clyde before choosing groups.

## virt-clone copies the source's serial log path
Source: `trap-virt-clone-copies-the-sources-serial-log-path-so-no-clone-starts-while-the-source-runs` (0.90.25).
- `scripts/lab_clone_node.sh test5 ubuntu2404-1 ... ubuntu2404-8` cloned the images, restarted test5, then died at the first clone's start with `Cannot open log file: '/var/log/libvirt/qemu/test5-serial.log': Device or resource busy`.
- The rig VM definitions carry `<log file='/var/log/libvirt/qemu/<name>-serial.log' append='on'/>` under both `<serial>` and `<console>`. `virt-clone` rewrites only name, UUID, MAC and disk, so every clone names the source's log file, which the running source holds open.
- It had never appeared because the osimager-built platform VMs (pve9-*, alma9-*, debian13-*) have a bare `<serial type='pty'>` with no log line, and every earlier clone was of one of those.
- Repair of clones already made: `virsh dumpxml --inactive <clone> | sed "s#<source>-serial.log#<clone>-serial.log#g" > file; virsh define file`. The images need nothing, since identity rewrite happens before first start.
- After any `virt-clone`, grep the clone's definition for the source's NAME. Anything still carrying it (log files, sockets, channel paths, nvram) is shared with the source and will either refuse to open or be written by both.

## Stale `addr` pins in the lab file
Source: `trap-a-stale-addr-line-in-the-lab-file-fails-lab-power-up-while-ssh-by-name-still-works` (0.90.35).
- `~/.config/mxfslab/lab*` still pinned `pve9-1=192.168.120.194 pve9-2=192.168.120.138` from the two-node era. DHCP had moved the guests to .192 and .137.
- `scripts/lab_power.sh up pve9` waits on `lab_addr <node>`, which prefers the lab file's `addr` over the resolver. It reported "NOT UP within 240 s" and exited 1, while `tools/mxfs_sshpass.sh pve9-1 ...` by name answered at once because DNS had the current address. A POWER=1 chain (`tests/full_verify.sh`, `tests/release_verify_chain.sh`) would have failed at its first platform step.
- Diagnosis when a node is "not up" but reachable by name: compare `getent hosts <node>` and `ip neigh show dev br0 | grep -i <mac from virsh domiflist>` with `lab_addr <node>`.
- An `addr` entry is needed only for a node the resolver does not know. Here alma9-* and debian13-* have no DNS names; pve9-* and ubuntu2404-* do. Delete entries the resolver covers instead of re-pinning them, because `lab_addr` falls back to `getent ahostsv4`. Leave `lab.backup` alone.

# II. Lanes sharing the SCST target double CAW latency
Source: `trap-lanes-sharing-the-scst-target-double-caw-latency-and-overrun-tight-lap-bounds`, via `compiled-scst-shared-target-caw-latency-lap-bounds`.

## Trap
All rig groups reach pool LUNs on ONE SCST target on clyde. When create-heavy lanes run at the same time (a 40000-create stage on disk/caw, a TCP ledger-heavy unmount lap, even a local-disk create loop on a node), every COMPARE AND WRITE another lane issues takes about twice as long. In tests/fourkn_merge_2node.sh the kernel's CAW-ILOCK avg went from ~1.5 ms to 3.0-3.7 ms, the worker from a 7.8 s median to 15.4 s, and its 16 s client bound (WBOUND) cut the other node's half. Lap 104 of a 298-lap verification failed that way and the whole batch was lost (D-FOURKN-MERGE-WORKLOAD-OVERRAN-16S-WHEN-EVERY-CAW-TOOK-TWICE-AS-LONG).

## How to apply
- Before declaring a long verification batch of a lap whose bound is near 2x its own median wall, check what else will load the target while it runs; keep create-heavy lanes (lmu traces, alloc fills, rsync) off it, or schedule the batch when nothing else runs.
- When a timing-graded lap fails with no error in its kernel log, compare the per-op CAW latency counters (CAW-ILOCK n/tot_ms/avg_us lines) against a passing lap before suspecting the filesystem, and list every lane running in the window (tests/evidence/lanes/*/summary.log step times).
- Single-writer creates on 2/disk/caw/direct cost 6-18 ms each (D-SINGLE-WRITER-CREATE-PACE-...), against the ~2.2 ms tests/last_member_umount_lap.sh assumed from the TCP lock manager: a lap bound derived on net/mesh overruns on disk/caw in its setup stage. Derive per lock manager.
- Do not run your own ad-hoc load probes on rig nodes while another lane's timing-graded batch runs.

# III. Release-candidate freeze: added files drift a running candidate
Traps around files added under a frozen directory while a candidate is RUNNING (lane queue files, `check` not read-only, what works on an INVALID attempt). Folded via `compiled-scst-shared-target-caw-latency-lap-bounds` from `compiled-frozen-release-candidate-subagent-script-drift` and `compiled-release-candidate-freeze-drift-traps`.

## Frozen directories and what counts as drift
- `tools/release_candidate.py` freezes every file under `tests`, `tools`, `scripts` (FROZEN_DIRS) except the MUTABLE patterns (`tests/evidence/*`, `*.pyc`, `*.o`, `tests/queues/*.state`, ...).
- An ADDED file in a frozen dir is drift exactly like an edited one: it sets the candidate INVALID at the next check. `tests/lanes/` is not MUTABLE, so a new queue file there is drift.
- The Edit/Write freeze hook did not stop it: the files were new, written while the session's hook judged them, or through the shell.
- `release_candidate.py frozen <path>` does not catch a new file: it answers 0 only for a path already in the manifest's file list (or non-mutable `data/`); a new file returns 1 ("not frozen") although adding it is drift.

## Incident 1: lane queue files (candidate 0.90.134, attempt frozen 2026-10-23T20:41:09Z)
- Drifted on five ADDED files: `scripts/scst_reload.sh` and four lane queues `tests/lanes/queue_*.txt`, written by a session after the freeze (original note `trap-lane-queue-files-under-tests-drift-a-running-candidate`).

## Incident 2: subagent helper script (session 65, 0.90.134 attempt frozen 2026-10-24T04:13:43Z)
Original note: `trap-subagent-writes-a-helper-into-scripts-and-drifts-a-running-candidate`.
- A `miner` subagent asked to parse prep step timings wrote its parser to `scripts/prep_step_stats.py`, because the global rules say anything executable goes in the repo's `tools/`/`scripts/`, never `/tmp`.
- That file was an ADDED file under a frozen dir: drift, candidate INVALID at the next check.
- The Edit/Write freeze hook did not stop it (the agent's write was a new file).

## `check` is not read-only
- `tools/release_candidate.py check <version>` on drift prints the changes and sets the candidate's state to INVALID in `data/candidates/<version>.json` ("candidate 0.90.134 is now INVALID"). Session 56 ran it to look, and that moved the state.

## What still works on an INVALID attempt (read in tools/defects.py, 2026-10-24)
- `check_batch_lap` (defects.py:989) checks batch state, row, configuration and candidate name, not the candidate's state, so running batch laps continue.
- `cmd_verify` (:1302-1360) does not check it either, and counts laps after `criteria.attempt_began`, which only a new `create` moves.
- A reviewer may still object to evidence from a drifted tree, so cite that the drift touches no file the lap runs.

## How to apply
- While a candidate is RUNNING, every delegated prompt that might produce a script must say: write no file under `tests/`, `tools/`, `scripts/`, `packaging/` or `run.sh`; put any helper you need under the session scratchpad (or `tests/evidence/`, which is MUTABLE), and say where it is.
- Put lane queue files for a running attempt under `tests/evidence/` (MUTABLE), never `tests/lanes/`; land new scripts in the sibling tree for the next freeze.
- Before writing any file into the main tree during an attempt, ask `tools/release_candidate.py frozen <path>` (remembering a new file answers 1 yet is still drift: treat only a MUTABLE-pattern path as safe).
- Do not run `check` to look; read the manifest, or run `frozen` per path.
- If a file slips in, move it out of the frozen dirs at once (before any orchestrator step or `check`), keep it in the scratchpad, and land it under `scripts/` right after the attempt is abandoned.
- After any agent returns, check its report for "I wrote ... new file" before trusting the tree is unchanged.
