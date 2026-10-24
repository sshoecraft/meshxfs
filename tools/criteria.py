#!/usr/bin/env python3
"""The board: what MXFS MUST ACHIEVE, and whether it does yet.

    tools/criteria.py                     the board, every configuration
    tools/criteria.py 2/net/mesh/direct   the board for ONE configuration (also --at)
    tools/criteria.py 2/net/mesh/direct --candidate 0.90.133-1   graded for one release candidate
    tools/criteria.py -v                  add each criterion's requirement and why
    tools/criteria.py show <id>           one criterion in full: every configuration, every run
    tools/criteria.py --gaps              criteria nothing can measure -- wishes, not criteria
    tools/criteria.py incidents [--at C]  every FAIL or INCOMPLETE nothing accounts for (exit 1)
    tools/criteria.py rates [--at C]      each row's recorded failure rate, for scheduling only
    tools/criteria.py add    -i ID -r "requirement" -d "detector" [-b BUDGET_S] [-p PHASE]
    tools/criteria.py update <id> --at 2/net/mesh/direct -s PASS -m "measured" --build SRCVER [-e ELAPSED_S]
    tools/criteria.py amend  <id> --at C --iso <stamp> --detector-defect "..." --approval <proposal>
    tools/criteria.py infra  <id> --at C --iso <stamp> --why "..." --approval <proposal>
    tools/criteria.py unretire <id> --at C --iso <stamp> --why "the fix did not hold"
    tools/criteria.py migrate-ledger [--dry-run]   one time: seed a board's run ledger
    tools/criteria.py remove <id> --why "why this is no longer something we must achieve"

EVERY RUN IS KEPT, AND NOTHING AGES OUT. Each recorded run is appended to the board's run ledger
(`<board>.runs.jsonl` beside the board file) and never rewritten or dropped. Annotations -- a
verified fix retiring a run, a reviewed detector-defect or infra finding, the withdrawal of
either -- are appended as separate events next to it. The board file keeps each cell's latest
result and a short history for display only; every verdict is computed from the ledger. Until
2026-10-21 a failure stopped counting once eleven newer runs of its row existed, and passing laps
were run on purpose to push failures out of that window. A failure that passes cannot account
for is a defect, however many passes follow it (docs/release-process.md).

A RUN SAYS ONE OF SEVEN THINGS (`OUTCOMES`): PASS; FAIL (the test detected a fault, or the
filesystem hung or stalled past the policy's limit); INFRA (the harness proved, with positive
evidence, that the rig and not MXFS failed); INCOMPLETE (the run measured nothing and nobody yet
knows why -- it may have been a wedge); UNREACHED (the run never got to the row); SKIP (the row
does not apply); CONTROL (a declared negative control). The harness says which, where it knows;
a status this board does not recognise is recorded as FAIL with its text, never refused.

A ROW IS GRADED ON THE CANDIDATE BEING RELEASED. With `--candidate C` a cell reads PASS only when
the runs on C hold no FAIL (unless only open `noblock` records name it), no unresolved INCOMPLETE,
and at least the policy's required number of PASSes. Runs on any other candidate or build never
grade C -- but their failures stay incidents until a defect record names them or a reviewed
disposition retires them (`incidents`). Without a candidate the board grades by build: the one
named with `--build`, or the build of the row's newest run.

THE ONE WAY IN OR OUT. This file is the only reader and the only writer of `data/criteria.json`
and of every board's run ledger. tools/defects.py appends annotations through `append_ledger`
under the board's own lock.

CRITERIA AND DEFECTS ARE DIFFERENT LISTS AND MUST STAY APART. A criterion is the SPECIFICATION --
permanent, and it can regress. A defect is transient and leaves the queue when it is fixed
(`tools/defects.py`). Ask the queue what blocks a release -- `tools/defects.py 2/net/mesh/direct`
-- and ask this board whether the requirements are met. `remove` here is for a criterion that is
no longer something we must achieve, NOT for one that now passes.

THE SPECIFICATION LIVES IN ONE FILE. data/criteria.json holds every row's requirement, detector,
budget, dispatch class and node range. A board kept elsewhere (`MXFS_CRIT`: the DRBD rig, the
physical Proxmox pair, a scratch A/B board) receives results only; its rows and budgets are read
from data/criteria.json, so a copy made months ago can neither drift nor be edited mid-run. While
a release candidate is being qualified, nothing that changes the specification is allowed.

EVERY CRITERION IS PROVED ONE CONFIGURATION AT A TIME. A green on 32/disk/caw/mpath says nothing
about 2/net/mesh/direct. Every cell is per configuration, and a criterion is UNKNOWN for every
configuration it was never run on.

EVERY CRITERION CARRIES A TIME BUDGET, AND OVERRUNNING IT IS A FAILURE. A timeout is not a flaky
run and a slow pass is not a pass: `update` records FAIL when the elapsed time exceeds the budget,
and when the row reports an operation stall longer than the policy's `stall_limit_s`, whatever
status the caller passed and even with zero errors.

EVERY CRITERION MUST HAVE A DETECTOR, AND NAMING ONE IS NOT HAVING ONE. `add` refuses without
one, and `--gaps` reports detectors that name a file that is not there.
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
from datetime import date, datetime, timezone
from pathlib import Path

#: `criteria.py | head` closes the pipe under us, and python turns that into a traceback on stderr
#: plus a non-zero exit. Restoring the default disposition makes it exit quietly, the way every
#: other command in a pipeline does.
try:
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
except (AttributeError, ValueError):
    pass

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import configuration  # noqa: E402  (tools/configuration.py: the only parser of a configuration)

#: The specification: every row's requirement, detector, budget and dispatch class.
#: `MXFS_SPEC` names a copy, for replaying recorded boards (tests/release_gate/replay.sh) without
#: touching the live one; nothing on the rig sets it.
SPEC = Path(os.environ["MXFS_SPEC"]) if os.environ.get("MXFS_SPEC") else ROOT / "data" / "criteria.json"
#: `MXFS_CRIT` points at a different board file, so a second rig's results can be kept off the
#: primary board without a second copy of this tool.
CRITERIA = Path(os.environ["MXFS_CRIT"]) if os.environ.get("MXFS_CRIT") else SPEC
#: tools/release_run.py writes every release step's run (row `release:<step>`) into the primary
#: board's ledger, whatever configuration it files it under, so a command naming one reads and
#: writes the primary board. Each part of that fix has a switch of its own, so the control of one
#: part reaches the code it is about instead of stopping at another part's refusal:
#: `MXFS_RELEASE_STEP_SETTLE=0` parses a step's run as any other (tools/defects.py parse_cell);
#: `MXFS_RELEASE_STEP_ANNOTATE=0` looks a step's row up as a board criterion (annotated_run);
#: `MXFS_RELEASE_STEP_BOARD=0` gives a command that names a step's run its configuration's board
#: (the board choice below); `MXFS_RELEASE_STEP_ROUTE=0` looks a named run up and retires it on its
#: configuration's board (run_board). Each is that part as before the fix: its control.
RELEASE_STEP_SETTLE = os.environ.get("MXFS_RELEASE_STEP_SETTLE", "1") != "0"
RELEASE_STEP_ANNOTATE = os.environ.get("MXFS_RELEASE_STEP_ANNOTATE", "1") != "0"
RELEASE_STEP_BOARD = os.environ.get("MXFS_RELEASE_STEP_BOARD", "1") != "0"
RELEASE_STEP_ROUTE = os.environ.get("MXFS_RELEASE_STEP_ROUTE", "1") != "0"
#: `incidents --at 1/any` narrows the listing to the placeholder configuration most release steps'
#: runs are filed under, which parse_at refuses (it is no configuration of MXFS);
#: `MXFS_RELEASE_STEP_LIST=0` hands it to parse_at, as before: the control.
RELEASE_STEP_LIST = os.environ.get("MXFS_RELEASE_STEP_LIST", "1") != "0"
#: A batch lap's run (row `lap:<name>`, tools/batch_lap.py) also exists only in a ledger, and
#: tools/defects.py verify writes a retirement on it like any other cell, so an annotation names it
#: by its row as it names a release step's (annotated_run). `MXFS_LAP_ANNOTATE=0` looks a lap's row
#: up as a board criterion, as before: the control.
LAP_ANNOTATE = os.environ.get("MXFS_LAP_ANNOTATE", "1") != "0"
#: An attachment verified by a rig of its own (data/configurations.json attaches.<a>.board, e.g.
#: drbd) keeps its board there; naming such a configuration reads and writes that board, as its
#: rig does, so `criteria.py 2/net/mesh/drbd` needs no environment. A command that names a release
#: step's run keeps the primary board: the drbd step's run, filed under 2/net/mesh/drbd, is there.
if not os.environ.get("MXFS_CRIT"):
    step_run = RELEASE_STEP_BOARD and any(re.fullmatch(r"release:\S+", arg)
                                          for arg in sys.argv[1:])
    for board_arg in sys.argv[1:]:
        board_match = re.match(r"^\d+/[a-z]+/[a-z]+/([a-z]+)$", board_arg)
        board_path = board_match and configuration.ATTACHES.get(board_match.group(1), {}).get("board")
        if board_path:
            os.environ.setdefault("MXFS_OWN_RIG", "1")
            if not step_run:
                CRITERIA = ROOT / board_path
            break

POLICY = ROOT / "data" / "release_policy.json"
CANDIDATES = ROOT / "data" / "candidates"

#: Held across the whole read-modify-write of every mutating subcommand. Rig groups run several
#: boards at once, each run.sh writing its own column into this one file, and the board is
#: rewritten whole: without the lock two writers read the same snapshot and the later save drops
#: the earlier one's cell. One lock per board file, so an alternate board (`MXFS_CRIT`) does not
#: wait on the primary. The board's run ledger is appended under the same lock.
LOCK = CRITERIA.with_name("." + CRITERIA.name + ".lock")
MUTATORS = ("add", "update", "amend", "unamend", "unretire", "infra", "remove", "move", "pending",
            "executing", "finalize", "migrate-keys", "migrate-ledger")

#: A save of the board takes milliseconds, so a holder still there after this long is wedged
#: rather than busy, and saying so beats blocking a run forever.
LOCK_WAIT_SECONDS = 30

#: The open lock file, kept for the process's lifetime so the lock is held until it exits.
lock_handle = None


def lock_board(path: Path):
    """Hold an exclusive lock on one board file from its read to its write, or say who is
    holding it. Returns the open handle: the lock lasts as long as the handle does."""
    lock = path.with_name("." + path.name + ".lock")
    lock.parent.mkdir(parents=True, exist_ok=True)
    handle = lock.open("w")
    deadline = time.monotonic() + LOCK_WAIT_SECONDS
    announced = False
    while True:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return handle
        except OSError:
            if time.monotonic() >= deadline:
                sys.exit("criteria: %s has been held by another criteria.py for %ds. That is far "
                         "longer than a write takes, so it is wedged rather than busy: find the "
                         "holder before retrying." % (lock, LOCK_WAIT_SECONDS))
            if not announced:
                print("criteria: waiting for another criteria.py to finish writing the board…",
                      file=sys.stderr)
                announced = True
            time.sleep(0.05)


def take_lock() -> None:
    """Hold an exclusive lock from `load` to `save`, or say who is holding it."""
    global lock_handle
    lock_handle = lock_board(CRITERIA)


def board_for(config: str) -> Path:
    """The board file a configuration's cells live in: `MXFS_CRIT` when set, the board of an
    attachment verified by a rig of its own (drbd), or data/criteria.json -- the same choice the
    command line makes when it is given that configuration."""
    if os.environ.get("MXFS_CRIT"):
        return Path(os.environ["MXFS_CRIT"])
    match = re.match(r"^\d+/[a-z]+/[a-z]+/([a-z]+)$", config)
    own = match and configuration.ATTACHES.get(match.group(1), {}).get("board")
    return ROOT / own if own else SPEC


def run_board(config: str, row: str) -> Path:
    """The board whose run ledger holds one run: the primary for a release step's (row
    `release:<step>`, which tools/release_run.py writes there whatever configuration it files the
    run under), the configuration's board (board_for) for any other. Every lookup of a named run
    (tools/defects.py check_cells, drop_cells, unsettled, retire_cells) goes through here."""
    if RELEASE_STEP_ROUTE and str(row).startswith("release:"):
        return SPEC
    return board_for(config)


#: A status this board does not recognise is NOT green. An unknown string paints as a warning and
#: never as a pass; `update` records it as FAIL with its text.
MARK = {
    "PASS": "32",
    "FAIL": "1;31",
    "BLOCKED": "1;31",
    "ABORTED": "1;31",
    "INCOMPLETE": "1;31",
    "INFRA": "33",
    "SKIP": "33",
    "NOT RUN": "33",
    "NOT STARTED": "33",
    "UNKNOWN": "33",
    "STALE": "33",
    "PARTIAL": "33",
    #: A LIVE-RUN STATE ONLY. A cell must never still be PENDING when no run is executing: a run
    #: that started a test and then died did not produce a result, and `finalize` converts every
    #: marker it left into ABORTED (was in flight) or NOT RUN (never reached).
    "PENDING": "1;36",
}
STATUSES = tuple(MARK)

#: How many previous verdicts a cell keeps for DISPLAY. Nothing is graded on this history; the
#: run ledger holds every run.
HISTORY_DEPTH = 10

GREEN = ("PASS",)

#: What one recorded run says. See the module docstring.
OUTCOMES = ("PASS", "FAIL", "INFRA", "INCOMPLETE", "UNREACHED", "SKIP", "CONTROL")


def outcome_of(status, reason="") -> str | None:
    """The outcome a status means when the harness did not name one.

    This is also how every run recorded before 2026-10-21 is read. Then a FAIL whose reason
    matched a "rig noise" pattern was excluded from every count -- including a pre-assert, which a
    mount whose `ls` hangs or returns EIO also produces. Such a run is INCOMPLETE now: it measured
    nothing, and it stays an incident until a reviewed disposition says why. Only the two setup
    checks that prove a missing instrument before anything is measured read as INFRA.
    """
    status = str(status or "").upper().strip().replace("_", " ")
    reason = str(reason or "")
    low = reason.lower()
    if status == "PASS":
        return "PASS"
    if status in ("SKIP", "INFRA", "CONTROL"):
        return status
    if status in ("NOT RUN", "NOT STARTED"):
        return "UNREACHED"
    if status in ("PENDING", "UNKNOWN", "STALE", "PARTIAL", ""):
        return None
    if status in ("ABORTED", "INCOMPLETE"):
        return "INCOMPLETE"
    if status == "BLOCKED":
        if "{MXFS}" in reason:
            return "FAIL"
        if "did not reconverge" in reason:
            return "UNREACHED"
        if "{EXT4-ROOTDISK}" in reason and "{other}" not in reason:
            return "INFRA"
        return "INCOMPLETE"
    if status == "FAIL":
        if reason.startswith("not run:"):
            return "UNREACHED"
        if "chk tool missing" in low or "fua_verify missing" in low:
            return "INFRA"
        if "pre-assert" in low or reason.startswith("prep failed"):
            return "INCOMPLETE"
        return "FAIL"
    return "FAIL"


policy_cache = None


def policy() -> dict:
    """data/release_policy.json: the owner's numbers. A missing or unreadable file stops every
    command that needs it -- a gate with no thresholds would pass everything."""
    global policy_cache
    if policy_cache is None:
        try:
            policy_cache = json.loads(POLICY.read_text())
        except (OSError, ValueError) as exc:
            sys.exit(f"criteria: cannot read {POLICY}: {exc}")
    return policy_cache


def required_runs(row: str, config: str) -> int:
    """How many PASSes on one candidate a row needs at a configuration (the policy's
    `required_runs`: a default, then per-row, then per-configuration-and-row)."""
    spec = policy().get("required_runs") or {}
    need = int(spec.get("default", 1) or 1)
    need = int((spec.get("rows") or {}).get(row, need))
    need = int(((spec.get("configs") or {}).get(config) or {}).get(row, need))
    return max(need, 1)


def active_candidate() -> dict:
    """The release candidate being qualified (data/candidates/active.json), or {}."""
    try:
        return json.loads((CANDIDATES / "active.json").read_text())
    except (OSError, ValueError):
        return {}


def refuse_while_qualifying(what: str) -> None:
    """A change to what the rig runs, while a candidate is being qualified, would make the rows
    of one candidate measure different things. tools/release_run.py would mark it INVALID; this
    refuses it at the source."""
    active = active_candidate()
    if active.get("state") == "RUNNING":
        sys.exit("criteria: %s changes the specification, and candidate %s is being qualified. "
                 "Wait until it ends, or abandon it (tools/release_candidate.py abandon)."
                 % (what, active.get("candidate", "?")))


#: Every configuration MXFS has an implementation for, at every laddered node count. A criterion
#: proved on 32/disk/caw/mpath says nothing about 2/net/mesh/direct, so a criterion is UNKNOWN for
#: every configuration absent from its `per_config` map -- which is the only way an unmeasured
#: column can stay visible instead of reading as green. `1/xfs` is the native-XFS baseline the 2x
#: performance ceiling is measured against.
CONFIGS = configuration.board_configurations()

#: For `lift_config` only: what a leading bare configuration must not be mistaken for.
SUBCOMMANDS = ("show", "add", "update", "remove", "amend", "unamend", "unretire", "infra", "move",
               "pending", "executing", "finalize", "rows", "migrate-keys", "migrate-ledger",
               "incidents", "rates")
VALUE_FLAGS = ("--at", "--build", "--candidate")


def flat(value, width: int | None = None) -> str:
    text = " ".join(str(value).split())
    return text[:width - 1] + "…" if width and len(text) > width else text


def wrap(text, width: int, indent: str) -> str:
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


class Paint:
    def __init__(self, on: bool):
        self.on = on

    def __call__(self, text, code) -> str:
        return f"\033[{code}m{text}\033[0m" if self.on else str(text)


def status_of(entry: dict) -> str:
    return str(entry.get("status", "UNKNOWN")).upper().strip()


def parse_at(text: str) -> str:
    """`2/net/mesh/direct` -- one complete configuration, normalised.

    A column is one exact key, so unlike the defect queue this needs every field: `2` alone
    names a dozen columns, and picking one of them silently is how a TCP green gets read as a
    CAW one.
    """
    try:
        return configuration.parse(text).key
    except configuration.ConfigurationError as exc:
        match = re.fullmatch(r"\s*(\d+)\s*", str(text))
        if match:
            here = [c for c in CONFIGS if c.startswith("%s/" % int(match.group(1)))]
            sys.exit("criteria: name the whole configuration — a cell is one exact column. "
                     "At %s nodes: %s" % (match.group(1), ", ".join(here) if here else "none declared"))
        sys.exit(f"criteria: {exc}")


def lift_config(argv: list) -> list:
    """Accept `criteria.py 2/net/mesh/direct` as `--at 2/net/mesh/direct`.

    The leading argument is a configuration only when it starts with digits, so it can never
    shadow `show`, `add`, `update` or `remove`. The old two-token `criteria.py 2 tcp` is refused
    by name rather than half-parsed.
    """
    rest, skip = list(argv[1:]), False
    for index, token in enumerate(rest):
        if skip:
            skip = False
            continue
        if token in SUBCOMMANDS:
            break
        if token.startswith("-"):
            #: A flag that takes a value would otherwise have its value read as a node count.
            skip = token in VALUE_FLAGS
            continue
        #: a field after the node count starts with a letter or `*` and may carry digits after
        #: it: the 4K-native attachment is `direct4k`
        if not re.fullmatch(r"\d+(?:/[A-Za-z*][A-Za-z0-9*]*)*", token):
            break
        if index + 1 < len(rest) and re.fullmatch(r"[A-Za-z]+", rest[index + 1]) \
                and rest[index + 1] not in SUBCOMMANDS:
            hint = configuration.retired_hint("%s/%s" % (token, rest[index + 1]))
            sys.exit("criteria: give the configuration as one key, e.g. %s/net/mesh/direct%s"
                     % (token, "; " + hint if hint else ""))
        return argv[:1] + rest[:index] + ["--at", token] + rest[index + 1:]
    return argv


def read_board(path: Path) -> dict:
    if not path.is_file():
        return {"criteria": []}
    try:
        with path.open() as handle:
            data = json.load(handle)
    except ValueError as exc:
        raise SystemExit(f"criteria: {path} is not valid JSON: {exc}")
    data.setdefault("criteria", [])
    return data


def write_board(path: Path, data: dict) -> None:
    """Atomically, because a half-written board is worse than a stale one."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.tmp")
    with temporary.open("w") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    os.replace(temporary, path)


