---
name: trap-a-per-host-answer-in-per-resource-drbd-fencing-strands-every-resource-but-the-first
description: TRAP (0.90.121): fence-self `status <peer>` answered per host while exclusions are per resource; with 2 DRBD resources the 2nd never recovered.
metadata:
  type: feedback
tags: [drbd, multi-mount, fencing, trap]
---

**What bit:** with two MXFS DRBD resources on one pair (mxfs, mxfs2), the built-in authority `mxfs-drbd-fence-self` excludes a dead peer once PER RESOURCE, each under a fresh episode, but `status <peer>` returned the FIRST inhibit naming that host. The witness for every other resource reported `AUTH_INHIBIT` = another resource's episode vs its own `RECEIPT_EPISODE`; `dlm/drbdfence.c peer_fenced()` refuses on that mismatch, so the module logged `P238-DRBD-FENCE-NOT-YET ... the peer is inhibited under episode X, the receipt names Y` forever: recovery_pending=1, mkdir/ls/pvestatd in D state. The first resource recovered normally, so a single-filesystem check reads green.

**Fix:** `status <target> <resource>` (self authority answers that resource's inhibit); the witness passes its resource when agent=self. Node-fence authorities (ssh/exec, tools/rig_fence_virsh.sh) hold the HOST under one episode and reuse it for a second resource's fence, so their protocol stays per host.

**General lesson:** when adding multi-mount/multi-resource support, audit every query that keys state by HOST (peer name, node) where the producer keys it by RESOURCE (episode files, nft tables, receipts). Test with a host death while BOTH are mounted, not just mount/IO.

**Fast confirmation technique:** on the stuck survivor run `/usr/sbin/mxfs_drbd_witness.py 0123456789abcdef monitor <minor>` per minor and compare RECEIPT_EPISODE with AUTH_INHIBIT; hot-installing the fixed witness/authority unblocked recovery within 15 s (the module re-asks the witness every second).

Related: `scripts/pve_mxfs_spare_disk.sh` only `start`s its unit (not enable) - a reboot test needs `systemctl enable mxfs-drbd@<res>`; `scripts/pve_pair_update.sh` used to stop only RES before rmmod.
