# MeshXFS on two hosts with DRBD dual-primary

`2/net/mesh/drbd` is released; the README names the version that last verified
it. Each release verifies it with DRBD 8.4.11 on its own two-node test rig
(Ubuntu 24.04), and the installation below was carried out exactly as written
on two physical Proxmox VE 9 hosts (0.90.130).

Two hosts, each with a local disk, and no shared storage: DRBD keeps the two
disks identical and MeshXFS runs on top of both at once. This is the `2/net/mesh/drbd`
configuration. It works with exactly two hosts and nothing else: no SAN, no
third machine, no IPMI.

Every command below is run as root. "Both nodes" means run it on each host;
"node A" means only one of them. The examples use two Proxmox VE hosts named
`pve1` (192.168.1.80) and `pve2` (192.168.1.81).

## 1. Install

On both nodes, download the latest release's `mxfs` package from the
[Releases page](https://github.com/sshoecraft/meshxfs/releases) and install it
with DRBD's tools:

```
apt install drbd-utils proxmox-headers-$(uname -r) ./mxfs_<version>_amd64.deb
```

On Debian or Ubuntu the headers package is `linux-headers-$(uname -r)`
instead. The package installs the module (built by DKMS against the running
kernel's headers, and rebuilt after a kernel update), `mkfs.mxfs` and the
other tools, the DRBD fence handler and its built-in fence authority, and two
systemd units. To move to a later release, install that release's package on
both nodes the same way.

If a MeshXFS filesystem is mounted while you upgrade, the new module takes
effect once every MeshXFS filesystem is unmounted and the module is reloaded
(`rmmod mxfs && modprobe mxfs`).

Both nodes must run the same MeshXFS version. Check with
`cat /sys/module/mxfs/version` on each. (`srcversion` is not the check: DKMS
builds the module against each kernel, so two hosts on different kernels, as
during a rolling update, show different srcversions for the same release.
That mix is supported: a pair with one host on Proxmox's 6.17 kernel and the
other on 7.0 recovered from a hard reset of one host with every file intact.)

## 2. A backing device on each node

Give DRBD the disk that will hold your VMs: a whole disk on each node is the
usual choice (a partition or an LVM logical volume also works). The two need
not be the same size; DRBD uses the smaller. Name each by its
`/dev/disk/by-id` path, which stays the same across reboots where `/dev/sdX`
may not:

```
ls -l /dev/disk/by-id/ | grep -v -- -part            # find the disk
wipefs -a /dev/disk/by-id/<this node's disk>         # both nodes
```

`wipefs` removes old partition tables and filesystem signatures, so nothing
mistakes the disk for what it held before. Everything on it is lost.

Do not use a loop device on a file. It is not recreated at boot, so the
resource cannot come back after a restart.

## 3. The DRBD resource

`/etc/drbd.d/mxfs.res`, identical on both nodes. The `on` names must be the
hosts' names exactly as `hostname` prints them, and each `disk` is that node's
own disk from section 2.

```
resource mxfs {
    net {
        protocol C;
        allow-two-primaries yes;
        after-sb-0pri disconnect;
        after-sb-1pri disconnect;
        after-sb-2pri disconnect;
        ping-int 3;             # notice a dead peer within ~7 s, not 21 s
    }
    disk {
        fencing resource-and-stonith;
        c-fill-target 4M;       # DRBD 8.4's default keeps ~50 KB in flight
        c-max-rate    110M;     # and resyncs at ~9 MB/s on gigabit; this
        c-min-rate    20M;      # lets it run at the link's speed or the
                                # slower disk's (set c-max-rate to your link)
    }
    handlers {
        fence-peer "/usr/sbin/mxfs-drbd-fence-peer";
    }
    on pve1 {
        device    /dev/drbd0 minor 0;
        disk      /dev/disk/by-id/ata-Samsung_SSD_850_EVO_250GB_S2R5NB0HA78204Z;
        address   192.168.1.80:7788;
        meta-disk internal;
    }
    on pve2 {
        device    /dev/drbd0 minor 0;
        disk      /dev/disk/by-id/ata-Samsung_SSD_850_EVO_500GB_S2RANXAH208584Y;
        address   192.168.1.81:7788;
        meta-disk internal;
    }
}
```

MeshXFS refuses to mount unless `protocol`, `allow-two-primaries`, every
`after-sb-*`, `fencing` and `fence-peer` are exactly as above. Do not add
`become-primary-on`: the `mxfs-drbd@` unit promotes the node only once it is
safe. For the same reason, leave the resource and the mount out of Pacemaker
(no `ocf:linbit:drbd` or `Filesystem` resource for them). A node that comes
back has to stay Secondary until the other has replayed its journal, and
after both nodes went down the first mount needs the other node Secondary;
another promoter keeps it Primary, so the mount would be refused at every
attempt. When either is set up, `mxfs-drbd@` refuses to start and its journal
names what else manages the resource.

`ping-int` decides how long the surviving node's writes stop when its peer
dies. DRBD notices a dead peer by a keep-alive that goes unanswered, and while
writes are in flight that takes up to twice `ping-int` plus `ping-timeout`
(0.5 s); every write on the survivor waits for it. With DRBD's default of 10 s
the survivor's VMs stopped for 21 s in our tests; with 3 s, for 7 s. A
keep-alive is sent only when the link is otherwise idle, so the shorter
interval adds no traffic under load. A change to `ping-int` on a running pair
takes effect when the connection is next made.

## 4. Bring DRBD up, with no initial copy

```
drbdadm create-md mxfs && drbdadm up mxfs        # both nodes
drbdadm -- --clear-bitmap new-current-uuid mxfs  # node A only, once both show Connected
```

On a disk that held anything before, `create-md` stops at "Found some data
==> This might destroy existing data! <==" and asks whether to proceed: it
looked where it keeps its own records, at the end of the disk, and found
bytes there. Type `yes`. (`wipefs` clears signatures, not that area.)

`cat /proc/drbd` then shows `cs:Connected ro:Secondary/Secondary
ds:UpToDate/UpToDate` on both nodes, at once.

DRBD's default for a new resource is to copy one whole disk to the other,
because it cannot know the disks hold nothing anyone needs. Here they do not:
the next step formats the device, and every write from then on, the format's
included, goes to both disks. What was on the disks before stays only in what
the new filesystem calls free space, which it never reads before writing.
So the copy is skipped; on a 250 GB disk over gigabit it would take about an
hour. (`drbdadm verify` compares every block, so it will list blocks the
filesystem has never written as different. They are never read.)

## 5. Format, once

```
drbdadm primary mxfs                             # node A only
mkfs.mxfs /dev/drbd0                             # node A only
```

A device that already holds a filesystem is refused; add `-f` to overwrite it.

## 6. Mount at boot

On both nodes:

```
systemctl disable drbd
echo MOUNTPOINT=/mnt/shared > /etc/mxfs/drbd-mxfs.conf
systemctl enable --now mxfs-drbd@mxfs
```

`drbd.service` stays disabled: `mxfs-drbd@mxfs` brings the resource up itself,
and only after it has checked that the node may, so a reboot never brings the
resource back on its own. `mxfs-drbd@mxfs` brings the resource up, waits until DRBD is Connected with both
disks UpToDate, promotes the node, and mounts; pve1, if it was running alone,
gives pve2 30 s and then mounts without it (section 7). At shutdown it unmounts and
steps down, so the other node carries on. Check it with
`systemctl status mxfs-drbd@mxfs`, and see why MeshXFS admitted or refused the
mount with `dmesg | grep P-DRBD-ARM`.

Proxmox starts the guests marked "start at boot" and its HA services only once
the unit reports the filesystem mounted, so a VM whose disk is on
`/mnt/shared` does not fail to start because the mount came late. If the
mount cannot happen within `GUEST_WAIT` seconds of the unit starting (default
300; the peer is down or still booting), guests on local storage start
without waiting, and the unit starts the remaining "start at boot" guests
itself once it has mounted. Set another bound with a `GUEST_WAIT=<seconds>`
line in `/etc/mxfs/drbd-mxfs.conf`.

On Proxmox, add the mount as shared directory storage once (it is cluster-wide):

```
pvesm add dir shared --path /mnt/shared --shared 1 --is_mountpoint yes \
      --content images,iso,vztmpl,backup,snippets
```

With `--shared 1`, a live migration (`qm migrate <vmid> <node> --online`)
moves only the guest's memory: both hosts open the same disk image, the
source until the switchover, the target from then on. Give a guest that
must migrate a CPU type both hosts can run. `host` migrates only between
identical CPUs, and Proxmox's default `x86-64-v2-AES` needs AES-NI on both.
With an older CPU on one host (e.g. a Nehalem Xeon W3520, which has no
AES-NI), use `x86-64-v2`:

```
qm set <vmid> --cpu x86-64-v2
```

Give every VM disk on the storage `cache=none`, the Proxmox default (Hard
Disk → Cache → "Default (No cache)"). It writes the guest's I/O straight to
the DRBD device with `O_DIRECT`; `writeback` and `writethrough` hold it in
one host's page cache first, and they are not the modes this pair was
validated with.

`tests/pve_live_migrate.sh` checks a pair end to end: a guest writing and
fsyncing throughout is migrated back and forth, and after every move each
file it wrote is read back from disk on the new host and checked.

## 7. What happens when a node is lost

Either node carries on when the other dies only with a third vote or a node
fence, so the pair needs one of them before it mounts. Write it into
`/etc/mxfs/drbd-fence.conf` on both nodes:

- `agent=self` and `authority=quorum`: corosync's vote, with a QDevice
  (`corosync-qnetd` on any third machine). How the vote decides is in
  `docs/quorum-takeover.md` ("The DRBD pair").
- `agent=exec` or `agent=ssh`: a node fence (IPMI, a PDU, a hypervisor) that
  powers the lost node off. The contract it must keep is in
  `docs/attachment-methods.md` ("The fence authority is the site's").

With neither (no file, or `agent=self` alone), the mount is refused and the
kernel log names both (`dmesg | grep P-DRBD-ARM-REFUSED`). The pair's fixed
tie-break alone would let only one of the two nodes outlive the other: the
node with the lower DRBD address cannot be told dead from a cut cable.

That node (here `pve1`) is participant 0; the other is participant 1.

- **pve2 dies, or loses its network.** pve1's writes stop until DRBD notices
  (up to ~7 s with the `ping-int` above). Then pve1 isolates pve2 from itself
  (the DRBD port and MeshXFS's ports, nothing else), takes DRBD StandAlone, and
  carries on, and MeshXFS replays pve2's journal; a VM on pve1 that needs a file
  pve2 was writing waits for that replay too, ~17 s after pve2's death in our
  tests. When pve2 is back and reports MeshXFS unmounted, pve1 releases it, DRBD
  resyncs pve2 from pve1, and `mxfs-drbd@mxfs` mounts it again.
  pve1's fence handler resumes pve1's frozen I/O itself (`drbdadm
  resume-io`) once pve2 is isolated, before it answers DRBD. Left to resume
  it on the answer, the in-kernel DRBD 8.4 driver writes its metadata while
  holding an RCU read lock, which the kernel reports as a WARNING ("Voluntary
  context switch within RCU read-side critical section", from
  `drbd_uuid_new_current`); `resume-io` does the same work without that lock.
  The driver bug itself is fixed by the patch in `upstream/linux/` in this
  repository.
- **pve1 dies.** The same with the roles swapped: under the vote pve2 is
  quorate without pve1 and carries on; with a node fence pve2 powers pve1 off
  and carries on.
- **The replication link breaks with both nodes alive.** One node carries on,
  and the other freezes, logs why, and restarts itself, then rejoins as
  above. Under the vote, while corosync still sees both nodes, the vote has no
  answer for 45 s and then the fixed tie-break picks pve1; with a node fence,
  the fence picks.
- **pve1 is shut down or restarted on purpose.** Its unit unmounts, steps
  down and takes DRBD down before the network stops, so DRBD disconnects
  gracefully and pve2 carries on.
- **A node restarts while the other is still down.** Under the vote it mounts
  alone only on its own standing exclusion of the other (it carried on when
  the other was lost), never on DRBD's record of which copy is newer, which a
  crash can leave stale on disk; otherwise it waits for the other node. With a
  node fence, pve1 gives pve2 30 s to connect and then, if DRBD records pve1's
  copy as the newer one, isolates pve2 and mounts alone, about two and a half
  minutes after the boot in our tests; pve2 in the same case waits for pve1.
- **A node's mount shuts down while the node stays up.** MeshXFS withdraws a
  node that lost its standing: no heartbeat of its own landed within its
  60 s authority lease, because its writes to the shared device stalled for
  that long. From then on every access to `/mnt/shared` on that node fails
  with an I/O error. A heartbeat that is merely slow costs nothing: every
  write waits for both disks, so one host's overloaded disk slows the other's
  writes too, and a beat may take up to about 29 s. `mxfs-drbd-guard`
  sees this within seconds (`/sys/fs/mxfs/drbd0/shutdown` reads 1) and
  rejoins the node without restarting it. It kills every process holding the
  mount at once, the VMs whose disks are on it among them: they can no longer
  read or write them, and a `qm stop` would pull their power too, only one VM
  at a time. Proxmox cleans each one up as after a guest crash. Then it
  unmounts the mount and restarts `mxfs-drbd@mxfs`, which mounts it again as
  after a restart of that node, and starts the on-boot guests. The node stays
  Secondary until the other node has replayed its old mount's journal (it asks
  over ssh; at most 3 min). Being Secondary on a connected link is how the
  other node knows the old mount is gone, so a node that promoted first would
  hold up that replay, and with it its own mount. Other VMs it killed stay
  stopped, and
  the journal names each one. It rejoins at most three times an hour. A mount
  that keeps shutting down stays down until you restart `mxfs-drbd@mxfs`, and
  the kernel log says why each time. A mount that cannot be released, because
  something the guard cannot stop holds it, restarts the host as in the cases
  above.
- **A host never promotes itself while the other is unreachable** unless it
  holds an exclusion of the other. A `drbdadm primary` run then is refused.
- **Both nodes crash or lose power at once.** When they come back, DRBD
  reconnects and resyncs. Then pve2 waits, Secondary, while pve1 mounts: pve2
  being Secondary on a connected link is DRBD's own proof that no old mount is
  left on it, and pve1 replays both nodes' journals. pve2 mounts once pve1 has
  (it asks pve1 over ssh), about two and a half minutes after the boot in our
  tests. If one of them does not come back, the other waits for it, unmounted:
  at boot neither can tell a dead peer from a cut cable.

The release check uses ssh between the nodes as root. A Proxmox cluster
already has that trust; on other systems set up root keys both ways, with the
peer's host key known under its DRBD host name.

To use a real node fence instead (IPMI, a PDU, a hypervisor), write
`/etc/mxfs/drbd-fence.conf` with an `agent=exec` or `agent=ssh` authority; the
contract it must keep is in `docs/attachment-methods.md` ("The fence authority
is the site's").

## Never

- Never run `drbdadm primary --force`, `drbdadm resume-io`, or `drbdadm outdate`
  outside step 4, and never mount `/dev/drbd0` by hand. Each of these can put
  two writers on two copies of the data.
- Never restore either node from a VM snapshot or saved memory.
- Never edit the resource on one node only.
