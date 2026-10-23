---
name: compiled-ccloop-keepgoing-stop-hook-vs-agent-waits
description: ccloop keepgoing Stop hook re-prompts at once when a turn ends to wait on agents (~2.5K tokens/round); fill waits with work, cap reports
metadata:
  type: feedback
tags: [compiled, ccloop, keepgoing, stop-hook, background-agents, delegation]
---

Assorted-tail group of one note (the clusterer could not fit it to a topic): what a turn must know about waiting for background agents while ccloop's `keepgoing` Stop hook is active.

## Failure observed

Session 1a544818, run 9aa0fe9b, 2026-10-23 `trap-ending-the-turn-does-not-wait-for-agents-under-ccloop-keepgoing`:

- Six background `Agent` tasks were live. Every attempt to end the turn to wait for their notifications was answered immediately by the `ccloop keepgoing` Stop hook: "HAVE YOU MET THE CRITERIA?", with the criteria printed twice.
- No agent notification arrived between rounds.
- Each round cost about 2.5K tokens of the run's 500K cutoff. Five rounds burned ~12K tokens and produced nothing.
- The previous session (5df8f46c) shows the same pattern: a run of "Not met. Nothing new has finished" replies at its end.

## Conflict with the global rule

The global rule says ending the turn to wait is fine while an Agent's `tasks/<id>.output` is held open. In practice the `keepgoing` hook still blocks the stop, so ending the turn is not a wait `trap-ending-the-turn-does-not-wait-for-agents-under-ccloop-keepgoing`.

## What to do

- Do not end the turn to wait for agents or rig lanes. Fill the wait with work the agents do not cover: design reading for the next code change, a lesson write, a CHANGELOG entry, preparing the next proposal's argument `trap-ending-the-turn-does-not-wait-for-agents-under-ccloop-keepgoing`.
- Launch background agents early and in parallel, and order the session so the work they unblock comes after other independent work `trap-ending-the-turn-does-not-wait-for-agents-under-ccloop-keepgoing`.
- Cap every delegated report's length in the brief (e.g. "under 60 lines"): a read-only lane survey with no cap returned ~15K tokens in one notification `trap-ending-the-turn-does-not-wait-for-agents-under-ccloop-keepgoing`.
- Read `.ccloop/runs/<run>/cutoff` at session start; plan against it, not the 1M window `trap-ending-the-turn-does-not-wait-for-agents-under-ccloop-keepgoing`.
