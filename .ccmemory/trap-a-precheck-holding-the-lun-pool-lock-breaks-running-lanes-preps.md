---
name: trap-a-precheck-holding-the-lun-pool-lock-breaks-running-lanes-preps
description: Never hold the LUN pool lock on purpose (lun_pool.sh quiet sleep) while lanes run: a lap's inner 120 s prep bound counts the wait and goes INCOMPLETE
metadata:
  type: feedback
tags: [trap, lun-pool, lanes, batch, precheck, incomplete]
---

What bit (2026-10-24, session 80): the precheck of tests/batch_lap_wait_lap.sh held the LUN pool lock for 20 s on purpose (`tools/lun_pool.sh quiet sleep 20`), four times in three minutes, while seven lanes ran. Lap pw9c10 of a peer_window control batch on g8b started its prep in that window: run.sh waited 18 s for the pool lock and its quiet preflight 19 s more, so its prep (84 s of its own work) took 121 s against the lap's own `timeout 120 ./run.sh ... prep_cluster`, the lap ABORTed at stage=prep, batch_lap recorded INCOMPLETE, and the whole 10-lap control (9 of 10 failures, ~26 min of rig) could not be measured until an infra-proven proposal for that lap was reviewed.

Why: almost every lap wraps its own prep in `timeout N ./run.sh ... prep_cluster` (about 490 such sites in 290 files), and that inner bound counts any wait on another lane's lock; the wait ledger in tools/batch_lap.py (MXFS_LAP_WAIT_FILE) only extends batch_lap's outer bound.

How to apply:
- Never run anything that holds the pool lock, the power-up lock or the host perf lock on purpose while lanes run; run such prechecks when `tests/evidence/lanes/*/` show no live lane, or put them in a lane queue after the others (scripts/lane_after.sh).
- When a batch lap goes INCOMPLETE with 'STAGE prep rc=124', read its prep.log 'pool lock waited N s' lines and the pool's lock.log (`$(lab_need paths pool)/lock.log`, holds over 10 s with pid and command) to name the holder before anything else; that pair is the infra-proven evidence.
