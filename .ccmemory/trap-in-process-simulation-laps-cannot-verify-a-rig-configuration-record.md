---
name: trap-in-process-simulation-laps-cannot-verify-a-rig-configuration-record
description: Release-reviewer rejects verify/removal batches whose laps are in-process tauth simulations for a record observed on a rig configuration
metadata:
  type: feedback
---

A verification or removal batch for a defect observed on a rig configuration (e.g. 8/net/mesh/mpath) is rejected when its laps run the in-process tauth simulation (`tests/tauth/*_test.sh`: four simulated nodes in one process on the lab host, `VMs held for the lap: none`), however clean the statistics.

Seen 2026-10-23 on candidate 0.90.134: verifies P20261023-867053 and P20261023-6664ba and removals P20261023-778a6d and P20261023-6c4c99 (records D-8NETMESH-SURVIVOR-SHUTDOWN-FALSE-FRESH-AG-GRANT-AFTER-TAKEOVER and D-SELF-FENCED-NODE-LEDGER-PUBLISHER-RETRIES-FOREVER-ON-RESERVATION-CONFLICT) were all rejected although controls were 10/10 and fix-on batches 6/6 with exposure.

Why the reviewer refuses:
- the configuration the verify would clear never ran, and no lap loaded the candidate's module (the ledger's build field comes from `modinfo` of a module nobody loaded);
- a simulation whose store never refuses a write cannot produce a RESERVATION CONFLICT loop, so the recorded failure was neither reproduced nor shown gone;
- `tests/tauth/Makefile` omits included headers from some object rules, so the linked binary is not shown to be built from the frozen tree;
- a removal settles every run the record names, so failures in that run the cause does not explain must first be named by another open record.

What passes instead: board-row laps (`harness_batch.py --board`, `MXFS_CANDIDATE` set) at the record's configuration on the candidate's module, a kernel-log probe of the trigger on the node that hits it, and N sized from a control measured there (knob off through `MXFS_EXTRA_MODARGS`, or the fix reverted in a scratch copy of the frozen file list), or an explicit `--transfer` the reviewer can check. Plan the rig laps before spending a lane on simulation laps.
