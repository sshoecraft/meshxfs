#!/bin/bash
# pve_storage_ops.sh — what a Proxmox administrator does with a shared
# datastore, done on the MXFS one across the hosts of a cluster, each step
# checked against what the guest itself fsynced.
#
# Live migration (tests/pve_live_migrate.sh) and HA failover
# (tests/pve_ha_failover.sh) cover a guest moving.  This covers the guest's
# disk being operated on: qcow2 images with internal snapshots written while
# the guest runs, a RAM snapshot's state file, rollback, an online resize, a
# live backup and its restore on another host, an online move of the disk off
# the datastore and back, a template with a linked clone booted on another
# host, and a container whose root filesystem is an image on the datastore.
# Every one of them is QEMU, qemu-img, vzdump or pct reading and writing
# files on MXFS from one host while another host may read them next.
#
# What it does (A, B, C are the first three hosts; with two hosts C is A):
#   1. A full clone of SRC_VMID onto SHARED as qcow2 (VMID), started on A.  In
#      the guest a writer (as in pve_live_migrate.sh: files from /dev/urandom,
#      each fsynced, its sha256 recorded beside it after the fsync) runs.
#   2. A live disk snapshot (snap1) between two marker files: `pre` written
#      and synced before it, `post` after.  Then a live snapshot with the
#      guest's RAM (snap2, its state file on SHARED).
#   3. Online migration A -> B with both snapshots in the image.
#   4. On B: rollback to snap2 (the guest resumes from its saved RAM), files
#      verified; rollback to snap1 (the guest is stopped), started: `pre`
#      must exist, `post` must not, every recorded file must verify.  Both
#      snapshots deleted.
#   5. Online resize (+1 GiB): the guest must see the new size.
#   6. A live backup (vzdump, snapshot mode, zstd) to SHARED with the writer
#      running.  The archive must hash the same on every host.  Restored on C
#      as RVMID (new MAC).  Booted at the end of step 7, once VMID is stopped
#      (a restored disk keeps the guest's machine-id and so its DHCP lease):
#      every file the backup's image recorded must verify (it is a
#      crash-consistent image, as after a power cut).
#   7. The disk of VMID moved online to LOCAL and back to SHARED; files
#      verified after each move.  VMID stopped; `qemu-img check` of its image
#      on C must find no errors.
#   8. A template (TVMID, a qcow2 full clone of SRC_VMID), a linked clone of
#      it (LVMID) moved to C and booted there, a file written and verified;
#      the template's base image must hash the same before and after, on B.
#   9. A container (CTID) from an Alpine template downloaded to SHARED, its
#      root filesystem an image on SHARED, started on A, files written; a
#      restart migration to B; the files verified there.
#  10. Every host's kernel log since the start searched for I/O errors, hung
#      tasks, warnings, withdrawals and shutdowns; every guest and container
#      created removed, the backup archives this run made deleted, and the
#      storage's content types put back as they were.
#
# Budgets are derived at the start from the LUN's measured sequential read
# rate R on host A (dd, direct I/O, 1 GiB): moving X bytes through MXFS is
# allowed 2*X/R plus a fixed per-command overhead (Proxmox's own setup,
# measured at 4-5 s for a clone and a migration on these hosts), and a boot
# is BOOT_BUDGET (the guest's measured 62 s boot, twice that).
#
# Usage: tests/pve_storage_ops.sh
# Env:
#   PVE_HOSTS   "<addr> ..." (required, two or more)
#   SRC_VMID (9000)  VMID (9300)  RVMID (9301)  TVMID (9302)  LVMID (9303)
#   CTID (9304)  SHARED (mxfssan)  LOCAL (local-lvm)  MNT (/mnt/mxfssan)
#   SAN_DEV     the LUN's device on the hosts (default the pve9 multipath map)
#   CT_TEMPLATE the container template to download (default the newest amd64
#               Alpine: the catalogue also lists arm64 builds, whose init cannot
#               run here)
#   WRITE_MB (16)  MAXF (16)  SETTLE_S (15)  BOOT_BUDGET (130)  OVERHEAD_S (15)
#   KEEP=1      leave the guests and archives in place
# Evidence: tests/evidence/pve_storage_ops/<UTC stamp>/
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSHP="$REPO/tools/mxfs_sshpass.sh"
read -r -a HOSTS <<<"${PVE_HOSTS:?PVE_HOSTS must name two or more hosts}"
[ "${#HOSTS[@]}" -ge 2 ] || { echo "pve_storage_ops: two or more hosts are needed"; exit 2; }
SRC_VMID=${SRC_VMID:-9000}; VMID=${VMID:-9300}; RVMID=${RVMID:-9301}
TVMID=${TVMID:-9302}; LVMID=${LVMID:-9303}; CTID=${CTID:-9304}
SHARED=${SHARED:-mxfssan}; LOCAL=${LOCAL:-local-lvm}; MNT=${MNT:-/mnt/mxfssan}
SAN_DEV=${SAN_DEV:-/dev/disk/by-id/dm-uuid-mpath-23335366365663866}
CT_TEMPLATE=${CT_TEMPLATE:-}
WRITE_MB=${WRITE_MB:-16}; MAXF=${MAXF:-16}; SETTLE_S=${SETTLE_S:-15}
BOOT_BUDGET=${BOOT_BUDGET:-130}; OVERHEAD_S=${OVERHEAD_S:-15}
CPU=${CPU:-x86-64-v2}
TAG="mxfs storage-ops test guest (tests/pve_storage_ops.sh)"
EVID=${EVID:-$REPO/tests/evidence/pve_storage_ops/$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$EVID" || exit 1
LOG=$EVID/log
BAD='I/O error|blocked for more than|WARNING:|BUG:|Oops|Shutting down filesystem|P-WITHDRAW|RECOVERY_BLOCKED|self-fenc|corrupt|Call Trace'
bad=0

on() {  # <host> <cmd> [timeout]
    timeout "${3:-60}" "$SSHP" "$1" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$'
    return "${PIPESTATUS[0]}"
}
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
fail() { say "FAIL: $*"; bad=1; }
# a timed command on a host: <label> <host> <budget> <cmd> <ok-pattern>
# Its output goes to $EVID/<label>.txt; a miss of the pattern, a nonzero rc or
# an overrun is a FAIL, and the return code says whether it succeeded.
timed() {
    local label=$1 h=$2 b=$3 cmd=$4 pat=$5 t rc wall
    t=$(date +%s%N)
    on "$h" "$cmd" "$b" > "$EVID/$label.txt" 2>&1
    rc=$?
    wall=$(( ($(date +%s%N) - t) / 1000000 ))
    say "  $label: rc=$rc wall=${wall}ms budget=${b}s"
    if [ "$rc" != 0 ] || ! grep -aqE "$pat" "$EVID/$label.txt"; then
        fail "$label failed (rc=$rc): $(tail -3 "$EVID/$label.txt" | tr '\n' ' ' | cut -c1-400)"
        return 1
    fi
    [ "$wall" -le $(( b * 1000 )) ] || { fail "$label took ${wall}ms, over its ${b}s budget"; return 1; }
    return 0
}

declare -A ADDR
NODES=()
for h in "${HOSTS[@]}"; do
    n=$(on "$h" "hostname" 20 | tail -1)
    [ -n "$n" ] || { say "FAIL: $h did not answer"; exit 1; }
    ADDR[$n]=$h; NODES+=("$n")
done
NA=${NODES[0]}; NB=${NODES[1]}; NC=${NODES[2]:-${NODES[0]}}
A=${ADDR[$NA]}; B=${ADDR[$NB]}; C=${ADDR[$NC]}

node_of() {  # <vmid>: the node its config is on, or empty
    on "$A" "pvesh get /cluster/resources --type vm --output-format json" 30 |
        python3 -I -c 'import json,sys; v=[r for r in json.load(sys.stdin) if r.get("vmid")==int(sys.argv[1])]; print(v[0]["node"] if v else "")' "$1"
}
guest_ip() {  # <host> <vmid>: the guest's first non-loopback IPv4 address
    on "$1" "qm agent $2 network-get-interfaces" 30 |
        python3 -I -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
for i in d:
    if i.get("name") == "lo":
        continue
    for a in i.get("ip-addresses", []):
        if a.get("ip-address-type") == "ipv4":
            print(a["ip-address"]); sys.exit(0)
sys.exit(1)'
}
# Boot wait: <host> <vmid> -> prints the guest's address once its agent and
# ssh answer, within BOOT_BUDGET of the call.
boot_wait() {
    local h=$1 v=$2 t ip=
    t=$(date +%s)
    until on "$h" "qm agent $v ping && echo PONG" 20 | grep -q PONG; do
        [ $(( $(date +%s) - t )) -lt "$BOOT_BUDGET" ] || return 1
        sleep 3
    done
    until ip=$(guest_ip "$h" "$v") && [ -n "$ip" ] && on "$ip" true 20; do
        [ $(( $(date +%s) - t )) -lt "$BOOT_BUDGET" ] || return 1
        sleep 3
    done
    echo "$ip $(( $(date +%s) - t ))"
}
WRITER='mkdir -p /root/mig && cd /root/mig && rm -f stop stopped pause paused f*.tmp && n=0
while [ ! -e stop ]; do
  if [ -e pause ]; then : > paused; sleep 0.2; continue; fi
  rm -f paused
  n=$((n+1)); i=$(( (n-1) % '"$MAXF"' + 1 ))
  rm -f f$i.sha
  dd if=/dev/urandom of=f$i bs=1M count='"$WRITE_MB"' conv=fsync status=none || { echo "write f$i failed" >> errors; sleep 1; continue; }
  sha256sum f$i > f$i.sha.tmp && sync f$i.sha.tmp && mv f$i.sha.tmp f$i.sha && sync
  echo "$n $(date +%s)" > count
done
: > stopped'
writer_start() {  # <guest ip>
    on "$1" "printf '%s\n' $(printf '%q' "$WRITER") > /root/mig-writer.sh && setsid nohup bash /root/mig-writer.sh > /root/mig-writer.out 2>&1 < /dev/null & echo WRITER_STARTED" 30 | grep -q WRITER_STARTED
}
# Every file the guest recorded a sum for must verify, read from the disk.
# <guest ip> <label> [running: pause the writer around the check]
verify() {
    local ip=$1 label=$2 out rc
    if [ "${3:-}" = running ]; then
        on "$ip" 'cd /root/mig && touch pause; for k in $(seq 1 600); do [ -e paused ] && break; sleep 0.2; done; [ -e paused ]' 150 > /dev/null ||
            { fail "$label: the writer did not pause"; return 1; }
    fi
    out=$(on "$ip" 'cd /root/mig && sync && echo 3 > /proc/sys/vm/drop_caches && n=$(ls f*.sha 2>/dev/null | wc -l) && res=$(cat f*.sha | sha256sum -c 2>&1); ok=$(grep -c ": OK$" <<<"$res"); bad=$(grep -v ": OK$" <<<"$res"); echo "files=$n ok=$ok count=$(cat count 2>/dev/null) errors=$(cat errors 2>/dev/null | wc -l)"; [ -z "$bad" ] || echo "BAD: $bad"; [ "$n" -gt 0 ] && [ "$n" = "$ok" ] && [ -z "$bad" ]' 300)
    rc=$?
    say "  $label verify: $(echo "$out" | head -4 | tr '\n' ' ')"
    [ "${3:-}" = running ] && on "$ip" 'rm -f /root/mig/pause' 30 > /dev/null
    [ "$rc" = 0 ] || { fail "$label: the guest's files did not all verify (rc=$rc)"; return 1; }
}

# 0. every host holds the volume and the storage is active on it
for n in "${NODES[@]}"; do
    h=${ADDR[$n]}
    on "$h" "grep -q ' $MNT mxfs ' /proc/mounts && pvesm status --storage $SHARED | grep -q ' active ' && echo WHOLE" 30 | grep -q WHOLE ||
        { say "FAIL: $n does not hold $MNT with storage $SHARED active; not starting"; exit 1; }
    on "$h" "date +%s" 20 > "$EVID/t0-$n"
    say "$n ($h): build $(on "$h" "cat /sys/module/mxfs/version /sys/module/mxfs/srcversion" 20 | tr '\n' ' ')"
done
CONTENT=$(on "$A" "pvesh get /storage/$SHARED --output-format json" 30 | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["content"])')
[ -n "$CONTENT" ] || { say "FAIL: storage $SHARED has no readable content list"; exit 1; }
say "storage $SHARED content was: $CONTENT"

# Leftovers of an earlier run of this script, and only those.
for v in $VMID $RVMID $LVMID $TVMID; do
    n=$(node_of "$v")
    [ -n "$n" ] || continue
    desc=$(on "${ADDR[$n]}" "qm config $v | sed -n 's/^description: //p'" 30)
    [[ "$desc" == *"pve_storage_ops"* ]] || { say "FAIL: VM $v exists and was not made by this script ($desc); not touching it"; exit 1; }
    say "VM $v left by an earlier run on $n: destroying it"
    on "${ADDR[$n]}" "qm stop $v --skiplock 1 >/dev/null 2>&1; qm destroy $v --purge 1 --destroy-unreferenced-disks 1" 300 | tail -1 | tee -a "$LOG"
done
n=$(node_of "$CTID")
if [ -n "$n" ]; then
    desc=$(on "${ADDR[$n]}" "pct config $CTID | sed -n 's/^description: //p'" 30)
    [[ "$desc" == *"pve_storage_ops"* ]] || { say "FAIL: CT $CTID exists and was not made by this script ($desc); not touching it"; exit 1; }
    on "${ADDR[$n]}" "pct stop $CTID >/dev/null 2>&1; pct destroy $CTID --purge 1" 120 | tail -1 | tee -a "$LOG"
fi

cleanup() {
    local v n
    if [ "${KEEP:-0}" = 1 ]; then say "KEEP=1: leaving the guests and archives"; else
        for v in $VMID $RVMID $LVMID $TVMID; do
            n=$(node_of "$v"); [ -n "$n" ] || continue
            on "${ADDR[$n]}" "qm stop $v --skiplock 1 >/dev/null 2>&1; qm destroy $v --purge 1 --destroy-unreferenced-disks 1 >/dev/null 2>&1; echo DESTROY_RC=\$?" 300 | tail -1 | sed "s/^/VM $v on $n: /" | tee -a "$LOG"
        done
        n=$(node_of "$CTID")
        [ -n "$n" ] && on "${ADDR[$n]}" "pct stop $CTID >/dev/null 2>&1; pct destroy $CTID --purge 1 >/dev/null 2>&1; echo DESTROY_RC=\$?" 120 | tail -1 | sed "s/^/CT $CTID on $n: /" | tee -a "$LOG"
        on "$A" "rm -f $MNT/dump/vzdump-qemu-$VMID-* && echo ARCHIVES_REMOVED" 60 | tail -1 | tee -a "$LOG"
    fi
    on "$A" "pvesm set $SHARED --content $CONTENT && echo CONTENT_RESTORED $CONTENT" 30 | tail -1 | tee -a "$LOG"
}
trap cleanup EXIT
timed content "$A" 30 "pvesm set $SHARED --content images,rootdir,backup,vztmpl,iso && pvesm status --storage $SHARED" ' active ' || exit 1

# Budgets from the LUN's own read rate.
r=$(on "$A" "s=\$(date +%s%N); dd if=$SAN_DEV of=/dev/null bs=4M count=256 iflag=direct status=none && echo RATE \$(( 1073741824 * 1000000 / ((\$(date +%s%N) - s) / 1000) ))" 120 | sed -n 's/^RATE //p')
[ -n "$r" ] && [ "$r" -gt 0 ] || { fail "the LUN's read rate could not be measured"; exit 1; }
say "LUN read rate on $NA: $(( r / 1048576 )) MiB/s"
mv_budget() {  # <bytes> -> seconds: twice the time to read them at the LUN's rate, plus the fixed overhead
    echo $(( 2 * $1 / r + OVERHEAD_S ))
}

# 1. the qcow2 clone, booted on A, with its writer
src=$(node_of "$SRC_VMID")
[ -n "$src" ] && [ -n "${ADDR[$src]:-}" ] || { fail "source VM $SRC_VMID is on no host given"; exit 1; }
on "${ADDR[$src]}" "qm status $SRC_VMID" 20 | grep -q 'status: stopped' || { fail "source VM $SRC_VMID is not stopped"; exit 1; }
used=$(on "${ADDR[$src]}" "du -B1 \$(pvesm path \$(qm config $SRC_VMID | sed -n 's/^virtio0: \([^,]*\).*/\1/p')) | cut -f1" 30)
# a source whose disk is gone (the volume was formatted again under its
# config) answers du with an error, not a number
[[ "$used" =~ ^[0-9]+$ ]] || { fail "source VM $SRC_VMID's disk could not be sized (${used:-no answer}): rebuild it with scripts/pve_cloud_guest.sh"; exit 1; }
say "source image allocated: $(( used / 1048576 )) MiB"
# a clone made on another node than the source's needs --target
TGT=; [ "$src" = "$NA" ] || TGT="--target $NA"
CB=$(mv_budget $(( used * 2 )))
timed clone "${ADDR[$src]}" "$CB" "qm clone $SRC_VMID $VMID --full 1 --storage $SHARED --format qcow2 --name mxfs-ops $TGT && qm set $VMID --description '$TAG' --onboot 0 --cpu $CPU >/dev/null && echo CLONED" CLONED || exit 1
on "$A" "qm config $VMID | grep -E '^virtio0:'" 20 | tee -a "$LOG"
on "$A" "qm start $VMID" 120 >> "$LOG"
bw=$(boot_wait "$A" "$VMID") || { fail "VM $VMID did not boot on $NA within ${BOOT_BUDGET}s"; exit 1; }
GIP=${bw% *}; say "guest $VMID up on $NA after ${bw#* }s at $GIP"
writer_start "$GIP" || { fail "the writer did not start"; exit 1; }
sleep "$SETTLE_S"
verify "$GIP" "after the clone" running || exit 1

# 2. live snapshots, between two markers
on "$GIP" 'echo pre > /root/pre && sync && echo PRE_OK' 30 | grep -q PRE_OK || fail "marker pre not written"
timed snap1 "$A" 60 "qm snapshot $VMID snap1 --description 'disk only, writer running' && echo SNAP_OK" SNAP_OK
on "$GIP" 'echo post > /root/post && sync && echo POST_OK' 30 | grep -q POST_OK || fail "marker post not written"
sleep "$SETTLE_S"
# the RAM state: the guest's 1 GiB of memory written to a file on SHARED
timed snap2 "$A" "$(mv_budget 1073741824)" "qm snapshot $VMID snap2 --vmstate 1 --description 'with RAM' && echo SNAP_OK" SNAP_OK
on "$A" "qm config $VMID --snapshot snap2 | grep -E '^vmstate:' && ls -l $MNT/images/$VMID/" 30 | tee -a "$LOG"
on "$A" "qm config $VMID --snapshot snap2" 30 | grep -q "^vmstate: $SHARED:" || fail "snap2 has no vmstate on $SHARED"
verify "$GIP" "after both snapshots" running

# 3. online migration with the snapshots in the image
timed migrate "$A" "$(mv_budget 1073741824)" "qm migrate $VMID $NB --online 1" 'migration finished successfully' || exit 1
[ "$(node_of "$VMID")" = "$NB" ] || { fail "VM $VMID is not on $NB after the migration"; exit 1; }
verify "$GIP" "on $NB after the migration" running

# 4. rollbacks on B
timed rollback2 "$B" "$(mv_budget 1073741824)" "qm rollback $VMID snap2 && qm status $VMID" 'status: running'
on "$B" "qm agent $VMID ping && echo PONG" 30 | grep -q PONG || fail "the guest's agent does not answer after the RAM rollback"
on "$GIP" 'test -e /root/post && echo POST_PRESENT' 30 | grep -q POST_PRESENT || fail "after the rollback to snap2 the marker post written before it is missing"
verify "$GIP" "after the rollback to snap2 (RAM)" running
timed rollback1 "$B" 120 "qm rollback $VMID snap1 && qm status $VMID" 'status: stopped'
on "$B" "qm start $VMID" 120 >> "$LOG"
bw=$(boot_wait "$B" "$VMID") || { fail "VM $VMID did not boot on $NB after the rollback within ${BOOT_BUDGET}s"; exit 1; }
GIP=${bw% *}; say "guest $VMID up on $NB after the rollback to snap1 after ${bw#* }s"
m=$(on "$GIP" 'echo "pre=$(cat /root/pre 2>/dev/null) post=$(cat /root/post 2>/dev/null)"' 30)
say "  markers after the rollback to snap1: $m"
[ "$m" = "pre=pre post=" ] || fail "after the rollback to snap1 the markers are '$m', expected pre present and post absent"
verify "$GIP" "after the rollback to snap1 (disk)"
writer_start "$GIP" || fail "the writer did not restart"
timed delsnap2 "$B" 60 "qm delsnapshot $VMID snap2 && echo DEL_OK" DEL_OK
timed delsnap1 "$B" 60 "qm delsnapshot $VMID snap1 && echo DEL_OK" DEL_OK
on "$B" "qm listsnapshot $VMID" 20 | tee -a "$LOG" | grep -q snap && fail "snapshots remain after delsnapshot"
on "$B" "ls $MNT/images/$VMID/" 20 | grep -q state && fail "a vmstate file remains after the snapshot was deleted"

# 5. online resize
s0=$(on "$GIP" 'lsblk -bdno SIZE /dev/vda' 20)
timed resize "$B" 60 "qm disk resize $VMID virtio0 +1G && echo RESIZED" RESIZED
sleep 3
s1=$(on "$GIP" 'lsblk -bdno SIZE /dev/vda' 20)
say "  guest disk size $s0 -> $s1"
[ -n "$s0" ] && [ "${s1:-0}" = $(( s0 + 1073741824 )) ] || fail "the guest does not see the resized disk ($s0 -> ${s1:-?})"
verify "$GIP" "after the resize" running

# 6. live backup, its archive on every host, and its restore on C
sleep "$SETTLE_S"
img=$(on "$B" "pvesm path \$(qm config $VMID | sed -n 's/^virtio0: \([^,]*\).*/\1/p')" 30)
iused=$(on "$B" "du -B1 $img | cut -f1" 30)
# harness-lint: ok - taken only to be compared with the archive found after the backup
arch0=$(on "$B" "ls -t $MNT/dump/vzdump-qemu-$VMID-*.vma.zst 2>/dev/null | head -1" 20)
timed backup "$B" "$(mv_budget $(( iused * 2 )))" "vzdump $VMID --storage $SHARED --mode snapshot --compress zstd 2>&1 | tail -8" 'Finished Backup of VM' || exit 1
arch=$(grep -aoE "creating vzdump archive '[^']+'" "$EVID/backup.txt" | sed "s/.*'\(.*\)'/\1/" | tail -1)
if [ -z "$arch" ]; then
    # The newest archive of this VM, unless it is the one that was newest before
    # the backup: that is a previous run's, and restoring it tests nothing here.
    # harness-lint: ok - refused below when it is the archive that was newest before this backup
    arch=$(on "$B" "ls -t $MNT/dump/vzdump-qemu-$VMID-*.vma.zst | head -1" 20)
    [ -n "$arch" ] && [ "$arch" != "$arch0" ] || { fail "the backup left no new archive in $MNT/dump (newest: ${arch:-none})"; exit 1; }
fi
say "  archive $arch"
declare -A ASUM
for n in "${NODES[@]}"; do ( on "${ADDR[$n]}" "sha256sum $arch" 120 | awk '{print $1}' > "$EVID/asum-$n" ) & done
wait
for n in "${NODES[@]}"; do ASUM[$n]=$(cat "$EVID/asum-$n"); say "  archive sha256 on $n: ${ASUM[$n]:0:16}"; done
for n in "${NODES[@]}"; do [ -n "${ASUM[$NB]}" ] && [ "${ASUM[$n]}" = "${ASUM[$NB]}" ] || fail "the archive read on $n differs from $NB"; done
verify "$GIP" "after the backup" running
timed restore "$C" "$(mv_budget $(( iused * 2 )))" "qmrestore $arch $RVMID --storage $SHARED --unique 1 && qm set $RVMID --description '$TAG' --name mxfs-ops-restored --onboot 0 >/dev/null && echo RESTORED" RESTORED || exit 1

# 7. the disk moved off the datastore and back, online
isize=$(on "$B" "qemu-img info --force-share --output=json $img" 30 | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])')
timed move_out "$B" "$(mv_budget "${isize:-0}")" "qm disk move $VMID virtio0 $LOCAL --delete 1 && echo MOVED" MOVED
verify "$GIP" "on $LOCAL" running
timed move_back "$B" "$(mv_budget "${isize:-0}")" "qm disk move $VMID virtio0 $SHARED --format qcow2 --delete 1 && echo MOVED" MOVED
on "$B" "qm config $VMID | grep -E '^virtio0:'" 20 | tee -a "$LOG" | grep -q "virtio0: $SHARED:" || fail "the disk is not back on $SHARED"
verify "$GIP" "back on $SHARED" running
on "$GIP" 'cd /root/mig && touch stop; for k in $(seq 1 600); do [ -e stopped ] && break; sleep 0.2; done; [ -e stopped ] && echo STOPPED' 150 | grep -q STOPPED || fail "the writer did not stop"
verify "$GIP" "final, writer stopped"
on "$GIP" 'dmesg' 60 > "$EVID/guest-dmesg.txt"
gbad=$(grep -aiE 'I/O error|blk_update_request|buffer I/O|EXT4-fs error|XFS .*(error|corrupt|Shutting down)|blocked for more than|Call Trace' "$EVID/guest-dmesg.txt")
say "guest dmesg: $(wc -l < "$EVID/guest-dmesg.txt") lines, bad=$(grep -c . <<<"$gbad")"
[ -z "$gbad" ] || fail "the guest logged: $(head -3 <<<"$gbad" | tr '\n' ' ')"
timed stop "$B" 120 "qm shutdown $VMID --timeout 90 && qm status $VMID" 'status: stopped'
img=$(on "$B" "pvesm path \$(qm config $VMID | sed -n 's/^virtio0: \([^,]*\).*/\1/p')" 30)
timed qemu_img_check "$C" 120 "qemu-img check $img" 'No errors were found'

