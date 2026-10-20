#!/bin/bash
# tests/noino_gen0_ab.sh — same-build A/B of the no-inode release's
# generation-0 guard (module knob noino_gen0_guard), for
# D-NETMESH-LIVE-FILE-INODE-FREED-UNDER-ITS-NAME-AFTER-NUMBER-REUSE.
#
# H-N2, written before the instrument: a peer's BAST for an inode this node no
# longer has in core, arriving when the node holds no granted entry for it,
# captures rel_gen 0 (xfs/xfs_mxfs_bast.c, noino_rel_gen); the queued release
# runs only after its drain fence and then releases with expected_gen 0,
# which on TCP takes the first granted entry whatever its generation
# (dlm/dlm.c dlm_unlock_tenure).  When the node has meanwhile reused the
# number for a create and been granted it, that create's grant is released
# while the create still depends on it, and a peer can take the inode: the
# record's shape (a name whose inode is free on disk, or one number named
# twice).  PREDICTION IF TRUE: with the guard off, P-NOINO-GEN0-LIVE fires
# (noino_gen0_live > 0: a generation-0 release met a generation-bearing grant
# when it ran).  IF FALSE: generation-0 releases run (noino_gen0_releases > 0)
# and none ever meets a grant (noino_gen0_live == 0 across the laps).
#
# THE WORKLOAD, both directions at once in two directories: one node churns
# create+unlink of the same 32 names, so its inode numbers are reused within
# a chunk every few ms; the other stats and touches those names and drops its
# caches between rounds, so its lookups BAST the churner for numbers the
# churner may already have released and is about to reuse
# (tests/incarn_reuse_lookup_stress.sh's shape, run symmetrically).
#
# THE GRADES
#   VACUOUS   no generation-0 release ran on either node: the path was not
#             exercised, and the lap measured nothing
#   guard=0   the control: reports live (did the hazard occur) and the cold
#             audit; RESULT CONTROL-REACHED when live > 0, CONTROL-NOT-REACHED
#             when live == 0
#   guard=1   PASS when every generation-0 release that met a grant on TCP was
#             refused (refused == live on each node), the cold audit is CLEAN,
#             and neither node shut down, withdrew, or logged BUG/Oops/hung task
#
# THE WINDOW.  On the rig a generation-0 release's live check and its unlock
# are microseconds apart, and 43 such releases in the first A/B never met a
# grant made between them.  NG0_DELAY_MS sets the test knob
# dbg_noino_release_delay_ms on both nodes for the workload (read back, then
# set to 0 again before the cold audit): every generation-0 release waits that
# long between the two, so a create that reuses the number can be granted
# inside the window.  Both arms of one A/B use the same delay.
#
# Budgets (derived): the prep and the cold audit are run.sh rows under their
# own manifest budgets (run.sh flips an overrun to FAIL itself, so no outer
# timeout); the workload SECS on each node, bounded SECS+60; evidence 40 s per
# node.
#
# THE SAME WORKLOAD, A SECOND A/B (D-FREED-INODE-HOME-NEVER-PUBLISHED-LIVE-
# CORE-AFTER-CLEAN-UNMOUNT).  The lookup node's touch makes it the last closer
# of a file the churner unlinked, so it frees the life itself; the churner's
# own inactivation then gets EX after that free.  NG0_INACT_GUARD sets the
# module knob inact_local_epoch_guard on both nodes (unset = the module
# default, 1): 1 sends a local-unlink inactivation whose grant was lost since
# the unlink to the platter, 0 is the same-build control that trusts the
# in-core image as before.  Each node reports the reach counters
# (inact_local_epoch_moved: the trigger happened; inact_local_peerfreed: the
# platter held the peer's free or reuse), the P-INACT-LOCAL-EPOCH verdicts,
# and nl_staged: P219 writes staged AND written at NL, the shape of the write
# that put the corrupted core back in ng0rf1.  The cold audit is the verdict.
#
# THE H-F7 INSTRUMENT (same record; egc2's corrupting write was the lookup
# node's touch, logged ~80 ms after the churner freed the life and written
# home).  NG0_MIRROR_CHECK=1 turns on dbg_log_mirror_check for the workload
# and reports, per node, the three counters of that hypothesis:
# recycle_keep_noino (a recycle kept a cached grant while a no-inode release of
# the number was in flight), noino_unlock_left_grant (such a release unlocked
# while an in-core inode cached a grant; lifecycle=LIVE is the hazard), and
# log_mirror_phantom (a regular file logged at a cached EX the DLM does not
# record), plus noino_unlock_undrained: a no-inode release unlocked while the
# in-core inode of the number (corpse included) still held committed changes
# not yet on the platter -- what a recycle that kept the grant can leave behind
# the release's drain fence.  It needs a build carrying those knobs.
# The same knob turns on the write side: logwr_dlm_nogrant counts logged live
# cores written home while the DLM recorded no EX of this node for the inode
# (P-LOGWR-DLM-NOGRANT; TCP only), the shape of both corrupting writes traced
# so far.  In a CORRUPT lap every stream line naming each audited inode is kept
# as <node>_audited_inos.txt.
#
# THE H-F7 FIX, same build.  NG0_RECYCLE_GUARD sets the module knob
# noino_recycle_guard on both nodes (unset = the module default, 1): 1 resets a
# recycled corpse's cached grant while a no-inode release of the number may be
# in flight (recycle_reset_noino) and re-drives a BAST whose corpse entered a
# recycle before its release was registered (noino_recycle_redrive); 0 is the
# same-build control that keeps the grant.  Its reach is those two counters,
# and its hazard counters (recycle_keep_noino, noino_unlock_undrained) must read
# 0 under it.
#
# THE H-F8 FIX, same build (the same record; every corrupt lap with a readable
# log had the lookup node keep a CLEAN shell of the audited life over the
# platter's FREE image at a protective reload, P5F pin=0 ili_fields=0x0, on
# the reload's own fresh grant).  NG0_FRESHSRC_GUARD sets the module knob
# freshsrc_keep_guard on both nodes (unset = the module default, 1): 1 keeps a
# FREE fresh image out only for a shell with committed changes not yet on the
# platter, 0 is the same-build control that also keeps it on a held grant.
# Each node reports freshsrc_keep_clean (the hazard: a clean shell kept on the
# grant alone) and freshsrc_clean_refused (the guard's reach), and its P5F
# lines are kept as <node>_p5f.txt.  Under the guard a lap PASSes only with
# keep_clean 0.
#
# THE H-F14 FIX, same build (D-FREED's lfn1: a shell poisoned because the
# platter held a newer incarnation was recycled from its P91-protected kept
# cluster buffer, whose bytes still held the dead one, so the recycle kept it
# and the retried unlink freed the number under the live file).
# NG0_RECYCLE_SIDEREAD sets the module knob recycle_stale_sideread on every
# node (unset = the module default, 1): 1 judges such a recycle by a platter
# side-read, 0 is the same-build control that judges the kept buffer.  The
# side-read runs in both settings; recycle_sideread_disagree counts the
# recycles whose kept buffer and platter disagree, and their P-RECYCLE-SIDEREAD
# lines (with the gate, poison and protect lines around them) are kept as
# <node>_rsr.txt.  Its reach (rs_live_reuse) is the lfn1 shape: the kept
# buffer holds the in-core generation and the platter a different live one.
# Verdict line SRESULT: no reach SVACUOUS; control SCONTROL-SHOWS-CAUSE when the
# audit names P-FREE-LIVE-CORE, else SCONTROL-NO-CORRUPTION; fix SPASS with a
# clean audit and no node failure, else SFAIL.
#
# THE H-IU1 FIX, same build (D-IUNLINK-PREV-OF-PEER-FREED-INODE-STALE-PRECOMMIT-
# SHUTDOWN: fn32's free of a mid-list member of a peer's unlinked bucket dropped
# the AG DLM to take its predecessor's EX hold, the owner freed that
# predecessor in the gap, and the retried remove edited the free inode's next
# pointer, so the precommit check shut the filesystem down).
# NG0_UNLPREV_VERIFY sets the module knob unlprev_held_verify on every node
# (unset = the module default, 1): 1 checks under the hold that the predecessor
# is still a live unlinked inode naming the freed one and starts the free over
# when it is not, 0 is the same-build control that edits it as before.  The
# check and its count (unlprev_held_moved, P-UNLPREV-MOVED) run in both
# settings; unlprev_rebuilds counts the frees started over.
# NG0_UNLPREV_DELAY_MS sets the test knob dbg_unlprev_wait_delay_ms (read back,
# then 0 again before the cold audit): such a free sleeps that long, holding
# nothing, between dropping the AG DLM and asking for the predecessor's hold.
# The lines are kept as <node>_unlprev.txt.  Verdict line URESULT: no
# unlprev_held_moved on any node UVACUOUS; control UCONTROL-SHOWS-CAUSE when a
# P53-IUNLINK-MISMATCH names an inode that a P-UNLPREV-MOVED line of the same
# node named as the held predecessor, else UCONTROL-NO-MISMATCH; fix UPASS with
# no P53 mismatch, no node failure and a clean audit, else UFAIL.
#
# THE H-RS1 FIX, same build (D-INODE-CLUSTER-PUBLISH-WITHOUT-AUTHORITY: lfb2's
# inactivation re-logged an inode whose epoch-3 image had already landed, and
# a cluster write mxfsaild started for other slots carried the buffer's old
# image of it, in a release-flush/demoter context the stale-stage masks leave
# alone, over the peer's newer image).  NG0_RS1_SKIP sets the module knob
# stale_stage_skip_landed on every node (unset = the module default, 1): 1
# masks a dead-tenure logged slot whose image already landed from such writes,
# 0 is the same-build control that writes it.  stale_stage_rf_landed counts
# the slots found in both settings (P-RS1-LANDED-SKIP).  Needs NG0_IWR_WHOLE=1,
# whose clobber check prints the regressions it is graded by.
# tools/rs1_regress_attribution.py attributes every partial-path regression
# (P-DINO-CLOBBER path=partial) to the line that preceded it for the same slot
# (rs1.txt).  Verdict line RRESULT: no stale_stage_rf_landed on any node
# RVACUOUS; control RCONTROL-SHOWS-CAUSE when a regression follows a
# P-RS1-LANDED-SKIP line for its slot, else RCONTROL-NO-REGRESS; fix RPASS with
# no regression of that shape (rs1, landed_unseen), no node failure and a
# clean audit, else RFAIL.  prevented= counts the slots a fix lap's mask kept
# off the platter while their image was behind it (P-DINO-CLOBBER-MASKED names
# the slot, a masked=1 P-RS1-LANDED-SKIP line for it precedes): each is a
# regression the control would have written.
#
# THE H-FA1 FIX, same build (D-FREED-IMAGE-ADOPT-KEEPS-DEAD-LIFE-CORE-FIELDS-
# REGRESSES-FREE-DINODE: a reload that adopts a peer's free dinode into a live
# in-core inode takes only its generation and mode, so the freed life's link
# count and older change count ride the slot's next copy-in home, a free
# dinode reading nlink 1 about five change counts behind the platter's).
# NG0_FREE_ADOPT_CORE sets the module knob free_adopt_core on every node (unset
# = the module default, 1): 1 takes the core fields from the free dinode, 0 is
# the same-build control that keeps the freed life's.  free_adopt_core_diff
# counts the adopts whose core differed in both settings (P-FREE-ADOPT-CORE,
# applied=0|1).  Needs NG0_IWR_WHOLE=1, whose clobber check prints the
# regressions it is graded by.  tools/free_adopt_attribution.py attributes
# every free-image regression (P-DINO-CLOBBER path=partial, disk and mem mode
# 0) to the latest P-FREE-ADOPT-CORE line for the same inode on the same node
# (fa1.txt).  Verdict line ARESULT: no free_adopt_core_diff on any node
# AVACUOUS; control ACONTROL-SHOWS-CAUSE when a free-image regression follows
# an applied=0 line for its inode, else ACONTROL-NO-REGRESS; fix APASS with no
# free-image regression after an adopt line (fa1, fa1_applied), no node
# failure and a clean audit, else AFAIL.  free_unattributed (a free-image
# regression no adopt line preceded) is reported in both arms: it is not this
# shape, and a fix lap showing one says the class has another writer.
#
# THE H-IFD1 FIX, same build (D-IFREE-DEFER-UNLANDED-FATAL-SHUTDOWN-BEHIND-
# LOCKED-CLUSTER-BUFFER: a deferred free's 200 ms drain ran out while xfsaild
# was writing the cluster buffer that carried its state, and the fail-closed
# arm shut the node down, ifd2).  NG0_IFREE_EXTEND sets the module knob
# ifree_defer_extend on every node (unset = the module default, 1): 1 keeps
# draining without a bound when the bound runs out with the cached mode not EX,
# 0 is the same-build control that fails closed at the bound.
# ifree_defer_extended counts the drains whose bound ran out that way in both
# settings (P-IFREE-DEFER-EXTENDED, landed=0|1).  The lines are kept as
# <node>_ifext.txt.  Verdict line ERESULT: no ifree_defer_extended on any node
# EVACUOUS; control ECONTROL-SHOWS-CAUSE when a P-IFREE-DEFER-UNLANDED-FATAL
# follows, else ECONTROL-NO-FATAL; fix EPASS when every extended drain landed
# (landed=1 on every P-IFREE-DEFER-EXTENDED line), no fatal, no node failure
# and a clean audit, else EFAIL.  NG0_IFREE_BOUND_MS sets the test knob
# dbg_ifree_defer_bound_ms on every node for the workload (read back, then 0
# again before the cold audit): the deferred free's drain bound in place of
# ifree_drain_ms's 200 ms, so the arm is met in most laps (about one drain in
# six takes 50 ms or more on 2/disk/caw/mpath, one in ninety over 200 ms).
#
# THE H-CG1 FIX, same build (D-CREATE-REUSE-OVER-MID-TEARDOWN-SHELL-IGRAB-FAIL-
# DIRTY-CANCEL-SHUTDOWN: a create took a number whose stale linked copy was
# being evicted, the igrab of that copy failed, the free-state check called
# the copy's live mode corruption and the create cancelled a dirty
# transaction, rsd11).  NG0_CR63_IGRAB_RETRY sets the module knob
# cr63_igrab_retry on every node (unset = the module default, 1): 1 looks
# again once the teardown is done, 0 is the same-build control that falls
# through to the check.  cr63_igrab_fail counts the failed igrabs in both
# settings, cr63_igrab_retried the retries.  The lines are kept as
# <node>_cg1.txt.  Verdict line GRESULT: no cr63_igrab_fail on any node
# GVACUOUS; control GCONTROL-SHOWS-CAUSE when the free-state check or a
# create's cancel names a number a retry=0 P-CR63-IGRAB-FAIL named, else
# GCONTROL-NO-CANCEL; fix GPASS when every failed igrab was retried, no
# create cancelled, every retried create lookup ended rc=0, no node failure
# and a clean audit, else GFAIL.  NG0_EVICT_STALE_DELAY_MS sets the test knob
# dbg_evict_stale_delay_ms on every node for the workload (read back, then 0
# again before the cold audit): a stale linked copy's eviction is held that
# long after clear_inode, one at a time and at most one start a second, so a
# create that takes the number meets the teardown at its igrab.
#
# THE H-UB1 FIX, same build (D-INODE-CLUSTER-PUBLISH-WITHOUT-AUTHORITY: a
# partial cluster write carried a logged slot this node never copied in, with
# the buffer's older read of it, over a peer's landed free, rk5).
# NG0_UB1_SKIP sets the module knob unstaged_logged_skip on every node (unset
# = the module default, 1): 1 masks such a slot, 0 is the same-build control
# that writes it.  unstaged_logged_found counts the slots in both settings
# (P-UB1-UNSTAGED-SKIP); with the clobber check on (NG0_IWR_WHOLE=1, needed)
# unstaged_logged_prevented counts those masked while the platter was ahead
# of the buffer, unstaged_logged_regressed those written while it was.  The
# lines are kept as <node>_ub1.txt.  Verdict line BRESULT: no
# unstaged_logged_found on any node BVACUOUS; control BCONTROL-SHOWS-CAUSE
# when unstaged_logged_regressed > 0, else BCONTROL-NO-REGRESS; fix BPASS when
# none regressed, no node failure and a clean audit (prevented is reported:
# above 0 the mask stopped a write that would have regressed), else BFAIL.
#
# THE H-NR1 FIX, same build (D-INODE-CLUSTER-PUBLISH-WITHOUT-AUTHORITY, fw3c3:
# a no-inode release unlocked the grant a reclaimable corpse still cached; a
# create re-took the grant and reused the corpse with its dead tenure's epoch,
# and a partial cluster write carried the previous life's staged image over a
# peer's newer one).  NG0_NR1_HONOR sets the module knob
# noino_release_mark_honor on every node (unset = the module default, 1): 1
# makes the recycle that finds the release's mark end the cached tenure, 0 is
# the same-build control that keeps it.  noino_release_marked counts the marks
# and recycle_released_reset/_kept the recycles that consumed one, by setting;
# logwr_relmark_written counts slots a cluster write carried with bytes copied
# in before such a recycle (P-LOGWR-RELMARK-WRITTEN), in both settings; with
# the clobber check on (NG0_IWR_WHOLE=1, needed) logwr_relmark_regressed counts
# those written while the platter held a newer image.  The lines are kept as
# <node>_nr1.txt.  Verdict line NRESULT: no marked recycle on any node
# NVACUOUS; control NCONTROL-SHOWS-CAUSE when logwr_relmark_regressed > 0,
# else NCONTROL-NO-REGRESS; fix NPASS when no recycle kept a marked tenure, no
# P-LOGWR-RELMARK-WRITTEN line reads staged=1, none regressed, no node failure
# and a clean audit, else NFAIL.  NG0_RECLAIM_HOLD=1 sets the test knob
# dbg_reclaim_hold on every node for the workload (read back before and after
# it, then 0 again before the cold audit): background and shrinker reclaim
# skip every inode, so an evicted or freed inode stays a reclaimable shell
# that the next lookup or create of its number recycles, which is the window
# the shape needs (without it nra1 recycled 1 of 78 marked copies); the
# unmount still reclaims.
#
# THE H-F7 WINDOW, HELD OPEN (the same record; kdf2's corrupting write was the
# lookup node's touch, committed through a recycled corpse's kept grant after
# the no-inode release's drain fence and written home 46 ms after the peer
# freed the inode).  On the rig that window is microseconds wide and the A/B
# met it about once in twenty laps.  NG0_POSTFENCE_MS sets the test knob
# dbg_noino_postfence_delay_ms on both nodes for the workload (read back, then
# set to 0 again before the cold audit): every no-inode release waits that
# long after its fence, just before it publishes and unlocks.  With it set the
# lap measures H-F7, so its vacuity gate is H-F7's reach instead of the
# generation-0 releases: a control lap (NG0_RECYCLE_GUARD=0) must count a kept
# grant (recycle_keep_noino > 0), a fix lap a reset one (recycle_reset_noino >
# 0); NG0_MIRROR_CHECK=1 is required.  In a CORRUPT lap each audited inode is
# attributed: the P-NOINO-UNLOCK-UNDRAINED, P5F keep and NL-staged P219 lines
# that name it, per node.
#
# THE H-F8b FIX, same build (the same record; kdc3's nlink-0 audited core was
# the lookup node's dead shell, kept by the reload's P116 self-clobber guard on
# the held grant alone -- pin=0 ili_fields=0x0 held=1, disk generation
# unrelated -- then truncated by its inactivation, whose ifree was skipped as
# peer-freed).  NG0_SELFCLOBBER_GUARD sets the module knob
# selfclobber_keep_guard on both nodes (unset = the module default, 1): 1
# adopts the freed image for a clean held shell, 0 is the same-build control
# that keeps it.  Each node reports selfclobber_keep_clean (the hazard) and
# selfclobber_clean_refused (the reach), and its P116 lines are kept as
# <node>_p116.txt.  Under the guard a lap PASSes only with keep_clean 0.
#
# THE H-F8b WINDOW, HELD OPEN.  In kdc3 the lookup node's touch reached the
# number only after the churner had freed it, reallocated it and freed it
# again (the touch's iget waited 3.4 s behind the shell's first inactivation),
# so the disk generation was unrelated to the shell's and the zombie arm's
# gen+1 test missed it.  A churn round is ~230 ms (kdc3: 1194-1403 rounds in
# 300 s).  NG0_SETATTR_DELAY_MS sets the test knob dbg_setattr_time_delay_ms
# on both nodes for the workload (read back, then 0 again before the cold
# audit): the lookup loop's `touch -c` sleeps that long after its lookup and
# before its first lock, so the number can turn over twice before the touch's
# EX reload decides on the shell.  With it set the lap measures H-F8b, so its
# vacuity gate is H-F8b's reach: a control lap (NG0_SELFCLOBBER_GUARD=0) must
# count a clean held keep (selfclobber_keep_clean > 0), a fix lap a refusal
# (selfclobber_clean_refused > 0); NG0_SELFCLOBBER_GUARD must be set.
#
# THE H-F7c FIX, same build (the same record; on the H-F7 fix arm with the
# window held open, pmf1 and pdf1 each released a number at the generation its
# BAST anchored while a NEW life of that number, created after the release
# began, was live at cached EX with logged changes not on the platter: the
# allocator's probe is answered from the anchored grant by the DLM's
# already-granted shortcut, which mints no generation).  NG0_RESV_GUARD sets
# the module knob noino_resv_guard on both nodes (unset = the module default,
# 1): 1 skips a number whose no-inode release is in flight, 0 is the same-build
# control that takes it.  Each node reports dialloc_resv_under_noino (the
# hazard: a candidate reserved or taken with the release in flight) and
# dialloc_resv_noino_skipped (the reach).  It needs NG0_POSTFENCE_MS (the
# window) and NG0_MIRROR_CHECK=1 (the undrained count that is the verdict);
# with it set the lap's vacuity gate is H-F7c's reach: a control lap must count
# a hazard, a fix lap a skip.
#
# THE H-F9 FIX, same build (the same record; with NG0_SETATTR_DELAY_MS=500 five
# of six H-F8b laps audited CORRUPT, and in smc1 each audited core was the
# lookup node's touch logged at an EX the DLM no longer recorded: the node's
# in-core inode had adopted the churner's free on a reload (mode 0), a peer's
# BAST then found it refused by the in-core lookup, classified LIVE, and served
# by the no-inode release, which unlocked the grant the shell still cached; a
# lookup of the number's next life resurrected the shell with that mode).
# NG0_SHELL_GUARD sets the module knob noino_shell_guard on both nodes (unset =
# the module default, 1): 1 serves such a BAST through the in-core release, 0
# is the same-build control that sends it to the no-inode release.  Each node
# reports noino_live_shell (the hazard: a BAST that met such a shell) and
# noino_shell_routed (the reach), and its P-NOINO-LIVE-SHELL lines are kept in
# <node>_hf7.txt.  It needs NG0_SETATTR_DELAY_MS (the window) and
# NG0_MIRROR_CHECK=1 (the phantom and no-grant counts that are the verdict);
# with it set the lap's vacuity gate is H-F9's reach: a control lap must count
# a hazard, a fix lap a routed BAST.  A fix lap passes only if every hazard was
# routed (a shell the grab missed went to the no-inode release after all).
#
# THE H-F10 FIX, same build (the same record; on the H-F9 fix laps zmf1 and
# zmf4 a new file logged changes at no grant while a publish drain for an
# unrelated directory had taken it off the unpublished list and its claim was
# still in flight: a file whose parent is not yet recorded is in every drain's
# scope, so its real parent's or its AG's release can go to the peer, name and
# all, while the file is neither unpublished nor granted).
# NG0_PUBCLAIM_GUARD sets the module knob pub_claim_release_guard on both nodes
# (unset = the module default, 1): 1 holds a directory or AG release until the
# claims in its scope return, 0 is the same-build control that lets it go.
# Each node reports pub_claim_inflight_rel (the hazard: a release that went
# with a claim in its scope in flight) and pub_claim_rel_waited (the reach),
# and its P-PUB-CLAIM-INFLIGHT-AT-RELEASE lines are kept in <node>_hf7.txt;
# the phantom and no-grant lines are split by pub_inflight= (1: logged or
# written while a claim was in flight).  NG0_PUBCLAIM_DELAY_MS sets the test
# knob dbg_pub_claim_delay_ms (read back, then 0 again before the cold audit):
# a drain waits that long between taking an inode and claiming it, which holds
# the window open.  It needs NG0_MIRROR_CHECK=1; with it set the lap's vacuity
# gate is H-F10's reach: a control lap must count a hazard, a fix lap a wait.
# A fix lap passes only with pub_claim_inflight_rel 0 (a release that waited
# out the drain bound and went anyway counts there).
# NG0_PUBCLAIM_WRITE_GUARD sets the module knob pub_claim_write_guard on both
# nodes (unset = the module default, 1): 1 keeps the live core of an inode
# whose publish claim is in flight out of a cluster write until the claim
# lands, 0 is the same-build control that writes it.  Each node reports
# pub_claim_write_masked (the reach) and its P-PUB-CLAIM-WRITE-MASKED lines
# are kept in <node>_hf7.txt; the hazard is a P-LOGWR-DLM-NOGRANT line with
# pub_inflight=1.  It needs NG0_PUBCLAIM_GUARD; with it set the lap's vacuity
# gate is the write side's reach (a control lap must write such a core, a fix
# lap must mask one) and a fix lap passes only with no such line.
# NG0_P55C_RESTORE sets the module knob p55c_home_restore on both nodes (unset
# = the module default, 1): 1 puts a free's cluster slot that holds this node's
# unlanded staged image back to the platter's bytes before P55C classifies on
# them, 0 is the same-build control that leaves the staged bytes (H-F11).
# Each node reports p55c_home_restored (the reach); its P55C-HOME-PLATTER,
# P55C-HOME-RESTORED and P-DIALLOC-DISKLIVE lines are kept in <node>_p55c.txt.
# Every lap reports, from both nodes' streams, the H-F11 chain: a DISKLIVE whose
# number and generation a P55C-HOME-PLATTER named as the slot's staged image.
# With the knob set the lap's vacuity gate is H-F11's reach (a control lap
# must classify a live staged slot over a free platter, a fix lap must restore
# one) and a fix lap passes only with no chain.
#
#
# THE DIRTY-CORPSE WAIT, same build (D-RECYCLE-RESET-UNDER-NOINO-STRANDS-
# COMMITTED-DIR-CHANGE-WEDGE-SHUTDOWN; in fxdp2 a lookup recycled a directory's
# reclaimable corpse 3 ms after a peer's BAST was served by the no-inode release,
# and the H-F7 reset lowered the grant while the corpse still held a committed
# shrink: the aild skipped the inode at NL (P119-NONEX-FLUSH-SKIP), its log item
# left the AIL unwritten, the release's fence passed and the peer was granted a
# stale home; 60 s later the node shut down, P-INODE-WEDGE).  NG0_DIRTY_WAIT sets
# the module knob noino_recycle_dirty_wait on both nodes (unset = the module
# default, 1): 1 makes such a recycle wait for the release (recycle_dirty_waits,
# recycle_dirty_wait_rounds) or, when the release registered after the recycle
# began and is re-driven, keep the grant (recycle_dirty_kept); 0 is the
# same-build control that resets it (recycle_dirty_hazard counts the recycles
# that met the case, recycle_reset_dirty the resets of a dirty corpse).  The
# P-RECYCLE-DIRTY-*, P-RECYCLE-WAITED and P-RECYCLE-RESET-UNDER-NOINO lines, and
# the P119 / P383 / P228 / P-INODE-WEDGE lines that follow a reset, are kept in
# <node>_dirtywait.txt.  With it set the lap's vacuity gate is its reach: a
# control lap must count a hazard, a fix lap a wait or a keep.  A fix lap passes
# only with no reset of a dirty corpse the change covers (owes=1 at_start=0);
# resets with owes=1 at_start=1 (a create or a caller holding transaction
# items, which cannot wait) are reported as dw_uncovered.
#
# THE DEFERRED-FREE FIXES, same build (D-INACT-DEFERRED-FREE-LOSES-TRUNCATED-
# CORE-AND-REAP-AUTHORITY; in fzmp1 and the fzc laps every audited inode was a
# file whose inactivation truncated it and then deferred the free at the
# unlinked-list preflight: the truncated core never reached the platter, and
# nothing was left with the authority to finish the free).  NG0_IFREE_DRAIN sets
# the module knob ifree_defer_drain on both nodes (unset = the module default,
# 1): 1 lands the committed core before the grant goes, 0 is the same-build
# control.  NG0_IFREE_REAP sets ifree_defer_reap (unset = 1): 1 records the reap
# entry that carries the freer's authority, 0 is the control.  Each node reports
# ifree_defer_dirty (deferred frees leaving with state not at home: the reach in
# both arms), ifree_defer_drained, ifree_defer_unlanded (a node that failed
# closed) and ifree_defer_reaps, and tools/ifree_defer_attribution.py grades
# the cold audit against both nodes' streams (<OUT>/ifdefer.txt): the audited
# inodes (bucket members and fork-ownership errors) a deferral names.  With
# either knob set the lap's vacuity gate is the deferrals' reach (a lap with
# none measured nothing); a lap passes only with no fork-ownership error under
# ifree_defer_drain, no unlanded drain, and no bucket member under
# ifree_defer_reap.  The audit's own log is kept as chk_audit.log in every lap.
#
# THE REAPER'S FAILED LOOKUPS, same build (H-3 of the same record: in fwcm3 the
# reap worker's own walk reloaded six zombies and released them, its lookup of
# each then failed -ENOENT while the in-core inode was queued for inactivation,
# and it retired their entries as freed; the queued inactivation ran without
# the entry's authority and skipped, so all six were still on their bucket
# after the clean unmount).  NG0_REAP_KEEP sets reap_transient_keep on both
# nodes (unset = the module default, 1; needs NG0_IFREE_DRAIN or
# NG0_IFREE_REAP): 1 keeps such an entry for the worker's next pass, 0 is the
# same-build control, which retires it.  Each node reports reap_iget_transient
# (those failures, both arms: the reach) and reap_iget_retired (entries retired
# on a failed lookup), and tools/ifree_defer_attribution.py counts the
# P88-REAP-IGET-FAIL lines and marks each audited zombie whose entry a transient
# failure retired.  Under reap_transient_keep 1 a lap fails if any transient
# failure retired its entry.
#
# D-FREED-INODE-HOME-NEVER-PUBLISHED-LIVE-CORE-AFTER-CLEAN-UNMOUNT, H-F12 (an AG
# release's prepass publish drain chased the children its own node kept
# creating in that AG and ran out its 5000 ms window; fw3f2).  NG0_DRAIN_BOUND
# sets pub_drain_bound on every node (unset = the module default, 1): 1 bounds
# an AG release's drain to the entries listed when it began, 0 is the
# same-build control, the open scan.  Each node reports pub_drain_bound_left
# (newer in-scope entries a bounded drain left listed), and every lap counts,
# from each node's whole kernel log after the mark, the drain timeouts of AG
# releases (dt_ag) and of directory releases (dt_dir), the P-PUB-DRAIN-STUCK
# lines of AG drains whose worker was on its child less than 1000 ms (a chase)
# or at least 2500 ms (a held wait), and the P-PUB-DRAIN-BOUND lines.
# With NG0_DRAIN_BOUND set, each node also reports pub_unlock_exposed and
# pub_unlock_listed, and every lap counts the P-PUB-UNPUB-AT-UNLOCK lines of AG
# releases (an AG unlock with an unpublished inode of that AG still listed or
# its claim in flight): ux_unlocks lines at site=ag-bast, and over them the
# sums ux_listed, ux_unlinked (of the listed, already unlinked) and
# ux_inflight; ux_unmount counts the lines at site=unmount.
# NG0_LOOKUP_HOLD_MS (default unset = 0) makes each node's lookup loop also hold
# each file of the peer's directory open that long after its stat: when the
# churner removes a file the peer holds, the peer becomes its last closer and
# frees it, which asks the churner for its churn AG while it is creating in it
# (every file is allocated in its creator's own AG, so without this a peer
# asks for that AG about once a lap).  Measured: it does not (brc1-brc2: the
# churner received one AG BAST a lap); NG0_PEER_UNLINK below is built to.
# NG0_PEER_UNLINK (default 0) runs a feed beside the churn: the churner creates
# that many files, at an even pace over the workload, in a directory of their
# own that the churn never locks, and the peer removes each as it appears.  A
# file created while the churn runs is allocated in the AG the churn is
# creating in, and each remove takes that inode's AG lock for its unlinked-list
# insert (xfs_iunlink), so it asks the churner for the AG while its churn goes
# on creating there; the remove locks only the feed's directory.  Files made
# before the mark do not do this: the node's allocator moves between its AGs,
# so 300 files created in a directory of their own landed in AG 6 while the
# churn allocated in AG 12 (ifc1, the nodes' P82-ADD lines), and 300 created in
# the churn directory itself landed in AGs 12 and 8 while the churn then
# allocated in AG 6 (ixc1); the churner received 3-8 AG BASTs in each such lap.
# The RESULT line reports punl, punl_created, punl_removed and agbast_a, the AG
# BASTs the churner received after the mark.
# NG0_IALLOC_FENCE (0|1, default unset; needs NG0_DRAIN_BOUND) sets
# ag_ialloc_fence on every node (D-FREED's H-F13: no inode allocation in an AG
# while a peer's BAST is pending on it, and no release COMMIT while an
# unpublished inode of it is listed or claiming, within MXFS_PUB_DRAIN_TIMEOUT_MS
# of the BAST) and reports fn_refused, fn_held, fn_escaped (its counters) and
# fn_escape_lines (P-AG-FENCE-ESCAPE after the mark), and from every node's
# stream after the mark stale_hints (P12-STALE-HINT: a BAST hint pending on an
# AG this node held nothing of, dropped at a fresh grant), sweep_lines and
# sweep_max (P-DIALLOC-SWEEP-RETRY, the create sweep's contention backoff, and
# the highest sweep count one printed: jwf1's stall reached 976).
# NG0_FENCE_HINT_EXEMPT (0|1, default unset; needs NG0_IALLOC_FENCE) sets
# ag_fence_hint_exempt on every node (H-F13b: a BAST pending on an AG this
# node holds no tenure of does not fence allocation in it) and reports
# fh_passed and fh_refused (its counters).
# NG0_CR63_DEFER (0|1, default unset) sets cr63_linked_defer on every node
# (D-CREATE-REUSE-OVER-PEER-FREED-LINKED-CORPSE-SHUTS-NODE-DOWN's H-L1: a create
# that finds a reclaimable copy of its number still linked defers the
# free-state check to the recycle path's platter re-read) and grades a line of
# its own, CRESULT, printed before the deferred-free attribution, which ABORTs
# a lap with no audit: cr_deferred and cr_refused (its counters, summed over
# the nodes), and from every node's stream after the mark cr_fall
# (P-CR63-DEADSHELL, the fall-through), cr_cancel (P-CR3-CANCEL) and
# cr_disklive (P-CR63-DEFER-DISKLIVE).  Its grades:
#   CVACUOUS              defer 0 with cr_fall 0, or defer 1 with cr_deferred 0
#   CCONTROL-SHOWS-CAUSE  defer 0, a fall-through, a cancel and a node failure
#   CCONTROL-NO-SHUTDOWN  defer 0, a fall-through and no shutdown through it
#   CPASS                 defer 1, reached, cr_refused, cr_fall, cr_cancel and
#                         cr_disklive 0, no node failure, audit CLEAN
#   CFAIL                 defer 1, reached, anything else
# NG0_RELFLUSH_AUDIT (0|1, default unset) sets relflush_through_audit on every
# node (D-NETMESH-LIVE-FILE-INODE-FREED-UNDER-ITS-NAME-AFTER-NUMBER-REUSE's
# H-RT1: an EX directory release keeps its RELFLUSH token through the
# late-dirent audit, until just before the unlock) and reports rt_kept and
# rt_skip_demoting (relflush_audit_kept and nl_dir_skip_demoting, summed over
# the nodes: releases that kept the token, and logged directory slots a cluster
# write dropped at NL while their inode was in a release drain), and from every
# node's stream after the mark rt_p56_dem_lines (P56-NL-LOGGED-DIR-SKIP with
# state=3), rt_p57 (P57-PREUNLOCK-DIRTY), rt_refuse_older
# (P3-REFUSE-OLDER-DISK) and rt_readd (P-SFM-READD-ALWAYS with peer_mod=0); the
# lines are kept in <node>_relflush.txt.  The P56 and P57 lines are
# ratelimited, so the counters are the measure and the lines the evidence.
# NG0_IWR_WHOLE (0|1, default unset) sets dino_clobber_check on every node
# (the same record's H-WW1 instrument: every inode-cluster write is read back
# against the platter first and P-DINO-CLOBBER names a submitted image behind
# it, path=whole or partial) and reports ww_early, ww_noskip, ww_empty and
# ww_declined (iwr_whole_early/noskip/empty/declined summed over the nodes:
# cluster writes sent whole, by the bail that sent them), and from every
# node's stream after the mark ww_clobber_whole_dir / ww_clobber_partial_dir
# (P-DINO-CLOBBER lines whose regressed slot is a directory, by path),
# ww_probe (P-IWR-WHOLE lines, by why= in <node>_iwr.txt) and ww_dirahead_behind
# / ww_dirahead_ahead (P-CLMERGE-DIRAHEAD whose buffer changecount is below /
# above the platter's, same generation); the lines are kept in <node>_iwr.txt.
# NG0_IWR_REFUSE (0|1, default unset; needs NG0_IWR_WHOLE=1) sets
# iwr_refuse_empty on every node (the H-WW1 fix: a cluster write whose every
# sector the per-slot rules skipped, with no passenger skip, completes with no
# I/O instead of going out whole; 0 is the same-build control), reports iwref
# and ww_refused (iwr_empty_refused summed over the nodes) and ww_recov_refused
# (P218-RECOV-REFUSED lines in the streams, kept in <node>_iwr.txt), and prints
# its own verdict, WRESULT: C arm WCONTROL-SHOWS-CAUSE (a whole-path directory
# clobber), WCONTROL-NO-CLOBBER (whole writes of the empty case, no directory
# clobber) or WVACUOUS (no empty-case whole write); F arm WPASS (refusals, no
# empty-case or declined whole write, no directory clobber by either path, no
# recovery-owned refusal, a CLEAN audit and no node failure), WVACUOUS (no
# refusal) or WFAIL.
#
# A CORRUPT cold audit or a node failure outranks every vacuity gate: such a lap
# is graded, never reported VACUOUS.
#
# Every lap counts node failures (shutdown, withdraw, self-fence, wedge, BUG,
# Oops, hung task) from each node's whole kernel log after the lap's mark,
# <node>_dmesg_stream.gz, as well as from the ring read after the workload: the
# ring wraps under this workload, and fxdp2's shutdown was in the stream only.
#
# Usage: tests/noino_gen0_ab.sh <label> <guard 0|1> [secs=120] [config=2/net/mesh/direct] [group=g2]
# Env:   NG0_DELAY_MS (default 0), NG0_INACT_GUARD (0|1, default unset),
#        NG0_MIRROR_CHECK (0|1, default 0), NG0_RECYCLE_GUARD (0|1, default unset),
#        NG0_FRESHSRC_GUARD (0|1, default unset), NG0_POSTFENCE_MS (default unset),
#        NG0_SELFCLOBBER_GUARD (0|1, default unset), NG0_SETATTR_DELAY_MS (default unset),
#        NG0_RESV_GUARD (0|1, default unset), NG0_SHELL_GUARD (0|1, default unset),
#        NG0_PUBCLAIM_GUARD (0|1, default unset), NG0_PUBCLAIM_DELAY_MS (default unset),
#        NG0_CREATE_PARENT_DELAY_MS (default unset: test knob dbg_create_parent_delay_ms,
#        a regular-file create held that long while its new inode is unpublished
#        with no parent recorded, the window a drain of another directory takes it
#        in; read back, reset to 0 before the cold audit; needs NG0_PUBCLAIM_GUARD),
#        NG0_PUBCLAIM_WRITE_GUARD (0|1, default unset; needs NG0_PUBCLAIM_GUARD),
#        NG0_P55C_RESTORE (0|1, default unset), NG0_DIRTY_WAIT (0|1, default unset),
#        NG0_IFREE_DRAIN (0|1, default unset), NG0_IFREE_REAP (0|1, default unset),
#        NG0_REAP_KEEP (0|1, default unset; needs NG0_IFREE_DRAIN or NG0_IFREE_REAP),
#        NG0_DRAIN_BOUND (0|1, default unset), NG0_LOOKUP_HOLD_MS (default 0),
#        NG0_PEER_UNLINK (default 0), NG0_IALLOC_FENCE (0|1, default unset),
#        NG0_FENCE_HINT_EXEMPT (0|1, default unset; needs NG0_IALLOC_FENCE),
#        NG0_CR63_DEFER (0|1, default unset), NG0_RELFLUSH_AUDIT (0|1, default unset),
#        NG0_IWR_WHOLE (0|1, default unset), NG0_IWR_REFUSE (0|1, default unset;
#        needs NG0_IWR_WHOLE=1), NG0_RECYCLE_SIDEREAD (0|1, default unset),
#        NG0_UNLPREV_VERIFY (0|1, default unset), NG0_UNLPREV_DELAY_MS (default
#        unset; needs NG0_UNLPREV_VERIFY), NG0_RS1_SKIP (0|1, default unset;
#        needs NG0_IWR_WHOLE=1), NG0_FREE_ADOPT_CORE (0|1, default unset;
#        needs NG0_IWR_WHOLE=1), NG0_IFREE_EXTEND (0|1, default unset),
#        NG0_IFREE_BOUND_MS (default unset; needs NG0_IFREE_EXTEND)
# Exit 0 PASS / CONTROL-*, 1 FAIL, 2 ABORT, 3 VACUOUS.
set -u
LABEL=${1:?label}; GUARD=${2:?guard 0|1}; SECS=${3:-120}
CONFIG=${4:-2/net/mesh/direct}; GROUP=${5:-g2}
DELAY_MS=${NG0_DELAY_MS:-0}
IGUARD=${NG0_INACT_GUARD:-}
MCHECK=${NG0_MIRROR_CHECK:-0}
RGUARD=${NG0_RECYCLE_GUARD:-}
FGUARD=${NG0_FRESHSRC_GUARD:-}
PFENCE=${NG0_POSTFENCE_MS:-}
SGUARD=${NG0_SELFCLOBBER_GUARD:-}
case "$SGUARD" in ''|0|1) ;; *) echo "NG0_SELFCLOBBER_GUARD must be 0 or 1"; exit 2 ;; esac
HGUARD=${NG0_SHELL_GUARD:-}
case "$HGUARD" in ''|0|1) ;; *) echo "NG0_SHELL_GUARD must be 0 or 1"; exit 2 ;; esac
SADELAY=${NG0_SETATTR_DELAY_MS:-}
case "$SADELAY" in '') ;; *[!0-9]*) echo "NG0_SETATTR_DELAY_MS must be a number of ms"; exit 2 ;; esac
[ -z "$SADELAY" ] || [ -n "$SGUARD" ] || [ -n "$HGUARD" ] || { echo "NG0_SETATTR_DELAY_MS needs NG0_SELFCLOBBER_GUARD or NG0_SHELL_GUARD (its reach counters)"; exit 2; }
[ -z "$HGUARD" ] || [ -n "$SADELAY" ] || { echo "NG0_SHELL_GUARD needs NG0_SETATTR_DELAY_MS (the window it is measured in)"; exit 2; }
[ -z "$HGUARD" ] || [ "${NG0_MIRROR_CHECK:-0}" = 1 ] || { echo "NG0_SHELL_GUARD needs NG0_MIRROR_CHECK=1 (its verdict counters)"; exit 2; }
[ -z "$SADELAY" ] || [ -z "${NG0_POSTFENCE_MS:-}" ] || { echo "NG0_SETATTR_DELAY_MS and NG0_POSTFENCE_MS each set a lap's vacuity gate; set one"; exit 2; }
case "$PFENCE" in '') ;; *[!0-9]*) echo "NG0_POSTFENCE_MS must be a number of ms"; exit 2 ;; esac
[ -z "$PFENCE" ] || [ "${NG0_MIRROR_CHECK:-0}" = 1 ] || { echo "NG0_POSTFENCE_MS needs NG0_MIRROR_CHECK=1 (its reach counters)"; exit 2; }
VGUARD=${NG0_RESV_GUARD:-}
case "$VGUARD" in ''|0|1) ;; *) echo "NG0_RESV_GUARD must be 0 or 1"; exit 2 ;; esac
[ -z "$VGUARD" ] || [ -n "$PFENCE" ] || { echo "NG0_RESV_GUARD needs NG0_POSTFENCE_MS (the window it is measured in)"; exit 2; }
CGUARD=${NG0_PUBCLAIM_GUARD:-}
case "$CGUARD" in ''|0|1) ;; *) echo "NG0_PUBCLAIM_GUARD must be 0 or 1"; exit 2 ;; esac
CDELAY=${NG0_PUBCLAIM_DELAY_MS:-}
case "$CDELAY" in '') ;; *[!0-9]*) echo "NG0_PUBCLAIM_DELAY_MS must be a number of ms"; exit 2 ;; esac
[ -z "$CDELAY" ] || [ -n "$CGUARD" ] || { echo "NG0_PUBCLAIM_DELAY_MS needs NG0_PUBCLAIM_GUARD (its reach counters)"; exit 2; }
[ -z "$CGUARD" ] || [ "${NG0_MIRROR_CHECK:-0}" = 1 ] || { echo "NG0_PUBCLAIM_GUARD needs NG0_MIRROR_CHECK=1 (the phantom and no-grant lines it splits)"; exit 2; }
PDELAY=${NG0_CREATE_PARENT_DELAY_MS:-}
case "$PDELAY" in '') ;; *[!0-9]*) echo "NG0_CREATE_PARENT_DELAY_MS must be a number of ms"; exit 2 ;; esac
[ -z "$PDELAY" ] || [ -n "$CGUARD" ] || { echo "NG0_CREATE_PARENT_DELAY_MS needs NG0_PUBCLAIM_GUARD (its reach counters)"; exit 2; }
WGUARD=${NG0_PUBCLAIM_WRITE_GUARD:-}
case "$WGUARD" in ''|0|1) ;; *) echo "NG0_PUBCLAIM_WRITE_GUARD must be 0 or 1"; exit 2 ;; esac
[ -z "$WGUARD" ] || [ -n "$CGUARD" ] || { echo "NG0_PUBCLAIM_WRITE_GUARD needs NG0_PUBCLAIM_GUARD (the pub_inflight split of the no-grant lines)"; exit 2; }
XGUARD=${NG0_P55C_RESTORE:-}
case "$XGUARD" in ''|0|1) ;; *) echo "NG0_P55C_RESTORE must be 0 or 1"; exit 2 ;; esac
DWAIT=${NG0_DIRTY_WAIT:-}
case "$DWAIT" in ''|0|1) ;; *) echo "NG0_DIRTY_WAIT must be 0 or 1"; exit 2 ;; esac
IDRAIN=${NG0_IFREE_DRAIN:-}
case "$IDRAIN" in ''|0|1) ;; *) echo "NG0_IFREE_DRAIN must be 0 or 1"; exit 2 ;; esac
IREAP=${NG0_IFREE_REAP:-}
case "$IREAP" in ''|0|1) ;; *) echo "NG0_IFREE_REAP must be 0 or 1"; exit 2 ;; esac
RKEEP=${NG0_REAP_KEEP:-}
case "$RKEEP" in ''|0|1) ;; *) echo "NG0_REAP_KEEP must be 0 or 1"; exit 2 ;; esac
[ -z "$RKEEP" ] || [ -n "$IDRAIN$IREAP" ] || { echo "NG0_REAP_KEEP needs NG0_IFREE_DRAIN or NG0_IFREE_REAP (the deferred-free grading)"; exit 2; }
DBOUND=${NG0_DRAIN_BOUND:-}
case "$DBOUND" in ''|0|1) ;; *) echo "NG0_DRAIN_BOUND must be 0 or 1"; exit 2 ;; esac
LHOLD=${NG0_LOOKUP_HOLD_MS:-0}
case "$LHOLD" in ''|*[!0-9]*) echo "NG0_LOOKUP_HOLD_MS must be a whole number of ms"; exit 2 ;; esac
LHOLD_S=$(awk -v m="$LHOLD" 'BEGIN { printf "%.3f", m / 1000 }')
IFENCE=${NG0_IALLOC_FENCE:-}
case "$IFENCE" in ''|0|1) ;; *) echo "NG0_IALLOC_FENCE must be 0 or 1"; exit 2 ;; esac
[ -z "$IFENCE" ] || [ -n "$DBOUND" ] || { echo "NG0_IALLOC_FENCE needs NG0_DRAIN_BOUND (the drain and exposure census it is judged by)"; exit 2; }
FHEX=${NG0_FENCE_HINT_EXEMPT:-}
case "$FHEX" in ''|0|1) ;; *) echo "NG0_FENCE_HINT_EXEMPT must be 0 or 1"; exit 2 ;; esac
[ -z "$FHEX" ] || [ -n "$IFENCE" ] || { echo "NG0_FENCE_HINT_EXEMPT needs NG0_IALLOC_FENCE (the fence it qualifies)"; exit 2; }
CRDEF=${NG0_CR63_DEFER:-}
case "$CRDEF" in ''|0|1) ;; *) echo "NG0_CR63_DEFER must be 0 or 1"; exit 2 ;; esac
RTAUD=${NG0_RELFLUSH_AUDIT:-}
case "$RTAUD" in ''|0|1) ;; *) echo "NG0_RELFLUSH_AUDIT must be 0 or 1"; exit 2 ;; esac
IWW=${NG0_IWR_WHOLE:-}
case "$IWW" in ''|0|1) ;; *) echo "NG0_IWR_WHOLE must be 0 or 1"; exit 2 ;; esac
IWREF=${NG0_IWR_REFUSE:-}
case "$IWREF" in ''|0|1) ;; *) echo "NG0_IWR_REFUSE must be 0 or 1"; exit 2 ;; esac
[ -z "$IWREF" ] || [ "$IWW" = 1 ] || { echo "NG0_IWR_REFUSE needs NG0_IWR_WHOLE=1 (the clobber check and whole-write counters it is judged by)"; exit 2; }
RSR=${NG0_RECYCLE_SIDEREAD:-}
case "$RSR" in ''|0|1) ;; *) echo "NG0_RECYCLE_SIDEREAD must be 0 or 1"; exit 2 ;; esac
UPV=${NG0_UNLPREV_VERIFY:-}
case "$UPV" in ''|0|1) ;; *) echo "NG0_UNLPREV_VERIFY must be 0 or 1"; exit 2 ;; esac
UPD=${NG0_UNLPREV_DELAY_MS:-}
case "$UPD" in '') ;; *[!0-9]*) echo "NG0_UNLPREV_DELAY_MS must be a number of ms"; exit 2 ;; esac
[ -z "$UPD" ] || [ -n "$UPV" ] || { echo "NG0_UNLPREV_DELAY_MS needs NG0_UNLPREV_VERIFY (its reach counters)"; exit 2; }
RS1=${NG0_RS1_SKIP:-}
case "$RS1" in ''|0|1) ;; *) echo "NG0_RS1_SKIP must be 0 or 1"; exit 2 ;; esac
[ -z "$RS1" ] || [ "$IWW" = 1 ] || { echo "NG0_RS1_SKIP needs NG0_IWR_WHOLE=1 (the clobber check it is graded by)"; exit 2; }
FA1=${NG0_FREE_ADOPT_CORE:-}
case "$FA1" in ''|0|1) ;; *) echo "NG0_FREE_ADOPT_CORE must be 0 or 1"; exit 2 ;; esac
[ -z "$FA1" ] || [ "$IWW" = 1 ] || { echo "NG0_FREE_ADOPT_CORE needs NG0_IWR_WHOLE=1 (the clobber check it is graded by)"; exit 2; }
IFX=${NG0_IFREE_EXTEND:-}
case "$IFX" in ''|0|1) ;; *) echo "NG0_IFREE_EXTEND must be 0 or 1"; exit 2 ;; esac
IFB=${NG0_IFREE_BOUND_MS:-}
case "$IFB" in '') ;; *[!0-9]*) echo "NG0_IFREE_BOUND_MS must be a number of ms"; exit 2 ;; esac
[ -z "$IFB" ] || [ -n "$IFX" ] || { echo "NG0_IFREE_BOUND_MS needs NG0_IFREE_EXTEND (its reach counters)"; exit 2; }
CGR=${NG0_CR63_IGRAB_RETRY:-}
case "$CGR" in ''|0|1) ;; *) echo "NG0_CR63_IGRAB_RETRY must be 0 or 1"; exit 2 ;; esac
CGD=${NG0_EVICT_STALE_DELAY_MS:-}
case "$CGD" in '') ;; *[!0-9]*) echo "NG0_EVICT_STALE_DELAY_MS must be a number of ms"; exit 2 ;; esac
[ -z "$CGD" ] || [ -n "$CGR" ] || { echo "NG0_EVICT_STALE_DELAY_MS needs NG0_CR63_IGRAB_RETRY (its reach counters)"; exit 2; }
UB1=${NG0_UB1_SKIP:-}
case "$UB1" in ''|0|1) ;; *) echo "NG0_UB1_SKIP must be 0 or 1"; exit 2 ;; esac
[ -z "$UB1" ] || [ "$IWW" = 1 ] || { echo "NG0_UB1_SKIP needs NG0_IWR_WHOLE=1 (the clobber check it is graded by)"; exit 2; }
NR1=${NG0_NR1_HONOR:-}
case "$NR1" in ''|0|1) ;; *) echo "NG0_NR1_HONOR must be 0 or 1"; exit 2 ;; esac
[ -z "$NR1" ] || [ "$IWW" = 1 ] || { echo "NG0_NR1_HONOR needs NG0_IWR_WHOLE=1 (the clobber check it is graded by)"; exit 2; }
RHOLD=${NG0_RECLAIM_HOLD:-}
case "$RHOLD" in ''|0|1) ;; *) echo "NG0_RECLAIM_HOLD must be 0 or 1"; exit 2 ;; esac
PUNL=${NG0_PEER_UNLINK:-0}
case "$PUNL" in ''|*[!0-9]*) echo "NG0_PEER_UNLINK must be a whole number of files"; exit 2 ;; esac
case "$GUARD" in 0|1) ;; *) echo "guard must be 0 or 1"; exit 2 ;; esac
case "$RGUARD" in ''|0|1) ;; *) echo "NG0_RECYCLE_GUARD must be 0 or 1"; exit 2 ;; esac
case "$FGUARD" in ''|0|1) ;; *) echo "NG0_FRESHSRC_GUARD must be 0 or 1"; exit 2 ;; esac
case "$DELAY_MS" in ''|*[!0-9]*) echo "NG0_DELAY_MS must be a number of ms"; exit 2 ;; esac
case "$IGUARD" in ''|0|1) ;; *) echo "NG0_INACT_GUARD must be 0 or 1"; exit 2 ;; esac
case "$MCHECK" in 0|1) ;; *) echo "NG0_MIRROR_CHECK must be 0 or 1"; exit 2 ;; esac
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
read -r A B rest <<< "$(tools/mxfs_lab.sh group "$GROUP")"
[ -n "${A:-}" ] && [ -n "${B:-}" ] || { echo "RESULT: ABORT label=$LABEL -- group $GROUP has no two nodes"; exit 2; }
# the workload runs on A and B; every node of the group is mounted by the prep
# and takes part in the locking, so each one is held, marked, set to the lap's
# knobs, and has its counters and whole kernel log kept and graded
NODES="$A $B${rest:+ $rest}"
# run.sh holds the nodes only while it runs; between its calls the churn below
# is invisible to tools/vm_pool.sh, whose idle sweep would shut them off
. tests/lib/runlock.sh
vmhold_take "noino_gen0_ab $LABEL" $NODES \
    || { echo "RESULT: ABORT label=$LABEL -- could not hold $NODES"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_noino_gen0_$LABEL
mkdir -p "$OUT"
MARK="NOINO-GEN0-$LABEL-$$"
P=/sys/module/mxfs/parameters
CNTS="noino_gen0_releases noino_gen0_live noino_gen0_refused"
ICNTS="inact_local_epoch_moved inact_local_peerfreed"
HCNTS="recycle_keep_noino noino_unlock_left_grant log_mirror_phantom noino_unlock_undrained recycle_reset_noino noino_recycle_redrive logwr_dlm_nogrant"
FCNTS="freshsrc_keep_clean freshsrc_clean_refused"
SCNTS="selfclobber_keep_clean selfclobber_clean_refused"
VCNTS="dialloc_resv_under_noino dialloc_resv_noino_skipped"
ZCNTS="noino_live_shell noino_shell_routed"
CCNTS="pub_claim_inflight_rel pub_claim_rel_waited"
WCNTS="pub_claim_write_masked"
XCNTS="p55c_home_restored"
DCNTS="recycle_dirty_waits recycle_dirty_wait_rounds recycle_dirty_kept recycle_waited_reset recycle_dirty_hazard recycle_reset_dirty"
IFCNTS="ifree_defer_dirty ifree_defer_drained ifree_defer_unlanded ifree_defer_reaps"
RKCNTS="reap_iget_transient reap_iget_retired"
DBCNTS="pub_drain_bound_left pub_unlock_exposed pub_unlock_listed"
FNCNTS="ag_ialloc_fenced ag_fence_held ag_fence_escaped"
FHCNTS="ag_fence_hint_passed ag_fence_hint_refused"
CRCNTS="cr63_linked_deferred cr63_linked_refused"
RTCNTS="relflush_audit_kept nl_dir_skip_demoting"
IWCNTS="iwr_whole_early iwr_whole_noskip iwr_whole_empty iwr_whole_declined"
IRCNTS="iwr_empty_refused"
RSCNTS="recycle_sideread_disagree"
UPCNTS="unlprev_held_moved unlprev_rebuilds"
RLCNTS="stale_stage_rf_landed"
FACNTS="free_adopt_core_diff"
IXCNTS="ifree_defer_extended"
CGCNTS="cr63_igrab_fail cr63_igrab_retried dbg_evict_stale_delayed"
UBCNTS="unstaged_logged_found unstaged_logged_prevented unstaged_logged_regressed"
NRCNTS="noino_release_marked recycle_released_reset recycle_released_kept logwr_relmark_written logwr_relmark_regressed"
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
echo "=== noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS secs=$SECS $CONFIG $GROUP [$NODES] build=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 \
    || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }
# NG0_PEER_UNLINK: a directory of the feed's own, made before the lap's knobs
# and mark and read once by the peer; during the workload the churner creates
# the feed's files in it at an even pace beside its churn and the peer removes
# each as it appears
DA=/mnt/shared/ng0.$LABEL.a; DB=/mnt/shared/ng0.$LABEL.b
DV=/mnt/shared/ng0.$LABEL.v
if [ "$PUNL" -gt 0 ]; then
    got=$(rs 30 "$A" "mkdir -p $DV && sync && echo ok" | tail -1)
    [ "$got" = ok ] || { echo "RESULT: ABORT label=$LABEL stage=peer-unlink-mkdir evidence=$OUT"; exit 2; }
    got=$(rs 30 "$B" "stat $DV > /dev/null && echo ok" | tail -1)
    [ "$got" = ok ] || { echo "RESULT: ABORT label=$LABEL stage=peer-unlink-stat ($B could not stat $DV) evidence=$OUT"; exit 2; }
fi
want=$(modinfo -F srcversion mxfs.ko)
for n in $NODES; do
    sv=$(rs 20 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$sv" = "$want" ] || { echo "RESULT: ABORT label=$LABEL -- $n runs '$sv', not the tree build $want evidence=$OUT"; exit 2; }
    got=$(rs 20 "$n" "echo $GUARD > $P/noino_gen0_guard; echo $DELAY_MS > $P/dbg_noino_release_delay_ms; for c in $CNTS; do echo 0 > $P/\$c; done; echo $MARK > /dev/kmsg; echo \$(cat $P/noino_gen0_guard)/\$(cat $P/dbg_noino_release_delay_ms)" | tail -1)
    [ "$got" = "$GUARD/$DELAY_MS" ] || { echo "RESULT: ABORT label=$LABEL -- $n's noino_gen0_guard/dbg_noino_release_delay_ms read '$got', not $GUARD/$DELAY_MS (is the build missing a knob?) evidence=$OUT"; exit 2; }
    if [ -n "$IGUARD" ]; then
        got=$(rs 20 "$n" "echo $IGUARD > $P/inact_local_epoch_guard; for c in $ICNTS; do echo 0 > $P/\$c; done; cat $P/inact_local_epoch_guard" | tail -1)
        [ "$got" = "$IGUARD" ] || { echo "RESULT: ABORT label=$LABEL -- $n's inact_local_epoch_guard read '$got', not $IGUARD (is the build missing the knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$RGUARD" ]; then
        got=$(rs 20 "$n" "echo $RGUARD > $P/noino_recycle_guard; cat $P/noino_recycle_guard" | tail -1)
        [ "$got" = "$RGUARD" ] || { echo "RESULT: ABORT label=$LABEL -- $n's noino_recycle_guard read '$got', not $RGUARD (is the build missing the knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$FGUARD" ]; then
        got=$(rs 20 "$n" "echo $FGUARD > $P/freshsrc_keep_guard; for c in $FCNTS; do echo 0 > $P/\$c; done; cat $P/freshsrc_keep_guard" | tail -1)
        [ "$got" = "$FGUARD" ] || { echo "RESULT: ABORT label=$LABEL -- $n's freshsrc_keep_guard read '$got', not $FGUARD (is the build missing the H-F8 knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$SGUARD" ]; then
        got=$(rs 20 "$n" "echo $SGUARD > $P/selfclobber_keep_guard; for c in $SCNTS; do echo 0 > $P/\$c; done; cat $P/selfclobber_keep_guard" | tail -1)
        [ "$got" = "$SGUARD" ] || { echo "RESULT: ABORT label=$LABEL -- $n's selfclobber_keep_guard read '$got', not $SGUARD (is the build missing the H-F8b knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$VGUARD" ]; then
        got=$(rs 20 "$n" "echo $VGUARD > $P/noino_resv_guard; for c in $VCNTS; do echo 0 > $P/\$c; done; cat $P/noino_resv_guard" | tail -1)
        [ "$got" = "$VGUARD" ] || { echo "RESULT: ABORT label=$LABEL -- $n's noino_resv_guard read '$got', not $VGUARD (is the build missing the H-F7c knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$HGUARD" ]; then
        got=$(rs 20 "$n" "echo $HGUARD > $P/noino_shell_guard; for c in $ZCNTS; do echo 0 > $P/\$c; done; cat $P/noino_shell_guard" | tail -1)
        [ "$got" = "$HGUARD" ] || { echo "RESULT: ABORT label=$LABEL -- $n's noino_shell_guard read '$got', not $HGUARD (is the build missing the H-F9 knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$CGUARD" ]; then
        got=$(rs 20 "$n" "echo $CGUARD > $P/pub_claim_release_guard; for c in $CCNTS; do echo 0 > $P/\$c; done; cat $P/pub_claim_release_guard" | tail -1)
        [ "$got" = "$CGUARD" ] || { echo "RESULT: ABORT label=$LABEL -- $n's pub_claim_release_guard read '$got', not $CGUARD (is the build missing the H-F10 knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$WGUARD" ]; then
        got=$(rs 20 "$n" "echo $WGUARD > $P/pub_claim_write_guard; for c in $WCNTS; do echo 0 > $P/\$c; done; cat $P/pub_claim_write_guard" | tail -1)
        [ "$got" = "$WGUARD" ] || { echo "RESULT: ABORT label=$LABEL -- $n's pub_claim_write_guard read '$got', not $WGUARD (is the build missing the H-F10 write-side knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$XGUARD" ]; then
        got=$(rs 20 "$n" "echo $XGUARD > $P/p55c_home_restore; for c in $XCNTS; do echo 0 > $P/\$c; done; cat $P/p55c_home_restore" | tail -1)
        [ "$got" = "$XGUARD" ] || { echo "RESULT: ABORT label=$LABEL -- $n's p55c_home_restore read '$got', not $XGUARD (is the build missing the H-F11 knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$DWAIT" ]; then
        got=$(rs 20 "$n" "echo $DWAIT > $P/noino_recycle_dirty_wait; for c in $DCNTS; do echo 0 > $P/\$c; done; cat $P/noino_recycle_dirty_wait" | tail -1)
        [ "$got" = "$DWAIT" ] || { echo "RESULT: ABORT label=$LABEL -- $n's noino_recycle_dirty_wait read '$got', not $DWAIT (is the build missing the knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$IDRAIN$IREAP" ]; then
        got=$(rs 20 "$n" "${IDRAIN:+echo $IDRAIN > $P/ifree_defer_drain; }${IREAP:+echo $IREAP > $P/ifree_defer_reap; }for c in $IFCNTS; do echo 0 > $P/\$c; done; echo \$(cat $P/ifree_defer_drain)/\$(cat $P/ifree_defer_reap)" | tail -1)
        [ "$got" = "${IDRAIN:-1}/${IREAP:-1}" ] || { echo "RESULT: ABORT label=$LABEL -- $n's ifree_defer_drain/ifree_defer_reap read '$got', not ${IDRAIN:-1}/${IREAP:-1} (is the build missing the knobs?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$RKEEP" ]; then
        got=$(rs 20 "$n" "echo $RKEEP > $P/reap_transient_keep; for c in $RKCNTS; do echo 0 > $P/\$c; done; cat $P/reap_transient_keep" | tail -1)
        [ "$got" = "$RKEEP" ] || { echo "RESULT: ABORT label=$LABEL -- $n's reap_transient_keep read '$got', not $RKEEP (is the build missing the H-3 knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$DBOUND" ]; then
        got=$(rs 20 "$n" "echo $DBOUND > $P/pub_drain_bound; for c in $DBCNTS; do echo 0 > $P/\$c; done; cat $P/pub_drain_bound" | tail -1)
        [ "$got" = "$DBOUND" ] || { echo "RESULT: ABORT label=$LABEL -- $n's pub_drain_bound read '$got', not $DBOUND (is the build missing the H-F12 knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$IFENCE" ]; then
        got=$(rs 20 "$n" "echo $IFENCE > $P/ag_ialloc_fence; for c in $FNCNTS; do echo 0 > $P/\$c; done; cat $P/ag_ialloc_fence" | tail -1)
        [ "$got" = "$IFENCE" ] || { echo "RESULT: ABORT label=$LABEL -- $n's ag_ialloc_fence read '$got', not $IFENCE (is the build missing the H-F13 knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$FHEX" ]; then
        got=$(rs 20 "$n" "echo $FHEX > $P/ag_fence_hint_exempt; for c in $FHCNTS; do echo 0 > $P/\$c; done; echo \$(cat $P/ag_fence_hint_exempt)/\$(cat $P/ag_fence_hint_passed)/\$(cat $P/ag_fence_hint_refused)" | tail -1)
        [ "$got" = "$FHEX/0/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's ag_fence_hint_exempt and its counters read '$got', not $FHEX/0/0 (is the build missing the H-F13b knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$CRDEF" ]; then
        got=$(rs 20 "$n" "echo $CRDEF > $P/cr63_linked_defer; for c in $CRCNTS; do echo 0 > $P/\$c; done; echo \$(cat $P/cr63_linked_defer)/\$(cat $P/cr63_linked_deferred)/\$(cat $P/cr63_linked_refused)" | tail -1)
        [ "$got" = "$CRDEF/0/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's cr63_linked_defer and its counters read '$got', not $CRDEF/0/0 (is the build missing the H-L1 knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$RTAUD" ]; then
        got=$(rs 20 "$n" "echo $RTAUD > $P/relflush_through_audit; for c in $RTCNTS; do echo 0 > $P/\$c; done; echo \$(cat $P/relflush_through_audit)/\$(cat $P/relflush_audit_kept)/\$(cat $P/nl_dir_skip_demoting)" | tail -1)
        [ "$got" = "$RTAUD/0/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's relflush_through_audit and its counters read '$got', not $RTAUD/0/0 (is the build missing the H-RT1 knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$IWW" ]; then
        got=$(rs 20 "$n" "echo $IWW > $P/dino_clobber_check; for c in $IWCNTS; do echo 0 > $P/\$c; done; echo \$(cat $P/dino_clobber_check)/\$(cat $P/iwr_whole_early)/\$(cat $P/iwr_whole_noskip)/\$(cat $P/iwr_whole_empty)/\$(cat $P/iwr_whole_declined)" | tail -1)
        [ "$got" = "$IWW/0/0/0/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's dino_clobber_check and the iwr_whole counters read '$got', not $IWW/0/0/0/0 (is the build missing the H-WW1 instrument?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$IWREF" ]; then
        got=$(rs 20 "$n" "echo $IWREF > $P/iwr_refuse_empty; for c in $IRCNTS; do echo 0 > $P/\$c; done; echo \$(cat $P/iwr_refuse_empty)/\$(cat $P/iwr_empty_refused)" | tail -1)
        [ "$got" = "$IWREF/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's iwr_refuse_empty and iwr_empty_refused read '$got', not $IWREF/0 (is the build missing the H-WW1 fix?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$RSR" ]; then
        got=$(rs 20 "$n" "echo $RSR > $P/recycle_stale_sideread; for c in $RSCNTS; do echo 0 > $P/\$c; done; echo \$(cat $P/recycle_stale_sideread)/\$(cat $P/recycle_sideread_disagree)" | tail -1)
        [ "$got" = "$RSR/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's recycle_stale_sideread and recycle_sideread_disagree read '$got', not $RSR/0 (is the build missing the H-F14 knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$UPV" ]; then
        got=$(rs 20 "$n" "echo $UPV > $P/unlprev_held_verify; for c in $UPCNTS; do echo 0 > $P/\$c; done; echo \$(cat $P/unlprev_held_verify)/\$(cat $P/unlprev_held_moved)/\$(cat $P/unlprev_rebuilds)" | tail -1)
        [ "$got" = "$UPV/0/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's unlprev_held_verify and its counters read '$got', not $UPV/0/0 (is the build missing the H-IU1 fix?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$UPD" ]; then
        got=$(rs 20 "$n" "echo $UPD > $P/dbg_unlprev_wait_delay_ms; cat $P/dbg_unlprev_wait_delay_ms" | tail -1)
        [ "$got" = "$UPD" ] || { echo "RESULT: ABORT label=$LABEL -- $n's dbg_unlprev_wait_delay_ms read '$got', not $UPD (is the build missing the knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$RS1" ]; then
        got=$(rs 20 "$n" "echo $RS1 > $P/stale_stage_skip_landed; for c in $RLCNTS; do echo 0 > $P/\$c; done; echo \$(cat $P/stale_stage_skip_landed)/\$(cat $P/stale_stage_rf_landed)" | tail -1)
        [ "$got" = "$RS1/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's stale_stage_skip_landed and stale_stage_rf_landed read '$got', not $RS1/0 (is the build missing the H-RS1 fix?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$FA1" ]; then
        got=$(rs 20 "$n" "echo $FA1 > $P/free_adopt_core; for c in $FACNTS; do echo 0 > $P/\$c; done; echo \$(cat $P/free_adopt_core)/\$(cat $P/free_adopt_core_diff)" | tail -1)
        [ "$got" = "$FA1/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's free_adopt_core and free_adopt_core_diff read '$got', not $FA1/0 (is the build missing the H-FA1 fix?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$IFX" ]; then
        got=$(rs 20 "$n" "echo $IFX > $P/ifree_defer_extend; for c in $IXCNTS; do echo 0 > $P/\$c; done; echo \$(cat $P/ifree_defer_extend)/\$(cat $P/ifree_defer_extended)" | tail -1)
        [ "$got" = "$IFX/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's ifree_defer_extend and ifree_defer_extended read '$got', not $IFX/0 (is the build missing the H-IFD1 fix?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$IFB" ]; then
        got=$(rs 20 "$n" "echo $IFB > $P/dbg_ifree_defer_bound_ms; cat $P/dbg_ifree_defer_bound_ms" | tail -1)
        [ "$got" = "$IFB" ] || { echo "RESULT: ABORT label=$LABEL -- $n's dbg_ifree_defer_bound_ms read '$got', not $IFB (is the build missing the knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$CGR" ]; then
        got=$(rs 20 "$n" "echo $CGR > $P/cr63_igrab_retry; for c in $CGCNTS; do echo 0 > $P/\$c; done; echo \$(cat $P/cr63_igrab_retry)/\$(cat $P/cr63_igrab_fail)/\$(cat $P/cr63_igrab_retried)/\$(cat $P/dbg_evict_stale_delayed)" | tail -1)
        [ "$got" = "$CGR/0/0/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's cr63_igrab_retry and its counters read '$got', not $CGR/0/0/0 (is the build missing the H-CG1 fix?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$CGD" ]; then
        got=$(rs 20 "$n" "echo $CGD > $P/dbg_evict_stale_delay_ms; cat $P/dbg_evict_stale_delay_ms" | tail -1)
        [ "$got" = "$CGD" ] || { echo "RESULT: ABORT label=$LABEL -- $n's dbg_evict_stale_delay_ms read '$got', not $CGD (is the build missing the knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$UB1" ]; then
        got=$(rs 20 "$n" "echo $UB1 > $P/unstaged_logged_skip; for c in $UBCNTS; do echo 0 > $P/\$c; done; echo \$(cat $P/unstaged_logged_skip)/\$(cat $P/unstaged_logged_found)/\$(cat $P/unstaged_logged_prevented)/\$(cat $P/unstaged_logged_regressed)" | tail -1)
        [ "$got" = "$UB1/0/0/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's unstaged_logged_skip and its counters read '$got', not $UB1/0/0/0 (is the build missing the H-UB1 fix?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$NR1" ]; then
        got=$(rs 20 "$n" "echo $NR1 > $P/noino_release_mark_honor; for c in $NRCNTS; do echo 0 > $P/\$c; done; echo \$(cat $P/noino_release_mark_honor)/\$(cat $P/noino_release_marked)/\$(cat $P/recycle_released_reset)/\$(cat $P/recycle_released_kept)/\$(cat $P/logwr_relmark_written)/\$(cat $P/logwr_relmark_regressed)" | tail -1)
        [ "$got" = "$NR1/0/0/0/0/0" ] || { echo "RESULT: ABORT label=$LABEL -- $n's noino_release_mark_honor and its counters read '$got', not $NR1/0/0/0/0/0 (is the build missing the H-NR1 fix?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$RHOLD" ]; then
        got=$(rs 20 "$n" "echo $RHOLD > $P/dbg_reclaim_hold; cat $P/dbg_reclaim_hold" | tail -1)
        [ "$got" = "$RHOLD" ] || { echo "RESULT: ABORT label=$LABEL -- $n's dbg_reclaim_hold read '$got', not $RHOLD (is the build missing the knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$CDELAY" ]; then
        got=$(rs 20 "$n" "echo $CDELAY > $P/dbg_pub_claim_delay_ms; cat $P/dbg_pub_claim_delay_ms" | tail -1)
        [ "$got" = "$CDELAY" ] || { echo "RESULT: ABORT label=$LABEL -- $n's dbg_pub_claim_delay_ms read '$got', not $CDELAY (is the build missing the knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$PDELAY" ]; then
        got=$(rs 20 "$n" "echo $PDELAY > $P/dbg_create_parent_delay_ms; cat $P/dbg_create_parent_delay_ms" | tail -1)
        [ "$got" = "$PDELAY" ] || { echo "RESULT: ABORT label=$LABEL -- $n's dbg_create_parent_delay_ms read '$got', not $PDELAY (is the build missing the knob?) evidence=$OUT"; exit 2; }
    fi
    if [ "$MCHECK" = 1 ]; then
        got=$(rs 20 "$n" "echo 1 > $P/dbg_log_mirror_check; for c in $HCNTS; do echo 0 > $P/\$c; done; cat $P/dbg_log_mirror_check" | tail -1)
        [ "$got" = 1 ] || { echo "RESULT: ABORT label=$LABEL -- $n's dbg_log_mirror_check read '$got', not 1 (is the build missing the H-F7 instrument?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$PFENCE" ]; then
        got=$(rs 20 "$n" "echo $PFENCE > $P/dbg_noino_postfence_delay_ms; cat $P/dbg_noino_postfence_delay_ms" | tail -1)
        [ "$got" = "$PFENCE" ] || { echo "RESULT: ABORT label=$LABEL -- $n's dbg_noino_postfence_delay_ms read '$got', not $PFENCE (is the build missing the knob?) evidence=$OUT"; exit 2; }
    fi
    if [ -n "$SADELAY" ]; then
        got=$(rs 20 "$n" "echo $SADELAY > $P/dbg_setattr_time_delay_ms; cat $P/dbg_setattr_time_delay_ms" | tail -1)
        [ "$got" = "$SADELAY" ] || { echo "RESULT: ABORT label=$LABEL -- $n's dbg_setattr_time_delay_ms read '$got', not $SADELAY (is the build missing the knob?) evidence=$OUT"; exit 2; }
    fi
done
rs 30 "$A" "mkdir -p $DA $DB && sync && echo ok" | grep -q ok || { echo "RESULT: ABORT label=$LABEL stage=mkdir evidence=$OUT"; exit 2; }

churn() {   # <dir>
    cat <<EOF
end=\$((\$(date +%s) + $SECS)); r=0
while [ \$(date +%s) -lt \$end ]; do
    for i in \$(seq 0 31); do echo \$r > $1/f\$i; done
    for i in \$(seq 0 31); do rm -f $1/f\$i; done
    r=\$((r + 1))
done
echo "churn dir=$1 rounds=\$r"
EOF
}
lookup() {  # <dir>
    cat <<EOF
end=\$((\$(date +%s) + $SECS)); r=0
while [ \$(date +%s) -lt \$end ]; do
    for i in \$(seq 0 31); do
        stat $1/f\$i > /dev/null 2>&1 && touch -c $1/f\$i 2>/dev/null
        [ $LHOLD = 0 ] || { sleep $LHOLD_S 3< $1/f\$i; } 2>/dev/null
    done
    echo 2 > /proc/sys/vm/drop_caches
    r=\$((r + 1))
done
echo "lookup dir=$1 rounds=\$r"
EOF
}
pfeed() {  # the churner creates the feed's files at an even pace
    cat <<EOF
end=\$((\$(date +%s) + $SECS)); i=0
gap=\$(awk -v s=$SECS -v n=$PUNL 'BEGIN { printf "%.3f", s / n }')
while [ \$i -lt $PUNL ] && [ \$(date +%s) -lt \$end ]; do
    : > $DV/v\$i && i=\$((i + 1))
    sleep \$gap
done
echo "peer_feed dir=$DV created=\$i of $PUNL"
EOF
}
punlink() {  # the peer removes each of the feed's files as it appears
    cat <<EOF
end=\$((\$(date +%s) + $SECS + 5)); n=0
while [ \$n -lt $PUNL ] && [ \$(date +%s) -lt \$end ]; do
    if rm $DV/v\$n 2>/dev/null; then n=\$((n + 1)); else sleep 0.05; fi
done
echo "peer_unlink dir=$DV removed=\$n of $PUNL"
EOF
}
churn "$DA" > "$OUT/churn_a.sh"; lookup "$DA" > "$OUT/lookup_a.sh"
churn "$DB" > "$OUT/churn_b.sh"; lookup "$DB" > "$OUT/lookup_b.sh"
timeout $((SECS + 60)) "$SSH" "$A" "bash -s" < "$OUT/churn_a.sh" > "$OUT/${A}_churn.out" 2>&1 & p1=$!
timeout $((SECS + 60)) "$SSH" "$B" "bash -s" < "$OUT/lookup_a.sh" > "$OUT/${B}_lookup.out" 2>&1 & p2=$!
timeout $((SECS + 60)) "$SSH" "$B" "bash -s" < "$OUT/churn_b.sh" > "$OUT/${B}_churn.out" 2>&1 & p3=$!
timeout $((SECS + 60)) "$SSH" "$A" "bash -s" < "$OUT/lookup_b.sh" > "$OUT/${A}_lookup.out" 2>&1 & p4=$!
p5=""; r5=-; p6=""; r6=-
if [ "$PUNL" -gt 0 ]; then
    pfeed > "$OUT/pfeed_a.sh"; punlink > "$OUT/punlink_b.sh"
    timeout $((SECS + 60)) "$SSH" "$A" "bash -s" < "$OUT/pfeed_a.sh" > "$OUT/${A}_pfeed.out" 2>&1 & p6=$!
    timeout $((SECS + 60)) "$SSH" "$B" "bash -s" < "$OUT/punlink_b.sh" > "$OUT/${B}_punlink.out" 2>&1 & p5=$!
fi
wait $p1; r1=$?; wait $p2; r2=$?; wait $p3; r3=$?; wait $p4; r4=$?
[ -z "$p5" ] || { wait $p5; r5=$?; }
[ -z "$p6" ] || { wait $p6; r6=$?; }
echo "workload rc: $A churn=$r1 lookup=$r4 peer_feed=$r6  $B churn=$r3 lookup=$r2 peer_unlink=$r5 (124 = overran SECS+60)"
for f in "$OUT"/*_churn.out "$OUT"/*_lookup.out "$OUT"/*_pfeed.out "$OUT"/*_punlink.out; do [ -e "$f" ] || continue; echo "  $(basename "$f"): $(tail -1 "$f" | cut -c1-120)"; done
punl_removed=$(sed -n 's/^peer_unlink .* removed=\([0-9]*\) .*/\1/p' "$OUT/${B}_punlink.out" 2>/dev/null)
punl_created=$(sed -n 's/^peer_feed .* created=\([0-9]*\) .*/\1/p' "$OUT/${A}_pfeed.out" 2>/dev/null)

tot_rel=0; tot_live=0; bad=0; refuse_ok=1; tot_im=0; tot_ipf=0; tot_nls=0
tot_hk=0; tot_hl=0; tot_hp=0; tot_hu=0; tot_hr=0; tot_hd=0; tot_hn=0; tot_fk=0; tot_fr=0; tot_sk=0; tot_sr=0
tot_vu=0; tot_vs=0; tot_zl=0; tot_zr=0; tot_ci=0; tot_cw=0; tot_wm=0; tot_ngi=0; tot_wml=0
tot_xr=0; tot_xhp=0; tot_xlf=0; tot_xrl=0; tot_xrlf=0; tot_xdl=0
tot_dw=0; tot_dwr=0; tot_dk=0; tot_dwz=0; tot_dhz=0; tot_drd=0; tot_dcov=0; tot_dunc=0
tot_ifd=0; tot_ifdr=0; tot_ifu=0; tot_ifr=0; tot_rkt=0; tot_rkr=0
tot_dbl=0; tot_dtag=0; tot_dtdir=0; tot_stc=0; tot_sth=0; tot_bnd=0; tot_pcag=0; tot_pcdir=0
tot_uxe=0; tot_uxl=0; tot_uxu=0; tot_uxlst=0; tot_uxunl=0; tot_uxinf=0; tot_uxum=0
tot_fnr=0; tot_fnh=0; tot_fne=0; tot_fnel=0; agbast_a=0
tot_fhp=0; tot_fhr=0; tot_shint=0; tot_swl=0; swmax=0
tot_crd=0; tot_crr=0; tot_crf=0; tot_crc=0; tot_crl=0
tot_rtk=0; tot_rts=0; tot_rt56=0; tot_rt57=0; tot_rt3r=0; tot_rtsf=0
tot_wwe=0; tot_wwn=0; tot_wwm=0; tot_wwd=0; tot_wwcw=0; tot_wwcp=0; tot_wwp=0; tot_wwb=0; tot_wwa=0; tot_wwr=0; tot_wwrr=0
tot_rsd=0; tot_rsl=0; tot_rsh=0
tot_upm=0; tot_upr=0; tot_upml=0; tot_upmf=0; tot_uprl=0; tot_upw=0; tot_p53=0; tot_p53m=0; tot_upsd=0
tot_rlc=0
tot_fac=0
tot_ixc=0; tot_ixl=0; tot_ixland=0; tot_ixfat=0
tot_cgf=0; tot_cgr=0; tot_cgd=0; tot_cgl=0; tot_cgl0=0; tot_cgrl=0; tot_cgrbad=0; tot_cgc=0; tot_cgcause=0; cgmax=0; cgmax1=0
tot_ubf=0; tot_ubp=0; tot_ubr=0; tot_ubl=0; tot_ubm=0
tot_nrm=0; tot_nrr=0; tot_nrk=0; tot_nrw=0; tot_nrg=0; tot_nrwl=0; tot_nrws=0
declare -A nfail=()
for n in $NODES; do
    rs 40 "$n" "for c in $CNTS; do echo \$c=\$(cat $P/\$c); done; for c in $ICNTS inact_local_epoch_guard; do echo \$c=\$(cat $P/\$c 2>/dev/null); done; if [ $MCHECK = 1 ]; then for c in $HCNTS; do echo \$c=\$(cat $P/\$c 2>/dev/null); done; fi; for c in $FCNTS freshsrc_keep_guard $SCNTS selfclobber_keep_guard $VCNTS noino_resv_guard $ZCNTS noino_shell_guard $CCNTS pub_claim_release_guard $WCNTS pub_claim_write_guard $XCNTS p55c_home_restore $DCNTS noino_recycle_dirty_wait $IFCNTS ifree_defer_drain ifree_defer_reap $RKCNTS reap_transient_keep $DBCNTS pub_drain_bound $FNCNTS ag_ialloc_fence $FHCNTS ag_fence_hint_exempt $CRCNTS cr63_linked_defer $RTCNTS relflush_through_audit $IWCNTS dino_clobber_check $IRCNTS iwr_refuse_empty $RSCNTS recycle_stale_sideread $UPCNTS unlprev_held_verify dbg_unlprev_wait_delay_ms $RLCNTS stale_stage_skip_landed $FACNTS free_adopt_core $IXCNTS ifree_defer_extend $CGCNTS cr63_igrab_retry dbg_evict_stale_delay_ms $UBCNTS unstaged_logged_skip $NRCNTS noino_release_mark_honor dbg_reclaim_hold incarn_poison_unexposed dialloc_held_skip dialloc_held_skipped cr63_held_reset; do echo \$c=\$(cat $P/\$c 2>/dev/null); done; echo mounted=\$(grep -c ' /mnt/shared mxfs ' /proc/mounts); dmesg | sed -n '/$MARK/,\$p'" > "$OUT/${n}_kmsg.txt"
    dw=$(sed -n 's/^recycle_dirty_waits=//p' "$OUT/${n}_kmsg.txt"); dwr=$(sed -n 's/^recycle_dirty_wait_rounds=//p' "$OUT/${n}_kmsg.txt")
    dk=$(sed -n 's/^recycle_dirty_kept=//p' "$OUT/${n}_kmsg.txt"); dwz=$(sed -n 's/^recycle_waited_reset=//p' "$OUT/${n}_kmsg.txt")
    dhz=$(sed -n 's/^recycle_dirty_hazard=//p' "$OUT/${n}_kmsg.txt"); drd=$(sed -n 's/^recycle_reset_dirty=//p' "$OUT/${n}_kmsg.txt")
    dg=$(sed -n 's/^noino_recycle_dirty_wait=//p' "$OUT/${n}_kmsg.txt")
    echo "$n dirtywait: knob=${dg:-?} waits=${dw:-?} wait_rounds=${dwr:-?} kept=${dk:-?} waited_reset=${dwz:-?} hazard=${dhz:-?} reset_dirty=${drd:-?}"
    if [ -n "$DWAIT" ]; then
        [ -n "$dw" ] && [ -n "$dwr" ] && [ -n "$dk" ] && [ -n "$dwz" ] && [ -n "$dhz" ] && [ -n "$drd" ] || { echo "RESULT: ABORT label=$LABEL -- $n's dirty-wait counters did not read evidence=$OUT"; exit 2; }
        tot_dw=$((tot_dw + dw)); tot_dwr=$((tot_dwr + dwr)); tot_dk=$((tot_dk + dk)); tot_dwz=$((tot_dwz + dwz))
        tot_dhz=$((tot_dhz + dhz)); tot_drd=$((tot_drd + drd))
    fi
    ifd=$(sed -n 's/^ifree_defer_dirty=//p' "$OUT/${n}_kmsg.txt"); ifdr=$(sed -n 's/^ifree_defer_drained=//p' "$OUT/${n}_kmsg.txt")
    ifu=$(sed -n 's/^ifree_defer_unlanded=//p' "$OUT/${n}_kmsg.txt"); ifr=$(sed -n 's/^ifree_defer_reaps=//p' "$OUT/${n}_kmsg.txt")
    ifg=$(sed -n 's/^ifree_defer_drain=//p' "$OUT/${n}_kmsg.txt")/$(sed -n 's/^ifree_defer_reap=//p' "$OUT/${n}_kmsg.txt")
    echo "$n ifdefer: drain/reap=$ifg dirty=${ifd:-?} drained=${ifdr:-?} unlanded=${ifu:-?} reaps=${ifr:-?}"
    if [ -n "$IDRAIN$IREAP" ]; then
        [ "$ifg" = "${IDRAIN:-1}/${IREAP:-1}" ] || { echo "RESULT: ABORT label=$LABEL -- $n's ifree_defer_drain/ifree_defer_reap read '$ifg' after the workload, not ${IDRAIN:-1}/${IREAP:-1} evidence=$OUT"; exit 2; }
        [ -n "$ifd" ] && [ -n "$ifdr" ] && [ -n "$ifu" ] && [ -n "$ifr" ] || { echo "RESULT: ABORT label=$LABEL -- $n's deferred-free counters did not read evidence=$OUT"; exit 2; }
        tot_ifd=$((tot_ifd + ifd)); tot_ifdr=$((tot_ifdr + ifdr)); tot_ifu=$((tot_ifu + ifu)); tot_ifr=$((tot_ifr + ifr))
    fi
    rkt=$(sed -n 's/^reap_iget_transient=//p' "$OUT/${n}_kmsg.txt"); rkr=$(sed -n 's/^reap_iget_retired=//p' "$OUT/${n}_kmsg.txt")
    rkg=$(sed -n 's/^reap_transient_keep=//p' "$OUT/${n}_kmsg.txt")
    echo "$n reap lookups: keep=${rkg:-?} transient=${rkt:-?} retired=${rkr:-?}"
    if [ -n "$RKEEP" ]; then
        [ "$rkg" = "$RKEEP" ] || { echo "RESULT: ABORT label=$LABEL -- $n's reap_transient_keep read '$rkg' after the workload, not $RKEEP evidence=$OUT"; exit 2; }
        [ -n "$rkt" ] && [ -n "$rkr" ] || { echo "RESULT: ABORT label=$LABEL -- $n's reap lookup counters did not read evidence=$OUT"; exit 2; }
        tot_rkt=$((tot_rkt + rkt)); tot_rkr=$((tot_rkr + rkr))
    fi
    dbl=$(sed -n 's/^pub_drain_bound_left=//p' "$OUT/${n}_kmsg.txt"); dbg=$(sed -n 's/^pub_drain_bound=//p' "$OUT/${n}_kmsg.txt")
    uxe=$(sed -n 's/^pub_unlock_exposed=//p' "$OUT/${n}_kmsg.txt"); uxl=$(sed -n 's/^pub_unlock_listed=//p' "$OUT/${n}_kmsg.txt")
    echo "$n drain bound: knob=${dbg:-?} left=${dbl:-?} unlock_exposed=${uxe:-?} unlock_listed=${uxl:-?}"
    if [ -n "$DBOUND" ]; then
        [ "$dbg" = "$DBOUND" ] || { echo "RESULT: ABORT label=$LABEL -- $n's pub_drain_bound read '$dbg' after the workload, not $DBOUND evidence=$OUT"; exit 2; }
        [ -n "$dbl" ] || { echo "RESULT: ABORT label=$LABEL -- $n's pub_drain_bound_left did not read evidence=$OUT"; exit 2; }
        [ -n "$uxe" ] && [ -n "$uxl" ] || { echo "RESULT: ABORT label=$LABEL -- $n's pub_unlock_exposed/pub_unlock_listed did not read (is the build missing the exposure instrument?) evidence=$OUT"; exit 2; }
        tot_dbl=$((tot_dbl + dbl)); tot_uxe=$((tot_uxe + uxe)); tot_uxl=$((tot_uxl + uxl))
    fi
    fnr=$(sed -n 's/^ag_ialloc_fenced=//p' "$OUT/${n}_kmsg.txt"); fnh=$(sed -n 's/^ag_fence_held=//p' "$OUT/${n}_kmsg.txt")
    fne=$(sed -n 's/^ag_fence_escaped=//p' "$OUT/${n}_kmsg.txt"); fng=$(sed -n 's/^ag_ialloc_fence=//p' "$OUT/${n}_kmsg.txt")
    echo "$n ialloc fence: knob=${fng:-?} refused=${fnr:-?} held=${fnh:-?} escaped=${fne:-?}"
    if [ -n "$IFENCE" ]; then
        [ "$fng" = "$IFENCE" ] || { echo "RESULT: ABORT label=$LABEL -- $n's ag_ialloc_fence read '$fng' after the workload, not $IFENCE evidence=$OUT"; exit 2; }
        [ -n "$fnr" ] && [ -n "$fnh" ] && [ -n "$fne" ] || { echo "RESULT: ABORT label=$LABEL -- $n's H-F13 counters did not read evidence=$OUT"; exit 2; }
        tot_fnr=$((tot_fnr + fnr)); tot_fnh=$((tot_fnh + fnh)); tot_fne=$((tot_fne + fne))
    fi
    fhp=$(sed -n 's/^ag_fence_hint_passed=//p' "$OUT/${n}_kmsg.txt"); fhr=$(sed -n 's/^ag_fence_hint_refused=//p' "$OUT/${n}_kmsg.txt")
    fhg=$(sed -n 's/^ag_fence_hint_exempt=//p' "$OUT/${n}_kmsg.txt")
    echo "$n fence hint: knob=${fhg:-?} passed=${fhp:-?} refused=${fhr:-?}"
    if [ -n "$FHEX" ]; then
        [ "$fhg" = "$FHEX" ] || { echo "RESULT: ABORT label=$LABEL -- $n's ag_fence_hint_exempt read '$fhg' after the workload, not $FHEX evidence=$OUT"; exit 2; }
        [ -n "$fhp" ] && [ -n "$fhr" ] || { echo "RESULT: ABORT label=$LABEL -- $n's H-F13b counters did not read evidence=$OUT"; exit 2; }
        tot_fhp=$((tot_fhp + fhp)); tot_fhr=$((tot_fhr + fhr))
    fi
    crd=$(sed -n 's/^cr63_linked_deferred=//p' "$OUT/${n}_kmsg.txt"); crr=$(sed -n 's/^cr63_linked_refused=//p' "$OUT/${n}_kmsg.txt")
    crg=$(sed -n 's/^cr63_linked_defer=//p' "$OUT/${n}_kmsg.txt")
    echo "$n cr63 linked: knob=${crg:-?} deferred=${crd:-?} refused=${crr:-?}"
    if [ -n "$CRDEF" ]; then
        [ "$crg" = "$CRDEF" ] || { echo "RESULT: ABORT label=$LABEL -- $n's cr63_linked_defer read '$crg' after the workload, not $CRDEF evidence=$OUT"; exit 2; }
        [ -n "$crd" ] && [ -n "$crr" ] || { echo "RESULT: ABORT label=$LABEL -- $n's H-L1 counters did not read evidence=$OUT"; exit 2; }
        tot_crd=$((tot_crd + crd)); tot_crr=$((tot_crr + crr))
    fi
    rtk=$(sed -n 's/^relflush_audit_kept=//p' "$OUT/${n}_kmsg.txt"); rts=$(sed -n 's/^nl_dir_skip_demoting=//p' "$OUT/${n}_kmsg.txt")
    rtg=$(sed -n 's/^relflush_through_audit=//p' "$OUT/${n}_kmsg.txt")
    echo "$n relflush audit: knob=${rtg:-?} kept=${rtk:-?} skip_demoting=${rts:-?}"
    if [ -n "$RTAUD" ]; then
        [ "$rtg" = "$RTAUD" ] || { echo "RESULT: ABORT label=$LABEL -- $n's relflush_through_audit read '$rtg' after the workload, not $RTAUD evidence=$OUT"; exit 2; }
        [ -n "$rtk" ] && [ -n "$rts" ] || { echo "RESULT: ABORT label=$LABEL -- $n's H-RT1 counters did not read evidence=$OUT"; exit 2; }
        tot_rtk=$((tot_rtk + rtk)); tot_rts=$((tot_rts + rts))
    fi
    wwe=$(sed -n 's/^iwr_whole_early=//p' "$OUT/${n}_kmsg.txt"); wwn=$(sed -n 's/^iwr_whole_noskip=//p' "$OUT/${n}_kmsg.txt")
    wwm=$(sed -n 's/^iwr_whole_empty=//p' "$OUT/${n}_kmsg.txt"); wwd=$(sed -n 's/^iwr_whole_declined=//p' "$OUT/${n}_kmsg.txt")
    wwg=$(sed -n 's/^dino_clobber_check=//p' "$OUT/${n}_kmsg.txt")
    echo "$n whole cluster writes: clobber_check=${wwg:-?} early=${wwe:-?} noskip=${wwn:-?} empty=${wwm:-?} declined=${wwd:-?}"
    if [ -n "$IWW" ]; then
        [ "$wwg" = "$IWW" ] || { echo "RESULT: ABORT label=$LABEL -- $n's dino_clobber_check read '$wwg' after the workload, not $IWW evidence=$OUT"; exit 2; }
        [ -n "$wwe" ] && [ -n "$wwn" ] && [ -n "$wwm" ] && [ -n "$wwd" ] || { echo "RESULT: ABORT label=$LABEL -- $n's H-WW1 counters did not read evidence=$OUT"; exit 2; }
        tot_wwe=$((tot_wwe + wwe)); tot_wwn=$((tot_wwn + wwn)); tot_wwm=$((tot_wwm + wwm)); tot_wwd=$((tot_wwd + wwd))
    fi
    wwr=$(sed -n 's/^iwr_empty_refused=//p' "$OUT/${n}_kmsg.txt"); wwrg=$(sed -n 's/^iwr_refuse_empty=//p' "$OUT/${n}_kmsg.txt")
    echo "$n empty-case refusals: knob=${wwrg:-?} refused=${wwr:-?}"
    if [ -n "$IWREF" ]; then
        [ "$wwrg" = "$IWREF" ] || { echo "RESULT: ABORT label=$LABEL -- $n's iwr_refuse_empty read '$wwrg' after the workload, not $IWREF evidence=$OUT"; exit 2; }
        [ -n "$wwr" ] || { echo "RESULT: ABORT label=$LABEL -- $n's iwr_empty_refused did not read evidence=$OUT"; exit 2; }
        tot_wwr=$((tot_wwr + wwr))
    fi
    rsd=$(sed -n 's/^recycle_sideread_disagree=//p' "$OUT/${n}_kmsg.txt"); rsg=$(sed -n 's/^recycle_stale_sideread=//p' "$OUT/${n}_kmsg.txt")
    echo "$n stale-recycle side-reads: knob=${rsg:-?} disagree=${rsd:-?}"
    if [ -n "$RSR" ]; then
        [ "$rsg" = "$RSR" ] || { echo "RESULT: ABORT label=$LABEL -- $n's recycle_stale_sideread read '$rsg' after the workload, not $RSR evidence=$OUT"; exit 2; }
        [ -n "$rsd" ] || { echo "RESULT: ABORT label=$LABEL -- $n's recycle_sideread_disagree did not read evidence=$OUT"; exit 2; }
        tot_rsd=$((tot_rsd + rsd))
    fi
    upm=$(sed -n 's/^unlprev_held_moved=//p' "$OUT/${n}_kmsg.txt"); upr=$(sed -n 's/^unlprev_rebuilds=//p' "$OUT/${n}_kmsg.txt")
    upg=$(sed -n 's/^unlprev_held_verify=//p' "$OUT/${n}_kmsg.txt"); upd=$(sed -n 's/^dbg_unlprev_wait_delay_ms=//p' "$OUT/${n}_kmsg.txt")
    echo "$n unlinked predecessor check: knob=${upg:-?} delay_ms=${upd:-?} moved=${upm:-?} rebuilds=${upr:-?}"
    if [ -n "$UPV" ]; then
        [ "$upg" = "$UPV" ] || { echo "RESULT: ABORT label=$LABEL -- $n's unlprev_held_verify read '$upg' after the workload, not $UPV evidence=$OUT"; exit 2; }
        [ -z "$UPD" ] || [ "$upd" = "$UPD" ] || { echo "RESULT: ABORT label=$LABEL -- $n's dbg_unlprev_wait_delay_ms read '$upd' after the workload, not $UPD evidence=$OUT"; exit 2; }
        [ -n "$upm" ] && [ -n "$upr" ] || { echo "RESULT: ABORT label=$LABEL -- $n's H-IU1 counters did not read evidence=$OUT"; exit 2; }
        tot_upm=$((tot_upm + upm)); tot_upr=$((tot_upr + upr))
    fi
    rlc=$(sed -n 's/^stale_stage_rf_landed=//p' "$OUT/${n}_kmsg.txt"); rlg=$(sed -n 's/^stale_stage_skip_landed=//p' "$OUT/${n}_kmsg.txt")
    echo "$n dead-tenure landed slots in release-flush/demoter writes: knob=${rlg:-?} found=${rlc:-?}"
    if [ -n "$RS1" ]; then
        [ "$rlg" = "$RS1" ] || { echo "RESULT: ABORT label=$LABEL -- $n's stale_stage_skip_landed read '$rlg' after the workload, not $RS1 evidence=$OUT"; exit 2; }
        [ -n "$rlc" ] || { echo "RESULT: ABORT label=$LABEL -- $n's stale_stage_rf_landed did not read evidence=$OUT"; exit 2; }
        tot_rlc=$((tot_rlc + rlc))
    fi
    fac=$(sed -n 's/^free_adopt_core_diff=//p' "$OUT/${n}_kmsg.txt"); fag=$(sed -n 's/^free_adopt_core=//p' "$OUT/${n}_kmsg.txt")
    echo "$n free-dinode adopts whose core differed: knob=${fag:-?} found=${fac:-?}"
    if [ -n "$FA1" ]; then
        [ "$fag" = "$FA1" ] || { echo "RESULT: ABORT label=$LABEL -- $n's free_adopt_core read '$fag' after the workload, not $FA1 evidence=$OUT"; exit 2; }
        [ -n "$fac" ] || { echo "RESULT: ABORT label=$LABEL -- $n's free_adopt_core_diff did not read evidence=$OUT"; exit 2; }
        tot_fac=$((tot_fac + fac))
    fi
    ixc=$(sed -n 's/^ifree_defer_extended=//p' "$OUT/${n}_kmsg.txt"); ixg=$(sed -n 's/^ifree_defer_extend=//p' "$OUT/${n}_kmsg.txt")
    echo "$n deferred-free drains past their bound: knob=${ixg:-?} found=${ixc:-?}"
    if [ -n "$IFX" ]; then
        [ "$ixg" = "$IFX" ] || { echo "RESULT: ABORT label=$LABEL -- $n's ifree_defer_extend read '$ixg' after the workload, not $IFX evidence=$OUT"; exit 2; }
        [ -n "$ixc" ] || { echo "RESULT: ABORT label=$LABEL -- $n's ifree_defer_extended did not read evidence=$OUT"; exit 2; }
        tot_ixc=$((tot_ixc + ixc))
    fi
    cgf=$(sed -n 's/^cr63_igrab_fail=//p' "$OUT/${n}_kmsg.txt"); cgr=$(sed -n 's/^cr63_igrab_retried=//p' "$OUT/${n}_kmsg.txt")
    cgd=$(sed -n 's/^dbg_evict_stale_delayed=//p' "$OUT/${n}_kmsg.txt"); cgg=$(sed -n 's/^cr63_igrab_retry=//p' "$OUT/${n}_kmsg.txt")
    cgdm=$(sed -n 's/^dbg_evict_stale_delay_ms=//p' "$OUT/${n}_kmsg.txt")
    echo "$n create igrabs of a copy in teardown: knob=${cgg:-?} hold_ms=${cgdm:-?} failed=${cgf:-?} retried=${cgr:-?} evictions_held=${cgd:-?}"
    if [ -n "$CGR" ]; then
        [ "$cgg" = "$CGR" ] || { echo "RESULT: ABORT label=$LABEL -- $n's cr63_igrab_retry read '$cgg' after the workload, not $CGR evidence=$OUT"; exit 2; }
        [ -z "$CGD" ] || [ "$cgdm" = "$CGD" ] || { echo "RESULT: ABORT label=$LABEL -- $n's dbg_evict_stale_delay_ms read '$cgdm' after the workload, not $CGD evidence=$OUT"; exit 2; }
        [ -n "$cgf" ] && [ -n "$cgr" ] && [ -n "$cgd" ] || { echo "RESULT: ABORT label=$LABEL -- $n's H-CG1 counters did not read evidence=$OUT"; exit 2; }
        tot_cgf=$((tot_cgf + cgf)); tot_cgr=$((tot_cgr + cgr)); tot_cgd=$((tot_cgd + cgd))
    fi
    ubf=$(sed -n 's/^unstaged_logged_found=//p' "$OUT/${n}_kmsg.txt"); ubp=$(sed -n 's/^unstaged_logged_prevented=//p' "$OUT/${n}_kmsg.txt")
    ubr=$(sed -n 's/^unstaged_logged_regressed=//p' "$OUT/${n}_kmsg.txt"); ubg=$(sed -n 's/^unstaged_logged_skip=//p' "$OUT/${n}_kmsg.txt")
    echo "$n never-copied-in logged slots in partial cluster writes: knob=${ubg:-?} found=${ubf:-?} prevented=${ubp:-?} regressed=${ubr:-?}"
    if [ -n "$UB1" ]; then
        [ "$ubg" = "$UB1" ] || { echo "RESULT: ABORT label=$LABEL -- $n's unstaged_logged_skip read '$ubg' after the workload, not $UB1 evidence=$OUT"; exit 2; }
        [ -n "$ubf" ] && [ -n "$ubp" ] && [ -n "$ubr" ] || { echo "RESULT: ABORT label=$LABEL -- $n's H-UB1 counters did not read evidence=$OUT"; exit 2; }
        tot_ubf=$((tot_ubf + ubf)); tot_ubp=$((tot_ubp + ubp)); tot_ubr=$((tot_ubr + ubr))
    fi
    nrm=$(sed -n 's/^noino_release_marked=//p' "$OUT/${n}_kmsg.txt"); nrr=$(sed -n 's/^recycle_released_reset=//p' "$OUT/${n}_kmsg.txt")
    nrk=$(sed -n 's/^recycle_released_kept=//p' "$OUT/${n}_kmsg.txt"); nrw=$(sed -n 's/^logwr_relmark_written=//p' "$OUT/${n}_kmsg.txt")
    nrg=$(sed -n 's/^logwr_relmark_regressed=//p' "$OUT/${n}_kmsg.txt"); nrh=$(sed -n 's/^noino_release_mark_honor=//p' "$OUT/${n}_kmsg.txt")
    echo "$n no-inode release marks: knob=${nrh:-?} marked=${nrm:-?} recycle_reset=${nrr:-?} recycle_kept=${nrk:-?} relmark_written=${nrw:-?} relmark_regressed=${nrg:-?}"
    rhg=$(sed -n 's/^dbg_reclaim_hold=//p' "$OUT/${n}_kmsg.txt")
    [ -z "$RHOLD" ] || [ "$rhg" = "$RHOLD" ] || { echo "RESULT: ABORT label=$LABEL -- $n's dbg_reclaim_hold read '$rhg' after the workload, not $RHOLD evidence=$OUT"; exit 2; }
    if [ -n "$NR1" ]; then
        [ "$nrh" = "$NR1" ] || { echo "RESULT: ABORT label=$LABEL -- $n's noino_release_mark_honor read '$nrh' after the workload, not $NR1 evidence=$OUT"; exit 2; }
        [ -n "$nrm" ] && [ -n "$nrr" ] && [ -n "$nrk" ] && [ -n "$nrw" ] && [ -n "$nrg" ] || { echo "RESULT: ABORT label=$LABEL -- $n's H-NR1 counters did not read evidence=$OUT"; exit 2; }
        tot_nrm=$((tot_nrm + nrm)); tot_nrr=$((tot_nrr + nrr)); tot_nrk=$((tot_nrk + nrk))
        tot_nrw=$((tot_nrw + nrw)); tot_nrg=$((tot_nrg + nrg))
    fi
    ci=$(sed -n 's/^pub_claim_inflight_rel=//p' "$OUT/${n}_kmsg.txt"); cw=$(sed -n 's/^pub_claim_rel_waited=//p' "$OUT/${n}_kmsg.txt")
    cg=$(sed -n 's/^pub_claim_release_guard=//p' "$OUT/${n}_kmsg.txt")
    wm=$(sed -n 's/^pub_claim_write_masked=//p' "$OUT/${n}_kmsg.txt"); wg=$(sed -n 's/^pub_claim_write_guard=//p' "$OUT/${n}_kmsg.txt")
    echo "$n pubclaim: guard=${cg:-?} inflight_rel=${ci:-?} rel_waited=${cw:-?} write_guard=${wg:-?} write_masked=${wm:-?}"
    if [ -n "$CGUARD" ]; then
        [ -n "$ci" ] && [ -n "$cw" ] || { echo "RESULT: ABORT label=$LABEL -- $n's H-F10 counters did not read evidence=$OUT"; exit 2; }
        tot_ci=$((tot_ci + ci)); tot_cw=$((tot_cw + cw))
    fi
    if [ -n "$WGUARD" ]; then
        [ -n "$wm" ] || { echo "RESULT: ABORT label=$LABEL -- $n's H-F10 write-side counter did not read evidence=$OUT"; exit 2; }
        tot_wm=$((tot_wm + wm))
    fi
    xr=$(sed -n 's/^p55c_home_restored=//p' "$OUT/${n}_kmsg.txt"); xg=$(sed -n 's/^p55c_home_restore=//p' "$OUT/${n}_kmsg.txt")
    echo "$n p55c: home_restore=${xg:-?} home_restored=${xr:-?}"
    if [ -n "$XGUARD" ]; then
        [ -n "$xr" ] || { echo "RESULT: ABORT label=$LABEL -- $n's H-F11 counter did not read evidence=$OUT"; exit 2; }
        tot_xr=$((tot_xr + xr))
    fi
    zl=$(sed -n 's/^noino_live_shell=//p' "$OUT/${n}_kmsg.txt"); zr=$(sed -n 's/^noino_shell_routed=//p' "$OUT/${n}_kmsg.txt")
    zg=$(sed -n 's/^noino_shell_guard=//p' "$OUT/${n}_kmsg.txt")
    echo "$n shell: guard=${zg:-?} live_shell=${zl:-?} shell_routed=${zr:-?}"
    if [ -n "$HGUARD" ]; then
        [ -n "$zl" ] && [ -n "$zr" ] || { echo "RESULT: ABORT label=$LABEL -- $n's H-F9 counters did not read evidence=$OUT"; exit 2; }
        tot_zl=$((tot_zl + zl)); tot_zr=$((tot_zr + zr))
    fi
    vu=$(sed -n 's/^dialloc_resv_under_noino=//p' "$OUT/${n}_kmsg.txt"); vs=$(sed -n 's/^dialloc_resv_noino_skipped=//p' "$OUT/${n}_kmsg.txt")
    vg=$(sed -n 's/^noino_resv_guard=//p' "$OUT/${n}_kmsg.txt")
    echo "$n resv: guard=${vg:-?} under_noino=${vu:-?} noino_skipped=${vs:-?}"
    if [ -n "$VGUARD" ]; then
        [ -n "$vu" ] && [ -n "$vs" ] || { echo "RESULT: ABORT label=$LABEL -- $n's H-F7c counters did not read evidence=$OUT"; exit 2; }
        tot_vu=$((tot_vu + vu)); tot_vs=$((tot_vs + vs))
    fi
    sk=$(sed -n 's/^selfclobber_keep_clean=//p' "$OUT/${n}_kmsg.txt"); sr=$(sed -n 's/^selfclobber_clean_refused=//p' "$OUT/${n}_kmsg.txt")
    sg=$(sed -n 's/^selfclobber_keep_guard=//p' "$OUT/${n}_kmsg.txt")
    echo "$n selfclobber: guard=${sg:-?} keep_clean=${sk:-?} clean_refused=${sr:-?}"
    if [ -n "$SGUARD" ]; then
        [ -n "$sk" ] && [ -n "$sr" ] || { echo "RESULT: ABORT label=$LABEL -- $n's H-F8b counters did not read evidence=$OUT"; exit 2; }
        tot_sk=$((tot_sk + sk)); tot_sr=$((tot_sr + sr))
    fi
    fk=$(sed -n 's/^freshsrc_keep_clean=//p' "$OUT/${n}_kmsg.txt"); fr=$(sed -n 's/^freshsrc_clean_refused=//p' "$OUT/${n}_kmsg.txt")
    fg=$(sed -n 's/^freshsrc_keep_guard=//p' "$OUT/${n}_kmsg.txt")
    echo "$n freshsrc: guard=${fg:-?} keep_clean=${fk:-?} clean_refused=${fr:-?}"
    if [ -n "$FGUARD" ]; then
        [ -n "$fk" ] && [ -n "$fr" ] || { echo "RESULT: ABORT label=$LABEL -- $n's H-F8 counters did not read evidence=$OUT"; exit 2; }
        tot_fk=$((tot_fk + fk)); tot_fr=$((tot_fr + fr))
    fi
    im=$(sed -n 's/^inact_local_epoch_moved=//p' "$OUT/${n}_kmsg.txt"); ipf=$(sed -n 's/^inact_local_peerfreed=//p' "$OUT/${n}_kmsg.txt")
    ig=$(sed -n 's/^inact_local_epoch_guard=//p' "$OUT/${n}_kmsg.txt")
    echo "$n inact_local: guard=${ig:-?} moved=${im:-?} peerfreed=${ipf:-?}"
    tot_im=$((tot_im + ${im:-0})); tot_ipf=$((tot_ipf + ${ipf:-0}))
    if [ "$MCHECK" = 1 ]; then
        hk=$(sed -n 's/^recycle_keep_noino=//p' "$OUT/${n}_kmsg.txt"); hl=$(sed -n 's/^noino_unlock_left_grant=//p' "$OUT/${n}_kmsg.txt")
        hp=$(sed -n 's/^log_mirror_phantom=//p' "$OUT/${n}_kmsg.txt"); hu=$(sed -n 's/^noino_unlock_undrained=//p' "$OUT/${n}_kmsg.txt")
        hr=$(sed -n 's/^recycle_reset_noino=//p' "$OUT/${n}_kmsg.txt"); hd=$(sed -n 's/^noino_recycle_redrive=//p' "$OUT/${n}_kmsg.txt")
        hn=$(sed -n 's/^logwr_dlm_nogrant=//p' "$OUT/${n}_kmsg.txt")
        echo "$n hf7: recycle_keep_noino=${hk:-?} noino_unlock_left_grant=${hl:-?} log_mirror_phantom=${hp:-?} noino_unlock_undrained=${hu:-?} recycle_reset_noino=${hr:-?} noino_recycle_redrive=${hd:-?} logwr_dlm_nogrant=${hn:-?}"
        [ -n "$hk" ] && [ -n "$hl" ] && [ -n "$hp" ] && [ -n "$hu" ] && [ -n "$hr" ] && [ -n "$hd" ] && [ -n "$hn" ] || { echo "RESULT: ABORT label=$LABEL -- $n's H-F7 counters did not read evidence=$OUT"; exit 2; }
        tot_hk=$((tot_hk + hk)); tot_hl=$((tot_hl + hl)); tot_hp=$((tot_hp + hp)); tot_hu=$((tot_hu + hu))
        tot_hr=$((tot_hr + hr)); tot_hd=$((tot_hd + hd)); tot_hn=$((tot_hn + hn))
    fi
    rel=$(sed -n 's/^noino_gen0_releases=//p' "$OUT/${n}_kmsg.txt"); live=$(sed -n 's/^noino_gen0_live=//p' "$OUT/${n}_kmsg.txt")
    ref=$(sed -n 's/^noino_gen0_refused=//p' "$OUT/${n}_kmsg.txt"); mnt=$(sed -n 's/^mounted=//p' "$OUT/${n}_kmsg.txt")
    sd=$(grep -ac 'Shutting down filesystem\|P-WITHDRAW\|P131-SELF-FENCE\|BUG:\|Oops\|blocked for more than' "$OUT/${n}_kmsg.txt")
    echo "$n gen0_releases=${rel:-?} gen0_live=${live:-?} gen0_refused=${ref:-?} mounted=${mnt:-?} live_lines=$(grep -ac P-NOINO-GEN0-LIVE "$OUT/${n}_kmsg.txt") stale_release_lines=$(grep -ac P-NOINO-STALE-RELEASE "$OUT/${n}_kmsg.txt") acq_wait_lines=$(grep -ac P-NOINO-ACQ-WAIT "$OUT/${n}_kmsg.txt") failure_lines=$sd"
    grep -a -m3 'P-NOINO-GEN0-LIVE' "$OUT/${n}_kmsg.txt" | cut -c1-240
    [ -n "$rel" ] && [ -n "$live" ] && [ -n "$ref" ] || { echo "RESULT: ABORT label=$LABEL -- $n's counters did not read evidence=$OUT"; exit 2; }
    tot_rel=$((tot_rel + rel)); tot_live=$((tot_live + live))
    [ "$sd" = 0 ] && [ "$mnt" = 1 ] || nfail[$n]=1
    [ "$GUARD" = 1 ] && [ "$ref" != "$live" ] && refuse_ok=0
done
for n in $NODES; do
    got=$(rs 20 "$n" "echo 0 > $P/dbg_noino_release_delay_ms; cat $P/dbg_noino_release_delay_ms" | tail -1)
    [ "$got" = 0 ] || echo "WARN $n's dbg_noino_release_delay_ms reads '$got' after the reset; the cold audit's unmount waits on it"
    if [ "$MCHECK" = 1 ]; then
        got=$(rs 20 "$n" "echo 0 > $P/dbg_log_mirror_check; cat $P/dbg_log_mirror_check" | tail -1)
        [ "$got" = 0 ] || echo "WARN $n's dbg_log_mirror_check reads '$got' after the reset"
    fi
    if [ -n "$PFENCE" ]; then
        got=$(rs 20 "$n" "echo 0 > $P/dbg_noino_postfence_delay_ms; cat $P/dbg_noino_postfence_delay_ms" | tail -1)
        [ "$got" = 0 ] || echo "WARN $n's dbg_noino_postfence_delay_ms reads '$got' after the reset; the cold audit's unmount waits on it"
    fi
    if [ -n "$IFB" ]; then
        got=$(rs 20 "$n" "echo 0 > $P/dbg_ifree_defer_bound_ms; cat $P/dbg_ifree_defer_bound_ms" | tail -1)
        [ "$got" = 0 ] || echo "WARN $n's dbg_ifree_defer_bound_ms reads '$got' after the reset"
    fi
    if [ -n "$CGD" ]; then
        got=$(rs 20 "$n" "echo 0 > $P/dbg_evict_stale_delay_ms; cat $P/dbg_evict_stale_delay_ms" | tail -1)
        [ "$got" = 0 ] || echo "WARN $n's dbg_evict_stale_delay_ms reads '$got' after the reset; the cold audit's unmount evictions wait on it"
    fi
    if [ -n "$RHOLD" ]; then
        got=$(rs 20 "$n" "echo 0 > $P/dbg_reclaim_hold; cat $P/dbg_reclaim_hold" | tail -1)
        [ "$got" = 0 ] || echo "WARN $n's dbg_reclaim_hold reads '$got' after the reset"
    fi
    if [ -n "$SADELAY" ]; then
        got=$(rs 20 "$n" "echo 0 > $P/dbg_setattr_time_delay_ms; cat $P/dbg_setattr_time_delay_ms" | tail -1)
        [ "$got" = 0 ] || echo "WARN $n's dbg_setattr_time_delay_ms reads '$got' after the reset"
    fi
    if [ -n "$CDELAY" ]; then
        got=$(rs 20 "$n" "echo 0 > $P/dbg_pub_claim_delay_ms; cat $P/dbg_pub_claim_delay_ms" | tail -1)
        [ "$got" = 0 ] || echo "WARN $n's dbg_pub_claim_delay_ms reads '$got' after the reset; the cold audit's unmount drains wait on it"
    fi
    if [ -n "$PDELAY" ]; then
        got=$(rs 20 "$n" "echo 0 > $P/dbg_create_parent_delay_ms; cat $P/dbg_create_parent_delay_ms" | tail -1)
        [ "$got" = 0 ] || echo "WARN $n's dbg_create_parent_delay_ms reads '$got' after the reset"
    fi
    if [ -n "$UPD" ]; then
        got=$(rs 20 "$n" "echo 0 > $P/dbg_unlprev_wait_delay_ms; cat $P/dbg_unlprev_wait_delay_ms" | tail -1)
        [ "$got" = 0 ] || echo "WARN $n's dbg_unlprev_wait_delay_ms reads '$got' after the reset"
    fi
done

since=$(date -u +%FT%TZ)
./run.sh "$CONFIG" --group "$GROUP" chk_clean > "$OUT/chk.log" 2>&1
audit=$(python3 - data/criteria.json "$CONFIG" "$since" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
for e in d["criteria"]:
    if e.get("id") == "chk_clean":
        cell = (e.get("per_config") or {}).get(sys.argv[2]) or {}
        if str(cell.get("iso", "")) < sys.argv[3]:
            print("STALE"); break
        m = re.search(r"verdict=([A-Z]+).*?errors=(\d+)", str(cell.get("measured", "")))
        print("%s errors=%s" % m.groups() if m else "NONE")
        break
else:
    print("NONE")
PY
)
echo "cold audit: $audit ($OUT/chk.log)"
# The lap's whole kernel log.  The prep starts `dmesg --follow` into
# /root/dmesg.stream on every node (tests/setup/prep_node.sh) and the next
# lap's prep replaces it, so it is kept here, after the cold audit's unmount,
# or never: the ring read above keeps only what the 1 MiB ring still held,
# and a CORRUPT lap whose ring had wrapped left no log of the damage.
for n in $NODES; do
    timeout 120 "$SSH" "$n" "gzip -c /root/dmesg.stream" < /dev/null 2>/dev/null > "$OUT/${n}_dmesg_stream.gz"
    echo "$n kernel log: $OUT/${n}_dmesg_stream.gz marks=$(zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | grep -acF -- "$MARK")"
    # node failures from the whole log after this lap's mark: the ring read
    # above wraps under this workload and missed fxdp2's mid-lap shutdown
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
        | grep -a 'Shutting down filesystem\|P-WITHDRAW\|P131-SELF-FENCE\|P-INODE-WEDGE \|P-SESSION-POISON\|BUG:\|Oops\|blocked for more than' > "$OUT/${n}_failures.txt"
    sds=$(wc -l < "$OUT/${n}_failures.txt")
    echo "$n stream failure lines: $sds ($OUT/${n}_failures.txt)"
    head -3 "$OUT/${n}_failures.txt" | cut -c1-300
    [ "$sds" = 0 ] || nfail[$n]=1
    if [ -n "$CRDEF" ]; then
        zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
            | grep -a 'P-CR63-\|P-CR62 \|P-CR3-CANCEL\|not marked free' > "$OUT/${n}_cr63.txt"
        crf=$(grep -ac 'P-CR63-DEADSHELL ino=' "$OUT/${n}_cr63.txt"); crc=$(grep -ac 'P-CR3-CANCEL' "$OUT/${n}_cr63.txt")
        crl=$(grep -ac 'P-CR63-DEFER-DISKLIVE' "$OUT/${n}_cr63.txt")
        echo "$n cr63 lines: fallthrough=$crf defer_linked=$(grep -ac 'P-CR63-DEADSHELL-DEFER-LINKED ' "$OUT/${n}_cr63.txt") linked_refused=$(grep -ac 'P-CR63-LINKED-REFUSED ' "$OUT/${n}_cr63.txt") cancels=$crc disklive=$crl ($OUT/${n}_cr63.txt)"
        tot_crf=$((tot_crf + crf)); tot_crc=$((tot_crc + crc)); tot_crl=$((tot_crl + crl))
    fi
    if [ -n "$RSR" ]; then
        # the H-F14 side-read verdicts and the poisonings, protections and
        # recycle gates around them
        zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
            | grep -a 'P-RECYCLE-SIDEREAD \|P-RECYCLE-GATE \|P34H-INCARN-POISON \|P34H-POISON-EVICT \|P91-RECYCLE-PROTECT ' > "$OUT/${n}_rsr.txt"
        rsl=$(grep -ac 'P-RECYCLE-SIDEREAD ' "$OUT/${n}_rsr.txt")
        # lfn1's shape: the kept buffer holds the in-core generation and the
        # platter a different live incarnation
        rsh=$(grep -a 'P-RECYCLE-SIDEREAD ' "$OUT/${n}_rsr.txt" \
            | sed -n 's/.*cached\[mode=\([0-7]*\) gen=\([0-9]*\)\] platter\[mode=\([0-7]*\) gen=\([0-9]*\)\] incore_gen=\([0-9]*\) .*/\1 \2 \3 \4 \5/p' \
            | awk '$3 + 0 != 0 && $2 == $5 && $4 != $2 { c++ } END { print c + 0 }')
        echo "$n stale-recycle side-read lines: disagree=$rsl live_reuse=$rsh ($OUT/${n}_rsr.txt)"
        grep -a -m3 'P-RECYCLE-SIDEREAD ' "$OUT/${n}_rsr.txt" | cut -c1-300
        tot_rsl=$((tot_rsl + rsl)); tot_rsh=$((tot_rsh + rsh))
    fi
    if [ -n "$UPV" ]; then
        # the H-IU1 check's lines, the predecessor waits and rebuilds around
        # them, and the precommit mismatch fn32 shut down on
        zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
            | grep -a 'P-UNLPREV-MOVED \|P-UNLPREV-REBUILD \|P-UNLPREV-WAIT \|P53-IUNLINK-MISMATCH \|xfs_iunlink_item_precommit\|Shutting down filesystem' > "$OUT/${n}_unlprev.txt"
        upml=$(grep -ac 'P-UNLPREV-MOVED ' "$OUT/${n}_unlprev.txt")
        upmf=$(grep -a 'P-UNLPREV-MOVED ' "$OUT/${n}_unlprev.txt" | grep -ac ' prev_mode=00* ')
        uprl=$(grep -ac 'P-UNLPREV-REBUILD ' "$OUT/${n}_unlprev.txt")
        upw=$(grep -ac 'P-UNLPREV-WAIT ' "$OUT/${n}_unlprev.txt")
        p53=$(grep -ac 'P53-IUNLINK-MISMATCH ' "$OUT/${n}_unlprev.txt")
        # a mismatch on an inode this node's check had named as the held
        # predecessor (P-UNLPREV-MOVED prints prev= in decimal, P53 ino= in hex)
        p53m=0
        for h in $(grep -a 'P53-IUNLINK-MISMATCH ' "$OUT/${n}_unlprev.txt" | sed -n 's/.* ino=0x\([0-9a-f]*\) .*/\1/p'); do
            grep -a 'P-UNLPREV-MOVED ' "$OUT/${n}_unlprev.txt" | grep -q " prev=$((16#$h)) " && p53m=$((p53m + 1))
        done
        upsd=$(grep -ac 'Shutting down filesystem' "$OUT/${n}_unlprev.txt")
        echo "$n unlinked predecessor lines: waits=$upw moved=$upml moved_freed=$upmf rebuilds=$uprl p53=$p53 p53_on_moved=$p53m shutdowns=$upsd ($OUT/${n}_unlprev.txt)"
        grep -a -m3 'P-UNLPREV-MOVED \|P53-IUNLINK-MISMATCH ' "$OUT/${n}_unlprev.txt" | cut -c1-300
        tot_upml=$((tot_upml + upml)); tot_upmf=$((tot_upmf + upmf)); tot_uprl=$((tot_uprl + uprl))
        tot_upw=$((tot_upw + upw)); tot_p53=$((tot_p53 + p53)); tot_p53m=$((tot_p53m + p53m)); tot_upsd=$((tot_upsd + upsd))
    fi
    if [ -n "$IFX" ]; then
        # the H-IFD1 lines: each drain past its bound, how it ended, and the
        # fail-closed arm ifd2 shut down on
        zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
            | grep -a 'P-IFREE-DEFER-EXTENDED \|P-IFREE-DEFER-UNLANDED-FATAL \|P-INACT-UNLANDED-STATE \|P-BUFLOCK-HOLDER \|P113-DRAIN-WEDGE' > "$OUT/${n}_ifext.txt"
        ixl=$(grep -ac 'P-IFREE-DEFER-EXTENDED ' "$OUT/${n}_ifext.txt")
        ixland=$(grep -a 'P-IFREE-DEFER-EXTENDED ' "$OUT/${n}_ifext.txt" | grep -ac ' landed=1 ')
        ixfat=$(grep -ac 'P-IFREE-DEFER-UNLANDED-FATAL ' "$OUT/${n}_ifext.txt")
        echo "$n deferred-free extension lines: extended=$ixl landed=$ixland fatal=$ixfat ($OUT/${n}_ifext.txt)"
        grep -a -m3 'P-IFREE-DEFER-EXTENDED \|P-IFREE-DEFER-UNLANDED-FATAL ' "$OUT/${n}_ifext.txt" | cut -c1-300
        tot_ixl=$((tot_ixl + ixl)); tot_ixland=$((tot_ixland + ixland)); tot_ixfat=$((tot_ixfat + ixfat))
    fi
    if [ -n "$CGR" ]; then
        # the H-CG1 lines: each failed igrab, the create lookups that met
        # -EAGAIN and how they ended, the held evictions, and the free-state
        # check and dirty cancel rsd11 shut down on
        zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
            | grep -a 'P-CR63-IGRAB-FAIL \|P-IGET-CREATE-RETRIED \|P-EVICT-STALE-DELAY \|P-CR3-CANCEL\|not marked free\|Shutting down filesystem' > "$OUT/${n}_cg1.txt"
        cgl=$(grep -ac 'P-CR63-IGRAB-FAIL ' "$OUT/${n}_cg1.txt")
        cgl0=$(grep -a 'P-CR63-IGRAB-FAIL ' "$OUT/${n}_cg1.txt" | grep -ac ' retry=0 ')
        cgrl=$(grep -ac 'P-IGET-CREATE-RETRIED ' "$OUT/${n}_cg1.txt")
        cgrbad=$(grep -a 'P-IGET-CREATE-RETRIED ' "$OUT/${n}_cg1.txt" | grep -avc ' rc=0 ')
        cgm=$(grep -a 'P-IGET-CREATE-RETRIED ' "$OUT/${n}_cg1.txt" | sed -n 's/.* ms=\([0-9]*\) .*/\1/p' | sort -n | tail -1)
        cgc=$(grep -ac 'P-CR3-CANCEL' "$OUT/${n}_cg1.txt")
        # a retry=0 failed igrab whose number the free-state check (hex) or
        # a create's cancel (dialloc_ino, decimal) then names: rsd11's chain
        cgcause=0
        for h in $(grep -a 'P-CR63-IGRAB-FAIL ' "$OUT/${n}_cg1.txt" | grep -a ' retry=0 ' | sed -n 's/.* ino=0x\([0-9a-f]*\) .*/\1/p' | sort -u); do
            if grep -aq "Free inode 0x$h not marked free" "$OUT/${n}_cg1.txt" \
                || grep -a 'P-CR3-CANCEL' "$OUT/${n}_cg1.txt" | grep -q " dialloc_ino=$((16#$h)) "; then
                cgcause=$((cgcause + 1))
            fi
        done
        # the longest retried lookup of a number a retry=1 failed igrab named:
        # the wait H-CG1 adds, under the creator's AGI
        cgm1=0
        for h in $(grep -a 'P-CR63-IGRAB-FAIL ' "$OUT/${n}_cg1.txt" | grep -a ' retry=1 ' | sed -n 's/.* ino=0x\([0-9a-f]*\) .*/\1/p' | sort -u); do
            m=$(grep -a "P-IGET-CREATE-RETRIED ino=$((16#$h)) " "$OUT/${n}_cg1.txt" | sed -n 's/.* ms=\([0-9]*\) .*/\1/p' | sort -n | tail -1)
            [ -n "$m" ] && [ "$m" -gt "$cgm1" ] && cgm1=$m
        done
        echo "$n create igrab lines: failed=$cgl retry0=$cgl0 retried_lookups=$cgrl retried_not_rc0=$cgrbad retried_max_ms=${cgm:-none} igrab_retry_max_ms=$cgm1 cancels=$cgc control_chains=$cgcause held=$(grep -ac 'P-EVICT-STALE-DELAY ' "$OUT/${n}_cg1.txt") ($OUT/${n}_cg1.txt)"
        grep -a -m3 'P-CR63-IGRAB-FAIL \|P-CR3-CANCEL' "$OUT/${n}_cg1.txt" | cut -c1-300
        tot_cgl=$((tot_cgl + cgl)); tot_cgl0=$((tot_cgl0 + cgl0)); tot_cgrl=$((tot_cgrl + cgrl))
        tot_cgrbad=$((tot_cgrbad + cgrbad)); tot_cgc=$((tot_cgc + cgc)); tot_cgcause=$((tot_cgcause + cgcause))
        [ -n "$cgm" ] && [ "$cgm" -gt "$cgmax" ] && cgmax=$cgm
        [ "$cgm1" -gt "$cgmax1" ] && cgmax1=$cgm1
    fi
    if [ -n "$UB1" ]; then
        # the H-UB1 lines: each never-copied-in logged slot a partial cluster
        # write met, and the clobber check's lines around them
        zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
            | grep -a 'P-UB1-UNSTAGED-SKIP \|P-DINO-CLOBBER' > "$OUT/${n}_ub1.txt"
        ubl=$(grep -ac 'P-UB1-UNSTAGED-SKIP ' "$OUT/${n}_ub1.txt")
        ubm=$(grep -a 'P-UB1-UNSTAGED-SKIP ' "$OUT/${n}_ub1.txt" | grep -ac ' masked=1 ')
        echo "$n never-copied-in slot lines: found=$ubl masked=$ubm clobber_lines=$(grep -ac 'P-DINO-CLOBBER' "$OUT/${n}_ub1.txt") ($OUT/${n}_ub1.txt)"
        grep -a -m3 'P-UB1-UNSTAGED-SKIP ' "$OUT/${n}_ub1.txt" | cut -c1-300
        tot_ubl=$((tot_ubl + ubl)); tot_ubm=$((tot_ubm + ubm))
    fi
    if [ -n "$NR1" ]; then
        # the H-NR1 lines: each release that left a cached grant, each recycle
        # that consumed its mark, each slot written with bytes copied in before
        # that recycle, and the clobber check's lines around them
        zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
            | grep -a 'P-NOINO-UNLOCK-LEFT-GRANT \|P-RECYCLE-RELEASED-\|P-LOGWR-RELMARK-WRITTEN \|P-DINO-CLOBBER' > "$OUT/${n}_nr1.txt"
        nrwl=$(grep -ac 'P-LOGWR-RELMARK-WRITTEN ' "$OUT/${n}_nr1.txt")
        nrws=$(grep -a 'P-LOGWR-RELMARK-WRITTEN ' "$OUT/${n}_nr1.txt" | grep -ac ' staged=1 ')
        echo "$n release-mark lines: left_grant=$(grep -ac 'P-NOINO-UNLOCK-LEFT-GRANT ' "$OUT/${n}_nr1.txt") reset=$(grep -ac 'P-RECYCLE-RELEASED-RESET ' "$OUT/${n}_nr1.txt") keep=$(grep -ac 'P-RECYCLE-RELEASED-KEEP ' "$OUT/${n}_nr1.txt") written=$nrwl written_staged=$nrws clobber_lines=$(grep -ac 'P-DINO-CLOBBER' "$OUT/${n}_nr1.txt") ($OUT/${n}_nr1.txt)"
        grep -a -m3 'P-RECYCLE-RELEASED-\|P-LOGWR-RELMARK-WRITTEN ' "$OUT/${n}_nr1.txt" | cut -c1-300
        tot_nrwl=$((tot_nrwl + nrwl)); tot_nrws=$((tot_nrws + nrws))
    fi
    # the dirty-corpse wait's lines, and what follows a reset of a dirty corpse
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
        | grep -a 'P-RECYCLE-DIRTY-WAIT \|P-RECYCLE-DIRTY-KEEP \|P-RECYCLE-WAITED \|P-RECYCLE-RESET-UNDER-NOINO \|P119-NONEX-FLUSH-SKIP \|P383-HOME-VS-OWED \|P228-RELBAR-DEFER \|P-INODE-WEDGE ' > "$OUT/${n}_dirtywait.txt"
    dcov=$(grep -a 'P-RECYCLE-RESET-UNDER-NOINO ' "$OUT/${n}_dirtywait.txt" | grep -ac ' owes=1 at_start=0 ')
    dunc=$(grep -a 'P-RECYCLE-RESET-UNDER-NOINO ' "$OUT/${n}_dirtywait.txt" | grep -ac ' owes=1 at_start=1 ')
    tot_dcov=$((tot_dcov + dcov)); tot_dunc=$((tot_dunc + dunc))
    echo "$n dirtywait lines: wait=$(grep -ac 'P-RECYCLE-DIRTY-WAIT ' "$OUT/${n}_dirtywait.txt") keep=$(grep -ac 'P-RECYCLE-DIRTY-KEEP ' "$OUT/${n}_dirtywait.txt") waited=$(grep -ac 'P-RECYCLE-WAITED ' "$OUT/${n}_dirtywait.txt") reset=$(grep -ac 'P-RECYCLE-RESET-UNDER-NOINO ' "$OUT/${n}_dirtywait.txt") reset_dirty_covered=$dcov reset_dirty_uncovered=$dunc p119=$(grep -ac 'P119-NONEX-FLUSH-SKIP ' "$OUT/${n}_dirtywait.txt") relbar_defer=$(grep -ac 'P228-RELBAR-DEFER ' "$OUT/${n}_dirtywait.txt")"
    grep -a -m3 'P-RECYCLE-DIRTY-WAIT \|P-RECYCLE-DIRTY-KEEP \|owes=1 ' "$OUT/${n}_dirtywait.txt" | cut -c1-300
    # the free-publication handoff check (dbg_freepub_handoff_check=1 at
    # module load, MXFS_EXTRA_MODARGS): its lines after this lap's mark
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
        | grep -a 'P-FREEPUB-HANDOFF-' > "$OUT/${n}_handoff.txt"
    echo "$n handoff check: live=$(grep -ac 'P-FREEPUB-HANDOFF-LIVE ' "$OUT/${n}_handoff.txt") late=$(grep -ac 'P-FREEPUB-HANDOFF-LATE ' "$OUT/${n}_handoff.txt") $(grep -a 'P-FREEPUB-HANDOFF-TOTALS' "$OUT/${n}_handoff.txt" | tail -1 | sed 's/.*TOTALS //; s/ --.*//')"
    # every P5F keep and refusal of the protective reload (H-F8), whole
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
        | grep -a 'P5F-FRESHSRC-' > "$OUT/${n}_p5f.txt"
    echo "$n p5f lines: keep=$(grep -ac 'P5F-FRESHSRC-SELFCLOBBER-SKIP ' "$OUT/${n}_p5f.txt") keep_clean=$(grep -ac 'P5F-FRESHSRC-SELFCLOBBER-SKIP .*clean_held=1 ' "$OUT/${n}_p5f.txt") refused=$(grep -ac 'P5F-FRESHSRC-CLEAN-REFUSED ' "$OUT/${n}_p5f.txt")"
    # every P116 keep, refusal and zombie adopt of the self-clobber guard (H-F8b)
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
        | grep -a 'P116-RELOAD-SELFCLOBBER-SKIP \|P116-CLEAN-REFUSED \|P116-ZOMBIE-ADOPT ' > "$OUT/${n}_p116.txt"
    echo "$n p116 lines: keep=$(grep -ac 'P116-RELOAD-SELFCLOBBER-SKIP ' "$OUT/${n}_p116.txt") keep_clean=$(grep -ac 'P116-RELOAD-SELFCLOBBER-SKIP .*clean_held=1 ' "$OUT/${n}_p116.txt") refused=$(grep -ac 'P116-CLEAN-REFUSED ' "$OUT/${n}_p116.txt") zombie_adopt=$(grep -ac 'P116-ZOMBIE-ADOPT ' "$OUT/${n}_p116.txt")"
    # the local-unlink epoch guard's verdicts, and every write staged and
    # written at NL (ng0rf1's corrupting write was the lap's only one)
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
        | grep -a 'P-INACT-LOCAL-EPOCH \|P219-LOGGED-NO-AUTHORITY.* dlm_mode=0 stage_mode=0 ' > "$OUT/${n}_inact_local.txt"
    # ng0rf1's write was staged outside any release flush (relflush=0
    # demoter=0); a demoter's own release flush of a directory also stages
    # and writes at NL and is the release working, not that shape
    nls=$(grep -a 'P219-LOGGED-NO-AUTHORITY' "$OUT/${n}_inact_local.txt" | grep -ac ' relflush=0 demoter=0 ')
    tot_nls=$((tot_nls + nls))
    echo "$n epoch verdicts: $(grep -ao 'verdict=[a-z-]*' "$OUT/${n}_inact_local.txt" | sort | uniq -c | tr -s ' ' | paste -sd' ') nl_staged=$nls"
    grep -a -m3 'P219-LOGGED-NO-AUTHORITY' "$OUT/${n}_inact_local.txt" | cut -c1-300
    # H-F11: every free's flush that classified on the platter because its slot
    # held a staged image, every restore of such a slot to the platter's bytes,
    # and every allocator quarantine of a live core under a free inobt bit
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
        | grep -a 'P55C-HOME-PLATTER \|P55C-HOME-RESTORED \|P-DIALLOC-DISKLIVE ' > "$OUT/${n}_p55c.txt"
    xhp=$(grep -ac 'P55C-HOME-PLATTER ' "$OUT/${n}_p55c.txt")
    xlf=$(grep -a 'P55C-HOME-PLATTER ' "$OUT/${n}_p55c.txt" | grep -a ' platter_mode=00 ' | grep -avc ' buf_mode=00 ')
    xrl=$(grep -ac 'P55C-HOME-RESTORED ' "$OUT/${n}_p55c.txt")
    xrlf=$(grep -a 'P55C-HOME-RESTORED ' "$OUT/${n}_p55c.txt" | grep -a ' platter_mode=00 ' | grep -avc ' buf_mode=00 ')
    xdl=$(grep -ac 'P-DIALLOC-DISKLIVE ' "$OUT/${n}_p55c.txt")
    tot_xhp=$((tot_xhp + xhp)); tot_xlf=$((tot_xlf + xlf)); tot_xrl=$((tot_xrl + xrl))
    tot_xrlf=$((tot_xrlf + xrlf)); tot_xdl=$((tot_xdl + xdl))
    echo "$n p55c lines: home_platter=$xhp live_over_free=$xlf restored=$xrl restored_live_over_free=$xrlf disklive=$xdl"
    grep -a -m3 'P55C-HOME-RESTORED \|P-DIALLOC-DISKLIVE ' "$OUT/${n}_p55c.txt" | cut -c1-300
    # H-F12: every publish drain that ran out its window, by scope (an AG
    # release's has parent=0, a directory's names the directory), the
    # unfinished workers an AG drain named (on their child under 1000 ms: a
    # chase; at least 2500 ms: a held wait), every bounded AG drain that left
    # newer children listed, and every release that went with a claim in
    # flight in its scope, by scope
    zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
        | grep -a 'P-PUB-DRAIN-TIMEOUT \|P-PUB-DRAIN-STUCK \|P-PUB-DRAIN-BOUND \|P-PUB-CLAIM-INFLIGHT-AT-RELEASE \|P-PUB-UNPUB-AT-UNLOCK \|P-AG-FENCE-ESCAPE ' > "$OUT/${n}_drain.txt"
    # H-F13: COMMITs the fence's window let through exposed, and how often a
    # peer asked this node for an AG after the mark (the peer-unlink reach)
    fnel=$(grep -ac 'P-AG-FENCE-ESCAPE ' "$OUT/${n}_drain.txt")
    agbx=$(zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" | grep -ac 'P12-AGBAST-RX ')
    tot_fnel=$((tot_fnel + fnel))
    [ "$n" = "$A" ] && agbast_a=$agbx
    echo "$n fence escapes: $fnel  AG BASTs received after the mark: $agbx"
    # H-F13b: stale BAST hints dropped at a fresh grant (both arms), and the
    # create sweep's contention backoff, whose sweep count grows without bound
    # while every owned AG is refused (jwf1)
    shint=$(zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" | grep -ac 'P12-STALE-HINT ')
    swl=$(zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" | grep -a 'P-DIALLOC-SWEEP-RETRY ' | tee "$OUT/${n}_sweep.txt" | wc -l)
    swm=$(grep -ao ' sweep=[0-9]*' "$OUT/${n}_sweep.txt" | cut -d= -f2 | sort -n | tail -1)
    tot_shint=$((tot_shint + shint)); tot_swl=$((tot_swl + swl))
    [ "${swm:-0}" -gt "$swmax" ] && swmax=${swm:-0}
    echo "$n stale hints: $shint  create sweep backoffs: $swl (highest sweep ${swm:-0})"
    # H-RT1: directory slots a cluster write dropped mid-release (state=3), dir
    # releases that unlocked with a committed change not durable, this node's
    # reloads that found its in-core fork ahead of the platter, and same-tenure
    # re-adds by a shortform merge
    if [ -n "$RTAUD" ]; then
        zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
            | grep -a 'P56-NL-LOGGED-DIR-SKIP \|P57-PREUNLOCK-DIRTY \|P3-REFUSE-OLDER-DISK \|P-SFM-READD-ALWAYS ' > "$OUT/${n}_relflush.txt"
        rt56=$(grep -a 'P56-NL-LOGGED-DIR-SKIP ' "$OUT/${n}_relflush.txt" | grep -ac ' state=3 ')
        rt57=$(grep -ac 'P57-PREUNLOCK-DIRTY ' "$OUT/${n}_relflush.txt")
        rt3r=$(grep -ac 'P3-REFUSE-OLDER-DISK ' "$OUT/${n}_relflush.txt")
        rtsf=$(grep -a 'P-SFM-READD-ALWAYS ' "$OUT/${n}_relflush.txt" | grep -ac ' peer_mod=0 ')
        tot_rt56=$((tot_rt56 + rt56)); tot_rt57=$((tot_rt57 + rt57)); tot_rt3r=$((tot_rt3r + rt3r)); tot_rtsf=$((tot_rtsf + rtsf))
        echo "$n relflush lines: p56_state3=$rt56 p57=$rt57 refuse_older=$rt3r readd_peer_mod0=$rtsf"
    fi
    # H-WW1: cluster writes whose submitted image is behind the platter for a
    # directory slot (P-DINO-CLOBBER with a mode=040 slot), by path; the
    # whole-write probe; and the merge's kept shortform images, behind or
    # ahead of the platter by changecount within one generation
    if [ -n "$IWW" ]; then
        zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
            | grep -a 'P-DINO-CLOBBER\|P-IWR-WHOLE \|P-CLMERGE-DIRAHEAD \|P218-RECOV-REFUSED ' > "$OUT/${n}_iwr.txt"
        wwrr=$(grep -ac 'P218-RECOV-REFUSED ' "$OUT/${n}_iwr.txt"); tot_wwrr=$((tot_wwrr + wwrr))
        wwcw=$(grep -a 'P-DINO-CLOBBER#[0-9]* path=whole ' "$OUT/${n}_iwr.txt" | grep -ac ' mode=040')
        wwcp=$(grep -a 'P-DINO-CLOBBER#[0-9]* path=partial ' "$OUT/${n}_iwr.txt" | grep -ac ' mode=040')
        wwp=$(grep -ac 'P-IWR-WHOLE ' "$OUT/${n}_iwr.txt")
        wwb=$(grep -a 'P-CLMERGE-DIRAHEAD ' "$OUT/${n}_iwr.txt" | awk '{ for (i = 1; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] } if (f["buf_gen"] != "" && f["buf_gen"] == f["disk_gen"] && f["buf_cc"] + 0 < f["disk_cc"] + 0) n++ } END { print n + 0 }')
        wwa=$(grep -a 'P-CLMERGE-DIRAHEAD ' "$OUT/${n}_iwr.txt" | awk '{ for (i = 1; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] } if (f["buf_gen"] != "" && f["buf_gen"] == f["disk_gen"] && f["buf_cc"] + 0 > f["disk_cc"] + 0) n++ } END { print n + 0 }')
        tot_wwcw=$((tot_wwcw + wwcw)); tot_wwcp=$((tot_wwcp + wwcp)); tot_wwp=$((tot_wwp + wwp)); tot_wwb=$((tot_wwb + wwb)); tot_wwa=$((tot_wwa + wwa))
        echo "$n whole-write lines: clobber_whole_dir=$wwcw clobber_partial_dir=$wwcp iwr_whole=$wwp ($(grep -ao 'P-IWR-WHOLE why=[a-z-]*' "$OUT/${n}_iwr.txt" | sort | uniq -c | awk '{printf "%s:%s ", $3, $1}')) dirahead_behind=$wwb dirahead_ahead=$wwa"
    fi
    dtag=$(grep -ac 'P-PUB-DRAIN-TIMEOUT parent=0 agno=[0-9]' "$OUT/${n}_drain.txt")
    dtdir=$(grep -ac 'P-PUB-DRAIN-TIMEOUT parent=[1-9]' "$OUT/${n}_drain.txt")
    stc=$(grep -a 'P-PUB-DRAIN-STUCK parent=0 agno=[0-9]' "$OUT/${n}_drain.txt" | grep -ao ' age_ms=[0-9]*' | cut -d= -f2 | awk '$1 < 1000' | wc -l)
    sth=$(grep -a 'P-PUB-DRAIN-STUCK parent=0 agno=[0-9]' "$OUT/${n}_drain.txt" | grep -ao ' age_ms=[0-9]*' | cut -d= -f2 | awk '$1 >= 2500' | wc -l)
    bnd=$(grep -ac 'P-PUB-DRAIN-BOUND ' "$OUT/${n}_drain.txt")
    pcag=$(grep -a 'P-PUB-CLAIM-INFLIGHT-AT-RELEASE parent=0 agno=[0-9]' "$OUT/${n}_drain.txt" | grep -avc ' outcome=waited ')
    pcdir=$(grep -a 'P-PUB-CLAIM-INFLIGHT-AT-RELEASE parent=[1-9]' "$OUT/${n}_drain.txt" | grep -avc ' outcome=waited ')
    tot_dtag=$((tot_dtag + dtag)); tot_dtdir=$((tot_dtdir + dtdir)); tot_stc=$((tot_stc + stc)); tot_sth=$((tot_sth + sth))
    tot_bnd=$((tot_bnd + bnd)); tot_pcag=$((tot_pcag + pcag)); tot_pcdir=$((tot_pcdir + pcdir))
    echo "$n drain lines: timeout_ag=$dtag timeout_dir=$dtdir stuck_chase=$stc stuck_held=$sth stuck_all=$(grep -ac 'P-PUB-DRAIN-STUCK ' "$OUT/${n}_drain.txt") bound=$bnd inflight_rel_ag=$pcag inflight_rel_dir=$pcdir"
    grep -a -m6 'P-PUB-DRAIN-TIMEOUT \|P-PUB-DRAIN-STUCK ' "$OUT/${n}_drain.txt" | cut -c1-300
    grep -a -m2 'P-PUB-DRAIN-BOUND ' "$OUT/${n}_drain.txt" | cut -c1-300
    # the handoff exposure: AG releases that unlocked with unpublished inodes
    # of the AG still listed or a claim of one in flight, and those fields
    # summed over them; the unmount's lines apart
    uxu=$(grep -ac 'P-PUB-UNPUB-AT-UNLOCK agno=[0-9]* site=ag-bast ' "$OUT/${n}_drain.txt")
    uxum=$(grep -ac 'P-PUB-UNPUB-AT-UNLOCK agno=[0-9]* site=unmount ' "$OUT/${n}_drain.txt")
    read -r uxlst uxunl uxinf <<< "$(grep -a 'P-PUB-UNPUB-AT-UNLOCK agno=[0-9]* site=ag-bast ' "$OUT/${n}_drain.txt" \
        | awk '{ for (i = 1; i <= NF; i++) { split($i, kv, "="); if (kv[1] == "listed") l += kv[2]; else if (kv[1] == "unlinked") u += kv[2]; else if (kv[1] == "inflight") f += kv[2] } } END { printf "%d %d %d\n", l, u, f }')"
    tot_uxu=$((tot_uxu + uxu)); tot_uxum=$((tot_uxum + uxum))
    tot_uxlst=$((tot_uxlst + uxlst)); tot_uxunl=$((tot_uxunl + uxunl)); tot_uxinf=$((tot_uxinf + uxinf))
    echo "$n unlock exposure: ag_unlocks=$uxu listed=$uxlst unlinked=$uxunl inflight=$uxinf unmount_lines=$uxum"
    grep -a -m3 'P-PUB-UNPUB-AT-UNLOCK ' "$OUT/${n}_drain.txt" | cut -c1-300
    if [ "$MCHECK" = 1 ]; then
        # the H-F7 lines after this lap's mark, kept whole
        zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | sed -n "/$MARK/,\$p" \
            | grep -a 'P-RECYCLE-KEEP-UNDER-NOINO \|P-NOINO-UNLOCK-LEFT-GRANT \|P-LOG-MIRROR-PHANTOM \|P-NOINO-UNLOCK-UNDRAINED \|P-RECYCLE-RESET-UNDER-NOINO \|P-NOINO-RECYCLE-REDRIVE \|P-LOGWR-DLM-NOGRANT \|P-DIALLOC-RESV-UNDER-NOINO \|P-DIALLOC-NOINO-SKIP \|P-FREE-RELEASE \|P-NOINO-LIVE-SHELL \|P-PUB-CLAIM-INFLIGHT-AT-RELEASE \|P-PUB-CLAIM-WRITE-MASKED ' > "$OUT/${n}_hf7.txt"
        echo "$n hf7 lines: keep=$(grep -ac 'P-RECYCLE-KEEP-UNDER-NOINO ' "$OUT/${n}_hf7.txt") left=$(grep -ac 'P-NOINO-UNLOCK-LEFT-GRANT ' "$OUT/${n}_hf7.txt") left_live=$(grep -ac 'P-NOINO-UNLOCK-LEFT-GRANT .*lifecycle=LIVE ' "$OUT/${n}_hf7.txt") phantom=$(grep -ac 'P-LOG-MIRROR-PHANTOM ' "$OUT/${n}_hf7.txt") undrained=$(grep -ac 'P-NOINO-UNLOCK-UNDRAINED ' "$OUT/${n}_hf7.txt") reset=$(grep -ac 'P-RECYCLE-RESET-UNDER-NOINO ' "$OUT/${n}_hf7.txt") redrive=$(grep -ac 'P-NOINO-RECYCLE-REDRIVE ' "$OUT/${n}_hf7.txt") nogrant=$(grep -ac 'P-LOGWR-DLM-NOGRANT ' "$OUT/${n}_hf7.txt") live_shell=$(grep -ac 'P-NOINO-LIVE-SHELL ' "$OUT/${n}_hf7.txt") live_shell_unrouted=$(grep -ac 'P-NOINO-LIVE-SHELL .*routed=0 ' "$OUT/${n}_hf7.txt")"
        # H-F10: phantom and no-grant lines logged or written while a publish
        # claim on the inode was in flight (pub_inflight=1, sampled at the
        # print) or not, the phantom lines also by q_inflight (sampled before
        # the DLM was asked, the one that says whether a claim explains the
        # line), and every release that met a claim in flight in its scope, by
        # outcome
        echo "$n hf10 lines: phantom_inflight=$(grep -ac 'P-LOG-MIRROR-PHANTOM .* pub_inflight=1 ' "$OUT/${n}_hf7.txt") phantom_noinflight=$(grep -ac 'P-LOG-MIRROR-PHANTOM .* pub_inflight=0 ' "$OUT/${n}_hf7.txt") phantom_q_inflight=$(grep -ac 'P-LOG-MIRROR-PHANTOM .* q_inflight=1 ' "$OUT/${n}_hf7.txt") phantom_q_noinflight=$(grep -ac 'P-LOG-MIRROR-PHANTOM .* q_inflight=0 ' "$OUT/${n}_hf7.txt") nogrant_inflight=$(grep -ac 'P-LOGWR-DLM-NOGRANT .* pub_inflight=1 ' "$OUT/${n}_hf7.txt") nogrant_noinflight=$(grep -ac 'P-LOGWR-DLM-NOGRANT .* pub_inflight=0 ' "$OUT/${n}_hf7.txt") release_inflight=$(grep -ac 'P-PUB-CLAIM-INFLIGHT-AT-RELEASE ' "$OUT/${n}_hf7.txt") $(grep -ao 'P-PUB-CLAIM-INFLIGHT-AT-RELEASE .* outcome=[a-z-]*' "$OUT/${n}_hf7.txt" | grep -o 'outcome=[a-z-]*' | sort | uniq -c | tr -s ' ' | paste -sd' ')"
        # H-F10 write side: the no-grant lines written while a claim was in
        # flight (the hazard) and the cores the write guard kept back (its
        # reach), with how long each masked item had been held by its claim
        ngi=$(grep -ac 'P-LOGWR-DLM-NOGRANT .* pub_inflight=1 ' "$OUT/${n}_hf7.txt")
        wml=$(grep -ac 'P-PUB-CLAIM-WRITE-MASKED ' "$OUT/${n}_hf7.txt")
        tot_ngi=$((tot_ngi + ngi)); tot_wml=$((tot_wml + wml))
        echo "$n hf10 write side: nogrant_inflight=$ngi mask_lines=$wml masked_inodes=$(grep -ao 'P-PUB-CLAIM-WRITE-MASKED .* ino=[0-9]* ' "$OUT/${n}_hf7.txt" | grep -o 'ino=[0-9]*' | sort -u | wc -l) claim_ms_max=$(grep -ao 'P-PUB-CLAIM-WRITE-MASKED .* claim_ms=[0-9-]*' "$OUT/${n}_hf7.txt" | grep -o 'claim_ms=[0-9-]*' | cut -d= -f2 | sort -n | tail -1) claim_ms_over_1000=$(grep -ao 'P-PUB-CLAIM-WRITE-MASKED .* claim_ms=[0-9-]*' "$OUT/${n}_hf7.txt" | grep -o 'claim_ms=[0-9-]*' | cut -d= -f2 | awk '$1 > 1000' | wc -l)"
        for t in P-RECYCLE-KEEP-UNDER-NOINO P-NOINO-UNLOCK-LEFT-GRANT P-LOG-MIRROR-PHANTOM P-NOINO-UNLOCK-UNDRAINED P-RECYCLE-RESET-UNDER-NOINO P-NOINO-RECYCLE-REDRIVE P-LOGWR-DLM-NOGRANT P-NOINO-LIVE-SHELL P-PUB-CLAIM-INFLIGHT-AT-RELEASE P-PUB-CLAIM-WRITE-MASKED; do
            grep -a -m3 "$t " "$OUT/${n}_hf7.txt" | cut -c1-300
        done
    fi
done
# H-F11's chain, across every node: an allocator met a live core under a free
# inobt bit whose number and generation a P55C classification had named as its
# slot's staged image.  Two passes, so a quarantine on another node counts.
p55c_all=""
for n in $NODES; do p55c_all="$p55c_all $OUT/${n}_p55c.txt"; done
xchain=$(awk '
    NR == FNR { if ($0 ~ /P55C-HOME-PLATTER /) { i = ""; g = ""; for (k = 1; k <= NF; k++) { if ($k ~ /^ino=/) i = $k; if ($k ~ /^buf_gen=/) g = substr($k, 9) }; s[i ":" g] = 1 }; next }
    /P-DIALLOC-DISKLIVE / { i = ""; g = ""; for (k = 1; k <= NF; k++) { if ($k ~ /^ino=/) i = $k; if ($k ~ /^disk_gen=/) g = substr($k, 10) }; if ((i ":" g) in s) c++ }
    END { print c + 0 }' <(cat $p55c_all) <(cat $p55c_all))
echo "hf11 chain: $xchain of $tot_xdl quarantines follow a P55C platter classification of the same number and generation"
if [ -n "$CRDEF" ]; then
    crbad=${#nfail[@]}
    CRREP="cr63_defer=$CRDEF cr_deferred=$tot_crd cr_refused=$tot_crr cr_fall=$tot_crf cr_cancel=$tot_crc cr_disklive=$tot_crl audit=$audit node_failures=$crbad"
    if [ "$CRDEF" = 0 ]; then
        if [ "$tot_crf" = 0 ]; then
            cv=CVACUOUS
        elif [ "$crbad" -gt 0 ] && [ "$tot_crc" -gt 0 ]; then
            cv=CCONTROL-SHOWS-CAUSE
        else
            cv=CCONTROL-NO-SHUTDOWN
        fi
    elif [ "$tot_crd" = 0 ]; then
        cv=CVACUOUS
    else
        case "$audit" in CLEAN*) craok=1 ;; *) craok=0 ;; esac
        if [ "$tot_crr" = 0 ] && [ "$tot_crf" = 0 ] && [ "$tot_crc" = 0 ] && [ "$tot_crl" = 0 ] \
           && [ "$crbad" = 0 ] && [ "$craok" = 1 ]; then
            cv=CPASS
        else
            cv=CFAIL
        fi
    fi
    echo "CRESULT: $cv label=$LABEL $CRREP evidence=$OUT"
fi
if [ -n "$IWREF" ]; then
    wwbad=${#nfail[@]}
    WWREP="iwref=$IWREF ww_refused=$tot_wwr ww_empty=$tot_wwm ww_declined=$tot_wwd ww_early=$tot_wwe ww_clobber_whole_dir=$tot_wwcw ww_clobber_partial_dir=$tot_wwcp ww_recov_refused=$tot_wwrr audit=$audit node_failures=$wwbad"
    if [ "$IWREF" = 0 ]; then
        if [ "$tot_wwm" = 0 ]; then
            wv=WVACUOUS
        elif [ "$tot_wwcw" -gt 0 ]; then
            wv=WCONTROL-SHOWS-CAUSE
        else
            wv=WCONTROL-NO-CLOBBER
        fi
    elif [ "$tot_wwr" = 0 ]; then
        wv=WVACUOUS
    else
        case "$audit" in CLEAN*) wwaok=1 ;; *) wwaok=0 ;; esac
        if [ "$tot_wwm" = 0 ] && [ "$tot_wwd" = 0 ] && [ "$tot_wwcw" = 0 ] && [ "$tot_wwcp" = 0 ] \
           && [ "$tot_wwrr" = 0 ] && [ "$wwbad" = 0 ] && [ "$wwaok" = 1 ]; then
            wv=WPASS
        else
            wv=WFAIL
        fi
    fi
    echo "WRESULT: $wv label=$LABEL $WWREP evidence=$OUT"
fi
# run.sh's chk.log only names the audit's own log (evidence=, a path under the
# nodes' /src, which is this host's ~/src); the error lines and the unlinked
# bucket members are there.  It is kept here as chk_audit.log, CLEAN or not: a
# clean audit can still list bucket members.
alog=$(grep -ao 'evidence=/src/[^ ]*chk_clean_[0-9]*node_[0-9TZ]*\.log' "$OUT/chk.log" | head -1 | sed "s#^evidence=/src/#$HOME/src/#")
if [ -n "$alog" ] && [ -r "$alog" ]; then
    cp "$alog" "$OUT/chk_audit.log"
else
    echo "WARN the audit log named by $OUT/chk.log ('${alog:-none named}') is not readable here; no inode can be attributed"
fi
if [ -n "$RSR" ]; then
    rsbad=${#nfail[@]}
    case "$audit" in CLEAN*) rsaok=1 ;; *) rsaok=0 ;; esac
    rsflc=$(grep -ac 'P-FREE-LIVE-CORE' "$OUT/chk_audit.log" 2>/dev/null)
    RSREP="rsr=$RSR rs_disagree=$tot_rsd rs_lines=$tot_rsl rs_live_reuse=$tot_rsh free_live_core=${rsflc:-0} audit=$audit node_failures=$rsbad"
    if [ "$tot_rsh" = 0 ]; then
        sv=SVACUOUS
    elif [ "$RSR" = 0 ]; then
        if [ "${rsflc:-0}" -gt 0 ]; then sv=SCONTROL-SHOWS-CAUSE; else sv=SCONTROL-NO-CORRUPTION; fi
    elif [ "$rsbad" = 0 ] && [ "$rsaok" = 1 ]; then
        sv=SPASS
    else
        sv=SFAIL
    fi
    echo "SRESULT: $sv label=$LABEL $RSREP evidence=$OUT"
fi
if [ -n "$UPV" ]; then
    upbad=${#nfail[@]}
    case "$audit" in CLEAN*) upaok=1 ;; *) upaok=0 ;; esac
    UPREP="unlprev_verify=$UPV delay_ms=${UPD:-unset} moved=$tot_upm rebuilds=$tot_upr moved_lines=$tot_upml moved_freed=$tot_upmf rebuild_lines=$tot_uprl waits=$tot_upw p53=$tot_p53 p53_on_moved=$tot_p53m shutdowns=$tot_upsd audit=$audit node_failures=$upbad"
    if [ "$tot_upm" = 0 ]; then
        uv=UVACUOUS
    elif [ "$UPV" = 0 ]; then
        if [ "$tot_p53m" -gt 0 ]; then uv=UCONTROL-SHOWS-CAUSE; else uv=UCONTROL-NO-MISMATCH; fi
    elif [ "$tot_p53" = 0 ] && [ "$upbad" = 0 ] && [ "$upaok" = 1 ]; then
        uv=UPASS
    else
        uv=UFAIL
    fi
    echo "URESULT: $uv label=$LABEL $UPREP evidence=$OUT"
fi
if [ -n "$RS1" ]; then
    python3 tools/rs1_regress_attribution.py "$OUT" "$MARK" > "$OUT/rs1.txt" 2>&1
    rsl1=$(grep -a '^RS1 ' "$OUT/rs1.txt" | tail -1)
    [ -n "$rsl1" ] || { echo "RESULT: ABORT label=$LABEL -- tools/rs1_regress_attribution.py printed no RS1 line ($OUT/rs1.txt) evidence=$OUT"; exit 2; }
    grep -a '^RS1NODE \|^RS1REG \|^RS1PREV ' "$OUT/rs1.txt" | head -16 | cut -c1-240
    r1f() { echo "$rsl1" | grep -o " $1=[0-9]*" | cut -d= -f2; }
    rr_rs1=$(r1f rs1); rr_lu=$(r1f landed_unseen); rr_unl=$(r1f unlanded)
    rr_oth=$(r1f other_p219); rr_una=$(r1f unattributed); rr_cp=$(r1f clobber_partial)
    rrbad=${#nfail[@]}
    case "$audit" in CLEAN*) rraok=1 ;; *) rraok=0 ;; esac
    RRREP="rs1_skip=$RS1 found=$tot_rlc rs1_lines=$(r1f rs1_lines) masked=$(r1f rs1_masked) unmasked=$(r1f rs1_unmasked) p219_stale_rfdem=$(r1f p219_stale_rfdem) clobber_partial=$rr_cp regress_rs1=$rr_rs1 regress_landed_unseen=$rr_lu regress_unlanded=$rr_unl regress_other_p219=$rr_oth regress_unattributed=$rr_una prevented=$(r1f prevented) masked_other=$(r1f masked_other) masked_unnamed=$(r1f masked_unnamed) audit=$audit node_failures=$rrbad"
    if [ "$tot_rlc" = 0 ]; then
        rv=RVACUOUS
    elif [ "$RS1" = 0 ]; then
        if [ "${rr_rs1:-0}" -gt 0 ]; then rv=RCONTROL-SHOWS-CAUSE; else rv=RCONTROL-NO-REGRESS; fi
    elif [ "${rr_rs1:-0}" = 0 ] && [ "${rr_lu:-0}" = 0 ] && [ "$rrbad" = 0 ] && [ "$rraok" = 1 ]; then
        rv=RPASS
    else
        rv=RFAIL
    fi
    echo "RRESULT: $rv label=$LABEL $RRREP evidence=$OUT"
fi
if [ -n "$FA1" ]; then
    python3 tools/free_adopt_attribution.py "$OUT" "$MARK" > "$OUT/fa1.txt" 2>&1
    fal=$(grep -a '^FA ' "$OUT/fa1.txt" | tail -1)
    [ -n "$fal" ] || { echo "RESULT: ABORT label=$LABEL -- tools/free_adopt_attribution.py printed no FA line ($OUT/fa1.txt) evidence=$OUT"; exit 2; }
    grep -a '^FANODE \|^FAREG ' "$OUT/fa1.txt" | head -16 | cut -c1-240
    faf() { echo "$fal" | grep -o " $1=[0-9]*" | cut -d= -f2; }
    fa_fa1=$(faf fa1); fa_app=$(faf fa1_applied); fa_una=$(faf free_unattributed)
    fabad=${#nfail[@]}
    case "$audit" in CLEAN*) faaok=1 ;; *) faaok=0 ;; esac
    FAREP="free_adopt_core=$FA1 found=$tot_fac adopt_lines=$(faf adopt_lines) adopt_applied=$(faf adopt_applied) adopt_kept=$(faf adopt_kept) adopt_nlink_diff=$(faf adopt_nlink_diff) adopt_cc_diff=$(faf adopt_cc_diff) clobber_partial=$(faf clobber_partial) free_regress=$(faf free_regress) regress_fa1=$fa_fa1 regress_fa1_applied=$fa_app regress_free_unattributed=$fa_una regress_other=$(faf other_regress) audit=$audit node_failures=$fabad"
    if [ "$tot_fac" = 0 ]; then
        fav=AVACUOUS
    elif [ "$FA1" = 0 ]; then
        if [ "${fa_fa1:-0}" -gt 0 ]; then fav=ACONTROL-SHOWS-CAUSE; else fav=ACONTROL-NO-REGRESS; fi
    elif [ "${fa_fa1:-0}" = 0 ] && [ "${fa_app:-0}" = 0 ] && [ "$fabad" = 0 ] && [ "$faaok" = 1 ]; then
        fav=APASS
    else
        fav=AFAIL
    fi
    echo "ARESULT: $fav label=$LABEL $FAREP evidence=$OUT"
