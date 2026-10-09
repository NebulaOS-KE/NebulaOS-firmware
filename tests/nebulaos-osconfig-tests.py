#!/usr/bin/env python3
# Offline tests for the NebulaOS OS-settings helper (nebulaos_osconfig) and the
# [nebulaos] Moonraker component (GUI/service readiness mission, 2026-10-09).
#
# Every hardware/system boundary is faked: the network apply bridge
# (nebulaos-netapply), the backlight CLI (nebulaos-backlight), the framebuffer
# geometry and the Moonraker server. What this proves is the helper's own
# logic - validation, atomic persistence, revert, the JSON/exit contract, the
# component's argv mapping. It does not prove the kernel controller, ifupdown
# or Moonraker behave as documented; hardware acceptance does that.
#
# Usage: python3 tests/nebulaos-osconfig-tests.py
import asyncio
import importlib
import io
import json
import os
import shutil
import stat
import struct
import sys
import tempfile
import textwrap
import types
import unittest
import warnings

warnings.simplefilter("ignore", ResourceWarning)

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OVERLAY = os.path.join(REPO, "scripts", "build", "overlay")
PYLIB = os.path.join(OVERLAY, "usr", "lib", "nebulaos", "python")
COMPONENT = os.path.join(OVERLAY, "usr", "lib", "nebulaos", "moonraker", "nebulaos.py")
CLI = os.path.join(OVERLAY, "usr", "libexec", "nebulaos", "nebulaos-osconfig")


def write_exe(path, body):
    with open(path, "w") as handle:
        handle.write("#!/bin/sh\n" + textwrap.dedent(body))
    os.chmod(path, 0o755)


