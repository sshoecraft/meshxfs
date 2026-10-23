// SPDX-License-Identifier: GPL-2.0
/*
 * adopted_grant_handoff_test — D-8NETMESH-SURVIVOR-SHUTDOWN-FALSE-FRESH-AG-GRANT-AFTER-TAKEOVER,
 * in usermode.
 *
 * Rig shape (8/net/mesh/mpath, build 9594B08726D6732D2ED5E87, ledger run
 * 8/net/mesh/mpath:path_peer_withdrawn:2026-10-22T19:58:42Z, test21's boot kernel log): test21
 * waited for EX on AG 6, mastered by test24.  The grant arrived between two attempts of the wait
 * and was kept for it (P958-ACQ-GRANT-ADOPTED gen=2731 master=test24).  A view change then handed
 * AG 6's ledger page from test24 to test21 (P-TAUTH-ACTIVATE page=210 ... P-TAUTH-PAGE-MINE
 * via=frozen-msg), so the mirror the grant had installed became the lock master's own record of
 * test21's EX.  The wait's next attempt was answered by the local already-granted shortcut
 * (P958-ACQ-LOCAL-ANSWER-END site=shortcut), and 0.2 ms before that line the adopted grant was
 * handed back as unclaimed (P958-ACQ-GRANT-RELEASED why=unclaimed mirror_unlinked=1, master =
 * test21 itself).  22 ms later test21's master decided another node's EX on AG 6, which the ledger
 * refused 110 times in six seconds (P-TAUTH-DOUBLE-GRANT ... vs record ex=test21), and test21 later
 * shut its filesystem down on a fresh grant over its own open lineage (P130-FALSE-FRESH).
 *
 * H-ADOPT-1: dlm_local_answered ends the acquisition record with claimed=0, so the grant the
 * wait adopted is released as unclaimed (dlm_acq_release_grant).  The release unlinks the table
 * entry of that grant episode, which after the hand-off is the entry the shortcut has just
 * answered the wait from: the caller holds EX while its own lock master records nobody.
 * Falsifier: A's lock master still records A's EX after the shortcut answer.
 *
 * Harness: four nodes, A the bootstrap (lowest slot), B, C, D.  R is an inode resource mastered
 * by B under {A,B,C,D} and by A under {A,B,C}, on a page nobody has decided on.  The TEST ONLY gap
 * knob (dl_acq_gap_ino/dl_acq_gap_ms) holds A for GAP_MS with no pending entry after each
 * timed-out attempt of its acquire of R, which is what lets the grant land between two attempts.
 *   1  C takes EX on R from B;
 *   2  A asks EX on R; its first attempt queues at B behind C and times out into the gap;
 *   3  C releases: B promotes A, and the grant lands with no pending entry and is adopted;
 *   4  D leaves the view, still in A's gap: R's page is handed B -> A;
 *   5  A's next attempt is mastered here and answered by the already-granted shortcut: A holds EX
 *      and its lock master must still record that EX;
 *   6  B asks EX on R while A holds it: not granted, and A's master decides no conflicting grant
 *      (A's ledger refuses none);
 *   7  A releases, and B's EX is granted.
 * 1-4 and the exposure half of 5 assert that the lap reached the rig's sequence.  A FAIL on the
 * table check of 5 or on 6 reproduces the rig defect.
 *
 * DL_SHORTCUT_CLAIM=0 in the environment turns the fix's knob (dl_shortcut_claim) off: the
 * shortcut ends the wait unclaimed, as before the fix (the same-build control).
 */
#define NNODES 4
#include "dlm_mesh.h"
#include "dlm/dlm_user_compat.h"

extern unsigned long long mxfs_dl_acq_gap_ino;
extern unsigned int mxfs_dl_acq_gap_ms;
extern atomic_t mxfs_dl_local_acq_end_n;
extern int mxfs_dl_shortcut_claim;

/* A's gap after its first timed-out attempt: long enough for steps 3 and 4 to finish inside it
 * (a grant and a page hand-off, each tens of ms here), well under the acquisition record's idle
 * retirement (MXFS_DLM_ACQ_IDLE_MS, 15 s) */
