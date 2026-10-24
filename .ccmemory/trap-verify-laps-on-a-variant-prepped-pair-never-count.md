---
name: trap-verify-laps-on-a-variant-prepped-pair-never-count
description: Verification laps on a pair prepped with MXFS_EXTRA_MODARGS carry variant marker_modargs=...; defects.py verify counts none of them
metadata:
  type: feedback
---

**Trap.** A verification batch has no variant (plan-verify takes no --variant), and `tools/defects.py unplanned_variant` drops every lap whose ledger run carries any variant. A batch lap run on a pair that `run.sh prep_cluster` formed with `MXFS_EXTRA_MODARGS=...` is recorded with `variant: marker_modargs=<those args>` (taken from the cluster marker), even when the lap's own command sets nothing. So six exposed PASSes of b20261024-565ac2 (8/disk/caw/mpath, prepped with dead_timeout_ms=12000) counted zero, after the release-reviewer had approved the verify proposal. The refusal text then said "PASS without exposure", which points at the probe, not the variant (D-VERIFY-REFUSAL-NAMES-VARIANT-LAPS-AS-UNEXPOSED).

**What to do.** Before queueing a verification batch, check the prep step that forms its pair: no MXFS_EXTRA_MODARGS and no MXFS_TEST_ENV that run.sh records as a variant. Controls may run on a variant (the knob is their variant), but the fix-on batch must run the candidate as frozen. If the defect only shows with a non-default module argument, find an exposure that needs none (the rejoin lap now exposes on prep's own log_repeat_limit=0 against the module default 1) before spending rig time on the verification. A quick check after lap 1: `grep '"batch": *"<bid>"' data/criteria.runs.jsonl | head -1` and read its `variant` field.
