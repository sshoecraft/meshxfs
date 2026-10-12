---
name: reference-pve-pair-qdevice-is-qnetd-on-serv
description: corosync-qnetd on serv 192.168.1.5 is the QDevice for the physical pve1/pve2 cluster AND for nested PVE clusters on clyde (user-approved).
metadata:
  type: reference
tags: [pve, qdevice, quorum, rig, nested]
---

**serv, 192.168.1.5** (Debian 11 bullseye) runs `corosync-qnetd` (port 5403, ffsplit, tls on). The user approved it as the QDevice for the physical Proxmox pair AND for nested Proxmox clusters built as VMs on clyde. One qnetd serves many clusters as long as each cluster has a distinct name.

Physical pair: pve1 (192.168.1.80) / pve2 (192.168.1.81), cluster `mxfs-cluster`. Set up 2026-10-10 with `pvecm qdevice remove` + `pvecm qdevice setup 192.168.1.5 --force` from pve1, after pve1's root key was added to serv's /root/.ssh/authorized_keys.

- Before that, corosync.conf pointed the QDevice at **192.168.1.108**, which no longer answers: `pvecm status` showed `Expected votes: 3, Total votes: 2`, both nodes `A,NV,NMW`, and corosync-qdevice logged "Can't connect to qnetd host". A two-node cluster in that state has no tie-breaker: losing one node loses quorum.
- Healthy looks like: `Total votes: 3`, both nodes `A,V,NMW`, `Qdevice` with 1 vote.
- For a nested cluster: its VMs must reach 192.168.1.5:5403 (bridged onto the lab LAN, or NAT from clyde), the node running `pvecm qdevice setup` needs its root key in serv's authorized_keys, and every node needs `corosync-qdevice` installed.
- serv's root password is the user's; it is NOT in the tree or in ~/.config/mxfslab/secrets. pve1 reaches serv by key; clyde does not.
- serv's apt has broken third-party sources (bullseye-backports gone, hashicorp/github/jenkins keys); Debian main still installs packages.