#define GAP_MS 4000

/* the master of r under the view ids[0..n), asked of a context that holds no ledger */
static struct mxfs_dlm_ctx *scratch;

static mxfs_node_id_t master_under(const mxfs_node_id_t *ids, int n,
                                   const struct mxfs_resource_id *r)
{
    mxfs_dlm_update_active_nodes(scratch, ids, n);
    return mxfs_dlm_resource_master(scratch, r);
}

/* the first inode number from `from` up whose master under view v1 is m1 and under v2 is m2,
 * on a page nothing has decided on */
static struct mxfs_resource_id pick(const mxfs_node_id_t *v1, int n1, mxfs_node_id_t m1,
                                    const mxfs_node_id_t *v2, int n2, mxfs_node_id_t m2,
                                    uint64_t from)
{
    struct mxfs_resource_id r;
    struct mxfs_tauth_page_auth a;

    memset(&r, 0, sizeof(r));
    r.type = MXFS_LTYPE_INODE;
    for (r.ino = from; ; r.ino++) {
        if (master_under(v1, n1, &r) != m1 || master_under(v2, n2, &r) != m2)
            continue;
        if (mxfs_tauth_ledger_page_auth(&probe, tl_page(&r), true, &a) ||
            a.state != MXFS_TAUTH_PG_UNOWNED)
            continue;
        return r;
    }
}

/* wait (bounded) until page p reads ACTIVE under `auth` on the platter */
static int wait_active(uint32_t p, mxfs_node_id_t auth, uint64_t ms)
{
    struct mxfs_tauth_page_auth a;
    uint64_t t0 = mxfs_pal_time_ms();

    for (;;) {
        if (mxfs_tauth_ledger_page_auth(&probe, p, true, &a) == 0 &&
            a.state == MXFS_TAUTH_PG_ACTIVE && a.auth_node == auth)
            return 1;
        if (mxfs_pal_time_ms() - t0 >= ms)
            return 0;
        mxfs_pal_sleep_ms(10);
    }
}

/* does n's lock table hold a GRANTED entry of `owner` on r at `mode` or stronger? */
static int table_holds(struct vnode *n, const struct mxfs_resource_id *r, mxfs_node_id_t owner,
                       uint8_t mode)
{
    struct mxfs_lock *lk;
    uint32_t i;
    int found = 0;

    mxfs_pal_rwlock_rdlock(n->dlm->table_rwlock);
    for (i = 0; i < n->dlm->bucket_count && !found; i++)
        for (lk = n->dlm->buckets[i]; lk; lk = lk->next)
            if (lk->resource.type == r->type && lk->resource.ino == r->ino &&
                lk->resource.ag_number == r->ag_number && lk->owner == owner &&
                lk->state == MXFS_LSTATE_GRANTED && lk->mode >= mode) {
                found = 1;
                break;
            }
    mxfs_pal_rwlock_unlock(n->dlm->table_rwlock);
    return found;
}

