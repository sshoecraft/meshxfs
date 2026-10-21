---
name: compiled-release-publication-rig-measurement-and-packaging-lessons
description: Assorted: rig sync before power cut, measure defect reach, withdraw corrupt releases, no team voice, packaging triggers/claims, orphan-adopt and TCP…
metadata:
  type: feedback
tags: [compiled, release, rig, packaging, public-text, ledger, orphan-scan]
---

Assorted group (kind: assorted, the clusterer could not fit a single topic). Common thread: things that made a measurement, a public statement or a shipped artifact wrong in MXFS/MeshXFS around 0.90.130-0.90.132. Organised by area.

## Rig measurement (tests, A/B laps)

### Sync before any power cut; assert the arm's precondition after boot `trap-unsynced-install-before-a-power-cut-reverts-to-the-old-program`
Measured twice on 2026-10-21 (drbd_rig.sh promoter-test):
1. Lap 7 of tests/queues/drbd_promoter_ab.queue: the control arm copied the pre-fix /usr/sbin/mxfs-drbd-fence-self onto both nodes with `cat > f.new && chmod && mv f.new f` at 22:16:05; the pair outage `virsh destroy`ed both 2 s later. After the boot test2 ran the FIXED program (it printed the fix's new log line), so the "control" lap measured the fix.
2. Lap 3 of drbdprom4: `sed -i` added `become-primary-on both` to /etc/drbd.d/mxfs.res at 22:43:22 (drbdadm dump showed it), the outage came 34 s later, and after the boot the file was the old one (mtime 03:40, the earlier `up`), so the promoter under test never existed.

A change can be lost at a power cut well past ext4's 5 s journal commit: plan for "anything since the last explicit sync".
- Before any power cut a test inflicts (virsh destroy, sysrq b, a fence), run `sync` on the nodes, once, right before it.
- After the boot, assert what the arm depends on before measuring: sha256 of the installed program, the config line in `drbdadm dump`. Die on mismatch. A control arm that silently ran the fix, or a promoter arm with no promoter, is vacuous evidence that reads like a result.
- A lap whose edit and power cut were separated by a long setup (~70 s of Pacemaker setup) happened to be safe, which is why the bug showed only in the fast arms.

### Delayed-work use-after-free A/B: arm the delay past the capture, read the serial console `technique-delayed-work-uaf-ab-arm-delay-past-capture-read-serial-console`
For a control arm expected to run a delayed work on freed memory (D-FAILED-MOUNT-LEAVES-DESTAGE-AND-ALLOCLIST-RETRY-WORK-QUEUED-PAST-FREE, tests/reap_inactive_mount_ab.sh MODE=failkick):
- With the injected delay (KICK_MS) at 3 s, the node oopsed and panicked before the harness's dmesg capture 6 s after the mount, so the lap ABORTed at stage=capture with no instrument line (lap rfka).
- Arm the delay LONGER than the capture (KICK_MS=20000, SETTLE_S=6): the control's dmesg holds the instrument line (P-MOUNT-FREE-WORK-PENDING at 475.42) before the work fires, and the oops lands 20.3 s later (lap rfkb). Cause and consequence both on record.
- The guest's own console keeps the oops: /var/log/libvirt/qemu/<node>-serial.log, mode 600 root. `sudo -n tail -c N` works on clyde (plain tail gets Permission denied). Guest console runs loglevel=3, so pr_warn instrument lines are NOT on it, but BUG/Oops/panic are.
- Power-cycle the node after such a control (scripts/lab_power.sh down/up); otherwise it panics with 'Rebooting in 25 seconds' and comes back on its own mid-next-lap.

### Measure a defect's reach before widening it or saying it publicly `feedback-measure-a-defects-reach-before-widening-it-or-saying-it-publicly`
Owner, 2026-10-20, on seeing tools/release_status.py mark every single-path and DRBD row "Not ready" from a record named ...NETMESH-MPATH-FENCED-RETURN...: "WTF DO THESE HAVE TO DO WITH MPATH ... you are screwing your reputation online".

What happened: a corruption was found after a fenced-return lap on 2/net/mesh/mpath. Reading the code (the orphan scan is called from transport-independent recovery paths), the record's -C was widened to */*/* and the public README advisory said "it is not specific to one lock manager" — both before any measurement off mpath. The reach turned out real (a directed control lap reproduced it on 2/net/mesh/direct and 2/disk/caw/direct), but at the time of widening it was an inference presented as fact, and the record's name still said NETMESH-MPATH, so the table read as nonsense.
- Reach in a record comes from a run on that configuration. When code says a path is generic, run the directed test on the other attach/lock-manager configurations FIRST (a 2-node control lap costs ~4 min per group, groups in parallel), then widen with the run's evidence in -w.
- Public advisory text states only what was measured ("reproduced on X and Y"), never a code-reading conclusion about reach.
- If the measured reach outgrows a record's id (e.g. NETMESH-MPATH in the name but it hits disk/caw/direct), say so in the summary's first words so the release table is not misread.

## Release publication and public text

### A release found corrupt after publish is withdrawn, not advised around `feedback-a-release-found-corrupt-after-publish-is-withdrawn-not-advised-around`
Owner, 2026-10-21, on an advisory that told 0.90.131 users "test data only, backups, run chk_mxfs, fix ships next release": "that is no way to build confidence in humans who already do not trust you ... better to remove the release than have it out there causing issues ... most humans ARE NOT ok with 'i found something after the release' ... they dont trust anything after that". And: "another problem with 'test data only' is that people will fixate on those words and consider the product to be experimental and for test data only - even after you fix it".

For a measured integrity defect in a PUBLISHED release (precedents: Debian halted 12.3 over ext4 corruption and went to 12.4; Hyperledger Besu removes binaries of a data-corruption release and keeps the tag; OpenZFS 2.2.0 -> quick 2.2.1/2.2.2; trust-repair research, Kim/Ferrin/Cooper/Dirks 2004: a competence failure is repaired by owning it, hiding turns it into an integrity failure; voluntary recalls raise trust, contested ones lose it):
- Withdraw at once: `gh release delete-asset` the packages (keep SHA256SUMS for audit), retitle "MeshXFS <V> — WITHDRAWN: <one-line cause>", `--prerelease --latest=false`, make the previous release Latest with a note at its top ("stay on it until <next> is published").
- Do NOT delete the release or the tag: that reads as hiding evidence and breaks links.
- Notice text (README top + withdrawn page): plain facts of what was found and how it shows in chk_mxfs, that it was found after publishing, own the process failure in one sentence, what users on <V> and on the previous release should do, and that the fix ships only after full verification. No defensiveness, no AI talk, no marketing.
- NEVER write "test data only", "for testing only", "not for production" (or equivalent) about the product, in an advisory or anywhere public: readers keep it as the product's label after the fix. tools/release_text_check.py now refuses those phrases (STALE list). For an opt-in feature, say precisely what is true ("outside every released configuration: no release has verified it").
- Process failure behind it: 0.90.131 was published BEFORE its kept-log verification runs on the shipped build finished; those runs found the bug. Never publish until every check on the exact build has finished — the public notice now promises this.
- Supersedes the "advisory on found bugs" rule (compiled-release-authority-chain-integrity-and-public-advisories) for integrity defects in a published release: withdrawal, not an advisory.

### Public text never implies a team `feedback-public-text-never-implies-a-team`
Owner correction (2026-10-21, GitHub issues #2/#3 replies): "you make it sound like a team ... its just you (and astra and gpt gemini)".
- There is no MeshXFS team. The code and replies are Claude's, with other models consulted on hard problems (README "written entirely by AI").
- In GitHub issue comments (project CLAUDE.md: "Never talk in the third person in a GitHub issue: no we, us, our"), and by the same reasoning in release notes, forum posts and README text: never "we're fixing", "we'll report back", "our side".
- What worked: impersonal phrasing about the product and release: "MeshXFS refuses ...", "the next release makes MeshXFS ...", "whether X triggers it is being checked", "updates will be posted here". Do not switch to "I" either: comments post from the owner's GitHub account, and "I" would speak as the owner (no invented owner persona).
- Before posting, grep the draft: `grep -n -iwE "we|us|our|we.re|we.ll" draft.md`.

## Packaging

### Packaged text is fixed before the boards decide the claims `trap-packaged-text-fixed-before-boards-decide-claims`
`tests/release_verify_chain.sh` runs the boards, then `full_verify` packages,platforms. The packages carry `docs/man/man5/mxfs.5` and `packaging/mxfs-modprobe.conf`. Which configurations a release can claim is only known once the boards finish (e.g. 0.90.131: 4/8/16 net/mesh failed on the release candidate and had to stay unclaimed). A packaged page saying "TCP released for two and four nodes" or "TCP on mpath last verified in 0.90.130" is wrong if claims change after the package step, and editing it means a new chain (an edit after the chain's build step breaks "verified build = published build").
- Rule of thumb: packaged pages name no per-version claim. They say both transports are released "at two to sixteen nodes" (the text check requires the largest size to be named) and point at the README for which configurations and which version verified each. README and data/configurations.json are not packaged and can be edited after the chain.
- Related chain traps fixed in 0.90.131 (session 832bf9ad): board lanes started together tripped each other's host preflight on SCST login bursts (fixed: board_4node_chain.sh waits for the previous lane's prep line); bench/README.md must be regenerated from the boards before the package step or release.sh's text check refuses to build (fixed: chain step "bench page").

### pve-manager upgrade wipes the index.html.tpl injection; needs a dpkg trigger `trap-pve-manager-upgrade-replaces-index-html-tpl-needs-dpkg-trigger`
pve-storage-mxfs adds MXFS to Datacenter -> Storage -> Add by inserting a script tag into /usr/share/pve-manager/index.html.tpl from postinst. That file belongs to pve-manager; every pve-manager install/upgrade lays down a fresh copy, so the entry silently disappears after the next `apt full-upgrade` and nothing errors.
- Measured 2026-10-20 on pve92-1 (PVE 9.2 ISO, pve-manager 9.2.2): the 0.90.130 packages put the tag in; full-upgrade to pve-manager 9.2.21 removed it from the template and from the page pveproxy serves (tests/evidence/pve92_gui_tag s1/s2). A Proxmox forum tester hit exactly this.
- Fix: DEBIAN/triggers with `interest-noawait <path>` on the foreign file; dpkg then runs our postinst with `triggered` after any package installs that path, and the idempotent injection puts it back (packaging/mkdeb_pve.sh). Verified with `apt-get install --reinstall pve-manager`: 'Processing triggers for pve-storage-mxfs' ran and the tag stayed.
- Any time MXFS packaging edits a file it does not own (another package's template, config, unit), add a file trigger and test it by reinstalling the owning package, not only a fresh install. An ISO-fresh lab node is NOT what a user runs; update it to the current point release before claiming anything (9.2 ISO storage APIVER was 14, updated 9.2.21 is 16).

## Kernel-module defects

### In-core nlink on a poisoned dead-incarnation shell is the dead file's, not the platter's `trap-in-core-mode-nlink-on-a-poisoned-dead-incarnation-shell-is-the-dead-files-not-the-platters`
Since 0.90.131, reload poisons an unexposed shell whose platter names another incarnation (incarn_poison_unexposed=1) instead of adopting the platter in place. The poisoned shell KEEPS the dead incarnation's in-core state: VFS i_mode, i_nlink, i_generation.

Bit us: mxfs_orphan_scan (xfs/xfs_mxfs_join.c) collected a zombie from an unlocked platter read, the peer freed it, the iget returned this node's cached shell of that number (nlink 0 from an earlier fstat), the reload under ILOCK EX poisoned it, and the adopt's re-verify `VFS_I(ip)->i_mode == 0 || i_nlink != 0` passed on the dead shell. xfs_iunlink stamped a FREE inode onto the AGI bucket (cold chk: "unlinked bucket N: member ... has a FREE core"). Fixed 0.90.132 by orphan_adopt_platter_verify (re-read the dinode under the adopt's locks: mode set, nlink 0, di_gen == in-core gen, and not MXFS_IF_INCARN_STALE / i_mxfs_dead_incarn_gen).
- Any code doing iget -> lock -> "check in-core state" -> destructive/structural action (iunlink, free, adopt, reap) must also test MXFS_IF_INCARN_STALE / i_mxfs_dead_incarn_gen or re-read the platter.
- Repro: tests/orphan_adopt_dead_incarn_ab.sh (B remounts, A holds f open, B opens f, A unlinks, B fstats+closes, scan parked by dbg_orphan_scan_hold_ms, A closes).

### TCP ledger: wait-for-room is a hang unless something makes room `trap-tcp-ledger-wait-for-room-is-a-hang-unless-something-makes-room`
A TCP-ledger page holds 31 records and hash v2 routes inodes in shards of 8 (MXFS_TAUTH_INO_SHARD), so four busy shards fill a page. At 20-40k live grants over ~10k pages a few full pages are statistically EXPECTED.
- A record leaves a page only when its holder RELEASES the grant, and holders keep grants cached indefinitely. Any "wait for room" (dl_capacity_wait_local, the remote MXFS_ERR_LEDGER_FULL re-ask, cap park) is a hang unless something asks holders to give records up.
- 0.90.131 turned the EDQUOT shutdown into exactly that wait; on 2/net/mesh/mpath (run 20261020T142123Z-g2d) a truncating open waited without end on a page full of the survivor's OWN idle EX grants, and the join freeze for the rejoining peer hung behind it (freeze_super waits for the writer), failing the rejoin mount. Fix: dl_capacity_reclaim — on -EDQUOT, DEMAND-BAST the holders of the page's 8 oldest records (dlm_txn_commit -> dlm_capacity_reclaim).
- Read a full page: `tools/tauth_page_auth.py <dev> --page <P> --entries` on a node (the P-TAUTH-PAGE-FULL line names the page).
- Passing B0D2 laps did not show this: they never met a page that STAYED full during a join. Grade a capacity change on whether a page that stays full ever empties, not on lap pass counts.
