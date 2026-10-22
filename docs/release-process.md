# How a MeshXFS release is verified

A release is published from one frozen **release candidate**, after one orchestrator has run every
check on exactly that candidate and a mechanical publisher has confirmed the record. Every result
is kept, nothing ages out, and a defect stops blocking only on measured evidence that a second
agent has reviewed.

The decisions behind this design, the outside review that shaped it, and the questions the owner
answered are in `docs/rulings/release-verification-rework.md`.

## What it guarantees, and why each part exists

| Guarantee | Mechanism | The failure it prevents |
|---|---|---|
| A failure counts until something accounts for it | an append-only run ledger beside every board; the incident gate | a failure pushed out of a sliding window by passing laps |
| A verdict is about the build being released | grading per candidate | history from another build deciding a release |
| "Fixed" means measured | failure rates read from declared batches; verification batches sized from them | one passing run clearing an intermittent defect |
| Nobody grades their own homework | proposals reviewed by the `release-reviewer` agent; policy changes by the owner | a release agent narrowing, waiving or retiring its own blockers |
| Users on the default path are protected | the default-install gate | leaving a configuration out of the claims while every default install still runs it |
| What was checked is what ships | the candidate's frozen manifest and the publisher's checks | publishing before checks finish, verifying a stale module, editing a tool mid-run |

## The run ledger

Every board has a ledger beside it, `<board>.runs.jsonl`: `data/criteria.runs.jsonl` for the
primary board, and the same beside the DRBD rig's, the Proxmox pair's and the vSphere rig's
boards. `tools/criteria.py` is its only writer.

- **One line per run**, keyed by (configuration, row, ISO stamp). That is the key the defect
  queue uses to name a run. Each line carries the outcome, the raw status, the full reason, the
  measured text, elapsed time and the budget applied, the build (module srcversion), the
  candidate, any batch or variant, the run id, the evidence path, the seed, the platform and the
  kernel.
- **Annotations are separate lines**, appended next to the run they refer to: `retired_by` (a
  verified fix or a disposition retired it), `detector_defect` and `infra_proven` (a reviewed
  finding that the detector or the rig failed, not MeshXFS), and `withdrawn` (one of those taken
  back). No line is ever rewritten.
- **Write order.** The ledger line is appended and fsynced under the board's lock before the
  board file is rewritten, so the board can never get ahead of the ledger. A reader skips a torn
  last line; it never repairs one.
- **The board file is a display.** It keeps each cell's latest run and a short history, but no
  verdict is computed from it.
- **One specification.** Every row's requirement, detector, budget, dispatch class and node range
  live in `data/criteria.json`. A board kept elsewhere (`MXFS_CRIT`) receives results only, so a
  copy cannot drift or be edited to change what a row means.

## What a run says

The harness records the outcome where it knows it. A status the board does not recognise is
recorded as FAIL with its text, never refused: a refused result is a lost result.

| Outcome | Meaning | Incident? |
|---|---|---|
| PASS | the row's assertions held within its budget | no |
| FAIL | a fault was detected; the row overran its budget; or a file operation stalled longer than the policy's `stall_limit_s` | yes |
| INFRA | the harness proved, with positive evidence from outside MeshXFS, that the rig failed first | yes, until a reviewed `infra-proven` disposition settles it |
| INCOMPLETE | the run measured nothing and nobody yet knows why (a hung mount looks like this too) | yes |
| UNREACHED | the run never got to the row | no: not an observation |
| SKIP | the row does not apply | no |
| CONTROL | a negative control declared before it ran | no |

**Stalls.** A file operation stalled longer than `stall_limit_s` (30 s) is a stability failure,
whatever status the row reported. That is the usual SCSI command timeout inside a VM guest: past
it, the guests on a datastore start failing their own I/O.

**Variants.** A run with a module knob set, a test environment override or rig-specific budgets
is recorded with a `variant`. A variant run never grades a candidate. Its failures are still
incidents.

## Grading

