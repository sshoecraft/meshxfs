---
name: reference-mkosimage-latest-is-scoped-to-an-os-major-version
description: mkosimage --latest DIST-VERSION (e.g. rhel-9) and targets <dist>-<major>-latest-<arch> pick the newest point release of one OS major.
metadata:
  type: reference
---

USER 2026-10-12: "mkosimage --latest rhel-9 <== now filters by os version for latest".

osimager (`mkosimage`) resolves "latest" per OS major version, not only per distribution:

- `mkosimage --latest rhel-9` lists `rhel-9-latest-x86_64 -> rhel-9.8-x86_64` (and aarch64).
- `mkosimage --latest debian-11` lists `debian-11-latest-x86_64 -> debian-11.11-x86_64`.
- Help: `--latest [DIST[-VERSION]]` — DIST limits to one distribution, DIST-VERSION to the newest of that version line.
- So a build target can name a major line: `<dist>-<major>-latest-<arch>` (e.g. `debian-11-latest-x86_64`, `rhel-9-latest-x86_64`).

Earlier (same day) `<dist>-latest-<arch>` resolved to the newest version of the whole distribution (debian-latest -> 13.x), which did not fit platforms on an older major (ubuntu2404, rhel9, debian11/12). The major-scoped form fits every row, so `lab/vms.md`'s spec column can name `<dist>-<major>-latest-<arch>` instead of a point release. The exact kernel a platform claims still comes from `data/platforms.json` and the row's after-build steps, not from the install media.
