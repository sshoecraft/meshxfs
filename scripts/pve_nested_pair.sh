#!/bin/bash
# pve_nested_pair.sh — build a further nested Proxmox VE 9 cluster on clyde,
# beside pve9-1/pve9-2, so the crash and reset steps of
# tests/pve_pair_failover.sh can run on two pairs at once, or so MXFS-on-CAW can
# be tested on a 3-, 4- or 5-node SAN-style cluster.
#
# Each VM is built the way lab/README.md builds every lab node: mkosimage with
# no address, so the lab's DHCP server hands one out and registers the name.
# pve9-1/pve9-2's disks are never copied: a clone carries their cluster, their
# DRBD resource and their identity.
#
# Usage: scripts/pve_nested_pair.sh [phase ...]
#   build    mkosimage installs every VM at once from the lab's proxmox-ve spec
#            (packer shuts each down when its install answers ssh), then
#            scripts/vm_reclaim_disk.sh gives each disk discard
#   start    each VM started; done when every one resolves in the lab's DNS
#            and answers ssh
#   prep     /etc/hosts names every host, the pve-no-subscription repository in
#            place of the subscription-only ones, and drbd-utils and fio (the
#            guide's own packages come with its section 1)
#   cluster  a Proxmox cluster of their own: pvecm create on the first host
#            named, then each other host in turn gets root ssh trust and runs
#            pvecm add; done when every host sees one vote per host and reaches
#            every other by name over ssh as root
#   (default: build start prep cluster)
#
# Then MXFS on DRBD, by the guide, from this working tree:
#   env PVE_PAIR="<addr> <addr>" FROM_TREE=1 LV_SIZE=12G \
#       scripts/pve_pair_from_guide.sh guide verify
#
# Env:
#   NESTED_PAIR  the hosts' names (default "pve9-3 pve9-4"); the first is
#                participant 0, which creates the cluster.  Two or more.
#   MEM_MIB      each VM's memory (default 4096; guests run inside it)
#   CPUS         each VM's vCPUs (default 8)
#   CLUSTER      the Proxmox cluster name (default mxfslab9b)
#   OSI_SPEC     the osimager location/spec (default qemu/lab/proxmox-ve-9.1-x86_64,
#                the pve9 row of lab/vms.md)
#   BUILD_BUDGET seconds for the installs, run at once (default 700: two
#                finished in 5 min 37 s on clyde, packer's ssh wait included)
#   BOOT_BUDGET  seconds from `virsh start` to ssh answering (default 120:
#                pve9-1 answers 21-57 s after a reset)
#
# Refuses pve9-1 and pve9-2: they are the pair this one runs beside, and every
# phase here rewrites a host.
# Evidence: tests/evidence/pve_nested_pair/<UTC stamp>/
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
. "$REPO/tools/mxfs_lab.sh"
SSHP="$REPO/tools/mxfs_sshpass.sh"
VIRSH="virsh -c qemu:///system"
VMS_DIR=$(lab_get paths qemu_root 2>/dev/null) || VMS_DIR=/home/steve/vms/qemu
OSI_SPEC=${OSI_SPEC:-qemu/lab/proxmox-ve-9.1-x86_64}
CLUSTER=${CLUSTER:-mxfslab9b}
BUILD_BUDGET=${BUILD_BUDGET:-700}
BOOT_BUDGET=${BOOT_BUDGET:-120}
MEM_MIB=${MEM_MIB:-4096}
CPUS=${CPUS:-8}
DOMAIN=$(lab_need dns domain) || exit 2
read -r -a NAMES <<<"${NESTED_PAIR:-pve9-3 pve9-4}"
[ "${#NAMES[@]}" -ge 2 ] || { echo "pve_nested_pair: NESTED_PAIR must name at least two hosts"; exit 2; }
PHASES=("$@")
[ "${#PHASES[@]}" -gt 0 ] || PHASES=(build start prep cluster)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
EVID="$REPO/tests/evidence/pve_nested_pair/$STAMP"
mkdir -p "$EVID" || exit 1

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$EVID/log"; }
die() { say "FAIL: $*"; exit 1; }
on() {  # <host> <cmd> [timeout]
    local out rc
    out=$(timeout "${3:-60}" "$SSHP" "${ADDR[$1]}" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$')
    rc=${PIPESTATUS[0]}
    { echo "### [$(date +%H:%M:%S)] $1 (rc=$rc): $2"; echo "$out"; } >> "$EVID/host-$1.log"
    printf '%s\n' "$out"
    return "$rc"
}

for n in "${NAMES[@]}"; do
    case "$n" in
        pve9-1|pve9-2) die "refusing $n: it is the pair this one runs beside" ;;
        *=*) die "NESTED_PAIR takes names only ('$n'): the lab's DHCP server assigns the addresses" ;;
    esac
