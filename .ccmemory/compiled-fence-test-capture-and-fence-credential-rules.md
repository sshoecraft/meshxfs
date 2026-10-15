---
name: compiled-fence-test-capture-and-fence-credential-rules
description: Assorted fencing lessons: use netconsole not ssh kmsg for pre-reset lines; no fence design may store hypervisor credentials on cluster nodes.
metadata:
  type: feedback
tags: [compiled, fencing, netconsole, vcenter, credentials]
---

Assorted group (loose): two fencing lessons, one about test evidence capture, one about fence design.

## Capture: ssh kmsg stream loses the line before emergency_restart()

`trap-ssh-kmsg-stream-loses-the-line-before-an-emergency-restart-use-clydes-netconsole`

- Observed in the fence=quorum split tests (vstest2): the module prints `P-QUORUM-LOST-RESET` and calls `emergency_restart()` in the same breath. One run's `tools/node_kmsg_stream.sh` capture (ssh `cat /dev/kmsg`) had the line, the next run's did not: the remote `cat` and sshd never get scheduled before the reset. A check reading only the stream reported FAIL on a reset that happened.
- How to apply: for any line a node prints right before resetting itself (self-fence, panic, quorum loss), load netconsole on the node (`modprobe netconsole netconsole=@/eth0,6666@192.168.120.1/`) — it transmits from inside printk.
- clyde already runs a listener (`tools/netconsole_listen.sh status`: socat on 6666, log `tests/evidence/netconsole.log`). It is the rig's: do not start/stop it from a test; record the log's byte size before and read only what is appended (`tail -c +N`). `tests/vsphere_shared_fence.sh` `split` does exactly this.

## Design: no fence may put hypervisor credentials on cluster nodes

`feedback-no-fence-design-may-store-hypervisor-credentials-on-cluster-nodes`

- User rejected fence=vcenter outright. The 0.90.128 `fence=vcenter` design (docs/shared-disk-attachment.md, "Method: vcenter"; tools/mxfs_fence_vcenter.py) keeps `/etc/mxfs/vcenter.conf` + a 0600 `password_file=` on EVERY node, for an account that can power VMs off. User, 2026-10-13: "a clear text password to the entire vSphere environment with administrative access. You're insane." Scoping the vCenter role does not answer it; mode 0600 does not answer it.
- Why: any one compromised or misconfigured guest then holds the power to power off arbitrary VMs in the customer's vSphere. No storage admin will deploy a filesystem that requires that, and a session marked "working on vSphere" done on top of it.
- How to apply: a fence for a hypervisor-attached shared disk must not depend on credentials living inside the guests. Credential-free mechanisms to evaluate first: storage-side fencing reachable from the guest (in-guest iSCSI + SCSI PR), operator confirmation (`fence=manual`), guest self-fencing with the VMware virtual watchdog (vWDT, HW version 17+, `wdat_wdt`) plus a disk-based lease, SBD-style. Raise any design that needs a management-plane credential with the user BEFORE building it.