- **For a candidate** (`--candidate C`), a cell reads PASS only when all of these hold:
  - the runs on C hold no FAIL, unless every FAIL is named by an open `noblock` record;
  - they hold no unresolved INCOMPLETE;
  - they hold at least the policy's required number of PASSes.

  Runs on any other candidate or build never grade C.
- **For development**, with no candidate, a cell is graded by build: the one named with
  `--build`, or the build of the row's newest run.
- **One run, by its run id** (`criteria.py lap <run id>`). A harness that runs whole boards
  grades each lap from the runs that lap recorded, never from the board, because the board also
  shows rows the lap never reached.

## The incident gate

`tools/criteria.py incidents` lists every FAIL and INCOMPLETE on the release boards, from any build
and any candidate, that nothing accounts for. It exits 1 while the list is not empty. A run leaves
the list in one of two ways:

- an open defect record names it in its `cells`; the record then blocks or does not by its own
  impact and reach;
- a reviewed disposition settles it: retired by a verification or a removal, or annotated as a
  detector defect or a proven infrastructure fault.

Nothing leaves by age, and no regular expression over a failure's reason excuses it. A missing
instrument can make a run INFRA, but it can never make a run pass.

## The defect queue: measured rates, declared batches

`tools/defects.py` keeps the queue. Membership is the status: a record is in the queue until it
is removed with evidence. These are the parts that decide whether a record still blocks a release.

### Measuring a rate

A record's failure rate is read from the ledger, never typed in.

1. **Declare a calibration batch** before its first lap: `defects.py batch <id> --kind calibrate
   --row R --at X --runs n`, on a build that has the defect.
2. **Run its laps:** `MXFS_BATCH=<batch> ./run.sh X R`. run.sh and `criteria.py` refuse a lap that
   is not part of an open, declared batch with that row, configuration and candidate, and a lap
   past the planned count.
3. **Close it:** `defects.py measure <id> --batch <batch>` records k failures in n exposed laps.

**Exposure.** A batch names a probe, a kernel-log pattern showing that the lap reached the
defect's trigger. A PASS without exposure is not a trial: it says nothing about whether the cause
is gone. A FAIL counts as exposed, because the failure is the trigger firing.

### Verifying a fix

`defects.py plan-verify <id> --at X --row R --probe P --candidate C` declares a verification
batch. Its size is fixed before the first lap, from the measured rate:

- L is the one-sided Clopper–Pearson lower bound of the rate at confidence 1 − δ:
  L = BetaQuantile(δ; k, n − k + 1). When every calibration lap failed, L = δ^(1/n).
- N = ⌈ln α / ln(1 − L)⌉. If the defect still failed at rate L, the chance that N laps would all
  pass is α.
- The policy sets δ = α = 0.005, so a verification has at most about a 1% chance of clearing a
  defect that is still there.

| Calibration (k failures of n) | L | Clean laps needed |
|---|---|---|
| 7 of 7 | 0.469 | 9 |
| 20 of 20 | 0.767 | 4 |
| 1 of 1 | 0.005 | 1058 |

A single sighting therefore buys no cheap verification. The way to make verification affordable
is a better reproducer, never a smaller batch.

**The verification itself.** `defects.py verify <id> --batch <batch> --approval <proposal>` needs
the planned number of exposed PASSes and no FAIL, and every INCOMPLETE lap must be settled. The
first FAIL ends the batch for good: its runs are named by the record, and a new batch needs a new
finding written into the record first.

**No streaks.** There is no "N passes in a row" counter that resets. A defect failing 1 lap in 10
passes a 29-lap batch 4.7% of the time, so twenty fresh attempts at that batch would clear it
about 62% of the time. Counting until it comes out green measures nothing.

**What a verification clears.** A passed batch stops the record blocking that configuration and
platform on that candidate only (`verified_at`). The record stays open. Removing it is a separate
disposition.

**Transfer.** A rate measured at one configuration is used at another only with `--transfer "why
the rate given exposure carries over"`, which the reviewer checks. Otherwise the rate must be
measured there. The verification batch needs exposure at its own configuration either way.

### Removing a record

