// SPDX-License-Identifier: GPL-2.0
/*
 * MXFS — Multinode XFS
 * XFS-side DLM lock caching (Phase 3)
 *
 * Caches DLM lock grants per-inode. Releases only on BAST (blocking AST
 * from another node), inode eviction, or unmount.
 *
 * Design based on GFS2 glocks, OCFS2 dlmglue, and mxfs.1 inode_cache:
 *   - DLM lock ordering: DLM outer, VFS i_rwsem inner
 *   - BAST processing: deferred to workqueue, never inline
 *   - Holder counting: separate EX/PR counters
 *   - DEMOTING state: blocks new lock attempts during flush
 *
 * Copyright (c) 2026
 */
#define MXFS_TU_ID 1	/* igrab/iput call-site file id */
#include "xfs_mxfs_dlm_priv.h"
#include <linux/kthread.h>

/*
 * (D-474 AIL-freeze anatomy): pag_dlm_lock hold/wait forensics.
 * See the field comment in xfs_ag.h.  Every mutex_lock/unlock of a
 * pag_dlm_lock in this file routes through these two helpers (mechanical
 * rewrite; the only other site is the mutex_init in xfs_ag.c).
 *
 *   P-AGMUTEX-WAIT  — a waiter waited >= mxfs_agmutex_warn_ms; names the
 *                     owner (pid/comm/lock-site) sampled when the wait began.
 *   P-AGMUTEX-HOLD  — a holder held it >= mxfs_agmutex_warn_ms; names the
 *                     lock site and unlock site and dumps the holder's stack
 *                     (ratelimited) so the blocking edge between them is read
 *                     off the kernel, not guessed.
 */
atomic64_t mxfs_dlm_stat_agtry_localbusy = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_ag_trydemoting = ATOMIC64_INIT(0);
/*
 * handoff-latch accounting (D-RSYNC-LAP-PACE-AG-SHARING-388).
 *   latch_unlock / latch_acq / latch_acqnb — who performed the COMMIT
 *     outside the worker (last-holder unlock, blocking acquirer, nonblock
 *     acquirer); worker COMMITs are the existing P12-WORK COMMIT path.
 *   handoff_n + b2c (BAST rx -> COMMIT) and c2r (COMMIT -> on-disk release)
 *     sums/maxima in ms, with >50 ms and >500 ms buckets — the ruling's
 *     acceptance numbers (p50 needs the sum/n; p99/max need the buckets and
 *     the max).
 *   demote_wait_n / _ms / _max / _trans / _dirty — blocking acquirers that
 *     slept in wait_demote (the ILOCK-holder hazard class the ruling wants
 *     counted), how long, and whether they carried a (dirty) transaction.
 *   postlatch_adopt — invariant counter, must stay 0: a cached fast-path
 *     adoption observed while latched.
 */
atomic64_t mxfs_dlm_stat_latch_unlock = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_latch_acq = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_latch_acqnb = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_handoff_n = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_handoff_b2c_ms = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_handoff_b2c_max = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_handoff_b2c_gt50 = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_handoff_b2c_gt500 = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_handoff_c2r_ms = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_handoff_c2r_max = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_handoff_c2r_gt50 = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_handoff_c2r_gt500 = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_demote_wait_n = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_demote_wait_ms = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_demote_wait_max = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_demote_wait_trans = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_demote_wait_dirty = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_postlatch_adopt = ATOMIC64_INIT(0);
/* cached AG hints found with no grant behind them in this node's table (net/mesh) */
atomic64_t mxfs_dlm_stat_ag_cached_phantom = ATOMIC64_INIT(0);
/* 0.22.3: BAST->COMMIT split tails (rx->queued, queued->enter, enter->armed, armed->commit) */
atomic64_t mxfs_dlm_stat_handoff_q_gt500 = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_handoff_q_max = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_handoff_wq_gt500 = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_handoff_wq_max = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_handoff_e2a_gt500 = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_handoff_e2a_max = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_handoff_a2c_gt500 = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_handoff_a2c_max = ATOMIC64_INIT(0);
atomic64_t mxfs_dlm_stat_handoff_rxheld = ATOMIC64_INIT(0);	/* holders>0 at first rx */
atomic64_t mxfs_dlm_stat_stale_hint = ATOMIC64_INIT(0);	/* 0.22.4: pre-acquire hints dropped */

/*
 * every demote-completion site clears the latch state with the
 * demoting flag — a latched COMMIT that completed (or was abandoned by an
 * inject/unmount path) must never leave pag_dlm_latched behind, or the
 * next worker run would re-enter the committed path on a released grant.
 */
void mxfs_ag_demote_clear(struct xfs_perag *pag)
{
	pag->pag_dlm_demoting = false;
	pag->pag_dlm_latched = false;
	pag->pag_dlm_finishing = false;
	pag->pag_dlm_prepass_done = false;
	/*
	 * 0.22.1: the schedule latch is released HERE, at demote
	 * completion — not at the COMMIT.  mxfs_ag_handoff_commit keeps
	 * pag_dlm_bast_scheduled set across the drains so the rx watchdog
	 * (P275-AG-STUCK-LATCH) can requeue a lost worker; 0.22.0 then never
	 * cleared it, so after the first completed handoff on an AG every
	 * later BAST saw sched=1, neither rx nor the last-holder unlock queued
	 * the worker, and each generation waited the full 30 s for the
	 * watchdog (measured 25 AGs lap 1: b2c_max=30031 ms, P275 requeued=1
	 * five times on one node, all three rows BUDGET_EXHAUSTED on 32/32).
	 * The pre-latch code cleared it at the COMMIT, i.e. strictly before
	 * every completion site, so clearing at completion is the same
	 * contract made explicit.
	 */
	pag->pag_dlm_bast_scheduled = false;
}

/*
 * 0.22.3: the one place the AG BAST worker is queued.  Stamps the
 * first queue of the current BAST generation (rx -> queued is the time a
 * pending revocation waited for a local holder to let go; queued -> enter is
 * the ordered-workqueue latency behind other AGs' workers on this mount).
 * Benign first-writer race on the stamp — instrumentation only.
 */
void mxfs_ag_bast_queue(struct xfs_mount *mp, struct xfs_perag *pag)
{
	if (!READ_ONCE(pag->pag_dlm_queued_ns))
		WRITE_ONCE(pag->pag_dlm_queued_ns, ktime_get_ns());
	if (mp->m_mxfs_ag_bast_wq)
		queue_work(mp->m_mxfs_ag_bast_wq, &pag->pag_dlm_bast_work);
	else
		schedule_work(&pag->pag_dlm_bast_work);
}

void mxfs_stat_max64(atomic64_t *v, s64 n)
{
	s64 old = atomic64_read(v);

	while (n > old) {
		s64 seen = atomic64_cmpxchg(v, old, n);

		if (seen == old)
			break;
		old = seen;
	}
}
/* lifecycle probe counters (defined with the machinery near
 * mxfs_dlm_bast_notify; tentative declarations here for the stats line). */
atomic64_t mxfs_noino_lifecycle_stat[XFS_ILC_NR];
atomic64_t mxfs_noino_lifecycle_requeued;
atomic64_t mxfs_noino_lifecycle_timeouts;
static int mxfs_agmutex_warn_ms = 300;
module_param_named(agmutex_warn_ms, mxfs_agmutex_warn_ms, int, 0644);
MODULE_PARM_DESC(agmutex_warn_ms,
	"warn when pag_dlm_lock is held or waited for >= this many ms (0=off)");

void
mxfs_pag_dlm_lock(struct xfs_perag *pag, int site)
{
	u64		t0 = 0;
	pid_t		opid = 0;
	int		osite = 0;
	char		ocomm[16] = "";

	if (!mutex_trylock(&pag->pag_dlm_lock)) {
		struct task_struct *own;

		t0 = ktime_get_ns();
		/* owner word: task pointer with the low 3 flag bits set. */
		rcu_read_lock();
		own = (struct task_struct *)
			(atomic_long_read(&pag->pag_dlm_lock.owner) & ~0x07UL);
		if (own) {
			opid = own->pid;
			strscpy(ocomm, own->comm, sizeof(ocomm));
		}
		rcu_read_unlock();
		osite = READ_ONCE(pag->pag_dlm_lock_site);
		mutex_lock(&pag->pag_dlm_lock);
		if (mxfs_agmutex_warn_ms > 0) {
			u64 w = ktime_get_ns() - t0;

			if (w >= (u64)mxfs_agmutex_warn_ms * NSEC_PER_MSEC)
				mxfs_probe("mxfs: P-AGMUTEX-WAIT ag=%u site=%u:%u waited_ms=%llu owner_at_start=%s/%d owner_site=%u:%u comm=%s pid=%d\n",
					pag_agno(pag), MXFS_SITE_ARGS(site),
					(unsigned long long)(w / NSEC_PER_MSEC),
					ocomm, opid, MXFS_SITE_ARGS(osite), current->comm,
					current->pid);
		}
	}
	pag->pag_dlm_lock_t0 = ktime_get_ns();
	pag->pag_dlm_lock_site = site;
	pag->pag_dlm_lock_pid = current->pid;
	strscpy(pag->pag_dlm_lock_comm, current->comm,
		sizeof(pag->pag_dlm_lock_comm));
}

void
mxfs_pag_dlm_unlock(struct xfs_perag *pag, int site)
{
	u64	held = ktime_get_ns() - pag->pag_dlm_lock_t0;
	int	lsite = pag->pag_dlm_lock_site;
	bool	warn = mxfs_agmutex_warn_ms > 0 &&
		       held >= (u64)mxfs_agmutex_warn_ms * NSEC_PER_MSEC;

	pag->pag_dlm_lock_site = 0;
	pag->pag_dlm_lock_pid = 0;
	mutex_unlock(&pag->pag_dlm_lock);
	if (warn) {
		static DEFINE_RATELIMIT_STATE(rs, 10 * HZ, 3);

		mxfs_probe("mxfs: P-AGMUTEX-HOLD ag=%u lock_site=%u:%u unlock_site=%u:%u held_ms=%llu comm=%s pid=%d\n",
			pag_agno(pag), MXFS_SITE_ARGS(lsite), MXFS_SITE_ARGS(site),
			(unsigned long long)(held / NSEC_PER_MSEC),
			current->comm, current->pid);
		if (mxfs_probe_on() && __ratelimit(&rs))
			dump_stack();
	}
}
static atomic_t mxfs_demev_seq = ATOMIC_INIT(0);

/*
 * D-DWORK-TEARDOWN-LASTREF-LEAK class fix: single gate for EVERY
 * per-inode bast work/dwork arm (each arm owns one igrab ref; queued-false
 * means the caller drops it — both for "already queued" and "gate closed",
 * the same contract every site already implements).  put_super closes the
 * gate under m_mxfs_arm_lock, flushes the wq, then sweeps s_inodes
 * sync-canceling armed works: a delayed work still on its timer is
 * invisible to flush_workqueue, and when its ref is the inode's LAST ref
 * the eviction whose P204 cancel would disarm it can never run (circular)
 * — the timer then outlives xfs_free_perag and the P142 last-ref guard
 * leaks the inode (captured live, ino 31457413).  Lock order:
 * callers may hold ip->i_dlm_lock; the sweep takes arm_lock only, never
 * i_dlm_lock, so i_dlm_lock -> arm_lock is the only edge.
 */
bool
mxfs_bast_arm_queue(
	struct xfs_inode	*ip)
{
	struct xfs_mount	*mp = ip->i_mount;
	bool			queued = false;

	spin_lock(&mp->m_mxfs_arm_lock);
	if (unlikely(mp->m_mxfs_arms_off))
		pr_warn_ratelimited("mxfs: P6S-ARM-REFUSED ino=%llu src=%u -- bast-arm gate closed (teardown)\n",
			(unsigned long long)ip->i_ino, ip->i_dlm_bastq_src);
	else
		queued = queue_work(mp->m_mxfs_inode_bast_wq,
				    &ip->i_dlm_bast_work);
	if (queued)
		ip->i_dlm_bastq_qns = ktime_get_ns();
	spin_unlock(&mp->m_mxfs_arm_lock);
	return queued;
}

bool
mxfs_bast_arm_queue_delayed(
	struct xfs_inode	*ip,
	unsigned long		delay_j)
{
	return mxfs_bast_arm_queue_delayed_gated(ip, delay_j) > 0;
}

/*
 * The same arm, telling apart the two ways it can fail to queue: 1 = queued
 * (the caller's reference now belongs to the dwork), 0 = already queued (that
 * dwork owns a reference of its own, so the caller's is a duplicate and never
 * the last one), -1 = the gate is closed for teardown (nothing queued, and the
 * caller's reference may be the last).  The gate is read and the work queued
 * under one lock, so a caller that sees 0 or 1 cannot be overtaken by the
 * gate closing.
 */
int
mxfs_bast_arm_queue_delayed_gated(
	struct xfs_inode	*ip,
	unsigned long		delay_j)
{
	struct xfs_mount	*mp = ip->i_mount;
	int			rc;

	spin_lock(&mp->m_mxfs_arm_lock);
	if (unlikely(mp->m_mxfs_arms_off)) {
		pr_warn_ratelimited("mxfs: P6S-ARM-REFUSED ino=%llu src=%u -- bast-dwork gate closed (teardown)\n",
			(unsigned long long)ip->i_ino, ip->i_dlm_bastq_src);
		rc = -1;
	} else {
		rc = queue_delayed_work(mp->m_mxfs_inode_bast_wq,
					&ip->i_dlm_bast_dwork, delay_j) ? 1 : 0;
	}
	if (rc > 0)
		ip->i_dlm_bastq_qns = ktime_get_ns() +
				      jiffies_to_nsecs(delay_j);
	spin_unlock(&mp->m_mxfs_arm_lock);
	return rc;
}

/*
 * P296-BASTQLAT (D-503 instrumentation): measure the pure
 * queue-to-run EXCESS of every per-inode bast work/dwork on
 * m_mxfs_inode_bast_wq.  Hypothesis under test: during the post-load
 * sync-write pace collapse the shared-dir demote/handoff work sits queued
 * behind a torrent of sweep-release (src=16) works, so the dd writer's
 * ~1.7s/create EX-acquire wait (P36-MHT-REARM exh_ms=1672) is queue delay,
 * not lock-protocol delay.  Called at both work-fn entries right after the
 * ident check.  Logs only when the excess tops 100ms; capped per boot so a
 * genuine torrent cannot flood the ring.
 */
void
mxfs_bastq_lat_probe(
	struct xfs_inode	*ip,
	const char		*who)
{
	static atomic_t		p296_logged = ATOMIC_INIT(0);
	u64			qns = ip->i_dlm_bastq_qns;
	s64			excess;

	if (!qns)
		return;
	ip->i_dlm_bastq_qns = 0;
	excess = ktime_get_ns() - qns;
	if (excess < 100 * NSEC_PER_MSEC)
		return;
	if (atomic_inc_return(&p296_logged) > 400)
		return;
	mxfs_probe("mxfs: P296-BASTQLAT %s ino=%llu src=%u isdir=%d excess_ms=%lld\n",
		who, (unsigned long long)ip->i_ino, ip->i_dlm_bastq_src,
		S_ISDIR(VFS_I(ip)->i_mode) ? 1 : 0,
		div_s64(excess, NSEC_PER_MSEC));
}

/*
 * (ruling B): exponential backoff for the release-abort
 * re-arm loop.  The P15/P244/P95 defer arms re-fire the release pipeline
 * via a 25ms dwork; when the abort repeats with an UNCHANGED tenure gen
 * (no progress — the victim's fenced drain writes could never
 * land), each repeat doubles the delay toward a 1s cap so the loop cannot
 * hammer the node/target at 40Hz forever.  Gen movement (a fresh grant —
 * real progress) resets the streak, so healthy operation keeps today's
 * 25ms first-retry latency.  0-31ms jitter decorrelates a fleet of
 * victims re-firing in lockstep.  Fields are only touched here and at the
 * committed-release reset; the bast dwork is coalesced per inode, so
 * cross-call races are benign.
 */
unsigned int
mxfs_relab_backoff_ms(
	struct xfs_inode	*ip,
	uint32_t		now_gen)
{
	unsigned int		delay;

	if (ip->i_dlm_relab_gen != now_gen) {
		ip->i_dlm_relab_gen = now_gen;
		ip->i_dlm_relab_streak = 0;
	} else if (ip->i_dlm_relab_streak < 6) {
		ip->i_dlm_relab_streak++;
	}
	delay = 25U << ip->i_dlm_relab_streak;
	if (delay > 1000) {
		delay = 1000;
		pr_warn_ratelimited("mxfs: P279-RELAB-BACKOFF ino=%llu gen=%u streak=%u -- release-abort re-arm at 1s cap (no tenure-gen progress)\n",
			(unsigned long long)ip->i_ino, now_gen,
			ip->i_dlm_relab_streak);
	}
	return delay + (get_random_u32() & 31);
}
/*
 * EXPOSURE counters for the `demoter_legacy_clobber` A/B arm.  The legacy
 * branches deliberately reproduce the pre-fix unconditional store/clear, so
 * they bypass the counters above.  Without their own instrumentation the
 * legacy arm has NO exposure measure, and "legacy armed, no wedge" is then
 * indistinguishable from "the race never happened" — which is precisely the
 * false-verification trap this whole campaign keeps hitting.
 */
/*
 * ROOT MEASUREMENT for the stranded demoter claim.  init_inherit counts
 * inodes that came out of xfs_inode_alloc with a claim ALREADY set — inherited
 * from the recycled slab object, because alloc_inode_sb does not zero it and
 * the initializer's MXFS_CLEAR_DEMOTER refuses a non-owner clear.  free_dirty
 * counts objects that went BACK to the slab still claimed, which is where the
 * inherited ones come from.  Exposure and source for one defect; both must
 * reach zero.  Declared here, with the other demoter counters, because
 * mxfs_dlm_inode_final_release is defined far above the punt-reclaim block.
 */
atomic64_t mxfs_dem_init_inherit;
atomic64_t mxfs_dem_free_dirty;

void
mxfs_demev_rec(struct xfs_inode *ip, uint8_t op, uint32_t line)
{
	uint8_t	h = ip->i_dlm_demev_head;

	if (h >= MXFS_DEMEV_N)
		h = 0;
	ip->i_dlm_demev_op[h] = op;
	ip->i_dlm_demev_line[h] = line;
	ip->i_dlm_demev_pid[h] = current->pid;
	ip->i_dlm_demev_state[h] = ip->i_dlm_state;
	ip->i_dlm_demev_cookie[h] = (uint32_t)atomic_inc_return(&mxfs_demev_seq);
	ip->i_dlm_demev_head = (h + 1) % MXFS_DEMEV_N;
}

/*
 * ROOT FIX for D-BAST-IRELE-INACTIVE-SELF-WEDGE (PROVEN by the
 * demoter ring, replayed off a live 32/caw wedge on test16):
 *
 *   P73-DEMEV[8]  SET   line=15980 pid=59368  cookie=446   <- bast_work_fn claims
 *   P73-DEMEV[9]  SET   line=16280 pid=56068  cookie=449   <- dwork_fn OVERWRITES it
 *   P73-DEMEV[10] CLEAR line=16292 pid=56068  cookie=450   <- dwork_fn CLEARS it
 *   P73-DEMEV[11] WAIT  line=25206 pid=59368  cookie=451   <- 59368 parks, demoter NULL
 *
 * mxfs_dlm_bast_work_fn (pid 59368) and mxfs_dlm_bast_dwork_fn (pid 56068)
 * both ran a release drain on the SAME inode.  The claim was an unqualified
 * single-slot `task_struct *`: the dwork stored itself over a live foreign
 * claim and then cleared the slot to NULL on its way out.  pid 59368's
 * trailing xfs_irele then cascaded into evict -> xfs_inactive ->
 * xfs_attr_inactive -> xfs_ilock, found i_dlm_demoter == NULL instead of
 * itself, lost the "demoter is exempt (it must re-enter during its own
 * drain)" exemption, and parked in the demote-wait FOREVER waiting for a
 * release that only it could drive.  Captured on 3 of 32 nodes at once,
 * 619-839 s and climbing, on a QUIESCED cluster.
 *
 * Two earlier candidate clobberers were refuted first, by their own probes
 * firing zero times: the orphan reclaim's demoter override
 * (P72-DEMOTER-OVERRIDE) and the EDEADLK-freeing self-clobber
 * (P60-EDEADLK-FREEING).  already fixed a DIFFERENT bug with
 * this same stack (clearing the claim before the trailing irele) and its
 * handoff warned the fix might be "necessary-but-not-sufficient".  This is
 * that second bug.
 *
 * THE FIX: the claim becomes OWNED and NESTABLE.
 *   - A task may claim only an unowned slot, or re-claim its own (depth++).
 *     A foreign LIVE claim is never overwritten.
 *   - Only the owner may release, and only the outermost release clears it.
 * cmpxchg rather than i_dlm_lock because the call sites disagree about
 * whether that spinlock is held (bast_work_fn and dwork_fn hold nothing here;
 * others are mid-critical-section), so taking it inside the macro would
 * deadlock some callers.  Depth is touched only by the owning task.
 */
/*
 * Is `current` one of the tasks currently draining this inode?  The demote-wait
 * exemption ("demoter is exempt — it must re-enter during its own drain") must
 * cover EVERY live drain of the inode, not just the first one to claim, or the
 * others stall 3s per nested ilock.  See i_dlm_demoter2 in xfs_inode.h.
 */
/*
 * A CLAIM HOLDS A REFERENCE ON ITS OWNER, AND A CLAIM WHOSE OWNER HAS EXITED
 * IS RETIRED.
 *
 * The slots used to hold a bare task_struct pointer with no reference.  Two
 * failures followed, both measured on 8/net/mesh/direct:
 *
 *   1. A claim whose owner exited stayed set, and the task_struct went back to
 *      the slab.  The next task given that memory compared equal to the slot
 *      and was treated as the inode's drain: a mkdir 12 s later, and an rm 28
 *      ms later, presented a dead rm's claim on a shared directory and were
 *      offered the demoter bypass with no grant behind it (the corruption of
 *      D-SHARED-PARENT-NLINK-EXCEEDS-ITS-ENTRIES-AFTER-CONCURRENT-RM-AND-MKDIR).
 *   2. Nothing retired a dead owner's claim.  Every release of the directory
 *      then met a foreign claim it could not take (P74, P15-REL-ABORT x116)
 *      until P-INODE-WEDGE shut the node down 64 s later.
 *
 * Every NULL->task transition of a slot now takes a reference and every
 * task->NULL transition drops it, each done only by the side that wins the
 * atomic swap, so the pointer is valid memory for as long as it is in a slot
 * and can never be reissued to another task while claimed.  A claim whose
 * owner has reached exit_state is provably not a drain in progress (the owner
 * runs no filesystem code after exit_files), so it is retired at the two places
 * that meet it: a task asking whether a foreign drain is active, and a task
 * trying to claim the inode.
 *
 * Retirement and the punt sweep are the only paths that remove a slot they do
 * not own, and both drop the owner's reference.  They serialize on a hashed
 * lock so neither reads ->exit_state through a pointer the other has just put.
 * The owner's own clear needs no lock: a live owner's task_struct is pinned by
 * its own usage count.
 */
int mxfs_demoter_dead_claim_reap = 1;
module_param_named(demoter_dead_claim_reap, mxfs_demoter_dead_claim_reap,
		   int, 0644);
MODULE_PARM_DESC(demoter_dead_claim_reap,
	"retire a demoter claim whose owner has exited (1, default); 0 = leave it set, for a control arm");
atomic64_t mxfs_dem_dead_reap_n;
atomic64_t mxfs_dem_claim_wait_expired;
atomic64_t mxfs_dem_punt_gen_reject;	/* sweep met a later claim of the slot */

/*
 * TEST ONLY: stall for this many microseconds at the points where 0.90.37's
 * claim-slot races lived: after a claimant wins a slot and before it sets
 * the slot's depth and stamps, and in the punt sweep between reading a slot
 * and taking the reap lock to remove it.  A remover that met a claim inside
 * those windows used to drop a reference not yet taken, or zero a new
 * owner's depth.  0 = off.
 */
int mxfs_demoter_test_window_us;
module_param_named(demoter_test_window_us, mxfs_demoter_test_window_us, int,
		   0644);
MODULE_PARM_DESC(demoter_test_window_us,
	"TEST ONLY: microseconds to stall inside each demoter slot race window (0 = off)");

void
mxfs_demoter_test_window(void)
{
	int us = READ_ONCE(mxfs_demoter_test_window_us);

	if (unlikely(us > 0))
		udelay(min(us, 1000));
}

#define MXFS_DEMOTER_REAP_LOCKS	64
static spinlock_t mxfs_demoter_reap_locks[MXFS_DEMOTER_REAP_LOCKS] = {
	[0 ... MXFS_DEMOTER_REAP_LOCKS - 1] =
		__SPIN_LOCK_UNLOCKED(mxfs_demoter_reap_locks)
};

spinlock_t *
mxfs_demoter_reap_lock(const struct xfs_inode *ip)
{
	return &mxfs_demoter_reap_locks[hash_ptr((void *)ip,
					 ilog2(MXFS_DEMOTER_REAP_LOCKS))];
}

/*
 * Every transition of a slot between empty and a task happens under the
 * inode's reap lock, and the task reference moves with it: the claimant takes
 * its reference BEFORE the slot can name it, and whoever empties a slot drops
 * the slot's reference AFTER the lock is released.  So nothing can ever put a
 * reference the slot does not yet hold, retirement never reads a task another
 * remover has just put, and a remover never writes slot metadata (depth,
 * stamps) once the slot is claimable again: the next claimant owns those.
 *
 * The owner's own writes to depth and stamps are made under the same lock and
 * only while the slot still names it.  The punt sweep can empty a retained
 * claim while its owner is still running, so "the slot is mine" read outside
 * the lock can be stale by the time the owner writes; a write made on that
 * read lands on whichever task claimed the slot next.  Measured by the slot
 * self-test on 0.90.39's first build: one nested claim in 7.7M rounds released
 * by its first unnest, after a swept owner's clear had zeroed its depth.
 */
/* a clear by a task that held neither slot when it took the lock */
atomic64_t mxfs_dem_drop_lost;

static void
mxfs_demoter_slot_stamp(struct xfs_inode *ip, int slot, u32 line)
{
	if (slot) {
		ip->i_dlm_demoter2_pid = current->pid;
		strscpy(ip->i_dlm_demoter2_comm, current->comm,
			sizeof(ip->i_dlm_demoter2_comm));
		ip->i_dlm_demoter2_set_ns = ktime_get_ns();
		ip->i_dlm_demoter2_line = line;
	} else {
		ip->i_dlm_demoter_pid = current->pid;
		strscpy(ip->i_dlm_demoter_comm, current->comm,
			sizeof(ip->i_dlm_demoter_comm));
		ip->i_dlm_demoter_set_ns = ktime_get_ns();
		ip->i_dlm_demoter_line = line;
	}
}

bool
mxfs_demoter_slot_take(struct xfs_inode *ip, int slot, u32 line)
{
	struct task_struct	**cell = slot ? &ip->i_dlm_demoter2 :
						&ip->i_dlm_demoter;
	spinlock_t		*lock = mxfs_demoter_reap_lock(ip);
	unsigned long		flags;
	bool			won;

	get_task_struct(current);
	spin_lock_irqsave(lock, flags);
	won = cmpxchg(cell, NULL, current) == NULL;
	if (won) {
		ip->i_dlm_demoter_gen[slot]++;
		if (slot)
			ip->i_dlm_demoter2_depth = 1;
		else
			ip->i_dlm_demoter_depth = 1;
		mxfs_demoter_slot_stamp(ip, slot, line);
	}
	spin_unlock_irqrestore(lock, flags);
	if (!won)
		put_task_struct(current);
	else
		mxfs_demoter_test_window();
	return won;
}

/* Nest a claim this task already holds in @slot; false if it holds none. */
bool
mxfs_demoter_slot_nest(struct xfs_inode *ip, int slot, u32 line)
{
	struct task_struct	**cell = slot ? &ip->i_dlm_demoter2 :
						&ip->i_dlm_demoter;
	spinlock_t		*lock = mxfs_demoter_reap_lock(ip);
	unsigned long		flags;
	bool			mine;

	if (READ_ONCE(*cell) != current)
		return false;	/* only this task can make it so */
	mxfs_demoter_test_window();
	spin_lock_irqsave(lock, flags);
	mine = READ_ONCE(*cell) == current;
	if (mine) {
		if (slot)
			ip->i_dlm_demoter2_depth++;
		else
			ip->i_dlm_demoter_depth++;
		mxfs_demoter_slot_stamp(ip, slot, line);
	}
	spin_unlock_irqrestore(lock, flags);
	return mine;
}

/*
 * Unnest this task's claim in @slot, emptying the slot at the outermost level.
 * Returns 0 when a nesting level was dropped, 1 when the slot was emptied, and
 * -1 when the slot does not name this task (never claimed, or a remover took
 * it first).
 */
int
mxfs_demoter_slot_release(struct xfs_inode *ip, int slot)
{
	struct task_struct	**cell = slot ? &ip->i_dlm_demoter2 :
						&ip->i_dlm_demoter;
	int			*depth = slot ? &ip->i_dlm_demoter2_depth :
						&ip->i_dlm_demoter_depth;
	spinlock_t		*lock = mxfs_demoter_reap_lock(ip);
	unsigned long		flags;
	int			ret = -1;

	if (READ_ONCE(*cell) != current)
		return -1;
	mxfs_demoter_test_window();
	spin_lock_irqsave(lock, flags);
	if (READ_ONCE(*cell) == current) {
		if (*depth > 1) {
			(*depth)--;
			ret = 0;
		} else {
			*depth = 0;
			WRITE_ONCE(*cell, NULL);
			ret = 1;
		}
	}
	spin_unlock_irqrestore(lock, flags);
	if (ret == 1)
		put_task_struct(current);
	else if (ret < 0)
		atomic64_inc(&mxfs_dem_drop_lost);
	return ret;
}

/* A/B-only legacy clobber mode: an unconditional store, still locked. */
void
mxfs_demoter_slot_force(struct xfs_inode *ip)
{
	spinlock_t		*lock = mxfs_demoter_reap_lock(ip);
	struct task_struct	*old;
	unsigned long		flags;

	get_task_struct(current);
	spin_lock_irqsave(lock, flags);
	old = xchg(&ip->i_dlm_demoter, current);
	ip->i_dlm_demoter_gen[0]++;
	spin_unlock_irqrestore(lock, flags);
	if (old)
		put_task_struct(old);
}

void
mxfs_demoter_slot_force_clear(struct xfs_inode *ip)
{
	spinlock_t		*lock = mxfs_demoter_reap_lock(ip);
	struct task_struct	*old;
	unsigned long		flags;

	spin_lock_irqsave(lock, flags);
	old = xchg(&ip->i_dlm_demoter, NULL);
	spin_unlock_irqrestore(lock, flags);
	if (old)
		put_task_struct(old);
}

void
mxfs_demoter_reap_dead(struct xfs_inode *ip)
{
	struct task_struct	*dead[2] = { NULL, NULL };
	spinlock_t		*lock;
	unsigned long		flags;
	int			slot;

	if (!READ_ONCE(mxfs_demoter_dead_claim_reap))
		return;
	if (likely(!READ_ONCE(ip->i_dlm_demoter) &&
		   !READ_ONCE(ip->i_dlm_demoter2)))
		return;

	lock = mxfs_demoter_reap_lock(ip);
	spin_lock_irqsave(lock, flags);
	for (slot = 0; slot < 2; slot++) {
		struct task_struct	**cell = slot ? &ip->i_dlm_demoter2 :
							&ip->i_dlm_demoter;
		struct task_struct	*d = READ_ONCE(*cell);
		static atomic_t		p_reap_n = ATOMIC_INIT(0);
		u64			set_ns;

		/* d stays valid here: only a holder of this lock can empty
		 * the slot, so its reference is still the slot's */
		if (!d || d == current || !READ_ONCE(d->exit_state))
			continue;
		if (cmpxchg(cell, d, NULL) != d)
			continue;
		dead[slot] = d;
		set_ns = slot ? ip->i_dlm_demoter2_set_ns :
				ip->i_dlm_demoter_set_ns;
		atomic64_inc(&mxfs_dem_dead_reap_n);
		mxfs_demev_rec(ip, 7, MXFS_SITE);
		if (atomic_inc_return(&p_reap_n) <= 2000)
			pr_err("mxfs: P-DEMOTER-DEAD-REAP ino=%llu slot=%d owner_pid=%d owner_comm=%s claim_line=%u:%u claim_age_ms=%llu depth=%d punt=0x%x punt_n=%u state=%u mode=%u by_pid=%d by_comm=%s -- demoter claim whose owner exited retired\n",
			       (unsigned long long)ip->i_ino, slot + 1,
			       slot ? ip->i_dlm_demoter2_pid :
				      ip->i_dlm_demoter_pid,
			       slot ? ip->i_dlm_demoter2_comm :
				      ip->i_dlm_demoter_comm,
			       MXFS_SITE_ARGS(slot ? ip->i_dlm_demoter2_line :
						     ip->i_dlm_demoter_line),
			       set_ns ? (unsigned long long)((ktime_get_ns() -
					set_ns) / NSEC_PER_MSEC) : 0ULL,
			       slot ? ip->i_dlm_demoter2_depth :
				      ip->i_dlm_demoter_depth,
			       (unsigned int)READ_ONCE(ip->i_dlm_demoter_punt),
			       (unsigned int)ip->i_dlm_punt_n[slot],
			       ip->i_dlm_state, ip->i_dlm_mode,
			       current->pid, current->comm);
	}
	spin_unlock_irqrestore(lock, flags);
	for (slot = 0; slot < 2; slot++)
		if (dead[slot])
			put_task_struct(dead[slot]);
}

bool
mxfs_is_demoter(const struct xfs_inode *ip)
{
	return READ_ONCE(ip->i_dlm_demoter) == current ||
	       READ_ONCE(ip->i_dlm_demoter2) == current;
}

/*
 * Is some OTHER task currently draining this inode?
 *
 * With ONE claim slot this question was spelled inline at every call site as
 * `ip->i_dlm_demoter && !mxfs_is_demoter(ip)`.  Adding a second slot silently
 * broke that spelling: it reads FALSE whenever slot 1 has been released while
 * slot 2 is still draining.  That is a reachable and entirely ordinary state —
 * the two drains do not finish in claim order — so every "is a foreign drain
 * active?" test must consider BOTH slots.  Use this predicate for that
 * question and mxfs_is_demoter() only for "am *I* one of the drains?".
 */
bool
mxfs_foreign_demoter(const struct xfs_inode *ip)
{
	struct task_struct	*d1;
	struct task_struct	*d2;

	/* a dead owner's claim is not a drain anyone may wait for */
	mxfs_demoter_reap_dead((struct xfs_inode *)ip);
	d1 = READ_ONCE(ip->i_dlm_demoter);
	d2 = READ_ONCE(ip->i_dlm_demoter2);

	/*
	 * SELF-EXEMPTION FIRST, and it is not optional.  The one-slot spelling
	 * this replaces was `ip->i_dlm_demoter && !mxfs_is_demoter(ip)`, whose
	 * second clause exempts US whenever we hold EITHER slot — so a task
	 * that is itself a drain never defers to another drain.
	 *
	 * A first cut of this helper wrote `(d1 && d1 != current) || (d2 && d2
	 * != current)`, which drops that exemption for the case "slot 1 foreign,
	 * slot 2 == me": a live drain then treats its peer as a reason to
	 * abandon its OWN reload.  Measured cost of getting this wrong at
	 * 32/caw: cache_coherency 0/32 (timed out at its 60 s budget, from 25 s
	 * passing), strong_consistency 25/32, posix_multi 1/32.
	 */
	if (d1 == current || d2 == current)
		return false;
	return d1 != NULL || d2 != NULL;
}

/*
 * Out-of-line claim/release for translation units that cannot see the macros
 * above (xfs_inode.c's inactivation upgrade path did its own raw
 * `i_dlm_demoter = current` / `= NULL` pair, which is the exact clobber shape
 * that produced D-BAST-IRELE-INACTIVE-SELF-WEDGE: it can overwrite a live
 * foreign claim and then NULL the slot, stranding the real owner).
 */
void
mxfs_dlm_claim_demoter(struct xfs_inode *ip)
{
	MXFS_SET_DEMOTER(ip);
}

void
mxfs_dlm_release_demoter(struct xfs_inode *ip)
{
	MXFS_CLEAR_DEMOTER(ip);
}

