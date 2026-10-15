#!/usr/bin/python3
#
# mxfs_fence_vcenter.py — the shared attachment's vCenter fence helper
#
# docs/shared-disk-attachment.md, fence=vcenter.  The mxfs module runs this
# node-local helper (installed as /usr/sbin/mxfs_fence_vcenter.py) and waits,
# bounded, for its report:
#
#   mxfs_fence_vcenter.py <nonce> <mode> <host> <boot> <report-path>
#
#   arm    tag this node's own VM, found by its BIOS UUID, with the custom
#          attributes mxfs.host=<host> and mxfs.boot=<boot>.  RESULT=ARMED, or
#          REFUSED when vCenter cannot be reached, no VM or more than one VM
#          has this BIOS UUID, another VM already carries mxfs.host=<host> (a
#          clone that kept /etc/machine-id), or the VM has a snapshot that
#          holds its memory (reverting one resumes an old boot alive).
#   check  has boot <boot> of host <host> ended?  The VM tagged mxfs.host=
#          <host> is powered off (HOW=POWERED_OFF), or tagged by a later boot
#          (HOW=BOOTED_AGAIN): RESULT=ENDED.  Otherwise RUNNING.  Changes
#          nothing.
#   fence  as check, but a VM still running that boot is powered off first,
#          and the answer is read after the power-off task completes.
#
# The report is KEY=value lines (NONCE, MODE, RESULT, HOW, VM, POWER,
# VM_BOOT, DETAIL) and the end mark MXFS-FENCEH-END, written to <report-path>
# (/proc/fs/mxfs/fence_report) in one write.  The module parses it and judges
# nothing but those fields; a helper that cannot answer reports why and is
# never taken as evidence.
#
# Configuration, /etc/mxfs/vcenter.conf (root-owned):
#   server=<vCenter address>
#   user=<account>          privileges: read VMs, set a custom attribute,
#                           define one (first use only), power a VM off
#   password_file=<path>    the password alone, root-owned, mode 0600
#   insecure=1              optional: skip vCenter's certificate check
#
# Needs pyVmomi (python3-pyvmomi, or pip install pyvmomi).
#
import os
import socket
import ssl
import sys
import time

CONF = "/etc/mxfs/vcenter.conf"
FIELD_HOST = "mxfs.host"
FIELD_BOOT = "mxfs.boot"
END_MARK = "MXFS-FENCEH-END"
# Each vCenter call is bounded by this socket timeout; the module's own bound
# on the whole upcall (fence_vcenter_timeout_ms, 60 s) covers a login, one
# inventory read, a power-off task and the read after it.
CALL_TIMEOUT_S = 20
POWEROFF_WAIT_S = 30


def report(path, fields):
    lines = "".join("%s=%s\n" % (k, str(v).replace("\n", " ")) for k, v in fields.items())
    with open(path, "w") as f:
        f.write(lines + END_MARK + "\n")


def read_conf():
    conf = {}
    st = os.stat(CONF)
    if st.st_uid != 0:
        raise RuntimeError("%s is not owned by root" % CONF)
    with open(CONF) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            conf[k.strip()] = v.strip()
    for k in ("server", "user", "password_file"):
        if not conf.get(k):
            raise RuntimeError("%s has no %s=" % (CONF, k))
    pst = os.stat(conf["password_file"])
    if pst.st_uid != 0 or pst.st_mode & 0o077:
        raise RuntimeError("%s must be root-owned and mode 0600" % conf["password_file"])
    with open(conf["password_file"]) as f:
        conf["password"] = f.read().strip()
    return conf


def bios_uuid():
    with open("/sys/class/dmi/id/product_uuid") as f:
        u = f.read().strip().lower()
    # SMBIOS before 2.6 stores the first three fields little-endian, and a
    # kernel reading such a table prints them swapped from what vSphere shows.
    p = u.split("-")
    if len(p) != 5:
        return u, u

    def swap(h):
        return "".join(reversed([h[i:i + 2] for i in range(0, len(h), 2)]))
    return u, "-".join([swap(p[0]), swap(p[1]), swap(p[2]), p[3], p[4]])


def connect(conf):
    from pyVim.connect import SmartConnect
    socket.setdefaulttimeout(CALL_TIMEOUT_S)
    ctx = ssl.create_default_context()
    if conf.get("insecure") == "1":
        ctx = ssl._create_unverified_context()
    return SmartConnect(host=conf["server"], user=conf["user"],
                        pwd=conf["password"], sslContext=ctx)


