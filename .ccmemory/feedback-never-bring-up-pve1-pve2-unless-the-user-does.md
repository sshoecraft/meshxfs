---
name: feedback-never-bring-up-pve1-pve2-unless-the-user-does
description: USER (exasperated, repeated): never raise pve1/pve2 — their state, redeploys, version drift — unless the user asks. Rig VMs cover the work.
metadata:
  type: feedback
tags: [pve, user-correction, scope]
---

The user corrected this three times in one conversation (2026-10-11): first asking why the focus kept going back to them, then telling the session to stop focusing on pve1/2.

- Do not mention the physical Proxmox pair (pve1/pve2) in summaries, handoffs, "state the next session inherits", caveats, or rule-interpretation examples unless the user brings them up in that turn.
- Not "they need a redeploy", not "they run an older build", not "this is the situation that clause targets".
- Why: the user's position is that everything doable on those hosts is doable on the rig VMs (test1..test32), they are noisy and powered off by default, and their state is the user's concern, not a standing work item.
- If a task genuinely cannot be done on the rig, say what specifically and ask once; do not keep re-raising them.
