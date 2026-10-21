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
    tools/defects.py update  <id> --ab "off=10/10 on=0/10 build=<srcversion> evidence=<path>"
    tools/defects.py remove  <id> --fixed     --why "what was measured and what it said"
    tools/defects.py remove  <id> --disproved --why "what was measured and what it said"

EVERY BOARD FAILURE A RECORD ACCOUNTS FOR IS NAMED, NOT DESCRIBED. `--cell CONFIG:ROW:ISO` is
one recorded run of a board row (its stamp exactly as `tools/criteria.py show <row>` prints it),
checked against the board when it is given; `--collateral CONFIG:ROW:ISO=<evidence>` is a run
that failed because of this defect without measuring it (a node that could not unmount behind the
hung creates), with the log line that shows the dependency. `tools/criteria.py --unattributed`
lists every genuine failure in a window that no open record names.

FIXED AND VERIFIED NEEDS A REPRODUCER THAT FAILS EVERY TIME WITHOUT THE FIX. `remove --fixed`
refuses a record with no `--reproducer`, or whose `--ab` does not show the fix-off arm failing
every lap and the fix-on arm passing every lap on one build. A defect seen only now and then with
no reproducer like that stays open: passing laps cannot close it. It also refuses while any row
the record names, its own failures retired, does not PASS on this tree's build. Then each named
run is marked as retired by the record on the board, and only the flake window stops counting it.
`--disproved` retires them the same way, with no reproducer and no pass required.
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
import json
import os
import re
import signal
import sys
import time
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
LEDGER = ROOT / "data" / "defects.json"

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
LOCK = ROOT / "data" / ".defects.lock"
MUTATORS = ("add", "update", "remove", "verify", "rename", "migrate-config")

#: A save measures ~6 ms on the real 858 KB ledger, so anything still holding the lock after this
#: long is wedged rather than busy, and saying so beats blocking a session forever.
LOCK_WAIT_SECONDS = 30

#: For `lift_config` only: what a leading bare configuration must not be mistaken for.
SUBCOMMANDS = ("show", "add", "update", "remove", "verify", "rename", "migrate-config")
VALUE_FLAGS = ("-s", "--severity", "--at")

ORDERED = ("id", "severity", "nodes", "config", "platform", "opened", "updated", "summary",
           "evidence", "next", "cells", "collateral", "reproducer", "ab", "reproducible",
           "verified_at")

#: `--ab`: the fix-off and fix-on arms of the reproducer on one build, as counts of laps.
AB_FORM = re.compile(r"^off=(\d+)/(\d+)\s+on=(\d+)/(\d+)\s+build=([0-9A-F]{23})\s+evidence=(\S+)$")


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


def blocks(entry: dict, nodes: int, selector: tuple, platform=None) -> bool:
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
    #: A reproducible defect `verify` found passing at exactly this configuration, on this tree's
    #: build, has nothing left to say about it: the board there passes with its failures retired.
    #: It still blocks every configuration it reaches and was not verified at.
    if verified_here(entry, configuration.selector_label(nodes, selector)):
        return False
    return configuration.overlaps(pattern, selector)


#: This tree's mxfs.ko srcversion, read once per process.
build_cache = None


def verified_here(entry: dict, config: str) -> bool:
    """Was this record verified (`defects.py verify`) at exactly `config`, on this tree's build?"""
    marks = [v for v in entry.get("verified_at") or []
             if isinstance(v, dict) and v.get("config") == config]
    if not marks:
        return False
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
            print("  %-10s %s on build %s (%s): passes there, does not block it"
                  % ("verified", mark.get("config"), mark.get("build"), mark.get("date")))
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
    config, _, rest = text.strip().partition(":")
    row, _, iso = rest.partition(":")
    if not (config and row and iso):
        sys.exit(f"defects: {text!r}: a board run is CONFIG:ROW:ISO, e.g. "
                 "4/net/mesh/direct:alloc_witness:2026-10-20T07:38:35Z")
    cell = {"config": board_tool().parse_at(config), "row": row, "iso": iso}
    if collateral:
        cell["why"] = why.strip()
    return cell


