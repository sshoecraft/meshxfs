#!/usr/bin/env python3
"""Pull verbatim P-DIALLOC / P-NOINO evidence lines out of lap kernel-log streams.

Input:  <BASE>/<DIR>/<NODE>_dmesg_stream.gz, lines of "[ secs.usecs] text", plus
        <NODE>_hf7.txt (kernel-time range of the harvested window) and
        <NODE>_kmsg.txt (the lap's own sysctl counters) from the same directory.
Output: one report file of verbatim stream lines, each prefixed with its 1-based
        line number in the decompressed stream, the way `zcat F | grep -n` prints
        them.  Every cap is announced together with its pre-cap total.

usage:
  noino_lap_attr.py BASE OUT [options]
    --window LABEL=DIR:NODE:INO:TLO:THI      (repeatable)
        every line naming INO with kernel time in [TLO,THI] seconds, and every
        P-DIALLOC-RESV-UNDER-NOINO line for INO at any time
    --lap LABEL=DIR:NODE[,NODE...]           (repeatable)
        per node: B1 RESV-UNDER-NOINO lines, B2 per-ino neighbourhoods, B3 counts
    --counts LABEL=DIR:NODE[,NODE...]        (repeatable)
        B3 counts only
    --max-resv N   B1 print cap per node             (default 40)
    --max-inos N   distinct inos given a B2 section  (default 15)
    --cap N        B2 print cap per ino              (default 30)
    --pad S        B2 window half-width, seconds     (default 1.5)
    --jobs N       parallel stream readers           (default 4)

A line "names" an ino when it contains "ino=<N> " or ends with "ino=<N>".  That is
a literal substring test with no left boundary, so "parent_ino=<N> " matches too;
such lines are counted and listed in the notes.  Windows are inclusive.  A line
without a "[ts]" prefix cannot be placed in a window.

What the stream alone does not show: consecutive laps on one node share its kernel
clock, and a stream can begin during the previous lap.  So the tag lines are split
into regions relative to the hf7 kernel-time range (pre = before its first line,
in = inside, post = after), the lap's own kmsg.txt counters are printed beside them,
and lines that also appear verbatim in another provided stream of the same node
are counted.
"""
import argparse
import bisect
import gc
import gzip
import re
import sys
from concurrent.futures import ProcessPoolExecutor

TS_RX = re.compile(rb'^\[\s*(\d+)\.(\d+)\]')
INO_RX = re.compile(rb'ino=(\d+)')
PHASE_RX = re.compile(rb'phase=(-?\d+)')
RESV_TAG = b'P-DIALLOC-RESV-UNDER-NOINO'
SKIP_TAG = b'P-DIALLOC-NOINO-SKIP'
ULG_TAG = b'P-NOINO-UNLOCK-LEFT-GRANT'
TAGS3 = (('resv', RESV_TAG), ('skip', SKIP_TAG), ('ulg', ULG_TAG))
B2_TAGS = (b'P-DIALLOC', b'P-NOINO', b'P-LOG-MIRROR-PHANTOM', b'P-LOGWR-DLM-NOGRANT',
           b'P4L-', b'P74-GRANT', b'P64-MASTER-HANDOFF', b'P82-REM', b'P-FREE-RELEASE',
           b'P-RECYCLE', b'P-PUB-CLAIM', b'P977-REL-MARK', b'P-DGEX')
COUNTER_KEYS = ('dialloc_resv_under_noino', 'dialloc_resv_noino_skipped', 'noino_resv_guard',
                'noino_unlock_left_grant', 'log_mirror_phantom', 'logwr_dlm_nogrant')
NEG = -1
POS = 1 << 62
BAR = '=' * 100 + '\n'
RULE = '-' * 100 + '\n'


def to_us(text):
    whole, sep, frac = text.partition('.')
    return int(whole) * 1000000 + int((frac + '000000')[:6])


def fmt_us(us):
    return 'none' if us is None else '%d.%06d' % divmod(us, 1000000)


def fmt_s1(us):
    return 'n/a' if us is None else '%.1f' % (us / 1000000.0)


def note(text):
    return text.encode() + b'\n'


