---
name: compiled-repo-transparency-release-verification-and-transcript-traps
description: Assorted: repo keeps full dev record public; pve pair not a release gate; release chain must use rebuilt tree .ko; queued user msgs not type=user
metadata:
  type: feedback
tags: [compiled, transparency, release, srcversion, transcript, proxmox]
---

Assorted group (the clusterer could not fit these to one topic): repo/release policy from the owner, plus two release/transcript traps.

## Full transparency: the repo carries the whole development record
`feedback-full-transparency-repo-carries-the-whole-development-record`
User, 2026-10-19: "we want FULL transparency ... if a user downloads the project and starts a claude code session ... i want that claude session to have all the info that i have here."
- Never untrack, hide, .gitignore or move out of the repo the internal development record: docs/history/, notes/, docs/rulings/, docs/cost-audit.md, .claude/awareness/, .ccmemory/, data/defects.json and CHANGELOG history. Asked 2026-10-19 whether to untrack 627 such files, the owner chose to leave them public.
- Goes further than not hiding: anything a session here relies on should travel with the clone (CLAUDE.md, .claude/ agents and settings, .ccmemory notes, tools). If something it needs lives only on this host, raise it rather than leave it local.
- Does not change release/outreach text rules (README front page, release notes): state what MeshXFS is and what it passed, no volunteered negatives or open-defect listings (compiled-public-text-states-positives-never-negatives-or-open-defects). The repo carries the full record; the announcement text stays positive.

## Physical Proxmox pair is not a release gate
`feedback-physical-pve-pair-is-not-a-release-gate`
User, 2026-10-19: pve1/pve2 are about 1000 miles from the owner; nobody can pull the network cable or recover them if down. Row "DRBD dual-primary, physical Proxmox VE 9 hosts (pve1/pve2)" (runs tests/pve_cable_pull.sh) was removed from `data/release_table.json` at the owner's direction.
- Do not add the row back; no release may depend on the physical pair.
- 2/net/mesh/drbd is verified by `tests/drbd_release_verify.sh` on the test1/test2 rig, the only DRBD evidence `scripts/release.sh --publish` requires (`data/configurations.json` released_by_own_rig).
- Release text must not claim physical-pair or cable-pull validation for a version that did not run it.
- Adds to the earlier hands-off rule for pve1/pve2 in compiled-lab-hardware-release-scope-and-wording-corrections.

## Trap: release chain verifies the tree's mxfs.ko, not its clean build
`trap-release-chain-verifies-the-trees-mxfs-ko-not-its-clean-build`
`tests/release_verify_chain.sh` runs `full_verify nodes=N build` first: builds a CLEAN COPY and logs `clean_build_rc=0 version=V srcversion=S` in `tests/evidence/full_verify_<V>.log`. The following window laps and boards (`tests/board_4node_chain.sh` -> `run.sh` prep) deploy the MAIN TREE's `mxfs.ko`, not the copy's. `tests/drbd_release_verify.sh` does the same (`modinfo -F srcversion mxfs.ko`, line 55).
- Incident (0.90.131, 2026-10-19): source edited, chain launched without `make modules` in the main tree. Clean build logged srcversion 8DAEC6B8298ADB049222D74; first lap's board log said `prep OK ... build 28AD29D0280957262F97F85`, the tree's stale .ko from hours earlier. Every lap/board would have verified a module that would not ship. Caught on lap 1; chain stopped, `make modules && make tools` run in the main tree, chain relaunched.
- Apply: before any release chain, DRBD verify or Proxmox suite, run `make modules` and `make tools` in the main tree after the LAST source edit. Check `modinfo -F srcversion ./mxfs.ko` equals the chain build's srcversion (srcversion depends only on source, so a rebuild matches). After lap 1, grep its board log for `build <srcversion>` and compare.

## Trap: a queued user message is not a type=user transcript event
`trap-queued-user-message-is-not-a-type-user-transcript-event`
A message typed while the model is working is stored as:
- `"type":"queue-operation"` with `"operation":"enqueue"` (text in `content`), then `"operation":"remove"`;
- `"type":"attachment"` whose `attachment.type` is `queued_command`.
Neither is `"type":"user"`, and `tools/transcript_digest.py` (text and results modes) emits neither.
- Cost: ccloop session 122 (4bfb49c5) got "ok you need to get to a stopping point - see ccusage ..." at 11:50:15Z (L679 enqueue, L688 attachment). It stopped, then answered the Stop hook's "HAVE YOU MET THE CRITERIA?" ~150 times with "I'm still stopped, as you asked". Session 123 (660878da) grepped `"type":"user"`, concluded the only prompt was "begin", and investigated a stop instruction it believed did not exist; the user interrupted and exited.
- Apply: to list what the user said, include `queue-operation` enqueue content and `attachment` events of type `queued_command` alongside `type=user` string events, so an "as you asked" in model text can be traced.
