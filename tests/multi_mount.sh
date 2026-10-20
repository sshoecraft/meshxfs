#!/bin/bash
# multi_mount.sh — two MXFS filesystems mounted at once on the same hosts.
#
# Two pool LUNs, A and B, are bound to their nodes (the second with
# tools/lun_pool.sh alloc --also), each is formatted, and every member of each
# mounts it.  By default both have every node, so every node mounts both;
# MM_NODES_A / MM_NODES_B give each its own membership, e.g. A on test18,test19
# and B on test19,test20, so test19 shares one filesystem with each of the
# others (docs/host-dlm-lockspaces.md, "The test").  Every member writes and
# fsyncs files on each filesystem it mounts, and every member reads back and
# checksums every other member's files.  Each filesystem is unmounted and
# checked cold with chk_mxfs.
#
# What it measures, besides the integrity checks:
#   - each mount's wall time, against the mount budget below;
#   - the lock manager's connection setup: every filesystem on a host listens
#     on the same TCP port, which routes each connection to the mount whose
#     volume its NODE_JOIN names.  A connection for a volume no mount there
#     listens for (yet) is closed unread and resets at the connector ("reset
#     the handshake", counted and reported); any other handshake failure
#     ("peer: handshake reply from node N failed") is a FAIL.
#   - that every filesystem heard every peer's heartbeat: one lease per peer
#     per filesystem goes ACTIVE;
#   - every error, warning or BUG line the module printed during the run.
#
# Usage: tests/multi_mount.sh <tcp|caw> [node...]   (default nodes test18 test19)
# Env:   MM_NODES_A, MM_NODES_B  comma lists: the members of A and of B
#                    (default: every node given)
#        MM_PEERS=1  mount with peers=<the filesystem's members' addresses>
#                    (unicast discovery and heartbeat instead of multicast)
#        MM_ORDER=ab|ba  which filesystem the members mount first (default ab)
#        MM_CRASH=1  after the cross-read, destroy MM_VICTIM (default the last
#                    node) with its filesystems mounted.  On each filesystem it
#                    was a member of, every survivor must recover it and write
#                    again within RECOVER_BOUND_S and read back its fsynced
#                    files.  On a filesystem it was NOT a member of, every
#                    member keeps writing through the whole recovery window
#                    and no fsynced write may take longer than STEADY_MAX_MS:
#                    a death in one filesystem must not reach another.  The
#                    victim then boots, mounts its filesystems again and reads
#                    the survivors' new files.
#        MM_SIMUL_B=<cycles>  after the first mounts, unmount B on every member
#                    and mount it on all of them at the same instant, <cycles>
#                    times (the simultaneous-start race; see the loop)
#        MM_OPT_A, MM_OPT_B  more mount options for A or for B, e.g.
#                    MM_OPT_A=transport=tcp MM_OPT_B=transport=caw: one
#                    filesystem on each lock transport on the same hosts
#
# Budget (TIMEOUTS ARE PERFORMANCE ASSERTIONS): mkfs 0.6 s, first cluster
# mount 2.7 s, a later mount 4.8 s, umount 0.4 s (TIMEOUT_BUDGETS.md); on the
# network transport a node joining a mounted peer waits up to one BAST period
# (~10 s, D-ON-THE-TCP-TRANSPORT-A-NODE-MOUNTING-WHILE-ITS), so each mount is
# bounded at MOUNT_BOUND_S=25 s.  Workload: 2 x 8 MiB fsynced per node per
# filesystem, native well under 1 s; bounded at 30 s.  Whole run: LUN binds
# (~20 s each) + module load 5 s + 2 mkfs + one mount per membership +
# workload + one umount per membership + 2 chk ~ 150 s for two nodes; the crash
# arm adds recovery (<= 120 s), the boot (<= 180 s), the reload and the
# victim's mounts, ~ 380 s more.
set -u
cd "$(dirname "$0")/.."
REPO=$PWD
. "$REPO/tests/lib/runlock.sh"
. "$REPO/tools/mxfs_lab.sh"
SSH="$REPO/tools/mxfs_sshpass.sh"

