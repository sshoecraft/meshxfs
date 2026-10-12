---
name: feedback-never-test-on-the-2011-kingston-ssds-the-samsungs-are-the-pve-pair-reference-disks
description: USER directive: never test on the Kingston SVP100S (2011) SSDs again; <1% of users run disks that old. PVE pair legs run on the Samsung 850 EVOs.
metadata:
  type: feedback
---

User directive, 2026-10-10, after about a week of physical-pair legs on pve1/pve2's spare Kingston SSDNow V+ (SVP100S, 2011 SATA, QD1, ~1 s flush stalls):

- **Never run a test, leg, A/B or measurement on the Kingston drives again.** The user is removing them. "It'd be like taking an old SATA drive from 2005 and tuning our 2026 clustered software on it." Fewer than 1% of users run SSDs that old.
- The **Samsung 850 EVOs** (pve1 250 GB, pve2 500 GB) are the reference disks for the physical pair. Wiping them for legs is authorized. Select them by model ("850 EVO"), never by /dev name: names shift when drives are removed.
- Why it went wrong: the D-REMOTE-NOQUEUE family only reproduced on the slow Kingstons, so every fix needed a Kingston leg, and a week of work was tuned to worst-case hardware nobody runs. Defects found only on such hardware stay in the queue but rank below anything seen on ordinary disks.
- The user also corrected the reading of "working perfectly" as "every open slowdown record closed": the DRBD pair worked at 0.90.116 (released, failover suite green, no integrity/stability record). Do not inflate a criterion into an endless queue drain; judge it the way the user would.
