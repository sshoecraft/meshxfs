---
name: trap-make-modules-under-running-lanes-swaps-the-module-they-deploy
description: Never run make modules while any lane or batch can deploy the tree's mxfs.ko: abandoning the candidate does not protect them; a DRBD lap loaded the n…
metadata:
  type: feedback
tags: [build, mxfs.ko, rig-lanes, release-candidate, trap]
---

**What bit (session 65):** after abandoning candidate 0.90.134 so kernel sources could be edited while lanes finished on the frozen build, the session ran `make modules` "to check it compiles". The tree's `mxfs.ko` changed for about two minutes (srcversion B947A20F... -> 3E3690F7...). In that window a third_vote control lap's `drbd_rig.sh` copied the tree's module to test1/test2 and loaded it, so one control lap ran a build other than its batch's. `run.sh` with MXFS_CANDIDATE refuses a mismatched build at its start, but nothing re-checks mid-row: a path row's victim rejoin re-preps the victim from the tree, and DRBD laps deploy without the candidate check. Restored by reversing the edits exactly and rebuilding (srcversion and sha256 matched the manifest), then reading `/sys/module/mxfs/srcversion` on every busy node to find which runs were touched; the contaminated batch was stopped and moved to the next attempt.

**How to apply:**
- While ANY lane, batch or row may deploy (prep, rejoin, DRBD up/mxfs, laps that insmod), never build `mxfs.ko` in place. Abandoning the candidate changes nothing for them: they read the tree's .ko.
- Edit kernel sources then if needed, but build only after every lane using the module has ended; to check that an edit compiles earlier, there is no safe in-place way: wait.
- If a build slips out: restore the frozen build at once (reverse the edits exactly and rebuild, compare srcversion and sha256 with data/candidates/<v>.json), then read the loaded srcversion on every busy node and name each run that loaded the wrong one.