/*
 * Claim the inode for a drain this task is about to run inline, waiting for a
 * slot when both are held.  Without a claim the drain's own re-entry into
 * xfs_ilock is not exempt from the DEMOTING wait and can wait on itself.  A
 * slot is now held only by a live drain (a dead owner's claim is retired),
 * and a drain measures 22-23 ms, so 50 ms covers one finishing.  Returns
 * whether it holds one.  A caller that gets false must NOT run the drain: an
 * unclaimed drain's re-entry waits on the transition it is itself driving.
 * Workers hand the drain to the MHT dwork (mxfs_dlm_drain_defer); a context
 * that cannot queue work claims with mxfs_dlm_claim_demoter_sync.
 */
int mxfs_demoter_claim_fail_inject;
module_param_named(demoter_claim_fail_inject, mxfs_demoter_claim_fail_inject,
		   int, 0644);
MODULE_PARM_DESC(demoter_claim_fail_inject,
	"TEST ONLY: every Nth demoter claim wait reports no slot without claiming, to drive the deferred-drain path (0 = off)");
atomic64_t mxfs_dem_claim_fail_injected;
atomic64_t mxfs_dem_claim_sync_n;	/* synchronous claims that had to wait */

bool
mxfs_dlm_claim_demoter_wait(struct xfs_inode *ip)
{
	unsigned long	deadline = jiffies + msecs_to_jiffies(50);
	static atomic_t	p_cw_n = ATOMIC_INIT(0);
	int		inject = READ_ONCE(mxfs_demoter_claim_fail_inject);

	if (unlikely(inject > 0) && !mxfs_is_demoter(ip)) {
		static atomic_t	inj_n = ATOMIC_INIT(0);

		if (atomic_inc_return(&inj_n) % inject == 0) {
			atomic64_inc(&mxfs_dem_claim_fail_injected);
			return false;
		}
	}
	for (;;) {
		MXFS_SET_DEMOTER(ip);
		if (mxfs_is_demoter(ip))
			return true;
		if (time_after(jiffies, deadline))
			break;
		msleep(1);
	}
	atomic64_inc(&mxfs_dem_claim_wait_expired);
	if (atomic_inc_return(&p_cw_n) <= 2000)
		pr_err("mxfs: P-DEMOTER-CLAIM-WAIT-EXPIRED ino=%llu s1_pid=%d s1_comm=%s s2_pid=%d me=%d comm=%s -- both demoter slots held past 50 ms; the drain is not run unclaimed\n",
		       (unsigned long long)ip->i_ino, ip->i_dlm_demoter_pid,
		       ip->i_dlm_demoter_comm, ip->i_dlm_demoter2_pid,
		       current->pid, current->comm);
	return false;
}

/*
 * Claim the inode for a drain that has nowhere else to go: an evicting inode,
 * which no work item can hold a reference on, or a teardown that has closed
 * the work arms.  Waits until a slot frees.  Both holders are live drains of
 * this inode (a dead owner's claim is retired, and a punt-retained one is
 * swept once its window closes), and a drain runs no longer than its own
 * pipeline, so the wait ends.  Called holding no lock a drain could need.
 */
void
mxfs_dlm_claim_demoter_sync(struct xfs_inode *ip)
{
	u64		t0 = ktime_get_ns();
	unsigned int	n = 0;

	for (;;) {
		MXFS_SET_DEMOTER(ip);
		if (mxfs_is_demoter(ip))
			break;
		if (++n % 10000 == 0)
			pr_err("mxfs: P-DEMOTER-CLAIM-SYNC-WAIT ino=%llu waited_ms=%llu s1_pid=%d s1_comm=%s s2_pid=%d s2_comm=%s me=%d comm=%s -- still waiting for a demoter slot\n",
			       (unsigned long long)ip->i_ino,
			       (unsigned long long)((ktime_get_ns() - t0) /
						    NSEC_PER_MSEC),
			       ip->i_dlm_demoter_pid, ip->i_dlm_demoter_comm,
			       ip->i_dlm_demoter2_pid, ip->i_dlm_demoter2_comm,
			       current->pid, current->comm);
		msleep(1);
	}
	if (n) {
		atomic64_inc(&mxfs_dem_claim_sync_n);
		mxfs_probe_ratelimited("mxfs: P-DEMOTER-CLAIM-SYNC ino=%llu waited_ms=%llu comm=%s -- claimed after both slots were held\n",
			(unsigned long long)ip->i_ino,
			(unsigned long long)((ktime_get_ns() - t0) /
					     NSEC_PER_MSEC),
			current->comm);
	}
}

/*
 *  — THE SOURCE SIDE of the inherited-claim defect.
 *
 * Called from xfs_inode_free_callback immediately before
 * kmem_cache_free(xfs_inode_cache, ip).  A claim can still be set here through
 * no fault of its holder: the release paths deliberately keep i_dlm_demoter ==
 * current across their TRAILING xfs_irele/iput ( — the
 * cascade into evict -> xfs_inactive -> xfs_ilock must stay exempt or the
 * drain self-deadlocks), and if that irele is the LAST reference the object is
 * destroyed inside it.  The holder's MXFS_CLEAR_DEMOTER then runs against
 * memory that has already gone back to the slab.
 *
 * Whatever the path, an object must never re-enter the slab claimed: the next
 * xfs_inode_alloc does not zero it, so the claim becomes a permanent, unownable
 * strand on an unrelated inode.  Clear it here, where the object is provably
 * dead and unreachable, and count how often it was needed.
 */
void
mxfs_dlm_inode_final_release(struct xfs_inode *ip)
{
	if (unlikely(ip->i_dlm_demoter || ip->i_dlm_demoter2)) {
		static atomic_t p217n = ATOMIC_INIT(0);

		atomic64_inc(&mxfs_dem_free_dirty);
		if (atomic_inc_return(&p217n) <= 200)
			mxfs_probe("mxfs: P217-FREE-DIRTY-CLAIM ino=%llu s1=%d s2=%d s1_pid=%d s1_comm=%s s1_line=%u:%u s1_depth=%d s1_age_ms=%llu s2_pid=%d s2_line=%u:%u -- inode returning to the slab still claimed; cleared so the next allocation cannot inherit it\n",
				(unsigned long long)ip->i_ino,
				!!ip->i_dlm_demoter, !!ip->i_dlm_demoter2,
				ip->i_dlm_demoter_pid, ip->i_dlm_demoter_comm,
				MXFS_SITE_ARGS(ip->i_dlm_demoter_line), ip->i_dlm_demoter_depth,
				(unsigned long long)(ip->i_dlm_demoter_set_ns ?
					(ktime_get_ns() - ip->i_dlm_demoter_set_ns)
						/ NSEC_PER_MSEC : 0ULL),
				ip->i_dlm_demoter2_pid,
				MXFS_SITE_ARGS(ip->i_dlm_demoter2_line));
	}
	{
		/* each slot holds a reference on its owner; give it back */
		struct task_struct *d1 = xchg(&ip->i_dlm_demoter, NULL);
		struct task_struct *d2 = xchg(&ip->i_dlm_demoter2, NULL);

		if (d1)
			put_task_struct(d1);
		if (d2)
			put_task_struct(d2);
	}
	ip->i_dlm_demoter_depth = 0;
	ip->i_dlm_demoter2_depth = 0;
	ip->i_dlm_demoter_punt = 0;
	ip->i_dlm_punt_n[0] = 0;
	ip->i_dlm_punt_n[1] = 0;
	ip->i_dlm_demoter_punt_ns = 0;
	ip->i_dlm_demoter_injected = NULL;
	ip->i_dlm_strand_named = false;
}

/*
 *  — RELEASE THE ONE CLAIM THAT OUTLIVES ITS CRITICAL
 * SECTION.  See the design block at i_dlm_demoter_punt in xfs_inode.h for the
 * proof; in short, mxfs_trans_drain_inode_unlocks' P152 punt is the only exit
 * in the tree that returns with a demoter claim still held, and nothing
 * downstream can clear it (the dwork that inherits the release lands in the
 * OTHER slot and clears only that one).  The claim then makes
 * mxfs_foreign_demoter() true for the life of the in-core inode.
 *
 * The retention is not a bug by itself — it is what keeps the committing task
 * exempt across its post-commit xfs_iunlock — so this bounds it rather than
 * removing it.  Two conditions must BOTH hold before a retained claim is
 * released, and together they mean "the window this claim exists to cover is
 * provably over":
 *
 *   1. the retaining task no longer owns ILOCK-EXCL on this inode.  That is
 *      the exact condition that CREATED the punt (mxfs_trans_drain_inode_
 *      unlocks reads the same rwsem owner field), so its negation is the
 *      window's own end.  Note xfs_iunlock does up_write(&ip->i_lock) BEFORE
 *      calling mxfs_dlm_ilock_end, so the owner clears slightly ahead of the
 *      DLM-side unlock — which is why condition 2 exists.
 *   2. the claim is older than mxfs.demoter_punt_grace_ms (default 200).  A
 *      real post-commit iunlock window is microseconds to a few ms; the
 *      leaked claim in evidence was 179907 ms.  Three orders of magnitude of
 *      headroom, so this can only fire on a claim that is genuinely stranded.
 *
 * NEVER dereferences i_dlm_demoter/2: they are bare task_struct pointers held
 * without a reference and dangle once the holder exits (which is precisely
 * what the evidence shows).  Only the pointer VALUE is compared, and only the
 * stamped scalars are printed.
 */
int mxfs_demoter_punt_reclaim = 1;
module_param_named(demoter_punt_reclaim, mxfs_demoter_punt_reclaim, int, 0644);
MODULE_PARM_DESC(demoter_punt_reclaim,
	"release a demoter claim retained past trans-free once its window has closed (1=on, 0=negative control)");

/*
 * THE GRACE IS A SAFETY MARGIN AGAINST A LIVE TASK, NOT A TUNING KNOB.
 *
 * xfs_iunlock does up_write(&ip->i_lock) BEFORE calling mxfs_dlm_ilock_end, so
 * between those two the retaining task is still executing, still owns its
 * claim, and NO LONGER matches the rwsem owner — it is indistinguishable by
 * inspection from a task that abandoned the claim.  If the sweep fires inside
 * that window it foreign-clears a live owner's claim, which is precisely the
 * event that produced D-BAST-IRELE-INACTIVE-SELF-WEDGE.
 *
 * That window is normally sub-microsecond, but nothing bounds it: the task can
 * be preempted, the vCPU descheduled by the host, or the guest paused.  Age
 * therefore cannot PROVE abandonment; it can only make a live-task false
 * positive implausible.  5 s is ~5 orders of magnitude above the window and far
 * above any real drain (22-23 ms), and it is not load-bearing for the fix: the
 * owner-driven clear in mxfs_dlm_ilock_end retires every retention in practice
 * (measured: 6 punts, 0 sweeps needed, 0 strands).  This exists only for a task
 * that never returns to its unlock at all.
 */
int mxfs_demoter_punt_grace_ms = 5000;
module_param_named(demoter_punt_grace_ms, mxfs_demoter_punt_grace_ms, int, 0644);
MODULE_PARM_DESC(demoter_punt_grace_ms,
	"minimum age of a trans-free-retained demoter claim before the SWEEP may reclaim it (ms); safety margin against clearing a live owner mid-unlock, not a tuning knob");
atomic64_t mxfs_dem_punt_reclaim_n;	/* retained claims released again */
atomic64_t mxfs_dem_punt_selfclear;	/* retained claim cleared normally */
atomic64_t mxfs_dem_punt_ctx_end;	/* retention ended by its owner at the end of its completion batch or writeback pass */

/*
 * END A COMPLETION CONTEXT'S RETENTION WHEN THE CONTEXT ENDS.
 *
 * The trans-free punt also retains a claim when the committing task is an
 * xfs_end_io worker or a writeback submitter (the ioend-ctx case).  There the
 * claim covers the rest of THAT batch or pass: a later completion in the same
 * xfs_end_io batch, or a later folio of the same writepages pass, takes this
 * inode's ILOCK again, and the release the punt queued waits on exactly that
 * writeback.  The task has already unlocked inside its own commit, so the
 * owner-side end in mxfs_dlm_ilock_end never comes, and a worker that does
 * not complete I/O on this inode again leaves the claim to the reclaim sweep,
 * which runs only when something else touches the inode.  Measured on the SAN
 * pair: an xfs-conv retention stood past a 15 s idle settle until the next
 * run's traffic reclaimed it.
 *
 * The batch's last completion (or the pass's last folio) is the end of the
 * window, and this is the task that took the claim, so it is ended here by
 * its own owner: MXFS_CLEAR_DEMOTER releases only the caller's slot, as many
 * times as the punt recorded.
 */
void
mxfs_demoter_punt_ctx_end(struct xfs_inode *ip)
{
	if (likely(!READ_ONCE(ip->i_dlm_demoter_punt)) ||
	    !mxfs_demoter_punt_reclaim)
		return;

	while (ip->i_dlm_punt_n[0] &&
	       READ_ONCE(ip->i_dlm_demoter) == current) {
		ip->i_dlm_punt_n[0]--;
		atomic64_inc(&mxfs_dem_punt_ctx_end);
		MXFS_CLEAR_DEMOTER(ip);
	}
	while (ip->i_dlm_punt_n[1] &&
	       READ_ONCE(ip->i_dlm_demoter2) == current) {
		ip->i_dlm_punt_n[1]--;
		atomic64_inc(&mxfs_dem_punt_ctx_end);
		MXFS_CLEAR_DEMOTER(ip);
	}
	WRITE_ONCE(ip->i_dlm_demoter_punt,
		   (ip->i_dlm_punt_n[0] ? 1 : 0) |
		   (ip->i_dlm_punt_n[1] ? 2 : 0));
}


void
mxfs_demoter_punt_reclaim_check(struct xfs_inode *ip, int site)
{
	struct task_struct	*owner;
	spinlock_t		*reap_lock;
	u64			age_ms;
	u8			punt;
	int			slot;

	punt = READ_ONCE(ip->i_dlm_demoter_punt);
	if (likely(!punt))
		return;

	/*
	 * Retire the bookkeeping for a slot that some other path already
	 * cleared — unconditionally, so the negative-control arm does not
	 * accumulate a permanently set mask and mis-report exposure.
	 */
	if ((punt & 1) && !READ_ONCE(ip->i_dlm_demoter)) {
		punt &= ~1;
		atomic64_inc(&mxfs_dem_punt_selfclear);
	}
	if ((punt & 2) && !READ_ONCE(ip->i_dlm_demoter2)) {
		punt &= ~2;
		atomic64_inc(&mxfs_dem_punt_selfclear);
	}
	WRITE_ONCE(ip->i_dlm_demoter_punt, punt);
	if (!punt)
		return;

	if (!mxfs_demoter_punt_reclaim)
		return;			/* A/B negative control: leak as before */

	age_ms = ip->i_dlm_demoter_punt_ns ?
		 (ktime_get_ns() - ip->i_dlm_demoter_punt_ns) / NSEC_PER_MSEC : 0;
	if (mxfs_demoter_punt_grace_ms > 0 &&
	    age_ms < (u64)mxfs_demoter_punt_grace_ms)
		return;			/* still inside a plausible unlock window */

	owner = (struct task_struct *)
		(atomic_long_read(&ip->i_lock.owner) & ~0x7UL);

	reap_lock = mxfs_demoter_reap_lock(ip);
	for (slot = 0; slot < 2; slot++) {
		struct task_struct	**cell;
		struct task_struct	*d;
		unsigned long		flags;

		if (!(punt & (1u << slot)))
			continue;
		cell = slot ? &ip->i_dlm_demoter2 : &ip->i_dlm_demoter;
		d = READ_ONCE(*cell);
		if (!d || d == owner || d == current)
			continue;	/* window still open, or it is us */

		/*
		 * Remove only the claim the punt retained: the generation must
		 * still be the one recorded, or the slot holds a later claim by
		 * the same task.  Under the reap lock, where every claim and
		 * removal of a slot happens; the slot's reference is ours once
		 * the swap is won and is dropped after the lock.  Depth is not
		 * touched: the slot is claimable the moment it is empty, and
		 * its next claimant sets it.
		 */
		mxfs_demoter_test_window();
		spin_lock_irqsave(reap_lock, flags);
		if (ip->i_dlm_demoter_gen[slot] != ip->i_dlm_punt_gen[slot]) {
			spin_unlock_irqrestore(reap_lock, flags);
			atomic64_inc(&mxfs_dem_punt_gen_reject);
			continue;	/* a later claim of the slot */
		}
		if (cmpxchg(cell, d, NULL) != d) {
			spin_unlock_irqrestore(reap_lock, flags);
			continue;	/* not the retained claim any more */
		}
		spin_unlock_irqrestore(reap_lock, flags);
		put_task_struct(d);

		punt &= ~(1u << slot);
		ip->i_dlm_punt_n[slot] = 0;
		WRITE_ONCE(ip->i_dlm_demoter_punt, punt);
		atomic64_inc(&mxfs_dem_punt_reclaim_n);
		mxfs_demev_rec(ip, 6, MXFS_SITE);
		mxfs_probe_ratelimited(
			"mxfs: P213-PUNT-RECLAIM ino=%llu slot=%d claim_pid=%d claim_comm=%s claim_line=%u:%u age_ms=%llu site=%d -- trans-free-retained demoter claim released\n",
			(unsigned long long)ip->i_ino, slot + 1,
			ip->i_dlm_demoter_pid, ip->i_dlm_demoter_comm,
			MXFS_SITE_ARGS(ip->i_dlm_demoter_line), age_ms, site);
	}
}

/*
 * IN-KERNEL RACE TEST OF THE CLAIM SLOTS.  Writing N to the module parameter
 * demoter_slot_selftest runs it for N seconds (the write blocks) on two
 * detached inode objects that no filesystem can see, and prints one
 * P-DEMOTER-SLOT-SELFTEST line with the verdict.
 *
 * Per inode: two claimants, one remover running the punt sweep and dead-claim
 * retirement as fast as it can, and one spawner of short-lived threads that
 * claim the inode and exit holding the claim.  Each claimant, per round, takes
 * a claim and records it as a punt retention (what the trans-free punt does),
 * clears it, takes a LATER claim of the slot, nests it, and unnests.  The
 * later claim must survive the sweep that is aimed at the retained one, and
 * its depth must survive retirement: a claim lost while held, or a nested
 * claim released by its first unnest, is the failure.  Each claimant's task
 * reference count must come back to where it started, and both slots must be
 * empty once the dead claims are retired.  With demoter_test_window_us set,
 * every round stalls inside the windows the 0.90.37 races lived in.
 */
struct mxfs_dst_ino {
	struct xfs_inode	*ip;
	atomic_t		stop;
	atomic64_t		rounds;
	atomic64_t		lost_claim;
	atomic64_t		depth_lost;
	atomic64_t		ref_drift;
	atomic64_t		children;
	atomic64_t		no_slot;
	struct completion	done[4];
};

struct mxfs_dst_arg {
	struct mxfs_dst_ino	*t;
	int			which;
};

static int
mxfs_dst_child(void *arg)
{
	struct xfs_inode	*ip = arg;

	MXFS_SET_DEMOTER(ip);
	return 0;		/* exits holding the claim */
}

static void
mxfs_dst_claimant_round(struct mxfs_dst_ino *t)
{
	struct xfs_inode	*ip = t->ip;

	MXFS_SET_DEMOTER(ip);
	if (READ_ONCE(ip->i_dlm_demoter) == current) {
		ip->i_dlm_punt_gen[0] = READ_ONCE(ip->i_dlm_demoter_gen[0]);
		ip->i_dlm_demoter_punt_ns = 1;	/* as old as a retention gets */
		WRITE_ONCE(ip->i_dlm_demoter_punt,
			   READ_ONCE(ip->i_dlm_demoter_punt) | 1);
	}
	MXFS_CLEAR_DEMOTER(ip);

	MXFS_SET_DEMOTER(ip);
	if (!mxfs_is_demoter(ip)) {
		atomic64_inc(&t->no_slot);
		return;
	}
	MXFS_SET_DEMOTER(ip);
	mxfs_demoter_test_window();
	if (!mxfs_is_demoter(ip)) {
		atomic64_inc(&t->lost_claim);
		return;
	}
	MXFS_CLEAR_DEMOTER(ip);
	if (!mxfs_is_demoter(ip)) {
		atomic64_inc(&t->depth_lost);
		return;
	}
	MXFS_CLEAR_DEMOTER(ip);
	atomic64_inc(&t->rounds);
}

static int
mxfs_dst_claimant(void *arg)
{
	struct mxfs_dst_arg	*a = arg;
	struct mxfs_dst_ino	*t = a->t;
	int			which = a->which;
	unsigned int		base = refcount_read(&current->usage);

	while (!atomic_read(&t->stop)) {
		mxfs_dst_claimant_round(t);
		cond_resched();
	}
	if (mxfs_is_demoter(t->ip))
		atomic64_inc(&t->lost_claim);	/* a round left a claim */
	if (refcount_read(&current->usage) != base)
		atomic64_inc(&t->ref_drift);
	complete(&t->done[which]);
	return 0;
}

static int
mxfs_dst_remover(void *arg)
{
	struct mxfs_dst_ino	*t = ((struct mxfs_dst_arg *)arg)->t;

	while (!atomic_read(&t->stop)) {
		mxfs_demoter_punt_reclaim_check(t->ip, 99);
		mxfs_demoter_reap_dead(t->ip);
		cond_resched();
	}
	complete(&t->done[2]);
	return 0;
}

static int
mxfs_dst_spawner(void *arg)
{
	struct mxfs_dst_ino	*t = ((struct mxfs_dst_arg *)arg)->t;

	while (!atomic_read(&t->stop)) {
		if (!IS_ERR(kthread_run(mxfs_dst_child, t->ip, "mxfs_dst_child")))
			atomic64_inc(&t->children);
		msleep(1);
	}
	complete(&t->done[3]);
	return 0;
}

static int
mxfs_demoter_slot_selftest_set(const char *val, const struct kernel_param *kp)
{
	struct mxfs_dst_ino	*t;
	struct mxfs_dst_arg	args[2][4];
	struct task_struct	*k;
	int			(*fn[4])(void *) = { mxfs_dst_claimant,
						     mxfs_dst_claimant,
						     mxfs_dst_remover,
						     mxfs_dst_spawner };
	s64			gen0 = atomic64_read(&mxfs_dem_punt_gen_reject);
	s64			rec0 = atomic64_read(&mxfs_dem_punt_reclaim_n);
	s64			reap0 = atomic64_read(&mxfs_dem_dead_reap_n);
	s64			dlost0 = atomic64_read(&mxfs_dem_drop_lost);
	s64			rounds = 0, lost = 0, depth = 0, drift = 0;
	s64			kids = 0, noslot = 0, left = 0;
	unsigned int		secs;
	int			i, j, rc;

	rc = kstrtouint(val, 0, &secs);
	if (rc)
		return rc;
	if (secs == 0 || secs > 600)
		return -EINVAL;
	t = kcalloc(2, sizeof(*t), GFP_KERNEL);
	if (!t)
		return -ENOMEM;
	rc = -ENOMEM;
	for (i = 0; i < 2; i++) {
		t[i].ip = kzalloc(sizeof(struct xfs_inode), GFP_KERNEL);
		if (!t[i].ip)
			goto out_free;
		init_rwsem(&t[i].ip->i_lock);
		spin_lock_init(&t[i].ip->i_dlm_lock);
		t[i].ip->i_ino = i + 1;
		for (j = 0; j < 4; j++)
			init_completion(&t[i].done[j]);
	}
	for (i = 0; i < 2; i++) {
		for (j = 0; j < 4; j++) {
			args[i][j].t = &t[i];
			args[i][j].which = j;
			k = kthread_run(fn[j], &args[i][j], "mxfs_dst_%d_%d",
					i, j);
			if (IS_ERR(k))
				complete(&t[i].done[j]);
		}
	}
	msleep(secs * 1000);
	for (i = 0; i < 2; i++)
		atomic_set(&t[i].stop, 1);
	for (i = 0; i < 2; i++)
		for (j = 0; j < 4; j++)
			wait_for_completion(&t[i].done[j]);
	msleep(50);		/* the last children exit */
	for (i = 0; i < 2; i++) {
		struct xfs_inode *ip = t[i].ip;
		struct task_struct *d1, *d2;
		int spin;

		for (spin = 0; spin < 200 &&
		     (READ_ONCE(ip->i_dlm_demoter) ||
		      READ_ONCE(ip->i_dlm_demoter2)); spin++) {
			mxfs_demoter_reap_dead(ip);
			msleep(5);
		}
		d1 = xchg(&ip->i_dlm_demoter, NULL);
		d2 = xchg(&ip->i_dlm_demoter2, NULL);
		if (d1) {
			left++;
			put_task_struct(d1);
		}
		if (d2) {
			left++;
			put_task_struct(d2);
		}
		rounds += atomic64_read(&t[i].rounds);
		lost += atomic64_read(&t[i].lost_claim);
		depth += atomic64_read(&t[i].depth_lost);
		drift += atomic64_read(&t[i].ref_drift);
		kids += atomic64_read(&t[i].children);
		noslot += atomic64_read(&t[i].no_slot);
	}
	pr_err("mxfs: P-DEMOTER-SLOT-SELFTEST secs=%u window_us=%d rounds=%lld lost_claim=%lld depth_lost=%lld ref_drift=%lld slot_left=%lld no_slot=%lld children=%lld gen_reject=%lld punt_reclaim=%lld dead_reap=%lld drop_lost=%lld verdict=%s\n",
	       secs, READ_ONCE(mxfs_demoter_test_window_us), rounds, lost,
	       depth, drift, left, noslot, kids,
	       atomic64_read(&mxfs_dem_punt_gen_reject) - gen0,
	       atomic64_read(&mxfs_dem_punt_reclaim_n) - rec0,
	       atomic64_read(&mxfs_dem_dead_reap_n) - reap0,
	       atomic64_read(&mxfs_dem_drop_lost) - dlost0,
	       (lost || depth || drift || left || !rounds) ? "FAIL" : "PASS");
	rc = 0;
out_free:
	for (i = 0; i < 2; i++)
		kfree(t[i].ip);
	kfree(t);
	return rc;
}

static const struct kernel_param_ops mxfs_demoter_slot_selftest_ops = {
	.set = mxfs_demoter_slot_selftest_set,
};
module_param_cb(demoter_slot_selftest, &mxfs_demoter_slot_selftest_ops,
		NULL, 0200);
MODULE_PARM_DESC(demoter_slot_selftest,
	"TEST ONLY: write N to race the demoter claim slots for N seconds on detached inodes and print the verdict");
static struct mxfs_dlmtr_ent mxfs_dlmtr[MXFS_DLMTR_N];
static atomic_t mxfs_dlmtr_idx = ATOMIC_INIT(0);
atomic64_t mxfs_auth_backstop_n = ATOMIC64_INIT(0);
/*
 * a lowering that arrives with the tenure already in RELEASING is
 * the release protocol finishing (begin_release ran first) — counted here,
 * silently.  mxfs_auth_backstop_n is then reserved for the violation: a
 * PROVING tenure (DURABLE_EX/UNPUBLISHED_EX) dropped by a lowering that never
 * announced release-begin, i.e. a path where a peer could have been granted
 * while our certificate still claimed the tenure (P246-AUTH-LATE-REVOKE).
 */
atomic64_t mxfs_auth_relclean_n = ATOMIC64_INIT(0);

/*
 * THE mode-transition chokepoint.
 *
 * PROVEN by exhaustive grep: all 19 real `ip->i_dlm_mode = ...`
 * stores in the tree live in xfs_mxfs_dlm.c and every one of them is wrapped
 * in the `{ u8 dtr_om = ...; store; mxfs_dlmtr_rec(...); }` idiom, so this
 * function sees every mode transition with the old mode in hand.  That makes
 * it the one place a mode LOWERING can be caught without relying on any
 * enumeration of release sites staying complete as the code changes.
 *
 * It is therefore no longer diagnostic-only: the authority backstop runs
 * BEFORE the watch-ino early return.  The primary revoke happens at
 * release-begin (earlier, and before anything outwardly visible — wired
 * at every deliberate release site); the lowering seen here then
 * finds the tenure in RELEASING and finishes it silently (relclean).  A
 * lowering that still finds a PROVING tenure is the violation this backstop
 * exists for: the mode dropped without the release protocol having been
 * announced, so the revoke is LATE — a peer may already have been granted
 * while our certificate still claimed the tenure.  As of (design-consult
 * ruling A) there is NO known population left: the phantom-recovery arms
 * (P108-REACQUIRE, P-TCPEX-REACQ, the phantom-undo) invalidate at detection
 * via mxfs_inode_authority_phantom_loss_locked, so any P246-AUTH-LATE-REVOKE
 * hit is an uninstrumented release path — a wiring bug to be closed, not a
 * signal to be tolerated.
 */
void
mxfs_dlmtr_rec(struct xfs_inode *ip, u8 om, u8 os, u32 line)
{
	struct mxfs_dlmtr_ent *e;

	if (unlikely(om > ip->i_dlm_mode) &&
	    ip->i_mxfs_auth_state != MXFS_AUTH_NONE) {
		if (ip->i_mxfs_auth_state == MXFS_AUTH_RELEASING) {
			atomic64_inc(&mxfs_auth_relclean_n);
		} else {
			atomic64_inc(&mxfs_auth_backstop_n);
			mxfs_probe_ratelimited("mxfs: P246-AUTH-LATE-REVOKE ino=%llu auth_state=%u om=%u nm=%u os=%u L%u:%u -- proving certificate dropped by a mode lowering that never announced release-begin\n",
				(unsigned long long)ip->i_ino,
				ip->i_mxfs_auth_state, om, ip->i_dlm_mode,
				os, MXFS_SITE_ARGS(line));
		}
		mxfs_inode_authority_revoke_locked(ip, line);
	}

	/* #18 forensics: stamp the last granted->NL lowering on EVERY
	 * inode (the ring below is watch_ino-gated and useless for an
	 * unpredictable ino).  P95-OPEN-PROTECT-FAIL prints these to name the
	 * setter that left mode==NL after the open's ilock ride. */
	if (ip->i_dlm_mode == MXFS_LOCK_NL && om != MXFS_LOCK_NL) {
		ip->i_dlm_nl_line = line;
		ip->i_dlm_nl_pid = current->pid;
		ip->i_dlm_nl_ns = ktime_get_real_ns();
		ip->i_dlm_nl_om = om;
		strscpy(ip->i_dlm_nl_comm, current->comm,
			sizeof(ip->i_dlm_nl_comm));
		/* #18 near-miss survey: holders sit inside
		 * ilock_begin/ilock_end critical sections, so a granted->NL
		 * lowering while exh/prh != 0 is the P95-OPEN-PROTECT-FAIL
		 * hazard class firing REGARDLESS of whether an open loses the
		 * microsecond race — names the setter population without
		 * waiting for the EIO to reproduce. */
		if (ip->i_dlm_ex_holders || ip->i_dlm_pr_holders)
			mxfs_probe_ratelimited("mxfs: P95-NL-UNDER-HOLD ino=%llu L%u:%u om=%u os=%u ns=%u exh=%u prh=%u acq=%u open_n=%d imode=%o pid=%d comm=%s\n",
				(unsigned long long)ip->i_ino, MXFS_SITE_ARGS(line), om, os,
				ip->i_dlm_state, ip->i_dlm_ex_holders,
				ip->i_dlm_pr_holders, ip->i_dlm_acq_inflight,
				atomic_read(&ip->i_mxfs_open_n),
				VFS_I(ip)->i_mode, current->pid,
				current->comm);
	}

	/* #23 forensics (design-consult ruling): if the task recording this
	 * event is an open_protect admission mid-ride, stamp the call-site
	 * line.  Every ilock_begin admit arm ends in MXFS_DLMTR_H at its
	 * holder++, so the LAST line stamped before the admission re-read
	 * names the admit arm that registered the opener's holder (the arm
	 * that let it ride at mode==NL).  All callers hold i_dlm_lock. */
	if (unlikely(ip->i_mxfs_openprot_pid == current->pid &&
		     ip->i_mxfs_openprot_pid != 0))
		ip->i_mxfs_openprot_arm = line;

	if (likely(!mxfs_watch_ino) || ip->i_ino != mxfs_watch_ino)
		return;
	e = &mxfs_dlmtr[(u32)atomic_inc_return(&mxfs_dlmtr_idx) %
			MXFS_DLMTR_N];
	e->ns = ktime_get_real_ns();
	e->ino = ip->i_ino;
	e->line = line;
	e->pid = current->pid;
	e->om = om;
	e->nm = ip->i_dlm_mode;
	e->os = os;
	e->nst = ip->i_dlm_state;
	e->exh = ip->i_dlm_ex_holders;
	e->prh = ip->i_dlm_pr_holders;
	strscpy(e->comm, current->comm, sizeof(e->comm));
}

void
mxfs_dlmtr_dump(void)
{
	u32 idx = (u32)atomic_read(&mxfs_dlmtr_idx);
	int i;

	mxfs_probe("mxfs: P12-DLMTR-DUMP watch=%llu idx=%u\n",
		mxfs_watch_ino, idx);
	for (i = 0; i < MXFS_DLMTR_N; i++) {
		struct mxfs_dlmtr_ent *e =
			&mxfs_dlmtr[(idx + 1 + i) % MXFS_DLMTR_N];
		if (!e->ns)
			continue;
		mxfs_probe("mxfs: P12-DLMTR ino=%llu m%u>%u s%u>%u ex=%u pr=%u L%u:%u pid=%u %s ns=%llu\n",
			(unsigned long long)e->ino, e->om, e->nm, e->os,
			e->nst, e->exh, e->prh, MXFS_SITE_ARGS(e->line), e->pid, e->comm,
			(unsigned long long)e->ns);
	}
}

/*
 *  a864 (instrumented): the dir_reuse@32/caw wedge is an ORPHANED on-disk
 * EX holder bit — a peer holds a dir inode's EX bit on the CAW slot while its
 * cached i_dlm_mode==NL, so it swallows every peer BAST ("I hold nothing") and
 * 31 waiters block 360s -> rc=-110 cascade.  Prior sessions PROVED the bit is
 * set + frozen from the ACQUIRER's view (P-ACQ-STUCK) but never captured, from
 * the HOLDER's view at the swallow, three decisive facts:
 *   held_raw  = the HINTED find_slot read (what inode_held/the release gate see)
 *   scan_mine = a duplicate-immune FULL-CHAIN scan (does our bit exist ANYWHERE)
 *   nslots    = live-slot count for the ino (>1 == claim-race dup => the hinted
 *               read and the scan can disagree)
 * held_raw==0 && scan_mine==1 && nslots>1  => the dup-slot/hint blind spot is
 * root (the release gate reads the wrong slot).  held_raw>=EX (or scan_mine==1,
 * nslots==1) => held() is correct and the swallow is a STATE-MACHINE gating bug
 * (the release path never fires for this mode/state).  Either way the fix is
 * named.  The one-shot transition-ring dump adds the exact formation sequence.
 * Read-only; hard-capped (synchronous slot I/O).  site: 0=P72 DEMOTING-swallow,
 * 1=NONE/NL "no orphan" swallow.  Call with i_dlm_lock NOT held.
 */
void
mxfs_caw_orphan_forensic(struct xfs_inode *ip, int site)
{
	struct xfs_mount *mp = ip->i_mount;
	static atomic_t forensic_n = ATOMIC_INIT(0);
	static atomic_t ring_dumped = ATOMIC_INIT(0);
	static unsigned long last_j;
	uint8_t held_raw;
	int mine, nslots = 0;
	uint64_t hex_or = 0;
	unsigned n;

	if (!mp->m_mxfs_dlm || !mxfs_v5_dlm_transport_caw(mp->m_mxfs_dlm))
		return;
	if (!S_ISDIR(VFS_I(ip)->i_mode))
		return;
	n = (unsigned)atomic_inc_return(&forensic_n);
	if (n > 8000)
		return;			/* hard cap on synchronous scan I/O */
	/* light throttle so samples spread across the whole wedge (per node) */
	if (n > 1 && time_before(jiffies, last_j + msecs_to_jiffies(150)))
		return;
	last_j = jiffies;

	/* Cheap hinted read first.  Do the expensive full-chain scan (and log)
	 * for the ACTUAL holder (held_raw>=EX — the FROZEN holder that wedges the
	 * cluster and MUST be captured throughout the 360s wedge, not just at r2)
	 * OR for a bounded transient sample of non-holders (first 400). */
	held_raw = mxfs_v5_dlm_inode_held_rawmode(mp->m_mxfs_dlm, ip->i_ino);
	if (held_raw < MXFS_LOCK_EX && n > 400)
		return;
	mine = mxfs_v5_dlm_inode_self_held_scan(mp->m_mxfs_dlm, ip->i_ino,
						&nslots, &hex_or);
	mxfs_probe("mxfs: P-ORPH-FORENSIC ino=%llu site=%d incore_mode=%u state=%u ex=%u pr=%u pin=%u held_raw=%u scan_mine=%d nslots=%d hex_or=%llx\n",
		(unsigned long long)ip->i_ino, site, ip->i_dlm_mode,
		ip->i_dlm_state, ip->i_dlm_ex_holders, ip->i_dlm_pr_holders,
		ip->i_dlm_pin_count, held_raw, mine, nslots,
		(unsigned long long)hex_or);

	/* PROVEN orphan (our bit on disk while incore says NL): dump the full
	 * per-inode transition ring ONCE so the formation line sequence is in
	 * the snapshot. */
	if (mine == 1 && ip->i_dlm_mode == MXFS_LOCK_NL &&
	    atomic_cmpxchg(&ring_dumped, 0, 1) == 0) {
		pr_warn("mxfs: P-ORPH-FORENSIC ino=%llu PROVEN-DISK-ORPHAN (scan_mine=1, incore NL) -- dumping transition ring (watch=%llu)\n",
			(unsigned long long)ip->i_ino,
			(unsigned long long)mxfs_watch_ino);
		mxfs_dlmtr_dump();
	}
}
int mxfs_dir_perf_probe;	/* when 1, log per dir-class FUA read (P15-DIRFUA) to diagnose the 8-node verify FUA-read storm. */
module_param_named(dir_perf_probe, mxfs_dir_perf_probe, int, 0644);

