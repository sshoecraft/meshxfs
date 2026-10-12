---
name: compiled-multi-resource-drbd-fencing-and-multi-mount-harness-traps
description: Assorted traps from the multi-mount DRBD work (0.90.120/121): per-host fence answers, missing /src after reboot, bare wait on a tee.
metadata:
  type: feedback
tags: [compiled, drbd, fencing, multi-mount, harness]
---

Assorted group (not a single topic): three traps that all surfaced while bringing up multi-mount / two-resource DRBD (mxfs, mxfs2) and its `tests/multi_mount.sh` crash arm. Common thread: the symptom looks like a filesystem hang or refusal, and the cause is elsewhere (keying, missing mount, local shell).

**1. Per-host answer to a per-resource question (0.90.121)** — [[trap-a-per-host-answer-in-per-resource-drbd-fencing-strands-every-resource-but-the-first]]
- `mxfs-drbd-fence-self` excludes a dead peer once per resource, each under a fresh episode. `status <peer>` returned the first inhibit naming that host, so every other resource's witness saw AUTH_INHIBIT (another resource's episode) != its own RECEIPT_EPISODE. `dlm/drbdfence.c peer_fenced()` refuses on mismatch: `P238-DRBD-FENCE-NOT-YET` forever, recovery_pending=1, mkdir/ls/pvestatd in D state. The first resource recovers, so a one-filesystem check reads green.
- Fix: `status <target> <resource>`; the witness passes its resource when agent=self. Node-fence authorities (ssh/exec, tools/rig_fence_virsh.sh) hold the HOST under one episode and reuse it for the second resource, so they stay per host.
- Lesson: when adding multi-resource support, audit every query keyed by HOST where the producer keys by RESOURCE (episode files, nft tables, receipts). Test host death with BOTH mounted, not just mount/IO.
- Confirm: on the stuck survivor run `/usr/sbin/mxfs_drbd_witness.py 0123456789abcdef monitor <minor>` per minor, compare RECEIPT_EPISODE vs AUTH_INHIBIT. Hot-installing the fixed witness/authority unblocked recovery in 15 s.
- Side notes: `scripts/pve_mxfs_spare_disk.sh` only starts its unit (reboot tests need `systemctl enable mxfs-drbd@<res>`); `scripts/pve_pair_update.sh` used to stop only RES before rmmod.

**2. Rebooted rig node has no /src** — [[trap-a-rig-node-just-rebooted-has-no-nfs-src-so-prep-node-silently-does-not-run]]
- `prep_node.sh` mounts /src itself but is read from /src; on a freshly booted node bash fails with ENOENT on stderr and a caller grepping NODE_PREP_(OK|FAIL) sees nothing. Later steps fail MOUNT_RC=32 because the module never loaded, which looks like a filesystem refusal.
- Fix in the caller before running anything from /src on a restarted node: `mkdir -p /src; mountpoint -q /src || mount -t nfs -o rw,vers=4.1,hard,timeo=600,retrans=2,tcp 192.168.120.1:/src /src`.
- An empty capture from a node step is a capture failure, never a filesystem verdict.

**3. Bare `wait` after `exec > >(tee log)`** — [[trap-bare-wait-in-a-harness-that-tees-its-own-log-waits-on-the-tee-for-ever]]
- Bash 5.1+ counts the process substitution as a child; argument-less `wait` waits on the tee, which never exits. Writers finished in 0.6 s, the run sat for an hour and looked like an FS hang.
- Fix: `pids+=($!)` per job and `wait "${pids[@]}"`. Before diagnosing a harness "hang", check whether the remote work finished (files present, no D-state task); if so the hang is local.
