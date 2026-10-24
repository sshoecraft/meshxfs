#!/bin/bash
# scst_pr_abort_shutdown_race.sh — D-HOST-SCST-PR-ABORT-SESSION-SHUTDOWN-PANIC-408
# verification: drive SCST's PERSISTENT RESERVE OUT / PREEMPT AND ABORT into the
# registrant-session teardown window that panicked clyde on 2026-08-23, on the
# FIXED target (+caw-abort-reclaim.5), and assert it is handled on both sides of
# the window and the host stays up.
#
# THE DEFECT (scst core, not MXFS): reg->tgt_dev keeps pointing at a session from
# scst_unregister_session() (shut_phase=SHUTDOWN, refcnt killed) until
# scst_free_session() clears it under dev_pr_mutex.  A PREEMPT AND ABORT from
# another initiator naming that registrant's key ran scst_pr_abort_reg() ->
# scst_rx_mgmt_fn_lun() on the dying session: percpu_ref_get on a killed (maybe
# zero) ref, then the READY sBUG in scst_post_rx_mgmt_cmd() -> host panic.  On
# the rig that window opens on EVERY kill-fence whose P&A lands ~60 s after the
# kill (iSCSI nop-in 30 s + response timeout 30 s).
#
# THE FIX (.5): scst_pr_abort_reg pins the session with percpu_ref_tryget
# (fails at zero -> "already released ... skipping"); a core-originated
# PR_ABORT_ALL is exempt from the READY sBUG ("PR ABORT ALL admitted on session
# ... in shut_phase N"); scst_rx_mgmt_fn rolls the PR counters back on a failed
# post.  Test-only module parameter scst.pr_abort_shutdown_delay_ms holds a
# session (a) in SHUTDOWN before the refcount kill and (b) after the refcount
# reached zero before its tgt_devs are freed, so both windows can be hit on
# purpose.
#
# ARMS
#   window  (default) deterministic, knob armed at DELAY ms:
#     A: X registers KX1 on its path-1 session only; X logs path 1 out; at
#        +DELAY/3 the peer Y issues PREEMPT AND ABORT on KX1 -> target must log
#        "PR ABORT ALL admitted on session ... (initiator X) in shut_phase 1".
#     B: X registers KX2 on its path-2 session only; X logs path 2 out; at
#        +DELAY+DELAY/3 (refcount is zero, tgt_devs still linked) Y issues
#        PREEMPT AND ABORT on KX2 -> target must log "PR ABORT: registrant ...
#        session ... is already released ... skipping".
#     Both P&As must return rc=0 at Y, both keys must be gone from PR IN
#     afterwards, and the host kernel log must carry no BUG/Oops/CRITICAL.
#   stress  knob OFF (the natural ~ms window): ITERS x { X registers KX on path
#     1, logs out, Y fires P&A on KX immediately, X logs back in }.  Asserts
#     no BUG/Oops/CRITICAL and every P&A rc=0; reports how many landed in the
#     window (either INFO line) — informational, the natural window is narrow.
#   handoff  (+caw-abort-reclaim.6) knob armed at DELAY ms, one path each:
#     Y registers KY and reserves the LU Write Exclusive Registrants Only; X
#     registers KX1 on its path-1 session, then that session's TCP connection
#     is reset (ss -K, as a path flap resets it) and iscsid recovers the same
#     session: it logs in again with the same ISID, so the target sees a new
#     session of the same I_T nexus while the old one is held in its teardown.
#     X then writes one 4 KiB block at the LU's end through path 1.  Once the
#     old session's holds are over, path 1 is reset again and Y issues PREEMPT
#     AND ABORT on KX1 at DELAY/3, while the session just left is still held in
#     SHUTDOWN with its refcount alive.
#     A logout and a login cannot stand in for the reset: open-iscsi builds a
#     session's ISID from its session id, and a login after a logout is a new
#     session with a new id, so a different I_T nexus that holds no
#     registration (measured 2026-10-24 on .6: ISIDs 0x100003d0200 and
#     0x200003d0200 for sids 1 and 2, and every write after such a re-login
#     refused RESERVATION CONFLICT, as SPC requires).  A registered nexus's write must succeed: the target must
#     log "PR: moving reg ... from shutting-down sess" for X and no
#     "Reservation conflict" for X's initiator before the P&A, and the P&A
#     must abort the earlier session too ("earlier session ... of the nexus").
#     On a target without the handoff (.5) the write is refused RESERVATION
#     CONFLICT until the old session is freed: that run is the control.
#     The block written is the LU's last 4 KiB; run it on a LUN the rig
#     formats again before it is mounted.
#   flap  (+caw-abort-reclaim.7) knob OFF, X's path 1 cut as a path row cuts
#     it: Y registers KY and reserves the LU Write Exclusive Registrants Only;
#     X registers KX1 on its path-1 session and starts a writer on that path's
#     own disk (the LU's last 4 KiB, O_DIRECT, one write every 0.1 s, each
#     stamped on X's clock with its exit code) and two readers (4 MiB direct
#     reads, so the target is executing a command of the session when the
#     cable goes).  X's cable on path 1's storage network is pulled
#     (scripts/san_net.sh link X <a|b> down) for 1.5-4 s and put back, then
#     FLAP_S s up, up to FLAPS times; the session recovers with the same ISID.
#     When the old session still has a command executing, its teardown waits
#     on it and it stays READY while the new session logs in: a gap login, read
#     from the host log (.7's handoff names shut_phase 0; on .6, no handoff and
#     the old session freed after the login).  Exposed when one of X's writes
#     was blocked across a gap login (issued before it, ended after it, on X's
#     clock): that write went out on the new session while the target held the
#     old one, as path_flap's refused writes did (measured 2026-10-24 on .6 in
#     a path_flap row: no "PR: moving reg", 16 writes refused RESERVATION
#     CONFLICT).  The flaps stop at the first exposure.  PASS: the target logged
#     the handoff of X's registrant, no "Reservation conflict" for X and no
#     write ended 'Invalid exchange' (EBADE, a refused write), a write
#     succeeded after the last login, then Y's PREEMPT AND ABORT of KX1 returns
#     0 and removes it.  A write failing EIO while the cable is out is the cut,
#     not the defect.  On .6 this arm fails: the control (2026-10-24: exposed at
#     flap 11, 27 writes refused).
#
# PRECONDITIONS: X and Y have NO mxfs mount (their sessions carry no MXFS PR
# key; the test keys are registered with --register-ignore and removed again).
# Other nodes may be mounted: only the test keys are ever preempted.  The knob
# delays EVERY session teardown on the host while armed; it is reset to 0 on
# exit (trap) and scripts/clyde_preflight.sh refuses a rig run while it is set.
#
# budget: every ssh bounded; window arm budget = 2 x (logout + DELAY*2 + login)
# ~ 2 x 12 s at DELAY=4000 plus ~10 ssh round trips -> 60 s; stress arm ~3 s
# per iteration.  the unkillable-wedge rule: no pgrep/ps.  the source-tree rule: lives in tests/.
#
# handoff arm budget: connection reset + iscsid's re-login (polled up to 20 s,
# 0.2 s apart) + path learn + write + P&A ~5 s inside the 2 x DELAY hold
# (DELAY=8000 for it), then the rest of the hold and cleanup: ~30 s, and at
# most ~45 s if the re-login takes the whole poll; the second reset and its P&A
# wait out the first session's holds and then hold a second session for 2 x
# DELAY: ~20 s more, ~50 s in all at DELAY=8000 (65 s at the poll's worst).
#
# flap arm budget: at most FLAPS=40 flaps of 1.5-4 s down and FLAP_S=4 s up,
# each followed by a read of the host log (~1 s), ~8.5 s a flap, stopping at the
# first exposed one: the .6 control was exposed at flap 11 (97 s in all), so a
# run takes ~100 s and at most ~340 s plus X's session back in LOGGED_IN (polled
# up to 30 s), 3 s more of writes, the P&A and cleanup (~10 s): ~385 s at worst.
# Run it on a two-path binding made with MXFS_MPATH_TMO=2 (the 2 s path
# timescale the failing rows ran); with the default 5 s timers the target frees
# the old session before iscsid logs in again and the gap is never reached.
#
# Usage: tests/scst_pr_abort_shutdown_race.sh <label> [window|stress|handoff|flap] [X=test1] [Y=test2] [DELAY_MS=4000] [ITERS=20]
# Env:   SPR_OUT (evidence dir, default tests/evidence/<label>_spr), MXFS_SCST_TGT, FLAP_S (flap arm, 4)
set -u
LABEL=${1:?label}; ARM=${2:-window}; X=${3:-test1}; Y=${4:-test2}; DELAY=${5:-4000}; ITERS=${6:-20}
case $ARM in window|stress|handoff|flap) ;; *) echo "arm must be window, stress, handoff or flap"; exit 2;; esac
[ "$X" = "$Y" ] && { echo "X and Y must differ"; exit 2; }
cd "$(dirname "$0")" || exit 2
# the tree root holds run.sh and tests/lib/rig.sh both, so a draft of this file run from a copy
# of tests/ alone finds the tree's own tools
while { [ ! -f run.sh ] || [ ! -f tests/lib/rig.sh ]; } && [ "$(pwd)" != / ]; do cd ..; done
[ -f run.sh ] || { echo "no tree root above $0"; exit 2; }
OUT=${SPR_OUT:-tests/evidence/${LABEL}_spr}; mkdir -p "$OUT"
SSH=tools/mxfs_sshpass.sh
TGT=${MXFS_SCST_TGT:-iqn.2026-05.local.mxfs:shared}
KNOB=/sys/module/scst/parameters/pr_abort_shutdown_delay_ms
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo -n"
KX1=0xabcd40801; KX2=0xabcd40802; KY=0xabcd40809
t0=$(date +%s)
flt() { grep -av '^Unauthorized\|^Warning:\|^If you'; }
rsh() { local h=$1; shift; timeout 25 $SSH "$h" "$*" 2>/dev/null | flt; }
echo "=== scst_pr_abort_shutdown_race label=$LABEL arm=$ARM X=$X Y=$Y delay=${DELAY}ms iters=$ITERS out=$OUT $(date -u +%FT%TZ) ==="

