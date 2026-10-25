# guest_start.sh -- how a harness starts lab guests without flooding another lane's preflight.
#
# Needs SSH (tools/mxfs_sshpass.sh) and PASS (the password file) set, as run.sh sets them.
# run.sh's power cycles start their guests through guest_start_held, and
# tests/powerup_flood_lap.sh MODE=teardown calls the same function, so the lap exercises the
# text run.sh runs.

# Start a guest under the host power-up lock.  A guest's boot floods the host's kernel log (its
# vnet and bridge lines, its iSCSI logins), and another lane's preflight sampling the rate then
# refuses its prep (D-LANE-POWER-UP-FLOODS-THE-HOST-LOG-AND-ANOTHER-LANES-PREFLIGHT-REFUSES-ITS-PREP).
# scripts/lab_power.sh up holds /tmp/mxfs_host_powerup.lock exclusive until its guests answer
# ssh, and scripts/clyde_preflight.sh takes it shared before it samples; run.sh's own power
# cycles started their guests without it, and one lane's teardown power cycle of seven guests
# refused another lane's prep (attempt 22, lap lcnv225).  This takes the lock exclusive (at most
# 240 s, lab_power's own wait), starts the guests at once, and leaves one child holding the same
# open lock until every one of them answers ssh with its boot done (at most 180 s,
# power_cycle_node's own wait), so the caller goes on as before; one lock for the whole set, so a
# set's starts are not serialized behind each other's boots.  MXFS_TEARDOWN_POWER_LOCK=0 (or
# LAB_POWER_LOCK=0) starts them without the lock, as before: the control.
guest_start_held() {  # <node>... -> 0 when every virsh start returned 0
    local n lfd rc=0 pids=() p
    if [ "${MXFS_TEARDOWN_POWER_LOCK:-1}" != 0 ] && [ "${LAB_POWER_LOCK:-1}" != 0 ]; then
        exec {lfd}>>/tmp/mxfs_host_powerup.lock
        flock -x -w 240 "$lfd" || echo "    WARN: host power-up lock not taken in 240 s; starting $* without it"
    fi
    for n in "$@"; do
        timeout 60 virsh -c qemu:///system start "$n" >/dev/null 2>&1 &
        pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p" || rc=1; done
    [ -n "${lfd:-}" ] || return $rc
    # the child keeps the power-up lock and nothing else: inherited, the run lock (fd 9), the
    # pool's and the lap's would stay held after this run exits and refuse the next one
    ( for f in /proc/$BASHPID/fd/*; do
          f=${f##*/}
          [ "$f" -gt 2 ] 2>/dev/null && [ "$f" != "$lfd" ] && eval "exec $f>&-"
      done
      dl=$(( SECONDS + 180 ))
      for n in "$@"; do
          while [ "$SECONDS" -lt "$dl" ]; do
              timeout 8 "$SSH" "$n" "$PASS" "test -e /run/nologin || echo SSH_UP" 2>/dev/null | grep -q SSH_UP && break
              sleep 3
          done
      done ) > /dev/null 2>&1 < /dev/null &
    exec {lfd}>&-
    return $rc
}
