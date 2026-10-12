---
name: trap-a-background-job-started-in-run-sh-is-waited-on-by-run-coords-bare-wait
description: TRAP: run.sh's run_coord uses a bare `wait`; any `&` job started in run.sh's shell (a sampler) stalls every row for that job's whole lifetime. disown…
metadata:
  type: feedback
---

Adding a per-row host-disk sampler to run.sh (`path_io_sampler.sh ... &` before the row, stop file after) made every fio_perf row stand still for the sampler's entire lifetime before fio started: 180 s with lifetime budget+60, ~11 min with lifetime 3*budget+300. The row's own elapsed still read 36 s, so nothing looked wrong except the wall.

- Cause: run_coord launches the node jobs in the background and collects them with a bare `wait`, which waits for EVERY job in the shell's job table — including any `&` the caller started earlier in the same shell.
- Worse than slow: the sampler always expired just before fio began, so the sample was empty (peak 14 MiB/s while the disk then took 13 GB at 1.0-1.6 GB/s). An instrument that ends before the event reads as "the device was idle".
- Fix: `disown "$!"` right after starting any helper job in run.sh (or any script whose callees use a bare `wait`). A subshell `$(...)` cannot reset globals for the caller either — reset them in the caller.
- How it was found: nodes idle (load 0.08, no fio), run.sh's only children were the sampler and its memory loop; an independent sampler across the whole call (tests/mpath/fio_host_timeline.sh) placed the writes seconds after the in-row sampler expired.

Provenance: 0.90.124, tests/evidence/fio_host_timeline_20261012T025732Z (stalled) and _031003Z (fixed, 82 s).
