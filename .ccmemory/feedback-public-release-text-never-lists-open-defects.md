---
name: feedback-public-release-text-never-lists-open-defects
description: README, release notes, CHANGELOG release sections and forum posts never list or describe open defects; open records live only in data/defects.json.
metadata:
  type: feedback
tags: [release, readme, changelog, public-text]
---

Public release text (README, the CHANGELOG section that becomes the GitHub release notes, forum posts, banners) never names, lists or describes an open defect: no "exception" paragraphs, no "shipped open by the owner's decision", no description of an unexplained failure.

**Why:** the owner, on finding a README exception paragraph and a CHANGELOG "Shipped open" paragraph added at release time (0.90.130): a reader takes "open defects" in release text as a reason not to try the software at all. It reads as sabotaging the release. Leaving a record out of release text does not close it: it stays in `data/defects.json` with its evidence, and the queue stays public.

**How to apply:**
- If a public sentence would be false with an open noblock record in the queue (e.g. "no open defect that can ... reaches any released configuration"), reword it to state the bar and the command that checks it (`tools/defects.py <configuration> --release`). Do not keep the false absolute, and do not add a disclosure paragraph.
- A harness-fix CHANGELOG entry may say what was fixed, not describe the open failure that exposed it.
- After editing the CHANGELOG section of a published version, regenerate the release notes from it: `gh release edit v<V> --notes-file <section>`.
