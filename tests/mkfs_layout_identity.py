#!/usr/bin/env python3
"""Does a change to mkfs.mxfs keep a volume's layout byte for byte?

    tests/mkfs_layout_identity.py image MKFS IMAGE SIZE_MIB [SECTOR_BYTES [MKFS_ARG...]]
    tests/mkfs_layout_identity.py compare REFERENCE CANDIDATE
    tests/mkfs_layout_identity.py against REF_MKFS MKFS DIR SIZE_MIB [SECTOR_BYTES]

image    formats IMAGE, a sparse file of SIZE_MIB MiB, through a loop device whose logical
         blocks are SECTOR_BYTES (512 by default; 4096 makes a 4K-native device), with the
         mkfs binary MKFS and every input it takes from outside fixed: SOURCE_DATE_EPOCH
         pins the time its timestamps carry, and in a private mount namespace a file of
         fixed bytes is bound over /dev/urandom, from which it draws the filesystem uuid and
         the authority ledger's seed.  Two images formatted so by one binary are identical,
         so between two binaries every difference is the binaries'.  Any MKFS_ARG is passed
         to mkfs before -f and the device.
compare  every range of bytes in which two images differ, named by the region of the
         reference's MXFS envelope it lies in (and, in the XFS data area, by allocation
         group and block).  Identical images exit 0.
against  formats DIR/reference.img with REF_MKFS, a mkfs that ignores SOURCE_DATE_EPOCH and
         stamps the wall clock (0.90.132's, from dpkg-deb -x of its package), inside one
         wall-clock second, read before and after; a format that straddles a second is done
         again.  Then DIR/candidate.img with MKFS, its SOURCE_DATE_EPOCH that second, and the
         two are compared as above.  Exit as compare.

The loop device and the bind mount need root, so those commands go through `sudo -n`.
mkfs's own output is kept beside the image (IMAGE.mkfs.txt), with the fixed bytes
(IMAGE.random).  Exit 0 formatted / identical, 1 mkfs failed / the images differ, 2 could
not run.
"""
import os
import struct
import subprocess
import sys
import time

EPOCH = "1700000000"
# The fixed bytes /dev/urandom reads as: mkfs reads 16 for the uuid and 8 for the seed, each
# from a fresh open, so both come from the start; a zero seed is refused, and this one is not.
RANDOM = bytes((i * 37 + 11) & 0xFF for i in range(4096))
CHUNK = 4 << 20
REPORT = 40
# Bounds: losetup's attach and detach are single ioctls; a format of a 2 GiB loop image at
# 512 took 0.1 s, sudo and the namespace included (2026-10-22).
LOSETUP_S = 10
MKFS_S = 30
# against: formats tried for one that starts and ends in the same second; at 0.1 s a format,
# three straddling one in a row would mean the clock read is broken, not bad luck.
SECOND_TRIES = 3

# struct mxfs_ondisk_super (include/mxfs/mxfs_super.h): the region offsets and sizes
ENVELOPE = (("journal", 48, 56), ("disklock", 64, 72), ("manifests", 112, 120),
            ("authority ledger", 128, 136), ("PR registrants", 144, 152),
            ("bootstrap", 160, 168), ("slice lifecycle", 176, 184))
MAGIC = 0x5346584D


def sudo(args, timeout):
    return subprocess.run(["sudo", "-n", "timeout", str(timeout)] + args,
                          capture_output=True, text=True)


def cmd_image(mkfs, image, size_mib, sector, extra, epoch=EPOCH):
    if not os.access(mkfs, os.X_OK):
        print("ABORT: %s is not an executable mkfs" % mkfs)
        return 2
    with open(image, "wb") as handle:
        handle.truncate(size_mib << 20)
    rand = image + ".random"
    with open(rand, "wb") as handle:
        handle.write(RANDOM)
    att = sudo(["losetup", "-f", "--show", "--sector-size", str(sector), image], LOSETUP_S)
    loop = att.stdout.strip()
    if att.returncode != 0 or not loop.startswith("/dev/loop"):
        print("ABORT: losetup did not attach %s: rc=%d %s" % (image, att.returncode,
                                                              att.stderr.strip()))
        return 2
    try:
        start = time.monotonic()
        run = sudo(["env", "SOURCE_DATE_EPOCH=" + epoch, "unshare", "-m", "sh", "-c",
                    'r=$1 m=$2 d=$3; shift 3; mount --bind "$r" /dev/urandom && exec "$m" "$@" -f "$d"',
                    "sh", rand, os.path.abspath(mkfs), loop] + extra, MKFS_S)
        wall = time.monotonic() - start
    finally:
        sudo(["losetup", "-d", loop], LOSETUP_S)
    with open(image + ".mkfs.txt", "w") as handle:
        handle.write(run.stdout + run.stderr)
    print("IMAGE %s size=%dMiB sector=%d mkfs=%s %s rc=%d wall=%.1fs" % (
        image, size_mib, sector, mkfs, " ".join(extra), run.returncode, wall))
    if run.returncode != 0:
        print("  mkfs: %s" % (run.stdout + run.stderr).strip().splitlines()[-1:])
        return 1
    return 0