atomic64_t mxfs_dlm_stat_cache_hit;
atomic64_t mxfs_dlm_stat_cache_miss;
atomic64_t mxfs_dlm_stat_bast_immediate;
atomic64_t mxfs_dlm_stat_bast_deferred;
atomic64_t mxfs_dlm_stat_bast_no_inode;
atomic64_t mxfs_dlm_stat_ag_acquire;
atomic64_t mxfs_dlm_stat_ag_nested;
atomic64_t mxfs_dlm_stat_ag_release;
static uint64_t mxfs_dlm_stat_last_report;

/*
 * FUA-read instrumentation: count SCSI FUA reads by buffer class to
 * confirm the rsync_paired ~9.4s residual decomposition.  Incremented from
 * the FUA gate in pal/linux/xfs_buf.c via mxfs_fua_count().
 */
atomic64_t mxfs_fua_inode_reads;
atomic64_t mxfs_fua_dir_reads;
atomic64_t mxfs_fua_agmeta_reads;
atomic64_t mxfs_fua_inode_owned_skip;	/* inode FUA skipped because AG owned */
atomic64_t mxfs_fua_scsi_actual;	/* ACTUAL slow SCSI FUA reads issued */
atomic64_t mxfs_fua_p91_skip;		/* P91 in-core skips (cheap, no SCSI) */
atomic64_t mxfs_iget_cluster_staled;	/* cache-miss site DID stale the cluster */
atomic64_t mxfs_ccprev_reads;	/* /409: CREATE prev-changecount cluster reads (miss+recycle) */
atomic64_t mxfs_ccprev_nostale;	/* ... of which the cached cluster was locked (tp ICREATE/xfsaild) and read as cached */
atomic64_t mxfs_ccprev_tenure_hit;	/* ... of which the cached cluster was fresh under the current AG tenure (re-read skipped) */

/*
 * 0.84.16, test only (D-0947): the next N candidate validations in
 * xfs_dialloc read as magic-less whatever the platter holds, each consuming
 * one count, so the no-magic arm (kick the owed writes, cool the candidate
 * down, re-pick) can be driven on a healthy filesystem.  Read back as the
 * count still to consume; 0 in production.
 */
int mxfs_dbg_validate_nomagic_n = 0;
module_param_named(dbg_validate_nomagic_n, mxfs_dbg_validate_nomagic_n, int, 0644);
MODULE_PARM_DESC(dbg_validate_nomagic_n,
		 "TEST ONLY: make the next N inode-allocation candidates validate as magic-less (0=off)");
/* The persistent form: ONE inode number whose home always validates as
 * magic-less, for as long as the knob names it — the shape of the original
 * failure (one candidate, picked by every create in turn). */
unsigned long long mxfs_dbg_validate_nomagic_ino = 0;
module_param_named(dbg_validate_nomagic_ino, mxfs_dbg_validate_nomagic_ino, ullong, 0644);
MODULE_PARM_DESC(dbg_validate_nomagic_ino,
		 "TEST ONLY: this inode number always validates as magic-less (0=off)");

bool
mxfs_dbg_validate_nomagic_take(unsigned long long ino)
{
	int n;

	if (ino && READ_ONCE(mxfs_dbg_validate_nomagic_ino) == ino)
		return true;
	n = READ_ONCE(mxfs_dbg_validate_nomagic_n);
	if (n <= 0)
		return false;
	WRITE_ONCE(mxfs_dbg_validate_nomagic_n, n - 1);
	return true;
}
EXPORT_SYMBOL(mxfs_dbg_validate_nomagic_take);

/*
 * A resettable exact counter as a module parameter: read gives the count,
 * write sets it (a harness writes 0 at the start of a window and reads at the
 * end, instead of counting print-budgeted dmesg lines).
 */
static int
mxfs_dbg_atomic_param_set(const char *val, const struct kernel_param *kp)
{
	int	v;
	int	rc = kstrtoint(val, 0, &v);

	if (rc)
		return rc;
	atomic_set((atomic_t *)kp->arg, v);
	return 0;
}

static int
mxfs_dbg_atomic_param_get(char *buf, const struct kernel_param *kp)
{
	return sysfs_emit(buf, "%d\n", atomic_read((atomic_t *)kp->arg));
}

static const struct kernel_param_ops mxfs_dbg_atomic_param_ops = {
	.set = mxfs_dbg_atomic_param_set,
	.get = mxfs_dbg_atomic_param_get,
};

/*
 * D-0946: the allocator's own-obligation arm, counted exactly.  `refused` is
 * the fix (dialloc_pubpend_refuse=1), `allowed` the control arm; the
 * P946-VALIDATE-PUBPEND / -ALLOW lines print the first 32 and then one in
 * 500, so a harness that needs to know the arm was exercised reads these.
 */
atomic_t mxfs_dialloc_pubpend_refused = ATOMIC_INIT(0);
module_param_cb(dialloc_pubpend_refused, &mxfs_dbg_atomic_param_ops,
		&mxfs_dialloc_pubpend_refused, 0644);
MODULE_PARM_DESC(dialloc_pubpend_refused,
		 "count of allocation candidates refused because this node's own free of the number is not yet on the platter (write resets)");
atomic_t mxfs_dialloc_pubpend_allowed = ATOMIC_INIT(0);
module_param_cb(dialloc_pubpend_allowed, &mxfs_dbg_atomic_param_ops,
		&mxfs_dialloc_pubpend_allowed, 0644);
MODULE_PARM_DESC(dialloc_pubpend_allowed,
		 "count of such candidates ALLOWED under dialloc_pubpend_refuse=0, the A/B control arm (write resets)");
module_param_cb(p71_underflows, &mxfs_dbg_atomic_param_ops,
		&mxfs_p71_underflows, 0644);
MODULE_PARM_DESC(p71_underflows,
		 "count of inode DLM ends that found no holder to release (P71-UNDERFLOW), multi-node only (write resets)");
module_param_cb(noino_bast_reclaimable, &mxfs_dbg_atomic_param_ops,
		&mxfs_noino_bast_reclaimable, 0644);
MODULE_PARM_DESC(noino_bast_reclaimable,
		 "count of peer BASTs served by the no-inode release for an in-core RECLAIMABLE inode (write resets)");
module_param_cb(noino_gen0_releases, &mxfs_dbg_atomic_param_ops,
		&mxfs_noino_gen0_releases, 0644);
MODULE_PARM_DESC(noino_gen0_releases,
		 "count of no-inode releases whose BAST found no tenure of this node (rel_gen 0) (write resets)");
module_param_cb(noino_gen0_live, &mxfs_dbg_atomic_param_ops,
		&mxfs_noino_gen0_live, 0644);
MODULE_PARM_DESC(noino_gen0_live,
		 "count of those that met a tenure granted after the BAST when the release ran (P-NOINO-GEN0-LIVE) (write resets)");
module_param_cb(noino_gen0_refused, &mxfs_dbg_atomic_param_ops,
		&mxfs_noino_gen0_refused, 0644);
MODULE_PARM_DESC(noino_gen0_refused,
		 "count of those the guarded release refused because a generation-bearing grant was held (write resets)");
module_param_cb(sf_kept_ahead_reloads, &mxfs_dbg_atomic_param_ops,
		&mxfs_sf_kept_ahead_reloads, 0644);
MODULE_PARM_DESC(sf_kept_ahead_reloads,
		 "count of reloads that kept a shortform directory's in-core fork as ahead of the platter (write resets)");
module_param_cb(sf_kept_ahead_replaced, &mxfs_dbg_atomic_param_ops,
		&mxfs_sf_kept_ahead_replaced, 0644);
MODULE_PARM_DESC(sf_kept_ahead_replaced,
		 "count of those whose kept fork differed from the platter and replaced the merge base (sf_kept_ahead_base=0) (write resets)");
module_param_cb(sf_kept_ahead_kept, &mxfs_dbg_atomic_param_ops,
		&mxfs_sf_kept_ahead_kept, 0644);
MODULE_PARM_DESC(sf_kept_ahead_kept,
		 "count of those whose kept fork differed from the platter and left the merge base (sf_kept_ahead_base=1) (write resets)");
/*
 * D-FREED-INODE-HOME-NEVER-PUBLISHED-LIVE-CORE-AFTER-CLEAN-UNMOUNT: the node
 * that unlinked a file skipped the platter read at its inactivation whenever
 * it held a fresh EX, trusting its in-core image of the life.  A peer that had
 * the file open is its last closer and can free the life first; the unlinker's
 * EX then arrives after that free, and destructive inactivation of the dead
 * incarnation staged and published its live image over the peer's free.  The
 * fast path now needs the grant unbroken since the unlink (i_dlm_epoch equal
 * to i_mxfs_unlink_epoch).  inact_local_epoch_guard=0 is the same-build
 * control: the fast path as before, the platter read made only to report.
 */
int mxfs_inact_local_epoch_guard = 1;
module_param_named(inact_local_epoch_guard, mxfs_inact_local_epoch_guard, int, 0644);
MODULE_PARM_DESC(inact_local_epoch_guard,
		 "a local-unlink inactivation trusts its in-core image without a platter read only if the inode grant was never lost since the unlink (1=default; 0=always trust it, the same-build control)");
atomic_t mxfs_inact_local_epoch_moved = ATOMIC_INIT(0);
module_param_cb(inact_local_epoch_moved, &mxfs_dbg_atomic_param_ops,
		&mxfs_inact_local_epoch_moved, 0644);
MODULE_PARM_DESC(inact_local_epoch_moved,
		 "count of local-unlink inactivations under a fresh EX whose grant was lost since the unlink (write resets)");
atomic_t mxfs_inact_local_peerfreed = ATOMIC_INIT(0);
module_param_cb(inact_local_peerfreed, &mxfs_dbg_atomic_param_ops,
		&mxfs_inact_local_peerfreed, 0644);
MODULE_PARM_DESC(inact_local_peerfreed,
		 "count of those whose platter read found the life already freed or the number reused by a peer (P-INACT-LOCAL-EPOCH) (write resets)");
/*
 * D-LOCAL-UNLINK-INACT-AFTER-GRANT-LOSS-WRITES-STALE-CORE-OVER-PEER-CHANGE: the
 * guard above sends the inactivation to the platter, but it compared only the
 * mode and the generation there, so a peer's change of the same life (a
 * timestamp update or an append through a descriptor it held across the unlink)
 * read as 'ours'.  The truncate then logged the in-core core the peer had
 * superseded, and the inactivation's flush sanction put it home over the peer's
 * newer image (lap fv3c4: changecount 2563 written over 2564).  The inactivation
 * cannot reload an I_FREEING inode in place, so a same-incarnation platter image
 * with a higher changecount defers the free: nothing is dirtied, the grant is
 * released plainly, and the reaper's iget and ILOCK ride reload the core before
 * the free is tried again.  inact_local_cc_guard=0 is the same-build control:
 * the verdict is printed and the inactivation proceeds on the in-core image.
 */
int mxfs_inact_local_cc_guard = 1;
module_param_named(inact_local_cc_guard, mxfs_inact_local_cc_guard, int, 0644);
MODULE_PARM_DESC(inact_local_cc_guard,
		 "a local-unlink inactivation judged on the platter defers the free when the platter holds a newer changecount of the same life (1=default; 0=proceed on the in-core image, the same-build control)");
atomic_t mxfs_inact_local_peerchanged = ATOMIC_INIT(0);
module_param_cb(inact_local_peerchanged, &mxfs_dbg_atomic_param_ops,
		&mxfs_inact_local_peerchanged, 0644);
MODULE_PARM_DESC(inact_local_peerchanged,
		 "count of those whose platter held the same life with a higher changecount than the in-core inode (P-INACT-LOCAL-EPOCH verdict=peer-changed) (write resets)");
atomic_t mxfs_inact_local_cc_deferred = ATOMIC_INIT(0);
module_param_cb(inact_local_cc_deferred, &mxfs_dbg_atomic_param_ops,
		&mxfs_inact_local_cc_deferred, 0644);
MODULE_PARM_DESC(inact_local_cc_deferred,
		 "count of those whose free was deferred to the reaper for it (inact_local_cc_guard=1) (write resets)");
/*
 * TEST ONLY: the window inact_local_epoch_guard closes.  A peer's touch of the
 * file by name holds a reference across the unlink without an open mark; its
 * setattr then reads nlink 0, its iput frees the life, and the unlinker's
 * inactivation comes after.  On the rig the unlinker's inodegc runs within a
 * jiffy of its unlink and the peer's lookup-to-ILOCK gap is microseconds, so
 * the guard's A/B never reached its branch (inact_local_peerfreed 0 in every
 * lap).  The grant can be lost only while the unlinked inode is still live:
 * once it is NEED_INACTIVE or INACTIVATING, a peer's BAST is parked until the
 * inactivation ends (noino_lifecycle_requeue), so a delay inside the
 * inactivation opens nothing (hf6c, 4 laps: every touched inode's EX BAST on
 * the unlinker logged P-NOINO-LIFECYCLE class=NEED_INACTIVE, then
 * P-NOINO-LIFECYCLE-DONE).  ng0rf1 lost it between the unlink's commit and the
 * VFS's final iput, serving the peer's queued EX in core.
 * dbg_unlink_live_delay_ms holds that window: a regular-file unlink that
 * dropped the last link waits that long after its transaction commits, with
 * no XFS lock held and the inode still referenced by the unlinking task.
 * dbg_setattr_time_delay_ms holds a timestamp-only setattr of a regular file
 * that long before it takes any lock.  0 = off.
 */
int mxfs_dbg_unlink_live_delay_ms;
module_param_named(dbg_unlink_live_delay_ms, mxfs_dbg_unlink_live_delay_ms, int, 0644);
MODULE_PARM_DESC(dbg_unlink_live_delay_ms,
		 "TEST ONLY: ms a regular-file unlink that dropped the last link waits after its commit, before the final iput (0=off)");
int mxfs_dbg_setattr_time_delay_ms;
module_param_named(dbg_setattr_time_delay_ms, mxfs_dbg_setattr_time_delay_ms, int, 0644);
MODULE_PARM_DESC(dbg_setattr_time_delay_ms,
		 "TEST ONLY: ms a timestamp-only setattr of a regular file waits before taking any lock (0=off)");
/*
 * TEST ONLY, D-STALE-NAME-SETATTR's other operations: the reload's poison is
 * refused after the lock by each operation's own gate -- xfs_setattr_size for
 * a truncate, the namespace gate for a chmod or chown, the open path's P95 for
 * an open -- and the timestamp delay above holds only a touch.
 * dbg_setattr_delay_any 1 makes dbg_setattr_time_delay_ms hold every
 * regular-file setattr (size, mode, owner, times) at entry instead, before any
 * lock; dbg_open_delay_ms holds a multi-node regular-file open that long
 * between the VFS's lookup and the open's protecting acquire.  0 = off.
 */
int mxfs_dbg_setattr_delay_any;
module_param_named(dbg_setattr_delay_any, mxfs_dbg_setattr_delay_any, int, 0644);
MODULE_PARM_DESC(dbg_setattr_delay_any,
		 "TEST ONLY: dbg_setattr_time_delay_ms holds every regular-file setattr at entry, not only a timestamp-only one (0=off)");
int mxfs_dbg_open_delay_ms;
module_param_named(dbg_open_delay_ms, mxfs_dbg_open_delay_ms, int, 0644);
MODULE_PARM_DESC(dbg_open_delay_ms,
		 "TEST ONLY: ms a multi-node regular-file open waits between the lookup and its protecting acquire (0=off)");
/*
 * TEST ONLY: the context ng0rf1's inactivation ran in.  The two delays above
 * make the peer the last closer, but the unlinker's last reference is still
 * its own unlink's, so every lap inactivated as comm=rm, where the truncate's
 * ILOCK reloads the stale inode and adopts the peer's free (P116) before any
 * truncate.  ng0rf1's ran on the BAST worker: the worker serving the peer's EX
 * held its reference past the unlink's final iput, its trailing xfs_irele
 * (xfs_mxfs_bast.c mxfs_dlm_bast_work_fn) dropped the last one, and the
 * synchronous inactivation ran under its demoter claim, which the ILOCK hook
 * admits with no reload (H-F6a).  dbg_bast_lastref_wait_ms holds that
 * trailing irele, for an unlinked regular file this node removed, until the
 * work's reference is the only one or that many ms passed, so the work drops
 * the last reference on demand.  0 = off.
 */
int mxfs_dbg_bast_lastref_wait_ms;
module_param_named(dbg_bast_lastref_wait_ms, mxfs_dbg_bast_lastref_wait_ms, int, 0644);
MODULE_PARM_DESC(dbg_bast_lastref_wait_ms,
		 "TEST ONLY: ms the BAST work holds its trailing irele of a locally unlinked regular file until its reference is the last (0=off)");
atomic_t mxfs_bast_lastref_waits = ATOMIC_INIT(0);
module_param_cb(bast_lastref_waits, &mxfs_dbg_atomic_param_ops,
		&mxfs_bast_lastref_waits, 0644);
MODULE_PARM_DESC(bast_lastref_waits,
		 "count of BAST works that held their trailing irele for dbg_bast_lastref_wait_ms (write resets)");
atomic_t mxfs_bast_lastref_reached = ATOMIC_INIT(0);
module_param_cb(bast_lastref_reached, &mxfs_dbg_atomic_param_ops,
		&mxfs_bast_lastref_reached, 0644);
MODULE_PARM_DESC(bast_lastref_reached,
		 "count of those whose reference was the last when the hold ended (P-BAST-LASTREF-WAIT reached=1) (write resets)");
/*
 * TEST ONLY: the second half of ng0rf1's window.  The no-reload truncate logs
 * the dead life's core, but on its own it puts nothing home: the inactivation's
 * raw EX leaves i_dlm_mode at NL, so a flush after MXFS_IF_DLM_RELFLUSH clears
 * is refused (P119) and a staging from a dead tenure is masked (P222), and
 * that is how the first BAST-order lap (lrc1, 19 peer-freed truncates on the
 * BAST worker) audited CLEAN.  ng0rf1's xfsaild copied the core into its
 * cluster buffer while the token was still set (P240-COPYIN-ID, 6 ms after the
 * grant, the truncate waiting at the AG seam) and the write followed.
 * dbg_inact_relflush_hold_ms makes that happen on demand: after a local-unlink
 * inactivation's truncate, with the token still set, the log is forced and
 * this inode's item drained through the AIL (bounded by the knob's ms).
 * 0 = off.
 */
int mxfs_dbg_inact_relflush_hold_ms;
module_param_named(dbg_inact_relflush_hold_ms, mxfs_dbg_inact_relflush_hold_ms, int, 0644);
MODULE_PARM_DESC(dbg_inact_relflush_hold_ms,
		 "TEST ONLY: after a local-unlink inactivation's truncate, with MXFS_IF_DLM_RELFLUSH set, force the log and drain the inode through the AIL for at most this many ms (0=off)");
atomic_t mxfs_inact_relflush_holds = ATOMIC_INIT(0);
module_param_cb(inact_relflush_holds, &mxfs_dbg_atomic_param_ops,
		&mxfs_inact_relflush_holds, 0644);
MODULE_PARM_DESC(inact_relflush_holds,
		 "count of inactivations drained under the token by dbg_inact_relflush_hold_ms (P-INACT-RELFLUSH-HOLD) (write resets)");

void
mxfs_dbg_bast_lastref_wait(
	struct xfs_inode	*ip)
{
	static atomic_t		pblw_n = ATOMIC_INIT(0);
	int			budget = READ_ONCE(mxfs_dbg_bast_lastref_wait_ms);
	int			waited = 0;
	int			cnt;

	if (budget <= 0 || !S_ISREG(VFS_I(ip)->i_mode) ||
	    VFS_I(ip)->i_nlink != 0 ||
	    !xfs_iflags_test(ip, MXFS_IF_LOCAL_UNLINK))
		return;
	atomic_inc(&mxfs_bast_lastref_waits);
	while ((cnt = atomic_read(&VFS_I(ip)->i_count)) > 1 &&
	       waited < budget) {
		msleep(10);
		waited += 10;
	}
	if (cnt == 1)
		atomic_inc(&mxfs_bast_lastref_reached);
	if (atomic_inc_return(&pblw_n) <= 2000)
		pr_warn("mxfs: P-BAST-LASTREF-WAIT ino=%llu gen=%u waited_ms=%d i_count=%d reached=%d comm=%s -- TEST ONLY: the BAST work held its trailing irele until its reference was the last\n",
			(unsigned long long)ip->i_ino,
			VFS_I(ip)->i_generation, waited, cnt,
			cnt == 1 ? 1 : 0, current->comm);
}
/*
 * D-TCP-LEDGER-SMALLFILE-WORKLOAD-PACE-RULE0-0349 (ruling
 * docs/rulings/d0349-batched-reserve-ahead.md): on the TCP transport with a
 * peer mounted, the allocator's reserve of each new inode number is a durable
 * ledger grant at the number's master, and a single creator pays one commit
 * per file, one after another.  resv_ahead=N requests the next N free numbers
 * of the inobt record a create just reserved in, concurrently and outside
 * every XFS lock (xfs_ialloc.c mxfs_resv_ahead_queue), so the commits overlap
 * and the creates that follow find their grant already held.  0 is off, the
 * same-build control.
 */
int mxfs_resv_ahead;
module_param_named(resv_ahead, mxfs_resv_ahead, int, 0644);
MODULE_PARM_DESC(resv_ahead,
		 "free inode numbers of the allocator's current inobt record to reserve ahead of the creates (0=off, the same-build control; at most 64)");
atomic_t mxfs_resv_ahead_queued = ATOMIC_INIT(0);
module_param_cb(resv_ahead_queued, &mxfs_dbg_atomic_param_ops,
		&mxfs_resv_ahead_queued, 0644);
MODULE_PARM_DESC(resv_ahead_queued,
		 "count of reserve-ahead requests queued (write resets)");
atomic_t mxfs_resv_ahead_granted = ATOMIC_INIT(0);
module_param_cb(resv_ahead_granted, &mxfs_dbg_atomic_param_ops,
		&mxfs_resv_ahead_granted, 0644);
MODULE_PARM_DESC(resv_ahead_granted,
		 "count of reserve-ahead requests granted (write resets)");
atomic_t mxfs_resv_ahead_denied = ATOMIC_INIT(0);
module_param_cb(resv_ahead_denied, &mxfs_dbg_atomic_param_ops,
		&mxfs_resv_ahead_denied, 0644);
MODULE_PARM_DESC(resv_ahead_denied,
		 "count of reserve-ahead requests refused because another node holds the number (write resets)");
atomic_t mxfs_resv_ahead_err = ATOMIC_INIT(0);
module_param_cb(resv_ahead_err, &mxfs_dbg_atomic_param_ops,
		&mxfs_resv_ahead_err, 0644);
MODULE_PARM_DESC(resv_ahead_err,
		 "count of reserve-ahead requests that failed for any other reason, or were dropped at unmount (write resets)");
atomic_t mxfs_resv_ahead_consumed = ATOMIC_INIT(0);
module_param_cb(resv_ahead_consumed, &mxfs_dbg_atomic_param_ops,
		&mxfs_resv_ahead_consumed, 0644);
MODULE_PARM_DESC(resv_ahead_consumed,
		 "count of creates whose number had been requested ahead (write resets)");
atomic_t mxfs_resv_ahead_capped = ATOMIC_INIT(0);
module_param_cb(resv_ahead_capped, &mxfs_dbg_atomic_param_ops,
		&mxfs_resv_ahead_capped, 0644);
MODULE_PARM_DESC(resv_ahead_capped,
		 "count of reserve-ahead requests not queued because the mount already had its limit in flight (write resets)");
module_param_cb(recycle_grant_cached, &mxfs_dbg_atomic_param_ops,
		&mxfs_recycle_grant_cached, 0644);
MODULE_PARM_DESC(recycle_grant_cached,
		 "count of reclaimable-inode recycles that found a cached DLM grant in core (write resets)");
module_param_cb(recycle_grant_phantom, &mxfs_dbg_atomic_param_ops,
		&mxfs_recycle_grant_phantom, 0644);
MODULE_PARM_DESC(recycle_grant_phantom,
		 "count of those recycles where the DLM mirror no longer held the cached mode (P-RECYCLE-PHANTOM) (write resets)");
/*
 * D-FREED-INODE-HOME-NEVER-PUBLISHED-LIVE-CORE-AFTER-CLEAN-UNMOUNT, H-F7: the
 * no-inode release decides its unlock from a live check that cannot see a
 * reclaimable corpse (xfs_iget INCORE refuses one), and the recycle that puts
 * the corpse back into service decides from the DLM's record while that
 * release may still be in flight.  If the recycle keeps the cached grant and
 * the release then unlocks it, the live inode goes on writing at an EX the
 * DLM has handed to a peer.  These count both sides of that window and the
 * logging it would leave behind.
 */
atomic_t mxfs_recycle_keep_noino = ATOMIC_INIT(0);
module_param_cb(recycle_keep_noino, &mxfs_dbg_atomic_param_ops,
		&mxfs_recycle_keep_noino, 0644);
MODULE_PARM_DESC(recycle_keep_noino,
		 "count of recycles that kept a cached grant while a no-inode release of the same inode was in flight (P-RECYCLE-KEEP-UNDER-NOINO) (write resets)");
atomic_t mxfs_noino_unlock_left_grant = ATOMIC_INIT(0);
module_param_cb(noino_unlock_left_grant, &mxfs_dbg_atomic_param_ops,
		&mxfs_noino_unlock_left_grant, 0644);
MODULE_PARM_DESC(noino_unlock_left_grant,
		 "count of no-inode releases that unlocked while an in-core inode of the number carried a cached grant (P-NOINO-UNLOCK-LEFT-GRANT) (write resets)");
int mxfs_dbg_log_mirror_check;
module_param_named(dbg_log_mirror_check, mxfs_dbg_log_mirror_check, int, 0644);
MODULE_PARM_DESC(dbg_log_mirror_check,
		 "TEST ONLY: at every logging of a regular file at a cached EX, ask the DLM whether it still records that grant for this node (P-LOG-MIRROR-PHANTOM) (0=off)");
atomic_t mxfs_log_mirror_phantom = ATOMIC_INIT(0);
module_param_cb(log_mirror_phantom, &mxfs_dbg_atomic_param_ops,
		&mxfs_log_mirror_phantom, 0644);
MODULE_PARM_DESC(log_mirror_phantom,
		 "count of regular-file loggings at a cached EX that the DLM no longer records for this node (write resets)");
/*
 * The write side of the same question, under the same knob: a logged slot
 * carrying a live core goes to its home while the DLM records no EX of this
 * node for the inode -- the shape of both corrupting writes traced so far
 * (pal/linux/xfs_buf.c, P-LOGWR-DLM-NOGRANT; TCP only).
 */
atomic_t mxfs_logwr_dlm_nogrant = ATOMIC_INIT(0);
module_param_cb(logwr_dlm_nogrant, &mxfs_dbg_atomic_param_ops,
		&mxfs_logwr_dlm_nogrant, 0644);
MODULE_PARM_DESC(logwr_dlm_nogrant,
		 "count of logged live inode images written home while the DLM recorded no EX of this node (P-LOGWR-DLM-NOGRANT, dbg_log_mirror_check) (write resets)");

/*
 * Under the same knob, the other end of such a write: a free release
 * (mxfs_v5_dlm_inode_unlock_free) names no tenure and retires whatever grant
 * of ours it meets.  The H-F7 fix arm logged a published live life written
 * home at a cached EX 3.5 ms after this node's own free release of the number
 * (pmf4, ino 2097292), with no no-inode release anywhere near it.  Each free
 * release says which life it is for and which generation the DLM holds for the
 * number as it goes; a P-LOGWR-DLM-NOGRANT whose cgen equals that generation
 * names the life that was riding the retired grant.  Detection only, TCP only
 * (the generation is exact there).
 */
void
mxfs_free_release_probe(
	struct xfs_inode	*ip,
	const char		*site)
{
	static atomic_t		p_frel_n = ATOMIC_INIT(0);
	struct xfs_mount	*mp = ip->i_mount;

	if (likely(!READ_ONCE(mxfs_dbg_log_mirror_check)) || !mp->m_mxfs_dlm ||
	    !mxfs_v5_dlm_is_tcp(mp->m_mxfs_dlm))
		return;
	if (atomic_inc_return(&p_frel_n) > 20000)
		return;
	pr_warn("mxfs: P-FREE-RELEASE site=%s ino=%llu gen=%u cgen=%u dlm_gen=%u mode=%u state=%u iflags=0x%lx nlink=%u reused=%d comm=%s -- a free release, generation 0, of this life's grant\n",
		site, (unsigned long long)ip->i_ino, VFS_I(ip)->i_generation,
		ip->i_dlm_cached_grant_gen,
		mxfs_v5_dlm_inode_grant_gen(mp->m_mxfs_dlm, ip->i_ino),
		ip->i_dlm_mode, ip->i_dlm_state, ip->i_flags,
		VFS_I(ip)->i_nlink, ip->i_mxfs_reused_create ? 1 : 0,
		current->comm);
}
/*
 * The same hypothesis, the decisive half: the release's drain fence covers what
 * this node committed before the fence's last log force, so a change committed
 * through a recycled corpse after it is still in core when the unlock hands the
 * inode to the peer.  Counted at the unlock itself, from the inode log item.
 */
atomic_t mxfs_noino_unlock_undrained = ATOMIC_INIT(0);
module_param_cb(noino_unlock_undrained, &mxfs_dbg_atomic_param_ops,
		&mxfs_noino_unlock_undrained, 0644);
MODULE_PARM_DESC(noino_unlock_undrained,
		 "count of no-inode releases that unlocked while the in-core inode of the number still held committed changes not yet on the platter (P-NOINO-UNLOCK-UNDRAINED) (write resets)");
/*
 * D-FREED-INODE-HOME-NEVER-PUBLISHED-LIVE-CORE-AFTER-CLEAN-UNMOUNT, H-F8: the
 * protective reload's P5F arm (xfs/xfs_mxfs_reload.c) kept a clean shell's
 * cached image over the platter's FREE image because the reload's own fresh
 * grant was held.  freshsrc_keep_guard 1 (default) keeps it only for a shell
 * with committed changes not yet on the platter; 0 is the old rule, the
 * same-build control.  keep_clean counts the hazard (a clean shell kept on the
 * grant alone), clean_refused the guard's reach.
 */
int mxfs_freshsrc_keep_guard = 1;
module_param_named(freshsrc_keep_guard, mxfs_freshsrc_keep_guard, int, 0644);
MODULE_PARM_DESC(freshsrc_keep_guard,
		 "a protective reload keeps a cached image over the platter's FREE image only when the in-core inode has committed changes not yet on the platter (1=default; 0=a held grant also keeps it, the same-build control)");
atomic_t mxfs_freshsrc_keep_clean = ATOMIC_INIT(0);
module_param_cb(freshsrc_keep_clean, &mxfs_dbg_atomic_param_ops,
		&mxfs_freshsrc_keep_clean, 0644);
MODULE_PARM_DESC(freshsrc_keep_clean,
		 "count of protective reloads that kept a CLEAN shell's cached image over the platter's FREE image on the held grant alone (P5F clean_held=1) (write resets)");
atomic_t mxfs_freshsrc_clean_refused = ATOMIC_INIT(0);
module_param_cb(freshsrc_clean_refused, &mxfs_dbg_atomic_param_ops,
		&mxfs_freshsrc_clean_refused, 0644);
MODULE_PARM_DESC(freshsrc_clean_refused,
		 "count of protective reloads where freshsrc_keep_guard refused that keep (P5F-FRESHSRC-CLEAN-REFUSED) (write resets)");
/*
 * D-PEER-OPEN-UNLINKED-CHAIN-REMOVE-FAILS-IFREE-SHUTDOWN-BOTH-NODES, H-U3: the
 * protective reload's fresh-source arm (xfs/xfs_mxfs_reload.c) adopts a slot's
 * whole dinode from a private read of the platter, di_next_unlinked included,
 * while this node's own committed edit of that pointer is still only in the
 * kept buffer and the iunlink store.  It reverted a predecessor's next pointer
 * to the inode just removed, and the predecessor's own remove then pointed the
 * bucket at a free inode.  freshsrc_iunl_overlay 1 (default) grafts the store's
 * committed values onto the fresh image before it is adopted, as the buffer
 * read, write and cluster-merge paths do; 0 adopts the platter's bytes, the
 * same-build control.  freshsrc_iunl_stale counts the reloads whose image
 * carried a stale next pointer for the reloaded inode, in either arm (the
 * hazard's reach); freshsrc_iunl_overlaid those the graft corrected.
 */
int mxfs_freshsrc_iunl_overlay = 1;
module_param_named(freshsrc_iunl_overlay, mxfs_freshsrc_iunl_overlay, int, 0644);
MODULE_PARM_DESC(freshsrc_iunl_overlay,
		 "a protective reload grafts this node's committed, not yet landed di_next_unlinked values onto the platter image it adopts (1=default; 0=adopts the platter's bytes, the same-build control)");
atomic_t mxfs_freshsrc_iunl_stale = ATOMIC_INIT(0);
module_param_cb(freshsrc_iunl_stale, &mxfs_dbg_atomic_param_ops,
		&mxfs_freshsrc_iunl_stale, 0644);
MODULE_PARM_DESC(freshsrc_iunl_stale,
		 "count of protective reloads whose platter image carried a di_next_unlinked for the reloaded inode older than this node's committed value (P-FRESHSRC-IUNL-STALE), with or without the graft (write resets)");
atomic_t mxfs_freshsrc_iunl_overlaid = ATOMIC_INIT(0);
module_param_cb(freshsrc_iunl_overlaid, &mxfs_dbg_atomic_param_ops,
		&mxfs_freshsrc_iunl_overlaid, 0644);
MODULE_PARM_DESC(freshsrc_iunl_overlaid,
		 "count of those reloads where the graft put the committed di_next_unlinked into the image before the adopt (P-FRESHSRC-IUNL-STALE grafted=1) (write resets)");
/*
 * The same defect, H-U4: a mid-list unlinked remove rewrites the PREDECESSOR's
 * di_next_unlinked, a field of another inode's slot, under the AG DLM alone,
 * and a peer holding that predecessor's inode EX publishes the whole slot from
 * its own cluster buffer, whose copy of the field predates the edit: the
 * platter reverts to a removed inode.  unlprev_tenure 1 (default) makes the
 * edit under the predecessor's own EX (xfs_inactive_ifree takes it as a counted
 * hold, never while holding the AG DLM), lands it before that inode's lock
 * leaves the node (mxfs_iunl_store_land), and refreshes a kept cluster
 * buffer's copy of the field from the platter at the next acquire
 * (xfs/xfs_mxfs_reload.c); 0 is the same-build control.  The counters count in
 * both arms: unlprev_notenure, edits of a predecessor this node held no EX hold
 * on (P-UNLPREV-NOTENURE); nextwr_stale, flushed slots whose next pointer
 * differed from the platter's with no store record behind it (P-NEXTWR-STALE);
 * iunl_owed_release, inode releases that still owed such an edit
 * (P-IUNL-OWED-AT-RELEASE, landed=0 in the control); kept_next_stale, kept
 * buffers whose copy of the field was older than the platter's
 * (P-KEPT-NEXT-STALE); unlprev_waits, frees that backed off to take the hold.
 */
