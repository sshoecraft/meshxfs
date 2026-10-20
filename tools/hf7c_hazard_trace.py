#!/usr/bin/env python3
"""hf7c_hazard_trace.py: what became of each allocator take under an
in-flight no-inode release (H-F7c of
D-FREED-INODE-HOME-NEVER-PUBLISHED-LIVE-CORE-AFTER-CLEAN-UNMOUNT).

The allocator prints P-DIALLOC-RESV-UNDER-NOINO (phase 1: a candidate
reserved, phase 2: a candidate taken) when a no-inode release of the number
is in flight at that moment, and P-DIALLOC-NOINO-SKIP when noino_resv_guard
gives the candidate up instead (xfs/libxfs/xfs_ialloc.c).  With the guard on,
phase 1 checks before its DLM probe and counts the hazard after it, so a
release that registers during the probe leaves a reserved candidate; phase 2
re-checks before its take.  For every hazard line this prints, from the same
node's kernel stream after the lap's mark:

  p2       what phase 2 did with a phase-1 hazard's number next (within
           P2_WINDOW s): skip2 (P-DIALLOC-NOINO-SKIP phase=2), under2 (taken
           with the release still in flight), lost (VALIDATED-LOST), none (no
           allocator line: taken after the release ended, or the create gave
           up without one).
  release  how the next no-inode release of the number ended (within
           REL_WINDOW s): live-skip (its live check met the new life and
           skipped), stale (unlock refused, a newer tenure), left-grant (it
           unlocked under a cached grant), undrained, gen0-live, or none (no
           line: an unlock with nothing in core caching a grant, or a release
           that ended before the hazard).
  harm     every P-LOG-MIRROR-PHANTOM, P-LOGWR-DLM-NOGRANT,
           P-NOINO-UNLOCK-LEFT-GRANT and P-NOINO-UNLOCK-UNDRAINED of the number
           within HARM_WINDOW s, with pub_inflight= where printed.

For each P-NOINO-UNLOCK-UNDRAINED, and each P-NOINO-UNLOCK-LEFT-GRANT with
lifecycle=LIVE cached_mode=5, it also prints the ATTRIBUTED check of
tests/queues/hf7c_resv_guard_ab.queue: whether a P-DIALLOC-RESV-UNDER-NOINO
of the number precedes it on the node inside that release (unlock time less
queue_ms + fence_ms + tail_ms; a LEFT-GRANT takes the window of the UNDRAINED
line the same release printed, else ATTR_DEFAULT_S), and the nearest one.

Per node it prints the line counts and each probe's print cap, so a count at
its cap reads as a floor, not a total.

Usage: tools/hf7c_hazard_trace.py <noino_gen0 lap evidence dir>...
"""
import glob
import gzip
import os
import re
import sys

P2_WINDOW = 2.0
REL_WINDOW = 5.0
HARM_WINDOW = 10.0
ATTR_DEFAULT_S = 10.0

TS = re.compile(r'^\[\s*(\d+\.\d+)\]')
KV = re.compile(r'(\w+)=(\S+)')

# probe -> per-load print cap (the source's atomic counters), for the floor note
CAPS = {
    'P-DIALLOC-RESV-UNDER-NOINO': 2000,
    'P-DIALLOC-NOINO-SKIP': 2000,
    'P-NOINO-LIVE-SKIP': 200,
    'P-NOINO-STALE-RELEASE': 200,
    'P-NOINO-UNLOCK-LEFT-GRANT': 2000,
    'P-NOINO-UNLOCK-UNDRAINED': 2000,
    'P-NOINO-GEN0-LIVE': 1000,
}
WANT = ('P-DIALLOC-RESV-UNDER-NOINO', 'P-DIALLOC-NOINO-SKIP', 'P-DIALLOC-VALIDATED-LOST',
        'P-NOINO-LIVE-SKIP', 'P-NOINO-STALE-RELEASE', 'P-NOINO-UNLOCK-LEFT-GRANT',
        'P-NOINO-UNLOCK-UNDRAINED', 'P-NOINO-GEN0-LIVE', 'P-LOG-MIRROR-PHANTOM',
        'P-LOGWR-DLM-NOGRANT')
RELEASE_END = {
    'P-NOINO-LIVE-SKIP': 'live-skip',
    'P-NOINO-STALE-RELEASE': 'stale',
    'P-NOINO-UNLOCK-LEFT-GRANT': 'left-grant',
    'P-NOINO-UNLOCK-UNDRAINED': 'undrained',
    'P-NOINO-GEN0-LIVE': 'gen0-live',
}
HARM = ('P-LOG-MIRROR-PHANTOM', 'P-LOGWR-DLM-NOGRANT', 'P-NOINO-UNLOCK-LEFT-GRANT',
        'P-NOINO-UNLOCK-UNDRAINED')


def probe_of(line):
    for p in WANT:
        if 'mxfs: ' + p + ' ' in line:
            return p
    return None


def events(path, mark):
    """(t, probe, kv, line) for every wanted line after the lap's mark."""
    out = []
    seen = False
    with gzip.open(path, 'rt', errors='replace') as f:
        for line in f:
            if not seen:
                seen = mark in line
                continue
            p = probe_of(line)
            if not p:
                continue
            m = TS.match(line)
            if not m:
                continue
            kv = dict(KV.findall(line.split('mxfs: ' + p + ' ', 1)[1]))
            out.append((float(m.group(1)), p, kv, line.rstrip('\n')))
    return seen, out


def first_after(ev, i, ino, t, window, probes, pred=None):
    for t2, p2, kv2, line2 in ev[i + 1:]:
        if t2 - t > window:
            return None
        if p2 in probes and kv2.get('ino') == ino and (pred is None or pred(p2, kv2)):
            return (t2, p2, kv2, line2)
    return None


