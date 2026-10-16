# MeshXFS

### A POSIX clustered filesystem built on XFS

**Mount the same shared block device read-write from multiple nodes.**

Shared SAN or DRBD storage · Network or on-disk locking · Fencing and journal recovery

MeshXFS is an open-source (GPL-2.0) clustered filesystem. Built on XFS, it
supports concurrent read-write mounts on shared iSCSI SAN storage—validated
with 2, 4, 8, and 16 nodes—or on dual-primary DRBD, with network-based or SCSI
COMPARE AND WRITE locking. MeshXFS provides fencing and survivor-led journal
recovery, is packaged as a DKMS module for Proxmox VE 9, RHEL 9, Ubuntu 24.04,
Ubuntu 26.04, Debian 12 and Debian 13, and includes a Proxmox VE storage plugin.

On a system, MeshXFS goes by its short name `mxfs`: the `mxfs.ko` module,
`mount -t mxfs`, the tools `mkfs.mxfs`, `chk_mxfs` (`fsck.mxfs`),
`resize_mxfs` and `mxfs_admin`, and the `mxfs` and `pve-storage-mxfs`
packages.

> **A shared-LUN clustered filesystem written entirely by AI.**
>
> Every line of the clustering, coordination, distributed-lock, fencing, and
> on-disk-envelope code in this repository was written by an autonomous AI agent
> (Anthropic's Claude Code) — **not** by a human using an AI tool. MeshXFS starts
> from the upstream Linux kernel **XFS** code, written by the XFS developers,
> and the AI has since modified much of it heavily (see "How this was built").
> Everything that turns XFS into a filesystem many machines can mount at once
> is AI-authored.

> ## 0.90.130: Stronger Recovery, Broader Platform Support
>
> What changed for someone upgrading from 0.90.129:
>
> - **The network lock manager over multipath, at 2, 4, 8 and 16 nodes, and
>   over a single path at 8 and 16** (0.90.130).  A node that loses every
>   storage path is fenced and its journal replayed while the others keep
>   writing; every other node now refuses the fenced node's late lock
>   releases before recovery collects its locks, so none of them can land
>   afterwards and leave the filesystem refusing every write.
> - **Ubuntu 26.04 and Debian 12 are supported** (0.90.130): the .deb, on
>   Ubuntu 26.04's kernel 7.0 and Debian 12's 6.1.
> - **Fixes** (0.90.130): on kernels before 6.5 (Debian 12) every buffered
>   write now advances the file position (it rewrote the same offset); a
>   node frozen by a backup or snapshot tool (`fsfreeze`) answers another
>   node's lock request without a kernel warning, which on a host that sets
>   `panic_on_warn` was a crash; on kernels before 6.6 a userspace thaw no
>   longer ends the freeze a node holds while another node joins.
>
> **Released configurations and what 0.90.130 was validated on:**
>
> | configuration | nodes | storage | validated on 0.90.130 |
> |---|---|---|---|
> | `2/net/mesh/drbd` | 2 | each host's own disk, DRBD 8.4 dual-primary | `tests/drbd_release_verify.sh`; two physical Proxmox VE 9 hosts, a network cable pulled under load and plugged back in |
> | `2/net/mesh/direct` | 2 | one shared iSCSI LUN, network lock manager | the 31-row suite on the test rig; installed packages |
> | `4/net/mesh/direct` | 4 | one shared iSCSI LUN, network lock manager | the 31-row suite on the test rig; installed packages |
> | `8/net/mesh/direct` | 8 | one shared iSCSI LUN, network lock manager | the 31-row suite on the test rig |
> | `16/net/mesh/direct` | 16 | one shared iSCSI LUN, network lock manager | the 31-row suite on the test rig |
> | `2/net/mesh/mpath` | 2 | one shared iSCSI LUN over two paths, network lock manager | the 31-row suite plus eight path-fault rows on the test rig |
> | `4/net/mesh/mpath` | 4 | one shared iSCSI LUN over two paths, network lock manager | the 31-row suite plus eight path-fault rows on the test rig |
> | `8/net/mesh/mpath` | 8 | one shared iSCSI LUN over two paths, network lock manager | the 31-row suite plus eight path-fault rows on the test rig |
> | `16/net/mesh/mpath` | 16 | one shared iSCSI LUN over two paths, network lock manager | the 31-row suite plus eight path-fault rows on the test rig |
> | `2/disk/caw/direct` | 2 | one shared iSCSI LUN, on-disk locks | the 31-row suite on the test rig; installed packages |
> | `4/disk/caw/direct` | 4 | one shared iSCSI LUN, on-disk locks | the 31-row suite on the test rig; installed packages |
> | `8/disk/caw/direct` | 8 | one shared iSCSI LUN, on-disk locks | the 31-row suite on the test rig; installed packages |
> | `16/disk/caw/direct` | 16 | one shared iSCSI LUN, on-disk locks | the 31-row suite on the test rig; installed packages |
> | `2/disk/caw/mpath` | 2 | one shared iSCSI LUN over two paths, on-disk locks | the 31-row suite plus nine path-fault rows on the test rig |
> | `4/disk/caw/mpath` | 4 | one shared iSCSI LUN over two paths, on-disk locks | the 31-row suite plus nine path-fault rows on the test rig |
> | `8/disk/caw/mpath` | 8 | one shared iSCSI LUN over two paths, on-disk locks | the 31-row suite plus nine path-fault rows on the test rig |
> | `16/disk/caw/mpath` | 16 | one shared iSCSI LUN over two paths, on-disk locks | the 31-row suite plus nine path-fault rows on the test rig; three Proxmox VE 9 hosts on two paths (path faults, live migration, datastore operations, HA power loss), kernels 6.17 and 7.0 |
>
> The test rig is Ubuntu 24.04 (kernel 6.8.0-101-generic).  "Installed
> packages" means the release packages on two nodes of each supported
> platform: Proxmox VE 9 (kernels 6.17 and 7.0), RHEL 9.8, Ubuntu 24.04,
> Ubuntu 26.04, Debian 12 and Debian 13.  Every host in a cluster needs the
> same MeshXFS version; hosts on different kernels are fine.

> ## 0.90.129: Shared Proxmox Storage, Faster DRBD Setup, Stronger Recovery
>
> What changed for someone upgrading from 0.90.124, the last published release
> (0.90.125 to 0.90.128 were never published; their work ships here):
>
> - **Proxmox VE 9 hosts share one SAN LUN as their datastore, over
>   multipath** (0.90.129).  Three hosts on one iSCSI LUN over two storage
>   networks run guests on it: live migration with the guest writing
>   throughout, HA restart after a host loses power, snapshots and rollback,
>   backup and restore, disk moves, templates and linked clones, containers,
>   and a storage path lost and returned under load.  Verified on both
>   Proxmox VE 9 kernels: 6.17, which the 9.1 installer ships, and 7.0, which
>   `proxmox-default-kernel` now installs.
> - **A DRBD pair is set up in minutes, on whole disks** (0.90.129).  The
>   guide gives DRBD the disk that will hold the VMs and skips DRBD's first
>   copy of it, which took about an hour per 250 GB: the device is formatted
>   next, so nothing on it before is ever read.  Two physical Proxmox VE 9
>   hosts set up this way wrote at the replication link's full speed and
>   passed live migration, datastore operations, a full disk, a host reset
>   under load, a host leaving and returning cleanly, and the 31-row suite,
>   on both kernels, and through a rolling kernel upgrade with one host on
>   each.
> - **A DRBD pair whose first host dies recovers, given a QDevice** (0.90.128):
>   `authority=quorum` in `/etc/mxfs/drbd-fence.conf` lets corosync's vote
>   decide which host carries on.
> - **Fixes to locking and recovery** (0.90.128, 0.90.129): a host that dies no
>   longer stalls the others for a minute; a new lock tenure is no longer
>   taken for one already released; a waiter registration that fails no
>   longer leaves its mark on the lock; a fenced host reports being fenced,
>   not corruption; a new file on a reused inode number no longer crashes its
>   creator; a shared `mmap` write no longer hangs on RHEL 9; a full DRBD
>   filesystem refuses a write at once instead of hanging the writer.
> - **vSphere shared disks** (0.90.128): MeshXFS mounts a multi-writer VMDK
>   or a physical-mode RDM with `fence=vcenter`, `fence=manual` or
>   `fence=quorum`.  Not yet a released configuration.
> - **The module's messages say MeshXFS** (0.90.128), not XFS, and the
>   product is named MeshXFS throughout (0.90.125).
> - **Proxmox VM disk settings are documented** (0.90.129): give VM disks on
>   MeshXFS `cache=none`, the Proxmox default and the mode every Proxmox
>   validation ran with (see "Proxmox VE: VM disk settings" below).
>
> **Released configurations and what 0.90.129 was validated on:**
>
> | configuration | nodes | storage | validated on 0.90.129 |
> |---|---|---|---|
> | `2/net/mesh/drbd` | 2 | each host's own disk, DRBD 8.4 dual-primary | `tests/drbd_release_verify.sh`; two physical Proxmox VE 9 hosts set up from `docs/drbd-setup.md` (the 31-row suite, live migration, datastore operations, a full disk, a host reset and a clean departure, kernels 6.17 and 7.0) |
> | `2/net/mesh/direct` | 2 | one shared iSCSI LUN, network lock manager | the 31-row suite on the test rig; installed packages |
> | `4/net/mesh/direct` | 4 | one shared iSCSI LUN, network lock manager | the 31-row suite on the test rig; installed packages |
> | `2/disk/caw/direct` | 2 | one shared iSCSI LUN, on-disk locks | the 31-row suite on the test rig; installed packages |
> | `4/disk/caw/direct` | 4 | one shared iSCSI LUN, on-disk locks | the 31-row suite on the test rig; installed packages |
> | `8/disk/caw/direct` | 8 | one shared iSCSI LUN, on-disk locks | the 31-row suite on the test rig; installed packages |
> | `16/disk/caw/direct` | 16 | one shared iSCSI LUN, on-disk locks | the 31-row suite on the test rig; installed packages |
> | `2/disk/caw/mpath` | 2 | one shared iSCSI LUN over two paths, on-disk locks | the 31-row suite plus nine path-fault rows on the test rig |
> | `4/disk/caw/mpath` | 4 | one shared iSCSI LUN over two paths, on-disk locks | the 31-row suite plus nine path-fault rows on the test rig |
> | `8/disk/caw/mpath` | 8 | one shared iSCSI LUN over two paths, on-disk locks | the 31-row suite plus nine path-fault rows on the test rig |
> | `16/disk/caw/mpath` | 16 | one shared iSCSI LUN over two paths, on-disk locks | the 31-row suite plus nine path-fault rows on the test rig; three Proxmox VE 9 hosts on two paths (path faults, live migration, datastore operations, HA power loss), kernels 6.17 and 7.0 |
>
> The test rig is Ubuntu 24.04 (kernel 6.8.0-101-generic).  "Installed
> packages" means the release packages on two nodes of each released
> platform: Proxmox VE 9 (kernels 6.17 and 7.0), RHEL 9.8, Ubuntu 24.04
> and Debian 13.  Every host in a cluster needs the same MeshXFS
> version; hosts on different kernels are fine.

> ## 0.90.124: Multipath SAN Support, Stronger Recovery, Better Scalability
>
> What changed for someone upgrading from 0.90.116, the last published
> release:
>
> - **dm-multipath is released again for SAN clusters on the on-disk lock
>   manager** (0.90.124): `2/disk/caw/mpath`, `4/disk/caw/mpath`,
>   `8/disk/caw/mpath` and `16/disk/caw/mpath`.  Every node reaches the shared
>   iSCSI LUN through a dm-multipath map over two paths, each on its own NIC
>   and storage network.  It was last claimed in 0.90.51, and later releases
>   dropped it when defects found since then reached it.
> - **Fixed on the way there** (0.90.123, 0.90.124), each found by the
>   16-node path-fault runs: a node acquiring a directory could wait on a
>   child's lock that a peer held while that peer waited for the same
>   directory, stalling every node for eight minutes; a node that rejoined
>   after being fenced could fail to open a file, its `open()` retrying for
>   ever and impossible to kill; and an open that can never be granted now
>   fails with EIO, while a killed open always returns.
> - **More than one MeshXFS filesystem can be mounted on a host** (0.90.120).
>   Before, two filesystems on the same hosts crossed each other's lock
>   traffic: connections were reset, one filesystem could miss its peer's
>   heartbeat, and fsyncs took 17 s instead of 0.6 s.  A new mount option,
>   `transport=tcp|caw`, picks each filesystem's lock manager, so one host can
>   keep a DRBD resource mounted beside a SAN LUN.
> - **A DRBD pair with several MeshXFS resources recovers every one of them**
>   (0.90.121, 0.90.122).  When a host died, only one resource recovered and
>   the others stayed blocked; now each is fenced and recovered under its own
>   evidence.  When one replication link fails, the peer is cut off on every
>   resource the two hosts share, where before a mount could shut down or hang.
>   The module is now loaded before DRBD connects, because loading it with
>   links up could drop them.
> - **Less wasted lock work under heavy VM load on a DRBD pair** (0.90.117,
>   0.90.118).  With seven AlmaLinux installs at once on two physical Proxmox
>   VE 9 hosts with 2011-era SATA SSDs, the lock answers a host wrote for
>   requests the other host had already abandoned fell from 84 to 17, and the
>   longest a request waited in the answering host's queue fell from 39 s to
>   13 s.  An allocation now stops asking a host that has stopped answering:
>   the longest allocation walk fell from 46 s to 8.5 s.
> - **A misleading kernel warning is gone** (0.90.117): `P958-ACQ-IDLE-LOST`
>   read like a lock wait of up to 20 minutes, but every one was the leftover
>   record of a brief try that had already given up.
>
> **Still open:** under heavy load on slow disks, a VM write that needs new
> space can still wait about a second for a slow answer from the other host
> of a DRBD pair (D-REMOTE-NOQUEUE-AG-TRYLOCK-WAITS-A-FULL-ATTEMPT-PER-AG-UNDER-ILOCK).
> No write fails and no data is at risk.
>
> **Released configurations and what 0.90.124 was validated on:**
>
> | configuration | nodes | storage | validated on 0.90.124 |
> |---|---|---|---|
> | `2/net/mesh/drbd` | 2 | each host's own disk, DRBD 8.4 dual-primary | the DRBD test rig, including several resources on one pair through a host's death and a link cut; a nested Proxmox VE 9 pair with two resources through a host's death |
> | `2/net/mesh/direct` | 2 | one shared iSCSI LUN, network lock manager | the 31-row suite on the test rig; installed packages |
> | `4/net/mesh/direct` | 4 | one shared iSCSI LUN, network lock manager | the 31-row suite on the test rig; installed packages |
> | `2/disk/caw/direct` | 2 | one shared iSCSI LUN, on-disk locks | the 31-row suite on the test rig; installed packages |
> | `4/disk/caw/direct` | 4 | one shared iSCSI LUN, on-disk locks | the 31-row suite on the test rig; installed packages |
> | `8/disk/caw/direct` | 8 | one shared iSCSI LUN, on-disk locks | the 31-row suite on the test rig; installed packages |
> | `16/disk/caw/direct` | 16 | one shared iSCSI LUN, on-disk locks | the 31-row suite on the test rig; installed packages |
> | `2/disk/caw/mpath` | 2 | one shared iSCSI LUN over two paths, on-disk locks | the 31-row suite plus nine path-fault rows on the test rig |
> | `4/disk/caw/mpath` | 4 | one shared iSCSI LUN over two paths, on-disk locks | the 31-row suite plus nine path-fault rows on the test rig |
> | `8/disk/caw/mpath` | 8 | one shared iSCSI LUN over two paths, on-disk locks | the 31-row suite plus nine path-fault rows on the test rig |
> | `16/disk/caw/mpath` | 16 | one shared iSCSI LUN over two paths, on-disk locks | the 31-row suite plus nine path-fault rows on the test rig |
>
> The test rig is Ubuntu 24.04 (kernel 6.8.0-101-generic): one iSCSI path per
> node for `direct`, two for `mpath` (multipath-tools 0.9.4, the settings of
> `tools/mpath_settings.sh`).  The path-fault rows
> ([`docs/mpath-verification.md`](docs/mpath-verification.md)) run under load
> on every node: one path lost and returned and then the other, a whole
> storage network lost on every node at once, a flapping path, a mount and an
> unmount on one path, a node killed while the survivors are on one path, a
> fenced node whose dead path comes back, every path lost, a node that
> withdraws, and a lock command the target applied whose answer never
> arrived.  "Installed packages" means the release packages on two nodes of
> each of Proxmox VE 9, RHEL 9.8, Ubuntu 24.04 and Debian 13; those rounds
> attach on one path, so `mpath` is claimed on Ubuntu 24.04 only.  Not
> covered for `mpath`: a second target or storage controller, Fibre Channel or
> SAS, more than two paths, other multipath settings, and automatic failback
> to a preferred path group.  Every host in a cluster needs the same version.

> ## 0.90.116: two-host Proxmox VE on DRBD: VM disks no longer freeze on slow SSDs, and a host that leaves, fails or rejoins comes back cleanly
>
> **For `2/net/mesh/drbd`, a VM's disk writes no longer freeze on slow
> disks.**  With seven AlmaLinux installs at once on two physical Proxmox VE 9
> hosts whose DRBD sat on 2011-era SATA SSDs, a guest write that needed new
> space could hold its disk image locked for 30 s to a minute. Its lock
> request had asked only to try, but it waited on the cluster's lock-ownership
> records, which were being written to the slow disk.  Every other write to
> that image waited behind it, and the host kernel reported hung tasks.  No
> write failed and no data was lost.  0.90.116's try never touches the disk
> and never waits: when its answer is not ready, it says so at once, the write
> takes space elsewhere, and a background worker readies the answer for next
> time.  On the same disks and load, none of the slow waits remained, no task
> hung, and all seven installs finished (`CHANGELOG.md`, 0.90.115 and
> 0.90.116).
>
> **A host whose MeshXFS mount is shut down and then
> rejoins no longer hangs or stalls.**  When a host's heartbeat writes stop
> long enough, the other host declares its mount dead, recovers it, and the
> host's guard unmounts and remounts it with no restart.  On two physical
> Proxmox VE 9 hosts that rejoin had two faults when the rejoining host held
> the lower heartbeat slot:
>
> - its mount could wait minutes for an admission that never came (fixed in
>   0.90.113);
> - its first reads could take 69 to 95 s, because its peer's requests for
>   the lock pages those reads needed were queued behind a stream of other
>   hand-offs (fixed in 0.90.114).
>
> No data was lost in either.  Both were found by forcing the dropout on
> purpose (`tests/pve_pair_failover.sh` `withdraw-p0`), as happened for real on
> 2026-10-06 when a swapping host's heartbeat writes stalled.  Everyday use
> did not reach either one.  `CHANGELOG.md` has what was measured, 0.90.108
> to 0.90.114.
>
> **What 0.90.116 was validated on:**
>
> - **The six shared-LUN configurations under "Released" below**
>   (`2/net/mesh/direct`, `4/net/mesh/direct`, `2/disk/caw/direct`,
>   `4/disk/caw/direct`, `8/disk/caw/direct`, `16/disk/caw/direct`): the
>   31-row suite of each on the test rig (Ubuntu 24.04, iSCSI, one path per
>   node) at its node count, and the installed packages on two nodes of each
>   of Proxmox VE 9, RHEL 9.8, Ubuntu 24.04 and Debian 13.
> - **`2/net/mesh/drbd`**: the DRBD rig (`tests/drbd_release_verify.sh`), the
>   nested Proxmox VE 9 pair through every step of
>   `tests/pve_pair_failover.sh` (crashes, power cuts, restarts, promotions, a
>   slow heartbeat and the withdrawals), and the two physical Proxmox VE 9.1
>   hosts: seven concurrent AlmaLinux 9.7 installs at a time on MeshXFS on DRBD,
>   on both the hosts' Samsung 850 EVO and their older Kingston SATA SSDs,
>   and repeated dropout-and-rejoin laps under load.
>
> `8/net/mesh/direct`, `16/net/mesh/direct` and every `mpath` configuration
> were not tested on this release and are not claimed.

> ## 0.90.107: MeshXFS on DRBD dual-primary is released again, verified on two physical Proxmox VE 9 hosts
>
> **`2/net/mesh/drbd` is released again**: two hosts, each with its own local
> disk, replicated by DRBD dual-primary, with MeshXFS mounted read/write on both
> and no shared storage at all.  It was withdrawn on 2026-10-06, after eight
> concurrent VM installs on two physical Proxmox VE 9 hosts shut both hosts'
> MeshXFS mounts down and gave the guests I/O errors.  What that load found was
> fixed (`CHANGELOG.md`, 0.90.55 to 0.90.107), and this release was verified
> on those same two hosts as well as on the test rig:
>
> - **Two physical Proxmox VE 9.1 hosts** (HP Z400, SATA SSDs, gigabit;
>   kernel 6.17.2-1-pve, DRBD 8.4.11), installed with `make install` as
>   [`docs/drbd-setup.md`](docs/drbd-setup.md) describes: seven AlmaLinux 9.7
>   installs at once, three on one host and four on the other, every guest
>   disk on the shared filesystem, for 43 minutes.  No guest I/O error, hung
>   task, kernel warning, withdrawal or self-fence on either host.
> - **A nested Proxmox VE 9 pair**, for the failures nobody should cause on
>   hardware: a crash of either host, both hosts' power cut at once, a clean
>   reboot, a host that dies while its peer is being repaired (four ways),
>   stale and racing promotions, a slow heartbeat, and four withdrawals, each
>   under a VM-like load on both hosts with every fsynced file checked on both
>   afterwards.  All 15 passed.
> - **The test rig** (Ubuntu 24.04, DRBD 8.4.11, `tests/drbd_release_verify.sh`):
>   the cluster suite on `/dev/drbd0`, unmount and remount, a node crash, a cut
>   replication link, a split with no tie-break, a device stacked on DRBD, both
>   nodes' power cut, and a pair-outage recovery whose owner dies.  All passed.
>
> **What it is not: fast under heavy writes on modest disks.**  Both disks
> write everything and every write waits for both, so a pair has one disk's
> write capacity.  On the physical pair one AlmaLinux install on MeshXFS takes
> 1.4–1.9 times as long as on a local disk, and XFS on the same DRBD takes
> about three quarters of MeshXFS's time.  Seven installs at once did not finish
> in 43 minutes, and under that load one heartbeat write took 8.6 s (the lease
> is 60 s).  A lone sequential writer gets about three quarters of what XFS
> gets on the same DRBD: MeshXFS bounds its own writes in flight on DRBD so that
> its coordination writes are never starved.  Size the VMs on a pair to its
> disks.  Each of these is an open record in the defect queue.
>
> Also fixed, for every configuration: unmounting a filesystem that had been
> shut down could free the lock manager under a background log task and crash
> the node.  The six `direct` configurations that no open defect blocks, and
> all four platforms, were verified again on this build.  The eight `mpath`
> configurations and `8/net/mesh/direct` and `16/net/mesh/direct` are not
> claimed by this release, because defects found after 0.90.51 reach them; see
> "Released in an earlier version" below.

> ## 0.90.51: multipath, verified by taking paths away
>
> **The `mpath` attachment is released at 2, 4, 8 and 16 nodes with both lock
> managers:** `{2,4,8,16}/net/mesh/mpath` and `{2,4,8,16}/disk/caw/mpath`.
> Every node reaches the shared LUN through a dm-multipath map over two iSCSI
> paths, each path on its own NIC and its own storage network.  Each of the
> eight configurations passed the 31-row suite the `direct` configurations
> pass, and then the path-fault rows of
> [`docs/mpath-verification.md`](docs/mpath-verification.md), all under load on
> every node: one path lost and returned and then the other, a whole storage
> network lost on every node at once, a flapping path, a mount and an unmount
> on one path, a node killed while the survivors are on one path, a fenced
> node whose dead path comes back, every path lost, a node that withdraws, and
> on `disk/caw` a lock command the target applied whose answer never arrived.
> A row passes only with no failed operation on any node, no node lost that
> the row did not kill, every stall under the bound, and every acknowledged
> file read back by checksum from another node.
>
> Making those rows pass took changes to the filesystem, not only to the rig:
> a node now registers its fencing key on each path itself and follows its
> paths as they come and go, the lone survivor's fence works with one
> registration per path, a `disk/caw` lock swap whose answer was lost is
> recognised as landed, and several faults that are not specific to multipath
> were found and fixed on the way (a lock wait that lost its registration, a
> refused lock upgrade that starved behind its own node's readers, a healthy
> node shutting down behind a stalled peer, a survivor opening a dead node's
> files as directories, a lookup failing when its name was removed under it).
> `CHANGELOG.md` has each with what was measured.
>
> **What this covers:** iSCSI; two paths on separate networks to ONE target;
> the multipath and initiator settings in `tools/mpath_settings.sh`, which are
> the ones to use; the test rig's platform, Ubuntu 24.04 with kernel
> 6.8.0-101-generic and multipath-tools 0.9.4.  **What it does not:** a second
> target or storage controller, Fibre Channel or SAS, more than two paths,
> other multipath settings, automatic failback to a preferred path group, and
> the other three platforms, whose package rounds attach on one path.
>
> The eight `direct` configurations and all four platforms were verified again
> on this build.

> ## 0.90.42: sixteen nodes
>
> **`16/net/mesh/direct` and `16/disk/caw/direct` are released.**  Sixteen
> nodes mounting one LUN, with either lock manager, passed the same 31-row
> suite the smaller clusters pass — data integrity, coherency, crash and fence
> recovery, pace against native XFS — on the build this release ships, and
> the 2-, 4- and 8-node configurations and all four platforms were verified
> again on it.
>
> Two defect records stood between 8 nodes and 16.  One was disproved by
> measurement.  The other was a real fault in the `disk/caw` lock manager's
> clean-up after an abandoned lock wait, found by reading the code and never
> seen on the rig: the clean-up could act on a lock slot that had since been
> reused for a different lock.  The check that stops it from releasing that
> other lock was already in the tree; this release adds a deterministic test
> for it and fixes what the test then showed — when the slot had been reused,
> the abandoned wait's own registration was left behind, which stalls every
> other node's readers of that lock.  See `CHANGELOG.md`.

> ## 0.90.41: MeshXFS on DRBD dual-primary — a clustered filesystem with no shared storage
>
> **Two nodes, a local disk each, no SAN, no iSCSI target, no third server.**
> DRBD replicates the two disks synchronously (protocol C) with both nodes
> Primary at once, and MeshXFS mounts `/dev/drbd0` read/write on both.  The
> configuration is **`2/net/mesh/drbd`**.  This is the smallest possible MeshXFS
> cluster: two Proxmox hosts with local NVMe can share one filesystem for VM
> images and live migration without buying storage.
>
> DRBD has no SCSI underneath, so it has neither persistent reservations (how
> MeshXFS fences a dead node) nor COMPARE AND WRITE (how it claims heartbeat and
> recovery records).  MeshXFS supplies both from the attachment itself:
>
> - **Fencing through an authority outside both nodes.**  DRBD's
>   `fencing resource-and-stonith` freezes I/O when a node loses its peer and
>   runs MeshXFS's handler, which has the site's fence authority (IPMI, a PDU, the
>   hypervisor) power the peer off and hold it off.  The authority grants one
>   winner per split.  The survivor proves the peer is off, disconnected and
>   Outdated (fence proof kind 25) before every irreversible recovery step.
> - **Admission by a witness.**  A mount is refused unless DRBD is on protocol
>   C with two primaries, MeshXFS's fence handler, every split-brain policy set to
>   `disconnect`, no suspended I/O, and this node a working, UpToDate Primary.
> - **A compare-and-swap on the replicated device**: a two-party one-bit lock
>   in reserved sectors, with swaps group-committed under one acquisition.
> - **Recovery after both nodes lose power**: the first node back has the
>   authority hold its peer off, replays both journals, then lets the peer
>   rejoin.
>
> **Measured on the rig** (two nodes, DRBD 8.4.11, Ubuntu 24.04, the 0.90.41
> module built from the tree): the cluster suite's rows all passed, the
> fault rows and `crash_audit` included; a power cut of both nodes recovered
> with every file of both nodes intact, also when the recovery's completion
> was refused partway and finished by a resume; a recovery whose owner died
> was taken over and finished, by the owner's next boot and by the other
> node, every file intact; a node crash with a writer running was fenced,
> certified and recovered in 84 s with every fsynced file of both nodes
> intact; a link cut settled in 11 s and a split had exactly one winner in
> 11 s; unmount/remount cycles, a crash-cut retirement and a whole-cluster
> restart left nothing stalled; a device stacked on DRBD, and a loop device,
> were refused and left byte-identical.  Cold `chk_mxfs` clean after each.
>
> **Status: withdrawn on 2026-10-06 and released again in 0.90.107** (see the
> top of this file).  0.90.41 released it on Ubuntu 24.04 with DRBD 8.4.11,
> the platform and DRBD version everything above was measured on.  Setup
> is in "DRBD dual-primary" under Quick start, the design in
> [`docs/attachment-methods.md`](docs/attachment-methods.md) ("DRBD
> dual-primary"), and the design rulings in
> [`docs/rulings/drbd-dual-primary-attachment.md`](docs/rulings/drbd-dual-primary-attachment.md).
>
> 0.90.41 is the first published DRBD release.  The attachment was built in
> 0.90.40, whose release validation found three ways a second fault during
> pair-outage recovery could leave a volume unmountable; 0.90.40 was held
> back, all three were fixed, and the tests that found them are part of what
> passed above.  A pair outage on `2/net/mesh/direct` is also no longer left
> REFUSED when the other host is still booting.
>
> Also since 0.90.39, for every configuration: a stacked device is never resolved
> to the disk underneath it for SCSI passthrough, a compare-and-swap never
> falls back to a plain write, a node joining after a whole-cluster bootstrap
> settles the adopted victim's lock records (reads of the inodes they covered
> used to hang), and a departing node hands its lock pages off in parallel.
> See `CHANGELOG.md`.

> ## 0.90.39: `mkfs.mxfs` is no longer slow
>
> **If you tried MeshXFS before and the format alone put you off, try it again.**
> `mkfs.mxfs` used to take tens of seconds on a small LUN and minutes on a
> large one, where `mkfs.xfs` takes a moment.  It now formats a 20 GB LUN in a
> quarter of a second.
>
> | LUN | before | 0.90.39 |
> |---|---|---|
> | 10 GB | 12.4 s | 0.13 s |
> | 20 GB | 17.9–30.9 s | 0.24 s |
>
> The cause was the lock authority ledger, which mkfs lays out on the LUN and
> sizes with it.  mkfs wrote every empty page of it as its own synchronous
> 4 KiB write, about 2.3 ms each: 10,571 of them for 20 GB, 67,650 for
> 128 GiB, so the wait grew with the LUN.  It now writes
> them in large batches, flushes once at the end instead of opening the device
> `O_SYNC`, and computes CRC32C in hardware.
>
> The formatted device is byte-for-byte identical: its sha256 matches the old
> binary's output at 10 GB and 20 GB.  Every board of this release formatted
> its LUN with it, and the 8-node boards' cold audit read clean on every node.
>
> Also in 0.90.39:
>
> - **Fixes for races that could crash or wedge a node**, all in the slots
>   that let a lock-release drain re-enter the inode lock.  A design review
>   found three; this version's own self-test found a fourth.  None was seen on
>   the rig before the fixes.  A release drain that cannot claim a slot is now
>   queued and retried instead of run without one.  0.90.37 has these races,
>   so upgrade from it.
> - **The RPM builds again.**  The 0.90.38 source tarball was missing a header
>   the new mkfs needs.
> - All six released configurations were verified on this version, and the
>   release boards now run side by side, each on its own fixed-size test LUN.

> ## Released: seventeen configurations, on the `direct`, `mpath` and `drbd` attachments
>
> A configuration is four fields, `<nodes>/<class>/<method>/<attach>`, for
> example `8/net/mesh/direct`. Each field is explained in the tables below and in
> [`docs/attachment-methods.md`](docs/attachment-methods.md).
>
> ### Released
>
> | configuration | first released in | platforms |
> |---|---|---|
> | `2/net/mesh/direct` | 0.89.77 | Ubuntu 24.04 from 0.89.77, Proxmox VE 9 from 0.89.78, RHEL 9.8 from 0.89.84, Debian 13 from 0.90.0, Ubuntu 26.04 and Debian 12 from 0.90.130 |
> | `2/disk/caw/direct` | 0.90.7 | Proxmox VE 9, RHEL 9.8, Ubuntu 24.04, Ubuntu 26.04, Debian 12, Debian 13 |
> | `4/net/mesh/direct` | 0.90.24 | Proxmox VE 9, RHEL 9.8, Ubuntu 24.04, Ubuntu 26.04, Debian 12, Debian 13 |
> | `4/disk/caw/direct` | 0.90.24 | Proxmox VE 9, RHEL 9.8, Ubuntu 24.04, Ubuntu 26.04, Debian 12, Debian 13 |
> | `8/net/mesh/direct` | 0.90.51, again in 0.90.130 | Proxmox VE 9, RHEL 9.8, Ubuntu 24.04, Ubuntu 26.04, Debian 12, Debian 13 |
> | `8/disk/caw/direct` | 0.90.36 | Proxmox VE 9, RHEL 9.8, Ubuntu 24.04, Ubuntu 26.04, Debian 12, Debian 13 |
> | `16/net/mesh/direct` | 0.90.51, again in 0.90.130 | Proxmox VE 9, RHEL 9.8, Ubuntu 24.04, Ubuntu 26.04, Debian 12, Debian 13 |
> | `16/disk/caw/direct` | 0.90.42 | Proxmox VE 9, RHEL 9.8, Ubuntu 24.04, Ubuntu 26.04, Debian 12, Debian 13 |
> | `2/net/mesh/mpath` | 0.90.51, again in 0.90.130 | Ubuntu 24.04 |
> | `4/net/mesh/mpath` | 0.90.51, again in 0.90.130 | Ubuntu 24.04 |
> | `8/net/mesh/mpath` | 0.90.51, again in 0.90.130 | Ubuntu 24.04 |
> | `16/net/mesh/mpath` | 0.90.51, again in 0.90.130 | Ubuntu 24.04 |
> | `2/disk/caw/mpath` | 0.90.51, again in 0.90.124 | Ubuntu 24.04 |
> | `4/disk/caw/mpath` | 0.90.51, again in 0.90.124 | Ubuntu 24.04 |
> | `8/disk/caw/mpath` | 0.90.51, again in 0.90.124 | Ubuntu 24.04 |
> | `16/disk/caw/mpath` | 0.90.51, again in 0.90.124 | Ubuntu 24.04; Proxmox VE 9 (kernels 6.17 and 7.0, three hosts) |
> | `2/net/mesh/drbd` | 0.90.41, again in 0.90.107 | Proxmox VE 9 (kernels 6.17 and 7.0, two physical hosts set up from the guide with the release package), Ubuntu 24.04 (the test rig); DRBD 8.4.11 |
>
> All seventeen were verified on the current release, 0.90.130: each `direct`
> configuration's suite on the test rig at its node count, and the installed
> packages on two nodes of each released platform; each `mpath`
> configuration's suite and path-fault rows on the test rig at its node
> count; `2/net/mesh/drbd` on its own rig and on Proxmox VE 9 as described at
> the top of this file. A release claims exactly the configurations it lists.
>
> ### Released in an earlier version
>
> None: 0.90.130 claims every configuration an earlier release claimed.
> `8/net/mesh/direct`, `16/net/mesh/direct` and `net/mesh/mpath` at 2, 4, 8
> and 16 nodes, released in 0.90.51 and not claimed from 0.90.107, are
> released again in 0.90.130.  The `net/mesh/mpath` configurations were
> verified on the test rig only, which runs Ubuntu 24.04 (kernel
> 6.8.0-101-generic, multipath-tools 0.9.4), with the path-fault rows of
> `docs/mpath-verification.md` in each board.
>
> ### Implemented, not yet released
>
> The code runs these and the test rig can build them. No release has
> verified them yet, so they are not claimed.
>
> | method and attach | configurations |
> |---|---|
> | `net/mesh/direct` | `32/net/mesh/direct` |
> | `net/mesh/mpath` | `32/net/mesh/mpath` |
> | `net/mesh/pass` | `2/net/mesh/pass`, `4/net/mesh/pass`, `8/net/mesh/pass`, `16/net/mesh/pass`, `32/net/mesh/pass` |
> | `disk/caw/direct` | `32/disk/caw/direct` |
> | `disk/caw/mpath` | `32/disk/caw/mpath` |
> | `disk/caw/pass` | `2/disk/caw/pass`, `4/disk/caw/pass`, `8/disk/caw/pass`, `16/disk/caw/pass`, `32/disk/caw/pass` |
>
> Every other node count from 3 to 64 (3, 5 to 7, 9 to 15, and 17 and up) is in
> the same state on `net/mesh` and `disk/caw` with `direct`, `mpath` or `pass`.
> From 17 nodes up, open defects in the queue include ones that can lose data
> or hang a node.
>
> ### The four fields
>
> **`nodes`**: how many nodes mount the filesystem, 2 to 64. Released: 2, 4, 8 and 16.
>
> **`class`**: where the lock manager keeps lock state.
>
> | class | lock state lives |
> |---|---|
> | `net` | in node memory, exchanged over the network |
> | `disk` | on the shared LUN, claimed with a storage primitive |
>
> **`method`**: which lock manager of that class.
>
> | method | implemented | how it works |
> |---|---|---|
> | `net/mesh` | yes | Peer to peer over the network; lock mastership is spread across the members. The release packages default to it (`force_transport=1`). |
> | `net/server` | no | One lock server, or an active/standby pair, holds every lock. |
> | `disk/caw` | yes | SCSI COMPARE AND WRITE on a lock block on the LUN (`force_transport=0`). The storage target must implement COMPARE AND WRITE atomically (see "Choosing the transport" below). |
> | `disk/reserve` | no | SCSI-2 RESERVE/RELEASE around a plain write of the lock block. |
> | `disk/pr` | no | SCSI persistent reservations as the lock, or guarding its write. |
> | `disk/fused` | no | NVMe fused Compare+Write; the Linux block layer cannot issue it today. |
> | `disk/paxos` | no | Disk Paxos / Disk Lease: consensus on plain reads and writes. |
>
> **`attach`**: how the shared LUN reaches each node.
>
> | attach | implemented | released | the node's path to the LUN |
> |---|---|---|---|
> | `direct` | yes | yes | its own initiator, one path: bare metal, or an in-guest iSCSI login |
> | `mpath` | yes | at 2, 4, 8 and 16 nodes: `disk/caw` released in 0.90.51, not claimed from 0.90.107, released again in 0.90.124; `net/mesh` released in 0.90.51, not claimed from 0.90.107, released again in 0.90.130 | its own initiator over two or more paths, assembled by dm-multipath |
> | `pass` | yes | no | the hypervisor's initiator: the LUN is passed into the VM (QEMU SCSI passthrough). A VMware RDM mounts as `shared` instead: ESXi drops a VM's reservation key when the VM is powered off |
> | `drbd` | yes | yes: released in 0.90.41, withdrawn on 2026-10-06, released again in 0.90.107 | a DRBD dual-primary replica of two local disks: no shared storage at all |
> | `shared` | yes | no | a disk two VMs share through the hypervisor with no reservation fence MeshXFS can use (a vSphere multi-writer VMDK or physical-mode RDM): two nodes, `net/mesh`, a dead node fenced by vCenter powering its VM off or by an operator's confirmation ([`docs/shared-disk-attachment.md`](docs/shared-disk-attachment.md)) |
>
> A configuration that names a method or an attach that is not implemented does
> not exist yet. `drbd` can never be more than two nodes, because DRBD allows
> exactly two primaries, and `docs/attachment-methods.md` limits it to `net`,
> because COMPARE AND WRITE cannot be atomic across two replicas. It fences
> through a fence authority outside both nodes (power off and hold off, proof
> kind 25) instead of SCSI reservations, which DRBD does not have; the
> authority is the site's own (IPMI, a PDU, a hypervisor), and what it must
> guarantee is in `docs/attachment-methods.md`.
>
> Both implemented methods fence a dead node with SCSI persistent reservations
> on the LUN, so both need storage that implements them
> ([`docs/fencing.md`](docs/fencing.md)), except on `drbd` (above) and on
> `shared`, which is mounted with `-o fence=vcenter` or `-o fence=manual` and
> `peers=<this node>/<the other node>`, and proves a dead node's writes ended
> by its boot having ended.
>
> **Running 0.90.37 or earlier?  Upgrade.**  0.90.36 and earlier have defects
> that can lose data, and 0.90.37 has races that could crash or wedge a node
> (the claim-slot ones described under 0.90.39 above).  The data-loss defects
> were found after 0.90.36 shipped, measured on `8/net/mesh/direct`; the code
> involved is not specific to that configuration. All are fixed and verified
> since 0.90.37:
>
> - A name created in a directory that another node had just removed was lost
>   (`mkdir`, `link`, `symlink`, `rename`), and a `symlink` into such a
>   directory could shut nodes down.
> - An entry removed while other nodes were adding to its directory could
>   survive with its inode freed, and a shared directory's link count could
>   end up above its entries. A task whose lock-release claim had outlived its
>   release modified the directory with no lock grant.
> - A release claim whose owning process had exited was never retired, could
>   be inherited by an unrelated process, and could shut a node down.
>
> **The release bar: no open defect that can lose data, or crash, hang or
> shut down a node.**  A configuration has to clear it to be released, and
> `tools/defects.py <configuration> --release` shows it for each one.  The defect queue itself is public
> (`data/defects.json`, read with `tools/defects.py`), and every record carries
> its evidence.  It holds 123 open records.  54 of them reach only
> configurations this release does not claim, such as clusters larger than 16
> nodes.
> The 69 that reach a released
> configuration (between 11 and 45 each, depending on the configuration) are
> each classified as not crossing that bar, most of them as
> slowness in a particular operation: `tools/defects.py --at 2/net/mesh/drbd -d`
> lists them for one configuration.
>
> **Verified attachments on shared storage: `direct` and `mpath`**, over
> iSCSI.  With `direct` each node ran its own iSCSI initiator and reached the
> shared LUN on one path with nothing between MeshXFS and the target.  With
> `mpath` each node reached it through a dm-multipath map over two paths to
> the same target (Ubuntu 24.04, multipath-tools 0.9.4, the settings of
> `tools/mpath_settings.sh`), with paths taken away under load as
> `docs/mpath-verification.md` describes; 0.90.130 claims it for `disk/caw`
> and `net/mesh` at 2, 4, 8 and 16 nodes. `pass` is not
> verified with either method: it carries the fencing reservations and, for
> `disk/caw`, the COMPARE AND WRITE lock commands through a layer no release
> has tested. Fibre Channel and SAS are not verified. A device without SCSI
> persistent reservations (virtio-blk, NVMe, md RAID) is refused at mount.
>
> **Without shared storage: `drbd`.** Two nodes, each with a local disk,
> replicated by DRBD dual-primary and fenced without SCSI reservations
> (`2/net/mesh/drbd`, `docs/attachment-methods.md`), verified with DRBD 8.4.11
> on Proxmox VE 9 and Ubuntu 24.04 (see the top of this file).  It is installed
> from source on both hosts with `make install`
> ([`docs/drbd-setup.md`](docs/drbd-setup.md)); the release packages carry the
> same DRBD pieces, but their install has not been verified on DRBD.
>
> What a build has to pass before it is called a release, and what that does
> not cover, is in "How a release is validated" below.
>
> **Directory sharding** (`mkfs.mxfs -D` with the module parameter
> `dirshard_mkdir_enable=1`) is experimental, off by default and part of no
> release. On `4/disk/caw/direct` a node's listing of a sharded directory that
> another node had just re-created failed with "Structure needs cleaning" in 3
> of 10 laps (`D-DIRSHARD-REUSE-PEER-READDIR-EUCLEAN-ON-CAW-AT-4-NODES`).
>
> **Performance:** every released configuration passes the suite's pace rows
> against native XFS on the same storage (`fio_perf`, `fio_perf_vs_xfs`), and
> every row of the suite runs under a time budget derived from native XFS.
> Performance work continues; the open records are in the queue.
>
> **Released for exactly these kernels**, each installed from the release
> packages on two x86-64 nodes of that platform sharing an iSCSI LUN and
> verified there with both lock managers (the 2-, 4-, 8- and 16-node suites
> run on the test rig, which is the Ubuntu 24.04 row):
>
> | platform | kernel verified |
> |---|---|
> | Proxmox VE 9 | 6.17.2-1-pve, 7.0.14-19-pve |
> | Ubuntu 24.04 LTS | 6.8.0-101-generic (the GA kernel) |
> | RHEL / AlmaLinux / Rocky 9.8 | 5.14.0-687.49.1.el9_8 |
> | Debian 13 | 6.12.107+deb13-amd64 (Debian 13.7) |
> | Debian 12 | 6.1.0-53-amd64 |
> | Ubuntu 26.04 LTS | 7.0.0-38-generic (Ubuntu 26.04.1) |
>
> **Any other kernel is untested, even on the same distribution.** MeshXFS builds
> against each kernel's own API, and a distribution's kernels differ: every
> RHEL 9 minor release reports 5.14 but carries different backports (9.2 has
> far fewer than 9.8), and Ubuntu 24.04 point releases install newer HWE
> kernels. The module may not build, or may build different code, on a kernel
> not listed here. On RHEL the RPM builds the module with DKMS (from EPEL) and
> installs an SELinux rule that labels MeshXFS files as XFS files are labeled.
> Other platforms are in development or planned — see `data/platforms.json`.
>
> **Storage:** the shared storage's write cache must survive a power loss
> (battery- or flash-backed, as enterprise SAN and NAS arrays provide), or
> losing the storage target's power must be outside what the cluster has to
> survive. Crash-durable operation on unprotected caches is in development.
>
> The release packages and `make install` configure both for you:
> `/etc/modprobe.d/mxfs.conf` sets `options mxfs force_transport=1`
> (`net/mesh`) and `options mxfs target_cache_protected=1` (the storage
> declaration above); without the second a clustered mount is refused. A new cluster forms on `net/mesh` by default; `disk/caw` has to be
> asked for with `force_transport=0` (see "Choosing the transport"). To see
> what still blocks each configuration:
>
> ```
> tools/defects.py 16/disk/caw/direct --release  # released; also 2/, 4/ and 8/
> tools/defects.py 4/net/mesh/direct --release   # released; also 2/
> tools/defects.py 2/net/mesh/drbd --release     # released
> tools/defects.py 8/net/mesh/direct --release   # released; also 16/ and every .../mpath
> tools/defects.py 32/disk/caw/mpath             # 32 nodes: not released yet
> ```

---

## What MeshXFS is

MeshXFS lets **multiple nodes mount the same block device at the same time**,
read/write, with coherent caching and crash consistency — a shared-disk
clustered filesystem built as a fork of XFS.

- **One shared LUN, many nodes.** Every node opens the same device — reachable
  over SCSI (iSCSI verified; see "Verified storage attachment" above) —
  read/write, concurrently. NVMe, NVMe-oF included, is not supported: the
  fencing and lock commands are SCSI's.
- **Or two nodes and no shared storage at all.** Two hosts with a local disk
  each, replicated by DRBD dual-primary, mount one MeshXFS filesystem read/write
  on both (`2/net/mesh/drbd`, "DRBD dual-primary" under Quick start).
  Released in 0.90.107, verified on two physical Proxmox VE 9 hosts.
- **Coherent and consistent.** A write on one node becomes visible to the
  others; metadata and data stay consistent across node failures.
- **One kernel module, no daemon.** All cluster coordination — locking, peer
  discovery, membership, heartbeat, fencing — runs in-kernel inside a single
  module, `mxfs.ko`. There is no userspace cluster daemon to run.
- **XFS on disk.** File data is stored in a standard XFS v5 filesystem, wrapped
  in an MeshXFS coordination envelope (see below).

## How it works

MeshXFS is a fork of upstream Linux **XFS**, taken from the Linux 6.19
development tree (no exact upstream commit was recorded), plus a coordination
overlay.

- **Forked and heavily modified XFS.** `xfs/` began as upstream XFS and has been
  changed throughout, not only extended: it is about 314k lines against about
  226k in upstream `fs/xfs`, and core files such as `xfs_inode.c` and
  `xfs_buf.c` are several times their upstream size. The MeshXFS overlay
  (`xfs/xfs_mxfs_dlm.c` plus per-allocation-group and per-inode hooks)
  intercepts the points where nodes would otherwise collide — allocation-group
  metadata, the inode cache, the buffer cache — and coordinates them across the
  cluster. It is not a patch series against upstream today.
- **Distributed lock manager (`dlm/`).** Two lock managers are implemented:
  - **`net/mesh`** (released at 2, 4, 8 and 16 nodes on `direct` and `mpath`,
    and at 2 nodes on `drbd`) — a network DLM spoken over TCP between nodes.
  - **`disk/caw`** (released at 2, 4, 8 and 16 nodes on `direct` and
    `mpath`) — lock state lives *in-band on the shared
    disk*, claimed with the SCSI **COMPARE AND WRITE** (opcode `0x89`) atomic
    primitive plus SCSI Persistent Reservations. No separate lock network is
    required, which is what lets it scale past the point where a network DLM
    stops keeping up (more than 16 nodes is still in development).

  The module parameter `force_transport` picks the lock manager a new cluster
  forms on: `1` (the default) is `net/mesh`, `0` is `disk/caw`. The release
  packages also set `1` explicitly. A node joining an existing cluster adopts
  the lock manager the cluster's members are already using.
- **Membership and fencing.** Peers are found by UDP-multicast discovery;
  liveness is tracked by an on-disk heartbeat with per-node slot claiming; a
  departed or partitioned node is fenced with SCSI Persistent Reservations
  before its resources are recovered. Each node owns a journal slice, so a
  survivor can replay a dead node's journal.
- **Platform abstraction (`pal/`).** All OS-specific code — VFS glue, block I/O,
  FUA reads, module init — routes through a `mxfs_pal_*` layer, which also keeps
  the DLM and tools buildable in user space.
- **On-disk envelope.** `mkfs.mxfs` lays the device out as:

  ```
  [ MXFS super  4 KB ] [ journal ~64 MB ] [ disklock ~32 MB ] [ XFS v5 data … ]
  ```

  The XFS superblock is shifted past the journal and disklock regions, and the
  4 KB MXFS super carries its own magic so the device is never mistaken for — or
  mounted as — plain XFS.

### ⚠️ Use the MeshXFS tools, never the stock XFS tools

`xfs_db`, `xfs_info`, `xfs_repair`, and `xfs_admin` are the **stock XFS tools
from `xfsprogs`** (installed system-wide under `/usr/sbin`) — they are *not* part
of MeshXFS. Because of the envelope above, they read the wrong sectors and return
empty or garbage output on an MeshXFS device. MeshXFS ships its own equivalents:

| Job | Stock XFS — do **not** use | MeshXFS tool |
|---|---|---|
| Format | `mkfs.xfs` | `mkfs.mxfs` |
| Check / repair (fsck) | `xfs_repair` | `chk_mxfs -a` / `-p` / `-y` |
| Geometry / info | `xfs_info` | `chk_mxfs -v` |
| Grow | `xfs_growfs` | `resize.mxfs` |
| Low-level debug | `xfs_db` | *(none yet)* |

There is no separate `mxfs_info` or `mxfs_repair` — `chk_mxfs` does both the
repair and the geometry/info jobs. There is currently no low-level debugger
equivalent to `xfs_db`. Tool names follow the standard Linux `mkfs.TYPE` /
`fsck.TYPE` convention (`chk_mxfs` also runs as `fsck.mxfs`).

## How this was built

MeshXFS was written **entirely by AI** — specifically Anthropic's **Claude Code**,
an autonomous AI coding agent — across many development sessions. No human wrote,
hand-edited, or line-by-line reviewed the clustering code. The human/AI boundary
is clean:

- **Human-written:** the upstream Linux kernel **XFS** source MeshXFS forked,
  written by the XFS developers (their copyright notices are kept in every
  forked file).
- **AI-written:** everything that makes it *multinode* — the DLM (`dlm/`), the
  coordination overlay (`xfs/xfs_mxfs_dlm.c` and the per-AG / per-inode hooks),
  the platform abstraction (`pal/`), the on-disk envelope, the userspace tools
  (`tools/`), and the test and benchmark harnesses — **and every change made
  to the forked XFS files since the fork**, which is a large share of `xfs/`.

## How a release is validated

A release claims configurations (`<nodes>/<class>/<method>/<attach>`,
[`docs/attachment-methods.md`](docs/attachment-methods.md)) and kernels, and it
claims each only after that exact build passed everything below on it. The set
of configurations a release must have green is its release matrix
(`data/configurations.json`). Nothing is
carried over from an earlier version: when a larger cluster size is
released, the smaller ones are run again on the same build, and a
configuration that is not run again is not claimed (it is listed under
"Released in an earlier version", with the version that verified it). One script
drives the whole sequence and logs every step with its exit code
(`tests/release_verify_chain.sh`, which calls `tests/full_verify.sh`); their
headers are the reference for what follows.

### What a build must pass

1. **A build from a clean copy of the tree.** No compiler warnings, the
   userspace tools, the user-mode tests of the lock manager's authority
   ledger (`tests/tauth`), and two source audits (every cross-file
   declaration matches its definition; no two inode flags share a bit).
2. **The cluster suite, on every configuration of the release matrix.** About thirty rows (`tests/suite/manifest`), each run on a real
   cluster of that many nodes mounting one LUN:
   - what one node writes, every other node reads, and nothing is lost
     silently (`cache_coherency`, `strong_consistency`, `mmap_coherency`,
     `posix_multi`, `zero_silent_loss`, `rsync_paired`, the `dirent_*` rows,
     `dir_reuse_coherency`);
   - the lock manager under contention and membership change
     (`dlm_fairness`, `dlm_membership`, `dlm_scaling`, `scaling_curve`);
   - a node killed, or cut off from the others, in the middle of writing:
     the rest must fence it, replay its journal and go on serving
     (`crash_consistency`, `crash_audit`, `fence_during_write`,
     `fault_netpartition`);
   - no kernel fault, hang or filesystem shutdown on any node during any of
     it (`kernel_health`, `node_responsive`, `sustained_load`, `soak`);
   - the filesystem checker exits 0 on the LUN after all of it
     (`chk_clean`);
   - pace, against native XFS on the same storage (`fio_perf`,
     `fio_perf_vs_xfs`);
   - on an `mpath` configuration, the path-fault rows as well (`path_*`,
     defined in [`docs/mpath-verification.md`](docs/mpath-verification.md)):
     paths, a whole storage network and whole nodes taken away under load on
     every node. The run's log records that every node's mount sat on a
     multipath map with at least two active paths when the board started and
     when it ended, and a board that ends otherwise fails.

   The manifest lists every row with its budget.  Every row must read PASS on the board (`tools/criteria.py
   <configuration>`). The board keeps each row's last eleven runs, and a row
   with a genuine failure anywhere in that window does not read PASS: it
   has to pass lap after lap until the failure has left the window. A row
   that was skipped is not a pass either.

   Every row also has a time budget, derived from twice what the same work
   takes on native XFS plus the measured cost of forming the cluster
   (`tests/criteria/TIMEOUT_BUDGETS.md`). Running over it is a failure, even
   when every byte is right.
3. **The packages, installed as a user installs them, on every released
   platform.** On a set of nodes of that platform with a LUN of its own, as
   many nodes as the release claims: the package installs and DKMS builds
   the module against that platform's kernel; every node mounts with no
   options; each node writes 64 MiB and every other node reads it back by
   checksum; files created on one node are counted and removed on another;
   the checker exits 0; the nodes find each other by static `peer=`
   addresses with multicast dropped; every node is rebooted and the data is
   intact. Each configuration of the matrix; Proxmox on both of its kernels; RHEL with
   SELinux enforcing and its sVirt test (`tests/selinux_svirt_mxfs.sh`).
4. **A hung node, on every released platform, on each configuration of the matrix.** One
   node's CPUs are stopped in the middle of a write, so it answers nothing
   and closes nothing. The others have 120 s to declare it dead and 180 s
   to have fenced it, replayed its journal and written again
   (`tests/tcp_peer_freeze_death.sh`).
5. **The platform ledger.** `scripts/release.sh` runs each released
   platform's kernel build check and refuses to publish unless
   `data/platforms.json` holds a recorded verification of that exact version
   on every released platform (`tools/platforms.py check`).
6. **The text agrees with the data.** `tools/release_text_check.py` derives
   what is released from the release data (the release matrix, the
   configurations verified by a rig of their own, the platform ledger, the
   version, the defect queue) and reads this file, the manual pages, the
   installed module-options file, the storage guides and the module's own
   parameter descriptions against it: the Released table, the current
   version, the defect counts, the cluster sizes, and any wording that calls
   a released thing experimental, unverified, unsupported or in development.
   `scripts/release.sh` runs it before it builds a package and again before
   it publishes, and stops on a failure.
7. **The configurations with a rig of their own.** `2/net/mesh/drbd` is
   verified by `tests/drbd_release_verify.sh` (the suite on `/dev/drbd0`, then
   the remount, node-death, fence, split, device-resolution, pair-outage and
   takeover tests), not by a board column, so nothing would go red if its run
   were left out. `scripts/release.sh --publish` refuses a version without
   that script's PASS for it.

### The defect bar

The defect queue is public (`data/defects.json`, read with
`tools/defects.py`). Each record says what was observed, on what evidence,
and the smallest cluster and the configurations its evidence reaches (a
pattern such as `disk/caw/*`); a record nobody has classified counts against
every configuration.

- A configuration is released only when `tools/defects.py <configuration>
  --release` lists nothing: no open defect that reaches it and
  can corrupt or lose data, or crash, hang or shut down a node.
- A defect leaves the queue in two ways only. It is disproved by direct
  evidence, or it is fixed and verified: the cause shown by an instrument in
  the running kernel and not by reading the code, the change made at that
  cause, and a test that meets the cause passing under the criteria it had
  before. "Could not reproduce" closes nothing, and neither does a clean run
  that never met the cause.
- Where the defect is a crash or a race, the test is run on a control build
  as well. If the build without the change does not fail the way the defect
  did, the test proves nothing about the change. The 0.90.30 entry of
  `CHANGELOG.md` shows both arms for two such defects, with the numbers
  measured.

### What this does not cover

- **Every shared-storage node is a virtual machine.** The development rig and
  the platform sets are KVM guests on one host, and the shared LUNs are iSCSI
  LUNs served from that host. No release has been verified on a storage array.
  The one exception is `2/net/mesh/drbd`, which 0.90.107 verified on two
  physical Proxmox VE 9 hosts with their own local disks as well.
- **Only the kernels and cluster sizes named at the top of this file.**
- **No run longer than the suite.** The `soak` row is 30 seconds unless it
  is asked for longer, and no multi-hour soak is part of the sequence.
- **Loss of power at the storage.** The write cache is required to survive
  it (see "Storage" above).
- **Anything the suite has no row for.** A passing suite says those rows
  passed. The first time two nodes were killed at once, under load, it
  found defects that every single-death row had passed over.

The raw logs of these runs (22 GB of kernel logs and traces) stay on the
rig host and are not in this repository. What is here is every harness, the
defect queue, and a changelog that carries the measurements each release
and each fix rests on. `lab/README.md` describes how the test platforms are
built.

## Build

MeshXFS builds as an out-of-tree kernel module against the running kernel's headers.

```
make             # build the kernel module -> mxfs.ko
make install     # as root: install everything a node needs (below)
make tools       # build the userspace tools in tools/ without installing them
make load        # insmod mxfs.ko
make unload      # rmmod mxfs
```

`make install` installs what the release packages install, from the same file
list (`packaging/common.sh`): the module (`modules_install` + `depmod`), the
tools (`mkfs.mxfs`, `chk_mxfs` with its `fsck.mxfs` link, `resize_mxfs`,
`mxfs_admin`) in `/usr/sbin`, the LU-reset and DRBD witness helpers, the DRBD
fence-peer handler `/usr/sbin/mxfs-drbd-fence-peer`, the man pages,
`/etc/modprobe.d/mxfs.conf` (an existing one is kept; `make install OVERWRITE=1`
replaces it and saves the old one as `mxfs.conf.backup`), `/etc/modules-load.d/mxfs.conf`
and the udev rule. It refuses to run on a host that already has an MeshXFS
package or DKMS module installed: remove that first, or two versions of the
module and the tools end up installed under the same names.

A matching kernel build tree must be present at `/lib/modules/$(uname -r)/build`.
The module is developed against a **6.8.x** host kernel; its XFS source was
forked from the Linux 6.19 development tree, bridged by the `pal/`
compatibility layer. The
current version is recorded in [`VERSION`](VERSION).

## Tools

Installed by `make install` and by the packages.

| Tool | Installed as | Purpose |
|---|---|---|
| `mkfs_mxfs` | `/usr/sbin/mkfs.mxfs` | Format a block device for MeshXFS. |
| `chk_mxfs` | `/usr/sbin/chk_mxfs` | Check / repair and report geometry — the MeshXFS `fsck`. |
| `resize_mxfs` | `/usr/sbin/resize_mxfs` | Grow an MeshXFS filesystem after the device has been expanded. |
| `fua_verify` | — | Verify SCSI READ/WRITE **FUA** semantics across nodes on a shared LUN. |
| `caw_verify` | — | Verify SCSI **COMPARE AND WRITE** (`0x89`) persistence across nodes (built separately). |

Synopses:

```
mkfs.mxfs   [-f] [-n count] [-v] [-V] DEVICE    # -n = per-node log slices (1-64, default 4)
chk_mxfs    [-v] [-a|-p|-y|-n] DEVICE           # -n check-only (default); -a/-p/-y repair
resize.mxfs [-v] [-n] [-V] DEVICE               # -n = dry run
```

## Quick start

The released configurations are 2, 4, 8 and 16 nodes with either lock manager
(`net/mesh` or `disk/caw`), each node reaching the LUN over iSCSI on one path
(`direct`) or through dm-multipath on two (`mpath`, with the settings of
`tools/mpath_settings.sh`), and two nodes with no shared storage on DRBD
dual-primary (`2/net/mesh/drbd`, its own section below). Install
the release package from the
[Releases page](https://github.com/sshoecraft/meshxfs/releases) on every node; it
loads the module with `force_transport=1 target_cache_protected=1`, i.e.
`net/mesh`, and every node must run the same version. A source build of this
tree (`make && make install`) installs the development code, which is not a
release (see the notice at the top).
For `disk/caw`, see "Choosing the transport" below before the first mount.

```
apt install ./mxfs_<version>_amd64.deb                  # Ubuntu 24.04 and 26.04, Debian 12 and 13, Proxmox VE 9
dnf install epel-release kernel-devel-$(uname -r)       # RHEL / AlmaLinux / Rocky 9.8: DKMS is in EPEL
dnf install ./mxfs-<version>-1.el9.x86_64.rpm
```

With firewalld on, open the DLM, discovery, lock-hint and heartbeat ports on
every node:
`firewall-cmd --permanent --add-port=7600/tcp --add-port=7601/udp --add-port=7602/udp --add-port=7603/udp && firewall-cmd --reload`.
(7600/tcp carries the locks of `net/mesh`; 7602/udp carries the lock-release
requests and grant notices of `disk/caw` between the nodes.)

On the first node, format and mount the shared device:

```
mkfs.mxfs /dev/sdX
mount -t mxfs /dev/sdX /mnt/shared
```

On each other node, mount the **same** device — no reformat:

```
mount -t mxfs /dev/sdX /mnt/shared
```

The nodes discover each other and coordinate through the kernel module. Files
written on one node are visible on the others.

Discovery uses multicast (`239.66.83.1`). Where multicast does not pass, such
as Proxmox or ESXi nested inside VMware Workstation, or where one node sits on
another network, name the other node's address at mount time:

```
mount -t mxfs -o peer=10.0.0.12 /dev/sdX /mnt/shared      # on 10.0.0.11
mount -t mxfs -o peer=10.0.0.11 /dev/sdX /mnt/shared      # on 10.0.0.12
```

`peer=` adds unicast to multicast discovery and may be repeated;
`peers=A/B/...` replaces multicast with exactly that list and drops every
other sender. See `mxfs(5)` and [`docs/discovery.md`](docs/discovery.md).

A host can mount more than one MeshXFS filesystem at once, each shared with its
own set of hosts.
They share the host's ports: a lock-manager connection or datagram reaches the
filesystem it is for.  Each filesystem may run its own transport with the
`transport=tcp|caw` mount option, so a DRBD resource and a SAN LUN can be
mounted side by side; see "Choosing the transport".

### Proxmox VE: VM disk settings

Add the mount as shared directory storage once (it is cluster-wide):

```
pvesm add dir shared --path /mnt/shared --shared 1 --is_mountpoint yes \
      --content images,iso,vztmpl,backup,snippets
```

Give every VM disk on it **`cache=none`**, the Proxmox default (Hard Disk →
Cache → "Default (No cache)"):

```
qm set <vmid> --scsi0 shared:<vmid>/vm-<vmid>-disk-0.qcow2,cache=none
```

`cache=none` opens the image with `O_DIRECT`: each guest write goes to the
storage array, and the array's own write cache is used as it is for any
other host.  `writeback` and `writethrough` put the host's page cache in
between, so guest writes take the filesystem's buffered-write path and sit
in one host's RAM before they reach the shared LUN.  Every Proxmox
validation of MeshXFS (live migration, HA power loss, snapshots, backup and
restore, disk moves, path faults) ran with `cache=none`; the other modes are
not validated.

### DRBD dual-primary (`2/net/mesh/drbd`)

A released configuration (see the top of this file).  Install the latest
release's package from the
[Releases page](https://github.com/sshoecraft/meshxfs/releases), not this
development branch.

Two hosts, each with a local disk, and no shared storage, no third machine and
no fence hardware. The complete, tested setup is in
[`docs/drbd-setup.md`](docs/drbd-setup.md): the release package on both, an LVM
volume per host, the DRBD resource (protocol C, two primaries, every
`after-sb-*` `disconnect`, `fencing resource-and-stonith` with
`/usr/sbin/mxfs-drbd-fence-peer`), `mkfs.mxfs` once, and
`systemctl enable --now mxfs-drbd@<resource>` to mount at boot.

Fencing is on by default with no configuration. On losing the peer, the host
with the lower DRBD address isolates the other from itself and carries on; the
other freezes and restarts, and rejoins once it is provably out. When that
lower-address host is the one that died, the other cannot tell it from a cut
link and waits for it, which no two-node system without a third vote or fence
hardware can avoid. A node fence (IPMI, a PDU, a hypervisor) replaces the
default through `/etc/mxfs/drbd-fence.conf`. Design:
[`docs/rulings/drbd-two-node-self-exclusion.md`](docs/rulings/drbd-two-node-self-exclusion.md).

Never restore a node of this pair from saved memory or a VM snapshot, and never
force-promote or mount `/dev/drbd0` by hand.

### Choosing the transport

Both transports are released for clusters of two, four, eight and sixteen
nodes, on `direct` and on `mpath`.
Pick one per cluster, before its first mount:

| | `net/mesh` | `disk/caw` |
|---|---|---|
| Where the locks live | messages between the nodes | slots on the shared LUN, claimed with SCSI COMPARE AND WRITE |
| Storage it needs | any shared block device with SCSI Persistent Reservations | a target that implements COMPARE AND WRITE **atomically**, plus Persistent Reservations |
| Network it needs | a reliable low-latency link between the nodes | discovery and lock-release notices only (UDP) |
| How to select it | the package default (`force_transport=1`) | `force_transport=0` |

To run `disk/caw`, change the line in `/etc/modprobe.d/mxfs.conf` on **every**
node before the first mount, then reload the module (or reboot):

```
options mxfs force_transport=0
```

```
modprobe -r mxfs && modprobe mxfs
cat /sys/module/mxfs/parameters/force_transport     # 0
```

The setting survives a reboot on every released platform. On RHEL the RPM
keeps `mxfs` out of the initramfs (`/etc/dracut.conf.d/mxfs.conf`), so the
module is always loaded with the file on the root filesystem rather than a
copy baked into the boot image; an initramfs built by an earlier MeshXFS
package is rebuilt when the package is installed.

One filesystem can name its own lock manager with a mount option instead,
whatever the module setting: `-o transport=caw` or `-o transport=tcp`
(`mxfs(5)`).  A DRBD device always runs `net/mesh`, the only lock manager it
has, whatever the module setting.

The setting only chooses the lock manager of a **new** cluster: a node that
mounts a volume other nodes already have mounted joins on that cluster's lock
manager, and a mount that asks for `net/mesh` on a volume that already has
`disk/caw` members is refused. On a device that does not implement COMPARE AND
WRITE a `disk/caw` mount is refused at admission (`P311-CAW-ADMISSION-REFUSED`),
so nothing is written. Each mount logs which lock manager it runs:

```
dmesg | grep P-DOMAIN-ADMITTED       # ... transport=CAW)
```

**Not every target that accepts COMPARE AND WRITE honours it.** The Linux LIO
target reports success without an atomic compare-and-swap; on LIO use
`net/mesh`. This release's `disk/caw` verification ran on an SCST
`vdisk_fileio` iSCSI target.
For any other target, prove it first with `caw_verify` from both nodes
([`docs/iscsi_setup.md`](docs/iscsi_setup.md) §4).

**Before trusting data, verify the storage.** The shared LUN must honor durable
(FUA) writes and SCSI Persistent Reservations, which MeshXFS uses to fence a failed
node. See [`docs/iscsi_setup.md`](docs/iscsi_setup.md) for the storage
requirements, and use `fua_verify` from both nodes to prove them before you
format.

## Repository layout

| Path | Contents |
|---|---|
| `xfs/` | XFS forked from the Linux 6.19 development tree and heavily modified, plus the MeshXFS coordination overlay — the bulk of the code. |
| `dlm/` | Distributed lock managers `net/mesh` and `disk/caw`, discovery, membership, lease, disklock heartbeat, SCSI-PR fencing, journal slicing. |
| `pal/` | Platform abstraction layer — kernel/userspace split, VFS + block-I/O glue, module init. |
| `mxfs_clayer/` | Cluster-layer helpers (pinned resources, adaptive yield quantum). |
| `tools/` | Userspace binaries: `mkfs` / `chk` / `resize` / `fua_verify` / `caw_verify`. |
| `include/`, `compat/` | Shared headers and compatibility shims. |
| `tests/` | Multi-node test harness + `tests/criteria/` ship-gate verifiers. |
| `bench/` | Performance benchmarks (paired against native XFS). |
| `scripts/` | Cluster orchestration and diagnostics. |
| `packaging/` | Debian packaging. |
| `docs/` | Architecture, operator, and man-page documentation. |

## License

MeshXFS is licensed under the **GNU General Public License, version 2** (`GPL-2.0-only`)
— see [`LICENSE`](LICENSE).

MeshXFS is a fork of the Linux kernel **XFS** filesystem, which is GPL-2.0. As a
derivative work, the combined kernel module (`mxfs.ko`) is necessarily licensed
under the same terms: you are free to use, study, modify, and redistribute it,
including commercially, provided derivative works are distributed under GPL-2.0
with complete corresponding source.

Copyright (C) 2026 Stephen P. Shoecraft.
