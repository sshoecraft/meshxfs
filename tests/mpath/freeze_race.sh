#!/bin/bash
# tests/mpath/freeze_race.sh — the victim frozen at a chosen instant after its
# path a is cut, swept across the moment its commands on the dead path time
# out.
#
# path_fenced_return freezes the victim when its 2 s poll first sees
# multipathd fail path a, which lands within a second or two of the instant
# the victim's commands on that path time out (~15.5 s after the cut).  That
# is also when the victim, its stalled I/O answered, finishes what it was
# doing under the shared directory's lock and hands it to the survivor.  Once
# in 33 runs (20261016T013801Z-g2b) the survivor's own filesystem shut down
# at that instant instead (D-CAWMPATH-FENCED-RETURN-SURVIVOR-EIO-VICTIM-
# UNFENCED).  This row puts the freeze at offsets swept across that moment,
# lap after lap, so the instant is hit on purpose rather than by the poll's
# phase.
#
# Each lap:
#   1. the victim's (last node's) path a is cut
#   2. at cut + offset the victim is frozen (virsh suspend)
#   3. after FR_HOLD_S seconds, every node's load is read for an error since
#      the cut: a frozen peer may make the others wait, never fail
#   4. the victim is thawed and its path a restored; the lap ends when it has
#      2 usable paths again and its load completes operations
# A hold shorter than the death window (62 s) means nobody is fenced: the lap
# measures the handoff instant only.
#
# What a PASS claims: in FR_LAPS laps, freezes at offsets FR_LO_MS..FR_HI_MS
# after the cut, no node's load returned an error, no node's kernel log shows
# a shutdown or withdrawal, and the victim came back to 2 usable paths and a
# running load within 60 s of each thaw.  A FAIL keeps every node's followed
# kernel log in the evidence (kmsg_keep).
#
# derived time budget: gate 15 s + load warm-up 20 s + per lap (offset up to
# 17 s + suspend/resume 1 s + hold 4 s + path back ~10-20 s + load check 2 s,
# ~45 s) + stop ~10 s.  FR_LAPS=40: about 1850 s.
set -u
ROW=freeze_race
. "$(dirname "$0")/lib.sh"
LAPS=${FR_LAPS:-40}
LO=${FR_LO_MS:-14500}
HI=${FR_HI_MS:-17000}
HOLD=${FR_HOLD_S:-4}
# a kernel line that means a node's filesystem stopped serving
DOWN_RX='shutting down filesystem|forcing shutdown|lock unrecoverable|P-WITHDRAW-QUEUE|P163-WITHDRAW-STAMP|xfs_do_force_shutdown|filesystem has been shut down'

sleep_until() {  # <epoch ms>
    local d=$(( $1 - $(now_ms) ))
    [ "$d" -gt 0 ] && sleep "$(printf '%d.%03d' $((d / 1000)) $((d % 1000)))"
    return 0
}
errs_of() { local c; c=$(grep -ac ' ERR ' "$OUT/load_$1/ops.log" 2>/dev/null); echo "${c:-0}"; }
oks_of() { local c; c=$(grep -ac ' ok$' "$OUT/load_$1/ops.log" 2>/dev/null); echo "${c:-0}"; }
down_of() { rs 15 "$1" "grep -aciE '$DOWN_RX' $KFILE" 2>/dev/null | tail -1; }

main() {
[ "$N" -ge 2 ] || { why="needs 2 nodes, got $N"; finish FAIL "nodes=$N"; exit 1; }
pf_start_gate
pf_load_start
trap 'timeout 30 $VIRSH resume "$V" >/dev/null 2>&1; stop_loads "$NODES"; links_all_up; kmsg_keep; kmsg_stop' EXIT

local i off tc tz tr n e d o0 o1 back
for n in $NODES; do eval "E0_${n}=$(errs_of "$n")"; done
for i in $(seq 1 "$LAPS"); do
    off=$(( LO + (HI - LO) * (i - 1) / (LAPS > 1 ? LAPS - 1 : 1) ))
    tc=$(now_ms)
    link "$V" a down
    sleep_until $(( tc + off ))
    tools/lun_pool.sh fault timeout 30 $VIRSH suspend "$V" >/dev/null 2>&1
    tz=$(now_ms)
    [ "$($VIRSH domstate "$V" 2>/dev/null | head -1)" = paused ] || { why="lap $i: $V did not freeze"; fails=$((fails + 1)); break; }
    sleep "$HOLD"
    sleep 1     # the load pushes its log to the server twice a second
    local bad="" down=""
    for n in $NODES; do
        e=$(errs_of "$n"); eval "o0=\$E0_${n}"
        [ "$e" -gt "$o0" ] && bad="$bad $n:+$((e - o0))"
        eval "E0_${n}=$e"
    done
    for n in $(for x in $NODES; do [ "$x" = "$V" ] || echo "$x"; done); do
        d=$(down_of "$n"); [ "${d:-0}" -gt 0 ] 2>/dev/null && down="$down $n:$d"
    done
    timeout 30 $VIRSH resume "$V" >/dev/null 2>&1
    tr=$(now_ms)
    link "$V" a up
    o0=$(oks_of "$V")
    back=$(wait_usable "$V" "lap$i" 60)
    sleep 2
    o1=$(oks_of "$V")
    d=$(down_of "$V")
    echo "  LAP $i off_ms=$off frozen_at_ms=$((tz - tc)) held_ms=$((tr - tz)) errors=[${bad# }] survivor_down=[${down# }] victim_down=${d:-unread} paths_back_s=$back victim_ops_after_thaw=$((o1 - o0))"
    if [ -n "$bad" ] || [ -n "$down" ]; then
        why="lap $i (freeze at cut+$((tz - tc)) ms): errors [${bad# }] shutdown lines [${down# }]"; fails=$((fails + 1)); break
    fi
    if [ "${d:-0}" != 0 ]; then
        why="lap $i: the victim's kernel log shows a shutdown or withdrawal ($d lines)"; fails=$((fails + 1)); break
    fi
    [ "$back" -lt 60 ] 2>/dev/null || { why="lap $i: $V did not get 2 usable paths back within 60 s"; fails=$((fails + 1)); break; }
    [ $((o1 - o0)) -gt 0 ] || { why="lap $i: $V's load completed nothing after the thaw"; fails=$((fails + 1)); break; }
done

if [ "$fails" = 0 ]; then
    finish PASS "laps=$LAPS offsets_ms=$LO..$HI hold_s=$HOLD"
else
    finish FAIL "laps_run=$i offsets_ms=$LO..$HI hold_s=$HOLD"
fi
}
main