fi
if [ -n "$IFX" ]; then
    ixbad=${#nfail[@]}
    case "$audit" in CLEAN*) ixaok=1 ;; *) ixaok=0 ;; esac
    IXREP="ifree_defer_extend=$IFX bound_ms=${IFB:-default} found=$tot_ixc extended_lines=$tot_ixl landed=$tot_ixland fatal=$tot_ixfat audit=$audit node_failures=$ixbad"
    if [ "$tot_ixc" = 0 ]; then
        ixv=EVACUOUS
    elif [ "$IFX" = 0 ]; then
        if [ "$tot_ixfat" -gt 0 ]; then ixv=ECONTROL-SHOWS-CAUSE; else ixv=ECONTROL-NO-FATAL; fi
    elif [ "$tot_ixfat" = 0 ] && [ "$tot_ixland" = "$tot_ixl" ] && [ "$tot_ixl" -gt 0 ] && [ "$ixbad" = 0 ] && [ "$ixaok" = 1 ]; then
        ixv=EPASS
    else
        ixv=EFAIL
    fi
    echo "ERESULT: $ixv label=$LABEL $IXREP evidence=$OUT"
fi
if [ -n "$CGR" ]; then
    cgbad=${#nfail[@]}
    case "$audit" in CLEAN*) cgaok=1 ;; *) cgaok=0 ;; esac
    CGREP="cr63_igrab_retry=$CGR hold_ms=${CGD:-unset} failed=$tot_cgf retried=$tot_cgr evictions_held=$tot_cgd fail_lines=$tot_cgl retry0_lines=$tot_cgl0 retried_lookups=$tot_cgrl retried_not_rc0=$tot_cgrbad retried_max_ms=$cgmax igrab_retry_max_ms=$cgmax1 cancels=$tot_cgc control_chains=$tot_cgcause audit=$audit node_failures=$cgbad"
    if [ "$tot_cgf" = 0 ]; then
        cgv=GVACUOUS
    elif [ "$CGR" = 0 ]; then
        if [ "$tot_cgcause" -gt 0 ]; then cgv=GCONTROL-SHOWS-CAUSE; else cgv=GCONTROL-NO-CANCEL; fi
    elif [ "$tot_cgr" = "$tot_cgf" ] && [ "$tot_cgc" = 0 ] && [ "$tot_cgrbad" = 0 ] && [ "$cgbad" = 0 ] && [ "$cgaok" = 1 ] \
        && [ "$cgmax1" -le $(( ${CGD:-0} + 1000 )) ]; then
        # the retried create waits out the held teardown and no more: a wait
        # past the hold by over a second is something else holding it
        cgv=GPASS
    else
        cgv=GFAIL
    fi
    echo "GRESULT: $cgv label=$LABEL $CGREP evidence=$OUT"
