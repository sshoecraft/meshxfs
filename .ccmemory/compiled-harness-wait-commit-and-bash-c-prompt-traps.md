---
name: compiled-harness-wait-commit-and-bash-c-prompt-traps
description: Unattended shell/harness: inline bash -c, bare wait hang, polling, timeouts, vacuous-green evidence, commit/push/release delegated, no password
metadata:
  type: feedback
tags: [compiled, bash, harness, wait, commit, permissions, allowlist, timeouts, unattended, evidence, delegation, secrets]
---

Unattended shell and harness discipline: what makes a session, a delegated subagent or a test-harness script stall on a permission prompt, hang, run on a wrong timeout, report green on evidence of something that never happened, or leak a secret. Folds `compiled-unattended-shell-discipline-and-harness-traps` (prompts, allowlist, timeouts and waiting, shell and process traps, standing directives), `compiled-vacuous-evidence-traps-stored-board-reprint-unaged-control-arm-unset-mask-and-inline-agent-programs` (vacuous-green evidence, no inline shell in agent prompts) and this article's earlier body (bare `wait` hang, delegated commit/push/release, inline `bash -c` with `rm`). Two of the three began as assorted tails the clusterer could not fit to one topic.

## Permission prompts stop unattended runs

Sources: this article's earlier body; `compiled-unattended-shell-discipline-and-harness-traps` (the `run()` and `"$@"` incidents, the rules, the allowlist); `compiled-vacuous-evidence-traps-stored-board-reprint-unaged-control-arm-unset-mask-and-inline-agent-programs` (the agent-prompt incident).

A prompt stalls an unattended session until a human looks. Claude Code's safety checker cannot resolve what an inline `bash -c` program executes: the body is opaque to it, and an `rm` inside it is flagged whatever the allowlist says. The allowlist (`.claude/settings.json`) holds `Bash(tests/:*)`, `Bash(scripts/:*)`, `Bash(tools/:*)`.

Four incidents, one class:
- The owner, after an inline `bash -c '<30-line script>'` tool call raised "This shell -c script runs rm and could not be checked" and an auto-deny countdown: "DONT DO THIS AGAIN". `trap-inline-bash-c-with-rm-triggers-unattended-permission-prompt`
- A grind subagent ran `bash -c` with a function `run() { local name="$1" cmd="$2"; bash -c "$cmd" ... }` and the run stopped on "This shell -c script runs rm and could not be checked". User: "dont do this again ... write it to a script or something". `feedback-multi-step-shell-logic-goes-in-a-repo-script-never-an-inline-bash-c-program`
- `nohup setsid bash -c 'step() { ...; "$@"; ...}; step scripts/drbd_rig.sh x'` was refused because `"$@"` could be `rm`, and an unattended session cannot approve it. `trap-a-bash-c-chain-that-runs-a-function-with-dollar-at-is-refused-by-the-rm-safety-check`
- User correction 2026-10-09 ("dont do this again", "run a script or something"): a grind agent asked to run `dlm_ledger_test` under CPU load copied the example from the agent prompt, `sh -c 'while :; do :; done' &` times 8 in a for-loop chain. The permission checker could not verify the `sh -c` program and stopped the unattended session on an approval prompt. Agents copy example commands verbatim, so the prompt text was the cause. Same class as the `run()` incident above, unapplied to the prompt itself. `feedback-never-put-an-inline-sh-c-program-in-a-delegated-agent-prompt`

