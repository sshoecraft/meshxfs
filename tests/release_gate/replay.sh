#!/bin/bash
#
# replay.sh — the release gate's known answers, replayed on recorded data.
#
# Usage: tests/release_gate/replay.sh
#
# The fixtures in tests/release_gate/fixtures/2026-10-21/ are the real board,
# run ledger, defect queue and DRBD rig board as they stood on 2026-10-21, when
# the release verification rework landed (docs/rulings/release-verification-
# rework.md).  Nothing in them is constructed.  Each check below is a question
# the old gate answered wrongly, or that the owner asked, with the answer the
# new gate must give on that day's data:
#
#   1. 16/net/mesh/direct alloc_witness, graded on the 0.90.132 release build
#      (71AC...), reads PASS -- its two failures on the 0.90.131 candidate build
#      stay in the ledger, named by the capacity record, and grade nothing here
#      ("DOES THIS SPECIFIC CONFIGURATION PASS THIS TEST RIGHT NOW").
#   2. The capacity record's 0.90.132 single-pass verify marks no longer clear
#      4, 8 and 16/net/mesh: a mark with no declared batch counts for nothing.
#   3. At least 25 pre-assert runs that the old gate excluded as rig noise are
#      incidents now (INCOMPLETE until a reviewed disposition says why).
#   4. 8 and 16/net/mesh/mpath, left out of 0.90.132's claims, still block the
#      release: the default install reaches them and no guard is declared.
#   5. The verification batch sizes at the policy's 99%: 7 of 7 -> 9 clean
#      laps, 20 of 20 -> 4, 1 of 1 -> 1058.
#   6. Seeding the DRBD rig board's ledger beside the primary skips the copies
#      of the primary's runs, and its incidents are its own column's only.
#   7. The incident gate exits non-zero on that day's data.
#
# Read-only on the tree: every file it writes is in a fresh temporary
# directory.  Budget: the board and ledger are read a few dozen times, each
# well under 10 s (measured on the live data the same day); 180 s in all.
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$HERE" || exit 2
FX="$HERE/tests/release_gate/fixtures/2026-10-21"
W=$(mktemp -d)
trap 'rm -rf -- "$W"' EXIT
gunzip -c "$FX/criteria.json.gz" > "$W/criteria.json"
gunzip -c "$FX/criteria.runs.jsonl.gz" > "$W/criteria.runs.jsonl"
gunzip -c "$FX/defects.json.gz" > "$W/defects.json"
mkdir -p "$W/drbd"
gunzip -c "$FX/drbd_criteria.json.gz" > "$W/drbd/criteria.json"
export MXFS_SPEC="$W/criteria.json" MXFS_CRIT="$W/criteria.json" MXFS_DEFECTS="$W/defects.json"

fails=0
check() {  # <n> <what> <command...>
    local n=$1 what=$2; shift 2
    if "$@"; then echo "PASS $n $what"; else echo "FAIL $n $what"; fails=$((fails + 1)); fi
}

alloc_witness_passes() {
    # harness-lint: ok - the board is this script's fixture copy, never a live one: what it last recorded is known
    timeout 60 python3 tools/criteria.py 16/net/mesh/direct --build 71AC6107043DD5BE3D9181A --no-colour \
        | grep -qE '^[0-9]+ +\| alloc_witness +\| PASS '
}
check 1 "16/net/mesh/direct alloc_witness reads PASS on the 0.90.132 build" alloc_witness_passes

check 2 "the capacity record's single-pass marks no longer clear 4/8/16 net/mesh" \
    timeout 60 python3 -c '
import sys; sys.path.insert(0, "tools")
import defects
entry = next(e for e in defects.load()["defects"] if e["id"].startswith("D-TCP-4NODE-NOQUEUE"))
assert entry.get("verified_at"), "the fixture should carry the 0.90.132 marks"
for config in ("4/net/mesh/direct", "8/net/mesh/direct", "16/net/mesh/direct", "4/net/mesh/mpath"):
    nodes, selector, platform = defects.parse_at(config)
    assert defects.blocks(entry, nodes, selector, platform), config + " is cleared"
