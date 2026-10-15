#!/bin/bash
#
# vsphere_poweroff_quiesce.sh — does a vCenter power-off end a VM's writes to
# a shared disk by the time vCenter reports the VM off?
#
# fence=vcenter (docs/shared-disk-attachment.md) certifies a victim's slice
# for replay on exactly that report, so this is the measurement the method
# rests on.  It is taken the way the fence takes it:
#
#   the victim  writes 4 KiB O_DIRECT blocks as fast as WRITERS threads can,
#               round-robin over a RING of blocks on the raw shared disk, each
#               block carrying a sequence number that only grows
#   the survivor reads the whole ring O_DIRECT in a loop, tracking the highest
#               sequence number on the disk, then powers the victim off itself
#               through vCenter (pyVmomi, /etc/mxfs/vcenter.conf, as the fence
#               helper does), notes when the task reports success, and goes on
#               reading for WATCH_S seconds
#   verdict     the highest sequence number seen by a read pass that STARTED
#               after vCenter reported the VM off is the baseline; any later
#               pass that sees a higher one is a write that landed after the
#               report: QUIESCE_FAIL
#
# Both nodes must have the shared disk unmounted: the ring overwrites part of
# it (the last RING_MB of the disk), so format it again afterwards.  The
# victim is left powered off; power it on with tools/node_power.sh start.
#
# Usage: tests/vsphere_poweroff_quiesce.sh [<survivor> <victim>] [attempts]
# Env:   SHARED_WWID, WRITERS (8), RING_MB (64), RUN_S (6, writing before the
#        power-off), WATCH_S (20), OUT
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SSH="$HERE/tools/mxfs_sshpass.sh"
POWER="$HERE/tools/node_power.sh"
S=${1:-vstest1}; V=${2:-vstest2}; ATTEMPTS=${3:-1}
SHARED_WWID=${SHARED_WWID:-naa.6000c2952d4cf17b9c6f50c882f9dda9}
WRITERS=${WRITERS:-8}; RING_MB=${RING_MB:-64}; RUN_S=${RUN_S:-6}; WATCH_S=${WATCH_S:-20}
OUT=${OUT:-$HERE/tests/evidence/vsphere/quiesce-$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$OUT"
gssh() { local t=$1 n=$2; shift 2; timeout "$t" "$SSH" "$n.vm.localdomain" "$@" 2>&1 | grep -avE '^Warning: Permanently|^Unauthorized access|^If you are not|^$'; }
DEV_OF='for d in /sys/block/sd*; do [ "$(cat $d/device/wwid 2>/dev/null)" = "@WWID@" ] && { echo /dev/${d##*/}; exit 0; }; done; exit 1'

WRITER='
import os, struct, sys, threading, time
dev, ring_mb, nthreads, run_s = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
fd = os.open(dev, os.O_RDWR | os.O_DIRECT)
size = os.lseek(fd, 0, os.SEEK_END)
nblk = ring_mb * 256
base = size - ring_mb * 1024 * 1024
lock = threading.Lock(); seq = [0]
def w():
    import mmap
    buf = mmap.mmap(-1, 4096)
    while True:
        with lock:
            seq[0] += 1; s = seq[0]
        buf.seek(0); buf.write(struct.pack("<QQ", 0x4d58515549455343, s))
        os.pwritev(fd, [buf], base + (s % nblk) * 4096)
for _ in range(nthreads):
    threading.Thread(target=w, daemon=True).start()
print("WRITING base=%d nblk=%d" % (base, nblk), flush=True)
while True:
    time.sleep(1); print("SEQ %d" % seq[0], flush=True)
'

WATCHER='
import mmap, os, ssl, struct, sys, time
dev, ring_mb, vm, run_s, watch_s = sys.argv[1], int(sys.argv[2]), sys.argv[3], float(sys.argv[4]), float(sys.argv[5])
fd = os.open(dev, os.O_RDONLY | os.O_DIRECT)
size = os.lseek(fd, 0, os.SEEK_END)
base = size - ring_mb * 1024 * 1024
buf = mmap.mmap(-1, ring_mb * 1024 * 1024)
def scan():
    os.preadv(fd, [buf], base)
    hi = 0
    for off in range(0, len(buf), 4096):
        m, s = struct.unpack_from("<QQ", buf, off)
        if m == 0x4d58515549455343 and s > hi: hi = s
    return hi
conf = {}
for l in open("/etc/mxfs/vcenter.conf"):
    if "=" in l: k, v = l.strip().split("=", 1); conf[k] = v
pw = open(conf["password_file"]).read().strip()
from pyVim.connect import SmartConnect
from pyVmomi import vim
si = SmartConnect(host=conf["server"], user=conf["user"], pwd=pw, sslContext=ssl._create_unverified_context())
c = si.RetrieveContent()
view = c.viewManager.CreateContainerView(c.rootFolder, [vim.VirtualMachine], True)
target = [x for x in view.view if x.name == vm][0]
t0 = time.monotonic(); hi = 0; passes = 0
while time.monotonic() - t0 < run_s:
    hi = max(hi, scan()); passes += 1
print("BEFORE hi=%d passes=%d" % (hi, passes), flush=True)
t_issue = time.monotonic()
task = target.PowerOffVM_Task()
while str(task.info.state) in ("queued", "running"):
    hi = max(hi, scan())
t_off = time.monotonic()
print("POWEROFF state=%s task_s=%.3f power=%s hi_at_report=%d" % (task.info.state, t_off - t_issue, target.runtime.powerState, hi), flush=True)
base_hi = scan(); passes = 0; late = []
while time.monotonic() - t_off < watch_s:
    h = scan(); passes += 1
    if h > base_hi:
        late.append((round(time.monotonic() - t_off, 3), h)); base_hi = h
print("AFTER baseline_pass_hi=%d passes=%d late_landings=%d first=%s" % (base_hi, passes, len(late), late[:5]), flush=True)
print("QUIESCE_%s" % ("FAIL" if late else "OK"), flush=True)
'

for t in $(seq 1 "$ATTEMPTS"); do
    echo "=== attempt $t survivor=$S victim=$V writers=$WRITERS ring=${RING_MB}MB"
    [ "$(gssh 10 "$V" 'echo alive')" = alive ] || {
        "$POWER" start "$V" >/dev/null 2>&1
        for i in $(seq 1 36); do [ "$(gssh 10 "$V" 'echo alive')" = alive ] && break; sleep 5; done; }
    for n in "$S" "$V"; do
        [ -z "$(gssh 10 "$n" "grep -c ' /mnt/shared mxfs' /proc/mounts | grep -v '^0$'")" ] || { echo "$n has the shared disk mounted"; exit 2; }
    done
    sd=$(gssh 20 "$S" "${DEV_OF//@WWID@/$SHARED_WWID}" | tail -1)
    vd=$(gssh 20 "$V" "${DEV_OF//@WWID@/$SHARED_WWID}" | tail -1)
    case "$sd$vd" in /dev/sd*/dev/sd*) ;; *) echo "shared disk not found ($S='$sd' $V='$vd')"; exit 2;; esac
    # the writer runs until the VM dies; its ssh is killed afterwards
    timeout $((RUN_S + WATCH_S + 90)) "$SSH" "$V.vm.localdomain" "python3 -c '$WRITER' $vd $RING_MB $WRITERS $RUN_S" > "$OUT/writer_$t.txt" 2>&1 &
    wp=$!
    sleep 3
    gssh $((RUN_S + WATCH_S + 60)) "$S" "python3 -c '$WATCHER' $sd $RING_MB $V $RUN_S $WATCH_S" | tee "$OUT/watcher_$t.txt" | sed 's/^/  /'
    kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
    echo "  victim's last report: $(grep -a '^SEQ' "$OUT/writer_$t.txt" | tail -1)"
done
echo "RESULT attempts=$ATTEMPTS ok=$(cat "$OUT"/watcher_*.txt | grep -c QUIESCE_OK) fail=$(cat "$OUT"/watcher_*.txt | grep -c QUIESCE_FAIL) evidence=$OUT"
