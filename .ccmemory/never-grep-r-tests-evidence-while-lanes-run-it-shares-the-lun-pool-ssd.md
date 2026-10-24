---
name: never-grep-r-tests-evidence-while-lanes-run-it-shares-the-lun-pool-ssd
description: tests/evidence -> /src/mxfs-evidence is on /dev/sda, the SSD backing every pool LUN; a recursive grep of it saturates the rig and fails laps
metadata:
  type: feedback
---

**Trap.** `tests/evidence` is a symlink to `/src/mxfs-evidence`, on `/dev/sda` — the one SATA SSD that also holds every SCST pool LUN image (`/mxfs/disks/pool`). A recursive read of the evidence tree (`grep -rl <batch id> tests/evidence`, ~TBs of lap logs) reads ~500 MB/s and drives sda to 100 % util, and every rig lane's I/O through the target slows with it.

**Observed 2026-10-24 (0.90.134 attempt 19).** A session's `grep -rl 'b20261024-d04ebf' tests/evidence` ran 16:10:37Z-16:13:56Z (backgrounded at its 120 s tool timeout). clyde's sysstat (`sadf -t -d /var/log/sysstat/sa24 -- -d -p`, CDT): sda rkB/s 238461 at 11:11:01, 539491 / 510022 / 473715 at 11:12-11:14 with %util 100.00 / 99.99 / 92.84, then 6702 at 11:15. In that window: verification b20261024-0fd280 (fourkn_merge_2node, g2d) lap 12 overran its 130 s bound (workers stopped at round 3 of 20, remount hung 68 s) after 11 PASS laps of 67-75 s — the first FAIL ends a verification batch for good; and control b20261024-aefae7 (lh_master, g2) lap 10's prep overran 88 s (log-slice zeroing zero_ms 13679 / 16208 vs 1030-6902 normally).

**How to apply.**
- Never `grep -r`, `du`, `find` or any recursive read over `tests/evidence` while any rig lane runs. Locate a batch's laps via the ledger (`grep -n <batch> data/criteria.runs.jsonl`) — lap logs are `tests/evidence/batch_laps/<batch>/*.log`, lap evidence dirs `tests/evidence/<stamp>_<tag>_<label>` — or `ls -d` a known stamp prefix.
- When a lap is slow or overruns, check sda first: `sadf -t -d /var/log/sysstat/saDD -s HH:MM:00 -e HH:MM:00 -- -d -p | awk -F';' '$4=="sda"'` (local time CDT, 1-minute samples), and match the window against this session's own commands (transcript timestamps) before suspecting MXFS.
- Related: [[compiled-scst-shared-target-caw-latency-lap-bounds]] (lanes sharing the target double CAW latency), the D-FOURKN-MERGE-WORKLOAD-OVERRAN record (sda 92-99 % util during an earlier slow lap).
