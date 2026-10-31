#!/usr/bin/env python3
# Run 20 (Tim 2026-10-25): START_PRINT's bed warp soak and the end park.
#
#   - G112: the soak is OFF by default. START_PRINT BED_SOAK=1 soaks,
#     BED_SOAK=0 skips; without BED_SOAK the Mainsail switch
#     [output_pin Bed_Warp_Stabilisation] decides, and it starts at 0.
#   - G111: END_PRINT, CANCEL_PRINT and the end of the cooldown park at
#     X2 Y218 (_CLIENT_VARIABLE park_at_cancel_x/y); the cooldown itself
#     still parks at the bed's middle in front of the fan, PAUSE/M600 keep
#     their own park position.
#
# The macros are rendered with Jinja2 the way Klipper renders gcode_macro
# templates. Usage: python3 tests/print-start-end-macro-tests.py
import configparser
import os
import re
import sys
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PRINT_CFG = os.path.join(REPO, "scripts", "build", "overlay", "etc", "nebulaos", "klipper",
                         "print.cfg")


def section(name):
    """The raw lines of [name] in print.cfg (up to the next section)."""
    with open(PRINT_CFG) as f:
        lines = f.read().splitlines()
    start = lines.index("[%s]" % name)
    out = []
    for line in lines[start + 1:]:
        if line.startswith("["):
            break
        out.append(line)
    return out


def variable(macro_name, var):
    for line in section("gcode_macro %s" % macro_name):
        m = re.match(r"variable_%s:\s*(.*)$" % re.escape(var), line)
        if m:
            return m.group(1).strip()
    raise KeyError(var)


def macro(name):
    out, inside = [], False
    for line in section("gcode_macro %s" % name):
        if line.startswith("gcode:"):
            inside = True
            continue
        if inside:
            out.append(line)
    return "\n".join(out)


def render(name, **ctx):
    try:
        import jinja2
    except ImportError:
        raise unittest.SkipTest("jinja2 not installed")
    env = jinja2.Environment("{%", "%}", "{", "}")
    text = env.from_string(macro(name)).render(**ctx)
    return [l.strip() for l in text.splitlines() if l.strip() and not l.strip().startswith("#")]


class Obj(dict):
    __getattr__ = dict.__getitem__


START_END_PARAMS = Obj({
    "start_max_velocity": 400, "start_max_accel": 10000,
    "start_square_corner_velocity": 5.0, "start_preheat_nozzle_temp": 150,
    "start_print_bed_heating_move_bed_distance": 50.0,
    "full_bed_mesh_above_percentage_full": 75.0,
    "bed_warp_wait_multiplier": 8.0, "bed_warp_fraction_wait": 0.75,
    "bed_warp_wait_interval": 15,
})


def start_ctx(switch_value):
    return Obj({
        "gcode_macro END_PRINT": Obj({"started_cooldown": False}),
        "gcode_macro _CLIENT_VARIABLE": Obj({"runout_sensor": ""}),
        "gcode_macro _START_END_PARAMS": START_END_PARAMS,
        "output_pin Bed_Warp_Stabilisation": Obj({"value": switch_value}),
        "heater_bed": Obj({"temperature": 22.0}),
        "toolhead": Obj({"max_velocity": 500.0, "max_accel": 8000.0,
                         "square_corner_velocity": 5.0, "homed_axes": "xyz"}),
        "configfile": Obj({"settings": {}}),
    })


def warp_line(lines):
    w = [l for l in lines if l.startswith("_WARP_STABILISE")]
    assert len(w) == 1, lines
    return w[0]


