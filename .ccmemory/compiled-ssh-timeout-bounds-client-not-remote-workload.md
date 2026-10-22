---
name: compiled-ssh-timeout-bounds-client-not-remote-workload
description: Local `timeout N ssh` kills only the ssh client; remote loop runs on, umount busy, fuser -km misses it; bound on the node, tear down by state
metadata:
  type: feedback
tags: [compiled, harness, ssh, timeout, rig, teardown, drbd, trap]
---

Assorted tail group (one note, no sibling topic): a local `timeout N ssh <node> "<cmd>"` bound stops the ssh client, not the node's workload. How it wedged a DRBD rig arm, and how to bound and tear down instead. `trap-a-local-timeout-around-ssh-leaves-the-remote-workload-running`

## Trap

A harness that bounds a node workload as `timeout N ssh <node> "<loop>"` stops only the local ssh client at the bound. That covers every `ssh_n` / `on <node> <cmd> <bound>` helper in `scripts/drbd_rig.sh`, `tests/fourkn_merge_2node.sh` and most laps. The remote command has no pty, so it gets no SIGHUP; a bash loop that writes nothing until it ends keeps running on the node, its result line lost. `trap-a-local-timeout-around-ssh-leaves-the-remote-workload-running`

## What it did

0.90.134, `scripts/drbd_rig.sh fourkn-test`, evidence `tests/evidence/drbd_rig/20261022T140512Z-fourkn-test`. `trap-a-local-timeout-around-ssh-leaves-the-remote-workload-running`

- The 512 arm's merge workers overran their 19 s bound; they needed ~95 s on DRBD.
- The harness went on to unmount: `umount: target is busy` on both nodes.
- Its teardown ran `fuser -km` and found nothing. Between steps the worker bash holds no file open on the mount; a moment later its next `chmod` does.
- `drbdadm down` then could not take the minor down.
- The 4096 arm's `drbdmeta create-md` refused (`Device '20' is configured!`), and the arm under test never ran.
- The workers finished on their own 90 s later.

## Apply

`trap-a-local-timeout-around-ssh-leaves-the-remote-workload-running`

- Bound the workload ON THE NODE: `echo $$ > /root/<x>.pid; exec timeout --foreground <bound> <worker>`, with the local ssh bound = node bound + the release policy's `stall_limit_s` + ssh connect.
- `--foreground` signals only the worker shell, not the chmod/stat it waits on. A worker that traps TERM (`trap 'stop=1' TERM`, checked between steps) stops after the step in hand and can report exactly what it changed: `tests/fourkn_merge_worker.sh` prints `MODE <i> <mode>` per file and `WORKER_STOPPED`, so a pace failure still gets a correctness verdict.
- Teardown kills a leftover by that pidfile, only if `/proc/<pid>/comm` is still `timeout`, and waits for it; never `pkill`.
- Teardown success is read from state (mount gone, minor gone from `/proc/drbd`), never from a command's ignored exit; the next arm does not start on a node that failed it.
- When diagnosing, a `/proc/*/cmdline` scan for the worker's name also matches the diagnostic shell itself (its own command line contains the name): exclude `$$` or match the interpreter path, or the scan reports a live worker that has already exited.
