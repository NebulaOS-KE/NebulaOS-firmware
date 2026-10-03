#!/usr/bin/env python3
"""HWCAP-ADXL: ADXL345 FIFO overflow count during a resonance test.

Subscribes to Klipper's adxl345/dump_adxl345 endpoint on the API socket
(JSON messages terminated by 0x03) and reports the largest 'overflows'
delta seen. Read-only: it only listens; the test itself (TEST_RESONANCES)
is started separately in an authorised motion session.
"""
import argparse, json, os, socket, sys, time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", default="/opt/printer_data/comms/klippy.sock")
    ap.add_argument("--sensor", default="adxl345")
    ap.add_argument("--seconds", type=int, default=120)
    ap.add_argument("--out", default="/tmp/hwcap/out/adxl_overflows.json")
    a = ap.parse_args()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(a.socket)
    req = {"id": 1, "method": "adxl345/dump_adxl345",
           "params": {"sensor": a.sensor, "response_template": {}}}
    s.sendall(json.dumps(req).encode() + b"\x03")
    s.settimeout(1.0)
    buf, first, last, msgs = b"", None, None, 0
    end = time.monotonic() + a.seconds
    while time.monotonic() < end:
        try:
            d = s.recv(65536)
        except socket.timeout:
            continue
        if not d:
            break
        buf += d
        while b"\x03" in buf:
            m, buf = buf.split(b"\x03", 1)
            try:
                o = json.loads(m).get("params", {})
            except ValueError:
                continue
            if "overflows" in o:
                msgs += 1
                first = o["overflows"] if first is None else first
                last = o["overflows"]
    res = {"messages": msgs, "overflows_delta": (last - first) if first is not None else None}
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w") as f:
        json.dump(res, f, indent=1)
    print("ADXL " + " ".join(f"{k}={v}" for k, v in res.items()))


if __name__ == "__main__":
    sys.exit(main())
