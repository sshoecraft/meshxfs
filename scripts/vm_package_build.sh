#!/bin/bash
#
# vm_package_build.sh — build the release packages on the lab's own VMs
#
# Usage: scripts/vm_package_build.sh deb|rpm <out-dir>
#
#   deb  mxfs_<v>_amd64.deb and pve-storage-mxfs_<v>_all.deb, built on the
#        first node of the debian12 set: Debian 12 is the oldest Debian-family
#        system the packages target, so the userspace tools it links need no
#        newer glibc (2.36) than Debian 12, Ubuntu 24.04 or Proxmox VE 9 have.
#   rpm  mxfs-<v>-1.el9.x86_64.rpm, built on the first node of the rhel9 set
#        (AlmaLinux 9.8, the RHEL release the packages are verified on).
#
# The nodes are VMs built on this host with mkosimage (lab/README.md), held
# through the VM pool for the build and left to it afterwards.  Packages are
# never built in a container or on a downloaded image.
#
# The tree is copied to the node without its evidence, history, build
# products or dist/, and the packaging scripts run there unchanged
# (packaging/mkdeb.sh, mkdeb_pve.sh, mkrpm.sh <out-dir>).  Each package comes
# back over ssh and is accepted only if its sha256 matches the node's.  The
# kernel module is not compiled here: the packages carry its source, and DKMS
# builds it on the system that installs them.
#
# Budgets: copying the ~400 MB tree over the lab bridge, 120 s; the build
# packages (gcc make rsync dpkg-dev / rpm-build), installed once per node,
# 300 s (the Debian 12 after-build steps, a full upgrade, measured 122 s);
# the tools compile and the archives, 300 s (the container builds they
# replace took about a minute each); each package back, 60 s.
#
set -u

KIND="${1:?usage: vm_package_build.sh deb|rpm <out-dir>}"
OUT="${2:?usage: vm_package_build.sh deb|rpm <out-dir>}"
SRCDIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH="$SRCDIR/tools/mxfs_sshpass.sh"
case "$KIND" in
    deb) PLAT=debian12
         DEPS="DEBIAN_FRONTEND=noninteractive apt-get -q update >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get -q -y install gcc make rsync dpkg-dev >/dev/null"
         BUILD="packaging/mkdeb.sh /root/mxfs-pkg/out && packaging/mkdeb_pve.sh /root/mxfs-pkg/out" ;;
    rpm) PLAT=rhel9
         DEPS="dnf -q -y install gcc make rsync rpm-build tar gzip >/dev/null"
         BUILD="packaging/mkrpm.sh /root/mxfs-pkg/out" ;;
    *)   echo "usage: vm_package_build.sh deb|rpm <out-dir>" >&2; exit 2 ;;
esac
mkdir -p "$OUT" || exit 2

. "$SRCDIR/tools/mxfs_lab.sh"
. "$SRCDIR/tests/lib/runlock.sh"
NODES=$(lab_nodes "$PLAT") || { echo "PKG_BUILD_FAIL $KIND: no $PLAT set in the lab file"; exit 1; }
NODE=${NODES%% *}
vmhold_take "vm_package_build $KIND" "$NODE" || { echo "PKG_BUILD_FAIL $KIND: cannot hold $NODE"; exit 1; }
"$SRCDIR/tools/vm_pool.sh" up "$NODE" || { echo "PKG_BUILD_FAIL $KIND: $NODE did not come up"; exit 1; }
# from a subshell that exits at once: never a child a caller's bare wait would block on
( setsid "$SRCDIR/tools/vm_pool.sh" release --after $$ "$NODE" </dev/null >/dev/null 2>&1 & )
H=$(lab_addr "$NODE") || { echo "PKG_BUILD_FAIL $KIND: no address for $NODE"; exit 1; }
echo "=== $KIND packages on $NODE ($PLAT, $H) ==="

on() {
    local t=$1; shift
    timeout "$t" "$SSH" "$H" "$@" 2>&1 | grep --line-buffered -v -E "^Warning: Permanently|^$|Unauthorized access|authorized user, disconnect|System is booting up\. Unprivileged users"
    return "${PIPESTATUS[0]}"
}

STAGE=$(mktemp -d)
trap 'rm -rf -- "$STAGE"' EXIT
B=$(basename "$SRCDIR")
# The packages' inputs, named: the module source DKMS builds, the tools, the
# packaging scripts and what they install.  Packing the whole tree took in the
# boards and their run ledgers too, which runs write while a package builds,
# and tar fails a file that changes under it.  The packaging scripts name every
# file they need and fail on a missing one, so a new input fails here loudly
# rather than shipping without it.
INPUTS=(compat include xfs dlm pal mxfs_clayer Kbuild Makefile VERSION tools packaging
        docs/man docs/drbd-setup.md frontend/proxmox)
tar -C "$SRCDIR/.." -czf "$STAGE/tree.tgz" \
    --exclude='*.o' --exclude='*.ko' --exclude='.*.cmd' --exclude='*.mod.c' \
    --exclude='__pycache__' "${INPUTS[@]/#/$B/}" \
    || { echo "PKG_BUILD_FAIL $KIND: could not pack the package inputs"; exit 1; }
echo "PKG_INPUTS $KIND sha256=$(sha256sum "$STAGE/tree.tgz" | awk '{print $1}') inputs=[${INPUTS[*]}]"
on 30 "rm -rf /root/mxfs-pkg && mkdir -p /root/mxfs-pkg/out" || { echo "PKG_BUILD_FAIL $KIND: workdir"; exit 1; }
timeout 120 "$SSH" "$H" SCP "$STAGE/tree.tgz" /root/mxfs-pkg/tree.tgz >/dev/null 2>&1 \
    || { echo "PKG_BUILD_FAIL $KIND: copying the tree to $NODE"; exit 1; }
on 300 "$DEPS" || { echo "PKG_BUILD_FAIL $KIND: build packages did not install on $NODE"; exit 1; }
on 300 "cd /root/mxfs-pkg && tar -xzf tree.tgz && cd $B && $BUILD" > "$STAGE/build.log"
rc=$?
if [ "$rc" != 0 ]; then
    why="rc=$rc"; [ "$rc" = 124 ] && why="over the 300 s budget"
    echo "PKG_BUILD_FAIL $KIND: the packaging scripts failed on $NODE ($why); last lines:"
    tail -30 "$STAGE/build.log"
    exit 1
fi
files=$(on 20 "cd /root/mxfs-pkg/out && ls -1") || { echo "PKG_BUILD_FAIL $KIND: no output listing"; exit 1; }
[ -n "$files" ] || { echo "PKG_BUILD_FAIL $KIND: the build left no package"; exit 1; }
for f in $files; do
    want=$(on 20 "sha256sum /root/mxfs-pkg/out/$f" | awk '{print $1}')
    timeout 60 "$SSH" "$H" "cat /root/mxfs-pkg/out/$f" > "$OUT/$f" 2>/dev/null
    got=$(sha256sum "$OUT/$f" | awk '{print $1}')
    if [ -z "$want" ] || [ "$want" != "$got" ]; then
        echo "PKG_BUILD_FAIL $KIND: $f did not arrive intact (node $want, here $got)"
        exit 1
    fi
    echo "PKG_BUILD_OK $KIND $f sha256=$got built_on=$NODE"
done
on 30 "rm -rf /root/mxfs-pkg" >/dev/null
exit 0
