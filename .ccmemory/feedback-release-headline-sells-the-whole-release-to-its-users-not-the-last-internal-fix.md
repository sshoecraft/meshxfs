---
name: feedback-release-headline-sells-the-whole-release-to-its-users-not-the-last-internal-fix
description: USER: 0.90.116's headline was "the allocator's trylock no longer does ledger I/O..." for 8 versions of DRBD pair work. Lead with what users…
metadata:
  type: feedback
---

USER 2026-10-10, on the published 0.90.116 release: "LOL _this_ is your headline? for the massive amount of drbd 2 node work??? how is that a selling point to the proxmox users". Then: "STOP SAYING 'and nothing else' ... its implied" (README's "What 0.90.116 was validated on, and nothing else:").

**Why:** `scripts/release.sh --publish` uses the version's CHANGELOG section as the GitHub release notes, and its heading as the release headline. The CHANGELOG heading had been written as an engineering note for the LAST fix. The versions between releases (0.90.108-0.90.115, all "IN PROGRESS, NOT RELEASED") never reach users through their own notes, so the released version's section is the only place their work is announced.

**How to apply:**
- Before publishing, rewrite the released version's CHANGELOG heading as a headline for its USERS (e.g. "two-host Proxmox VE on DRBD: VM disks no longer freeze on slow SSDs, and a host that leaves, fails or rejoins comes back cleanly"), covering everything since the previous RELEASE, not just this version's patch.
- Open the section with a plain-language summary for someone upgrading from the last release: one bullet per user-visible improvement, with the version that made it, then what it was validated on. Put the engineering detail after it under "### <version> in detail".
- Never write "and nothing else" / "no other X was tested" after a validation list: the list's scope is implied. Name only the specific configurations that are explicitly NOT claimed, when that matters to the reader.
- If a release has already gone out with a bad headline: `gh release edit v<V> --title ... --notes-file <section>` fixes the published page.
