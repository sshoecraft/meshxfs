#!/bin/bash
#
# vsphere_shared_fence.sh — the shared attachment (docs/shared-disk-attachment.md)
# on the vSphere guests' multi-writer VMDK: bring it up, load it, kill a node
# and check the survivor recovers every write the victim acknowledged
#
# Usage: tests/vsphere_shared_fence.sh up <manual|vcenter|quorum>
#        tests/vsphere_shared_fence.sh work
#        tests/vsphere_shared_fence.sh down
#        tests/vsphere_shared_fence.sh chk
#        tests/vsphere_shared_fence.sh kill <poweroff|panic> [<survivor> <victim>]
#        tests/vsphere_shared_fence.sh rejoin <vm>
#        tests/vsphere_shared_fence.sh restart
#        tests/vsphere_shared_fence.sh baseline     (native XFS, `work`'s load)
#        tests/vsphere_shared_fence.sh refuse       (fence=scsipr must be refused)
#        tests/vsphere_shared_fence.sh split        (fence=quorum: VM2 loses the vote)
#        tests/vsphere_shared_fence.sh dinq <link|isolate> <cycles>
#        tests/vsphere_shared_fence.sh noquorum     (fence=quorum: qnetd lost, then the link)
#        tests/vsphere_shared_fence.sh freeze <guest|host>
#
#   up      format the shared disk from VM1 (tests/setup/prep_fs.sh), then
#           load the module (TCP transport) and mount it on VM1, then VM2,
#           with -o fence=<method>,peers=<VM1 addr>/<VM2 addr>
#           (tests/setup/prep_node.sh); prints each node's P-SHARED-ARM line
#   work    both nodes at once: each writes WORK_N files of WORK_KB KiB into
#           its own directory and WORK_N into one shared directory, fsyncing
#           each; then each reads every file the other wrote and compares
#           md5s, and lists the shared directory (2*WORK_N entries)
#   down    unmount both
#   chk     tools/chk_mxfs -v on VM1 (both must be unmounted)
#   kill    the victim writes fsync-acknowledged files, the acknowledgements
#           streaming here over ssh; after KILL_AFTER s it is powered off
#           (`poweroff`: vCenter force power-off) or panicked (`panic`:
#           sysrq-c, the VM stays powered on, so the survivor's fence must
#           act).  Under fence=manual the operator step is done here: the VM
#           is powered off if it is not, then the posted request confirmed.
#           Asserts the survivor's death certificate (P238-SHARED-FENCE-ENDED),
#           the victim slice's foreign replay and P163-RECOVERY-COMPLETE, then
#           reads every acknowledged file back on the survivor.
#   rejoin  power the VM on if needed and mount it again (as `up` does)
#   restart both nodes write, both VMs are powered off at once and on again,
#           VM1 mounts, then VM2 (cmd_restart says what is asserted)
#   split   fence=quorum (docs/quorum-takeover.md): VM2 writes acknowledged
#           files, then its traffic to and from VM1 is dropped (nftables on
#           VM2) while both still reach qnetd, so ffsplit's tie-break keeps
#           the vote with the lower node id, VM1.  VM2 must end its own boot
#           (P-QUORUM-LOST-RESET, captured by tools/node_kmsg_stream.sh) within
#           the takeover bound, VM1 must keep its boot, take VM2's slice over
#           and read every file VM2 acknowledged.  VM2 is left booted again,
#           unmounted (`rejoin` mounts it).
#   dinq    D_inq of docs/quorum-takeover.md, measured rather than read off
#           corosync's configuration: with nothing mounted, VM2's traffic to
#           VM1 (`link`), or to VM1 and qnetd (`isolate`), is dropped, and VM2
#           times how long votequorum still calls it quorate; the cut is lifted
#           and the pair re-forms before the next cycle.  A random 0-3 s delay
#           before each cut moves it across corosync's token rotation and the
#           QDevice's heartbeat.  Asserts every cycle's D_inq + the lease is
#           under the takeover bound.
#   noquorum both nodes write, qnetd is dropped on both, then the link between
#           them: neither holds the vote, so both must end their boots and
#           neither may take the other over.  Then both mount again (as after a
#           whole-cluster restart) and every acknowledged file reads back.
#   freeze  Q of docs/quorum-takeover.md: VM2 overwrites a preallocated file
#           with O_DIRECT from 16 threads, every 4 KiB block stamped with its
#           boot, thread and sequence; then VM2 is frozen (`guest`: a vSphere
#           suspend of the VM; `host`: Workstation pauses the nested ESXi host
#           VM2 runs on, its I/O queues with it).  VM1 must take VM2 over; it
#           then reads the file (O_DIRECT, snapshot A), VM2 is resumed, ends its
#           boot, and VM1 reads the file again (snapshot B).  A block that
#           differs between A and B is a write of VM2's that landed after the
#           takeover: a late write, and a FAIL.
#
# Env: VM1 (vstest1), VM2 (vstest2), SHARED_WWID (the VMDK's naa id, as
#      /sys/block/sdX/device/wwid prints it), MNT (/mnt/shared),
#      KILL_AFTER (6), WORK_N (100), WORK_KB (256), OUT (evidence directory),
#      NODE_REPO (/src/mxfs: the tree the nodes run prep and tools from),
#      HOLD_MS (0; kill: arm the victim's next swap to hold the lock this long,
#      so it dies holding it)
#
# Bounds, each a performance assertion: the RECOVERY bound is the TCP death
# detection (heartbeat expiry, ~62 s, tests/tcp_death_replay.sh) + vCenter's
# answer (login, inventory and a power-off task: the helper's own 60 s upcall
# bound covers it; measured ~2-9 s) + replay of a 6 s write burst (~5 s) = 140 s.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SSH="$HERE/tools/mxfs_sshpass.sh"
POWER="$HERE/tools/node_power.sh"
VM1=${VM1:-vstest1}; VM2=${VM2:-vstest2}
SHARED_WWID=${SHARED_WWID:-naa.6000c2952d4cf17b9c6f50c882f9dda9}
MNT=${MNT:-/mnt/shared}
# the tree the nodes run from: the shared /src/mxfs, or a node-local copy
# built for their platform (PLATFORM_TREE=... scripts/platform_build.sh)
NODE_REPO=${NODE_REPO:-/src/mxfs}
KILL_AFTER=${KILL_AFTER:-6}
WORK_N=${WORK_N:-100}; WORK_KB=${WORK_KB:-256}
RECOVERY_BOUND=${RECOVERY_BOUND:-140}
# split: the loser resets within the quorum takeover bound (45 s: corosync's
# token + consensus, the QDevice's vote withdrawal and the 3 s lease), its last
# heartbeat then ages out the death window (~62 s), and its slice replays
# (~5 s): 112 s, with 28 s for the monitor's sampling and the fence leg = 140 s
SPLIT_RESET_BOUND=${SPLIT_RESET_BOUND:-45}
SPLIT_BOUND=${SPLIT_BOUND:-140}
HOLD_MS=${HOLD_MS:-0}   # kill: the victim dies holding the swap lock (dbg_drbd_cas_hold_ms)
QNETD=${QNETD:-192.168.1.5}
# dinq: the takeover bound less the lease (3 s) and an immediate reset is what
# D_inq may use up (docs/quorum-takeover.md, W = D_inq + L + T_reset)
QUORUM_TAKEOVER_S=${QUORUM_TAKEOVER_S:-45}
QUORUM_LEASE_S=${QUORUM_LEASE_S:-3}
# the Workstation VM each nested ESXi host is (the vSphere lab on clyde)
ESX_VMX_vstest1=${ESX_VMX_vstest1:-/home/steve/vms/vmware/esxhost/esxhost.vmx}
ESX_VMX_vstest2=${ESX_VMX_vstest2:-/home/steve/vms/vmware/esxhost2/esxhost2.vmx}
OUT=${OUT:-$HERE/tests/evidence/vsphere/shared-$(date -u +%Y%m%dT%H%M%SZ)}
FAILS=0

