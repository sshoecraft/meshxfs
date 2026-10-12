#!/bin/bash
# pve_fairness_knob_ab.sh — interleaved A/B of one mxfs module parameter on a
# PVE pair, graded by tests/pve_churn_fairness.sh.
#
# Run to run, the nested pair's I/O latency moves by about three times (the
# host under it is shared), and the shared-directory churn's fairness moves
# with it, so two settings are compared by alternating them run by run rather
# than in two blocks.  Before each run the parameter is written on both hosts
# and read back; a host that does not hold the value stops the A/B.
#
# Usage: tests/pve_fairness_knob_ab.sh <param> <value A> <value B> [pairs]
#   pairs  how many A,B pairs (default 3)
# Env: PVE_PAIR (default the nested pair "192.168.120.137 192.168.120.192"),
#      CHURN, WORK_S, PROBES — passed to the fairness run.
# Leaves the parameter at <value B> (the last run's) and says so.
# Output: one line per run (value, iterations, ratio, verdict, evidence) and
# the per-value summary; the whole of each run in $OUT/<n>.out.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSHP="$REPO/tools/mxfs_sshpass.sh"
P=${1:?usage: pve_fairness_knob_ab.sh <param> <value A> <value B> [pairs]}
VA=${2:?value A}
VB=${3:?value B}
PAIRS=${4:-3}
PAIR_S=${PVE_PAIR:-192.168.120.137 192.168.120.192}
read -r -a PAIR <<<"$PAIR_S"
OUT=$REPO/tests/evidence/pve_fairness_knob_ab/$(date -u +%Y%m%dT%H%M%SZ)-$P
mkdir -p "$OUT" || exit 1
on() {
    timeout "${3:-20}" "$SSHP" "$1" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$'
    return "${PIPESTATUS[0]}"
}
set_knob() {  # <value>: write it on both hosts and read it back
    local h got
    for h in "${PAIR[@]}"; do
        got=$(on "$h" "echo $1 > /sys/module/mxfs/parameters/$P && cat /sys/module/mxfs/parameters/$P")
        [ "$got" = "$1" ] || { echo "ABORT: $h holds $P=${got:-?} after writing $1"; return 1; }
    done
}
n=0
for i in $(seq 1 "$PAIRS"); do
    for v in "$VA" "$VB"; do
        n=$((n + 1))
        set_knob "$v" || exit 1
        # the fairness run's own budget: arm 20 s + work 40 s + collection;
        # the slowest healthy run measured end to end took 90 s, twice that
        env PVE_PAIR="$PAIR_S" timeout 180 "$REPO/tests/pve_churn_fairness.sh" > "$OUT/$n.out" 2>&1
        rc=$?
        it=$(grep -a '^iterations' "$OUT/$n.out" | tail -1)
        err=$(grep -ac 'FAIL: loop error .*: [a-z]* [0-9]*$' "$OUT/$n.out")
        ev=$(grep -ao "$REPO/tests/evidence/pve_churn_fairness/[^ ]*" "$OUT/$n.out" | tail -1)
        # a loop that died on an error stops early; the per-loop rate of the
        # loops that ran to the end is the pace comparison it leaves standing
        alive=$(python3 -I - "$OUT/$n.out" <<'PY'
import re, sys
txt = open(sys.argv[1], errors="replace").read()
dead = {(h, k) for h, k in re.findall(r"FAIL: loop error (\S+) loop (\d+): [a-z]+ \d+$", txt, re.M)}
rate = {}
for h, loops in re.findall(r"^(\S+): iterations \d+ \(([^)]*)\)", txt, re.M):
    ok = [int(c) for k, c in re.findall(r"loop (\d+) (\d+)", loops) if (h, k) not in dead]
    rate[h] = sum(ok) / len(ok) if ok else 0.0
if len(rate) == 2:
    a, b = rate.values()
    print(f"per_live_loop {' '.join(f'{h}={r:.0f}' for h, r in rate.items())} ratio={min(a, b) / max(a, b) if max(a, b) else 0:.2f}")
PY
)
        echo "run $n $P=$v rc=$rc loop_errors=$err ${it:-no result} ${alive:-} evidence=${ev:-none}" | tee -a "$OUT/summary"
    done
done
echo "$P left at $VB on both hosts" | tee -a "$OUT/summary"
python3 -I - "$OUT/summary" "$P" <<'PY'
import re, sys
rows = {}
for line in open(sys.argv[1]):
    m = re.search(r"%s=(\S+) rc=(\d+) loop_errors=(\d+) .*made ([0-9.]+) of" % re.escape(sys.argv[2]), line)
    if m:
        live = re.search(r"per_live_loop .* ratio=([0-9.]+)", line)
        rows.setdefault(m.group(1), []).append((float(m.group(4)), int(m.group(2)), int(m.group(3)),
                                                float(live.group(1)) if live else None))
for v, rs in rows.items():
    ratios = sorted(r for r, _, _, _ in rs)
    live = sorted(l for _, _, _, l in rs if l is not None)
    print(f"{sys.argv[2]}={v}: ratios {ratios}, per-live-loop ratios {live}, "
          f"passes {sum(1 for _, rc, _, _ in rs if rc == 0)}/{len(rs)}, "
          f"runs with a loop error {sum(1 for _, _, e, _ in rs if e)}")
PY
