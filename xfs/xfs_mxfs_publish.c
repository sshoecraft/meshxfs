// SPDX-License-Identifier: GPL-2.0
/*
 * MXFS -- publishing unpublished inodes and directories
 */
#define MXFS_TU_ID 22	/* igrab/iput call-site file id */
#include "xfs_mxfs_dlm_priv.h"
int mxfs_creator_baseline_stamp;
module_param_named(creator_baseline_stamp, mxfs_creator_baseline_stamp, int, 0644);
MODULE_PARM_DESC(creator_baseline_stamp,
	"stamp the dir staleness baselines when a self-created dir takes its first real EX grant (bit0=dir_valid_epoch, bit1=cached_grant_gen); 0=pre-fix sentinels");

/* ─── deferred-publish ─── */

/* the order inodes join m_mxfs_unpub_list: an AG release's drain takes only
 * the entries listed before it began (pub_drain_bound, xfs_mxfs_dlm.c) */
static atomic64_t	mxfs_unpub_seq_next = ATOMIC64_INIT(0);

/* Called under m_mxfs_unpub_lock. */
static void
mxfs_unpub_list_add(
	struct xfs_mount	*mp,
	struct xfs_inode	*ip)
{
	ip->i_mxfs_unpub_seq = atomic64_inc_return(&mxfs_unpub_seq_next);
	list_add_tail(&ip->i_dlm_unpub_link, &mp->m_mxfs_unpub_list);
}

/*
 * Grant a brand-new inode (XFS_IGET_CREATE) its DLM lock locally, with no
 * on-disk CAW.  The creator owns the inode exclusively (it is invisible to
 * peers until its parent dirent is durable AND its slot is published), so we
 * grant EX, mark CACHED, bump the holder for the lock the caller is taking,
 * and link it onto the per-mount unpublished list.  See header + design note.
 */
void
mxfs_dlm_grant_local_new(
	struct xfs_inode	*ip,
	uint8_t			mode)
{
	struct xfs_mount	*mp = ip->i_mount;

	spin_lock(&ip->i_dlm_lock);
	/* P77: this function OVERWRITES mode/state
	 * unconditionally.  If the struct is a REUSED in-core inode with
	 * live demote machinery (state DEMOTING/BAST, queued bast work,
	 * nonzero holders), the overwrite orphans that machinery — a
	 * candidate producer of run68's phantom-EX wedge.  Shout first. */
	if (ip->i_dlm_state != MXFS_DLM_ISTATE_NONE ||
	    ip->i_dlm_ex_holders || ip->i_dlm_pr_holders ||
	    ip->i_dlm_mode != MXFS_LOCK_NL) {
		static atomic_t p77_n = ATOMIC_INIT(0);
		if (atomic_inc_return(&p77_n) <= 3000)
			pr_warn("mxfs: P77-GRANTNEW-CLOBBER ino=%llu prev_mode=%u prev_state=%u prev_ex=%u prev_pr=%u pin=%u work_busy=%d comm=%s\n",
				(unsigned long long)ip->i_ino,
				ip->i_dlm_mode, ip->i_dlm_state,
				ip->i_dlm_ex_holders, ip->i_dlm_pr_holders,
				ip->i_dlm_pin_count,
				work_busy(&ip->i_dlm_bast_work),
				current->comm);
	}
	/* Creator-exclusive: hold EX regardless of the requested mode. */
	{ u8 dtr_om = ip->i_dlm_mode, dtr_os = ip->i_dlm_state;
	ip->i_dlm_mode = MXFS_LOCK_EX;
	mxfs_dlmtr_rec(ip, dtr_om, dtr_os, MXFS_SITE); }
	/* EX at the mode level, provably NOT durable — no CAS ever ran
	 * for this inode, there is no slot to prove anything with.  Becomes
	 * provable only when the lazy publish worker's own acquire result is
	 * installed (UNPUBLISHED_EX -> DURABLE_EX). */
	mxfs_inode_authority_note_unpublished_locked(ip, MXFS_SITE);
	/* (design review DLM-epoch guard): fresh EX tenure for a new inode. */
	mxfs_ex_epoch_churn_check(ip, MXFS_SITE);
	ip->i_mxfs_ex_grant_seq = atomic64_inc_return(&mxfs_ex_epoch);
	/* stamp fresh-EX acquire time for MHT batching */
	ip->i_dlm_ex_acquire_ns = ktime_get_ns();
	ip->i_dlm_tenure_ops = 0;
	ip->i_dlm_tenure_firstop_ns = 0;
	/*
	 *  — BASELINE THE STALENESS TRACKERS AT CREATE.
	 *
	 * PROVEN (32/caw dirent_durability, test29, in-window):
	 *   P195-STALE-BASE-ALREADY-DIRTY ino=27263105 grant_epoch=2 valid_epoch=0
	 *       grant_gen=2019 cached_gen=0 gen_moved=1 dirty_seq=359 ex_grant_seq=359
	 *
	 * This path creates an inode WITHOUT a real DLM acquire (deferred
	 * publish), and it stamped the tenure counter but left BOTH staleness
	 * baselines at their "never set" sentinel: i_dlm_cached_grant_gen = 0
	 * and i_dlm_dir_valid_epoch = 0.  Every detector that asks "has this
	 * lock changed hands / has a peer published since my base loaded?"
	 * compares against those, and several are explicitly gated on
	 * `cached_grant_gen != 0` — so for a directory THIS node created they
	 * are inert for the lifetime of the in-core inode, no matter how many
	 * times peers take the lock and modify it.  Above: the master is at
	 * generation 2019 and epoch 2 while our baselines still read 0/0.
	 *
	 * Consequence: the creator keeps a base that no guard will ever call
	 * stale, adds its own child to it, and the write-side backstop then
	 * (correctly) refuses to publish the behind-disk result — so the entry
	 * is dropped while mkdir(2) returned 0.  That is the silent-loss path.
	 *
	 *  /— THE STAMP CANNOT HAPPEN HERE.  Proven,
	 * not suspected, and the block that used to sit here is deleted:
	 *
	 *  1. It was DEAD.  The gate was S_ISDIR(VFS_I(ip)->i_mode), but the
	 *     only caller is xfs_iget_cache_miss under XFS_IGET_CREATE, where
	 *     i_mode is still 0 (xfs_init_new_inode sets it later, and even
	 *     i_generation is only assigned at xfs_icache.c:1902).  Probe
	 *     P209-CREATE-BASELINE, placed INSIDE the block, read 0 on every
	 *     node across a full 32-node dirent_durability run.
	 *  2. It could not have worked if reached.  This path creates the inode
	 *     WITHOUT a real DLM acquire (deferred publish), so the DLM has no
	 *     grant record for the number and both queries return 0 — the
	 *     `if (bgg)` / `if (bep)` guards skipped and the sentinels survived.
	 *  3. It was a latent sleep-in-atomic.  We are inside
	 *     spin_lock(&ip->i_dlm_lock) here (unlocked ~90 lines below), and
	 *     mxfs_v5_dlm_inode_grant_gen -> mxfs_dlm_caw_grant_seq32 ->
	 *     caw_grant_meta_seq takes a SLEEPING mutex (dlm/dlm_caw.c:1120).
	 *     Same class as the 2/tcp wedge.
	 *
	 * The baseline is established instead at the moment the values first
	 * EXIST — this node's first real EX grant for the inode, i.e. the
	 * publish — by mxfs_dlm_creator_baseline_query/_apply (sites 1-3).  See
	 * the mxfs_creator_baseline_stamp block comment for why that point is
	 * the only one where stamping cannot launder a peer update.
	 */
	{ u8 dtr_om = ip->i_dlm_mode, dtr_os = ip->i_dlm_state;
	ip->i_dlm_state = MXFS_DLM_ISTATE_CACHED;
	mxfs_dlmtr_rec(ip, dtr_om, dtr_os, MXFS_SITE); }
	if (mode == MXFS_LOCK_EX) {
		ip->i_dlm_ex_holders++; MXFS_DLMTR_H(ip);
		mxfs_exh_stamp_locked(ip);
	} else {
		ip->i_dlm_pr_holders++; MXFS_DLMTR_H(ip);
	}
	spin_unlock(&ip->i_dlm_lock);

	/* v0.5.4 fresh cache-miss create — no peer can hold a stale
	 * reference to this ino's incarnation (see i_mxfs_reused_create). */
	ip->i_mxfs_reused_create = false;

	spin_lock(&mp->m_mxfs_unpub_lock);
	if (!ip->i_dlm_unpublished) {
		ip->i_dlm_unpublished = true;
		/* v0.5.6: parent unknown until xfs_create/xfs_symlink records
		 * it post-dirent; 0 = matched by every scoped BAST drain. */
		ip->i_mxfs_unpub_parent = 0;
		mxfs_unpub_list_add(mp, ip);
	}
	spin_unlock(&mp->m_mxfs_unpub_lock);

	mxfs_idbg("mxfs: deferred-publish GRANT-LOCAL ino=%llu mode=%u\n",
		(unsigned long long)ip->i_ino, mode);
}

/*
 * ROOT FIX (cross_write_read empty-md5, PROVEN BY INSTRUMENT via
 * P128-PUBLISH-BAIL + P103-RELOAD-REUSE-ADOPT): re-arm deferred-publish for a
 * CREATE that was satisfied from the inode CACHE (recycle of an IRECLAIMABLE
 * freed incarnation, reset_inode_for_create of a live stale one, or a freed
 * mode==0 cache hit).  Those inodes keep the PRIOR incarnation's DLM fields:
 * i_dlm_mode=EX with i_dlm_unpublished=false — but the prior incarnation's
 * on-disk slot was RELEASED by xfs_inactive at free time.  The new create then
 * runs on a PHANTOM in-core EX: mxfs_dlm_publish_inode fast-bails on the clear
 * unpub flag, no slot is ever acquired, a peer's acquire of the reused number
 * grants CLEAN (empty slot, no BAST), and the creator is never forced to flush
 * the new dinode → the peer adopts it at its not-yet-durable size=0 image
 * (readers see an existing file as empty).
 *
 * Restore the brand-new-inode invariant (creator-exclusive local EX, on the
 * unpublished list) exactly as mxfs_dlm_grant_local_new does for cache-miss
 * creates — WITHOUT touching the holder counts (the caller's xfs_ilock
 * accounts those normally).  xfs_create's publish-on-create then acquires the
 * real slot.  A peer that meanwhile holds a (stale) slot on this number is
 * BASTed by that EX acquire and invalidates — also coherent.
 */
void
mxfs_dlm_rearm_unpublished(
	struct xfs_inode	*ip)
{
	struct xfs_mount	*mp = ip->i_mount;
	bool			rearmed = false;

	/* 0.83.3 (D-0955) / 0.87.16: every mount's recycled-number create gets
	 * its unpublished-EX tenure like any member's -- a membership early-out
	 * here left s583c's directory at NL with the dead peer's stale mark,
	 * and a never-multi one left every lone mount's inode without the
	 * authority its logged images need at replay. */
	if (!mp->m_mxfs_dlm)
		return;