die() { echo "vsphere_shared_fence: $*" >&2; exit 1; }
gssh() {  # <bound s> <vm> <cmd>
    local t=$1 n=$2; shift 2
    timeout "$t" "$SSH" "$n.vm.localdomain" "$@" 2>&1 | grep -avE '^Warning: Permanently|^Unauthorized access|^If you are not|^$'
}
ck() {  # <what> <got> <want>
    if [ "$2" = "$3" ]; then echo "  PASS $1"; else echo "  FAIL $1 (got '$2', want '$3')"; FAILS=$((FAILS + 1)); fi
}
addr() { getent hosts "$1.vm.localdomain" | awk '{print $1; exit}'; }
# The shared disk inside a guest, by the identity vSphere gives the VMDK
DEV_OF='for d in /sys/block/sd*; do [ "$(cat $d/device/wwid 2>/dev/null)" = "@WWID@" ] && { echo /dev/${d##*/}; exit 0; }; done; exit 1'
devof() { gssh 30 "$1" "${DEV_OF//@WWID@/$SHARED_WWID}" | tail -1; }
method_of() { gssh 20 "$1" "awk '\$2==\"$MNT\" && \$3==\"mxfs\" {print \$4}' /proc/mounts" | tr ',' '\n' | sed -n 's/^fence=//p'; }

mount_node() {  # <vm> <method> <fsid> [<bound s>]
    local vm=$1 f=$2 fsid=$3 bound=${4:-120} dev opts t0 out
    dev=$(devof "$vm"); case "$dev" in /dev/sd*) ;; *) die "$vm: no disk with wwid $SHARED_WWID";; esac
    opts="-o fence=$f,peers=$(addr "$VM1")/$(addr "$VM2")"
    t0=$(date +%s)
    out=$(gssh "$bound" "$vm" "MXFS_REPO=$NODE_REPO MXFS_DEV=$dev MXFS_FSID=$fsid MXFS_MOUNT='$MNT' MXFS_MOUNT_OPTS='$opts' $NODE_REPO/tests/setup/prep_node.sh tcp 2>&1; echo PREP_RC=\$?; dmesg | grep -a 'P-SHARED-ARM\|P-SHARED-CAS\|P305\|mxfs: .*REFUSED' | tail -6")
    echo "$out" > "$OUT/prep_node_$vm.txt"
    echo "$out" | grep -a 'NODE_PREP\|PREP_RC\|P-SHARED\|REFUSED' | sed "s/^/  [$vm] /"
    echo "  [$vm] mount wall $(( $(date +%s) - t0 )) s"
    echo "$out" | grep -aq '^NODE_PREP_OK' || return 1
}

cmd_up() {
    local f=$1 dev fsid t0 out
    case "$f" in manual|vcenter|quorum) ;; *) die "up <manual|vcenter|quorum>";; esac
    gssh 60 "$VM1" "timeout 30 umount $MNT 2>/dev/null; true" >/dev/null
    gssh 60 "$VM2" "timeout 30 umount $MNT 2>/dev/null; true" >/dev/null
    dev=$(devof "$VM1"); case "$dev" in /dev/sd*) ;; *) die "$VM1: no disk with wwid $SHARED_WWID";; esac
    t0=$(date +%s)
    out=$(gssh 120 "$VM1" "MXFS_REPO=$NODE_REPO MXFS_DEV=$dev $NODE_REPO/tests/setup/prep_fs.sh 2>&1 | tail -3; sh $NODE_REPO/tests/setup/dev_identity.sh $dev")
    echo "$out" > "$OUT/prep_fs.txt"
    echo "$out" | sed "s/^/  [$VM1] /"
    echo "  [$VM1] mkfs wall $(( $(date +%s) - t0 )) s"
    echo "$out" | grep -aq '^FS_PREP_OK' || die "format failed"
    fsid=$(echo "$out" | grep -ao ' fsid=[0-9a-f-]*' | head -1 | cut -d= -f2)
    [ -n "$fsid" ] || die "no fsid after format"
    mount_node "$VM1" "$f" "$fsid" || die "$VM1 did not mount"
    mount_node "$VM2" "$f" "$fsid" || die "$VM2 did not mount"
    echo "UP fence=$f fsid=$fsid"
}

cmd_rejoin() {
    local vm=$1 f fsid other st
    other=$VM1; [ "$vm" = "$VM1" ] && other=$VM2
    f=$(method_of "$other"); [ -n "$f" ] || die "$other is not mounted, so the method is unknown"
    st=$(gssh 20 "$vm" "echo alive")
    if [ "$st" != alive ]; then
        "$POWER" start "$vm" >/dev/null 2>&1
        local i; for i in $(seq 1 36); do [ "$(gssh 10 "$vm" 'test -d /src/mxfs && echo UP')" = UP ] && break; sleep 5; done
    fi
    fsid=$(gssh 20 "$other" "sh $NODE_REPO/tests/setup/dev_identity.sh \$(awk '\$2==\"$MNT\"{print \$1}' /proc/mounts)" | grep -ao ' fsid=[0-9a-f-]*' | cut -d= -f2)
    mount_node "$vm" "$f" "$fsid" || die "$vm did not rejoin"
    echo "REJOINED $vm fence=$f"
}

# One node's half of the load: own dir + the shared dir, every file fsynced
WORKER='
import hashlib, os, sys, time
mnt, me, n, kb = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
own = os.path.join(mnt, "work_" + me); sh = os.path.join(mnt, "work_shared")
t0 = time.monotonic()
for d in (own, sh):
    os.makedirs(d, exist_ok=True)
lat = {"own": [], "shared": []}
for i in range(n):
    for d, name, k in ((own, "f%04d" % i, "own"), (sh, "%s_%04d" % (me, i), "shared")):
        data = os.urandom(kb * 1024)
        p = os.path.join(d, name)
        a = time.monotonic()
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
        b = time.monotonic()
        os.write(fd, data); os.fsync(fd); os.close(fd)
        lat[k].append((b - a, time.monotonic() - b))
        print("OK %s %s" % (os.path.relpath(p, mnt), hashlib.md5(data).hexdigest()), flush=True)
for d in (own, sh):
    fd = os.open(d, os.O_RDONLY); os.fsync(fd); os.close(fd)
