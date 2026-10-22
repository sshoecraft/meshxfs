#!/bin/bash
#
# full_verify.sh — everything a version must pass before it can be published
#
# Usage: [NODES=N] tests/full_verify.sh VERSION [STALL_LAPS]
#
# NODES (default 2) is the cluster size the release claims: the rig suites run
# at that node count.  The platform rounds do not: they run on the first
# PLATFORM_NODES (2) nodes of each platform's set, on the release matrix's
# 2-node configurations, whatever the claim.  What a platform round has ever
# caught is the platform itself — its kernel, its build, its packages, its
# fence path (a module that would not build for Debian 13, a fence refused on
# every Proxmox kernel, a helper the packages never shipped, SELinux labels) —
# and every one of those shows on two nodes; node-count behaviour is the rig's
# job, at the claimed count.  Two, not one, because the hung-node test needs a
# peer to fence.  At 32 nodes on thirteen platforms the old rule was 416
# guests; this one is 26.
#
# In order, each step logged into tests/evidence/full_verify_<VERSION>.log with
# its own "=== rc=N: <step> ===" line:
#   1. a build from a clean copy of the tree (no objects), warnings counted;
#      the userspace tools, the user-mode tests (tests/tauth) and the extern
#      declaration audit
#   2. the rig suite for every configuration of the release matrix at NODES
#      (tools/configuration.py release-matrix --nodes N, e.g. 8/net/mesh/direct
#      and 8/disk/caw/direct), side by side: the i-th configuration runs on rig
#      group g<N>, the next on g<N>b, and so on (the lab file's `group` lines),
#      each on a LUN borrowed from the pool (tools/lun_pool.sh)
#   3. the release packages (scripts/release.sh), unless dist/VERSION holds them
#   4. every platform's packaged round on EACH configuration of the matrix
#      (CONFIG=N/net/mesh/direct, N/disk/caw/direct): ubuntu2404, pve9 on both
#      claimed kernels, and every other platform data/platforms.json releases
#   5. every platform's hung-node test on each configuration, and on the rhel9
#      set the SELinux sVirt test, then STALL_LAPS laps of
#      tests/svirt_stall_laps.sh (default 0)
#
# Steps 4-5 run the platforms of a group in parallel, each platform's own
# steps in order, and the groups one after another: every set borrows a LUN of
# its own from the pool for its steps (tools/lun_pool.sh), and its lab file
# ~/.config/mxfslab/lab.<platform> is written from that allocation, so no set's
# format touches another's.
# Each platform's steps also go to
# tests/evidence/full_verify_<VERSION>_<platform>.log and are copied into the
# main log when it finishes.
#
# PLATFORM_GROUPS (default: every released platform in one group, all
# at once) names the groups, commas inside a group and spaces between
# groups.  POWER=1 (default 0) powers the sets with scripts/lab_power.sh so
# that only what a step needs is up: the rig alone for the suites, then each
# group's sets alone for their steps, and the rig again at the end.  Both
# exist for a host that cannot hold every guest at once: at eight nodes the
# rig and the four sets are forty guests, 112 GiB of configured memory against
# this host's 94, so the 8-node verification runs
#   POWER=1 PLATFORM_GROUPS="pve9 debian13 rhel9 ubuntu2404"
# one platform at a time.  Memory would allow two sets at once (48 GiB, then
# 64 GiB), but the packaged round's install is a DKMS compile on every node
# under a per-guest budget (tests/packaged_round.sh): two 8-node sets compile
# on 64 vCPUs of this 56-core host at once, and on 0.90.36 six of eight rhel9
# nodes overran the 660 s install budget beside ubuntu2404's compile.  One set
# is 32 vCPUs.  The suites grade pace, so with POWER=1 they also run with
# every platform guest off.
#
# Stops only when the build or the packages fail: every later step needs them.
# A failing test step is logged and the rest still run, so one run shows every
# failure.  Each harness enforces its own budget; nothing here widens one.
#
# Before each platform step the pair's MXFS mounts are taken down: a pair left
# mounted by the step before (the hung-node test ends remounted) makes the next
# round refuse mkfs.
#
set -u

