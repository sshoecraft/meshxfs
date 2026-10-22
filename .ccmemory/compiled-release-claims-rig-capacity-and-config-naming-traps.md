---
name: compiled-release-claims-rig-capacity-and-config-naming-traps
description: Release claims: failure tests, all-PASS board, derived timeouts; clyde VM capacity; caw/cawd/cawp keys; mis-measuring board/harness; XFS-fork traps
metadata:
  type: feedback
tags: [compiled, release, rig, clyde, defects, caw, mpath, timeouts, board, fio, measurement, harness, fault-injection, xfs-traps]
---

Compiled from a topic group, then merged with two articles on the same subject: whether a release claim, a green board row or a measured number actually proves what it says. Covers what a release claim requires (failure-mode tests, every board row PASS, derived timeouts), how many rig VMs clyde can carry, how the CAW configuration names mislead the defect queue and release prose, the timeout and VM-disposability directives, the board rows and harness readers, injectors and clock anchors that measure something other than what they claim, and four loosely related XFS-fork traps from the same board/wedge investigations. Absorbs `compiled-harness-measurement-integrity-clock-anchors-field-readers-vacuous-injectors-and-hang-fix-verification` and `compiled-board-measurement-validity-and-release-gating`.

## A release claim for a failure-surviving feature requires the failure to be tested

`feedback-an-attachment-is-not-released-until-its-failure-mode-is-tested` (0.90.43). All eight `{2,4,8,16}/{net/mesh,disk/caw}/mpath` boards passed 31/31 with each node on a dm-multipath map over two iSCSI portals. Both portals were addresses on the same host bridge and each VM had one NIC, so no row ever removed a path. Writing "released; path failover not verified" in the README was rejected. The user said mpath is not working until it is tested fully, because production users will test it.

- Applies to any attachment or redundancy feature: multipath, replication, redundancy, fencing. The happy path does not earn the claim.
- Build the real topology: independent NICs or networks per path, not aliases on one wire.
- Inject the failure under load. Verify failover AND failback, and that I/O is actually carried by the returned path.
- When a criterion says "boards pass on X", ask what a production user would do to X on day one and make it a suite row on X's columns before releasing.
- Documenting the gap is not a substitute for testing it when the claim is "released".

## Release gating

Source: `compiled-board-measurement-validity-and-release-gating`.

- User correction on the 0.90.7 release: every suite row must PASS cleanly on the release srcversion; "there can be no such thing as FLAKY". A harness fix does not turn a FAIL/FLAKY row into PASS; a SKIP (e.g. missing native-XFS baseline, so the 2x ceiling was never measured) is work owed, not a pass; a pass in a separate run does not replace the row on the board. An empty `tools/defects.py <N> <dlm> --release` or a loop's own criteria-met judgement is not a substitute for an all-PASS board. `feedback-a-release-requires-every-board-row-pass-no-flaky-no-skip`
- FLAKY clears by aging, so derive laps from the board: `tools/criteria.py` keeps an 11-run window (live + 10 history); NOT RUN/ABORTED occupy a slot but do not count. Take k = index of the newest genuine FAIL in `data/criteria.json` (`per_config` is live, `history` newest first); the row reads PASS after 11-k more runs. Run 10-k single-row laps first, then the board, because the board's read-back is what a release cites and must see a clean window. Do not count laps from "how many failed", and do not run the board before the laps. `tests/release_verify_chain.sh` takes W4_LAPS / W2TCP / W2CAWD; `tests/board_4node_chain.sh` runs each lap as one forced prep plus the rows. `technique-derive-flake-window-laps-from-the-board-before-a-release-board-run`

## Timing is a pass/fail property

`timing-is-first-class`. Timeouts are performance assertions, not safety nets.