class Stream:
    """One decompressed kernel-log stream held in memory."""

    def __init__(self, path):
        self.path = path
        self.lines = []
        self.kts = []
        self.no_ts = 0
        self.cr_lines = 0
        self.backsteps = 0
        self.max_back = 0
        self.read_error = None
        prev = None
        try:
            with gzip.open(path, 'rb') as fh:
                for raw in fh:
                    line = raw[:-1] if raw.endswith(b'\n') else raw
                    self.lines.append(line)
                    if b'\r' in line:
                        self.cr_lines += 1
                    m = TS_RX.match(line)
                    if m is None:
                        self.kts.append(None)
                        self.no_ts += 1
                        continue
                    t = int(m.group(1)) * 1000000 + int(m.group(2).ljust(6, b'0')[:6])
                    self.kts.append(t)
                    if prev is not None and t < prev:
                        self.backsteps += 1
                        self.max_back = max(self.max_back, prev - t)
                    prev = t
        except (EOFError, OSError) as exc:
            self.read_error = '%s: %s' % (type(exc).__name__, exc)
        self.kt_first = next((t for t in self.kts if t is not None), None)
        self.kt_last = next((t for t in reversed(self.kts) if t is not None), None)
        run = NEG
        self.pmax = []
        for t in self.kts:
            if t is not None and t > run:
                run = t
            self.pmax.append(run)
        run = POS
        self.smin = [POS] * len(self.kts)
        for i in range(len(self.kts) - 1, -1, -1):
            t = self.kts[i]
            if t is not None and t < run:
                run = t
            self.smin[i] = run

    def span(self, lo, hi):
        """Index range [a, b) guaranteed to hold every line with lo <= kt <= hi."""
        return bisect.bisect_left(self.pmax, lo), bisect.bisect_right(self.smin, hi)

    def verbatim(self, i):
        return b'%d:' % (i + 1) + self.lines[i] + b'\n'

    def header(self, title):
        out = [BAR.encode(), note(title), note('stream=' + self.path),
               note('stream lines=%d  no-[ts]-prefix lines=%d  lines with CR=%d  '
                    'ts back-steps=%d (max %s s)' % (len(self.lines), self.no_ts,
                                                      self.cr_lines, self.backsteps,
                                                      fmt_us(self.max_back)))]
        if self.read_error:
            out.append(note('READ ERROR after %d lines: %s' % (len(self.lines), self.read_error)))
        out.append(RULE.encode())
        return out


def names_ino(line, key):
    return (key + b' ') in line or line.endswith(key)


def left_clean(key):
    return re.compile(rb'(?<![A-Za-z0-9_])' + re.escape(key) + rb'(?: |$)')


def lap_path(base, dirname, node, suffix):
    return '%s/%s/%s_%s' % (base, dirname, node, suffix)


def hf7_range(path):
    """(first kt, last kt, timestamped lines) of the harvested window, or None."""
    lo = hi = None
    count = 0
    try:
        with open(path, 'rb') as fh:
            for raw in fh:
                m = TS_RX.match(raw)
                if m is None:
                    continue
                t = int(m.group(1)) * 1000000 + int(m.group(2).ljust(6, b'0')[:6])
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
                if sep and val.lstrip('-').isdigit():
                    ctr[key] = int(val)
    except OSError:
        return None
    return ctr


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


def split_regions(st, idxs, rng):
    out = {'pre': [], 'in': [], 'post': [], 'none': [], 'nohf7': []}
    for i in idxs:
        out[region_of(st.kts[i], rng)].append(i)
    return out


def region_text(parts):
    bits = []
    for name in ('pre', 'in', 'post', 'none', 'nohf7'):
        ids = parts[name]
        if ids:
            bits.append('%s=%d (stream lines %d..%d)' % (name, len(ids), ids[0] + 1, ids[-1] + 1))
        elif name in ('pre', 'in', 'post'):
            bits.append('%s=0' % name)
    return '   '.join(bits)


def phase_of(line, tag):
    m = PHASE_RX.search(line, line.index(tag))
    return m.group(1).decode() if m else 'none'


