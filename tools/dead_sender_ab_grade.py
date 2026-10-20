#!/usr/bin/env python3
"""Grade path_fenced_return laps for a retired identity's lock traffic.

For each row evidence directory (tests/evidence/board_<run>_path_fenced_return,
on the host under /src/mxfs/tests/evidence) this reads the row's kept kernel
logs (kmsg_<node>_fromnode.gz), scoped to the lines after the row's own
PF-MARK, and prints one line per lap with the counts
tests/queues/dead_sender_drop_ab_netmesh_mpath.queue grades:

  survivor      the node that logged P-DEAD-INC for the fenced victim
  fenced        victim node id / incarnation (that P-DEAD-INC line)
  dead_connect  P164-DEAD-REJECT connect lines for the victim after its death
                note (the thawed old incarnation reconnected)
  zgrant        P74-GRANT lines after the death note whose grant id names the
                fenced incarnation as authority (its grant was processed)
  stale_own     P-TAUTH-OWN-REL-STALE with rel_auth = the fenced incarnation
  relex         P-TAUTH-REL-EX-STALE-HOLDER whose op auth = the fenced
                incarnation
  drops         P164-DEAD-MSG-DROP lines, with the message types
  passes        P164-DEAD-MSG-PASS lines (dl_dead_sender_drop=0: processed),
                with the message types
  double        P-TAUTH-DOUBLE-GRANT on each node, by the record's ex= holder:
                the survivor, the fenced victim, or another identity
  resync        P-TAUTH-OWN-REL-RESYNC on each node (dl_own_release_resync: a
                master-local EX release that took its record's identity)
  shadow        P-DOUBLEGRANT (the double-grant shadow's report) on each node,
                by owner_existing: the survivor, the fenced victim's node id
                (on the rejoined node: its own previous incarnation), or
                another identity; and P-DG-DESTROY-RELEASED lines
  p74           P74-GRANT lines in scope on the survivor (the probe stops at
                8000 per module load: near that, a zero zgrant is not evidence)

plus each node's 'lock request failed after' count, the knobs the row read
back (knobs.txt) and the row's RESULT.  Counts only: the queue's rules judge.

Per node, also the capacity and publish-claim counts the TCP page-full and
deferred-publish records are judged on:

  full          P-TAUTH-PAGE-FULL (a grant refused for a full ledger page)
  e122          lines carrying rc=-122 (-EDQUOT reaching a caller)
  unrec         'DLM inode lock unrecoverable' (the fail-fast shutdown), not
                counting the fenced victim's own withdrawal
  fenced        the fenced victim's withdrawal ('fenced off the shared storage')
  sdown         'Corruption of in-memory data' (any forced shutdown)
  park          P-CAP-PARK / P-CAP-PARK-EXPIRE (dl_capacity_park)
  claim         P-PUB-CLAIM-RETRY / P-PUB-CLAIM-RETRY-GRANTED / 'deferred-publish
                CAW EX failed' (pub_claim_retry: asked again / granted / dropped);
                cdrop leaves out rc=-108, a claim ended by its own node's
                shutdown (the fenced victim), which cdropdown counts with the rest

Usage: tools/dead_sender_ab_grade.py <row-evidence-dir> [...]
"""
import gzip
import os
import re
import sys

