#!/usr/bin/env python3
"""hf7d_match.py: name each P-LOGWR-DLM-NOGRANT that rode a grant a free
release had already retired (H-F7d of
D-FREED-INODE-HOME-NEVER-PUBLISHED-LIVE-CORE-AFTER-CLEAN-UNMOUNT).

A free release (generation 0, from xfs_inactive's INACT-EXREL or from
mxfs_dlm_evict) prints P-FREE-RELEASE with the DLM's grant generation as it
goes (dlm_gen).  A NOGRANT prints the cached grant generation (cgen) of the
life whose logged core went home while the DLM recorded no EX of the node.  A
NOGRANT whose cgen equals the dlm_gen of an EARLIER P-FREE-RELEASE of the same
inode on the same node names the life that was riding the retired grant.  A
generation of 0 matches nothing: it is no grant.

Usage: tools/hf7d_match.py <lap evidence dir>...
Reads every <node>_hf7.txt in each directory (tests/noino_gen0_ab.sh keeps
both probes there, in kernel-log order) and prints one line per NOGRANT with
its verdict and the release it matched, a tally per node, and a total.
"""
import glob
import os
import re
import sys

KV = re.compile(r'(\w+)=(\S+)')


def fields(text):
    return dict(KV.findall(text))


def scan(path):
    released = {}
    nogrant = matched = 0
    out = []
    with open(path, errors='replace') as f:
        for line in f:
            if 'P-FREE-RELEASE ' in line:
                kv = fields(line.split('P-FREE-RELEASE ', 1)[1])
                if kv.get('dlm_gen', '0') != '0':
                    released.setdefault((kv.get('ino'), kv['dlm_gen']), line.strip())
            elif 'P-LOGWR-DLM-NOGRANT ' in line:
                kv = fields(line.split('P-LOGWR-DLM-NOGRANT ', 1)[1])
                nogrant += 1
                hit = released.get((kv.get('ino'), kv.get('cgen')))
                if hit:
                    matched += 1
                out.append('NOGRANT ino=%s cgen=%s img_gen=%s img_cc=%s reused=%s comm=%s -> %s' % (
                    kv.get('ino'), kv.get('cgen'), kv.get('img_gen'), kv.get('img_cc'),
                    kv.get('reused'), kv.get('comm'),
                    'H-F7d, after: ' + hit[:240] if hit else 'no earlier free release at that generation'))
    return nogrant, matched, out


def main(dirs):
    tn = tm = 0
    for d in dirs:
        files = sorted(glob.glob(os.path.join(d, '*_hf7.txt')))
        if not files:
            print('%s: no <node>_hf7.txt' % d)
            continue
        for path in files:
            node = os.path.basename(path)[:-len('_hf7.txt')]
            n, m, lines = scan(path)
            for line in lines:
                print('%s %s %s' % (d, node, line))
            print('%s %s: nogrant=%d matched_free_release=%d' % (d, node, n, m))
            tn += n
            tm += m
    print('TOTAL nogrant=%d matched_free_release=%d' % (tn, tm))


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
