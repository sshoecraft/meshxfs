#!/bin/bash
#
# vsphere_env.sh — export govc's connection settings for one vSphere endpoint
#
# Usage: . scripts/vsphere_env.sh [entry]
#
# Reads the osimager secrets file (OSIMAGER_SECRETS, default
# ~/.config/osimager/secrets) and exports GOVC_URL, GOVC_USERNAME,
# GOVC_PASSWORD and GOVC_INSECURE for the entry named vsphere/<entry>:
# `lab` (vCenter, the default), or `esxhost1` / `esxhost2` to talk to one
# ESXi host directly.  The password travels in the environment, never on a
# command line where any process listing would show it.
#

vsphere_entry="vsphere/${1:-lab}"
vsphere_secrets="${OSIMAGER_SECRETS:-$HOME/.config/osimager/secrets}"
vsphere_exports="$(python3 - "$vsphere_secrets" "$vsphere_entry" <<'EOF'
import re, shlex, sys
path, entry = sys.argv[1], sys.argv[2]
for line in open(path):
    parts = line.split()
    if parts and parts[0] == entry:
        f = dict(re.findall(r"(\w+)=(\S+)", line))
        print("export GOVC_URL=%s" % shlex.quote("https://" + f["server"] + "/sdk"))
        print("export GOVC_USERNAME=%s" % shlex.quote(f["username"]))
        print("export GOVC_PASSWORD=%s" % shlex.quote(f["password"]))
        break
else:
    sys.exit("no %s entry in %s" % (entry, path))
EOF
)" || return 1 2>/dev/null || exit 1
eval "$vsphere_exports"
unset vsphere_exports vsphere_entry vsphere_secrets
export GOVC_INSECURE=1
