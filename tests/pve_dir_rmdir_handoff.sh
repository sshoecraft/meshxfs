#!/bin/bash
# pve_dir_rmdir_handoff.sh — does a host's removal of a subdirectory reach the
# platter when the directory's lock is taken from it straight afterwards?
#
# The lock-release drain's write-side backstop (P189-RELOG-BEHIND-DISK,
# xfs/xfs_mxfs_bast.c) refuses to re-log a directory whose in-core link count
# is below the platter's.  Across past runs it fired 183 times with the
# in-core changecount AHEAD of the platter and one fewer link: the node's own
# rmdir, judged "behind" (D-SAN-CAW-RELOG-BEHIND-DISK-INCORE-DIR-STALE).  This
# test drives exactly that: both hosts of the pair remove, list and recreate
# their own subdirectories of one shared shortform directory at once
# (tests/pve_dir_rmdir_loop.sh), then require
#   - no mkdir/rmdir error on either host,
#   - both hosts to list the directory as exactly a0..a3 b0..b3,
#   - no I/O error, hang, kernel warning, withdrawal or self-fence,
#   - scripts/pve_mxfs_verify.sh: identical whole-tree listings, both
#     unmounted, chk_mxfs -n clean.
# The verdict also says how often P189 was reached and with the changecount
# ahead: a clean run that never reached it measured nothing about it.
#
# Precondition: the volume is mounted on both hosts at MNT (for the SAN LUN:
# scripts/pve_mxfs_san_disk.sh up).  The volume is left unmounted.
#
# Usage: tests/pve_dir_rmdir_handoff.sh <label>
# Env:   PVE_PAIR ("192.168.1.80 192.168.1.81")  DUR (240 s of load)
#        MNT (/mnt/mxfssan)  DEV (scripts/pve_caw_lun.sh's by-path link)
# Output: tests/evidence/pve_dir_rmdir_handoff/<stamp>-<label>/; exit 0 = PASS.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSHP="$REPO/tools/mxfs_sshpass.sh"
LABEL=${1:?label}
read -r -a H <<<"${PVE_PAIR:-192.168.1.80 192.168.1.81}"
DUR=${DUR:-240}
MNT=${MNT:-/mnt/mxfssan}
DEV=${DEV:-/dev/disk/by-path/ip-192.168.1.166:3260-iscsi-iqn.2026-05.local.mxfs:pve-caw-01-lun-0}
EVID="$REPO/tests/evidence/pve_dir_rmdir_handoff/$(date -u +%Y%m%dT%H%M%SZ)-$LABEL"
mkdir -p "$EVID" || exit 1
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$EVID/verdict.txt"; }
on() { timeout "${3:-60}" "$SSHP" "$1" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^$'; return "${PIPESTATUS[0]}"; }
BAD='I/O error|blocked for more than|WARNING:|BUG:|Oops|Shutting down filesystem|P-WITHDRAW|RECOVERY_BLOCKED|self-fenc|corrupt|failed after [0-9]+ retries'
fail=0
D="$MNT/rd-$(date +%s)"
EXPECT="a0 a1 a2 a3 b0 b1 b2 b3"

declare -A T0
for h in "${H[@]}"; do
    T0[$h]=$(on "$h" "date +%s")
    [[ "${T0[$h]}" =~ ^[0-9]+$ ]] || { say "FAIL: cannot read the clock of $h"; exit 1; }
    m=$(on "$h" "findmnt -n -o FSTYPE $MNT")
    [ "$m" = mxfs ] || { say "FAIL: $MNT is not an mxfs mount on $h ($m)"; exit 1; }
    say "$h: build=$(on "$h" "cat /sys/module/mxfs/version /sys/module/mxfs/srcversion" | tr '\n' ' ')mnt=$MNT"
done
on "${H[0]}" "mkdir $D" || { say "FAIL: mkdir $D"; exit 1; }
say "load: ${DUR}s on $D, ${H[0]} as a0..a3, ${H[1]} as b0..b3"

# Both loops at once, each with its own output and exit code; the bound is
# the loop's own duration plus a minute for its last pass and the ssh.
i=0
for h in "${H[@]}"; do
    p=$([ "$i" = 0 ] && echo a || echo b)
    ( timeout $(( DUR + 60 )) "$SSHP" "$h" "bash -s -- $p $D $DUR" < "$REPO/tests/pve_dir_rmdir_loop.sh" \
        2>&1 | grep -av '^Warning:' > "$EVID/loop-$h.txt"; echo "${PIPESTATUS[0]}" > "$EVID/loop-$h.rc" ) &
    i=$(( i + 1 ))
done
wait
for h in "${H[@]}"; do
    rc=$(cat "$EVID/loop-$h.rc")
    say "$h loop rc=$rc: $(tail -1 "$EVID/loop-$h.txt")"
    [ "$rc" = 0 ] || fail=1
done

for h in "${H[@]}"; do
    got=$(on "$h" "ls $D" | tr '\n' ' ' | sed 's/ $//')
    if [ "$got" = "$EXPECT" ]; then say "$h lists $D as expected"
    else say "FAIL: $h lists $D as [$got], expected [$EXPECT]"; fail=1; fi
done

for h in "${H[@]}"; do
    on "$h" "journalctl -k --since @${T0[$h]} --no-pager -o short-iso" 120 > "$EVID/kmsg-$h.txt"
    nbad=$(grep -acE "$BAD" "$EVID/kmsg-$h.txt")
    n189=$(grep -ac 'P189-RELOG-BEHIND-DISK' "$EVID/kmsg-$h.txt")
    nahead=$(grep -ac 'P189-RELOG-BEHIND-DISK.*chg_ahead=1' "$EVID/kmsg-$h.txt")
    say "$h kernel log: $(wc -l < "$EVID/kmsg-$h.txt") lines, bad=$nbad, P189=$n189 (chg_ahead=$nahead)"
    grep -aE "$BAD" "$EVID/kmsg-$h.txt" | head -10 | cut -c1-240 | sed "s/^/  $h: /" | tee -a "$EVID/verdict.txt"
    grep -a 'P189-RELOG-BEHIND-DISK' "$EVID/kmsg-$h.txt" | head -3 | cut -c1-400 | sed "s/^/  $h: /" | tee -a "$EVID/verdict.txt"
    [ "$nbad" = 0 ] || fail=1
done

PVE_PAIR="${H[*]}" "$REPO/scripts/pve_mxfs_verify.sh" "$EVID/verify" "$MNT" "$DEV" > "$EVID/verify.log" 2>&1
say "$(tail -1 "$EVID/verify.log")"
grep -q '^VERIFY PASS' "$EVID/verify.log" || fail=1

if [ "$fail" = 0 ]; then say "VERDICT PASS $LABEL"; else say "VERDICT FAIL $LABEL"; fi
exit "$fail"
