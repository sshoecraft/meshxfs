---
name: compiled-compact-before-push-and-read-sessions-by-digest
description: Compact ccmemory to backlog 0 before any pushed commit; read past sessions via transcript_digest.py only, thinking blocks trip reasoning_extraction
metadata:
  type: feedback
tags: [compiled, ccmemory, compaction, commit, push, github, transcript, safeguard, refusal, reasoning_extraction, session-context]
---

Assorted group, no shared topic: two standing user corrections of 2026-10-22 about session conduct around the ccmemory store and past transcripts. Section 1 is a pre-push ritual (compaction); section 2 is how to read a prior session.

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