V="${1:?usage: [NODES=N] full_verify.sh VERSION [STALL_LAPS]}"
LAPS="${2:-0}"
NODES="${NODES:-2}"
[[ "$NODES" =~ ^[0-9]+$ ]] && [ "$NODES" -ge 2 ] || { echo "NODES must be an integer >= 2 (got '$NODES')" >&2; exit 2; }
POWER="${POWER:-0}"
# every platform data/platforms.json releases, never a list kept here: a
# platform released there and left out of a fixed list here would ship
# unverified (Debian 12, released in 0.90.130, had to be run by a copy of
# this script until then)
ALL_PLATFORMS=$(python3 -c 'import json, sys; d = json.load(open(sys.argv[1]))["platforms"]; print(" ".join(k for k, v in d.items() if v["status"] == "released"))' "$(dirname "$0")/../data/platforms.json")
[ -n "$ALL_PLATFORMS" ] || { echo "no released platform in data/platforms.json" >&2; exit 2; }
# PLATFORMS (default every released platform) re-runs only the sets named, for a run whose
# other sets already passed on this version.  The verdict at the end still
# reads every platform's log, so a set not re-run is graded on its own last
# run of $V and a failed one cannot drop out of it.
PLATFORMS="${PLATFORMS:-$ALL_PLATFORMS}"
for k in $PLATFORMS; do
    case " $ALL_PLATFORMS " in *" $k "*) ;; *) echo "PLATFORMS: '$k' is not one of [$ALL_PLATFORMS]" >&2; exit 2 ;; esac
done
PLATFORM_GROUPS="${PLATFORM_GROUPS:-$(echo $PLATFORMS | tr ' ' ',')}"
[ "$(echo "$PLATFORM_GROUPS" | tr ', ' '\n\n' | awk 'NF' | sort | tr '\n' ' ')" = "$(echo $PLATFORMS | tr ' ' '\n' | sort | tr '\n' ' ')" ] \
    || { echo "PLATFORM_GROUPS must name each of [$PLATFORMS] exactly once (got '$PLATFORM_GROUPS')" >&2; exit 2; }
# Every log is named by TAG: the version, or the release candidate this runs
# for (tools/release_run.py sets MXFS_LOGTAG), so one candidate's platform
# rounds are never graded on another's run of the same version.
TAG="${MXFS_LOGTAG:-$V}"
# GRADED is what the verdict reads: every released platform, except for a
# dry-run candidate (tools/release_candidate.py create --dry-run), which can
# never be qualified and may exercise a subset; it is graded on that subset.
GRADED="$ALL_PLATFORMS"
if [ -n "${MXFS_CANDIDATE:-}" ] && python3 -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1])).get("dry_run") else 1)' \
        "$(dirname "$0")/../data/candidates/$MXFS_CANDIDATE.json" 2>/dev/null; then
    GRADED="$PLATFORMS"
fi
for k in $GRADED; do
    [ -s "$(dirname "$0")/evidence/full_verify_${TAG}_$k.log" ] || case " $PLATFORMS " in *" $k "*) ;; *)
        echo "PLATFORMS leaves out $k, which has no run of $TAG to be graded on" >&2; exit 2 ;; esac
done
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 1
L="$HERE/tests/evidence/full_verify_$TAG.log"
# a run that resumes after the build keeps the log of the run it continues
case ",${STEPS:-build}," in *,build,*) : > "$L" ;; esac
SSH="$HERE/tools/mxfs_sshpass.sh"
PLATFORM_NODES=2
echo "=== full_verify $V nodes=$NODES platform_nodes=$PLATFORM_NODES power=$POWER groups=[$PLATFORM_GROUPS] $(date -u +%FT%TZ) ===" | tee -a "$L"
. "$HERE/tools/mxfs_lab.sh"
# plat_set <platform>: the nodes its rounds run on, the first PLATFORM_NODES
# of its set
plat_set() {
    lab_nodes "$1" | tr ' ' '\n' | awk 'NF' | head -n "$PLATFORM_NODES" | tr '\n' ' '
}
for k in $ALL_PLATFORMS; do
    n=$(lab_nodes "$k" 2>/dev/null | wc -w)
    [ "$n" -ge "$PLATFORM_NODES" ] || { echo "$k: its verification set has $n node(s), the rounds need $PLATFORM_NODES" | tee -a "$L"; exit 2; }
