# Test platforms: what to build

One row per platform in `data/platforms.json`, keyed the same way. Each row is
what it takes to stand up that platform's verification set: the
[osimager](https://pypi.org/project/osimager/) spec that builds a node, and
what to do to the node after the build. `README.md` has the procedure that
applies to every row; this file has only what differs between them.

Nothing here is about any one site: node names, addresses and storage are
yours, and go in your lab file (`README.md`, "Your lab file").

The kernel a set must run is the one `data/platforms.json` lists under
`kernels` for that platform — a release claims exact kernels, so a set on any
other kernel verifies nothing. It is not repeated here, so the two cannot
disagree.

The `nodes` column is the size of the verification set: two, a node and a
peer to fence (both built from the spec, on one LUN of their own). Every fault a
platform node has caught — a kernel API, the fence on that kernel, packaging —
shows at two; a release's node count is verified on the development rig.

| platform | osimager spec | nodes | after the build | role |
|---|---|---|---|---|
| `ubuntu2404` | `ubuntu-24.04-latest-x86_64` | 2 | boot the GA kernel `platforms.json` claims, not an HWE one | runtime |
| `pve9` | `proxmox-ve-9-latest-x86_64` | 2 | install each kernel `platforms.json` claims by its exact version (`proxmox-default-kernel` for the newest), so every claimed kernel is present; `proxmox-headers-<krel>` for each | runtime, one round per claimed kernel |
| `rhel9` | `alma-9-latest-x86_64` | 2 | boot the claimed kernel, installed by its exact version if the build brought a newer one; enable EPEL (DKMS comes from there); firewalld running, SELinux enforcing | runtime |
| `debian13` | `debian-13-latest-x86_64` | 2 | replace the DVD-only `sources.list` with deb.debian.org `trixie`, `trixie-updates` and `trixie-security`; `apt full-upgrade` and boot the claimed kernel; install `linux-headers-amd64 dkms open-iscsi sg3-utils` | runtime |
| `ubuntu2604` | `ubuntu-26.04-latest-x86_64` | 2 | | runtime |
| `rhel10` | `alma-10-latest-x86_64` | 2 | enable EPEL; firewalld running, SELinux enforcing | runtime |
| `debian12` | `debian-12-latest-x86_64` | 2 | | runtime |
| `rhel8` | `alma-8-latest-x86_64` | 2 | enable EPEL; firewalld running, SELinux enforcing | runtime |
| `debian11` | `debian-11-latest-x86_64` | 2 | replace the DVD-only `sources.list` with deb.debian.org `bullseye` and `bullseye-updates`, and `bullseye-security` from archive.debian.org (deb.debian.org's security index still lists packages whose files have moved to the archive, so installs 404); install `linux-headers-$(uname -r) linux-headers-amd64 dkms build-essential open-iscsi sg3-utils` | runtime |
| `sles16` | `sles-16-latest-x86_64` | 2 | | runtime |
| `freebsd14` | `freebsd-14-latest-x86_64` | 2 | | runtime (a port; no package exists yet) |
| `raspios11` | none — a Raspberry Pi | 2 | | runtime on real hardware |
| `macos26` | none — a Mac | 2 | | runtime on real hardware |

**Build checks need no VM.** Rocky 9 and the other rebuilds are compiled in a
container by the platform's `build_check` (`scripts/rhel_kbuild_check.sh -i
rockylinux:9`); only the runtime platform above gets a set of nodes.

**A spec names an OS major line, never a point release.**
`<dist>-<major>-latest-<arch>` builds the newest point release osimager has
for that major (`mkosimage --latest alma-9` shows which). The install media
decides nothing a release claims: the kernel comes from `platforms.json` and
the row's after-build steps, which install it by its exact version when the
newest media brings a later one.

**`debian13` from the DVD ends with no mirror.** The install uses only the
DVD, so the node's `sources.list` names the DVD and nothing else; until the
mirror lines replace it, `apt` can neither upgrade nor install the headers.
An unattended osimager build of this spec has also stopped at "apt
configuration problem": its `early_command` found no `/media/debian.fix`
(the `media` CD was not mounted when it ran), so the stock media scan ran and
failed. Watch the build's VNC console if it waits on SSH past the install.

**Firewalls.** Where the row says firewalld is running, open only what MeshXFS
uses: 7600/tcp (DLM), 7601/udp (discovery), 7602/udp (CAW lock-release requests),
7603/udp (lease heartbeat). Verifying with the firewall on is the point: a
user's RHEL node has it on.

## The development rig

Separate from the platform sets: `run.sh` drives a fleet of Ubuntu 24.04
libvirt domains named `test1`..`testN` (up to 32), built from the `ubuntu2404`
spec above. The name pattern is fixed — `run.sh` finds the fleet by it. The
rig's storage conditions (LIO, SCST, multipath) are in `README.md`. A rig
node is never a member of a platform's set, so the `ubuntu2404` set is nodes
of its own, built from the same spec.
