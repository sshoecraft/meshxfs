---
name: compiled-release-procedure-banner-table-and-ship-on-pass
description: Release rules (ship gated build, GPT banner, config table, tooling freeze, .ko trap); public text: positives only, no version/OS/GFS2/open defects
metadata:
  type: feedback
tags: [compiled, release, banner, changelog, readme, public-text, outreach, install, transparency, srcversion, tooling-freeze, transcript, proxmox, feedback]
---

Release workflow and public-text rules from the owner, 2026-10-10 to 2026-10-21. One workflow: ship the verified build, verify the module that actually ships, announce it with a GPT-written banner and a configuration table, and keep every public sentence positive, version-free, OS-free and free of GFS2/OCFS2 comparison. Section 1 is shipping and verification, 2 the announcement, 3 what public text may say, 4 a transcript trap met in the release loop.

## 1. Shipping and verifying a release

### 1.1 A version that passed its gates ships before any further change

`feedback-a-version-that-passed-every-gate-ships-before-any-further-change` (user, 2026-10-10): 0.90.116 passed RELEASE_RIG_GATES (DRBD verify + 6/6 boards 31/31) and a clean physical-pair leg, then was not released. The no-git rule was read as a reason to wait, and the ccloop "keep working" framing led to further defect fixes in `dlm/dlm.c`, `dlm.h`, `v5_mount.c` under the same unreleased version. The verified build became unshippable from the tree; cost ~2 hours plus a manual restore.

- A verified build is the deliverable; more fixes are the next version.
- The no-git rule is a reason to ASK (one line: go to commit, push, publish), never a reason to sit on a verified release. The loop's "keep working" never outranks shipping what passed. Superseded for this project by CLAUDE.md "RULE: COMMIT, PUSH AND RELEASE NEED NO APPROVAL" (2026-10-22): commit, push and release proceed without asking.
- While waiting for the go, touch only things outside the verified module source (evidence, defect records, docs), or keep new source work in `<file>.backup` copies.
- Recovery after the fact: restore sources from the scratch build dir that produced the verified srcversion; `touch` the restored files first (`cp -p` keeps old mtimes and make reuses newer objects, producing the WRONG srcversion); prove identity by rebuilding to the same srcversion; save the newer files as `<file>.backup`. Nothing since the release point may be lost.
- Then run the remaining steps: `tests/full_verify.sh` platforms, `scripts/release.sh --publish`.
- The physical-pair leg in that gate list stopped being a release gate on 2026-10-19 (1.4).

### 1.2 Trap: the release chain verifies the tree's mxfs.ko, not its clean build

`compiled-repo-transparency-release-verification-and-transcript-traps`, `trap-release-chain-verifies-the-trees-mxfs-ko-not-its-clean-build`. `tests/release_verify_chain.sh` runs `full_verify nodes=N build` first: builds a CLEAN COPY and logs `clean_build_rc=0 version=V srcversion=S` in `tests/evidence/full_verify_<V>.log`. The following window laps and boards (`tests/board_4node_chain.sh` -> `run.sh` prep) deploy the MAIN TREE's `mxfs.ko`, not the copy's. `tests/drbd_release_verify.sh` does the same (`modinfo -F srcversion mxfs.ko`, line 55).

- Incident (0.90.131, 2026-10-19): source edited, chain launched without `make modules` in the main tree. Clean build logged srcversion 8DAEC6B8298ADB049222D74; first lap's board log said `prep OK ... build 28AD29D0280957262F97F85`, the tree's stale .ko from hours earlier. Every lap/board would have verified a module that would not ship. Caught on lap 1; chain stopped, `make modules && make tools` run in the main tree, chain relaunched.
- Apply: before any release chain, DRBD verify or Proxmox suite, run `make modules` and `make tools` in the main tree after the LAST source edit. Check `modinfo -F srcversion ./mxfs.ko` equals the chain build's srcversion (srcversion depends only on source, so a rebuild matches). After lap 1, grep its board log for `build <srcversion>` and compare.

