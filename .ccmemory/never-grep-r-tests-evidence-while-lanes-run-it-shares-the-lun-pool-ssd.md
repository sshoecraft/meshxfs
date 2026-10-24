---
name: never-grep-r-tests-evidence-while-lanes-run-it-shares-the-lun-pool-ssd
description: tests/evidence -> /src/mxfs-evidence is on /dev/sda, the SSD under every pool LUN; a recursive grep saturates it and confounds every running lap
metadata:
  type: feedback
---

**Trap.** `tests/evidence` is a symlink to `/src/mxfs-evidence`, on `/dev/sda`, the one SATA SSD that also holds every SCST pool LUN image (`/mxfs`, `/home/steve/disks/pool`). A recursive read of the evidence tree (`grep -rl <batch id> tests/evidence`) reads ~500 MB/s and drives sda to 100 % util for minutes.

**Observed 2026-10-24 (0.90.134 attempt 19).** A session's `grep -rl 'b20261024-d04ebf' tests/evidence` ran 16:10:37Z-16:13:56Z (backgrounded at its 120 s tool timeout). clyde's sysstat (`sadf -t -d /var/log/sysstat/sa24 -- -d -p`, CDT): sda rkB/s 238461 at 11:11:01, 539491 / 510022 / 473715 at 11:12-11:14 with %util 100.00 / 99.99 / 92.84, then 6702 at 11:15. In those minutes two laps failed: verification b20261024-0fd280 lap 12 (workers 3 of 20 rounds, remount hung 68 s, killed at 130 s; it ended an 89-lap verification) and control b20261024-aefae7 lap 10 (prep over 88 s, log-slice zero_ms 13679/16208 vs 1030-6902).

**The cost is worse than the lost laps.** The release-reviewer REJECTED the infra-proven claim for lap 12 (P20261024-a96a97): coincidence in time is not a measured link, the lap kept no node kernel log, and an earlier lap passed in a 61 % minute. A session's own I/O can therefore leave an unexplained failure that must be recorded as a defect and reproduced under control. A failed lap the session caused cannot simply be written off.

**How to apply.**
- Never `grep -r`, `du`, `find` or any recursive read over `tests/evidence` while any rig lane runs. Locate a batch's laps through the ledger (`grep -n <batch> data/criteria.runs.jsonl`): lap logs are `tests/evidence/batch_laps/<batch>/*.log`, lap evidence directories are `tests/evidence/<stamp>_<tag>_<label>`, or `ls -d` a known stamp prefix.
- When a lap is slow or overruns, check sda (`sadf -t -d /var/log/sysstat/saDD -s HH:MM:00 -e HH:MM:00 -- -d -p | awk -F';' '$4=="sda"'`, 1-minute samples in CDT) and the session's own commands at that time. An infra claim still needs the nodes' kernel logs for the window.
- Related: [[compiled-scst-shared-target-caw-latency-lap-bounds]].
