// SPDX-License-Identifier: GPL-2.0
/*
 * MXFS -- BASTs for inodes not in core
 */
#define MXFS_TU_ID 18	/* igrab/iput call-site file id */
#include "xfs_mxfs_dlm_priv.h"

static int mxfs_noino_agwait_inflight( struct xfs_mount *mp, xfs_agnumber_t agno);

static DEFINE_HASHTABLE(mxfs_noino_inflight_ht, 8);
static DEFINE_SPINLOCK(mxfs_noino_inflight_lock);

/*
 * Returns true if (mp,ino) was newly inserted (caller should queue/perform the
 * release); false if a release for this inode is already in flight (drop this
 * BAST — an in-flight work will handle the current slot state, or the peer
 * re-BASTs after it completes).  On alloc failure returns true (degrade to
 * no-dedup for this BAST rather than drop it) with *tracked false: the caller
 * then counts the release in mxfs_noino_untracked_inflight until it ends, so
 * mxfs_noino_release_may_be_inflight still answers for it.
 */
bool
mxfs_noino_inflight_try_add(struct xfs_mount *mp, uint64_t ino, bool *tracked)
{
	struct mxfs_noino_inflight *e;
	unsigned long flags;

	*tracked = false;
	spin_lock_irqsave(&mxfs_noino_inflight_lock, flags);
	hash_for_each_possible(mxfs_noino_inflight_ht, e, hnode, ino) {
		if (e->mp == mp && e->ino == ino) {
			spin_unlock_irqrestore(&mxfs_noino_inflight_lock, flags);
			return false;
		}
	}
	e = kmalloc(sizeof(*e), GFP_ATOMIC);
	if (e) {
		e->mp = mp;
		e->ino = ino;
		e->add_ns = ktime_get_ns();
		e->start_ns = 0;
		e->phase = MXFS_NOINO_PH_QUEUED;
		e->fence_try = -1;
		e->fence_target = 0;
		e->taken = false;
		hash_add(mxfs_noino_inflight_ht, &e->hnode, ino);
		*tracked = true;
	}
	spin_unlock_irqrestore(&mxfs_noino_inflight_lock, flags);
	return true;
}

/* true when a recycle had taken the removed release over
 * (mxfs_noino_inflight_take), decided in the same hold as the removal */
bool
mxfs_noino_inflight_remove(struct xfs_mount *mp, uint64_t ino)
{
	struct mxfs_noino_inflight *e;
	unsigned long flags;
	bool taken;

	spin_lock_irqsave(&mxfs_noino_inflight_lock, flags);
	hash_for_each_possible(mxfs_noino_inflight_ht, e, hnode, ino) {
		if (e->mp == mp && e->ino == ino) {
			taken = e->taken;
			hash_del(&e->hnode);
			spin_unlock_irqrestore(&mxfs_noino_inflight_lock, flags);
			kfree(e);
			return taken;
		}
	}
	spin_unlock_irqrestore(&mxfs_noino_inflight_lock, flags);
	return false;
}

/* is a no-inode async release in flight for (mp,ino)?
 * Used by the slow-path acquire to serialize a FRESH local tenure behind
 * a pending release of the PRIOR tenure — otherwise the release's final
 * CAS strips the fresh grant's slot bit (the mkdir-storm double-EX root;
 * see mxfs_noino_bast_work.rel_gen comment). */
bool
mxfs_noino_inflight_contains(struct xfs_mount *mp, uint64_t ino)
{
	struct mxfs_noino_inflight *e;
	unsigned long flags;
	bool found = false;

	spin_lock_irqsave(&mxfs_noino_inflight_lock, flags);
	hash_for_each_possible(mxfs_noino_inflight_ht, e, hnode, ino) {
		if (e->mp == mp && e->ino == ino) {
			found = true;
			break;
		}
	}
	spin_unlock_irqrestore(&mxfs_noino_inflight_lock, flags);
	return found;
}

/* the release's progress, read by mxfs_noino_wait_report; try < 0 keeps the
 * fence fields */
void
mxfs_noino_inflight_note(
	struct xfs_mount	*mp,
	uint64_t		ino,
	int			phase,
	int			try,
	s64			target)
{
	struct mxfs_noino_inflight *e;
	unsigned long flags;

	spin_lock_irqsave(&mxfs_noino_inflight_lock, flags);
	hash_for_each_possible(mxfs_noino_inflight_ht, e, hnode, ino) {
		if (e->mp == mp && e->ino == ino) {
			if (!e->start_ns)
				e->start_ns = ktime_get_ns();
			e->phase = phase;
			if (try >= 0) {
				e->fence_try = try;
				e->fence_target = target;
			}
			break;
		}
	}
	spin_unlock_irqrestore(&mxfs_noino_inflight_lock, flags);
}

/*
 * D-RECYCLE-RESET-UNDER-NOINO-STRANDS-COMMITTED-DIR-CHANGE-WEDGE-SHUTDOWN: the
 * two halves of a take-over, each decided under the table lock so that exactly
 * one of them wins.  A recycle that cannot wait for the release (a create, or
 * a caller whose transaction holds items) and meets a corpse still owing the
 * platter a change marks the release taken and keeps the corpse's grant
 * (mxfs_dlm_recycle_grant_check); that succeeds only while the release has not
 * begun its unlock.  The release, about to unlock, refuses to when it finds the
 * mark (mxfs_dlm_noino_bast_work_fn) and re-drives its BAST through the
 * lifecycle park, which meets the recycled inode through the in-core path.
 * Once the release has begun its unlock the take-over fails and the recycle
 * resets the grant as before: by then the drain fence has written everything
 * the corpse committed, and a reclaimable corpse commits nothing new.
 */
bool
mxfs_noino_inflight_take(struct xfs_mount *mp, uint64_t ino)
{
	struct mxfs_noino_inflight *e;
	unsigned long flags;
	bool taken = false;

	spin_lock_irqsave(&mxfs_noino_inflight_lock, flags);
	hash_for_each_possible(mxfs_noino_inflight_ht, e, hnode, ino) {
		if (e->mp == mp && e->ino == ino) {
			if (e->phase < MXFS_NOINO_PH_UNLOCK) {
				e->taken = true;
				taken = true;
			}
			break;
		}
	}
	spin_unlock_irqrestore(&mxfs_noino_inflight_lock, flags);
	return taken;
}

/* true: a recycle or an acquire took this release over (its fence stops) */
bool
mxfs_noino_inflight_is_taken(struct xfs_mount *mp, uint64_t ino)
{
	struct mxfs_noino_inflight *e;
	unsigned long flags;
	bool taken = false;

	spin_lock_irqsave(&mxfs_noino_inflight_lock, flags);
	hash_for_each_possible(mxfs_noino_inflight_ht, e, hnode, ino) {
		if (e->mp == mp && e->ino == ino) {
			taken = e->taken;
			break;
		}
	}
	spin_unlock_irqrestore(&mxfs_noino_inflight_lock, flags);
	return taken;
}

/* false: a recycle took this release over and it must not unlock */
bool
mxfs_noino_inflight_begin_unlock(struct xfs_mount *mp, uint64_t ino)
{
	struct mxfs_noino_inflight *e;
	unsigned long flags;
	bool go = true;

	spin_lock_irqsave(&mxfs_noino_inflight_lock, flags);
	hash_for_each_possible(mxfs_noino_inflight_ht, e, hnode, ino) {
		if (e->mp == mp && e->ino == ino) {
			if (e->taken)
				go = false;
			else
				e->phase = MXFS_NOINO_PH_UNLOCK;
			break;
		}
	}
	spin_unlock_irqrestore(&mxfs_noino_inflight_lock, flags);
	return go;
}

static const char *
mxfs_noino_phase_name(int phase)
{
	switch (phase) {
	case MXFS_NOINO_PH_QUEUED:	return "queued";
	case MXFS_NOINO_PH_LAND:	return "land";
	case MXFS_NOINO_PH_FENCE:	return "fence";
	case MXFS_NOINO_PH_LIVE:	return "live-check";
	case MXFS_NOINO_PH_UNLOCK:	return "unlock";
	}
	return "?";
}

/*
 * D-4NODE-SHARED-DIR-EX-HANDOFF-6S-TAIL-DOZE: a create that reused a number
 * whose no-inode release registered after the allocator took it waits behind
 * that release (xfs/xfs_mxfs_ilock.c, P-NOINO-ACQ-WAIT) and, on
 * 4/disk/caw/mpath, waited out its whole bound, 6 s of wall, every time.  On
 * tdr1 the inobt and finobt buffers of the creator's AG were written 2 ms after
 * it gave up and the release ended 1 ms after that.  H-TD1: the release's drain
 * fence cannot reach its AIL target because the AIL's oldest item is joined to
 * the waiting creator's own transaction, which holds it locked until it
 * commits.  A wait past 100 rounds reports where the release is, the AIL's
 * oldest item, and whether that item is in the waiter's transaction.
 * Detection only.
 */