	spin_lock(&ip->i_dlm_lock);
	if (ip->i_dlm_mode != MXFS_LOCK_EX)
		{ u8 dtr_om = ip->i_dlm_mode, dtr_os = ip->i_dlm_state;
		ip->i_dlm_mode = MXFS_LOCK_EX;
		mxfs_dlmtr_rec(ip, dtr_om, dtr_os, MXFS_SITE); }
	/* a re-armed unpublished incarnation is local-only EX — see
	 * mxfs_dlm_grant_local_new.  Any tenure the PREVIOUS incarnation of
	 * this inode number proved is dead here. */
	mxfs_inode_authority_note_unpublished_locked(ip, MXFS_SITE);
	/* Fresh incarnation = fresh EX tenure (epoch guard). */
	mxfs_ex_epoch_churn_check(ip, MXFS_SITE);
	ip->i_mxfs_ex_grant_seq = atomic64_inc_return(&mxfs_ex_epoch);
	ip->i_dlm_ex_acquire_ns = ktime_get_ns();
	ip->i_dlm_tenure_ops = 0;
	ip->i_dlm_tenure_firstop_ns = 0;
	/* Don't clobber a pending BAST downconvert on a real prior slot. */
	if (ip->i_dlm_state == MXFS_DLM_ISTATE_NONE)
		{ u8 dtr_om = ip->i_dlm_mode, dtr_os = ip->i_dlm_state;
		ip->i_dlm_state = MXFS_DLM_ISTATE_CACHED;
		mxfs_dlmtr_rec(ip, dtr_om, dtr_os, MXFS_SITE); }
	spin_unlock(&ip->i_dlm_lock);

	/* v0.5.4 reused in-core incarnation — peers may still name
	 * this ino from the prior incarnation; keep the synchronous
	 * unpublished-EX backstop armed (see i_mxfs_reused_create). */
	ip->i_mxfs_reused_create = true;

	/* Option B: cache-hit CREATE = new incarnation — drop the prior
	 * life's dir-base baseline so the publish stamp (creator sites) can
	 * establish a fresh one (see the reset_inode_for_create sibling). */
	if (mxfs_dir_adopt_at_acquire) {
		ip->i_dlm_dir_valid_epoch = 0;
		ip->i_dlm_dir_valid_incarn = 0;
		WRITE_ONCE(ip->i_dlm_base_valid, 0);
		ip->i_dlm_creator_base_state = MXFS_CBASE_UNSET;
	}

	spin_lock(&mp->m_mxfs_unpub_lock);
	if (!ip->i_dlm_unpublished) {
		ip->i_dlm_unpublished = true;
		/* v0.5.6: parent unknown until xfs_create/xfs_symlink records
		 * it post-dirent; 0 = matched by every scoped BAST drain. */
		ip->i_mxfs_unpub_parent = 0;
		mxfs_unpub_list_add(mp, ip);
		rearmed = true;
	}
	spin_unlock(&mp->m_mxfs_unpub_lock);

	if (rearmed)
		mxfs_probe_ratelimited(
		    "mxfs: P128-REARM-UNPUB ino=%llu dlm_mode=%u -- cache-hit CREATE on reused inode, deferred-publish re-armed\n",
			(unsigned long long)ip->i_ino, ip->i_dlm_mode);
}

/*
 * Remove an inode from the unpublished list and clear the flag.  Returns true
 * if the inode WAS unpublished (caller must NOT do an on-disk release — there
 * is no slot).  Safe no-op (returns false) if not unpublished.
 */
bool
mxfs_dlm_unpublish_drop(
	struct xfs_inode	*ip)
{
	struct xfs_mount	*mp = ip->i_mount;
	bool			was;

	if (!mp->m_mxfs_dlm)
		return false;

	spin_lock(&mp->m_mxfs_unpub_lock);
	was = ip->i_dlm_unpublished;
	if (was) {
		list_del_init(&ip->i_dlm_unpub_link);
		ip->i_dlm_unpublished = false;
		WRITE_ONCE(ip->i_mxfs_unpub_clr_line, MXFS_SITE);
	}
	spin_unlock(&mp->m_mxfs_unpub_lock);
	return was;
}

/*
 * Publish (acquire a real on-disk EX slot for) every inode on the unpublished
 * list.  Called from a peer BAST (inode or AG): the peer is blocked on the
 * lock that BAST'd us and cannot reach any of our locally-granted inodes until
 * we release it; we publish them all first so the peer's subsequent ilock of
 * each one BASTs us and we flush its data before the peer reads it.
 *
 * We publish BY INODE NUMBER (read under the list lock), so the ip pointer is
 * never dereferenced after the lock is dropped — no UAF vs concurrent reclaim.
 * A racing reclaim either (a) drops the inode first (we skip it; its data is
 * durable, peer reads disk) or (b) loses the claim race and later releases the
 * slot we acquired (peer reads durable disk).  Both outcomes are coherent.
 */
/*
 * v0.5.6: scope predicate for the BAST-side
 * publish drain.  A peer blocked on the lock we are releasing can reach
 * an unpublished inode only by (a) reading the released DIRECTORY's
 * dirents and chasing a child ino — covered by the parent_ino scope —
 * or (b) walking the released AG's AGI/inobt (inode alloc, bulkstat) —
 * covered by the agno scope.  Entries whose parent is unrecorded
 * (parent == 0: tmpfile, whiteout, or the tiny window between
 * grant_local_new and xfs_create's assignment) match EVERY scope, so a
 * missed assignment degrades to over-publishing, never to the
 * peer-acquires-empty-slot hole.  Called under m_mxfs_unpub_lock.
 */
static bool
mxfs_dlm_unpub_in_scope(
	struct xfs_mount	*mp,
	struct xfs_inode	*ip,
	xfs_ino_t		parent_ino,
	xfs_agnumber_t		agno)
{
	if (ip->i_mxfs_unpub_parent == 0) {
		/*
		 * H-F13: an AG release's scope is what the AG's own structures
		 * can surface, and a parent-unknown inode of another AG is not
		 * among it -- every directory's drain still matches it.  With
		 * ag_ialloc_fence on, the creates the fence sends to the
		 * node's other AGs no longer feed this AG's drain.
		 */
		if (parent_ino == 0 && agno != NULLAGNUMBER &&
		    READ_ONCE(mxfs_ag_ialloc_fence))
			return XFS_INO_TO_AGNO(mp, ip->i_ino) == agno;
		return true;
	}
	if (parent_ino != 0 && ip->i_mxfs_unpub_parent == parent_ino)
		return true;
	if (agno != NULLAGNUMBER &&
	    XFS_INO_TO_AGNO(mp, ip->i_ino) == agno)
		return true;
	return false;
}

/*
 * D-FREED-INODE-HOME-NEVER-PUBLISHED-LIVE-CORE-AFTER-CLEAN-UNMOUNT, H-F10.  A
 * publish that takes an inode off the unpublished list before claiming it
 * leaves the inode neither unpublished nor granted until the claim returns.
 * The BAST-side drain below may do that only because the peer whose BAST it
 * serves waits for the whole drain, which shields the inodes that peer can
 * reach through the released lock and no others.  An inode whose parent is
 * not yet recorded is in every drain's scope, so the drain of an unrelated
 * lock can take it, and its real parent's release then finds nothing listed
 * to publish.  Measured on the H-F9 fix lap zmf1 (test2, ino 10485895): the
 * BAST drain of the peer's directory took the new file while its creator was
 * still inside the create; the creator ended its own directory's tenure 0.8
 * ms before that claim landed, and the file logged four changes at no grant
 * (P-LOG-MIRROR-PHANTOM unpub_clr=22:583).  Every take-then-claim publish
 * keeps the inode on m_mxfs_pubclaim_list while its claim is in flight, so a
 * directory or AG release can see the claims in its scope.
 */
static atomic64_t	mxfs_pubclaim_next = ATOMIC64_INIT(0);

/* Under m_mxfs_unpub_lock, at the take.  Returns the claim's token, 0 if the
 * inode is being reclaimed (i_ino 0) or is already tracked. */
static u64
mxfs_pubclaim_begin_locked(
	struct xfs_mount	*mp,
	struct xfs_inode	*ip)
{
	if (ip->i_ino == 0 || !list_empty(&ip->i_mxfs_pubclaim_link))
		return 0;
	ip->i_mxfs_pubclaim_seq = atomic64_inc_return(&mxfs_pubclaim_next);
	ip->i_mxfs_pubclaim_ns = ktime_get_ns();
	list_add_tail(&ip->i_mxfs_pubclaim_link, &mp->m_mxfs_pubclaim_list);
	return ip->i_mxfs_pubclaim_seq;
}

/* The claim carrying `seq` returned (or was not made): it leaves the list.
 * Found by token, never by pointer: reclaim may have freed the inode and
 * removed it first. */
void
mxfs_pubclaim_end(
	struct xfs_mount	*mp,
	u64			seq)
{
	struct xfs_inode	*ip;
	bool			found = false;

	if (!seq)
		return;
	spin_lock(&mp->m_mxfs_unpub_lock);
	list_for_each_entry(ip, &mp->m_mxfs_pubclaim_list,
			    i_mxfs_pubclaim_link) {
		if (ip->i_mxfs_pubclaim_seq == seq) {
			list_del_init(&ip->i_mxfs_pubclaim_link);
			found = true;
			break;
		}
	}
	spin_unlock(&mp->m_mxfs_unpub_lock);
	if (found)
		wake_up_all(&mp->m_mxfs_pubclaim_wq);
}

/* The inode is about to be freed (reclaim, or a failed create's teardown): a
 * claim still tracked on it leaves now, whatever its claimant does later. */
void
mxfs_pubclaim_drop(
	struct xfs_inode	*ip)
{
	struct xfs_mount	*mp = ip->i_mount;
	bool			was;

	spin_lock(&mp->m_mxfs_unpub_lock);
	was = !list_empty(&ip->i_mxfs_pubclaim_link);
	if (was)
		list_del_init(&ip->i_mxfs_pubclaim_link);
	spin_unlock(&mp->m_mxfs_unpub_lock);
	if (was)
		wake_up_all(&mp->m_mxfs_pubclaim_wq);
}

/*
 * The ilock backstop's take (xfs/xfs_mxfs_ilock.c): mxfs_dlm_unpublish_drop
 * plus the claim's tracking, in one critical section.  The token is kept on
 * the inode (i_mxfs_pubclaim_bseq) for the acquiring thread, which holds a
 * reference, to end once its acquire returns.  Returns whether the inode was
 * unpublished.
 */
bool
mxfs_dlm_unpublish_take(
	struct xfs_inode	*ip)
{
	struct xfs_mount	*mp = ip->i_mount;
	bool			was;

	if (!mp->m_mxfs_dlm)
		return false;

	spin_lock(&mp->m_mxfs_unpub_lock);
	was = ip->i_dlm_unpublished;
	if (was) {
		list_del_init(&ip->i_dlm_unpub_link);
		ip->i_dlm_unpublished = false;
		WRITE_ONCE(ip->i_mxfs_unpub_clr_line, MXFS_SITE);
		ip->i_mxfs_pubclaim_bseq = mxfs_pubclaim_begin_locked(mp, ip);
	}
	spin_unlock(&mp->m_mxfs_unpub_lock);
	return was;
}

/* Under m_mxfs_unpub_lock: the first claim in flight in this release's scope. */
static struct xfs_inode *
mxfs_pubclaim_inscope_locked(
	struct xfs_mount	*mp,
	xfs_ino_t		parent_ino,
	xfs_agnumber_t		agno)
{
	struct xfs_inode	*ip;

	list_for_each_entry(ip, &mp->m_mxfs_pubclaim_list,
			    i_mxfs_pubclaim_link)
		if (mxfs_dlm_unpub_in_scope(mp, ip, parent_ino, agno))
			return ip;
	return NULL;
}

static bool
mxfs_pubclaim_inscope(
	struct xfs_mount	*mp,
	xfs_ino_t		parent_ino,
	xfs_agnumber_t		agno)
{
	bool			any;

	spin_lock(&mp->m_mxfs_unpub_lock);
	any = mxfs_pubclaim_inscope_locked(mp, parent_ino, agno) != NULL;
	spin_unlock(&mp->m_mxfs_unpub_lock);
	return any;
}

