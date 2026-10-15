---
name: compiled-public-tester-release-requires-full-proxmox-pass
description: Public Proxmox-forum tester release: full PVE suite must pass on the exact release build after its last source change; no commit/push/release unless…
metadata:
  type: feedback
tags: [compiled, release, proxmox, testing]
---

Single-note group (kind assorted): the release gate for a MeshXFS build going to public testers.

Source: `feedback-public-tester-release-needs-full-proxmox-pass-on-the-release-build`

User, 2026-10-13: once the Proxmox VE 9 work is done the plan is commit, push and release, then the user posts a call for testers on the Proxmox forums — "so it needs to be solid".

**Why:** outside testers are the first real users. A defect they hit costs the project's credibility, which a lab failure does not. Their reports also arrive with less evidence than a rig run.

**How to apply:**
- Before telling the user a release is ready for a public call, every Proxmox check must pass on the exact build being released, after its last source change:
  - the multipath fault rows (`tests/mpath/path_*.sh` on pve9-5/6/7);
  - live migration (`tests/pve_live_migrate.sh`);
  - HA power-cut failover (`tests/pve_ha_failover.sh`);
  - datastore operations: snapshot, rollback, backup and restore, disk move, template and linked clone, container (`tests/pve_storage_ops.sh`);
  - each with zero bad kernel lines.
- Any source change after a pass, even to an unrelated file in the module, means re-running them.
- No open defect observed on the Proxmox configuration may remain. The release bar is integrity plus stability, and the zero-known-defects rule still applies.
- Commit, push and release only when the user directs it in that turn. The plan above is the user's intent, not standing permission.
