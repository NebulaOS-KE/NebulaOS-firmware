#!/usr/bin/env python3
# C3 (Z-offset chain review, 2026-10-22): START_PRINT's mesh is calibrated
# under its own name "adaptive" and is never staged for SAVE_CONFIG, so an
# unrelated SAVE_CONFIG can never replace the calibrated "default" mesh.
#
#   - the macros (etc/nebulaos/klipper/print.cfg), rendered with Jinja2 the
#     way Klipper renders gcode_macro templates;
#   - pinned Klipper's own bed_mesh ProfileManager and configfile
#     ConfigAutoSave (vendor/klipper): the full-mesh fallback stages
#     [bed_mesh adaptive], BED_MESH_PROFILE REMOVE=adaptive unstages it and
#     never unloads the mesh in use, a saved [bed_mesh default] is untouched;
#   - the pinned bed_mesh behaviour the macro relies on (PROFILE default
#     "default", the adaptive path drops the name);
#   - F2 (Run 18): a full mesh on a print with objects goes through the
#     adaptive path (ADAPTIVE=1 ADAPTIVE_MARGIN=1000): pinned
#     BedMeshCalibrate.update_config with machine.cfg's [bed_mesh] probes the
#     same points as ADAPTIVE=0 and stages nothing (no save_config_pending).
#
# Usage: python3 tests/print-mesh-profile-tests.py
import collections
import configparser
import os
import re
import sys
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PRINT_CFG = os.path.join(REPO, "scripts", "build", "overlay", "etc", "nebulaos", "klipper",
                         "print.cfg")
KLIPPY = os.path.join(REPO, "vendor", "klipper", "klippy")
BED_MESH = os.path.join(KLIPPY, "extras", "bed_mesh.py")


def macro(name):
    """The gcode template of [gcode_macro NAME] in print.cfg."""
    lines = open(PRINT_CFG).read().splitlines()
    start = lines.index("[gcode_macro %s]" % name)
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


def printer_ctx(objects=(), profiles=()):
    return Obj({
        "configfile": Obj({"settings": {"bed_mesh": {}},
                           "config": Obj({"stepper_x": Obj({"position_max": "220"}),
                                          "stepper_y": Obj({"position_max": "220"})})}),
        "exclude_object": Obj({"objects": [Obj({"polygon": p}) for p in objects]}),
        "gcode_macro _START_END_PARAMS": Obj({"full_bed_mesh_above_percentage_full": 75.0}),
        "bed_mesh": Obj({"profiles": {p: {} for p in profiles}}),
    })


FULL_VIA_ADAPTIVE = "BED_MESH_CALIBRATE ADAPTIVE=1 ADAPTIVE_MARGIN=1000 PROFILE=adaptive START_PRINT=1"