fi
if [ -n "$UB1" ]; then
    ubbad=${#nfail[@]}
    case "$audit" in CLEAN*) ubaok=1 ;; *) ubaok=0 ;; esac
    UBREP="unstaged_logged_skip=$UB1 found=$tot_ubf prevented=$tot_ubp regressed=$tot_ubr found_lines=$tot_ubl masked_lines=$tot_ubm audit=$audit node_failures=$ubbad"
    if [ "$tot_ubf" = 0 ]; then
        ubv=BVACUOUS
    elif [ "$UB1" = 0 ]; then
        if [ "$tot_ubr" -gt 0 ]; then ubv=BCONTROL-SHOWS-CAUSE; else ubv=BCONTROL-NO-REGRESS; fi
    elif [ "$tot_ubr" = 0 ] && [ "$ubbad" = 0 ] && [ "$ubaok" = 1 ]; then
        ubv=BPASS
    else
        ubv=BFAIL
    fi
    echo "BRESULT: $ubv label=$LABEL $UBREP evidence=$OUT"
fi
if [ -n "$NR1" ]; then
    nrbad=${#nfail[@]}
    case "$audit" in CLEAN*) nraok=1 ;; *) nraok=0 ;; esac
    NRREP="noino_release_mark_honor=$NR1 reclaim_hold=${RHOLD:-unset} marked=$tot_nrm recycle_reset=$tot_nrr recycle_kept=$tot_nrk relmark_written=$tot_nrw relmark_regressed=$tot_nrg written_lines=$tot_nrwl written_staged_lines=$tot_nrws audit=$audit node_failures=$nrbad"
    if [ $((tot_nrr + tot_nrk)) = 0 ]; then
        nrv=NVACUOUS
    elif [ "$NR1" = 0 ]; then
        if [ "$tot_nrg" -gt 0 ]; then nrv=NCONTROL-SHOWS-CAUSE; else nrv=NCONTROL-NO-REGRESS; fi
    elif [ "$tot_nrk" = 0 ] && [ "$tot_nrws" = 0 ] && [ "$tot_nrg" = 0 ] && [ "$nrbad" = 0 ] && [ "$nraok" = 1 ]; then
        nrv=NPASS
    else
        nrv=NFAIL
    fi
    echo "NRESULT: $nrv label=$LABEL $NRREP evidence=$OUT"