int mxfs_unlprev_tenure = 1;
module_param_named(unlprev_tenure, mxfs_unlprev_tenure, int, 0644);
MODULE_PARM_DESC(unlprev_tenure,
		 "a mid-list unlinked remove edits its predecessor's di_next_unlinked only under that predecessor's inode EX, lands the edit before the lock leaves, and a kept cluster buffer's copy is refreshed at the next acquire (1=default; 0=the same-build control)");
atomic_t mxfs_unlprev_notenure = ATOMIC_INIT(0);
module_param_cb(unlprev_notenure, &mxfs_dbg_atomic_param_ops,
		&mxfs_unlprev_notenure, 0644);
MODULE_PARM_DESC(unlprev_notenure,
		 "count of mid-list unlinked removes that edited a predecessor this node held no EX hold on (P-UNLPREV-NOTENURE) (write resets)");
atomic_t mxfs_unlprev_waits = ATOMIC_INIT(0);
module_param_cb(unlprev_waits, &mxfs_dbg_atomic_param_ops,
		&mxfs_unlprev_waits, 0644);
MODULE_PARM_DESC(unlprev_waits,
		 "count of inode frees that backed off the AG DLM to take their predecessor's EX hold (P-UNLPREV-WAIT) (write resets)");
atomic_t mxfs_nextwr_stale = ATOMIC_INIT(0);
module_param_cb(nextwr_stale, &mxfs_dbg_atomic_param_ops,
		&mxfs_nextwr_stale, 0644);
MODULE_PARM_DESC(nextwr_stale,
		 "count of flushed inode slots whose di_next_unlinked differed from the platter's with no iunlink store record behind it (P-NEXTWR-STALE) (write resets)");
atomic_t mxfs_iunl_owed_release = ATOMIC_INIT(0);
module_param_cb(iunl_owed_release, &mxfs_dbg_atomic_param_ops,
		&mxfs_iunl_owed_release, 0644);
MODULE_PARM_DESC(iunl_owed_release,
		 "count of inode lock releases that still owed a committed di_next_unlinked of their slot (P-IUNL-OWED-AT-RELEASE) (write resets)");
atomic_t mxfs_kept_next_stale = ATOMIC_INIT(0);
module_param_cb(kept_next_stale, &mxfs_dbg_atomic_param_ops,
		&mxfs_kept_next_stale, 0644);
MODULE_PARM_DESC(kept_next_stale,
		 "count of protective reloads whose kept cluster buffer carried an older di_next_unlinked for the reloaded inode than the platter (P-KEPT-NEXT-STALE) (write resets)");
/*
 * The same defect, H-U1: a mid-list unlinked remove looks its predecessor up in
 * core (xfs_iunlink_remove_inode) and fails -EFSCORRUPTED, with the transaction
 * already dirty, when it is gone (P-UNLREM-NOPREV), so the node shuts down.  A
 * bucket's owner holds no reference to a member a peer holds open: its copy
 * goes reclaimable when the owner's inactivation defers for the open holder,
 * and a cache drop reclaims it.  The preflight that loads and pins the
 * predecessor ran only when the freed inode's own chain state was incomplete.
 * unlprev_pin 1 (default) pins a live in-core predecessor of a mid-list free
 * for the length of the free and runs the preflight when it is absent, a
 * reclaimable shell or mid-evict; 0 is the same-build control.  The counters
 * count in both arms: unlprev_absent, mid-list frees whose recorded predecessor
 * was absent, reclaimable or mid-evict at that check (P-UNLPREV-ABSENT);
 * unlprev_pinned, those the preflight then loaded and pinned.
 * dbg_ifree_midlist_delay_ms (TEST ONLY) holds a mid-list free that long
 * before it starts, with no AG lock held, so a cache drop can reclaim the
 * predecessor first; 0 = off.
 */
int mxfs_unlprev_pin = 1;
module_param_named(unlprev_pin, mxfs_unlprev_pin, int, 0644);
MODULE_PARM_DESC(unlprev_pin,
		 "a mid-list inode free pins its predecessor before the remove, loading it through the preflight when it is not live in core (1=default; 0=the same-build control)");
atomic_t mxfs_unlprev_absent = ATOMIC_INIT(0);
module_param_cb(unlprev_absent, &mxfs_dbg_atomic_param_ops,
		&mxfs_unlprev_absent, 0644);
MODULE_PARM_DESC(unlprev_absent,
		 "count of mid-list inode frees whose predecessor was absent, reclaimable or mid-evict in core (P-UNLPREV-ABSENT) (write resets)");
atomic_t mxfs_unlprev_pinned = ATOMIC_INIT(0);
module_param_cb(unlprev_pinned, &mxfs_dbg_atomic_param_ops,
		&mxfs_unlprev_pinned, 0644);
MODULE_PARM_DESC(unlprev_pinned,
		 "count of those whose preflight then loaded and pinned the predecessor (write resets)");
int mxfs_dbg_ifree_midlist_delay_ms;
module_param_named(dbg_ifree_midlist_delay_ms, mxfs_dbg_ifree_midlist_delay_ms, int, 0644);
MODULE_PARM_DESC(dbg_ifree_midlist_delay_ms,
		 "TEST ONLY: ms a mid-list inode free waits before it starts, holding no AG lock (0=off)");
/*
 * D-IUNLINK-PREV-OF-PEER-FREED-INODE-STALE-PRECOMMIT-SHUTDOWN, H-IU1: H-U4's
 * free drops the AG DLM to take its predecessor's EX hold, and the
 * predecessor's owner can take it off the list and free it in that gap; the
 * retry then edited a free inode's next pointer, the precommit found NULLAGINO
 * where it expected the freed inode, and the node shut down.  Under the hold
 * the predecessor's core is current, so unlprev_held_verify 1 (default)
 * requires it to be live, unlinked and pointing at the freed inode, and on a
 * miss clears the freed inode's prev pointer and starts the free over so the
 * preflight rebuilds the chain from the platter; 0 is the same-build control.
 * The counters count in both arms: unlprev_held_moved, held predecessors that
 * failed the check (P-UNLPREV-MOVED); unlprev_rebuilds, frees started over for
 * it.  dbg_unlprev_wait_delay_ms (TEST ONLY) sleeps after the free has dropped
 * the AG DLM, ILOCK and transaction and before it asks for the hold; 0 = off.
 */
int mxfs_unlprev_held_verify = 1;
module_param_named(unlprev_held_verify, mxfs_unlprev_held_verify, int, 0644);
MODULE_PARM_DESC(unlprev_held_verify,
		 "a mid-list inode free re-checks, under the predecessor's EX hold, that the predecessor is still live, unlinked and pointing at it, and rebuilds the chain when it is not (1=default; 0=the same-build control)");
atomic_t mxfs_unlprev_held_moved = ATOMIC_INIT(0);
module_param_cb(unlprev_held_moved, &mxfs_dbg_atomic_param_ops,
		&mxfs_unlprev_held_moved, 0644);
MODULE_PARM_DESC(unlprev_held_moved,
		 "count of held predecessors no longer live, unlinked and pointing at the freed inode (P-UNLPREV-MOVED) (write resets)");
atomic_t mxfs_unlprev_rebuilds = ATOMIC_INIT(0);
module_param_cb(unlprev_rebuilds, &mxfs_dbg_atomic_param_ops,
		&mxfs_unlprev_rebuilds, 0644);
MODULE_PARM_DESC(unlprev_rebuilds,
		 "count of inode frees started over to rebuild a stale unlinked chain view (P-UNLPREV-REBUILD) (write resets)");
int mxfs_dbg_unlprev_wait_delay_ms;
module_param_named(dbg_unlprev_wait_delay_ms, mxfs_dbg_unlprev_wait_delay_ms, int, 0644);
MODULE_PARM_DESC(dbg_unlprev_wait_delay_ms,
		 "TEST ONLY: ms an inode free waits, holding nothing, between dropping the AG DLM and asking for its predecessor's EX hold (0=off)");
/*
 * The same defect, H-U5: xfs_inactive's open-holder deferral (B6) releases its
 * EX grant raw so that the reaper's retry takes a fresh one, and the unlink it
 * follows is usually not at home yet; the next EX tenure on this node then
 * meets that state as a P17B ghost and the AIL freezes behind it.
 * b6_release_drain 1 (default) lands the inode's committed state before the
 * release (log force, the bounded per-inode AIL drain, buftarg wait, device
 * flush) and keeps the grant cached when the bound runs out; 0 is the
 * same-build control, which releases raw.  The counters count in both arms:
 * b6_release_dirty, B6 releases that found the inode pinned, logging fields or
 * in the AIL (P-B6-RELEASE-DIRTY); b6_release_drained, those the drain landed;
 * b6_release_kept, those whose grant stayed cached.
 */
int mxfs_b6_release_drain = 1;
module_param_named(b6_release_drain, mxfs_b6_release_drain, int, 0644);
MODULE_PARM_DESC(b6_release_drain,
		 "an inactivation deferred for a peer's open holder lands the inode's committed state before it releases its grant, or keeps the grant cached (1=default; 0=releases raw, the same-build control)");
atomic_t mxfs_b6_release_dirty = ATOMIC_INIT(0);
module_param_cb(b6_release_dirty, &mxfs_dbg_atomic_param_ops,
		&mxfs_b6_release_dirty, 0644);
MODULE_PARM_DESC(b6_release_dirty,
		 "count of open-holder-deferred inactivations whose grant release found the inode's committed state not at home (P-B6-RELEASE-DIRTY) (write resets)");
atomic_t mxfs_b6_release_drained = ATOMIC_INIT(0);
module_param_cb(b6_release_drained, &mxfs_dbg_atomic_param_ops,
		&mxfs_b6_release_drained, 0644);
MODULE_PARM_DESC(b6_release_drained,
		 "count of those releases the drain landed first (P-B6-RELEASE-DIRTY drained=1) (write resets)");
atomic_t mxfs_b6_release_kept = ATOMIC_INIT(0);
module_param_cb(b6_release_kept, &mxfs_dbg_atomic_param_ops,
		&mxfs_b6_release_kept, 0644);
MODULE_PARM_DESC(b6_release_kept,
		 "count of those whose bounded drain could not land the state, so the grant stayed cached (P-B6-RELEASE-DIRTY kept=1) (write resets)");
/*
 * D-INACT-DEFERRED-FREE-LOSES-TRUNCATED-CORE-AND-REAP-AUTHORITY, H-1: a free
 * that xfs_inactive_ifree defers (the unlinked-list preflight, P-UNLPRE-SKIP,
 * or the predecessor's hold, P-UNLPREV-DEFER) leaves the truncate this
 * inactivation committed before it not at home.  The raw EX the inactivation
 * runs under never sets i_dlm_mode, so when the cached mode is not EX the
 * truncate's only flush sanction is MXFS_IF_DLM_RELFLUSH, which the exit
 * clears; every later flush is refused (P119) and retired unwritten, and the
 * peer reads the pre-truncate core, naming the blocks the truncate freed.
 * ifree_defer_drain 1 (default) lands the inode's committed state with the B6
 * drain's bounded chain while the sanction still holds, and fails closed
 * (shutdown) when the bound runs out with the cached mode not EX, since no
 * later flush could write the change; 0 is the same-build control, which only
 * counts.  The counters count in both arms: ifree_defer_dirty, deferred frees
 * leaving with committed state not at home (P-IFREE-DEFER-DIRTY);
 * ifree_defer_drained, those the drain landed; ifree_defer_unlanded, those
 * that failed closed.
 */
/*
 * D-OPEN-EFI-DEATH-REPLAY-REFUSED-NOT-HELD-VICTIM-DOMAIN-QUARANTINED-2TCP: an
 * inactivation whose tenure stamped a token released its grant with no
 * clean-release marker (P-RELMARK-OWED), so when a held EFI kept that tenure's
 * transactions in the replay window and the node died, the survivor could show
 * neither a holder at death nor a clean release and refused the replay
 * not-held.  inact_relmark 1 (default) publishes the marker before that
 * release, with the core home and the device flushed (P-RELMARK-INACT); 0 is
 * the same-build control, which releases unmarked as before.
 */
int mxfs_inact_relmark = 1;
module_param_named(inact_relmark, mxfs_inact_relmark, int, 0644);
MODULE_PARM_DESC(inact_relmark,
		 "an inactivation whose tenure stamped a token publishes its clean-release marker before releasing its grant (1=default; 0=the same-build control)");
int mxfs_ifree_defer_drain = 1;
module_param_named(ifree_defer_drain, mxfs_ifree_defer_drain, int, 0644);
MODULE_PARM_DESC(ifree_defer_drain,
		 "an inactivation whose free is deferred lands the state it committed before releasing its grant, failing closed when it cannot (1=default; 0=the same-build control)");
atomic_t mxfs_ifree_defer_dirty = ATOMIC_INIT(0);
module_param_cb(ifree_defer_dirty, &mxfs_dbg_atomic_param_ops,
		&mxfs_ifree_defer_dirty, 0644);
MODULE_PARM_DESC(ifree_defer_dirty,
		 "count of deferred inode frees whose inactivation left committed state not at home (P-IFREE-DEFER-DIRTY) (write resets)");
atomic_t mxfs_ifree_defer_drained = ATOMIC_INIT(0);
module_param_cb(ifree_defer_drained, &mxfs_dbg_atomic_param_ops,
		&mxfs_ifree_defer_drained, 0644);
MODULE_PARM_DESC(ifree_defer_drained,
		 "count of those the drain landed before the grant release (P-IFREE-DEFER-DIRTY drained=1) (write resets)");
atomic_t mxfs_ifree_defer_unlanded = ATOMIC_INIT(0);
module_param_cb(ifree_defer_unlanded, &mxfs_dbg_atomic_param_ops,
		&mxfs_ifree_defer_unlanded, 0644);
MODULE_PARM_DESC(ifree_defer_unlanded,
		 "count of those whose bounded drain could not land the state with the cached mode not EX, so the node failed closed (P-IFREE-DEFER-UNLANDED-FATAL) (write resets)");
/*
 * D-IFREE-DEFER-UNLANDED-FATAL-SHUTDOWN-BEHIND-LOCKED-CLUSTER-BUFFER, H-IFD1:
 * the drain above takes its 200 ms bound (ifree_drain_ms) from the
 * inactivation that holds the AG DLM across its drain, where a peer's AG BAST
 * waits on it.  The deferred free holds neither the AG DLM nor the ILOCK, and
 * its bound ran out in lap ifd2 while xfsaild was writing the cluster buffer
 * that carried the state (copied in 152 ms into the drain, the buffer locked
 * for the write 1 ms before the bound), so the node failed closed over a write
 * in flight.  1 keeps draining without a bound when the bound runs out with
 * the cached mode not EX (the forward-progress contract the BAST release
 * path's drains wait under) and fails closed only if the state still owes home
 * once the item has landed; 0 is the same-build control, which fails closed at
 * the bound.  ifree_defer_extended counts the drains whose bound ran out with
 * the cached mode not EX, in both settings (P-IFREE-DEFER-EXTENDED).
 */
int mxfs_ifree_defer_extend = 1;
module_param_named(ifree_defer_extend, mxfs_ifree_defer_extend, int, 0644);
MODULE_PARM_DESC(ifree_defer_extend,
		 "a deferred free whose bounded drain runs out with the cached mode not EX keeps draining until the state lands instead of failing closed (1=default; 0=the same-build control)");
atomic_t mxfs_ifree_defer_extended = ATOMIC_INIT(0);
module_param_cb(ifree_defer_extended, &mxfs_dbg_atomic_param_ops,
		&mxfs_ifree_defer_extended, 0644);
MODULE_PARM_DESC(ifree_defer_extended,
		 "count of deferred-free drains whose bound ran out with the cached mode not EX (P-IFREE-DEFER-EXTENDED), extended or not (write resets)");
/*
 * TEST ONLY, for the H-IFD1 A/B: a bound in ms for the deferred free's drain
 * in place of ifree_drain_ms (0, the default, keeps ifree_drain_ms).  Under
 * the lap's load about one deferred-free drain in six takes 50 ms or more and
 * about one in ninety more than 200 ms, so a short bound meets the arm the
 * A/B grades in most laps instead of one in four.
 */
int mxfs_dbg_ifree_defer_bound_ms;
module_param_named(dbg_ifree_defer_bound_ms, mxfs_dbg_ifree_defer_bound_ms, int, 0644);
MODULE_PARM_DESC(dbg_ifree_defer_bound_ms,
		 "TEST ONLY: the deferred free's drain bound in ms in place of ifree_drain_ms (0=ifree_drain_ms)");
/*
 * The same defect, H-2: the P-UNLPRE-SKIP deferral recorded no reap entry, so
 * the zombie's freer kept no authority past the inactivation: every later
 * inactivation of it, on any node, is refused by B4 (no local unlink, no EX),
 * and after a clean unmount it is still on its bucket.  ifree_defer_reap 1
 * (default) records the entry the P-UNLPREV-DEFER deferrals record, so the
 * reaper's retry restores the authority and frees it; 0 is the same-build
 * control.  ifree_defer_reaps counts the entries recorded.
 */
int mxfs_ifree_defer_reap = 1;
module_param_named(ifree_defer_reap, mxfs_ifree_defer_reap, int, 0644);
MODULE_PARM_DESC(ifree_defer_reap,
		 "a free deferred at the unlinked-list preflight records a reap entry carrying the freer's authority (1=default; 0=the same-build control)");
atomic_t mxfs_ifree_defer_reaps = ATOMIC_INIT(0);
module_param_cb(ifree_defer_reaps, &mxfs_dbg_atomic_param_ops,
		&mxfs_ifree_defer_reaps, 0644);
MODULE_PARM_DESC(ifree_defer_reaps,
		 "count of reap entries recorded for frees deferred at the unlinked-list preflight (write resets)");
/*
 * The same defect, H-3: the reaper retired an entry whenever its lookup
 * failed, as freed elsewhere.  A lookup of an unlinked inode whose in-core
 * copy is queued for inactivation fails -ENOENT (xfs_iget_cache_hit: unlinked
 * inodes cannot be re-grabbed) though nothing has freed it.  The reaper's own
 * unlinked-list walk for an earlier entry of the same pass reloads the
 * bucket's members and releases them, which queues exactly that state; the
 * queued inactivation runs without the authority only the reaper restores, so
 * it is skipped, and the zombie stays on its bucket with no entry left to free
 * it (lap fwcm3: six).  reap_transient_keep 1 (default) keeps an entry whose
 * failed lookup met that life still in core (mode set, nlink 0, the entry's
 * generation, queued, inactivating or done with it) for the next pass; 0 is
 * the same-build control, which retires it.  reap_iget_transient counts those
 * failures in both arms, reap_iget_retired the entries retired on a failed
 * lookup.
 */
int mxfs_reap_transient_keep = 1;
module_param_named(reap_transient_keep, mxfs_reap_transient_keep, int, 0644);
MODULE_PARM_DESC(reap_transient_keep,
		 "a reap entry whose lookup failed while its zombie's in-core inode was still in its inactivation is kept for the next pass (1=default; 0=retired, the same-build control)");
atomic_t mxfs_reap_iget_transient = ATOMIC_INIT(0);
module_param_cb(reap_iget_transient, &mxfs_dbg_atomic_param_ops,
		&mxfs_reap_iget_transient, 0644);
MODULE_PARM_DESC(reap_iget_transient,
		 "count of reap lookups that failed while the entry's zombie was still in core in its inactivation (P88-REAP-IGET-FAIL transient=1) (write resets)");
atomic_t mxfs_reap_iget_retired = ATOMIC_INIT(0);
module_param_cb(reap_iget_retired, &mxfs_dbg_atomic_param_ops,
		&mxfs_reap_iget_retired, 0644);
MODULE_PARM_DESC(reap_iget_retired,
		 "count of reap entries retired because their lookup failed (write resets)");
/*
 * D-FORMATION-RAMP-LOCK-REQUEST-EXHAUSTS-RETRIES-EAGAIN, H-F2: the engine
 * returns -EAGAIN when an acquire spent its whole retry budget on RETRY answers
 * (remaster, pend-retry, prepare, ledger-busy: a cluster reorganising itself,
 * as when nodes join one after another), and the inode lock's timeout
 * classifier had no arm for it: it reached the "lock unrecoverable" shutdown.
 * ilock_retry_exhaust_park 1 (default) parks such an acquire with backoff and
 * asks again, as behind a live holder or a pending recovery; a killed task at
 * a fallible boundary leaves.  0 is the same-build control, the shutdown.
 * ilock_retry_exhaust_parks counts the parks.  dbg_ilock_force_eagain_ino
 * (test only, 0 = off) makes the next slow-path acquire of that inode report
 * -EAGAIN for all its attempts without asking the engine, once, so the arm
 * can be reached on demand.
 */
int mxfs_ilock_retry_exhaust_park = 1;
module_param_named(ilock_retry_exhaust_park, mxfs_ilock_retry_exhaust_park, int, 0644);
MODULE_PARM_DESC(ilock_retry_exhaust_park,
		 "an inode acquire whose retry budget ran out on RETRY answers (-EAGAIN) parks and asks again (1=default; 0=the lock-unrecoverable shutdown, the same-build control)");
atomic_t mxfs_ilock_retry_exhaust_parks = ATOMIC_INIT(0);
module_param_cb(ilock_retry_exhaust_parks, &mxfs_dbg_atomic_param_ops,
		&mxfs_ilock_retry_exhaust_parks, 0644);
MODULE_PARM_DESC(ilock_retry_exhaust_parks,
		 "count of inode acquires parked after their retry budget ran out on RETRY answers (P-LKRETRY-PARK) (write resets)");
unsigned long long mxfs_dbg_ilock_force_eagain_ino;
module_param_named(dbg_ilock_force_eagain_ino, mxfs_dbg_ilock_force_eagain_ino, ullong, 0644);
MODULE_PARM_DESC(dbg_ilock_force_eagain_ino,
		 "TEST ONLY: the next slow-path acquire of this inode reports -EAGAIN for all its attempts without asking the engine, once (0=off)");
/*
 * D-FREED-INODE-HOME-NEVER-PUBLISHED-LIVE-CORE-AFTER-CLEAN-UNMOUNT, H-F12: an
 * AG release publishes its scope's unpublished inodes in its prepass, while
 * local admission to the AG is still open, and its drain took any in-scope
 * entry on every pass, so the creates its own node kept making in that AG fed
 * it new children faster than its workers claimed them; it ran out its window
 * (fw3f2: 5000 ms, the peer waiting for the AG all that time) and the release
 * went with a claim in flight.  pub_drain_bound 1 bounds an AG release's drain
 * to the entries listed when it began; a later child is published by its
 * directory's release, or by the next release of the AG, exactly as one
 * created after a drain had emptied its scope always was.  Its A/B never
 * reached (brc1, brf1, brc2), and H-F13's fence below stops the chase at its
 * source, so it is off: 0 (default) is the open scan every H-F13 lap ran.
 * pub_drain_bound_left counts the newer in-scope entries a bounded drain left
 * listed at its end.
 */
int mxfs_pub_drain_bound;
module_param_named(pub_drain_bound, mxfs_pub_drain_bound, int, 0644);
MODULE_PARM_DESC(pub_drain_bound,
		 "an AG release's publish drain takes only the unpublished inodes listed when it began (1; 0=default, every in-scope entry on every pass)");
atomic_t mxfs_pub_drain_bound_left = ATOMIC_INIT(0);
module_param_cb(pub_drain_bound_left, &mxfs_dbg_atomic_param_ops,
		&mxfs_pub_drain_bound_left, 0644);
MODULE_PARM_DESC(pub_drain_bound_left,
		 "count of in-scope unpublished inodes listed after a bounded AG release drain began and left listed at its end (P-PUB-DRAIN-BOUND) (write resets)");
/*
 * What an AG handoff exposes, in both arms of pub_drain_bound: a peer granted
 * the AG can reach an inode of it through the AGI and inode btree without its
 * directory, and an inode still unpublished there grants it CLEAN while this
 * node holds it EX.  pub_unlock_exposed counts AG unlocks with an unpublished
 * inode of the AG still listed or one of its claims in flight;
 * pub_unlock_listed sums the listed ones (P-PUB-UNPUB-AT-UNLOCK).
 */
atomic_t mxfs_pub_unlock_exposed = ATOMIC_INIT(0);
module_param_cb(pub_unlock_exposed, &mxfs_dbg_atomic_param_ops,
		&mxfs_pub_unlock_exposed, 0644);
MODULE_PARM_DESC(pub_unlock_exposed,
		 "count of AG unlocks with an unpublished inode of that AG still listed or its claim in flight (P-PUB-UNPUB-AT-UNLOCK) (write resets)");
atomic_t mxfs_pub_unlock_listed = ATOMIC_INIT(0);
module_param_cb(pub_unlock_listed, &mxfs_dbg_atomic_param_ops,
		&mxfs_pub_unlock_listed, 0644);
MODULE_PARM_DESC(pub_unlock_listed,
		 "sum over AG unlocks of the unpublished inodes of that AG still listed (P-PUB-UNPUB-AT-UNLOCK) (write resets)");
/*
 * D-FREED-INODE-HOME-NEVER-PUBLISHED-LIVE-CORE-AFTER-CLEAN-UNMOUNT, H-F13.
 * Nothing stopped the holder's own creates from allocating inodes in an AG
 * while a peer's BAST was pending on it: they re-adopted it during the
 * release's prepass, which publishes with admission open, and the COMMIT taken
 * afterwards at the last-holder unlock went to the post-COMMIT drains without
 * publishing them (pha2: 32 listed at the unlock, 6 already unlinked), or fed
 * the prepass drain children faster than it claimed them (fw3f2, fds3: the
 * drain ran out its window and the release went with a claim in flight).
 * ag_ialloc_fence 1 (default): while a peer's BAST is pending on an AG this
 * node holds, no inode is allocated in it here (xfs_dialloc_try_ag answers as
 * for a peer-held AG), and the release COMMIT waits, publishing again, while
 * an unpublished inode of the AG is listed or one's claim is in flight -- for
 * at most MXFS_PUB_DRAIN_TIMEOUT_MS from the BAST, then it commits as before
 * (P-AG-FENCE-ESCAPE).  0 is the same-build control.  ag_ialloc_fenced counts
 * refused allocations, ag_fence_held refused COMMITs, ag_fence_escaped COMMITs
 * the window let through with an inode of the AG still exposed.
 */
int mxfs_ag_ialloc_fence = 1;
module_param_named(ag_ialloc_fence, mxfs_ag_ialloc_fence, int, 0644);
MODULE_PARM_DESC(ag_ialloc_fence,
		 "no inode allocation in an AG while a peer's BAST is pending on it, and no release COMMIT while an unpublished inode of it is listed or claiming (1=default; 0=the same-build control)");
atomic_t mxfs_ag_ialloc_fenced = ATOMIC_INIT(0);
module_param_cb(ag_ialloc_fenced, &mxfs_dbg_atomic_param_ops,
		&mxfs_ag_ialloc_fenced, 0644);
MODULE_PARM_DESC(ag_ialloc_fenced,
		 "count of inode allocations refused an AG because a peer's BAST was pending on it (write resets)");
atomic_t mxfs_ag_fence_held = ATOMIC_INIT(0);
module_param_cb(ag_fence_held, &mxfs_dbg_atomic_param_ops,
		&mxfs_ag_fence_held, 0644);
MODULE_PARM_DESC(ag_fence_held,
		 "count of AG release COMMITs refused because an unpublished inode of the AG was listed or claiming (write resets)");
atomic_t mxfs_ag_fence_escaped = ATOMIC_INIT(0);
module_param_cb(ag_fence_escaped, &mxfs_dbg_atomic_param_ops,
		&mxfs_ag_fence_escaped, 0644);
MODULE_PARM_DESC(ag_fence_escaped,
		 "count of AG release COMMITs taken past the fence's window with an unpublished inode of the AG still listed or claiming (P-AG-FENCE-ESCAPE) (write resets)");
/*
 * The fence keys on a BAST pending on a tenure this node holds.  The pending
 * flag is also left set on an AG this node holds nothing of (a disk-locking
 * BAST reaches the whole group, the waiter's re-BASTs land after the release),
 * and only a fresh grant clears it, so a fence that refuses on it refuses the
 * AG for good (mxfs_ag_ialloc_fenced_now).  ag_fence_hint_exempt 1 (default)
 * lets the allocation through to its acquire; 0 is the same-build control
 * that refuses as before.  ag_fence_hint_passed and ag_fence_hint_refused
 * count each.
 */
int mxfs_ag_fence_hint_exempt = 1;
module_param_named(ag_fence_hint_exempt, mxfs_ag_fence_hint_exempt, int, 0644);
MODULE_PARM_DESC(ag_fence_hint_exempt,
		 "a BAST pending on an AG this node holds no tenure of does not fence inode allocation in it (1=default; 0=the same-build control)");
atomic_t mxfs_ag_fence_hint_passed = ATOMIC_INIT(0);
module_param_cb(ag_fence_hint_passed, &mxfs_dbg_atomic_param_ops,
		&mxfs_ag_fence_hint_passed, 0644);
MODULE_PARM_DESC(ag_fence_hint_passed,
		 "count of inode allocations let through an AG with a BAST pending but no tenure here (write resets)");
atomic_t mxfs_ag_fence_hint_refused = ATOMIC_INIT(0);
module_param_cb(ag_fence_hint_refused, &mxfs_dbg_atomic_param_ops,
		&mxfs_ag_fence_hint_refused, 0644);
MODULE_PARM_DESC(ag_fence_hint_refused,
		 "count of inode allocations refused an AG with a BAST pending but no tenure here, ag_fence_hint_exempt=0 (write resets)");
/*
 * D-UMOUNT-ROOT-DENTRY-STILL-IN-USE-DEFERRED-DIR-DCACHE-SHRINK-RACE: every
 * completed directory reload queues a deferred dcache shrink
 * (mxfs_dir_dshrink_queue) that igrabs the directory and holds a reference
 * on its dentry while it runs.  The only gate on it closed in put_super,
 * which generic_shutdown_super calls after shrink_dcache_for_umount, so a
 * shrink queued by the reload umount's own stat of the mount point caused
 * was still running when the dentry tree was walked: 'BUG: Dentry ... still
 * in use (2) [unmount of mxfs sda]' (jwc3, test15).  dshrink_umount_gate 1
 * (default): xfs_kill_sb closes a gate on new shrinks, waits for the queue
 * calls already past it, and flushes the inode BAST workqueue before
 * kill_block_super; 0 is the same-build control.  dshrink_at_umount counts
 * the shrinks queued or running when xfs_kill_sb began, dshrink_gate_refused
 * the queue calls the closed gate turned away.  dbg_dshrink_hold_ms (TEST
 * ONLY, 0 = off) keeps each shrink's dentry reference that long before it
 * runs, so an unmount right after a directory reload meets it.
 */
int mxfs_dshrink_umount_gate = 1;
module_param_named(dshrink_umount_gate, mxfs_dshrink_umount_gate, int, 0644);
MODULE_PARM_DESC(dshrink_umount_gate,
		 "unmount waits out the deferred directory dcache shrinks before the dentry tree is torn down (1=default; 0=the same-build control)");
atomic_t mxfs_dshrink_at_umount = ATOMIC_INIT(0);
module_param_cb(dshrink_at_umount, &mxfs_dbg_atomic_param_ops,
		&mxfs_dshrink_at_umount, 0644);
MODULE_PARM_DESC(dshrink_at_umount,
		 "count of deferred directory dcache shrinks queued or running when an unmount reached xfs_kill_sb (write resets)");
atomic_t mxfs_dshrink_gate_refused = ATOMIC_INIT(0);
module_param_cb(dshrink_gate_refused, &mxfs_dbg_atomic_param_ops,
		&mxfs_dshrink_gate_refused, 0644);
MODULE_PARM_DESC(dshrink_gate_refused,
		 "count of deferred directory dcache shrinks refused because the unmount had closed their gate (write resets)");
int mxfs_dbg_dshrink_hold_ms;
module_param_named(dbg_dshrink_hold_ms, mxfs_dbg_dshrink_hold_ms, int, 0644);
MODULE_PARM_DESC(dbg_dshrink_hold_ms,
		 "TEST ONLY: a deferred directory dcache shrink holds its dentry reference this many ms before it runs (0=off)");
/*
 * D-NETMESH-LIVE-FILE-INODE-FREED-UNDER-ITS-NAME-AFTER-NUMBER-REUSE, H-WW1
 * instrument: inode-cluster writes that mxfs_submit_partial_inode_write sent
 * whole under multi-node membership, by the bail that sent them.  early: a
 * buffer it does not split (readahead ops, maps, a fresh chunk, no perag,
 * geometry); noskip: every slot was going out anyway; empty: every sector was
 * skipped and no passenger skip let the refusal fire; declined: every sector
 * was skipped and the passenger refusal declined.  kwf2's and jzf1's removed
 * names went back on the platter in the creator's whole writes of a cluster
 * whose directory slot was its own stale image.  Detection only.
 */
atomic_t mxfs_iwr_whole_early = ATOMIC_INIT(0);
module_param_cb(iwr_whole_early, &mxfs_dbg_atomic_param_ops,
		&mxfs_iwr_whole_early, 0644);
MODULE_PARM_DESC(iwr_whole_early,
		 "count of inode-cluster writes sent whole because the partial writer does not split that buffer (write resets)");
atomic_t mxfs_iwr_whole_noskip = ATOMIC_INIT(0);
module_param_cb(iwr_whole_noskip, &mxfs_dbg_atomic_param_ops,
		&mxfs_iwr_whole_noskip, 0644);
MODULE_PARM_DESC(iwr_whole_noskip,
		 "count of inode-cluster writes sent whole because no slot was skipped (write resets)");
atomic_t mxfs_iwr_whole_empty = ATOMIC_INIT(0);
module_param_cb(iwr_whole_empty, &mxfs_dbg_atomic_param_ops,
		&mxfs_iwr_whole_empty, 0644);
MODULE_PARM_DESC(iwr_whole_empty,
		 "count of inode-cluster writes sent whole although every sector was skipped, with no passenger skip (write resets)");
atomic_t mxfs_iwr_whole_declined = ATOMIC_INIT(0);
module_param_cb(iwr_whole_declined, &mxfs_dbg_atomic_param_ops,
		&mxfs_iwr_whole_declined, 0644);
MODULE_PARM_DESC(iwr_whole_declined,
		 "count of inode-cluster writes sent whole although every sector was skipped, the passenger refusal declining (write resets)");
/*
 * H-WW1 fix: an inode-cluster write whose every sector the per-slot rules
 * skipped, with no passenger skip, completes with no I/O instead of going
 * out whole (the whole write publishes only slots those rules refused).
 * 1 (default) refuses; 0 is the same-build control.  iwr_empty_refused
 * counts the refusals.
 */
int mxfs_iwr_refuse_empty = 1;
module_param_named(iwr_refuse_empty, mxfs_iwr_refuse_empty, int, 0644);
MODULE_PARM_DESC(iwr_refuse_empty,
		 "an inode-cluster write whose every sector was skipped completes with no I/O instead of going out whole (1=default; 0=the whole write, the same-build control)");
atomic_t mxfs_iwr_empty_refused = ATOMIC_INIT(0);
module_param_cb(iwr_empty_refused, &mxfs_dbg_atomic_param_ops,
		&mxfs_iwr_empty_refused, 0644);
MODULE_PARM_DESC(iwr_empty_refused,
		 "count of inode-cluster writes refused because every sector was skipped (write resets)");
/*
 * The merged inode-cluster write (pal/linux/xfs_buf.c, docs/4kn-support.md),
 * on a volume whose sector holds several inodes: the blocks it swapped, the
 * MISCOMPAREs it retried (a peer landed one of its own slots in the block
 * between this node's read and its swap), the cluster writes it failed (a
 * swap error, a block still miscomparing at its bound, or a write it could
 * not merge), and the cluster writes that owed nothing and completed with no
 * I/O.  A harness writes 0 to each and reads it at the end.
 */
atomic_t mxfs_iwr_merge_blocks = ATOMIC_INIT(0);
module_param_cb(iwr_merge_blocks, &mxfs_dbg_atomic_param_ops,
		&mxfs_iwr_merge_blocks, 0644);
MODULE_PARM_DESC(iwr_merge_blocks,
		 "count of inode-cluster blocks the merged write swapped (write resets)");
atomic_t mxfs_iwr_merge_miscompares = ATOMIC_INIT(0);
module_param_cb(iwr_merge_miscompares, &mxfs_dbg_atomic_param_ops,
		&mxfs_iwr_merge_miscompares, 0644);
MODULE_PARM_DESC(iwr_merge_miscompares,
		 "count of merged-write swaps that miscompared and were read and merged again (write resets)");
atomic_t mxfs_iwr_merge_failed = ATOMIC_INIT(0);
module_param_cb(iwr_merge_failed, &mxfs_dbg_atomic_param_ops,
		&mxfs_iwr_merge_failed, 0644);
