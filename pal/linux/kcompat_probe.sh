#!/bin/sh
#
# kcompat_probe.sh — which kernel APIs the kernel being built for provides
#
# Usage: pal/linux/kcompat_probe.sh <cc> [kernel compiler flags ...]
#   Prints a C header on stdout defining MXFS_HAVE_<NAME> 1 for each API the
#   kernel's own headers provide, and leaving it undefined otherwise.  Kbuild
#   runs it from the kernel build directory with the flags every module object
#   is compiled with, so a probe answers exactly what an MXFS object would see.
#
# Why probes and not LINUX_VERSION_CODE: a distribution kernel's version names
# the base it forked from, not what it carries.  RHEL 9 reports 5.14 for every
# minor release while Red Hat backports newer block and super APIs into it
# (9.8 has super_set_uuid, the bdev file API, bio_add_vmalloc and the atomic
# write helpers) and keeps older VFS and iomap ones (update_time with a
# timespec64, an int filldir_t, iomap_page_ops).  Ubuntu backports inside a
# point series (6.8.0-101 has FALLOC_FL_MODE_MASK, 6.8.0-53 does not).  A
# version gate is wrong in one direction or the other on each of them; a probe
# of the kernel's own declarations is not.
#
# A probe is one small translation unit compiled syntax-only.  It passes only
# if the API exists with the shape MXFS uses: a missing function, member or
# type, a wrong argument count, or an incompatible pointer type fails it.  A
# probe whose compiler reports an error leaves its define unset, and the shim
# in xfs/xfs_platform.h (or the older call in pal/linux) is used.  A probe
# whose compiler was killed or crashed fails the build, naming the probe.
#
cc="$1"
shift

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# probe NAME 'includes' 'body' [exported-symbol]
#   With a fourth argument the API also has to be exported to modules: a
#   declaration proves nothing about the export (RHEL 9.8 declares
#   bio_add_folio and does not export it).  Kbuild passes the kernel's
#   Module.symvers in MXFS_SYMVERS: from 6.13 an M= build runs from the module
#   directory, where a relative path finds nothing and every export reads
#   absent.  A kernel without one answers "not provided", which selects
#   MXFS's own fallback.
symvers="${MXFS_SYMVERS:-Module.symvers}"
if [ -n "${MXFS_KCOMPAT_DEBUG:-}" ] && [ ! -r "$symvers" ]; then
    echo "kcompat_probe: no $symvers: every export-checked probe reads absent" >&2
fi
probe() {
    if [ -n "$4" ] && ! grep -q "$(printf '\t%s\t' "$4")" "$symvers" 2>/dev/null; then
        echo "/* MXFS_HAVE_$1 not provided (not exported) */" > "$tmp/$1.res"
        return
    fi
    printf '%s\n%s\n' "$2" "$3" > "$tmp/$1.c"
    (
        # -Wno-error first: a kernel built with CONFIG_WERROR would otherwise
        # fail a probe on its own harmless warnings (an unused static, a
        # missing prototype) and report a present API as absent.
        $cc -fsyntax-only -Wno-error -Werror=implicit-function-declaration \
            -Werror=incompatible-pointer-types -Werror=int-conversion \
            -Werror=return-type "$tmp/$1.c" >"$tmp/$1.err" 2>&1
        rc=$?
        if [ "$rc" -eq 0 ]; then
            echo "#define MXFS_HAVE_$1 1" > "$tmp/$1.res"
        elif [ "$rc" -ne 1 ] || ! grep -q 'error:' "$tmp/$1.err" ||
             grep -qi -e 'internal compiler error' -e 'killed' -e 'terminated' "$tmp/$1.err"; then
            # Only a compiler that ran to completion and reported an error
            # answers "absent".  One killed (the OOM killer takes cc1 and the
            # driver reports an internal error) or crashed has answered
            # nothing, and reading that as absent builds the module with a
            # fallback for an API the kernel has.
            echo "kcompat_probe $1: compiler did not complete (exit $rc):" > "$tmp/$1.fail"
            sed 's/^/    /' "$tmp/$1.err" >> "$tmp/$1.fail"
        else
            echo "/* MXFS_HAVE_$1 not provided */" > "$tmp/$1.res"
            # MXFS_KCOMPAT_DEBUG=1 in the build's environment prints why a
            # probe did not compile: a probe written wrong answers "absent"
            # exactly as a missing API does, and nothing else tells them apart
            [ -n "${MXFS_KCOMPAT_DEBUG:-}" ] && sed "s/^/kcompat_probe $1: /" "$tmp/$1.err" >&2
        fi
    ) &
    running=$((running + 1))
    if [ "$running" -ge "$jobs" ]; then
        wait
        running=0
    fi
}
# How many probes compile at once: one per CPU, and no more than available
# memory holds.  Each is a compiler driver, cc1 and a shell, ~40 MB together
# (measured: 57 at once took 2.1 GB on a 2.3 GB guest and the OOM killer took
# compilers, systemd and sshd).  The allowance is 128 MB a probe, so a host
# building its module at install time keeps room for everything else.
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || jobs=1
[ "$jobs" -ge 1 ] 2>/dev/null || jobs=1
avail_kb=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null)
if [ -n "$avail_kb" ]; then
    by_mem=$((avail_kb / 131072))
    [ "$by_mem" -ge 1 ] || by_mem=1
    [ "$by_mem" -lt "$jobs" ] && jobs=$by_mem
