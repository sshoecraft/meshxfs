#!/bin/bash
#
# host_pressure_log.sh — clyde's memory, CPU and I/O pressure once a second,
# to set beside a test node's log when that node stalls.
#
# A KVM guest the host does not schedule for half a second drops a DRBD link
# (PingAck) exactly as a stall inside the guest does, and the host's own log
# says nothing about it.  /proc/pressure is the host's record of how long its
# tasks waited; one line a second, stamped in UTC with milliseconds, lines up
# with a guest's dmesg time.
#
# Usage: tools/host_pressure_log.sh start <file>
#        tools/host_pressure_log.sh stop <file>
# A line: <UTC> mem_some10 mem_full10 cpu_some10 io_some10 io_full10 swap_used_kB
# (the avg10 fields: the share of the last 10 s that tasks spent stalled)
set -u
cmd=${1:-}; f=${2:-}
[ -n "$cmd" ] && [ -n "$f" ] || { echo "usage: $0 start|stop <file>"; exit 2; }
case "$cmd" in
start)
    [ -e "$f.pid" ] && kill -0 "$(cat "$f.pid")" 2>/dev/null && { echo "already logging to $f"; exit 1; }
    (
        trap 'exit 0' TERM
        while :; do
            ms=$(awk '$1 == "some" {split($2, a, "="); s = a[2]} $1 == "full" {split($2, b, "="); g = b[2]} END {print s, g}' /proc/pressure/memory)
            cs=$(awk '$1 == "some" {split($2, a, "="); print a[2]}' /proc/pressure/cpu)
            io=$(awk '$1 == "some" {split($2, a, "="); s = a[2]} $1 == "full" {split($2, b, "="); g = b[2]} END {print s, g}' /proc/pressure/io)
            sw=$(awk '$1 == "SwapTotal:" {t = $2} $1 == "SwapFree:" {f = $2} END {print t - f}' /proc/meminfo)
            echo "$(date -u +%FT%T.%3NZ) $ms $cs $io $sw"
            sleep 1
        done
    ) >> "$f" 2>&1 &
    echo $! > "$f.pid"
    echo "logging to $f (pid $!)"
    ;;
stop)
    [ -e "$f.pid" ] || { echo "no logger for $f"; exit 1; }
    kill "$(cat "$f.pid")" 2>/dev/null
    rm -f "$f.pid"
    echo "stopped; $(wc -l < "$f") lines in $f"
    ;;
*) echo "usage: $0 start|stop <file>"; exit 2 ;;
esac
