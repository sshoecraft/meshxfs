#!/usr/bin/env python3
"""Ledger evidence for the runs `tools/criteria.py incidents` lists.

usage: python3 -I scripts/incident_evidence.py INCIDENTS_TXT REPORT_TXT [PREFACE_TXT]

INCIDENTS_TXT is the saved output of `tools/criteria.py incidents`. For every run it lists, the
report gives the ledger line that recorded the run; the line of the same run_id (same
configuration) appended just before it and just after it; and, by kind of incident:

  "run died while this test was executing"   every other non-PASS line of that run_id, and the
                                             names under tests/evidence/ that contain the run_id
  release:<step>                             the ledger line's evidence path, whether the file
                                             exists, and its last lines
  guard_census                               the ledger line's evidence path and, when the file
                                             exists, the lines that name the unclassified fast path

PREFACE_TXT, when given, is copied to the top of the report unchanged (the commands and any
evidence gathered by hand).

Reads only. The one file written is REPORT_TXT. A ledger is read up to its last complete line, and
the report records each one's line count, byte length and sha256 over that prefix, so the line
numbers it quotes can be checked later against the append-only ledger:
`head -c BYTES LEDGER | sha256sum`.
"""
import hashlib
import json
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PRIMARY = "data/criteria.runs.jsonl"
LEDGER_PATHS = (
    PRIMARY,
    "tests/evidence/drbd_rig/criteria.runs.jsonl",
    "data/criteria.pvephys.runs.jsonl",
)
DIED = "run died while this test was executing"
EXCERPT = 220
REASON_WIDTH = 400
NEIGHBOR_WIDTH = 200
TAIL_LINES = 8
MATCH_LINES = 20
MAX_PATHS = 5
MAX_COUNT_BYTES = 64 * 1024 * 1024
TAIL_WINDOW = 256 * 1024

ENTRY = re.compile(r"^  (?P<key>\S+)  (?P<outcome>[A-Z]+)(?: (?P<rest>.*))?$")
KEY = re.compile(r"^(?P<config>[^:]+):(?P<row>.+):"
                 r"(?P<iso>\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}Z)?)$")
BOARD = re.compile(r" \[(?P<board>[^\]\s]+)\]$")
CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
GUARD_LINES = re.compile(r"^(NEW|GREW) |test=guard_census")


def clean(text):
    """Control characters made visible, so an excerpt cannot drive the terminal."""
    return CONTROL.sub(lambda hit: "\\x%02x" % ord(hit.group()), text)


def flat(value, width=None):
    """tools/criteria.py's flat(): whitespace collapsed, cut to width with an ellipsis."""
    text = " ".join(str(value).split())
    return text[:width - 1] + "…" if width and len(text) > width else text


def clip(text, width):
    """text cut to width characters; a cut says how long the whole was."""
    if len(text) <= width:
        return text
    return "%s…[cut at %d of %d chars]" % (text[:width], width, len(text))


def field(item, key):
    """A ledger field for the report: an absent key and a null are told apart."""
    if key not in item:
        return "(absent)"
    return "null" if item[key] is None else str(item[key])


def load_ledger(rel):
    """One ledger up to its last complete line: the lines of kind run, indexed three ways."""
    path = ROOT / rel
    if not path.is_file():
        return None
    raw = path.read_bytes()
    end = raw.rfind(b"\n") + 1
    body = raw[:end]
    ledger = {"rel": rel, "bytes": end, "tail": len(raw) - end,
              "sha256": hashlib.sha256(body).hexdigest(), "total": body.count(b"\n"),
              "bad": [], "runs": [], "cells": {}, "by_run": {}, "cap": 0}
    for number, chunk in enumerate(body.split(b"\n")[:-1], 1):
        try:
            item = json.loads(chunk.decode("utf-8"))
        except ValueError:
            ledger["bad"].append(number)
            continue
        if not isinstance(item, dict) or item.get("kind") != "run":
            continue
        ledger["runs"].append((number, item))
        if len(item.get("reason") or "") == REASON_WIDTH:
            ledger["cap"] += 1
        cell = (item.get("config"), item.get("row"), str(item.get("iso", "")))
        ledger["cells"].setdefault(cell, []).append((number, item))
        if item.get("run_id"):
            ledger["by_run"].setdefault(item["run_id"], []).append((number, item))
    return ledger


