---
name: technique-delayed-work-uaf-ab-arm-delay-past-capture-read-serial-console
description: A/B of a delayed work left queued past a freed mount: arm the delay longer than the dmesg capture, then read the oops from the root-owned serial log…
metadata:
  type: feedback
tags: [ab-test, use-after-free, serial-console, rig, workqueue]
---

When the control arm of an A/B is expected to run a delayed work on freed memory (D-FAILED-MOUNT-LEAVES-DESTAGE-AND-ALLOCLIST-RETRY-WORK-QUEUED-PAST-FREE, tests/reap_inactive_mount_ab.sh MODE=failkick):

- With the injected delay (KICK_MS) at 3 s, the node oopsed and panicked before the harness's dmesg capture 6 s after the mount, so the lap ABORTed at stage=capture with no instrument line: the cause was not shown (lap rfka).
- Arm the delay LONGER than the capture (KICK_MS=20000, SETTLE_S=6): the control's dmesg then holds the instrument line (P-MOUNT-FREE-WORK-PENDING at 475.42) before the work fires, and the oops lands 20.3 s later (lap rfkb). Cause and consequence, both on record.
- The guest's own console keeps the oops: /var/log/libvirt/qemu/<node>-serial.log, mode 600 root. `sudo -n tail -c N` works on clyde (plain tail gets Permission denied). The guest console runs loglevel=3, so pr_warn instrument lines are NOT on it, but BUG/Oops/panic are.
- Power-cycle the node after such a control (scripts/lab_power.sh down/up); it panics with 'Rebooting in 25 seconds' and comes back on its own otherwise, mid-next-lap.
