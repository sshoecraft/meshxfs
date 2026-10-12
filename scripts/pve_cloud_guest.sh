#!/bin/bash
# pve_cloud_guest.sh — a source guest for the Proxmox VM tests
# (tests/pve_live_migrate.sh, tests/pve_ha_failover.sh) on a cluster that has
# no installed guest of its own: a VM made from the Debian 12 cloud image, its
# disk imported onto the shared MXFS storage, never booted.  Each test clones
# it; a clone's first boot runs cloud-init, which
#   - sets root's password to the lab nodes' password and allows root password
#     ssh, which is how the tests drive a guest (tools/mxfs_sshpass.sh), and
#   - installs and starts qemu-guest-agent, which the tests use for the
#     guest's address and liveness.
# The user-data is a Proxmox snippet on every host's `local` storage (a clone
# may boot on any of them), written from the lab secrets store at run time:
# the password is never in this tree.
#
# Usage: scripts/pve_cloud_guest.sh
# Env:   PVE_HOSTS  "<addr> ..." (required): every host of the cluster; the VM
#                   is created on the first
#        IMG        the cloud image on this host (default
#                   /home/steve/vms/iso/debian12-cloud/debian-12-genericcloud-amd64.qcow2)
#        VMID (9000)  STORE (mxfssan)  MEM_MB (1024)  DISK_GB (8)
#        CPU        (x86-64-v2: runs on every host the tests use)
# Prints PVE_CLOUD_GUEST_OK vmid=<id> on success.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSHP="$REPO/tools/mxfs_sshpass.sh"
read -r -a HOSTS <<<"${PVE_HOSTS:?PVE_HOSTS must name the hosts}"
IMG=${IMG:-/home/steve/vms/iso/debian12-cloud/debian-12-genericcloud-amd64.qcow2}
VMID=${VMID:-9000}; STORE=${STORE:-mxfssan}; MEM_MB=${MEM_MB:-1024}; DISK_GB=${DISK_GB:-8}
CPU=${CPU:-x86-64-v2}
TAG="mxfs cloud-image source guest (scripts/pve_cloud_guest.sh)"
SNIP=mxfs-guest-user.yaml
die() { echo "pve_cloud_guest: $*" >&2; exit 1; }
on() { timeout "${3:-60}" "$SSHP" "$1" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^$'; return "${PIPESTATUS[0]}"; }

[ -f "$IMG" ] || die "no image $IMG"
PW=$("$REPO/tools/mxfs_secrets.sh" get node password) && [ -n "$PW" ] || die "no node password in the lab secrets store"
H0=${HOSTS[0]}

existing=$(on "$H0" "qm config $VMID 2>/dev/null | sed -n 's/^description: //p'" 30)
if [ -n "$existing" ]; then
    [[ "$existing" == *pve_cloud_guest* ]] || die "VM $VMID exists and was not made by this script ($existing)"
    echo "VM $VMID already exists (made by this script); leaving it"
    echo "PVE_CLOUD_GUEST_OK vmid=$VMID"; exit 0
fi

# the user-data snippet on every host; `local` must allow snippets
UD="#cloud-config
disable_root: false
ssh_pwauth: true
chpasswd:
  expire: false
  users:
    - {name: root, password: '$PW', type: text}
packages: [qemu-guest-agent]
runcmd:
  - [sh, -c, 'printf \"PermitRootLogin yes\\nPasswordAuthentication yes\\n\" > /etc/ssh/sshd_config.d/10-mxfs-test.conf && systemctl restart ssh']
  - [systemctl, enable, --now, qemu-guest-agent]"
for h in "${HOSTS[@]}"; do
    on "$h" "c=\$(pvesm config local 2>/dev/null | sed -n 's/^[[:space:]]*content //p'); case \",\$c,\" in *,snippets,*) ;; *) pvesm set local --content \"\$c,snippets\" ;; esac
        mkdir -p /var/lib/vz/snippets && umask 077 && cat > /var/lib/vz/snippets/$SNIP <<'EOF'
$UD
EOF
        echo SNIPPET_OK" 30 | grep -q SNIPPET_OK || die "$h: could not write the user-data snippet"
done

timeout 300 "$SSHP" "$H0" SCP "$IMG" /root/mxfs-guest-src.qcow2 </dev/null >/dev/null 2>&1 || die "could not copy the image to $H0"
out=$(on "$H0" "set -e
    qm create $VMID --name mxfs-guest-src --memory $MEM_MB --cores 2 --cpu $CPU --net0 virtio,bridge=vmbr0 \
        --agent enabled=1 --serial0 socket --vga serial0 --scsihw virtio-scsi-pci --ostype l26 --description '$TAG'
    qm set $VMID --virtio0 $STORE:0,import-from=/root/mxfs-guest-src.qcow2,format=raw >/dev/null
    qm resize $VMID virtio0 ${DISK_GB}G >/dev/null
    qm set $VMID --ide2 $STORE:cloudinit --boot order=virtio0 --ipconfig0 ip=dhcp --cicustom user=local:snippets/$SNIP >/dev/null
    rm -f /root/mxfs-guest-src.qcow2
    qm config $VMID | grep -E '^(virtio0|ide2|cicustom|cpu|memory):'
    echo CREATED" 600)
echo "$out"
grep -q CREATED <<<"$out" || die "could not create VM $VMID on $H0"
echo "PVE_CLOUD_GUEST_OK vmid=$VMID"
