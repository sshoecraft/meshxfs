#!/bin/bash
#
# userfreeze_peer_demand.sh — what happens on a node frozen from userspace
# (fsfreeze -f) when its peer asks for a lock the frozen node holds?
#
# The peer's request reaches the frozen node as a BAST and ends its tenure;
# the release makes a clean-release marker durable before the unlock
# (mxfs_relmark_publish, xfs/xfs_relmark_item.c), which commits a log-only
# transaction.  xfs_trans_alloc warns on any transaction at
# SB_FREEZE_COMPLETE unless the single-to-multi join holds the freeze, so a
# userspace freeze is expected to show whether that path warns, blocks the
# peer, or neither.
#
# On the platform's two nodes A and B (lab file; installed package's module,
# or MODULE=tree to build this tree on both):
#   1. format the platform's LUN on A, mount it on A and then on B;
#   2. A creates a directory and files in it (A holds the directory's tenure);
#   3. A: fsfreeze -f;
#   4. B: create a file in that directory and list it, timed, bounded;
#   5. A: fsfreeze -u;
#   6. read A's kernel log for WARNING/BUG/Oops and P-RELMARK lines.
#
# Budgets: mkfs 60 s, each mount 60 s (an idle 2-node mount ~7-10 s measured
# in the packaged round), B's create+list 30 s (a lock handoff on an idle
# 2-node cluster is well under a second; 30 s covers one lease-bounded wait).
#
# Usage: tests/userfreeze_peer_demand.sh <platform> [tree]
#   MXFS_LAB defaults to ~/.config/mxfslab/lab.<platform> when it exists.
#
set -u

PLAT="${1:?usage: userfreeze_peer_demand.sh <platform> [tree]}"
MODULE="${2:-}"
SRCDIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH="$SRCDIR/tools/mxfs_sshpass.sh"
EV="$SRCDIR/tests/evidence/userfreeze_peer_demand/${PLAT}_$(date +%Y%m%dT%H%M%S)"
mkdir -p "$EV"
exec > >(tee -a "$EV/run.log") 2>&1
say() { echo "[$(date +%T)] $*"; }

[ -z "${MXFS_LAB:-}" ] && [ -f "$HOME/.config/mxfslab/lab.$PLAT" ] && export MXFS_LAB="$HOME/.config/mxfslab/lab.$PLAT"
. "$SRCDIR/tools/mxfs_lab.sh"
. "$SRCDIR/tests/lib/runlock.sh"
NODES=$(lab_nodes "$PLAT") || { say "RESULT ABORT: no set for $PLAT"; exit 2; }
set -- $NODES
A=$1; B=$2
LUN=$(lab_need storage lun) || { say "RESULT ABORT: no storage line"; exit 2; }
vmhold_take "userfreeze_peer_demand $PLAT" "$A" "$B" || exit 2
"$SRCDIR/tools/vm_pool.sh" up "$A" "$B" || exit 2
( setsid "$SRCDIR/tools/vm_pool.sh" release --after $$ "$A" "$B" </dev/null >/dev/null 2>&1 & )
HA=$(lab_addr "$A"); HB=$(lab_addr "$B")
MNT=/mnt/mxfs
say "platform=$PLAT A=$A ($HA) B=$B ($HB) module=${MODULE:-package} evidence=$EV"

on() {
    local h=$1 t=$2; shift 2
    timeout "$t" "$SSH" "$h" "$@" 2>&1 | grep --line-buffered -v -E "^Warning: Permanently|^$|Unauthorized access|authorized user, disconnect|System is booting up\. Unprivileged users"
    return "${PIPESTATUS[0]}"
}

# TRANSPORT=tcp (default) or caw; a command-line option wins over modprobe.d
case "${TRANSPORT:-tcp}" in tcp) FT=1 ;; caw) FT=0 ;; *) echo "TRANSPORT must be tcp or caw" >&2; exit 2 ;; esac
LOAD="modprobe mxfs force_transport=$FT"
UNLOAD="{ modprobe -r mxfs 2>/dev/null || rmmod mxfs 2>/dev/null; };"
if [ "$MODULE" = tree ]; then
    . "$SRCDIR/packaging/common.sh"; set +e
    STAGE=$(mktemp -d)
    trap 'rm -rf -- "$STAGE"' EXIT
    mxfs_stage_kmod_source "$STAGE/src" >/dev/null
    tar -C "$STAGE" -czf "$STAGE/k.tgz" src
    bpids=()
    for h in "$HA" "$HB"; do
        timeout 60 "$SSH" "$h" SCP "$STAGE/k.tgz" /root/mxfs-ufpd.tgz >/dev/null 2>&1 || { say "RESULT ABORT: copy to $h"; exit 2; }
        # the build budget is INSTALL_S of tests/packaged_round.sh
        on "$h" 660 "rm -rf /root/mxfs-ufpd && mkdir /root/mxfs-ufpd && tar -C /root/mxfs-ufpd -xzf /root/mxfs-ufpd.tgz && make -s -j\$(nproc) -C /lib/modules/\$(uname -r)/build M=/root/mxfs-ufpd/src modules >/root/mxfs-ufpd/build.log 2>&1; echo build_rc=\$?" &
        bpids+=($!)
    done
    # by pid: a bare wait also waits for the tee behind `exec > >(tee ...)`
    wait "${bpids[@]}"
    LOAD="for m in \$(modinfo -F depends /root/mxfs-ufpd/src/mxfs.ko | tr , ' '); do modprobe \$m; done; insmod /root/mxfs-ufpd/src/mxfs.ko force_transport=$FT target_cache_protected=1"
