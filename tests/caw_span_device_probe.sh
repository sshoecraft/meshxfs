#!/bin/bash
# tests/caw_span_device_probe.sh — does this rig's target answer a whole-page
# (8-block) SCSI COMPARE AND WRITE, and how long does one take beside the
# 1-block swap every disklock CAS uses?
#
# WHY.  The ledger store now commits a page in one 8-block COMPARE AND WRITE
# on a SCSI device whose Block Limits page allows it (module knob caw_span,
# default 1).  The first rig runs of a build carrying it (2026-10-19
# 04:09-04:30Z, ~/src/mxfs-e E9B83D5632B58D3C14FDF5A) saw 4 of 6 preps hang in
# the first node's mount, each with that node's iSCSI session reset about 60 s
# after the prep began (host kernel log: 'Connection ... unexpectedly closed',
# then NEXUS_LOSS_SESS and a new session), and the one prep that passed had no
# reset.  Nothing has yet shown an 8-block swap answered on this rig: every fix
# arm of the span A/B aborted before its counter was read.  This asks the
# device directly, with no filesystem in the way.
#
# Usage: tests/caw_span_device_probe.sh <label> <node> <wwid> [rounds]
#   <node> is held (tools/vm_pool.sh shuts off a VM nobody holds) and started
#   if it is off.  The LUN is /dev/disk/by-id/wwn-0x<wwid> on <node>; the probe
#   refuses when <node> has any mxfs mount, because it writes a scratch region
#   (the last 2 MiB of the LUN, 4 KiB aligned).  Each round reads NUM blocks
#   there, then issues one COMPARE AND WRITE of NUM blocks with FUA that
#   compares exactly what was read and writes fresh random data, timed, and
#   reads the region back; NUM alternates 1 and 8.  The device's Block Limits
#   page is printed first, the node's kernel log since the probe began last.
#
# Output: one line per command,
#   ROUND r=<n> num=<1|8> rc=<sg rc> ms=<wall> verify=<landed|old|other>
# and RESULT: <ANSWERED|UNANSWERED|ABORT> ...  (ANSWERED: every command rc 0
# and landed; UNANSWERED: any command timed out or failed).  A measurement of
# the target, not a verdict about MXFS.
#
# Bound: each command carries the sg tool's 30 s timeout (the module's own CAW
# timeout); worst case rounds x 2 x 30 s plus the reads, so the remote script
# gets rounds x 70 + 30 s.  Starting an off node takes up to 120 s.
set -u
LABEL=${1:?label}
NODE=${2:?node}
WWID=${3:?wwid}
ROUNDS=${4:-5}
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$REPO/tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_caw_span_probe_$LABEL
mkdir -p "$OUT"
. "$REPO/tests/lib/rig.sh"
. "$REPO/tests/lib/runlock.sh"
vmhold_take "caw_span_device_probe $LABEL" "$NODE" || { echo "RESULT: ABORT label=$LABEL stage=hold"; exit 2; }
timeout 120 "$REPO/tools/vm_pool.sh" up "$NODE" > "$OUT/vm_up.txt" 2>&1 \
    || { cat "$OUT/vm_up.txt"; echo "RESULT: ABORT label=$LABEL stage=vm-up evidence=$OUT"; exit 2; }
probe=$(cat <<EOF
set -u
dev=\$(readlink -f /dev/disk/by-id/wwn-0x$WWID) || { echo "NODEV wwn-0x$WWID"; exit 3; }
[ -b "\$dev" ] || { echo "NODEV wwn-0x$WWID"; exit 3; }
if awk '\$3=="mxfs"' /proc/mounts | grep -q .; then echo "REFUSE an mxfs mount is up"; exit 3; fi
echo "MARK caw_span_probe $LABEL \$(date -u +%FT%TZ)" > /dev/kmsg
sz=\$(blockdev --getsz "\$dev")
lba=\$(( (sz - 4096) / 8 * 8 ))
echo "DEV \$dev sectors=\$sz lba=\$lba"
sg_vpd -p bl "\$dev" 2>&1 | grep -i 'compare and write\|transfer length granularity'
w=\$(mktemp -d)
for r in \$(seq 1 $ROUNDS); do
  for num in 1 8; do
    dd if="\$dev" of="\$w/cmp" bs=512 skip=\$lba count=\$num iflag=direct status=none
    head -c \$((num * 512)) /dev/urandom > "\$w/new"
    cat "\$w/cmp" "\$w/new" > "\$w/in"
    t0=\$(date +%s%N)
    sg_compare_and_write --in="\$w/in" --lba=\$lba --num=\$num --fua --timeout=30 "\$dev" > "\$w/sg.out" 2>&1
    rc=\$?
    t1=\$(date +%s%N)
    dd if="\$dev" of="\$w/rb" bs=512 skip=\$lba count=\$num iflag=direct status=none
    if cmp -s "\$w/rb" "\$w/new"; then v=landed; elif cmp -s "\$w/rb" "\$w/cmp"; then v=old; else v=other; fi
    echo "ROUND r=\$r num=\$num rc=\$rc ms=\$(( (t1 - t0) / 1000000 )) verify=\$v"
    [ "\$rc" = 0 ] || sed 's/^/  sg: /' "\$w/sg.out"
  done
done
rm -rf "\$w"
echo KMSG-BEGIN
dmesg | sed -n "/MARK caw_span_probe $LABEL/,\\\$p" | tail -60
echo KMSG-END
EOF
)
rsx $(( ROUNDS * 70 + 30 )) "$NODE" "$probe" > "$OUT/probe.txt"
rc=$?
cat "$OUT/probe.txt"
grep -aq '^DEV ' "$OUT/probe.txt" || { echo "RESULT: ABORT label=$LABEL stage=probe rc=$rc evidence=$OUT"; exit 2; }
n=$(grep -ac '^ROUND ' "$OUT/probe.txt")
bad=$(grep -a '^ROUND ' "$OUT/probe.txt" | grep -avc ' rc=0 .*verify=landed')
[ "$n" = $(( ROUNDS * 2 )) ] || bad=$(( bad + ROUNDS * 2 - n ))
if [ "$bad" = 0 ]; then verdict=ANSWERED; else verdict=UNANSWERED; fi
echo "RESULT: $verdict label=$LABEL node=$NODE commands=$n bad=$bad rc=$rc evidence=$OUT"
[ "$verdict" = ANSWERED ]
