#!/bin/bash
# dir_reload_child_inact.sh — D-DIR-RELOAD-CHILD-INACTIVATION-DEADLOCK:
# exercise a directory reload whose dcache shrink drops a stale child, and
# prove the shrink runs outside the directory's acquire.
#
# The hang (16/disk/caw/mpath path_fenced_return, 0.90.122): test7 acquired
# the shared directory after peers had changed it; the acquire's reload ended
# in shrink_dcache_parent(), which dropped test7's cached copy of the `LOCK`
# directory — an old incarnation of an inode number the mutex keeps
# recycling — and inactivated it synchronously, taking that inode's lock while
# the parent's acquire was still open.  test12 held the new `LOCK` (rmdir:
# child, then parent) and waited for the parent.  Each waited 480 s on the
# other.  0.90.123 queues the shrink to a per-directory work item that runs
# with no lock held.
#
# Shape: the lockers (every node but A) run the path load's mutex on S/LOCK —
# `mkdir S/LOCK && rmdir S/LOCK` — which frees and reallocates one inode
# number over and over.  A keeps a cached dentry on S/LOCK (`stat`) and keeps
# acquiring S (`ls`), so each acquire reloads S after a peer changed it and
# its shrink drops whatever stale LOCK copy A holds.  Every operation is
# timed on its node.
#
# Verdict (each one counted from a capture that crossed into this shell):
#   - the deferred path ran: P-DSHRINK-INACT >= 1 summed over the nodes (a
#     child inactivated from the shrink's worker).  Zero means this run did
#     not reach the case and proves nothing about it: FAIL, not PASS.
#   - no P-SYNC-INACT-SLOW stack runs through mxfs_dlm_reload_inode
#   - no operation took 15 s or more: P-ACQ-STUCK's own threshold for a lock
#     wait that is not contention.  A healthy cross-node handoff is
#     milliseconds; the hang was 480 s.
#   - no error but the mutex's legal EEXIST/ENOENT/ENOTEMPTY, and no shutdown
#
# Budget: WINDOW_S of workload (default 60) + probe arming and the kernel-log
# pull, ~2 s per node each => WINDOW_S + 15 + 4 x nodes.
#
# Usage: tests/dir_reload_child_inact.sh <label> <A> <locker> [locker ...]
#        env WINDOW_S (default 60)
set -u
LABEL=${1:?label}; A=${2:?reloader node}; shift 2
LOCKERS=("$@"); [ ${#LOCKERS[@]} -ge 1 ] || { echo "usage: $0 <label> <A> <locker> [locker ...]"; exit 2; }
WINDOW_S=${WINDOW_S:-60}
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); cd "$REPO"
SSH=tools/mxfs_sshpass.sh
MNT=${MXFS_MNT:-/mnt/shared}
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_drci_$LABEL
mkdir -p "$OUT"
. "$(dirname "$0")/lib/rig.sh"
fails=0
S="$MNT/.drci_$LABEL"
MARK="DRCI-$LABEL-$$"
STALL_MS=15000
NODES=("$A" "${LOCKERS[@]}")

echo "=== dir_reload_child_inact label=$LABEL A=$A lockers=${LOCKERS[*]} window=${WINDOW_S}s out=$OUT $(date -u +%FT%TZ) ==="
want=$(modinfo mxfs.ko | awk '/^srcversion:/{print $2}')
for n in "${NODES[@]}"; do
    nsv=$(rs 15 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$nsv" = "$want" ] || { echo "ABORT: $n srcversion '$nsv' != tree '$want'"; echo "RESULT: ABORT label=$LABEL stage=srcversion evidence=$OUT"; exit 2; }
    # the two probes the verdict counts are pr_debug sites: arm them and read
    # back how many are on, so a zero count cannot mean "never printed"
    measure "$n" 20 "$OUT/arm_$n.txt" '^ARMED [0-9]+$' "probe arming on $n" \
        "c=/proc/dynamic_debug/control; for f in P-DSHRINK-INACT P-SYNC-INACT-SLOW; do echo \"module mxfs format \$f +p\" > \$c; done; echo ARMED \$(grep -cE '=p.*(P-DSHRINK-INACT|P-SYNC-INACT-SLOW)' \$c)"
    armed=$(awk '/^ARMED/ {print $2}' "$OUT/arm_$n.txt")
    ckge "$n has both probe sites armed" "$armed" 2
    rs 12 "$n" "echo '$MARK' > /dev/kmsg" >/dev/null
done
# The parent must carry a HIGHER inode number than most LOCK incarnations.
# Two-inode locking goes in inode-number order, so rmdir takes the child
# before the parent only when the child's number is lower — the order of the
# hang (LOCK 33569536 under shared 92813250), and the only order in which a
# node holding LOCK can be waiting for the parent.  A parent at the bottom of
# AG 0 makes every rmdir lock the parent first and the deadlock cannot form.
# Where a new directory lands moves between mounts, so every node creates a
# candidate, the highest-numbered becomes S, and one LOCK from each locker
# (calibration) shows which of them lock child-first.  Up to four rounds,
# until at least one locker does.
below=0; round=0
while [ "$below" -lt 1 ] && [ "$round" -lt 4 ]; do
    round=$((round + 1)); below=0
    rs 30 "$A" "rm -rf $S ${S}_c*" >/dev/null
    for n in "${NODES[@]}"; do rs 20 "$n" "mkdir ${S}_c$n" >/dev/null; done
    rs 30 "$A" "best=\$(stat -c '%i %n' ${S}_c* | sort -n | tail -1 | cut -d' ' -f2); mv \$best $S && rm -rf ${S}_c* && echo SETUP_OK ino=\$(stat -c %i $S)" > "$OUT/setup.txt"
    grep -q '^SETUP_OK ino=[0-9]' "$OUT/setup.txt" || { echo "ABORT: setup on $A: $(cat "$OUT/setup.txt")"; echo "RESULT: ABORT label=$LABEL stage=setup evidence=$OUT"; exit 2; }
    S_INO=$(sed -n 's/^SETUP_OK ino=//p' "$OUT/setup.txt")
    echo "  INFO round $round: parent S ino=$S_INO"
    for n in "${LOCKERS[@]}"; do
        li=$(rs 20 "$n" "mkdir $S/LOCK && stat -c %i $S/LOCK; rmdir $S/LOCK" | tr -dc '0-9')
        echo "  INFO $n's LOCK ino=$li ($([ -n "$li" ] && [ "$li" -lt "$S_INO" ] && echo 'below the parent: child locked first' || echo 'above the parent'))"
        [ -n "$li" ] && [ "$li" -lt "$S_INO" ] && below=$((below + 1))
    done
done
ckge "at least one locker's LOCK sits below the parent (the hang's lock order)" "$below" 1

# one line per operation: <start_ms> <dur_ms> <op> rc=<n> [err=<text>]
LOOP_HEAD="end=\$(( \$(date +%s%3N) + ${WINDOW_S}000 )); n=0; op() { local t0=\$(date +%s%3N) e rc; e=\$(\"\$@\" 2>&1 >/dev/null); rc=\$?; local t1=\$(date +%s%3N); echo \"\$t0 \$((t1 - t0)) \$1 rc=\$rc\${e:+ err=[\$e]}\"; n=\$((n+1)); return \$rc; }"
for n in "${LOCKERS[@]}"; do
    rs $((WINDOW_S + 30)) "$n" "$LOOP_HEAD; while [ \$(date +%s%3N) -lt \$end ]; do op mkdir $S/LOCK && op rmdir $S/LOCK; done; echo \"LOOP_DONE ops=\$n\"" > "$OUT/ops_$n.txt" 2>&1 &
done
rs $((WINDOW_S + 30)) "$A" "$LOOP_HEAD; while [ \$(date +%s%3N) -lt \$end ]; do op stat $S/LOCK; op ls $S; done; echo \"LOOP_DONE ops=\$n\"" > "$OUT/ops_$A.txt" 2>&1 &
wait

for n in "${NODES[@]}"; do
    f="$OUT/ops_$n.txt"
    done_n=$(grep -ac '^LOOP_DONE' "$f")
    ck "$n's loop ran to its end and reported" "$done_n" 1
    ops=$(grep -ac ' rc=' "$f")
    slow=$(awk -v s=$STALL_MS '/ rc=/ && $2 ~ /^[0-9]+$/ && $2 >= s' "$f" | wc -l)
    maxms=$(awk '/ rc=/ && $2 ~ /^[0-9]+$/ && $2 > m {m = $2} END {print m + 0}' "$f")
    other=$(grep -a ' rc=[1-9]' "$f" | grep -avc 'File exists\|No such file\|Directory not empty')
    echo "  INFO $n ops=$ops max_ms=$maxms legal_races=$(grep -a ' rc=[1-9]' "$f" | grep -ac 'File exists\|No such file\|Directory not empty')"
    ckge "$n completed operations" "$ops" 1
    ck "$n: no operation took ${STALL_MS} ms or more" "$slow" 0
    ck "$n: no error but the mutex's EEXIST/ENOENT/ENOTEMPTY" "$other" 0
    [ "$other" -gt 0 ] && grep -a ' rc=[1-9]' "$f" | grep -av 'File exists\|No such file\|Directory not empty' | head -3 | sed 's/^/    /'
done

dshr_total=0
for n in "${NODES[@]}"; do
    measure "$n" 30 "$OUT/kmsg_$n.txt" '^KMSG_END$' "the kernel log on $n from the run marker" "dmesg | sed -n '/$MARK/,\$p'; echo KMSG_END"
    grep -aq "$MARK" "$OUT/kmsg_$n.txt" || { echo "ABORT: $n's kernel log no longer holds the run marker (ring rotated)"; echo "RESULT: ABORT label=$LABEL stage=kmsg-rotated node=$n evidence=$OUT"; exit 2; }
    k="$OUT/kmsg_$n.txt"
    dshr=$(cnt "$k" 'P-DSHRINK-INACT')
    slow_reload=$(grep -a -A40 'P-SYNC-INACT-SLOW' "$k" | grep -ac 'mxfs_dlm_reload_inode')
    stuck=$(cnt "$k" 'P-ACQ-STUCK')
    sd=$(cnt "$k" 'P-SESSION-POISON\|force-shutdown\|Internal error\|BUG:\|Oops\|hung_task\|blocked for more than')
    echo "  INFO $n P-DSHRINK-INACT=$dshr P-SYNC-INACT-SLOW=$(cnt "$k" 'P-SYNC-INACT-SLOW') P-ACQ-STUCK=$stuck max_dshrink_ms=$(grep -ao 'P-DSHRINK-INACT ino=[0-9]* ms=[0-9]*' "$k" | sed 's/.*ms=//' | sort -n | tail -1)"
    ck "$n: no synchronous inactivation stalled inside a directory reload" "$slow_reload" 0
    ck "$n: no shutdown, BUG, oops or hung task" "$sd" 0
    dshr_total=$((dshr_total + dshr))
done
ckge "the deferred shrink inactivated at least one child (the case was reached)" "$dshr_total" 1

rs 20 "$A" "rm -rf $S" >/dev/null
echo "RESULT: $([ $fails -eq 0 ] && echo PASS || echo FAIL) label=$LABEL dshrink_inact=$dshr_total fails=$fails evidence=$OUT"
exit $((fails > 0))