fi
running=0
# Inside probe(), "$@" is probe's own arguments, so the kernel flags travel in
# $cc, split at spaces when it is expanded: the form Kbuild passes them in.
cc="$cc $*"

# --- block and super APIs Red Hat backports into older bases -------------
probe SUPER_SET_UUID '#include <linux/fs.h>' \
    'void p(struct super_block *s, const u8 *u) { super_set_uuid(s, u, 16); }'
probe SUPER_SET_SYSFS_NAME_ID '#include <linux/fs.h>' \
    'void p(struct super_block *s) { super_set_sysfs_name_id(s); }'
probe BDEV_FILE_OPEN '#include <linux/blkdev.h>
#include <linux/fs.h>' \
    'struct block_device *p(void) { struct file *f = bdev_file_open_by_path("x", BLK_OPEN_READ, NULL, NULL); struct block_device *b = file_bdev(f); bdev_fput(f); return b; }'
probe SB_BDEV_FILE '#include <linux/fs.h>' \
    'struct file *p(struct super_block *s) { return s->s_bdev_file; }'
# the generation before the file API (6.7, 6.8): a bdev_handle, held by the
# super_block too.  A kernel with neither (6.1) opens with blkdev_get_by_path.
probe BDEV_OPEN_BY_PATH '#include <linux/blkdev.h>' \
    'struct block_device *p(void) { struct bdev_handle *h = bdev_open_by_path("x", BLK_OPEN_READ, NULL, NULL); struct block_device *b = h->bdev; bdev_release(h); return b; }'
probe SB_BDEV_HANDLE '#include <linux/fs.h>
#include <linux/blkdev.h>' \
    'struct bdev_handle *p(struct super_block *s) { return s->s_bdev_handle; }'
probe BLK_MODE_T '#include <linux/blkdev.h>' \
    'blk_mode_t p(void) { return BLK_OPEN_READ | BLK_OPEN_WRITE; }'
probe SB_OPEN_MODE '#include <linux/fs.h>
#include <linux/blkdev.h>' \
    'blk_mode_t p(struct super_block *s) { return sb_open_mode(s->s_flags); }'
probe FS_HOLDER_OPS '#include <linux/fs.h>
#include <linux/blkdev.h>' \
    'const struct blk_holder_ops *p(void) { return &fs_holder_ops; }'
probe BIO_ADD_VMALLOC_CHUNK '#include <linux/bio.h>' \
    'unsigned int p(struct bio *b, void *v) { return bio_add_vmalloc_chunk(b, v, 1); }'
probe BIO_ADD_VMALLOC '#include <linux/bio.h>' \
    'bool p(struct bio *b, void *v) { return bio_add_vmalloc(b, v, 1); }'
probe BIO_ADD_VIRT_NOFAIL '#include <linux/bio.h>' \
    'void p(struct bio *b, void *v) { bio_add_virt_nofail(b, v, 1); }'
probe BIO_ADD_MAX_VECS '#include <linux/bio.h>' \
    'unsigned int p(void *d) { return bio_add_max_vecs(d, 1); }'
probe BDEV_RW_VIRT '#include <linux/bio.h>
#include <linux/blkdev.h>' \
    'int p(struct block_device *b, void *d) { return bdev_rw_virt(b, 0, d, 512, REQ_OP_READ); }'
probe BDEV_CAN_ATOMIC_WRITE '#include <linux/blkdev.h>' \
    'bool p(struct block_device *b) { return bdev_can_atomic_write(b); }'
probe BDEV_ATOMIC_WRITE_UNIT_MIN_BYTES '#include <linux/blkdev.h>' \
    'unsigned int p(struct block_device *b) { return bdev_atomic_write_unit_min_bytes(b); }'
