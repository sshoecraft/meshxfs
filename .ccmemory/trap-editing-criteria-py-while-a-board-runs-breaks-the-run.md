---
name: trap-editing-criteria-py-while-a-board-runs-breaks-the-run
description: run.sh calls tools/criteria.py for every row it records; an edit that is mid-way (a renamed constant) crashes live runs. No tools/ edits during a rel…
metadata:
  type: feedback
---

run.sh records every board row by invoking `tools/criteria.py update ...`, a fresh python process per row, so the file on disk at that instant is what runs. A multi-step edit (rename `FLAKE_WINDOW`/`NEVER_FLAKE` in one Edit, fix the callers in the next) leaves a window where every live board's next write dies with NameError. Observed 2026-10-21 (0.90.132 cycle): the nq_wouldblock fix-off arm's run hit `NameError: name 'NEVER_FLAKE' is not defined` in cmd_update's print, after `save` (so its cell survived, by luck of ordering). Earlier the same day an edit to tools/ broke the Proxmox 7.0 suite while it packed the tree.

Owner, on seeing it: "make SURE this does NOT affect the current release validation cycle in progress" / "i need .132 to be released cleanly".

**How to apply:**
- While any board, chain, lap or PVE suite is running, make no edit to tools/criteria.py, tools/defects.py, tools/configuration.py, run.sh or anything they import. Release-cycle tooling changes wait until the release is published.
- If a change cannot wait, build it in a separate checkout and swap it in only when nothing is running (check `tools/mxfs_pgrep.sh run.sh` and the chain pids first).
- If an edit already landed mid-run: restore immediately, py_compile, then grep every log written since the edit for Traceback/NameError and check whether the affected cell was saved before the crash.
