#!/usr/bin/python3
#
# mxfs_quorumd.py — the shared attachment's quorum reporter (fence=quorum)
#
# docs/quorum-takeover.md.  Installed as /usr/sbin/mxfs_quorumd and run by
# mxfs-quorumd.service.  It reads corosync's votequorum (libvotequorum, the
# same library corosync-quorumtool uses) every quarter second and reports to
# the mxfs module through /proc/fs/mxfs/quorum, one report per write:
#
#   QUORATE=0|1   this node is quorate
#   QDEVICE=0|1   this node's QDevice is registered, alive and casting its vote
#   TWONODE=0|1   votequorum's two_node is set
#   NODES=a,b     the IPv4 ring0 address of every node of the nodelist
#   MEMBERS=a,b   those of them that are members now
#   BOOTS=a/h/b,..  for each member that has announced itself since it last
#                 joined: its /etc/machine-id (h) and the boot it runs
#                 (/proc/sys/kernel/random/boot_id, b)
#   ASKS=n/i,..   the isolation exchange (below): asks heard for mount node n,
#                 incarnation i
#   CLOSED=n/i,.. closes heard
#   END=1
#
# THE ISOLATION EXCHANGE, over the same CPG group.  A host that loses every
# path to a shared LUN while staying a corosync member stops beating, and its
# peers would otherwise wait out the whole death window to learn why.  The
# module posts on /proc/fs/mxfs/quorum ("ask node=n inc=i": a survivor asking
# that mount whether it lost the LUN; "closed node=n inc=i": that mount's
# answer, its authority is closed); this program multicasts each post once a
# second while it stands and reports what it heard in the last HEARD_S.
#
# The announcements travel over corosync's own authenticated messaging (CPG
# group "mxfs-boot"): each reporter multicasts its host and boot when it joins,
# whenever a node joins, and every few seconds.  One kernel runs on a machine,
# so a member announcing a later boot of a host ends every earlier boot of it:
# a survivor whose peer lost the vote, reset and came back within the takeover
# bound learns from this that the peer's old boot is over.
#
# A quorate report renews the module's quorum lease; while a fence=quorum
# filesystem is mounted, a lease that runs out, or a report that says
# inquorate, ends this host's boot.  So this program never reports quorate
# unless votequorum said so in this tick, and when it cannot ask (corosync
# stopped, the library gone) it reports QUORATE=0: a reporter that cannot
# see the vote is a host that does not hold it.
#
#   mxfs_quorumd.py run      the service loop
#   mxfs_quorumd.py query    print one report to stdout and exit (0 when
#                            quorate, 1 when not, 2 when corosync cannot be
#                            asked); operators use it
#   mxfs_quorumd.py vote     the same without the boot announcements, so
#                            it answers at once (no CPG join): the DRBD
#                            fence authority polls it
#
# The nodelist and ring0 addresses come from /etc/corosync/corosync.conf
# (on Proxmox VE, a copy of /etc/pve/corosync.conf).  A ring0_addr that is a
# name is resolved once per tick.
#
import ctypes
import ctypes.util
import os
import socket
import sys
import time

PROC = "/proc/fs/mxfs/quorum"
CONF = "/etc/corosync/corosync.conf"
TICK_S = 0.25

CS_OK = 1
VOTEQUORUM_INFO_TWONODE = 1
VOTEQUORUM_INFO_QUORATE = 2
VOTEQUORUM_INFO_QDEVICE_REGISTERED = 64
VOTEQUORUM_INFO_QDEVICE_ALIVE = 128
VOTEQUORUM_INFO_QDEVICE_CAST_VOTE = 256
VOTEQUORUM_NODESTATE_MEMBER = 1
VOTEQUORUM_QDEVICE_MAX_NAME_LEN = 255
CPG_TYPE_AGREED = 2
CS_DISPATCH_ALL = 2
CPG_MAX_NAME_LENGTH = 128
CPG_GROUP = b"mxfs-boot"
ANNOUNCE_S = 5.0
POST_S = 1.0
HEARD_S = 3.0


class VotequorumInfo(ctypes.Structure):
    # struct votequorum_info, corosync/votequorum.h
    _fields_ = [
        ("node_id", ctypes.c_uint),
        ("node_state", ctypes.c_uint),
        ("node_votes", ctypes.c_uint),
        ("node_expected_votes", ctypes.c_uint),
        ("highest_expected", ctypes.c_uint),
        ("total_votes", ctypes.c_uint),
        ("quorum", ctypes.c_uint),
        ("flags", ctypes.c_uint),
        ("qdevice_votes", ctypes.c_uint),
        ("qdevice_name", ctypes.c_char * VOTEQUORUM_QDEVICE_MAX_NAME_LEN),
    ]


