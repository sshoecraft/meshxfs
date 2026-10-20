---
name: compiled-kept-snapshots-fill-clyde-root-and-host-io-storms
description: Lap ABORT at stage=prep = host preflight (kept snapshots fill root); snapshot copies storm nvme0n1 and stall every LUN - read sar first
metadata:
  type: feedback
tags: [compiled, rig, clyde, preflight, snapshots, lun_pool, sar, host-io, scst]
---

# Kept snapshot images fill clyde's root; host write storms stall every pool LUN

Assorted-tail group (one note, no sibling topic): two host-side failure modes on clyde that look like MXFS or rig faults but are the host's own state. Provenance: run 7e16fd1d, session 31 (2026-10-17). Source: `trap-kept-snapshots-fill-clyde-root-and-host-write-storms-stall-every-lun`.

## 1. A burst of `RESULT: ABORT ... stage=prep` within seconds, across every queue, is the host preflight

From `trap-kept-snapshots-fill-clyde-root-and-host-write-storms-stall-every-lun`:

- Seen: from 14:04Z every queued lap on every pair (hf8b, hf6t, hf7c: 16 laps) aborted at prep in 8-22 s; all queues reached QUEUE DONE with nothing measured.
- Read the lap's `prep.log` first. Here: `clyde_preflight: FAIL ... test LUN pool (/dev/nvme0n1p2): 100% used, 7G free (limit: >=10G free)`.
- Cause: `tools/lun_pool.sh snapshot` (called by `tests/noino_gen0_ab.sh` on every CORRUPT audit) copied each 20 GiB pool LUN (12-15 G of data) into `/home/steve/disks/snapshots` on the root ext4 with no check; 22 images = 285 G.
- Since 0.90.131 the snapshot refuses a copy that could leave its filesystem below `MXFS_PREFLIGHT_MIN_FREE_GB` (10 G) and honours `MXFS_SNAPSHOT_DIR`. `/mxfs` is a separate XFS on `/dev/sda` (SSD, 1.8 T); the kept images live in `/mxfs/snapshots` with symlinks at the old paths. Put `MXFS_SNAPSHOT_DIR=/mxfs/snapshots` on queue lines that can keep images.
- Never clear or skip the preflight to get moving; free the space.

## 2. A snapshot copy (or any big buffered write on /) is a host-wide I/O storm

From `trap-kept-snapshots-fill-clyde-root-and-host-write-storms-stall-every-lun`:

- The pool LUNs, the 32 guest images and the journal share nvme0n1p2. Two snapshot copies took nvme0n1 average await from ~0.5 ms to 20-70 ms (aqu-sz ~110) and dirty pages to 6-7 G for about two minutes.
- Two unexplained stalls on concurrent laps sat inside such storms: a 57 s CAW hold at unmount on 2/disk/caw/mpath (13:34Z) and a 35 s path-down stall on an 8-node board (13:14Z).
- Measured with `tests/caw_host_storm_probe.sh`: a lone initiator's CAW latency rose from 10 ms to 1.95 s under a 28 G storm. That is 200x, but not tens of seconds, so the storm alone did not reproduce the 57 s hold.
- Before diagnosing any stall, timeout or budget overrun on the rig as an MXFS fault, read the host's own history for that minute: `LC_ALL=C sar -f /var/log/sysstat/saDD -s HH:MM:00 -e HH:MM:00 -d -p | grep -E 'DEV|nvme0n1$'` (DEV is the last column, so do not grep `'nvme0n1 '`), and `-r` for kbdirty. sar uses local time (CDT = Z-5).
- `make modules` in the main tree took 376 s instead of ~38 s while a 285 G move ran on the same NVMe.
