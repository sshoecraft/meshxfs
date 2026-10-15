# vmss_cpu_state.py — per-CPU scheduler/IPI/timer state from a guest memory image.
#
# Usage:
#   VMLINUX=<debug vmlinux> CORE=<vmss2core -N6 core> [NCPU=4] \
#       gdb -batch -q -x tools/vmss_cpu_state.py
#
# What it answers: is a CPU of a frozen guest stranded because a wakeup it was
# sent never arrived?  A remote wakeup or smp_call_function on Linux queues an
# entry on the target CPU's call_single_queue and sends an IPI only when that
# list was EMPTY.  If that one IPI is lost (a hypervisor that drops an interrupt
# to a halted vCPU), the list never drains: every later entry queues behind it
# without an IPI, the queued tasks never run, and if one of them is the CPU's
# ksoftirqd — left in TASK_RUNNING on the list — every irq_exit on that CPU
# leaves softirqs to it, so the CPU's timer wheel stops and every msleep /
# schedule_timeout sleeper whose timer is there never wakes.
#
# For each CPU it prints the call_single_queue entries (task for a TTWU entry,
# function for a CSD), the runqueue, ksoftirqd's state, pending softirqs, the
# timer base clock against jiffies, and the idle task's NEED_RESCHED / POLLING
# flags.  A non-empty queue on a CPU sitting idle with NEED_RESCHED clear is
# the lost-IPI signature.
#
# The image needs no VMCOREINFO: the KASLR slide is found by scanning for
# linux_banner, and per-CPU symbols (zero-based on x86_64) are resolved from
# `nm` plus __per_cpu_offset[] read out of the image, so gdb's relocation of
# the per-cpu section never matters.  Read-only on the image.

import os
import subprocess

import gdb

vml = os.environ["VMLINUX"]
core = os.environ["CORE"]
ncpu = int(os.environ.get("NCPU", "4"))

nm = {}
out = subprocess.run(["nm", vml], capture_output=True, text=True, check=True).stdout
for line in out.splitlines():
    p = line.split()
    if len(p) == 3:
        nm.setdefault(p[2], int(p[0], 16))

gdb.execute("core-file " + core, to_string=True)
inf = gdb.selected_inferior()


def rd(addr, n):
    return bytes(inf.read_memory(addr, n))


def u64(addr):
    return int.from_bytes(rd(addr, 8), "little")


def u32(addr):
    return int.from_bytes(rd(addr, 4), "little")


slide = None
for s in range(0, 0x40000000, 0x200000):
    try:
        if rd(nm["linux_banner"] + s, 13) == b"Linux version":
            slide = s
            break
    except gdb.MemoryError:
        pass
if slide is None:
    raise SystemExit("linux_banner not found at any 2 MiB slide")
print("KASLR slide %#x" % slide)
print("banner:", rd(nm["linux_banner"] + slide, 100).split(b"\n")[0].decode(errors="replace"))
gdb.execute("add-symbol-file %s -o %#x" % (vml, slide), to_string=True)


def typed(addr, tname):
    return gdb.Value(addr).cast(gdb.lookup_type(tname).pointer()).dereference()


def offsetof(tname, field):
    return int(gdb.parse_and_eval("(unsigned long)&((%s *)0)->%s" % (tname, field)))


def sym(addr):
    s = gdb.execute("info symbol %#x" % addr, to_string=True).strip()
    return s.split(" in section")[0]


def task_line(t):
    try:
        cpu = int(t["cpu"])
    except gdb.error:
        cpu = int(t["thread_info"]["cpu"])
    return "pid=%d comm=%s state=%#x on_rq=%d on_cpu=%d cpu=%d" % (
        int(t["pid"]), t["comm"].string(), int(t["__state"]),
        int(t["on_rq"]), int(t["on_cpu"]), cpu)


jiffies = u64(nm["jiffies_64"] + slide)
print("jiffies_64 = %d" % jiffies)
if "tick_do_timer_cpu" in nm:
    print("tick_do_timer_cpu = %d" % int.from_bytes(rd(nm["tick_do_timer_cpu"] + slide, 4), "little", signed=True))

# The guest's own clocks at the moment of the image.  xtime_sec is the wall
# clock as of the last timekeeping update and tkr_mono.base the monotonic time
# then; set against the time the image was taken (the .vmsn's timestamp), a
# guest whose timekeeping stopped or jumped shows it here.
try:
    tkc = gdb.parse_and_eval("tk_core")
    t = tkc["timekeeper"]
    print("timekeeper: xtime_sec=%d tkr_mono.base=%.3f s tkr_raw.base=%.3f s offs_boot=%.3f s" % (
        int(t["xtime_sec"]), int(t["tkr_mono"]["base"]) / 1e9,
        int(t["tkr_raw"]["base"]) / 1e9, int(t["offs_boot"]) / 1e9))
    print("timekeeper: tkr_mono.cycle_last=%d clock=%s" % (
        int(t["tkr_mono"]["cycle_last"]), sym(int(t["tkr_mono"]["clock"]))))
