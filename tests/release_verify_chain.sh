#!/bin/bash
#
# release_verify_chain.sh — every rig step a release must pass, in order, on
# one module, detached: the flake-window laps a board's genuine failures still
# need, the full verification at the claimed node count, then the boards of
# every smaller released node count (with their own window laps first) on the
# same module, so each smaller claim is re-earned at the version being
# released.
#
# Usage: [CLAIM=N] tests/release_verify_chain.sh VERSION
#
# Read from the environment:
#   CLAIM   (default 4)  the node count the release claims
#   LAPS    (default none)  window laps, each "<configuration>:<row>[,<row>...]:<count>",
#           e.g. "4/net/mesh/direct:chk_clean:2": <count> laps of
#           tests/board_4node_chain.sh w<slug><i>_V <configuration>:<rows>.
#           Laps at the claimed node count run first; laps at a smaller count
#           run before that count's boards.
#   FULL    (default 1)  NODES=CLAIM tests/full_verify.sh VERSION — the clean
#           build, the release matrix's boards at the claimed node count, the
#           packages unless dist/VERSION holds them, every platform's packaged
#           round and hung-node test on each configuration, sVirt on RHEL
#   LOWER   (default: the release matrix's node counts below CLAIM, largest
#           first — "8 4 2" under CLAIM=16, "2" under CLAIM=4)  every count's laps, and
#           then the boards of every configuration of the release matrix at
#           every one of those counts (tools/configuration.py release-matrix
#           --nodes <count>): the i-th configuration at <count> on rig group
#           g<count>, the next on g<count>b, each on a pool LUN of its own,
#           side by side in waves of groups that share no node
#           (tests/board_4node_chain.sh bL<wave>_V), once the host preflight
#           passes after the groups' power-up.  The boards come last so their
#           read-back sees every lap
#   POWER, PLATFORM_GROUPS  passed on to tests/full_verify.sh, which documents
#           them.  With POWER=1 the chain also starts with every platform set
#           off and the rig's CLAIM nodes up, so the laps and the boards run
#           on a host holding nothing else.
#
# The lap counts are derived from the board, never guessed: a row whose newest
# genuine failure sits at window index k (0 = the live run, 11-run window,
# tools/criteria.py) reads PASS again only after 11-k more runs of that row,
# and the board run that ends each half is one of them.  So a row at k needs
# 10-k laps here before its board.  Derived 2026-09-29 for 0.90.17: 4/net/mesh/direct
# chk_clean k=6 with two chain laps still to land ->
# 4/net/mesh/direct:alloc_witness,chk_clean:2 (the four-node quiesce row and
# the witness its release verdict needs under one run id); 2/net/mesh/direct
# fio_perf k=3 -> 2/net/mesh/direct:fio_perf,guard_census:7; 2/disk/caw/direct
# crash_audit k=2 -> 2/disk/caw/direct:alloc_witness,chk_clean,crash_audit:8.
#
# Every run.sh enforces its own per-row budget and full_verify.sh its own
# per-step bounds, so nothing here wraps a step in a timeout.  A failing step
# does not stop the chain: each step's own prep restores the fleet, and one
# run should show every failure.  What does stop it is a step that could not
# start (missing script, malformed LAPS): that is a chain defect, not a
# measurement.
#
# Log: tests/evidence/release_verify_<VERSION>.log — each step ends with
# "=== rc=N: <step> ===", and the last line is RELEASE_CHAIN_DONE.  The
# sub-steps keep their own logs (board_<N-class-method-attach>_<label>.log,
# full_verify_<VERSION>*.log).
#
# Launch it detached with its output in a file (nohup setsid ... &): a chain
# started as a tool's background task is killed with the session that started
# it, and a board killed mid-row finalizes that row ABORTED.
#
set -u
V="${1:?usage: [CLAIM=N] tests/release_verify_chain.sh VERSION}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 1
EV="$HERE/tests/evidence"
mkdir -p "$EV"
L="$EV/release_verify_$V.log"
CLAIM="${CLAIM:-4}"
LAPS="${LAPS:-}"
FULL="${FULL:-1}"
POWER="${POWER:-0}"
export POWER
[[ "$CLAIM" =~ ^[0-9]+$ ]] && [ "$CLAIM" -ge 2 ] || { echo "CLAIM must be an integer >= 2 (got '$CLAIM')" | tee -a "$L"; exit 2; }
# table_boards [N]: every configuration the release table grades by its board
# (data/release_table.json, the rows tools/release_status.py reads), at node
# count N or all.  The release matrix alone left out the TCP configurations
# released earlier (8/16 net/mesh/direct, 2-16 net/mesh/mpath), whose rows the
# table still turns red on a build they never ran on.
#
# A configuration this version does not claim (data/configurations.json
# released_earlier) is left out while a record that crosses the release bar
# reaches it (tools/defects.py <configuration> --release): its row reads Not
# ready on that record whatever its board says, so the board cannot change the
# release.  0.90.131's B0D2 chain spent waves 3-5, about three hours, on the
# 4/8/16 net/mesh boards the open D-TCP-4NODE-NOQUEUE-TRY-WAITS-9S-ON-FULL-
# LEDGER-PAGE-CREATES-STALL already held back.  ALL_BOARDS=1 runs them anyway.
table_boards() {
    ALL_BOARDS="${ALL_BOARDS:-0}" python3 -c 'import json, os, sys
sys.path.insert(0, "tools")
import defects
n = sys.argv[2] if len(sys.argv) > 2 else ""
earlier = json.load(open("data/configurations.json")).get("released_earlier", {})
queue = defects.load()["defects"]
def held_back(c):
    if os.environ.get("ALL_BOARDS") == "1" or c not in earlier:
        return False
    nodes, selector, platform = defects.parse_at(c)
    return any(str(e.get("impact", "")).lower() != "noblock" and defects.blocks(e, nodes, selector, platform)
               for e in queue)
seen = []
for row in json.load(open(sys.argv[1]))["rows"]:
    if "boards" not in row:
        continue
    for c in row["configs"]:
        if c not in seen and (not n or c.split("/")[0] == n) and not held_back(c):
            seen.append(c)
print("\n".join(seen))' data/release_table.json "$@"
}
if [ -z "${LOWER+set}" ]; then
    # every node count the release table's boards name below the claim, largest first
    LOWER=""
    for n in $(table_boards | cut -d/ -f1 | sort -rnu); do
        [ "$n" -lt "$CLAIM" ] && LOWER="$LOWER $n"
    done