# --- host preconditions ------------------------------------------------------
sver=$(modinfo scst 2>/dev/null | awk '/^version:/{print $2}')
lver=$(cat /sys/module/scst/version 2>/dev/null)
minor=$(printf '%s' "$lver" | sed -n 's/.*+caw-abort-reclaim\.\([0-9]\+\)$/\1/p')
echo "scst: installed=$sver loaded=$lver"
[ -n "$minor" ] && [ "$minor" -ge 5 ] || { echo "FAIL: loaded scst '$lver' predates +caw-abort-reclaim.5 — NEVER run this against the unfixed target (it panics the host)"; exit 3; }
[ -f "$KNOB" ] || { echo "FAIL: $KNOB missing — loaded scst lacks the test knob"; exit 3; }
knob0=$(cat "$KNOB"); [ "$knob0" = 0 ] || echo "WARN: knob already armed ($knob0) at start"
setknob() { echo "$1" | $SUDO tee "$KNOB" >/dev/null; echo "knob=$(cat "$KNOB")"; }
trap 'setknob 0 >/dev/null 2>&1' EXIT

# --- node preconditions: no mxfs mount on X/Y; learn their per-portal disks ----
for n in $X $Y; do
    m=$(rsh $n "grep -c ' mxfs ' /proc/mounts" | tail -1 | tr -dc 0-9)
    [ "${m:-1}" = 0 ] || { echo "FAIL: $n has an mxfs mount (count=$m) — unmount it first; the test keys would collide with its PR registration"; exit 3; }
