---
name: compiled-consult-tool-fallbacks-and-refusals
description: Consult fallbacks (429 -> ask_fable model=claude-opus-5-5, neutral wording) plus release/rig traps, claim rulings, DRBD 9 policy, consult policy, i_d…
metadata:
  type: feedback
tags: [compiled, consult, ask_fable, refusal, release, packaging, rig, defects, platforms, claims, drbd, dlm, ilock, trap, owner-decision]
---

# Consulting another model, and release/rig traps and owner rulings

Two articles merged, so the fit is loose. Part 1 is the practical how-to for consulting when the default consult tools fail. Part 2 (absorbed from `compiled-release-and-rig-tooling-traps`) holds release, packaging and rig-tooling traps, owner rulings that bound a release (what it claims, which DRBD it supports), one DLM lock-release trap from release 0.90.132, and the consult policy history and how to treat consult output. The traps share one shape (a tool or marker looks like it did the thing and did not); the rulings share an owner who corrected a session.

# Part 1: Consulting another model when the default tools fail

Source: `consult-route-fable-tool-to-opus-when-the-default-model-refuses`.

## Failure and fix
- When the OpenAI consult tools (`ask_astra`, `ask_gpt`) return HTTP 429 `credit_balance_exhausted` and `mcp__ask_fable__query` returns `stop_reason=refusal` with no text, the consult is NOT blocked. Pass `model: "claude-opus-5-5"` to `mcp__ask_fable__query`. It answered a SPC-4 question at once, after the default model (`claude-fable-5`) had refused even a one-line control question.
- Why this is recorded: a session (0.90.134) concluded no model could be consulted and reported it as an owner blocker ("top up the OpenAI credits"). That held D-OUT-OF-BAND-KEY-REMOVAL-AT-3-PLUS-NODES-FENCE-SERIES-STALLS-SURVIVORS-126S for a whole session. The next session only had to change the model argument.

## How to apply
- Try `model: "claude-opus-5-5"` on the fable tool before reporting a consult as blocked.
- Opus still refused a long fencing prompt that used "victim", "fence" and "attack"-adjacent wording: the answer streamed partly, then hit `finish_reason=refusal`. The same questions reworded neutrally ("node D has left", "remaining node R") and split into short numbered questions were answered in full.
- Keep each consult under about 600 words of prompt. Ask for clauses and hazards, not approval. Its answers are hypotheses to measure.

# Part 2: Release, packaging and rig-tooling traps, release rulings, consult policy (from `compiled-release-and-rig-tooling-traps`)

## Release, packaging and rig-tooling traps

Each learned from a lost hour or a wrong conclusion.

**Mount refusal reasons are invisible on the rig (0.90.65).** MXFS sends a refused mount's reason through `errorfc(fc, ...)` with EPERM. On Ubuntu 24.04 (util-linux 2.39.3) mount(8) prints only "permission denied. dmesg(1) may have more information", and the errorfc text is not in dmesg either. `logfc()` printk's only for a context with no log (classic mount(2)); an fsopen() context stores the message for read() on the context fd, and util-linux 2.39 mounts through fsopen/fsconfig without reading it. 2.40+ does (PVE 9 / Debian 13 ships 2.41).
- Verify any errorfc/invalfc message on a host with util-linux >= 2.40 (the nested pve9 pair); never conclude it is broken from the rig's mount(8).
- Keep the reason also in the module's own kernel-log line (`mxfs_pal_log`); on 2.39 that is the only place an operator finds it.

See `trap-util-linux-2-39-mounts-through-fsopen-but-never-prints-the-kernels-errorfc-message`.

**`tools/defects.py update -w` replaces evidence (0.90.39).** It looks like an append because the next-step flag has `-a`, but evidence has no append form. Adding 20 GiB board measurements to `D-TAUTH-RECOVERY-SCANS-SCALE-WITH-LUN-SIZE-NOT-LEDGER-USE` erased its 1 TB takeover measurement, sizing pointers and consult reference; recovered only because the text was still in context from an earlier `show`.
- Run `tools/defects.py show <id>` first, pass `-w "<old evidence> ===== <new evidence>"`, then `show` again to check.

See `trap-defects-py-update-w-replaces-the-evidence-field-it-does-not-append`.

