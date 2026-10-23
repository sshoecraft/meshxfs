---
name: compiled-sibling-prep-mkfs-and-register-word-decoding
description: Assorted rig/release-gate traps: verify-before-refreeze, drift, root-0600 tree, stale SG_IO tools, SATA 870, fencing, sibling mkfs, crash register de…
metadata:
  type: feedback
tags: [compiled, defects-py, verify, release-gate, drift, budget, tree-ownership, harness, sg-io, sata-870, fencing, netconsole, vcenter, run-sh, mkfs, sibling-checkout, crash-forensics, register-decode, clyde, trap]
---

Assorted group (no single topic; the clusterer could not fit these to one). Common thread: gate, rig or crash evidence looks valid while bound to the wrong attempt, tree, binary, disk, capture path, mkfs or writer. Merged from the original two-note article (sibling-checkout mkfs, register-word decoding; both found session 36) and `compiled-defects-verify-before-refreeze` (`compiled-defects-verify-before-refreeze`, itself merged from `compiled-release-candidate-freeze-drift-and-budget-spec` and `compiled-release-gate-and-rig-evidence-traps`).

# A. Verify order, attempts and removals

Source: [[trap-apply-a-verify-before-refreezing-or-its-laps-stop-counting]].

## Rule: apply a passed verify while its attempt is current

- A passed verification batch must be applied (`tools/defects.py verify <id> --batch <b> --approval <P>`) while the attempt its laps ran on is still the candidate's current attempt.

## Why a re-freeze voids it

- `unplanned_variant()` in tools/defects.py (the lines under "a candidate is its version: a lap from before its current attempt was frozen ran another tree") drops every lap whose `iso` is earlier than `criteria.attempt_began(candidate)`.
- A new `release_candidate.py create` moves `attempt_began` forward. A verify batch that passed on the old attempt then has zero countable laps and can never be applied; its rig time is lost.
- `verified_at` also carries the attempt, so an applied verify stops clearing anything once the attempt changes.

## What survives a re-freeze: a removal

- `cmd_remove` checks only that the control is closed with k>=1 and the fix-on batch is `passed` and sized from that control. It does not check the attempt.
- Order before retiring an attempt: (1) apply every passed verify that a removal needs, (2) abandon/re-freeze, (3) propose the removals. Learned in the session of 2026-10-23, the 4K merged-write record.

## Source and tool changes

- A source or tool change needs the attempt retired first (every frozen file is checked for drift). Batch the next attempt's changes and convert verifies to removals promptly; a verify left unremoved is redone on the next attempt.

# B. Verification batches need a frozen candidate

Source: [[trap-verification-batches-count-only-on-a-frozen-candidate-controls-may-run-before]] (via `compiled-release-gate-and-rig-evidence-traps`). The release-reviewer rejected proposal P20261022-c75127 (verify of D-PACKAGE-INPUT-LIST-NAMES-ABSENT-MXFS-C-NO-PACKAGE-CAN-BE-BUILT, batch b20261022-1666e5, 4 of 4 exposed PASS laps). The batch was declared with `plan-verify --build <srcversion>` and no `--candidate`, and its laps carried no `MXFS_CANDIDATE`. Review: `data/reviews/P20261022-c75127.md`.

Why it is wrong:
- A verification batch stops a record blocking a configuration *on a candidate* (`docs/release-process.md`, "What a verification clears"). With no candidate it counts for none, and in the development view it would count on any tree with that module, including one with the fix reverted.
- The module srcversion names only the kernel module. A fix in a script or tool (here `scripts/vm_package_build.sh`) leaves it unchanged, so the control (fix out) and the verify (fix in) ran on the same "build".

The reviewer judged the control batch itself sound: k=20 of 20 with the fix reverted by a hashed diff, on the dev tree, no candidate. So:
- Write every fix and run its control batch on the development tree.
- Freeze the candidate (`tools/release_candidate.py create`) only when every fix is in: any later change makes it INVALID.
- Declare each verification batch with `plan-verify --control <batch> --candidate <version>`; run its laps with `MXFS_CANDIDATE` set, after the freeze. The `batches` step of `tools/release_run.py` runs the open verification batches declared for the candidate.
- A verify clears one configuration only. A record that reaches `*/*/*` keeps blocking every other configuration until it is removed (`remove --fixed` needs that passed verify batch).

The same review also noted:
- A lap bound that is the sum of a script's per-step timeouts is not derived from what the lap takes.
- A record's `--reproducer` must name a command that exists: `run.sh` has no `lap:` rows; such laps run through `tools/harness_batch.py` / `tools/batch_lap.py`.

# C. Frozen-candidate drift and budget spec

