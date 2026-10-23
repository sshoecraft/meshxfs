---
name: compiled-ccloop-run-never-ask-owner-questions
description: In a ccloop run never use AskUserQuestion or end a reply with a question to the owner; an owner-only decision is recorded as a blocker, not asked
metadata:
  type: feedback
tags: [compiled, ccloop, owner, askuserquestion, unattended]
---

Assorted tail group (a single note the clusterer could not fit to a sibling topic): how an unattended ccloop run treats the owner, who is AFK, and what to do with a decision only the owner can make.

## The correction

- Owner, 2026-10-23, after an AskUserQuestion dialog about two DRBD release decisions (an exception, and pace grading) appeared on the screen mid-run: "OMG WTF IS THIS????? I AM FUCKING AFK ... DO NOT ASK ME ANY STUPID FUCKING QUESTIONS". `never-ask-the-owner-questions-in-a-ccloop-run`
- Context: the owner had sent short remarks into the running turn ("at this rate you'll never do another release", "did you even check ccusage?"). Those are comments typed in passing, not an open channel. The owner is still AFK, and a dialog left on the screen stalls the loop. `never-ask-the-owner-questions-in-a-ccloop-run`

## What to do

- In a ccloop run, never call AskUserQuestion and never end a reply with a question to the owner. `never-ask-the-owner-questions-in-a-ccloop-run`
- A decision only the owner can make (a policy exception, a gate rule) goes into the record's next step as a blocker, naming exactly what is missing. Work then continues on everything else. `never-ask-the-owner-questions-in-a-ccloop-run`
- When the owner remarks mid-turn, answer in plain text and keep working. `never-ask-the-owner-questions-in-a-ccloop-run`
