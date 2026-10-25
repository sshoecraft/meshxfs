#!/bin/bash
# batch_variant_refuse_lap.sh -- one host lap of
# D-VERIFY-LAPS-UNDER-A-LANE-WIDE-TEST-ENV-RUN-AS-VARIANTS-AND-COUNT-NOTHING.
#
# The defect: a calibration or verification batch declared with no variant counts no lap that runs
# as a variant (tools/defects.py unplanned_variant), yet the queue admitted such a lap and the lap
# ran and was recorded, counting nothing. Attempt 22's 8-node verification b20261024-802114 ran 25
# laps under its lane's MXFS_TEST_ENV=PF_KEEP_KMSG=1 that way. The fix: run.sh and tools/batch_lap.py
# pass the lap's own variant to `defects.py batch-check`, which refuses the lap.
# MXFS_BATCH_VARIANT_REFUSE=0 admits it, as before: the same-build control.
#
# The defect lives on the host (the queue's check and the lap runner), so the lap runs there, on a
# scratch copy of the tree's tools and data in a fresh directory: it declares a two-lap calibration
# with no variant on the scratch queue, then
#   1. asks batch-check with no variant (must be admitted, or the lap measured nothing: ABORT);
#   2. asks batch-check with the lane's variant, MXFS_TEST_ENV=PF_KEEP_KMSG=1;
#   3. runs tools/batch_lap.py on the batch with MXFS_TEST_ENV=PF_KEEP_KMSG=1 in its environment and
#      `true` as the harness, and counts the scratch ledger's lines of the batch before and after.
#   EXPOSED  step 2's lap had a variant the batch does not declare
#   PASS     step 2 was refused naming that it would count nothing, and step 3 ran no lap and
#            recorded none
#   FAIL     either admitted the lap (step 3 recorded a run that counts nothing)
#   ABORT    the scratch tree or batch could not be made, or step 1 was refused
#
# Bound, derived: three queue commands of about 1 s each and one batch_lap of about 2 s; 20 s.
#
# Usage: tests/batch_variant_refuse_lap.sh <label>      (MXFS_BATCH_VARIANT_REFUSE=0: the control)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
T=$(mktemp -d /tmp/mxfs_bvr.XXXXXX) || { echo "LAP batch_variant_refuse ABORT: no scratch directory"; exit 2; }
mkdir -p "$T/tools" "$T/data" || exit 2
cp "$REPO"/tools/*.py "$REPO"/tools/*.sh "$T/tools/" 2>/dev/null
cp "$REPO"/data/*.json "$REPO"/data/*.jsonl "$T/data/" 2>/dev/null
cd "$T" || exit 2
echo "LAP batch_variant_refuse start $(date -u +%FT%TZ) label=$LABEL scratch=$T MXFS_BATCH_VARIANT_REFUSE=${MXFS_BATCH_VARIANT_REFUSE:-unset}"
CFG=2/net/mesh/direct
REC=$(python3 -c "import json; print(json.load(open('data/defects.json'))['defects'][0]['id'])")
B=$(timeout 10 python3 tools/defects.py batch "$REC" --kind calibrate --row fsync_basic --at $CFG --runs 2 \
        --candidate 0.90.134 --why "scratch batch of $LABEL" 2>&1 | grep -o 'batch b[0-9]*-[0-9a-f]*' | head -1 | cut -d' ' -f2)
[ -n "$B" ] || { echo "LAP batch_variant_refuse ABORT: no scratch batch declared"; exit 2; }
echo "  INFO scratch batch $B (calibrate, no variant) on $REC at $CFG"
plain=$(timeout 10 env -u MXFS_TEST_ENV python3 tools/defects.py batch-check "$B" --row fsync_basic --at $CFG --candidate 0.90.134 2>&1); prc=$?
[ "$prc" = 0 ] || { echo "LAP batch_variant_refuse ABORT: a lap with no variant was refused: $plain"; exit 2; }
V="MXFS_TEST_ENV=PF_KEEP_KMSG=1"
echo "EXPOSED: a lap with variant $V asks for calibration $B, declared with none"
withv=$(timeout 10 python3 tools/defects.py batch-check "$B" --row fsync_basic --at $CFG --candidate 0.90.134 --variant "$V" 2>&1); vrc=$?
echo "  STAGE batch-check with the variant: rc=$vrc $(echo "$withv" | tail -1 | cut -c1-200)"
n0=$(grep -c "\"batch\": \"$B\"" data/criteria.runs.jsonl)
lapout=$(MXFS_TEST_ENV=PF_KEEP_KMSG=1 MXFS_CANDIDATE=0.90.134 timeout 15 python3 tools/batch_lap.py --batch "$B" --at $CFG \
             --row fsync_basic --bound 10 --pass '.' --build-from "$REPO/mxfs.ko" -- true 2>&1); lrc=$?
n1=$(grep -c "\"batch\": \"$B\"" data/criteria.runs.jsonl)
echo "  STAGE batch_lap under the variant: rc=$lrc ledger lines of the batch $n0 -> $n1 $(echo "$lapout" | tail -1 | cut -c1-200)"
fails=0
if [ "$vrc" = 0 ] || ! grep -q "would count nothing" <<<"$withv"; then
    echo "  FAIL batch-check refused the lap with a variant the batch does not declare got=rc$vrc want=refused"; fails=$((fails + 1))
else
    echo "  PASS batch-check refused the lap with a variant the batch does not declare"
fi
if [ "$n1" -gt "$n0" ]; then
    echo "  FAIL batch_lap ran and recorded a lap that counts nothing got=$((n1 - n0)) want=0"; fails=$((fails + 1))
else
    echo "  PASS batch_lap recorded no lap under the variant"
fi
if [ "$fails" = 0 ]; then
    echo "LAP batch_variant_refuse PASS label=$LABEL"; exit 0
fi
echo "LAP batch_variant_refuse FAIL label=$LABEL fails=$fails"
exit 1
