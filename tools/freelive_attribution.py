#!/usr/bin/env python3
"""freelive_attribution.py -- attribute a cold audit's P-FREE-LIVE-CORE inodes
to the unlinker's peer-freed inactivations of a tests/peer_last_closer_ab.sh lap.

D-FREED-INODE-HOME-NEVER-PUBLISHED-LIVE-CORE-AFTER-CLEAN-UNMOUNT, hypothesis
H-F6b (tests/queues/fi_relflush_copyin_ab.queue): an audited inode is
attributed to that mechanism when its LIVE core's generation is a life the
unlinker's BAST worker judged peer-freed (P-INACT-LOCAL-EPOCH verdict=peer-freed
by a kworker) and then drained through the AIL with the RELFLUSH token set
(P-INACT-RELFLUSH-HOLD landed=1), with no reload of the number in between
(P116-ZOMBIE-ADOPT / P103-RELOAD-REUSE-ADOPT).

The audit's ERROR lines come from the lap's chk_audit.log (the cold audit's own
chk_mxfs output; chk.log is run.sh's summary and does not carry them); the
unlinker's kernel log is <node>_dmesg_stream.gz.

Usage: tools/freelive_attribution.py <lap evidence dir> [unlinker node=test1]
Prints one line per audited inode and a closing tally:
  ATTRIB audited=N attributed=M unattributed=K reloaded=R
Exit 0 when every audited inode is attributed, 1 otherwise, 2 on bad input.
"""
import gzip
import os
import re
import sys

AUDIT = re.compile(r'inobt-FREE agino (\d+) \(ino (\d+)\) has a LIVE core \(mode (\d+), nlink (\d+), gen (\d+)')
EPOCH = re.compile(r'P-INACT-LOCAL-EPOCH ino=(\d+) gen=(\d+) .*verdict=(\S+) .*comm=(\S+)')
HOLD = re.compile(r'P-INACT-RELFLUSH-HOLD ino=(\d+) gen=(\d+) .*landed=(\d+)')
RELOAD = re.compile(r'(P116-ZOMBIE-ADOPT|P103-RELOAD-REUSE-ADOPT)\S* .*ino=(\d+)\b')
TS = re.compile(r'^\[\s*(\d+\.\d+)\]')


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip().splitlines()[-6])
        return 2
    lap = sys.argv[1]
    node = sys.argv[2] if len(sys.argv) > 2 else 'test1'
    alog = os.path.join(lap, 'chk_audit.log')
    stream = os.path.join(lap, node + '_dmesg_stream.gz')
    if not os.path.exists(alog) or not os.path.exists(stream):
        print('freelive_attribution: need %s and %s' % (alog, stream))
        return 2
    audited = []
    with open(alog, errors='replace') as f:
        for line in f:
            m = AUDIT.search(line)
            if m:
                audited.append((int(m.group(2)), int(m.group(5)), m.group(3), int(m.group(4))))
    want = {ino for ino, _, _, _ in audited}
    peerfreed = {}   # (ino, gen) -> (ts, comm)
    holds = {}       # (ino, gen) -> (ts, landed)
    reloads = {}     # ino -> [ts]
    with gzip.open(stream, 'rt', errors='replace') as f:
        for line in f:
            if 'P-INACT' not in line and 'ADOPT' not in line:
                continue
            t = TS.search(line)
            ts = float(t.group(1)) if t else 0.0
            m = EPOCH.search(line)
            if m and int(m.group(1)) in want and m.group(3) == 'peer-freed':
                peerfreed[(int(m.group(1)), int(m.group(2)))] = (ts, m.group(4))
                continue
            m = HOLD.search(line)
            if m and int(m.group(1)) in want:
                holds[(int(m.group(1)), int(m.group(2)))] = (ts, int(m.group(3)))
                continue
            m = RELOAD.search(line)
            if m and int(m.group(2)) in want:
                reloads.setdefault(int(m.group(2)), []).append(ts)
    attributed = unattributed = reloaded = 0
    for ino, gen, mode, nlink in audited:
        pf = peerfreed.get((ino, gen))
        hd = holds.get((ino, gen))
        why = []
        if not pf:
            why.append('no peer-freed verdict for this generation')
        elif not pf[1].startswith('kworker'):
            why.append('verdict not in a kworker (comm=%s)' % pf[1])
        if not hd:
            why.append('no relflush hold for this generation')
        elif hd[1] != 1:
            why.append('hold landed=%d' % hd[1])
        rl = []
        if pf and hd:
            rl = [t for t in reloads.get(ino, []) if pf[0] <= t <= hd[0]]
            if rl:
                why.append('reloaded between verdict and hold')
                reloaded += 1
        if why:
            unattributed += 1
            print('UNATTRIBUTED ino=%d gen=%d mode=%s nlink=%d -- %s' % (ino, gen, mode, nlink, '; '.join(why)))
        else:
            attributed += 1
            print('ATTRIBUTED ino=%d gen=%d mode=%s nlink=%d verdict_ts=%.6f comm=%s hold_ts=%.6f' %
                  (ino, gen, mode, nlink, pf[0], pf[1], hd[0]))
    print('ATTRIB audited=%d attributed=%d unattributed=%d reloaded=%d' %
          (len(audited), attributed, unattributed, reloaded))
    return 0 if audited and unattributed == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
