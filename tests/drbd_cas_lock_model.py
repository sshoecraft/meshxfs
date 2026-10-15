#!/usr/bin/env python3
"""Exhaustive check of the two-host lock that guards the DRBD compare-and-swap
emulation (pal/linux/drbd.c), under DRBD's storage model.

THE STORAGE MODEL.  Each host has its own disk.  A register write is issued
by its owner, lands on each of the two disks at its own moment (protocol C
replicates it; nothing orders the local landing against the remote one), and
completes for its writer only once both disks hold it.  A host reads its OWN
disk.  Every register has exactly one writer, so no two writes to one sector
are ever in flight together: the lock waits for its own release to complete
before it raises again.

THE LOCK ("one-bit", Burns-Lamport for two):
  index 0 (priority):  [defer while the peer's want is set, bounded]
                       raise {1,0}; wait until peer.number == 0; CRIT;
                       release {0,0} (completes after the caller returns)
  index 1:             raise {1,w}; read peer; if peer.number == 0: CRIT
                       else lower {0,1}, wait until peer.number == 0, retry
                       with w = 1; release {0,0} (completes later)
`want` only delays index 0 (fairness); it never admits anyone.

Checked over every interleaving and every landing order:
  - mutual exclusion: never both in CRIT;
  - no deadlock: from every reachable state some host can still reach CRIT;
  - index 1 is not starved: once its want is on index 0's disk and index 0
    has not raised again, index 1 reaches CRIT before index 0 enters again,
    provided index 0's deferral is not cut short by its bound.
The bakery (MODEL=bakery) is checked by the same harness as a control.

--ranges checks the lock as it runs now: a flag claims the sectors of its
batch, a participant enters with every sector the peer's flag does not claim,
and a waiting one may take a new batch (regroup); mutual exclusion is then per
sector.  --old / --old0 make host 1 / host 0 a node from before the ranges
(claims every sector, never enters partially).  ranged_steps says the rest.

Exit 0 when every property holds; 1 with a counterexample trace otherwise.
"""
import sys
from collections import deque

BROKEN = "--broken" in sys.argv
IDLE, WREL, DEFER, RAISE, RAISEW, CHECK, LOWER, LOWERW, BACKOFF, CRIT, RELEASE = range(11)
NAMES = "IDLE WREL DEFER RAISE RAISEW CHECK LOWER LOWERW BACKOFF CRIT RELEASE".split()


def onebit_steps(s, p):
    """Successors of host p's next action in state s (fairness=False lets the
    deferral bound fire)."""
    pc, w, disk, infl = s
    q = 1 - p
    out = []
    mine_landed = infl[p] is None
    peer = disk[p][q]  # host p reads its own disk: the peer's register there

    def put(npc=None, nw=None, ninfl=None):
        pcs = list(pc); ws = list(w); fl = list(infl)
        if npc is not None:
            pcs[p] = npc
        if nw is not None:
            ws[p] = nw
        if ninfl is not None:
            fl[p] = ninfl
        return (tuple(pcs), tuple(ws), disk, tuple(fl))

    cur = pc[p]
    if cur == IDLE:
        out.append(("start", put(WREL)))
    elif cur == WREL:                       # the last release must have completed
        if mine_landed:
            out.append(("rel-done", put(DEFER if p == 0 else RAISE, nw=0)))
    elif cur == DEFER:                      # index 0 only
        if peer[1] == 1:
            out.append(("defer", put(DEFER)))
            out.append(("defer-bound", put(RAISE)))
        else:
            out.append(("no-defer", put(RAISE)))
    elif cur == RAISE:
        val = (1, 0) if p == 0 else (1, w[p])
        # --broken: read the peer before the raise has completed (negative
        # control: the checker must find the violation)
        out.append(("raise", put(CHECK if BROKEN else RAISEW, ninfl=(val, False, False))))
    elif cur == RAISEW:
        if mine_landed:
            out.append(("raised", put(CHECK)))
    elif cur == CHECK:
        if peer[0] == 0:
            out.append(("enter", put(CRIT)))
        elif p == 0:
            out.append(("wait", put(CHECK)))
        else:
            out.append(("lose", put(LOWER)))
    elif cur == LOWER:
        out.append(("lower", put(LOWERW, ninfl=((0, 1), False, False))))
    elif cur == LOWERW:
        if mine_landed:
            out.append(("lowered", put(BACKOFF)))
    elif cur == BACKOFF:
        if peer[0] == 0:
            out.append(("retry", put(RAISE, nw=1)))
        else:
            out.append(("backoff", put(BACKOFF)))
    elif cur == CRIT:
        out.append(("exit", put(RELEASE)))
    elif cur == RELEASE:
        out.append(("release", put(IDLE, ninfl=((0, 0), False, False))))
    return out


