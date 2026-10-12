#!/usr/bin/env python3
"""tenure_timeline.py — both hosts' lock releases on a few inodes, merged in
wall-clock order, from a churn run's tenure probes (tests/pve_churn_fairness.sh
PROBES=1), so one handoff cycle can be read end to end.

Usage: tools/tenure_timeline.py <evidence dir> <T> <host>[=label] <host>[=label] --ino N [--ino N...] [--from S] [--to S] [--stats]

Reads <evidence dir>/klog.<host>: P70-BP ENTRY (a release begins: held_ms,
tops = operations the tenure served, lo_ms = last operation to this release,
qsrc = which path queued it) and P70-BP EXIT (the release is done), P-ACQ-LAT
(an acquire: mode, when it was asked, how long it took, rc) and P-BAST-RX (a
BAST reaching the holder), each with its realns wall time, and the loops'
operations from ops.<host>.  Prints one line per event, as seconds after T.
The two hosts' clocks are NTP-synchronised to within about a millisecond.
--stats prints instead, per host and inode, the duration of each kind of
release (begins to done) and of each kind of acquire (asked to granted).
"""
import re
import sys

KV = re.compile(r"(\w+)=(\S+)")


def main():
    args = sys.argv[1:]
    inos, lo, hi = [], -1e9, 1e9
    stats = "--stats" in args
    if stats:
        args.remove("--stats")
    while "--ino" in args:
        i = args.index("--ino")
        inos.append(args[i + 1])
        del args[i:i + 2]
    for k in ("--from", "--to"):
        if k in args:
            i = args.index(k)
            v = float(args[i + 1])
            del args[i:i + 2]
            if k == "--from":
                lo = v
            else:
                hi = v
    if len(args) < 3 or not inos:
        print(__doc__)
        return 2
    evid, t0, hosts = args[0], float(args[1]), args[2:]
    ev = []
    for spec in hosts:
        h, _, label = spec.partition("=")
        label = label or h
        for line in open(f"{evid}/klog.{h}", errors="replace"):
            if "P70-BP" not in line and "P-ACQ-LAT" not in line and "P-BAST-RX" not in line:
                continue
            d = dict(KV.findall(line))
            if d.get("ino") not in inos or "realns" not in d:
                continue
            t = int(d["realns"]) / 1e9 - t0
            if t < lo or t > hi:
                continue
            if "P-ACQ-LAT" in line:
                # an acquire: logged at its end, stamped with its start
                dur = int(d.get("dur_us", "0")) / 1e3
                ev.append((t, label, d["ino"], f"acquire mode={d.get('mode')} asked ({d.get('comm')})"))
                what = f"acquire mode={d.get('mode')} GRANTED after {dur:.1f} ms rc={d.get('rc')}"
                t += dur / 1e3
            elif "P-BAST-RX" in line:
                what = (f"BAST arrives want={d.get('want')} state={d.get('state')} mode={d.get('mode')} "
                        f"ex={d.get('ex')} pr={d.get('pr')} pin={d.get('pin')} bpend={d.get('bpend')}")
            elif " ENTRY " in line:
                what = (f"release begins mode={d.get('mode')} qsrc={d.get('qsrc')} held_ms={d.get('held_ms')} "
                        f"tops={d.get('tops')} lo_ms={d.get('lo_ms')} selfdem={d.get('selfdem')}")
            else:
                what = f"release done {line.split('EXIT=')[1].split()[0] if 'EXIT=' in line else ''}"
            ev.append((t, label, d["ino"], what))
        # the host's loop operations, when the run kept each iteration's start
        try:
            ops = open(f"{evid}/ops.{h}", errors="replace").read().splitlines()
        except OSError:
            ops = []
        for line in ops:
            f = line.split()
            if f[:1] != ["OPS"] or len(f) != 9:
                continue
            t = int(f[8]) / 1e6 - t0
            for name, us in zip(("append", "create", "rename", "remove", "sync"), f[3:8]):
                d = int(us) / 1e6
                if d > 0 and lo <= t <= hi and not (name == "sync" and d < 1e-5):
                    ev.append((t, label, f"loop{f[1]}", f"{name} it={f[2]} took {d * 1000:.1f} ms"))
                t += d
    ev.sort()
    if stats:
        # per host and inode: how long each kind of release took (begins to
        # done) and each kind of acquire (asked to granted), p50/p90/n
        def pct(v, p):
            v = sorted(v)
            return v[min(len(v) - 1, int(len(v) * p))] if v else 0.0
        rel, acq, open_rel = {}, {}, {}
        for t, label, ino, what in ev:
            if what.startswith("release begins"):
                d = dict(KV.findall(what))
                open_rel[(label, ino)] = (t, f"mode={d.get('mode')} qsrc={d.get('qsrc')} selfdem={d.get('selfdem')}")
            elif what.startswith("release done") and (label, ino) in open_rel:
                t1, kind = open_rel.pop((label, ino))
                rel.setdefault((label, ino, kind), []).append((t - t1) * 1000)
            elif "GRANTED after" in what:
                d = dict(KV.findall(what))
                ms = float(what.split("GRANTED after ")[1].split()[0])
                acq.setdefault((label, ino, f"mode={d.get('mode')} rc={d.get('rc')}"), []).append(ms)
        for name, table in (("release", rel), ("acquire", acq)):
            for (label, ino, kind), v in sorted(table.items()):
                print(f"{label:6s} ino={ino:<8s} {name} {kind:28s} n={len(v):5d} "
                      f"p50={pct(v, .5):7.1f} p90={pct(v, .9):7.1f} mean={sum(v) / len(v):7.1f} ms")
        return 0
    for t, label, ino, what in ev:
        print(f"{t:9.3f}  {label:6s} ino={ino:<8s} {what}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
