---
name: compiled-pve-qdevice-qnetd-on-serv
description: corosync-qnetd on serv 192.168.1.5 is the QDevice for physical pve1/pve2 and nested PVE clusters; setup, healthy state, requirements.
metadata:
  type: project
tags: [compiled, pve, qdevice, quorum, rig]
---

Assorted group of one note: the QDevice (quorum tie-breaker) arrangement for Proxmox clusters on the lab rig. Source: [[reference-pve-pair-qdevice-is-qnetd-on-serv]].

- serv (192.168.1.5, Debian 11) runs `corosync-qnetd` on port 5403, ffsplit, tls on. User-approved as QDevice for the physical pair pve1 (192.168.1.80) / pve2 (192.168.1.81), cluster `mxfs-cluster`, and for nested PVE clusters built as VMs on clyde. One qnetd serves many clusters provided each has a distinct cluster name.
- Setup: from pve1, `pvecm qdevice remove` then `pvecm qdevice setup 192.168.1.5 --force`, after pve1's root key is in serv's /root/.ssh/authorized_keys.
- Failure mode found: corosync.conf pointed at 192.168.1.108, which no longer answers. `pvecm status` showed Expected votes 3 / Total votes 2, nodes `A,NV,NMW`, and corosync-qdevice logged "Can't connect to qnetd host". A two-node cluster in that state loses quorum when one node is lost.
- Healthy: Total votes 3, nodes `A,V,NMW`, Qdevice with 1 vote.
- Nested cluster requirements: VMs reach 192.168.1.5:5403 (bridged to lab LAN or NAT from clyde); the node running `pvecm qdevice setup` has its root key in serv's authorized_keys; every node has `corosync-qdevice` installed.
- Access: serv's root password is the user's and is not in the tree or ~/.config/mxfslab/secrets. pve1 reaches serv by key; clyde does not.
- serv's apt has broken third-party sources (bullseye-backports gone, hashicorp/github/jenkins keys); Debian main still installs packages.
