---
name: compiled-scst-abort-hold-3x-timeout-and-chain-reprep-drops-modargs
description: iscsi-scst/libiscsi hold TMF-aborted cmds 3x timeout; fio exit != writes returned; chain's own prep_cluster drops unexported MXFS_EXTRA_MODARGS
metadata:
  type: feedback
tags: [compiled, scst, libiscsi, tas, fio, modargs, lap-chain, fenced-victim-withdraw]
---

# Fenced-victim-withdraw rig traps: a verdict read from the wrong witness (a prep's read-back, fio's exit) instead of the effect inside the row

Assorted group (no tighter topic fit): two traps from the TAS (Task Aborted Status) line of the D-FENCED-VICTIM-WITHDRAW investigation on the clyde rig. What they share: a reading that looked like success (a control arm that PASSed; held_ms=0 from fio's exit) did not measure what it appeared to. Grade on the effect observed inside the row's own window.

## 1. A chain's own `prep_cluster` drops an `MXFS_EXTRA_MODARGS` knob that was not exported

Source: `trap-board-chain-reprep-drops-unexported-modargs`. Measured 2026-10-16.

- Trap: a module knob passed as `MXFS_EXTRA_MODARGS=... ./run.sh <cfg> --group <g> prep_cluster` and then a `tests/mpath/lap_chain.sh laps ...` (board_4node_chain.sh) lap. `tests/board_4node_chain.sh` and the `lap_chain` laps run their own `prep_cluster` first. The chain's first step is its OWN `prep_cluster`, which reloads mxfs.ko with whatever `MXFS_EXTRA_MODARGS` is in ITS environment. Unexported, the knob reverts to its default before the row runs.
- Where to see it: `tests/evidence/board_<cfg>_<row>_<group>_<tag>.log` shows the chain's prep as `=== ... ./run.sh <cfg> --group <g> prep_cluster ===`.
- Measured instance (D-FENCED-VICTIM-WITHDRAW, `scsi_tas_set` A/B): the control arm's prep logged `P303-FENCECAP-TAS set=0 tas_on=0`; 48 s later the chain's prep logged `set=1 set_now=1` and the row ran with TAS on - a vacuous control that read PASS.
- Do: `export MXFS_EXTRA_MODARGS=...` for the whole arm (prep and lap). Grade the arm on the knob's EFFECT read inside the row's own window (here: the Control mode page read just before the freeze), never on the prep's read-back.
- This resolves the "mechanism not established" in [[compiled-rig-prep-traps-nologin-banner-as-srcversion-and-knob-state-lost-before-the-board]] item 3 for chain runs.
- Related trap, same run: `ssh node "a && nohup setsid b > out 2>&1 &"` backgrounds the whole `a && b` list in a subshell whose stdout is the ssh channel, so ssh returns only when b exits. Group it: `a && { nohup setsid b </dev/null >out 2>&1 & }`.

## 2. iscsi-scst drops commands another initiator's TMF aborted; libiscsi holds each for 3 x its request timeout; fio's exit is not write return

Source: `trap-scst-aborted-commands-held-3x-timeout-and-fio-exit-is-not-write-return`. Measured 2026-10-17 (D-FENCED-VICTIM-WITHDRAW-HANGS, D-A-BYSTANDER-INITIATOR).

Target (iscsi-scst):
- A PREEMPT AND ABORT or LU RESET from another initiator makes iscsi-scst release this node's queued commands with NO response, whatever the Control mode page TAS bit says: `iscsi_on_abort_cmd` -> `ISCSI_CMD_ABORTED`; `iscsi_xmit_response` drops it.
- Turning TAS on fixed nothing (refuted A/B, code withdrawn).

Initiator (Linux libiscsi):
- It then holds each such command exactly 3 x its request timeout (`iscsi_eh_cmd_timed_out`: "making progress" reset, transport-check reset, then EH abort -> retry). `cmd_age=90s` at 30 s, `540s` at 180 s.
- Trace it with the `iscsi:iscsi_dbg_eh` tracepoints, which fire even with `debug_libiscsi_eh=0`.

Measuring:
- fio's exit is NOT "every write returned": a lap scored held_ms=0 by fio's exit had a write outstanding on a path that returned 90 s later.
- Measure with `/sys/block/<path>/inflight` and the `cmd_age=` the midlayer prints on the failed command.

Releasing held writes:
- `sg_reset -H` does nothing on iscsi_tcp (no `eh_host_reset_handler`).
- Killing the node's own session TCP connection (`ss -K dst addr dport = :port sport = :local_port`) makes libiscsi requeue and iscsid recover the same session: held writes return in ms, no TMF to the target.

Do not lower the timeout:
- Do not lower the 180 s device timeout or provoke nexus loss casually on clyde: the 180 s exists because EH escalation to nexus loss during SCST serialized-CAW drains leaked D-state `iscsi_conn_cleanup` and wedged the LUN (host reset). Check `/proc/*/stat` for D-state scst/iscsi tasks after any such experiment.
