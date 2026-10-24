#!/bin/bash
# live_holder_shard_lap.sh -- one lap of
# D-LIVE-HOLDER-WAIT-FINDS-NO-REMOTE-MASTERED-INODE-AND-ABORTS-BEFORE-MEASURING,
# graded by the MASTER PROBE, never by arithmetic on inode numbers.
#
# tests/live_holder_wait.sh needs a candidate inode whose lock master is H, so
# that W's acquire is a remote request answered by H.  On the 0.90.134 dry run's
# capture gate (attempt 20261021T230333Z, H=test1, W=test2) the probe measured
# all eight candidates `master=local (P7S-BAST-FIRE test1=0 test2=1)`: W, the
# requester, mastered every one, and the harness ABORTed before measuring.
# The lap runs the harness's real selection and its real probe, on a pair the
# lap forms itself, and reads three things from what the probe measured:
#
#   EXPOSED  every one of the eight objects the pre-fix harness would have used
#            (objects 1-8: made first, back to back, under the same names; the
#            harness keeps them under LH_PROBE_ONLY=1 and probes each) was
#            measured mastered by a node other than H -- by W on two nodes.
#            That is the abort's precondition, measured on this formation.
#   PASS     the selection found an H-mastered candidate: the harness would go
#            on to measure (`PROBE-ONLY: target chosen`, rc 0).
#   FAIL     the selection ABORTed `none of the <n> candidates ... is
#            remote-mastered from W` (rc 2).
#   ABORT    anything else: the prep, the harness's preconditions, an overrun.
#
# LH_SHARD_SELECT=0 in the lap's environment is the harness's own same-build
# control: the eight objects back to back are the candidates, as before the fix.
# A control lap that is EXPOSED must FAIL, because its candidates ARE the eight.
#
# FRESH FORMATION EVERY LAP.  Which node masters a shard is
# active_nodes[page % N], with the active list sorted by node id
# (dlm/dlm.c:2448-2454, :13755-13758) and page = the seeded routing hash % npages
# (dlm/dlm.c:2436-2443; include/mxfs/mxfs_tauth.h:498-508).  The node id is a hash
# of a random per-mount UUID (dlm/v5_mount.c:20226-20230) and the seed is drawn
# at every mkfs (tools/mkfs_mxfs.c:2250).  On one formation the same inode
# numbers come back lap after lap (the freed numbers are reused: nine of the ten
# control laps of b20261023-3f3289 made 8388736-8388743), so laps on one
# formation are one draw repeated.  The lap therefore runs prep_cluster first
# (a fresh mkfs and fresh mounts: fresh seed, fresh ids); LHS_REFORM=0 skips it
# for a precheck on a pair already formed.
#
# THE SHARD MODEL IS MEASURED, NOT ASSUMED.  The lap records every probed
# inode's master by node, the routing version each member opened
# (P-TAUTH-OPEN hash_version=), and each member's node id (`TCP DLM initialized
# ... node_id=`), then groups the measured masters by routing shard: inodes in
# one shard must agree (a disagreement prints SHARD-MODEL CONTRADICTED), and two
# adjacent shards measured with different masters print SHARD-BOUNDARY.  None
# of that feeds the verdict; it is the evidence for the cause.
#
# NODE COUNTS.  Any N >= 2: MXFS_NODE_LIST names every member; H and W default
# to its first two and the rest go to the harness as LHW_HOLD, which probes them
# all and sizes its search from N (tests/live_holder_wait.sh, NODE COUNTS).  On
# N > 2, EXPOSED means none of the eight is H's (W's or a third member's).
#
# Bound, derived (2x what the steps should take):
#   prep_cluster on 2/net/mesh/direct measured 40 s and 44 s (lanes
#   g2c_jdt_control_20261022T232233Z and g2_attempt1011_20261023T101421Z,
#   step 2): bound 88 s.  The member reads: one ssh per member, concurrent,
#   ~0.5 s: bound 15 s each.  The harness: its checks before the setup ~3.6 s
#   (the gate's first probe ended at +9 s, a probe is ~5.4 s: idx=1 at +9 s to
#   idx=8 at +47 s), the setup <= 1.2 s, cleanup ~1.5 s, and P probes at 5.4 s:
#   P = 8 on the control (the candidates are the eight; the map re-probes none),
#   P = NSHARD + 7 with the fix (every candidate, plus objects 2-8 when they
#   share candidate 1's shard): 23 on two members.  The harness bound is
#   2 x (6.3 + 5.4 P) s: 99 s on the control, 261 s with the fix on two
#   members.  The lap: 44 + 0.5 + 49.5 = 94 s on the control (188 s at 2x),
#   44 + 0.5 + 130.5 = 175 s with the fix (350 s at 2x).
#
# Usage: tests/live_holder_shard_lap.sh <label> [H] [W]
# Env:   MXFS_NODE_LIST (test1,test2), MXFS_CONFIG (2/net/mesh/direct),
#        MXFS_GROUP (passed to run.sh), LHS_REFORM (1; 0 = the pair is formed),
#        LH_SHARD_SELECT (passed through; 0 = the control)
# Exit: 0 PASS, 1 FAIL, 2 ABORT (measured nothing).
set -u
LABEL=${1:?label}
cd "$(dirname "$0")/.." || exit 2
export MXFS_NODE_LIST=${MXFS_NODE_LIST:-test1,test2}
export MXFS_CONFIG=${MXFS_CONFIG:-2/net/mesh/direct}
read -r -a NL <<< "${MXFS_NODE_LIST//,/ }"
H=${2:-${NL[0]}}; W=${3:-${NL[1]:-}}
[ -n "$W" ] && [ "$H" != "$W" ] || { echo "LAP lh_master ABORT: need two distinct members (H=$H W=$W, MXFS_NODE_LIST=$MXFS_NODE_LIST)"; exit 2; }
HOLD=""
for n in "${NL[@]}"; do [ "$n" = "$H" ] || [ "$n" = "$W" ] || HOLD="$HOLD,$n"; done
HOLD=${HOLD#,}
MEMBERS="$H $W ${HOLD//,/ }"
NMEM=$(echo $MEMBERS | wc -w)
LHS_REFORM=${LHS_REFORM:-1}
SEL=${LH_SHARD_SELECT:-1}
SSH=tools/mxfs_sshpass.sh
OLDN=8
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_lhmaster_$LABEL
mkdir -p "$OUT" || exit 2
s0=$(date +%s)
el() { echo $(( $(date +%s) - s0 )); }

# the harness's bound (header): 2 x (6.3 + 5.4 P) s, P from the selection's size
if [ "$SEL" = 0 ]; then
    P=$OLDN
else
    NSHARD=$(awk -v n="$NMEM" 'BEGIN { x = 16 * log(2) / -log(1 - 1 / n); c = int(x); if (x - c > 1e-9) c++; print c }')
    P=$(( NSHARD + OLDN - 1 ))
fi
HB=$(( (2 * (63 + 54 * P) + 9) / 10 ))

echo "LAP lh_master start $(date -u +%FT%TZ) label=$LABEL H=$H W=$W hold=${HOLD:-none} members=$NMEM shard_select=$SEL reform=$LHS_REFORM harness_bound=${HB}s out=$OUT"

# 1. a fresh formation: fresh mkfs seed, fresh per-mount node ids
if [ "$LHS_REFORM" = 1 ]; then
    GROUPARG=()
    [ -n "${MXFS_GROUP:-}" ] && GROUPARG=(--group "$MXFS_GROUP")
    MXFS_FORCE_PREP=1 timeout -k 5 88 ./run.sh "$MXFS_CONFIG" "${GROUPARG[@]}" prep_cluster < /dev/null > "$OUT/prep.log" 2>&1
    prc=$?
    echo "STAGE prep rc=$prc wall=$(el)s $(grep -am1 'prep OK\|FAIL' "$OUT/prep.log" | cut -c1-140)"
    [ "$prc" = 124 ] && echo "LAP lh_master: prep_cluster overran its 88 s bound (rc 124)"
    [ "$prc" = 0 ] || { echo "LAP lh_master ABORT: prep_cluster rc=$prc (evidence $OUT/prep.log)"; exit 2; }
fi

# 2. each member's node id and the routing version it opened (evidence, not verdict)
pids=()
for n in $MEMBERS; do
    ( timeout 15 $SSH "$n" "dmesg | grep -a 'TCP DLM initialized' | tail -1; dmesg | grep -a 'P-TAUTH-OPEN' | tail -1" < /dev/null > "$OUT/member_$n.txt" 2>/dev/null
      echo $? > "$OUT/member_$n.rc" ) &
    pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done
HV=""
for n in $MEMBERS; do
    id=$(grep -ao 'node_id=[0-9]*' "$OUT/member_$n.txt" | tail -1 | cut -d= -f2)
    sl=$(grep -ao 'slot=-\?[0-9]*' "$OUT/member_$n.txt" | tail -1 | cut -d= -f2)
    hv=$(grep -ao 'hash_version=[0-9]*' "$OUT/member_$n.txt" | tail -1 | cut -d= -f2)
    np=$(grep -ao 'npages=[0-9]*' "$OUT/member_$n.txt" | tail -1 | cut -d= -f2)
    echo "MEMBER $n rc=$(cat "$OUT/member_$n.rc") node_id=${id:-unread} slot=${sl:-unread} routing_npages=${np:-unread} hash_version=${hv:-unread}"
    echo "${id:-unread} $n" >> "$OUT/view.txt"
    HV="$HV ${hv:-unread}"
done
HVS=$(echo $HV | tr ' ' '\n' | sort -u | tr '\n' ' ')
echo "VIEW active list sorted by node id (index = page % $NMEM): $(sort -n "$OUT/view.txt" | awk '{printf "%s%s(%s)", (NR > 1 ? " " : ""), $1, $2}')"
echo "ROUTING hash_version per member: ${HVS% }"

# 3. the harness's selection and master probe, stopped before the pause
hlog="$OUT/harness.log"
LH_PROBE_ONLY=1 LHW_HOLD="$HOLD" timeout -k 5 "$HB" tests/live_holder_wait.sh "lhm_$LABEL" "$H" "$W" < /dev/null > "$hlog" 2>&1
hrc=$?
grep -a '^===\|^  INFO candidate\|^  INFO map\|^  INFO target\|^OLD8\|^PROBE-\|^ABORT' "$hlog" | cut -c1-240
[ "$hrc" = 124 ] || [ "$hrc" = 137 ] && { echo "LAP lh_master ABORT: the harness overran its ${HB} s bound (rc $hrc)"; exit 2; }

# 4. every measured master, by node
awk -v H="$H" -v W="$W" '
    /^  INFO (candidate|map) idx=/ {
        kind = ($2 == "candidate") ? "candidate" : "map"; idx = ""; ino = ""; m = ""
        for (i = 3; i <= NF; i++) {
            if ($i ~ /^idx=/) idx = substr($i, 5)
            if ($i ~ /^ino=/) ino = substr($i, 5)
            if ($i ~ /^master=/) m = substr($i, 8)
        }
        node = (m == "remote") ? H : (m == "local") ? W : (m ~ /^third:/) ? substr(m, 7) : "-"
        print idx, ino, m, node, kind
    }' "$hlog" > "$OUT/masters.txt"
awk '$1 == "OLD8" {print $2, $3}' "$hlog" > "$OUT/old8.txt"
while read -r idx ino m node kind; do
    role=$kind; awk -v i="$idx" '$1 == i {f = 1} END {exit !f}' "$OUT/old8.txt" && role="$role,old8"
    echo "MASTER ino=$ino idx=$idx master=$m node=$node role=$role"
done < "$OUT/masters.txt"

# 5. exposure: the pre-fix harness's eight, as the probe measured them
n8=$(grep -ac . "$OUT/old8.txt")
read -r o8h o8w o8t o8u o8m <<< "$(awk -v H="$H" -v W="$W" '
    FILENAME == ARGV[1] { m[$1] = $4; next }
    { if (!($1 in m)) mis++; else if (m[$1] == H) h++; else if (m[$1] == W) w++; else if (m[$1] == "-") u++; else t++ }
    END { print h + 0, w + 0, t + 0, u + 0, mis + 0 }' "$OUT/masters.txt" "$OUT/old8.txt")"
o8inos=$(awk '{printf "%s%s", (NR > 1 ? " " : ""), $2}' "$OUT/old8.txt")
if [ "$n8" = "$OLDN" ] && [ "$o8h" = 0 ] && [ "$o8u" = 0 ] && [ "$o8m" = 0 ]; then
    echo "EXPOSED: the pre-fix harness's $OLDN candidates [$o8inos] were all measured mastered off H=$H (W=$W: $o8w, third: $o8t); it would have aborted on this formation"
    exposed=1
else
    echo "NOT-EXPOSED: the pre-fix harness's candidates [$o8inos] ($n8 of $OLDN listed): H=$o8h W=$o8w third=$o8t undetermined=$o8u unprobed=$o8m"
    exposed=0
fi

# 6. the shard model against the measurements (evidence for the cause, not the verdict)
HV1=$(echo $HVS)
case "$HV1" in
    2) SB=3 ;;
    1) SB=0 ;;
    *) SB=3; echo "SHARD-MODEL: routing version not one measured value (${HV1:-none}); grouped as version 2" ;;
