// SPDX-License-Identifier: GPL-2.0
/*
 * capacity_park_test — a request refused for a full ledger page keeps its
 * place in the resource's queue.
 *
 * Measured on 2/net/mesh/mpath after a fenced peer rejoined: the publish
 * drain's claim of a child its creator held EX only locally waited out its
 * budget on full ledger pages
 * (D-SURVIVOR-DEFERRED-PUBLISH-EX-CLAIM-FAILS-AFTER-60-REMASTER-RETRIES-AT-REJOIN).
 * The master freed the claim's table entry at every capacity refusal, so a
 * peer asking for the child once the drain window ended was decided against
 * an empty queue and could take the next free entry before the claim.
 *
 * Shape: three nodes; M masters page P and fills it with exclusive records.
 * Each lap's resource T is one on P that M was just refused for (so the page
 * is full and T has no record).  B asks EX on T and is refused; M releases
 * one of its records; a latecomer asks PR on T.  B and the latecomer release
 * on a blocking notification.
 *   lap 1 CONTROL (dl_capacity_park=0), latecomer C: C must be granted first
 *     (the inversion), else the lap reproduced nothing and the A/B judges
 *     nothing.
 *   lap 2 FIX: the same; B must be granted first, C after it, and
 *     dl_capacity_park_n counts the park.
 *   lap 3 FIX, latecomer M itself (the master's own request): B first.
 *   lap 4 FIX: B gives up after a few refusals and asks no more; C must be
 *     granted within the park lifetime (MXFS_CAP_PARK_TTL_MS, 2 s) and 2 s.
 *   lap 5 FIX: EX on a resource of another page, granted at once, no park.
 */
#define NNODES 3
#include "dlm_mesh.h"
#include "dlm/dlm_user_compat.h"

extern int mxfs_dl_capacity_wait_local;
extern int mxfs_dl_capacity_park;
extern atomic_t mxfs_dl_capacity_park_n;

#define FILL MXFS_TAUTH_ENTRIES_PER_PAGE
#define NCAND (FILL + 16)

static struct mxfs_resource_id cand[NCAND];
static int held[NCAND];         /* M holds EX on cand[k] */
static int used[NCAND];         /* cand[k] was a lap's T */
static struct vnode *M, *B, *C;

/* Fill page P with M's exclusive records; the first candidate M is refused
 * for is the lap's T (no record of it on P, and P full).  -1 if none. */
static int refill(void)
{
    int keep_wait = mxfs_dl_capacity_wait_local, keep_park = mxfs_dl_capacity_park;
    int k, rc, t = -1;
    uint8_t granted;

    mxfs_dl_capacity_wait_local = 0;
    mxfs_dl_capacity_park = 0;
    for (k = 0; k < NCAND; k++) {
        if (held[k] || used[k])
            continue;
        granted = 0;
        rc = lock_sync(M, &cand[k], MXFS_LOCK_EX, &granted);
        if (rc == 0 && granted == MXFS_LOCK_EX) {
            held[k] = 1;
            continue;
        }
        if (rc == -EDQUOT) {
            t = k;
            used[k] = 1;
            break;
        }
        printf("  INFO refill cand %d rc=%d granted=%u\n", k, rc, granted);
    }
    settle(M);
    mxfs_dl_capacity_wait_local = keep_wait;
    mxfs_dl_capacity_park = keep_park;
    return t;
}

static void release_one_filler(void)
{
    int k;

    for (k = 0; k < NCAND; k++)
        if (held[k]) {
            mxfs_dlm_unlock(M->dlm, &cand[k]);
            held[k] = 0;
            return;
        }
}

/* B asks EX on T and is refused; M frees one entry; `late` asks PR on T.
 * Returns 1 if B was granted first, 0 if the latecomer was, -1 otherwise. */
