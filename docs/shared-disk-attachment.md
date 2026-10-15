# A shared disk with no reservations: the `shared` attachment

A disk that both nodes can read and write, with no SCSI persistent reservations
and no COMPARE AND WRITE. On vSphere 7.0 and later, a multi-writer VMDK is
exactly this (`docs/attachment-methods.md`, VMware section): ESXi answers every
PERSISTENT RESERVE with INVALID COMMAND OPERATION CODE, reports COMPARE AND
WRITE as not implemented, and carries FUA. Any shared virtual disk a
hypervisor exposes without forwarding SCSI arbitration has the same shape.

A physical-mode RDM does forward reservations, but ESXi registers and
unregisters each VM's key itself and drops it when the VM is powered off, so
the reservation fence cannot prove a dead node's writes ended there; MeshXFS
refuses `fence=scsipr` behind VMware's virtual SCSI adapters
(`P305-PR-HYPERVISOR-INITIATOR`, `docs/attachment-methods.md`). An RDM mounts
as this attachment too: its reservations and COMPARE AND WRITE go unused.

MeshXFS takes three things from SCSI on every other attachment, and this one
supplies none of them:

1. **COMPARE AND WRITE** for every on-disk record the cluster updates
   atomically: the heartbeat, the slot claim, recovery milestones, the
   bootstrap owner and the ledger tickets. The TCP lock transport uses it too;
   only the lock traffic itself moves to the network.
2. **The fence**: PREEMPT AND ABORT, which makes the storage refuse a dead node
   and retire what it had accepted from it (`docs/fencing.md`).
3. **Admission**: a node that registers a key can be fenced later, and one that
   cannot register is refused (`docs/fencing.md`, "Arm, at mount").

The DRBD attachment already lives without all three
(`docs/rulings/drbd-dual-primary-attachment.md`), and this attachment reuses
its two-party machinery wherever that machinery does not depend on DRBD.

Configuration: `2/net/mesh/shared`. Two nodes, the network lock manager, a
shared disk with no SCSI arbitration.

## Selecting it

The mount option `fence=` names the method, and with it the attachment:

| `fence=` | attachment | what proves a dead node's writes have ended |
|---|---|---|
| `scsipr` (default) | whatever the device is | PREEMPT AND ABORT |
| `manual` | `shared` | an operator's confirmation, per incarnation |
| `vcenter` | `shared` | vCenter: the victim's VM powered off, or booted again |
| `quorum` | `shared` | corosync's vote held without the victim for the takeover bound, the victim having ended its own boot on losing it; or its host booted again (`docs/quorum-takeover.md`) |

A DRBD device keeps its own method whatever `fence=` says, and refuses
`manual`, `vcenter` and `quorum`: its fence is the replication link's, not the
node's.

`fence=manual`, `fence=vcenter` and `fence=quorum` mount only on the TCP transport (a disk
with no COMPARE AND WRITE cannot carry the disk lock manager), and only with
the whole cluster named: `peers=<this node>/<the other node>`, two IPv4
addresses, exactly one of them this host's. The list is exclusive, so no
third node is admitted by multicast; the emulated swap below is a two-party
lock.

## The compare-and-swap

The DRBD attachment emulates COMPARE AND WRITE with a one-bit lock for two
(Burns and Lamport) built on the device: each participant writes only its own
register sector, and a read issued after a completed write sees it
(`pal/linux/drbd.c`, THE LOCK). Its correctness needs three properties of the
device, and a shared disk has all three:

- a write that has completed is returned by any later read from either node
  (the device is one device, not two replicas: there is nothing to converge);
- each node writes only its own register sector, so no write is ever torn
  between the two;
- the target write of a swap completes before the release is written.

So the swap code runs unchanged on a shared disk, reached through the same
`mxfs_pal_bdev_compare_and_write*` entry points, which send a shared
attachment's swaps to the emulation even though the device is SCSI. What
differs is identity and the dead peer:

- **Participant index.** DRBD orders its two endpoints by the replication
  link's addresses. A shared disk orders the two `peers=` addresses: the
  numerically lower is participant 0. The enrollment sector records both, so
  two nodes that disagree about who is participant 0 are refused at attach,
  as on DRBD.
- **Host and boot in the register.** Each node writes its host identity
  (`/etc/machine-id`) and boot identity into every register it puts. A peer
  register naming this node's own host is refused at attach: two nodes that
  share a machine-id (a clone that kept it) could each take the other's live
  boot for an ended boot of their own.
