#!/usr/bin/env python3
"""Follow every P-DIALLOC-RESV-UNDER-NOINO line of a noino_gen0 lap forward in its node's stream.

Input:  EVID/<DIR>/<NODE>_dmesg_stream.gz   kernel log, lines "[ secs.usecs] text"
        EVID/<DIR>/<NODE>_hf7.txt           its first/last timestamped line bound the lap's window
        EVID/<DIR>/<NODE>_kmsg.txt          the lap's own sysctl counters
Output: OUTDIR/report.txt    phase table, per-instance rows of the detail arm, verbatim windows
                             (window lines cut at the first " -- " and at --width), summaries
        OUTDIR/rows.tsv      every instance row of every lap, own set or not
        OUTDIR/windows.txt   the same verbatim windows with uncut lines
        OUTDIR/step3_bc.txt  the windows' headers, counts and B/C parts only (P-NOINO-/P977/P4L-
                             lines, P-DIALLOC- lines), cut like report.txt

usage:
  noino_resv_followup.py EVID OUTDIR --lap LABEL:ARM:DIR:NODE[,NODE...] [--lap ...]
      [--detail-arm ARM] [--per-lap N] [--cap N] [--width N] [--jobs N]

Every quantity is computed on the instance's own node stream:
  instance      a line containing P-DIALLOC-RESV-UNDER-NOINO
  same ino      a token "ino=<v>" not preceded by [A-Za-z0-9_], <v> decimal or 0x-hex, equal to
                the instance's ino (parent_ino=, dir_ino=, agino= and the like do not count)
  after it      a line of the same boot segment with t0 <= t <= t0 + W that follows the instance
                in stream order, or precedes it with t0 < t <= t0 + W
  boot segment  a timestamp more than 1 s below the running maximum starts a new one
  region        pre / in / post = before / inside / after the hf7.txt kernel-time range
  twin          another stream of the same node, given on this command line, holding the
                identical instance line (same timestamp and text)
  own set       region in or post (or no hf7 / no timestamp), or region pre with no twin
  b             first P-DIALLOC-NOINO-SKIP phase=2 line of the same ino within 5.0 s after it
  c             first line of the same ino within 10 s after it containing P-NOINO-
  d             lines of the same ino within 10 s after it containing each hazard probe
  e             first later P-DIALLOC-RESV-UNDER-NOINO phase=2 line of the same ino within 5 s
  window        [t0 - 1.0 s, t0 + 4.0 s], same boot segment, lines that mention the ino:
                a token "<key>ino=<v>" with any key except one ending in "ag" (agino= counts
                too when the instance's agno is 0), <v> equal to the ino; or, called "bare",
                the decimal not preceded by [0-9A-Za-z_.=+/:-] nor followed by [0-9A-Za-z_],
                or the 0x-hex not preceded by [0-9A-Za-z_=] nor followed by [0-9a-fA-F]
  window pick   per detail lap, own-set instances with no b; phase=1 before phase=2; within a
                phase the nodes alternate, each in stream order; an instance whose window
                overlaps an already picked one of the same node and ino is passed over
Line numbers are 1-based in the decompressed stream, as `zcat F | grep -n` prints them.
"""
import argparse
import bisect
import gzip
import os
import re
import sys
from concurrent.futures import ProcessPoolExecutor

TS_RX = re.compile(rb'^\[\s*(\d+)\.(\d+)\]')
KEYED_RX = re.compile(rb'(?<![A-Za-z0-9_])ino=(0[xX][0-9a-fA-F]+|[0-9]+)')
ANYKEY_RX = re.compile(rb'([A-Za-z0-9_]*)ino=(0[xX][0-9a-fA-F]+|[0-9]+)')
PHASE_RX = re.compile(rb'phase=(-?\d+)')
AGNO_RX = re.compile(rb'agno=(\d+)')
COMM_RX = re.compile(rb'comm=(\S+)')
PUBINF_RX = re.compile(rb'pub_inflight=(\S+)')
NOINO_RX = re.compile(rb'P-NOINO-[A-Z0-9-]*[A-Z0-9]')
RESV = b'P-DIALLOC-RESV-UNDER-NOINO'
SKIP = b'P-DIALLOC-NOINO-SKIP'
NOINO = b'P-NOINO-'
DPROBES = (('ULG', b'P-NOINO-UNLOCK-LEFT-GRANT'), ('UND', b'P-NOINO-UNLOCK-UNDRAINED'),
           ('STL', b'P-NOINO-STALE-RELEASE'), ('LIV', b'P-NOINO-LIVE-SKIP'),
           ('NGR', b'P-LOGWR-DLM-NOGRANT'), ('PHN', b'P-LOG-MIRROR-PHANTOM'))