fi
if_reach=0; if_fork=0; if_zomb=0; if_fatal=0; if_undr=0; if_unattr=0; if_rdone=0
if_igf=0; if_trans=0; if_kept=0; if_rt=0; if_zrt=0
if [ -n "$IDRAIN$IREAP" ]; then
    # the deferred frees' attribution: which audited inodes a deferral names
    python3 tools/ifree_defer_attribution.py "$OUT" "$MARK" > "$OUT/ifdefer.txt" 2>&1
    ifl=$(grep -a '^IFDEFER ' "$OUT/ifdefer.txt" | tail -1)
    [ -n "$ifl" ] || { echo "RESULT: ABORT label=$LABEL -- tools/ifree_defer_attribution.py printed no IFDEFER line ($OUT/ifdefer.txt) evidence=$OUT"; exit 2; }
    echo "ifdefer attribution: $ifl"
    grep -a '^NODE \|^UNATTRIBUTED ' "$OUT/ifdefer.txt" | head -12 | cut -c1-240
    if_reach=$(echo "$ifl" | grep -o ' reach=[0-9]*' | cut -d= -f2)
    if_fork=$(echo "$ifl" | grep -o ' fork_errors=[0-9]*' | cut -d= -f2)
    if_zomb=$(echo "$ifl" | grep -o ' zombies=[0-9]*' | cut -d= -f2)
    if_fatal=$(echo "$ifl" | grep -o ' fatal=[0-9]*' | cut -d= -f2)
    if_undr=$(echo "$ifl" | grep -o ' undrained=[0-9]*' | cut -d= -f2)
    if_unattr=$(echo "$ifl" | grep -o ' unattributed=[0-9]*' | cut -d= -f2)
    if_rdone=$(echo "$ifl" | grep -o ' reap_done=[0-9]*' | cut -d= -f2)
    if_igf=$(echo "$ifl" | grep -o ' igetfail=[0-9]*' | cut -d= -f2)
    if_trans=$(echo "$ifl" | grep -o ' transient=[0-9]*' | cut -d= -f2)
    if_kept=$(echo "$ifl" | grep -o ' kept=[0-9]*' | cut -d= -f2)
    if_rt=$(echo "$ifl" | grep -o ' retired_transient=[0-9]*' | cut -d= -f2)
    if_zrt=$(echo "$ifl" | grep -o ' zombie_retired_transient=[0-9]*' | cut -d= -f2)
