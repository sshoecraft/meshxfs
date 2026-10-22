#!/bin/bash
# mxfs_rig_tag.sh — which PHYSICAL RIG is this cluster on?
#
# Several measurements are only meaningful against a yardstick captured on the
# same hardware: the native-XFS fio baseline and the raw N-sharer ceiling are
# per-rig files, and scoring one rig's numbers against another's produces a
# confident verdict about the wrong machine.  It has happened: a 1 GbE iSCSI
# LUN's 109 MiB/s was scored against a local SCST/mpath rig's 820 MiB/s
# baseline and recorded as a 62% FAIL with no filesystem change behind it.
#
# The rig used to be inferred from HOW THE DEVICE HAPPENED TO BE SPELLED — a
# by-path name containing "qnap" resolved, /dev/sda did not, and the two are
# the same LUN.  So the identity of the hardware depended on which spelling
# whoever last prepped the cluster typed, and when it did not resolve the
# measurement was declined rather than scored.  This resolves it from the
# hardware itself, and everything that needs the answer asks here so there is
# one rule and not three.
#
# Order, strongest first:
#   1. MXFS_RIG_TAG              — an explicit override always wins.
#   2. .cluster_marker.json .rig — recorded at prep time by run.sh, which is
#                                  the moment the rig identity is actually
#                                  established.  Survives later invocations
#                                  that reuse the cluster without touching the
#                                  device.  Skipped when MXFS_RIG_TAG_FRESH=1:
#                                  the prep that is establishing the identity
#                                  must not read it back from the marker it is
#                                  about to replace, or a cluster moved to a
#                                  new LUN keeps the old rig's tag (it did: the
#                                  clyde SCST LUN was recorded as 'qnap' after
#                                  the QNAP was retired).
#   3. the device spelling       — MXFS_DEV or the marker's dev, for a by-path
#                                  name that names its vendor.
#   4. the LUN's own SCSI vendor — read from a prepped node.  This is the one
#                                  that cannot be defeated by a rename.
#
# Prints the tag and exits 0, or prints nothing and exits 1 when the rig cannot
# be established.  Callers must treat exit 1 as "do not score", never as "use
# whatever yardstick is lying around".
#
# Usage: tools/mxfs_rig_tag.sh [device]
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
# run.sh exports MXFS_MARKER: a rig-group run keeps a marker of its own.
MARKER="${MXFS_MARKER:-$REPO/.cluster_marker.json}"

mk() {  # mk <key> — one field out of the cluster marker, empty if absent
    [ -s "$MARKER" ] || return 0
    python3 - "$MARKER" "$1" <<'PY' 2>/dev/null
import json, sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], "") or "")
except Exception:
    print("")
PY
}

# A tag becomes part of a filename, so keep it to what a filename can hold
# without quoting.  A SCSI vendor string arrives space-padded ("QNAP    "), so
# trim before separating: squeezing spaces away instead of turning them into a
# separator would render "QNAP Lab 1" and "QNAPLab1" as the same rig.  `tr -cd`
# discards the trailing newline along with everything else outside the set, so
# it is re-supplied — a resolver that prints its answer without one runs into
# whatever is echoed next.
sanitise() {
    printf '%s' "$1" \
      | tr 'A-Z' 'a-z' \
      | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
      | tr -s ' _' '-' \
      | tr -cd 'a-z0-9-'
    echo
}

emit() { [ -n "${1:-}" ] && { sanitise "$1"; exit 0; }; return 0; }

# 1. explicit override
emit "${MXFS_RIG_TAG:-}"

# 2. recorded when the cluster was prepped
[ "${MXFS_RIG_TAG_FRESH:-0}" = 1 ] || emit "$(mk rig)"

# 3. a device name that carries the vendor
DEV="${1:-${MXFS_DEV:-}}"
[ -z "$DEV" ] && DEV=$(mk dev)
case "$DEV" in
    *qnap*) echo qnap; exit 0 ;;
esac

# 4. ask the hardware.  Whoever is holding the LUN can read the SCSI vendor
#    string out of sysfs; that is a property of the array, not of the path
#    anyone used to reach it.
#
#    WHERE it is read depends on which host this is.  The suite's detectors run
#    ON THE NODES (their results spool through /run/mxfs-suite), and a node has
#    no ssh credentials for its peers — the lab secrets live on the dev host
#    only.  A resolver that could only reach the hardware over ssh therefore
#    answered "unknown" in the one place the answer was needed, while sitting
#    on the very device it was asking about: a node reads it locally.
#
#    The dev host never reads it locally.  A device path here names a NODE's
#    device, and the same path on the dev host can be one of its own disks:
#    /dev/sda there is its boot disk, whose vendor is ATA.  The 0.90.134
#    capture gate did exactly that — a harness re-prepped the pair with the
#    path its node's live mount had (/dev/sda), run.sh recorded rig=ata, and
#    every later harness aborted "rig 'ata' declares no LUN".  So the dev host
#    always asks a node, and it is told apart by the credentials that let it.
[ -n "$DEV" ] || exit 1