class MacroTests(unittest.TestCase):
    def test_print_mesh_is_named_adaptive_and_unstaged(self):
        small = [[[100, 100], [120, 100], [120, 120], [100, 120]]]
        out = render("_START_PRINT_BED_MESH", params={}, printer=printer_ctx(small))
        self.assertEqual(out, ["BED_MESH_CALIBRATE ADAPTIVE=1 PROFILE=adaptive START_PRINT=1",
                               "_START_PRINT_BED_MESH_UNSTAGE"])
        # bed usage above the threshold: a full mesh through the adaptive
        # path (F2: same points, nothing staged)
        big = [[[0, 0], [220, 0], [220, 220], [0, 220]]]
        out = render("_START_PRINT_BED_MESH", params={}, printer=printer_ctx(big))
        self.assertIn(FULL_VIA_ADAPTIVE, out)
        self.assertEqual(out[-1], "_START_PRINT_BED_MESH_UNSTAGE")
        # the user asks for a full mesh on a print with objects: same
        out = render("_START_PRINT_BED_MESH", params={"BED_MESH_ADAPTIVE": "0"},
                     printer=printer_ctx(small))
        self.assertEqual(out, [FULL_VIA_ADAPTIVE, "_START_PRINT_BED_MESH_UNSTAGE"])
        # ... without objects: the named fallback (unstaged afterwards)
        out = render("_START_PRINT_BED_MESH", params={"BED_MESH_ADAPTIVE": "0"},
                     printer=printer_ctx())
        self.assertEqual(out, ["BED_MESH_CALIBRATE ADAPTIVE=0 PROFILE=adaptive START_PRINT=1",
                               "_START_PRINT_BED_MESH_UNSTAGE"])
        # no objects at all
        out = render("_START_PRINT_BED_MESH", params={}, printer=printer_ctx())
        self.assertEqual(out, ["BED_MESH_CALIBRATE ADAPTIVE=1 PROFILE=adaptive START_PRINT=1",
                               "_START_PRINT_BED_MESH_UNSTAGE"])

    def test_explicit_profile_is_loaded_not_calibrated(self):
        out = render("_START_PRINT_BED_MESH", params={"BED_MESH_PROFILE": "default"},
                     printer=printer_ctx())
        self.assertEqual(out, ['BED_MESH_PROFILE LOAD="default"'])

    def test_unstage_only_when_staged(self):
        self.assertEqual(render("_START_PRINT_BED_MESH_UNSTAGE",
                                printer=printer_ctx(profiles=("default", "adaptive"))),
                         ["BED_MESH_PROFILE REMOVE=adaptive"])
        self.assertEqual(render("_START_PRINT_BED_MESH_UNSTAGE",
                                printer=printer_ctx(profiles=("default",))), [])

    def test_no_print_mesh_under_a_saved_name(self):
        text = open(PRINT_CFG).read()
        calls = re.findall(r"^\s*BED_MESH_CALIBRATE\b.*$", text, re.M)
        self.assertEqual(len(calls), 2)
        for call in calls:
            self.assertIn("PROFILE=adaptive", call)
        self.assertNotRegex(text, r"(?m)^\s*BED_MESH_PROFILE SAVE")


class FakeGcode(object):
    def register_command(self, *a, **k):
        pass

    def respond_info(self, msg):
        pass


class FakePrinter(object):
    def __init__(self):
        self.objects = {"gcode": FakeGcode()}

    def lookup_object(self, name, default=None):
        return self.objects.get(name, default)


class FakeZMesh(object):
    def __init__(self, name):
        self.name = name

    def get_probed_matrix(self):
        return [[0.1, 0.2], [0.3, 0.4]]

    def get_mesh_params(self):
        return {"min_x": 10.0, "max_x": 200.0, "x_count": 2, "y_count": 2}

    def get_profile_name(self):
        return self.name


class FakeBedMesh(object):
    def __init__(self, mesh):
        self.mesh, self.set_calls = mesh, []

    def get_mesh(self):
        return self.mesh

    def set_mesh(self, mesh):
        self.set_calls.append(mesh)
        self.mesh = mesh

    def update_status(self):
        pass


