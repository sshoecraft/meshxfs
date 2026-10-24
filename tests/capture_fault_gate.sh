#!/bin/bash
# tests/capture_fault_gate.sh — does every adopted harness REJECT a failed
# measurement, rather than avoid one?
#
# The capture contract (docs/harness-capture-contract.md, ledger
# D-A-TEST-HARNESS-CAN-REPORT-A-VERDICT-ABOUT-MXFS) is verified by rejection:
# a real ssh failure at a real acquisition point must end the lap as ABORT
# with the injection proven in the evidence and NO verdict printed after it.
# tests/lib/rig.sh injects that with MXFS_FAULT_RSX_NTH=<n>: the n-th
# measurement of the lap is issued to a host that does not resolve, and the
# library prints a STAGE FAULT line on stderr when the injection is reached.
#
# For every entry of the gate manifest this runs the harness once with the
# fault armed and requires, from the lap's own log:
#   - exit status 2 (ABORT), never 0 (a PASS from no measurement) and never
#     1 (a FAIL fabricated from the failed capture);
#   - the STAGE FAULT line (the injection was reached: a harness whose first
#     measurement never goes through rsx would "pass" this gate vacuously);
#   - a RESULT: ABORT line;
#   - ZERO assertion lines ("  PASS"/"  FAIL") after the STAGE FAULT line.
# With --healthy it then runs the same entry without the fault and requires
# exit status 0: the boundary must not refuse a healthy measurement either
# (--healthy-only runs just that lap, for a manifest whose fault side has
# its evidence).  The healthy line quotes the lap's DEVICE line: the harness
# resolved its device by identity (tests/lib/rig.sh mxfs_dev_resolve).
# A healthy lap that exits 3 with zero FAIL lines is the harness's own
# VACUOUS / INCONCLUSIVE (its trigger was not reached; nothing refused,
# nothing fabricated): recorded as VACUOUS, counted apart, not BROKEN.
# An entry that misses any of these is BROKEN and the gate exits 1.
#
# Every lap starts on the pair as it was formed: each node up with the tree on
# /src, this tree's module loaded and the filesystem mounted.  The entries run
# back to back, and an injected fault or an entry's own kill arm can leave a
# node destroyed, unmounted or without its module.  The next entry that did
# not prep itself then aborted on that before its first measurement, and the
# gate read it BROKEN without testing its capture handling at all (0.90.134:
# tcp_death_replay and lone_mount_crash_replay found test2 off after
# recov_bmbt_reuse, join_during_takeover found it unmounted).  So the pair is
# checked before every lap and formed again when it is not: the nodes that did
# not answer are powered on, then run.sh prep_cluster forms the pair under the
# configuration its cluster marker records (MXFS_MARKER, as run.sh exports it;
# MXFS_GROUP carries a rig group into run.sh).  Bounds: a started VM answered
# ssh in 40-90 s (tests/recov_bmbt_reuse.sh), so 120 s; prep_cluster bounds
# itself with its manifest budget.  A pair that is still not formed after that
# ends the gate as ABORT: every later lap would measure the rig, not its
# harness.  GATE_PAIR_RESTORE=0 skips the check, as the gate ran before it:
# the control of that fix (tests/capture_gate_pair_lap.sh).
#
# Manifest (tests/capture_gate.manifest): one entry per line,
#     <harness> | <fault lap timeout s> | <healthy lap timeout s> | <env> | <args after the label>
# The timeouts are the harness's own caller bound (its header derives it);
# a lap that overruns is recorded with rc=124 and is BROKEN, never re-run.
# <env> is the environment for both laps (NOPREP=1 to reuse the live mount)
# or '-' for none.  With --only, GATE_ENTRY_ENV (NAME=value words) is added after
# that entry's <env> and overrides it: a control's variant, the manifest untouched.
#
# Usage: tests/capture_fault_gate.sh <label> [--healthy|--healthy-only] [--only <harness>] [manifest]
set -u
LABEL=${1:?label}; shift
HEALTHY=0; FAULT=1; ONLY=; MANIFEST=tests/capture_gate.manifest
while [ $# -gt 0 ]; do
    case $1 in
        --healthy) HEALTHY=1 ;;
        --healthy-only) HEALTHY=1; FAULT=0 ;;   # the fault side already has its evidence for this manifest
        --only) ONLY=$2; shift ;;
        *) MANIFEST=$1 ;;
    esac
    shift
