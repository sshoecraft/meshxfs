---
name: precheck-lanes-beside-batch-lanes-spend-their-plan-places
description: A session's own precheck lane (power-up, pool lock) beside running batch lanes pushes their laps' 88-120 s inner prep bounds over; the INCOMPLETE use…
metadata:
  type: feedback
---

Laps such as tests/peer_window_lap.sh (prep bound 120 s) and tests/live_holder_shard_lap.sh (88 s) time their own `run.sh prep_cluster`, and that bound counts run.sh's pre-prep waits: the LUN pool lock and the shared power-up lock (scripts/lab_power.sh up holds /tmp/mxfs_host_powerup.lock exclusive until its guests answer ssh; the preflight takes it shared).

Observed 2026-10-24: a precheck holding the pool lock 20 s on purpose (batch_lap_wait) made an 8-node prep wait 37 s, and some other power-up made a 2-node prep's preflight wait 31 s; both laps ended rc=2 'prep_cluster rc=124' after the prep itself printed OK. An INCOMPLETE lap uses up a place in the batch plan (defects.plan_laps counts PASS/FAIL/INCOMPLETE), so the control can never be measured without a reviewed settlement, which needs node kernel logs that an aborted prep never collected.

Also: a bare (groupless) run.sh takes /tmp/mxfs_run.lock EXCLUSIVELY (run.sh:432-446) and refuses beside any group run, so a lap whose control arm runs a bare prep (in_gate_prep) can only measure with no other lane up.

How to apply: run prechecks that power VMs up or hold the pool lock only when no batch lane is mid-batch, or in a solo lane; schedule laps that need exclusivity in a solo lane started when every other lane is DONE.
