#!/bin/bash
# rejoin_modargs_lap.sh -- a host-only lap of the rejoin half of
# D-PATH-ROW-REJOIN-DROPS-THE-LANES-MODARGS-SO-A-LANE-RUNS-MIXED-WINDOWS.
#
# tests/mpath/lib.sh pf_boot_rejoin brings a killed victim back and loads mxfs
# on it.  It loaded mxfs_rig_modargs only, while tests/setup/prep_node.sh loads
# every node with its transport's MODARGS, the lane's MXFS_EXTRA_MODARGS and the
# retirement contract, so a lane with MXFS_EXTRA_MODARGS=dead_timeout_ms=12000
# ran its rejoined victim on the default window.
#
# This lap runs pf_boot_rejoin and pf_rejoin_modargs as they are in
# tests/mpath/lib.sh, with tests/lib/rig.sh, on this host, with no node touched:
# ssh ($SSH) and virsh ($VIRSH) are this script in its recorder mode.  The
# recorder writes down every command it is handed and runs none of them, except
# the boot probe (`test -e /run/nologin || echo SSH_UP`), which it runs here so
# the rejoin goes on to the command that loads the module.  That command is
# recorded, never run; it prints nothing, so the rejoin's capture_require ends
# it with an ABORT, which is expected here.  The lap then prints the insmod and
# modprobe the rejoin would have sent, the argv the node's shell would hand
# insmod, and the argv prep_node.sh hands insmod for the same environment (its
# MODARGS line for the configuration's transport, read from prep_node.sh itself,
# then MXFS_EXTRA_MODARGS split, then the contract as one argument).
#
#   PASS   the rejoin's insmod argv is prep's, element for element
#   FAIL   it differs
#   ABORT  no insmod was recorded, or prep's MODARGS line could not be read
#
# Environment (each has the default shown, as a lane of that defect ran it):
#   MXFS_CONFIG=8/net/mesh/mpath  MXFS_EXTRA_MODARGS=dead_timeout_ms=12000
#   MXFS_RIG_TAG=scst-fio (so no node is asked which rig this is)
#   MXFS_RETIRE_CONTRACT: as run.sh treats it, verbatim when set, even empty;
#   the rig's declaration in data/rigs.json otherwise.
# The control is PF_REJOIN_PREP_ARGS=0, which tests/mpath/lib.sh reads.
#
# Bound, derived: no ssh, no VM; two python3 calls to tools/configuration.py and
# two to data/rigs.json (about 0.1 s each) and the shell around them: under 2 s.
#
# Usage: tests/rejoin_modargs_lap.sh
# Exit: 0 PASS, 1 FAIL, 2 ABORT.

if [ -n "${REJOIN_LAP_RECORD:-}" ]; then
    { printf 'CALL'; printf ' %q' "$@"; printf '\n'; } >> "$REJOIN_LAP_RECORD"
    if [ "$#" = 2 ] && [ "$2" = 'test -e /run/nologin || echo SSH_UP' ]; then
        bash -c "$2"
    fi
    # the load command verbatim, as the node's shell would receive it
    case "${2:-}" in *'REJOIN dev='*) printf '%s\n' "$2" > "$REJOIN_LAP_RECORD.load" ;; esac
    exit 0
fi

set -u
SELF=$(readlink -f "$0")
REPO=$(cd "$(dirname "$SELF")/.." && pwd)
cd "$REPO" || exit 2
: "${MXFS_CONFIG:=8/net/mesh/mpath}"
: "${MXFS_EXTRA_MODARGS=dead_timeout_ms=12000}"
: "${MXFS_RIG_TAG:=scst-fio}"
export MXFS_CONFIG MXFS_EXTRA_MODARGS MXFS_RIG_TAG

S=$(mktemp -d) || { echo "LAP rejoin_modargs ABORT: no scratch directory"; exit 2; }
trap 'rm -rf -- "$S"' EXIT
export REJOIN_LAP_RECORD="$S/record"
: > "$REJOIN_LAP_RECORD"

