#!/bin/bash
# tcp_rsync_offcpu.sh — where a both-mounted small-file rsync's creates wait on
# the 2-node TCP rig, as off-CPU time by kernel stack.
#
# For D-TCP-LEDGER-SMALLFILE-WORKLOAD-PACE-RULE0-0349.  tests/tcp_rsync_stacks.sh
# times the create path by function per task (rcs3: on the copier xfs_create
# took at least 19.6 s of a 22.8 s rsync, the inode-number reserve at least
# 9.1 s of it, 6.8 s of that in 286 calls of 8 ms or more), but a duration says
# nothing about what the call waited for.  This runs bpftrace on node A for one
# tests/lone_rsync_bench.sh both-mounted pass and sums, for every rsync task
# inside xfs_create, the time it spent switched out, keyed by the kernel stack
# it switched out on (run-queue time after the wake-up included).  Each
# inode-number reserve the create path makes is timed as well, and its number's
# offset in its 64-inode record is histogrammed for all reserves and for those
# of 8 ms or more, so a slow tail at the start of a record shows as such.
#
# The bench copies with plain `rsync -a`, which per file also looks the name
# up, writes a temporary, sets its attributes and renames it into place, so
# the copy's waits are not all inside xfs_create.  @all_us therefore sums every
# rsync task's off-CPU time by the stack it left the CPU on, wherever it was
# (the sender's reads and the pipe waits between rsync's processes included,
# told apart by their stacks), and @fn_us/@fn_n time the receiver's other
# per-file VFS operations, so the create's share of the copy is measured
# rather than assumed.
#
# Usage: tests/tcp_rsync_offcpu.sh <label> [A=test1] [B=test2]
#   The group must already be prepared (2/net/mesh/direct) and both nodes
#   mounted; the bench unmounts only A, and A's peer stays mounted.
# Output: tests/evidence/tcp_rsync_offcpu/<stamp>-<label>/: offcpu.txt (the
# bpftrace maps as printed at exit, the stack maps cut to their 40 largest
# entries), bench.txt, attach.txt.  It grades nothing.
#
# derived bound: bpftrace attach wait 30 s + the bench's own caller bound
# 120 s (tests/lone_rsync_bench.sh header) + stop and read-back 30 s = 180 s.
set -u
LABEL=${1:?label}; A=${2:-test1}; B=${3:-test2}
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); cd "$REPO" || exit 2
SSH=tools/mxfs_sshpass.sh
EVID=tests/evidence/tcp_rsync_offcpu/$(date -u +%Y%m%dT%H%M%SZ)-$LABEL
mkdir -p "$EVID"
# @c marks an rsync task inside xfs_create; @r/@rino time the create path's
# reserve; the first two sched_switch probes open and close an off-CPU
# interval for a marked task, keyed by the stack it left the CPU on; the last
# two do the same for every rsync task; @fn_us/@fn_n time the other VFS
# operations rsync makes per file, one probe pair per function with the
# function named literally: a single pair over the six functions keyed by
# `func` attached (21 probes) and never printed @fn_us in either pass of
# ra32off (2026-10-19), so the copy's non-create half went unmeasured
read -r -d '' BT <<'EOF'
kprobe:xfs_create /comm == "rsync"/ { @c[tid] = 1; @creates = count(); @cr0[tid] = nsecs; }
kretprobe:xfs_create /@c[tid]/ {
	delete(@c[tid]);
	$d = (nsecs - @cr0[tid]) / 1000;
	@create_us = sum($d);
	if ($d >= 8000) { @create_slow_n = count(); @create_slow_us = sum($d); }
	delete(@cr0[tid]);
}
kprobe:xfs_vn_rename /comm == "rsync"/ { @frn[tid] = nsecs; }
kretprobe:xfs_vn_rename /@frn[tid]/ {
	$d = (nsecs - @frn[tid]) / 1000;
	@fn_us["rename"] = sum($d); @fn_n["rename"] = count();
	if ($d >= 8000) { @fn_slow_n["rename"] = count(); @fn_slow_us["rename"] = sum($d); }
	delete(@frn[tid]);
}
kprobe:xfs_vn_setattr /comm == "rsync"/ { @fsa[tid] = nsecs; }
kretprobe:xfs_vn_setattr /@fsa[tid]/ {
	$d = (nsecs - @fsa[tid]) / 1000;
	@fn_us["setattr"] = sum($d); @fn_n["setattr"] = count();
	if ($d >= 8000) { @fn_slow_n["setattr"] = count(); @fn_slow_us["setattr"] = sum($d); }
	delete(@fsa[tid]);
}
kprobe:xfs_vn_lookup /comm == "rsync"/ { @flk[tid] = nsecs; }
kretprobe:xfs_vn_lookup /@flk[tid]/ {
	$d = (nsecs - @flk[tid]) / 1000;
	@fn_us["lookup"] = sum($d); @fn_n["lookup"] = count();
	if ($d >= 8000) { @fn_slow_n["lookup"] = count(); @fn_slow_us["lookup"] = sum($d); }
	delete(@flk[tid]);
}
kprobe:xfs_file_write_iter /comm == "rsync"/ { @fwr[tid] = nsecs; }
kretprobe:xfs_file_write_iter /@fwr[tid]/ {
	$d = (nsecs - @fwr[tid]) / 1000;
	@fn_us["write"] = sum($d); @fn_n["write"] = count();
	if ($d >= 8000) { @fn_slow_n["write"] = count(); @fn_slow_us["write"] = sum($d); }
	delete(@fwr[tid]);
}
kprobe:xfs_file_release /comm == "rsync"/ { @frl[tid] = nsecs; }
kretprobe:xfs_file_release /@frl[tid]/ {
	$d = (nsecs - @frl[tid]) / 1000;
	@fn_us["release"] = sum($d); @fn_n["release"] = count();
	if ($d >= 8000) { @fn_slow_n["release"] = count(); @fn_slow_us["release"] = sum($d); }
	delete(@frl[tid]);
}
kprobe:xfs_vn_getattr /comm == "rsync"/ { @fga[tid] = nsecs; }
kretprobe:xfs_vn_getattr /@fga[tid]/ {
	$d = (nsecs - @fga[tid]) / 1000;
	@fn_us["getattr"] = sum($d); @fn_n["getattr"] = count();
	if ($d >= 8000) { @fn_slow_n["getattr"] = count(); @fn_slow_us["getattr"] = sum($d); }
	delete(@fga[tid]);
}
kprobe:xfs_vn_mkdir /comm == "rsync"/ { @fmd[tid] = nsecs; }
kretprobe:xfs_vn_mkdir /@fmd[tid]/ {
	$d = (nsecs - @fmd[tid]) / 1000;
	@fn_us["mkdir"] = sum($d); @fn_n["mkdir"] = count();
	if ($d >= 8000) { @fn_slow_n["mkdir"] = count(); @fn_slow_us["mkdir"] = sum($d); }
	delete(@fmd[tid]);
}
kprobe:mxfs_v5_dlm_inode_reserve_try /@c[tid]/ { @r[tid] = nsecs; @rino[tid] = arg1; }
kretprobe:mxfs_v5_dlm_inode_reserve_try /@r[tid]/ {
	$d = (nsecs - @r[tid]) / 1000;
	@resv_us = hist($d);
	@resv_off_all = lhist(@rino[tid] & 63, 0, 64, 1);
	@resv_off_us[@rino[tid] & 63] = sum($d);
	if ($d >= 8000) {
		@resv_off_slow = lhist(@rino[tid] & 63, 0, 64, 1);
		@resv_slow_n = count();
		@resv_slow_us = sum($d);
	}
	delete(@r[tid]);
	delete(@rino[tid]);
}
tracepoint:sched:sched_switch /@c[args->prev_pid]/ {
	@t0[args->prev_pid] = nsecs;
	@s[args->prev_pid] = kstack(40);
}
tracepoint:sched:sched_switch /@t0[args->next_pid]/ {
	$off = (nsecs - @t0[args->next_pid]) / 1000;
	@off_us[@s[args->next_pid]] = sum($off);
	@off_total_us = sum($off);
	delete(@t0[args->next_pid]);
	delete(@s[args->next_pid]);
}
tracepoint:sched:sched_switch /args->prev_comm == "rsync"/ {
	@a0[args->prev_pid] = nsecs;
	@as[args->prev_pid] = kstack(40);
}
tracepoint:sched:sched_switch /@a0[args->next_pid]/ {
	$o = (nsecs - @a0[args->next_pid]) / 1000;
	@all_us[@as[args->next_pid]] = sum($o);
	@all_total_us = sum($o);
	delete(@a0[args->next_pid]);
	delete(@as[args->next_pid]);
}
END {
	clear(@c); clear(@cr0); clear(@r); clear(@rino); clear(@t0); clear(@s); clear(@a0); clear(@as);
	clear(@frn); clear(@fsa); clear(@flk); clear(@fwr); clear(@frl); clear(@fga); clear(@fmd);
	print(@off_us, 40); clear(@off_us);
	print(@all_us, 40); clear(@all_us);
}
EOF
# MXFS's forked functions keep XFS's names, so with xfs.ko loaded beside it
# (the native baseline's mount loads it) xfs_create and the others are not
# unique symbols, the kernel refuses a kretprobe on them ('cannot attach
# kprobe, Invalid argument', test29 2026-10-19), and bpftrace 0.20 cannot
# qualify a kretprobe by module.  An unused xfs.ko is unloaded first; one in
# use stops the run.
x=$(timeout 15 "$SSH" "$A" "if grep -q '^xfs ' /proc/modules; then rmmod xfs 2>&1 && echo xfs_unloaded || echo xfs_in_use; else echo xfs_absent; fi" < /dev/null 2>/dev/null | grep -a '^xfs_')
echo "$x" > "$EVID/xfs_module.txt"
[ "$x" = xfs_unloaded ] || [ "$x" = xfs_absent ] || { echo "RESULT: ABORT label=$LABEL -- xfs.ko on $A could not be unloaded ($x): its symbols shadow mxfs's"; exit 2; }
# start bpftrace detached on A, wait for it to attach
printf '%s\n' "$BT" | timeout 15 "$SSH" "$A" "cat > /run/mxoff.bt" 2>/dev/null
timeout 15 "$SSH" "$A" "rm -f /run/mxoff.out; nohup setsid bpftrace /run/mxoff.bt > /run/mxoff.out 2>&1 < /dev/null & echo \$! > /run/mxoff.pid" > /dev/null 2>&1
# bpftrace prints 'Attaching N probes...' once its probes are in place
att=""
for i in $(seq 1 30); do
    att=$(timeout 10 "$SSH" "$A" "kill -0 \$(cat /run/mxoff.pid) 2>/dev/null && echo alive; head -5 /run/mxoff.out" 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you\|^$')
    echo "$att" | grep -q '^Attaching' && break
    echo "$att" | grep -q '^alive' || break
    sleep 1
done
echo "$att" > "$EVID/attach.txt"
cat "$EVID/attach.txt"
echo "$att" | grep -q '^alive' && echo "$att" | grep -q '^Attaching' \
    || { echo "RESULT: ABORT label=$LABEL -- bpftrace did not attach on $A ($EVID/attach.txt)"; exit 2; }
MXFS_NODE_LIST="$A,$B" timeout 120 tests/lone_rsync_bench.sh "off_$LABEL" "$A" 1 > "$EVID/bench.txt" 2>&1
echo "bench_rc=$?" >> "$EVID/bench.txt"
timeout 30 "$SSH" "$A" "kill -INT \$(cat /run/mxoff.pid); for i in \$(seq 1 20); do kill -0 \$(cat /run/mxoff.pid) 2>/dev/null || break; sleep 1; done; cat /run/mxoff.out" 2>/dev/null \
    | grep -av '^Warning\|^Unauthorized\|^If you' > "$EVID/offcpu.txt"
grep -a '^RESULT' "$EVID/bench.txt" | cut -c1-300
grep -a '^@creates\|^@create_\|^@off_total_us\|^@all_total_us\|^@resv_slow_n\|^@resv_slow_us\|^@fn_us\|^@fn_n\|^@fn_slow' "$EVID/offcpu.txt"
echo "evidence $EVID"
