---
name: trap-lap-on-helper-rc-is-greps-not-the-ssh-commands
description: Lap helpers `on()` pipe ssh through grep -v, so their exit status is grep's (1 when silent), never the remote rc or 124 from timeout
metadata:
  type: feedback
---

tests/fourkn_merge_2node.sh's `on() { timeout ... ssh ... | grep -avE '^Warning:...'; }` returns grep's status: 1 when the killed client printed nothing, 0 when anything printed. A lap testing `rc=124` on that line could never see an overrun and graded every lap VACUOUS (2026-10-24, session 8815bf68, tests/merge_overrun_lap.sh).

Also: `fuser -m DIR` on a directory that is no longer a mount point counts every user of the root filesystem (~130), and misses a looping bash worker with no file open at that instant.

How to apply: grade overruns from measured walls against the bound, holds from /proc/mounts plus `ps -C <comm>`; never trust rc through a pipeline without PIPESTATUS.