def tag_census(st):
    """For SKIP and RESV: (stream indexes, {phase: count}, lines with tag not right after 'mxfs: ')."""
    census = {}
    for name, tag in (('skip', SKIP_TAG), ('resv', RESV_TAG)):
        prefixed = b'mxfs: ' + tag
        idxs = [i for i, ln in enumerate(st.lines) if tag in ln]
        by = {}
        off = 0
        for i in idxs:
            ln = st.lines[i]
            if prefixed not in ln:
                off += 1
            k = phase_of(ln, tag)
            by[k] = by.get(k, 0) + 1
        census[name] = (idxs, by, off)
    census['ulg'] = ([i for i, ln in enumerate(st.lines) if ULG_TAG in ln], {}, 0)
    return census


def phase_text(idxs, by):
    rest = {k: v for k, v in by.items() if k not in ('1', '2')}
    text = 'total=%d phase=1:%d phase=2:%d other:%d' % (len(idxs), by.get('1', 0),
                                                         by.get('2', 0), sum(rest.values()))
    if rest:
        text += ' (other values: ' + ' '.join('phase=%s:%d' % (k, rest[k]) for k in sorted(rest)) + ')'
    return text


def section_window(base, spec):
    label, rest = spec.split('=', 1)
    dirname, node, ino, tlo, thi = rest.split(':')
    lo, hi = to_us(tlo), to_us(thi)
    st = Stream(lap_path(base, dirname, node, 'dmesg_stream.gz'))
    rng = hf7_range(lap_path(base, dirname, node, 'hf7.txt'))
    key = b'ino=' + ino.encode()
    clean = left_clean(key)
    a, b = st.span(lo, hi)
    inwin = [i for i in range(a, b) if st.kts[i] is not None and lo <= st.kts[i] <= hi]
    hits = [i for i in inwin if names_ino(st.lines[i], key)]
    hitset = set(hits)
    prefixed = [i for i in hits if not clean.search(st.lines[i])]
    digits = re.compile(rb'(?<!\d)' + re.escape(ino.encode()) + rb'(?!\d)')
    others = [i for i in inwin if i not in hitset and digits.search(st.lines[i])]
    back = sum(1 for j in range(1, len(hits)) if st.kts[hits[j]] < st.kts[hits[j - 1]])
    out = st.header('TASK A  %s  dir=%s  node=%s  ino=%s  kernel time [%s, %s]' %
                    (label, dirname, node, ino, fmt_us(lo), fmt_us(hi)))
    if rng is None:
        out.append(note('context: hf7.txt missing or without timestamps'))
    else:
        out.append(note('context: hf7.txt kt range [%s, %s]; the window lies inside it: %s' %
                        (fmt_us(rng[0]), fmt_us(rng[1]), 'yes' if rng[0] <= lo and hi <= rng[1] else 'NO')))
    out.append(note('lines in the window (any content): %d' % len(inwin)))
    out.append(note('A1 lines containing "%s " or ending "%s", kt in window: %d' %
                    (key.decode(), key.decode(), len(hits))))
    out.append(note('   matching only through a name-prefixed key such as parent_ino=: %d%s' %
                    (len(prefixed), (' -> stream lines ' + ' '.join(str(i + 1) for i in prefixed)) if prefixed else '')))
    out.append(note('   lines in the window carrying the digits %s in some other form (not matched by the rule): %d%s' %
                    (ino, len(others), (' -> stream lines ' + ' '.join(str(i + 1) for i in others[:200])) if others else '')))
    out.append(note('   timestamp back-steps among the printed lines (stream order kept): %d' % back))
    for i in hits:
        out.append(st.verbatim(i))
    if others and len(others) <= 25:
        out.append(note('(supplementary, NOT matched by the stated rule, shown because they carry the digits:)'))
        for i in others:
            out.append(st.verbatim(i))
    lit = RESV_TAG + b' ' + key
    lit_idx = [i for i, ln in enumerate(st.lines) if lit in ln]
    resv = [i for i in lit_idx if st.lines[i].endswith(lit) or (lit + b' ') in st.lines[i]]
    out.append(note(''))
    out.append(note('A2 lines containing "%s" (space or end-of-line after the number), all times: %d' %
                    (lit.decode(), len(resv))))
    out.append(note('   literal substring count without the trailing boundary: %d' % len(lit_idx)))
    for i in resv:
        out.append(st.verbatim(i))
    return out, None