static int race(const char *lap, const struct mxfs_resource_id *T, struct vnode *late,
                int b_budget, uint64_t *late_ms)
{
    struct lock_job *jb, *jl;
    int first = -1;

    jb = lock_async(B, T, MXFS_LOCK_EX, b_budget);
    mxfs_pal_sleep_ms(300);
    printf("  INFO %s B after 300 ms done=%d rc=%d\n", lap, jb->done, jb->rc);
    if (b_budget > 10)
        CHECK(!jb->done, "%s B's EX request is still waiting on the full page after 300 ms "
              "(done=%d rc=%d; else the page was not full and the lap judges nothing)",
              lap, jb->done, jb->rc);
    else
        lock_wait(jb, 10000);
    release_one_filler();
    jl = lock_async(late, T, MXFS_LOCK_PR, 60);
    lock_wait(jl, 30000);
    if (!jb->done)
        lock_wait(jb, 30000);
    printf("  INFO %s B done=%d rc=%d granted=%u t1=%llu | late done=%d rc=%d granted=%u "
           "t1=%llu wait_ms=%llu\n", lap, jb->done, jb->rc, jb->granted,
           (unsigned long long)jb->t1, jl->done, jl->rc, jl->granted,
           (unsigned long long)jl->t1, (unsigned long long)(jl->t1 - jl->t0));
    *late_ms = jl->done ? jl->t1 - jl->t0 : 0;
    if (jb->done && jb->rc == 0 && jl->done && jl->rc == 0)
        first = jb->t1 <= jl->t1 ? 1 : 0;
    else if (jl->done && jl->rc == 0 && (!jb->done || jb->rc != 0))
        first = 0;
    /* whatever is still held on T goes before the next lap */
    if (jb->done && jb->rc == 0)
        mxfs_dlm_unlock(B->dlm, T);
    if (jl->done && jl->rc == 0)
        mxfs_dlm_unlock(late->dlm, T);
    lock_finish(jb);
    lock_finish(jl);
    settle(M);
    return first;
}