def check_cells(cells: list) -> None:
    """Every named run exists on its board and did not pass. A record that names a run nobody
    recorded, or a passing one, accounts for nothing."""
    criteria = board_tool()
    for cell in cells:
        board = criteria.read_board(criteria.board_for(cell["config"]))
        row, run = criteria.run_of(board, cell["row"], cell["config"], cell["iso"])
        if row is None:
            sys.exit(f"defects: no board row {cell['row']!r}")
        if run is None:
            sys.exit("defects: %s at %s records no run stamped %s (recorded: %s)"
                     % (cell["row"], cell["config"], cell["iso"],
                        ", ".join(str(r.get("iso", "?"))
                                  for r in criteria.runs_of(row, cell["config"]))))
        if str(run.get("status", "")).upper().strip() == "PASS":
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


def parse_ab(text: str) -> dict:
    match = AB_FORM.match(text.strip())
    if not match:
        sys.exit("defects: --ab is \"off=<failed>/<laps> on=<failed>/<laps> build=<srcversion> "
                 "evidence=<path>[,<path>]\": the reproducer's laps with the fix off and on, on "
                 "one build")
    off_fail, off_laps, on_fail, on_laps = (int(match.group(i)) for i in range(1, 5))
    if off_fail > off_laps or on_fail > on_laps:
        sys.exit("defects: --ab counts more failed laps than laps")
    missing = [p for p in match.group(6).split(",") if not (ROOT / p).exists()]
    if missing:
        sys.exit("defects: --ab evidence not in the tree: %s" % ", ".join(missing))
    return {"off_fail": off_fail, "off_laps": off_laps, "on_fail": on_fail, "on_laps": on_laps,
            "build": match.group(5), "evidence": match.group(6)}


def fixed_gaps(entry: dict) -> list:
    """What a record still lacks to be removed as FIXED AND VERIFIED."""
    gaps = []
    if not str(entry.get("reproducer") or "").strip():
        gaps.append("no reproducer: name the test that reaches the cause (update --reproducer)")
    ab = entry.get("ab")
    if not ab:
        gaps.append("no fix-off/fix-on result on one build (update --ab)")
    else:
        if ab["off_laps"] < 1 or ab["off_fail"] != ab["off_laps"]:
            gaps.append("the fix-off arm failed %d of %d laps; it must fail every lap, or the "
                        "reproducer does not reach the cause reliably enough to prove the fix"
                        % (ab["off_fail"], ab["off_laps"]))
        if ab["on_laps"] < 1 or ab["on_fail"] != 0:
            gaps.append("the fix-on arm failed %d of %d laps; it must pass every lap"
                        % (ab["on_fail"], ab["on_laps"]))
    return gaps


