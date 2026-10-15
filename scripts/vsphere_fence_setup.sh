#!/bin/bash
#
# vsphere_fence_setup.sh — make the vSphere test guests able to mount a shared
# disk with fence=vcenter (docs/shared-disk-attachment.md)
#
# Usage: scripts/vsphere_fence_setup.sh [<vm> ...]      (default: vstest1 vstest2)
#
# On each guest: pyVmomi (python3-pyvmomi from the distribution or EPEL, else
# pip), the helper the module runs (/usr/sbin/mxfs_fence_vcenter.py, copied
# from this tree as the package would install it), the boot-time tag unit
# (mxfs-vcenter-tag.service, enabled), and /etc/mxfs/vcenter.conf
# with its password file, root-owned and mode 0600.  The vCenter account and
# password are the lab's (scripts/vsphere_env.sh's `lab` entry in the osimager
# secrets file); the password travels on ssh's stdin, never on a command line
# or into this tree.  Ends with one CHECK of the helper per guest against its
# own identity, which must report RUNNING (its own VM, still running that boot),
# and one run of the boot-time tag, which must report ARMED.
#
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SSH="$HERE/tools/mxfs_sshpass.sh"
. "$HERE/scripts/vsphere_env.sh" lab || { echo "no vCenter credentials" >&2; exit 2; }
VC=$(printf '%s' "$GOVC_URL" | sed -E 's#^https://([^/]+)/sdk$#\1#')
[ -n "$VC" ] || { echo "cannot read the vCenter address from GOVC_URL" >&2; exit 2; }
[ $# -gt 0 ] || set -- vstest1 vstest2

SETUP='
set -u
fail() { echo "FENCE_SETUP_FAIL $(hostname -s): $*"; exit 1; }
IFS= read -r pw
[ -n "$pw" ] || fail "no password on stdin"
if ! python3 -c "import pyVmomi" 2>/dev/null; then
    timeout 300 dnf -y -q install python3-pyvmomi >/dev/null 2>&1 ||
    { timeout 300 dnf -y -q install python3-pip >/dev/null 2>&1 &&
      timeout 300 pip3 install -q pyvmomi >/dev/null 2>&1; } ||
    fail "pyVmomi: neither python3-pyvmomi nor pip install pyvmomi"
fi
python3 -c "import pyVmomi" || fail "pyVmomi does not import"
install -m 755 /src/mxfs/tools/mxfs_fence_vcenter.py /usr/sbin/mxfs_fence_vcenter.py || fail "helper"
# the boot-time tag the package enables (packaging/mxfs-vcenter-tag.service)
install -m 644 /src/mxfs/packaging/mxfs-vcenter-tag.service /etc/systemd/system/mxfs-vcenter-tag.service || fail "unit"
systemctl daemon-reload && systemctl enable mxfs-vcenter-tag.service >/dev/null 2>&1 || fail "unit enable"
install -d -m 755 /etc/mxfs
umask 077
printf "%s\n" "$pw" > /etc/mxfs/vcenter.password
chmod 600 /etc/mxfs/vcenter.password
printf "server=@VC@\nuser=@USER@\npassword_file=/etc/mxfs/vcenter.password\ninsecure=1\n" > /etc/mxfs/vcenter.conf
chmod 600 /etc/mxfs/vcenter.conf
h=$(tr -d "-" < /etc/machine-id)
b=$(tr -d "-" < /proc/sys/kernel/random/boot_id)
rep=$(mktemp)
timeout 60 /usr/sbin/mxfs_fence_vcenter.py 0123456789abcdef check "$h" "$b" "$rep"
echo "FENCE_SETUP_CHECK $(hostname -s) $(tr "\n" " " < "$rep")"
rm -f "$rep"
echo "FENCE_SETUP_BOOT_TAG $(hostname -s) $(timeout 220 /usr/sbin/mxfs_fence_vcenter.py boot | tr "\n" " ")"
echo "FENCE_SETUP_OK $(hostname -s)"
'
SETUP=${SETUP//@VC@/$VC}
SETUP=${SETUP//@USER@/$GOVC_USERNAME}

d=$(mktemp -d)
for n in "$@"; do
    ( printf '%s\n' "$GOVC_PASSWORD" | timeout 700 "$SSH" "$n.vm.localdomain" "$SETUP" > "$d/$n" 2>&1
      echo "rc=$?" >> "$d/$n" ) &
done
wait
rc=0
for n in "$@"; do
    grep -avE '^Warning:|^Unauthorized|^If you|^$' "$d/$n"
    grep -q "FENCE_SETUP_OK $n" "$d/$n" || rc=1
done
exit $rc
