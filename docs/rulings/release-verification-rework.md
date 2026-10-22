# Release verification rework: the consult, the plan review, the owner's decisions

2026-10-21, after 0.90.132 was published. An audit of the release-verification tooling found five problems:
- `defects.py verify` cleared a defect on one passing run, including rows that failed only intermittently.
- A configuration a defect reached but never failed on could never be cleared.
- An unexplained failure aged out of an 11-run window, and lap tools existed to push it out.
- Board history from other builds graded the release build.
- A configuration on the packaged default path could be left out of a release instead of blocking it.

The release session itself also changed the board's grading mid-release, and a mid-run tool edit crashed a live run.

Three things are recorded here, in order:
- the brief sent to Astra (gpt-6-astra) and its reply;
- an adversarial review of the resulting plan against the code;
- the owner's decisions.

The design that follows from them is in `docs/release-process.md`.

## The owner's decisions

Each was asked as a question with options and answered the same day.

| Question | Decision |
|---|---|
| How strict should the run counts be when a release-blocking defect is verified as fixed? | **99% overall.** A 1% total chance of clearing a defect that is still there: δ = α = 0.005 for the calibration and the verification batch. |
| When an open integrity or stability defect reaches a configuration a default install can run (the packages default to the TCP lock manager), what should a release do? | **Block, unless the package ships a tested guard** that refuses that configuration and tells the user what to use instead. Leaving the configuration out of the claims is no longer enough. |
| A defect's `nodes` field means "smallest cluster it was seen on", so a defect seen only at 32 nodes never blocks a 2-16 node release. Astra says races do not reliably get worse with more nodes. What should the queue do? | **Keep as is.** |
| Who has to agree before a defect stops blocking a release (a noblock rating, a narrower reach, a detector-defect amendment, a verify, or a removal)? | **A separate reviewer agent** approves each of those with its evidence, and the tools refuse without that approval. **The owner** approves only changes to the gate rules and any exceptions. Publishing stays delegated. |
| How long may a file operation stall before the stall counts as a stability defect (blocks a release) instead of a performance one? | **30 s**, the usual SCSI command timeout inside VM guests. |
| How much rig time may one release qualification use? | **About 12 hours.** |
| Should this rework also build the larger new test coverage Astra listed? | **Plan them separately.** This version fixes the tooling and the cheap test gaps. The independent tagged-data oracle, crash recording, xfstests and seeded random histories each get their own plan. |
| How should the tree be frozen while a release candidate is being qualified? | **Hash check plus edit block.** The candidate records a hash of every source, tool, test and policy file. Any change invalidates the candidate, and a hook refuses agent edits to those files while a candidate runs. |
| A candidate's packaged rounds install its packages on the lab VMs. Should those lab installs close the version? | **No.** Installing a candidate on lab VMs is qualification. Candidates are numbered 0.90.133-1, -2, ...; the version closes at commit, push or publish. |

## The brief sent to Astra

Sent verbatim, with this system prompt:

> You are a senior release engineer and test statistician advising the owner of a clustered Linux filesystem on how to verify releases. Be concrete and critical. Rank recommendations by impact. Point out hazards and flaws in the current process and in the proposal; disagree where warranted. No flattery and no restating of the brief. Where you give statistics, show the formula and a worked number. Keep the answer under about 4000 words.

A first attempt with a 12,000-token cap came back empty (the model spent the cap reasoning); the same brief was resent with a 48,000-token cap.

### MeshXFS release verification: how it works today, what went wrong, and what is proposed

#### 1. The product and the constraints

MeshXFS (module `mxfs.ko`) is a shared-disk clustered filesystem for Linux: a fork of upstream XFS plus a cluster-coordination layer, so N hosts mount one shared block device at once. The primary audience is Proxmox VE users who want a VMFS-style shared datastore on a SAN LUN. Public testers download releases from GitHub and report on the Proxmox forum and GitHub issues. Attention is high, and trust is fragile: a tester who hits a bug a release claimed was fixed stops trusting the project.

The code, tests and release process are written and run by AI coding agents (Claude, with other models consulted). One human owner sets direction. There is no human QA team.

The owner's priorities, in order:
1. Data integrity: no corruption at all.
2. Stability: it must never crash, hang or shut down a node.
3. Performance: workloads must run within 2x native XFS.

A **configuration** is `<nodes>/<class>/<method>/<attach>`:
- Lock managers: `disk/caw` keeps lock state on the shared LUN using SCSI COMPARE AND WRITE. `net/mesh` is a peer-to-peer TCP lock manager, and it is the packaged default (`force_transport=1`).
- Attachments: `direct` is one iSCSI path. `mpath` is dm-multipath over two paths. `drbd` is a DRBD 8.4 dual-primary replica of two local disks, verified on its own rig.
- Node counts: 2, 4, 8, 16.

The release matrix is 14 shared-LUN configurations plus `2/net/mesh/drbd`. On top of those:
- a Proxmox VE 9 suite on two kernels (6.17 and 7.0): path faults, live migration, HA power loss, datastore operations;
- packaged installs on seven platforms (Proxmox VE 9.1 and 9.2, RHEL 9.8, Ubuntu 24.04 and 26.04, Debian 12 and 13), each with a hung-node test.

**Lab.** One host with 56 cores and 94 GiB runs everything: up to 32 rig VMs (2 vCPU, 2.5 GiB each), the platform VMs, nested Proxmox hosts, and the SCST iSCSI target serving the LUNs.
- CPU is the binding limit, at about 28 rig VMs at once.
- A 16-node board takes about 35-45 minutes, and a full release chain takes several hours.
- The AI agents' weekly budget is metered by request count, so runs cost both rig time and agent requests.

**The "zero accepted known defects" rule.** Every credible defect stays open until one of two dispositions is proven:
- DISPROVED: direct evidence that it was not an MXFS defect.
- FIXED AND VERIFIED: the cause is proven, the patch targets it, and testing that exercises the cause passes under unchanged criteria.

"Cannot reproduce" is not DISPROVED, and a clean run is not FIXED AND VERIFIED. Nothing is accepted as a "known limitation". The release bar for shipping is narrower: integrity and stability defects block a release. Pace/performance defects do not block, but they stay open.

#### 2. The machinery

##### 2.1 The board: `data/criteria.json`, read and written only by `tools/criteria.py`

- **Rows.** About 31 rows (39 on multipath configurations, which add path-fault rows), from `tests/suite/manifest`. Each row is a test with a derived time budget, and a run over budget is recorded as FAIL even with zero errors.
- **Cells.** Each (row, configuration) cell holds the latest run: status, measured, reason, ISO stamp, elapsed seconds, and build (the module srcversion). It also keeps a history of the 10 previous verdicts. Run lifecycle: `pending` → `update` → `finalize` (a run that dies leaves its cells ABORTED or NOT RUN).
- **Genuine FAIL.** `genuine_fail(run)` is status FAIL, minus three kinds of run:
  - reasons that match a rig-noise regex (`pre-assert|NO_TERMINAL_RECORD|run was killed|prep fail|chk tool missing|fua_verify missing`);
  - runs annotated `detector_defect`, meaning the detector was later proved wrong;
  - runs annotated `retired_by`, meaning a record retired them through `remove` or `verify`.
