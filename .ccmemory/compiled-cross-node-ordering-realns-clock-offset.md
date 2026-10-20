---
name: compiled-cross-node-ordering-realns-clock-offset
description: Rig guests' realns clocks disagree ~20 ms; order cross-node events <50 ms apart via uptime offset bounded by protocol-forced causal pairs
metadata:
  type: feedback
tags: [compiled, rig, measurement, clocks, cross-node, timeline, realns]
---

Assorted group (the tail the clusterer could not fit to a topic): one note, about a single subject — ordering events that happened on different rig nodes when the only stamps are the guests' own wall clocks.

## Trap: guest realns clocks are only loosely synced

The `realns=`/`realms=` fields MXFS probes print are each guest's own CLOCK_REALTIME. Guests on clyde are NTP-synced, but only loosely. They disagree by tens of ms (~20 ms measured below), so a realns-based cross-node order is unreliable for events closer than ~50 ms. `trap-guest-realns-disagree-tens-of-ms-bound-offset-from-causal-pairs`

## Measured case: kwf2 (g2b, test15/test16, 2026-10-18) `trap-guest-realns-disagree-tens-of-ms-bound-offset-from-causal-pairs`

- The realns-derived uptime offset said test16 = test15 - 0.2425 s.
- Two causal pairs bounded it to -0.2228 < d < -0.2207 s:
  - test15's unlock (P70-BP EXIT) must precede test16's grant (P138-ACQ after a 182 ms wait);
  - test16's P6H-HANDOFF must precede test15's P6H-ADOPT (realns put the adopt 20 ms BEFORE the handoff).
- So realns was off by ~20 ms, enough to put a peer's removal after the write that clobbered it, or a grant before the release it waited for.
- Arithmetic on those figures: the bound window is 2.1 ms wide (hence the +-1 ms bound), and the realns-derived -0.2425 s lies 19.7-21.8 ms outside it.
- An earlier session had concluded "offsets differ by 4.7 ms, so stamps compare directly" from realns alone.

## How to apply `trap-guest-realns-disagree-tens-of-ms-bound-offset-from-causal-pairs`

- When an argument depends on the order of two events on different nodes less than ~50 ms apart, do not order them by realns.
- Find at least one pair on each side that the protocol forces into an order: A's unlock -> B's grant that was waiting; B's handoff -> A's adopt; a BAST receive after the request. (kwf2 used one pair per direction.)
- Compute uptime offset bounds from those pairs, and convert with the bounded offset.
- State the bound (+-1 ms here) with the conclusion.
