---
name: compiled-ssh-timeout-bounds-client-not-remote-workload
description: Rig/lab traps (ssh timeout, lab VMs only, Ubuntu 26.04, DRBD departure/unmount/takeover/ABBA, PVE deploy) + ccloop: never ask the owner
metadata:
  type: feedback
tags: [compiled, harness, ssh, timeout, rig, teardown, drbd, trap, mkosimage, lab-vms, ubuntu2604, iscsi, acpi, uutils, dd, containers, ledger, departure, takeover, unmount, pve, ccloop, owner, askuserquestion, unattended]
---

DRBD rig, harness and lab test-node traps, plus one ccloop behavior rule (assorted: the last section shares no topic with the rest). Part one: harness or lab-setup faults, not MXFS defects. The anchor trap, originally an assorted tail group of one note with no sibling topic: a local `timeout N ssh <node> "<cmd>"` bound stops the ssh client, not the node's workload. How it wedged a DRBD rig arm, and how to bound and tear down instead. [[trap-a-local-timeout-around-ssh-leaves-the-remote-workload-running]] Also absorbs `compiled-lab-vm-platform-node-traps`: lab VM / platform test-node rules and traps, i.e. what a test node may be and what mkosimage-built Ubuntu 26.04 nodes get wrong before MXFS is involved. Part two, absorbed from `compiled-drbd-departure-ledger-handoff-costs-and-unmount-takeover-harness-traps`: what a departing/dying MXFS node costs on a DRBD pair (ledger page handoff and takeover), how to time and measure it, and the harness shapes that silently measure nothing. Part three, absorbed from `compiled-ccloop-run-never-ask-owner-questions`: in an unattended ccloop run never ask the owner anything. Eight traps plus that rule, grouped by theme.

## A local `timeout N ssh` bounds the client, not the remote workload

### Trap

A harness that bounds a node workload as `timeout N ssh <node> "<loop>"` stops only the local ssh client at the bound. That covers every `ssh_n` / `on <node> <cmd> <bound>` helper in `scripts/drbd_rig.sh`, `tests/fourkn_merge_2node.sh` and most laps. The remote command has no pty, so it gets no SIGHUP; a bash loop that writes nothing until it ends keeps running on the node, its result line lost. [[trap-a-local-timeout-around-ssh-leaves-the-remote-workload-running]]

### What it did

0.90.134, `scripts/drbd_rig.sh fourkn-test`, evidence `tests/evidence/drbd_rig/20261022T140512Z-fourkn-test`. [[trap-a-local-timeout-around-ssh-leaves-the-remote-workload-running]]

- The 512 arm's merge workers overran their 19 s bound; they needed ~95 s on DRBD.
- The harness went on to unmount: `umount: target is busy` on both nodes.
- Its teardown ran `fuser -km` and found nothing. Between steps the worker bash holds no file open on the mount; a moment later its next `chmod` does.
- `drbdadm down` then could not take the minor down.
- The 4096 arm's `drbdmeta create-md` refused (`Device '20' is configured!`), and the arm under test never ran.
- The workers finished on their own 90 s later.

### Apply

[[trap-a-local-timeout-around-ssh-leaves-the-remote-workload-running]]

- Bound the workload ON THE NODE: `echo $$ > /root/<x>.pid; exec timeout --foreground <bound> <worker>`, with the local ssh bound = node bound + the release policy's `stall_limit_s` + ssh connect.
- `--foreground` signals only the worker shell, not the chmod/stat it waits on. A worker that traps TERM (`trap 'stop=1' TERM`, checked between steps) stops after the step in hand and can report exactly what it changed: `tests/fourkn_merge_worker.sh` prints `MODE <i> <mode>` per file and `WORKER_STOPPED`, so a pace failure still gets a correctness verdict.
- Teardown kills a leftover by that pidfile, only if `/proc/<pid>/comm` is still `timeout`, and waits for it; never `pkill`.
- Teardown success is read from state (mount gone, minor gone from `/proc/drbd`), never from a command's ignored exit; the next arm does not start on a node that failed it.
- When diagnosing, a `/proc/*/cmdline` scan for the worker's name also matches the diagnostic shell itself (its own command line contains the name): exclude `$$` or match the interpreter path, or the scan reports a live worker that has already exited.

## Lab VM / platform test-node rules and traps