/*
 * A directory or AG release is about to go to a peer.  With a claim in its
 * scope in flight, pub_claim_release_guard 1 waits for it within the drain's
 * own window; 0 (the same-build control) lets the release go.  A release
 * whose own drain timed out goes as it did before (that timeout breaks a
 * cross-node BAST cycle) and is counted.  A release of a regular file exposes
 * no child and is not checked.
 */
static void
mxfs_pubclaim_release_check(
	struct xfs_mount	*mp,
	xfs_ino_t		parent_ino,
	xfs_agnumber_t		agno,
	bool			drain_timed_out)
{
	extern int		mxfs_pub_claim_release_guard;
	extern atomic_t		mxfs_pub_claim_inflight_rel;
	extern atomic_t		mxfs_pub_claim_rel_waited;
	static atomic_t		p_pcir_n = ATOMIC_INIT(0);
	struct xfs_inode	*ip, *cip;
	xfs_ino_t		cino = 0, cparent = 0, oino = 0;
	s64			age_us = 0, oage_us = 0, a;
	u64			t0 = 0, now;
	unsigned int		ninscope = 0;
	int			guard = READ_ONCE(mxfs_pub_claim_release_guard);
	const char		*outcome;

	if (parent_ino == 0 && agno == NULLAGNUMBER)
		return;
	spin_lock(&mp->m_mxfs_unpub_lock);
	ip = mxfs_pubclaim_inscope_locked(mp, parent_ino, agno);
	if (ip) {
		cino = ip->i_ino;
		cparent = ip->i_mxfs_unpub_parent;
		now = ktime_get_ns();
		age_us = (s64)(now - ip->i_mxfs_pubclaim_ns) / 1000;
		/* every in-scope claim, and the oldest: a drain-timeout
		 * release names whether its own stuck claim is among them */
		list_for_each_entry(cip, &mp->m_mxfs_pubclaim_list,
				    i_mxfs_pubclaim_link) {
			if (!mxfs_dlm_unpub_in_scope(mp, cip, parent_ino,
						     agno))
				continue;
			ninscope++;
			a = (s64)(now - cip->i_mxfs_pubclaim_ns) / 1000;
			if (a > oage_us) {
				oage_us = a;
				oino = cip->i_ino;
			}
		}
	}
	spin_unlock(&mp->m_mxfs_unpub_lock);
	if (!ip)
		return;

	if (guard && !drain_timed_out) {
		t0 = ktime_get_ns();
		wait_event_timeout(mp->m_mxfs_pubclaim_wq,
				   !mxfs_pubclaim_inscope(mp, parent_ino, agno),
				   msecs_to_jiffies(MXFS_PUB_DRAIN_TIMEOUT_MS));
	}
	if (t0 && !mxfs_pubclaim_inscope(mp, parent_ino, agno)) {
		atomic_inc(&mxfs_pub_claim_rel_waited);
		outcome = "waited";
	} else {
		atomic_inc(&mxfs_pub_claim_inflight_rel);
		outcome = drain_timed_out ? "drain-timeout" :
			  guard ? "escaped" : "proceeded";
	}
	if (atomic_inc_return(&p_pcir_n) <= 2000)
		pr_warn("mxfs: P-PUB-CLAIM-INFLIGHT-AT-RELEASE parent=%llu agno=%d child=%llu child_parent=%llu age_us=%lld wait_us=%lld guard=%d outcome=%s inscope=%u oldest=%llu oldest_age_us=%lld comm=%s -- a release in whose scope a publish claim was in flight: that inode is neither unpublished nor granted until the claim returns\n",
			(unsigned long long)parent_ino,
			agno == NULLAGNUMBER ? -1 : (int)agno,
			(unsigned long long)cino, (unsigned long long)cparent,
			age_us, t0 ? (s64)(ktime_get_ns() - t0) / 1000 : 0,
			guard, outcome, ninscope,
			(unsigned long long)oino, oage_us, current->comm);
}

/*
 * v0.5.5: pop-and-claim loop shared by the
 * inline drain and the parallel drain workers.  Pops one inode at a
 * time off m_mxfs_unpub_list (clear-then-acquire — safe here because
 * every caller of mxfs_dlm_publish_unpublished holds the peer blocked
 * on the BAST'd lock until the whole drain returns) and claims its
 * on-disk EX slot.  Safe to run concurrently from several workers:
 * each list entry is popped exactly once under m_mxfs_unpub_lock.
 * v0.5.6: pops only IN-SCOPE entries (see mxfs_dlm_unpub_in_scope) —
 * the 16-node whole-list drain (~8.7k claims/node, ~96k cluster-wide
 * vs the 65536-slot table) ground releases into minutes and starved
 * EX waiters into 120s timeouts (scaling_curve root cause 2).
 */
/*
 * FIX-I durability settle for one unpublished child (extracted from
 * the drain loop's pre_mode!=EX branch so the routed pre-pass in
 * mxfs_dlm_publish_unpublished can reuse it): make the child's inode-
 * cluster buffer platter-durable before a dir handoff exposes its name,
 * so a peer's clean grant cannot FUA-read a pre-icreate platter image.
 * Local and bounded (log_force + settle poll); takes no DLM locks.
 */
static void
mxfs_dlm_unpub_child_settle(
	struct xfs_mount	*mp,
	xfs_ino_t		ino)
{
{
	extern int xfs_imap(struct xfs_perag *,
			struct xfs_trans *, xfs_ino_t,
			struct xfs_imap *, uint);
	struct xfs_perag *fi_pag = xfs_perag_get(mp,
			XFS_INO_TO_AGNO(mp, ino));
	struct xfs_imap	fi_imap;
	struct xfs_buf	*fi_bp = NULL;

	memset(&fi_imap, 0, sizeof(fi_imap));
	if (fi_pag &&
	    xfs_imap(fi_pag, NULL, ino, &fi_imap, 0) == 0 &&
	    fi_imap.im_len &&
	    xfs_buf_incore(mp->m_ddev_targp,
			   fi_imap.im_blkno,
			   fi_imap.im_len,
			   XBF_TRYLOCK, &fi_bp) == 0 &&
	    fi_bp) {
		struct xfs_buf_log_item *fi_bip =
				fi_bp->b_log_item;
		bool fi_dirty =
		    (fi_bp->b_flags & _XBF_DELWRI_Q) ||
		    xfs_buf_ispinned(fi_bp) ||
		    (fi_bip &&
		     (test_bit(XFS_LI_DIRTY,
			&fi_bip->bli_item.li_flags) ||
		      test_bit(XFS_LI_IN_AIL,
			&fi_bip->bli_item.li_flags))) ||
		    !list_empty_careful(
			&fi_bp->b_li_list);

		if (fi_dirty) {
			int fi_i;

			/* incore's hold survives the
			 * unlock; the flusher needs
			 * the lock */
			xfs_buf_unlock(fi_bp);
			xfs_log_force(mp, XFS_LOG_SYNC);
			xfs_ail_push_all(mp->m_ail);
			for (fi_i = 0; fi_i < 125; fi_i++) {
				fi_bip = fi_bp->b_log_item;
				if (!(fi_bp->b_flags &
				      (_XBF_DELWRI_Q |
				       XBF_WRITE)) &&
				    !xfs_buf_ispinned(fi_bp) &&
				    (!fi_bip ||
				     !test_bit(XFS_LI_IN_AIL,
				       &fi_bip->bli_item.li_flags)))
					break;
				if (fi_i % 25 == 24)
					xfs_ail_push_all(mp->m_ail);
				msleep(2);
			}
			{
				static atomic_t p15j_n =
					ATOMIC_INIT(0);
				if (atomic_inc_return(&p15j_n) <= 400)
					mxfs_probe("mxfs: P15J-PUBSKIP-FLUSH ino=%llu daddr=%lld waited_ms=%d settled=%d -- evicted-unpublished child made durable before dir handoff\n",
						(unsigned long long)ino,
						(long long)fi_imap.im_blkno,
						fi_i * 2,
						fi_i < 125 ? 1 : 0);
			}
			xfs_buf_rele(fi_bp);
		} else {
			xfs_buf_relse(fi_bp);
		}
	}
	if (fi_pag)
		xfs_perag_put(fi_pag);
}
}

/*
 *  — CREATOR BASELINE STAMP (see mxfs_creator_baseline_stamp).
 *
 * Two entry points, because the publish sites differ in what they may do:
 *
 *  _query()  — SLEEPS.  Reads the DLM's post-claim epoch/grant-gen for `ino`.
 *              Both queries bottom out in caw_grant_meta_get/caw_grant_meta_seq,
 *              which take ctx->grant_meta_lock (a SLEEPING mutex, dlm_caw.c:1120).
 *              Call ONLY from sleepable context, never under a spinlock — the
 *              2/tcp wedge was exactly this shape (sleeping rwsem under
 *              pag_ici_lock).
 *  _apply()  — pure stores, no query, no allocation.  Safe under a spinlock, so
 *              a publish site that must stamp while holding m_mxfs_unpub_lock
 *              can hoist the _query() above the lock and apply inside it.
 *
 * The eligibility test lives in _apply() so every site enforces it identically.
 * i_mxfs_self_created is the load-bearing guard: it is set only by xfs_create's
 * success path and cleared by mxfs_dlm_bast_notify on the FIRST peer BAST, so
 * while it holds, no peer has requested this inode's lock and therefore no peer
 * can have published anything we could launder away.
 *
 * The stamped fields are not covered by ip->i_dlm_lock at their other write
 * sites either (the fast-path stamps at mxfs_dlm_ilock_begin and the adopt
 * stamp in mxfs_dlm_reload_inode both run after spin_unlock); they are tenure-
 * protected.  Here the inode is still unpublished and self-created, so this
 * node is the only possible writer.
 */
static void
mxfs_dlm_creator_baseline_apply(
	struct xfs_inode	*ip,
	uint32_t		bep,
	uint32_t		bgg,
	unsigned int		site)
{
	uint32_t		old_ep, old_gg;

	if (!ip || ip->i_ino == 0)
		return;
	if (!S_ISDIR(VFS_I(ip)->i_mode))
		return;
	/* A peer BAST would have cleared this; without it we cannot claim the
	 * in-core image is the authoritative successor. */
	if (!ip->i_mxfs_self_created)
		return;
	/* Only the never-established state is ours to fill.  A real adopt or a
	 * slow-path grant has already recorded a meaningful baseline; never
	 * overwrite one — that IS the laundering case.  Tracked as an EXPLICIT
	 * state rather than "the number is still 0" (design review's prescription):
	 * a legitimate baseline of epoch 0 is reachable, and inferring "never
	 * set" from the value cannot tell the two apart.
	 *
	 * i_dlm_cached_grant_gen is deliberately NOT part of this precondition.
	 * Measured 2/caw this session: a self-created dir can reach P195 with
	 * cached_gen=27 and valid_epoch=0 — the dir-EX fast path stamps the
	 * grant gen (mxfs_dlm_ilock_begin) independently of the epoch, so
	 * requiring both to be 0 would refuse the stamp in exactly the case
	 * that still loses the dirent. */
	if (ip->i_dlm_creator_base_state != MXFS_CBASE_UNSET)
		return;
	if (ip->i_dlm_dir_valid_epoch != 0)
		return;

	old_ep = ip->i_dlm_dir_valid_epoch;
	old_gg = ip->i_dlm_cached_grant_gen;
	/* State advances in BOTH arms — SEEN when the knob is off — so the probe
	 * below is a KNOB-INDEPENDENT exposure counter that fires exactly once
	 * per eligible inode in either arm.  A fix-gated exposure counter makes
	 * the reproducing arm report zero exposure, which is how first
	 * typeflip A/B nearly produced an unfalsifiable "pass". */
	if (mxfs_dir_adopt_at_acquire) {
		/*
		 * Option B (design review contract item 6) — the creator stamp is
		 * SUBORDINATED to the adopt-at-acquire machinery: at the first
		 * real EX grant of a self-created dir the in-core image is the
		 * authoritative successor (self_created still set = no peer has
		 * even requested the lock), so stamping (epoch, gen, valid) here
		 * is what makes the acquire gate's != compares meaningful — and
		 * what stops the gate's sentinel leg from adopting a
		 * not-yet-destaged disk image over the live create at the first
		 * fast-path serve.  mxfs.creator_baseline_stamp remains the A/B
		 * lever for the gate-off arm only.
		 */
		ip->i_dlm_creator_base_state = MXFS_CBASE_VALID;
		mxfs_dir_base_stamp(ip, bep, bgg, site);
	} else if (mxfs_creator_baseline_stamp) {
		ip->i_dlm_creator_base_state = MXFS_CBASE_VALID;
		if (mxfs_creator_baseline_stamp & MXFS_CBS_EPOCH) {
			ip->i_dlm_dir_valid_epoch = bep;
			ip->i_dlm_dir_valid_incarn = VFS_I(ip)->i_generation;
		}
		if (mxfs_creator_baseline_stamp & MXFS_CBS_GRANTGEN)
			ip->i_dlm_cached_grant_gen = bgg;
	} else {
		ip->i_dlm_creator_base_state = MXFS_CBASE_SEEN;
	}

	{
		static atomic_t p210n = ATOMIC_INIT(0);

		if (atomic_inc_return(&p210n) <= 600)
			mxfs_probe("mxfs: P210-CREATOR-BASELINE ino=%llu site=%u bep=%u bgg=%u old_ep=%u old_gg=%u mask=%d state=%u -- self-created dir reached its first real EX grant\n",
				(unsigned long long)ip->i_ino, site,
				bep, bgg, old_ep, old_gg,
				mxfs_creator_baseline_stamp,
				ip->i_dlm_creator_base_state);
	}
}