# the restore booted now that the original is stopped: a restored disk keeps
# the guest's machine-id, so DHCP hands it the original's lease, and with both
# running a command sent to that address could reach either guest
m0=$(on "$B" "qm config $VMID | sed -n 's/^net0: virtio=\([^,]*\).*/\1/p'" 20)
m1=$(on "$C" "qm config $RVMID | sed -n 's/^net0: virtio=\([^,]*\).*/\1/p'" 20)
say "  MAC original $m0, restored $m1"
[ -n "$m1" ] && [ "$m1" != "$m0" ] || fail "the restored guest does not have a MAC of its own (--unique)"
on "$C" "qm start $RVMID" 120 >> "$LOG"
if bw=$(boot_wait "$C" "$RVMID"); then
    RIP=${bw% *}; say "restored guest $RVMID up on $NC after ${bw#* }s at $RIP"
    verify "$RIP" "the restored guest on $NC"
    on "$C" "qm stop $RVMID" 120 >> "$LOG"
else
    fail "restored VM $RVMID did not boot on $NC within ${BOOT_BUDGET}s"
fi

# 8. template, linked clone booted on another host than the template's:
# C, or B when there are only two (C is then A, and a migration to the host
# it is on is refused)
if [ "$NC" != "$NA" ]; then NL=$NC; else NL=$NB; fi; L=${ADDR[$NL]}
timed tclone "${ADDR[$src]}" "$CB" "qm clone $SRC_VMID $TVMID --full 1 --storage $SHARED --format qcow2 --name mxfs-ops-tmpl $TGT && qm set $TVMID --description '$TAG' --cpu $CPU >/dev/null && echo CLONED" CLONED || exit 1
timed template "$A" 60 "qm template $TVMID && echo TEMPLATED" TEMPLATED || exit 1
base=$(on "$A" "pvesm path \$(qm config $TVMID | sed -n 's/^virtio0: \([^,]*\).*/\1/p')" 30)
b0=$(on "$B" "sha256sum $base" 120 | awk '{print $1}')
say "  base $base sha256 on $NB ${b0:0:16}"
timed lclone "$A" 60 "qm clone $TVMID $LVMID --full 0 --name mxfs-ops-linked && qm set $LVMID --description '$TAG' >/dev/null && echo CLONED" CLONED || exit 1
on "$A" "qm config $LVMID | grep -E '^virtio0:'" 20 | tee -a "$LOG"
timed lmove "$A" 60 "qm migrate $LVMID $NL && echo MOVED" MOVED || exit 1
on "$L" "qm start $LVMID" 120 >> "$LOG"
if bw=$(boot_wait "$L" "$LVMID"); then
    LIP=${bw% *}; say "linked clone $LVMID up on $NL after ${bw#* }s at $LIP"
    on "$LIP" 'dd if=/dev/urandom of=/root/l bs=1M count=64 conv=fsync status=none && sha256sum /root/l > /root/l.sha && sync && echo 3 > /proc/sys/vm/drop_caches && sha256sum -c /root/l.sha' 120 | tee -a "$LOG" | grep -q ': OK$' ||
        fail "the linked clone's file did not verify"
    on "$L" "qm stop $LVMID" 120 >> "$LOG"