def trace_node(label, node, ev):
    counts = {}
    for _, p, _, _ in ev:
        counts[p] = counts.get(p, 0) + 1
    tally = {}
    for i, (t, p, kv, line) in enumerate(ev):
        if p != 'P-DIALLOC-RESV-UNDER-NOINO':
            continue
        ino, phase = kv.get('ino'), kv.get('phase')
        p2 = '-'
        if phase == '1':
            hit = first_after(ev, i, ino, t, P2_WINDOW,
                              ('P-DIALLOC-NOINO-SKIP', 'P-DIALLOC-RESV-UNDER-NOINO',
                               'P-DIALLOC-VALIDATED-LOST'),
                              lambda pp, k: pp == 'P-DIALLOC-VALIDATED-LOST' or k.get('phase') == '2')
            if hit is None:
                p2 = 'none'
            elif hit[1] == 'P-DIALLOC-NOINO-SKIP':
                p2 = 'skip2@+%.4f' % (hit[0] - t)
            elif hit[1] == 'P-DIALLOC-VALIDATED-LOST':
                p2 = 'lost@+%.4f' % (hit[0] - t)
            else:
                p2 = 'under2@+%.4f' % (hit[0] - t)
        rel = first_after(ev, i, ino, t, REL_WINDOW, tuple(RELEASE_END))
        rels = 'none' if rel is None else '%s@+%.4f' % (RELEASE_END[rel[1]], rel[0] - t)
        harm = []
        for t2, pp, kv2, _ in ev[i + 1:]:
            if t2 - t > HARM_WINDOW:
                break
            if pp in HARM and kv2.get('ino') == ino:
                extra = ''
                if 'pub_inflight' in kv2:
                    extra = ' pub_inflight=' + kv2['pub_inflight']
                if 'lifecycle' in kv2:
                    extra += ' lifecycle=' + kv2['lifecycle'] + ' cached_mode=' + kv2.get('cached_mode', '?')
                harm.append('%s@+%.3f%s' % (pp, t2 - t, extra))
        key = (phase, p2.split('@')[0], rels.split('@')[0], 'harm' if harm else 'noharm')
        tally[key] = tally.get(key, 0) + 1
        print('%s %s HAZARD t=%.6f ino=%s phase=%s comm=%s p2=%s release=%s harm=%s' % (
            label, node, t, ino, phase, kv.get('comm', '?'), p2, rels,
            ','.join(harm) if harm else 'none'))
    # the queue's ATTRIBUTED check
    for i, (t, p, kv, line) in enumerate(ev):
        if p == 'P-NOINO-UNLOCK-UNDRAINED':
            win = sum(float(kv.get(k, '0')) for k in ('queue_ms', 'fence_ms', 'tail_ms')) / 1000.0
            what = 'UNDRAINED lifecycle=%s start=%s cached_mode=%s' % (
                kv.get('lifecycle'), kv.get('start_lifecycle'), kv.get('cached_mode'))
        elif p == 'P-NOINO-UNLOCK-LEFT-GRANT' and kv.get('lifecycle') == 'LIVE' and kv.get('cached_mode') == '5':
            nxt = first_after(ev, i, kv.get('ino'), t, 0.01, ('P-NOINO-UNLOCK-UNDRAINED',))
            if nxt:
                win = sum(float(nxt[2].get(k, '0')) for k in ('queue_ms', 'fence_ms', 'tail_ms')) / 1000.0
            else:
                win = ATTR_DEFAULT_S
            what = 'LEFT-GRANT lifecycle=LIVE cached_mode=5 rel_gen=%s' % kv.get('rel_gen')
        else:
            continue
        ino = kv.get('ino')
        prior = [(t0, kv0) for t0, p0, kv0, _ in ev[:i]
                 if p0 == 'P-DIALLOC-RESV-UNDER-NOINO' and kv0.get('ino') == ino and t0 <= t]
        inside = [x for x in prior if t - x[0] <= win]
        near = prior[-1] if prior else None
        print('%s %s ATTR %s ino=%s t=%.6f window=%.3fs attributed=%s nearest=%s' % (
            label, node, what, ino, t, win, 'yes' if inside else 'NO',
            'none' if near is None else 'phase=%s@-%.4f' % (near[1].get('phase'), t - near[0])))
    caps = ' '.join('%s=%d%s' % (p.replace('P-', '').lower(), counts.get(p, 0),
                                 '(AT CAP)' if p in CAPS and counts.get(p, 0) >= CAPS[p] else '')
                    for p in WANT)
    print('%s %s COUNTS %s' % (label, node, caps))
    return tally


def main(dirs):
    total = {}
    for d in dirs:
        d = d.rstrip('/')
        label = d.rsplit('_noino_gen0_', 1)[-1]
        mark = 'NOINO-GEN0-%s-' % label
        streams = sorted(glob.glob(os.path.join(d, '*_dmesg_stream.gz')))
        if not streams:
            print('%s: no <node>_dmesg_stream.gz' % d)
            continue
        for s in streams:
            node = os.path.basename(s)[:-len('_dmesg_stream.gz')]
            seen, ev = events(s, mark)
            if not seen:
                print('%s %s: NO MARK %s in the stream; not counted' % (label, node, mark))
                continue
            for k, v in trace_node(label, node, ev).items():
                total[k] = total.get(k, 0) + v
    print('TALLY phase p2 release harm: count')
    for k in sorted(total):
        print('TALLY %s %s %s %s: %d' % (k + (total[k],)))


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
