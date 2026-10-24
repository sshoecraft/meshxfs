---
name: technique-infra-proven-proposal-needs-node-kmsg-window-and-every-lock-holder-named
description: An infra-proven proposal for an INCOMPLETE lap passes review only with the nodes' dmesg for the window and every lock holder named, transitively
metadata:
  type: feedback
---

The release-reviewer rejects an infra-proven proposal whose "no MXFS signature" rests on a harness log being silent, or whose blocking lock's holder is unnamed (an MXFS unmount stalling under the lock cannot be ruled out). 2026-10-24 (session 8815bf68): the peer_window lap passed on the second try, the lh_master lap only on the third.

What got them approved:
- Each node's own dmesg ring for the window, pulled after the fact (`dmesg --time-format iso | awk '$1 >= "<start>" && $1 < "<end>"'`). Show the ring reaches back to boot, state the capture command, and show any repeated benign line (e.g. one 'reservation conflict' pair per module load) is the baseline at every load.
- Every holder named down the chain: the pool lock (`run.sh` preflight under `lun_pool.sh quiet`) → the power-up lock (`lab_power.sh up` of each lane) → for each holder, the host journal's libvirtd 'Domain id=N name=...' and systemd-machined 'terminated' lines, proving the VMs booted from off.
- Re-run every disposition-critical negative yourself (e.g. no other domain started in the window).

Lane logs give step windows; lab_power's own 'host power-up lock held' line exists only when the caller keeps its output.
