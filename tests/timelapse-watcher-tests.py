#!/usr/bin/env python3
# Timelapse (2026-10-31): camera.cfg's layer watcher. START_PRINT starts it,
# END_PRINT/CANCEL_PRINT stop it; once a second it takes a picture
# (TIMELAPSE_TAKE_FRAME, upstream moonraker-timelapse) when the nozzle height
# rose and held for a second - a new layer, not a Z-hop.
#
# The delayed_gcode template is rendered with Jinja2 the way Klipper renders
# it, tick by tick, with SET_GCODE_VARIABLE applied between ticks.
# Usage: python3 tests/timelapse-watcher-tests.py
import ast
import os
import re
import shlex
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CAMERA_CFG = os.path.join(REPO, "scripts", "build", "overlay", "etc", "nebulaos", "klipper",
                          "camera.cfg")


def gcode_of(section_name):
    with open(CAMERA_CFG) as f:
        lines = f.read().splitlines()
    start = lines.index("[%s]" % section_name)
    out, inside = [], False
    for line in lines[start + 1:]:
        if line.startswith("["):
            break
        if line.startswith("gcode:"):
            inside = True
            continue
        if inside:
            out.append(line)
    return "\n".join(out)


class Obj(dict):
    __getattr__ = dict.__getitem__


class Watcher:
    def __init__(self):
        import jinja2
        env = jinja2.Environment("{%", "%}", "{", "}")
        self.macro = env.from_string(gcode_of("gcode_macro _NEBULAOS_TIMELAPSE"))
        self.tick_t = env.from_string(gcode_of("delayed_gcode _NEBULAOS_TIMELAPSE_WATCH"))
        self.vars = {"active": False, "frame_z": -1.0, "seen_z": -1.0}
        self.frames = 0
        self.scheduled = None

    def _run(self, text):
        for line in (l.strip() for l in text.splitlines()):
            if not line or line.startswith("#"):
                continue
            if line == "TIMELAPSE_TAKE_FRAME":
                self.frames += 1
            elif line.startswith("SET_GCODE_VARIABLE"):
                p = dict(a.split("=", 1) for a in shlex.split(line)[1:])
                assert p["MACRO"] == "_NEBULAOS_TIMELAPSE", line
                self.vars[p["VARIABLE"]] = ast.literal_eval(p["VALUE"])
            elif line.startswith("UPDATE_DELAYED_GCODE"):
                self.scheduled = float(re.search(r"DURATION=(\S+)", line).group(1))
            else:
                raise AssertionError("unexpected command: " + line)

    def action(self, action):
        self._run(self.macro.render(params={"ACTION": action}))

    def tick(self, z, enabled=True, state="printing"):
        printer = Obj({
            "gcode_macro _NEBULAOS_TIMELAPSE": Obj(self.vars),
            "gcode_macro TIMELAPSE_TAKE_FRAME": Obj({"enable": enabled}),
            "gcode_move": Obj({"gcode_position": Obj({"z": z})}),
            "print_stats": Obj({"state": state}),
        })
        self._run(self.tick_t.render(printer=printer))


def run(heights, **kw):
    w = Watcher()
    w.action("START")
    for z in heights:
        w.tick(z, **kw)
    return w


class WatcherTests(unittest.TestCase):
    def setUp(self):
        try:
            import jinja2  # noqa: F401
        except ImportError:
            raise unittest.SkipTest("jinja2 not installed")

    def test_one_picture_per_layer(self):
        w = run([0.2, 0.2, 0.2, 0.4, 0.4, 0.6, 0.6, 0.6, 0.8, 0.8])
        self.assertEqual(w.frames, 4)

    def test_short_z_hop_is_not_a_layer(self):
        # hop to 0.6 for under a second during layer 0.2
        w = run([0.2, 0.2, 0.6, 0.2, 0.2, 0.4, 0.4])
        self.assertEqual(w.frames, 2)

    def test_long_z_hop_does_not_hide_the_next_layer(self):
        # a travel that holds the hop height for two ticks costs one extra
        # picture, but the next layer is still taken
        w = run([0.2, 0.2, 0.6, 0.6, 0.2, 0.2, 0.4, 0.4])
        self.assertEqual(w.frames, 3)

    def test_nothing_while_timelapse_is_off(self):
        self.assertEqual(run([0.2, 0.2, 0.4, 0.4], enabled=False).frames, 0)

    def test_nothing_while_paused(self):
        self.assertEqual(run([0.2, 0.2, 0.4, 0.4], state="paused").frames, 0)

    def test_keeps_ticking_and_stop_ends_it(self):
        w = run([0.2, 0.2])
        self.assertEqual(w.scheduled, 1.0)
        w.action("STOP")
        self.assertEqual((w.vars["active"], w.scheduled), (False, 0.0))
        w.tick(0.4)
        w.tick(0.4)
        self.assertEqual(w.frames, 1)

    def test_start_resets_the_heights(self):
        w = run([5.0, 5.0])
        w.action("START")
        w.tick(0.2)
        w.tick(0.2)
        self.assertEqual(w.frames, 2)

    def test_upstream_macros_are_included(self):
        with open(CAMERA_CFG) as f:
            self.assertIn("[include timelapse.cfg]", f.read().splitlines())


if __name__ == "__main__":
    unittest.main(verbosity=1)