def regions(handle):
    """(name, start, end) of every region the envelope names, then the XFS data area."""
    head = handle.read(4096)
    if len(head) < 4096 or struct.unpack_from("<I", head, 0)[0] != MAGIC:
        return None
    out = [("envelope", 0, 4096)]
    for name, off_at, size_at in ENVELOPE:
        off, size = struct.unpack_from("<QQ", head, off_at)[0], struct.unpack_from("<Q", head, size_at)[0]
        if size:
            out.append((name, off, off + size))
    xfs = struct.unpack_from("<Q", head, 88)[0]
    handle.seek(xfs + 84)
    agblocks = struct.unpack(">I", handle.read(4))[0]
    out.append(("XFS data", xfs, 1 << 62))
    return out, xfs, agblocks


def where(offset, named):
    table, xfs, agblocks = named
    for name, start, end in table:
        if start <= offset < end:
            if name == "XFS data":
                block = (offset - xfs) // 4096
                return "XFS data AG %d block %d" % (block // agblocks, block % agblocks) \
                    if agblocks else "XFS data"
            return "%s +%d" % (name, offset - start)
    return "between regions"


def cmd_compare(ref, cand):
    if os.path.getsize(ref) != os.path.getsize(cand):
        print("DIFFER sizes %d and %d" % (os.path.getsize(ref), os.path.getsize(cand)))
        return 1
    with open(ref, "rb") as a, open(cand, "rb") as b:
        named = regions(a)
        if not named:
            print("ABORT: %s carries no MXFS envelope" % ref)
            return 2
        a.seek(0)
        ranges, base, start = [], 0, None
        while True:
            x, y = a.read(CHUNK), b.read(CHUNK)
            if not x:
                break
            if x != y:
                for i in range(len(x)):
                    if x[i] != y[i]:
                        if start is None:
                            start = base + i
                    elif start is not None:
                        ranges.append((start, base + i))
                        start = None
            elif start is not None:
                ranges.append((start, base))
                start = None
            base += len(x)
        if start is not None:
            ranges.append((start, base))
    total = sum(e - s for s, e in ranges)
    for s, e in ranges[:REPORT]:
        print("  DIFF %d-%d (%d bytes) %s" % (s, e - 1, e - s, where(s, named)))
    if len(ranges) > REPORT:
        print("  ... %d more ranges" % (len(ranges) - REPORT))
    print("%s %s %s: %d differing range(s), %d byte(s)" % (
        "IDENTICAL" if not ranges else "DIFFER", ref, cand, len(ranges), total))
    return 0 if not ranges else 1


def cmd_against(ref_mkfs, mkfs, out, size_mib, sector):
    os.makedirs(out, exist_ok=True)
    ref, cand = os.path.join(out, "reference.img"), os.path.join(out, "candidate.img")
    second = None
    for attempt in range(1, SECOND_TRIES + 1):
        before = int(time.time())
        rc = cmd_image(ref_mkfs, ref, size_mib, sector, [])
        after = int(time.time())
        if rc != 0:
            return rc
        print("  reference format %d: wall clock %d to %d" % (attempt, before, after))
        if before == after:
            second = str(before)
            break
    if second is None:
        print("ABORT: %d reference formats each straddled a second" % SECOND_TRIES)
        return 2
    rc = cmd_image(mkfs, cand, size_mib, sector, [], epoch=second)
    if rc != 0:
        return rc
    print("  candidate formatted at SOURCE_DATE_EPOCH=%s, the reference's second" % second)
    return cmd_compare(ref, cand)


def main(argv):
    if len(argv) >= 5 and argv[1] == "image":
        try:
            size = int(argv[4])
            sector = int(argv[5]) if len(argv) > 5 else 512
        except ValueError:
            size = sector = 0
        if size > 0 and sector in (512, 4096):
            return cmd_image(argv[2], argv[3], size, sector, argv[6:])
    if len(argv) == 4 and argv[1] == "compare":
        return cmd_compare(argv[2], argv[3])
    if len(argv) in (6, 7) and argv[1] == "against":
        try:
            size = int(argv[5])
            sector = int(argv[6]) if len(argv) > 6 else 512
        except ValueError:
            size = sector = 0
        if size > 0 and sector in (512, 4096):
            return cmd_against(argv[2], argv[3], argv[4], size, sector)
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
