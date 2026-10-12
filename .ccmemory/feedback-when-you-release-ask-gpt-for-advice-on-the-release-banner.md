---
name: feedback-when-you-release-ask-gpt-for-advice-on-the-release-banner
description: USER: release banner = GPT writes it from the version's changelog section, prompt "write a banner describing the enhancements", no draft of ours.
metadata:
  type: feedback
---

USER 2026-10-10: "when you release ask gpt for advice on the release banner" — NO ONE is excited by an engineering headline like "the allocator's trylock no longer does ledger I/O...".

USER 2026-10-12, after testing the method below on 0.90.124: "whatever you did to get this result is what I want to see in the future."

## The procedure (exactly this)

Before publishing, call `mcp__ask_gpt__query` with:

1. The prompt, first: **"Write a banner describing the enhancements made in this release. Here is the changelog for the release, MXFS <version>:"**
2. Then the released version's `CHANGELOG.md` section:
   - **Without its `## ...` heading line** (the heading is the banner being written; sending it seeds the answer).
   - The user-facing summary and the released-configurations table **verbatim**.
   - The "### <version> in detail" part with test-tooling and lab-host paragraphs dropped (harness fixes, evidence/space tools, recovered scripts) and the defect write-ups shortened; refer to the lab host generically ("the test host"), not by name.
3. **Nothing else.** No draft banner, no audience description, no length limit, no "what would make users upgrade". GPT reads the changelog and writes the banner.

Use GPT's title line as the banner: the GitHub release title, the CHANGELOG heading, the README release heading.

0.90.124's result, which the user liked: **"MXFS 0.90.124 — Multipath SAN Support, Stronger Recovery, Better Scalability"** — short category labels an admin scans in a second.

## What failed and why (do not repeat)

- Sending GPT OUR draft plus our change list and asking it to improve it (0.90.124, session d49bdcf7): GPT polished our framing into "restored multipath for 2–16-node SANs, multiple filesystems per host, and multi-resource DRBD recovery". User: the worst selling point of a release they had ever seen.
- "Restored"/"returns"/"is back": history only we know (claimed in 0.90.51, withdrawn). To a user it says it was broken. It comes from the changelog's own "released again ... Last claimed in 0.90.51" wording, so keep version history out of the user-facing summary.
- Rewriting it ourselves did not fix it: outcome sentences ("lose a cable... and your cluster keeps running") were "banners for managers"; feature-list lines were just as bad.
- Do not take GPT's output and ship it unread; but when it comes from this procedure, its title line is the banner.

The old "never consult another model" rule was REMOVED by the user on 2026-10-10 to allow this.
Related: feedback-release-headline-sells-the-whole-release-to-its-users-not-the-last-internal-fix, feedback-every-release-lists-its-released-configurations-in-a-table.