/* SLEEPS — see the block comment above. */
void
mxfs_dlm_creator_baseline_query(
	struct xfs_inode	*ip,
	unsigned int		site)
{
	struct mxfs_v5_dlm	*dlm;
	uint32_t		bep, bgg;

	if (!ip || ip->i_ino == 0 || !ip->i_mount)
		return;
	dlm = ip->i_mount->m_mxfs_dlm;
	if (!dlm || mxfs_v5_dlm_is_single_node(dlm))
		return;
	/* Cheap in-memory rejects before paying the grant_meta mutex.  These
	 * MUST mirror _apply's preconditions exactly, or the two arms pay
	 * different costs and the exposure counts stop being comparable. */
	if (!S_ISDIR(VFS_I(ip)->i_mode) || !ip->i_mxfs_self_created)
		return;
	if (ip->i_dlm_creator_base_state != MXFS_CBASE_UNSET)
		return;
	if (ip->i_dlm_dir_valid_epoch != 0)
		return;

	bep = mxfs_v5_dlm_inode_dir_epoch(dlm, ip->i_ino);
	bgg = mxfs_v5_dlm_inode_grant_gen(dlm, ip->i_ino);
	mxfs_dlm_creator_baseline_apply(ip, bep, bgg, site);
}

/*
 * The step a drain worker is in for its current child, recorded for the
 * drain's timeout report: a drain that runs out its window names the child
 * each unfinished worker is on and what it waits in (P-PUB-DRAIN-STUCK).
 */
#define MXFS_PUB_STEP_SETTLE	1	/* FS-layer EX gone: durability settle */
#define MXFS_PUB_STEP_DEMOTE	2	/* routed: the child's own demote pipeline */
#define MXFS_PUB_STEP_ICLUS	3	/* routed, live holder: cluster EX claim */
#define MXFS_PUB_STEP_EVICTED	4	/* routed, evicted: durability settle */
#define MXFS_PUB_STEP_CLAIM	5	/* the on-disk EX claim */

static inline void
mxfs_pub_drain_step(
	struct mxfs_pub_drain_worker	*w,
	xfs_ino_t			ino,
	int				step)
{
	WRITE_ONCE(w->cur_phase, step);
	WRITE_ONCE(w->cur_ns, ktime_get_ns());
	WRITE_ONCE(w->cur_ino, ino);
}

/*
 * D-SURVIVOR-DEFERRED-PUBLISH-EX-CLAIM-FAILS-AFTER-60-REMASTER-RETRIES-AT-REJOIN.
 * The non-routed arm's on-disk EX claim can fail after the pop has cleared
 * i_dlm_unpublished: on 2/net/mesh/mpath, after a fenced peer rejoined, a
 * full ledger page answered every one of the claim's 60 retries
 * (why[capacity=60]) and the claim returned -EAGAIN.  The arm only logged it,
 * so the child kept its local-only EX with no grant behind it and sat on no
 * list: a peer that sees its name can be granted it cleanly and read the
 * platter before the child is written, while this node goes on writing it
 * under an EX nobody else knows of.
 *
 * The claim cannot be given up and the child cannot be demoted instead: its
 * live core may not go home without a grant (pub_claim_write_guard masks it
 * while the claim is in flight, because a peer may still hold the number's
 * previous life).  So 1 (default): a claim answered -EAGAIN (its retry budget
 * spent on RETRY answers) stays in flight and is asked again, with backoff,
 * until it is granted, the filesystem shuts down or unmounts, or it fails
 * otherwise -- as the inode lock parks and asks again instead of failing.
 * While it waits on a full page the master keeps its place in the child's
 * queue (dl_capacity_park), so a peer that asks for the child after the
 * drain window ends queues behind the claim instead of being granted first.
 * 0 = the same-build control: the failure is only logged.
 * dbg_pub_claim_fail_ino (TEST ONLY): the first claim attempt of that inode
 * fails with -EAGAIN without asking the lock layer, the state a claim that
 * ran out its retries is in; the switch clears itself when it fires.
 */
int mxfs_pub_claim_retry = 1;
static atomic_t mxfs_pub_claim_retry_n = ATOMIC_INIT(0);
static unsigned long long mxfs_dbg_pub_claim_fail_ino;
module_param_named(pub_claim_retry, mxfs_pub_claim_retry, int, 0644);
MODULE_PARM_DESC(pub_claim_retry,
	"a deferred-publish EX claim answered -EAGAIN stays in flight and is asked again until granted (1, default); 0 = the failure is only logged (test control)");
module_param_named(pub_claim_retry_n, mxfs_pub_claim_retry_n.counter, int,
		   0444);
MODULE_PARM_DESC(pub_claim_retry_n,
	"deferred-publish claims asked again after an -EAGAIN since load");
module_param_named(dbg_pub_claim_fail_ino, mxfs_dbg_pub_claim_fail_ino,
		   ullong, 0644);
MODULE_PARM_DESC(dbg_pub_claim_fail_ino,
	"TEST ONLY: the first deferred-publish EX claim attempt of this inode fails with -EAGAIN without asking the lock layer; cleared when it fires (0 = off)");

static unsigned int
mxfs_dlm_publish_drain_loop(
	struct xfs_mount	*mp,
	xfs_ino_t		parent_ino,
	xfs_agnumber_t		agno,
	struct mxfs_pub_drain_worker *w)
{
	xfs_ino_t		*seen_defer = w->seen_defer;	/* MXFS_PUB_SEEN_DEFER_MAX */
	struct mxfs_v5_dlm	*dlm = mp->m_mxfs_dlm;
	struct xfs_inode	*ip, *match;
	uint64_t		ino;
	unsigned int		n = 0;
	int			rc;
	/* inos this drain already deferred (live holder + failed
	 * claim).  Without the guard the relist->re-pop cycle busy-spins the
	 * drain worker (measured: 146s soft lockup on kworker/u11:18 while
	 * dir 131's handoff sat inside this loop and peers BAST-stormed). */
	unsigned int		n_defer = 0, di;
	/* step 5.3(d): provenance of the fallback cluster claim. */
	struct mxfs_grant_result pub_gres;
	uint64_t		pub_gen_snap = MXFS_AUTH_GEN_NONE;