def parse_incidents(path):
    """(declared count, listed incidents, lines that did not parse)."""
    lines = path.read_text(encoding="utf-8").split("\n")
    declared = re.match(r"^(\d+) run\(s\)", lines[0]) if lines else None
    listed, unparsed = [], []
    for number, line in enumerate(lines[1:], 2):
        if not line.strip():
            continue
        entry = ENTRY.match(line)
        key = KEY.match(entry.group("key")) if entry else None
        if not key:
            unparsed.append((number, line))
            continue
        rest = entry.group("rest") or ""
        board = BOARD.search(rest)
        if board:
            rest = rest[:board.start()]
        listed.append({"line": number, "config": key.group("config"), "row": key.group("row"),
                       "iso": key.group("iso"), "outcome": entry.group("outcome"),
                       "reason": rest, "board": board.group("board") if board else ""})
    return (int(declared.group(1)) if declared else None), listed, unparsed


def board_ledger(board):
    path = Path(board)
    return str(path.with_name(path.stem + ".runs.jsonl"))


def find_lines(ledger, wanted, exact):
    """The run lines of one cell with the listed outcome; exact also compares the listed reason,
    which tools/criteria.py printed through flat(reason or measured, 90)."""
    found = []
    for number, item in ledger["cells"].get((wanted["config"], wanted["row"], wanted["iso"]), []):
        if item.get("outcome") != wanted["outcome"]:
            continue
        if exact and flat(item.get("reason") or item.get("measured") or "", 90) != wanted["reason"]:
            continue
        found.append((number, item))
    return found


def neighbors(ledger, number, item):
    """The nearest run lines before and after this one in file order that share its run_id and
    configuration. A line with no run_id has none, so the fallback is its candidate, and failing
    that its configuration alone; the label says which one was used."""
    if item.get("run_id"):
        label, key, value = "run_id", "run_id", item["run_id"]
    elif item.get("candidate"):
        label, key, value = "candidate", "candidate", item["candidate"]
    else:
        label, key, value = "configuration", None, None
    before = after = None
    for other_number, other in ledger["runs"]:
        if other_number == number or other.get("config") != item.get("config"):
            continue
        if key and other.get(key) != value:
            continue
        if other_number < number:
            before = (other_number, other)
        else:
            after = (other_number, other)
            break
    return label, value, before, after


def describe(entry, width):
    """row outcome stamp reason, with the ledger line number in front."""
    if entry is None:
        return "none"
    number, item = entry
    reason, prefix = flat(item.get("reason") or ""), ""
    if not reason:
        reason, prefix = flat(item.get("measured") or ""), "measured: "
    return clean("L%d  %s  %s  %s  %s%s" % (number, item.get("row"), item.get("outcome"),
                                            item.get("iso"), prefix, clip(reason, width)))


def resolve(evidence):
    path = Path(evidence)
    return path if path.is_absolute() else ROOT / path


def count_lines(path, size):
    if size > MAX_COUNT_BYTES:
        return None
    total, last = 0, b""
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            total += chunk.count(b"\n")
            last = chunk[-1:]
    return total + (1 if last and last != b"\n" else 0)


def tail_of(path, count):
    size = path.stat().st_size
    with path.open("rb") as handle:
        handle.seek(max(0, size - TAIL_WINDOW))
        text = handle.read().decode("utf-8", "replace")
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines[-count:]