**An existing `dist/<V>` is not a finished build (0.90.39).** `tests/full_verify.sh` tested `[ ! -d dist/$V ]` to decide packages were built. A chain stopped while `release.sh` was starting left an empty `dist/0.90.39`; the packages step then ran nothing and printed nothing, and all 12 packaged rounds (four platforms, both configurations) failed in about a second with `FAIL: missing .../mxfs_0.90.39_amd64.deb`. The script still exited 0 because its last command was a summary grep. About an hour lost.
- Fix: a finished build is a `dist/$V` whose `SHA256SUMS` verifies (release.sh writes it last); the exit status counts failed platform steps.
- General: a directory or marker existing does not prove the step that creates it finished; test for the artifact written last. When a chain's rounds all fail within a second, read one round's first FAIL line before anything else.

See `trap-an-empty-dist-version-directory-made-full-verify-skip-the-package-build`.

**Host-built packages ship tools that will not start on target (0.89.77).** `make package` / `packaging/mkdeb.sh` on clyde link `mkfs.mxfs` and `chk_mxfs` against glibc 2.39 and require GLIBC_2.38 (`objdump -T | grep GLIBC_`). PVE 8 / Debian 12 has 2.36, RHEL 9 has 2.34, so the package installs and the tools then refuse to run. The DKMS module is unaffected (built on target).
- Release packages come only from `scripts/release.sh`, which builds in a container of the oldest targeted distribution: `debian:bookworm` for both .debs (tools need 2.34), `almalinux:8` for the RPM (tools need 2.14). Never attach a host-built package to a release.
- Docker's bridge network on clyde has no outbound TCP (pulls work, apt/dnf inside do not); build containers use `--network host`. Do not fix clyde's firewall for this; the rig depends on it.
- EL8 rpmbuild fails on an empty debugsource list when tools compile without `-g`; the spec needs `%global debug_package %{nil}`.
- `mkrpm.sh` drifted from `mkdeb.sh` (no `mxfs_admin`, no udev rule, man pages by name). A tool, page or config added to one builder goes into the other.

See `trap-a-release-package-built-on-clyde-ships-tools-that-refuse-to-start-on-proxmox-8-and-rhel`.

## What a release claims and supports

**A platform release claims exact kernels (user decision 2026-09-24, release 0.89.84).** The registry name and `kernels` field, README table and release notes name the exact kernels verified (e.g. RHEL 9.8 / 5.14.0-687.49.1), never "RHEL 9" or "Ubuntu 24.04"; every other kernel is stated untested, even on the same distribution. User's reason: a cloner who builds for another version and fails concludes "it's not ready". Technical reason: `pal/linux/kcompat_probe.sh` probes each kernel's API at build time, so kernels answer differently. RHEL 9 minors all report 5.14 with different backports; Ubuntu 24.04 point releases pull HWE kernels (6.11+); PVE 9 carries 6.17 and 7.0, which probe differently (7.0 has IOMAP_DIO_BOUNCE, 6.17 does not).
- Every claimed kernel gets a runtime round (`tests/packaged_round.sh`; on PVE `KERNEL=<krel>` pins one).
- Widening to a range is an open design in `docs/platforms.md` (build-check every kernel line, runtime-verify once per distinct probe fingerprint: LINUX_VERSION_CODE + MXFS_HAVE_* set); not implemented.
- rhel9-1/rhel9-2 are stuck on RHEL 9.2 (no subscription), reserved for a future 9.2 claim; AlmaLinux 9.8 (alma9-1/2) stands in for current RHEL 9.

See `user-a-platform-release-claims-exact-kernels-never-a-whole-distribution`.

Two owner corrections on what a release claims, both 2026-10-21 on 0.90.132. Source: `compiled-release-claims-scope-and-acquiring-trample-lessons`.

**Narrowing the claims table is not mitigation.** Source note: `feedback-narrowing-the-claims-table-does-not-protect-users-on-the-default-path`. A session recommended publishing 0.90.132 with 4/8/16 net/mesh left out of its claims while D-TCP-4NODE-NOQUEUE-TRY-WAITS-9S-ON-FULL-LEDGER-PAGE-CREATES-STALL (a stability defect, fix in the build but unverified) was open, and verifying them for a later release. Owner:

> "i dont think you understand human behaviour when it comes to establishing trust. so do you think they are going to look up their specific config to see if it's in RELEASE X tested config pages?"
> "the fact you make the recommendation means we need to step back and maybe establish some new rules regarding releases"

Why: the packages default to the network lock manager (force_transport=1). Anyone installing at 4+ nodes runs the unverified path whatever the README table says. A tester who hits the defect stops trusting the project; an "unclaimed" row prevents nothing.

How to apply:
- Never recommend shipping while a defect that crosses the release bar, or an unverified fix for one, reaches a configuration a default install runs. Verify it on the release build (or fix it) first, even if that delays the release.
- Leaving a configuration out of the claims is not mitigation; it is a gap that still has to be closed.
- The owner intends to discuss new release rules. Do not write any into CLAUDE.md until they say exactly what to write.

**An unsupported-setup issue never drops a supported claim.** Source note: `feedback-unsupported-setup-issue-never-drops-a-supported-claim`. A session moved 2/net/mesh/drbd out of 0.90.132's claims because the GitHub #3 record (DRBD survivor never mounts; the tester runs DRBD under Pacemaker/corosync with stonith) was open and counted against the configuration. Owner:

> "WAIT ... what??? no. it must be part of .132 ... also github #3 uses corosync and all that ... does DRBD work using our doc'd config?"
> "we may add support for issue #3 in the future but right now we have a supported configuration"

Why: a claim covers the documented setup (for DRBD: docs/drbd-setup.md, where `mxfs-drbd@` is the only thing bringing up or promoting DRBD, `drbd.service` is disabled, and there is no Pacemaker and no `become-primary-on`). A failure in a setup outside the docs says nothing about that claim unless reproduced on the documented setup.

