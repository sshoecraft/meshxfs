---
name: compiled-harness-substring-greps-and-gates-that-report-the-wrong-verdict
description: Harness verdict traps: substring greps, gate polarity/vacuity, probe caps, teardown zeros, ruling escape clauses, stale boards, VM/transport residue
metadata:
  type: feedback
tags: [compiled, harness, substring-grep, measurement-integrity, vacuity-gate, trap, probes, dmesg, evidence, teardown, authority-gate, vacuity, platform, release, transport]
---

# Harness and probe readings that answered a different question than the one asked

One shape throughout: a test asks "did event X happen?" but implements "does the text X appear somewhere?" (or counts a sibling, a stale format, or a presence that is not usability), or an absent probe line, a zero from a gate, a `Total: N PASS` read-back or a repro that stopped reproducing is read as a fact about MXFS when the cause was a spent cap, a drained producer, harness state or a stale artifact. Most fail silently in the direction of good news or of a null result that reads as "defect did not reproduce". Sections: word/substring matches that hit the wrong line; gates with the wrong polarity, format coverage or precondition; probes and gates that could not have printed; harness state and stale artifacts read as results; a ruling's escape clause; checklist.

Provenance of the material marked `compiled-capped-probe-absence-is-not-evidence`: that article had three parts. Part A was an assorted group of one note the clusterer could not fit to a topic, no siblings (common subject: what a missing probe line in an MXFS dmesg stream does and does not prove). Part B was folded in from `compiled-teardown-gate-zero-readings-vacuity-controls-and-choke-point-injection` (shared topic: how to read, and not misread, a zero from a gate that sits on a teardown or never-reached path, and how to make the unreached arm measurable). Part C was folded in from `compiled-platform-rig-harness-traps` (an assorted group, loosely related: three traps in the platform/release test harness, each a case of harness state or a stale artifact being mistaken for a real result).

## Word/substring matches that hit the wrong line

- **Wait loop on `grep -q PENDING`** (sess571, on the retired `showstat.sh`):

      timeout 420 bash -c 'while ./showstat.sh 2 tcp 2>&1 | grep -q "PENDING"; do
          sleep 20; done; echo BOARD_DONE'

  The board's totals line always named every status, "0 PENDING" included, so the loop never saw absence, spun its full 420 s and exited 124 on a board that had finished minutes earlier (a `rc=124` that looks like a hung board). `showstat.sh` is gone; the board is `tools/criteria.py`, whose `Total:` line lists only statuses present, so the literal "0 PENDING" is gone. A bare word test is still wrong: the word also shows in `criteria.py pending` output, in `measured` text, and in any future summary wording. The lesson is the shape, not the tool. Same shape as the mount_rc/umount_rc trap below: a token that also appears inside the very line that reports its absence. Assert on a parsed number, counting rows by the status column: `tools/criteria.py 2 tcp --no-colour | grep -cE '^[0-9]+ +\| [^|]+\| PENDING '`. General rule: when waiting on a condition, assert on a NUMBER you parsed, never on a word the "all clear" message may also contain. Better, do not wait on a board at all; run `run.sh` in the foreground with its own per-row budgets (see `feedback-sane-timeouts-derive-from-measured-wall-never-pad`). `trap-grep-q-PENDING-matches-the-summary-lines-own-zero-pending`
- **`grep -o 'mount_rc=[0-9]*'` matches inside `umount_rc=0`**, which the harness prints first; with `head -1` every lap read `mount_rc=0`. In `tests/d0944_death_rejoin_ab.sh` this turned "control 5 of 7 FAILED, fix 8 of 8 clean" into "control 4/6 ok, fix 6/6 ok". Second occurrence of that exact mis-summary. Anchor to the owning line (`sed -n 's/.*REJOIN mount_rc=\([0-9]*\).*/\1/p'`), prefer the node's own evidence file, and cross-check the driver's verdict against the harness's own `ck`/FAIL line at least once. Kernel-side probes (`ATOMIC-SKIP`, `P227-FR-TORN-UNPUBLISHED`) come from the survivor's dmesg, not harness stdout. `trap-bare-mount-rc-grep-matches-inside-umount-rc-and-reports-every-lap-as-success`
- **Contamination test counting `self-fenc`.** `fence_crash_cuts.sh` aborted every TCP lap because the routine peer-death line "deferring death 40000 ms ...; EX frozen (self-fence)" (dlm/v5_mount.c) contains the word. Fixed in 0.89.8 by counting the module's own `P131-SELF-FENCE` / `P236-SELF-FENCE` plus the shutdown text. Before counting a word as a failure marker, grep the tree for every print containing it and confirm each one is the event; prefer P-number markers over English fragments. `trap-a-substring-contamination-test-matches-the-transports-routine-peer-death-deferral-line-and-aborts-every-lap`