WTAGS = (b'P-NOINO-', b'P977', b'P4L-')
SKIP_WIN = 5000000
FOLLOW_WIN = 10000000
RESV2_WIN = 5000000
PRE_US = 1000000
POST_US = 4000000
SEG_DROP = 1000000
CTR_KEYS = ('dialloc_resv_under_noino', 'dialloc_resv_noino_skipped', 'noino_resv_guard')


def to_us(m):
    return int(m.group(1)) * 1000000 + int(m.group(2).ljust(6, b'0')[:6])


def ival(v):
    return int(v, 16) if v[:2] in (b'0x', b'0X') else int(v)


def fmt_ts(us):
    return 'none' if us is None else '%d.%06d' % divmod(us, 1000000)


def fmt_ms(us):
    return '+%.1fms' % (us / 1000.0)


def field(rx, line, start):
    m = rx.search(line, start)
    return m.group(1) if m else None


def region_of(t, rng):
    if t is None:
        return 'none'
    if rng is None:
        return 'nohf7'
    if t < rng[0]:
        return 'pre'
    if t > rng[1]:
        return 'post'
    return 'in'


def hf7_range(path):
    lo = hi = None
    count = 0
    try:
        with open(path, 'rb') as fh:
            for raw in fh:
                m = TS_RX.match(raw)
                if m is None:
                    continue
                t = to_us(m)
                count += 1
                if lo is None or t < lo:
                    lo = t
                if hi is None or t > hi:
                    hi = t
    except OSError:
        return None
    return (lo, hi, count) if count else None


def read_counters(path):
    ctr = {}
    try:
        with open(path) as fh:
            for line in fh:
                key, sep, val = line.strip().partition('=')
                if sep:
                    ctr[key] = val
    except OSError:
        return None
    return ctr


def bounds(kts):
    pmax = []
    run = -1
    for t in kts:
        if t is not None and t > run:
            run = t
        pmax.append(run)
    smin = [0] * len(kts)
    run = 1 << 62
    for i in range(len(kts) - 1, -1, -1):
        t = kts[i]
        if t is not None and t < run:
            run = t
        smin[i] = run
    return pmax, smin


def follow(rec, i0, lines, kts, seg, cand):
    t0 = rec['ts']
    s0 = seg[i0]
    for j in cand:
        if j == i0:
            continue
        t = kts[j]
        if t is None or seg[j] != s0 or t < t0 or (t == t0 and j < i0):
            continue
        dt = t - t0
        if dt > FOLLOW_WIN:
            continue
        ln = lines[j]
        key = (dt, j)
        if dt <= SKIP_WIN and SKIP in ln:
            if field(PHASE_RX, ln, ln.index(SKIP)) == b'2' and (rec['b'] is None or key < rec['b']):
                rec['b'] = key
        if NOINO in ln:
            if rec['c'] is None or key < rec['c'][:2]:
                pm = NOINO_RX.search(ln)
                rec['c'] = (dt, j, pm.group(0).decode() if pm else 'P-NOINO-')
        for k, (name, tag) in enumerate(DPROBES):
            if tag in ln:
                rec['d'][k] += 1
                if name in ('NGR', 'PHN'):
                    pi = field(PUBINF_RX, ln, 0)
                    rec['hz'].append((name, j + 1, dt, pi.decode() if pi else '-'))
        if dt <= RESV2_WIN and RESV in ln:
            if field(PHASE_RX, ln, ln.index(RESV)) == b'2' and (rec['e'] is None or key < rec['e']):
                rec['e'] = key


