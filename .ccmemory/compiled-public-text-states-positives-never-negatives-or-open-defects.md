---
name: compiled-public-text-states-positives-never-negatives-or-open-defects
description: Public/outreach/release text: state what MeshXFS is and passed; no volunteered negatives, no open-defect listings, no invented owner persona.
metadata:
  type: feedback
tags: [compiled, outreach, public-text, release, readme, changelog]
---

Two feedback notes (assorted group, one theme): everything public-facing — outreach drafts, README, release notes, forum posts — states what MeshXFS is and has passed, and never volunteers a negative or lists an open defect.

## Outreach text (press emails, forum posts, HN, social) — `feedback-outreach-text-states-what-it-is-never-what-it-is-not`

Rule: outreach states what MeshXFS is and what it has passed. It never volunteers a negative the owner did not ask for: "not proposed for upstream", "not a production release / use disposable data", open defects, "not yet X". It never says anything about the owner that the owner has not stated: no persona, background, fandom or listener status.

Evidence:
- LWN pitch (2026-10-16) carried an added line "It is not proposed for upstream and is not a patch series against it today". The editor's refusal quoted it back as one of the two reasons not to cover it. Owner: "You really shouldn't have put the upstream shit into the post."
- Same session added, unasked, a "not yet a production release" section to the Proxmox forum post and README exception paragraphs for open defects; the owner rejected each.
- Not claiming something does not claim its opposite, so a disclaimer adds nothing true and hands the reader a reason to stop.
- 2.5 Admins draft: opening "Long-time storage nerd here" invented a persona for the owner; the owner removed it ("wtf").

Apply:
- Draft only positive, verifiable facts about the project; facts about the owner only as the owner gave them (goal and bar set; did not write, edit or review the code).
- If a sentence would be false without a qualifier, reword the sentence rather than adding a disclaimer.
- If a likely objection seems worth answering, mention it to the owner as a suggestion outside the draft, not inside it.

## Release text (README, CHANGELOG release section, forum posts, banners) — `feedback-public-release-text-never-lists-open-defects`

Rule: public release text never names, lists or describes an open defect: no "exception" paragraphs, no "shipped open by the owner's decision", no description of an unexplained failure. Open records live only in `data/defects.json`.

Evidence: owner, on finding a README exception paragraph and a CHANGELOG "Shipped open" paragraph added at release time (0.90.130): a reader takes "open defects" in release text as a reason not to try the software at all; it reads as sabotaging the release. Leaving a record out of release text does not close it: it stays in `data/defects.json` with its evidence, and the queue stays public.

Apply:
- If a public sentence would be false with an open noblock record in the queue (e.g. "no open defect that can ... reaches any released configuration"), reword it to state the bar and the command that checks it (`tools/defects.py <configuration> --release`). Do not keep the false absolute, and do not add a disclosure paragraph.
- A harness-fix CHANGELOG entry may say what was fixed, not describe the open failure that exposed it.
- After editing the CHANGELOG section of a published version, regenerate the release notes from it: `gh release edit v<V> --notes-file <section>`.
