# Quorum takeover: a third vote, and a loser that ends its own boot

Two nodes cannot tell a dead peer from a cut link. Every two-node attachment
MeshXFS has today answers that with something outside the pair that can act on
the victim: the storage (`scsipr`), the hypervisor (`vcenter`), an operator
(`manual`), or a fixed tie-break that only one side may win (the DRBD pair,
`docs/rulings/drbd-two-node-self-exclusion.md`). Each costs something:

- `scsipr` needs storage that forwards reservations intact, which a VMDK or a
  physical RDM does not (`docs/shared-disk-attachment.md`).
- `vcenter` puts a credential that can power VMs off on every node.
- `manual` stops recovery until a person answers.
- The DRBD tie-break cannot recover when participant 0 is the one that died
  (`D-DRBD-PAIR-NO-EXTERNAL-QUORUM-SO-P1-CANNOT-TAKE-OVER-WHEN-P0-DIES`).

This design adds a method that needs none of them: a third vote decides who may
carry on, and the node that loses the vote ends its own boot. Nothing outside
the pair is given the power to act on a node, and no node holds a credential to
anything but the vote.

It is the shape every two-node cluster stack converged on: Proxmox VE HA (three
votes with a QDevice, plus a self-fencing watchdog), OCFS2 (the losing half of a
split calls `emergency_restart()`), HP Serviceguard's quorum server.

## The vote

The third vote is corosync's `votequorum` with a QDevice: `corosync-qdevice` on
each node, `corosync-qnetd` on a third machine, algorithm `ffsplit`. MeshXFS
does not implement a vote protocol of its own; corosync's membership and
`ffsplit` already give the properties needed, and a Proxmox pair already runs
exactly this.

- **What `ffsplit` gives.** In a 50:50 split qnetd gives its vote to exactly one
  partition, so at most one side of the pair is quorate. A node that cannot
  reach qnetd and cannot see its peer holds 1 of 3 votes and is not quorate.
- **What the qnetd link can do.** It is authenticated by TLS certificates
  issued for the qdevice (`corosync-qdevice-net-certutil`). They grant a vote,
  nothing else: no power over any VM, host or disk.
- **Configuration that breaks it.** `two_node: 1` makes both halves of a split
  quorate. `auto_tie_breaker`
  is a second rule beside the vote and is not used. The quorum MeshXFS reads is
  the corosync cluster's, so on a Proxmox cluster of more than two hosts the
  pair's vote is the whole cluster's majority, which is still exactly one side.
- **Who is in the cluster.** Both MeshXFS nodes must be members of the same
  corosync cluster. On vSphere the two guests form a cluster of their own; on a
  Proxmox pair the hosts already are one.

A node's helper (`mxfs_quorumd`, `tools/mxfs_quorumd.py`, run by
`mxfs-quorumd.service`) asks votequorum four times a second
(`votequorum_getinfo` for this node and every node of the nodelist) and writes
one report per tick to `/proc/fs/mxfs/quorum`: whether this node is quorate,
whether its QDevice is registered, alive and voting, whether `two_node` is set,
the nodelist's addresses and which of them are members, and each member's
announced boot (below). It never reports quorate without votequorum having said
so in that tick: when it cannot ask, it reports inquorate.

**Boot announcements.** Each helper joins the CPG group `mxfs-boot` (corosync's
own authenticated messaging) and multicasts its host (`/etc/machine-id`) and
the boot it runs (`/proc/sys/kernel/random/boot_id`) when it joins, whenever a
node joins, and every few seconds. A member's announcement stands only while it
is a member. One kernel runs on a machine, so a member announcing a later boot
of a host ends every earlier boot of it. This is what lets a survivor finish a
takeover when the loser reset and came back within the bound: its absence was
too short to prove anything, but its new boot is a fact.

## The method: `fence=quorum`