def section_lap(args, label, dirname, node, kind):
    st = Stream(lap_path(args.base, dirname, node, 'dmesg_stream.gz'))
    rng = hf7_range(lap_path(args.base, dirname, node, 'hf7.txt'))
    ctr = read_counters(lap_path(args.base, dirname, node, 'kmsg.txt'))
    census = tag_census(st)
    skip_idx, skip_by, skip_off = census['skip']
    resv_idx, resv_by, resv_off = census['resv']
    regs = {name: split_regions(st, census[name][0], rng) for name, tag in TAGS3}
    in_by = {}
    for name, tag in (('skip', SKIP_TAG), ('resv', RESV_TAG)):
        by = {}
        for i in regs[name]['in']:
            k = phase_of(st.lines[i], tag)
            by[k] = by.get(k, 0) + 1
        in_by[name] = by
    out = st.header('%s  %s  dir=%s  node=%s' % ('LAP' if kind == 'fix' else 'BASELINE (not requested)',
                                                  label, dirname, node))
    if rng is None:
        out.append(note('context: hf7.txt missing or without timestamps'))
    else:
        out.append(note('context: hf7.txt kt range [%s, %s] (%d timestamped lines); stream kt range [%s, %s]' %
                        (fmt_us(rng[0]), fmt_us(rng[1]), rng[2], fmt_us(st.kt_first), fmt_us(st.kt_last))))
    if ctr is None:
        out.append(note('context: kmsg.txt missing'))
    else:
        out.append(note("context: kmsg.txt counters (this lap's own, uncapped): " +
                        ' '.join('%s=%s' % (k, ctr.get(k, 'absent')) for k in COUNTER_KEYS)))
    for name, tag in TAGS3:
        out.append(note('context: %s lines by hf7 region: %s' % (tag.decode(), region_text(regs[name]))))
    row = {'kind': kind, 'label': label, 'node': node, 'nlines': len(st.lines),
           'skip_n': len(skip_idx), 'skip_by': skip_by, 'resv_n': len(resv_idx), 'resv_by': resv_by,
           'kt': (st.kt_first, st.kt_last), 'hf7': rng, 'ctr': ctr, 'dist': None,
           'reg': {name: {r: len(v) for r, v in regs[name].items()} for name in regs},
           'lines': {name: {r: set(st.lines[i] for i in regs[name][r]) for r in regs[name]} for name in regs}}
    row['in_by'] = in_by
    if kind != 'fix':
        out.append(note('B3 P-DIALLOC-NOINO-SKIP: %s' % phase_text(skip_idx, skip_by)))
        out.append(note('B3 P-DIALLOC-RESV-UNDER-NOINO: %s' % phase_text(resv_idx, resv_by)))
        return out, row
    shown = resv_idx[:args.max_resv]
    out.append(note('B1 P-DIALLOC-RESV-UNDER-NOINO lines in stream: %d (tag not directly after "mxfs: ": %d); '
                    'printing %s' % (len(resv_idx), resv_off,
                                     'all %d' % len(resv_idx) if len(resv_idx) <= args.max_resv
                                     else 'the first %d (stream lines %d..%d); %d not printed (stream lines %d..%d)' %
                                     (args.max_resv, shown[0] + 1, shown[-1] + 1, len(resv_idx) - args.max_resv,
                                      resv_idx[args.max_resv] + 1, resv_idx[-1] + 1))))
    for i in shown:
        out.append(st.verbatim(i))
    first = {}
    count = {}
    phs = {}
    order = []
    unparsed = 0
    for i in resv_idx:
        ln = st.lines[i]
        m = INO_RX.search(ln, ln.index(RESV_TAG))
        if m is None:
            unparsed += 1
            continue
        ino = int(m.group(1))
        if ino not in first:
            first[ino] = i
            order.append(ino)
            count[ino] = 0
            phs[ino] = {}
        count[ino] += 1
        pk = phase_of(ln, RESV_TAG)
        phs[ino][pk] = phs[ino].get(pk, 0) + 1
    row['dist'] = len(order)
    chosen = order[:args.max_inos]
    omitted = order[args.max_inos:]
    out.append(note('B1 distinct ino among the RESV lines: %d (RESV lines whose ino could not be parsed: %d); '
                    'B2 sections follow for the first %d in order of first appearance' %
                    (len(order), unparsed, len(chosen))))
    if omitted:
        out.append(note('B1 distinct inos NOT given a B2 section (%d), ino(RESV line count, first stream line): %s' %
                        (len(omitted), ' '.join('%d(%d,L%d)' % (n, count[n], first[n] + 1) for n in omitted))))
    pad = to_us(args.pad)
    for ino in chosen:
        key = b'ino=%d' % ino
        clean = left_clean(key)
        anchor = first[ino]
        t0 = st.kts[anchor]
        out.append(note(''))
        if t0 is None:
            out.append(note('B2 ino=%d: first RESV line (stream line %d) has no [ts] prefix; window cannot be placed' %
                            (ino, anchor + 1)))
            continue
        lo, hi = t0 - pad, t0 + pad
        a, b = st.span(lo, hi)
        sel = []
        for i in range(a, b):
            t = st.kts[i]
            if t is None or t < lo or t > hi:
                continue
            ln = st.lines[i]
            if not names_ino(ln, key):
                continue
            if any(tag in ln for tag in B2_TAGS):
                sel.append(i)
        pos = sel.index(anchor) + 1 if anchor in sel else 0
        pre = len(sel)
        out.append(note('B2 ino=%d  RESV lines for this ino: %d (phases %s)  first RESV line = stream line %d at kt %s  '
                        'hf7 region of it: %s' %
                        (ino, count[ino], ' '.join('%s:%d' % (k, phs[ino][k]) for k in sorted(phs[ino])),
                         anchor + 1, fmt_us(t0), region_of(t0, rng))))
        out.append(note('   window kt [%s, %s]; lines naming the ino and carrying a listed tag (pre-cap): %d; '
                        'the first RESV line is selected line #%d' % (fmt_us(lo), fmt_us(hi), pre, pos)))
        hist = {}
        for i in sel:
            ln = st.lines[i]
            at = ln.find(b'mxfs: ')
            token = ln[at + 6:].split(b' ', 1)[0].decode(errors='replace') if at >= 0 else '(no "mxfs: " prefix)'
            hist[token] = hist.get(token, 0) + 1
        out.append(note('   tags in these lines (first token after "mxfs: ", pre-cap): ' +
                        ' '.join('%s:%d' % (k, v) for k, v in sorted(hist.items(), key=lambda kv: (-kv[1], kv[0])))))
        pfx = [i for i in sel if not clean.search(st.lines[i])]
        if pfx:
            out.append(note('   %d of these match only through a name-prefixed key such as parent_ino=: stream lines %s' %
                            (len(pfx), ' '.join(str(i + 1) for i in pfx))))
        shown2 = sel[:args.cap]
        if pre > args.cap:
            out.append(note('   CAP: printing the first %d of %d (stream lines %d..%d); %d not printed (stream lines %d..%d)' %
                            (args.cap, pre, shown2[0] + 1, shown2[-1] + 1, pre - args.cap,
                             sel[args.cap] + 1, sel[-1] + 1)))
        for i in shown2:
            out.append(st.verbatim(i))
        if anchor in sel and anchor not in shown2:
            out.append(note('   the first RESV line (selected line #%d) fell beyond the cap; printed here so it is not lost:' % pos))
            out.append(st.verbatim(anchor))
    out.append(note(''))
    out.append(note('B3 P-DIALLOC-NOINO-SKIP: %s' % phase_text(skip_idx, skip_by)))
    out.append(note('B3 P-DIALLOC-RESV-UNDER-NOINO: %s' % phase_text(resv_idx, resv_by)))
    return out, row