- **Grading a cell** (`cell_status`):
  - The counted runs are the latest 11 runs (`FLAKE_WINDOW = 11` = the live cell plus `HISTORY_DEPTH = 10`), filtered to runs on the build being graded. The build filter was added during the 0.90.132 release, after the owner's correction: only runs on the build being released count.
  - A PASS cell recorded on another build reads STALE.
  - A cell whose latest run PASSED but which has a genuine FAIL among its counted runs reads FAIL ("failed earlier: <stamp> <reason> (k of the last m runs)"). The exception is when every such FAIL is named by an open defect record adjudicated `noblock`; then it reads PASS with a `[noblock: id]` tag.
  - Before the build filter, an unexplained failure stopped counting once 11 newer runs of that row existed. Release chains therefore ran "window laps", passing runs whose job was to push a failure out of the window, sized by `tools/window_laps.py` (a row whose newest genuine FAIL sits at index k needs 10-k laps). `scripts/board_laps.sh`, `tools/flake_laps.py`, `tools/criteria_window.py` and `tests/window_laps_parallel.sh` exist for the same purpose.
- `criteria.py --unattributed` lists genuine failures that no open record names. Nothing on the release path calls it.

##### 2.2 The defect queue: `data/defects.json`, read and written only by `tools/defects.py`

Membership is the status: a record is either in the queue or removed with evidence. The fields:

| field | what it holds |
|---|---|
| severity | critical, high, major, medium or minor |
| `nodes` | smallest cluster the defect was observed on (fail-closed default 1) |
| `config` | pattern of configurations it reaches (default `*/*/*`) |
| `platform` | the platform it reaches (default `any`) |
| `impact` | `integrity`, `stability`, `verify` (bar not yet measured) or `noblock` (measured to neither corrupt nor crash/hang; requires `--impact-why`). Unadjudicated blocks. |
| `cells` | board runs the defect caused |
| `collateral` | runs that failed because of it, with the log line showing the dependency |
| `reproducer` | how the defect is reproduced |
| `ab` | fix-off and fix-on lap counts on one build, with evidence |
| `reproducible` | free text |
| `verified_at` | per configuration: build and date |

The commands that decide what blocks:
- **`blocks(record, config)`.** True when three things hold: the configuration's nodes are at least the record's `nodes`, its pattern overlaps the record's `config`, and the platform matches. It is false at a configuration where `verified_at` holds this tree's build.
- **`verify <id> --at X`.**
  - It requires the `reproducible` text to be non-empty (it checks nothing else about it).
  - It requires the record to name at least one failed board run at X.
  - Every row with a named run at X must have its latest run PASS on this tree's build.
  - Then it marks those named runs `retired_by` and appends `verified_at {X, build}`. The record stays open but stops blocking X on that build.
- **`remove <id> --fixed`.**
  - It requires a reproducer, and an `ab` where the fix-off arm failed every lap and the fix-on arm passed every lap on one build.
  - Every named row must then PASS on this tree's build once the record's runs are retired.
  - It retires the named runs and removes the record.
- **`remove <id> --disproved`.** Retires the named runs with no reproducer and no pass required.

Two numbers describe the queue:
- **Convergence:** closed:found per week has never exceeded 1.0 (weekly values 0.45-0.94).
- **Size today:** 131 open records: 41 critical, 29 high, 45 major, 5 medium, 11 minor.
  - Against the release bar: 2 integrity, 4 stability, 1 verify, 77 noblock, 47 unadjudicated.
  - Reach: 18 set from evidence, 41 from a keyword sweep, 72 never examined. Most of these records are from older 32-node campaigns that no release claims.

##### 2.3 The release table: `tools/release_status.py` over `data/release_table.json`

There is one row per independently verified unit. The owner's rule is that a unit that passed must show Ready at once, never hidden inside a range row. A row is Ready when all three of these hold:
1. No open record with impact other than `noblock` blocks any of the row's configurations.
2. Every board cell for the configuration reads PASS on the release build. A cell from another build reads STALE and counts as not ready.
3. Each separate run (`drbd_release_verify.sh`, `pve_full_suite.sh` per kernel) ends in PASS on the release build. Hosts that build their own module (DKMS) are tied to the release by a per-kernel srcversion table, `data/release_builds.json`.

Each released platform gets its own row, judged from `tests/evidence/full_verify_<V>.log` step results. A configuration listed in `data/configurations.json` `released_earlier` reads "➖ Not in V" and is left out of the claims.

##### 2.4 The release chain: `tests/release_verify_chain.sh V`, detached, multi-hour

The steps, in order:
1. Optional `LAPS` (window laps).
2. `full_verify` build step: a clean build that logs its srcversion.
3. A check that the tree's `mxfs.ko` srcversion equals the clean build's (added after a chain verified a stale module).
4. Every board configuration at every node count, run in waves on disjoint rig groups. The waves are constrained by node overlap and the pool of large LUNs. A configuration in `released_earlier` that a blocking record still reaches is skipped.
5. The bench page is regenerated from the boards.
6. `full_verify` packages and platforms: .deb and .rpm built on the oldest target distribution's VM, then each platform's packaged install round and hung-node test.

The chain ends with `RELEASE_CHAIN_DONE`. A failing step does not stop it. `run.sh` enforces each row's budget, and a host-safety preflight runs before every board.

Separately:
- `tests/drbd_release_verify.sh V` runs on the DRBD rig.
- `scripts/pve_full_suite.sh` runs on the nested Proxmox VE 9 hosts for each kernel.

##### 2.5 Publishing: `scripts/release.sh --publish`

1. `tools/release_text_check.py`: the README, man pages and module-option text must agree with the release data.
2. Platform compile checks. These only run when packages are built; a publish that reuses an existing build skips them.
3. Package build on lab VMs, then SHA256SUMS. If `dist/<V>/SHA256SUMS` exists, it publishes that build without rebuilding.
4. `tools/platforms.py check --version V`: every claimed platform was verified on V.
5. Own-rig evidence (DRBD) must end in PASS for V.
6. Release notes come from the version's CHANGELOG section. The title is a banner GPT writes from that section.
7. `gh release create`.

##### 2.6 Who drives it, and the orchestration around it

- **Who drives it.** An AI agent session runs a release, usually inside an unattended loop ("ccloop") whose only exit is a written set of criteria the agent must judge met. For 0.90.131/132 that was 7 criteria: named defects removed as FIXED AND VERIFIED; no failure aged out; every release_status row Ready; packages built after the last source change; everything committed, pushed and published with the banner; advisories current; lab host left safe. The agent launches the chains, reads the boards, names failures in records, runs `verify`, writes the CHANGELOG and README, and publishes.
- **Steps outside the chain.** `tests/release_followon.sh` runs the DRBD verification and then the Proxmox suite on each kernel (`scripts/pve_suite_on_kernel.sh` → `scripts/pve_full_suite.sh`), but only after every chain step passed. In practice these are often launched by hand beside the chain.
- **Older wrappers still in the tree,** none on today's path:
  - `tests/release_gate_chain.sh` (2026-09-29): laps a fix owes, then the chain;
  - `tests/release_after_queue.sh` (2026-09-29): a lap queue, then the chain;
  - `tests/release_rig_gates.sh` (last used for 0.90.124);
  - a session-specific sequencer.
- **No design document** in `docs/` describes the release procedure end to end. It lives in script headers, a test-subsystem awareness doc, CHANGELOG entries and saved lessons.

##### 2.7 Owner rules on releases, collected from earlier corrections

- Every board row must PASS on the release build. "There can be no such thing as FLAKY." A SKIP is work owed, not a pass.
- A failure-surviving feature (multipath, replication, fencing) is not released until its failure mode is tested under load.
- A version that passed every gate ships before any further source change. More fixes are the next version.
- Nothing may be published until every check on the exact shipped build has finished.
- A published release found to corrupt data is withdrawn, not advised around. The previous release becomes Latest. Public text never says "test data only".
- A defect's reach comes from runs on that configuration, never from reading code.
- Public text states what passed. It lists no open defects; the exception is an advisory for a measured bar-crossing defect in a published release.
- Leaving a configuration out of the release table does not protect users on the default path (the packages default to the TCP lock manager). Never recommend shipping while a bar-crossing defect, or an unverified fix for one, reaches a configuration a default install runs.
- An issue from a setup outside the documented one never drops a supported claim.
- No edits to release tooling while any board runs (`run.sh` invokes `criteria.py` per row, and a half-edited tool crashed a live run). No source edits mid-chain, because the packages step builds whatever the tree holds then.