- **FIXED AND VERIFIED** (`remove --fixed --control <batch> --fixon <batch> --cause "..."`) needs
  all of these:
  - a reproducer;
  - a closed control batch with the fix taken out that reproduced the failure (k ≥ 1): either the
    candidate's source with only the fix reverted, recorded as a variant with the diff's hash, or
    the fix's knob turned off;
  - a passed verification batch with the fix in, sized from that control's rate;
  - an approval.

  Without a control that reproduces the failure, nothing shows the fix is what ended it, and the
  record can be neither verified nor removed. A defect that stopped reproducing after unrelated
  changes is unexplained, not fixed.
- **DISPROVED** (`remove --disproved`) needs an approval of the direct evidence that the behaviour
  was not a MeshXFS defect.

## Reviewed decisions

Every decision that stops something blocking a release goes through a proposal:

| Proposal kind | What it changes | What it must carry |
|---|---|---|
| `noblock` | the record no longer blocks releases (it stays open) | the performance objective it violates, the correctness assertions every named run completed, and a measured worst stall under `stall_limit_s` |
| `narrow` | the record's `nodes`, `config` or `platform` reach | the runs that show the precondition |
| `verify` | applies a passed verification batch | the batch |
| `remove-fixed`, `remove-disproved` | removes the record | as above |
| `detector-defect` | settles one run as the detector's fault | the run, the evidence, and the detector fix already in the tree |
| `infra-proven` | settles one run as the rig's fault | the run and the positive evidence from outside MeshXFS |
| `exception` | the record stops blocking one configuration in one release (it stays open) | the owner's exception in the policy file, naming the record, the configuration and the release, with the question and the owner's answer |

1. `defects.py propose <kind> ... --argument "..." --evidence <path> ...` records the proposal as
   pending. Every evidence path must exist in the tree.
2. The `release-reviewer` agent (`.claude/agents/release-reviewer.md`) reads the proposal and
   every piece of evidence it cites, checks it against the policy, writes
   `data/reviews/<proposal>.md`, and records its verdict with `defects.py review <proposal>
   --approve|--reject --file <review>`. The review file's hash is recorded with the verdict.
3. The change is made naming the approval (`--approval <proposal>`). The tool refuses unless that
   approved proposal exists, is for exactly this change, and its review file has not changed
   since the review. An approval is used once.

**The owner approves the gate itself:** the policy numbers, the gate rules and any exception.
Each approval is recorded in `data/release_policy.json` with the question and the answer.
Publishing stays delegated, because the publisher decides nothing.

**An exception takes both keys.** The owner grants it in the policy file's `exceptions`, for
named records at named configurations in one release. It changes nothing until an `exception`
proposal applying exactly that is approved and `defects.py except <id> --at X --candidate C
--approval P` records it on the record (`excepted_at`). The record stays open with its bar and
reach, blocks every other configuration and release, and blocks this one again if the policy stops
granting the exception.

The reviewer agent returns a verdict, not raw evidence. That is deliberate: its job is to judge
the evidence another agent assembled, and its review file is kept as the record of that
judgement.

## The policy file

`data/release_policy.json` holds the gate's numbers. Every value is an owner decision, recorded in
the same file.

| Field | Value | What it is |
|---|---|---|
| `delta`, `alpha` | 0.005, 0.005 | the error budget of one verification decision: about 1% in all |
| `stall_limit_s` | 30 | a longer file-operation stall is a stability failure, not a performance one |
| `qualification_budget_h` | 12 | the rig hours one qualification may use |
| `required_runs` | 1 | PASSes a cell needs on the candidate in the coverage pass |
| `repeat_rows` | default-path fault and recovery rows, `sustained_load` and `soak` | what the detection budget repeats |
| `default_install` | `net/mesh/*` | what a package installed with its defaults runs |
| `exceptions` | per release | open records the owner let stop blocking named configurations in that release |

## The default install path

The packages load the module with the network lock manager on any attachment and at any node count.
Everyone who installs a package with its defaults therefore runs every `net/mesh` configuration,
whether the release claims it or not.

So `release_status --gate` fails the whole release when any record that is not `noblock` reaches
one of those configurations, at the node counts the release table names or in its
`released_earlier` list. The only exception is a configuration with a guard in `data/guards.json`
whose test passed on the candidate: the package refuses that configuration and tells the user
what to use instead. Leaving a configuration out of the claims exempts nothing.