def tree_build() -> str:
    """This tree's mxfs.ko srcversion: the build the named rows must pass on."""
    import subprocess
    try:
        out = subprocess.run(["modinfo", "-F", "srcversion", str(ROOT / "mxfs.ko")],
                             capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def retire_cells(entry: dict, disposition: str, why: str) -> list:
    """Mark every board run the record names as retired by it, on every board they live on.

    For FIXED the rows it names must then PASS on this tree's build -- the record's own failures
    no longer counted, and nothing else in their windows -- or nothing is written at all. Returns
    the lines to report: each run retired, and each one that has already aged off its board."""
    criteria = board_tool()
    cells = list(entry.get("cells") or []) + list(entry.get("collateral") or [])
    by_board: dict = {}
    for cell in cells:
        by_board.setdefault(criteria.board_for(cell["config"]), []).append(cell)
    build = tree_build() if disposition == "fixed" else ""
    if disposition == "fixed" and cells and not build:
        sys.exit("defects: cannot read this tree's mxfs.ko srcversion; the rows the record names "
                 "must pass on the build being released, so build the module first")
    mark = {"defect": entry["id"], "disposition": disposition, "date": date.today().isoformat(),
            "why": why[:400]}
    handles, boards, report, refused = [], {}, [], []
    for path, named in by_board.items():
        handles.append(criteria.lock_board(path))
        board = boards[path] = criteria.read_board(path)
        for cell in named:
            row, run = criteria.run_of(board, cell["row"], cell["config"], cell["iso"])
            if run is None:
                report.append("%s:%s:%s has aged off the board; nothing to retire"
                              % (cell["config"], cell["row"], cell["iso"]))
                continue
            run["retired_by"] = mark
            report.append("retired %s:%s:%s" % (cell["config"], cell["row"], cell["iso"]))
        if disposition == "fixed":
            for config, row_id in sorted({(c["config"], c["row"]) for c in named}):
                row = next((e for e in board["criteria"] if e.get("id") == row_id), None)
                status = criteria.cell_status(row, config, build) if row else "UNKNOWN"
                if status != "PASS":
                    window = criteria.runs_of(row or {}, config)[:criteria.FLAKE_WINDOW]
                    left = [r.get("iso", "?") for r in window if criteria.genuine_fail(r)]
                    refused.append("%s at %s reads %s on build %s%s"
                                   % (row_id, config, status, build,
                                      "; genuine FAILs still in its window, which another record "
                                      "or this one must name: " + ", ".join(left) if left else ""))
    if refused:
        sys.exit("defects: not removed, and nothing written. Every row the record names must "
                 "PASS on this tree's build once its own failures are retired:\n  "
                 + "\n  ".join(refused))
    for path, board in boards.items():
        criteria.write_board(path, board)
    del handles
    return report


def cmd_verify(data: dict, args) -> int:
    """A configuration whose rows pass again after a reproducible defect's fix reads PASS again.

    The question a board answers is whether THAT configuration passes. A defect that failed every
    run of a row before its fix and whose row now passes on this tree's build has nothing left to
    say about that configuration, so its named failures there are retired now -- not after the
    flake window ages them out, and whatever the same defect still does elsewhere. An intermittent
    defect is not marked reproducible, so its failures keep counting for the whole window: one
    pass proves nothing about a bug that only shows now and then. The record stays open; `remove`
    is the disposition of the defect itself."""
    entry = find(data, args.id)
    if not str(entry.get("reproducible") or "").strip():
        sys.exit("defects: %s is not marked reproducible (update --reproducible \"how every run of "
                 "the row failed before the fix\"); an intermittent defect's failures count for "
                 "the whole flake window" % entry["id"])
    criteria = board_tool()
    config = criteria.parse_at(args.verify_at)
    named = [c for c in list(entry.get("cells") or []) + list(entry.get("collateral") or [])
             if c["config"] == config]
    if not named:
        sys.exit("defects: %s names no board run at %s (update --cell)" % (entry["id"], config))
    build = tree_build()
    if not build:
        sys.exit("defects: cannot read this tree's mxfs.ko srcversion; build the module first")
    path = criteria.board_for(config)
    handle = criteria.lock_board(path)
    board = criteria.read_board(path)
    mark = {"defect": entry["id"], "disposition": "verified at " + config,
            "date": date.today().isoformat(), "why": entry["reproducible"][:400]}
    retired, refused = [], []
    for row_id in sorted({c["row"] for c in named}):
        row = next((e for e in board["criteria"] if e.get("id") == row_id), None)
        cell = criteria.cell_of(row or {}, config)
        if not row or str(cell.get("status", "")).upper().strip() != "PASS" \
                or (cell.get("build") and cell["build"] != build):
            refused.append("%s at %s: its latest run is %s on build %s, not PASS on %s"
                           % (row_id, config, cell.get("status", "none"),
                              cell.get("build", "?"), build))
            continue
        for c in named:
            if c["row"] != row_id:
                continue
            _, run = criteria.run_of(board, row_id, config, c["iso"])
            if run is not None:
                run["retired_by"] = mark
                retired.append("%s:%s:%s" % (config, row_id, c["iso"]))
    if refused:
        sys.exit("defects: nothing retired at %s:\n  %s" % (config, "\n  ".join(refused)))
    criteria.write_board(path, board)
    del handle
    #: One mark per configuration, naming the build its board passed on: a later build has to
    #: pass there again before the record stops blocking it.
    entry["verified_at"] = [v for v in entry.get("verified_at") or []
                            if isinstance(v, dict) and v.get("config") != config]
    entry["verified_at"].append({"config": config, "build": build,
                                 "date": date.today().isoformat()})
    entry["updated"] = date.today().isoformat()
    save(data)
    print("verified %s at %s on build %s; retired %d run(s):" % (entry["id"], config, build,
                                                                  len(retired)))
    for line in retired:
        print("  " + line)
    for row_id in sorted({c["row"] for c in named}):
        row = next(e for e in board["criteria"] if e.get("id") == row_id)
        print("  %s at %s now reads %s" % (row_id, config, criteria.cell_status(row, config, build)))
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


def cmd_update(data: dict, args) -> int:
    entry = find(data, args.id)
    changed = []
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
    appended = getattr(args, "append_next", None)
    if appended:
        have = entry.get("next") or ""
        entry["next"] = (have + " ===== " if have else "") + appended
        changed.append("next")
    #: The same for evidence: a board cell a record accounts for (configuration, row, verdict,
    #: stamp) is added to what the record already cites, never typed over it.
    appended = getattr(args, "append_evidence", None)
    if appended:
        have = entry.get("evidence") or ""
        entry["evidence"] = (have + " ===== " if have else "") + appended
        changed.append("evidence")
    changed += add_cells(entry, args)
    if args.reproducible:
        entry["reproducible"] = args.reproducible
        changed.append("reproducible")
    if args.reproducer:
        entry["reproducer"] = args.reproducer
        changed.append("reproducer")
    if args.ab:
        entry["ab"] = parse_ab(args.ab)
        changed.append("ab")
    if not changed:
        sys.exit("defects: update needs at least one of -s/-m/-n/-a/-w/-W/-N/-C/-P/-I/"
                 "--cell/--collateral/--reproducer/--ab")
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
        gaps = fixed_gaps(entry)
        if gaps:
            sys.exit("defects: %s cannot be removed as FIXED AND VERIFIED yet:\n  %s"
                     % (entry["id"], "\n  ".join(gaps)))
    #: The board first: it is the step that can refuse, and a record removed from the queue
    #: whose failures were never retired would leave its rows yellow with nothing open to own them.
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
    update.add_argument("-w", "--evidence")
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
    update.add_argument("--reproducer", help="the test that reaches the cause, and how")
    update.add_argument("--reproducible", metavar="EVIDENCE",
                        help="mark it reproducible: how every run of its rows failed before the "
                             "fix. Lets `verify` retire its failures at a configuration that "
                             "passes again")
    update.add_argument("--ab", metavar="'off=F/L on=F/L build=SRCVERSION evidence=PATH'",
                        help="the reproducer's failed/total laps with the fix off and on, on one "
                             "build; FIXED needs every fix-off lap failed and no fix-on lap")

    remove = subs.add_parser("remove", help="it is fixed or it was never real")
    remove.add_argument("id")
    disposition = remove.add_mutually_exclusive_group(required=True)
    disposition.add_argument("--fixed", action="store_true",
                             help="FIXED AND VERIFIED: needs --reproducer and an --ab whose fix-off "
                                  "arm failed every lap, and every named row passing on this build")
    disposition.add_argument("--disproved", action="store_true",
                             help="DISPROVED: direct evidence that it was not an MXFS defect")
    remove.add_argument("--why", required=True,
                        help="what was measured and what it said")

    verify = subs.add_parser("verify", help="a reproducible defect's rows pass again at one "
                                            "configuration: retire its failures there")
    verify.add_argument("id")
    verify.add_argument("--at", dest="verify_at", metavar="CONFIGURATION", required=True,
                        help="the configuration whose board passes again, e.g. 4/net/mesh/direct")

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
                    "reproducer", "ab", "fixed", "disproved", "reproducible"):
        if not hasattr(args, missing):
            setattr(args, missing, None)
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
    if args.command == "rename":
        return cmd_rename(data, args)
    if args.command == "verify":
        return cmd_verify(data, args)
    if args.command == "migrate-config":
        return cmd_migrate_config(data, args)
    return cmd_list(data, args)


if __name__ == "__main__":
    sys.exit(main())