TRANSPORT=${1:?usage: tests/multi_mount.sh <tcp|caw> [node...]}
shift
case "$TRANSPORT" in tcp|caw) ;; *) echo "transport is tcp or caw"; exit 2 ;; esac
NODES=("$@")
[ "${#NODES[@]}" -ge 1 ] || NODES=(test18 test19)
MM_NODES_A=${MM_NODES_A:-}
MM_NODES_B=${MM_NODES_B:-}
MA=(${MM_NODES_A//,/ })
MB=(${MM_NODES_B//,/ })
[ "${#MA[@]}" -ge 1 ] || MA=("${NODES[@]}")
[ "${#MB[@]}" -ge 1 ] || MB=("${NODES[@]}")
# every node of either membership, in order of first appearance
NODES=()
for n in "${MA[@]}" "${MB[@]}"; do
    case " ${NODES[*]} " in *" $n "*) ;; *) NODES+=("$n") ;; esac
done
ORDER=${MM_ORDER:-ab}
case "$ORDER" in ab|ba) ;; *) echo "MM_ORDER is ab or ba"; exit 2 ;; esac
MOUNT_BOUND_S=25
WORK_BOUND_S=30
UMOUNT_BOUND_S=15
CHK_BOUND_S=60
# a dead node is declared after the 62 s heartbeat window; its takeover, fence
# and journal replay measured 18 s (TIMEOUT_BUDGETS.md); x1.5
RECOVER_BOUND_S=120
# a filesystem the dead node was not in keeps writing for the whole window
STEADY_S=80
# one 64 KiB fsynced write on an idle filesystem takes milliseconds; a write
# that waits on another filesystem's recovery takes the 62 s window
STEADY_MAX_MS=2000
# destroy + start + boot of a rig VM ~150 s (TIMEOUT_BUDGETS.md), bounded at
# that: a boot is not the filesystem's to speed up, but it must not hang
BOOT_BOUND_S=180

