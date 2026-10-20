#!/usr/bin/env python3
"""Reach a peer's held-open unlinked inode through a file handle.

  handle_reopen.py make <dir> <n> <handlefile> <pidfile> <hold_s>
      create n files in <dir>, write each one's file handle
      (name_to_handle_at) to <handlefile> as hex, unlink every file while
      holding it open, hold them for <hold_s> seconds, then close them.
  handle_reopen.py open <mountpoint> <handlefile>
      open_by_handle_at every handle on THIS node and print how each ended.
  handle_reopen.py hold <path> <mountpoint> <trigger> <resultfile> <wait_s>
      take <path>'s file handle through an O_PATH descriptor and keep that
      descriptor, so this node's in-core inode stays cached without the file
      being open; when <trigger> appears (at most <wait_s> seconds), open the
      handle, read the file and write how it ended to <resultfile>.
  handle_reopen.py gen <path>
      print the generation <path>'s file handle carries.

On a node that never had those inodes in core, opening a handle reads the
inode from disk with nlink 0 and an incomplete in-core unlinked list, so
xfs_nfs_get_inode reloads its AGI bucket (pal/linux/xfs_export.c ->
xfs_inode_reload_unlinked).  That is the cluster-mount path whose line was
upstream XFS's "Found unrecovered unlinked inode ... Initiating recovery".

`hold` is the other case: the handle's inode is still cached on this node
after a peer removed the file and freed its number, so the open is a cache
hit and the read is what asks the peer for the inode's lock.

prints (make): HANDLES made=<n> held=<n>
prints (open): HANDLE-OPEN tried=<n> ok=<n> estale=<n> other=<n> [errnos=...]
prints (hold): HOLD ino=<n> gen=<n>, then to <resultfile>
               HANDLE-READ rc=ok ms=<n> ino=<n> nlink=<n> size=<n> gen=<n> data=<hex>
               or HANDLE-READ rc=<errno name> stage=open|read ms=<n>
               or HANDLE-READ rc=NOTRIGGER
"""
import struct
import ctypes
import ctypes.util
import errno
import os
import sys
import time

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
MAX_HANDLE_SZ = 128
AT_FDCWD = -100
AT_EMPTY_PATH = 0x1000


class FileHandle(ctypes.Structure):
    _fields_ = [("handle_bytes", ctypes.c_uint),
                ("handle_type", ctypes.c_int),
                ("f_handle", ctypes.c_ubyte * MAX_HANDLE_SZ)]


