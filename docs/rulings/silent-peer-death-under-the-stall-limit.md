# A silent peer death inside the stall limit

How long survivors may take to carry on after a peer dies without a goodbye (its VM killed, or every
storage path lost), what makes taking over early safe, and what has to change before the death window
can shrink. Record: `D-SILENT-PEER-DEATH-TAKES-35S-TO-DETECT-SO-SURVIVORS-STALL-OVER-30S`.

## The question

On the SCSI attachments a peer declares a node dead after 17 unchanged reads of its disk heartbeat
(2 s apart, 34.8 s measured). That window exists only so that a node whose beats stopped landing has
closed its own 30 s authority lease before anyone declares it dead (`dlm/disklock.h`, the comment above
`MXFS_DISKLOCK_SCSI_DEAD_THRESHOLD`). Survivors resume 7-9 s after the declaration, so a survivor
operation that needs a lock the dead node held stalls 37-61 s, measured at 2, 4, 8 and 16 nodes on both
lock managers. A file operation stall over 30 s is a stability failure (`stall_limit_s`,
`data/release_policy.json`).

The takeover proof was never the lease: replay needs a verified fence certificate (READ KEYS, READ
RESERVATION, PREEMPT AND ABORT of the victim's key, READ KEYS again, the certificate published). The
question put to gpt-6-astra on 2026-10-23, with these numbers and the project's earlier fencing rulings
(`docs/fencing.md`, `docs/pr-fencing-departure.md`), was whether the death window can be decoupled from the lease, what an early
PREEMPT AND ABORT proves, and what that leaves unprotected.

## The ruling

**Suspicion is decoupled from the lease. Taking over is not decoupled from proof that the victim can
no longer write, and can no longer serve cached reads under the grants it held.**

1. **Writes.** A target-confirmed PREEMPT AND ABORT can replace lease expiry as the proof that the
   victim's writes are retired, provided all of this holds for the target, backend and topology
   actually qualified (never "SCST" or "an array family" in general):
   - one PR key per node incarnation, registered on every I_T nexus the victim has (every path, every
     session), with a reservation of a type that rejects an unregistered initiator's writes in place;
     removing a key without a protecting reservation is not a fence;
   - the abort covers every task of every removed nexus, and a write the target already passed to a
     backend that cannot cancel it completes before the fence completes;
   - a command still in the fabric, or queued in the victim's own multipath queue and released later,
     meets the reservation and is rejected. The victim's queue need not drain; whatever leaves it later
     must be harmless;
   - nothing re-registers the victim's key after the preempt (multipathd's registration on path
     restore, reconnect and restart handling included). Registration again is a new incarnation, never
     the old mount carrying on;
   - the survivor that recovers holds the serialized recovery authority; "lowest live slot" is an
     election preference, not partition arbitration.

   With those, no logical victim mutation lands after the certificate. A Linux timeout or EIO proves
   none of it, and a key found already absent is not evidence that the victim's tasks were aborted.

