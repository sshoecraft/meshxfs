#!/bin/bash
# sibling_sync.sh — make a sibling checkout (e.g. ~/src/mxfs-b) carry exactly
# this tree's sources, with a module and tools built from them there, so rig
# laps can run from it while laps from this tree keep loading this tree's
# mxfs.ko.  run.sh hands prep_node.sh the module of the checkout it runs from
# (the nodes see this host's ~/src as /src), so a lap started in the sibling
# loads the sibling's build.
#
# The sibling's own objects are never trusted.  The copy brings sources only
# and the build starts from `make clean`: an object newer than a source that
# rsync carried in with an older mtime is never rebuilt, and the module it
# links reports a srcversion naming sources it does not contain.  The
# sibling's evidence, loop state and memory stay its own.
#
# Usage: tools/sibling_sync.sh <sibling-dir> [marker-string]
#   marker-string  a string unique to the change under test; the built module
#                  must contain it (strings -a)
# Env: JOBS (default nproc)
# Output (last line): SIBLING <dir> sv=<srcversion> marker=<ok|MISSING|none>
# budget: the source copy takes seconds; a from-scratch build measured 3-5 min
# at -j$(nproc) (tools/scratch_build.sh).
set -u
DEST=${1:?usage: sibling_sync.sh <sibling-dir> [marker-string]}
MARK=${2:-}
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
JOBS=${JOBS:-$(nproc)}
[ -d "$DEST" ] || { echo "ABORT: $DEST is not a directory"; exit 1; }
DEST=$(cd -- "$DEST" && pwd)
[ "$DEST" != "$REPO" ] || { echo "ABORT: the sibling is this tree"; exit 1; }
[ -f "$DEST/Makefile" ] && [ -d "$DEST/xfs" ] || { echo "ABORT: $DEST does not look like an mxfs checkout"; exit 1; }
echo "=== sibling_sync $REPO -> $DEST $(date -u +%FT%TZ) ==="
rsync -a --delete \
  --exclude '*.o' --exclude '*.cmd' --exclude '*.ko' --exclude '*.mod' \
  --exclude '*.mod.c' --exclude 'modules.order' --exclude 'Module.symvers' \
  --exclude '.tmp_*' --exclude 'tests/evidence' --exclude '.ccloop' \
  --exclude '.ccmemory' --exclude '.git' --exclude '*.a' \
  --exclude 'bench.json' --exclude '.xfs_fio_baseline.*' \
  "$REPO/" "$DEST/" || { echo "ABORT: rsync rc=$?"; exit 1; }
T0=$(date +%s)
( cd "$DEST" && make clean ) > "$DEST/build_clean.log" 2>&1
( cd "$DEST" && make -j"$JOBS" modules ) > "$DEST/build_modules.log" 2>&1; rc=$?
echo "STAGE make_modules rc=$rc wall=$(( $(date +%s) - T0 ))s log=$DEST/build_modules.log"
[ $rc -eq 0 ] || { grep -n 'error:\|Error \|undefined' "$DEST/build_modules.log" | head -20; echo "ABORT: make modules failed"; exit 1; }
T1=$(date +%s)
( cd "$DEST" && make -j"$JOBS" tools ) > "$DEST/build_tools.log" 2>&1; rc=$?
echo "STAGE make_tools rc=$rc wall=$(( $(date +%s) - T1 ))s log=$DEST/build_tools.log"
[ $rc -eq 0 ] || { grep -n 'error:\|Error ' "$DEST/build_tools.log" | head -10; echo "ABORT: make tools failed"; exit 1; }
sv=$(modinfo -F srcversion "$DEST/mxfs.ko")
mk=none
if [ -n "$MARK" ]; then
    mk=ok; strings -a "$DEST/mxfs.ko" | grep -qF -- "$MARK" || mk=MISSING
fi
echo "warnings: $(grep -c 'warning:' "$DEST/build_modules.log")"
echo "SIBLING $DEST sv=$sv marker=$mk wall_total=$(( $(date +%s) - T0 ))s"
[ "$mk" != MISSING ]
