---
name: compiled-release-cycle-banner-and-tooling-freeze
description: Release-cycle lessons (0.90.132): banner must name headline platform support; no tools/ or run.sh edits while a board runs.
metadata:
  type: feedback
tags: [compiled, release, banner, tools, criteria]
---

Assorted group (loosely related): two owner corrections from the 0.90.132 release cycle, 2026-10-21.

## Release banner must name the headline platform support
Source: `feedback-release-banner-must-name-the-headline-platform-support`

- The banner had been "Safer Inodes, Stronger Recovery, Proxmox VE 9.2". After the changelog section changed, GPT was asked for a banner from the whole section with no guidance and returned "Cross-Node Inode Coherence and Recovery"; it was applied and pushed. Owner: "WAIT ... WE DO ADD SUPPORT FOR 9.2 right ... I DONT WANT TO RELEASE WITHOUT IT" / "THEN WHY REMOVE IT ... ITS IMPORTANT".
- Why: new platform support (a Proxmox VE version) is what the primary audience, Proxmox users, looks for; a banner built only from fix bullets drops it.
- When asking GPT for a banner, name in the prompt what the owner treats as the headline (new platform/version support first), and say it must appear.
- Compare the returned banner with the previous banner before applying it: anything the old banner named that is still true of the release must still be there, or ask the owner.
- The banner goes in three places: CHANGELOG.md heading, README `> ## <version>:` heading, and the GitHub release title (scripts/release.sh reads it from the CHANGELOG heading).

## No tooling edits while a board runs
Source: `trap-editing-criteria-py-while-a-board-runs-breaks-the-run`

- run.sh records every board row by invoking `tools/criteria.py update ...`, a fresh python process per row, so the file on disk at that instant is what runs. A multi-step edit (rename `FLAKE_WINDOW`/`NEVER_FLAKE` in one Edit, fix the callers in the next) leaves a window where every live board's next write dies with NameError.
- Observed 0.90.132 cycle: the nq_wouldblock fix-off arm's run hit `NameError: name 'NEVER_FLAKE' is not defined` in cmd_update's print, after `save` (so its cell survived, by luck of ordering). Earlier the same day an edit to tools/ broke the Proxmox 7.0 suite while it packed the tree.
- Owner: "make SURE this does NOT affect the current release validation cycle in progress" / "i need .132 to be released cleanly".
- While any board, chain, lap or PVE suite is running, make no edit to tools/criteria.py, tools/defects.py, tools/configuration.py, run.sh or anything they import. Release-cycle tooling changes wait until the release is published.
- If a change cannot wait, build it in a separate checkout and swap it in only when nothing is running (check `tools/mxfs_pgrep.sh run.sh` and the chain pids first).
- If an edit already landed mid-run: restore immediately, py_compile, then grep every log written since the edit for Traceback/NameError and check whether the affected cell was saved before the crash.
