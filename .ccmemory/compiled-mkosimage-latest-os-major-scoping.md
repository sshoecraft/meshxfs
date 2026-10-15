---
name: compiled-mkosimage-latest-os-major-scoping
description: osimager mkosimage resolves "latest" per OS major (rhel-9-latest-x86_64) so lab VM specs name a major line, not a point release.
metadata:
  type: project
tags: [compiled, osimager, mkosimage, lab]
---

Single-note group (kind: assorted) on osimager `mkosimage` "latest" resolution.

From `reference-mkosimage-latest-is-scoped-to-an-os-major-version`:

USER 2026-10-12: "mkosimage --latest rhel-9 <== now filters by os version for latest".

osimager (`mkosimage`) resolves "latest" per OS major version, not only per distribution:

- `mkosimage --latest rhel-9` lists `rhel-9-latest-x86_64 -> rhel-9.8-x86_64` (and aarch64).
- `mkosimage --latest debian-11` lists `debian-11-latest-x86_64 -> debian-11.11-x86_64`.
- Help: `--latest [DIST[-VERSION]]` — DIST limits to one distribution, DIST-VERSION to the newest of that version line.
- A build target can name a major line: `<dist>-<major>-latest-<arch>` (e.g. `debian-11-latest-x86_64`, `rhel-9-latest-x86_64`).

Earlier the same day `<dist>-latest-<arch>` resolved to the newest version of the whole distribution (debian-latest -> 13.x), which did not fit platforms on an older major (ubuntu2404, rhel9, debian11/12). The major-scoped form fits every row, so `lab/vms.md`'s spec column can name `<dist>-<major>-latest-<arch>` instead of a point release. The exact kernel a platform claims still comes from `data/platforms.json` and the row's after-build steps, not from the install media.