int main(void)
{
    struct mxfs_resource_id R;
    struct vnode *A, *B, *C, *D;
    struct lock_job *j;
    mxfs_node_id_t v4[4], v3[3];
    uint64_t adopted0, released0, claimed0, busy0, t0;
    uint8_t granted = 0;
    int rc, lae0, held, x_adopted, x_handed, x_local;

    tl_mktemp("adopted_grant_handoff_test");
    if (getenv("DL_SHORTCUT_CLAIM") && *getenv("DL_SHORTCUT_CLAIM"))
        mxfs_dl_shortcut_claim = atoi(getenv("DL_SHORTCUT_CLAIM"));
    printf("=== adopted_grant_handoff_test file=%s dl_shortcut_claim=%d ===\n", tl_path,
           mxfs_dl_shortcut_claim);
    format_region(base, uuid);
    dev = mxfs_pal_bdev_open(tl_path);
    if (!dev) { perror("bdev_open"); return 2; }
    rc = mxfs_tauth_ledger_open(&probe, dev, base, MXFS_TAUTH_REGION_BYTES, uuid, 99, 9999, 63);
    if (rc) { printf("probe open rc=%d\n", rc); return 2; }
    scratch = mxfs_dlm_create(4242);
    mxfs_dlm_set_ledger_geometry(scratch, MXFS_TAUTH_NPAGES, TL_SEED, MXFS_TAUTH_HASH_VERSION);

    /* slot i+1: A holds the lowest slot, the bootstrap node */
    A = node_up(0, 1000, 5000, 1, 1);
    B = node_up(1, 1000 + 7919, 5001, 2, 1);
    C = node_up(2, 1000 + 2 * 7919, 5002, 3, 1);
    D = node_up(3, 1000 + 3 * 7919, 5003, 4, 1);
    v4[0] = A->id; v4[1] = B->id; v4[2] = C->id; v4[3] = D->id;
    v3[0] = A->id; v3[1] = B->id; v3[2] = C->id;
    R = pick(v4, 4, B->id, v3, 3, A->id, 100000);
    printf("  INFO R ino=%llu page=%u: master B under {A,B,C,D}, A under {A,B,C}\n",
           (unsigned long long)R.ino, tl_page(&R));
    membership(v4, 4);
    mxfs_pal_sleep_ms(200);

    /* ── 1. C holds EX on R, granted by B ── */
    rc = lock_sync(C, &R, MXFS_LOCK_EX, &granted);
    CHECK(rc == 0 && wait_active(tl_page(&R), B->id, 2000),
          "1 C's EX on R granted by B, R's page ACTIVE under B (rc=%d)", rc);
    settle(C);

    /* ── 2. A's wait: its first attempt queues at B behind C, times out, and enters the gap ── */
    mxfs_dl_acq_gap_ino = R.ino;
    mxfs_dl_acq_gap_ms = GAP_MS;
    adopted0 = A->dlm->acq_grant_adopted;
    released0 = A->dlm->acq_grant_released;
    claimed0 = A->dlm->acq_grant_claimed;
    lae0 = atomic_read(&mxfs_dl_local_acq_end_n);
    t0 = mxfs_pal_time_ms();
    j = lock_async(A, &R, MXFS_LOCK_EX, 4);
    /* the first attempt waits MXFS_LOCK_ACQUIRE_WAIT_MS for B's answer, then the gap starts */
    mxfs_pal_sleep_ms(MXFS_LOCK_ACQUIRE_WAIT_MS + 400);
    CHECK(!j->done, "2 A's wait is still open %llu ms in (its first attempt timed out into the gap)",
          (unsigned long long)(mxfs_pal_time_ms() - t0));

    /* ── 3. C releases: B promotes A, and the grant lands with no pending entry ── */
    mxfs_dlm_unlock(C->dlm, &R);
    {
        uint64_t t1 = mxfs_pal_time_ms();

        while (A->dlm->acq_grant_adopted == adopted0 && mxfs_pal_time_ms() - t1 < 800)
            mxfs_pal_sleep_ms(5);
    }
    x_adopted = A->dlm->acq_grant_adopted == adopted0 + 1;
    CHECK(x_adopted,
          "3 exposure: B's grant reached A between two attempts of its wait and was kept for it "
          "(adopted +%llu)", (unsigned long long)(A->dlm->acq_grant_adopted - adopted0));
    CHECK(table_holds(A, &R, A->id, MXFS_LOCK_EX), "3 the grant's mirror is in A's table");

    /* ── 4. D leaves the view: R's page moves B -> A while A is still in its gap ── */
    membership(v3, 3);
    x_handed = wait_active(tl_page(&R), A->id, 1500) && !j->done;
    CHECK(x_handed, "4 exposure: R's page handed from B to A and ACTIVE under A, A's wait still "
          "in its gap (%llu ms in)", (unsigned long long)(mxfs_pal_time_ms() - t0));
    CHECK(table_holds(A, &R, A->id, MXFS_LOCK_EX),
          "4 the grant's entry is A's lock master's record of A's EX on R");

    /* ── 5. A's next attempt is mastered here ── */
    lock_wait(j, GAP_MS + 4000);
    printf("  INFO 5 A's wait: done=%d rc=%d granted=%u wall=%llums adopted=+%llu claimed=+%llu "
           "released=+%llu local_answers=+%d\n", j->done, j->rc, j->granted,
           (unsigned long long)(j->t1 - j->t0),
           (unsigned long long)(A->dlm->acq_grant_adopted - adopted0),
           (unsigned long long)(A->dlm->acq_grant_claimed - claimed0),
           (unsigned long long)(A->dlm->acq_grant_released - released0),
           atomic_read(&mxfs_dl_local_acq_end_n) - lae0);
    CHECK(j->done && j->rc == 0 && j->granted == MXFS_LOCK_EX,
          "5 A's wait granted EX (done=%d rc=%d granted=%u)", j->done, j->rc, j->granted);
    x_local = j->done && j->rc == 0 && atomic_read(&mxfs_dl_local_acq_end_n) > lae0;
    CHECK(x_local, "5 exposure: the wait was answered locally, outside the promote path");
    /* the one line a batch's probe reads: every step of the rig's sequence was reached */
    printf("EXPOSURE adopted=%d handed=%d local=%d\n", x_adopted, x_handed, x_local);
    held = table_holds(A, &R, A->id, MXFS_LOCK_EX);
    CHECK(held, "5 A's lock master still records A's EX on R, the hold the wait was answered with");
    CHECK(mxfs_dlm_held_mode(A->dlm, &R) == MXFS_LOCK_EX,
          "5 A's lock layer reads its EX on R (held mode %u)", mxfs_dlm_held_mode(A->dlm, &R));
    mxfs_dl_acq_gap_ino = 0;
    mxfs_dl_acq_gap_ms = 0;
    lock_finish(j);
    settle(A);

    /* ── 6. B asks EX on R while A holds it ── */
    busy0 = A->ledger.busy_denies;
    rc = mxfs_dlm_lock_retries(B->dlm, &R, MXFS_LOCK_EX, 0, &granted, 2);
    printf("  INFO 6 B's EX on R: rc=%d granted=%u; A's ledger refusals %llu -> %llu\n", rc, granted,
           (unsigned long long)busy0, (unsigned long long)A->ledger.busy_denies);
    CHECK(rc != 0, "6 B's EX on R not granted while A holds EX (rc=%d)", rc);
    if (rc == 0)
        mxfs_dlm_unlock(B->dlm, &R);
    CHECK(A->ledger.busy_denies == busy0,
          "6 A's lock master decided no grant conflicting with A's EX (ledger refusals %llu -> %llu)",
          (unsigned long long)busy0, (unsigned long long)A->ledger.busy_denies);
    settle(B);

    /* ── 7. A releases; B's EX is granted ── */
    mxfs_dlm_unlock(A->dlm, &R);
    settle(A);
    rc = lock_sync(B, &R, MXFS_LOCK_EX, &granted);
    CHECK(rc == 0 && granted == MXFS_LOCK_EX, "7 after A's release B's EX on R is granted (rc=%d)", rc);
    if (rc == 0)
        mxfs_dlm_unlock(B->dlm, &R);

    mxfs_dlm_release_all(A->dlm);
    mxfs_dlm_release_all(B->dlm);
    mxfs_dlm_release_all(C->dlm);
    mxfs_dlm_release_all(D->dlm);
    node_down(D);
    node_down(C);
    node_down(B);
    node_down(A);
    mxfs_dlm_destroy(scratch);
    mxfs_tauth_ledger_close(&probe);
    mxfs_pal_bdev_close(dev);
    unlink(tl_path);
    printf("=== adopted_grant_handoff_test RESULT %s fails=%d ===\n", tl_fails ? "FAIL" : "PASS",
           tl_fails);
    return tl_fails ? 1 : 0;
}
