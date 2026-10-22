#!/bin/bash
# prun.sh — the criteria board on physical hosts that were set up the way a
# user sets them up, not by the rig.
#
# run.sh prepares its own clusters: it formats the device, loads the module
# with the rig's options and mounts.  A pair installed from the package and
# set up by docs/drbd-setup.md is already formed, its mount belongs to
# mxfs-drbd@mxfs, and re-preparing it would test the rig's setup instead of
# the user's.  So this never preps.  It checks that the cluster is live (every
# host mounted, DRBD Primary/Primary and UpToDate, one build loaded on all),
# records that as the run's cluster marker, and runs the board's rows against
# it as a run.sh group of its own: its own marker, node locks and board file,
# and the rig's other groups keep running beside it.
#
# Usage: scripts/prun.sh [test ...]       (default: every board row)
# Env:   PHYS_GROUP   lab-file group naming the hosts (default pvephys:
#                     pve1/pve2, ~/.config/mxfslab/lab `group` and `addr` lines)
#        PHYS_CONFIG  configuration (default 2/net/mesh/drbd)
#        PHYS_DEV     the shared device (default /dev/drbd0)
#        PHYS_RIG     rig tag naming this hardware's native-XFS yardstick
#                     (default pvephys: .xfs_fio_baseline.<shape>.pvephys.json)
#        PHYS_CRIT    board file (default data/criteria.<group>.json, started
#                     from data/criteria.json the first time)
#        PHYS_NFS_SRC clyde's tree, mounted at /src on a host that lacks it
#                     (default 192.168.1.166:/src; clyde exports it to the hosts)
# The rows run their harnesses from /src/mxfs on each host.
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSH="$REPO/tools/mxfs_sshpass.sh"
GROUP=${PHYS_GROUP:-pvephys}
CONFIG=${PHYS_CONFIG:-2/net/mesh/drbd}
DEV=${PHYS_DEV:-/dev/drbd0}
RIG=${PHYS_RIG:-pvephys}
CRIT=${PHYS_CRIT:-$REPO/data/criteria.$GROUP.json}
MNT=/mnt/shared
die() { echo "prun: $*"; exit 1; }

read -r -a NODES <<<"$("$REPO/tools/mxfs_lab.sh" group "$GROUP")" || die "no lab group $GROUP"
[ "${#NODES[@]}" -ge 1 ] || die "lab group $GROUP names no hosts"

# clyde's tree at /src on every host: an NFS mount, gone after a host's reboot
NFS_SRC=${PHYS_NFS_SRC:-192.168.1.166:/src}
for n in "${NODES[@]}"; do
    timeout 40 "$SSH" "$n" "mountpoint -q /src || { mkdir -p /src; timeout 20 mount -t nfs -o rw,vers=4.1,hard,timeo=600,retrans=2,tcp $NFS_SRC /src; }" </dev/null >/dev/null 2>&1
done

# the live cluster, read from every host
builds=""
for n in "${NODES[@]}"; do
    s=$(timeout 30 "$SSH" "$n" "echo \"src=\$(mountpoint -q /src && echo y) mnt=\$(awk '\$2 == \"$MNT\" && \$3 == \"mxfs\" {print \$1}' /proc/mounts) build=\$(cat /sys/module/mxfs/srcversion 2>/dev/null) role=\$(drbdadm role all 2>/dev/null | head -1) ds=\$(drbdadm dstate all 2>/dev/null | head -1)\"" </dev/null 2>/dev/null | grep -a '^src=' | tail -1)
    echo "$n: $s"
    case "$s" in *"src=y mnt=$DEV "*) ;; *) die "$n: /src not mounted or $DEV not mounted at $MNT" ;; esac
    case "$CONFIG" in */drbd)
        case "$s" in *"role=Primary/Primary ds=UpToDate/UpToDate"*) ;; *) die "$n: DRBD is not Primary/Primary UpToDate/UpToDate" ;; esac ;;
    esac
    b=$(sed -n 's/.* build=\([^ ]*\) .*/\1/p' <<<"$s")
    [[ "$b" =~ ^[0-9A-F]{23}$ ]] || die "$n: no usable srcversion ('$b')"
    builds="$builds $b"
done
[ "$(tr ' ' '\n' <<<"$builds" | grep -c . )" = "${#NODES[@]}" ] || die "a build is missing"
[ "$(tr ' ' '\n' <<<"$builds" | grep . | sort -u | wc -l)" = 1 ] || die "the hosts run different builds:$builds"
build=$(tr ' ' '\n' <<<"$builds" | grep . | head -1)

# the marker run.sh's filtered runs check: this cluster, formed outside run.sh
nl=$(IFS=,; echo "${NODES[*]}")
fsid=$(timeout 30 "$SSH" "${NODES[0]}" "blkid -o value -s UUID $DEV" </dev/null 2>/dev/null | grep -aE '^[0-9a-f-]{36}$' | tail -1)
MARKER="$REPO/.cluster_marker.$GROUP.json"
gen=$(( $(jq -r '.gen // 0' "$MARKER" 2>/dev/null || echo 0) + 1 ))
jq -n --argjson n "${#NODES[@]}" --arg d "$CONFIG" --arg s "$build" --arg nl "$nl" --arg dev "$DEV" \
      --arg rig "$RIG" --arg fsid "${fsid:-}" --argjson gen "$gen" --arg t "$(date -u +%FT%TZ)" \
    '{nodes:$n, configuration:$d, srcversion:$s, node_list:$nl, dev:$dev, rig:$rig, wwid:"none", fsid:$fsid, gen:$gen, iso:$t, formed_by:"package+guide (scripts/prun.sh)"}' \
    > "$MARKER" || die "could not write $MARKER"
echo "prun: marker $MARKER: $CONFIG on $nl, build $build, rig $RIG"

[ -s "$CRIT" ] || cp "$REPO/data/criteria.json" "$CRIT" || die "could not start $CRIT"

if [ "$#" -gt 0 ]; then
    TESTS=("$@")
else
    # every row the specification applies to this configuration: the manifest
    # alone leaves out the rows run.sh adds after it (alloc_witness, chk_clean,
    # crash_audit, ...)
    mapfile -t TESTS < <(python3 "$REPO/tools/criteria.py" rows --at "$CONFIG" 2>/dev/null \
        | cut -f3 | grep -vx prep_cluster)
    [ "${#TESTS[@]}" -gt 0 ] || die "the board lists no rows for $CONFIG"
fi
echo "prun: ${#TESTS[@]} row(s): ${TESTS[*]}"
cd "$REPO" || exit 1
BUDGETS="$REPO/tests/criteria/budgets.$RIG"
[ -s "$BUDGETS" ] && echo "prun: row budgets for this hardware from $BUDGETS: $(awk '!/^#/ && NF {printf "%s=%ss ", $1, $2}' "$BUDGETS")"
exec env MXFS_OWN_RIG=1 MXFS_DEV="$DEV" MXFS_CRIT="$CRIT" MXFS_WANT_SRCVER="$build" \
    MXFS_RIG_BUDGETS="$( [ -s "$BUDGETS" ] && echo "$BUDGETS" )" \
    MXFS_RIG_TAG="$RIG" MXFS_TEST_ENV="MXFS_RIG_TAG=$RIG ${MXFS_TEST_ENV:-}" \
    ./run.sh "$CONFIG" --group "$GROUP" "${TESTS[@]}"