# where the time went: open+create and write+fsync+close, per directory kind
for k, v in lat.items():
    for j, what in ((0, "create"), (1, "fsync")):
        s = sorted(x[j] * 1000 for x in v)
        print("LAT %s %s n=%d sum_ms=%.0f p50_ms=%.2f p90_ms=%.2f p99_ms=%.2f max_ms=%.2f" % (k, what, len(s), sum(s), s[len(s) // 2], s[len(s) * 9 // 10], s[len(s) * 99 // 100], s[-1]), flush=True)
print("DONE wall_s=%.2f" % (time.monotonic() - t0), flush=True)
'
VERIFY='
import hashlib, os, sys
mnt, lst = sys.argv[1], sys.argv[2]
bad = miss = good = 0
for line in open(lst):
    f = line.split()
    if len(f) != 3 or f[0] != "OK":
        continue
    try:
        h = hashlib.md5(open(os.path.join(mnt, f[1]), "rb").read()).hexdigest()
    except OSError as e:
        miss += 1; print("MISSING %s %s" % (f[1], e)); continue
    if h == f[2]: good += 1
    else: bad += 1; print("MISMATCH %s want=%s got=%s" % (f[1], f[2], h))
print("VERIFY good=%d missing=%d mismatch=%d" % (good, miss, bad))
'

cmd_work() {
    local t0 p1 p2 w
    t0=$(date +%s)
    gssh 300 "$VM1" "python3 -c '$WORKER' $MNT $VM1 $WORK_N $WORK_KB" > "$OUT/work_$VM1.txt" & p1=$!
    gssh 300 "$VM2" "python3 -c '$WORKER' $MNT $VM2 $WORK_N $WORK_KB" > "$OUT/work_$VM2.txt" & p2=$!
    wait $p1; wait $p2
    w=$(( $(date +%s) - t0 ))
    echo "  write wall ${w}s ($((2 * WORK_N)) files of ${WORK_KB} KiB per node)"
    grep -ah '^LAT\|^DONE' "$OUT/work_$VM1.txt" | sed "s/^/  [$VM1] /"
    grep -ah '^LAT\|^DONE' "$OUT/work_$VM2.txt" | sed "s/^/  [$VM2] /"
    ck "$VM1 finished writing" "$(grep -ac '^DONE' "$OUT/work_$VM1.txt")" 1
    ck "$VM2 finished writing" "$(grep -ac '^DONE' "$OUT/work_$VM2.txt")" 1
    # each reads the other's (drop its page cache first, so the disk answers)
    local a b
    for a in "$VM1 $VM2" "$VM2 $VM1"; do
        set -- $a
        gssh 30 "$1" "cat > /root/vsf_list.txt" < "$OUT/work_$2.txt"
        gssh 300 "$1" "echo 3 > /proc/sys/vm/drop_caches; python3 -c '$VERIFY' $MNT /root/vsf_list.txt; ls $MNT/work_shared | wc -l" > "$OUT/verify_$1.txt"
        ck "$1 read every file $2 wrote with $2's content" "$(grep -ao 'VERIFY.*' "$OUT/verify_$1.txt")" "VERIFY good=$((2 * WORK_N)) missing=0 mismatch=0"
        ck "$1 lists the shared directory complete" "$(tail -1 "$OUT/verify_$1.txt")" "$((2 * WORK_N))"
    done
    echo "  total wall $(( $(date +%s) - t0 ))s"
}

# The native-XFS baseline for `work`: the same two workers' load (each
# WORK_N files of WORK_KB KiB into its own directory and WORK_N into a shared
# one, every file fsynced), run at once on VM1 against XFS on the same shared
# disk, both nodes' MeshXFS unmounted.  Leaves the disk formatted XFS: `up`
# formats it again.
cmd_baseline() {
    local dev t0 w
    gssh 60 "$VM1" "timeout 30 umount $MNT 2>/dev/null; true" >/dev/null
    gssh 60 "$VM2" "timeout 30 umount $MNT 2>/dev/null; true" >/dev/null
    dev=$(devof "$VM1"); case "$dev" in /dev/sd*) ;; *) die "$VM1: no disk with wwid $SHARED_WWID";; esac
    gssh 120 "$VM1" "sh $NODE_REPO/tests/setup/refuse_inuse_dev.sh $dev && mkfs.xfs -f -q $dev && mkdir -p /mnt/xfsbase && mount -t xfs $dev /mnt/xfsbase && echo XFS_UP" | grep -a 'XFS_UP\|refus' | sed 's/^/  /'
    t0=$(date +%s.%N)
    gssh 300 "$VM1" "python3 -c '$WORKER' /mnt/xfsbase a $WORK_N $WORK_KB > /root/xb_a.txt & python3 -c '$WORKER' /mnt/xfsbase b $WORK_N $WORK_KB > /root/xb_b.txt & wait; grep -h '^LAT\|^DONE' /root/xb_a.txt /root/xb_b.txt; umount /mnt/xfsbase" | sed 's/^/  /'
    w=$(echo "$(date +%s.%N) - $t0" | bc)
    echo "  native XFS write wall ${w}s (2 workers x $((2 * WORK_N)) files of ${WORK_KB} KiB, one node)"
}

# The reservation fence on the shared disk (docs/attachment-methods.md, `pass`
# on VMware): VM1 mounts it alone with fence=scsipr, on each lock transport.
# Behind VMware's virtual SCSI adapter the mount must be refused, the kernel
# saying why (P305-PR-HYPERVISOR-INITIATOR), and nothing left mounted.
cmd_refuse() {
    local dev t out mark
    gssh 60 "$VM1" "timeout 30 umount $MNT 2>/dev/null; true" >/dev/null
    gssh 60 "$VM2" "timeout 30 umount $MNT 2>/dev/null; true" >/dev/null
    dev=$(devof "$VM1"); case "$dev" in /dev/sd*) ;; *) die "$VM1: no disk with wwid $SHARED_WWID";; esac
    for t in tcp caw; do
        mark="VSF-REFUSE-$t-$(date +%s)"
        out=$(gssh 120 "$VM1" "echo '$mark' > /dev/kmsg; MXFS_REPO=$NODE_REPO MXFS_DEV=$dev MXFS_MOUNT='$MNT' $NODE_REPO/tests/setup/prep_node.sh $t 2>&1 | grep -a 'NODE_PREP'; dmesg | sed -n '/$mark/,\$p' | grep -a 'P305-PR-HYPERVISOR-INITIATOR' | cut -c1-160; echo MOUNTED=\$(grep -c ' $MNT mxfs' /proc/mounts)")
        echo "$out" > "$OUT/refuse_$t.txt"
        echo "$out" | sed "s/^/  [$VM1 $t] /"
        ck "fence=scsipr refused on the shared disk ($t)" "$(echo "$out" | grep -ac '^NODE_PREP_OK')" 0
        # logged where refused, and again by the mount's own failure report
        ck "the refusal names VMware's adapter ($t)" "$([ "$(echo "$out" | grep -ac 'P305-PR-HYPERVISOR-INITIATOR adapter=vmw_pvscsi')" -ge 1 ] && echo yes)" yes
        ck "nothing mounted ($t)" "$(echo "$out" | grep -ao 'MOUNTED=[0-9]*')" MOUNTED=0
    done
}

cmd_down() {
    local vm
    for vm in "$VM1" "$VM2"; do
        echo "  [$vm] $(gssh 60 "$vm" "timeout 45 umount $MNT; echo umount_rc=\$?")"
    done
}

cmd_chk() {
    local dev
    dev=$(devof "$VM1")
    gssh 300 "$VM1" "grep -q ' $MNT mxfs' /proc/mounts && echo STILL_MOUNTED; $NODE_REPO/tools/chk_mxfs -v $dev 2>&1 | tail -25; echo chk_rc=\${PIPESTATUS[0]}" | tee "$OUT/chk.txt"
    ck "chk_mxfs clean" "$(grep -ao 'chk_rc=[0-9]*' "$OUT/chk.txt")" "chk_rc=0"
}