members() { if [ "$1" = A ]; then echo "${MA[@]}"; else echo "${MB[@]}"; fi; }
member() {  # <node> <A|B> -> 0 iff the node mounts that filesystem
    case " $(members "$2") " in *" $1 "*) return 0 ;; esac
    return 1
}
mnt_of() { echo "/mnt/mm$1"; }

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
SHAPE=
[ -n "${MM_NODES_A:-}${MM_NODES_B:-}" ] && SHAPE=-A_${MM_NODES_A//,/_}-B_${MM_NODES_B//,/_}
OUT=$REPO/tests/evidence/multi_mount/$STAMP-$TRANSPORT$SHAPE${MM_PEERS:+-peers}${MM_CRASH:+-crash}${MM_OPT_A:+-optA_${MM_OPT_A//[=,]/_}}${MM_OPT_B:+-optB_${MM_OPT_B//[=,]/_}}-$ORDER-$(cat VERSION)
mkdir -p "$OUT"
exec > >(tee "$OUT/run.log") 2>&1
TAG=MMOUNT-$STAMP-$$
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
on() {  # <node> <bound s> <command>: run it on the node, bounded
    timeout "$2" "$SSH" "$1" "$3" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you'
}

echo "multi_mount: transport=$TRANSPORT A=[${MA[*]}] B=[${MB[*]}] order=$ORDER peers=${MM_PEERS:-0} optA=${MM_OPT_A:-} optB=${MM_OPT_B:-} evidence=$OUT"
runlock_take "$RUNLOCK" shared "multi_mount $TRANSPORT ${NODES[*]}" \
    || { echo "ABORT: the rig is held exclusively: $(runlock_holder "$RUNLOCK")"; exit 2; }
runlock_nodes "multi_mount $TRANSPORT" "${NODES[@]}" || exit 2

WANT_SV=$(modinfo -F srcversion mxfs.ko 2>/dev/null)
[ -n "$WANT_SV" ] || { echo "ABORT: no built mxfs.ko"; exit 2; }

LA=$(tools/lun_pool.sh alloc --owner $$ --what "multi_mount A $TAG" "${MA[@]}") \
    || { echo "ABORT: LUN A not allocated"; exit 2; }
LB=$(tools/lun_pool.sh alloc --also --owner $$ --what "multi_mount B $TAG" "${MB[@]}") \
    || { echo "ABORT: LUN B not allocated"; tools/lun_pool.sh free "$(sed -n 's/.* id=\([0-9]*\).*/\1/p' <<<"$LA")"; exit 2; }
echo "$LA"; echo "$LB"
IDA=$(sed -n 's/.* id=\([0-9]*\).*/\1/p' <<<"$LA"); DEVA=$(sed -n 's/.* dev=\([^ ]*\).*/\1/p' <<<"$LA")
IDB=$(sed -n 's/.* id=\([0-9]*\).*/\1/p' <<<"$LB"); DEVB=$(sed -n 's/.* dev=\([^ ]*\).*/\1/p' <<<"$LB")
[ "$IDA" != "$IDB" ] || { echo "ABORT: both allocations are lun$IDA"; exit 2; }
dev_of() { if [ "$1" = A ]; then echo "$DEVA"; else echo "$DEVB"; fi; }
cleanup() {
    for n in "${NODES[@]}"; do
        on "$n" 60 "for m in /mnt/mmB /mnt/mmA; do mountpoint -q \$m && timeout 30 umount \$m; done; true" >/dev/null
    done
    tools/lun_pool.sh free "$IDB" >/dev/null
    tools/lun_pool.sh free "$IDA" >/dev/null
}
trap cleanup EXIT

opt_of() {  # <A|B>: the filesystem's mount options
    local w=$1 o p="" n
    if [ "$w" = A ]; then o=${MM_OPT_A:-}; else o=${MM_OPT_B:-}; fi
    if [ -n "${MM_PEERS:-}" ]; then
        for n in $(members "$w"); do p="$p${p:+/}$(lab_addr "$n")"; done
        o="${o:+$o,}peers=$p"
    fi
    echo "$o"
}

# Load the tree's module on every node the way the fleet prep does (a local
# copy checked against this host's md5, the rig's module arguments and
# retirement contract), and mount nothing.
KO_MD5=$(md5sum mxfs.ko | awk '{print $1}')
# This checkout as the nodes see it (this host's ~/src is their /src).  The
# node-side prep, format and check run from it, so a sibling checkout's run
# loads its own mxfs.ko: without MXFS_REPO prep_node.sh loads /src/mxfs's
# module, whose md5 is not this checkout's, and every load from a sibling
# aborted ('mxfs.ko content never matched expected md5').
NODE_REPO=/src/$(basename "$REPO")
# /src (the tree, over NFS) is not mounted on a node that just booted
SRC_UP='mkdir -p /src; mountpoint -q /src || mount -t nfs -o rw,vers=4.1,hard,timeo=600,retrans=2,tcp 192.168.120.1:/src /src'
load_node() {  # <node>
    local n=$1 r sv d
    d=$DEVA; member "$n" A || d=$DEVB
    r=$(on "$n" 120 "echo $TAG-load > /dev/kmsg; $SRC_UP; mkdir -p /mnt/mmA /mnt/mmB; MXFS_NO_MOUNT=1 MXFS_REPO='$NODE_REPO' MXFS_DEV='$d' MXFS_KO_MD5='$KO_MD5' bash $NODE_REPO/tests/setup/prep_node.sh $TRANSPORT 2>&1 | grep -aE 'NODE_PREP_(OK|FAIL)'")
    sv=$(sed -n 's/.*srcversion=\([^ ]*\).*/\1/p' <<<"$r" | tr -d '\r ')
    [ "$sv" = "$WANT_SV" ] || { echo "$n prep: $r (want srcversion $WANT_SV)"; return 1; }
}
for n in "${NODES[@]}"; do
    load_node "$n" || { echo "ABORT: module load"; exit 2; }
done
echo "module $WANT_SV transport=$TRANSPORT on ${NODES[*]}"

# Format each on one of its members the way the fleet prep does (no live
# heartbeat writer, the stale SCSI reservation a previous holder left cleared,
# then mkfs_mxfs).
for w in A B; do
    f=$(members $w); f=${f%% *}
    r=$(on "$f" 60 "MXFS_REPO='$NODE_REPO' MXFS_DEV='$(dev_of $w)' MXFS_MOUNT=/mnt/mm_none bash $NODE_REPO/tests/setup/prep_fs.sh 2>&1 | tail -4; echo MKFS_RC=\${PIPESTATUS[0]}")
    grep -q 'MKFS_RC=0' <<<"$r" || { echo "ABORT: format $w on $f: $r"; exit 2; }
done
echo "formatted A $DEVA (lun$IDA) and B $DEVB (lun$IDB)"

mount_one() {  # <node> <A|B>
    local n=$1 w=$2 r ms o
    o=$(opt_of "$w")
    r=$(on "$n" $((MOUNT_BOUND_S + 5)) "t0=\$(date +%s%N); timeout $MOUNT_BOUND_S mount -t mxfs ${o:+-o $o} $(dev_of $w) $(mnt_of $w) 2>&1; rc=\$?; echo MOUNT_RC=\$rc MS=\$(( (\$(date +%s%N) - t0) / 1000000 ))")
    ms=$(sed -n 's/.*MS=\([0-9]*\).*/\1/p' <<<"$r")
    echo "mount $w on $n: $(grep -o 'MOUNT_RC=[0-9]*' <<<"$r") ${ms:-?} ms $(on "$n" 15 "findmnt -n -o OPTIONS $(mnt_of $w)" | grep -o 'transport=[a-z]*')"
    grep -q 'MOUNT_RC=0' <<<"$r" || { fail "mount $w on $n: $r"; return 1; }
    return 0
}

for w in $([ "$ORDER" = ab ] && echo A B || echo B A); do
    for n in $(members $w); do mount_one "$n" $w; done
done
[ "$FAILS" = 0 ] || { echo "RESULT: FAIL stage=mount fails=$FAILS evidence=$OUT"; exit 1; }

# MM_SIMUL_B=<cycles> (D-JOIN-OUTBOUND-HANDSHAKE-ECONNRESET-LOGGED-AS-ERROR-ON-A-
# JOIN-THAT-SUCCEEDS): with A mounted, unmount B on every member, then mount it
# on all of them at the same instant, <cycles> times.  A host routes each
# connection on its shared port by the volume its NODE_JOIN names, so a
# connect for B that beats the peer's own B mount to its listener is closed
# unread there ('a connection for no filesystem mounted here; closed') and
# reset at the connector.  The scan below counts both ends of that race.
SIMUL=${MM_SIMUL_B:-0}
case "$SIMUL" in *[!0-9]*) echo "MM_SIMUL_B is a cycle count"; exit 2 ;; esac
for c in $(seq 1 "$SIMUL"); do
    for n in $(members B); do
        r=$(on "$n" $((UMOUNT_BOUND_S + 5)) "timeout $UMOUNT_BOUND_S umount $(mnt_of B) 2>&1; echo UMOUNT_RC=\$?")
        grep -q 'UMOUNT_RC=0' <<<"$r" || { fail "simul cycle $c: unmount B on $n: $r"; break 2; }
    done
    sd=$(mktemp -d)
    spids=()
    for n in $(members B); do
        mount_one "$n" B > "$sd/$n" 2>&1 & spids+=($!)
    done
    src=0; for p in "${spids[@]}"; do wait "$p" || src=1; done
    echo "simul cycle $c: $(cat "$sd"/* | grep -o 'mount B on [a-z0-9]*: MOUNT_RC=[0-9]* [0-9?]* ms' | paste -sd' ')"
    rm -r "$sd"
    [ "$src" = 0 ] || { fail "simul cycle $c: a simultaneous mount of B failed"; break; }
done
[ "$FAILS" = 0 ] || { echo "RESULT: FAIL stage=simul fails=$FAILS evidence=$OUT"; exit 1; }

# Every member writes 2 x 8 MiB, fsynced, on each filesystem it mounts, all at
# once.  Each line SUM <A|B> <md5> <file>.
td=$(mktemp -d)
pids=()
for n in "${NODES[@]}"; do
    ms=""
    for w in A B; do member "$n" $w && ms="$ms $w"; done
    on "$n" $WORK_BOUND_S "t0=\$(date +%s%N); for w in $ms; do m=/mnt/mm\$w; mkdir -p \$m/$n; for i in 1 2; do head -c 8388608 /dev/urandom > \$m/$n/f\$i && sync -f \$m/$n/f\$i || echo WRITE_FAIL \$m \$i; done & done; wait; for w in $ms; do (cd /mnt/mm\$w/$n && md5sum f1 f2) | sed \"s/^/SUM \$w /\"; done; echo WORK_MS=\$(( (\$(date +%s%N) - t0) / 1000000 ))" > "$td/$n" &
    pids+=($!)
done
# Only the writers: a bare wait also waits for the tee behind this script's
# log, which never exits.
wait "${pids[@]}"
for n in "${NODES[@]}"; do
    echo "write on $n: $(grep -o 'WORK_MS=[0-9]*' "$td/$n")"
    grep -q WORK_MS "$td/$n" || fail "write on $n did not finish in ${WORK_BOUND_S}s: $(tail -3 "$td/$n")"
    grep -q WRITE_FAIL "$td/$n" && fail "write on $n: $(grep WRITE_FAIL "$td/$n")"
done

sums() { awk -v w=$2 '$1 == "SUM" && $2 == w {print $3}' "$td/$1" | tr '\n' ' '; }  # <writer> <A|B>
check_read() {  # <reader> <writer> <A|B> <what>
    local r=$1 n=$2 w=$3 want got
    want=$(echo $(sums "$n" $w))
    got=$(echo $(on "$r" 30 "cd /mnt/mm$w/$n && md5sum f1 f2" | awk 'NF == 2 {print $1}'))
    [ -n "$want" ] && [ "$want" = "$got" ] || fail "$r reads $4$n's files on $w: got [$got] want [$want]"
}

# Every member checksums every member's files on each filesystem.
for w in A B; do
    for r in $(members $w); do
        for n in $(members $w); do check_read "$r" "$n" $w ""; done
    done
done
echo "cross-read: every member read every member's files on each filesystem"

if [ -n "${MM_CRASH:-}" ] && [ "$FAILS" = 0 ]; then
    VICTIM=${MM_VICTIM:-${NODES[$((${#NODES[@]} - 1))]}}
    hit=""; spared=""
    for w in A B; do
        if member "$VICTIM" $w; then hit="$hit $w"; else spared="$spared $w"; fi
    done
    echo "crash: destroying $VICTIM (member of$hit; not of${spared:- nothing})"
    pd=$(mktemp -d)
    pids=()
    # On a filesystem the victim is not in, its members write steadily
    # through the whole window, timing every fsynced write.
    for w in $spared; do
        for s in $(members $w); do
            on "$s" $((STEADY_S + 30)) "m=/mnt/mm$w; mx=0; k=0; end=\$(( \$(date +%s) + $STEADY_S )); while [ \$(date +%s) -lt \$end ]; do t=\$(date +%s%N); head -c 65536 /dev/urandom > \$m/steady.$s && sync -f \$m/steady.$s || echo STEADY_FAIL; d=\$(( (\$(date +%s%N) - t) / 1000000 )); [ \$d -gt \$mx ] && mx=\$d; k=\$((k + 1)); sleep 0.5; done; echo STEADY_DONE max_ms=\$mx writes=\$k" > "$pd/steady.$w.$s" &
            pids+=($!)
        done
    done
    sleep 2
    timeout 60 sudo virsh -c qemu:///system destroy "$VICTIM" >/dev/null 2>&1 \
        || fail "virsh destroy $VICTIM"
    for w in $hit; do
        for s in $(members $w); do
            [ "$s" = "$VICTIM" ] && continue
            on "$s" $((RECOVER_BOUND_S + 5)) "m=/mnt/mm$w; t0=\$(date +%s%N); mkdir -p \$m/post && head -c 1048576 /dev/urandom > \$m/post/$s && sync -f \$m/post/$s && echo POSTSUM \$(md5sum < \$m/post/$s | cut -c1-32) && echo POST_OK \$(( (\$(date +%s%N) - t0) / 1000000 ))" > "$pd/post.$w.$s" &
            pids+=($!)
        done
    done
    wait "${pids[@]}"
    for w in $spared; do
        for s in $(members $w); do
            l=$(grep -a '^STEADY_DONE' "$pd/steady.$w.$s")
            mx=$(sed -n 's/.*max_ms=\([0-9]*\).*/\1/p' <<<"$l")
            echo "untouched $w on $s: ${l:-no result} (bound ${STEADY_MAX_MS} ms)"
            [ -n "$mx" ] || { fail "$s: the steady writer on $w never finished: $(tail -2 "$pd/steady.$w.$s")"; continue; }
            grep -q STEADY_FAIL "$pd/steady.$w.$s" && fail "$s: a write on $w failed while $VICTIM died"
            [ "$mx" -le "$STEADY_MAX_MS" ] || fail "$s: a write on $w took $mx ms while $VICTIM, not a member of $w, died"
        done
    done
    for w in $hit; do
        for s in $(members $w); do
            [ "$s" = "$VICTIM" ] && continue
            ms=$(sed -n 's/^POST_OK \([0-9]*\).*/\1/p' "$pd/post.$w.$s")
            echo "recovered $w on $s: wrote again ${ms:-NEVER} ms after the crash"
            [ -n "$ms" ] || fail "$s: $w did not take a write within ${RECOVER_BOUND_S}s of $VICTIM's death"
            check_read "$s" "$VICTIM" $w "the dead "
        done
    done
    echo "crash: survivors read the dead node's fsynced files"

    timeout 60 sudo virsh -c qemu:///system start "$VICTIM" >/dev/null 2>&1 || fail "virsh start $VICTIM"
    up=0
    for i in $(seq 1 $((BOOT_BOUND_S / 5))); do
        on "$VICTIM" 8 "echo UP" | grep -q '^UP' && { up=1; break; }
        sleep 5
    done
    [ "$up" = 1 ] || { fail "$VICTIM not back within ${BOOT_BOUND_S}s"; echo "RESULT: FAIL stage=reboot fails=$FAILS evidence=$OUT"; exit 1; }
    load_node "$VICTIM" || fail "$VICTIM reload after boot"
    for w in $hit; do mount_one "$VICTIM" $w; done
    for w in $hit; do
        for s in $(members $w); do
            [ "$s" = "$VICTIM" ] && continue
            want=$(sed -n 's/^POSTSUM \([0-9a-f]*\).*/\1/p' "$pd/post.$w.$s")
            got=$(on "$VICTIM" 30 "md5sum < /mnt/mm$w/post/$s" | awk 'NF == 2 {print $1}')
            [ -n "$want" ] && [ "$want" = "$got" ] || fail "rejoined $VICTIM reads $s's post-crash file on $w: got [$got] want [$want]"
        done
    done
    rm -rf "$pd"
    echo "crash: $VICTIM rejoined and read the survivors' post-crash files"
fi
rm -rf "$td"

# Unmount B everywhere first while A stays mounted, then A.
for w in B A; do
    for n in $(members $w); do
        r=$(on "$n" $((UMOUNT_BOUND_S + 5)) "t0=\$(date +%s%N); timeout $UMOUNT_BOUND_S umount /mnt/mm$w 2>&1; echo UMOUNT_RC=\$? MS=\$(( (\$(date +%s%N) - t0) / 1000000 ))")
        echo "umount $w on $n: $(grep -o 'UMOUNT_RC=[0-9]* MS=[0-9]*' <<<"$r")"
        grep -q 'UMOUNT_RC=0' <<<"$r" || fail "umount $w on $n: $r"
    done
done

for w in A B; do
    f=$(members $w); f=${f%% *}
    r=$(on "$f" $CHK_BOUND_S "$NODE_REPO/tools/chk_mxfs -n $(dev_of $w) 2>&1 | tail -3; echo CHK_RC=\${PIPESTATUS[0]}")
    echo "chk_mxfs $w on $f: $(grep -o 'CHK_RC=[0-9]*' <<<"$r")"
    grep -q 'CHK_RC=0' <<<"$r" || fail "chk_mxfs -n $w: $r"
done

# The kernel's account of the run, from this run's load mark on.
for n in "${NODES[@]}"; do
    on "$n" 30 "dmesg | sed -n '/$TAG-load/,\$p'" > "$OUT/dmesg.$n"
    hs=$(grep -ac 'handshake reply from node' "$OUT/dmesg.$n")
    hsr=$(grep -ac 'reset the handshake' "$OUT/dmesg.$n")
    rtc=$(grep -ac 'a connection for no filesystem mounted here; closed' "$OUT/dmesg.$n")
    bad=$(grep -aE 'mxfs|MXFS|XFS' "$OUT/dmesg.$n" | grep -aE 'BUG:|Oops|WARNING:|[Cc]orrupt[^=]|[Cc]orruption|EUCLEAN|Busy inodes|Shutting down|shut down|REFUSED' | head -5)
    # Every filesystem on this node must have heard every peer's heartbeat:
    # one lease per peer per filesystem goes ACTIVE.
    act=$(grep -ac 'transitioned to ACTIVE' "$OUT/dmesg.$n")
    want_act=0
    for w in A B; do
        member "$n" $w && want_act=$((want_act + $(members $w | wc -w) - 1))
    done
    echo "$n: handshake-reply failures=$hs, handshake resets=$hsr, connections closed here unrouted=$rtc, leases ACTIVE $act of $want_act"
    [ "$act" -ge "$want_act" ] || fail "$n: only $act of $want_act peer leases went ACTIVE: a filesystem here never heard a peer's heartbeat"
    # A reset is the peer's host refusing a connect that beat its mount's
    # listener (counted above, reported); any other handshake failure is not
    # explained by that race and fails the run.
    [ "$hs" = 0 ] || fail "$n: $hs handshake(s) failed: $(grep -a 'handshake reply from node' "$OUT/dmesg.$n" | head -2)"
    [ -z "$bad" ] || fail "$n kernel: $bad"
done

echo "RESULT: $([ "$FAILS" = 0 ] && echo PASS || echo FAIL) transport=$TRANSPORT A=[${MA[*]}] B=[${MB[*]}] order=$ORDER peers=${MM_PEERS:-0} fails=$FAILS evidence=$OUT"
[ "$FAILS" = 0 ]