Source: `compiled-lab-vm-platform-node-traps`. Lab VM / platform test-node rules and traps: what a test node may be, and what mkosimage-built Ubuntu 26.04 nodes get wrong before MXFS is involved. Check these before reading a failure on such a node as an MXFS defect.

### Rule: test nodes are mkosimage lab VMs, never containers or downloaded images

Source: [[feedback-no-containers-for-testing-lab-vms-only]]

The owner, 2026-10-15: "I would never ever have authorized using a container, ever. The only authorized method of verification and testing is using a virtual machine built with mkosimage - NEVER downloaded." Also: "we dont use containers for testing here - we use lab vms and lab vms are used by the vm pool."

What happened: `scripts/debian_kbuild_check.sh` and `scripts/rhel_kbuild_check.sh` (the `build_check` of each platform in `data/platforms.json`, run by `scripts/release.sh` before packaging) started named `docker run -d ... sleep infinity` containers (mxfs-kbuild-debian-11/12/13, -rockylinux-9, -almalinux-9) and kept them. Five sat running for days holding ~3.7 GB. No session ever had authorization; an earlier session invented it. The owner had them all deleted.

Why: a container or a downloaded image is not the platform a user runs; verification on it proves nothing about the product and consumes disk and memory nobody tracks.

How to apply:
- Any test, build check, probe or verification runs on a lab VM built on this host with `mkosimage` (lab/README.md, lab/vms.md), powered through `tools/vm_pool.sh`.
- Never `docker run`/`podman` for testing or checking, never a downloaded cloud image, prebuilt qcow2 or container image as a test node.
- Before adding any new infrastructure method, ask. "An earlier session did it" is not authorization.

### Trap: mkosimage Ubuntu 26.04 nodes share an iSCSI initiator name and the domain has no ACPI

Source: [[trap-mkosimage-nodes-share-iscsi-initiator-name-and-lack-acpi]]

Found building the ubuntu2604 set (0.90.130). Both handled by `scripts/platform_node_setup.sh`; run it on every new mkosimage node.

