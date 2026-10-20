<!-- RULE: CONSULT ANOTHER MODEL WHEN STUCK ruling (D-0349): take the per-create durable reserve commit off the create path by batched reserve-ahead (K=32), gated on grouped-commit wall time -->
# D-0349 ruling — batched inode-number reserve-ahead

Design put to GPT with the measured split: on 2/net/mesh/direct a single-threaded
8714-file rsync with the peer mounted takes 36-55 s against 6.87 s native; the
allocator's EX NOQUEUE reserve of each new inode number is 40.5 of the 51.5 s in
`xfs_create` (3.8 ms per call); the ledger counts one durable grant commit per
create at the number's master (1.27 ms each) and every release at unmount. The
2x-native bar leaves ~0.8 ms of MXFS cost per create, so one commit per create
cannot fit whatever else is removed.

## Ranking

1. **(A) Batched reserve-ahead** — adopt. Reserve up to K eligible free numbers
   of an inobt record in one multi-resource NOQUEUE request per master; each item
   is granted only once its own page transition is durable; pages share barrier
   phases (group commit). Creates consume grants already cached.
2. **(B) Locality routing** of inode resources (home page from AG/chunk, not the
   seeded hash) — only later, on top of A, as a new routing geometry with a hard
   mixed-version gate. Two pages cannot hold a 64-number chunk (31 records each):
   at least three shards with a mapping that caps each at 31.
3. **(C) Chunk range grant** — a full delegation protocol (parent intent visible
   to every child master, drain before grant, recall); only after A is exhausted.
4. **(D) Volatile reserve** — rejected: allocating on a reserve that a master
   death can forget lets two creators own one number.

## What makes A sound

- Durable-before-deliver per item; a batch is never atomic across pages; partial
  success is normal and every item has its own status (GRANTED_NEW,
  GRANTED_EXISTING, DENIED_CONFLICT, DENIED_CAPACITY, REMASTER/RETRY_PAGE,
  STALE_VIEW, STALE_SESSION, IO_ERROR).
- **An EX grant on a free number is an exclusion claim only.** It must never
  certify an inode image for replay; replay authority also needs the allocation
  or live-incarnation record tied to the logged inode. A manifest whose only
  entries are unused reserves certifies nothing.
- A committed grant whose reply was lost is idempotent for the same requester
  incarnation (GRANTED_EXISTING, no second commit); a new incarnation never
  inherits it; a dead requester's grants are released only after it is fenced.
- **Node-local ownership of a cached reserve.** A grant cached on the node is not
  free for every local allocator: record which allocation stream owns each
  reserved number, and on consumption take the AG lock, check that ownership,
  revalidate the number is still free, then move it to ALLOCATING before the
  inobt transaction. Do not hold the AG lock across the batch's ledger wait;
  BAST/release processing must not need the AG lock.
- No DEMAND in a speculative batch (a create that runs dry falls back to today's
  single reserve, counted). DENIED_CONFLICT is not retried in the batch loop.

## Bounds and give-back

- K=32 first (refill below 8 left), K=64 only as a measured variant.
- Unused reserves: at most 64 per allocation window, 1024 per node, about 10% of
  ledger records cluster-wide, at most 8 speculative records per page and none
  past a page occupancy high-water mark (27/31), so live and recovery locks keep
  room. The master must know a record is speculative durably (a record flag or
  equivalent), not only in memory.
- Give back (durably, in background batches, with hysteresis) on a peer's
  conflicting probe (which must BAST the holder; speculative reserves are
  released before live cached grants), window abandoned, quota or occupancy
  pressure, idle interval, inode-cache shrink, unmount. Expiry triggers a
  voluntary release; it is never what makes the exclusion end.

## First-touch pages

Proactive preparation is sound under the earlier bootstrap ruling
(`d0349-eager-page-activation.md`): only the fenced bootstrap node makes the
UNOWNED -> PREPARED(target, view) transition, from a bounded dedup queue keyed by
(page, view epoch, target) drained by a ledger-I/O worker, grouped, bound to the
view epoch (discard on view change), in the background with bounded I/O, never
blocking mount; foreground requests join the queued item instead of re-asking.

## The gate that decides whether A can meet the bar

Grouping barriers is not enough if the page operations of a batch still run one
after another: K=32 must finish in about 12 ms (8 ms for margin) to keep ledger
cost under 0.4 ms per create. Measure batch wall time and page-operation
concurrency before building the protocol; if 32 scattered pages take near
32 x 1.27 ms, the grouped commit's per-page concurrency is the first thing to fix.

## Proof required

Crash matrix at every durable phase of grant, release and cancel batches (page
master, requester, bootstrap, both); recovery-authority laps where unused
reserves exist at the creator's death; same-node multi-stream allocator races;
fairness/capacity laps (an idle reserver must release promptly under a peer's
allocation); first-touch under view churn; and the rsync bench under the 2x line
with counters for batch size, pages per batch, batch wall, fallbacks, retries,
unused high-water and conflict-to-release latency.