fi
for s in tests/board_4node_chain.sh tests/full_verify.sh scripts/lab_power.sh run.sh; do
    [ -x "$s" ] || { echo "$(date -u +%FT%TZ) chain defect: $s is not executable; nothing run" | tee -a "$L"; exit 2; }
done
for spec in $LAPS; do
    [[ "$spec" =~ ^[0-9]+(/[a-z]+){3}:[a-z0-9_,]+:[0-9]+$ ]] \
        && python3 tools/configuration.py parse "${spec%%:*}" >/dev/null \
        || { echo "$(date -u +%FT%TZ) chain defect: LAPS entry '$spec' is not <configuration>:<rows>:<count>; nothing run" | tee -a "$L"; exit 2; }
done

step() {  # step <name> <command...>: run it, log its output and rc
    local name=$1
    shift
    echo "=== $(date -u +%FT%TZ) $name: $* ===" | tee -a "$L"
    "$@" >> "$L" 2>&1
    local rc=$?
    echo "=== rc=$rc: $name ($(date -u +%FT%TZ)) ===" | tee -a "$L"
    return $rc
}

SETTLE_BUDGET=120   # a set of guests boots and logs in within ~40 s; the burst itself lasts seconds
wait_host_settled() {  # until the host preflight passes, at most SETTLE_BUDGET s
    local t0=$SECONDS out="$EV/release_verify_${V}_preflight.out"
    while :; do
        if scripts/clyde_preflight.sh > "$out" 2>&1; then
            tail -1 "$out"
            return 0
        fi
        if [ $((SECONDS - t0)) -ge "$SETTLE_BUDGET" ]; then
            grep -aE 'FAIL|clyde_preflight:' "$out"
            return 1
        fi
        sleep 10
    done
}

