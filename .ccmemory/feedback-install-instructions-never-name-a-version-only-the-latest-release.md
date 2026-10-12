---
name: feedback-install-instructions-never-name-a-version-only-the-latest-release
description: USER: install steps in any README/guide/man page never name a version; always "the latest release from the Releases page".
metadata:
  type: feedback
---

USER 2026-10-12, on finding docs/drbd-setup.md telling testers `git clone --branch v0.90.107`: "LOL OMG NO ... It should just tell testers to download the latest release! Never ever a specific version ... look through all the readme files or the guides to make sure they don't tell you to use a specific version ... Just tell them to use the latest release from a releases page. Period."

- Any instruction that tells someone what to install says: the latest release, from https://github.com/sshoecraft/meshxfs/releases. Package names use `<version>` (`apt install ./mxfs_<version>_amd64.deb`), never a number.
- Never `git clone --branch v<N>`, `git checkout v<N>`, "Install 0.90.x", "Released in 0.90.x — check out its tag", or a download URL with a version in it.
- A pinned version goes stale the moment the next release ships: the DRBD guide sent new users to 0.90.107, two releases behind, missing 0.90.124's multi-resource DRBD recovery.
- The release package is the install path; `make install` from source is only the developer section ("Building from source"), which says it is not a release.
- Not covered by this rule: release-news / changelog text recording what a past release was validated on (history), and the README release section the release check requires to name the current version.
- When editing docs, sweep for pins: `--branch v[0-9]`, `checkout v[0-9]`, `Released in 0.`, `mxfs_0.` in README.md, docs/*.md, lab/*.md, packaging/*.md, tools/*.md, docs/man/.