How to apply:
- For an issue from a setup outside the docs, first ask whether the documented setup does the same thing, and measure it (for #3: tests/pve_pair_failover.sh p0-poweroff on the nested DRBD pair, where the survivor carried on).
- Keep the record open (it is still a user's report). Set its impact to noblock, with an impact-why naming the unsupported setup and the documented-setup measurement. Do not drop or narrow the configuration's claim.
- Support for that setup is future work, not a release gate.
- The claimed configuration still needs its own verification on the exact release build (tests/drbd_release_verify.sh <V> for 2/net/mesh/drbd).

**DRBD 9 support waits for the mainline kernel (owner decision, 2026-10-21).** Source: `compiled-drbd9-support-waits-for-mainline-kernel` (a group of one, kind assorted; its note is `drbd9-support-waits-for-mainline-kernel`). A Proxmox forum tester's mount on DRBD 9 (LINBIT's drbd-dkms) was refused with `P-DRBD-ARM-REFUSED ... replication protocol is '' (configured 'C')`. Owner: "we're not staying on drbd 8.4 forever" / "we'll support it when it reaches rhe mainline kernel".

Why: DRBD 9 is LINBIT's out-of-tree driver, shipped as `drbd-dkms` from LINBIT's own repositories, and its DKMS builds often lag new Proxmox kernels. The mainline kernel still carries DRBD 8.4.11: `/src/linux/drivers/block/drbd/drbd_config.h:12` `REL_VERSION "8.4.11"` at Linux 7.3.0. LINBIT is working to get DRBD 9 into mainline: it was aimed at around 7.2 but had not landed by 7.3, and a new patch series went out in late September 2026. Once it lands, every kernel built from it (Proxmox's included) ships DRBD 9 by default. MeshXFS then refuses every DRBD mount on those kernels, because the witness (`/usr/sbin/mxfs_drbd_witness.py`, `pal/linux/drbd.c:10-14`) reads each device's live state from `/proc/drbd`, which DRBD 9 no longer reports there, and `dlm/drbdfence.c:33-35` refuses a live protocol of `''` (also stated in `docs/quarantine-repair.md:156`). That outage ends 2/net/mesh/drbd on those kernels, so the work has to be done before Proxmox moves to such a kernel.

How to apply:
- Do not propose or start DRBD 9 support work before DRBD 9 is in the mainline kernel.
- When answering testers or issues: MeshXFS supports DRBD 8.4 (the driver built into the Proxmox kernel, `drbd-utils` without `drbd-dkms`) at this time. State what is supported; do not promise dates.
- Whenever `/src/linux` is updated, check `drivers/block/drbd/drbd_config.h` `REL_VERSION`. When it reads 9.x, tell the owner: DRBD 9 support is now needed, ahead of the first Proxmox kernel built on that release.
- The work, when it starts: read state from DRBD 9's own interface instead of `/proc/drbd`, handle DRBD 9's auto-promote/auto-demote (it promotes on open, which bypasses `mxfs-drbd@`'s promotion control), its resource syntax (`connection-mesh`, `node-id`, `fencing` in `net {}`) and its quorum/multi-node model, then verify it as its own configuration.

## DLM trap: a lock-release exit that writes `i_dlm_state` tramples ACQUIRING

Source: `compiled-release-claims-scope-and-acquiring-trample-lessons`, note `trap-a-release-exit-that-writes-i-dlm-state-tramples-acquiring` ("release" here is the DLM lock-release/abort path, not a product release).

ACQUIRING is the ONLY thing that makes a node's other tasks wait for an in-flight slow-path acquire (mxfs_ilock_wait_for_transition). A release that ends by assigning `ip->i_dlm_state = NONE/CACHED/BAST` without looking at what is there tramples it.

Found in 0.90.132 (D-CC-16NODE-SYNCED-CREATE-NAME-LOST-INODE-DISCONNECTED): mxfs_bast_nl_entry_cleanup's orphan-only abort set NONE over ACQUIRING; md5sum's PR request then ran beside the shell's EX create, hit the node's own fresh EX as P-SELF-STALE-EDEADLK, and P109 released that grant as a "phantom". The shell then modified the directory under an EX already handed to another node; that node's write of the same dir block dropped the name.

How to apply:
- When reading/writing any i_dlm_state assignment in a release/abort/rescue path, ask whether an acquirer can have set ACQUIRING meanwhile. Gate on `i_dlm_acq_inflight > 0` (the untrampled count), not on state.
- P109's phantom test (ACQUIRING + mode NL) cannot tell its own stale entry from another local task's fresh grant; it is safe only while ACQUIRING serialization holds.
- Detector: P-ACQ-CONCURRENT (second slow-path acquire with acq_inflight>0). To read a loss: compare per-block P11-DATALOG placements vs final P68-EVDECIDE fcnt, and look for two nodes placing at the same off; P-DIRWR gmode<5 on a dir data write is the holder that lost its EX.
- `md5sum f | awk > f.md5` (crash_consistency) is a natural same-node PR+EX pair on one directory.

## Consult policy history and handling consult output

Source: `compiled-model-consults-policy-and-handling-consult-output` (ten notes, each named below). Whether and how to consult another model (GPT, Astra, Fable), and how to treat what past consults returned; the last two notes (rule numbers, restoring removed rules) are adjacent rules-handling lessons that landed in the same cluster.

### Current rule (binding)

The project CLAUDE.md carries `RULE: CONSULT ANOTHER MODEL WHEN STUCK` (user directive, 2026-10-10), which outranks every memory. When stuck, consult (Astra first, as the owner asked on 2026-10-23: "are you asking astra for help on stuff you get stuck on?"). Sessions kept reading the never-consult paragraph below as binding and consulted nobody for weeks, which the owner had to ask about. A consult's output is still hypotheses to instrument, never findings. If Astra/GPT return HTTP 429 `credit_balance_exhausted`, the OpenAI account is out of credits: try `mcp__ask_fable__query`, and if it refuses, pass `model: "claude-opus-5-5"` (Part 1) before reporting a blocker only the owner can clear.

Old rule, kept only as history and NOT in force: Never call `mcp__ask_gpt__query`, `mcp__ask_astra__query` or `mcp__ask_fable__query`, on any model, for any question: not a hard-to-reverse design choice, not a stuck loop. Own the decision: read the code and references, instrument, measure. Stuck means the next step is a new instrument or hypothesis; a blocker only the user can clear is reported as one. Source: `feedback-never-consult-another-model` (user, 0.90.71, after a session asked GPT how to recover a withdrawn DRBD mount: stop asking GPT, then "don't ask anybody anything"). The user backed it with a web check that Opus 5.5 on max leads GPT-6 Astra on agentic coding (Terminal-Bench 4.0 66.4% vs 57.9%) and full-repo coding (FrontierCode 54.4% vs 53.3%); Astra leads only on math, abstract reasoning and computer use.

### How the policy moved (chronological; later entries supersede)

1. First Astra use: called exactly once, on the foreign-slot replay-gating defect, asking for hazards rather than approval. It rejected folding an epoch into the XFS log cycle field and exposed a false premise (reapplying a flushed image is not idempotent). The defect stayed open, so the honest claim was "prevented a wrong turn", not "closes defects faster". The call ran over 120 s. Astra is an OpenAI model, so it sits in the same family the user had already limited. The user never authorized routine use; a conditional ("if it helps close defects faster") is not permission. `astra-consult-was-used-once-and-was-substantive-but-has-not-yet-closed-a-defect`
2. User corrected a Fable session twice for consulting GPT on a fencing design, then objected to the strict-never rewrite as an extreme swing; the intermediate rule allowed consults for hard-to-reverse designs, unconverged loops, and more readily on Opus fallback. `feedback-gpt-consults-are-a-last-resort` and `feedback-no-gpt-consults-when-running-on-fable`. The retained design-choice clause was treated by sessions as permission, which is why the corrections did not stick.
3. Both of those were superseded by the never-consult rule, itself now superseded by the CLAUDE.md consult-when-stuck rule. Do not follow the old "Opus-fallback session may consult GPT" clause.
4. Autonomy note: `feedback-when-the-user-is-afk-take-the-recommended-default-never-ask` says that when the user is AFK on a handed-over task, take the "(Recommended)" option at design forks and list each decision in the final report so it can be reversed. Its aside that a design consult is "still fine" matches the current CLAUDE.md consult-when-stuck rule. Project hard prohibitions still apply (no host reboot, no git unasked, no widened timeouts).

### Treating consult output already in hand

- A consult returns hypotheses ordered by plausibility, not findings. In one case the rank-1 hazard (a shared acquisition-record key) was reached 114 times per wait and cost zero; the recommended fix (per-acquisition identity) would have failed the remote master's `resource_equal && owner == sender` identity test and reintroduced the re-send defect; two mid-ranked hazards were never observed; the real fault (a harness probe inferring locality from silence) was not on its list. Take such a list as things to instrument, one counter per predicted mode with a running `total=` (rate-limited probes make line counts unreliable), prove the probe can fire by forcing the case and asserting it, and run a controlled pair differing in one variable. Ask for hazards, never let it set the work order. `trap-a-design-consults-hazard-ranking-is-hypotheses-not-findings-measure-before-redesigning`
- Before building a durable fact (on-disk format) to answer a consult's class-level hazard, inventory the class's consumers and ask of each what state it protects and whether that state can survive the quiesce described. Reading all 16 consumers of the sole-survivor/never-multi predicates showed none outlives a clean unmount plus replay, disproving the hazard with one measured lap. Harness corollaries: window a survivor-note check to a mark written after the remount; count a pattern rather than directory listing size against NFILES. `technique-before-demanding-a-durable-predicate-inventory-what-each-guard-protects-and-whether-it-outlives-a-quiesce`
- When a consult names two halves of a requirement, verify both were built before marking fixed. A gate set populated at "validated" or "started" holds nothing for an obligation that exists durably but has not begun; answer "is anything owed" from the durable state (recovery descriptors on the platter), and use in-memory sets only for windows the durable state cannot see, pinned before the action. `trap-a-set-built-from-validation-holds-nothing-for-an-obligation-not-yet-started`

### Adjacent rules-handling lessons

- Never write a rule number in any comment, doc, changelog, commit message, defect record or handoff note, in any project; say the rule itself. Retiring four rules left 830 comments citing stubs and 2,133 citations across 605 files. Do not canonise a widespread bad convention by documenting it; remove it. Leave lowercase "rule 3/rule 6" in `dlm/disklock.{c,h,md}` alone (protocol-internal). `feedback-never-write-a-rule-number-in-any-comment-or-document`
- A reply that adds context to an open yes/no question is not a yes. A session removed a rule section and two agent definitions from the rules file for a flag-rate A/B on that misreading, was objected to, and restored everything. Rules and the agent roster are the user's: propose, wait, proceed only on an explicit "do it". `rule10-and-agents-pulled-2026-08-22-flag-ab-arm-restore-text`
