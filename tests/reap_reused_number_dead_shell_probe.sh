#!/bin/bash
# reap_reused_number_dead_shell_probe.sh — does the survivor's bucket sweep
# and reap act on its own stale shell of a reused inode number?
#
# Question (from the audit after D-ORPHAN-SCAN-ADOPTS-FREED-NUMBER-LEAVES-
# UNLINKED-BUCKET-ON-FREE-CORE): a shell the reload poisons keeps the dead
# incarnation's in-core mode, nlink and generation.  The survivor's bucket
# sweep (mxfs_survivor_sweep_bucket_ag) igets each member of a dead peer's
# bucket and queues a reap entry with the IN-CORE generation; the reap worker
# (mxfs_reap_worker) checks that generation against the same shell and nlink
# 0, then inactivates it as an adopted unlink.  If the survivor's cached copy
# of a member's number is a dead older incarnation, does the reap act on it,
# and does the platter come out consistent?
#
# Shape (two mounted nodes, A the peer that dies, B the survivor):
#   1. A creates f; B opens f; A unlinks f; B stats its descriptor (its copy
#      reads nlink 0) and closes it, keeping its shell cached; A frees f.
#   2. A creates files in the same directory until one takes f's number
#      (g, 64 KiB of data), removes the rest, holds g open and unlinks it:
#      g is a zombie on A's bucket under f's old number.
#   3. A's domain is destroyed.  B declares it dead, fences it, replays its
#      slice and sweeps its bucket, which holds g's number.
#   4. Cold check of the platter after B unmounts.
#
# READING RULES (written before the first lap):
#   VACUOUS  no file took f's number (reuse not reached), or B never swept
#            A's bucket (no P97-SWEEP-DONE), or B's sweep found the number
#            with no stale shell (no poison line naming it and no reap entry
#            with f's generation): the composition was not reached.
#   REACHED  B's log names g's number with f's generation in a reap entry or
#            a poison line during the sweep.
#   then:    chk_mxfs reports no ERROR -> this path survives the composition
#            on this run; any ERROR (FREE core, leaked or doubly owned blocks,
#            link count) -> a defect, recorded from its own lines.
#
# Budget (derived): prep 72-137 s measured + setup ~30 s + death detection
# ~35 s (17 heartbeat checks) + recovery 5-40 s + reap retry <= 30 s +
# unmount ~10 s + chk ~10 s => ~300 s; bound 400 s.
#
# Usage: tests/reap_reused_number_dead_shell_probe.sh <label> [A] [B] [group] [configuration]
set -u
LABEL=${1:?label}; A=${2:-test29}; B=${3:-test30}; GROUP=${4:-g2c}; CONF=${5:-2/net/mesh/direct}
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); cd "$REPO"
MXFS_FORCE_PREP=1 ./run.sh "$CONF" --group "$GROUP" prep_cluster > "tests/evidence/prep_rrnd_${LABEL}.log" 2>&1 ||
    { echo "ABORT: prep of $CONF on $GROUP failed (tests/evidence/prep_rrnd_${LABEL}.log)"; echo "RESULT: ABORT label=$LABEL stage=prep"; exit 2; }
