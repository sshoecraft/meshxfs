#!/usr/bin/env python3
"""Bytes for mkfs.mxfs's /dev/urandom that put one lock's CAW home slot where a lap wants it.

    tests/caw_slot_uuid.py <out file> [--ino N] [--type T] [--ag A] [--slot S]

A COMPARE AND WRITE volume keeps each lock in the slot table at the first free slot from its home,
resource_hash_raw(resource) % MXFS_CAW_MAX_SLOTS (dlm/dlm_caw.c find_slot_skip), where
resource_hash_raw is 32-bit FNV-1a over the zeroed 32-byte struct mxfs_resource_id
(dlm/dlm_shared.c, include/mxfs/mxfs_common.h: u64 volume, u64 ino, u64 offset, u32 ag_number,
u8 type, 3 pad bytes; dlm/v5_mount.c make_inode_resource and make_ag_resource memset it first).
The volume id is 64-bit FNV-1a over the superblock uuid (include/mxfs/mxfs_common.h
mxfs_uuid_to_volume_id), and mkfs.mxfs takes that uuid from the first 16 bytes of /dev/urandom,
then sets the version and variant bits (tools/mkfs_mxfs.c gen_uuid: byte 6 high nibble 4, byte 8
top bits 10). Its authority-ledger seed is the first 8 bytes of another open of /dev/urandom, so a
seed of zero, which mkfs refuses, is avoided too.

The search walks a counter through sha256 until the uuid's volume id puts the lock (default: the
root directory's inode lock, type 1 ino 128) home at the slot (default 0), and writes 4096 bytes:
the uuid as mkfs will store it, then the rest of the counter's digest stream. A lap binds the file
over /dev/urandom in a private mount namespace while it formats (as tests/mkfs_layout_identity.py
does), so the first mount's claim of that lock lands in the slot when the slot is free.

Prints 'UUID <hex> VOLUME <hex> HOME <slot> TRIES <n>'. Exit 0, or 2 on bad arguments.
"""
import argparse
import hashlib
import struct
import sys

MAX_SLOTS = 65536
LTYPE_INODE = 1


def fnv1a32(data: bytes) -> int:
    h = 2166136261
    for b in data:
        h = ((h ^ b) * 16777619) & 0xFFFFFFFF
    return h


def fnv1a64(data: bytes) -> int:
    h = 0xcbf29ce484222325
    for b in data:
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


def mkfs_uuid(raw: bytes) -> bytes:
    u = bytearray(raw[:16])
    u[6] = (u[6] & 0x0F) | 0x40
    u[8] = (u[8] & 0x3F) | 0x80
    return bytes(u)


def home(volume: int, ino: int, ltype: int, ag: int) -> int:
    resource = struct.pack("<QQQIB3x", volume, ino, 0, ag, ltype)
    return fnv1a32(resource) % MAX_SLOTS


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("out")
    p.add_argument("--ino", type=int, default=128)
    p.add_argument("--type", type=int, default=LTYPE_INODE)
    p.add_argument("--ag", type=int, default=0)
    p.add_argument("--slot", type=int, default=0)
    a = p.parse_args()
    if not 0 <= a.slot < MAX_SLOTS:
        print("ABORT: slot %d is outside 0..%d" % (a.slot, MAX_SLOTS - 1))
        return 2
    for n in range(1, 64 * MAX_SLOTS):
        raw = hashlib.sha256(b"caw_slot_uuid:%d" % n).digest()
        uuid = mkfs_uuid(raw)
        if not any(uuid[:8]):
            continue
        volume = fnv1a64(uuid)
        if home(volume, a.ino, a.type, a.ag) == a.slot:
            stream = uuid + raw[16:]
            k = n
            while len(stream) < 4096:
                stream += hashlib.sha256(b"caw_slot_uuid:%d:%d" % (n, k)).digest()
                k += 1
            with open(a.out, "wb") as handle:
                handle.write(stream[:4096])
            print("UUID %s VOLUME %016x HOME %d TRIES %d" % (uuid.hex(), volume, a.slot, n))
            return 0
    print("ABORT: no uuid found in %d tries" % (64 * MAX_SLOTS))
    return 2


if __name__ == "__main__":
    sys.exit(main())
