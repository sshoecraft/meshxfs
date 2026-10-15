#!/bin/bash
#
# quorum_setup.sh — make two lab nodes a corosync cluster with a QDevice, for
# fence=quorum (docs/quorum-takeover.md)
#
# Usage: scripts/quorum_setup.sh <cluster-name> <qnetd-host> <node1>=<addr1> <node2>=<addr2>
#   e.g. scripts/quorum_setup.sh mxfs-vsphere 192.168.1.5 \
#            vstest1.vm.localdomain=192.168.120.178 vstest2.vm.localdomain=192.168.120.181
#
# On both nodes: corosync and corosync-qdevice (AlmaLinux's HighAvailability
# repository, or apt on Debian/Ubuntu), a corosync.conf naming exactly these two nodes and the QDevice
# (model net, algorithm ffsplit, TLS), one shared authkey, the corosync port
# open, and the QDevice's certificate signed by the qnetd host's CA.  Then
# mxfs_quorumd and its unit from this tree, and every service started.
#
# The qnetd host is reached as root by key from this machine (it signs the
# cluster's certificate request; corosync-qdevice-net-certutil -Q would need
# the nodes themselves to reach it).  One qnetd serves many clusters, each by
# its own cluster name, so the name must be unique on that qnetd.
#
# Nodes are reached through tools/mxfs_sshpass.sh.  Re-running it replaces the
# configuration and the certificates: a cluster whose corosync.conf changes
# must be restarted anyway.
#
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SP="$ROOT/tools/mxfs_sshpass.sh"

[ $# -eq 4 ] || { sed -n '3,8p' "$0" >&2; exit 64; }
CLUSTER="$1"; QNETD="$2"
N1="${3%%=*}"; A1="${3#*=}"
N2="${4%%=*}"; A2="${4#*=}"
for v in "$CLUSTER" "$QNETD" "$N1" "$A1" "$N2" "$A2"; do
    case "$v" in ''|*[!A-Za-z0-9._-]*) echo "quorum_setup: bad argument '$v'" >&2; exit 64 ;; esac
done

T="$(mktemp -d)"
# it holds the cluster's authkey and certificate for the length of the run
trap 'rm -rf "$T"' EXIT
NSS=/etc/corosync/qdevice/net/nssdb
QNSS=/etc/corosync/qnetd/nssdb

# each node is reached by the address it is given, which is also its ring0
# address: a rig node's name need not resolve from here
addr_of() { if [ "$1" = "$N1" ]; then echo "$A1"; else echo "$A2"; fi; }
run() {   # run <node> <command>: the node's output, prefixed
    local n="$1"; shift
    timeout 300 "$SP" "$(addr_of "$n")" "$*" 2>&1 | grep -av '^Warning: Permanently\|^Unauth\|^If you' | sed "s|^|[$n] |"
    return "${PIPESTATUS[0]}"
}
step() { echo "=== $*"; }
die() { echo "quorum_setup: FAILED: $*" >&2; exit 1; }

step "packages"
for n in "$N1" "$N2"; do
    run "$n" 'if command -v dnf >/dev/null; then rpm -q corosync corosync-qdevice >/dev/null 2>&1 || dnf -y -q --enablerepo=highavailability install corosync corosync-qdevice; rpm -q corosync corosync-qdevice; else dpkg -s corosync corosync-qdevice >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get -y -q install corosync corosync-qdevice >/dev/null; dpkg-query -W corosync corosync-qdevice; fi' ||
        die "corosync packages on $n"
done

step "corosync.conf"
cat > "$T/corosync.conf" <<EOF
# written by scripts/quorum_setup.sh (fence=quorum, docs/quorum-takeover.md)
totem {
    version: 2
    cluster_name: $CLUSTER
    transport: knet
    crypto_cipher: aes256
    crypto_hash: sha256
}

nodelist {
    node {
        name: ${N1%%.*}
        nodeid: 1
        ring0_addr: $A1
    }
    node {
        name: ${N2%%.*}
        nodeid: 2
        ring0_addr: $A2
    }
}

# No two_node and no auto_tie_breaker: the QDevice is the third vote, and
# either of those would let both halves of a split carry on.
quorum {
    provider: corosync_votequorum
    device {
        model: net
        votes: 1
        net {
            tls: on
            host: $QNETD
            algorithm: ffsplit
        }
    }
}

logging {
    to_syslog: yes
    to_logfile: no
}
EOF
for n in "$N1" "$N2"; do
    run "$n" 'systemctl stop corosync-qdevice corosync 2>/dev/null; true'
    "$SP" "$(addr_of "$n")" 'cat > /etc/corosync/corosync.conf' < "$T/corosync.conf" || die "corosync.conf on $n"
done

step "authkey (made on $N1, copied to $N2)"
run "$N1" 'corosync-keygen -l >/dev/null 2>&1; test -s /etc/corosync/authkey && echo authkey-ok' | grep -q authkey-ok ||
    die "corosync-keygen on $N1"
"$SP" "$A1" 'cat /etc/corosync/authkey' > "$T/authkey" 2>/dev/null && [ -s "$T/authkey" ] || die "read authkey"
"$SP" "$A2" 'umask 077; cat > /etc/corosync/authkey; chmod 400 /etc/corosync/authkey' < "$T/authkey" || die "authkey on $N2"

