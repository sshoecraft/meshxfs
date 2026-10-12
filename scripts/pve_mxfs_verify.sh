#!/bin/bash
# pve_mxfs_verify.sh — after a build leg on the physical pair, check the MXFS
# volume it ran on before anything reuses the device: both hosts list the whole
# tree (inode, type, link count, size, path) and the two listings must be
# identical, then both unmount (B then A, each bounded) and host A runs
# chk_mxfs -n on the device.  A leg's install times say nothing about whether
# the filesystem it left behind is consistent; a later leg that reformats the
# device destroys the only evidence.
#
# Usage: scripts/pve_mxfs_verify.sh <outdir> <mountpoint> <device>
# Env:   PVE_PAIR ("192.168.1.80 192.168.1.81"): host A (runs the check) then B
# Output: <outdir>/listing-<host>.txt, listing.diff, chk.txt; the last line
#         printed is "VERIFY PASS" or "VERIFY FAIL: <reasons>".  Exit 0 = PASS.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSHP="$REPO/tools/mxfs_sshpass.sh"
OUT=${1:?outdir}; MNT=${2:?mountpoint}; DEV=${3:?device}
read -r -a PAIR <<<"${PVE_PAIR:-192.168.1.80 192.168.1.81}"
mkdir -p "$OUT" || exit 1
on() { timeout "${3:-60}" "$SSHP" "$1" "$2" </dev/null 2>&1 | grep -avE '^Warning:'; return "${PIPESTATUS[0]}"; }
why=""

# Both listings at once, each with its own file and exit code.  A tree of a
# few hundred entries lists in well under a second; 60 s is a stalled mount.
for h in "${PAIR[@]}"; do
    ( on "$h" "set -o pipefail; cd $MNT && find . -xdev -printf '%i %y %n %s %P\n' | LC_ALL=C sort -k5" 60 \
        > "$OUT/listing-$h.txt"; echo $? > "$OUT/listing-$h.rc" ) &
done
wait
for h in "${PAIR[@]}"; do
    rc=$(cat "$OUT/listing-$h.rc")
    echo "$h: listing rc=$rc entries=$(wc -l < "$OUT/listing-$h.txt")"
    [ "$rc" = 0 ] || why+=" listing-rc($h)=$rc"
done
if diff "$OUT/listing-${PAIR[0]}.txt" "$OUT/listing-${PAIR[1]}.txt" > "$OUT/listing.diff"; then
    echo "listings identical"
else
    echo "listings differ: $(grep -c '^[<>]' "$OUT/listing.diff") lines"
    grep '^[<>]' "$OUT/listing.diff" | head -20
    why+=" listings-differ"
fi

# B then A, as the storage scripts unmount: one that hangs is a defect to
# report, never a reason to force it.
for h in "${PAIR[@]:1}" "${PAIR[0]}"; do
    r=$(on "$h" "if mountpoint -q $MNT; then timeout 120 umount $MNT; echo umount_rc=\$?; else echo umount_rc=not-mounted; fi" 150)
    echo "$h: $r"
    [[ "$r" == *umount_rc=0* || "$r" == *umount_rc=not-mounted* ]] || why+=" umount($h)"
done

# A check of a 120 GiB volume holding a few GiB reads well under 1 GiB of
# metadata over 1 GbE: about 10 s.  120 s is a stalled check, recorded as one.
if [ -z "$why" ]; then
    on "${PAIR[0]}" "timeout 120 chk_mxfs -n -v $DEV; echo chk_rc=\$?" 150 > "$OUT/chk.txt"
    crc=$(sed -n 's/^chk_rc=//p' "$OUT/chk.txt" | tail -1)
    echo "chk_mxfs rc=${crc:-none}"
    grep -aiE 'error|corrupt|bad |mismatch|dangling|orphan|fix' "$OUT/chk.txt" | head -20
    [ "${crc:-x}" = 0 ] || why+=" chk_mxfs-rc=${crc:-none}"
else
    echo "chk_mxfs not run: the volume did not quiesce cleanly on both hosts"
fi

if [ -z "$why" ]; then echo "VERIFY PASS"; exit 0; fi
echo "VERIFY FAIL:$why"
exit 1
