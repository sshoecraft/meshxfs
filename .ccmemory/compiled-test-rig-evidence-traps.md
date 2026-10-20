---
name: compiled-test-rig-evidence-traps
description: Assorted rig/test traps: bash local-line expansion, stale drc_blkdump dirs, SCST reconfig suspend behind frozen guest, frozen-guest uptime offset step
metadata:
  type: feedback
tags: [compiled, trap, tests, rig, bash, scst]
---

Assorted group (kind: assorted, not one topic): four traps that each make test/rig evidence read as an MXFS defect when it is not. Common thread: a verdict built on evidence that is mis-attributed, mis-timed or mis-scripted.

## 1. Bash `local` line expands every word before assigning
`trap-bash-local-line-expands-all-words-before-assigning`

- **Trap.** `local K="$1" D="$BASE/r$K"` expands every word of the line before `local` assigns any, so `$K` in the second assignment is the CALLER's `K` (or empty), not `$1`. `bash -c 'f(){ local K="$1" D="r$K"; echo $D; }; K=30; f 21'` prints `D=r30`.
- **Cost.** `tests/suite/dirent_durability.sh` `verify_round` had exactly this line. Every "verify round J" listed the round being created instead, and the final settle judged every pending round against the LAST round's listing. On the 0.90.131 release build it produced a critical "stale directory view" verdict (D-DIRVIEW-NONCONVERGE-SESS25, 8/disk/caw/direct, run 20261019T214738Z-g8): six round directories convicted with one identical missing set, while the kernel log showed every `ls` reading r30 (inode 4194445) and r21-r26 holding all names on the platter. The original sess25 observation (r21-r28 missing the same 28 peers) has the same signature.
- **Tell.** Several DIFFERENT directories/objects convicted with the IDENTICAL missing set, and the probes for the convicted inodes silent while one other inode logs on every check.
- **Apply.** Write `local K="$1"` and `local D="...$K"` as two statements. Sibling bug: a helper that assigns a global loop variable (`K=$1` without `local`) silently rewrites the caller's loop index for the rest of that iteration (`tests/sf_mkdir_storm.sh`). Scanner used: a python pass over tests/scripts `local|declare|export` lines flagging an assignment whose value references a name declared earlier on the same line.

## 2. `*_drc_blkdump_*` dirs in run evidence can be months-old node leftovers
`trap-drc-blkdump-dirs-in-run-evidence-can-be-months-old-node-leftovers`

- **Trap.** `run.sh` (around line 2017) copies `/root/drc_blkdump_*` from each node into the run's artifact directory (e.g. `run_dirent_durability_<RUNID>/test11_drc_blkdump_dsc_node11/dmesg_at_fail.txt`). Those are written by suite rows' failure dumps (`tests/suite/dlm_scaling.sh:98-101`, `dmesg | tail -n 4000`) into the node's `/root`, which survives reboots and module reloads. A run's evidence can hold a dump from a different boot, weeks earlier.
- **Measured 2026-10-19:** `run_dirent_durability_20261019T191246Z-g8/test11_drc_blkdump_dsc_node11/dmesg_at_fail.txt` showed an XFS `Internal error rec.ir_free != frec->ir_free` (inobt/finobt mismatch) and a corruption shutdown, looking like a new integrity failure during the 19:14Z storage outage. It was not: its uptime (16863 s) did not match the node's boot (~1300 s then), and its `realns=` values decode to 2026-08-20 (`date -u -d @<realns/1e9>`), an old dlm_scaling incident already in the queue.
- **Apply.** Before treating any `*_drc_blkdump_*` file as this run's evidence, check its uptimes fit the node's boot in `kernlog_<node>.gz` and that `realns=` decodes to the run's date. Prefer `kernlog_<node>.gz` / `kmsg_<node>_fromnode.gz`, captured per run.

## 3. SCST reconfig suspends every LUN behind a frozen guest's command
`trap-scst-reconfig-suspends-every-lun-behind-a-frozen-guests-command`

