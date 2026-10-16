#!/bin/bash
#
# platform_lab.sh — borrow a pool LUN for one platform's verification set and
# write that platform's own lab file, ~/.config/mxfslab/lab.<platform>, the way
# tests/full_verify.sh does before its platform steps
#
# Usage: scripts/platform_lab.sh <platform>
#
# For running a platform's checks on their own (tests/buffered_write_pos_verify.sh
# <platform>, tests/packaged_round.sh <platform>) before or outside a
# full_verify run: each of them reads ~/.config/mxfslab/lab.<platform> when it
# exists.  The allocation outlives this script on purpose: tools/lun_pool.sh
# keeps an exited owner's allocation bound, and the next run on exactly this
# node set adopts it, so the lab file stays valid until a run names one of
# these nodes for another LUN.
#
# Binding logs every node of the set in to the LUN, so the set is held through
# the VM pool and started for the length of the allocation, then released.
#
set -u

PLAT="${1:?usage: platform_lab.sh <platform>}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 1
. "$HERE/tools/mxfs_lab.sh"
. "$HERE/tests/lib/runlock.sh"

# the site's own lab file, never a platform's (a lab.<platform> holds that set alone)
MXFS_LAB="$HOME/.config/mxfslab/lab"
export MXFS_LAB
LAB="$HOME/.config/mxfslab/lab.$PLAT"

set=$(lab_nodes "$PLAT" | tr ' ' '\n' | awk 'NF' | head -n 2 | tr '\n' ' ') \
    || { echo "platform_lab: no verification set for $PLAT in $MXFS_LAB" >&2; exit 2; }
[ -n "$set" ] || { echo "platform_lab: no verification set for $PLAT in $MXFS_LAB" >&2; exit 2; }
portal=$(lab_need storage portal) || exit 2

# shellcheck disable=SC2086  # one argument per node
vmhold_take "platform_lab $PLAT" $set || { echo "platform_lab: cannot hold [$set] in the VM pool" >&2; exit 2; }
# shellcheck disable=SC2086
tools/vm_pool.sh up $set || { echo "platform_lab: [$set] did not come up" >&2; exit 2; }
# shellcheck disable=SC2086
( setsid tools/vm_pool.sh release --after $$ $set </dev/null >/dev/null 2>&1 & )

# shellcheck disable=SC2086
line=$(tools/lun_pool.sh alloc --owner "$$" --what "platform_lab $PLAT" $set) \
    || { echo "platform_lab: no pool LUN for [$set]" >&2; exit 2; }
{ grep -E '^#|^addr|^dns|^qemu|^paths' "$MXFS_LAB"
  echo "storage portal=$portal target=$(sed -n 's/.* target=\([^ ]*\).*/\1/p' <<<"$line") lun=$(sed -n 's/.* dev=\([^ ]*\).*/\1/p' <<<"$line")"
  echo "nodes $PLAT=$(echo $set | tr ' ' ',')"; } > "$LAB"
echo "$line"
echo "platform_lab: wrote $LAB"
grep -E '^(storage|nodes) ' "$LAB"