probe BDEV_ATOMIC_WRITE_UNIT_MAX_BYTES '#include <linux/blkdev.h>' \
    'unsigned int p(struct block_device *b) { return bdev_atomic_write_unit_max_bytes(b); }'
probe BDEV_VALIDATE_BLOCKSIZE '#include <linux/blkdev.h>' \
    'int p(struct block_device *b) { return bdev_validate_blocksize(b, 4096); }'

# --- atomic write reporting: present, and with which signature ------------
probe GENERIC_FILL_STATX_ATOMIC_WRITES_4 '#include <linux/fs.h>
#include <linux/stat.h>' \
    'void p(struct kstat *s) { generic_fill_statx_atomic_writes(s, 1, 1, 1); }'
probe GENERIC_FILL_STATX_ATOMIC_WRITES_3 '#include <linux/fs.h>
#include <linux/stat.h>' \
    'void p(struct kstat *s) { generic_fill_statx_atomic_writes(s, 1, 1); }'
# exported too: Debian 13's 6.12 declares it and does not export it
probe GENERIC_ATOMIC_WRITE_VALID '#include <linux/fs.h>
#include <linux/uio.h>' \
    'int p(struct kiocb *k, struct iov_iter *i) { return generic_atomic_write_valid(k, i); }' \
    generic_atomic_write_valid

# --- iomap ----------------------------------------------------------------
probe IOMAP_LAST_WRITTEN_BLOCK '#include <linux/iomap.h>' \
    'loff_t p(struct inode *i) { return iomap_last_written_block(i, 0, 1); }'
probe IOMAP_WRITE_DELALLOC_RELEASE '#include <linux/iomap.h>' \
    'static void pu(struct inode *i, loff_t o, loff_t l, struct iomap *m) { }
void p(struct inode *i, struct iomap *m) { iomap_write_delalloc_release(i, 0, 1, 0, m, pu); }' \
    iomap_write_delalloc_release
probe IOMAP_FOLIO_OPS '#include <linux/iomap.h>' \
    'const struct iomap_folio_ops *p(struct iomap *m) { return m->folio_ops; }'
probe IOMAP_ITER_PRIVATE '#include <linux/iomap.h>' \
    'void *p(struct iomap_iter *i) { return i->private; }'
probe IOMAP_DIO_BIO_SET '#include <linux/iomap.h>' \
    'struct bio_set *p(const struct iomap_dio_ops *o) { return o->bio_set; }'
# iomap's own ioend bio_set: declared AND exported, because a dio bio_set that
# names a set nobody initialized crashes the first bio_alloc_bioset from it.
probe IOMAP_IOEND_BIOSET '#include <linux/iomap.h>' \
    'struct bio_set *p(void) { return &iomap_ioend_bioset; }' \
    iomap_ioend_bioset
# Probed before xfs_platform.h defines it to 0: set only where this kernel's
# iomap bounces a direct I/O itself.
probe IOMAP_DIO_BOUNCE '#include <linux/iomap.h>' \
    'unsigned int p(void) { return IOMAP_DIO_BOUNCE; }'
probe IOMAP_DIO_RW_PRIVATE '#include <linux/iomap.h>' \
    'ssize_t p(struct kiocb *k, struct iov_iter *i, const struct iomap_ops *o) { return iomap_dio_rw(k, i, o, NULL, 0, NULL, 0); }'
# The ioend and writeback shapes changed one at a time, and a stable series
# carries some of the newer ones without the rest: Debian 13's 6.12 embeds the
# bio and passes ->map_blocks a length, yet keeps io_type and IOMAP_F_SHARED.
# With the bio embedded, iomap no longer points bi_private at the ioend, so
# the completion must find it with iomap_ioend_from_bio -- the old read still
# compiles and completes against whatever bi_private holds.
probe IOMAP_IOEND_BIO_EMBEDDED '#include <linux/iomap.h>' \
    'struct bio *p(struct bio *b) { return &iomap_ioend_from_bio(b)->io_bio; }'
# Where the bio is not embedded, iomap chains an ioend's bios and submits all
# but the last itself; the ioend's batch counter is how MXFS ends one before
# its bio fills (pal/linux/xfs_aops.c, the DRBD write bound).
probe IOMAP_IOEND_IO_FOLIOS '#include <linux/iomap.h>' \
    'u32 *p(struct iomap_ioend *e) { return &e->io_folios; }'
probe IOMAP_IOEND_FLAGS '#include <linux/iomap.h>' \
    'unsigned int p(struct iomap_ioend *e) { return e->io_flags & (IOMAP_IOEND_UNWRITTEN | IOMAP_IOEND_SHARED); }'
