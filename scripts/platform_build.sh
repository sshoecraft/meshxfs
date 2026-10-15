#!/bin/bash
#
# platform_build.sh — build the module and the node-side tools in the shared
# tree on the FIRST node of the platform about to be tested, and mark what
# they were built for
#
# Usage: scripts/platform_build.sh <node>       (a lab node name, or clyde)
#        scripts/platform_build.sh --show       print the current marker
#        PLATFORM_TREE=/root/mxfs-local scripts/platform_build.sh <node>
#               copy /src/mxfs to that node-local path first (sources only:
#               no evidence, no build products) and build there, leaving the
#               shared tree's build alone; the harnesses take it as their
#               node repository (MXFS_REPO, NODE_REPO).  So two platforms can
#               be tested at once: the shared tree built for one, a node-local
#               copy on the other.
#
# The nodes run everything from /src/mxfs over NFS: prep_node.sh loads the
# tree's mxfs.ko when its vermagic is the node's kernel, and the harness runs
# tools/mkfs_mxfs, chk_mxfs, caw_verify, fua_verify, recov_forge,
# tests/suite/tools/fsx and the rest from there.  Built on clyde (Ubuntu, glibc 2.39) the tools do not
# start on an older distribution ("version `GLIBC_2.38' not found" on
# AlmaLinux 9, glibc 2.34), and the module loads only on clyde's kernel.  So
# before testing on another platform the tree is cleaned and rebuilt on that
# platform's first node, and switched back the same way, with clyde named,
# before the rig runs again.
#
# The marker is tools/.built_for, one line:
#   node=<n> os=<ID>-<VERSION_ID> kernel=<krel> glibc=<ver> built=<UTC>
# Every other node of the platform must run the same os and kernel; a node
# that does not cannot load this build.
#
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SSH="$HERE/tools/mxfs_sshpass.sh"
MARK="$HERE/tools/.built_for"
NODE="${1:?usage: $0 <node> | --show}"

if [ "$NODE" = --show ]; then
    cat "$MARK" 2>/dev/null || echo "no marker: $MARK (built for an unknown platform)"
    exit 0
fi

# make clean empties tools/, and the module build regenerates its probe
# headers, so the tree is rebuilt from scratch on the target
BUILD='
set -u
tree=@TREE@
if [ "$tree" != /src/mxfs ]; then
    mkdir -p "$tree" && rsync -a --delete --exclude=/tests/evidence --exclude=/.ccmemory --exclude=/.git \
        --exclude="*.o" --exclude="*.ko" --exclude="*.cmd" --exclude="*.mod*" /src/mxfs/ "$tree"/ \
        || { echo "PLATFORM_BUILD_FAIL: cannot copy /src/mxfs to $tree"; exit 0; }
fi
cd "$tree" || { echo "PLATFORM_BUILD_FAIL: no $tree"; exit 0; }
. /etc/os-release
j=$(nproc)
make clean > /tmp/platform_build.log 2>&1
make -j"$j" modules >> /tmp/platform_build.log 2>&1 || { echo "PLATFORM_BUILD_FAIL: make modules (tail /tmp/platform_build.log on the node)"; tail -20 /tmp/platform_build.log; exit 0; }
make -j"$j" tools >> /tmp/platform_build.log 2>&1 || { echo "PLATFORM_BUILD_FAIL: make tools"; tail -20 /tmp/platform_build.log; exit 0; }
gcc -O2 -I tests/suite/tools -o tests/suite/tools/fsx tests/suite/tools/fsx.c >> /tmp/platform_build.log 2>&1 || { echo "PLATFORM_BUILD_FAIL: fsx"; exit 0; }
# The SG_IO and forge helpers are single-file programs outside tools/Makefile,
# and make clean leaves them in place: a caw_verify linked on clyde survived
# the first vSphere rebuild, failed to start on glibc 2.34, and
# dlm_lock_correctness read that as the array refusing COMPARE AND WRITE.
for h in tools/caw_verify tools/caw_slotdump tools/recov_forge tools/mxfs_mmapio tests/caw/caw_align_probe tests/fence_inflight/prprobe; do
    gcc -O2 -Wall -I include -o "$h" "$h.c" >> /tmp/platform_build.log 2>&1 || { echo "PLATFORM_BUILD_FAIL: $h"; tail -20 /tmp/platform_build.log; exit 0; }
done
[ "$(modinfo -F vermagic ./mxfs.ko | cut -d" " -f1)" = "$(uname -r)" ] || { echo "PLATFORM_BUILD_FAIL: mxfs.ko vermagic is not $(uname -r)"; exit 0; }
./tools/mkfs_mxfs -h >/dev/null 2>&1; [ $? -ne 127 ] || { echo "PLATFORM_BUILD_FAIL: tools/mkfs_mxfs does not start"; exit 0; }
g=$(ldd --version | head -1 | awk "{print \$NF}")
line="node=$(hostname -s) os=${ID}-${VERSION_ID} kernel=$(uname -r) glibc=$g built=$(date -u +%FT%TZ)"
# A node building as root over NFS leaves the marker owned by root, which
# clyde cannot overwrite: the redirect failed unseen, the build said OK, and
# run.sh kept naming the previous platform.  Replace the file, and say so
# when even that fails.
rm -f tools/.built_for
echo "$line" > tools/.built_for && [ "$(cat tools/.built_for)" = "$line" ] \
    || { echo "PLATFORM_BUILD_FAIL: cannot write tools/.built_for"; exit 0; }
echo "PLATFORM_BUILD_OK $line tree=$tree srcversion=$(modinfo -F srcversion ./mxfs.ko)"
'
TREE=${PLATFORM_TREE:-/src/mxfs}
case "$TREE" in /*) ;; *) echo "platform_build: PLATFORM_TREE must be an absolute path" >&2; exit 2;; esac
BUILD=${BUILD//@TREE@/$TREE}

if [ "$NODE" = clyde ] || [ "$NODE" = "$(hostname -s)" ]; then
    out=$(cd /src && timeout 900 bash -c "$BUILD" 2>&1)
else
    . "$HERE/tools/mxfs_lab.sh"
    addr=$(lab_addr "$NODE") || { echo "platform_build: cannot resolve $NODE" >&2; exit 2; }
    out=$(timeout 900 "$SSH" "$addr" "$BUILD" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you')
fi
echo "$out" | grep -a -E '^PLATFORM_BUILD_(OK|FAIL)' -A20
echo "$out" | grep -aq '^PLATFORM_BUILD_OK'