except gdb.error as e:
    print("timekeeper: unreadable (%s)" % e)

wake_off = offsetof("struct task_struct", "wake_entry")
TIF_NEED_RESCHED, TIF_POLLING_NRFLAG = 3, 21
CSD_TYPE = {0x00: "ASYNC", 0x10: "SYNC", 0x20: "IRQ_WORK", 0x30: "TTWU"}

for c in range(ncpu):
    off = u64(nm["__per_cpu_offset"] + slide + 8 * c)
    print("\n===== CPU %d (per_cpu_offset %#x)" % (c, off))

    rq = typed(off + nm["runqueues"], "struct rq")
    idle_flags = int(rq["idle"]["thread_info"]["flags"])
    print("rq: nr_running=%d curr=%s ttwu_pending=%s idle.NEED_RESCHED=%d idle.POLLING=%d" % (
        int(rq["nr_running"]), rq["curr"]["comm"].string(),
        rq["ttwu_pending"] if "ttwu_pending" in [f.name for f in rq.type.fields()] else "n/a",
        (idle_flags >> TIF_NEED_RESCHED) & 1, (idle_flags >> TIF_POLLING_NRFLAG) & 1))
    curr_flags = int(rq["curr"]["thread_info"]["flags"])
    print("curr.NEED_RESCHED=%d" % ((curr_flags >> TIF_NEED_RESCHED) & 1))

    head = typed(off + nm["call_single_queue"], "struct llist_head")
    node = int(head["first"])
    n = 0
    print("call_single_queue.first = %#x" % node)
    while node and n < 64:
        csn = typed(node, "struct __call_single_node")
        flags = int(csn["u_flags"])
        kind = CSD_TYPE.get(flags & 0xF0, "type%#x" % (flags & 0xF0))
        if kind == "TTWU":
            print("  [%d] TTWU %s" % (n, task_line(typed(node - wake_off, "struct task_struct"))))
        else:
            csd = typed(node, "struct __call_single_data")
            print("  [%d] %s func=%s flags=%#x" % (n, kind, sym(int(csd["func"])), flags))
        node = int(csn["llist"]["next"])
        n += 1

    ksd = u64(off + nm["ksoftirqd"])
    if ksd:
        print("ksoftirqd: %s" % task_line(typed(ksd, "struct task_struct")))
    if "__softirq_pending" in nm:
        print("softirq_pending = %#x" % u32(off + nm["__softirq_pending"]))
    elif "irq_stat" in nm:
        st = typed(off + nm["irq_stat"], "irq_cpustat_t")
        try:
            print("softirq_pending = %#x" % int(st["__softirq_pending"]))
        except gdb.error:
            pass

    hb = typed(off + nm["hrtimer_bases"], "struct hrtimer_cpu_base")
    ts = typed(off + nm["tick_cpu_sched"], "struct tick_sched")
    fields = [f.name for f in ts.type.fields()]
    print("hrtimer: expires_next=%.3f s in_hrtirq=%d hang_detected=%d nr_events=%d nr_hangs=%d max_hang_time=%d ns" % (
        int(hb["expires_next"]) / 1e9, int(hb["in_hrtirq"]), int(hb["hang_detected"]),
        int(hb["nr_events"]), int(hb["nr_hangs"]), int(hb["max_hang_time"])))
    print("tick: last_tick=%.3f s tick_stopped=%s idle_active=%s last_jiffies=%d next_tick=%.3f idle_calls=%d idle_sleeps=%d" % (
        int(ts["last_tick"]) / 1e9,
        int(ts["tick_stopped"]) if "tick_stopped" in fields else "?",
        int(ts["idle_active"]) if "idle_active" in fields else "?",
        int(ts["last_jiffies"]), int(ts["next_tick"]) / 1e9,
        int(ts["idle_calls"]), int(ts["idle_sleeps"])))

    base = typed(off + nm["timer_bases"], "struct timer_base")
    print("timer_base[STD]: clk=%d (jiffies-clk=%d) next_expiry=%d is_idle=%d timers_pending=%s running_timer=%#x" % (
        int(base["clk"]), jiffies - int(base["clk"]), int(base["next_expiry"]),
        int(base["is_idle"]),
        base["timers_pending"] if "timers_pending" in [f.name for f in base.type.fields()] else "n/a",
        int(base["running_timer"])))