MODULE_PARM_DESC(iwr_merge_failed,
		 "count of inode-cluster writes the merged write failed, leaving the buffer dirty (write resets)");
atomic_t mxfs_iwr_merge_empty = ATOMIC_INIT(0);
module_param_cb(iwr_merge_empty, &mxfs_dbg_atomic_param_ops,
		&mxfs_iwr_merge_empty, 0644);
MODULE_PARM_DESC(iwr_merge_empty,
		 "count of merged-mode inode-cluster writes that owed no slot and completed with no I/O (write resets)");
/*
 * DEBUG: the next dbg_iwr_merge_hold_n blocks the merged write swaps each wait
 * dbg_iwr_merge_hold_ms between the block's read and its first swap, so a test
 * can land a peer's write of the same block in between and see the swap
 * miscompare and the block read and merged again (tests/fourkn_merge_2node.sh).
 * Each held block takes one from the count, which reads back what is left; a
 * retry is never held.  Never in production.
 */
atomic_t mxfs_dbg_iwr_merge_hold_n = ATOMIC_INIT(0);
module_param_cb(dbg_iwr_merge_hold_n, &mxfs_dbg_atomic_param_ops,
		&mxfs_dbg_iwr_merge_hold_n, 0644);
MODULE_PARM_DESC(dbg_iwr_merge_hold_n,
		 "DEBUG: the next N blocks of merged inode-cluster writes wait dbg_iwr_merge_hold_ms between their read and their swap (reads back the count left). Never enable in production.");
int mxfs_dbg_iwr_merge_hold_ms = 20;
module_param_named(dbg_iwr_merge_hold_ms, mxfs_dbg_iwr_merge_hold_ms, int, 0644);
MODULE_PARM_DESC(dbg_iwr_merge_hold_ms,
		 "DEBUG: how long a block held by dbg_iwr_merge_hold_n waits, in ms. Never enable in production.");
/*
 * DEBUG (D-FOURKN-MERGE-LAP-HELD-WINDOW-MISSES-THE-RETRY-IN-SOME-LAPS): a fixed
 * hold catches a peer's write only when the peer happens to write the block
 * inside it.  With dbg_iwr_merge_hold_peer_ms set, a held block instead waits
 * until the block on the device no longer matches the image it read, which is
 * a peer's swap of that block landing, so its own swap miscompares; or until
 * this many ms, when no peer wrote it.  iwr_merge_hold_landed counts the holds
 * a peer's swap ended.  0, the default, keeps the fixed hold.  Never in
 * production.
 */
int mxfs_dbg_iwr_merge_hold_peer_ms;
module_param_named(dbg_iwr_merge_hold_peer_ms, mxfs_dbg_iwr_merge_hold_peer_ms, int, 0644);
MODULE_PARM_DESC(dbg_iwr_merge_hold_peer_ms,
		 "DEBUG: a block held by dbg_iwr_merge_hold_n waits until a peer's swap of it lands, or at most this many ms (0=the fixed dbg_iwr_merge_hold_ms hold, the default). Never enable in production.");
atomic_t mxfs_iwr_merge_hold_landed = ATOMIC_INIT(0);
module_param_cb(iwr_merge_hold_landed, &mxfs_dbg_atomic_param_ops,
		&mxfs_iwr_merge_hold_landed, 0644);
MODULE_PARM_DESC(iwr_merge_hold_landed,
		 "count of dbg_iwr_merge_hold_peer_ms holds that a peer's swap of the held block ended (write resets)");
/*
 * D-PEER-OPEN-UNLINKED-CHAIN-REMOVE-FAILS-IFREE-SHUTDOWN-BOTH-NODES, H-U6:
 * xfs_inactive_ifree released its predecessor pin (H-U1) and hold (H-U4) with
 * a synchronous xfs_irele after the free committed.  When it is the
 * predecessor's last reference and the predecessor is unlinked, its whole
 * inactivation runs nested inside this one, while this inode's number is
 * already free in the inobt and its in-core inode still inactivating: a local
 * create that picks the number holds the AGI and waits in xfs_iget for this
 * inactivation to finish, and the nested one waits for that AGI (hu4df1,
 * test29).  unlprev_rele_defer 1 (default) hands those references to the
 * inode BAST workqueue, so the predecessor's inactivation runs after this one
 * has finished; 0 is the same-build control, which releases them inline.
 * unlprev_rele_deferred counts the references handed off.
 */
int mxfs_unlprev_rele_defer = 1;
module_param_named(unlprev_rele_defer, mxfs_unlprev_rele_defer, int, 0644);
MODULE_PARM_DESC(unlprev_rele_defer,
		 "a free's predecessor pin and hold are released from the inode BAST workqueue, never inside the inactivation (1=default; 0=inline, the same-build control)");
atomic_t mxfs_unlprev_rele_deferred = ATOMIC_INIT(0);
module_param_cb(unlprev_rele_deferred, &mxfs_dbg_atomic_param_ops,
		&mxfs_unlprev_rele_deferred, 0644);
MODULE_PARM_DESC(unlprev_rele_deferred,
		 "count of predecessor references a free released through the inode BAST workqueue (write resets)");
/*
 * H-U6's census and window, for the same-build A/B of unlprev_rele_defer.  A
 * predecessor reference released after the free committed can run a nested
 * inactivation only when it is the predecessor's last reference and the
 * predecessor is unlinked.  A candidate is a committed free whose references
 * are an unlinked predecessor's only ones when it starts releasing them
 * (P-UNLPREV-RELE-LAST, once per predecessor, the same test in both arms: a
 * free holds the pin and the hold on one predecessor, and in the fix arm the
 * first is still queued when the second goes).  unlprev_rele_inline_last
 * counts the inline releases that dropped the last reference (each one an
 * inactivation run inside the outer one), unlprev_rele_deferred_last the
 * workqueue releases that did (each one run after the outer one).
 * dbg_unlprev_rele_hold_ms holds each candidate that long before its releases
 * in both arms, so a local create can take the freed number while the freed
 * inode is still inactivating: hu4df1's window, opened on purpose.
 */
int mxfs_dbg_unlprev_rele_hold_ms;
module_param_named(dbg_unlprev_rele_hold_ms, mxfs_dbg_unlprev_rele_hold_ms, int, 0644);
MODULE_PARM_DESC(dbg_unlprev_rele_hold_ms,
		 "TEST ONLY: ms a committed free holds its last reference on an unlinked predecessor before releasing it (0=off)");
atomic_t mxfs_unlprev_rele_inline_last = ATOMIC_INIT(0);
module_param_cb(unlprev_rele_inline_last, &mxfs_dbg_atomic_param_ops,
		&mxfs_unlprev_rele_inline_last, 0644);
MODULE_PARM_DESC(unlprev_rele_inline_last,
		 "count of committed frees that released their last reference on an unlinked predecessor inline (write resets)");
atomic_t mxfs_unlprev_rele_deferred_last = ATOMIC_INIT(0);
module_param_cb(unlprev_rele_deferred_last, &mxfs_dbg_atomic_param_ops,
		&mxfs_unlprev_rele_deferred_last, 0644);
MODULE_PARM_DESC(unlprev_rele_deferred_last,
		 "count of workqueue releases of a committed free's reference that were an unlinked predecessor's last (write resets)");
/*
 * The same defect, H-U7: a reload that keeps the in-core inode (judged
 * identical to the platter, or kept ahead of it) skips xfs_inode_from_disk, the
 * only reload path that imports di_next_unlinked.  A peer's removal of this
 * inode's successor rewrites that field under the peer's EX and lands it, but
 * moves none of the fields the identical test compares (the iunlink item logs
 * a range of the cluster buffer, not the core), so the kept in-core next still
 * names the removed successor and this node's own free of the inode stitches
 * the bucket to it (pfcw1: P-UNLREM-BACKREF next=0x81 rc=-22, shutdown).
 * reload_next_refresh 1 (default) imports the reload's di_next_unlinked into a
 * kept unlinked inode of the same life; 0 keeps the in-core value, the
 * same-build control.  reload_next_stale counts kept reloads whose dinode
 * named another next than the in-core inode, in both arms;
 * reload_next_refreshed those that imported it.
 */
int mxfs_reload_next_refresh = 1;
module_param_named(reload_next_refresh, mxfs_reload_next_refresh, int, 0644);
MODULE_PARM_DESC(reload_next_refresh,
		 "a reload that keeps an unlinked inode's in-core state imports the dinode's di_next_unlinked when it differs (1=default; 0=keeps the in-core value, the same-build control)");
atomic_t mxfs_reload_next_stale = ATOMIC_INIT(0);
module_param_cb(reload_next_stale, &mxfs_dbg_atomic_param_ops,
		&mxfs_reload_next_stale, 0644);
MODULE_PARM_DESC(reload_next_stale,
		 "count of reloads that kept an unlinked inode whose dinode named a different di_next_unlinked than its in-core inode (P-RELOAD-NEXT-STALE) (write resets)");
atomic_t mxfs_reload_next_refreshed = ATOMIC_INIT(0);
module_param_cb(reload_next_refreshed, &mxfs_dbg_atomic_param_ops,
		&mxfs_reload_next_refreshed, 0644);
MODULE_PARM_DESC(reload_next_refreshed,
		 "count of those reloads that imported the dinode's di_next_unlinked (P-RELOAD-NEXT-STALE refreshed=1) (write resets)");
/*
 * H-F8b, the same rule at the reload's P116 self-clobber guard
 * (xfs/xfs_mxfs_reload.c mxfs_reload_self_clobber_guard): its grant term kept a
 * clean shell over a FREE disk image on the held grant alone.
 * selfclobber_keep_guard 1 (default) adopts the freed image for a clean held
 * shell; 0 keeps it, the same-build control.  keep_clean counts the hazard,
 * clean_refused the guard's reach.
 */
int mxfs_selfclobber_keep_guard = 1;
module_param_named(selfclobber_keep_guard, mxfs_selfclobber_keep_guard, int, 0644);
MODULE_PARM_DESC(selfclobber_keep_guard,
		 "the reload's self-clobber guard keeps an in-core inode over a FREE disk image only when it has committed changes not yet on the platter (1=default; 0=a held grant also keeps it, the same-build control)");
atomic_t mxfs_selfclobber_keep_clean = ATOMIC_INIT(0);
module_param_cb(selfclobber_keep_clean, &mxfs_dbg_atomic_param_ops,
		&mxfs_selfclobber_keep_clean, 0644);
MODULE_PARM_DESC(selfclobber_keep_clean,
		 "count of reloads whose self-clobber guard kept a CLEAN shell over a FREE disk image on the held grant alone (P116 clean_held=1) (write resets)");
atomic_t mxfs_selfclobber_clean_refused = ATOMIC_INIT(0);
module_param_cb(selfclobber_clean_refused, &mxfs_dbg_atomic_param_ops,
		&mxfs_selfclobber_clean_refused, 0644);
MODULE_PARM_DESC(selfclobber_clean_refused,
		 "count of reloads where selfclobber_keep_guard refused that keep (P116-CLEAN-REFUSED) (write resets)");
/* the two arms of noino_recycle_guard (xfs/xfs_mxfs_noino.c) */
atomic_t mxfs_recycle_reset_noino = ATOMIC_INIT(0);
module_param_cb(recycle_reset_noino, &mxfs_dbg_atomic_param_ops,
		&mxfs_recycle_reset_noino, 0644);
MODULE_PARM_DESC(recycle_reset_noino,
		 "count of recycles that reset a cached grant because a no-inode release of the same inode may be in flight (P-RECYCLE-RESET-UNDER-NOINO) (write resets)");
/* noino_recycle_dirty_wait (xfs/xfs_mxfs_noino.c) */
atomic_t mxfs_recycle_dirty_waits = ATOMIC_INIT(0);
module_param_cb(recycle_dirty_waits, &mxfs_dbg_atomic_param_ops,
		&mxfs_recycle_dirty_waits, 0644);
MODULE_PARM_DESC(recycle_dirty_waits,
		 "count of corpses whose recycle waited for an in-flight no-inode release because they still owed the platter a committed change (P-RECYCLE-DIRTY-WAIT) (write resets)");
atomic_t mxfs_recycle_dirty_wait_rounds = ATOMIC_INIT(0);
module_param_cb(recycle_dirty_wait_rounds, &mxfs_dbg_atomic_param_ops,
		&mxfs_recycle_dirty_wait_rounds, 0644);
MODULE_PARM_DESC(recycle_dirty_wait_rounds,
		 "count of xfs_iget passes those waits refused, one per retry (write resets)");
atomic_t mxfs_recycle_dirty_kept = ATOMIC_INIT(0);
module_param_cb(recycle_dirty_kept, &mxfs_dbg_atomic_param_ops,
		&mxfs_recycle_dirty_kept, 0644);
MODULE_PARM_DESC(recycle_dirty_kept,
		 "count of recycles that kept a dirty corpse's grant instead of resetting it, the release having registered after the recycle began (P-RECYCLE-DIRTY-KEEP) (write resets)");
atomic_t mxfs_recycle_dirty_hazard = ATOMIC_INIT(0);
module_param_cb(recycle_dirty_hazard, &mxfs_dbg_atomic_param_ops,
		&mxfs_recycle_dirty_hazard, 0644);
MODULE_PARM_DESC(recycle_dirty_hazard,
		 "count of recycles that met a corpse owing the platter a committed change under a tracked in-flight no-inode release and, with noino_recycle_dirty_wait=0, went on to reset it; one per iget pass (write resets)");
atomic_t mxfs_recycle_reset_dirty = ATOMIC_INIT(0);
module_param_cb(recycle_reset_dirty, &mxfs_dbg_atomic_param_ops,
		&mxfs_recycle_reset_dirty, 0644);
MODULE_PARM_DESC(recycle_reset_dirty,
		 "count of P-RECYCLE-RESET-UNDER-NOINO resets of a corpse that still owed the platter a committed change (owes=1) (write resets)");
atomic_t mxfs_recycle_waited_reset = ATOMIC_INIT(0);
module_param_cb(recycle_waited_reset, &mxfs_dbg_atomic_param_ops,
		&mxfs_recycle_waited_reset, 0644);
MODULE_PARM_DESC(recycle_waited_reset,
		 "count of recycles after such a wait whose unsampled measurement found the grant gone and reset it (P-RECYCLE-WAITED) (write resets)");
/* noino_recycle_takeover (xfs/xfs_mxfs_noino.c) */
atomic_t mxfs_recycle_dirty_takeover = ATOMIC_INIT(0);
module_param_cb(recycle_dirty_takeover, &mxfs_dbg_atomic_param_ops,
		&mxfs_recycle_dirty_takeover, 0644);
MODULE_PARM_DESC(recycle_dirty_takeover,
		 "count of recycles that could not wait and took an in-flight no-inode release over, keeping a dirty corpse's grant (P-RECYCLE-DIRTY-TAKEOVER) (write resets)");
atomic_t mxfs_noino_takeovers = ATOMIC_INIT(0);
module_param_cb(noino_takeovers, &mxfs_dbg_atomic_param_ops,
		&mxfs_noino_takeovers, 0644);
MODULE_PARM_DESC(noino_takeovers,
		 "count of no-inode releases that found themselves taken over and did not unlock (P-NOINO-TAKEN-OVER) (write resets)");
/* noino_acq_takeover (xfs/xfs_mxfs_noino.c) */
atomic_t mxfs_noino_acq_meets = ATOMIC_INIT(0);
module_param_cb(noino_acq_meets, &mxfs_dbg_atomic_param_ops,
		&mxfs_noino_acq_meets, 0644);
MODULE_PARM_DESC(noino_acq_meets,
		 "count of acquires whose transaction held items that met an in-flight no-inode release of their number, whatever noino_acq_takeover says (write resets)");
atomic_t mxfs_noino_acq_takeovers = ATOMIC_INIT(0);
module_param_cb(noino_acq_takeovers, &mxfs_dbg_atomic_param_ops,
		&mxfs_noino_acq_takeovers, 0644);
MODULE_PARM_DESC(noino_acq_takeovers,
		 "count of acquires whose transaction held items that took an in-flight no-inode release of their number over instead of waiting behind it (P-NOINO-ACQ-TAKEOVER) (write resets)");
atomic_t mxfs_noino_fence_taken = ATOMIC_INIT(0);
module_param_cb(noino_fence_taken, &mxfs_dbg_atomic_param_ops,
		&mxfs_noino_fence_taken, 0644);
MODULE_PARM_DESC(noino_fence_taken,
		 "count of no-inode release drain fences that stopped because the release was taken over (P-NOINO-FENCE-TAKEN) (write resets)");
atomic_t mxfs_dbg_recycle_nowait_hits = ATOMIC_INIT(0);
module_param_cb(dbg_recycle_nowait_hits, &mxfs_dbg_atomic_param_ops,
		&mxfs_dbg_recycle_nowait_hits, 0644);
MODULE_PARM_DESC(dbg_recycle_nowait_hits,
		 "TEST ONLY: count of recycles dbg_recycle_nowait sent on without the wait they would have taken (write resets)");
atomic_t mxfs_noino_recycle_redrive = ATOMIC_INIT(0);
module_param_cb(noino_recycle_redrive, &mxfs_dbg_atomic_param_ops,
		&mxfs_noino_recycle_redrive, 0644);
MODULE_PARM_DESC(noino_recycle_redrive,
		 "count of no-inode BASTs re-driven because the corpse entered a recycle before the release was registered (P-NOINO-RECYCLE-REDRIVE) (write resets)");
/*
 * H-F7c, the create side of the same window (xfs/libxfs/xfs_ialloc.c
 * mxfs_dialloc_noino_inflight): the allocator's probe is answered by the DLM's
 * already-granted shortcut, which mints no generation, so a create that reuses
 * a number whose no-inode release is in flight builds its new life on the very
 * grant that release anchored at its BAST, and the release unlocks it after
 * its live check with the new life's changes undrained.  noino_resv_guard 1
 * (default) skips such a number as a peer-held one; 0 takes it, the same-build
 * control.  resv_under_noino counts the hazard (a candidate reserved or taken
 * while the release was in flight), resv_noino_skipped the guard's reach.
 */
int mxfs_noino_resv_guard = 1;
module_param_named(noino_resv_guard, mxfs_noino_resv_guard, int, 0644);
MODULE_PARM_DESC(noino_resv_guard,
		 "the inode allocator never takes a number whose no-inode release is in flight on this node (1=default; 0=takes it, the same-build control)");
atomic_t mxfs_dialloc_resv_under_noino = ATOMIC_INIT(0);
module_param_cb(dialloc_resv_under_noino, &mxfs_dbg_atomic_param_ops,
		&mxfs_dialloc_resv_under_noino, 0644);
MODULE_PARM_DESC(dialloc_resv_under_noino,
		 "count of inode-allocator candidates reserved or taken while a no-inode release of the same number was in flight (P-DIALLOC-RESV-UNDER-NOINO) (write resets)");
atomic_t mxfs_dialloc_resv_noino_skipped = ATOMIC_INIT(0);
module_param_cb(dialloc_resv_noino_skipped, &mxfs_dbg_atomic_param_ops,
		&mxfs_dialloc_resv_noino_skipped, 0644);
MODULE_PARM_DESC(dialloc_resv_noino_skipped,
		 "count of inode-allocator candidates noino_resv_guard skipped because a no-inode release of the number was in flight (P-DIALLOC-NOINO-SKIP) (write resets)");
/*
 * H-F9, the lookup side (xfs/xfs_mxfs_bast.c __mxfs_dlm_bast_notify): a
 * VFS-live in-core inode whose reload adopted a peer's free (mode 0,
 * P116-ZOMBIE-ADOPT) is refused by xfs_iget(XFS_IGET_INCORE) and classified
 * LIVE, so a peer's BAST for it was served by the no-inode release, which
 * unlocks the grant the shell still caches.  noino_shell_guard 1 (default)
 * serves such a BAST through the in-core path, which releases the grant and
 * the cached mode together; 0 sends it to the no-inode release, the same-build
 * control.  noino_live_shell counts the hazard (a BAST that met such a shell),
 * noino_shell_routed the guard's reach.
 */
int mxfs_noino_shell_guard = 1;
module_param_named(noino_shell_guard, mxfs_noino_shell_guard, int, 0644);
MODULE_PARM_DESC(noino_shell_guard,
		 "a peer BAST for a live in-core inode holding a freed image is served by the in-core release (1=default; 0=no-inode release, the same-build control)");
atomic_t mxfs_noino_live_shell = ATOMIC_INIT(0);
module_param_cb(noino_live_shell, &mxfs_dbg_atomic_param_ops,
		&mxfs_noino_live_shell, 0644);
MODULE_PARM_DESC(noino_live_shell,
		 "count of BASTs whose in-core lookup refused a live inode holding a freed image (P-NOINO-LIVE-SHELL) (write resets)");
atomic_t mxfs_noino_shell_routed = ATOMIC_INIT(0);
module_param_cb(noino_shell_routed, &mxfs_dbg_atomic_param_ops,
		&mxfs_noino_shell_routed, 0644);
MODULE_PARM_DESC(noino_shell_routed,
		 "count of those BASTs noino_shell_guard served through the in-core release (write resets)");
/*
 * H-F10, the publish side (xfs/xfs_mxfs_publish.c): a publish drain takes an
 * unpublished inode off the list before its claim, which is safe only while
 * the peer that sent the BAST is the one that could reach the inode.  An
 * inode whose parent was not yet recorded is in every drain's scope, so the
 * drain of an unrelated lock can take it, and its real parent's release then
 * goes to the peer with the inode neither unpublished nor granted.
 * pub_claim_release_guard 1 (default) holds a release until every claim in
 * its scope taken by another publish has returned (bounded by the drain's own
 * window); 0 lets it go, the same-build control.  pub_claim_inflight_rel
 * counts the hazard (a release that went with such a claim in flight),
 * pub_claim_rel_waited the guard's reach.
 */
int mxfs_pub_claim_release_guard = 1;
module_param_named(pub_claim_release_guard, mxfs_pub_claim_release_guard, int, 0644);
MODULE_PARM_DESC(pub_claim_release_guard,
		 "a directory or AG release waits for the publish claims in flight in its scope (1=default; 0=goes with them in flight, the same-build control)");
atomic_t mxfs_pub_claim_inflight_rel = ATOMIC_INIT(0);
module_param_cb(pub_claim_inflight_rel, &mxfs_dbg_atomic_param_ops,
		&mxfs_pub_claim_inflight_rel, 0644);
MODULE_PARM_DESC(pub_claim_inflight_rel,
		 "count of directory or AG releases that went while a publish claim in their scope was in flight (P-PUB-CLAIM-INFLIGHT-AT-RELEASE) (write resets)");
atomic_t mxfs_pub_claim_rel_waited = ATOMIC_INIT(0);
module_param_cb(pub_claim_rel_waited, &mxfs_dbg_atomic_param_ops,
		&mxfs_pub_claim_rel_waited, 0644);
MODULE_PARM_DESC(pub_claim_rel_waited,
		 "count of releases pub_claim_release_guard held until the claims in their scope returned (write resets)");
/* TEST ONLY: hold every BAST-drain claim this long between the take and the
 * request, so a release in its scope meets it in flight (the H-F10 A/B). */
unsigned int mxfs_dbg_pub_claim_delay_ms;
module_param_named(dbg_pub_claim_delay_ms, mxfs_dbg_pub_claim_delay_ms, uint, 0644);
MODULE_PARM_DESC(dbg_pub_claim_delay_ms,
		 "TEST ONLY: ms a publish drain waits between taking an inode off the unpublished list and claiming it (0=off)");
/* TEST ONLY: hold a regular-file create this long while its new inode is
 * listed unpublished with no parent recorded, the window in which the drain
 * of another directory can take it (the H-F10 A/B's reach; the claim delay
 * above only lengthens what follows a take). */
unsigned int mxfs_dbg_create_parent_delay_ms;
module_param_named(dbg_create_parent_delay_ms, mxfs_dbg_create_parent_delay_ms, uint, 0644);
MODULE_PARM_DESC(dbg_create_parent_delay_ms,
		 "TEST ONLY: ms a regular-file create waits, its new inode unpublished, before recording the inode's parent directory (0=off)");
/* TEST ONLY: hold every create this long between the allocator's take of the
 * number and the inode's instantiation (xfs/xfs_inode.c xfs_create), the
 * window in which a peer BAST registering a no-inode release of the number
 * leaves the create waiting behind that release
 * (D-4NODE-SHARED-DIR-EX-HANDOFF-6S-TAIL-DOZE's reach). */
unsigned int mxfs_dbg_create_alloc_delay_ms;
module_param_named(dbg_create_alloc_delay_ms, mxfs_dbg_create_alloc_delay_ms, uint, 0644);
MODULE_PARM_DESC(dbg_create_alloc_delay_ms,
		 "TEST ONLY: ms a create waits between the allocator's take of the inode number and the inode's instantiation (0=off)");
/*
 * H-F10, the write side (pal/linux/xfs_buf.c, the cluster write): between the
 * take and the claim's return the inode is neither unpublished nor granted, and
 * its own writeback can put a live core home while a peer may hold the number
 * (P-LOGWR-DLM-NOGRANT pub_inflight=1: 1-2 per lap on the H-F10 fix laps, whose
 * release guard does not reach it).  pub_claim_write_guard 1 (default) masks
 * such a slot from the home write; the item stays dirty in the AIL and the next
 * push writes it under the grant the claim brings.  0 writes it, the same-build
 * control.  pub_claim_write_masked counts the masks.
 */
int mxfs_pub_claim_write_guard = 1;
module_param_named(pub_claim_write_guard, mxfs_pub_claim_write_guard, int, 0644);
MODULE_PARM_DESC(pub_claim_write_guard,
		 "a cluster write never carries the live core of an inode whose publish claim is in flight (1=default; 0=writes it, the same-build control)");
atomic_t mxfs_pub_claim_write_masked = ATOMIC_INIT(0);
module_param_cb(pub_claim_write_masked, &mxfs_dbg_atomic_param_ops,
		&mxfs_pub_claim_write_masked, 0644);
MODULE_PARM_DESC(pub_claim_write_masked,
		 "count of live slots pub_claim_write_guard masked from a cluster write because the inode's publish claim was in flight (P-PUB-CLAIM-WRITE-MASKED) (write resets)");
/*
 * D-CREATE-ON-ZOMBIE-SHELL-INHERITS-DEAD-LIFE-NBLOCKS: a reload that adopts a
 * peer's free image (P116-ZOMBIE-ADOPT) takes only its generation and mode
 * (xfs_inode_from_disk stops at a free image), so the shell keeps the dead
 * life's block count, size and forks.  A create that recycles the shell is
 * deferred as a dead shell (P-CR63 enters on a mode or a block count), but the
 * recycle's sanitize arm ran only for a shell that still had a mode, and
 * xfs_inode_init only asserts that the block count is 0: the new life went
 * home with the dead life's count (2/net/mesh/direct lap q6dc1, ino 8388736:
 * an empty file's core with nblocks 1 and no extents, which xfs_dinode_verify
 * rejected on both nodes).  deadshell_sanitize_guard 1 (default) resets every
 * deferred dead shell whose home reads free; 0 keeps the mode-only test, the
 * same-build control.  deadshell_stale_blocks counts the hazard (a deferred
 * shell with no mode over a free home), deadshell_stale_sanitized the guard's
 * reach, and create_nblocks_inherited every create that reached
 * xfs_inode_init with a block count, by whatever path.
 */
int mxfs_deadshell_sanitize_guard = 1;
module_param_named(deadshell_sanitize_guard, mxfs_deadshell_sanitize_guard, int, 0644);
MODULE_PARM_DESC(deadshell_sanitize_guard,
		 "a create that recycles a peer-freed dead shell over a free home resets it to a free shell, mode or not (1=default; 0=only a shell that still has a mode, the same-build control)");
atomic_t mxfs_deadshell_stale_blocks = ATOMIC_INIT(0);
module_param_cb(deadshell_stale_blocks, &mxfs_dbg_atomic_param_ops,
		&mxfs_deadshell_stale_blocks, 0644);
MODULE_PARM_DESC(deadshell_stale_blocks,
		 "count of create-path recycles of a deferred dead shell with no mode over a free home (P-RECYCLE-DEADSHELL-STALE) (write resets)");
atomic_t mxfs_deadshell_stale_sanitized = ATOMIC_INIT(0);
module_param_cb(deadshell_stale_sanitized, &mxfs_dbg_atomic_param_ops,
		&mxfs_deadshell_stale_sanitized, 0644);
MODULE_PARM_DESC(deadshell_stale_sanitized,
		 "count of those shells deadshell_sanitize_guard reset to free (write resets)");
atomic_t mxfs_create_nblocks_inherited = ATOMIC_INIT(0);
module_param_cb(create_nblocks_inherited, &mxfs_dbg_atomic_param_ops,
		&mxfs_create_nblocks_inherited, 0644);
MODULE_PARM_DESC(create_nblocks_inherited,
		 "count of creates whose new inode reached xfs_inode_init with a nonzero block count (P-CREATE-NBLOCKS-INHERITED) (write resets)");
/*
 * D-CREATE-REUSE-OVER-PEER-FREED-LINKED-CORPSE-SHUTS-NODE-DOWN: a create that
 * takes a number a peer unlinked and freed while this node held the number's
 * old life evicted with its link count intact.  The copy never saw the peer's
 * unlink, so it still reads nlink 1, and P-CR63 deferred only a copy with
 * nlink 0: the linked one reached xfs_iget_check_free_state, which called the
 * free number corrupt, and xfs_create cancelled its dirty transaction
 * (2/disk/caw/direct lap iwc1, ino 141: the peer's free image was durable
 * 28 ms before the create took the number).  cr63_linked_defer 1 (default)
 * defers a linked copy to the recycle path's platter re-read as it does an
 * unlinked one; 0 lets it fall through, the same-build control.
 * cr63_linked_deferred counts the deferrals, cr63_linked_refused the ones
 * whose recycle then failed (a LIVE home, P-CR63-DEFER-DISKLIVE, or any other
 * error).
 */
int mxfs_cr63_linked_defer = 1;
module_param_named(cr63_linked_defer, mxfs_cr63_linked_defer, int, 0644);
MODULE_PARM_DESC(cr63_linked_defer,
		 "a create that finds a reclaimable copy of its number still linked defers the free-state check to the recycle path's platter re-read, as for an unlinked copy (1=default; 0=the linked copy falls through to the free-state check, the same-build control)");
atomic_t mxfs_cr63_linked_deferred = ATOMIC_INIT(0);
module_param_cb(cr63_linked_deferred, &mxfs_dbg_atomic_param_ops,
		&mxfs_cr63_linked_deferred, 0644);
MODULE_PARM_DESC(cr63_linked_deferred,
		 "count of creates that deferred a linked reclaimable copy to the platter re-read (P-CR63-DEADSHELL-DEFER-LINKED) (write resets)");
atomic_t mxfs_cr63_linked_refused = ATOMIC_INIT(0);
module_param_cb(cr63_linked_refused, &mxfs_dbg_atomic_param_ops,
		&mxfs_cr63_linked_refused, 0644);
MODULE_PARM_DESC(cr63_linked_refused,
		 "count of those deferrals whose recycle returned an error (P-CR63-LINKED-REFUSED) (write resets)");
/*
 * D-CREATE-REUSE-OVER-MID-TEARDOWN-SHELL-IGRAB-FAIL-DIRTY-CANCEL-SHUTDOWN,
 * H-CG1: P-CR63 igrabs a non-reclaimable cached copy of the number a create
 * took, to reset it for the create.  When the VFS inode is being torn down at
 * that instant (I_FREEING: a drop_caches or reclaim eviction) igrab fails, and
 * the copy fell through to xfs_iget_check_free_state, which called its stale
 * live mode corruption; xfs_create then cancelled its dirty transaction (lap
 * rsd11, ino 208: i_state 0x0 at the P-CR63-SHELL read, 0x60 at the igrab
 * 10 us later).  cr63_igrab_retry 1 (default) retries the lookup, as
 * upstream's cache-hit path treats every igrab failure (-EAGAIN, xfs_iget's
 * delay(1) loop), so the copy is met again once its teardown has made it
 * reclaimable and the recycle path re-reads the platter; 0 lets it fall
 * through, the same-build control.  cr63_igrab_fail counts the failed igrabs
 * in both settings, cr63_igrab_retried the retries.
 */
int mxfs_cr63_igrab_retry = 1;
module_param_named(cr63_igrab_retry, mxfs_cr63_igrab_retry, int, 0644);
MODULE_PARM_DESC(cr63_igrab_retry,
		 "a create whose number's cached copy is being evicted at the igrab retries the lookup once the teardown is done instead of failing the free-state check (1=default; 0=falls through, the same-build control)");
atomic_t mxfs_cr63_igrab_fail = ATOMIC_INIT(0);
module_param_cb(cr63_igrab_fail, &mxfs_dbg_atomic_param_ops,
		&mxfs_cr63_igrab_fail, 0644);
MODULE_PARM_DESC(cr63_igrab_fail,
		 "count of failed igrabs of a create's non-reclaimable cached copy (P-CR63-IGRAB-FAIL), in both settings (write resets)");
atomic_t mxfs_cr63_igrab_retried = ATOMIC_INIT(0);
module_param_cb(cr63_igrab_retried, &mxfs_dbg_atomic_param_ops,
		&mxfs_cr63_igrab_retried, 0644);
MODULE_PARM_DESC(cr63_igrab_retried,
		 "count of those failed igrabs retried (cr63_igrab_retry=1) (write resets)");
/*
 * D-LOCAL-CREATE-RESETS-HELD-STALE-COPY-IN-PLACE-REMOVED-NAME-ACTS-ON-NEW-FILE:
 * P-CR63 resets a VFS-live cached copy of the number a create took for the new
 * file, which is safe only for a copy nothing references.  A peer that removes
 * a file this node still references -- a task mid-operation through the removed
 * name, or the name's cached dentry -- frees the number while the copy is live
 * here, and this node's allocator may hand the number to a local create: the
 * copy is then the new file under its holder (2/disk/caw/direct lap snl1, inos
 * 2097281-2097283: a touch held through the removed name logged its setattr
 * against the new file).  Waiting at P-CR63 would deadlock (the creator holds
 * the parent's ILOCK and the AGI, and a refused holder re-walks through the
 * parent), so dialloc_held_skip 1 (default) skips such a candidate in the
 * allocator's walk, where nothing is dirtied, on the peer-held cooldown; 0
 * takes it, the same-build control.  cr63_held_reset counts the hazard (a
 * create's reset of a copy something else referenced) in both settings,
 * dialloc_held_skipped the guard's reach.
 */
int mxfs_dialloc_held_skip = 1;
module_param_named(dialloc_held_skip, mxfs_dialloc_held_skip, int, 0644);
MODULE_PARM_DESC(dialloc_held_skip,
		 "the inode allocator never takes a number whose cached copy on this node is referenced (1=default; 0=takes it, the same-build control)");
atomic_t mxfs_dialloc_held_skipped = ATOMIC_INIT(0);
module_param_cb(dialloc_held_skipped, &mxfs_dbg_atomic_param_ops,
		&mxfs_dialloc_held_skipped, 0644);
MODULE_PARM_DESC(dialloc_held_skipped,
		 "count of inode-allocator candidates dialloc_held_skip skipped because this node's cached copy of the number was referenced (P-DIALLOC-HELD-SKIP) (write resets)");
atomic_t mxfs_cr63_held_reset = ATOMIC_INIT(0);
module_param_cb(cr63_held_reset, &mxfs_dbg_atomic_param_ops,
		&mxfs_cr63_held_reset, 0644);
MODULE_PARM_DESC(cr63_held_reset,
		 "count of creates that reset a cached copy of their number something else still referenced (P-CR63-HELD), in both settings (write resets)");
/*
 * TEST ONLY, H-CG1's A/B: the failed igrab needs an eviction to begin in the
 * microseconds between a create's look at the cached copy and its igrab.
 * dbg_evict_stale_delay_ms holds a multi-node regular file's eviction that
 * long after clear_inode (I_FREEING set, no lock held) when the copy is
 * linked and stale -- a peer changed the number since this node cached it,
 * rsd11's copy -- one hold at a time and at most one start a second, so a
 * create that takes the number inside it meets the teardown at its igrab.
 * 0 (default) = off.  dbg_evict_stale_delayed counts the holds.
 */
int mxfs_dbg_evict_stale_delay_ms;
module_param_named(dbg_evict_stale_delay_ms, mxfs_dbg_evict_stale_delay_ms, int, 0644);
MODULE_PARM_DESC(dbg_evict_stale_delay_ms,
		 "TEST ONLY: hold a stale linked regular file's eviction this many ms after clear_inode, one at a time, at most one start a second (0=off, default)");
