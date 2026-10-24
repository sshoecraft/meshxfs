#!/usr/bin/env python3
"""List Bash tool_use commands (and result heads) of a session transcript.
usage: transcript_bash_cmds.py FILE [--grep STR] [--from N] [--to N] [--result N]
"""
import json, sys, argparse
ap = argparse.ArgumentParser()
ap.add_argument("file")
ap.add_argument("--grep")
ap.add_argument("--from", dest="lo", type=int, default=1)
ap.add_argument("--to", dest="hi", type=int, default=10**9)
ap.add_argument("--result", type=int, default=0)
a = ap.parse_args()
uses = {}   # tool_use_id -> (line, ts, cmd)
results = {}
for n, line in enumerate(open(a.file, encoding="utf-8"), 1):
    try:
        o = json.loads(line)
    except Exception:
        continue
    m = o.get("message")
    if not isinstance(m, dict) or not isinstance(m.get("content"), list):
        continue
    for c in m["content"]:
        if c.get("type") == "tool_use" and c.get("name") == "Bash":
            uses[c["id"]] = (n, o.get("timestamp"), c["input"].get("command", ""))
        elif c.get("type") == "tool_result":
            t = c.get("content")
            if isinstance(t, list):
                t = "".join(x.get("text", "") for x in t if isinstance(x, dict))
            results[c["tool_use_id"]] = (n, str(t))
for i, (n, ts, cmd) in sorted(uses.items(), key=lambda kv: kv[1][0]):
    if not (a.lo <= n <= a.hi):
        continue
    if a.grep and a.grep not in cmd:
        continue
    print(f"##### line {n} ts {ts}")
    print(cmd)
    if a.result and i in results:
        print(f"----- result (line {results[i][0]}), first {a.result} chars of {len(results[i][1])}")
        print(results[i][1][:a.result])
