---
name: Bug report
about: Something went wrong, hung, or was unexpectedly slow
title: ''
labels: bug
assignees: ''
---

**What happened**

What you did, what you expected, and what happened instead. Include the time
it happened (with time zone) so it can be found in the logs.

**Versions, on every node**

```
cat /sys/module/mxfs/version
uname -r
```

Proxmox VE / distribution version:

**Configuration**

- Number of nodes:
- Storage: shared SAN LUN, or two hosts on DRBD
- Attachment: single path, or dm-multipath (how many paths)
- Lock manager: network (default) or on-disk (`force_transport=0` or `-o transport=caw`)
- Storage target (array, iSCSI target software, or DRBD version):
- Mount options:

The lock manager each mount runs is in its kernel log:

```
dmesg | grep P-DOMAIN-ADMITTED
```

**Kernel log from every node**

Please attach the kernel log of **every** node, not only the one that showed
the problem, covering a few minutes before it started until after it ended:

```
journalctl -k --since "YYYY-MM-DD HH:MM" > mxfs-$(hostname).log
```

If a node rebooted, was fenced or lost power, its log from before that is in
the previous boot:

```
journalctl -k -b -1 > mxfs-$(hostname)-previous-boot.log
```

**Filesystem check**, if data looks wrong or a mount is refused (unmounted on
every node if you can):

```
chk_mxfs -v /dev/<device>
```

**Workload**

What was running when it happened (VM migrations, backups, a particular
guest, a benchmark), and whether it happens again when repeated.
