#!/bin/bash
# tests/scst_session_watch.sh — sample, on the SCST host, what the target thinks
# of one initiator's iSCSI sessions: does it still receive that initiator's
# commands, how many does it count active, and what is each connection doing.
#
# For D-A-BYSTANDER-INITIATOR-HANGS-ON-AN-UNANNOUNCED-LU-RESET.  After another
# initiator's LU reset aborted one of the bystander's commands, the bystander's
# whole session completed nothing for 28 s (no unit attention at the next three
# resets, none of its commands aborted by them) while its keep-alives went on.
# Whether the target stopped RECEIVING its commands, received them and did not
# answer, or could not write its answers decides where the stall is:
#   write_cmd_count/read_cmd_count/none_cmd_count climbing  -> the target receives
#   active_commands                                         -> what it holds
#   connection state (iscsi-scst print_conn_state): read_processing,
#   in_read_list, write_processing, in_write_list, space_waiting (the target
#   cannot write because the initiator is not reading), reinstating,
#   "established idle", closing
#
# Usage: tests/scst_session_watch.sh <target-iqn> <initiator-iqn> <interval_s> <duration_s>
# One line per session per sample on stdout:
#   t_ms=<epoch ms> sess=<dir> sid=<sid> active=<n> commands=<n> w=<n> r=<n> none=<n> conn=<ip>:<state>[,...]
# Reads sysfs only; changes nothing.
set -u
TGT=${1:?target iqn}; INI=${2:?initiator iqn}; IV=${3:?interval s}; DUR=${4:?duration s}
D=/sys/kernel/scst_tgt/targets/iscsi/$TGT/sessions
[ -d "$D" ] || { echo "no such target: $D" >&2; exit 2; }
rd() { head -c 200 "$1" 2>/dev/null | tr -d '\n'; }
end=$(( $(date +%s) + DUR ))
while [ "$(date +%s)" -lt "$end" ]; do
    t=$(date +%s%3N)
    for s in "$D/$INI" "$D/$INI"_*; do
        [ -d "$s" ] || continue
        conns=
        for c in "$s"/*/; do
            [ -f "$c/state" ] || continue
            conns="$conns${conns:+,}$(rd "$c/ip"):$(rd "$c/state" | tr ' ' '_')"
        done
        echo "t_ms=$t sess=$(basename "$s") sid=$(rd "$s/sid") active=$(rd "$s/active_commands") commands=$(rd "$s/commands") w=$(rd "$s/write_cmd_count") r=$(rd "$s/read_cmd_count") none=$(rd "$s/none_cmd_count") conn=${conns:-none}"
    done
    sleep "$IV"
done