done
N0=${NAMES[0]}
JOIN=("${NAMES[@]:1}")
NHOSTS=${#NAMES[@]}
declare -A ADDR

# resolve <host>: its address in the lab's DNS, which answers only while the
# host is up and holds a lease
resolve() {
    getent ahostsv4 "$1.$DOMAIN" | awk 'NR == 1 {print $1}'
}

# wait_up <host> <budget>: prints seconds until the host resolved and answered
# ssh as root, and records its address
wait_up() {
    local t0 a
    t0=$(date +%s)
    while [ $(( $(date +%s) - t0 )) -lt "$2" ]; do
        a=$(resolve "$1")
        if [ -n "$a" ]; then
            ADDR[$1]=$a
            on "$1" "echo SSH_UP" 10 | grep -q SSH_UP && { echo $(( $(date +%s) - t0 )); return 0; }
        fi
        sleep 3
    done
    return 1
}

# every later phase needs each host's address; a host that does not resolve is down
need_addrs() {
    local n a
    for n in "${NAMES[@]}"; do
        [ -n "${ADDR[$n]:-}" ] && continue
        a=$(resolve "$n")
        [ -n "$a" ] || die "$n.$DOMAIN does not resolve: it is off or holds no lease (run the start phase)"
        ADDR[$n]=$a
    done
}

build() {
    local n rc=0 t0
    say "== build: ${NAMES[*]} from $OSI_SPEC (${CPUS} vCPU, ${MEM_MIB} MiB), budget ${BUILD_BUDGET}s"
    command -v mkosimage >/dev/null || die "mkosimage is not on PATH (osimager: lab/README.md)"
    for n in "${NAMES[@]}"; do
        $VIRSH dominfo "$n" >/dev/null 2>&1 && die "$n is already defined in libvirt; this phase installs a new VM"
        [ -e "$VMS_DIR/$n" ] && die "$VMS_DIR/$n exists; this phase installs a new VM"
        # osimager takes the address a resolving name already has as a static
        # one: a fresh name must come from DHCP
        [ -z "$(resolve "$n")" ] || die "$n.$DOMAIN still resolves (a live lease); mkosimage would pin that address"
    done
    t0=$(date +%s)
    for n in "${NAMES[@]}"; do
        timeout "$BUILD_BUDGET" mkosimage -D libvirt_uri=qemu:///system -D "cpu_cores=$CPUS" -D "memory=$MEM_MIB" \
            "$OSI_SPEC" "$n" > "$EVID/build-$n.log" 2>&1 &
    done
    for n in "${NAMES[@]}"; do wait -n || rc=1; done
    for n in "${NAMES[@]}"; do
        grep -a -E 'Build .* finished|errored|Error|Timeout' "$EVID/build-$n.log" | sed 's/\x1b\[[0-9;]*m//g' | tail -3 | sed "s|^|  $n: |" | tee -a "$EVID/log"
        $VIRSH dominfo "$n" >/dev/null 2>&1 || rc=1
    done
    [ "$rc" = 0 ] || die "a build failed or ran past ${BUILD_BUDGET}s (budget exceeded); see $EVID/build-*.log"
    say "all $NHOSTS installed in $(( $(date +%s) - t0 ))s"
    for n in "${NAMES[@]}"; do
        timeout 300 "$REPO/scripts/vm_reclaim_disk.sh" "$n" 2>&1 | sed "s|^|  $n: |" | tee -a "$EVID/log"
        [ "${PIPESTATUS[0]}" = 0 ] || die "vm_reclaim_disk.sh failed for $n"
    done
}

start() {
    local n s
    say "== start: ${NAMES[*]}"
    for n in "${NAMES[@]}"; do
        [ "$($VIRSH domstate "$n" 2>/dev/null)" = running ] && continue
        $VIRSH start "$n" >> "$EVID/log" 2>&1 || die "could not start $n"
    done
    for n in "${NAMES[@]}"; do
        s=$(wait_up "$n" "$BOOT_BUDGET") || die "$n did not resolve and answer ssh within ${BOOT_BUDGET}s of its start"
        ADDR[$n]=$(resolve "$n")   # wait_up ran in a subshell
        say "$n (${ADDR[$n]}) answered ssh ${s}s after the wait began: $(on "$n" 'hostname; uname -r; pveversion' 20 | tr '\n' ' ')"
    done
}

prep() {
    local n m alt="" hl=""
    need_addrs
    for m in "${NAMES[@]}"; do alt+="${alt:+|}$m"; hl+=" ${ADDR[$m]} $m.$DOMAIN $m"; done
    say "== prep: /etc/hosts, the no-subscription repository, drbd-utils and fio"
    for n in "${NAMES[@]}"; do
        on "$n" "set -e
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
        grep -q PREP_OK "$EVID/host-$n.log" || die "$n: prep failed (see $EVID/host-$n.log and /root/pve_nested_pair_apt.log there)"
    done
}

cluster() {
    local k1 out n m a0 an
    need_addrs
    a0=${ADDR[$N0]}
    say "== cluster: $CLUSTER of ${NAMES[*]}, created on $N0 ($a0)"
    out=$(on "$N0" "pvecm status >/dev/null 2>&1 && echo IN_CLUSTER; true" 30)
    if grep -q IN_CLUSTER <<<"$out"; then
        say "$N0 is already in a cluster: $(on "$N0" "pvecm status | awk '/^Name:/ {print \$2}'" 20)"
    else
        on "$N0" "pvecm create $CLUSTER --link0 $a0 2>&1 | tail -3; echo CREATE_RC=\${PIPESTATUS[0]}" 120 | tee -a "$EVID/log" | grep -q 'CREATE_RC=0' \
            || die "pvecm create on $N0 failed"
    fi
    # one host at a time: a join restarts the cluster filesystem, so the next
    # waits for quorum again before its key can be written
    for n in "${JOIN[@]}"; do
        an=${ADDR[$n]}
        # the joining host logs in to the first as root by key: its key in the
        # cluster's authorized_keys, the first host's key in its known_hosts
        k1=$(on "$n" "[ -f /root/.ssh/id_rsa.pub ] || ssh-keygen -q -t rsa -b 4096 -N '' -f /root/.ssh/id_rsa; cat /root/.ssh/id_rsa.pub" 30 | grep '^ssh-')
        [ -n "$k1" ] || die "$n has no root ssh key"
        # /root/.ssh/authorized_keys is /etc/pve/priv/authorized_keys, and /etc/pve
        # refuses writes while the cluster filesystem restarts after a create or
        # a join (seen: "echo: write error: Permission denied" a second after it).
        # The write itself is what is retried: [ -w ] is true for root whether
        # or not the cluster filesystem will take the write.
        on "$N0" "for i in \$(seq 1 30); do
                grep -qxF '$k1' /root/.ssh/authorized_keys 2>/dev/null && break
                pvecm status 2>/dev/null | grep -q '^Quorate: *Yes' && echo '$k1' >> /root/.ssh/authorized_keys 2>/dev/null
                grep -qxF '$k1' /root/.ssh/authorized_keys 2>/dev/null && break
                sleep 1
            done
            grep -qxF '$k1' /root/.ssh/authorized_keys && echo KEY_OK" 45 | grep -q KEY_OK || die "could not authorize $n's key on $N0"
        on "$n" "ssh-keygen -R $a0 >/dev/null 2>&1; ssh-keyscan -t ed25519,rsa $a0 2>/dev/null >> /root/.ssh/known_hosts; ssh -o BatchMode=yes root@$a0 hostname" 30 | grep -qx "$N0" \
            || die "$n cannot log in to $N0 as root by key"
        out=$(on "$n" "pvecm status >/dev/null 2>&1 && echo IN_CLUSTER; true" 30)
        if ! grep -q IN_CLUSTER <<<"$out"; then
            on "$n" "pvecm add $a0 --use_ssh 1 --link0 $an 2>&1 | tail -4; echo ADD_RC=\${PIPESTATUS[0]}" 300 | tee -a "$EVID/log" | grep -q 'ADD_RC=0' \
                || die "pvecm add on $n failed"
        fi
    done
    for n in "${NAMES[@]}"; do
        out=$(on "$n" "echo name=\$(pvecm status | awk '/^Name:/ {print \$2}') votes=\$(pvecm status | awk '/^Total votes:/ {print \$3}') quorate=\$(pvecm status | awk '/^Quorate:/ {print \$2}')" 30)
        say "$n: $out"
        [ "$out" = "name=$CLUSTER votes=$NHOSTS quorate=Yes" ] || die "$n is not a quorate member of the $NHOSTS-node $CLUSTER"
    done
    # the guard's release check logs in to a peer by its host name.  PVE 9 keeps
    # each node's host key in /etc/pve/nodes/<node>/ssh_known_hosts for its own
    # ssh calls, and a plain `ssh <peer>` checks neither file (seen: "Host key
    # verification failed"), so each host's root known_hosts gets every peer's
    # key from the cluster's copy, under its name and its address
    for n in "${NAMES[@]}"; do
        for m in "${NAMES[@]}"; do
            [ "$m" = "$n" ] && continue
            on "$n" "touch /root/.ssh/known_hosts; ssh-keygen -R $m >/dev/null 2>&1; ssh-keygen -R ${ADDR[$m]} >/dev/null 2>&1
                sed -n 's/^$m /$m,${ADDR[$m]} /p' /etc/pve/nodes/$m/ssh_known_hosts >> /root/.ssh/known_hosts; echo KH_OK" 30 | grep -q KH_OK || die "could not add $m's host key on $n"
            on "$n" "ssh -o BatchMode=yes $m hostname" 30 | grep -qx "$m" || die "$n cannot reach $m by name over ssh as root"
        done
    done
    say "cluster $CLUSTER up: $NHOSTS votes, quorate, root ssh by name between every pair"
}

for ph in "${PHASES[@]}"; do
    case "$ph" in
        build|start|prep|cluster) "$ph" ;;
        *) die "unknown phase $ph" ;;
    esac
done
say "evidence: $EVID"
