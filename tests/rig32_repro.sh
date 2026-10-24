#!/bin/bash
#
# rig32_repro.sh — run one row N times at a 32-node configuration and keep, for
# every run that does not pass, what its nodes hold before the next run erases it.
#
# Three open records were each seen once at 32 nodes, on builds of 2026-08 and
# 2026-09, and kept nothing that names a cause:
#   D-32CAWMPATH-DIR-REUSE-ROUND7-RANK9-FAILED-WITH-READDIR-AND-LOOKUPS-WHOLE
#     (32/disk/caw/mpath dir_reuse_coherency, a round failed with readdir 128/128
#     and no lookup failing, on a predicate the ledger does not name)
#   D-32CAWMPATH-PREP-CLUSTER-FAILED-AFTER-177S-NO-EVIDENCE-RETAINED
#   D-32NETMESH-PREP-CLUSTER-FAILED-AFTER-9S-NO-EVIDENCE-RETAINED
# Each is cleared only by a reproduction that shows its cause. Two things stood
# in the way of keeping one: dir_reuse_coherency deletes its failed-round files
# (/root/drc_fail_r*, /root/drc_failverify_r*, /root/drc_failrounds.txt) as it
# starts (tests/suite/dir_reuse_coherency.sh:60), so each run erased the evidence
# of the one before it; and a prep keeps no node's kernel log, only its own
# output, which the lane's step log holds.
#
# Each run is `./run.sh <configuration> <row>`, which bounds it by the row's
# budget in tests/suite/manifest; a prep_cluster run is forced
# (MXFS_FORCE_PREP=1), so every run is a fresh prep. After a run whose rc is not
# 0 this keeps, in <out>/run<i>/: every node's kernel ring (dmesg) and its
# journal's kernel lines since the run began (the ring wraps within minutes under
# the module's debug lines; the journal is volatile and current-boot only, so
# both are kept), and for dir_reuse_coherency every node's /root/drc_fail*.dmesg
# and /root/drc_failrounds.txt. A run that passes keeps nothing but its line.
#
# Usage: tests/rig32_repro.sh <label> <configuration> <row> <runs>
# Output: tests/evidence/<stamp>_rig32_<label>/ with one line per run in runs.txt:
#   RUN <i> rc=<rc> secs=<s>
# and a last line on stdout: RESULT: <k> of <n> runs did not pass.
# Bounds: each run is bounded by run.sh; each node's collection by 60 s, all
# nodes in parallel.
set -u
LABEL=${1:?label}
CONFIG=${2:?configuration}
ROW=${3:?row}
RUNS=${4:?runs}
cd "$(dirname "$0")" || exit 2
# the tree root holds run.sh and tests/lib/rig.sh both: the drafts tree holds a run.sh of its own
while { [ ! -f run.sh ] || [ ! -f tests/lib/rig.sh ]; } && [ "$(pwd)" != / ]; do cd ..; done
[ -f run.sh ] || { echo "ABORT: no tree root above $0"; exit 2; }
NODES=${CONFIG%%/*}
case $NODES in ''|*[!0-9]*) echo "ABORT: no node count in $CONFIG"; exit 2 ;; esac
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_rig32_$LABEL
mkdir -p "$OUT" || exit 2
echo "=== rig32_repro label=$LABEL config=$CONFIG row=$ROW runs=$RUNS nodes=test1..test$NODES out=$OUT"

collect() {  # <dir> <since-utc>
    local dir=$1 since=$2 n
    mkdir -p "$dir"
    for n in $(seq 1 "$NODES"); do
        (
            h=test$n
            timeout 60 tools/mxfs_sshpass.sh "$h" "dmesg" > "$dir/$h.dmesg" 2> "$dir/$h.err"
            timeout 60 tools/mxfs_sshpass.sh "$h" \
                "journalctl -k --utc --since '$since' -o short-iso --no-pager" \
                > "$dir/$h.klog" 2>> "$dir/$h.err"
            if [ "$ROW" = dir_reuse_coherency ]; then
                timeout 60 tools/mxfs_sshpass.sh "$h" \
                    "cd /root && for f in drc_fail_r*_rank*.dmesg drc_failverify_r*_rank*.dmesg drc_failrounds.txt; do [ -f \"\$f\" ] && { echo \"=== \$f\"; cat \"\$f\"; }; done" \
                    > "$dir/$h.drc_fail.txt" 2>> "$dir/$h.err"
            fi
        ) &
    done
    wait
}

bad=0
for i in $(seq 1 "$RUNS"); do
    since=$(date -u '+%Y-%m-%d %H:%M:%S')
    t0=$SECONDS
    if [ "$ROW" = prep_cluster ]; then
        MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" prep_cluster
    else
        ./run.sh "$CONFIG" "$ROW"
    fi
    rc=$?
    secs=$(( SECONDS - t0 ))
    echo "RUN $i rc=$rc secs=$secs" | tee -a "$OUT/runs.txt"
    if [ "$rc" != 0 ]; then
        bad=$(( bad + 1 ))
        collect "$OUT/run$i" "$since"
        echo "RUN $i kept: $(cat "$OUT/run$i"/*.dmesg 2>/dev/null | wc -l) ring lines, $(cat "$OUT/run$i"/*.klog 2>/dev/null | wc -l) journal lines, $(grep -c '^=== ' "$OUT/run$i"/*.drc_fail.txt 2>/dev/null | awk -F: '{s+=$2} END {print s+0}') failed-round files" | tee -a "$OUT/runs.txt"
    fi
done
echo "RESULT: $bad of $RUNS runs did not pass" | tee -a "$OUT/runs.txt"
