---
name: compiled-revert-control-pre-fix-source-and-per-part-switches
description: Revert controls (sibling-checkout pre-fix source, one switch per part), git add -A during fix-out, owner process rules, lab VMs, clyde snapshots/I/O…
metadata:
  type: feedback
tags: [compiled, release-gate, revert-control, technique, defects-queue, fix-switch, git, commit, control-batch, harness_batch, control_precheck, lane, user-direction, process, naming, time, handoff, ccmemory, lab-vm, virsh, pve, libvirt, owner-communication, direct-question, stop, rig, clyde, preflight, snapshots, lun_pool, sar, host-io, scst, disk-space, mxfs-disk, evidence, owner-directive]
---

Standing process rules and host-state lessons for sessions in this project, in five parts: (A) building revert controls for the release gate (pre-fix source from a sibling checkout; one switch per fix part); (B) commit hygiene around a fix-out control (`git add -A` while a fix is reverted in the shared tree ships the source without it); (C) the owner's process corrections; (D) how to treat the lab's VMs; (E) clyde's own disk and I/O state (kept snapshot images fill `/`, what the `/mxfs` disk is for, host write storms that stall every pool LUN). Parts A and B are control-lane mechanics; C-E are process and host rules that share no narrower topic with them. This article is the merge of the revert-control article (original name kept) with `compiled-git-add-during-fix-out-control`, absorbed whole; that one had itself absorbed `compiled-user-process-corrections-and-lab-vm-rules` and `compiled-kept-snapshots-fill-clyde-root-and-host-io-storms`. Absorbed article: `compiled-git-add-during-fix-out-control`. Backticked names ending a bullet (`trap-`, `feedback-`, `user-`, `technique-`) are raw notes folded earlier and already deleted, kept as provenance.

# A. Revert controls for the release gate

Assorted-tail group of one note. Its two techniques share one topic: building revert controls (`--revert` controls, fix-out lanes, switched fix parts) for the release gate. Learned in 0.90.134, 2026-10-23. `technique-pre-fix-source-from-sibling-checkouts-and-one-switch-per-part`

## 1. A fix whose diff was never saved: read the old form from a sibling checkout

