#!/bin/bash
# tests/tcp_parallel_create_probe.sh — what a create's durable reserve costs
# when many are in flight at once, on the 2-node TCP rig with the peer mounted.
#
# For D-TCP-LEDGER-SMALLFILE-WORKLOAD-PACE-RULE0-0349.  The batched reserve-ahead
# ruling (docs/rulings/d0349-batched-reserve-ahead.md) is gated on how long a
# grouped commit of ~32 scattered ledger pages takes: about 12 ms or less, or the
# batch cannot keep ledger cost under 0.4 ms per create.  Concurrent creators in
# separate directories (new directories spread over AGs) each commit their own
# reserve at the number's master, so with T of them in flight the ledger sees up
# to T single-page commits at once — the store path a batch would use.  Run with
# tauth_group_commit 0 and 1: the wall per create at concurrency T is the
# amortized cost the batch would get.
#
# Usage: tests/tcp_parallel_create_probe.sh <label> <threads> <files-per-thread> <group_commit 0|1> [A=test1] [B=test2]
#   B must be mounted (the peer); A is mounted here and unmounted at the end,
#   which prints A's ledger stats (P-TAUTH-STATS why=close: commits, avg_ms,
#   gc_batches, gc_pages, gc_max) into its kernel log.
# Budget: mount 15 s + creates (native XFS makes 10k empty files in well under
# 2 s; the whole remote command is bounded at 200 s by its ssh) + unmount 30 s.
# The creators are waited for in the shell that started them: a `wait` in any
# other shell returns at once and times nothing.
set -u
LABEL=${1:?label}; T=${2:?threads}; F=${3:?files per thread}; GC=${4:?group_commit 0|1}
A=${5:-test1}; B=${6:-test2}
cd "$(dirname "$0")/.." || exit 2
SSH=tools/mxfs_sshpass.sh
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_tcp_parallel_create_$LABEL
mkdir -p "$OUT"
MARK="TPC-$LABEL-$$"
# pool VMs nobody holds are shut off by release helpers: hold both for the probe
. tests/lib/runlock.sh
vmhold_take tcp_parallel_create "$A" "$B" || { echo "RESULT: ABORT tcp_parallel_create label=$LABEL -- could not hold $A $B"; exit 2; }
rsx() { local t=$1 n=$2; shift 2; timeout "$t" $SSH "$n" "$*" 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
DEV=$(rsx 15 "$B" "awk '\$3==\"mxfs\"{print \$1}' /proc/mounts" | grep '^/dev' | head -1)
[ -n "$DEV" ] || { echo "RESULT: ABORT tcp_parallel_create label=$LABEL -- $B has no mxfs mount"; exit 2; }
for n in "$A" "$B"; do
    got=$(rsx 15 "$n" "echo $GC > /sys/module/mxfs/parameters/tauth_group_commit; cat /sys/module/mxfs/parameters/tauth_group_commit" | tail -1)
    [ "$got" = "$GC" ] || { echo "RESULT: ABORT tcp_parallel_create label=$LABEL -- $n did not take tauth_group_commit=$GC (got '$got')"; exit 2; }
done
R=$(rsx 200 "$A" "echo $MARK > /dev/kmsg; awk '\$3==\"mxfs\"' /proc/mounts | grep -q . || timeout 15 mount -t mxfs $DEV /mnt/shared; echo mrc=\$?; D=/mnt/shared/tpc_$LABEL; mkdir -p \$D; for t in \$(seq 1 $T); do mkdir \$D/d\$t; done; sync; t0=\$(date +%s%N); for t in \$(seq 1 $T); do ( for i in \$(seq 1 $F); do : > \$D/d\$t/f\$i || { echo cerr; break; }; done ) & done; wait; t1=\$(date +%s%N); echo create_ns=\$((t1 - t0)); echo files=\$(find \$D -type f | wc -l); t2=\$(date +%s%N); timeout 30 umount /mnt/shared; echo urc=\$?; echo umount_ns=\$(( \$(date +%s%N) - t2 )); dmesg | sed -n '/$MARK/,\$p' | grep -a 'P-TAUTH-STATS\|P-TAUTH-STORE-STATS\|P-DLM-RETRY-TALLY\|Shutting down\|Internal error'")
echo "$R" > "$OUT/A.txt"
CNS=$(echo "$R" | sed -n 's/^create_ns=//p'); FILES=$(echo "$R" | sed -n 's/^files=//p')
echo "$R" | grep -a 'P-TAUTH-STATS\|P-DLM-RETRY' | sed 's/^.*\(P-[A-Z-]*\)/\1/' | cut -c1-400
python3 -c "
c=int('${CNS:-0}'); f=int('${FILES:-0}')
print(f'RESULT: MEASURED tcp_parallel_create label=$LABEL threads=$T gc=$GC files={f} create_wall={c/1e9:.2f}s per_create_ms={(c/1e6/f) if f else 0:.3f} creates_per_s={(f/(c/1e9)) if c else 0:.0f} evidence=$OUT')"
