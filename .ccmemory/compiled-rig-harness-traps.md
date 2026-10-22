---
name: compiled-rig-harness-traps
description: Rig traps: pool-LUN MXFS_DEV, xfs.ko vs kretprobes, detached-process lifetime, SCST 3x abort hold, unexported modargs, MXFS_CRIT, RHEL9 folio mmap
metadata:
  type: feedback
tags: [compiled, trap, rig, harness, device-resolution, bpftrace, kretprobe, background-jobs, lap-queue, setsid, systemd, cgroup, process-lifetime, dracut, scst, libiscsi, tas, fio, modargs, lap-chain, fenced-victim-withdraw, criteria, MXFS_CRIT, vsphere, rhel9, large-folio, mmap, iomap, kcompat, srcversion, board]
---

# Rig and harness traps: driving the lab rig, detached-process lifetime, reading the right witness, and vSphere / RHEL 9 board bring-up

Merged from four compiled articles; shared topic: traps in driving the MXFS lab rig and in reading what it reports. (1) The original article: three traps (an assorted tail) that share being traps in driving the rig, each hit on 2026-10-19 and each prevented by a cheap precondition check; organised by where the trap sits: device resolution in the harness, symbol resolution in the tracer on a guest, background-job PIDs on the host. (2) `compiled-detached-process-lifetime-and-teardown-traps`: who owns a detached process's lifetime and what a kill does or does not reach (four of five inputs), plus a neighbouring boot-time persistence trap (dracut). (3) `compiled-scst-abort-hold-3x-timeout-and-chain-reprep-drops-modargs`: two traps from the TAS line of the D-FENCED-VICTIM-WITHDRAW investigation, each a verdict read from the wrong witness. (4) `compiled-criteria-board-env-trap-and-rhel9-large-folio-mmap-livelock`: two unrelated traps hit while bringing up the vSphere / RHEL 9 platform board.

## A. Driving the rig: device, symbol and PID resolution

### Pool rig: an unmounted node's LUN is not found unless the caller sets `MXFS_DEV`

Source: `trap-pool-lun-unmounted-node-device-resolution-needs-mxfs-dev`

`tests/lib/rig.sh` `mxfs_dev_resolve` picks the device in this order: `MXFS_DEV`, else the node's live mxfs mount, else `/dev/disk/by-id/wwn-0x<declared wwid>`, else MXFS_CONFIG's attachment device. On the pool rig (SCST_FIO `mxfspool` LUNs) the WWID is an EUI-64 (`eui.6233653366636664`), and both of the last two steps fail:

- The `wwn-0x` fallback path does not exist. udev names the LUN `scsi-2<hex>` (and `scsi-1SCST_FIO...`, `scsi-SSCST_FIO_...`), never `wwn-0x<hex>`. And `mxfs_wwid_norm` strips only `naa.` / `0x` / `mpath-`, so `eui.` leaves a stray `e` in the hex.
- MXFS_CONFIG's device (`data/configurations.json`, `attaches.direct.device`) is the FIXED rig's LUN path (`.../shared-lun-0`), which a pool node does not have. Error text: `is not a block device on <node> (configuration-default)`.

Consequence: a harness that mounts a node the previous lap left UNMOUNTED ABORTs at `stage=device` unless the caller names the path, e.g. `MXFS_DEV=/dev/sda`. The case that bit: `tests/remount_node.sh` after `tests/lone_rsync_bench.sh`, which ends with A's own umount. The resolver still checks the named path's WWID against the pool allocation, so a wrong path ABORTs rather than mounts the wrong disk.

Seen 2026-10-19: queue `p6a2`'s three remount laps all ABORTed this way, and the audits behind them refused (`marker stale ... want ... MOUNTED`).

A node that is still mounted resolves by its live mount and needs nothing.

### Tracing MXFS by function name while xfs.ko is also loaded

Source: `trap-xfs-ko-beside-mxfs-ko-makes-kretprobes-fail-unique-symbol`

MXFS forks XFS and keeps XFS's function names (`xfs_create`, `xfs_vn_rename`, `xfs_file_write_iter`, ...). On a rig guest where `xfs.ko` is also loaded, those names are not unique kernel symbols. The native-XFS baseline's `mount -t xfs` loads `xfs.ko`, and nothing unloads it.