done

run() {
    echo "=== $* ===" >> "$L"
    "$@" >> "$L" 2>&1
    local rc=$?
    echo "=== rc=$rc: $* ===" >> "$L"
    echo "rc=$rc  $*"
    return $rc
}

all_platform_nodes() {  # every node the platform rounds run on
    local k
    for k in $ALL_PLATFORMS; do
        plat_set "$k" 2>/dev/null
    done | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' '
}
unmount_pairs() {  # [node...] — default: every platform node
    local h
    for h in ${*:-$(all_platform_nodes)}; do
        (timeout 75 "$SSH" "$(tools/mxfs_lab.sh addr $h 2>/dev/null || echo $h)" \
            'for m in $(grep " mxfs " /proc/mounts | cut -d" " -f2); do timeout 60 umount $m; done; echo left=$(grep -c " mxfs " /proc/mounts)' \
            </dev/null 2>/dev/null | grep left= | sed "s/^/$h /") &
    done
    wait
}

# pool_lab <key> <lab file>: borrow a pool LUN for the platform's whole
# verification set, held by the calling shell for as long as it runs, and
# write the lab file its steps read: the site's own lines, that set alone, and
# the borrowed LUN as its storage.
pool_lab() {
    local key=$1 lab=$2 set line portal
    set=$(plat_set "$key")
    [ -n "$set" ] || return 1
    portal=$(lab_need storage portal) || return 1
    line=$(tools/lun_pool.sh alloc --owner "$BASHPID" --what "full_verify $V $key" $set) || return 1
    { grep -E '^#|^addr|^dns|^qemu|^paths' "$MXFS_LAB"
      echo "storage portal=$portal target=$(sed -n 's/.* target=\([^ ]*\).*/\1/p' <<<"$line") lun=$(sed -n 's/.* dev=\([^ ]*\).*/\1/p' <<<"$line")"
      echo "nodes $key=$(echo $set | tr ' ' ',')"; } > "$lab"
    echo "$line"
}

# platform <key> <steps...>: one platform's steps in order against its own
# lab file, logged to its own file.  A step is "[VAR=value ...] command args".
platform() {
    local key=$1 lab="$HOME/.config/mxfslab/lab.$1" pl="$HERE/tests/evidence/full_verify_${TAG}_$1.log" pair step
    shift
    : > "$pl"
    pool_lab "$key" "$lab" >> "$pl" 2>&1 || { echo "=== rc=2: $key: no pool LUN for its verification set ===" >> "$pl"; return; }
    pair=$(plat_set "$key")
    for step in "$@"; do
        MXFS_LAB=$lab unmount_pairs $pair >> "$pl"
        echo "=== $key: $step ===" >> "$pl"
        env MXFS_LAB="$lab" bash -c "$step" >> "$pl" 2>&1
        echo "=== rc=$?: $key: $step ===" >> "$pl"
    done
    MXFS_LAB=$lab unmount_pairs $pair >> "$pl"
}

# STEPS (default "build,suites,packages,platforms") names the steps to run.
# A chain whose suites already ran, but whose packages failed, picks up with
# STEPS=packages,platforms instead of running the suites again.
STEPS=",${STEPS:-build,suites,packages,platforms},"
want() { case "$STEPS" in *",$1,"*) return 0 ;; esac; return 1; }
echo "steps:${STEPS//,/ }" | tee -a "$L"

# --- 1. clean build, tools, user-mode tests, audit
if want build; then
B=$(mktemp -d) || exit 1
timeout 300 rsync -a --exclude .git --exclude dist --exclude tests/evidence \
    --exclude '*.o' --exclude '*.ko' --exclude '.*.cmd' ./ "$B/"