fi
case "$audit" in
    CORRUPT*)
        # every stream line naming an inode the audit names, per node
        grep -a 'ERROR' "$OUT/chk_audit.log" 2>/dev/null | head -8 | cut -c1-240
        inos=$(cat "$OUT/chk.log" "$OUT/chk_audit.log" 2>/dev/null | grep -ao '(ino [0-9]*)' | tr -dc '0-9\n' | sort -u | paste -sd' ')
        echo "audited inodes: ${inos:-none parsed}"
        for n in $NODES; do
            : > "$OUT/${n}_audited_inos.txt"
            for i in $inos; do
                zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | grep -a "ino=$i \|ino=$i\$" >> "$OUT/${n}_audited_inos.txt"
            done
            echo "$n audited-inode lines: $(wc -l < "$OUT/${n}_audited_inos.txt") ($OUT/${n}_audited_inos.txt)"
            # which known writer shape names each audited inode on this node
            for i in $inos; do
                echo "$n attrib ino=$i undrained=$(grep -ac "P-NOINO-UNLOCK-UNDRAINED ino=$i " "$OUT/${n}_hf7.txt" 2>/dev/null) live_shell=$(grep -ac "P-NOINO-LIVE-SHELL ino=$i " "$OUT/${n}_hf7.txt" 2>/dev/null) left_live=$(grep -a "P-NOINO-UNLOCK-LEFT-GRANT .*ino=$i " "$OUT/${n}_hf7.txt" 2>/dev/null | grep -ac 'lifecycle=LIVE ') zombie_adopt=$(grep -ac "P116-ZOMBIE-ADOPT ino=$i " "$OUT/${n}_p116.txt" 2>/dev/null) resv_under=$(grep -ac "P-DIALLOC-RESV-UNDER-NOINO ino=$i " "$OUT/${n}_hf7.txt" 2>/dev/null) nogrant=$(grep -ac "P-LOGWR-DLM-NOGRANT .* ino=$i " "$OUT/${n}_hf7.txt" 2>/dev/null) p5f_keep=$(grep -ac "P5F-FRESHSRC-SELFCLOBBER-SKIP ino=$i " "$OUT/${n}_p5f.txt" 2>/dev/null) p116_keep_clean=$(grep -a "P116-RELOAD-SELFCLOBBER-SKIP ino=$i " "$OUT/${n}_p116.txt" 2>/dev/null | grep -ac 'clean_held=1 ') nl_staged=$(grep -a "P219-LOGGED-NO-AUTHORITY.* ino=$i " "$OUT/${n}_inact_local.txt" 2>/dev/null | grep -ac ' relflush=0 demoter=0 ') claim_at_release=$(grep -ac "P-PUB-CLAIM-INFLIGHT-AT-RELEASE .* child=$i " "$OUT/${n}_hf7.txt" 2>/dev/null) phantom_inflight=$(grep -a "P-LOG-MIRROR-PHANTOM ino=$i " "$OUT/${n}_hf7.txt" 2>/dev/null | grep -ac ' pub_inflight=1 ') nogrant_inflight=$(grep -a "P-LOGWR-DLM-NOGRANT .* ino=$i " "$OUT/${n}_hf7.txt" 2>/dev/null | grep -ac ' pub_inflight=1 ')"
            done
        done
        lun=$(tools/lun_pool.sh lookup --nodes "$(echo $NODES | tr ' ' ',')" | sed -n 's/.* id=\([0-9]*\) .*/\1/p')
        snap=$([ -n "$lun" ] && tools/lun_pool.sh snapshot "$lun" "$GROUP-noino-gen0-$LABEL") \
            && echo "image kept: $snap" || echo "image NOT kept: no pool LUN bound to [$NODES]" ;;
