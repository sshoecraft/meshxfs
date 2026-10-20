#!/bin/bash
# zshell_lap_check.sh — per-lap counts, from each lap's OWN kernel-log mark, of
# the lines that judge D-CREATE-ON-ZOMBIE-SHELL-INHERITS-DEAD-LIFE-NBLOCKS on a
# tests/peer_last_closer_ab.sh lap.
#
# usage: scripts/zshell_lap_check.sh DIR [DIR...]
#   DIR  a peer_last_closer_ab evidence dir (<UTC>_peer_last_closer_<label>).
#
# A node's <node>_dmesg_stream.gz holds its whole kernel ring since the prep,
# and the ring survives the module reload, so it also carries the previous
# laps' lines: counting the whole stream credits a lap with its predecessor's
# events.  Every count here starts at the lap's own mark,
# PEER-LAST-CLOSER-<label>-<pid> (the harness writes it at the knob set), and
# the mark count is printed so a stream without its mark (0) or with two is
# visible rather than silently counted from the top or the wrong place.
#
# Columns per node:
#   marks      lines carrying this lap's mark (expect 1)
#   stale0/1   P-RECYCLE-DEADSHELL-STALE with guard=0 / guard=1
#   sanitize   P-RECYCLE-SANITIZE (either arm's reset of a dead shell)
#   inherited  P-CREATE-NBLOCKS-INHERITED (a create that kept a block count)
#   paired     inherited lines whose ino has a P-RECYCLE-DEADSHELL-STALE line
#              on this node in the preceding second (the guarded path)
#   unpaired   inherited lines with no such line: a second path into
#              xfs_inode_init with a block count; each is printed after the
#              node's count line as UNPAIRED <the line>
#   bail80a    RELOAD-VERIFY-BAIL at xfs_dinode_verify+0x80a (a reload that
#              found a core with blocks and no extents on the platter; the
#              offset is build A7E5F619's and 3AEA31FD's)
#   bailany    RELOAD-VERIFY-BAIL at any offset
#   corrupt    'Metadata corruption detected at xfs_dinode_verify'
#   sfv        P-SFV-FAIL
set -u
export LC_ALL=C
[ $# -ge 1 ] || { echo "usage: zshell_lap_check.sh DIR [DIR...]" >&2; exit 2; }
for d in "$@"; do
    d=${d%/}
    [ -d "$d" ] || { echo "not a directory: $d" >&2; continue; }
    label=${d##*_peer_last_closer_}
    for s in "$d"/*_dmesg_stream.gz; do
        [ -f "$s" ] || continue
        n=$(basename "$s" _dmesg_stream.gz)
        timeout 60 zcat -- "$s" 2>/dev/null | gawk -v mark="PEER-LAST-CLOSER-$label-" \
            -v lab="$label" -v node="$n" '
            index($0, mark) { marks++; on = 1 }
            !on { next }
            function ts() { return match($0, /^\[ *[0-9]+\.[0-9]+\]/) ? substr($0, RSTART + 1, RLENGTH - 2) + 0 : -1 }
            function ino() { return match($0, / ino=[0-9]+ /) ? substr($0, RSTART + 5, RLENGTH - 6) : "" }
            index($0, "P-RECYCLE-DEADSHELL-STALE ") {
                if ($0 ~ /guard=0/) s0++; else if ($0 ~ /guard=1/) s1++
                last[ino()] = ts() }
            index($0, "P-RECYCLE-SANITIZE ") { san++ }
            index($0, "P-CREATE-NBLOCKS-INHERITED ") {
                inh++; i = ino(); t = ts()
                if (i in last && t >= last[i] && t - last[i] <= 1.0) pair++
                else { unp++; ul[unp] = substr($0, 1, 300) } }
            index($0, "RELOAD-VERIFY-BAIL ") {
                bany++; if (index($0, "xfs_dinode_verify.part.0+0x80a")) b80++ }
            index($0, "Metadata corruption detected at xfs_dinode_verify") { cor++ }
            index($0, "P-SFV-FAIL ") { sfv++ }
            END { printf "%s %s marks=%d stale0=%d stale1=%d sanitize=%d inherited=%d paired=%d unpaired=%d bail80a=%d bailany=%d corrupt=%d sfv=%d\n",
                  lab, node, marks, s0, s1, san, inh, pair, unp, b80, bany, cor, sfv
                  for (k = 1; k <= unp; k++) print "UNPAIRED " ul[k] }'
    done
done
