#!/usr/bin/env python3
"""proposal_precheck.py -- what a verify or removal proposal for a record will be reviewed on.

Applying a verify retires every run the record names at the batch's configuration, and a removal
retires every run it names anywhere, so the release-reviewer reads each of those runs.  A review
costs about as much rejected as approved, so this lists, before proposing:

  - the verification batch: its state, row, configuration, candidate, and the closed control
    batch of the same record, row and configuration it is sized from;
  - every run (cell) the record names, from the run ledgers, grouped by configuration, row,
    outcome and the batch it ran under, with each group's reason text as recorded, so a cell of
    another cause shows up as its own group;
  - whether the record has a reproducer (a removal refuses without one) and its summary, which a
    removal publishes in CHANGELOG.md as written.

It reads data/defects.json and data/*.runs.jsonl of the tree it is run from (the working
directory), and writes nothing.

Usage: tools/proposal_precheck.py <record id> [<verify batch id>]
"""
import collections
import glob
import json
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__.strip().splitlines()[-1])
        return 2
    rid = sys.argv[1]
    batch_id = sys.argv[2] if len(sys.argv) > 2 else None
    records = {e["id"]: e for e in json.load(open("data/defects.json"))["defects"]}
    if rid not in records:
        print("precheck: no record %s in data/defects.json" % rid)
        return 2
    rec = records[rid]
    runs = {}
    # an attachment verified by a rig of its own keeps its board, and that board's run ledger,
    # where data/configurations.json names it (the DRBD rig's laps are only there)
    ledgers = sorted(glob.glob("data/*.runs.jsonl"))
    for attach in json.load(open("data/configurations.json")).get("attaches", {}).values():
        if attach.get("board"):
            ledgers.append(attach["board"][:-len(".json")] + ".runs.jsonl")
    for path in ledgers:
        if not glob.glob(path):
            continue
        for line in open(path):
            try:
                run = json.loads(line)
            except ValueError:
                continue
            # a note (a retirement, an annotation) carries its run's key too: keep the run
            if run.get("kind") == "note":
                continue
            runs[(run.get("config"), run.get("row"), run.get("iso"))] = run

    print("record     %s (%s, nodes %s, config %s)" % (rid, rec.get("severity"), rec.get("nodes"),
                                                         rec.get("config")))
    print("reproducer %s" % (rec.get("reproducer") or "NONE: remove --fixed refuses"))
    print("summary    %s" % rec.get("summary"))
    batches = rec.get("batches", [])
    if batch_id:
        found = [b for b in batches if b["id"] == batch_id]
        if not found:
            print("precheck: %s is not a batch of this record" % batch_id)
            return 2
        bat = found[0]
        print("batch      %s %s %s state=%s row=%s at %s candidate=%s planned=%s" % (
            bat["id"], bat["kind"], bat.get("variant") or "", bat.get("state"), bat.get("row"),
            bat.get("config"), bat.get("candidate") or "-", bat.get("planned")))
        controls = [b for b in batches if b["kind"] == "control" and b.get("state") == "closed"
                    and b.get("config") == bat.get("config") and b.get("row") == bat.get("row")]
        for ctl in controls:
            print("control    %s k/n=%s/%s build=%s variant=%s" % (
                ctl["id"], ctl.get("k"), ctl.get("n"), ctl.get("build"), ctl.get("variant")))
        if not controls:
            print("control    NONE closed at that configuration and row")
    groups = collections.OrderedDict()
    missing = []
    for cell in rec.get("cells", []):
        key = (cell.get("config"), cell.get("row"), cell.get("iso"))
        run = runs.get(key)
        if run is None:
            missing.append(":".join(str(k) for k in key))
            continue
        gkey = (key[0], key[1], run.get("outcome"), run.get("batch") or "-")
        groups.setdefault(gkey, []).append(run)
    print("cells      %d named, %d not in any run ledger" % (len(rec.get("cells", [])), len(missing)))
    for (config, row, outcome, batch), group in groups.items():
        reasons = collections.Counter(str(r.get("reason") or "")[:160] for r in group)
        print("  %-22s %-34s %-8s batch=%-17s %3d run(s)" % (config, row, outcome, batch, len(group)))
        for reason, count in reasons.most_common(3):
            print("      %3dx %s" % (count, reason))
        if len(reasons) > 3:
            print("      ... %d other reason texts" % (len(reasons) - 3))
    for key in missing:
        print("  not in a ledger: %s" % key)
    return 0


if __name__ == "__main__":
    sys.exit(main())
