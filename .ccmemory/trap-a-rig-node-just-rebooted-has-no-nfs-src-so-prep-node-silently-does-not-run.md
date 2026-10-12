---
name: trap-a-rig-node-just-rebooted-has-no-nfs-src-so-prep-node-silently-does-not-run
description: TRAP: a rig VM restarted by a harness has no /src NFS mount; `bash /src/mxfs/tests/setup/prep_node.sh` fails before printing NODE_PREP_*.
metadata:
  type: feedback
---

prep_node.sh mounts /src itself (step 1), but it is READ from /src, so on a node that just booted the script never starts: bash prints "No such file or directory" on stderr, and a caller that greps for NODE_PREP_(OK|FAIL) sees nothing at all. Every later step (mount, read-back) then fails with MOUNT_RC=32 because the module was never loaded, which reads like a filesystem refusal.

Seen in the tests/multi_mount.sh crash arm (0.90.120): the survivor recovered both filesystems in 68 s, the victim booted, and the reload printed an empty line.

Fix in the caller, before running anything from /src on a node it restarted:
`mkdir -p /src; mountpoint -q /src || mount -t nfs -o rw,vers=4.1,hard,timeo=600,retrans=2,tcp 192.168.120.1:/src /src`.
An empty capture from a node step is a capture failure, never a verdict about the filesystem.
