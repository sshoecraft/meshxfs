// SPDX-License-Identifier: GPL-2.0
/*
 * fenced_node_ledger_test — D-SELF-FENCED-NODE-LEDGER-PUBLISHER-RETRIES-FOREVER-ON-RESERVATION-
 * CONFLICT, in usermode.
 *
 * Rig shape (8/net/mesh/mpath, build 9594B08726D6732D2ED5E87, test21, ledger run
 * 8/net/mesh/mpath:path_peer_withdrawn:2026-10-22T19:58:42Z): the node's filesystem shut down,
 * its authority over the LUN closed (P290-AUTH-CLOSED, its PR key preempted), and its peers
 * went on naming it in their view.  For five minutes it wrote ledger pages the target
 * refused: 31,510 P-TAUTH-PUBLISH-FAIL rc=-52, each the activation of a page prepared to it,
 * on a peer's FROZEN answer (P-TAUTH-FROZEN-NOT-CONSUMED from=<peer>) or while serving a
 * request on a page its view names it the owner of.
 *
 * H-FLOOD-1: neither dlm_page_ensure_mine (which activates a page prepared to this node, or
 * asks the page's authority for it) nor mxfs_dlm_process_page_handoff (a FROZEN activates, a
 * FREEZE_REQ prepares a page away) asks whether this incarnation's authority has closed
 * (dlm_authority_lost), as the hand-off tick and the takeover pass already do.  So a node
 * whose authority closed goes on writing the pages its peers hand it, ask it for, and send it
 * requests on.
 *
 * Harness: four nodes, A the bootstrap (lowest slot), B, C, and D, which joins late.  C's
 * authority closes through its authority_lost_cb, the way the mount layer's
 * v5_authority_lost_cb answers once the authority object has closed.  The shared temp file
 * does not refuse C's writes as the target did, so every ledger write C attempts lands and is
 * counted (its store's `writes`); the defect is the attempt.  Resources are chosen by their
 * master under each view the test moves through (a scratch DLM context answers for a view
 * nobody holds yet), each on a page of its own.
 *   0  control, C's authority open: a page handed to C on the view change that adds it (A's
 *      hand-off tick, a FROZEN) and B's EX on a resource C masters make C write; the counter
 *      sees the writes the later checks assert are gone;
 *   then C's authority closes, every view still naming C:
 *   1  B's EX on a never-touched resource C masters reaches C as a LOCK_REQ, is not granted,
 *      and C writes nothing;
 *   2  D joins and becomes the owner of a page C is the authority of; B's EX on a resource of
 *      that page makes D ask C for it (FREEZE_REQ), and C writes nothing;
 *   3  D leaves again, handing C a page D took while it was in the view (a FROZEN), and C
 *      writes nothing.
 * Each of 1-3 also asserts its exposure: the message reached C after its authority closed.
 * A FAIL on the write count of 1, 2 or 3 reproduces the rig defect.
 */
#define NNODES 4
#include "dlm_mesh.h"

static volatile int c_auth_closed;

static int vauth_lost(void *data)
{
    struct vnode *me = data;

    return me == &nodes[2] && c_auth_closed;
}

/* the master of r under the view ids[0..n), asked of a context that holds no ledger */
static struct mxfs_dlm_ctx *scratch;

static mxfs_node_id_t master_under(const mxfs_node_id_t *ids, int n,
                                   const struct mxfs_resource_id *r)
{
    mxfs_dlm_update_active_nodes(scratch, ids, n);
    return mxfs_dlm_resource_master(scratch, r);
}

static uint32_t used_pages[8];
static int nused;

static int page_used(uint32_t p)
{
    int i;

    for (i = 0; i < nused; i++)
        if (used_pages[i] == p)
            return 1;
    return 0;
}

/* the first inode number from `from` up whose master under view v1 is m1 and under v2 is m2
 * (n2 == 0: v1 only), on a page no other chosen resource uses and nothing has decided on */