def window(rec, i0, lines, kts, seg, pmax, smin):
    ino = rec['ino']
    t0 = rec['ts']
    lo = t0 - PRE_US
    hi = t0 + POST_US
    s0 = seg[i0]
    dec = str(ino).encode()
    hexd = ('%x' % ino).encode()
    hexu = hexd.upper()
    bare_dec = re.compile(rb'(?<![0-9A-Za-z_.=+/:-])' + dec + rb'(?![0-9A-Za-z_])')
    bare_hex = re.compile(rb'(?<![0-9A-Za-z_=])0[xX]0*' + hexd + rb'(?![0-9a-fA-F])', re.IGNORECASE)
    agzero = rec['agno'] == 0
    out = []
    for j in range(bisect.bisect_left(pmax, lo), bisect.bisect_right(smin, hi)):
        t = kts[j]
        if t is None or t < lo or t > hi or seg[j] != s0:
            continue
        ln = lines[j]
        if dec not in ln and hexd not in ln and hexu not in ln:
            continue
        kind = None
        for m in ANYKEY_RX.finditer(ln):
            key = m.group(1)
            if key[-2:] == b'ag' and not agzero:
                continue
            if ival(m.group(2)) == ino:
                kind = key.decode('ascii', 'replace') + 'ino='
                break
        span = None
        if kind is None:
            m = bare_dec.search(ln) or bare_hex.search(ln)
            if m is not None:
                kind = 'bare'
                span = (m.start(), m.end())
        if kind is None:
            continue
        out.append((j + 1, t, kind, any(tag in ln for tag in WTAGS), ln, span))
    return out


def scan(job):
    label, arm, node, stream, hf7, kmsg, detail = job
    res = {'label': label, 'arm': arm, 'node': node, 'stream': stream, 'error': None,
           'hf7': hf7_range(hf7), 'kmsg': read_counters(kmsg)}
    lines = []
    kts = []
    try:
        with gzip.open(stream, 'rb') as fh:
            for raw in fh:
                line = raw[:-1] if raw.endswith(b'\n') else raw
                lines.append(line)
                m = TS_RX.match(line)
                kts.append(to_us(m) if m else None)
    except (EOFError, OSError) as exc:
        res['error'] = '%s after %d lines: %s' % (type(exc).__name__, len(lines), exc)
    rng = res['hf7']
    seg = []
    cur = 0
    run = None
    back = 0
    maxback = 0
    first = last = None
    nots = 0
    for t in kts:
        if t is None:
            nots += 1
        else:
            if first is None:
                first = t
            last = t
            if run is not None and t < run:
                back += 1
                if run - t > maxback:
                    maxback = run - t
                if run - t > SEG_DROP:
                    cur += 1
                    run = t
            if run is None or t > run:
                run = t
        seg.append(cur)
    res.update(nlines=len(lines), nots=nots, backsteps=back, maxback=maxback,
               segments=cur + 1, kt=(first, last))
    index = {}
    resv = []
    skip = []
    for i, line in enumerate(lines):
        if RESV in line:
            resv.append(i)
        elif SKIP in line:
            skip.append(i)
        if b'ino=' not in line:
            continue
        for m in KEYED_RX.finditer(line):
            v = ival(m.group(1))
            lst = index.get(v)
            if lst is None:
                index[v] = [i]
            elif lst[-1] != i:
                lst.append(i)
    tallies = {}
    for name, idxs, tag in (('resv', resv, RESV), ('skip', skip, SKIP)):
        tally = {}
        for i in idxs:
            p = field(PHASE_RX, lines[i], lines[i].index(tag))
            key = (p.decode() if p else 'none', region_of(kts[i], rng))
            tally[key] = tally.get(key, 0) + 1
        tallies[name] = tally
    res['tally'] = tallies
    pmax = smin = None
    insts = []
    for i0 in resv:
        line = lines[i0]
        at = line.index(RESV)
        m = KEYED_RX.search(line, at)
        ino = ival(m.group(1)) if m else None
        ph = field(PHASE_RX, line, at)
        ag = field(AGNO_RX, line, at)
        cm = field(COMM_RX, line, at)
        t0 = kts[i0]
        rec = {'line': i0 + 1, 'ts': t0, 'ino': ino, 'phase': ph.decode() if ph else 'none',
               'agno': int(ag) if ag else None,
               'comm': cm.decode('utf-8', 'replace') if cm else '-',
               'region': region_of(t0, rng), 'text': line,
               'b': None, 'c': None, 'd': [0] * len(DPROBES), 'e': None, 'hz': [], 'win': None}
        if ino is not None and t0 is not None:
            follow(rec, i0, lines, kts, seg, index.get(ino, ()))
            if detail and rec['b'] is None:
                if pmax is None:
                    pmax, smin = bounds(kts)
                rec['win'] = window(rec, i0, lines, kts, seg, pmax, smin)
        insts.append(rec)
    res['insts'] = insts
    return res


