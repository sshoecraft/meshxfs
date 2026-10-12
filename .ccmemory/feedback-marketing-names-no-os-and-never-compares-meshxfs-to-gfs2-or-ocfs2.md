---
name: feedback-marketing-names-no-os-and-never-compares-meshxfs-to-gfs2-or-ocfs2
description: USER: public text (README, banners, descriptions, release notes) never ties MeshXFS to one OS and never compares it to GFS2/OCFS2.
metadata:
  type: feedback
---

Two rules for anything public-facing — README, release banners and notes, GitHub description and topics, package descriptions, man pages, prompts given to GPT to write any of these.

## 1. Never name an operating system as what MeshXFS is

USER 2026-10-12: "why do you keep wanting to put Linux in there? I know it's technically accurate right now, but that's not the future direction. It will support multiple OSs. That's the whole reason for the PAL layer."

- Say "a POSIX clustered filesystem built on XFS", not "for Linux" / "built on Linux XFS" / "multiple Linux nodes".
- The PAL layer (`pal/`, architectural invariant 4: no direct kernel API outside `pal/`) exists so MeshXFS is not tied to one OS; FreeBSD and macOS ports are the direction.
- Naming the platforms that have packages today (Proxmox VE 9, RHEL 9, Ubuntu 24.04, Debian 13) is fine: that is a fact about releases, not identity.
- The trap: feeding "for Linux" into the facts given to GPT makes its draft say it. Leave the OS out of the input.
- The GitHub topic `linux-kernel` stays; the user will add freebsd and mac topics when those ports are done.

## 2. Never compare MeshXFS to GFS2 or OCFS2

USER 2026-10-12: "Don't ever say this in any marketing. It's not comparable. It's not even partially comparable."

WHY (the user's reason): "both GFS2 and OCFS2 have negative connotations in the mind of every admin that's ever used them." Naming either one — even favourably, even as "unlike GFS2" — puts that baggage in the reader's head before MeshXFS is judged on its own.

- No "comparable to", "alternative to", "in the family of", "like GFS2/OCFS2", and no `gfs2-alternative` / `ocfs2-alternative` topics. All were removed from the README and GitHub on 2026-10-12.
- Do not hand GPT a "comparable systems: GFS2, OCFS2" fact when asking it to write public text.

## Also from the same day

- Proxmox VE is a supported platform with a storage plugin, not what MeshXFS was made for. USER: "It has support for Proxmox VE, but it wasn't made for it. It is a standard POSIX clustered file system."

Related: compiled-release-procedure-banner-table-and-ship-on-pass (how banners are written).
