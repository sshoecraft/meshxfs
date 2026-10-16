#!/bin/bash
#
# platform_verify.sh — one platform's verification steps on their own: the
# packaged round on each of the release matrix's 2-node direct configurations,
# then the hung-node test on each, exactly as tests/full_verify.sh runs them
# for that platform (its steps_of)
#
# Usage: tests/platform_verify.sh <platform> <version>
#
# For a platform being added to an open version (Ubuntu 26.04 in 0.90.130):
# full_verify.sh grades every released platform at the end and refuses a run
# that names one platform while the others have no run of the version, which
# is right for the release run and leaves no way to verify one new set before
# it.  This is that way.  The release still needs full_verify.sh.
#
# Needs: the platform's lab file ~/.config/mxfslab/lab.<platform> with its own
# pool LUN (scripts/platform_lab.sh <platform>) and the version's packages in
# dist/<version> with a SHA256SUMS they match (scripts/release.sh).
#
# Each harness enforces its own budget (tests/packaged_round.sh,
# tests/tcp_peer_freeze_death.sh); nothing here widens one.  The mounts are
# taken down before every step, as full_verify.sh does: the hung-node test
# ends remounted and the next round's mkfs refuses a mounted LUN.
#
# Log: tests/evidence/platform_verify_<version>_<platform>.log, one
# "=== rc=N: <step> ===" line per step.  Exit 0 only if every step passed.
#
set -u

PLAT="${1:?usage: platform_verify.sh <platform> <version>}"
V="${2:?usage: platform_verify.sh <platform> <version>}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 1
SSH="$HERE/tools/mxfs_sshpass.sh"
LAB="$HOME/.config/mxfslab/lab.$PLAT"
[ -f "$LAB" ] || { echo "no $LAB: run scripts/platform_lab.sh $PLAT first" >&2; exit 2; }
export MXFS_LAB="$LAB"
( cd "dist/$V" 2>/dev/null && sha256sum --quiet -c SHA256SUMS ) \
    || { echo "dist/$V has no packages matching its SHA256SUMS" >&2; exit 2; }
. "$HERE/tools/mxfs_lab.sh"
. "$HERE/tests/lib/runlock.sh"
SET=$(lab_nodes "$PLAT" | tr ' ' '\n' | awk 'NF' | head -n 2 | tr '\n' ' ')
[ "$(echo $SET | wc -w)" = 2 ] || { echo "$PLAT: its set in $LAB is [$SET], the steps need 2 nodes" >&2; exit 2; }
L="$HERE/tests/evidence/platform_verify_${V}_$PLAT.log"
: > "$L"

# shellcheck disable=SC2086  # one argument per node
vmhold_take "platform_verify $V $PLAT" $SET || { echo "cannot hold [$SET] in the VM pool" | tee -a "$L"; exit 2; }
# shellcheck disable=SC2086
tools/vm_pool.sh up $SET >> "$L" 2>&1 || { echo "[$SET] did not come up" | tee -a "$L"; exit 2; }
# shellcheck disable=SC2086
( setsid tools/vm_pool.sh release --after $$ $SET </dev/null >/dev/null 2>&1 & )

unmount_set() {
    local h
    for h in $SET; do
        timeout 75 "$SSH" "$(lab_addr "$h" 2>/dev/null || echo "$h")" \
            'for m in $(grep " mxfs " /proc/mounts | cut -d" " -f2); do timeout 60 umount $m; done; echo left=$(grep -c " mxfs " /proc/mounts)' \
            </dev/null 2>/dev/null | grep left= | sed "s/^/$h /"
    done
}

PMATRIX=$(python3 tools/configuration.py release-matrix --nodes 2 | grep '/direct$')
[ -n "$PMATRIX" ] || { echo "the release matrix has no 2-node direct configuration" | tee -a "$L"; exit 2; }
steps=()
for cfg in $PMATRIX; do steps+=("CONFIG=$cfg tests/packaged_round.sh $PLAT $V"); done
for cfg in $PMATRIX; do steps+=("CONFIG=$cfg PREP=$PLAT tests/tcp_peer_freeze_death.sh"); done

echo "=== platform_verify $PLAT $V set=[$SET] $(date -u +%FT%TZ) ===" | tee -a "$L"
failed=0
for step in "${steps[@]}"; do
    unmount_set >> "$L"
    echo "=== $PLAT: $step ===" >> "$L"
    bash -c "$step" >> "$L" 2>&1
    rc=$?
    echo "=== rc=$rc: $PLAT: $step ===" | tee -a "$L"
    [ "$rc" = 0 ] || failed=$((failed + 1))
done
unmount_set >> "$L"
echo "=== platform_verify $PLAT $V steps failed: $failed ===" | tee -a "$L"
[ "$failed" = 0 ]