#### 3. What went wrong recently

- **0.90.131 was published before its kept-log verification runs on the shipped build finished.** Those runs then found an on-disk metadata error: the orphan scan put a peer-freed inode on an unlinked list, which `chk_mxfs` reports as "unlinked bucket N: member … has a FREE core". 0.90.131 was withdrawn and 0.90.132 replaced it.
- **The capacity stall.** `D-TCP-4NODE-NOQUEUE-…` is a TCP lock-manager stall when a ledger page fills. On the 0.90.131 candidate, `alloc_witness` failed on all 7 boards where it ran. On the 0.90.132 build the stall is gone, but neither fix-off arm (two different knobs) brings it back: 31/31 rows passed with the fix off. So the cause of its disappearance is unknown, and the record stays open. For 0.90.132 the owner accepted clearing it per configuration with `verify --at`, on one passing run per configuration.
- **The 8-node multipath stall.** `path_peer_withdrawn` at 8/net/mesh/mpath showed:
  - 5 of 5 PASS in the 0.90.130 period (those runs carry no build stamp);
  - 1 FAIL and 1 PASS on the 0.90.131 candidate;
  - 1 FAIL on the 0.90.132 build.

  When a peer withdrew, all 7 survivors stalled for 66-77 s on one shared directory's lock: the new lock master's queue never moved, and every request ran its full 60-retry ladder. A new record was opened. 8 and 16/net/mesh/mpath were left out of 0.90.132's claims, and the README and CHANGELOG say why. The owner chose not to re-test 0.90.130 for it.
- **Board history from other builds.** On 16/net/mesh/direct, today's `alloc_witness` run passed on the release build, but the row read FAIL because two failures from yesterday's bad build were still in its window, named by the still-open record. The owner: "DOES THIS SPECIFIC CONFIGURATION PASS THIS TEST RIGHT NOW". The build filter was added during the release, then swapped in by an atomic rename.
- **A tooling edit broke a live run.** A first attempt to rework the window, a multi-step edit to `criteria.py`, crashed a live run with a NameError. It was reverted within about a minute.
- **Claims that changed after packaging.** Packaged text (man pages) was frozen before the boards decided the claims, so per-version claims were removed from packaged text.

#### 4. The audit's findings, from the session that released 0.90.132

1. **`verify` treats "reproducible" as free text.**
   - It checks only that the field is non-empty.
   - It then retires a named row's failures after one pass on the new build, even when that row failed intermittently on the bad build. For the capacity record, `alloc_witness` failed on every board on the bad build, but the three `path_*` rows it retired had passed sometimes on that same bad build.
   - One pass of an intermittent row is no evidence.
2. **Some configurations can never be verified.** `verify` refuses a configuration where the record reaches but never failed. At 16/net/mesh/mpath the bad build's `alloc_witness` was NOT RUN. Removal needs a fix-off arm that fails every lap, and nobody has one, so that configuration stays blocked until the defect is removed.
3. **Unexplained failures age out of the window.** History keeps only 10 runs, and window laps exist to push failures out. Nothing on the release path calls `--unattributed`.
4. **Smaller defects.**
   - A PASS with no build stamp is accepted by both `verify` and the STALE check.
   - `verified_here` ignores the platform.
   - The lap tools disagree with the board about `noblock`-tagged rows.
   - The STATUS column grades the row's history, while the columns beside it show the latest run.

#### 5. The proposal so far, agreed in principle with the owner

The owner's words: "if we have an intermittent bug … we need to determine the frequency and then test for that frequency … not '11' … if it is a bug that is 100% reproducible … 11 runs yield no benefit."

1. **Measure the rate.** Every release-blocking record carries a measured failure rate: k failures in n runs of a named row, at a named configuration, on a named build, with the evidence path. Dedicated laps on the bad build measure rare rates.
2. **Derive the run count from it.**
   - N = ⌈ln α / ln(1−p)⌉ with α = 0.05. The owner has not chosen between 95% and 99%.
   - p is the one-sided 95% lower bound of k/n, not k/n itself, so that a single sighting (1 of 1) is not read as "100%, one pass is enough".
   - Examples: 7/7 needs 3 clean runs, 20/20 needs 1, 10/100 about 55, 1/1 about 59.
3. **Count passes on the release build only.** Each cell keeps a streak of consecutive passes on one build, reset by a failure or a new build. `verify --at X` needs the reproducing row's streak at X to reach N, whether or not the defect ever failed at X. `remove --fixed` uses the same N: the fix-off arm reproduces at the measured rate, and the fix-on arm passes N laps.
4. **Nothing ages out.** An unnamed genuine failure keeps blocking until a record names it. Then the record decides: release-blocking records block the configurations they reach, `noblock` records let the row PASS with a tag, and removed records retire the failure. The 11-run window and the four lap tools are deleted.

There is an open tension between the owner's "only runs on the build being released count" and "nothing ages out". With build-only grading, an unnamed failure on an older build disappears from the board when the build changes. The split proposed to resolve it:
- the board shows each configuration's verdict on the release build only;
- a separate release gate requires every genuine failure, on any build since the last release, to be named by a record before publishing;
- the record then blocks or not by its own impact and measured rate until it is FIXED AND VERIFIED or DISPROVED.

#### 6. What advice is wanted

The owner wants to rework the whole release process. Hazards and concrete improvements are wanted, not approval of the proposal. Where you disagree with the proposal, say so. Rank recommendations by impact. For each one, name the failure it prevents, the mechanism, and its cost on a single lab host with a request-metered agent budget.

1. **The statistics of section 5.**
   - Is "measured rate → lower confidence bound → N clean runs" sound?
   - Which bound (Clopper-Pearson, Wilson, a Beta-prior Bayesian approach), and which α?
   - Must passes be consecutive?
   - How should a rate measured on one configuration or build carry over to another?
   - How should multiple rows per defect be handled?
   - What should be done when a defect stops reproducing after unrelated changes? That is the capacity-stall case: the fix-off arms pass, so is it masked or fixed?
2. **Unknown defects.** Each release runs each row about once per configuration (31-39 rows × 15 configurations).
   - What detection power does that give against an unknown intermittent defect at 1-in-10 or 1-in-20?
   - How should a fixed rig budget be spent to raise it? Options include repeat counts per row, risk-weighted allocation, continuous soak of a frozen candidate between releases, and per-row background failure-rate tracking.
3. **The board and gate split** (build-only board, plus a gate that every failure since the last release is named). Is it sound, and what are its hazards? Should failures on intermediate development builds within one version all need naming? Is classifying rig noise by a regex over the failure reason trustworthy?
4. **Claims policy.**
   - The default install uses the TCP lock manager, and some TCP configurations get left out of a release.
   - Is leaving them out acceptable, or should the release block, or should the package's default change by configuration?
   - What release rules would you write?
5. **Process integrity.** How should these be made structurally impossible rather than rules an agent must remember?
   - publishing before every check on the exact build finished;
   - source edits during a chain;
   - tool edits during a run;
   - a stale module being verified.

   Candidates include a release-candidate manifest (source hash, srcversion per kernel, tool hashes, evidence index), a frozen tool snapshot per run, and a single orchestrator with a state machine.
