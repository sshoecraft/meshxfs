#!/usr/bin/env python3
import sys, json
needle = sys.argv[1]
out = []
for fn in sys.argv[2:]:
    for ln in open(fn, errors="replace"):
        try:
            o = json.loads(ln)
        except Exception:
            continue
        c = (o.get("message") or {}).get("content")
        if not isinstance(c, list):
            continue
        for b in c:
            if isinstance(b, dict) and b.get("type") == "tool_use":
                cmd = (b.get("input") or {}).get("command")
                if isinstance(cmd, str) and needle in cmd:
                    out.append((fn, cmd))
print("TOTAL", len(out))
for fn, cmd in out[:6]:
    print("=== ", fn.split("/")[-1])
    print(cmd[:1500])
