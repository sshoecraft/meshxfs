---
name: compiled-vsphere-test-rig-esxhost2-avoidance-per-platform-builds-and-parallel-iso-trap
description: vSphere test rig lessons: keep guests off esxhost2 (soft lockups), build driver+tools on a new platform's first node, don't parallel-build an uncache…
metadata:
  type: feedback
tags: [compiled, vsphere, esxi, esxhost2, soft-lockup, build, platform, mkosimage, iso]
---

Assorted group (loose): three lessons from the 2026-10-12 vSphere vstest1/vstest2 (AlmaLinux 9) bring-up. Common thread: standing up test guests on a non-rig platform.

## Keep vSphere test guests off esxhost2
Source: `user-esxhost2-has-always-had-soft-lockup-problems-keep-it-off`

User, 2026-10-12: "There was always a problem with ESX2 and the soft lockups. I used to just keep it off." Said after a day of chasing vstest2 soft lockups that a session had first blamed on two guests sharing one host, then on missing CPU affinity.

Measured on esxhost2-hosted guests:
- Soft lockups with two CPUs spinning in smp_call_function_many_cond (IPI from netstamp_clear / drain_vmap_area_work) waiting on a third CPU that sat idle in default_idle and never woke (swapper/N idle-CPU soft lockups): a halted vCPU not being woken, a hypervisor/nesting fault.
- An 87 s guest clock jump with all vCPUs in timer catch-up.
- Persisted after esxhost2 was pinned to its own socket (processorN.use) and the guest ran alone on it. The guest on esxhost1 in the same setup had zero. No mxfs on any stack.
- esxhost2's .vmx differs from esxhost1's only in VNC enabled, firmware=bios, numa.vcpu.maxPerMachineNode=8 (vs 32), and disconnected serial/parallel/sound devices; none confirmed as the cause.

Confirmed by a swap: vstest1 (0 lockups on esxhost1) live-migrated to esxhost2 became unreachable within minutes; its persistent journal (`journalctl -b -1 -k`) held 73 soft lockups, idle CPU3 "stuck for 2631s", the same smp_call_function_many_cond waits, and a last entry stamped five days in the future. vstest2 moved to esxhost1 stopped locking up. The fault follows esxhost2, not the guest. esxhost2 was then put in maintenance and powered off; both guests run on esxhost1.

Apply: put vSphere test guests on esxhost1; if a two-host test is needed, expect esxhost2's guests to soft-lock and check their dmesg before trusting any result from them. Ask before investing more in esxhost2.

## Build driver and tools on the first node of each platform
Source: `feedback-build-driver-and-tools-on-the-first-node-of-each-platform`

User correction (2026-10-12, vSphere vstest1/vstest2 on AlmaLinux 9): "for every platform you were testing on you would build the driver and tools on the 1st node." The procedure had been lost (not in any memory/doc; possibly in an uncommitted-deleted feedback_make_clean.md), and the session instead concluded run.sh "cannot" run on the nodes because /src/mxfs/tools/mkfs_mxfs (built on clyde, glibc 2.39) refuses to start on EL9 (glibc 2.34). The user was alarmed that the procedure was gone.

Procedure, before any run.sh test on a platform that is not the rig's own OS:
1. Check the marker in `tools/` that says what platform the tree's binaries were compiled for.
2. If different: clean the module and the tools (`make clean` deletes both; `make modules` alone does not rebuild tools).
3. On the FIRST node of the new platform, over the shared /src: build the driver (`mxfs.ko`) and the tools from /src/mxfs.
4. Write the marker naming the platform (OS id/version, kernel, node) it was built on.
5. Going back to the rig (clyde/Ubuntu test1..N): clean and rebuild on clyde, re-mark.

Why: nodes execute mkfs_mxfs, chk_mxfs, caw_verify, fua_verify, fsx etc. from /src/mxfs over NFS, and prep_node.sh loads the repo mxfs.ko when its vermagic matches the node's kernel. Binaries linked on another distro's glibc fail with "version `GLIBC_2.38' not found". Never answer a glibc/ABI mismatch with "we can't test on these nodes"; rebuild on the first node.

## Parallel mkosimage builds of an uncached ISO boot a half-downloaded ISO
Source: `trap-parallel-mkosimage-builds-boot-a-half-downloaded-iso`

Observed 2026-10-12 building vstest1/vstest2 (alma-9-latest on vsphere/lab) in parallel. User saw "vstest1 didnt start and 2 is stuck at grub prompt".
- osimager/packer download straight into `<iso_path>/<name>.iso` (`/iso` = `/data/media/cdimages/os`). The `.iso.lock` beside it is NOT honoured by a second build: the second packer logged "Skipping download, ... already exists in the local cache" while the first was 1.2 GB into a 13.3 GB download.
- On vSphere the `iso` datastore is the same directory and `[iso] packer_cache` is a self-symlink (`packer_cache -> .`), so it also logged "Skipping upload ... already exists in remote cache" and booted the truncated ISO -> GRUB prompt, then hung at "Waiting for IP".
- Rule: when the ISO is not already complete in /iso, build ONE node first (or download the ISO alone), and start the others only after its size is final. Check `ls -la /iso/<name>.iso` against the expected size before a parallel build.
- Recovery: `govc vm.power -off -force <vm>; govc vm.destroy <vm>` fails that packer build out; the downloading build is unaffected.
