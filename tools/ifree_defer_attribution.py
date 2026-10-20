#!/usr/bin/env python3
"""ifree_defer_attribution.py -- attribute a cold audit's unlinked-bucket zombies
and fork-ownership errors to deferred inode frees, and grade the
ifree_defer_drain / ifree_defer_reap A/B of
D-INACT-DEFERRED-FREE-LOSES-TRUNCATED-CORE-AND-REAP-AUTHORITY.

An audited inode is one the lap's cold audit (chk_audit.log, the audit's own
chk_mxfs output) lists as a member of an AGI unlinked bucket, or names in a
fork-ownership ERROR line (a block a second fork names, a FREE block, a block
inside an inode chunk).  It is attributed when a deferral of its free --
P-UNLPRE-SKIP (the unlinked-list preflight) or P-UNLPREV-DEFER (the
predecessor's hold) -- names it in some node's kernel log after the lap's mark.

Each node's log is <node>_dmesg_stream.gz in the lap directory; only lines
after the last line carrying the lap's mark count (default mark: the
tests/noino_gen0_ab.sh one, NOINO-GEN0-<label>-, the label read from the
directory name).

The reap worker's failed lookups (P88-REAP-IGET-FAIL, H-3 of the same record)
are counted per node: igetfail all of them, transient those that met the
entry's zombie still in core in its inactivation, kept those of them the worker
kept for its next pass (reap_transient_keep 1), retired_transient those it
retired (the control).  An audited zombie whose entry a transient failure
retired is marked retired_transient=1; zombie_retired_transient counts them.

Usage: tools/ifree_defer_attribution.py <lap evidence dir> [mark]
Prints one line per audited inode, one line per node, and a closing tally:
  IFDEFER audited=N attributed=M unattributed=K zombies=Z fork_errors=F
          reach=R preflight=P prevdefer=D dirty=X drained=Y undrained=U
          drain_arm=<0|1|mixed|none> fatal=E reaps=S reap_done=T
          igetfail=G transient=I kept=J retired_transient=Q
          zombie_retired_transient=W
Exit 0 when every audited inode is attributed (or none was audited), 1 when
any is not, 2 on bad input.
"""
import glob
import gzip
import os
import re
import sys

MEMBER = re.compile(r'unlinked bucket (\d+): member ino=(\d+) agino=(\d+) mode=(\d+) nlink=(\d+)')
FORK2 = re.compile(r'ERROR: AG \d+ block \d+ is named by a second fork \(inode (\d+) ')
FORKX = re.compile(r'ERROR: inode (\d+) data fork names AG \d+ block \d+, which ')
TS = re.compile(r'^\[\s*(\d+\.\d+)\]')
PRE = re.compile(r'P-UNLPRE-SKIP ino=(\d+) ')
PREV = re.compile(r'P-UNLPREV-DEFER ino=(\d+) ')
DIRTY = re.compile(r'P-IFREE-DEFER-DIRTY ino=(\d+) .* drain=(\d) drained=(\d) fatal=(\d) ')
FATAL = re.compile(r'P-IFREE-DEFER-UNLANDED-FATAL ino=(\d+) ')
REAP = re.compile(r'P88-REAP-RETRY ino=(\d+) ')
DONE = re.compile(r'P89-REAP-DONE ino=(\d+)')
IGETFAIL = re.compile(r'P88-REAP-IGET-FAIL ino=(\d+) .* transient=(\d) keep=(\d)')


def node_events(path, mark):
    """events after the last mark line: {kind: {ino: [ts, ...]}}, plus counts"""
    lines = []
    with gzip.open(path, 'rt', errors='replace') as f:
        for line in f:
            lines.append(line)
    start = 0
    for i, line in enumerate(lines):
        if mark in line:
            start = i + 1
    ev = {'pre': {}, 'prev': {}, 'reap': {}, 'done': {}, 'fatal': {},
          'igetfail': {}, 'transient': {}, 'kept': {}, 'retired_transient': {}}
    dirty = []      # (ino, drain, drained, fatal)
    for line in lines[start:]:
        if 'P-UNLPRE' not in line and 'P-UNLPREV' not in line and \
           'P-IFREE-DEFER' not in line and 'REAP' not in line:
            continue
        t = TS.search(line)
        ts = float(t.group(1)) if t else 0.0
        m = IGETFAIL.search(line)
        if m:
            ino = int(m.group(1))
            ev['igetfail'].setdefault(ino, []).append(ts)
            if m.group(2) == '1':
                ev['transient'].setdefault(ino, []).append(ts)
                kind = 'kept' if m.group(3) == '1' else 'retired_transient'
                ev[kind].setdefault(ino, []).append(ts)
            continue
        for kind, rx in (('pre', PRE), ('prev', PREV), ('reap', REAP),
                         ('done', DONE), ('fatal', FATAL)):
            m = rx.search(line)
            if m:
                ev[kind].setdefault(int(m.group(1)), []).append(ts)
                break
        m = DIRTY.search(line)
        if m:
            dirty.append((int(m.group(1)), int(m.group(2)), int(m.group(3)),
                          int(m.group(4))))
    return start > 0, ev, dirty


