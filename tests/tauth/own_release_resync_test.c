// SPDX-License-Identifier: GPL-2.0
/*
 * own_release_resync_test — a master's release of its own exclusive grant
 * must retire the record the page holds for it.
 *
 * Measured on 2/net/mesh/mpath path_fenced_return (D-MASTER-OWN): the
 * survivor took the fenced peer's ledger page over and re-granted its own EX
 * on an inode under its own authority (P-TAUTH-ADOPT-REGRANT), then the
 * thawed peer's fenced incarnation reconnected and its LOCK_GRANT re-affirm
 * of the old grant id was processed (P74-GRANT matched=0 have_mirror=1),
 * overwriting the id in the survivor's table entry.  The survivor's next
 * release of that EX named the old id, the ledger applied it as stale, the
 * finalize freed the entry, and the record kept naming the survivor's EX:
 * every later grant of the inode to the peer was refused as a double grant
 * (P-TAUTH-DOUBLE-GRANT), the peer's operations failed after their retry
 * budget and its unmount stuck.
 *
 * Shape: M masters R and holds EX on it; a LOCK_GRANT re-affirm for R naming
 * another authority epoch and grant seq is processed by M (the trigger); B
 * asks for PR and M releases its EX on the BAST.  Lap 1 runs with
 * dl_own_release_resync=0 and must strand (otherwise the injection reproduced
 * nothing and the A/B judges nothing).  Lap 2 runs the same steps with the
 * switch on: B is granted, the record no longer names M, the release was
 * re-pointed once.  Lap 3 is an ordinary EX release and PR hand-off with the
 * switch on: no re-pointing.
 */
#define NNODES 2
#include "dlm_mesh.h"
#include "dlm/dlm_user_compat.h"

extern int mxfs_dl_own_release_resync;
extern atomic_t mxfs_dl_own_release_resync_n;

static int same_res(const struct mxfs_resource_id *a, const struct mxfs_resource_id *b)
{
    return a->type == b->type && a->ino == b->ino && a->ag_number == b->ag_number;
}

/* the grant id M's own GRANTED entry for R carries; 0 = no such entry */
static int own_entry_id(struct vnode *n, const struct mxfs_resource_id *r,
                        uint64_t *auth, uint64_t *seq, uint32_t *gen)
{
    struct mxfs_lock *lk;
    uint32_t b;
    int found = 0;

    mxfs_pal_rwlock_rdlock(n->dlm->table_rwlock);
    for (b = 0; b < n->dlm->bucket_count && !found; b++)
        for (lk = n->dlm->buckets[b]; lk; lk = lk->next)
            if (lk->owner == n->id && lk->state == MXFS_LSTATE_GRANTED &&
                same_res(&lk->resource, r)) {
                *auth = lk->auth_epoch;
                *seq = lk->grant_seq;
                *gen = lk->grant_gen;
                found = 1;
                break;
            }
    mxfs_pal_rwlock_unlock(n->dlm->table_rwlock);
    return found;
}

/* a re-affirm GRANT for M's own EX naming a grant id the record does not */
static void inject_reaffirm(struct vnode *m, struct vnode *from,
                            const struct mxfs_resource_id *r, uint32_t gen,
                            uint64_t auth, uint64_t seq)
{
    struct mxfs_dlm_lock_resp resp;

    memset(&resp, 0, sizeof(resp));
    resp.hdr.magic = MXFS_DLM_MAGIC;
    resp.hdr.version = MXFS_DLM_VERSION;
    resp.hdr.type = MXFS_MSG_LOCK_GRANT;
    resp.hdr.length = sizeof(resp);
    resp.hdr.sender = from->id;
    resp.hdr.target = m->id;
    resp.hdr.epoch = mxfs_dlm_get_epoch(m->dlm);
    resp.resource = *r;
    resp.mode = MXFS_LOCK_EX;
    resp.status = MXFS_OK;
    resp.grant_gen = gen;
    resp.authority_epoch = auth;
    resp.grant_seq64 = seq;
    mxfs_dlm_process_remote_grant(m->dlm, &resp);
}

struct lap_out {
    int injected;       /* M's entry carried the injected id before the release */
    int b_granted;      /* B's PR granted within its budget */
    uint64_t b_ms;
    int m_holds;        /* M's held mode after the release */
    int rec_names_m;    /* the platter record still names M as EX */
    int resynced;       /* dl_own_release_resync_n after the lap */
};

/* M takes EX on R; optionally the re-affirm; B asks PR with `retries`; M
 * releases on the BAST */
