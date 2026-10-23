---
name: compiled-release-candidate-freeze-drift-and-budget-spec
description: Frozen-candidate drift, budget_s in 2 places, root-0600 tree files, harness label/bound, stale ledger cache; fence netconsole, no node creds
metadata:
  type: feedback
tags: [compiled, release-candidate, drift, freeze, budget, criteria, manifest, trap, tree-ownership, release-tooling, harness, fencing, netconsole, vcenter, credentials]
---

Release-tooling and rig-harness traps, grouped by what they break. Sections 1-2: what makes a frozen release candidate (`tools/release_candidate.py`) INVALID or mis-grades it. Sections 3-5: release/harness tooling that crashes or silently misreads (root-owned 0600 tree files, self-test harnesses run without a label, a stale criteria ledger cache). Sections 6-7: two fencing lessons, a loose fit here (a line lost before a node resets itself; no hypervisor credentials on cluster nodes). Merged from `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget` and `compiled-tree-ownership-and-release-tooling-traps` (which itself folded `compiled-fence-test-capture-and-fence-credential-rules`).

## 1. Adding a file is drift, not only editing one

- `drift()` reports `added: <path>` for any file that joined the frozen set after the freeze. `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget`
- The frozen set is every file under `xfs/ dlm/ pal/ mxfs_clayer/ include/ compat/ tests/ tools/ scripts/ packaging/ frontend/proxmox/ docs/man/`, minus the MUTABLE patterns (`tests/evidence/*`, `*.o`, `__pycache__`, ...), plus `data/` except `criteria.json`, `*.runs.jsonl`, `defects.json`, `proposals.json`, `candidates/`, `reviews/`. `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget`
- Consequence: while a candidate is RUNNING, a new helper script or lap in `tests/` or `tools/` makes it INVALID. `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget`
- Do: write one-off helpers inline (a heredoc in the Bash call) or under `tests/evidence/`; put new laps and tools in the tree only before the freeze. `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget`
- `docs/` (except `docs/man`) is not frozen, so design docs can be written during a run. `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget`

## 2. A board row's budget lives in two places

- `run.sh` enforces the BUDGET_S column of `tests/suite/manifest`. `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget`
- The board's own spec, `budget_s` in `data/criteria.json` (`tools/criteria.py` `budget_of`), is what a lap line prints (`(33s/60s)`) and what grades; it is part of the candidate's frozen spec projection. (`criteria.json` is excluded from the frozen file set in section 1, yet the `budget_s` spec is frozen through the spec projection.) `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget`
- Failure seen: session 19 (run 9aa0fe9b) changed fourkn_merge's manifest budget 60 -> 55 and froze; the laps still showed 60. `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget`
- Do: change both together, before freezing, and check a lap's printed budget. `trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget`

## 3. Tree files are root-owned by design; mktemp writers make them 0600

Source: `trap-node-written-tree-files-are-root-0600-via-mktemp-mv`, via `compiled-tree-ownership-and-release-tooling-traps`.

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

## 4. Self-test harnesses need a label and their caller's bound

Source: `trap-self-test-harnesses-need-a-label-and-their-caller-bound`, via `compiled-tree-ownership-and-release-tooling-traps`.

**What bit:** `tools/release_run.py`'s presteps called `tests/capture_fault_gate.sh` (and the other two) with no arguments. All three start `LABEL=${1:?label}`, so they exit at once and the step fails on every candidate.

**Facts, from the scripts' own headers:**
- `tests/chk_oracle_calibration.sh <label>`: host-local (loop device, no rig). Header derives ~50 s, **caller bound 150 s**.
- `tests/rig_lib_contract.sh <label> [node=test1]`: needs test1 up with a mounted 2-node cluster (it unmounts the peer behind a live node). Header derives ~150 s, **bound 300 s**. Exit 0 PASS, 1 FAIL, 2 INFRA.
- `tests/capture_fault_gate.sh <label> [--healthy|--healthy-only] [--only h]`: 60 manifest entries (`tests/capture_gate.manifest`), each harness run with `MXFS_FAULT_RSX_NTH=1`; it bounds each lap itself from the manifest (fault laps sum to 17030 s worst case). Harnesses default to test1,test2 at 2/net/mesh/direct; 9 entries set NOPREP=1 and reuse the live mount, 45 prep it themselves. Verdict line `RESULT: PASS|FAIL label=<label> entries=...`.