def evidence_lines(item, pattern):
    """The ledger line's evidence path and whether it exists; then its last lines, or with a
    pattern the lines that match it (with their line numbers)."""
    evidence = item.get("evidence")
    if not evidence:
        return ["evidence: (no `evidence` key on the ledger line)"]
    path = resolve(evidence)
    out = ["evidence path: %s" % evidence, "resolved to: %s" % path]
    try:
        if not path.exists():
            out.append("exists: no")
            return out
        if path.is_dir():
            names = sorted(os.listdir(path))
            out.append("exists: yes, a directory with %d entries; the first %d:"
                       % (len(names), min(len(names), 10)))
            out.extend("  " + clean(name) for name in names[:10])
            return out
        size = path.stat().st_size
        total = count_lines(path, size)
        out.append("exists: yes, a file of %d bytes, %s lines"
                   % (size, "not counted (over %d bytes)" % MAX_COUNT_BYTES if total is None else total))
        if pattern is None:
            out.append("last %d lines (each cut to %d chars):" % (TAIL_LINES, EXCERPT))
            out.extend("  | " + clean(clip(text, EXCERPT)) for text in tail_of(path, TAIL_LINES))
            return out
        hits = []
        with path.open("rb") as handle:
            for number, raw in enumerate(handle, 1):
                text = raw.decode("utf-8", "replace").rstrip("\n")
                if pattern.search(text):
                    hits.append((number, text))
        out.append("lines matching /%s/: %d%s" % (pattern.pattern, len(hits),
                   "" if len(hits) <= MATCH_LINES else ", showing the first %d" % MATCH_LINES))
        out.extend("  %s:%d: %s" % (evidence, number, clean(clip(text, EXCERPT)))
                   for number, text in hits[:MATCH_LINES])
    except OSError as exc:
        out.append("error reading it: %s" % exc)
    return out


def source_line(rel, needle):
    """file:line: text of the first line of a source file that contains needle."""
    try:
        for number, line in enumerate((ROOT / rel).read_text(encoding="utf-8").split("\n"), 1):
            if needle in line:
                return "%s:%d: %s" % (rel, number, clip(line.strip(), EXCERPT))
    except OSError as exc:
        return "%s: unreadable (%s)" % (rel, exc)
    return "%s: no line contains %r" % (rel, needle)


def evidence_names(run_ids):
    """Every entry under tests/evidence/ whose own name contains one of the run ids."""
    hits = {rid: [] for rid in run_ids}
    unreadable = []
    walked = 0
    if not run_ids:
        return hits, walked, unreadable
    pattern = re.compile("|".join(re.escape(rid) for rid in sorted(run_ids, key=len, reverse=True)))

    def note_error(error):
        unreadable.append(str(error.filename))

    top = str(ROOT / "tests" / "evidence") + "/"
    for dirpath, dirnames, filenames in os.walk(top, onerror=note_error):
        for name in dirnames + filenames:
            walked += 1
            if pattern.search(name):
                for rid in run_ids:
                    if rid in name:
                        hits[rid].append(os.path.relpath(os.path.join(dirpath, name), ROOT))
    return hits, walked, unreadable


def lines_of(ledgers, rid):
    return [(rel, number, item) for rel, ledger in ledgers.items() if ledger
            for number, item in ledger["by_run"].get(rid, [])]


def ledger_block(rel, number, item, how, ledger):
    extras = ["outcome=%s" % field(item, "outcome"), "status=%s" % field(item, "status")]
    for key in ("batch", "variant", "migrated"):
        if key in item:
            extras.append("%s=%s" % (key, clip(field(item, key), 120)))
    if how != "exact":
        extras.append("match=" + how)
    out = ["ledger: %s:%d  run_id=%s  build=%s  candidate=%s  evidence=%s  [%s]"
           % (rel, number, field(item, "run_id"), field(item, "build"), field(item, "candidate"),
              field(item, "evidence"), " ".join(extras))]
    reason, label = flat(item.get("reason") or ""), "reason"
    if not reason:
        reason, label = flat(item.get("measured") or ""), "reason (empty on the line; measured)"
    stored = len(item.get("reason") or "")
    out.append("%s: %s%s" % (label, clean(clip(reason, REASON_WIDTH)),
                             " [stored reason length: %d chars]" % stored if stored >= REASON_WIDTH else ""))
    label, value, before, after = neighbors(ledger, number, item)
    if label == "run_id":
        same = [n for n, other in ledger["runs"]
                if other.get("run_id") == value and other.get("config") == item.get("config")]
        out.append("position: line %d of %d in this ledger carrying run_id %s for configuration %s"
                   % (same.index(number) + 1, len(same), value, item.get("config")))
        out.append("prev: " + (describe(before, NEIGHBOR_WIDTH) if before else
                               "none (no earlier line of this run_id for this configuration in this ledger)"))
        out.append("next: " + (describe(after, NEIGHBOR_WIDTH) if after else
                               "none (no later line of this run_id for this configuration in this ledger)"))
    else:
        shared = "the configuration only" if value is None else "%s=%s and the configuration" % (label, value)
        out.append("prev: none (this ledger line carries no run_id)")
        out.append("next: none (this ledger line carries no run_id)")
        out.append("fallback prev (shares %s; NOT the same run_id): %s"
                   % (shared, describe(before, NEIGHBOR_WIDTH)))
        out.append("fallback next (shares %s; NOT the same run_id): %s"
                   % (shared, describe(after, NEIGHBOR_WIDTH)))
    return out


