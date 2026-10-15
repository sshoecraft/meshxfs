---
name: compiled-pve-rig-traps-san-disk-up-template-loss-and-backgrounded-ssh-arm-chains
description: Proxmox rig traps: pve_mxfs_san_disk.sh up destroys template VM 9000's disk; a && b & over ssh holds the arm open and skews two-host start.
metadata:
  type: feedback
tags: [compiled, pve, rig, ssh, harness, traps]
---

Assorted group (loose): two Proxmox-rig harness traps, both seen 2026-10-14 on pve9-5/6/7.

## `pve_mxfs_san_disk.sh up` reformats the LUN and destroys the clone template
Source: `trap-pve-san-disk-up-reformats-lun-and-destroys-the-template-guest-the-vm-tests-clone`

- `scripts/pve_mxfs_san_disk.sh up` wipes and re-runs `mkfs.mxfs` on the SAN LUN (pve9-5/6/7, /mnt/mxfssan). The cloud-image source guest VM 9000 (`scripts/pve_cloud_guest.sh`) keeps its config on the hosts, but its disk `mxfssan:9000/vm-9000-disk-0.raw` lived on that LUN, so after any `up` the template is a config with no disk.
- Observed: a session ran `up` for a reproducer (~04:30Z 2026-10-14); the next full Proxmox suite failed `tests/pve_live_migrate.sh` at its first step, 2 s in: `clone failed: volume 'mxfssan:9000/vm-9000-disk-0.raw' does not exist`. It reads like a lost file on MXFS; it is not. `ls /mnt/mxfssan/images` shows an empty directory dated at the reformat.
- Rule: use `join` (never formats) to re-mount. After any `up`, rebuild the template with `PVE_HOSTS="..." scripts/pve_cloud_guest.sh` (destroy the stale 9000 config first) before the live-migrate / HA rows.

## `a && b && nohup x &` over ssh backgrounds the whole chain and skews two-host start
Source: `trap-backgrounded-and-list-holds-ssh-arm-open-and-skews-two-host-start`

- Trap: in a remote arm command like
  `on host "decode > f && decode > g && for ...; do nohup setsid loop & done && nohup setsid sampler >/dev/null 2>&1 </dev/null & echo ARMED" 30`
  the trailing `&` applies to the WHOLE `&&` chain. The chain runs in a background subshell that inherits ssh's stdout, and the last command (the sampler) runs in that subshell's FOREGROUND, so the subshell (and ssh's channel) lives as long as the sampler. `ARMED` still prints, so `grep -q ARMED` succeeds, but the `on` call returns only when its `timeout 30` kills it.
- Effect: tests/pve_churn_fairness.sh arms p0 then p1 with ARM_S=20, so p0's arm returned at T+10 and p1's loops began ~T+11 (measured +10.88 s, pve9-5/6). p0 ran solo for 11 s (one 3.6 s tenure of 1244 creates) and the harness reported "participant 1 starved" at 0.40-0.46 for weeks; the D-DRBD-PAIR-SHARED-DIR-CHURN-STARVES-PARTICIPANT-1 record was built on it. Fixed arming: 0.98.
- Fix: background each launch on its own inside braces: `a && b && { for ...; do nohup ... & done; nohup ... & } && echo ARMED`. The same shape was in tests/pve_tree_walk.sh and tests/pve_pair_concurrency.sh.
- Detect: have every timed loop write its actual start time (`echo START $EPOCHREALTIME`) and log each host's arm completion relative to T. A two-host comparison whose starts differ by >1 s measured the start, not the sharing. A per-host sum of op latencies short of the window (29 s of 40) is the same tell from old evidence.
