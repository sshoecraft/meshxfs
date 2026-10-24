---
name: trap-lanes-sharing-the-scst-target-double-caw-latency-and-overrun-tight-lap-bounds
description: Lanes sharing the one SCST target slow every COMPARE AND WRITE ~2x; a lap whose bound is ~2x its own median then overruns (4Kn merge lap, 298-lap bat…
metadata:
  type: feedback
tags: [trap, rig, scst, timing, batch]
---

All rig groups reach pool LUNs on ONE SCST target on clyde. When create-heavy lanes run at the same time (a 40000-create stage on disk/caw, a TCP ledger-heavy unmount lap, even a local-disk create loop on a node), every COMPARE AND WRITE another lane issues takes about twice as long: in tests/fourkn_merge_2node.sh the kernel's CAW-ILOCK avg went from ~1.5 ms to 3.0-3.7 ms, the worker from a 7.8 s median to 15.4 s, and its 16 s client bound (WBOUND) cut the other node's half. Lap 104 of a 298-lap verification failed that way and the whole batch was lost (D-FOURKN-MERGE-WORKLOAD-OVERRAN-16S-WHEN-EVERY-CAW-TOOK-TWICE-AS-LONG).

How to apply:
- Before declaring a long verification batch of a lap whose bound is near 2x its own median wall, check what else will load the target while it runs; keep create-heavy lanes (lmu traces, alloc fills, rsync) off it, or schedule the batch when nothing else runs.
- When a timing-graded lap fails with no error in its kernel log, compare the per-op CAW latency counters (CAW-ILOCK n/tot_ms/avg_us lines) against a passing lap before suspecting the filesystem, and list every lane running in the window (tests/evidence/lanes/*/summary.log step times).
- Single-writer creates on 2/disk/caw/direct cost 6-18 ms each (D-SINGLE-WRITER-CREATE-PACE-...), against the ~2.2 ms tests/last_member_umount_lap.sh assumed from the TCP lock manager: a lap bound derived on net/mesh overruns on disk/caw in its setup stage. Derive per lock manager.
- Do not run your own ad-hoc load probes on rig nodes while another lane's timing-graded batch runs.