def parse_nodes(spec):
    label, rest = spec.split('=', 1)
    dirname, nodes = rest.split(':', 1)
    return label, dirname, nodes.split(',')


def summary_table(rows):
    out = [note('B3 SUMMARY, whole stream (same numbers as the per-node B3 lines)'),
           note('%-9s %-7s %-7s %9s %7s %7s %7s | %9s %7s %7s %7s | %8s | %11s' %
                ('kind', 'lap', 'node', 'SKIP_tot', 'ph1', 'ph2', 'other', 'RESV_tot', 'ph1', 'ph2', 'other',
                 'dist_ino', 'stream_lines'))]
    for r in rows:
        sb, rb = r['skip_by'], r['resv_by']
        out.append(note('%-9s %-7s %-7s %9d %7d %7d %7d | %9d %7d %7d %7d | %8s | %11d' %
                        ('fix' if r['kind'] == 'fix' else 'baseline', r['label'], r['node'], r['skip_n'],
                         sb.get('1', 0), sb.get('2', 0), r['skip_n'] - sb.get('1', 0) - sb.get('2', 0),
                         r['resv_n'], rb.get('1', 0), rb.get('2', 0), r['resv_n'] - rb.get('1', 0) - rb.get('2', 0),
                         str(r['dist']) if r['kind'] == 'fix' else 'n/a', r['nlines'])))
    return out


