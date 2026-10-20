---
name: compiled-capped-probe-absence-is-not-evidence
description: An absent probe line proves nothing once that probe's per-boot cap is spent; check whole-stream count and last timestamp (sess54 misread)
metadata:
  type: feedback
tags: [compiled, trap, probes, dmesg, evidence]
---

Assorted group (kind: assorted: one note the clusterer could not fit to a topic, no siblings). Common subject: what a missing probe line in an MXFS dmesg stream does and does not prove.

## Rule

An inode-specific probe line missing from a stream is not evidence when that probe's per-boot cap was spent earlier. Before reading "no line for X after time T" as a fact, establish that the probe could still print at T. `trap-capped-probe-absence-after-cap-is-spent`

## Which probes stop printing

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

## What it cost: the D-FREED-INODE-HOME misread (session 54, corrected session 55)

- Session 54 concluded "the peer never wrote its free to disk before the unlinker got the lock" (ng0rf1, D-FREED-INODE-HOME) from the absence of P-FREEPUB / P55C / P170-CLWR lines for one inode after its free.
- On that node every one of those probes had already hit its cap about 45 s before the free: last lines at 2515.6 s and 2517.3 s; the free at 2562.5 s.
- The "second fault" session 54 built on that absence, and its claim that the epoch guard could not cover the case, had no evidence behind them.
- Session 55 corrected the record.

`trap-capped-probe-absence-after-cap-is-spent`

## How to apply

1. Before reading "no line for X after time T" as a fact, run per probe and per node the whole-stream count and the last timestamp: `zcat <node>_dmesg_stream.gz | grep -a -- '<TAG>' | awk` (awk reduces to first, last, count).
2. If the count equals the cap, or the last line is before T, the absence says nothing.
3. Use the module's counters or an uncapped probe instead.
4. A harness that grades on a probe line must reset or raise its cap, or grade on a counter.

`trap-capped-probe-absence-after-cap-is-spent`