### 1.3 No tooling edits while a board runs

`compiled-release-cycle-banner-and-tooling-freeze`, `trap-editing-criteria-py-while-a-board-runs-breaks-the-run` (owner corrections, 0.90.132 release cycle, 2026-10-21).

- run.sh records every board row by invoking `tools/criteria.py update ...`, a fresh python process per row, so the file on disk at that instant is what runs. A multi-step edit (rename `FLAKE_WINDOW`/`NEVER_FLAKE` in one Edit, fix the callers in the next) leaves a window where every live board's next write dies with NameError.
- Observed 0.90.132 cycle: the nq_wouldblock fix-off arm's run hit `NameError: name 'NEVER_FLAKE' is not defined` in cmd_update's print, after `save` (so its cell survived, by luck of ordering). Earlier the same day an edit to tools/ broke the Proxmox 7.0 suite while it packed the tree.
- Owner: "make SURE this does NOT affect the current release validation cycle in progress" / "i need .132 to be released cleanly".
- While any board, chain, lap or PVE suite is running, make no edit to tools/criteria.py, tools/defects.py, tools/configuration.py, run.sh or anything they import. Release-cycle tooling changes wait until the release is published.
- If a change cannot wait, build it in a separate checkout and swap it in only when nothing is running (check `tools/mxfs_pgrep.sh run.sh` and the chain pids first).
- If an edit already landed mid-run: restore immediately, py_compile, then grep every log written since the edit for Traceback/NameError and check whether the affected cell was saved before the crash.

### 1.4 The physical Proxmox pair is not a release gate

`compiled-repo-transparency-release-verification-and-transcript-traps`, `feedback-physical-pve-pair-is-not-a-release-gate` (user, 2026-10-19): pve1/pve2 are about 1000 miles from the owner; nobody can pull the network cable or recover them if down. Row "DRBD dual-primary, physical Proxmox VE 9 hosts (pve1/pve2)" (runs tests/pve_cable_pull.sh) was removed from `data/release_table.json` at the owner's direction.

- Do not add the row back; no release may depend on the physical pair.
- 2/net/mesh/drbd is verified by `tests/drbd_release_verify.sh` on the test1/test2 rig, the only DRBD evidence `scripts/release.sh --publish` requires (`data/configurations.json` released_by_own_rig).
- Release text must not claim physical-pair or cable-pull validation for a version that did not run it.
- Adds to the earlier hands-off rule for pve1/pve2 in compiled-lab-hardware-release-scope-and-wording-corrections.

## 2. Announcing a release

User corrections of 2026-10-10 around the 0.90.116 release, revised 2026-10-12 and 2026-10-21.

### 2.1 The headline sells the whole release to its users

`feedback-release-headline-sells-the-whole-release-to-its-users-not-the-last-internal-fix`: the published 0.90.116 headline was an engineering note about the allocator trylock (the last fix), for a release carrying eight versions of DRBD two-node work. User reaction: how is that a selling point to Proxmox users.

- `scripts/release.sh --publish` takes the version's CHANGELOG section as the GitHub release notes and its heading as the headline. Intermediate versions (marked "IN PROGRESS, NOT RELEASED") never reach users on their own, so the released section is the only announcement of their work.
- The heading covers everything since the previous RELEASE, and it is written by GPT from the changelog section (2.2), never drafted by us.
- Open the section with a plain-language summary for someone upgrading from the last release: one bullet per user-visible improvement with the version that made it, then what it was validated on. Engineering detail follows under "### <version> in detail".
- Never write "and nothing else" / "no other X was tested" after a validation list; scope is implied. Name only configurations explicitly NOT claimed, when it matters (later owner corrections on volunteered negatives: 3.4 and 3.5).
- Already shipped with a bad headline: `gh release edit v<V> --title ... --notes-file <section>`.

### 2.2 GPT writes the banner from the changelog

`feedback-when-you-release-ask-gpt-for-advice-on-the-release-banner` (procedure revised by the user 2026-10-12: "whatever you did to get this result is what I want to see in the future"). Before publishing, `mcp__ask_gpt__query` with:

