#!/usr/bin/env python3
"""Live fix verification M1 (2026-10-05): the MCU guard's identify budget.

  snap STEP                         uart1 counters (fe oe rx) with uptime
  holders                           pids holding /dev/ttyS1 (empty = free)
  setbaud BAUD                      leave BAUD as the port's saved rate (as at boot: 9600)
  identify LABEL BAUD PORT [MODDIR] time get_application_identity(port, baud) exactly as
                                    mcu_lifecycle.decide() calls it; MODDIR (a patched
                                    copy) is imported ahead of /etc/nebulaos
Only the identify handshake reaches the MCU (no bootloader path, no other command).
"""
import os
import sys
import termios
import time

PORT = "/dev/ttyS1"
BAUD = {9600: termios.B9600, 115200: termios.B115200, 230400: termios.B230400}


def up():
    with open("/proc/uptime") as fh:
        return fh.read().split()[0]


def snap(step):
    c = {}
    for name in os.listdir("/proc/tty/driver"):
        with open("/proc/tty/driver/" + name) as fh:
            for line in fh:
                if line.startswith("1: uart:"):
                    c = {k: v for k, _, v in (t.partition(":") for t in line.split()) if v.isdigit()}
    print("UART step=%s t=%s rx=%s fe=%s oe=%s" % (step, up(), c.get("rx", 0), c.get("fe", 0), c.get("oe", 0)), flush=True)


def holders():
    target = os.path.realpath(PORT)
    found = []
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            if any(os.path.realpath("/proc/%s/fd/%s" % (pid, fd)) == target for fd in os.listdir("/proc/%s/fd" % pid)):
                found.append(pid)
        except OSError:
            pass
    return found


def setbaud(baud):
    if holders():
        sys.exit("PORT_BUSY")
    fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[4] = a[5] = BAUD[baud]
    termios.tcsetattr(fd, termios.TCSANOW, a)
    os.close(fd)


def identify(label, baud, port, moddir=None):
    t0 = time.monotonic()
    sys.path.insert(0, "/etc/nebulaos")
    if moddir:
        sys.path.insert(0, moddir)
    import mcu_application_identify as app
    t1 = time.monotonic()
    try:
        version, _ = app.get_application_identity(port, baud)
        out = "OK version=%s" % version
    except Exception as e:  # noqa: BLE001 - the outcome is the measurement
        out = "ERROR %s" % str(e).split(":")[0]
    t2 = time.monotonic()
    print("IDENTIFY label=%s baud=%d port=%s module=%s import_ms=%d identify_ms=%d %s"
          % (label, baud, port, app.__file__, (t1 - t0) * 1000, (t2 - t1) * 1000, out), flush=True)


if __name__ == "__main__":
    a = sys.argv
    if a[1] == "snap":
        snap(a[2])
    elif a[1] == "holders":
        print(" ".join(holders()))
    elif a[1] == "setbaud":
        setbaud(int(a[2]))
    elif a[1] == "identify":
        identify(a[2], int(a[3]), a[4], a[5] if len(a) > 5 else None)