TS = re.compile(r'^\[\s*(\d+\.\d+)\]')
DEAD_INC = re.compile(r'P-DEAD-INC node=(\d+) inc=(\d+)')
DEAD_NOTE = re.compile(r'P164-DEAD-NOTE node=(\d+)')
DEAD_CONNECT = re.compile(r'P164-DEAD-REJECT connect node=(\d+)')
P74 = re.compile(r'P74-GRANT ino=(\d+) .*grant_id=\{(\d+),(\d+)\}')
OWN_STALE = re.compile(r'P-TAUTH-OWN-REL-STALE .*rel_auth=(\d+) ')
RELEX = re.compile(r'P-TAUTH-REL-EX-STALE-HOLDER .* op inc=\d+ auth=(\d+) ')
DROP = re.compile(r'P164-DEAD-MSG-DROP n=\d+ type=(\d+) from node (\d+)')
PASS = re.compile(r'P164-DEAD-MSG-PASS n=\d+ type=(\d+) from node (\d+)')
DOUBLE = re.compile(r'P-TAUTH-DOUBLE-GRANT .* vs record ex=(\d+)/(\d+)')
SHADOW = re.compile(r'P-DOUBLEGRANT ino=\d+ .*owner_existing=(\d+)')
DG_DESTROY = 'P-DG-DESTROY-RELEASED'
RESYNC = 'P-TAUTH-OWN-REL-RESYNC'
OWN_ID = re.compile(r'P-TAUTH-STORE-STATS why=\S+ node=(\d+)')
LRF = 'lock request failed after'
# (name, text the line carries, text that excludes it).  The fenced victim's
# own withdrawal also logs 'DLM inode lock unrecoverable ... rc=-108 ... this
# node was fenced off the shared storage': the row's intended fence, counted
# apart as 'fenced'.
FENCED_OFF = 'fenced off the shared storage'
CAPACITY = (
    ('full', 'P-TAUTH-PAGE-FULL ', None),
    ('e122', 'rc=-122', None),
    ('unrec', 'DLM inode lock unrecoverable', FENCED_OFF),
    ('fenced', FENCED_OFF, None),
    ('sdown', 'Corruption of in-memory data', None),
    ('park', 'P-CAP-PARK ', None),
    ('parkexp', 'P-CAP-PARK-EXPIRE ', None),
    ('cretry', 'P-PUB-CLAIM-RETRY ', None),
    ('cgrant', 'P-PUB-CLAIM-RETRY-GRANTED ', None),
    ('cdrop', 'deferred-publish CAW EX failed', 'rc=-108'),
    ('cdropdown', 'deferred-publish CAW EX failed ino=', None),
)


def ts_of(line):
    m = TS.match(line)
    return float(m.group(1)) if m else None


def scoped_lines(path, mark):
    try:
        with gzip.open(path, 'rt', errors='replace') as f:
            lines = f.read().splitlines()
    except OSError as e:
        return None, str(e)
    start = None
    for i, line in enumerate(lines):
        if mark in line:
            start = i
    if start is None:
        return None, 'no ' + mark
    return lines[start:], None


