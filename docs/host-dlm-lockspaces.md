# One DLM per host, one lockspace per filesystem

How a host mounts more than one MXFS filesystem at once, each shared with a
different set of hosts, on the network transport.  This is the model the
kernel DLM gives GFS2 and OCFS2: the host joins the cluster once, and each
filesystem is a lockspace inside it.

## What MXFS does today

The host owns the network ports; everything above them is still per mount.

- **One socket per port per host** (`pal/linux/kern.c`).  The TCP lock
  manager listens on 7600 (`MXFS_PORT_DLM`, `include/mxfs/mxfs_ports.h`);
  discovery, the CAW nudges and the lease heartbeat use UDP 7601-7603.  The
  first mount on a host that needs a port creates its socket and the thread
  that serves it, every later one takes a handle on it, and the last one to
  close takes both down.  A datagram is copied to every mount on the port, and
  each drops what is not for its volume (the volume UUID in every discovery,
  lease and nudge packet).  A connection goes to the mount whose volume id
  the connector's first message, the NODE_JOIN, carries: the acceptor peeks
  it without consuming it (`mxfs_pal_tcp_listen_keyed`).
- **Why not a socket per mount with `SO_REUSEPORT`.**  Linux gives a new connection or a unicast datagram to one socket chosen
  by a hash of the addresses and ports, not by the volume.  Measured with two
  filesystems on the same two hosts (`tests/multi_mount.sh`): a lock-manager
  connection reached the other filesystem's listener and was reset on every
  run, and under `peers=` one filesystem never heard its peer's heartbeat,
  because the peer's fixed source port always hashed to the other socket.
- **Its own identity per mount.**  The node id is drawn once per mount context
  (`dlm/v5_mount.c`), along with the epoch and, on SCSI, the reservation key.
- **Its own discovery and lease threads per mount**, announcing node UUID,
  volume UUID and port (`docs/discovery.md`), and its own connection to each
  peer: two filesystems shared by the same two hosts run two connections and
  two liveness judgements of the same peer.
- **Its own lock transport per mount.**  The `transport=tcp|caw` mount option
  names it, overriding the module's `force_transport`; a DRBD device always
  runs TCP.