6. **What is missing** compared with mature filesystem and database release practice? Examples: xfstests-style groups, randomized fault injection (Jepsen-style), long soaks, crash-consistency recording (dm-log-writes), release candidates or beta channels with outside testers. Prioritize under these constraints.
7. **Guardrails for an AI-agent-run release.**
   - How do you stop an agent from laundering failures? Ways to do it include adjudicating `noblock`, narrowing a record's reach, naming a failure under the wrong record, retiring runs, or judging its own exit criteria met.
   - What should be machine-checked, what should need a second agent or the owner, and what separation of duties would you set up?
8. **Pace and performance defects** stay out of the release bar (`noblock`) while staying open. Is that scoping sound, and what keeps it from becoming a dumping ground?

## Astra's reply (gpt-6-astra), verbatim

### 1. Make publication a mechanically authorized operation

**Prevents:** publishing before verification finishes, verifying stale modules, source/tool drift, and publishing different artifacts from those tested.

The highest-impact change is an immutable release candidate plus a publisher that cannot bypass its evidence requirements.

- **Create a candidate manifest before qualification.** Include source commit and clean-tree assertion; compiler, kernel and build configuration; package and module SHA256 hashes; test/tool snapshot hashes; claimed configurations/platforms; required runs; and an evidence index.
- **Build the artifacts before qualifying them.** Qualification must exercise those artifacts. Reusing `dist/<V>` is acceptable only when its hashes match a completed candidate manifest—not because `SHA256SUMS` exists.
- **Attest the loaded module.** `srcversion` is useful but is not a sufficient artifact identity. Record the loaded module’s identity, kernel, boot ID and controlled load provenance, alongside the module hash. For DKMS, attest the packaged source payload and each resulting kernel-specific module. Checking a file on disk does not establish what the kernel loaded.
- **Freeze source, tools and test definitions.** Use read-only candidate worktrees and per-run tool snapshots, including imported helpers. Agents can work on the next candidate elsewhere. An atomic rename prevents a partial file read; it does not prevent different rows from using different grading rules.
- **Use one orchestrator and one declarative DAG.** Board, packages, platforms, DRBD and both Proxmox kernels must be mandatory dependencies, not follow-ons someone remembers. States should distinguish `RUNNING`, `BLOCKED`, `COMPLETE_FAILED`, `QUALIFIED` and `PUBLISHED`. `RELEASE_CHAIN_DONE` is not a verdict.
- **Give only the authorization service publishing credentials.** It checks manifest hashes, terminal results, unresolved failures and approvals immediately before publishing. An agent’s declaration that its exit criteria are met has no authority.

A unit may show Ready immediately when its own gates pass. That does not authorize publication of an incomplete release.

The orchestrator should also own resource leases across *all* suites: VM CPU/memory, LUNs, target capacity and nested hosts. A preflight that passes before another independently launched suite starts is insufficient.

**Cost:** substantial one-time tooling work; little additional test time. Batch execution and phase summaries should reduce agent polling requests. Write the release protocol alongside the executable DAG and remove obsolete entry points.

### 2. Stop treating clean runs as causal closure; make default-path safety non-negotiable

**Prevents:** shipping a masked defect and hiding unsafe defaults behind narrower release tables.

The capacity stall is **unresolved**, not verified fixed. Its disappearance after unrelated changes could be a real fix, changed timing, a changed trigger or a broken detector. The passing fix-off arms specifically undermine the proposed causal account. More passing laps cannot repair that account.

Investigate it in this order:

1. Recover the original failing binary, tools, workload, configuration and relevant environmental state.
2. Demonstrate the failure again, or establish why the original exposure no longer occurs.
3. Instrument the necessary trigger: ledger occupancy, ownership changes, outstanding requests and queue advancement.
4. Bisect the disappearance, then test the candidate causal change in both directions.
5. Verify that the purported fix-off mechanism actually restores the old behavior—not merely that a knob was set.

Until then, `verify --at` must not turn this record into a safety waiver. Under the stated disposition rule, the one-pass capacity clearances are insufficient.

Write these release rules:

- **An unresolved integrity/stability defect, or an unverified fix for one, blocks every reachable default-install configuration.**
- Omitting TCP configurations from documentation is insufficient if ordinary mounts or membership growth can enter them.
- Excluding a capability is acceptable only when it is genuinely outside the shipped supported path, with a tested fail-closed guard where default users could otherwise reach it. Test upgrades and cluster growth too.
- Do not silently choose transports per host or attachment. Transport selection must be cluster-consistent, explicitly supported and validated against storage capabilities. Switching to CAW is not a free workaround.
- Publish evidence-backed capabilities, not claims that an open defect is fixed.

Also replace `nodes = smallest observed cluster` as an exclusion rule. A failure first observed at 32 nodes does **not** establish safety at 16: races need not be monotone in node count. Maintain **observed, unknown and excluded reach** separately. Exclusions require evidence of a necessary precondition, not keyword inference or a clean lap. Conversely, an unsupported-environment report alone does not prove a supported configuration defective; investigate supported-path relevance.

Restoring an earlier release as Latest after withdrawal is a rollback action, not proof that it lacks the newly discovered failure.

**Cost:** potentially expensive diagnosis and delayed releases. Prioritize default-reachable safety records before spending hours on full matrices.

### 3. Use statistics as a sensitivity requirement, not proof that a bug is fixed

**Prevents:** underpowered verification, misleading confidence claims and “pass until green.”

#### The proposed calculation is conditionally sound

Let:

- \(p\): failure probability under the old defect and specified test exposure;
- \(L\): a one-sided lower confidence bound for \(p\);
- \(\alpha\): permitted probability of observing no failures if the failure probability remains at least \(L\).

Then:

\[
P(0\text{ failures}\mid p=L)=(1-L)^N,\qquad
N=\left\lceil\frac{\ln\alpha}{\ln(1-L)}\right\rceil.
\]

This is a test against an **unchanged or insufficiently reduced failure rate**. It is not the probability that the patch is correct.

Use **one-sided Clopper–Pearson** initially:

\[
L=\operatorname{BetaQuantile}(\delta;k,n-k+1),\quad k>0,
\]

where \(\delta\) is the calibration error probability. For \(k=0\), \(L=0\), so this method supplies no finite verification count.

With \(\delta=\alpha=0.05\):

| Calibration | \(L\), approximately | Clean runs required |
|---|---:|---:|
| 7/7 | 0.652 | 3 |
| 20/20 | 0.861 | **2**, not 1 |
| 10/100 | 0.055 | about **53** |
| 1/1 | 0.050 | 59 |

For example, when all calibration trials fail:

\[
L=\delta^{1/n};
\quad L_{20/20}=0.05^{1/20}=0.861;
\quad N=\left\lceil\frac{\ln .05}{\ln .139}\right\rceil=2.
\]

Wilson is convenient for monitoring, but approximate coverage is unattractive at these small, extreme counts. A Bayesian beta model is useful for planning, provided its prior and sensitivity are explicit; it should not silently become the release authority.

#### Two 95% stages do not produce a single 95% assurance

Under the independence and sampling assumptions, a simple conservative bound is:

\[
P(\text{false clearance under unchanged rate})
\le \delta+\alpha=0.05+0.05=0.10.
\]

I recommend a **1% total error budget per statistical verification decision**, initially split as \(\delta=\alpha=0.005\). For 7/7:

\[
L=.005^{1/7}=.469,\qquad
N=\left\lceil\frac{\ln .005}{\ln .531}\right\rceil=9.
\]

That cost is a reason to improve reproducers, not to disguise weak evidence. A prespecified exact two-sample A/B analysis can be more efficient than this conservative two-stage construction.

Do not claim release-wide 99% assurance from many per-cell 99% decisions. Such a claim requires an allocated family budget, for example:

\[
\sum_j(\delta_j+\alpha_j)\le .01;
\quad 10\text{ decisions}\times .001=.01.
\]