	for (;;) {
		uint8_t		pre_mode = MXFS_LOCK_EX;
		uint8_t		pre_state = MXFS_DLM_ISTATE_CACHED;
		bool		pub_routed = false;
		u64		claim_seq = 0;	/* H-F10: this take's tracking */

		ino = 0;
		match = NULL;
		spin_lock(&mp->m_mxfs_unpub_lock);
		list_for_each_entry(ip, &mp->m_mxfs_unpub_list,
				    i_dlm_unpub_link) {
			bool deferred = false;

			if (!mxfs_dlm_unpub_in_scope(mp, ip, parent_ino, agno))
				continue;
			/* H-F12: listed after this drain began */
			if (ip->i_mxfs_unpub_seq > w->seq_limit)
				continue;
			for (di = 0; di < n_defer; di++)
				if (seen_defer[di] == ip->i_ino) {
					deferred = true;
					break;
				}
			if (deferred)
				continue;
			match = ip;
			break;
		}
		if (match) {
			list_del_init(&match->i_dlm_unpub_link);
			match->i_dlm_unpublished = false;
			WRITE_ONCE(match->i_mxfs_unpub_clr_line, MXFS_SITE);
			ino = match->i_ino;
			claim_seq = mxfs_pubclaim_begin_locked(mp, match);
			/* P78: snapshot FS-layer lock state while the
			 * entry is provably alive (on-list under the lock).
			 * ICLUSTER: routability snapshotted here too — match
			 * may be freed once the spinlock drops. */
			pub_routed = mxfs_iclus_routed(match);
			if (pub_routed)
				/* the claim below is cluster-backed; the
				 * inode's release must route there too */
				match->i_dlm_routed_iclus = true;
			pre_mode = match->i_dlm_mode;
			pre_state = match->i_dlm_state;
		}
		spin_unlock(&mp->m_mxfs_unpub_lock);

		if (!match)
			break;
		if (ino == 0)
			continue;	/* reclaiming; disk durable, skip */

		/*
		 * FIX-28 — the P78 probe promoted to a guard.
		 * The publish exists to close the 16057 hazard: an UNPUBLISHED
		 * inode whose FS layer holds a live cached EX is invisible to
		 * the DLM, so a peer acquires it cleanly and both modify.  That
		 * hazard exists ONLY while the FS-layer mode is still EX.  When
		 * the pop-time snapshot shows the EX is already gone (released,
		 * demoted, evicted, or the number reused), claiming a master EX
		 * anyway creates a PHANTOM the FS layer never drives: run r4
		 * measured ~1000 such claims per node per suite (P78-PUB-PHANTOM),
		 * each a ghost holder that peers must break via the orphan-
		 * release path — grant delays, tds residual ghosts, and the
		 * dlm_scaling/fault setup-visibility flakes.  Skip the claim;
		 * a later re-acquire of the inode goes through the slow path
		 * (mode is not EX) which claims the on-disk lock properly.
		 */
		if (pre_mode != MXFS_LOCK_EX) {
			static atomic_t p78s_n = ATOMIC_INIT(0);
			if (atomic_inc_return(&p78s_n) <= 2000)
				mxfs_probe("mxfs: P78-PUB-SKIP ino=%llu pre_mode=%u pre_state=%u -- FS-layer EX gone; phantom master claim skipped\n",
					(unsigned long long)ino,
					pre_mode, pre_state);
			/*
			 * FIX-I (PROVEN BY INSTRUMENT, 2/tcp r6 ino
			 * 0x883400): the skipped child lost its EX via VFS
			 * EVICTION (crash_consistency's drop_caches) — its
			 * icreate/dinode state may still be dirty-unwritten
			 * (CIL, AIL, or a reclaim-queued delwri cluster buf)
			 * while the dirent naming it becomes peer-visible via
			 * THIS dir handoff.  With the slot never claimed, a
			 * peer's acquire grants CLEANLY (no BAST to us, no
			 * mirror — P74-GRANT absent) and its FUA read pulls
			 * the PRE-ICREATE platter: prior-mkfs dinodes → uuid
			 * verifier reject → EFSCORRUPTED → iget retry ladder
			 * loops on the same platter → EIO (durable-vs-visible
			 * invariant hole).  Make the child's cluster durable
			 * BEFORE the handoff returns: the peer is blocked on
			 * the BAST'd dir until then.  Bounded; fires only when
			 * the cluster is provably not yet durable.
			 */
			mxfs_pub_drain_step(w, ino, MXFS_PUB_STEP_SETTLE);
			mxfs_dlm_unpub_child_settle(mp, ino);
			/* H-F10: a release of this child's real parent waits
			 * for the settle as it would for a claim */
			mxfs_pubclaim_end(mp, claim_seq);
			mxfs_pub_drain_step(w, 0, 0);
			continue;
		}

		if (pub_routed) {
			/*
			 * EAGER-DEMOTE PUBLISH — the
			 * routed replacement for the cluster EX claim that
			 * stood here.  Instrumented history, all measured on the
			 * 8/cawd board:
			 *   1. The claim (mxfs_iclus_lock EX) remote-waited
			 *      on peer-held clusters FROM THE BAST PIPELINE
			 *      and closed a cross-node bast-worker cycle
			 *      (470s P-WAIT-EXTEND wedges).
			 *   2. Under reader-PR contention it EDEADLK-failed
			 *      AFTER the pop — child delisted, no on-disk
			 *      claim, local EX intact: peers then clean-grant
			 *      the cluster and FUA-read the pre-flush platter
			 *      (the cwr exp="" stale-read class).
			 * Claiming is the wrong primitive for a routed child:
			 * the CLUSTER is legitimately shared.  What the
			 * handoff actually requires is that the platter be
			 * AUTHORITATIVE for the child before its name is
			 * peer-visible.  So: run the child's OWN per-inode
			 * demote pipeline (full data writeback + durable
			 * dinode + local NL + iclus release sweep) right
			 * here, in the drain worker — local, bounded,
			 * contention-independent.  No claim exists to fail;
			 * no invisible EX survives; the reader's clean grant
			 * reads correct bytes.  A live local holder aborts
			 * the release (P15 re-check) — re-list, and
			 * ilock_end's pending-BAST demote + the next publish
			 * converge it.
			 */
			struct xfs_inode *dip = NULL;
			bool run_bp = false;

			mxfs_pub_drain_step(w, ino, MXFS_PUB_STEP_DEMOTE);
			if (xfs_iget(mp, NULL, ino, XFS_IGET_INCORE, 0,
				     &dip) == 0 && dip) {
				spin_lock(&dip->i_dlm_lock);
				dip->i_dlm_bast_pending = true;
				if (dip->i_dlm_demoter == NULL) {
					MXFS_SET_DEMOTER(dip);
					run_bp = true;
				}
				spin_unlock(&dip->i_dlm_lock);
				if (run_bp) {
					struct mxfs_dirdrain_task dde;

					mxfs_dirdrain_enter(&dde);
					mxfs_dlm_bast_process(dip);
					mxfs_dirdrain_exit(&dde);
					MXFS_CLEAR_DEMOTER(dip);
				}
				spin_lock(&dip->i_dlm_lock);
				if (dip->i_dlm_mode != MXFS_LOCK_NL) {
					static atomic_t ppedm_n =
						ATOMIC_INIT(0);
					int crc;

					spin_unlock(&dip->i_dlm_lock);
					/* Live local holder kept the grant —
					 * the demote cannot proceed.  Restore
					 * the OLD exclusion primitive for
					 * exactly this case: claim the
					 * cluster EX from THIS worker.  Safe
					 * now: the caller's batch wait
					 * is 5s-bounded, so a remote-waiting
					 * claim can no longer wedge the bast
					 * pipeline (it just lands late,
					 * detached).  On success the child is
					 * DLM-visible and peers BAST us as
					 * before. */
					/* fairness A/B: the claim
					 * fallback added EX pressure on the
					 * hottest cluster (fairness churns
					 * ONE shared cluster; every live-
					 * holder abort claimed it) — starved
					 * 2-3 nodes below 50 rounds.  The
					 * abort path already armed
					 * bast_pending, so the holder's
					 * ilock_end runs the full demote
					 * (durable + NL + sweep) within the
					 * op's remaining microseconds — the
					 * publish-equivalent, µs-deferred.
					 * Relist so the NEXT publish verifies
					 * convergence. */
					/* step 5.3(d), ruling coverage
					 * gap (i): this worker's OWN claim is
					 * the evidence that promotes the child
					 * from local-only EX to a durable
					 * tenure.  Snapshot the gen before the
					 * claim, install under i_dlm_lock. */
					pub_gen_snap = MXFS_AUTH_GEN_NONE;
					if (mxfs_pub_defer_claim) {
						spin_lock(&dip->i_dlm_lock);
						pub_gen_snap =
							dip->i_mxfs_auth_gen;
						spin_unlock(&dip->i_dlm_lock);
					}
					mxfs_pub_drain_step(w, ino,
							    MXFS_PUB_STEP_ICLUS);
					crc = mxfs_pub_defer_claim ?
						mxfs_iclus_lock(mp, ino,
							MXFS_LOCK_EX,
							&pub_gres) : -EAGAIN;
					if (crc == 0) {
						spin_lock(&dip->i_dlm_lock);
						mxfs_dlm_authority_install(dip,
							&pub_gres,
							pub_gen_snap, true,
							MXFS_SITE);
						spin_unlock(&dip->i_dlm_lock);
					}
					if (crc) {
						/* H-F10: off the in-flight list
						 * before it is listed again */
						mxfs_pubclaim_end(mp, claim_seq);
						claim_seq = 0;
						spin_lock(&mp->m_mxfs_unpub_lock);
						if (!dip->i_dlm_unpublished &&
						    dip->i_ino == ino) {
							dip->i_dlm_unpublished = true;
							dip->i_mxfs_unpub_parent =
								parent_ino;
							mxfs_unpub_list_add(mp, dip);
						}
						spin_unlock(&mp->m_mxfs_unpub_lock);
						if (n_defer <
						    MXFS_PUB_SEEN_DEFER_MAX)
							seen_defer[n_defer++] =
								ino;
					}
					if (atomic_inc_return(&ppedm_n) <= 400)
						mxfs_probe("mxfs: P-PUB-EDEMOTE-DEFER ino=%llu mode=%u ran=%d claim_rc=%d -- live holder kept the grant\n",
							(unsigned long long)ino,
							dip->i_dlm_mode,
							run_bp ? 1 : 0, crc);
					if (crc &&
					    n_defer >= MXFS_PUB_SEEN_DEFER_MAX) {
						/* guard full — stop this
						 * drain; the next publish
						 * retries the rest */
						xfs_irele(dip);
						mxfs_pubclaim_end(mp, claim_seq);
						mxfs_pub_drain_step(w, 0, 0);
						break;
					}
				} else {
					spin_unlock(&dip->i_dlm_lock);
				}
				xfs_irele(dip);
			} else {
				/* evicted between pop and here: its updates
				 * are log-only — settle the platter image */
				mxfs_pub_drain_step(w, ino,
						    MXFS_PUB_STEP_EVICTED);
				mxfs_dlm_unpub_child_settle(mp, ino);
			}
			mxfs_pubclaim_end(mp, claim_seq);
			mxfs_pub_drain_step(w, 0, 0);
			n++;
			continue;
		}
		{
			/*
			 * THE CLAIM IS THE PROOF, SO IT MUST BE INSTALLED
			 * (D-0937).  This arm used to ask the lock layer for no
			 * grant result at all, so nothing was ever offered to
			 * mxfs_dlm_authority_install — while the pop above had
			 * already cleared i_dlm_unpublished.  The inode came out
			 * of the publish holding a real, exclusive on-disk grant
			 * with its authority state still UNPUBLISHED_EX and its
			 * last install attempt reading "never attempted"; and
			 * because it is CACHED EX from here on, every later
			 * operation is served from the ilock_begin fast path and
			 * never descends into the lock layer again.  The tenure
			 * therefore never became provable, and every directory
			 * image it authorised shipped class NONE — enough for a
			 * foreign replayer to refuse the whole slice and
			 * quarantine the dead node's allocation groups.
			 *
			 * The justification for installing is the one the
			 * creator-baseline stamp below already rests on: we are
			 * inside a peer BAST on the PARENT, the peer is blocked
			 * on that lock and cannot have reached this child, so
			 * the claim we just took is this inode's first real
			 * grant.  The ICLUSTER arm above has snapshotted the gen
			 * and installed since; a directory is not routed
			 * there, which is the only reason this arm was left
			 * without it.
			 *
			 * The reference and the provenance snapshot are taken
			 * BEFORE the claim: `match` was valid only under
			 * m_mxfs_unpub_lock, and a gen sampled after the claim
			 * could not detect a relinquishment that raced it.
			 * INCORE means no disk I/O, and a NULL is a reclaimed
			 * inode — nothing to prove for and nothing to stamp.
			 */
			struct xfs_inode *bip = NULL;
			struct mxfs_grant_result dir_gres;
			uint64_t dir_gen_snap = MXFS_AUTH_GEN_NONE;

			if (xfs_iget(mp, NULL, ino, XFS_IGET_INCORE, 0,
				     &bip) != 0)
				bip = NULL;
			if (bip) {
				spin_lock(&bip->i_dlm_lock);
				dir_gen_snap = bip->i_mxfs_auth_gen;
				spin_unlock(&bip->i_dlm_lock);
			}

			mxfs_pub_drain_step(w, ino, MXFS_PUB_STEP_CLAIM);
			/* TEST ONLY (H-F10 A/B): hold the claim in flight */
			{
				extern unsigned int mxfs_dbg_pub_claim_delay_ms;
				unsigned int d = READ_ONCE(mxfs_dbg_pub_claim_delay_ms);

				if (d)
					msleep(d);
			}

			if (unlikely(READ_ONCE(mxfs_dbg_pub_claim_fail_ino) == ino)) {
				WRITE_ONCE(mxfs_dbg_pub_claim_fail_ino, 0);
				rc = -EAGAIN;
			} else
				rc = mxfs_v5_dlm_inode_lock(dlm, ino, MXFS_LOCK_EX,
							    bip ? &dir_gres : NULL);
			{
				int	laps = 0;

				while (rc == -EAGAIN &&
				       READ_ONCE(mxfs_pub_claim_retry) &&
				       !xfs_is_shutdown(mp) &&
				       !xfs_is_unmounting(mp)) {
					int	k = atomic_inc_return(
						&mxfs_pub_claim_retry_n);

					laps++;
					if (k <= 2000)
						pr_warn("mxfs: P-PUB-CLAIM-RETRY ino=%llu laps=%d total=%d -- deferred-publish EX claim answered -EAGAIN; it stays in flight and is asked again\n",
							(unsigned long long)ino,
							laps, k);
					/* the lock layer already waited out its
					 * budget; ask again well inside the time a
					 * request parked for capacity keeps its
					 * place (MXFS_CAP_PARK_TTL_MS) */
					msleep(50);
					rc = mxfs_v5_dlm_inode_lock(dlm, ino,
							MXFS_LOCK_EX,
							bip ? &dir_gres : NULL);
				}
				if (laps && !rc)
					pr_warn("mxfs: P-PUB-CLAIM-RETRY-GRANTED ino=%llu laps=%d\n",
						(unsigned long long)ino, laps);
			}
			if (rc) {
				mxfs_pal_log(MXFS_LOG_WARN,
					"mxfs: deferred-publish CAW EX failed ino=%llu rc=%d",
					(unsigned long long)ino, rc);
			} else if (bip) {
				spin_lock(&bip->i_dlm_lock);
				mxfs_dlm_authority_install(bip, &dir_gres,
							   dir_gen_snap, false,
							   MXFS_SITE);
				spin_unlock(&bip->i_dlm_lock);
				/* CREATOR BASELINE STAMP site 3 — the
				 * live path for a DIRECTORY. */
				mxfs_dlm_creator_baseline_query(bip, 3);
			}
			if (bip)
				xfs_irele(bip);
			mxfs_pubclaim_end(mp, claim_seq);
			mxfs_pub_drain_step(w, 0, 0);
		}
		n++;
	}
	return n;
}

