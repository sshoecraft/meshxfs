#!/bin/bash
#
# join_freeze_userspace_thaw.sh — can a userspace thaw (fsfreeze -u, FITHAW)
# end the single-to-multi join's kernel freeze?
#
# The join freezes the incumbent's mount (mxfs_dlm_join_prepare,
# xfs/xfs_mxfs_join.c) so nothing can modify it between the cached-view drop
# and the two-node view's install; mxfs_dlm_join_commit thaws.  From 6.6 the
# freeze is taken as FREEZE_HOLDER_KERNEL and a userspace thaw cannot end it.
# Before 6.6 (Debian 12's 6.1) there are no holders: the kernel's and the
# user's freeze are one state, so a FITHAW inside the window would let writers
# in while the join still depends on the freeze (D-JOIN-FREEZE-THAWED-BY-
# USERSPACE-FITHAW-ON-6-1).
#
# On the platform's two nodes A and B (lab file; the installed package's
# module must be loaded):
#   1. format the platform's LUN on A and mount it there alone;
#   2. set dbg_join_flip_delay_ms=HOLD_MS on A, start a writer on A that
#      appends one timestamped line every 100 ms;
#   3. mount on B: A's join freezes and holds the window HOLD_MS;
#   4. ARM=thaw: ~5 s into the window run `fsfreeze -u` on A's mount and record
#      its rc; ARM=control: do nothing;
#   5. count the writer lines whose time falls inside A's window (from its
#      P-JOIN-FLIP-DELAY line to its P-JOIN-THAW / P-JOIN-THAW-FAIL line).
# A frozen window lets no line through.  The verdict line states the counts;
# lines inside the window are the defect.
#
# Budgets: mkfs 60 s, each mount 60 s (an idle 2-node mount ~7-10 s measured
# in the packaged round), the window HOLD_MS (20 s) plus the join on either
# side of it (a few seconds) -> 90 s for the join step.
#
# Usage: tests/join_freeze_userspace_thaw.sh <platform> thaw|control [tree|noreload]
#   MXFS_LAB defaults to ~/.config/mxfslab/lab.<platform> when it exists.
#
set -u

PLAT="${1:?usage: join_freeze_userspace_thaw.sh <platform> thaw|control}"
ARM="${2:?usage: join_freeze_userspace_thaw.sh <platform> thaw|control}"
case "$ARM" in thaw|control) ;; *) echo "arm must be thaw or control" >&2; exit 2 ;; esac
MODULE="${3:-}"   # read before `set -- $NODES` below replaces the arguments
HOLD_MS=20000
SRCDIR="$(cd "$(dirname "$0")/.." && pwd)"
SSH="$SRCDIR/tools/mxfs_sshpass.sh"
EV="$SRCDIR/tests/evidence/join_freeze_userspace_thaw/${PLAT}_${ARM}_$(date +%Y%m%dT%H%M%S)"
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
vmhold_take "join_freeze_userspace_thaw $PLAT" "$A" "$B" || exit 2
"$SRCDIR/tools/vm_pool.sh" up "$A" "$B" || exit 2
( setsid "$SRCDIR/tools/vm_pool.sh" release --after $$ "$A" "$B" </dev/null >/dev/null 2>&1 & )
HA=$(lab_addr "$A"); HB=$(lab_addr "$B")
MNT=/mnt/mxfs
say "platform=$PLAT arm=$ARM A=$A ($HA) B=$B ($HB) hold_ms=$HOLD_MS evidence=$EV"

on() {
    local h=$1 t=$2; shift 2
    timeout "$t" "$SSH" "$h" "$@" 2>&1 | grep --line-buffered -v -E "^Warning: Permanently|^$|Unauthorized access|authorized user, disconnect|System is booting up\. Unprivileged users"
    return "${PIPESTATUS[0]}"
}