- A `--revert` control needs "the candidate's source with only the fix reverted", but `git show`/`git log` are not allowed without the owner's direction, and `tests/evidence/controls/` held no diff for the fsx.sh EXIT-trap fix (D-FSX-SH-SENT-FSX-OUTPUT-TO-A-TMP-LOG-ITS-EXIT-TRAP-DELETED). `technique-pre-fix-source-from-sibling-checkouts-and-one-switch-per-part`
- The host keeps older checkouts beside the tree: `/home/steve/src/mxfs-{b,c,d0349,dev,e,f,g,ledger,v130,wt-*}` (also under `/src`). Compare the file across them with `stat -c %y` and `sha256sum`: there, eight copies of `tests/suite/fsx.sh` hashed alike from 2026-06-14 through `mxfs-v130` (0.90.130), the last pre-fix form.
- Build the old side as today's file with ONLY the fix's hunks replaced by the old forms (keep later, unrelated changes, e.g. fsx's `-S "$SEED"`), in the scratchpad: `a/<path>` and `b/<path>`, then `diff -u a/<path> b/<path> > tests/evidence/controls/<record>.fix.diff` and `patch -p1 -R --dry-run` from the tree root. State in the record which checkout and lines the old side came from.
- Precheck with `tools/control_precheck.sh <diff> -- timeout <bound> <lap>`: it reverts, runs, restores and checks the hash. Do not commit while a lane's fix-out step runs (`git status --porcelain` must not show the reverted file); see part B.

## 2. One switch over several parts of a fix proves only the first part

- D-RELEASE-RUN-STEP-INCIDENTS-CANNOT-BE-SETTLED had four parts (parse, annotated_run, the command's board choice, run_board) behind one switch. With it off, every disposition was refused at the parse, so the control never reached the other three, and the removal was rejected (`data/reviews/P20261023-463c4c.md`): "Three of the four switched hunks therefore have no measured failure behind them." `technique-pre-fix-source-from-sibling-checkouts-and-one-switch-per-part`
- A part also masks the parts after it in the same command pipeline: with only the routing (run_board) off, `propose --target` failed in check_cells before criteria.py's board choice ran. So that choice needed a switch of its own too (`MXFS_RELEASE_STEP_BOARD`).
- Do: give each part its own switch, run the lap once with each switch off, and confirm in the lap's output that each arm fails at its own code (the refusal text names the site). Then split the record, one per switch, each with its own control and fix-on batch. Evidence: `tests/evidence/release_step_switches_20261023T171448Z` (9, 12, 4 and 4 of 12 refused, one arm per switch).

# B. Commit hygiene: `git add -A` during a fix-out control

Began as an assorted-tail group of one note, no sibling topic. It is a single trap: `git add -A` while a fix-out control has a fix reverted in the shared working tree commits and pushes the source without the fix. `trap-git-add-all-during-a-fix-out-control-commits-the-reverted-source`

## Mechanism: the fix is out of the shared tree for the length of a control

- `tools/harness_batch.py control --revert <fix.diff>` and `tools/control_precheck.sh` take a fix out by applying its diff in reverse in the working tree (`patch -p1 -R`), run laps, then put it back. `trap-git-add-all-during-a-fix-out-control-commits-the-reverted-source`
- A detached lane (`scripts/rig_lane.sh`) can be in that window for many minutes. `trap-git-add-all-during-a-fix-out-control-commits-the-reverted-source`

## What happened (0.90.134, 2026-10-22)

- A lane was running the D-CHK-FREESPACE-REBUILD fix-out control, so `tools/chk_mxfs.c` had the free-space rebuild fix removed.
- The session ran its pre-push memory-compaction commit with `git add -A` (the commit-everything rule) and pushed. Commit 2ae126a published `tools/chk_mxfs.c` WITHOUT the integrity fix.
- `git status --porcelain` printed ` M tools/chk_mxfs.c` in the same command and was not read before the add. `trap-git-add-all-during-a-fix-out-control-commits-the-reverted-source`

## Apply

- Before any commit, read `git status --porcelain`. A modified file named in a `+++ b/` line of a `tests/evidence/controls/*.fix.diff`, while a lane's `summary.log` shows a control or control_precheck step started and not ended, means a fix is out. Wait for that step's `restored:` / `the fix is back in` line, then commit.
- If it already happened: commit the restored file as soon as the control restores it, with a message that says the previous commit carried the reverted file, and push.
- Schedule commits and pushes between control steps, or before launching a lane that reverts. `trap-git-add-all-during-a-fix-out-control-commits-the-reverted-source`

# C. User process corrections

From `compiled-user-process-corrections-and-lab-vm-rules`. Topic of this part and the next: the user's standing process corrections for sessions in this project, and the rules for handling the lab's VMs. That article was split out of [[compiled-harness-oracle-blind-spots-and-delete-guard-traps]] when that article passed the size ceiling; the harness/oracle, rig-operation, product and deletion traps stayed there. It had folded earlier `compiled-user-process-corrections-and-rig-operating-traps` (twelve notes; all stand as written unless marked superseded) and `compiled-pve-guest-lifecycle-delegation-scripts-and-rig-diagnosis-traps` (assorted; dated 2026-10-11 unless noted). Later fold: `feedback-answer-the-owners-direct-question-first-and-at-once` (2026-10-22).

## Process fidelity

- Execute the user's stated steps, in their order, with their mechanism. Told "commit and push, then `git fetch && git pull` on each node and `make install OVERWRITE=1`", rsync'ing the working tree to "test first" skipped exactly the path under test. If a step cannot be done as stated (permission, rule, missing prerequisite, safety), STOP and report the specific conflict and what would unblock it. Never choose an alternative route. An interrupted instruction is not cancelled by default; confirm. `feedback-follow-the-users-process-exactly-and-stop-on-a-conflict` `compiled-user-process-corrections-and-rig-operating-traps`
- Do not propose commits mid-development or in handoffs; commit only when the feature/fix works or the user directs it. User: "Why release something that doesn't work?" Version control here tracks working states, not in-progress experiments; mid-development commits add noise. When wrapping up a session with broken/in-progress code, save state to state.md and memory (see the handoff bullet below for what is now allowed) but do not list files-to-commit or propose `git` operations. If the user asks for a commit explicitly, follow normal commit protocol. The global rule bans `git` unless directed anyway. Since 2026-10-22 (user directive, project CLAUDE.md): commit, push and release, versions included, need no approval, and the git commands a commit or push takes need no direction in the turn; that overrides this note's "unless the user directs it" and "bans `git` unless directed" for those operations. The waived approval does not waive the pre-commit `git status --porcelain` read (see part B, Apply). `Commits only when work is done/working` `compiled-user-process-corrections-and-rig-operating-traps`
- Read a rule for its purpose before stretching it. "Never download kernel source" means no source trees/tarballs/clones (`/src/linux` exists); installing `proxmox-headers-*`, `linux-headers-*`, `kernel-devel` on a target VM or throwaway build container (`scripts/pve_kbuild_check.sh`) is how DKMS modules are built and is fine. The .deb depends on `proxmox-default-headers | linux-headers-generic | linux-headers-amd64 | linux-headers`. When unsure, ask in one line rather than proposing a workaround such as dropping the container build check. `feedback-never-downloading-kernel-source-does-not-mean-never-installing-kernel-headers` `compiled-user-process-corrections-and-rig-operating-traps`

## Answering the owner: a direct question first, at once

From `feedback-answer-the-owners-direct-question-first-and-at-once` (owner, 2026-10-22): "ok stop what your doing - i asked this before i want an answer now" and later "AND I TOLD YOU TO STOP WHAT YOUR DOING!!! WE _MUST_ FIX THIS BEFORE DOING _ANYTHING_ ELSE!"

- What happened: the owner asked why `/` was still 91% full after `/mxfs` was added. One session answered only at the bottom of a long end-of-session report, so the question read as ignored. The next kept running rig work (a shutdown reproduction on test31/test32) between replies while the owner waited, and gave a definition ("what is a snapshot") inside a paragraph the owner had to ask for twice.
- A direct question from the owner gets its answer as the first thing in the next reply, plainly, before any work report. A definition asked for is given in one or two sentences on its own line.
- "Stop" means stop starting new work. Answer, then do only what the owner directs. A background job already running may finish, but say so in one line.
- Measure before answering (df, du, the record), and correct a wrong number the moment it is found, saying it was wrong.
- When the owner names the priority ("fix this before anything else"), every step until it is fixed serves that priority and is described as such.

## Naming, time, repo

- A configuration is named only by its full key `<nodes>/<class>/<method>/<attach>` (`2/net/mesh/direct`, `8/disk/caw/direct`); families as patterns (`{2,4,8}/net/mesh/direct`, `*/disk/caw/*`). A lock manager is `net/mesh` or `disk/caw`. Never "2-node TCP", "8-node CAW", "on TCP", or the retired codes `tcp`, `cawd`, `cawp`, `caw`, `tcpmp` (retired in `data/configurations.json`). Applies in chat, README, docs, CHANGELOG, defects, commits, queue files, harness output. Existing code identifiers (`force_transport`, `dlm_caw.c`) are not renamed unasked. Reason: the old codes fused lock manager and attachment and hid that releases were verified on `direct` only. `user-never-use-the-old-naming-convention-name-configurations-by-their-full-key` `compiled-user-process-corrections-and-rig-operating-traps`
- Times told to the user are clyde-local (America/Chicago, label CDT/CST), never UTC. Harness logs mix zones: `date -u`, chain logs and criteria.py stamps are UTC; platform round `[HH:MM:SS]` prefixes and `stat` mtimes are local. Convert with `date -d '15:30 UTC' '+%H:%M %Z'`. Internal artifacts keep their existing zone. `feedback-give-the-user-times-in-local-time-never-utc` `compiled-user-process-corrections-and-rig-operating-traps`
- `.ccmemory/` stays committed in the public repo; it is a feature (a clone with the ccmemory MCP gets every trap and correction). Never list its removal or gitignoring as hygiene. Consequence: no secrets or test passwords in a memory (they live in `~/.config/mxfslab/secrets`), no site specifics. Root launcher/scratch files remain an undecided hygiene item. `user-ccmemory-stays-in-the-public-mxfs-tree` `compiled-user-process-corrections-and-rig-operating-traps`
- Handoff is the ccloop relay (automatic) plus ccmemory, nothing else. Never put rolling state (build srcversion, blocker, findings, next steps) in CLAUDE.md (a ~34 KB awareness line once did, loaded every session), never invent STATE.md, never use CHANGELOG.md for troubleshooting notes. The original note says to write a new `sessNN-*` memory per session; that naming is superseded by the current rule that memories are named for the lesson, never a session or date. The no-CLAUDE.md/STATE.md/CHANGELOG part stands. (The commits note's "save state to state.md" is likewise superseded by this: no STATE.md.) `feedback-handoff-state-via-relay-and-ccmemory-never-claude-md` `compiled-user-process-corrections-and-rig-operating-traps`

# D. Lab VMs, libvirt and Proxmox guests

From `compiled-user-process-corrections-and-lab-vm-rules`.

- Do not wait for permission on lab VMs. test1..test32, pve9-1/pve9-2 (libvirt), vstest1/vstest2/alma-97 (vSphere via govc) may be reset, power-cycled, resized or reconfigured whenever a test needs it; report afterwards. Excluded: clyde itself, ESXi hosts, vCenter, the QNAP (its iSCSI service is never restarted). Still check for shared-LUN mounts first when evidence matters. `feedback-lab-vms-are-disposable-reset-them-without-asking` `compiled-user-process-corrections-and-rig-operating-traps`
- All libvirt operations use `sudo virsh` (qemu:///system), never bare `virsh` (qemu:///session), in scripts and direct invocation alike. User-session libvirt runs QEMU as an unprivileged user with CapEff=0x0; SCSI passthrough (CAW, PR) needs CAP_SYS_RAWIO, which system libvirt (QEMU as root) has. Bare `virsh` silently breaks every SCSI CAW operation with "Aborted command, I/O process terminated" while basic reads/writes still work, which makes the failure deceptive. Documented in docs/qemu_direct_caw.md (lines 97-106) and docs/qemu_tcm_loop_setup.md (lines 10-13); read the project docs before touching the test environment. `feedback_sudo_virsh` `compiled-user-process-corrections-and-rig-operating-traps`
- Nested Proxmox VE guests pve9-1..pve9-7 (libvirt domains on clyde) are shut down as soon as the test that needs them completes; never left running idle (2026-10-11). Trigger: clyde ran out of RAM and disk (94 GB RAM, guests configured for 152 GB; 35 guests held 63 GB RAM + 15 GB swap, swap 100% full; idle pve9-3..7 alone held 27 GB). `feedback-nested-pve-guests-are-shut-down-when-their-test-completes` `compiled-pve-guest-lifecycle-delegation-scripts-and-rig-diagnosis-traps`
  - Any harness or manual session that boots pve9-* shuts them down (`virsh shutdown`, bounded, `destroy` as fallback) at test end, including failure/exit (trap).
  - Before leaving a session, check `virsh -c qemu:///system list` for running pve9-* nothing is using.
  - `tools/vm_reclaim.sh` trims a guest's qcow2 (fstrim inside, discard=unmap on every domain) and leaves a domain it had to boot shut off again.
- Never raise the physical Proxmox pair pve1/pve2 (state, redeploys, version drift, "state the next session inherits", rule-interpretation examples) unless the user brings them up in that turn. Corrected three times in one conversation (2026-10-11). The user's position: everything doable there is doable on rig VMs test1..test32; those hosts are noisy, off by default, and their state is the user's concern. If a task genuinely cannot be done on the rig, say what specifically and ask once. `feedback-never-bring-up-pve1-pve2-unless-the-user-does` `compiled-pve-guest-lifecycle-delegation-scripts-and-rig-diagnosis-traps`

# E. Clyde host: kept snapshots fill the disks, what /mxfs is for, write storms stall every pool LUN

From `compiled-kept-snapshots-fill-clyde-root-and-host-io-storms` (folded whole). Host-side failure modes on clyde that look like MXFS or rig faults but are the host's own state, and the owner's rule for the disk added to stop them. Provenance: run 7e16fd1d, session 31 (2026-10-17) for subsections 1-2; 2026-10-22 for subsection 3. Its sources, folded earlier and already deleted: `trap-kept-snapshots-fill-clyde-root-and-host-write-storms-stall-every-lun`, `feedback-mxfs-disk-is-for-lun-images-test-vms-and-evidence`.

## 1. A burst of `RESULT: ABORT ... stage=prep` within seconds, across every queue, is the host preflight

From `trap-kept-snapshots-fill-clyde-root-and-host-write-storms-stall-every-lun` (`compiled-kept-snapshots-fill-clyde-root-and-host-io-storms`):

- Seen: from 14:04Z every queued lap on every pair (hf8b, hf6t, hf7c: 16 laps) aborted at prep in 8-22 s; all queues reached QUEUE DONE with nothing measured.
- Read the lap's `prep.log` first. Here: `clyde_preflight: FAIL ... test LUN pool (/dev/nvme0n1p2): 100% used, 7G free (limit: >=10G free)`.
- Cause: `tools/lun_pool.sh snapshot` (called by `tests/noino_gen0_ab.sh` on every CORRUPT audit) copied each 20 GiB pool LUN (12-15 G of data) into `/home/steve/disks/snapshots` on the root ext4 with no check; 22 images = 285 G.
- Since 0.90.131 the snapshot refuses a copy that could leave its filesystem below `MXFS_PREFLIGHT_MIN_FREE_GB` (10 G) and honours `MXFS_SNAPSHOT_DIR`.
- SUPERSEDED (2026-10-22, subsection 3): this trap note went on to send kept images to `/mxfs/snapshots` and to put `MXFS_SNAPSHOT_DIR=/mxfs/snapshots` on queue lines. The owner rejected that use of `/mxfs`; the 84 images there (1.2T) were deleted on the owner's approval. `tests/linked_corpse_reuse_ab.sh`, `tests/ilock_eagain_park_ab.sh` (`MXFS_SNAPSHOT_DIR` default) and `lun_pool.sh snapshot` (default `$(dirname $POOL)/snapshots`, now on `/mxfs`) still default to keeping copies; changing that awaits the owner.
- Never clear or skip the preflight to get moving; free the space.

## 2. A snapshot copy (or any big buffered write on /) is a host-wide I/O storm

From `trap-kept-snapshots-fill-clyde-root-and-host-write-storms-stall-every-lun` (`compiled-kept-snapshots-fill-clyde-root-and-host-io-storms`):

- Until 2026-10-22 the pool LUNs, the 32 guest images and the journal shared nvme0n1p2; they now live on `/mxfs` (`/dev/sda`, a Samsung 870 SATA SSD), so read `sda` as well as `nvme0n1` for later storms. Two snapshot copies took nvme0n1 average await from ~0.5 ms to 20-70 ms (aqu-sz ~110) and dirty pages to 6-7 G for about two minutes.
- Two unexplained stalls on concurrent laps sat inside such storms: a 57 s CAW hold at unmount on 2/disk/caw/mpath (13:34Z) and a 35 s path-down stall on an 8-node board (13:14Z).
- Measured with `tests/caw_host_storm_probe.sh`: a lone initiator's CAW latency rose from 10 ms to 1.95 s under a 28 G storm. That is 200x, but not tens of seconds, so the storm alone did not reproduce the 57 s hold.
- Before diagnosing any stall, timeout or budget overrun on the rig as an MXFS fault, read the host's own history for that minute: `LC_ALL=C sar -f /var/log/sysstat/saDD -s HH:MM:00 -e HH:MM:00 -d -p | grep -E 'DEV|nvme0n1$|sda$'` (DEV is the last column, so do not grep `'nvme0n1 '`), and `-r` for kbdirty. sar uses local time (CDT = Z-5).
- `make modules` in the main tree took 376 s instead of ~38 s while a 285 G move ran on the same NVMe.

## 3. The /mxfs disk holds ~/disks, the test VMs and evidence, and nothing else unasked

From `feedback-mxfs-disk-is-for-lun-images-test-vms-and-evidence` (owner, 2026-10-22; `compiled-kept-snapshots-fill-clyde-root-and-host-io-storms`):

- The owner added the 2 TB disk at `/mxfs` for exactly three things:
  - `~/disks` (SCST pool LUN images, the pve and 4Kn LUN images): `~/disks` is a symlink to `/mxfs/disks`;
  - the libvirt test VMs (test1-32, pve9-*, pve92-*, alma/rhel/debian/ubuntu guests): `~/vms/qemu` is a symlink to `/mxfs/vms/qemu`;
  - rig evidence: the data lives in `/mxfs/evidence` ("from now on put evidence in /mxfs/evidence ... move the current one there"). `tests/evidence` is a symlink to `/src/mxfs-evidence`, a bind mount of `/mxfs/evidence` (host `/etc/fstab`), and `/src` is exported with `crossmnt`, so the link resolves to the same directory on a node. Never point the link straight at `/mxfs/evidence`: a node has no `/mxfs`, the link resolved to nothing there, and every row writing evidence from a node failed (alloc_witness `witness_dir=unwritable`, then chk_clean found no sealed witness; D-NODES-CANNOT-WRITE-TESTS-EVIDENCE-IT-LINKS-TO-THE-HOSTS-OWN-MXFS-DISK, 2026-10-22).
- NOT on `/mxfs`: the vmware/vcenter VMs (`~/vms/vmware`, `~/vms/vsphere`, the latter NFS-exported to the nested ESXi lab) stay in `~/vms`. ISOs live in `/iso`, not in the home dir.
- What went wrong: sessions moved 84 kept LUN copies (1.2T, `lunNN-*-2026101[789]*.img`) onto `/mxfs/snapshots` and left the VM disks and LUN images on `/`, which sat at 91% (the same figure as the owner's question under "Answering the owner" above; both 2026-10-22). Owner: "I INSTALLED THAT 2TB DISK _JUST_ FOR THIS PURPOSE AND YOU FILLED IT UP WITH WHAT?? CRAP?" No defect cited any single image.
- A harness that wants to keep a LUN image asks first, or keeps it under the run's own evidence dir, never a standing `snapshots/` pile on either disk.
- After a mass delete on XFS, re-read `df` a few seconds later before reporting free space: XFS frees large files in the background, and a reading taken at once showed 803G used where 148G was true.
- Moving a file SCST holds open (pool LUN images) leaves the device writing the deleted copy: `scripts/scst_reopen.sh <prefix> <move command>` removes the devices, runs the move and re-creates each with its parameters, identity and LUN mappings. A libvirt-owned image (root 0600) needs `sudo mv`; a cross-filesystem `mv` that hits an unreadable file copies the rest and deletes nothing, so finish with `sudo rsync -aH --remove-source-files`.
