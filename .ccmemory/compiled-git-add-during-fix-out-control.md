---
name: compiled-git-add-during-fix-out-control
description: git status before git add -A mid fix-out control; owner process rules: steps, answer first, naming, local time, handoff; lab VMs: sudo virsh, pve9
metadata:
  type: feedback
tags: [compiled, git, commit, control-batch, harness_batch, control_precheck, revert, lane, user-direction, process, naming, time, handoff, ccmemory, lab-vm, virsh, pve, libvirt, owner-communication, direct-question, stop]
---

Standing process rules for sessions in this project, in three parts: commit hygiene around a fix-out control (`git add -A` while a fix is reverted in the shared tree ships the source without it), the owner's process corrections, and how to treat the lab's VMs. The first part is this article's original single-trap content; the other two were absorbed whole from `compiled-user-process-corrections-and-lab-vm-rules`.

## Commit hygiene: `git add -A` during a fix-out control

Began as an assorted-tail group of one note, no sibling topic. It is a single trap: `git add -A` while a fix-out control has a fix reverted in the shared working tree commits and pushes the source without the fix. `trap-git-add-all-during-a-fix-out-control-commits-the-reverted-source`

### Mechanism: the fix is out of the shared tree for the length of a control

- `tools/harness_batch.py control --revert <fix.diff>` and `tools/control_precheck.sh` take a fix out by applying its diff in reverse in the working tree (`patch -p1 -R`), run laps, then put it back. `trap-git-add-all-during-a-fix-out-control-commits-the-reverted-source`
- A detached lane (`scripts/rig_lane.sh`) can be in that window for many minutes. `trap-git-add-all-during-a-fix-out-control-commits-the-reverted-source`

### What happened (0.90.134, 2026-10-22)

- A lane was running the D-CHK-FREESPACE-REBUILD fix-out control, so `tools/chk_mxfs.c` had the free-space rebuild fix removed.
- The session ran its pre-push memory-compaction commit with `git add -A` (the commit-everything rule) and pushed. Commit 2ae126a published `tools/chk_mxfs.c` WITHOUT the integrity fix.
- `git status --porcelain` printed ` M tools/chk_mxfs.c` in the same command and was not read before the add. `trap-git-add-all-during-a-fix-out-control-commits-the-reverted-source`

### Apply

- Before any commit, read `git status --porcelain`. A modified file named in a `+++ b/` line of a `tests/evidence/controls/*.fix.diff`, while a lane's `summary.log` shows a control or control_precheck step started and not ended, means a fix is out. Wait for that step's `restored:` / `the fix is back in` line, then commit.
- If it already happened: commit the restored file as soon as the control restores it, with a message that says the previous commit carried the reverted file, and push.
- Schedule commits and pushes between control steps, or before launching a lane that reverts. `trap-git-add-all-during-a-fix-out-control-commits-the-reverted-source`

## User process corrections

From `compiled-user-process-corrections-and-lab-vm-rules`. Topic of this part and the next: the user's standing process corrections for sessions in this project, and the rules for handling the lab's VMs. That article was split out of [[compiled-harness-oracle-blind-spots-and-delete-guard-traps]] when that article passed the size ceiling; the harness/oracle, rig-operation, product and deletion traps stayed there. It had folded earlier `compiled-user-process-corrections-and-rig-operating-traps` (twelve notes; all stand as written unless marked superseded) and `compiled-pve-guest-lifecycle-delegation-scripts-and-rig-diagnosis-traps` (assorted; dated 2026-10-11 unless noted). Backticked names ending a bullet (`trap-`, `feedback-`, `user-`, `technique-`) are the raw notes folded earlier, already deleted, kept as provenance. Later fold: `feedback-answer-the-owners-direct-question-first-and-at-once` (2026-10-22).

### Process fidelity