What to do:
- Anything longer than a one-liner, and anything that removes files (locally or over ssh), goes in a script under `tests/` or `scripts/` (check for an existing one first) and is run as `tests/<name>.sh args`, alone, not chained with `&&`/`;` to other commands.
- Shell logic beyond a plain command or short pipeline (functions, eval-building loops, `"$@"`, `run()` wrappers) goes in a script under `tests/`, `tools/` or `scripts/`, written with Write and run by path.
- Never `bash -c '...'` or `bash -s <<EOF` wrapping multi-step work in a tool call.
- Never `rm` with a variable or glob path in a tool call; inside a committed script it is fine.
- Never execute a variable as the command; use a fixed command with variable arguments (`for s in "self-outage-test" "takeover-test self"; do scripts/drbd_rig.sh $s; done`) and an `if` branch for an env-prefixed variant.
- `cmd && L=x && nohup ... &` backgrounds the whole && list, leaving `$L` unset in the parent; separate with `;`.
- Every subagent prompt delegating shell work must carry verbatim: "Do not write shell functions or `bash -c` programs; run each command as its own plain Bash call, or write a script file under the repo's tests/ or tools/ and run that." Subagents do not see mid-session corrections.
- Never write `sh -c`, `bash -c`, a busy-loop or a multi-command loop into an Agent prompt, even as an example. Write it as a script in `tests/` or `scripts/` first (`bash -n` it) and tell the agent to run that script with arguments.
- For CPU load use a repo script (or `stress-ng` if installed).
- If an agent is stopped mid-run, confirm any background load it started is gone (`ps -o pid,stat,cmd -C sh`, never pgrep or `ps -e`). `ps` is off the allowlist (below), so that check prompts in an unattended run; `tools/mxfs_pgrep.sh` is the allowlisted route.

### The allowlist matches each command piece on its FIRST word
`feedback-every-bash-command-starts-with-an-allowlisted-program-never-cd-sleep-or-an-env-prefix`
- On it: `tests/:*`, `tools/:*`, `scripts/:*`, `./run.sh:*`, `python3`, `grep`, `timeout`, `virsh`, `make`, `chmod`, `cat`, `ls`. NOT on it: `cd`, `sleep`, `export`, inline `VAR=value cmd`, `( ... ) &` subshells, `zcat`, `strings`, `ps`, `sudo`, `systemctl`. In one session 55 of 57 Bash calls began `cd /home/steve/src/mxfs; ...` and the user had to approve them by hand.
- The shell already starts in the repo root; never `cd`. Use absolute scratchpad paths.
- Rig launches via `tests/mpath/lap_chain.sh laps|row ...`; kernel logs (plain or .gz) via `tools/kgrep.py`, not `zcat | sed | grep | cut`; processes via `tools/mxfs_pgrep.sh`, never `ps`; binary strings via `grep -ac`, never `strings`; no `sudo` for the cold-audit log (world-readable now).
- Anything multi-step or env-dependent is a script called with arguments. This is distinct from the ccloop delegate hook that refuses an 8th consecutive Bash call.

## Waiting, timeouts and parallelism

Sources: this article's earlier body (bare `wait`); `compiled-unattended-shell-discipline-and-harness-traps` (everything else in this section).

### Bare `wait` hangs in scripts that log through `exec > >(tee ...)`
`trap-bare-wait-also-waits-for-the-tee-process-substitution`

Seen 2026-10-15 in tests/join_freeze_userspace_thaw.sh: two parallel `on host ... &` builds followed by a bare `wait` hung for over an hour after both builds printed build_rc=0. bash (5.1+) counts the process substitution behind `exec > >(tee -a "$EV/run.log")` among the children a bare `wait` waits for, and that tee exits only when the script's stdout closes, i.e. never while the script waits.

The same day run.sh hung at every bare `wait` because a background `setsid tools/vm_pool.sh release --after $$` helper (which waits for run.sh to exit) was its child: same shape, a child that ends only after the waiter.
- Never write a bare `wait` in a script that has a process substitution or any long-lived background child. Collect the PIDs (`pids+=($!)`) and `wait "${pids[@]}"`.
- A helper that must outlive or wait for its starter is started from a subshell that exits at once: `( setsid helper --after $$ ... & )` -- never a direct child.
- When a run sits far past its budget with nothing printed, check /proc/<pid>/wchan for `do_wait` before suspecting the system under test.

### Derive every timeout; parallelize
`feedback-parallelize-and-derive-timeouts`
- Never reuse a prior session's timeout; derive each as measured infra + 2x native workload. Reusing a 590 s timeout for a cluster reset drew a correction from the user. `cluster_reset_n.sh 16` is about 180 s ceiling; tighten after each healthy pass and record it in `tests/criteria/TIMEOUT_BUDGETS.md`.
- Per-node loops run as backgrounded subshells plus `wait` (on collected PIDs, never a bare `wait`, in a script with a `tee` process substitution or other long-lived child; see above); audit a script for a serial per-node loop before running it; independent diagnostics run concurrently (parallel Bash calls, background tasks, subagents).