static struct mxfs_resource_id pick(const mxfs_node_id_t *v1, int n1, mxfs_node_id_t m1,
                                    const mxfs_node_id_t *v2, int n2, mxfs_node_id_t m2,
                                    uint64_t from)
{
    struct mxfs_resource_id r;
    struct mxfs_tauth_page_auth a;

    memset(&r, 0, sizeof(r));
    r.type = MXFS_LTYPE_INODE;
    for (r.ino = from; ; r.ino++) {
        if (page_used(tl_page(&r)))
            continue;
        if (master_under(v1, n1, &r) != m1)
            continue;
        if (n2 && master_under(v2, n2, &r) != m2)
            continue;
        if (mxfs_tauth_ledger_page_auth(&probe, tl_page(&r), true, &a) ||
            a.state != MXFS_TAUTH_PG_UNOWNED)
            continue;
        used_pages[nused++] = tl_page(&r);
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
        mxfs_pal_sleep_ms(20);
    }
}

static int ex_once(struct vnode *n, const struct mxfs_resource_id *r, int retries,
                   const char *what)
{
    uint8_t granted = 0;
    uint64_t t0 = mxfs_pal_time_ms();
    int rc = mxfs_dlm_lock_retries(n->dlm, r, MXFS_LOCK_EX, 0, &granted, retries);

    printf("  INFO %s: node %u EX ino=%llu page=%u rc=%d granted=%u wall=%llums\n", what,
           n->id, (unsigned long long)r->ino, tl_page(r), rc, granted,
           (unsigned long long)(mxfs_pal_time_ms() - t0));
    if (rc == 0)
        mxfs_dlm_unlock(n->dlm, r);
    return rc;
}

static uint64_t c_writes(void)
{
    return nodes[2].ledger.store.writes;
}