**How to apply:** pass a label; wrap the first two in `timeout` with their header's bound (the "never wrap" rule is for run.sh, which bounds its own rows); power and form g2 (test1,test2) on the module under test before the contract and the gate; read the gate's verdict from its RESULT line, not only its rc.

## 5. criteria ledger cache goes stale in a long-lived process

Source: `trap-criteria-ledger-cache-goes-stale-in-a-long-lived-process`, via `compiled-tree-ownership-and-release-tooling-traps`.

**The trap:** `tools/criteria.py` `read_ledger()` caches each board's run ledger per process (`ledger_cache`), and only `append_ledger()` in the SAME process invalidates it. A process that imports criteria/defects and then runs `./run.sh` laps as children (`tools/release_run.py`'s batch step did this) reads the ledger as it was before the laps: a failed lap is missed, counts are stale, and a FAIL never ends the batch.

**Fixed (0.90.133):** `Run.sh()` in `tools/release_run.py` calls `criteria.ledger_cache.clear()` after every child command.

**How to apply:** any new Python that imports `criteria` (or `defects`, which reads through it) and lives across subprocesses that record runs must clear `criteria.ledger_cache` after each child before reading verdicts. Short CLI invocations are unaffected.

## 6. Capture: ssh kmsg stream loses the line before emergency_restart()

Source: `trap-ssh-kmsg-stream-loses-the-line-before-an-emergency-restart-use-clydes-netconsole`, via `compiled-fence-test-capture-and-fence-credential-rules` (two fencing lessons, one about test evidence capture, one about fence design; this is the capture one; the design one is section 7) and `compiled-tree-ownership-and-release-tooling-traps`.

- Observed in the fence=quorum split tests (vstest2): the module prints `P-QUORUM-LOST-RESET` and calls `emergency_restart()` in the same breath. One run's `tools/node_kmsg_stream.sh` capture (ssh `cat /dev/kmsg`) had the line, the next run's did not: the remote `cat` and sshd never get scheduled before the reset. A check reading only the stream reported FAIL on a reset that happened.
- How to apply: for any line a node prints right before resetting itself (self-fence, panic, quorum loss), load netconsole on the node (`modprobe netconsole netconsole=@/eth0,6666@192.168.120.1/`) - it transmits from inside printk.
- clyde already runs a listener (`tools/netconsole_listen.sh status`: socat on 6666, log `tests/evidence/netconsole.log`). It is the rig's: do not start/stop it from a test; record the log's byte size before and read only what is appended (`tail -c +N`). `tests/vsphere_shared_fence.sh` `split` does exactly this.

## 7. Design: no fence may put hypervisor credentials on cluster nodes

Source: `feedback-no-fence-design-may-store-hypervisor-credentials-on-cluster-nodes`, via `compiled-fence-test-capture-and-fence-credential-rules` (the fence-design lesson) and `compiled-tree-ownership-and-release-tooling-traps`.

- User rejected fence=vcenter outright. The 0.90.128 `fence=vcenter` design (docs/shared-disk-attachment.md, "Method: vcenter"; tools/mxfs_fence_vcenter.py) keeps `/etc/mxfs/vcenter.conf` + a 0600 `password_file=` on EVERY node, for an account that can power VMs off. User, 2026-10-13: "a clear text password to the entire vSphere environment with administrative access. You're insane." Scoping the vCenter role does not answer it; mode 0600 does not answer it.
- Why: any one compromised or misconfigured guest then holds the power to power off arbitrary VMs in the customer's vSphere. No storage admin will deploy a filesystem that requires that, and a session marked "working on vSphere" done on top of it.
- How to apply: a fence for a hypervisor-attached shared disk must not depend on credentials living inside the guests. Credential-free mechanisms to evaluate first: storage-side fencing reachable from the guest (in-guest iSCSI + SCSI PR), operator confirmation (`fence=manual`), guest self-fencing with the VMware virtual watchdog (vWDT, HW version 17+, `wdat_wdt`) plus a disk-based lease, SBD-style. Raise any design that needs a management-plane credential with the user BEFORE building it.