class PinnedBedMeshTests(unittest.TestCase):
    def setUp(self):
        if KLIPPY not in sys.path:
            sys.path.insert(0, KLIPPY)
        try:
            import configfile
            from extras import bed_mesh
        except Exception as exc:          # numpy etc. missing on this host
            raise unittest.SkipTest("pinned Klipper not importable here: %s" % exc)
        self.printer = FakePrinter()
        self.autosave = configfile.ConfigAutoSave(self.printer)
        self.autosave.fileconfig = configparser.RawConfigParser()
        # the user's calibrated mesh, already in the SAVE_CONFIG block
        self.autosave.fileconfig.add_section("bed_mesh default")
        self.autosave.fileconfig.set("bed_mesh default", "points", "0.0, 0.0")
        self.printer.objects["configfile"] = self.autosave
        self.bedmesh = FakeBedMesh(FakeZMesh("adaptive"))
        pm = bed_mesh.ProfileManager.__new__(bed_mesh.ProfileManager)
        pm.name, pm.printer, pm.gcode = "bed_mesh", self.printer, FakeGcode()
        pm.bedmesh, pm.profiles, pm.incompatible_profiles = self.bedmesh, {"default": {}}, []
        self.pm = pm

    def test_fallback_staged_then_unstaged_mesh_kept(self):
        # what probe_finalize does for a named (non-adaptive) mesh
        self.pm.save_profile("adaptive")
        self.assertIn("bed_mesh adaptive", self.autosave.status_save_pending)
        self.assertIn("adaptive", self.pm.profiles)
        # _START_PRINT_BED_MESH_UNSTAGE
        self.pm.remove_profile("adaptive")
        # set() put the section into the autosave config, so the removal is
        # recorded as a deletion (None) - what SAVE_CONFIG writes is the
        # autosave config itself, which no longer has it.
        self.assertIsNone(self.autosave.status_save_pending["bed_mesh adaptive"])
        # F2 residual (prints without objects only): the flag stays set
        self.assertTrue(self.autosave.save_config_pending)
        self.assertFalse(self.autosave.fileconfig.has_section("bed_mesh adaptive"))
        import configfile
        written = configfile.ConfigFileReader().build_config_string(self.autosave.fileconfig)
        self.assertNotIn("adaptive", written)
        self.assertIn("[bed_mesh default]", written)
        self.assertNotIn("adaptive", self.pm.profiles)
        self.assertEqual(self.bedmesh.set_calls, [])            # the print's mesh stays loaded
        self.assertEqual(self.bedmesh.get_mesh().get_profile_name(), "adaptive")
        # the calibrated default mesh: untouched, nothing pending for it
        self.assertTrue(self.autosave.fileconfig.has_section("bed_mesh default"))
        self.assertNotIn("bed_mesh default", self.autosave.status_save_pending)

    def test_old_behaviour_would_replace_default(self):
        # the C3 bug: the fallback mesh named "default" is staged over it
        self.pm.save_profile("default")
        self.assertIn("bed_mesh default", self.autosave.status_save_pending)

    def test_pinned_bed_mesh_naming(self):
        src = open(BED_MESH).read()
        self.assertIn("self._profile_name = gcmd.get('PROFILE', \"default\")", src)
        adaptive = src[src.index("def set_adaptive_mesh"):src.index("def update_config")]
        self.assertIn("self._profile_name = None", adaptive)    # adaptive mesh: never staged
        self.assertIn("if self._profile_name is not None:\n            self.bedmesh.save_profile(",
                      src)
        remove = src[src.index("def remove_profile"):src.index("cmd_BED_MESH_PROFILE_help")]
        self.assertNotIn("set_mesh", remove)                    # REMOVE never unloads


MACHINE_CFG = os.path.join(os.path.dirname(PRINT_CFG), "machine.cfg")


class FakeExcludeObject(object):
    def __init__(self, polygons):
        self.polygons = polygons

    def get_status(self, eventtime=None):
        return {"objects": [{"name": "o%d" % i, "polygon": p}
                            for i, p in enumerate(self.polygons)]}


class FakeProbeMgr(object):
    def __init__(self):
        self.calls = []

    def generate_points(self, mesh_config, mesh_min, mesh_max, radius, origin,
                        probe_method="automatic"):
        self.calls.append((dict(mesh_config), tuple(mesh_min), tuple(mesh_max),
                           radius, origin, probe_method))


class FakeGcmd(object):
    def __init__(self, **params):
        self.params = {k: str(v) for k, v in params.items()}

    def get_command_parameters(self):
        return dict(self.params)

    def get(self, name, default=None):
        return self.params.get(name, default)

    def get_int(self, name, default=None, **kw):
        return int(self.params[name]) if name in self.params else default

    def get_float(self, name, default=None, **kw):
        return float(self.params[name]) if name in self.params else default

    def respond_info(self, msg):
        pass

    def error(self, msg):
        return Exception(msg)