Observed (test29, 2026-10-19, bpftrace v0.20.2, 6.8 guest):
- `kprobe:xfs_create` attaches.
- `kretprobe:xfs_create` fails with `cannot attach kprobe, Invalid argument` / `ERROR: Error attaching probe: 'kretprobe:xfs_create'`. The kernel refuses the kretprobe (EINVAL) and the whole bpftrace script refuses to run.
- `kretprobe:mxfs:xfs_create` (module-qualified) is rejected by bpftrace 0.20: `kretprobe probe type requires 1 arguments, found 2`.

Apply:
- Before tracing MXFS functions by name on a guest, check `grep '^xfs ' /proc/modules`. If `xfs` is loaded with refcount 0, `rmmod xfs` first. If it is in use, stop: a probe on the shared name may attach to the wrong module.
- `tests/tcp_rsync_offcpu.sh` does this itself: it writes `xfs_module.txt` and ABORTs when xfs.ko is in use.
- Ftrace's function profiler and kprobe hist triggers by name have the same ambiguity. Prefer unloading xfs.ko over trusting which copy a name resolved to.
- Related bpftrace quirk: `func` in a kretprobe is a ksym, not a string. A map keyed by `func` cannot also take a string literal key (type-mismatch error at parse).

### `$!` after `nohup setsid X &` is not the runner's PID

Source: `trap-nohup-setsid-background-pid-is-not-the-runner`

What bit us (session 110, 2026-10-19): `nohup setsid tests/lap_queue.sh p6r Q > log 2>&1 < /dev/null & echo $!` printed 102263. That PID was gone seconds later while the queue ran on. `tests/lap_queue_after.sh 102263 p6a Q2` saw "pid gone" and started p6a at once. p6a's prep then took g2c's run and config locks in the middle of p6r. Every p6r lap after that failed in 0 s (rc=3 on the locks, ABORT on knob read-back), and an arm in flight was contaminated.

Why: the Bash tool's shell runs background jobs with job control. A background job that is a single command is its own process-group leader. setsid(1) forks when its caller leads a group, so `$!` is the parent, which exits at once, and the runner gets a new PID. When the `&` covers a whole `a && b && nohup setsid X &` list, the list's subshell leads the group instead. setsid then does not fork, and `$!` (the subshell) stays alive as X's parent. That is why the other queue's PID happened to work.

Apply:
- Never pass a `$!` from `nohup setsid ... &` to `lap_queue_after.sh`, `kill`, or a liveness check.
- After launching, get the runner's real PID with `tools/mxfs_pgrep.sh 'lap_queue.sh <label>'`. Ignore the PID that also matches your own pgrep shell. Confirm it with `/proc/<pid>/cmdline` before chaining on it.
- Before relying on a waiter, read its `.after` file. "pid ... gone" on the first line, at the same second it started, means it fired immediately. Stop it before its prep runs.
- Two queues on one rig group never overlap safely: a prep re-formats the LUN under the other queue's arm.

## B. Detached process lifetime and teardown (from `compiled-detached-process-lifetime-and-teardown-traps`)

Topic: who owns a detached process's lifetime, and what a kill does or does not reach. Four of the five inputs are about it; one (dracut) is a neighbouring boot-time persistence trap folded in because it shares the "state outlives what you think you changed" shape.

### Lifetime owners, outermost first

**systemd unit cgroup.** A process started from inside a service (including a `systemd-run` transient unit) stays in that unit's cgroup however it is detached: `setsid`, `start_new_session=True`, `nohup`, double fork. When the unit's main process exits, systemd stops the unit and, with default `KillMode=control-group`, kills everything left in the cgroup. `restart_host()` in `tools/mxfs_drbd_fence_self.py` Popen'd a `sleep 10; echo b > /proc/sysrq-trigger` from the rejoin unit and returned; the host logged "restarting in 10 s" three times and never restarted. Measured on PVE 9.1 / systemd 257: the unit deactivated at once and the delayed write never happened. Fix pattern: do the delayed action in the unit's own main process (sleep, then act) or as its own unit/timer. Detaching is fine only where no unit owns the caller (DRBD handlers run from the kernel usermode helper). Test a delayed action by checking the action happened, not that it was logged. `trap-a-detached-child-of-a-systemd-unit-dies-with-the-unit-setsid-does-not-leave-its-cgroup`

