---
name: compiled-public-text-rules-no-version-pins-no-os-no-gfs2-comparison
description: User rules for public/install text: never pin a version, never tie MeshXFS to one OS, never compare to GFS2/OCFS2 (assorted group, 2026-10-12).
metadata:
  type: feedback
tags: [compiled, docs, readme, marketing, install]
---

Assorted group: user corrections from 2026-10-12 about what public-facing and install text (README, guides, man pages, banners, release notes, GitHub description/topics, package descriptions, prompts to GPT) may say.

## 1. Install instructions never name a version  `feedback-install-instructions-never-name-a-version-only-the-latest-release`

USER, on finding docs/drbd-setup.md telling testers `git clone --branch v0.90.107`: "LOL OMG NO ... It should just tell testers to download the latest release! Never ever a specific version ... look through all the readme files or the guides to make sure they don't tell you to use a specific version ... Just tell them to use the latest release from a releases page. Period."

- Any instruction that tells someone what to install says: the latest release, from https://github.com/sshoecraft/meshxfs/releases. Package names use `<version>` (`apt install ./mxfs_<version>_amd64.deb`), never a number.
- Never `git clone --branch v<N>`, `git checkout v<N>`, "Install 0.90.x", "Released in 0.90.x — check out its tag", or a download URL with a version in it.
- A pinned version goes stale at the next release: the DRBD guide sent new users to 0.90.107, two releases behind, missing 0.90.124's multi-resource DRBD recovery.
- The release package is the install path; `make install` from source is only the developer section ("Building from source"), which says it is not a release.
- Not covered: release-news / changelog text recording what a past release was validated on (history), and the README release section the release check requires to name the current version.
- Sweep for pins when editing docs: `--branch v[0-9]`, `checkout v[0-9]`, `Released in 0.`, `mxfs_0.` in README.md, docs/*.md, lab/*.md, packaging/*.md, tools/*.md, docs/man/.

## 2. Never name an operating system as what MeshXFS is  `feedback-marketing-names-no-os-and-never-compares-meshxfs-to-gfs2-or-ocfs2`

USER: "why do you keep wanting to put Linux in there? I know it's technically accurate right now, but that's not the future direction. It will support multiple OSs. That's the whole reason for the PAL layer."

- Say "a POSIX clustered filesystem built on XFS", not "for Linux" / "built on Linux XFS" / "multiple Linux nodes".
- The PAL layer (`pal/`, architectural invariant 4: no direct kernel API outside `pal/`) exists so MeshXFS is not tied to one OS; FreeBSD and macOS ports are the direction.
- Naming platforms that have packages today (Proxmox VE 9, RHEL 9, Ubuntu 24.04, Debian 13) is fine: a fact about releases, not identity.
- Trap: feeding "for Linux" into the facts given to GPT makes its draft say it. Leave the OS out of the input.
- The GitHub topic `linux-kernel` stays; the user will add freebsd and mac topics when those ports are done.
- Proxmox VE is a supported platform with a storage plugin, not what MeshXFS was made for. USER: "It has support for Proxmox VE, but it wasn't made for it. It is a standard POSIX clustered file system."

## 3. Never compare MeshXFS to GFS2 or OCFS2  `feedback-marketing-names-no-os-and-never-compares-meshxfs-to-gfs2-or-ocfs2`

USER: "Don't ever say this in any marketing. It's not comparable. It's not even partially comparable."

Reason (user): "both GFS2 and OCFS2 have negative connotations in the mind of every admin that's ever used them." Naming either, even favourably ("unlike GFS2"), puts that baggage in the reader's head before MeshXFS is judged on its own.

- No "comparable to", "alternative to", "in the family of", "like GFS2/OCFS2", and no `gfs2-alternative` / `ocfs2-alternative` topics. All removed from the README and GitHub on 2026-10-12.
- Do not hand GPT a "comparable systems: GFS2, OCFS2" fact when asking it to write public text.

Related: compiled-release-procedure-banner-table-and-ship-on-pass (how banners are written).
