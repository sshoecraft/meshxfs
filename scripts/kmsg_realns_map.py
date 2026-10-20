#!/usr/bin/env python3
"""Report how a followed kmsg file's [monotonic] stamps map to CLOCK_REALTIME,
from the lines that carry realns=<ns>.  usage: kmsg_realns_map.py FILE.gz [...]"""
import gzip, re, sys
for f in sys.argv[1:]:
    rx = re.compile(rb'^\[\s*(\d+\.\d+)\].*?realns=(\d+)')
    n = 0; lines = 0; first = last = None; offs = []
    with gzip.open(f, 'rb') as fh:
        for ln in fh:
            lines += 1
            m = rx.match(ln)
            if m:
                ts = float(m.group(1)); rn = int(m.group(2))
                off = rn / 1e9 - ts
                n += 1
                offs.append((ts, off))
    print(f, "lines", lines, "realns-lines", n)
    if offs:
        # report offset at every 10 s of monotonic stamp, min/max
        prev = None
        for ts, off in offs:
            b = int(ts // 10)
            if b != prev:
                prev = b
                print("  ts=%.3f off=%.6f" % (ts, off))
        print("  min off %.6f max off %.6f" % (min(o for _, o in offs), max(o for _, o in offs)))
