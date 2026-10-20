#!/bin/bash
# tests/caw_span_adjacent_ab.sh — one arm of the A/B for
# D-WHOLE-PAGE-CAW-PAYLOAD-PANICS-NODE-IN-SCSI-ALLOC-SGTABLES.
#
# THE DEFECT.  A node panicked in mount(2) at scsi_alloc_sgtables+0x3a1, the
# BUG_ON(count > cmd->sdb.table.nents) of the 6.8 kernel, on the first build
# that commits a TCP ledger page in one 8-block SCSI COMPARE AND WRITE
# (caw_span=1): the crash registers hold the mapped count 2 (R15) and the 8 KiB
# request length (RAX).  HYPOTHESIS: caw_manual_bio added its two payload pages
# with bio_add_page, which folds a physically adjacent second page into the
# first page's bvec; 6.8's blk_rq_append_bio counts bvecs, so the request held
# one segment, and __blk_rq_map_sg split the 8 KiB bvec at iscsi_tcp's page
# boundary into two.  Two pages are adjacent only by the allocator's chance.
#
# THE ARM.  The module's test knob dbg_caw_span_adjacent=N builds the next N
# two-page payloads on two pages split from one order-1 block, so they are
# adjacent on every whole-page command, and logs each one
# (P-DBG-CAW-SPAN-ADJACENT pfn=<a>,<b> ... vcnt=<the bio's bvec count>).  The
# cluster must have been prepped from this tree with caw_span=0
# (MXFS_EXTRA_MODARGS=caw_span=0), so the prep itself issues no whole-page
# command on either build.  Then on node A: caw_span=1, dbg_caw_span_adjacent
# =<ADJ> and caw_span_n=0 are written and read back; then ROUNDS times: umount,
# mount (a join: the mount commits ledger pages), create FILES files in a
# directory of its own, sync, read caw_span_n and the knob's count left.  After
# the rounds, A's boot id is compared with the one read before, and the host's
# copy of A's serial console from the arm's start is searched for a BUG, Oops
# or panic (rig guests print only those to the console).  The peer B stays
# mounted throughout.
#
# RESULT (exit status):
#   PANIC   (4) A's boot id changed or its serial console printed a BUG, Oops
#               or panic line during the arm; the lines are printed
#   PASS    (0) no panic; every round mounted, created every file and synced;
#               caw_span_n rose in every round; with ADJ > 0 the knob reached
#               at least one command, and every P-DBG-CAW-SPAN-ADJACENT line
#               names two adjacent pages (pfn b = a + 1) built as two bvecs
#               (vcnt=2)
#   VACUOUS (3) no panic, and no whole-page command was answered, or ADJ > 0
#               and the knob reached none
#   FAIL    (1) no panic, and a round failed, or a knob line shows a merged
#               payload (vcnt=1) or non-adjacent pages
#   ABORT   (2) A does not run this tree's build, a knob did not read back,
#               the device or the serial console could not be read
#
# derived bound: device resolve (mount list 20 s + identity 25 s) + knob write
# 15 s + boot id 15 s + ROUNDS x round 50 s (umount 20 s, mount 15 s, FILES=100
# creates at the 34/s measured on net/mesh within 10 s, sync 5 s) + boot id
# 15 s + serial read 10 s + knob lines 20 s + knob reset 15 s
# = 155 + 50 x ROUNDS s: 305 s at ROUNDS=3.
#
# usage: [MXFS_NODE_LIST=A,B] tests/caw_span_adjacent_ab.sh <label> <adjacent N> <A> [rounds=3] [files=100]
set -u
LABEL=${1:?label}; ADJ=${2:?adjacent count (0 = natural pages)}; A=${3:?node A}
ROUNDS=${4:-3}; FILES=${5:-100}
case $ADJ$ROUNDS$FILES in *[!0-9]*) echo "RESULT: ABORT label=$LABEL -- adjacent, rounds and files are counts: [$ADJ] [$ROUNDS] [$FILES]"; exit 2 ;; esac
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); cd "$REPO"
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_caw_span_adjacent_$LABEL
mkdir -p "$OUT"
. "$REPO/tests/lib/rig.sh"
. "$REPO/tests/lib/runlock.sh"
vmhold_take caw_span_adjacent_ab $(echo "$A ${MXFS_NODE_LIST:-}" | tr ',' ' ') || { echo "RESULT: ABORT label=$LABEL stage=vmhold"; exit 2; }
P=/sys/module/mxfs/parameters
SER=/var/log/libvirt/qemu/$A-serial.log
MARK="CSA-$LABEL-$$"
want=$(modinfo -F srcversion mxfs.ko)
echo "=== caw_span_adjacent_ab label=$LABEL adjacent=$ADJ A=$A rounds=$ROUNDS files=$FILES sv=$want tree=$REPO out=$OUT $(date -u +%FT%TZ) ==="
abort() { echo "RESULT: ABORT label=$LABEL adjacent=$ADJ -- $1 evidence=$OUT"; exit 2; }

mxfs_dev_resolve "$A"; LUN=$MXFS_DEV_RESOLVED

off0=$(timeout 10 sudo -n stat -c %s "$SER" 2>/dev/null)
case $off0 in ''|*[!0-9]*) abort "cannot read the size of $SER (sudo -n stat)" ;; esac
boot0=$(rs 15 "$A" "cat /proc/sys/kernel/random/boot_id" | tail -1)
[ -n "$boot0" ] || abort "cannot read $A's boot id"

