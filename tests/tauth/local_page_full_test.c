// SPDX-License-Identifier: GPL-2.0
/*
 * local_page_full_test — a request the page's master grants itself must wait
 * on a full home page, not fail.
 *
 * Measured on 2/net/mesh/mpath path_fenced_return (0.90.131 release chain,
 * window lap 9): after the fenced peer rejoined, about 40,500 live inodes
 * filled ledger pages (P-TAUTH-PAGE-FULL "requester waits"), a request the
 * node decided for itself on such a page returned the raw -EDQUOT, and the
 * inode lock shut the filesystem down: first on the survivor, then on the
 * rejoined node.  A remote requester refused for the same reason waits and
 * asks again (MXFS_ERR_LEDGER_FULL).
 *
 * Shape: M masters page P; M takes EX on 31 resources whose home page is P,
 * which fills it; then M asks for a 32nd resource on P.  Lap 1 runs with
 * dl_capacity_wait_local=0 and must get -EDQUOT at once (otherwise the page
 * was not full or the grant was not M's own, and the A/B judges nothing).
 * Lap 2 runs the same request with the switch on: it must still be waiting
 * after 300 ms, and once M releases one of the 31 it must be granted, with
 * dl_capacity_wait_local_n counting the waits.  Lap 3, switch on, a resource
 * on another page: granted at once, no wait counted.
 *
 * A no-queue request on the full page (an inode reservation try) is answered
 * would-block at once (dl_capacity_nq_wouldblock).  Measured on
 * 2/net/mesh/mpath with one node creating 16384 files in one directory: the
 * same inode's try waited out its retry budget on the full page every 10 s
 * and creates crawled.  Laps 4-7 run on a 33rd resource of the page, refilled
 * by lap 2's grant: lap 4 CONTROL (switch 0) M's no-queue try must wait (waits
 * counted, more than 300 ms) before -EAGAIN, else the page was not full and
 * the laps judge nothing; lap 5 FIX M's try answered -EAGAIN at once, one
 * would-block counted, no wait, nothing parked; lap 6 FIX the same from B, a
 * remote requester answered MXFS_ERR_LEDGER_FULL by M; lap 7 CONTROL from B
 * waits, so lap 6's answer is the switch's.
 *
 * Nothing asked a holder to make room on a full page, so a waiter waited as
 * long as the page stayed full.  Measured on 2/net/mesh/mpath path_fenced_return
 * (run 20261020T142123Z-g2d): the survivor's page held 31 of its own idle EX
 * grants and a truncating open waited on it without end, which hung the freeze
 * for the rejoining peer's join.  dl_capacity_reclaim asks the holders of the
 * page's oldest records to release them.  Laps 8-12, with each holder
 * releasing when asked (auto_release): lap 8 CONTROL (switch 0) M's request on
 * a page full of M's own grants still waits after 1 s and no holder was
 * notified; lap 9 FIX granted within 1.5 s, and the records released were the
 * page's MXFS_TAUTH_INO_SHARD oldest (the newest kept); lap 10 CONTROL the page
 * full of B's grants (a remote holder), B not notified; lap 11 FIX the same
 * request, switch on, B asked and the request granted; lap 12 FIX B, a remote
 * requester, on a page full of M's own grants, granted once M releases.
 */
#define NNODES 2
#include "dlm_mesh.h"
#include "dlm/dlm_user_compat.h"

extern int mxfs_dl_capacity_wait_local;
extern atomic_t mxfs_dl_capacity_wait_local_n;
extern int mxfs_dl_capacity_nq_wouldblock;
extern atomic_t mxfs_dl_capacity_nq_wouldblock_n;
extern atomic_t mxfs_dl_capacity_park_n;
extern int mxfs_dl_capacity_reclaim;
extern atomic_t mxfs_dl_capacity_reclaim_n;

#define FILL MXFS_TAUTH_ENTRIES_PER_PAGE
/* the no-queue laps' retry budget: enough waits to see, short enough to run */
#define NQ_RETRIES 10

