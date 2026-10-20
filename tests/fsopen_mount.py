#!/usr/bin/env python3
"""fsopen_mount.py — mount through the kernel's mount API (fsopen, fsconfig,
fsmount, move_mount) and print every message the filesystem logged into the
mount context, as util-linux >= 2.40's mount(8) does.

util-linux 2.39 (Ubuntu 24.04, this rig's nodes) mounts through the same
fsopen/fsconfig calls but never reads the context, so a refusal's errorfc()
text reaches neither its stderr nor the kernel log; this client reads it.

Usage: fsopen_mount.py <fstype> <device> <mountpoint> [key[=value] ...]
Prints one 'fc: <message>' line per context message (the kernel prefixes
each with e/w/i), then
    result: rc=<0|errno> err=<name> step=<source|option|create|fsmount|move_mount>
Exit 0 mounted, 1 refused with an errno, 2 usage or the API unavailable.
x86_64 syscall numbers.
"""
import ctypes
import errno
import os
import sys

NR_MOVE_MOUNT, NR_FSOPEN, NR_FSCONFIG, NR_FSMOUNT = 429, 430, 431, 432
FSOPEN_CLOEXEC = 1
FSCONFIG_SET_FLAG, FSCONFIG_SET_STRING, FSCONFIG_CMD_CREATE = 0, 1, 6
FSMOUNT_CLOEXEC = 1
MOVE_MOUNT_F_EMPTY_PATH = 4
AT_FDCWD = -100

libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long


def sc(nr, *args):
    r = libc.syscall(ctypes.c_long(nr), *args)
    if r < 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e))
    return r


def cstr(s):
    return ctypes.c_char_p(s.encode()) if s is not None else ctypes.c_void_p(None)


def drain(fd):
    out = []
    while True:
        try:
            b = os.read(fd, 4096)
        except OSError as e:
            if e.errno == errno.ENODATA:
                break
            out.append('(context read failed: %s)' % e.strerror)
            break
        if not b:
            break
        out.append(b.decode(errors='replace').rstrip('\n'))
    return out


def main():
    if len(sys.argv) < 4:
        print(__doc__.strip().splitlines()[0])
        return 2
    fstype, dev, mnt = sys.argv[1:4]
    try:
        fd = sc(NR_FSOPEN, cstr(fstype), ctypes.c_long(FSOPEN_CLOEXEC))
    except OSError as e:
        print('result: rc=%d err=%s step=fsopen' % (e.errno, errno.errorcode.get(e.errno, '?')))
        return 2
    rc, step = 0, 'source'
    try:
        sc(NR_FSCONFIG, ctypes.c_long(fd), ctypes.c_long(FSCONFIG_SET_STRING),
           cstr('source'), cstr(dev), ctypes.c_long(0))
        step = 'option'
        for o in sys.argv[4:]:
            k, eq, v = o.partition('=')
            if eq:
                sc(NR_FSCONFIG, ctypes.c_long(fd), ctypes.c_long(FSCONFIG_SET_STRING),
                   cstr(k), cstr(v), ctypes.c_long(0))
            else:
                sc(NR_FSCONFIG, ctypes.c_long(fd), ctypes.c_long(FSCONFIG_SET_FLAG),
                   cstr(k), cstr(None), ctypes.c_long(0))
        step = 'create'
        sc(NR_FSCONFIG, ctypes.c_long(fd), ctypes.c_long(FSCONFIG_CMD_CREATE),
           cstr(None), cstr(None), ctypes.c_long(0))
        step = 'fsmount'
        mfd = sc(NR_FSMOUNT, ctypes.c_long(fd), ctypes.c_long(FSMOUNT_CLOEXEC), ctypes.c_long(0))
        step = 'move_mount'
        sc(NR_MOVE_MOUNT, ctypes.c_long(mfd), cstr(''), ctypes.c_long(AT_FDCWD), cstr(mnt),
           ctypes.c_long(MOVE_MOUNT_F_EMPTY_PATH))
    except OSError as e:
        rc = e.errno
    for m in drain(fd):
        print('fc: %s' % m)
    print('result: rc=%d err=%s step=%s' % (rc, errno.errorcode.get(rc, '0') if rc else '0', step))
    return 0 if rc == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