else
    fail "linked clone $LVMID did not boot on $NL within ${BOOT_BUDGET}s"
fi
b1=$(on "$B" "sha256sum $base" 120 | awk '{print $1}')
say "  base sha256 on $NB after the linked clone ran: ${b1:0:16}"
[ -n "$b0" ] && [ "$b0" = "$b1" ] || fail "the template's base image changed while its linked clone ran"
lim=$(on "$L" "pvesm path \$(qm config $LVMID | sed -n 's/^virtio0: \([^,]*\).*/\1/p')" 30)
timed lclone_check "$B" 120 "qemu-img check $lim" 'No errors were found'

# 9. a container on the datastore, restart-migrated
if [ -z "$CT_TEMPLATE" ]; then
    CT_TEMPLATE=$(on "$A" "pveam update >/dev/null 2>&1; pveam available --section system | awk '/alpine-.*_amd64/{print \$2}' | sort -V | tail -1" 60 | tail -1)
fi
[ -n "$CT_TEMPLATE" ] || { fail "no container template to download"; exit 1; }
on "$A" "pveam list $SHARED" 30 | grep -q "$CT_TEMPLATE" ||
    timed ct_template "$A" 120 "pveam download $SHARED $CT_TEMPLATE 2>&1 | tail -2" 'download of .* finished|calculating checksum.*OK|finished' || exit 1