step "firewall: corosync knet (5405/udp)"
for n in "$N1" "$N2"; do
    run "$n" 'if systemctl -q is-active firewalld; then firewall-cmd -q --permanent --add-port=5405/udp && firewall-cmd -q --reload && echo opened; else echo no-firewalld; fi'
done

step "QDevice certificates, signed by $QNETD"
timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$QNETD" "cat $QNSS/qnetd-cacert.crt" > "$T/ca.crt" &&
    [ -s "$T/ca.crt" ] || die "fetch the qnetd CA from root@$QNETD (by key)"
for n in "$N1" "$N2"; do
    "$SP" "$(addr_of "$n")" 'mkdir -p /etc/corosync/qdevice/net && cat > /etc/corosync/qdevice/net/qnetd-cacert.crt' < "$T/ca.crt" || die "CA on $n"
    run "$n" "rm -rf $NSS; corosync-qdevice-net-certutil -i -c /etc/corosync/qdevice/net/qnetd-cacert.crt >/dev/null && echo nssdb-ok" |
        grep -q nssdb-ok || die "nssdb on $n"
done
run "$N1" "corosync-qdevice-net-certutil -r -n $CLUSTER >/dev/null && test -s $NSS/qdevice-net-node.crq && echo crq-ok" |
    grep -q crq-ok || die "certificate request on $N1"
"$SP" "$A1" "cat $NSS/qdevice-net-node.crq" > "$T/node.crq" || die "read the request"
timeout 30 ssh -o BatchMode=yes "root@$QNETD" "cat > /tmp/mxfs-$CLUSTER.crq" < "$T/node.crq" || die "request to $QNETD"
timeout 60 ssh -o BatchMode=yes "root@$QNETD" \
    "corosync-qnetd-certutil -s -c /tmp/mxfs-$CLUSTER.crq -n $CLUSTER >/dev/null && cat $QNSS/cluster-$CLUSTER.crt; rm -f /tmp/mxfs-$CLUSTER.crq" \
    > "$T/cluster.crt" && [ -s "$T/cluster.crt" ] || die "signing on $QNETD"
"$SP" "$A1" "cat > $NSS/cluster-$CLUSTER.crt" < "$T/cluster.crt" || die "certificate to $N1"
run "$N1" "corosync-qdevice-net-certutil -M -c $NSS/cluster-$CLUSTER.crt >/dev/null && test -s $NSS/qdevice-net-node.p12 && echo p12-ok" |
    grep -q p12-ok || die "import on $N1"
"$SP" "$A1" "cat $NSS/qdevice-net-node.p12" > "$T/node.p12" || die "read the p12"
"$SP" "$A2" "cat > /etc/corosync/qdevice/net/qdevice-net-node.p12" < "$T/node.p12" || die "p12 to $N2"
run "$N2" "corosync-qdevice-net-certutil -m -c /etc/corosync/qdevice/net/qdevice-net-node.p12 >/dev/null && echo p12-ok" |
    grep -q p12-ok || die "import on $N2"

step "mxfs_quorumd from this tree"
for n in "$N1" "$N2"; do
    "$SP" "$(addr_of "$n")" 'cat > /usr/sbin/mxfs_quorumd; chmod 755 /usr/sbin/mxfs_quorumd' < "$ROOT/tools/mxfs_quorumd.py" || die "helper on $n"
    "$SP" "$(addr_of "$n")" 'cat > /usr/lib/systemd/system/mxfs-quorumd.service' < "$ROOT/packaging/mxfs-quorumd.service" || die "unit on $n"
done

step "start corosync, the QDevice and mxfs_quorumd"
for n in "$N1" "$N2"; do
    run "$n" 'systemctl daemon-reload; systemctl enable -q corosync corosync-qdevice mxfs-quorumd; systemctl restart corosync && echo corosync-started'
done
for n in "$N1" "$N2"; do
    run "$n" 'systemctl restart corosync-qdevice mxfs-quorumd && echo qdevice-started'
done

step "verify (up to 60 s for the QDevice to vote)"
for i in $(seq 1 30); do
    ok=0
    for n in "$N1" "$N2"; do
        "$SP" "$(addr_of "$n")" '/usr/sbin/mxfs_quorumd query' 2>/dev/null > "$T/q.$i" || true
        grep -q '^QUORATE=1' "$T/q.$i" && grep -q '^QDEVICE=1' "$T/q.$i" &&
            grep -q "^MEMBERS=.*$A1" "$T/q.$i" && grep -q "^MEMBERS=.*$A2" "$T/q.$i" && ok=$((ok + 1))
    done
    [ "$ok" = 2 ] && break
    sleep 2
done
for n in "$N1" "$N2"; do
    echo "--- $n"
    run "$n" '/usr/sbin/mxfs_quorumd query; corosync-quorumtool -s | sed -n "/Votequorum/,\$p"'
done
[ "$ok" = 2 ] || die "both nodes quorate with the QDevice voting and both members"
echo "quorum_setup: OK cluster=$CLUSTER qnetd=$QNETD nodes=$A1,$A2"
