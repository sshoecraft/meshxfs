#!/usr/bin/env python3
"""path_io_latency.py — read tests/mpath/path_io_sampler.sh captures.

Each sampler line is: <epoch ms> <dev> <writes completed> <sectors written>
<ms spent writing> <in flight> <ms doing io>  (cumulative /proc/diskstats
fields).  For every device in each file this prints, over the seconds in
which the device wrote anything: how many such seconds, the MiB/s written
(median and peak), and the mean time per completed write (ms spent writing /
writes completed over the second) — median, 95th percentile and worst.

A slow sequential write that is the DEVICE's doing shows up as long per-write
times on the paths (and, sampled on clyde, on the pool disk) while MXFS keeps
writes in flight; a filesystem that stops issuing shows idle seconds instead.

Usage: tools/path_io_latency.py <capture> [<capture> ...] [--dev REGEX]
"""
import re
import sys
from collections import defaultdict


def pct(vals, p):
    if not vals:
        return 0.0
    s = sorted(vals)
    return s[min(len(s) - 1, int(round(p / 100.0 * (len(s) - 1))))]


def read(path, devre):
    rows = defaultdict(list)
    with open(path, errors="replace") as f:
        for line in f:
            p = line.split()
            if len(p) != 7 or not p[0].isdigit():
                continue
            if devre and not re.search(devre, p[1]):
                continue
            t, w, sec, wms = int(p[0]), int(p[2]), int(p[3]), int(p[4])
            rows[p[1]].append((t, w, sec, wms))
    return rows


def main(argv):
    devre = None
    files = []
    i = 0
    while i < len(argv):
        if argv[i] == "--dev":
            devre = argv[i + 1]
            i += 2
            continue
        files.append(argv[i])
        i += 1
    if not files:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    print("%-40s %-12s %5s %9s %9s %9s %9s %9s" %
          ("capture", "device", "secs", "MiBs_med", "MiBs_max",
           "wms_med", "wms_p95", "wms_max"))
    for path in files:
        for dev, r in sorted(read(path, devre).items()):
            mibs, lat = [], []
            for a, b in zip(r, r[1:]):
                dt = (b[0] - a[0]) / 1000.0
                dw, dsec, dms = b[1] - a[1], b[2] - a[2], b[3] - a[3]
                if dt <= 0 or dw <= 0:
                    continue
                mibs.append(dsec * 512 / 1048576.0 / dt)
                lat.append(dms / float(dw))
            if not lat:
                continue
            print("%-40s %-12s %5d %9.0f %9.0f %9.1f %9.1f %9.1f" %
                  (path[-40:], dev, len(lat), pct(mibs, 50), max(mibs),
                   pct(lat, 50), pct(lat, 95), max(lat)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
