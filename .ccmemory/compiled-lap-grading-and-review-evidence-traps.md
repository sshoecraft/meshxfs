---
name: compiled-lap-grading-and-review-evidence-traps
description: Assorted lap/review lessons: infra-proven proposal evidence, lap helper rc, drafts-tree run.sh root, VFS ESTALE retry, kmsg fromnode ring since boot
metadata:
  type: feedback
tags: [compiled, laps, release-review, kmsg, testing]
---

Assorted group (the clusterer could not fit these to one topic): five lessons, all from session 8815bf68 on 2026-10-24, about how a lap or review is graded and where its evidence comes from.

## Infra-proven proposals need node dmesg and every lock holder named
`technique-infra-proven-proposal-needs-node-kmsg-window-and-every-lock-holder-named`

The release-reviewer rejects an infra-proven proposal whose "no MXFS signature" rests on a harness log being silent. It also rejects one whose blocking lock's holder is unnamed, because an MXFS unmount stalling under the lock cannot be ruled out. The peer_window lap passed on the second try, the lh_master lap only on the third. For an INCOMPLETE lap, what got them approved:
- Each node's own dmesg ring for the window, pulled after the fact: `dmesg --time-format iso | awk '$1 >= "<start>" && $1 < "<end>"'`. Show the ring reaches back to boot, state the capture command, and show any repeated benign line (e.g. one 'reservation conflict' pair per module load) is the baseline at every load.
- Every holder named down the chain: the pool lock (`run.sh` preflight under `lun_pool.sh quiet`) -> the power-up lock (`lab_power.sh up` of each lane) -> for each holder, the host journal's libvirtd 'Domain id=N name=...' and systemd-machined 'terminated' lines, proving the VMs booted from off.
- Re-run every disposition-critical negative yourself (e.g. no other domain started in the window).
- Lane logs give step windows. lab_power's own 'host power-up lock held' line exists only when the caller keeps its output.

## Lap helper `on()` returns grep's rc, not the remote rc
`trap-lap-on-helper-rc-is-greps-not-the-ssh-commands`

tests/fourkn_merge_2node.sh's `on() { timeout ... ssh ... | grep -avE '^Warning:...'; }` returns grep's status: 1 when the killed client printed nothing, 0 when anything printed. A lap testing `rc=124` on that line could never see an overrun and graded every lap VACUOUS (tests/merge_overrun_lap.sh).
- `fuser -m DIR` on a directory that is no longer a mount point counts every user of the root filesystem (~130), and misses a looping bash worker with no file open at that instant.
- Apply: grade overruns from measured walls against the bound, holds from /proc/mounts plus `ps -C <comm>`. Never trust rc through a pipeline without PIPESTATUS.

## A draft run.sh in the drafts tree becomes the lap tree root
`trap-draft-run-sh-in-drafts-tree-becomes-lap-tree-root`

Draft laps under tests/evidence/drafts/tree/tests/ locate the repo by walking up until a run.sh exists. Copying run.sh into drafts/tree (to draft a run.sh fix) made that the root. Three merge-overrun laps aborted in 8 s (no tools/mxfs_lab.sh there) and wrote evidence under drafts/tree/tests/evidence/.
- Apply: root walks use `while { [ ! -f run.sh ] || [ ! -f tools/mxfs_lab.sh ]; } && [ "$(pwd)" != / ]; do cd ..; done`. Before copying run.sh into drafts/tree, check no draft lap there is running or queued.
- Related lane trap: scripts/lane_after.sh picks `ls -dt lanes/<name>_*`, which also matches `<name>_wait.log`. A wait log newer than the lane dir keeps it waiting.

## The VFS retries ESTALE lookups, hiding xfs_lookup give-ups
`trap-vfs-retries-estale-lookup-so-workload-errors-miss-resolver-giveups`

Linux retries a path walk that returned -ESTALE (LOOKUP_REVAL), so a single xfs_lookup give-up is invisible to userspace. Measured on 4/disk/caw/mpath path_mount_degraded, typeflip_relookup_shell_dead=0: 5 shell-dead give-ups on test7, every pathload op ok (err=0).
- P201-RELOOKUP is mxfs_probe_ratelimited, so pairing give-up lines with relookup lines fails past ~10 per burst.
- Apply: a lap grading a lookup/resolver fix must read a module counter of the outcome (atomic_t + module_param_cb with mxfs_dbg_atomic_param_ops, write resets), not the workload's error count or ratelimited probe lines.

## kmsg_<node>_fromnode.gz holds the ring since boot
`trap-kmsg-fromnode-holds-ring-since-boot-count-after-pf-mark`

The path rows' kernel-log follower (tests/lib/rig.sh ~292-305) starts by dumping the node's whole dmesg ring, so `kmsg_<node>_fromnode.gz` in a `board_*` dir holds every line since boot, including earlier rows on the same boot. A fix-off path_mount_degraded run "showed" 10 `why=shell-dead` relookups that need the fix on; they were byte-identical to the previous fix-on run's lines, from before this run's PF-MARK.
- Apply: `zcat f.gz | sed -n '/PF-MARK/,$p'` before counting any probe per run. Plain `grep -r` also skips the .gz files entirely, so use zgrep/zcat.