Source: [[trap-a-running-candidate-freezes-new-files-and-the-board-spec-budget]] (via `compiled-release-candidate-freeze-drift-and-budget-spec`).

## Adding a file is drift, not only editing one

- `drift()` reports `added: <path>` for any file that joined the frozen set after the freeze.
- The frozen set is every file under `xfs/ dlm/ pal/ mxfs_clayer/ include/ compat/ tests/ tools/ scripts/ packaging/ frontend/proxmox/ docs/man/`, minus the MUTABLE patterns (`tests/evidence/*`, `*.o`, `__pycache__`, ...), plus `data/` except `criteria.json`, `*.runs.jsonl`, `defects.json`, `proposals.json`, `candidates/`, `reviews/`.
- Consequence: while a candidate is RUNNING, a new helper script or lap in `tests/` or `tools/` makes it INVALID.
- Do: write one-off helpers inline (a heredoc in the Bash call) or under `tests/evidence/`; put new laps and tools in the tree only before the freeze.
- `docs/` (except `docs/man`) is not frozen, so design docs can be written during a run.

## A board row's budget lives in two places

- `run.sh` enforces the BUDGET_S column of `tests/suite/manifest`.
- The board's own spec, `budget_s` in `data/criteria.json` (`tools/criteria.py` `budget_of`), is what a lap line prints (`(33s/60s)`) and what grades; it is part of the candidate's frozen spec projection. (`criteria.json` is excluded from the frozen file set above, yet the `budget_s` spec is frozen through the spec projection.)
- Failure seen: session 19 (run 9aa0fe9b) changed fourkn_merge's manifest budget 60 -> 55 and froze; the laps still showed 60.
- Do: change both together, before freezing, and check a lap's printed budget.

# D. Tree ownership and release/harness tooling

## Tree files are root-owned by design; mktemp writers make them 0600

Source: [[trap-node-written-tree-files-are-root-0600-via-mktemp-mv]], via `compiled-tree-ownership-and-release-tooling-traps`.

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

## Self-test harnesses need a label and their caller's bound

Source: [[trap-self-test-harnesses-need-a-label-and-their-caller-bound]], via `compiled-tree-ownership-and-release-tooling-traps`.

**What bit:** `tools/release_run.py`'s presteps called `tests/capture_fault_gate.sh` (and the other two) with no arguments. All three start `LABEL=${1:?label}`, so they exit at once and the step fails on every candidate.

**Facts, from the scripts' own headers:**
- `tests/chk_oracle_calibration.sh <label>`: host-local (loop device, no rig). Header derives ~50 s, **caller bound 150 s**.
- `tests/rig_lib_contract.sh <label> [node=test1]`: needs test1 up with a mounted 2-node cluster (it unmounts the peer behind a live node). Header derives ~150 s, **bound 300 s**. Exit 0 PASS, 1 FAIL, 2 INFRA.
- `tests/capture_fault_gate.sh <label> [--healthy|--healthy-only] [--only h]`: 60 manifest entries (`tests/capture_gate.manifest`), each harness run with `MXFS_FAULT_RSX_NTH=1`; it bounds each lap itself from the manifest (fault laps sum to 17030 s worst case). Harnesses default to test1,test2 at 2/net/mesh/direct; 9 entries set NOPREP=1 and reuse the live mount, 45 prep it themselves. Verdict line `RESULT: PASS|FAIL label=<label> entries=...`.

**How to apply:** pass a label; wrap the first two in `timeout` with their header's bound (the "never wrap" rule is for run.sh, which bounds its own rows); power and form g2 (test1,test2) on the module under test before the contract and the gate; read the gate's verdict from its RESULT line, not only its rc.

## criteria ledger cache goes stale in a long-lived process

Source: [[trap-criteria-ledger-cache-goes-stale-in-a-long-lived-process]], via `compiled-tree-ownership-and-release-tooling-traps`.

**The trap:** `tools/criteria.py` `read_ledger()` caches each board's run ledger per process (`ledger_cache`), and only `append_ledger()` in the SAME process invalidates it. A process that imports criteria/defects and then runs `./run.sh` laps as children (`tools/release_run.py`'s batch step did this) reads the ledger as it was before the laps: a failed lap is missed, counts are stale, and a FAIL never ends the batch.

**Fixed (0.90.133):** `Run.sh()` in `tools/release_run.py` calls `criteria.ledger_cache.clear()` after every child command.

**How to apply:** any new Python that imports `criteria` (or `defects`, which reads through it) and lives across subprocesses that record runs must clear `criteria.ledger_cache` after each child before reading verdicts. Short CLI invocations are unaffected.

# E. Stale single-file SG_IO helper binaries

