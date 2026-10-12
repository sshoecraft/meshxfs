#!/usr/bin/env python3
"""churn_stack_report.py — where a churn run's loop tasks waited, by wait and
by the operation that waited.

Usage: tools/churn_stack_report.py <evidence dir> <host> [<host>...] [--from S] [--to S] [--t T]

Reads <evidence dir>/samples.<host> (tests/pve_churn_fairness.sh: every 0.2 s,
each loop task's state and kernel stack, innermost frame first).  Each sample
is classed by its innermost wait (the first frame that names one: a cluster
lock wait, a lock-state transition wait, a ledger write, a VFS directory lock,
...) and by the outermost filesystem frame (xfs_create, xfs_rename, xfs_lookup,
xfs_file_write_iter, ...), and the pairs are counted, most frequent first.
--from/--to (seconds after T, with --t T) limit the samples to a window.
"""
import collections
import sys

WAITS = (
    ("pending_wait", "cluster lock wait (dlm_lock_impl)"),
    ("mxfs_ilock_wait_for_transition", "inode lock state transition"),
    ("mxfs_tauth_page_write", "ledger page write"),
    ("mxfs_pal_drbd_cas_emulate", "DRBD coordination swap"),
    ("mxfs_tauth_ledger_page_mine", "ledger page mutex"),
    ("xfs_ail_push", "AIL push (sync)"),
    ("folio_wait", "page writeback"),
    ("xlog_", "log force"),
    ("d_alloc_parallel", "VFS parallel lookup"),
    ("path_openat", "VFS directory lock (open)"),
    ("do_renameat2", "VFS directory lock (rename)"),
    ("do_unlinkat", "VFS directory lock (unlink)"),
    ("do_wait", "waiting for a child (fork/exec)"),
)
# the filesystem operation: the innermost of these, else the outermost VFS call
XFS_OPS = ("xfs_create", "xfs_rename", "xfs_remove", "xfs_lookup", "xfs_file_write_iter",
           "xfs_file_open", "xfs_setattr_nonsize", "xfs_setattr_size", "xfs_fs_sync_fs",
           "xfs_vn_getattr")
VFS_OPS = ("do_unlinkat", "do_renameat2", "path_openat", "vfs_statx")


def classify(stack):
    frames = [f for f in stack.split(",") if f]
    wait = next((name for key, name in WAITS for f in frames if f.startswith(key)), frames[0] if frames else "-")
    op = next((f for f in frames if f in XFS_OPS), None) or \
        next((f for f in reversed(frames) if f in VFS_OPS), "-")
    return wait, op


def main():
    args = sys.argv[1:]
    opt = {}
    for k in ("--from", "--to", "--t"):
        if k in args:
            i = args.index(k)
            opt[k] = float(args[i + 1])
            del args[i:i + 2]
    if len(args) < 2:
        print(__doc__)
        return 2
    evid, hosts = args[0], args[1:]
    for h in hosts:
        c = collections.Counter()
        n = 0
        for line in open(f"{evid}/samples.{h}", errors="replace"):
            f = line.rstrip("\n").split(" ", 5)
            if len(f) < 5:
                continue
            if "--t" in opt:
                rel = float(f[0]) - opt["--t"]
                if rel < opt.get("--from", -1e9) or rel > opt.get("--to", 1e9):
                    continue
            n += 1
            wait, op = classify(f[5] if len(f) == 6 else "")
            c[(f[3], f[4], wait, op)] += 1
        print(f"{h}: {n} task samples (comm, state, innermost wait, outermost filesystem frame)")
        for (comm, st, wait, op), m in c.most_common(16):
            print(f"  {m:5d} {100.0 * m / max(n, 1):5.1f}%  {comm:5s} {st}  {wait:40s} {op}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
