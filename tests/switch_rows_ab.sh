#!/bin/bash
# tests/switch_rows_ab.sh <configuration> <group> <nodes-csv> "<rows>" [pairs] [label]
#
# A same-build, same-prep A/B of one module switch over board rows.  One prep
# (a module load resets every switch and capped probe), then per pair arm F
# (KNOB=1, the fix) and arm C (KNOB=0, the same-build control).  Each arm sets
# the switch on every node, boards PRE_ROWS (state the defect needs, not
# graded), boards <rows> in one run.sh call, then reads the switch back on
# every node: a value that did not survive (a module reload in between puts
# every parameter back to its default) voids the arm instead of grading it.
#
#   KNOB=<name>        the module parameter under test (required)
#   PRE_ROWS="..."     rows boarded before <rows> in each arm, not graded
#   GRADE="..."        the rows of <rows> that grade the arm (default: all)
#   PROBES="a|b|..."   kernel-log tags counted per arm over the graded rows'
#                      kernlog_<node>.gz (run_<row>_<run_id>/), one count each
#   SCOPE_MARK=<text>  count only the lines after the last line holding it:
#                      the kernel ring survives every arm on one prep, so an
#                      unscoped count carries the earlier arms' lines
#
# An arm PASSes when every graded row PASSes.  The verdict line:
#   SUPPORTED  every F arm passed and at least one C arm failed
#   REFUTED    an F arm failed
#   NOREACH    every arm passed: the control never showed the defect, so the
#              A/B proves nothing about the fix
#
# Runs from the checkout holding this script, so a sibling
# (tools/sibling_sync.sh) boards its own build while the main tree's module
# stays loaded elsewhere.
#
# Bounds, derived, never chosen: each run.sh call is bounded by the sum of its
# rows' BUDGET_S from tests/suite/manifest or tests/tooling/manifest (a linear
# row times the node count) plus 40 s of run.sh setup and aggregation per call
# (measured 30-40 s on the 8-node boards); prep by its manifest 300 s.
set -u
cd "$(dirname "$0")/.." || exit 1
CFG=${1:?configuration}; G=${2:?rig group}; NODES=${3:?comma list of the group nodes}
ROWS=${4:?rows to board per arm}; PAIRS=${5:-3}; LABEL=${6:-swab}
KNOB=${KNOB:?KNOB=<module parameter>}
PRE_ROWS=${PRE_ROWS:-}
GRADE=${GRADE:-$ROWS}
PROBES=${PROBES:-}
N=$(echo "$NODES" | tr ',' '\n' | grep -c .)

row_budget() { # <row>: its manifest budget in seconds, scaled for a linear row
    awk -v r="$1" -v n="$N" '$1 !~ /^#/ && $2 == r && $5 ~ /^[0-9]+$/ { b = ($6 == "linear") ? $5 * n : $5; print b; exit }' \
        tests/suite/manifest tests/tooling/manifest
}
rows_bound() { # <rows...>: the bound of one run.sh call boarding them
    local t=40 r b
    for r in "$@"; do
        b=$(row_budget "$r")
        [ -n "$b" ] || { echo "no manifest budget for row $r" >&2; return 1; }
        t=$((t + b))
    done
    echo "$t"
}

OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_swab_$LABEL
mkdir -p "$OUT"
pre_bound=0
[ -n "$PRE_ROWS" ] && { pre_bound=$(rows_bound $PRE_ROWS) || exit 2; }
rows_b=$(rows_bound $ROWS) || exit 2
echo "=== switch_rows_ab knob=$KNOB rows=[$ROWS] grade=[$GRADE] pre=[$PRE_ROWS] cfg=$CFG group=$G nodes=$NODES pairs=$PAIRS bounds=pre:${pre_bound}s rows:${rows_b}s tree=$(pwd) sv=$(modinfo -F srcversion mxfs.ko) out=$OUT $(date -u +%FT%TZ) ==="
MXFS_FORCE_PREP=1 timeout 300 ./run.sh "$CFG" --group "$G" prep_cluster > "$OUT/prep.log" 2>&1
prc=$?
[ "$prc" = 0 ] || { echo "RESULT ABORT swab: prep rc=$prc ($OUT/prep.log)"; exit 2; }
void=0; c_pass=0; c_fail=0; f_pass=0; f_fail=0
for p in $(seq 1 "$PAIRS"); do
  for arm in F1 C0; do
    v=1; [ "$arm" = C0 ] && v=0
    tag=p${p}_$arm
    tests/fleet_set_params.sh "$KNOB=$v" "$NODES" "$OUT/knobs_${tag}_set.txt" > /dev/null 2>&1
    if [ -n "$PRE_ROWS" ]; then
      timeout "$pre_bound" ./run.sh "$CFG" --group "$G" $PRE_ROWS > "$OUT/pre_$tag.log" 2>&1
      echo "  PRE $tag rc=$? $(grep -a -E '^Total:' "$OUT/pre_$tag.log" | tail -1)"
    fi
    s=$(date +%s)
    timeout "$rows_b" ./run.sh "$CFG" --group "$G" $ROWS > "$OUT/run_$tag.log" 2>&1
    rrc=$?
    wall=$(( $(date +%s) - s ))
    tests/fleet_set_params.sh "$KNOB" "$NODES" "$OUT/knobs_${tag}_after.txt" > /dev/null 2>&1
    got=$(grep -c "$KNOB=$v\b" "$OUT/knobs_${tag}_after.txt")
    if [ "$got" != "$N" ]; then
      echo "  RESULT $tag VOID switch read back on $got of $N nodes"; void=$((void+1)); continue
    fi
    rid=$(grep -a -o 'run_id=[^ )]*' "$OUT/run_$tag.log" | head -1 | cut -d= -f2)
    verdict=PASS; rows_txt=""
    for r in $GRADE; do
      line=$(grep -a -E "^\s+(PASS|FAIL|FLAKY|ABORTED|SKIP[A-Z]*|BLOCKED)\s+$r\b" "$OUT/run_$tag.log" | tail -1 | sed 's/^ *//')
      st=$(printf '%s' "$line" | awk '{print $1}')
      rows_txt="$rows_txt $r=${st:-none}"
      [ "$st" = PASS ] || verdict=FAIL
    done
    probes_txt=""
    if [ -n "$PROBES" ] && [ -n "$rid" ]; then
      for pat in $(echo "$PROBES" | tr '|' ' '); do
        c=0
        for r in $GRADE; do
          for k in tests/evidence/run_${r}_${rid}/kernlog_*.gz; do
            [ -f "$k" ] || continue
            if [ -n "${SCOPE_MARK:-}" ]; then
              c=$((c + $(zcat "$k" | awk -v m="$SCOPE_MARK" -v p="$pat" \
                  'index($0, m) { n = 0; next } index($0, p) { n++ } END { print n + 0 }')))
            else
              c=$((c + $(zcat "$k" | grep -a -c -- "$pat")))
            fi
          done
        done
        probes_txt="$probes_txt $pat=$c"
      done
    fi
    echo "  RESULT $tag $KNOB=$v verdict=$verdict rc=$rrc wall=${wall}s run_id=${rid:-none} rows:${rows_txt} probes:${probes_txt}"
    case "$arm:$verdict" in
      C0:PASS) c_pass=$((c_pass+1));; C0:*) c_fail=$((c_fail+1));;
      F1:PASS) f_pass=$((f_pass+1));; F1:*) f_fail=$((f_fail+1));;
    esac
  done
done
tests/fleet_set_params.sh "$KNOB=1" "$NODES" "$OUT/knobs_restore.txt" > /dev/null 2>&1
echo "  INFO c0_pass=$c_pass c0_fail=$c_fail f1_pass=$f_pass f1_fail=$f_fail void=$void evidence=$OUT"
[ "$void" = 0 ] || { echo "RESULT ABORT swab: $void void arm(s)"; exit 2; }
if [ "$f_fail" -gt 0 ]; then echo "RESULT REFUTED swab: F1 failed $f_fail of $PAIRS"; exit 1; fi
if [ "$c_fail" -gt 0 ]; then echo "RESULT SUPPORTED swab: every F1 arm passed, C0 failed $c_fail of $PAIRS"; exit 0; fi
echo "RESULT NOREACH swab: every arm passed; the control never showed the defect"; exit 3
