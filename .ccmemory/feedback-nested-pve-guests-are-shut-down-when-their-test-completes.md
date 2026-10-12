---
name: feedback-nested-pve-guests-are-shut-down-when-their-test-completes
description: USER (2026-10-11): the nested Proxmox guests pve9-1..7 are shut down as soon as the test that needs them completes; never left running idle.
metadata:
  type: feedback
---

User directive, 2026-10-11, after clyde ran out of memory and disk: "they should be shut down after the test is complete" — about the nested Proxmox VE guests pve9-1 .. pve9-7 (libvirt domains on clyde).

Why: clyde has 94 GB RAM and the running guests were configured for 152 GB; 35 guests held 63 GB RAM + 15 GB swap, swap was 100% full. The five idle pve9-3..7 alone held 27 GB (8+8+8+4+4 configured), more than any other single group, while no test used them.

How to apply:
- Any harness or manual session that boots pve9-* shuts them down (virsh shutdown, bounded, destroy as fallback) when its test finishes, including on failure/exit (trap).
- Before leaving a session, check `virsh -c qemu:///system list` for running pve9-* that nothing is using and shut them down.
- tools/vm_reclaim.sh trims a guest's qcow2 image (fstrim inside, discard=unmap is on every domain) and leaves a domain it had to boot shut off again.