On the shared attachment it is a value of the existing option, beside `manual`
and `vcenter`, with the same requirements: the TCP transport and
`peers=<this>/<other>`. On the DRBD pair it replaces the fixed tie-break as the
fence authority, chosen in `/etc/mxfs/drbd-fence.conf`
(`authority=quorum`). It is one rule or the other on a given pair, never both:
mixing a vote with a local fallback can elect both sides (the DRBD ruling,
decision 1), and the same holds here.

### Arm (mount)

The mount is refused unless all of these hold when it is asked:

- the helper is running and the module holds a valid quorum lease (below);
- this node is quorate in a membership that contains the peer named by `peers=`
  (or the DRBD peer), identified by its corosync node id, which the helper maps
  from the peer's address;
- the quorum device is voting (`pvecm status` and `corosync-quorumtool` print
  the `Qdevice` flag; a QDevice that is configured but not voting gives a
  two-node cluster no third vote, as measured on pve1/pve2 when its qnetd host
  was unreachable);
- the configuration is not `two_node`.

A node that cannot be fenced must never join (`docs/fencing.md`, Arm), and here
a node that cannot lose the vote cleanly is one that cannot be fenced.

### The quorum lease, and the reset

The module holds a **quorum lease**: a deadline on the monotonic clock, renewed
by the helper only while this node is quorate. The helper renews every L/4; the
lease is L.

- **The lease expires, or the helper reports inquorate, while a `fence=quorum`
  filesystem is mounted:** the module ends the boot
  with `emergency_restart()`. It writes nothing first: no unmount, no log force,
  no heartbeat. Writing after losing the vote is exactly what must not happen.
  A halt is not offered: the kernel's exported halt (`kernel_halt`) runs the
  reboot notifiers and the device shutdown first, which is code running and I/O
  issued after the vote is lost, and the halt that skips them is not exported.
  The lease is 3 s (`quorum_lease_ms`); the helper reports every 250 ms.
- **Expiry is evaluated where authority is used, not only by a timer**
  (`docs/rulings/local-authority-lease-and-the-limits-of-a-software-gate.md`,
  section 1). The I/O admission gate already checks the authority lease; the
  quorum lease joins that check (`mxfs_mount_write_admitted`), and so does the
  emulated swap's lock, which carries the heartbeat, the slot claim and the
  ledger: the first write a resumed node attempts after its deadline resets the
  node instead of being issued. A timer still fires the reset for a node that
  is not writing.
- **A helper that dies, hangs or is killed stops renewing,** and the node resets
  at the deadline. A userspace failure is a quorum loss, never a reason to carry
  on.
- **No reset loop.** The reset fires only while mounted. After the restart the
  mount is refused until the node is quorate with its peer in the membership
  again, so a node on the losing side of a lasting split comes up and waits.

### Takeover (a death)

The survivor may take over the peer's slice only when all of these hold:

1. **It holds the vote without the peer.** Its helper reports a quorate
   membership that does not contain the peer's node id. A peer still in the
   membership is not dead to corosync, whatever MeshXFS's own links say; that
   case is not a takeover, and the pair falls back to what the attachment does
   for a lost lock-manager link with both nodes alive.