void
mxfs_noino_wait_report(
	struct xfs_mount	*mp,
	uint64_t		ino,
	int			rounds,
	u64			wait_start_ns)
{
	static atomic_t		cap = ATOMIC_INIT(0);
	struct mxfs_noino_inflight *e;
	struct xfs_ail		*ailp = mp->m_ail;
	struct xfs_log_item	*lip, *tlip;
	struct xfs_trans	*tp = current->journal_info;
	unsigned long		flags;
	u64			now = ktime_get_ns();
	u64			add_ns = 0, start_ns = 0;
	int			phase = -1, ftry = -1, titems = 0;
	s64			ftarget = 0;
	xfs_lsn_t		min_lsn = 0, max_lsn;
	bool			found = false, mine = false;
	char			item[112] = "none";

	if (atomic_inc_return(&cap) > 300)
		return;
	spin_lock_irqsave(&mxfs_noino_inflight_lock, flags);
	hash_for_each_possible(mxfs_noino_inflight_ht, e, hnode, ino) {
		if (e->mp == mp && e->ino == ino) {
			found = true;
			add_ns = e->add_ns;
			start_ns = e->start_ns;
			phase = e->phase;
			ftry = e->fence_try;
			ftarget = e->fence_target;
			break;
		}
	}
	spin_unlock_irqrestore(&mxfs_noino_inflight_lock, flags);

	if (tp)
		list_for_each_entry(tlip, &tp->t_items, li_trans)
			titems++;
	spin_lock(&ailp->ail_lock);
	lip = xfs_ail_min(ailp);
	if (lip) {
		min_lsn = lip->li_lsn;
		if (tp) {
			list_for_each_entry(tlip, &tp->t_items, li_trans) {
				if (tlip == lip) {
					mine = true;
					break;
				}
			}
		}
		if (lip->li_type == XFS_LI_BUF) {
			struct xfs_buf *bp = container_of(lip,
					struct xfs_buf_log_item, bli_item)->bli_buf;

			snprintf(item, sizeof(item),
				 "BUF daddr=%lld len=%u locked=%d ops=%s liflags=0x%lx",
				 (long long)bp->b_maps[0].bm_bn, bp->b_length,
				 xfs_buf_islocked(bp) ? 1 : 0,
				 bp->b_ops ? bp->b_ops->name : "none",
				 lip->li_flags);
		} else if (lip->li_type == XFS_LI_INODE) {
			struct xfs_inode *tip = container_of(lip,
					struct xfs_inode_log_item, ili_item)->ili_inode;

			snprintf(item, sizeof(item),
				 "INODE ino=%llu ilocked=%d liflags=0x%lx",
				 tip ? (unsigned long long)tip->i_ino : 0ULL,
				 tip ? (rwsem_is_locked(&tip->i_lock) ? 1 : 0) : -1,
				 lip->li_flags);
		} else {
			snprintf(item, sizeof(item),
				 "type=0x%x intent=%d liflags=0x%lx",
				 lip->li_type, xlog_item_is_intent(lip) ? 1 : 0,
				 lip->li_flags);
		}
	}
	spin_unlock(&ailp->ail_lock);
	max_lsn = xfs_ail_max_lsn(ailp);
	pr_warn("mxfs: P-NOINO-WAIT-REPORT ino=%llu rounds=%d wall_ms=%llu inflight=%d phase=%s reg_ms=%llu queued_ms=%llu fence_try=%d fence_target=0x%llx ail_min=0x%llx ail_max=0x%llx drained=0x%llx min_item=[%s] min_in_waiter_trans=%d waiter_trans=%d waiter_trans_items=%d comm=%s -- an acquire waiting behind a pending no-inode release of its number\n",
		(unsigned long long)ino, rounds,
		(unsigned long long)((now - wait_start_ns) / NSEC_PER_MSEC),
		found ? 1 : 0, found ? mxfs_noino_phase_name(phase) : "gone",
		found ? (unsigned long long)((now - add_ns) / NSEC_PER_MSEC) : 0ULL,
		found ? (unsigned long long)(((start_ns ? start_ns : now) -
					      add_ns) / NSEC_PER_MSEC) : 0ULL,
		ftry, (unsigned long long)ftarget,
		(unsigned long long)min_lsn, (unsigned long long)max_lsn,
		(unsigned long long)atomic64_read(&mp->m_mxfs_noino_drained_lsn),
		item, mine ? 1 : 0, tp ? 1 : 0, titems, current->comm);
}

/*
 * D-FREED-INODE-HOME-NEVER-PUBLISHED-LIVE-CORE-AFTER-CLEAN-UNMOUNT, H-F7: a
 * BAST that meets this node's reclaimable corpse of an inode is served by the
 * no-inode release below, and the corpse keeps the grant it caches (its NL
 * store runs at reclaim, not at evict).  The release unlocks that grant after
 * its drain fence, and the fence covers only what this node committed before
 * the fence's last log force.  A lookup that recycled the corpse in between
 * kept the cached grant -- the DLM still recorded it -- and wrote through it;
 * those changes rode the unlock to the peer without reaching the platter, and
 * were written home later over whatever the peer had done since (kdf2: 88
 * touches through the kept grant during a 5.3 s fence, the last one undrained
 * at the unlock and written home 46 ms after the peer freed the inode -- an
 * inobt-free inode with a live core after a clean unmount).
 *
 * noino_recycle_guard (default 1) closes both sides of that window: the
 * recycle resets a cached grant while a release of the number may be in
 * flight, so the recycled inode acquires for real, behind the release
 * (mxfs_dlm_recycle_grant_check); and a BAST whose corpse entered a recycle
 * before the release was registered is re-driven through the lifecycle park,
 * which meets the recycled inode through the in-core path
 * (__mxfs_dlm_bast_notify).  0 is the same-build control: the recycle keeps
 * the grant, as before.
 */
int mxfs_noino_recycle_guard = 1;
module_param_named(noino_recycle_guard, mxfs_noino_recycle_guard, int, 0644);
MODULE_PARM_DESC(noino_recycle_guard,
	"a recycle never serves a cached grant that an in-flight no-inode release of the same inode will unlock (1=default; 0=keep it, the same-build control)");

/* releases running without an in-flight table entry (its allocation failed,
 * or the inline fallback): while any is, every number counts as in flight */
atomic_t mxfs_noino_untracked_inflight = ATOMIC_INIT(0);

bool
mxfs_noino_release_may_be_inflight(struct xfs_mount *mp, uint64_t ino)
{
	if (!READ_ONCE(mxfs_noino_bast_dedup))
		return true;	/* nothing is tracked */
	if (atomic_read(&mxfs_noino_untracked_inflight) > 0)
		return true;
	return mxfs_noino_inflight_contains(mp, ino);
}

/*
 * D-RECYCLE-RESET-UNDER-NOINO-STRANDS-COMMITTED-DIR-CHANGE-WEDGE-SHUTDOWN: the
 * recycle's reset (mxfs_dlm_recycle_grant_check) is right only for a corpse
 * that owes the platter nothing.  The release's drain fence lands what this
 * node committed through the AIL, and the write paths refuse an inode whose
 * cached grant is NL -- xfs_iflush skips it (P119-NONEX-FLUSH-SKIP) and the
 * cluster write drops a logged directory slot (P56-NL-LOGGED-DIR-SKIP) -- while
 * its log item still completes and leaves the AIL.  A dirty corpse reset under
 * the release therefore let the fence pass with its change never written, and
 * the release unlocked over it.  Traced in fxdp2 (2/net/mesh/direct, test30):
 * an rm shrank directory 16777345 to shortform (changecount 14774, home 14768)
 * and drop_caches left it reclaimable and dirty; a peer's BAST was served by
 * this release; 3 ms later the rm's next lookup recycled the corpse and reset
 * it; the aild skipped it, the unlock went through and the peer read the
 * block-form home; and test30, holding a later PR with the change still in
 * core and no way to write it, could not release (P228-RELBAR-DEFER) and shut
 * down 60 s later (P-INODE-WEDGE).
 *
 * noino_recycle_dirty_wait (default 1): such a corpse is not recycled while the
 * release is in flight.  xfs_iget_cache_hit returns -EAGAIN and xfs_iget
 * retries, so the corpse keeps its cached grant and the fence writes the
 * change under it; the recycle that finally runs measures the grant the
 * release left behind, unsampled.  Decided under i_flags_lock in the same hold
 * that sets XFS_IRECLAIM, so it pairs with the BAST side's registration and
 * lifecycle re-check (__mxfs_dlm_bast_notify): a release registered before the
 * recycle starts is seen here, and one registered after sees XFS_IRECLAIM and
 * is re-driven through the lifecycle park instead of unlocking.  Only a release
 * the in-flight table tracks is waited for, since only its end is visible.  A
 * create, or a caller whose transaction holds items, is not made to wait: a
 * fence that has to push those buffers could not finish behind it (the shape
 * D-4NODE-SHARED-DIR-EX-HANDOFF-6S-TAIL-DOZE measured).  Such a caller takes
 * the release over instead (noino_recycle_takeover below).  0 is the same-build
 * control: the corpse is reset at once, as before.
 */
int mxfs_noino_recycle_dirty_wait = 1;
module_param_named(noino_recycle_dirty_wait, mxfs_noino_recycle_dirty_wait, int, 0644);
MODULE_PARM_DESC(noino_recycle_dirty_wait,
	"a reclaimable corpse that still owes the platter a committed change is not recycled while a no-inode release of its number is in flight (1=default; 0=its grant is reset at once, the same-build control)");

/*
 * noino_recycle_takeover (default 1, effective only with
 * noino_recycle_dirty_wait): the recycles that cannot wait -- a create
 * reusing a freed number whose free image is not on the platter yet, or a
 * caller whose transaction holds items -- would otherwise still reset a
 * corpse that owes the platter a change, under a release that then unlocks
 * over it (tdr1, 4/disk/caw/mpath: a mkdir recycled the corpse of the number
 * it had just allocated 2.3 ms after a peer's BAST registered the release
 * behind that number's inactivation).  Such a recycle takes the release over
 * (mxfs_noino_inflight_take): the release does not unlock, its BAST is
 * re-driven to the in-core path once the recycle is done, and the corpse keeps
 * the grant its change is written under.  0 is the same-build control: those
 * recycles reset the grant as before.
 */