## Gates with the wrong polarity, format coverage or precondition

- **Vacuity gate counted the no-event probe.** `authtail_mount_unwind.sh` required a foreign replay but counted `P163-RECOVERED` (dlm/disklock.c, the NO-REPLAY completion). The replay path prints `P163-RECOVERY-COMPLETE` and `foreign replay of slot N complete` (xfs/xfs_log.c). Four laps read VACUOUS while their journals showed the replay; three release-gate records depended on it. "The string exists in the tree" does not validate a probe; read the source line to see which branch prints it, and prefer the subsystem's own sentence over a prefix-sharing tag. A harness that keeps returning VACUOUS on a path with independent evidence it ran is a harness bug until the raw journal is checked against the gate predicate. `trap-a-vacuity-gate-can-count-the-probe-that-fires-only-when-the-thing-it-requires-did-not-happen`
- **Gate table keyed on `RESULT:`.** 17 of 19 "no verdict" logs were passing laps in older shapes: `=== <harness> <label>: fails=0 wall=Ns ===`, `VERDICT PASS`. Also 25 of 150 capture-gate dirs are chunk runs whose dir name lacks the harness name; match on `<harness>_fault.log` / `<harness>_ok.log`. The gate itself reads only `^RESULT`, so its one-line summary of an older-format lap is also "no RESULT". Classify by all verdict shapes; "no line matched" means read the tail, never a category. `trap-a-gate-table-keyed-on-the-result-token-misreads-the-older-fails0-and-verdict-pass-lines-as-no-verdict`
- **Presence is not usability.** A shut-down (self-fenced) fs stays in `/proc/mounts` and returns EIO; `tests/d0949_sole_survivor_chunkfree.sh` ran against it, got zero counters and printed `VACUOUS` instead of a precondition failure. Probe usability (`mkdir -p $MNT/.probe.$$ && rmdir ...`) and `exit 2`. A `touch` at a mountpoint with nothing mounted writes to the root fs. `trap-a-mount-in-proc-mounts-is-not-a-working-mount-and-two-shell-counter-bugs`
  - `cnt() { grep -ac ... || echo 0; }` returns `"0\n0"` because `grep -c` prints 0 and exits 1. Use `c=$(grep -ac ... | head -1); echo "${c:-0}"`.
  - `df -i --output=itotal` is rejected, and without `-i` itotal is `maxicount`, not `sb_icount` (25991808 before and after 12000 creates). Use `tools/chk_mxfs -v <dev>` (`Superblock icount:`, `Total inodes (inobt sum):`; works mounted). Prefer kernel-maintained counters over budgeted probes (`P133-ICLUSTER-SYNCINIT` prints only the first 20 per load), but verify the counter means what the verdict assumes.
- **Vacuity is a precondition, not a FAIL** (Part B of `compiled-capped-probe-absence-is-not-evidence`). `d0932_retire_pending_takeover.sh` and `d0932_owner_depart_takeover.sh` checked "is the needed state on the platter" with `ckge` (prints `  FAIL`) and then printed `RESULT: VACUOUS` / exit 3. `tests/capture_fault_gate.sh` counts VACUOUS only with exit 3 and zero FAIL lines, so both scored BROKEN on laps the harness itself judged non-measurements (s53b, s59h, s70c). The state is genuinely unreachable in that shape: a clean unmount serialises against the node's parked fence/recovery work, so the departure leaves nothing standing. See `trap-a-vacuity-precondition-printed-as-a-fail-line-makes-the-capture-gate-score-the-harnesss-own-vacuous-verdict-as-broken`.
  - Rule: a check deciding whether the lap can measure anything prints a `STAGE ...` line with the count and takes the VACUOUS exit. Reserve `ck`/`ckge` FAIL lines for assertions about MXFS on a state that was reached. Gate contract: exit 0 = OK; exit 3 with no FAIL lines = VACUOUS (counted apart); exit 1/2 or any FAIL line = BROKEN.