# MODULE=tree: build mxfs.ko from this tree on both nodes and load it (insmod
# reads no modprobe.d, so the package's two options are passed), so the same
# source runs on every kernel compared; default: the installed package's
# TRANSPORT=tcp (default) or caw: the lock transport the pair forms on.  A
# command-line option follows modprobe.d's, so it wins over the package's
# file whatever a packaged round last left there.
case "${TRANSPORT:-tcp}" in tcp) FT=1 ;; caw) FT=0 ;; *) echo "TRANSPORT must be tcp or caw" >&2; exit 2 ;; esac
LOAD="modprobe mxfs force_transport=$FT"
# the module is reloaded before each run unless MODULE=noreload, which keeps
# the one already loaded with whatever earlier mounts left in it
# (rmmod for a tree module an earlier run loaded with insmod: modprobe -r
# cannot find a module that is not installed under /lib/modules)
UNLOAD="{ modprobe -r mxfs 2>/dev/null || rmmod mxfs 2>/dev/null; };"
[ "$MODULE" = noreload ] && UNLOAD=""
if [ "$MODULE" = tree ]; then
    . "$SRCDIR/packaging/common.sh"; set +e
    STAGE=$(mktemp -d)
    trap 'rm -rf -- "$STAGE"' EXIT
    mxfs_stage_kmod_source "$STAGE/src" >/dev/null
    tar -C "$STAGE" -czf "$STAGE/k.tgz" src
    bpids=()
    for h in "$HA" "$HB"; do
        timeout 60 "$SSH" "$h" SCP "$STAGE/k.tgz" /root/mxfs-jfut.tgz >/dev/null 2>&1 || { say "RESULT ABORT: copy to $h"; exit 2; }
        # the build budget is INSTALL_S of tests/packaged_round.sh
        on "$h" 660 "rm -rf /root/mxfs-jfut && mkdir /root/mxfs-jfut && tar -C /root/mxfs-jfut -xzf /root/mxfs-jfut.tgz && make -s -j\$(nproc) -C /lib/modules/\$(uname -r)/build M=/root/mxfs-jfut/src modules >/root/mxfs-jfut/build.log 2>&1; echo build_rc=\$?" &
        bpids+=($!)
    done
    # the builds by pid: a bare wait also waits for the tee behind `exec >
    # >(tee ...)`, which ends only with this script, and hung it for an hour
    wait "${bpids[@]}"
    LOAD="for m in \$(modinfo -F depends /root/mxfs-jfut/src/mxfs.ko | tr , ' '); do modprobe \$m; done; insmod /root/mxfs-jfut/src/mxfs.ko force_transport=$FT target_cache_protected=1"
fi
# what holds a mount that refuses to unmount: user processes (fuser), any
# process whose cwd or root is in it, and the mount's own line
HOLDERS="echo UMOUNT_REFUSED; fuser -vm $MNT 2>&1; for p in /proc/[0-9]*; do l=\$(readlink \$p/cwd 2>/dev/null); case \$l in $MNT*) echo cwd_in_mount pid=\${p#/proc/} comm=\$(cat \$p/comm);; esac; done; grep ' $MNT ' /proc/mounts; wp=\$(cat /root/jfut_writer.pid 2>/dev/null); [ -n \"\$wp\" ] && echo writer_pgid=\$wp alive=\$(ls -d /proc/\$wp 2>/dev/null | wc -l) group_members=\$(awk -v g=\$wp '\$5==g' /proc/[0-9]*/stat 2>/dev/null | wc -l); for st in /proc/[0-9]*/stat; do awk -v g=\$wp '\$5==g {print \"member\", \$1, \$2, \"state=\" \$3}' \$st 2>/dev/null; done; for st in /proc/[0-9]*/stat; do m=\$(awk -v g=\$wp '\$5==g {print \$1}' \$st 2>/dev/null); [ -n \"\$m\" ] && { echo stack_of=\$m wchan=\$(cat /proc/\$m/wchan); cat /proc/\$m/stack; }; done; for t in \$(seq 1 30); do sleep 1; umount $MNT 2>/dev/null && { echo umount_ok_after_retry_s=\$t; break; }; done"
loads=""
for h in "$HA" "$HB"; do
    out=$(on "$h" 70 "grep -q ' $MNT ' /proc/mounts && { fuser -km $MNT >/dev/null 2>&1; sleep 1; timeout 60 umount $MNT || { $HOLDERS; }; }; grep -q ' $MNT ' /proc/mounts && echo STALE_MOUNT; $UNLOAD $LOAD; mkdir -p $MNT; echo \$(uname -r) srcversion=\$(cat /sys/module/mxfs/srcversion) force_transport=\$(cat /sys/module/mxfs/parameters/force_transport) holders=\$(grep -c FREEZE_HOLDER /lib/modules/\$(uname -r)/build/include/linux/fs.h 2>/dev/null)")
    echo "$out"
    loads+="$(echo "$out" | grep -o 'srcversion=[^ ]* force_transport=[^ ]*') "
    echo "$out" | grep -q STALE_MOUNT && { say "RESULT ABORT: $h still has $MNT mounted from an earlier run (holders above)"; exit 2; }
done
# both nodes on one module and one transport, or the pair measures a mix
[ "$(echo $loads | tr ' ' '\n' | sort -u | grep -c srcversion)" = 1 ] || { say "RESULT ABORT: the two nodes run different modules: $loads"; exit 2; }
mk=$(on "$HA" 60 "mkfs.mxfs -f $LUN >/dev/null 2>&1; echo mkfs_rc=\$?"); echo "$mk"
[ "$mk" = mkfs_rc=0 ] || { say "RESULT ABORT: mkfs failed on A"; exit 2; }
on "$HA" 60 "timeout 60 mount -t mxfs $LUN $MNT; rc=\$?; echo mountA_rc=\$rc; [ \$rc = 0 ]" || {
    say "RESULT ABORT: A did not mount $LUN (a stale lab file names a LUN the pool no longer binds to this set)"; exit 2; }