### An outer timeout below the wrapped operation's own bound kills it just before it explains itself
`trap-an-outer-timeout-below-the-wrapped-operations-own-bound-kills-it-just-before-it-reports-why`

The DRBD boot program ran `mount` under `timeout=180` while the module's own refusal was due at ~184 s (scan ~64 s + fence 120 s). The kill raised `TimeoutExpired` out of `cmd_boot`, bypassed the 6-attempt step-down-and-retry loop, and left the node Primary needing an operator. Sum the inner bounds and set the outer past the sum, say so in a comment, catch the timeout as a failed attempt inside the retry loop, and drive the retry to its second attempt in a test (`SELF_OUTAGE_PEER_PRIMARY=1 scripts/drbd_rig.sh self-outage-test`).

### Never wait by polling
`feedback-never-background-wait-poll`
- No `until ... sleep` waiter, no `TaskOutput block=true`, no watching `tasks/*.output`, no backgrounding a batch and polling for a tally. Each poll costs a full request, and `TaskOutput` on a local agent dumps raw JSONL (~15K tokens).
- Backgrounding itself is fine since the Stop gate counts only an `.output` file held open by a live process, and it blocks (without counting against max continues) while one exists. Fire the Agent or background Bash and do independent work.
- Ending the turn to wait is valid only for locally live tasks; rig work (32-node `run.sh`, ssh/nohup launches) counts zero and gets the session re-fed "continue". Outside ccloop there is no gate and ending the turn hands control to the user. Nothing required may be in flight at a relay boundary; a task exiting is not a task succeeding, so validate output.

### A Workflow is invisible to the Stop gate and dies at the relay
`trap-a-workflow-is-invisible-to-the-ccloop-stop-gate-and-dies-at-the-relay`

An in-flight Workflow is invisible to the Stop gate (13 of 13 samples read zero live) and dies at the relay: the watcher SIGTERMs the child plus descendants, SIGKILL after 5 s, and auto-compact is disabled in ccloop sessions. Size a workflow to remaining token headroom, have its agents write findings into the repo as they go, and read the durable record with `tools/workflow_journal.py`. Workflow agents inherit the session model, so a 10-agent run costs ~134 requests, not fewer than steering by hand; override `model`/`effort` on mechanical stages. A genuine `run_in_background` Bash task was NOT measured by that probe and does count.

## Shell and process traps

Source: `compiled-unattended-shell-discipline-and-harness-traps`.

- **`grep` in the Bash tool and every subagent is a function over ugrep, and its `-v -q` exit status on empty input is 0.** `grep -avq PAT` on EMPTY input exits 0 (GNU grep: 1), so a watcher stop condition `grep '^LAP ' summary | grep -avq ' rc=0 '` fired with zero laps and abandoned a 78-minute chain. Counts agree; only `-v -q` exit status differs. Decide on a count (`n=$(... | grep -avc PAT); [ "$n" -gt 0 ]`) or call `command grep`. Scripts run as their own `#!/bin/bash` and do not inherit the function, so test pasted conditions on empty input. sed back-references stop at `\9`. `trap-grep-in-the-tool-shell-is-a-ugrep-function-and-its-v-q-exit-code-on-empty-input-is-zero`
- **Never edit a shell script while bash is executing it:** bash reads by byte offset, so an insertion can resume mid-token and run text nobody wrote. It bit twice (a trap added to `tests/fence_lost_response.sh` mid-lap). Stop the run (`TaskStop`), edit, re-run with a new label; a lap that overlapped an edit is untrustworthy even if it completes. Applies equally to a script being run by a subagent or a `run_in_background` Bash. `trap-editing-a-shell-script-while-bash-is-executing-it-shifts-the-interpreters-byte-offset`
- **A `call_usermodehelper` child starts with fds 0, 1, 2 closed.** `tools/mxfs_lu_reset_witness.py` died on `sys.stdout.write` (CPython leaves `sys.stdout` None), so every upcall timed out at 45 s with `no-report-within-bound` although exec had succeeded. Worse, the first `os.open()` gets fd 0 and the next fd 1; there the first open was the block device being reset, so a later stdout write would have landed inside the LUN. In any program a kernel may exec: fill 0/1/2 first (`os.fstat`, else `/dev/null` + `dup2`), write the load-bearing report channel before the console, each in its own try/except, and treat `UMH_WAIT_EXEC` success as only meaning `execve` worked. Fixed as `secure_fds()` and verified by `tests/lu_reset_witness_probe.sh`. `trap-a-kernel-upcalls-child-starts-with-fds-0-1-2-closed-so-a-helper-dies-on-its-first-print-and-its-first-open-becomes-stdout`