/* one no-queue EX try of `res` from `n`; prints and returns the answer */
static int nq_try(const char *lap, struct vnode *n, const struct mxfs_resource_id *res,
                  int *waits, int *nq, int *parks, uint64_t *ms)
{
    uint8_t granted = 0;
    uint64_t t0;
    int rc;

    atomic_set(&mxfs_dl_capacity_wait_local_n, 0);
    atomic_set(&mxfs_dl_capacity_nq_wouldblock_n, 0);
    atomic_set(&mxfs_dl_capacity_park_n, 0);
    t0 = mxfs_pal_time_ms();
    rc = mxfs_dlm_lock_retries(n->dlm, res, MXFS_LOCK_EX, MXFS_LKF_NOQUEUE, &granted,
                               NQ_RETRIES);
    *ms = mxfs_pal_time_ms() - t0;
    *waits = atomic_read(&mxfs_dl_capacity_wait_local_n);
    *nq = atomic_read(&mxfs_dl_capacity_nq_wouldblock_n);
    *parks = atomic_read(&mxfs_dl_capacity_park_n);
    printf("  INFO %s rc=%d granted=%u in %llu ms local_waits=%d wouldblock=%d parks=%d\n",
           lap, rc, granted, (unsigned long long)*ms, *waits, *nq, *parks);
    return rc;
}