done
cd "$(dirname "$0")/.." || exit 2
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_capture_gate_$LABEL
mkdir -p "$OUT"
[ -r "$MANIFEST" ] || { echo "ABORT: gate manifest $MANIFEST is not readable"; exit 2; }
echo "=== capture_fault_gate label=$LABEL manifest=$MANIFEST healthy=$HEALTHY out=$OUT $(date -u +%FT%TZ) ==="
broken=0; vacuous=0; entries=0; s0=$(date +%s)

# the assertion lines printed AFTER the injection line, counted from the
# same log the harness wrote (stderr and stdout interleaved as they came)
verdicts_after_fault() { awk '/STAGE FAULT:/{f=1; next} f && /^  (PASS|FAIL) /{n++} END{print n+0}' "$1"; }
# relay_stall <harness log> <what>: the worst max_stall_ms= the harness printed
# over its timed operations, on this gate's own output.  A gate lap run through
# tools/batch_lap.py is held to the release policy's stall limit only by the
# max_stall_ms= lines in that output, and each harness writes into its own log
# here: a 31 s last-member unmount inside join_during_takeover's lap was
# recorded PASS (batch b20261022-548ef2,
# D-HARNESS-LAP-TIMED-OPS-REACH-NO-STALL-GRADER-JDT-31S-UNMOUNT-GRADED-PASS).
# GATE_RELAY_STALL=0 relays nothing, as before: the control.
relay_stall() {
    local w
    [ "${GATE_RELAY_STALL:-1}" = 0 ] && return 0
    w=$(grep -ao 'max_stall_ms=[0-9]*' "$1" | cut -d= -f2 | sort -n | tail -1)
    [ -z "$w" ] || echo "GATE $2 max_stall_ms=$w (the worst timed operation the harness printed, $1)"
}