class VotequorumCallbacks(ctypes.Structure):
    # votequorum_callbacks_t: three notification pointers, none used here
    _fields_ = [("quorum", ctypes.c_void_p),
                ("expectedvotes", ctypes.c_void_p),
                ("nodelist", ctypes.c_void_p)]


class Votequorum:
    def __init__(self):
        name = ctypes.util.find_library("votequorum") or "libvotequorum.so.8"
        self.lib = ctypes.CDLL(name)
        self.lib.votequorum_initialize.argtypes = [
            ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(VotequorumCallbacks)]
        self.lib.votequorum_finalize.argtypes = [ctypes.c_uint64]
        self.lib.votequorum_getinfo.argtypes = [
            ctypes.c_uint64, ctypes.c_uint, ctypes.POINTER(VotequorumInfo)]
        self.handle = None
        self.cbs = VotequorumCallbacks()

    def open(self):
        h = ctypes.c_uint64(0)
        rc = self.lib.votequorum_initialize(ctypes.byref(h), ctypes.byref(self.cbs))
        if rc != CS_OK:
            raise OSError("votequorum_initialize rc=%d" % rc)
        self.handle = h.value

    def close(self):
        if self.handle is not None:
            self.lib.votequorum_finalize(self.handle)
            self.handle = None

    def info(self, nodeid):
        if self.handle is None:
            self.open()
        i = VotequorumInfo()
        rc = self.lib.votequorum_getinfo(self.handle, nodeid, ctypes.byref(i))
        if rc != CS_OK:
            raise OSError("votequorum_getinfo node=%d rc=%d" % (nodeid, rc))
        return i


class CpgName(ctypes.Structure):
    _fields_ = [("length", ctypes.c_uint32), ("value", ctypes.c_char * CPG_MAX_NAME_LENGTH)]


class CpgAddress(ctypes.Structure):
    _fields_ = [("nodeid", ctypes.c_uint32), ("pid", ctypes.c_uint32), ("reason", ctypes.c_uint32)]


class Iovec(ctypes.Structure):
    _fields_ = [("iov_base", ctypes.c_void_p), ("iov_len", ctypes.c_size_t)]


DELIVER_FN = ctypes.CFUNCTYPE(None, ctypes.c_uint64, ctypes.POINTER(CpgName), ctypes.c_uint32,
                              ctypes.c_uint32, ctypes.c_void_p, ctypes.c_size_t)
CONFCHG_FN = ctypes.CFUNCTYPE(None, ctypes.c_uint64, ctypes.POINTER(CpgName),
                              ctypes.POINTER(CpgAddress), ctypes.c_size_t,
                              ctypes.POINTER(CpgAddress), ctypes.c_size_t,
                              ctypes.POINTER(CpgAddress), ctypes.c_size_t)


class CpgCallbacks(ctypes.Structure):
    _fields_ = [("deliver", DELIVER_FN), ("confchg", CONFCHG_FN)]


def read_uuid(path):
    with open(path) as f:
        v = f.read().strip().replace("-", "").lower()
    if len(v) != 32 or any(c not in "0123456789abcdef" for c in v):
        raise OSError("%s does not hold a UUID" % path)
    return "%s-%s-%s-%s-%s" % (v[:8], v[8:12], v[12:16], v[16:20], v[20:])


