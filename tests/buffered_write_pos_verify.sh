#!/bin/bash
#
# buffered_write_pos_verify.sh — does a buffered write() on MXFS advance the
# file position, with the module built from THIS tree on a platform node.
#
# Debian 12 (6.1) lost data on every buffered write larger than one write()
# call: each write returned its full count but left the file position where
# it was, so the next one overwrote it (an 8 MiB dd left a 1 MiB file).  Until
# 6.5 iomap_file_buffered_write left the position to its caller; the fork's
# callers rely on the later iomap that advances it.
#
# On the platform's first node (held through the VM pool), this:
#   1. builds mxfs.ko from this tree against the node's running kernel and
#      loads it in place of the installed one (insmod: the package's
#      modprobe.d options are passed explicitly, insmod does not read them);
#   2. formats the platform's LUN (its lab file's storage line) and mounts it
#      alone;
#   3. checks: four 1 MiB write()s leave the position at 1/2/3/4 MiB; an
#      O_APPEND write lands at EOF; pwrite() does not move the position;
#      64 MiB written by dd bs=1M and by cp read back identical after
#      drop_caches; then tests/dio_stable_writes_read.sh;
#   4. unmounts, unloads the test module, and removes its files.
# The node is left with no MXFS module loaded; the next packaged round or
# reboot loads the installed one.
#
# Budgets: the build is INSTALL_S of tests/packaged_round.sh (660 s); the
# checks are 64 MiB twice plus small writes (native XFS ~1 s each) and one
# mkfs and mount (~10 s measured) -> 120 s; dio_stable_writes_read.sh keeps
# its own 60 s.
#
# Usage: tests/buffered_write_pos_verify.sh <platform>
#   MXFS_LAB defaults to ~/.config/mxfslab/lab.<platform> when that file exists.
#
set -u

PLAT="${1:?usage: buffered_write_pos_verify.sh <platform>}"
SRCDIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH="$SRCDIR/tools/mxfs_sshpass.sh"
BUILD_S=660
CHECK_S=120
EV="$SRCDIR/tests/evidence/buffered_write_pos_verify/${PLAT}_$(date +%Y%m%dT%H%M%S)"
mkdir -p "$EV"
exec > >(tee -a "$EV/run.log") 2>&1
say() { echo "[$(date +%T)] $*"; }

# the platform's own lab file names its LUN (tests/full_verify.sh writes it)
[ -z "${MXFS_LAB:-}" ] && [ -f "$HOME/.config/mxfslab/lab.$PLAT" ] && export MXFS_LAB="$HOME/.config/mxfslab/lab.$PLAT"
. "$SRCDIR/tools/mxfs_lab.sh"
. "$SRCDIR/tests/lib/runlock.sh"
. "$SRCDIR/packaging/common.sh"
set +e

NODES=$(lab_nodes "$PLAT") || { say "RESULT FAIL: no verification set for $PLAT"; exit 2; }
NODE=${NODES%% *}
LUN=$(lab_need storage lun) || { say "RESULT FAIL: no storage line (set MXFS_LAB)"; exit 2; }
vmhold_take "buffered_write_pos_verify $PLAT" "$NODE" || exit 2
"$SRCDIR/tools/vm_pool.sh" up "$NODE" || exit 2
( setsid "$SRCDIR/tools/vm_pool.sh" release --after $$ "$NODE" </dev/null >/dev/null 2>&1 & )
H=$(lab_addr "$NODE")
say "platform=$PLAT node=$NODE ($H) lun=$LUN evidence=$EV"

on() {
    local t=$1; shift
    timeout "$t" "$SSH" "$H" "$@" 2>&1 | grep --line-buffered -v -E "^Warning: Permanently|^$|Unauthorized access|authorized user, disconnect|System is booting up\. Unprivileged users"
    return "${PIPESTATUS[0]}"
}

STAGE=$(mktemp -d)
trap 'rm -rf -- "$STAGE"' EXIT
mxfs_stage_kmod_source "$STAGE/src" >/dev/null
tar -C "$STAGE" -czf "$STAGE/k.tgz" src
timeout 60 "$SSH" "$H" SCP "$STAGE/k.tgz" /root/mxfs-poscheck.tgz >/dev/null 2>&1 || { say "RESULT FAIL: copy"; exit 1; }

on "$BUILD_S" "rm -rf /root/mxfs-poscheck && mkdir /root/mxfs-poscheck && tar -C /root/mxfs-poscheck -xzf /root/mxfs-poscheck.tgz && make -s -j\$(nproc) -C /lib/modules/\$(uname -r)/build M=/root/mxfs-poscheck/src modules >/root/mxfs-poscheck/build.log 2>&1; echo build_rc=\$?; echo kernel=\$(uname -r) built_srcversion=\$(modinfo -F srcversion /root/mxfs-poscheck/src/mxfs.ko)"