2. **Cached reads.** A PR fence revokes no page cache. A victim cut off from storage keeps serving
   cache hits under grants it still believes it holds, until its own lease closes; if survivors grant a
   conflicting lock first, the victim serves data another node has since changed. That breaks the
   coherence the filesystem promises. **Conflicting recovery mutations and new grants of the victim's
   resources wait for the storage fence certificate AND one of:**
   - the victim's acknowledged read-stop: over the TCP mesh, the victim confirms an epoch-specific
     quiesced state it cannot leave without a new grant (a "you are fenced" message sent is not proof;
     the acknowledgment is);
   - a read-authority lease provably expired: the survivor saw heartbeat value h at its time t0, a read
     after the fence still finds h, beats are serialized and sequence-protected so no newer renewal can
     hide, and the victim renews only from the issue time of a landed beat; then the victim's authority
     ends no later than t0 + lease x 1.001 (two clocks at +-500 ppm) plus the proven time its readers
     take to quiesce. If the final read finds a different value, this proof does not apply;
   - a confirmed host stop (a power-off request is not completion).

   Non-mutating preparation (reading the victim's slice, planning the replay) may start before both
   conditions hold.

3. **The lease.** It has to expire before conflicting access, not before suspicion. Its closure must
   **suspend** the mount (no operation admitted under the old grants, reads included, and no reopening
   because a late beat finally lands), never force an XFS shutdown: shortening a lease whose closure
   shuts the filesystem down only turns path failovers on live nodes into shut-down nodes. Suspension
   has to cover buffered and direct reads, directory and metadata operations, operations that wake after
   the closure, mappings already installed, and asynchronous completions.

4. **The window K is an availability number, not a safety one.** It sets how often a live node is
   wrongly suspected and appears nowhere in the safety argument. No finite K separates an
   indefinitely delayed live node from a dead one. It must exceed the longest supported gap between a
   live node's landed beats, which has not been measured: one hung beat is bounded at 8 s and beats are
   2 s apart, so K = 4 (about 8.2 s) is already inside a single hung beat's reach.

5. **The live loser** is a state machine, ACTIVE -> SUSPENDED -> REVALIDATED or EVICTED, not "abort and
   remount": SUSPENDED keeps the node's state while it is decided whether the same incarnation may
   continue; REVALIDATED resumes only once ownership and dirty state are proven still valid; EVICTED
   invalidates the old grants for good, quarantines old dirty state so it can never flush into a later
   epoch, fails the affected operations and rejoins under control. Losing data a live node accepted
   with `write()` but never made durable is a failure the application must see, never something
   presented as a transparent failover; completed `fsync` guarantees always hold.

6. **The 7-9 s after the declaration** is mostly fixed waits, to be traced before being cut, in this
   order: the TCP lock manager's disconnect-driven 20 s non-NL freeze and its 40 s reconnect grace come
   out of the takeover's critical path (a disconnect is suspicion, not a membership change, and the
   view is confirmed among the new member set); the fixed 3 s seal settle becomes an acknowledged epoch
   barrier with the same correctness condition; certificate publication is one bounded durable write in
   the normal case (its five tries spend 3 s on backoff alone); replay work is bounded by journal and
   admission policy; independent steps run in parallel; PR round trips last. A 60 s PR command timeout
   cannot support a sub-30 s claim, and a shorter Linux timeout proves no retirement: an unresolved
   fence attempt fails closed and keeps reconciling, it never replays.

7. **DRBD and the shared attachment.** A witness naming a winner excludes nothing: the loser may still
   write its replica, serve cached reads or reconnect diverged. Shortening the DRBD window needs the
   witness path to deliver an exclusion as rigorous as the SCSI fence, and read-stop proof unless a
   confirmed host fence supplies it. Manual fencing has no unattended bound at all.

## The safety argument

1. A serialized membership and recovery authority chooses the transition.
2. A verified fence retires every old victim write and blocks every later write of that incarnation.
3. The victim's read authority has provably stopped before any conflicting recovery mutation or grant.
4. Recovery completes durably before the dead node's grants are released and new owners proceed.
5. The loser cannot re-register, expose old caches or flush old dirty state without a validated rejoin.

The death window appears in none of the five.

## The budget it allows

A first shape to measure against, not yet a qualified one: suspicion at K = 5 (10.25 s at the measured
lap); a 12 s read and write authority counted from the beat's issue time, whose closure suspends;
fence, verification and certificate within 2 s; recovery, flush, grant release and membership within
5 s; first unblocked survivor operation by max(11 + 2, 12.6) + 5 = 18 s. The 4 s the current window
allows for the heartbeat pump's lateness does not vanish by itself: either admission and expiry are
enforced where they are used, so a late timer cannot extend authority, or the allowance stays in the
budget (12 + 4 + 5 s is over 20).

## What is measured before K and the lease are chosen

- Each node's beat issue, landing, completion and peer observation at 2, 4, 8 and 16 nodes: the gap
  between landed beats as a distribution with its maximum, not a mean.
- Those gaps on a live node under a single-path failover, path restoration, multipath queueing, a host
  I/O storm, memory or CPU pressure, and a VM pause and resume.
- PR retirement under attack: old writes executing in the target, delayed in the fabric and queued in
  multipath; restored paths; controller failover; no old write over a post-certificate survivor write.
- Cached-read revocation on a victim cut off from storage with its TCP links up: buffered and metadata
  reads and existing mappings against a conflicting survivor change.
- The recovery phases of one unfiltered run of each silent-death row, with a busy victim journal: PR,
  publication, seal, replay size, flushes, membership and the first unblocked operation.