def grade(d):
    d = d.rstrip('/')
    base = os.path.basename(d)
    m = re.match(r'board_(.+)_path_fenced_return$', base)
    if not m:
        return '%s: not a path_fenced_return row directory' % d
    run = m.group(1)
    mark = 'PF-MARK-path_fenced_return-' + run
    nodes = sorted(f[len('kmsg_'):-len('_fromnode.gz')]
                   for f in os.listdir(d)
                   if f.startswith('kmsg_') and f.endswith('_fromnode.gz'))
    if not nodes:
        return '%s: no kmsg_<node>_fromnode.gz' % run
    logs = {}
    for n in nodes:
        lines, err = scoped_lines(os.path.join(d, 'kmsg_%s_fromnode.gz' % n), mark)
        if lines is None:
            return '%s: %s %s' % (run, n, err)
        logs[n] = lines
    survivor = victim = fenced_inc = None
    for n in nodes:
        for line in logs[n]:
            mm = DEAD_INC.search(line)
            if mm:
                survivor, victim, fenced_inc = n, mm.group(1), mm.group(2)
    if survivor is None:
        return '%s: no P-DEAD-INC in scope on %s (no death declared in this lap)' % (
            run, ','.join(nodes))
    own_id = None
    t_death = None
    for line in logs[survivor]:
        mm = OWN_ID.search(line)
        if mm and own_id is None:
            own_id = mm.group(1)
        mm = DEAD_NOTE.search(line)
        if mm and mm.group(1) == victim and t_death is None:
            t_death = ts_of(line)
    if t_death is None:
        for line in logs[survivor]:
            mm = DEAD_INC.search(line)
            if mm and mm.group(1) == victim:
                t_death = ts_of(line)
    dead_connect = zgrant = stale_own = relex = p74 = 0
    drop_types = {}
    zgrant_inos = set()
    for line in logs[survivor]:
        t = ts_of(line)
        if P74.search(line):
            p74 += 1
        if t is None or t_death is None or t < t_death:
            continue
        mm = DEAD_CONNECT.search(line)
        if mm and mm.group(1) == victim:
            dead_connect += 1
        mm = P74.search(line)
        if mm and mm.group(2) == fenced_inc:
            zgrant += 1
            zgrant_inos.add(mm.group(1))
        mm = OWN_STALE.search(line)
        if mm and mm.group(1) == fenced_inc:
            stale_own += 1
        mm = RELEX.search(line)
        if mm and mm.group(1) == fenced_inc:
            relex += 1
    pass_types = {}
    for line in logs[survivor]:
        mm = DROP.search(line)
        if mm:
            drop_types[mm.group(1)] = drop_types.get(mm.group(1), 0) + 1
        mm = PASS.search(line)
        if mm:
            pass_types[mm.group(1)] = pass_types.get(mm.group(1), 0) + 1
    doubles = []
    shadows = []
    resyncs = []
    lrf = []
    capacity = []

    def classify(holder):
        if own_id and holder == own_id:
            return 'survivor'
        if holder == victim:
            return 'fenced'
        return 'other'

    for n in nodes:
        cls = {'survivor': 0, 'fenced': 0, 'other': 0}
        scls = {'survivor': 0, 'fenced': 0, 'other': 0}
        destroyed = 0
        for line in logs[n]:
            mm = DOUBLE.search(line)
            if mm:
                cls[classify(mm.group(1))] += 1
            mm = SHADOW.search(line)
            if mm:
                scls[classify(mm.group(1))] += 1
            if DG_DESTROY in line:
                destroyed += 1
        doubles.append('%s:s%d/f%d/o%d' % (n, cls['survivor'], cls['fenced'], cls['other']))
        shadows.append('%s:s%d/f%d/o%d/destroy%d' % (n, scls['survivor'], scls['fenced'],
                                                     scls['other'], destroyed))
        resyncs.append('%s:%d' % (n, sum(1 for line in logs[n] if RESYNC in line)))
        lrf.append('%s:%d' % (n, sum(1 for line in logs[n] if LRF in line)))
        capacity.append('%s:%s' % (n, ','.join(
            '%s=%d' % (name, sum(1 for line in logs[n]
                                 if needle in line and not (unless and unless in line)))
            for name, needle, unless in CAPACITY)))
    knobs = ''
    kp = os.path.join(d, 'knobs.txt')
    if os.path.exists(kp):
        with open(kp, errors='replace') as f:
            knobs = ' '.join('%s:%s' % (p[0], p[3].replace('got=', ''))
                             for p in (l.split() for l in f) if len(p) >= 4)
    result = ''
    rp = os.path.join(d, 'row.log')
    if os.path.exists(rp):
        with open(rp, errors='replace') as f:
            for line in f:
                if line.startswith('RESULT:'):
                    result = line.split('|')[0].strip()
    def types(t):
        return ('(types ' + ','.join('%s:%d' % kv for kv in sorted(t.items())) + ')') if t else ''

    return ('%s survivor=%s(%s) fenced=%s/%s dead_connect=%d zgrant=%d%s stale_own=%d '
            'relex=%d drops=%d%s passes=%d%s double=[%s] shadow=[%s] resync=[%s] lrf=[%s] '
            'capacity=[%s] p74=%d knobs=[%s] %s') % (
        run, survivor, own_id or '?', victim, fenced_inc, dead_connect, zgrant,
        ('(inos ' + ','.join(sorted(zgrant_inos)[:6]) + ')') if zgrant_inos else '',
        stale_own, relex, sum(drop_types.values()), types(drop_types),
        sum(pass_types.values()), types(pass_types),
        ' '.join(doubles), ' '.join(shadows), ' '.join(resyncs), ' '.join(lrf),
        ' '.join(capacity), p74, knobs,
        result)


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[-1])
        return 2
    for d in argv[1:]:
        print(grade(d))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
