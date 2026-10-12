---
name: compiled-pve-guest-lifecycle-delegation-scripts-and-rig-diagnosis-traps
description: Assorted: shut nested pve9-* guests after tests, never raise pve1/pve2, scripts not bash -c, mountpoint -q EIO, iput under grant, clock skew stalls.
metadata:
  type: feedback
tags: [compiled, pve, delegation, rig, traps, feedback]
---

This is a `kind: assorted` group: two user directives about Proxmox hosts, one about delegated shell work, and three rig/diagnosis traps. No single topic; organised by kind. All dated 2026-10-11 unless noted.

## User directives on Proxmox guests

- Nested Proxmox VE guests pve9-1..pve9-7 (libvirt domains on clyde) are shut down as soon as the test that needs them completes; never left running idle. Trigger: clyde ran out of RAM and disk (94 GB RAM, guests configured for 152 GB; 35 guests held 63 GB RAM + 15 GB swap, swap 100% full; idle pve9-3..7 alone held 27 GB). `feedback-nested-pve-guests-are-shut-down-when-their-test-completes`
  - Any harness or manual session that boots pve9-* shuts them down (`virsh shutdown`, bounded, `destroy` as fallback) at test end, including failure/exit (trap).
  - Before leaving a session, check `virsh -c qemu:///system list` for running pve9-* nothing is using.
  - `tools/vm_reclaim.sh` trims a guest's qcow2 (fstrim inside, discard=unmap on every domain) and leaves a domain it had to boot shut off again.
- Never raise the physical Proxmox pair pve1/pve2 (state, redeploys, version drift, "state the next session inherits", rule-interpretation examples) unless the user brings them up in that turn. Corrected three times in one conversation. The user's position: everything doable there is doable on rig VMs test1..test32; those hosts are noisy, off by default, and their state is the user's concern. If a task genuinely cannot be done on the rig, say what specifically and ask once. `feedback-never-bring-up-pve1-pve2-unless-the-user-does`

## Delegated shell work

- A grind agent given prose steps improvised `xargs -0 -P4 -I{} bash -c '...'`; Claude Code cannot parse a `bash -c` body and stopped on a permission prompt (same for a `timeout 300 bash -c '...'` sweep). User: "Don't do this again. Write a script." `feedback-a-delegated-shell-pipeline-goes-in-a-repo-script-never-an-inline-bash-c`
  - Multi-step or parallel shell work goes into a script in `tools/` or `tests/` first (example: `tools/compress_evidence.py`), then the agent runs that one script.
  - The agent prompt names the exact script and explicitly forbids `bash -c` / `sh -c` / `xargs ... sh -c`.
  - Data one-offs: `python3 - <<'EOF'` heredocs pass the checker; `bash -c` does not.

## Rig and diagnosis traps

- `mountpoint -q` stats the mount root; with the backing LUN gone it gets EIO and reports "not mounted" while `/proc/mounts` still lists it. `tools/lun_pool.sh` NODE_UNMOUNT broke out on that, never called `umount`, and every bind failed UNMOUNT_FAIL (test8-16, 0.90.123); plain `umount` succeeded instantly. Decide "still mounted" from `/proc/mounts`; use `mountpoint -q` only to gate `fuser -km` (on a non-mountpoint fuser resolves to `/` and kills sshd). A D-state `mxfs-worker bast_poll_fn` in msleep on such a node is not a stuck umount. `trap-mountpoint-q-is-false-on-a-mount-whose-storage-is-gone`
- On a multi-node mount `xfs_inode_mark_reclaimable` runs `xfs_inactive` synchronously in the task dropping the last reference, and that takes the inode's DLM lock EX. So any `iput`/`xfs_irele`/`shrink_dcache_parent`/`d_prune_aliases` is a potential cross-node acquire. Doing one inside a directory acquire window (i_dlm_state ACQUIRING = 4, peer BASTs deferred) deadlocked against a peer in `rmdir` (child then parent): D-DIR-RELOAD-CHILD-INACTIVATION-DEADLOCK, 480 s, 15 nodes stuck at 0.90.122. Rule: never drop an inode reference inside an acquire window or under a held DLM grant; queue it (0.90.123 `i_mxfs_dshrink_work`). Signatures: P-ACQ-STUCK with unchanged hpr, P-DIRBAST state=4 ex=0 pr=0, P35-ACQBAST-HONOR in the same ms as the child lock returning; P-SYNC-INACT-SLOW (>=10 s) prints the caller stack, P-DSHRINK-INACT witnesses the deferred path. Cross-node timelines: map kmsg monotonic to wall clock via the median of (realms= minus mono ms), subtract the clock_test<N> offset; hpr=0x4000 is disklock slot 14. `trap-an-iput-inside-a-directory-acquire-runs-a-childs-synchronous-inactivation-under-the-held-grant`
- Before calling a path-row stall an MXFS fault, check the node clock. Two-load rows start/stop all loads together, so each pair of `load_<node>/ops.log` must span the same duration within ~1 s; constant offset at both ends is skew, differing start/end offsets is a mid-row step. Seen: test2 74 s behind made four rows FAIL on fake "72 s stalls" (disposed D-2NODE-MPATH-VICTIM-LOAD-BLOCKED-OUTSIDE-ITS-OPS as DISPROVED); a 366 s step made a 16.7 s op look like 383 s. pathload writes an op line only after the op returns, so gaps between ops are time outside MXFS. Harness fix 0.90.122: `tests/lib/rig.sh` `clock_measure`/`clock_off`/`clock_steady`; a node moving >2 s mid-row ends the row ABORT. Related: unmount rc=32 within ms is EBUSY; look for a stray pathload from an externally stopped chain. `trap-a-node-clock-offset-or-step-reads-as-a-filesystem-stall-in-path-rows`