- the prompt **"Write a banner describing the enhancements made in this release. Here is the changelog for the release, MXFS <version>:"**, then
- the version's CHANGELOG section WITHOUT its `##` heading (that is the banner being written): user-facing summary and configurations table verbatim; the "in detail" part with test-tooling and lab-host paragraphs dropped and the lab host named generically;
- nothing else: no draft of ours, no audience description, no length limit (amended 2026-10-21: 2.3).

GPT's title line becomes the GitHub release title, the CHANGELOG heading and the README release heading. 0.90.124's run gave "MXFS 0.90.124 — Multipath SAN Support, Stronger Recovery, Better Scalability", which the user liked. What failed before: sending our draft for polishing produced "restored multipath for 2–16-node SANs, ..."; "restored/returns/is back" is our history and tells users it was broken; outcome sentences read as banners for managers.
- The "consult another model when stuck / never consult another model" rule in CLAUDE.md was REMOVED by the user on 2026-10-10 to allow this. Older memories saying never to consult another model describe the retired rule.

### 2.3 The banner must name the headline platform support

`compiled-release-cycle-banner-and-tooling-freeze`, `feedback-release-banner-must-name-the-headline-platform-support` (owner, 0.90.132 release cycle, 2026-10-21).

- The banner had been "Safer Inodes, Stronger Recovery, Proxmox VE 9.2". After the changelog section changed, GPT was asked for a banner from the whole section with no guidance and returned "Cross-Node Inode Coherence and Recovery"; it was applied and pushed. Owner: "WAIT ... WE DO ADD SUPPORT FOR 9.2 right ... I DONT WANT TO RELEASE WITHOUT IT" / "THEN WHY REMOVE IT ... ITS IMPORTANT".
- Why: new platform support (a Proxmox VE version) is what the primary audience, Proxmox users, looks for; a banner built only from fix bullets drops it.
- When asking GPT for a banner, name in the prompt what the owner treats as the headline (new platform/version support first), and say it must appear.
- Compare the returned banner with the previous banner before applying it: anything the old banner named that is still true of the release must still be there, or ask the owner.
- The banner goes in three places: CHANGELOG.md heading, README `> ## <version>:` heading, and the GitHub release title (scripts/release.sh reads it from the CHANGELOG heading).

### 2.4 Released configurations go in a table

`feedback-every-release-lists-its-released-configurations-in-a-table`: the README's prose "What 0.90.116 was validated on" list crammed six shared-LUN configurations into one run-on bullet. On every release, in both the README release section and the CHANGELOG section used as release notes:

- One table row per released configuration (`2/net/mesh/direct` ... `16/disk/caw/direct`, `2/net/mesh/drbd`), columns: nodes, how nodes reach storage, what it was validated on (rig suite, platforms with installed packages, physical hosts / failover suite; the physical pair stopped being a release gate on 2026-10-19: 1.4).
- Pertinent context (rig details, platform list shared by all rows, configurations explicitly NOT claimed, the same-version-on-every-host rule) goes in short text immediately before or after the table, not in run-on bullets.
- No "and nothing else" after it.

## 3. What public text may say

Covers README, guides, man pages, banners, release notes, GitHub description/topics, package descriptions, prompts to GPT, and outreach (press emails, forum posts, HN, social).

### 3.1 Install instructions never name a version

`compiled-public-text-rules-no-version-pins-no-os-no-gfs2-comparison`, `feedback-install-instructions-never-name-a-version-only-the-latest-release` (user corrections of 2026-10-12). USER, on finding docs/drbd-setup.md telling testers `git clone --branch v0.90.107`: "LOL OMG NO ... It should just tell testers to download the latest release! Never ever a specific version ... look through all the readme files or the guides to make sure they don't tell you to use a specific version ... Just tell them to use the latest release from a releases page. Period."