## Evidence that is green but vacuous

Source: `compiled-vacuous-evidence-traps-stored-board-reprint-unaged-control-arm-unset-mask-and-inline-agent-programs`.

Three traps share one theme: a result that reads as pass/green while the precondition for it never held. Common rule: a pass counts only when the run's own exit line, the arm's precondition counters, or a firing probe shows the thing under test actually happened.

### Stored board reprinted after a failed run
`trap-run-sh-reprints-the-stored-board-after-a-failed-run-so-its-verdict-line-is-not-this-runs`

`run.sh` prints the board from `data/criteria.json` after ANY exit, including a setup failure. In the 0.90.115 release gates, `tests/release_rig_gates.sh` graded boards from the log's `VERDICT:` line. Two configs (2/net/mesh/direct@g2 and 16/disk/caw/direct@g16) read "every criterion green" while `run.sh` had exited in 28 s with `ERROR: no pool LUN for [test1 test2]` and `=== rc=1 run.sh ...`. test2 was held off by the rig fence (libvirt hook, left behind by a failed drbd outage test). The green cells were a previous build's.
- A board run counts only if its own `=== rc=0 run.sh <cfg> ...` line is present AND the verdict is green.
- Sanity-check log size: a real 31-row board log is about 11-12 KB, a setup failure about 4.5 KB.
- `tools/boards_stage_chain.sh` exits 0 whatever its boards found.
- After any failed DRBD rig test, check `virsh domstate` of both nodes and `tools/rig_fence_virsh.sh status <node>`. Release a fenced node with `rig_fence_virsh.sh release <node> <episode> <survivor>` only once the survivor has nothing to recover, then `scripts/drbd_rig.sh down`.

### Control arm on an unaged pair
`trap-a-rejoin-read-stall-needs-an-aged-pair-so-a-control-arm-right-after-a-deploy-is-vacuous`

The physical-pair rejoin read stall (0.90.113: first read 69-95 s after `withdraw-p0`) reproduced 2/2 on a pair with many withdraw/rejoin laps behind it and 0/6 in an A/B run right after `scripts/pve_pair_update.sh` restarted both units, with the fix off as well as on. The deploy resets ledger and hand-off state: the rejoiner's swap lock fell to about 1 ms within 30 s on the fresh pair, versus 18-45 ms for 90 s+ on the aged one (census 3.7 pages/s vs about 20). Cause: the rejoiner's single hand-off worker activates the survivor's view-change FROZEN stream while the survivor's FREEZE_REQs wait behind it; the length grows with repeated rejoins.
- A control arm is evidence only if it shows the precondition: check `P-HRX-ASK-WAIT` / `P-TAUTH-PAGE-PARKED` counts in the arm's window, not just pass/fail.
- Age the pair with alternating `withdraw-p1 withdraw-p0` laps (4th lap stalled 69 s with the knob at 0), then run the treatment arm at once on the same aged state (5/5 passed, 0 asks waited >=1 s).
- `tests/pve_pair_failover.sh` used to collect step klogs before the verify, so a passing arm's reads were never in its evidence; it now collects again after the census, and a slow read leaves stacks via `tests/pve_read_stall_probe.sh`.
- Fix: 0.90.114 `handoff_rx_ask_first` in `dlm/v5_mount.c`.

### Predicate that is never set on the path under test
`trap-mphase-resolved-mask-never-names-the-replayers-own-recovery`

