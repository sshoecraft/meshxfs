---
name: feedback-a-delegated-shell-pipeline-goes-in-a-repo-script-never-an-inline-bash-c
description: USER (2026-10-11): a grind agent's inline `xargs ... bash -c '...'` raised a permission prompt; "Don't do this again. Write a script". Delegate scrip…
metadata:
  type: feedback
---

What happened: I delegated "compress big evidence files" to a grind agent with only steps in prose. It improvised `tr | xargs -0 -P4 -I{} bash -c 'timeout 300 pigz "$1"; echo ...' _ {}`; Claude Code's safety check cannot parse a `bash -c` body ("This shell -c script runs rm and could not be checked") and stopped on a permission prompt for the user. My own `timeout 300 bash -c '...'` sweep was refused the same way earlier that session.

User: "Don't do this again. Write a script or something, but don't do this."

Do instead:
- Any multi-step or parallel shell work that will run again (or that an agent would otherwise improvise) goes into a script in tools/ or tests/ FIRST; the agent or I then run that one script. Example written for this: tools/compress_evidence.py (lossless gzip of old plain-text evidence, verify, min-age guard).
- An agent prompt must forbid `bash -c`/`sh -c`/`xargs ... sh -c` explicitly and name the exact script to run; prose steps let a weaker model reach for inline shells.
- Data-processing one-offs: `python3 - <<'EOF'` heredocs pass the checker; `bash -c '...'` does not.
