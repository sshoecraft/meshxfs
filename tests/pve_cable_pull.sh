#!/bin/bash
# pve_cable_pull.sh — a person pulls a physical pair host's network cable while
# both hosts write, and the pair must lose nothing that was acknowledged.
#
# pve1/pve2 have one network each: DRBD's replication link, corosync, the
# QDevice and ssh all go over it, so a pulled cable is every one of those
# failing at once, the way a dead switch port or NIC fails them.  Nothing here
# simulates the cut; this records what the pair does when it happens.
#
#   start   on each host a writer loops: a file of WRITE_MB from
#           /dev/urandom, fsync, then its sha256 is printed.  The ssh session
#           carrying that output is held open from clyde, and each line that
#           arrives is an ACKNOWLEDGEMENT: the host fsynced that file before
#           clyde heard about it.  A line that never arrives (the cable was
#           pulled) is not counted.  Both hosts' kernel logs are streamed to
#           clyde (tools/node_kmsg_stream.sh keep, which follows a reboot).
#   watch   once: each host's acknowledgements, the seconds since its last,
#           its DRBD role/connection and its mount (run it under `watch -n 2`)
#   stop    stops the writers (and the ssh sessions that carry them)
#   verify  once the pulled host is back and both are mounted: every
#           acknowledged file is read on BOTH hosts after dropping caches and
#           must match its sha256; both kernel logs since start are searched
#           for BUG/WARNING/Oops/hung tasks and filesystem shutdowns; the
#           writers' directories are removed
#
# Usage: tests/pve_cable_pull.sh start|watch|stop|verify
# Env:   PVE_PAIR  "<addr> <addr>" (default "192.168.1.80 192.168.1.81")
#        MNT (/mnt/shared)  WRITE_MB (4)
# Evidence: tests/evidence/pve_cable_pull/current -> the run's directory
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSH="$REPO/tools/mxfs_sshpass.sh"
read -r -a PAIR <<<"${PVE_PAIR:-192.168.1.80 192.168.1.81}"
MNT=${MNT:-/mnt/shared}
WRITE_MB=${WRITE_MB:-4}
# each writer stops after WRITE_GB, so verify has a bounded amount to re-read
# (both hosts' files, on each host); the cable has to come out before then:
# at the measured ~30 MB/s per writer, 4 GiB is about two minutes
WRITE_GB=${WRITE_GB:-4}
MAX_FILES=$(( WRITE_GB * 1024 / WRITE_MB ))
# verify reads every acknowledged byte on each host: measured ~220 MB/s from
# the pair's Samsungs, twice that time, plus the drop-caches and ssh overhead
READ_MBS=220
BASE="$REPO/tests/evidence/pve_cable_pull"
CUR="$BASE/current"
on() { timeout "${2:-30}" "$SSH" "$1" "$3" </dev/null 2>/dev/null | grep -av '^Warning'; }

case "${1:-}" in
start)
    E="$BASE/$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$E" || exit 1
    ln -sfn "$E" "$CUR"
    date -u +%s > "$E/t0"
    for h in "${PAIR[@]}"; do
        "$REPO/tools/node_kmsg_stream.sh" keep "$h" "$E/kmsg_$h.log" >/dev/null
        on "$h" 30 "mkdir -p $MNT/cablepull/\$(hostname); echo CABLE-PULL-START > /dev/kmsg" >/dev/null
        # the writer runs inside the ssh session: when the session dies (cable,
        # reset) the writer goes with it, and whatever it had fsynced but not
        # yet reported is simply not counted
        nohup setsid bash -c '
            exec "$1" "$2" "d='"$MNT"'/cablepull/\$(hostname); i=0
                while [ \$i -lt '"$MAX_FILES"' ]; do i=\$((i+1)); f=\$d/f\$i
                    head -c '"$WRITE_MB"'M /dev/urandom > \$f && sync \$f && echo \"ACK \$(date +%s.%N) \$(hostname) \$(sha256sum \$f)\"
                done; echo WRITER_DONE; sleep 86400"' writer "$SSH" "$h" > "$E/acks_$h.log" 2>&1 < /dev/null &
        echo $! > "$E/writer_$h.pid"
    done
    sleep 3
    for h in "${PAIR[@]}"; do echo "$h: $(grep -c '^ACK ' "$E/acks_$h.log") acknowledged so far"; done
    echo "evidence: $E"
    ;;