def bakery_steps(s, p):
    """Lamport's bakery for two, register = (choosing, number).  Control."""
    pc, w, disk, infl = s
    q = 1 - p
    out = []
    mine_landed = infl[p] is None
    peer = disk[p][q]

    def put(npc=None, nw=None, ninfl=None):
        pcs = list(pc); ws = list(w); fl = list(infl)
        if npc is not None:
            pcs[p] = npc
        if nw is not None:
            ws[p] = nw
        if ninfl is not None:
            fl[p] = ninfl
        return (tuple(pcs), tuple(ws), disk, tuple(fl))

    cur = pc[p]
    # reuse the names: RAISE = choosing=1, RAISEW its wait, LOWER = read the
    # peer's number and publish ours, LOWERW its wait, CHECK = wait loop
    if cur == IDLE:
        out.append(("start", put(WREL)))
    elif cur == WREL:
        if mine_landed:
            out.append(("rel-done", put(RAISE)))
    elif cur == RAISE:
        out.append(("choosing", put(RAISEW, ninfl=((1, 0), False, False))))
    elif cur == RAISEW:
        if mine_landed:
            out.append(("chosen", put(LOWER)))
    elif cur == LOWER:
        mine = peer[1] + 1
        if mine > 4:
            # the real swap refuses a ticket past its bound (-EOVERFLOW) and
            # releases without entering; clipping it instead makes two tickets
            # tie at the cap
            out.append(("overflow", put(RELEASE)))
        else:
            out.append(("ticket", put(LOWERW, nw=mine, ninfl=((0, mine), False, False))))
    elif cur == LOWERW:
        if mine_landed:
            out.append(("published", put(CHECK)))
    elif cur == CHECK:
        pch, pnum = peer
        if not pch and (pnum == 0 or w[p] < pnum or (w[p] == pnum and p == 0)):
            out.append(("enter", put(CRIT)))
        else:
            out.append(("wait", put(CHECK)))
    elif cur == CRIT:
        out.append(("exit", put(RELEASE)))
    elif cur == RELEASE:
        out.append(("release", put(IDLE, ninfl=((0, 0), False, False))))
    return out


SET_A, SET_B, SET_ALL = 1, 2, 3


