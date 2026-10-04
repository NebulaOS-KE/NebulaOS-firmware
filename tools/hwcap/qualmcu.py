#!/usr/bin/env python3
"""uart1 / MCU link probe for the uart-fe-probe and mcu-link-bench exercises.

Runs on the printer while klippy is stopped (the exercise stops and restarts
it). Subcommands:

  snap STEP            print the uart1 counters (tx rx fe oe brk pe) with uptime
  holders              print the pids holding /dev/ttyS1 (empty = free)
  listen BAUD SECONDS  open /dev/ttyS1 at BAUD, read only (nothing is written),
                       report what arrived; then close
  setbaud BAUD         open, set BAUD, close - leaves BAUD as the port's saved
                       setting, as a first open after boot finds 9600
  bench                connect with Klipper's own serialhdl (the MCU guard's
                       run_connected helper) and time read-only commands

The MCU is only ever sent commands in ALLOWED: identify (inside serialhdl's
connect), get_uptime, get_clock, debug_nop, debug_ping. None of them touches a
pin, a stepper, a heater or the MCU configuration.
"""

import glob
import os
import sys
import termios
import time

PORT = "/dev/ttyS1"
BAUD = {9600: termios.B9600, 115200: termios.B115200, 230400: termios.B230400}
ALLOWED = ("get_uptime", "get_clock", "debug_nop", "debug_ping")


def uart_counters():
    for path in glob.glob("/proc/tty/driver/*"):
        try:
            with open(path) as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        for line in lines:
            if line.startswith("1: uart:"):
                out = {}
                for tok in line.split():
                    key, _, val = tok.partition(":")
                    if val.isdigit():
                        out[key] = int(val)
                return out
    return {}


def uptime():
    with open("/proc/uptime") as fh:
        return fh.read().split()[0]


def snap(step):
    c = uart_counters()
    print("UART step=%s t=%s tx=%d rx=%d fe=%d oe=%d brk=%d pe=%d"
          % (step, uptime(), c.get("tx", 0), c.get("rx", 0), c.get("fe", 0),
             c.get("oe", 0), c.get("brk", 0), c.get("pe", 0)), flush=True)


def holders():
    target = os.path.realpath(PORT)
    found = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            fds = os.listdir("/proc/%s/fd" % pid)
        except OSError:
            continue
        for fd in fds:
            try:
                if os.path.realpath("/proc/%s/fd/%s" % (pid, fd)) == target:
                    found.append(int(pid))
                    break
            except OSError:
                pass
    return found


def open_at(baud):
    busy = holders()
    if busy:
        sys.exit("PORT_BUSY pids=%s" % busy)
    fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = 0
    a[1] = 0
    a[2] = (a[2] & termios.HUPCL) | termios.CS8 | termios.CREAD | termios.CLOCAL
    a[3] = 0
    a[4] = a[5] = BAUD[baud]
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    return fd


def listen(baud, seconds):
    fd = open_at(baud)
    got = bytearray()
    end = time.monotonic() + seconds
    try:
        while time.monotonic() < end:
            time.sleep(0.05)
            try:
                chunk = os.read(fd, 4096)
            except BlockingIOError:
                chunk = b""
            got.extend(chunk)
    finally:
        os.close(fd)
    print("LISTEN baud=%d seconds=%s bytes=%d first=%s"
          % (baud, seconds, len(got), got[:48].hex()), flush=True)


def setbaud(baud):
    os.close(open_at(baud))
    print("SETBAUD baud=%d" % baud, flush=True)


def _stats(xs):
    xs = sorted(xs)
    n = len(xs)
    return ("n=%d mean=%.3f p50=%.3f p99=%.3f max=%.3f ms"
            % (n, sum(xs) / n, xs[n // 2], xs[min(n - 1, int(n * 0.99))], xs[-1]))


def bench():
    sys.path.insert(0, "/etc/nebulaos")
    import mcu_application_identify as app

    def check(cmd):
        if cmd.split()[0] not in ALLOWED:
            raise RuntimeError("command %r is not allowed in this probe" % cmd)
        return cmd

    def action(sr):
        out = []
        version, _ = sr.get_msgparser().get_version_info()
        out.append("MCU_VERSION=%s" % version)
        out.append("STATS_BEFORE %s" % sr.stats(sr.reactor.monotonic()))
        for cmd, resp, n in (("get_uptime", "uptime", 1000), ("get_clock", "clock", 1000),
                             ("debug_ping data=" + "a5" * 40, "pong", 1000)):
            check(cmd)
            xs = []
            for _ in range(n):
                t0 = time.monotonic()
                sr.send_with_response(cmd, resp)
                xs.append((time.monotonic() - t0) * 1000.0)
            out.append("RTT %s %s" % (cmd.split()[0], _stats(xs)))
        n = 20000
        check("debug_nop")
        t0 = time.monotonic()
        for _ in range(n):
            sr.send("debug_nop")
        sr.send_with_response(check("get_uptime"), "uptime")
        dt = time.monotonic() - t0
        out.append("THROUGHPUT debug_nop n=%d seconds=%.3f per_second=%.0f" % (n, dt, n / dt))
        out.append("STATS_AFTER %s" % sr.stats(sr.reactor.monotonic()))
        return out

    t0 = time.monotonic()
    lines = app.run_connected(PORT, 230400, action, timeout=10.0,
                              klippy_lib_path="/opt/klipper/klippy")
    for line in lines:
        print(line, flush=True)
    print("BENCH_SECONDS=%.1f" % (time.monotonic() - t0), flush=True)


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "snap":
        snap(argv[2])
    elif cmd == "holders":
        print(" ".join(str(p) for p in holders()))
    elif cmd == "listen":
        listen(int(argv[2]), float(argv[3]))
    elif cmd == "setbaud":
        setbaud(int(argv[2]))
    elif cmd == "bench":
        bench()
    else:
        sys.exit("usage: qualmcu.py snap STEP | holders | listen BAUD SECONDS | setbaud BAUD | bench")


if __name__ == "__main__":
    main(sys.argv)