def main():
    if len(sys.argv) < 2:
        print('usage: tools/ifree_defer_attribution.py <lap evidence dir> [mark]')
        return 2
    lap = sys.argv[1].rstrip('/')
    if len(sys.argv) > 2:
        mark = sys.argv[2]
    else:
        m = re.search(r'_noino_gen0_([^/]+)$', lap)
        if not m:
            print('ifree_defer_attribution: no label in %s; pass the mark' % lap)
            return 2
        mark = 'NOINO-GEN0-%s-' % m.group(1)
    alog = os.path.join(lap, 'chk_audit.log')
    streams = sorted(glob.glob(os.path.join(lap, '*_dmesg_stream.gz')))
    if not os.path.exists(alog) or not streams:
        print('ifree_defer_attribution: need %s and <node>_dmesg_stream.gz' % alog)
        return 2
    zombies = {}
    forks = set()
    with open(alog, errors='replace') as f:
        for line in f:
            m = MEMBER.search(line)
            if m:
                zombies[int(m.group(2))] = (int(m.group(1)), m.group(4), int(m.group(5)))
                continue
            for rx in (FORK2, FORKX):
                m = rx.search(line)
                if m:
                    forks.add(int(m.group(1)))
    audited = sorted(set(zombies) | forks)
    per_node = {}
    for s in streams:
        node = os.path.basename(s)[:-len('_dmesg_stream.gz')]
        per_node[node] = node_events(s, mark)
    attributed = unattributed = zombie_rt = 0
    for ino in audited:
        hits = []
        rts = []
        for node, (_, ev, _) in per_node.items():
            for kind in ('pre', 'prev'):
                for ts in ev[kind].get(ino, []):
                    hits.append('%s:%s@%.6f' % (node, kind, ts))
            for ts in ev['retired_transient'].get(ino, []):
                rts.append('%s@%.6f' % (node, ts))
        what = []
        if ino in zombies:
            what.append('zombie bucket=%d mode=%s nlink=%d' % zombies[ino])
            what.append('retired_transient=%d' % (1 if rts else 0))
            if rts:
                zombie_rt += 1
                what.append('retired_at=%s' % ','.join(rts))
        if ino in forks:
            what.append('fork-error')
        if hits:
            attributed += 1
            print('ATTRIBUTED ino=%d %s deferrals=%s' % (ino, ' '.join(what), ','.join(hits)))
        else:
            unattributed += 1
            print('UNATTRIBUTED ino=%d %s -- no P-UNLPRE-SKIP or P-UNLPREV-DEFER names it after the mark' %
                  (ino, ' '.join(what)))
    tot = {'pre': 0, 'prev': 0, 'reap': 0, 'done': 0, 'fatal': 0,
           'igetfail': 0, 'transient': 0, 'kept': 0, 'retired_transient': 0}
    dirty = drained = undrained = 0
    arms = set()
    for node, (marked, ev, dl) in sorted(per_node.items()):
        n = {k: sum(len(v) for v in ev[k].values()) for k in tot}
        for k in tot:
            tot[k] += n[k]
        nd = len(dl)
        ndr = sum(1 for _, dr, ok, _ in dl if dr == 1 and ok == 1)
        nun = sum(1 for _, dr, ok, _ in dl if dr == 1 and ok == 0)
        arms.update(dr for _, dr, _, _ in dl)
        dirty += nd
        drained += ndr
        undrained += nun
        print('NODE %s marked=%d preflight=%d prevdefer=%d dirty=%d drained=%d undrained=%d fatal=%d reaps=%d reap_done=%d igetfail=%d transient=%d kept=%d retired_transient=%d' %
              (node, 1 if marked else 0, n['pre'], n['prev'], nd, ndr, nun,
               n['fatal'], n['reap'], n['done'], n['igetfail'],
               n['transient'], n['kept'], n['retired_transient']))
    arm = 'none' if not arms else ('mixed' if len(arms) > 1 else str(arms.pop()))
    print('IFDEFER audited=%d attributed=%d unattributed=%d zombies=%d fork_errors=%d '
          'reach=%d preflight=%d prevdefer=%d dirty=%d drained=%d undrained=%d '
          'drain_arm=%s fatal=%d reaps=%d reap_done=%d igetfail=%d transient=%d '
          'kept=%d retired_transient=%d zombie_retired_transient=%d' %
          (len(audited), attributed, unattributed, len(zombies), len(forks),
           tot['pre'] + tot['prev'], tot['pre'], tot['prev'], dirty, drained,
           undrained, arm, tot['fatal'], tot['reap'], tot['done'],
           tot['igetfail'], tot['transient'], tot['kept'],
           tot['retired_transient'], zombie_rt))
    return 0 if unattributed == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
