---
name: compiled-rig-group-config-lock-collision
description: Two rig groups on the SAME configuration collide on run.sh's non-blocking /tmp/mxfs_config.<slug>.lock; use different configurations or serialize.
metadata:
  type: feedback
tags: [compiled, rig, harness, run.sh, lock, groups]
---

Assorted-tail group of one note, so the topic is only what that note covers: the rig harness's per-configuration lock (`runlock_config`) and the collision when two groups run the same configuration. Source: `trap-two-rig-groups-on-one-configuration-collide-on-its-nonblocking-config-lock`.

## Mechanism

- `tests/lib/runlock.sh` `runlock_config` takes `/tmp/mxfs_config.<slug>.lock` with `flock -n` (no wait), so the lock is non-blocking.
- Every `run.sh <configuration> --group <g> ...` call holds it for its own lifetime: `prep_cluster`, `chk_clean`, any row.
- The lock is per configuration, not per group. Two groups on the same configuration at once, e.g. `g2` and a second two-node group both on `2/net/mesh/direct`, collide whenever their `run.sh` calls overlap.

Cited: `trap-two-rig-groups-on-one-configuration-collide-on-its-nonblocking-config-lock`

## What a collision looks like

- Because the lock is non-blocking, the later call loses (the later `prep_cluster` / `chk_clean` aborts rather than waiting). The loser prints `ERROR: configuration 2-net-mesh-direct is held by another run: <pid> ... --group <other>` and exits.
- Harnesses that wrap `run.sh` then report `RESULT: ABORT stage=prep`, or read their cold audit as `STALE`. `tests/noino_gen0_ab.sh` did both (2026-10-17).
- A `STALE` audit or a prep `ABORT` that names another group's run is this collision, not a filesystem result.

Cited: `trap-two-rig-groups-on-one-configuration-collide-on-its-nonblocking-config-lock`

## Apply

- Give concurrent experiments on different groups DIFFERENT configurations: e.g. one on `2/net/mesh/direct`, the other on `2/net/mesh/mpath` (same TCP lock network, but a separate lock and board column).
- Or run them one after the other.

Cited: `trap-two-rig-groups-on-one-configuration-collide-on-its-nonblocking-config-lock`

## Related

- The lab file `~/.config/mxfslab/lab` gained `group g2c=test29,test30` (2026-10-17) for a third two-node pair. It only helps when `g2c`'s configuration differs from what `g2`/`g2b` are running.

Cited: `trap-two-rig-groups-on-one-configuration-collide-on-its-nonblocking-config-lock`