timed ct_create "$A" 120 "pct create $CTID $SHARED:vztmpl/$CT_TEMPLATE --rootfs $SHARED:2 --hostname mxfs-ops-ct --net0 name=eth0,bridge=vmbr0,ip=dhcp --description '$TAG' --unprivileged 1 && echo CREATED" CREATED || exit 1
timed ct_start "$A" 60 "pct start $CTID && pct status $CTID" 'status: running' || exit 1
on "$A" "pct exec $CTID -- sh -c 'mkdir -p /root/c && for i in 1 2 3 4 5 6 7 8; do dd if=/dev/urandom of=/root/c/f\$i bs=1M count=8 2>/dev/null && sync; done; cd /root/c && sha256sum f* > sums && sync && echo CT_WRITTEN'" 120 | grep -q CT_WRITTEN || fail "the container's files were not written"
timed ct_migrate "$A" 120 "pct migrate $CTID $NB --restart 1 2>&1 | tail -3" 'migration finished successfully' || exit 1
on "$B" "pct status $CTID" 20 | grep -q 'status: running' || fail "the container is not running on $NB after the migration"
on "$B" "pct exec $CTID -- sh -c 'cd /root/c && sha256sum -c sums'" 60 | tee "$EVID/ct_verify.txt" | grep -c ': OK$' | grep -qx 8 ||
    fail "the container's files did not all verify on $NB: $(tr '\n' ' ' < "$EVID/ct_verify.txt" | cut -c1-300)"
