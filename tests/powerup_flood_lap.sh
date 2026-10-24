#!/bin/bash
# powerup_flood_lap.sh -- one lap of
# D-LANE-POWER-UP-FLOODS-THE-HOST-LOG-AND-ANOTHER-LANES-PREFLIGHT-REFUSES-ITS-PREP.
#
# A group's power-up floods the host's kernel log while its guests boot and log
# in to the target, and a prep whose host-safety preflight sampled the log rate
# inside that flood was refused ('kernel log is producing ~N lines/s'), so a lap
# of another lane aborted unexposed.  The fix: scripts/lab_power.sh up holds
# /tmp/mxfs_host_powerup.lock exclusive until every guest it started answers ssh,
# and scripts/clyde_preflight.sh takes that lock shared before it samples, so the
# sample is taken after a power-up, not inside one.  Neither the 40 lines/s limit
# nor the 3 s window changes.  LAB_POWER_LOCK=0 takes no lock on either side, as
# before: the control.
#
# The lap powers the group down, follows the host kernel log, powers the group up
# and, while the power-up runs, starts the preflight (--report, read-only, which
# prints the same log-rate line the gate grades) every STEP_S seconds, each with
# its own log:
#
#   EXPOSED  some 3 s window of the host kernel log during the power-up held
#            more than 40 lines/s, and at least one preflight was running then
#            (its start before the window's end, its end after the window's start)
#   PASS     every preflight printed 'kernel log ~N lines/s', none 'kernel log is
#            producing'
#   FAIL     a preflight printed 'kernel log is producing ~N lines/s'
#   ABORT    the power-down or power-up failed, or a preflight printed no
#            log-rate line
#
# Run it with no other lane up: its flood is what other lanes' preps would meet.
# The group is left up; the lane powers it down.
#
# Bound, derived from lane summaries of group g8b on 2026-10-24 (scripts/lab_power.sh
# down 3-5 s with nothing mounted, up 29-51 s): a preflight after the power-up's lock
# is released takes 7 s (median, run.sh's 'preflight starts' to 'passed' over 117
# preps), so down 5 + up 51 + preflight 7 = 63 s, twice that 126 s; 130 s.  The
# power-up itself is bounded by its own BOOT_S (240 s) inside the lap's bound.
#
# Usage: tests/powerup_flood_lap.sh <label> [group, default g8b]
#        LAB_POWER_LOCK=0 tests/powerup_flood_lap.sh <label> [group]   (control)
# Exit: 0 PASS, 1 FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
G=${2:-g8b}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$HERE/..
# a draft under tests/evidence/drafts/tree/tests runs against the tree it sits in
while [ ! -f "$REPO/scripts/lab_power.sh" ] || [ ! -f "$REPO/VERSION" ]; do
    [ "$REPO" = / ] && { echo "LAP powerup_flood ABORT label=$LABEL: no tree root above $HERE"; exit 2; }
    REPO=$(cd "$REPO/.." && pwd)
done
REPO=$(cd "$REPO" && pwd)
OUT="$REPO/tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_powerupflood_$LABEL"
mkdir -p "$OUT" || exit 2
STEP_S=${STEP_S:-5}
KMSG_MAX=40
log() { echo "$*" | tee -a "$OUT/lap.log"; }
abort() { log "LAP powerup_flood ABORT label=$LABEL: $*"; exit 2; }
log "LAP powerup_flood start $(date -u +%FT%TZ) group=$G LAB_POWER_LOCK=${LAB_POWER_LOCK:-unset} step_s=$STEP_S out=$OUT"

timeout 100 "$REPO/scripts/lab_power.sh" down "group:$G" > "$OUT/down.log" 2>&1 \
    || abort "power-down of group:$G failed: $(tail -1 "$OUT/down.log")"

# the host kernel log, one ISO-stamped line each, from before the power-up to its end
sudo -n timeout 300 dmesg --follow-new --time-format iso > "$OUT/kmsg.txt" 2>&1 & kp=$!
sleep 1
t0=$(date +%s)
timeout 260 "$REPO/scripts/lab_power.sh" up "group:$G" > "$OUT/up.log" 2>&1 & pu=$!
k=0
pids=()
while kill -0 "$pu" 2>/dev/null && [ "$k" -lt 48 ]; do
    ( s=$(date +%s.%N)
      timeout 260 "$REPO/scripts/clyde_preflight.sh" --report > "$OUT/pf_$k.log" 2>&1
      echo "PF_SPAN $s $(date +%s.%N)" >> "$OUT/pf_$k.log" ) & pids+=("$!")
    k=$((k + 1))
    sleep "$STEP_S"
done
wait "$pu"; rc_up=$?
for p in "${pids[@]}"; do wait "$p"; done
kill "$kp" 2>/dev/null; wait "$kp" 2>/dev/null
log "STEP power-up rc=$rc_up wall=$(( $(date +%s) - t0 )) s, $k preflight(s) started every ${STEP_S} s"
[ "$rc_up" = 0 ] || abort "power-up of group:$G failed rc=$rc_up: $(tail -1 "$OUT/up.log")"
[ "$k" -ge 1 ] || abort "no preflight started inside the power-up"

# the busiest 3 s of the host log, and whether a preflight was running then
read -r peak pstart <<<"$(awk '{ t = substr($1, 1, 19); n[t]++ } END {
        for (t in n) { cmd = "date -d " t " +%s"; cmd | getline e; close(cmd); c[e] += n[t] }
        for (e in c) { s = c[e] + c[e + 1] + c[e + 2]; if (s > m) { m = s; me = e } }
        print m + 0, me + 0 }' "$OUT/kmsg.txt")"
over=$(awk -v p="$peak" 'BEGIN { print (p / 3 > 40) ? 1 : 0 }')
overlap=0
for f in "$OUT"/pf_*.log; do
    read -r s e <<<"$(awk '/^PF_SPAN/ {print $2, $3}' "$f")"
    [ -n "${s:-}" ] || continue
    awk -v s="$s" -v e="$e" -v ws="$pstart" 'BEGIN { exit !(s < ws + 3 && e > ws) }' && overlap=$((overlap + 1))
done
log "STEP host kernel log: $(wc -l < "$OUT/kmsg.txt") lines over the power-up, busiest 3 s from $(date -u -d "@$pstart" +%T) held $peak ($(( peak / 3 )) lines/s); $overlap preflight(s) running then"
[ "$over" = 1 ] && [ "$overlap" -ge 1 ] \
    && log "EXPOSED: the power-up's kernel log held $(( peak / 3 )) lines/s over 3 s (limit $KMSG_MAX) while $overlap preflight(s) ran"

refused=0; sampled=0
for f in "$OUT"/pf_*.log; do
    if grep -q 'kernel log is producing' "$f"; then
        refused=$((refused + 1)); log "  $(basename "$f"): $(grep -m1 'kernel log is producing' "$f")"
    elif grep -q 'kernel log ~' "$f"; then
        sampled=$((sampled + 1))
    else
        abort "$(basename "$f") printed no log-rate line: $(tail -2 "$f" | tr '\n' '|')"
    fi
done
grep -h 'waited .* for a power-up' "$OUT"/pf_*.log | sort | uniq -c | sed 's/^/  /' | tee -a "$OUT/lap.log"
if [ "$refused" = 0 ]; then
    log "LAP powerup_flood PASS label=$LABEL: none of $k preflight(s) started inside group:$G's power-up was refused for the log rate ($sampled sampled under the limit)"
    exit 0
fi
log "LAP powerup_flood FAIL label=$LABEL: $refused of $k preflight(s) started inside group:$G's power-up refused for the log rate"
exit 1