done
# portal -> sd device map from the initiator's own view (iscsiadm -P3)
learn_paths() {   # prints "portal_ip disk" lines for this target
    rsh "$1" "iscsiadm -m session -P3 2>/dev/null | awk '/^Target: /{t=\$2} /Current Portal:/{p=\$3; sub(/:3260.*/,\"\",p)} /Attached scsi disk/{ if (t ~ /$TGT/) print p, \$4 }'"
}
XP=$(learn_paths $X); YP=$(learn_paths $Y)
XP1_IP=$(printf '%s\n' "$XP" | sed -n 1p | awk '{print $1}'); XP1_DEV=$(printf '%s\n' "$XP" | sed -n 1p | awk '{print $2}')
XP2_IP=$(printf '%s\n' "$XP" | sed -n 2p | awk '{print $1}'); XP2_DEV=$(printf '%s\n' "$XP" | sed -n 2p | awk '{print $2}')
YP1_IP=$(printf '%s\n' "$YP" | sed -n 1p | awk '{print $1}'); YP1_DEV=$(printf '%s\n' "$YP" | sed -n 1p | awk '{print $2}')
echo "paths: X path1=$XP1_IP:/dev/$XP1_DEV path2=$XP2_IP:/dev/$XP2_DEV  Y path1=$YP1_IP:/dev/$YP1_DEV"
if [ "$ARM" = handoff ] || [ "$ARM" = flap ]; then
    [ -n "$XP1_DEV" ] && [ -n "$YP1_DEV" ] || { echo "FAIL: could not learn an iSCSI path on $X and on $Y (X='$XP' Y='$YP')"; exit 3; }
else
    [ -n "$XP1_DEV" ] && [ -n "$XP2_DEV" ] && [ -n "$YP1_DEV" ] || { echo "FAIL: could not learn 2 iSCSI paths on $X and 1 on $Y (X='$XP' Y='$YP')"; exit 3; }
fi
XIQN=$(rsh $X "cat /etc/iscsi/initiatorname.iscsi | sed -n 's/^InitiatorName=//p'" | tail -1)
echo "X iqn: $XIQN"

# Y's own registration (needed to issue PR OUT); --register-ignore overwrites any stale test key
yr=$(rsh $Y "sg_persist --out --register-ignore --param-sark=$KY /dev/$YP1_DEV 2>&1 | grep -v 'Peripheral device type\|SCST_FIO'; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' ')
echo "Y register $KY on /dev/$YP1_DEV: $yr"
case "$yr" in *rc=0*) ;; *) echo "FAIL: Y could not register its key"; exit 3;; esac
# A run killed before its cleanup leaves KY registered on whichever of Y's nexuses it used, and
# the handoff arm's reservation held by it, so this run's RESERVE through another nexus is refused
# (seen: a SIGKILLed qualification, then 'Y could not reserve the LU' twice). A PREEMPT naming Y's
# own key removes KY from every other nexus and, when one of them holds the reservation, moves it
# here; it touches no other key. The RELEASE then leaves the LU unreserved by the test.
py=$(rsh $Y "sg_persist --out --preempt --prout-type=5 --param-rk=$KY --param-sark=$KY /dev/$YP1_DEV 2>&1 | grep -v 'Peripheral device type\|SCST_FIO'; echo rc=\${PIPESTATUS[0]}; sg_persist --out --release --prout-type=5 --param-rk=$KY /dev/$YP1_DEV 2>&1 | grep -v 'Peripheral device type\|SCST_FIO'; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' ')
echo "Y purge of stale $KY (preempt own key, release): $py"
pa() {   # PREEMPT AND ABORT key $1 from Y; echoes "rc=N <text>"
    # --prout-type is mandatory for PREEMPT (type 5 = WE-RO, what MXFS fences with);
    # without it SCST answers ILLEGAL REQUEST before the PR path is even reached.
    rsh $Y "sg_persist --out --preempt-abort --prout-type=5 --param-rk=$KY --param-sark=$1 /dev/$YP1_DEV 2>&1 | grep -v 'Peripheral device type\|SCST_FIO'; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' '
}
keycount() { rsh $Y "sg_persist --in --read-keys /dev/$YP1_DEV 2>&1 | grep -ci '${1#0x}\$'" | tail -1 | tr -dc 0-9; }
logout_path() { rsh $1 "iscsiadm -m node -T $TGT -p $2:3260 -u 2>&1 | tail -1; echo rc=\$?" | tr '\n' ' '; }
login_path()  { rsh $1 "iscsiadm -m node -T $TGT -p $2:3260 -l 2>&1 | tail -1; echo rc=\$?" | tr '\n' ' '; }
hostlog() { journalctl -k --since "$1" --until "$2" 2>/dev/null; }
hostlogp() { journalctl -k -o short-iso-precise --since "$1" --until "$2" 2>/dev/null; }

fail=0
if [ "$ARM" = window ]; then
    # register the two test keys, one per X session
    r1=$(rsh $X "sg_persist --out --register-ignore --param-sark=$KX1 /dev/$XP1_DEV 2>&1 | grep -v 'Peripheral device type\|SCST_FIO'; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' ')
    r2=$(rsh $X "sg_persist --out --register-ignore --param-sark=$KX2 /dev/$XP2_DEV 2>&1 | grep -v 'Peripheral device type\|SCST_FIO'; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' ')
    echo "X register $KX1 on path1: $r1 | $KX2 on path2: $r2"
    echo "pr-in before: KX1=$(keycount $KX1) KX2=$(keycount $KX2) KY=$(keycount $KY)"
    setknob "$DELAY"
    third=$(( DELAY / 3000 )); [ $third -ge 1 ] || third=1
    # --- window A: SHUTDOWN with the initial ref still held -------------------
    TA=$(date -u +%FT%T.%3NZ); ta=$(date +%s)
    lo=$(logout_path $X $XP1_IP); echo "A: X logout path1 at $TA: $lo"
    sleep $third
    paA=$(pa $KX1); echo "A: P&A $KX1 from Y at +$(( $(date +%s) - ta ))s: $paA"
    # wait out the rest of both holds so session 1 is fully freed before B
    sleep $(( (2 * DELAY) / 1000 + 1 ))
    # --- window B: refcount zero, tgt_devs still linked ------------------------
    TB=$(date -u +%FT%T.%3NZ); tb=$(date +%s)
    lo=$(logout_path $X $XP2_IP); echo "B: X logout path2 at $TB: $lo"
    sleep $(( DELAY / 1000 + third ))
    paB=$(pa $KX2); echo "B: P&A $KX2 from Y at +$(( $(date +%s) - tb ))s: $paB"
    sleep $(( DELAY / 1000 + 1 ))
    setknob 0
    TE=$(date -u +%FT%T.%3NZ)
    hostlog "$TA" "$TE" > "$OUT/host_kmsg.txt"
    echo "pr-in after: KX1=$(keycount $KX1) KX2=$(keycount $KX2) KY=$(keycount $KY)"
    li1=$(login_path $X $XP1_IP); li2=$(login_path $X $XP2_IP); echo "X re-login: path1 $li1 | path2 $li2"
    adm=$(grep -ac "PR ABORT ALL admitted on session .*${X}-mxfs-node" "$OUT/host_kmsg.txt")
    rel=$(grep -ac "PR ABORT: registrant .* is already released" "$OUT/host_kmsg.txt")
    holdA=$(grep -ac "holding session .*${X}-mxfs-node.* in SHUTDOWN" "$OUT/host_kmsg.txt")
    holdB=$(grep -ac "holding released session .*${X}-mxfs-node" "$OUT/host_kmsg.txt")
    bad=$(grep -ac 'BUG:\|Oops\|CRITICAL ERROR\|New mgmt cmd while shutting down\|SCST_PR_ABORT_ALL failed' "$OUT/host_kmsg.txt")
    echo "host: admitted_during_shutdown=$adm released_skip=$rel holdA=$holdA holdB=$holdB bad=$bad  (host_kmsg.txt $(wc -l < "$OUT/host_kmsg.txt") lines)"
    grep -a 'PR ABORT\|holding' "$OUT/host_kmsg.txt" | cut -c1-220 | sed 's/^/  /'
    case "$paA" in *rc=0*) ;; *) echo "FAIL: window-A P&A did not return rc=0: $paA"; fail=1;; esac
    case "$paB" in *rc=0*) ;; *) echo "FAIL: window-B P&A did not return rc=0: $paB"; fail=1;; esac
    [ "$adm" -ge 1 ] || { echo "FAIL: window A not exercised — no 'PR ABORT ALL admitted on session' line for $X (holdA=$holdA)"; fail=1; }
    [ "$rel" -ge 1 ] || { echo "FAIL: window B not exercised — no 'already released ... skipping' line for $X (holdB=$holdB)"; fail=1; }
    [ "$(keycount $KX1)" = 0 ] && [ "$(keycount $KX2)" = 0 ] || { echo "FAIL: a test key survived its PREEMPT AND ABORT"; fail=1; }
    [ "$bad" = 0 ] || { echo "FAIL: BUG/Oops/CRITICAL/unexpected error on the host during the window"; fail=1; }
