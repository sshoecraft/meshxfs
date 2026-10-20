#!/usr/bin/env python3
"""nextwr_stale_attribution.py -- classify each P-NEXTWR-STALE line of a lap.

P-NEXTWR-STALE (xfs/xfs_inode.c, the cluster-write merge) is the H-U4 detector
of D-PEER-OPEN-UNLINKED-CHAIN-REMOVE-FAILS-IFREE-SHUTDOWN-BOTH-NODES: a slot
this node writes carries a di_next_unlinked other than the platter's, for the
same generation, and mxfs_iunl_store_live() finds no record of this node
committing it.  The detector's premise is that only another node's remove can
make the two differ.  It has one known exception, proven on lap pfd1:

  OWN-FREE-RESET  the slot is an inode THIS node removed from its unlinked list
                  in the transaction that freed it.  The remove logs the
                  inode's own next as NULLAGINO (xfs/libxfs/xfs_inode_util.c,
                  xfs_iunlink_remove_inode), and the precommit records that
                  store under VFS_I(ip)->i_generation, which xfs_inode_uninit
                  has already bumped by one; the buffer's dinode keeps the old
                  generation until the free image is copied in, so a cluster
                  write in between finds no record for the buffer's generation.
                  Signature: buf_next=0xffffffff, and the same node's same write
                  logs P-LOGWR-INCARN-MISMATCH for that ino and daddr with
                  incore_gen = gen+1 and incore_mode=00, or a P55C-FREE-FLUSH of
                  gen+1 follows within the window.

Every other line is UNEXPLAINED and stays the detector's finding.

Usage: tools/nextwr_stale_attribution.py <lap evidence dir> [mark] [window_ms]
Reads every <node>_dmesg_stream.gz in the lap directory, from the line after
the last one carrying the lap's mark (a node's stream also holds the laps
before it; default mark: tests/peer_open_unlinked_chain.sh's,
PEER-OPEN-UNLINKED-<label>-, the label read from the directory name).  Prints
one line per P-NEXTWR-STALE and a closing tally:
  NEXTWR lines=N own_free_reset=F unexplained=U
Exit 0 when every line is explained (or there is none), 1 when any is not,
2 on bad input.
"""
import glob
import gzip
import os
import re
import sys

TS = re.compile(r'^\[\s*(\d+\.\d+)\]')
STALE = re.compile(r'P-NEXTWR-STALE ino=(\d+) slot=(\d+) buf_next=(0x[0-9a-f]+) '
                   r'disk_next=(0x[0-9a-f]+) gen=(\d+) ')
INCARN = re.compile(r'P-LOGWR-INCARN-MISMATCH daddr=(\d+) slot=(\d+) ino=(\d+) '
                    r'img_gen=(\d+) .*incore_gen=(\d+) incore_mode=(\d+) ')
FREEFL = re.compile(r'P55C-FREE-FLUSH ino=(\d+) gen=(\d+) ')


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    lap = sys.argv[1].rstrip('/')
    if len(sys.argv) > 2:
        mark = sys.argv[2]
    else:
        m = re.search(r'_peer_open_unlinked_([^/]+)$', lap)
        if not m:
            print('nextwr_stale_attribution: no label in %s; pass the mark' % lap)
            return 2
        mark = 'PEER-OPEN-UNLINKED-%s-' % m.group(1)
    window = (float(sys.argv[3]) if len(sys.argv) > 3 else 100.0) / 1000.0
    streams = sorted(glob.glob(os.path.join(lap, '*_dmesg_stream.gz')))
    if not streams:
        print('nextwr_stale_attribution: no <node>_dmesg_stream.gz in %s' % lap)
        return 2
    total = own = unexplained = 0
    for s in streams:
        node = os.path.basename(s)[:-len('_dmesg_stream.gz')]
        stale, incarn, freefl = [], [], []
        with gzip.open(s, 'rt', errors='replace') as f:
            lines = f.readlines()
        start = 0
        for i, line in enumerate(lines):
            if mark in line:
                start = i + 1
        if not start:
            print('NOMARK %s: no line carries %s; the whole stream is read' % (node, mark))
        for line in lines[start:]:
            if 'P-NEXTWR-STALE' not in line and \
               'P-LOGWR-INCARN-MISMATCH' not in line and \
               'P55C-FREE-FLUSH' not in line:
                continue
            t = TS.search(line)
            ts = float(t.group(1)) if t else 0.0
            m = STALE.search(line)
            if m:
                stale.append((ts, int(m.group(1)), int(m.group(2)),
                              m.group(3), m.group(4), int(m.group(5))))
                continue
            m = INCARN.search(line)
            if m:
                incarn.append((ts, int(m.group(3)), int(m.group(2)),
                               int(m.group(4)), int(m.group(5)),
                               m.group(6)))
                continue
            m = FREEFL.search(line)
            if m:
                freefl.append((ts, int(m.group(1)), int(m.group(2))))
        for ts, ino, slot, bnext, dnext, gen in stale:
            total += 1
            why = []
            if bnext == '0xffffffff':
                for its, iino, islot, igen, cgen, cmode in incarn:
                    if iino == ino and islot == slot and igen == gen and \
                       cgen == gen + 1 and cmode == '00' and \
                       0 <= its - ts <= window:
                        why.append('incarn-mismatch@%.6f' % its)
                        break
                for fts, fino, fgen in freefl:
                    if fino == ino and fgen == gen + 1 and 0 <= fts - ts <= window:
                        why.append('free-flush@%.6f' % fts)
                        break
            if why:
                own += 1
                print('OWN-FREE-RESET %s ino=%d slot=%d buf_next=%s disk_next=%s gen=%d at=%.6f by=%s' %
                      (node, ino, slot, bnext, dnext, gen, ts, ','.join(why)))
            else:
                unexplained += 1
                print('UNEXPLAINED %s ino=%d slot=%d buf_next=%s disk_next=%s gen=%d at=%.6f' %
                      (node, ino, slot, bnext, dnext, gen, ts))
    print('NEXTWR lines=%d own_free_reset=%d unexplained=%d' % (total, own, unexplained))
    return 0 if unexplained == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
