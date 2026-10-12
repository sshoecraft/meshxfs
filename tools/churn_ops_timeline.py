#!/usr/bin/env python3
"""churn_ops_timeline.py — when, within a shared-directory churn run, each
host's loops made their progress.

Usage: tools/churn_ops_timeline.py <evidence dir> <host> [<host>...] [--bucket S] [--t T]

Reads <evidence dir>/ops.<host> (tests/pve_churn_fairness.sh): per loop, one
line per iteration with each operation's latency in microseconds.  With --t
(the run's start time T, epoch seconds) and a run that kept each iteration's
start time, iterations are placed by that time; otherwise the running sum of
a loop's latencies places them (shell overhead between operations is not
counted, and a loop that started late is placed as if it began at T).  Prints, per host, the
iterations all its loops completed in each bucket of S seconds (default 5),
and the share of the bucket's time its loops spent in each operation.
"""
import collections
import sys

NAMES = ("append", "create", "rename", "remove", "sync")


def main():
    args = sys.argv[1:]
    bucket = 5.0
    if "--bucket" in args:
        i = args.index("--bucket")
        bucket = float(args[i + 1])
        del args[i:i + 2]
    t0 = None
    if "--t" in args:
        i = args.index("--t")
        t0 = float(args[i + 1])
        del args[i:i + 2]
    if len(args) < 2:
        print(__doc__)
        return 2
    evid, hosts = args[0], args[1:]
    for h in hosts:
        clock = collections.defaultdict(float)
        iters = collections.Counter()
        spent = collections.defaultdict(lambda: [0.0] * len(NAMES))
        for line in open(f"{evid}/ops.{h}"):
            f = line.split()
            if f[:1] == ["OPS"] and len(f) == 4 and f[2] == "START" and t0 is not None:
                clock[f[1]] = float(f[3]) - t0
            if f[:1] != ["OPS"] or len(f) not in (8, 9):
                continue
            loop = f[1]
            if len(f) == 9 and t0 is not None:
                # the iteration's own wall-clock start, when the run kept it
                clock[loop] = int(f[8]) / 1e6 - t0
            for n, v in enumerate(f[3:8]):
                b = int(clock[loop] / bucket)
                spent[b][n] += int(v) / 1e6
                clock[loop] += int(v) / 1e6
            iters[int(clock[loop] / bucket)] += 1
        print(f"{h}: iterations per {bucket:g} s bucket (all loops), and loop-seconds per operation")
        for b in sorted(set(iters) | set(spent)):
            s = spent[b]
            print(f"  {b * bucket:5.0f}-{(b + 1) * bucket:<4.0f} s: {iters[b]:5d} iterations | "
                  + " ".join(f"{n} {v:5.1f}" for n, v in zip(NAMES, s)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
