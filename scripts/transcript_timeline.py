#!/usr/bin/env python3
"""Timeline of one line range of a Claude Code session transcript (.jsonl).

    python3 scripts/transcript_timeline.py TRANSCRIPT FIRST LAST OUT

  TRANSCRIPT   the session transcript: one JSON event per physical line
  FIRST, LAST  inclusive 1-based physical line numbers (what `wc -l` counts)
  OUT          output path; "-" writes the timeline to stdout and the run report
               to stderr

One entry per assistant text block, per assistant tool_use and per tool_result
block, in file order.  Each entry starts with a header line

    ##### #<n> L<line> <timestamp or -> <KIND> ...

where L<line> is the physical line of the transcript and <timestamp> is that
event's "timestamp" field ("-" when the event has none).

ASSISTANT_TEXT   the whole text block, verbatim.
TOOL_USE         the tool name and its input as the assistant wrote it (the
                 message content, not the "wireToolInputs" copy, which can differ:
                 a Bash command there carries a "cd <cwd> && " prefix):
                   Bash            command and description, first 600 chars each
                   Edit            file_path; old_string and new_string, first 300 each
                   Agent / Task    description and prompt, first 600 chars each
                   Write           file_path; content, first 300 chars
                   any other tool  the whole input as JSON, first 600 chars
                 Input fields not shown above follow on one "other input fields"
                 line, each value cut to 80 chars.  Every cut says how many
                 characters were not shown.
TOOL_RESULT      the text of the result: whole when it is at most 800 chars, else
                 the first 400 chars, a "[... N chars omitted ...]" line and the
                 last 400 chars.  The header names the tool_use it answers
                 (use=L<line> <tool>) and says IS_ERROR when is_error is set.

Not emitted, and counted in the run report: thinking blocks, user events that
carry no tool_result (typed prompts), and every event type other than assistant
and user (attachment, system, api-request, ...).  Nothing is filtered or
rewritten inside what is emitted.  Blank and non-JSON lines are skipped and
reported with their line numbers.  Lines of the output that start with "@@"
describe the run and are not transcript content.
"""
import collections
import json
import os
import sys

RESULT_EDGE = 400
GENERIC_CAP = 600
OTHER_VALUE_CAP = 80
SHOWN = {
    "Bash": (("command", 600), ("description", 600)),
    "Edit": (("file_path", 600), ("old_string", 300), ("new_string", 300)),
    "Agent": (("description", 600), ("prompt", 600)),
    "Task": (("description", 600), ("prompt", 600)),
    "Write": (("file_path", 600), ("content", 300)),
}
HEADER = "##### #"
USAGE = ("usage: python3 scripts/transcript_timeline.py TRANSCRIPT FIRST LAST OUT"
         "   (OUT '-' = timeline on stdout, run report on stderr)\n")
Entry = collections.namedtuple("Entry", "line stamp kind head body")


def load(path):
    """Every parseable event as (physical line number, dict).  Blank and malformed
    lines are returned by number so nothing is skipped silently."""
    records = []
    blank = []
    malformed = []
    total = 0
    with open(path, "r", encoding="utf-8", errors="replace", newline="\n") as handle:
        for number, raw in enumerate(handle, 1):
            total = number
            text = raw.strip()
            if not text:
                blank.append(number)
                continue
            try:
                event = json.loads(text)
            except json.JSONDecodeError:
                malformed.append(number)
                continue
            if isinstance(event, dict):
                records.append((number, event))
            else:
                malformed.append(number)
    return records, blank, malformed, total


def message_blocks(event):
    """The event's message content as a list of dict blocks; a plain string
    becomes one text block."""
    message = event.get("message")
    if not isinstance(message, dict):
        return []
    content = message.get("content")
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    if isinstance(content, list):
        return [block for block in content if isinstance(block, dict)]
    return []


def index_tools(records):
    """tool_use id -> (line, tool name) and the set of tool_use ids that have a
    tool_result, both over the whole file."""
    uses = {}
    answered = set()
    for number, event in records:
        kind = event.get("type")
        for block in message_blocks(event):
            if kind == "assistant" and block.get("type") == "tool_use":
                uses[block.get("id")] = (number, str(block.get("name")))
            elif kind == "user" and block.get("type") == "tool_result":
                answered.add(block.get("tool_use_id"))
    return uses, answered


def as_text(value):
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False, default=str)


def cut(text, limit):
    """The first limit chars, then a line saying how many were not shown."""
    if len(text) <= limit:
        return text
    return "%s\n[cut: %d of %d chars not shown]" % (text[:limit], len(text) - limit, len(text))