probe IOMAP_MAP_BLOCKS_LEN '#include <linux/iomap.h>' \
    'static int m(struct iomap_writepage_ctx *w, struct inode *i, loff_t o, unsigned int l) { return 0; }
const struct iomap_writeback_ops p = { .map_blocks = m };'
probe IOMAP_BUFFERED_WRITE_PRIVATE '#include <linux/iomap.h>' \
    'ssize_t p(struct kiocb *k, struct iov_iter *i, const struct iomap_ops *o) { return iomap_file_buffered_write(k, i, o, NULL); }'
probe IOMAP_BUFFERED_WRITE_OPS '#include <linux/iomap.h>' \
    'ssize_t p(struct kiocb *k, struct iov_iter *i, const struct iomap_ops *o) { return iomap_file_buffered_write(k, i, o, NULL, NULL); }'

# --- super_block freeze ---------------------------------------------------
# Holders (6.6) let a kernel freeze and a userspace freeze coexist.  The enum
# alone is probed: the call itself gained a third argument in 6.16.
probe FREEZE_HOLDER '#include <linux/fs.h>' \
    'enum freeze_holder p(void) { return FREEZE_HOLDER_KERNEL; }'
probe BDEV_FREEZE '#include <linux/blkdev.h>' \
    'int p(struct block_device *b) { int e = bdev_freeze(b); return e ? e : bdev_thaw(b); }'

# --- inode timestamps: accessors replaced the fields one family at a time --
probe INODE_GET_MTIME '#include <linux/fs.h>' \
    'struct timespec64 p(struct inode *i) { inode_set_mtime_to_ts(i, inode_get_atime(i)); inode_set_atime(i, 0, 0); return inode_get_mtime(i); }'
probe INODE_GET_MTIME_SEC '#include <linux/fs.h>' \
    'time64_t p(struct inode *i) { return inode_get_mtime_sec(i) + inode_get_atime_nsec(i); }'
probe INODE_GET_CTIME '#include <linux/fs.h>' \
    'struct timespec64 p(struct inode *i) { inode_set_ctime_to_ts(i, inode_set_ctime_current(i)); return inode_get_ctime(i); }'
probe INODE_GET_CTIME_SEC '#include <linux/fs.h>' \
    'time64_t p(struct inode *i) { return inode_get_ctime_sec(i) + inode_get_ctime_nsec(i); }'

# --- shrinker: allocated with a private pointer from 6.7, embedded before --
probe SHRINKER_ALLOC '#include <linux/shrinker.h>' \
    'void p(void) { struct shrinker *s = shrinker_alloc(0, "x"); s->private_data = s; shrinker_register(s); shrinker_free(s); }'

# --- dentries, lists, locking ---------------------------------------------
probe DENTRY_D_CHILDREN '#include <linux/dcache.h>' \
    'bool p(struct dentry *d) { return hlist_empty(&d->d_children); }'
probe LIST_COUNT_NODES '#include <linux/list.h>' \
    'size_t p(struct list_head *h) { return list_count_nodes(h); }'
probe RWSEM_ASSERT_HELD '#include <linux/rwsem.h>' \
    'void p(struct rw_semaphore *s) { rwsem_assert_held(s); rwsem_assert_held_write(s); rwsem_assert_held_write_nolockdep(s); }'

# --- idmapped mounts: struct mnt_idmap from 6.3, a user_namespace before --
probe MNT_IDMAP '#include <linux/fs.h>
#include <linux/mnt_idmapping.h>' \
    'struct mnt_idmap *p(struct file *f) { return f ? file_mnt_idmap(f) : &nop_mnt_idmap; }'
# 6.2 split ->get_acl into ->get_inode_acl (same shape) and a dentry-based one
probe GET_INODE_ACL '#include <linux/fs.h>' \
    'const struct inode_operations p = { .get_inode_acl = NULL };'
# The form that takes the time to set (6.1).  Probed for itself, not as the
# absence of the two-argument form, which 7.0 replaced again.
probe GENERIC_UPDATE_TIME_TIMESPEC '#include <linux/fs.h>' \
    'int p(struct inode *i, struct timespec64 *t) { return generic_update_time(i, t, S_MTIME); }'
probe POSIX_ACL_CHMOD_DENTRY '#include <linux/fs.h>
#include <linux/posix_acl.h>' \
    'int p(struct mnt_idmap *m, struct dentry *d) { return posix_acl_chmod(m, d, 0644); }'