int main(void)
{
    struct mxfs_resource_id R1, R0, R2, R4;
    struct vnode *A, *B, *C, *D;
    mxfs_node_id_t vAB[2], vABC[3], vABCD[4];
    uint64_t w0, w;
    int rc, rx0;

    tl_mktemp("fenced_node_ledger_test");
    printf("=== fenced_node_ledger_test file=%s ===\n", tl_path);
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
    C->dlm->authority_lost_cb = vauth_lost;
    vAB[0] = A->id; vAB[1] = B->id;
    vABC[0] = A->id; vABC[1] = B->id; vABC[2] = C->id;
    vABCD[0] = A->id; vABCD[1] = B->id; vABCD[2] = C->id; vABCD[3] = 1000 + 3 * 7919;

    /* R1: A's under {A,B}, C's under {A,B,C}; R0: C's under {A,B,C}, D's under {A,B,C,D};
     * R2: C's under {A,B,C}; R4: D's under {A,B,C,D}, C's under {A,B,C} */
    R1 = pick(vAB, 2, A->id, vABC, 3, C->id, 100000);
    R0 = pick(vABC, 3, C->id, vABCD, 4, vABCD[3], 200000);
    R2 = pick(vABC, 3, C->id, NULL, 0, 0, 300000);
    R4 = pick(vABCD, 4, vABCD[3], vABC, 3, C->id, 400000);
    printf("  INFO pages: R1 ino=%llu p=%u  R0 ino=%llu p=%u  R2 ino=%llu p=%u  R4 ino=%llu p=%u\n",
           (unsigned long long)R1.ino, tl_page(&R1), (unsigned long long)R0.ino, tl_page(&R0),
           (unsigned long long)R2.ino, tl_page(&R2), (unsigned long long)R4.ino, tl_page(&R4));

    /* ── 0. control: C's authority open ── */
    membership(vAB, 2);
    mxfs_pal_sleep_ms(100);
    ex_once(A, &R1, 10, "0 A decides R1 under {A,B}");
    CHECK(wait_active(tl_page(&R1), A->id, 2000), "0 R1's page ACTIVE under A before C joins");
    w0 = c_writes();
    membership(vABC, 3);
    CHECK(wait_active(tl_page(&R1), C->id, 3000),
          "0 R1's page handed to C on the view change and activated there (control)");
    rc = ex_once(B, &R0, 10, "0 B on R0, mastered by C");
    CHECK(rc == 0 && wait_active(tl_page(&R0), C->id, 2000),
          "0 B's EX on R0 granted by C, its page ACTIVE under C (control)");
    w = c_writes();
    printf("  INFO C ledger writes with its authority open: %llu -> %llu\n",
           (unsigned long long)w0, (unsigned long long)w);
    CHECK(w > w0, "0 C wrote while its authority was open (the counter sees its writes)");
    settle(C);

    /* ── C's authority closes; every view still names C ── */
    c_auth_closed = 1;
    w0 = c_writes();
    printf("  INFO C's authority closed; C ledger writes %llu\n", (unsigned long long)w0);

    /* ── 1. a request C masters, on a page nobody has decided on ── */
    rx0 = C->lockreq_rx;
    rc = ex_once(B, &R2, 3, "1 B on R2, mastered by C");
    CHECK(C->lockreq_rx > rx0, "1 exposure: B's request reached C after its authority closed "
          "(%d LOCK_REQ)", C->lockreq_rx - rx0);
    CHECK(rc != 0, "1 B's EX on R2 not granted by a master whose authority closed (rc=%d)", rc);
    CHECK(c_writes() == w0, "1 C wrote nothing serving it (writes %llu -> %llu)",
          (unsigned long long)w0, (unsigned long long)c_writes());

    /* ── 2. D joins and owns R0's page, whose authority is C ── */
    D = node_up(3, vABCD[3], 5003, 4, 1);
    membership(vABCD, 4);
    mxfs_pal_sleep_ms(200);
    rx0 = C->handoff_rx[MXFS_HANDOFF_FREEZE_REQ];
    rc = ex_once(B, &R0, 3, "2 B on R0, now mastered by D");
    CHECK(C->handoff_rx[MXFS_HANDOFF_FREEZE_REQ] > rx0,
          "2 exposure: D asked C for R0's page after C's authority closed (%d FREEZE_REQ)",
          C->handoff_rx[MXFS_HANDOFF_FREEZE_REQ] - rx0);
    CHECK(c_writes() == w0, "2 C prepared nothing away (writes %llu -> %llu)",
          (unsigned long long)w0, (unsigned long long)c_writes());

    /* ── 3. D takes R4's page, then leaves: its hand-off goes to C ── */
    rc = ex_once(A, &R4, 10, "3 A on R4, mastered by D");
    CHECK(rc == 0 && wait_active(tl_page(&R4), D->id, 2000), "3 R4's page ACTIVE under D");
    rx0 = C->handoff_rx[MXFS_HANDOFF_FROZEN];
    membership(vABC, 3);
    {
        uint64_t t0 = mxfs_pal_time_ms();

        while (C->handoff_rx[MXFS_HANDOFF_FROZEN] == rx0 && mxfs_pal_time_ms() - t0 < 3000)
            mxfs_pal_sleep_ms(20);
        mxfs_pal_sleep_ms(300);     /* the activation the FROZEN would start */
    }
    CHECK(C->handoff_rx[MXFS_HANDOFF_FROZEN] > rx0,
          "3 exposure: D handed C R4's page after C's authority closed (%d FROZEN)",
          C->handoff_rx[MXFS_HANDOFF_FROZEN] - rx0);
    CHECK(c_writes() == w0, "3 C activated nothing (writes %llu -> %llu)",
          (unsigned long long)w0, (unsigned long long)c_writes());

    mxfs_dlm_release_all(A->dlm);
    mxfs_dlm_release_all(B->dlm);
    mxfs_dlm_release_all(D->dlm);
    node_down(D);
    node_down(C);
    node_down(B);
    node_down(A);
    mxfs_dlm_destroy(scratch);
    mxfs_tauth_ledger_close(&probe);
    mxfs_pal_bdev_close(dev);
    unlink(tl_path);
    printf("=== fenced_node_ledger_test RESULT %s fails=%d ===\n", tl_fails ? "FAIL" : "PASS",
           tl_fails);
    return tl_fails ? 1 : 0;
}
