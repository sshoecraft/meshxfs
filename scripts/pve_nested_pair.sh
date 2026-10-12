#!/bin/bash
# pve_nested_pair.sh — build a further nested Proxmox VE 9 pair on clyde, shaped
# like pve9-1/pve9-2, so the crash and reset steps of tests/pve_pair_failover.sh
# can run on two pairs at once.
#
# pve9-1/pve9-2's disks are not copied.  They run, so a file copy of their
# images is no single moment of either disk, and a copy carries their cluster,
# their DRBD resource and, through its DHCP lease, pve9-1's address: a clone
# booted with that identity takes the address and joins their cluster.  Each VM
# is installed fresh, the way pve9-1/pve9-2 were — osimager's packer qemu build
# of proxmox-ve 9.1 with the Proxmox auto-installer — but with a static address
# outside dnsmasq's range, so nothing else on br0 can be handed it.
#
# Usage: scripts/pve_nested_pair.sh [phase ...]
#   build    osimager installs both VMs at once from the PVE 9.1 ISO in ISO_DIR
#            (packer shuts each down when its install answers ssh)
#   define   each VM's libvirt definition replaced by one shaped like pve9-1's
#            (8 vCPU, 4 GiB, i440fx, host CPU, on_crash destroy, virtio disk with
#            discard, br0), then started; done when both answer ssh
#   prep     /etc/hosts names both hosts, the pve-no-subscription repository in
#            place of the subscription-only ones, and drbd-utils and fio (the
#            guide's own packages come with its section 1)
#   cluster  a Proxmox cluster of their own: pvecm create on the lowest
#            address, then each other host in turn gets root ssh trust and runs
#            pvecm add; done when every host sees one vote per host and reaches
#            every other by name over ssh as root
#
# NESTED_PAIR may name more than two hosts: the same phases build a 3-, 4- or
# 5-node cluster (e.g. the SAN-style cluster MXFS-on-CAW is tested on).
#   (default: build define prep cluster)
#
# Then MXFS on DRBD, by the guide, from this working tree:
#   env PVE_PAIR="<addr> <addr>" FROM_TREE=1 LV_SIZE=12G \
#       scripts/pve_pair_from_guide.sh guide verify
#
# Env:
#   NESTED_PAIR  "name=addr name=addr ..." (default "pve9-3=192.168.120.211
#                pve9-4=192.168.120.212"); the lowest address is participant 0
#   MEM_MIB      each VM's memory (default 4096; guests run inside it)
#   CLUSTER      the Proxmox cluster name (default mxfslab9b)
#   ISO_DIR      where proxmox-ve_9.1-1.iso is (default /home/steve/vms/iso)
#   BUILD_BUDGET seconds for the two installs, run at once (default 700: both
#                finished in 5 min 37 s on clyde, packer's ssh wait included)
#   BOOT_BUDGET  seconds from `virsh start` to ssh answering (default 120:
#                pve9-1 answers 21-57 s after a reset)
#
# Refuses pve9-1 and pve9-2 by name and by address: they are the pair this one
# runs beside, and every phase here rewrites a host.
# Evidence: tests/evidence/pve_nested_pair/<UTC stamp>/
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSHP="$REPO/tools/mxfs_sshpass.sh"
VIRSH="virsh -c qemu:///system"
MKOSIMAGE=${MKOSIMAGE:-/home/steve/src/osimager/bin/mkosimage}
ISO_DIR=${ISO_DIR:-/home/steve/vms/iso}
VMS_DIR=${VMS_DIR:-/home/steve/vms/qemu}
CLUSTER=${CLUSTER:-mxfslab9b}
BUILD_BUDGET=${BUILD_BUDGET:-700}
BOOT_BUDGET=${BOOT_BUDGET:-120}
MEM_MIB=${MEM_MIB:-4096}
read -r -a SPEC <<<"${NESTED_PAIR:-pve9-3=192.168.120.211 pve9-4=192.168.120.212}"
[ "${#SPEC[@]}" -ge 2 ] || { echo "pve_nested_pair: NESTED_PAIR must name at least two hosts"; exit 2; }
PHASES=("$@")
[ "${#PHASES[@]}" -gt 0 ] || PHASES=(build define prep cluster)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
EVID="$REPO/tests/evidence/pve_nested_pair/$STAMP"
mkdir -p "$EVID" || exit 1

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$EVID/log"; }
die() { say "FAIL: $*"; exit 1; }
on() {  # <host addr> <cmd> [timeout]
    local out rc
    out=$(timeout "${3:-60}" "$SSHP" "$1" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$')
    rc=${PIPESTATUS[0]}
    { echo "### [$(date +%H:%M:%S)] $1 (rc=$rc): $2"; echo "$out"; } >> "$EVID/host-$1.log"
    printf '%s\n' "$out"
    return "$rc"
}

declare -A ADDR
NAMES=()
for s in "${SPEC[@]}"; do
    n=${s%%=*}; a=${s#*=}
    [ -n "$n" ] && [ -n "$a" ] && [ "$n" != "$s" ] || die "NESTED_PAIR entry '$s' is not name=addr"
    case "$n" in pve9-1|pve9-2) die "refusing $n: it is the pair this one runs beside" ;; esac
    case "$a" in 192.168.120.192|192.168.120.137) die "refusing $a: pve9-1/pve9-2 hold it" ;; esac
    ADDR[$n]=$a; NAMES+=("$n")
