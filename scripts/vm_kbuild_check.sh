#!/bin/bash
#
# vm_kbuild_check.sh — compile mxfs.ko on a platform's own lab VM
#
# Usage: scripts/vm_kbuild_check.sh <platform> [KREL ...]
#
# Builds the module on the first node of the platform's verification set (the
# lab file's `nodes` line, tools/mxfs_lab.sh), against the headers of the
# kernel the node runs and of each KREL given (e.g. a Proxmox node carries
# both of its claimed kernels).  The node is a VM built on this host with
# mkosimage (lab/README.md); a platform with no verification set cannot be
# checked here, and this says so and fails.  Checks never run in a container
# or on a downloaded image: neither is the platform a user runs.
#
# The node is held in the VM pool for the length of the build (vmhold_take,
# tests/lib/runlock.sh), started if it is off, and left to the pool when this
# exits: tools/vm_pool.sh shuts it off once nobody has held it for its grace.
#
# The source is staged the way the packages stage it (packaging/common.sh)
# and compiled from a clean copy, as DKMS compiles it on a user's node.
#
# Budget per kernel: INSTALL_S of tests/packaged_round.sh, the measured DKMS
# compile of the whole module scaled to a lab guest (660 s); the compile alone
# is the larger part of that install.  Over budget is a FAIL.
#
# Prints VM_KBUILD_OK <platform> <node> <krel> <srcversion> or
# VM_KBUILD_FAIL <platform> <node> <krel> per kernel, followed by the
# compiler's error lines for a failure.  Exits non-zero if any build failed.
#
set -u

PLAT="${1:?usage: vm_kbuild_check.sh <platform> [KREL ...]}"
shift
SRCDIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH="$SRCDIR/tools/mxfs_sshpass.sh"
BUILD_S=660
SCP_S=60

. "$SRCDIR/tools/mxfs_lab.sh"
. "$SRCDIR/tests/lib/runlock.sh"
. "$SRCDIR/packaging/common.sh"
# common.sh turns on errexit for the packaging scripts; here a filter that
# prints nothing (grep -v of a silent command) is not a failure
set +e

NODES=$(lab_nodes "$PLAT") || { echo "VM_KBUILD_FAIL $PLAT: no verification set in the lab file (lab/README.md)"; exit 1; }
NODE=${NODES%% *}
vmhold_take "vm_kbuild_check $PLAT" "$NODE" || { echo "VM_KBUILD_FAIL $PLAT: cannot hold $NODE in the VM pool"; exit 1; }
"$SRCDIR/tools/vm_pool.sh" up "$NODE" || { echo "VM_KBUILD_FAIL $PLAT: $NODE did not come up"; exit 1; }
# once this exits, the pool shuts the node off if nobody else takes it up
( setsid "$SRCDIR/tools/vm_pool.sh" release --after $$ "$NODE" </dev/null >/dev/null 2>&1 & )
H=$(lab_addr "$NODE") || { echo "VM_KBUILD_FAIL $PLAT: no address for $NODE"; exit 1; }

# on SECONDS CMD — the node's output, the remote command's rc (124 = over budget);
# pam_nologin's banner prefixes every reply while a node is still booting
on() {
    local t=$1; shift
    timeout "$t" "$SSH" "$H" "$@" 2>&1 | grep --line-buffered -v -E "^Warning: Permanently|^$|Unauthorized access|authorized user, disconnect|System is booting up\. Unprivileged users"
    return "${PIPESTATUS[0]}"
}

STAGE=$(mktemp -d)
trap 'rm -rf -- "$STAGE"' EXIT
mxfs_stage_kmod_source "$STAGE/src" >/dev/null
tar -C "$STAGE" -czf "$STAGE/mxfs-kbuild.tgz" src
timeout "$SCP_S" "$SSH" "$H" SCP "$STAGE/mxfs-kbuild.tgz" /root/mxfs-kbuild.tgz >/dev/null 2>&1 \
    || { echo "VM_KBUILD_FAIL $PLAT $NODE: copying the source failed"; exit 1; }

KRELS="$(on 20 'uname -r' | tail -1) $*"
rc=0
for k in $(echo $KRELS | tr ' ' '\n' | awk 'NF && !seen[$0]++'); do
    out=$(on "$BUILD_S" "
        hdr=/lib/modules/$k/build
        [ -f \$hdr/Makefile ] || { echo 'NO_HEADERS $k'; exit 3; }
        rm -rf /root/mxfs-kbuild && mkdir /root/mxfs-kbuild && tar -C /root/mxfs-kbuild -xzf /root/mxfs-kbuild.tgz || exit 4
        # -k: keep compiling past a failed object, so one run lists every file
        # that does not build rather than only the first few make reached
        if make -k -s -j\$(nproc) -C \$hdr M=/root/mxfs-kbuild/src modules >/root/mxfs-kbuild/kbuild.log 2>&1; then
            echo \"SRCVERSION \$(modinfo -F srcversion /root/mxfs-kbuild/src/mxfs.ko)\"
            echo \"KCOMPAT \$(sed -n 's/^#define MXFS_HAVE_\([A-Z0-9_]*\) 1\$/\1/p' /root/mxfs-kbuild/src/pal/linux/mxfs_kcompat.h | paste -sd ' ')\"
        else
            grep -E 'error:|ERROR:|undefined!|not found|error while loading|No such file|Error [0-9]' /root/mxfs-kbuild/kbuild.log | sort | uniq -c | sort -rn | head -300
            exit 1
        fi")
    r=$?
    if [ "$r" = 0 ]; then
        echo "VM_KBUILD_OK $PLAT $NODE $k $(echo "$out" | sed -n 's/^SRCVERSION //p')"
        echo "  kcompat $k: $(echo "$out" | sed -n 's/^KCOMPAT //p')"
    else
        case $r in
            3)   why="no headers for $k installed on $NODE" ;;
            124) why="over the ${BUILD_S} s budget" ;;
            *)   why="rc=$r" ;;
        esac
        echo "VM_KBUILD_FAIL $PLAT $NODE $k ($why)"
        echo "$out"
        rc=1
    fi
done
on 30 'rm -rf /root/mxfs-kbuild /root/mxfs-kbuild.tgz' >/dev/null
exit $rc