say "  container files on $NB: $(grep -c ': OK$' "$EVID/ct_verify.txt") of 8 OK"
timed ct_stop "$B" 60 "pct shutdown $CTID --timeout 40 && pct status $CTID" 'status: stopped'

# 10. the hosts' kernel logs
for n in "${NODES[@]}"; do
    on "${ADDR[$n]}" "journalctl -k --since @$(cat "$EVID/t0-$n") --no-pager -o short-monotonic" 60 > "$EVID/kmsg-$n.txt"
    hbad=$(grep -aE "$BAD" "$EVID/kmsg-$n.txt")
    say "$n kernel log: $(wc -l < "$EVID/kmsg-$n.txt") lines, mxfs $(grep -ac mxfs "$EVID/kmsg-$n.txt"), bad=$(grep -c . <<<"$hbad")"
    [ -z "$hbad" ] || fail "$n logged: $(head -3 <<<"$hbad" | tr '\n' ' ' | cut -c1-400)"
    on "${ADDR[$n]}" "grep -q ' $MNT mxfs ' /proc/mounts && echo WHOLE" 20 | grep -q WHOLE || fail "$n no longer holds $MNT"
done
[ "$bad" = 0 ] && say "RESULT: PASS (evidence $EVID)" || say "RESULT: FAIL (evidence $EVID)"
[ "$bad" = 0 ]