PAIR_NODES=${MXFS_NODE_LIST:-test1,test2}; PAIR_NODES=${PAIR_NODES//,/ }
# The harnesses run on their own default nodes, test1 and test2 (a manifest
# entry passes the label and its args, never the pair), so a gate pointed at
# another pair checked and formed that pair and then measured test1/test2: with
# MXFS_NODE_LIST=test29,test30, join_during_takeover aborted at once on an
# unmounted test1 (lanes g2c_jdt_control_20261022T202825Z and
# 20261022T232233Z).  Such a gate measures nothing, so it is refused.
[ "$PAIR_NODES" = "test1 test2" ] || { echo "ABORT: the gate's pair is [$PAIR_NODES], but its harnesses run on their default nodes test1 and test2; run it on the g2 pair"; echo "RESULT: ABORT label=$LABEL entries=0 broken=0 vacuous=0 restores=0 wall=0s stage=pair evidence=$OUT"; exit 2; }
PAIR_MNT=${MXFS_MOUNT:-/mnt/shared}
PAIR_SV=$(modinfo -F srcversion mxfs.ko 2>/dev/null)
PAIR_CONFIG=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("configuration") or "")' "${MXFS_MARKER:-.cluster_marker.json}" 2>/dev/null)
[ -n "$PAIR_SV" ] || { echo "ABORT: no srcversion in ./mxfs.ko, so no lap can be checked for this tree's module"; exit 2; }
[ -n "$PAIR_CONFIG" ] || { echo "ABORT: the cluster marker ${MXFS_MARKER:-.cluster_marker.json} names no configuration, so the pair cannot be formed again between laps"; exit 2; }
# force_transport as prep loads it for the configuration (tests/lib/rig.sh mxfs_rig_modargs)
PAIR_FT=1; [ "$(python3 tools/configuration.py get "$PAIR_CONFIG" transport 2>/dev/null)" = caw ] && PAIR_FT=0
restores=0
# pair_state: one line per node that answered,
#   "<node> src=<0|1> sv=<srcversion> ft=<force_transport> m=<mxfs mounts>"
pair_state() {
    local n a
    for n in $PAIR_NODES; do
        a=$(timeout 20 tools/mxfs_sshpass.sh "$n" "echo src=\$(mountpoint -q /src && [ -r /src/mxfs/tests/setup/prep_node.sh ] && echo 1 || echo 0) sv=\$(cat /sys/module/mxfs/srcversion 2>/dev/null) ft=\$(cat /sys/module/mxfs/parameters/force_transport 2>/dev/null) m=\$(grep -c ' $PAIR_MNT mxfs ' /proc/mounts)" < /dev/null 2>/dev/null | grep -a '^src=' | tail -1)
        [ -n "$a" ] && echo "$n $a"
    done
}
pair_formed() {  # <pair_state output>
    local n
    for n in $PAIR_NODES; do grep -aqx "$n src=1 sv=$PAIR_SV ft=$PAIR_FT m=1" <<<"$1" || return 1; done
}
# pair_ready <lap>: the pair is formed, or is formed again, or the gate ends
pair_ready() {
    local st n s log
    [ "${GATE_PAIR_RESTORE:-1}" = 0 ] && return 0
    st=$(pair_state)
    pair_formed "$st" && return 0
    restores=$((restores+1)); log=$OUT/pair_restore_$restores.log
    echo "PAIR before $1: not formed [$(tr '\n' ';' <<<"$st")] -> forming it again (log $log)"
    for n in $PAIR_NODES; do
        grep -aq "^$n src=" <<<"$st" || tools/node_power.sh start "$n" < /dev/null >> "$log" 2>&1
    done
    s=$(date +%s)
    for n in $PAIR_NODES; do
        until timeout 10 tools/mxfs_sshpass.sh "$n" "echo SSH_UP" < /dev/null 2>/dev/null | grep -q SSH_UP; do
            [ $(( $(date +%s) - s )) -lt 120 ] || break
            sleep 5
        done
    done
    ./run.sh "$PAIR_CONFIG" prep_cluster < /dev/null >> "$log" 2>&1
    st=$(pair_state)
    pair_formed "$st" && { echo "PAIR formed again before $1 in $(( $(date +%s) - s ))s"; return 0; }
    echo "ABORT: the pair could not be formed again before $1 [$(tr '\n' ';' <<<"$st")]; $(grep -a '^ABORT\|^ERROR\|prep_cluster OK' "$log" | tail -2 | tr '\n' ' ' | cut -c1-240)"
    echo "RESULT: ABORT label=$LABEL entries=$entries broken=$broken vacuous=$vacuous restores=$restores wall=$(( $(date +%s) - s0 ))s stage=pair evidence=$OUT"
    exit 2
}