watch)
    E=$(readlink -f "$CUR"); now=$(date +%s)
    echo "$(date +%T)  since start $(( now - $(cat "$E/t0") ))s"
    for h in "${PAIR[@]}"; do
        n=$(grep -c '^ACK ' "$E/acks_$h.log"); last=$(grep '^ACK ' "$E/acks_$h.log" | tail -1 | awk '{print int($2)}')
        st=$(on "$h" 4 "echo \"\$(hostname) role=\$(drbdadm role mxfs) cs=\$(drbdadm cstate mxfs) ds=\$(drbdadm dstate mxfs) mnt=\$(findmnt -n -o FSTYPE $MNT) up=\$(cut -d. -f1 /proc/uptime)s\"")
        printf '%-14s acks=%-6s last_ack=%ss ago  %s\n' "$h" "$n" "$(( now - ${last:-now} ))" "${st:-NO ANSWER}"
    done
    ;;
stop)
    E=$(readlink -f "$CUR")
    for h in "${PAIR[@]}"; do
        [ -s "$E/writer_$h.pid" ] && kill -- "-$(cat "$E/writer_$h.pid")" 2>/dev/null
        on "$h" 20 "pkill -f 'cablepull/\$(hostname)' 2>/dev/null; true" >/dev/null
    done
    echo "writers stopped"
    ;;
verify)
    E=$(readlink -f "$CUR"); bad=0
    "$0" stop >/dev/null
    for h in "${PAIR[@]}"; do
        "$REPO/tools/node_kmsg_stream.sh" stop "$E/kmsg_$h.log" >/dev/null
    done
    # every acknowledgement, from both hosts' writers, as "<sha>  <path>"
    grep -h '^ACK ' "$E"/acks_*.log | awk '{print $4"  "$5}' > "$E/acked.sha"
    nacked=$(wc -l < "$E/acked.sha")
    vbudget=$(( 2 * nacked * WRITE_MB / READ_MBS + 60 ))
    echo "acknowledged files: $nacked ($(for h in "${PAIR[@]}"; do printf '%s=%s ' "$h" "$(grep -c '^ACK ' "$E/acks_$h.log")"; done)); read-back bound ${vbudget}s per host"
    for h in "${PAIR[@]}"; do
        timeout 30 "$SSH" "$h" SCP "$E/acked.sha" /root/cablepull.sha </dev/null >/dev/null 2>&1
        r=$(on "$h" "$vbudget" "echo 3 > /proc/sys/vm/drop_caches; findmnt -n -o FSTYPE $MNT; sha256sum -c --quiet /root/cablepull.sha 2>&1 | tail -5; echo SHA_RC=\${PIPESTATUS[0]}")
        grep -q 'SHA_RC=' <<<"$r" || echo "$h: the read-back did not finish within ${vbudget}s"
        echo "$h: $(echo "$r" | tr '\n' ' ')"
        grep -q 'SHA_RC=0' <<<"$r" && grep -q '^mxfs' <<<"$r" || bad=1
        k=$(on "$h" 60 "journalctl _TRANSPORT=kernel --since @$(cat "$E/t0") --no-pager -o cat | grep -aE 'BUG:|WARNING:|Oops|blocked for more than|Filesystem has been shut down|shutting down filesystem' | head -5")
        if [ -n "$k" ]; then echo "$h kernel log:"; echo "$k" | sed 's/^/    /'; bad=1; fi
    done
    on "${PAIR[0]}" "$vbudget" "rm -rf $MNT/cablepull" >/dev/null
    # the verdict is kept with the run, naming the build both hosts ran, so the
    # release table (data/release_table.json) can read it
    ident=$(on "${PAIR[0]}" 20 "echo version=\$(modinfo -F version mxfs) build=\$(cat /sys/module/mxfs/srcversion)")
    { [ "$bad" = 0 ] && echo "RESULT: PASS — every acknowledged file intact on both hosts, kernel logs clean" \
                     || echo "RESULT: FAIL"
      echo "acknowledged=$nacked $ident"; } | tee "$E/result.txt"
    [ "$bad" = 0 ]
    ;;
*) sed -n '2,30p' "$0"; exit 2 ;;
esac