/* A/B: Wave-A publish pre-pass (writeback+single-force before the
 * per-child eager-demote batch).  1=on (drc 4-7s handoffs -> in-budget);
 * 0=off for fairness-regression bisection. */
int mxfs_pub_wave_a = 1;

/* A/B: 1 = live-holder eager-demote aborts CLAIM the cluster EX from
 * the drain worker (airtight exclusion, extra hot-cluster EX pressure);
 * 0 = relist-only (holder's armed ilock_end demote converges µs later). */
int mxfs_pub_defer_claim = 1;
module_param_named(pub_defer_claim, mxfs_pub_defer_claim, int, 0644);
module_param_named(pub_wave_a, mxfs_pub_wave_a, int, 0644);
MODULE_PARM_DESC(pub_wave_a, "publish Wave-A writeback pre-pass (1=on)");

static void
mxfs_dlm_publish_drain_work(
	struct work_struct	*work)
{
	struct mxfs_pub_drain_worker *w =
		container_of(work, struct mxfs_pub_drain_worker, work);
	struct mxfs_pub_drain_batch *b = w->batch;
	struct xfs_mount	*mp = w->mp;

	WRITE_ONCE(w->cur_pid, current->pid);
	w->published = mxfs_dlm_publish_drain_loop(mp, w->parent_ino,
						   w->agno, w);
	if (atomic_dec_and_test(&b->pending))
		complete(&b->done);
	if (atomic_dec_and_test(&b->refs))
		kfree(b);
	atomic_dec(&mp->m_mxfs_pubdrain_active);
}

/*
 * H-F12: a bounded AG release drain that finished.  Count the in-scope entries
 * listed after it began and still listed: the release goes with them
 * unpublished, as with a child created after an open drain emptied its scope.
 * The walk stops at 1024.
 */
static void
mxfs_pub_drain_bound_report(
	struct xfs_mount	*mp,
	xfs_agnumber_t		agno,
	unsigned int		backlog,
	unsigned int		published,
	u64			seq_limit)
{
	static atomic_t		pbnd_n = ATOMIC_INIT(0);
	struct xfs_inode	*ip;
	unsigned int		left = 0;

	spin_lock(&mp->m_mxfs_unpub_lock);
	list_for_each_entry(ip, &mp->m_mxfs_unpub_list, i_dlm_unpub_link) {
		if (ip->i_mxfs_unpub_seq <= seq_limit ||
		    !mxfs_dlm_unpub_in_scope(mp, ip, 0, agno))
			continue;
		if (++left >= 1024)
			break;
	}
	spin_unlock(&mp->m_mxfs_unpub_lock);
	if (!left)
		return;
	atomic_add(left, &mxfs_pub_drain_bound_left);
	if (atomic_inc_return(&pbnd_n) <= 200)
		mxfs_probe("mxfs: P-PUB-DRAIN-BOUND agno=%u backlog=%u published=%u left=%u -- a bounded AG release drain finished and left the children listed after it began\n",
			agno, backlog, published, left);
}

/*
 * Just before an AG release's unlock: the unpublished inodes of this AG still
 * listed (of them, the ones already unlinked, which a peer's unlinked-list
 * remove can take as its predecessor), the parent-unknown entries of other AGs
 * the AG scope also matches, and the claims of this AG's inodes still in
 * flight.  Read only; each walk stops at 1024.
 */
void
mxfs_pub_unlock_exposure(
	struct xfs_mount	*mp,
	xfs_agnumber_t		agno,
	const char		*site)
{
	static atomic_t		pexp_n = ATOMIC_INIT(0);
	struct xfs_inode	*ip;
	unsigned int		listed = 0, unl = 0, p0 = 0, infl = 0, n = 0;
	xfs_ino_t		first = 0;

	if (!mp->m_mxfs_dlm)
		return;
	spin_lock(&mp->m_mxfs_unpub_lock);
	list_for_each_entry(ip, &mp->m_mxfs_unpub_list, i_dlm_unpub_link) {
		if (++n > 1024)
			break;
		if (XFS_INO_TO_AGNO(mp, ip->i_ino) == agno) {
			if (!listed++)
				first = ip->i_ino;
			if (VFS_I(ip)->i_nlink == 0)
				unl++;
		} else if (ip->i_mxfs_unpub_parent == 0) {
			p0++;
		}
	}
	n = 0;
	list_for_each_entry(ip, &mp->m_mxfs_pubclaim_list,
			    i_mxfs_pubclaim_link) {
		if (++n > 1024)
			break;
		if (XFS_INO_TO_AGNO(mp, ip->i_ino) == agno)
			infl++;
	}
	spin_unlock(&mp->m_mxfs_unpub_lock);
	if (!listed && !infl)
		return;
	atomic_inc(&mxfs_pub_unlock_exposed);
	atomic_add(listed, &mxfs_pub_unlock_listed);
	if (atomic_inc_return(&pexp_n) <= 2000)
		mxfs_probe("mxfs: P-PUB-UNPUB-AT-UNLOCK agno=%u site=%s listed=%u unlinked=%u first=%llu p0_other=%u inflight=%u comm=%s -- an AG unlock with unpublished inodes of this AG still listed or one's claim in flight\n",
			agno, site, listed, unl, (unsigned long long)first,
			p0, infl, current->comm);
}

/*
 * H-F13: whether an unpublished inode of this AG is listed or one's claim is
 * in flight -- what a peer granted the AG could reach through its AGI or inode
 * btree with no grant of ours to meet.  Parent-unknown entries of other AGs
 * are not counted: the AG's own structures cannot surface them, and their
 * directories' releases publish them.  Callable under pag_dlm_lock, a mutex
 * always taken before m_mxfs_unpub_lock.
 */
bool
mxfs_pub_ag_exposed(
	struct xfs_mount	*mp,
	xfs_agnumber_t		agno)
{
	struct xfs_inode	*ip;
	bool			found = false;

	spin_lock(&mp->m_mxfs_unpub_lock);
	list_for_each_entry(ip, &mp->m_mxfs_unpub_list, i_dlm_unpub_link) {
		if (XFS_INO_TO_AGNO(mp, ip->i_ino) == agno) {
			found = true;
			break;
		}
	}
	if (!found) {
		list_for_each_entry(ip, &mp->m_mxfs_pubclaim_list,
				    i_mxfs_pubclaim_link) {
			if (XFS_INO_TO_AGNO(mp, ip->i_ino) == agno) {
				found = true;
				break;
			}
		}
	}
	spin_unlock(&mp->m_mxfs_unpub_lock);
	return found;
}

/*
 * A drain whose window ran out: name the child each unfinished worker is on,
 * the step it waits in and for how long, and dump that worker's stack.  The
 * batch holds the waiter's reference, so the worker slots stay valid; the
 * fields are read racily and the worker may finish meanwhile.
 */
static void
mxfs_pub_drain_stuck_report(
	struct mxfs_pub_drain_worker	*w,
	unsigned int			i,
	xfs_ino_t			parent_ino,
	xfs_agnumber_t			agno)
{
	static atomic_t		pstk_n = ATOMIC_INIT(0);
	xfs_ino_t		ino = READ_ONCE(w->cur_ino);
	int			step = READ_ONCE(w->cur_phase);
	u64			t0 = READ_ONCE(w->cur_ns);
	pid_t			pid = READ_ONCE(w->cur_pid);
	struct pid		*wpid;
	struct task_struct	*task;

	if (!ino)
		return;
	pr_warn("mxfs: P-PUB-DRAIN-STUCK parent=%llu agno=%d worker=%u ino=%llu step=%d age_ms=%llu pid=%d -- an unfinished drain worker at the publish window's end (step 1 settle, 2 demote, 3 cluster claim, 4 evicted settle, 5 claim)\n",
		(unsigned long long)parent_ino,
		agno == NULLAGNUMBER ? -1 : (int)agno, i,
		(unsigned long long)ino, step,
		(unsigned long long)((ktime_get_ns() - t0) / NSEC_PER_MSEC),
		pid);
	if (!pid || atomic_inc_return(&pstk_n) > 20)
		return;
	wpid = find_get_pid(pid);
	task = wpid ? get_pid_task(wpid, PIDTYPE_PID) : NULL;
	if (task) {
		sched_show_task(task);
		put_task_struct(task);
	}
	put_pid(wpid);
}

/* The drain of mxfs_dlm_publish_unpublished; returns whether its bounded
 * wait ran out with claims of its own still in flight. */
