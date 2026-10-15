#!/bin/sh
#
# kcompat_killed_probe.sh — a kernel-API probe whose compiler is killed must
# fail the module build, never read as "API absent".
#
# Usage: tests/kcompat_killed_probe.sh [PROBE]      (default FREEZE_HOLDER)
#
# Kills the probe's compiler the way the OOM killer does during a package
# install on a small host, through gcc's own -wrapper hook, two ways:
#   cc1   cc1 is SIGKILLed; the gcc driver survives and reports an internal
#         compiler error (exit 4) -- what the Ubuntu 24.04 install hit
#   drv   the gcc driver itself is SIGKILLed (exit 137)
# Each must fail `make modules` with the probe named, and leave the tree's
# generated header untouched.  A final plain build must reproduce the header
# byte for byte, so the probes still answer exactly as before.
#
# Run from the top of the tree, against the kernel `make modules` builds for.

probe=${1:-FREEZE_HOLDER}
cc=${CC:-gcc}
header=pal/linux/mxfs_kcompat.h
[ -f "$header" ] || { echo "FAIL: no $header: run make modules once first"; exit 1; }

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
cp -p "$header" "$work/header.before"

cat > "$work/kill_cc1" <<'EOF'
#!/bin/sh
case "$1" in */cc1) kill -KILL $$ ;; esac
exec "$@"
EOF
for mode in cc1 drv; do
    cat > "$work/cc_$mode" <<EOF
#!/bin/sh
case "\$*" in
*"/$probe.c"*)
    [ "$mode" = drv ] && kill -KILL \$\$
    exec $cc -wrapper "$work/kill_cc1" "\$@" ;;
esac
exec $cc "\$@"
EOF
done
chmod +x "$work"/kill_cc1 "$work"/cc_cc1 "$work"/cc_drv

fails=0
for mode in cc1 drv; do
    make modules CC="$work/cc_$mode" > "$work/make_$mode.log" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "FAIL $mode: make modules succeeded with $probe's compiler killed"
        fails=$((fails + 1))
    elif ! grep -q "kcompat_probe $probe: compiler did not complete" "$work/make_$mode.log"; then
        echo "FAIL $mode: make failed (rc=$rc) without naming $probe:"
        tail -5 "$work/make_$mode.log"
        fails=$((fails + 1))
    else
        echo "PASS $mode: make modules rc=$rc, $probe named:"
        grep -A2 "kcompat_probe $probe:" "$work/make_$mode.log" | head -3
    fi
    if ! cmp -s "$header" "$work/header.before"; then
        echo "FAIL $mode: $header changed"
        fails=$((fails + 1))
    fi
done

make modules > "$work/make_plain.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "FAIL plain: make modules rc=$rc"
    tail -5 "$work/make_plain.log"
    fails=$((fails + 1))
elif ! cmp -s "$header" "$work/header.before"; then
    echo "FAIL plain: $header differs from before the test"
    diff "$work/header.before" "$header"
    fails=$((fails + 1))
else
    echo "PASS plain: make modules rc=0, $header identical"
fi

[ "$fails" -eq 0 ] && { echo "PASS"; exit 0; }
echo "FAIL ($fails)"
exit 1