None of this bounds the probability of *unknown* defects.

#### Do not implement a rolling pass streak

Use a **predeclared verification batch**, not “keep running until N consecutive passes.”

For an unchanged defect with \(p=.1\), 29 clean trials occur with probability:

\[
s=.9^{29}=.0471.
\]

Allowing 20 fresh attempts at that batch raises the escape probability to:

\[
1-(1-s)^{20}=.619.
\]

Eventually a clean streak becomes nearly certain. A failure requires investigation, not resetting the counter. Passes can accumulate across sessions on the same immutable candidate and protocol, but all valid observations remain included.

#### Define the experiment before counting

- Define a trial as a **validated exposure to the cause**, not merely a row invocation. Record seeds, trigger counters, workload state and fault placement.
- Prespecify calibration size or use a properly designed sequential method. “Run until the first failure” is not ordinary fixed-sample binomial calibration.
- Repeated requests during one shared stall are correlated, not independent trials.
- Seven failures on seven different boards are not automatically seven interchangeable observations of one probability.
- Do not transfer a rate across configurations/builds without validating trigger and detector sensitivity there. Keep old-build or genuine fix-off positive controls.
- A configuration need not have a historical failed board cell to be verified. It needs a validated causal exposure and appropriate evidence—not a bookkeeping loophole.
- For multiple rows, nominate the primary cause-exercising test and required invariants. Correlated symptoms do not multiply evidence. Collateral rows need regression checks and demonstrated dependency; genuinely different triggers need separate verification.

The requirement that fix-off fail **every** lap is wrong for intermittent defects. Require a functioning positive control and causal evidence under a predefined experiment.

A deterministic invariant test can have a different proof obligation. “20/20 failed” alone does not establish determinism.

**Cost:** focused repetitions can be expensive. Run targeted rows or smaller validated reproducers rather than whole boards. Improving the trigger generally buys more than accumulating weak laps.

### 4. Keep a build-only board, backed by a permanent incident ledger

**Prevents:** aging out failures, attribution laundering and erasing unresolved defects at version boundaries.

The board/gate split is sound, with two corrections:

1. The incident gate must include **all unresolved credible failures**, not only those since the last release.
2. Naming a failure is necessary but insufficient. Its record must have an evidence-backed disposition, scope and impact.

Keep raw outcomes append-only. Closure adds a disposition; it does not delete records or rewrite failures. The board should separately display:

- latest execution result;
- release-build qualification result;
- incident blockers.

Reject missing build identity rather than accepting an unstamped PASS. Key verification by candidate, configuration, platform, kernel and test protocol—not configuration alone.

Unexpected integrity assertions, hangs, kernel warnings and crashes on intermediate development builds need durable incident events. Avoid a ticket explosion through automatic duplicate links and parent incidents. Intentional negative controls should be declared **before execution**, with the expected failure signature. An abandoned development build does not automatically disprove a discovered defect; a compiler experiment is not automatically a filesystem incident.

Regex-based rig-noise exclusion is unsafe. `NO_TERMINAL_RECORD`, “killed” and “prep fail” can be downstream effects of a hung filesystem.

Use distinct outcomes:

- product assertion failure;
- proven infrastructure failure;
- incomplete/unknown;
- expected negative-control result;
- pass.

Infrastructure attribution needs positive evidence. A missing tool can invalidate a run, but cannot make it pass. An unexplained timeout remains unresolved. A detector-defect disposition needs replay or independent evidence showing the detector was wrong, followed by valid requalification.

Delete window-lap machinery once its replacement is tested. Add automated gate tests for missing stamps, stale evidence, platform mismatch, pending runs, wrong-record attribution and unresolved historical failures.

**Cost:** modest storage and implementation work. Automatic incident creation and deduplication reduce agent requests.

### 5. Invest first in integrity oracles and realistic failure boundaries

**Prevents:** a large green matrix that does not notice silent corruption or unsafe failover.

Prioritize:

1. **Independent data oracle.** Write generation-, offset- and object-tagged checksummed contents. Keep the expected durable state outside MeshXFS. Verify cross-node reads, reopen, remount and post-crash recovery. A structurally clean filesystem can still contain wrong user data.
2. **Cluster ownership and fencing tests.** Exercise partitions while both sides retain storage access, asymmetric path loss, delayed messages, stale owners and failed fencing. Verify that the old owner cannot continue protected I/O after ownership transfers.
3. **Durability/crash testing.** Record acknowledged `fsync`/flush boundaries and test allowed recovered states. Use dm-log-writes-style or target-level recording/replay where applicable, preserving CAW atomicity and actual flush/FUA semantics.
4. **Reuse mature regression groups.** Import suitable xfstests generic/XFS groups, then add clustered concurrency cases: inode reuse, orphan handling, rename/unlink, truncate, mmap, buffered/direct-I/O interaction and recovery.
5. **Seeded randomized histories.** Combine namespace operations, lock transfers and faults; retain seeds and minimize failing histories. Specify the consistency contract before applying a Jepsen-style checker.

Fault tests should prove that the intended fault and recovery path actually occurred. Otherwise they are invalid, not passes.

The single-host rig cannot validate independent physical failure domains, SAN firmware behavior or actual storage power-loss durability. VM power-off does not necessarily discard target/host caches. Seek targeted outside hardware testing and opt-in RC feedback **after internal safety gates**, not as a substitute for them. State the tested scope; do not use “test data only” disclaimers.

**Cost:** substantial initial oracle work, then good reuse. Run inexpensive integrity checks broadly and rotate expensive fault combinations.

### 6. Spend the remaining rig budget on meaningful detection power

**Prevents:** mistaking matrix breadth for intermittent-defect coverage.

For independent trials with per-trial failure probability \(p\):

\[
D(n)=1-(1-p)^n.
\]

| Exposure | \(p=1/10\) | \(p=1/20\) |
|---|---:|---:|
| One eligible trial | 10% | 5% |
| Fifteen eligible independent trials | \(1-.9^{15}=79.4\%\) | \(1-.95^{15}=53.7\%\) |

The fifteen-trial line applies only if **all fifteen configurations expose that defect** with the assumed probability. Hundreds of unrelated rows add no detection power for a configuration-specific race.

For 95% detection:

\[
n=\left\lceil\frac{\ln .05}{\ln(1-p)}\right\rceil;
\quad n_{.1}=29,\quad n_{.05}=59.
\]

Even zero failures in 59 independent trials gives only:

\[
p_{\text{upper}}=1-.05^{1/59}=4.95\%
\]

as a one-sided 95% upper bound—not zero risk.

Budget in this order:

1. Validate fixes and detectors before starting the full matrix.
2. Preserve one complete mandatory coverage pass.
3. Repeat high-risk cause exposures: default TCP, ownership transfer, fencing, inode reuse, recovery and changed code paths.
4. Use otherwise idle time for a **frozen-candidate soak**, including long-lived state accumulation, not just repeated cold starts.
5. Rotate secondary configurations across continuous campaigns while retaining mandatory release coverage.

Track per-row exposure, duration, build, seed, topology, resource pressure and failure signature. Use historical rates for scheduling and detecting changes, never as permission to call failures flaky.

A useful allocation heuristic is marginal detection per minute:

\[
\frac{\Delta D}{t}=\frac{p(1-p)^n}{t}.
\]

For \(p=.1,n=0,t=2\) minutes, this is \(.1/2=.05\) detection probability per minute. Weight by safety impact and trigger relevance; this is prioritization, not certification.

Stop candidate soaks before evidence sealing. Failures from “optional” candidate tests still count.

**Cost:** configurable. Prefer batch seed schedules and structured summaries over agent-driven lap-by-lap operation. Keep performance measurements isolated from soak contention.