esac

bad=${#nfail[@]}
IREP="inact_guard=${IGUARD:-default} inact_moved=$tot_im inact_peerfreed=$tot_ipf nl_staged=$tot_nls"
[ -n "$DWAIT" ] && IREP="$IREP dwait=$DWAIT dw_waits=$tot_dw dw_rounds=$tot_dwr dw_kept=$tot_dk dw_waited_reset=$tot_dwz dw_hazard=$tot_dhz dw_reset_dirty=$tot_drd dw_covered=$tot_dcov dw_uncovered=$tot_dunc"
[ "$MCHECK" = 1 ] && IREP="$IREP rguard=${RGUARD:-default} hf7_keep=$tot_hk hf7_left=$tot_hl hf7_phantom=$tot_hp hf7_undrained=$tot_hu hf7_reset=$tot_hr hf7_redrive=$tot_hd hf7_nogrant=$tot_hn"
[ -n "$FGUARD" ] && IREP="$IREP fguard=$FGUARD fk_clean=$tot_fk fk_refused=$tot_fr"
[ -n "$SGUARD" ] && IREP="$IREP sguard=$SGUARD sc_clean=$tot_sk sc_refused=$tot_sr"
[ -n "$VGUARD" ] && IREP="$IREP vguard=$VGUARD rv_under=$tot_vu rv_skipped=$tot_vs"
[ -n "$HGUARD" ] && IREP="$IREP hguard=$HGUARD live_shell=$tot_zl shell_routed=$tot_zr"
[ -n "$CGUARD" ] && IREP="$IREP cguard=$CGUARD pc_inflight_rel=$tot_ci pc_rel_waited=$tot_cw pc_delay_ms=${CDELAY:-0} parent_delay_ms=${PDELAY:-0} nogrant_inflight=$tot_ngi"
[ -n "$WGUARD" ] && IREP="$IREP wguard=$WGUARD pw_masked=$tot_wm pw_mask_lines=$tot_wml"
IREP="$IREP p55_home_platter=$tot_xhp p55_live_over_free=$tot_xlf p55_restored=$tot_xrl p55_restored_lof=$tot_xrlf disklive=$tot_xdl hf11_chain=$xchain"
[ -n "$XGUARD" ] && IREP="$IREP xguard=$XGUARD p55_restored_counter=$tot_xr"
[ -n "$IDRAIN$IREAP" ] && IREP="$IREP idrain=${IDRAIN:-default} ireap=${IREAP:-default} if_reach=$if_reach if_dirty=$tot_ifd if_drained=$tot_ifdr if_unlanded=$tot_ifu if_reaps=$tot_ifr if_fork_errors=$if_fork if_zombies=$if_zomb if_unattributed=$if_unattr if_undrained=$if_undr if_reap_done=$if_rdone if_igetfail=$if_igf if_transient=$if_trans if_kept=$if_kept if_retired_transient=$if_rt if_zombie_retired_transient=$if_zrt"
[ -n "$RKEEP" ] && IREP="$IREP rkeep=$RKEEP rk_transient=$tot_rkt rk_retired=$tot_rkr"
IREP="$IREP dt_ag=$tot_dtag dt_dir=$tot_dtdir stuck_chase=$tot_stc stuck_held=$tot_sth pc_rel_ag=$tot_pcag pc_rel_dir=$tot_pcdir"
[ -n "$DBOUND" ] && IREP="$IREP dbound=$DBOUND db_left=$tot_dbl db_lines=$tot_bnd ux_unlocks=$tot_uxu ux_listed=$tot_uxlst ux_unlinked=$tot_uxunl ux_inflight=$tot_uxinf ux_unmount=$tot_uxum ux_exposed_counter=$tot_uxe ux_listed_counter=$tot_uxl lookup_hold_ms=$LHOLD"
[ -n "$IFENCE" ] && IREP="$IREP ifence=$IFENCE fn_refused=$tot_fnr fn_held=$tot_fnh fn_escaped=$tot_fne fn_escape_lines=$tot_fnel stale_hints=$tot_shint sweep_lines=$tot_swl sweep_max=$swmax"
[ -n "$FHEX" ] && IREP="$IREP fhex=$FHEX fh_passed=$tot_fhp fh_refused=$tot_fhr"
[ -n "$RTAUD" ] && IREP="$IREP rtaud=$RTAUD rt_kept=$tot_rtk rt_skip_demoting=$tot_rts rt_p56_dem_lines=$tot_rt56 rt_p57=$tot_rt57 rt_refuse_older=$tot_rt3r rt_readd=$tot_rtsf"
[ -n "$IWW" ] && IREP="$IREP iww=$IWW ww_early=$tot_wwe ww_noskip=$tot_wwn ww_empty=$tot_wwm ww_declined=$tot_wwd ww_clobber_whole_dir=$tot_wwcw ww_clobber_partial_dir=$tot_wwcp ww_probe=$tot_wwp ww_dirahead_behind=$tot_wwb ww_dirahead_ahead=$tot_wwa"
[ -n "$IWREF" ] && IREP="$IREP iwref=$IWREF ww_refused=$tot_wwr ww_recov_refused=$tot_wwrr"
[ "$PUNL" -gt 0 ] && IREP="$IREP punl=$PUNL punl_created=${punl_created:-?} punl_removed=${punl_removed:-?} agbast_a=$agbast_a"
# a CORRUPT cold audit or a node failure is graded below whatever the lap's
# reach: corruption found by a lap that missed the path it was aimed at is
# still corruption on this build
case "$audit" in CORRUPT*) graded=1 ;; *) graded=0 ;; esac
[ "$bad" = 0 ] || graded=1
if [ "$graded" = 1 ]; then
    :
