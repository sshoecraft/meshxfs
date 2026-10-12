---
name: trap-a-two-inode-deadlock-repro-needs-the-hangs-inode-number-order
description: TRAP: rmdir/rename lock two inodes in inode-NUMBER order; a parent at ino 131 makes every child lock second, so an ABBA repro can never form.
metadata:
  type: feedback
---

A directed reproducer for a parent/child lock-order deadlock (D-DIR-RELOAD-CHILD-INACTIVATION-DEADLOCK: test12's rmdir held child LOCK 33569536 and waited for parent `shared` 92813250) ran clean on BOTH the fix and an inline-shrink control build until the geometry was matched.

- xfs_lock_two_inodes takes the lower inode number first. The hang needed the child BELOW the parent, so rmdir held the child while waiting for the parent. A test parent made fresh at the top of the mount sat at ino 131 (bottom of AG 0): every LOCK was above it, rmdir always locked the parent first, and the deadlock order was impossible.
- MXFS places a node's new directories in that node's AG, and which AG moves between mounts: eight candidates from one node all landed at 131-138; one candidate per node spread across AGs. Pick the highest-numbered as the parent, then CALIBRATE (each locker makes one LOCK and reports its ino) and retry the setup until at least one locker is below — tests/dir_reload_child_inact.sh does this.
- Do not put a per-iteration `stat` in a lock loop to log inode numbers: it cut cycles from ~700 to ~7 per minute and the window was never reached. Calibrate once before the window instead.
- A control build (the old code path restored, everything else identical) is what tells you whether the test discriminates. Here it showed the inline shrink cutting lock cycles ~50x (7-15 vs ~700 per minute, 7-10 s ops vs <1 s) even without reaching the full 480 s deadlock.

Provenance: 0.90.124 verification, tests/evidence/*_drci_ctlshrink{,2,3,4} and *_drci_v124{a,b,c,d}.