def b3_in_table(rows):
    out = [note("B3 RESTRICTED TO THE hf7 KERNEL-TIME RANGE (the lap's own window; these totals equal the kmsg.txt counters, see CONTEXT)"),
           note('%-9s %-7s %-7s %9s %7s %7s %7s | %9s %7s %7s %7s' %
                ('kind', 'lap', 'node', 'SKIP_in', 'ph1', 'ph2', 'other', 'RESV_in', 'ph1', 'ph2', 'other'))]
    for r in rows:
        sb, rb = r['in_by']['skip'], r['in_by']['resv']
        skip_in, resv_in = r['reg']['skip']['in'], r['reg']['resv']['in']
        out.append(note('%-9s %-7s %-7s %9d %7d %7d %7d | %9d %7d %7d %7d' %
                        ('fix' if r['kind'] == 'fix' else 'baseline', r['label'], r['node'],
                         skip_in, sb.get('1', 0), sb.get('2', 0), skip_in - sb.get('1', 0) - sb.get('2', 0),
                         resv_in, rb.get('1', 0), rb.get('2', 0), resv_in - rb.get('1', 0) - rb.get('2', 0))))
    return out


def context_table(rows):
    out = [note('CONTEXT: whole-stream tag lines split by the hf7.txt kernel-time range (pre/in/post), beside the lap\'s own kmsg.txt counters'),
           note('%-9s %-7s %-7s | %-17s | %-17s | %-13s %-13s %-13s | %-5s %-5s %-5s %-5s | in==counter' %
                ('kind', 'lap', 'node', 'stream kt', 'hf7 kt', 'RESV p/i/p', 'SKIP p/i/p', 'ULG p/i/p',
                 'c_res', 'c_ski', 'guard', 'c_ulg'))]
    for r in rows:
        g = r['reg']
        ctr = r['ctr'] or {}
        hf = r['hf7']

        def trio(name):
            return '%d/%d/%d' % (g[name]['pre'], g[name]['in'], g[name]['post'])

        def match(name, key):
            if key not in ctr:
                return 'n/a'
            return 'yes' if g[name]['in'] == ctr[key] else 'NO'
        out.append(note('%-9s %-7s %-7s | %8s %8s | %8s %8s | %-13s %-13s %-13s | %-5s %-5s %-5s %-5s | resv=%s skip=%s ulg=%s' %
                        ('fix' if r['kind'] == 'fix' else 'baseline', r['label'], r['node'],
                         fmt_s1(r['kt'][0]), fmt_s1(r['kt'][1]),
                         fmt_s1(hf[0]) if hf else 'n/a', fmt_s1(hf[1]) if hf else 'n/a',
                         trio('resv'), trio('skip'), trio('ulg'),
                         ctr.get('dialloc_resv_under_noino', 'n/a'), ctr.get('dialloc_resv_noino_skipped', 'n/a'),
                         ctr.get('noino_resv_guard', 'n/a'), ctr.get('noino_unlock_left_grant', 'n/a'),
                         match('resv', 'dialloc_resv_under_noino'), match('skip', 'dialloc_resv_noino_skipped'),
                         match('ulg', 'noino_unlock_left_grant'))))
    return out