## Probes and gates that could not have printed

From `compiled-capped-probe-absence-is-not-evidence` (Parts A and B): an absence or a zero read as a fact about MXFS.

### A missing probe line proves nothing once its per-boot cap is spent (Part A)

**Rule.** An inode-specific probe line missing from a stream is not evidence when that probe's per-boot cap was spent earlier. Before reading "no line for X after time T" as a fact, establish that the probe could still print at T. `trap-capped-probe-absence-after-cap-is-spent`

**Which probes stop printing.** Many MXFS probes print under a static per-boot cap (`atomic_inc_return(&n) <= 2000` style). Caps on record: `trap-capped-probe-absence-after-cap-is-spent`

| probe | per-boot cap |
|---|---|
| `P-FREEPUB-WRITE` and `P-FREEPUB-CLAIM` | 2000 |
| the shared `P55C-FREE-*` counter | 2000 |
| `P170-CLWR` | 800 |
| `P25-INSTR` | 300 |
| `P-LOGWR-INCARN-MISMATCH` | 20000 |
| `P17B` / `P119` | 4000 |

`P133-ICLUSTER-SYNCINIT` is capped too (first 20 per load; see the counter bullet under "Presence is not usability"). Other probes use `mxfs_probe_ratelimited`, which drops lines in bursts. `trap-capped-probe-absence-after-cap-is-spent`

**What it cost: the D-FREED-INODE-HOME misread (session 54, corrected session 55).**

- Session 54 concluded "the peer never wrote its free to disk before the unlinker got the lock" (ng0rf1, D-FREED-INODE-HOME) from the absence of P-FREEPUB / P55C / P170-CLWR lines for one inode after its free.
- On that node every one of those probes had already hit its cap about 45 s before the free: last lines at 2515.6 s and 2517.3 s; the free at 2562.5 s.
- The "second fault" session 54 built on that absence, and its claim that the epoch guard could not cover the case, had no evidence behind them.
- Session 55 corrected the record.

`trap-capped-probe-absence-after-cap-is-spent`

**How to apply.**

1. Before reading "no line for X after time T" as a fact, run per probe and per node the whole-stream count and the last timestamp: `zcat <node>_dmesg_stream.gz | grep -a -- '<TAG>' | awk` (awk reduces to first, last, count).
2. If the count equals the cap, or the last line is before T, the absence says nothing.
3. Use the module's counters or an uncapped probe instead.
4. A harness that grades on a probe line must reset or raise its cap, or grade on a counter.

`trap-capped-probe-absence-after-cap-is-spent`

### A zero on a teardown gate: find what emptied the producer (Part B, from `compiled-teardown-gate-zero-readings-vacuity-controls-and-choke-point-injection`)

- The post-detach metadata arm of the authority gate counted zero twice, and both conclusions drawn ("ordering never reached", then "MXFS skips the one buffer") were about the gate and were wrong. `put_super` runs `xfs_log_quiesce` before sealing and detaching, but only when the SB summary lock was granted. That quiesce empties the AIL, so the post-detach `xfs_ail_push_all_sync` finds nothing. A refused SB lock therefore leaves MORE dirty at detach, the opposite of what the evidence was read to say. Dirtying the filesystem before umount cannot populate this arm because the quiesce drains it. The producer must be created after the quiesce and seal; `dbg_sb_late_dirty` already did that (root inode core logged after the seal), sitting in the tree for ~30 versions under another record's name. See `trap-a-teardown-gate-reads-zero-because-an-earlier-quiesce-drained-its-producer-not-because-the-gate-is-unreached`.
  - Rule: before concluding anything from a zero on a teardown path, list every quiesce, drain and flush between workload and gate and ask which empties the producer. A gate after a drain measures only what was created after it. Then grep the tree for an injection that already produces the population.

### A refused mount's unwind is mute by design (Part B)

- The mount-failure unwind (`out_unmount`) detaches the DLM before `xfs_unmountfs`, so the window after detach is real, yet lap s92 counted zero `P291-AUTH-META-DETACHED`. The positive control (`P291-AUTH-TAIL-ADMIT`, emitted for any post-detach submission) was also zero: the window never opened. The refused mount had a clean log slice (no recovery) and its quiesce deliberately writes no SB summary (`P960-REFUSED-MOUNT-NOCOVER`, gated on `!mp->m_mxfs_mount_complete`). To make the unwind write, stage a dirty log it must recover. See `trap-a-refused-mount-unwind-has-nothing-to-write-so-its-zero-is-not-a-measurement-of-the-gate`.
  - Rule: a teardown measurement needs a positive control emitted from the SAME window by an already-working path; without one, "zero" and "the window never opened" are the same number. Build the control in from the start and FAIL the lap on a zero control instead of reporting the measurement.

