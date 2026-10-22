---
name: compiled-compact-before-push-and-read-sessions-by-digest
description: Compact ccmemory to backlog 0 before any push; read sessions by digest only; ccloop cutoff file, no handoff file, ccmemory down = hard stop
metadata:
  type: feedback
tags: [compiled, ccmemory, compaction, commit, push, github, transcript, safeguard, refusal, reasoning_extraction, session-context, ccloop, relay, handoff, cutoff, hard-stop]
---

Loose group, no single topic: five standing user corrections about session conduct around the ccmemory store, past transcripts and the ccloop loop. Sections 1-2 are two corrections of 2026-10-22: section 1 is a pre-push ritual (compaction), section 2 is how to read a prior session. Sections 3-5 come from `compiled-ccloop-relay-cutoff-no-handoff-file-and-ccmemory-hard-stop`, three behavior notes on how a ccloop-run session starts, ends and depends on ccmemory; they share one theme: the loop's real boundaries are not the ones the tooling displays, and the transcript plus ccmemory are the only continuity mechanisms. Section 3 is budget, 4 is handoff, 5 is memory availability.

## 1. Compact ccmemory to `backlog: 0` before any commit that is pushed

User, 2026-10-22 (`feedback-compact-ccmemory-before-every-commit-and-push`), verbatim: "before you do a commit,push (updating github) you need to do a ccmemory compaction so anyone cloning/refreshing wont have to do it"

Procedure:
- Before every commit that will be pushed, call `memory_compaction_plan`. For each group it returns, dispatch one `memory-compactor` agent with that group's seed, running `wave` at a time. Wait for them to finish, then call the plan again. Commit only once it reports `backlog: 0`.
- Applies below the nudge threshold too (`threshold: 20`): a backlog of 1 still gets compacted before a push.
- The compactors' rewrites and deletions in `.ccmemory/` go into the same commit, because `.ccmemory/` always travels with the commit.
- Release commits are no exception: `scripts/release.sh --publish` pushes, so compact before it.

Why: `.ccmemory/` is published with the repo so a fresh clone has the full record (see `compiled-repo-transparency-release-verification-and-transcript-traps`). An uncompacted backlog makes every cloner's first session spend requests compacting it.

## 2. Read a prior session through the digest only; never its thinking blocks

When the user says "read session <id> for context" (`trap-reading-a-session-means-digests-only-never-its-thinking-blocks`): read it through `tools/transcript_digest.py` (text and results modes) plus the queued-message events. Never extract, measure, dump or read the transcript's `thinking` blocks, in any form: a python one-liner, a "full" dump file, a size count, or quoting them back.

What happened (session 1446d0db, 2026-10-22, reading 5d11a39e):
- L247: a one-liner over the raw jsonl that also counted `thinking` content. L264: the response was stopped by the API safeguard, `Details: [reasoning_extraction]`.
- L272: after the stop, the session wrote "full edits, thinking, Bash commands and key results" to a scratchpad file and read it back (L283-L304). That earned four more stops, at L323, L343, L373 and L395 (five in all).
- The user said "stop doing w/e you are doing" (L357), then "you did it again" (L378), then exited. The session produced nothing.
- Control: 5d11a39e read b990c391 with the digests only and was never stopped. So did 10165cad, reading 1446d0db and 5d11a39e.

Apply:
- The digest omits thinking on purpose. What a past session decided is in its text blocks, its tool calls and edits, and the tree. Its reasoning is not needed and is not to be reconstructed.
- After a safeguard stop, the next response takes a DIFFERENT approach. Never retry the same extraction reworded; the stop message itself says "Do not produce that content again, even reworded."
- When the user says stop, stop the current line of work entirely. Do not continue it under another description.
- See also: `compiled-request-economics-delegation-and-safeguard-flags` section 5 (refusal categories and CLI routing; `reasoning_extraction` has no fallback model), and `compiled-repo-transparency-release-verification-and-transcript-traps` (queued user messages are not `type=user`).

## 3. ccloop budget: the relay fires at the run's cutoff file, not at the context window

From `trap-the-ccloop-relay-fires-at-the-runs-cutoff-file-not-at-the-context-window-so-read-it-at-session-start` (via `compiled-ccloop-relay-cutoff-no-handoff-file-and-ccmemory-hard-stop`):

- The context tool showed 46% of a 1M window used, which reads as plenty. `.ccloop/runs/<run-id>/cutoff` held `500000`, and `hook-events.log` showed the previous session `fired` and `halt` at exactly that number. The session had about 40K tokens left, not 540K, when it found out. That was after a 348 s module build and a deploy, with rig verification still to launch.
- At session start read `.ccloop/runs/$CCLOOP_RUN_ID/cutoff` and plan against that number. Orientation (memory list, prior transcript digest, files that must be understood) measured about 150K.
- Spend the first half of the budget on the code change and start the build early. A header change in `dlm/dlm.h` or `dlm/disklock.h` rebuilds most of the module (348 s measured), and the build can run while tests are written.
- Anything that must outlive the session is launched `nohup setsid`, with output and a one-line-per-step summary under `tests/evidence/`. The next session reads files instead of re-running. A background Bash task dies at the relay.
- Keep tool output small from the first call. Every large Read is paid for against the 500K, not the 1M.

## 4. Handoff: there is no handoff file

From `handoff-md-removed-context-is-auto-derived` (user directive; via `compiled-ccloop-relay-cutoff-no-handoff-file-and-ccmemory-hard-stop`):

- ccloop derives the next session's starting context automatically from the transcript. Every mention of a handoff document was removed from ccloop, and the old CLAUDE.md rule that required maintaining `handoff.md` was deleted. The resulting numbering gap is deliberate; do not renumber.
- Do not create, write or update `.ccloop/handoff.md` or any equivalent (`state.md`, `HANDOFF.md`, `resume.md`, a session-summary file). Do not spend a turn on an end-of-session summary. The transcript is the handoff.
- This joins the earlier `state-md-deprecated-do-not-maintain` directive. The user has had to say it twice; do not introduce a third variant.
- Durable findings go to ccmemory. Defect state goes to the defect queue. Neither is a handoff document.

Together with the budget note (section 3): since the next session starts from the transcript, what must survive the relay is evidence files under `tests/evidence/` and lessons in ccmemory, not a hand-written summary.

## 5. ccmemory unavailable is a hard stop

From `feedback-ccmemory-unavailable-is-hard-stop` (user directive; via `compiled-ccloop-relay-cutoff-no-handoff-file-and-ccmemory-hard-stop`):

- If ccmemory or the MCP interface exposing it drops or reports "disconnected" mid-session, stop. Report that ccmemory is unavailable and halt. This applies every time.
- A prior session saw the harness drop the MCP transport (ccmemory batched with several other servers) and concluded it was not a hard stop because the data is flat `.md` files on disk. The user explicitly overrode that conclusion.
- Reasons: memory is load-bearing for multi-session ccloop work. Without it prior lessons cannot be recalled reliably and solved problems get re-derived. The regen-index hook does not fire, so bypassing `memory_write` with direct file writes leaves `MEMORY.md` stale and risks silent divergence.
- Do not continue substantive work. Do not write memories by direct file write as a workaround and carry on. Do not declare "no memory loss."
