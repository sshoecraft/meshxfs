#!/bin/bash
# guest_thread_sampler.sh — runs ON a test node.  Every INTERVAL seconds it
# appends one snapshot of every mxfs kernel thread (state + kernel stack, one
# line each), every task in uninterruptible sleep anywhere, and the shared
# device's in-flight request counts to OUT.
#
# Why: a stall that prints nothing leaves nothing in the kernel log.  The
# vSphere board of 2026-10-13 00:07 lost vstest1's disk heartbeat AND its UDP
# lease renewals for sixteen minutes with no P278-HB-STALL line, because the
# watchdog only reports a heartbeat stuck outside its SLEEP stage; the only
# stacks the harness captured were the two it happened to name.  This keeps
# the blocked stacks of every mxfs thread across the whole window, stamped
# with the node's own monotonic clock (uptime) so they line up with dmesg.
#
# Reads only /proc/<pid>/{comm,stat,stack} — never cmdline or maps, which take
# the target's mmap_lock and can hang on a wedged task.
#
# Usage (from clyde):
#   tools/mxfs_sshpass.sh <node> 'nohup bash /src/mxfs/tests/guest_thread_sampler.sh 900 2 /var/tmp/mxfs_threads.log >/dev/null 2>&1 &'
# Stop early: touch /var/tmp/mxfs_threads.stop on the node.
DUR="${1:-900}"
INTERVAL="${2:-2}"
OUT="${3:-/var/tmp/mxfs_threads.log}"
DEV="${4:-sdb}"
STOP="${OUT%.log}.stop"
rm -f "$STOP"
end=$(( $(date +%s) + DUR ))
while [ "$(date +%s)" -lt "$end" ] && [ ! -e "$STOP" ]; do
    {
        read -r up _ < /proc/uptime
        echo "=== $(date -u +%H:%M:%S) up=$up inflight=$(tr -s ' ' < /sys/block/$DEV/inflight 2>/dev/null)"
        for p in /proc/[0-9]*; do
            read -r comm < "$p/comm" 2>/dev/null || continue
            stat=$(cat "$p/stat" 2>/dev/null) || continue
            # field 3 follows the ')' that closes comm, which may hold spaces
            st=${stat##*) }; st=${st%% *}
            case "$comm" in
                mxfs*|*mxfs*) ;;
                *) [ "$st" = D ] || continue ;;
            esac
            stk=$(sed 's/^\[<[0-9a-f]*>\] //; s/+0x[0-9a-f]*\/0x[0-9a-f]*//' "$p/stack" 2>/dev/null \
                  | grep -v -E '^(ret_from_fork|ret_from_fork_asm|kthread)' | tr '\n' '<')
            echo "${p#/proc/} $st $comm ${stk%<}"
        done
    } >> "$OUT"
    sleep "$INTERVAL"
done
echo "=== end $(date -u +%H:%M:%S)" >> "$OUT"
