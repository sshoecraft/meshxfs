# lap_load.sh — how a rig lap ends the tests/mpath/pathload.py loads it started
# on its nodes, and what it leaves of them in each node's /run.
#
# tests/noino_fence_efd_hold_lap.sh and tests/fenced_ledger_rig_lap.sh run a
# load on each node with its logs in /run/<lap>_<label> (a guest's /run is a
# tmpfs of ~360 MB).  The noino lap stopped its loads only on its normal path,
# so a lap that ABORTed after starting them left them running through the next
# lap's forced prep (D-NOINO-LAP-ABORT-LEAVES-ITS-LOADS-RUNNING-INTO-THE-NEXT-LAP);
# neither lap removed the logs, so 15 fenced_reason laps filled test1's /run and
# every load started there afterwards died on its first write
# (D-RIG-LAPS-LEAVE-LOAD-LOGS-IN-NODE-RUN-AND-A-FULL-RUN-KILLS-THE-NEXT-LOAD).
# Both laps end their loads here, from their exit trap, so every exit does it.
#
# An exit that cannot reach a node cannot stop that node's load: the abort the
# record was filed on came from S not answering (rc=124 under a flooded kernel
# log), and an ssh to that node to touch its stop file fails the same way.  So
# each load also runs under a deadline on its own node, and cannot outlive its
# lap whatever the node's reachability.
#
# lap_load_prefix <deadline s>
#   Prints the command a lap puts before its load's python3 (empty with
#   LAP_LOAD_DEADLINE=0) and records the start: 'timeout -k 5 <deadline>', so
#   the node itself ends the load at the deadline.  The deadline is twice the
#   load's planned life in the lap (each lap derives it).  LAP_LOAD_DEADLINE=0
#   starts the load with no deadline, as before: the control of that part.
#   Call it in the parent shell (it sets LAP_LOAD_T0 and LAP_LOAD_DL), then use
#   the value it put in LAP_LOAD_PFX.
lap_load_prefix() {
    LAP_LOAD_DL=${1:?lap_load_prefix: deadline}
    LAP_LOAD_T0=$(date +%s)
    LAP_LOAD_PFX=""
    [ "${LAP_LOAD_DEADLINE:-1}" != 0 ] && LAP_LOAD_PFX="timeout -k 5 $LAP_LOAD_DL"
    return 0
}
#
# lap_load_end <ld> <out dir> <node>...
#   On every node at once, each with its own ssh, bound and output file: touch
#   <ld>.stop and wait at most 45 s (the laps' bound on a load's report) for the
#   node's pathload of <ld> to exit; keep the load's .out, at most 500 of its
#   failed operations and the last 20 lines of its ops log in
#   <out dir>/<node>_load_end.txt; remove <ld>, <ld>.out and <ld>.stop.  Then
#   print one line a node:
#     LOAD-END <node> rc=<ssh rc> running=<its pathloads of <ld> still running> left=<of the 3 paths>
#   LAP_LOAD_STOP=0 neither touches the stop file nor waits, as the noino lap's
#   exit did before: the control of that part.
#   LAP_LOAD_CLEAN=0 removes nothing, as both laps did before: the control of
#   that part.
#   A node whose load this could not see end (its ssh failed, or the load still
#   ran) under a deadline from lap_load_prefix is waited for until that
#   deadline has passed, so the lap does not return while the load may run:
#     LOAD-END <node> waited <s> s for the load's deadline
#   Bound: the wait 45 s, the reads of a full ops log (124 MB measured) and the
#   removal under 10 s, so 60 s a node; the nodes run at once; then at most the
#   load's deadline from its start, plus 5 for timeout's kill.
# Needs tests/lib/rig.sh (rs) sourced first.
lap_load_end() {
    local ld=${1:?lap_load_end: load dir} out=${2:?lap_load_end: out dir} n i r l w unseen=0
    shift 2
    local stop=${LAP_LOAD_STOP:-1} clean=${LAP_LOAD_CLEAN:-1}
    local nodes=("$@") pids=() rcs=()
    # the load's argv ends '<ld> <ld>.stop' (pathload.py run <node> <mnt> <outdir> <stopfile>)
    local busy="ps -o args= -C python3 | grep -F 'pathload.py run' | grep -cF ' $ld $ld.stop'"
    local cmd=""
    [ "$stop" = 1 ] && cmd="touch $ld.stop; for t in \$(seq 1 45); do [ \"\$($busy)\" = 0 ] && break; sleep 1; done; "
    cmd="$cmd echo '--- out'; head -c 4000 $ld.out 2>/dev/null; echo; echo '--- failed operations'; grep -a ' ERR ' $ld/ops.log 2>/dev/null | head -500; echo '--- ops tail'; tail -20 $ld/ops.log 2>/dev/null; "
    [ "$clean" = 1 ] && cmd="$cmd rm -rf --one-file-system $ld $ld.out $ld.stop; "
    cmd="$cmd echo LOADEND_RUNNING=\$($busy); echo LOADEND_LEFT=\$(for p in $ld $ld.out $ld.stop; do [ -e \$p ] && echo \$p; done | wc -l)"
    for n in "${nodes[@]}"; do
        rs 60 "$n" "$cmd" > "$out/${n}_load_end.txt" 2>&1 &
        pids+=($!)
    done
    for i in "${!pids[@]}"; do
        wait "${pids[$i]}"
        rcs[$i]=$?
    done
    for i in "${!nodes[@]}"; do
        n=${nodes[$i]}
        r=$(sed -n 's/^LOADEND_RUNNING=\([0-9]*\)$/\1/p' "$out/${n}_load_end.txt" | tail -1)
        l=$(sed -n 's/^LOADEND_LEFT=\([0-9]*\)$/\1/p' "$out/${n}_load_end.txt" | tail -1)
        echo "LOAD-END $n rc=${rcs[$i]} running=${r:-?} left=${l:-?}"
        [ "${rcs[$i]}" = 0 ] && [ "${r:-?}" = 0 ] || unseen=$((unseen + 1))
    done
    if [ "$unseen" -gt 0 ] && [ -n "${LAP_LOAD_T0:-}" ] && [ "${LAP_LOAD_DEADLINE:-1}" != 0 ]; then
        w=$(( LAP_LOAD_T0 + LAP_LOAD_DL + 5 - $(date +%s) ))
        [ "$w" -gt 0 ] || w=0
        sleep "$w"
        echo "LOAD-END $unseen node(s) waited $w s for the load's deadline"
    fi
}
