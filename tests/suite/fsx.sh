#!/bin/bash
# fsx — file-system exerciser: long randomized read/write/mmap/truncate/
# fallocate sequences with after-every-op data verification. Catches data
# corruption and mmap-vs-read/write coherency bugs. Agnostic: $1 = mount point.
#
# Uses the vendored fsx binary on NFS (tools/fsx, built once on clyde from the
# vendored fsx.c — host and VMs are identical, so one binary serves all nodes).

SUITE_TEST_NAME=fsx
MNT="${1:-/mnt/shared}"
NODES="${MXFS_NODES:-1}"
HERE="$(dirname "$(readlink -f "$0")")"
source "$HERE/lib.sh"
FSX="$HERE/tools/fsx"

[ -x "$FSX" ] || {
    echo "RESULT: FAIL | test=$SUITE_TEST_NAME | nodes=$NODES | measured=setup | reason=fsx binary missing at $FSX"; exit 1; }

W="$MNT/.suite_fsx.$(hostname).$$"
rm -rf "$W" 2>/dev/null; mkdir -p "$W" || {
    echo "RESULT: FAIL | test=$SUITE_TEST_NAME | nodes=$NODES | measured=setup | reason=cannot mkdir $W"; exit 1; }
# FSX_TRAP_LOG=<file off the mount> keeps what the trap's removal did: every
# name rm removed, any error, and its exit status.  A work directory left on
# the mount after the row could not otherwise say why the removal failed
# (D-FSX-ROW-WORK-DIRECTORY-LEFT-ON-THE-MXFS-MOUNT-AFTER-ITS-EXIT-TRAP-RAN-RM-RF).
# Unset, the trap discards both, as the board runs it.
if [ -n "${FSX_TRAP_LOG:-}" ]; then
    trap 'rm -rfv "$W" > "$FSX_TRAP_LOG" 2>&1; echo "trap_rm_rc=$? at $(date +%T.%N)" >> "$FSX_TRAP_LOG"' EXIT
else
    trap 'rm -rf "$W" 2>/dev/null' EXIT
fi

# A random seed each run (fsx's own default is always 1, so every run replayed
# the one same operation history), reported as seed=<n> so the board records it
# and a failing history can be replayed with FSX_SEED=<n>.  fsx keeps its seed in
# an int and prints its usage for a negative one, so the seed is 1..2^31-1: four
# random bytes gave a seed past INT_MAX half the time, and those runs exited 90
# at once, a FAIL that exercised nothing (0 would make fsx use the time instead).
SEED="${FSX_SEED:-$(( $(od -An -N4 -tu4 /dev/urandom | tr -d ' \n') % 2147483647 + 1 ))}"
SUITE_MEASURED_EXTRA="${SUITE_MEASURED_EXTRA:+$SUITE_MEASURED_EXTRA }seed=$SEED"

# run_fsx <ops> [extra args]  — fsx exits nonzero on any verify miscompare.  A
# failing run's log stays on the node and its path goes into the record, with
# its last lines in the kernel log the harness captures; a passing run's log is
# removed.  FSX_LOG_DIR moves the logs off /root for a run that is not root.
#
# fsx writes its own files: .fsxlog (every line it printed), .fsxops (the
# operation history a miscompare dumps, replayable with --replay-ops) and
# .fsxgood (the image the file should have held).  By default it puts them
# beside the test file in $W, which the EXIT trap removes, so a failing check
# lost them; moving them out after the fact copied ~256 kB off an mxfs mount
# that had just miscompared, and a check killed by the row's timeout never got
# to the move.  fsx's own -P writes them from the start into a directory of
# their own beside the kept log ($base.d, off the mount), so they survive
# whatever ends the row; the directory names go into the record, and a
# passing check's is removed with its log.  FSX_KEEP_FAIL_FILES=0 leaves them
# in $W to be removed with it, as before: the control.
run_fsx() {
    local base="${FSX_LOG_DIR:-/root}/fsx.$SEED.$1" log rc f kept="" pdir="" popt=""
    log="$base.log"
    if [ "${FSX_KEEP_FAIL_FILES:-1}" != 0 ]; then
        pdir="$base.d"
        mkdir -p "$pdir" && popt="-P $pdir"
    fi
    "$FSX" -S "$SEED" -N "$1" ${2:-} $popt "$W/fsxfile_$1" > "$log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        SUITE_MEASURED_EXTRA="$SUITE_MEASURED_EXTRA fsx_fail_log=$(hostname):$log"
        if [ -n "$popt" ]; then
            for f in fsxlog fsxops fsxgood; do
                [ -e "$pdir/fsxfile_$1.$f" ] && kept="${kept:+$kept,}$f"
            done
            SUITE_MEASURED_EXTRA="$SUITE_MEASURED_EXTRA fsx_fail_dir=$(hostname):$pdir fsx_fail_kept=${kept:-none}"
        fi
        echo "mxfs-FSXfail seed=$SEED ops=$1 rc=$rc $(tail -n 3 "$log" | tr '\n' ' ' | cut -c1-300)" > /dev/kmsg 2>/dev/null
    else
        rm -f "$log"
        [ -n "$pdir" ] && rm -rf "$pdir"
    fi
    return "$rc"
}

ck "fsx 100k mixed ops"          run_fsx 100000
ck "fsx 50k blocksize 8k -r4096" run_fsx 50000 "-r 4096 -w 4096"

finish