on "$HA" 20 "echo $HOLD_MS > /sys/module/mxfs/parameters/dbg_join_flip_delay_ms; echo hold=\$(cat /sys/module/mxfs/parameters/dbg_join_flip_delay_ms); dmesg -C
    nohup setsid bash -c 'while :; do date +%s.%N >> $MNT/writer.log; sleep 0.1; done' </dev/null >/dev/null 2>&1 & echo \$! > /root/jfut_writer.pid; echo writer_started"
sleep 2
# A modifies the root directory just before B mounts, so A holds the root's
# tenure when B's mount asks for it: B's request then ends that tenure inside
# A's frozen window, and the release publishes its clean-release marker on a
# frozen filesystem (D-JOIN-FREEZE-RELMARK-TRANS-ALLOC-WHILE-FROZEN).  The
# P-RELMARK-ON-FROZEN count in the verdict says whether that was reached.
on "$HA" 10 "touch $MNT/prejoin.1 $MNT/prejoin.2 && mkdir -p $MNT/prejoin.d && echo prejoin_rc=\$?"
# RECLAIM=1: halfway through the window A reclaims prejoin.1's inode
# (dbg_join_window_reclaim_ino, one shot), so that tenure ends inside the freeze
[ "${RECLAIM:-0}" = 1 ] && on "$HA" 10 "i=\$(stat -c %i $MNT/prejoin.1); echo \$i > /sys/module/mxfs/parameters/dbg_join_window_reclaim_ino; echo reclaim_ino=\$(cat /sys/module/mxfs/parameters/dbg_join_window_reclaim_ino)"
# DYNDBG=1: A's debug-level probes on for the join (tenures, BASTs, releases),
# into dmesg_A_full.txt; off again before the unmounts
[ "${DYNDBG:-0}" = 1 ] && on "$HA" 10 "echo 'module mxfs +p' > /sys/kernel/debug/dynamic_debug/control; echo dyndbg_on=\$?"
# B's mount triggers A's join; it returns once the join has completed
( on "$HB" 90 "timeout 90 mount -t mxfs $LUN $MNT; echo mountB_rc=\$?" > "$EV/mountB.txt" 2>&1 ) &
mpid=$!
if [ "$ARM" = thaw ]; then
    # wait for A to enter the window, then thaw from userspace 5 s in
    for i in $(seq 1 60); do
        on "$HA" 10 "dmesg | grep -q P-JOIN-FLIP-DELAY && echo IN" | grep -q IN && break
        sleep 0.5
    done
    sleep 5
    on "$HA" 15 "date +%s.%N > /root/jfut_thaw_at; timeout 10 fsfreeze -u $MNT; echo fsfreeze_u_rc=\$?"