Source: [[trap-make-tools-does-not-rebuild-the-single-file-sg-io-helpers]]. `tools/Makefile` TOOLS is `mkfs_mxfs chk_mxfs resize_mxfs mxfs_admin fua_verify`. The single-file SG_IO and forge helpers - `tools/caw_verify`, `tools/caw_slotdump`, `tools/recov_forge`, `tools/mxfs_mmapio`, `tests/caw/caw_align_probe`, `tests/fence_inflight/prprobe` - are built only by `scripts/platform_build.sh` (`gcc -O2 -Wall -I include -o "$h" "$h.c"`), never by `make tools` or `make modules`.

Found 2026-10-22 (0.90.134, 4K-native work): `caw_verify.c`, `caw_slotdump.c` and `recov_forge.c` were changed on 2026-10-21 to take LBAs in the device's own logical blocks, but the binaries in the tree dated from 2026-10-14 and still took 512-byte LBAs (`caw_verify` printed `<lba_512>` in its usage). The nodes run the tree's binaries over NFS, so a board row on a 4096-byte LUN handing `caw_verify` a device-block LBA would have written 8x too far in: into the journal or the mounted volume.

Apply:
- After editing any of those six `.c` files, rebuild them with platform_build.sh's command, or compare each binary's mtime with its source before a rig run (`stat -c %Y`).
- Before freezing a release candidate, check all six are newer than their sources: the candidate freezes the binaries as files, and its build step re-verifies only the five TOOLS.
- When a tool's behaviour seems not to match its source, run its usage text first: a stale binary shows the old text.

# F. Pool LUNs stay on the SATA 870; capture yardsticks there

Source: [[feedback-pool-luns-stay-on-the-sata-870-capture-yardsticks-there]]. The rig's pool LUN images (`~/disks` -> `/mxfs/disks`, `/mxfs` = `/dev/sda`, a SATA Samsung SSD 870, ~512 MiB/s) moved off the NVMe root on 2026-10-22 by the owner's direction. When a session recommended moving them back to the NVMe (990 EVO Plus) because native XFS on a pool LUN measured only 511 MiB/s sequential write, the owner answered: "LOL -NO-".

Apply:
- Never propose moving the pool LUNs (or the VMs, or evidence) back to the NVMe. The 870 is the rig's LUN backing.
- A native-XFS yardstick measured on a pool LUN is bounded by the 870's SATA link: `host_disk[sda ... MiBs_max=512]` in the capture's own sampler. 511 MiB/s seq write and 539 MiB/s seq read on the 4K-native LUN (2026-10-22) are the disk, not XFS.
- Yardsticks captured before the move (the 512-byte `.xfs_fio_baseline.disk-caw-*.scst-fio.json`, 2026-10-01/04, 1133/1291 MiB/s) were measured on the NVMe and are stale for every board run on the 870: `tools/xfs_baseline_refresh.sh` says to re-measure whenever the LUN backing changes. Re-capture them on the 870 before grading any board's `fio_perf_vs_xfs`.
- Capture only on a quiet host: a board run or a package build on the lab VMs (whose disks are also on `/mxfs`) loads the same 870 and biases the yardstick low.

# G. Fencing lessons

(Two fencing lessons, a loose fit here: one on evidence capture, one on fence design. Sources: [[trap-ssh-kmsg-stream-loses-the-line-before-an-emergency-restart-use-clydes-netconsole]] and [[feedback-no-fence-design-may-store-hypervisor-credentials-on-cluster-nodes]], via `compiled-fence-test-capture-and-fence-credential-rules`.)

## Capture: ssh kmsg stream loses the line before emergency_restart()

- Observed in the fence=quorum split tests (vstest2): the module prints `P-QUORUM-LOST-RESET` and calls `emergency_restart()` in the same breath. One run's `tools/node_kmsg_stream.sh` capture (ssh `cat /dev/kmsg`) had the line, the next run's did not: the remote `cat` and sshd never get scheduled before the reset. A check reading only the stream reported FAIL on a reset that happened.
- How to apply: for any line a node prints right before resetting itself (self-fence, panic, quorum loss), load netconsole on the node (`modprobe netconsole netconsole=@/eth0,6666@192.168.120.1/`) - it transmits from inside printk.
- clyde already runs a listener (`tools/netconsole_listen.sh status`: socat on 6666, log `tests/evidence/netconsole.log`). It is the rig's: do not start/stop it from a test; record the log's byte size before and read only what is appended (`tail -c +N`). `tests/vsphere_shared_fence.sh` `split` does exactly this.

## Design: no fence may put hypervisor credentials on cluster nodes

