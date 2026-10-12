#!/bin/bash
# pve_tree_install.sh — build and install this working tree on Proxmox VE hosts
# that have no MXFS yet, the way a user does from a clone (`make && make
# install`), and load the module: what a shared-LUN (SAN) cluster needs before
# scripts/pve_mxfs_san_disk.sh can format and mount it.  No DRBD, no units:
# the DRBD pair is set up by scripts/pve_pair_from_guide.sh instead, and an
# installed pair is updated by scripts/pve_pair_update.sh.
#
# Packs the sources `make install` reads (no build products, as
# pve_pair_from_guide.sh FROM_TREE=1 does), copies the pack to every host,
# installs the build dependencies, builds and installs on every host at once,
# then `modprobe mxfs` and reads back the loaded version and srcversion, which
# must be the same on every host.
#
# Usage: scripts/pve_tree_install.sh
# Env:   PVE_HOSTS     "<addr> ..." (required)
#        BUILD_BUDGET  seconds for one host's apt + build + install (default
#                      900: the nested pair's install of the same tree with the
#                      same packages, measured under 7 min, about twice that)
# Evidence: tests/evidence/pve_tree_install/<UTC stamp>/ (each host's log)
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSHP="$REPO/tools/mxfs_sshpass.sh"
read -r -a HOSTS <<<"${PVE_HOSTS:?PVE_HOSTS must name the hosts}"
BUILD_BUDGET=${BUILD_BUDGET:-900}
EVID="$REPO/tests/evidence/pve_tree_install/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$EVID" || exit 1
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$EVID/log"; }
die() { say "FAIL: $*"; exit 1; }

tar -C "$REPO" -czf "$EVID/mxfs-tree.tar.gz" \
    --exclude='*.o' --exclude='*.ko' --exclude='*.mod' --exclude='*.mod.c' \
    --exclude='.*.cmd' --exclude='*.a' --exclude='modules.order' \
    --exclude='Module.symvers' --exclude='.tmp_versions' --exclude='__pycache__' \
    --exclude='tools/mkfs_mxfs' --exclude='tools/chk_mxfs' \
    --exclude='tools/resize_mxfs' --exclude='tools/mxfs_admin' \
    --exclude='tools/fua_verify' \
    Kbuild Makefile VERSION compat include xfs dlm pal mxfs_clayer packaging \
    tools docs/drbd-setup.md docs/man \
    || die "could not pack the working tree"
say "packed $(cat "$REPO/VERSION") ($(du -h "$EVID/mxfs-tree.tar.gz" | cut -f1)) for ${HOSTS[*]}"
for h in "${HOSTS[@]}"; do
    timeout 120 "$SSHP" "$h" SCP "$EVID/mxfs-tree.tar.gz" /root/mxfs-tree.tar.gz </dev/null >/dev/null 2>&1 \
        || die "$h: could not copy the pack"
done

INSTALL="set -o pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y git build-essential proxmox-headers-\$(uname -r) open-iscsi sg3-utils > /root/mxfs-apt.log 2>&1 || { echo APT_FAIL; tail -3 /root/mxfs-apt.log; exit 1; }
    rm -rf /root/mxfs-tree && mkdir /root/mxfs-tree && tar -xzf /root/mxfs-tree.tar.gz -C /root/mxfs-tree && cd /root/mxfs-tree || exit 1
    make > /root/mxfs-make.log 2>&1 && make install >> /root/mxfs-make.log 2>&1 || { echo MAKE_FAIL; tail -5 /root/mxfs-make.log; exit 1; }
    modprobe mxfs || { echo MODPROBE_FAIL; exit 1; }
    echo INSTALLED version=\$(cat /sys/module/mxfs/version) srcversion=\$(cat /sys/module/mxfs/srcversion) tools=\$(ls /usr/sbin | grep -c mxfs)"
for h in "${HOSTS[@]}"; do
    ( timeout "$BUILD_BUDGET" "$SSHP" "$h" "$INSTALL" </dev/null 2>&1 | grep -av '^Warning:' > "$EVID/host-$h.log"
      echo "${PIPESTATUS[0]}" > "$EVID/host-$h.rc" ) &
done
wait
want=""; bad=""
for h in "${HOSTS[@]}"; do
    line=$(grep -a '^INSTALLED' "$EVID/host-$h.log" | tail -1)
    say "$h rc=$(cat "$EVID/host-$h.rc"): ${line:-$(tail -2 "$EVID/host-$h.log" | tr '\n' ' ')}"
    [ -n "$line" ] || { bad+=" $h"; continue; }
    sv=$(sed -n 's/.*srcversion=\([^ ]*\).*/\1/p' <<<"$line")
    [ -z "$want" ] && want=$sv
    [ "$sv" = "$want" ] || bad+=" $h(srcversion $sv)"
done
[ -z "$bad" ] || die "not installed alike on:$bad"
say "PVE_TREE_INSTALL_OK $(cat "$REPO/VERSION") srcversion=$want on ${HOSTS[*]}"
