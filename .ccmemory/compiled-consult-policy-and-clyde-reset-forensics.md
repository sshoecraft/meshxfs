---
name: compiled-consult-policy-and-clyde-reset-forensics
description: Assorted: CLAUDE.md consult-when-stuck rule supersedes the old never-consult memory; how to bracket and classify a silent clyde hard reset.
metadata:
  type: feedback
tags: [compiled, consult, clyde, reset, pstore, journald]
---

Assorted group (the clusterer could not fit these to one topic): a policy correction about consulting other models, and forensics for silent clyde resets. Both are "what a turn should have known".

## Consulting another model: allowed when stuck

`consult-policy-claude-md-2026-10-10-supersedes-never-consult`

- The compiled memory `compiled-model-consults-policy-and-handling-consult-output` states a binding "never consult another model" rule, sourced from a 0.90.71-era user correction.
- The project CLAUDE.md outranks memory and now carries `RULE: CONSULT ANOTHER MODEL WHEN STUCK (User directive, 2026-10-10.)`, which is newer than that note. Consulting is allowed (expected) when genuinely stuck. It is not a replacement for instrumenting and measuring first.
- The handling lessons in the compiled article still hold: a consult's output is a ranked list of hypotheses to instrument, never findings and never the work order; ask for hazards, not approval; verify every half of a requirement it names was built.
- Noticed in the 0.90.131 session while weighing a design consult for the TCP per-create ledger commit (D-TCP-LEDGER-SMALLFILE).

## clyde reset time is not the journal tail

`clyde-reset-time-is-not-the-journal-tail`

When clyde resets with no shutdown, `journalctl -b -1` ends tens of seconds BEFORE the machine actually died: journald's mmap'd tail was never flushed. On 2026-10-16 the journal ended 12:03:32 but rig evidence files (tests/evidence/board_*/row.log) had inode mtimes up to 12:04:10 and recorded an action at that time. The kernel was alive 38 s past the journal's end.

How to bracket a reset:
- Last journal line is a lower bound only. The newest file mtime under tests/evidence (or any file written by a live process) is a later lower bound. The first line of `journalctl -b 0` is the upper bound.
- `/src` is on clyde's root nvme filesystem (df shows /dev/nvme0n1p2), NOT NFS, despite older comments in tools/clyde_kmsg_guard.sh saying evidence goes "to /src (NFS, a different server)". A file timestamp surviving there proves only an ext4 commit, which lands before journald's lazy sync.

Discriminating a hardware/power reset from a kernel panic on clyde:
- pstore backend is `erst` and recorded the real panics (Jul-Sep 1 dirs in /var/lib/systemd/pstore).
- hardlockup_panic=0 and softlockup_panic=0, so a lockup HANGS rather than resets.
- A fatal MCE with warm reset would be reported by the next boot's mce banks.
- No ERST record + no mce at boot + ~2 min return = reset below the kernel.
- clyde has no BMC (no /dev/ipmi0), no netconsole, no kdump, no UPS tooling.
- Recurring silent resets were seen Sep 17 (x3), Sep 21, Oct 7, Oct 15, Oct 16 under unrelated workloads (idle, vLLM-only, rig-only).
- Per-boot grep counts for AER/EDAC/NVRM/NMI are boot-time init lines (identical every boot), not errors. Check EDAC ce_count/ue_count in sysfs instead.
