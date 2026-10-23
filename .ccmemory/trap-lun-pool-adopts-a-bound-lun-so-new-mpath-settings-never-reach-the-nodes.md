---
name: trap-lun-pool-adopts-a-bound-lun-so-new-mpath-settings-never-reach-the-nodes
description: lun_pool.sh alloc adopts a finished binding without logging in again, so a changed tools/mpath_settings.sh or its env never reaches the nodes
metadata:
  type: feedback
tags: [lun-pool, multipath, mpath-settings, rig, variant, trap]
---

tools/lun_pool.sh cmd_alloc (about :580-598) adopts a finished run's LUN when the node set, path count, block size, initiator group and wwid file match, and returns its pool line WITHOUT running NODE_LOGIN_MP. The multipath and iSCSI initiator settings (`tools/mpath_settings.sh multipath|iscsi`, written into /etc/multipath/conf.d/mxfs.conf and each node record) are applied only by that login, i.e. only when a LUN is first bound to a node set. `MXFS_FORCE_PREP=1 ./run.sh ... prep_cluster` re-forms the cluster on the adopted binding; it does not log in again.

Consequences:
- A variant of the path settings (a different timescale, a different no_path_retry) measured on a group whose LUN was already bound measures the OLD settings. Release the group's binding first, or make adoption compare the settings the LUN was bound with.
- After a change to the default settings, every adopted binding keeps the old ones, and a later non-variant run on it grades the candidate on settings that do not ship.
- Verify what a node actually runs on the node: `multipathd show config | grep -E 'polling_interval|fast_io_fail_tmo|no_path_retry'` and `iscsiadm -m node -T <tgt> -p <portal> | grep -E 'replacement_timeout|noop_out'`, not the tree's file.

Found 2026-10-23 while planning the 2 s path-timescale measurement for D-SILENT-PEER-DEATH-TAKES-35S-TO-DETECT-SO-SURVIVORS-STALL-OVER-30S (session 02386252).