cmd_kill() {
    local how=$1 S=${2:-$VM1} V=${3:-$VM2} f mark wpid t0 tk i log id
    f=$(method_of "$S"); [ -n "$f" ] || die "$S is not mounted"
    [ "$(method_of "$V")" = "$f" ] || die "$V is not mounted with fence=$f"
    mark="VSF-KILL-$how-$(date +%s)"
    gssh 10 "$S" "echo '$mark' > /dev/kmsg" >/dev/null
    echo "=== kill $how victim=$V survivor=$S fence=$f kill_after=${KILL_AFTER}s out=$OUT ==="
    gssh 30 "$V" "rm -rf $MNT/kill_$V; mkdir -p $MNT/kill_$V" >/dev/null
    # the victim's writer: one file at a time, file then directory fsynced
    # before its OK line; the lines received here are the ACKNOWLEDGED set
    timeout $((KILL_AFTER + 60)) "$SSH" "$V.vm.localdomain" "python3 -c '
import hashlib, os, sys
d = sys.argv[1]; dfd = os.open(d, os.O_RDONLY); i = 0
while True:
    data = os.urandom(65536); p = os.path.join(d, \"k%06d\" % i)
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    os.write(fd, data); os.fsync(fd); os.close(fd); os.fsync(dfd)
    print(\"OK %s %s\" % (os.path.relpath(p, sys.argv[2]), hashlib.md5(data).hexdigest()), flush=True); i += 1
' $MNT/kill_$V $MNT" > "$OUT/writer.txt" 2>/dev/null &
    wpid=$!
    sleep "$KILL_AFTER"
    if [ "$HOLD_MS" != 0 ]; then
        # the victim's next swap holds the lock inside its critical section;
        # its heartbeat swaps every ~2 s, so within 3 s one is holding it
        gssh 10 "$V" "echo $HOLD_MS > /sys/module/mxfs/parameters/dbg_drbd_cas_hold_ms; cat /sys/module/mxfs/parameters/dbg_drbd_cas_hold_ms" | sed 's/^/  hold armed: /'
        sleep 3
    fi
    t0=$(date +%s)
    case "$how" in
        poweroff) "$POWER" destroy "$V" > "$OUT/power.txt" 2>&1 ;;
        panic)    timeout 10 "$SSH" "$V.vm.localdomain" "echo 1 > /proc/sys/kernel/sysrq; echo c > /proc/sysrq-trigger" >/dev/null 2>&1 ;;
        *) die "kill <poweroff|panic>" ;;
    esac
    tk=$(date +%s)
    sleep 2; kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
    if [ "$HOLD_MS" != 0 ]; then
        # what the victim died holding: its lock register as the disk has it
        # (the swap area from the survivor's P-SHARED-CAS-ATTACH; register
        # sector = area + 1 + the victim's index), decoded per struct
        # mxfs_drbd_reg in pal/linux/drbd.c
        gssh 20 "$S" "a=\$(dmesg | grep -ao 'P-SHARED-CAS-ATTACH .*index=[01] .*area_lba=[0-9]*' | tail -1); i=\$(echo \"\$a\" | grep -o 'index=[01]' | cut -d= -f2); l=\$(echo \"\$a\" | grep -o 'area_lba=[0-9]*' | cut -d= -f2); d=\$(awk '\$2==\"$MNT\"{print \$1}' /proc/mounts); dd if=\$d bs=512 skip=\$((l + 1 + 1 - i)) count=1 iflag=direct 2>/dev/null | python3 -c '
