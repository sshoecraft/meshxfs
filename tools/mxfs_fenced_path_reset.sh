#!/bin/sh
# mxfs_fenced_path_reset.sh — release the writes a fenced node's own iSCSI
# paths are holding.
#
# Run by mxfs.ko (user-mode helper) on a node the cluster has fenced, with the
# disk names of that node's SCSI paths to the shared LUN as arguments
# (e.g. "sda sdb").
#
# WHY.  The fence is a PREEMPT AND ABORT, and it aborts this node's commands
# still queued at the target.  A target may release those commands without
# sending any response (iscsi-scst does, whatever the Control mode page's TAS
# bit says), and the Linux initiator then holds each one for three expiries of
# its command timeout before its error handler aborts it — 540 s at the 180 s
# timeout MeshXFS asks for.  The fenced filesystem's unmount waits on those
# writes, so the node cannot leave or rejoin the cluster for that long.
#
# WHAT IT DOES.  For each path that is an iSCSI session, it drops that
# session's TCP connection.  libiscsi treats that as a connection error,
# requeues every command it was holding, and iscsid recovers the same session
# (the SCSI devices stay); the requeued writes go out again, meet the
# reservation that fenced this node, and return RESERVATION CONFLICT at once.
# No task-management function is sent, so no other node's commands are
# touched.  A write it releases could only have finished later without it,
# never earlier.  Where the kernel cannot destroy a socket (ss -K needs
# CONFIG_INET_DIAG_DESTROY) the session is logged out and back in instead.
# A path that is not iSCSI is left alone.
#
# Every action is written to the kernel log as a P-FENCED-PATH-RESET line.
# Exit 0 when every iSCSI path was reset (or there was none), 1 otherwise.

log() { echo "mxfs: P-FENCED-PATH-RESET $*" > /dev/kmsg 2>/dev/null; }

rc=0
for p in "$@"; do
    case "$p" in *[!a-z0-9]*|'') log "path='$p' skipped -- not a disk name"; rc=1; continue ;; esac
    sess=$(readlink -f "/sys/block/$p/device/../.." 2>/dev/null)
    case "$sess" in
        */session[0-9]*) ;;
        *) log "path=$p not-iscsi -- left alone"; continue ;;
    esac
    conn=$(ls -d "$sess"/connection*/iscsi_connection/connection* 2>/dev/null | head -1)
    addr=$(cat "$conn/address" 2>/dev/null)
    port=$(cat "$conn/port" 2>/dev/null)
    lport=$(cat "$conn/local_port" 2>/dev/null)
    sid=${sess##*/session}
    # ss exits 0 whether or not a socket matched: count the ones it closed
    killed=0
    if [ -n "$addr" ] && [ -n "$port" ] && [ -n "$lport" ]; then
        killed=$(ss -HtnK dst "$addr" dport = ":$port" sport = ":$lport" 2>/dev/null | grep -c .)
    fi
    if [ "${killed:-0}" -ge 1 ]; then
        log "path=$p session=$sid portal=$addr:$port local_port=$lport how=connkill closed=$killed rc=0"
        continue
    fi
    tgt=$(cat "/sys/class/iscsi_session/session$sid/targetname" 2>/dev/null)
    if [ -n "$tgt" ] && [ -n "$addr" ] &&
       iscsiadm -m session -r "$sid" --logout > /dev/null 2>&1 &&
       iscsiadm -m node -T "$tgt" -p "$addr:$port" --login > /dev/null 2>&1; then
        log "path=$p session=$sid portal=$addr:$port how=relogin rc=0"
        continue
    fi
    log "path=$p session=$sid portal=$addr:$port rc=1 -- neither the connection kill nor a relogin worked; the held writes return only when the initiator's timeout ladder ends"
    rc=1
done
exit $rc