on "$CHECK_S" "bash -s" <<EOF
grep -q " /mnt/mxfs " /proc/mounts && timeout 30 umount /mnt/mxfs
modprobe -r mxfs
# insmod resolves no dependencies: load them first, as modprobe would
for m in \$(modinfo -F depends /root/mxfs-poscheck/src/mxfs.ko | tr , ' '); do modprobe \$m; done
insmod /root/mxfs-poscheck/src/mxfs.ko force_transport=1 target_cache_protected=1; rc=\$?
loaded=\$(cat /sys/module/mxfs/srcversion 2>/dev/null)
built=\$(modinfo -F srcversion /root/mxfs-poscheck/src/mxfs.ko)
echo insmod_rc=\$rc loaded_srcversion=\$loaded built_srcversion=\$built
# a failed load lets mount autoload the installed module, and every check
# below would then grade the wrong build
[ "\$rc" = 0 ] && [ "\$loaded" = "\$built" ] || { echo "MODULE_LOAD FAIL"; exit 1; }
# mkfs.mxfs comes from the installed package: a node that has never had it
# (ubuntu2604, fresh from mkosimage) ran every check below on its root
# filesystem and printed PASS for each before the mount check failed it
command -v mkfs.mxfs >/dev/null || { echo "NO_PACKAGE: mkfs.mxfs is not installed; run tests/packaged_round.sh $PLAT first"; exit 1; }
mkfs.mxfs -f $LUN >/dev/null 2>&1; rc=\$?; echo mkfs_rc=\$rc
[ "\$rc" = 0 ] || exit 1
mkdir -p /mnt/mxfs; timeout 60 mount -t mxfs $LUN /mnt/mxfs; rc=\$?; echo mount_rc=\$rc
[ "\$rc" = 0 ] && grep -q " /mnt/mxfs mxfs " /proc/mounts || { echo "MOUNT FAIL: the checks would grade another filesystem"; exit 1; }
python3 - <<'PY'
import os
ok = True
fd = os.open("/mnt/mxfs/poscheck", os.O_CREAT | os.O_WRONLY | os.O_TRUNC)
for i in range(4):
    n = os.write(fd, b"x" * 1048576); p = os.lseek(fd, 0, os.SEEK_CUR)
    print("write", i, "returned", n, "pos", p); ok &= (n == 1048576 and p == (i + 1) << 20)
os.close(fd)
fd = os.open("/mnt/mxfs/poscheck", os.O_WRONLY | os.O_APPEND)
n = os.write(fd, b"y" * 4096); p = os.lseek(fd, 0, os.SEEK_CUR); s = os.fstat(fd).st_size
print("append returned", n, "pos", p, "size", s); ok &= (p == (4 << 20) + 4096 and s == p)
os.close(fd)
fd = os.open("/mnt/mxfs/poscheck", os.O_WRONLY)
n = os.pwrite(fd, b"z" * 4096, 8192); p = os.lseek(fd, 0, os.SEEK_CUR)
print("pwrite returned", n, "pos", p, "(must stay 0)"); ok &= (n == 4096 and p == 0)
os.close(fd)
print("POSITION_CHECKS", "PASS" if ok else "FAIL")
PY
head -c 67108864 /dev/urandom > /root/mxfs-poscheck/s64
dd if=/root/mxfs-poscheck/s64 of=/mnt/mxfs/dd64 bs=1M conv=fsync status=none
cp /root/mxfs-poscheck/s64 /mnt/mxfs/cp64; sync; echo 3 > /proc/sys/vm/drop_caches
stat -c "%n size=%s" /mnt/mxfs/dd64 /mnt/mxfs/cp64
cmp /root/mxfs-poscheck/s64 /mnt/mxfs/dd64 && echo DD64 MATCH || echo DD64 MISMATCH
cmp /root/mxfs-poscheck/s64 /mnt/mxfs/cp64 && echo CP64 MATCH || echo CP64 MISMATCH
rm -f /mnt/mxfs/poscheck /mnt/mxfs/dd64 /mnt/mxfs/cp64
EOF

grep -q "MODULE_LOAD FAIL" "$EV/run.log" && { on 60 "rm -rf /root/mxfs-poscheck /root/mxfs-poscheck.tgz"; say "RESULT FAIL: the tree's module did not load"; exit 1; }
"$SRCDIR/tests/dio_stable_writes_read.sh" "$H" /mnt/mxfs 64 | grep -E "srcversion|want=|got =|RESULT"

on 60 "timeout 30 umount /mnt/mxfs; echo umount_rc=\$?; rmmod mxfs; echo rmmod_rc=\$?; rm -rf /root/mxfs-poscheck /root/mxfs-poscheck.tgz"
dmesg_bad=$(on 20 "dmesg | grep -c -E 'BUG:|Oops|WARNING:|Call Trace'")
say "kernel bad lines: $dmesg_bad"
if grep -q "POSITION_CHECKS PASS" "$EV/run.log" && grep -q "DD64 MATCH" "$EV/run.log" && grep -q "CP64 MATCH" "$EV/run.log" \
   && grep -q "RESULT PASS" "$EV/run.log" && [ "$dmesg_bad" = 0 ]; then
    say "RESULT PASS"; exit 0
fi
say "RESULT FAIL"; exit 1
