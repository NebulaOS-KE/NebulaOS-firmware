#!/usr/bin/env python3
"""HWCAP-KDUTY: per-thread CPU duty of a process (or of threads named --comm).

Samples utime+stime (clock ticks, HZ=100 here) of every matching TID at --hz
and reports D1 (max CPU-seconds per second over 1 s windows), D100 (max ticks
in a 100 ms window, all threads) and L (longest run of 100 ms windows in which
one thread was busy every tick). JSON to /tmp/hwcap/out/kduty.json.
"""
import argparse, json, os, sys, time


def ticks(path):
    with open(path) as f:
        s = f.read()
    f = s[s.rindex(")") + 2:].split()
    return int(f[11]) + int(f[12])


def threads(pid, comm):
    out = {}
    pids = [pid] if pid else [p for p in os.listdir("/proc") if p.isdigit()]
    for p in pids:
        try:
            for t in os.listdir(f"/proc/{p}/task"):
                path = f"/proc/{p}/task/{t}/stat"
                if comm:
                    with open(f"/proc/{p}/task/{t}/comm") as f:
                        if not f.read().startswith(comm):
                            continue
                out[t] = path
        except OSError:
            continue
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pid")
    ap.add_argument("--comm")
    ap.add_argument("--hz", type=float, default=10)
    ap.add_argument("--seconds", type=int, default=1800)
    ap.add_argument("--out", default="/tmp/hwcap/out/kduty.json")
    a = ap.parse_args()
    clk = os.sysconf("SC_CLK_TCK")
    prev, samples = {}, []
    end = time.monotonic() + a.seconds
    while time.monotonic() < end:
        cur = {}
        for t, path in threads(a.pid, a.comm).items():
            try:
                cur[t] = ticks(path)
            except OSError:
                pass
        samples.append({t: cur[t] - prev.get(t, cur[t]) for t in cur})
        prev = cur
        time.sleep(1 / a.hz)
    per = int(a.hz / 10) or 1
    win100 = [sum(sum(s.values()) for s in samples[i:i + per]) for i in range(0, len(samples), per)]
    win1s = [sum(sum(s.values()) for s in samples[i:i + int(a.hz)]) / clk for i in range(0, len(samples), int(a.hz))]
    full = clk / 10
    run = best = 0
    for i in range(0, len(samples), per):
        busy = {}
        for s in samples[i:i + per]:
            for t, v in s.items():
                busy[t] = busy.get(t, 0) + v
        run = run + 1 if busy and max(busy.values()) >= full else 0
        best = max(best, run)
    totals = {}
    for s in samples:
        for t, v in s.items():
            totals[t] = totals.get(t, 0) + v
    res = {"D1": max(win1s or [0]), "D100": max(win100 or [0]), "L": best,
           "per_tid_ticks": totals, "hz": a.hz, "clk_tck": clk}
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w") as f:
        json.dump(res, f, indent=1)
    print(f'KDUTY D1={res["D1"]:.2f} D100={res["D100"]} L={res["L"]} threads={len(totals)}')


if __name__ == "__main__":
    sys.exit(main())
