#!/usr/bin/env python3
"""Issue #19 (2026-11-16): what a Klipper status answer costs, per object.

Read-only. Talks to Klippy's own API socket (the one Moonraker uses) and only
sends "objects/list" and "objects/query" - the same requests Mainsail and the
screen make all the time. Nothing is subscribed, set or run.

For every object it times REPEAT queries of that object alone and prints the
fastest and the median round trip (ms) and the answer's size, the most
expensive first; then the same for ALL objects in one query (what one
subscription update of a client that subscribed to everything costs).
The fastest of the repeats is the cost, the rest is scheduling noise.
"""
import json
import os
import socket
import sys
import time

REPEAT = 7


def klippy_socket():
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            with open("/proc/%s/cmdline" % pid, "rb") as fh:
                args = fh.read().split(b"\0")
        except OSError:
            continue
        if any(a.endswith(b"klippy.py") for a in args) and b"-a" in args:
            return args[args.index(b"-a") + 1].decode()
    return "/opt/printer_data/comms/klippy.sock"


class Api:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(10)
        self.s.connect(path)
        self.buf = b""
        self.n = 0

    def call(self, method, params):
        self.n += 1
        msg = json.dumps({"id": self.n, "method": method, "params": params}).encode() + b"\x03"
        t0 = time.monotonic()
        self.s.sendall(msg)
        while True:
            while b"\x03" not in self.buf:
                chunk = self.s.recv(65536)
                if not chunk:
                    raise OSError("klippy closed the socket")
                self.buf += chunk
            raw, _, self.buf = self.buf.partition(b"\x03")
            reply = json.loads(raw)
            if reply.get("id") == self.n:
                return (time.monotonic() - t0) * 1000.0, len(raw), reply


def timed(api, objs):
    times, size = [], 0
    for _ in range(REPEAT):
        ms, size, reply = api.call("objects/query", {"objects": {o: None for o in objs}})
        if "error" in reply:
            return None, None, size, reply["error"].get("message", "?")
        times.append(ms)
    times.sort()
    return times[0], times[len(times) // 2], size, None


def main():
    path = klippy_socket()
    api = Api(path)
    _, _, info = api.call("info", {})
    print("socket=%s state=%s" % (path, info.get("result", {}).get("state")))
    _, _, lst = api.call("objects/list", {})
    objs = lst["result"]["objects"]
    base = sorted(api.call("info", {})[0] for _ in range(REPEAT))
    print("objects=%d baseline_info_ms min=%.1f median=%.1f" % (len(objs), base[0], base[len(base) // 2]))
    rows = []
    for o in objs:
        mn, md, size, err = timed(api, [o])
        if err:
            print("ERROR %s: %s" % (o, err))
            continue
        rows.append((mn, md, size, o))
    rows.sort(reverse=True)
    print("== per object, most expensive first (min_ms median_ms bytes name)")
    for mn, md, size, o in rows[:40]:
        print("%7.1f %7.1f %8d %s" % (mn, md, size, o))
    print("sum_of_min_ms=%.1f (minus %d x baseline %.1f = %.1f)" % (
        sum(r[0] for r in rows), len(rows), base[0], sum(r[0] for r in rows) - len(rows) * base[0]))
    mn, md, size, err = timed(api, objs)
    print("ALL objects in one query: min_ms=%s median_ms=%s bytes=%s %s" % (
        "%.1f" % mn if mn is not None else "-", "%.1f" % md if md is not None else "-", size, err or ""))
    groups = {}
    for o in objs:
        groups.setdefault(o.split(" ")[0], []).append(o)
    print("== per object type, all of that type in one query (min_ms count type)")
    out = []
    for g, members in groups.items():
        if len(members) < 2:
            continue
        mn, _, _, err = timed(api, members)
        if not err:
            out.append((mn, len(members), g))
    for mn, n, g in sorted(out, reverse=True)[:15]:
        print("%7.1f %4d %s" % (mn, n, g))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # report, never hang the capture
        print("QSTATUS_FAILED %s: %s" % (type(e).__name__, e))
        sys.exit(1)
