#!/bin/bash
# nlink_answer_lost_laps.sh — path_answer_lost then chk_clean on a formed
# cluster, lap after lap, until chk_clean finds the volume CORRUPT or the laps
# run out.  On 2026-10-19 that pair of rows left a regular file of nlink 1
# named by two directory entries at 4 and at 8 nodes on 4/ and 8/disk/caw/mpath
# (D-CAWMPATH-NLINK1-FILE-NAMED-TWICE-AFTER-ANSWER-LOST).
#
# Each lap is one run.sh invocation of the two rows (run.sh adds alloc_witness
# before chk_clean) on the cluster the caller formed: the rig group, any module
# knob (MXFS_EXTRA_MODARGS at the prep) and MXFS_TEST_ENV come from the
# environment, and run.sh records a run with either set as a variant.  A
# CORRUPT verdict ends the laps, since the next row would mount the condemned
# volume and a new prep formats it.  chk_clean keeps, in its evidence file,
# every directory entry naming an inode a link-count error names; on CORRUPT
# this prints them with the errors.
#
# Usage: tests/nlink_answer_lost_laps.sh <configuration> <laps>
# Bound: each row's budget in data/criteria.json, which run.sh enforces
# (path_answer_lost 300 s, alloc_witness 120 s, chk_clean 180 s).
set -u
cd "$(dirname "$0")/.." || exit 2
CFG=${1:?usage: nlink_answer_lost_laps.sh <configuration> <laps>}
LAPS=${2:?usage: nlink_answer_lost_laps.sh <configuration> <laps>}
[[ "$LAPS" =~ ^[1-9][0-9]*$ ]] || { echo "laps must be a positive integer (got '$LAPS')"; exit 2; }
G=${MXFS_GROUP:?MXFS_GROUP names the rig group of the formed cluster}
out=$(mktemp)
trap 'rm -f "$out"' EXIT
for ((lap = 1; lap <= LAPS; lap++)); do
    echo "LAP $lap start $(date -u +%FT%TZ) $CFG group=$G modargs=${MXFS_EXTRA_MODARGS:-none} env=${MXFS_TEST_ENV:-none}"
    ./run.sh "$CFG" --group "$G" path_answer_lost chk_clean 2>&1 | tee "$out"
    rc=${PIPESTATUS[0]}
    pal=$(grep -aE '^  [A-Z]+ +path_answer_lost  ' "$out" | tail -1)
    chk=$(grep -aE '^  [A-Z]+ +chk_clean  ' "$out" | tail -1)
    echo "LAP $lap end $(date -u +%FT%TZ) run.sh rc=$rc"
    echo "LAP $lap path_answer_lost: ${pal:-no result line}"
    echo "LAP $lap chk_clean: ${chk:-no result line}"
    case "$chk" in
        *verdict=CORRUPT*)
            ev=$(sed -n 's/.* evidence=\([^ ]*\).*/\1/p' <<<"$chk")
            ev=${ev/#\/src\/mxfs\//}
            echo "LAP $lap CORRUPT: evidence $ev"
            grep -a -E 'ERROR:|NAMES-OF:|=== every entry naming' "$ev" 2>/dev/null | head -60
            echo "STOP: lap $lap found the volume CORRUPT; nothing formats or mounts it from here"
            exit 1 ;;
        *verdict=CLEAN*) ;;
        *)
            echo "STOP: lap $lap reached no chk_clean verdict"
            exit 3 ;;
    esac
done
echo "DONE: $LAPS lap(s), every chk_clean verdict CLEAN"
