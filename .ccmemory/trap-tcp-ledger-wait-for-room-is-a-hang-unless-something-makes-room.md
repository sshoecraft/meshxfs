---
name: trap-tcp-ledger-wait-for-room-is-a-hang-unless-something-makes-room
description: TCP ledger: a request that waits on a full page waits forever unless holders are asked to release; full pages are expected, not rare
metadata:
  type: feedback
---

A TCP-ledger page holds 31 records and hash v2 routes inodes in shards of 8 (MXFS_TAUTH_INO_SHARD), so four busy shards fill a page. At 20-40k live grants over ~10k pages a few full pages are statistically EXPECTED, not a corner case.

A record leaves a page only when its holder RELEASES the grant, and holders keep grants cached indefinitely. So any "wait for room" (dl_capacity_wait_local, the remote MXFS_ERR_LEDGER_FULL re-ask, cap park) is a hang unless something asks holders to give records up. 0.90.131 turned the EDQUOT shutdown into exactly that wait; on 2/net/mesh/mpath (run 20261020T142123Z-g2d) a truncating open waited without end on a page full of the survivor's OWN idle EX grants, and the join freeze for the rejoining peer hung behind it (freeze_super waits for the writer), failing the rejoin mount. The fix is dl_capacity_reclaim: on -EDQUOT, DEMAND-BAST the holders of the page's 8 oldest records (dlm_txn_commit -> dlm_capacity_reclaim).

How to read a full page: tools/tauth_page_auth.py <dev> --page <P> --entries on a node (the P-TAUTH-PAGE-FULL line names the page). Passing B0D2 laps did not show this: they never met a page that STAYED full during a join. Grade a capacity change on whether a page that stays full ever empties, not on lap pass counts.
