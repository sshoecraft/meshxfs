---
name: compiled-platform-rig-harness-traps
description: Assorted rig-harness traps: unheld pool VMs shut off by release helpers, stale board read-back, packaged-round transport residue in modprobe.d.
metadata:
  type: feedback
tags: [compiled, trap, harness, platform, release, transport]
---

Assorted group (loosely related): three traps in the platform/release test harness, each a case of harness state or a stale artifact being mistaken for a real result.

## 1. Unheld platform VMs are shut off by release helpers mid-round `trap-unheld-platform-vms-are-shut-off-by-release-helpers-mid-round`

**Trap.** `scripts/release.sh` builds packages and runs kernel build checks on the first node of several platform sets (`vm_package_build.sh` on debian12-1 and alma9-1, `vm_kbuild_check.sh` on pve9-1 ...). Each leaves a `tools/vm_pool.sh release --after <pid>` helper that, once release.sh exits and a 600 s grace passes, shuts off any of its VMs that NOBODY HOLDS. `tests/full_verify.sh POWER=1` powered the platform sets with `lab_power.sh` but did not `vmhold_take` them (only the POWER=0 path did), so 0.90.130's first platform run lost pve9-1, alma9-1 and debian12-1 part way through their packaged rounds ("System is going down" pam_nologin banner parsed as kernel names, `dpkg was interrupted`, firewalld not running after the hard stop). Fixed in 0.90.130: full_verify holds the sets in both modes.

**Second-order: killing a platform run leaves residue the next run fails on.** A killed CAW packaged round leaves `force_transport=0` in the conffile `/etc/modprobe.d/mxfs.conf` (kept across reinstalls), so the next TCP round fails "loaded mxfs with force_transport=0"; a node powered off mid-install leaves dpkg half-configured. Before rerunning after a kill: `dpkg --audit` (run `dpkg --configure -a`), check mxfs.conf's force_transport, and firewalld on alma nodes. Also: full_verify POWER=1's group-end `lab_power.sh down` DESTROYS a node still busy (e.g. a manual `dpkg --configure -a` rebuilding DKMS) — repair only after the run has ended.

**Apply:** any script that uses pool VMs must `vmhold_take` them for its whole life (tests/lib/runlock.sh), whatever powers them. When a VM shuts off unexpectedly on clyde, first suspect a `release --after` helper, not the guest.

## 2. A board log's `Total: N PASS` seconds after start is a stale read-back `trap-board-log-total-within-seconds-of-start-is-a-stale-read-back`

**Trap.** `tests/board_4node_chain.sh` always reads the board back with `tools/criteria.py <cfg>` after `run.sh`, whatever `run.sh` did. When `run.sh` refuses before running any row, the chain log still prints `<cfg>: Total: 40 — 40 PASS` — cells stored from an EARLIER build. Common refusal: `lun_pool: no LUN of at least 80G is free` (run.sh takes 20G up to 8 nodes, 80G above; the pool had one 80G LUN and two 16-node boards were in the same wave).

**Seen:** 0.90.130 release chain (2026-10-16): `16/disk/caw/mpath: Total: 40 — 40 PASS` at 00:58:11, three seconds after its run started at 00:58:08; `16/net/mesh/mpath` the same. Neither board had run. `tools/release_status.py` caught it ("not run on the release build"), the chain log did not.

**Apply:**
- Before reading a chain's `Total:` line as a result, check the board log itself (`tests/evidence/board_<cfg>_<group>_<label>.log`) for `=== rc=` and an `ERROR:` before the CRITERIA table, and that the row lines carry this run's timestamps/build.
- A board's wall is minutes (2-node ~25-50 min, 16-node ~20-60 min); a Total within seconds is never a run.
- `tests/release_verify_chain.sh` now caps boards above 8 nodes per wave at the pool's count of >=80G LUNs (0.90.130), but any refusal (node lock, preflight, LUN) still reads back the stale board.

## 3. Package-module tests inherit the transport the last packaged round left `trap-package-module-tests-inherit-the-transport-the-last-packaged-round-left`

`tests/packaged_round.sh` rewrites `/etc/modprobe.d/mxfs.conf` to `force_transport=0` for its CAW configuration and puts 1 back afterwards. A harness that later loads the package with a bare `modprobe mxfs` gets whichever value is in the file at that moment, so two runs of the "same" test can run on different lock transports without saying so.

Bit us on D-JOIN-FREEZE-RELMARK-TRANS-ALLOC-WHILE-FROZEN (0.90.130): the WARN reproduced 3 of 3 at 12:03-12:05 and then 0 of 12 afterwards, read as "timing-dependent". The real difference was the transport: the reach is CAW-only (a lone CAW incumbent holds on-disk tenures with grant epochs; on TCP the newcomer is registered only after the view install). With TRANSPORT=caw it reproduced every time.

**Apply:**
- Any platform harness must pin the transport on the command line (`modprobe mxfs force_transport=N`, which wins over modprobe.d) and print `/sys/module/mxfs/parameters/force_transport` next to srcversion.
- When a defect "stops reproducing", diff the load conditions (transport, params, module identity) before calling it intermittent.
- `tests/join_freeze_userspace_thaw.sh` and `tests/userfreeze_peer_demand.sh` take TRANSPORT=tcp|caw.

Link between 1 and 3: both involve the stale `force_transport` value in `/etc/modprobe.d/mxfs.conf` left by packaged rounds (killed or finished).
