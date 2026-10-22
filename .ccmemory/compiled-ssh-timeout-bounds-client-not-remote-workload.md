---
name: compiled-ssh-timeout-bounds-client-not-remote-workload
description: Local timeout around ssh leaves remote work running; test nodes are mkosimage VMs only; Ubuntu 26.04 traps: shared iSCSI name, no ACPI, uutils dd
metadata:
  type: feedback
tags: [compiled, harness, ssh, timeout, rig, teardown, drbd, trap, mkosimage, lab-vms, ubuntu2604, iscsi, acpi, uutils, dd, containers]
---

Rig harness and lab test-node traps (harness or lab-setup faults, not MXFS defects). The anchor trap, originally an assorted tail group of one note with no sibling topic: a local `timeout N ssh <node> "<cmd>"` bound stops the ssh client, not the node's workload. How it wedged a DRBD rig arm, and how to bound and tear down instead. `trap-a-local-timeout-around-ssh-leaves-the-remote-workload-running` Also absorbs `compiled-lab-vm-platform-node-traps`: lab VM / platform test-node rules and traps, i.e. what a test node may be and what mkosimage-built Ubuntu 26.04 nodes get wrong before MXFS is involved.

## A local `timeout N ssh` bounds the client, not the remote workload

### Trap

A harness that bounds a node workload as `timeout N ssh <node> "<loop>"` stops only the local ssh client at the bound. That covers every `ssh_n` / `on <node> <cmd> <bound>` helper in `scripts/drbd_rig.sh`, `tests/fourkn_merge_2node.sh` and most laps. The remote command has no pty, so it gets no SIGHUP; a bash loop that writes nothing until it ends keeps running on the node, its result line lost. `trap-a-local-timeout-around-ssh-leaves-the-remote-workload-running`

### What it did

0.90.134, `scripts/drbd_rig.sh fourkn-test`, evidence `tests/evidence/drbd_rig/20261022T140512Z-fourkn-test`. `trap-a-local-timeout-around-ssh-leaves-the-remote-workload-running`

- The 512 arm's merge workers overran their 19 s bound; they needed ~95 s on DRBD.
- The harness went on to unmount: `umount: target is busy` on both nodes.
- Its teardown ran `fuser -km` and found nothing. Between steps the worker bash holds no file open on the mount; a moment later its next `chmod` does.
- `drbdadm down` then could not take the minor down.
- The 4096 arm's `drbdmeta create-md` refused (`Device '20' is configured!`), and the arm under test never ran.
- The workers finished on their own 90 s later.

### Apply

`trap-a-local-timeout-around-ssh-leaves-the-remote-workload-running`

- Bound the workload ON THE NODE: `echo $$ > /root/<x>.pid; exec timeout --foreground <bound> <worker>`, with the local ssh bound = node bound + the release policy's `stall_limit_s` + ssh connect.
- `--foreground` signals only the worker shell, not the chmod/stat it waits on. A worker that traps TERM (`trap 'stop=1' TERM`, checked between steps) stops after the step in hand and can report exactly what it changed: `tests/fourkn_merge_worker.sh` prints `MODE <i> <mode>` per file and `WORKER_STOPPED`, so a pace failure still gets a correctness verdict.
- Teardown kills a leftover by that pidfile, only if `/proc/<pid>/comm` is still `timeout`, and waits for it; never `pkill`.
- Teardown success is read from state (mount gone, minor gone from `/proc/drbd`), never from a command's ignored exit; the next arm does not start on a node that failed it.
- When diagnosing, a `/proc/*/cmdline` scan for the worker's name also matches the diagnostic shell itself (its own command line contains the name): exclude `$$` or match the interpreter path, or the scan reports a live worker that has already exited.

## Lab VM / platform test-node rules and traps

Source: `compiled-lab-vm-platform-node-traps`. Lab VM / platform test-node rules and traps: what a test node may be, and what mkosimage-built Ubuntu 26.04 nodes get wrong before MXFS is involved. Check these before reading a failure on such a node as an MXFS defect.

### Rule: test nodes are mkosimage lab VMs, never containers or downloaded images

Source: `feedback-no-containers-for-testing-lab-vms-only`

The owner, 2026-10-15: "I would never ever have authorized using a container, ever. The only authorized method of verification and testing is using a virtual machine built with mkosimage - NEVER downloaded." Also: "we dont use containers for testing here - we use lab vms and lab vms are used by the vm pool."

What happened: `scripts/debian_kbuild_check.sh` and `scripts/rhel_kbuild_check.sh` (the `build_check` of each platform in `data/platforms.json`, run by `scripts/release.sh` before packaging) started named `docker run -d ... sleep infinity` containers (mxfs-kbuild-debian-11/12/13, -rockylinux-9, -almalinux-9) and kept them. Five sat running for days holding ~3.7 GB. No session ever had authorization; an earlier session invented it. The owner had them all deleted.

Why: a container or a downloaded image is not the platform a user runs; verification on it proves nothing about the product and consumes disk and memory nobody tracks.

How to apply:
- Any test, build check, probe or verification runs on a lab VM built on this host with `mkosimage` (lab/README.md, lab/vms.md), powered through `tools/vm_pool.sh`.
- Never `docker run`/`podman` for testing or checking, never a downloaded cloud image, prebuilt qcow2 or container image as a test node.
- Before adding any new infrastructure method, ask. "An earlier session did it" is not authorization.

### Trap: mkosimage Ubuntu 26.04 nodes share an iSCSI initiator name and the domain has no ACPI

Source: `trap-mkosimage-nodes-share-iscsi-initiator-name-and-lack-acpi`

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

Source: `trap-ubuntu-2604-dd-is-uutils-and-iflag-direct-always-fails`

Ubuntu 25.10+ ships the Rust coreutils (uutils) as the default `dd`, `cp`, etc. On Ubuntu 26.04.1 it is `dd (uutils coreutils) 0.10.0`; GNU's is still installed as `gnudd` (package gnu-coreutils).

What bit: the 0.90.130 ubuntu2604 packaged round failed "O_DIRECT read with stable writes" on both configurations: `dd iflag=direct bs=1M` returned "IO error: Input/output error" in 0.02 s for 64 MiB with nothing in the kernel log. It looked like an MXFS bounce-read defect on Ubuntu's 7.0 kernel (Proxmox 7.0.14 compiles the same bounce path and passed).

Disproved: a page-aligned Python O_DIRECT reader read the exact bytes in both stable_writes modes (tests/dio_bounce_eio_probe.sh, evidence tests/evidence/dio_bounce_eio_probe/20261015T165138), and uutils `dd iflag=direct` failed 6/6 on a plain ext4 file with MXFS not involved ("IO error: Invalid input").

How to apply:
- Never read a `dd iflag=direct`/`oflag=direct` failure on Ubuntu 26.04+ as a filesystem result. Check `dd --version` first.
- Platform-node harnesses do O_DIRECT with a page-aligned reader (python3 mmap buffer + os.readv), as tests/dio_stable_writes_read.sh now does; or `gnudd` where present.
- Many rig/PVE harnesses still use `dd ... direct` (grep `iflag=direct|oflag=direct`); fine on GNU coreutils nodes but would grade dd on a uutils node.
- The error text differs between runs ("Invalid input", "Input/output error"); the same dd sometimes succeeds for one block, so a single passing dd proves nothing.