- Any instruction that tells someone what to install says: the latest release, from https://github.com/sshoecraft/meshxfs/releases. Package names use `<version>` (`apt install ./mxfs_<version>_amd64.deb`), never a number.
- Never `git clone --branch v<N>`, `git checkout v<N>`, "Install 0.90.x", "Released in 0.90.x — check out its tag", or a download URL with a version in it.
- A pinned version goes stale at the next release: the DRBD guide sent new users to 0.90.107, two releases behind, missing 0.90.124's multi-resource DRBD recovery.
- The release package is the install path; `make install` from source is only the developer section ("Building from source"), which says it is not a release.
- Not covered: release-news / changelog text recording what a past release was validated on (history), and the README release section the release check requires to name the current version.
- Sweep for pins when editing docs: `--branch v[0-9]`, `checkout v[0-9]`, `Released in 0.`, `mxfs_0.` in README.md, docs/*.md, lab/*.md, packaging/*.md, tools/*.md, docs/man/.

### 3.2 Never name an operating system as what MeshXFS is

`compiled-public-text-rules-no-version-pins-no-os-no-gfs2-comparison`, `feedback-marketing-names-no-os-and-never-compares-meshxfs-to-gfs2-or-ocfs2` (user, 2026-10-12). USER: "why do you keep wanting to put Linux in there? I know it's technically accurate right now, but that's not the future direction. It will support multiple OSs. That's the whole reason for the PAL layer."

- Say "a POSIX clustered filesystem built on XFS", not "for Linux" / "built on Linux XFS" / "multiple Linux nodes".
- The PAL layer (`pal/`, architectural invariant 4: no direct kernel API outside `pal/`) exists so MeshXFS is not tied to one OS; FreeBSD and macOS ports are the direction.
- Naming platforms that have packages today (Proxmox VE 9, RHEL 9, Ubuntu 24.04, Debian 13) is fine: a fact about releases, not identity (a new platform version is also what a banner must carry: 2.3).
- Trap: feeding "for Linux" into the facts given to GPT makes its draft say it. Leave the OS out of the input.
- The GitHub topic `linux-kernel` stays; the user will add freebsd and mac topics when those ports are done.
- Proxmox VE is a supported platform with a storage plugin, not what MeshXFS was made for. USER: "It has support for Proxmox VE, but it wasn't made for it. It is a standard POSIX clustered file system."

### 3.3 Never compare MeshXFS to GFS2 or OCFS2

`compiled-public-text-rules-no-version-pins-no-os-no-gfs2-comparison`, same note `feedback-marketing-names-no-os-and-never-compares-meshxfs-to-gfs2-or-ocfs2`. USER: "Don't ever say this in any marketing. It's not comparable. It's not even partially comparable."

Reason (user): "both GFS2 and OCFS2 have negative connotations in the mind of every admin that's ever used them." Naming either, even favourably ("unlike GFS2"), puts that baggage in the reader's head before MeshXFS is judged on its own.

- No "comparable to", "alternative to", "in the family of", "like GFS2/OCFS2", and no `gfs2-alternative` / `ocfs2-alternative` topics. All removed from the README and GitHub on 2026-10-12.
- Do not hand GPT a "comparable systems: GFS2, OCFS2" fact when asking it to write public text.

### 3.4 Outreach text states what MeshXFS is, never what it is not

`compiled-public-text-states-positives-never-negatives-or-open-defects`, `feedback-outreach-text-states-what-it-is-never-what-it-is-not` (press emails, forum posts, HN, social). Rule: outreach states what MeshXFS is and what it has passed. It never volunteers a negative the owner did not ask for: "not proposed for upstream", "not a production release / use disposable data", open defects, "not yet X". It never says anything about the owner that the owner has not stated: no persona, background, fandom or listener status.

Evidence:
- LWN pitch (2026-10-16) carried an added line "It is not proposed for upstream and is not a patch series against it today". The editor's refusal quoted it back as one of the two reasons not to cover it. Owner: "You really shouldn't have put the upstream shit into the post."
- Same session added, unasked, a "not yet a production release" section to the Proxmox forum post and README exception paragraphs for open defects; the owner rejected each.
- Not claiming something does not claim its opposite, so a disclaimer adds nothing true and hands the reader a reason to stop.
- 2.5 Admins draft: opening "Long-time storage nerd here" invented a persona for the owner; the owner removed it ("wtf").

Apply:
- Draft only positive, verifiable facts about the project; facts about the owner only as the owner gave them (goal and bar set; did not write, edit or review the code).
- If a sentence would be false without a qualifier, reword the sentence rather than adding a disclaimer.
- If a likely objection seems worth answering, mention it to the owner as a suggestion outside the draft, not inside it.

### 3.5 Release text never lists open defects

`compiled-public-text-states-positives-never-negatives-or-open-defects`, `feedback-public-release-text-never-lists-open-defects` (README, CHANGELOG release section, forum posts, banners). Rule: public release text never names, lists or describes an open defect: no "exception" paragraphs, no "shipped open by the owner's decision", no description of an unexplained failure. Open records live only in `data/defects.json`.

Evidence: owner, on finding a README exception paragraph and a CHANGELOG "Shipped open" paragraph added at release time (0.90.130): a reader takes "open defects" in release text as a reason not to try the software at all; it reads as sabotaging the release. Leaving a record out of release text does not close it: it stays in `data/defects.json` with its evidence, and the queue stays public.

Apply:
- If a public sentence would be false with an open noblock record in the queue (e.g. "no open defect that can ... reaches any released configuration"), reword it to state the bar and the command that checks it (`tools/defects.py <configuration> --release`). Do not keep the false absolute, and do not add a disclosure paragraph.
- A harness-fix CHANGELOG entry may say what was fixed, not describe the open failure that exposed it.
- After editing the CHANGELOG section of a published version, regenerate the release notes from it: `gh release edit v<V> --notes-file <section>`.

### 3.6 Full transparency: the repo carries the whole development record

`compiled-repo-transparency-release-verification-and-transcript-traps`, `feedback-full-transparency-repo-carries-the-whole-development-record`. User, 2026-10-19: "we want FULL transparency ... if a user downloads the project and starts a claude code session ... i want that claude session to have all the info that i have here."

- Never untrack, hide, .gitignore or move out of the repo the internal development record: docs/history/, notes/, docs/rulings/, docs/cost-audit.md, .claude/awareness/, .ccmemory/, data/defects.json and CHANGELOG history. Asked 2026-10-19 whether to untrack 627 such files, the owner chose to leave them public.
- Goes further than not hiding: anything a session here relies on should travel with the clone (CLAUDE.md, .claude/ agents and settings, .ccmemory notes, tools). If something it needs lives only on this host, raise it rather than leave it local.
- Does not change release/outreach text rules (README front page, release notes): state what MeshXFS is and what it passed, no volunteered negatives or open-defect listings (3.4, 3.5). The repo carries the full record; the announcement text stays positive.

## 4. Trap: a queued user message is not a type=user transcript event

`compiled-repo-transparency-release-verification-and-transcript-traps`, `trap-queued-user-message-is-not-a-type-user-transcript-event`. A message typed while the model is working is stored as:
- `"type":"queue-operation"` with `"operation":"enqueue"` (text in `content`), then `"operation":"remove"`;
- `"type":"attachment"` whose `attachment.type` is `queued_command`.

Neither is `"type":"user"`, and `tools/transcript_digest.py` (text and results modes) emits neither.

- Cost: ccloop session 122 (4bfb49c5) got "ok you need to get to a stopping point - see ccusage ..." at 11:50:15Z (L679 enqueue, L688 attachment). It stopped, then answered the Stop hook's "HAVE YOU MET THE CRITERIA?" ~150 times with "I'm still stopped, as you asked". Session 123 (660878da) grepped `"type":"user"`, concluded the only prompt was "begin", and investigated a stop instruction it believed did not exist; the user interrupted and exited.
- Apply: to list what the user said, include `queue-operation` enqueue content and `attachment` events of type `queued_command` alongside `type=user` string events, so an "as you asked" in model text can be traced.