def load() -> dict:
    return read_board(CRITERIA)


def save(data: dict) -> None:
    write_board(CRITERIA, data)


def find(data: dict, wanted: str) -> dict:
    wanted = wanted.strip()
    for entry in data["criteria"]:
        if str(entry.get("id", "")) == wanted:
            return entry
    low = wanted.lower()
    hits = [e for e in data["criteria"] if low in str(e.get("id", "")).lower()]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        sys.exit(f"criteria: nothing matches {wanted!r}")
    sys.exit("criteria: %r matches %d:\n  %s"
             % (wanted, len(hits), "\n  ".join(str(e["id"]) for e in hits)))


spec_cache = None


def spec_rows() -> list:
    """Every row of the specification, in dispatch order."""
    global spec_cache
    if spec_cache is None:
        spec_cache = read_board(SPEC)["criteria"]
    return spec_cache


def spec_of(entry: dict) -> dict:
    """The specification's own copy of a row, whatever board `entry` came from."""
    for spec in spec_rows():
        if spec.get("id") == entry.get("id"):
            return spec
    return entry


def find_or_adopt(data: dict, wanted: str) -> dict:
    """A row of the board being written. A results board (`MXFS_CRIT`) that has never seen a row
    the specification gained since it was copied takes that row on first use."""
    wanted = wanted.strip()
    for entry in data["criteria"]:
        if str(entry.get("id", "")) == wanted:
            return entry
    if CRITERIA.resolve() != SPEC.resolve():
        for spec in spec_rows():
            if spec.get("id") == wanted:
                adopted = {k: v for k, v in spec.items() if k != "per_config"}
                adopted["per_config"] = {}
                data["criteria"].append(adopted)
                return adopted
    return find(data, wanted)


