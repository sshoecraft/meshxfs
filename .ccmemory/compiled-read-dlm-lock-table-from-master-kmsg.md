---
name: compiled-read-dlm-lock-table-from-master-kmsg
description: No DLM lock-table dump exists; read a TCP master's waiters/holders from its followed kmsg: P-LKTIMEOUT-HOLDER, P6-FAIRQ, P958-ACQ-RETX lines
metadata:
  type: feedback
tags: [compiled, technique, dlm, tcp, diagnosis, kmsg, lock-table]
---

# Reading a TCP DLM master's lock table from its followed kmsg

Opening line: this article holds one technique note (kind assorted, a single-note group). Central topic: diagnosing what a stuck DLM wait waits on when no lock-table dump exists. Source: `technique-read-a-masters-lock-table-from-its-followed-debug-lines`.

## Why this technique
- MXFS has no debugfs dump of the DLM lock table, and a lap's nodes are often powered off before anyone thinks to look. `technique-read-a-masters-lock-table-from-its-followed-debug-lines`
- The table is still recoverable from the MASTER's own followed /dev/kmsg, because on rig nodes the `mxfs_pal_log` DEBUG lines are printed. They all share the one dynamic-debug format "%s%pV" in `pal/linux/kern.c` `mxfs_pal_vlog`, so they are on or off together; DLM_TRACE lines in a log prove they were on. `technique-read-a-masters-lock-table-from-its-followed-debug-lines`

## What to grep, on the node that MASTERS the stuck resource
Find the master from its own `P-RBLK-DENY-LOCAL` / "we=" lines, or whichever node's log has `P-LKTIMEOUT-HOLDER` for that ino. `technique-read-a-masters-lock-table-from-its-followed-debug-lines`
- `P-LKTIMEOUT-HOLDER type= ino= holder=<node> hmode= hstate= held_ms= queued_ms= (we= req=)`: every entry on the resource when a LOCAL wait times out. hstate: 1 WAITING, 2 GRANTED, 3 CONVERTING, 4 BLOCKED (`include/mxfs/mxfs_dlm.h:251-255`). `technique-read-a-masters-lock-table-from-its-followed-debug-lines`
- `P6-FAIRQ site=local|remote ... behind waiter=<owner> wmode=`: a request held by the arrival FIFO barrier (`find_conflicting_waiter`), naming the older waiter. `technique-read-a-masters-lock-table-from-its-followed-debug-lines`
- `P958-ACQ-RETX ... entry and queue position kept`: a remote re-send of a queued wait answered QUEUED without being decided again. `technique-read-a-masters-lock-table-from-its-followed-debug-lines`

## Pitfalls
- Node ids change per mount within one boot: map id -> host from that boot's `MXFS-MEMBERSHIP local=<id>` / `P290-AUTH-ADMITTED node <id>` lines on each node. `technique-read-a-masters-lock-table-from-its-followed-debug-lines`
- Each node's kmsg usec is its own boot clock; never compare across nodes. `technique-read-a-masters-lock-table-from-its-followed-debug-lines`

## Worked case (2026-10-24, D-8NETMESH-RECOVERY-BLOCKED-LEAVES-QUEUED-SURVIVOR-ACQUIRES-PARKED-FOREVER)
Survivors parked "forever" looked like waiting on a dead node's grant. The master's `P-LKTIMEOUT-HOLDER` showed the dead node held a COMPATIBLE PR, and the survivors' PR waits were held only by the master's own older EX wait, which was later denied and freed; `P958-ACQ-RETX` showed the re-sends were then kept, never re-decided. Without these lines the wrong fix (deny on blocked holder) would have been written. `technique-read-a-masters-lock-table-from-its-followed-debug-lines`

## How to apply
Before concluding what a stuck wait waits on, find the master and read these three lines around the stall; keep the kmsg followed into a file for the whole lap (the ring rotates). `technique-read-a-masters-lock-table-from-its-followed-debug-lines`
