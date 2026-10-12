---
name: compiled-drbd-rig-module-load-and-fence-isolation-traps
description: Assorted DRBD rig traps (0.90.122): mxfs.ko load freezes a CPU and drops pinned DRBD links; fence-self port cut is host-wide, not per-resource.
metadata:
  type: feedback
tags: [compiled, drbd, trap, fencing, module-load, rig]
---

Assorted group (the clusterer could not fit these to a narrower topic): two DRBD-on-rig traps, both found at 0.90.122. Common thread: DRBD link loss on a single resource or CPU is far more destructive under MXFS's built-in authority than it looks, and the instruments used to observe it can read clean.

## Module load freezes a CPU and drops DRBD links
Source: `trap-loading-mxfs-ko-freezes-a-cpu-and-drops-drbd-links-pinned-to-it`

- On the 2-vCPU rig guests, loading mxfs.ko holds the CPU it runs on ~0.9 s inside the kernel's load_module (code patching of ~48k call sites), before MXFS init (6 ms). Stripping debug info (88 MB -> 11 MB) changes nothing; stock xfs.ko holds ~0.27 s.
- DRBD 8.4 pins each resource's threads to one CPU (`Cpus_allowed_list` of drbd_r_/drbd_w_) and drops a link whose PingAck is 0.5 s late. A load with links up drops every link pinned to that CPU: on six resources, alternate sets {mxfs,mxfs3,mxfs5} / {mxfs2,mxfs4,mxfs6}. Under the built-in authority that fences a host.
- Rule: load the module BEFORE any DRBD link comes up. Packages: modules-load.d at boot. Rig: drbd_rig.sh load_mxfs_node, prep_node MXFS_KEEP_LOADED=1. Boot program: modprobe before drbdadm up.
- Instrument trap: an unpinned ping during the load reads clean (migrates to the free CPU). Pin one per CPU: `taskset -c N ping -D -i 0.05`. VM clocks differ by seconds after boot; stamp steps and pings on the same node's clock. tests/vm_stall_probe.sh does the node-local version and counts DRBD losses; it refuses with no link Connected (a "no loss" result there was once vacuous).
- Unexplained residual: loads without dyndbg=+p stalled as long but dropped no link in 20 loads; with dyndbg=+p 3 of 3 dropped. Load ordering fixes both.

## Built-in authority isolation is per host, exclusion is per resource
Source: `trap-drbd-built-in-authority-isolation-is-per-host-so-one-resource-exclusion-strands-the-others`

- drbd_rig multi-death-test, 6 resources on test1/test2: one resource (mxfs5) missed a PingAck, the other five stayed Connected. The winner's `mxfs_fence_mxfs5` nft table drops that resource's DRBD port AND 7600/tcp + 7601-7603/udp to the peer. Since 0.90.120 those ports are shared by all MXFS filesystems on the host, so every other filesystem lost lock traffic while its DRBD stayed Connected/Primary/Primary with no provable exclusion. Winner's next mount retried the root lock 19 s and shut down; loser's mount of the frozen resource sat in D state at drbd_submit_bio. Queue: D-DRBD-ONE-RESOURCE-EXCLUSION-CUTS-EVERY-RESOURCES-MXFS-TRAFFIC.
- Any change or test reasoning about one resource's fence must ask what the host-wide port cut does to unfenced resources. A real host death hides this (all links drop together); only a single-resource link loss exposes it.
- Link to the first trap: a CPU-pinned link drop from module load is exactly the single-resource-loss trigger.

## Harness trap
- A per-step check grepping the evidence file's last line (`tail -1`) passes a step whose ssh returned nothing, since the previous step's `MOUNT_RC=0` is still last. Judge each step on its own captured output and write `NO_RESULT` when empty.