- **A flag claims only its own sectors.** Each register names the sector
  ranges of the swaps it is raised for, and holds up only swaps on those
  sectors (`docs/attachment-methods.md`, the DRBD lock). A peer that dies
  holding its flag holds up the sectors of the swap it was in, typically its
  own heartbeat or a page of its own ledger; every other swap of the survivor,
  its own heartbeat above all, goes on. Measured before the ranges existed,
  under `fence=manual`: a peer that died holding its flag stopped every swap of
  the survivor, the survivor's heartbeat stopped landing, its authority lease
  ran out 62 s later and it withdrew, before the dead peer's death had even
  been declared and so before any operator could have been asked.
- **A peer that died holding its flag.** Its register is never cleared on age,
  and never written. A swap that has waited a second asks the mount's fence
  method whether the boot named in the peer's register has ended (below); if
  it has, those exact 512 bytes are set aside: read as idle while the sector
  still holds them. A later boot of the peer rewrites its register under a
  fresh nonce when it attaches, which ends the setting aside, so no live flag
  is ever erased. This is DRBD's set-aside for a quiescent peer.
- **A peer that holds its flag past the wait bound.** A critical section is a
  few sector writes; a peer holding a sector for the whole bound (10 s) is
  dead or frozen. So before a swap on that sector fails, `fence=vcenter`
  powers the peer's VM off and sets its register aside. `fence=manual` cannot
  act: the swap fails, as an operation needing the dead node's locks does,
  until the operator confirms; swaps on other sectors, the heartbeat among
  them, are not held up.

## The identity of a node

A fence names its victim by the identity recovery uses: the slot, the node id
and the incarnation (epoch) of the dead record (`docs/fencing.md`,
invariants). A `shared` mount registers no key, but it writes an identity
block on every heartbeat record, as a SCSI mount does, so each record names
the host and boot of the incarnation that wrote it. The block's key field
carries a value derived from the incarnation, which nothing registers. The
survivor freezes that block at the death, as it does on SCSI.

## What proves a victim's writes have ended

There is no storage-side operation on this disk, so the evidence is about the
node: **the boot that ran the victim has ended.** A boot that ended issues no
further I/O, and a later boot of the same machine starts by resetting its
disk controller, so nothing the earlier kernel submitted is still
outstanding. Three observations establish it:

- **An earlier boot of this host.** The survivor runs a later boot of the same
  machine, which ended the earlier one. Both methods accept it.
- **`fence=vcenter`.** vCenter reports the victim's VM powered off, or tagged
  by a later boot than the victim's.
- **`fence=manual`.** An operator confirmed the request naming exactly that
  incarnation.

Each is a death certificate, not a fence: a boot that ended does not come
back, so nothing re-takes the evidence before a later recovery step. The
victim's VM may well be running again; that is a new incarnation, which
reaches the dead one's slice only through admission.

### Method: `manual`

The operator is the fence. MeshXFS refuses to guess, so a death stops
recovery until a person says the victim is gone.

- **Arm (mount).** The mount logs, at WARN, that no automatic fence exists on
  this attachment, and that a dead peer's recovery will wait for an operator.
- **Fence (death).** The survivor posts a request naming the victim: slot,
  node id, incarnation, the host and boot recorded in its identity block, and
  the peer's address, and logs it with the command to confirm it. Each
  request carries a random id drawn when it is posted. The dead node's locks
  stay frozen; once the fence series is BLOCKED, operations that need them
  fail fast.
- **Evidence.** `echo 'confirm <id>' > /proc/fs/mxfs/fence_confirm`. Reading
  the file lists every request, waiting or confirmed. A confirmation can only
  name a request the operator read: a later death is given a new id.
  It produces proof kind 28 (`SHARED_MANUAL_V1`).

What the confirmation asserts, and what the operator must establish before
writing it: the victim's machine is powered off, or its access to the disk
is cut, and it will not resume in that boot. A hung VM that is still powered
on is not dead, and confirming it is the corruption this method exists to
prevent. A VM that has since been restarted has ended that boot.

### Method: `vcenter`

vCenter is the fence. A node-local helper speaks to it, the way the DRBD
witness speaks to DRBD (`/usr/sbin/mxfs_fence_vcenter.py`, from
`tools/mxfs_fence_vcenter.py`, invoked with a nonce and reporting back through
`/proc/fs/mxfs/fence_report`; it needs pyVmomi).