def labelled(label, data, limit):
    if label not in data:
        return "--- %s: absent ---" % label
    text = as_text(data[label])
    return "--- %s (len=%d) ---\n%s" % (label, len(text), cut(text, limit))


def short(value):
    if value is None or isinstance(value, (bool, int, float)):
        return value
    text = as_text(value)
    if len(text) <= OTHER_VALUE_CAP:
        return text
    return "%s...[+%d chars]" % (text[:OTHER_VALUE_CAP], len(text) - OTHER_VALUE_CAP)


def tool_use_body(name, data):
    if not isinstance(data, dict):
        text = as_text(data)
        return "--- input (len=%d) ---\n%s" % (len(text), cut(text, GENERIC_CAP))
    plan = SHOWN.get(name)
    if plan is None:
        text = as_text(data)
        return "--- input as JSON (len=%d) ---\n%s" % (len(text), cut(text, GENERIC_CAP))
    parts = [labelled(label, data, limit) for label, limit in plan]
    shown = [label for label, limit in plan]
    rest = {key: short(value) for key, value in data.items() if key not in shown}
    if rest:
        parts.append("--- other input fields ---\n" + json.dumps(rest, ensure_ascii=False, default=str))
    return "\n".join(parts)


def result_text(block):
    """Text of a tool_result block: a string as is, text blocks joined with a
    newline, any other block as a one-line placeholder."""
    content = block.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict) and item.get("type") == "text":
                parts.append(str(item.get("text", "")))
            elif isinstance(item, dict):
                parts.append("[%s block omitted]" % item.get("type"))
        return "\n".join(parts)
    return ""


def result_body(text):
    if len(text) <= 2 * RESULT_EDGE:
        return text
    return "%s\n[... %d chars omitted ...]\n%s" % (
        text[:RESULT_EDGE], len(text) - 2 * RESULT_EDGE, text[-RESULT_EDGE:])


def collect(records, first, last, uses, answered):
    """Entries for the range plus the tallies the run report prints."""
    entries = []
    tally = collections.defaultdict(collections.Counter)
    lists = collections.defaultdict(list)
    for number, event in records:
        if number < first or number > last:
            continue
        kind = event.get("type")
        tally["events"][str(kind)] += 1
        raw = event.get("timestamp")
        stamp = None if raw in (None, "") else str(raw)
        if kind not in ("assistant", "user"):
            continue
        if event.get("isSidechain"):
            tally["flags"]["isSidechain"] += 1
        blocks = message_blocks(event)
        if kind == "user" and not any(b.get("type") == "tool_result" for b in blocks):
            lists["user_without_result"].append(number)
        for block in blocks:
            btype = str(block.get("type"))
            tally[kind + " blocks"][btype] += 1
            if kind == "assistant" and btype == "text":
                text = block.get("text")
                if not isinstance(text, str):
                    text = "" if text is None else as_text(text)
                entries.append(Entry(number, stamp, "ASSISTANT_TEXT", "chars=%d" % len(text), text))
            elif kind == "assistant" and btype == "tool_use":
                name = str(block.get("name"))
                entries.append(Entry(number, stamp, "TOOL_USE", "%s id=%s" % (name, block.get("id")),
                                     tool_use_body(name, block.get("input"))))
                if block.get("id") not in answered:
                    lists["use_without_result"].append(number)
            elif kind == "user" and btype == "tool_result":
                text = result_text(block)
                ident = block.get("tool_use_id")
                found = uses.get(ident)
                head = "use=L%d %s" % found if found else "use=not-in-file"
                head += " id=%s len=%d" % (ident, len(text))
                if block.get("is_error"):
                    head += " IS_ERROR"
                    tally["flags"]["is_error"] += 1
                if found and found[0] < first:
                    lists["result_for_use_before_range"].append(number)
                entries.append(Entry(number, stamp, "TOOL_RESULT", head, result_body(text)))
    return entries, tally, lists


def render(entries):
    chunks = []
    for index, entry in enumerate(entries, 1):
        chunks.append("%s%d L%d %s %s %s\n%s\n\n" % (
            HEADER, index, entry.line, entry.stamp or "-", entry.kind, entry.head, entry.body))
    return chunks


def fmt(counter):
    items = sorted(counter.items(), key=lambda item: (-item[1], str(item[0])))
    return ", ".join("%s=%d" % item for item in items) or "-"


