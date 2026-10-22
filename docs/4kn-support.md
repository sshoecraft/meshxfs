# 4K-native shared LUNs

A 4K-native (4Kn) LUN reports 4096-byte **logical** blocks: the smallest unit it reads, writes or
compares. Most new arrays present LUNs this way. A 512e LUN (512-byte logical blocks over 4096-byte
physical ones) is a 512-byte device as far as MeshXFS is concerned and needs nothing here.

This is the design for formatting and running MeshXFS on a LUN of any supported logical block size.
The owner's ruling it implements (2026-10-19, recorded in the defect queue's 4Kn record) is:

- the sector size is taken from the device at format time;
- **every structure that two nodes write independently gets a logical block of its own, never a
  share of one** — a read-modify-write of a block another node also writes is corruption;
- COMPARE AND WRITE is issued in device logical blocks;
- the tools follow the device's block size;
- a volume on a 512-byte device keeps today's layout, byte for byte.

## The unit of atomicity

A device reads, writes and compares whole logical blocks; nothing smaller exists on the wire. Call
the device's logical block size **L** (512 or 4096; `BLKSSZGET` in user space,
`bdev_logical_block_size()` in the kernel).

On a 512-byte device, MeshXFS relies on one property everywhere: a 512-byte record written by one
node never shares its unit of atomicity with a record another node writes. The disklock heartbeat
slots, the 65536 lock slots, the bootstrap sectors, the PR registrant entries and the slice
lifecycle records are each 512 bytes, at 512-byte stride. On an L = 4096 device the same stride
would put eight of them in one block, and every write of one would carry seven stale neighbours.

So the rule is applied once, mechanically: **each 512-byte record unit of an MXFS region occupies
its own logical block**. The record keeps its 512-byte structure in the block's first 512 bytes;
the rest of the block is zero. Whatever two nodes shared inside one 512-byte record on a 512-byte
device (the bootstrap completion tombstones, eight per sector, CAW-written) they share inside the
same 512 bytes on a 4Kn device, protected by the same COMPARE AND WRITE. Nothing that is private
today becomes shared, and no algorithm that reads or writes a record changes — only where the record
sits and how the PAL moves it.

## The format records its block size

- The envelope gains an incompatible flag, `MXFS_FORMAT_F_LBS`, and a `logical_block_size` field
  carved from `reserved`. mkfs sets both only when L > 512, so every 512-byte volume, existing or
  new, is unchanged. A kernel that does not know the flag refuses the volume, as gate-aware kernels
  refuse every unknown envelope flag.
- **Mount refuses a mismatch**, naming both sizes: a device whose logical block size differs from
  the one the volume records (absent flag = 512). That covers an image moved between a 512-byte
  and a 4Kn array in either direction.
- mkfs supports L = 512 and L = 4096. It refuses anything else, naming the size: XFS's sector size
  cannot exceed the 4096-byte filesystem block, and no 1024- or 2048-byte device has been seen.

## Layout of a 4Kn volume, region by region

Region order and the 4 KiB alignment between regions are unchanged. Sizes below are for L = 4096.

| Region | On a 512-byte device | On a 4Kn device | Who writes a unit |
|---|---|---|---|
| super | 4096 | 4096 (one block) | mkfs, offline tools |
| journal | journal super + one 1 MiB slot per node, 512-byte sectors | each 512-byte sector in a block of its own | the slot's owner only |
| disklock heartbeats | 64 × 512 | 64 × L | each node its own |
| disklock lock slots | 65536 × 512 = 32 MiB | 65536 × L = 256 MiB | any node, by CAW |
| recovery manifest | 64 slots of 2 MiB + 64 KiB | unchanged: every structure is 4096-aligned and sized | see below |
| TCP authority ledger | 4 KiB pages; 512-byte ticket and root | 4 KiB pages; the root and the ticket protocol use the whole page as one block (`docs/tauth-view-table.md`) | the resource's master, by CAW |
| PR registrant ledger | 256 × 512 | 256 × L | each registrant its own, by CAW |
| bootstrap | 64 sectors × 512 | 64 × L | by CAW, per sector map |
| slice lifecycle | 64 × 512 | 64 × L | the slice's claimant |
| XFS data | `sb_sectsize` 512 | `sb_sectsize` = L, `sb_logsectsize` = L | see below |