- Detection from the moment of failure, not from the last beat seen: a pre-failure beat that lands late
  resets the stale count and extends detection.

## Keeping the window longer than the lease

A simpler shape was put to gpt-6-astra the same day. It keeps today's invariant (no peer can declare
before the victim's lease ended) and shrinks both numbers, for example L = 8 s and K = 7. At the
deadline the victim suspends instead of shutting down: mutations, reads and lock acquires block at the
gate. It resumes the same incarnation when a beat lands early enough to prove that no peer can have
counted K unchanged reads. It closes and shuts down on a definitive fence signal, or when that proof
can no longer come. Survivors keep their protocol and add no read-stop wait.

The verdict was **unsound as stated**. It can be made sound only on these conditions.

- **The count.** The bound needs K unchanged comparisons *after* the first observation (K intervals).
  K observations of one stamp give only K-1 intervals. The earliest staleness declaration is
  W/(1+e) real seconds after the old beat's issue, with W = K x 2 s and e the clock rate error.
- **Revalidation.** A beat qualifies only if its CAS succeeded and its completion t_c satisfies
  t_c - anchor_old < W(1-e)/(1+e). That is less any further reserve d as (t_c - anchor_old)/(1-e) + d
  < W/(1+e). Completion is a conservative bound on when the write became visible: issue time cannot
  show that a beat queued in multipath executed in time. The check and the state change are one
  synchronized step. Anchor_old is not advanced by the completion being tested. The new deadline must
  still lie in the future when the node is readmitted. No other completion bypasses the check.
  CLOSED stays irreversible for the incarnation. Grants revoked through the lock manager in between are
  not kept. A declaration latched before the certified anchor is never erased by a beat that lands
  later.
- **No survivor-side read-stop wait** only if W/(1+e) > L/(1-e) + d. Here d bounds the victim's
  *completed* quiescence, not the closing of an entry gate. It must cover operations that passed the
  gate, in-flight I/O and asynchronous work, faults racing with unmapping, completed TLB shootdowns and
  CPU or timer stalls. If d cannot be bounded, survivors need an explicit stop proof. A Write Exclusive
  reservation revokes no reads.
- **Every declaration path obeys the bound.** A longer timeout is not enough. A TCP declaration 65 s
  after a link failure can fall inside the lease of a node whose storage beats kept landing. A peer's
  "did you lose the LUN" answer must certify completed closure, not a flag set.
- **What it leaves open.** A beat that executed but whose result the node never saw resets the peers'
  counts while the node cannot revalidate. The node must still close. Delayed queued beats then
  postpone detection further, so shrinking W alone does not bound the stall. Pass duration,
  outstanding beats, multipath delays, fencing, replay and membership removal each need an upper bound.
- **The reservation.** A successful CAS proves registration only under the reservation type and nexus
  coverage actually configured. It is never by itself a membership or no-pending-fence certificate.

## A holder's path failover followed by its death

With the window at 7 checks (14 s, a 10 s lease), every path row whose waiting operation began after
the fault stalled 19.6-24.2 s at 4 and 8 nodes on both lock managers. The one row over the limit was
a compound: at 8 nodes a survivor's operation needed a lock whose holder lost one path, could not
hand the lock back while the flush that must precede the unlock was stuck on the dead path, and then
died. It waited 17.5 s of the holder's failover (NOP-Out 5 s with a 5 s answer, replacement timeout
5 s, polling 5 s: the settings `tools/mpath_settings.sh` recommends), 14.3 s of detection and about
6 s of recovery: 38 s. The question put to gpt-6-astra the same day was whether that sequence is
inside the requirement and how to bound it.

- **It is a defect.** Two faults in a row are not an exception to "every file operation", and a
  holder dying while it recovers from a path failure is foreseeable. Excluding overlapping faults
  would change the release contract, not pass it. A window longer than the lease protects
  authority; it bounds no accumulated waiting, and beats can keep landing while the holder's flush
  is stuck.
