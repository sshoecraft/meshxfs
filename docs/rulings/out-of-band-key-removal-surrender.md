# A departed node's key removed out of band: surrender by re-registration

Records: `D-OUT-OF-BAND-KEY-REMOVAL-AT-3-PLUS-NODES-FENCE-SERIES-STALLS-SURVIVORS-126S`,
`D-8NETMESH-RECOVERY-BLOCKED-LEAVES-QUEUED-SURVIVOR-ACQUIRES-PARKED-FOREVER`.

## The problem

Under WRITE EXCLUSIVE - ALL REGISTRANTS a member's key can leave the target without any MXFS fence
intent: an operator's `sg_persist --preempt`, or a plain PREEMPT from any other tool. A plain
PREEMPT removes the registration and aborts nothing, so commands the member's I_T nexuses had
already queued can still execute afterwards. The prover then finds the key absent with no ledger
entry naming a successor (`KEY_ABSENT_UNPROVEN`). At two nodes the sole-survivor gate certifies.
At three or more it cannot, the bounded series ends in `RECOVERY_BLOCKED` after
`fence_blocked_after_ms`, and the slice is never replayed until the PR state changes. Measured on
8/net/mesh/direct: 22 attempts over 126 s, survivors' operations parked over the 30 s stall limit.

## What the standards give (consulted 2026-10-24, claude-opus-5-5; gpt-6-astra out of credits)

- PREEMPT AND ABORT aborts every command in the task set of each I_T nexus whose registration it
  removes, with TST=1 (SPC-4 r37 5.12.11.5, "Preempting and aborting", by reference to SAM-4
  command abort). Abort scope is the I_T nexus, not the registration instance, so commands a nexus
  queued before an earlier plain PREEMPT are aborted too, if that nexus is registered again and
  then preempted with abort.
- REGISTER is allowed from an unregistered nexus under every reservation type, and nothing lets
  the device server refuse or defer it because older commands from that nexus are outstanding
  (5.12.7).
- The device server completes the PREEMPT AND ABORT only once the preempted commands are
  aborted; after GOOD status none of them transfers data or changes the medium (SAM-4 5.6).
- Each I_T nexus is registered separately. An iSCSI initiator with two sessions has two
  initiator ports, so a node must register again on every session it ever sent commands on, or
  use ALL_TG_PT=1 where the target reports ATP_C. One nexus left unregistered keeps its queued
  commands out of the abort.
- A LOGICAL UNIT RESET also ends every queued command, from every nexus, but aborts the other
  members' commands as well. On this target (SCST vdisk, TAS=0) those get no status and wait out
  their 30 s SCSI timeout. Making it harmless needs a cluster-wide I/O quiesce, which MXFS does
  not have.

## The design

A member that finds its own key gone (P277, then P290-AUTH-CLOSED reason=PR_CONFLICT_FENCED and
P131-SELF-FENCE) and is still running can make its own exclusion provable by the normal fence:

1. It stops every writer of its own first: the filesystem is shut down, the heartbeat has exited,
   the authority is closed, and nothing of MXFS's submits to the LUN any more. The authority-ledger
   publisher is NOT covered by the write gate today
   (`D-SELF-FENCED-NODE-LEDGER-PUBLISHER-RETRIES-FOREVER-ON-RESERVATION-CONFLICT`: 31,510 refused
   publishes after P290-AUTH-CLOSED). That record's fix is a precondition: re-registering before it
   would let those writes land.
2. It registers its recorded key again on every path of the logical unit (every I_T nexus it
   used), once per incarnation, and logs one line naming the key and each path.
3. It keeps that registration until it reads its key absent again (the survivors' PREEMPT AND
   ABORT), and does not unregister it at unmount before then. An unregister in that window would
   put the prover back at KEY_ABSENT_UNPROVEN.
4. The prover changes nothing. Its re-drive (backoff 0.25 to 6 s, then every 30 s once blocked)
   finds the key present and issues the usual PREEMPT AND ABORT, which certifies.

What this does not cover is a departed node that is not running, or not reachable to run step 2.
There the out-of-band removal stays `RECOVERY_BLOCKED` with fail-fast, as `docs/dlm-protocol.md`
"Recovery blocked on unprovable exclusion" describes, and the stall before the verdict is still
the series' length.

## Open

- How the departed node tells an out-of-band removal from a proper fence. After a peer's
  PREEMPT AND ABORT under a durable fence intent naming it, the exclusion is already proved, and
  a REGISTER would only leave a stray registration under a dead incarnation: the reason
  `mxfs_scsipr_fill_paths` (dlm/scsipr.c:187-195) registers only while the node still holds
  authority. The surrender has to read the fencing descriptor of its own slot first and
  re-register only when no fence intent names this incarnation, and never after a certificate
  for it exists.
- Whether the departed node's PR code can reach every path's nexus after its key was removed,
  and how it learns the set of nexuses it used (the PAL enumerates the logical unit's paths for
  the isolation check, `mxfs_pal_lu_paths_offline`).
- A same-build switch for the re-registration (off: today's behaviour), and a lap: the
  fenced-ledger rig lap's `INJECT=preempt` arm at 4 and 8 nodes, graded on certification and on
  every survivor operation ending inside the stall limit.
- The series length for `KEY_ABSENT_UNPROVEN` with the prover provably not sole, when the departed
  node does not surrender: retries cannot change it until the PR state does, so the fail-fast
  could start well inside the stall limit.
