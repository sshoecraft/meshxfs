---
name: feedback-every-delegated-brief-carries-the-no-bash-c-line-even-for-read-only-scouts
description: Owner again: "dont do this again" after a read-only scout ran a bash -c survey loop that tripped the rm check; every Agent brief carries the no-bash-…
metadata:
  type: feedback
---

A scout briefed only "read-only, no git, no pgrep" built its survey as `timeout 60 bash -c '...for n in ...; do ... done'` piped to a scratchpad file. Claude Code raised "This shell -c script runs rm and could not be checked" and stalled the unattended run; the owner answered "dont do this again". The rule already existed (compiled-ccloop-keepgoing-stop-hook-vs-agent-waits, permission prompts section), but the brief left it out, and a subagent sees only its brief.

How to apply:
- Every Agent brief that may run shell, read-only scouts, miners and log-sweepers included, carries verbatim: "Do not write shell functions or `bash -c` / `sh -c` programs; run each command as its own plain Bash call, or write a script under the session scratchpad and run that by path."
- Ask for per-file loops as separate plain commands or a scratchpad script, never an inline multi-line loop.