'

check 3 "every run the old rig-noise rule excused, and no record names, is an incident" \
    timeout 120 python3 -c '
import re, sys; sys.path.insert(0, "tools")
import criteria
noise = re.compile(r"pre-assert|NO_TERMINAL_RECORD|run was killed|prep fail|chk tool missing|fua_verify missing", re.I)
named = criteria.named_runs()
excused = set()
for entry in criteria.read_board(criteria.SPEC)["criteria"]:
    for config, cell in (entry.get("per_config") or {}).items():
        for run in [cell] + list(cell.get("history") or []):
            reason = str(run.get("reason") or "")
            if str(run.get("status")).upper() != "FAIL" or not noise.search(reason):
                continue
            if "chk tool missing" in reason.lower() or "fua_verify missing" in reason.lower():
                continue   # positive evidence of a missing instrument: INFRA, not an incident
            key = (config, entry["id"], str(run.get("iso") or run.get("recorded") or ""))
            if named.get(key) or run.get("retired_by") or run.get("detector_defect"):
                continue
            excused.add(key)
loose = {(c, r, str(run.get("iso"))) for _, c, r, run in criteria.incidents(boards=[criteria.SPEC])}
missing = excused - loose
print("excused by the old rule:", len(excused), "now incidents:", len(excused & loose))
assert excused and not missing, sorted(missing)[:5]
'

check 4 "8 and 16/net/mesh/mpath block the release on the default install path" \
    timeout 120 python3 -c '
import json, sys; sys.path.insert(0, "tools")
import defects, release_status
rows = json.load(open("data/release_table.json"))["rows"]
queue = defects.load()["defects"]
blocked = {c for c, hits, how in release_status.default_path_problems(rows, queue, "0.90.132", "", "")}
assert {"8/net/mesh/mpath", "16/net/mesh/mpath"} <= blocked, blocked
'

check 5 "batch sizes at delta = alpha = 0.005" \
    timeout 30 python3 -c '
import sys; sys.path.insert(0, "tools")
import defects
got = [defects.laps_needed(k, n, 0.005, 0.005) for k, n in ((7, 7), (20, 20), (1, 1))]
assert got == [9, 4, 1058], got
'

drbd_ledger_skips_copies() {
    # harness-lint: ok - migrate-ledger seeds this script's fixture copy of the DRBD board; its output is this call's own
    MXFS_CRIT="$W/drbd/criteria.json" timeout 120 python3 tools/criteria.py migrate-ledger \
        | grep -qE 'copies of the primary.s runs' || return 1
    timeout 60 python3 -c '
import json, sys
w = sys.argv[1]
runs = [json.loads(l) for l in open(w + "/drbd/criteria.runs.jsonl") if l.strip()]
primary = set()
for e in json.load(open(w + "/criteria.json"))["criteria"]:
    for c, cell in (e.get("per_config") or {}).items():
        for r in [cell] + list(cell.get("history") or []):
            primary.add((c, e["id"], str(r.get("iso") or "")))
dup = [r for r in runs if r.get("kind") == "run" and (r["config"], r["row"], r["iso"]) in primary]
assert not dup, len(dup)
' "$W"
}
check 6 "the DRBD board's ledger skips the primary's copies and keeps its own column" drbd_ledger_skips_copies

gate_refuses() {
    # harness-lint: ok - the incident gate reads this script's fixture copy of the 2026-10-21 ledger, never a live one
    ! timeout 120 python3 tools/criteria.py incidents --board "$W/criteria.json" >/dev/null
}
check 7 "the incident gate exits non-zero" gate_refuses

echo "replay: $fails failed of 7"
[ "$fails" = 0 ]
