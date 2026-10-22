#!/usr/bin/env python3
"""Spend what is left of a qualification's rig budget on detection: repeat rounds.

    tools/release_plan.py --candidate <id>          the schedule, and the hours it predicts
    tools/release_plan.py --candidate <id> --json   the same, for tools/release_run.py

WHY. One run of a row per configuration catches a defect that shows one run in ten one time in
ten (Astra, 2026-10-21: 29 independent exposures catch it 95% of the time, 59 for one run in
twenty). Breadth across configurations adds nothing for a race that only one of them reaches, so
the time left after the full coverage pass goes to repeating the rows that exercise the default
install's fault and recovery paths, and the fixed-work soak. Every failure in them counts like
any other. No row here runs for a length of time somebody chose: each is a fixed workload graded
against its own budget, 2x what native XFS measured for the same work.

HOW. The budget is data/release_policy.json `qualification_budget_h`. What is already spent is
read from the candidate's own manifest (each finished step's start and end). Each repeat round is
one run.sh invocation per default-install configuration the release claims, with the policy's
`repeat_rows` that apply there, after a fresh prep; its length is predicted from the run ledger
(the median wall of that row's recent passing runs at that configuration, and of its preps).
Rounds are added while the next one still fits. A row with no recorded wall is predicted at its
own budget; a row with neither is refused, never guessed. The predicted lengths schedule work;
they never decide a verdict.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import statistics
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import configuration  # noqa: E402
import criteria       # noqa: E402

#: The sealing step's own work: the benchmark page, the text check, the incident gate and the
#: release table read every board and ledger once. Measured on dry-run candidate 0.90.133-2: 2 s
#: (2026-10-21T20:21:15Z to 20:21:17Z); reserved at twice that.
SEAL_RESERVE_S = 4


def parse_time(text: str) -> float:
    return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").timestamp()


def spent_seconds(manifest: dict) -> float:
    total = 0.0
    for state in (manifest.get("steps") or {}).values():
        if state.get("started") and state.get("ended"):
            total += max(0.0, parse_time(state["ended"]) - parse_time(state["started"]))
    return total


def wall(config: str, row: str) -> float:
    """The median wall of the row's recent passing plain runs at this configuration, or its
    budget when it has none."""
    runs = [r for r in criteria.ledger_runs(criteria.SPEC, config, row)
            if r.get("outcome") == "PASS" and not r.get("variant") and r.get("elapsed_s")]
    if runs:
        return float(statistics.median(int(r["elapsed_s"]) for r in runs[:9]))
    spec = next((e for e in criteria.spec_rows() if e.get("id") == row), {})
    budget = criteria.budget_of(spec)
    if not budget:
        sys.exit(f"release_plan: {row} at {config} has no recorded wall and no budget; it cannot "
                 f"be scheduled until it has one measured")
    return float(budget)


def default_configs() -> list:
    """The default-install configurations this release claims and grades by a board."""
    pattern = criteria.policy().get("default_install", {}).get("pattern", "net/mesh/*")
    table = json.loads((ROOT / "data" / "release_table.json").read_text())
    earlier = json.loads((ROOT / "data" / "configurations.json").read_text()).get(
        "released_earlier", {})
    found = []
    for row in table["rows"]:
        for board in row.get("boards") or []:
            config = board["config"]
            if config in earlier or config in found:
                continue
            if configuration.matches(pattern, configuration.parse(config)):
                found.append(config)
    return found


def repeat_rows(config: str) -> list:
    patterns = criteria.policy().get("repeat_rows") or []
    rows = []
    for spec in criteria.spec_rows():
        rid = spec.get("id", "")
        if any(fnmatch.fnmatch(rid, p) for p in patterns) and criteria.applies(spec, config):
            rows.append(rid)
    return rows


def schedule(candidate: str) -> dict:
    rules = criteria.policy()
    manifest = json.loads((ROOT / "data" / "candidates" / f"{candidate}.json").read_text())
    budget = float(rules.get("qualification_budget_h", 12)) * 3600
    spent = spent_seconds(manifest)
    left = budget - spent - SEAL_RESERVE_S
    runs, predicted, rounds = [], 0.0, 0
    while True:
        this_round, length = [], 0.0
        for config in default_configs():
            rows = repeat_rows(config)
            if not rows:
                continue
            cost = wall(config, "prep_cluster") + sum(wall(config, r) for r in rows)
            this_round.append({"config": config, "rows": rows, "prep": True,
                               "predicted_s": round(cost)})
            length += cost
        if not this_round or length > left:
            break
        runs += this_round
        rounds += 1
        left -= length
        predicted += length
    return {"candidate": candidate, "budget_h": budget / 3600, "spent_h": spent / 3600,
            "rounds": rounds, "runs": runs, "hours": predicted / 3600}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    plan = schedule(args.candidate)
    if args.json:
        print(json.dumps(plan, indent=2))
        return 0
    print(f"candidate {plan['candidate']}: budget {plan['budget_h']:.1f} h, spent "
          f"{plan['spent_h']:.1f} h, {plan['rounds']} repeat round(s): "
          f"{plan['hours']:.1f} h predicted")
    for item in plan["runs"]:
        print(f"  {item['config']:20} {item['predicted_s']:6d}s  {' '.join(item['rows'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
