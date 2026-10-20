#!/bin/bash
# churn_rows_audit.sh — does a churn file keep the inode its create was handed?
# (D-NETMESH-LIVE-FILE-INODE-FREED-UNDER-ITS-NAME-AFTER-NUMBER-REUSE)
#
# THE SHAPE.  On 8/net/mesh/mpath (0.90.51, lap r51fixB1) the cold audit found
# inode 12631170 named twice and 12631172 named by nothing.  One of the names
# was test13.1282.r, the LAST churn file test13's load left when the path_flap
# row stopped it: path rows run tests/mpath/pathload.py, whose churn creates
# <node>.<lap>, renames it to <node>.<lap>.r and unlinks <node>.<lap-1>.r, so
# every churn file is unlinked one lap later except a row's last.  When the
# next row's load restarted at lap 0 on the same mount, test13's allocator held
# 12631170 free from the start, i.e. the leftover name named a free inode.
# Inode numbers turn over every few ms under that churn (a pool of ~12 just-
# freed numbers per node), and no fault was injected in the window.
#
# WHY ROWS, AND WHY THE CHECKS.  A churn file freed under its name is invisible
# while the churn runs: the next lap's unlink of a dead name fails ENOENT,
# which pathload swallowed, and the name stayed.  Only a row's last file
# survives to be audited.  So this lap runs ROWS rows of the path load with no
# fault, all on one mount, each restarting at lap 0 exactly as consecutive
# path rows do, and checks three ways:
#   - PATHLOAD_VERIFY=1: before each unlink the churn checks the previous lap's
#     name still resolves to the inode its create was handed, with one link;
#     a failure is logged (verify.log) and the name left for the audit;
#   - after every row, from a node that did not create them and after dropping
#     its caches, every name each node's rows should have left (replayed from
#     their inos.log) is looked up and compared (pathload.py leftovers);
#   - at the end, the cold audit (run.sh chk_clean).
# Every node's whole kernel log (/root/dmesg.stream, started by the prep) is
# kept, and on any failure the LUN image too.
#
# VERDICT (written before the first lap):
#   CORRUPT  any VERIFY_FAIL, any LEFTOVER BAD or UNEXPECTED, or a CORRUPT
#            cold audit: the record's shape (or another integrity failure) on
#            this build; the lap names the file, the inode its create was
#            handed (inos.log), and every kernel-log line naming that inode.
#   FAIL     no corruption, but a load operation returned an error, the mutual
#            exclusion saw a double grant, a load did not report within its
#            bound after the stop (its stacks are kept), or a step overran.
#   CLEAN    every check passed and the audit is CLEAN errors=0.
#   A lap whose audit is STALE/NONE has no audit verdict and is rerun.
#
# BOUNDS (derived): prep 300 s (tests/suite/manifest prep_cluster); each row:
# load start 20 s, ROW_S, the stop and report 45 s (tests/mpath/lib.sh
# pf_load_stop), the leftover check 60 s (a cache drop and a lookup per
# leftover, seconds); chk_clean under run.sh's own budget; each node's kernel
# log 120 s in parallel (tests/noino_gen0_ab.sh).  At ROWS=6 ROW_S=60:
# 300 + 6 x 185 + chk_clean + 120 s, about 1700 s with the audit.
#
# Usage: tests/churn_rows_audit.sh <label> [config=8/net/mesh/mpath] [group=g8]
# Env:   ROWS (default 6), ROW_S (default 60)
# Exit 0 CLEAN, 1 CORRUPT or FAIL, 2 ABORT.
set -u
LABEL=${1:?label}
CONFIG=${2:-8/net/mesh/mpath}; GROUP=${3:-g8}
ROWS=${ROWS:-6}; ROW_S=${ROW_S:-60}
case "$ROWS$ROW_S" in *[!0-9]*) echo "ROWS and ROW_S must be numbers"; exit 2 ;; esac
cd "$(dirname "$0")/.." || exit 2
CO=$(basename "$PWD")
SSH=tools/mxfs_sshpass.sh
MNT=/mnt/shared
SHARED=$MNT/pathload/shared
NN=${CONFIG%%/*}
read -r -a GN <<< "$(tools/mxfs_lab.sh group "$GROUP")"
[ "${#GN[@]}" -ge "$NN" ] && [ "$NN" -ge 2 ] || { echo "RESULT: ABORT label=$LABEL -- group $GROUP has ${#GN[@]} nodes, $CONFIG needs $NN (>= 2)"; exit 2; }
NODES=("${GN[@]:0:$NN}")
. tests/lib/runlock.sh
vmhold_take "churn_rows_audit $LABEL" "${NODES[@]}" \
    || { echo "RESULT: ABORT label=$LABEL -- could not hold ${NODES[*]}"; exit 2; }
OUT=tests/evidence/$(date -u +%Y%m%dT%H%M%SZ)_churn_rows_$LABEL
mkdir -p "$OUT"
MARK="CHURN-ROWS-$LABEL-$$"
rs() { timeout "$1" "$SSH" "$2" "$3" < /dev/null 2>/dev/null | grep -av '^Warning\|^Unauthorized\|^If you'; }
t0=$(date +%s); el() { echo $(( $(date +%s) - t0 )); }
want=$(modinfo -F srcversion mxfs.ko)
echo "=== churn_rows_audit label=$LABEL $CONFIG $GROUP [${NODES[*]}] rows=$ROWS row_s=$ROW_S build=$want out=$OUT $(date -u +%FT%TZ) ==="

MXFS_FORCE_PREP=1 ./run.sh "$CONFIG" --group "$GROUP" prep_cluster > "$OUT/prep.log" 2>&1 \
    || { echo "RESULT: ABORT label=$LABEL stage=prep evidence=$OUT"; exit 2; }
for n in "${NODES[@]}"; do
    info=$(rs 20 "$n" "echo sv=\$(cat /sys/module/mxfs/srcversion) m=\$(grep -c ' $MNT mxfs ' /proc/mounts) stream=\$(test -s /root/dmesg.stream && echo 1 || echo 0)")
    echo "  INFO $n $info"
    [[ "$info" == *"sv=$want "* ]] || { echo "RESULT: ABORT label=$LABEL -- $n does not run this checkout's build $want ($info) evidence=$OUT"; exit 2; }
    [[ "$info" == *"m=1 "* ]] || { echo "RESULT: ABORT label=$LABEL -- $n is not mounted after the prep ($info) evidence=$OUT"; exit 2; }
    [[ "$info" == *"stream=1"* ]] || { echo "RESULT: ABORT label=$LABEL -- $n has no /root/dmesg.stream (the prep starts it) evidence=$OUT"; exit 2; }
    rs 12 "$n" "echo '$MARK' > /dev/kmsg" > /dev/null
done

# The stop file is local to each node (tests/mpath/lib.sh: a file made on the
# shared tree reaches a node's NFS client only when its negative lookup
# expires, up to a minute later).
STOP=/run/mxfs_churn_rows.$LABEL.$$.stop
loadfail=0; vfail=0; lbad=0; lunexp=0; errs=0; dgrant=0; stuck=0
row_dirs() {  # <node> <last row>: that node's run directories, in order, as the nodes see them
    local r
    for r in $(seq 1 "$2"); do printf ' /src/%s/%s/row%s/load_%s' "$CO" "$OUT" "$r" "$1"; done
}
for r in $(seq 1 "$ROWS"); do
    pids=()
    for n in "${NODES[@]}"; do
        mkdir -p "$OUT/row$r/load_$n"
        rs 20 "$n" "rm -f $STOP; PATHLOAD_VERIFY=1 nohup setsid python3 /src/$CO/tests/mpath/pathload.py run $n $MNT /src/$CO/$OUT/row$r/load_$n $STOP > /src/$CO/$OUT/row$r/load_$n/run.out 2>&1 < /dev/null &" > /dev/null &
        pids+=($!)
    done
    wait "${pids[@]}"
    sleep "$ROW_S"
    pids=()
    for n in "${NODES[@]}"; do ( rs 15 "$n" "touch $STOP" > /dev/null ) & pids+=($!); done
    wait "${pids[@]}"
    for n in "${NODES[@]}"; do
        f=$OUT/row$r/load_$n/run.out
        i=0; while [ $i -lt 45 ] && ! grep -aq '^PATHLOAD ' "$f" 2>/dev/null; do sleep 1; i=$((i + 1)); done
        pl=$(grep -a '^PATHLOAD ' "$f" 2>/dev/null | tail -1)
        if [ -z "$pl" ]; then
            stuck=$((stuck + 1))
            echo "  FAIL row $r: $n's load did not report within 45 s of the stop; its stacks follow"
            rs 40 "$n" "p=\$(cat /src/$CO/$OUT/row$r/load_$n/pid 2>/dev/null); echo \"== load pid=\$p state=\$(cut -d' ' -f3 /proc/\$p/stat 2>/dev/null)\"; cat /proc/\$p/stack 2>/dev/null; for d in /proc/[0-9]*; do [ \"\$(cut -d' ' -f3 \$d/stat 2>/dev/null)\" = D ] || continue; echo \"== \$d comm=\$(cat \$d/comm 2>/dev/null) state=D\"; cat \$d/stack 2>/dev/null; done" > "$OUT/row$r/stuck_stacks_$n.txt" 2>&1
            continue
        fi
        e=$(sed -n 's/.* err=\([0-9]*\).*/\1/p' <<<"$pl"); d=$(sed -n 's/.*double_grant=\([0-9]*\).*/\1/p' <<<"$pl"); v=$(sed -n 's/.*verify_fail=\([0-9]*\).*/\1/p' <<<"$pl")
        [ -n "$v" ] || { echo "RESULT: ABORT label=$LABEL -- $n's load printed no verify_fail= (a pathload without PATHLOAD_VERIFY?) evidence=$OUT"; exit 2; }
        lp=$(sed -n 's/.* laps=\([0-9]*\).*/\1/p' <<<"$pl")
        [ "${lp:-0}" -gt 1 ] || { echo "  FAIL row $r: $n's load ran ${lp:-no} laps in ${ROW_S} s"; loadfail=$((loadfail + 1)); }
        errs=$((errs + ${e:-0})); dgrant=$((dgrant + ${d:-0})); vfail=$((vfail + v))
        echo "  row $r $n: ${pl#PATHLOAD }"
        [ "${e:-0}" = 0 ] || grep -a ' ERR' "$OUT/row$r/load_$n/ops.log" | head -5 | sed 's/^/      /'
        [ "$v" = 0 ] || sed 's/^/      /' "$OUT/row$r/load_$n/verify.log" | head -10
    done
    # Each node's leftovers, looked up from the next node in the list after a
    # cache drop there.
    for k in "${!NODES[@]}"; do
        c=${NODES[$k]}; q=${NODES[$(( (k + 1) % ${#NODES[@]} ))]}
        lo=$(rs 60 "$q" "echo 2 > /proc/sys/vm/drop_caches; python3 /src/$CO/tests/mpath/pathload.py leftovers $c $SHARED$(row_dirs "$c" "$r")")
        printf '%s\n' "$lo" > "$OUT/row$r/leftovers_${c}_from_$q.txt"
        s=$(grep -a '^LEFTOVERS ' <<<"$lo" | tail -1)
        [ -n "$s" ] || { echo "  FAIL row $r: the leftover check of $c's names on $q returned nothing"; loadfail=$((loadfail + 1)); continue; }
        b=$(sed -n 's/.* bad=\([0-9]*\).*/\1/p' <<<"$s"); u=$(sed -n 's/.* unexpected=\([0-9]*\).*/\1/p' <<<"$s")
        lbad=$((lbad + b)); lunexp=$((lunexp + u))
        [ "$b$u" = 00 ] || { echo "  CORRUPT row $r: $c's names looked up on $q: $s"; grep -a '^LEFTOVER ' <<<"$lo" | head -10 | sed 's/^/      /'; }
    done
    echo "  row $r done at +$(el)s: verify_fail=$vfail leftover_bad=$lbad leftover_unexpected=$lunexp errors=$errs double_grant=$dgrant stuck=$stuck"
done

since=$(date -u +%FT%TZ)
./run.sh "$CONFIG" --group "$GROUP" chk_clean > "$OUT/chk.log" 2>&1
audit=$(python3 - data/criteria.json "$CONFIG" "$since" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
for e in d["criteria"]:
    if e.get("id") == "chk_clean":
        cell = (e.get("per_config") or {}).get(sys.argv[2]) or {}
        if str(cell.get("iso", "")) < sys.argv[3]:
            print("STALE"); break
        m = re.search(r"verdict=([A-Z]+).*?errors=(\d+)", str(cell.get("measured", "")))
        print("%s errors=%s" % m.groups() if m else "NONE")
        break
else:
    print("NONE")
PY
)
echo "cold audit: $audit ($OUT/chk.log)"
pids=()
for n in "${NODES[@]}"; do
    ( timeout 120 "$SSH" "$n" "gzip -c /root/dmesg.stream" < /dev/null 2>/dev/null > "$OUT/${n}_dmesg_stream.gz" ) & pids+=($!)
done
wait "${pids[@]}"
for n in "${NODES[@]}"; do echo "$n kernel log: $OUT/${n}_dmesg_stream.gz marks=$(zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | grep -acF -- "$MARK")"; done

# Every inode a failed check or the audit names: the inode a create was handed
# for each failed name, and every kernel-log line of every node naming it.
bad_inos=$(cat "$OUT"/row*/load_*/verify.log 2>/dev/null | grep -ao 'want_ino=[0-9]*\| ino=[0-9]*' | tr -dc '0-9\n' | sort -u)
bad_inos="$bad_inos $(cat "$OUT"/row*/leftovers_*.txt 2>/dev/null | grep -a '^LEFTOVER ' | grep -ao 'want_ino=[0-9]*\| ino=[0-9]*' | tr -dc '0-9\n' | sort -u)"
case "$audit" in
    CORRUPT*)
        alog=$(grep -ao 'evidence=/src/[^ ]*chk_clean_[0-9]*node_[0-9TZ]*\.log' "$OUT/chk.log" | head -1 | sed "s#^evidence=/src/#$HOME/src/#")
        if [ -n "$alog" ] && [ -r "$alog" ]; then cp "$alog" "$OUT/chk_audit.log"; else echo "WARN the audit log named by $OUT/chk.log ('${alog:-none named}') is not readable here"; fi
        grep -a 'ERROR' "$OUT/chk_audit.log" 2>/dev/null | head -12 | cut -c1-240
        bad_inos="$bad_inos $(cat "$OUT/chk.log" "$OUT/chk_audit.log" 2>/dev/null | grep -ao '(ino [0-9]*)\|inode [0-9]*' | tr -dc '0-9\n' | sort -u)" ;;
esac
bad_inos=$(echo $bad_inos | tr ' ' '\n' | grep -v '^$' | sort -un | paste -sd' ')
if [ -n "$bad_inos" ]; then
    echo "inodes named by a failed check or the audit: $bad_inos"
    for i in $bad_inos; do
        echo "  ino $i handed to: $(grep -ah " $i\$" "$OUT"/row*/load_*/inos.log 2>/dev/null | tail -3 | tr '\n' ';')"
    done
    for n in "${NODES[@]}"; do
        : > "$OUT/${n}_named_inos.txt"
        for i in $bad_inos; do
            zcat "$OUT/${n}_dmesg_stream.gz" 2>/dev/null | grep -a "ino=$i \|ino=$i\$\|ino $i \|inum=$i \|ip=$i " >> "$OUT/${n}_named_inos.txt"
        done
        echo "  $n kernel-log lines naming them: $(wc -l < "$OUT/${n}_named_inos.txt") ($OUT/${n}_named_inos.txt)"
    done
    csv=$(IFS=,; echo "${NODES[*]}")
    lun=$(tools/lun_pool.sh lookup --nodes "$csv" | sed -n 's/.* id=\([0-9]*\) .*/\1/p')
    snap=$([ -n "$lun" ] && tools/lun_pool.sh snapshot "$lun" "$GROUP-churn-rows-$LABEL") \
        && echo "image kept: $snap" || echo "image NOT kept: no pool LUN bound to [$csv]"
fi

REP="rows=$ROWS row_s=$ROW_S verify_fail=$vfail leftover_bad=$lbad leftover_unexpected=$lunexp load_errors=$errs double_grant=$dgrant stuck=$stuck check_failures=$loadfail audit=${audit// /_}"
if [ "$vfail" != 0 ] || [ "$lbad" != 0 ] || [ "$lunexp" != 0 ] || [[ "$audit" == CORRUPT* ]]; then
    echo "RESULT: CORRUPT churn_rows_audit label=$LABEL $REP evidence=$OUT"; exit 1
fi
case "$audit" in
    STALE*|NONE*) echo "RESULT: ABORT churn_rows_audit label=$LABEL $REP -- no audit verdict (rerun) evidence=$OUT"; exit 2 ;;
esac
if [ "$errs" != 0 ] || [ "$dgrant" != 0 ] || [ "$stuck" != 0 ] || [ "$loadfail" != 0 ]; then
    echo "RESULT: FAIL churn_rows_audit label=$LABEL $REP evidence=$OUT"; exit 1
fi
echo "RESULT: CLEAN churn_rows_audit label=$LABEL $REP evidence=$OUT"
exit 0