import struct, sys
b = sys.stdin.buffer.read()
want, raised = struct.unpack_from(\"<I\", b, 40)[0], struct.unpack_from(\"<Q\", b, 48)[0]
n = struct.unpack_from(\"<H\", b, 136)[0]
r = [struct.unpack_from(\"<QH\", b, 138 + 10 * k) for k in range(min(n, 32))]
print(\"VICTIM_REG want=%d raised=%d nranges=%d ranges=%s\" % (want, raised, n, \" \".join(\"%d+%d\" % x for x in r)))
'" | tee "$OUT/victim_reg.txt" | sed 's/^/  /'
    fi
    echo "  acknowledged before the kill: $(grep -ac '^OK ' "$OUT/writer.txt") files"
    ck "the victim acknowledged writes before the kill" "$([ "$(grep -ac '^OK ' "$OUT/writer.txt")" -gt 0 ] && echo 1 || echo 0)" 1
    if [ "$f" = manual ]; then
        # the operator: wait for the request, make the machine's stop true, confirm
        for i in $(seq 1 $((RECOVERY_BOUND / 2))); do
            id=$(gssh 10 "$S" "dmesg | sed -n '/$mark/,\$p' | grep -ao 'P-FENCE-CONFIRM-NEEDED id=[0-9a-f]*' | tail -1 | cut -d= -f2")
            [ -n "$id" ] && break; sleep 2
        done
        ck "the survivor posted a confirmation request" "$([ -n "$id" ] && echo 1 || echo 0)" 1
        echo "  request posted $(( $(date +%s) - tk )) s after the kill: $(gssh 10 "$S" "cat /proc/fs/mxfs/fence_confirm" | tr '\n' '|')"
        [ "$how" = panic ] && "$POWER" destroy "$V" >> "$OUT/power.txt" 2>&1
        [ -n "$id" ] && gssh 10 "$S" "echo 'confirm $id' > /proc/fs/mxfs/fence_confirm; echo rc=\$?" | sed 's/^/  confirm /'
    fi
    for i in $(seq 1 $((RECOVERY_BOUND / 2))); do
        log=$(gssh 15 "$S" "dmesg | sed -n '/$mark/,\$p'")
        echo "$log" | grep -aq 'P163-RECOVERY-COMPLETE' && break
        [ $(( $(date +%s) - tk )) -ge "$RECOVERY_BOUND" ] && break
        sleep 2
    done
    echo "$log" > "$OUT/dmesg_survivor.txt"
    echo "  recovery wall $(( $(date +%s) - tk )) s after the kill (bound ${RECOVERY_BOUND}s)"
    echo "$log" | grep -a 'P238-SHARED\|SHARED-CAS\|foreign replay of\|P163-RECOVERY\|FENCE-CONFIRM\|Shutting down\|withdraw' | head -20 | sed 's/^/  | /'
    ck "death certificate (P238-SHARED-FENCE-ENDED fence=$f)" "$(echo "$log" | grep -ac "P238-SHARED-FENCE-ENDED .*fence=$f")" 1
    ck "the victim's slice replayed" "$(echo "$log" | grep -ac 'foreign replay of slot [0-9]* complete')" 1
    ck "P163-RECOVERY-COMPLETE" "$(echo "$log" | grep -ac 'P163-RECOVERY-COMPLETE')" 1
    ck "no shutdown on the survivor" "$(echo "$log" | grep -ac 'Shutting down filesystem')" 0
    # a panicked VM stays powered on under fence=quorum: nothing powers it off
    [ "$f" = quorum ] && [ "$how" = panic ] ||
    ck "the victim's VM is powered off" "$(timeout 30 govc vm.info -json "$(timeout 30 govc find / -type m -name "$V" | head -1)" | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtualMachines"][0]["runtime"]["powerState"])')" poweredOff
    gssh 30 "$S" "cat > /root/vsf_list.txt" < "$OUT/writer.txt"
    gssh 120 "$S" "python3 -c '$VERIFY' $MNT /root/vsf_list.txt" > "$OUT/verify_kill.txt"
    grep -a 'MISSING\|MISMATCH' "$OUT/verify_kill.txt" | head -5 | sed 's/^/  | /'
    ck "every acknowledged file reads back on $S" "$(grep -ao 'VERIFY.*' "$OUT/verify_kill.txt" | sed 's/good=[0-9]* //')" "VERIFY missing=0 mismatch=0"
    echo "  $(grep -ao 'VERIFY.*' "$OUT/verify_kill.txt")"
}

cmd_split() {
    local S=$VM1 V=$VM2 mark wpid tk tr b0 b1 b sb0 sb1 i log reset_s=-1
    [ "$(method_of "$S")" = quorum ] || die "$S is not mounted with fence=quorum"
    [ "$(method_of "$V")" = quorum ] || die "$V is not mounted with fence=quorum"
    mark="VSF-SPLIT-$(date +%s)"
    gssh 10 "$S" "echo '$mark' > /dev/kmsg" >/dev/null
    echo "=== split loser=$V survivor=$S out=$OUT ==="
    "$HERE/tools/node_kmsg_stream.sh" start "$V.vm.localdomain" "$OUT/kmsg_$V.txt" | sed 's/^/  /'
    # The reset follows its log line at once, so the ssh stream can lose the
    # race for it; netconsole sends from inside printk and does not.  clyde's
    # listener (tools/netconsole_listen.sh, port 6666) is the rig's and runs
    # on: only what it appends during this step is read.
    local nclog nc0
    nclog=$("$HERE/tools/netconsole_listen.sh" status 2>/dev/null | sed -n 's/.* log=\([^ ]*\).*/\1/p')
    [ -n "$nclog" ] || die "no netconsole listener on clyde: tools/netconsole_listen.sh start"
    nc0=$(stat -c %s "$nclog")
    gssh 15 "$V" "modprobe -r netconsole 2>/dev/null; modprobe netconsole netconsole=@/eth0,6666@192.168.120.1/ && echo NETCONSOLE_ON" | sed 's/^/  /'
    b0=$(gssh 10 "$V" "cat /proc/sys/kernel/random/boot_id")
    sb0=$(gssh 10 "$S" "cat /proc/sys/kernel/random/boot_id")
    gssh 10 "$V" "cat /proc/fs/mxfs/quorum" | sed 's/^/  [$V quorum] /'
    gssh 30 "$V" "rm -rf $MNT/split_$V; mkdir -p $MNT/split_$V" >/dev/null
    timeout $((KILL_AFTER + SPLIT_RESET_BOUND + 60)) "$SSH" "$V.vm.localdomain" "python3 -c '
import hashlib, os, sys
d = sys.argv[1]; dfd = os.open(d, os.O_RDONLY); i = 0
while True:
    data = os.urandom(65536); p = os.path.join(d, \"s%06d\" % i)
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    os.write(fd, data); os.fsync(fd); os.close(fd); os.fsync(dfd)
    print(\"OK %s %s\" % (os.path.relpath(p, sys.argv[2]), hashlib.md5(data).hexdigest()), flush=True); i += 1
' $MNT/split_$V $MNT" > "$OUT/writer.txt" 2>/dev/null &
    wpid=$!
    sleep "$KILL_AFTER"
    tk=$(date +%s)
    gssh 15 "$V" "nft add table inet vsfsplit && nft add chain inet vsfsplit in '{ type filter hook input priority -300; }' && nft add chain inet vsfsplit out '{ type filter hook output priority -300; }' && nft add rule inet vsfsplit in ip saddr $(addr "$S") drop && nft add rule inet vsfsplit out ip daddr $(addr "$S") drop && echo CUT" | sed 's/^/  [cut] /'
    # the loser's boot ends: its boot id changes (it answers again once booted)
    for i in $(seq 1 $(( (SPLIT_RESET_BOUND + 120) / 2 ))); do
        b=$(gssh 6 "$V" "cat /proc/sys/kernel/random/boot_id")
        if [ -z "$b" ] && [ "$reset_s" = -1 ]; then reset_s=$(( $(date +%s) - tk )); fi
        [ -n "$b" ] && [ "$b" != "$b0" ] && break
        sleep 2
    done
    b1=$b
    kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
    echo "  acknowledged before the loser's boot ended: $(grep -ac '^OK ' "$OUT/writer.txt") files"
    echo "  the loser stopped answering $reset_s s after the cut (bound ${SPLIT_RESET_BOUND}s + ssh's own detection)"
    tail -c +$((nc0 + 1)) "$nclog" | grep -a '192.168.120.181\|mxfs' > "$OUT/netconsole.log"
    grep -ah 'P-QUORUM' "$OUT/kmsg_$V.txt" "$OUT/netconsole.log" | tail -5 | cut -c1-260 | sed 's/^/  | /'
    ck "$V ended its own boot on losing the vote (P-QUORUM-LOST-RESET, kmsg stream or netconsole)" "$([ "$(cat "$OUT/kmsg_$V.txt" "$OUT/netconsole.log" 2>/dev/null | grep -ac 'P-QUORUM-LOST-RESET')" -ge 1 ] && echo yes)" yes
    ck "$V booted again" "$([ -n "$b1" ] && [ "$b1" != "$b0" ] && echo yes)" yes
    ck "$V stopped within the bound" "$([ "$reset_s" -ge 0 ] && [ "$reset_s" -le $((SPLIT_RESET_BOUND + 12)) ] && echo yes)" yes
    "$HERE/tools/node_kmsg_stream.sh" stop "$OUT/kmsg_$V.txt" >/dev/null 2>&1
    for i in $(seq 1 $((SPLIT_BOUND / 2))); do
        log=$(gssh 15 "$S" "dmesg | sed -n '/$mark/,\$p'")
        echo "$log" | grep -aq 'P163-RECOVERY-COMPLETE' && break
        [ $(( $(date +%s) - tk )) -ge "$SPLIT_BOUND" ] && break
        sleep 2
    done
    tr=$(( $(date +%s) - tk ))
    echo "$log" > "$OUT/dmesg_survivor.txt"
    gssh 10 "$S" "cat /proc/fs/mxfs/quorum" | tee "$OUT/quorum_survivor.txt" | sed "s/^/  [$S quorum] /"
    echo "  recovery wall $tr s after the cut (bound ${SPLIT_BOUND}s)"
    echo "$log" | grep -a 'P238-SHARED\|P-QUORUM\|foreign replay of\|P163-RECOVERY\|Shutting down\|withdraw' | head -20 | cut -c1-260 | sed 's/^/  | /'
    sb1=$(gssh 10 "$S" "cat /proc/sys/kernel/random/boot_id")
    ck "$S kept its boot" "$sb1" "$sb0"
    ck "death certificate (P238-SHARED-FENCE-ENDED fence=quorum)" "$(echo "$log" | grep -ac 'P238-SHARED-FENCE-ENDED .*fence=quorum')" 1
    ck "the loser's slice replayed" "$(echo "$log" | grep -ac 'foreign replay of slot [0-9]* complete')" 1
    ck "P163-RECOVERY-COMPLETE within ${SPLIT_BOUND}s" "$(echo "$log" | grep -ac 'P163-RECOVERY-COMPLETE')" 1
    ck "no shutdown on the survivor" "$(echo "$log" | grep -ac 'Shutting down filesystem')" 0
    gssh 30 "$S" "cat > /root/vsf_list.txt" < "$OUT/writer.txt"
    gssh 120 "$S" "python3 -c '$VERIFY' $MNT /root/vsf_list.txt" > "$OUT/verify_split.txt"
    grep -a 'MISSING\|MISMATCH' "$OUT/verify_split.txt" | head -5 | sed 's/^/  | /'
    ck "every file $V acknowledged reads back on $S" "$(grep -ao 'VERIFY.*' "$OUT/verify_split.txt" | sed 's/good=[0-9]* //')" "VERIFY missing=0 mismatch=0"
    echo "  $(grep -ao 'VERIFY.*' "$OUT/verify_split.txt")"
}

cmd_dinq() {
    local how=$1 n=$2 c out q worst=0 d bad=0 limit
    case "$how" in link) q= ;; isolate) q=$QNETD ;; *) die "dinq <link|isolate> <cycles>" ;; esac
    for vm in "$VM1" "$VM2"; do
        [ -z "$(method_of "$vm")" ] || die "$vm has MeshXFS mounted: a cut would reset it"
    done
    # what D_inq may use: the bound less the lease and the helper's 250 ms report
    limit=$(awk -v b="$QUORUM_TAKEOVER_S" -v l="$QUORUM_LEASE_S" 'BEGIN { printf "%.2f", b - l - 0.25 }')
    echo "=== dinq $how cycles=$n limit=${limit}s out=$OUT ==="
    for c in $(seq 1 "$n"); do
        # cut + up to 120 s inquorate wait + 60 s re-form, + ssh
        out=$(gssh 200 "$VM2" "bash /src/mxfs/tests/setup/quorum_dinq_probe.sh $(addr "$VM1") $q")
        echo "$out" | grep -a '^DINQ' | tee -a "$OUT/dinq_$how.txt" | sed "s/^/  [$c] /"
        d=$(echo "$out" | sed -n 's/^DINQ .* dinq=\([0-9.]*\) .*/\1/p')
        if [ -z "$d" ] || echo "$out" | grep -aq 'reform=NONE'; then bad=$((bad + 1)); continue; fi
        worst=$(awk -v a="$d" -v b="$worst" 'BEGIN { print (a > b) ? a : b }')
        # let the QDevice settle on the re-formed pair before the next cut
        sleep 3
    done
    echo "  worst D_inq ${worst}s over $n cycles ($how)"
    ck "every cycle measured and re-formed" "$bad" 0
    ck "worst D_inq + lease + report within the ${QUORUM_TAKEOVER_S}s takeover bound" "$(awk -v a="$worst" -v l="$limit" 'BEGIN { print (a <= l) ? "yes" : "no" }')" yes
}

# The vote denied to both (docs/quorum-takeover.md, test plan): both write,
# qnetd is dropped on both (the pair stays quorate: 2 of 3 votes), then the link
# between them.  Each holds 1 of 3 and must end its boot; neither may mint a
# death certificate for the other.  Both are then mounted again, VM1 first.
cmd_noquorum() {
    local vm b0_1 b0_2 b1 b2 i p1 p2 st t tk r1=-1 r2=-1 nclog nc0
    for vm in "$VM1" "$VM2"; do
        [ "$(method_of "$vm")" = quorum ] || die "$vm is not mounted with fence=quorum"
    done
    echo "=== noquorum out=$OUT ==="
    nclog=$("$HERE/tools/netconsole_listen.sh" status 2>/dev/null | sed -n 's/.* log=\([^ ]*\).*/\1/p')
    [ -n "$nclog" ] || die "no netconsole listener on clyde: tools/netconsole_listen.sh start"
    nc0=$(stat -c %s "$nclog")
    for vm in "$VM1" "$VM2"; do
        gssh 15 "$vm" "modprobe -r netconsole 2>/dev/null; modprobe netconsole netconsole=@/eth0,6666@192.168.120.1/ && echo NETCONSOLE_ON" | sed "s/^/  [$vm] /"
        gssh 30 "$vm" "rm -rf $MNT/nq_$vm; mkdir -p $MNT/nq_$vm" >/dev/null
    done
    b0_1=$(gssh 10 "$VM1" "cat /proc/sys/kernel/random/boot_id")
    b0_2=$(gssh 10 "$VM2" "cat /proc/sys/kernel/random/boot_id")
    for vm in "$VM1" "$VM2"; do
        timeout $((KILL_AFTER + SPLIT_RESET_BOUND + 90)) "$SSH" "$vm.vm.localdomain" "python3 -c '
import hashlib, os, sys
d = sys.argv[1]; dfd = os.open(d, os.O_RDONLY); i = 0
while True:
    data = os.urandom(65536); p = os.path.join(d, \"q%06d\" % i)
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    os.write(fd, data); os.fsync(fd); os.close(fd); os.fsync(dfd)
    print(\"OK %s %s\" % (os.path.relpath(p, sys.argv[2]), hashlib.md5(data).hexdigest()), flush=True); i += 1
' $MNT/nq_$vm $MNT" > "$OUT/writer_$vm.txt" 2>/dev/null &
        [ "$vm" = "$VM1" ] && p1=$! || p2=$!
    done
    sleep "$KILL_AFTER"
    for vm in "$VM1" "$VM2"; do
        gssh 15 "$vm" "nft add table inet vsfnq && nft add chain inet vsfnq in '{ type filter hook input priority -300; }' && nft add chain inet vsfnq out '{ type filter hook output priority -300; }' && nft add rule inet vsfnq in ip saddr $QNETD drop && nft add rule inet vsfnq out ip daddr $QNETD drop && echo QNETD_CUT" | sed "s/^/  [$vm] /"
    done
    # the pair is still 2 of 3 without the QDevice: neither may reset yet
    sleep 5
    ck "both still booted with qnetd cut but the link up" "$([ "$(gssh 10 "$VM1" "cat /proc/sys/kernel/random/boot_id")" = "$b0_1" ] && [ "$(gssh 10 "$VM2" "cat /proc/sys/kernel/random/boot_id")" = "$b0_2" ] && echo yes)" yes
    tk=$(date +%s)
    gssh 15 "$VM2" "nft add rule inet vsfnq in ip saddr $(addr "$VM1") drop && nft add rule inet vsfnq out ip daddr $(addr "$VM1") drop && echo LINK_CUT" | sed "s/^/  [$VM2] /"
    for i in $(seq 1 $(( (SPLIT_RESET_BOUND + 150) / 2 ))); do
        b1=$(gssh 6 "$VM1" "cat /proc/sys/kernel/random/boot_id")
        b2=$(gssh 6 "$VM2" "cat /proc/sys/kernel/random/boot_id")
        [ -z "$b1" ] && [ "$r1" = -1 ] && r1=$(( $(date +%s) - tk ))
        [ -z "$b2" ] && [ "$r2" = -1 ] && r2=$(( $(date +%s) - tk ))
        [ -n "$b1" ] && [ "$b1" != "$b0_1" ] && [ -n "$b2" ] && [ "$b2" != "$b0_2" ] && break
        sleep 2
    done
    kill "$p1" "$p2" 2>/dev/null; wait "$p1" "$p2" 2>/dev/null
    tail -c +$((nc0 + 1)) "$nclog" > "$OUT/netconsole.log"
    echo "  stopped answering after the link cut: $VM1 ${r1}s, $VM2 ${r2}s (bound ${SPLIT_RESET_BOUND}s + ssh's own detection)"
    grep -a 'P-QUORUM\|P238-SHARED\|foreign replay of' "$OUT/netconsole.log" | cut -c1-240 | sed 's/^/  | /'
    ck "both ended their boots on losing the vote (P-QUORUM-LOST-RESET x2 on netconsole)" "$([ "$(grep -ac 'P-QUORUM-LOST-RESET' "$OUT/netconsole.log")" -ge 2 ] && echo yes)" yes
    ck "neither minted a death certificate for the other" "$(grep -ac 'P238-SHARED-FENCE-ENDED' "$OUT/netconsole.log")" 0
    ck "$VM1 booted again" "$([ -n "$b1" ] && [ "$b1" != "$b0_1" ] && echo yes)" yes
    ck "$VM2 booted again" "$([ -n "$b2" ] && [ "$b2" != "$b0_2" ] && echo yes)" yes
    ck "$VM1 stopped within the bound" "$([ "$r1" -ge 0 ] && [ "$r1" -le $((SPLIT_RESET_BOUND + 12)) ] && echo yes)" yes
    ck "$VM2 stopped within the bound" "$([ "$r2" -ge 0 ] && [ "$r2" -le $((SPLIT_RESET_BOUND + 12)) ] && echo yes)" yes
    echo "  acknowledged: $VM1 $(grep -ac '^OK ' "$OUT/writer_$VM1.txt"), $VM2 $(grep -ac '^OK ' "$OUT/writer_$VM2.txt")"
    for vm in "$VM1" "$VM2"; do
        for i in $(seq 1 36); do [ "$(gssh 10 "$vm" 'test -d /src/mxfs && echo UP')" = UP ] && break; sleep 5; done
        for i in $(seq 1 30); do gssh 10 "$vm" "corosync-quorumtool -s" | grep -q '^Total votes: *3' && break; sleep 2; done
    done
    st=$(gssh 20 "$VM1" "sh $NODE_REPO/tests/setup/dev_identity.sh \$(for d in /sys/block/sd*; do [ \"\$(cat \$d/device/wwid 2>/dev/null)\" = $SHARED_WWID ] && echo /dev/\${d##*/}; done)" | grep -ao ' fsid=[0-9a-f-]*' | cut -d= -f2)
    mount_node "$VM1" quorum "$st" 170; ck "$VM1 mounted after both reset" "$?" 0
    mount_node "$VM2" quorum "$st"; ck "$VM2 mounted after both reset" "$?" 0
    for vm in "$VM1" "$VM2"; do
        gssh 30 "$VM1" "cat > /root/vsf_list.txt" < "$OUT/writer_$vm.txt"
        gssh 120 "$VM1" "python3 -c '$VERIFY' $MNT /root/vsf_list.txt" > "$OUT/verify_$vm.txt"
        ck "every file $vm acknowledged reads back" "$(grep -ao 'VERIFY.*' "$OUT/verify_$vm.txt" | sed 's/good=[0-9]* //')" "VERIFY missing=0 mismatch=0"
        echo "  $(grep -ao 'VERIFY.*' "$OUT/verify_$vm.txt")"
    done
}

# freeze: the victim's writer.  16 threads overwrite blocks of a preallocated
# file with O_DIRECT; each 4 KiB block carries MXFSQ, the boot id, thread,
# sequence and CLOCK_BOOTTIME ns.  Prints a count each second to its log.
FZWRITER='
import mmap, os, struct, sys, threading, time
p, nb = sys.argv[1], int(sys.argv[2]); T = 16
boot = open("/proc/sys/kernel/random/boot_id").read().strip().encode()
fd = os.open(p, os.O_WRONLY | os.O_DIRECT)
done = [0] * T
def run(t):
    buf = mmap.mmap(-1, 4096); s = 0
    while True:
        b = (t + T * s) % nb
        buf.seek(0); buf.write(b"MXFSQ" + boot + struct.pack("<IIQQ", t, b, s, time.clock_gettime_ns(time.CLOCK_BOOTTIME)))
        os.pwrite(fd, buf, b * 4096); s += 1; done[t] = s
for t in range(T):
    threading.Thread(target=run, args=(t,), daemon=True).start()
while True:
    time.sleep(1); print("W %d %d" % (time.clock_gettime_ns(time.CLOCK_BOOTTIME), sum(done)), flush=True)
'
# freeze: read the file O_DIRECT, one line per block: index and its stamp
FZREAD='
import mmap, os, struct, sys
p, nb = sys.argv[1], int(sys.argv[2])
fd = os.open(p, os.O_RDONLY | os.O_DIRECT); buf = mmap.mmap(-1, 1 << 20)
for o in range(0, nb, 256):
    n = os.preadv(fd, [buf], o * 4096) // 4096
    for k in range(n):
        b = buf[k * 4096:(k + 1) * 4096]
        if b[:5] == b"MXFSQ":
            t, i, s, ns = struct.unpack_from("<IIQQ", b, 41)
            print("%d %s %d %d %d" % (o + k, b[5:41].decode(), t, s, ns))
        else:
            print("%d -" % (o + k))
'

cmd_freeze() {
    local how=$1 S=$VM1 V=$VM2 mark nb=4096 f tf tr tb b0 b i log late nclog nc0 vmx
    case "$how" in guest|host) ;; *) die "freeze <guest|host>" ;; esac
    [ "$(method_of "$S")" = quorum ] || die "$S is not mounted with fence=quorum"
    [ "$(method_of "$V")" = quorum ] || die "$V is not mounted with fence=quorum"
    eval "vmx=\${ESX_VMX_$V:-}"
    [ "$how" = guest ] || [ -f "$vmx" ] || die "no Workstation VM for $V's ESXi host"
    f=$MNT/freeze_$V/blk
    mark="VSF-FREEZE-$how-$(date +%s)"
    echo "=== freeze $how victim=$V survivor=$S out=$OUT ==="
    nclog=$("$HERE/tools/netconsole_listen.sh" status 2>/dev/null | sed -n 's/.* log=\([^ ]*\).*/\1/p')
    [ -n "$nclog" ] || die "no netconsole listener on clyde: tools/netconsole_listen.sh start"
    nc0=$(stat -c %s "$nclog")
    gssh 15 "$V" "modprobe -r netconsole 2>/dev/null; modprobe netconsole netconsole=@/eth0,6666@192.168.120.1/ && echo NETCONSOLE_ON" | sed 's/^/  /'
    gssh 60 "$V" "rm -rf $MNT/freeze_$V; mkdir -p $MNT/freeze_$V && dd if=/dev/zero of=$f bs=1M count=$((nb / 256)) conv=fsync status=none && sync -f $f && echo PREALLOC_OK" | sed 's/^/  /'
    b0=$(gssh 10 "$V" "cat /proc/sys/kernel/random/boot_id")
    gssh 15 "$V" "nohup python3 -c '$FZWRITER' $f $nb > /root/fz_writer.log 2>&1 < /dev/null & echo WRITER_PID=\$!" | sed 's/^/  /'
    sleep "$KILL_AFTER"
    gssh 10 "$V" "tail -2 /root/fz_writer.log" | sed 's/^/  writer: /'
    gssh 10 "$S" "echo '$mark' > /dev/kmsg" >/dev/null
    tf=$(date +%s)
    case "$how" in
        guest) timeout 300 govc vm.power -suspend "$V" > "$OUT/freeze.txt" 2>&1 ;;
        host)  timeout 30 vmrun -T ws pause "$vmx" > "$OUT/freeze.txt" 2>&1 ;;
    esac
    echo "  frozen: rc=$? $(( $(date +%s) - tf )) s to freeze ($(tr '\n' ' ' < "$OUT/freeze.txt"))"
    for i in $(seq 1 $((SPLIT_BOUND / 2))); do
        log=$(gssh 15 "$S" "dmesg | sed -n '/$mark/,\$p'")
        echo "$log" | grep -aq 'P163-RECOVERY-COMPLETE' && break
        [ $(( $(date +%s) - tf )) -ge "$SPLIT_BOUND" ] && break
        sleep 2
    done
    tr=$(( $(date +%s) - tf ))
    echo "$log" > "$OUT/dmesg_survivor.txt"
    echo "  survivor recovery $tr s after the freeze (bound ${SPLIT_BOUND}s)"
    echo "$log" | grep -a 'P238-SHARED\|P-QUORUM\|foreign replay of\|P163-RECOVERY\|Shutting down' | head -12 | cut -c1-240 | sed 's/^/  | /'
    ck "death certificate (P238-SHARED-FENCE-ENDED fence=quorum)" "$(echo "$log" | grep -ac 'P238-SHARED-FENCE-ENDED .*fence=quorum')" 1
    ck "P163-RECOVERY-COMPLETE within ${SPLIT_BOUND}s" "$(echo "$log" | grep -ac 'P163-RECOVERY-COMPLETE')" 1
    gssh 120 "$S" "python3 -c '$FZREAD' $f $nb" > "$OUT/snap_a.txt"
    echo "  snapshot A: $(wc -l < "$OUT/snap_a.txt") blocks, $(grep -c ' - *$\| -$' "$OUT/snap_a.txt") unstamped, frozen $(( $(date +%s) - tf )) s"
    tb=$(date +%s)
    case "$how" in
        guest) timeout 300 govc vm.power -on "$V" > "$OUT/resume.txt" 2>&1 ;;
        host)  timeout 30 vmrun -T ws unpause "$vmx" > "$OUT/resume.txt" 2>&1 ;;
    esac
    echo "  resumed: rc=$? after $(( $(date +%s) - tb )) s"
    # the victim's boot ends (it answers again once booted); then 10 s for
    # anything ESXi still retries on its behalf
    for i in $(seq 1 $(( (SPLIT_RESET_BOUND + 150) / 2 ))); do
        b=$(gssh 6 "$V" "cat /proc/sys/kernel/random/boot_id")
        [ -n "$b" ] && [ "$b" != "$b0" ] && break
        sleep 2
    done
    echo "  victim booted again $(( $(date +%s) - tb )) s after resume"
    sleep 10
    gssh 120 "$S" "python3 -c '$FZREAD' $f $nb" > "$OUT/snap_b.txt"
    tail -c +$((nc0 + 1)) "$nclog" > "$OUT/netconsole.log"
    grep -a 'P-QUORUM' "$OUT/netconsole.log" | cut -c1-240 | sed 's/^/  | /'
    ck "$V booted again" "$([ -n "$b" ] && [ "$b" != "$b0" ] && echo yes)" yes
    ck "snapshot A read every block" "$(wc -l < "$OUT/snap_a.txt")" "$nb"
    ck "snapshot B read every block" "$(wc -l < "$OUT/snap_b.txt")" "$nb"
    diff "$OUT/snap_a.txt" "$OUT/snap_b.txt" | grep '^>' > "$OUT/late_writes.txt"
    late=$(wc -l < "$OUT/late_writes.txt")
    head -5 "$OUT/late_writes.txt" | sed 's/^/  late: /'
    ck "no write of $V's landed after the takeover" "$late" 0
    ck "$S kept running (no shutdown)" "$(gssh 15 "$S" "dmesg | sed -n '/$mark/,\$p' | grep -ac 'Shutting down filesystem'")" 0
}