elif [ -n "$DBOUND" ]; then
    # the lap measures H-F12: its reach is an AG release's drain meeting the
    # children its node created in that AG while it ran, chased until its
    # window ran out (control) or bounded and left listed (fix); a fix lap's
    # AG drain timeout is reach too, and fails it below
    if [ "$DBOUND" = 0 ]; then
        [ "$tot_dtag" -gt 0 ] || { echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit node_failures=$bad -- no AG release drain ran out its window (control arm did not reach H-F12) evidence=$OUT"; exit 3; }
    else
        [ $((tot_dbl + tot_dtag)) -gt 0 ] || { echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit node_failures=$bad -- no bounded AG release drain left a newer child listed (fix arm did not reach H-F12) evidence=$OUT"; exit 3; }
    fi
elif [ -n "$IDRAIN$IREAP" ]; then
    # the lap measures the deferred-free fixes: its reach is a free deferred
    # by the unlinked-list preflight or the predecessor's hold, on either node
    [ "$if_reach" -gt 0 ] || { echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit node_failures=$bad -- no inode free was deferred on either node (the lap did not reach the deferred-free path) evidence=$OUT"; exit 3; }
elif [ -n "$DWAIT" ]; then
    # the lap measures the dirty-corpse wait: its reach is a recycle meeting a
    # corpse that owes the platter a change under a tracked in-flight release,
    # reset (control) or made to wait or keep its grant (fix)
    if [ "$DWAIT" = 0 ]; then
        [ $((tot_dhz + tot_drd)) -gt 0 ] || { echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit node_failures=$bad -- no recycle met a dirty corpse under an in-flight no-inode release (control arm did not reach the dirty-corpse wait) evidence=$OUT"; exit 3; }
    else
        [ $((tot_dw + tot_dk)) -gt 0 ] || { echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit node_failures=$bad -- no recycle waited for, or kept the grant of, a dirty corpse under an in-flight no-inode release (fix arm did not reach the dirty-corpse wait) evidence=$OUT"; exit 3; }
    fi
elif [ -n "$XGUARD" ]; then
    # the lap measures H-F11: its reach is a free's flush classifying on the
    # platter because its slot holds a live staged image over a free platter,
    # left in the slot (control) or put back to the platter's bytes (fix)
    if [ "$XGUARD" = 0 ]; then
        [ "$tot_xlf" -gt 0 ] || { echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit -- no free's flush met a live staged slot over a free platter (control arm did not reach H-F11) evidence=$OUT"; exit 3; }
    else
        [ "$tot_xrlf" -gt 0 ] || { echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit -- no live staged slot over a free platter was put back to the platter's bytes (fix arm did not reach H-F11) evidence=$OUT"; exit 3; }
    fi
elif [ -n "$WGUARD" ]; then
    # the lap measures H-F10's write side: its reach is a cluster write meeting
    # the live core of an inode whose publish claim is in flight, written
    # (control) or masked (fix)
    if [ "$WGUARD" = 0 ]; then
        [ "$tot_ngi" -gt 0 ] || { echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit -- no live core went home while its publish claim was in flight (control arm did not reach H-F10's write side) evidence=$OUT"; exit 3; }
    else
        [ "$tot_wm" -gt 0 ] || { echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit -- no live core was kept out of a cluster write for a publish claim in flight (fix arm did not reach H-F10's write side) evidence=$OUT"; exit 3; }
    fi
elif [ -n "$CGUARD" ]; then
    # the lap measures H-F10: its reach is a directory or AG release meeting a
    # publish claim in flight in its scope, let go (control) or held (fix)
    if [ "$CGUARD" = 0 ]; then
        [ "$tot_ci" -gt 0 ] || { echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit -- no release met a publish claim in flight in its scope (control arm did not reach H-F10) evidence=$OUT"; exit 3; }
    else
        [ "$tot_cw" -gt 0 ] || { echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit -- no release waited for a publish claim in its scope (fix arm did not reach H-F10) evidence=$OUT"; exit 3; }
    fi
elif [ -n "$HGUARD" ]; then
    # the lap measures H-F9: its reach is a BAST meeting a live in-core shell
    # holding a freed image, sent to the no-inode release (control) or routed
    # through the in-core release (fix)
    IREP="$IREP setattr_delay_ms=$SADELAY"
    if [ "$HGUARD" = 0 ]; then
        [ "$tot_zl" -gt 0 ] || { echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit -- no BAST met a live shell holding a freed image (control arm did not reach H-F9) evidence=$OUT"; exit 3; }
    else
        [ "$tot_zr" -gt 0 ] || { echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit -- no BAST for a live shell was routed through the in-core release (fix arm did not reach H-F9) evidence=$OUT"; exit 3; }
    fi
elif [ -n "$VGUARD" ]; then
    # the lap measures H-F7c: its reach is the allocator meeting a number
    # whose no-inode release is in flight, taken (control) or skipped (fix)
    IREP="$IREP postfence_ms=$PFENCE"
    if [ "$VGUARD" = 0 ]; then
        [ "$tot_vu" -gt 0 ] || { echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit -- no candidate was reserved or taken under an in-flight no-inode release (control arm did not reach H-F7c) evidence=$OUT"; exit 3; }
    else
        [ "$tot_vs" -gt 0 ] || { echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit -- no candidate was skipped for an in-flight no-inode release (fix arm did not reach H-F7c) evidence=$OUT"; exit 3; }
    fi
elif [ -n "$PFENCE" ]; then
    # the lap measures H-F7: its reach is the recycle meeting an in-flight
    # release, kept (control) or reset (fix)
    IREP="$IREP postfence_ms=$PFENCE"
    if [ "${RGUARD:-1}" = 0 ]; then
        [ "$tot_hk" -gt 0 ] || { echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit -- no recycle kept a grant under an in-flight no-inode release (control arm did not reach H-F7) evidence=$OUT"; exit 3; }
    else
        [ "$tot_hr" -gt 0 ] || { echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit -- no recycle reset a grant under an in-flight no-inode release (fix arm did not reach H-F7) evidence=$OUT"; exit 3; }
    fi
elif [ -n "$SADELAY" ]; then
    # the lap measures H-F8b: its reach is a reload meeting a clean held shell
    # over a FREE disk image, kept (control) or refused (fix)
    IREP="$IREP setattr_delay_ms=$SADELAY"
    if [ "$SGUARD" = 0 ]; then
        [ "$tot_sk" -gt 0 ] || { echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit -- no reload kept a clean held shell over a FREE disk image (control arm did not reach H-F8b) evidence=$OUT"; exit 3; }
    else
        [ "$tot_sr" -gt 0 ] || { echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit -- no reload refused a clean held shell over a FREE disk image (fix arm did not reach H-F8b) evidence=$OUT"; exit 3; }
    fi
elif [ "$tot_rel" = 0 ]; then
    echo "RESULT: VACUOUS noino_gen0_ab label=$LABEL guard=$GUARD delay_ms=$DELAY_MS $IREP audit=$audit node_failures=$bad -- no generation-0 no-inode release ran on either node evidence=$OUT"; exit 3
fi
if [ "$GUARD" = 0 ]; then
    v=CONTROL-NOT-REACHED; [ "$tot_live" -gt 0 ] && v=CONTROL-REACHED
    echo "RESULT: $v noino_gen0_ab label=$LABEL guard=0 delay_ms=$DELAY_MS gen0_releases=$tot_rel gen0_live=$tot_live $IREP audit=$audit node_failures=$bad evidence=$OUT"; exit 0
fi
case "$audit" in CLEAN*) aok=1 ;; *) aok=0 ;; esac
# under noino_recycle_guard (unset = its default, 1) no recycle keeps a grant a
# release will unlock, and no release unlocks over changes not on the platter
hf7_ok=1
if [ "$MCHECK" = 1 ] && [ "${RGUARD:-1}" = 1 ]; then
    [ "$tot_hk" = 0 ] && [ "$tot_hu" = 0 ] || hf7_ok=0
fi
IREP="$IREP hf7_ok=$hf7_ok"
# under freshsrc_keep_guard no protective reload keeps a clean shell's image
# over the platter's FREE image
fk_ok=1
[ "${FGUARD:-1}" = 1 ] && [ "$tot_fk" != 0 ] && fk_ok=0
IREP="$IREP fk_ok=$fk_ok"
# under selfclobber_keep_guard no reload keeps a clean held shell over a FREE
# disk image
sc_ok=1
[ "${SGUARD:-1}" = 1 ] && [ "$tot_sk" != 0 ] && sc_ok=0
IREP="$IREP sc_ok=$sc_ok"
# under noino_shell_guard every BAST that met a live shell reached the in-core
# release
hs_ok=1
[ "$HGUARD" = 1 ] && [ "$tot_zl" != "$tot_zr" ] && hs_ok=0
[ -n "$HGUARD" ] && IREP="$IREP hs_ok=$hs_ok"
# under pub_claim_release_guard no directory or AG release went with a publish
# claim in flight in its scope
pc_ok=1
[ "${CGUARD:-1}" = 1 ] && [ "$tot_ci" != 0 ] && pc_ok=0
[ -n "$CGUARD" ] && IREP="$IREP pc_ok=$pc_ok"
# under pub_claim_write_guard no live core went home while its publish claim
# was in flight
pw_ok=1
[ "$WGUARD" = 1 ] && [ "$tot_ngi" != 0 ] && pw_ok=0
[ -n "$WGUARD" ] && IREP="$IREP pw_ok=$pw_ok"
# under p55c_home_restore no slot a free's flush classified on the platter
# reached home with its staged image
p55_ok=1
[ "${XGUARD:-1}" = 1 ] && [ "$xchain" != 0 ] && p55_ok=0
IREP="$IREP p55_ok=$p55_ok"
# under noino_recycle_dirty_wait no recycle the change covers reset a corpse
# that still owed the platter a committed change
dw_ok=1
[ "${DWAIT:-1}" = 1 ] && [ "$tot_dcov" != 0 ] && dw_ok=0
IREP="$IREP dw_ok=$dw_ok"
# under ifree_defer_drain no deferred free's inode names blocks its truncate
# freed, and no drain failed closed; under ifree_defer_reap no zombie is left
# on its bucket
if_ok=1
if [ -n "$IDRAIN$IREAP" ]; then
    if [ "${IDRAIN:-1}" = 1 ]; then
        [ "$if_fork" = 0 ] && [ "$tot_ifu" = 0 ] && [ "$if_fatal" = 0 ] || if_ok=0
    fi
    [ "${IREAP:-1}" = 1 ] && [ "$if_zomb" != 0 ] && if_ok=0
    # under reap_transient_keep no entry was retired by a lookup that met its
    # zombie still in core in its inactivation
    [ "${IREAP:-1}" = 1 ] && [ "${RKEEP:-1}" = 1 ] && [ "$if_rt" != 0 ] && if_ok=0
    IREP="$IREP if_ok=$if_ok"
fi
# under pub_drain_bound 1 no AG release's publish drain ran out its window
db_ok=1
[ "$DBOUND" = 1 ] && [ "$tot_dtag" != 0 ] && db_ok=0
[ -n "$DBOUND" ] && IREP="$IREP db_ok=$db_ok"
if [ "$aok" = 1 ] && [ "$bad" = 0 ] && [ "$refuse_ok" = 1 ] && [ "$hf7_ok" = 1 ] && [ "$fk_ok" = 1 ] && [ "$sc_ok" = 1 ] && [ "$hs_ok" = 1 ] && [ "$pc_ok" = 1 ] && [ "$pw_ok" = 1 ] && [ "$p55_ok" = 1 ] && [ "$dw_ok" = 1 ] && [ "$if_ok" = 1 ] && [ "$db_ok" = 1 ]; then
    echo "RESULT: PASS noino_gen0_ab label=$LABEL guard=1 delay_ms=$DELAY_MS gen0_releases=$tot_rel gen0_live=$tot_live $IREP audit=$audit evidence=$OUT"; exit 0
fi
echo "RESULT: FAIL noino_gen0_ab label=$LABEL guard=1 delay_ms=$DELAY_MS gen0_releases=$tot_rel gen0_live=$tot_live refused_all=$refuse_ok $IREP audit=$audit node_failures=$bad evidence=$OUT"; exit 1