int mxfs_noino_recycle_takeover = 1;
module_param_named(noino_recycle_takeover, mxfs_noino_recycle_takeover, int, 0644);
MODULE_PARM_DESC(noino_recycle_takeover,
	"a recycle that cannot wait for an in-flight no-inode release and meets a corpse owing the platter a change takes the release over instead of resetting the grant (1=default; 0=reset, the same-build control)");

/*
 * TEST ONLY: the recycles that cannot wait are hard to put on a dirty corpse
 * at will.  A create cannot meet one at all: the allocator hands out a number
 * only once its home reads free on the platter and refuses one whose own free
 * this node has not published (mxfs_dialloc_validate_candidate), and a freed
 * corpse takes no change after its free.  That leaves callers whose
 * transaction already holds items, such as the unlinked-list reloads of
 * xfs_iunlink, which meet a reclaimable corpse only when a peer's unlinked
 * inode shares the bucket.  dbg_recycle_nowait makes every lookup that would
 * wait recycle as such a caller instead, so the lookup reproducer
 * (tests/noino_dirty_recycle_ab.sh) drives the take-over, and its counter
 * dbg_recycle_nowait_hits says how often.  0 = off.
 */
int mxfs_dbg_recycle_nowait;
module_param_named(dbg_recycle_nowait, mxfs_dbg_recycle_nowait, int, 0644);
MODULE_PARM_DESC(dbg_recycle_nowait,
	"TEST ONLY: a recycle that would wait for an in-flight no-inode release goes on as a caller that cannot wait (0=off)");

/*
 * D-NETMESH-MPATH-SURVIVOR-NOINO-RELFENCE-WEDGE-SHUTDOWN-WHILE-PEER-FROZEN,
 * H-AT1: the take-over above covers a corpse that still caches its grant.  A
 * create also reaches the acquire with nothing cached: the allocator reserved
 * the number (a grant of its own), took it, and a peer's BAST registered a
 * no-inode release of that reservation in the 0.4 ms before the create's
 * xfs_iget recycled the corpse, whose cached mode an earlier release had
 * already lowered to NL.  The create then waited in
 * mxfs_ilock_acquire_from_dlm behind the release while its transaction held
 * the AGI it had just logged, which was the AIL's oldest item, so the
 * release's drain fence could not land it until the create committed.  On
 * 2/net/mesh/mpath (lap r131b-9) the wait ran out its 2000 rounds, the acquire
 * that followed went to a master that had just frozen, and the fence's eight
 * bounded pushes ran out first: P-NOINO-RELFENCE-WEDGE shut the survivor down.
 * The same cycle cost 6 s on 4/disk/caw/mpath
 * (D-4NODE-SHARED-DIR-EX-HANDOFF-6S-TAIL-DOZE).
 *
 * noino_acq_takeover (default 1): an acquire whose transaction holds items
 * and meets a release of its number that has not begun its unlock takes it
 * over instead of waiting.  A taken release neither unlocks nor finishes its
 * fence -- it hands nothing over, so nothing must be durable first -- and its
 * BAST is re-driven to the in-core path, which serves the peer once the
 * acquirer is done with the inode.  0 is the same-build control: the acquire
 * waits behind the release, as before.
 */
int mxfs_noino_acq_takeover = 1;
module_param_named(noino_acq_takeover, mxfs_noino_acq_takeover, int, 0644);
MODULE_PARM_DESC(noino_acq_takeover,
	"an acquire whose transaction holds items takes an in-flight no-inode release of its number over instead of waiting behind it (1=default; 0=wait, the same-build control)");

/*
 * Called by an acquire that met a release of its number in flight.  true: the
 * caller took the release over and must not wait for it.  noino_acq_meets
 * counts the callers whose transaction holds items whatever the knob, so both
 * arms of the A/B report the same reach.
 */
bool
mxfs_noino_acq_try_takeover(
	struct xfs_inode	*ip)
{
	extern atomic_t		mxfs_noino_acq_takeovers;
	extern atomic_t		mxfs_noino_acq_meets;
	static atomic_t		p_nat_n = ATOMIC_INIT(0);
	struct xfs_trans	*tp = current->journal_info;
	struct xfs_log_item	*lip;
	int			items = 0;

	if (!tp)
		return false;
	list_for_each_entry(lip, &tp->t_items, li_trans)
		items++;
	if (!items)
		return false;
	atomic_inc(&mxfs_noino_acq_meets);
	if (!READ_ONCE(mxfs_noino_acq_takeover) ||
	    !mxfs_noino_inflight_take(ip->i_mount, ip->i_ino))
		return false;
	atomic_inc(&mxfs_noino_acq_takeovers);
	if (atomic_inc_return(&p_nat_n) <= 2000)
		pr_warn("mxfs: P-NOINO-ACQ-TAKEOVER ino=%llu trans_items=%d comm=%s -- an acquire whose transaction holds items met a no-inode release of its number before its unlock; the release is taken over instead of waited for\n",
			(unsigned long long)ip->i_ino, items, current->comm);
	return true;
}

/* logged fields, a pin, or an item still in the AIL: a committed change the
 * home does not have yet (a flush in progress keeps the item in the AIL until
 * its cluster write completes) */
bool
mxfs_noino_corpse_owes_platter(
	struct xfs_inode	*ip)
{
	struct xfs_inode_log_item *iip = ip->i_itemp;

	if (xfs_ipincount(ip) > 0)
		return true;
	return iip && (READ_ONCE(iip->ili_fields) ||
		       test_bit(XFS_LI_IN_AIL, &iip->ili_item.li_flags));
}

/*
 * xfs_iget_cache_hit, IRECLAIMABLE corpse, i_flags_lock and rcu held.
 * *registered says whether a tracked release of the number was registered at
 * this moment, which is the recycle's start when it returns false: the caller
 * sets XFS_IRECLAIM in the same hold, and mxfs_dlm_recycle_grant_check needs
 * to know which side of that the release it meets registered on.
 */
bool
mxfs_noino_recycle_must_wait(
	struct xfs_inode	*ip,
	struct xfs_trans	*tp,
	int			flags,
	bool			*registered)
{
	extern atomic_t		mxfs_recycle_dirty_waits;
	extern atomic_t		mxfs_recycle_dirty_wait_rounds;
	extern atomic_t		mxfs_recycle_dirty_hazard;
	extern atomic_t		mxfs_dbg_recycle_nowait_hits;
	static atomic_t		p_rdw_n = ATOMIC_INIT(0);
	struct xfs_mount	*mp = ip->i_mount;
	struct xfs_trans	*ctp = current->journal_info;
	struct xfs_inode_log_item *iip = ip->i_itemp;

	*registered = false;
	if (!mp->m_mxfs_dlm || mxfs_v5_dlm_is_single_node(mp->m_mxfs_dlm))
		return false;
	if (!READ_ONCE(mxfs_noino_recycle_guard) ||
	    !READ_ONCE(mxfs_noino_bast_dedup))
		return false;
	*registered = mxfs_noino_inflight_contains(mp, ip->i_ino);
	if (!*registered || (flags & XFS_IGET_CREATE))
		return false;
	if ((tp && !list_empty(&tp->t_items)) ||
	    (ctp && ctp != tp && !list_empty(&ctp->t_items)))
		return false;
	if (READ_ONCE(ip->i_dlm_mode) == MXFS_LOCK_NL ||
	    !mxfs_noino_corpse_owes_platter(ip))
		return false;
	if (READ_ONCE(mxfs_dbg_recycle_nowait)) {
		/* TEST ONLY: recycle as a caller that cannot wait would */
		atomic_inc(&mxfs_dbg_recycle_nowait_hits);
		return false;
	}
	if (!READ_ONCE(mxfs_noino_recycle_dirty_wait)) {
		/* the control: this recycle resets a corpse that owes the
		 * platter a change, under the release that needs it written */
		atomic_inc(&mxfs_recycle_dirty_hazard);
		return false;
	}
	atomic_inc(&mxfs_recycle_dirty_wait_rounds);
	if (!ip->i_mxfs_noino_waited) {
		ip->i_mxfs_noino_waited = 1;
		atomic_inc(&mxfs_recycle_dirty_waits);
		if (atomic_inc_return(&p_rdw_n) <= 2000)
			pr_warn("mxfs: P-RECYCLE-DIRTY-WAIT ino=%llu cached_mode=%u fields=0x%x in_ail=%d pin=%u cc=%llu nlink=%u imode=0%o comm=%s -- a no-inode release of this number is in flight and the corpse still owes the platter a committed change; the recycle waits for the release instead of lowering the grant its fence writes under\n",
				(unsigned long long)ip->i_ino, ip->i_dlm_mode,
				iip ? READ_ONCE(iip->ili_fields) : 0,
				(iip && test_bit(XFS_LI_IN_AIL,
						 &iip->ili_item.li_flags)) ? 1 : 0,
				xfs_ipincount(ip),
				(unsigned long long)inode_peek_iversion(VFS_I(ip)),
				VFS_I(ip)->i_nlink, VFS_I(ip)->i_mode,
				current->comm);
	}
	return true;
}

/*
 * coalesced release-side device flush.  Equivalent to
 * blkdev_issue_flush(bdev) for the caller (its already-submitted writes are on
 * the platter when this returns) but concurrent callers share one device flush.
 * Correctness: a release takes a ticket AFTER its writes are submitted, then
 * either observes that a completed flush already covered its ticket, or issues a
 * flush itself.  blkdev_issue_flush persists everything submitted before it
 * returns, so the ticket it covers (snapshot, taken before issuing) is a safe
 * lower bound.  May over-flush (never under-flush) under races.
 */
void
mxfs_release_coalesced_flush(
	struct xfs_mount	*mp)
{
	struct block_device	*bdev;
	long long		seq, snap;

