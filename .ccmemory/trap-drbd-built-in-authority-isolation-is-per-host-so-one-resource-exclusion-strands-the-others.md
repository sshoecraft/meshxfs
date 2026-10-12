---
name: trap-drbd-built-in-authority-isolation-is-per-host-so-one-resource-exclusion-strands-the-others
description: TRAP: fence-self's per-resource nft table drops ALL MXFS ports to the peer; one resource's link loss cuts every other filesystem's lock traffic.
metadata:
  type: feedback
tags: [trap, drbd, fencing, multi-mount, harness]
---

**What bit us (0.90.122, drbd_rig multi-death-test, 6 resources on test1/test2):** one resource (mxfs5) missed a DRBD PingAck while the other five stayed Connected. The winner's `mxfs_fence_mxfs5` nft table drops that resource's DRBD port AND 7600/tcp + 7601-7603/udp to the peer. Since 0.90.120 those ports are shared by every MXFS filesystem on the host, so every other filesystem lost its lock traffic while its DRBD stayed Connected/Primary/Primary with no exclusion any witness could prove: the winner's next mount retried the root lock for 19 s "during cluster membership changes" and shut down; the loser's mount of the frozen resource sat in D state at drbd_submit_bio. Queue: D-DRBD-ONE-RESOURCE-EXCLUSION-CUTS-EVERY-RESOURCES-MXFS-TRAFFIC.

**Why it matters for any multi-resource reasoning:** "per-resource exclusion" and "per-host isolation" coexist in the built-in authority. Any change or test that reasons about one resource's fence must ask what the host-wide port cut does to the resources that were NOT fenced. A real host death hides this (every link drops at once); only a single-resource link loss shows it.

**Harness trap found alongside it:** a per-step check that greps the evidence file's LAST line (`tail -1`) passes a step whose ssh returned nothing — the previous step's `MOUNT_RC=0` line is still last. Judge each step on its own captured output and write `NO_RESULT` when it is empty.