def make(d, n, hfile, pidfile, hold_s):
    with open(pidfile, "w") as f:
        f.write(str(os.getpid()))
    fds = []
    lines = []
    for i in range(n):
        p = os.path.join(d, "h%04d" % i)
        fd = os.open(p, os.O_CREAT | os.O_WRONLY, 0o644)
        os.write(fd, b"h" * 512)
        os.fsync(fd)
        fh = FileHandle()
        fh.handle_bytes = MAX_HANDLE_SZ
        mid = ctypes.c_int()
        if libc.name_to_handle_at(AT_FDCWD, p.encode(), ctypes.byref(fh),
                                  ctypes.byref(mid), 0) != 0:
            e = ctypes.get_errno()
            raise OSError(e, "name_to_handle_at " + p)
        raw = bytes(fh.f_handle[:fh.handle_bytes])
        lines.append("%d %s" % (fh.handle_type, raw.hex()))
        os.unlink(p)
        fds.append(fd)
    with open(hfile, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("HANDLES made=%d held=%d" % (len(lines), len(fds)), flush=True)
    time.sleep(hold_s)
    for fd in fds:
        os.close(fd)


def openall(mnt, hfile):
    mfd = os.open(mnt, os.O_RDONLY | os.O_DIRECTORY)
    tried = ok = estale = other = 0
    errs = {}
    for ln in open(hfile):
        ln = ln.split()
        if len(ln) != 2:
            continue
        raw = bytes.fromhex(ln[1])
        fh = FileHandle()
        fh.handle_type = int(ln[0])
        fh.handle_bytes = len(raw)
        ctypes.memmove(fh.f_handle, raw, len(raw))
        tried += 1
        fd = libc.open_by_handle_at(mfd, ctypes.byref(fh), os.O_RDONLY)
        if fd >= 0:
            ok += 1
            os.close(fd)
            continue
        e = ctypes.get_errno()
        if e == errno.ESTALE:
            estale += 1
        else:
            other += 1
            errs[e] = errs.get(e, 0) + 1
    os.close(mfd)
    line = "HANDLE-OPEN tried=%d ok=%d estale=%d other=%d" % (tried, ok, estale, other)
    if errs:
        line += " errnos=" + ",".join("%s:%d" % (errno.errorcode.get(k, k), v)
                                      for k, v in sorted(errs.items()))
    print(line)


def fd_handle(fd, what):
    fh = FileHandle()
    fh.handle_bytes = MAX_HANDLE_SZ
    mid = ctypes.c_int()
    if libc.name_to_handle_at(fd, b"", ctypes.byref(fh), ctypes.byref(mid),
                              AT_EMPTY_PATH) != 0:
        e = ctypes.get_errno()
        raise OSError(e, "name_to_handle_at " + what)
    return fh


def handle_gen(fh):
    # the generation follows the inode number in both of xfs_fs_encode_fh's
    # layouts: a u32 in struct fid's i32, a u64 in the packed xfs_fid64 that
    # XFS_FILEID_TYPE_64FLAG (0x80) selects (MXFS answers FS_IOC_GETVERSION
    # with ENOTTY)
    raw = bytes(fh.f_handle[:fh.handle_bytes])
    return struct.unpack_from("<I", raw, 8 if fh.handle_type & 0x80 else 4)[0]


def hold(path, mnt, trigger, result, wait_s):
    mfd = os.open(mnt, os.O_RDONLY | os.O_DIRECTORY)
    pfd = os.open(path, os.O_PATH)
    fh = fd_handle(pfd, path)
    print("HOLD ino=%d gen=%d" % (os.fstat(pfd).st_ino, handle_gen(fh)), flush=True)
    deadline = time.monotonic() + wait_s
    while not os.path.exists(trigger):
        if time.monotonic() > deadline:
            with open(result, "w") as f:
                f.write("HANDLE-READ rc=NOTRIGGER\n")
            return
        time.sleep(0.005)
    t0 = time.monotonic()
    fd = libc.open_by_handle_at(mfd, ctypes.byref(fh), os.O_RDONLY)
    if fd < 0:
        e = ctypes.get_errno()
        line = "HANDLE-READ rc=%s stage=open ms=%d" % (
            errno.errorcode.get(e, e), (time.monotonic() - t0) * 1000)
    else:
        try:
            data = os.read(fd, 64)
            st = os.fstat(fd)
            line = "HANDLE-READ rc=ok ms=%d ino=%d nlink=%d size=%d gen=%d data=%s" % (
                (time.monotonic() - t0) * 1000, st.st_ino, st.st_nlink,
                st.st_size, handle_gen(fd_handle(fd, "the opened handle")),
                data.hex() or "-")
        except OSError as ex:
            line = "HANDLE-READ rc=%s stage=read ms=%d" % (
                errno.errorcode.get(ex.errno, ex.errno),
                (time.monotonic() - t0) * 1000)
        os.close(fd)
    os.close(mfd)
    os.close(pfd)
    with open(result, "w") as f:
        f.write(line + "\n")
    print(line, flush=True)


if sys.argv[1] == "make":
    make(sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5], float(sys.argv[6]))
elif sys.argv[1] == "open":
    openall(sys.argv[2], sys.argv[3])
elif sys.argv[1] == "hold":
    hold(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], float(sys.argv[6]))
elif sys.argv[1] == "gen":
    gfd = os.open(sys.argv[2], os.O_PATH)
    print(handle_gen(fd_handle(gfd, sys.argv[2])))
    os.close(gfd)
else:
    sys.exit("usage: handle_reopen.py make|open|hold|gen ...")