- User rejected fence=vcenter outright. The 0.90.128 `fence=vcenter` design (docs/shared-disk-attachment.md, "Method: vcenter"; tools/mxfs_fence_vcenter.py) keeps `/etc/mxfs/vcenter.conf` + a 0600 `password_file=` on EVERY node, for an account that can power VMs off. User, 2026-10-13: "a clear text password to the entire vSphere environment with administrative access. You're insane." Scoping the vCenter role does not answer it; mode 0600 does not answer it.
- Why: any one compromised or misconfigured guest then holds the power to power off arbitrary VMs in the customer's vSphere. No storage admin will deploy a filesystem that requires that, and a session marked "working on vSphere" done on top of it.
- How to apply: a fence for a hypervisor-attached shared disk must not depend on credentials living inside the guests. Credential-free mechanisms to evaluate first: storage-side fencing reachable from the guest (in-guest iSCSI + SCSI PR), operator confirmation (`fence=manual`), guest self-fencing with the VMware virtual watchdog (vWDT, HW version 17+, `wdat_wdt`) plus a disk-based lease, SBD-style. Raise any design that needs a management-plane credential with the user BEFORE building it.

# H. Trap: a sibling checkout's `run.sh` prep formats the LUN with the main tree's `mkfs_mxfs`

Source: `trap-sibling-checkout-prep-formats-with-main-tree-mkfs` (found session 36).

- Mechanism: `run.sh`'s mkfs step ran `bash /src/mxfs/tests/setup/prep_fs.sh` without `MXFS_REPO`, and `prep_fs.sh` defaults `MXFS_REPO=/src/mxfs`. So every sibling checkout's (`~/src/mxfs-X`) prep formatted the LUN with the MAIN tree's `tools/mkfs_mxfs`, while `prep_node.sh` (given `MXFS_REPO=$NODE_REPO`) loaded the sibling's module.
- `run.sh`'s own comment says the nodes run "the tree's own tools"; the mkfs call did not.
- Consequence: any A/B of an mkfs/format change run from a sibling (e.g. the D-0349 ledger routing version, `mkfs -H 1|2` in `~/src/mxfs-d0349`) would have formatted every arm with the old mkfs (or failed on an unknown option), silently or loudly vacuous. Sibling A/Bs of module-only changes were unaffected (same mkfs).
- Fix: made first in `~/src/mxfs-d0349/run.sh`, passing `MXFS_REPO='/src/$(basename "$REPO")'` to `prep_fs.sh`. The main tree's `run.sh` needs the same one-line change, made only when no lap is executing it (bash reads a running script incrementally).
- Also: board test scripts are run as `/src/mxfs/tests/<cat>/<name>.sh` on the nodes, i.e. main's copies, even from a sibling.
- When a sibling arm must prove what it ran, read it back on the node. The d0349 arm reads `P-TAUTH-OPEN` `hash_version=` from each node's mount.

# I. Technique: decode a crash's "impossible" register words as data to name the writer

Source: `technique-decode-corrupt-register-words-as-data-to-name-the-writer` (found session 36, run 7e16fd1d).

- When a kernel crash shows "impossible" values (a non-canonical pointer in a register, a folio order of 189), the value is usually the BYTES OF WHATEVER OVERWROTE the structure, not a random flip. Decode it before calling the source unknown.
- How: take the 64-bit word, split it in memory order (little-endian on x86), and read it as fp16, bf16, two fp32, ASCII, and small ints. Structured data stands out.
- Worked case: `D-HOST-CLYDE-CRASH-XAS-SPLIT-ALLOC-FOLIO-ORDER-CORRUPT-0901A` (clyde host panic 2026-09-01) carried RSI `0xc1d8c166c1c7c1d1` and `0xc21dc0d8c0fcc209` for two months as "neither a valid kernel pointer, source unproven". Decoded, each is four fp16 values, all negative in a -2.4..-3.1 band (log-probability shaped tensor data). Eight halves with top byte 0xc0-0xc2 occur by chance ~1e-15. That was the direct evidence that disposed the record: ML tensor data over the `radix_tree_node` slab; mxfs never loads on the host.
- Why two unrelated processes hit it in the same millisecond: `xa_get_order` adds `xa_node->shift`, so a garbage `order` in `__filemap_add_folio` means the shared radix-tree node slab was overwritten.
- Why it matters: the record was mis-disposed once on another crash's evidence, then sat open as "unknown corrupter"; the answer was in the registers already transcribed.
- Transcribe register dumps verbatim when filing a host crash. The archived dmesg and pstore copies of that crash were later found deleted (empty `/var/lib/systemd/pstore/<id>/` dirs, no `.evidence/crash_*`), and the transcription was the only surviving copy.