# A whole-cluster restart (docs/whole-cluster-restart.md): both nodes write
# fsync-acknowledged files, both VMs are powered off at once, both are powered
# on, VM1 mounts alone and only then VM2.  Asserts that VM2 is still powered
# on when VM1's mount has finished (its earlier boot ended by the power cycle,
# not by a power-off from VM1), that both mount, and that every acknowledged
# file of both reads back.
cmd_restart() {
    local f vm i p1 p2 st
    f=$(method_of "$VM1"); [ -n "$f" ] || die "$VM1 is not mounted"
    echo "=== restart fence=$f out=$OUT ==="
    for vm in "$VM1" "$VM2"; do
        gssh 30 "$vm" "rm -rf $MNT/rs_$vm; mkdir -p $MNT/rs_$vm" >/dev/null
        timeout $((KILL_AFTER + 60)) "$SSH" "$vm.vm.localdomain" "python3 -c '
import hashlib, os, sys
d = sys.argv[1]; dfd = os.open(d, os.O_RDONLY); i = 0
while True:
    data = os.urandom(65536); p = os.path.join(d, \"r%06d\" % i)
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    os.write(fd, data); os.fsync(fd); os.close(fd); os.fsync(dfd)
    print(\"OK %s %s\" % (os.path.relpath(p, sys.argv[2]), hashlib.md5(data).hexdigest()), flush=True); i += 1
' $MNT/rs_$vm $MNT" > "$OUT/writer_$vm.txt" 2>/dev/null &
        [ "$vm" = "$VM1" ] && p1=$! || p2=$!
    done
    sleep "$KILL_AFTER"
    local d1 d2
    "$POWER" destroy "$VM1" > "$OUT/power_$VM1.txt" 2>&1 & d1=$!
    "$POWER" destroy "$VM2" > "$OUT/power_$VM2.txt" 2>&1 & d2=$!
    wait "$d1" "$d2"
    sleep 2; kill "$p1" "$p2" 2>/dev/null; wait "$p1" "$p2" 2>/dev/null
    echo "  acknowledged: $VM1 $(grep -ac '^OK ' "$OUT/writer_$VM1.txt"), $VM2 $(grep -ac '^OK ' "$OUT/writer_$VM2.txt")"
    for vm in "$VM1" "$VM2"; do "$POWER" start "$vm" >/dev/null 2>&1; done
    for vm in "$VM1" "$VM2"; do
        for i in $(seq 1 36); do [ "$(gssh 10 "$vm" 'test -d /src/mxfs && echo UP')" = UP ] && break; sleep 5; done
    done
    st=$(gssh 20 "$VM1" "sh $NODE_REPO/tests/setup/dev_identity.sh \$(for d in /sys/block/sd*; do [ \"\$(cat \$d/device/wwid 2>/dev/null)\" = $SHARED_WWID ] && echo /dev/\${d##*/}; done)" | grep -ao ' fsid=[0-9a-f-]*' | cut -d= -f2)
    # alone after a total outage: two frozen-table windows (64 s each,
    # measured), two slice replays (~7 s each) and prep + arm (~9 s)
    mount_node "$VM1" "$f" "$st" 170; ck "$VM1 mounted alone after the outage" "$?" 0
    gssh 20 "$VM1" "dmesg | grep -a 'P-BOOT-TAKEOVER\|P238-SHARED\|P-FENCEH-REPORT\|P163-RECOVERY-COMPLETE\|foreign replay of' | cut -c1-260" | tee "$OUT/dmesg_vm1_takeover.txt" | sed 's/^/  | /' | head -20
    ck "$VM2 still powered on after $VM1 mounted (no power-off of a VM already restarted)" "$(timeout 30 govc vm.info -json "$(timeout 30 govc find / -type m -name "$VM2" | head -1)" | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtualMachines"][0]["runtime"]["powerState"])')" poweredOn
    if [ "$(gssh 10 "$VM2" 'echo alive')" != alive ]; then
        "$POWER" start "$VM2" >/dev/null 2>&1
        for i in $(seq 1 36); do [ "$(gssh 10 "$VM2" 'test -d /src/mxfs && echo UP')" = UP ] && break; sleep 5; done
    fi
    mount_node "$VM2" "$f" "$st"; ck "$VM2 mounted" "$?" 0
    for vm in "$VM1" "$VM2"; do
        gssh 30 "$VM1" "cat > /root/vsf_list.txt" < "$OUT/writer_$vm.txt"
        gssh 120 "$VM1" "python3 -c '$VERIFY' $MNT /root/vsf_list.txt" > "$OUT/verify_$vm.txt"
        ck "every file $vm acknowledged reads back" "$(grep -ao 'VERIFY.*' "$OUT/verify_$vm.txt" | sed 's/good=[0-9]* //')" "VERIFY missing=0 mismatch=0"
        echo "  $(grep -ao 'VERIFY.*' "$OUT/verify_$vm.txt")"
    done
}