elif [ "$ARM" = handoff ]; then
    rv=$(rsh $Y "sg_persist --out --reserve --prout-type=5 --param-rk=$KY /dev/$YP1_DEV 2>&1 | grep -v 'Peripheral device type\|SCST_FIO'; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' ')
    echo "Y reserve Write Exclusive Registrants Only with $KY: $rv"
    case "$rv" in *rc=0*) ;; *) echo "FAIL: Y could not reserve the LU"; exit 3;; esac
    r1=$(rsh $X "sg_persist --out --register-ignore --param-sark=$KX1 /dev/$XP1_DEV 2>&1 | grep -v 'Peripheral device type\|SCST_FIO'; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' ')
    echo "X register $KX1 on path1: $r1"
    # the block written: the LU's last 4 KiB, through path 1's own disk
    sz=$(rsh $X "blockdev --getsize64 /dev/$XP1_DEV" | tail -1 | tr -dc 0-9)
    [ -n "$sz" ] && [ "$sz" -gt 4096 ] || { echo "FAIL: could not read the LU's size on $X (/dev/$XP1_DEV)"; exit 3; }
    seek=$(( sz / 4096 - 1 ))
    xwrite() { rsh $X "dd if=/dev/zero of=/dev/$1 bs=4096 count=1 seek=$seek oflag=direct conv=notrunc status=none 2>&1 | tail -1; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' '; }
    # X is registered, so a write before the re-login goes through: the arm
    # measures the re-login, not a missing registration
    w0=$(xwrite "$XP1_DEV"); echo "X write before the re-login: $w0"
    case "$w0" in *rc=0*) ;; *) echo "FAIL: X's write was refused before the re-login; the reservation or the registration is not what the arm needs"; exit 3;; esac
    setknob "$DELAY"
    TA=$(date -u +%FT%T.%3NZ); ta=$(date +%s%3N)
    # reset path 1's connection, then wait (on the node, in one ssh) to see the session leave
    # LOGGED_IN and come back to it: iscsid's recovery of the same session, the same ISID
    rc1=$(rsh $X "h=\$(readlink -f /sys/block/$XP1_DEV/device/../..); s=\$(basename \$h); sid=\${s#session}; ss -K dst $XP1_IP dport = :3260 >/dev/null 2>&1; echo kill_rc=\$? \$s; seen=; for i in \$(seq 1 100); do st=\$(iscsiadm -m session -r \$sid -P1 2>/dev/null | sed -n 's/.*iSCSI Session State: //p'); [ \"\$st\" != LOGGED_IN ] && seen=\${seen:-\$st@\$i}; [ -n \"\$seen\" ] && [ \"\$st\" = LOGGED_IN ] && { echo left=\$seen back=LOGGED_IN@\$i; exit 0; }; sleep 0.2; done; echo left=\${seen:-never} back=no last=\$st" | tr '\n' ' ')
    tl=$(( $(date +%s%3N) - ta ))
    XP1_DEV=$(learn_paths $X | awk -v ip="$XP1_IP" '$1==ip{print $2}' | head -1)
    w1=$(xwrite "${XP1_DEV:-null}"); tw=$(( $(date +%s%3N) - ta ))
    echo "handoff: X path1 connection reset at $TA: $rc1 (+${tl} ms; 0.2 s polls) | path1 now /dev/${XP1_DEV:-none} | write at +${tw} ms: $w1"
    case "$rc1" in *back=LOGGED_IN*) ;; *) echo "FAIL: not exercised — X's path-1 session did not leave LOGGED_IN and recover after its connection reset: $rc1"; fail=1;; esac
    # Second part: PREEMPT AND ABORT must also reach the nexus's earlier session while that one
    # still holds its refcount (inside the first hold), since the registrant has moved off it and
    # it may still carry commands it admitted. The write above cannot be that moment: iscsid's
    # re-login completes only once the old session has left SHUTDOWN (measured +8.7 s at
    # DELAY=8000, 2026-10-24), so a P&A after it finds the earlier session's refcount at zero,
    # where .6 skips it by design (nothing is left to abort). So the earlier session's holds are
    # waited out, path 1 is reset again, and the P&A goes in at DELAY/3, inside the new hold.
    left_ms=$(( 2 * DELAY - ($(date +%s%3N) - ta) )); [ "$left_ms" -gt 0 ] || left_ms=0
    sleep $(( left_ms / 1000 + 1 ))
    TB=$(date -u +%FT%T.%3NZ); tb=$(date +%s%3N)
    rc2=$(rsh $X "ss -K dst $XP1_IP dport = :3260 >/dev/null 2>&1; echo kill_rc=\$?" | tr '\n' ' ')
    sleep $(( DELAY / 3000 ))
    paA=$(pa $KX1); tp=$(( $(date +%s%3N) - tb ))
    echo "handoff: X path1 connection reset again at $TB: $rc2 | P&A $KX1 from Y at +${tp} ms (first hold ${DELAY} ms): $paA"
    sleep $(( (2 * DELAY) / 1000 + 1 ))
    setknob 0
    TE=$(date -u +%FT%T.%3NZ)
    hostlog "$TA" "$TE" > "$OUT/host_kmsg.txt"
    rr=$(rsh $Y "sg_persist --out --release --prout-type=5 --param-rk=$KY /dev/$YP1_DEV 2>&1 | grep -v 'Peripheral device type\|SCST_FIO'; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' ')
    echo "Y release: $rr"
    echo "pr-in after: KX1=$(keycount $KX1) KY=$(keycount $KY)"
    # .6 logs "from shutting-down sess", .7 "from earlier sess ... (shut_phase N"
    mov=$(grep -ac "PR: moving reg .*${X}-mxfs-node.* from \(shutting-down\|earlier\) sess" "$OUT/host_kmsg.txt")
    conf=$(grep -ac "Reservation conflict (dev .*${X}-mxfs-node" "$OUT/host_kmsg.txt")
    earlier=$(grep -ac "PR ABORT: registrant .*${X}-mxfs-node.* earlier session .* of the nexus" "$OUT/host_kmsg.txt")
    held=$(grep -ac "holding session .*${X}-mxfs-node.* in SHUTDOWN" "$OUT/host_kmsg.txt")
    bad=$(grep -ac 'BUG:\|Oops\|CRITICAL ERROR\|New mgmt cmd while shutting down\|SCST_PR_ABORT_ALL failed' "$OUT/host_kmsg.txt")
    echo "host: handoff=$mov conflicts_for_X=$conf earlier_session_aborted=$earlier held_in_shutdown=$held bad=$bad  (host_kmsg.txt $(wc -l < "$OUT/host_kmsg.txt") lines)"
    grep -a 'PR: moving\|PR ABORT\|holding\|Reservation conflict' "$OUT/host_kmsg.txt" | cut -c1-220 | sed 's/^/  /'
    # the knob holds the old session twice, DELAY in SHUTDOWN and DELAY more with its refcount at
    # zero and its tgt_devs still linked (the registrant still on them); the reset waits for
    # neither, so a write before both holds end lands while the old tgt_dev still holds the
    # registrant, which is the gap
    [ "$held" -ge 1 ] && [ "$tw" -lt $(( 2 * DELAY )) ] || { echo "FAIL: not exercised — the old session was not held (held=$held) or the write came after both holds (+${tw} ms, holds 2 x ${DELAY} ms)"; fail=1; }
    case "$w1" in *rc=0*) ;; *) echo "FAIL: X's write through its new path-1 session was refused although X is registered: $w1"; fail=1;; esac
    [ "$conf" = 0 ] || { echo "FAIL: the target refused $conf command(s) of the registered nexus after its re-login"; fail=1; }
    [ "$mov" -ge 1 ] || { echo "FAIL: the target logged no handoff of X's registrant to the new session"; fail=1; }
    case "$paA" in *rc=0*) ;; *) echo "FAIL: the P&A did not return rc=0: $paA"; fail=1;; esac
    [ "$held" -ge 2 ] && [ "$tp" -lt "$DELAY" ] || { echo "FAIL: not exercised — the second reset's session was not held (held=$held, want 2) or the P&A came after its first hold (+${tp} ms, hold ${DELAY} ms)"; fail=1; }
    [ "$earlier" -ge 1 ] || { echo "FAIL: the P&A did not abort the earlier session of X's nexus"; fail=1; }
    [ "$(keycount $KX1)" = 0 ] || { echo "FAIL: KX1 survived its PREEMPT AND ABORT"; fail=1; }
    [ "$bad" = 0 ] || { echo "FAIL: BUG/Oops/CRITICAL/unexpected error on the host during the window"; fail=1; }
