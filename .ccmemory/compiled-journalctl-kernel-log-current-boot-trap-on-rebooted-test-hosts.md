---
name: compiled-journalctl-kernel-log-current-boot-trap-on-rebooted-test-hosts
description: journalctl -k/--dmesg implies -b and drops earlier boots on fenced/power-cut pve9 hosts; use _TRANSPORT=kernel --since and verify the run mark.
metadata:
  type: feedback
tags: [compiled, trap, evidence, pve9, journal]
---

Group kind: assorted (a single note the clusterer could not fit to a topic). Topic: reading kernel logs across reboots on the pve9 test rig. Source: `trap-journalctl-k-implies-current-boot-only-on-rebooted-test-hosts`.

## The trap
`journalctl -k` (and `--dmesg`) implies `-b` — the CURRENT boot only, even with `--since`. On the pve9 rig the fault rows fence pve9-7 (it reboots) and the HA test power-cuts a host, so a "kernel log since the run mark" read with `-k` silently lost the boot that ran most of the workload. Plain `dmesg` loses it too (ring is per boot). `trap-journalctl-k-implies-current-boot-only-on-rebooted-test-hosts`

## Seen
- A full-pass sweep reported 0 modify-path P36 warnings on pve9-7 from a 0-line dmesg; the previous boot's journal held 109 (all from older builds, as it turned out — but the zero was vacuous).
- Next pass, `-k --since T0` again missed pve9-5/pve9-7's earlier boots; the run mark was absent from those files, which is what exposed it.

## How to apply
- Read kernel lines across boots with `journalctl _TRANSPORT=kernel --no-pager -o short-iso --since '<T0>'` (does not imply -b; persistent journal is on, /var/log/journal exists on pve9 hosts, TZ UTC).
- Always count the run mark in the captured file; mark=0 means the capture does not cover the run, so every zero in it is void.
- Count `Linux version` lines to see how many boots the window crossed.
- Grep a probe by its full tag (`P88-CLOBBER`, not `P88`): `P88-PUBOB-*` is an unrelated family sharing the prefix.