## The release candidate

`tools/release_candidate.py create` freezes the tree as the candidate for `VERSION`: the candidate
is the version, `0.90.134`, with no suffix. It needs `mxfs.ko` and the tools already built. The
manifest, `data/candidates/<version>.json`, records:

- every frozen file with its sha256, inode, size, mtime and ctime;
- a hash of the board's specification fields, and of `data/platforms.json` without its
  verification records (results are written into both files during qualification);
- the module's srcversion and sha256;
- each step's state and evidence, the packages and their hashes, and each Proxmox kernel's
  module build.

**What is frozen:**

- the kernel sources, `run.sh`, `tests/`, `tools/`, `scripts/` and `packaging/`;
- the Proxmox frontend, the man pages and the DRBD setup guide;
- the native-XFS yardsticks;
- every file under `data/` except the results the qualification itself writes (boards, ledgers,
  the defect queue, proposals and reviews, candidates);
- the reviewer agent's definition, the project settings that install the edit hook, and the lab
  file.

Secrets are never hashed.

**Drift.** Any change sets the candidate INVALID: content changed, or a file touched and restored
(its ctime moved even though its content matches), added or gone, the specification or the
platforms changed, or a different `mxfs.ko`. The orchestrator checks before every step and at
sealing, and the publisher checks again.

**The edit hook** (`scripts/candidate_freeze_hook.py`, a `PreToolUse` hook on Edit, Write and
NotebookEdit) refuses an edit to a frozen file while a candidate is RUNNING. When it cannot tell,
it refuses. An edit made another way, through the shell, is caught by drift. `criteria.py`'s
specification-changing subcommands refuse while a candidate is being qualified.

**States:** RUNNING → QUALIFIED → PUBLISHED; RUNNING → COMPLETE_FAILED, BLOCKED or INVALID; any
state → ABANDONED. A `--dry-run` candidate exercises the machinery and can never be QUALIFIED or
published. When every step passes it ends ABANDONED. Its seal refuses by construction, since the
candidate is never published, so a refused dry-run seal is recorded as CONTROL, not as an incident
(owner, 2026-10-22). Every other step of a dry run is graded as usual.

**Attempts.** Freezing a version again, once its last attempt has ended (COMPLETE_FAILED,
INVALID or ABANDONED), starts a new attempt under the same name. The earlier attempts stay in the
manifest's `attempts`, with their frozen lists, steps and package hashes. A version that was
QUALIFIED or PUBLISHED is never frozen again; the next release is a new VERSION. Nothing is
frozen while an orchestrator still runs: an ended attempt's runner would go on recording runs
under the same name, and they would grade the new attempt.

- Grading for the candidate counts only the runs made after its current attempt was frozen, so an
  earlier attempt's runs, from another tree, never grade it. Batch laps and the benchmark page
  count the same way.
- Every evidence file and harness label of an attempt is named `<version>_<freeze time>`. The
  version alone is also what a plain run of a harness logs under, so a step that read its verdict
  from a file named by the version could read a run that was not its own.

**Versions.** Installing a candidate's packages on lab VMs is qualification. It does not close
the version. The version closes when it is committed, pushed or published.

## The orchestrator

`tools/release_run.py start <candidate>` runs every step detached, in order, and resumes from the
manifest. Each step's outcome goes into the manifest and also into the primary ledger as a run of
row `release:<step>`. A step that failed on one candidate and passed on the next is therefore
still an incident until a record names it.

