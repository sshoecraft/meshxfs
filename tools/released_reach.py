#!/usr/bin/env python3
"""Which open defects reach a configuration that ships, in severity order.

    tools/released_reach.py            every open record that reaches one, one line each
    tools/released_reach.py -v         and the shipped configurations each one reaches
    tools/released_reach.py --latest   and each one's summary and the newest segment of its
                                       next step (the text after its last '=====')
    tools/released_reach.py --gate     exit 1 if any record reaches one, 0 if none does

A shipped configuration is a row of data/release_table.json (each row is a configuration a
release ships, on the platform it names) or one of the `platform_rounds` configurations on a
platform data/platforms.json marks `released`.  A record reaches one when `tools/defects.py
--at <config>@<platform>` would list it: the same `defects.blocks` test, applied to every
shipped configuration at once, so the answer cannot drift from the queue tool's own.

Each line says whether the record blocks those releases (its bar is anything but `noblock`,
and an unadjudicated bar blocks) or only reaches them.  Both kinds are still broken; the bar
decides which releases wait on a record, never whether it is work.

Read-only: it loads the queue and writes nothing.
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import defects  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]


def shipped() -> list:
    """Every shipped configuration as `<config>@<platform>`, in table order, no repeats."""
    table = json.loads((ROOT / "data" / "release_table.json").read_text())
    registry = json.loads((ROOT / "data" / "platforms.json").read_text())
    platforms = registry.get("platforms", registry)
    out = []
    for row in table["rows"]:
        for config in row.get("configs", []):
            out.append("%s@%s" % (config, row["platform"]) if row.get("platform") else config)
    rounds = table.get("platform_rounds", {}).get("configs", [])
    for name, info in platforms.items():
        if isinstance(info, dict) and info.get("status") == "released":
            out.extend("%s@%s" % (config, name) for config in rounds)
    return list(dict.fromkeys(out))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="list the shipped configurations each record reaches")
    ap.add_argument("--latest", action="store_true",
                    help="print each record's summary and the newest segment of its next step")
    ap.add_argument("--gate", action="store_true",
                    help="exit 1 if any record reaches a shipped configuration")
    args = ap.parse_args()

    configs = shipped()
    gates = [(text,) + defects.parse_at(text) for text in configs]
    entries = sorted(defects.load()["defects"], key=defects.rank)
    reached = []
    for entry in entries:
        hits = [text for text, nodes, selector, platform in gates
                if defects.blocks(entry, nodes, selector, platform)]
        if hits:
            reached.append((entry, hits))

    blocking = [e for e, _ in reached if e.get("impact") not in defects.IMPACT_CLEAR]
    print("shipped configurations: %d   open records: %d   reaching one: %d "
          "(%d block a release, %d noblock)"
          % (len(configs), len(entries), len(reached), len(blocking),
             len(reached) - len(blocking)))
    for entry, hits in reached:
        bar = entry.get("impact") or "unadjudicated"
        nodes, pattern = defects.reach(entry)
        print("%-8s %-13s n=%-2d %-16s %-10s [%2d] %s"
              % (entry.get("severity", "?"), bar, nodes, pattern, defects.platform_of(entry),
                 len(hits), entry.get("id")))
        if args.verbose:
            print("         reaches: " + " ".join(hits))
        if args.latest:
            #: a record's history is appended as segments separated by '=====': the last
            #: non-empty one is where the investigation stands
            segments = [s.strip() for s in str(entry.get("next") or "").split("=====")]
            newest = ([s for s in segments if s] or [""])[-1]
            pad = " " * 9
            print(pad + defects.wrap("summary: " + defects.flat(entry.get("summary", ""), 10 ** 6),
                                     100, pad))
            print(pad + defects.wrap("latest: " + newest, 100, pad))
    if args.gate and reached:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