esac
awk -v sb="$SB" '
    $4 != "-" { s = int($2 / (2 ^ sb)); key[s] = key[s] " " $2 ":" $4; if (!((s, $4) in seen)) { seen[s, $4] = 1; nm[s]++; mm[s] = mm[s] " " $4 } cnt[s]++ }
    END {
        for (s in cnt) {
            printf "SHARD shard=%d inos=%d masters=%s [%s ]\n", s, cnt[s], substr(mm[s], 2), key[s]
            if (cnt[s] > 1) multi++
            if (nm[s] > 1) { bad++; printf "SHARD-MODEL CONTRADICTED: shard %d has %d masters:%s\n", s, nm[s], mm[s] }
            if (((s + 1) in cnt) && nm[s] == 1 && nm[s + 1] == 1 && mm[s] != mm[s + 1])
                printf "SHARD-BOUNDARY: shard %d (%s) | shard %d (%s)\n", s, substr(mm[s], 2), s + 1, substr(mm[s + 1], 2)
            n++
        }
        printf "SHARD-MODEL: shard_bits=%d shards_measured=%d multi_inode_shards=%d disagreeing=%d\n", sb, n, multi, bad
    }' "$OUT/masters.txt" | sort

# 7. the verdict: what the harness's own selection did
echo "LAP lh_master candidates=$(grep -ac '^  INFO candidate' "$hlog") harness_rc=$hrc exposed=$exposed evidence=$OUT"
if [ "$hrc" = 0 ] && grep -aq '^PROBE-ONLY: target chosen' "$hlog"; then
    if [ "$SEL" = 0 ] && [ "$exposed" = 1 ]; then
        echo "LAP lh_master ABORT: the control's candidates are the eight, measured off H, yet its selection chose a target: the probe disagrees with itself"
        exit 2
    fi
    echo "LAP lh_master PASS: the selection found a candidate mastered by H=$H: $(grep -a '^  INFO target' "$hlog" | sed 's/^  INFO //' | cut -c1-160)"
    exit 0
fi
if [ "$hrc" = 2 ] && grep -aq '^ABORT: none of the [0-9]* candidates' "$hlog"; then
    echo "LAP lh_master FAIL: $(grep -a '^ABORT: none of the' "$hlog" | head -1 | cut -c1-200)"
    exit 1
fi
echo "LAP lh_master ABORT: the harness neither chose a target nor ran out of candidates (rc=$hrc): $(grep -a '^ABORT' "$hlog" | head -1 | cut -c1-200)"
exit 2
