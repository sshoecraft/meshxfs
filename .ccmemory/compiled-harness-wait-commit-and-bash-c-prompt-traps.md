---
name: compiled-harness-wait-commit-and-bash-c-prompt-traps
description: Assorted: bare wait hangs on tee process-substitution; no mid-version commits before full validation; no inline bash -c with rm (permission prompt).
metadata:
  type: feedback
tags: [compiled, bash, harness, wait, commit, permissions]
---

Assorted group (the clusterer could not fit these to one topic): three owner-facing behavior lessons about writing shell harnesses, running Bash tool calls unattended, and when to commit.

## Bare `wait` hangs in scripts that log through `exec > >(tee ...)`
Source: `trap-bare-wait-also-waits-for-the-tee-process-substitution`

Seen 2026-10-15 in tests/join_freeze_userspace_thaw.sh: two parallel `on host ... &` builds followed by a bare `wait` hung for over an hour after both builds printed build_rc=0. bash (5.1+) counts the process substitution behind `exec > >(tee -a "$EV/run.log")` among the children a bare `wait` waits for, and that tee exits only when the script's stdout closes, i.e. never while the script waits.

The same day run.sh hung at every bare `wait` because a background `setsid tools/vm_pool.sh release --after $$` helper (which waits for run.sh to exit) was its child: same shape, a child that ends only after the waiter.

How to apply:
- Never write a bare `wait` in a script that has a process substitution or any long-lived background child. Collect the PIDs (`pids+=($!)`) and `wait "${pids[@]}"`.
- A helper that must outlive or wait for its starter is started from a subshell that exits at once: `( setsid helper --after $$ ... & )` -- never a direct child.
- When a run sits far past its budget with nothing printed, check /proc/<pid>/wchan for `do_wait` before suspecting the system under test.

## Do not commit a version's work in pieces
Source: `feedback-commit-only-after-the-versions-full-release-validation`

The owner, 2026-10-15, asked whether to commit the 0.90.130 fixes and defect-queue changes as they landed: "no. not until .130 has done a FULL release validation cycle. we're going to do more in .130 than this."

Why: a version is shipped as a whole; partial commits of an unvalidated version are not wanted, and the version is expected to gather more work before it is validated.

How to apply:
- Do not ask to commit mid-version, and do not propose committing `data/defects.json` with each fix while a version is open; keep the tree's changes until the owner directs the commit after the full validation (boards, platforms, packages, DRBD, Proxmox).
- Keep working inside the open version (no bump) for further work the owner adds to it.
- Ask at most once, when the full validation is green.

## No inline `bash -c` with `rm` in a tool call
Source: `trap-inline-bash-c-with-rm-triggers-unattended-permission-prompt`

The owner, after an inline `bash -c '<30-line script>'` tool call raised "This shell -c script runs rm and could not be checked" and an auto-deny countdown: "DONT DO THIS AGAIN".

Why: a prompt stalls an unattended session until a human looks. The allowlist (`.claude/settings.json`) holds `Bash(tests/:*)`, `Bash(scripts/:*)`, `Bash(tools/:*)`, but a `bash -c` body is opaque to the checker, and an `rm` inside it is flagged whatever the allowlist says.

How to apply:
- Anything longer than a one-liner, and anything that removes files (locally or over ssh), goes in a script under `tests/` or `scripts/` (check for an existing one first) and is run as `tests/<name>.sh args`, alone, not chained with `&&`/`;` to other commands.
- Never `bash -c '...'` or `bash -s <<EOF` wrapping multi-step work in a tool call.
- Never `rm` with a variable or glob path in a tool call; inside a committed script it is fine.