class Env(object):
    """Fresh NEBULAOS_ROOT/run dir + fake tools, modules re-imported."""

    def __init__(self):
        self.tmp = tempfile.mkdtemp()
        self.root = os.path.join(self.tmp, "data")
        self.run = os.path.join(self.tmp, "run")
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        self.netapply = os.path.join(self.bin, "netapply")
        self.backlight = os.path.join(self.bin, "backlight")
        self.config_root = os.path.join(self.tmp, "config")
        os.makedirs(self.config_root)
        os.environ.update({
            "NEBULAOS_ROOT": self.root, "NEBULAOS_OSCONFIG_RUN": self.run,
            "NEBULAOS_NETAPPLY": self.netapply,
            "NEBULAOS_BACKLIGHT_CLI": self.backlight,
            "NEBULAOS_CONFIG_ROOT": self.config_root,
            "NEBULAOS_SEED_MANIFEST": os.path.join(self.tmp, "seed.json"),
            "NEBULAOS_GUPPY_CONFIG": os.path.join(self.tmp, "guppy.json"),
            "NEBULAOS_DATA_MOUNT": self.tmp,
            "NEBULAOS_DATA_FS_STATE": os.path.join(self.tmp, "datafs.state"),
            # Never the host's real framebuffer.
            "NEBULAOS_FB_SYSFS": os.path.join(self.tmp, "no-fb-sysfs"),
            "NEBULAOS_FB_DEV": os.path.join(self.tmp, "no-fb"),
        })
        if PYLIB not in sys.path:
            sys.path.insert(0, PYLIB)
        for name in list(sys.modules):
            if name.startswith("nebulaos_osconfig"):
                del sys.modules[name]
        self.pkg = importlib.import_module("nebulaos_osconfig")
        for mod in ("common", "network", "display", "bootdisplay", "system", "cli"):
            setattr(self, mod, importlib.import_module("nebulaos_osconfig." + mod))

    def netapply_script(self, apply_rcs):
        """apply exits with the next rc of apply_rcs per call (log in calls)."""
        calls = os.path.join(self.tmp, "netapply.calls")
        if os.path.exists(calls):
            os.unlink(calls)
        seq = " ".join(str(r) for r in apply_rcs)
        write_exe(self.netapply, """
            echo "$1 $(cat "%(env)s" 2>/dev/null | tr '\\n' ' ')" >> "%(calls)s"
            [ "$1" = hostname ] && exit 0
            n=$(grep -c '^apply' "%(calls)s")
            set -- %(seq)s
            i=1; rc=0
            for r in "$@"; do [ "$i" -eq "$n" ] && rc=$r; i=$((i+1)); done
            exit $rc
        """ % {"calls": calls, "seq": seq,
               "env": os.path.join(self.root, "network", "boot.env")})
        return calls

    def cleanup(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


class NetworkValidationTests(unittest.TestCase):
    def setUp(self):
        self.e = Env()
        self.n = self.e.network

    def tearDown(self):
        self.e.cleanup()

    def test_hostnames(self):
        self.assertEqual(self.n.validate_hostname("KE-Workshop"), "ke-workshop")
        for bad in ["", "-a", "a-", "a_b", "a.b", "x" * 64, "1234", "localhost",
                    "héllo", "a b", None, 5, "a;reboot"]:
            with self.assertRaises(self.e.common.OsConfigError, msg=repr(bad)) as cm:
                self.n.validate_hostname(bad)
            self.assertTrue(cm.exception.invalid)

    def test_static_ok(self):
        v = self.n.validate_ipv4({"mode": "static", "address": "192.168.1.50",
                                  "prefix": 24, "gateway": "192.168.1.1",
                                  "dns": ["192.168.1.1", "1.1.1.1"]})
        self.assertEqual(v["prefix"], 24)
        self.assertEqual(self.n.validate_ipv4({"mode": "dhcp", "address": "x"}),
                         {"mode": "dhcp"})

    def test_static_rejections(self):
        base = {"mode": "static", "address": "192.168.1.50", "prefix": 24,
                "gateway": "192.168.1.1", "dns": []}
        cases = [
            dict(base, mode="manual"), dict(base, address="192.168.1.0"),
            dict(base, address="192.168.1.255"), dict(base, address="127.0.0.1"),
            dict(base, address="224.0.0.1"), dict(base, address="169.254.1.1"),
            dict(base, address="0.0.0.0"), dict(base, address="300.1.1.1"),
            dict(base, address="1.2.3"), dict(base, prefix=31), dict(base, prefix=7),
            dict(base, prefix="x"), dict(base, gateway="192.168.2.1"),
            dict(base, gateway="192.168.1.50"), dict(base, dns="1.1.1.1"),
            dict(base, dns=["1.1.1.1"] * 4), dict(base, dns=["0.0.0.0"]),
            "static", None,
        ]
        for spec in cases:
            with self.assertRaises(self.e.common.OsConfigError, msg=repr(spec)) as cm:
                self.n.validate_ipv4(spec)
            self.assertTrue(cm.exception.invalid)

    def test_boot_env_static(self):
        cfg = {"schema": 1, "hostname": "ke",
               "ipv4": {"mode": "static", "address": "10.0.0.5", "prefix": 16,
                        "gateway": "10.0.0.1", "dns": ["10.0.0.1"]}}
        text = self.n.boot_env_text(cfg)
        self.assertIn('NNET_NETMASK="255.255.0.0"', text)
        self.assertIn('NNET_DNS="10.0.0.1"', text)
        self.assertIn('NNET_MODE="static"', text)


class NetworkApplyTests(unittest.TestCase):
    def setUp(self):
        self.e = Env()
        self.n = self.e.network
        self.static = {"mode": "static", "address": "192.168.1.50", "prefix": 24,
                       "gateway": "192.168.1.1", "dns": ["192.168.1.1"]}

    def tearDown(self):
        self.e.cleanup()

    def test_defaults_when_missing(self):
        cfg, err = self.n.load_config()
        self.assertEqual(cfg, self.n.default_config())
        self.assertIsNone(err)

    def test_corrupt_config_falls_back_and_reports(self):
        os.makedirs(os.path.dirname(self.n.CONFIG))
        with open(self.n.CONFIG, "w") as handle:
            handle.write("{not json")
        cfg, err = self.n.load_config()
        self.assertEqual(cfg["ipv4"], {"mode": "dhcp"})
        self.assertIn("corrupt", err)
        with open(self.n.CONFIG) as handle:   # left for inspection
            self.assertEqual(handle.read(), "{not json")

    def test_set_static_success_commits_lkg(self):
        self.e.netapply_script([0])
        result = self.n.set_ipv4(self.static)
        self.assertEqual(result["result"], "APPLIED")
        self.assertEqual(self.n.load_config()[0]["ipv4"]["address"], "192.168.1.50")
        self.assertEqual(json.load(open(self.n.LKG))["ipv4"]["mode"], "static")
        with open(self.n.BOOT_ENV) as handle:
            self.assertIn('NNET_MODE="static"', handle.read())

    def test_gateway_silent_reverts_files_and_live(self):
        calls = self.e.netapply_script([4, 0])
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.n.set_ipv4(self.static)
        self.assertEqual(cm.exception.code, "GATEWAY_UNREACHABLE_REVERTED")
        self.assertFalse(cm.exception.invalid)
        self.assertFalse(os.path.exists(self.n.CONFIG))   # previous state: absent
        self.assertFalse(os.path.exists(self.n.BOOT_ENV))
        self.assertFalse(os.path.exists(self.n.LKG))
        lines = open(calls).read().splitlines()
        self.assertEqual([l.split()[0] for l in lines], ["apply", "apply"])
        self.assertIn("static", lines[0])                 # new config applied first

    def test_revert_restores_previous_static(self):
        self.e.netapply_script([0])
        self.n.set_ipv4(self.static)
        before = open(self.n.CONFIG, "rb").read()
        self.e.netapply_script([3, 0])
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.n.set_ipv4({"mode": "dhcp"})
        self.assertEqual(cm.exception.code, "DHCP_FAILED_REVERTED")
        self.assertEqual(open(self.n.CONFIG, "rb").read(), before)

    def test_invalid_input_writes_nothing(self):
        calls = self.e.netapply_script([0])
        with self.assertRaises(self.e.common.OsConfigError):
            self.n.set_ipv4(dict(self.static, gateway="10.9.9.9"))
        self.assertFalse(os.path.exists(self.n.CONFIG))
        self.assertFalse(os.path.exists(calls))

    def test_hostname_change_no_network_bounce(self):
        calls = self.e.netapply_script([0])
        result = self.n.set_hostname("Workshop-KE")
        self.assertEqual(result["config"]["hostname"], "workshop-ke")
        self.assertTrue(result["mdns_restart_required"])
        self.assertEqual(open(calls).read().split()[0], "hostname")
        self.assertEqual(self.n.set_hostname("workshop-ke")["result"], "UNCHANGED")

    def test_reset(self):
        self.e.netapply_script([0, 0])
        self.n.set_ipv4(self.static)
        self.n.reset()
        self.assertEqual(self.n.load_config()[0], self.n.default_config())


class FakeBacklight(object):
    """A fake nebulaos-backlight CLI with a tiny state file."""

    def __init__(self, env, set_rc=0, sleep_rc=0, wake_rc=0, state="boot-preserve"):
        self.state_file = os.path.join(env.tmp, "bl.state")
        self.calls = os.path.join(env.tmp, "bl.calls")
        with open(self.state_file, "w") as handle:
            handle.write("%s 100\n" % state)
        write_exe(env.backlight, """
            echo "$*" >> "%(calls)s"
            read st lvl < "%(sf)s"
            case "$1" in
              status) echo available=1; echo state=$st
                      [ "$st" = asleep ] && echo level=0 || echo level=$lvl
                      [ "$st" = asleep ] && echo asleep=1 || echo asleep=0
                      echo touch_wake=1; exit 0 ;;
              set) [ "$st" = asleep ] && exit 3
                   [ %(set_rc)d -ne 0 ] && exit %(set_rc)d
                   echo "pwm-committed $2" > "%(sf)s"; exit 0 ;;
              sleep) [ %(sleep_rc)d -ne 0 ] && exit %(sleep_rc)d
                   echo "asleep $lvl" > "%(sf)s"; exit 0 ;;
              wake) [ %(wake_rc)d -ne 0 ] && exit %(wake_rc)d
                   echo "pwm-committed $lvl" > "%(sf)s"; exit 0 ;;
            esac
            exit 64
        """ % {"calls": self.calls, "sf": self.state_file, "set_rc": set_rc,
               "sleep_rc": sleep_rc, "wake_rc": wake_rc})

    def call_log(self):
        try:
            return open(self.calls).read().splitlines()
        except OSError:
            return []


class DisplayTests(unittest.TestCase):
    def setUp(self):
        self.e = Env()
        self.d = self.e.display

    def tearDown(self):
        self.e.cleanup()

    def test_level_validation(self):
        for good in (25, 50, 75, 100, "50"):
            self.assertIn(self.d.validate_level(good), self.d.LEVELS)
        for bad in (0, 10, 60, 101, -1, "50.0", "fifty", None, True, 50.5, " 50x"):
            with self.assertRaises(self.e.common.OsConfigError, msg=repr(bad)):
                self.d.validate_level(bad)

    def test_invalid_level_writes_and_runs_nothing(self):
        bl = FakeBacklight(self.e)
        with self.assertRaises(self.e.common.OsConfigError):
            self.d.set_brightness(30)
        self.assertFalse(os.path.exists(self.d.CONFIG))
        self.assertEqual(bl.call_log(), [])

    def test_set_brightness_persists_json_and_env(self):
        FakeBacklight(self.e)
        result = self.d.set_brightness(50)
        self.assertEqual(result["result"], "APPLIED")
        self.assertEqual(json.load(open(self.d.CONFIG))["brightness"], 50)
        env = open(self.d.ENV).read()
        self.assertIn('BRIGHTNESS="50"', env)
        self.assertIn('TOUCH_WAKE="1"', env)

    def test_brightness_while_asleep_saved_for_wake(self):
        bl = FakeBacklight(self.e, state="asleep")
        self.assertEqual(self.d.set_brightness(25)["result"], "SAVED_APPLIES_ON_WAKE")
        self.d.wake()
        self.assertIn("set 25", bl.call_log())

    def test_apply_failure_reported_level_still_persisted(self):
        FakeBacklight(self.e, set_rc=2)
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.d.set_brightness(75)
        self.assertEqual(cm.exception.code, "BRIGHTNESS_APPLY_FAILED")
        self.assertFalse(cm.exception.invalid)
        self.assertEqual(self.d.load_config()[0]["brightness"], 75)

    def test_sleep_refused_without_touch_wake_path(self):
        FakeBacklight(self.e, sleep_rc=4)
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.d.sleep()
        self.assertEqual(cm.exception.code, "SLEEP_UNAVAILABLE")

    def test_sleep_refused_when_touch_wake_disabled(self):
        bl = FakeBacklight(self.e)
        os.makedirs(self.d.DISPLAY_DIR)
        json.dump({"schema": 1, "brightness": 100, "touch_wake": False},
                  open(self.d.CONFIG, "w"))
        with self.assertRaises(self.e.common.OsConfigError):
            self.d.sleep()
        self.assertEqual(bl.call_log(), [])

    def test_sleep_writes_env_allowing_watcher_then_wake(self):
        bl = FakeBacklight(self.e)
        self.assertEqual(self.d.sleep()["result"], "ASLEEP")
        self.assertIn('TOUCH_WAKE="1"', open(self.d.ENV).read())
        self.assertEqual(self.d.wake()["result"], "AWAKE")
        self.assertEqual(bl.call_log()[:2], ["sleep", "status"])

    def test_corrupt_config_defaults(self):
        os.makedirs(self.d.DISPLAY_DIR)
        open(self.d.CONFIG, "w").write('{"schema":1,"brightness":33}')
        cfg, err = self.d.load_config()
        self.assertEqual(cfg["brightness"], 100)
        self.assertTrue(err)


def fake_geometry(bpp=32, layout=None, xres=48, yres=27, stride=None):
    return {"xres": xres, "yres": yres, "bpp": bpp,
            "stride": stride or xres * bpp // 8 + 8,
            "layout": layout or {"r": (16, 8), "g": (8, 8), "b": (0, 8)}}


class BootDisplayTests(unittest.TestCase):
    def setUp(self):
        self.e = Env()
        self.b = self.e.bootdisplay
        from PIL import Image
        self.Image = Image

    def tearDown(self):
        self.e.cleanup()

    def _png(self, name, size=(64, 32), colour=(255, 0, 0)):
        path = os.path.join(self.e.config_root, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.Image.new("RGB", size, colour).save(path, "PNG")
        return path

    def test_modes(self):
        self.assertEqual(self.b.set_mode("console")["config"]["mode"], "console")
        self.assertIn('MODE="console"', open(self.b.ENV).read())
        with self.assertRaises(self.e.common.OsConfigError):
            self.b.set_mode("splash; reboot")
        self.assertEqual(self.b.load_config()[0]["mode"], "console")

    def test_path_confinement(self):
        for bad in ("/etc/passwd", "../x.png", "a/../../x.png", "", None):
            with self.assertRaises(self.e.common.OsConfigError, msg=repr(bad)):
                self.b.resolve_config_path(bad)
        os.symlink("/etc", os.path.join(self.e.config_root, "evil"))
        with self.assertRaises(self.e.common.OsConfigError):
            self.b.resolve_config_path("evil/hostname")

    def test_image_validation(self):
        good = self._png("ok.png")
        self.assertEqual(self.b.validate_image_file(good)[0], "PNG")
        big = self._png("big.png", size=(2049, 10))
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.b.validate_image_file(big)
        self.assertEqual(cm.exception.code, "IMAGE_TOO_LARGE")
        jpg = os.path.join(self.e.config_root, "x.jpg")
        open(jpg, "wb").write(b"\xff\xd8\xff\xe0" + b"0" * 100)
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.b.validate_image_file(jpg)
        self.assertEqual(cm.exception.code, "IMAGE_FORMAT")
        trunc = os.path.join(self.e.config_root, "t.png")
        open(trunc, "wb").write(open(good, "rb").read()[:40])
        with self.assertRaises(self.e.common.OsConfigError):
            self.b.validate_image_file(trunc)
        huge = os.path.join(self.e.config_root, "huge.png")
        with open(huge, "wb") as handle:
            handle.write(b"\x89PNG\r\n\x1a\n")
            handle.truncate(self.b.MAX_FILE_BYTES + 1)
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.b.validate_image_file(huge)
        self.assertEqual(cm.exception.code, "IMAGE_TOO_LARGE")

    def test_decompression_bomb_rejected(self):
        # Small header-valid dimensions but a lot of pixels in total.
        bomb = self._png("bomb.png", size=(2048, 2048), colour=(0, 0, 0))
        old = self.b.MAX_PIXELS
        self.b.MAX_PIXELS = 1000
        try:
            with self.assertRaises(self.e.common.OsConfigError):
                self.b.validate_image_file(bomb)
        finally:
            self.b.MAX_PIXELS = old

    def test_to_framebuffer_32bpp_bgrx_and_stride(self):
        geo = fake_geometry()
        img = self.Image.new("RGB", (48, 27), (1, 2, 3))
        data = self.b.to_framebuffer(img, geo)
        self.assertEqual(len(data), geo["stride"] * 27)
        self.assertEqual(data[:4], bytes([3, 2, 1, 0]))          # B G R X
        self.assertEqual(data[48 * 4:geo["stride"]], b"\x00" * 8)  # stride pad

    def test_to_framebuffer_rgb565_generic(self):
        geo = fake_geometry(bpp=16, layout={"r": (11, 5), "g": (5, 6), "b": (0, 5)})
        img = self.Image.new("RGB", (48, 27), (255, 0, 0))
        data = self.b.to_framebuffer(img, geo)
        self.assertEqual(len(data), geo["stride"] * 27)
        self.assertEqual(struct.unpack("<H", data[:2])[0], 0xF800)

    def test_render_builtin_rotation_and_staleness(self):
        geo = fake_geometry(xres=96, yres=54)
        json.dump({"display_rotate": 2}, open(os.environ["NEBULAOS_GUPPY_CONFIG"], "w"))
        json.dump({"firmware_head": "abcdef0123"}, open(os.environ["NEBULAOS_SEED_MANIFEST"], "w"))
        r = self.b.render(geo=geo)
        self.assertEqual(r["result"], "RENDERED")
        self.assertEqual(os.path.getsize(self.b.RAW), geo["stride"] * 54)
        meta = open(self.b.META).read()
        for line in ('XRES="96"', 'ROTATE="2"', 'KIND="builtin"', 'SOURCE="builtin-1-abcdef0"'):
            self.assertIn(line, meta)
        self.assertEqual(self.b.render(if_stale=True, geo=geo)["result"], "UP_TO_DATE")
        self.assertEqual(self.b.render(if_stale=True, geo=fake_geometry(xres=100, yres=54))["result"],
                         "RENDERED")

    def test_set_image_copies_validates_and_renders(self):
        self._png("nebulaos/boot.png", colour=(0, 255, 0))
        old = self.b.fb_geometry
        self.b.fb_geometry = lambda: fake_geometry()
        try:
            r = self.b.set_image("nebulaos/boot.png")
        finally:
            self.b.fb_geometry = old
        self.assertEqual(r["config"]["image"], "custom")
        self.assertEqual(r["render"]["result"], "RENDERED")
        self.assertTrue(os.path.isfile(os.path.join(self.b.BOOT_DIR, "custom.png")))
        self.assertIn('KIND="custom"', open(self.b.META).read())
        r = self.b.reset_image()   # no framebuffer here: render deferred, choice kept
        self.assertEqual(r["config"]["image"], "builtin")
        self.assertEqual(r["render"]["result"], "RENDER_DEFERRED")
        self.assertIsNone(self.b.custom_path())

    def test_invalid_image_changes_nothing(self):
        open(os.path.join(self.e.config_root, "bad.png"), "wb").write(b"nope")
        with self.assertRaises(self.e.common.OsConfigError):
            self.b.set_image("bad.png")
        self.assertFalse(os.path.exists(self.b.CONFIG))
        self.assertIsNone(self.b.custom_path())


class CliContractTests(unittest.TestCase):
    def setUp(self):
        self.e = Env()

    def tearDown(self):
        self.e.cleanup()

    def run_cli(self, *argv):
        out = io.StringIO()
        old = sys.stdout
        sys.stdout = out
        try:
            rc = self.e.cli.main(list(argv))
        finally:
            sys.stdout = old
        lines = out.getvalue().splitlines()
        self.assertEqual(len(lines), 1, out.getvalue())
        return rc, json.loads(lines[0])

    def test_usage_and_unknown(self):
        self.assertEqual(self.run_cli()[0], 64)
        self.assertEqual(self.run_cli("network", "explode")[0], 64)
        self.assertEqual(self.run_cli("network", "status", "--x", "1")[0], 64)
        rc, out = self.run_cli("display", "set-brightness", "--level")
        self.assertEqual(rc, 64)
        self.assertFalse(out["ok"])

    def test_invalid_is_exit_1(self):
        rc, out = self.run_cli("network", "set-hostname", "--hostname", "bad_name")
        self.assertEqual((rc, out["ok"], out["error"]), (1, False, "INVALID_HOSTNAME"))
        rc, out = self.run_cli("network", "set-ipv4", "--json", "{nope")
        self.assertEqual(rc, 1)

    def test_internal_error_is_json(self):
        old = self.e.system.info
        self.e.system.info = lambda: 1 / 0
        try:
            rc, out = self.run_cli("system", "info")
        finally:
            self.e.system.info = old
        self.assertEqual((rc, out["error"]), (2, "INTERNAL"))

    def test_system_info(self):
        json.dump({"firmware_head": "f" * 40, "build_date": "x",
                   "seeds": {"klipper": {"seed_commit": "k"}}},
                  open(os.environ["NEBULAOS_SEED_MANIFEST"], "w"))
        open(os.environ["NEBULAOS_DATA_FS_STATE"], "w").write(
            "DATAFS_RESULT=CLEAN\nDATAFS_MOUNT=rw\nDATAFS_STATE_BEFORE='clean'\n")
        rc, out = self.run_cli("system", "info")
        self.assertEqual(rc, 0)
        self.assertEqual(out["build"]["klipper"], "k")
        self.assertEqual(out["storage"]["boot_check"]["result"], "CLEAN")
        self.assertEqual(out["storage"]["boot_check"]["state_before"], "clean")
        self.assertIn("free_bytes", out["storage"])

    def test_entry_script_runs(self):
        env = dict(os.environ, NEBULAOS_OSCONFIG_PYTHONPATH=PYLIB)
        import subprocess
        proc = subprocess.run([sys.executable, CLI, "boot-display", "status"],
                              capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(json.loads(proc.stdout)["ok"])


class ComponentTests(unittest.TestCase):
    """Loads nebulaos.py as moonraker.components.nebulaos against a stub."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.helper = os.path.join(self.tmp, "helper")
        self.log = os.path.join(self.tmp, "argv")
        write_exe(self.helper, """
            printf '%%s\\n' "$@" > "%(log)s"; echo "NEBULAOS_CONFIG_ROOT=$NEBULAOS_CONFIG_ROOT" >> "%(log)s"
            case "$1 $2" in
              "display set-brightness") echo '{"ok": false, "error": "INVALID_BRIGHTNESS", "message": "m"}'; exit 1 ;;
              "network set-ipv4") echo '{"ok": false, "error": "GATEWAY_UNREACHABLE_REVERTED", "message": "m"}'; exit 2 ;;
            esac
            echo '{"ok": true, "result": "APPLIED"}'
        """ % {"log": self.log})
        pkg = types.ModuleType("moonraker")
        pkg.__path__ = []
        comps = types.ModuleType("moonraker.components")
        comps.__path__ = [os.path.dirname(COMPONENT)]
        common = types.ModuleType("moonraker.common")

        class RequestType(object):
            GET, POST = 1, 2
        common.RequestType = RequestType
        sys.modules.update({"moonraker": pkg, "moonraker.components": comps,
                            "moonraker.common": common})
        sys.modules.pop("moonraker.components.nebulaos", None)
        self.mod = importlib.import_module("moonraker.components.nebulaos")
        test = self

        class ServerError(Exception):
            def __init__(self, msg, code=400):
                super().__init__(msg)
                self.status_code = code

        class FM(object):
            def get_directory(self, root):
                return "/cfg-root"

        class Server(object):
            def __init__(self):
                self.endpoints, self.events = {}, []

            def register_endpoint(self, path, rtype, cb):
                self.endpoints[path] = (rtype, cb)

            def register_notification(self, name):
                pass

            def send_event(self, name, data):
                self.events.append((name, data))

            def lookup_component(self, name, default=None):
                return FM()

            def error(self, msg, code=400):
                return ServerError(msg, code)

        class Config(object):
            def get_server(self):
                return test.server

            def get(self, key, default=None):
                return test.helper if key == "helper" else default

        self.server = Server()
        self.comp = self.mod.load_component(Config())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)
        for name in [n for n in sys.modules if n == "moonraker" or n.startswith("moonraker.")]:
            del sys.modules[name]

    class Req(object):
        def __init__(self, args):
            self.args = args

        def get_str(self, key, default=None):
            return str(self.args[key])

        def get_int(self, key, default=None):
            return int(self.args[key])

        def get_list(self, key, default=None):
            return self.args.get(key, default)

    def call(self, path, args=None):
        cb = self.server.endpoints[path][1]
        return asyncio.run(cb(self.Req(args or {})))

    def argv(self):
        return open(self.log).read().splitlines()

    def test_all_endpoints_registered_single_type(self):
        paths = set(self.server.endpoints)
        for p in ("info", "network/status", "network/hostname", "network/ipv4",
                  "boot_display/status", "boot_display/mode", "boot_display/image",
                  "boot_display/reset_image", "display/status", "display/brightness",
                  "display/sleep", "display/wake"):
            self.assertIn("/machine/nebulaos/" + p, paths)

    def test_argv_mapping_no_shell(self):
        self.call("/machine/nebulaos/network/hostname", {"hostname": "a; reboot"})
        self.assertEqual(self.argv()[:4], ["network", "set-hostname", "--hostname", "a; reboot"])
        self.assertIn("NEBULAOS_CONFIG_ROOT=/cfg-root", self.argv())
        self.call("/machine/nebulaos/display/wake")
        self.assertEqual(self.argv()[:2], ["display", "wake"])
        self.assertEqual(self.server.events[-1][0], "nebulaos:settings_changed")

    def test_static_ipv4_json(self):
        with self.assertRaises(Exception) as cm:
            self.call("/machine/nebulaos/network/ipv4",
                      {"mode": "static", "address": "10.0.0.5", "prefix": "24",
                       "gateway": "10.0.0.1", "dns": ["10.0.0.1"]})
        self.assertEqual(cm.exception.status_code, 500)
        self.assertIn("GATEWAY_UNREACHABLE_REVERTED", str(cm.exception))
        spec = json.loads(self.argv()[3])
        self.assertEqual(spec, {"mode": "static", "address": "10.0.0.5", "prefix": 24,
                                "gateway": "10.0.0.1", "dns": ["10.0.0.1"]})

    def test_invalid_maps_to_400(self):
        with self.assertRaises(Exception) as cm:
            self.call("/machine/nebulaos/display/brightness", {"level": 30})
        self.assertEqual(cm.exception.status_code, 400)

    def test_ok_result_strips_ok(self):
        out = self.call("/machine/nebulaos/info")
        self.assertEqual(out, {"result": "APPLIED"})


if __name__ == "__main__":
    unittest.main()