atomic_t mxfs_dbg_evict_stale_delayed = ATOMIC_INIT(0);
module_param_cb(dbg_evict_stale_delayed, &mxfs_dbg_atomic_param_ops,
		&mxfs_dbg_evict_stale_delayed, 0644);
MODULE_PARM_DESC(dbg_evict_stale_delayed,
		 "count of evictions dbg_evict_stale_delay_ms held (P-EVICT-STALE-DELAY) (write resets)");

void
mxfs_dbg_evict_stale_delay(
	struct xfs_inode	*ip)
{
	static atomic_t		busy = ATOMIC_INIT(0);
	static unsigned long	last_start;
	struct xfs_mount	*mp = ip->i_mount;
	struct inode		*inode = VFS_I(ip);
	int			ms = READ_ONCE(mxfs_dbg_evict_stale_delay_ms);

	if (ms <= 0 || !mp->m_mxfs_dlm ||
	    mxfs_v5_dlm_is_single_node(mp->m_mxfs_dlm))
		return;
	if (!S_ISREG(inode->i_mode) || inode->i_nlink == 0 ||
	    !READ_ONCE(ip->i_dlm_stale))
		return;
	if (READ_ONCE(last_start) &&
	    time_before(jiffies, READ_ONCE(last_start) + HZ))
		return;
	if (atomic_cmpxchg(&busy, 0, 1) != 0)
		return;
	WRITE_ONCE(last_start, jiffies);
	atomic_inc(&mxfs_dbg_evict_stale_delayed);
	mxfs_probe("mxfs: P-EVICT-STALE-DELAY ino=%llu ms=%d istate=0x%lx comm=%s -- TEST ONLY: holding a stale linked copy's eviction past clear_inode\n",
		(unsigned long long)ip->i_ino, ms, mxfs_istate(inode),
		current->comm);
	msleep(ms);
	atomic_set(&busy, 0);
}
/*
 * D-FREED-INODE-HOME-NEVER-PUBLISHED-LIVE-CORE-AFTER-CLEAN-UNMOUNT, H-F11
 * (xfs/xfs_inode.c, the P55C classification in xfs_iflush): a free's flush
 * whose cluster slot still holds this node's unlanded staged image of the
 * previous life (a cluster write masked or dropped it and re-armed the item)
 * classifies on the platter, and when the platter is already free it discharges
 * without copying anything in.  The slot stays logged by the attached item, so
 * the next write of the cluster put the dead life's live core home over the
 * free (14 of 14 P-FREE-LIVE-CORE in laps ftmp1/ftdp1, each 2-4 ms after its
 * P55C-HOME-PLATTER).  p55c_home_restore 1 (default) puts the slot back to the
 * platter's bytes before the classification; 0 leaves the staged bytes, the
 * same-build control.  p55c_home_restored counts the restores.
 */
int mxfs_p55c_home_restore = 1;
module_param_named(p55c_home_restore, mxfs_p55c_home_restore, int, 0644);
MODULE_PARM_DESC(p55c_home_restore,
		 "a free's flush that classifies on the platter because its cluster slot holds this node's unlanded staged image puts the slot back to the platter's bytes first (1=default; 0=leaves the staged bytes, the same-build control)");
atomic_t mxfs_p55c_home_restored = ATOMIC_INIT(0);
module_param_cb(p55c_home_restored, &mxfs_dbg_atomic_param_ops,
		&mxfs_p55c_home_restored, 0644);
MODULE_PARM_DESC(p55c_home_restored,
		 "count of cluster slots p55c_home_restore put back to the platter's bytes (P55C-HOME-RESTORED) (write resets)");
/*
 * D-0532 item (c), the in-core half: xfs_iget_recycle clears the previous
 * incarnation's i_dlm_bast_pending unconditionally.  Count the recycles
 * where the flag was actually SET — a peer's BAST delivered to the corpse
 * before it went reclaimable, whose drain had not run yet — because that is
 * the case where the clear leaves the peer waiting on a request nobody on
 * this node remembers.
 */
atomic_t mxfs_recycle_bast_dropped = ATOMIC_INIT(0);
module_param_cb(recycle_bast_dropped, &mxfs_dbg_atomic_param_ops,
		&mxfs_recycle_bast_dropped, 0644);
MODULE_PARM_DESC(recycle_bast_dropped,
		 "count of xfs_iget_recycle clears of a SET i_dlm_bast_pending on the recycled corpse (P-RECYCLE-BAST-DROP) (write resets)");
atomic_t mxfs_recycle_bast_kept = ATOMIC_INIT(0);
module_param_cb(recycle_bast_kept, &mxfs_dbg_atomic_param_ops,
		&mxfs_recycle_bast_kept, 0644);
MODULE_PARM_DESC(recycle_bast_kept,
		 "count of xfs_iget_recycle keeps of a SET i_dlm_bast_pending on a corpse whose cached grant is live (P-RECYCLE-BAST-KEEP) (write resets)");
int mxfs_recycle_adopt_fail_refuse = 1;
module_param_named(recycle_adopt_fail_refuse, mxfs_recycle_adopt_fail_refuse,
		   int, 0644);
MODULE_PARM_DESC(recycle_adopt_fail_refuse,
		 "xfs_iget_recycle fails the recycle when the platter image of a different incarnation is rejected, instead of handing the inode out with the fork the rejection left; 1=on (default), 0=hand it out, for A/B");
/*
 * A stale recycle (i_dlm_stale) re-reads the dinode through xfs_imap_to_bp,
 * which is a cache hit when the cluster buffer is P91-protected, so the adopt
 * verdict judged the kept buffer's bytes.  Those can still hold an
 * incarnation the platter has replaced, and keeping it resurrects a dead life
 * whose next unlink frees the number under the live one.  On: the verdict
 * takes the platter side-read the deferred-deadshell create already takes.
 * The side-read and the disagreement count run in both settings.
 */
int mxfs_recycle_stale_sideread = 1;
module_param_named(recycle_stale_sideread, mxfs_recycle_stale_sideread,
		   int, 0644);
MODULE_PARM_DESC(recycle_stale_sideread,
		 "xfs_iget_recycle judges a stale recycle of a P91-protected cluster buffer by the platter's dinode instead of the kept buffer's; 1=on (default), 0=the kept buffer's bytes, for A/B");
atomic_t mxfs_recycle_sideread_disagree = ATOMIC_INIT(0);
module_param_cb(recycle_sideread_disagree, &mxfs_dbg_atomic_param_ops,
		&mxfs_recycle_sideread_disagree, 0644);
MODULE_PARM_DESC(recycle_sideread_disagree,
		 "count of stale recycles whose P91-protected cluster buffer and platter side-read disagree on the dinode's mode or generation (P-RECYCLE-SIDEREAD) (write resets)");
int mxfs_recycle_bast_keep = 1;
module_param_named(recycle_bast_keep, mxfs_recycle_bast_keep, int, 0644);
MODULE_PARM_DESC(recycle_bast_keep,
		 "xfs_iget_recycle keeps a pending peer BAST on a corpse whose cached grant is still live instead of clearing it (D-0532 item c); 1=on (default), 0=the unconditional clear for A/B");

atomic_t mxfs_recycle_bast_stale = ATOMIC_INIT(0);
module_param_cb(recycle_bast_stale, &mxfs_dbg_atomic_param_ops,
		&mxfs_recycle_bast_stale, 0644);
MODULE_PARM_DESC(recycle_bast_stale,
		 "count of xfs_iget_recycle clears of a BAST signal on a corpse whose grant was already NL (the stale signal the clear exists for; P-RECYCLE-BAST-STALE) (write resets)");

void
mxfs_dlm_recycle_bast_note(struct xfs_inode *ip, uint8_t prev_state,
			   uint8_t prev_mode, int outcome)
{
	static atomic_t p_rcbd_n = ATOMIC_INIT(0);
	static const char *const what[] = { "STALE", "DROP", "KEEP" };

	atomic_inc(outcome == 2 ? &mxfs_recycle_bast_kept :
		   outcome == 1 ? &mxfs_recycle_bast_dropped :
		   &mxfs_recycle_bast_stale);
	if (atomic_inc_return(&p_rcbd_n) <= 64)
		mxfs_probe("mxfs: P-RECYCLE-BAST-%s ino=%llu prev_state=%u prev_mode=%u now_state=%u mode=%u pending=%d nlink=%u imode=0%o comm=%s -- recycle met a delivered BAST: %s\n",
			what[outcome],
			(unsigned long long)ip->i_ino, prev_state, prev_mode,
			ip->i_dlm_state, ip->i_dlm_mode,
			ip->i_dlm_bast_pending ? 1 : 0, VFS_I(ip)->i_nlink,
			VFS_I(ip)->i_mode, current->comm,
			outcome == 2 ? "the grant is live, the obligation stays with it" :
			outcome == 1 ? "the grant is live but recycle_bast_keep=0 cleared it" :
			"the grant is NL, the signal was stale");
}

/* Mappings refused under IOMAP_NOWAIT on a clustered mount (D-0532;
 * xfs_ilock_for_iomap): the coverage count proving the path was reached. */
atomic_t mxfs_iomap_nowait_refused = ATOMIC_INIT(0);
module_param_cb(iomap_nowait_refused, &mxfs_dbg_atomic_param_ops,
		&mxfs_iomap_nowait_refused, 0644);
MODULE_PARM_DESC(iomap_nowait_refused,
		 "count of IOMAP_NOWAIT mappings refused with -EAGAIN because the mount is clustered (write resets)");

/* D-0972: shared iomap mappings whose extent load asked the cluster for PR
 * (xfs_ilock_for_iomap through xfs_ilock_data_map_shared): the coverage
 * count proving a verification lap reached the load. */
atomic_t mxfs_iomap_iread_pr = ATOMIC_INIT(0);
module_param_cb(iomap_iread_pr, &mxfs_dbg_atomic_param_ops,
		&mxfs_iomap_iread_pr, 0644);
MODULE_PARM_DESC(iomap_iread_pr,
		 "count of shared iomap mappings whose extent-map load asked the cluster for PR, not EX (write resets)");

module_param_cb(bmbt_lookup_bad, &mxfs_dbg_atomic_param_ops,
		&mxfs_bmbt_lookup_bad, 0644);
MODULE_PARM_DESC(bmbt_lookup_bad,
		 "count of inode-rooted btree blocks a lookup refused (owner, level or empty node) on a clustered mount (write resets)");
module_param_cb(bmbt_rel_evicted, &mxfs_dbg_atomic_param_ops,
		&mxfs_bmbt_rel_evicted, 0644);
MODULE_PARM_DESC(bmbt_rel_evicted,
		 "count of cached bmbt blocks dropped at the end of a tenure (write resets)");
module_param_cb(bmbt_rel_busy, &mxfs_dbg_atomic_param_ops,
		&mxfs_bmbt_rel_busy, 0644);
MODULE_PARM_DESC(bmbt_rel_busy,
		 "count of cached bmbt blocks whose lock the tenure-end eviction could not take within its budget; that release is wedged (write resets)");
module_param_cb(bmbt_rel_localwork, &mxfs_dbg_atomic_param_ops,
		&mxfs_bmbt_rel_localwork, 0644);
MODULE_PARM_DESC(bmbt_rel_localwork,
		 "count of owned bmbt blocks found still carrying local work at the end of a tenure; that release is wedged (write resets)");
module_param_cb(bmbt_scan_stale_skip, &mxfs_dbg_atomic_param_ops,
		&mxfs_bmbt_scan_stale_skip, 0644);
MODULE_PARM_DESC(bmbt_scan_stale_skip,
		 "count of stale (freed) bmbt buffers a bmbt durability scan declined to write (write resets)");
module_param_cb(reg_bmbt_rel_flushed, &mxfs_dbg_atomic_param_ops,
		&mxfs_reg_bmbt_rel_flushed, 0644);
MODULE_PARM_DESC(reg_bmbt_rel_flushed,
		 "count of regular-file EX releases whose btree extent tree the release loop had to flush before the unlock (write resets)");
module_param_cb(reg_bmbt_rel_wedge, &mxfs_dbg_atomic_param_ops,
		&mxfs_reg_bmbt_rel_wedge, 0644);
MODULE_PARM_DESC(reg_bmbt_rel_wedge,
		 "count of regular-file releases that could not make the extent tree durable and shut down instead (write resets)");
module_param_cb(iflush_bmbt_capped, &mxfs_dbg_atomic_param_ops,
		&mxfs_iflush_bmbt_capped, 0644);
MODULE_PARM_DESC(iflush_bmbt_capped,
		 "count of owned bmbt blocks an inode flush's destage walk left unwritten because its hold array was full (write resets)");
module_param_cb(iflush_bmbt_notdone_needs, &mxfs_dbg_atomic_param_ops,
		&mxfs_iflush_bmbt_notdone_needs, 0644);
MODULE_PARM_DESC(iflush_bmbt_notdone_needs,
		 "count of owned bmbt blocks an inode flush's destage walk skipped for !XBF_DONE although they carried local work (write resets)");
module_param_cb(bmbt_evict_capped, &mxfs_dbg_atomic_param_ops,
		&mxfs_bmbt_evict_capped, 0644);
MODULE_PARM_DESC(bmbt_evict_capped,
		 "count of owned bmbt blocks a reload's eviction walk saw but left cached because its hold array was full (write resets)");
atomic_t mxfs_bmbt_write_unread = ATOMIC_INIT(0);
module_param_cb(bmbt_write_unread, &mxfs_dbg_atomic_param_ops,
		&mxfs_bmbt_write_unread, 0644);
MODULE_PARM_DESC(bmbt_write_unread,
		 "count of bmbt block writes whose in-core owner had unread btree extents (detector, write resets)");
module_param_cb(iflush_unread_clean_skip, &mxfs_dbg_atomic_param_ops,
		&mxfs_iflush_unread_clean_skip, 0644);
MODULE_PARM_DESC(iflush_unread_clean_skip,
		 "count of clean cached bmbt blocks an inode flush did not destage because the extents were unread (write resets)");
module_param_cb(iflush_unread_local, &mxfs_dbg_atomic_param_ops,
		&mxfs_iflush_unread_local, 0644);
MODULE_PARM_DESC(iflush_unread_local,
		 "count of bmbt blocks with local modifications found by an inode flush while the extents were unread (write resets)");

/* D-0970: write checks retaken exclusive on a clustered mount so the
 * timestamp update's EX never asks under this task's own shared ride. */
atomic_t mxfs_write_checks_excl = ATOMIC_INIT(0);
module_param_cb(write_checks_excl, &mxfs_dbg_atomic_param_ops,
		&mxfs_write_checks_excl, 0644);
MODULE_PARM_DESC(write_checks_excl,
		 "count of write checks retaken with the IOLOCK exclusive before the timestamp update on a clustered mount (write resets)");
module_param_cb(demote_survivor, &mxfs_dbg_atomic_param_ops,
		&mxfs_demote_survivor, 0644);
MODULE_PARM_DESC(demote_survivor,
		 "count of IOLOCK demotes performed on a sole survivor (write resets)");
module_param_cb(end_unpaired_single, &mxfs_dbg_atomic_param_ops,
		&mxfs_end_unpaired_single, 0644);
MODULE_PARM_DESC(end_unpaired_single,
		 "count of inode DLM ends on a sole survivor that found no holder (write resets)");
atomic_t mxfs_dio_hipri_refused = ATOMIC_INIT(0);
module_param_cb(rel_dio_waited, &mxfs_dbg_atomic_param_ops,
		&mxfs_rel_dio_waited, 0644);
MODULE_PARM_DESC(rel_dio_waited,
		 "count of inode grant releases that waited for this node's outstanding direct I/O before draining (write resets)");
module_param_cb(rel_dio_wait_max_us, &mxfs_dbg_atomic_param_ops,
		&mxfs_rel_dio_wait_max_us, 0644);
MODULE_PARM_DESC(rel_dio_wait_max_us,
		 "longest such wait in microseconds (write resets)");
module_param_cb(rel_dio_defer, &mxfs_dbg_atomic_param_ops,
		&mxfs_rel_dio_defer, 0644);
MODULE_PARM_DESC(rel_dio_defer,
		 "count of releases deferred at the terminal guard because direct I/O was still in flight (write resets)");
module_param_cb(rel_acq_inflight_abort, &mxfs_dbg_atomic_param_ops,
		&mxfs_rel_acq_inflight_abort, 0644);
MODULE_PARM_DESC(rel_acq_inflight_abort,
		 "count of inode grant releases that did not commit because an acquire of this node was in flight on the inode (write resets)");
atomic_t mxfs_acq_uncertified = ATOMIC_INIT(0);
module_param_cb(acq_uncertified, &mxfs_dbg_atomic_param_ops,
		&mxfs_acq_uncertified, 0644);
MODULE_PARM_DESC(acq_uncertified,
		 "count of EX acquires that returned on a published inode with no proving certificate (write resets)");
module_param_cb(dioend_admit, &mxfs_dbg_atomic_param_ops,
		&mxfs_dioend_admit, 0644);
MODULE_PARM_DESC(dioend_admit,
		 "count of direct-write completions admitted as nested holders during a release drain (write resets)");
module_param_cb(dio_hipri_refused, &mxfs_dbg_atomic_param_ops,
		&mxfs_dio_hipri_refused, 0644);
MODULE_PARM_DESC(dio_hipri_refused,
		 "count of polled direct I/Os refused on a clustered mount (write resets)");
/* Where the direct-write completion ran, and whether it ran while the
 * inode's release pipeline was in progress (state BAST/DEMOTING).  iomap
 * runs a completion that needs filesystem work — unwritten conversion, a
 * size update — on the direct-I/O completion workqueue, a kernel thread,
 * which the cached-grant fast path admits under the still-EX mode as a
 * counted holder; a completion in task context is the registry admission's
 * case.  A completion counted in_drain that returned (the wait then ended)
 * is the measured progress path. */
atomic_t mxfs_dioend_kthread = ATOMIC_INIT(0);
atomic_t mxfs_dioend_task = ATOMIC_INIT(0);
atomic_t mxfs_dioend_in_drain = ATOMIC_INIT(0);
module_param_cb(dioend_kthread, &mxfs_dbg_atomic_param_ops,
		&mxfs_dioend_kthread, 0644);
MODULE_PARM_DESC(dioend_kthread,
		 "count of direct-write completions that ran on a kernel thread (write resets)");
module_param_cb(dioend_task, &mxfs_dbg_atomic_param_ops,
		&mxfs_dioend_task, 0644);
MODULE_PARM_DESC(dioend_task,
		 "count of direct-write completions that ran in task context (write resets)");
module_param_cb(dioend_in_drain, &mxfs_dbg_atomic_param_ops,
		&mxfs_dioend_in_drain, 0644);
MODULE_PARM_DESC(dioend_in_drain,
		 "count of direct-write completions that began while the inode's grant release was in progress (write resets)");
module_param_cb(recov_tagged, &mxfs_dbg_atomic_param_ops, &mxfs_recov_tagged, 0644);
MODULE_PARM_DESC(recov_tagged, "count of buffers a foreign slice replay populated in this node's cache: every read the recovery task completed (write resets)");
module_param_cb(recov_queued, &mxfs_dbg_atomic_param_ops, &mxfs_recov_queued, 0644);
MODULE_PARM_DESC(recov_queued, "count of replayed images a foreign slice replay queued for write; tagged minus this is what it read and skipped (write resets)");
module_param_cb(recov_cache_hit, &mxfs_dbg_atomic_param_ops, &mxfs_recov_cache_hit, 0644);
MODULE_PARM_DESC(recov_cache_hit, "count of reads outside recovery served a recovery-populated image from the cache with no read (write resets)");
module_param_cb(recov_hit_in_recovery, &mxfs_dbg_atomic_param_ops, &mxfs_recov_hit_in_recovery, 0644);
MODULE_PARM_DESC(recov_hit_in_recovery, "count of the recovery task's own cache hits on images it populated, expected before retirement (write resets)");
module_param_cb(recov_bmbt_cached, &mxfs_dbg_atomic_param_ops, &mxfs_recov_bmbt_cached, 0644);
MODULE_PARM_DESC(recov_bmbt_cached, "census at recovery end: cached extent-tree images the replay wrote (write resets)");
module_param_cb(recov_dir_cached, &mxfs_dbg_atomic_param_ops, &mxfs_recov_dir_cached, 0644);
MODULE_PARM_DESC(recov_dir_cached, "census at recovery end: cached directory/attr/symlink images the replay wrote, plus unverified ones (write resets)");
module_param_cb(recov_agbt_cached, &mxfs_dbg_atomic_param_ops, &mxfs_recov_agbt_cached, 0644);
MODULE_PARM_DESC(recov_agbt_cached, "census at recovery end: cached AG btree images the replay wrote (write resets)");
module_param_cb(recov_other_cached, &mxfs_dbg_atomic_param_ops, &mxfs_recov_other_cached, 0644);
MODULE_PARM_DESC(recov_other_cached, "census at recovery end: cached fixed-address images the replay wrote, not evicted (write resets)");
module_param_cb(recov_evicted, &mxfs_dbg_atomic_param_ops, &mxfs_recov_evicted, 0644);
MODULE_PARM_DESC(recov_evicted, "count of recovery-written images retired at the recovery's end (write resets)");
module_param_cb(recov_busy, &mxfs_dbg_atomic_param_ops, &mxfs_recov_busy, 0644);
MODULE_PARM_DESC(recov_busy, "count of recovery-written images that could not be locked for retirement; the recovery is retried (write resets)");
module_param_cb(recov_localwork, &mxfs_dbg_atomic_param_ops, &mxfs_recov_localwork, 0644);
MODULE_PARM_DESC(recov_localwork, "count of recovery-written images still carrying local work at the recovery's end; the recovery is retried (write resets)");
void
mxfs_atomic_max(atomic_t *v, int n)
{
	int	o = atomic_read(v);

	while (o < n && !atomic_try_cmpxchg(v, &o, n))
		;
}
module_param_cb(rel_dio_inflight, &mxfs_dbg_atomic_param_ops,
		&mxfs_rel_dio_inflight, 0644);
MODULE_PARM_DESC(rel_dio_inflight,
		 "count of inode grant releases committed with direct I/O still in flight (write resets)");

/*
 * D-0948: a SPARSE inode record carries every hole bit SET in its free mask
 * (the carve stamps ir_free = ALL_FREE and describes the missing half with
 * ir_holemask), so a pick that walks ir_free without masking the holes hands
 * out an inode number whose home block was never carved -- it belongs to
 * whatever owns that block.  Upstream's xfs_inobt_first_free_inode masks the
 * holes; the MXFS pick in mxfs_dialloc_pick_in_rec (xfs/libxfs/xfs_ialloc.c)
 * did not, and on s572 handed out offset 0 of a record whose holemask was
 * 0xff, the home being a live directory data block.  The pick masks the
 * holes now.  dbg_dialloc_pick_holes=1 restores the hole-blind walk as the
 * control arm of an A/B: it re-opens the defect and is for measurement only.
 * dialloc_holemask_n counts records whose free mask had hole bits masked out
 * (the fixed path was exercised on a sparse record with holes below a free
 * inode); dialloc_holepick_n counts picks that landed inside a hole, which
 * only the control arm can produce.
 */
int mxfs_dbg_dialloc_pick_holes = 0;
module_param_named(dbg_dialloc_pick_holes, mxfs_dbg_dialloc_pick_holes, int, 0644);
MODULE_PARM_DESC(dbg_dialloc_pick_holes,
		 "TEST ONLY: 1 = walk a sparse inode record's free mask without masking its holes (the pre-fix D-0948 pick; re-opens the defect)");
atomic_t mxfs_dialloc_holemask_n = ATOMIC_INIT(0);
module_param_cb(dialloc_holemask_n, &mxfs_dbg_atomic_param_ops,
		&mxfs_dialloc_holemask_n, 0644);
MODULE_PARM_DESC(dialloc_holemask_n,
		 "count of sparse inode records whose free-mask walk masked out hole bits (write resets)");
int mxfs_dbg_force_sparse_carve = 0;
module_param_named(dbg_force_sparse_carve, mxfs_dbg_force_sparse_carve, int, 0644);
MODULE_PARM_DESC(dbg_force_sparse_carve,
		 "TEST ONLY: 1 = every inode-chunk carve takes the sparse path; 2 = and carves the UPPER half of the next chunk-aligned region first (holes below the inodes, the D-0948 shape)");
atomic_t mxfs_dialloc_holepick_n = ATOMIC_INIT(0);
module_param_cb(dialloc_holepick_n, &mxfs_dbg_atomic_param_ops,
		&mxfs_dialloc_holepick_n, 0644);
MODULE_PARM_DESC(dialloc_holepick_n,
		 "count of inode picks that landed inside a sparse record's hole (control arm only; write resets)");

/*
 * 0.84.17, test only (D-0946): read the platter dinode at EVERY create-path
 * inode recycle in xfs_iget_recycle and fail the recycle when it is LIVE.
 * The defect's chain ended at that read, but only a shell that still carried
 * a mode or blocks reached it; a locally freed shell has neither, so ordinary
 * churn never asserts on the number the allocator handed out.  With this on,
 * every recycled number is asserted: under the fixed allocator a fire is a
 * crossed FREE-PUBLISH invariant (a FREE obligation is retired only by the
 * completion of the write carrying the free image), and under the control
 * arm it reproduces the original shutdown on demand.  The two counters exist
 * so a harness can prove the check RAN -- a silent instrument and a clean
 * system are the same observation otherwise.  0 in production.
 */
/*
 * Test only: xfs_iformat_data_fork rejects the btree-format dinode of this one
 * inode number, as xfs_iformat_btree does a corrupt one: after if_format and
 * if_needextents are set and before the root is allocated.  It is how a test
 * reaches the failure arms of the MXFS fork rebuilds (the recycle adopt in
 * xfs_iget_recycle, the reload adopt), which a healthy platter never does.
 * The counter proves the injection ran.  0 in production.
 */
unsigned long long mxfs_dbg_iformat_reject_ino = 0;
module_param_named(dbg_iformat_reject_ino, mxfs_dbg_iformat_reject_ino,
		   ullong, 0644);
MODULE_PARM_DESC(dbg_iformat_reject_ino,
		 "TEST ONLY: reject this inode's btree-format data fork as corrupt when it is read from disk; 18446744073709551615 (~0) = every one the recycle adopt rebuilds (0=off)");
atomic_t mxfs_dbg_iformat_rejected = ATOMIC_INIT(0);
/*
 * Test only: background and shrinker inode reclaim skip every inode while
 * this is set, so an evicted inode stays a reclaimable shell for the next
 * lookup to recycle (unmount still reclaims).  How a test reaches
 * xfs_iget_recycle, which eviction and the shrinker in one drop_caches pass
 * otherwise leave no window for.  0 in production.
 */
int mxfs_dbg_reclaim_hold = 0;
module_param_named(dbg_reclaim_hold, mxfs_dbg_reclaim_hold, int, 0644);
MODULE_PARM_DESC(dbg_reclaim_hold,
		 "TEST ONLY: background and shrinker inode reclaim skip every inode, so evicted inodes stay reclaimable shells (unmount still reclaims; 0=off)");
module_param_cb(dbg_iformat_rejected, &mxfs_dbg_atomic_param_ops,
		&mxfs_dbg_iformat_rejected, 0644);

int mxfs_dbg_recycle_platter_assert = 0;
module_param_named(dbg_recycle_platter_assert, mxfs_dbg_recycle_platter_assert,
		   int, 0644);
MODULE_PARM_DESC(dbg_recycle_platter_assert,
		 "TEST ONLY: read the platter dinode on every create-path inode recycle and fail a LIVE one (0=off)");
static atomic_t mxfs_dbg_recycle_platter_checked = ATOMIC_INIT(0);
module_param_cb(dbg_recycle_platter_checked, &mxfs_dbg_atomic_param_ops,
		&mxfs_dbg_recycle_platter_checked, 0644);
MODULE_PARM_DESC(dbg_recycle_platter_checked,
		 "TEST ONLY: recycles asserted on the platter (write resets)");
static atomic_t mxfs_dbg_recycle_platter_live = ATOMIC_INIT(0);
module_param_cb(dbg_recycle_platter_live, &mxfs_dbg_atomic_param_ops,
		&mxfs_dbg_recycle_platter_live, 0644);
MODULE_PARM_DESC(dbg_recycle_platter_live,
		 "TEST ONLY: recycles whose platter dinode read LIVE (write resets)");

void
mxfs_dbg_recycle_platter_note(bool live)
{
	atomic_inc(&mxfs_dbg_recycle_platter_checked);
	if (live)
		atomic_inc(&mxfs_dbg_recycle_platter_live);
}
EXPORT_SYMBOL(mxfs_dbg_recycle_platter_note);

/*
 * sess-pve DEBUG one-shot fault injection for the AGI umount-wedge reclaim
 * test.  Arm with `mxfs.dbg_dialloc_shutdown=1`; the next multi-node create
 * forces a DIRTY xfs_trans_cancel right after xfs_dialloc has logged +
 * mxfs_ag_meta_track'd the AGI/inobt/finobt — reproducing the natural
 * stale-inode dialloc corruption deterministically so the shutdown-abort
 * reclaim path fires under test.  Consumed atomically (one-shot).  Default 0.
 * NEVER enable in production — it deliberately shuts the filesystem down.
 */
int mxfs_dbg_dialloc_shutdown;
module_param_named(dbg_dialloc_shutdown, mxfs_dbg_dialloc_shutdown, int, 0644);
MODULE_PARM_DESC(dbg_dialloc_shutdown,
	"DEBUG one-shot: force a dirty dialloc trans_cancel on the next multi-node create (AGI umount-wedge reclaim test). Never enable in production.");

/*
 * True if this node currently owns (EX) the AG that contains this buffer's
 * blocks.  The AG DLM grant is EX-only, so ownership means no peer can be
 * concurrently mutating AG metadata.  Hint-only: a concurrent BAST clears
 * pag_dlm_cached early (before draining), so a false "owned" here is bounded
 * by the BAST commit point.  Used by the FUA gate.
 */
bool
mxfs_buf_ag_owned_ex(
	struct xfs_buf	*bp)
{
	struct xfs_mount	*mp = bp->b_mount;
	xfs_agnumber_t		agno;
	struct xfs_perag	*pag;
	bool			owned = false;

	if (!mp || !mp->m_sb.sb_agblocks || bp->b_map_count < 1)
		return false;
	agno = xfs_daddr_to_agno(mp, bp->b_maps[0].bm_bn);
	if (agno >= mp->m_sb.sb_agcount)
		return false;
	pag = xfs_perag_get(mp, agno);
	if (!pag)
		return false;
	if (pag->pag_dlm_holders > 0 || pag->pag_dlm_cached)
		owned = true;
	xfs_perag_put(pag);
	return owned;
}

/* Classify a FUA read by buffer ops and bump the matching counter.  Emits a
 * cumulative pr_warn every 1024 inode-cluster FUA reads so the composition is
 * reliably visible in dmesg (the rate-limited report_stats line does not
 * surface). */
void
mxfs_fua_count(
	struct xfs_buf	*bp)
{
	const struct xfs_buf_ops *ops = bp->b_ops;
	static atomic64_t total;
	int64_t t;

	if (mxfs_buf_is_ag_metadata(bp)) {
		atomic64_inc(&mxfs_fua_agmeta_reads);
	} else if (ops == &xfs_inode_buf_ops || ops == &xfs_inode_buf_ra_ops) {
		atomic64_inc(&mxfs_fua_inode_reads);
		/* PERF probe (instrumented): log inode-cluster FUA daddrs
		 * so we can count REPEAT reads of the same cluster (caching/stale
		 * thrash, fixable) vs distinct clusters (inherent).  Gated on the
		 * existing dir_perf_probe param; capped. */
		if (mxfs_dir_perf_probe) {
			extern int mxfs_v5_dlm_get_node_slot(struct mxfs_v5_dlm *);
			static atomic_t p19 = ATOMIC_INIT(0);
			if (atomic_inc_return(&p19) <= 4000)
				mxfs_probe("mxfs: P19-INOFUA daddr=%lld len=%u slot=%d comm=%s\n",
					(long long)bp->b_maps[0].bm_bn,
					(unsigned int)bp->b_maps[0].bm_len,
					bp->b_mount && bp->b_mount->m_mxfs_dlm ?
					mxfs_v5_dlm_get_node_slot(bp->b_mount->m_mxfs_dlm) : -1,
					current->comm);
		}
	} else if (ops == &xfs_dir3_data_buf_ops ||
		   ops == &xfs_dir3_block_buf_ops ||
		   ops == &xfs_dir3_leaf1_buf_ops ||
		   ops == &xfs_dir3_leafn_buf_ops ||
		   ops == &xfs_dir3_free_buf_ops) {
		atomic64_inc(&mxfs_fua_dir_reads);
	}

	/* Emit cumulative composition every 256 FUA reads (any class) so the
	 * inode/dir/agmeta split is reliably visible in dmesg. */
	t = atomic64_inc_return(&total);
	if ((t & 255) == 0)
		mxfs_probe("mxfs: FUA-COUNT total=%lld ino=%lld dir=%lld agm=%lld scsi=%lld p91skip=%lld oskip=%lld igstale=%lld ccprev=%lld ccprev_nostale=%lld ccprev_tenure_hit=%lld realns=%llu\n",
			t,
			(long long)atomic64_read(&mxfs_fua_inode_reads),
			(long long)atomic64_read(&mxfs_fua_dir_reads),
			(long long)atomic64_read(&mxfs_fua_agmeta_reads),
			(long long)atomic64_read(&mxfs_fua_scsi_actual),
			(long long)atomic64_read(&mxfs_fua_p91_skip),
			(long long)atomic64_read(&mxfs_fua_inode_owned_skip),
			(long long)atomic64_read(&mxfs_iget_cluster_staled),
			(long long)atomic64_read(&mxfs_ccprev_reads),
			(long long)atomic64_read(&mxfs_ccprev_nostale),
			(long long)atomic64_read(&mxfs_ccprev_tenure_hit),
			(unsigned long long)ktime_get_real_ns());
}

