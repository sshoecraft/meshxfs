---
name: feedback-when-you-release-ask-gpt-for-advice-on-the-release-banner
description: USER directive: when you release, ask GPT for advice on the release banner. RULE: CONSULT ANOTHER MODEL WHEN STUCK (never consult another model) was removed for this, 2026-10-10.
metadata:
  type: feedback
---

USER 2026-10-10: "remove rule 5 and add a memory that says 'when you release ask gpt for advice on the release banner' ... because NO ONE I MEAN _NO ONE_ is going to [be] excited about '2026-10-10 — 0.90.116 — the allocator's trylock no longer does ledger I/O while it holds a VM image's lock' ... ever".

**When you release, ask GPT (`mcp__ask_gpt__query`) for advice on the release banner** — the headline on the GitHub release page, the released version's CHANGELOG heading, and the README's release section heading — before publishing.

- Give GPT what users get from the release (every user-visible improvement since the previous RELEASE, not just the last version), who the users are (e.g. Proxmox admins running a two-host DRBD pair), and the draft banner; ask what would make it a reason to upgrade.
- RULE: CONSULT ANOTHER MODEL WHEN STUCK in CLAUDE.md ("never consult another model") was REMOVED by the user on 2026-10-10 to allow this. Older memories that say never to consult another model (compiled-model-consults-policy-and-handling-consult-output, feedback notes from 2026-09-04 and 2026-10-06) describe the retired rule.
- Related: feedback-release-headline-sells-the-whole-release-to-its-users-not-the-last-internal-fix, feedback-every-release-lists-its-released-configurations-in-a-table.