`ctx->mphase_resolved_mask` in `dlm/v5_mount.c` looks like "slots whose recovery is complete" but is set ONLY by `v5_recovered_cb`, when this node's heartbeat monitor logs `P163-RECOVERED`. A survivor that recovers the slot itself as replayer logs `P163-RECOVERY-COMPLETE` and never `P163-RECOVERED`. The mask is the mount barrier's witness lineage, not a recovery record. The 0.90.112 fix for D-REJOINER-IN-A-RECOVERED-SLOT-DECERTIFIES-THE-SURVIVORS-TAKEOVER keyed its election skip on that mask; on a 2-node pair the survivor is always the replayer, so the skip never applied, two clean A/B fix arms were luck, and a fix-on lap with the rejoiner's announce held 10 s deadlocked like the control. `v5_bootstrap_ready` had the same blind spot (`P-BOOTSTRAP-NOT-READY ... resolved=0`).
- For "this mount recovered slot N" use `v5_recovered_here()` (`recovered_here_mask`, set at `P163-RECOVERY-COMPLETE`, voided while `dl->recovery_pending[N]`).
- Prove a predicate fires with a probe before trusting an A/B whose fix arms merely passed; `P-BOOTSTRAP-NOT-READY` and `bn=` on `P-TAUTH-TAKEOVER-DECERTIFIED` exposed this.
- Deterministic window: `JOIN_ANNOUNCE_DELAY_MS=10000 tests/pve_pair_failover.sh withdraw-p0` (knob `dbg_join_announce_delay_ms`, one-shot, on the withdrawn host) holds the rejoiner between heartbeat claim and discovery announce. Holding the SURVIVOR's join (`dbg_join_flip_delay_ms`) is the wrong window: the rejoiner is already in `active_nodes`, `bn_in_view=1`, nothing deadlocks.

## Commit, push and release are delegated: never ask

Sources: this article's earlier body: `feedback-commit-only-after-the-versions-full-release-validation` (2026-10-15), owner 2026-10-22.

- 2026-10-15 the owner declined mid-version commits of 0.90.130: "no. not until .130 has done a FULL release validation cycle. we're going to do more in .130 than this."
- 2026-10-22 the owner, after a session listed "Commit. Nothing is committed." under "still waiting on you" twice: "not sure why you keep mentioning commit; you control commit,push,release INCLUDING versions 100% ... you do not need to ask me anymore". Recorded in CLAUDE.md as RULE: COMMIT, PUSH AND RELEASE NEED NO APPROVAL.

How to apply:
- Never list commit, push, release or a version bump as a decision waiting on the owner, and never ask about them. Decide and do them.
- Timing is the session's judgment: commit at a coherent, verified point, and commit `data/defects.json` with the change that caused it (CLAUDE.md, the queue section). A version is still released only through its full release process (tools/release_run.py and its gates); delegation removes the asking, not the release bar.
- Every commit still stages the whole tree, `.ccmemory/` included, and carries no Claude attribution. Run the password check below before each commit.

## Standing directives

Source: `compiled-unattended-shell-discipline-and-harness-traps`.

- `state.md` is a deprecated pre-ccloop handoff artifact. Do not read, maintain, or write it at relay boundaries even when a run prompt says "read state.md"; handoff is ccloop's resume summary, durable knowledge is ccmemory, build history is `CHANGELOG.md`, defect state is the defect queue. Deleting the file is the user's call. `state-md-deprecated-do-not-maintain`
- The lab node root password lives only in `~/.config/mxfslab/secrets` (mode 600), never in prose, docs, comments, tables, examples, awareness docs, memory bodies, handoffs or commit messages. The repo is PUBLIC and four doc files had leaked it, three of them sentences asserting it was never committed; prose is where the leak lives, not code. Write "password from the lab secrets store" and point at `tools/mxfs_secrets.sh passfile`. Before each commit grep the tree and `git diff --cached` for the password and for sshpass litter (directories with spaces or shell metacharacters in the name), reading the password at run time so no part of it is ever written down: `PW=$(tools/mxfs_secrets.sh get node); grep -rInF --exclude-dir=.git -e "$PW" .; git diff --cached | grep -nF -e "$PW" -e 'password='` (both must be empty). The check once spelled out the password's first four characters as its pattern, which put them in the public history. A separate defect, calling `mxfs_sshpass.sh` without the passfile arg writing password files named after the command, is already fixed by a guard in `secrets_passfile()`. `feedback-never-write-lab-password-into-any-file-in-tree`