. "$HERE/scripts/vsphere_env.sh" lab >/dev/null 2>&1 || die "no vCenter credentials"
export GOVC_INSECURE=1
mkdir -p "$OUT"
op=${1:-}; shift || true
case "$op" in
    up)     [ $# -ge 1 ] || die "up <manual|vcenter|quorum>"; cmd_up "$1" ;;
    work)   cmd_work ;;
    down)   cmd_down ;;
    chk)    cmd_chk ;;
    kill)   [ $# -ge 1 ] || die "kill <poweroff|panic>"; cmd_kill "$@" ;;
    rejoin) [ $# -ge 1 ] || die "rejoin <vm>"; cmd_rejoin "$1" ;;
    restart) cmd_restart ;;
    baseline) cmd_baseline ;;
    refuse) cmd_refuse ;;
    split)  cmd_split ;;
    dinq)   [ $# -ge 2 ] || die "dinq <link|isolate> <cycles>"; cmd_dinq "$1" "$2" ;;
    noquorum) cmd_noquorum ;;
    freeze) [ $# -ge 1 ] || die "freeze <guest|host>"; cmd_freeze "$1" ;;
    *) sed -n '7,19p' "$0" >&2; exit 2 ;;
esac
echo "RESULT $op fails=$FAILS evidence=$OUT"
[ "$FAILS" = 0 ]