class BootAnnounce:
    """This node's host and boot to the other members, theirs to us, over
    corosync CPG.  boots: nodeid -> (host, boot), for members that announced
    since they last joined."""

    def __init__(self):
        name = ctypes.util.find_library("cpg") or "libcpg.so.4"
        self.lib = ctypes.CDLL(name)
        self.lib.cpg_initialize.argtypes = [ctypes.POINTER(ctypes.c_uint64),
                                            ctypes.POINTER(CpgCallbacks)]
        self.lib.cpg_finalize.argtypes = [ctypes.c_uint64]
        self.lib.cpg_join.argtypes = [ctypes.c_uint64, ctypes.POINTER(CpgName)]
        self.lib.cpg_dispatch.argtypes = [ctypes.c_uint64, ctypes.c_int]
        self.lib.cpg_mcast_joined.argtypes = [ctypes.c_uint64, ctypes.c_int,
                                              ctypes.POINTER(Iovec), ctypes.c_uint]
        self.handle = None
        self.boots = {}
        self.msg = ("MXFS-BOOT v1 host=%s boot=%s" % (
            read_uuid("/etc/machine-id"),
            read_uuid("/proc/sys/kernel/random/boot_id"))).encode()
        self.due = 0.0
        # the isolation exchange: (kind, node, inc) -> when heard / last sent
        self.heard = {}
        self.sent = {}
        self.cbs = CpgCallbacks(DELIVER_FN(self.on_deliver), CONFCHG_FN(self.on_confchg))

    def on_deliver(self, handle, group, nodeid, pid, msg, msg_len):
        f = ctypes.string_at(msg, msg_len).decode(errors="replace").split()
        if len(f) == 4 and f[0] == "MXFS-BOOT" and f[1] == "v1" and \
                f[2].startswith("host=") and f[3].startswith("boot="):
            self.boots[nodeid] = (f[2][5:], f[3][5:])
        elif len(f) == 4 and f[0] in ("MXFS-ASK", "MXFS-CLOSED") and f[1] == "v1" and \
                f[2].startswith("node=") and f[3].startswith("inc="):
            try:
                key = (f[0][5:].lower(), int(f[2][5:]), int(f[3][4:]))
            except ValueError:
                return
            self.heard[key] = time.monotonic()

    def heard_list(self, kind):
        now = time.monotonic()
        return ",".join("%d/%d" % (n, i) for (k, n, i), t in sorted(self.heard.items())
                        if k == kind and now - t <= HEARD_S)

    def mcast(self, text):
        buf = ctypes.create_string_buffer(text, len(text))
        iov = Iovec(ctypes.cast(buf, ctypes.c_void_p), len(text))
        return self.lib.cpg_mcast_joined(self.handle, CPG_TYPE_AGREED, ctypes.byref(iov), 1)

    def post(self, posts):
        """Multicast the module's standing posts, each once per POST_S."""
        now = time.monotonic()
        for key in posts:
            if now - self.sent.get(key, -POST_S) >= POST_S and \
                    self.mcast(("MXFS-%s v1 node=%d inc=%d" % (key[0].upper(), key[1], key[2])).encode()) == CS_OK:
                self.sent[key] = now
        for key in [k for k, t in self.sent.items() if now - t > 10 * POST_S]:
            del self.sent[key]
        for key in [k for k, t in self.heard.items() if now - t > HEARD_S]:
            del self.heard[key]

    def on_confchg(self, handle, group, members, nmembers, left, nleft, joined, njoined):
        for i in range(nleft):
            self.boots.pop(left[i].nodeid, None)
        for i in range(njoined):
            self.boots.pop(joined[i].nodeid, None)
        if njoined:
            self.due = 0.0      # tell the newcomer at once

    def open(self):
        h = ctypes.c_uint64(0)
        rc = self.lib.cpg_initialize(ctypes.byref(h), ctypes.byref(self.cbs))
        if rc != CS_OK:
            raise OSError("cpg_initialize rc=%d" % rc)
        g = CpgName(len(CPG_GROUP), CPG_GROUP)
        rc = self.lib.cpg_join(h.value, ctypes.byref(g))
        if rc != CS_OK:
            self.lib.cpg_finalize(h.value)
            raise OSError("cpg_join rc=%d" % rc)
        self.handle = h.value
        self.boots = {}
        self.due = 0.0

    def close(self):
        if self.handle is not None:
            self.lib.cpg_finalize(self.handle)
            self.handle = None
            self.boots = {}

    def tick(self):
        if self.handle is None:
            self.open()
        rc = self.lib.cpg_dispatch(self.handle, CS_DISPATCH_ALL)
        if rc != CS_OK:
            raise OSError("cpg_dispatch rc=%d" % rc)
        now = time.monotonic()
        if now >= self.due and self.mcast(self.msg) == CS_OK:
            self.due = now + ANNOUNCE_S


def nodelist(path=CONF):
    """[(nodeid, ring0_addr)] from corosync.conf's nodelist."""
    nodes, stack, cur = [], [], None
    with open(path) as f:
        for raw in f:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            if line.endswith("{"):
                stack.append(line[:-1].strip())
                if stack == ["nodelist", "node"]:
                    cur = {}
                continue
            if line == "}":
                if stack == ["nodelist", "node"] and cur is not None:
                    if "nodeid" in cur and "ring0_addr" in cur:
                        nodes.append((int(cur["nodeid"]), cur["ring0_addr"]))
                    cur = None
                if stack:
                    stack.pop()
                continue
            if cur is not None and ":" in line:
                k, v = line.split(":", 1)
                cur[k.strip()] = v.strip()
    return nodes


def ipv4(addr):
    try:
        socket.inet_aton(addr)
        return addr
    except OSError:
        return socket.gethostbyname(addr)


def local_addrs():
    out = set()
    with os.popen("ip -4 -o addr show 2>/dev/null") as p:
        for line in p:
            f = line.split()
            if "inet" in f:
                out.add(f[f.index("inet") + 1].split("/")[0])
    return out


