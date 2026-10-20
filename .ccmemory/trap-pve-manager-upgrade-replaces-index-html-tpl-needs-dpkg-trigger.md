---
name: trap-pve-manager-upgrade-replaces-index-html-tpl-needs-dpkg-trigger
description: Anything pve-storage-mxfs injects into a file another package owns (index.html.tpl) is wiped by that package's upgrade; only a dpkg file trigger rest…
metadata:
  type: feedback
tags: [proxmox, packaging, dpkg, trigger, pve92]
---

pve-storage-mxfs adds MXFS to Datacenter -> Storage -> Add by inserting a script tag into /usr/share/pve-manager/index.html.tpl from postinst. That file belongs to pve-manager. Every pve-manager install or upgrade lays down a fresh copy, so the entry silently disappears after the user's next `apt full-upgrade` and nothing errors.

Measured 2026-10-20 on pve92-1 (built from the PVE 9.2 ISO, pve-manager 9.2.2): the 0.90.130 packages put the tag in; full-upgrade to pve-manager 9.2.21 removed it from the template and from the page pveproxy serves (tests/evidence/pve92_gui_tag s1/s2). A Proxmox forum tester hit exactly this.

Fix pattern: DEBIAN/triggers with `interest-noawait <path>` on the foreign file; dpkg then runs our postinst with `triggered` after any package installs that path, and the idempotent injection puts it back (packaging/mkdeb_pve.sh). Verified with `apt-get install --reinstall pve-manager`: 'Processing triggers for pve-storage-mxfs' ran and the tag stayed.

How to apply: any time MXFS packaging edits a file it does not own (another package's template, config, unit), add a file trigger, and test it by reinstalling the owning package, not just by a fresh install. Also: an ISO-fresh lab node is NOT what a user runs; update it to the current point release before claiming anything (the 9.2 ISO's storage APIVER was 14, the updated 9.2.21 is 16).