static struct lap_out run_lap(const char *lap, struct vnode *M, struct vnode *B,
                              const struct mxfs_resource_id *R, int inject, int retries)
{
    struct lap_out o;
    struct mxfs_tauth_entry e;
    struct lock_job *j;
    uint64_t auth = 0, seq = 0, a2 = 0, s2 = 0;
    uint32_t gen = 0, g2 = 0;
    uint8_t granted = 0;
    int rc;

    memset(&o, 0, sizeof(o));
    rc = lock_sync(M, R, MXFS_LOCK_EX, &granted);
    CHECK(rc == 0 && granted == MXFS_LOCK_EX, "%s M EX on R ino=%llu rc=%d granted=%u",
          lap, (unsigned long long)R->ino, rc, granted);
    settle(M);
    rc = probe_lookup(R, &e);
    CHECK(rc == 0 && e.state == MXFS_TAUTH_ST_ACTIVE && e.ex_node == M->id,
          "%s the platter names M's EX: rc=%d state=%u ex=%u id={%llu,%llu}", lap, rc,
          e.state, e.ex_node, (unsigned long long)e.authority_epoch,
          (unsigned long long)e.grant_seq64);
    if (!own_entry_id(M, R, &auth, &seq, &gen)) {
        CHECK(0, "%s M has its GRANTED entry for R", lap);
        return o;
    }
    if (inject) {
        inject_reaffirm(M, B, R, gen, e.authority_epoch + 1000003ULL,
                        e.grant_seq64 > 1 ? e.grant_seq64 - 1 : e.grant_seq64 + 7);
        own_entry_id(M, R, &a2, &s2, &g2);
        o.injected = (a2 != e.authority_epoch || s2 != e.grant_seq64);
        printf("  INFO %s entry id before={%llu,%llu} after re-affirm={%llu,%llu} record={%llu,%llu}\n",
               lap, (unsigned long long)auth, (unsigned long long)seq,
               (unsigned long long)a2, (unsigned long long)s2,
               (unsigned long long)e.authority_epoch, (unsigned long long)e.grant_seq64);
    }
    M->auto_release = 1;
    j = lock_async(B, R, MXFS_LOCK_PR, retries);
    /* the budget: `retries` attempts of about one second each, and a margin of
     * the same again for the last answer to arrive */
    lock_wait(j, (uint64_t)retries * 2000 + 2000);
    o.b_granted = j->done && j->rc == 0 && j->granted == MXFS_LOCK_PR;
    o.b_ms = j->done ? j->t1 - j->t0 : 0;
    M->auto_release = 0;
    settle(M);
    o.m_holds = mxfs_dlm_held_mode(M->dlm, R);
    rc = probe_lookup(R, &e);
    o.rec_names_m = (rc == 0 && e.state == MXFS_TAUTH_ST_ACTIVE && e.ex_node == M->id);
    o.resynced = atomic_read(&mxfs_dl_own_release_resync_n);
    printf("  INFO %s B granted=%d in %llu ms (rc=%d done=%d) M holds=%u record ex=%u "
           "holders=%#llx resynced=%d\n", lap, o.b_granted, (unsigned long long)o.b_ms,
           j->rc, j->done, o.m_holds, e.ex_node, (unsigned long long)e.holders, o.resynced);
    if (!j->done)
        lock_wait(j, (uint64_t)retries * 2000 + 2000);
    lock_finish(j);
    if (o.b_granted) {
        mxfs_dlm_unlock(B->dlm, R);
        settle(B);
    }
    return o;
}

int main(void)
{
    struct mxfs_resource_id R1, R2, R3;
    mxfs_node_id_t ids[NNODES];
    struct vnode *M, *B;
    struct lap_out o;
    int keep = mxfs_dl_own_release_resync;
    int rc;

    tl_mktemp("own_release_resync_test");
    printf("=== own_release_resync_test file=%s ===\n", tl_path);
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
    R1 = res_mastered_by(M, M->id, 128);
    R2 = res_mastered_by(M, M->id, R1.ino + 1);
    R3 = res_mastered_by(M, M->id, R2.ino + 1);

    /* ── lap 1: the control strands ── */
    mxfs_dl_own_release_resync = 0;
    atomic_set(&mxfs_dl_own_release_resync_n, 0);
    o = run_lap("lap1 control", M, B, &R1, 1, 4);
    CHECK(o.injected, "lap1 control the re-affirm rewrote M's entry id (else VACUOUS)");
    CHECK(!o.b_granted && o.m_holds == MXFS_LOCK_NL && o.rec_names_m,
          "lap1 control STRANDS: B refused=%d, M holds nothing=%d, the record still names M=%d "
          "(else the injection reproduced nothing and the A/B judges nothing)",
          !o.b_granted, o.m_holds == MXFS_LOCK_NL, o.rec_names_m);
    CHECK(o.resynced == 0, "lap1 control no release re-pointed (%d)", o.resynced);

    /* ── lap 2: the same with the switch on ── */
    mxfs_dl_own_release_resync = 1;
    atomic_set(&mxfs_dl_own_release_resync_n, 0);
    o = run_lap("lap2 fix", M, B, &R2, 1, 4);
    CHECK(o.injected, "lap2 fix the re-affirm rewrote M's entry id (else VACUOUS)");
    CHECK(o.b_granted, "lap2 fix B granted PR in %llu ms", (unsigned long long)o.b_ms);
    CHECK(o.m_holds == MXFS_LOCK_NL && !o.rec_names_m,
          "lap2 fix M holds nothing and the record no longer names M (holds=%u names=%d)",
          o.m_holds, o.rec_names_m);
    CHECK(o.resynced == 1, "lap2 fix the release was re-pointed at the record once (%d)",
          o.resynced);

    /* ── lap 3: no re-affirm, switch on: an ordinary hand-off ── */
    atomic_set(&mxfs_dl_own_release_resync_n, 0);
    o = run_lap("lap3 plain", M, B, &R3, 0, 4);
    CHECK(o.b_granted && o.m_holds == MXFS_LOCK_NL && !o.rec_names_m,
          "lap3 plain B granted in %llu ms, M holds nothing, record free of M",
          (unsigned long long)o.b_ms);
    CHECK(o.resynced == 0, "lap3 plain no release re-pointed (%d)", o.resynced);

    mxfs_dl_own_release_resync = keep;
    node_down(B);
    node_down(M);
    mxfs_tauth_ledger_close(&probe);
    mxfs_pal_bdev_close(dev);
    unlink(tl_path);
    printf("=== own_release_resync_test RESULT %s fails=%d ===\n",
           tl_fails ? "FAIL" : "PASS", tl_fails);
    return tl_fails ? 1 : 0;
}