while IFS= read -r line; do
    case $line in ''|'#'*) continue ;; esac
    IFS='|' read -r h tf th env args <<< "$line"
    h=$(echo "$h" | tr -d ' '); tf=$(echo "$tf" | tr -d ' '); th=$(echo "$th" | tr -d ' '); env=$(echo "$env" | sed 's/^ *//;s/ *$//'); args=$(echo "$args" | sed 's/^ *//;s/ *$//')
    [ -z "$ONLY" ] || [ "$h" = "$ONLY" ] || continue
    [ -x "tests/$h.sh" ] || { echo "GATE $h: BROKEN (tests/$h.sh is not executable or missing)"; broken=$((broken+1)); continue; }
    case $tf in ''|*[!0-9]*) echo "GATE $h: BROKEN (no fault-lap timeout in the manifest)"; broken=$((broken+1)); continue ;; esac
    [ "$env" = '-' ] && env=
    # The control of an entry's own environment (join_during_takeover's NFILES,
    # D-JOIN-DURING-TAKEOVER-GATE-PASS-ENDS-BEFORE-ITS-IN-FLIGHT-SAMPLE) runs the
    # entry with other values without editing the frozen manifest: with --only,
    # GATE_ENTRY_ENV's NAME=value words follow the manifest's, so env(1) takes them.
    [ -n "$ONLY" ] && [ -n "${GATE_ENTRY_ENV:-}" ] && env="$env $GATE_ENTRY_ENV"
    entries=$((entries+1))
    tag=${h//[^A-Za-z0-9_]/_}
    # a harness whose label is not its first positional (`<A> <B> [laps]
    # [label]`) names the label's place with {label} in its args
    fargs="$LABEL-$tag-fault $args"; hargs="$LABEL-$tag-ok $args"
    case $args in *'{label}'*) fargs=${args//\{label\}/$LABEL-$tag-fault}; hargs=${args//\{label\}/$LABEL-$tag-ok} ;; esac
    # ---- fault lap: the FIRST measurement fails ----
    if [ "$FAULT" = 1 ]; then
    pair_ready "$h fault"
    s=$(date +%s)
    # shellcheck disable=SC2086
    # stdin closed: the harness runs inside this loop's `read` over the
    # manifest, and a legacy ssh helper without `< /dev/null` drains the
    # manifest as its own input — a chunk of four entries then ran ONE (s58g)
    timeout "$tf" env MXFS_FAULT_RSX_NTH=1 $env "tests/$h.sh" $fargs < /dev/null > "$OUT/${tag}_fault.log" 2>&1
    rc=$?
    wall=$(( $(date +%s) - s ))
    fl=$(grep -ac 'STAGE FAULT:' "$OUT/${tag}_fault.log")
    ab=$(grep -ac '^RESULT: ABORT' "$OUT/${tag}_fault.log")
    va=$(verdicts_after_fault "$OUT/${tag}_fault.log")
    st=OK
    [ "$rc" = 2 ] && [ "$fl" -ge 1 ] && [ "$ab" -ge 1 ] && [ "$va" = 0 ] || st=BROKEN
    echo "GATE $h fault: rc=$rc wall=${wall}s fault_line=$fl abort=$ab verdicts_after_fault=$va -> $st"
    relay_stall "$OUT/${tag}_fault.log" "$h fault"
    [ "$st" = OK ] || { broken=$((broken+1)); grep -a '^ABORT:\|^RESULT\|STAGE FAULT' "$OUT/${tag}_fault.log" | head -4 | sed 's/^/      /' | cut -c1-220; }
    fi
    # ---- healthy lap ----
    if [ "$HEALTHY" = 1 ]; then
        pair_ready "$h healthy"
        s=$(date +%s)
        # shellcheck disable=SC2086
        timeout "${th:-$tf}" env $env "tests/$h.sh" $hargs < /dev/null > "$OUT/${tag}_ok.log" 2>&1
        rc=$?
        wall=$(( $(date +%s) - s ))
        fails=$(grep -ac '^  FAIL ' "$OUT/${tag}_ok.log")
        res=$(grep -a '^RESULT' "$OUT/${tag}_ok.log" | tail -1 | cut -c1-120)
        # the DEVICE line is the device record's migration proof: the harness
        # resolved its device by identity (absent for a harness that touches
        # no device by path, which is then said)
        dev=$(grep -a -m1 '^DEVICE node=' "$OUT/${tag}_ok.log" | cut -c1-140)
        # exit 3 is the harness's own VACUOUS / INCONCLUSIVE: every check it
        # made held, no capture was refused and no verdict was fabricated,
        # but its trigger was not reached (d0532_relog_live_holder's
        # concurrent case is unreachable for a user holder by its header).
        # That is a measured shape, not a boundary failure: recorded as
        # VACUOUS with its RESULT line, counted apart from OK, never BROKEN.
        st=OK; [ "$rc" = 0 ] || { [ "$rc" = 3 ] && [ "$fails" = 0 ] && st=VACUOUS || st=BROKEN; }
        echo "GATE $h healthy: rc=$rc wall=${wall}s fails=$fails result=[$res] device=[${dev:-none}] -> $st"
        relay_stall "$OUT/${tag}_ok.log" "$h healthy"
        [ "$st" = VACUOUS ] && vacuous=$((vacuous+1))
        [ "$st" != BROKEN ] || { broken=$((broken+1)); grep -a '^ABORT:\|^  FAIL\|^RESULT' "$OUT/${tag}_ok.log" | head -4 | sed 's/^/      /' | cut -c1-220; }
    fi
done < "$MANIFEST"
echo "RESULT: $( [ "$broken" = 0 ] && echo PASS || echo FAIL ) label=$LABEL entries=$entries broken=$broken vacuous=$vacuous restores=$restores wall=$(( $(date +%s) - s0 ))s evidence=$OUT"
[ "$broken" = 0 ]
