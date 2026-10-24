#!/usr/bin/env python3
"""Per-prep step timings from run.sh prep_cluster logs.

usage: prep_step_stats.py FILE [FILE ...]

Parses `--- prep: N node(s) [...] configuration=X` headers and the
`PREP STEP <name> start +<N>s: <what>` / `PREP STEP <name> end <M>s` lines
(run.sh prep_step).  One file may hold several preps; each header opens one.
Total seconds = last step's start offset + that step's end seconds.
Prints every prep, then median/max per (node count, configuration) and per
node count, then every prep whose total or any step exceeds twice the median
for the same node count (all configurations pooled), with the verbatim
start and end lines and their file:line.
"""
import re
import statistics
import sys
from collections import defaultdict

HDR = re.compile(r'^--- prep: (\d+) node\(s\) \[.*?\] configuration=(\S+)')
START = re.compile(r'^PREP STEP (\S+) start \+(\d+)s: ')
END = re.compile(r'^PREP STEP (\S+) end (\d+)s\s*$')

preps = []
for path in sys.argv[1:]:
    cur = None
    with open(path, errors='replace') as fh:
        for ln, raw in enumerate(fh, 1):
            line = raw.rstrip('\n')
            m = HDR.match(line)
            if m:
                cur = {'file': path, 'hdr': ln, 'n': int(m.group(1)), 'cfg': m.group(2),
                       'steps': {}, 'order': []}
                preps.append(cur)
                continue
            m = START.match(line)
            if m:
                if cur is None:
                    cur = {'file': path, 'hdr': 0, 'n': None, 'cfg': None, 'steps': {}, 'order': []}
                    preps.append(cur)
                name = m.group(1)
                cur['steps'][name] = {'off': int(m.group(2)), 'sl': ln, 'st': line,
                                      'secs': None, 'el': None, 'et': None}
                cur['order'].append(name)
                continue
            m = END.match(line)
            if m and cur is not None and m.group(1) in cur['steps']:
                s = cur['steps'][m.group(1)]
                s['secs'] = int(m.group(2)); s['el'] = ln; s['et'] = line

for p in preps:
    last = p['steps'][p['order'][-1]] if p['order'] else None
    p['total'] = last['off'] + last['secs'] if last and last['secs'] is not None else None
    p['complete'] = bool(last and last['secs'] is not None)

print(f"preps found: {len(preps)} in {len(set(p['file'] for p in preps))} files")
print("\n== every prep (file | hdr line | nodes | configuration | total s | steps name=secs)")
for p in preps:
    st = ' '.join(f"{k}={p['steps'][k]['secs']}" for k in p['order'])
    print(f"{p['file']} | L{p['hdr']} | {p['n']} | {p['cfg']} | total={p['total']} | {st}")

def stat(vals):
    return statistics.median(vals), max(vals), len(vals)

def table(keyfn, title):
    g = defaultdict(list)
    for p in preps:
        if p['total'] is not None:
            g[keyfn(p)].append(p)
    print(f"\n== {title}")
    for key in sorted(g, key=str):
        ps = g[key]
        print(f"-- {key}: {len(ps)} preps")
        names = []
        for p in ps:
            for k in p['order']:
                if k not in names:
                    names.append(k)
        for k in sorted(names):
            v = [p['steps'][k]['secs'] for p in ps if k in p['steps'] and p['steps'][k]['secs'] is not None]
            if v:
                md, mx, c = stat(v)
                print(f"   step {k}: median={md} max={mx} n={c}")
        md, mx, c = stat([p['total'] for p in ps])
        print(f"   TOTAL: median={md} max={mx} n={c}")

table(lambda p: (p['n'], p['cfg']), "median/max per (node count, configuration)")
table(lambda p: p['n'], "median/max per node count (configurations pooled; this is the outlier baseline)")

print("\n== outliers: value > 2 x median of the same step among preps with the same node count")
byn = defaultdict(list)
for p in preps:
    byn[p['n']].append(p)
count = 0
for p in preps:
    grp = byn[p['n']]
    tot = [q['total'] for q in grp if q['total'] is not None]
    if p['total'] is not None and tot:
        md = statistics.median(tot)
        if p['total'] > 2 * md:
            count += 1
            print(f"OUTLIER total: {p['file']} (hdr L{p['hdr']}) total={p['total']}s > 2 x median {md}s (n={len(tot)})")
    for k in p['order']:
        s = p['steps'][k]
        v = [q['steps'][k]['secs'] for q in grp if k in q['steps'] and q['steps'][k]['secs'] is not None]
        if s['secs'] is None or not v:
            continue
        md = statistics.median(v)
        if s['secs'] > 2 * md:
            count += 1
            print(f"OUTLIER step {k}: {p['file']} secs={s['secs']}s > 2 x median {md}s (n={len(v)} preps, nodes={p['n']})")
            print(f"    {p['file']}:{s['sl']}: {s['st']}")
            print(f"    {p['file']}:{s['el']}: {s['et']}")
print(f"\noutlier lines listed: {count}; preps: {len(preps)}")
