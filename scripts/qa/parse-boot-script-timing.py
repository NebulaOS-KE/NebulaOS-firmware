#!/usr/bin/env python3
"""BOOT-09: rebuild the per-script boot table from /run/nebulaos-boot-scripts.log.

Input lines (written by the NebulaOS rcS):
  T=<uptime> EV=begin BOOT_ID=<id>
  T=<uptime> EV=start S=<script>
  T=<uptime> EV=end S=<script> RC=<rc> DUR=<s>
  T=<uptime> EV=done

Prints one row per script (start, end, duration, rc), the gap before each
script (time rcS itself spent between scripts), and any anomaly: a script
that never ended (hung, or the boot is still running), a clock that went
backwards, an unknown timestamp. Usage: parse-boot-script-timing.py LOG [--json]
"""

import json
import sys


def parse(lines):
    begin = done = None
    boot_id = None
    rows, open_rows, anomalies = [], {}, []
    last_t = None
    for n, line in enumerate(lines, 1):
        fields = dict(f.split("=", 1) for f in line.split() if "=" in f)
        ev, raw_t = fields.get("EV"), fields.get("T")
        if ev is None or raw_t is None:
            anomalies.append("line %d unparseable: %r" % (n, line.strip()))
            continue
        try:
            t = float(raw_t)
        except ValueError:
            t = None
            anomalies.append("line %d unknown time (T=%s)" % (n, raw_t))
        if t is not None and last_t is not None and t < last_t:
            anomalies.append("line %d time went backwards (%.2f < %.2f)" % (n, t, last_t))
        if t is not None:
            last_t = t
        if ev == "begin":
            begin, boot_id = t, fields.get("BOOT_ID")
        elif ev == "done":
            done = t
        elif ev == "start":
            row = {"script": fields.get("S"), "start": t, "end": None, "dur": None, "rc": None}
            rows.append(row)
            open_rows[row["script"]] = row
        elif ev == "end":
            row = open_rows.pop(fields.get("S"), None)
            if row is None:
                anomalies.append("line %d end without start for %s" % (n, fields.get("S")))
                continue
            row["end"] = t
            row["rc"] = int(fields["RC"]) if fields.get("RC", "").lstrip("-").isdigit() else fields.get("RC")
            try:
                row["dur"] = float(fields.get("DUR"))
            except (TypeError, ValueError):
                row["dur"] = (t - row["start"]) if t is not None and row["start"] is not None else None
    for s in open_rows:
        anomalies.append("%s started but never ended" % s)
    prev_end = begin
    for row in rows:
        row["gap_before"] = (row["start"] - prev_end) if row["start"] is not None and prev_end is not None else None
        prev_end = row["end"] if row["end"] is not None else prev_end
    return {"boot_id": boot_id, "begin": begin, "done": done, "scripts": rows, "anomalies": anomalies}


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    with open(argv[1], encoding="utf-8", errors="replace") as fh:
        result = parse(fh.readlines())
    if "--json" in argv:
        print(json.dumps(result, indent=1))
        return 0
    fmt = lambda v: "?" if v is None else "%.2f" % v
    print("boot_id=%s rcS begin=%s done=%s" % (result["boot_id"], fmt(result["begin"]), fmt(result["done"])))
    print("%-40s %8s %8s %8s %4s %6s" % ("script", "start", "end", "dur", "rc", "gap"))
    for r in result["scripts"]:
        print("%-40s %8s %8s %8s %4s %6s" % (r["script"], fmt(r["start"]), fmt(r["end"]), fmt(r["dur"]),
                                              "?" if r["rc"] is None else r["rc"], fmt(r["gap_before"])))
    for a in result["anomalies"]:
        print("ANOMALY " + a)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
