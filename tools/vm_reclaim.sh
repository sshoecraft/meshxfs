#!/bin/bash
#
# vm_reclaim.sh — give clyde back the space its guests' qcow2 images hold for
# data the guests have deleted.
#
# A qcow2 image grows when a guest writes and never shrinks by itself: test4
# used 4.6 GB inside and its image held 10.4 GB (2026-10-11), 288 GB across 43
# guest images.  Every domain's disk is defined discard='unmap'
# detect_zeroes='unmap', so a TRIM inside the guest makes qemu free those
# clusters and punch them out of the image file; nothing trims on its own.
#
# Usage: tools/vm_reclaim.sh [--compact] <domain>...
#   default    fstrim -av inside each guest.  A shut-off domain is started for
#              it and shut down again afterwards.  A domain whose disk lacks
#              discard='unmap' gets it (persistently) and is restarted first.
#   --compact  then rewrite each image with `qemu-img convert -O qcow2` while
#              the domain is shut off (a running one is shut down for it and
#              started again), verified with `qemu-img compare` before it
#              replaces the original.  Recovers what trimming leaves behind
#              (clusters freed without a hole, fragmentation).
# Prints per domain the image's allocated size before and after.  Never run
# it on nodes a rig run is using: it restarts some, and trims under load.
set -u
cd "$(dirname "$0")/.." || exit 2
V="virsh -c qemu:///system"
SSH=tools/mxfs_sshpass.sh
COMPACT=0
[ "${1:-}" = --compact ] && { COMPACT=1; shift; }
[ $# -gt 0 ] || { echo "usage: $0 [--compact] <domain>..." >&2; exit 2; }

gib() { qemu-img info -U --output=json "$1" 2>/dev/null \
    | python3 -c 'import json,sys; print("%.1f" % (json.load(sys.stdin)["actual-size"] / 2**30))'; }
state() { timeout 20 $V domstate "$1" 2>/dev/null | head -1; }
image_of() { timeout 20 $V domblklist --details "$1" 2>/dev/null \
    | awk '$1 == "file" && $2 == "disk" {print $4; exit}'; }

addr_of() {  # <dom>: the lab file's address, else what libvirt sees on its NIC
    local a
    a=$(tools/mxfs_lab.sh addr "$1" 2>/dev/null)
    case "$a" in *.*.*.*) echo "$a"; return 0 ;; esac
    getent hosts "$1" >/dev/null 2>&1 && { echo "$1"; return 0; }
    for src in lease arp agent; do
        a=$(timeout 10 $V domifaddr "$1" --source "$src" 2>/dev/null \
            | awk '$3 == "ipv4" {sub("/.*", "", $4); print $4; exit}')
        [ -n "$a" ] && { echo "$a"; return 0; }
    done
    return 1
}

# wait_ssh <dom> <bound s>: sets ADDR to the address that answered.  The
# nested Proxmox guests (pve9-*) are in no lab line and no resolver, and their
# address shows in libvirt's ARP view only once they talk, so it is looked up
# again on every try.
wait_ssh() {
    local i=0
    while [ "$i" -lt "$2" ]; do
        ADDR=$(addr_of "$1") && timeout 15 "$SSH" "$ADDR" true >/dev/null 2>&1 && return 0
        timeout 2 ping -c1 -W1 "${ADDR:-127.0.0.1}" >/dev/null 2>&1
        sleep 5; i=$((i + 5))
    done
    return 1
}

stop_dom() {  # <dom>: clean shutdown, bounded, then destroy
    local i=0
    timeout 20 $V shutdown "$1" >/dev/null 2>&1
    while [ "$i" -lt 180 ]; do
        [ "$(state "$1")" = "shut off" ] && return 0
        sleep 5; i=$((i + 5))
    done
    echo "  $1: no clean shutdown in 180 s; destroying"
    timeout 30 $V destroy "$1" >/dev/null 2>&1
    [ "$(state "$1")" = "shut off" ]
}

for dom in "$@"; do
    img=$(image_of "$dom")
    [ -n "$img" ] && [ -f "$img" ] || { echo "$dom: no file disk found; skipped"; continue; }
    before=$(gib "$img")
    st0=$(state "$dom")
    echo "== $dom ($st0) $img: ${before} GiB allocated"

    # discard must be live for a trim to reach the image
    if ! timeout 20 $V dumpxml --inactive "$dom" | grep -q "discard='unmap'"; then
        timeout 30 virt-xml -c qemu:///system "$dom" --edit all \
            --disk discard=unmap,detect_zeroes=unmap >/dev/null 2>&1 \
            && echo "  set discard=unmap (persistent)" \
            || echo "  could not set discard=unmap"
    fi
    if [ "$st0" = running ] && ! timeout 20 $V dumpxml "$dom" | grep -q "discard='unmap'"; then
        echo "  live definition lacks discard; restarting"
        stop_dom "$dom" && timeout 30 $V start "$dom" >/dev/null 2>&1
    fi

    started=0
    if [ "$(state "$dom")" != running ]; then
        timeout 30 $V start "$dom" >/dev/null 2>&1 && started=1
    fi
    if wait_ssh "$dom" 240; then
        out=$(timeout 900 "$SSH" "$ADDR" 'fstrim -av 2>&1 || sudo -n fstrim -av 2>&1' 2>&1 \
            | grep -v -E '^Warning|Unauthorized|disconnect')
        echo "$out" | sed 's/^/  fstrim: /'
    else
        echo "  $dom: no ssh within 240 s; not trimmed"
    fi
    [ "$started" = 1 ] && stop_dom "$dom"

    if [ "$COMPACT" = 1 ]; then
        was_running=0
        if [ "$(state "$dom")" = running ]; then was_running=1; stop_dom "$dom" || { echo "  could not stop; not compacted"; continue; }; fi
        tmp="$img.compact"
        if timeout 1800 qemu-img convert -O qcow2 "$img" "$tmp" \
           && timeout 1800 qemu-img compare -q "$img" "$tmp"; then
            chmod --reference="$img" "$tmp"
            chown --reference="$img" "$tmp" 2>/dev/null || sudo -n chown --reference="$img" "$tmp"
            mv -f "$tmp" "$img" && echo "  compacted (contents verified identical)"
        else
            echo "  compaction failed or did not compare equal; original kept${tmp:+, $tmp left for inspection}"
        fi
        [ "$was_running" = 1 ] && timeout 30 $V start "$dom" >/dev/null 2>&1
    fi

    echo "  $dom: ${before} -> $(gib "$img") GiB allocated"
done
df -h / | tail -1
