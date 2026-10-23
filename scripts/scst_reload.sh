#!/bin/bash
# scst_reload.sh -- install a rebuilt SCST (core, vdisk handler, iSCSI target
# and iscsi-scstd) on the lab host and bring the target back exactly as it was.
#
# WHY.  A fix to SCST's own code (lab/*.patch, the +caw-abort-reclaim.N line)
# only takes effect once the modules are reloaded, and a reload drops the whole
# target: every device, every iSCSI target, every LUN mapping, every attribute.
# The rig's target is built up piecewise (scripts/scst_setup.sh,
# tools/lun_pool.sh creating pool LUNs of either block size, the PVE target),
# so it is not rebuilt from any one script; it is restored from SCST's own dump
# of itself, taken just before the unload, and the dump taken after the reload
# must match it.  A device's persistent reservations are SCST's own
# (/var/lib/scst/pr/<device>) and come back when a device of that name is
# created again.
#
# WHAT IT DOES, in order; any failure before the unload changes nothing:
#   1. refuses unless the built modules carry VERSION (the suffix the patch
#      sets), no iSCSI target has a session, mxfs-clyde-guard is active, there
#      is no .rig_halt, and no SCST trace flag is on (a reload under a trace
#      flag floods the host log the same way a run does);
#   2. writes the live configuration with scstadmin (before.conf);
#   3. stops iscsi-scstd (it holds a reference on iscsi_scst: rmmod fails under
#      it) by the pid in its pidfile, clears the configuration, unloads
#      iscsi_scst, scst_vdisk and scst;
#   4. keeps each installed module and iscsi-scstd as <file>.<loaded version
#      suffix> (once), copies the built ones in, depmod;
#   5. loads scst, scst_vdisk, iscsi_scst, checks /sys/module/scst/version,
#      starts iscsi-scstd, applies before.conf, writes after.conf and compares
#      the two;
#   6. on a failure after the unload, puts the kept modules and daemon back,
#      loads them and applies before.conf, so the host ends on the old target
#      rather than none.
# Each bounded step is a kernel or daemon operation measured in seconds on
# this host (module unload/load well under 1 s each; scstadmin applying 17
# devices and 16 targets a few seconds): every one is bounded at 60 s, and a
# step that overruns is a failure, not a retry.
#
# Usage: scripts/scst_reload.sh <scst source tree> <expected version suffix>
#   e.g. scripts/scst_reload.sh ~/src/scst +caw-abort-reclaim.6
# Exit 0 reloaded and restored; 1 failed (rolled back where it could); 2 refused.
set -u
SRC=${1:?scst source tree}; WANT=${2:?expected version suffix}
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SUDO="sudo -n"
KDIR=/lib/modules/$(uname -r)/extra
SCSTADMIN=/usr/local/sbin/scstadmin
DAEMON=/usr/local/sbin/iscsi-scstd
PIDF=/run/iscsi-scstd.pid
OUT=$HERE/tests/evidence/scst_reload_$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUT"
exec > >(tee -a "$OUT/reload.log") 2>&1
step() { echo "$(date -u +%FT%T.%3NZ) $*"; }
refuse() { step "REFUSED $*"; exit 2; }
fail() { step "FAILED $*"; exit 1; }

# module file in the source tree -> installed path
declare -A MAP=(
    ["$SRC/scst/src/scst.ko"]="$KDIR/scst.ko"
    ["$SRC/scst/src/dev_handlers/scst_vdisk.ko"]="$KDIR/dev_handlers/scst_vdisk.ko"
    ["$SRC/iscsi-scst/kernel/iscsi-scst.ko"]="$KDIR/iscsi-scst.ko"
    ["$SRC/iscsi-scst/usr/iscsi-scstd"]="$DAEMON"
)

step "=== scst_reload src=$SRC want=$WANT out=$OUT ==="
# 1. preconditions
for s in "${!MAP[@]}"; do [ -f "$s" ] || refuse "built file missing: $s"; done
for k in "$SRC/scst/src/scst.ko" "$SRC/scst/src/dev_handlers/scst_vdisk.ko" "$SRC/iscsi-scst/kernel/iscsi-scst.ko"; do
    v=$(modinfo -F version "$k" 2>/dev/null)
    case "$v" in *"$WANT") ;; *) refuse "$k is version '$v', not *$WANT" ;; esac
