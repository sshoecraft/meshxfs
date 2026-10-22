---
name: compiled-drbd9-support-waits-for-mainline-kernel
description: Owner decision: DRBD 9 support waits for mainline kernel; DRBD 8.4 supported until then; check /src/linux drbd_config.h REL_VERSION.
metadata:
  type: feedback
tags: [compiled, drbd, platform-support, owner-decision, proxmox]
---

Compiled from a single note (kind assorted group of one): DRBD 9 support policy. Source: `drbd9-support-waits-for-mainline-kernel`.

Owner decision, 2026-10-21. A Proxmox forum tester's mount on DRBD 9 (LINBIT's drbd-dkms) was refused with `P-DRBD-ARM-REFUSED ... replication protocol is '' (configured 'C')`. Owner: "we're not staying on drbd 8.4 forever" / "we'll support it when it reaches rhe mainline kernel". `drbd9-support-waits-for-mainline-kernel`

**Why:** DRBD 9 is LINBIT's out-of-tree driver, shipped as `drbd-dkms` from LINBIT's own repositories, and its DKMS builds often lag new Proxmox kernels. The mainline kernel still carries DRBD 8.4.11: `/src/linux/drivers/block/drbd/drbd_config.h:12` `REL_VERSION "8.4.11"` at Linux 7.3.0. LINBIT is working to get DRBD 9 into mainline: it was aimed at around 7.2 but had not landed by 7.3, and a new patch series went out in late September 2026. Once it lands, every kernel built from it (Proxmox's included) ships DRBD 9 by default. MeshXFS then refuses every DRBD mount on those kernels, because the witness (`/usr/sbin/mxfs_drbd_witness.py`, `pal/linux/drbd.c:10-14`) reads each device's live state from `/proc/drbd`, which DRBD 9 no longer reports there, and `dlm/drbdfence.c:33-35` refuses a live protocol of `''` (also stated in `docs/quarantine-repair.md:156`). That outage ends 2/net/mesh/drbd on those kernels, so the work has to be done before Proxmox moves to such a kernel. `drbd9-support-waits-for-mainline-kernel`

**How to apply:** `drbd9-support-waits-for-mainline-kernel`
- Do not propose or start DRBD 9 support work before DRBD 9 is in the mainline kernel.
- When answering testers or issues: MeshXFS supports DRBD 8.4 (the driver built into the Proxmox kernel, `drbd-utils` without `drbd-dkms`) at this time. State what is supported; do not promise dates.
- Whenever `/src/linux` is updated, check `drivers/block/drbd/drbd_config.h` `REL_VERSION`. When it reads 9.x, tell the owner: DRBD 9 support is now needed, ahead of the first Proxmox kernel built on that release.
- The work, when it starts: read state from DRBD 9's own interface instead of `/proc/drbd`, handle DRBD 9's auto-promote/auto-demote (it promotes on open, which bypasses `mxfs-drbd@`'s promotion control), its resource syntax (`connection-mesh`, `node-id`, `fencing` in `net {}`) and its quorum/multi-node model, then verify it as its own configuration.
