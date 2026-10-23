---
name: removal-needs-applied-verify-and-a-lap-where-the-defect-lives
description: remove --fixed is refused/rejected while its fix-on batch is open (apply verify first); a host-only lap of a node-side harness defect is rejected
metadata:
  type: feedback
---

Two ways four remove-fixed proposals were rejected in one sitting (2026-10-23, P20261023-9b6f3f, -1bcf31, -b32dc8, -7bd24f):

1. **Order.** `tools/defects.py remove --fixed` refuses unless the fix-on batch is `passed` (defects.py:1752), and only an approved, applied `verify` (`propose verify` -> release-reviewer -> `defects.py verify --batch B --approval P`) sets that. A `harness_batch.py verify` run leaves the batch `open`. So file the verify proposal FIRST, apply it, then file the removal; filing both at once wastes a review. Also check the record has a `reproducer` field (defects.py:1736 refuses without one).

2. **Where the lap runs.** A harness defect whose failure happens on a rig node (fsx files moved off an mxfs mount to /root; a rejoined victim's loaded module parameters) is not proven by a host-only lap that runs on /dev/shm or records the argv a node's shell would get. The reviewer rejects it: the fix never ran on the path the defect lives on (cross-filesystem copy, CAW vs TCP branch, real module load). Design the lap to run on the node, on the configuration the failures were seen on, and file its ledger rows at the configuration it actually ran (a lap that ran MXFS_CONFIG=8/net/mesh/mpath but recorded 2/net/mesh/direct was also cited).

Host-only laps are fine for defects that live on the host (tools/*.py, criteria/defects logic).