class BedSoakTests(unittest.TestCase):
    def test_switch_starts_off(self):
        self.assertIn("value: 0", section("output_pin Bed_Warp_Stabilisation"))

    def test_default_is_no_soak(self):
        lines = render("START_PRINT", params={"BED_TEMP": "85", "EXTRUDER_TEMP": "240"},
                       rawparams="BED_TEMP=85 EXTRUDER_TEMP=240", printer=start_ctx(0))
        self.assertTrue(warp_line(lines).endswith("ENABLE=0"), warp_line(lines))

    def test_bed_soak_1_soaks_even_with_the_switch_off(self):
        lines = render("START_PRINT", params={"BED_TEMP": "85", "BED_SOAK": "1"},
                       rawparams="BED_TEMP=85 BED_SOAK=1", printer=start_ctx(0))
        self.assertTrue(warp_line(lines).endswith("ENABLE=1"), warp_line(lines))

    def test_bed_soak_0_skips_even_with_the_switch_on(self):
        lines = render("START_PRINT", params={"BED_TEMP": "85", "BED_SOAK": "0"},
                       rawparams="BED_TEMP=85 BED_SOAK=0", printer=start_ctx(1))
        self.assertTrue(warp_line(lines).endswith("ENABLE=0"), warp_line(lines))

    def test_no_bed_soak_follows_the_switch(self):
        lines = render("START_PRINT", params={"BED_TEMP": "85"},
                       rawparams="BED_TEMP=85", printer=start_ctx(1))
        self.assertTrue(warp_line(lines).endswith("ENABLE=1"), warp_line(lines))

    def warp(self, enable, switch_value=0, current=22.0):
        params = {"TARGET_TEMP": "85.0", "CURRENT_TEMP": str(current)}
        if enable is not None:
            params["ENABLE"] = str(enable)
        return render("_WARP_STABILISE", params=params, printer=Obj({
            "output_pin Bed_Warp_Stabilisation": Obj({"value": switch_value}),
            "gcode_macro _START_END_PARAMS": START_END_PARAMS}))

    def test_warp_enable_0_skips_with_a_hint(self):
        lines = self.warp(0, switch_value=1)
        self.assertFalse(any(l.startswith("G4") for l in lines), lines)
        self.assertTrue(any("BED_SOAK=1" in l for l in lines), lines)

    def test_warp_enable_1_waits_8_s_per_degree(self):
        lines = self.warp(1)
        self.assertTrue(any("total time of 680 seconds" in l for l in lines), lines)
        waits = sum(int(re.match(r"G4 P(\d+)", l).group(1)) for l in lines if l.startswith("G4"))
        # 45 status lines; the last wait is the 5 s left (SimpleAF rounding)
        self.assertEqual(waits, 44 * 15000 + 5000)

    def test_warp_without_enable_reads_the_switch(self):
        self.assertFalse(any(l.startswith("G4") for l in self.warp(None, switch_value=0)))
        self.assertTrue(any(l.startswith("G4") for l in self.warp(None, switch_value=1)))


def park_ctx(cooldown=False):
    return Obj({
        "toolhead": Obj({"homed_axes": "xyz", "axis_maximum": Obj({"x": 221.0, "y": 223.0, "z": 240.0})}),
        "gcode_macro _CLIENT_VARIABLE": Obj({
            "speed_move": 100.0, "speed_hop": 15.0, "custom_park_dz": 45.0,
            "park_at_cancel_x": float(variable("_CLIENT_VARIABLE", "park_at_cancel_x")),
            "park_at_cancel_y": float(variable("_CLIENT_VARIABLE", "park_at_cancel_y"))}),
        "configfile": Obj({"settings": {"pause_resume": {"recover_velocity": 50.0},
                                        "stepper_y": {"position_max": 223.0}}}),
        "gcode_move": Obj({"homing_origin": Obj({"z": 0.0}),
                           "gcode_position": Obj({"z": 10.0}),
                           "absolute_coordinates": True}),
    })


class EndParkTests(unittest.TestCase):
    def park_move(self, **params):
        lines = render("_TOOLHEAD_PARK_CANCEL_END_PRINT", params=params, printer=park_ctx())
        moves = [l for l in lines if l.startswith("G0 X")]
        self.assertEqual(len(moves), 1, lines)
        return moves[0]

    def test_end_and_cancel_park_at_x2_y218(self):
        self.assertTrue(self.park_move().startswith("G0 X2.0 Y218.0 "), self.park_move())

    def test_end_of_cooldown_parks_at_x2_y218(self):
        self.assertTrue(self.park_move(SKIP_Z_PARK="1").startswith("G0 X2.0 Y218.0 "))

    def test_cooldown_itself_parks_in_front_of_the_fan(self):
        self.assertTrue(self.park_move(COOLDOWN="1").startswith("G0 X2.0 Y111.5 "))

    def test_callers(self):
        self.assertIn("_TOOLHEAD_PARK_CANCEL_END_PRINT", macro("END_PRINT"))
        self.assertIn("_TOOLHEAD_PARK_CANCEL_END_PRINT", macro("CANCEL_PRINT"))
        self.assertIn("_TOOLHEAD_PARK_CANCEL_END_PRINT SKIP_Z_PARK=1", macro("_WAIT_TEMP_COOL_DOWN_END"))

    def test_park_is_inside_the_bed_limits(self):
        cfg = configparser.RawConfigParser(strict=False, inline_comment_prefixes=("#", ";"))
        cfg.read(os.path.join(os.path.dirname(PRINT_CFG), "machine.cfg"))
        x = float(variable("_CLIENT_VARIABLE", "park_at_cancel_x"))
        y = float(variable("_CLIENT_VARIABLE", "park_at_cancel_y"))
        self.assertTrue(cfg.getfloat("stepper_x", "position_min") <= x <= cfg.getfloat("stepper_x", "position_max"))
        self.assertTrue(cfg.getfloat("stepper_y", "position_min") <= y <= cfg.getfloat("stepper_y", "position_max"))

    def test_pause_park_unchanged(self):
        self.assertEqual(variable("_CLIENT_VARIABLE", "custom_park_x"), "0.0")
        self.assertEqual(variable("_CLIENT_VARIABLE", "custom_park_y"), "0.0")



