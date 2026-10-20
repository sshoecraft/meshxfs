#!/usr/bin/env python3
"""offcpu_families.py -- sum a bpftrace stack map into named stack families.

tests/tcp_rsync_offcpu.sh and its kin print maps keyed by kernel stack
(`@off_us[ <frames> ]: <value>`), cut to their N largest entries.  A
hypothesis about where the time went names families of stacks ("the reserve's
retry sleeps: msleep called from dlm_lock_retries_impl called from
mxfs_v5_dlm_inode_reserve_try"); this sums each family the same way for every
pass, so passes are compared by one instrument instead of by hand.

Usage:
  tools/offcpu_families.py <offcpu.txt> [<offcpu.txt>...] [--map off_us]
      [--total off_total_us] [--family NAME=CHAIN]... [--dump]

  CHAIN is frame-name regexes joined by '<', leaf first, each one a caller of
  the one before it (not necessarily its direct caller):
      --family 'retry=msleep<dlm_lock_retries_impl<mxfs_v5_dlm_inode_reserve_try'
  A regex must match a whole function name (the '+offset' is dropped).  A
  stack goes to the FIRST family whose chain it contains, so order the
  families from most to least specific.  Stacks matching none are 'other'.

  The denominator is the scalar named by --total (the map's full sum as the
  probe kept it); the printed entries sum to less when the map was cut, and
  that remainder is reported as 'unprinted' rather than spread over families.

  --dump prints each printed stack's value and frames (leaf first) instead.
"""
import re
import sys


def parse(path, mapname):
    """Return ({stack tuple: value} for mapname, {scalar name: value})."""
    stacks = {}
    scalars = {}
    open_re = re.compile(r'^@' + re.escape(mapname) + r'\[\s*$')
    scalar_re = re.compile(r'^@([A-Za-z0-9_]+):\s*(-?\d+)\s*$')
    frames = None
    with open(path, errors='replace') as f:
        for line in f:
            line = line.rstrip('\n')
            if frames is None:
                if open_re.match(line):
                    frames = []
                    continue
                m = scalar_re.match(line)
                if m:
                    scalars[m.group(1)] = int(m.group(2))
                continue
            m = re.match(r'^\]:\s*(-?\d+)\s*$', line)
            if m:
                key = tuple(frames)
                stacks[key] = stacks.get(key, 0) + int(m.group(1))
                frames = None
                continue
            fr = line.strip()
            if fr:
                frames.append(fr.split('+')[0])
    return stacks, scalars


def chain_match(frames, chain):
    """True if the regexes of chain appear in frames in order, leaf first."""
    i = 0
    for rx in chain:
        while i < len(frames) and not rx.fullmatch(frames[i]):
            i += 1
        if i == len(frames):
            return False
        i += 1
    return True


def main(argv):
    paths, families, mapname, total, dump = [], [], 'off_us', 'off_total_us', False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--map':
            mapname = argv[i + 1]; i += 2; continue
        if a == '--total':
            total = argv[i + 1]; i += 2; continue
        if a == '--family':
            name, chain = argv[i + 1].split('=', 1)
            families.append((name, [re.compile(c) for c in chain.split('<')]))
            i += 2; continue
        if a == '--dump':
            dump = True; i += 1; continue
        if a.startswith('-'):
            sys.exit(__doc__)
        paths.append(a); i += 1
    if not paths:
        sys.exit(__doc__)
    for path in paths:
        stacks, scalars = parse(path, mapname)
        printed = sum(stacks.values())
        denom = scalars.get(total)
        print('== %s  map=@%s entries=%d printed_sum=%d %s=%s'
              % (path, mapname, len(stacks), printed, total,
                 denom if denom is not None else 'ABSENT'))
        if dump:
            for key, v in sorted(stacks.items(), key=lambda kv: -kv[1]):
                print('%10d  %s' % (v, ' < '.join(key)))
            continue
        sums = {name: [0, 0] for name, _ in families}
        sums['other'] = [0, 0]
        for key, v in stacks.items():
            for name, chain in families:
                if chain_match(key, chain):
                    break
            else:
                name = 'other'
            sums[name][0] += v
            sums[name][1] += 1
        base = denom if denom else printed
        for name in [n for n, _ in families] + ['other']:
            us, n = sums[name]
            print('  %-14s %12d us  %6.2f s  %5.1f%%  stacks=%d'
                  % (name, us, us / 1e6, 100.0 * us / base if base else 0, n))
        if denom is not None:
            rest = denom - printed
            print('  %-14s %12d us  %6.2f s  %5.1f%%  (beyond the printed entries)'
                  % ('unprinted', rest, rest / 1e6, 100.0 * rest / denom if denom else 0))


if __name__ == '__main__':
    main(sys.argv[1:])