def ranged_steps(s, p):
    """The one-bit lock with target ranges (--ranges).  The sectors a batch
    swaps are a set drawn from {A, B}; the register carries
    (raised, want, set), and a set of 0 is a register written by a node
    before ranges existed, which claims every sector.

      raise:   {1, w, set} -- the batch's sectors, fixed for this raise
      check:   peer down, or peer up with a set disjoint from ours: enter with
               every sector; peer up and overlapping: enter with the sectors
               of ours it does not claim, if any (partial entry), else index 0
               waits and index 1 lowers {0, 1, set} and backs off as before
      defer:   index 0 defers only to a want whose set overlaps its own
      backoff: index 1 retries once any sector of its batch is free
      regroup: a waiting host may take a new batch (new swaps queued); it
               writes its register again (raise or lower) before it reads the
               peer again
    With --old (--old0), host 1 (host 0) is a node from before ranges: its
    set is always 0 (every sector), it never enters partially and never
    regroups.

    State: (pc, w, sets, crits, disk, infl); crits[p] is the set host p
    writes in CRIT.  Mutual exclusion is now per sector: never both in CRIT
    with intersecting crits."""
    pc, w, sets, crits, disk, infl = s
    q = 1 - p
    out = []
    mine_landed = infl[p] is None
    peer = disk[p][q]                    # (raised, want, set)
    old = OLD and p == OLD_HOST

    def claims(st):
        return SET_ALL if st == 0 else st

    def put(npc=None, nw=None, nset=None, ncrit=None, ninfl=None):
        pcs = list(pc); ws = list(w); ss = list(sets); cs = list(crits); fl = list(infl)
        if npc is not None:
            pcs[p] = npc
        if nw is not None:
            ws[p] = nw
        if nset is not None:
            ss[p] = nset
        if ncrit is not None:
            cs[p] = ncrit
        if ninfl is not None:
            fl[p] = ninfl
        return (tuple(pcs), tuple(ws), tuple(ss), tuple(cs), disk, tuple(fl))

    choices = (0,) if old else (SET_A, SET_B, SET_ALL)
    mine = claims(sets[p])
    cur = pc[p]
    if cur == IDLE:
        for st in choices:
            out.append((f"start{st}", put(WREL, nset=st)))
    elif cur == WREL:
        if mine_landed:
            out.append(("rel-done", put(DEFER if p == 0 else RAISE, nw=0)))
    elif cur == DEFER:                   # index 0 only
        if peer[1] == 1 and claims(peer[2]) & mine:
            out.append(("defer", put(DEFER)))
            out.append(("defer-bound", put(RAISE)))
        else:
            out.append(("no-defer", put(RAISE)))
    elif cur == RAISE:
        val = (1, 0 if p == 0 else w[p], sets[p])
        out.append(("raise", put(CHECK if BROKEN else RAISEW, ninfl=(val, False, False))))
    elif cur == RAISEW:
        if mine_landed:
            out.append(("raised", put(CHECK)))
    elif cur == CHECK:
        theirs = claims(peer[2]) if peer[0] else 0
        free = mine & ~theirs
        if not theirs & mine:
            out.append(("enter", put(CRIT, ncrit=mine)))
        elif free and not old:
            out.append(("enter-partial", put(CRIT, ncrit=free)))
        elif p == 0:
            out.append(("wait", put(CHECK)))
            for st in choices:
                if st != sets[p]:
                    out.append((f"regroup{st}", put(RAISE, nset=st)))
        else:
            out.append(("lose", put(LOWER)))
    elif cur == LOWER:
        out.append(("lower", put(LOWERW, ninfl=((0, 1, sets[p]), False, False))))
    elif cur == LOWERW:
        if mine_landed:
            out.append(("lowered", put(BACKOFF)))
    elif cur == BACKOFF:
        theirs = claims(peer[2]) if peer[0] else 0
        if (mine & ~theirs) if not old else not theirs:
            out.append(("retry", put(RAISE, nw=1)))
        else:
            out.append(("backoff", put(BACKOFF)))
            for st in choices:
                if st != sets[p]:
                    out.append((f"regroup{st}", put(LOWER, nset=st)))
    elif cur == CRIT:
        out.append(("exit", put(RELEASE, ncrit=0)))
    elif cur == RELEASE:
        out.append(("release", put(IDLE, ninfl=((0, 0, sets[p]), False, False))))
    return out


def ranged_landings(s):
    pc, w, sets, crits, disk, infl = s
    out = []
    for p in (0, 1):
        if infl[p] is None:
            continue
        val, l0, l1 = infl[p]
        for d, landed in ((0, l0), (1, l1)):
            if landed:
                continue
            nd = [list(disk[0]), list(disk[1])]
            nd[d][p] = val
            nl0, nl1 = (True, l1) if d == 0 else (l0, True)
            fl = list(infl)
            fl[p] = None if (nl0 and nl1) else (val, nl0, nl1)
            out.append((f"land{p}->disk{d}", (pc, w, sets, crits, (tuple(nd[0]), tuple(nd[1])), tuple(fl))))
    return out


