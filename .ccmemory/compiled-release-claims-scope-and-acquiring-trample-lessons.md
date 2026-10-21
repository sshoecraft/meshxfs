---
name: compiled-release-claims-scope-and-acquiring-trample-lessons
description: Release-claims corrections from 0.90.132 (narrowing claims is no mitigation; unsupported-setup issues don't drop claims) plus the i_dlm_state ACQUIRI…
metadata:
  type: feedback
tags: [compiled, release, claims, drbd, ilock, dlm, trap]
---

Assorted group (loose fit): two owner corrections on what a release claims (both 2026-10-21, 0.90.132) and one DLM trap found in that same release.

## Release claims: narrowing the table is not mitigation

Source: `feedback-narrowing-the-claims-table-does-not-protect-users-on-the-default-path`

Owner correction, 2026-10-21. A session recommended publishing 0.90.132 with 4/8/16 net/mesh left out of its claims while D-TCP-4NODE-NOQUEUE-TRY-WAITS-9S-ON-FULL-LEDGER-PAGE-CREATES-STALL (a stability defect, fix in the build but unverified) was open, and verifying them for a later release. Owner:

> "i dont think you understand human behaviour when it comes to establishing trust. so do you think they are going to look up their specific config to see if it's in RELEASE X tested config pages?"
> "the fact you make the recommendation means we need to step back and maybe establish some new rules regarding releases"

Why: the packages default to the network lock manager (force_transport=1). Anyone installing at 4+ nodes runs the unverified path whatever the README table says. A tester who hits the defect stops trusting the project; an "unclaimed" row prevents nothing.

How to apply:
- Never recommend shipping while a defect that crosses the release bar, or an unverified fix for one, reaches a configuration a default install runs. Verify it on the release build (or fix it) first, even if that delays the release.
- Leaving a configuration out of the claims is not mitigation; it is a gap that still has to be closed.
- The owner intends to discuss new release rules. Do not write any into CLAUDE.md until they say exactly what to write.

## Release claims: an unsupported-setup issue never drops a supported claim

Source: `feedback-unsupported-setup-issue-never-drops-a-supported-claim`

Owner correction, 2026-10-21, after a session moved 2/net/mesh/drbd out of 0.90.132's claims because the GitHub #3 record (DRBD survivor never mounts; the tester runs DRBD under Pacemaker/corosync with stonith) was open and counted against the configuration. Owner:

> "WAIT ... what??? no. it must be part of .132 ... also github #3 uses corosync and all that ... does DRBD work using our doc'd config?"
> "we may add support for issue #3 in the future but right now we have a supported configuration"

Why: a claim covers the documented setup (for DRBD: docs/drbd-setup.md, where `mxfs-drbd@` is the only thing bringing up or promoting DRBD, `drbd.service` is disabled, and there is no Pacemaker and no `become-primary-on`). A failure in a setup outside the docs says nothing about that claim unless reproduced on the documented setup.

How to apply:
- For an issue from a setup outside the docs, first ask whether the documented setup does the same thing, and measure it (for #3: tests/pve_pair_failover.sh p0-poweroff on the nested DRBD pair, where the survivor carried on).
- Keep the record open (it is still a user's report). Set its impact to noblock, with an impact-why naming the unsupported setup and the documented-setup measurement. Do not drop or narrow the configuration's claim.
- Support for that setup is future work, not a release gate.
- The claimed configuration still needs its own verification on the exact release build (tests/drbd_release_verify.sh <V> for 2/net/mesh/drbd).

## Trap: a release exit that writes i_dlm_state tramples ACQUIRING

Source: `trap-a-release-exit-that-writes-i-dlm-state-tramples-acquiring`

ACQUIRING is the ONLY thing that makes a node's other tasks wait for an in-flight slow-path acquire (mxfs_ilock_wait_for_transition). A release that ends by assigning `ip->i_dlm_state = NONE/CACHED/BAST` without looking at what is there tramples it.

Found in 0.90.132 (D-CC-16NODE-SYNCED-CREATE-NAME-LOST-INODE-DISCONNECTED): mxfs_bast_nl_entry_cleanup's orphan-only abort set NONE over ACQUIRING; md5sum's PR request then ran beside the shell's EX create, hit the node's own fresh EX as P-SELF-STALE-EDEADLK, and P109 released that grant as a "phantom". The shell then modified the directory under an EX already handed to another node; that node's write of the same dir block dropped the name.

How to apply:
- When reading/writing any i_dlm_state assignment in a release/abort/rescue path, ask whether an acquirer can have set ACQUIRING meanwhile. Gate on `i_dlm_acq_inflight > 0` (the untrampled count), not on state.
- P109's phantom test (ACQUIRING + mode NL) cannot tell its own stale entry from another local task's fresh grant; it is safe only while ACQUIRING serialization holds.
- Detector: P-ACQ-CONCURRENT (second slow-path acquire with acq_inflight>0). To read a loss: compare per-block P11-DATALOG placements vs final P68-EVDECIDE fcnt, and look for two nodes placing at the same off; P-DIRWR gmode<5 on a dir data write is the holder that lost its EX.
- `md5sum f | awk > f.md5` (crash_consistency) is a natural same-node PR+EX pair on one directory.
