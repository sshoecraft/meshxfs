---
name: compiled-lab-hardware-release-scope-and-wording-corrections
description: Assorted owner corrections (2026-10-15): pve1/pve2 hands-off, no profanity in records, DRBD module-load fence, idle VMs, 99/1 rule, no "trial", relea…
metadata:
  type: feedback
tags: [compiled, feedback, release, drbd, lab-hardware, wording]
---

Assorted group (kind: assorted): owner corrections and traps from 2026-10-15, loosely tied by lab-rig hygiene, release scope and record wording.

## Physical hardware: pve1/pve2 (user, 2026-10-15) — `feedback-physical-pve-pair-is-old-hardware-never-reset-or-reboot-it-unasked`
> The only thing that needed testing on the physical boxes was the network-cable pull; everything else runs on VMs; stop wearing out this old hardware.

- pve1/pve2 (11-yr-old HP Z400s) are for the physical network-cable pull only (tests/pve_cable_pull.sh), with the user at the rack.
- Everything else runs on VMs: the board (scripts/prun.sh), crash_audit, failover and resets, fio, failure tests. Use the KVM DRBD rig (test1/test2) or nested Proxmox VMs (pve9-*).
- Never reset, sysrq, reboot or power-cycle pve1/pve2, and do not propose it.
- Incident (2026-10-14/15): pve2 power-cycled three times (cable-pull fence, two physical crash_audit runs via sysrq b); pve1 once (clean reboot to pick up a kernel parameter) and it hung, user reset it by hand. pve2 had already been replaced once: "pve2 used to be a Z400 as well and constant reboots finished it; this is 11-year-old hardware and it keeps getting rebooted."
- A release-table row or harness requiring a board or death test on pvephys is the wrong design; move that evidence to VMs.
- A session added a pvephys sysrq-reset branch to tools/node_power.sh and a physical-victim path to crash_audit; both removed the same night. Do not add them back.

## Never record the user's swearing — `feedback-never-record-the-users-swearing-in-memories-or-docs`
- User, 2026-10-15: do not put their swearing in any memory or doc. Memories/docs are durable records; a verbatim angry quote preserves profanity, not the point.
- Paraphrase corrections, keep substance (e.g. "only the cable pull needed the physical boxes; run everything else on VMs").
- Applies to `.ccmemory/`, `docs/`, CHANGELOG.md, defect records (tools/defects.py), commit messages, code comments. Check any user quote for profanity before writing it.

## Reloading mxfs.ko with DRBD Connected fences the peer — `trap-reloading-mxfs-ko-with-a-drbd-link-up-fences-the-peer`
- 0.90.129: tests/drbd_release_verify.sh failed twice on the KVM DRBD rig with an unprompted link drop and STONITH while clyde memory pressure was 0.00. Node kmsg showed: 'mxfs: loading out-of-tree module' at 33.645 s; 'meta connection shut down by peer' at 34.652 s; module init line at 34.746 s.
- tests/module_load_stall.sh (2-vCPU guest): insmod holds one CPU 921-968 ms (~0.93 s); debug stripping (89 MB to 11.7 MB) did not change it. DRBD PingAck is 0.5 s, so the peer is STONITHed.
- Three harness paths reloaded with the link up: run.sh cluster prep (prep_node.sh without MXFS_KEEP_LOADED); drbd_rig.sh step_outage_test and takeover test after a reboot; the outage test's A2 arm (rmmod then mount).
- Users are not affected: package boot program (mxfs_drbd_fence_self.py cmd_boot) loads the module before `drbdadm up`; upgrades never reload it.
- Misread first: blamed on host starvation and the defect removed. Check node kmsg for 'loading out-of-tree module' before a DRBD drop is blamed on the host.
- Apply: load mxfs.ko before DRBD connects; never rmmod/insmod while Connected. Mount via prep_node.sh with MXFS_KEEP_LOADED=1 (run.sh does for */drbd configs). Set module params on DRBD via /sys/module/mxfs/parameters (debug knobs 0644), not MXFS_EXTRA_MODARGS (silently dropped when module kept; arm measures nothing).
- Product-side defect: D-MODULE-LOAD-HOLDS-A-CPU-930MS-PAST-DRBD-PING-TIMEOUT (noblock).