probe SOP_SHUTDOWN '#include <linux/fs.h>' \
    'static void s(struct super_block *sb) { }
const struct super_operations p = { .shutdown = s };'
probe VMF_FS_ERROR '#include <linux/mm.h>' \
    'vm_fault_t p(int e) { return vmf_fs_error(e); }'
probe FILEMAP_SPLICE_READ '#include <linux/fs.h>
#include <linux/pagemap.h>' \
    'ssize_t p(struct file *f, loff_t *o, struct pipe_inode_info *pi) { return filemap_splice_read(f, o, pi, 1, 0); }'
probe MF_MEM_PRE_REMOVE '#include <linux/mm.h>' \
    'int p(void) { return MF_MEM_PRE_REMOVE; }'
# per-block dirty tracking in iomap (6.6); 6.1 iomap dirties a whole folio
probe IOMAP_DIRTY_FOLIO '#include <linux/iomap.h>' \
    'const struct address_space_operations p = { .dirty_folio = iomap_dirty_folio };'

# --- block ----------------------------------------------------------------
probe BIO_ADD_FOLIO_NOFAIL '#include <linux/bio.h>' \
    'void p(struct bio *b, struct folio *f) { bio_add_folio_nofail(b, f, 512, 0); }'

# --- memory ---------------------------------------------------------------
probe LIST_LRU_ADD_OBJ '#include <linux/list_lru.h>' \
    'bool p(struct list_lru *l, struct list_head *i) { return list_lru_add_obj(l, i) && list_lru_del_obj(l, i); }'
probe MM_ACCOUNT_RECLAIMED_PAGES '#include <linux/swap.h>' \
    'void p(void) { mm_account_reclaimed_pages(1); }'
probe MAPPING_MAX_FOLIO_SIZE_SUPPORTED '#include <linux/pagemap.h>' \
    'size_t p(void) { return mapping_max_folio_size_supported(); }'
probe KVREALLOC_3 '#include <linux/slab.h>' \
    'void *p(const void *o) { return kvrealloc(o, 64, GFP_KERNEL); }'

# --- VFS operation signatures ---------------------------------------------
probe UPDATE_TIME_TIMESPEC '#include <linux/fs.h>' \
    'static int u(struct inode *i, struct timespec64 *t, int f) { return 0; }
const struct inode_operations p = { .update_time = u };'
probe FILLDIR_BOOL '#include <linux/fs.h>' \
    'static bool a(struct dir_context *c, const char *n, int l, loff_t o, u64 i, unsigned int t) { return true; }
struct dir_context p = { .actor = a };'
probe ERROR_REMOVE_FOLIO '#include <linux/fs.h>
#include <linux/mm.h>' \
    'const struct address_space_operations p = { .error_remove_folio = generic_error_remove_folio };'

# --- SCSI -----------------------------------------------------------------
# The block layer's persistent-reservation reads (6.5).  Without them MXFS
# reads READ KEYS and READ RESERVATION itself, down the scsi_device.
# (blkdev.h first: pr.h names struct block_device without declaring it, so on
# its own every pr_ops member's type is a different, parameter-scoped struct)
probe PR_OPS_READ_KEYS '#include <linux/blkdev.h>
#include <linux/pr.h>' \
    'int p(const struct pr_ops *o, struct block_device *b, struct pr_keys *k) { return o->pr_read_keys(b, k); }'
probe PR_OPS_READ_RESERVATION '#include <linux/blkdev.h>
#include <linux/pr.h>' \
    'int p(const struct pr_ops *o, struct block_device *b, struct pr_held_reservation *r) { return o->pr_read_reservation(b, r); }'
# sd maps a PR command's result to an enum pr_status (6.5); before that the
# pr_ops return the raw SCSI result word
probe PR_STATUS '#include <linux/pr.h>' \
    'int p(void) { return PR_STS_RESERVATION_CONFLICT + PR_STS_PATH_FAILED + PR_STS_RETRY_PATH_FAILURE + PR_STS_PATH_FAST_FAILED + PR_STS_IOERR; }'
probe SCSI_CMND_SENSE_LEN '#include <scsi/scsi_cmnd.h>' \
    'unsigned int p(struct scsi_cmnd *c) { return c->sense_len + c->resid_len; }'

wait

if ls "$tmp"/*.fail >/dev/null 2>&1; then
    cat "$tmp"/*.fail >&2
    echo "kcompat_probe: kernel API probes did not complete; the module was not configured" >&2
    exit 1
fi

echo "/* generated by pal/linux/kcompat_probe.sh: which APIs this kernel provides */"
cat $(ls "$tmp"/*.res | sort)