- Execute the user's stated steps, in their order, with their mechanism. Told "commit and push, then `git fetch && git pull` on each node and `make install OVERWRITE=1`", rsync'ing the working tree to "test first" skipped exactly the path under test. If a step cannot be done as stated (permission, rule, missing prerequisite, safety), STOP and report the specific conflict and what would unblock it. Never choose an alternative route. An interrupted instruction is not cancelled by default; confirm. `feedback-follow-the-users-process-exactly-and-stop-on-a-conflict` `compiled-user-process-corrections-and-rig-operating-traps`
- Do not propose commits mid-development or in handoffs; commit only when the feature/fix works or the user directs it. User: "Why release something that doesn't work?" Version control here tracks working states, not in-progress experiments; mid-development commits add noise. When wrapping up a session with broken/in-progress code, save state to state.md and memory (see the handoff bullet below for what is now allowed) but do not list files-to-commit or propose `git` operations. If the user asks for a commit explicitly, follow normal commit protocol. The global rule bans `git` unless directed anyway. Since 2026-10-22 (user directive, project CLAUDE.md): commit, push and release, versions included, need no approval, and the git commands a commit or push takes need no direction in the turn; that overrides this note's "unless the user directs it" and "bans `git` unless directed" for those operations. The waived approval does not waive the pre-commit `git status --porcelain` read (see Apply, above). `Commits only when work is done/working` `compiled-user-process-corrections-and-rig-operating-traps`
- Read a rule for its purpose before stretching it. "Never download kernel source" means no source trees/tarballs/clones (`/src/linux` exists); installing `proxmox-headers-*`, `linux-headers-*`, `kernel-devel` on a target VM or throwaway build container (`scripts/pve_kbuild_check.sh`) is how DKMS modules are built and is fine. The .deb depends on `proxmox-default-headers | linux-headers-generic | linux-headers-amd64 | linux-headers`. When unsure, ask in one line rather than proposing a workaround such as dropping the container build check. `feedback-never-downloading-kernel-source-does-not-mean-never-installing-kernel-headers` `compiled-user-process-corrections-and-rig-operating-traps`

### Answering the owner: a direct question first, at once

From `feedback-answer-the-owners-direct-question-first-and-at-once` (owner, 2026-10-22): "ok stop what your doing - i asked this before i want an answer now" and later "AND I TOLD YOU TO STOP WHAT YOUR DOING!!! WE _MUST_ FIX THIS BEFORE DOING _ANYTHING_ ELSE!"

- What happened: the owner asked why `/` was still 91% full after `/mxfs` was added. One session answered only at the bottom of a long end-of-session report, so the question read as ignored. The next kept running rig work (a shutdown reproduction on test31/test32) between replies while the owner waited, and gave a definition ("what is a snapshot") inside a paragraph the owner had to ask for twice.
- A direct question from the owner gets its answer as the first thing in the next reply, plainly, before any work report. A definition asked for is given in one or two sentences on its own line.
- "Stop" means stop starting new work. Answer, then do only what the owner directs. A background job already running may finish, but say so in one line.
- Measure before answering (df, du, the record), and correct a wrong number the moment it is found, saying it was wrong.
- When the owner names the priority ("fix this before anything else"), every step until it is fixed serves that priority and is described as such.

### Naming, time, repo

