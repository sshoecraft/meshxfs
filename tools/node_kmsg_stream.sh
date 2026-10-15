#!/bin/bash
#
# node_kmsg_stream.sh — keep a test node's kernel log on clyde while it runs
#
# The rig's guests keep their journal in memory and their ring wraps within
# minutes under the module's debug sites, and a node the fence powers off
# takes both with it: what that node saw just before it died is then nowhere.
# This holds an ssh `cat /dev/kmsg` open to the node and appends every record,
# less the per-I/O iomap debug line, to a file on clyde as it arrives, so the
# record survives the node.
#
# Usage: tools/node_kmsg_stream.sh start <node> <file>
#        tools/node_kmsg_stream.sh keep <node> <file>   (restart on each new boot)
#        tools/node_kmsg_stream.sh stop <file>
#        tools/node_kmsg_stream.sh status <file>
#
# The stream reads the node's ring from its oldest record, then follows it.
# One stream per file; its process group is recorded in <file>.pgid and stop
# signals that group.  A stream whose node died stays open until stop.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SSH="$HERE/tools/mxfs_sshpass.sh"
op=${1:-}
case "$op" in
    start)
        node=${2:?usage: start <node> <file>}; file=${3:?usage: start <node> <file>}
        if [ -s "$file.pgid" ] && kill -0 -- "-$(cat "$file.pgid")" 2>/dev/null; then
            echo "STREAM_RUNNING pgid=$(cat "$file.pgid") file=$file"; exit 0
        fi
        echo "# kmsg stream from $node, started $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$file"
        nohup setsid bash -c 'echo $$ > "$1.pgid"; exec "$2" "$3" "cat /dev/kmsg" 2>/dev/null | grep -av --line-buffered "mxfs: iomap addr=" >> "$1"' \
            stream "$file" "$SSH" "$node" > /dev/null 2>&1 < /dev/null &
        for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$file.pgid" ] && break; sleep 0.2; done
        echo "STREAM_STARTED node=$node pgid=$(cat "$file.pgid" 2>/dev/null) file=$file"
        ;;
    keep)
        # A node the test kills leaves its stream hanging on a dead TCP
        # connection, and the node's next boot is not streamed.  The keeper
        # asks the node its boot id every 10 s and starts a fresh stream (the
        # new boot's ring from its start) whenever the id changes.
        node=${2:?usage: keep <node> <file>}; file=${3:?usage: keep <node> <file>}
        nohup setsid bash -c '
            echo $$ > "$2.keep"; boot=""
            while [ -e "$2.keep" ]; do
                b=$(timeout 10 "$3" "$1" "cat /proc/sys/kernel/random/boot_id" 2>/dev/null | grep -aoE "^[0-9a-f-]{36}$")
                if [ -n "$b" ] && [ "$b" != "$boot" ]; then
                    "$4" stopstream "$2" > /dev/null
                    echo "# boot $b" >> "$2"
                    "$4" start "$1" "$2" > /dev/null
                    boot=$b
                fi
                sleep 10
            done' keeper "$node" "$file" "$SSH" "$0" > /dev/null 2>&1 < /dev/null &
        echo "KEEPER_STARTED node=$node file=$file"
        ;;
    stop|stopstream)
        # stopstream ends only the stream: the keeper uses it to replace a
        # stream on a new boot, and `stop` would end the keeper itself
        file=${2:?usage: stop <file>}
        if [ "$op" = stop ] && [ -s "$file.keep" ]; then
            k=$(cat "$file.keep"); rm -f "$file.keep"; kill -- "-$k" 2>/dev/null
        fi
        [ -s "$file.pgid" ] || { echo "STREAM_NONE file=$file"; exit 0; }
        kill -- "-$(cat "$file.pgid")" 2>/dev/null
        echo "STREAM_STOPPED pgid=$(cat "$file.pgid") lines=$(wc -l < "$file") file=$file"
        rm -f "$file.pgid"
        ;;
    status)
        file=${2:?usage: status <file>}
        if [ -s "$file.pgid" ] && kill -0 -- "-$(cat "$file.pgid")" 2>/dev/null; then
            echo "STREAM_RUNNING pgid=$(cat "$file.pgid") lines=$(wc -l < "$file") file=$file"
        else
            echo "STREAM_ENDED lines=$(wc -l < "$file" 2>/dev/null || echo 0) file=$file"
        fi
        ;;
    *) sed -n '3,20p' "$0" >&2; exit 2 ;;
esac
