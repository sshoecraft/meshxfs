#!/bin/bash
# pve_dir_rmdir_loop.sh — the per-host half of tests/pve_dir_rmdir_handoff.sh,
# run on a pair host over ssh (`bash -s -- <prefix> <dir> <seconds>`).
#
# For <seconds>, over and over: remove each of this host's four subdirectories
# <prefix>0..<prefix>3 of the shared directory <dir>, list <dir>, and create
# the subdirectory again.  The other host does the same with its own prefix in
# the same directory at the same time, so the directory's lock passes between
# the hosts on nearly every operation and each host's removals are what it
# holds when it is asked to give the lock up.  Every loop ends with all four
# of its subdirectories present, so the directory's final contents are known.
#
# Prints: ops=<n> errors=<n> and the first errors verbatim.  Exit 0 = no error.
set -u
P=${1:?prefix}; D=${2:?dir}; DUR=${3:?seconds}
ops=0; errs=0; first=""
for k in 0 1 2 3; do mkdir -p "$D/$P$k"; done
SECONDS=0
while [ "$SECONDS" -lt "$DUR" ]; do
    for k in 0 1 2 3; do
        if ! out=$(rmdir "$D/$P$k" 2>&1); then
            errs=$(( errs + 1 )); [ "$errs" -le 5 ] && first+="rmdir $P$k: $out; "
        fi
        ls "$D" > /dev/null 2>&1
        if ! out=$(mkdir "$D/$P$k" 2>&1); then
            errs=$(( errs + 1 )); [ "$errs" -le 5 ] && first+="mkdir $P$k: $out; "
        fi
        ops=$(( ops + 2 ))
    done
done
echo "ops=$ops errors=$errs ${first:+first: $first}"
[ "$errs" = 0 ]