got=$(rs 15 "$A" "cat $P/../srcversion; echo 1 > $P/caw_span; echo $ADJ > $P/dbg_caw_span_adjacent; echo 0 > $P/caw_span_n; echo $MARK > /dev/kmsg; echo knobs \$(cat $P/caw_span) \$(cat $P/dbg_caw_span_adjacent) \$(cat $P/caw_span_n)" | tr '\r' ' ')
echo "$A: $(echo "$got" | tr '\n' ' ')"
echo "$got" | grep -q "^$want" || abort "$A does not run this tree's build $want"
echo "$got" | grep -qE "^knobs 1 $ADJ 0 ?$" || abort "$A's knobs did not read back as caw_span=1 dbg_caw_span_adjacent=$ADJ caw_span_n=0"

ok=1; last=0; rise=1; done_rounds=0
for r in $(seq 1 "$ROUNDS"); do
    D=/mnt/shared/csa_${LABEL}_$r
    R=$(rsx 50 "$A" "umount /mnt/shared 2>/dev/null; mount -t mxfs $LUN /mnt/shared; echo mrc=\$?; mkdir -p $D; i=0; while [ \$i -lt $FILES ]; do echo \$i > $D/f\$i || break; i=\$((i+1)); done; echo made=\$i; sync; echo sync_rc=\$?; echo span_n=\$(cat $P/caw_span_n) adj_left=\$(cat $P/dbg_caw_span_adjacent)")
    src=$?
    echo "$R" > "$OUT/round_$r.txt"
    f() { echo "$R" | grep -ao "$1=[0-9-]*" | tail -1 | cut -d= -f2; }
    mrc=$(f mrc); made=$(f made); syncrc=$(f sync_rc); spn=$(f span_n); left=$(f adj_left)
    echo "ROUND r=$r ssh_rc=$src mrc=${mrc:-?} made=${made:-?}/$FILES sync_rc=${syncrc:-?} caw_span_n=${spn:-?} adj_left=${left:-?}"
    done_rounds=$r
    if [ "$src" != 0 ] || [ "${mrc:-1}" != 0 ] || [ "${made:-0}" != "$FILES" ] || [ "${syncrc:-1}" != 0 ]; then
        ok=0; break
    fi
    [ "${spn:-0}" -gt "$last" ] || rise=0
    last=${spn:-0}
done

boot1=$(rs 15 "$A" "cat /proc/sys/kernel/random/boot_id" | tail -1)
size1=$(timeout 10 sudo -n stat -c %s "$SER" 2>/dev/null)
case $size1 in ''|*[!0-9]*) abort "cannot read the size of $SER after the arm" ;; esac
# a console file that shrank was replaced: all of it is this arm's
from=$((off0 + 1)); [ "$size1" -ge "$off0" ] || from=1
timeout 10 sudo -n tail -c +"$from" "$SER" 2>/dev/null | tr -d '\r' > "$OUT/serial_$A.txt"
panic=$(grep -aE 'BUG:|kernel BUG|Oops|Kernel panic|RIP: 0010|scsi_alloc_sgtables| R15: | RAX: ' "$OUT/serial_$A.txt" | head -20)
rebooted=0; [ -n "$boot1" ] && [ "$boot1" != "$boot0" ] && rebooted=1
[ -z "$boot1" ] && rebooted=unread
if [ -n "$panic" ] || [ "$rebooted" = 1 ]; then
    echo "$panic" | sed 's/^/  serial | /'
    echo "RESULT: PANIC label=$LABEL adjacent=$ADJ A=$A rounds_run=$done_rounds rebooted=$rebooted serial_lines=$(echo "$panic" | grep -ac .) sgtables=$(grep -ac 'scsi_alloc_sgtables' "$OUT/serial_$A.txt") evidence=$OUT"
    exit 4
fi

rs 20 "$A" "dmesg | sed -n '/$MARK/,\$p' | grep -a 'P-DBG-CAW-SPAN-ADJACENT'" > "$OUT/adjacent_lines.txt"
nl=$(grep -ac 'P-DBG-CAW-SPAN-ADJACENT' "$OUT/adjacent_lines.txt")
v2=$(grep -ac 'vcnt=2 ' "$OUT/adjacent_lines.txt")
adj=$(grep -ao 'pfn=[0-9a-f]*,[0-9a-f]*' "$OUT/adjacent_lines.txt" | python3 -c '
import sys
n = 0
for l in sys.stdin:
    a, b = l.strip()[4:].split(",")
    n += int(b, 16) == int(a, 16) + 1
print(n)')
rs 15 "$A" "echo 0 > $P/dbg_caw_span_adjacent" > /dev/null
reach=$(( ADJ - ${left:-$ADJ} ))
SUM="label=$LABEL adjacent=$ADJ A=$A rounds=$done_rounds/$ROUNDS caw_span_n=${spn:-?} reached=$reach knob_lines=$nl vcnt2=$v2 adjacent_pairs=$adj rebooted=$rebooted"
if [ "$ok" != 1 ]; then
    echo "RESULT: FAIL $SUM -- round $done_rounds failed (round_$done_rounds.txt) evidence=$OUT"; exit 1
fi
if [ "${spn:-0}" = 0 ] || { [ "$ADJ" -gt 0 ] && [ "$reach" -le 0 ]; }; then
    echo "RESULT: VACUOUS $SUM -- no whole-page command answered, or the knob reached none evidence=$OUT"; exit 3
fi
if [ "$rise" != 1 ]; then
    echo "RESULT: VACUOUS $SUM -- a round made no whole-page command evidence=$OUT"; exit 3
fi
if [ "$ADJ" -gt 0 ] && { [ "$nl" = 0 ] || [ "$v2" != "$nl" ] || [ "$adj" != "$nl" ]; }; then
    echo "RESULT: FAIL $SUM -- a knob line shows a merged payload or non-adjacent pages (adjacent_lines.txt) evidence=$OUT"; exit 1
fi
echo "RESULT: PASS $SUM evidence=$OUT"