	if (!mp->m_ddev_targp || !mp->m_ddev_targp->bt_bdev)
		return;
	bdev = mp->m_ddev_targp->bt_bdev;

	seq = atomic64_inc_return(&mp->m_mxfs_flush_req);
	if (atomic64_read(&mp->m_mxfs_flush_done) >= seq)
		return;	/* a flush already persisted our writes */

	mutex_lock(&mp->m_mxfs_flush_lock);
	if (atomic64_read(&mp->m_mxfs_flush_done) >= seq) {
		mutex_unlock(&mp->m_mxfs_flush_lock);
		return;	/* coalesced: someone flushed while we waited */
	}
	snap = atomic64_read(&mp->m_mxfs_flush_req);
	blkdev_issue_flush(bdev);
	/* the coalesced engine is the main release-path
	 * flush - advance the platter-coherence epoch (m_mxfs_flush_epoch). */
	atomic64_inc(&mp->m_mxfs_flush_epoch);
	/* This flush covered every write submitted before it returned, i.e. at
	 * least every ticket up to `snap`.  Advance done (never backwards). */
	if (atomic64_read(&mp->m_mxfs_flush_done) < snap)
		atomic64_set(&mp->m_mxfs_flush_done, snap);
	mutex_unlock(&mp->m_mxfs_flush_lock);
}

static void
mxfs_noino_dump_ail_min(
	struct xfs_mount	*mp,
	uint64_t		ino)
{
	static atomic_t		cap = ATOMIC_INIT(0);
	static atomic_t		owner_stacks = ATOMIC_INIT(0);
	struct xfs_ail		*ailp = mp->m_ail;
	struct xfs_log_item	*lip;
	pid_t			efi_owner = 0;

	if (atomic_inc_return(&cap) > 24)
		return;
	spin_lock(&ailp->ail_lock);
	lip = xfs_ail_min(ailp);
	if (!lip) {
		spin_unlock(&ailp->ail_lock);
		mxfs_probe("mxfs: P-AILMIN ino=%llu -- AIL empty at dump\n",
			(unsigned long long)ino);
		return;
	}
	if (lip->li_type == XFS_LI_BUF) {
		struct xfs_buf_log_item *bip =
			container_of(lip, struct xfs_buf_log_item, bli_item);
		struct xfs_buf *bp = bip->bli_buf;

		mxfs_probe("mxfs: P-AILMIN ino=%llu BUF lsn=0x%llx daddr=%lld len=%u bflags=0x%x liflags=0x%lx pin=%d ops=%s\n",
			(unsigned long long)ino,
			(unsigned long long)lip->li_lsn,
			(long long)bp->b_maps[0].bm_bn, bp->b_length,
			bp->b_flags, lip->li_flags,
			atomic_read(&bp->b_pin_count),
			bp->b_ops ? bp->b_ops->name : "none");
		mxfs_buf_diag_dump("P-AILMIN-BUF", ino, bp);
	} else if (lip->li_type == XFS_LI_INODE) {
		struct xfs_inode_log_item *iip =
			container_of(lip, struct xfs_inode_log_item, ili_item);
		struct xfs_inode *tip = iip->ili_inode;

		/*
		 * (0.23.4 test31, D-474): the frozen min was an INODE
		 * item in XFS_LI_FLUSHING (liflags 0x21 = IN_AIL|FLUSHING, NOT
		 * FAILED) for 23 s.  xfsaild never pushes a FLUSHING item, so
		 * the P129 branch probes are blind to it; name the item's own
		 * flush state and dump its cluster buffer (the only thing that
		 * can still complete it).
		 */
		mxfs_probe("mxfs: P-AILMIN ino=%llu INODE lsn=0x%llx tgt_ino=%llu liflags=0x%lx fields=0x%x last=0x%x flush_lsn=0x%llx iflags=0x%lx dlm_mode=%d ipin=%d nlink=%u mode=0%o\n",
			(unsigned long long)ino,
			(unsigned long long)lip->li_lsn,
			(unsigned long long)(tip ? tip->i_ino : 0),
			lip->li_flags, iip->ili_fields, iip->ili_last_fields,
			(unsigned long long)iip->ili_flush_lsn,
			tip ? tip->i_flags : 0UL,
			tip ? (int)tip->i_dlm_mode : -1,
			tip ? xfs_ipincount(tip) : -1,
			tip ? VFS_I(tip)->i_nlink : 0,
			tip ? VFS_I(tip)->i_mode : 0);
		mxfs_buf_diag_dump("P-AILMIN-IBUF", ino, lip->li_buf);
	} else if (lip->li_type == XFS_LI_EFI) {
		/*
		 * an EFI at the AIL min is an extent-free DEFER
		 * CHAIN still in flight (no iop_push — it leaves the AIL
		 * only when its EFD commits, which needs the AGF of each
		 * extent's AG).  Name the AGs so the freeze can be matched
		 * to a local blocking AG wait (P1-AGWAIT / agwait_inflight).
		 */
		struct xfs_efi_log_item *efip =
			container_of(lip, struct xfs_efi_log_item, efi_item);
		unsigned int nx = efip->efi_format.efi_nextents;
		xfs_agnumber_t a0 = nx ? XFS_FSB_TO_AGNO(mp,
				efip->efi_format.efi_extents[0].ext_start) :
				NULLAGNUMBER;
		int wait0 = (a0 != NULLAGNUMBER) ?
			mxfs_noino_agwait_inflight(mp, a0) : -1;

		efi_owner = efip->efi_mxfs_owner_pid;
		mxfs_probe("mxfs: P-AILMIN ino=%llu EFI lsn=0x%llx nextents=%u ag0=%u agwait_inflight=%d liflags=0x%lx owner_pid=%d -- extent-free intent: its EFD is the owner's to commit\n",
			(unsigned long long)ino,
			(unsigned long long)lip->li_lsn, nx, a0, wait0,
			lip->li_flags, efi_owner);
	} else {
		mxfs_probe("mxfs: P-AILMIN ino=%llu type=0x%x intent=%d lsn=0x%llx liflags=0x%lx\n",
			(unsigned long long)ino, lip->li_type,
			xlog_item_is_intent(lip) ? 1 : 0,
			(unsigned long long)lip->li_lsn, lip->li_flags);
	}
	spin_unlock(&ailp->ail_lock);
	/*
	 * D-8CAWMPATH-SURVIVOR-SHUTS-DOWN-ON-NOINO-EFI-WEDGE-DURING-PEER-FENCE:
	 * the frozen EFI's AG was granted to its chain 7 s before the dump
	 * (agwait_inflight=0), so the owner was blocked somewhere no probe
	 * named.  Its stack says where; a few per boot.
	 */
	if (efi_owner && atomic_inc_return(&owner_stacks) <= 4) {
		pr_warn("mxfs: P-AILMIN-EFI-OWNER ino=%llu owner_pid=%d -- stack of the task that logged the frozen EFI follows (none: it has exited)\n",
			(unsigned long long)ino, efi_owner);
		mxfs_pal_dump_task_stack(efi_owner);
	}
}

/*
 * (D-474 convoy-aware fence): classify a FROZEN AIL min.  Returns
 * true when the freeze is attributable to a LOCAL task blocked in the per-AG
 * CAW acquire — i.e. the item cannot land until that bounded wait ends, so
 * the fence must keep waiting rather than shut the node down:
 *   EFI        -> an extent's AG has agwait_inflight > 0 (exact: the EFD
 *                 commits when xfs_extent_free_finish_item gets that AGF);
 *   BUF/INODE  -> some local blocking AG wait is in flight (the owner that
 *                 holds the buffer/ILOCK across the wait cannot be named
 *                 cheaply; the fence's 45-try hard wall still bounds it).
 * *agno_out names the attributed AG (NULLAGNUMBER when none), *wait_ms the
 * age of that AG's oldest in-flight wait episode.  Done under ail_lock; no
 * item pointer escapes it.
 */
static int
mxfs_noino_agwait_inflight(
	struct xfs_mount	*mp,
	xfs_agnumber_t		agno)
{
	struct xfs_perag	*pag;
	int			n;

	if (agno == NULLAGNUMBER || agno >= mp->m_sb.sb_agcount)
		return 0;
	pag = xfs_perag_get(mp, agno);
	if (!pag)
		return 0;
	n = atomic_read(&pag->pag_mxfs_agwait_inflight);
	xfs_perag_put(pag);
	return n;
}

static xfs_agnumber_t
mxfs_noino_any_agwait(
	struct xfs_mount	*mp,
	u64			*since_ns)
{
	xfs_agnumber_t		agno;

	for (agno = 0; agno < mp->m_sb.sb_agcount; agno++) {
		struct xfs_perag *pag = xfs_perag_get(mp, agno);

		if (!pag)
			continue;
		if (atomic_read(&pag->pag_mxfs_agwait_inflight) > 0) {
			*since_ns = READ_ONCE(pag->pag_mxfs_agwait_since_ns);
			xfs_perag_put(pag);
			return agno;
		}
		xfs_perag_put(pag);
	}
	return NULLAGNUMBER;
}

/*
 * D-8CAWMPATH-SURVIVOR-SHUTS-DOWN-ON-NOINO-EFI-WEDGE-DURING-PEER-FENCE: a frozen
 * minimum that no AG wait accounts for can still belong to a local transaction
 * chain in flight: an intent item stays the minimum until its chain commits the
 * done item, and an inode item cannot be flushed while the chain holds the
 * inode's ILOCK.  Such a chain was waiting out a frozen peer's death window,
 * fence and replay (~20 s at a 12 s window), and holding one EFD 30 s on a
 * healthy pair (dbg_efd_hold_ms) did the same; the 8-stall budget shut the node
 * down both times.  It is a convoy, not a wedge.  noino_convoy_chain=0 excuses
 * only AG waits, as before: the same-build control.
 */
