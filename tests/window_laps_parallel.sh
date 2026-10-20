#!/bin/bash
#
# window_laps_parallel.sh — the flake-window laps of several configurations,
# each configuration's laps one after another on its own rig group, the
# groups side by side.
#
# tests/release_verify_chain.sh runs window laps itself, but one at a time
# across every configuration: at 0.90.131 the boards needed up to ten laps of
# a dozen rows at each of five configurations, which serially is most of a day
# with the rest of the rig idle.  The groups share no node, so their laps can
# run at once, as the chain's own board waves do.
#
# Usage: tests/window_laps_parallel.sh <label> <configuration>:<row>[,<row>...]:<count>@<group> [...]
#   The counts come from tools/window_laps.py (10-k for a row whose newest
#   genuine FAIL is at window index k), never guessed.  Each lap is
#   tests/board_4node_chain.sh w<slug><i>_<label> <configuration>:<rows>@<group>,
#   so the rows' cells and windows are the board's own.  A chk_clean lap also
#   runs alloc_witness first: chk_clean's release verdict needs a coverage
#   witness sealed under the same run id.
#   PF_KEEP_KMSG=1 is exported, so a passing path row keeps its kernel logs.
#   Specs joined by '+' form one lane and run one after another: the way to
#   give two configurations the same group, or groups that share nodes (g16
#   and g4), without their laps colliding.
#
# Every run.sh enforces its own per-row budgets, so nothing here wraps a lap
# in a timeout.  A lap's verdict does not stop its configuration's laps: the
# next lap's prep restores the group, and every failure is one more run to read.
#
# Logs: tests/evidence/window_<label>_<slug>.log, one line per lap with its rc,
# then the configuration's rows as tools/criteria.py reads them.
#
# Launch it detached (nohup setsid ... &) with its output in a file.
set -u
LABEL=${1:?label}; shift
[ "$#" -gt 0 ] || { echo "usage: $0 <label> <configuration>:<rows>:<count>@<group> ..."; exit 2; }
cd "$(dirname "$0")/.." || exit 1
export PF_KEEP_KMSG=1
for lane in "$@"; do
    for spec in ${lane//+/ }; do
        [[ "$spec" =~ ^([0-9]+/[a-z]+/[a-z]+/[a-z]+):([a-z0-9_,]+):([0-9]+)@(g[0-9a-z]+)$ ]] \
            || { echo "malformed spec '$spec'"; exit 2; }
    done
done
runs() {  # <configuration> <rows> <count> <group>
    local cfg=$1 rows=$2 count=$3 group=$4 i rc slug log
    slug=${cfg//\//-}
    log=tests/evidence/window_${LABEL}_${slug}.log
    case ",$rows," in *,chk_clean,*) case ",$rows," in *,alloc_witness,*) ;; *) rows="alloc_witness,$rows" ;; esac ;; esac
    # dirent_type_integrity judges the window dirent_durability stamps
    # (MXFS_DIRENT_WINDOW, tests/suite/manifest P6 before P8); alone it fails
    # 'no MXFS_DIRENT_WINDOW marker' (4/disk/caw/mpath, lap 1 of r131a)
    case ",$rows," in *,dirent_type_integrity,*) case ",$rows," in *,dirent_durability,*) ;; *) rows="dirent_durability,$rows" ;; esac ;; esac
    echo "=== window $LABEL $cfg@$group rows=$rows laps=$count $(date -u +%FT%TZ) sv=$(modinfo -F srcversion mxfs.ko) ===" >> "$log"
    for ((i = 1; i <= count; i++)); do
        tests/board_4node_chain.sh "w${slug}${i}_$LABEL" "$cfg:$rows@$group" > /dev/null 2>&1
        rc=$?
        echo "lap $i/$count rc=$rc $(date -u +%FT%TZ)" >> "$log"
        python3 tools/criteria.py "$cfg" | grep -E "^Total|${rows//,/|}" | cut -c1-160 >> "$log"
    done
    echo "=== done $cfg $(date -u +%FT%TZ) ===" >> "$log"
}
pids=()
for lane in "$@"; do
    (
        for spec in ${lane//+/ }; do
            [[ "$spec" =~ ^([0-9]+/[a-z]+/[a-z]+/[a-z]+):([a-z0-9_,]+):([0-9]+)@(g[0-9a-z]+)$ ]]
            runs "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
        done
    ) &
    pids+=($!)
    # the groups' preps reconfigure the target one after another, not at once
    sleep 20
done
for p in "${pids[@]}"; do wait "$p"; done
echo "WINDOW_LAPS_DONE $LABEL $(date -u +%FT%TZ)"
