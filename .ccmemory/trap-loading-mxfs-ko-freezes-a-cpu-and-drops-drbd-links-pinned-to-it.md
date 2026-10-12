---
name: trap-loading-mxfs-ko-freezes-a-cpu-and-drops-drbd-links-pinned-to-it
description: TRAP: insmod of mxfs.ko holds its CPU ~0.9 s (kernel code patching); DRBD threads pinned there miss PingAck. Load before DRBD connects.
metadata:
  type: feedback
tags: [trap, drbd, module-load, instrument, rig]
---

**What bit us (0.90.122):** on the 2-vCPU rig guests, loading mxfs.ko holds the CPU it runs on for ~0.9 s inside the kernel's load_module (code patching of ~48k call sites etc.), before MXFS's own init (6 ms). Stripping debug info (88 MB -> 11 MB) changes nothing; stock xfs.ko holds ~0.27 s. DRBD 8.4 pins each resource's threads to one CPU (check `Cpus_allowed_list` of drbd_r_/drbd_w_ threads) and drops a link whose PingAck is 0.5 s late, so a load with DRBD links up drops every link pinned to that CPU — on six resources, exactly alternate sets {mxfs,mxfs3,mxfs5} / {mxfs2,mxfs4,mxfs6}. Under the built-in authority that fences a host.

**Rule of thumb:** on a DRBD node, load the module BEFORE any DRBD link comes up (packages: modules-load.d at boot; rig: drbd_rig.sh load_mxfs_node, prep_node MXFS_KEEP_LOADED=1; boot program: modprobe before drbdadm up).

**Instrument trap:** an UNPINNED ping during the load reads clean (it migrates to the free CPU). Pin a ping per CPU with `taskset -c N ping -D -i 0.05` to see a per-CPU freeze. Also: two VMs' clocks disagree by seconds after a boot — stamp steps and pings on the same node's clock. tests/vm_stall_probe.sh does the node-local version and counts DRBD losses (it refuses with no link Connected, which once made a "no loss" vacuous).

**Unexplained residual:** loads without dyndbg=+p stalled as long but dropped no link in 20 loads; with dyndbg=+p 3 of 3 runs dropped. Ordering fixes both.