int mxfs_noino_convoy_chain = 1;
module_param_named(noino_convoy_chain, mxfs_noino_convoy_chain, int, 0644);
MODULE_PARM_DESC(noino_convoy_chain,
	"no-inode fence: an AIL minimum held by a local chain in flight (an intent item, or an inode item whose ILOCK is held) is a convoy, not charged as a wedge (default 1; 0 = only AG waits)");

static bool
mxfs_noino_freeze_is_convoy(
	struct xfs_mount	*mp,
	xfs_agnumber_t		*agno_out,
	unsigned int		*item_type_out,
	u64			*wait_ms_out)
{
	struct xfs_ail		*ailp = mp->m_ail;
	struct xfs_log_item	*lip;
	xfs_agnumber_t		item_ag = NULLAGNUMBER;
	xfs_agnumber_t		ags[8];
	unsigned int		nags = 0, i;
	unsigned int		type = 0;
	u64			since = 0;
	bool			convoy = false;
	bool			chain = false;

	*agno_out = NULLAGNUMBER;
	*item_type_out = 0;
	*wait_ms_out = 0;

	spin_lock(&ailp->ail_lock);
	lip = xfs_ail_min(ailp);
	if (lip) {
		type = lip->li_type;
		if (lip->li_type == XFS_LI_EFI) {
			struct xfs_efi_log_item *efip =
				container_of(lip, struct xfs_efi_log_item,
					     efi_item);
			unsigned int nx = efip->efi_format.efi_nextents;

			for (i = 0; i < nx && nags < ARRAY_SIZE(ags); i++)
				ags[nags++] = XFS_FSB_TO_AGNO(mp,
					efip->efi_format.efi_extents[i].ext_start);
		} else if (lip->li_type == XFS_LI_BUF) {
			struct xfs_buf_log_item *bip =
				container_of(lip, struct xfs_buf_log_item,
					     bli_item);
			item_ag = xfs_daddr_to_agno(mp,
					bip->bli_buf->b_maps[0].bm_bn);
		} else if (lip->li_type == XFS_LI_INODE) {
			struct xfs_inode_log_item *iip =
				container_of(lip, struct xfs_inode_log_item,
					     ili_item);
			if (iip->ili_inode) {
				struct xfs_inode *ip = iip->ili_inode;

				item_ag = XFS_INO_TO_AGNO(mp, ip->i_ino);
				/* a trylock and its raw release never
				 * sleep; the item in the AIL keeps the inode
				 * from reclaim while ail_lock is held.  ILOCK
				 * nowait takes no DLM holder, so the release
				 * must not end one (xfs_iunlock_nodlm). */
				if (READ_ONCE(mxfs_noino_convoy_chain)) {
					if (xfs_ilock_nowait(ip, XFS_ILOCK_SHARED))
						xfs_iunlock_nodlm(ip, XFS_ILOCK_SHARED);
					else
						chain = true;
				}
			}
		}
		if (READ_ONCE(mxfs_noino_convoy_chain) &&
		    xlog_item_is_intent(lip))
			chain = true;
	}
	spin_unlock(&ailp->ail_lock);
	*item_type_out = type;
	if (!lip)
		return false;

	if (type == XFS_LI_EFI) {
		for (i = 0; i < nags; i++) {
			struct xfs_perag *pag;

			if (ags[i] >= mp->m_sb.sb_agcount)
				continue;
			pag = xfs_perag_get(mp, ags[i]);
			if (!pag)
				continue;
			if (atomic_read(&pag->pag_mxfs_agwait_inflight) > 0) {
				since = READ_ONCE(pag->pag_mxfs_agwait_since_ns);
				*agno_out = ags[i];
				convoy = true;
			}
			xfs_perag_put(pag);
			if (convoy)
				break;
		}
	} else {
		xfs_agnumber_t wag = mxfs_noino_any_agwait(mp, &since);

		if (wag != NULLAGNUMBER) {
			*agno_out = wag;
			convoy = true;
		} else {
			*agno_out = item_ag;
		}
	}
	if (convoy && since)
		*wait_ms_out = (ktime_get_ns() - since) / 1000000;
	if (!convoy && chain) {
		static atomic_t p_chain_n = ATOMIC_INIT(0);

		if (atomic_inc_return(&p_chain_n) <= 200)
			pr_warn("mxfs: P-NOINO-CONVOY-CHAIN item=0x%x ag=%u intent=%d -- AIL min held by a local chain in flight; not charged as a wedge\n",
				type, item_ag, type == XFS_LI_INODE ? 0 : 1);
		convoy = true;
	}
	return convoy;
}

/*
 * stall repair: land the node's own committed-but-
 * unwritable buffers.  Invariant #1's contract ("everything this node
 * committed before the release is on disk") INCLUDES fresh inode-cluster
 * buffers sitting on pag_mxfs_alloc_buflist — committed icreate state that
 * xfsaild structurally cannot write (FLUSHING dead-end above).  The AG
 * release path drains them as a mandatory pre-unlock step; the noino
 * fence must too, or the AIL min freezes at their BLI and the fence can
 * never complete (run70: 9-node collapse; and the un-landed cluster init
 * is exactly what peers then mis-read — run69 test18's EFSBADCRC inode
 * cluster still holding prior-tenant file data).  Bounded: agcount
 * iterations, only non-empty lists pay; drain itself submits sync +
 * device-flushes (mxfs_dlm_ag_drain_alloc_buflist).
 */
static void
mxfs_noino_drain_mxfs_buflists(
	struct xfs_mount	*mp,
	uint64_t		ino)
{
	unsigned int		drained_ags;

	drained_ags = mxfs_dlm_ag_drain_all_alloc_buflists(mp);
	pr_warn("mxfs: P-NOINO-LISTDRAIN ino=%llu ags=%u -- fence stalled; drained mxfs alloc buflists (xfsaild cannot write _XBF_MXFS_ALLOC_QUEUED bufs)\n",
		(unsigned long long)ino, drained_ags);
}

