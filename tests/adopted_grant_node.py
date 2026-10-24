#!/usr/bin/env python3
"""adopted_grant_node.py -- the node side of tests/adopted_grant_rig_lap.sh.

Runs on a rig node, from the tree the node mounts at /src/<tree>, as root.

  pick <dev> <dir> <host=id>...
      For every file in <dir> (the first of each routing shard), the ledger page its inode lock
      routes to (tools/tauth_page_auth.py inode_page over the region's own geometry) and that
      page's master: the sorted active node ids [page % N] (dlm/dlm.c dlm_page_master_locked).
      Prints the first file, and the nodes A B C D, such that B masters it under all the given
      nodes and A masters it once D has left:
        PICK ino=<n> page=<p> file=<path> A=<host> B=<host> C=<host> D=<host>
      or NOPICK with the count examined.
  page-auth <dev> <page>
      The page's authority as the platter holds it (the copy with the higher commit seq):
        PAGEAUTH page=<p> state=<UNOWNED|ACTIVE|PREPARED> node=<id> seq=<n>
  hold-write <file> <go-file> <byte>
      Opens <file> read-write and prints OPENED, then waits for <go-file> to exist and writes
      4 KiB of <byte> at offset 0 through that descriptor, so the write asks for the inode's
      exclusive lock with the open already done: WROTE rc=<errno or 0> ms=<n> t0=<s> t1=<s>.
  read <file>
      DIGEST=<md5 of the file's first 4 KiB>, read with O_DIRECT so the node's page cache is not
      what answers.
"""
import hashlib
import mmap
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import tauth_page_auth as tpa  # noqa: E402


def geometry(dev):
    with tpa.DirectDev(dev) as f:
        base, vid = tpa.super_fields(f)
        npages, seed, hver = tpa.region_geometry(f, base)
    return base, vid, npages, seed, hver


def pick(dev, d, pairs):
    hosts = {}
    for p in pairs:
        h, i = p.split("=", 1)
        hosts[int(i)] = h
    ids = sorted(hosts)
    n = len(ids)
    base, vid, npages, seed, hver = geometry(dev)
    if not npages:
        print("NOPICK reason=no-region-geometry base=%d" % base)
        return 2
    print("GEOM base=%d npages=%d seed=%#x hash_version=%d nodes=%d" % (base, npages, seed, hver, n))
    seen = set()
    examined = 0
    for name in sorted(os.listdir(d)):
        path = os.path.join(d, name)
        ino = os.stat(path).st_ino
        shard = ino >> 3 if hver >= 2 else ino
        if shard in seen:
            continue
        seen.add(shard)
        examined += 1
        page = tpa.inode_page(vid, ino, seed, npages, hver)
        b = ids[page % n]
        for dd in ids:
            if dd == b:
                continue
            rest = [x for x in ids if x != dd]
            a = rest[page % (n - 1)]
            if a in (b, dd):
                continue
            c = next(x for x in ids if x not in (a, b, dd))
            print("PICK ino=%d page=%d file=%s A=%s B=%s C=%s D=%s ida=%d idb=%d idc=%d idd=%d"
                  % (ino, page, path, hosts[a], hosts[b], hosts[c], hosts[dd], a, b, c, dd))
            return 0
    print("NOPICK examined=%d" % examined)
    return 1


def page_auth(dev, page):
    base, _vid, npages, _seed, _hver = geometry(dev)
    best = None
    with tpa.DirectDev(dev) as f:
        for copy in (0, 1):
            f.seek(base + (2 + 3 + copy * npages + page) * tpa.PAGE)
            got = tpa.decode(f.read(tpa.PAGE), page)
            if got and (best is None or got[0] > best[0]):
                best = got
    if best is None:
        print("PAGEAUTH page=%d state=NONE node=0 seq=0" % page)
        return 1
    seq, (state, node, _epoch, _tnode, _tinc), _buf = best
    print("PAGEAUTH page=%d state=%s node=%d seq=%d" % (page, state, node, seq))
    return 0


def hold_write(path, go, byte):
    fd = os.open(path, os.O_RDWR)
    print("OPENED", flush=True)
    while not os.path.exists(go):
        time.sleep(0.02)
    t0 = time.time()
    rc = 0
    try:
        os.pwrite(fd, bytes([ord(byte)]) * 4096, 0)
    except OSError as e:
        rc = e.errno
    t1 = time.time()
    os.close(fd)
    print("WROTE rc=%d ms=%d t0=%.3f t1=%.3f" % (rc, (t1 - t0) * 1000, t0, t1), flush=True)
    return 0 if rc == 0 else 1


def read_digest(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECT)
    buf = mmap.mmap(-1, 4096)
    try:
        got = os.preadv(fd, [buf], 0)
        print("DIGEST=%s n=%d" % (hashlib.md5(bytes(buf[:got])).hexdigest(), got))
    finally:
        buf.close()
        os.close(fd)
    return 0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "pick" and len(args) >= 4:
        return pick(args[0], args[1], args[2:])
    if cmd == "page-auth" and len(args) == 2:
        return page_auth(args[0], int(args[1]))
    if cmd == "hold-write" and len(args) == 3:
        return hold_write(args[0], args[1], args[2])
    if cmd == "read" and len(args) == 1:
        return read_digest(args[0])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
