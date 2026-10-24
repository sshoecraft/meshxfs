#!/usr/bin/env python3
"""The defect ledger: what is broken and still needs work.

THE ONE WAY IN OR OUT. This file is the only reader and the only writer of `data/defects.json`.
Hand-editing the JSON is how two sessions end up disagreeing about what is open, and how an entry
acquires a field nothing else understands.

IT IS A WORK QUEUE, NEVER AN ARCHIVE. A defect that is fixed is REMOVED and the fix becomes a
`CHANGELOG.md` entry. There is no closed status, no resolved status, no pending-verification status
-- an entry that had one would still be sitting in the queue telling every session it was work.

WHAT REPLACED WHAT. `defects.sh` was read-only by design, so adding an entry or transitioning one
meant hand-editing megabytes of JSON, which is why the `tools/ledger_*.py` files exist: written to
make single edits the reader could not. That whole shape is gone.

EVERY DEFECT NAMES THE CONFIGURATION IT REACHES. A defect observed only at 32 nodes on the CAW
DLM does not block a 2-node TCP release, and a queue that cannot say so makes every release
wait on every defect -- which is how a queue stops being a queue and becomes a wall. Two fields
say it, and they DEFAULT TO BLOCKING EVERYTHING:

    nodes   the SMALLEST cluster the defect has been observed on.  1, 2, 4, 32...
            An entry with nodes=2 blocks a 2-node release and every larger one.
            An entry with nodes=32 blocks nothing smaller than 32.
    config  the configurations the evidence reaches, as a class/method/attach pattern
            (tools/configuration.py): `*/*/*` reaches every one and is the default,
            `disk/caw/*` every CAW configuration whatever the attachment,
            `net/mesh/direct` exactly one.  Narrowing it is a claim about reach and
            needs the evidence to say so, exactly like a severity does.  It replaced a
            `dlm` field whose values were compared to the view by exact string, so a
            record tagged `caw` never appeared in a `cawd` view and the reverse.
    platform  the operating system it reaches: a key of data/platforms.json (pve9,
            rhel9, ...) or `any`, the default.  A defect in the RHEL 9 build does not
            block a Proxmox release; one that has only been seen on the Ubuntu rig
            still blocks every platform until someone shows it cannot reach them.

Narrowing these fields DISPOSES OF NOTHING. It records which release an open defect blocks; the
defect stays open, stays in the queue, and still has to be fixed.

WHAT A RELEASE BAR IS, AND WHY IT IS NOT THE SAME AS REACH. `nodes`/`config` say which
configurations can exercise a defect. `impact` says whether the behaviour is one this release
refuses to ship: `integrity` (it corrupts or loses data), `stability` (it crashes, hangs or
shuts a node down), `verify` (the bar is unestablished and someone has to measure it), or
`noblock` (measured, and it does neither). `--release` keeps everything except `noblock`, so an
UNADJUDICATED record blocks -- deciding a record is harmless is a judgement someone makes and
signs, never a default. Setting it requires `--impact-why`, because "it does not corrupt data
and does not crash a node" is a claim about what was measured, and a bar set without one is the
relabel this queue exists to make impossible. Like a reach narrowing, an `impact` of `noblock`
DISPOSES OF NOTHING: the defect stays open, stays in the queue, and still has to be fixed.

    tools/defects.py                          the queue, severity order, one line each
    tools/defects.py -d                       the same queue with each one's next step
    tools/defects.py 2/net/mesh/direct        only what blocks that configuration (also --at)
    tools/defects.py 2/disk                   ... every disk-class configuration at 2 nodes
    tools/defects.py 2/net/mesh/direct --release --gate    exit 1 while anything still blocks it
    tools/defects.py 2/net/mesh/direct@pve9 --release --gate  the same, for one platform
    tools/defects.py show <id>                one entry in full
    tools/defects.py add     -s high -m "..." [-N 2] [-C net/mesh] [-n "next step"] [-w "how it shows"]
    tools/defects.py update  <id> [-s ...] [-m ...] [-N ...] [-C ...] [-n ...] [-w ...]
    tools/defects.py update  <id> -I noblock --impact-why "what was measured"
    tools/defects.py update  <id> --cell 4/net/mesh/direct:alloc_witness:2026-10-20T07:38:35Z
    tools/defects.py update  <id> --collateral "4/net/mesh/direct:chk_clean:<iso>=the log line"
    tools/defects.py update  <id> --reproducer "command, and how it reaches the cause"
    tools/defects.py batch   <id> --kind calibrate|control|verify --row R --at C --runs N --probe RE
    tools/defects.py measure <id> --batch <bid>          close a calibration or control batch
    tools/defects.py plan-verify <id> --row R --at C --candidate <cand>   size a verification batch
    tools/defects.py verify  <id> --batch <bid> --approval <proposal>
    tools/defects.py propose <kind> ... ; tools/defects.py review <proposal> --approve|--reject --file F
    tools/defects.py remove  <id> --fixed --control <bid> --fixon <bid> --cause "..." --why "..." --approval <p>
    tools/defects.py remove  <id> --disproved --why "what was measured and what it said" --approval <p>

EVERY BOARD FAILURE A RECORD ACCOUNTS FOR IS NAMED, NOT DESCRIBED. `--cell CONFIG:ROW:ISO` is
one recorded run of a board row (its stamp exactly as `tools/criteria.py show <row>` prints it),
checked against the board's run ledger when it is given; `--collateral CONFIG:ROW:ISO=<evidence>`
is a run that failed because of this defect without measuring it (a node that could not unmount
behind the hung creates), with the log line that shows the dependency. `tools/criteria.py
incidents` lists every failure on the release boards that no open record names -- from any build,
for as long as it is unnamed.

A DEFECT IS CLEARED BY A RUN COUNT DERIVED FROM ITS MEASURED RATE, NEVER BY A GUESS. A record
carries the failure rate its reproducer was measured at: k failures in n laps of a declared
calibration batch (`batch --kind calibrate`, then `measure`), read from the board's run ledger,
never typed. From it, `plan-verify` sizes a verification batch: L is the one-sided Clopper-Pearson
lower bound of k/n at the policy's delta, and N = ceil(ln alpha / ln(1 - L)) clean laps
(data/release_policy.json: delta = alpha = 0.005, a 1% chance overall of clearing a defect that is
still there). 7 of 7 needs 9 clean laps; 20 of 20 needs 4; a single sighting needs about 1,058,
which is the arithmetic telling you to build a better reproducer first. Every lap of a declared
batch counts: a failure ends the batch for good, and a new one needs a new finding. A lap counts
toward N only if its exposure probe shows the defect's trigger was reached.

FIXED AND VERIFIED NEEDS A POSITIVE CONTROL. `remove --fixed` needs a control batch with the fix
taken out (the candidate's source with only the fix reverted, or its knob turned off) that
reproduces the failure, a fix-on batch sized from that control's rate that passes every lap with
exposure, and the proven cause. A defect that no control can reproduce can be neither verified nor
removed: passing laps cannot close it. `--disproved` needs direct evidence and no batch.

DECISIONS THAT STOP A DEFECT BLOCKING ARE REVIEWED. A `noblock` impact, a narrower reach (more
nodes, another config or platform), a `verify`, a removal, and the board's detector-defect and
infra annotations each need an approved proposal: `propose` records what is asked and why, the
release-reviewer agent (.claude/agents/release-reviewer.md) checks the evidence and records its
verdict with `review`, and the command that makes the change names the approval. Decisions that
make a record block MORE need nothing. The owner decided this on 2026-10-21
(docs/rulings/release-verification-rework.md).
    tools/defects.py rename  <id> D-NEW-SHORTER-ID-0962   a new id, nothing else changes

AN ID IS AT MOST 80 CHARACTERS. It is minted from the summary, so a summary that opens with a
paragraph mints an id nobody can type, grep for or read in a one-line listing -- and truncating one
is not available, because evidence directories, memories and CHANGELOG entries already name the
record. Over the limit, `add` and `rename` REFUSE and ask for a name: pass `--id D-SHORT-NAME`.
    tools/defects.py --json                   the whole queue, for a script
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import math
import os
import re
import signal
import sys
import time
import uuid
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import configuration  # noqa: E402  (tools/configuration.py: the only parser of a configuration)

#: `defects.py | head` closes the pipe under us, and python turns that into a traceback on stderr
#: plus a non-zero exit. Restoring the default disposition makes it exit quietly, the way every
#: other command in a pipeline does -- a queue nobody can pipe is a queue nobody greps.
try:
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
except (AttributeError, ValueError):
    pass

ROOT = Path(__file__).resolve().parents[1]
#: `MXFS_DEFECTS` points at another queue file, for replaying recorded queues
#: (tests/release_gate/replay.sh) without touching the live one.
LEDGER = Path(os.environ["MXFS_DEFECTS"]) if os.environ.get("MXFS_DEFECTS") \
    else ROOT / "data" / "defects.json"
#: The proposals the reviewer rules on, kept beside the queue they change.
PROPOSALS = LEDGER.with_name("proposals.json") if os.environ.get("MXFS_DEFECTS") \
    else ROOT / "data" / "proposals.json"
REVIEWS = ROOT / "data" / "reviews"

#: Ordered worst-first. Anything else sorts last rather than being dropped -- an unfamiliar severity
#: must never make a defect vanish out of the queue.
SEVERITIES = ("critical", "high", "major", "medium", "minor")

#: `*/*/*` is the fail-closed default: it reaches every configuration, so an entry nobody has
#: classified holds up every release rather than quietly sliding out of one.
DEFAULT_NODES = 1
DEFAULT_CONFIG = "*/*/*"

#: The platforms a defect can be scoped to are the keys of data/platforms.json, plus `any`, the
#: fail-closed default. Read from the registry so a platform added there is valid here at once.
DEFAULT_PLATFORM = "any"
PLATFORM_REGISTRY = Path(__file__).resolve().parents[1] / "data" / "platforms.json"


def platform_keys() -> tuple:
    try:
        with open(PLATFORM_REGISTRY) as handle:
            return (DEFAULT_PLATFORM,) + tuple(json.load(handle)["platforms"])
    except (OSError, ValueError, KeyError):
        return (DEFAULT_PLATFORM,)


PLATFORMS = platform_keys()

#: HOW a record's reach was set, which is not the same question as what it was set to.
#:
#: A keyword sweep over a record's prose gives a useful number today; only reading the evidence
#: gives a number you can release on. Recording which one happened lets the queue report both,
#: instead of forcing a choice between a heuristic everyone half-trusts and a 93-record wall
#: nobody starts. `heuristic` is explicitly NOT an adjudication: a record whose text names CAW may
#: still reproduce over TCP, and the sweep only reports that the record does not say so.
REACH_SOURCES = ("default", "heuristic", "evidence")
DEFAULT_SOURCE = "default"

#: What this release refuses to ship, adjudicated per record. Absent means UNADJUDICATED, which
#: blocks -- the same fail-closed shape as an unexamined reach. `verify` is the honest answer when
#: the bar has not been measured yet: it blocks, and it says why it blocks.
IMPACTS = ("integrity", "stability", "verify", "noblock")

#: The bar values that are not a blocker for a release. Only one, and it is the only value that
#: takes a record OUT of `--release`, so it is the one that has to be earned.
IMPACT_CLEAR = ("noblock",)

FIELDS = {"severity": "s", "summary": "m", "next": "n", "evidence": "w",
          "nodes": "N", "config": "C", "platform": "P", "impact": "I", "impact_why": "impact-why"}

#: Held across the whole read-modify-write of every mutating subcommand. The ledger is one JSON
#: document rewritten whole, so without this two concurrent `remove`s each read the same snapshot,
#: each write their own, and the later write silently resurrects the record the earlier one took
#: out -- both reporting success, in a file that carries no dates, so nothing afterwards shows it
#: happened. Measured 2026-09-17 on a copy of the real ledger.
LOCK = LEDGER.with_name(".defects.lock")
MUTATORS = ("add", "update", "remove", "verify", "rename", "migrate-config", "batch", "measure",
            "plan-verify", "propose", "review", "except", "retire")

#: A save measures ~6 ms on the real 858 KB ledger, so anything still holding the lock after this
#: long is wedged rather than busy, and saying so beats blocking a session forever.
LOCK_WAIT_SECONDS = 30

#: A run named as CONFIG:ROW:ISO may carry a date alone, as the runs the board migration brought
#: into the ledgers do (D-DEFECTS-PARSE-CELL-REFUSES-A-DAY-STAMP-SO-MIGRATED-RUNS-CANNOT-BE-NAMED).
#: MXFS_CELL_DAY_STAMP=0 takes only a full stamp, as before: the control.
CELL_DAY_STAMP = os.environ.get("MXFS_CELL_DAY_STAMP", "1") != "0"

#: For `lift_config` only: what a leading bare configuration must not be mistaken for.
SUBCOMMANDS = ("show", "add", "update", "remove", "verify", "rename", "migrate-config", "batch",
               "measure", "plan-verify", "batch-check", "propose", "review", "proposal", "except")
VALUE_FLAGS = ("-s", "--severity", "--at", "--candidate")

ORDERED = ("id", "severity", "nodes", "config", "platform", "opened", "updated", "summary",
           "evidence", "next", "cells", "collateral", "reproducer", "ab", "reproducible",
           "verified_at", "excepted_at", "batches", "rates")

#: What a declared batch of laps is for. A calibration measures the defect's rate on the build
#: that has it; a control measures it with the fix taken out of the candidate; a verification
#: runs the planned number of laps with the fix in.
BATCH_KINDS = ("calibrate", "control", "verify")

#: What a proposal can ask for. Each is a decision that stops a defect, or a failure, blocking.
PROPOSAL_KINDS = ("noblock", "narrow", "verify", "remove-fixed", "remove-disproved",
                  "detector-defect", "infra-proven", "exception", "retire")


#: The open lock file, kept for the process's lifetime so the lock is held until it exits. Nothing
#: reads it; binding it is what stops the handle being closed and the lock dropped mid-command.
lock_handle = None


def take_lock() -> None:
    """Hold an exclusive lock for the whole read-modify-write, or say who is holding it.

    A lock taken around `save` alone would not help: the window that loses a record opens at
    `load`, so the lock has to span both. Waiting is bounded rather than indefinite -- a holder
    that has not finished in far longer than a write takes is wedged, and a session told that can
    act, while one blocked forever inside a tool cannot.
    """
    global lock_handle
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    lock_handle = LOCK.open("w")
    deadline = time.monotonic() + LOCK_WAIT_SECONDS
    announced = False
    while True:
        try:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except OSError:
            if time.monotonic() >= deadline:
                sys.exit("defects: %s has been held by another defects.py for %ds. That is far "
                         "longer than a write takes, so it is wedged rather than busy: find the "
                         "holder before retrying." % (LOCK, LOCK_WAIT_SECONDS))
            if not announced:
                print("defects: waiting for another defects.py to finish writing the ledger…",
                      file=sys.stderr)
                announced = True
            time.sleep(0.05)


def load() -> dict:
    if not LEDGER.is_file():
        return {"defects": []}
    try:
        with LEDGER.open() as handle:
            data = json.load(handle)
    except ValueError as exc:
        #: Reachable without the lock only if something wrote the file by a path that is not this
        #: tool. Saying which file and what is wrong with it beats a bare traceback, because the
        #: reader's next move is to look at the file.
        raise SystemExit(f"defects: {LEDGER} is not valid JSON: {exc}")
    data.setdefault("defects", [])
    #: A record written by the earlier append path carries its later history in a stray
    #: `next_step` beside the canonical `next`. Fold it in, oldest first, so one field holds the
    #: whole investigation and a replace cannot lose half of it. The fold is saved by whatever
    #: mutator called `load`; a read-only listing sees the folded view without writing.
    for entry in data["defects"]:
        stray = entry.pop("next_step", None)
        if stray:
            have = entry.get("next") or ""
            entry["next"] = (have + " ===== " if have else "") + stray
    return data


def save(data: dict) -> None:
    """Atomically, so a concurrent READER never sees a half-written queue.

    The non-atomic version left an ~6 ms window per write in which `json.load` raised on a
    truncated document; a reader hitting it saw a corrupt ledger rather than the before or after
    state. The lock serialises writers; this makes readers safe without needing one.
    """
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    temporary = LEDGER.with_suffix(".json.tmp")
    with temporary.open("w") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    os.replace(temporary, LEDGER)


def rank(entry: dict) -> tuple:
    severity = str(entry.get("severity", "")).lower()
    position = SEVERITIES.index(severity) if severity in SEVERITIES else len(SEVERITIES)
    return position, str(entry.get("id", ""))


def reach(entry: dict) -> tuple:
    """The configuration this defect has been observed on, with the fail-closed defaults applied.

    A missing field is not "unknown, so skip it" -- it is "nobody has established reach, so it
    blocks everything". Reading it any other way turns an unexamined entry into a silently
    narrowed one, which is the relabel this whole design exists to make impossible.
    """
    try:
        nodes = int(entry.get("nodes", DEFAULT_NODES))
    except (TypeError, ValueError):
        nodes = DEFAULT_NODES
    try:
        pattern = configuration.check_pattern(entry.get("config", DEFAULT_CONFIG))
    except configuration.ConfigurationError:
        pattern = DEFAULT_CONFIG
    return max(nodes, 1), pattern


def platform_of(entry: dict) -> str:
    """The platform a defect reaches, fail-closed: missing or unknown reads as `any`."""
    value = str(entry.get("platform", DEFAULT_PLATFORM)).lower()
    return value if value in PLATFORMS else DEFAULT_PLATFORM


def blocks(entry: dict, nodes: int, selector: tuple, platform=None, candidate: str = "") -> bool:
    """Does this defect block a release of the configuration(s) `nodes`/`selector` on `platform`?

    It does if one of those configurations can exercise it: the cluster is at least as large as
    the smallest one the defect was seen on, the record's pattern overlaps the configurations the
    view names, and the defect is not confined to some other platform. A field the view left open
    (`defects.py 8`, `defects.py 8/disk`) matches every value, and a `platform` of None means none
    was named, so every platform counts.
    """
    seen_nodes, pattern = reach(entry)
    if seen_nodes > nodes:
        return False
    if platform is not None and platform_of(entry) not in ("any", platform):
        return False
    #: A defect whose declared verification batch passed at exactly this configuration, on the
    #: candidate being released (or, with no candidate named, on this tree's build), has nothing
    #: left to say about it there. It still blocks every configuration it reaches and was not
    #: verified at.
    if verified_here(entry, configuration.selector_label(nodes, selector), platform, candidate):
        return False
    #: The owner's exception, applied through a reviewed proposal, lets an open record stop
    #: blocking one configuration in one release. It blocks everything else it reaches.
    if excepted_here(entry, configuration.selector_label(nodes, selector), candidate):
        return False
    return configuration.overlaps(pattern, selector)


def owner_exception(record: str, config: str, release: str):
    """The exception in data/release_policy.json (`exceptions`, each one recorded with the owner's
    words in `owner_approved`) that lets `record` stop blocking `config` in `release`, or None.
    Only the owner writes one; a reviewed `exception` proposal applies it to the record."""
    if not (record and config and release):
        return None
    for granted in board_tool().policy().get("exceptions") or []:
        if (isinstance(granted, dict) and granted.get("release") == release
                and record in (granted.get("records") or [])
                and config in (granted.get("configs") or [])):
            return granted
    return None


def excepted_here(entry: dict, config: str, candidate: str = "") -> bool:
    """Was the owner's exception for this record applied at exactly `config` for `candidate`, and
    does the policy still grant it? Without a candidate nothing is excepted: a development view
    shows every record that reaches it."""
    if not candidate:
        return False
    marks = [v for v in entry.get("excepted_at") or []
             if isinstance(v, dict) and v.get("config") == config
             and v.get("candidate") == candidate and v.get("approval")]
    return bool(marks) and owner_exception(entry.get("id", ""), config, candidate) is not None


#: This tree's mxfs.ko srcversion, read once per process.
build_cache = None


def verified_here(entry: dict, config: str, platform=None, candidate: str = "") -> bool:
    """Was this record verified at exactly `config` -- by a declared batch, on `candidate` (or on
    this tree's build when no candidate is named), for this platform or for every platform?

    A mark with no batch is a single-pass `verify` from before 2026-10-21; it proves nothing about
    a defect that showed only now and then, and it no longer counts.

    A candidate is its version, and a version is frozen again after an attempt fails, so a mark
    counts only on the attempt its laps ran on (the `attempt` it carries, that attempt's frozen-at
    stamp). Matched by the version alone, a batch that passed on one attempt stopped the record
    blocking on every later attempt, none of whose trees its laps ran on
    (D-VERIFIED-AT-MATCHED-BY-VERSION-ALONE-CARRIES-TO-A-LATER-ATTEMPT); a mark from before the
    attempt was recorded counts on none.
    """
    marks = [v for v in entry.get("verified_at") or []
             if isinstance(v, dict) and v.get("config") == config and v.get("batch")
             and v.get("platform", "any") in ("any", platform or "any")]
    if not marks:
        return False
    if candidate:
        began = board_tool().attempt_began(candidate)
        return bool(began) and any(v.get("candidate") == candidate and v.get("attempt") == began
                                   for v in marks)
    global build_cache
    if build_cache is None:
        build_cache = tree_build()
    return bool(build_cache) and any(v.get("build") == build_cache for v in marks)


def parse_at(text: str) -> tuple:
    """`2/net/mesh/direct`, `2/disk`, `2/net/mesh/direct@pve9`, or a bare `2` meaning every
    configuration at that size.

    Same notation as the board and the run keys, with `@platform` for the operating system a
    release is for, and trailing fields may be left off to ask about a whole class or method.
    """
    spec, _, platform = str(text).strip().partition("@")
    try:
        nodes, selector = configuration.parse_selector(spec)
    except configuration.ConfigurationError as exc:
        sys.exit(f"defects: {exc}")
    platform = platform.strip().lower() or None
    if platform is not None and platform not in PLATFORMS:
        sys.exit(f"defects: platform {platform!r}; expected one of {list(PLATFORMS)} "
                 f"(data/platforms.json)")
    return nodes, selector, platform


def gate_label(gate: tuple) -> str:
    nodes, selector, platform = gate
    label = configuration.selector_label(nodes, selector)
    return label if platform is None else "%s@%s" % (label, platform)


def lift_config(argv: list) -> list:
    """Accept `defects.py 2/net/mesh/direct` as `--at 2/net/mesh/direct`.

    A session names the configuration far more often than it names a subcommand, and having to
    remember `--at` for the common case is how a tool stops being reached for. The leading
    argument is a configuration only when it starts with digits, so it can never shadow `show`,
    `add`, `update` or `remove`.
    """
    rest, skip = list(argv[1:]), False
    for index, token in enumerate(rest):
        if skip:
            skip = False
            continue
        if token in SUBCOMMANDS:
            break
        if token.startswith("-"):
            #: A flag that takes a value would otherwise have its value read as a node count:
            #: `-s 2` is a severity, not a cluster.
            skip = token in VALUE_FLAGS
            continue
        if not re.fullmatch(r"\d+(?:/[A-Za-z*]+)*(@[a-z0-9]+)?", token):
            break
        #: The old two-token spelling (`defects.py 2 tcp`) is refused by name, not half-parsed
        #: into a bare `2` that silently shows every configuration.
        if index + 1 < len(rest) and re.fullmatch(r"[A-Za-z]+", rest[index + 1]) \
                and rest[index + 1] not in SUBCOMMANDS:
            hint = configuration.retired_hint("%s/%s" % (token, rest[index + 1]))
            sys.exit("defects: give the configuration as one key, e.g. %s/net/mesh/direct%s"
                     % (token, "; " + hint if hint else ""))
        return argv[:1] + rest[:index] + ["--at", token] + rest[index + 1:]
    return argv


def tally(entries: list) -> str:
    """`68 critical, 21 high, 4 major` -- worst first, and an unfamiliar severity is still counted.

    A count by severity is the only line most sessions read. Dropping a severity the tool does not
    recognise would silently shrink the queue, so anything unexpected is named and counted where
    it falls rather than folded into a total that no longer adds up.
    """
    counts: dict[str, int] = {}
    for entry in entries:
        counts[str(entry.get("severity", "unset")).lower()] = \
            counts.get(str(entry.get("severity", "unset")).lower(), 0) + 1
    order = [s for s in SEVERITIES if s in counts] + \
            sorted(k for k in counts if k not in SEVERITIES)
    return ", ".join("%d %s" % (counts[k], k) for k in order)


def source_of(entry: dict) -> str:
    value = str(entry.get("reach_source", DEFAULT_SOURCE)).lower()
    return value if value in REACH_SOURCES else DEFAULT_SOURCE


def config_of(entry: dict) -> str:
    """`2/net/mesh` confirmed from evidence, `2/net/mesh?` set by the keyword sweep, `1/any` never
    looked at. Trailing `*` fields are left off: `disk/caw/*` prints as `disk/caw`.

    The question mark is the whole point of recording provenance: a heuristic reach is a useful
    number and a weak claim, and the queue has to be able to show both at once without the reader
    having to remember which records were adjudicated.
    """
    seen_nodes, pattern = reach(entry)
    while pattern.endswith("/*"):
        pattern = pattern[:-2]
    if pattern == "*":
        pattern = "any"
    mark = "?" if source_of(entry) == "heuristic" else ""
    #: `any` is left off: it is every record's default and would widen every line to say nothing.
    where = "" if platform_of(entry) == DEFAULT_PLATFORM else "@" + platform_of(entry)
    return "%d/%s%s%s" % (seen_nodes, pattern, where, mark)


#: An id is something a person types, greps for, and reads in a one-line queue listing. Past the
#: eighties it stops being a name and starts being the summary again: a 104-character id pushed
#: every other column off the terminal and had to be quoted by hand in every message about it.
#: The limit is a refusal and never a truncation -- silently cutting an id would break every
#: evidence directory, memory and CHANGELOG entry that already refers to the record by name.
MAX_ID = 80


def check_id(new_id: str) -> str:
    """The one gate every id passes, whether minted or given."""
    if len(new_id) > MAX_ID:
        sys.exit("defects: the id is %d characters and the limit is %d:\n  %s\n"
                 "Choose a shorter one with --id: name the defect, do not restate the summary."
                 % (len(new_id), MAX_ID, new_id))
    return new_id


def mint(summary: str, taken) -> str:
    """An id from the summary, because a defect nobody can name is one nobody discusses.

    The old ledger's ids were written by hand and read well -- `D-THE-TRAINER-OPTION-NAMES-A-TRAINER
    -OF-THE-WRONG-CLASS` says what is wrong without opening the entry. This keeps that shape without
    asking for it twice.

    It does NOT shorten a long summary into a fitting id. Dropping words picks the name by counting
    characters, and the word it drops is as likely to be the one that distinguishes this record from
    its neighbour as not. A summary too long to name itself is handed back for a name.
    """
    words = re.findall(r"[A-Za-z0-9]+", summary.upper())[:9]
    base = "D-" + "-".join(words) if words else "D-UNNAMED"
    candidate, suffix = base, 2
    while candidate in taken:
        candidate = f"{base}-{suffix}"
        suffix += 1
    return check_id(candidate)


def find(data: dict, wanted: str) -> dict:
    """By exact id, else by unique substring -- ids are long and typing one in full is a chore."""
    wanted = wanted.strip()
    for entry in data["defects"]:
        if str(entry.get("id", "")) == wanted:
            return entry
    low = wanted.lower()
    hits = [e for e in data["defects"] if low in str(e.get("id", "")).lower()]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        sys.exit(f"defects: no entry matches {wanted!r}")
    sys.exit("defects: %r matches %d entries:\n  %s"
             % (wanted, len(hits), "\n  ".join(str(e["id"]) for e in hits)))


def flat(text, width: int) -> str:
    """One line, truncated. Summaries here run to a couple of thousand characters, and a queue
    that wraps every one of them across four lines is a queue nobody scans."""
    line = " ".join(str(text).split())
    return line[:width - 1] + "…" if len(line) > width else line


def wrap(text: str, width: int, indent: str) -> str:
    out, line = [], ""
    for word in str(text).split():
        if line and len(line) + 1 + len(word) > width:
            out.append(line)
            line = word
        else:
            line = (line + " " + word).strip()
    if line:
        out.append(line)
    return ("\n" + indent).join(out)


def show_one(entry: dict) -> None:
    print(entry.get("id", "?"))
    print("  %-10s %s" % ("severity", entry.get("severity", "unset")))
    if entry.get("impact"):
        print("  %-10s %s — %s" % ("bar", entry["impact"], wrap(entry.get("impact_why",""), 80, " "*13)))
    print("  %-10s %s%s" % ("observed", config_of(entry),
                            "" if "nodes" in entry and "config" in entry
                            else "   (defaulted -- reach not established, blocks every release)"))
    for key in ("opened", "updated"):
        if entry.get(key):
            print("  %-10s %s" % (key, entry[key]))
    for key in ("summary", "evidence", "next"):
        if entry.get(key):
            print("  %-10s %s" % (key, wrap(entry[key], 88, " " * 13)))
    for cell in entry.get("cells") or []:
        print("  %-10s %s:%s:%s" % ("cell", cell["config"], cell["row"], cell["iso"]))
    for cell in entry.get("collateral") or []:
        print("  %-10s %s:%s:%s — %s" % ("collateral", cell["config"], cell["row"], cell["iso"],
                                         wrap(cell.get("why", ""), 70, " " * 13)))
    if entry.get("reproducer"):
        print("  %-10s %s" % ("reproducer", wrap(entry["reproducer"], 88, " " * 13)))
    if entry.get("ab"):
        ab = entry["ab"]
        print("  %-10s fix off failed %d/%d, fix on failed %d/%d, build %s, evidence %s"
              % ("ab", ab["off_fail"], ab["off_laps"], ab["on_fail"], ab["on_laps"],
                 ab["build"], ab["evidence"]))
    if entry.get("reproducible"):
        print("  %-10s %s" % ("reproduces", wrap(entry["reproducible"], 88, " " * 13)))
    for mark in entry.get("verified_at") or []:
        if isinstance(mark, dict):
            if mark.get("batch"):
                print("  %-10s %s on %s (batch %s, %s): does not block it there"
                      % ("verified", mark.get("config"),
                         "candidate %s attempt %s" % (mark["candidate"], mark.get("attempt") or "?")
                         if mark.get("candidate")
                         else "build " + str(mark.get("build")), mark["batch"], mark.get("date")))
            else:
                print("  %-10s %s on build %s (%s): a single pass from before batches; it no "
                      "longer clears anything" % ("verified", mark.get("config"), mark.get("build"),
                                                  mark.get("date")))
    for mark in entry.get("excepted_at") or []:
        if isinstance(mark, dict):
            print("  %-10s %s in %s (owner's exception, proposal %s, %s): does not block it there"
                  % ("excepted", mark.get("config"), mark.get("candidate"), mark.get("approval"),
                     mark.get("date")))
    for rate in entry.get("rates") or []:
        print("  %-10s %s at %s: %d of %d laps failed (batch %s, %s %s)"
              % ("rate", rate.get("row"), rate.get("config"), rate.get("k", 0), rate.get("n", 0),
                 rate.get("batch"), rate.get("kind"), rate.get("date")))
    for batch in entry.get("batches") or []:
        print("  %-10s %s %-9s %s at %s, %s laps planned, %s, %s%s"
              % ("batch", batch.get("id"), batch.get("kind"), batch.get("row"),
                 batch.get("config"), batch.get("planned"), batch.get("state"),
                 "candidate " + batch["candidate"] if batch.get("candidate")
                 else "build " + str(batch.get("build") or "?"),
                 " variant " + batch["variant"] if batch.get("variant") else ""))
    for key, value in entry.items():
        if key not in ORDERED:
            print("  %-10s %s" % (key, wrap(value, 88, " " * 13)))


def cmd_list(data: dict, args) -> int:
    entries = sorted(data["defects"], key=rank)
    total = len(entries)
    if args.severity:
        entries = [e for e in entries if str(e.get("severity", "")).lower() == args.severity]
    gate = None
    if args.at:
        gate = parse_at(args.at)
        entries = [e for e in entries if blocks(e, *gate)]
    if args.release:
        #: THE RELEASE BAR: 100% data integrity, and stability (no crashes, hangs, shutdowns or
        #: unmountable volumes). Anything that is neither is not a blocker for THIS release --
        #: pace, cosmetics, and defects unreachable in the shipping configuration.
        #:
        #: An UNADJUDICATED record blocks, exactly as an unclassified reach does. Deciding a
        #: record is harmless is a judgement someone has to make and be accountable for; it is
        #: never the default.
        entries = [e for e in entries if str(e.get("impact", "")).lower() != "noblock"]
    #: THE ONLY LIST PATH THAT CAN FAIL, AND ONLY WHEN ASKED. Every other one exits 0 whether it
    #: printed 16 records or none, so a script could not tell "clear" from "still blocked" without
    #: parsing the output -- which is how a release gate ends up grepping prose. `--gate` makes the
    #: emptiness of the filtered queue the exit status, and it is opt-in so that no existing caller
    #: starts failing because its queue is not empty.
    verdict = 1 if (args.gate and entries) else 0
    if args.json:
        json.dump({"defects": entries}, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return verdict
    if not entries:
        print("no open defects." if not gate
              else "nothing in the queue blocks a %s release (%d open overall)."
                   % (gate_label(gate), total))
        return verdict

    width_id = max(len(str(e.get("id", "?"))) for e in entries)
    width_sev = max(len(str(e.get("severity", "unset"))) for e in entries)
    width_cfg = max(len(config_of(e)) for e in entries)
    #: The rule under the queue is drawn to what was actually printed, not to a guess at the
    #: summary column. A rule wider than the terminal wraps and puts a stray line of dashes under
    #: the total, which reads as a second, empty section.
    ruler = 0
    for number, entry in enumerate(entries, 1):
        head = ("%2d. %-*s  %-*s  %-*s  %s"
                % (number, width_sev, entry.get("severity", "unset"),
                   width_cfg, config_of(entry),
                   width_id, entry.get("id", "?"),
                   "" if args.detail else flat(entry.get("summary", ""), 100)))
        ruler = max(ruler, max(len(line) for line in head.splitlines()))
        print(head)
        if args.detail:
            print("    %s" % wrap(entry.get("summary", ""), 92, " " * 4))
            if entry.get("next"):
                print("    next: %s" % wrap(entry["next"], 86, " " * 10))
            print()
    print("-" * ruler)
    kinds: dict[str, int] = {}
    for e in entries:
        kinds[str(e.get("impact", "unadjudicated")).lower()] = \
            kinds.get(str(e.get("impact", "unadjudicated")).lower(), 0) + 1
    firm = sum(1 for e in entries if source_of(e) == "evidence")
    guess = sum(1 for e in entries if source_of(e) == "heuristic")
    blind = len(entries) - firm - guess
    if gate:
        print("Total: %d of %d open block a %s release — %s"
              % (len(entries), total, gate_label(gate), tally(entries)))
    else:
        print("Total: %d open — %s" % (len(entries), tally(entries)))
    #: A gate number is only as good as how its members got there, so the split is printed with it
    #: rather than left for someone to go and check.
    order = [k for k in ("integrity", "stability", "verify", "noblock", "unadjudicated")
             if k in kinds]
    if order:
        print("       bar:   %s" % ", ".join("%d %s" % (kinds[k], k) for k in order))
    print("       reach: %d from evidence, %d from the keyword sweep (marked ?), %d never examined"
          % (firm, guess, blind))
    if verdict:
        print("GATE: %d record%s still block%s a %s release."
              % (len(entries), "" if len(entries) == 1 else "s",
                 "s" if len(entries) == 1 else "",
                 gate_label(gate) if gate else "any"))
    return verdict


def cmd_show(data: dict, args) -> int:
    show_one(find(data, args.id))
    return 0


def check_impact(value, why) -> None:
    """A bar is a claim about what was measured, so it does not get set without the measurement.

    `noblock` is the only value that takes a record out of `--release`, which makes it the one
    worth a guard -- but every value gets the same one, because "we have not looked" is also
    something a later reader needs stated rather than inferred from a blank field.
    """
    if value is None:
        return
    if str(value).lower() not in IMPACTS:
        sys.exit(f"defects: impact {value!r}; expected one of {list(IMPACTS)}")
    if not str(why or "").strip():
        sys.exit("defects: -I/--impact needs --impact-why saying what was measured and what it "
                 "said. A bar recorded without one is a relabel, not an adjudication.")


def board_tool():
    """tools/criteria.py as a module, for the board runs a record names. Imported only by the
    commands that touch the board, so listing the queue never depends on it."""
    import criteria  # noqa: E402
    return criteria


def parse_cell(text: str, collateral: bool) -> dict:
    """`CONFIG:ROW:ISO`, or `CONFIG:ROW:ISO=<evidence>` for a collateral run. The stamp has
    colons of its own, so the configuration and the row are the first two fields and the stamp is
    the rest."""
    why = ""
    if collateral:
        text, sep, why = text.partition("=")
        if not sep or not why.strip():
            sys.exit("defects: --collateral needs CONFIG:ROW:ISO=<the log evidence that this run "
                     "failed because of the defect>; a run that only failed at the same time is "
                     "not collateral")
    criteria = board_tool()
    if criteria.RELEASE_STEP_SETTLE:
        #: The stamp is anchored at the end: a release step's row (`release:<step>`) has a colon
        #: of its own, and splitting at the first two colons read row `release` and stamp
        #: `<step>:...`.
        #: A run the board migration brought into a ledger keeps the date its board recorded and
        #: no time (`32/disk/caw/mpath:prep_cluster:2026-09-10`), so such a stamp is a date alone;
        #: MXFS_CELL_DAY_STAMP=0 takes only a full stamp, as before.
        stamp = r"\d{4}-\d\d-\d\d(?:T\d\d:\d\d:\d\dZ)?" if CELL_DAY_STAMP \
            else r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"
        match = re.fullmatch(r"([^:]+):(.+):(" + stamp + ")", text.strip())
        fields = match.groups() if match else None
    else:
        config, sep1, rest = text.strip().partition(":")
        row, sep2, iso = rest.partition(":")
        fields = (config, row, iso) if sep1 and sep2 and iso else None
    if not fields:
        sys.exit(f"defects: {text!r}: a board run is CONFIG:ROW:ISO, e.g. "
                 "4/net/mesh/direct:alloc_witness:2026-10-20T07:38:35Z")
    config, row, iso = fields
    #: A release step's run (tools/release_run.py: row `release:<step>`) is filed under the
    #: configuration the orchestrator gave it, which may be a placeholder such as `1/any`.
    parsed = config if criteria.RELEASE_STEP_SETTLE and row.startswith("release:") \
        else criteria.parse_at(config)
    cell = {"config": parsed, "row": row, "iso": iso}
    if collateral:
        cell["why"] = why.strip()
    return cell


def check_cells(cells: list) -> None:
    """Every named run exists in its board's run ledger and did not pass. A record that names a
    run nobody recorded, or a passing one, accounts for nothing."""
    criteria = board_tool()
    for cell in cells:
        # tools/release_run.py writes every release step's run into the primary ledger, whatever
        # configuration it files it under: the drbd step's, under 2/net/mesh/drbd, was looked for
        # in the DRBD board's and could never be named
        board = criteria.run_board(cell["config"], cell["row"])
        run = criteria.ledger_run(board, cell["config"], cell["row"], cell["iso"])
        if run is None:
            sys.exit("defects: %s at %s records no run stamped %s (recorded: %s)"
                     % (cell["row"], cell["config"], cell["iso"],
                        ", ".join(str(r.get("iso", "?")) for r in
                                  criteria.ledger_runs(board, cell["config"], cell["row"])[:12])))
        if run.get("outcome") == "PASS":
            sys.exit("defects: %s at %s run %s PASSED; a record names the runs that failed"
                     % (cell["row"], cell["config"], cell["iso"]))


def add_cells(entry: dict, args) -> list:
    """Append the runs named by --cell and --collateral to the record, once each."""
    changed = []
    for key, given in (("cells", args.cell or []), ("collateral", args.collateral or [])):
        new = [parse_cell(text, key == "collateral") for text in given]
        if not new:
            continue
        check_cells(new)
        have = entry.setdefault(key, [])
        seen = {(c["config"], c["row"], c["iso"]) for c in have}
        for cell in new:
            if (cell["config"], cell["row"], cell["iso"]) not in seen:
                have.append(cell)
                seen.add((cell["config"], cell["row"], cell["iso"]))
        changed.append(key)
    return changed


def drop_cells(data: dict, entry: dict, args) -> list:
    """Stop naming runs this record's removal must not retire as its own.

    A removal retires every run its record names, as fixed or disproved (retire_cells). A run a
    record names for a failure another cause produced would be settled by a fix that did not end
    it, and a removal was rejected for exactly that (data/reviews/P20261023-5e015a.md, Check 4: a
    DRBD alloc_witness run that fails with or without the fix and whose failure an open major
    record owns). The queue could add a run to a record but never take one away. A run is dropped
    only when it stays accounted for without this record: a standing disposition already settles
    it, or another open record names it, so the incident gate reads it as before. The run's own
    evidence for the drop, and what still accounts for the run, go into this record's evidence."""
    given = getattr(args, "drop_cell", None) or []
    if not given:
        return []
    why = (getattr(args, "drop_why", None) or "").strip()
    if not why:
        sys.exit("defects: --drop-cell needs --drop-why: the run's own evidence that this "
                 "record's cause is not what failed it")
    criteria = board_tool()
    dropped = []
    for text in given:
        cell = parse_cell(text, False)
        key = (cell["config"], cell["row"], cell["iso"])
        field = next((f for f in ("cells", "collateral")
                      if any((c["config"], c["row"], c["iso"]) == key
                             for c in entry.get(f) or [])), None)
        if field is None:
            sys.exit("defects: %s does not name %s" % (entry["id"], text))
        board = criteria.run_board(cell["config"], cell["row"])
        others = [x["id"] for x in data["defects"] if x is not entry and any(
            (c["config"], c["row"], c["iso"]) == key
            for c in (x.get("cells") or []) + (x.get("collateral") or []))]
        standing = criteria.settled(board, *key)
        if standing:
            still = "settled (%s)" % standing
        elif others:
            still = "named by " + ", ".join(others)
        else:
            sys.exit("defects: %s is neither settled nor named by another open record: dropping "
                     "it would leave a failure nothing accounts for" % text)
        entry[field] = [c for c in entry[field] if (c["config"], c["row"], c["iso"]) != key]
        dropped.append("%s:%s:%s, %s" % (key + (still,)))
    note = "%s: no longer names %s: %s" % (date.today().isoformat(), "; ".join(dropped), why)
    have = entry.get("evidence") or ""
    entry["evidence"] = have + [note] if isinstance(have, list) else \
        ((have + " ===== " if have else "") + note)
    return ["cells", "evidence"]


# ---------------------------------------------------------------------------------------------
# MEASURED RATES AND THE BATCHES THEY SIZE
# ---------------------------------------------------------------------------------------------

def binomial_upper_tail(k: int, n: int, p: float) -> float:
    """P(X >= k) for X ~ Binomial(n, p), exactly."""
    if k <= 0:
        return 1.0
    if p <= 0.0:
        return 0.0
    if p >= 1.0:
        return 1.0
    total = 0.0
    for j in range(k, n + 1):
        total += math.comb(n, j) * (p ** j) * ((1.0 - p) ** (n - j))
    return min(total, 1.0)


def clopper_pearson_lower(k: int, n: int, delta: float) -> float:
    """The one-sided Clopper-Pearson lower bound of k/n at error delta: the smallest p for which
    seeing k or more failures in n laps has probability at least delta. Zero when k is zero:
    nothing measured, nothing to bound."""
    if k <= 0 or n <= 0:
        return 0.0
    if k >= n:
        return delta ** (1.0 / n)
    low, high = 0.0, k / n
    for _ in range(200):
        mid = (low + high) / 2.0
        if binomial_upper_tail(k, n, mid) < delta:
            low = mid
        else:
            high = mid
    return low


def laps_needed(k: int, n: int, delta: float, alpha: float) -> int:
    """Clean laps that leave at most alpha chance of all passing while the defect still fails at
    its lower-bound rate: N = ceil(ln alpha / ln(1 - L)). None when the rate bounds nothing."""
    low = clopper_pearson_lower(k, n, delta)
    if low <= 0.0:
        return 0
    if low >= 1.0:
        return 1
    return max(1, math.ceil(math.log(alpha) / math.log(1.0 - low)))


def policy_numbers() -> tuple:
    rules = board_tool().policy()
    return float(rules["delta"]), float(rules["alpha"])


def find_batch(data: dict, bid: str) -> tuple:
    """(record, batch) for a batch id, or exit."""
    for entry in data["defects"]:
        for batch in entry.get("batches") or []:
            if batch.get("id") == bid:
                return entry, batch
    sys.exit(f"defects: no declared batch {bid!r}")


def batch_runs(batch: dict) -> list:
    """Every recorded lap of a batch, from its board's run ledger."""
    criteria = board_tool()
    board = criteria.board_for(batch["config"])
    return [r for r in criteria.ledger_runs(board, batch["config"], batch["row"])
            if r.get("batch") == batch["id"]]


def exposed(run: dict, batch: dict | None = None) -> bool:
    """Did the lap reach the defect's trigger? run.sh appends ` exposure=<count>` to `measured`
    when the batch names a probe, on every outcome.

    A batch with no probe cannot tell, so every lap of it counts: it is a lap of the row as run,
    and counting only its failures read every such rate as 100% (3 failures in 30 laps measured
    3/3, which sizes a verification batch at 28 laps instead of about 440). With a probe, a FAIL
    counts only when the probe saw the trigger: a FAIL the defect did not cause is an incident of
    its own, and counting it raises the rate and shrinks the verification batch."""
    if batch is not None and not batch.get("probe"):
        return True
    match = re.search(r"\bexposure=(\d+)", str(run.get("measured") or ""))
    if match:
        return int(match.group(1)) > 0
    # a run recorded before exposure was measured: a FAIL is the trigger firing
    return run.get("outcome") == "FAIL" and batch is None


def unplanned_variant(run: dict, batch: dict) -> bool:
    """A lap run as something other than the batch declared: a module knob, a test environment
    or another build than the batch names. A control batch takes the fix out, so its laps carry
    the knob that does it and run.sh's `batch:<variant>`; a calibration or verification lap with
    any variant at all measured a different build than the one it is counted for."""
    variant = str(run.get("variant") or "")
    if batch.get("variant"):
        if "batch:" + batch["variant"] not in variant:
            return True
    elif variant:
        return True
    if batch.get("build") and str(run.get("build") or "") != batch["build"]:
        return True
    if not batch.get("candidate"):
        return False
    # a candidate is its version: a lap from before its current attempt was frozen ran another tree
    return run.get("candidate") != batch["candidate"] \
        or str(run.get("iso", "")) < board_tool().attempt_began(batch["candidate"])


def check_batch_lap(bid: str, row: str, config: str, candidate: str) -> None:
    """Refuse a lap that is not part of an open, declared batch: wrong row, configuration or
    candidate, a batch already ended by a failure, or one that has used all its laps. Called by
    tools/criteria.py before it records a lap, and by run.sh before it runs one."""
    data = load()
    entry, batch = find_batch(data, bid)
    if batch.get("state") != "open":
        sys.exit("defects: batch %s is %s; no more laps" % (bid, batch.get("state")))
    if batch["row"] != row and row not in batch.get("support", []):
        sys.exit("defects: batch %s is for row %s, not %s" % (bid, batch["row"], row))
    if batch["config"] != config:
        sys.exit("defects: batch %s is for %s, not %s" % (bid, batch["config"], config))
    if batch.get("candidate") and batch["candidate"] != candidate:
        sys.exit("defects: batch %s is for candidate %s, not %r"
                 % (bid, batch["candidate"], candidate))
    if row != batch["row"]:
        return
    laps = [r for r in batch_runs(batch) if r.get("outcome") in ("PASS", "FAIL", "INCOMPLETE")]
    if any(r.get("outcome") == "FAIL" for r in laps) and batch["kind"] == "verify":
        sys.exit("defects: batch %s already failed a lap; a verification batch ends at its first "
                 "failure" % bid)
    if len(laps) >= int(batch["planned"]):
        sys.exit("defects: batch %s has run all %s of its laps" % (bid, batch["planned"]))


def cmd_batch(data: dict, args) -> int:
    """Declare a batch before its first lap. The number of laps is fixed here: a batch that ran
    until it got the answer it wanted measures nothing."""
    entry = find(data, args.id)
    criteria = board_tool()
    config = criteria.parse_at(args.batch_at)
    if args.kind == "verify":
        sys.exit("defects: a verification batch is sized from the record's measured rate; use "
                 "plan-verify")
    if args.runs < 1:
        sys.exit("defects: --runs is the number of laps; at least 1")
    if args.kind == "control" and not args.variant:
        sys.exit("defects: a control batch takes the fix out; --variant says how (the knob, or the "
                 "build with the fix reverted and the diff's hash)")
    bid = "b%s-%s" % (date.today().strftime("%Y%m%d"), uuid.uuid4().hex[:6])
    batch = {"id": bid, "kind": args.kind, "row": args.row, "config": config,
             "platform": args.platform or "any", "planned": args.runs,
             "probe": args.probe or "", "candidate": args.candidate or "",
             "build": args.build or "", "variant": args.variant or "", "state": "open",
             "leaves_cluster": bool(args.leaves_cluster), "support": args.support or [],
             "created": date.today().isoformat(), "why": args.why or ""}
    entry.setdefault("batches", []).append(batch)
    entry["updated"] = date.today().isoformat()
    save(data)
    print("declared %s batch %s for %s: %s at %s, %d laps" % (args.kind, bid, entry["id"],
                                                              args.row, config, args.runs))
    print("run each lap with: MXFS_BATCH=%s%s ./run.sh %s %s"
          % (bid, " MXFS_CANDIDATE=" + args.candidate if args.candidate else "", config, args.row))
    return 0


def cmd_measure(data: dict, args) -> int:
    """Close a calibration or control batch and record its rate, read from the run ledger."""
    entry, batch = find_batch(data, args.batch)
    if batch["kind"] not in ("calibrate", "control"):
        sys.exit("defects: %s is a %s batch; measure closes calibration and control batches"
                 % (batch["id"], batch["kind"]))
    if batch.get("state") != "open":
        sys.exit("defects: batch %s is already %s" % (batch["id"], batch.get("state")))
    laps = batch_runs(batch)
    unresolved = [r for r in laps if r.get("outcome") in ("INCOMPLETE", "INFRA")
                  and not board_tool().settled(board_tool().board_for(batch["config"]),
                                               batch["config"], batch["row"], str(r.get("iso")))]
    if unresolved:
        sys.exit("defects: batch %s has %d INCOMPLETE or INFRA lap(s) (%s); a rate needs every planned lap "
                 "to have measured something, or a reviewed infra disposition for the lap"
                 % (batch["id"], len(unresolved), ", ".join(str(r.get("iso")) for r in unresolved)))
    counted = [r for r in laps if r.get("outcome") in ("PASS", "FAIL") and exposed(r, batch)
               and not unplanned_variant(r, batch)]
    unattributed = [r for r in laps if r.get("outcome") == "FAIL" and not exposed(r, batch)]
    if unattributed:
        print("  %d FAIL lap(s) without exposure are not counted against %s (each is an incident "
              "of its own until a record names it): %s"
              % (len(unattributed), entry["id"], ", ".join(str(r.get("iso")) for r in unattributed)))
    if len([r for r in laps if r.get("outcome") in ("PASS", "FAIL")]) != int(batch["planned"]):
        sys.exit("defects: batch %s planned %s laps and has %d; run the rest first"
                 % (batch["id"], batch["planned"],
                    len([r for r in laps if r.get("outcome") in ("PASS", "FAIL")])))
    k = sum(1 for r in counted if r.get("outcome") == "FAIL")
    rate = {"row": batch["row"], "config": batch["config"], "platform": batch["platform"],
            "kind": batch["kind"], "batch": batch["id"], "k": k, "n": len(counted),
            "candidate": batch.get("candidate", ""), "variant": batch.get("variant", ""),
            "builds": sorted({str(r.get("build")) for r in laps}), "date": date.today().isoformat()}
    entry.setdefault("rates", []).append(rate)
    batch["state"] = "closed"
    entry["updated"] = date.today().isoformat()
    save(data)
    delta, alpha = policy_numbers()
    print("measured %s: %s at %s failed %d of %d exposed laps (batch %s)"
          % (entry["id"], batch["row"], batch["config"], k, len(counted), batch["id"]))
    if k:
        print("  lower bound %.4f at delta %s: a verification batch needs %d clean laps"
              % (clopper_pearson_lower(k, len(counted), delta), delta,
                 laps_needed(k, len(counted), delta, alpha)))
    else:
        print("  no failure: this batch bounds nothing, and nothing can be verified from it")
    return 0


def rate_for(entry: dict, row: str, config: str, kind: str = "calibrate") -> dict:
    """The record's measured rate for a row: at `config` if it was measured there, else the most
    recent one for the row at any configuration (the record must say the rate transfers)."""
    rates = [r for r in entry.get("rates") or [] if r.get("row") == row and r.get("k", 0) > 0
             and r.get("kind") == kind]
    here = [r for r in rates if r.get("config") == config]
    return (here or rates or [None])[-1]


def cmd_plan_verify(data: dict, args) -> int:
    """Declare a verification batch sized from the record's measured rate."""
    entry = find(data, args.id)
    criteria = board_tool()
    config = criteria.parse_at(args.batch_at)
    if args.control:
        rate = next((r for r in entry.get("rates") or []
                     if r.get("batch") == args.control and r.get("k", 0) > 0), None)
        if rate is None:
            sys.exit("defects: control batch %s has no measured failure for %s; a fix-on batch is "
                     "sized from a control that reproduced" % (args.control, entry["id"]))
    else:
        rate = rate_for(entry, args.row, config)
    if rate is None:
        sys.exit("defects: %s has no measured rate for %s with a failure in it; declare a "
                 "calibration batch on a build that has the defect and measure it first"
                 % (entry["id"], args.row))
    if rate["config"] != config and not args.transfer:
        sys.exit("defects: the rate for %s was measured at %s, not %s. Measure it here, or pass "
                 "--transfer \"why the rate given exposure carries over\" (the reviewer checks it)"
                 % (args.row, rate["config"], config))
    delta, alpha = policy_numbers()
    planned = laps_needed(rate["k"], rate["n"], delta, alpha)
    bid = "b%s-%s" % (date.today().strftime("%Y%m%d"), uuid.uuid4().hex[:6])
    batch = {"id": bid, "kind": "verify", "row": args.row, "config": config,
             "platform": args.platform or "any", "planned": planned,
             "probe": args.probe or "", "candidate": args.candidate or "",
             "build": args.build or "", "variant": "", "state": "open",
             "leaves_cluster": bool(args.leaves_cluster), "support": args.support or [],
             "created": date.today().isoformat(), "rate": rate, "transfer": args.transfer or "",
             "lower_bound": clopper_pearson_lower(rate["k"], rate["n"], delta)}
    if not batch["probe"]:
        sys.exit("defects: a verification batch needs --probe, the kernel-log pattern that shows "
                 "a lap reached the defect's trigger; an unexposed pass is not a trial")
    if not batch["candidate"] and not batch["build"]:
        sys.exit("defects: name the release candidate (--candidate) or the build (--build) the "
                 "batch verifies")
    entry.setdefault("batches", []).append(batch)
    entry["updated"] = date.today().isoformat()
    save(data)
    print("declared verification batch %s for %s: %s at %s, %d clean laps "
          "(rate %d/%d, lower bound %.4f, delta %s, alpha %s)"
          % (bid, entry["id"], args.row, config, planned, rate["k"], rate["n"],
             batch["lower_bound"], delta, alpha))
    print("run each lap with: MXFS_BATCH=%s%s ./run.sh %s %s"
          % (bid, " MXFS_CANDIDATE=" + args.candidate if args.candidate else "", config, args.row))
    return 0


def cmd_batch_check(data: dict, args) -> int:
    """run.sh's question before a lap: may this lap run? Prints the batch's probe and whether the
    row leaves the cluster down (so the next lap re-forms it)."""
    criteria = board_tool()
    config = criteria.parse_at(args.batch_at)
    check_batch_lap(args.batch, args.row, config, args.candidate or "")
    _, batch = find_batch(data, args.batch)
    print("PROBE=%s" % batch.get("probe", ""))
    print("LEAVES_CLUSTER=%d" % (1 if batch.get("leaves_cluster") else 0))
    print("VARIANT=%s" % batch.get("variant", ""))
    return 0


def tree_build() -> str:
    """This tree's mxfs.ko srcversion: the build the named rows must pass on."""
    import subprocess
    try:
        out = subprocess.run(["modinfo", "-F", "srcversion", str(ROOT / "mxfs.ko")],
                             capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def retire_cells(entry: dict, disposition: str, why: str, configs=None,
                 approval: dict | None = None) -> list:
    """Append a `retired_by` note for every board run the record names (at `configs`, or
    everywhere), to each board's run ledger, under each board's lock taken in path order.
    Returns the lines to report."""
    criteria = board_tool()
    cells = [c for c in list(entry.get("cells") or []) + list(entry.get("collateral") or [])
             if configs is None or c["config"] in configs]
    by_board: dict = {}
    for cell in cells:
        by_board.setdefault(criteria.run_board(cell["config"], cell["row"]), []).append(cell)
    mark = {"defect": entry["id"], "disposition": disposition, "date": date.today().isoformat(),
            "why": why[:400]}
    if approval:
        mark["approval"] = approval
    handles, report = [], []
    for path in sorted(by_board, key=str):
        handles.append(criteria.lock_board(path))
    for path in sorted(by_board, key=str):
        notes = []
        for cell in by_board[path]:
            if criteria.ledger_run(path, cell["config"], cell["row"], cell["iso"]) is None:
                report.append("%s:%s:%s is not in the run ledger; nothing to retire"
                              % (cell["config"], cell["row"], cell["iso"]))
                continue
            notes.append(criteria.note(cell["config"], cell["row"], cell["iso"], "retired_by", mark))
            report.append("retired %s:%s:%s" % (cell["config"], cell["row"], cell["iso"]))
        criteria.append_ledger(path, notes)
    del handles
    return report


# A removal retires the runs its record names, but only those already in a run ledger: the boards
# were migrated into run ledgers after several removals, so the runs those removals named in
# CHANGELOG.md arrived unretired and stand as incidents with nothing left to name them. A retire
# proposal applies such a removal to the runs it named, once the reviewer has read the entry.

def removed_record(data: dict, wanted) -> str:
    """The id of a record that has left the queue. An open record names its runs with
    `update --cell`; only a removed one has a disposition to apply."""
    wanted = str(wanted or "").strip()
    if not re.fullmatch(r"D-[A-Za-z0-9.][A-Za-z0-9.-]*", wanted):
        sys.exit("defects: a retire proposal names the removed record by its full id (--record)")
    if any(str(e.get("id", "")) == wanted for e in data["defects"]):
        sys.exit("defects: %s is still in the queue; an open record names its runs with "
                 "`update --cell`" % wanted)
    return wanted


def unsettled(runs: list) -> None:
    """Every run is still an incident: no annotation settles it and no open record names it."""
    criteria = board_tool()
    named = criteria.named_runs()
    for cell in runs:
        board = criteria.run_board(cell["config"], cell["row"])
        key = (cell["config"], cell["row"], cell["iso"])
        if criteria.settled(board, *key) or named.get(key):
            sys.exit("defects: %s:%s:%s is already settled or named by an open record" % key)


def removal_entry(record: str, runs: list) -> tuple:
    """The CHANGELOG.md paragraph whose heading removed `record` and whose text names every run
    (its configuration, its row and its stamp): (first line, disposition, text). A run the
    removal never named is not retired by it."""
    lines = (ROOT / "CHANGELOG.md").read_text().splitlines()
    paragraphs, first, body = [], None, []
    for number, text in enumerate(lines + [""], 1):
        if text.strip():
            if first is None:
                first, body = number, []
            body.append(text.strip())
        elif first is not None:
            paragraphs.append((first, " ".join(body)))
            first = None
    heading = re.compile(r"\*\*Removed from the queue, (?P<how>[^:*]+):\s*(?P<id>D-[A-Za-z0-9.-]+?)"
                         r"\.?\*\*")
    found = False
    for first, text in paragraphs:
        match = heading.match(text)
        if not match or match.group("id") != record:
            continue
        found = True
        how = match.group("how").lower()
        disposition = "fixed" if "fixed and verified" in how else \
            "disproved" if "disproved" in how else ""
        if not disposition:
            sys.exit("defects: CHANGELOG.md:%d removed %s as %r, neither fixed and verified nor "
                     "disproved" % (first, record, match.group("how")))
        missing = [c for c in runs if c["iso"] not in text or c["config"] not in text
                   or not re.search(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % re.escape(c["row"]),
                                    text)]
        if not missing:
            return first, disposition, text
    if not found:
        sys.exit("defects: CHANGELOG.md has no paragraph headed **Removed from the queue, ...: "
                 "%s.**" % record)
    sys.exit("defects: no removal of %s in CHANGELOG.md names every run (configuration, row and "
             "stamp); a run it never named is not retired by it" % record)


def cmd_retire(data: dict, args) -> int:
    """Apply an approved retire proposal: a `retired_by` note, carrying the removal's disposition
    and the approval, on each run the removal named. Everything the proposal was checked against
    is checked again first, and the approval is spent only when all of it still holds."""
    record = removed_record(data, args.id)
    proposal = find_proposal(load_proposals(), args.approval or "")
    change = dict(proposal.get("change") or {})
    runs = [parse_cell(text, False) for text in change.get("runs") or []]
    if not runs:
        sys.exit("defects: proposal %s names no runs" % args.approval)
    check_cells(runs)
    unsettled(runs)
    line, disposition, text = removal_entry(record, runs)
    if disposition != change.get("disposition"):
        sys.exit("defects: CHANGELOG.md now removes %s as %s; the proposal was for %s"
                 % (record, disposition, change.get("disposition")))
    approval = require_approval(args.approval, "retire", record,
                                {"runs": change["runs"], "disposition": disposition})
    report = retire_cells({"id": record, "cells": runs}, disposition,
                          "CHANGELOG.md:%d %s" % (line, text), approval=approval)
    for entry in report:
        print(entry)
    return 0


def cmd_verify(data: dict, args) -> int:
    """A declared verification batch passed: the record stops blocking that configuration, on that
    candidate, and its named failures there are retired.

    The batch was sized before its first lap from the record's measured rate; every lap it ran on
    the candidate counts. It needs its planned number of exposed PASSes and no FAIL; an INCOMPLETE
    lap needs a reviewed infra disposition first. The record stays open: `remove` is the
    disposition of the defect itself."""
    entry, batch = find_batch(data, args.batch)
    if entry["id"] != find(data, args.id)["id"]:
        sys.exit("defects: batch %s belongs to %s" % (batch["id"], entry["id"]))
    if batch["kind"] != "verify":
        sys.exit("defects: %s is a %s batch, not a verification batch" % (batch["id"], batch["kind"]))
    if batch.get("state") != "open":
        sys.exit("defects: batch %s is %s" % (batch["id"], batch.get("state")))
    criteria = board_tool()
    laps = batch_runs(batch)
    fails = [r for r in laps if r.get("outcome") == "FAIL"]
    if fails:
        batch["state"] = "failed"
        for run in fails:
            cell = {"config": batch["config"], "row": batch["row"], "iso": run["iso"]}
            if cell not in (entry.get("cells") or []):
                entry.setdefault("cells", []).append(cell)
        entry["updated"] = date.today().isoformat()
        save(data)
        sys.exit("defects: batch %s FAILED %d lap(s) (%s): the defect is still there on this "
                 "candidate. The batch is closed; the failing runs are now named by %s. A new "
                 "batch needs a new finding in the record."
                 % (batch["id"], len(fails), ", ".join(r["iso"] for r in fails), entry["id"]))
    unsettled = [r for r in laps if r.get("outcome") in ("INCOMPLETE", "INFRA")
                 and not criteria.settled(criteria.board_for(batch["config"]), batch["config"],
                                          batch["row"], str(r.get("iso")))]
    if unsettled:
        sys.exit("defects: batch %s has %d INCOMPLETE or INFRA lap(s) with no reviewed disposition (%s)"
                 % (batch["id"], len(unsettled), ", ".join(r["iso"] for r in unsettled)))
    good = [r for r in laps if r.get("outcome") == "PASS" and exposed(r, batch)
            and not unplanned_variant(r, batch)]
    if len(good) < int(batch["planned"]):
        sys.exit("defects: batch %s has %d exposed PASS lap(s) of the %s planned (%d PASS without "
                 "exposure do not count); run the rest" % (batch["id"], len(good),
                                                          batch["planned"],
                                                          sum(1 for r in laps
                                                              if r.get("outcome") == "PASS")
                                                          - len(good)))
    approval = require_approval(args.approval, "verify", entry["id"],
                                {"batch": batch["id"]})
    batch["state"] = "passed"
    report = retire_cells(entry, "verified at " + batch["config"],
                          "batch %s: %d exposed clean laps on %s" %
                          (batch["id"], len(good), batch.get("candidate") or batch.get("build")),
                          configs={batch["config"]})
    entry["verified_at"] = [v for v in entry.get("verified_at") or []
                            if not (isinstance(v, dict) and v.get("config") == batch["config"]
                                    and v.get("candidate") == batch.get("candidate")
                                    and v.get("platform", "any") == batch.get("platform", "any"))]
    entry["verified_at"].append({"config": batch["config"], "platform": batch.get("platform", "any"),
                                 "candidate": batch.get("candidate", ""),
                                 "attempt": (criteria.attempt_began(batch["candidate"])
                                             if batch.get("candidate") else ""),
                                 "build": batch.get("build") or (laps[0].get("build") if laps else ""),
                                 "batch": batch["id"], "approval": approval["proposal"],
                                 "date": date.today().isoformat()})
    entry["updated"] = date.today().isoformat()
    save(data)
    print("verified %s at %s on %s: batch %s, %d exposed clean laps"
          % (entry["id"], batch["config"], batch.get("candidate") or batch.get("build"),
             batch["id"], len(good)))
    for line in report:
        print("  " + line)
    return 0


# ---------------------------------------------------------------------------------------------
# PROPOSALS AND REVIEWS
# ---------------------------------------------------------------------------------------------

def load_proposals() -> dict:
    try:
        with PROPOSALS.open() as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return {"proposals": []}
    except ValueError as exc:
        raise SystemExit(f"defects: {PROPOSALS} is not valid JSON: {exc}")
    data.setdefault("proposals", [])
    return data


def save_proposals(data: dict) -> None:
    PROPOSALS.parent.mkdir(parents=True, exist_ok=True)
    temporary = PROPOSALS.with_suffix(".json.tmp")
    with temporary.open("w") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    os.replace(temporary, PROPOSALS)


def find_proposal(proposals: dict, pid: str) -> dict:
    for proposal in proposals["proposals"]:
        if proposal.get("id") == pid:
            return proposal
    sys.exit(f"defects: no proposal {pid!r}")


def file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_approval(pid, kind: str, record, change: dict) -> dict:
    """The approved proposal a change needs, checked against exactly what is being changed, with
    its review file unchanged since the reviewer wrote it. Marks it applied. Called under the
    queue's lock."""
    if not pid:
        sys.exit("defects: this change needs a reviewed approval (--approval <proposal>): "
                 "tools/defects.py propose %s ..., then the release-reviewer agent" % kind)
    proposals = load_proposals()
    proposal = find_proposal(proposals, pid)
    if proposal.get("kind") != kind:
        sys.exit("defects: proposal %s is for %s, not %s" % (pid, proposal.get("kind"), kind))
    if record and proposal.get("record") != record:
        sys.exit("defects: proposal %s is for %s, not %s" % (pid, proposal.get("record"), record))
    for key, value in change.items():
        if proposal.get("change", {}).get(key) != value:
            sys.exit("defects: proposal %s approved %s=%r; this asks for %r"
                     % (pid, key, proposal.get("change", {}).get(key), value))
    if proposal.get("state") != "approved":
        sys.exit("defects: proposal %s is %s, not approved" % (pid, proposal.get("state")))
    review = proposal.get("review") or {}
    path = ROOT / review.get("file", "")
    if not review.get("file") or not path.is_file() or file_hash(path) != review.get("sha256"):
        sys.exit("defects: proposal %s's review file %s is missing or changed since the review"
                 % (pid, review.get("file")))
    proposal["state"] = "applied"
    proposal["applied"] = date.today().isoformat()
    save_proposals(proposals)
    return {"proposal": pid, "kind": kind, "review_sha256": review.get("sha256"),
            "date": proposal["applied"], "change": dict(proposal.get("change") or {})}


def approval_for(pid: str, kind: str, target: dict) -> dict:
    """For tools/criteria.py's amend and infra: the approval for one board run."""
    take_lock()
    return require_approval(pid, kind, None, target)


def cmd_propose(args) -> int:
    """Ask for a decision that stops a defect, or a failure, blocking. Nothing changes until the
    release-reviewer agent approves it and the change is made naming the approval."""
    data = load()
    change: dict = {}
    record = None
    if args.kind in ("noblock", "narrow", "verify", "remove-fixed", "remove-disproved", "exception"):
        if not args.record:
            sys.exit("defects: a %s proposal names the record (--record)" % args.kind)
        record = find(data, args.record)["id"]
    if args.kind == "noblock":
        limit = int(board_tool().policy().get("stall_limit_s", 30))
        if args.max_stall_s is None or not args.objective or not args.assertions:
            sys.exit("defects: a noblock proposal needs --objective (the performance objective it "
                     "violates), --assertions (the correctness assertions every named run "
                     "completed) and --max-stall-s (the worst measured operation stall)")
        if args.max_stall_s >= limit:
            sys.exit("defects: a %ss stall is a stability defect (data/release_policy.json "
                     "stall_limit_s=%d); it cannot be noblock" % (args.max_stall_s, limit))
        change = {"impact": "noblock", "objective": args.objective,
                  "assertions": args.assertions, "max_stall_s": args.max_stall_s}
    elif args.kind == "narrow":
        for field, value in (("nodes", args.nodes), ("config", args.config),
                             ("platform", args.platform)):
            if value is not None:
                change[field] = value
        if not change:
            sys.exit("defects: a narrow proposal names the new --nodes, --config or --platform")
    elif args.kind == "verify":
        if not args.batch:
            sys.exit("defects: a verify proposal names the batch (--batch)")
        change = {"batch": args.batch}
    elif args.kind == "remove-fixed":
        if not (args.control and args.fixon and args.cause):
            sys.exit("defects: a remove-fixed proposal names --control, --fixon and --cause")
        change = {"control": args.control, "fixon": args.fixon, "cause": args.cause}
    elif args.kind in ("detector-defect", "infra-proven"):
        if not args.target:
            sys.exit("defects: a %s proposal names the run (--target CONFIG:ROW:ISO)" % args.kind)
        cell = parse_cell(args.target, False)
        check_cells([cell])
        change = {"config": cell["config"], "row": cell["row"], "iso": cell["iso"]}
    elif args.kind == "retire":
        record = removed_record(data, args.record)
        if not args.run:
            sys.exit("defects: a retire proposal names each run (--run CONFIG:ROW:ISO, repeat)")
        runs = [parse_cell(text, False) for text in args.run]
        check_cells(runs)
        unsettled(runs)
        line, disposition, _ = removal_entry(record, runs)
        change = {"runs": ["%s:%s:%s" % (c["config"], c["row"], c["iso"]) for c in runs],
                  "disposition": disposition, "changelog_line": line}
    elif args.kind == "exception":
        if not (args.exception_at and args.candidate):
            sys.exit("defects: an exception proposal names the configuration (--at) and the "
                     "release (--candidate)")
        if owner_exception(record, args.exception_at, args.candidate) is None:
            sys.exit("defects: data/release_policy.json grants no exception for %s at %s in %s; "
                     "only the owner grants one" % (record, args.exception_at, args.candidate))
        change = {"config": args.exception_at, "candidate": args.candidate}
    if not str(args.argument or "").strip() or not args.evidence:
        sys.exit("defects: a proposal needs --argument (why) and at least one --evidence path")
    missing = [p for p in args.evidence if not (ROOT / p).exists()]
    if missing:
        sys.exit("defects: evidence not in the tree: %s" % ", ".join(missing))
    take_lock()
    proposals = load_proposals()
    pid = "P%s-%s" % (date.today().strftime("%Y%m%d"), uuid.uuid4().hex[:6])
    proposals["proposals"].append({"id": pid, "kind": args.kind, "record": record,
                                   "change": change, "argument": args.argument,
                                   "evidence": args.evidence, "state": "pending",
                                   "created": date.today().isoformat()})
    save_proposals(proposals)
    print("proposal %s (%s%s) is pending review. Have the release-reviewer agent review it:\n"
          "  Agent(subagent_type=release-reviewer, prompt=\"Review proposal %s.\")"
          % (pid, args.kind, " of " + record if record else "", pid))
    return 0


def cmd_except(data: dict, args) -> int:
    """The owner's exception, applied: the record stops blocking one configuration in one release.

    The owner grants it in data/release_policy.json, with the question and the answer; the
    release-reviewer checks that the proposal applies exactly that, and nothing else changes. The
    record stays open with its impact and reach, blocks every other configuration and release it
    reaches, and blocks this one again if the policy stops granting the exception."""
    entry = find(data, args.id)
    if owner_exception(entry["id"], args.except_at, args.candidate) is None:
        sys.exit("defects: data/release_policy.json grants no exception for %s at %s in %s"
                 % (entry["id"], args.except_at, args.candidate))
    approval = require_approval(args.approval, "exception", entry["id"],
                                {"config": args.except_at, "candidate": args.candidate})
    entry["excepted_at"] = [v for v in entry.get("excepted_at") or []
                            if not (isinstance(v, dict) and v.get("config") == args.except_at
                                    and v.get("candidate") == args.candidate)]
    entry["excepted_at"].append({"config": args.except_at, "candidate": args.candidate,
                                 "approval": approval["proposal"],
                                 "date": date.today().isoformat()})
    entry["updated"] = date.today().isoformat()
    save(data)
    print("%s does not block %s in %s: the owner's exception, applied by %s. The record stays open."
          % (entry["id"], args.except_at, args.candidate, approval["proposal"]))
    return 0


def cmd_proposal_show(args) -> int:
    proposal = find_proposal(load_proposals(), args.pid)
    print(json.dumps(proposal, indent=2))
    if proposal.get("record"):
        print()
        show_one(find(load(), proposal["record"]))
    return 0


def cmd_review(args) -> int:
    """The reviewer's verdict on a proposal, with the review file it wrote. The file's hash is
    recorded: a change applied later checks the file has not changed since."""
    path = Path(args.file)
    path = path if path.is_absolute() else ROOT / path
    if not path.is_file():
        sys.exit("defects: review file %s does not exist" % path)
    try:
        relative = path.resolve().relative_to(REVIEWS.resolve())
    except ValueError:
        sys.exit("defects: review files live in %s" % REVIEWS)
    proposals = load_proposals()
    proposal = find_proposal(proposals, args.pid)
    if proposal.get("state") != "pending":
        sys.exit("defects: proposal %s is %s; reviewed once" % (args.pid, proposal.get("state")))
    proposal["state"] = "approved" if args.approve else "rejected"
    proposal["review"] = {"file": str(Path("data") / "reviews" / relative),
                          "sha256": file_hash(path), "verdict": proposal["state"],
                          "date": date.today().isoformat()}
    save_proposals(proposals)
    print("proposal %s %s (review %s)" % (args.pid, proposal["state"], proposal["review"]["file"]))
    return 0


def cmd_add(data: dict, args) -> int:
    if not args.summary:
        sys.exit("defects: add needs -m/--summary saying what is broken")
    check_impact(args.impact, args.impact_why)
    severity = (args.severity or "medium").lower()
    if severity not in SEVERITIES:
        sys.exit(f"defects: severity {severity!r}; expected one of {list(SEVERITIES)}")
    if args.nodes is not None and args.nodes < 1:
        sys.exit("defects: -N/--nodes is the smallest cluster it was seen on; at least 1")

    taken = {str(e.get("id", "")) for e in data["defects"]}
    entry = {"id": check_id(args.id.strip()) if args.id else mint(args.summary, taken),
             "severity": severity,
             "nodes": DEFAULT_NODES if args.nodes is None else args.nodes,
             "config": args.config or DEFAULT_CONFIG,
             "opened": date.today().isoformat(),
             "summary": args.summary}
    if entry["id"] in taken:
        sys.exit(f"defects: {entry['id']} already exists")
    if args.evidence:
        entry["evidence"] = args.evidence
    if args.next:
        entry["next"] = args.next
    if args.impact:
        entry["impact"] = str(args.impact).lower()
        entry["impact_why"] = args.impact_why
    if args.platform:
        entry["platform"] = args.platform.lower()
    if args.reproducer:
        entry["reproducer"] = args.reproducer
    add_cells(entry, args)

    data["defects"].append(entry)
    save(data)
    print(f"added {entry['id']}  ({config_of(entry)})")
    return 0


def narrowing(entry: dict, args) -> dict:
    """The reach changes in an update that would let the record block LESS: more nodes, a config
    other than every configuration, a platform other than every platform. Widening needs no
    review; narrowing does, because a reach comes from runs and never from reading code."""
    narrower = {}
    seen_nodes, pattern = reach(entry)
    if args.nodes is not None and args.nodes > seen_nodes:
        narrower["nodes"] = args.nodes
    if args.config and args.config.lower() not in (DEFAULT_CONFIG, pattern):
        narrower["config"] = args.config.lower()
    if args.platform and args.platform.lower() not in (DEFAULT_PLATFORM, platform_of(entry)):
        narrower["platform"] = args.platform.lower()
    return narrower


def cmd_update(data: dict, args) -> int:
    entry = find(data, args.id)
    narrower = narrowing(entry, args)
    approvals = []
    if narrower:
        approvals.append(require_approval(args.approval, "narrow", entry["id"], narrower))
    if args.impact and str(args.impact).lower() == "noblock" \
            and str(entry.get("impact", "")).lower() != "noblock":
        granted = require_approval(args.approval, "noblock", entry["id"], {"impact": "noblock"})
        approvals.append(granted)
        entry["noblock"] = {k: v for k, v in granted["change"].items() if k != "impact"}
    changed = []
    #: -w and -n replace. On a record that already holds evidence or a next step, a replace wipes
    #: the history the record is for (2026-10-21: an -w meant to add a second sighting erased the
    #: first's evidence), so it needs --replace; adding goes through -W and -a.
    for field, flag, add in (("evidence", "-w", "-W"), ("next", "-n", "-a")):
        value = getattr(args, field if field != "next" else "next_step", None)
        if value and entry.get(field) and not getattr(args, "replace", False):
            sys.exit(f"defects: {entry['id']} already has {field}; {flag} would replace it. "
                     f"Add to it with {add}, or pass --replace to replace it on purpose")
    for field in FIELDS:
        value = getattr(args, field if field != "next" else "next_step", None)
        if value is not None and value != "":
            entry[field] = value.lower() if field in ("config", "platform", "impact") else value
            changed.append(field)
    #: A record's next step is its investigation, oldest finding first; every
    #: session so far rebuilt it by hand as "old ===== new" because -n replaces.
    #: The separator is the one those hand-built records already use.
    #: It appends to `next`, the field every other path reads and prints. An earlier version wrote
    #: a separate `next_step`, which `-n` then silently left in place while replacing `next`, so a
    #: record could carry two next-step histories and a replace could destroy the canonical one
    #: while the caller checked the stray one. `load` folds any such field back into `next`.
    #: A record written before the fields were text keeps them as a list of entries (the
    #: 32-node records of 2026-08 and 2026-09); an append to one adds an entry, so the list
    #: neither breaks the append nor is flattened into text it was not written as.
    appended = getattr(args, "append_next", None)
    if appended:
        have = entry.get("next") or ""
        if isinstance(have, list):
            entry["next"] = have + [appended]
        else:
            entry["next"] = (have + " ===== " if have else "") + appended
        changed.append("next")
    #: The same for evidence: a board cell a record accounts for (configuration, row, verdict,
    #: stamp) is added to what the record already cites, never typed over it.
    appended = getattr(args, "append_evidence", None)
    if appended:
        have = entry.get("evidence") or ""
        if isinstance(have, list):
            entry["evidence"] = have + [appended]
        else:
            entry["evidence"] = (have + " ===== " if have else "") + appended
        changed.append("evidence")
    changed += add_cells(entry, args)
    changed += drop_cells(data, entry, args)
    if args.reproducer:
        entry["reproducer"] = args.reproducer
        changed.append("reproducer")
    if not changed:
        sys.exit("defects: update needs at least one of -s/-m/-n/-a/-w/-W/-N/-C/-P/-I/"
                 "--cell/--collateral/--drop-cell/--reproducer")
    for granted in approvals:
        entry.setdefault("approvals", []).append({k: v for k, v in granted.items()
                                                  if k != "change"})
    #: Checked against what the record will HOLD, not only against what this call passed, so that
    #: `-I noblock` on a record whose reason was written earlier is accepted while `-I noblock` with
    #: no reason anywhere is not.
    if "impact" in changed:
        check_impact(entry["impact"], entry.get("impact_why"))
    elif "impact_why" in changed and not entry.get("impact"):
        sys.exit("defects: --impact-why is the reason for a bar, and this record has none. "
                 "Set both, with -I/--impact.")
    #: Setting reach BY HAND means someone read the record. That is the only thing that upgrades a
    #: heuristic guess to a claim the release gate can rest on.
    if "nodes" in changed or "config" in changed or "platform" in changed:
        entry["reach_source"] = "evidence"
    if "severity" in changed and str(entry["severity"]).lower() not in SEVERITIES:
        sys.exit(f"defects: severity {entry['severity']!r}; expected one of {list(SEVERITIES)}")
    if "nodes" in changed and int(entry["nodes"]) < 1:
        sys.exit("defects: -N/--nodes is the smallest cluster it was seen on; at least 1")
    entry["updated"] = date.today().isoformat()
    save(data)
    print(f"updated {entry['id']}: {', '.join(changed)}  ({config_of(entry)})")
    return 0


def cmd_remove(data: dict, args) -> int:
    """A defect leaves ONLY on evidence, and what leaves is written down somewhere else.

    `--why` IS NOT OPTIONAL. An entry that cannot say what was measured is not fixed, and removing
    it without that is how a known defect becomes a "known limitation" by attrition -- which is the
    whole reason the ledger exists.
    """
    entry = find(data, args.id)
    if not args.why:
        sys.exit("defects: remove needs --why saying what was measured and what it said")
    disposition = "fixed" if args.fixed else "disproved"
    if disposition == "fixed":
        gaps = []
        if not str(entry.get("reproducer") or "").strip():
            gaps.append("no reproducer: name the test that reaches the cause (update --reproducer)")
        if not (args.control and args.fixon and args.cause):
            gaps.append("--control, --fixon and --cause are all required")
        else:
            owner, control = find_batch(data, args.control)
            owner2, fixon = find_batch(data, args.fixon)
            if owner is not entry or owner2 is not entry:
                gaps.append("both batches must belong to %s" % entry["id"])
            if control.get("kind") != "control" or control.get("state") != "closed":
                gaps.append("%s is not a closed control batch" % args.control)
            rate = next((r for r in entry.get("rates") or [] if r.get("batch") == args.control), None)
            if not rate or rate.get("k", 0) < 1:
                gaps.append("the control batch %s did not reproduce the failure: with the fix taken "
                            "out nothing failed, so nothing shows the fix is what ended it"
                            % args.control)
            if fixon.get("kind") != "verify" or fixon.get("state") != "passed":
                gaps.append("%s is not a verification batch that passed (defects.py verify)"
                            % args.fixon)
            if (fixon.get("rate") or {}).get("batch") != args.control:
                gaps.append("%s was not sized from the control %s (plan-verify --control)"
                            % (args.fixon, args.control))
        if gaps:
            sys.exit("defects: %s cannot be removed as FIXED AND VERIFIED yet:\n  %s"
                     % (entry["id"], "\n  ".join(gaps)))
        require_approval(args.approval, "remove-fixed", entry["id"],
                         {"control": args.control, "fixon": args.fixon, "cause": args.cause})
    else:
        require_approval(args.approval, "remove-disproved", entry["id"], {})
    report = retire_cells(entry, disposition, args.why)
    data["defects"] = [e for e in data["defects"] if e is not entry]
    save(data)

    print(f"removed {entry['id']} ({'FIXED AND VERIFIED' if disposition == 'fixed' else 'DISPROVED'})")
    for line in report:
        print("  " + line)
    print("\nThe fix belongs in CHANGELOG.md. Paste this under today's version:\n")
    print(f"- **{entry.get('summary', entry['id'])}** — {args.why}")
    return 0


def cmd_rename(data: dict, args) -> int:
    """A new id for an existing record; nothing else about it changes.

    Ids are minted from the summary and can run to a dozen words, which nobody types and nobody
    reads in a queue listing.  The numeric suffix (`-0962`) is how evidence directories, memories
    and CHANGELOG entries refer to a record, so a rename that drops it must be deliberate: the tool
    warns and keeps going, because the id is the user's to choose.
    """
    entry = find(data, args.id)
    new_id = args.new_id.strip()
    if not re.fullmatch(r"D-[A-Z0-9][A-Z0-9-]*", new_id):
        sys.exit(f"defects: {new_id!r} is not an id of the form D-WORDS-LIKE-THIS[-0962]")
    check_id(new_id)
    if any(str(e.get("id", "")) == new_id for e in data["defects"]):
        sys.exit(f"defects: {new_id} already exists")
    old_id = str(entry.get("id", ""))
    old_suffix = re.search(r"-(\d{3,4})$", old_id)
    if old_suffix and not new_id.endswith("-" + old_suffix.group(1)):
        print(f"warning: {old_id} ends in -{old_suffix.group(1)} and {new_id} does not; "
              "evidence directories and CHANGELOG entries refer to it by that number")
    entry["id"] = new_id
    entry["updated"] = date.today().isoformat()
    save(data)
    print(f"renamed {old_id}\n     -> {new_id}  ({config_of(entry)})")
    return 0


def config_pattern(text: str) -> str:
    """argparse type for -C: a valid class/method/attach pattern, normalised."""
    try:
        return configuration.check_pattern(text)
    except configuration.ConfigurationError as exc:
        raise argparse.ArgumentTypeError(str(exc))


#: What each retired `dlm` value becomes. The attachment is left open (`*`) on every record: none
#: of them recorded which attachment its evidence came from, and a reach is narrowed only from a
#: record's own evidence, never by a migration.
DLM_TO_CONFIG = {"any": "*/*/*", "tcp": "net/mesh/*", "caw": "disk/caw/*",
                 "cawd": "disk/caw/*", "cawp": "disk/caw/*", "xfs": "xfs"}


def cmd_migrate_config(data: dict, args) -> int:
    """ONE TIME: replace each record's `dlm` with a `config` pattern, keeping field order."""
    if any("config" in e for e in data["defects"]):
        sys.exit("defects: %s is already migrated" % LEDGER)
    counts: dict[str, int] = {}
    for position, entry in enumerate(data["defects"]):
        old = str(entry.get("dlm", "any")).lower()
        pattern = DLM_TO_CONFIG.get(old, DEFAULT_CONFIG)
        counts["%s -> %s" % (old, pattern)] = counts.get("%s -> %s" % (old, pattern), 0) + 1
        rebuilt = {}
        for key, value in entry.items():
            if key == "dlm":
                rebuilt["config"] = pattern
            else:
                rebuilt[key] = value
        if "config" not in rebuilt:
            rebuilt["config"] = pattern
        data["defects"][position] = rebuilt
    for line in sorted(counts):
        print("%-24s %d" % (line, counts[line]))
    print("records: %d" % len(data["defects"]))
    if args.dry_run:
        print("dry run: nothing written")
        return 0
    save(data)
    print("migrated %s" % LEDGER)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="what is broken and still needs work",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("    tools/defects.py")[0].strip())
    parser.add_argument("-d", "--detail", action="store_true",
                        help="include each one's next step")
    parser.add_argument("-s", "--severity", help="filter the queue by severity")
    parser.add_argument("--at", metavar="NODES[/CLASS[/METHOD[/ATTACH]]][@PLATFORM]",
                        help="only what blocks those configurations, e.g. 2/net/mesh/direct, "
                             "2/disk or 2/net/mesh/direct@pve9. May also be given bare: "
                             "`defects.py 2/net/mesh/direct`")
    parser.add_argument("--release", action="store_true",
                        help="only what blocks a release: data integrity and stability. "
                             "An unadjudicated record blocks.")
    parser.add_argument("--gate", action="store_true",
                        help="exit 1 if anything is left after the filters, 0 if nothing is. "
                             "Without it every list exits 0, empty or not.")
    parser.add_argument("--json", action="store_true", help="the queue as JSON")

    subs = parser.add_subparsers(dest="command")

    show = subs.add_parser("show", help="one entry in full")
    show.add_argument("id")

    add = subs.add_parser("add", help="record a new defect")
    add.add_argument("-s", "--severity", default="medium", choices=SEVERITIES)
    add.add_argument("-m", "--summary", required=True, help="what is broken")
    add.add_argument("-w", "--evidence", help="how it shows, and what was measured")
    add.add_argument("-n", "--next", help="the next step")
    add.add_argument("-N", "--nodes", type=int,
                     help="smallest cluster it was observed on (default %d)" % DEFAULT_NODES)
    add.add_argument("-C", "--config", type=config_pattern,
                     help="class/method/attach pattern the evidence reaches, e.g. disk/caw "
                          "(default %s)" % DEFAULT_CONFIG)
    add.add_argument("-P", "--platform", choices=PLATFORMS,
                     help="platform it reaches, from data/platforms.json (default %s)"
                          % DEFAULT_PLATFORM)
    add.add_argument("-I", "--impact", choices=IMPACTS,
                     help="the release bar this behaviour crosses; absent blocks every release")
    add.add_argument("--impact-why", dest="impact_why",
                     help="what was measured that establishes that bar; required with -I")
    add.add_argument("--id", help="override the generated id; at most %d characters. "
                     "Required when the summary is too long to name itself." % MAX_ID)
    add.add_argument("--cell", action="append", metavar="CONFIG:ROW:ISO",
                     help="a board run this record accounts for (repeat for each)")
    add.add_argument("--collateral", action="append", metavar="CONFIG:ROW:ISO=EVIDENCE",
                     help="a board run that failed because of this defect, with the log "
                          "evidence of the dependency (repeat for each)")
    add.add_argument("--reproducer", help="the test that reaches the cause, and how")

    update = subs.add_parser("update", help="change an entry")
    update.add_argument("id")
    update.add_argument("-s", "--severity", choices=SEVERITIES)
    update.add_argument("-m", "--summary")
    update.add_argument("-w", "--evidence", help="replace the evidence (needs --replace when the "
                                                 "record has some; -W adds to it)")
    update.add_argument("--replace", action="store_true",
                        help="let -w / -n replace a field that already holds text")
    update.add_argument("-W", "--append-evidence", dest="append_evidence",
                        help="append to the evidence after a ' ===== ' separator instead of "
                             "replacing it")
    update.add_argument("-n", "--next", dest="next_step")
    update.add_argument("-a", "--append-next", dest="append_next",
                        help="append to the next step after a ' ===== ' separator instead of "
                             "replacing it")
    update.add_argument("-N", "--nodes", type=int,
                        help="smallest cluster it was observed on")
    update.add_argument("-C", "--config", type=config_pattern,
                        help="class/method/attach pattern the evidence reaches, e.g. disk/caw")
    update.add_argument("-P", "--platform", choices=PLATFORMS,
                        help="platform it reaches, from data/platforms.json")
    update.add_argument("-I", "--impact", choices=IMPACTS,
                        help="the release bar this behaviour crosses; %s is the only value that "
                             "takes a record out of --release" % IMPACT_CLEAR[0])
    update.add_argument("--impact-why", dest="impact_why",
                        help="what was measured that establishes that bar; required with -I")
    update.add_argument("--cell", action="append", metavar="CONFIG:ROW:ISO",
                        help="add a board run this record accounts for (repeat for each)")
    update.add_argument("--collateral", action="append", metavar="CONFIG:ROW:ISO=EVIDENCE",
                        help="add a board run that failed because of this defect, with the log "
                             "evidence of the dependency (repeat for each)")
    update.add_argument("--drop-cell", dest="drop_cell", action="append", metavar="CONFIG:ROW:ISO",
                        help="stop naming a run that a standing disposition already settles or "
                             "another open record names (repeat; needs --drop-why)")
    update.add_argument("--drop-why", dest="drop_why",
                        help="--drop-cell: the run's own evidence that this record's cause did "
                             "not fail it")
    update.add_argument("--reproducer", help="the test that reaches the cause, and how")
    update.add_argument("--approval", help="the approved proposal a noblock impact or a narrower "
                                           "reach needs")

    remove = subs.add_parser("remove", help="it is fixed or it was never real")
    remove.add_argument("id")
    disposition = remove.add_mutually_exclusive_group(required=True)
    disposition.add_argument("--fixed", action="store_true",
                             help="FIXED AND VERIFIED: needs --control, --fixon, --cause and an "
                                  "approval")
    disposition.add_argument("--disproved", action="store_true",
                             help="DISPROVED: direct evidence that it was not an MXFS defect")
    remove.add_argument("--why", required=True,
                        help="what was measured and what it said")
    remove.add_argument("--control", help="the closed control batch that reproduced with the fix "
                                          "taken out")
    remove.add_argument("--fixon", help="the passed verification batch sized from that control")
    remove.add_argument("--cause", help="the proven cause the fix targets")
    remove.add_argument("--approval", help="the approved proposal")

    verify = subs.add_parser("verify", help="a declared verification batch passed: the record "
                                            "stops blocking that configuration on that candidate")
    verify.add_argument("id")
    verify.add_argument("--batch", required=True, help="the verification batch")
    verify.add_argument("--approval", help="the approved proposal")

    def batch_options(sub, sized: bool):
        sub.add_argument("id")
        sub.add_argument("--row", required=True, help="the board row the laps run")
        sub.add_argument("--at", dest="batch_at", metavar="CONFIGURATION", required=True)
        sub.add_argument("--probe", help="kernel-log pattern showing a lap reached the trigger")
        sub.add_argument("--candidate", help="the release candidate the laps run on")
        sub.add_argument("--build", help="the build the laps run on, when not a candidate")
        sub.add_argument("--platform", choices=PLATFORMS, help="the platform the laps run on")
        sub.add_argument("--leaves-cluster", dest="leaves_cluster", action="store_true",
                         help="the row leaves the cluster down: re-form it before every lap")
        sub.add_argument("--support", action="append",
                         help="a row the batch row needs in the same run (alloc_witness for "
                              "chk_clean); recorded but not counted")
        if not sized:
            sub.add_argument("--kind", choices=("calibrate", "control"), required=True)
            sub.add_argument("--runs", type=int, required=True,
                             help="the number of laps, fixed before the first one")
            sub.add_argument("--variant", help="how a control takes the fix out")
            sub.add_argument("--why", help="what the batch is for")
        else:
            sub.add_argument("--control", help="size from this control batch's rate (fix-on arm)")
            sub.add_argument("--transfer", help="why a rate measured at another configuration "
                                                "carries over here")

    batch = subs.add_parser("batch", help="declare a calibration or control batch")
    batch_options(batch, False)
    plan = subs.add_parser("plan-verify", help="declare a verification batch sized from the "
                                               "record's measured rate")
    batch_options(plan, True)

    measure = subs.add_parser("measure", help="close a calibration or control batch: its rate")
    measure.add_argument("id")
    measure.add_argument("--batch", required=True)

    check = subs.add_parser("batch-check", help="may this lap run? (run.sh asks before a lap)")
    check.add_argument("batch")
    check.add_argument("--row", required=True)
    check.add_argument("--at", dest="batch_at", metavar="CONFIGURATION", required=True)
    check.add_argument("--candidate")

    propose = subs.add_parser("propose", help="ask for a decision that stops something blocking")
    propose.add_argument("kind", choices=PROPOSAL_KINDS)
    propose.add_argument("--record", help="the defect record")
    propose.add_argument("--target", metavar="CONFIG:ROW:ISO",
                         help="the board run (detector-defect, infra-proven)")
    propose.add_argument("--run", action="append", metavar="CONFIG:ROW:ISO",
                         help="retire: a run the removed record's CHANGELOG.md removal names "
                              "(repeat for each)")
    propose.add_argument("--batch", help="the verification batch (verify)")
    propose.add_argument("--control")
    propose.add_argument("--fixon")
    propose.add_argument("--cause")
    propose.add_argument("--objective", help="noblock: the performance objective it violates")
    propose.add_argument("--assertions",
                         help="noblock: the correctness assertions every named run completed")
    propose.add_argument("--max-stall-s", dest="max_stall_s", type=float,
                         help="noblock: the worst measured operation stall, seconds")
    propose.add_argument("-N", "--nodes", type=int, help="narrow: the new smallest cluster")
    propose.add_argument("-C", "--config", type=config_pattern, help="narrow: the new pattern")
    propose.add_argument("-P", "--platform", choices=PLATFORMS, help="narrow: the new platform")
    propose.add_argument("--at", dest="exception_at", metavar="CONFIGURATION",
                         help="exception: the configuration the owner's exception names")
    propose.add_argument("--candidate", help="exception: the release it is granted for")
    propose.add_argument("--argument", required=True, help="why, in full")
    propose.add_argument("--evidence", action="append", required=True,
                         help="a path in the tree the reviewer must read (repeat for each)")

    review = subs.add_parser("review", help="the release-reviewer agent's verdict on a proposal")
    review.add_argument("pid")
    verdict = review.add_mutually_exclusive_group(required=True)
    verdict.add_argument("--approve", action="store_true")
    verdict.add_argument("--reject", action="store_true")
    review.add_argument("--file", required=True, help="the review it wrote, in data/reviews/")

    excepted = subs.add_parser("except", help="apply the owner's exception: the record stops "
                                              "blocking one configuration in one release")
    excepted.add_argument("id")
    excepted.add_argument("--at", dest="except_at", metavar="CONFIGURATION", required=True)
    excepted.add_argument("--candidate", required=True, help="the release it is granted for")
    excepted.add_argument("--approval", help="the approved exception proposal")

    retire = subs.add_parser("retire", help="apply a removed record's disposition to the runs "
                                            "its removal named that reached a ledger later")
    retire.add_argument("id", help="the removed record's full id")
    retire.add_argument("--approval", required=True, help="the approved retire proposal")

    proposal = subs.add_parser("proposal", help="show a proposal")
    proposal_subs = proposal.add_subparsers(dest="proposal_command", required=True)
    proposal_show = proposal_subs.add_parser("show")
    proposal_show.add_argument("pid")

    rename = subs.add_parser("rename", help="give an entry a new id; nothing else changes")
    rename.add_argument("id")
    rename.add_argument("new_id", help="the new id, D-WORDS-LIKE-THIS-0962 (keep the number); "
                        "at most %d characters" % MAX_ID)

    migrate = subs.add_parser("migrate-config",
                              help="one time: replace each record's dlm field with a config pattern")
    migrate.add_argument("--dry-run", action="store_true")

    args = parser.parse_args(lift_config(sys.argv)[1:])
    for missing in ("at", "release", "gate", "nodes", "config", "platform", "next_step", "summary",
                    "evidence", "id", "next", "impact", "impact_why", "cell", "collateral",
                    "reproducer", "fixed", "disproved", "approval", "control", "fixon", "cause"):
        if not hasattr(args, missing):
            setattr(args, missing, None)
    if args.command == "propose":
        return cmd_propose(args)
    if args.command == "review":
        take_lock()
        return cmd_review(args)
    if args.command == "proposal":
        return cmd_proposal_show(args)
    #: BEFORE `load`, because the window that loses a record spans the read as well as the write.
    #: Read-only paths do not take it: `save` is atomic, so a reader sees the before or the after
    #: state and never a torn document, and making every listing contend for a lock would make the
    #: one command every session runs able to block.
    if args.command in MUTATORS:
        take_lock()
    data = load()

    if args.command == "show":
        return cmd_show(data, args)
    if args.command == "add":
        return cmd_add(data, args)
    if args.command == "update":
        return cmd_update(data, args)
    if args.command == "remove":
        return cmd_remove(data, args)
    if args.command == "retire":
        return cmd_retire(data, args)
    if args.command == "rename":
        return cmd_rename(data, args)
    if args.command == "verify":
        return cmd_verify(data, args)
    if args.command == "batch":
        return cmd_batch(data, args)
    if args.command == "measure":
        return cmd_measure(data, args)
    if args.command == "plan-verify":
        return cmd_plan_verify(data, args)
    if args.command == "batch-check":
        return cmd_batch_check(data, args)
    if args.command == "except":
        return cmd_except(data, args)
    if args.command == "migrate-config":
        return cmd_migrate_config(data, args)
    return cmd_list(data, args)


if __name__ == "__main__":
    sys.exit(main())
