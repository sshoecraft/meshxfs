#!/bin/bash
# runlock.sh — who may touch which rig nodes right now.  Sourced by run.sh,
# scripts/rig.sh; defines functions only.
#
# Three kinds of lock, all flock(2) on files in /tmp, held on an open fd until
# the holding process exits (a crash releases them; nothing to clean up):
#
#   /tmp/mxfs_run.lock          the rig as a whole.  A run over test1..testN
#                               takes it EXCLUSIVE, as it always has: it may
#                               power-cycle or tear down any rig VM outside its
#                               set, and it cleans the shared broker namespace.
#                               A rig-group run takes it SHARED, so any number
#                               of group runs coexist while a whole-rig run, or
#                               a rewiring of every node, is refused.
#   /tmp/mxfs_node.<node>.lock  one node.  A group run takes every node of its
#                               group, so two runs can never share a node.
#   /tmp/mxfs_config.<slug>.lock  one configuration.  Its board column and its
#                               stale-marker heal belong to one run at a time.
#
# Each file's content names the holder (pid, time, what), for the refusal.

RUNLOCK=/tmp/mxfs_run.lock

runlock_holder() {  # <file> -> the holder line it records, or "unknown"
    local h
    h=$(head -1 "$1" 2>/dev/null)
    echo "${h:-unknown}"
}

runlock_take() {  # <file> <shared|exclusive> <what> [wait_s] -> 0 if taken; the fd stays open
    local file=$1 mode=$2 what=$3 wait_s=${4:-0} fd flag=-x wflag=-n
    [ "$mode" = shared ] && flag=-s
    case $wait_s in ''|*[!0-9]*) wait_s=0 ;; esac
    [ "$wait_s" -gt 0 ] && wflag="-w $wait_s"
    exec {fd}>>"$file" || return 1
    # shellcheck disable=SC2086  # wflag is "-n" or "-w <s>" by design
    if ! flock $wflag $flag "$fd"; then
        exec {fd}>&-
        return 1
    fi
    # Only an exclusive holder rewrites the holder line: shared holders
    # append, so the file names every group run holding the rig.
    if [ "$mode" = exclusive ]; then
        : > "$file"
    fi
    echo "$$ $(date -u +%FT%TZ) $what" >> "$file"
    return 0
}

runlock_rig_free() {  # -> 0 iff no run of any kind holds the rig lock right now
    local fd
    exec {fd}>>"$RUNLOCK" || return 1
    if flock -n -x "$fd"; then
        exec {fd}>&-
        return 0
    fi
    exec {fd}>&-
    return 1
}

runlock_nodes() {  # <what> <node>... -> 0 iff every node's lock is taken
    local what=$1 n; shift
    for n in "$@"; do
        runlock_take "/tmp/mxfs_node.$n.lock" exclusive "$what" || {
            echo "ERROR: $n is held by another run: $(runlock_holder "/tmp/mxfs_node.$n.lock")"
            return 1
        }
    done
    return 0
}

vmhold_take() {  # <what> <vm>... -> holds every VM in use (tools/vm_pool.sh) while the caller lives
    local what=$1 v fd; shift
    for v in "$@"; do
        exec {fd}>>"/tmp/mxfs_vmhold.$v.lock" || return 1
        flock -s "$fd" || return 1
        echo "$$ $(date -u +%FT%TZ) $what" >> "/tmp/mxfs_vmhold.$v.lock"
    done
    return 0
}

# MXFS_CONFIG_LOCK_WAIT_S=<s> makes a run wait up to <s> seconds for the
# configuration's lock instead of refusing at once.  Two rig groups can run the
# same configuration (g2c and g2d are both 2/net/mesh/direct); their run.sh
# calls then take turns on the board column instead of one of them failing
# mid-queue with "held by another run" and costing the lap it belonged to.
# Unset or 0: refuse at once, as before.
runlock_config() {  # <slug> <what> -> 0 iff the configuration's lock is taken
    runlock_take "/tmp/mxfs_config.$1.lock" exclusive "$2" "${MXFS_CONFIG_LOCK_WAIT_S:-0}" || {
        echo "ERROR: configuration $1 is held by another run: $(runlock_holder "/tmp/mxfs_config.$1.lock")"
        return 1
    }
}