def ranged_main():
    zero = ((0, 0, 0), (0, 0, 0))
    init = ((IDLE, IDLE), (0, 0), (0, 0), (0, 0), (zero, zero), (None, None))
    seen = {init: None}
    edges = {}
    dq = deque([init])
    bad = None
    while dq:
        s = dq.popleft()
        if s[0][0] == CRIT and s[0][1] == CRIT and s[3][0] & s[3][1]:
            bad = s
            break
        succ = [(p, name, t) for p in (0, 1) for name, t in ranged_steps(s, p)]
        succ += [(None, name, t) for name, t in ranged_landings(s)]
        edges[s] = succ
        for p, name, t in succ:
            if t not in seen:
                seen[t] = (s, p, name)
                dq.append(t)
    tag = "ranges" + (" (host %d from before ranges)" % OLD_HOST if OLD else "")
    if bad:
        trace = []
        cur = bad
        while seen[cur] is not None:
            prev, p, name = seen[cur]
            trace.append(f"  host{p if p is not None else '-'} {name}")
            cur = prev
        print(f"{tag}: MUTUAL EXCLUSION VIOLATED (a sector in both CRITs) after {len(trace)} steps:")
        print("\n".join(reversed(trace)))
        return 1

    def can_reach(pred, allowed=lambda p, name, t: True):
        rev = {}
        for s, succ in edges.items():
            for p, name, t in succ:
                if allowed(p, name, t):
                    rev.setdefault(t, []).append(s)
        good = {s for s in seen if pred(s)}
        dq2 = deque(good)
        while dq2:
            t = dq2.popleft()
            for s in rev.get(t, ()):
                if s not in good:
                    good.add(s)
                    dq2.append(s)
        return good

    live = can_reach(lambda s: CRIT in s[0])
    dead = [s for s in seen if s not in live]
    if dead:
        s = dead[0]
        print(f"{tag}: DEADLOCK reachable, e.g. pcs={[NAMES[x] for x in s[0]]} sets={s[2]} disk={s[4]} inflight={s[5]}")
        return 1
    # host 1 reaches CRIT once its want is on host 0's disk, without host 0
    # entering again over any sector host 1 claims, without host 0's deferral
    # being cut short by its bound, and without host 1 regrouping (a regroup is
    # a new batch, not the one that lost)
    trying1 = {RAISE, RAISEW, CHECK, LOWER, LOWERW, BACKOFF}

    def blocks(p, name, t):
        if p == 0 and name == "defer-bound":
            return False
        if p == 1 and name.startswith("regroup"):
            return False
        if p == 0 and name.startswith("enter"):
            mine1 = SET_ALL if t[2][1] == 0 else t[2][1]
            if t[3][0] & mine1:
                return False
        return True
    reach1 = can_reach(lambda s: s[0][1] == CRIT, blocks)
    starved = [s for s in seen if s[0][1] in trying1 and s[4][0][1][1] == 1
               and s[0][0] in (IDLE, WREL, DEFER) and s not in reach1]
    if starved:
        s = starved[0]
        print(f"{tag}: host 1 can be STARVED, e.g. pcs={[NAMES[x] for x in s[0]]} sets={s[2]} disk={s[4]} inflight={s[5]}")
        return 1
    print(f"{tag}: {len(seen)} states; per-sector mutual exclusion holds, no deadlock; "
          "host 1 always reaches CRIT before host 0 enters again over a sector it claims")
    return 0


OLD = "--old" in sys.argv or "--old0" in sys.argv
OLD_HOST = 0 if "--old0" in sys.argv else 1