- Budget = measured infra (boot, mkfs, mount, ssh) + workload at 2x the native-XFS equivalent. Set the Bash timeout to that budget, never a round number or the tool cap.
- A timeout is a FAIL even with zero errors. Kill it, record FAIL, diagnose the slowness as a first-class bug.
- 2x native XFS is the hard ceiling for workloads. Never widen a timeout or re-run with a bigger one to see if it finishes.
- After each healthy PASS, record the actual wall in `tests/criteria/TIMEOUT_BUDGETS.md` and tighten.
- Baselines: mkfs 0.6s, first mount 2.7s, later mounts 4.8s, umount 0.4s, VM power-cycle to ssh 40-50s, 4-node fresh_cluster_mount ~60s.
- Internal-timeout debt: barrier_wait 120s (should be <=15s) and MXFS_CAW_WAIT_TIMEOUT_MS=120s.
- Deriving a board chunk's timeout (`compiled-board-measurement-validity-and-release-gating`): from the measured last-healthy wall, never padded (the user said it "at least 50 times"). `run.sh` already enforces per-test budgets from the manifest and flips PASS to FAIL on overrun; an outer wrapper only bounds a harness-level hang. Derive: sum the ELAPSED column of `tools/criteria.py <N> <dlm>` for the chunk, +20%, +10 s ssh dispatch; the Bash tool timeout is that +~5 s. Never widen on a non-finish; the slowness is the bug. 32/caw 0.14.11 reference: prep 56 s, fio chunk 26 s, coherency chunk 75 s, scaling chunk 76 s, whole 28-row board ~690 s. Invented 420-540 s wrappers around 26-76 s chunks are the failure. `feedback-sane-timeouts-derive-from-measured-wall-never-pad`

## Rig VMs and clyde capacity

- `Test VMs are disposable`: `virsh destroy testN` / `virsh start testN` / full rebuild of test1..test32 needs no permission. There are 32 of them and the user can rebuild any in ~5 minutes. Confirmed 2026-04-25 in the v0.3.4 session, after a D-state self-deadlock on test2 (from v0.3.3) where permission to `virsh destroy` was asked; user (paraphrased): do whatever you need to with the test VMs, they don't matter. They are disposable test infrastructure for kernel module work. The `feedback_no_reboot.md` rule still applies to production hosts (clyde, serv, etc.); only the testN guest VMs are fair game.
- `trap-32-idle-vms-running-exhausts-clyde-ram-harness-kills-background-tasks-shut-idle-vms` (2026-09-05). 32 VMs left running at ~1.2-1.4 GB RSS each put clyde at 0 free and 20 of 23 GB swap used. Claude Code killed the session's background Bash ("running low on memory"), but the chain it launched survived as an orphan and died later.
  - Before a long background rig job, check `free -g`. If swap is in use, shut the VMs the job does not need (test1-test4 stay for the 2- and 3-node arms).
  - `virsh shutdown` (ACPI) did not complete on any of 28 VMs within 60 s, so `virsh destroy` was needed. Delegate this to a rig-runner.
  - Restart the VMs in batches of ~8, then use `scripts/mpath_up.sh up 32` as the readiness gate.
  - A killed wrapper does not kill its chain: check `tools/mxfs_pgrep.sh <script>` and attach a Monitor to the orphan's log. Do not relaunch on top of it.
- `trap-the-host-fits-14-rig-vms-under-load-so-six-release-boards-cannot-run-at-once` (corrected 2026-10-01). Rig VMs have Max 4 GiB with balloon Used 2.5 GiB and 4 vCPU (`virsh dominfo`). The earlier "14 VMs max" claim counted the balloon ceiling.
  - Memory: 28 nodes x 2.5 GiB = 70 GiB fits the 94 GiB host, until balloons are raised or platform sets are up at the same time.
  - The real limit is CPU: 28 x 4 = 112 vCPU on 56 cores. A fully parallel six-board run risks pace failures from host contention, since the boards grade pace. Throughput rows already take a host-wide lock.
  - Check `virsh dominfo <vm>` Used memory before sizing a parallel run. Do not quote the max.

## Configuration names: caw, cawd, cawp

The three CAW names are the rig's names for how the LUN is attached, not different transports. `caw` was CAW over dm-multipath, `cawd` was direct in-guest single-path iSCSI, and `cawp` was passthrough. `run.sh` maps `cawd|cawp` to `BASE_TRANSPORT=caw`.

