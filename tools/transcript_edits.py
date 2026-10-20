#!/usr/bin/env python3
"""Print the Edit / Write / MultiEdit calls a session transcript made, verbatim.

    python3 tools/transcript_edits.py TRANSCRIPT [--path SUBSTR] [--grep SUBSTR] [--out FILE]

  TRANSCRIPT   a Claude Code session transcript (.jsonl, one JSON event per line)
  --path       keep only calls whose file_path contains SUBSTR (repeatable; any match)
  --grep       keep only calls whose old_string, new_string or content contains SUBSTR
               (repeatable; any match)
  --out        write there instead of stdout

Each kept call prints a header "=== L<line> <tool> <file_path> [replace_all]" and then
the call's strings between explicit markers, unmodified:

    --- old_string ---          (Edit, and each MultiEdit entry)
    --- new_string ---
    --- content ---             (Write)
    --- end ---

It reads tool CALLS, not their results, so a call that failed (old_string not found,
file not read first) is printed like one that applied: check the transcript's result
for the line before trusting that a call took effect.  This is how code removed from
the tree is recovered when the tree has no other copy of it.
"""
import argparse
import json
import sys


def calls(path):
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for number, raw in enumerate(handle, 1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                event = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if not isinstance(event, dict) or event.get("type") != "assistant":
                continue
            message = event.get("message")
            content = message.get("content") if isinstance(message, dict) else None
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                name = block.get("name")
                data = block.get("input")
                if name in ("Edit", "Write", "MultiEdit") and isinstance(data, dict):
                    yield number, name, data


def pieces(name, data):
    """(label, text) pairs in the order they print."""
    if name == "Write":
        return [("content", str(data.get("content", "")))]
    if name == "Edit":
        return [("old_string", str(data.get("old_string", ""))),
                ("new_string", str(data.get("new_string", "")))]
    out = []
    for entry in data.get("edits") or []:
        if isinstance(entry, dict):
            out.append(("old_string", str(entry.get("old_string", ""))))
            out.append(("new_string", str(entry.get("new_string", ""))))
    return out


def main(argv):
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("transcript")
    parser.add_argument("--path", action="append", default=[])
    parser.add_argument("--grep", action="append", default=[])
    parser.add_argument("--out")
    args = parser.parse_args(argv[1:])

    out = open(args.out, "w", encoding="utf-8") if args.out else sys.stdout
    kept = 0
    seen = 0
    for number, name, data in calls(args.transcript):
        seen += 1
        target = str(data.get("file_path", ""))
        if args.path and not any(p in target for p in args.path):
            continue
        texts = pieces(name, data)
        if args.grep and not any(g in text for g in args.grep for _, text in texts):
            continue
        kept += 1
        flag = " replace_all" if data.get("replace_all") else ""
        out.write("=== L%d %s %s%s\n" % (number, name, target, flag))
        for label, text in texts:
            out.write("--- %s ---\n" % label)
            out.write(text if text.endswith("\n") else text + "\n")
        out.write("--- end ---\n")
    if args.out:
        out.close()
    sys.stderr.write("edit/write calls in transcript: %d, printed: %d\n" % (seen, kept))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
