---
name: trap-kmsg-fromnode-holds-ring-since-boot-count-after-pf-mark
description: kmsg_*_fromnode.gz in board dirs dumps the node's ring since boot: count probes only after the run's PF-MARK, or earlier rows' lines count twice
metadata:
  type: feedback
---

The path rows' kernel-log follower (tests/lib/rig.sh ~292-305) starts by dumping the node's whole dmesg ring, so `kmsg_<node>_fromnode.gz` in a `board_*` dir holds every line since boot, including earlier rows on the same boot.

Bitten 2026-10-24 (session 8815bf68): a fix-off path_mount_degraded run "showed" 10 `why=shell-dead` relookups that need the fix on; they were byte-identical to the previous fix-on run's lines, from before this run's PF-MARK.

How to apply: `zcat f.gz | sed -n '/PF-MARK/,$p'` before counting any probe per run. Plain `grep -r` also skips the .gz files entirely — use zgrep/zcat.
