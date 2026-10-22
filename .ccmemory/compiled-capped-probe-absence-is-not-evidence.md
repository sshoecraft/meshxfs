---
name: compiled-capped-probe-absence-is-not-evidence
description: Readings that measured nothing: spent-cap probe absence, teardown-gate zeros, vacuity vs FAIL, injection; VM shutoff, stale board, transport residue
metadata:
  type: feedback
tags: [compiled, trap, probes, dmesg, evidence, measurement-integrity, teardown, authority-gate, vacuity, harness, platform, release, transport]
---

Readings that measured nothing: an absent probe line, a zero from a gate, a `Total: N PASS` read-back, a repro that stopped reproducing. Each was read as a fact about MXFS when the cause was a spent cap, a drained producer, harness state or a stale artifact. Three parts. A is the original article (an assorted group of one note the clusterer could not fit to a topic, no siblings; common subject: what a missing probe line in an MXFS dmesg stream does and does not prove). B is folded in from `compiled-teardown-gate-zero-readings-vacuity-controls-and-choke-point-injection` (shared topic: how to read, and not misread, a zero from a gate that sits on a teardown or never-reached path, and how to make the unreached arm measurable). C is folded in from `compiled-platform-rig-harness-traps` (an assorted group, loosely related: three traps in the platform/release test harness, each a case of harness state or a stale artifact being mistaken for a real result).

## Part A. A missing probe line proves nothing once its per-boot cap is spent

### Rule

An inode-specific probe line missing from a stream is not evidence when that probe's per-boot cap was spent earlier. Before reading "no line for X after time T" as a fact, establish that the probe could still print at T. `trap-capped-probe-absence-after-cap-is-spent`

### Which probes stop printing

Many MXFS probes print under a static per-boot cap (`atomic_inc_return(&n) <= 2000` style). Caps on record: `trap-capped-probe-absence-after-cap-is-spent`

| probe | per-boot cap |
|---|---|
| `P-FREEPUB-WRITE` and `P-FREEPUB-CLAIM` | 2000 |
| the shared `P55C-FREE-*` counter | 2000 |
| `P170-CLWR` | 800 |
| `P25-INSTR` | 300 |
| `P-LOGWR-INCARN-MISMATCH` | 20000 |
| `P17B` / `P119` | 4000 |

Other probes use `mxfs_probe_ratelimited`, which drops lines in bursts. `trap-capped-probe-absence-after-cap-is-spent`

### What it cost: the D-FREED-INODE-HOME misread (session 54, corrected session 55)

- Session 54 concluded "the peer never wrote its free to disk before the unlinker got the lock" (ng0rf1, D-FREED-INODE-HOME) from the absence of P-FREEPUB / P55C / P170-CLWR lines for one inode after its free.
- On that node every one of those probes had already hit its cap about 45 s before the free: last lines at 2515.6 s and 2517.3 s; the free at 2562.5 s.
- The "second fault" session 54 built on that absence, and its claim that the epoch guard could not cover the case, had no evidence behind them.
- Session 55 corrected the record.

`trap-capped-probe-absence-after-cap-is-spent`

### How to apply

1. Before reading "no line for X after time T" as a fact, run per probe and per node the whole-stream count and the last timestamp: `zcat <node>_dmesg_stream.gz | grep -a -- '<TAG>' | awk` (awk reduces to first, last, count).
2. If the count equals the cap, or the last line is before T, the absence says nothing.
3. Use the module's counters or an uncapped probe instead.
4. A harness that grades on a probe line must reset or raise its cap, or grade on a counter.

`trap-capped-probe-absence-after-cap-is-spent`

## Part B. A zero on a teardown path: find what emptied the producer, build the control, inject the unreached arm

Folded in from `compiled-teardown-gate-zero-readings-vacuity-controls-and-choke-point-injection`.

### Zero on a teardown gate: find what emptied the producer

- The post-detach metadata arm of the authority gate counted zero twice, and both conclusions drawn ("ordering never reached", then "MXFS skips the one buffer") were about the gate and were wrong. `put_super` runs `xfs_log_quiesce` before sealing and detaching, but only when the SB summary lock was granted. That quiesce empties the AIL, so the post-detach `xfs_ail_push_all_sync` finds nothing. A refused SB lock therefore leaves MORE dirty at detach, the opposite of what the evidence was read to say. Dirtying the filesystem before umount cannot populate this arm because the quiesce drains it. The producer must be created after the quiesce and seal; `dbg_sb_late_dirty` already did that (root inode core logged after the seal), sitting in the tree for ~30 versions under another record's name. See `trap-a-teardown-gate-reads-zero-because-an-earlier-quiesce-drained-its-producer-not-because-the-gate-is-unreached`.
- Rule: before concluding anything from a zero on a teardown path, list every quiesce, drain and flush between workload and gate and ask which empties the producer. A gate after a drain measures only what was created after it. Then grep the tree for an injection that already produces the population.