done
old=$(cat /sys/module/scst/version 2>/dev/null) || refuse "scst is not loaded"
oldsfx=${old#*+}; [ "$oldsfx" != "$old" ] || oldsfx=stock
step "loaded: $old; installing *$WANT"
[ "$(systemctl is-active mxfs-clyde-guard.service)" = active ] || refuse "mxfs-clyde-guard.service is not active"
[ -e "$HERE/.rig_halt" ] && refuse ".rig_halt is present: read it first"
# the trace flags beyond SCST's defaults, by scripts/clyde_preflight.sh's allowlist
hot_trace() {
    local tf f hot=""
    for tf in /sys/kernel/scst_tgt/trace_level /sys/kernel/scst_tgt/handlers/*/trace_level \
              /sys/kernel/scst_tgt/targets/*/trace_level; do
        [ -f "$tf" ] || continue
        for f in $(head -1 "$tf" 2>/dev/null | tr '|' ' '); do
            case "$f" in '['*) continue ;; esac
            case " out_of_mem minor pid line function special mgmt retry conn " in *" $f "*) ;; *) hot="$hot ${tf#/sys/kernel/scst_tgt/}:$f" ;; esac
        done
    done
    echo "$hot"
}
h=$(hot_trace); [ -z "$h" ] || refuse "SCST trace flags are on:$h"
nsess=0
for t in /sys/kernel/scst_tgt/targets/iscsi/*/sessions; do
    n=$(ls "$t" 2>/dev/null | wc -l); [ "$n" -gt 0 ] && { step "sessions on ${t%/sessions}: $(ls "$t" | tr '\n' ' ')"; nsess=$((nsess + n)); }
done
[ "$nsess" = 0 ] || refuse "$nsess iSCSI session(s) are logged in: power the rig VMs off first"

# 2. the live configuration
timeout 60 $SUDO "$SCSTADMIN" -nonkey -write_config "$OUT/before.conf" > "$OUT/write_before.out" 2>&1 \
    || refuse "scstadmin -write_config failed: $(tail -2 "$OUT/write_before.out")"
step "configuration saved: $(grep -c 'DEVICE ' "$OUT/before.conf") devices, $(grep -c 'TARGET ' "$OUT/before.conf") targets, $(grep -c 'LUN ' "$OUT/before.conf") LUNs"

restore_old() {
    step "ROLLBACK to the kept $oldsfx files"
    for s in "${!MAP[@]}"; do d=${MAP[$s]}; [ -f "$d.$oldsfx" ] && $SUDO cp -f "$d.$oldsfx" "$d"; done
    $SUDO depmod -a
    unload
    load || { step "ROLLBACK could not load the old modules: the host has no target"; return 1; }
    timeout 60 $SUDO "$SCSTADMIN" -noprompt -config "$OUT/before.conf" > "$OUT/rollback_config.out" 2>&1
    step "ROLLBACK applied before.conf rc=$? version=$(cat /sys/module/scst/version 2>/dev/null)"
}
unload() {
    local pid
    pid=$(cat "$PIDF" 2>/dev/null)
    if [ -n "$pid" ] && [ "$(cat /proc/"$pid"/comm 2>/dev/null)" = iscsi-scstd ]; then
        $SUDO kill -TERM "$pid"
        for i in $(seq 1 50); do [ -d /proc/"$pid" ] || break; sleep 0.1; done
        [ -d /proc/"$pid" ] && { step "iscsi-scstd $pid did not exit in 5 s"; return 1; }
    fi
    for m in iscsi_scst scst_vdisk scst; do
        if grep -q "^$m " /proc/modules; then
            timeout 60 $SUDO rmmod "$m" || { step "rmmod $m failed: $(grep "^$m " /proc/modules)"; return 1; }
        fi
    done
    step "unloaded"
}
load() {
    for m in scst scst_vdisk iscsi_scst; do
        timeout 60 $SUDO modprobe "$m" || { step "modprobe $m failed"; return 1; }
    done
    timeout 60 $SUDO "$DAEMON" || { step "iscsi-scstd failed to start"; return 1; }
    step "loaded $(cat /sys/module/scst/version), iscsi-scstd pid $(cat "$PIDF" 2>/dev/null)"
}

# 3. stop and unload
timeout 60 $SUDO "$SCSTADMIN" -noprompt -force -clear_config > "$OUT/clear.out" 2>&1 \
    || fail "scstadmin -clear_config failed (nothing unloaded): $(tail -2 "$OUT/clear.out")"
unload || { timeout 60 $SUDO "$SCSTADMIN" -noprompt -config "$OUT/before.conf" > "$OUT/reapply.out" 2>&1; fail "unload failed; before.conf re-applied rc=$?"; }

# 4. keep the installed files once, install the built ones
for s in "${!MAP[@]}"; do
    d=${MAP[$s]}
    [ -e "$d.$oldsfx" ] || $SUDO cp -p "$d" "$d.$oldsfx" || { restore_old; fail "could not keep $d"; }
    $SUDO install -m "$( [ "$d" = "$DAEMON" ] && echo 755 || echo 644 )" "$s" "$d" || { restore_old; fail "could not install $d"; }
    step "installed $d (kept $d.$oldsfx)"
done
$SUDO depmod -a || { restore_old; fail "depmod failed"; }

# 5. load, check, restore the configuration
load || { restore_old; fail "load failed"; }
case "$(cat /sys/module/scst/version)" in *"$WANT") ;; *) restore_old; fail "loaded version is $(cat /sys/module/scst/version), not *$WANT" ;; esac
timeout 60 $SUDO "$SCSTADMIN" -noprompt -config "$OUT/before.conf" > "$OUT/config.out" 2>&1 \
    || { restore_old; fail "scstadmin -config failed: $(tail -3 "$OUT/config.out")"; }
timeout 60 $SUDO "$SCSTADMIN" -nonkey -write_config "$OUT/after.conf" > "$OUT/write_after.out" 2>&1 \
    || fail "scstadmin -write_config after the reload failed (the new target is up; compare by hand)"
# the dump's header names the time it was written; everything else must match
if ! diff <(grep -v '^#' "$OUT/before.conf") <(grep -v '^#' "$OUT/after.conf") > "$OUT/config.diff"; then
    step "the restored configuration differs from the saved one ($(wc -l < "$OUT/config.diff") diff lines, $OUT/config.diff):"
    head -20 "$OUT/config.diff"
    fail "configuration not restored exactly (the new modules stay loaded; fix the difference)"
fi
# a fresh load starts on the build's default masks, which may include mgmt_dbg
timeout 60 $SUDO bash "$HERE/scripts/scst_setup.sh" reset-trace > "$OUT/reset_trace.out" 2>&1
h=$(hot_trace)
[ -z "$h" ] || fail "trace flags still on after reset-trace:$h (turn them off: scripts/scst_setup.sh reset-trace)"
step "OK reloaded $old -> $(cat /sys/module/scst/version); configuration identical ($(grep -c 'DEVICE ' "$OUT/after.conf") devices, $(grep -c 'LUN ' "$OUT/after.conf") LUNs); no trace flag beyond the defaults"
exit 0
