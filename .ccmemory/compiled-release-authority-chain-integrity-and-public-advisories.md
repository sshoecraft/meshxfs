---
name: compiled-release-authority-chain-integrity-and-public-advisories
description: Release rules: owner delegates release calls, advisory on found bugs in published releases, no source edits mid release-chain (dist/<V> reuse trap).
metadata:
  type: feedback
tags: [compiled, release, advisory, packaging, release_verify_chain]
---

Central topic: how releases are run in MXFS/MeshXFS. Who decides, what gets said publicly when a shipped release is found buggy, and how a source edit mid-chain contaminates the packages. All from session 0da2c171, 2026-10-19 (the 0.90.131 validation).

## Authority: releases are Claude's call
Source: `feedback-owner-delegates-release-decisions-claude-releases-as-it-deems-necessary`

Owner directive, verbatim in part: "do not wait for me from now on - i am afk and cant answer questions - you release as per your recommendation - make a memory this is YOUR PROJECT ... you release as you deem necessary! remember there a LOT of people talking about it right now and testing it and downloading ... do w/e you need to do".

- Release decisions are Claude's: when to cut a release, what it claims, which configurations it covers, when to commit, push and run `scripts/release.sh --publish`. Do not stop to ask; decide as a careful owner would and report what was done and why.
- This does NOT relax any bar in CLAUDE.md. The release still needs every gate (release chain, platform rounds, Proxmox suite on the exact build) and claims only what passed. A configuration blocked by an open integrity/stability record is left out of the claims, not shipped. Honest narrowing beats a claim testers will break in public.
- Public attention is high (Phoronix, HN, Proxmox forum, GitHub traffic, an "AI code is slop" narrative). Verify before publishing, keep public text factual, get verified fixes out fast.
- When a decision genuinely needs the owner (publishing credentials, anything that could wedge or reboot clyde), record it and keep everything else moving.
- First use: 0.90.131 found a critical 2-node TCP outage (D-TCP-LEDGER-PAGE-FULL-EDQUOT-SHUTS-DOWN-BOTH-NODES-AFTER-FENCED-PEER-REJOINS) mid-validation; owner approved publishing 0.90.131 for the CAW configurations only, TCP rows left out until fixed.

## Public advisory when a published release has a found bug
Source: `feedback-warn-testers-publicly-when-a-published-release-has-a-found-bug`

Owner, verbatim: "if you need to publish an updated readme file or update .130 release page warning of a possible bug thats been found then do so - anyone testing this needs to know ... and they do NOT want to find the bug on their own - they will NEVER trust this system if they do".

- A defect that crosses the release bar (integrity or stability) and reaches a configuration a PUBLISHED release claims gets a public advisory as soon as it is measured: a short block at the top of the README on GitHub and on that release's GitHub release page (`gh release edit v<V> --notes-file`). Do not wait for the fix.
- Relation to `compiled-public-text-states-positives-never-negatives-or-open-defects`: that rule still holds for ordinary release text (no exception paragraphs, no lists of open records, no volunteered disclaimers). The advisory is the one exception, only for a measured bar-crossing defect in shipped code. Content: what was observed, which configurations, what users should do (test data, backups, `chk_mxfs` after tests, report), whether the published version is affected ("not yet determined" when not established), and that the fix ships after verification. Facts only, no speculation, no defect-queue dump. Remove the advisory when the fixing release is published.
- Mechanics keeping unverified work off main: when the working tree holds an unreleased version, commit ONLY README.md built from HEAD's copy (`git show HEAD:README.md`, edit, then `git hash-object -w` + `git update-index --cacheinfo` + commit), so the working tree is never overwritten and nothing unverified is pushed.

## Trap: a source edit during a running release chain contaminates the packages
Source: `trap-release-chain-packages-step-after-a-source-edit-leaves-unverified-packages-that-publish-ships`

- `tests/release_verify_chain.sh` runs `tests/full_verify.sh ... STEPS=packages,platforms` as its LAST step, hours after start. The package build (`scripts/vm_package_build.sh`) takes the tree's sources as they are at that moment.
- `scripts/release.sh --publish` then finds `dist/<V>/SHA256SUMS` and publishes that build WITHOUT rebuilding ("Publish what was built and inspected, never a silent rebuild"). So any source edit in the main tree while a chain is still in its boards (a fix for a defect the chain just found, an instrument) lands in packages that carry the release version but were never the verified build, and a later publish ships them.
- Rule of thumb: once a source edit goes into the tree during a chain, its remaining steps cannot produce a releasable result. Stop it before its packages step (kill its process group, check no run.sh/board child survived, power the rig down), or make sure `dist/<V>` is removed before the next real build. Boards are unaffected by source edits (they load the tree's prebuilt mxfs.ko); only `make` in the tree would change them, and that is forbidden mid-run anyway.
- First seen: the 0.90.131 chain found release-blocking defects in wave 1, a TCP fix was written into dlm/dlm.c during wave 2, and the chain was stopped at wave 3 before its packages step; dist/0.90.131 confirmed absent.