drives_nodes() {  # this host holds the lab's node credentials (as tools/mxfs_sshpass.sh finds them)
    [ -r /tmp/.mxfs_pass ] && [ -s /tmp/.mxfs_pass ] && return 0
    "$REPO/tools/mxfs_secrets.sh" get node >/dev/null 2>&1
}

# What the host holding the device reads about it, run where the device is: by
# bash locally on a node, and on a node over ssh from the dev host (sent
# base64-encoded, so neither side quotes it).  $1 is the device.  Prints
# RIGVENDOR (the array's SCSI vendor), RIGDMI (the host's DMI sys_vendor) and,
# for a DRBD device, RIGDRBD=1.
#   - A partition has no `device` link of its own; the disk it sits on has.
#   - A device-mapper node (the dm-multipath map) has none either: its paths
#     are its slaves, and every path of one map is the same LUN, so the first
#     slave's vendor is the array's.
#   - A DRBD device has neither a `device` link nor slaves.  Its array is the
#     one under its backing disk, which drbdsetup's configuration names
#     (`device minor N;`, then `disk "<path>";` in the same volume), and a
#     replicated device is a rig of its own: every write it acknowledges has
#     reached both nodes' disks, so native XFS on it is not native XFS on the
#     LUN beneath it.
NODE_PROBE='
d=$(readlink -f "$1" 2>/dev/null) || exit 1
b=$(basename "$d")
case "$b" in
    drbd[0-9]*)
        m=${b#drbd}
        k=$(drbdsetup show 2>/dev/null | awk -v m="$m" '"'"'
            $1 == "device" && $2 == "minor" { gsub(/;/, "", $3); cur = $3 }
            $1 == "disk" && $2 ~ /^"\// && cur == m { gsub(/[";]/, "", $2); print $2; exit }'"'"')
        d=$(readlink -f "$k" 2>/dev/null) || exit 1
        b=$(basename "$d")
        echo RIGDRBD=1 ;;
esac
[ -r /sys/block/$b/device/vendor ] || b=$(echo "$b" | sed "s/[0-9]*\$//")
case "$b" in
    dm-*) b=$(ls /sys/block/$(basename "$d")/slaves 2>/dev/null | head -1) ;;
esac
echo "RIGVENDOR=$(cat /sys/block/$b/device/vendor 2>/dev/null)"
echo "RIGDMI=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)"
'

# 5. ...and the path to it, when the path is a different machine.  The vSphere
#    guests reach the very same SCST LUN as the qemu rig, so the array's vendor
#    string is identical, but through in-guest iSCSI across nested ESXi: native
#    XFS measured 108 MiB/s sequential write there against the qemu rig's
#    ~2 GB/s.  Scoring one against the other's yardstick is the cross-rig
#    comparison this resolver exists to prevent, so a node that is a VMware
#    guest carries "-vmware" after the vendor.  QEMU guests and physical hosts
#    keep the vendor alone, so every tag recorded before this stays valid.
platform_suffix() {  # platform_suffix <dmi sys_vendor>
    case "$1" in
        "VMware, Inc."*) echo "-vmware" ;;
    esac
}

if ! drives_nodes; then
    [ -b "$(readlink -f "$DEV" 2>/dev/null)" ] || exit 1
    answer=$(bash -c "$NODE_PROBE" probe "$DEV" 2>/dev/null)
else
    # MXFS_RIG_NODE first: the prep that establishes the identity may be
    # writing a marker for the first time (a new rig group's), and a marker
    # that does not exist yet names no node to ask.
    NODE=${MXFS_RIG_NODE:-$(mk node_list | cut -d, -f1)}
    [ -n "$NODE" ] && [ -x "$REPO/tools/mxfs_sshpass.sh" ] || exit 1
    answer=$(timeout 25 "$REPO/tools/mxfs_sshpass.sh" "$NODE" \
        "echo $(printf '%s' "$NODE_PROBE" | base64 -w0) | base64 -d | bash -s -- '$DEV'" 2>/dev/null)
fi
vendor=$(printf '%s\n' "$answer" | sed -n 's/^RIGVENDOR=//p' | head -1)
vendor=$(sanitise "${vendor:-}")
[ -n "$vendor" ] || exit 1
grep -q '^RIGDRBD=1' <<<"$answer" && vendor="$vendor-drbd"
echo "$vendor$(platform_suffix "$(printf '%s\n' "$answer" | sed -n 's/^RIGDMI=//p' | head -1)")"
