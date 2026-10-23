---
name: trap-concurrent-lane-starts-flood-scst-log-and-fail-the-host-preflight
description: Two rig lanes started seconds apart: one's pool-LUN allocation floods clyde's kernel log (88 lines/s), the other's prep fails the preflight
metadata:
  type: feedback
---

**What happened (2026-10-23, lanes g4_spd_window20 and g8_spd_window20, started 3 s apart).** g8's `lun_pool.sh` allocation created its pool LUN while g4's step 2 ran `MXFS_FORCE_PREP=1 ./run.sh 4/disk/caw/mpath --group g4 prep_cluster`. SCST started one `scst_cmd_thread` per CPU for the new device (128 lines) and 16 iSCSI sessions logged in, so `scripts/clyde_preflight.sh` measured the host kernel log at ~88 lines/s against its 40 limit and run.sh aborted the prep (rc=3). That is the preflight working: never widen or skip it.

**The trap is what came after.** The lane does not stop on a failed step, so g4's next three steps (`./run.sh 4/disk/caw/mpath ... path_*`) each refused at once: `ERROR: cluster is prepped for 4/net/mesh/mpath (srcver=16A5...)`, the marker an older lane left. Three rows of measurement were lost, and nothing in the summary said why except rc=1 in 9-22 s.

**Apply:**
- Start rig lanes at least a minute apart, or after the previous lane's prep step has ended (its `step 2 end` line in `summary.log`), so no pool LUN is being created while another lane's preflight samples the log.
- A lane step that ends rc=1 in seconds is not a measurement: read its `step<N>.log` before trusting the lane. Look for the run.sh refusal or `clyde_preflight: FAIL` first.
- Before reading a flood as a host fault, tally the host's kernel lines for that window (`sudo dmesg --time-format iso`, the lines grouped by their text with numbers masked). The SCST thread starts and iSCSI logins of a pool allocation are transient; anything else repeating is the real fault the preflight exists to catch.