2. **The loser's deadline has passed.** Measured from the survivor's own
   observation of that membership (an absence is timed only across reports
   that follow each other within the lease), it waits

       W = D_inq + L + T_reset

   where `D_inq` is the longest a node cut off at the same instant can still be
   told it is quorate (corosync's token and consensus timeouts and the
   QDevice's vote-withdrawal time for this configuration), `L` the quorum
   lease, and `T_reset` the bound from the lease expiring to the reset
   executing. The survivor's observation comes no earlier than the cut, so
   timing from it is conservative. Clock-rate error is applied as the lease
   ruling's budget does. The module's bound is 45 s (`quorum_takeover_ms`):
   corosync's token (3 s) and consensus (3.6 s) on a two-node default, the
   QDevice's vote withdrawal, which votequorum waits for at most its qdevice
   sync timeout (30 s by default), the 3 s lease and an immediate reset.
   Measured (`tests/vsphere_shared_fence.sh dinq`, the cut at a random 0-3 s
   phase, 12 cycles each, two-node default timings, qnetd on serv): a node cut
   from its peer alone goes inquorate in 6.1-6.7 s (token + consensus, then
   qnetd's ffsplit answer); cut from its peer and qnetd at once, in 8.7-11.6 s
   (its QDevice has to notice qnetd is gone). The worst, 11.6 s + the lease
   + one report period, is 14.9 s of the 45 s bound.

   The absence need not still be going on. An absence that lasted the whole
   bound and ended after the survivor last saw the victim's heartbeat change
   ends the victim's boot too: the victim was writing then, so it was armed
   before the absence ended, so before it began (a node out of the membership
   is not quorate and cannot arm), and it ended its boot within the bound. The
   peer may be a member again by now; that is a later boot.
3. **On the shared attachment, the peer's heartbeat stopped.** The disk does not
   split with the network, so a peer that is still running writes its heartbeat
   where the survivor reads it. The survivor reads the victim's heartbeat
   record twice, 5 s apart (more than two heartbeat intervals), straight from
   the disk: the heartbeat monitor stops watching a slot once its death is
   declared, and a death the TCP or lease layer declared says nothing about the
   disk. A record that changed means the peer did not reset when it had to; the
   takeover is refused (`P-QUORUM-LOSER-STILL-WRITING`) and stays refused. It
   never takes over from a peer that is visibly still writing. A DRBD pair has no such check, since its
   heartbeat is replicated and stops with the link; there the loser's I/O is
   already frozen by DRBD's fence-peer contract, and the survivor excludes it as
   it does today (kind 26).

When these hold, the victim's boot has ended. That is the owner's decision for
this method: the deadline having passed, with the vote held, counts as the
victim's boot being over. It is not an observation of the victim, and the
certificate says so. A hypervisor host that freezes the victim breaks the
premise: its boot does not end (below, "What this does not cover").

A later boot of the peer, seen in its swap register (a later boot that has
mounted) or in its boot announcement (a later boot that is a member, mounted or
not), ends the old boot directly (observation `HOST_BOOTED_AGAIN`, as for the
other shared methods) and takes over without waiting out `W`.

### Evidence

Proof kind 30, `MXFS_FENCE_KIND_SHARED_QUORUM_V1`: the survivor held a quorate
membership without the victim's node id for `W` and the victim's heartbeat no
longer changes (observation `QUORUM_LOSER_DEADLINE_PASSED`, claim
`QUORUM_LOSER_ENDED_ITS_BOOT`), or the victim's host runs a later boot
(`HOST_BOOTED_AGAIN`, claim `VICTIM_BOOT_ENDED`). Basis `NODE_STOPPED`.
It is accepted only on a mount whose `fence=` is `quorum`, the same restriction
kinds 28 and 29 carry (`mxfs_disklock_cert_method_ok`). Like them it is a death
certificate, not a fence: nothing re-checks the victim against it, and the
victim's next boot is a new incarnation that comes back only through admission.

On the DRBD pair the takeover still mints kind 26: the vote decides which
participant may exclude the other, but what the certificate proves is still the
exclusion from this replica.

## The DRBD pair: `authority=quorum`

`/etc/mxfs/drbd-fence.conf` with `agent=self` and `authority=quorum`. The vote
replaces the fixed tie-break inside DRBD's fence-peer handler
(`tools/mxfs_drbd_fence_self.py`, `quorum_decision`); nothing else of the
built-in authority changes (exclusion, receipt, witness, guard, release). With
a node fence configured (`agent=ssh`/`exec`) an `authority=` line is refused:
the node fence already picks the one winner, and a vote beside it would be a
second rule on the same split.

No lease and no deadline are needed here. Under `resource-and-stonith` DRBD
freezes a Primary's I/O when its link fails and keeps it frozen until the
handler answers; a loser answers 1 and stays frozen, and its replica is not
the winner's, so nothing it holds can reach the winner's disk whenever it
runs again. What the vote must guarantee on DRBD is only that both sides never
win. The handler polls `mxfs_quorumd vote` and decides once a verdict has held:

- **win** — this node is quorate in a membership without the peer. Under
  `ffsplit` a QDevice votes for one partition of a changed membership, so the
  peer cannot be quorate without this node at the same time. Held 2 s. Either
  participant can win, which is what lets participant 1 take the pair when
  participant 0 died.
- **lose** — this node is not quorate, or the vote cannot be asked, or the
  configuration cannot give an exclusive vote (`two_node`, the peer not in the
  nodelist). Held 2 s. The node keeps its I/O frozen and, with MeshXFS mounted,
  restarts, as the tie-break's loser does.
- **tiebreak** — the peer stays in this node's quorate membership: the
  replication link failed and corosync's did not, both nodes are alive. Held
  for 45 s (the takeover bound, far past any stale view: `D_inq` measured at
  most 11.6 s, below), the fixed tie-break decides, and the peer, in the same
  membership, reaches the same verdict. A node whose view still holds a peer
  that has already left keeps that view at most `D_inq`, so it cannot hold
  this verdict for 45 s while the peer holds **win**.
- No verdict held within 75 s (reports flapping): **lose**.

The tie-break is never applied to a decision the vote has an answer for, which
is the mixing the DRBD ruling's decision 1 forbids.

What changes in the DRBD ruling (`docs/rulings/drbd-two-node-self-exclusion.md`)
under the vote:

- Decision 2 (participant 1 never carries on): replaced by the vote above.
- Decision 10 (participant 0 keeps its standing at boot from DRBD's record of
  the peer Outdated): **disabled**. That record can be stale — written before a
  crash, the peer resynced and carried on since — and acting on it is safe
  only because participant 1 never carries on alone. Under the vote either node
  may have, so neither mounts alone on DRBD's record; a node that won holds its
  own exclusion (inhibit) and mounts as the survivor on that, either
  participant.
- Decision 11 (a disconnected Secondary is promoted only under its own
  standing exclusion): unchanged, for either participant.
- A participant 1 inhibit is kept at boot rather than dropped as an earlier
  version's.

### Whole-cluster restart

When both nodes come up together, neither has a deadline to wait out: each
earlier boot is ended by its host having booted again (this host's own, by its
identity; the peer's, by its announcement or its register), and a host that is
still off is not writing. The first mount needs only to be quorate with its peer in the
membership, or quorate alone after `W` from boot for a peer that never
appears.

### Where the pieces are

| piece | where |
|---|---|
| `fence=quorum`, arm, the death certificate | `dlm/v5_mount.c` (`v5_shared_arm`, `v5_shared_boot_ended`, `v5_shared_fence`) |
| the quorum channel, lease, reset, absence timing, announced boots | `pal/linux/drbd.c` (`/proc/fs/mxfs/quorum`, `mxfs_pal_quorum_*`) |
| the admission gate | `pal/linux/xfs_super.c` (`mxfs_mount_write_admitted`), and the emulated swap's lock |
| the fresh heartbeat read | `dlm/disklock.c` (`mxfs_disklock_slot_hb_changing`) |
| kind 30 | `dlm/scsipr.h`, `dlm/scsipr.c`, `dlm/disklock.c` (`mxfs_disklock_cert_method_ok`) |
| the helper and its unit | `tools/mxfs_quorumd.py`, `packaging/mxfs-quorumd.service` |
| a lab pair's corosync, QDevice certificates and helper | `scripts/quorum_setup.sh` |
| the tests | `tests/vsphere_shared_fence.sh` (`up quorum`, `kill`, `split`, `restart`) |

## What this does not cover

- **A VM frozen by its hypervisor host: measured, and NOT covered by the vote
  alone** (`D-QUORUM-FROZEN-HOST-LATE-WRITES-AFTER-TAKEOVER`). With the nested
  ESXi host under vstest2 paused for 76 s (`tests/vsphere_shared_fence.sh
  freeze host`), vstest1 took it over at +75 s, and after the unpause 4 of
  vstest2's blocks changed on disk. Three were commands queued in ESXi at the
  pause, which ESXi issued on unpause. One was a new write: the guest's clock
  did not advance across the pause, so its lease still read valid, and its
  corosync merged back into the membership without ever reporting it
  inquorate. The node never reset. Its filesystem shut down 0.85 s of guest
  time later, when its heartbeat found its slot taken, so the certificate's
  claim that its boot had ended was false. A vSphere suspend of the guest
  alone (`freeze guest`) gave no late write: the suspend drains the guest's
  I/O, and the guest reset on resume. So a node cannot see its own freeze before
  it writes, and commands below it are out of its reach. Only a barrier at the
  storage closes this: a reservation preempt where the disk forwards
  reservations per guest (a physical RDM), and nothing on a disk that has none
  (a multi-writer VMDK). The rest of this design stands for nodes that crash,
  power off, are cut off, or whose helper dies.
- **Both sides inquorate.** With qnetd unreachable and the pair split, neither
  node is quorate, and both reset if mounted. That is an outage, chosen over a
  rule that lets an inquorate node carry on: an inquorate node that carries on
  can meet a peer that later regains the vote.
- **A cluster stack MeshXFS does not control.** A misconfigured corosync (`two_node`,
  `expected_votes` overridden, a quorum forced by an operator with
  `corosync-quorumtool -e` or `pvecm expected`) defeats the vote the way
  `drbdadm primary --force` defeats the DRBD ruling. The arm check refuses the
  configurations it can see; an operator override after mount is outside it.
- **A node whose reset does not stop its I/O.** `emergency_restart()` on a VM
  resets the virtual hardware; on bare metal it resets the machine. Whether the
  storage path can still complete a command issued before the reset is the same
  question as `Q` and is measured with it.

## Test plan

Each item names the property it measures; none of them is a single clean run.

- **The loser resets.** Mounted pair, both writing. Cut corosync and the MeshXFS
  links between them, with qnetd reachable from one side. The side qnetd denies
  resets within `D_inq + L + T_reset` (logged by the module before the reset, read
  on the console capture); the other side takes over after `W`; every
  acknowledged file reads back; `chk_mxfs` is clean.
- **The peer dies.** Power-off and panic of a writing node: the survivor takes
  over after `W`, every acknowledged file reads back.
- **The vote denied to both.** qnetd down, then the link cut: both reset, neither
  takes over, both rejoin when qnetd returns.
- **The helper dies.** `SIGKILL` and `SIGSTOP` of `mxfs_quorumd` on a mounted
  node: the node resets at the lease deadline, and the peer takes over.
- **A peer that does not reset.** With the reset suppressed by a debug knob, the
  survivor must refuse the takeover on the shared attachment, because the
  victim's heartbeat advances past its deadline.
- **`D_inq` measured, not read off the config.** Cut the link at known phases of
  corosync's token rotation and the qdevice heartbeat, and record when each side
  learns its quorum state. `W` is derived from the measured worst case with the
  lease ruling's margins.
- **`Q`, per platform.** The victim writes 4 KiB direct I/O from eight threads;
  freeze it (a vSphere suspend, a nested-host stall, a KVM `virsh suspend`) for
  longer than `W` while the survivor takes over and reads the victim's region
  in a loop. Any of the victim's sequence numbers landing after the takeover is
  a late write. The same run with `emergency_restart()` instead of a freeze
  measures `T_reset` and whether the reset retires queued commands.
- **The whole-cluster restart.** Both nodes reset at once; the first mount
  proceeds on each peer's later boot, without waiting out `W`.