def tsum(tally, phases=None, regions=None):
    n = 0
    for (p, r), c in tally.items():
        if phases is not None and p not in phases:
            continue
        if regions is not None and r not in regions:
            continue
        n += c
    return n


def tcols(tl):
    other = tsum(tl) - tsum(tl, {'1', '2'})
    return ('%d/%d/%d' % (tsum(tl, {'1'}), tsum(tl, {'2'}), other),
            '%d/%d' % (tsum(tl, {'1'}, {'in'}), tsum(tl, {'2'}, {'in'})),
            '%d/%d/%d' % (tsum(tl, None, {'pre'}), tsum(tl, None, {'in'}), tsum(tl, None, {'post'})),
            tsum(tl, None, {'none', 'nohf7'}))


def step1(rep, results):
    rep.append('STEP 1  per stream: P-DIALLOC-RESV-UNDER-NOINO (RESV) and P-DIALLOC-NOINO-SKIP (SKIP) lines by phase')
    rep.append('  "all p1/p2/ot" = whole stream by phase 1 / 2 / other; "in p1/p2" = inside the hf7.txt kernel-time range;')
    rep.append('  "pre/in/po" = all phases by region; kmsg = the lap\'s own counters ' + ' / '.join(CTR_KEYS))
    rep.append('%-5s %-7s %-6s | %-12s | %-9s | %-11s | %-12s | %-9s | %-11s | %s' % (
        'lap', 'arm', 'node', 'RESV all', 'RESV in', 'RESV region', 'SKIP all', 'SKIP in',
        'SKIP region', 'kmsg resv/skip/guard'))
    rep.append('%-5s %-7s %-6s | %-12s | %-9s | %-11s | %-12s | %-9s | %-11s |' % (
        '', '', '', 'p1/p2/ot', 'p1/p2', 'pre/in/po', 'p1/p2/ot', 'p1/p2', 'pre/in/po'))
    odd = []
    for r in results:
        ra, ri, rr, rn = tcols(r['tally']['resv'])
        sa, si, sr, sn = tcols(r['tally']['skip'])
        ctr = r['kmsg']
        kv = '/'.join(ctr.get(k, '-') for k in CTR_KEYS) if ctr is not None else 'no kmsg.txt'
        rep.append('%-5s %-7s %-6s | %-12s | %-9s | %-11s | %-12s | %-9s | %-11s | %s' % (
            r['label'], r['arm'], r['node'], ra, ri, rr, sa, si, sr, kv))
        if rn or sn:
            odd.append('  %s %s: RESV lines without region %d, SKIP lines without region %d' % (
                r['label'], r['node'], rn, sn))
    rep.extend(odd)
    rep.append('')
    rep.append('STEP 1 context: stream kernel-time span, hf7.txt range, stream health')
    rep.append('%-5s %-6s | %-27s | %-34s | %8s | %5s | %-16s | %4s | %s' % (
        'lap', 'node', 'stream kt first..last', 'hf7 kt lo..hi (timestamped lines)', 'lines',
        'no-ts', 'backsteps (max s)', 'segs', 'read error'))
    for r in results:
        h = r['hf7']
        hs = 'none' if h is None else '%s..%s (%d)' % (fmt_ts(h[0]), fmt_ts(h[1]), h[2])
        rep.append('%-5s %-6s | %-27s | %-34s | %8d | %5d | %-16s | %4d | %s' % (
            r['label'], r['node'], '%s..%s' % (fmt_ts(r['kt'][0]), fmt_ts(r['kt'][1])), hs,
            r['nlines'], r['nots'], '%d (%s)' % (r['backsteps'], fmt_ts(r['maxback'])),
            r['segments'], r['error'] or '-'))
    rep.append('')