bool
mxfs_noino_drain_fence(
	struct xfs_mount	*mp,
	uint64_t		ino,
	int			landed)
{
	xfs_lsn_t		last_min = 0;
	int			stall = 0;
	int			convoy_stalls = 0;
	xfs_agnumber_t		cv_ag = NULLAGNUMBER;
	unsigned int		cv_type = 0;
	u64			cv_wait_ms = 0;
	int			try;
	bool			armed_here = false;

	for (try = 0; try < MXFS_NOINO_MAX_TRIES; try++) {
		xfs_lsn_t target = 0;
		xfs_lsn_t ail_max;
		xfs_lsn_t min_now;

		/* noino_acq_takeover: a taken release does not unlock, so it
		 * has nothing to make durable; its caller re-drives the BAST */
		if (mxfs_noino_bast_dedup &&
		    mxfs_noino_inflight_is_taken(mp, ino)) {
			extern atomic_t mxfs_noino_fence_taken;
			static atomic_t p_nft_n = ATOMIC_INIT(0);

			atomic_inc(&mxfs_noino_fence_taken);
			if (atomic_inc_return(&p_nft_n) <= 2000)
				pr_warn("mxfs: P-NOINO-FENCE-TAKEN ino=%llu try=%d stall=%d -- the release was taken over; its drain fence stops\n",
					(unsigned long long)ino, try, stall);
			if (armed_here)
				mxfs_ailstuck_probe_fence_disarm();
			return true;
		}
		xfs_log_force(mp, XFS_LOG_SYNC);
		/* FIX-12b skip arm: a completed noino drain already covers
		 * everything now in the AIL (see loop comment below). */
		ail_max = xfs_ail_max_lsn(mp->m_ail);
		if (ail_max == 0 ||
		    XFS_LSN_CMP(ail_max, (xfs_lsn_t)atomic64_read(
				&mp->m_mxfs_noino_drained_lsn)) <= 0) {
			/* FIX-16: the skip arm does no device flush; if the
			 * land scan wrote, cover those writes before the
			 * unlock hands the platter to a FUA reader. */
			if (landed > 0)
				mxfs_release_coalesced_flush(mp);
			if (armed_here)
				mxfs_ailstuck_probe_fence_disarm();
			return true;
		}
		mxfs_noino_inflight_note(mp, ino, MXFS_NOINO_PH_FENCE, try,
					 ail_max);
		if (xfs_ail_push_upto_sync_bounded(mp->m_ail, 2000,
						   &target)) {
			s64 old;

			/* flush BEFORE publishing the marker: a racer that
			 * skips on the marker must find its writes already
			 * device-flush-covered. */
			mxfs_release_coalesced_flush(mp);
			old = atomic64_read(&mp->m_mxfs_noino_drained_lsn);
			while (XFS_LSN_CMP((xfs_lsn_t)old, target) < 0 &&
			       !atomic64_try_cmpxchg(
				       &mp->m_mxfs_noino_drained_lsn,
				       &old, (s64)target))
				;
			if (armed_here)
				mxfs_ailstuck_probe_fence_disarm();
			return true;
		}
		if (xfs_is_shutdown(mp))
			return false;	/* already down: stop retry spam */
		min_now = xfs_ail_min_lsn(mp->m_ail);
		if (min_now != last_min) {
			stall = 0;
			last_min = min_now;
			/* freeze broke: disarm now so a later new freeze in
			 * this same fence re-arms with a fresh odumps budget */
			if (armed_here) {
				mxfs_ailstuck_probe_fence_disarm();
				armed_here = false;
			}
		} else if (mxfs_noino_freeze_is_convoy(mp, &cv_ag, &cv_type,
						       &cv_wait_ms)) {
			/*
			 * (D-474, design-consult ruling): the frozen
			 * min is attributable to a LOCAL task blocked in the
			 * bounded per-AG CAW acquire (measured at 25 AGs: an
			 * EFI whose EFD needs the shared AG a peer held 13 s;
			 * every fence on the node froze on it and the 8-stall
			 * budget shut the node down).  A convoy is not a
			 * wedge: do not charge the stall budget.  The
			 * MXFS_NOINO_MAX_TRIES hard wall still bounds the
			 * whole fence, so an unrelated or never-ending wait
			 * cannot suppress a real freeze forever.
			 */
			convoy_stalls++;
			if (convoy_stalls == 1 || (convoy_stalls % 4) == 0)
				pr_warn("mxfs: P-NOINO-CONVOY ino=%llu try=%d min=0x%llx item=0x%x ag=%u agwait_ms=%llu frozen=%d chargeable=%d -- AIL min frozen behind a local blocking AG wait; not charged as a wedge\n",
					(unsigned long long)ino, try,
					(unsigned long long)min_now, cv_type,
					cv_ag, (unsigned long long)cv_wait_ms,
					convoy_stalls, stall);
			if (convoy_stalls == 2)
				mxfs_noino_dump_ail_min(mp, ino);
		} else {
			stall++;
			/* Frozen min: name the item (proof), then land the
			 * node's own alloc-buflist buffers (repair — the
			 * FLUSHING dead-end class xfsaild cannot write).
			 * Only wedge if the min stays frozen even after the
			 * repair had two further pushes to show effect. */
			if (stall == 2) {
				/* incident474: the fence wedged and shut the
				 * node down without ever arming the AIL-stuck
				 * probes (they self-latch only after 30s inside
				 * xfs_ail_push_all_sync, a path this fence never
				 * takes).  Latch them here so the remaining
				 * bounded pushes name WHY the frozen item's
				 * cluster flush is skipped (P129-CLSKIP incl.
				 * ILOCK owner) instead of dying silent.
				 * Fence-scoped: a recovered fence disarms on
				 * its success return (— the benign
				 * LISTDRAIN-repairable class was permanently
				 * latching the fleet); DRAIN-STUCK/shutdown
				 * exits keep the latch for the post-mortem. */
				if (!armed_here) {
					mxfs_ailstuck_probe_fence_arm();
					armed_here = true;
				}
				mxfs_noino_dump_ail_min(mp, ino);
			}
			if (stall == 3)
				mxfs_noino_drain_mxfs_buflists(mp, ino);
			if (stall >= MXFS_NOINO_STALL_TRIES) {
				pr_warn("mxfs: P-NOINO-DRAIN-STUCK ino=%llu try=%d -- AIL min frozen at 0x%llx across %d bounded pushes (post-listdrain) convoy_stalls=%d\n",
					(unsigned long long)ino, try,
					(unsigned long long)min_now, stall,
					convoy_stalls);
				return false;
			}
		}
		if ((try % 5) == 4)
			pr_warn("mxfs: P-NOINO-DRAIN-RETRY ino=%llu try=%d min=0x%llx stall=%d convoy=%d -- pre-release AIL target not yet landed\n",
				(unsigned long long)ino, try,
				(unsigned long long)min_now, stall, convoy_stalls);
	}
	pr_warn("mxfs: P-NOINO-DRAIN-STUCK ino=%llu -- hard cap %d tries exceeded (AIL advancing or convoy-frozen but never caught the snapshot target) convoy_stalls=%d last_ag=%u agwait_ms=%llu\n",
		(unsigned long long)ino, MXFS_NOINO_MAX_TRIES, convoy_stalls,
		cv_ag, (unsigned long long)cv_wait_ms);
	return false;
}

/*
 * D-NETMESH-LIVE-FILE-INODE-FREED-UNDER-ITS-NAME-AFTER-NUMBER-REUSE, H-N2: a
 * no-inode release whose BAST found no tenure of ours (rel_gen 0) releases
 * whatever grant it meets when it runs -- mxfs_dlm_unlock_open with
 * expected_gen 0 takes the first granted entry and echoes that entry's own
 * generation, so the master accepts it -- and it runs only after the drain
 * fence above, which can take seconds.  A tenure granted in between was not
 * the one the peer's BAST was about: a fresh local acquire, typically a create
 * that reused the number (an INEW inode is invisible to the live check above).
 * Releasing it hands the inode to a peer while this node is still using it.
 *
 * Census of every rel_gen 0 release: noino_gen0_releases counts them,
 * noino_gen0_live those that meet a generation-bearing tenure at the moment of
 * the release (on TCP the mirror's generation is exact; on CAW grant_meta is
 * lossy, so a 0 there proves nothing), with one line each (capped).  Both are
 * module parameters (xfs_mxfs_dlm.c).
 *
 * noino_gen0_guard (default 1) sends such a release through
 * mxfs_v5_dlm_inode_unlock_unanchored, which on TCP refuses a
 * generation-bearing grant under the table lock; 0 is the old unconditional
 * release, the same-build control.  A refusal leaves the peer's request to its
 * own re-send: the TCP waiter re-BASTs the current holder every
 * MXFS_DLM_ACQ_BAST_REFIRE_MS, and that BAST meets the live tenure through
 * the in-core path, which releases it once its holders are done.
 */
atomic_t mxfs_noino_gen0_releases = ATOMIC_INIT(0);
atomic_t mxfs_noino_gen0_live = ATOMIC_INIT(0);
atomic_t mxfs_noino_gen0_refused = ATOMIC_INIT(0);
int mxfs_noino_gen0_guard = 1;
module_param_named(noino_gen0_guard, mxfs_noino_gen0_guard, int, 0644);
MODULE_PARM_DESC(noino_gen0_guard,
	"a no-inode release whose BAST found no tenure of ours never releases a generation-bearing grant (TCP) (1=default; 0=unconditional release, the same-build control)");

/*
 * TEST ONLY: how long a rel_gen 0 release waits between its live check and its
 * unlock.  On the rig that window is a few microseconds, so the guard's A/B
 * never met a tenure granted inside it (43 gen-0 releases, 0 live); held open,
 * a local create that reuses the number is granted inside it.  0 = off.
 */
int mxfs_dbg_noino_release_delay_ms;
module_param_named(dbg_noino_release_delay_ms, mxfs_dbg_noino_release_delay_ms, int, 0644);
MODULE_PARM_DESC(dbg_noino_release_delay_ms,
	"TEST ONLY: ms a no-inode release whose BAST found no tenure of ours waits between its live check and its unlock (0=off)");

/*
 * TEST ONLY: how long EVERY no-inode release waits after its drain fence and
 * live check, just before it publishes and unlocks.  A change this node
 * commits through the number's cached grant inside that window is covered by
 * no fence (H-F7: kdf2's lookup node touched a recycled corpse 88 times during
 * a 5.3 s fence and the last touch rode the unlock undrained); on the rig the
 * window is microseconds, so noino_recycle_guard's A/B met it about once in
 * twenty laps.  Held open, the lookup's recycle-and-touch lands inside it.
 * 0 = off.
 */
int mxfs_dbg_noino_postfence_delay_ms;
module_param_named(dbg_noino_postfence_delay_ms, mxfs_dbg_noino_postfence_delay_ms, int, 0644);
MODULE_PARM_DESC(dbg_noino_postfence_delay_ms,
	"TEST ONLY: ms every no-inode release waits after its drain fence and live check, before it publishes and unlocks (0=off)");

/*
 * TEST ONLY: how long EVERY no-inode release waits before its land scan and
 * drain fence.  D-RECYCLE-RESET-UNDER-NOINO-STRANDS-COMMITTED-DIR-CHANGE-
 * WEDGE-SHUTDOWN needs a lookup to recycle a dirty corpse after the release
 * registered and before its fence writes the corpse; on the rig that is a few
 * ms, and 1 of 84 recycle resets in the final-verification laps met a dirty
 * corpse.  Held open, the dirtying node's own next lookup lands inside it
 * (tests/noino_dirty_recycle_ab.sh).  0 = off.
 */
int mxfs_dbg_noino_prefence_delay_ms;
module_param_named(dbg_noino_prefence_delay_ms, mxfs_dbg_noino_prefence_delay_ms, int, 0644);
MODULE_PARM_DESC(dbg_noino_prefence_delay_ms,
	"TEST ONLY: ms every no-inode release waits before its land scan and drain fence (0=off)");

static void
mxfs_noino_gen0_census(
	struct xfs_mount	*mp,
	uint64_t		ino,
	bool			guard)
{
	static atomic_t		p_gen0_cap = ATOMIC_INIT(0);
	uint32_t		now_gen;
	unsigned long		lfl = 0, lst = 0;
	unsigned int		lnl = 0;
	enum xfs_ino_lifecycle	lc;

	atomic_inc(&mxfs_noino_gen0_releases);
	now_gen = mxfs_v5_dlm_inode_grant_gen(mp->m_mxfs_dlm, ino);
	if (!now_gen)
		return;
	atomic_inc(&mxfs_noino_gen0_live);
	if (atomic_inc_return(&p_gen0_cap) > 1000)
		return;
	lc = xfs_icache_ino_lifecycle(mp, ino, &lfl, &lnl, &lst);
	pr_warn("mxfs: P-NOINO-GEN0-LIVE ino=%llu now_gen=%u mode=%u lifecycle=%s nlink=%u tcp=%d guard=%d -- a no-inode release whose BAST found no tenure of ours meets a tenure granted since; %s\n",
		(unsigned long long)ino, now_gen,
		mxfs_v5_dlm_inode_granted_mode(mp->m_mxfs_dlm, ino),
		lc < XFS_ILC_NR ? xfs_ino_lifecycle_name(lc) : "?", lnl,
		mxfs_v5_dlm_is_tcp(mp->m_mxfs_dlm) ? 1 : 0, guard ? 1 : 0,
		guard ? "the guarded release refuses a generation-bearing grant" :
			"the unconditional release takes it (guard off)");
}

