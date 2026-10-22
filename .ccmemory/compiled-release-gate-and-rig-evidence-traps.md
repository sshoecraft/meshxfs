---
name: compiled-release-gate-and-rig-evidence-traps
description: Assorted release-gate/rig traps: verify batches need a frozen candidate; make tools skips 6 SG_IO helpers; LUNs/yardsticks stay on SATA 870
metadata:
  type: feedback
tags: [compiled, release-gate, verification, release-candidate, stale-binary, sg-io, yardstick, sata-870, 4k-native, rig]
---

Assorted group: the three notes share no subsystem. What they have in common is that each is a way release-gate or rig evidence looks valid while being bound to the wrong build, binary or disk: a verify batch with no candidate, a tool binary older than its source, a yardstick captured on a different disk.

## Verification batches count only on a frozen candidate

`trap-verification-batches-count-only-on-a-frozen-candidate-controls-may-run-before` - the release-reviewer rejected proposal P20261022-c75127 (verify of D-PACKAGE-INPUT-LIST-NAMES-ABSENT-MXFS-C-NO-PACKAGE-CAN-BE-BUILT, batch b20261022-1666e5, 4 of 4 exposed PASS laps). The batch was declared with `plan-verify --build <srcversion>` and no `--candidate`, and its laps carried no `MXFS_CANDIDATE`. Review: `data/reviews/P20261022-c75127.md`.

Why it is wrong:
- A verification batch stops a record blocking a configuration *on a candidate* (`docs/release-process.md`, "What a verification clears"). With no candidate it counts for none, and in the development view it would count on any tree with that module, including one with the fix reverted.
- The module srcversion names only the kernel module. A fix in a script or tool (here `scripts/vm_package_build.sh`) leaves it unchanged, so the control (fix out) and the verify (fix in) ran on the same "build".

The reviewer judged the control batch itself sound: k=20 of 20 with the fix reverted by a hashed diff, on the dev tree, no candidate. So:
- Write every fix and run its control batch on the development tree.
- Freeze the candidate (`tools/release_candidate.py create`) only when every fix is in: any later change makes it INVALID.
- Declare each verification batch with `plan-verify --control <batch> --candidate <version>`; run its laps with `MXFS_CANDIDATE` set, after the freeze. The `batches` step of `tools/release_run.py` runs the open verification batches declared for the candidate.
- A verify clears one configuration only. A record that reaches `*/*/*` keeps blocking every other configuration until it is removed (`remove --fixed` needs that passed verify batch).

The same review also noted:
- A lap bound that is the sum of a script's per-step timeouts is not derived from what the lap takes.
- A record's `--reproducer` must name a command that exists: `run.sh` has no `lap:` rows; such laps run through `tools/harness_batch.py` / `tools/batch_lap.py`.

## `make tools` does not rebuild the single-file SG_IO helpers

`trap-make-tools-does-not-rebuild-the-single-file-sg-io-helpers` - `tools/Makefile` TOOLS is `mkfs_mxfs chk_mxfs resize_mxfs mxfs_admin fua_verify`. The single-file SG_IO and forge helpers - `tools/caw_verify`, `tools/caw_slotdump`, `tools/recov_forge`, `tools/mxfs_mmapio`, `tests/caw/caw_align_probe`, `tests/fence_inflight/prprobe` - are built only by `scripts/platform_build.sh` (`gcc -O2 -Wall -I include -o "$h" "$h.c"`), never by `make tools` or `make modules`.

Found 2026-10-22 (0.90.134, 4K-native work): `caw_verify.c`, `caw_slotdump.c` and `recov_forge.c` were changed on 2026-10-21 to take LBAs in the device's own logical blocks, but the binaries in the tree dated from 2026-10-14 and still took 512-byte LBAs (`caw_verify` printed `<lba_512>` in its usage). The nodes run the tree's binaries over NFS, so a board row on a 4096-byte LUN handing `caw_verify` a device-block LBA would have written 8x too far in: into the journal or the mounted volume.

Apply:
- After editing any of those six `.c` files, rebuild them with platform_build.sh's command, or compare each binary's mtime with its source before a rig run (`stat -c %Y`).
- Before freezing a release candidate, check all six are newer than their sources: the candidate freezes the binaries as files, and its build step re-verifies only the five TOOLS.
- When a tool's behaviour seems not to match its source, run its usage text first: a stale binary shows the old text.

## Pool LUNs stay on the SATA 870; capture yardsticks there

`feedback-pool-luns-stay-on-the-sata-870-capture-yardsticks-there` - the rig's pool LUN images (`~/disks` -> `/mxfs/disks`, `/mxfs` = `/dev/sda`, a SATA Samsung SSD 870, ~512 MiB/s) moved off the NVMe root on 2026-10-22 by the owner's direction. When a session recommended moving them back to the NVMe (990 EVO Plus) because native XFS on a pool LUN measured only 511 MiB/s sequential write, the owner answered: "LOL -NO-".

Apply:
- Never propose moving the pool LUNs (or the VMs, or evidence) back to the NVMe. The 870 is the rig's LUN backing.
- A native-XFS yardstick measured on a pool LUN is bounded by the 870's SATA link: `host_disk[sda ... MiBs_max=512]` in the capture's own sampler. 511 MiB/s seq write and 539 MiB/s seq read on the 4K-native LUN (2026-10-22) are the disk, not XFS.
- Yardsticks captured before the move (the 512-byte `.xfs_fio_baseline.disk-caw-*.scst-fio.json`, 2026-10-01/04, 1133/1291 MiB/s) were measured on the NVMe and are stale for every board run on the 870: `tools/xfs_baseline_refresh.sh` says to re-measure whenever the LUN backing changes. Re-capture them on the 870 before grading any board's `fio_perf_vs_xfs`.
- Capture only on a quiet host: a board run or a package build on the lab VMs (whose disks are also on `/mxfs`) loads the same 870 and biases the yardstick low.