( cd "$B" && timeout 540 make modules -j"$(nproc)" > "$B/build.log" 2>&1 )
brc=$?
echo "clean_build_rc=$brc version=$(modinfo -F version "$B/mxfs.ko" 2>/dev/null) srcversion=$(modinfo -F srcversion "$B/mxfs.ko" 2>/dev/null) warnings=$(grep 'warning:' "$B/build.log" | grep -vc 'compiler differs\|Clock skew')" | tee -a "$L"
grep -E 'warning:|error:' "$B/build.log" | grep -v 'compiler differs\|Clock skew' | head -20 | tee -a "$L"
[ $brc = 0 ] || { echo "clean build failed; stopping" | tee -a "$L"; exit 1; }
( cd "$B" && timeout 120 make -C tools > "$B/tools.log" 2>&1; echo "tools_rc=$? tool_warn=$(grep -ci warning "$B/tools.log")"
  timeout 240 make -C tests/tauth clean test > "$B/tauth.log" 2>&1; echo "tauth_rc=$? $(grep -aoE '=== tauth_test: fails=[0-9]+' "$B/tauth.log")" ) | tee -a "$L"
timeout 120 python3 scripts/extern_decl_audit.py >> "$L" 2>&1; echo "extern_audit_rc=$?" | tee -a "$L"
timeout 60 python3 scripts/inode_flag_bits_audit.py >> "$L" 2>&1; echo "inode_flag_audit_rc=$?" | tee -a "$L"
# the public text against the release data (scripts/release.sh stops on this;
# here it is recorded with the build's other audits)
timeout 120 python3 tools/release_text_check.py ${MXFS_CANDIDATE:+--before-build} >> "$L" 2>&1; echo "release_text_check_rc=$?" | tee -a "$L"
# the clean copy has served its purpose: the tree's own module is what the
# later steps deploy, and its srcversion is checked against this one's
rm -rf "$B"
fi

# --- 2. the release matrix's suites on the rig at the claimed node count
MATRIX=$(python3 tools/configuration.py release-matrix --nodes "$NODES")
[ -n "$MATRIX" ] || { echo "the release matrix (data/configurations.json) has no configuration at $NODES nodes" | tee -a "$L"; exit 2; }
# The rig groups of the claimed size, g<N> then g<N>b, g<N>c ... for as many
# as the lab file names: the suites run side by side on disjoint nodes, the
# i-th configuration on the i-th group.  A matrix with more configurations at
# this count than the rig has groups (four at 16 nodes on a 32-node rig) wraps
# around, and the configurations that share a group run one after another.
SUITE_GROUPS=""
i=0
for cfg in $MATRIX; do
    g=g$NODES; [ "$i" -gt 0 ] && g=g$NODES$(printf "\\$(printf %o $((97 + i)))")
    [ "$(lab_group "$g" 2>/dev/null | wc -w)" = "$NODES" ] || break
    SUITE_GROUPS="$SUITE_GROUPS $g"
    i=$((i + 1))
done
[ -n "$SUITE_GROUPS" ] || { echo "the suites need rig group g$NODES of $NODES nodes in $MXFS_LAB" | tee -a "$L"; exit 2; }
if want suites; then
if [ "$POWER" = 1 ]; then
    # shellcheck disable=SC2086  # one argument per platform
    run scripts/lab_power.sh down $ALL_PLATFORMS
    # shellcheck disable=SC2086
    run scripts/lab_power.sh up $(for g in $SUITE_GROUPS; do echo "group:$g"; done)