def inventory(si):
    """Every VM with the properties the decisions read, in one collector call."""
    from pyVmomi import vim, vmodl
    content = si.RetrieveContent()
    view = content.viewManager.CreateContainerView(content.rootFolder,
                                                   [vim.VirtualMachine], True)
    try:
        props = ["name", "config.uuid", "config.instanceUuid",
                 "runtime.powerState", "customValue", "snapshot"]
        spec = vmodl.query.PropertyCollector.FilterSpec(
            objectSet=[vmodl.query.PropertyCollector.ObjectSpec(
                obj=view, skip=True,
                selectSet=[vmodl.query.PropertyCollector.TraversalSpec(
                    name="t", path="view", skip=False,
                    type=vim.view.ContainerView)])],
            propSet=[vmodl.query.PropertyCollector.PropertySpec(
                type=vim.VirtualMachine, pathSet=props)])
        out = content.propertyCollector.RetrieveContents([spec])
    finally:
        view.Destroy()
    vms = []
    for oc in out:
        d = {"obj": oc.obj}
        for p in oc.propSet:
            d[p.name] = p.val
        vms.append(d)
    return content, vms


def field_keys(content, create):
    from pyVmomi import vim
    cfm = content.customFieldsManager
    keys = {}
    for f in cfm.field or []:
        if f.name in (FIELD_HOST, FIELD_BOOT) and \
                f.managedObjectType in (None, vim.VirtualMachine):
            keys[f.name] = f.key
    for name in (FIELD_HOST, FIELD_BOOT):
        if name not in keys and create:
            keys[name] = cfm.AddCustomFieldDef(name=name, moType=vim.VirtualMachine).key
    return keys


def value_of(vm, key):
    for cv in vm.get("customValue") or []:
        if cv.key == key:
            return cv.value
    return ""


def memory_snapshot(vm):
    """A snapshot taken powered on holds the VM's memory: reverting to it
    resumes the boot that was running then, alive, whatever came after."""
    snap = vm.get("snapshot")
    stack = list(snap.rootSnapshotList) if snap else []
    while stack:
        s = stack.pop()
        if str(s.state) == "poweredOn":
            return True
        stack.extend(s.childSnapshotList or [])
    return False


def vm_name(vm):
    return "%s (%s)" % (vm.get("name", "?"), vm.get("config.instanceUuid", "?"))


def own_vm(vms):
    a, b = bios_uuid()
    mine = [vm for vm in vms if (vm.get("config.uuid") or "").lower() in (a, b)]
    if len(mine) != 1:
        raise RuntimeError("%d VMs have this node's BIOS UUID %s" % (len(mine), a))
    return mine[0]


def do_arm(si, host, boot):
    content, vms = inventory(si)
    me = own_vm(vms)
    keys = field_keys(content, create=True)
    if memory_snapshot(me):
        return {"RESULT": "REFUSED", "VM": vm_name(me),
                "POWER": me.get("runtime.powerState"),
                "DETAIL": "this VM has a snapshot that holds its memory; "
                          "reverting to it would resume an old boot alive"}
    for vm in vms:
        if vm["obj"] != me["obj"] and value_of(vm, keys[FIELD_HOST]) == host:
            return {"RESULT": "REFUSED", "VM": vm_name(me),
                    "POWER": me.get("runtime.powerState"),
                    "DETAIL": "VM %s already carries %s=%s: two VMs share this "
                              "machine-id (regenerate it on the clone, then "
                              "clear the attribute)" % (vm_name(vm), FIELD_HOST, host)}
    cfm = content.customFieldsManager
    cfm.SetField(entity=me["obj"], key=keys[FIELD_HOST], value=host)
    cfm.SetField(entity=me["obj"], key=keys[FIELD_BOOT], value=boot)
    content, vms = inventory(si)
    me = own_vm(vms)
    if value_of(me, keys[FIELD_HOST]) != host or value_of(me, keys[FIELD_BOOT]) != boot:
        return {"RESULT": "REFUSED", "VM": vm_name(me),
                "DETAIL": "the attributes did not read back as written"}
    return {"RESULT": "ARMED", "VM": vm_name(me),
            "POWER": me.get("runtime.powerState"), "VM_BOOT": boot}


def judge(vm, keys, boot):
    """ENDED with how, or None.  Never on anything but vCenter's own state."""
    power = str(vm.get("runtime.powerState"))
    if power == "poweredOff":
        return "POWERED_OFF"
    tagged = value_of(vm, keys[FIELD_BOOT])
    if tagged and tagged != boot and not memory_snapshot(vm):
        return "BOOTED_AGAIN"
    return None