def report(vq, ba=None):
    """The report text, and whether this node is quorate.  Raises OSError
    when votequorum cannot be asked.  `ba`: the boot announcements, if any."""
    nodes = [(nid, ipv4(a)) for nid, a in nodelist()]
    mine = local_addrs()
    me = [nid for nid, a in nodes if a in mine]
    if len(me) != 1:
        raise OSError("this host is %d nodes of the nodelist (want 1)" % len(me))
    self_info = vq.info(me[0])
    flags = self_info.flags
    quorate = bool(flags & VOTEQUORUM_INFO_QUORATE)
    want = (VOTEQUORUM_INFO_QDEVICE_REGISTERED | VOTEQUORUM_INFO_QDEVICE_ALIVE |
            VOTEQUORUM_INFO_QDEVICE_CAST_VOTE)
    qdevice = (flags & want) == want
    members, boots = [], []
    for nid, a in nodes:
        st = self_info.node_state if nid == me[0] else vq.info(nid).node_state
        if st == VOTEQUORUM_NODESTATE_MEMBER:
            members.append(a)
            if ba is not None and nid in ba.boots:
                boots.append("%s/%s/%s" % (a, ba.boots[nid][0], ba.boots[nid][1]))
    text = ("QUORATE=%d\nQDEVICE=%d\nTWONODE=%d\nNODES=%s\nMEMBERS=%s\n"
            "BOOTS=%s\nVOTES=%d/%d\n" % (
                quorate, qdevice, bool(flags & VOTEQUORUM_INFO_TWONODE),
                ",".join(a for _, a in nodes), ",".join(members), ",".join(boots),
                self_info.total_votes, self_info.highest_expected))
    if ba is not None:
        text += "ASKS=%s\nCLOSED=%s\n" % (ba.heard_list("ask"), ba.heard_list("closed"))
    return text + "END=1\n", quorate


def read_posts():
    """The module's standing isolation-exchange posts: {(kind, node, inc)}."""
    out = set()
    try:
        with open(PROC) as f:
            for line in f:
                w = line.split()
                if len(w) == 3 and w[0] in ("ask", "closed") and \
                        w[1].startswith("node=") and w[2].startswith("inc="):
                    out.add((w[0], int(w[1][5:]), int(w[2][4:])))
    except (OSError, ValueError):
        pass
    return out


def inquorate_text(why):
    return ("QUORATE=0\nQDEVICE=0\nTWONODE=0\nNODES=\nMEMBERS=\nBOOTS=\n"
            "DETAIL=%s\nEND=1\n" % why.replace("\n", " "))


def write_proc(text):
    try:
        fd = os.open(PROC, os.O_WRONLY)
    except FileNotFoundError:
        return False           # the module is not loaded: nothing to renew
    try:
        os.write(fd, text.encode())
    finally:
        os.close(fd)
    return True


def cmd_run():
    vq = Votequorum()
    ba = BootAnnounce()
    last_err = None
    while True:
        t0 = time.monotonic()
        try:
            # announcements are a fact about other nodes' boots; a failure
            # here costs only them, never the vote
            try:
                ba.tick()
                ba.post(read_posts())
            except OSError as e:
                ba.close()
                if str(e) != last_err:
                    print("mxfs_quorumd: CPG: %s -- no boot announcements" % e, flush=True)
                    last_err = str(e)
            text, _ = report(vq, ba)
            if last_err:
                print("mxfs_quorumd: votequorum answers again", flush=True)
                last_err = None
        except Exception as e:     # never report quorate without an answer
            vq.close()
            text = inquorate_text(str(e))
            if str(e) != last_err:
                print("mxfs_quorumd: cannot ask votequorum: %s -- reporting "
                      "inquorate" % e, flush=True)
                last_err = str(e)
        try:
            write_proc(text)
        except OSError as e:
            print("mxfs_quorumd: %s: %s" % (PROC, e), flush=True)
        time.sleep(max(0.0, TICK_S - (time.monotonic() - t0)))


def cmd_query(boots=True):
    vq = Votequorum()
    ba = None
    try:
        # joining the group makes every member announce itself at once
        if boots:
            try:
                ba = BootAnnounce()
                t_end = time.monotonic() + 1.5
                while time.monotonic() < t_end:
                    ba.tick()
                    time.sleep(0.1)
            except OSError:
                ba = None
        text, quorate = report(vq, ba)
    except Exception as e:
        sys.stdout.write(inquorate_text(str(e)))
        return 2
    finally:
        vq.close()
        if ba is not None:
            ba.close()
    sys.stdout.write(text)
    return 0 if quorate else 1


def main(argv):
    if len(argv) != 2 or argv[1] not in ("run", "query", "vote"):
        sys.stderr.write("usage: mxfs_quorumd.py run|query|vote\n")
        return 64
    if argv[1] == "run":
        return cmd_run()
    return cmd_query(boots=argv[1] == "query")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