laps_at() {  # laps_at <nodes>: every LAPS entry for that node count, in order
    local want=$1 spec cfg n rows count i
    for spec in $LAPS; do
        IFS=: read -r cfg rows count <<<"$spec"
        n=${cfg%%/*}
        [ "$n" = "$want" ] || continue
        for ((i = 1; i <= count; i++)); do
            step "w $cfg lap $i/$count" tests/board_4node_chain.sh "w${cfg//\//-}${i}_$V" "$cfg:$rows"
            python3 tools/criteria.py "$cfg" | grep -E "^Total|${rows//,/|}" | cut -c1-160 >> "$L"
        done
    done
}

echo "=== release_verify_chain $V $(date -u +%FT%TZ) CLAIM=$CLAIM LAPS=[$LAPS] FULL=$FULL LOWER=[$LOWER ] POWER=$POWER ===" | tee -a "$L"
# What the host actually spends, every 5 s for the whole chain, next to the
# step lines in $L that say which stage was running: how far the stages can
# overlap is decided from this, not from the vCPUs the guests were given.
# Anything else running on clyde shows up here too.
vmstat -w -t 5 > "$EV/release_verify_hostcpu_$V.log" 2>&1 &
HOSTCPU=$!
trap 'kill $HOSTCPU 2>/dev/null' EXIT
# group_of <count> <i>: the rig group the i-th configuration at <count> runs on
# (g<count>, g<count>b, g<count>c ... for as many as the lab file names).  A
# matrix with more configurations at a count than the rig has groups wraps
# around: tests/board_4node_chain.sh runs the boards that share a group one
# after another.
group_of() {
    local n=0 g
    while g=g$1; [ "$n" -gt 0 ] && g=g$1$(printf "\\$(printf %o $((97 + n)))"); [ "$(tools/mxfs_lab.sh group "$g" 2>/dev/null | wc -w)" = "$1" ]; do n=$((n + 1)); done
    [ "$n" -gt 0 ] || { echo "g$1"; return; }
    n=$(($2 % n))
    g=g$1; [ "$n" -gt 0 ] && g=g$1$(printf "\\$(printf %o $((97 + n)))")
    echo "$g"
}
# With POWER=1 every stage starts from a host holding only what it uses: a
# guest left up from the stage before (a platform set is 8 of them) is memory
# and CPU the boards do not get.  RIG_MAX is the highest rig node any group
# names.
RIG_MAX=$(tools/mxfs_lab.sh groups | while read -r g; do tools/mxfs_lab.sh group "$g"; done | tr ' ' '\n' | sed -n 's/^test//p' | sort -n | tail -1)
if [ "$POWER" = 1 ]; then
    # every set data/platforms.json releases, as tests/full_verify.sh reads it
    # shellcheck disable=SC2046  # one argument per platform
    step "platform sets off" scripts/lab_power.sh down $(python3 -c 'import json, sys; d = json.load(open(sys.argv[1]))["platforms"]; print(" ".join(k for k, v in d.items() if v["status"] == "released"))' data/platforms.json)
    step "rig off" scripts/lab_power.sh down "rig:${RIG_MAX:-$CLAIM}"
    [ -n "$LAPS" ] && step "rig up" scripts/lab_power.sh up "rig:$CLAIM"
fi
laps_at "$CLAIM"
# SIDE_BY_SIDE=1 (default): the claimed count's boards join the smaller
# counts' boards in ONE side-by-side step, and full_verify runs only its build
# before it and its packages and platforms after it.  At 2 vCPUs and 2.5 GiB
# per rig guest, 8+8+4+4+2+2 = 28 guests are 56 vCPUs on this 56-core host
# and ~70 GiB of its 94.  SIDE_BY_SIDE=0 keeps the stages apart: the claimed
# count's suites inside full_verify, then the smaller counts' boards.
SIDE_BY_SIDE="${SIDE_BY_SIDE:-1}"
together=0
[ "$FULL" = 1 ] && [ "$SIDE_BY_SIDE" = 1 ] && together=1
if [ "$together" = 1 ]; then
    NODES=$CLAIM STEPS=build step "full_verify nodes=$CLAIM build" tests/full_verify.sh "$V"
elif [ "$FULL" = 1 ]; then
    NODES=$CLAIM step "full_verify nodes=$CLAIM" tests/full_verify.sh "$V"
fi
# The laps and boards deploy the tree's mxfs.ko, not the clean copy the build
# step made, so a tree whose module was not rebuilt after the last source edit
# would have every step below verify a module that does not ship (0.90.131's
# first chain did, on its first lap).  srcversion depends only on the source:
# the tree's module must carry the clean build's.
if [ "$FULL" = 1 ]; then
    clean_sv=$(grep -a -o -E "clean_build_rc=0 version=$V srcversion=[0-9A-F]+" "$EV/full_verify_$V.log" 2>/dev/null | tail -n 1 | sed 's/.*srcversion=//')
    tree_sv=$(modinfo -F srcversion mxfs.ko 2>/dev/null)
    if [ -z "$clean_sv" ] || [ "$clean_sv" != "$tree_sv" ]; then
        echo "$(date -u +%FT%TZ) chain defect: the tree's mxfs.ko is srcversion '$tree_sv', the clean build's is '$clean_sv'; run make modules in the tree, then this chain again; nothing more run" | tee -a "$L"
        exit 2
    fi
fi
counts="$LOWER"
[ "$together" = 1 ] && counts="$CLAIM $LOWER"
boards=(); sets=(); cfgs=()
for n in $counts; do
    [ "$n" = "$CLAIM" ] || laps_at "$n"
    i=0
    for cfg in $(table_boards "$n"); do
        g=$(group_of "$n" "$i")
        [ "$(scripts/../tools/mxfs_lab.sh group "$g" 2>/dev/null | wc -w)" = "$n" ] \
            || { echo "$(date -u +%FT%TZ) chain defect: $cfg needs rig group $g of $n nodes in the lab file" | tee -a "$L"; exit 2; }
        boards+=("$cfg@$g"); sets+=("group:$g"); cfgs+=("$cfg")
        i=$((i + 1))
    done
done
if [ "${#boards[@]}" -gt 0 ]; then
    if [ "$POWER" = 1 ]; then
        step "rig off" scripts/lab_power.sh down "rig:${RIG_MAX:-$CLAIM}"
        step "board groups up" scripts/lab_power.sh up "${sets[@]}"
    fi
    # Guests booting put ~45 kernel lines/s on clyde for a few seconds (SCST
    # session threads, bridge ports), over the host preflight's 40/s gate, and
    # a run.sh that starts inside that burst is refused: 0.90.107's
    # 2/disk/caw/direct board never ran.  No board starts before the gate
    # passes.
    step "host settled" wait_host_settled
    # Boards run side by side only on groups with no node in common.  g16 holds
    # every node of g8, g4, g2 and g2b, and a run.sh that finds one of its
    # nodes held by another run refuses (0.90.107: the 16-node board and
    # 2/net/mesh/direct never ran).  So the boards go in waves, in argument
    # order: a board joins the first wave none of whose groups shares a node
    # with its own, and the waves run one after another.
    # A board also needs a pool LUN of its own for the whole wave: run.sh takes
    # 20G up to 8 nodes and 80G above, and a board that finds none free fails
    # at once with no row run (0.90.130: 16/disk/caw/mpath and 16/net/mesh/mpath
    # each shared a wave with another 16-node board, and the pool has one 80G
    # LUN).  So a wave holds no more boards above 8 nodes than the pool has
    # LUNs of 80G or more.
    big_luns=$(tools/lun_pool.sh status 2>/dev/null | awk '$1 ~ /^lun[0-9]+$/ { s = $2; sub(/G$/, "", s); if (s + 0 >= 80) n++ } END { print n + 0 }')
    [ "$big_luns" -ge 1 ] || big_luns=1
    waves=(); wave_nodes=(); wave_big=()
    for b in "${boards[@]}"; do
        nodes=$(tools/mxfs_lab.sh group "${b##*@}")
        big=0; [ "$(echo "$nodes" | wc -w)" -gt 8 ] && big=1
        placed=0
        for w in "${!waves[@]}"; do
            clash=0
            for n in $nodes; do
                case "${wave_nodes[$w]}" in *" $n "*) clash=1; break ;; esac
            done
            [ "$big" = 1 ] && [ "${wave_big[$w]}" -ge "$big_luns" ] && clash=1
            if [ "$clash" = 0 ]; then
                waves[w]="${waves[$w]} $b"; wave_nodes[w]="${wave_nodes[$w]} $nodes "
                wave_big[w]=$(( ${wave_big[$w]} + big ))
                placed=1; break
            fi
        done
        [ "$placed" = 1 ] || { waves+=("$b"); wave_nodes+=(" $nodes "); wave_big+=("$big"); }
    done
    for w in "${!waves[@]}"; do
        # shellcheck disable=SC2086  # one argument per board
        step "boards wave $((w + 1))/${#waves[@]} nodes=[$counts ]:${waves[$w]}" \
            tests/board_4node_chain.sh "bL$((w + 1))_$V" ${waves[$w]}
    done
    for cfg in "${cfgs[@]}"; do
        echo "=== board $cfg ===" >> "$L"
        python3 tools/criteria.py "$cfg" | grep -vE '\| PASS ' | cut -c1-160 >> "$L"
    done
    # bench/README.md is written from the release boards (tools/bench_report.py)
    # and scripts/release.sh refuses to build while the page disagrees with
    # them, so the page is rewritten from the boards just run, before the
    # packages step reads it: on 0.90.131 the boards changed the throughput
    # numbers and the page still held the previous run's.
    step "bench page" python3 tools/bench_report.py
fi
if [ "$together" = 1 ]; then
    # full_verify powers down only the claimed count's groups before a
    # platform group; the smaller counts' groups are up from the boards too
    [ "$POWER" = 1 ] && step "rig off" scripts/lab_power.sh down "rig:${RIG_MAX:-$CLAIM}"
    NODES=$CLAIM STEPS=packages,platforms step "full_verify nodes=$CLAIM packages,platforms" tests/full_verify.sh "$V"
fi
grep -E '^=== rc=|^Total:|^VERDICT:' "$L" | tail -n 40
echo "RELEASE_CHAIN_DONE $(date -u +%FT%TZ)" | tee -a "$L"
