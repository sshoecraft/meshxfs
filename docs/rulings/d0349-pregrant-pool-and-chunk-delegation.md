<!-- RULE: CONSULT ANOTHER MODEL WHEN STUCK ruling (D-0349, 2026-10-19): page-aligned batched pre-grants consumed locally can reach ~10-12 s; chunk delegation is the structural answer below that -->
# D-0349 ruling — pre-grant pool vs chunk delegation (2026-10-19, GPT)

Facts given: the both-mounted 8137-file rsync costs ~12 ms a file on the default build (routing v1, no
reserve-ahead), nearly every create's number landing on a ledger page its incarnation never used (a
full page hand-off, then the grant commit); the best measured combination (routing v2, reserve-ahead 32,
group commit, same-page combining) reached 26 s = 6.2x native, with creates still waiting on their own
pre-grant mid-commit, on a remote master's re-affirm of a number already pre-granted, on the
candidate-home platter read (~1 ms a create) and on the ledger page mutex; combining packed ~2.2 grants
per page write. Budget: 2x native, ~1.0-1.4 ms a file all-in. Rig: a TCP round trip ~0.3-0.5 ms, a
platter read ~0.5 ms, a durable page commit 1-3 ms.

## Ruling

- Per-inode durable authority is NOT incompatible with ~1 ms a create, provided up to eight grants are
  committed in ONE page transaction and none of that transaction is on the create path. At 1000
  creates/s fully packed that is 125 page commits/s (12.5-37.5% of the ledger device at 1-3 ms a
  commit); at 2.2 grants a write it is 455/s, over 100% at 3 ms: the current packing cannot sustain the
  rate.
- The pipeline must issue RANGE requests split by page and master and commit every currently free slot
  of a page in one transaction; 32 single-resource requests that may combine are not enough. Pool depth
  512-1024 entries (32 entries cover 32 ms at 1000/s, below ordinary flush jitter).
- Consumption is local and idempotent: a pre-grant has a fixed grant id; a re-request of it returns that
  same grant, not a fresh generation; the release names the exact grant id and master-side request
  sequencing handles a LOCK_RELEASE overtaking a duplicate LOCK_REQ. The current fresh-generation
  re-affirm defeats pre-granting.
- The candidate-home check moves into the refill and works per inode cluster, not per candidate: a
  verdict is bound to {inode number, allocation generation, grant id} and valid only while BOTH the
  number's reservation and the AG exclusion are continuously held; AG EX alone does not exclude an old
  inode writer, delayed writeback or replay, and recovery must have closed every older authority that
  could still write the home before the reservation is issued.
- What may stay on the create's synchronous path: allocation from already locked/cached AG metadata, the
  pool pop and local grant-state transition, the cached verdict check, ordinary logging. No network
  exchange, no ledger mutex wait, no durable authority write, no platter read.
- Expected: about 10-12 s from 26 s. If the fully packed asynchronous refill still measures above about
  11 s, further tuning of per-inode grants will not reliably make 2x across the native 4.2-5.9 s range,
  and chunk delegation is required.

## Chunk delegation, minimal safe form (the structural answer)

- Durable record per aligned 64-inode chunk: owner slot and incarnation, delegation epoch, allocation
  generation, state PREPARING/ACTIVE/CLOSING/CLOSED, allocated-slot bitmap, peer-exception (suspended)
  bitmap, per-slot authority generation where a peer transfer or reuse is possible. No freed slot is
  reused inside an active epoch.
- A delegate's image carries {chunk, delegation epoch, allocation generation, slot, authority
  generation}; the replay gate admits it only when durable history proves that incarnation owned the
  chunk in that epoch, the slot was not suspended to a peer at that authority generation, the epoch was
  not closed before the image and the slot was not reused later. Closed epochs stay in the ledger until
  every slice that could reference them is recovered or discarded.
- While a delegation is ACTIVE the delegate masters every inode resource of the chunk. The hash master
  stays the stable locator: it consults a delegation map cached from the durable record and redirects
  with the epoch; the delegate accepts only the current epoch (a stale redirect answers REMASTER). A
  peer's first stat/open reaches the delegate, which blocks new conflicting local operations and forces
  its journal and inode writeback before granting. A peer EX/PW first durably suspends the slot
  (quiesce, force, commit OWNER_SUSPENDED, commit the peer's ordinary grant, grant); after the peer's
  release the grant is closed, the slot's authority generation bumped and the suspension cleared before
  the delegate writes it again.
- Cases and invariants: delegate death (fence first; freeze the chunk; replay only images whose epoch and
  slot authority validate; commit CLOSED before any new epoch or reuse: no new owner while the old
  incarnation can issue I/O); partition (replacement only after a successful storage fence: a network
  timeout is not revocation); locator death (rebuild routing from the durable record, reject stale
  redirects by epoch: locator state is a cache, the ledger is authority); a peer dying with a slot lock
  (fence, recover or quarantine by its per-inode grant, close it, advance the slot generation before the
  delegate resumes); clean transfer (stop, recall, flush, CLOSING then CLOSED, then the new epoch: epochs
  never overlap).

## Ranked first steps

1. Page-aligned batched pre-grants with local consumption (highest gain, moderate risk). Proof: fewer
   than 140 page commits/s at 1000 allocations/s, packing >= 7 grants a write, > 99.9% of creates
   consuming locally with no TCP and no ledger wait, pool-empty < 0.1%; interim copy under 18 s (above
   20 s means the waits were not removed).
2. Home validation in the refill, per cluster (high gain, moderate-to-high risk): zero synchronous
   candidate reads in xfs_create, the validator >= 1500 candidates/s, crash tests for delayed writeback,
   replay, remaster and lost tenure; a cached verdict never survives a grant or AG-generation loss.
3. Chunk delegation for owner-local creates (largest gain, highest risk): one delegation commit per 64
   inodes, no authority I/O or TCP on the create path, a peer's first access demonstrably waiting for the
   delegate's writeback, the replay fault matrix (delegate crash, peer crash, partition, stale redirect,
   epoch transfer).
