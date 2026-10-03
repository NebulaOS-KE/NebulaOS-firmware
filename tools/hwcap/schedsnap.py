#!/usr/bin/env python3
"""HWCAP-SCHEDSNAP: scheduling policy of every printer-relevant thread.

Reads /proc only (BusyBox has no ps -L). For each /proc/<pid>/task/<tid>:
tid, policy, rt_priority, nice, comm. Also the tty_flip workqueue nice,
kernel.sched_rt_runtime_us and the NebulaOS priority config. Two samples,
--interval seconds apart. JSON to /tmp/hwcap/out/schedsnap.json.
"""
import argparse, gzip, json, os, re, sys, time

KEEP = re.compile(r"^(irq/|ktimers/|irq_work/|rcu|klipper_mcu|python3|moonraker|"
                  r"guppyscreen|ustreamer|nginx|kworker/u|nebulaos|ksoftirqd)")
POLICY = {0: "OTHER", 1: "FIFO", 2: "RR", 3: "BATCH", 5: "IDLE", 6: "DEADLINE"}


def stat_fields(path):
    with open(path) as f:
        s = f.read()
    comm = s[s.index("(") + 1:s.rindex(")")]
    f = s[s.rindex(")") + 2:].split()
    # f[0] is field 3 (state); field N is f[N-3]
    return comm, int(f[16]), int(f[37]), int(f[38]), int(f[36])


def snapshot():
    rows = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        tdir = f"/proc/{pid}/task"
        try:
            tids = os.listdir(tdir)
        except OSError:
            continue
        for tid in tids:
            try:
                comm, nice, rtprio, policy, cpu = stat_fields(f"{tdir}/{tid}/stat")
            except (OSError, ValueError, IndexError):
                continue
            if KEEP.match(comm):
                rows.append({"pid": int(pid), "tid": int(tid), "comm": comm,
                             "policy": POLICY.get(policy, policy), "rtprio": rtprio,
                             "nice": nice, "cpu": cpu})
    return sorted(rows, key=lambda r: (-r["rtprio"], r["comm"]))


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def kconfig():
    try:
        with gzip.open("/proc/config.gz", "rt") as f:
            return [l.strip() for l in f if "NEBULAOS_" in l or "PREEMPT_RT" in l]
    except OSError:
        return []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=float, default=60)
    ap.add_argument("--out", default="/tmp/hwcap/out/schedsnap.json")
    a = ap.parse_args()
    out = {"samples": [], "tty_flip_nice": read("/sys/devices/virtual/workqueue/tty_flip/nice"),
           "sched_rt_runtime_us": read("/proc/sys/kernel/sched_rt_runtime_us"),
           "irq_thread_prio_param": read("/sys/module/kernel/parameters/irq_thread_prio"),
           "kconfig": kconfig()}
    for i in range(2):
        if i:
            time.sleep(a.interval)
        out["samples"].append({"t": time.time(), "threads": snapshot()})
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w") as f:
        json.dump(out, f, indent=1)
    for r in out["samples"][-1]["threads"]:
        print(f'{r["tid"]:>6} {r["policy"]:<5} {r["rtprio"]:>3} {r["nice"]:>4} {r["comm"]}')
    print(f'SCHEDSNAP threads={len(out["samples"][-1]["threads"])} tty_flip_nice={out["tty_flip_nice"]} out={a.out}')


if __name__ == "__main__":
    sys.exit(main())
