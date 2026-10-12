---
name: trap-a-node-clock-offset-or-step-reads-as-a-filesystem-stall-in-path-rows
description: TRAP: path rows graded node-clock ops.log against host-clock windows; a 74 s skew and a 366 s mid-row step made fake 72 s/383 s stalls.
metadata:
  type: feedback
---

Before calling a path-row stall or hang an MXFS fault, check the node's clock.

Two-load test (needs no extra capture): a row starts and stops every node's load together, so each pair of `load_<node>/ops.log` files must span the same duration and start/end within ~1 s of each other. A constant offset at both ends is a skewed node clock; a start offset that differs from the end offset is a clock STEP during the row.

Seen in the 2026-10-05 evidence:
- run 20261005T154539Z-g2: test2's clock was 74.0 s behind (start and end offsets 74023/74057 ms). Four rows FAILED on "72 s stalls", yet every op finished in under 17 s. This disposed of D-2NODE-MPATH-VICTIM-LOAD-BLOCKED-OUTSIDE-ITS-OPS as DISPROVED.
- run 20261005T204723Z-g2: test1's log began 366.5 s before test2's, but the two ended 48 ms apart, so the clock was stepped mid-row. One "383 s" mutex op was really 16.7 s once the step is taken out.

Also: pathload writes each op line only after the op returns. The gap between one op's end and the next op's start is time spent outside MXFS (log flush, stop-file stat). In the 154539Z run that gap never exceeded 55 ms.

Harness fix (0.90.122): tests/lib/rig.sh `clock_measure`, `clock_off` and `clock_steady`. pf_window and the related helpers translate host windows into each node's clock, and a node whose clock moves by more than 2 s mid-row ends the row as ABORT.

Related: an unmount that returns rc=32 within ms is EBUSY. Look for a stray pathload from a chain that was stopped from outside: its run.out has no PATHLOAD line and its ops.log keeps advancing.
