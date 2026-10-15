#!/bin/bash
#
# guest_timer_probe.sh — is one CPU of this guest no longer being run?
#
# Usage (on the guest, as root):   bash guest_timer_probe.sh [gap_s]
# Usage (no guest network):        tools/vsphere_guest_run.sh <vm> "$(cat tests/guest_timer_probe.sh)"
#
# A guest whose hypervisor stops running (or stops waking) one vCPU keeps going
# on the others: clocksource time advances, userspace runs, other CPUs' timers
# fire.  What stops is everything bound to that CPU — the timers queued on its
# timer base, so every schedule_timeout()/msleep() sleeper whose timer landed
# there never wakes, and the interrupts routed to it, so a NIC queue whose MSI-X
# vector targets it stops receiving.  From outside that looks like a node that
# went silent while "alive".
#
# This takes two snapshots gap_s apart (default 5) and prints, per CPU, how far
# each moved: local timer interrupts, the tick-sched counters in
# /proc/timer_list, and each NIC queue's interrupt count.  A CPU whose counters
# do not move across the gap is not running.  Then every mxfs kernel thread and
# every D-state task: the CPU it last ran on, its state, and its kernel stack,
# so a sleeper stranded on that CPU is named.
#
# Read-only: it writes nothing and changes no setting.

gap=${1:-5}

snap() {
    awk '/^LOC:/{for(i=2;i<=NF-3;i++) printf "LOC cpu%d %s\n", i-2, $i}' /proc/interrupts
    awk '/-edge|-fasteoi/ && /eth|virtio|vmxnet/ {n=$NF; for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) printf "IRQ %s cpu%d %s\n", n, i-2, $i; else break}' /proc/interrupts
    awk '/^cpu: /{c=$2} c!="" && /^  \.(idle_calls|idle_sleeps|last_tick|tick_stopped|idle_jiffies|last_jiffies|next_timer|idle_expires)/{gsub(/[:,]/,""); printf "TS cpu%s %s %s\n", c, $1, $2} /^jiffies: /{print "JIFFIES", $2}' /proc/timer_list
}

a=$(snap)
up0=$(cut -d' ' -f1 /proc/uptime)
sleep "$gap"
b=$(snap)
up1=$(cut -d' ' -f1 /proc/uptime)

echo "=== $(hostname -s) kernel $(uname -r) uptime $up0 -> $up1 (gap ${gap}s), $(nproc) cpus"
echo "--- counter deltas over the gap (0 on a CPU that should be ticking = that CPU is not running)"
join <(printf '%s\n' "$a" | awk '{k=$1; for(i=2;i<NF;i++) k=k"|"$i; print k, $NF}' | sort) \
     <(printf '%s\n' "$b" | awk '{k=$1; for(i=2;i<NF;i++) k=k"|"$i; print k, $NF}' | sort) |
    awk '{d=$3-$2; printf "%-48s %16s -> %-16s delta %s\n", $1, $2, $3, d}' |
    grep -v -E '^TS\|cpu[0-9]+\|\.(tick_stopped|idle_jiffies|last_jiffies|next_timer|idle_expires)'
echo "--- tick-sched state now"
printf '%s\n' "$b" | grep -E '^TS .*\.(tick_stopped|last_jiffies|next_timer|idle_expires|last_tick)|^JIFFIES' | sort -u
echo "--- NIC queue affinity"
for d in /proc/irq/*/; do
    n=$(ls "$d" 2>/dev/null | grep -E 'eth|vmxnet|virtio' | head -1)
    [ -n "$n" ] && echo "irq $(basename "$d") $n effective=$(cat "$d"/effective_affinity_list 2>/dev/null) allowed=$(cat "$d"/smp_affinity_list 2>/dev/null)"
done
echo "--- mxfs kernel threads and D-state tasks: pid comm state last_cpu wchan"
for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ -r "$p/stat" ] || continue
    st=$(cat "$p/stat" 2>/dev/null) || continue
    comm=$(cat "$p/comm" 2>/dev/null)
    rest=${st##*) }
    state=$(echo "$rest" | awk '{print $1}')
    cpu=$(echo "$rest" | awk '{print $37}')
    case "$comm" in mxfs*|*mxfs*) ;; *) [ "$state" = D ] || continue ;; esac
    echo "TASK $pid $comm $state cpu$cpu $(cat "$p/wchan" 2>/dev/null)"
    sed 's/^/    /' "$p/stack" 2>/dev/null | head -12
done