## Shut off idle VMs; host starvation fabricates defects — `feedback-shut-off-idle-vms-host-starvation-fabricates-defects`
- 2026-10-15: 36 libvirt guests running on clyde (94 GiB), 18 in use, swap full (24/24 GiB), while investigating a "DRBD link drops and peer is fenced" defect.
- User: "didn't I tell you before that if you're not using a VM for a test ... you need to shut it down?"; "I wonder how many times you've logged a defect when the entire time the problem is you starving the host ... I could add 128 more gig of memory, you'll just fill it up again."; "change your tooling so that when you're done using a VM, then you shut it off. Just like you do the disk pool, you need to use a VM pool."
- A guest unscheduled 0.5 s drops DRBD (PingAck); seconds misses heartbeats and lock deadlines.
- Shut off every VM not in use: `tools/vm_pool.sh status`, `tools/vm_pool.sh idle`. Pool design like tools/lun_pool.sh. In use = run.sh node lock (/tmp/mxfs_node.<vm>.lock), hold lock (vmhold_take in tests/lib/runlock.sh, /tmp/mxfs_vmhold.<vm>.lock), or exclusive /tmp/mxfs_run.lock (covers test*). Anything else is idle.
- Before filing a stall-like defect, read clyde /proc/pressure/memory, swap use, running-VM count for that window; a defect seen on a starved host is suspect until it reproduces unstarved.

## 99/1 rule: rare unreproduced defects do not hold a release — `feedback-rare-unreproduced-defects-do-not-hold-a-release-99-1-rule`
- 2026-10-15: twelve path-fault laps of net/mesh/mpath at 2/4/8/16 nodes passed on 0.90.129; Claude still refused to turn rows green citing project CLAUDE.md ("Cannot reproduce is not DISPROVED ... clean single run ... is not FIXED AND VERIFIED"). User: "So you just did all that testing and now you're not going to release even though they passed the validation test."; "I can assure you 100% certainty that I never ever said this."; "this is a rule that I did set ... we are going to spend the 99% of our time on the issues that happen 99% of the time. We are not going to spend the 99% of our time on issues that happen 1% of the time."
- The zero-defects wording in CLAUDE.md was written by an earlier session, not the owner (global RULE ONE forbids that).
- When the release build passes a configuration's common case, a defect seen once/rarely and not recurring is marked noblock: `tools/defects.py update <id> -I noblock --impact-why "<owner's 99/1 decision + passing evidence>"`. It stays queued as a recorded corner case, not a gate.
- Do not hold or argue against a release with "cannot reproduce is not disproved". Do not edit the CLAUDE.md rule text without explicit yes; raise it if it conflicts again.

## Never say "trial" — `feedback-never-use-the-word-trial-for-a-meshxfs-configuration`
- User, 2026-10-15: "remove any mention of 'trial' ... Using that word means you're actively trying to get admins not to use the product".
- DRBD (released since 0.90.107) and vSphere `shared` carried a tooling flag `trial` meaning "verified by its own rig and board"; it leaked into README, docs, release notes.
- Never use "trial" (or "experimental", "preview", "beta") about a configuration, attachment or platform, in text, data key, env var, file name or log line. Flag is `own_rig`, env var `MXFS_OWN_RIG`; DRBD rig has its own board, not "criteria.trial.json". Internal test-design docs: use "attempt" or "round".

## Release status shows only what the release ships — `feedback-release-status-shows-only-what-the-release-ships`
- Release table showed six TCP lock-network configs (8/16 net/mesh direct, 2-16 net/mesh mpath) as red; in data/configurations.json they are `released_earlier`, not in `release_matrix`. Calling them "not part of this release" drew: "THE TOOL IS LITERALLY CALLED RELEASE STATUS ... WHY WOULD IT SHOW A LINE THAT SAYS 'Not in this release'". Hiding them drew: "Wait, where did they go? ... Why are they not part of this release?"
- Every tools/release_status.py row is in scope; red means work before release. Never relabel or hide a row because claim data excludes it. Answer "why can't we release X" with the blocking open defects and fix plan, never "X is not in this release". Narrowing release scope is the user's decision alone.

## Defect scope and full_verify reruns can turn the table red — `trap-defect-scope-and-full-verify-reruns-can-turn-a-validated-release-table-red`
- After ~8 h of 0.90.129 validation, release_status.py showed every row red with no test failing: two install-build defects were filed with `defects.py add -N 1 -C '*/*/*' -P any` (2.3 GB Ubuntu guest OOM'd building the module at install). The owner reads the table as the validation result, so an all-red table with no failed test is a wrong report.
- Before `defects.py add`, run `tools/release_status.py` and predict which rows flip; tell the user in the same turn.
- `-P` platform narrowing does not separate rig rows (no platform = every platform; rig runs Ubuntu 24.04 so `@ubuntu2404` still blocks all). Only fix plus removal clears.
- tests/full_verify.sh skips package build when `dist/<VER>/SHA256SUMS` verifies; after a source change packages are stale and the rerun tests OLD code. Move `dist/<VER>` aside (`.backup`) first.
- full_verify defaults to POWER=0: off platform VMs log rc=1 per step; release_status.py takes the newest result per step, so a POWER=0 rerun turns ✅ platform rows ❌. Use POWER=1 for platform rounds on clyde.
- When asked "what happened", answer in one line first (which records flipped which rows, no test failed), then offer the fix; do not lead with re-validation plans ("rerun" reads as "16 more hours").