- A configuration is named only by its full key `<nodes>/<class>/<method>/<attach>` (`2/net/mesh/direct`, `8/disk/caw/direct`); families as patterns (`{2,4,8}/net/mesh/direct`, `*/disk/caw/*`). A lock manager is `net/mesh` or `disk/caw`. Never "2-node TCP", "8-node CAW", "on TCP", or the retired codes `tcp`, `cawd`, `cawp`, `caw`, `tcpmp` (retired in `data/configurations.json`). Applies in chat, README, docs, CHANGELOG, defects, commits, queue files, harness output. Existing code identifiers (`force_transport`, `dlm_caw.c`) are not renamed unasked. Reason: the old codes fused lock manager and attachment and hid that releases were verified on `direct` only. `user-never-use-the-old-naming-convention-name-configurations-by-their-full-key` `compiled-user-process-corrections-and-rig-operating-traps`
- Times told to the user are clyde-local (America/Chicago, label CDT/CST), never UTC. Harness logs mix zones: `date -u`, chain logs and criteria.py stamps are UTC; platform round `[HH:MM:SS]` prefixes and `stat` mtimes are local. Convert with `date -d '15:30 UTC' '+%H:%M %Z'`. Internal artifacts keep their existing zone. `feedback-give-the-user-times-in-local-time-never-utc` `compiled-user-process-corrections-and-rig-operating-traps`
- `.ccmemory/` stays committed in the public repo; it is a feature (a clone with the ccmemory MCP gets every trap and correction). Never list its removal or gitignoring as hygiene. Consequence: no secrets or test passwords in a memory (they live in `~/.config/mxfslab/secrets`), no site specifics. Root launcher/scratch files remain an undecided hygiene item. `user-ccmemory-stays-in-the-public-mxfs-tree` `compiled-user-process-corrections-and-rig-operating-traps`
- Handoff is the ccloop relay (automatic) plus ccmemory, nothing else. Never put rolling state (build srcversion, blocker, findings, next steps) in CLAUDE.md (a ~34 KB awareness line once did, loaded every session), never invent STATE.md, never use CHANGELOG.md for troubleshooting notes. The original note says to write a new `sessNN-*` memory per session; that naming is superseded by the current rule that memories are named for the lesson, never a session or date. The no-CLAUDE.md/STATE.md/CHANGELOG part stands. (The commits note's "save state to state.md" is likewise superseded by this: no STATE.md.) `feedback-handoff-state-via-relay-and-ccmemory-never-claude-md` `compiled-user-process-corrections-and-rig-operating-traps`

## Lab VMs, libvirt and Proxmox guests

From `compiled-user-process-corrections-and-lab-vm-rules`.

- Do not wait for permission on lab VMs. test1..test32, pve9-1/pve9-2 (libvirt), vstest1/vstest2/alma-97 (vSphere via govc) may be reset, power-cycled, resized or reconfigured whenever a test needs it; report afterwards. Excluded: clyde itself, ESXi hosts, vCenter, the QNAP (its iSCSI service is never restarted). Still check for shared-LUN mounts first when evidence matters. `feedback-lab-vms-are-disposable-reset-them-without-asking` `compiled-user-process-corrections-and-rig-operating-traps`
- All libvirt operations use `sudo virsh` (qemu:///system), never bare `virsh` (qemu:///session), in scripts and direct invocation alike. User-session libvirt runs QEMU as an unprivileged user with CapEff=0x0; SCSI passthrough (CAW, PR) needs CAP_SYS_RAWIO, which system libvirt (QEMU as root) has. Bare `virsh` silently breaks every SCSI CAW operation with "Aborted command, I/O process terminated" while basic reads/writes still work, which makes the failure deceptive. Documented in docs/qemu_direct_caw.md (lines 97-106) and docs/qemu_tcm_loop_setup.md (lines 10-13); read the project docs before touching the test environment. `feedback_sudo_virsh` `compiled-user-process-corrections-and-rig-operating-traps`
- Nested Proxmox VE guests pve9-1..pve9-7 (libvirt domains on clyde) are shut down as soon as the test that needs them completes; never left running idle (2026-10-11). Trigger: clyde ran out of RAM and disk (94 GB RAM, guests configured for 152 GB; 35 guests held 63 GB RAM + 15 GB swap, swap 100% full; idle pve9-3..7 alone held 27 GB). `feedback-nested-pve-guests-are-shut-down-when-their-test-completes` `compiled-pve-guest-lifecycle-delegation-scripts-and-rig-diagnosis-traps`
  - Any harness or manual session that boots pve9-* shuts them down (`virsh shutdown`, bounded, `destroy` as fallback) at test end, including failure/exit (trap).
  - Before leaving a session, check `virsh -c qemu:///system list` for running pve9-* nothing is using.
  - `tools/vm_reclaim.sh` trims a guest's qcow2 (fstrim inside, discard=unmap on every domain) and leaves a domain it had to boot shut off again.
- Never raise the physical Proxmox pair pve1/pve2 (state, redeploys, version drift, "state the next session inherits", rule-interpretation examples) unless the user brings them up in that turn. Corrected three times in one conversation (2026-10-11). The user's position: everything doable there is doable on rig VMs test1..test32; those hosts are noisy, off by default, and their state is the user's concern. If a task genuinely cannot be done on the rig, say what specifically and ask once. `feedback-never-bring-up-pve1-pve2-unless-the-user-does` `compiled-pve-guest-lifecycle-delegation-scripts-and-rig-diagnosis-traps`
