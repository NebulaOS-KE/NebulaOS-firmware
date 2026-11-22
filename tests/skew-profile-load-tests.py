#!/usr/bin/env python3
"""#31: calibration.cfg loads the skew profile "nebulaos" at Klipper start,
only when printer.cfg holds [skew_correction nebulaos]. Renders the
delayed_gcode body with Jinja2 the way Klipper does (same delimiters)."""
import configparser
import os
import sys

try:
    import jinja2
except ImportError:
    print("SKEW_PROFILE_LOAD_TESTS=SKIP")
    sys.exit(3)

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
CFG = os.path.join(ROOT, "scripts/build/overlay/etc/nebulaos/klipper/calibration.cfg")
fails = 0


def check(name, ok):
    global fails
    print(("PASS: " if ok else "FAIL: ") + name)
    if not ok:
        fails += 1


cp = configparser.RawConfigParser(strict=False, inline_comment_prefixes=("#",))
cp.read(CFG)
sec = "delayed_gcode _NEBULAOS_SKEW_LOAD"
check("section present", cp.has_section(sec))
if cp.has_section(sec):
    check("runs once at start", cp.get(sec, "initial_duration").strip() == "1")
    env = jinja2.Environment("{%", "%}", "{", "}")
    tpl = env.from_string(cp.get(sec, "gcode"))

    def run(config):
        out = tpl.render(printer={"configfile": {"config": config}})
        return [l.strip() for l in out.splitlines() if l.strip()]

    check("loads when the profile is saved",
          run({"skew_correction": {}, "skew_correction nebulaos": {"xy_skew": "0.001"}})
          == ["SKEW_PROFILE LOAD=nebulaos"])
    check("nothing without a saved profile", run({"skew_correction": {}}) == [])
    check("other profile names are not loaded",
          run({"skew_correction my": {"xy_skew": "0.001"}}) == [])

# the bare section stays in machine.cfg (the module itself)
mc = open(os.path.join(ROOT, "scripts/build/overlay/etc/nebulaos/klipper/machine.cfg")).read()
check("[skew_correction] in machine.cfg", "\n[skew_correction]\n" in mc)
sys.exit(1 if fails else 0)