void mxfs_dlm_report_stats(void)
{
	uint64_t now = mxfs_pal_time_ms();
	int64_t hit, miss, imm, def, noino;
	int64_t ag_acq, ag_nest, ag_rel;

	if (mxfs_dlm_stat_last_report && now - mxfs_dlm_stat_last_report < 10000)
		return;
	mxfs_dlm_stat_last_report = now;

	hit = atomic64_read(&mxfs_dlm_stat_cache_hit);
	miss = atomic64_read(&mxfs_dlm_stat_cache_miss);
	imm = atomic64_read(&mxfs_dlm_stat_bast_immediate);
	def = atomic64_read(&mxfs_dlm_stat_bast_deferred);
	noino = atomic64_read(&mxfs_dlm_stat_bast_no_inode);
	ag_acq = atomic64_read(&mxfs_dlm_stat_ag_acquire);
	ag_nest = atomic64_read(&mxfs_dlm_stat_ag_nested);
	ag_rel = atomic64_read(&mxfs_dlm_stat_ag_release);

	if ((hit + miss > 0 || ag_acq > 0))
		mxfs_pal_log(MXFS_LOG_DEBUG,
			"mxfs DLM cache: hit=%lld miss=%lld (%lld%%) "
			"bast: imm=%lld def=%lld noino=%lld "
			"ag: acq=%lld nest=%lld rel=%lld trybusy=%lld trydemote=%lld "
			"handoff: n=%lld latch_unlock=%lld latch_acq=%lld latch_acqnb=%lld b2c_ms=%lld b2c_max=%lld b2c_gt50=%lld b2c_gt500=%lld c2r_ms=%lld c2r_max=%lld c2r_gt50=%lld c2r_gt500=%lld dwait_n=%lld dwait_ms=%lld dwait_max=%lld dwait_trans=%lld dwait_dirty=%lld postlatch_adopt=%lld q_gt500=%lld q_max=%lld wq_gt500=%lld wq_max=%lld e2a_gt500=%lld e2a_max=%lld a2c_gt500=%lld a2c_max=%lld rxheld=%lld stale_hint=%lld "
			"resv: try=%lld ok=%lld cont=%lld cool=%lld err=%lld exh=%lld adv=%lld sweeps=%lld backoff_ms=%lld demand=%lld probe_us=%lld probe_max_us=%lld grow=%lld "
			"noino_lc: inact=%lld needinact=%lld inew=%lld ireclaim=%lld vfsteardown=%lld reclaimable=%lld requeued=%lld lc_timeouts=%lld "
			"fua: ino=%lld dir=%lld agm=%lld ino_skip=%lld ccprev=%lld ccprev_nostale=%lld ccprev_tenure_hit=%lld",
			hit, miss,
			(hit + miss) ? hit * 100 / (hit + miss) : 0,
			imm, def, noino,
			ag_acq, ag_nest, ag_rel,
			(long long)atomic64_read(&mxfs_dlm_stat_agtry_localbusy),
			(long long)atomic64_read(&mxfs_dlm_stat_ag_trydemoting),
			(long long)atomic64_read(&mxfs_dlm_stat_handoff_n),
			(long long)atomic64_read(&mxfs_dlm_stat_latch_unlock),
			(long long)atomic64_read(&mxfs_dlm_stat_latch_acq),
			(long long)atomic64_read(&mxfs_dlm_stat_latch_acqnb),
			(long long)atomic64_read(&mxfs_dlm_stat_handoff_b2c_ms),
			(long long)atomic64_read(&mxfs_dlm_stat_handoff_b2c_max),
			(long long)atomic64_read(&mxfs_dlm_stat_handoff_b2c_gt50),
			(long long)atomic64_read(&mxfs_dlm_stat_handoff_b2c_gt500),
			(long long)atomic64_read(&mxfs_dlm_stat_handoff_c2r_ms),
			(long long)atomic64_read(&mxfs_dlm_stat_handoff_c2r_max),
			(long long)atomic64_read(&mxfs_dlm_stat_handoff_c2r_gt50),
			(long long)atomic64_read(&mxfs_dlm_stat_handoff_c2r_gt500),
			(long long)atomic64_read(&mxfs_dlm_stat_demote_wait_n),
			(long long)atomic64_read(&mxfs_dlm_stat_demote_wait_ms),
			(long long)atomic64_read(&mxfs_dlm_stat_demote_wait_max),
			(long long)atomic64_read(&mxfs_dlm_stat_demote_wait_trans),
			(long long)atomic64_read(&mxfs_dlm_stat_demote_wait_dirty),
			(long long)atomic64_read(&mxfs_dlm_stat_postlatch_adopt),
			(long long)atomic64_read(&mxfs_dlm_stat_handoff_q_gt500),
			(long long)atomic64_read(&mxfs_dlm_stat_handoff_q_max),
			(long long)atomic64_read(&mxfs_dlm_stat_handoff_wq_gt500),
			(long long)atomic64_read(&mxfs_dlm_stat_handoff_wq_max),
			(long long)atomic64_read(&mxfs_dlm_stat_handoff_e2a_gt500),
			(long long)atomic64_read(&mxfs_dlm_stat_handoff_e2a_max),
			(long long)atomic64_read(&mxfs_dlm_stat_handoff_a2c_gt500),
			(long long)atomic64_read(&mxfs_dlm_stat_handoff_a2c_max),
			(long long)atomic64_read(&mxfs_dlm_stat_handoff_rxheld),
			(long long)atomic64_read(&mxfs_dlm_stat_stale_hint),
			(long long)atomic64_read(&mxfs_resv_stat_try),
			(long long)atomic64_read(&mxfs_resv_stat_ok),
			(long long)atomic64_read(&mxfs_resv_stat_contended),
			(long long)atomic64_read(&mxfs_resv_stat_cool),
			(long long)atomic64_read(&mxfs_resv_stat_err),
			(long long)atomic64_read(&mxfs_resv_stat_exhaust),
			(long long)atomic64_read(&mxfs_resv_stat_recadv),
			(long long)atomic64_read(&mxfs_resv_stat_sweeps),
			(long long)atomic64_read(&mxfs_resv_stat_backoff_ms),
			(long long)atomic64_read(&mxfs_resv_stat_demand),
			(long long)(atomic64_read(&mxfs_resv_stat_probe_ns) / 1000),
			(long long)(atomic64_read(&mxfs_resv_stat_probe_max_ns) / 1000),
			(long long)atomic64_read(&mxfs_resv_stat_grow),
			(long long)atomic64_read(&mxfs_noino_lifecycle_stat[XFS_ILC_INACTIVATING]),
			(long long)atomic64_read(&mxfs_noino_lifecycle_stat[XFS_ILC_NEED_INACTIVE]),
			(long long)atomic64_read(&mxfs_noino_lifecycle_stat[XFS_ILC_INEW]),
			(long long)atomic64_read(&mxfs_noino_lifecycle_stat[XFS_ILC_IRECLAIM]),
			(long long)atomic64_read(&mxfs_noino_lifecycle_stat[XFS_ILC_VFS_TEARDOWN]),
			(long long)atomic64_read(&mxfs_noino_lifecycle_stat[XFS_ILC_RECLAIMABLE]),
			(long long)atomic64_read(&mxfs_noino_lifecycle_requeued),
			(long long)atomic64_read(&mxfs_noino_lifecycle_timeouts),
			(long long)atomic64_read(&mxfs_fua_inode_reads),
			(long long)atomic64_read(&mxfs_fua_dir_reads),
			(long long)atomic64_read(&mxfs_fua_agmeta_reads),
			(long long)atomic64_read(&mxfs_fua_inode_owned_skip),
			(long long)atomic64_read(&mxfs_ccprev_reads),
			(long long)atomic64_read(&mxfs_ccprev_nostale),
			(long long)atomic64_read(&mxfs_ccprev_tenure_hit));
}

/* P71 instrumented probe: run68's wedge kept a leaked
 * i_dlm_ex_holders=1 with no live holder task, permanently blocking the
 * ilock_end/notify BAST re-fire (both require exact-zero counts).  Print
 * every holder-count transition taken while the lock state is in a
 * demote/BAST window (normal CACHED traffic stays silent) so the leaking
 * site+comm self-identify.  Caller holds i_dlm_lock.  Capped. */
void
mxfs_p71_hold(struct xfs_inode *ip, const char *site, int dex, int dpr)
{
	static atomic_t p71_n = ATOMIC_INIT(0);

	if (ip->i_dlm_state != MXFS_DLM_ISTATE_DEMOTING &&
	    ip->i_dlm_state != MXFS_DLM_ISTATE_BAST)
		return;
	if (atomic_inc_return(&p71_n) > 8000)
		return;
	mxfs_probe("mxfs: P71-HOLD ino=%llu %s d_ex=%d d_pr=%d now_ex=%u now_pr=%u mode=%u state=%u pin=%u comm=%s\n",
		(unsigned long long)ip->i_ino, site, dex, dpr,
		ip->i_dlm_ex_holders, ip->i_dlm_pr_holders,
		ip->i_dlm_mode, ip->i_dlm_state, ip->i_dlm_pin_count,
		current->comm);
}
atomic64_t mxfs_noino_lifecycle_stat[XFS_ILC_NR];
atomic64_t mxfs_noino_lifecycle_requeued = ATOMIC64_INIT(0);
atomic64_t mxfs_noino_lifecycle_timeouts = ATOMIC64_INIT(0);
module_param_cb(sf_own_image_hits, &mxfs_dbg_atomic_param_ops,
		&mxfs_sf_own_image_hits, 0644);
MODULE_PARM_DESC(sf_own_image_hits,
		 "refreshes that found this node's own flushed image on the platter and kept the in-core fork (write resets)");
module_param_cb(sf_own_image_recorded, &mxfs_dbg_atomic_param_ops,
		&mxfs_sf_own_image_recorded, 0644);
MODULE_PARM_DESC(sf_own_image_recorded,
		 "shortform dir images recorded at flush into the own-image ring (write resets)");
module_param_cb(sf_release_base, &mxfs_dbg_atomic_param_ops,
		&mxfs_sf_release_base, 0644);
MODULE_PARM_DESC(sf_release_base,
		 "merge bases captured from the platter at a shortform dir's EX release (write resets)");
module_param_cb(sf_base_captures, &mxfs_dbg_atomic_param_ops,
		&mxfs_sf_base_captures, 0644);
MODULE_PARM_DESC(sf_base_captures,
		 "captures of a shortform dir's merge base, every caller (write resets)");
module_param_cb(sf_base_overlaps, &mxfs_dbg_atomic_param_ops,
		&mxfs_sf_base_overlaps, 0644);
MODULE_PARM_DESC(sf_base_overlaps,
		 "captures of a merge base that began while another capture of the same inode's base was in progress (write resets)");

/* ─── Inode init ─── */

/*
 * Initialize per-inode DLM fields.
 * Called from xfs_inode_alloc for every new xfs_inode.
 */
void
mxfs_dlm_inode_init(
	struct xfs_inode	*ip)
{
	/*
	 * FIRST, before anything that can reach mxfs_dlmtr_rec — the
	 * xfs_inode cache is not zeroing, so the authority backstop inside
	 * that chokepoint would otherwise read garbage state on a fresh
	 * allocation.  A fresh inode holds no authority by construction.
	 */
	/* tuple publication, associated with the writers' lock */
	seqcount_spinlock_init(&ip->i_mxfs_auth_seq, &ip->i_dlm_lock);
	ip->i_mxfs_auth_inact = MXFS_INACT_CERT_NONE;
	ip->i_mxfs_auth_state = MXFS_AUTH_NONE;
	ip->i_mxfs_auth_kind = 0;
	ip->i_mxfs_auth_reaffirm = 0;
	ip->i_mxfs_auth_gen = 1;	/* 0 is never a live snapshot value */
	ip->i_mxfs_auth_resource = 0;
	ip->i_mxfs_auth_epoch = 0;
	ip->i_mxfs_auth_lineage = 0;
	ip->i_mxfs_auth_incarn = 0;
	ip->i_mxfs_auth_line = MXFS_SITE;
	/*
	 * THE LAST-ATTEMPT RECORD IS PART OF THE SAME BLOCK AND MUST BE RESET
	 * WITH IT.  These five were the only members of the authority block
	 * left out, on a slab the comment above already states is not zeroing —
	 * so a recycled inode reported the PREVIOUS TENANT'S install attempt,
	 * and the documented reading of the pair ("try == NONE means no install
	 * was EVER attempted here", "try_gen < auth_gen means a revoke happened
	 * after the last attempt") was unsound for exactly the reused
	 * incarnations that need it most.  i_mxfs_auth_gen restarts at 1 here
	 * while try_gen carried an arbitrary older value, so the staleness
	 * comparison could read either way on evidence belonging to a different
	 * inode.  Nothing gates on these fields, but dispositions are made on
	 * them, and an instrument that reports a refusal that never happened
	 * sends the next investigation at the wrong code.
	 */
	ip->i_mxfs_auth_try = MXFS_AUTH_TRY_NONE;
	ip->i_mxfs_auth_try_mode = 0;
	ip->i_mxfs_auth_try_line = 0;
	ip->i_mxfs_auth_try_epoch = 0;
	ip->i_mxfs_auth_try_gen = 0;
	ip->i_mxfs_relmark_res = 0;	/* */
	ip->i_mxfs_relmark_epoch = 0;
	ip->i_mxfs_relmark_lineage = 0;
	ip->i_mxfs_auth_stamp_epoch = 0;
	ip->i_mxfs_auth_stamp_lineage = 0;
	ip->i_mxfs_rearm_res = 0;
	ip->i_mxfs_rearm_epoch = 0;
	ip->i_mxfs_rearm_lineage = 0;
	/* 0.84.18 (D-0963): no own-flushed shortform images yet.  The free
	 * callback releases them, so a recycled object arrives with NULLs. */
	{
		int	k;

		for (k = 0; k < MXFS_SF_OWN_RING; k++) {
			ip->i_dlm_dir_sf_own[k] = NULL;
			ip->i_dlm_dir_sf_own_bytes[k] = 0;
		}
		ip->i_dlm_dir_sf_own_next = 0;
	}
	atomic_set(&ip->i_dlm_dir_sf_base_busy, 0);
	ip->i_dlm_dir_sf_base_site = NULL;
	ip->i_dlm_dir_sf_base_pid = 0;

	spin_lock_init(&ip->i_dlm_lock);
	init_waitqueue_head(&ip->i_dlm_wait);
	INIT_WORK(&ip->i_dlm_bast_work, mxfs_dlm_bast_work_fn);
	INIT_DELAYED_WORK(&ip->i_dlm_bast_dwork, mxfs_dlm_bast_dwork_fn);
	ip->i_dlm_bast_pending = false;
	ip->i_dlm_drain_site = 0;	/* not inside a drain flush */
	ip->i_dlm_bast_starve_since_ns = 0;
	ip->i_dlm_dir_contended = false;	/* sticky shared-dir BAST flag */
	ip->i_dlm_dir_want_ex = false;		/* peer-wants-EX (modifier) BAST flag (design review) */
	ip->i_dlm_bast_during_acq = false;	/* deferred-during-ACQUIRING BAST */ ip->i_dlm_stale_src = 0; ip->i_dlm_bastq_src = 0;
	ip->i_mxfs_noino_waited = 0;
	ip->i_dlm_self_demote = false;		/* EDEADLK self-demote tag */
	ip->i_dlm_upg_pid = 0;
	ip->i_dlm_upg_until_ns = 0;
	ip->i_dlm_bastq_qns = 0;		/* P296-BASTQLAT arm stamp */
	ip->i_dlm_ex_acquire_ns = 0;
	{ u8 dtr_om = ip->i_dlm_mode, dtr_os = ip->i_dlm_state;
	ip->i_dlm_mode = MXFS_LOCK_NL;
	mxfs_dlmtr_rec(ip, dtr_om, dtr_os, MXFS_SITE); }
	ip->i_dlm_epoch_src = 0;
	ip->i_dlm_epoch = 1;	/* v0.5.1: != 0 so a fresh dentry (d_time==0) never epoch-fast-paths before one coordinated validation */
	ip->i_mxfs_unlink_epoch = 0;
	{ u8 dtr_om = ip->i_dlm_mode, dtr_os = ip->i_dlm_state;
	ip->i_dlm_state = MXFS_DLM_ISTATE_NONE;
	mxfs_dlmtr_rec(ip, dtr_om, dtr_os, MXFS_SITE); }
	/* #18: AFTER the two init transitions above — they pass a
	 * recycled-slab om into mxfs_dlmtr_rec, which would garbage-stamp
	 * these.  0 = no granted->NL lowering in THIS incarnation. */
	ip->i_dlm_nl_line = 0;
	ip->i_dlm_nl_pid = 0;
	ip->i_dlm_nl_ns = 0;
	ip->i_dlm_nl_om = 0;
	ip->i_dlm_nl_comm[0] = '\0';
	ip->i_dlm_ex_holders = 0; MXFS_DLMTR_H(ip);
	ip->i_dlm_pr_holders = 0; MXFS_DLMTR_H(ip);
	ip->i_dlm_pin_count = 0;
	ip->i_dlm_acq_inflight = 0;	/* daf50d34 no slow-path acquire in flight */
	ip->i_dlm_acq_pid = 0;		/* ACQUIRING-setter forensics */
	ip->i_dlm_acq_comm[0] = '\0';
	ip->i_dlm_acq_set_ns = 0;
	ip->i_dlm_exh_pid = 0;		/* EX-admission holder forensics */
	ip->i_dlm_exh_comm[0] = '\0';
	ip->i_dlm_exh_since_ns = 0;
	ip->i_dlm_acq_strikes = 0;
	ip->i_dlm_yield_remaining = 0;
	ip->i_dlm_dwork_strikes = 0;	/* v0.10.31: dwork busy-re-arm strikeout */
	ip->i_dlm_phantom_bast_j = 0;	/* FIX-20: phantom-BAST strikes */
	ip->i_dlm_phantom_bast_n = 0;
	ip->i_dlm_orphan_gg = 0;	/* FIX-H2: orphan-live strikes */
	ip->i_dlm_orphan_strikes = 0;
	ip->i_dlm_orphan_since_ns = 0;	/*  a864 wall-clock strand escape clock */
	{
		static atomic_t init_seq_ctr = ATOMIC_INIT(0);
		ip->i_dlm_init_seq = (uint32_t)atomic_inc_return(&init_seq_ctr);
	}
	ip->i_dlm_p72_strikes = 0;	/*  a864 P72 orphan-reclaim strike */
	ip->i_dlm_reconcile_pending = false;
	ip->i_dlm_dir_gen = 0;	/* read-time block-dir invalidation gen */
	ip->i_dlm_dir_loaded_gen = 0;	/* shortform-fork load gen */
	ip->i_mxfs_iget_ns = ktime_get_ns();	/* cold-iget age for P14 */
	/* recycled slab memory must not inherit the previous
	 * occupant's defer episode (same class as the stranded-demoter-claim
	 * root below) — a fresh in-core inode has no release in flight. */
	ip->i_mxfs_reldefer_started_j = 0;
	ip->i_mxfs_reldefer_progress_j = 0;
	ip->i_mxfs_reldefer_causes = 0;
	ip->i_mxfs_reldefer_badness = 0;
	ip->i_mxfs_reldefer_tries = 0;
	ip->i_mxfs_relwedge_shot = false;
	/* The release state too: WEDGED is entered and never left
	 * (mxfs_rel_state_set), so memory whose last occupant wedged would
	 * refuse every acquire on this new inode for the life of the mount
	 * (path_all_lost: a fenced node remounted and could not open a file
	 * its new mount had never touched).  Plain store, not the setter —
	 * the setter is what refuses to leave WEDGED. */
	if (ip->i_mxfs_rel_state == MXFS_RELSTATE_WEDGED)
		pr_warn_ratelimited("mxfs: P-RELSTATE-RECYCLED ino=%llu prev=WEDGED -- new in-core inode allocated in memory whose last occupant wedged; starting ACTIVE\n",
			(unsigned long long)ip->i_ino);
	WRITE_ONCE(ip->i_mxfs_rel_state, MXFS_RELSTATE_ACTIVE);
	ip->i_mxfs_dscan_clean_key = ~0ULL;	/* datascan gen-gate sentinel — first miss always scans */
	ip->i_dlm_handoff_acted_gen = 0;	/* no handoff acted on yet */
	ip->i_dlm_dir_valid_epoch = 0;	/* base predates any tracked handoff -> first dir grant refreshes */
	ip->i_dlm_dir_valid_incarn = 0;	/* NO baseline yet — mxfs_dir_epoch_superseded treats a mismatch against the live i_generation as "belongs to another incarnation" */
	ip->i_dlm_base_valid = 0;	/* Option B: no baseline for this in-core incarnation — first dir-EX authorization adopts (recycled slab memory would otherwise inherit the previous occupant's bit, exactly the class the demoter-claim root documents below) */
	ip->i_dlm_creator_base_state = MXFS_CBASE_UNSET;	/* no baseline established for this incarnation yet */
	ip->i_dlm_dir_acq_epoch = 0;	/* v0.6.5: never made coherent by an acquire-reload adopt yet */
	ip->i_dlm_icd_refused = false;	/* v0.6.5: no tenure-refused destage pending */
	ip->i_dlm_dir_evicted_gen = 0;	/* consumer eager-evict gen */
	ip->i_dlm_dir_evicted_incarn = 0;	/* ABA incarnation evict-key (0 != any real i_generation => first access force-evicts) */
	ip->i_dlm_dir_evict_mep = 0;	/* new-tenure evict baseline (0 => first multinode modify is a new tenure) */
	ip->i_dlm_adopt_ok_epoch = 0;	/* no clean adopt check under EX yet -> first modify reads */
	ip->i_dlm_adopt_ok_incarn = 0;
	ip->i_dlm_adopt_ok_dir_gen = 0;
	ip->i_dlm_leaf_scan_epoch = 0;	/* 0.75.61: first modify under EX scans the leaf range */
	ip->i_dlm_leaf_scan_incarn = 0;
	ip->i_mxfs_dir_hole_known = false;	/* 0.75.63: no legitimate data-region hole known for this incarnation */
	ip->i_mxfs_ex_grant_seq = 0;	/* DLM-epoch guard — no EX tenure yet */
	ip->i_mxfs_dirty_seq = 0;	/* no dirtying under EX yet */
	ip->i_mxfs_dirty_ns = 0;	/* P197: no dirtying timestamp yet */
	/*
	 *  — ROOT OF THE STRANDED DEMOTER CLAIM.
	 *
	 * xfs_inode_alloc gets its xfs_inode from alloc_inode_sb ->
	 * kmem_cache_alloc_lru.  That memory is NOT zeroed: it is a recycled
	 * slab object, and every MXFS field the initializer does not explicitly
	 * assign carries the PREVIOUS OCCUPANT's value.  i_dlm_demoter and
	 * i_dlm_demoter2 were "cleared" here by MXFS_CLEAR_DEMOTER, which — by
	 * deliberate design, and correctly for every other caller — REFUSES a
	 * clear by a task that owns neither slot (D-BAST-IRELE-INACTIVE-SELF-
	 * WEDGE: a non-owner clear is what stranded the real owner).  So an
	 * inherited claim was not cleared; it was logged as
	 * P76-DEMOTER-FOREIGN-CLEAR and left in place.
	 *
	 * The inode is then born with mxfs_foreign_demoter() already true, and
	 * it stays true for the life of the in-core inode: EVERY reload pays
	 * mxfs.reload_demote_wait_ms and abandons with i_dlm_stale set.  That is
	 * exactly the observed shape — a claim whose stamped holder PID no
	 * longer exists (it belongs to the slab object's previous life), the
	 * same stale pid across several unrelated inodes, ages of minutes, and
	 * P215-DEFER balance=0 proving the defer/drain accounting never lost
	 * anything.
	 *
	 * A FRESHLY ALLOCATED INODE CANNOT HAVE A DRAIN IN PROGRESS — it is not
	 * in the radix tree, so no other task can even name it.  The refusal has
	 * no meaning here.  Force both slots, unconditionally, and COUNT the
	 * inherited ones: that count is the direct measurement of the root.
	 */
	if (unlikely(ip->i_dlm_demoter || ip->i_dlm_demoter2)) {
		static atomic_t p216n = ATOMIC_INIT(0);

		atomic64_inc(&mxfs_dem_init_inherit);
		if (atomic_inc_return(&p216n) <= 200)
			mxfs_probe("mxfs: P216-INIT-INHERITED-CLAIM ino=%llu s1=%d s2=%d s1_pid=%d s1_comm=%s s1_line=%u:%u s1_depth=%d s2_pid=%d s2_line=%u:%u -- fresh inode inherited a demoter claim from the recycled slab object; forced NULL\n",
				(unsigned long long)ip->i_ino,
				!!ip->i_dlm_demoter, !!ip->i_dlm_demoter2,
				ip->i_dlm_demoter_pid, ip->i_dlm_demoter_comm,
				MXFS_SITE_ARGS(ip->i_dlm_demoter_line), ip->i_dlm_demoter_depth,
				ip->i_dlm_demoter2_pid,
				MXFS_SITE_ARGS(ip->i_dlm_demoter2_line));
	}
	ip->i_dlm_demoter = NULL;
	ip->i_dlm_demoter2 = NULL;
	ip->i_dlm_demoter_depth = 0;
	ip->i_dlm_demoter2_depth = 0;
	MXFS_CLEAR_DEMOTER(ip);
	ip->i_dlm_demoter_punt = 0;		/* no trans-free-retained claim */
	ip->i_dlm_punt_n[0] = 0;
	ip->i_dlm_punt_n[1] = 0;
	ip->i_dlm_demoter_punt_ns = 0;
	ip->i_dlm_demoter_injected = NULL;	/* no test-planted claim */
	ip->i_dlm_strand_named = false;		/* not yet named as stranded */
	ip->i_dlm_demoter2_pid = 0;		/* slot-2 forensics */
	ip->i_dlm_demoter2_comm[0] = '\0';
	ip->i_dlm_demoter2_set_ns = 0;
	ip->i_dlm_demoter2_line = 0;
	ip->i_dlm_clobber_victim_pid = 0;	/* no claim stolen on this incarnation */
	ip->i_dlm_clobber_victim_line = 0;
	ip->i_dlm_p6skip_n = 0;			/* H4: no P6 skip streak yet */
	ip->i_mxfs_self_created = false;	/* v0.5.4: only xfs_create's success path sets this */
	ip->i_mxfs_dead_incarn_gen = 0;	/* no dead-incarnation verdict */
	ip->i_mxfs_forkreset_src = 0;	/* no MXFS fork rebuild yet */
	ip->i_mxfs_fork_rejected = false;	/* no platter image rejected */
	ip->i_mxfs_freeob = 0;		/* no FREE obligation */
	ip->i_mxfs_freeob_strikes = 0;
	ip->i_mxfs_freepub_epoch = 0;	/* no FREE-publication claim */
	ip->i_mxfs_freepub_bp = NULL;
	ip->i_mxfs_freepub_seq = 0;
	ip->i_mxfs_freepub_gen = 0;
	/* D3 residual: publication obligation counters start equal =
	 * "nothing owed" (see the design block at xfs_inode.h). */
	ip->i_mxfs_pub_pending_seq = 0;
	ip->i_mxfs_pub_durable_seq = 0;
	ip->i_mxfs_pub_flush_seq = 0;	/* no image in flight */
	ip->i_mxfs_pub_durable_fepoch = 0;	/* F3: no discharge yet */
	/*
	 * MUST be reset with the counters above, for the reason the
	 * comment below spells out — xfs_inode_alloc is kmem_cache_alloc, not
	 * zalloc, so a recycled inode would otherwise inherit a stale
	 * "a fence abandoned my publication" verdict and its reload budget,
	 * and the release-side reload would fire (or refuse to) on evidence
	 * belonging to a previous incarnation.
	 */
	ip->i_mxfs_pub_fenced = 0;
	ip->i_mxfs_reldefer_reloads = 0;
	/*
	 * MUST be reset here.  xfs_inode_alloc uses kmem_cache_alloc,
	 * NOT zalloc, so a recycled xfs_inode carries whatever the previous
	 * tenant left in any field this function does not clear.  The first
	 * P219 measurement read `stage_epoch=2 now_epoch=1` on 18 of 22 hits —
	 * an epoch that went DOWN, which a monotonic counter cannot do: those
	 * were recycled inodes whose i_dlm_epoch had been re-initialised to 1
	 * while the stale staging stamp survived.  Instrument artifact, not a
	 * lost tenure.
	 */
	ip->i_mxfs_pub_stage_epoch = 0;
	ip->i_mxfs_pub_stage_mode = 0;
	ip->i_mxfs_pub_stage_ns = 0;
	ip->i_mxfs_relmark_ns = 0;	/* H-NR1: no marked recycle yet */
	ip->i_mxfs_atomic_bypass_ns = 0;	/* P229/P230 */
	ip->i_mxfs_disk_nlink_seen = 0;	/* P186: fresh incarnation */
	ip->i_mxfs_disk_nlink_gen = 0;
	ip->i_mxfs_reused_create = false;	/* v0.5.4 set by rearm_unpublished only */
	ip->i_dlm_unpublished = false;	/* deferred-publish */
	ip->i_mxfs_unpub_clr_line = 0;
	ip->i_dlm_iclus_seen_seq = 0;	/* iclus coherency clock: never loaded */
	ip->i_dlm_routed_iclus = false;	/* no grant, no backing resource */
	INIT_LIST_HEAD(&ip->i_dlm_unpub_link);
	INIT_LIST_HEAD(&ip->i_mxfs_pubclaim_link);
	ip->i_mxfs_pubclaim_seq = 0;
	ip->i_mxfs_pubclaim_ns = 0;
	ip->i_mxfs_pubclaim_bseq = 0;
	/* ILOCK last-locker forensics */
	atomic_set(&ip->i_mxfs_ilk_rd_held, 0);
	atomic_set(&ip->i_mxfs_ilk_wr_held, 0);	/* writer-quiescence census */
	ip->i_mxfs_pipe_relog = 0;		/* P234 tripwire gate */
	ip->i_mxfs_ilk_wr_ret = 0;
	ip->i_mxfs_ilk_rd_ret = 0;
	ip->i_mxfs_ilk_un_ret = 0;
	ip->i_mxfs_ilk_wr_pid = 0;
	ip->i_mxfs_ilk_rd_pid = 0;
	ip->i_mxfs_ilk_wr_comm[0] = '\0';
	ip->i_mxfs_ilk_rd_comm[0] = '\0';
	/*
	 * Start stale when DLM is active.  The in-memory inode is
	 * populated at iget/mount time before any DLM lock is held,
	 * so it may not reflect other nodes' changes.  The first
	 * DLM acquire (slow path) will see stale=true and reload
	 * from disk, ensuring we have the current on-disk state.
	 * Single-node mounts never check stale, so this is harmless.
	 */
	ip->i_dlm_stale = (ip->i_mount->m_mxfs_dlm != NULL);
}

/*
 * instrumented inode-lifecycle watch: mxfs.watch_ino=<ino>
 * traces every iflush / iflush-abort / DLM release-fence pass / reload-adopt
 * decision / dir-contraction event for one inode.  Hunting the run13 proven
 * loss: the rm-holder's committed dir contraction (block->SF) never reached
 * the on-disk dinode, yet its ILI looked clean at the next reload, which
 * adopted the stale EXTENTS map whose blocks the contraction had already
 * freed durably (bnobt) -> map-of-freed-blocks resurrected cluster-wide.
 */
unsigned long long mxfs_watch_ino;
module_param_named(watch_ino, mxfs_watch_ino, ullong, 0644);
MODULE_PARM_DESC(watch_ino,
		 "Trace iflush/abort/release-fence/reload for this inode number (0=off)");
EXPORT_SYMBOL(mxfs_watch_ino);

/*
 * Mount-time read of every AGF+AGI whose in-core summary is not built (a
 * fresh tenure taken during the mount phase clears it), so no AG is left
 * with a zero summary.  A rebuilt summary folds the peer's changes into this
 * node's counters (mxfs_pag_agf_reinit).  ~2 reads per AG through the normal
 * DLM-aware verified paths, once per mount.  Errors are non-fatal: the AG
 * just stays uninitialized until first use, exactly as before.
 */
void
mxfs_init_all_perag_data(
	struct xfs_mount	*mp)
{
	struct xfs_perag	*pag = NULL;
	int			inited = 0;

	if (!mp->m_mxfs_dlm || mxfs_v5_dlm_is_single_node(mp->m_mxfs_dlm))
		return;
	while ((pag = xfs_perag_next(mp, pag))) {
		struct xfs_buf	*bp;

		if (!xfs_perag_initialised_agf(pag)) {
			if (!xfs_alloc_read_agf(pag, NULL, 0, &bp))
				xfs_buf_relse(bp);
		}
		if (!xfs_perag_initialised_agi(pag)) {
			if (!xfs_ialloc_read_agi(pag, NULL, 0, &bp))
				xfs_buf_relse(bp);
		}
		inited++;
	}
	pr_info("mxfs: statfs perag baseline initialized (%d AGs)\n", inited);
}
EXPORT_SYMBOL(mxfs_init_all_perag_data);
/*
 * (#1 design review Q5): one lock serializes every setter that can
 * change the foreign_replay_token_enforce prerequisite predicates with the
 * enforce setter's check-then-write and with the recovery preflight's
 * config sample — a prerequisite can then never flip between "validated"
 * and "written", and an armed knob can never be invalidated underneath a
 * concurrent validation.  release_proof_enforce is 0444 (immutable at
 * runtime) so only the two F2-domain params below need the guard.
 */
DEFINE_MUTEX(mxfs_fr_cfg_lock);
EXPORT_SYMBOL(mxfs_fr_cfg_lock);

static int
mxfs_fua_disable_set(const char *val, const struct kernel_param *kp)
{
	int v;
	int rc = kstrtoint(val, 0, &v);

	if (rc)
		return rc;
	mutex_lock(&mxfs_fr_cfg_lock);
	if (v && READ_ONCE(mxfs_foreign_replay_token_enforce) &&
	    !mxfs_target_cache_protected) {
		mutex_unlock(&mxfs_fr_cfg_lock);
		pr_err("mxfs: fua_disable=%d REFUSED while foreign_replay_token_enforce is armed without target_cache_protected -- it would invalidate the F2 domain the enforcement arming was validated against.  Disarm foreign_replay_token_enforce first\n",
		       v);
		return -EBUSY;
	}
	WRITE_ONCE(mxfs_fua_disable, v);
	mutex_unlock(&mxfs_fr_cfg_lock);
	return 0;
}
static const struct kernel_param_ops mxfs_fua_disable_ops = {
	.set = mxfs_fua_disable_set,
	.get = param_get_int,
};
module_param_cb(fua_disable, &mxfs_fua_disable_ops, &mxfs_fua_disable, 0644);
MODULE_PARM_DESC(fua_disable,
                 "Disable SCSI-FUA reads; use normal bio (SCST shared cache "
                 "is coherent): 1=disable-FUA-reads (default, SCST-required), "
                 "0=use-FUA");

/*
 * on regular-file DLM release (BAST), iflush the dinode + flush the
 * device write cache so a peer's FUA read of the inode cluster sees the
 * writer's di_size (closes the cross-node empty-content failure).  Default
 * on; set 0 to A/B the correctness benefit vs the per-release flush cost.
 */
/*
 * DEFAULT OFF: tested =1 — it made cross-node empty-content WORSE
 * (40 fails vs ~15, 120 empty vs 36) and the test 10x slower (151s).  The
 * cross-node empty-content is a LATENCY-SENSITIVE RACE, not a missing-
 * durability problem: a per-release flush widens the race window rather than
 * closing it.  Kept off; the next session should NOT pursue durability fixes
 * for the empty-content — it is a coherence/race issue (see docs/history/session-39-lessons.md).
 */
/*
 * IRECLAIMABLE reused-inode DLM-coordinated reload in xfs_iget_cache_hit.
 * Default ON (needed for the create-race coherency: a peer-reused inode read as
 * mode=0 -> EACCES/ENOENT, blocks cache_coherency).  Param so it can be A/B'd:
 * it adds a reload (+ DLM round-trip for Type-A) per stale mode-0 iget, which
 * over-triggers on the unlink verify-gone phase (~480 igets of deleted files)
 * and pushes cache_coherency over its 900s budget.  The real fix is parent-
 * dir-block coherence so deleted dirents aren't followed at all.  Set
 * mxfs.reuse_reload=0 to isolate that perf cost / disable the create-race fix.
 */
int mxfs_reuse_reload = 1;
module_param_named(reuse_reload, mxfs_reuse_reload, int, 0644);
MODULE_PARM_DESC(reuse_reload,
                 "Cheap reload of IRECLAIMABLE reused inodes on iget "
                 "(1=on default, fixes create-race; 0=off, faster).");

/*
 * D-POSIX-MULTI-RANK1-COUNT-125-OF-128-AFTER-CREATE-DONE-BARRIER: 1 (default)
 * also reloads, on a non-create iget, a reclaimable FREED copy (mode 0) that
 * no stale flag marks when this node holds no grant on the number (its cached
 * mode is NL, or a no-inode release unlocked the one it caches): with no grant
 * nothing stops a peer reusing the number without telling this node, so the
 * copy's "free" is not authoritative and only the platter can say.  Measured
 * (tests/reused_corpse_lookup_enoent.sh, 2/disk/caw/direct): a node that
 * removed a peer's files kept their freed copies, the peer created new files
 * on the same numbers, and every lookup of the new names failed -ENOENT
 * (P-IGET-ENOENT incore_mode=0 reclaimable=1 dlm_stale=0, P26-IGET-FAIL) in
 * 10 of 10 laps at the default settings.  A reload that still reads free ends
 * the iget -ENOENT at once, so the lookup's nudge-and-retry ladder re-arms it
 * each lap.  0 = only a stale-flagged copy is reloaded (the same-build control).
 */
int mxfs_reuse_reload_ungranted = 1;
module_param_named(reuse_reload_ungranted, mxfs_reuse_reload_ungranted, int, 0644);
MODULE_PARM_DESC(reuse_reload_ungranted,
                 "a non-create iget reloads a reclaimable freed copy this node holds no grant on (1, default); 0 = only a stale-flagged one (test control)");

/*
 * gate the EXPENSIVE Type-A DLM PR round-trip inside the reuse_reload
 * path (BAST the peer to force its flush when disk still reads free).  Default
 * OFF — it over-fires on unlink verify-gone (~480 deleted-file igets) and times
 * out cache_coherency.  Cheap-only relies on the creator's eventual flush.
 */
int mxfs_reuse_dlm;
module_param_named(reuse_dlm, mxfs_reuse_dlm, int, 0644);
MODULE_PARM_DESC(reuse_dlm,
                 "Force a DLM PR round-trip for a still-free reused inode "
                 "(1=on, more correct under create-race; 0=off default, fast).");

