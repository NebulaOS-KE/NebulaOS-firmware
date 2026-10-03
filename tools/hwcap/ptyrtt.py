#!/usr/bin/env python3
"""HWCAP-PTYRTT: round trip through a pty pair, the klippy <-> klipper_mcu path.

A forked child echoes on the raw slave; the parent writes --bytes every
--period-ms on the master and timestamps the echo: two tty flip hops, the
same flush_to_ldisc path as the host MCU link. JSON to /tmp/hwcap/out/ptyrtt.json.
"""
import argparse, json, os, select, sys, time, tty


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--period-ms", type=float, default=10)
    ap.add_argument("--bytes", type=int, default=16)
    ap.add_argument("--seconds", type=int, default=600)
    ap.add_argument("--out", default="/tmp/hwcap/out/ptyrtt.json")
    a = ap.parse_args()
    master, slave = os.openpty()
    tty.setraw(master)
    tty.setraw(slave)
    pid = os.fork()
    if pid == 0:
        os.close(master)
        while True:
            d = os.read(slave, 4096)
            if not d:
                os._exit(0)
            os.write(slave, d)
    os.close(slave)
    msg = b"x" * a.bytes
    rtt = []
    end = time.monotonic() + a.seconds
    while time.monotonic() < end:
        t0 = time.monotonic_ns()
        os.write(master, msg)
        got = 0
        while got < a.bytes:
            r, _, _ = select.select([master], [], [], 1.0)
            if not r:
                break
            got += len(os.read(master, 4096))
        rtt.append(time.monotonic_ns() - t0)
        time.sleep(max(0, a.period_ms / 1000 - (time.monotonic_ns() - t0) / 1e9))
    os.kill(pid, 9)
    rtt.sort()
    us = lambda q: rtt[min(len(rtt) - 1, int(len(rtt) * q))] / 1000.0
    res = {"n": len(rtt), "p50_us": us(0.5), "p99_us": us(0.99), "p999_us": us(0.999), "max_us": rtt[-1] / 1000.0}
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w") as f:
        json.dump(res, f, indent=1)
    print("PTYRTT " + " ".join(f"{k}={v}" for k, v in res.items()))


if __name__ == "__main__":
    sys.exit(main())