def dup_table(rows):
    out = [note('OVERLAP: pre-/post-hf7 tag lines that also appear verbatim (same kt and text) in another PROVIDED stream of the same node'),
           note('(only streams given on this command line can be compared; a pre-hf7 line with no twin may belong to a lap that was not provided)'),
           note('%-9s %-7s %-7s | pre-hf7 lines also elsewhere: RESV     SKIP      ULG        | post-hf7 lines also elsewhere: RESV     SKIP      ULG' %
                ('kind', 'lap', 'node'))]
    for r in rows:
        peers = [o for o in rows if o is not r and o['node'] == r['node']]
        cells = []
        for region in ('pre', 'post'):
            parts = []
            for name in ('resv', 'skip', 'ulg'):
                twins = set()
                for o in peers:
                    for s in o['lines'][name].values():
                        twins |= s
                mine = r['lines'][name][region]
                parts.append('%d/%d' % (len(mine & twins), len(mine)))
            cells.append('%-9s %-9s %-9s' % tuple(parts))
        out.append(note('%-9s %-7s %-7s | %-48s | %s   (peers: %s)' %
                        ('fix' if r['kind'] == 'fix' else 'baseline', r['label'], r['node'], cells[0], cells[1],
                         ','.join(o['label'] for o in peers) or 'none')))
    return out


def run_job(job):
    gc.disable()
    if job[0] == 'window':
        return section_window(job[1], job[2])
    return section_lap(job[1], job[2], job[3], job[4], job[0])


def main():
    ap = argparse.ArgumentParser(description='Attribute P-DIALLOC / P-NOINO lines in lap kernel-log streams.')
    ap.add_argument('base')
    ap.add_argument('out')
    ap.add_argument('--window', action='append', default=[])
    ap.add_argument('--lap', action='append', default=[])
    ap.add_argument('--counts', action='append', default=[])
    ap.add_argument('--max-resv', type=int, default=40)
    ap.add_argument('--max-inos', type=int, default=15)
    ap.add_argument('--cap', type=int, default=30)
    ap.add_argument('--pad', default='1.5')
    ap.add_argument('--jobs', type=int, default=4)
    args = ap.parse_args()
    jobs = [('window', args.base, spec) for spec in args.window]
    for kind, specs in (('fix', args.lap), ('baseline', args.counts)):
        for spec in specs:
            label, dirname, nodes = parse_nodes(spec)
            for node in nodes:
                jobs.append((kind, args, label, dirname, node))
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(run_job, jobs))
    body = []
    laps = []
    rows = []
    for job, (chunks, row) in zip(jobs, results):
        if job[0] == 'window':
            body.extend(chunks)
        else:
            laps.extend(chunks)
            rows.append(row)
    legend = [note('# produced by scripts/noino_lap_attr.py'),
              note('# command: ' + ' '.join(sys.argv)),
              note('# line format: "<stream line number>:<verbatim stream line>"; the number is the 1-based line of `zcat <stream>`'),
              note('# a line names ino N when it contains "ino=N " or ends with "ino=N" (literal substring, no left boundary)'),
              note('# kernel time = the [secs.usecs] prefix; windows are inclusive; stream order is kept (each stream header reports its timestamp back-steps)'),
              note('# source: xfs/libxfs/xfs_ialloc.c:2366 and :2385 (working tree) emit the SKIP and RESV tags only while a static counter is <= 2000 '
                   '(per module lifetime); no __ratelimit guards those two sites'),
              note('# regions: pre/in/post = before / inside / after the kernel-time range of the lap\'s hf7.txt; counters are the lap\'s kmsg.txt')]
    tables = (summary_table(rows) + [note('')] + b3_in_table(rows) + [note('')] +
              context_table(rows) + [note('')] + dup_table(rows))
    final = legend + body + [BAR.encode()] + tables + laps
    with open(args.out, 'wb') as fh:
        for chunk in final:
            fh.write(chunk)
    total = sum(c.count(b'\n') for c in final)
    sys.stdout.write('wrote %s: %d lines\n' % (args.out, total))
    for chunk in tables:
        sys.stdout.write(chunk.decode())


if __name__ == '__main__':
    main()