### Making an unreached arm measurable (Part B)

- For a leak class with one unattributable historical event (D-0924, AG-meta track token), the disposition that holds: (1) prove the lifetime class finite and name its choke points, including grepping for wholesale flag resets and teardown paths that detach the item; (2) return the obligation at every choke point, even the one that looked like a pure diagnostic; (3) write the exclusion argument for the late return next to the code (buffer lock held from submit to completion's relse); (4) exercise the arm a healthy build never reaches with an injection knob (`dbg_agmeta_iodone_skip=N`; epilogue must return exactly N, conservation exact); (5) check conservation per unit (per AG), not only globally; (6) state which routes are measured and which closed by construction. A closure shipped unreached is a claim, not a measurement. See `technique-close-a-finite-lifetime-class-at-its-choke-points-and-prove-the-unreached-one-by-injection`.
- Evidence trap: injection evidence lands in the first second of churn; at ~700 lines/s the dmesg ring rotated past it before the post-run sweep. Lost-to-rotation is not absent. Stream the ring (`setsid nohup dmesg -w > /dev/shm/x &`) from before the arming marker and grep the stream; confirm the marker survives in whatever is swept.

## Harness state and stale artifacts read as results

From `compiled-capped-probe-absence-is-not-evidence` (Part C, which was `compiled-platform-rig-harness-traps`): three traps in the platform/release test harness.

### Unheld platform VMs are shut off by release helpers mid-round `trap-unheld-platform-vms-are-shut-off-by-release-helpers-mid-round`

**Trap.** `scripts/release.sh` builds packages and runs kernel build checks on the first node of several platform sets (`vm_package_build.sh` on debian12-1 and alma9-1, `vm_kbuild_check.sh` on pve9-1 ...). Each leaves a `tools/vm_pool.sh release --after <pid>` helper that, once release.sh exits and a 600 s grace passes, shuts off any of its VMs that NOBODY HOLDS. `tests/full_verify.sh POWER=1` powered the platform sets with `lab_power.sh` but did not `vmhold_take` them (only the POWER=0 path did), so 0.90.130's first platform run lost pve9-1, alma9-1 and debian12-1 part way through their packaged rounds ("System is going down" pam_nologin banner parsed as kernel names, `dpkg was interrupted`, firewalld not running after the hard stop). Fixed in 0.90.130: full_verify holds the sets in both modes.

**Second-order: killing a platform run leaves residue the next run fails on.** A killed CAW packaged round leaves `force_transport=0` in the conffile `/etc/modprobe.d/mxfs.conf` (kept across reinstalls), so the next TCP round fails "loaded mxfs with force_transport=0"; a node powered off mid-install leaves dpkg half-configured. Before rerunning after a kill: `dpkg --audit` (run `dpkg --configure -a`), check mxfs.conf's force_transport, and firewalld on alma nodes. Also: full_verify POWER=1's group-end `lab_power.sh down` DESTROYS a node still busy (e.g. a manual `dpkg --configure -a` rebuilding DKMS) — repair only after the run has ended.

**Apply:** any script that uses pool VMs must `vmhold_take` them for its whole life (tests/lib/runlock.sh), whatever powers them. When a VM shuts off unexpectedly on clyde, first suspect a `release --after` helper, not the guest.

### A board log's `Total: N PASS` seconds after start is a stale read-back `trap-board-log-total-within-seconds-of-start-is-a-stale-read-back`

**Trap.** `tests/board_4node_chain.sh` always reads the board back with `tools/criteria.py <cfg>` after `run.sh`, whatever `run.sh` did. When `run.sh` refuses before running any row, the chain log still prints `<cfg>: Total: 40 — 40 PASS` — cells stored from an EARLIER build. Common refusal: `lun_pool: no LUN of at least 80G is free` (run.sh takes 20G up to 8 nodes, 80G above; the pool had one 80G LUN and two 16-node boards were in the same wave).

**Seen:** 0.90.130 release chain (2026-10-16): `16/disk/caw/mpath: Total: 40 — 40 PASS` at 00:58:11, three seconds after its run started at 00:58:08; `16/net/mesh/mpath` the same. Neither board had run. `tools/release_status.py` caught it ("not run on the release build"), the chain log did not.

**Apply:**
- Before reading a chain's `Total:` line as a result, check the board log itself (`tests/evidence/board_<cfg>_<group>_<label>.log`) for `=== rc=` and an `ERROR:` before the CRITERIA table, and that the row lines carry this run's timestamps/build.
- A board's wall is minutes (2-node ~25-50 min, 16-node ~20-60 min); a Total within seconds is never a run.
- `tests/release_verify_chain.sh` now caps boards above 8 nodes per wave at the pool's count of >=80G LUNs (0.90.130), but any refusal (node lock, preflight, LUN) still reads back the stale board.

### Package-module tests inherit the transport the last packaged round left `trap-package-module-tests-inherit-the-transport-the-last-packaged-round-left`

`tests/packaged_round.sh` rewrites `/etc/modprobe.d/mxfs.conf` to `force_transport=0` for its CAW configuration and puts 1 back afterwards. A harness that later loads the package with a bare `modprobe mxfs` gets whichever value is in the file at that moment, so two runs of the "same" test can run on different lock transports without saying so.

Bit us on D-JOIN-FREEZE-RELMARK-TRANS-ALLOC-WHILE-FROZEN (0.90.130): the WARN reproduced 3 of 3 at 12:03-12:05 and then 0 of 12 afterwards, read as "timing-dependent". The real difference was the transport: the reach is CAW-only (a lone CAW incumbent holds on-disk tenures with grant epochs; on TCP the newcomer is registered only after the view install). With TRANSPORT=caw it reproduced every time.

**Apply:**
- Any platform harness must pin the transport on the command line (`modprobe mxfs force_transport=N`, which wins over modprobe.d) and print `/sys/module/mxfs/parameters/force_transport` next to srcversion.
- When a defect "stops reproducing", diff the load conditions (transport, params, module identity) before calling it intermittent.
- `tests/join_freeze_userspace_thaw.sh` and `tests/userfreeze_peer_demand.sh` take TRANSPORT=tcp|caw.

Link between the first and third traps: both involve the stale `force_transport` value in `/etc/modprobe.d/mxfs.conf` left by packaged rounds (killed or finished).

## Not a grep, same discipline

- **A ruling's escape clause may already be closed.** `docs/rulings/fence-crash-matrix-cuts.md` allows omitting in-flight entries as crash laps "once pending I/O has drained before a successor acts". `dlm/scsipr.c`, in the comment sizing `mxfs_lu_reset_converge_ms`, says that would be "the pre-reset drain the design ruling rejected". No drain exists to measure, so the live-prover faults must be injected (`mxfs.pr_fence_submit_inject`, 0.89.55). When an exemption is conditional on a property, grep the subsystem for the property's name first: a rejected design is not a property that might happen to hold, and the decision can sit in an unrelated timeout comment. `trap-a-rulings-escape-clause-can-be-closed-by-a-design-decision-recorded-only-in-a-comment-on-an-unrelated-timeout`

## Checklist

1. Assert on a parsed number or an anchored field, never on a word the all-clear text may also contain.
2. For each marker, enumerate every print site containing it and confirm which branch emits it.
3. Gate on usability of the precondition (a dead mount: exit non-zero, a precondition failure), never emit a null measurement. A lap that ran validly but could not reach the needed state is VACUOUS (exit 3, a `STAGE ...` line with the count, no FAIL lines), not BROKEN.
4. Enumerate every verdict format before tabulating; unmatched means read the tail.
5. Cross-check a driver's summary against the harness's own FAIL lines and the raw node evidence at least once.
6. Before reading an absence or a zero as a fact, show the reading could have been non-zero: per-probe, per-node whole-stream count and last timestamp against the cap; a positive control from the same window (FAIL the lap on a zero control); every quiesce, drain and flush between workload and gate; the dmesg ring streamed from before the arming marker.
7. Before reading a `Total:` line or a repro rate as a result, tie it to this run: the board log's `=== rc=`/`ERROR:`, this run's timestamps and build, a pinned and printed `force_transport`, pool VMs held with `vmhold_take` for the whole run.