elif [ "$ARM" = flap ]; then
    FLAP_S=${FLAP_S:-4}; FLAPS=${FLAPS:-40}
    # path 1's storage network: the lab file names each network's subnet, whose .1 is its portal
    . tools/mxfs_lab.sh
    FLAP_NET=""
    for k in a b; do v=$(lab_need san "$k" 2>/dev/null); [ -n "$v" ] && [ "${v##*,}.1" = "$XP1_IP" ] && FLAP_NET=$k; done
    [ -n "$FLAP_NET" ] || { echo "FAIL: path 1's portal $XP1_IP is on neither storage network the lab file names"; exit 3; }
    trap 'setknob 0 >/dev/null 2>&1; scripts/san_net.sh link "$X" "$FLAP_NET" up >/dev/null 2>&1' EXIT
    rv=$(rsh $Y "sg_persist --out --reserve --prout-type=5 --param-rk=$KY /dev/$YP1_DEV 2>&1 | grep -v 'Peripheral device type\|SCST_FIO'; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' ')
    echo "Y reserve Write Exclusive Registrants Only with $KY: $rv"
    case "$rv" in *rc=0*) ;; *) echo "FAIL: Y could not reserve the LU"; exit 3;; esac
    r1=$(rsh $X "sg_persist --out --register-ignore --param-sark=$KX1 /dev/$XP1_DEV 2>&1 | grep -v 'Peripheral device type\|SCST_FIO'; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' ')
    echo "X register $KX1 on path1: $r1"
    sz=$(rsh $X "blockdev --getsize64 /dev/$XP1_DEV" | tail -1 | tr -dc 0-9)
    [ -n "$sz" ] && [ "$sz" -gt 4096 ] || { echo "FAIL: could not read the LU's size on $X (/dev/$XP1_DEV)"; exit 3; }
    seek=$(( sz / 4096 - 1 ))
    w0=$(rsh $X "dd if=/dev/zero of=/dev/$XP1_DEV bs=4096 count=1 seek=$seek oflag=direct conv=notrunc status=none 2>&1 | tail -1; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' ')
    echo "X write before the cut: $w0"
    case "$w0" in *rc=0*) ;; *) echo "FAIL: X's write was refused before the cut; the reservation or the registration is not what the arm needs"; exit 3;; esac
    sinfo=$(rsh $X "h=\$(readlink -f /sys/block/$XP1_DEV/device/../..); s=\$(basename \$h); echo \$s recovery_tmo=\$(cat /sys/class/iscsi_session/\$s/recovery_tmo); iscsiadm -m session -r \${s#session} -P2 2>/dev/null | grep -iE 'nop|timeout' | tr -s ' ' | tr '\n' ';'" | tr '\n' ' ')
    echo "X path1 session: $sinfo"
    sid=$(printf '%s' "$sinfo" | sed -n 's/^session\([0-9]*\) .*/\1/p')
    [ -n "$sid" ] || { echo "FAIL: could not name X's path-1 session"; exit 3; }
    WLOG=/tmp/spr_flap_writes.log; WERR=/tmp/spr_flap_writes.err; WSTOP=/tmp/spr_flap_writes.stop
    W="end=\$(( \$(date +%s) + $(( FLAPS * 10 + 60 )) )); while [ \$(date +%s) -lt \$end ] && [ ! -e $WSTOP ]; do s=\$(date +%s%3N); dd if=/dev/zero of=/dev/$XP1_DEV bs=4096 count=1 seek=$seek oflag=direct conv=notrunc status=none 2>>$WERR; rc=\$?; echo \"\$s \$(date +%s%3N) \$rc\" >> $WLOG; sleep 0.1; done"
    st=$(rsh $X "rm -f $WLOG $WERR $WSTOP; nohup setsid timeout $(( FLAPS * 10 + 70 )) bash -c '$W' > /dev/null 2>&1 < /dev/null & echo writer_started")
    echo "X writer on /dev/$XP1_DEV: $st"
    # Reads in flight on the same path, so the target is executing a command of the old session
    # when the cable goes: at 00:52:29Z test18's old session had a READ in EXEC_WAIT ('deferring
    # ABORT'), its NEXUS_LOSS_SESS waited on it, and the session stayed READY while the new one
    # logged in.  An idle old session is torn down at once, and .6 handed its registrant over in
    # every such login of a 40-flap run (2026-10-24).  Reads need no registration under Write
    # Exclusive Registrants Only, so they are never refused.
    R="end=\$(( \$(date +%s) + $(( FLAPS * 10 + 60 )) )); while [ \$(date +%s) -lt \$end ] && [ ! -e $WSTOP ]; do dd if=/dev/$XP1_DEV of=/dev/null bs=4M count=16 iflag=direct status=none 2>/dev/null; done"
    st=$(rsh $X "nohup setsid timeout $(( FLAPS * 10 + 70 )) bash -c '$R' > /dev/null 2>&1 < /dev/null & nohup setsid timeout $(( FLAPS * 10 + 70 )) bash -c '$R' > /dev/null 2>&1 < /dev/null & echo readers_started")
    echo "X readers on /dev/$XP1_DEV (two, 4 MiB direct reads): $st"
    # The gap exists only while the target still holds the old session: a new session of X's
    # nexus created before the old one is freed.  iscsi-scst names a session's SID (TSIH above the
    # 48-bit ISID) when it creates and frees it.  Read in log order, the session last created with
    # X's ISID is the nexus's current one; a session of that ISID freed while another is current
    # was still held by the target when the newer one logged in.
    held_count() {   # host_kmsg.txt -> the gap logins on stdout; each login, classified, into held.txt
        local csid isid
        csid=$(grep -a "Session .* created: .*initiator .*${X}-mxfs-node" "$OUT/host_kmsg.txt" | head -1 | sed -n 's/.* sid 0x\([0-9a-f]*\),.*/\1/p')
        isid=${csid: -12}
        # A new login of X's nexus is a gap login when the old session was still READY at it:
        # .7 names the phase in its handoff ("from earlier sess ... (shut_phase 0"); .6 logs a
        # handoff only from a session already shutting down, so on .6 a login with no handoff
        # line whose old session is freed after it is one.  The handoff line precedes the
        # "Session ... created" line of the same login (scst_pr_init_tgt_dev runs inside it).
        awk -v isid="$isid" -v x="${X}-mxfs-node" '
            isid == "" { next }
            /PR: moving reg / && index($0, x) {
                mv = 1; ph = ($0 ~ /from shutting-down sess/) ? 1 : -1
                if (match($0, /shut_phase [0-9]+/)) ph = substr($0, RSTART + 11, RLENGTH - 11) + 0
            }
            /Session .* created: / && index($0, x) {
                s = $0; sub(/.* sid 0x/, "", s); sub(/,.*/, "", s)
                if (substr(s, length(s) - 11) != isid) next
                n++; t[n] = $1; sid[n] = s; prev[n] = cur; cur = s
                if (mv) kind[n] = (ph == 0) ? "gap(handoff from a READY session)" : "shutdown(handoff from a session already shutting down)"
                else kind[n] = "nomove"
                mv = 0
            }
            # a session of the ISID freed while a newer one is current was alive at the login of
            # that newer one (the old session of the first login was created before the window)
            /Freeing session .*\(SID / {
                s = $0; sub(/.*\(SID /, "", s); sub(/\).*/, "", s)
                if (substr(s, length(s) - 11) == isid && n > 0 && s != cur && kind[n] == "nomove")
                    kind[n] = "gap(old session freed after the login, no handoff)"
            }
            END {
                for (i = 1; i <= n; i++) {
                    if (kind[i] == "nomove") kind[i] = "nogap(old session gone before the login)"
                    print t[i] " " sid[i] " " kind[i] > "/dev/stderr"
                    if (kind[i] ~ /^gap/) g++
                }
                print g + 0
            }' "$OUT/host_kmsg.txt" 2> "$OUT/held.txt"
    }
    # Exposed: one of X's writes was blocked across a gap login and went out on the new session
    # while the target held the old one READY (issued before the login, ended after it), the
    # write path_flap's refused writes were.  Host times are mapped to X's clock with the offset
    # measured below.
    spanning() {
        local t k c n=0
        while read -r t _ k; do
            case "$k" in gap*) ;; *) continue ;; esac
            c=$(( $(date -d "$t" +%s%3N) + off ))
            n=$(( n + $(awk -v c="$c" '$1 < c && $2 > c' "$OUT/writes.log" | wc -l) ))
        done < "$OUT/held.txt"
        echo "$n"
    }
    # X's clock less this host's.  Read from one ssh call's midpoint it came out ~rtt/2 high: the
    # call's ~400 ms round trip is mostly the connection's setup, and X runs date at the end of
    # it (test15, 2026-10-24: midpoint -223..-236 ms, 3 ms round trips on an open session -428
    # ms), so every login was placed ~200 ms late on X's clock and the writes the new session
    # carried, which end 33-54 ms after it, read as ended before it: flap1 and flap2 of the .7
    # qualification graded 6 and 7 gap logins with a blocked write each as NOT EXPOSED
    # (D-SCST-FLAP-ARM-CLOCK-OFFSET-READS-SSH-SETUP).
    # The offset is now the midpoint of the shortest of five round trips on one open session.
    # SPR_OFFSET_MIDPOINT=1 takes one call's midpoint, as before: the control.
    if [ "${SPR_OFFSET_MIDPOINT:-0}" = 1 ]; then
        h0=$(date +%s%3N); n0=$(rsh $X "date +%s%3N" | tail -1 | tr -dc 0-9); h1=$(date +%s%3N)
        off=$(( n0 - (h0 + h1) / 2 )); rtt=$(( h1 - h0 ))
    else
        coproc CLK { timeout 30 $SSH "$X" 'echo ready; while read -r l; do date +%s%3N; done' 2>/dev/null; }
        rtt=""; off=""
        while read -t 25 -r l <&"${CLK[0]}"; do [ "$l" = ready ] && break; done
        if [ "$l" = ready ]; then
            for i in 1 2 3 4 5; do
                h0=$(date +%s%3N); echo x >&"${CLK[1]}"; read -t 5 -r n0 <&"${CLK[0]}" || break; h1=$(date +%s%3N)
                n0=$(printf '%s' "$n0" | tr -dc 0-9)
                if [ -n "$n0" ] && { [ -z "$rtt" ] || [ $(( h1 - h0 )) -lt "$rtt" ]; }; then
                    rtt=$(( h1 - h0 )); off=$(( n0 - (h0 + h1) / 2 ))
                fi
            done
        fi
        exec {CLK[1]}>&-
        [ -n "$off" ] || { echo "FAIL: could not read X's clock over an open session"; exit 3; }
    fi
    echo "X's clock - this host's: ${off} ms (round trip ${rtt} ms)"
    sleep 1
    TA=$(date -u +%FT%T.%3NZ); ta=$(date +%s%3N)
    # As path_flap cuts it, a cable pulled and put back, but the cut's length is varied (1.5 to
    # 4 s) and the flaps stop at the first new login that met the old session still held.  The
    # gap needs the cable back before the NOP-Out sent into the cut times out, so the initiator's
    # close of the old connection and its new login reach the target together (00:52:29Z on .6:
    # 8 ms from test18's 'ping timeout' to its first refused write); where the cut falls against
    # the NOP-Out and TCP retransmission timers decides it, and ten fixed 4 s flaps met it in
    # neither of two runs.
    cuts=(1.5 2 2.5 3 3.5 4)
    oldlive=0; f=0
    while [ "$f" -lt "$FLAPS" ]; do
        f=$((f + 1)); d=${cuts[$(( (f - 1) % ${#cuts[@]} ))]}
        scripts/san_net.sh link "$X" "$FLAP_NET" down >> "$OUT/links.log" 2>&1; sleep "$d"
        scripts/san_net.sh link "$X" "$FLAP_NET" up >> "$OUT/links.log" 2>&1; sleep "$FLAP_S"
        hostlogp "$TA" "$(date -u +%FT%T.%3NZ)" > "$OUT/host_kmsg.txt"
        oldlive=$(held_count)
        exposed=0
        if [ "$oldlive" -ge 1 ]; then rsh $X "cat $WLOG" > "$OUT/writes.log"; exposed=$(spanning); fi
        echo "flap $f: ${d} s down, ${FLAP_S} s up: $(grep -ac "Session .* created: .*initiator .*${X}-mxfs-node" "$OUT/host_kmsg.txt") new session(s) so far, $oldlive of them gap login(s), $exposed write(s) sent across one"
        [ "$exposed" -ge 1 ] && break
    done
    lb=$(timeout 35 $SSH "$X" "for i in \$(seq 1 150); do n=\$(iscsiadm -m session -r $sid -P1 2>/dev/null | grep -c State:.LOGGED_IN); [ \"\$n\" = 1 ] && { echo logged_in_ms=\$(date +%s%3N); exit 0; }; sleep 0.2; done; echo logged_in=never" 2>/dev/null | flt | tr '\n' ' ')
    echo "flap: X's session $sid after the last flap: $lb (+$(( $(date +%s%3N) - ta )) ms)"
    sleep 3
    rsh $X "touch $WSTOP" > /dev/null; sleep 1
    rsh $X "cat $WLOG" > "$OUT/writes.log"; rsh $X "cat $WERR" > "$OUT/writes.err"
    paA=$(pa $KX1); echo "flap: P&A $KX1 from Y: $paA"
    sleep 2
    TE=$(date -u +%FT%T.%3NZ)
    hostlogp "$TA" "$TE" > "$OUT/host_kmsg.txt"
    oldlive=$(held_count); exposed=$(spanning)
    rr=$(rsh $Y "sg_persist --out --release --prout-type=5 --param-rk=$KY /dev/$YP1_DEV 2>&1 | grep -v 'Peripheral device type\|SCST_FIO'; echo rc=\${PIPESTATUS[0]}" | tr '\n' ' ')
    echo "Y release: $rr"
    echo "pr-in after: KX1=$(keycount $KX1) KY=$(keycount $KY)"
    back_ms=$(printf '%s' "$lb" | sed -n 's/.*logged_in_ms=\([0-9]*\).*/\1/p')
    nw=$(grep -c . "$OUT/writes.log"); nwbad=$(awk '$3 != 0' "$OUT/writes.log" | wc -l)
    after=0
    [ -n "$back_ms" ] && after=$(awk -v b="$back_ms" '$1 >= b && $3 == 0' "$OUT/writes.log" | wc -l)
    # a write the cut fails ends EIO once the session's recovery timeout passes, which is the cut;
    # a RESERVATION CONFLICT ends EBADE, 'Invalid exchange' (blk_status_to_errno), which is the gap
    afterbad=$(grep -c 'Invalid exchange' "$OUT/writes.err")
    mov=$(grep -ac "PR: moving reg .*${X}-mxfs-node" "$OUT/host_kmsg.txt")
    conf=$(grep -ac "Reservation conflict (dev .*${X}-mxfs-node" "$OUT/host_kmsg.txt")
    bad=$(grep -ac 'BUG:\|Oops\|CRITICAL ERROR\|New mgmt cmd while shutting down\|SCST_PR_ABORT_ALL failed' "$OUT/host_kmsg.txt")
    echo "writes: $nw in all, $nwbad failed ($afterbad of them refused 'Invalid exchange', the rest the cut's EIO); $after succeeded after the last flap's login"
    echo "host: handoff=$mov conflicts_for_X=$conf bad=$bad  (host_kmsg.txt $(wc -l < "$OUT/host_kmsg.txt") lines)"
    grep -a 'PR: moving\|PR ABORT\|Reservation conflict\|unexpectedly closed\|Session .* created' "$OUT/host_kmsg.txt" | grep -a "${X}-mxfs-node\|PR ABORT" | cut -c1-230 | sed 's/^/  /'
    sed 's/^/  /' "$OUT/held.txt"
    if [ "$exposed" -ge 1 ] && [ "$after" -ge 1 ]; then
        echo "EXPOSED: $exposed of X's writes went out on a new login while the target still held the old session of X's nexus READY ($oldlive such login(s) in $f flap(s)); $after write(s) succeeded after the last login"
    else
        echo "NOT EXPOSED: $f flap(s), $oldlive gap login(s), $exposed write(s) sent across one, $after write(s) succeeded after the last login"; fail=1
    fi
    [ "$conf" = 0 ] || { echo "FAIL: the target refused $conf command(s) of the registered nexus after its re-login"; fail=1; }
    [ "$afterbad" = 0 ] || { echo "FAIL: $afterbad of X's writes were refused RESERVATION CONFLICT ('Invalid exchange') although X is registered"; fail=1; }
    [ "$mov" -ge 1 ] || { echo "FAIL: the target logged no handoff of X's registrant to the new session"; fail=1; }
    case "$paA" in *rc=0*) ;; *) echo "FAIL: the P&A did not return rc=0: $paA"; fail=1;; esac
    [ "$(keycount $KX1)" = 0 ] || { echo "FAIL: KX1 survived its PREEMPT AND ABORT"; fail=1; }
    [ "$bad" = 0 ] || { echo "FAIL: BUG/Oops/CRITICAL/unexpected error on the host during the window"; fail=1; }
else
    TA=$(date -u +%FT%T.%3NZ)
    echo "pr-in before: KX1=$(keycount $KX1) KY=$(keycount $KY)"
    ok=0; inwin=0
    for i in $(seq 1 $ITERS); do
        rsh $X "sg_persist --out --register-ignore --param-sark=$KX1 /dev/$XP1_DEV >/dev/null 2>&1; iscsiadm -m node -T $TGT -p $XP1_IP:3260 -u >/dev/null 2>&1 &" >/dev/null
        r=$(pa $KX1)
        case "$r" in *rc=0*) ok=$((ok+1));; *) echo "iter $i: P&A $r";; esac
        rsh $X "iscsiadm -m node -T $TGT -p $XP1_IP:3260 -l >/dev/null 2>&1; echo" >/dev/null
        XP1_DEV=$(learn_paths $X | awk -v ip="$XP1_IP" '$1==ip{print $2}' | head -1)
        [ -n "$XP1_DEV" ] || { echo "iter $i: path1 did not come back on $X"; break; }
    done
    sleep 2
    TE=$(date -u +%FT%T.%3NZ)
    hostlog "$TA" "$TE" > "$OUT/host_kmsg.txt"
    inwin=$(grep -ac "PR ABORT ALL admitted on session\|PR ABORT: registrant .* is already released" "$OUT/host_kmsg.txt")
    bad=$(grep -ac 'BUG:\|Oops\|CRITICAL ERROR\|New mgmt cmd while shutting down\|SCST_PR_ABORT_ALL failed' "$OUT/host_kmsg.txt")
    echo "stress: iters=$ITERS pa_ok=$ok in_window_lines=$inwin bad=$bad"
    [ "$ok" = "$ITERS" ] || { echo "FAIL: only $ok/$ITERS P&As returned rc=0"; fail=1; }
    [ "$bad" = 0 ] || { echo "FAIL: BUG/Oops/CRITICAL/unexpected error on the host"; fail=1; }
fi

# cleanup: drop Y's test key; X keys are gone by preemption (or dropped here).
# SCST re-links a surviving registrant to a re-logged-in session by TransportID,
# and the sd names may have moved after the re-login — re-learn them first.
XP=$(learn_paths $X)
XP1_DEV=$(printf '%s\n' "$XP" | awk -v ip="$XP1_IP" '$1==ip{print $2}' | head -1)
XP2_DEV=$(printf '%s\n' "$XP" | awk -v ip="$XP2_IP" '$1==ip{print $2}' | head -1)
rsh $X "sg_persist --out --register --param-rk=$KX1 --param-sark=0 /dev/${XP1_DEV:-null} >/dev/null 2>&1; sg_persist --out --register --param-rk=$KX2 --param-sark=0 /dev/${XP2_DEV:-null} >/dev/null 2>&1; echo" >/dev/null
rsh $Y "sg_persist --out --register --param-rk=$KY --param-sark=0 /dev/$YP1_DEV >/dev/null 2>&1; echo" >/dev/null
echo "cleanup: KX1=$(keycount $KX1) KX2=$(keycount $KX2) KY=$(keycount $KY) knob=$(cat "$KNOB")"
if [ $fail = 0 ]; then echo "VERDICT PASS"; else echo "VERDICT FAIL"; fi
echo "=== done label=$LABEL total=$(( $(date +%s) - t0 ))s out=$OUT ==="
exit $fail
