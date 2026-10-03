#!/usr/bin/env python3
"""HWCAP-TIMERLAT: emulate klipper_mcu's timer path and measure its latency.

klipper_mcu sleeps in ppoll() with SIGALRM blocked and is woken by a POSIX
CLOCK_MONOTONIC timer (src/linux/timer.c, console.c). This does the same at
the same priority: SCHED_FIFO --prio, mlockall, timer_create(SIGALRM),
absolute timer_settime, ppoll with SIGALRM unblocked; latency = wake time -
programmed expiry. stdlib + ctypes only. JSON to /tmp/hwcap/out/timerlat.json.
"""
import argparse, ctypes, ctypes.util, json, os, signal, sys, time

CLOCK_MONOTONIC = 1
TIMER_ABSTIME = 1
SCHED_FIFO = 1
MCL_CURRENT, MCL_FUTURE = 1, 2


class timespec(ctypes.Structure):
    _fields_ = [("tv_sec", ctypes.c_long), ("tv_nsec", ctypes.c_long)]


class itimerspec(ctypes.Structure):
    _fields_ = [("it_interval", timespec), ("it_value", timespec)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prio", type=int, default=49)
    ap.add_argument("--period-us", type=int, default=1250)
    ap.add_argument("--seconds", type=int, default=600)
    ap.add_argument("--out", default="/tmp/hwcap/out/timerlat.json")
    a = ap.parse_args()
    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    if libc.mlockall(MCL_CURRENT | MCL_FUTURE):
        print("WARNING: mlockall failed errno=%d" % ctypes.get_errno())
    os.sched_setscheduler(0, SCHED_FIFO, os.sched_param(a.prio))
    signal.signal(signal.SIGALRM, lambda *x: None)
    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
    tid = ctypes.c_void_p()
    if libc.timer_create(CLOCK_MONOTONIC, None, ctypes.byref(tid)):
        raise OSError(ctypes.get_errno(), "timer_create")
    unblocked = (ctypes.c_ulong * 32)()   # empty set: SIGALRM deliverable in ppoll
    ppoll = libc.ppoll
    lat = []
    period = a.period_us * 1000
    t = time.clock_gettime_ns(time.CLOCK_MONOTONIC) + period
    end = t + a.seconds * 1_000_000_000
    its = itimerspec()
    while t < end:
        its.it_value.tv_sec, its.it_value.tv_nsec = divmod(t, 1_000_000_000)
        libc.timer_settime(tid, TIMER_ABSTIME, ctypes.byref(its), None)
        ppoll(None, 0, None, unblocked)
        lat.append(time.clock_gettime_ns(time.CLOCK_MONOTONIC) - t)
        t += period
    lat.sort()
    us = lambda q: lat[min(len(lat) - 1, int(len(lat) * q))] / 1000.0
    res = {"n": len(lat), "prio": a.prio, "period_us": a.period_us,
           "p50_us": us(0.5), "p99_us": us(0.99), "p999_us": us(0.999), "max_us": lat[-1] / 1000.0,
           "over_1ms": sum(x > 1_000_000 for x in lat), "over_5ms": sum(x > 5_000_000 for x in lat),
           "over_8ms": sum(x > 8_000_000 for x in lat)}
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w") as f:
        json.dump(res, f, indent=1)
    print("TIMERLAT " + " ".join(f"{k}={v}" for k, v in res.items()))


if __name__ == "__main__":
    sys.exit(main())
