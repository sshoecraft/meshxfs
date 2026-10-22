---
name: trap-make-tools-does-not-rebuild-the-single-file-sg-io-helpers
description: make tools builds only mkfs/chk/resize/admin/fua_verify; caw_verify, caw_slotdump, recov_forge etc. stay stale until rebuilt by hand or platform_build
metadata:
  type: feedback
---

`tools/Makefile` TOOLS is `mkfs_mxfs chk_mxfs resize_mxfs mxfs_admin fua_verify`. The single-file SG_IO and forge helpers — `tools/caw_verify`, `tools/caw_slotdump`, `tools/recov_forge`, `tools/mxfs_mmapio`, `tests/caw/caw_align_probe`, `tests/fence_inflight/prprobe` — are built only by `scripts/platform_build.sh` (`gcc -O2 -Wall -I include -o "$h" "$h.c"`), never by `make tools` or `make modules`.

Found 2026-10-22 (0.90.134, 4K-native work): `caw_verify.c`, `caw_slotdump.c` and `recov_forge.c` were changed on 2026-10-21 to take LBAs in the device's own logical blocks, but the binaries in the tree dated from 2026-10-14 and still took 512-byte LBAs (`caw_verify` printed `<lba_512>` in its usage). The nodes run the tree's binaries over NFS, so a board row on a 4096-byte LUN handing `caw_verify` a device-block LBA would have written 8x too far in: into the journal or the mounted volume.

Apply:
- After editing any of those six `.c` files, rebuild them with platform_build.sh's command, or compare each binary's mtime with its source before a rig run (`stat -c %Y`).
- Before freezing a release candidate, check all six are newer than their sources: the candidate freezes the binaries as files, and its build step re-verifies only the five TOOLS.
- When a tool's behaviour seems not to match its source, run its usage text first: a stale binary shows the old text.