- `trap-a-defect-record-tagged-cawd-or-cawp-is-invisible-to-the-queues-caw-views` (0.90.24). `blocks()` in `tools/defects.py` matches `dlm` exactly. A record added with `-D cawd` (the board name) was missing from `N caw` and `N caw --release`. The README said 9 records reach 4-node CAW and the true count was 10. A blocking record tagged this way would have passed the release filter unseen.
  - Pass `-D caw` for anything seen on a caw, cawd or cawp board, and `-D tcp` for TCP. Never copy the board's condition name into `-D`.
  - Before citing a per-configuration count, check that no record in `data/defects.json` carries `cawd` or `cawp`.
  - The opposite holds for `tools/criteria.py`, which wants the condition name (`4 cawd`). `4 caw` is a different, mostly empty column.
- `trap-an-old-caw-key-is-the-multipath-rig-while-released-caw-was-cawd` (0.90.37 key migration). Before 0.90.37, `N/caw` meant disk/caw/mpath, but every CAW release (0.90.7, 0.90.24, 0.90.36) was graded on `cawd` = disk/caw/direct. `scripts/rekey_invocations.py` mapped the README's `8 caw --release` to `8/disk/caw/mpath`, a configuration that was never released, and it had to be fixed by hand.
  - Map: tcp -> net/mesh/direct, cawd -> disk/caw/direct, caw -> disk/caw/mpath, cawp -> disk/caw/pass, tcpmp -> net/mesh/mpath (`data/configurations.json` retired_keys).
  - TCP history before 2026-09-26 ran on LIO/QNAP (XML-wired /dev/sda), not direct iSCSI.
  - Any mechanical translation of release-claim prose must be checked by hand.

## Board rows that do not measure what they say

Source: `compiled-board-measurement-validity-and-release-gating`. Its central topic: whether a number or a green row on the MXFS release board actually measured what it claims, and how to gate a release on it.

- `tests/suite/fio_perf.sh` runs fio with `--ioengine=libaio --direct=1 --iodepth=32`. `fio_perf` / `fio_perf_vs_xfs` (seqW/seqR/randW/randR as % of XFS) never pass through the buffered write path or writeback. A buffered-write change (0.90.104: cluster-mount buffered write allocates at write time via `xfs_direct_write_iomap_begin`) can sit behind a green "seqW=142%" unmeasured. Measure it with `tests/rig_buffered_write_vs_xfs.sh` (1 GiB buffered `conv=fsync` dd; it reformats the LUN, re-prep with `MXFS_FORCE_PREP=1 ./run.sh 2/net/mesh/direct prep_cluster`). Measured 0.90.104/105: MXFS 0.96-1.07 s, delalloc 0.88-0.89 s, XFS 0.92-0.97 s. The first dd after a mount is slow in every mode (1.4-2.8 s): interleave arms, discard or reverse the first lap. On DRBD the in-flight cap bounds a lone buffered writer. `trap-the-board-fio-perf-rows-write-o-direct-so-a-buffered-path-change-is-never-measured-there`
- The native-XFS yardstick (`tools/xfs_baseline_refresh.sh`) ran solo on an idle host; the MXFS fio rows ran with five other clusters up on the same NVMe plus the user's own jobs. `fio_perf` logs only `hostload=`, and no sysstat history exists, so contention is undetectable afterwards. 4/net/mesh/direct seqW read 1018 MiB/s vs 1992/2024 an hour earlier; calling the iSCSI tuning "PROVEN" from two samples per arm was corrected by the user. Measure both sides of `fio_perf_vs_xfs` under identical host conditions, one group powered up at a time; run a host sampler (`/proc/diskstats` nvme0n1, `/proc/pressure/io`, loadavg every 5 s) into the evidence directory; never name a throughput cause from two samples per arm (pass-to-pass spread inside one run is already 2x). `trap-a-throughput-yardstick-from-an-idle-host-grades-boards-that-ran-beside-other-clusters-and-the-users-load`
- Before writing any test or bench, check `tests/criteria/`, `bench/`, `tools/` for an existing implementation and lift its body. Writing `fio_perf` / `fio_vs_xfs_baseline` fresh dropped the `bench.json` append the existing bench scripts had; perf numbers must land in `bench.json`, not only `criteria.json`. `reuse-existing-criteria-tests`
- A buffered read of the shared device from a node whose module holds it open returns the page cache's first image forever (the module's heartbeat/ledger bios bypass the bdev page cache; an unmounted node's last close flushes it, which is why the tool looked fine there). `disklock_hb_dump.py` with `buffering=0` showed a frozen slot 2 `ts_ms` while `dd iflag=direct` showed the live heartbeat; `prep_heartbeat_writer_guard` was vacuous. Read shared block devices with O_DIRECT (`os.open(O_RDONLY|O_DIRECT)` + `mmap` + `os.preadv`; `dd iflag=direct` on whole sectors then `od -j`; `bs=1` cannot be direct). Values fixed at mkfs may be read buffered if the script says so. Harnesses that dumped heartbeats from a mounted node before 0.89.4 may have judged a stale image. `trap-a-buffered-read-of-the-shared-device-on-a-node-whose-module-holds-it-open-returns-the-page-caches-first-image-forever`
- fio `--filename` splits on `:`. `raw_fio_ceiling.sh` escaped the by-path device once; the remote shell behind `ssh node "..."` ate the backslash, fio created fragment files in the ssh cwd (22 GB in `/root`), filled the node root disk, and every later prep failed with a misleading "md5 never matched (NFS staleness)". It also reported an impossible 5000 MiB/s on 1 GbE iSCSI. Fix: two backslashes in the command string (`${DEV//:/\\\\:}`) or `readlink -f` on the node, plus a post-run check for fragment files. On a repeating md5-mismatch prep failure, check `df -h /` on the node before blaming NFS. The bogus qnap TCP ceiling must be re-measured before `fio_perf_vs_xfs` (wsrc=raw-ceiling) means anything. `trap-fio-by-path-filename-colon-split-survives-one-escape-level-ssh-eats-backslash-fills-node-root-disk`