def row(r, rec):
    b = 'yes %s' % fmt_ms(rec['b'][0]) if rec['b'] else 'no'
    c = '%s %s' % (rec['c'][2], fmt_ms(rec['c'][0])) if rec['c'] else 'none'
    d = ' '.join('%3d' % v for v in rec['d'])
    e = 'yes %s' % fmt_ms(rec['e'][0]) if rec['e'] else 'no'
    return '%-5s %-6s %7d %15s %9s %-2s %-10s %-4s %-9s | %-15s | %-37s | %s | %s' % (
        r['label'], r['node'], rec['line'], fmt_ts(rec['ts']),
        '?' if rec['ino'] is None else rec['ino'], rec['phase'], rec['comm'][:10],
        rec['region'], ','.join(rec['twin']) or '-', b, c, d, e)


ROW_HDR = '%-5s %-6s %7s %15s %9s %-2s %-10s %-4s %-9s | %-15s | %-37s | %s | %s' % (
    'lap', 'node', 'line', 'ts', 'ino', 'ph', 'comm', 'reg', 'twin', 'b SKIP p2 <=5s',
    'c first P-NOINO- <=10s', ' '.join('%3s' % n for n, t in DPROBES), 'e RESV p2 <=5s')


def step2(rep, results, laps, arm):
    rep.append('STEP 2  per-instance rows, arm=%s, own set (see "own set" in the definitions)' % arm)
    rep.append('  d columns: ULG=P-NOINO-UNLOCK-LEFT-GRANT UND=P-NOINO-UNLOCK-UNDRAINED STL=P-NOINO-STALE-RELEASE '
               'LIV=P-NOINO-LIVE-SKIP NGR=P-LOGWR-DLM-NOGRANT PHN=P-LOG-MIRROR-PHANTOM (counts within 10 s)')
    rep.append(ROW_HDR)
    hz = []
    for label, larm, dirname, nodes in laps:
        if larm != arm:
            continue
        notown = {}
        nown = 0
        for r in results:
            if r['label'] != label:
                continue
            for rec in r['insts']:
                if rec['own']:
                    rep.append(row(r, rec))
                    nown += 1
                    for h in rec['hz']:
                        hz.append('  %s %s instance line %d ino=%s: %s at stream line %d %s pub_inflight=%s' % (
                            label, r['node'], rec['line'], rec['ino'], h[0], h[1], fmt_ms(h[2]), h[3]))
                else:
                    k = (r['node'], ','.join(rec['twin']))
                    notown[k] = notown.get(k, 0) + 1
        extra = '; '.join('%s twin=%s: %d' % (k[0], k[1], v) for k, v in sorted(notown.items()))
        rep.append('  -- %s: own-set rows %d; pre-hf7 rows with a twin (in rows.tsv only): %s' % (
            label, nown, extra or 'none'))
    rep.append('  NGR/PHN lines counted in d, located (own set):')
    rep.extend(hz or ['  none'])
    rep.append('')


def ranges(nums):
    out = []
    for n in nums:
        if out and n == out[-1][1] + 1:
            out[-1][1] = n
        else:
            out.append([n, n])
    return ','.join('%d' % a if a == b else '%d-%d' % (a, b) for a, b in out)


def cut(w, width):
    lineno, t, kind, tagged, ln, span = w
    s = ln.decode('utf-8', 'replace').replace('\r', '')
    if kind == 'bare' and span is not None and span[1] > width:
        a = max(span[0] - 40, 0)
        frag = ln[a:span[1] + 40].decode('utf-8', 'replace')
        s = s[:120] + ' ...[cut]... ' + frag + ' ...[cut]'
    else:
        k = s.find(' -- ')
        if k >= 0:
            s = s[:k] + ' --[cut]'
        if len(s) > width:
            s = s[:width] + '[cut]'
    mark = '' if kind == 'ino=' else ' {%s}' % kind
    return '%d:%s%s' % (lineno, s, mark)


def pick(results, label, per_lap):
    picked = []
    for phase_one in (True, False):
        queues = []
        for r in results:
            if r['label'] != label:
                continue
            q = [(r, rec) for rec in r['insts'] if rec['own'] and rec['b'] is None
                 and rec['win'] is not None and (rec['phase'] == '1') == phase_one]
            queues.append(q)
        pos = [0] * len(queues)
        while len(picked) < per_lap and any(pos[i] < len(q) for i, q in enumerate(queues)):
            for i, q in enumerate(queues):
                while pos[i] < len(q):
                    r, rec = q[pos[i]]
                    pos[i] += 1
                    clash = any(pr['node'] == r['node'] and prec['ino'] == rec['ino']
                                and abs(prec['ts'] - rec['ts']) < PRE_US + POST_US
                                for pr, prec in picked)
                    if not clash:
                        picked.append((r, rec))
                        break
                if len(picked) == per_lap:
                    break
    return picked