/*
 * A recycle took this release over (mxfs_noino_inflight_take) and kept the
 * grant it would have unlocked.  The peer's request is still pending: park its
 * BAST behind the recycle so the re-drive meets the recycled inode through the
 * in-core path, which drains under that grant and then releases it.  If the
 * park cannot be queued the peer's own re-send reaches the in-core path.
 */
void
mxfs_noino_taken_over(
	struct xfs_mount	*mp,
	uint64_t		ino,
	uint8_t			req_mode,
	uint32_t		rel_gen)
{
	extern atomic_t		mxfs_noino_takeovers;
	static atomic_t		p_ntko_n = ATOMIC_INIT(0);
	unsigned long		lfl = 0, lst = 0;
	unsigned int		lnl = 0;
	uint8_t			cm = MXFS_LOCK_NL;
	enum xfs_ino_lifecycle	lc;
	bool			parked;

	atomic_inc(&mxfs_noino_takeovers);
	lc = xfs_icache_ino_lifecycle_grant(mp, ino, &lfl, &lnl, &lst, &cm);
	parked = mxfs_noino_lifecycle_park(mp, ino, req_mode,
					   lc < XFS_ILC_NR ? lc : XFS_ILC_IRECLAIM);
	if (atomic_inc_return(&p_ntko_n) <= 2000)
		pr_warn("mxfs: P-NOINO-TAKEN-OVER ino=%llu rel_gen=%u req=%u lifecycle=%s cached_mode=%u parked=%d -- a recycle or acquire that could not wait kept this release's grant; no unlock, the BAST is re-driven to the in-core path\n",
			(unsigned long long)ino, rel_gen, req_mode,
			lc < XFS_ILC_NR ? xfs_ino_lifecycle_name(lc) : "?", cm,
			parked ? 1 : 0);
}

void
mxfs_dlm_noino_bast_work_fn(
	struct work_struct	*work)
{
	struct mxfs_noino_bast_work *w =
		container_of(work, struct mxfs_noino_bast_work, work);
	struct xfs_mount	*mp = w->mp;
	uint64_t		ino = w->ino;
	bool			drained = false;
	int			landed;
	u64			start_ns = ktime_get_ns(), fence_ns;
	struct xfs_ino_drain_state sds, uds;
	enum xfs_ino_lifecycle	slc, ulc;

	if (READ_ONCE(mxfs_dbg_noino_prefence_delay_ms) > 0)
		msleep(READ_ONCE(mxfs_dbg_noino_prefence_delay_ms));
	mxfs_noino_inflight_note(mp, ino, MXFS_NOINO_PH_LAND, -1, 0);
	/* H-F7 instrument: the in-core inode's changecount before the fence */
	slc = xfs_icache_ino_drain_state(mp, ino, &sds);

	/* FIX-16: land committed-never-written dir blocks
	 * owned by this ino FIRST — they are mxfs-seq-tracked (no BLI in the
	 * AIL), so the LSN fence below cannot see them (run89 r6: unlock
	 * handed the peer a pre-add platter while lseq=168 wseq=0 sat in
	 * core; peer readdir=758/800). */
	landed = mxfs_dir_noino_land_scan(mp, ino, true);

	/*
	 * FIX-12 (PROVEN BY INSTRUMENT, run81 r5): the old drain here
	 * pushed only XFS_INO_TO_AGNO(ino) — but a shared dir's data blocks
	 * are allocated AG-AFFINELY BY EACH WRITER, so they span AGs (node8's
	 * bno5@48144232 lived in a peer-allocated AG; the single-AG push never
	 * touched it, the unlock handed EX with 46 committed adds unlanded,
	 * and the cluster durably lost them off the stale platter).  This
	 * path also fires for IN-CORE inodes that xfs_iget(INCORE)
	 * transiently refuses (-EAGAIN: IRECLAIMABLE after the verify-phase
	 * drop_caches — the round-7 noino=170 storm), where the live dir
	 * state is very much ours to land.  No extent map => the only safe
	 * fence is "everything this node committed before the release is on
	 * disk": LSN-targeted whole-AIL push.  Later commits don't extend
	 * the target, so foreground load cannot livelock it.  P3B policy on
	 * failure: NEVER unlock undrained — retry, then shutdown (fence +
	 * journal replay beats a silent cluster-wide lost update).
	 *
	 * retry policy is PROGRESS-BASED now — see
	 * mxfs_noino_drain_fence above.  "Slow under a 32-node convoy" is
	 * not a wedge; only a frozen AIL min (or the ~90s hard wall) is.
	 */
	drained = mxfs_noino_drain_fence(mp, ino, landed);
	fence_ns = ktime_get_ns();
	mxfs_noino_inflight_note(mp, ino, MXFS_NOINO_PH_LIVE, -1, 0);
	if (!drained && !xfs_is_shutdown(mp)) {
		pr_warn("mxfs: P-NOINO-RELFENCE-WEDGE ino=%llu -- shutdown (un-durable no-inode lock NOT released)\n",
			(unsigned long long)ino);
		xfs_force_shutdown(mp, SHUTDOWN_META_IO_ERROR);
		if (mxfs_noino_bast_dedup)
			mxfs_noino_inflight_remove(mp, ino);
		if (w->untracked)
			atomic_dec(&mxfs_noino_untracked_inflight);
		kfree(w);
		return;
	}