| Step | What it does |
|---|---|
| freeze | the frozen files are unchanged (checked again before every step) |
| presteps | the harness lint, the offline checker's calibration, then on a 2-node pair formed on the candidate's module the rig library's contract and the capture fault gate |
| build | a clean copy builds the same srcversion; the tools, the user-mode tests and the source audits pass |
| textcheck | the text the packages ship (manual pages, module options, storage plugin, the module's own text) agrees with the release data. The README's release claims and the benchmark page ship in no package; they are written when the version is released and checked at seal |
| packages | the packages, from an explicit list of inputs, into `dist/<version>/`, before anything is verified on them. An earlier unpublished build there is removed first; a published one stops the step |
| boards | every released configuration's board, in waves on disjoint rig groups |
| drbd | the DRBD dual-primary verification, graded from the DRBD board's ledger for this candidate and its own verdict line |
| pve:\<kernel\> | the Proxmox VE suite on each claimed kernel; the module build there goes into the manifest |
| platforms | every released platform's packaged install and hung-node test, on these packages |
| guards | each declared guard's test |
| batches | the open verification batches declared for this candidate |
| repeats | the repeat rounds `tools/release_plan.py` schedules within the budget |
| seal | the benchmark page from this candidate's runs, all public-text checks, the incident gate, `release_status --candidate --gate`, and a last freeze check |

Verdicts come from terminal lines and ledgers, never from an exit code alone. run.sh exits 0 over
a failed row. The candidate is QUALIFIED only when the seal finds every step passed.

**Bounds.** Every row enforces its own derived budget, so run.sh is never wrapped in a timeout.
Every other step script is bounded by what its own header derives.

A scoped run (`--only`, `--configs`, `--platforms`, `--skip`) is allowed only on a dry-run
candidate and never seals.

## Spending the budget on detection

One coverage pass runs each row about once per configuration. Against an unknown intermittent
defect that is weak:

| Exposures | Detection at p = 1/10 | Detection at p = 1/20 |
|---|---|---|
| 1 | 10% | 5% |
| 15, all exposing the defect | 79.4% | 53.7% |
| for 95% | 29 | 59 |

Hundreds of unrelated rows add nothing against a race in one configuration. What is left of the
12 hours goes first to the verification batches, then to repeat rounds that `tools/release_plan.py`
fits into the rest. A round is one run of the `repeat_rows` (the default-path fault and recovery
rows, `sustained_load` and `soak`) on each default-install configuration the release claims.

**No row runs for a chosen length of time.** Each one is a fixed workload with a budget of 2× what
native XFS measured for the same work. The soak is 1112 operations with seeded file sizes, not a
number of seconds: a test sized in seconds only fails when it hangs, which is not a performance
assertion. Exposure comes from more rounds, never from a longer test.

Every failure in these counts like any other. `criteria.py rates` gives each row's recorded rate,
which is used for scheduling only and is never permission to call a failure flaky.

## The publisher

`scripts/release.sh --publish --candidate <id>` refuses unless all of these hold:

- the candidate is QUALIFIED and not a dry run;
- nothing frozen has drifted;
- the packages in its `dist/` directory are exactly the ones in the manifest, by hash;
- every step passed;
- the incident gate passes;
- `release_status --candidate <id> --gate` passes.

It then checks the public text, including the benchmark page, against the candidate, and
publishes. It decides nothing else.

## Limits of the design

- **Not unforgeable.** One host and one account run the agents, the tools and the publisher. The
  hashes, the review trail and the publisher's checks make a bypass visible and deliberate; they
  cannot make it impossible. Keeping publishing credentials and an append-only copy of the
  evidence outside that account would.
- **Statistics bound a known defect, not unknown ones.** A verification batch bounds the chance
  that a measured defect is still there. Nothing here bounds the chance of a defect nobody has
  seen. The detection budget raises the odds of seeing one; it proves nothing.
- **The transfer assumption.** Using a rate measured at one configuration at another assumes that
  the failure rate given exposure does not depend on configuration. The `--transfer` text states
  that assumption for the reviewer to check, and measuring the rate there removes it.
- **Reach by node count.** A record's `nodes` is the smallest cluster it was seen on, so a defect
  seen only at 32 nodes does not block a 2-16 node release. Races need not get worse as nodes are
  added, so this is a known exposure. The owner chose to keep it.

## Open

- **Coverage beyond the matrix**, each planned separately:
  - an independent tagged-data oracle, so silent wrong data is caught even when the filesystem is
    structurally clean;
  - crash-consistency recording;
  - xfstests groups;
  - seeded randomized histories.