/*
 *  — STRANDED CAW AG GRANT repair.
 *
 * The AG BAST schedule gate (mxfs_dlm_ag_bast_notify) requires
 * pag_dlm_cached: a release is only ever driven from the "we hold it on
 * disk and know it" state.  If a node ever reaches
 *     holders == 0 && !cached && !demoting && !release_pending
 * while its CAW holder bit is STILL SET on the platter, nothing on this
 * node can ever release that AG again — every peer BAST hits the gate,
 * finds nothing to schedule, and the peers block until the 480 s
 * liveness-extended disk-lock cap, at which point mxfs_dlm_ilock_begin
 * force-shuts the filesystem down.  Observed 2026-07-28 (32/caw, storm):
 * one stranded AG starved 31 peers and shut 21 of 32 filesystems down.
 *
 * The orphan-NAK covers the TCP flavour of this (master-side zombie
 * GRANTED entry) and is a NO-OP on CAW by construction — CAW has no
 * remote master table, the on-disk slot IS the truth, so the CAW repair
 * has to be a real release.
 *
 * Repair (mxfs.ag_strand_repair=1, default on): when the orphan condition
 * holds AND the CAW slot says we do hold the AG, re-adopt the grant into
 * pag_dlm_cached and hand it to the normal bast_work_fn.  That path runs
 * the FULL Architectural-Invariant-1 pipeline (log force + meta drain +
 * alloc buflist + inode buffers + blkdev flush) before
 * mxfs_v5_dlm_ag_unlock, so the repair can never publish a
 * not-yet-durable AG to a peer.  Set 0 to A/B against the pre-repair
 * behaviour (detect + report only).
 */
/*
 *  — H4: do not let a buffer-wide completion declare
 * unsubmitted inode bytes durable.  See MXFS_IF_PUB_SKIPPED (xfs_inode.h) and
 * xfs_buf_inode_iodone.  Default on; set 0 for a paired A/B against the old
 * (silently-lossy) behaviour.
 */
/*
 * MEASURED 2026-07-28 (build 609652CB): default 1 LIVELOCKS, exactly
 * as the design-consult review predicted.  Re-arming is only half a fix — the skip
 * happens BECAUSE this node no longer has publication authority, so the
 * retry can never succeed: xfsaild re-pushes, the sector is dropped again,
 * and the item is re-armed forever.  Storm run 155743: P187-PUB-REARM hit
 * its 4000 cap, P56-NL-LOGGED-DIR-SKIP went 21 -> 490, and test12 wedged in
 * mxfs_dlm_ilock_begin (INFRA-FAIL, 300 s).
 *
 * The completion lying about durability is still a real defect, but the
 * actionable repair is UPSTREAM: never leave the tenure with an unlanded
 * committed change (see P188-REL-OBLIGATION-AT-UNLOCK).  Re-arming becomes
 * safe only once that barrier holds, or once the retry can re-acquire the
 * inode grant and rebase before publishing.  Default OFF; kept as the lever
 * to re-test once the barrier is in.
 */
/*
 * — D-RELEASE-BARRIER-OPEN containment, review-ruled.
 * When set, the inode-cluster masking loop refuses to publish a LOGGED slot
 * whose image was staged under a tenure that has since died and for which we
 * hold no publication authority now (P222-STALE-STAGE-SKIP; measured shape:
 * xfsaild writing orphan images at NL after the grant-lost release, the
 * cluster-write-reverts-a-freed/reused-inode corruption class).  DEFAULT ON
 * since 0.11.272: paired laps on one module load measured skip=0 putting dead-
 * tenure images on the wire while skip=1 masked every detection (cumulative
 * sskip_landed=36, sskip_unlanded=0, wire writes of the class = 0) with the
 * full guard board green at healthy walls; 0 = pre-fix control.  See ccmemory
 * docs/rulings/stale-stage-mask-conditions.md for the full
 * condition set (three-state bookkeeping, recovery-side gate, EX-side
 * epoch-validity gate) this first cut deliberately scopes down from.
 */
int mxfs_stale_stage_skip = 1;
EXPORT_SYMBOL(mxfs_stale_stage_skip);
module_param_named(stale_stage_skip, mxfs_stale_stage_skip, int, 0644);
/* EX-side epoch gate (design review condition 4).  Separate knob by ruling —
 * never overload the NL knob.  1 = skip dead-tenure staged images from
 * EX-held home writes and restage under the live grant (PUB_SKIPPED
 * unconditional; retry succeeds at EX); 0 = legacy publish-at-EX control. */
int mxfs_stale_stage_skip_ex = 1;
EXPORT_SYMBOL(mxfs_stale_stage_skip_ex);
module_param_named(stale_stage_skip_ex, mxfs_stale_stage_skip_ex, int, 0644);
MODULE_PARM_DESC(stale_stage_skip_ex,
		 "EX-side dead-tenure staged-image gate (1=skip+restage "
		 "default, 0=legacy publish control)");
MODULE_PARM_DESC(stale_stage_skip,
                 "mask dead-tenure staged inode images out of home writes "
                 "(1=skip default, 0=pre-fix control; P222 counters in "
                 "P219-LOGGED-AUTHORITY-TOTAL)");

/*
 * (design review condition-1 ruling): the unlanded arm of the mask is an
 * invariant assertion, not a recovery path — a committed change whose only
 * non-journal copy is staged under a dead tenure at NL cannot be published
 * (cross-node corruption), completed (lost write), or re-armed bare (measured
 * AIL livelock).  Fail closed: shutdown -> lease loss -> peer fence -> the
 * journal copy is republished by the recovery protocol.  Never observed
 * (sskip_unlanded=0 across all laps/boards); 0 = legacy count-and-skip for
 * same-build A/B and fault injection only.
 */
int mxfs_stale_stage_unlanded_shutdown = 1;
EXPORT_SYMBOL(mxfs_stale_stage_unlanded_shutdown);
module_param_named(stale_stage_unlanded_shutdown, mxfs_stale_stage_unlanded_shutdown, int, 0644);
MODULE_PARM_DESC(stale_stage_unlanded_shutdown,
                 "fail closed (force shutdown) when a committed change is "
                 "found unlanded under a dead tenure at NL (1=shutdown "
                 "default, 0=legacy count-and-skip for A/B)");

/*
 * D-INODE-CLUSTER-PUBLISH-WITHOUT-AUTHORITY, H-RS1: the two masks above leave
 * release-flush and demoter contexts alone, and those contexts also carry
 * logged slots whose last copy-in was under a tenure that has since ended and
 * whose image already LANDED: an item logged again after its image went home
 * is attached to the cluster buffer again and rides a write started for other
 * slots, with the buffer's old bytes for it (lfb2: an inactivation's
 * re-logged item put the landed epoch-3 image over the peer's newer one).
 * 1 masks such a slot in those contexts too (lossless: the bytes are home
 * already, and the re-logged item stays dirty, so its next copy-in stages
 * current state under the live tenure); 0 is the same-build control, which
 * writes it.  stale_stage_rf_landed counts the slots found, in both settings
 * (P-RS1-LANDED-SKIP).
 */
int mxfs_stale_stage_skip_landed = 1;
module_param_named(stale_stage_skip_landed, mxfs_stale_stage_skip_landed, int, 0644);
MODULE_PARM_DESC(stale_stage_skip_landed,
		 "mask a dead-tenure logged inode slot whose image already landed from cluster writes in release-flush and demoter contexts too (1=mask default, 0=control)");
atomic_t mxfs_stale_stage_rf_landed = ATOMIC_INIT(0);
module_param_cb(stale_stage_rf_landed, &mxfs_dbg_atomic_param_ops,
		&mxfs_stale_stage_rf_landed, 0644);
MODULE_PARM_DESC(stale_stage_rf_landed,
		 "count of dead-tenure, already-landed logged slots found in release-flush or demoter cluster writes (P-RS1-LANDED-SKIP), masked or not (write resets)");

/*
 * D-INODE-CLUSTER-PUBLISH-WITHOUT-AUTHORITY, H-UB1: an inode item is attached
 * to its cluster buffer when the inode is first logged, not when it is copied
 * in, so the partial write's logged mask carries slots whose in-core life was
 * never copied in (i_mxfs_pub_stage_epoch 0), with the buffer's last read of
 * them: bytes this node never staged.  When that read predates this node's
 * tenure of the number and a peer wrote the slot in between, the write
 * reverts the peer (rk5: a peer's free of ino 131 put back to its older
 * unlinked image).  1 masks such a slot when it is not being flushed by this
 * write (lossless: the buffer's completion leaves a non-flushing item attached
 * and dirty, and its first copy-in stages the in-core state under the live
 * tenure); 0 is the same-build control, which writes it.
 * unstaged_logged_found counts the slots in both settings
 * (P-UB1-UNSTAGED-SKIP); with dino_clobber_check on, unstaged_logged_prevented
 * counts those a mask kept off the platter while they were behind it, and
 * unstaged_logged_regressed those written while behind it.
 */
int mxfs_unstaged_logged_skip = 1;
module_param_named(unstaged_logged_skip, mxfs_unstaged_logged_skip, int, 0644);
MODULE_PARM_DESC(unstaged_logged_skip,
		 "mask a logged inode slot whose in-core life was never copied in from cluster writes that do not flush it (1=mask default, 0=control)");
atomic_t mxfs_unstaged_logged_found = ATOMIC_INIT(0);
module_param_cb(unstaged_logged_found, &mxfs_dbg_atomic_param_ops,
		&mxfs_unstaged_logged_found, 0644);
MODULE_PARM_DESC(unstaged_logged_found,
		 "count of never-copied-in logged slots found in partial cluster writes (P-UB1-UNSTAGED-SKIP), masked or not (write resets)");
atomic_t mxfs_unstaged_logged_prevented = ATOMIC_INIT(0);
module_param_cb(unstaged_logged_prevented, &mxfs_dbg_atomic_param_ops,
		&mxfs_unstaged_logged_prevented, 0644);
MODULE_PARM_DESC(unstaged_logged_prevented,
		 "count of those slots masked while behind the platter (dino_clobber_check) (write resets)");
atomic_t mxfs_unstaged_logged_regressed = ATOMIC_INIT(0);
module_param_cb(unstaged_logged_regressed, &mxfs_dbg_atomic_param_ops,
		&mxfs_unstaged_logged_regressed, 0644);
MODULE_PARM_DESC(unstaged_logged_regressed,
		 "count of those slots written while behind the platter (dino_clobber_check) (write resets)");

/*
 * D-INODE-CLUSTER-PUBLISH-WITHOUT-AUTHORITY, H-NR1 (fw3c3): a no-inode release
 * that unlocks a grant a reclaimable in-core inode still caches cannot reach
 * that inode, so its tenure epoch stays where the dead grant left it.  A create
 * whose reservation re-takes the grant before xfs_iget recycles the inode then
 * passes mxfs_dlm_recycle_grant_check (the DLM's EX is no lower than the cached
 * one), the previous life's staged image in the cluster buffer reads as staged
 * under the live tenure, and a write of another slot publishes it over what a
 * peer wrote while it held the number.  The release marks the inode
 * (MXFS_IF_NOINO_RELEASED, always, counted in noino_release_marked); 1 makes the
 * recycle that finds the mark end that tenure (epoch moves, i_dlm_stale, mode
 * lowered to what the DLM records, NL when the record cannot be read), 0 is the
 * same-build control, which keeps it as before.  recycle_released_reset and
 * recycle_released_kept count the marked recycles by setting;
 * logwr_relmark_written counts slots a cluster write carried with bytes copied
 * in before such a recycle (P-LOGWR-RELMARK-WRITTEN), in both settings; with
 * dino_clobber_check on, logwr_relmark_regressed counts those written while
 * the platter held a newer image of the slot.
 */
int mxfs_noino_release_mark_honor = 1;
module_param_named(noino_release_mark_honor, mxfs_noino_release_mark_honor, int, 0644);
MODULE_PARM_DESC(noino_release_mark_honor,
		 "a recycle of an in-core inode whose grant a no-inode release unlocked ends that tenure before serving it (1=end it default, 0=control)");
atomic_t mxfs_noino_release_marked = ATOMIC_INIT(0);
module_param_cb(noino_release_marked, &mxfs_dbg_atomic_param_ops,
		&mxfs_noino_release_marked, 0644);
MODULE_PARM_DESC(noino_release_marked,
		 "count of no-inode releases that marked an in-core inode still caching the grant they unlocked (write resets)");
atomic_t mxfs_recycle_released_reset = ATOMIC_INIT(0);
module_param_cb(recycle_released_reset, &mxfs_dbg_atomic_param_ops,
		&mxfs_recycle_released_reset, 0644);
MODULE_PARM_DESC(recycle_released_reset,
		 "count of recycles that found a no-inode release's mark and ended the cached tenure (P-RECYCLE-RELEASED-RESET) (write resets)");
atomic_t mxfs_recycle_released_kept = ATOMIC_INIT(0);
module_param_cb(recycle_released_kept, &mxfs_dbg_atomic_param_ops,
		&mxfs_recycle_released_kept, 0644);
MODULE_PARM_DESC(recycle_released_kept,
		 "count of recycles that found a no-inode release's mark and kept the cached tenure (noino_release_mark_honor 0, P-RECYCLE-RELEASED-KEEP) (write resets)");
atomic_t mxfs_logwr_relmark_written = ATOMIC_INIT(0);
module_param_cb(logwr_relmark_written, &mxfs_dbg_atomic_param_ops,
		&mxfs_logwr_relmark_written, 0644);
MODULE_PARM_DESC(logwr_relmark_written,
		 "count of logged slots a cluster write carried with bytes copied in before a recycle that found a no-inode release's mark (P-LOGWR-RELMARK-WRITTEN) (write resets)");
atomic_t mxfs_logwr_relmark_regressed = ATOMIC_INIT(0);
module_param_cb(logwr_relmark_regressed, &mxfs_dbg_atomic_param_ops,
		&mxfs_logwr_relmark_regressed, 0644);
MODULE_PARM_DESC(logwr_relmark_regressed,
		 "count of those slots written while the platter held a newer image (dino_clobber_check) (write resets)");

/*
 * D-FREED-IMAGE-ADOPT-KEEPS-DEAD-LIFE-CORE-FIELDS-REGRESSES-FREE-DINODE, H-FA1:
 * xfs_inode_from_disk takes only the generation and mode of a free dinode,
 * because upstream reads one only into a fresh in-core inode.  A reload that
 * adopts a peer's free image reads it into a live one, which keeps the freed
 * life's link count, change count, size, block count and flags, and the slot's
 * next copy-in writes them over the peer's free (wtc2, wrf2: disk nlink 0 ->
 * mem nlink 1, five change counts behind).  1 takes those fields from the
 * free dinode, as from_disk takes them from a live one; 0 is the same-build
 * control, which keeps them.  free_adopt_core_diff counts the free adopts
 * whose core differed from the dinode, in both settings (P-FREE-ADOPT-CORE).
 */
int mxfs_free_adopt_core = 1;
module_param_named(free_adopt_core, mxfs_free_adopt_core, int, 0644);
MODULE_PARM_DESC(free_adopt_core,
		 "a reload that adopts a free dinode takes its core fields (link count, change count, size, blocks, flags) from it (1=default, 0=control keeps the freed life's)");
atomic_t mxfs_free_adopt_core_diff = ATOMIC_INIT(0);
module_param_cb(free_adopt_core_diff, &mxfs_dbg_atomic_param_ops,
		&mxfs_free_adopt_core_diff, 0644);
MODULE_PARM_DESC(free_adopt_core_diff,
		 "count of free-dinode adopts whose in-core core differed from the dinode (P-FREE-ADOPT-CORE), taken or not (write resets)");

/*
 * — D-FOREIGN-REPLAY-UNGATED-IMAGES containment,
 * review-ruled stop-ship.  Live foreign-slice replay applied BUFFER (and dquot/
 * quotaoff/icreate) image records gated only by the upstream on-disk-LSN
 * compare — but per-node log slices have independent LSN cycle/block
 * numbering, so a cross-slice XFS_LSN_CMP is meaningless (the sb-LSN check in
 * xlog_recover already skips itself for exactly this reason).  False-APPLY
 * silently reverts survivor-written dir blocks / AG state; false-SKIP drops
 * the dead node's fsync-acked change.  Until log records carry authority
 * tokens (resource id + grant incarnation + tenure), the only sound verdict
 * for an untagged non-inode image is SKIP: inode records keep their
 * node-independent di_changecount gate and continue to replay.
 * 1 = legacy apply (unsafe, same-build A/B control only).
 */
int mxfs_foreign_replay_untagged_apply;
EXPORT_SYMBOL(mxfs_foreign_replay_untagged_apply);
module_param_named(foreign_replay_untagged_apply, mxfs_foreign_replay_untagged_apply, int, 0644);
MODULE_PARM_DESC(foreign_replay_untagged_apply,
                 "apply untagged buf/dquot/icreate images during live "
                 "foreign-slice replay (0=skip-safe default, 1=legacy "
                 "cross-slice-LSN apply -- A/B control only)");

/*
 * (D-529 verification): fault-injection knob for the whole-txn
 * verdict.  When >0, mxfs_classify_untrusted_txn treats any untrusted
 * transaction with MORE than this many items as if a later-batch item
 * were unauthorized (forces the ATOMIC-SKIP arm, P-DBG-FR-TAINT-INJECT).
 * Under the pre-D-529 per-batch classifier this exact condition produced
 * ADMIT-batch-1 + SKIP-batch-2 = a partial apply; with the whole-txn
 * verdict the entire transaction must skip and ZERO of its images may
 * reach the home platter.  Default 0 = off.  Test only.
 */
int mxfs_dbg_fr_taint_items_over;
EXPORT_SYMBOL(mxfs_dbg_fr_taint_items_over);
module_param_named(dbg_fr_taint_items_over, mxfs_dbg_fr_taint_items_over, int, 0644);
MODULE_PARM_DESC(dbg_fr_taint_items_over,
                 "D-529 fault injection: force ATOMIC-SKIP for untrusted "
                 "transactions with more than N items (0=off, test only)");

/*
 * companion (mount-time arm of the same defect): a PASS-2 (fresh)
 * disklock claim inherits a log slice whose dirty records belong to an
 * already-recovered or foreign incarnation; xfs_log_mount marks that
 * recovery ADOPTED and the same untagged-image/intent suppression applies
 * (inode records keep the di_changecount gate).  A PASS-1 own-stamp reclaim
 * (nobody replayed us) always performs full recovery.  1 = legacy full
 * replay of adopted slices (unsafe, A/B control only).
 */
int mxfs_adopted_slice_full_replay;
EXPORT_SYMBOL(mxfs_adopted_slice_full_replay);
module_param_named(adopted_slice_full_replay, mxfs_adopted_slice_full_replay, int, 0644);
MODULE_PARM_DESC(adopted_slice_full_replay,
                 "fully replay an ADOPTED (fresh-claim) log slice at mount "
                 "(0=suppress untagged images+intents default, 1=legacy full "
                 "replay -- A/B control only)");

/*
 * 0.85.0 (D-FOREIGN-SLICE-INTENTS-ABANDONED): the verdict flip.  1 (default)
 * = a dead node's slice whose only open intents are admitted EFIs replays
 * successfully and its extents are completed by the custodian; 0 = the
 * pre-0.85.0 terminal refusal (INTENTS_UNDISCHARGED), the A/B control of
 * tests/d_intents_2tcp_open_efi.sh.  Read at the census verdict only.
 */
int mxfs_obl_complete_enable = 1;
EXPORT_SYMBOL(mxfs_obl_complete_enable);
module_param_named(obl_complete_enable, mxfs_obl_complete_enable, int, 0644);
MODULE_PARM_DESC(obl_complete_enable,
                 "complete a dead peer's open EFI obligations on the TCP "
                 "transport (1=default, 0=terminal refusal -- A/B control only)");

/*
 * (#1 D-FOREIGN-REPLAY-UNGATED-IMAGES, ruling): recovery-
 * time foreign-replay token enforcement.  Turns the shadow evaluator's
 * whole-transaction verdict into an APPLY decision for fully-tokenized
 * victim transactions during elected foreign-slice recovery.
 *
 * SEPARATE from replay_gate_enforce by design: that knob arms the live
 * release-certificate gate and fails closed on the F1/F3/F4 release
 * barriers, which are prerequisites of trusting the release predicate on
 * the LIVE path — not of the recovery-time token gate ruled here.  This
 * setter fails closed on the ruling's own set-time predicates:
 *   - F2 domain admission: under fua_disable=1 the tenure-boundary
 *     flush_epoch is a no-op, so the manifest hold/epoch state a token is
 *     checked against may survive a target write-cache loss that dropped
 *     the home writes it certifies.  Enforcement then requires the
 *     operator's explicit target_cache_protected=1 declaration — never
 *     inferred from fua_disable (/rulings).
 *   - release_proof_enforce=1: with the deferral OFF a failed completion
 *     proof does not block the release CAS, so a manifest slot can read
 *     released without the covering flush — the token gate would then
 *     credit "not_held" verdicts the platter does not back.
 * Per-mount predicates (proto_admitted, FENCED recovery descriptor) are
 * enforced at use time in xfs_log_recover.c, which also re-checks the
 * domain per replay because these params stay runtime-writable.
 */
/* (design-consult ruling, 0.54.0): DEFAULT 1.  The shipped default 0 was a
 * measured data-unavailability defect on the plain crash path (
 * ordinary death -> POLICY-REFUSED -> AG quarantine -> survivor ESTALE).
 * The durability domain that makes the gate sound is validated at mount
 * time (mxfs_durability_domain_admit, pal/linux/xfs_super.c); the setter
 * below still fails closed for runtime re-arming. */
int mxfs_foreign_replay_token_enforce = 1;
EXPORT_SYMBOL(mxfs_foreign_replay_token_enforce);
DEFINE_SHOW_ATTRIBUTE(mxfs_recovery_blocked);
DEFINE_SHOW_ATTRIBUTE(mxfs_inode_authority);

static const struct file_operations mxfs_caw_pw_selftest_fops = {
	.owner	= THIS_MODULE,
	.open	= simple_open,
	.write	= mxfs_caw_pw_selftest_write,
};

static const struct file_operations mxfs_caw_samenode_selftest_fops = {
	.owner	= THIS_MODULE,
	.open	= simple_open,
	.write	= mxfs_caw_samenode_selftest_write,
};

static const struct file_operations mxfs_inject_unheld_agmeta_dirty_fops = {
	.owner	= THIS_MODULE,
	.open	= simple_open,
	.write	= mxfs_inject_unheld_agmeta_dirty_write,
};
module_param_cb(dbg_iflush_pause_n, &mxfs_dbg_atomic_param_ops,
		&mxfs_dbg_iflush_pause_n, 0644);
MODULE_PARM_DESC(dbg_iflush_pause_n,
		 "TEST ONLY: cluster writes held by dbg_iflush_pause_ino (write resets)");
module_param_cb(dbg_ail_push_n, &mxfs_dbg_atomic_param_ops,
		&mxfs_dbg_ail_push_n, 0644);
MODULE_PARM_DESC(dbg_ail_push_n,
		 "TEST ONLY: AIL pushes requested through debugfs ail_push (write resets)");

static const struct file_operations mxfs_dbg_ail_push_fops = {
	.owner	= THIS_MODULE,
	.open	= simple_open,
	.write	= mxfs_dbg_ail_push_write,
};
DEFINE_SHOW_ATTRIBUTE(mxfs_ailpin_stats);
DEFINE_SHOW_ATTRIBUTE(mxfs_acquire_degraded);

static const struct file_operations mxfs_alloc_witness_fops = {
	.owner		= THIS_MODULE,
	.open		= mxfs_alloc_witness_open,
	.read		= seq_read,
	.write		= mxfs_alloc_witness_write,
	.llseek		= seq_lseek,
	.release	= single_release,
};

static const struct file_operations mxfs_alloc_witness_chunk_fops = {
	.owner		= THIS_MODULE,
	.open		= mxfs_alloc_witness_chunk_open,
	.read		= seq_read,
	.write		= mxfs_alloc_witness_chunk_write,
	.llseek		= seq_lseek,
	.release	= single_release,
};

static const struct file_operations mxfs_dbg_lu_reset_admit_fops = {
	.owner		= THIS_MODULE,
	.open		= simple_open,
	.write		= mxfs_dbg_lu_reset_admit_write,
	.llseek		= noop_llseek,
};

static const struct file_operations mxfs_dbg_lu_reset_barrier_fops = {
	.owner		= THIS_MODULE,
	.open		= simple_open,
	.write		= mxfs_dbg_lu_reset_barrier_write,
	.llseek		= noop_llseek,
};

static const struct file_operations mxfs_dbg_lu_reset_fence_fops = {
	.owner		= THIS_MODULE,
	.open		= simple_open,
	.write		= mxfs_dbg_lu_reset_fence_write,
	.llseek		= noop_llseek,
};

void
mxfs_dlm_cache_init(
	struct xfs_mount	*mp)
{
	if (!mp->m_mxfs_dlm)
		return;

	mxfs_v5_dlm_set_fence_notify(mp->m_mxfs_dlm,
				     mxfs_dlm_fence_notify, mp);

	if (mp->m_debugfs) {
		debugfs_create_file("recovery_blocked", 0400, mp->m_debugfs, mp,
				    &mxfs_recovery_blocked_fops);
		debugfs_create_file("inode_authority", 0400, mp->m_debugfs, mp,
				    &mxfs_inode_authority_fops);
		/* removed EARLY in put_super (before m_mxfs_dlm is
		 * NULLed) — see the m_mxfs_pwtest_dentry field comment. */
		mp->m_mxfs_pwtest_dentry = debugfs_create_file(
				    "caw_pw_selftest", 0200, mp->m_debugfs, mp,
				    &mxfs_caw_pw_selftest_fops);
		mp->m_mxfs_samenode_dentry = debugfs_create_file(
				    "caw_samenode_selftest", 0200, mp->m_debugfs,
				    mp, &mxfs_caw_samenode_selftest_fops);
		/* D-0487 verification injector (see the write handler) */
		debugfs_create_file("inject_unheld_agmeta_dirty", 0200,
				    mp->m_debugfs, mp,
				    &mxfs_inject_unheld_agmeta_dirty_fops);
		/* 0.70.2: the refusal retirement-age census */
		debugfs_create_file("ailpin_stats", 0400, mp->m_debugfs, mp,
				    &mxfs_ailpin_stats_fops);
		/* 0.83.0: remote lock waits the master has stopped confirming */
		debugfs_create_file("acquire_degraded", 0400, mp->m_debugfs, mp,
				    &mxfs_acquire_degraded_fops);
		/* 0.84.18, test only: kick xfsaild (D-0963 platter-lag harness) */
		debugfs_create_file("ail_push", 0200, mp->m_debugfs, mp,
				    &mxfs_dbg_ail_push_fops);
		/* 0.89.9: the allocation-coverage witness (read: per-AG
		 * transition counts; write: clear them) */
		debugfs_create_file("alloc_witness", 0600, mp->m_debugfs, mp,
				    &mxfs_alloc_witness_fops);
		/* 0.89.10: the inobt record covering a written inode number */
		debugfs_create_file("alloc_witness_chunk", 0600, mp->m_debugfs,
				    mp, &mxfs_alloc_witness_chunk_fops);
		/* 0.89.31: the LU-reset admission gate's verdict, issuing
		 * nothing (see the write handler) */
		debugfs_create_file("lu_reset_admit", 0200, mp->m_debugfs, mp,
				    &mxfs_dbg_lu_reset_admit_fops);
		debugfs_create_file("lu_reset_barrier", 0200, mp->m_debugfs, mp,
				    &mxfs_dbg_lu_reset_barrier_fops);
		debugfs_create_file("lu_reset_fence", 0200, mp->m_debugfs, mp,
				    &mxfs_dbg_lu_reset_fence_fops);
	}

	/* v0.5.0: foreign-slice replay of dead peers (elected survivor) */
	INIT_WORK(&mp->m_mxfs_foreign_replay_work,
		  mxfs_dlm_foreign_replay_work_fn);
	/* the reap duty's re-drive queues it only from here on (mxfs_freplay_redrive) */
	smp_store_release(&mp->m_mxfs_freplay_ready, true);
	/*
	 * 0.85.1: the dead/torn slot bitmaps are NOT zeroed here.  This runs
	 * after xfs_mountfs, and the mount recovery barrier inside it has
	 * already written them: an OPEN obligation case met in the barrier
	 * (P-OBL-BARRIER-OPEN) leaves its dead bit set and the REAPF_FREPLAY
	 * duty armed so the post-mount worker completes it.  Measured s614b
	 * (tests/evidence/20260913T042107Z_intents2tcp_s614b, dmesg_test1.txt):
	 * the zeroing here emptied the set, the reap worker's replay duty saw
	 * nothing outstanding and cleared itself, the orphan sweep ran with
	 * dead_slots=0x0 into the case's frozen AG and timed out twice
	 * (P-OBLF-AG-TIMEOUT), and the engine never started.  The mount is
	 * allocated zeroed, so the first writer is the barrier, never this.
	 */
	mxfs_v5_dlm_set_dead_node_notify(mp->m_mxfs_dlm,
					 mxfs_dlm_dead_node_notify, mp);
	/* (#92): clean-release latch unwind — see the notify body. */
	mxfs_v5_dlm_set_clean_depart_notify(mp->m_mxfs_dlm,
					    mxfs_dlm_clean_depart_notify, mp);

	/* DLM-stuck escalation — see mxfs_dlm_stuck_work_fn.  Same
	 * lifecycle as foreign_replay_work: INIT'd here iff m_mxfs_dlm was
	 * set, canceled after mxfs_v5_dlm_shutdown on every path past this
	 * point. */
	INIT_WORK(&mp->m_mxfs_dlm_stuck_work, mxfs_dlm_stuck_work_fn);
	mxfs_v5_dlm_set_dlm_stuck_notify(mp->m_mxfs_dlm,
					 mxfs_dlm_stuck_notify, mp);
	/* D-0487: the pinned-item response, same lifecycle as stuck_work */
	INIT_WORK(&mp->m_mxfs_ailpin_work, mxfs_ailpin_work_fn);
	atomic_set(&mp->m_mxfs_ailpin_fired, 0);
	atomic64_set(&mp->m_mxfs_ailpin_refused_n, 0);
	atomic64_set(&mp->m_mxfs_ailpin_clear_n, 0);
	atomic64_set(&mp->m_mxfs_ailpin_clear_sum_ms, 0);
	atomic64_set(&mp->m_mxfs_ailpin_clear_slow_n, 0);
	atomic64_set(&mp->m_mxfs_ailpin_clear_shutdown_n, 0);
	atomic_set(&mp->m_mxfs_ailpin_clear_max_ms, 0);

	mxfs_v5_dlm_set_bast_notify(mp->m_mxfs_dlm,
				     mxfs_dlm_bast_notify, mp);

	mxfs_v5_dlm_set_ag_bast_notify(mp->m_mxfs_dlm,
					 mxfs_dlm_ag_bast_notify, mp);

	/* ICLUSTER (Phase 1 core): callback registered but no ICLUSTER
	 * resource is ever acquired until the call-site routing lands
	 * (mxfs.icluster_dlm stays 0) — see DLM_PLAN.md.  Next session:
	 * fan-out inside the handler + mxfs_iclus_purge_all at teardown. */
	mxfs_v5_dlm_set_iclus_bast_notify(mp->m_mxfs_dlm,
					  mxfs_iclus_bast_notify, mp);

	mxfs_v5_dlm_set_peer_joined_notify(mp->m_mxfs_dlm,
					     mxfs_dlm_join_prepare,
					     mxfs_dlm_join_commit, mp);

	/*
	 * register the inode-eviction-ring consumer (design review Part 1).
	 * The disklock heartbeat monitor invokes this for each inode a peer
	 * reports freeing, so we can invalidate a stale NL-cached copy.
	 */
	mxfs_v5_dlm_set_evict_cb(mp->m_mxfs_dlm,
				   mxfs_dlm_evict_inode_cb, mp);

	/*
	 * (D-513): terminal recovery-refusal consumer.  The disklock
	 * monitor fires this once per imported (victim_epoch, publish_seq)
	 * outcome record so every survivor folds the refused victim domain
	 * into its quarantine map instead of timing out into shutdown.
	 */
	/*
	 * (design-consult ruling Q3): open the admission transaction BEFORE
	 * the consumer can fire.  Everything imported from here until
	 * mxfs_dlm_admission_commit() runs belongs to a mount that has not
	 * been admitted yet and can still be refused.
	 */
	spin_lock(&mp->m_mxfs_quar_lock);
	mp->m_mxfs_quar_admitting = true;
	spin_unlock(&mp->m_mxfs_quar_lock);

	mxfs_v5_dlm_set_quarantine_cb(mp->m_mxfs_dlm,
				      mxfs_dlm_quarantine_cb, mp);
	/* 0.85.0: the obligation freeze observer + its registration scan, so
	 * an OPEN case another node published is frozen here before this
	 * mount's first allocation. */
	mxfs_v5_dlm_set_obl_cb(mp->m_mxfs_dlm, mxfs_dlm_obl_cb, mp);

	/*
	 * (ruling item B): the AG-domain judgement the
	 * survivor-side out-of-closure scrub asks before force-revoking a
	 * quarantined victim's blocking CAW state.  Registered here because
	 * only this layer knows the inode->AG mapping (invariant 4).
	 */
	mxfs_v5_dlm_set_closure_classify_fn(mp->m_mxfs_dlm,
					    mxfs_dlm_closure_classify_cb, mp);

	/*
	 * (ruling part 1, second half): so that a blocking
	 * acquire the quarantine OVERTAKES is cancelled with the same error a
	 * fresh one gets, instead of waiting out the DLM timeout against a
	 * grant that can never be released.
	 */
	mxfs_v5_dlm_set_quar_covers_fn(mp->m_mxfs_dlm,
				       mxfs_dlm_quar_covers_cb, mp);

	/*
	 * (ruling item 4): the monitor only delivers outcomes
	 * it sees AFTER this registration — a record already on the platter
	 * (published before this mount, or already dedup'd by our own
	 * monitor's earlier pass) would never import and this node would time
	 * out into the incident-513 suicide.  Synchronously scan every slot's
	 * descriptor NOW, before any filesystem ops are exposed, and replay
	 * existing terminal verdicts into the quarantine map.
	 */
	mxfs_v5_dlm_recovery_scan_outcomes(mp->m_mxfs_dlm);

	/* Reset stats */
	atomic64_set(&mxfs_dlm_stat_cache_hit, 0);
	atomic64_set(&mxfs_dlm_stat_cache_miss, 0);
	atomic64_set(&mxfs_dlm_stat_bast_immediate, 0);
	atomic64_set(&mxfs_dlm_stat_bast_deferred, 0);
	atomic64_set(&mxfs_dlm_stat_bast_no_inode, 0);
	atomic64_set(&mxfs_dlm_stat_ag_acquire, 0);
	atomic64_set(&mxfs_dlm_stat_ag_nested, 0);
	atomic64_set(&mxfs_dlm_stat_ag_release, 0);
	mxfs_dlm_stat_last_report = 0;

	mxfs_pal_log(MXFS_LOG_DEBUG, "mxfs: DLM lock caching enabled");
}

/*
 * (design-consult ruling Q3) — THE ADMISSION TRANSITION.
 *
 * The mount admission barrier gates on m_mxfs_quar_fswide twice, but both
 * gates run inside xfs_mountfs, and the registration-time outcome scan runs
 * ~0.5 s LATER (measured) from mxfs_dlm_cache_init.  So an FSWIDE quarantine
 * that only the scan discovers — precisely the late-mount case the scan was
 * built for — was never gated at all: measured, mount rc=0 with
 * fswide=1 imported, a zombie whose every operation fails with EIO.
 *
 * This closes the window at the other end.  It runs after every synchronous
 * registration-phase import has happened, flips ADMITTING -> ADMITTED under
 * the import lock so no import can slip between the test and the decision,
 * and refuses the mount if the filesystem is known unusable.  A quarantine
 * that arrives after this point meets an admitted mount and is handled the
 * only way it still can be: runtime EIO.
 *
 * Returns 0 to admit, -EIO to refuse.  On refusal the caller must unwind
 * through the post-cache_init path, which unregisters the DLM consumer and
 * drains the workers before the mount is freed.
 */
int
mxfs_dlm_admission_commit(
	struct xfs_mount	*mp)
{
	bool			fswide;
	uint64_t		ag_mask;

	if (!mp)
		return 0;

	spin_lock(&mp->m_mxfs_quar_lock);
	fswide = mp->m_mxfs_quar_fswide;
	ag_mask = mp->m_mxfs_quar_ag_mask;
	mp->m_mxfs_quar_admitting = false;
	spin_unlock(&mp->m_mxfs_quar_lock);

	if (fswide) {
		xfs_alert(mp,
			"MXFS mount ABORTED at admission: a terminal recovery "
			"refusal quarantines the WHOLE filesystem (found "
			"during DLM registration, after the recovery "
			"barrier) -- every operation this mount could admit "
			"would fail with EIO.  Repair the refused slice "
			"targets, clear the outcome record, and remount");
		return -EIO;
	}
	if (ag_mask)
		xfs_alert(mp,
			"MXFS mount ADMITTED with AG mask 0x%llx quarantined "
			"by a terminal recovery refusal -- operations touching "
			"those AGs fail with EIO until operator repair",
			(unsigned long long)ag_mask);
	return 0;
}
