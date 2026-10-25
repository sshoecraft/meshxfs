# fuser_guard.sh — the shell text a harness sends a node to end what holds a
# mount, guarded so it runs only while the directory is still a mount point.
#
# fuser -m on a directory that is not a mount point names every user of the
# filesystem the directory is on, so `fuser -km /mnt/shared` after the volume
# was unmounted SIGKILLs every process on the node's root filesystem, sshd and
# the node's daemons with it (the merge-overrun lap's cleanup did exactly that
# on every passing lap: D-MERGE-OVERRUN-LAP-CLEANUP-FUSER-KILLS-ROOT-FS-USERS-WHEN-NOT-MOUNTED).
# Every cleanup that kills a mount's users takes its command from here, so
# tests/fuser_guard_lap.sh exercises the same text the harnesses send
# (D-FUSER-KM-WITHOUT-MOUNT-CHECK-IN-CLOSURE-RACE-AND-DRBD-RESOLVE-TEST).
#
# fuser_mounted_cmd <mnt> [settle s]
#   prints a command list, ending in ';', that kills every process using <mnt>
#   and sleeps <settle> (default 1) seconds, only while <mnt> is a mount point.
#   FUSER_MOUNT_GUARD=0 prints the unguarded kill, as before the fix: the
#   control, never set outside a control lap.
fuser_mounted_cmd() {
    local mnt=${1:?fuser_mounted_cmd: mount point} settle=${2:-1}
    if [ "${FUSER_MOUNT_GUARD:-1}" = 0 ]; then
        printf 'fuser -km %s >/dev/null 2>&1; sleep %s;' "$mnt" "$settle"
    else
        printf 'mountpoint -q %s && { fuser -km %s >/dev/null 2>&1; sleep %s; };' "$mnt" "$mnt" "$settle"
    fi
}

# fuser_inmounts_cmd <mnt>
#   prints the kill of every process using <mnt>, ending in ';', run only while
#   <mnt> is in /proc/mounts.  run.sh's kill of a timed-out row's leftovers
#   sends this: it ran 'fuser -k -m $MNT' on every node whether the volume was
#   mounted or not (D-RUN-SH-TIMEOUT-KILL-FUSER-ON-AN-UNMOUNTED-MNT-KILLS-ROOT-FS-USERS).
#   /proc/mounts and not mountpoint -q, as run.sh's teardown reads it: a stat
#   of a quarantined mount's root answers ESTALE.
#   MXFS_TIMEOUT_KILL_MOUNT_GUARD=0 prints the unguarded kill, as before: the
#   control, never set outside a control lap.
fuser_inmounts_cmd() {
    local mnt=${1:?fuser_inmounts_cmd: mount point}
    if [ "${MXFS_TIMEOUT_KILL_MOUNT_GUARD:-1}" = 0 ]; then
        printf 'fuser -k -m %s >/dev/null 2>&1;' "$mnt"
    else
        printf "grep -q ' %s ' /proc/mounts && fuser -k -m %s >/dev/null 2>&1;" "$mnt" "$mnt"
    fi
}