def main(argv):
    if len(argv) != 5:
        sys.stderr.write(USAGE)
        return 2
    path, first_text, last_text, outpath = argv[1:5]
    try:
        first = int(first_text)
        last = int(last_text)
    except ValueError:
        sys.stderr.write(USAGE)
        return 2
    if first < 1 or last < first:
        sys.stderr.write(USAGE)
        return 2
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="backslashreplace")
    try:
        records, blank, malformed, total = load(path)
    except OSError as failure:
        sys.stderr.write("error: cannot read %s: %s\n" % (path, failure))
        return 1
    uses, answered = index_tools(records)
    entries, tally, lists = collect(records, first, last, uses, answered)
    span = "%d..%d" % (first, min(last, total))

    chunks = ["@@ transcript_timeline source=%s lines=%s of %d\n" % (path, span, total),
              "@@ entries: ASSISTANT_TEXT (verbatim), TOOL_USE (input fields capped), TOOL_RESULT "
              "(first 400 + last 400 chars) in file order\n",
              "@@ not emitted: thinking blocks, user events without a tool_result, every event type "
              "other than assistant and user\n\n"]
    chunks.extend(render(entries))
    chunks.append("@@ end entries=%d\n" % len(entries))
    unencodable = 0
    encoded = []
    for chunk in chunks:
        try:
            encoded.append(chunk.encode("utf-8"))
        except UnicodeEncodeError:
            unencodable += 1
            encoded.append(chunk.encode("utf-8", "backslashreplace"))
    to_stdout = outpath == "-"
    if to_stdout:
        sys.stdout.flush()
        sys.stdout.buffer.write(b"".join(encoded))
        sys.stdout.buffer.flush()
    else:
        with open(outpath, "wb") as handle:
            handle.write(b"".join(encoded))

    in_range = [(n, e) for n, e in records if first <= n <= last]
    blank_in = [n for n in blank if first <= n <= last]
    malformed_in = [n for n in malformed if first <= n <= last]
    kinds = collections.Counter(entry.kind for entry in entries)
    stamped = [entry.stamp for entry in entries if entry.stamp]
    inversions = sum(1 for a, b in zip(stamped, stamped[1:]) if b < a)
    other_events = sum(v for k, v in tally["events"].items() if k not in ("assistant", "user"))
    report = sys.stderr if to_stdout else sys.stdout
    report.write("transcript: %s\n" % path)
    report.write("file: %d physical lines; range %s = %d lines; parsed=%d blank=%d malformed=%d %s\n"
                 % (total, span, max(0, min(last, total) - first + 1), len(in_range),
                    len(blank_in), len(malformed_in), malformed_in[:20]))
    report.write("events in range by type: %s\n" % fmt(tally["events"]))
    report.write("assistant blocks in range: %s\n" % fmt(tally["assistant blocks"]))
    report.write("user blocks in range: %s\n" % fmt(tally["user blocks"]))
    report.write("entries: %d (%s)\n" % (len(entries), fmt(kinds)))
    report.write("not emitted: thinking blocks=%d; events of types other than assistant/user=%d; "
                 "user events without a tool_result=%d %s\n"
                 % (tally["assistant blocks"]["thinking"], other_events,
                    len(lists["user_without_result"]), lists["user_without_result"][:40]))
    report.write("assistant/user blocks neither emitted nor counted above: %d\n" % (
        sum(tally["assistant blocks"].values()) + sum(tally["user blocks"].values())
        - len(entries) - tally["assistant blocks"]["thinking"]
        - sum(v for k, v in tally["user blocks"].items() if k != "tool_result")))
    report.write("flags among assistant/user events in range: %s\n" % fmt(tally["flags"]))
    report.write("entries without a timestamp: %d\n" % sum(1 for entry in entries if not entry.stamp))
    report.write("timestamp order: %d inversions in %d adjacent stamped-entry pairs\n"
                 % (inversions, max(0, len(stamped) - 1)))
    report.write("tool_use entries whose tool_use id has no tool_result anywhere in the file: %d %s\n"
                 % (len(lists["use_without_result"]), lists["use_without_result"][:40]))
    report.write("tool_result entries answering a tool_use before line %d: %d %s\n"
                 % (first, len(lists["result_for_use_before_range"]),
                    lists["result_for_use_before_range"][:40]))
    report.write("chunks written with backslashreplace (unencodable characters): %d\n" % unencodable)
    if to_stdout:
        report.write("output: stdout\n")
    else:
        counted = 0
        with open(outpath, "rb") as handle:
            for raw in handle:
                if raw.startswith(HEADER.encode("ascii")):
                    counted += 1
        report.write("output: %s bytes=%d header lines re-read from the file=%d\n"
                     % (outpath, os.path.getsize(outpath), counted))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