## Harness measurement-integrity techniques

Source: `compiled-harness-measurement-integrity-clock-anchors-field-readers-vacuous-injectors-and-hang-fix-verification`. Five harness and measurement-integrity techniques share one theme: a number or a verdict is only as good as the check that the instrument measured what it claims. Each one is a way a lap produced a graded result that meant nothing, or a way to catch that before it did.

### Cross-node timestamps (clock anchoring)

`technique-reconcile-two-nodes-module-timestamps-through-proc-uptime-and-check-the-anchor-against-the-same-lines-dmesg-prefix`

- Every `*_ms` field the module prints (`deadline_ms`, `now_ms`, `anchor_ms`, `issued_ms`, `last_ok_ms`) is `mxfs_pal_time_ms()` = `ktime_get_boottime_ns()/1e6` (`pal/linux/kern.c:2970`). It is boot-relative, so two nodes' values are on unrelated origins. Subtracting one node's value from another's yields a number that looks like seconds and means nothing.
- Anchor each node in ONE remote command: `printf 'ANCHOR up=%s wall=%s\n' "$(cut -d' ' -f1 /proc/uptime)" "$(date +%s.%N)"`. `wall_at_boot = wall - up`; any boottime-ms value becomes wall seconds as `wall_at_boot + ms/1000`. `/proc/uptime` is the same clock as boottime. NTP skew of a few ms is irrelevant against windows of seconds.
- Check the anchor, never trust it. A kernel line carrying `now_ms` also carries a dmesg prefix (`[ 5169.041]`). Convert both through the same anchor; they must land on the same wall instant. If they differ by more than a few seconds, ABORT. The node suspended, the clock stepped, or dmesg's `local_clock` differs from boottime. Reporting a margin anyway reports arithmetic, not a measurement.
- Implemented in `tests/authority_handoff_phase.sh` (`anchor_of`, `wall_of`, `dmesg_wall`, `ANCHOR_TOL_S` gate).

### Harness field readers

`trap-a-line-anchored-field-reader-silently-empties-every-field-after-the-first-on-a-multi-field-line`

