---
name: compiled-tree-ownership-and-release-tooling-traps
description: Assorted traps: root-owned 0600 tree files from mktemp+mv, label/bound args for self-test harnesses, stale criteria ledger cache in long-lived proces…
metadata:
  type: feedback
tags: [compiled, tree-ownership, release-tooling, harness, criteria]
---

Assorted group (the clusterer could not fit these to one topic): three unrelated release/harness traps, each with its cause and what to do.

## 1. Tree files are root-owned by design; mktemp writers make them 0600  `trap-node-written-tree-files-are-root-0600-via-mktemp-mv`

**The layout (owner, 2026-10-21):**
- `/src` normally mounts from the QNAP, `192.168.1.4:/src`. Its export maps to root (`anon=root`), so every file in the tree there is root-owned.
- While clyde is away from the QNAP, the tree lives in `/home/steve/src` (copied there with root ownership kept). It is bind-mounted at `/src` (`/etc/fstab`) and exported to the rig with `no_root_squash`, so node writes still land root-owned.
- Once clyde is back onsite, `/src` mounts from `192.168.1.4:/src` again.
- The owner said leave it: do not change the export, do not chown the tree. Root-owned files in the tree are the normal state, not damage to repair.
- A session guessed at causes before the owner explained. Check `findmnt /src` and `/etc/exports` before guessing.

**What bit (twice, the same day):**
- `tools/release_candidate.py create` crashed with `PermissionError` on `.xfs_fio_baseline.*.json` (seven yardsticks, root-owned, mode 0600). The freeze hashes every yardstick.
- The orchestrator's clean-build `rsync -a` of the tree failed with code 23 on `bench.json`, root-owned 0600.

**Why 0600:** writers that do `mktemp` + write + `mv` into the tree (`tests/suite/fio_perf.sh` for the baseline and `bench.json`, `tests/tooling/fio_vs_xfs_baseline.sh` for `bench.json`). `mktemp` always creates 0600 whatever the umask, and `mv`/`cp` keep it. Root-owned plus 0600 is readable by root only. Ordinary writes come out 0644 and stay readable.

**How to apply:**
- Any harness writing into the tree with `mktemp`+`mv` must `chmod 0644` before the `mv`.
- Host tools must work on root-owned files they can read, and never assume they own the tree. One that must read every file (the candidate freeze) refuses and names any unreadable file.
- `findmnt /src` must show the bind (`/dev/nvme0n1p2[/home/steve/src]`) until the move is done, and the QNAP mount after it. The old `192.168.1.8:/src` fstab line was commented out on 2026-10-21 so it cannot stack over the bind.

**Fixed so far:** `fio_perf.sh` chmods the baseline 0644; seven yardsticks and `bench.json` were made 0644; `release_candidate.py create` refuses with a list of unreadable frozen files. Still open: the two `bench.json` writers (`fio_perf.sh:196`, `fio_vs_xfs_baseline.sh:101`).

## 2. Self-test harnesses need a label and their caller's bound  `trap-self-test-harnesses-need-a-label-and-their-caller-bound`

**What bit:** `tools/release_run.py`'s presteps called `tests/capture_fault_gate.sh` (and the other two) with no arguments. All three start `LABEL=${1:?label}`, so they exit at once and the step fails on every candidate.

**Facts, from the scripts' own headers:**
- `tests/chk_oracle_calibration.sh <label>`: host-local (loop device, no rig). Header derives ~50 s, **caller bound 150 s**.
- `tests/rig_lib_contract.sh <label> [node=test1]`: needs test1 up with a mounted 2-node cluster (it unmounts the peer behind a live node). Header derives ~150 s, **bound 300 s**. Exit 0 PASS, 1 FAIL, 2 INFRA.
- `tests/capture_fault_gate.sh <label> [--healthy|--healthy-only] [--only h]`: 60 manifest entries (`tests/capture_gate.manifest`), each harness run with `MXFS_FAULT_RSX_NTH=1`; it bounds each lap itself from the manifest (fault laps sum to 17030 s worst case). Harnesses default to test1,test2 at 2/net/mesh/direct; 9 entries set NOPREP=1 and reuse the live mount, 45 prep it themselves. Verdict line `RESULT: PASS|FAIL label=<label> entries=...`.

**How to apply:** pass a label; wrap the first two in `timeout` with their header's bound (the "never wrap" rule is for run.sh, which bounds its own rows); power and form g2 (test1,test2) on the module under test before the contract and the gate; read the gate's verdict from its RESULT line, not only its rc.

## 3. criteria ledger cache goes stale in a long-lived process  `trap-criteria-ledger-cache-goes-stale-in-a-long-lived-process`

**The trap:** `tools/criteria.py` `read_ledger()` caches each board's run ledger per process (`ledger_cache`), and only `append_ledger()` in the SAME process invalidates it. A process that imports criteria/defects and then runs `./run.sh` laps as children (`tools/release_run.py`'s batch step did this) reads the ledger as it was before the laps: a failed lap is missed, counts are stale, and a FAIL never ends the batch.

**Fixed (0.90.133):** `Run.sh()` in `tools/release_run.py` calls `criteria.ledger_cache.clear()` after every child command.

**How to apply:** any new Python that imports `criteria` (or `defects`, which reads through it) and lives across subprocesses that record runs must clear `criteria.ledger_cache` after each child before reading verdicts. Short CLI invocations are unaffected.