def cell_of(entry: dict, config: str) -> dict:
    return (entry.get("per_config") or {}).get(config) or {}


def runs_of(entry: dict, config: str) -> list:
    """The live cell and its display history, newest first. For display only: verdicts come from
    the run ledger (`ledger_runs`)."""
    cell = cell_of(entry, config)
    return [cell] + list(cell.get("history") or []) if cell else []


def run_of(data: dict, row: str, config: str, iso: str) -> tuple:
    """(criterion, cell-or-history run) stamped `iso`, for display. The ledger's own record of a
    run is `ledger_run`."""
    entry = next((e for e in data["criteria"] if str(e.get("id", "")) == row), None)
    if entry is None:
        return None, None
    hit = [r for r in runs_of(entry, config) if str(r.get("iso", "")) == iso]
    return entry, (hit[0] if hit else None)


def budget_of(entry: dict):
    """The row's budget: the specification's, or the one a rig whose hardware the board's budgets
    were not derived on names for itself (run.sh reads the same file): "<row> <seconds>
    <derivation>" lines in MXFS_RIG_BUDGETS, each native XFS on that hardware x2. A run under
    MXFS_RIG_BUDGETS is a variant (run.sh): it never grades a release candidate."""
    budget = spec_of(entry).get("budget_s")
    rig_budgets = os.environ.get("MXFS_RIG_BUDGETS", "")
    if rig_budgets and os.path.isfile(rig_budgets):
        with open(rig_budgets) as handle:
            for line in handle:
                fields = line.split()
                if (len(fields) >= 2 and not fields[0].startswith("#")
                        and fields[0] == entry.get("id") and fields[1].isdigit()):
                    budget = int(fields[1])
    return budget


def stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------------------------
# THE RUN LEDGER
#
# One JSON object per line, appended and never rewritten: `{"kind": "run", ...}` for a recorded
# run, `{"kind": "note", ...}` for an annotation of one (`retired_by`, `detector_defect`,
# `infra_proven`, and `withdrawn` taking one of those back). A run is keyed by
# (configuration, row, iso) -- the key tools/defects.py names runs by.
# ---------------------------------------------------------------------------------------------

def ledger_path(board: Path) -> Path:
    return board.with_name(board.stem + ".runs.jsonl")


class Ledger:
    def __init__(self):
        self.runs = {}     # (config, row) -> [run, ...] newest first
        self.notes = {}    # (config, row, iso) -> [note, ...] oldest first


ledger_cache: dict = {}


def read_ledger(board: Path | None = None) -> Ledger:
    """The board's ledger, read once per process. A line that does not parse is a torn last line
    from a writer that died mid-append; it is skipped, never repaired."""
    board = Path(board or CRITERIA)
    key = str(board.resolve())
    if key in ledger_cache:
        return ledger_cache[key]
    ledger = Ledger()
    path = ledger_path(board)
    try:
        lines = path.read_text().splitlines()
    except FileNotFoundError:
        lines = []
    for line in lines:
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if item.get("kind") == "run":
            ledger.runs.setdefault((item.get("config"), item.get("row")), []).append(item)
        elif item.get("kind") == "note":
            ledger.notes.setdefault((item.get("config"), item.get("row"), item.get("iso")),
                                    []).append(item)
    for runs in ledger.runs.values():
        runs.reverse()
        runs.sort(key=lambda r: str(r.get("iso", "")), reverse=True)
    ledger_cache[key] = ledger
    return ledger