int main(void)
{
    mxfs_node_id_t ids[NNODES];
    struct mxfs_resource_id O;
    uint32_t page;
    uint64_t ino, late_ms;
    int keep = mxfs_dl_capacity_park;
    int n, k, t, first, parks, rc;
    uint8_t granted;

    tl_mktemp("capacity_park_test");
    printf("=== capacity_park_test file=%s ===\n", tl_path);
    format_region(base, uuid);
    dev = mxfs_pal_bdev_open(tl_path);
    if (!dev) { perror("bdev_open"); return 2; }
    rc = mxfs_tauth_ledger_open(&probe, dev, base, MXFS_TAUTH_REGION_BYTES, uuid, 99, 9999, 63);
    if (rc) { printf("probe open rc=%d\n", rc); return 2; }

    M = node_up(0, 1000, 5000, 1, 1);
    B = node_up(1, 2000, 5001, 2, 1);
    C = node_up(2, 3000, 5002, 3, 1);
    ids[0] = M->id; ids[1] = B->id; ids[2] = C->id;
    membership(ids, 3);
    mxfs_pal_sleep_ms(50);
    B->auto_release = 1;
    C->auto_release = 1;

    cand[0] = res_mastered_by(M, M->id, 128);
    page = tl_page(&cand[0]);
    n = 1;
    for (ino = cand[0].ino + 1; n < NCAND && ino < cand[0].ino + 50000000ULL; ino++) {
        struct mxfs_resource_id r = cand[0];

        r.ino = ino;
        if (tl_page(&r) == page && mxfs_dlm_resource_master(M->dlm, &r) == M->id)
            cand[n++] = r;
    }
    CHECK(n == NCAND, "found %d resources on page %u mastered by M (want %d)", n, page, NCAND);
    O = res_mastered_by(M, M->id, cand[NCAND - 1].ino + 1);
    while (tl_page(&O) == page)
        O = res_mastered_by(M, M->id, O.ino + 1);

    /* ── lap 1: CONTROL, the latecomer C overtakes B ── */
    t = refill();
    CHECK(t >= 0, "lap1 page %u filled and a resource refused for it (t=%d)", page, t);
    mxfs_dl_capacity_park = 0;
    atomic_set(&mxfs_dl_capacity_park_n, 0);
    first = race("lap1 control", &cand[t], C, 60, &late_ms);
    parks = atomic_read(&mxfs_dl_capacity_park_n);
    printf("  INFO lap1 control first=%s parks=%d\n",
           first == 1 ? "B" : first == 0 ? "C" : "none", parks);
    CHECK(first == 0, "lap1 control the latecomer C is granted before B, the earlier "
          "requester (first=%d; else the inversion was not reproduced and the A/B judges "
          "nothing)", first);
    CHECK(parks == 0, "lap1 control nothing parked (%d)", parks);

    /* ── lap 2: FIX, B keeps its place ── */
    t = refill();
    CHECK(t >= 0, "lap2 page refilled (t=%d)", t);
    mxfs_dl_capacity_park = 1;
    atomic_set(&mxfs_dl_capacity_park_n, 0);
    first = race("lap2 fix", &cand[t], C, 60, &late_ms);
    parks = atomic_read(&mxfs_dl_capacity_park_n);
    printf("  INFO lap2 fix first=%s parks=%d\n",
           first == 1 ? "B" : first == 0 ? "C" : "none", parks);
    CHECK(first == 1, "lap2 fix B, the earlier requester, is granted before C (first=%d)",
          first);
    CHECK(parks > 0, "lap2 fix B's refusal was parked (%d)", parks);

    /* ── lap 3: FIX, the latecomer is the master itself ── */
    t = refill();
    CHECK(t >= 0, "lap3 page refilled (t=%d)", t);
    atomic_set(&mxfs_dl_capacity_park_n, 0);
    M->auto_release = 0;
    first = race("lap3 fix-local", &cand[t], M, 60, &late_ms);
    printf("  INFO lap3 fix-local first=%s parks=%d\n",
           first == 1 ? "B" : first == 0 ? "M" : "none", atomic_read(&mxfs_dl_capacity_park_n));
    CHECK(first == 1, "lap3 fix B is granted before the master's own later request "
          "(first=%d)", first);

    /* ── lap 4: FIX, a parked request whose owner gave up expires ── */
    t = refill();
    CHECK(t >= 0, "lap4 page refilled (t=%d)", t);
    atomic_set(&mxfs_dl_capacity_park_n, 0);
    first = race("lap4 fix-expiry", &cand[t], C, 3, &late_ms);
    parks = atomic_read(&mxfs_dl_capacity_park_n);
    printf("  INFO lap4 fix-expiry first=%s parks=%d late_ms=%llu\n",
           first == 1 ? "B" : first == 0 ? "C" : "none", parks,
           (unsigned long long)late_ms);
    CHECK(parks > 0, "lap4 fix-expiry B's refusals were parked (%d)", parks);
    CHECK(first == 0 && late_ms > 0 && late_ms <= 2000 + 2000,
          "lap4 fix-expiry C granted within the park lifetime and 2 s after B gave up "
          "(first=%d late_ms=%llu)", first, (unsigned long long)late_ms);

    /* ── lap 5: FIX, another page: at once, nothing parked ── */
    atomic_set(&mxfs_dl_capacity_park_n, 0);
    granted = 0;
    rc = lock_sync(B, &O, MXFS_LOCK_EX, &granted);
    parks = atomic_read(&mxfs_dl_capacity_park_n);
    CHECK(rc == 0 && granted == MXFS_LOCK_EX && parks == 0,
          "lap5 plain EX on another page at once (rc=%d granted=%u parks=%d)", rc, granted,
          parks);
    mxfs_dlm_unlock(B->dlm, &O);

    mxfs_dl_capacity_park = keep;
    for (k = 0; k < NCAND; k++)
        if (held[k])
            mxfs_dlm_unlock(M->dlm, &cand[k]);
    settle(M);
    node_down(C);
    node_down(B);
    node_down(M);
    mxfs_tauth_ledger_close(&probe);
    mxfs_pal_bdev_close(dev);
    unlink(tl_path);
    printf("=== capacity_park_test RESULT %s fails=%d ===\n",
           tl_fails ? "FAIL" : "PASS", tl_fails);
    return tl_fails ? 1 : 0;
}
