---
name: compiled-harness-node-failure-count-misses-mid-lap-shutdown
description: A lap's node_failures=0 is not evidence; noino_gen0_ab.sh counts a short post-workload kmsg capture, so scan every <node>_dmesg_stream.gz
metadata:
  type: feedback
tags: [compiled, trap, harness, noino_gen0_ab, node-failures, dmesg-stream, audit-stale]
---

Assorted group (`kind: assorted`, one note): the clusterer fitted it to no topic cluster, so it stands alone. It is one trap in how the `tests/noino_gen0_ab.sh` lap harness counts node failures.

## Rule

A lap's `node_failures=0` is not evidence that no node failed. `trap-harness-node-failure-count-reads-a-post-workload-capture-and-misses-a-mid-lap-shutdown`

## Where the count comes from

- `tests/noino_gen0_ab.sh:468` counts `Shutting down filesystem|P-WITHDRAW|P131-SELF-FENCE|BUG:|Oops|blocked for more than` in `$OUT/<node>_kmsg.txt`. `trap-harness-node-failure-count-reads-a-post-workload-capture-and-misses-a-mid-lap-shutdown`
- `<node>_kmsg.txt` is a short capture read after the workload (33 lines in the lap that mattered), not the lap's kernel log. `trap-harness-node-failure-count-reads-a-post-workload-capture-and-misses-a-mid-lap-shutdown`
- The lap's full kernel stream is `<node>_dmesg_stream.gz`; a mid-lap forced shutdown showed only there. `trap-harness-node-failure-count-reads-a-post-workload-capture-and-misses-a-mid-lap-shutdown`

## Incident: lap fxdp2 (2026-10-17, 2/net/mesh/direct)

- test30 forced its own shutdown mid-lap: P-INODE-WEDGE, then withdrawal. `trap-harness-node-failure-count-reads-a-post-workload-capture-and-misses-a-mid-lap-shutdown`
- The full stream `<node>_dmesg_stream.gz` held those lines; the harness reported `node_failures=0`. `trap-harness-node-failure-count-reads-a-post-workload-capture-and-misses-a-mid-lap-shutdown`
- The lap was graded FAIL only because the audit came back STALE: `run.sh` refused with `marker stale ... want ... MOUNTED`. `trap-harness-node-failure-count-reads-a-post-workload-capture-and-misses-a-mid-lap-shutdown`

## Procedure

- Before judging any lap of this harness family, scan every `<node>_dmesg_stream.gz` for the patterns above (`Shutting down filesystem|P-WITHDRAW|P131-SELF-FENCE|BUG:|Oops|blocked for more than`) plus `P-INODE-WEDGE|P-SESSION-POISON`. `trap-harness-node-failure-count-reads-a-post-workload-capture-and-misses-a-mid-lap-shutdown`
- When the harness is next edited, make it count from the stream, not from `<node>_kmsg.txt`. `trap-harness-node-failure-count-reads-a-post-workload-capture-and-misses-a-mid-lap-shutdown`
- An audit=STALE with a "marker stale ... MOUNTED" refusal means a node lost its mount: read that node's stream before rerunning the lap. `trap-harness-node-failure-count-reads-a-post-workload-capture-and-misses-a-mid-lap-shutdown`