fi
wait "$mpid"
cat "$EV/mountB.txt"
# On CAW B's mount returns while A is still inside its window (A releases the
# tenures B asks for and stays frozen until its own view flip), so wait for
# the window to end in A's clock, then for A's writer to append again: a
# measurement taken earlier counts a partial window, and a writer killed while
# frozen cannot exit until the thaw, which held A's unmount busy.
# Budget: the hold, plus 5 s for the flip and the thaw (21.2 s measured for
# the whole join on TCP, attempts=1), plus 1 s for the writer's next append.
on "$HA" $(( HOLD_MS / 1000 + 20 )) "
    t_in=\$(dmesg | grep P-JOIN-FLIP-DELAY | head -1 | sed 's/^\[ *\([0-9.]*\)\].*/\1/')
    [ -n \"\$t_in\" ] || { echo window_missing; exit 0; }
    off=\$(awk -v n=\$(date +%s.%N) -v u=\$(cut -d' ' -f1 /proc/uptime) 'BEGIN{printf \"%.6f\", n-u}')
    w_out=\$(awk -v o=\$off -v t=\$t_in -v h=$HOLD_MS 'BEGIN{printf \"%.3f\", o + t + h / 1000}')
    deadline=\$(awk -v w=\$w_out 'BEGIN{printf \"%d\", w + 6}')
    while [ \$(date +%s) -le \$deadline ]; do
        last=\$(tail -1 $MNT/writer.log)
        awk -v l=\$last -v w=\$w_out 'BEGIN{exit !(l > w)}' && { echo writer_resumed_after_window_s=\$(awk -v l=\$last -v w=\$w_out 'BEGIN{printf \"%.2f\", l-w}'); exit 0; }
        sleep 0.5
    done
    echo writer_not_resumed last=\$(tail -1 $MNT/writer.log) window_out=\$w_out
" | tee "$EV/resume.txt"
# every gap over 1 s in the writer's own clock, before it is stopped: the
# freeze window is one; any other is a stall on the incumbent
on "$HA" 20 "awk 'NR>1 && \$1-p > 1 {printf \"writer_gap from=%.3f to=%.3f gap_s=%.2f\\n\", p, \$1, \$1-p} {p=\$1}' $MNT/writer.log; echo writer_last=\$(tail -1 $MNT/writer.log) now=\$(date +%s.%N)" | tee "$EV/writer_gaps.txt"
on "$HA" 20 "kill -- -\$(cat /root/jfut_writer.pid) 2>/dev/null; sleep 0.5; echo writer_stopped"
on "$HA" 20 "dmesg | grep -E 'P-JOIN-(FREEZE|FLIP-DELAY|THAW)|P-RELMARK-ON-FROZEN|WARNING|BUG:|Oops'" > "$EV/dmesg_A.txt"
on "$HA" 20 "dmesg" > "$EV/dmesg_A_full.txt"
[ "${DYNDBG:-0}" = 1 ] && on "$HA" 10 "echo 'module mxfs -p' > /sys/kernel/debug/dynamic_debug/control; echo dyndbg_off=\$?"
cat "$EV/dmesg_A.txt"
# the window in the writer's clock: A's kernel stamps converted with A's boot time
on "$HA" 30 "
    boot=\$(awk '/^btime/ {print \$2}' /proc/stat)
    up_now=\$(cut -d' ' -f1 /proc/uptime); now=\$(date +%s.%N)
    t_in=\$(dmesg | grep P-JOIN-FLIP-DELAY | head -1 | sed 's/^\[ *\([0-9.]*\)\].*/\1/')
    [ -n \"\$t_in\" ] || { echo window_missing; exit 0; }
    off=\$(awk -v n=\$now -v u=\$up_now 'BEGIN{printf \"%.6f\", n-u}')
    w_in=\$(awk -v o=\$off -v t=\$t_in 'BEGIN{printf \"%.3f\", o+t}')
    # the hold is fixed; the thaw's own line is debug-level and absent on an
    # installed package, so the window's end is its start plus the hold
    w_out=\$(awk -v a=\$w_in -v h=$HOLD_MS 'BEGIN{printf \"%.3f\", a + h / 1000}')
    total=\$(wc -l < $MNT/writer.log)
    inside=\$(awk -v a=\$w_in -v b=\$w_out '\$1 > a + 0.3 && \$1 < b' $MNT/writer.log | wc -l)
    echo window_in=\$w_in window_out=\$w_out window_s=\$(awk -v a=\$w_in -v b=\$w_out 'BEGIN{printf \"%.1f\", b-a}') writer_lines_total=\$total writer_lines_inside_window=\$inside
    [ -f /root/jfut_thaw_at ] && echo thaw_at=\$(cat /root/jfut_thaw_at)
" | tee "$EV/window.txt"
for h in "$HB" "$HA"; do on "$h" 70 "timeout 60 umount $MNT; rc=\$?; [ \$rc = 0 ] || { $HOLDERS; }; echo umount_rc=\$rc"; done | tee "$EV/umount.txt"
on "$HA" 10 "echo 0 > /sys/module/mxfs/parameters/dbg_join_flip_delay_ms; rm -f /root/jfut_writer.pid /root/jfut_thaw_at"
inside=$(sed -n 's/.*writer_lines_inside_window=\([0-9]*\).*/\1/p' "$EV/window.txt")
thawfail=$(grep -c "P-JOIN-THAW-FAIL" "$EV/dmesg_A.txt")
badk=$(grep -c -E "WARNING|BUG:|Oops" "$EV/dmesg_A.txt")
relmark=$(grep -c "P-RELMARK-ON-FROZEN" "$EV/dmesg_A.txt")
if [ -z "$inside" ]; then
    say "RESULT ABORT: the window could not be measured (see window.txt)"; exit 2
fi
resumed=$(grep -c writer_resumed_after_window_s "$EV/resume.txt")
umount_ok=$(grep -c '^umount_rc=0' "$EV/umount.txt")
say "RESULT arm=$ARM writer_lines_inside_window=$inside join_thaw_fail_lines=$thawfail kernel_warn_bug_lines=$badk relmark_on_frozen_lines=$relmark writer_resumed=$resumed umounts_ok=$umount_ok/2"
[ "$inside" = 0 ] && [ "$thawfail" = 0 ] && [ "$badk" = 0 ] && [ "$resumed" = 1 ] && [ "$umount_ok" = 2 ]