static bool
mxfs_dlm_publish_unpublished_drain(
	struct xfs_mount	*mp,
	xfs_ino_t		parent_ino,
	xfs_agnumber_t		agno)
{
	struct mxfs_v5_dlm	*dlm = mp->m_mxfs_dlm;
	struct xfs_inode	*ip;
	unsigned int		n = 0, backlog = 0;
	u64			t0;
	u64			seq_limit = U64_MAX;
	bool			timed_out = false;

	if (!dlm)
		return false;

	/* Fast bail without taking the lock in the common (empty) case. */
	if (list_empty(&mp->m_mxfs_unpub_list))
		return false;

	/*
	 * H-F12: an AG release drains in its prepass with local admission to
	 * the AG open, so the creates this node keeps making there list new
	 * children in scope for as long as the drain runs; taking those too, a
	 * drain whose workers claim slower than this node creates never empties
	 * its scope and runs out its window.  Bound it to what is listed now.
	 * A directory's release keeps the open scan: a peer reaches a new child
	 * of the directory by its name once the directory is released.
	 */
	if (READ_ONCE(mxfs_pub_drain_bound) && parent_ino == 0 &&
	    agno != NULLAGNUMBER)
		seq_limit = atomic64_read(&mxfs_unpub_seq_next);

	/*
	 * v0.5.5: the drain used to claim slots
	 * one CAW round-trip (~2 ms) at a time.  A single mid-rsync peer
	 * BAST then serialized ~9000 unclaimed file slots through the
	 * ordered bast workqueue — an 18-30 s stall on one node (ftrace
	 * stack aggregation: 8845 mxfs_v5_dlm_inode_lock calls from
	 * mxfs_dlm_publish_unpublished in one run).  The claims are
	 * independent (distinct slots), so fan the backlog out over
	 * MXFS_PUB_DRAIN_WORKERS unbound workers and wait; the
	 * peer-is-blocked-until-we-return guarantee is preserved.
	 */
	/* v0.5.6: count only IN-SCOPE entries — the inline-vs-parallel
	 * decision is about how many slots THIS drain will claim. */
	spin_lock(&mp->m_mxfs_unpub_lock);
	list_for_each_entry(ip, &mp->m_mxfs_unpub_list, i_dlm_unpub_link) {
		if (!mxfs_dlm_unpub_in_scope(mp, ip, parent_ino, agno))
			continue;
		if (ip->i_mxfs_unpub_seq > seq_limit)
			continue;
		if (++backlog > MXFS_PUB_DRAIN_INLINE)
			break;
	}
	spin_unlock(&mp->m_mxfs_unpub_lock);

	if (!backlog)
		return false;

	/*
	 * WAVE A (instrumented, P138-measured): the per-child eager-demote
	 * pipeline costs 5-9ms/child when each child pays its own first
	 * log_force (sa~1.5ms), dirty-page flush (sc~2-4ms) and durable
	 * section (sd~2ms) — x800 children = 4-7s dir handoffs (the drc
	 * budget killer).  Pre-pass: START async writeback for every
	 * in-scope routed child (parallel device IO from one thread), WAIT,
	 * then ONE synchronous log force covers every delalloc-conversion
	 * transaction the writebacks logged.  The per-child pipeline then
	 * finds pages clean (sc~0), the log pre-forced (sa~0), and shared
	 * cluster buffers coalesce in sd.
	 */
	{
		struct xfs_inode **wa;
		unsigned int nwa = 0, wi;

		wa = mxfs_pub_wave_a ?
			kmalloc_array(4096, sizeof(*wa), GFP_KERNEL) : NULL;
		if (wa) {
			xfs_ino_t *wains = (xfs_ino_t *)wa; /* reuse: pass 1 stores inos */

			spin_lock(&mp->m_mxfs_unpub_lock);
			list_for_each_entry(ip, &mp->m_mxfs_unpub_list,
					    i_dlm_unpub_link) {
				if (!mxfs_dlm_unpub_in_scope(mp, ip,
							     parent_ino, agno))
					continue;
				if (ip->i_mxfs_unpub_seq > seq_limit)
					continue;
				if (!mxfs_iclus_routed(ip))
					continue;
				if (ip->i_ino == 0)
					continue;
				wains[nwa++] = ip->i_ino;
				if (nwa == 4096)
					break;
			}
			spin_unlock(&mp->m_mxfs_unpub_lock);
			/* swap ino -> referenced ip in place (iget after the
			 * spinlock; INCORE lookup, no disk IO) */
			for (wi = 0; wi < nwa; wi++) {
				struct xfs_inode *wip = NULL;
				xfs_ino_t wino = wains[wi];

				if (xfs_iget(mp, NULL, wino, XFS_IGET_INCORE,
					     0, &wip) || !wip)
					wip = NULL;
				wa[wi] = wip;
			}
			for (wi = 0; wi < nwa; wi++)
				if (wa[wi] && VFS_I(wa[wi])->i_mapping)
					filemap_fdatawrite(
						VFS_I(wa[wi])->i_mapping);
			for (wi = 0; wi < nwa; wi++) {
				if (!wa[wi])
					continue;
				if (VFS_I(wa[wi])->i_mapping)
					filemap_fdatawait(
						VFS_I(wa[wi])->i_mapping);
				xfs_irele(wa[wi]);
			}
			if (nwa)
				xfs_log_force(mp, XFS_LOG_SYNC);
			kfree(wa);
		}
	}

	t0 = ktime_get_ns();
	{
		struct mxfs_pub_drain_batch *b;
		unsigned int i, nw;

		/* the INLINE small-backlog drain blocked the bast
		 * worker exactly like the parallel wait (each claim can
		 * remote-wait) — every backlog size now goes through the
		 * bounded-wait batch.  Worker count scales with backlog. */
		nw = min_t(unsigned int, backlog, MXFS_PUB_DRAIN_WORKERS);
		b = kzalloc(sizeof(*b), GFP_KERNEL);
		if (!b)
			goto report;	/* n=0; the next BAST's publish retries */
		b->nworkers = nw;
		init_completion(&b->done);
		atomic_set(&b->pending, nw);
		atomic_set(&b->refs, nw + 1);
		atomic_add(nw, &mp->m_mxfs_pubdrain_active);
		for (i = 0; i < nw; i++) {
			b->w[i].mp = mp;
			b->w[i].parent_ino = parent_ino;
			b->w[i].agno = agno;
			b->w[i].seq_limit = seq_limit;
			b->w[i].batch = b;
			INIT_WORK(&b->w[i].work, mxfs_dlm_publish_drain_work);
			queue_work(system_unbound_wq, &b->w[i].work);
		}
		if (wait_for_completion_timeout(&b->done,
				msecs_to_jiffies(MXFS_PUB_DRAIN_TIMEOUT_MS))) {
			for (i = 0; i < nw; i++)
				n += b->w[i].published;
			if (seq_limit != U64_MAX)
				mxfs_pub_drain_bound_report(mp, agno, backlog,
							    n, seq_limit);
		} else {
			static atomic_t ptmo_n = ATOMIC_INIT(0);

			timed_out = true;
			if (atomic_inc_return(&ptmo_n) <= 200) {
				pr_warn("mxfs: P-PUB-DRAIN-TIMEOUT parent=%llu agno=%d backlog=%u -- %ums publish window expired; handoff proceeds, claims land async (cross-node bast cycle broken)\n",
					(unsigned long long)parent_ino,
					agno == NULLAGNUMBER ? -1 : (int)agno,
					backlog,
					MXFS_PUB_DRAIN_TIMEOUT_MS);
				for (i = 0; i < nw; i++)
					mxfs_pub_drain_stuck_report(&b->w[i], i,
								    parent_ino,
								    agno);
			}
		}
		if (atomic_dec_and_test(&b->refs))
			kfree(b);
	}
report:
	if (n) {
		/* P25-PUB probe (capped): drain size + wall per invocation.
		 * v0.5.6 adds the scope so a runaway (huge drained= with a
		 * non-zero scope) is visible in dmesg. */
		static atomic_t p25_pub_cap = ATOMIC_INIT(0);
		if (atomic_inc_return(&p25_pub_cap) <= 40)
			if (unlikely(mxfs_dirwr_enabled || mxfs_instr_enabled))
				mxfs_probe("mxfs: P25-PUB drained=%u parallel=%d ms=%llu parent=%llu agno=%d\n",
					n, backlog > MXFS_PUB_DRAIN_INLINE,
					(unsigned long long)((ktime_get_ns() - t0) /
							     NSEC_PER_MSEC),
					(unsigned long long)parent_ino,
					agno == NULLAGNUMBER ? -1 : (int)agno);
	}
	return timed_out;
}

/*
 * Publish what a peer could reach through the lock this node is releasing,
 * then make sure no claim another publish took in this release's scope is
 * still in flight (H-F10, mxfs_pubclaim_release_check).  The check runs on
 * every path, including the ones where nothing was listed to publish: the
 * zmf1 release had nothing listed because the other drain had already taken
 * the child.
 */
void
mxfs_dlm_publish_unpublished(
	struct xfs_mount	*mp,
	xfs_ino_t		parent_ino,
	xfs_agnumber_t		agno)
{
	bool			timed_out;

	timed_out = mxfs_dlm_publish_unpublished_drain(mp, parent_ino, agno);
	if (mp->m_mxfs_dlm)
		mxfs_pubclaim_release_check(mp, parent_ino, agno, timed_out);
}

/*
 * v0.5.4 — background DIRECTORY publisher.
 *
 * Work fn for mp->m_mxfs_publish_work (queued on m_mxfs_inode_bast_wq by
 * xfs_create after each mkdir).  Claims the on-disk CAW slot for every
 * unpublished DIRECTORY on m_mxfs_unpub_list so the
 * unpublished-dir-EX backstop in mxfs_dlm_ilock_begin (a synchronous
 * ~1.5 ms CAW acquire + reload inside the dir's first pin-free EX op —
 * rsync's per-dir utimensat) finds the dir already published and
 * fast-paths.  Regular files are left on the list: they never hit the
 * backstop, and publishing all of them re-creates the v0.5.2 per-create
 * CAW cost this design removed.
 *
 * Ordering is ACQUIRE-then-CLEAR — the reverse of
 * mxfs_dlm_publish_unpublished.  That fn clears i_dlm_unpublished before
 * the CAW acquire, which is safe there only because its caller (a BAST)
 * guarantees the peer is blocked and cannot reach the inode.  Here there
 * is no such shield: clearing the flag first would let a local EX-modify
 * fast-path through ilock_begin during the in-flight acquire while a
 * peer might own the slot — the exact mutual-exclusion hole.
 * With acquire-first, the flag (and thus the backstop) stays armed until
 * the slot is provably ours.
 *
 * Races:
 *  - backstop / publish_unpublished concurrently acquiring the same ino:
 *    mxfs_dlm_caw_lock converges via its already-held path; the list
 *    re-scan below then simply finds the entry gone.  Coherent.
 *  - reclaim evicting the inode mid-acquire: mxfs_dlm_evict's
 *    unpublish_drop sees the flag still set and skips the on-disk
 *    release, briefly leaking the slot we just claimed; a peer's later
 *    acquire of that ino BASTs us and the no-inode orphan-release path
 *    frees it.  ip is never dereferenced outside m_mxfs_unpub_lock, so
 *    there is no UAF.
 */
void
mxfs_dlm_publish_dirs_work(
	struct work_struct	*work)
{
	struct xfs_mount	*mp = container_of(work, struct xfs_mount,
						   m_mxfs_publish_work);
	struct mxfs_v5_dlm	*dlm = mp->m_mxfs_dlm;
	struct xfs_inode	*ip;
	uint64_t		ino;
	unsigned int		n = 0;
	int			rc;
	/* D-0937: provenance of this worker's claim (see the claim below). */
	struct xfs_inode	*pubip;
	struct mxfs_grant_result pub_gres;
	uint64_t		pub_gen_snap;
	/* inodes this pass met with no reference to take: left listed */
	uint64_t		noref[16];
	unsigned int		n_noref = 0, ni;
	int			iget_rc;

	/* P24 instrumented probe: confirm the worker runs and claims (capped). */
	{
		static atomic_t p24w_n = ATOMIC_INIT(0);
		if (atomic_inc_return(&p24w_n) <= 50)
			mxfs_probe("mxfs: P24-WORKER enter dlm=%d single=%d\n",
				dlm ? 1 : 0,
				dlm ? mxfs_v5_dlm_is_single_node(dlm) : -1);
	}
	/* 0.83.3 (D-0955) / 0.87.16: every mount publishes its unpublished
	 * inodes to the master (itself when alone) so a joining peer's acquire
	 * BASTs it and a replayer finds the grant behind its logged images. */
	if (!dlm)
		return;

