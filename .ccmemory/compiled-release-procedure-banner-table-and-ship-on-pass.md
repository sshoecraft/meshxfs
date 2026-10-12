---
name: compiled-release-procedure-banner-table-and-ship-on-pass
description: Release rules: ship a gated version before further changes; GPT writes the banner from the changelog section; configurations table; no "and nothing else".
metadata:
  type: feedback
tags: [compiled, release, changelog, readme, feedback]
---

Release procedure corrections, all from the user on 2026-10-10 around the 0.90.116 release. Four notes folded in; they are one workflow: ship the verified build, then announce it properly.

## 1. A version that passed its gates ships before any further change

[[feedback-a-version-that-passed-every-gate-ships-before-any-further-change]]: 0.90.116 passed RELEASE_RIG_GATES (DRBD verify + 6/6 boards 31/31) and a clean physical-pair leg, then was not released. The no-git rule was read as a reason to wait, and the ccloop "keep working" framing led to further defect fixes in `dlm/dlm.c`, `dlm.h`, `v5_mount.c` under the same unreleased version. The verified build became unshippable from the tree; cost ~2 hours plus a manual restore.

- A verified build is the deliverable; more fixes are the next version.
- The no-git rule is a reason to ASK (one line: go to commit, push, publish), never a reason to sit on a verified release. The loop's "keep working" never outranks shipping what passed.
- While waiting for the go, touch only things outside the verified module source (evidence, defect records, docs), or keep new source work in `<file>.backup` copies.
- Recovery after the fact: restore sources from the scratch build dir that produced the verified srcversion; `touch` the restored files first (`cp -p` keeps old mtimes and make reuses newer objects, producing the WRONG srcversion); prove identity by rebuilding to the same srcversion; save the newer files as `<file>.backup`. Nothing since the release point may be lost.
- Then run the remaining steps: `tests/full_verify.sh` platforms, `scripts/release.sh --publish`.

## 2. The headline sells the whole release to its users

[[feedback-release-headline-sells-the-whole-release-to-its-users-not-the-last-internal-fix]]: the published 0.90.116 headline was an engineering note about the allocator trylock (the last fix), for a release carrying eight versions of DRBD two-node work. User reaction: how is that a selling point to Proxmox users.

- `scripts/release.sh --publish` takes the version's CHANGELOG section as the GitHub release notes and its heading as the headline. Intermediate versions (marked "IN PROGRESS, NOT RELEASED") never reach users on their own, so the released section is the only announcement of their work.
- The heading covers everything since the previous RELEASE, and it is written by GPT from the changelog section (section 3), never drafted by us.
- Open the section with a plain-language summary for someone upgrading from the last release: one bullet per user-visible improvement with the version that made it, then what it was validated on. Engineering detail follows under "### <version> in detail".
- Never write "and nothing else" / "no other X was tested" after a validation list; scope is implied. Name only configurations explicitly NOT claimed, when it matters.
- Already shipped with a bad headline: `gh release edit v<V> --title ... --notes-file <section>`.

## 3. GPT writes the banner from the changelog

[[feedback-when-you-release-ask-gpt-for-advice-on-the-release-banner]] (procedure revised by the user 2026-10-12: "whatever you did to get this result is what I want to see in the future"). Before publishing, `mcp__ask_gpt__query` with:

- the prompt **"Write a banner describing the enhancements made in this release. Here is the changelog for the release, MXFS <version>:"**, then
- the version's CHANGELOG section WITHOUT its `##` heading (that is the banner being written): user-facing summary and configurations table verbatim; the "in detail" part with test-tooling and lab-host paragraphs dropped and the lab host named generically;
- nothing else: no draft of ours, no audience description, no length limit.

GPT's title line becomes the GitHub release title, the CHANGELOG heading and the README release heading. 0.90.124's run gave "MXFS 0.90.124 — Multipath SAN Support, Stronger Recovery, Better Scalability", which the user liked. What failed before: sending our draft for polishing produced "restored multipath for 2–16-node SANs, ..."; "restored/returns/is back" is our history and tells users it was broken; outcome sentences read as banners for managers.
- The "consult another model when stuck / never consult another model" rule in CLAUDE.md was REMOVED by the user on 2026-10-10 to allow this. Older memories saying never to consult another model describe the retired rule.

## 4. Released configurations go in a table

[[feedback-every-release-lists-its-released-configurations-in-a-table]]: the README's prose "What 0.90.116 was validated on" list crammed six shared-LUN configurations into one run-on bullet. On every release, in both the README release section and the CHANGELOG section used as release notes:

- One table row per released configuration (`2/net/mesh/direct` ... `16/disk/caw/direct`, `2/net/mesh/drbd`), columns: nodes, how nodes reach storage, what it was validated on (rig suite, platforms with installed packages, physical hosts / failover suite).
- Pertinent context (rig details, platform list shared by all rows, configurations explicitly NOT claimed, the same-version-on-every-host rule) goes in short text immediately before or after the table, not in run-on bullets.
- No "and nothing else" after it.