SSH=tools/mxfs_sshpass.sh
. "$(dirname "$0")/lib/rig.sh"
export MXFS_NODE_LIST=${MXFS_NODE_LIST:-"$A $B"}
mxfs_dev_resolve "$B"; DEV=$MXFS_DEV_RESOLVED
MNT=${MXFS_MNT:-/mnt/shared}
HOST_IMG=$(tools/mxfs_host_image.sh "$B") || { echo "$HOST_IMG"; echo "RESULT: ABORT label=$LABEL stage=device"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_rrnd_${LABEL}
mkdir -p "$OUT"
fails=0
t0=$(date +%s)
waitfor() {  # <node> <mark> <pattern> <seconds> -> count once >= 1 or at the bound
    local i=0 c=0
    while [ $i -lt "$4" ]; do
        c=$(rs 20 "$1" "dmesg | sed -n \"/$2/,\\\$p\" | grep -aEc '$3'" | tr -dc '0-9')
        [ "${c:-0}" -ge 1 ] && break
        sleep 1; i=$((i+1))
    done
    echo "${c:-0}"
}

echo "=== reap_reused_number_dead_shell_probe label=$LABEL A=$A B=$B conf=$CONF out=$OUT $(date -u +%FT%TZ) ==="
want=$(modinfo mxfs.ko | awk '/^srcversion:/{print $2}')
for n in $A $B; do
    nsv=$(rs 15 "$n" "cat /sys/module/mxfs/srcversion" | tr -dc 'A-F0-9')
    [ "$nsv" = "$want" ] || { echo "ABORT: $n srcversion '$nsv' != tree '$want'"; echo "RESULT: ABORT label=$LABEL stage=build evidence=$OUT"; exit 2; }
done
MARK="RRND-$LABEL-$$"
for n in $A $B; do rs 12 "$n" "echo '$MARK' > /dev/kmsg" >/dev/null; done

# 1. B's stale nlink-0 shell of f
D="$MNT/.rrnd_$LABEL"
value_now_into x1 "$A" 30 "$OUT/x1.txt" '^[0-9]+$' "f's inode on A" "mkdir -p $D && dd if=/dev/urandom of=$D/f bs=4096 count=1 2>/dev/null && sync && stat -c %i $D/f"
value_now_into pb "$B" 20 "$OUT/hold_$B.txt" '^[0-9]+$' "the holder pid on $B" "nohup setsid sh -c 'echo \$\$ > /tmp/rrnd_hold.pid; exec 3<$D/f; exec sleep 300' >/dev/null 2>&1 & sleep 1; cat /tmp/rrnd_hold.pid"
value_now_into rv1 "$A" 30 "$OUT/rv1.txt" '^rc=' "A unlink f" "rm -f $D/f && sync && echo rc=0 || echo rc=1"; rv1=$(printf '%s\n' "$rv1" | sed -n 's/^rc=//p')
ck "A unlinked f" "$rv1" "0"
value_now_into bl "$B" 20 "$OUT/b_fstat.txt" '^links=' "B's view of f" "echo links=\$(stat -L -c %h /proc/$pb/fd/3 2>/dev/null)"
ck "B's copy of f reads nlink 0" "$bl" "links=0"
rs 15 "$B" "kill $pb 2>/dev/null; true" >/dev/null
fr=$(waitfor "$A" "$MARK" "P82-REM ino=$x1 " 30)
ck "A freed f (P82-REM ino=$x1)" "$([ "$fr" -ge 1 ] && echo yes || echo no)" "yes"
# B's generation for f, from the lines its reload and eviction print (a
# P74-GRANT gen= is the lock's grant counter, not the inode's)
g1=$(rs 15 "$B" "dmesg | sed -n \"/$MARK/,\\\$p\" | grep -aoE 'P-RELOAD-IDENTICAL ino=$x1 cc=[0-9]+ gen=[0-9]+|EVICT-RING-FLAG ino=$x1 incore_gen=[0-9]+' | head -1 | sed 's/.*gen=//'" | tr -dc '0-9')
echo "  INFO f ino=$x1, B's generation for it: ${g1:-unseen}"

# 2. a new file takes f's number on A, held open and unlinked
value_now_into gname "$A" 60 "$OUT/reuse.txt" '^(g[0-9]+|none)$' "the file that took f's number" "for i in \$(seq 0 31); do dd if=/dev/urandom of=$D/g\$i bs=65536 count=1 2>/dev/null; if [ \"\$(stat -c %i $D/g\$i)\" = $x1 ]; then hit=g\$i; break; fi; done; sync; for j in \$(seq 0 31); do [ \"g\$j\" = \"\${hit:-}\" ] || rm -f $D/g\$j; done; sync; echo \${hit:-none}"
echo "  INFO reuse: ${gname}"
if [ "$gname" = none ]; then
    echo "RESULT: VACUOUS label=$LABEL stage=reuse no file took ino $x1 evidence=$OUT"; exit 3
fi
value_now_into pa "$A" 20 "$OUT/hold_$A.txt" '^[0-9]+$' "the holder pid on $A" "nohup setsid sh -c 'echo \$\$ > /tmp/rrnd_hold.pid; exec 3<$D/$gname; exec sleep 300' >/dev/null 2>&1 & sleep 1; cat /tmp/rrnd_hold.pid"
value_now_into rv2 "$A" 30 "$OUT/rv2.txt" '^rc=' "A unlink g" "rm -f $D/$gname && sync && echo rc=0 || echo rc=1"; rv2=$(printf '%s\n' "$rv2" | sed -n 's/^rc=//p')
ck "A unlinked $gname (a zombie on A's bucket under ino $x1)" "$rv2" "0"
sleep 2

# 3. A dies; B recovers it and sweeps its bucket
MARK2="RRND2-$LABEL-$$"
rs 12 "$B" "echo '$MARK2' > /dev/kmsg" >/dev/null
echo "  INFO destroying $A at $(date -u +%T)"
timeout 30 virsh -c qemu:///system destroy "$A" > "$OUT/destroy.txt" 2>&1
sw=$(waitfor "$B" "$MARK2" 'P97-SWEEP-DONE' 150)
echo "  INFO B swept A's bucket: P97-SWEEP-DONE=$sw"
rs 15 "$B" "dmesg | sed -n \"/$MARK2/,\\\$p\" | grep -ac 'P89-REAP-DONE ino=$x1 \|P88-REAP-IGET-FAIL ino=$x1 '" > /dev/null
rp=$(waitfor "$B" "$MARK2" "P89-REAP-DONE ino=$x1 |P88-REAP-IGET-FAIL ino=$x1 |P82-REM ino=$x1 " 60)
sleep 3
window_into "$OUT/b_window.txt" "$B" 20 "$MARK"
echo "  INFO B's lines naming ino $x1 after the death:"
sed -n "/$MARK2/,\$p" "$OUT/b_window.txt" | grep -aE "ino=$x1[ ]|agino=$x1[ ]" | grep -avE 'buf_io|v5_bast' | head -30 | cut -c1-260 | sed 's/^/    /'
stale=$(sed -n "/$MARK2/,\$p" "$OUT/b_window.txt" | grep -aEc "(P88-REAP-RETRY ino=$x1 gen=${g1:-x}([^0-9]|$))|(XINCARN-POISON ino=$x1 )|(P977-RELOAD-EXPOSED-MISMATCH ino=$x1 )")
echo "  INFO reach: sweep=$sw reap_end=$rp stale_shell_lines=$stale"
for p in 'BUG:' 'Oops' 'blocked for more than' 'Shutting down filesystem'; do
    echo "  INFO B $p: $(grep -ac "$p" "$OUT/b_window.txt")"
done

# 4. the platter, cold
value_now_into um "$B" 90 "$OUT/um_$B.txt" '^rc=' "B umount" "timeout 60 umount $MNT; echo rc=\$?"; um=$(printf '%s\n' "$um" | sed -n 's/^rc=//p')
ck "B unmounted for the oracle" "$um" "0"
timeout 120 tools/chk_mxfs -v "$HOST_IMG" > "$OUT/chk.txt" 2>&1; chkrc=$?
[ "$chkrc" != 124 ] || { echo "ABORT: chk_mxfs ran out its 120 s bound"; echo "RESULT: ABORT label=$LABEL stage=capture evidence=$OUT"; exit 2; }
capture_require "$OUT/chk.txt" 'unlinked buckets|bucketed zombies' "chk_mxfs -v on the backing image"
errs=$(grep -ac 'ERROR' "$OUT/chk.txt")
echo "  INFO chk rc=$chkrc ERROR-lines=$errs"
grep -a 'ERROR' "$OUT/chk.txt" | head -6 | cut -c1-220 | sed 's/^/    /'
timeout 30 virsh -c qemu:///system start "$A" > /dev/null 2>&1
if [ "${sw:-0}" -lt 1 ] || [ "${stale:-0}" -lt 1 ]; then v=VACUOUS; elif [ "$errs" -eq 0 ] && [ "$fails" -eq 0 ]; then v=PASS; else v=FAIL; fi
echo "=== reap_reused_number_dead_shell_probe $LABEL: total=$(( $(date +%s) - t0 ))s out=$OUT ==="
echo "RESULT: $v label=$LABEL sweep=$sw stale_shell_lines=$stale chk_errors=$errs evidence=$OUT"
echo "NOTE: $A was destroyed and started again; prep before further rig work."
[ "$v" = PASS ]