fi
# shellcheck disable=SC2206  # one element per group
sgroups=($SUITE_GROUPS)
pids=()
for gi in "${!sgroups[@]}"; do
    g=${sgroups[$gi]}
    (
        i=0
        for cfg in $MATRIX; do
            if [ $((i % ${#sgroups[@]})) = "$gi" ]; then
                slug=${cfg//\//-}
                sl="$HERE/tests/evidence/full_verify_${TAG}_suite_$slug.log"
                ./run.sh "$cfg" --group "$g" > "$sl" 2>&1
                echo "=== rc=$?: ./run.sh $cfg --group $g ===" >> "$sl"
            fi
            i=$((i + 1))
        done
    ) &
    pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
for cfg in $MATRIX; do
    slug=${cfg//\//-}
    sl="$HERE/tests/evidence/full_verify_${TAG}_suite_$slug.log"
    cat "$sl" >> "$L"
    grep -a '^=== rc=' "$sl"
    echo "suite_${slug}_pass=$(grep -cE '^\s+PASS' "$sl") suite_${slug}_fail=$(grep -cE '^\s+(FAIL|TIMEOUT)' "$sl")" | tee -a "$L"
done
# the board is the verdict, not the run's own PASS lines: run.sh exits 0 with
# rows failed, so each board is read back, graded for the candidate when there
# is one, and a board that does not read green is a failed step
for cfg in $MATRIX; do
    echo "=== board $cfg ===" >> "$L"
    # harness-lint: ok - graded for the candidate, a board this run did not record reads NOT RUN, never a previous run's PASS
    python3 tools/criteria.py "$cfg" ${MXFS_CANDIDATE:+--candidate "$MXFS_CANDIDATE"} >> "$L" 2>&1
    # harness-lint: ok - the same graded read-back, as the step's verdict
    if python3 tools/criteria.py "$cfg" ${MXFS_CANDIDATE:+--candidate "$MXFS_CANDIDATE"} | grep -q 'VERDICT: every criterion green'; then
        echo "=== rc=0: board $cfg ===" >> "$L"
    else
        echo "=== rc=1: board $cfg ===" | tee -a "$L"
    fi
done
fi

# --- 3. packages
# A finished build is dist/$V with a SHA256SUMS its packages match: release.sh
# writes that file last.  The directory alone is not one -- a release.sh
# stopped part way leaves it behind, and 0.90.39's chain found it empty, built
# nothing, and failed every packaged round on a missing .deb.
D="${MXFS_DIST:-dist/$V}"
if want packages && ! { [ -f "$D/SHA256SUMS" ] && (cd "$D" && sha256sum --quiet -c SHA256SUMS); }; then
    run scripts/release.sh || { echo "release.sh failed; stopping" | tee -a "$L"; exit 1; }
fi
want platforms || { echo "=== full_verify $V done (steps:${STEPS//,/ }) ===" | tee -a "$L"; exit 0; }

# --- 4-5. platform rounds and the set tests, one platform per LUN: a group's
# platforms in parallel, the groups one after another
PR=tests/packaged_round.sh
FZ=tests/tcp_peer_freeze_death.sh
# The platform harnesses attach the LUN by in-guest iSCSI on one path and build
# nothing else (tests/packaged_round.sh), so a platform is verified on the
# matrix's direct configurations; a multipath configuration is verified by its
# rig board.
PMATRIX=$(python3 tools/configuration.py release-matrix --nodes "$PLATFORM_NODES" | grep '/direct$')
[ -n "$PMATRIX" ] || { echo "the release matrix has no configuration at $PLATFORM_NODES nodes" | tee -a "$L"; exit 2; }
steps_of() {  # <platform>: that platform's steps, in order
    local s=() cfg kernels=("") k
    # a platform verified on several kernels runs its rounds on each, the
    # kernels read from data/platforms.json: a list kept here drifted from it
    # (7.0.14-19 here, 7.0.14-24 in the release table)
    mapfile -t pk < <(python3 -c 'import json, sys; d = json.load(open(sys.argv[1]))["platforms"].get(sys.argv[2], {}); ks = d.get("kernel_releases") or []; print("\n".join(ks) if len(ks) > 1 else "")' data/platforms.json "$1")
    if [ -n "${pk[0]:-}" ]; then kernels=(); for k in "${pk[@]}"; do kernels+=("KERNEL=$k "); done; fi
    for k in "${kernels[@]}"; do
        for cfg in $PMATRIX; do s+=("${k}CONFIG=$cfg $PR $1 $V"); done
    done
    for cfg in $PMATRIX; do s+=("CONFIG=$cfg PREP=$1 $FZ"); done
    case "$1" in
        rhel9)
            s+=("PREP=rhel9 tests/selinux_svirt_mxfs.sh")
            # one step, whatever it holds: an unquoted expansion here made
            # three steps of the command and its two arguments
            [ "$LAPS" -gt 0 ] && s+=("tests/svirt_stall_laps.sh $V $LAPS") ;;
    esac
    platform "$1" "${s[@]}"
}
for g in $PLATFORM_GROUPS; do
    gs=${g//,/ }
    # The sets are held in the VM pool while they verify, whichever way they
    # are powered: a node nobody holds is idle to the pool, and the release
    # helpers that scripts/release.sh's package builds and kernel build checks
    # leave behind (vm_pool.sh release --after) shut the first node of the
    # pve9, rhel9 and debian12 sets off part way through 0.90.130's first
    # POWER=1 platform rounds.
    . "$HERE/tests/lib/runlock.sh"
    # shellcheck disable=SC2046  # one argument per node
    vmhold_take "full_verify $V" $(for k in $gs; do plat_set "$k"; done) \
        || { echo "could not hold the sets of [$gs]" | tee -a "$L"; exit 2; }
    if [ "$POWER" = 1 ]; then
        # only this group's sets hold the host's memory while they verify
        off=$(for g in $SUITE_GROUPS; do echo -n "group:$g "; done)
        for k in $ALL_PLATFORMS; do case " $gs " in *" $k "*) ;; *) off="$off $k" ;; esac; done
        # shellcheck disable=SC2086  # one argument per set
        run scripts/lab_power.sh down $off
        # shellcheck disable=SC2086  # only the nodes the rounds run on
        run scripts/lab_power.sh up $(for k in $gs; do plat_set "$k"; done)
    else
        # and started if the pool had shut them off: a set that was off failed
        # every step with "not answering" (0.90.130's first Debian 12 round)
        # shellcheck disable=SC2046
        run tools/vm_pool.sh up $(for k in $gs; do plat_set "$k"; done)
        # shellcheck disable=SC2046
        ( setsid tools/vm_pool.sh release --after $$ $(for k in $gs; do plat_set "$k"; done) </dev/null >/dev/null 2>&1 & )
    fi
    pids=()
    for k in $gs; do steps_of "$k" & pids+=($!); done
    for p in "${pids[@]}"; do wait "$p"; done
    # shellcheck disable=SC2086
    [ "$POWER" = 1 ] && run scripts/lab_power.sh down $gs
done
# shellcheck disable=SC2046
[ "$POWER" = 1 ] && run scripts/lab_power.sh up $(for g in $SUITE_GROUPS; do echo "group:$g"; done)
failed=0
for k in $GRADED; do
    cat "$HERE/tests/evidence/full_verify_${TAG}_$k.log" >> "$L"
    grep -a '^=== rc=' "$HERE/tests/evidence/full_verify_${TAG}_$k.log"
    failed=$((failed + $(grep -ac '^=== rc=[1-9]' "$HERE/tests/evidence/full_verify_${TAG}_$k.log")))
done

grep -E "=== rc=|RESULT|VERDICT|both nodes on kernel|suite_[0-9]+-|clean_build_rc|tools_rc|tauth_rc|extern_audit_rc|inode_flag_audit_rc|release_text_check_rc|all .* laps passed|STALL|STOP" "$L" | cut -c1-200
# The exit status covers every step this run made: the build's own audits and
# user-mode tests, every suite's run and board, and every platform step.  It
# used to be the platforms' alone, so a failed tauth or a red board exited 0.
others=$(grep -acE '^(tools_rc|tauth_rc|extern_audit_rc|inode_flag_audit_rc|release_text_check_rc)=[1-9]|^=== rc=[1-9]+: (\./run\.sh|board) ' "$L")
echo "=== full_verify $TAG failed: platform steps $failed, other steps $others ===" | tee -a "$L"
[ "$failed" = 0 ] && [ "$others" = 0 ]