	/*
	 * storm-2 refinement: the grant-gen anchor alone is
	 * NOT sufficient — grant_meta buckets are collision-LOSSY, so under
	 * a 32-node churn the anchor (and the unlock's own seq re-check)
	 * frequently degrade to 0/unconditional (guard fired 0× while
	 * P135-HELD-MISS stayed at 15,622/3min).  The robust tenure truth is
	 * IN CORE: this work fn only exists because the inode was NOT in
	 * core at BAST time; if it is BACK in core with a granted mode now,
	 * a local re-acquire won a new tenure during our drain fence — the
	 * slot bit is THE NEW TENURE'S, not ours to clear (test30's mkdir
	 * EX stripped 4ms after grant → double sf_to_block → durable dirent
	 * loss).  Skip; the live tenure's own BAST handling serves the peer.
	 */
	{
		struct xfs_inode *live_ip = NULL;

		if (!xfs_iget(mp, NULL, ino, XFS_IGET_INCORE, 0, &live_ip) &&
		    live_ip) {
			bool live_held =
				live_ip->i_dlm_mode != MXFS_LOCK_NL;

			xfs_irele(live_ip);
			if (live_held) {
				static atomic_t p_noino_live_cap =
					ATOMIC_INIT(0);
				bool taken = false;

				if (mxfs_noino_bast_dedup)
					taken = mxfs_noino_inflight_remove(mp, ino);
				if (atomic_inc_return(&p_noino_live_cap) <= 200)
					pr_warn("mxfs: P-NOINO-LIVE-SKIP ino=%llu taken=%d -- inode re-instantiated with a granted mode during the drain fence; release skipped (live tenure owns the slot)\n",
						(unsigned long long)ino, taken ? 1 : 0);
				/*
				 * A recycle took this release over and is that
				 * tenure: the peer's request waits on a BAST that
				 * only its requester's re-send (up to 10 s on TCP)
				 * would bring back, so re-drive it now.
				 */
				if (taken)
					mxfs_noino_taken_over(mp, ino, w->req_mode,
							      w->rel_gen);
				if (w->untracked)
					atomic_dec(&mxfs_noino_untracked_inflight);
				kfree(w);
				return;
			}
		}
	}
	if (w->rel_gen == 0 && READ_ONCE(mxfs_dbg_noino_release_delay_ms) > 0)
		msleep(READ_ONCE(mxfs_dbg_noino_release_delay_ms));
	if (READ_ONCE(mxfs_dbg_noino_postfence_delay_ms) > 0)
		msleep(READ_ONCE(mxfs_dbg_noino_postfence_delay_ms));
	if (mxfs_noino_bast_dedup && !w->untracked &&
	    !mxfs_noino_inflight_begin_unlock(mp, ino)) {
		/* the entry goes first: a re-drive that met it would be
		 * dropped as a duplicate of this release */
		mxfs_noino_inflight_remove(mp, ino);
		mxfs_noino_taken_over(mp, ino, w->req_mode, w->rel_gen);
		kfree(w);
		return;
	}
	mxfs_dlm_publish_unpublished(mp, ino, NULLAGNUMBER);
	/* H-F7 instrument: what the in-core inode still owes the platter as
	 * the unlock hands the inode over */
	ulc = xfs_icache_ino_drain_state(mp, ino, &uds);
	{
		bool guard = READ_ONCE(mxfs_noino_gen0_guard) != 0;
		int ug_rc;

		if (w->rel_gen == 0)
			mxfs_noino_gen0_census(mp, ino, guard);
		if (w->rel_gen == 0 && guard)
			ug_rc = mxfs_v5_dlm_inode_unlock_unanchored(
					mp->m_mxfs_dlm, ino);
		else
			ug_rc = mxfs_v5_dlm_inode_unlock_gen(mp->m_mxfs_dlm,
							     ino, w->rel_gen);

		if (ug_rc == -ESTALE) {
			static atomic_t p_noino_stale_cap = ATOMIC_INIT(0);

			if (w->rel_gen == 0)
				atomic_inc(&mxfs_noino_gen0_refused);
			if (atomic_inc_return(&p_noino_stale_cap) <= 200)
				pr_warn("mxfs: P-NOINO-STALE-RELEASE ino=%llu rel_gen=%u -- local re-acquire owns a newer tenure; release refused (fresh grant preserved)\n",
					(unsigned long long)ino, w->rel_gen);
		} else if (ug_rc == 0) {
			/*
			 * H-F7 instrument: the unlock went through.  An in-core
			 * inode of the number that still caches a grant now
			 * holds one the DLM no longer records for this node.
			 */
			extern atomic_t mxfs_noino_unlock_left_grant;
			unsigned long lfl = 0, lst = 0;
			unsigned int lnl = 0;
			uint8_t cm = MXFS_LOCK_NL;
			enum xfs_ino_lifecycle lc;

			lc = xfs_icache_ino_lifecycle_grant(mp, ino, &lfl,
							    &lnl, &lst, &cm);
			if (cm != MXFS_LOCK_NL) {
				extern atomic_t mxfs_noino_release_marked;
				static atomic_t p_nulg_n = ATOMIC_INIT(0);

				atomic_inc(&mxfs_noino_unlock_left_grant);
				if (atomic_inc_return(&p_nulg_n) <= 2000)
					pr_warn("mxfs: P-NOINO-UNLOCK-LEFT-GRANT ino=%llu rel_gen=%u lifecycle=%s cached_mode=%u iflags=0x%lx nlink=%u now_mode=%u -- no-inode release unlocked while an in-core inode of the number caches a grant\n",
						(unsigned long long)ino, w->rel_gen,
						lc < XFS_ILC_NR ?
							xfs_ino_lifecycle_name(lc) : "?",
						cm, lfl, lnl,
						mxfs_v5_dlm_inode_granted_mode(
							mp->m_mxfs_dlm, ino));
				/*
				 * H-NR1: that inode's tenure ended here.  Mark it
				 * before this release leaves the in-flight table,
				 * so a recycle that misses the table finds the mark.
				 */
				if (xfs_icache_ino_mark_released(mp, ino))
					atomic_inc(&mxfs_noino_release_marked);
			}
			/*
			 * The fence covered what was committed before its last
			 * log force; a change committed after it is still in core
			 * here, and the peer the unlock grants reads a platter
			 * without it.
			 */
			if (ulc != XFS_ILC_ABSENT &&
			    (uds.fields || uds.last_fields || uds.pin ||
			     uds.in_ail)) {
				extern atomic_t mxfs_noino_unlock_undrained;
				static atomic_t p_nuud_n = ATOMIC_INIT(0);
				u64 now = ktime_get_ns();

				atomic_inc(&mxfs_noino_unlock_undrained);
				if (atomic_inc_return(&p_nuud_n) <= 2000)
					pr_warn("mxfs: P-NOINO-UNLOCK-UNDRAINED ino=%llu rel_gen=%u lifecycle=%s start_lifecycle=%s cached_mode=%u fields=0x%x last=0x%x pin=%d in_ail=%d li_lsn=0x%llx drained_lsn=0x%llx cc=%llu start_cc=%llu queue_ms=%llu fence_ms=%llu tail_ms=%llu -- no-inode release unlocked while the in-core inode still held committed changes not on the platter\n",
						(unsigned long long)ino, w->rel_gen,
						xfs_ino_lifecycle_name(ulc),
						xfs_ino_lifecycle_name(slc),
						uds.dlm_mode, uds.fields,
						uds.last_fields, uds.pin,
						uds.in_ail ? 1 : 0,
						(unsigned long long)uds.li_lsn,
						(unsigned long long)atomic64_read(
							&mp->m_mxfs_noino_drained_lsn),
						(unsigned long long)uds.cc,
						(unsigned long long)sds.cc,
						(unsigned long long)((start_ns -
							w->bast_ns) / NSEC_PER_MSEC),
						(unsigned long long)((fence_ns -
							start_ns) / NSEC_PER_MSEC),
						(unsigned long long)((now -
							fence_ns) / NSEC_PER_MSEC));
			}
		}
	}
	if (mxfs_noino_bast_dedup)
		mxfs_noino_inflight_remove(mp, ino);
	if (w->untracked)
		atomic_dec(&mxfs_noino_untracked_inflight);
	kfree(w);
}
int mxfs_noino_lifecycle_max_ms = 60000;
module_param_named(noino_lifecycle_max_ms, mxfs_noino_lifecycle_max_ms, int, 0644);
MODULE_PARM_DESC(noino_lifecycle_max_ms,
	"bound on how long a no-inode BAST is requeued behind a local lifecycle op before it falls through to the fence (default 60000)");
static DEFINE_HASHTABLE(mxfs_noino_lc_ht, 6);
static DEFINE_SPINLOCK(mxfs_noino_lc_lock);

static void
mxfs_noino_lc_work_fn(
	struct work_struct	*work)
{
	struct mxfs_noino_lc_work *w =
		container_of(to_delayed_work(work), struct mxfs_noino_lc_work, dw);
	struct xfs_mount	*mp = w->mp;
	uint64_t		ino = w->ino;
	uint8_t			mode = w->mode;
	unsigned long		fl, st;
	unsigned int		nl;
	enum xfs_ino_lifecycle	lc;
	u64			age_ms;
	unsigned long		flags;
	bool			requeue;

	lc = xfs_icache_ino_lifecycle(mp, ino, &fl, &nl, &st);
	age_ms = (ktime_get_ns() - w->first_ns) / 1000000;
	requeue = mxfs_noino_lifecycle_requeue &&
		  (lc == XFS_ILC_INEW || lc == XFS_ILC_IRECLAIM ||
		   lc == XFS_ILC_INACTIVATING || lc == XFS_ILC_NEED_INACTIVE ||
		   lc == XFS_ILC_VFS_TEARDOWN) &&
		  age_ms < (u64)mxfs_noino_lifecycle_max_ms &&
		  !xfs_is_shutdown(mp);
	if (requeue) {
		w->n++;
		if (lc == XFS_ILC_NEED_INACTIVE)
			xfs_inodegc_push(mp);
		queue_delayed_work(mp->m_mxfs_inode_bast_wq, &w->dw,
				   msecs_to_jiffies(20));
		return;
	}
	spin_lock_irqsave(&mxfs_noino_lc_lock, flags);
	hash_del(&w->hnode);
	spin_unlock_irqrestore(&mxfs_noino_lc_lock, flags);
	if (age_ms >= (u64)mxfs_noino_lifecycle_max_ms) {
		atomic64_inc(&mxfs_noino_lifecycle_timeouts);
		pr_warn("mxfs: P-NOINO-LIFECYCLE-TIMEOUT ino=%llu class=%s iflags=0x%lx nlink=%u age_ms=%llu requeues=%u -- local lifecycle op still running; falling through to the fence\n",
			(unsigned long long)ino, xfs_ino_lifecycle_name(lc), fl,
			nl, (unsigned long long)age_ms, w->n);
	} else {
		static atomic_t p_lcdone_n = ATOMIC_INIT(0);

		if ((unsigned)atomic_inc_return(&p_lcdone_n) <= 64)
			mxfs_probe("mxfs: P-NOINO-LIFECYCLE-DONE ino=%llu class=%s age_ms=%llu requeues=%u -- lifecycle op finished; re-driving the BAST\n",
				(unsigned long long)ino,
				xfs_ino_lifecycle_name(lc),
				(unsigned long long)age_ms, w->n);
	}
	/* re-drive; a fresh transient state may requeue again (new bound),
	 * a timed-out one must not. */
	__mxfs_dlm_bast_notify(mp, ino, mode,
			       age_ms < (u64)mxfs_noino_lifecycle_max_ms);
	kfree(w);
}

/* Returns true when the BAST was parked behind the lifecycle op (caller must
 * return without fencing); false when the caller should proceed as before. */
bool
mxfs_noino_lifecycle_park(
	struct xfs_mount	*mp,
	uint64_t		ino,
	uint8_t			requested_mode,
	enum xfs_ino_lifecycle	lc)
{
	struct mxfs_noino_lc_work *w, *e;
	unsigned long		flags;

	if (!mp->m_mxfs_inode_bast_wq)
		return false;
	w = kzalloc(sizeof(*w), GFP_ATOMIC);
	if (!w)
		return false;
	w->mp = mp;
	w->ino = ino;
	w->mode = requested_mode;
	w->first_ns = ktime_get_ns();
	INIT_DELAYED_WORK(&w->dw, mxfs_noino_lc_work_fn);
	spin_lock_irqsave(&mxfs_noino_lc_lock, flags);
	hash_for_each_possible(mxfs_noino_lc_ht, e, hnode, ino) {
		if (e->mp == mp && e->ino == ino) {
			/* already parked: drop this duplicate BAST (the peer
			 * re-BASTs while our bit stays set; the parked work
			 * re-drives when the lifecycle op finishes). */
			spin_unlock_irqrestore(&mxfs_noino_lc_lock, flags);
			kfree(w);
			return true;
		}
	}
	hash_add(mxfs_noino_lc_ht, &w->hnode, ino);
	spin_unlock_irqrestore(&mxfs_noino_lc_lock, flags);
	atomic64_inc(&mxfs_noino_lifecycle_requeued);
	if (lc == XFS_ILC_NEED_INACTIVE)
		xfs_inodegc_push(mp);
	queue_delayed_work(mp->m_mxfs_inode_bast_wq, &w->dw,
			   msecs_to_jiffies(20));
	return true;
}

void
mxfs_dlm_bast_notify(
	void		*data,
	uint64_t	ino,
	uint8_t		requested_mode)
{
	__mxfs_dlm_bast_notify(data, ino, requested_mode, true);
}