- **The budget.** An operation's stall is S <= b + F + D + R: b what it had already waited before
  the path fault, F the holder's path delay until it finally stops making progress, D from then to
  the declaration (late beat completions and the detector's scheduling included), R from the
  declaration through fence, slice proof, replay, membership, lock grant and the operation's
  completion (the TCP lock manager's ledger takeover and orphan sweep belong inside R). The target
  to qualify: b 0.5 s, F 6 s, D 12.5 s, R 10 s on either lock manager, 29 s at 2, 4, 8 and 16 nodes.
  These are required bounds, not measured worst cases. At 7 checks the same budget is 31 s, so
  keeping 7 needs F <= 4 s or R <= 8 s.
- **Tighter path timeouts** are sound inside a documented load and latency envelope, but the
  settings alone bound nothing: what has to be bounded is the blocking data I/O, outstanding
  commands, error handling, retries and multipath queueing included. False path failures under load,
  and both paths of a node failed together, have to be tested.
- **A shorter window.** 6 checks (12 s, an 8 s lease) is a candidate against the measured 4.1 s
  live gap; 5 leaves 1.9 s and comes only after 6 is qualified. The supported worst-case live gap,
  scheduling and timer uncertainty included, has to stay well below the lease under I/O storms,
  memory pressure and a VM pause.
- **The slice proof.** Matching re-reads are not a stability proof without a bound on how late a
  write the target accepted before PREEMPT AND ABORT can land: three equal reads can all precede a
  delayed backing write. Shortening it needs a target-side drain acknowledgement covering every
  write accepted before the fence, or an enforceable maximum post-fence write latency followed by a
  complete read after that deadline; the drain's own worst case stays in R.
- **The holder** may use its heartbeat's 2 s view of a dead path to speed up its real failover, but
  failing a multipath path does not release commands already issued on it: the transport has to
  bound their resolution, and the normal unlock still waits for a completed flush that orders every
  protected write, those still outstanding on the dead path included. A stronger route is an
  acknowledged early surrender of authority followed by fence, drain and replay, which starts
  recovery before the window ends; it needs a protocol that proves quiescence, which one missed
  path is not.
- **Qualifying it** means forcing a waiter across the holder's path failure and death at 2, 4, 8 and
  16 nodes on both lock managers, sweeping the fault's timing against the beat, NOP-Out, polling,
  flush and recovery phases, under maximum journal occupancy, contention, CPU and I/O saturation,
  memory pressure and VM pauses, with every phase timestamped; and injecting backing writes delayed
  past the slice proof.

## Registering a late path under a short lease

A path that was down at mount, or whose session logged in again and lost its registration, is
registered after the mount by the late-path fill (`v5_pr_fill_tick`, `mxfs_pal_scsi_pr_fill_paths`):
READ KEYS down the late path, REGISTER on it, READ KEYS again, and keep the registration only if
another nexus still holds the key. That check orders a REGISTER that completed before any fence. It
does not cover a REGISTER that timed out: such a command can still execute at the target after a
peer's PREEMPT AND ABORT, whose abort does not reach a nexus that held no registration, and register
the fenced node again on that path. The fill guards that case by running only while 15 s of the
authority lease remain. A 12 s window leaves an 8 s lease, so the fill never runs and no late path is
ever registered.

Put to gpt-6-astra (2026-10-23): no threshold on the remaining lease alone is sound. What has to be
bounded is B, the real time from the fill's admission until its REGISTER has either completed or can
no longer execute at the target (queueing, the command timeout T, and a confirmed cancellation, not
merely an ABORT TASK sent). With a the age of the last landed beat's issue time on the local clock
(a = L - R), the clock-rate error e and an allowance d, the fill may issue the REGISTER only when

    a/(1-e) + B + d  <  (L + 4 s)/(1+e)

which is R + 4 s > B + d with no clock error: the 4 s reserve between the lease and the death window
may absorb completion, provided cancellation and recovery may still run while admission is
suspended. If cancellation has no enforced upper bound, no finite threshold proves the absence of a
registration after the fence, and the 15 s constant rests on the same unproven bound. A REGISTER
that timed out puts its late nexus in quarantine: it is not counted or used, and a READ KEYS that
finds it unregistered later is not enough, since the unresolved command could still execute after
that read; only an established end of the original task releases it. Issuing the fill right after a
beat lands maximizes R but does not bound B. Shortening T helps only by starting a bounded
cancellation sooner. The witness in the third step must already have existed before the fill (fills
serialized), since READ KEYS does not name nexuses.

What must be measured before any value is trusted: admission-to-dispatch delay, when the timeout
actually fires, how SCST cancels a queued or running PR OUT, transport recovery and re-login and any
hidden retry, beat completion jitter, the clock error, and the latency of stopping admission; and the
claimed earliest fence, pending fences included. Measured maxima validate an enforced bound; they do
not establish one.

## A target that refuses a retained registration after a relogin

With the 2 s path timescale a 4 s cut of one path makes the initiator drop the iSCSI connection and
log in again. On the lab's SCST target, a login that iscsi-scst does not handle as a session
reinstatement (the old session is already shutting down) gets new per-device state with no
registrant linked, because the registrant is still linked to the old session's state until that
session is freed on SCST's management thread; for those tens of milliseconds the target refuses
the node's writes with RESERVATION CONFLICT although the node is still registered. A refused log
write shuts the filesystem down. A real reinstatement holds the new session's commands until the
registrant is moved, so it has no gap. SPC keeps a registration across an I_T nexus loss, so this
is the target refusing a registered nexus. Put to gpt-6-astra on 2026-10-23, whether MXFS may
tolerate it by retrying the refused writes:

- **No probe authorizes a retry.** READ KEYS listing the key says some registration of it exists;
  not that this nexus is registered, nor that it stays so. A REGISTER with reservation key and
  service-action key both the node's own, down the same path, is a readiness check (an
  unregistered nexus cannot create the key with it), never an ordering barrier against a fence.
  A retry is safe only because the target refuses every write ordered after the fence's removal
  of the key; it need not win the race.
- **A journal retry needs more than the refused command.** A later iclog with PREFLUSH and FUA
  may already have completed: its flush never covered the refused write, so a plain resubmission
  followed by an acknowledged log force can lose that write to a power cut. Holding the iclog in
  SYNCING orders callbacks in memory, not persistence. A retry must keep the iclog logically in
  flight, re-check authority at every resubmission, make the retried write as durable as the
  forces that depend on it require, and the hole later records may leave on disk must be shown a
  valid recovery state. A conservative form is an ordered log-submission gate set up before any
  conflict: no dependent write overtakes an unresolved earlier one.
- **A data retry keeps the operation pending.** The raw conflict must be caught before it becomes
  a mapping error or a completed ioend; redirtying after the fact lets unwritten-extent
  conversion expose old blocks, and a waiter may never see the rewrite. Direct I/O has no page
  cache to fall back on. Coverage has to start at the first conflict, for journal, metadata,
  buffered and direct data writes and flushes; a three-conflict inspection threshold cannot give
  "no operation returns an error".
- **Preferred:** fix the target's handoff (hold the new session's commands until the retained
  registrant is moved, synchronized with PR removal and task abort; linking the registrant to the
  new state early instead can leave old-session writes outside PREEMPT AND ABORT's reach), or gate
  a recovering path below the filesystem before it carries ordinary I/O. A unit attention is no
  notice for that gate: only one command sees it, and it may be a write.
- **The late REGISTER is a fencing problem of its own.** A registration-creating command that
  executes after PREEMPT AND ABORT puts the fenced key back on its nexus, and no later READ KEYS
  can tell; SCSI keeps no tombstone of a removed key. Either registrations are created only while
  the incarnation is not yet fenceable and reconnects only verify retained ones, or an unresolved
  REGISTER keeps the fence from certifying until it is resolved, or the fence aborts the tasks of
  every nexus of the logical unit. Taking the path offline at the initiator keeps the node's own
  later writes off it, but not a write already queued at the target behind the delayed REGISTER.

What must be measured: the target-side order of the login, the refusal and the handoff, and how
long the handoff waits under management-thread load; a REGISTER held until after the certificate
and then released; a fence during every phase of a retry or handoff; crashes before, during and
after a retried log write with volatile write caches on; every completion class; authority
expiring inside a retry window.

## Open

- The read-stop acknowledgment protocol over the TCP mesh, and what CAW, which has no network between
  nodes, uses instead (a small control channel, a witness, or the conservative lease proof alone).
- How a suspended mount revalidates when a closed authority lease never reopens (a beat that lands
  after the closure is not a grant): resuming the same incarnation needs proof that no peer has fenced
  it and none can be part way through doing so.
- Revoking installed mappings within a bounded time, and clock behaviour across a VM pause.
