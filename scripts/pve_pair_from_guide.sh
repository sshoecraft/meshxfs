#!/bin/bash
# pve_pair_from_guide.sh — set the physical Proxmox pair up from nothing by
# docs/drbd-setup.md, exactly as a user who installs the released package
# would, and check the result.
#
# A user following an earlier README on these two hosts ended with DRBD over a
# loop file, no fencing and nothing that came back after a reboot.  The guide
# was written for that; this proves it, on the hardware it names, from a fresh
# clone of the public repository.
#
#   teardown  both hosts back to a Proxmox host with no MXFS on it: every DRBD
#             resource that names MXFS's fence handler (not only the guide's
#             `mxfs`) stopped through its unit (it unmounts and steps down) and
#             brought down, its resource file and mount settings removed, the
#             Proxmox storage on each of their mount points removed, the
#             backing LV removed, the mxfs package purged if one is installed,
#             every file `make install` writes removed (the module, tools,
#             helpers, units, /etc/mxfs, the module options and auto-load, the
#             udev rule, man pages), /var/lib/mxfs, any MXFS nftables table,
#             and the source clone moved to /root/mxfs.backup.  Refuses while
#             anything other than MXFS's own units holds one of the mounts.
#   guide     sections 1-6 of the guide, in order, with its own commands: the
#             apt install of DRBD's tools and the mxfs package, the thin LV,
#             the resource file (taken from the guide's text), create-md / up,
#             the first sync, `primary` on node B, mkfs.mxfs on node A, the
#             mount settings, `systemctl enable --now mxfs-drbd@mxfs`, and the
#             Proxmox storage.  Node A is participant 0 (the lower address).
#   finish    the guide from the first sync onward (the wait, `primary` on
#             node B, sections 5 and 6), for a run that stopped during the
#             sync: the sync is DRBD's own and carries on without this script.
#   verify    both mounted, Primary/Primary, UpToDate/UpToDate, the live
#             connection on the guide's ping-int, the guard active, one MXFS
#             build on both, the storage online.
#   (default: teardown guide verify)
#
# Each command the guide prints is checked against docs/drbd-setup.md before it
# runs, so a guide edited out from under this script stops it instead of
# testing something else.  The guide's commands run as written; the only
# additions are what an unattended shell needs (apt's -y) and bounds.
#
# DESTRUCTIVE: everything on the MXFS volume is destroyed.  Run it on a pair
# whose /mnt/shared holds nothing you need.
#
# Usage: scripts/pve_pair_from_guide.sh [phase ...]
# Env:   PVE_PAIR (default "192.168.1.80 192.168.1.81"), REPO_URL (default the
#        guide's), SYNC_BUDGET (seconds for the first sync, default 2700: on
#        pve1/pve2 it ran at 32 MB/s, held there by the SyncTarget's disk and
#        not by the guide's 110 MB/s c-max-rate, so 40 GiB takes ~22 min;
#        twice that, rounded up), MOUNT_BUDGET (seconds from `enable --now`
#        to both mounted, default 300)
#        Section 1 installs the latest release's mxfs package from GitHub.
#        FROM_TREE=1 installs a package built from this working tree instead,
#        by packaging/mkdeb.sh in the image scripts/release.sh builds its
#        packages in: a test build on a pair set up for testing.
#        BACKING_MODEL (default empty = the guide's thin LV): section 2's
#        backing device is instead a partition of BACKING_SIZE (default 200G)
#        on the one disk on each host whose model (as lsblk prints it; sysfs
#        cuts it to 16 characters) contains this text (the
#        guide allows "a partition, a disk or an LVM logical volume"; the
#        pair's two Samsung 850 EVOs are 250 and 500 GB, so a partition gives
#        both nodes the same size).  The disk is wiped and discarded first;
#        a disk holding the root filesystem or anything mounted is refused.
#        The resource names each host's partition by its /dev/disk/by-id path.
#        LV_SIZE (default the guide's 40G): a nested pair's thin pool is ~23 GiB,
#        so pve9-1/pve9-2 carry a 12G volume.  Its first sync ran at 39 MB/s
#        on pve9-3/pve9-4 (DRBD's resync controller wanted 45 MB/s with the
#        receiver idle), ~5 min, so SYNC_BUDGET=630 there.
#        A pair other than the guide's pve1/pve2 gets the guide's resource with
#        its hosts' names and addresses in place of pve1/pve2's, and nothing else
#        changed.
# Evidence: tests/evidence/pve_pair_from_guide/<UTC stamp>/
set -u
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SSHP="$REPO/tools/mxfs_sshpass.sh"
GUIDE="$REPO/docs/drbd-setup.md"
read -r -a PAIR <<<"${PVE_PAIR:-192.168.1.80 192.168.1.81}"
[ "${#PAIR[@]}" = 2 ] || { echo "pve_pair_from_guide: PVE_PAIR must name two hosts"; exit 2; }
REPO_URL=${REPO_URL:-https://github.com/sshoecraft/meshxfs}
SYNC_BUDGET=${SYNC_BUDGET:-2700}
MOUNT_BUDGET=${MOUNT_BUDGET:-300}
LV_SIZE=${LV_SIZE:-40G}
BACKING_MODEL=${BACKING_MODEL:-}
BACKING_SIZE=${BACKING_SIZE:-200G}
# The package install, whose DKMS build of the module on these hosts is the
# build `make` did, measured 2-4 min each on the HP Z400s; twice the slow end.
BUILD_BUDGET=480
PHASES=("$@")
[ "${#PHASES[@]}" -gt 0 ] || PHASES=(teardown guide verify)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
EVID="$REPO/tests/evidence/pve_pair_from_guide/$STAMP"
mkdir -p "$EVID" || exit 1

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$EVID/log"; }
die() { say "FAIL: $*"; exit 1; }
on() {  # <host> <cmd> [timeout] — output to stdout and to the host's log
    local out rc
    out=$(timeout "${3:-60}" "$SSHP" "$1" "$2" </dev/null 2>&1 | grep -avE '^Warning:|^Unauthorized|^If you|^$')
    rc=${PIPESTATUS[0]}
    { echo "### [$(date +%H:%M:%S)] $1 (rc=$rc): $2"; echo "$out"; } >> "$EVID/host-$1.log"
    printf '%s\n' "$out"
    return "$rc"
}
both() {  # <cmd> [timeout] — on both hosts at once; fails if either does
    local h rc=0
    for h in "$P0" "$P1"; do
        on "$h" "$1" "${2:-60}" > "$EVID/both.$h" 2>&1 &
    done
    for h in "$P0" "$P1"; do wait -n || rc=1; done
    for h in "$P0" "$P1"; do sed "s|^|  $h: |" "$EVID/both.$h" | tail -5 | tee -a "$EVID/log"; done
    return "$rc"
}
# guide_has <text>: the guide still prints this command
guide_has() {
    grep -qF -- "$1" "$GUIDE" || die "docs/drbd-setup.md no longer contains: $1"
}

if python3 -I -c 'import ipaddress, sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]) < ipaddress.ip_address(sys.argv[2]) else 1)' "${PAIR[0]}" "${PAIR[1]}"; then
    P0=${PAIR[0]}; P1=${PAIR[1]}
else
    P0=${PAIR[1]}; P1=${PAIR[0]}
fi

teardown() {
    say "== teardown: both hosts back to no MXFS"
    local h out mnts stores
    # MXFS's resources: every resource file naming its fence handler, and the
    # mount point each one's settings give (the guide's /mnt/shared at least)
    local RESLIST="grep -l mxfs-drbd-fence-peer /etc/drbd.d/*.res 2>/dev/null | xargs -r -n1 basename | sed 's/\\.res\$//'"
    local MNTLIST="{ echo /mnt/shared; cat /etc/mxfs/drbd-*.conf 2>/dev/null | sed -n 's/^MOUNTPOINT=//p'; } | sort -u"
    mnts=""
    for h in "$P0" "$P1"; do
        out=$(on "$h" "hostname; for m in \$($MNTLIST); do echo MNT \$m; done; for r in \$($RESLIST); do echo RES \$r; done" 60)
        say "$h: $(echo "$out" | head -1): resources $(awk '$1 == "RES" {printf "%s ", $2}' <<<"$out")mounts $(awk '$1 == "MNT" {printf "%s ", $2}' <<<"$out")"
        mnts="$mnts $(awk '$1 == "MNT" {print $2}' <<<"$out")"
    done
    mnts=$(tr ' ' '\n' <<<"$mnts" | grep . | sort -u | tr '\n' ' ')
    # the Proxmox storage entries on those mount points (pvesm's config is
    # cluster-wide, so one host's view is all of them)
    stores=$(on "$P0" "awk '/^[a-z]+: / {s = \$2} \$1 == \"path\" {print s, \$2}' /etc/pve/storage.cfg" 30 \
        | awk -v m=" $mnts" 'index(m, " " $2 " ") {print $1}' | tr '\n' ' ')
    for h in "$P0" "$P1"; do
        out=$(on "$h" "qm list 2>/dev/null | awk 'NR > 1 {print \$1}' | while read -r id; do for s in $stores; do qm config \$id 2>/dev/null | grep -qE \"^[a-z]+[0-9]+:.*\$s:\" && echo SHARED_VM \$id on \$s; done; done; for m in $mnts; do awk -v m=\$m '\$2 == m && \$3 == \"mxfs\" {f = 1} END {exit !f}' /proc/mounts && fuser -vm \$m 2>&1 | awk -v m=\$m 'NR > 1 && \$0 !~ /kernel/ {print \"HOLDER\", m, \$0}'; done; true" 60)
        if grep -qE '^(SHARED_VM|HOLDER)' <<<"$out"; then
            die "$h: something uses an MXFS mount: $(grep -E '^(SHARED_VM|HOLDER)' <<<"$out" | tr '\n' ' ')"
        fi
    done
    if [ -n "${stores// /}" ]; then
        say "Proxmox storage on those mounts: $stores"
        on "$P0" "for s in $stores; do pvesm remove \$s; done; for s in $stores; do pvesm status --storage \$s >/dev/null 2>&1 && echo STORAGE_LEFT \$s; done; echo DONE" 60 | grep -q STORAGE_LEFT \
            && die "the Proxmox storage on an MXFS mount could not be removed"
    fi
    # Stopping a unit unmounts and steps down; one host at a time, so the
    # second sees an ordinary departure of the first.
    for h in "$P1" "$P0"; do
        on "$h" "for r in \$($RESLIST); do systemctl disable --now mxfs-drbd@\$r 2>&1; timeout 60 drbdadm down \$r 2>&1; done; systemctl disable --now mxfs-drbd-guard 2>&1; grep ' mxfs ' /proc/mounts; grep -E '^ *[0-9]+: cs:' /proc/drbd 2>/dev/null; echo STOPPED" 300 | tail -4 | sed "s|^|  $h: |" | tee -a "$EVID/log"
        on "$h" "grep -q ' mxfs ' /proc/mounts && echo STILL_MOUNTED; for r in \$($RESLIST); do drbdadm cstate \$r >/dev/null 2>&1 && echo DRBD_STILL_UP \$r; done; true" 30 | grep -qE 'STILL_MOUNTED|DRBD_STILL_UP' \
            && die "$h: an MXFS mount or DRBD resource is still up after its unit stopped"
    done
    both "set -e
        lvs pve/mxfs >/dev/null 2>&1 && lvremove -y pve/mxfs >/dev/null
        for r in \$($RESLIST); do rm -f /etc/drbd.d/\$r.res; done
        if dpkg -s mxfs >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get purge -y mxfs >/dev/null 2>&1; fi
        rm -rf /etc/mxfs /var/lib/mxfs /usr/share/doc/mxfs
        rm -f /etc/modprobe.d/mxfs.conf /etc/modprobe.d/mxfs.conf.backup /etc/modules-load.d/mxfs.conf /etc/udev/rules.d/60-mxfs-blkid.rules
        rm -f /lib/systemd/system/mxfs-drbd@.service /lib/systemd/system/mxfs-drbd-guard.service
        rm -rf /etc/systemd/system/mxfs-drbd@.service.d /etc/systemd/system/mxfs-drbd-guard.service.d
        systemctl daemon-reload
        for f in /usr/sbin/*mxfs* /usr/share/man/man5/*mxfs* /usr/share/man/man8/*mxfs*; do if [ -e \"\$f\" ] || [ -L \"\$f\" ]; then rm -f \"\$f\"; fi; done
        for d in /usr/src/mxfs-*; do if [ -d \"\$d\" ]; then dkms remove \"mxfs/\${d#/usr/src/mxfs-}\" --all >/dev/null 2>&1 || true; rm -rf \"\$d\"; fi; done
        for m in $mnts; do if [ -d \"\$m\" ]; then rmdir \"\$m\" 2>/dev/null || true; fi; done
        for t in \$(nft list tables 2>/dev/null | awk '\$3 ~ /mxfs/ {print \$2\" \"\$3}' | tr ' ' ':'); do nft delete table \${t%%:*} \${t#*:}; done
        if lsmod | grep -q '^mxfs '; then rmmod mxfs; fi
        find /lib/modules/\$(uname -r) -name 'mxfs.ko*' -delete
        depmod -a
        if [ -d /root/mxfs ]; then rm -rf /root/mxfs.backup; mv /root/mxfs /root/mxfs.backup; fi
        echo TORN_DOWN" 300 || die "teardown failed"
    both "lsmod | grep -c '^mxfs ' ; ls /usr/sbin | grep -c mxfs; ls /etc/mxfs 2>&1 | head -1; lvs pve/mxfs 2>&1 | tail -1; ls /etc/drbd.d; dpkg -s mxfs 2>&1 | head -1" 60
    say "teardown done"
}

guide() {
    local c deb h url t0
    # 1. Install (both nodes)
    c="apt install drbd-utils proxmox-headers-\$(uname -r) ./mxfs_<version>_amd64.deb"; guide_has "$c"
    mkdir -p "$EVID/deb" || die "no package directory"
    if [ "${FROM_TREE:-0}" = 1 ]; then
        say "== guide: docs/drbd-setup.md sections 1-6, with a package built from this working tree ($(cat "$REPO/VERSION"))"
        t0=$(date +%s)
        # built the way release.sh builds it: on the debian12 lab node, each
        # step under that script's own budget
        "$REPO/scripts/vm_package_build.sh" deb "$EVID/deb" > "$EVID/deb/build.log" 2>&1 \
            || die "the package build failed (see $EVID/deb/build.log)"
        rm -f "$EVID"/deb/pve-storage-mxfs_*.deb
        say "   package built in $(( $(date +%s) - t0 ))s on the debian12 lab node"
    else
        say "== guide: docs/drbd-setup.md sections 1-6, with the latest release's package from $REPO_URL"
        url=$(timeout 60 curl -fsSL "https://api.github.com/repos/${REPO_URL#https://github.com/}/releases/latest" \
            | python3 -I -c 'import json, re, sys; print(next(a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if re.fullmatch(r"mxfs_[0-9.]+_amd64\.deb", a["name"])))') \
            || die "could not find the latest release's mxfs package"
        timeout 300 curl -fsSL -o "$EVID/deb/${url##*/}" "$url" || die "could not download $url"
    fi
    deb=$(cd "$EVID/deb" && ls mxfs_*_amd64.deb 2>/dev/null)
    [ "$(wc -w <<<"$deb")" = 1 ] || die "expected one mxfs package, found: $deb"
    for h in "$P0" "$P1"; do
        timeout 120 "$SSHP" "$h" SCP "$EVID/deb/$deb" "/root/$deb" </dev/null >/dev/null 2>&1 \
            || die "$h: could not copy $deb"
    done
    say "1. install: apt install drbd-utils, the headers and $deb (both nodes)"
    both "cd /root && DEBIAN_FRONTEND=noninteractive apt install -y drbd-utils proxmox-headers-\$(uname -r) ./$deb > /root/mxfs-apt.log 2>&1; echo APT_RC=\$?; tail -3 /root/mxfs-apt.log; echo version=\$(cat /sys/module/mxfs/version 2>/dev/null) dkms=\$(dkms status mxfs 2>&1 | tr '\n' ' ')" "$BUILD_BUDGET" \
        || die "section 1 failed (see $EVID/host-*.log)"
    for h in "$P0" "$P1"; do
        grep -q 'APT_RC=0' "$EVID/both.$h" || die "$h: section 1's apt install failed (see $EVID/host-$h.log)"
    done
    # 2. A backing device on each node
    c="lvcreate -V 40G -T pve/data -n mxfs"; guide_has "$c"
    local disk0="/dev/pve/mxfs" disk1="/dev/pve/mxfs"
    if [ -n "$BACKING_MODEL" ]; then
        say "2. backing device: a $BACKING_SIZE partition on the disk whose model contains '$BACKING_MODEL' (both nodes)"
        both "set -u
            d=''; for s in /sys/block/sd*; do case \"\$(lsblk -dno MODEL /dev/\${s##*/} 2>/dev/null)\" in *'$BACKING_MODEL'*) d=\"\$d \${s##*/}\" ;; esac; done
            set -- \$d; [ \$# = 1 ] || { echo \"REFUSE: \$# disks match '$BACKING_MODEL':\$d\"; exit 1; }
            dev=/dev/\$1
            rd=\$(lsblk -nrso NAME,TYPE \$(findmnt -n -o SOURCE /) | awk '\$2 == \"disk\" {print \$1}')
            [ \"/dev/\$rd\" != \$dev ] || { echo \"REFUSE: \$dev holds the root filesystem\"; exit 1; }
            lsblk -nro MOUNTPOINT \$dev | grep -q . && { echo \"REFUSE: something on \$dev is mounted\"; exit 1; }
            id=\$(ls /dev/disk/by-id/ | grep -E '^ata-' | grep -v -- '-part' | while read -r n; do [ \"\$(readlink -f /dev/disk/by-id/\$n)\" = \$dev ] && echo \$n; done | head -1)
            [ -n \"\$id\" ] || { echo \"REFUSE: no by-id name for \$dev\"; exit 1; }
            # wipefs takes both GPT copies; sgdisk -q with -Z first reported
            # success here and left no partition table on the disk
            wipefs -a -q \$dev && blkdiscard -f \$dev 2>/dev/null || { echo \"REFUSE: could not wipe \$dev\"; exit 1; }
            sgdisk -n 1:0:+$BACKING_SIZE -c 1:mxfs \$dev > /tmp/mxfs-sgdisk.out 2>&1 || { echo \"REFUSE: sgdisk: \$(tail -1 /tmp/mxfs-sgdisk.out)\"; exit 1; }
            blockdev --rereadpt \$dev && udevadm settle
            p=/dev/disk/by-id/\$id-part1
            # settle can return before the re-read's events are queued
            for i in \$(seq 1 20); do [ -b \$p ] && break; sleep 0.5; udevadm settle; done
            [ -b \$p ] || { echo \"REFUSE: \$p did not appear\"; exit 1; }
            echo BACKING=\$p size=\$(blockdev --getsize64 \$p)" 120 || die "section 2 failed"
        disk0=$(sed -n 's/.*BACKING=\([^ ]*\) .*/\1/p' "$EVID/both.$P0"); disk1=$(sed -n 's/.*BACKING=\([^ ]*\) .*/\1/p' "$EVID/both.$P1")
        [ -n "$disk0" ] && [ -n "$disk1" ] || die "section 2: no backing partition reported"
        [ "$(sed -n 's/.*size=//p' "$EVID/both.$P0")" = "$(sed -n 's/.*size=//p' "$EVID/both.$P1")" ] \
            || die "section 2: the two partitions differ in size"
    else
        c=${c/40G/$LV_SIZE}
        say "2. backing device: $c (both nodes)"
        both "$c && lvs --noheadings -o lv_name,lv_size,pool_lv pve/mxfs" 60 || die "section 2 failed"
    fi
    # 3. The DRBD resource, from the guide's own text
    local res n0 n1
    res=$(awk '/^## 3\./ {s = 1} s && /^```/ {if (in_block) exit; in_block = 1; next} in_block {print}' "$GUIDE")
    grep -q '^resource mxfs {' <<<"$res" && grep -q 'ping-int' <<<"$res" || die "could not take the resource file from section 3 of the guide"
    grep -q '^    on pve1 {' <<<"$res" && grep -q '^    on pve2 {' <<<"$res" && grep -q '192\.168\.1\.80:7788' <<<"$res" && grep -q '192\.168\.1\.81:7788' <<<"$res" \
        || die "section 3 of the guide no longer names pve1/pve2 at 192.168.1.80/.81"
    n0=$(on "$P0" hostname 20); n1=$(on "$P1" hostname 20)
    [ -n "$n0" ] && [ -n "$n1" ] || die "could not read the hosts' names"
    if [ "$n0 $P0 $n1 $P1" != "pve1 192.168.1.80 pve2 192.168.1.81" ]; then
        res=$(sed -e "s/^    on pve1 {/    on $n0 {/" -e "s/^    on pve2 {/    on $n1 {/" \
                  -e "s/192\.168\.1\.80:7788/$P0:7788/" -e "s/192\.168\.1\.81:7788/$P1:7788/" <<<"$res")
        say "3. the guide's resource with $n0 ($P0) for pve1 and $n1 ($P1) for pve2"
    fi
    if [ -n "$BACKING_MODEL" ]; then
        grep -q '^        disk      /dev/pve/mxfs;$' <<<"$res" || die "section 3 of the guide no longer names /dev/pve/mxfs as the disk"
        res=$(awk -v n0="$n0" -v n1="$n1" -v d0="$disk0" -v d1="$disk1" '
            $1 == "on" {h = $2}
            $1 == "disk" && $2 == "/dev/pve/mxfs;" {sub(/\/dev\/pve\/mxfs;/, (h == n0 ? d0 : h == n1 ? d1 : "UNKNOWN_HOST") ";")}
            {print}' <<<"$res")
        grep -q UNKNOWN_HOST <<<"$res" && die "section 3: a host block names neither $n0 nor $n1"
        say "3. the guide's resource with disk $disk0 on $n0 and $disk1 on $n1"
    fi
    echo "$res" > "$EVID/mxfs.res"
    say "3. resource file: $(wc -l <<<"$res") lines from the guide's section 3 (both nodes)"
    both "echo $(base64 -w0 <<<"$res") | base64 -d > /etc/drbd.d/mxfs.res && drbdadm dump mxfs > /dev/null && echo RES_OK" 30 || die "section 3 failed"
    # 4. First synchronisation
    for c in "drbdadm create-md mxfs && drbdadm up mxfs" "drbdadm primary --force mxfs" "drbdadm primary mxfs"; do guide_has "$c"; done
    say "4. first synchronisation: create-md + up (both), primary --force (node A = $P0)"
    both "drbdadm create-md mxfs < /dev/null && drbdadm up mxfs && echo UP" 120 || die "section 4 create-md/up failed"
    on "$P0" "drbdadm primary --force mxfs && echo PRIMARY" 60 | grep -q PRIMARY || die "section 4: primary --force on $P0 failed"
    finish
}

finish() {
    local c t0 st
    for c in "drbdadm primary mxfs" "mkfs.mxfs /dev/drbd0"; do guide_has "$c"; done
    say "4. waiting for the first sync to reach UpToDate/UpToDate (budget ${SYNC_BUDGET}s)"
    t0=$(date +%s)
    while :; do
        st=$(on "$P1" "grep -E '^ *0:' /proc/drbd; grep -oE 'sync.ed: *[0-9.]+%' /proc/drbd" 20 | tr '\n' ' ')
        grep -q 'ds:UpToDate/UpToDate' <<<"$st" && break
        [ $(( $(date +%s) - t0 )) -ge "$SYNC_BUDGET" ] && die "the first sync did not finish within ${SYNC_BUDGET}s: $st"
        sleep 20
    done
    say "   first sync done after $(( $(date +%s) - t0 ))s"
    on "$P1" "drbdadm primary mxfs && echo PRIMARY" 60 | grep -q PRIMARY || die "section 4: primary on $P1 failed"
    # 5. Format, once
    c="mkfs.mxfs /dev/drbd0"; guide_has "$c"
    say "5. format: $c (node A = $P0)"
    on "$P0" "$c < /dev/null 2>&1 | tail -4; echo MKFS_RC=\${PIPESTATUS[0]}" 300 | tee -a "$EVID/log" | grep -q 'MKFS_RC=0' || die "section 5 failed"
    # 6. Mount at boot
    for c in "echo MOUNTPOINT=/mnt/shared > /etc/mxfs/drbd-mxfs.conf" "systemctl enable --now mxfs-drbd@mxfs" \
             "pvesm add dir shared --path /mnt/shared --shared 1 --is_mountpoint yes"; do guide_has "$c"; done
    say "6. mount at boot: the conf file and enable --now (both nodes), the Proxmox storage (once)"
    t0=$(date +%s)
    both "echo MOUNTPOINT=/mnt/shared > /etc/mxfs/drbd-mxfs.conf && systemctl enable --now mxfs-drbd@mxfs; echo ENABLE_RC=\$?" "$MOUNT_BUDGET" || die "section 6: enable --now failed"
    say "   enable --now returned on both after $(( $(date +%s) - t0 ))s"
    on "$P0" "pvesm add dir shared --path /mnt/shared --shared 1 --is_mountpoint yes \\
      --content images,iso,vztmpl,backup,snippets && echo STORAGE_ADDED" 60 | grep -q STORAGE_ADDED || die "section 6: pvesm add failed"
    say "guide done"
}

verify() {
    say "== verify"
    local h s bad=0 builds=""
    for h in "$P0" "$P1"; do
        s=$(on "$h" "echo \"name=\$(hostname) mnt=\$(awk '\$2 == \"/mnt/shared\" && \$3 == \"mxfs\" {print \$2}' /proc/mounts | head -1) role=\$(drbdadm role mxfs 2>/dev/null) cs=\$(drbdadm cstate mxfs 2>/dev/null) ds=\$(drbdadm dstate mxfs 2>/dev/null) unit=\$(systemctl is-active mxfs-drbd@mxfs) guard=\$(systemctl is-active mxfs-drbd-guard) enabled=\$(systemctl is-enabled mxfs-drbd@mxfs) build=\$(cat /sys/module/mxfs/srcversion 2>/dev/null) ping_int=\$(drbdsetup show mxfs | awk '\$1 == \"ping-int\" {gsub(\";\", \"\"); print \$2}') storage=\$(pvesm status 2>/dev/null | awk '\$1 == \"shared\" {print \$3}')\"" 30)
        say "$h: $s"
        case "$s" in
            *"mnt=/mnt/shared role=Primary/Primary cs=Connected ds=UpToDate/UpToDate unit=active guard=active enabled=enabled build="*" ping_int=3 storage=active"*) ;;
            *) bad=1 ;;
        esac
        builds="$builds $(sed -n 's/.*build=\([^ ]*\).*/\1/p' <<<"$s")"
    done
    # drbdsetup show prints only what differs from DRBD's defaults, so the
    # configured value above is what the next connection takes; the live
    # connection was made by `drbdadm up` from the same file.
    [ "$(tr ' ' '\n' <<<"$builds" | sort -u | grep -c .)" = 1 ] || { say "the hosts run different builds:$builds"; bad=1; }
    [ "$bad" = 0 ] || die "the pair is not what the guide promises"
    say "RESULT: PASS — both hosts set up from the guide, mounted, Primary/Primary, UpToDate"
}

for ph in "${PHASES[@]}"; do
    case "$ph" in
        teardown|guide|finish|verify) "$ph" ;;
        *) die "unknown phase $ph" ;;
    esac
done
say "evidence: $EVID"