int main(void)
{
    struct mxfs_resource_id R[FILL + 2], O;
    mxfs_node_id_t ids[NNODES];
    struct vnode *M, *B;
    struct lock_job *j;
    uint8_t granted = 0;
    uint32_t page;
    uint64_t ino, t0;
    int keep = mxfs_dl_capacity_wait_local;
    int keep_nq = mxfs_dl_capacity_nq_wouldblock;
    int keep_reclaim = mxfs_dl_capacity_reclaim;
    int n, k, rc, filled = 0, waits, nq, parks;
    uint64_t ms;

    tl_mktemp("local_page_full_test");
    printf("=== local_page_full_test file=%s ===\n", tl_path);
    format_region(base, uuid);
    dev = mxfs_pal_bdev_open(tl_path);
    if (!dev) { perror("bdev_open"); return 2; }
    rc = mxfs_tauth_ledger_open(&probe, dev, base, MXFS_TAUTH_REGION_BYTES, uuid, 99, 9999, 63);
    if (rc) { printf("probe open rc=%d\n", rc); return 2; }

    M = node_up(0, 1000, 5000, 1, 1);
    B = node_up(1, 2000, 5001, 2, 1);
    ids[0] = M->id; ids[1] = B->id;
    membership(ids, 2);
    mxfs_pal_sleep_ms(50);

    /* FILL + 2 resources on one page M masters, and one on another page */
    R[0] = res_mastered_by(M, M->id, 128);
    page = tl_page(&R[0]);
    n = 1;
    for (ino = R[0].ino + 1; n < FILL + 2 && ino < R[0].ino + 50000000ULL; ino++) {
        struct mxfs_resource_id r = R[0];

        r.ino = ino;
        if (tl_page(&r) == page && mxfs_dlm_resource_master(M->dlm, &r) == M->id)
            R[n++] = r;
    }
    CHECK(n == FILL + 2, "found %d resources on page %u mastered by M (want %d)",
          n, page, FILL + 2);
    O = res_mastered_by(M, M->id, R[FILL + 1].ino + 1);
    while (tl_page(&O) == page)
        O = res_mastered_by(M, M->id, O.ino + 1);

    /* fill the page with FILL exclusive records */
    for (k = 0; k < FILL; k++) {
        rc = lock_sync(M, &R[k], MXFS_LOCK_EX, &granted);
        if (rc == 0 && granted == MXFS_LOCK_EX)
            filled++;
    }
    settle(M);
    CHECK(filled == FILL, "M holds EX on %d of %d resources on page %u", filled, FILL, page);

    /* laps 1-7 judge the wait and the no-queue answer, with no one asked to
     * make room (laps 8-12 judge that) */
    mxfs_dl_capacity_reclaim = 0;

    /* ── lap 1: the control fails at once ── */
    mxfs_dl_capacity_wait_local = 0;
    atomic_set(&mxfs_dl_capacity_wait_local_n, 0);
    t0 = mxfs_pal_time_ms();
    granted = 0;
    rc = lock_sync(M, &R[FILL], MXFS_LOCK_EX, &granted);
    waits = atomic_read(&mxfs_dl_capacity_wait_local_n);
    printf("  INFO lap1 control rc=%d granted=%u in %llu ms waits=%d\n", rc, granted,
           (unsigned long long)(mxfs_pal_time_ms() - t0), waits);
    CHECK(rc == -EDQUOT,
          "lap1 control the request on the full page fails with the raw -EDQUOT (rc=%d; else "
          "the page was not full or the grant was not M's own, and the A/B judges nothing)", rc);
    CHECK(waits == 0, "lap1 control no wait counted (%d)", waits);

    /* ── lap 2: the same request with the switch on waits, then lands ── */
    mxfs_dl_capacity_wait_local = 1;
    atomic_set(&mxfs_dl_capacity_wait_local_n, 0);
    j = lock_async(M, &R[FILL], MXFS_LOCK_EX, 60);
    mxfs_pal_sleep_ms(300);
    CHECK(!j->done, "lap2 fix the request is still waiting after 300 ms (done=%d rc=%d)",
          j->done, j->rc);
    mxfs_dlm_unlock(M->dlm, &R[0]);
    settle(M);
    /* the budget: 60 attempts of about one second each, and a margin of the
     * same again for the last answer to arrive */
    lock_wait(j, 60 * 2000 + 2000);
    waits = atomic_read(&mxfs_dl_capacity_wait_local_n);
    printf("  INFO lap2 fix done=%d rc=%d granted=%u in %llu ms waits=%d\n", j->done, j->rc,
           j->granted, (unsigned long long)(j->done ? j->t1 - j->t0 : 0), waits);
    CHECK(j->done && j->rc == 0 && j->granted == MXFS_LOCK_EX,
          "lap2 fix granted EX once a record left the page (done=%d rc=%d granted=%u)",
          j->done, j->rc, j->granted);
    CHECK(waits > 0, "lap2 fix the request waited on the full page (%d waits)", waits);
    lock_finish(j);

    /* ── lap 3: switch on, a resource on another page: no wait ── */
    atomic_set(&mxfs_dl_capacity_wait_local_n, 0);
    granted = 0;
    rc = lock_sync(M, &O, MXFS_LOCK_EX, &granted);
    waits = atomic_read(&mxfs_dl_capacity_wait_local_n);
    CHECK(rc == 0 && granted == MXFS_LOCK_EX && waits == 0,
          "lap3 plain EX on another page at once (rc=%d granted=%u waits=%d)", rc, granted, waits);
    mxfs_dlm_unlock(M->dlm, &O);
    settle(M);

    /* ── laps 4-7: a no-queue try on the page, full again from lap 2 ── */
    mxfs_dl_capacity_nq_wouldblock = 0;
    rc = nq_try("lap4 control M", M, &R[FILL + 1], &waits, &nq, &parks, &ms);
    CHECK(rc == -EAGAIN && waits > 0 && ms > 300,
          "lap4 control M's no-queue try waits on the full page before would-block (rc=%d "
          "waits=%d %llu ms; else the page was not full and the laps judge nothing)",
          rc, waits, (unsigned long long)ms);
    /* the parked entry the control left expires before the fix laps */
    mxfs_pal_sleep_ms(2500);

    mxfs_dl_capacity_nq_wouldblock = 1;
    rc = nq_try("lap5 fix M", M, &R[FILL + 1], &waits, &nq, &parks, &ms);
    CHECK(rc == -EAGAIN && waits == 0 && nq == 1 && parks == 0 && ms < 100,
          "lap5 fix M's no-queue try is answered would-block at once, not parked (rc=%d "
          "waits=%d wouldblock=%d parks=%d %llu ms)", rc, waits, nq, parks,
          (unsigned long long)ms);

    rc = nq_try("lap6 fix B", B, &R[FILL + 1], &waits, &nq, &parks, &ms);
    CHECK(rc == -EAGAIN && nq == 1 && parks == 0 && ms < 1000,
          "lap6 fix B's no-queue try of M's full page is answered would-block at once, not "
          "parked (rc=%d wouldblock=%d parks=%d %llu ms)", rc, nq, parks,
          (unsigned long long)ms);

    mxfs_dl_capacity_nq_wouldblock = 0;
    rc = nq_try("lap7 control B", B, &R[FILL + 1], &waits, &nq, &parks, &ms);
    CHECK(rc == -EAGAIN && nq == 0 && ms > 300,
          "lap7 control B's no-queue try waits on the full page before would-block (rc=%d "
          "wouldblock=%d %llu ms)", rc, nq, (unsigned long long)ms);
    mxfs_pal_sleep_ms(2500);
    mxfs_dl_capacity_nq_wouldblock = keep_nq;

    /* ── laps 8-9: the page full of M's own idle grants, which M releases
     * when asked (auto_release); the page holds R[1..FILL] ── */
    M->auto_release = 1;
    mxfs_dl_capacity_reclaim = 0;
    atomic_set(&mxfs_dl_capacity_reclaim_n, 0);
    M->basts = 0;
    j = lock_async(M, &R[FILL + 1], MXFS_LOCK_EX, 60);
    mxfs_pal_sleep_ms(1000);
    printf("  INFO lap8 control done=%d basts=%d reclaim_n=%d\n", j->done, M->basts,
           atomic_read(&mxfs_dl_capacity_reclaim_n));
    CHECK(!j->done && M->basts == 0 && atomic_read(&mxfs_dl_capacity_reclaim_n) == 0,
          "lap8 control nobody is asked to make room: the request still waits after 1000 ms "
          "and no record's holder was notified (done=%d basts=%d reclaim_n=%d)",
          j->done, M->basts, atomic_read(&mxfs_dl_capacity_reclaim_n));
    /* end it the way lap 2 does, then refill: R[1] becomes the newest record */
    mxfs_dlm_unlock(M->dlm, &R[1]);
    settle(M);
    lock_wait(j, 60 * 2000 + 2000);
    CHECK(j->done && j->rc == 0 && j->granted == MXFS_LOCK_EX,
          "lap8 control granted once a record left the page (done=%d rc=%d)", j->done, j->rc);
    lock_finish(j);
    mxfs_dlm_unlock(M->dlm, &R[FILL + 1]);
    settle(M);
    rc = lock_sync(M, &R[1], MXFS_LOCK_EX, &granted);
    settle(M);
    CHECK(rc == 0 && granted == MXFS_LOCK_EX, "lap9 setup M holds R[1] again, the newest record "
          "(rc=%d granted=%u)", rc, granted);

    mxfs_dl_capacity_reclaim = 1;
    atomic_set(&mxfs_dl_capacity_reclaim_n, 0);
    M->basts = 0;
    j = lock_async(M, &R[FILL + 1], MXFS_LOCK_EX, 60);
    lock_wait(j, 3000);
    printf("  INFO lap9 fix done=%d rc=%d granted=%u in %llu ms basts=%d reclaim_n=%d "
           "R2=%u R9=%u R10=%u R1=%u\n", j->done, j->rc, j->granted,
           (unsigned long long)(j->done ? j->t1 - j->t0 : 0), M->basts,
           atomic_read(&mxfs_dl_capacity_reclaim_n), mxfs_dlm_held_mode(M->dlm, &R[2]),
           mxfs_dlm_held_mode(M->dlm, &R[9]), mxfs_dlm_held_mode(M->dlm, &R[10]),
           mxfs_dlm_held_mode(M->dlm, &R[1]));
    CHECK(j->done && j->rc == 0 && j->granted == MXFS_LOCK_EX && j->t1 - j->t0 < 1500,
          "lap9 fix the holders were asked and the request granted within 1500 ms (done=%d "
          "rc=%d granted=%u %llu ms)", j->done, j->rc, j->granted,
          (unsigned long long)(j->done ? j->t1 - j->t0 : 0));
    CHECK(atomic_read(&mxfs_dl_capacity_reclaim_n) >= 1 && M->basts >= 1,
          "lap9 fix release notifications were fired (reclaim_n=%d basts=%d)",
          atomic_read(&mxfs_dl_capacity_reclaim_n), M->basts);
    CHECK(mxfs_dlm_held_mode(M->dlm, &R[2]) == MXFS_LOCK_NL &&
          mxfs_dlm_held_mode(M->dlm, &R[9]) == MXFS_LOCK_NL &&
          mxfs_dlm_held_mode(M->dlm, &R[10]) == MXFS_LOCK_EX &&
          mxfs_dlm_held_mode(M->dlm, &R[1]) == MXFS_LOCK_EX,
          "lap9 fix the %d oldest records were the ones asked: R[2..9] released, R[10] and the "
          "newest R[1] kept", MXFS_TAUTH_INO_SHARD);
    lock_finish(j);
    M->auto_release = 0;
    for (k = 0; k <= FILL + 1; k++)
        mxfs_dlm_unlock(M->dlm, &R[k]);
    settle(M);

    /* ── laps 10-11: the page full of B's grants (a remote holder, the
     * 4-node shape), M asks for one more ── */
    filled = 0;
    for (k = 1; k <= FILL; k++) {
        rc = lock_sync(B, &R[k], MXFS_LOCK_EX, &granted);
        if (rc == 0 && granted == MXFS_LOCK_EX)
            filled++;
    }
    settle(M);
    settle(B);
    CHECK(filled == FILL, "lap10 setup B holds EX on %d of %d resources on M's page %u",
          filled, FILL, page);
    B->auto_release = 1;
    mxfs_dl_capacity_reclaim = 0;
    B->basts = 0;
    j = lock_async(M, &R[FILL + 1], MXFS_LOCK_EX, 60);
    mxfs_pal_sleep_ms(1000);
    printf("  INFO lap10 control done=%d basts_B=%d\n", j->done, B->basts);
    CHECK(!j->done && B->basts == 0,
          "lap10 control the request still waits after 1000 ms and B was not notified "
          "(done=%d basts_B=%d)", j->done, B->basts);
    mxfs_dl_capacity_reclaim = 1;
    atomic_set(&mxfs_dl_capacity_reclaim_n, 0);
    lock_wait(j, 3000);
    printf("  INFO lap11 fix done=%d rc=%d granted=%u basts_B=%d reclaim_n=%d\n", j->done,
           j->rc, j->granted, B->basts, atomic_read(&mxfs_dl_capacity_reclaim_n));
    CHECK(j->done && j->rc == 0 && j->granted == MXFS_LOCK_EX && B->basts >= 1,
          "lap11 fix with the switch on, B was asked, released, and the waiting request was "
          "granted within 3000 ms (done=%d rc=%d basts_B=%d)", j->done, j->rc, B->basts);
    lock_finish(j);
    B->auto_release = 0;
    mxfs_dlm_unlock(M->dlm, &R[FILL + 1]);
    for (k = 0; k <= FILL + 1; k++)
        mxfs_dlm_unlock(B->dlm, &R[k]);
    settle(M);
    settle(B);

    /* ── lap 12: B, a remote requester, asks for one more on a page full of
     * M's own grants; the master asks itself to make room ── */
    filled = 0;
    for (k = 1; k <= FILL; k++) {
        rc = lock_sync(M, &R[k], MXFS_LOCK_EX, &granted);
        if (rc == 0 && granted == MXFS_LOCK_EX)
            filled++;
    }
    settle(M);
    M->auto_release = 1;
    M->basts = 0;
    atomic_set(&mxfs_dl_capacity_reclaim_n, 0);
    j = lock_async(B, &R[FILL + 1], MXFS_LOCK_EX, 60);
    lock_wait(j, 3000);
    printf("  INFO lap12 fix filled=%d done=%d rc=%d granted=%u basts_M=%d reclaim_n=%d\n",
           filled, j->done, j->rc, j->granted, M->basts,
           atomic_read(&mxfs_dl_capacity_reclaim_n));
    CHECK(filled == FILL && j->done && j->rc == 0 && j->granted == MXFS_LOCK_EX &&
          M->basts >= 1,
          "lap12 fix B's request on M's full page is granted within 3000 ms once M releases "
          "its oldest records (filled=%d done=%d rc=%d basts_M=%d)", filled, j->done, j->rc,
          M->basts);
    lock_finish(j);
    M->auto_release = 0;
    mxfs_dlm_unlock(B->dlm, &R[FILL + 1]);
    settle(B);

    mxfs_dl_capacity_reclaim = keep_reclaim;
    mxfs_dl_capacity_wait_local = keep;
    for (k = 0; k <= FILL + 1; k++)
        mxfs_dlm_unlock(M->dlm, &R[k]);
    settle(M);
    node_down(B);
    node_down(M);
    mxfs_tauth_ledger_close(&probe);
    mxfs_pal_bdev_close(dev);
    unlink(tl_path);
    printf("=== local_page_full_test RESULT %s fails=%d ===\n",
           tl_fails ? "FAIL" : "PASS", tl_fails);
    return tl_fails ? 1 : 0;
}