- **Trap.** A write to any SCST management file (add/del device, LUN, initiator, target enable, allowed_portal) calls `scst_suspend_activity(SCST_SUSPEND_TIMEOUT_USER = 90 s)`: SCST stops admitting commands on EVERY LUN it exports and waits for every already-admitted command to finish (`/src/scst/scst/src/scst_main.c:840`). A guest a test froze (virsh suspend), or whose storage path is cut or muted, holds its in-flight command (state PREP_DONE_CALLED for a WRITE waiting for data-out) until its iSCSI connection times out. For that long every LUN on the host stalls, and every MXFS node self-fences (AUTHORITY_LEASE_EXPIRED).
- **Measured 2026-10-19 19:14:14Z** (session a718c549): a `tools/lun_pool.sh` bind of test29/test30 waited 49 s on one WRITE of test18, which path_fenced_return had frozen 12 s before. The 8-node mpath suite, a 4-node and an 8-node lap and a 2-node fence lap all failed together. Host journal: `scst_suspend_activity:881:Waiting for N active commands`, then `scst_susp_wait: ... still not completed` with a per-command dump naming the session, then `All active commands completed`. sar showed no I/O storm (tps dropped).
- **Apply.**
  - When every cluster on clyde fails at once, grep the host journal for `scst_suspend_activity|scst_susp_wait` before suspecting MXFS or an I/O storm.
  - `tools/lun_pool.sh` gates every reconfiguration (scst_quiet_begin: no paused guest, no storage NIC link down, no netem mute, read from virsh/tc). Every fault injector must go through `tools/lun_pool.sh fault <command>`, or `fault-lock` for a shell-function injector such as QMP. A new test that freezes a guest or cuts a path and skips that gate reopens the race.
  - `tools/lun_pool.sh faults` prints what would hold a reconfiguration back; `tests/scst_reconfig_fault_gate.sh` verifies the gate.
  - A short suspend with nothing stuck is normal (dozens a day); it only hurts when a command cannot finish.

## 4. Frozen-guest uptime stops, so the cross-node offset steps by the freeze
`trap-frozen-guest-uptime-stops-so-cross-node-offset-steps-by-the-freeze`

- **Trap.** A rig row that freezes a guest (path_fenced_return: virsh suspend, then resume) stops that guest's kernel clock (kvmclock) for the whole freeze. Its uptime does not advance, so the uptime offset between it and any other node is one number before the freeze and another after; the step equals the freeze length.
- **Seen** 0.90.131 lap 9 (board_20261019T141313Z_path_fenced_return): test1-test2 offset was 352.5 s on every protocol pair before the freeze and 396.5 s after, a 44.0 s step against a 14:14:16-14:14:59 freeze. A record built on one offset (388.5 s, taken just after the thaw) placed test2's pre-row mount (incarnation 2128268000, slot claimed before the row's PF-MARK) as a remount after the thaw. It then read the row's own fence of that frozen incarnation as "the rejoined node declared dead 70 s later", and read the injected path-a outage (heartbeat LOCKWAIT 14.4 s) as an unexplained stall. That opened a release-blocking record, D-NETMESH-MPATH-REJOINED-NODE-HEARTBEAT-LOCKWAIT-STALL-DECLARED-DEAD, later DISPROVED.
- **Apply.**
  - Before ordering two nodes' events across a freeze or fence, take offset pairs on BOTH sides: join/MEMBERSHIP before, reconnect/departure after. If they differ, the frozen node's clock stopped; place each event with the offset of its own side.
  - Identify incarnations by node id: the `claimed heartbeat slot N for node <id>` line, compared against the row's PF-MARK. A death declaration names an id; check whether it is the frozen one or the rejoined one before calling it unexpected.
  - Map a heartbeat stall onto links.log (the row's path down/up times) before treating it as a defect. A LOCKWAIT that ends with multipath `Failing path` is the injected outage.