The DRBD tooling scopes its evidence to one resource: releasing an exclusion
asks whether the peer has that resource's device mounted, or a superblock of
it alive (`/sys/fs/mxfs/<dev>`), never whether it has any MXFS mount.  Each
resource's handler excludes the peer under that resource's own episode, so the
built-in authority answers `status <peer> <resource>` for one resource, and the
witness of each mount asks for its own; a host-wide answer would hand every
other resource an episode its receipt does not name, and those mounts would
never prove the peer excluded.  (A node fence is different: it holds the whole
host under one episode, which a second resource's fence reuses.)  Its
isolation drops every MXFS port to and from the peer, and those ports carry
every filesystem the two hosts share, so it is a fence of the whole host
whichever resource lost its link.  It therefore also drops the DRBD port of
every resource the two hosts share.  Left Connected, those resources would keep
the peer Primary with their MXFS traffic cut and no exclusion either side could
prove, so their filesystems could neither reach the peer nor recover it.
Dropped, each link fails the way a lost link does: DRBD runs that resource's
own handler, which excludes the peer under that resource's episode on the
winner and freezes the resource on the loser.  The cut is never a graceful
disconnect, because DRBD runs no handler for one and the peer would carry on
as Primary alone.  This is consistent across resources because the tie-break
is fixed: participant 0, the lower DRBD address, is the same host for every
resource the pair shares, so the same host wins every split.
`scripts/drbd_rig.sh multi-death-test` holds the rig to this: a pair with
`DRBD_RIG_RESOURCES` resources (default 3), each on pool LUNs of its own, loses
a node with every one mounted.  Every resource must exclude the node under an
episode no other resource uses and witness that episode, and its recovery must
complete.  The node is then released on each resource's own evidence and
rejoins all of them.  With `MULTI_CUT=1`, only one resource's link is cut
instead, and every resource must still end up excluded and recovered.  With
`MULTI_CUT=mounting`, that link is cut while the victim is still mounting the
resource, and the victim must restart itself rather than leave the mount
blocked.  The loser restarts whenever the module holds anything, because the
fence covers the whole host.

## The design

Two layers, split along what is a fact about a host and what is a fact about
a filesystem.

### Host layer: one per host, in the module

- **One listener per port, and one connection to each peer host**, shared by
  every mount that has that peer in common.  Created with the first mount that
  needs it and gone with the last.
- **One host identity**: a host UUID that survives remounts and reboots, and
  the address the host is reached at.  This is what a peer is: a mount on
  another host is reached through that host.
- **One liveness judgement per peer host.**  Whether pve2 is reachable is the
  same question for every filesystem pve1 shares with it, and gets one
  answer.  When the host layer declares a peer host dead, every lockspace that
  has it as a member hears so at once.
- **Discovery per host**: one announcement listing the volumes this host has
  mounted, not one sender per mount.

### Lockspace layer: one per mounted filesystem

- **Keyed by the volume id** (the FNV-1a of the filesystem UUID that already
  goes into every heartbeat and NODE_JOIN).
- **Joining**: a mount asks the host layer for a lockspace with that id.  The
  host layer tells each connected peer "this host is joining volume X"; a peer
  with X mounted adds the host to X's membership, and a peer without it
  ignores it.  Every lock message carries the volume id, and the receiving host
  hands it straight to that lockspace.  There is no guessing which socket
  holds which volume, because there is one socket.
- **Per filesystem, as now**: locks, grants, masters, ledger pages, the slot
  and journal this host holds on the device, the mount's generation, and
  journal recovery.
- **The device heartbeat stays per filesystem.**  On DRBD and CAW a mount
  proves it may still write a device by landing writes on that device; a
  heartbeat on one device says nothing about another.

### Liveness and fencing

These come apart, and the split is the point of the design:

- **A dead host is dead for every lockspace.**  When the host layer loses a
  peer, each lockspace it was a member of runs recovery for it on its own
  device: replay its journal there, take over what it held there.
  Lockspaces it was never in are not touched.
- **Fencing is of access to a device, and its reach is the fence's own.**  A
  SCSI reservation fences one LUN; a DRBD exclusion fences one resource; a
  power fence or the DRBD helper's host isolation fences the whole host.  A
  host-wide fence must be followed by every lockspace the fenced host is a
  member of, which the host layer's single liveness judgement gives; a
  device-scoped fence must not take down the fenced host's other mounts.
- **A partition between two hosts is a host-layer event.**  If A and B lose
  each other but B and C do not, A and B's shared filesystems resolve it
  between them, and B's filesystems with C carry on as if nothing happened.

## The test: three hosts, three filesystems, overlapping memberships

```
              +------------- sdZ -------------+
              |                               |
    A ------ sdX ------ B ------ sdY ------ C
```

| filesystem | presented to and mounted on |
|---|---|
| `sdZ` | A, B and C |
| `sdX` | A and B only |
| `sdY` | B and C only |

So every pair of hosts shares more than one filesystem except A and C, which
share only Z: A and B share X and Z, B and C share Y and Z.  B mounts all
three.  On the shared-LUN rig that is three pool LUNs, each attached to its
hosts only.  On DRBD, which replicates between two hosts, X and Y are two
resources (X between A and B, Y between B and C) and Z runs on the shared-LUN
rig, so the DRBD run covers steps 1-8 for X and Y with Z absent.  Every mount
runs the network transport.

What each step must show, beyond the usual integrity checks (every fsynced
file intact, a cold check of each filesystem clean, no kernel warning):

1. **Mount.**  Each host has one listener and one connection to each peer it
   shares a filesystem with: A to B and C, B to A and C, C to A and B.
   Memberships: Z {A, B, C}, X {A, B}, Y {B, C}; A never appears in Y and C
   never in X.  Each mount within its normal mount budget, with no rejected
   connection on any host.
2. **Concurrent load** on all seven mounts.  Locks for X travel only between
   A and B, for Y only between B and C, and for Z among all three
   (per-lockspace message counters on every host); the A-C connection carries
   Z only.  Pace on each filesystem within its bound for its member count:
   sharing a host's connection layer costs no filesystem anything measurable.
3. **A dies.**  B recovers A on X; B and C recover A on Z, each within that
   filesystem's recovery budget.  Y on B and on C does not stall: its writes
   continue throughout, with no recovery and no membership change.
4. **C dies.**  The mirror of step 3: Y and Z recover C, X is untouched.
5. **B dies.**  A recovers B on X, C recovers B on Y, and A and C recover B on
   Z; nothing of X reaches C and nothing of Y reaches A.
6. **The A-B link is cut; A-C and B-C are not.**  A and B have lost each
   other, so both filesystems they share must resolve it the same way: on X
   one of them keeps the filesystem and the other withdraws from it, and on Z
   the same one is excluded, since Z's two other members still reach each
   other through C and must agree with X on who is gone.  Y, which A is not
   in, carries on between B and C untouched.  On DRBD the helper's host
   isolation of B by A must not reach B's traffic with C.
7. **The A-C link is cut; A-B and B-C are not.**  A and C share only Z, so Z
   alone resolves it and excludes one of them; X and Y, which do not have
   both A and C as members, carry on untouched.
8. **B unmounts X while Y and Z are under load**, then mounts it again: Y and
   Z are unaffected, and B's connections to A and C are never torn down,
   since Z still needs both.
9. **B unmounts Z** while X and Y are loaded: the A-B and B-C connections
   stay (X and Y need them); the A-C connection, which carries Z only, stays
   for A's and C's own Z mounts.
10. **The last mount on a host goes away**: the host layer's listener and
   connections go with it, and a remount builds them again.

The mount order varies (Z first, Z last, X and Y in both orders), and steps
6 and 7 each run with either side of the cut as the one that keeps the
filesystem.

## Open questions

- **Which host owns a lockspace's master map.**  Today a mount's masters are
  hashed over its own membership; that stays per lockspace, but a peer host
  that leaves one lockspace and stays in another must change the first's map
  without disturbing the second's.
- **Who decides a cut between two hosts that share several filesystems.**
  When A and B lose each other (test step 6), X has only the two of them and
  breaks the tie by its own rule, while Z has C as a third vote.  The two
  must exclude the same host, or B is a member of Z and a fenced stranger on
  X at once.  Either the host layer makes the decision once and every shared
  lockspace follows it, or the lockspace with the most members decides and the
  others take its answer; which, and how a lockspace with no third vote learns
  it, is open.
- **Discovery on the wire.**  An announcement that lists volumes changes the
  discovery packet; a mixed cluster (old per-mount announcer, new per-host)
  needs either a version bit or a flag day.
- **The DRBD fence helper's isolation** is per resource in its bookkeeping
  (one nftables table per resource) but host-wide in effect (every MXFS port
  to the peer).  Whether a resource's exclusion should tell the other
  resources' mounts at once, instead of each finding the peer gone by its own
  timeout, is open.
- **The CAW transport** coordinates through the device itself and has no
  listener to share; whether its UDP nudges move to the host layer is to be
  decided with the rest of the UDP plane.
