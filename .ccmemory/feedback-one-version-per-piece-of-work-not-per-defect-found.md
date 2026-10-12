---
name: feedback-one-version-per-piece-of-work-not-per-defect-found
description: USER (2026-10-12): bump the version ONCE per thing being worked on (e.g. mpath support), however many defects or sessions it takes.
metadata:
  type: feedback
---

User, 2026-10-12, after the mpath run went 0.90.122 -> 0.90.123 (16-node dir-reload hang) -> 0.90.124 (rejoined node cannot open files): "You're only supposed to bump the version one time for each thing you're working on ... Right now you're working on mpath ... Even if you use 300 sessions, that's one version."

- The unit of a version is the piece of WORK the run is doing (the ccloop task: "test and release mpath support"), not each defect found while doing it. A defect found on the way joins the open version's CHANGELOG entry as another paragraph.
- The changelog rule's "a change that needs an entry of its own" means a different piece of work, not a different bug inside the same work. Read it that way.
- Do not renumber backwards to undo an extra bump. The user, 2026-10-12: "you don't have to go back to 123. You can stay on 124, but don't increase the version again." Renumbering also forces a rebuild and re-gating of a verified build.
- Stopping a running gate chain to renumber was itself the wrong move; the user interrupted it.