	for (;;) {
		unsigned int sc_tot = 0, sc_zero = 0, sc_file = 0;
		uint32_t bep = 0, bgg = 0;	/* creator baseline */

		ino = 0;
		spin_lock(&mp->m_mxfs_unpub_lock);
		list_for_each_entry(ip, &mp->m_mxfs_unpub_list,
				    i_dlm_unpub_link) {
			sc_tot++;
			/* P24 instrumented probe: dump what the scan actually sees. */
			{
				static atomic_t p24e_n = ATOMIC_INIT(0);
				if (atomic_inc_return(&p24e_n) <= 30)
					mxfs_probe("mxfs: P24-SCAN ip=%px ino=%llu vmode=%o\n",
						ip,
						(unsigned long long)ip->i_ino,
						VFS_I(ip)->i_mode);
			}
			if (ip->i_ino == 0) {
				sc_zero++;
				continue;
			}
			if (!S_ISDIR(VFS_I(ip)->i_mode)) {
				sc_file++;
				continue;
			}
			/* v0.5.6: only REUSED-incarnation
			 * dirs need a pre-claimed slot — peers may still name
			 * their ino from stale dcache of the prior incarnation
			 * WITHOUT transiting a lock we hold, and the
			 * backstop that covers that costs a synchronous ~1.5 ms
			 * CAW acquire on the dir's first EX-modify.  FRESH
			 * creates are reachable only through locks we hold, so
			 * the scoped BAST-side publish covers them; pre-claiming
			 * them here only generated ~700 claims/node of FUA slot
			 * traffic per rsync (16n: ~11k cluster-wide, 2.3 s of
			 * caw_lock per node, LUN queue inflation on every op). */
			if (!ip->i_mxfs_reused_create)
				continue;
			for (ni = 0; ni < n_noref; ni++)
				if (noref[ni] == ip->i_ino)
					break;
			if (ni < n_noref)
				continue;
			ino = ip->i_ino;
			break;
		}
		spin_unlock(&mp->m_mxfs_unpub_lock);

		if (!ino) {
			/* P24 instrumented probe: why the scan came up empty. */
			static atomic_t p24s_n = ATOMIC_INIT(0);
			if (atomic_inc_return(&p24s_n) <= 50)
				mxfs_probe("mxfs: P24-WORKER scan-empty tot=%u zero=%u file=%u\n",
					sc_tot, sc_zero, sc_file);
			break;
		}

		/*
		 * THE CLAIM IS THE PROOF, SO IT MUST BE INSTALLED (D-0937) —
		 * the same hole the publish drain carried: a real exclusive
		 * on-disk grant taken with no grant result, so the delist below
		 * leaves the inode looking published while its authority state
		 * still reads UNPUBLISHED_EX and nothing ever retries.  The
		 * reference and the gen snapshot are taken before the claim; the
		 * install runs after the delist, because the installer refuses
		 * any inode still flagged unpublished, and outside
		 * m_mxfs_unpub_lock, because the established nesting is
		 * i_dlm_lock -> m_mxfs_unpub_lock and never the reverse.
		 */
		pubip = NULL;
		pub_gen_snap = MXFS_AUTH_GEN_NONE;
		iget_rc = xfs_iget(mp, NULL, ino, XFS_IGET_INCORE, 0, &pubip);
		if (iget_rc || !pubip) {
			/*
			 * NO REFERENCE, NO CLAIM.  The install below needs the
			 * inode, and a claim that is not installed is worse
			 * than no claim: this worker used to take the grant
			 * with no grant result, de-list the inode and clear
			 * its flag all the same, and leave it cached EX, off
			 * the list, with its authority state still
			 * UNPUBLISHED_EX.  The lock fast path gates on the
			 * flag, so nothing installed a certificate for the
			 * rest of the tenure and every image of the
			 * directory's blocks went to the log with no class; a
			 * death then left transactions no peer may replay, the
			 * slice was refused and the dead node's allocation
			 * groups quarantined.  Measured on 8 nodes over TCP:
			 * 2130 of 2130 owners captured unprovable had been
			 * de-listed here, none had an install attempt in its
			 * tenure, and they were 20 to 28 percent of the
			 * inode-owned images each node logged.
			 *
			 * The lookup fails while the creating task is still
			 * setting the inode up: the work is queued at the
			 * mkdir's commit and an in-core lookup of a new inode
			 * answers at once instead of waiting.  Leave the inode
			 * listed and flagged.  Its first exclusive modify takes
			 * the synchronous publish (the unpublished-directory
			 * arm of the lock fast path), which de-lists, acquires
			 * and installs from its own grant result; a later pass
			 * of this worker may get there first.
			 */
			static atomic64_t	noref_n;
			long long		nn = atomic64_inc_return(&noref_n);

			pubip = NULL;
			if (nn <= 64 || (nn & 1023) == 0)
				mxfs_probe("mxfs: P24-WORKER-NOREF n=%lld ino=%llu rc=%d -- no reference to the inode: not claimed, left on the unpublished list for its first exclusive modify\n",
					nn, (unsigned long long)ino, iget_rc);
			if (n_noref >= ARRAY_SIZE(noref))
				break;
			noref[n_noref++] = ino;
			continue;
		}
		spin_lock(&pubip->i_dlm_lock);
		pub_gen_snap = pubip->i_mxfs_auth_gen;
		spin_unlock(&pubip->i_dlm_lock);

		rc = mxfs_v5_dlm_inode_lock(dlm, ino, MXFS_LOCK_EX, &pub_gres);

		/* CREATOR BASELINE STAMP site 2 — read the post-claim
		 * baseline HERE, in sleepable context, BEFORE taking the list
		 * spinlock.  The stamp itself is two scalar stores and happens
		 * under the lock below; hoisting only the QUERY keeps the
		 * sleeping grant_meta mutex (dlm_caw.c:1120) out of atomic
		 * context, which is what made this site awkward in the
		 * design note.  We hold EX from the call above and do not
		 * release it, so no peer can advance either value in between. */
		if (rc == 0) {
			bep = mxfs_v5_dlm_inode_dir_epoch(dlm, ino);
			bgg = mxfs_v5_dlm_inode_grant_gen(dlm, ino);
		}

		spin_lock(&mp->m_mxfs_unpub_lock);
		list_for_each_entry(ip, &mp->m_mxfs_unpub_list,
				    i_dlm_unpub_link) {
			if (ip->i_ino != ino)
				continue;
			if (rc == 0) {
				list_del_init(&ip->i_dlm_unpub_link);
				ip->i_dlm_unpublished = false;
				WRITE_ONCE(ip->i_mxfs_unpub_clr_line, MXFS_SITE);
				mxfs_dlm_creator_baseline_apply(ip, bep, bgg, 2);
			}
			break;
		}
		spin_unlock(&mp->m_mxfs_unpub_lock);

		if (rc == 0 && pubip) {
			spin_lock(&pubip->i_dlm_lock);
			mxfs_dlm_authority_install(pubip, &pub_gres,
						   pub_gen_snap, false,
						   MXFS_SITE);
			spin_unlock(&pubip->i_dlm_lock);
		}
		if (pubip)
			xfs_irele(pubip);

		if (rc) {
			/* Leave it listed; the ilock_begin backstop retries
			 * synchronously on the next EX-modify. */
			mxfs_probe_ratelimited(
			    "mxfs: P24-ASYNC-PUBLISH-FAIL ino=%llu rc=%d (backstop will retry)\n",
				(unsigned long long)ino, rc);
			break;
		}
		n++;
	}
	/* P24 instrumented probe (capped): claims per drain. */
	{
		static atomic_t p24c_n = ATOMIC_INIT(0);
		if (n && atomic_inc_return(&p24c_n) <= 50)
			mxfs_probe("mxfs: P24-WORKER claimed=%u\n", n);
	}
}

/*
 * NEWARCH Phase 1.4 — publish-on-create.  Synchronously promote ONE
 * unpublished inode to a real on-disk CAW slot.  Called from xfs_create
 * after xfs_trans_commit and before namespace exposure.
 *
 * Atomically removes the inode from the unpub list (so a concurrent
 * publish_unpublished or a peer-BAST-driven publish can't race us) and
 * acquires the real on-disk EX slot.  After this returns, a peer
 * reaching the new inode by name will find a real slot, send us a
 * proper BAST, and we will drain+release coherently — closing the
 * "peer acquires empty slot cleanly, never BASTs" window.
 *
 * Best-effort: if mxfs_v5_dlm_inode_lock fails (CAW exhausted),
 * P109-PUBLISH-FAIL is logged and we fall back to the lazy
 * publish backstop in mxfs_dlm_ilock_begin — same correctness, slower.
 * Hot-path probe ratelimited.
 */
void
mxfs_dlm_publish_inode(
	struct xfs_inode	*ip)
{
	struct xfs_mount	*mp = ip->i_mount;
	struct mxfs_v5_dlm	*dlm;
	bool			was_unpub;
	int			rc;
	uint64_t		pub_gen_snap;
	u64			claim_seq = 0;	/* H-F10: this take's tracking */

	if (!mp)
		return;
	dlm = mp->m_mxfs_dlm;
	if (!dlm)
		return;

	/* No membership exemption (0.83.3 for a sole survivor, 0.87.16 for a
	 * mount that never had a peer): the grant this publish claims is what
	 * authorizes the inode's logged images at a replay after a death. */

	/* Already published?  Common-case fast bail without the list lock. */
	if (!ip->i_dlm_unpublished) {
		/*
		 * instrumented probe: publish-on-create called for a REUSED
		 * in-core inode (recycle / reset_inode_for_create) that kept
		 * the PRIOR incarnation's DLM state.  If the prior incarnation
		 * was published and then freed, xfs_inactive released the
		 * on-disk slot — this inode now holds a PHANTOM in-core EX with
		 * NO slot, peers' acquires grant clean (no BAST), and the new
		 * dinode is never flushed for them (cross_write_read size=0).
		 */
		mxfs_probe_ratelimited(
		    "mxfs: P128-PUBLISH-BAIL ino=%llu dlm_mode=%u dlm_state=%u -- create on reused inode, unpub flag clear, NOT acquiring slot\n",
			(unsigned long long)ip->i_ino,
			ip->i_dlm_mode, ip->i_dlm_state);
		return;
	}

	/*
	 * THE CLAIM IS THE PROOF, SO IT MUST BE INSTALLED (D-0937).  This
	 * publish used to pass MXFS_AUTH_GEN_NONE, the sentinel reserved for
	 * probe and nudge callers that make no provenance claim — which turns
	 * mxfs_dlm_authority_install into a no-op.  But this IS a provenance
	 * claim: it delists the inode and then takes a real exclusive on-disk
	 * grant, and leaving the tenure unproven means every image it
	 * authorises ships class NONE and is refused on foreign replay.  Sample
	 * the gen before the delist, under i_dlm_lock and never inside
	 * m_mxfs_unpub_lock (the established nesting runs the other way), so a
	 * relinquishment racing the acquire still moves the counter and the
	 * install refuses.
	 */
	spin_lock(&ip->i_dlm_lock);
	pub_gen_snap = ip->i_mxfs_auth_gen;
	spin_unlock(&ip->i_dlm_lock);

	spin_lock(&mp->m_mxfs_unpub_lock);
	was_unpub = ip->i_dlm_unpublished;
	if (was_unpub) {
		list_del_init(&ip->i_dlm_unpub_link);
		ip->i_dlm_unpublished = false;
		WRITE_ONCE(ip->i_mxfs_unpub_clr_line, MXFS_SITE);
		claim_seq = mxfs_pubclaim_begin_locked(mp, ip);
	}
	spin_unlock(&mp->m_mxfs_unpub_lock);

	if (!was_unpub)
		return;	/* racing publisher won; nothing to do. */

	rc = mxfs_dlm_inode_lock_routed(ip, MXFS_LOCK_EX, pub_gen_snap);
	/* a release of this node that moved the generation under this
	 * request leaves the published EX uncertified: ask again */
	rc = mxfs_ilock_redrive_stalegen(ip, MXFS_LOCK_EX, pub_gen_snap, rc);
	mxfs_pubclaim_end(mp, claim_seq);	/* H-F10 */
	if (rc) {
		mxfs_probe_ratelimited(
		    "mxfs: P109-PUBLISH-FAIL ino=%llu rc=%d (falling back to lazy backstop)\n",
			(unsigned long long)ip->i_ino, rc);
		return;
	}
	mxfs_idbg("mxfs: P109-PUBLISH-OK ino=%llu mode=EX (publish-on-create)\n",
		(unsigned long long)ip->i_ino);
	/* CREATOR BASELINE STAMP site 1 — sleepable, no lock held, and
	 * `ip` is the caller's referenced inode.  Reached only from the
	 * cross-dir rename/link force-publish and xfs_symlink; xfs_create's own
	 * publish-on-create call was removed for cost (xfs_inode.c:2682), so a
	 * plain mkdir does NOT come through here — expect this site to measure
	 * near zero and read that as routing, not as the stamp failing. */
	mxfs_dlm_creator_baseline_query(ip, 1);
}