- **Configuration.** `/etc/mxfs/vcenter.conf`, root-owned: `server=`, `user=`,
  `password_file=` (root-owned, mode 0600) and optionally `insecure=1`. The
  account needs the privileges to read VMs, set a custom attribute (and
  define one, the first time) and power a VM off.
- **Arm (mount).** The helper finds this node's own VM by the BIOS UUID the
  guest reads from `/sys/class/dmi/id/product_uuid`, and sets the custom
  attributes `mxfs.host` and `mxfs.boot` on it to this node's host and boot
  identity. It refuses the mount when vCenter is unreachable, when no VM or
  more than one VM has that BIOS UUID, when another VM already carries the
  same `mxfs.host` (a clone that kept the machine id), or when the VM has a
  snapshot that holds its memory: reverting to one resumes an old boot alive,
  which no tag could tell apart from the boot that tagged it. The mapping from
  a MeshXFS host to a VM is therefore written by the node itself, from inside
  the VM, and is unique.
- **Fence (death).** The survivor passes the victim's host and boot (from its
  frozen identity block). The helper finds exactly one VM tagged with that
  host. Its boot has ended if the VM is powered off, or if a later boot has
  rewritten `mxfs.boot` (and the VM holds no memory snapshot). Otherwise the
  helper powers the VM off and reads its state again after the task
  completes.
- **Evidence.** vCenter's state of that VM, read in this attempt. It produces
  proof kind 29 (`SHARED_VCENTER_V1`).

What the evidence rests on: a powered-off VM issues no further I/O, and ESXi
does not report a VM powered off while its virtual disk still has commands
outstanding. That is the hypervisor's statement, not the storage's
(`docs/fencing.md`, open question on evidence strength), and it is measured
on this attachment the way the fence uses it
(`tests/vsphere_poweroff_quiesce.sh`): the victim writes 4 KiB direct I/O as
fast as eight threads can, the survivor reads the victim's whole region in a
loop, powers the victim off through vCenter itself, and any sequence number
that appears after the task reported success is a write that landed late.

A whole-cluster restart needs no power-off when the VMs have booted again.
Each node tags its VM with its new boot twice before it waits for the
cluster: at boot, from `mxfs-vcenter-tag.service` (the helper's `boot` mode,
the same refusals as a mount's arm), and again at mount. The first node to
take the bootstrap waits out two frozen-table windows before phase 3, so by
then every VM that has booted is tagged by its new boot, and its earlier boot
is ended by that tag. A VM still off is ended by being off; only a VM booting
so slowly that its unit has not run yet is powered off when phase 3 reaches
it. The VM's
`runtime.bootTime` is not used: it changes on a guest reboot as well as on a
power-on (measured), and whether anything else, such as a migration, changes
it while the same boot runs on was not established.

## Recovery

Both kinds plug into the recovery path exactly where kinds 25 to 27 do: the
fence leg takes the method's verdict, the proven branch certifies the
recovery descriptor with the kind, and foreign replay accepts the
certificate only for a kind on the durable allow-list. They carry their own
retirement basis, `node-stopped`, so no reader takes them for a target
operation. The certifier and both replay readers accept kinds 28 and 29 only
on a mount whose `fence=` names the same method
(`mxfs_disklock_cert_method_ok`): a certificate minted under `fence=manual` is
not evidence on a `fence=vcenter` or `fence=scsipr` mount.

A whole-cluster restart (`docs/whole-cluster-restart.md`) finds earlier
incarnations' records with no live owner. On SCSI it fences their keys; on
DRBD its startup fence excludes the peer. On `shared` nothing is fenced up
front: phase 3 certifies each victim from its own boot having ended, as
above. A victim not shown ended yet (no confirmation, vCenter unreachable)
leaves the term RECOVERING, and a later mount attempt resumes it.

The shared attachment's records carry DRBD's attachment marker: it holds no
key, its clean release is its retirement, and, like DRBD, its authority lease
is the death window less one heartbeat interval, because a peer replays its
slice only once its boot has ended.

## What this attachment cannot do

- More than two nodes: the swap is a two-party lock.
- The disk lock manager (`disk/caw`): there is no COMPARE AND WRITE.
- Fence by the storage: a VM that keeps running with its disk attached is
  never cut off by the disk itself. Both methods act on the node.