1. Shared iSCSI initiator name. The Ubuntu 26.04.1 live-server image carries open-iscsi with /etc/iscsi/initiatorname.iscsi already written (dated 2026-08-26, the image build), so every node installed from it has `iqn.2004-10.com.ubuntu:01:35ed4c1b7a`.
   - Symptoms: a storm of `connection1:0: detected conn error (1020)` + `sd ...: Power-on or device reset occurred` on both nodes (each login drops the other's session); the mount fails `permission denied` with `scsipr: P304-RESV-CONFLICT 'mxfs' RESERVE(WE-AR) was REFUSED ... held=0`; the pool LUN's SCST `alloc` group lists ONE initiator for two nodes. A lab-setup fault, not an MXFS defect.
   - Check: `sed -n s/^InitiatorName=//p /etc/iscsi/initiatorname.iscsi` on each node.
   - Fix: a name older than /etc/machine-id came from the image -> `iscsi-iname`, restart iscsid, then free and re-bind the pool LUN (`tools/lun_pool.sh free <id>`, `scripts/platform_lab.sh <platform>`).
   - Other sets built from images that preinstall open-iscsi could share a name too; check before reading a PR refusal as a defect.
2. No ACPI in the domain. mkosimage's libvirt definition has no `<features>` (ubuntu2604, debian12), so `virsh shutdown` is ignored and every stop runs out its budget and destroys the guest.
   - Adding `<acpi/><apic/>` (platform_node_setup.sh add_acpi) renames the guest NIC, changes its DHCP client id, and dnsmasq hands it a NEW address (.178 -> .107): resolve the node's address on every ssh attempt, never once after a start (vm_reclaim_disk.sh and platform_node_setup.sh do now).
   - After adding ACPI, shutdowns were still not reliably clean (one clean, two timed out) -- not yet explained.
3. Size. osimager builds at 2 vCPU / 2 GiB; Ubuntu sets run 4/4 like ubuntu2404 (a smaller Ubuntu guest OOM'd in the DKMS build).

### Trap: Ubuntu 26.04's dd is uutils; `iflag=direct` always fails

Source: [[trap-ubuntu-2604-dd-is-uutils-and-iflag-direct-always-fails]]

Ubuntu 25.10+ ships the Rust coreutils (uutils) as the default `dd`, `cp`, etc. On Ubuntu 26.04.1 it is `dd (uutils coreutils) 0.10.0`; GNU's is still installed as `gnudd` (package gnu-coreutils).

What bit: the 0.90.130 ubuntu2604 packaged round failed "O_DIRECT read with stable writes" on both configurations: `dd iflag=direct bs=1M` returned "IO error: Input/output error" in 0.02 s for 64 MiB with nothing in the kernel log. It looked like an MXFS bounce-read defect on Ubuntu's 7.0 kernel (Proxmox 7.0.14 compiles the same bounce path and passed).

Disproved: a page-aligned Python O_DIRECT reader read the exact bytes in both stable_writes modes (tests/dio_bounce_eio_probe.sh, evidence tests/evidence/dio_bounce_eio_probe/20261015T165138), and uutils `dd iflag=direct` failed 6/6 on a plain ext4 file with MXFS not involved ("IO error: Invalid input").

How to apply:
- Never read a `dd iflag=direct`/`oflag=direct` failure on Ubuntu 26.04+ as a filesystem result. Check `dd --version` first.
- Platform-node harnesses do O_DIRECT with a page-aligned reader (python3 mmap buffer + os.readv), as tests/dio_stable_writes_read.sh now does; or `gnudd` where present.
- Many rig/PVE harnesses still use `dd ... direct` (grep `iflag=direct|oflag=direct`); fine on GNU coreutils nodes but would grade dd on a uutils node.
- The error text differs between runs ("Invalid input", "Input/output error"); the same dd sometimes succeeds for one block, so a single passing dd proves nothing.

## DRBD: cost lives in pair-wide swap-lock acquisitions

From `compiled-drbd-departure-ledger-handoff-costs-and-unmount-takeover-harness-traps` (part two: what a departing node costs on a DRBD pair, and the harness shapes that measure nothing).

- Every ledger page commit on either host takes the one pair-wide swap lock (`pal/linux/drbd.c` `mxfs_drbd_lock`). A departure costs two commits per page: the departing host's PREPARE and the survivor's ACTIVATE.
- Survivor activations on an 8-thread pool (`tauth_async_activation`, 0.90.109 change D) took lock share from the departing host: 20.6 ms/page (70.8 s / 3391 pages) vs 13.6 ms/page inline (47.0 s / 3465 pages); departing host's swap wait/batch 27-45 ms vs 12-20 ms. Removed in 0.90.110. The pool also had one unexplained dlm_ledger_test case-15 failure (request parked REMASTER on a page whose activation was queued). Lesson: speeding one side's commits with concurrency slows the other side; judge any commit-path change by pair-wide swap statistics (P-DRBD-CAS-STATS) on BOTH hosts. [[trap-activating-handed-ledger-pages-on-a-pool-slows-a-drbd-departure-because-both-hosts-share-one-swap-lock]]
- Inline activation is not complete either: a departing host that closes its connection loses queued FROZENs (844 of 3465 activated); the survivor's GOODBYE takeover consumes those PREPARED-to-self pages. (same note)
- Routing prepares/activations through `tauth_group_commit` (ticket protocol: ticket-swap wave, body scatter, publish-swap wave = TWO lock acquisitions per batch) batched ~7 pages (gc_batches=139, gc_pages=973) but cost 20.8-21.9 ms/page vs 12.7-16.7 ms/page for one span swap each (`lpage_write_fresh_locked`: compare sector 0, write the 4 KiB page, one acquisition). Reverted. Per acquisition: enter ~3.4 ms, peer wait ~14 ms, critical section 14-21 ms, release ~5 ms. On DRBD the cost is acquisitions (they involve the peer), not barrier count; batching that doubles acquisitions loses. The swap server saw swaps=512 batches=512 with 8 worker threads, so callers were not reaching the swap together; look upstream first (P-TAUTH-DEPART worker_ms drain/prepare/send, peak_inflight). [[trap-routing-ledger-authority-transitions-through-the-group-commit-is-slower-on-drbd-than-one-span-swap-each]]

## Timing an unmount

From `compiled-drbd-departure-ledger-handoff-costs-and-unmount-takeover-harness-traps`.

- An MXFS mount leaves `/proc/mounts` as soon as umount(2) detaches it; put_super (grant release, ledger handoff, GOODBYE) runs afterward in the umount task's final mntput. Polling /proc/mounts reported done at 0.7-0.8 s; the DLM actually shut down 31 s and 61 s later. The harness also switched dyndbg probes off at that mark, so P-TAUTH-DEPART never printed and "no line" read as "nothing to hand off". Time to the `umount` process exit or the mxfs-drbd@ unit leaving active/deactivating (`systemctl is-active`: inactive = clean, failed = overran). Cross-check kernel marks: `DLM shutting down` -> `P-RELALL-WALL` -> `P-TAUTH-DEPART ... ms=` -> `DLM shutdown complete`. Keep probes on until the unit stops. dyndbg `format "%s%pV"` enables only mxfs_pal_log sites; a plain pr_debug probe like P-DRBD-CAS-STATS needs its own `format` line. [[trap-a-mount-leaves-proc-mounts-before-its-teardown-ends-so-time-an-unmount-to-the-umount-or-unit-exit]]

## Takeover vs teardown races, and repros that miss them

From `compiled-drbd-departure-ledger-handoff-costs-and-unmount-takeover-harness-traps`.

- A virsh-destroy repro (D-0953) puts the ledger takeover inside the peer's recovery (`P-TAUTH-TAKEOVER-RUN why=recovery-complete`); put_super waits for recovery before `DLM shutting down`, so an unmount 139 s into a 7999-page pass returned after 105 s with the pass complete and `P-TAUTH-TAKEOVER-INTERRUPTED` never printed. It looked clean and proved nothing. The passes that race the unmount are the departure WORKER's: `v5_settled_incarnation` (last-member's lone remount settling its predecessor, the "sole survivor's ghost"; ~13 s per 1000 pages), goodbye/clean-release of a peer, and the orphan sweep queued after every departure and bootstrap mount (crash stack `v5_depart_run -> v5_handoff_takeover`). Deterministic repro: `tests/depart_takeover_unmount.sh DEATH=ghost`. Findings: a joiner mounting during the bootstrap orphan sweep exhausts root-inode retries on remaster and self-shuts down (D-0960; `MXFS_JOIN_WAIT_PATTERN` in module_swap_deploy.sh holds joiners until the sweep line); every departure queues a sweep, so the first full sweep is followed ~2 s later by an empty one, and `tail -1` of the sweep lines scores leftover pages as never taken. [[trap-a-peer-death-takeover-runs-inside-recovery-and-put-super-waits-for-it-so-it-cannot-reach-the-worker-teardown]]
- The ghost arm originally had B leave, then A create alone. A lone mount takes no grant and writes no ledger record, so the predecessor held only 10 pages (cand=10) and the harness aborted ("pass not seen in flight"); earlier ~15k-page laps got their magnitude from aged-ledger residue. Fix: create under two members (~14 ms per create, 8000 creates 102 s), B unmounts (hands pages to A, via=frozen-msg), A unmounts last and remounts. Sweep ran ~30 ms/page (9332 pages), so budget NFILES/20+120 s, not NFILES/40+120 s. Lesson: derive pass length from what the workload RECORDS, not creates; a plateau of activations at a small number before the first sample is the tell; read `cand=` in the P-TAUTH-TAKEOVER summary. Sibling: `trap-a-defect-whose-magnitude-is-workload-residue-stops-reproducing-and-the-lap-reads-as-a-pass`. [[trap-a-harness-that-builds-its-authority-after-the-peer-leaves-gives-the-takeover-pass-nothing-because-a-lone-mount-records-no-grant]]
- A recovery completion landing after the watch window reads as "never completes" (D-0962): tcp_death_replay.sh laps FAILed `P163-RECOVERY-COMPLETE published` / `gate restored` / `WE-AR in force` on a 60 s wait and a 96 s capture, but the survivor's live dmesg showed completion at +104.5 s (`P-COMPLETE-TIMING handoff_ms=103767`, 31979 takeover lines, 7984 pages). Passing laps had handoff_ms 107376 and 43373 and logged the same late TCP-death event. Rules: read `P-COMPLETE-TIMING` and count takeover quartets before writing "never completes" (a late completion is a PACE defect with a number); a probe present in the failing lap is a cause only if ABSENT from passing laps; page count on a preserved filesystem is residue of earlier laps, the ~13 ms/page synchronous ledger I/O is the defect and the count the multiplier; pull the survivor's log to an evidence file before the next lap (ring rolls in ~2 laps, ~32k P-TAUTH lines per completion, victim's dmesg dies with it). [[trap-a-recovery-completion-that-lands-after-the-watch-window-reads-as-never-completes]]

## Superblock freeze from a worker vs unmount (ABBA)

From `compiled-drbd-departure-ledger-handoff-costs-and-unmount-takeover-harness-traps`.

- `freeze_super` in the join worker takes `s_umount`; umount holds `s_umount` through teardown and put_super joins the worker (`v5_join_worker_stop`). Seen 0.90.14 on 4/tcp. Window is milliseconds, so random-delay tests never hit it (20 laps, 0 hits); `dbg_join_prefreeze_delay_ms` widens it (5 of 20). Not fixes: SB_ACTIVE/SB_DYING check before the freeze (check-to-lock gap); `freeze_super` alone; trylock then `freeze_super` alone; on <=6.6 freeze_super takes its own `s_active` ref and thaw drops it, so thaw can run teardown on the worker (self-join). Fix (xfs/xfs_mxfs_join.c 0.90.16, kernel bdev-freeze pattern): `down_write_trylock(&sb->s_umount)`; under it check SB_BORN, SB_ACTIVE, `s_root`, `s_active > 0`, not shut down; `atomic_inc(&sb->s_active)`; `up_write`; then `freeze_super`. Drop the ref LAST from a per-request work item on a module-owned workqueue (never on the worker; never embed the work in the mount; never flush a system-wide workqueue). Cost: an umount mid-transition returns before teardown, which follows shortly. Verify with `tests/join_during_unmount.sh`: hold knob, umount at random point in hold, require `P-JOIN-FREEZE-BUSY` hits >= 1 (else VACUOUS), budgets on umount/mount walls, hung tasks = 0, module use count equal before/after (a leaked `s_active` shows only there). [[trap-a-worker-that-freezes-the-superblock-must-never-wait-for-s-umount-when-the-unmount-joins-that-worker]]

## Deploying a test build to the PVE pairs

From `compiled-drbd-departure-ledger-handoff-costs-and-unmount-takeover-harness-traps`.

- Neither Proxmox pair (physical pve1 192.168.1.80 / pve2 192.168.1.81; nested pve9-1 192.168.120.192 / pve9-2 192.168.120.137) mounts clyde's /src, so `scripts/pve_dkms_rebuild.sh` fails RC=127 (measured 0.90.109). Use `PVE_PAIR="<addr> <addr>" FROM_TREE=1 scripts/pve_pair_update.sh`: packs the tree (~9 s), copies to /root/mxfs-tree on each host, `make install OVERWRITE=1` (~7 min physical), stops both units, swaps module, starts both. /root/mxfs clone untouched. Confirm `/sys/module/mxfs/srcversion` on each host; an edit after the "packed the working tree" line is not in the build. It stops BOTH hosts together, so it is not a single-departure measurement. [[trap-the-physical-pve-pair-has-no-nfs-src-so-deploy-a-test-build-with-pve-pair-update-from-tree]]

## ccloop run: never ask the owner questions

Absorbed from `compiled-ccloop-run-never-ask-owner-questions` (assorted tail group: a single note the clusterer could not fit to a sibling topic): how an unattended ccloop run treats the owner, who is AFK, and what to do with a decision only the owner can make.

### The correction

- Owner, 2026-10-23, after an AskUserQuestion dialog about two DRBD release decisions (an exception, and pace grading) appeared on the screen mid-run: "OMG WTF IS THIS????? I AM FUCKING AFK ... DO NOT ASK ME ANY STUPID FUCKING QUESTIONS". `never-ask-the-owner-questions-in-a-ccloop-run`
- Context: the owner had sent short remarks into the running turn ("at this rate you'll never do another release", "did you even check ccusage?"). Those are comments typed in passing, not an open channel. The owner is still AFK, and a dialog left on the screen stalls the loop. `never-ask-the-owner-questions-in-a-ccloop-run`

### What to do

- In a ccloop run, never call AskUserQuestion and never end a reply with a question to the owner. `never-ask-the-owner-questions-in-a-ccloop-run`
- A decision only the owner can make (a policy exception, a gate rule) goes into the record's next step as a blocker, naming exactly what is missing. Work then continues on everything else. `never-ask-the-owner-questions-in-a-ccloop-run`
- When the owner remarks mid-turn, answer in plain text and keep working. `never-ask-the-owner-questions-in-a-ccloop-run`
