---
name: compiled-bare-wait-version-granularity-and-lock-order-repro-traps
description: Assorted: run.sh bare-wait stalls on helper jobs, one version bump per piece of work, and inode-number order in two-inode deadlock repros.
metadata:
  type: feedback
tags: [compiled, run-sh, versioning, deadlock-repro, mpath]
---

Assorted group (kind: assorted, no single topic): three lessons from the 0.90.12x mpath release work. Two are test-harness traps where the instrument or repro silently fails to exercise the event; one is a user correction on version granularity.

## Version granularity (user correction)

[[feedback-one-version-per-piece-of-work-not-per-defect-found]]: the mpath run went 0.90.122 -> 0.90.123 (16-node dir-reload hang) -> 0.90.124 (rejoined node cannot open files). The user's correction: bump once per thing being worked on, "even if you use 300 sessions, that's one version."
- Unit of a version = the piece of work (the ccloop task, e.g. "test and release mpath support"), not each defect found. A new defect joins the open version's CHANGELOG entry as another paragraph.
- "A change that needs an entry of its own" means different work, not a different bug inside the same work.
- Do not renumber backwards to undo an extra bump (stay on 124, just do not increase again); renumbering forces a rebuild and re-gate of a verified build.
- Stopping a running gate chain to renumber was itself wrong; the user interrupted it.

## run.sh bare `wait` traps every `&` job in the shell

[[trap-a-background-job-started-in-run-sh-is-waited-on-by-run-coords-bare-wait]]: a per-row host-disk sampler started with `&` in run.sh made every fio_perf row stall for the sampler's whole lifetime (180 s at budget+60, ~11 min at 3*budget+300) before fio started. Row-elapsed still read 36 s, so only the wall looked wrong.
- Cause: run_coord launches node jobs in the background and collects them with a bare `wait`, which waits on EVERY job in the shell's table, including earlier caller-started helpers.
- The sampler expired just before fio began, so the sample was empty (peak 14 MiB/s while the disk took 13 GB at 1.0-1.6 GB/s). An instrument that ends before the event reads as "the device was idle."
- Fix: `disown "$!"` immediately after starting any helper in run.sh (or any script whose callees use a bare `wait`). A `$(...)` subshell cannot reset globals for the caller; reset them in the caller.
- Found by: nodes idle (load 0.08, no fio), run.sh's only children were the sampler and its memory loop; an independent whole-call sampler (tests/mpath/fio_host_timeline.sh) placed the writes seconds after the in-row sampler expired.
- Provenance: 0.90.124, tests/evidence/fio_host_timeline_20261012T025732Z (stalled) and _031003Z (fixed, 82 s).

## Two-inode lock-order deadlock repros need the hang's inode-number order

[[trap-a-two-inode-deadlock-repro-needs-the-hangs-inode-number-order]]: a directed reproducer for D-DIR-RELOAD-CHILD-INACTIVATION-DEADLOCK (rmdir held child LOCK 33569536, waited on parent `shared` 92813250) ran clean on BOTH the fix and an inline-shrink control until the geometry matched.
- xfs_lock_two_inodes locks the lower inode number first. The hang needs the child BELOW the parent. A fresh parent at the top of the mount sat at ino 131 (bottom of AG 0), so every LOCK was above it and the ABBA order could never form.
- MXFS places a node's new directories in that node's AG, and the AG moves between mounts: eight candidates from one node landed at 131-138; one candidate per node spread across AGs. Choose the highest-numbered as parent, then CALIBRATE (each locker makes one LOCK and reports its ino) and retry setup until at least one locker is below; tests/dir_reload_child_inact.sh does this.
- No per-iteration `stat` in the lock loop: it cut cycles from ~700 to ~7 per minute and the window was never reached. Calibrate once before the window.
- Run a control build (old code path restored, all else identical) to prove the test discriminates. Here it showed the inline shrink cutting lock cycles ~50x (7-15 vs ~700 per minute, 7-10 s ops vs <1 s) even without reaching the full 480 s deadlock.
- Provenance: 0.90.124 verification, tests/evidence/*_drci_ctlshrink{,2,3,4} and *_drci_v124{a,b,c,d}.

## Common thread

A clean result is not evidence until the instrument is shown to overlap the event: the sampler that expired before fio, and the repro whose inode geometry made the deadlock order impossible, both reported "nothing wrong." Verify with an independent observer or a control build before trusting a negative.