- Sixteen fence harnesses carried `field(){ grep -ao "^$2=[^ ]*" ... }`. The `measure` convention prints several fields per line (`SEEN=1 PAUSED=1`); the `^` anchor makes only the first readable and every later field comes back empty.
- `ck` correctly refuses to grade an empty value and aborts the lap, so a healthy lap aborted at an assertion about a subsystem that worked (`PAUSED=1` was sitting in the capture file). The reader lied, not `ck`.
- Fix (0.89.20, all sixteen): `grep -aoE "(^| )$2=[^ ]*"`. When adding a field to an existing arm's print, verify the reader can see it; nothing warns.

### Fault injectors that can be armed into a no-op

`technique-a-fault-injector-that-can-be-armed-into-a-no-op-must-decline-loudly-and-before-the-destructive-step`

- Case: the partial-replay cut (submit N of the queued buffers, withhold the rest). If N >= queued there is no suffix and the experiment silently becomes its own control.
- The module counts the queue, refuses a cut that leaves no suffix or no prefix, prints `P-DBG-REPLAY-CUT-VACUOUS` with both numbers, then submits normally so the filesystem stays consistent. The harness checks for that line between capturing the prover's window and destroying the prover VM.
- First lap: `want=8 queued=1`, cost 137 s; without the guard, two VM boots, ~20 min and a verdict on a cut that never happened.
- Three properties: the injector decides vacuity (only it sees the runtime quantity; a harness prediction is a guess); it declines loudly and proceeds safely (silent no-op or silent best-effort both produce a graded lap); the check precedes the irreversible step.
- Generalises to any injector whose effect depends on a runtime quantity: torn record at byte K, kill after N of M, a delay shorter than what it delays.

### Verifying a hang fix

`technique-verify-a-hang-fix-by-timing-the-operation-that-hung-not-by-the-absence-of-the-hang`

- A lap that completes without hanging is weak evidence; it may never have attempted the blocking operation. Run the exact operation that hung, bounded by a derived `timeout`, and record wall time and rc on both builds.
- D-FENCE-POSTSUBMIT-AMBIGUITY-NO-RECONCILIATION-381: `stat` through the mount retried 764 693 ms and climbing before, EIO in 4 s after. `umount`+`rmmod` hung before (module unreleasable, only `virsh destroy` cleared it), after `UMOUNT_RC=0 MOUNTED_AFTER=0 RMMOD_RC=0 MODULE_PRESENT=0` in 3 s.
- A probe counter 0 before and 1 after (`P240-RBLK-EIO-ABORT`) names the mechanism that changed and outweighs any wall-clock number.
- Fold the check into the harness, bounded, so the fix cannot regress unnoticed. An unbounded `umount` on a wedged filesystem makes the check the next wedge.

### Attributing an inode to a lap round after the volume is gone

`technique-a-single-node-directory-rotor-anchors-which-lap-round-created-an-ags-first-inode`

- D-0957: a cold `chk_mxfs` found AG 4 agino 128 (ino 33554560) inobt-allocated with a chunk-init core (mode 0, changecount 0); the volume had been re-mkfs'd many times and dmesg had rotated.
- agino 128 is the first inode of an AG's first aligned chunk on this geometry (512-byte inodes, 8-block alignment, first chunk at agblock 16). In `xfs_ialloc.c` the directory AG is pinned to the node slot under multi-node membership and steps `(node_slot + m_agirotor++) % maxagi` only when single-node. During a sole-survivor phase every mkdir advances the AG by one, including a harness `mkdir -p probe && rmdir probe`. The rotor is per mount and survives across laps while mounted.
- Two logged anchors (P-CR3-CANCEL parents: round 1 = AG 11, round 3 = AG 13) plus counting mkdirs backwards placed the earlier lap's round 3 in AG 4, a knob=1 round of the partial-write-filter-without-grants arm.
- Rules: count every mkdir including probes and rmdir'd scratch dirs; the walk is valid only across the single-node span; record the assumption (one mkdir per round, one probe mkdir per sole phase) next to the conclusion since it is inference, not a platter read; a knob toggled per round whose later flush lands an earlier dropped image strands fewer objects than there are knob=1 rounds, so one stranded directory out of three is the expected shape.