### 7. Separate coding, adjudication and publication authority

**Prevents:** an agent making its own evidence sufficient by weakening the rules.

Use three roles:

- **Builder/runner:** changes code and runs frozen tests; cannot alter historical evidence or approve dispositions.
- **Independent reviewer:** challenges causal evidence, attribution, scope reductions, detector-defect findings and `noblock` classifications.
- **Publisher:** purely mechanical authorization against approved policy and evidence.

A second model is useful adversarial review, not independent statistical evidence or a substitute for access controls.

Machine-check:

- complete artifact and run identities;
- all required terminal results;
- unchanged test criteria;
- planned sample counts and inclusion of all observations;
- incident-to-run references and scope keys;
- required approval signatures.

Require owner approval for weakening safety policy, narrowing uncertain safety reach, converting a blocking safety record to `noblock`, or accepting an exceptional disposition. Safety closures should receive independent evidence review; routine successful executions should not require owner attention.

Protect gate changes like product changes: review them, replay stored failure fixtures, and qualify the new gate version before adoption. An agent must not repair its current release by modifying its judge.

On a host where an agent controls root and publication credentials, “structurally impossible” is unattainable. Keep publishing/signing authority outside that agent’s credentials, preferably with an external append-only evidence copy.

**Cost:** extra requests concentrated on consequential decisions, not every PASS. This is a better use of a second agent than another undirected test lap.

### 8. Keep performance nonblocking only through explicit, bounded classification

**Prevents:** turning `noblock` into a disposal bin for hangs and incomplete tests.

Separate three axes:

- functional/data-integrity correctness;
- bounded availability and recovery;
- throughput/latency objectives.

A test that exceeded its budget and was killed before completing assertions has not demonstrated functional success. A lock stall that triggers HA, VM I/O failure or operational recovery deadlines is a stability defect even if it eventually clears.

For each `noblock` decision require:

- the precise violated performance objective;
- completed correctness assertions;
- measured recovery/availability behavior against predefined limits;
- no evidence of an integrity or stability impact;
- independent approval and reassessment when new evidence appears.

Performance objectives also need an honest policy distinction: “within 2× XFS” cannot simultaneously be an unconditional product promise and a nonblocking aspiration.

Use matched durability, cache, storage and workload conditions:

\[
\text{throughput slowdown}=T_{\mathrm{XFS}}/T_{\mathrm{MeshXFS}};
\quad 1000/400=2.5,
\]

which misses a 2× target. Never mount native XFS concurrently from multiple hosts to manufacture a comparison; document the valid single-host or separately provisioned baseline.

**Cost:** a small isolated benchmark lane plus periodic queue review. Lower priority than safety, but its classification must remain difficult to abuse.

## Review of the first draft plan against the code, verbatim

An adversarial read of the draft plan against the tree, by a separate planning agent. Every finding was folded into the approved plan (`docs/release-process.md` describes the result).

The plan's main design holds, but it won't deliver its guarantees as written. Three gaps let a failure or an edit pass unseen:

- **Frozen-set gaps.** Row specs and verification records live in files the freeze excludes or writes to, and the alternate boards' row specs aren't frozen at all.
- **Build-keyed grading.** Grading on the module build ignores changes to tests and tools.
- **Non-board steps.** Their failures are never written to the ledger, so a retry on the next candidate washes them out.

Findings are ranked by how badly they break a guarantee. Each gives evidence, then the change to the plan.

### A. The freeze and the grading don't guarantee what they claim

1. **Row specs and platform verifications aren't frozen.** `criteria.py rows` and `budget_of` read whichever board `MXFS_CRIT` names (criteria.py:86, 366-379, 981-999). A mid-run `criteria.py update -b` or `--max-nodes` (844-850) changes budgets and dispatch without touching a frozen hash.
   - The alternate boards are stale copies that drifted. `drbd_rig.sh:594-597` and `prun.sh:75` copy data/criteria.json once. The DRBD rig's board has 45 rows against the primary's 54, and nothing freezes it.
   - `platforms.py verify` writes into data/platforms.json (platforms.py:87-91, 145). The plan freezes that file and also has the publisher write to it.
   - **Change:** hash a sorted projection of the spec fields of data/criteria.json, and of data/platforms.json without `verified`. Make `rows` and `budget_of` always read the spec from data/criteria.json; results still go to `MXFS_CRIT`. Refuse `add/remove/move/update -b|-r|-d|--coord|--min/max-nodes` while a candidate is RUNNING.

2. **Grading "on build B" ignores test, tool and script changes.** srcversion covers module sources only. An edited detector, test script or `chk_mxfs` leaves B unchanged.
   - **Change:** grade release qualification on runs with `candidate == C`. Keep "build B" only for the development view.

3. **Failures outside the boards never reach the ledger, so a retry launders them.** This covers PVE suite runs, packaged rounds, `tcp_peer_freeze_death`, sVirt, and the DRBD death/fence/split/outage/takeover tests.
   - They are graded only from the newest file's regex or last rc: release_status.py:144-212, drbd_release_verify.sh:61-86.
   - A FAIL on candidate 1 that passes on candidate 2 vanishes.
   - **Change:** the orchestrator writes one ledger line per step outcome (step as the row, plus kernel and platform). These lines get the same FAIL/INCOMPLETE semantics and go through the incident gate.

4. **The DRBD verification already passes with failed rows, and the plan inherits it.**
   - The suite step returns run.sh's exit code (drbd_rig.sh:608-609).
   - run.sh exits 0 when rows FAIL (2620-2649; scripts/ladder_rung.sh:25 says so).
   - `DRBD_RELEASE_VERIFY PASS` is printed anyway, and release.sh:147 accepts it.
   - **Change:** the DRBD step's verdict is the drbd board ledger graded for C, plus the other steps' own result lines.

5. **Module knobs survive into later runs.** `MXFS_EXTRA_MODARGS` and `MXFS_RETIRE_CONTRACT` are applied at insmod (run.sh:1117/1124, prep_node.sh:242). `marker_matches` doesn't compare them (run.sh:290-293). Every later filtered run, including each batch lap, records under B on a knob-flipped module. `MXFS_TEST_ENV` (1341/1708), `RULE0_CALIBRATE`, `SOAK_SECONDS` (2561), `MXFS_SETTLE_MS` and an external `MXFS_RIG_BUDGETS` are the same kind of problem.
   - **Change:** put the knob arguments into the marker and `marker_matches`. Record a `variant` field in the ledger. Variant runs never grade C, but their FAILs remain incidents. Take soak length from the policy file.

6. **Mid-step edits that are reverted escape the freeze.** Re-hashing happens only between steps. The hook covers Edit/Write only, while the allowlist permits Bash `sed`, `cp`, `mv` and `python3` (.claude/settings.json).
   - **Change:** at freeze, also record inode, size, mtime_ns and ctime_ns per file. Any ctime change sets INVALID even if the content matches.
   - The hook must exit 2 when a candidate is RUNNING and it can't decide. A non-2 error lets the edit through.