def died_lines(rel, number, item, ledgers, names):
    rid = item.get("run_id")
    if not rid:
        iso = str(item.get("iso", ""))
        runs = ledgers[rel]["runs"]
        same = [(n, o) for n, o in runs if n != number and o.get("config") == item.get("config")
                and str(o.get("iso", "")) == iso]
        elsewhere = [(n, o) for n, o in runs if o.get("config") != item.get("config")
                     and str(o.get("iso", "")) == iso]
        out = ["run_id absent on this ledger line: the other lines of its run_id and the evidence "
               "names containing it cannot be listed",
               "instead: other lines in this ledger with the identical iso %s in the same "
               "configuration: %d" % (iso, len(same))]
        out.extend("  %s:%d  %s  %s  %s  %s" % (rel, n, o.get("config"), o.get("row"),
                                               o.get("outcome"), o.get("iso")) for n, o in same)
        out.append("instead: lines in this ledger with the identical iso in other configurations: "
                   "%d%s" % (len(elsewhere), "" if len(elsewhere) <= 12 else ", showing the first 12"))
        out.extend("  %s:%d  %s  %s  %s  %s" % (rel, n, o.get("config"), o.get("row"),
                                               o.get("outcome"), o.get("iso"))
                   for n, o in elsewhere[:12])
        return out
    lines = lines_of(ledgers, rid)
    per_ledger = Counter(r for r, _, _ in lines)
    configs = sorted({o.get("config") for _, _, o in lines}, key=str)
    outcomes = Counter(o.get("outcome") for _, _, o in lines)
    out = ["run_id %s: %d ledger line(s) (%s) over %d configuration(s) (%s); by outcome %s"
           % (rid, len(lines), ", ".join("%s=%d" % pair for pair in sorted(per_ledger.items())),
              len(configs), ", ".join(str(c) for c in configs), dict(sorted(outcomes.items(), key=str)))]
    others = [(r, n, o) for r, n, o in lines
              if o.get("outcome") != "PASS" and not (r == rel and n == number)]
    out.append("other lines of this run_id whose outcome is not PASS: %d" % len(others))
    out.extend("  %s:%d  %s  %s  %s  %s" % (r, n, o.get("config"), o.get("row"), o.get("outcome"),
                                           o.get("iso")) for r, n, o in others)
    stamp = rid.split("-")[0]
    files = []
    for token, label in [(rid, "the run_id")] + ([(stamp, "the leading stamp of the run_id alone")]
                                                 if stamp != rid else []):
        paths = sorted(names[token])
        out.append("names under tests/evidence/ containing %s (%s): %d" % (label, token, len(paths)))
        out.extend("  " + clean(p) for p in paths[:MAX_PATHS])
        if len(paths) > MAX_PATHS:
            out.append("  (showing %d of %d)" % (MAX_PATHS, len(paths)))
        files += [p for p in paths[:MAX_PATHS] if (ROOT / p).is_file() and p not in files]
    out.append("recheck: find %s/tests/evidence/ -name '*%s*' | wc -l" % (ROOT, rid))
    for p in files[:2]:
        out.append("regular file whose name matched above (first %d of %d):" % (min(2, len(files)), len(files)))
        out.extend("  " + line for line in evidence_lines({"evidence": p}, None))
    return out