## XFS-fork traps and technique from the same investigations

Source: `compiled-board-measurement-validity-and-release-gating`. The four bullets below are loosely related XFS-fork traps and an instrumentation technique that surfaced in the same board/wedge investigations.

- Delalloc is a per-node promise: `xfs_bmapi_reserve_delalloc` -> `xfs_dec_freecounter` is local, so near full both hosts accept the same last blocks, and the second writeback gets ENOSPC in `xfs_bmapi_convert_delalloc`, producing "page discard" on both hosts and a failed fsync (`tests/pve_delalloc_overcommit.sh`). 0.90.104 fix: on a cluster mount route `xfs_buffered_write_iomap_begin` to `xfs_direct_write_iomap_begin` (allocation at write time under AG locks, ENOSPC at write()); `dbg_cluster_delalloc=1` restores delalloc for A/B; about 14% cost on small-file churn. Any per-node reservation of a shared resource needs a cluster-wide grant or conversion to the real allocation under the shared lock. `trap-delalloc-is-a-per-node-promise-two-hosts-promise-the-same-blocks-and-writeback-discards-data`
- An AIL-stuck buffer with `bflags=0x500020` (`_XBF_DELWRI_Q` bit 22 | `_XBF_MXFS_ALLOC_QUEUED` bit 20 | `XBF_DONE`), `ops=xfs_inode len=32`, `pin=0`, `dwskip_n=1 dwskip_why=2` is a fresh inode-cluster buffer parked on `pag_mxfs_alloc_buflist`; xfsaild cannot write it (it reports FLUSHING) and only an alloc-list drain does (next unlock of that AG, BAST release, force-release). An AG held but unused has none until unmount: log tail pinned nine minutes, put_super's whole-AIL wait never ending. 0.90.16: put_super drains all alloc lists before the wait (`mxfs_dlm_ag_drain_all_alloc_buflists`) and the nowait drain schedules a bounded retry (`m_mxfs_alloclist_retry`). Do not read `xfs_ail_push_ag_sync`'s skip of both-flag buffers as "handled". `trap-an-ail-item-flagged-delwri-queued-and-alloc-queued-sits-on-the-per-ag-alloc-list-and-only-a-drain-writes-it`
- `XFS_BLI_INODE_ALLOC_BUF` is sticky: set by `xfs_trans_inode_alloc_buf()` and never cleared, and the buf log item is buffer-scoped, so a later unlink's `di_next_unlinked` image reads `bli_flags=0x5a`. `mxfs_buf_iunlink_ag_authorized` excluded that flag, so shape B fired zero times while 14 inode-cluster images went out unauthorized; one unauthorized image ATOMIC-SKIPs the transaction, replay is POLICY-REFUSED (-117), and the AG mask is quarantined cluster-wide. The flag carries ordering/lifetime semantics, not recovery semantics. On v5 gate on `xfs_has_v3inodes()` (the wire `XFS_BLF_INODE_BUF` is set unconditionally and allocation images are ordered, never physically logged), not `xfs_has_crc()`. Read `P227-TOKENSUM` `dino_none` vs `dino_agsib` before theorising. `trap-xfs-bli-inode-alloc-buf-is-sticky-so-a-later-unlink-on-that-cluster-still-carries-the-allocation-flag`
- Technique: when a symptom surfaces seconds to minutes after a cause on an object many paths touch, record the last mutator inside the object at the one funnel (`xfs_buf_stale`: `__builtin_return_address(0)`, flags before the change, attached item count, ms stamp), print a rate-limited line at the funnel when suspicious, and print the stored fields in every report that can meet the object (the unmount stuck report `mxfs_buf_diag_dump` initially did not). The per-buffer event ring keeps only the low 16 flag bits and `_XBF_DELWRI_Q` is bit 22, so store full prior flags. Write the prediction (caller, flag bit, falsifier) before the run. `technique-record-the-last-mutator-inside-the-object-so-the-later-stuck-report-names-it`
