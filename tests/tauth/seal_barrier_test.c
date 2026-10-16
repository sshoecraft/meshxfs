// SPDX-License-Identifier: GPL-2.0
/*
 * seal_barrier_test — a fenced victim that is still on the network cannot
 * retire a ledger record through ANOTHER master after the prover's seal.
 *
 * On TCP each ledger page is committed by its own master.  At a victim's
 * fence-time snapshot the prover seals the victim and collects its records;
 * until 0.90.129 only the prover sealed.  A victim whose storage was gone but
 * whose network was not (net/mesh/mpath, path_all_lost) kept releasing for
 * the ~35 s until its own lease ran out, the other masters retired those
 * records, and the replay read the gap as a post-seal mutation and
 * quarantined the whole filesystem (2026-10-15, 4 and 8 nodes).
 * mxfs_dlm_seal_barrier asks every live member to seal and waits for each.
 *
 * Three nodes: P the prover, M the master of resource R, V the victim, which
 * holds R exclusively.
 *   1 control: P seals V only locally (the old cut); V's release reaches M,
 *     and the platter record of R no longer names V -- the mutation.
 *   2 barrier: V takes R again; P runs the barrier; M is sealed; V's release
 *     reaches M and is refused, and the record still names V.
 *   3 a member that never answers: M ignores the seal; the barrier fails
 *     -EAGAIN after its bound, so the snapshot is retried rather than taken.
 */
#define NNODES 3
#include "dlm_mesh.h"

/* does R's platter record name `node` as its exclusive holder? */
static int held_by(const struct mxfs_resource_id *r, mxfs_node_id_t node)
{
    struct mxfs_tauth_entry e;

    if (probe_lookup(r, &e))
        return -1;
    return e.state == MXFS_TAUTH_ST_ACTIVE && e.ex_node == node;
}

/* wait up to ms for held_by(r, node) to equal want */
static int wait_held(const struct mxfs_resource_id *r, mxfs_node_id_t node, int want,
                     uint64_t ms)
{
    uint64_t t0 = mxfs_pal_time_ms();
    int h;

    for (;;) {
        h = held_by(r, node);
        if (h == want || mxfs_pal_time_ms() - t0 > ms)
            return h;
        mxfs_pal_sleep_ms(10);
    }
}

static int sealed_on(struct vnode *n, mxfs_node_id_t victim)
{
    int i, s = 0;

    mxfs_pal_rwlock_rdlock(n->dlm->table_rwlock);
    for (i = 0; i < n->dlm->sealed_owner_count; i++)
        if (n->dlm->sealed_owners[i].node == victim)
            s = 1;
    mxfs_pal_rwlock_unlock(n->dlm->table_rwlock);
    return s;
}

int main(void)
{
    struct mxfs_resource_id R;
    mxfs_node_id_t ids[NNODES];
    struct vnode *P, *M, *V;
    uint8_t granted = 0;
    uint64_t refused0, t0, ms;
    int rc;

    tl_mktemp("seal_barrier_test");
    printf("=== seal_barrier_test file=%s ===\n", tl_path);
    format_region(base, uuid);
    dev = mxfs_pal_bdev_open(tl_path);
    if (!dev) { perror("bdev_open"); return 2; }
    rc = mxfs_tauth_ledger_open(&probe, dev, base, MXFS_TAUTH_REGION_BYTES, uuid, 99, 9999, 63);
    if (rc) { printf("probe open rc=%d\n", rc); return 2; }

    P = node_up(0, 1000, 5000, 1, 1);
    M = node_up(1, 2000, 5001, 2, 1);
    V = node_up(2, 3000, 5002, 3, 1);
    ids[0] = P->id; ids[1] = M->id; ids[2] = V->id;
    membership(ids, 3);
    mxfs_pal_sleep_ms(50);
    R = res_mastered_by(P, M->id, 128);
    printf("  R ino=%llu master=%u victim=%u prover=%u\n",
           (unsigned long long)R.ino, M->id, V->id, P->id);

    /* ── 1 control: the prover's local seal alone ── */
    rc = lock_sync(V, &R, MXFS_LOCK_EX, &granted);
    CHECK(rc == 0 && granted == MXFS_LOCK_EX, "1 V holds R EX (rc=%d)", rc);
    CHECK(wait_held(&R, V->id, 1, 2000) == 1, "1 the platter record names V");
    rc = mxfs_dlm_seal_owner(P->dlm, V->id, V->inc);
    CHECK(rc == 0 && sealed_on(P, V->id) && !sealed_on(M, V->id),
          "1 the old cut seals V on P only (rc=%d P=%d M=%d)", rc,
          sealed_on(P, V->id), sealed_on(M, V->id));
    mxfs_dlm_unlock(V->dlm, &R);
    CHECK(wait_held(&R, V->id, 0, 3000) == 0,
          "1 control: V's release retired R at its master after the seal (the mutation)");
    settle(P);

    /* ── 2 the barrier ── */
    rc = lock_sync(V, &R, MXFS_LOCK_EX, &granted);
    CHECK(rc == 0 && granted == MXFS_LOCK_EX, "2 V holds R EX again (rc=%d)", rc);
    CHECK(wait_held(&R, V->id, 1, 2000) == 1, "2 the platter record names V");
    t0 = mxfs_pal_time_ms();
    rc = mxfs_dlm_seal_barrier(P->dlm, V->id, V->inc);
    ms = mxfs_pal_time_ms() - t0;
    CHECK(rc == 0 && sealed_on(M, V->id),
          "2 the barrier sealed V on M too (rc=%d M=%d ms=%llu)", rc, sealed_on(M, V->id),
          (unsigned long long)ms);
    refused0 = M->dlm->sealed_releases_refused;
    mxfs_dlm_unlock(V->dlm, &R);
    mxfs_pal_sleep_ms(1500);    /* V's release and a retry tick's re-send reach M */
    CHECK(M->dlm->sealed_releases_refused > refused0,
          "2 M refused V's release (refused %llu -> %llu)", (unsigned long long)refused0,
          (unsigned long long)M->dlm->sealed_releases_refused);
    CHECK(held_by(&R, V->id) == 1, "2 the platter record still names V after the seal");

    /* ── 3 a member that never answers ── */
    M->drop_seals = 1;
    t0 = mxfs_pal_time_ms();
    rc = mxfs_dlm_seal_barrier(P->dlm, V->id, V->inc);
    ms = mxfs_pal_time_ms() - t0;
    CHECK(rc == -EAGAIN && ms >= 4000 && ms < 6000,
          "3 an unanswered member fails the barrier -EAGAIN after its bound (rc=%d ms=%llu)",
          rc, (unsigned long long)ms);

    node_down(V);
    node_down(M);
    node_down(P);
    mxfs_tauth_ledger_close(&probe);
    mxfs_pal_bdev_close(dev);
    unlink(tl_path);
    printf("=== seal_barrier_test RESULT %s fails=%d ===\n",
           tl_fails ? "FAIL" : "PASS", tl_fails);
    return tl_fails ? 1 : 0;
}