def main(argv):
    if len(argv) not in (3, 4):
        sys.exit(__doc__)
    incidents_path, report_path = Path(argv[1]), Path(argv[2])
    preface = Path(argv[3]).read_text(encoding="utf-8") if len(argv) == 4 else ""
    declared, listed, unparsed = parse_incidents(incidents_path)
    wanted_ledgers = list(LEDGER_PATHS)
    for entry in listed:
        if entry["board"] and board_ledger(entry["board"]) not in wanted_ledgers:
            wanted_ledgers.append(board_ledger(entry["board"]))
    ledgers = {rel: load_ledger(rel) for rel in wanted_ledgers}

    results = []
    for entry in listed:
        expected = board_ledger(entry["board"]) if entry["board"] else PRIMARY
        order = [expected] + [rel for rel in ledgers if rel != expected]
        chosen, how, where, also = [], "", "", []
        for exact in (True, False):
            for rel in order:
                if ledgers[rel] and find_lines(ledgers[rel], entry, exact):
                    chosen, where = find_lines(ledgers[rel], entry, exact), rel
                    how = "exact" if exact else "config,row,iso,outcome only; the reason differs"
                    also = [(other, find_lines(ledgers[other], entry, exact)) for other in order
                            if other != rel and ledgers[other] and find_lines(ledgers[other], entry, exact)]
                    break
            if chosen:
                break
        results.append({"entry": entry, "expected": expected, "chosen": chosen, "how": how,
                        "where": where, "also": also})

    died_ids = sorted({item["run_id"] for r in results for _, item in r["chosen"]
                       if item.get("run_id") and (item.get("reason") or "").startswith(DIED)})
    tokens = sorted({token for rid in died_ids for token in (rid, rid.split("-")[0])})
    names, walked, unreadable = evidence_names(tokens)

    blocks = []
    for index, result in enumerate(results, 1):
        entry = result["entry"]
        out = ["---- %d of %d  (incidents file line %d) ----" % (index, len(results), entry["line"]),
               "INCIDENT %s:%s:%s" % (entry["config"], entry["row"], entry["iso"])]
        if not result["chosen"]:
            out.append("ledger: NOT FOUND in %s" % ", ".join(r for r in ledgers if ledgers[r]))
            out.append("listed as: %s %s%s" % (entry["outcome"], entry["reason"],
                                               " [%s]" % entry["board"] if entry["board"] else ""))
            blocks.append(out)
            continue
        if result["where"] != result["expected"]:
            out.append("NOTE: the listing places this run on the board whose ledger is %s; the line "
                       "was found in %s" % (result["expected"], result["where"]))
        for position, (number, item) in enumerate(result["chosen"], 1):
            if len(result["chosen"]) > 1:
                out.append("(ledger line %d of %d for this cell)" % (position, len(result["chosen"])))
            out.extend(ledger_block(result["where"], number, item, result["how"],
                                    ledgers[result["where"]]))
            if (item.get("reason") or "").startswith(DIED):
                out.extend(died_lines(result["where"], number, item, ledgers, names))
            if str(entry["row"]).startswith("release:"):
                out.extend(evidence_lines(item, None))
            if entry["row"] == "guard_census":
                out.extend(evidence_lines(item, GUARD_LINES))
                out.append("measured on the ledger line: %s" % field(item, "measured"))
                out.append("the test prints the lines in question at: "
                           + source_line("tests/tooling/guard_census.sh", "(NEW|GREW)"))
        for other, hits in result["also"]:
            out.append("also present in %s at line(s): %s" % (other, ", ".join(str(n) for n, _ in hits)))
        blocks.append(out)

    found = [r for r in results if r["chosen"]]
    exact_found = [r for r in found if r["how"] == "exact"]
    multi = [r for r in found if len(r["chosen"]) > 1]
    with_run_id = [r for r in found if any(item.get("run_id") for _, item in r["chosen"])]
    died = [r for r in found if any((item.get("reason") or "").startswith(DIED) for _, item in r["chosen"])]
    release = [r for r in results if str(r["entry"]["row"]).startswith("release:")]
    guard = [r for r in results if r["entry"]["row"] == "guard_census"]
    lines_matched = sum(len(r["chosen"]) for r in found)

    head = ["INCIDENT EVIDENCE REPORT",
            "generated: " + datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "invoked as: python3 -I " + " ".join(argv),
            "script: %s (verbatim copy at the end of this file)" % Path(__file__).resolve(),
            "repo root: %s" % ROOT,
            "incidents file: %s" % incidents_path,
            "  incident lines parsed: %d (the header declares %s); lines not parsed: %d"
            % (len(listed), declared, len(unparsed))]
    head.extend("  not parsed, line %d: %s" % pair for pair in unparsed)
    head.append("ledgers (read to the last complete line; each is live and append-only, so the line "
                "numbers below refer to this prefix):")
    for rel, ledger in ledgers.items():
        if not ledger:
            head.append("  %s: does not exist" % rel)
            continue
        head.append("  %s  lines=%d  kind-run lines=%d  unparseable lines=%d%s  bytes=%d  sha256=%s"
                    "  run lines whose stored reason is exactly %d chars=%d"
                    % (rel, ledger["total"], len(ledger["runs"]), len(ledger["bad"]),
                       " %s" % ledger["bad"][:10] if ledger["bad"] else "", ledger["bytes"],
                       ledger["sha256"], REASON_WIDTH, ledger["cap"]))
        head.append("      verify: head -c %d %s | sha256sum%s" % (
            ledger["bytes"], rel,
            "   (%d torn trailing bytes ignored)" % ledger["tail"] if ledger["tail"] else ""))
    head += ["matching: a ledger line is the incident when kind=run and config, row, iso and outcome",
             "  equal the listed ones and flat(reason or measured, 90) equals the listed reason;",
             "  the listing's board suffix names the ledger to look in first (none: %s)." % PRIMARY,
             "prev/next: by ledger line order (the order lines were appended), among kind=run lines",
             "  of the same run_id and configuration in the same ledger; each shows its iso.",
             "reason text has whitespace collapsed; excerpts are cut as marked.",
             "COUNTS",
             "  incidents listed: %d" % len(results),
             "  incidents with a ledger line found: %d of %d (exact match on all five: %d; weaker: %d)"
             % (len(found), len(results), len(exact_found), len(found) - len(exact_found)),
             "  ledger lines matched: %d; incidents matching more than one line: %d%s"
             % (lines_matched, len(multi),
                " (%s)" % ", ".join("%s:%s:%s" % (r["entry"]["config"], r["entry"]["row"], r["entry"]["iso"])
                                    for r in multi) if multi else ""),
             "  found per ledger: " + ", ".join("%s=%d" % (rel, sum(1 for r in found if r["where"] == rel))
                                                for rel in ledgers),
             "  found in a ledger other than the one the listing implies: %d"
             % sum(1 for r in found if r["where"] != r["expected"]),
             "  matched lines that carry a run_id: %d of %d incidents found"
             % (len(with_run_id), len(found)),
             "  matched lines that carry a `migrated` key: %d of %d incidents found"
             % (sum(1 for r in found if any("migrated" in item for _, item in r["chosen"])), len(found)),
             "  'run died while this test was executing' incidents: %d" % len(died),
             "  release:<step> incidents: %d; guard_census incidents: %d" % (len(release), len(guard)),
             "  evidence-name walk: %d entries under tests/evidence/ visited for %d run_id(s); "
             "unreadable directories: %d%s"
             % (walked, len(died_ids), len(unreadable), " %s" % unreadable[:5] if unreadable else ""),
             "  NOT FOUND: %s" % (", ".join("%s:%s:%s" % (r["entry"]["config"], r["entry"]["row"], r["entry"]["iso"])
                                             for r in results if not r["chosen"]) or "none"),
             ""]
    text = preface + ("" if not preface or preface.endswith("\n") else "\n")
    text += "\n".join(head) + "\n" + "\n\n".join("\n".join(block) for block in blocks) + "\n"
    text += "\n==== SCRIPT (verbatim) ====\n" + Path(__file__).read_text(encoding="utf-8")
    report_path.write_text(text, encoding="utf-8")
    print("\n".join(head))
    print("report written to %s (%d bytes)" % (report_path, len(text.encode("utf-8"))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