The lock-slot table stays at 65536 slots: its size is layout, not a tunable. On a 4Kn LUN it costs
256 MiB instead of 32 MiB.

**The journal** is a record region like the others, although each slot has one writer and could be
packed at L: the kernel only claims and releases its slot (the slot header), so packing would save
space and nothing else. The space is the cost of keeping one rule: 1 MiB of slot becomes 8 MiB.

**The recovery manifest** is already page-structured. Every write to it must be a whole number of
blocks at a block-aligned offset, and no block may have two writers. Any write found during
implementation that does not meet both is changed to meet them before 4Kn is enabled.

### XFS on a 4Kn volume

XFS supports 4096-byte sectors natively; MeshXFS has to match what mkfs.xfs would do:

- `sb_sectsize` = L, `sb_sectlog` = 12, `sb_logsectsize` = L, `sb_logsectlog` = 12, and
  `XFS_SB_VERSION_SECTORBIT` in `sb_versionnum`: without that bit the superblock check refuses any
  nonzero log sector size (`xfs_validate_sb_common`). A 512-byte volume keeps the bit clear and both
  log sector fields zero, as today;
- the AG headers each take a sector of their own: superblock at byte 0 of the AG, AGF at L, AGI at
  2L, AGFL at 3L (XFS addresses them as `n << m_sectbb_log`); mkfs and resize_mxfs write them there
  instead of packing them into the AG's first 4 KiB. Each header's CRC covers its whole sector, and
  the AGFL holds (L − 36) / 4 entries, the unused ones `NULLAGBLOCK`;
- everything mkfs places after the headers moves down by the three blocks they now take: the free
  space, inode and free-inode btree roots at AG blocks 4-7 instead of 1-4, the AGFL's blocks at 8-11
  instead of 5-8, and the log at block 8 of its AG instead of 5. AG 0's first inode chunk stays at
  block 16 (it is aligned to 8 blocks), so the free gap in front of it is blocks 12-15;
- each per-node log slice starts and ends on an L boundary, and the log writes in L units
  (`l_sectBBsize` = 8): with no log stripe unit, each iclog write is rounded to the log sector
  size, as upstream's `xlog_alloc_log` does, never to 512. A v2 log is required for a log that
  does not start at block 0, and MeshXFS logs are v2.
- The inode size stays 512, eight inodes to a logical block.

## The inode cluster: where XFS itself shares a block between nodes

Every XFS structure other than inodes is written whole, under one lock: AG headers under the AG
lock (each in its own sector), directory and btree blocks under their inode's or AG's lock, the
superblock under the summary lock. Inodes are the exception. A cluster buffer holds many inodes, and
different nodes can hold the authority for different inodes in it.

On a 512-byte device MeshXFS never writes a peer's inode. Inode writeback writes only the sectors of
the slots this node owns and logged: the partial inode-buffer write in `pal/linux/xfs_buf.c`, with
one sector per inode. On a 4Kn device that is impossible. Eight inodes share each block, and
the partial write's geometry check (`inodesize % sectsize != 0`) sends the buffer to the
whole-buffer write. That write carries this node's stale copies of up to seven peers' inodes: the
inode-cluster clobber the partial write exists to prevent.

**The merged write.** On a device whose logical block holds more than one inode, in a multi-node
mount, every write of an inode cluster buffer becomes, for each logical block holding at least one
slot this node must write:

1. read the block from the device, bypassing every cache (the PAL's forced FUA read);
2. copy this node's slots into that image from the in-core buffer, leaving every other slot as the
   device holds it;
3. COMPARE AND WRITE the block, with FUA: compare against the image as read, write the merged
   image;
4. on MISCOMPARE (a peer wrote one of its own slots in that block since step 1) start again from
   step 1.

A peer's slot is never written from this node's copy, so no stale inode can land. Each dinode
carries its own CRC and `xfs_inode_buf_verify` validates each one separately, so a merged block is as
valid as its parts. Two nodes writing different slots of one block serialise on the device. A
MISCOMPARE costs one more read, and only when they actually overlap in time.

The slots a node must write are exactly the set the partial write already computes: the slots with
a live inode log item, the slots a foreign log recovery patched (`b_mxfs_recov_slots`), and the
buffer log item's dirty ranges, less the slots its refusal rules exclude.

Every path that writes an inode cluster buffer in a multi-node mount goes through it:

- AIL writeback (today's partial write), with merging as the per-block primitive;
- each of today's whole-buffer fallbacks (`nopag`, `geom`, `declined`, `empty`). On a device
  whose block holds several inodes there is no safe whole write, so each one becomes a merged write
  of its owed slots, or a refused write that leaves the buffer dirty. It never becomes a whole
  write;
- the surgical per-inode write;
- the foreign log recovery's write of a dead node's slots.

A brand-new inode chunk is the one whole write that stays safe. The allocating node initialises
it under the AG lock before the AGI publishes it, so no other node can hold an inode in it yet.

The retry loop is bounded. A block that keeps miscomparing past the bound means a peer is
rewriting the same block without pause, which nothing in the protocol does. The write fails with
`-EIO`, the buffer stays dirty and the failure is printed. It never falls back to a whole write.
Between one read and its swap, at most the block's other slot owners (seven, at 4096) can each
land a write of their own; the bound is four such rounds, 4 × (inodes per block − 1).

The partial write's masks count sectors; where a sector holds several inodes they count slots, one
bit an inode, and every rule that decides which slots this node owes is unchanged. The swap is
the PAL's block COMPARE AND WRITE, which compares the whole block and does not depend on the
ledger's span knob. It runs on a handle of the data device the mount keeps for it.

- A buffer that still carries the readahead verifier is an inode cluster like any other, and is
  merged.
- A write that cannot be merged (a buffer of several maps, one with no AG, a geometry the slot
  masks cannot express) is refused with `-EIO`, not written whole.
- The surgical per-inode write, which writes one inode's bytes at a time, does not run where a
  sector holds several inodes.
- Counters `iwr_merge_blocks`, `iwr_merge_miscompares`, `iwr_merge_failed` and `iwr_merge_empty`
  say what the merge did, so a test can tell a pass that exercised the retry from one that did not.

**Why not a lock.** A per-block lock would mean a new lock class with its own blocking callback,
cache and recovery, plus a lock round trip on every inode writeback. The device already offers an
atomic read-modify-write of exactly one logical block. Every supported attachment provides it:
SCSI COMPARE AND WRITE on the shared LUN, and the PAL's COMPARE AND WRITE emulation on DRBD.
Both transports already depend on it: the disklock tables and the TCP authority ledger are
written with it.

**Cost.** Each dirty block costs one read and one COMPARE AND WRITE, instead of one write per dirty
sector. That is measured against native XFS like any other workload, under the same 2× ceiling.

## Device I/O in logical blocks (`pal/`)

- **Block I/O.** `bi_sector` stays in 512-byte units, as the kernel defines it. Every offset and
  length the PAL submits must be a multiple of L. The PAL checks this and refuses with `-EINVAL`
  and a message naming the caller, instead of letting the block layer fail the bio less clearly.
- **SCSI passthrough** (READ(16), WRITE(16), COMPARE AND WRITE): LBA = byte offset / L and
  NUMBER OF LOGICAL BLOCKS = length / L. A COMPARE AND WRITE carries 2 × L bytes per block: the
  compare image, then the write image. Today every CDB carries 512-byte units, which address the
  wrong block on a 4Kn device.
- **Record regions, translated once.** The journal, the disklock heartbeat and lock tables, the
  PR registrant ledger, the bootstrap region and the slice lifecycle region are *record regions*.
  The DLM keeps addressing them as it does on a 512-byte device: `region start + unit × 512`.
  At mount, the PAL takes the volume's record-region table from the envelope and maps a byte
  offset inside a record region to `region start + (offset − start) / 512 × L + (offset − start)
  mod 512`, so every 512-byte unit lands in a block of its own. No caller's arithmetic changes,
  and the rule lives in one place. On these regions:
  - a read gathers the first 512 bytes of each block it spans;
  - a write scatters each 512-byte unit into its block, followed by a zero tail;
  - a COMPARE AND WRITE compares `[expected][zero tail]` and writes `[new][zero tail]`, one
    block per record.

  A block whose tail is not zero miscompares on every attempt. The PAL reports that as damage
  (the block's offset and its first nonzero tail byte) instead of retrying it.

  The PAL keeps each region as absolute device offsets. A handle opened at another base offset
  (the DLM's view of the XFS data area is one) addresses the device through its base, so an access
  is matched against the regions at `base + offset`: a region start taken relative to one handle's
  base would match the wrong bytes through any other.
- **The transport scratch block.** On a 512-byte device the 4 KiB alignment gap after the journal
  holds a scratch sector at `disklock_offset − 512`, where `caw_verify` and `fua_verify` write
  without touching any region. On a 4Kn device the journal's span is a whole number of blocks and
  there is no gap, so mkfs leaves one block of its own before the disklock region, at
  `disklock_offset − L`.
- **Page regions.** The recovery manifest and the TCP authority ledger are page-structured and
  are not translated: every access to them must already be whole blocks, and the PAL refuses one
  that is not.
- **Whole-page COMPARE AND WRITE** (the TCP authority ledger's page swap): on a 4Kn device a page
  is one block. Its swap is a single-block COMPARE AND WRITE, so the 512-only gate on the span
  path goes away.
- **Buffers.** The 512-byte stack buffers on the record and COMPARE AND WRITE paths become
  allocations of L, or of 2 × L for COMPARE AND WRITE.
- **DRBD.** A DRBD device takes the largest logical block size of its backing disks. DRBD over
  4Kn backing disks is supported exactly as a 4Kn LUN is (owner, 2026-10-22). The COMPARE AND WRITE
  emulation and its registry work in units of the DRBD device's logical block size, under the same
  rules: one compare and one write of a whole block, never a swap of 512-byte sectors inside one.

## Tools

- `mkfs_mxfs` reads L with `BLKSSZGET`, lays the volume out as above and records L.
- `chk_mxfs`, `resize_mxfs` and `mxfs_admin` take L from the envelope, and check that the device
  still reports it. `mxfs_admin`'s refusal of any `sectsize` other than 512 becomes a check that
  `sectsize` equals L.
- `caw_verify`, `fua_verify`, `caw_slotdump` and `recov_forge` address the device in its own
  logical blocks, from `BLKSSZGET`. Their LBA arguments are device LBAs.

## Before support: refuse with the cause

Until every part above is in place, mkfs refuses a device whose logical block size is not 512, and
the mount refuses one, each naming the size. Today mkfs fails at its first write with
`pwrite ... Invalid argument`, and the mount fails with "Invalid superblock magic number". Neither
names the cause.

## Verification

- **A 4Kn LUN class on the rig.** A pool LUN carries its block size: SCST `blocksize=4096` through
  `scripts/scst_setup.sh`, `tools/lun_pool.sh` creating either size. Boards run on both sizes,
  and the release matrix names the block size as a dimension of a configuration's attachment.
- **512-byte volumes are unchanged.** mkfs on a 512-byte device writes byte-identical metadata
  before and after, given the same uuid and geometry.
- **Rows aimed at the new code:**
  - two nodes dirtying different inodes of the same 4 KiB block at once (creates and setattrs in
    one directory from both nodes): every inode intact, `chk_mxfs` clean, and the merged write's
    MISCOMPARE retries counted, so a pass is known to have exercised them;
  - fence and foreign replay on a 4Kn volume;
  - the CDB unit, by `caw_verify` and `fua_verify` against known LBAs of a 4Kn LUN.

## Open

- **1024- and 2048-byte logical blocks.** These are refused at format, and the rule above extends
  to them unchanged.