def emit(out, width, hdr, win, cap, with_a):
    keyed = sum(1 for w in win if w[2] != 'bare')
    out.append(hdr)
    out.append('   A lines mentioning the ino: %d (keyed %d, bare %d); printed %s' % (
        len(win), keyed, len(win) - keyed,
        min(len(win), cap) if with_a else '0 in this file (they are in report.txt / windows.txt)'))
    if with_a:
        out.extend('     ' + cut(w, width) for w in win[:cap])
        if len(win) > cap:
            out.append('     cut by cap: %d lines, stream lines %s' % (
                len(win) - cap, ranges([w[0] for w in win[cap:]])))
    for name, test in (('B lines containing P-NOINO-/P977/P4L-', lambda w: w[3]),
                       ('C lines containing P-DIALLOC-', lambda w: b'P-DIALLOC-' in w[4])):
        sel = [w for w in win if test(w)]
        out.append('   %s among them: %d; printed %d' % (name, len(sel), min(len(sel), cap)))
        out.extend('     ' + cut(w, width) for w in sel[:cap])
        if len(sel) > cap:
            out.append('     cut by cap: %d lines, stream lines %s' % (
                len(sel) - cap, ranges([w[0] for w in sel[cap:]])))


def step3(rep, full, brief, results, laps, args):
    title = 'STEP 3  verbatim windows [t0-1.0s, t0+4.0s] for picked own-set instances with b=no, arm=%s' % args.detail_arm
    note = ('  lines cut at the first " -- " and at %d chars; {key} = matched through that key, {bare} = bare '
            'number (fragment shown); uncut lines in windows.txt' % args.width)
    rep.extend((title, note))
    brief.extend((title, note))
    for label, arm, dirname, nodes in laps:
        if arm != args.detail_arm:
            continue
        elig = sum(1 for r in results if r['label'] == label for rec in r['insts']
                   if rec['own'] and rec['b'] is None)
        picked = pick(results, label, args.per_lap)
        head = '== %s: own-set instances with b=no: %d; picked %d' % (label, elig, len(picked))
        for out in (rep, full, brief):
            out.append(head)
        for r, rec in picked:
            hdr = ('-- %s %s line=%d ts=%s ino=%d (0x%x) phase=%s agno=%s comm=%s region=%s twin=%s stream=%s' % (
                label, r['node'], rec['line'], fmt_ts(rec['ts']), rec['ino'], rec['ino'], rec['phase'],
                rec['agno'], rec['comm'], rec['region'], ','.join(rec['twin']) or '-', r['stream']))
            emit(rep, args.width, hdr, rec['win'], args.cap, True)
            emit(full, 1 << 30, hdr, rec['win'], args.cap, True)
            emit(brief, args.width, hdr, rec['win'], args.cap, False)
    rep.append('')


def summary(insts):
    n = len(insts)
    ph = {}
    cdist = {}
    for x in insts:
        ph[x['phase']] = ph.get(x['phase'], 0) + 1
        name = x['c'][2] if x['c'] else 'none'
        cdist[name] = cdist.get(name, 0) + 1
    b = sum(1 for x in insts if x['b'])
    d = [sum(1 for x in insts if x['d'][k] > 0) for k in range(len(DPROBES))]
    e = sum(1 for x in insts if x['e'])
    return '%4d  %-14s | b=yes %4d | %s | e=yes %4d | c: %s' % (
        n, ' '.join('p%s=%d' % kv for kv in sorted(ph.items())), b,
        ' '.join('%s>0=%d' % (DPROBES[k][0], d[k]) for k in range(len(DPROBES))), e,
        ', '.join('%s=%d' % kv for kv in sorted(cdist.items(), key=lambda kv: -kv[1])))


