---
name: compiled-rig-lap-node-run-tmpfs-exhaustion
description: Rig laps fill node /run tmpfs with pathload logs; full /run kills new loads silently so laps grade VACUOUS. Aborted laps leave loads running. Check d…
metadata:
  type: feedback
tags: [compiled, rig, trap, pathload, tmpfs, vacuous]
---

Single-note group (kind: assorted tail, one note): the trap of rig laps exhausting a node's /run tmpfs and grading vacuous.

Source: `trap-node-run-tmpfs-full-kills-pathload-silently-and-laps-grade-vacuous` (session 86, lane g2_a20, 2026-10-24).

## What bit us
- tests/fenced_ledger_rig_lap.sh (/run/fledger_<label>) and tests/noino_fence_efd_hold_lap.sh (/run/noinoefd_<label>) put each node's pathload logs in /run, a ~360 MB tmpfs, and never remove them.
- Fifteen fenced_reason laps left ~70 MB each on test1; /run reached 100%. From then on every pathload started on test1 died on its first write.
- Signs: a 0-byte `pid` file, an empty `.out` with no traceback (stderr is in /run too), no python3 left running, nothing in dmesg or the journal.
- Twelve noino laps then graded VACUOUS stage=no-fence: S's load never ran, so R ran uncontended (`mutex_busy=0`) and no fence came.

## How to spot it
- A lap's `<node>_load.txt` holds only `LOADREC_END` (no PATHLOAD, MAXOP_MS or ERRS line), and `STAGE <node>:  max_op_ms=` is empty.
- Check `df -h /run` on the node before reading anything into a VACUOUS or ABORT verdict.

## Aborted laps leave loads running
- A lap that ABORTs after starting its loads leaves them running. The next lap's forced prep reformats the volume under them (millions of ERR ENOENT in their ops.log), and they keep filling /run.
- Touch `/run/<lap>_<label>.stop` on both nodes after any aborted lap.

## A lane's own grep can be a vacuous negative
- g2_a20 step 6 grepped `*load_postmortem*`, but those laps write `test<N>_load.txt`, so the glob matched no file. Read the files directly before citing a negative.

## Records
D-RIG-LAPS-LEAVE-LOAD-LOGS-IN-NODE-RUN-AND-A-FULL-RUN-KILLS-THE-NEXT-LOAD, D-NOINO-LAP-ABORT-LEAVES-ITS-LOADS-RUNNING-INTO-THE-NEXT-LAP.
