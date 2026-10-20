---
name: compiled-rig-harness-traps
description: Rig traps: pool LUN needs MXFS_DEV when unmounted; xfs.ko beside mxfs.ko breaks kretprobes; nohup setsid $! is not the runner PID
metadata:
  type: feedback
tags: [compiled, rig, harness, device-resolution, bpftrace, kretprobe, background-jobs, lap-queue]
---

Assorted group: the clusterer could not fit these three notes to one topic. What they share is that each is a trap in driving the MXFS lab rig, each was hit on 2026-10-19, and each is prevented by a cheap precondition check. They are organised by where the trap sits: device resolution in the harness, symbol resolution in the tracer on a guest, and background-job PIDs on the host.

## Pool rig: an unmounted node's LUN is not found unless the caller sets `MXFS_DEV`

Source: `trap-pool-lun-unmounted-node-device-resolution-needs-mxfs-dev`

`tests/lib/rig.sh` `mxfs_dev_resolve` picks the device in this order: `MXFS_DEV`, else the node's live mxfs mount, else `/dev/disk/by-id/wwn-0x<declared wwid>`, else MXFS_CONFIG's attachment device. On the pool rig (SCST_FIO `mxfspool` LUNs) the WWID is an EUI-64 (`eui.6233653366636664`), and both of the last two steps fail:

- The `wwn-0x` fallback path does not exist. udev names the LUN `scsi-2<hex>` (and `scsi-1SCST_FIO...`, `scsi-SSCST_FIO_...`), never `wwn-0x<hex>`. And `mxfs_wwid_norm` strips only `naa.` / `0x` / `mpath-`, so `eui.` leaves a stray `e` in the hex.
- MXFS_CONFIG's device (`data/configurations.json`, `attaches.direct.device`) is the FIXED rig's LUN path (`.../shared-lun-0`), which a pool node does not have. Error text: `is not a block device on <node> (configuration-default)`.

Consequence: a harness that mounts a node the previous lap left UNMOUNTED ABORTs at `stage=device` unless the caller names the path, e.g. `MXFS_DEV=/dev/sda`. The case that bit: `tests/remount_node.sh` after `tests/lone_rsync_bench.sh`, which ends with A's own umount. The resolver still checks the named path's WWID against the pool allocation, so a wrong path ABORTs rather than mounts the wrong disk.

Seen 2026-10-19: queue `p6a2`'s three remount laps all ABORTed this way, and the audits behind them refused (`marker stale ... want ... MOUNTED`).

A node that is still mounted resolves by its live mount and needs nothing.

## Tracing MXFS by function name while xfs.ko is also loaded

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

## `$!` after `nohup setsid X &` is not the runner's PID

Source: `trap-nohup-setsid-background-pid-is-not-the-runner`

What bit us (session 110, 2026-10-19): `nohup setsid tests/lap_queue.sh p6r Q > log 2>&1 < /dev/null & echo $!` printed 102263. That PID was gone seconds later while the queue ran on. `tests/lap_queue_after.sh 102263 p6a Q2` saw "pid gone" and started p6a at once. p6a's prep then took g2c's run and config locks in the middle of p6r. Every p6r lap after that failed in 0 s (rc=3 on the locks, ABORT on knob read-back), and an arm in flight was contaminated.

Why: the Bash tool's shell runs background jobs with job control. A background job that is a single command is its own process-group leader. setsid(1) forks when its caller leads a group, so `$!` is the parent, which exits at once, and the runner gets a new PID. When the `&` covers a whole `a && b && nohup setsid X &` list, the list's subshell leads the group instead. setsid then does not fork, and `$!` (the subshell) stays alive as X's parent. That is why the other queue's PID happened to work.

Apply:
- Never pass a `$!` from `nohup setsid ... &` to `lap_queue_after.sh`, `kill`, or a liveness check.
- After launching, get the runner's real PID with `tools/mxfs_pgrep.sh 'lap_queue.sh <label>'`. Ignore the PID that also matches your own pgrep shell. Confirm it with `/proc/<pid>/cmdline` before chaining on it.
- Before relying on a waiter, read its `.after` file. "pid ... gone" on the first line, at the same second it started, means it fired immediately. Stop it before its prep runs.
- Two queues on one rig group never overlap safely: a prep re-formats the LUN under the other queue's arm.