def steps(lines):
    out = []
    for l in lines:
        m = re.match(r"SET_GCODE_VARIABLE MACRO=START_PRINT VARIABLE=step VALUE='\"(.*)\"'$", l)
        if m:
            out.append(m.group(1))
    return out


class StartStepTests(unittest.TestCase):
    """G112 (2026-10-31): START_PRINT says which step it is in (screen step list)."""

    def test_steps_in_order_without_soak(self):
        ctx = start_ctx(0)
        ctx["gcode_macro _NEBULAOS_TIMELAPSE"] = Obj({})
        lines = render("START_PRINT", params={"BED_TEMP": "60"}, rawparams="BED_TEMP=60",
                       printer=ctx)
        self.assertEqual(steps(lines), ["preparing", "heating_bed", "mesh", "heating_nozzle",
                                        "purge", ""])
        # each step is set right before the command it names
        self.assertTrue(lines[lines.index("M190 S60.0  # wait for bed temperature before next step") - 1]
                        .endswith("\"heating_bed\"'"))
        self.assertIn("_NEBULAOS_TIMELAPSE ACTION=START", lines)
        self.assertGreater(lines.index("_NEBULAOS_TIMELAPSE ACTION=START"),
                           lines.index("_LINE_PURGE"))

    def test_soak_step_only_when_soaking(self):
        lines = render("START_PRINT", params={"BED_TEMP": "85", "BED_SOAK": "1"},
                       rawparams="BED_TEMP=85 BED_SOAK=1", printer=start_ctx(0))
        self.assertEqual(steps(lines), ["preparing", "heating_bed", "soak", "mesh",
                                        "heating_nozzle", "purge", ""])

    def test_without_camera_cfg_no_watcher_call(self):
        lines = render("START_PRINT", params={"BED_TEMP": "60"}, rawparams="BED_TEMP=60",
                       printer=start_ctx(0))
        self.assertNotIn("_NEBULAOS_TIMELAPSE ACTION=START", lines)

    def test_filament_abort_clears_the_step(self):
        ctx = start_ctx(0)
        ctx["gcode_macro _CLIENT_VARIABLE"] = Obj({"runout_sensor": "filament_switch_sensor s"})
        ctx["filament_switch_sensor s"] = Obj({"filament_detected": False})
        lines = render("START_PRINT", params={"BED_TEMP": "60"}, rawparams="BED_TEMP=60",
                       printer=ctx)
        self.assertEqual(steps(lines), [""])
        self.assertLess(lines.index("SET_GCODE_VARIABLE MACRO=START_PRINT VARIABLE=step VALUE='\"\"'"),
                        lines.index("CANCEL_PRINT"))

    def test_end_and_cancel_stop_the_watcher_and_clear_the_step(self):
        for name in ("END_PRINT", "CANCEL_PRINT"):
            text = macro(name)
            self.assertIn("_NEBULAOS_TIMELAPSE ACTION=STOP", text, name)
            self.assertIn("VARIABLE=step VALUE='\"\"'", text, name)

    def test_soak_publishes_its_length(self):
        self.assertIn("SET_GCODE_VARIABLE MACRO=START_PRINT VARIABLE=soak_seconds VALUE={total_time}",
                      macro("_WARP_STABILISE"))
        self.assertEqual(variable("START_PRINT", "step"), '""')

if __name__ == "__main__":
    unittest.main(verbosity=1)
