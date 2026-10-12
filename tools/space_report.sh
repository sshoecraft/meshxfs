#!/bin/bash
#
# space_report.sh — where the space on clyde's root filesystem goes.
#
# The rig's LUN pool, the guest images, tests/evidence and everything else on
# this host share one filesystem (/dev/nvme0n1p2 on /), and the host preflight
# refuses every fleet run below 10 GB free.  This measures it without a scan
# from / (banned on this host: it hammers the large mounts): each top-level
# tree is sized by name, the largest are broken down two more levels, and the
# total is reconciled against df, so space held by something du cannot see —
# a root-only directory, a deleted file still open — shows up as a gap
# instead of going unreported.
#
# Usage: tools/space_report.sh [depth-2 drill count, default 6]
# Uses `sudo -n du` where it can (root-only trees such as /var/lib/libvirt);
# without sudo those are reported as unreadable.  Every du is bounded.
set -u
DRILL=${1:-6}
FS=/
DU_T=600
dev=$(findmnt -n -o SOURCE "$FS")
SUDO=""; sudo -n true 2>/dev/null && SUDO="sudo -n"
TMP=$(mktemp -d /tmp/space_report.XXXXXX)

echo "== $FS on $dev ($(date -u +%FT%TZ)), du as ${SUDO:+root}${SUDO:-$(id -un)}"
df -h "$FS" | tail -1
df -i "$FS" | tail -1

# Top-level entries of /, each sized alone, on this filesystem only (-x):
# /proc, /sys, other mounts are skipped by -x and by the mount check.
echo
echo "== top-level trees (du -x, each bounded ${DU_T}s)"
: > "$TMP/top"
for d in /*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    [ "$(findmnt -n -o SOURCE -T "$d")" = "$dev" ] || continue
    s=$(timeout "$DU_T" $SUDO du -xsk "$d" 2>/dev/null | cut -f1)
    echo "${s:-0} $d" >> "$TMP/top"
done
sort -rn "$TMP/top" | awk '{printf "%8.1f GiB  %s\n", $1/1048576, $2}'
top_kb=$(awk '{s+=$1} END {print s+0}' "$TMP/top")

# The largest trees, two levels down.
echo
echo "== the largest trees, two levels down (top 15 each)"
for d in $(sort -rn "$TMP/top" | head -"$DRILL" | awk '{print $2}'); do
    echo "-- $d"
    timeout "$DU_T" $SUDO du -xk --max-depth=2 "$d" 2>/dev/null | sort -rn | sed -n '2,16p' \
        | awk '{printf "%8.1f GiB  %s\n", $1/1048576, $2}'
done

# Deleted files still held open: their blocks count in df and in no du.
# Read through /proc/<pid>/fd links only (cmdline and maps can wedge here).
echo
echo "== deleted files still open (size from the fd's stat)"
: > "$TMP/del"
for fd in /proc/[0-9]*/fd/*; do
    t=$(readlink "$fd" 2>/dev/null) || continue
    case "$t" in *" (deleted)") ;; *) continue ;; esac
    sz=$(stat -L -c %s "$fd" 2>/dev/null) || continue
    [ "${sz:-0}" -gt 104857600 ] || continue
    p=${fd#/proc/}; p=${p%%/*}
    echo "$sz $p $(cat /proc/$p/comm 2>/dev/null) ${t% (deleted)}" >> "$TMP/del"
done
if [ -s "$TMP/del" ]; then
    sort -rn "$TMP/del" | awk '!seen[$4]++ {printf "%8.1f GiB  pid %s (%s)  %s\n", $1/1073741824, $2, $3, $4}'
else
    echo "  none over 100 MiB (as $(id -un); other users' fds are not readable without root)"
fi

used_kb=$(df -k --output=used "$FS" | tail -1 | tr -d ' ')
echo
awk -v u="$used_kb" -v t="$top_kb" 'BEGIN {
    printf "== df used %.1f GiB, du of the trees above %.1f GiB, not accounted for %.1f GiB\n",
           u/1048576, t/1048576, (u-t)/1048576 }'
echo "   (the gap is what du could not read, deleted-but-open files, and filesystem metadata)"