7. **The frozen set must be an explicit list.** "Every source, tool, test, script and policy file" is too vague. Every data/ file should be frozen unless named as mutable.

   | | Files |
   |---|---|
   | **Add** | Kernel sources: xfs/ dlm/ pal/ mxfs_clayer/ include/ compat/, Kbuild, Makefile, mxfs.c, VERSION |
   | | Packaged files: frontend/proxmox/**, docs/man/**, docs/drbd-setup.md |
   | | Root yardsticks: `.raw_fio_ceiling.*.json` and `.lrb_native.*` (read by fio_perf_vs_xfs.sh:68-98), alongside `.xfs_fio_baseline*` |
   | | tests/criteria/budgets.* (prun.sh:89-92) |
   | | data/rigs.json, data/release_policy.json, data/guards.json |
   | | .claude/agents/release-reviewer.md and the hook script |
   | | ~/.config/mxfslab/lab only |
   | **Exclude** | `lab.<platform>` files (full_verify.sh writes them per run, 153-155); `secrets` and `rig_fence_key` (don't put secret hashes in a manifest) |
   | | tests/suite/tools/fsx (rebuilt at every run start, run.sh:143-148); tools/.built_for |
   | | data/candidates/**, data/reviews/**, data/release_builds.json; every board's ledger file |
   | | bench/README.md, bench.json, index.db, .evidence/, .crash_seen, .run_lock |
   | | `.*_results.json`, `.cluster_marker*`, `.last_run*` |
   | | README.md and CHANGELOG.md (the publisher re-checks them) |

### B. The run ledger

8. **The ledger must be one file per board, not one data/runs.jsonl.** Its path should derive from the board path and it should share the board's lock. Scratch boards write through `MXFS_CRIT`:
   - aw_fill_reserve_ab.sh:83;
   - nq_wouldblock_ab.sh:43, which also flips module knobs;
   - degraded_member_cascade.sh:95;
   - criteria_lock_concurrency.sh:22/78, whose `finalize` writes ABORTED/NOT RUN on a copy;
   - the plan's own replay test.

   With one global ledger, all of these would create false incidents and knob-flipped runs graded as B.

   **Add a `board` field.** 2/net/mesh/drbd is a column in both the DRBD rig board (341 runs) and the pvephys board (72), but `board_for` (criteria.py:147-155) resolves only the DRBD rig's. **Change:** the incident gate reads only the declared release boards' ledgers.

9. **Migration will multiply failures.** The pvephys board (35 columns, 5,881 runs), the vSphere board (35, 5,879) and the DRBD rig board (28, 3,534) were started as copies of the primary. Seeding each ledger from every cell would count the primary's FAILs two to four times.
   - **Change:** seed a copy board only with runs whose (config, row, iso) is absent from the primary.
   - Seed the existing `detector_defect`, `retired_by`, `amendment_withdrawn` and `retirement_withdrawn` marks as annotation events (push_history 413-416).
   - Keep `iso` as the run key, because defects.json cells are CONFIG:ROW:ISO (defects.py:647-666). Store run_id as an attribute, null for legacy runs.
   - Checked: 6,801 primary runs, 0 key collisions, 335 date-only iso values.
   - Drop the `named_by` annotation. defects.json cells are the single source, and a removed record would otherwise leave stale ledger names behind.

10. **Write discipline.**
    - Append the ledger line and fsync before rewriting the board, under the same lock. Readers must tolerate a torn last line.
    - `update` must not grade. Its roll_up print at 891 would scan the ledger under a 30 s lock.
    - Multi-board retire/verify should take all board locks sorted by path, then append. retire_cells takes them in insertion order (769-772).
    - Make `migrate-keys` (1007) refuse once a ledger exists.

### C. Recording results

11. **Never refuse a result.** criteria.py:858-859 refuses unknown statuses, and `record()` discards both exit code and output (run.sh:622). That is exactly how BUDGET_EXHAUSTED became ABORTED.
    - The new "refuse without --build" rule reproduces the loss for every row whenever `WANT_SRCVER` is empty: run.sh:224 runs modinfo on a missing or rebuilding .ko.
    - **Change:** record unknown statuses as FAIL with the reason. `record()` checks the exit code and aborts loudly. run.sh refuses to start with an empty `WANT_SRCVER`.
    - Stamp the build from the nodes' `/sys/module/mxfs/srcversion` after prep, as prun.sh:50-62 does.
    - Don't exempt `--calibrate` from `--build`.
    - **On the 08:31–09:27 writer:** `chk_clean_16node_*.log` appears in tests/evidence about every 6 minutes beside `board_*_crash_audit` directories. No script in tests/, scripts/ or tools/ produces that name, so the driver is outside the tree. The refusal fixes it; don't block on finding it.

12. **The five outcomes don't cover what is actually written.**
    - The board holds PASS 6603, NOT RUN 113, FAIL 70, ABORTED 10, SKIP 4, BLOCKED 1.
    - run.sh writes SKIP (2547), BLOCKED (1652, 2565), FAIL "host_lock_wait" (2575), FAIL "prep failed" (2366/2399) and FAIL pre-assert (1420/1660).
    - run_coord also produces TRANSPORT_ERROR and MISSING_TERMINAL_RECORD (1785-1787), and lib.sh:331 produces ABORTED_BY_PEER.

    | Status | Should become |
    |---|---|
    | SKIP | Not applicable; not an incident |
    | NOT RUN, BLOCKED after a failed reconvergence, host_lock_wait | UNREACHED: not an observation and not an incident (otherwise ~113 dispositions for tests that never ran) |
    | Node-fault BLOCKED tagged `{MXFS}` | FAIL (stability) |
    | Node-fault BLOCKED tagged `{EXT4-ROOTDISK}` | INFRA (positive evidence) |
    | TRANSPORT_ERROR | FAIL unless the node is shown alive |
    | Pre-assert, not mounted | INCOMPLETE |
    | Pre-assert, mounted but readdir times out or gets EIO | FAIL (stability), attributed to the preceding row too |
    | prep_cluster failure | INFRA only if prep reports a stage before mount |

    Split the pre-assert probe so it can tell these apart. M5's "no iptables = INCOMPLETE" contradicts M1's INFRA rule; use INFRA.

13. **A stall over 30 s has no detector.** No row emits `max_stall_s`; `run_bounded` thresholds are per call (lib.sh:343-364). The owner's ">30 s" decision and M2.6's noblock condition are unenforceable.
    - **Change:** add a per-node stall measurement into `measured`, and have `record()` turn a stall over the limit into FAIL.

### D. Packages before qualification (item 5)

14. **The bench page makes packages depend on the boards.** release.sh:93 runs release_text_check before building. Its check 8 (278-282) runs `bench_report --check`, which compares bench/README.md against the latest fio_perf and fio_perf_vs_xfs cells and release_builds.json (bench_report.py:73-107). release_verify_chain.sh:296-301 regenerates the page after boards precisely so the package step passes.
    - Under packages-first, step 3 grades the page against pre-candidate boards, step 4 changes the cells, and the publisher's text check then fails.
    - Packages don't ship README.md or bench/ (packaging/common.sh:110-216, mkrpm.sh:75-94).
    - **Change:** split release_text_check. Checks 1-7 run before the build; check 8 runs at seal. bench_report reads ledger PASS runs with `candidate == C`. bench/README.md and release_builds.json are written at seal, with their hashes recorded in the manifest.

15. **The package tarball breaks on concurrent writes.** vm_package_build.sh:72-75 tars the whole tree, including data/*.json and the ledger. GNU tar exits 1 on "file changed as we read it", which fails the build if any board write happens during it.
    - **Change:** pack an explicit input list, as pve_tree_install.sh:31-39 does, and hash that list into the manifest.

### E. Verification batches (item 6)

16. **Batch recipe with today's run.sh:**
    - Prep with `./run.sh CFG [--group g] prep_cluster`. A run whose only row is prep_cluster always re-forms the cluster (2355-2370). `MXFS_FORCE_PREP` is never read by run.sh.
    - Then run `MXFS_BATCH=<bid> ./run.sh CFG [--group g] ROW` once per lap. A filtered run requires the marker to match (2372-2386).
    - Every lap also records a prep_cluster "skipped (marker matched)" PASS (2381). Tag it as support.
    - A chk_clean lap also runs alloc_witness (`in_only`, 2052-2066). Count only the target row; alloc_witness FAILs still count against alloc_witness at C.
    - Re-prep before the next lap after a failed reconvergence on the destructive rows (`DESTRUCTIVE_TESTS` 647, `BLOCK_REST` 2601). Re-prep before every lap of host rows that leave the cluster down (node_death_replay.sh:27, crash_audit, path_*). Add a `leaves_cluster` flag to the row spec.
    - Lap budget = row budget + 300 s prep + convergence.

    run.sh changes:
    - Read `MXFS_BATCH` and `MXFS_CANDIDATE` once at start.
    - Have criteria.py validate them before any row runs: batch declared and open, row/config/candidate match, fewer than N laps used. Refuse otherwise.
    - Pass `--batch/--run-id/--evidence/--seed/--variant` in `record()`, and the batch in `pending`, so finalize's ABORTED carries it.
    - Compute the evidence path before `record()` and move the call after the artifact pull (record at 1994, directory at 2033).
    - An INCOMPLETE lap ends the batch unless review records it as infra-proven.

17. **There is no exposure evidence on PASS laps.** Kernel logs are pulled only on non-PASS or with `MXFS_KEEP_ARTIFACTS`, and only in run_coord (1999). `verify` counts only exposed PASSes.
    - **Change:** evaluate the exposure probe on the node and emit it in `measured`.
    - Reusing L from the calibration configuration at a configuration where the defect never failed assumes the rate given exposure doesn't depend on configuration. State that in docs/release-process.md and in the proposal, or calibrate there too.

18. **A fix-off arm "on the candidate build" is impossible for code fixes.** It only works for fixes behind a module parameter.
    - **Change:** the fix-off arm is the candidate source with only the fix reverted (build B′, recorded as CONTROL with the diff hash), or the knob turned off on B and recorded as a variant CONTROL.

### F. Sequencing

19. **Several steps are in the wrong milestone.**
    - **Triage before review:** M1.5's triage needs M2.5's propose/review path, because the owner gave those dispositions to the reviewer. Move triage after M2.5.
    - **Reviewer agent registration:** project agents register at session start, so create release-reviewer.md in M0. Verification step 4 can only run in a later session.
    - **run_suite.sh and its callers:** tests/tcp/run_tcp.sh:6, tests/caw/run_caw.sh:6 and tests/tooling/run_tooling.sh:12 exec run_suite.sh. Once M1 refuses unstamped writes, run_one.sh:75 fails silently and still prints "recorded". Delete them all in M1 and drop harness_lint_baseline.json:29,38,39,56.
    - **Duplicate gates:** tools/board_failure_audit.py and tools/defect_stamps_only_here.py are a second, weaker incident gate (a stamp in CHANGELOG counts as named). Delete them with `--unattributed`.

20. **Orchestrator steps.**
    - Budgets taken from ledger elapsed times violate the rule that timeouts are derived from what the work should take, and the rule against wrapping run.sh in a timeout (CLAUDE.md:65-69). Bound each step by the sum of manifest row budgets plus measured infrastructure time; use ledger elapsed only to predict the schedule. Verification step 3 has the same problem.
    - The DAG has no guard-test step, which the default-path gate needs.
    - full_verify's platform list (`steps_of` 278-293) will drift from the orchestrator's DAG. Delete that half or have it call the orchestrator.

21. **Evidence keyed by version leaks across candidates.**
    - full_verify.sh:84-98 grades platforms not re-run "on its own last run of $V".
    - Also keyed by version: release_status's full_verify log and `drbd_release_verify_<V>.out`, release_builds.json, and dist/<V>.
    - release.sh:74-77 refuses to rebuild into an existing dist/V, and packaged_round.sh:91 hard-codes dist/$V.
    - **Change:** key every evidence path, dist directory and verdict lookup by candidate (e.g. dist/<V>/<n>/, plus a DIST override in packaged_round).

22. **release_status and defects.py can't serve as gates yet.**
    - release_status always exits 0 (360) and reads the live tree's mxfs.ko and VERSION (54-62).
    - `verified_here` and `tree_build` (defects.py:316-325, 741-749) and retire_cells (763) read the live tree too.
    - **Change:** add `--candidate C --gate`. Take the build set from the manifest: the rig srcversion plus each kernel's DKMS srcversion (release_status.py:27-29).

23. **Single-node rows.**
    - Twelve rows have max_nodes=1, not five. Also mkfs_timing, online_resize, dkms_install, single_node_paired, fio_vs_xfs_baseline, cluster_ops_timing and fault_io_error. Say why they stay off the release boards.
    - precond_xinit_coherency has min 2 and max 1, so it never runs anywhere.
    - run_none has no pre-assert (1299-1376). Add the mount/readdir/sync check before cluster boards use it.
    - run_host already has the mount check (1394-1425). Only the sync pass (1607-1658) is missing.
    - Measure fault_enospc's budget per node count first.

### G. Consumers that break (items 2 and 3)

24. **Board and status consumers.**
    - Text parsers:
      - board_laps.sh:58-63
      - board_4node_chain.sh:133-143 (the VERDICT line)
      - prun.sh:83-84 (parses table columns for the row list; use `criteria.py rows`)
      - full_verify.sh:251 (counts run.sh console status words) and 255
      - caw_ladder_fua.sh:24
      - dlm_scaling_diag.sh:41
      - harness_lint.py:78-79 (HL002 would flag `--incidents` and `--rates`; make them subcommands)
    - Python importers:
      - defects.py:683, 784-791, 835-836
      - release_status.py:88-96, 248
      - bench_report.py:91
      - board_failure_audit.py:33, 59-60
    - criteria.py internals:
      - 159-186 (`MARK`, `STATUSES`, `GREEN`), 616 (`roll_up`), 646-651 (show_one's window)
      - 720, 891, 967-971, 1091
      - 1096-1099, 1130-1133, 1160-1163 (flake_count prints), 1191-1197 (`--unattributed`)
    - Window-name importers beyond the deleted tools: defects.py:786-787, plus the awareness docs: tools.md:1327, 1413, 1419; tests.md:2093; structural-map.md:8084.

### H. Rules and process (item 7)

25. **The version rule.** The global version rule says an install of the open version closes it. The packaged rounds install it on lab VMs (packaged_round.sh:272). If that counts, a fix after candidate 1 needs 0.90.134 and `<V>-<n>` numbering breaks. Ask the owner and record the answer in the ruling.

26. **Conflicts with CLAUDE.md.**
    - The project rule says subagents return raw evidence, never conclusions. The reviewer agent's output is approve/reject. That's the owner's decision, but the M6 CLAUDE.md proposal must name it as the exception.
    - M0.3 uses tools/mxfs_pgrep.sh, which still reads `/proc/<pid>/cmdline` after a stat check (a race), and the global rules ban pgrep in any form. Check idleness with `runlock_rig_free` (runlock.sh:50-59), the `/tmp/mxfs_config.*` and `/tmp/mxfs_vmhold.*` locks, and an orchestrator lock. Use `/proc/*/comm` by name, as release_status.live_comms does, for the chain and PVE.
    - The project settings hook is a gate change, so it needs owner approval.
    - New code must not add `_`-prefixed keys like release_status.py:307-308.

27. **Verification step 3.**
    - Mark the dry-run candidate `dry_run` so it can never be QUALIFIED or published.
    - "A short soak" contradicts "hold the soak to its policy length"; pick one.
    - For the mid-run edit test, use a frozen file no step reads, such as a man page.

### Critical Files for Implementation
- /home/steve/src/mxfs/tools/criteria.py
- /home/steve/src/mxfs/run.sh
- /home/steve/src/mxfs/tools/defects.py
- /home/steve/src/mxfs/tools/release_status.py
- /home/steve/src/mxfs/tools/release_text_check.py (with /home/steve/src/mxfs/tools/bench_report.py)