### A refused mount's unwind is mute by design

- The mount-failure unwind (`out_unmount`) detaches the DLM before `xfs_unmountfs`, so the window after detach is real, yet lap s92 counted zero `P291-AUTH-META-DETACHED`. The positive control (`P291-AUTH-TAIL-ADMIT`, emitted for any post-detach submission) was also zero: the window never opened. The refused mount had a clean log slice (no recovery) and its quiesce deliberately writes no SB summary (`P960-REFUSED-MOUNT-NOCOVER`, gated on `!mp->m_mxfs_mount_complete`). To make the unwind write, stage a dirty log it must recover. See `trap-a-refused-mount-unwind-has-nothing-to-write-so-its-zero-is-not-a-measurement-of-the-gate`.
- Rule: a teardown measurement needs a positive control emitted from the SAME window by an already-working path; without one, "zero" and "the window never opened" are the same number. Build the control in from the start and FAIL the lap on a zero control instead of reporting the measurement.

### Making an unreached arm measurable

- For a leak class with one unattributable historical event (D-0924, AG-meta track token), the disposition that holds: (1) prove the lifetime class finite and name its choke points, including grepping for wholesale flag resets and teardown paths that detach the item; (2) return the obligation at every choke point, even the one that looked like a pure diagnostic; (3) write the exclusion argument for the late return next to the code (buffer lock held from submit to completion's relse); (4) exercise the arm a healthy build never reaches with an injection knob (`dbg_agmeta_iodone_skip=N`; epilogue must return exactly N, conservation exact); (5) check conservation per unit (per AG), not only globally; (6) state which routes are measured and which closed by construction. A closure shipped unreached is a claim, not a measurement. See `technique-close-a-finite-lifetime-class-at-its-choke-points-and-prove-the-unreached-one-by-injection`.
- Evidence trap: injection evidence lands in the first second of churn; at ~700 lines/s the dmesg ring rotated past it before the post-run sweep. Lost-to-rotation is not absent. Stream the ring (`setsid nohup dmesg -w > /dev/shm/x &`) from before the arming marker and grep the stream; confirm the marker survives in whatever is swept.

### Vacuity is a precondition, not a FAIL

- `d0932_retire_pending_takeover.sh` and `d0932_owner_depart_takeover.sh` checked "is the needed state on the platter" with `ckge` (prints `  FAIL`) and then printed `RESULT: VACUOUS` / exit 3. `tests/capture_fault_gate.sh` counts VACUOUS only with exit 3 and zero FAIL lines, so both scored BROKEN on laps the harness itself judged non-measurements (s53b, s59h, s70c). The state is genuinely unreachable in that shape: a clean unmount serialises against the node's parked fence/recovery work, so the departure leaves nothing standing. See `trap-a-vacuity-precondition-printed-as-a-fail-line-makes-the-capture-gate-score-the-harnesss-own-vacuous-verdict-as-broken`.
- Rule: a check deciding whether the lap can measure anything prints a `STAGE ...` line with the count and takes the VACUOUS exit. Reserve `ck`/`ckge` FAIL lines for assertions about MXFS on a state that was reached. Gate contract: exit 0 = OK; exit 3 with no FAIL lines = VACUOUS (counted apart); exit 1/2 or any FAIL line = BROKEN.

## Part C. Platform/release harness traps: stale state mistaken for a result

Folded in from `compiled-platform-rig-harness-traps`.

### 1. Unheld platform VMs are shut off by release helpers mid-round `trap-unheld-platform-vms-are-shut-off-by-release-helpers-mid-round`

**Trap.** `scripts/release.sh` builds packages and runs kernel build checks on the first node of several platform sets (`vm_package_build.sh` on debian12-1 and alma9-1, `vm_kbuild_check.sh` on pve9-1 ...). Each leaves a `tools/vm_pool.sh release --after <pid>` helper that, once release.sh exits and a 600 s grace passes, shuts off any of its VMs that NOBODY HOLDS. `tests/full_verify.sh POWER=1` powered the platform sets with `lab_power.sh` but did not `vmhold_take` them (only the POWER=0 path did), so 0.90.130's first platform run lost pve9-1, alma9-1 and debian12-1 part way through their packaged rounds ("System is going down" pam_nologin banner parsed as kernel names, `dpkg was interrupted`, firewalld not running after the hard stop). Fixed in 0.90.130: full_verify holds the sets in both modes.

**Second-order: killing a platform run leaves residue the next run fails on.** A killed CAW packaged round leaves `force_transport=0` in the conffile `/etc/modprobe.d/mxfs.conf` (kept across reinstalls), so the next TCP round fails "loaded mxfs with force_transport=0"; a node powered off mid-install leaves dpkg half-configured. Before rerunning after a kill: `dpkg --audit` (run `dpkg --configure -a`), check mxfs.conf's force_transport, and firewalld on alma nodes. Also: full_verify POWER=1's group-end `lab_power.sh down` DESTROYS a node still busy (e.g. a manual `dpkg --configure -a` rebuilding DKMS) — repair only after the run has ended.

**Apply:** any script that uses pool VMs must `vmhold_take` them for its whole life (tests/lib/runlock.sh), whatever powers them. When a VM shuts off unexpectedly on clyde, first suspect a `release --after` helper, not the guest.

### 2. A board log's `Total: N PASS` seconds after start is a stale read-back `trap-board-log-total-within-seconds-of-start-is-a-stale-read-back`

**Trap.** `tests/board_4node_chain.sh` always reads the board back with `tools/criteria.py <cfg>` after `run.sh`, whatever `run.sh` did. When `run.sh` refuses before running any row, the chain log still prints `<cfg>: Total: 40 — 40 PASS` — cells stored from an EARLIER build. Common refusal: `lun_pool: no LUN of at least 80G is free` (run.sh takes 20G up to 8 nodes, 80G above; the pool had one 80G LUN and two 16-node boards were in the same wave).

**Seen:** 0.90.130 release chain (2026-10-16): `16/disk/caw/mpath: Total: 40 — 40 PASS` at 00:58:11, three seconds after its run started at 00:58:08; `16/net/mesh/mpath` the same. Neither board had run. `tools/release_status.py` caught it ("not run on the release build"), the chain log did not.

**Apply:**
- Before reading a chain's `Total:` line as a result, check the board log itself (`tests/evidence/board_<cfg>_<group>_<label>.log`) for `=== rc=` and an `ERROR:` before the CRITERIA table, and that the row lines carry this run's timestamps/build.
- A board's wall is minutes (2-node ~25-50 min, 16-node ~20-60 min); a Total within seconds is never a run.
- `tests/release_verify_chain.sh` now caps boards above 8 nodes per wave at the pool's count of >=80G LUNs (0.90.130), but any refusal (node lock, preflight, LUN) still reads back the stale board.

### 3. Package-module tests inherit the transport the last packaged round left `trap-package-module-tests-inherit-the-transport-the-last-packaged-round-left`

`tests/packaged_round.sh` rewrites `/etc/modprobe.d/mxfs.conf` to `force_transport=0` for its CAW configuration and puts 1 back afterwards. A harness that later loads the package with a bare `modprobe mxfs` gets whichever value is in the file at that moment, so two runs of the "same" test can run on different lock transports without saying so.

Bit us on D-JOIN-FREEZE-RELMARK-TRANS-ALLOC-WHILE-FROZEN (0.90.130): the WARN reproduced 3 of 3 at 12:03-12:05 and then 0 of 12 afterwards, read as "timing-dependent". The real difference was the transport: the reach is CAW-only (a lone CAW incumbent holds on-disk tenures with grant epochs; on TCP the newcomer is registered only after the view install). With TRANSPORT=caw it reproduced every time.

**Apply:**
- Any platform harness must pin the transport on the command line (`modprobe mxfs force_transport=N`, which wins over modprobe.d) and print `/sys/module/mxfs/parameters/force_transport` next to srcversion.
- When a defect "stops reproducing", diff the load conditions (transport, params, module identity) before calling it intermittent.
- `tests/join_freeze_userspace_thaw.sh` and `tests/userfreeze_peer_demand.sh` take TRANSPORT=tcp|caw.

Link between traps 1 and 3 of this part: both involve the stale `force_transport` value in `/etc/modprobe.d/mxfs.conf` left by packaged rounds (killed or finished).
