---
name: feedback-release-banner-must-name-the-headline-platform-support
description: Before applying GPT's release banner, check it names the release's headline (e.g. new Proxmox VE version support); tell GPT what must be named.
metadata:
  type: feedback
---

Owner correction, 2026-10-21 (0.90.132). The banner had been "Safer Inodes, Stronger Recovery, Proxmox VE 9.2". After the changelog section changed, GPT was asked for a banner from the whole section with no guidance and returned "Cross-Node Inode Coherence and Recovery"; it was applied and pushed. The owner: "WAIT ... WE DO ADD SUPPORT FOR 9.2 right ... I DONT WANT TO RELEASE WITHOUT IT" / "THEN WHY REMOVE IT ... ITS IMPORTANT".

**Why:** new platform support (a Proxmox VE version) is what the primary audience, Proxmox users, looks for; a banner built only from fix bullets drops it.

**How to apply:**
- When asking GPT for a banner, name in the prompt what the owner treats as the headline (new platform/version support first), and say it must appear.
- Compare the returned banner with the previous banner before applying it: anything the old banner named that is still true of the release must still be there, or ask the owner.
- The banner goes in three places: CHANGELOG.md heading, README `> ## <version>:` heading, and the GitHub release title (scripts/release.sh reads it from the CHANGELOG heading).