def append_ledger(board: Path, items: list) -> None:
    """Append runs or notes to a board's ledger. The caller holds the board's lock; the append is
    flushed to disk before the caller rewrites the board, so a board write can never get ahead of
    the ledger."""
    if not items:
        return
    path = ledger_path(Path(board))
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        for item in items:
            handle.write(json.dumps(item, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    ledger_cache.pop(str(Path(board).resolve()), None)


def ledger_runs(board: Path | None, config: str, row: str) -> list:
    return read_ledger(board).runs.get((config, row), [])


def ledger_run(board: Path | None, config: str, row: str, iso: str) -> dict | None:
    for run in ledger_runs(board, config, row):
        if str(run.get("iso", "")) == iso:
            return run
    return None


def annotations(board: Path | None, config: str, row: str, iso: str) -> dict:
    """The annotations standing on one run: name -> value, after withdrawals."""
    standing = {}
    for note in read_ledger(board).notes.get((config, row, iso), []):
        name = note.get("note")
        if name == "withdrawn":
            standing.pop((note.get("value") or {}).get("of"), None)
        elif name:
            standing[name] = note.get("value") or {}
    return standing


def note(config: str, row: str, iso: str, name: str, value: dict) -> dict:
    return {"kind": "note", "config": config, "row": row, "iso": iso, "note": name,
            "value": value, "date": date.today().isoformat()}


def run_record(config: str, row: str, cell: dict, outcome: str) -> dict:
    """The ledger line for the run a cell now holds."""
    item = {"kind": "run", "config": config, "row": row, "outcome": outcome}
    for key in ("iso", "status", "raw_status", "measured", "reason", "elapsed_s", "budget_s",
                "build", "run_id", "candidate", "batch", "variant", "evidence", "seed",
                "platform", "kernel"):
        if cell.get(key) not in (None, ""):
            item[key] = cell[key]
    item.setdefault("build", None)
    return item


def push_history(cell: dict) -> None:
    """Move the outgoing verdict onto the cell's bounded display history before it is overwritten.
    A PENDING marker is not a verdict and is never pushed."""
    previous = str(cell.get("status", "")).upper().strip()
    if previous in ("", "PENDING"):
        return
    outgoing = {
        "status": cell.get("status"),
        "iso": cell.get("iso") or cell.get("recorded") or "",
        "measured": cell.get("measured", ""),
        "reason": str(cell.get("reason") or "")[:400],
    }
    for key in ("build", "outcome", "candidate", "run_id", "batch", "variant", "evidence",
                "detector_defect", "amendment_withdrawn", "retired_by", "retirement_withdrawn"):
        if cell.get(key):
            outgoing[key] = cell[key]
    cell["history"] = ([outgoing] + list(cell.get("history") or []))[:HISTORY_DEPTH]


def write_cell(entry: dict, config: str, status: str, measured: str = "",
               reason: str = "", elapsed_s=None, build: str = "", **extra) -> dict:
    """Replace one configuration's cell, preserving its display history."""
    cell = entry.setdefault("per_config", {}).setdefault(config, {})
    push_history(cell)
    history = cell.get("history") or []
    cell.clear()
    cell["status"] = status
    cell["measured"] = measured
    cell["reason"] = reason
    cell["iso"] = extra.pop("iso", None) or stamp()
    cell["recorded"] = date.today().isoformat()
    if elapsed_s is not None:
        cell["elapsed_s"] = elapsed_s
    if build:
        cell["build"] = build
    for key, value in extra.items():
        if value not in (None, ""):
            cell[key] = value
    if history:
        cell["history"] = history
    return cell


def fresh_iso(entry: dict, config: str, board: Path | None = None) -> str:
    """A stamp no run of this row at this configuration already carries: two writes inside one
    second would otherwise share a key."""
    taken = {str(r.get("iso", "")) for r in ledger_runs(board, config, entry.get("id"))}
    taken.add(str(cell_of(entry, config).get("iso", "")))
    iso = stamp()
    while iso in taken:
        time.sleep(0.2)
        iso = stamp()
    return iso


# ---------------------------------------------------------------------------------------------
# WHAT ACCOUNTS FOR A FAILURE
# ---------------------------------------------------------------------------------------------

named_cache = None


def named_runs() -> dict:
    """(configuration, row, iso) -> the open defect records that name that run (`cells` and
    `collateral` in tools/defects.py's queue)."""
    global named_cache
    if named_cache is None:
        import defects  # noqa: E402  (imported here: only verdicts need the queue)
        named_cache = {}
        for record in defects.load()["defects"]:
            for cell in list(record.get("cells") or []) + list(record.get("collateral") or []):
                key = (cell.get("config"), cell.get("row"), cell.get("iso"))
                named_cache.setdefault(key, []).append(record["id"])
    return named_cache


impact_cache = None


def record_impacts() -> dict:
    """Open record id -> its release-bar impact (`noblock` is the only one that clears)."""
    global impact_cache
    if impact_cache is None:
        import defects  # noqa: E402
        impact_cache = {r["id"]: str(r.get("impact") or "").lower()
                        for r in defects.load()["defects"]}
    return impact_cache


def settled(board: Path | None, config: str, row: str, iso: str) -> str:
    """The annotation that settles a run, or "": retired by a verified fix or a disproof, a
    reviewed detector-defect or infra finding, or a dry run's seal, which refuses by construction
    because a dry run is never published (owner, 2026-10-22, data/release_policy.json)."""
    standing = annotations(board, config, row, iso)
    for name in ("retired_by", "detector_defect", "infra_proven", "dry_run_seal"):
        if name in standing:
            return name
    return ""


# ---------------------------------------------------------------------------------------------
# GRADING
# ---------------------------------------------------------------------------------------------

attempt_cache: dict = {}


def attempt_began(candidate: str) -> str:
    """When the candidate's current attempt was frozen (its manifest's `created`): a candidate is
    its version, and an earlier attempt at the same version left runs under the same name that
    must not grade this one. "" when there is no manifest."""
    if candidate not in attempt_cache:
        try:
            attempt_cache[candidate] = str(json.loads(
                (CANDIDATES / f"{candidate}.json").read_text()).get("created") or "")
        except (OSError, ValueError):
            attempt_cache[candidate] = ""
    return attempt_cache[candidate]


def context_runs(runs: list, build: str, candidate: str) -> list:
    """The runs that grade the candidate (or build) being asked about. A variant run (a module
    knob, a test environment, a calibration, a rig's own budgets) never grades anything."""
    plain = [r for r in runs if not r.get("variant") and r.get("outcome")]
    if candidate:
        began = attempt_began(candidate)
        return [r for r in plain if r.get("candidate") == candidate
                and str(r.get("iso", "")) >= began]
    ref = build or (runs[0].get("build") or "" if runs else "")
    return [r for r in plain if (r.get("build") or "") == ref]


def grade(entry: dict, config: str, build: str = "", candidate: str = "",
          board: Path | None = None) -> dict:
    """One configuration's verdict for one row: `mark` (what the board shows), the latest run,
    the open records blocking it, the noblock records it carries, and the unresolved runs."""
    board = Path(board or CRITERIA)
    row = entry.get("id")
    result = {"mark": "UNKNOWN", "latest": None, "blockers": [], "noblock": [],
              "unnamed": [], "unresolved": [], "passes": 0, "need": required_runs(row, config)}
    cell = cell_of(entry, config)
    runs = ledger_runs(board, config, row)
    result["latest"] = runs[0] if runs else None
    if str(cell.get("status", "")).upper().strip() == "PENDING":
        result["mark"] = "PENDING"
        return result
    if not runs:
        return result
    ctx = context_runs(runs, build, candidate)
    if not ctx:
        result["mark"] = "STALE" if any(r.get("outcome") == "PASS" for r in runs) else "UNKNOWN"
        return result
    named, impact = named_runs(), record_impacts()
    fails, skips, infra = False, 0, 0
    for run in ctx:
        iso = str(run.get("iso", ""))
        outcome = run.get("outcome")
        if outcome == "PASS":
            result["passes"] += 1
        elif outcome == "FAIL":
            if settled(board, config, row, iso):
                continue
            ids = named.get((config, row, iso), [])
            blocking = [i for i in ids if impact.get(i) != "noblock"]
            if ids and not blocking:
                result["noblock"] += [i for i in ids if i not in result["noblock"]]
                continue
            fails = True
            if blocking:
                result["blockers"] += [i for i in blocking if i not in result["blockers"]]
            else:
                result["unnamed"].append(run)
        elif outcome in ("INCOMPLETE", "INFRA"):
            # INFRA is the harness's own claim that the rig failed first; like a run that
            # measured nothing, it stays unresolved until a record names it or a reviewed
            # infra-proven disposition settles it, so it can never stand beside a PASS unseen
            if settled(board, config, row, iso) or named.get((config, row, iso)):
                continue
            result["unresolved"].append(run)
            infra += outcome == "INFRA"
        elif outcome == "SKIP":
            skips += 1
    if fails:
        result["mark"] = "FAIL"
    elif result["unresolved"]:
        result["mark"] = "INFRA" if infra == len(result["unresolved"]) else "INCOMPLETE"
    elif result["passes"] >= result["need"]:
        result["mark"] = "PASS"
    elif result["passes"]:
        result["mark"] = "PARTIAL"
    elif skips:
        result["mark"] = "SKIP"
    else:
        result["mark"] = "NOT RUN"
    return result


def cell_status(entry: dict, config: str, build: str = "", candidate: str = "",
                board: Path | None = None) -> str:
    return grade(entry, config, build, candidate, board)["mark"]


def roll_up(entry: dict, build: str = "", candidate: str = "") -> str:
    """PASS only when every declared configuration has one. Anything else is PARTIAL at best."""
    marks = [cell_status(entry, config, build, candidate)
             for config in CONFIGS if applies(entry, config)]
    if not marks:
        return "UNKNOWN"
    if all(mark in GREEN for mark in marks):
        return "PASS"
    if any(mark in ("FAIL", "BLOCKED", "ABORTED", "INCOMPLETE", "INFRA") for mark in marks):
        return "FAIL"
    if any(mark in GREEN for mark in marks):
        return "PARTIAL"
    return "UNKNOWN"


def applies(entry: dict, config: str) -> bool:
    """Is this criterion even runnable in that configuration? Read from the specification, so a
    results board's stale copy of a row cannot change the answer.

    A key that does not parse applies to NOTHING. `applies_to` is a pattern over
    class/method/attach (`any`, `disk/caw`, `net/mesh`).
    """
    spec = spec_of(entry)
    try:
        parsed = configuration.parse(config)
    except configuration.ConfigurationError:
        return False
    nodes = parsed.nodes
    if not configuration.matches(spec.get("applies_to") or "any", parsed):
        return False
    if nodes < int(spec.get("min_nodes", 1) or 1):
        return False
    top = int(spec.get("max_nodes", 0) or 0)
    return top == 0 or nodes <= top


def verdict_note(verdict: dict) -> str:
    """What stands behind a mark, for the MEASURED column."""
    if verdict["mark"] == "FAIL":
        parts = []
        if verdict["blockers"]:
            parts.append("blocked by " + ", ".join(verdict["blockers"]))
        for run in verdict["unnamed"][:1]:
            parts.append("UNNAMED FAIL %s %s" % (run.get("iso", "?"),
                                                 flat(run.get("reason") or run.get("measured")
                                                      or "", 90)))
        return "; ".join(parts)
    if verdict["mark"] == "INCOMPLETE":
        run = verdict["unresolved"][0]
        return "unresolved %s %s %s" % (run.get("status", "?"), run.get("iso", "?"),
                                        flat(run.get("reason") or "", 90))
    if verdict["mark"] == "PARTIAL":
        return "%d of %d required passes" % (verdict["passes"], verdict["need"])
    if verdict["noblock"]:
        return "[noblock: %s]" % ", ".join(verdict["noblock"])
    return ""


def latest_label(verdict: dict, build: str, candidate: str) -> str:
    run = verdict["latest"]
    if not run:
        return "—"
    label = str(run.get("outcome") or run.get("status") or "?")
    other = (candidate and (run.get("candidate") != candidate
                            or str(run.get("iso", "")) < attempt_began(candidate))) or \
            (not candidate and build and (run.get("build") or "") != build)
    return label + ("*" if other or run.get("variant") else "")


def show_one(entry: dict, paint: Paint, build: str, candidate: str) -> int:
    print(paint(entry.get("id", "?"), "1"))
    status = roll_up(entry, build, candidate)
    print("  %-12s %s" % ("status", paint(status, MARK.get(status, "33"))))
    spec = spec_of(entry)
    for key in ("phase", "requirement", "detector", "budget_s", "source", "why", "invariant"):
        if spec.get(key):
            print("  %-12s %s" % (key, wrap(spec[key], 92, " " * 15)))
    runnable = [c for c in CONFIGS if applies(entry, c)]
    print("  %-12s" % "per config")
    for config in runnable:
        verdict = grade(entry, config, build, candidate)
        mark = verdict["mark"]
        cell = cell_of(entry, config)
        detail = verdict_note(verdict) or flat(cell.get("measured", ""), 52)
        elapsed = cell.get("elapsed_s")
        if elapsed is not None and budget_of(entry):
            detail = "%ss/%ss  %s" % (elapsed, budget_of(entry), detail)
        print("    %-20s %s  latest %-11s %s" % (config, paint("%-10s" % mark, MARK.get(mark, "33")),
                                                 latest_label(verdict, build, candidate), detail))
        for run in ledger_runs(None, config, entry.get("id"))[:12]:
            iso = str(run.get("iso", ""))
            settledby = settled(None, config, entry.get("id"), iso)
            print("    %-20s   %s %-10s build=%s%s%s%s" % (
                "", iso, run.get("outcome", "?"), (run.get("build") or "-")[:8],
                " cand=%s" % run["candidate"] if run.get("candidate") else "",
                " variant" if run.get("variant") else "",
                " (%s)" % settledby if settledby else ""))
    skipped = [c for c in CONFIGS if c not in runnable]
    if skipped:
        print("    %-10s not runnable here: %s" % ("", ", ".join(skipped)))
    return 0


def board(criteria: list, paint: Paint, verbose: bool, at: str, build: str, candidate: str) -> int:
    if not criteria:
        print("no criteria. Nothing has been said about what 'done' means.")
        return 0

    width_id = max([9] + [len(str(x.get("id", "?"))) for x in criteria])
    width_status = 10

    if at:
        criteria = [c for c in criteria if applies(c, at)]
        if not criteria:
            print("no criterion is runnable at %s." % at)
            return 0

    scope = at or "every configuration"
    graded = " — graded for candidate %s" % candidate if candidate else \
             (" — graded on build %s" % build if build else "")
    print("=== CRITERIA — what MXFS MUST ACHIEVE — %s%s ===" % (scope, graded))
    print("%-3s | %-*s | %-*s | %-11s | %-10s | %s" %
          ("#", width_id, "CRITERION", width_status, "STATUS", "LATEST", "BUDGET", "MEASURED"))
    print("%s-+-%s-+-%s-+-%s-+-%s-+-%s" %
          ("-" * 3, "-" * width_id, "-" * width_status, "-" * 11, "-" * 10, "-" * 40))

    tally: dict[str, int] = {}
    last_phase = None
    for number, entry in enumerate(criteria, 1):
        spec = spec_of(entry)
        if at:
            verdict = grade(entry, at, build, candidate)
            status = verdict["mark"]
            cell = cell_of(entry, at)
            measured, elapsed = cell.get("measured", ""), cell.get("elapsed_s")
            measured = verdict_note(verdict) or measured
            latest = latest_label(verdict, build, candidate)
        else:
            status = roll_up(entry, build, candidate)
            done = sum(1 for c in CONFIGS if cell_status(entry, c, build, candidate) in GREEN)
            measured, elapsed, latest = "%d of %d configurations" % (done, len(CONFIGS)), None, ""
        tally[status] = tally.get(status, 0) + 1

        phase = spec.get("phase")
        if verbose and phase and phase != last_phase:
            print(paint(f"\n  -- {phase} --", "1"))
            last_phase = phase
        budget = budget_of(entry)
        cost = "%s/%ss" % (elapsed, budget) if elapsed is not None and budget else (
            "%ss" % budget if budget else "—")
        print("%-3d | %s | %s | %-11s | %-10s | %s" %
              (number, paint("%-*s" % (width_id, entry.get("id", "?")), "1"),
               paint("%-*s" % (width_status, status), MARK.get(status, "33")),
               latest, cost, flat(measured, 56)))
        if verbose:
            print("    %s" % wrap(spec.get("requirement", ""), 96, " " * 4))
            if spec.get("why"):
                print("    %s %s" % (paint("why:", "2"), wrap(spec["why"], 96, " " * 4)))
            print()

    print("-" * (3 + width_id + width_status + 70))
    print("Total: %d — %s" %
          (len(criteria), ", ".join(f"{v} {k}" for k, v in sorted(tally.items()))))

    passing = sum(tally.get(mark, 0) for mark in GREEN)
    unmeasured = sum(tally.get(m, 0) for m in ("UNKNOWN", "STALE", "PARTIAL", "NOT RUN"))
    if passing == len(criteria):
        print(paint("VERDICT: every criterion green%s." % (" for %s" % at if at else ""), "32"))
    else:
        print(paint("VERDICT: %d of %d criteria are not passing. The bar is not met."
                    % (len(criteria) - passing, len(criteria)), "1;31"))
    if unmeasured:
        print(paint("NOTE: %d criterion/criteria are UNMEASURED or STALE, not failed. "
                    "Unmeasured is not a pass — nothing has been proved about them."
                    % unmeasured, "33"))
    print("LATEST is the newest run's own result; * means it was not on the build or candidate "
          "being graded.")
    return 0


def detector_script(detector: str) -> str:
    """The repo file a detector runs, or empty when it does not name one."""
    for word in str(detector).split():
        if word.endswith(".py") or word.endswith(".sh") or word.endswith(".c"):
            return word
    return ""


def cmd_gaps(criteria: list, paint: Paint, build: str) -> int:
    """
    Every criterion nobody can currently measure, and every configuration nobody has measured.

    NAMING A DETECTOR IS NOT HAVING ONE, and a `--gaps` that only asks whether the field is filled
    in will print "every criterion has a detector" while a named file has never existed.
    """
    missing, absent, unrun = [], [], []
    for entry in criteria:
        spec = spec_of(entry)
        detector = str(spec.get("detector", "")).strip()
        if not detector:
            missing.append((entry, "no detector at all"))
        else:
            script = detector_script(detector)
            if script and not (ROOT / script).exists():
                absent.append((entry, f"names {script}, which does not exist"))
        runnable = [c for c in CONFIGS if applies(entry, c)]
        never = [c for c in runnable if not ledger_runs(None, c, entry.get("id"))]
        if never:
            unrun.append((entry, "never run on %d of %d runnable configurations: %s"
                          % (len(never), len(runnable), ", ".join(never))))
    gaps = missing + absent + unrun
    if not gaps:
        print("every criterion has a detector that exists, and every configuration has a run.")
        return 0
    print(f"{len(gaps)} gap(s) — a requirement nobody can measure is a wish, and a "
          f"configuration nobody has measured is not a pass:\n")
    for entry, why in gaps:
        print(paint(entry.get("id", "?"), "1"), "—", why)
        print("  %s" % wrap(spec_of(entry).get("requirement", ""), 92, " " * 2))
        print()
    return 0


def specification_only(what: str) -> None:
    """A change to a row's specification is made on the specification, never on a results board."""
    if CRITERIA.resolve() != SPEC.resolve():
        sys.exit("criteria: %s changes the specification, which lives in %s; this command is "
                 "pointed at the results board %s (MXFS_CRIT)" % (what, SPEC, CRITERIA))
    refuse_while_qualifying(what)


def cmd_add(data: dict, args) -> int:
    specification_only("add")
    taken = {str(x.get("id", "")) for x in data["criteria"]}
    if args.id in taken:
        sys.exit(f"criteria: {args.id} already exists")
    entry = {"id": args.id,
             "requirement": args.requirement,
             "detector": args.detector,
             "per_config": {}}
    if args.budget_s is not None:
        if args.budget_s <= 0:
            sys.exit("criteria: -b/--budget-s is a time budget in seconds; must be positive")
        entry["budget_s"] = args.budget_s
    for key, value in (("phase", args.phase), ("why", args.why), ("source", args.source),
                       ("coord", args.coord), ("min_nodes", args.min_nodes),
                       ("max_nodes", args.max_nodes)):
        if value:
            entry[key] = value
    if args.applies_to:
        try:
            entry["applies_to"] = configuration.check_pattern(args.applies_to)
        except configuration.ConfigurationError as e:
            sys.exit(f"criteria: --applies-to: {e}")
    data["criteria"].append(entry)
    save(data)
    if args.budget_s is None:
        print("NOTE: no budget. A criterion with no time budget cannot fail on time, which is "
              "how a workload 30x slower than native reads as a pass. Set one with -b.")
    print(f"added {entry['id']}")
    return 0


def cmd_move(data: dict, args) -> int:
    """Put a criterion immediately before (or after) another on the board.

    The board's list order IS the dispatch order: run.sh runs the rows in the order `rows` emits
    them, and `add` appends. A row whose evidence another row consumes (alloc_witness seals the
    coverage witness chk_clean refuses to audit without, under the same run id) has to sit
    immediately before its consumer.
    """
    specification_only("move")
    entry = find(data, args.id)
    anchor = find(data, args.before or args.after)
    if entry is anchor:
        sys.exit(f"criteria: {args.id} cannot be moved relative to itself")
    rest = [x for x in data["criteria"] if x is not entry]
    at = rest.index(anchor) + (0 if args.before else 1)
    rest.insert(at, entry)
    data["criteria"] = rest
    save(data)
    print(f"moved {entry['id']} {'before' if args.before else 'after'} {anchor['id']}")
    return 0


def stall_over_limit(measured: str) -> int:
    """The worst operation stall a row reported (`max_stall_ms=`), when it is longer than the
    policy's `stall_limit_s`; else 0. A file operation stalled that long makes a VM's disk fail
    its I/O: the owner set it as the line between a performance and a stability defect."""
    worst = 0
    for value in re.findall(r"\bmax_stall_ms=(\d+)", str(measured)):
        worst = max(worst, int(value))
    return worst if worst > int(policy().get("stall_limit_s", 30)) * 1000 else 0


BASELINE = "1/xfs"


def cmd_update(data: dict, args) -> int:
    #: `is not None`: a max_nodes of 0 means "no cap", and a truthiness test dropped it silently.
    spec_fields = [(field, value) for field, value in (
        ("requirement", args.requirement), ("detector", args.detector), ("why", args.why),
        ("budget_s", args.budget_s), ("coord", args.coord), ("min_nodes", args.min_nodes),
        ("max_nodes", args.max_nodes)) if value is not None and value != ""]
    if spec_fields:
        specification_only("update " + "/".join(f for f, _ in spec_fields))

    if args.at:
        #: A CELL IS ONE CONFIGURATION'S MEASUREMENT. Recording it against the criterion as a whole
        #: is what let a 32/caw green stand in for 2/tcp, so a measurement without --at is refused
        #: rather than written somewhere it will be misread.
        config = parse_at(args.at)
        if spec_fields:
            sys.exit("criteria: a measurement and a change to the specification are two commands")
        #: A result with no build identity cannot be tied to the code it measured. run.sh refuses
        #: to start without one; anything else that records here must name it too. Only the
        #: native-XFS baseline has no module.
        if not args.build and config != BASELINE:
            sys.exit("criteria: --build is required: a result that names no build cannot be graded "
                     "against any release (the run's module srcversion, read from the nodes)")
        entry = find_or_adopt(data, args.id)
        raw = str(args.status or "").upper().strip().replace("_", " ")
        reason = args.reason or ""
        status = raw
        if raw and raw not in STATUSES:
            #: NEVER REFUSE A RESULT. Refusing an unknown status is how a node's own
            #: BUDGET_EXHAUSTED became ABORTED "result unknown": the write failed, the PENDING
            #: marker outlived it, and finalize discarded the hang.
            status = "FAIL"
            reason = "status %s, recorded as FAIL%s%s" % (raw, "; " if reason else "", reason)
        previous = cell_of(entry, config)
        status = status or str(previous.get("status", "UNKNOWN"))
        outcome = str(args.outcome or "").upper().strip() or outcome_of(status, reason)
        if outcome and outcome not in OUTCOMES:
            sys.exit(f"criteria: outcome {outcome!r}; expected one of {list(OUTCOMES)}")
        overrun = ""
        #: The budget the harness applied: the row's own, scaled by node count for a linear row,
        #: or derived from the soak length for the soak (run.sh). Grading the soak against its
        #: 60 s specification instead turned every real soak into a FAIL.
        applied = args.applied_budget if args.applied_budget else budget_of(entry)
        if args.elapsed_s is not None:
            budget = applied
            #: A budget is a performance assertion, so an overrun is a FAILURE and not a slow
            #: pass -- even with zero errors, even when the caller says PASS. A CALIBRATION run
            #: establishes a budget that does not exist yet; it is recorded as a variant, so it can
            #: never grade a release.
            if args.calibrate:
                reason = ("[CALIBRATION: budget not enforced, elapsed=%ss]%s%s"
                          % (args.elapsed_s, " " if reason else "", reason))
            elif budget and args.elapsed_s > budget and status in GREEN:
                status, outcome = "FAIL", "FAIL"
                reason = ("budget exceeded: elapsed=%ss > budget=%ss (functional checks passed)%s%s"
                          % (args.elapsed_s, budget, "; " if reason else "", reason))
                overrun = ("  OVERRUN: %ss against a %ss budget — recorded FAIL, not PASS"
                           % (args.elapsed_s, budget))
        measured = args.measured if args.measured is not None else previous.get("measured", "")
        stall = stall_over_limit(measured)
        if stall and outcome == "PASS":
            status, outcome = "FAIL", "FAIL"
            reason = ("operation stall %d ms is over the %d s limit "
                      "(data/release_policy.json stall_limit_s): a stability defect%s%s"
                      % (stall, int(policy().get("stall_limit_s", 30)), "; " if reason else "",
                         reason))
        if args.batch:
            import defects  # noqa: E402
            defects.check_batch_lap(args.batch, entry.get("id"), config, args.candidate or "")
        variant = args.variant or ("calibrate" if args.calibrate else "")
        iso = fresh_iso(entry, config)
        cell = write_cell(entry, config, status, measured, reason, args.elapsed_s,
                          args.build or "", iso=iso, outcome=outcome,
                          raw_status=raw if raw and raw != status else "",
                          budget_s=applied, run_id=args.run_id, candidate=args.candidate,
                          batch=args.batch, variant=variant, evidence=args.evidence,
                          seed=args.seed, platform=args.platform, kernel=args.kernel)
        #: The ledger first, flushed to disk; then the board. A board write can never get ahead
        #: of the record of the run.
        if outcome:
            append_ledger(CRITERIA, [run_record(config, entry.get("id"), cell, outcome)])
        save(data)
        print("recorded %s [%s] %s (outcome %s) at %s" % (entry["id"], config, status,
                                                         outcome or "-", iso))
        if overrun:
            print(overrun)
        return 0

    if args.status or args.measured or args.elapsed_s is not None or args.build:
        sys.exit("criteria: a measurement needs --at CONFIGURATION saying which configuration "
                 "it was measured on; a status with no configuration is how one column's green "
                 "gets read as the whole matrix")
    if not spec_fields:
        sys.exit("criteria: update needs at least one field to change")
    entry = find(data, args.id)
    for field, value in spec_fields:
        entry[field] = value
    entry["recorded"] = date.today().isoformat()
    save(data)
    print(f"updated {entry['id']}: {', '.join(f for f, _ in spec_fields)}")
    return 0


#: THE PENDING LIFECYCLE. A run marks everything it intends to run PENDING first, stamps the one
#: test actually in flight, and converts whatever markers survive when it exits.
#:
#: The two survivors mean different things and must not be conflated. A test that was EXECUTING
#: when the run died may have wedged the node: it is recorded INCOMPLETE, an incident until a
#: reviewed disposition says why. A test the run never reached says nothing whatever about the
#: filesystem: UNREACHED. Each carries the build, candidate and batch its run named.
MARKER_FIELDS = ("build", "candidate", "batch", "variant", "run_id")


def cmd_pending(data: dict, args) -> int:
    config = parse_at(args.at)
    marked = []
    for wanted in args.id:
        entry = find_or_adopt(data, wanted)
        write_cell(entry, config, "PENDING", "", "running %s" % args.run_id, None,
                   args.build or "", candidate=args.candidate, batch=args.batch,
                   variant=args.variant, run_id=args.run_id)
        marked.append(str(entry["id"]))
    save(data)
    print("marked %d PENDING for %s: %s" % (len(marked), config, " ".join(marked)))
    return 0


def cmd_executing(data: dict, args) -> int:
    config = parse_at(args.at)
    entry = find_or_adopt(data, args.id)
    cell = entry.setdefault("per_config", {}).setdefault(config, {})
    if str(cell.get("status", "")).upper().strip() != "PENDING":
        #: Not an error: a forced single-test run has no marker to stamp.
        return 0
    cell["reason"] = "executing %s" % args.run_id
    cell["iso"] = stamp()
    save(data)
    return 0


def cmd_finalize(data: dict, args) -> int:
    run = args.run_id or ""
    only = parse_at(args.at) if args.at else ""
    converted, records = [], []
    for entry in data["criteria"]:
        for config, cell in (entry.get("per_config") or {}).items():
            if only and config != only:
                continue
            if str(cell.get("status", "")).upper().strip() != "PENDING":
                continue
            reason = str(cell.get("reason") or "")
            if run:
                inflight, unreached = reason == "executing " + run, reason == "running " + run
            else:
                #: No run id: every pre-existing marker belongs to a run that is already dead,
                #: because the harness serialises runs behind a lock -- the whole board when
                #: runs are exclusive, one configuration's column (`--at`) when rig groups run
                #: several at once, each holding its configuration's lock. Heal them all.
                inflight = reason.startswith("executing ")
                unreached = reason.startswith("running ")
            marker = {k: cell.get(k) for k in MARKER_FIELDS if cell.get(k)}
            if inflight:
                status, outcome = "ABORTED", "INCOMPLETE"
                text = ("run died while this test was executing — result unknown; an incident "
                        "until a reviewed disposition says why (it may have wedged the node)")
            elif unreached:
                status, outcome = "NOT RUN", "UNREACHED"
                text = "sweep ended before reaching this test — not a result"
            else:
                continue
            written = write_cell(entry, config, status, "", text, None,
                                 marker.pop("build", ""),
                                 iso=fresh_iso(entry, config), outcome=outcome, **marker)
            records.append(run_record(config, entry.get("id"), written, outcome))
            converted.append("%s[%s]" % (entry["id"], config))
    if converted:
        append_ledger(CRITERIA, records)
        save(data)
        print("finalized %d marker(s): %s" % (len(converted), " ".join(converted)))
    return 0


def cmd_rows(data: dict, args) -> int:
    """The matrix as TSV, for the harness dispatch loop -- from the specification, whatever board
    the results go to.

    Eight columns: phase, applies_to, id, coord, min_nodes, max_nodes, budget_s, budget_scale.
    With --at, only the rows that apply to that configuration.
    """
    at = parse_at(args.at) if args.at else ""
    for spec in spec_rows():
        if at and not applies(spec, at):
            continue
        print("\t".join(str(x) for x in (
            spec.get("phase", ""),
            spec.get("applies_to") or "any",
            spec.get("id", ""),
            spec.get("coord", "none"),
            int(spec.get("min_nodes", 1) or 1),
            int(spec.get("max_nodes", 0) or 0),
            int(spec.get("budget_s", 300) or 300),
            spec.get("budget_scale", "flat"),
        )))
    return 0


#: The condition codes a `measured` string can still carry ("skipped (marker matched 1/caw)").
RETIRED_IN_TEXT = re.compile(r"\b(\d+)/(%s)\b" % "|".join(sorted(configuration.RETIRED, key=len,
                                                               reverse=True)))


def cmd_migrate_keys(data: dict, args) -> int:
    """ONE TIME: rename every condition-code column to its configuration, history and all.
    Refuses a board already migrated, and any board that already has a run ledger: the ledger's
    keys are configurations, and renaming the board under it would orphan them."""
    if ledger_path(CRITERIA).exists():
        sys.exit("criteria: %s has a run ledger; its keys cannot be renamed" % CRITERIA)

    def census() -> dict:
        counts = {}
        for entry in data["criteria"]:
            for key, cell in (entry.get("per_config") or {}).items():
                tally = counts.setdefault(key, [0, 0])
                tally[0] += 1
                tally[1] += len(cell.get("history") or [])
        return counts

    for entry in data["criteria"]:
        if "applies_to" in entry or any(k.count("/") > 1 for k in entry.get("per_config") or {}):
            sys.exit("criteria: %s is already migrated (%s)" % (CRITERIA, entry.get("id")))
    before = census()
    patterns = {"any": "any", "": "any", "tcp": "net/mesh", "caw": "disk/caw"}

    def retext(value):
        return RETIRED_IN_TEXT.sub(lambda m: configuration.translate_retired(m.group(0)), str(value))

    for entry in data["criteria"]:
        if "transport" in entry:
            old = str(entry.pop("transport")).lower()
            if old not in patterns:
                sys.exit("criteria: %s has transport %r, which has no pattern" % (entry["id"], old))
            entry["applies_to"] = patterns[old]
        renamed = {}
        for key, cell in (entry.get("per_config") or {}).items():
            new = configuration.translate_retired(key)
            if new in renamed:
                sys.exit("criteria: %s: two columns land on %s" % (entry["id"], new))
            for run in [cell] + list(cell.get("history") or []):
                if "measured" in run:
                    run["measured"] = retext(run["measured"])
            renamed[new] = cell
        if "per_config" in entry:
            entry["per_config"] = renamed
    after = census()
    for key in sorted(before):
        new = configuration.translate_retired(key)
        print("%-10s -> %-20s cells %3d -> %3d   history %4d -> %4d"
              % (key, new, before[key][0], after[new][0], before[key][1], after[new][1]))
    if sum(v[0] for v in before.values()) != sum(v[0] for v in after.values()) or \
            sum(v[1] for v in before.values()) != sum(v[1] for v in after.values()):
        sys.exit("criteria: cell or history totals changed; nothing written")
    if args.dry_run:
        print("dry run: nothing written")
        return 0
    save(data)
    print("migrated %s: %d columns" % (CRITERIA, len(after)))
    return 0


def cmd_migrate_ledger(data: dict, args) -> int:
    """ONE TIME per board: seed its run ledger from every cell and display history it holds.

    Each run is read with `outcome_of`. A board kept beside the primary (the DRBD rig, the
    physical Proxmox pair, vSphere) started life as a copy of data/criteria.json, so its copies of
    the primary's runs are skipped by key -- seeding them again would count the primary's failures
    two or three times over. The annotations the cells carry (`retired_by`, `detector_defect`)
    become notes; a withdrawn one becomes a withdrawal.
    """
    path = ledger_path(CRITERIA)
    if path.exists() and path.stat().st_size:
        sys.exit("criteria: %s already has a ledger (%s); nothing written" % (CRITERIA, path))
    primary = set()
    if CRITERIA.resolve() != SPEC.resolve():
        for entry in read_board(SPEC)["criteria"]:
            for config, cell in (entry.get("per_config") or {}).items():
                for run in [cell] + list(cell.get("history") or []):
                    primary.add((config, entry.get("id"), str(run.get("iso") or "")))
    runs, notes, skipped, copies = [], [], 0, 0
    for entry in data["criteria"]:
        for config, cell in (entry.get("per_config") or {}).items():
            for run in [cell] + list(cell.get("history") or []):
                outcome = outcome_of(run.get("status"), run.get("reason"))
                if outcome is None:
                    skipped += 1
                    continue
                iso = str(run.get("iso") or run.get("recorded") or "")
                key = (config, entry.get("id"), iso)
                if key in primary:
                    copies += 1
                    continue
                item = run_record(config, entry.get("id"), dict(run, iso=iso), outcome)
                item["migrated"] = date.today().isoformat()
                runs.append(item)
                for name in ("retired_by", "detector_defect"):
                    if run.get(name):
                        value = run[name] if isinstance(run[name], dict) else {"why": run[name]}
                        notes.append(note(config, entry.get("id"), iso, name, value))
                for name, of in (("retirement_withdrawn", "retired_by"),
                                 ("amendment_withdrawn", "detector_defect")):
                    if run.get(name):
                        notes.append(note(config, entry.get("id"), iso, "withdrawn",
                                          {"of": of, "why": run[name]}))
    runs.sort(key=lambda r: str(r.get("iso", "")))
    outcomes: dict = {}
    for item in runs:
        outcomes[item["outcome"]] = outcomes.get(item["outcome"], 0) + 1
    print("%s: %d runs (%s), %d notes; %d copies of the primary's runs and %d markers skipped"
          % (CRITERIA, len(runs), ", ".join("%s %d" % kv for kv in sorted(outcomes.items())),
             len(notes), copies, skipped))
    if args.dry_run:
        print("dry run: nothing written")
        return 0
    append_ledger(CRITERIA, runs + notes)
    print("wrote %s" % path)
    return 0


def annotated_run(data: dict, args) -> tuple:
    """(row, configuration) of the run an annotation is for: a board criterion's, or a release
    step's (tools/release_run.py records row `release:<step>`, which exists only in the ledger,
    filed under the step's configuration or the placeholder `1/any`), or a batch lap's (row
    `lap:<name>`, filed under its batch's configuration)."""
    if RELEASE_STEP_ANNOTATE and str(args.id).startswith("release:"):
        return args.id, (args.at if args.at == "1/any" else parse_at(args.at))
    if LAP_ANNOTATE and re.fullmatch(r"lap:\S+", str(args.id)):
        return args.id, parse_at(args.at)
    return find(data, args.id)["id"], parse_at(args.at)


def approval_or_exit(proposal: str, kind: str, config: str, row: str, iso: str) -> dict:
    """The reviewed approval a change needs (tools/defects.py proposals)."""
    import defects  # noqa: E402
    return defects.approval_for(proposal, kind, {"config": config, "row": row, "iso": iso})


def cmd_amend(data: dict, args) -> int:
    """Annotate ONE recorded FAIL as a detector defect, with a reviewed approval. The run stays in
    the ledger, FAIL, with the annotation beside it; it stops counting.

    A genuine FAIL means the TEST ITSELF detected a fault. When the test's own oracle is what was
    wrong (measured 2026-09-28: the 4-node crash audit read only the writer's kernel log while a
    third node had been the prover), the FAIL is evidence about the detector, not about MXFS. The
    detector fix must already be in the tree; the release-reviewer agent checks that, and that
    independent evidence shows the cluster did the right thing, before approving.
    """
    row, config = annotated_run(data, args)
    entry = {"id": row}
    run = ledger_run(CRITERIA, config, entry["id"], args.iso)
    if run is None:
        sys.exit("criteria: %s [%s] records no run stamped %s" % (entry["id"], config, args.iso))
    if run.get("outcome") not in ("FAIL", "INCOMPLETE"):
        sys.exit("criteria: the run stamped %s is %s; only a FAIL or INCOMPLETE can be a detector "
                 "defect" % (args.iso, run.get("outcome")))
    approval = approval_or_exit(args.approval, "detector-defect", config, entry["id"], args.iso)
    take_lock()
    append_ledger(CRITERIA, [note(config, entry["id"], args.iso, "detector_defect",
                                  {"why": args.detector_defect[:600], "approval": approval})])
    print("amended %s [%s] run %s: FAIL kept, annotated as a detector defect (approved %s)"
          % (entry["id"], config, args.iso, args.approval))
    print("\nThis changes what the board says. It belongs in CHANGELOG.md:\n")
    print("- **Board: %s at %s, the FAIL of %s was the detector's** — %s"
          % (entry["id"], config, args.iso, args.detector_defect))
    return 0


def cmd_infra(data: dict, args) -> int:
    """Annotate ONE recorded FAIL, INCOMPLETE or INFRA as an infrastructure fault, with a reviewed
    approval: positive evidence from outside MXFS that the rig failed first."""
    row, config = annotated_run(data, args)
    entry = {"id": row}
    run = ledger_run(CRITERIA, config, entry["id"], args.iso)
    if run is None:
        sys.exit("criteria: %s [%s] records no run stamped %s" % (entry["id"], config, args.iso))
    if run.get("outcome") not in ("FAIL", "INCOMPLETE", "INFRA"):
        sys.exit("criteria: the run stamped %s is %s; nothing to settle"
                 % (args.iso, run.get("outcome")))
    approval = approval_or_exit(args.approval, "infra-proven", config, entry["id"], args.iso)
    take_lock()
    append_ledger(CRITERIA, [note(config, entry["id"], args.iso, "infra_proven",
                                  {"why": args.why[:600], "approval": approval})])
    print("settled %s [%s] run %s as an infrastructure fault (approved %s)"
          % (entry["id"], config, args.iso, args.approval))
    print("\nThis changes what the board says. It belongs in CHANGELOG.md:\n")
    print("- **Board: %s at %s, the run of %s was the rig's** — %s"
          % (entry["id"], config, args.iso, args.why))
    return 0


def withdraw(data: dict, args, of: str, verb: str) -> int:
    """Take an annotation back: the run counts again. Needs no approval -- it can only make the
    board stricter."""
    row, config = annotated_run(data, args)
    entry = {"id": row}
    if ledger_run(CRITERIA, config, entry["id"], args.iso) is None:
        sys.exit("criteria: %s [%s] records no run stamped %s" % (entry["id"], config, args.iso))
    standing = annotations(CRITERIA, config, entry["id"], args.iso)
    if of not in standing:
        sys.exit("criteria: the run stamped %s carries no %s" % (args.iso, of))
    append_ledger(CRITERIA, [note(config, entry["id"], args.iso, "withdrawn",
                                  {"of": of, "why": args.why[:600]})])
    print("%s %s [%s] run %s: it counts again" % (verb, entry["id"], config, args.iso))
    print("\nThis changes what the board says. It belongs in CHANGELOG.md:\n")
    print("- **Board: %s at %s, the run of %s counts again** — %s"
          % (entry["id"], config, args.iso, args.why))
    return 0


def release_boards() -> list:
    """The boards a release is graded on: data/criteria.json, and the board of every attachment
    verified by a rig of its own that a release claims (data/configurations.json)."""
    boards = [SPEC]
    try:
        declared = json.loads((ROOT / "data" / "configurations.json").read_text())
    except (OSError, ValueError) as exc:
        sys.exit(f"criteria: cannot read data/configurations.json: {exc}")
    for key in declared.get("released_by_own_rig") or {}:
        if key == "_":
            continue
        attach = key.split("/")[-1]
        own = (declared.get("attaches") or {}).get(attach, {}).get("board")
        if own and (ROOT / own) not in boards:
            boards.append(ROOT / own)
    return boards


def own_attach(path: Path) -> str:
    """The attachment whose rig keeps this board (data/configurations.json attaches.<a>.board),
    or "" for a board that is not an own-rig board. An own-rig board began as a copy of the
    primary, so only its own attachment's columns are its results."""
    for attach, spec in configuration.ATTACHES.items():
        if spec.get("board") and (ROOT / spec["board"]).resolve() == Path(path).resolve():
            return attach
    return ""


def incidents(at: str = "", boards: list | None = None) -> list:
    """Every FAIL, INCOMPLETE or INFRA on a release board that no open defect record names and no
    disposition settles: (board, configuration, row, run). INFRA is the harness saying the rig
    failed first; that is a claim for the reviewer, never a way out of the list."""
    named = named_runs()
    loose = []
    for path in boards or release_boards():
        attach = own_attach(path)
        for (config, row), runs in sorted(read_ledger(path).runs.items(),
                                          key=lambda kv: (str(kv[0][0]), str(kv[0][1]))):
            if at and config != at:
                continue
            if attach and not str(config).endswith("/" + attach):
                continue
            for run in runs:
                if run.get("outcome") not in ("FAIL", "INCOMPLETE", "INFRA"):
                    continue
                iso = str(run.get("iso", ""))
                if settled(path, config, row, iso) or named.get((config, row, iso)):
                    continue
                loose.append((path, config, row, run))
    return loose


def cmd_incidents(args) -> int:
    """Every FAIL or INCOMPLETE nothing accounts for. Exit 1 while any is listed.

    Each has to be named by an open defect record (`tools/defects.py add|update --cell`) or
    settled by a reviewed disposition. Nothing ages out: a failure from any build, any candidate,
    stays here until one of those happens."""
    boards = [Path(b) if os.path.isabs(b) else ROOT / b for b in args.board] if args.board else None
    if not args.at:
        at = ""
    elif RELEASE_STEP_LIST and args.at == "1/any":
        at = args.at
    else:
        at = parse_at(args.at)
    loose = incidents(at, boards)
    if not loose:
        print("every FAIL and INCOMPLETE on the release boards%s is named by an open defect "
              "record or settled" % (" at %s" % args.at if args.at else ""))
        return 0
    print("%d run(s) that no open defect record names and no disposition settles (name each with "
          "tools/defects.py update <id> --cell CONFIG:ROW:ISO):" % len(loose))
    for path, config, row, run in loose:
        where = "" if path == SPEC else " [%s]" % os.path.relpath(path, ROOT)
        print("  %s:%s:%s  %s %s%s" % (config, row, run.get("iso", "?"), run.get("outcome"),
                                       flat(run.get("reason") or run.get("measured") or "", 90),
                                       where))
    return 1


def cmd_lap(args) -> int:
    """One run.sh invocation's verdict, from the runs it recorded (its run id) in the results
    board's ledger. Exit 0 when it recorded at least one run and every one passed (a SKIP is not
    applicable, not a failure), 1 when any did not, 2 when it recorded none.

    A lap is never graded from the board: the board also shows rows this lap did not run, so a lap
    that stopped early read as clean on the rows it never reached."""
    runs = [run for runs in read_ledger(CRITERIA).runs.values() for run in runs
            if run.get("run_id") == args.run_id]
    if not runs:
        print("lap %s recorded no run in %s" % (args.run_id, os.path.relpath(CRITERIA, ROOT)))
        return 2
    bad = [run for run in runs if run.get("outcome") not in ("PASS", "SKIP")]
    for run in sorted(runs, key=lambda r: str(r.get("iso", ""))):
        print("%-22s %-28s %-10s %s" % (run.get("config"), run.get("row"), run.get("outcome"),
                                         flat(run.get("reason") or run.get("measured") or "", 90)))
    print("lap %s: %d run(s), %d not passed" % (args.run_id, len(runs), len(bad)))
    return 1 if bad else 0


def cmd_rates(args) -> int:
    """Each row's recorded failure rate per configuration: FAIL / (PASS + FAIL), plain runs only.
    For scheduling repeat runs (tools/release_plan.py) -- never permission to ignore a failure."""
    at = parse_at(args.at) if args.at else ""
    rows = []
    for (config, row), runs in read_ledger(CRITERIA).runs.items():
        if at and config != at:
            continue
        plain = [r for r in runs if not r.get("variant")]
        fails = sum(1 for r in plain if r.get("outcome") == "FAIL")
        passes = sum(1 for r in plain if r.get("outcome") == "PASS")
        if fails + passes:
            rows.append((fails / (fails + passes), config, row, fails, fails + passes))
    for rate, config, row, fails, total in sorted(rows, reverse=True):
        print("%-22s %-28s %3d/%-4d %5.1f%%" % (config, row, fails, total, 100 * rate))
    return 0


def cmd_remove(data: dict, args) -> int:
    """Only for a criterion that is no longer something we must achieve.

    NOT FOR ONE THAT NOW PASSES. A criterion is permanent and can regress; taking a green one off
    the board is how a regression becomes invisible.
    """
    specification_only("remove")
    entry = find(data, args.id)
    was = roll_up(entry)
    data["criteria"] = [x for x in data["criteria"] if x is not entry]
    save(data)
    print(f"removed {entry['id']}")
    if was in GREEN:
        print("\nNOTE: that criterion was PASSING. If it is still something MXFS must do, "
              "put it back — a green taken off the board cannot regress visibly.")
    print("\nThis changes what 'done' means. It belongs in CHANGELOG.md:\n")
    print(f"- **Criterion {entry['id']} withdrawn** — {args.why}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="add each criterion's requirement and why it exists")
    parser.add_argument("--at", metavar="CONFIGURATION",
                        help="one configuration's column, e.g. 2/net/mesh/direct. "
                             "May also be given bare: `criteria.py 2/net/mesh/direct`")
    parser.add_argument("--build", default="",
                        help="grade on this module srcversion: a cell with no run on it reads "
                             "STALE")
    parser.add_argument("--candidate", default="",
                        help="grade for this release candidate (data/candidates/<id>.json)")
    parser.add_argument("--gaps", action="store_true",
                        help="criteria nobody can measure, and configurations nobody has")
    parser.add_argument("--no-colour", action="store_true")

    subs = parser.add_subparsers(dest="command")

    show = subs.add_parser("show", help="one criterion in full")
    show.add_argument("id")
    show.add_argument("--build", help="module srcversion to grade on")
    show.add_argument("--candidate", help="release candidate to grade for")

    add = subs.add_parser("add", help="a new thing MXFS must achieve")
    add.add_argument("-i", "--id", required=True)
    add.add_argument("-r", "--requirement", required=True, help="what must be true")
    add.add_argument("-d", "--detector", required=True,
                     help="how it is measured. Without one this is a wish, not a criterion")
    add.add_argument("-b", "--budget-s", type=int, dest="budget_s",
                     help="time budget in seconds. Derive it from what the operation SHOULD "
                          "take, never from what fits the tool cap")
    add.add_argument("-p", "--phase")
    add.add_argument("--why", help="why this matters")
    add.add_argument("--source", help="where the requirement came from")
    #: How run.sh dispatches the row (`rows` prints these): coord none runs the
    #: script on one node, barrier/ordered/fault on every node with a rank and
    #: a coordination prefix, host on this host.
    add.add_argument("--coord", choices=("none", "barrier", "ordered", "fault", "host"),
                     help="dispatch class: none (one node) | barrier/ordered/fault (every "
                          "node, ranked, coordinated) | host (this host)")
    add.add_argument("--min-nodes", type=int, dest="min_nodes",
                     help="the smallest node count the row is meaningful at")
    add.add_argument("--max-nodes", type=int, dest="max_nodes",
                     help="the largest node count the row runs at (0 = no cap)")
    add.add_argument("--applies-to", dest="applies_to", metavar="PATTERN",
                     help="the configurations the row exists on, a pattern over "
                          "class/method/attach: any (default) | disk/caw | net/mesh | */*/mpath")

    update = subs.add_parser("update", help="record a measurement")
    update.add_argument("id")
    update.add_argument("--at", metavar="CONFIGURATION",
                        help="the configuration this was measured on, e.g. 2/net/mesh/direct")
    update.add_argument("-s", "--status", help=f"one of {list(STATUSES)}; anything else is FAIL")
    update.add_argument("--outcome", help=f"one of {list(OUTCOMES)}, when the harness knows "
                                          "better than the status says")
    update.add_argument("-m", "--measured", help="what the detector said")
    #: No short flag: `-r` is already `--requirement` on this subcommand.
    update.add_argument("--reason", help="WHICH check failed")
    update.add_argument("--calibrate", action="store_true",
                        help="measurement run to establish a budget that does not exist yet: "
                             "recorded as a variant, never grading a release")
    update.add_argument("-e", "--elapsed-s", type=int, dest="elapsed_s",
                        help="wall seconds. Over the budget records FAIL, not PASS")
    update.add_argument("--applied-budget", type=int, dest="applied_budget",
                        help="the budget the harness applied to this run (scaled by node count, "
                             "or the soak's length); the row's own budget when absent")
    update.add_argument("--build", help="module srcversion this run measured (required)")
    update.add_argument("--run-id", dest="run_id", help="the run.sh run id")
    update.add_argument("--candidate", help="the release candidate this run belongs to")
    update.add_argument("--batch", help="the declared verification batch this run is a lap of")
    update.add_argument("--variant", help="what made this run not the plain candidate (a module "
                                          "knob, a test environment): it grades nothing")
    update.add_argument("--evidence", help="the run's evidence directory, relative to the tree")
    update.add_argument("--seed", help="the run's random seed, where the row takes one")
    update.add_argument("--platform", help="the platform the nodes ran (data/platforms.json key)")
    update.add_argument("--kernel", help="the nodes' kernel release")
    #: A criterion is permanent; its WORDING gets more exact as the bar is pinned down.
    update.add_argument("-r", "--requirement", help="restate what must be true")
    update.add_argument("-d", "--detector", help="restate how it is measured")
    update.add_argument("-b", "--budget-s", type=int, dest="budget_s",
                        help="restate the time budget. Widening one to make a cell green is "
                             "the edit this board exists to make visible")
    update.add_argument("--why", dest="why", help="restate why it matters")
    update.add_argument("--coord", choices=("none", "barrier", "ordered", "fault", "host"),
                        help="restate the dispatch class (see add)")
    update.add_argument("--min-nodes", type=int, dest="min_nodes")
    update.add_argument("--max-nodes", type=int, dest="max_nodes")

    amend = subs.add_parser("amend", help="annotate one recorded FAIL as the detector's fault")
    amend.add_argument("id")
    amend.add_argument("--at", metavar="CONFIGURATION", required=True)
    amend.add_argument("--iso", required=True,
                       help="the run's stamp as `show` prints it, naming exactly one run")
    amend.add_argument("--detector-defect", dest="detector_defect", required=True,
                       help="what the detector got wrong, the evidence that the cluster had done "
                            "the right thing, and the detector fix that is already in the tree")
    amend.add_argument("--approval", required=True,
                       help="the approved proposal (tools/defects.py propose / review)")

    infra = subs.add_parser("infra", help="annotate one run as an infrastructure fault")
    infra.add_argument("id")
    infra.add_argument("--at", metavar="CONFIGURATION", required=True)
    infra.add_argument("--iso", required=True, help="the run's stamp, as `show` prints it")
    infra.add_argument("--why", required=True,
                       help="the positive evidence, from outside MXFS, that the rig failed first")
    infra.add_argument("--approval", required=True,
                       help="the approved proposal (tools/defects.py propose / review)")

    unamend = subs.add_parser("unamend", help="take back an amendment whose case did not hold")
    unamend.add_argument("id")
    unamend.add_argument("--at", metavar="CONFIGURATION", required=True)
    unamend.add_argument("--iso", required=True, help="the amended run's stamp, as `show` prints it")
    unamend.add_argument("--why", required=True,
                         help="what was measured that shows the amendment's case was wrong")

    unretire = subs.add_parser("unretire",
                               help="take back a retirement whose fix did not hold")
    unretire.add_argument("id")
    unretire.add_argument("--at", metavar="CONFIGURATION", required=True)
    unretire.add_argument("--iso", required=True, help="the retired run's stamp, as `show` prints it")
    unretire.add_argument("--why", required=True,
                          help="what was measured that shows the fix did not hold")

    remove = subs.add_parser("remove", help="no longer something we must achieve")
    remove.add_argument("id")
    remove.add_argument("--why", required=True, help="why this is no longer required")

    move = subs.add_parser("move", help="reorder: the board's order is the dispatch order")
    move.add_argument("id")
    where = move.add_mutually_exclusive_group(required=True)
    where.add_argument("--before", help="the criterion this one must run immediately before")
    where.add_argument("--after", help="the criterion this one must run immediately after")

    pending = subs.add_parser("pending", help="mark criteria as in-flight for a run")
    pending.add_argument("id", nargs="+")
    pending.add_argument("--at", metavar="CONFIGURATION", required=True)
    pending.add_argument("--run-id", dest="run_id", required=True)
    pending.add_argument("--build", help="the run's module srcversion")
    pending.add_argument("--candidate", help="the run's release candidate")
    pending.add_argument("--batch", help="the run's verification batch")
    pending.add_argument("--variant", help="the run's variant")

    executing = subs.add_parser("executing", help="stamp the one criterion actually in flight")
    executing.add_argument("id")
    executing.add_argument("--at", metavar="CONFIGURATION", required=True)
    executing.add_argument("--run-id", dest="run_id", required=True)

    finalize = subs.add_parser("finalize", help="convert leftover PENDING markers to a result")
    finalize.add_argument("--run-id", dest="run_id", default="",
                          help="only this run's markers; omit to heal every stale marker")
    finalize.add_argument("--at", metavar="CONFIGURATION",
                          help="only this configuration's column")

    rows = subs.add_parser("rows", help="the matrix as TSV, for the harness dispatch loop")
    rows.add_argument("--at", metavar="CONFIGURATION",
                      help="only the rows that apply to this configuration")

    migrate = subs.add_parser("migrate-keys",
                              help="one time: rename condition-code columns to configurations")
    migrate.add_argument("--dry-run", action="store_true")

    seed = subs.add_parser("migrate-ledger",
                           help="one time per board: seed its run ledger from its cells")
    seed.add_argument("--dry-run", action="store_true")

    loose = subs.add_parser("incidents",
                            help="every FAIL or INCOMPLETE nothing accounts for; exit 1 while any")
    loose.add_argument("--at", metavar="CONFIGURATION")
    loose.add_argument("--board", action="append",
                       help="a board file instead of the release boards (repeatable)")

    rates = subs.add_parser("rates", help="each row's recorded failure rate (scheduling only)")
    rates.add_argument("--at", metavar="CONFIGURATION")

    lap = subs.add_parser("lap", help="one run.sh run's own verdict, from the runs it recorded")
    lap.add_argument("run_id", help="the run id run.sh prints (=== run @ <config> (run_id=...))")

    args = parser.parse_args(lift_config(sys.argv)[1:])
    for absent in ("at", "build", "candidate", "gaps", "verbose", "budget_s", "requirement",
                   "detector", "why", "status", "measured", "elapsed_s", "reason", "calibrate",
                   "run_id", "outcome", "batch", "variant", "evidence", "seed", "platform",
                   "kernel", "board", "approval", "applied_budget"):
        if not hasattr(args, absent):
            setattr(args, absent, None)
    paint = Paint(not args.no_colour and sys.stdout.isatty()
                  and os.environ.get("TERM", "") not in ("", "dumb"))
    #: amend and infra take the queue's lock for their approval first and the board's after it:
    #: tools/defects.py takes them in that order too, and two commands taking two locks in
    #: opposite orders can wait on each other until one gives up.
    if args.command in MUTATORS and args.command not in ("amend", "infra"):
        take_lock()
    if args.command == "incidents":
        return cmd_incidents(args)
    if args.command == "rates":
        return cmd_rates(args)
    if args.command == "lap":
        return cmd_lap(args)
    data = load()

    if args.command == "show":
        return show_one(find(data, args.id), paint, args.build or "", args.candidate or "")
    if args.command == "add":
        return cmd_add(data, args)
    if args.command == "update":
        return cmd_update(data, args)
    if args.command == "amend":
        return cmd_amend(data, args)
    if args.command == "infra":
        return cmd_infra(data, args)
    if args.command == "unamend":
        return withdraw(data, args, "detector_defect", "unamended")
    if args.command == "unretire":
        return withdraw(data, args, "retired_by", "unretired")
    if args.command == "remove":
        return cmd_remove(data, args)
    if args.command == "move":
        return cmd_move(data, args)
    if args.command == "pending":
        return cmd_pending(data, args)
    if args.command == "executing":
        return cmd_executing(data, args)
    if args.command == "finalize":
        return cmd_finalize(data, args)
    if args.command == "rows":
        return cmd_rows(data, args)
    if args.command == "migrate-keys":
        refuse_while_qualifying("migrate-keys")
        return cmd_migrate_keys(data, args)
    if args.command == "migrate-ledger":
        return cmd_migrate_ledger(data, args)
    if args.gaps:
        return cmd_gaps(data["criteria"], paint, args.build or "")
    return board(data["criteria"], paint, args.verbose,
                 parse_at(args.at) if args.at else "", args.build or "", args.candidate or "")


if __name__ == "__main__":
    sys.exit(main())
