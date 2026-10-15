#!/bin/bash
#
# vsphere_guest_run.sh — run a shell command inside a vSphere guest through
# VMware Tools, with no use of the guest's network.
#
# Usage: tools/vsphere_guest_run.sh <vm> <command...>
#
# The command runs as the node user from the lab secrets store (`node` entry,
# the same credential tools/mxfs_sshpass.sh uses) under /bin/bash -c, and its
# stdout/stderr come back on this terminal.  govc reaches the guest through
# vCenter and vmtoolsd's hypervisor channel, so this still works on a guest
# whose NIC has stopped receiving — which is exactly when its state is worth
# reading and ssh cannot get in.  The password travels in GOVC_GUEST_LOGIN,
# never on a command line.
#
# Exit status is the guest command's.

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 <vm> <command...>" >&2
    exit 2
fi
vm=$1; shift

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Sourced scripts see this script's positional parameters, so vsphere_env.sh
# gets its entry name explicitly — without it the guest command became the
# entry it looked up.
. "$here/../scripts/vsphere_env.sh" lab
. "$here/mxfs_secrets.sh"

user=$(secrets_get node username)
pass=$(secrets_get node password)
if [ -z "$user" ] || [ -z "$pass" ]; then
    echo "vsphere_guest_run: no node credential in ${MXFS_SECRETS}" >&2
    exit 2
fi
export GOVC_GUEST_LOGIN="$user:$pass"

# The guest runs the program line through its own shell and govc appends the
# output redirect to the END of that line, so a command passed as plain words
# is split at every ';' and only its last command's output comes back.  Ship it
# base64 (no shell metacharacters) and let the guest decode it into ONE bash -c
# argument; the redirect then applies to the whole command.
b64=$(printf '%s' "$*" | base64 -w0)
exec govc guest.run -vm "$vm" /bin/bash -c "\"\$(echo $b64 | base64 -d)\""
