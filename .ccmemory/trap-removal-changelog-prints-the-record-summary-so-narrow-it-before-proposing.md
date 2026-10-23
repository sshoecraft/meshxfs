---
name: trap-removal-changelog-prints-the-record-summary-so-narrow-it-before-proposing
description: remove --fixed prints the record's SUMMARY as the CHANGELOG heading (defects.py:1773); a summary claiming an unmeasured mechanism gets the removal re…
metadata:
  type: feedback
---

A `tools/defects.py remove --fixed` prints its CHANGELOG entry as the record's **summary** in bold plus `--why` (tools/defects.py:1773); the approved `--cause` is not printed. The release-reviewer therefore rejects a removal whose record summary claims anything the control and fix-on laps did not observe, even when `--cause` and `--argument` were trimmed to the measurement.

Seen 2026-10-23 (session 900576df's successor): the fsx `/tmp` log record was rejected twice (P20261023-564a5c, P20261023-0a53fb) until `defects.py update -m` replaced the summary with the measured claim; P20261023-44869d then passed with the same batches and nothing re-run. A drafting agent then found five of seven tooling records with over-claiming summaries; each needed the same narrowing.

How to apply:
- Before proposing any removal, read the record's summary next to the control's FAIL lines; if it names a mechanism, a consequence or a scope the laps did not show, `update -m` it to the measured claim first.
- If a failure the summary describes is not what the control reproduced (e.g. the jdt 31 s unmount that prints `ms=` and reaches no grader), open a separate record for it before narrowing, so nothing observed leaves the queue silently.
- The `--why` given at `remove` time is not reviewed but is published: keep it to the measured numbers.
- A removal also needs `--reproducer` set on the record (`update --reproducer`), or `remove` refuses.