def step4(rep, results, laps):
    rep.append('STEP 4  per-lap summaries (both arms): instances, phases, b=yes, instances with each d probe > 0, e=yes, c distribution')
    for scope, test in (('own set', lambda rec: rec['own']), ('whole stream', lambda rec: True)):
        rep.append('  scope: %s' % scope)
        armtot = {}
        for label, arm, dirname, nodes in laps:
            insts = [rec for r in results if r['label'] == label for rec in r['insts'] if test(rec)]
            armtot.setdefault(arm, []).extend(insts)
            rep.append('  %-5s %-7s %s' % (label, arm, summary(insts)))
        for arm, insts in armtot.items():
            rep.append('  %-5s %-7s %s' % ('TOTAL', arm, summary(insts)))
    rep.append('')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('evid')
    ap.add_argument('outdir')
    ap.add_argument('--lap', action='append', required=True)
    ap.add_argument('--detail-arm', default='fix')
    ap.add_argument('--per-lap', type=int, default=4)
    ap.add_argument('--cap', type=int, default=40)
    ap.add_argument('--width', type=int, default=300)
    ap.add_argument('--jobs', type=int, default=3)
    args = ap.parse_args()
    laps = []
    for spec in args.lap:
        parts = spec.split(':')
        if len(parts) != 4:
            ap.error('bad --lap %r' % spec)
        laps.append((parts[0], parts[1], parts[2], parts[3].split(',')))
    jobs = []
    for label, arm, dirname, nodes in laps:
        for node in nodes:
            base = os.path.join(args.evid, dirname, node)
            jobs.append((label, arm, node, base + '_dmesg_stream.gz', base + '_hf7.txt',
                         base + '_kmsg.txt', arm == args.detail_arm))
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(scan, jobs))
    seen = {}
    for r in results:
        for rec in r['insts']:
            seen.setdefault((r['node'], rec['text']), set()).add(r['label'])
    for r in results:
        for rec in r['insts']:
            rec['twin'] = sorted(seen[(r['node'], rec['text'])] - {r['label']})
            rec['own'] = rec['region'] != 'pre' or not rec['twin']
    os.makedirs(args.outdir, exist_ok=True)
    rep = ['argv: ' + ' '.join(sys.argv), '']
    full = []
    brief = []
    step1(rep, results)
    step2(rep, results, laps, args.detail_arm)
    step3(rep, full, brief, results, laps, args)
    step4(rep, results, laps)
    with open(os.path.join(args.outdir, 'report.txt'), 'w') as fh:
        fh.write('\n'.join(rep) + '\n')
    with open(os.path.join(args.outdir, 'windows.txt'), 'w') as fh:
        fh.write('\n'.join(full) + '\n')
    with open(os.path.join(args.outdir, 'step3_bc.txt'), 'w') as fh:
        fh.write('\n'.join(brief) + '\n')
    with open(os.path.join(args.outdir, 'rows.tsv'), 'w') as fh:
        fh.write('\t'.join(('lap', 'arm', 'node', 'line', 'ts', 'ino', 'phase', 'agno', 'comm', 'region',
                            'twin', 'own', 'b_ms', 'c_probe', 'c_ms') + tuple(n for n, t in DPROBES) +
                           ('e_ms', 'ngr_phn_lines')) + '\n')
        for r in results:
            for rec in r['insts']:
                fh.write('\t'.join(str(v) for v in (
                    r['label'], r['arm'], r['node'], rec['line'], fmt_ts(rec['ts']), rec['ino'], rec['phase'],
                    rec['agno'], rec['comm'], rec['region'], ','.join(rec['twin']) or '-', int(rec['own']),
                    '%.1f' % (rec['b'][0] / 1000.0) if rec['b'] else '-',
                    rec['c'][2] if rec['c'] else '-', '%.1f' % (rec['c'][0] / 1000.0) if rec['c'] else '-',
                    *rec['d'], '%.1f' % (rec['e'][0] / 1000.0) if rec['e'] else '-',
                    ';'.join('%s@%d:pi=%s' % (h[0], h[1], h[3]) for h in rec['hz']) or '-')) + '\n')
    print('wrote %s/report.txt windows.txt step3_bc.txt rows.tsv; streams=%d instances=%d' % (
        args.outdir, len(results), sum(len(r['insts']) for r in results)))


if __name__ == '__main__':
    main()