fi
# what holds a mount that refuses to unmount
HOLDERS="echo UMOUNT_REFUSED; fuser -vm $MNT 2>&1; for p in /proc/[0-9]*; do l=\$(readlink \$p/cwd 2>/dev/null); case \$l in $MNT*) echo cwd_in_mount pid=\${p#/proc/} comm=\$(cat \$p/comm);; esac; done; grep ' $MNT ' /proc/mounts"
loads=""
for h in "$HA" "$HB"; do
    out=$(on "$h" 70 "grep -q ' $MNT ' /proc/mounts && { fsfreeze -u $MNT 2>/dev/null; fuser -km $MNT >/dev/null 2>&1; sleep 1; timeout 60 umount $MNT || { $HOLDERS; }; }; grep -q ' $MNT ' /proc/mounts && echo STALE_MOUNT; $UNLOAD $LOAD; mkdir -p $MNT; echo \$(uname -r) srcversion=\$(cat /sys/module/mxfs/srcversion) force_transport=\$(cat /sys/module/mxfs/parameters/force_transport)")
    echo "$out"
    loads+="$(echo "$out" | grep -o 'srcversion=[^ ]* force_transport=[^ ]*') "
    echo "$out" | grep -q STALE_MOUNT && { say "RESULT ABORT: $h still has $MNT mounted from an earlier run (holders above)"; exit 2; }
done
# both nodes on one module and one transport, or the pair measures a mix
[ "$(echo $loads | tr ' ' '\n' | sort -u | grep -c srcversion)" = 1 ] || { say "RESULT ABORT: the two nodes run different modules: $loads"; exit 2; }
mk=$(on "$HA" 60 "mkfs.mxfs -f $LUN >/dev/null 2>&1; echo mkfs_rc=\$?"); echo "$mk"
[ "$mk" = mkfs_rc=0 ] || { say "RESULT ABORT: mkfs failed on A"; exit 2; }
for h in "$HA" "$HB"; do
    on "$h" 60 "timeout 60 mount -t mxfs $LUN $MNT; rc=\$?; echo mount_rc=\$rc; [ \$rc = 0 ]" || {
        say "RESULT ABORT: $h did not mount $LUN"; exit 2; }
done
on "$HA" 20 "mkdir $MNT/d && touch $MNT/d/a1 $MNT/d/a2 && sync && echo a_files_rc=\$?; dmesg -C; fsfreeze -f $MNT; echo freeze_rc=\$?"
on "$HB" 40 "t0=\$(date +%s.%N); timeout 30 touch $MNT/d/b1; r1=\$?; timeout 30 ls $MNT/d >/dev/null; r2=\$?; t1=\$(date +%s.%N); echo b_touch_rc=\$r1 b_ls_rc=\$r2 b_secs=\$(awk -v a=\$t0 -v b=\$t1 'BEGIN{printf \"%.2f\", b-a}')" | tee "$EV/b.txt"
on "$HA" 20 "fsfreeze -u $MNT; echo thaw_rc=\$?"
sleep 2
on "$HA" 20 "dmesg" > "$EV/dmesg_A_full.txt"
on "$HB" 20 "dmesg" > "$EV/dmesg_B_full.txt"
for h in "$HB" "$HA"; do on "$h" 70 "timeout 60 umount $MNT; rc=\$?; [ \$rc = 0 ] || { $HOLDERS; }; echo umount_rc=\$rc"; done | tee "$EV/umount.txt"
badk=$(grep -c -E "WARNING|BUG:|Oops" "$EV/dmesg_A_full.txt")
relmark=$(grep -c "P-RELMARK-ON-FROZEN" "$EV/dmesg_A_full.txt")
brc=$(sed -n 's/.*b_touch_rc=\([0-9]*\) b_ls_rc=\([0-9]*\).*/\1\2/p' "$EV/b.txt")
say "RESULT a_kernel_warn_bug_lines=$badk a_relmark_lines=$relmark $(cat "$EV/b.txt")"
[ "$badk" = 0 ] && [ "$brc" = 00 ] && [ "$relmark" -ge 1 ]