class FullMeshViaAdaptiveTests(unittest.TestCase):
    """F2: pinned BedMeshCalibrate.update_config with machine.cfg's real
    [bed_mesh]: ADAPTIVE=1 ADAPTIVE_MARGIN=1000 on a print with objects
    probes exactly the points of ADAPTIVE=0, and drops the profile name (so
    probe_finalize never stages [bed_mesh adaptive])."""

    def calibrate(self, polygons, **params):
        if KLIPPY not in sys.path:
            sys.path.insert(0, KLIPPY)
        try:
            import configfile
            from extras import bed_mesh
        except Exception as exc:          # numpy etc. missing on this host
            raise unittest.SkipTest("pinned Klipper not importable here: %s" % exc)
        printer = FakePrinter()
        printer.objects["exclude_object"] = FakeExcludeObject(polygons)
        fileconfig = configfile.ConfigFileReader().build_fileconfig(
            open(MACHINE_CFG).read(), MACHINE_CFG)
        config = configfile.ConfigWrapper(printer, fileconfig, {}, "bed_mesh")
        cal = bed_mesh.BedMeshCalibrate.__new__(bed_mesh.BedMeshCalibrate)
        cal.printer = printer
        cal.orig_config = {"radius": None, "origin": None}
        cal.radius = cal.origin = None
        cal.mesh_min = cal.mesh_max = (0., 0.)
        cal.adaptive_margin = 0.
        cal.mesh_config = collections.OrderedDict()
        cal._init_mesh_config(config)
        cal.probe_mgr = FakeProbeMgr()
        cal._profile_name = "adaptive"                  # PROFILE=adaptive
        cal.update_config(FakeGcmd(**params))
        return cal.probe_mgr.calls[-1], cal._profile_name

    def test_same_points_as_full_and_not_staged(self):
        objects = [[[0, 0], [220, 0], [220, 220], [0, 220]]]
        full, full_name = self.calibrate(objects, ADAPTIVE=0, PROFILE="adaptive")
        via, via_name = self.calibrate(objects, ADAPTIVE=1, ADAPTIVE_MARGIN=1000,
                                       PROFILE="adaptive")
        self.assertEqual(full, via)
        self.assertEqual(full[1:3], ((5.0, 10.0), (215.0, 215.0)))
        self.assertEqual((full[0]["x_count"], full[0]["y_count"]), (9, 9))
        self.assertEqual(full_name, "adaptive")         # ADAPTIVE=0: staged, then UNSTAGE
        self.assertIsNone(via_name)                     # never staged
        # a small object far from the edges: still the whole bed
        small, small_name = self.calibrate([[[100, 100], [120, 100], [120, 120], [100, 120]]],
                                           ADAPTIVE=1, ADAPTIVE_MARGIN=1000)
        self.assertEqual((small, small_name), (full, None))


CALIBRATION_CFG = os.path.join(os.path.dirname(PRINT_CFG), "calibration.cfg")
EXTENSIONS = [os.path.join(REPO, "..", "NebulaOS-klipper-extensions"),
              os.path.join(REPO, "vendor", "nebulaos-klipper-extensions")]


class ZAdjustConfigTests(unittest.TestCase):
    """G92: [nebulaos_z_adjust] in the image-owned calibration.cfg, and RESUME
    re-applies the saved adjustment after the upstream resume (C4)."""

    def test_section_with_module_defaults(self):
        lines = open(CALIBRATION_CFG).read().splitlines()
        i = lines.index("[nebulaos_z_adjust]")
        body = []
        for line in lines[i + 1:]:
            if not line.strip() or line.startswith("["):
                break
            body.append(line)
        self.assertEqual(body, ["#filename: /opt/printer_data/config/z_offset_adjust.json",
                                "#max_adjust: 2.0"])           # module defaults, not set here
        for root in EXTENSIONS:
            mod = os.path.join(root, "extras", "nebulaos_z_adjust.py")
            if os.path.exists(mod):
                src = open(mod).read()
                self.assertIn('"/opt/printer_data/config/z_offset_adjust.json"', src)
                self.assertIn("config.getfloat('max_adjust', 2.0", src)
                return
        self.skipTest("no extensions checkout with nebulaos_z_adjust.py here")

    def test_pause_marks_after_pause_base(self):
        stripped = [l.strip() for l in macro("PAUSE").splitlines()]
        base = stripped.index("PAUSE_BASE")
        mark = stripped.index("NEBULAOS_Z_ADJUST MARK=1")
        self.assertGreater(mark, base)

    def test_resume_reapplies_after_resume_base(self):
        body = macro("RESUME").splitlines()
        stripped = [l.strip() for l in body]
        base = next(i for i, l in enumerate(stripped) if l.startswith("RESUME_BASE"))
        # RESUME=1 adds only screen changes made while paused (never an
        # absolute APPLY: that would drop Mainsail / print-file offsets).
        self.assertNotIn("NEBULAOS_Z_ADJUST APPLY=1", stripped)
        apply = stripped.index("NEBULAOS_Z_ADJUST RESUME=1")
        self.assertGreater(apply, base)
        # in the same branch: only when the resume really happened
        self.assertEqual(body[apply][:len(body[apply]) - len(body[apply].lstrip())],
                         body[base][:len(body[base]) - len(body[base].lstrip())])
        between = [l for l in stripped[base + 1:apply] if l and not l.startswith("#")]
        self.assertEqual(between, [])


if __name__ == "__main__":
    unittest.main()
