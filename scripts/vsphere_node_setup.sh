#!/bin/bash
#
# vsphere_node_setup.sh — make a freshly built AlmaLinux 9 vSphere guest
# (vstest1, vstest2) a MeshXFS test node
#
# Usage: scripts/vsphere_node_setup.sh <node> [<node> ...]
#
# On each node, over tools/mxfs_sshpass.sh:
#   - EPEL (DKMS comes from there), DKMS, kernel-devel for the RUNNING kernel,
#     rpm-build and the test tools
#   - /src from clyde (192.168.120.1:/src) mounted now and from fstab, which
#     is where the harness runs tests/setup/*.sh from
#   - log_buf_len=16M on every kernel's command line (next boot)
#   - firewalld running with only MeshXFS's ports open (7600/tcp DLM,
#     7601/udp discovery, 7602/udp CAW lock-release, 7603/udp lease)
#   - the MeshXFS RPM built from THIS tree on the node (output in
#     /root/mxfs-rpm, never in the shared tree) and installed, so DKMS builds
#     mxfs.ko for the node's kernel: the .ko in /src/mxfs is built for clyde's
#     kernel and cannot load here
# Prints NODE_SETUP_OK <node> version=<v> kernel=<krel> or NODE_SETUP_FAIL.
#
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SSH="$HERE/tools/mxfs_sshpass.sh"
[ $# -ge 1 ] || { echo "usage: $0 <node> [<node> ...]" >&2; exit 2; }
VERSION=$(cat "$HERE/VERSION")

NODE_SETUP='
set -u
fail() { echo "NODE_SETUP_FAIL: $*"; exit 0; }
krel=$(uname -r)
rpm -q epel-release >/dev/null 2>&1 || dnf -y -q install epel-release >/dev/null 2>&1 || fail "epel-release"
dnf -y -q install dkms "kernel-devel-$krel" nfs-utils rpm-build gcc make elfutils-libelf-devel \
    firewalld fio attr sg3_utils iscsi-initiator-utils python3 mosquitto >/dev/null 2>&1 || fail "dnf install (kernel-devel-$krel may be gone from the mirror)"
# The harness publishes every barrier, value and signal with mosquitto_pub -q 1.
# EL9 ships the 2.0.22 client, which after its DISCONNECT waits out one more
# full 1 s pselect before exiting: 1014-1017 ms per publish, against 10-14 ms
# for a 2.0.18 client built on the same guest against the same broker.  That
# second lands on every rendezvous of every coordinated test.  Build 2.0.18'"'"'s
# clients statically linked into /usr/local/bin, which precedes /usr/bin on
# root'"'"'s PATH.  lib and client are directories in its Makefile, not phony
# targets, so they are built with -C.
mq_sha=d665fe7d0032881b1371a47f34169ee4edab67903b2cd2b4c083822823f4448a
if ! /usr/local/bin/mosquitto_pub --help 2>&1 | grep -q "version 2.0.18 "; then
    mqd=$(mktemp -d /var/tmp/mosq.XXXXXX)
    ( set -e; cd "$mqd"
      timeout 120 curl -4 -fsS -o m.tgz https://mosquitto.org/files/source/mosquitto-2.0.18.tar.gz
      echo "$mq_sha  m.tgz" | sha256sum -c -
      tar xzf m.tgz; cd mosquitto-2.0.18
      F="WITH_TLS=no WITH_CJSON=no WITH_DOCS=no WITH_SRV=no WITH_WEBSOCKETS=no WITH_STATIC_LIBRARIES=yes WITH_SHARED_LIBRARIES=no"
      timeout 300 make -j4 $F -C lib; timeout 300 make -j4 $F -C client
      install -m 0755 client/mosquitto_pub client/mosquitto_sub /usr/local/bin/ ) > /root/mosquitto-build.log 2>&1 \
        || fail "mosquitto 2.0.18 clients (see /root/mosquitto-build.log)"
    rm -rf "$mqd"
fi
[ "$(command -v mosquitto_pub)" = /usr/local/bin/mosquitto_pub ] || fail "mosquitto_pub resolves to $(command -v mosquitto_pub), not /usr/local/bin"
# EL9 writes the initiator name on iscsid'"'"'s first start, which a fresh guest has
# never had; tools/lun_pool.sh reads it to admit the node to a LUN
[ -s /etc/iscsi/initiatorname.iscsi ] || echo "InitiatorName=$(iscsi-iname)" > /etc/iscsi/initiatorname.iscsi
systemctl enable --now iscsid >/dev/null 2>&1 || fail "iscsid"
# a persistent journal: AlmaLinux keeps it in memory only, so a hung guest
# reset to recover it takes its kernel log, call traces and all, with it
[ -d /var/log/journal ] || { mkdir -p /var/log/journal && systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1; systemctl restart systemd-journald; journalctl --flush; }
# a 16 MB kernel ring, as the qemu rig'"'"'s nodes boot with: the harness reads
# its windows from dmesg between marks, and the default 1 MB held under a
# minute of a board'"'"'s mxfs messages, so crash_audit'"'"'s mark had rotated out
# before the row read its window.  Takes effect at the next boot.
grubby --update-kernel=ALL --args=log_buf_len=16M || fail "grubby log_buf_len"
mkdir -p /src
grep -q " /src nfs" /etc/fstab || echo "192.168.120.1:/src /src nfs rw,vers=4.1,hard,timeo=600,retrans=2,tcp,_netdev 0 0" >> /etc/fstab
mountpoint -q /src || timeout 60 mount /src || fail "mount /src"
[ -f /src/mxfs/VERSION ] || fail "/src/mxfs not visible: $(findmnt -n /src -o SOURCE,FSTYPE,OPTIONS | tr "\n" " ") ls: $(ls -A /src 2>&1 | tr "\n" " " | cut -c1-300)"
systemctl enable --now firewalld >/dev/null 2>&1 || fail "firewalld"
for p in 7600/tcp 7601/udp 7602/udp 7603/udp; do firewall-cmd -q --permanent --add-port=$p || fail "firewall $p"; done
firewall-cmd -q --reload || fail "firewall reload"
rm -rf /root/mxfs-rpm; mkdir -p /root/mxfs-rpm
( cd /src/mxfs && timeout 600 ./packaging/mkrpm.sh /root/mxfs-rpm ) > /root/mxfs-rpm/build.log 2>&1 || fail "mkrpm.sh (see /root/mxfs-rpm/build.log)"
rpmf=$(ls /root/mxfs-rpm/mxfs-@VER@-*.rpm 2>/dev/null | head -1)
[ -n "$rpmf" ] || fail "no mxfs-@VER@ rpm in /root/mxfs-rpm"
rpm -q mxfs >/dev/null 2>&1 && { rmmod mxfs 2>/dev/null; dnf -y -q remove mxfs >/dev/null 2>&1; }
timeout 1500 dnf -y -q install "$rpmf" > /root/mxfs-rpm/install.log 2>&1 || fail "rpm install (see /root/mxfs-rpm/install.log)"
v=$(modinfo -F version mxfs 2>/dev/null)
[ "$v" = @VER@ ] || fail "installed module version is \"$v\", not @VER@ ($(dkms status mxfs 2>&1 | tr "\n" " "))"
echo "NODE_SETUP_OK $(hostname -s) version=$v kernel=$krel srcversion=$(modinfo -F srcversion mxfs)"
'

td=$(mktemp -d)
for n in "$@"; do
    ( timeout 2100 "$SSH" "$n" "${NODE_SETUP//@VER@/$VERSION}" </dev/null 2>&1 \
        | grep -avE '^Warning:|^Unauthorized|^If you' > "$td/$n"; echo "rc=${PIPESTATUS[0]}" >> "$td/$n" ) &
done
wait
rc=0
for n in "$@"; do
    line=$(grep -a -E '^NODE_SETUP_(OK|FAIL)' "$td/$n" | tail -1)
    echo "$n: ${line:-no result ($(tail -1 "$td/$n"))}"
    case "$line" in NODE_SETUP_OK*) ;; *) rc=1; tail -5 "$td/$n" | sed "s/^/  $n| /" ;; esac
done
rm -rf "$td"
exit $rc
