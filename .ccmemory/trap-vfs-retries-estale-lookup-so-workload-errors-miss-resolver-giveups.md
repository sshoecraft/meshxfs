---
name: trap-vfs-retries-estale-lookup-so-workload-errors-miss-resolver-giveups
description: The VFS retries an ESTALE lookup once, so a workload's error count misses xfs_lookup give-ups; grade lookup fixes on module counters, not ops
metadata:
  type: feedback
---

Linux retries a path walk that returned -ESTALE (LOOKUP_REVAL), so a single xfs_lookup give-up is invisible to userspace. Measured 2026-10-24 (session 8815bf68, 4/disk/caw/mpath path_mount_degraded, typeflip_relookup_shell_dead=0): 5 shell-dead give-ups on test7, every pathload op ok (err=0).

Also: P201-RELOOKUP is mxfs_probe_ratelimited, so pairing give-up lines with relookup lines fails past ~10 per burst.

How to apply: a lap grading a lookup/resolver fix must read a module counter of the outcome (atomic_t + module_param_cb with mxfs_dbg_atomic_param_ops, write resets), not the workload's error count or ratelimited probe lines.
