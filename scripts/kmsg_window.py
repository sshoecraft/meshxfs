#!/usr/bin/env python3
"""Cut a UTC window out of a followed kmsg file (.gz or plain).
The [monotonic] stamp is mapped to CLOCK_REALTIME through the nearest line
carrying realns=<ns>.  usage:
  kmsg_window.py FILE UTC_LO_EPOCH_S UTC_HI_EPOCH_S OUT [EXCLUDE_REGEX]
Prints: map offsets used, lines in window, lines kept."""
import bisect, gzip, re, sys
f, lo, hi, out = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
excl = re.compile(sys.argv[5].encode()) if len(sys.argv) > 5 else None
opener = gzip.open if f.endswith('.gz') else open
tsrx = re.compile(rb'^\[\s*(\d+\.\d+)\]')
rnrx = re.compile(rb'realns=(\d+)')
lines = []
tss = []
samp_ts = []
samp_off = []
with opener(f, 'rb') as fh:
    for ln in fh:
        m = tsrx.match(ln)
        ts = float(m.group(1)) if m else None
        lines.append((ts, ln))
        if ts is not None:
            r = rnrx.search(ln)
            if r:
                samp_ts.append(ts)
                samp_off.append(int(r.group(1)) / 1e9 - ts)
def off_at(ts):
    i = bisect.bisect_left(samp_ts, ts)
    c = [j for j in (i - 1, i) if 0 <= j < len(samp_ts)]
    return samp_off[min(c, key=lambda j: abs(samp_ts[j] - ts))]
inwin = kept = notimestamp = 0
lo_ts = hi_ts = None
with open(out, 'wb') as o:
    for ts, ln in lines:
        if ts is None:
            notimestamp += 1
            continue
        u = ts + off_at(ts)
        if lo <= u <= hi:
            inwin += 1
            if lo_ts is None: lo_ts = ts
            hi_ts = ts
            if excl and excl.search(ln):
                continue
            kept += 1
            o.write(ln if ln.endswith(b'\n') else ln + b'\n')
print(f, "total lines", len(lines), "without [ts]", notimestamp, "realns samples", len(samp_ts))
print("  window ts range in file", lo_ts, hi_ts, "offset at lo %.6f" % off_at(lo_ts), "offset at hi %.6f" % off_at(hi_ts))
print("  lines in window", inwin, "kept after exclude", kept, "->", out)
