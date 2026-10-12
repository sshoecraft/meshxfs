#!/bin/bash
# pve_ha_failover.sh — a Proxmox HA guest on the shared MXFS storage survives
# the death of the host it runs on: Proxmox restarts it on a survivor, MXFS on
# the survivors carries on and recovers the dead host's share, and every file
# the guest had fsynced before the death reads back intact afterwards.  Then
# the dead host comes back, mounts the volume again, and takes the guest back
# by live migration.
#
# What a cluster of three or more Proxmox hosts on one SAN LUN is for: when a
# host dies its VMs come back elsewhere without anyone touching them.  The
# death is a power cut (virsh destroy of a nested host): no unmount, no
# flush, no goodbye to the cluster.
#
# What it does:
#   1. A full clone of SRC_VMID onto SHARED (raw), VMID, started on the first
#      host; its writer (the one tests/pve_live_migrate.sh runs: files from
#      /dev/urandom, each fsynced, its sha256 recorded beside it after the
#      fsync) runs, and the files are checked once.
#   2. The VM is put under HA (ha-manager add, state started) and the writer
#      runs on.
#   3. The host running it is powered off (virsh destroy).  On each survivor,
#      in parallel, a new file is created, written and fsynced on the volume
#      over and over: the time until the first one completes is how long
#      MXFS kept a survivor from writing while it recovered.
#   4. HA must have the VM running on a survivor, with its agent answering,
#      within HA_BUDGET.  The guest booted from a crash: every file whose sum
#      it recorded must verify.
#   5. The dead host is started again; it must rejoin the Proxmox cluster,
#      mount the volume (scripts/pve_mxfs_san_disk.sh join), and take the
#      guest back by online migration, after which the files verify again.
#   6. Every host's kernel log since the start (the dead host's from its new
#      boot) and the guest's are searched for I/O errors, hung tasks,
#      warnings, withdrawals and shutdowns.
#   7. The VM is removed from HA, stopped and destroyed (KEEP=1 keeps it).
#
# Usage: tests/pve_ha_failover.sh
# Env:
#   PVE_HOSTS   "<addr> ..." (required, three or more: HA needs a majority
#               without the dead host)
#   SRC_VMID (9000, scripts/pve_cloud_guest.sh)  VMID (9200)  SHARED (mxfssan)
#   MNT         the volume every host mounts (default /mnt/mxfssan)
#   SAN_DEV     its device path on the hosts (default scripts/pve_caw_lun.sh's
#               by-path link for target iqn.2026-05.local.mxfs:pve-caw-02 on
#               portal 192.168.120.1)
#   WRITE_MB (32)  MAXF (32)  SETTLE_S (20)
#   HA_BUDGET   seconds from the power-off to the guest's agent answering on a
#               survivor (default 300: Proxmox documents up to two minutes for
#               the dead node's lock to expire and the service to be recovered,
#               plus the guest's boot, about 150 s, twice that)
#   WRITE_BUDGET seconds a survivor may wait for its first fsynced write after
#               the power-off (default 120: MXFS's own bound is its lease and
#               fence of the dead host; no guest I/O timeout is longer than a
#               minute, twice that)
#   BOOT_BUDGET seconds from a host's start to ssh answering (default 120)
#   CLONE_BUDGET (400)  MIG_BUDGET (30)
#   BYVMID      the bystander guest (default 9201): runs on the last host, which
#               survives, writing new fsynced 1 MiB files throughout
#   BY_BUDGET_MS the longest a bystander write may take (default 30000: a
#               guest's own I/O timeout, the bound tests/pve_pair_failover.sh
#               holds a takeover's I/O to)
# Evidence: tests/evidence/pve_ha_failover/<UTC stamp>/
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSHP="$REPO/tools/mxfs_sshpass.sh"
VIRSH="virsh -c qemu:///system"
read -r -a HOSTS <<<"${PVE_HOSTS:?PVE_HOSTS must name three or more hosts}"
[ "${#HOSTS[@]}" -ge 3 ] || { echo "pve_ha_failover: HA needs three or more hosts"; exit 2; }
SRC_VMID=${SRC_VMID:-9000}; VMID=${VMID:-9200}; BYVMID=${BYVMID:-9201}; SHARED=${SHARED:-mxfssan}
BY_BUDGET_MS=${BY_BUDGET_MS:-30000}
MNT=${MNT:-/mnt/mxfssan}
SAN_DEV=${SAN_DEV:-/dev/disk/by-path/ip-192.168.120.1:3260-iscsi-iqn.2026-05.local.mxfs:pve-caw-02-lun-0}
WRITE_MB=${WRITE_MB:-32}; MAXF=${MAXF:-32}; SETTLE_S=${SETTLE_S:-20}
HA_BUDGET=${HA_BUDGET:-300}; WRITE_BUDGET=${WRITE_BUDGET:-120}; BOOT_BUDGET=${BOOT_BUDGET:-120}
CLONE_BUDGET=${CLONE_BUDGET:-400}; MIG_BUDGET=${MIG_BUDGET:-30}
CPU=${CPU:-x86-64-v2}
TAG="mxfs HA failover test clone (tests/pve_ha_failover.sh)"
EVID=${EVID:-$REPO/tests/evidence/pve_ha_failover/$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$EVID" || exit 1
LOG=$EVID/log
BAD='I/O error|blocked for more than|WARNING:|BUG:|Oops|Shutting down filesystem|P-WITHDRAW|RECOVERY_BLOCKED|self-fenc|corrupt'
bad=0

on() { timeout "${3:-60}" "$SSHP" "$1" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$'; return "${PIPESTATUS[0]}"; }
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
fail() { say "FAIL: $*"; bad=1; }
mounted() { on "$1" "grep -q ' $MNT mxfs ' /proc/mounts && echo M" 20 | grep -q M; }

declare -A ADDR
for h in "${HOSTS[@]}"; do
    n=$(on "$h" "hostname" 20 | tail -1)
    [ -n "$n" ] || { say "FAIL: $h did not answer"; exit 1; }
    ADDR[$n]=$h
    mounted "$h" || { say "FAIL: $h does not hold $MNT; not starting"; exit 1; }
    on "$h" "date +%s" 20 > "$EVID/t0-$h"
    say "$h ($n): build $(on "$h" "cat /sys/module/mxfs/version /sys/module/mxfs/srcversion" 20 | tr '\n' ' ')"
done
# The cluster's view of the VMs, from the first host that answers with it: a
# host this test powers off answers nothing, and asking only it read the
# recovered guest as missing.
resources() {
    local a out
    for a in "${HOSTS[@]}"; do
        out=$(on "$a" "pvesh get /cluster/resources --type vm --output-format json" 30)
        python3 -I -c 'import json,sys; json.loads(sys.argv[1])' "$out" 2>/dev/null && { printf '%s' "$out"; return 0; }
    done
    return 1
}
node_of() {
    resources | python3 -I -c 'import json,sys; v=[r for r in json.load(sys.stdin) if r.get("vmid")==int(sys.argv[1])]; print(v[0]["node"] if v else "")' "$1" 2>/dev/null
}
vm_status() {
    resources | python3 -I -c 'import json,sys; v=[r for r in json.load(sys.stdin) if r.get("vmid")==int(sys.argv[1])]; print(v[0].get("status","") if v else "")' "$1" 2>/dev/null
}
GIP=
gexec() { on "$GIP" "$1" "${2:-60}"; }
guest_ip() {  # <host> [vmid]
    on "$1" "qm agent ${2:-$VMID} network-get-interfaces" 30 | python3 -I -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
for i in d:
    if i.get("name") == "lo": continue
    for a in i.get("ip-addresses", []):
        if a.get("ip-address-type") == "ipv4": print(a["ip-address"]); sys.exit(0)
sys.exit(1)'
}
wait_guest() {  # <host> <budget> <since> [vmid]: agent, address, ssh; sets GIP
    local t0=$3 v=${4:-$VMID}
    until on "$1" "qm agent $v ping && echo PONG" 20 | grep -q PONG; do
        [ $(( $(date +%s) - t0 )) -lt "$2" ] || return 1; sleep 3
    done
    until GIP=$(guest_ip "$1" "$v") && [ -n "$GIP" ] && gexec 'true' 20; do
        [ $(( $(date +%s) - t0 )) -lt "$2" ] || return 1; sleep 3
    done
}

# 1. the clone, started on the first host
N0=$(on "${HOSTS[0]}" hostname 20 | tail -1)
cur=$(node_of "$VMID")
if [ -n "$cur" ]; then
    desc=$(on "${ADDR[$cur]}" "qm config $VMID | sed -n 's/^description: //p'" 30)
    [[ "$desc" == *pve_ha_failover* ]] || { say "FAIL: VM $VMID exists and was not made by this script"; exit 1; }
    on "${ADDR[$cur]}" "ha-manager remove vm:$VMID >/dev/null 2>&1; qm stop $VMID --skiplock 1 >/dev/null 2>&1; qm destroy $VMID --purge 1" 300 | tail -1 | tee -a "$LOG"
fi
src=$(node_of "$SRC_VMID")
[ -n "$src" ] || { say "FAIL: no source VM $SRC_VMID (scripts/pve_cloud_guest.sh)"; exit 1; }
t=$(date +%s)
on "${ADDR[$src]}" "qm clone $SRC_VMID $VMID --full 1 --storage $SHARED --format raw --name mxfs-ha && qm set $VMID --description '$TAG' --onboot 0 --cpu $CPU >/dev/null && echo CLONED" "$CLONE_BUDGET" > "$EVID/clone.txt" 2>&1
grep -q CLONED "$EVID/clone.txt" || { say "FAIL: clone: $(tail -3 "$EVID/clone.txt" | tr '\n' ' ')"; exit 1; }
say "clone $VMID made on $src in $(( $(date +%s) - t ))s"
if [ "$src" != "$N0" ]; then
    on "${ADDR[$src]}" "qm migrate $VMID $N0" 120 > "$EVID/move-to-$N0.txt" 2>&1 || { say "FAIL: could not move the stopped clone to $N0"; exit 1; }
fi
cleanup() {
    [ "${KEEP:-0}" = 1 ] && { say "KEEP=1: leaving VMs $VMID $BYVMID"; return; }
    local n v
    for v in "$VMID" "$BYVMID"; do
        n=$(node_of "$v"); [ -n "$n" ] || continue
        on "${ADDR[$n]}" "ha-manager remove vm:$v >/dev/null 2>&1; qm stop $v >/dev/null 2>&1; qm destroy $v --purge 1 >/dev/null 2>&1; echo DESTROY_RC=\$?" 300 | tail -1 | sed "s/^/VM $v on $n: /" | tee -a "$LOG"
    done
}
trap cleanup EXIT

# the bystander: a second guest on the last host, which survives, writing a
# new 1 MiB file with fsync every 0.2 s and logging each write's latency, so
# the run shows whether guests on SURVIVING hosts stall while MXFS recovers
# the dead host's share (new files make MXFS allocate, the case that can wait
# on locks the dead host held)
NB=$(on "${HOSTS[-1]}" hostname 20 | tail -1)
cur=$(node_of "$BYVMID")
if [ -n "$cur" ]; then
    desc=$(on "${ADDR[$cur]}" "qm config $BYVMID | sed -n 's/^description: //p'" 30)
    [[ "$desc" == *pve_ha_failover* ]] || { say "FAIL: VM $BYVMID exists and was not made by this script"; exit 1; }
    on "${ADDR[$cur]}" "qm stop $BYVMID --skiplock 1 >/dev/null 2>&1; qm destroy $BYVMID --purge 1" 300 | tail -1 | tee -a "$LOG"
fi
on "${ADDR[$src]}" "qm clone $SRC_VMID $BYVMID --full 1 --storage $SHARED --format raw --name mxfs-bystander && qm set $BYVMID --description '$TAG' --onboot 0 --cpu $CPU >/dev/null && echo CLONED" "$CLONE_BUDGET" > "$EVID/clone-bystander.txt" 2>&1
grep -q CLONED "$EVID/clone-bystander.txt" || { say "FAIL: bystander clone: $(tail -3 "$EVID/clone-bystander.txt" | tr '\n' ' ')"; exit 1; }
[ "$src" != "$NB" ] && { on "${ADDR[$src]}" "qm migrate $BYVMID $NB" 120 > "$EVID/move-bystander.txt" 2>&1 || { say "FAIL: could not move the bystander to $NB"; exit 1; }; }
on "${ADDR[$NB]}" "qm start $BYVMID" 120 | tee -a "$LOG"
t=$(date +%s)
wait_guest "${ADDR[$NB]}" 300 "$t" "$BYVMID" || { fail "the bystander did not come up on $NB within 300s"; exit 1; }
BIP=$GIP
on "$BIP" "mkdir -p /root/by && cd /root/by && rm -f stop lat.log b.* && setsid nohup bash -c 'n=0; while [ ! -e stop ]; do n=\$((n+1)); s=\$(date +%s%3N); dd if=/dev/urandom of=b.\$n bs=64k count=16 conv=fsync status=none; r=\$?; e=\$(date +%s%3N); echo \"\$s \$((e - s)) \$r\" >> lat.log; rm -f b.\$((n - 50)); sleep 0.2; done' > /dev/null 2>&1 < /dev/null & echo BY_STARTED" 30 | grep -q BY_STARTED \
    || { fail "the bystander's writer did not start"; exit 1; }
say "bystander $BYVMID up on $NB at $BIP, writing"

h=${ADDR[$N0]}
on "$h" "qm start $VMID" 120 | tee -a "$LOG"
t=$(date +%s)
wait_guest "$h" 300 "$t" || { fail "the guest did not come up on $N0 within 300s (first boot: cloud-init installs its agent)"; exit 1; }
say "guest up on $N0 after $(( $(date +%s) - t ))s at $GIP"
WRITER='mkdir -p /root/mig && cd /root/mig && rm -f stop stopped pause paused f*.tmp && n=$(cat count 2>/dev/null | cut -d" " -f1); n=${n:-0}
while [ ! -e stop ]; do
  if [ -e pause ]; then : > paused; sleep 0.2; continue; fi
  rm -f paused
  n=$((n+1)); i=$(( (n-1) % '"$MAXF"' + 1 ))
  rm -f f$i.sha
  dd if=/dev/urandom of=f$i bs=1M count='"$WRITE_MB"' conv=fsync status=none || { echo "write f$i failed" >> errors; sleep 1; continue; }
  sha256sum f$i > f$i.sha.tmp && sync f$i.sha.tmp && mv f$i.sha.tmp f$i.sha && sync
  echo "$n $(date +%s) $(cat /proc/sys/kernel/hostname)" > count
done
: > stopped'
start_writer() {
    gexec "printf '%s\n' $(printf '%q' "$WRITER") > /root/mig-writer.sh && setsid nohup bash /root/mig-writer.sh > /root/mig-writer.out 2>&1 < /dev/null & echo WRITER_STARTED" 30 | grep -q WRITER_STARTED
}
verify() {  # <label> [nopause: the writer is not running]
    local out rc
    if [ "${2:-}" != nopause ]; then
        gexec 'cd /root/mig && touch pause; for k in $(seq 1 600); do [ -e paused ] && break; sleep 0.2; done; [ -e paused ]' 150 > /dev/null || { fail "$1: the writer did not pause"; return; }
    fi
    out=$(gexec 'cd /root/mig && sync && echo 3 > /proc/sys/vm/drop_caches && n=$(ls f*.sha 2>/dev/null | wc -l) && res=$(cat f*.sha | sha256sum -c 2>&1); ok=$(grep -c ": OK$" <<<"$res"); bad=$(grep -v ": OK$" <<<"$res"); echo "files=$n ok=$ok count=$(cat count) errors=$(cat errors 2>/dev/null | wc -l)"; [ -z "$bad" ] || echo "BAD: $bad"; [ "$n" = "$ok" ] && [ "$n" -gt 0 ] && [ -z "$bad" ]' 600)
    rc=$?
    say "  $1 verify: $(echo "$out" | head -5 | tr '\n' ' ')"
    [ "$rc" = 0 ] || fail "$1: the guest's files did not all verify (rc=$rc)"
    [ "${2:-}" != nopause ] && gexec 'rm -f /root/mig/pause' 30 > /dev/null
}
start_writer || { fail "the writer did not start"; exit 1; }
sleep "$SETTLE_S"
verify "before HA"

# 2. under HA
on "$h" "ha-manager add vm:$VMID --state started --max_restart 1 --max_relocate 2 && echo HA_ADDED" 60 | grep -q HA_ADDED || { fail "ha-manager add failed"; exit 1; }
t=$(date +%s)
until on "$h" "ha-manager status" 20 | grep -qE "service vm:$VMID \\($N0, started\\)"; do
    [ $(( $(date +%s) - t )) -lt 120 ] || { fail "HA did not report vm:$VMID started on $N0 within 120s"; exit 1; }
    sleep 3
done
say "vm:$VMID under HA, started on $N0; writer at file $(gexec 'cut -d" " -f1 /root/mig/count' 20)"
sleep "$SETTLE_S"
before=$(gexec 'cut -d" " -f1 /root/mig/count' 20)

# 3. power off the host running it; survivors write meanwhile
SURV=(); for n in "${!ADDR[@]}"; do [ "$n" != "$N0" ] && SURV+=("$n"); done
say "power-off $N0 (virsh destroy) with the writer at file $before; survivors ${SURV[*]}"
tk=$(date +%s)
$VIRSH destroy "$N0" >> "$LOG" 2>&1 || { fail "virsh destroy $N0 failed"; exit 1; }
# One write per survivor, started on the survivor itself the moment the host
# is gone and bounded by WRITE_BUDGET there: how long it blocks is how long
# MXFS kept that survivor from writing (ms, timed on the survivor).
for n in "${SURV[@]}"; do
    ( a=${ADDR[$n]}
      out=$(on "$a" "s=\$(date +%s%3N); if timeout $WRITE_BUDGET dd if=/dev/urandom of=$MNT/ha-probe-$n bs=64k count=16 conv=fsync status=none; then r=OK; else r=FAIL; fi; e=\$(date +%s%3N); rm -f $MNT/ha-probe-$n; echo \"\$r \$(( e - s ))\"" $(( WRITE_BUDGET + 30 )) | tail -1)
      echo "${out:-FAIL none}" > "$EVID/survivor-write-$n" ) &
done
# 4. HA brings the guest back on a survivor
newn=""; t=$tk
while [ $(( $(date +%s) - t )) -lt "$HA_BUDGET" ]; do
    newn=$(node_of "$VMID")
    if [ -n "$newn" ] && [ "$newn" != "$N0" ] && [ "$(vm_status "$VMID")" = running ]; then break; fi
    newn=""; sleep 5
done
wait
for n in "${SURV[@]}"; do
    read -r r s < "$EVID/survivor-write-$n"
    say "survivor $n: a 1 MiB fsynced write started at the power-off: ${r} in ${s} ms"
    [ "$r" = OK ] || fail "survivor $n could not write to $MNT within ${WRITE_BUDGET}s of the power-off"
done
[ -n "$newn" ] || { fail "HA did not have vm:$VMID running on a survivor within ${HA_BUDGET}s"; exit 1; }
say "HA restarted vm:$VMID on $newn $(( $(date +%s) - tk ))s after the power-off"
if wait_guest "${ADDR[$newn]}" "$HA_BUDGET" "$tk"; then
    say "guest answers on $newn $(( $(date +%s) - tk ))s after the power-off"
else
    fail "the guest's agent and ssh did not answer on $newn within ${HA_BUDGET}s of the power-off"; exit 1
fi
verify "after the crash, on $newn" nopause
start_writer || fail "the writer did not restart on $newn"

# 5. the dead host comes back, rejoins, mounts, and takes the guest back
$VIRSH start "$N0" >> "$LOG" 2>&1 || fail "virsh start $N0 failed"
t=$(date +%s)
until on "${ADDR[$N0]}" "echo UP" 10 | grep -q UP; do
    [ $(( $(date +%s) - t )) -lt "$BOOT_BUDGET" ] || { fail "$N0 did not answer ssh within ${BOOT_BUDGET}s of its start"; break; }
    sleep 3
done
on "${ADDR[$N0]}" "date +%s" 20 > "$EVID/t1-${ADDR[$N0]}"
until on "${ADDR[$N0]}" "pvecm status" 20 | grep -qE "^Total votes: +${#HOSTS[@]}"; do
    [ $(( $(date +%s) - t )) -lt $(( BOOT_BUDGET * 2 )) ] || { fail "$N0 did not rejoin the cluster within $(( BOOT_BUDGET * 2 ))s"; break; }
    sleep 3
done
say "$N0 back in the cluster $(( $(date +%s) - t ))s after its start"
PVE_PAIR="${ADDR[$N0]}" SAN_DEV=$SAN_DEV MNT=$MNT "$REPO/scripts/pve_mxfs_san_disk.sh" join > "$EVID/rejoin.txt" 2>&1 \
    && say "$N0: $(tail -1 "$EVID/rejoin.txt")" || fail "$N0 could not mount the volume again: $(tail -2 "$EVID/rejoin.txt" | tr '\n' ' ')"
sleep "$SETTLE_S"
# an HA resource is moved by asking HA (qm migrate only files the request and
# returns): done when HA reports it started on N0 and the guest answers there
t=$(date +%s)
on "${ADDR[$newn]}" "ha-manager migrate vm:$VMID $N0" 30 > "$EVID/migrate-back.txt" 2>&1
moved=0
while [ $(( $(date +%s) - t )) -lt $(( MIG_BUDGET + 30 )) ]; do
    if [ "$(node_of "$VMID")" = "$N0" ] && [ "$(vm_status "$VMID")" = running ] &&
       on "${ADDR[$N0]}" "qm agent $VMID ping && echo PONG" 20 | grep -q PONG; then moved=1; break; fi
    sleep 2
done
if [ "$moved" = 1 ]; then
    say "HA migrated the guest back to $N0 in $(( $(date +%s) - t ))s"
    verify "back on $N0"
else
    fail "HA did not move the guest back to $N0 within $(( MIG_BUDGET + 30 ))s: $(tail -3 "$EVID/migrate-back.txt" | tr '\n' ' '); on $(node_of "$VMID")"
fi

# the bystander's writes across the whole run, the power-off included
on "$BIP" "touch /root/by/stop; sleep 1; cat /root/by/lat.log" 60 > "$EVID/bystander-lat.log"
read -r bn bmax bmaxat berr bslow <<<"$(awk -v b="$BY_BUDGET_MS" '{n++; if ($2 > m) {m = $2; at = $1} if ($3 != 0) e++; if ($2 > 1000) s++} END {print n+0, m+0, at+0, e+0, s+0}' "$EVID/bystander-lat.log")"
say "bystander on $NB: $bn fsynced 1 MiB writes, longest ${bmax} ms (started $(( bmaxat / 1000 - tk ))s after the power-off), $bslow over 1 s, $berr failed"
[ "$bn" -gt 0 ] || fail "the bystander logged no writes"
[ "$berr" = 0 ] || fail "the bystander saw $berr failed writes"
[ "$bmax" -le "$BY_BUDGET_MS" ] || fail "a bystander write on surviving host $NB took ${bmax} ms, over ${BY_BUDGET_MS} ms (a guest's own I/O timeout)"

# 6. logs
gexec 'touch /root/mig/stop' 20 > /dev/null
gexec 'dmesg' 60 > "$EVID/guest-dmesg.txt"
gbad=$(grep -aiE 'I/O error|blk_update_request|buffer I/O|EXT4-fs error|blocked for more than|Call Trace' "$EVID/guest-dmesg.txt")
say "guest dmesg: $(wc -l < "$EVID/guest-dmesg.txt") lines, bad=$(grep -c . <<<"$gbad")"
[ -z "$gbad" ] || fail "the guest logged: $(head -3 <<<"$gbad" | tr '\n' ' ')"
for n in "${!ADDR[@]}"; do
    a=${ADDR[$n]}
    if [ "$n" = "$N0" ]; then since=$(cat "$EVID/t1-$a" 2>/dev/null); else since=$(cat "$EVID/t0-$a"); fi
    on "$a" "journalctl -k --since @${since:-0} --no-pager -o short-iso" 60 > "$EVID/kmsg-$n.txt"
    hbad=$(grep -aE "$BAD" "$EVID/kmsg-$n.txt")
    say "$n kernel log: $(wc -l < "$EVID/kmsg-$n.txt") lines, bad=$(grep -c . <<<"$hbad")"
    [ -z "$hbad" ] || fail "$n logged: $(head -3 <<<"$hbad" | cut -c1-200 | tr '\n' ' ')"
    mounted "$a" || fail "$n does not hold $MNT at the end"
done
[ "$bad" = 0 ] && say "RESULT: PASS (evidence $EVID)" || say "RESULT: FAIL (evidence $EVID)"
exit "$bad"
