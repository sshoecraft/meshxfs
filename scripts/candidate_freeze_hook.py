#!/usr/bin/env python3
"""PreToolUse hook: refuse an edit to a file a release candidate has frozen.

While a candidate is being qualified (data/candidates/active.json, state RUNNING), every source,
tool, test, script and policy file it froze must stay as it was: the orchestrator re-checks them
before every step and marks the candidate INVALID on any change, after hours of rig time. This
refuses the edit before it lands. It sees only the Edit, Write and NotebookEdit tools; a change
made another way is caught by the orchestrator's own check (tools/release_candidate.py drift).

Exit 0 lets the edit through; exit 2 refuses it, with the reason on stderr. When it cannot tell
-- unreadable input, an unreadable manifest -- it refuses: an edit it lets through by mistake
costs a qualification, one it refuses by mistake costs a retry.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except ValueError:
        print("candidate_freeze_hook: unreadable hook input; refusing", file=sys.stderr)
        return 2
    tool_input = event.get("tool_input") or {}
    target = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
    if not target:
        return 0
    try:
        active = json.loads((ROOT / "data" / "candidates" / "active.json").read_text())
    except FileNotFoundError:
        return 0
    except ValueError:
        print("candidate_freeze_hook: data/candidates/active.json is unreadable; refusing",
              file=sys.stderr)
        return 2
    if active.get("state") != "RUNNING":
        return 0
    sys.path.insert(0, str(ROOT / "tools"))
    try:
        import release_candidate
        manifest = release_candidate.load(active["candidate"])
        files = json.loads((ROOT / manifest["files"]).read_text())
    except (SystemExit, Exception) as exc:  # noqa: BLE001 -- any failure to decide refuses
        print(f"candidate_freeze_hook: cannot read candidate {active.get('candidate')}: {exc}; "
              f"refusing", file=sys.stderr)
        return 2
    path = Path(target).resolve()
    try:
        rel = str(path.relative_to(ROOT))
    except ValueError:
        rel = str(path)
    # would_freeze: a file not there yet that a frozen directory would hold is frozen too, since
    # adding it is drift
    if rel in files or rel == "data/criteria.json" or \
            (rel.startswith("data/") and not release_candidate.mutable(rel)) or \
            release_candidate.would_freeze(rel):
        print(f"candidate {active['candidate']} is being qualified and has frozen {rel}: an edit "
              f"now would make it INVALID. Wait for it to end, or abandon it "
              f"(tools/release_candidate.py abandon {active['candidate']} --why ...).",
              file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