done
# every host in address order: the lowest is participant 0, which creates the
# cluster; each of the others joins it
mapfile -t NAMES < <(for n in "${NAMES[@]}"; do echo "${ADDR[$n]} $n"; done \
    | python3 -I -c 'import ipaddress, sys
rows = [l.split() for l in sys.stdin if l.strip()]
for a, n in sorted(rows, key=lambda r: ipaddress.ip_address(r[0])): print(n)')
N0=${NAMES[0]}; A0=${ADDR[$N0]}
JOIN=("${NAMES[@]:1}")
NHOSTS=${#NAMES[@]}

# wait_ssh <addr> <budget>: prints seconds until the host answered as root
wait_ssh() {
    local t0
    t0=$(date +%s)
    while [ $(( $(date +%s) - t0 )) -lt "$2" ]; do
        on "$1" "echo SSH_UP" 10 | grep -q SSH_UP && { echo $(( $(date +%s) - t0 )); return 0; }
        sleep 3
    done
    return 1
}

build() {
    local n rc=0
    say "== build: ${NAMES[*]} from $ISO_DIR/proxmox-ve_9.1-1.iso, budget ${BUILD_BUDGET}s"
    [ -f "$ISO_DIR/proxmox-ve_9.1-1.iso" ] || die "no $ISO_DIR/proxmox-ve_9.1-1.iso"
    for n in "${NAMES[@]}"; do
        $VIRSH dominfo "$n" >/dev/null 2>&1 && die "$n is already defined in libvirt; this phase installs a new VM"
        [ -e "$VMS_DIR/$n" ] && die "$VMS_DIR/$n exists; this phase installs a new VM"
        ping -c 1 -W 1 "${ADDR[$n]}" >/dev/null 2>&1 && die "${ADDR[$n]} answers ping: something on br0 holds it"
    done
    local t0
    t0=$(date +%s)
    for n in "${NAMES[@]}"; do
        timeout "$BUILD_BUDGET" "$MKOSIMAGE" --local -D "iso_path=$ISO_DIR" qemu/lab/proxmox-ve-9.1-x86_64 "$n" "${ADDR[$n]}" \
            > "$EVID/build-$n.log" 2>&1 &
    done
    for n in "${NAMES[@]}"; do wait -n || rc=1; done
    for n in "${NAMES[@]}"; do
        grep -a -E 'Build .* finished|errored|Error|Timeout' "$EVID/build-$n.log" | sed 's/\x1b\[[0-9;]*m//g' | tail -3 | sed "s|^|  $n: |" | tee -a "$EVID/log"
        [ -f "$VMS_DIR/$n/$n" ] || rc=1
    done
    [ "$rc" = 0 ] || die "a build failed or ran past ${BUILD_BUDGET}s (budget exceeded); see $EVID/build-*.log"
    say "all $NHOSTS installed in $(( $(date +%s) - t0 ))s"
}

define() {
    local n xml
    say "== define: libvirt definitions shaped like pve9-1's (${MEM_MIB} MiB each)"
    for n in "${NAMES[@]}"; do
        [ -f "$VMS_DIR/$n/$n" ] || die "no disk image $VMS_DIR/$n/$n"
        [ "$($VIRSH domstate "$n" 2>/dev/null)" = running ] && die "$n is running; define replaces the definition of a stopped VM"
        xml="$EVID/$n.xml"
        cat > "$xml" <<EOF
<domain type='kvm'>
  <name>$n</name>
  <memory unit='KiB'>$(( MEM_MIB * 1024 ))</memory>
  <currentMemory unit='KiB'>$(( MEM_MIB * 1024 ))</currentMemory>
  <vcpu placement='static'>8</vcpu>
  <os>
    <type arch='x86_64' machine='pc-i440fx-noble'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='on'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' discard='unmap' detect_zeroes='unmap'/>
      <source file='$VMS_DIR/$n/$n'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <controller type='scsi' index='0' model='virtio-scsi'/>
    <interface type='bridge'>
      <source bridge='br0'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'>
      <target type='isa-serial' port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <input type='mouse' bus='ps2'/>
    <input type='keyboard' bus='ps2'/>
    <graphics type='vnc' port='-1' autoport='yes' listen='0.0.0.0'/>
    <audio id='1' type='none'/>
    <video>
      <model type='cirrus' vram='16384' heads='1' primary='yes'/>
    </video>
    <memballoon model='virtio'/>
  </devices>
</domain>
EOF
        if $VIRSH dominfo "$n" >/dev/null 2>&1; then
            $VIRSH undefine "$n" >> "$EVID/log" 2>&1 || die "could not undefine $n"
        fi
        $VIRSH define "$xml" >> "$EVID/log" 2>&1 || die "could not define $n from $xml"
        $VIRSH start "$n" >> "$EVID/log" 2>&1 || die "could not start $n"
        say "$n defined and started: $($VIRSH domiflist "$n" | awk '$2 == "bridge" {print $3, $5}')"
    done
    for n in "${NAMES[@]}"; do
        s=$(wait_ssh "${ADDR[$n]}" "$BOOT_BUDGET") || die "$n (${ADDR[$n]}) did not answer ssh within ${BOOT_BUDGET}s of its start"
        say "$n answered ssh ${s}s after the wait began: $(on "${ADDR[$n]}" 'hostname; uname -r; pveversion' 20 | tr '\n' ' ')"
    done
}

prep() {
    local n m alt="" hl=""
    for m in "${NAMES[@]}"; do alt+="${alt:+|}$m"; hl+=" ${ADDR[$m]} $m.vm.localdomain $m"; done
    say "== prep: /etc/hosts, the no-subscription repository, drbd-utils and fio"
    for n in "${NAMES[@]}"; do
        on "${ADDR[$n]}" "set -e
            [ \"\$(hostname)\" = $n ] || { echo \"WRONG_HOST \$(hostname)\"; exit 1; }
            sed -i -E '/[[:space:]]($alt)([.[:space:]]|\$)/d' /etc/hosts
            printf '%s %s %s\n'$hl >> /etc/hosts
            k=/usr/share/keyrings/proxmox-archive-keyring.gpg
            [ -f \$k ]
            printf 'Types: deb\nURIs: http://download.proxmox.com/debian/pve\nSuites: trixie\nComponents: pve-no-subscription\nSigned-By: %s\n' \$k > /etc/apt/sources.list.d/pve-no-subscription.sources
            for f in pve-enterprise ceph; do s=/etc/apt/sources.list.d/\$f.sources; [ -f \$s ] && mv -f \$s \$s.backup; done
            export DEBIAN_FRONTEND=noninteractive
            apt-get update > /root/pve_nested_pair_apt.log 2>&1
            apt-get install -y drbd-utils fio >> /root/pve_nested_pair_apt.log 2>&1
            command -v drbdadm fio | tr '\n' ' '; echo PREP_OK" 600 | tail -2 | sed "s|^|  $n: |" | tee -a "$EVID/log"
        grep -q PREP_OK "$EVID/host-${ADDR[$n]}.log" || die "$n: prep failed (see $EVID/host-${ADDR[$n]}.log and /root/pve_nested_pair_apt.log there)"
    done
}

cluster() {
    local k1 out n m a an am
    say "== cluster: $CLUSTER of ${NAMES[*]}, created on $N0 ($A0)"
    out=$(on "$A0" "pvecm status >/dev/null 2>&1 && echo IN_CLUSTER; true" 30)
    if grep -q IN_CLUSTER <<<"$out"; then
        say "$N0 is already in a cluster: $(on "$A0" "pvecm status | awk '/^Name:/ {print \$2}'" 20)"
    else
        on "$A0" "pvecm create $CLUSTER --link0 $A0 2>&1 | tail -3; echo CREATE_RC=\${PIPESTATUS[0]}" 120 | tee -a "$EVID/log" | grep -q 'CREATE_RC=0' \
            || die "pvecm create on $N0 failed"
    fi
    # one host at a time: a join restarts the cluster filesystem, so the next
    # waits for quorum again before its key can be written
    for n in "${JOIN[@]}"; do
        an=${ADDR[$n]}
        # the joining host logs in to the first as root by key: its key in the
        # cluster's authorized_keys, the first host's key in its known_hosts
        k1=$(on "$an" "[ -f /root/.ssh/id_rsa.pub ] || ssh-keygen -q -t rsa -b 4096 -N '' -f /root/.ssh/id_rsa; cat /root/.ssh/id_rsa.pub" 30 | grep '^ssh-')
        [ -n "$k1" ] || die "$n has no root ssh key"
        # /root/.ssh/authorized_keys is /etc/pve/priv/authorized_keys, and /etc/pve
        # refuses writes while the cluster filesystem restarts after a create or
        # a join (seen: "echo: write error: Permission denied" a second after it).
        # The write itself is what is retried: [ -w ] is true for root whether
        # or not the cluster filesystem will take the write.
        on "$A0" "for i in \$(seq 1 30); do
                grep -qxF '$k1' /root/.ssh/authorized_keys 2>/dev/null && break
                pvecm status 2>/dev/null | grep -q '^Quorate: *Yes' && echo '$k1' >> /root/.ssh/authorized_keys 2>/dev/null
                grep -qxF '$k1' /root/.ssh/authorized_keys 2>/dev/null && break
                sleep 1
            done
            grep -qxF '$k1' /root/.ssh/authorized_keys && echo KEY_OK" 45 | grep -q KEY_OK || die "could not authorize $n's key on $N0"
        on "$an" "ssh-keygen -R $A0 >/dev/null 2>&1; ssh-keyscan -t ed25519,rsa $A0 2>/dev/null >> /root/.ssh/known_hosts; ssh -o BatchMode=yes root@$A0 hostname" 30 | grep -qx "$N0" \
            || die "$n cannot log in to $N0 as root by key"
        out=$(on "$an" "pvecm status >/dev/null 2>&1 && echo IN_CLUSTER; true" 30)
        if ! grep -q IN_CLUSTER <<<"$out"; then
            on "$an" "pvecm add $A0 --use_ssh 1 --link0 $an 2>&1 | tail -4; echo ADD_RC=\${PIPESTATUS[0]}" 300 | tee -a "$EVID/log" | grep -q 'ADD_RC=0' \
                || die "pvecm add on $n failed"
        fi
    done
    for n in "${NAMES[@]}"; do
        a=${ADDR[$n]}
        out=$(on "$a" "echo name=\$(pvecm status | awk '/^Name:/ {print \$2}') votes=\$(pvecm status | awk '/^Total votes:/ {print \$3}') quorate=\$(pvecm status | awk '/^Quorate:/ {print \$2}')" 30)
        say "$a: $out"
        [ "$out" = "name=$CLUSTER votes=$NHOSTS quorate=Yes" ] || die "$a is not a quorate member of the $NHOSTS-node $CLUSTER"
    done
    # the guard's release check logs in to a peer by its host name.  PVE 9 keeps
    # each node's host key in /etc/pve/nodes/<node>/ssh_known_hosts for its own
    # ssh calls, and a plain `ssh <peer>` checks neither file (seen: "Host key
    # verification failed"), so each host's root known_hosts gets every peer's
    # key from the cluster's copy, under its name and its address
    for n in "${NAMES[@]}"; do
        an=${ADDR[$n]}
        for m in "${NAMES[@]}"; do
            [ "$m" = "$n" ] && continue
            am=${ADDR[$m]}
            on "$an" "touch /root/.ssh/known_hosts; ssh-keygen -R $m >/dev/null 2>&1; ssh-keygen -R $am >/dev/null 2>&1
                sed -n 's/^$m /$m,$am /p' /etc/pve/nodes/$m/ssh_known_hosts >> /root/.ssh/known_hosts; echo KH_OK" 30 | grep -q KH_OK || die "could not add $m's host key on $n"
            on "$an" "ssh -o BatchMode=yes $m hostname" 30 | grep -qx "$m" || die "$n cannot reach $m by name over ssh as root"
        done
    done
    say "cluster $CLUSTER up: $NHOSTS votes, quorate, root ssh by name between every pair"
}

for ph in "${PHASES[@]}"; do
    case "$ph" in
        build|define|prep|cluster) "$ph" ;;
        *) die "unknown phase $ph" ;;
    esac
done
say "evidence: $EVID"