def do_check(si, host, boot, act):
    content, vms = inventory(si)
    keys = field_keys(content, create=False)
    if FIELD_HOST not in keys or FIELD_BOOT not in keys:
        return {"RESULT": "RUNNING", "DETAIL": "vCenter has no %s attribute: no "
                "node ever armed" % FIELD_HOST}
    tagged = [vm for vm in vms if value_of(vm, keys[FIELD_HOST]) == host]
    if len(tagged) != 1:
        return {"RESULT": "RUNNING", "DETAIL": "%d VMs carry %s=%s; the victim's "
                "VM cannot be named" % (len(tagged), FIELD_HOST, host)}
    vm = tagged[0]
    a, b = bios_uuid()
    if (vm.get("config.uuid") or "").lower() in (a, b):
        return {"RESULT": "RUNNING", "VM": vm_name(vm),
                "DETAIL": "the VM tagged with that host is this node's own"}
    how = judge(vm, keys, boot)
    fields = {"VM": vm_name(vm), "POWER": vm.get("runtime.powerState"),
              "VM_BOOT": value_of(vm, keys[FIELD_BOOT])}
    if how:
        fields.update({"RESULT": "ENDED", "HOW": how})
        return fields
    if not act:
        fields.update({"RESULT": "RUNNING", "DETAIL": "the VM still runs that boot"})
        return fields
    task = vm["obj"].PowerOffVM_Task()
    t0 = time.time()
    while str(task.info.state) in ("queued", "running") and time.time() - t0 < POWEROFF_WAIT_S:
        time.sleep(0.5)
    tstate = str(task.info.state)
    terr = task.info.error.msg if task.info.error else ""
    content, vms = inventory(si)
    again = [x for x in vms if x["obj"] == vm["obj"]]
    if not again:
        fields.update({"RESULT": "RUNNING",
                       "DETAIL": "the VM left the inventory during the power-off"})
        return fields
    vm = again[0]
    how = judge(vm, keys, boot)
    fields = {"VM": vm_name(vm), "POWER": vm.get("runtime.powerState"),
              "VM_BOOT": value_of(vm, keys[FIELD_BOOT])}
    if how:
        fields.update({"RESULT": "ENDED", "HOW": how,
                       "DETAIL": "power-off task %s in %.1f s" % (tstate, time.time() - t0)})
    else:
        fields.update({"RESULT": "RUNNING",
                       "DETAIL": "power-off task %s %s" % (tstate, terr)})
    return fields


def own_identity():
    """This node's host and boot as the module names them (dlm/hostid.c):
    /etc/machine-id and the kernel's boot_id, 32 lowercase hex digits each."""
    with open("/etc/machine-id") as f:
        host = f.read().strip().lower()
    with open("/proc/sys/kernel/random/boot_id") as f:
        boot = f.read().strip().lower().replace("-", "")
    for v in (host, boot):
        if len(v) != 32 or any(c not in "0123456789abcdef" for c in v):
            raise RuntimeError("cannot read this node's identity (%r)" % v)
    return host, boot


def boot_tag():
    """`boot`: tag this VM with the boot now running, before anything mounts
    (mxfs-vcenter-tag.service).  A whole-cluster restart then finds every VM
    that has booted again tagged by its new boot, so the node recovering the
    outage takes the earlier boots as ended (BOOTED_AGAIN) instead of powering
    those VMs off.  The tag is written from inside the new boot, as a mount's
    arm writes it, under the same refusals.  vCenter may not answer yet early
    in boot: tried BOOT_TRIES times, BOOT_RETRY_S apart."""
    host, boot = own_identity()
    fields = {}
    for attempt in range(BOOT_TRIES):
        fields = {"NONCE": "boot", "MODE": "boot", "ATTEMPT": attempt + 1}
        try:
            si = connect(read_conf())
            try:
                # a refusal here is vCenter's answer, not a failure to reach it
                fields.update(do_arm(si, host, boot))
            finally:
                from pyVim.connect import Disconnect
                Disconnect(si)
            break
        except Exception as e:
            fields.update({"RESULT": "REFUSED", "DETAIL": "%s: %s" % (type(e).__name__, e)})
        if attempt + 1 < BOOT_TRIES:
            time.sleep(BOOT_RETRY_S)
    sys.stdout.write("".join("%s=%s\n" % (k, str(v).replace("\n", " ")) for k, v in fields.items()))
    return 0 if fields.get("RESULT") == "ARMED" else 1


BOOT_TRIES = 6
BOOT_RETRY_S = 10


def main(argv):
    if argv[1:] == ["boot"]:
        return boot_tag()
    if len(argv) != 6:
        sys.stderr.write("usage: %s <nonce> <arm|check|fence> <host> <boot> <report>\n"
                         "       %s boot\n" % (argv[0], argv[0]))
        return 2
    nonce, mode, host, boot, path = argv[1:]
    fields = {"NONCE": nonce, "MODE": mode}
    try:
        conf = read_conf()
        si = connect(conf)
        try:
            if mode == "arm":
                fields.update(do_arm(si, host, boot))
            elif mode in ("check", "fence"):
                fields.update(do_check(si, host, boot, mode == "fence"))
            else:
                fields.update({"RESULT": "REFUSED", "DETAIL": "unknown mode"})
        finally:
            from pyVim.connect import Disconnect
            Disconnect(si)
    except Exception as e:  # every failure is reported, never taken as evidence
        fields.setdefault("RESULT", "REFUSED" if mode == "arm" else "RUNNING")
        fields["DETAIL"] = "%s: %s" % (type(e).__name__, e)
    report(path, fields)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
