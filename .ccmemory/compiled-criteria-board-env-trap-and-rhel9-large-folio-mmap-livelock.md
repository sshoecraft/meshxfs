---
name: compiled-criteria-board-env-trap-and-rhel9-large-folio-mmap-livelock
description: Assorted traps: criteria.py without MXFS_CRIT edits the qemu board; RHEL 9 page-based iomap_page_mkwrite + large folios livelocks mmap writes.
metadata:
  type: feedback
tags: [compiled, criteria, board, MXFS_CRIT, vsphere, rhel9, large-folio, mmap, iomap, kcompat, srcversion, trap]
---

Assorted group (no single topic): two unrelated traps, both hit while bringing up the vSphere / RHEL 9 platform board. Organised as one section per trap.

## criteria.py without MXFS_CRIT edits the main rig's board

Source: `trap-criteria-py-update-without-mxfs-crit-edits-the-main-rig-board`

- `tools/criteria.py` reads/writes `data/criteria.json` unless `MXFS_CRIT` is set. A platform board edit without it lands on the qemu rig's board.
- What happened: `tools/criteria.py update <id> -b ... --why ...` for the vSphere board (`tests/evidence/vsphere/criteria.json`) was run without `MXFS_CRIT=...` and rewrote the QEMU rig's `data/criteria.json` fio_perf budget 120 -> 364.
- A definition update also stamps `entry["recorded"] = today` (criteria.py:717), so undoing it means restoring `budget_s`, `why` AND removing `recorded`.
- Restore: copy the fields from an untouched copy of the same definition and diff every key (only `per_config` may differ between boards).
- Rule of thumb: every criteria.py call for a non-rig board carries `MXFS_CRIT=$PWD/<board>.json` in the same command, exactly as run.sh invocations do.

## RHEL 9 has folio iomap names but page-based mkwrite: large folios livelock mmap writes

Source: `trap-rhel9-has-folio-iomap-names-but-page-based-mkwrite-so-large-folios-livelock-mmap-writes`

- RHEL 9.8 (5.14.0-687) declares the folio-era iomap API (`iomap_release_folio`, `iomap_dirty_folio`, `iomap_read_folio`, `folio_mkwrite_check_truncate`), so a header probe says "folio iomap". Its `iomap_page_mkwrite` is still the page-based one: objdump of the live function from `/proc/kcore` (resolve call targets via `/proc/kallsyms`) shows `unlock_page`, `wait_for_stable_page`, `set_page_dirty`, `block_commit_write`, `__block_write_begin_int`.
- Symptom: with large folios enabled (the `mapping_set_folio_min_order` compat shim did so for every kernel < 6.12), a write fault on any tail page gets -EFAULT -> `VM_FAULT_NOPAGE` forever. The task sits in state R with millions of minor faults. mmap_coherency reports `steps[mc barrier ready]` because its step label is only updated inside `ck`, not by the python mmap step that actually hangs (misleading label).
- Fix, 0.90.128: large folios only for LINUX_VERSION_CODE >= 5.18 (upstream XFS's own enablement point). RHEL's own XFS leaves them off.
- How it was found fast: sysrq-l for the spinning task's kernel stack; tracefs kretprobes (`r:x func ret=$retval`) on `xfs_filemap_fault` / `xfs_filemap_page_mkwrite` / `iomap_page_mkwrite` / `xfs_buffered_write_iomap_begin` for 1 s to see which returns what. bpftrace on RHEL 9 needs `dnf install bpftrace`, and its struct-page field reads (mapping/index of a head page) were unreliable there.
- Build identity: mxfs.ko srcversion did NOT change for this header-only edit (65E3CB299AEB99B9B62D9E2 before and after); prove build identity with object mtimes and sha256 of mxfs.ko on the node.