**Session / relay teardown.** A harness or lap chain launched as a plain Bash child of the claude process (foreground, `run_in_background`, or via an agent's Bash) dies when the session is torn down at a relay boundary. Observed twice: a full 32-node board died at the exact relay moment, 3 minutes into a ~17-minute run, leaving no summary row and never starting the chained job; later g2/g4 lap chains died mid-fault, leaving SAN links cut, loads on nodes, and a stale ABORTED/NOT RUN board row. Fix: launch detached, `nohup setsid ... > tests/evidence/<name>.out 2>&1 < /dev/null &`, with per-stage `STAGE <name> rc=N` lines in an evidence chain-log. Evidence lives under `tests/evidence/`, never scratchpad or /tmp (host resets wipe it). Wait on a detached chain with a separate background `timeout <budget> tail -F <chain log> | grep -m1 VERDICT`, which may die harmlessly. `trap-harness-survives-session-exit-check-mxfs-pgrep-before-rig-work` `trap-a-lap-chain-started-as-a-session-background-task-dies-at-the-relay-mid-row`

**Consequence of the fix: detached work is now invisible and outlives the session.** At session start, before any rig work (especially rebuilds, which split srcversion), look for a live orphan with `tools/mxfs_pgrep.sh` and harvest its evidence first. Its output is a point-in-time snapshot: confirm `/proc/<pid>` exists before treating a pid as live. After a relay, check evidence-dir mtimes before trusting a lap is still running. Never use host-local `pgrep -f` / `ps -e` (they take every process's mmap_lock and can wedge the host unkillably). `trap-harness-survives-session-exit-check-mxfs-pgrep-before-rig-work` `trap-a-lap-chain-started-as-a-session-background-task-dies-at-the-relay-mid-row`

### Stopping detached work

- Stop a chain with `kill -TERM -- -<pgid>` (the setsid leader's pid). `run.sh` traps TERM and may linger on a pipe read with no children; check `/proc/<pid>/wchan` and KILL it. `trap-a-lap-chain-started-as-a-session-background-task-dies-at-the-relay-mid-row`
- A killed row leaves its fault in place: run `scripts/san_net.sh link <node> a|b up` and `mute ... off` on every node of the group. `trap-a-lap-chain-started-as-a-session-background-task-dies-at-the-relay-mid-row`
- A group kill does NOT reach a `timeout N ./run.sh` child: GNU `timeout` runs its command in its own process group. The orphaned run.sh kept `/tmp/mxfs_run.lock`, so the next chain's `prep_joiner` failed `rc=3 'another run.sh holds /tmp/mxfs_run.lock'` and continued on an un-prepped fleet. After killing a chain, also kill its run.sh (via `tools/mxfs_pgrep.sh`), or verify `fuser -v /tmp/mxfs_run.lock` is empty before appending DONE to a gate log; append DONE only once the lock is free. `trap-timeout-child-escapes-pgroup-kill-run-lock-collision`
- `tools/mxfs_pgrep.sh '<pattern>'` also matches the calling shell's own cmdline (caused an exit 144). Build the pattern at runtime (`A=chain9; "${A}8"`) and skip cmdlines containing 'snapshot'. `trap-timeout-child-escapes-pgroup-kill-run-lock-collision`

### Adjacent: dracut freezes modprobe options into the initramfs

On dracut distros (RHEL/Alma/Rocky), each initramfs regeneration, including the one the DKMS install triggers, copies every `/etc/modules-load.d` entry into the initramfs together with the module and `/etc/modprobe.d` as of that moment. Early boot loads mxfs from the initramfs with those baked options and the real root's modprobe.d is never consulted. Measured: editing `force_transport=1` to 0 and reloading showed runtime 0, but after reboot both nodes came back `force_transport=1` and mounted TCP; `lsinitrd` showed the baked mxfs.conf files and `mxfs.ko.xz`. `lsinitrd` file dates are dracut's reproducible timestamps, not the build time. Fix (0.90.5): the RPM installs `/etc/dracut.conf.d/mxfs.conf` with `omit_drivers+=" mxfs "` and `%post` rebuilds any initramfs still containing mxfs.ko; the initramfs's modules-load then logs a harmless "Failed to find module 'mxfs'". initramfs-tools (Ubuntu, Debian, Proxmox) does not read modules-load.d and was never affected; any other modprobe option (e.g. `target_cache_protected`) had the same exposure on RHEL. `trap-dracut-bakes-modules-load-d-modules-and-their-modprobe-options-into-the-initramfs`

## C. Fenced-victim-withdraw rig traps: a verdict read from the wrong witness (a prep's read-back, fio's exit) instead of the effect inside the row (from `compiled-scst-abort-hold-3x-timeout-and-chain-reprep-drops-modargs`)

Assorted group (no tighter topic fit): two traps from the TAS (Task Aborted Status) line of the D-FENCED-VICTIM-WITHDRAW investigation on the clyde rig. What they share: a reading that looked like success (a control arm that PASSed; held_ms=0 from fio's exit) did not measure what it appeared to. Grade on the effect observed inside the row's own window.

### 1. A chain's own `prep_cluster` drops an `MXFS_EXTRA_MODARGS` knob that was not exported

Source: `trap-board-chain-reprep-drops-unexported-modargs`. Measured 2026-10-16.

- Trap: a module knob passed as `MXFS_EXTRA_MODARGS=... ./run.sh <cfg> --group <g> prep_cluster` and then a `tests/mpath/lap_chain.sh laps ...` (board_4node_chain.sh) lap. `tests/board_4node_chain.sh` and the `lap_chain` laps run their own `prep_cluster` first. The chain's first step is its OWN `prep_cluster`, which reloads mxfs.ko with whatever `MXFS_EXTRA_MODARGS` is in ITS environment. Unexported, the knob reverts to its default before the row runs.
- Where to see it: `tests/evidence/board_<cfg>_<row>_<group>_<tag>.log` shows the chain's prep as `=== ... ./run.sh <cfg> --group <g> prep_cluster ===`.
- Measured instance (D-FENCED-VICTIM-WITHDRAW, `scsi_tas_set` A/B): the control arm's prep logged `P303-FENCECAP-TAS set=0 tas_on=0`; 48 s later the chain's prep logged `set=1 set_now=1` and the row ran with TAS on - a vacuous control that read PASS.
- Do: `export MXFS_EXTRA_MODARGS=...` for the whole arm (prep and lap). Grade the arm on the knob's EFFECT read inside the row's own window (here: the Control mode page read just before the freeze), never on the prep's read-back.
- This resolves the "mechanism not established" in [[compiled-rig-prep-traps-nologin-banner-as-srcversion-and-knob-state-lost-before-the-board]] item 3 for chain runs.
- Related trap, same run: `ssh node "a && nohup setsid b > out 2>&1 &"` backgrounds the whole `a && b` list in a subshell whose stdout is the ssh channel, so ssh returns only when b exits. Group it: `a && { nohup setsid b </dev/null >out 2>&1 & }`.

### 2. iscsi-scst drops commands another initiator's TMF aborted; libiscsi holds each for 3 x its request timeout; fio's exit is not write return

Source: `trap-scst-aborted-commands-held-3x-timeout-and-fio-exit-is-not-write-return`. Measured 2026-10-17 (D-FENCED-VICTIM-WITHDRAW-HANGS, D-A-BYSTANDER-INITIATOR).

Target (iscsi-scst):
- A PREEMPT AND ABORT or LU RESET from another initiator makes iscsi-scst release this node's queued commands with NO response, whatever the Control mode page TAS bit says: `iscsi_on_abort_cmd` -> `ISCSI_CMD_ABORTED`; `iscsi_xmit_response` drops it.
- Turning TAS on fixed nothing (refuted A/B, code withdrawn).

Initiator (Linux libiscsi):
- It then holds each such command exactly 3 x its request timeout (`iscsi_eh_cmd_timed_out`: "making progress" reset, transport-check reset, then EH abort -> retry). `cmd_age=90s` at 30 s, `540s` at 180 s.
- Trace it with the `iscsi:iscsi_dbg_eh` tracepoints, which fire even with `debug_libiscsi_eh=0`.

Measuring:
- fio's exit is NOT "every write returned": a lap scored held_ms=0 by fio's exit had a write outstanding on a path that returned 90 s later.
- Measure with `/sys/block/<path>/inflight` and the `cmd_age=` the midlayer prints on the failed command.

Releasing held writes:
- `sg_reset -H` does nothing on iscsi_tcp (no `eh_host_reset_handler`).
- Killing the node's own session TCP connection (`ss -K dst addr dport = :port sport = :local_port`) makes libiscsi requeue and iscsid recover the same session: held writes return in ms, no TMF to the target.

Do not lower the timeout:
- Do not lower the 180 s device timeout or provoke nexus loss casually on clyde: the 180 s exists because EH escalation to nexus loss during SCST serialized-CAW drains leaked D-state `iscsi_conn_cleanup` and wedged the LUN (host reset). Check `/proc/*/stat` for D-state scst/iscsi tasks after any such experiment.

## D. vSphere / RHEL 9 platform board bring-up (from `compiled-criteria-board-env-trap-and-rhel9-large-folio-mmap-livelock`)

Assorted group (no single topic): two unrelated traps, both hit while bringing up the vSphere / RHEL 9 platform board. Organised as one section per trap.

### criteria.py without MXFS_CRIT edits the main rig's board

Source: `trap-criteria-py-update-without-mxfs-crit-edits-the-main-rig-board`

- `tools/criteria.py` reads/writes `data/criteria.json` unless `MXFS_CRIT` is set. A platform board edit without it lands on the qemu rig's board.
- What happened: `tools/criteria.py update <id> -b ... --why ...` for the vSphere board (`tests/evidence/vsphere/criteria.json`) was run without `MXFS_CRIT=...` and rewrote the QEMU rig's `data/criteria.json` fio_perf budget 120 -> 364.
- A definition update also stamps `entry["recorded"] = today` (criteria.py:717), so undoing it means restoring `budget_s`, `why` AND removing `recorded`.
- Restore: copy the fields from an untouched copy of the same definition and diff every key (only `per_config` may differ between boards).
- Rule of thumb: every criteria.py call for a non-rig board carries `MXFS_CRIT=$PWD/<board>.json` in the same command, exactly as run.sh invocations do.

### RHEL 9 has folio iomap names but page-based mkwrite: large folios livelock mmap writes

Source: `trap-rhel9-has-folio-iomap-names-but-page-based-mkwrite-so-large-folios-livelock-mmap-writes`

- RHEL 9.8 (5.14.0-687) declares the folio-era iomap API (`iomap_release_folio`, `iomap_dirty_folio`, `iomap_read_folio`, `folio_mkwrite_check_truncate`), so a header probe says "folio iomap". Its `iomap_page_mkwrite` is still the page-based one: objdump of the live function from `/proc/kcore` (resolve call targets via `/proc/kallsyms`) shows `unlock_page`, `wait_for_stable_page`, `set_page_dirty`, `block_commit_write`, `__block_write_begin_int`.
- Symptom: with large folios enabled (the `mapping_set_folio_min_order` compat shim did so for every kernel < 6.12), a write fault on any tail page gets -EFAULT -> `VM_FAULT_NOPAGE` forever. The task sits in state R with millions of minor faults. mmap_coherency reports `steps[mc barrier ready]` because its step label is only updated inside `ck`, not by the python mmap step that actually hangs (misleading label).
- Fix, 0.90.128: large folios only for LINUX_VERSION_CODE >= 5.18 (upstream XFS's own enablement point). RHEL's own XFS leaves them off.
- How it was found fast: sysrq-l for the spinning task's kernel stack; tracefs kretprobes (`r:x func ret=$retval`) on `xfs_filemap_fault` / `xfs_filemap_page_mkwrite` / `iomap_page_mkwrite` / `xfs_buffered_write_iomap_begin` for 1 s to see which returns what. bpftrace on RHEL 9 needs `dnf install bpftrace`, and its struct-page field reads (mapping/index of a head page) were unreliable there.
- Build identity: mxfs.ko srcversion did NOT change for this header-only edit (65E3CB299AEB99B9B62D9E2 before and after); prove build identity with object mtimes and sha256 of mxfs.ko on the node.