rc_shown=unset
[ "${MXFS_RETIRE_CONTRACT+set}" = set ] && rc_shown="'$MXFS_RETIRE_CONTRACT'"
echo "LAP rejoin_modargs start $(date -u +%FT%TZ) config=$MXFS_CONFIG MXFS_EXTRA_MODARGS='$MXFS_EXTRA_MODARGS' MXFS_RETIRE_CONTRACT=$rc_shown PF_REJOIN_PREP_ARGS=${PF_REJOIN_PREP_ARGS:-unset}"

# The rejoin, in a subshell: its capture_require exits it.
(
    OUT="$S/out"; mkdir -p "$OUT"
    SSH="$SELF"
    LABEL=rejoin_modargs_lap
    # shellcheck source=tests/lib/rig.sh
    . tests/lib/rig.sh
    VIRSH="$SELF"
    DEV=/dev/mapper/mpatha
    MNT=/mnt/shared
    MOPT=""
    fails=0
    why=""
    eval "$(sed -n -e '/^ck() {/,/^}$/p' -e '/^finish() {$/,/^}$/p' \
                   -e '/^pf_rejoin_modargs() {$/,/^}$/p' -e '/^pf_boot_rejoin() {$/,/^}$/p' tests/mpath/lib.sh)"
    pf_boot_rejoin test14 rejoin
) > "$S/rejoin.out" 2>&1
echo "LAP rejoin_modargs the rejoin's own output (an ABORT at the load is expected: nothing ran it):"
sed 's/^/    /' "$S/rejoin.out"
echo "LAP rejoin_modargs recorded calls: $(grep -c '^CALL' "$REJOIN_LAP_RECORD")"
grep -a '^CALL' "$REJOIN_LAP_RECORD" | grep -av 'REJOIN dev=' | sed 's/^/    /'

ins=$(grep -ao 'insmod /root/mxfs.ko.prep [^;]*;' "$REJOIN_LAP_RECORD.load" 2>/dev/null | head -1)
mod=$(grep -ao 'else modprobe mxfs[^;]*;' "$REJOIN_LAP_RECORD.load" 2>/dev/null | head -1)
[ -n "$ins" ] || { echo "LAP rejoin_modargs ABORT: the rejoin recorded no insmod"; exit 2; }
echo "LAP rejoin_modargs INSMOD-LINE: $ins"
echo "LAP rejoin_modargs MODPROBE-LINE: $mod"

# The argv insmod receives on the node: the recorded text parsed by a shell, as
# the node's shell parses it.
argtext=${ins#insmod /root/mxfs.ko.prep }
argtext=${argtext%;}
mapfile -t got < <(bash -c "printf '%s\n' $argtext")

# The argv prep_node.sh hands insmod for this environment.
transport=$(python3 tools/configuration.py get "$MXFS_CONFIG" transport) \
    || { echo "LAP rejoin_modargs ABORT: no transport for $MXFS_CONFIG"; exit 2; }
prepargs=$(sed -n "s/^ *$transport) MODARGS=\"\([^\"]*\)\".*/\1/p" tests/setup/prep_node.sh)
[ -n "$prepargs" ] || { echo "LAP rejoin_modargs ABORT: no MODARGS line for $transport in tests/setup/prep_node.sh"; exit 2; }
if [ "${MXFS_RETIRE_CONTRACT+set}" = set ]; then
    contract=$MXFS_RETIRE_CONTRACT
else
    contract=$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); print((d.get(sys.argv[2]) or {}).get("task_retirement_contract") or "")' data/rigs.json "$MXFS_RIG_TAG")
fi
want=($prepargs ${MXFS_EXTRA_MODARGS:-})
[ -n "$contract" ] && want+=("target_retire_contract=\"$contract\"")

echo "LAP rejoin_modargs rejoin argv (${#got[@]}):$(printf ' [%s]' "${got[@]}")"
echo "LAP rejoin_modargs prep argv   (${#want[@]}):$(printf ' [%s]' "${want[@]}")"
if [ "$(printf '%s\n' "${got[@]}")" = "$(printf '%s\n' "${want[@]}")" ]; then
    echo "LAP rejoin_modargs PASS: the rejoin loads the module with prep_node.sh's arguments"
    exit 0
fi
echo "LAP rejoin_modargs FAIL: the rejoin's arguments differ from prep_node.sh's"
exit 1