def landings(s):
    pc, w, disk, infl = s
    out = []
    for p in (0, 1):
        if infl[p] is None:
            continue
        val, l0, l1 = infl[p]
        for d, landed in ((0, l0), (1, l1)):
            if landed:
                continue
            nd = [list(disk[0]), list(disk[1])]
            nd[d][p] = val
            nl0, nl1 = (True, l1) if d == 0 else (l0, True)
            fl = list(infl)
            fl[p] = None if (nl0 and nl1) else (val, nl0, nl1)
            out.append((f"land{p}->disk{d}", (pc, w, (tuple(nd[0]), tuple(nd[1])), tuple(fl))))
    return out


def successors(s, steps):
    out = []
    for p in (0, 1):
        for name, t in steps(s, p):
            out.append((p, name, t))
    for name, t in landings(s):
        out.append((None, name, t))
    return out


def main():
    if "--ranges" in sys.argv:
        return ranged_main()
    model = "bakery" if "--bakery" in sys.argv else "onebit"
    steps = bakery_steps if model == "bakery" else onebit_steps
    zero = ((0, 0), (0, 0))
    init = ((IDLE, IDLE), (0, 0), (zero, zero), (None, None))
    seen = {init: None}
    edges = {}
    dq = deque([init])
    bad = None
    while dq:
        s = dq.popleft()
        if s[0][0] == CRIT and s[0][1] == CRIT:
            bad = s
            break
        succ = successors(s, steps)
        edges[s] = succ
        for p, name, t in succ:
            if t not in seen:
                seen[t] = (s, p, name)
                dq.append(t)
    if bad:
        trace = []
        cur = bad
        while seen[cur] is not None:
            prev, p, name = seen[cur]
            trace.append(f"  host{p if p is not None else '-'} {name}")
            cur = prev
        print(f"{model}: MUTUAL EXCLUSION VIOLATED after {len(trace)} steps:")
        print("\n".join(reversed(trace)))
        return 1

    def can_reach(pred, allowed=lambda p, name, t: True):
        # states from which a state satisfying pred is reachable using only
        # allowed edges (backward fixpoint)
        rev = {}
        for s, succ in edges.items():
            for p, name, t in succ:
                if allowed(p, name, t):
                    rev.setdefault(t, []).append(s)
        good = {s for s in seen if pred(s)}
        dq2 = deque(good)
        while dq2:
            t = dq2.popleft()
            for s in rev.get(t, ()):
                if s not in good:
                    good.add(s)
                    dq2.append(s)
        return good

    live = can_reach(lambda s: CRIT in s[0])
    dead = [s for s in seen if s not in live]
    if dead:
        s = dead[0]
        print(f"{model}: DEADLOCK reachable, e.g. pcs={[NAMES[x] for x in s[0]]} disk={s[2]} inflight={s[3]}")
        return 1

    trying1 = {RAISE, RAISEW, CHECK, LOWER, LOWERW, BACKOFF}
    # host 1 reaches CRIT without host 0 entering, and with host 0's deferral
    # bound never cutting a deferral short (the bound exists only for a peer
    # that died with want set)
    reach1 = can_reach(lambda s: s[0][1] == CRIT,
                       lambda p, name, t: not (p == 0 and name in ("enter", "defer-bound")))
    # Starting points: host 1 lost a race (its want is on host 0's disk) and
    # host 0 has not yet raised again.  host 0 may enter once more if it had
    # already raised; this asks about every later entry.
    starved = [s for s in seen if s[0][1] in trying1 and s[2][0][1][1] == 1
               and s[0][0] in (IDLE, WREL, DEFER) and s not in reach1]
    if starved and model == "onebit":
        s = starved[0]
        print(f"{model}: host 1 can be STARVED, e.g. pcs={[NAMES[x] for x in s[0]]} disk={s[2]} inflight={s[3]}")
        return 1
    print(f"{model}: {len(seen)} states; mutual exclusion holds, no deadlock"
          + ("; host 1 always reaches CRIT before host 0 can enter again" if model == "onebit" else
             f"; host 1 starvable from {len(starved)} states without host 0 entering (FIFO by ticket instead)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
