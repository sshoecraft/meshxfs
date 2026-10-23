#!/bin/bash
# row_pull_since_start_lap.sh -- one lap of D-DIRENT-DURABILITY-CAPTURE-COPIES-STALE-DMESG-AT-FAIL-FROM-EARLIER-BOOTS.
#
# A cluster row that did not pass pulls each node's /root/drc_* captures and fsx logs into its
# evidence directory (run.sh pull_row_artifacts).  The nodes keep those files across rows and
# boots, and the pull took every one by name, so run_dirent_durability_20261019T191246Z-g8 carried
# dmesg_at_fail.txt copies of July and August boots, one with an old build's corruption line,
# beside that run's own kernel logs.  The fix: each node stamps the row's start on its own clock
# (mark_row_start) and the pull takes only files written after it.
#
# The lap plants on each node a capture as an earlier boot left one,
# /root/drc_blkdump_planted_<label>/dmesg_at_fail.txt, and an fsx log as an earlier fsx row left
# one, /root/fsx.planted_<label>.log, both dated 2026-07-26, then runs a cluster row made to fail
# at once: alloc_witness with rank 2 aborting after its fill (AW_ABORT_RANK=2), which ends in about
# a second with the abort named.  The row is recorded on a scratch copy of the board (MXFS_CRIT),
# never on the release board.  MXFS_PULL_SINCE_ROW passes through (0 is run.sh's switch back to the
# pull by name: the control).  The planted files are removed at the end.
#
# A pull that selected nothing at all would also leave the planted files out, so the lap also
# writes on each node, once the node's own row mark (/root/.mxfs_row_mark) is newer than a
# reference it touched while planting, a capture and an fsx log as the row itself would write
# them: /root/drc_blkdump_fresh_<label>/dmesg_at_fail.txt and /root/fsx.fresh_<label>.log, then
# 'mxfs-rowpull-fresh <label>' into the node's kernel log.  The pull reads each node's kernel log
# before its files, so that line after the row's mark in the pulled kernel log shows both were in
# place before the pull; the pull with the fix must copy them, and the pull by name copies them too.
#
# The pull by name lists drc_* and fsx.*.log in one ls, which exits 2 when either glob matches
# nothing, and then pulls nothing at all: a node holding a capture and no fsx log copies nothing
# with the fix out, so a lap planting the capture alone measured nothing on nodes where no fsx row
# had left a log (control b20261023-191fef).  Both are planted on every node for that reason.
#
#   EXPOSED  every node held both planted files when the row started, wrote both fresh files after
#            the row's mark and before its pull, and the row's pull ran (its evidence directory
#            holds the nodes' kernel logs)
#   PASS     no planted file is in the run's evidence, and every node's fresh files are
#   FAIL     a planted file was copied into the run's evidence, or a node's fresh file was not
#   ABORT    a capture could not be planted, the row did not fail, its pull left no directory, or a
#            node's fresh files were not in place after the mark and before the pull
#
# Bound, derived: planting and removing ~10 s; the row (rank 2 aborts after its fill: ~25 s
# measured with the abort broadcast, 120 s budget without it) plus run.sh's preflight and
# pre-assert (20-30 s) and the pull: about 170 s at worst, bounded at 200 s.  The fresh files'
# writer runs beside run.sh and waits for the mark at most 48 s, twice the 17-24 s measured from a
# lap's start to its row's mark (batch b20261023-5a85e4), plus 20 s for its ssh as every other
# call here: it adds nothing to the bound.
#
# Usage: tests/row_pull_since_start_lap.sh <label> <configuration>   (the pair formed, its group's env)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
AT=${2:?configuration}
cd "$(dirname "$0")/.." || exit 2
NODES=${MXFS_NODE_LIST:-test1,test2}; NODES=${NODES//,/ }
PL=drc_blkdump_planted_$LABEL
FL=fsx.planted_$LABEL.log
FC=drc_blkdump_fresh_$LABEL
FF=fsx.fresh_$LABEL.log
REF=.mxfs_rowpull_ref_$LABEL
S=$(mktemp -d /tmp/mxfs_rowpull.XXXXXX) || { echo "LAP row_pull ABORT: no scratch directory"; exit 2; }
unplant() {
    local n
    for n in $NODES; do
        timeout 20 tools/mxfs_sshpass.sh "$n" "rm -rf /root/$PL /root/$FL /root/$FC /root/$FF /root/$REF" < /dev/null > /dev/null 2>&1
    done
    rm -rf -- "$S"
}
trap unplant EXIT
cp data/criteria.json "$S/criteria.json" || { echo "LAP row_pull ABORT: no board copy"; exit 2; }
for n in $NODES; do
    p=$(timeout 20 tools/mxfs_sshpass.sh "$n" "mkdir -p /root/$PL && echo 'PLANTED $LABEL: a capture an earlier boot left' > /root/$PL/dmesg_at_fail.txt && echo 'PLANTED $LABEL: an fsx log an earlier row left' > /root/$FL && touch -d '2026-07-26 12:00:00' /root/$PL/dmesg_at_fail.txt /root/$PL /root/$FL && touch /root/$REF && stat -c '%y' /root/$PL/dmesg_at_fail.txt /root/$FL" < /dev/null 2>/dev/null | grep -ac '^2026-07-26')
    [ "$p" = 2 ] || { echo "LAP row_pull ABORT: could not plant the capture and the fsx log on $n (dated: ${p:-0} of 2)"; exit 2; }
done
echo "LAP row_pull start $(date -u +%FT%TZ) label=$LABEL at=$AT since_row=${MXFS_PULL_SINCE_ROW:-1} planted=/root/$PL,/root/$FL fresh=/root/$FC,/root/$FF on $NODES"
# Each node's writer of the fresh files: the mark is the only thing that makes the row's own
# files newer than it, so they are written only once the mark is newer than the reference, and
# WRITTEN is printed only when the node's own clock puts both after the mark.
wpids=()
for n in $NODES; do
    timeout 68 tools/mxfs_sshpass.sh "$n" "i=0; until [ /root/.mxfs_row_mark -nt /root/$REF ] || [ \$i -ge 480 ]; do i=\$((i+1)); sleep 0.1; done; [ /root/.mxfs_row_mark -nt /root/$REF ] && mkdir -p /root/$FC && echo 'FRESH $LABEL: a capture the row wrote' > /root/$FC/dmesg_at_fail.txt && echo 'FRESH $LABEL: an fsx log the row wrote' > /root/$FF && [ /root/$FC/dmesg_at_fail.txt -nt /root/.mxfs_row_mark ] && [ /root/$FF -nt /root/.mxfs_row_mark ] && echo 'mxfs-rowpull-fresh $LABEL' > /dev/kmsg && echo WRITTEN" \
        < /dev/null > "$S/fresh_$n.out" 2>&1 &
    wpids+=($!)
done
env -u MXFS_BATCH MXFS_CRIT="$S/criteria.json" MXFS_TEST_ENV="AW_ABORT_RANK=2" \
    ./run.sh "$AT" alloc_witness < /dev/null > "$S/run.out" 2>&1
wait "${wpids[@]}"
grep -aE '^\s+[A-Z]+\s+alloc_witness\b|logs: |ABORTED|^=== done' "$S/run.out" | cut -c1-300
python3 - "$S/criteria.runs.jsonl" "$AT" "$PL" "$FL" "$FC" "$FF" "$LABEL" "$S" $NODES <<'EOF'
import gzip, json, sys
from pathlib import Path
ledger, at, planted, fsxlog = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
fresh, freshlog, label, scratch, nodes = sys.argv[5], sys.argv[6], sys.argv[7], Path(sys.argv[8]), sys.argv[9:]
runs = []
if ledger.exists():
    for line in ledger.read_text().splitlines():
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if item.get("kind") == "run" and item.get("row") == "alloc_witness" and item.get("config") == at:
            runs.append(item)
if not runs:
    print("LAP row_pull ABORT: run.sh recorded no alloc_witness run on the scratch board")
    sys.exit(2)
run = runs[-1]
art = Path("tests/evidence") / f"run_alloc_witness_{run.get('run_id')}"
print(f"LAP row_pull run={run.get('run_id')} outcome={run.get('outcome')} evidence={run.get('evidence', '')}")
if run.get("outcome") == "PASS":
    print("LAP row_pull ABORT: the row passed, so it pulled nothing")
    sys.exit(2)
kern = [n for n in nodes if (art / f"kernlog_{n}.gz").is_file()]
if len(kern) != len(nodes):
    print(f"LAP row_pull ABORT: the row's pull left kernel logs of {kern} of {nodes} in {art}")
    sys.exit(2)
def before_pull(n):
    # The pull read this kernel log before the node's files, so the writer's line after the
    # row's own mark puts the fresh files on the node ahead of the pull.
    marked = False
    with gzip.open(art / f"kernlog_{n}.gz", "rt", errors="replace") as log:
        for line in log:
            if f"mxfs-rowmark {run.get('run_id')}-" in line:
                marked = True
            elif marked and f"mxfs-rowpull-fresh {label}" in line:
                return True
    return False
outs = {n: scratch / f"fresh_{n}.out" for n in nodes}
unwritten = [n for n in nodes if not outs[n].is_file() or "WRITTEN" not in outs[n].read_text(errors="replace")]
late = [n for n in nodes if n not in unwritten and not before_pull(n)]
if unwritten or late:
    print(f"LAP row_pull ABORT: the fresh files were not written after the row's mark on {unwritten}, or not before its pull on {late}")
    sys.exit(2)
print(f"EXPOSED: every node held /root/{planted} and /root/{fsxlog} from 2026-07-26, wrote /root/{fresh} and /root/{freshlog} after the row's mark and before its pull, and the row's pull ran ({art})")
copied = sorted(str(p) for p in list(art.glob(f"*_{planted}*")) + list(art.glob(f"*_{fsxlog}")))
missing = [str(p) for n in nodes for p in (art / f"{n}_{fresh}" / "dmesg_at_fail.txt", art / f"{n}_{freshlog}") if not p.is_file()]
if copied:
    print(f"LAP row_pull FAIL: files an earlier row or boot left were copied into the run's evidence: {' '.join(copied)}")
if missing:
    print(f"LAP row_pull FAIL: files the row wrote after its mark were not pulled into the run's evidence: {' '.join(missing)}")
if copied or missing:
    sys.exit(1)
print(f"LAP row_pull PASS: no capture or fsx log older than the row is in {art}, and every node's capture and fsx log written after the row's mark are")
sys.exit(0)
EOF
