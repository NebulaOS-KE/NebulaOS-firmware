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
import importlib.util
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
MCU_LIB = os.path.join(OVERLAY, "etc", "nebulaos")
MCU_TOOLS = os.path.join(OVERLAY, "opt", "nebulaos", "tools")
CANDIDATE = os.path.join(OVERLAY, "opt", "nebulaos", "mcu-candidates", "candidate-001.bin")


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
        self.config_root = os.path.join(self.tmp, "uploads")
        os.makedirs(self.config_root)
        os.environ.update({
            "NEBULAOS_ROOT": self.root, "NEBULAOS_OSCONFIG_RUN": self.run,
            "NEBULAOS_NETAPPLY": self.netapply,
            "NEBULAOS_BACKLIGHT_CLI": self.backlight,
            "NEBULAOS_BOOT_UPLOAD_DIR": self.config_root,
            "NEBULAOS_SEED_MANIFEST": os.path.join(self.tmp, "seed.json"),
            "NEBULAOS_GUPPY_CONFIG": os.path.join(self.tmp, "guppy.json"),
            "NEBULAOS_DATA_MOUNT": self.tmp,
            "NEBULAOS_DATA_FS_STATE": os.path.join(self.tmp, "datafs.state"),
            # Never the host's real framebuffer.
            "NEBULAOS_FB_SYSFS": os.path.join(self.tmp, "no-fb-sysfs"),
            "NEBULAOS_FB_DEV": os.path.join(self.tmp, "no-fb"),
            # Never the host's wpa_supplicant, OTA marker or data partition.
            "NEBULAOS_WPA_CTRL_DIR": os.path.join(self.tmp, "wpa"),
            "NEBULAOS_WIFI_SCAN_SECONDS": "2", "NEBULAOS_WIFI_CONNECT_SECONDS": "2",
            "NEBULAOS_WIFI_ADDRESS_SECONDS": "0.2",
            "NEBULAOS_CLEAN_RESET_FLAG": os.path.join(self.tmp, "data", ".nebulaos-clean-reset"),
            "NEBULAOS_CMDLINE": os.path.join(self.tmp, "cmdline"),
            "NEBULAOS_SLOT_SWAP": os.path.join(self.bin, "slot-swap"),
            # Wi-Fi re-addressing (G20/G5): never the host's udhcpc or arping.
            "NEBULAOS_UDHCPC_PIDFILE": os.path.join(self.tmp, "udhcpc.pid"),
            "NEBULAOS_ARPING": os.path.join(self.bin, "arping"),
            # MCU firmware (run 4): never the real upload dir, USB mount,
            # nebulaos-mcu or guard state.
            "NEBULAOS_MCU_UPLOAD_DIR": os.path.join(self.tmp, "mcu-upload"),
            "NEBULAOS_MCU_USB_DIR": os.path.join(self.tmp, "usb"),
            "NEBULAOS_MCU_BUILTIN": os.path.join(self.tmp, "builtin", "candidate-001.bin"),
            "NEBULAOS_MCU_LIB": MCU_LIB,
            "CREALITY_FLASH_PATH": MCU_TOOLS,
            "NEBULAOS_MCU_CLI": os.path.join(self.bin, "nebulaos-mcu"),
            "NEBULAOS_MCU_GUARD_STATE": os.path.join(self.tmp, "guard.state"),
            "NEBULAOS_MCU_MANAGED_FLAG": os.path.join(self.tmp, "data", "mcu", "managed"),
        })
        if PYLIB not in sys.path:
            sys.path.insert(0, PYLIB)
        for name in list(sys.modules):
            if name.startswith("nebulaos_osconfig"):
                del sys.modules[name]
        self.pkg = importlib.import_module("nebulaos_osconfig")
        for mod in ("common", "network", "display", "bootdisplay", "system", "wifi", "mcu", "image",
                    "cli"):
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
        self.assertEqual(self.b.set_mode("blank")["config"]["mode"], "blank")
        self.assertIn('MODE="blank"', open(self.b.ENV).read())
        with self.assertRaises(self.e.common.OsConfigError):
            self.b.set_mode("splash; reboot")
        self.assertEqual(self.b.load_config()[0]["mode"], "blank")
        self.assertEqual(self.b.status()["modes"], ["logo", "blank"])

    def test_console_retired(self):
        # D10 (2026-10-11): console can no longer be chosen; a saved one is logo.
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.b.set_mode("console")
        self.assertEqual(cm.exception.code, "INVALID_MODE")
        self.e.common.atomic_write_json(self.b.CONFIG, {"schema": 1, "mode": "console",
                                                         "image": "builtin"})
        cfg, error = self.b.load_config()
        self.assertEqual((cfg["mode"], error), ("logo", None))

    def test_upload_name_confinement(self):
        for bad in ("/etc/passwd", "../x.png", "a/b.png", "sub/../x.png", ".hidden.png",
                    "", None, "x" * 200, "a b.png", "a;reboot.png"):
            with self.assertRaises(self.e.common.OsConfigError, msg=repr(bad)) as cm:
                self.b.resolve_upload(bad)
            self.assertEqual(cm.exception.code, "INVALID_FILENAME")
        os.symlink("/etc/hostname", os.path.join(self.e.config_root, "evil.png"))
        with self.assertRaises(self.e.common.OsConfigError):
            self.b.resolve_upload("evil.png")
        self.assertEqual(self.b.resolve_upload("boot-1.png"),
                         os.path.join(os.path.realpath(self.e.config_root), "boot-1.png"))

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
        self._png("boot.png", colour=(0, 255, 0))
        old = self.b.fb_geometry
        self.b.fb_geometry = lambda: fake_geometry()
        try:
            r = self.b.set_image("boot.png")
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


class FakeTransport(object):
    def __init__(self, wpa):
        self.wpa, self.queue = wpa, []

    def send(self, data):
        self.wpa.receive(self, data.decode())

    def recv(self, timeout):
        return self.queue.pop(0).encode() if self.queue else None

    def close(self):
        self.wpa.attached.discard(self)


class FakeWpa(object):
    """An in-process wpa_supplicant control interface (the sandbox has no
    Unix sockets): enough of the protocol for the helper (STATUS, LIST/GET/
    ADD/SET/REMOVE/SELECT/ENABLE_NETWORK, SCAN, SCAN_RESULTS, SAVE_CONFIG,
    ATTACH/DETACH), replies first, then events to attached clients.
    `passwords` maps an SSID to the passphrase its access point accepts."""

    def __init__(self, wifi_module, scan, passwords, saved=(), wrong_event="temp-disabled"):
        self.wrong_event = wrong_event
        self.module = wifi_module
        self.real_transport = wifi_module.open_transport
        wifi_module.open_transport = lambda: FakeTransport(self)
        self.scan = scan            # [(ssid, signal, flags)]
        self.passwords = passwords
        self.nets = {}
        self.next_id = 0
        self.current = None
        self.saves = []
        self.commands = []
        self.attached = set()
        for ssid, pw in saved:
            nid = self._add()
            self.nets[nid]["ssid"] = ssid.encode()
            self.nets[nid]["psk"] = self._psk(ssid.encode(), pw)
        if self.nets:
            self.current = 0

    @staticmethod
    def _psk(raw, pw):
        import hashlib
        return hashlib.pbkdf2_hmac("sha1", pw.encode(), raw, 4096, 32).hex()

    def _add(self):
        nid = self.next_id
        self.next_id += 1
        self.nets[nid] = {"ssid": b"", "psk": None, "key_mgmt": "WPA-PSK", "disabled": False}
        return nid

    def close(self):
        self.module.open_transport = self.real_transport

    def _event(self, text):
        for t in list(self.attached):
            t.queue.append(text)

    def receive(self, t, cmd):
        self.commands.append(cmd)
        reply, after = self._handle(cmd, t)
        t.queue.append(reply)
        if after:
            after()

    def _ssid_out(self, raw):
        if all(32 <= b < 127 for b in raw):
            return '"%s"' % raw.decode()
        return raw.hex()

    def _handle(self, cmd, addr):
        parts = cmd.split(" ")
        verb = parts[0]
        if verb == "ATTACH":
            self.attached.add(addr)
            return "OK\n", None
        if verb == "DETACH":
            self.attached.discard(addr)
            return "OK\n", None
        if verb == "STATUS":
            if self.current is None:
                return "wpa_state=DISCONNECTED\n", None
            n = self.nets[self.current]
            return "wpa_state=COMPLETED\nid=%d\nssid=%s\nkey_mgmt=WPA2-PSK\n" % (
                self.current, n["ssid"].decode("utf-8", "replace")), None
        if verb == "LIST_NETWORKS":
            lines = ["network id / ssid / bssid / flags"]
            for nid, n in sorted(self.nets.items()):
                flags = "[CURRENT]" if nid == self.current else ("[DISABLED]" if n["disabled"] else "")
                lines.append("%d\t%s\tany\t%s" % (nid, n["ssid"].decode("utf-8", "replace"), flags))
            return "\n".join(lines) + "\n", None
        if verb == "GET_NETWORK":
            return self._ssid_out(self.nets[int(parts[1])]["ssid"]), None
        if verb == "ADD_NETWORK":
            return "%d\n" % self._add(), None
        if verb == "SET_NETWORK":
            n = self.nets.get(int(parts[1]))
            if n is None:
                return "FAIL\n", None
            if parts[2] == "ssid":
                n["ssid"] = bytes.fromhex(parts[3])
            elif parts[2] == "psk":
                n["psk"] = parts[3]
            elif parts[2] == "key_mgmt":
                n["key_mgmt"] = parts[3]
            return "OK\n", None
        if verb == "REMOVE_NETWORK":
            self.nets.pop(int(parts[1]), None)
            if self.current == int(parts[1]):
                self.current = None
            return "OK\n", None
        if verb == "ENABLE_NETWORK":
            for n in self.nets.values():
                n["disabled"] = False
            return "OK\n", None
        if verb == "SELECT_NETWORK":
            nid = int(parts[1])
            for other, n in self.nets.items():
                n["disabled"] = other != nid
            return "OK\n", lambda: self._try(nid)
        if verb == "SCAN":
            return "OK\n", lambda: self._event("<3>CTRL-EVENT-SCAN-RESULTS ")
        if verb == "SCAN_RESULTS":
            lines = ["bssid / frequency / signal level / flags / ssid"]
            for i, (ssid, sig, flags) in enumerate(self.scan):
                lines.append("aa:bb:cc:dd:ee:%02x\t2412\t%d\t%s\t%s" % (i, sig, flags, ssid))
            return "\n".join(lines) + "\n", None
        if verb == "SAVE_CONFIG":
            self.saves.append({nid: dict(n) for nid, n in self.nets.items()})
            return "OK\n", None
        return "UNKNOWN COMMAND\n", None

    def _try(self, nid):
        n = self.nets[nid]
        ssid = n["ssid"].decode("utf-8", "replace")
        if ssid not in self.passwords:
            return                                  # not in range: no event
        pw = self.passwords[ssid]
        ok = (n["key_mgmt"] == "NONE" and pw is None) or (
            pw is not None and n["psk"] == self._psk(n["ssid"], pw))
        if ok:
            self.current = nid
            self._event("<3>CTRL-EVENT-CONNECTED - Connection to aa:bb completed [id=%d id_str=]" % nid)
        elif self.wrong_event == "reason15":
            # What the BCM43430 reports first: a locally caused disconnect
            # from the old network (must not count), then reason 15.
            self._event("<3>CTRL-EVENT-DISCONNECTED bssid=aa:bb reason=3 locally_generated=1")
            self._event("<3>CTRL-EVENT-DISCONNECTED bssid=aa:bb reason=15")
        else:
            self._event('<3>CTRL-EVENT-SSID-TEMP-DISABLED id=%d ssid="%s" auth_failures=1 '
                        'duration=10 reason=WRONG_KEY' % (nid, ssid))


class WifiTests(unittest.TestCase):
    SCAN = [("Home", -50, "[WPA2-PSK-CCMP][ESS]"), ("Home", -70, "[WPA2-PSK-CCMP][ESS]"),
            ("Cafe", -60, "[ESS]"), ("Office\\x20\\xe2\\x9c\\x93", -65, "[WPA2-PSK-CCMP][ESS]"),
            ("", -40, "[ESS]"), ("Corp", -55, "[WPA2-EAP-CCMP][ESS]")]

    def setUp(self):
        self.e = Env()
        self.w = self.e.wifi
        self.calls = self.e.netapply_script([0])

    def tearDown(self):
        if getattr(self, "wpa", None):
            self.wpa.close()
        self.e.cleanup()

    def fake(self, passwords, saved=(), **kw):
        self.wpa = FakeWpa(self.w, self.SCAN, passwords, saved, **kw)
        return self.wpa

    def fake_udhcpc(self):
        """A child process standing in for udhcpc: records USR1/USR2. It says
        "ready" on stdout once its handlers are in place (a blocking read: other
        tests in this file replace time.sleep)."""
        import subprocess
        log = os.path.join(self.e.tmp, "udhcpc.signals")
        code = ("import os,signal,sys,time\n"
                "def h(n,f):\n"
                "    with open(sys.argv[1],'a') as fh: fh.write(str(n)+'\\n')\n"
                "signal.signal(signal.SIGUSR1,h); signal.signal(signal.SIGUSR2,h)\n"
                "print('ready', flush=True)\n"
                "for _ in range(600): signal.pause() if hasattr(signal,'pause') else time.sleep(1)\n")
        proc = subprocess.Popen([sys.executable, "-c", code, log], stdout=subprocess.PIPE)
        self.assertEqual(proc.stdout.readline().strip(), b"ready")
        open(os.environ["NEBULAOS_UDHCPC_PIDFILE"], "w").write("%d\n" % proc.pid)
        self.addCleanup(proc.stdout.close)
        self.addCleanup(proc.kill)
        return log

    def signals_seen(self, log, want):
        """Waits (by real wall-clock polling) until `want` signals were logged."""
        import select
        for _ in range(200):
            if os.path.exists(log) and len(open(log).read().split()) >= want:
                break
            select.select([], [], [], 0.05)
        return open(log).read().split() if os.path.exists(log) else []

    def test_parse_scan(self):
        nets = self.w.parse_scan_results("h\n" + "\n".join(
            "aa\t2412\t%d\t%s\t%s" % (sig, fl, ss) for ss, sig, fl in self.SCAN))
        self.assertEqual([n["ssid"] for n in nets], ["Home", "Corp", "Cafe", "Office ✓"])
        self.assertEqual(nets[0]["signal"], -50)
        self.assertEqual({n["ssid"]: n["security"] for n in nets},
                         {"Home": "psk", "Corp": "eap", "Cafe": "open", "Office ✓": "psk"})

    def test_psk(self):
        # IEEE 802.11i test vector.
        self.assertEqual(self.w.psk_for(b"IEEE", "password"),
                         "f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e")
        self.assertEqual(self.w.psk_for(b"x", "A" * 64), "a" * 64)
        for bad in ("short", "x" * 64, 5):
            with self.assertRaises(self.e.common.OsConfigError):
                self.w.psk_for(b"x", bad)

    def test_unavailable(self):
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.w.status()
        self.assertEqual(cm.exception.code, "WIFI_UNAVAILABLE")

    def test_status_and_scan(self):
        self.fake({"Home": "secret123"}, saved=[("Home", "secret123")])
        st = self.w.status()
        self.assertEqual((st["status"]["state"], st["status"]["ssid"]), ("COMPLETED", "Home"))
        self.assertEqual(st["saved"], [{"id": 0, "ssid": "Home", "current": True, "disabled": False}])
        sc = self.w.scan()
        self.assertTrue(sc["complete"])
        home = [n for n in sc["networks"] if n["ssid"] == "Home"][0]
        self.assertTrue(home["saved"] and home["current"])
        self.assertFalse([n for n in sc["networks"] if n["ssid"] == "Cafe"][0]["saved"])

    def test_connect_new_network_saves_only_after_success(self):
        wpa = self.fake({"Home": "secret123", "Office ✓": "pa\"ss word"},
                        saved=[("Home", "secret123")])
        out = self.w.connect({"ssid": "Office ✓", "password": "pa\"ss word"})
        self.assertEqual((out["result"], out["ssid"]), ("CONNECTED", "Office ✓"))
        self.assertEqual(len(wpa.saves), 1)
        saved = wpa.saves[0]
        self.assertEqual(sorted(n["ssid"] for n in saved.values()), [b"Home", "Office ✓".encode()])
        self.assertFalse(any(n["disabled"] for n in saved.values()))
        # Hex SSID and hex PSK only: no passphrase or quote ever sent.
        self.assertFalse([c for c in wpa.commands if "pa\"ss" in c or "ss word" in c])
        self.assertTrue(open(self.calls).read().startswith("apply"))   # no udhcpc: full apply
        self.assertEqual(out["address_mode"], "dhcp")

    def test_dhcp_renew_without_link_bounce(self):
        # G20: a running udhcpc is asked to release + renew; no netapply (no
        # ifdown/ifup), so wpa_supplicant never gets to reselect a network.
        log = self.fake_udhcpc()
        self.fake({"Home": "secret123", "Cafe": None}, saved=[("Home", "secret123")])
        out = self.w.connect({"ssid": "Cafe"})
        self.assertEqual((out["result"], out["ssid"]), ("CONNECTED", "Cafe"))
        import signal as _s
        # Both arrive; their order is enforced by waiting for the release
        # (this host has no wlan0 address, so that wait ends at once).
        self.assertEqual(sorted(self.signals_seen(log, 2)),
                         sorted([str(int(_s.SIGUSR2)), str(int(_s.SIGUSR1))]))
        self.assertFalse(os.path.exists(self.calls))                     # no apply

    def test_static_address_checked_on_new_network(self):
        # G5: static mode keeps the address and reports when the gateway is silent.
        self.e.common.atomic_write_json(self.e.network.CONFIG, {"schema": 1, "hostname": "nebulaos",
            "ipv4": {"mode": "static", "address": "10.0.0.5", "prefix": 24,
                     "gateway": "10.0.0.1", "dns": []}})
        write_exe(os.environ["NEBULAOS_ARPING"], "exit 1\n")
        self.fake({"Home": "secret123", "Cafe": None}, saved=[("Home", "secret123")])
        out = self.w.connect({"ssid": "Cafe"})
        self.assertEqual((out["address_mode"], out["address_ok"]), ("static", False))
        self.assertIn("switch to DHCP", out["address_note"])
        write_exe(os.environ["NEBULAOS_ARPING"], "exit 0\n")
        out = self.w.connect({"ssid": "Home"})
        self.assertEqual((out["address_mode"], out["address_ok"], out["address_note"]),
                         ("static", True, None))

    def test_wrong_password_reason15(self):
        # G21: the BCM43430 reports disconnect reason 15, not WRONG_KEY.
        wpa = self.fake({"Home": "secret123", "Office \u2713": "right-one"},
                        saved=[("Home", "secret123")], wrong_event="reason15")
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.w.connect({"ssid": "Office \u2713", "password": "wrong-one"})
        self.assertEqual(cm.exception.code, "WRONG_PASSWORD")
        self.assertEqual(wpa.current, 0)
        self.assertFalse(self.w._wrong_key_event(
            "<3>CTRL-EVENT-DISCONNECTED bssid=aa reason=3 locally_generated=1", 1))
        self.assertTrue(self.w._wrong_key_event(
            "<3>WPA: 4-Way Handshake failed - pre-shared key may be incorrect", 1))
        self.assertFalse(self.w._wrong_key_event("<3>CTRL-EVENT-DISCONNECTED bssid=aa reason=150", 1))

    def test_wrong_password_reverts(self):
        wpa = self.fake({"Home": "secret123", "Office ✓": "right-one"},
                        saved=[("Home", "secret123")])
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.w.connect({"ssid": "Office ✓", "password": "wrong-one"})
        self.assertEqual(cm.exception.code, "WRONG_PASSWORD")
        self.assertEqual(wpa.saves, [])
        self.assertEqual(sorted(n["ssid"] for n in wpa.nets.values()), [b"Home"])
        self.assertEqual(wpa.current, 0)
        self.assertFalse(any(n["disabled"] for n in wpa.nets.values()))

    def test_timeout_reverts(self):
        wpa = self.fake({"Home": "secret123"}, saved=[("Home", "secret123")])
        wpa.scan = wpa.scan + [("Far", -90, "[WPA2-PSK-CCMP][ESS]")]
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.w.connect({"ssid": "Far", "password": "whatever1"})
        self.assertEqual(cm.exception.code, "CONNECT_TIMEOUT")
        self.assertEqual([n["ssid"] for n in wpa.nets.values()], [b"Home"])

    def test_open_saved_and_refusals(self):
        wpa = self.fake({"Home": "secret123", "Cafe": None}, saved=[("Home", "secret123")])
        self.assertEqual(self.w.connect({"ssid": "Cafe"})["result"], "CONNECTED")
        self.assertEqual([n["key_mgmt"] for n in wpa.nets.values() if n["ssid"] == b"Cafe"], ["NONE"])
        self.assertEqual(self.w.connect({"ssid": "Home"})["result"], "CONNECTED")   # saved, no password
        for spec, code in (({"ssid": "Corp", "password": "whatever1"}, "UNSUPPORTED_SECURITY"),
                           ({"ssid": "Office ✓"}, "PASSWORD_REQUIRED"),
                           ({"ssid": "x" * 33, "password": "whatever1"}, "INVALID_SSID"),
                           ({"ssid": ""}, "INVALID_SSID")):
            with self.assertRaises(self.e.common.OsConfigError, msg=spec) as cm:
                self.w.connect(spec)
            self.assertEqual(cm.exception.code, code)

    def test_forget(self):
        wpa = self.fake({"Home": "secret123"}, saved=[("Home", "secret123"), ("Old", "whatever1")])
        self.assertEqual(self.w.forget("Old")["removed"], 1)
        self.assertEqual([n["ssid"] for n in wpa.saves[-1].values()], [b"Home"])
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.w.forget("Old")
        self.assertEqual(cm.exception.code, "NOT_SAVED")

    def test_changes_are_logged_without_secrets(self):
        # G27: one system-log line per change; never the password; reads silent.
        lines = []
        fake = types.ModuleType("syslog")
        fake.LOG_NOTICE, fake.LOG_WARNING = 5, 4
        fake.openlog = lambda *a, **k: None
        fake.closelog = lambda: None
        fake.syslog = lambda prio, msg: lines.append((prio, msg))
        old = sys.modules.get("syslog")
        sys.modules["syslog"] = fake
        try:
            self.fake({"Home": "secret123", "Cafe": None}, saved=[("Home", "secret123")])
            stdin = sys.stdin
            sys.stdin = io.StringIO(json.dumps({"ssid": "Home", "password": "secret123"}))
            try:
                CliContractTests.run_cli(self, "wifi", "connect", "--stdin")
            finally:
                sys.stdin = stdin
            CliContractTests.run_cli(self, "wifi", "status")
            CliContractTests.run_cli(self, "network", "set-hostname", "--hostname", "bad_name")
        finally:
            if old is None:
                del sys.modules["syslog"]
            else:
                sys.modules["syslog"] = old
        text = " | ".join(m for _, m in lines)
        self.assertEqual(len(lines), 2, text)                       # status not logged
        self.assertIn("wifi connect ok result=CONNECTED ssid=Home", text)
        self.assertNotIn("secret123", text)
        self.assertIn("network set-hostname hostname=bad_name FAILED INVALID_HOSTNAME", text)
        self.assertEqual(lines[1][0], 4)

    def test_cli_connect_reads_stdin_only(self):
        self.fake({"Home": "secret123"})
        rc, out = CliContractTests.run_cli(self, "wifi", "connect", "--ssid", "Home")
        self.assertEqual((rc, out["error"]), (64, "USAGE"))
        old = sys.stdin
        sys.stdin = io.StringIO(json.dumps({"ssid": "Home", "password": "secret123"}))
        try:
            rc, out = CliContractTests.run_cli(self, "wifi", "connect", "--stdin")
        finally:
            sys.stdin = old
        self.assertEqual((rc, out["result"]), (0, "CONNECTED"))


class SystemResetSlotTests(unittest.TestCase):
    def setUp(self):
        self.e = Env()
        self.s = self.e.system
        self.log = os.path.join(self.e.tmp, "swap.log")
        write_exe(os.environ["NEBULAOS_SLOT_SWAP"], 'echo "$1" >> "%s"\n[ -f "%s.fail" ] && exit 2\nexit 0\n'
                  % (self.log, self.log))

    def tearDown(self):
        self.e.cleanup()

    def cmdline(self, root):
        open(os.environ["NEBULAOS_CMDLINE"], "w").write(
            "console=ttyS2,115200 rootfstype=squashfs root=%s rw\n" % root)

    def test_slot_and_info(self):
        self.cmdline("/dev/mmcblk0p8")
        self.assertEqual(self.s.boot_slot(), "B")
        self.cmdline("/dev/mmcblk0p7")
        self.assertEqual(self.s.boot_slot(), "A")
        self.cmdline("/dev/sda1")
        self.assertIsNone(self.s.boot_slot())
        info = self.s.info()
        self.assertIn("slot", info)
        self.assertFalse(info["clean_reset_pending"])

    def test_after_clean_reset_marker(self):
        # G2: info reports the marker until the screen acknowledges it.
        self.assertIsNone(self.s.info()["after_clean_reset"])
        os.makedirs(os.path.dirname(self.s.AFTER_RESET_MARKER), exist_ok=True)
        open(self.s.AFTER_RESET_MARKER, "w").write("2026-10-12T01:00:00Z\n")
        self.assertEqual(self.s.info()["after_clean_reset"], "2026-10-12T01:00:00Z")
        self.assertEqual(self.s.ack_clean_reset()["result"], "ACKNOWLEDGED")
        self.assertIsNone(self.s.info()["after_clean_reset"])
        self.s.ack_clean_reset()      # idempotent

    def test_clean_reset_flag(self):
        self.assertEqual(self.s.request_clean_reset()["result"], "SCHEDULED")
        self.assertTrue(open(self.s.CLEAN_RESET_FLAG).read().startswith("requested="))
        self.assertTrue(self.s.info()["clean_reset_pending"])
        self.s.cancel_clean_reset()
        self.assertFalse(os.path.exists(self.s.CLEAN_RESET_FLAG))
        self.s.cancel_clean_reset()     # idempotent

    def test_swap_either_slot(self):
        # 2026-10-14: NebulaOS may run from either slot; swap goes to the other.
        self.cmdline("/dev/mmcblk0p8")
        self.assertEqual(self.s.swap_slot()["next_boot"], "A")
        self.s.keep_slot()
        self.cmdline("/dev/mmcblk0p7")
        self.assertEqual(self.s.swap_slot()["next_boot"], "B")
        self.assertEqual(open(self.log).read().split(), ["A", "B", "B"])
        self.cmdline("/dev/sda1")
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.s.swap_slot()
        self.assertEqual(cm.exception.code, "SLOT_UNKNOWN")
        self.cmdline("/dev/mmcblk0p8")
        open(self.log + ".fail", "w").close()
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.s.swap_slot()
        self.assertEqual(cm.exception.code, "SLOT_SWAP_FAILED")


def candidate_bytes():
    with open(CANDIDATE, "rb") as handle:
        return handle.read()


def raw_of(packed):
    """What `make` in NebulaOS-klipper-mcu produces before packing: the 16
    metadata bytes are the 0xFF placeholder."""
    data = bytearray(packed)
    data[0x200:0x210] = b"\xff" * 16
    return bytes(data)


class McuImageTests(unittest.TestCase):
    """mcu_image: what may be flashed, and the raw -> Creality packing."""

    def setUp(self):
        self.e = Env()
        self.img = self.e.mcu._image_module()
        self.packed = candidate_bytes()

    def tearDown(self):
        self.e.cleanup()

    def test_packed_and_raw_accepted(self):
        self.assertEqual(self.img.classify(self.packed), ("packed", None))
        self.assertEqual(self.img.classify(raw_of(self.packed)), ("raw", None))

    def test_packing_a_raw_build_reproduces_the_shipped_image(self):
        # candidate-001's provenance: raw and packed differ only in the header,
        # packed with version 900 - so packing its raw form must give it back.
        raw = raw_of(self.packed)
        self.assertEqual(self.img.sha256(raw),
                         "add546c7dd626c70a86ec33283cccdf4ad7956916d736af6b96f989b1b4188bd")
        kind, image = self.img.prepare(raw)
        self.assertEqual(kind, "raw")
        self.assertEqual(image, self.packed)
        self.assertEqual(self.img.prepare(self.packed), ("packed", self.packed))

    def test_rejected(self):
        p = self.packed
        bad_crc = bytearray(p)
        bad_crc[0x1000] ^= 0xFF
        other_board = bytearray(p)
        other_board[0x200:0x204] = b"noz0"
        no_header = bytearray(p)
        no_header[0x200:0x210] = bytes(range(16))     # code, like upstream Klipper
        wrong_slot = bytearray(raw_of(p))
        wrong_slot[4:8] = (0x08000101).to_bytes(4, "little")   # reset into the bootloader
        cases = {
            b"": "empty", b"\x00" * 100: "too small",
            bytes(p) + b"\x00" * 70000: "too large",
            bytes(bad_crc): "damaged", bytes(other_board): "another board",
            bytes(no_header): "no Creality header", bytes(wrong_slot): "mainboard",
        }
        for data, why in cases.items():
            kind, reason = self.img.classify(data)
            self.assertIsNone(kind, why)
            self.assertIn(why, reason)
            with self.assertRaises(self.img.ImageError):
                self.img.prepare(data)


class McuFilesTests(unittest.TestCase):
    """mcu status / list / flash with a fake nebulaos-mcu."""

    def setUp(self):
        self.e = Env()
        self.m = self.e.mcu
        self.packed = candidate_bytes()
        self.upload = os.environ["NEBULAOS_MCU_UPLOAD_DIR"]
        self.usb = os.environ["NEBULAOS_MCU_USB_DIR"]
        os.makedirs(self.upload)
        os.makedirs(os.path.join(self.usb, "sda1", "firmware"))
        builtin = os.environ["NEBULAOS_MCU_BUILTIN"]
        os.makedirs(os.path.dirname(builtin))
        shutil.copy(CANDIDATE, builtin)
        self.cli_log = os.path.join(self.e.tmp, "mcu-cli.log")
        self.fake_cli(0, "MCU firmware flashed successfully.")

    def tearDown(self):
        self.e.cleanup()

    def fake_cli(self, rc, out, err=""):
        write_exe(os.environ["NEBULAOS_MCU_CLI"], """
            echo "$@" >> "%(log)s"
            cp "$2" "%(log)s.image"
            echo "Stopping Klipper (required before any MCU serial operation)..."
            echo "%(out)s"
            [ -n "%(err)s" ] && echo "%(err)s" >&2
            [ %(rc)d -ne 0 ] && echo "Flash failed. MCU ownership unchanged." >&2
            echo "Restarting Klipper..."
            exit %(rc)d
        """ % {"log": self.cli_log, "out": out, "err": err, "rc": rc})

    def put(self, path, data):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(data)

    def test_list(self):
        self.put(os.path.join(self.upload, "klipper.bin"), raw_of(self.packed))
        self.put(os.path.join(self.upload, "notes.txt"), b"x")
        self.put(os.path.join(self.upload, ".hidden.bin"), self.packed)
        self.put(os.path.join(self.upload, "junk.bin"), b"\x00" * 4096)
        os.symlink("/etc/passwd", os.path.join(self.upload, "link.bin"))
        self.put(os.path.join(self.usb, "sda1", "firmware", "KE.BIN"), self.packed)
        self.put(os.path.join(self.usb, "sda1", "a", "b", "deep.bin"), self.packed)
        out = self.m.list_files()
        ids = [f["id"] for f in out["files"]]
        self.assertEqual(ids, ["upload/junk.bin", "upload/klipper.bin",
                               "usb/sda1/firmware/KE.BIN"])
        junk, raw, usb = out["files"]
        self.assertFalse(junk["valid"])
        self.assertIn("no Creality header", junk["problem"])
        self.assertEqual((raw["valid"], raw["kind"], raw["native"]), (True, "raw", False))
        self.assertEqual((usb["valid"], usb["kind"], usb["native"], usb["source"]),
                         (True, "packed", True, "usb"))
        self.assertEqual(out["builtin"]["id"], "builtin/candidate-001.bin")
        self.assertEqual(out["usb"], ["sda1"])

    def test_big_file_not_read(self):
        with open(os.path.join(self.upload, "huge.bin"), "wb") as handle:
            handle.truncate(5 << 20)
        f = self.m.list_files()["files"][0]
        self.assertFalse(f["valid"])
        self.assertIsNone(f["sha256"])
        self.assertIn("too large", f["problem"])

    def test_resolve_stays_inside(self):
        outside = os.path.join(self.e.tmp, "secret.bin")
        self.put(outside, self.packed)
        os.symlink(outside, os.path.join(self.upload, "escape.bin"))
        os.symlink(self.e.tmp, os.path.join(self.usb, "sda1", "up"))
        for bad in ("", "upload/../secret.bin", "../secret.bin", "/etc/passwd",
                    "upload/escape.bin", "usb/sda1/up/secret.bin", "builtin/other.bin",
                    "elsewhere/x.bin", "upload/a/b.bin", "usb/sda1", "upload/",
                    "usb/sda1/a/b/c.bin", None):
            with self.assertRaises(self.e.common.OsConfigError, msg=repr(bad)):
                self.m.resolve(bad)
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.m.resolve("upload/missing.bin")
        self.assertEqual(cm.exception.code, "FILE_NOT_FOUND")

    def test_flash_raw_is_packed_staged_and_recorded(self):
        raw = raw_of(self.packed)
        self.put(os.path.join(self.upload, "klipper.bin"), raw)
        sha = self.m.list_files()["files"][0]["sha256"]
        out = self.m.flash("upload/klipper.bin", sha)
        self.assertEqual((out["result"], out["kind"]), ("FLASHED", "raw"))
        args = open(self.cli_log).read().split()
        self.assertEqual(args[0], "flash")
        self.assertTrue(args[1].startswith(os.path.join(self.e.run, "mcu") + os.sep))
        self.assertEqual(open(self.cli_log + ".image", "rb").read(), self.packed)
        self.assertFalse(os.path.exists(args[1]))            # staged copy removed
        last = self.m.status()["last_flash"]
        self.assertEqual((last["file"], last["ok"], last["kind"]),
                         ("upload/klipper.bin", True, "raw"))

    def test_flash_refuses_before_the_cli(self):
        self.put(os.path.join(self.upload, "junk.bin"), b"\x00" * 4096)
        self.put(os.path.join(self.upload, "ok.bin"), self.packed)
        junk_sha = self.e.mcu._image_module().sha256(b"\x00" * 4096)
        cases = [("upload/junk.bin", junk_sha, "INVALID_FIRMWARE"),
                 ("upload/ok.bin", "0" * 64, "FILE_CHANGED"),
                 ("upload/ok.bin", "nope", "INVALID_FILE")]
        for file_id, sha, code in cases:
            with self.assertRaises(self.e.common.OsConfigError) as cm:
                self.m.flash(file_id, sha)
            self.assertEqual((cm.exception.code, cm.exception.invalid), (code, True))
        self.assertFalse(os.path.exists(self.cli_log))

    def test_flash_failure_reason_and_refusal(self):
        self.put(os.path.join(self.upload, "ok.bin"), self.packed)
        sha = self.e.mcu._image_module().sha256(self.packed)
        self.fake_cli(1, "Flashing...", "Hardware identity mismatch: 'xyz'")
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.m.flash("upload/ok.bin", sha)
        self.assertEqual(cm.exception.code, "FLASH_FAILED")
        self.assertEqual(cm.exception.message, "Hardware identity mismatch: 'xyz'")
        self.assertIn("Restarting Klipper", cm.exception.extra["log"])
        self.assertFalse(self.m.status()["last_flash"]["ok"])
        self.fake_cli(1, "", "REFUSED: Printer is printing. Cannot flash MCU during a print.")
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.m.flash("upload/ok.bin", sha)
        self.assertEqual(cm.exception.code, "REFUSED")

    def test_second_flash_is_refused_not_queued(self):
        self.put(os.path.join(self.upload, "ok.bin"), self.packed)
        sha = self.e.mcu._image_module().sha256(self.packed)
        os.makedirs(os.path.join(self.e.run, "mcu"))
        import fcntl
        fd = os.open(os.path.join(self.e.run, "mcu", "flash.lock"), os.O_RDWR | os.O_CREAT)
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            with self.assertRaises(self.e.common.OsConfigError) as cm:
                self.m.flash("upload/ok.bin", sha)
            self.assertEqual(cm.exception.code, "BUSY")
        finally:
            os.close(fd)
        self.assertFalse(os.path.exists(self.cli_log))

    def test_builtin_reinstall(self):
        sha = self.m.list_files()["builtin"]["sha256"]
        self.fake_cli(0, "NebulaOS native firmware installed. Auto-restore enabled.")
        out = self.m.flash("builtin/candidate-001.bin", sha)
        self.assertTrue(out["native"])
        self.assertEqual(open(self.cli_log + ".image", "rb").read(), self.packed)

    def test_status(self):
        self.assertEqual(self.m.status()["guard"], None)
        self.assertTrue(self.m.status()["managed"])
        with open(os.environ["NEBULAOS_MCU_GUARD_STATE"], "w") as handle:
            handle.write("MCU_GUARD_RESULT=PASS\nMCU_GUARD_DETAIL='it'\\''s fine'\n"
                         "MCU_LIFECYCLE_STATE=SUPPORTED_HW_NATIVE_APP\n"
                         "MCU_APPLICATION_CLASS=NATIVE_CANDIDATE_001\n"
                         "MCU_APPLICATION_IDENTITY=v0.13.0-742-g01a9c2f92\n")
        flag = os.environ["NEBULAOS_MCU_MANAGED_FLAG"]
        os.makedirs(os.path.dirname(flag), exist_ok=True)
        open(flag, "w").write("false\n")
        st = self.m.status()
        self.assertEqual(st["guard"]["application_class"], "NATIVE_CANDIDATE_001")
        self.assertEqual(st["guard"]["result"], "PASS")
        self.assertFalse(st["managed"])

    def test_cli_contract(self):
        out = io.StringIO()
        old, sys.stdout = sys.stdout, out
        try:
            rc = self.e.cli.main(["mcu", "flash", "--file", "upload/none.bin",
                                  "--sha256", "0" * 64])
            rc_list = self.e.cli.main(["mcu", "list"])
        finally:
            sys.stdout = old
        first, second = [json.loads(l) for l in out.getvalue().splitlines()]
        self.assertEqual((rc, first["error"]), (1, "FILE_NOT_FOUND"))
        self.assertEqual((rc_list, second["ok"]), (0, True))


class McuFlashFileTests(unittest.TestCase):
    """mcu_flash_file.py (the CLI's flash step) against a fake bootloader:
    an image that is not firmware for this board never reaches the MCU, and a
    raw build is packed before it is sent."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.events = []
        test = self

        class FlashError(Exception):
            pass

        fake = types.ModuleType("creality_flash")
        fake.FlashError = FlashError
        fake.DEFAULT_ALLOWED_HW_IDS = ("mcu0_001_G32",)
        fake.SerialTransport = lambda *a, **k: object()
        fake.handshake = lambda t: test.events.append("handshake") or True
        fake.get_version = lambda t: "mcu0_001_G32-mcu0_005_000"
        fake.check_identity = lambda v: v.startswith("mcu0_001_G32")
        fake.get_sector_size = lambda t: 2
        fake.flash_image = lambda t, image, s: test.events.append(("flash", image)) or True
        fake.app_start = lambda t: test.events.append("app_start") or True
        restart = types.ModuleType("mcu_restart")
        restart.request_generic_restart = lambda p, b: test.events.append("restart") or "reset"
        self.saved = {n: sys.modules.get(n) for n in ("creality_flash", "mcu_restart")}
        sys.modules.update({"creality_flash": fake, "mcu_restart": restart})
        os.environ["CREALITY_FLASH_PATH"] = MCU_TOOLS
        spec = importlib.util.spec_from_file_location(
            "mcu_flash_file_under_test", os.path.join(MCU_LIB, "mcu_flash_file.py"))
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)
        self.mod.time.sleep = lambda s: None

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)
        for name, mod in self.saved.items():
            if mod is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = mod

    def run_main(self, data):
        path = os.path.join(self.tmp, "fw.bin")
        with open(path, "wb") as handle:
            handle.write(data)
        old_argv, old_out, old_err = sys.argv, sys.stdout, sys.stderr
        sys.argv = ["mcu_flash_file.py", path]
        sys.stdout = sys.stderr = io.StringIO()
        try:
            rc = self.mod.main()
            text = sys.stdout.getvalue()
        finally:
            sys.argv, sys.stdout, sys.stderr = old_argv, old_out, old_err
        return rc, text

    def test_not_firmware_never_touches_the_mcu(self):
        rc, text = self.run_main(b"\x00" * 4096)
        self.assertEqual(rc, 1)
        self.assertIn("REFUSED", text)
        self.assertEqual(self.events, [])

    def test_raw_build_is_packed_then_flashed(self):
        packed = candidate_bytes()
        rc, text = self.run_main(raw_of(packed))
        self.assertEqual(rc, 0, text)
        self.assertEqual(self.events, ["restart", "handshake", ("flash", packed), "app_start"])
        self.assertIn("Image: raw", text)


class McuVersionTests(unittest.TestCase):
    """G32: the Klipper version inside an MCU image and the release check."""

    def setUp(self):
        self.e = Env()
        os.environ["CREALITY_FLASH_PATH"] = MCU_TOOLS
        self.m = self.e.mcu
        self.img = self.m._image_module()

    def tearDown(self):
        self.e.cleanup()

    def test_version_from_shipped_image(self):
        builtin = os.path.join(OVERLAY, "opt", "nebulaos", "mcu-candidates", "candidate-001.bin")
        data = open(builtin, "rb").read()
        self.assertEqual(self.img.klipper_version(data), "v0.13.0-742-g01a9c2f92")
        self.assertEqual(self.img.release_of("v0.13.0-742-g01a9c2f92"), "v0.13.0")
        self.assertIsNone(self.img.klipper_version(b"\x78\x9c not zlib" + b"\x00" * 64))
        import zlib
        blob = b"\x00" * 16 + zlib.compress(b'{"version": "v0.12.0-1-gabc"}') + b"\x00" * 16
        self.assertEqual(self.img.klipper_version(blob), "v0.12.0-1-gabc")

    def test_release_note(self):
        note = self.m._version_note
        ok = {"valid": True, "native": False, "klipper_version": "v0.13.0-1-gdead"}
        self.assertIsNone(note(ok, "v0.13.0-742-g01a9c2f92"))           # same release
        old = dict(ok, klipper_version="v0.12.0-300-gbeef")
        self.assertIn("Klipper v0.12.0, NebulaOS uses v0.13.0", note(old, "v0.13.0-742-g01a9c2f92"))
        unknown = dict(ok, klipper_version=None)
        self.assertIn("unknown", note(unknown, "v0.13.0-742-g01a9c2f92"))
        self.assertIsNone(note(dict(old, valid=False), "v0.13.0-742-g01a9c2f92"))
        self.assertIsNone(note(dict(old, native=True), "v0.13.0-742-g01a9c2f92"))


FAKE_7ZA = r"""#!/usr/bin/env python3
# Fake 7za for the image tests: an "archive" is a text file naming a fixture
# directory; l -slt / x -so / x -o behave like 7za on that tree.
import fnmatch, os, shutil, sys
args = [a for a in sys.argv[1:] if not a.startswith("-p") and a != "-y"]
if "-p" + os.environ["FAKE_7Z_PASSWORD"] not in sys.argv:
    sys.exit(2)
cmd = args[0]
outdir = None
rest = []
for a in args[1:]:
    if a.startswith("-o"):
        outdir = a[2:]
    elif a != "-slt" and a != "-so":
        rest.append(a)
archive = rest[0]
root = open(archive).read().strip()
files = []
for d, _, names in os.walk(root):
    for n in names:
        files.append(os.path.relpath(os.path.join(d, n), root))
files.sort()
if cmd == "l":
    print("Path = " + archive)
    for f in files:
        print("Path = " + f)
elif "-so" in sys.argv:
    sys.stdout.write(open(os.path.join(root, rest[1])).read())
else:
    for f in files:
        if any(fnmatch.fnmatch(f, pat) for pat in rest[1:]):
            dst = os.path.join(outdir, f)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(os.path.join(root, f), dst)
"""


class ImageTests(unittest.TestCase):
    """On-printer image install (2026-10-14) against fake 7za, block devices,
    sysfs and cmdline - never a real partition."""

    def setUp(self):
        self.e = Env()
        self.i = self.e.image
        t = self.e.tmp
        self.dev = os.path.join(t, "dev")
        self.sys = os.path.join(t, "sys")
        os.makedirs(self.dev)
        for part, name, mb in (("mmcblk0p5", "kernel", 8), ("mmcblk0p6", "kernel2", 8),
                               ("mmcblk0p7", "rootfs", 16), ("mmcblk0p8", "rootfs2", 16)):
            open(os.path.join(self.dev, part), "wb").write(b"\x00" * (mb * 1048576))
            os.makedirs(os.path.join(self.sys, part))
            open(os.path.join(self.sys, part, "uevent"), "w").write("PARTNAME=%s\n" % name)
            open(os.path.join(self.sys, part, "size"), "w").write("%d\n" % (mb * 2048))
        self.mounts = os.path.join(t, "mounts")
        open(self.mounts, "w").write("/dev/mmcblk0p8 / squashfs ro 0 0\n")
        self.upload = os.path.join(t, "os")
        os.makedirs(self.upload)
        self.fake = os.path.join(self.e.bin, "7za")
        open(self.fake, "w").write(FAKE_7ZA)
        os.chmod(self.fake, 0o755)
        self.calls = os.path.join(t, "calls")
        write_exe(os.path.join(self.e.bin, "swap"), 'echo "swap $1" >> "%s"\n' % self.calls)
        write_exe(os.path.join(self.e.bin, "reboot"), 'echo reboot >> "%s"\n' % self.calls)
        os.environ.update({"FAKE_7Z_PASSWORD": self.i.ENVELOPE_PASSWORD})
        m = self.i
        m.SEVENZA, m.UPLOAD_DIR, m.DEV_DIR, m.SYS_BLOCK = self.fake, self.upload, self.dev, self.sys
        m.PROC_MOUNTS, m.SLOT_SWAP, m.REBOOT = self.mounts, os.path.join(self.e.bin, "swap"), os.path.join(self.e.bin, "reboot")
        m.WORK_PARENT = os.path.join(t, "work")
        m.JOB_DIR = os.path.join(t, "job")
        m.JOB_STATE = os.path.join(m.JOB_DIR, "state.json")
        m.TRIAL = os.path.join(t, "trial.json")
        m.LAST = os.path.join(t, "last.json")
        self.cmdline("B")

    def tearDown(self):
        self.e.cleanup()

    def cmdline(self, slot):
        open(os.environ["NEBULAOS_CMDLINE"], "w").write(
            "console=ttyS4 root=%s rootfstype=squashfs\n" % {"A": "/dev/mmcblk0p7", "B": "/dev/mmcblk0p8"}[slot])

    def kernel(self, name="Linux-6.6.157-rt79", arch=5, size=1500000):
        head = bytearray(64)
        struct.pack_into(">I", head, 0, 0x27051956)
        head[29] = arch
        head[32:32 + len(name)] = name.encode()
        return bytes(head) + os.urandom(size - 64)

    def package(self, fname="nebula.img", kernel=None, rootfs=None, corrupt=None):
        import hashlib
        kernel = kernel if kernel is not None else self.kernel()
        rootfs = rootfs if rootfs is not None else b"hsqs" + os.urandom(3 * 1048576 + 1234)
        tree = os.path.join(self.e.tmp, "pkg-" + fname)
        inner = os.path.join(tree, "Ender-3_V3_KE_F005_ota_img_V9.9", "ota_v9.9")
        os.makedirs(inner)
        records = ["ota_version=9.9", ""]
        for kind, name, data in (("kernel", "xImage", kernel), ("rootfs", "rootfs.squashfs", rootfs)):
            whole = hashlib.md5(data).hexdigest()
            prev, sums = whole, []
            for idx in range(0, (len(data) + 1048575) // 1048576):
                chunk = data[idx * 1048576:(idx + 1) * 1048576]
                if corrupt == (name, idx):
                    chunk = b"X" + chunk[1:]
                open(os.path.join(inner, "%s.%04d.%s" % (name, idx, prev)), "wb").write(chunk)
                prev = hashlib.md5(data[idx * 1048576:(idx + 1) * 1048576]).hexdigest()
                sums.append(prev)
            open(os.path.join(inner, "ota_md5_%s.%s" % (name, whole)), "w").write("\n".join(sums) + "\n")
            records += ["img_type=" + kind, "img_name=" + name, "img_size=%d" % len(data),
                        "img_md5=" + whole, ""]
        open(os.path.join(inner, "ota_update.in"), "w").write("\n".join(records))
        archive = os.path.join(self.upload, fname)
        open(archive, "w").write(tree)
        return archive, kernel, rootfs

    def test_list_check_and_slots(self):
        self.package()
        open(os.path.join(self.dev, "mmcblk0p6"), "r+b").write(self.kernel()[:64])
        open(os.path.join(self.dev, "mmcblk0p5"), "r+b").write(self.kernel("Linux-4.4.94")[:64])
        out = self.i.list_files()
        self.assertEqual([f["id"] for f in out["files"]], ["upload/nebula.img"])
        self.assertEqual(out["slots"]["running"], "B")
        self.assertEqual((out["slots"]["A"]["system"], out["slots"]["B"]["system"]), ("creality", "nebulaos"))
        c = self.i.check("upload/nebula.img")
        self.assertEqual((c["result"], c["version"], c["target"]), ("OK", "9.9", "A"))
        self.assertEqual(len(c["sha256"]), 64)

    def test_bad_packages_refused(self):
        archive, _, _ = self.package()
        open(archive, "w").write(os.path.join(self.e.tmp, "nowhere"))
        with self.assertRaises(self.e.common.OsConfigError):
            self.i.check("upload/nebula.img")
        for bad in ("../x.img", "upload/../../etc/passwd", "usb/x", "", None):
            with self.assertRaises(self.e.common.OsConfigError):
                self.i.resolve(bad)

    def test_install_writes_inactive_slot_and_arms_trial(self):
        archive, kernel, rootfs = self.package()
        sha = self.i.sha256_file(archive)
        self.i.run_job("upload/nebula.img", sha)
        st = json.load(open(self.i.JOB_STATE))
        self.assertEqual(st["state"], "restarting", st)
        self.assertEqual(open(os.path.join(self.dev, "mmcblk0p5"), "rb").read(len(kernel)), kernel)
        self.assertEqual(open(os.path.join(self.dev, "mmcblk0p7"), "rb").read(len(rootfs)), rootfs)
        # the running slot (B) is untouched
        self.assertEqual(open(os.path.join(self.dev, "mmcblk0p8"), "rb").read(16), b"\x00" * 16)
        self.assertEqual(open(self.calls).read().split("\n")[:2], ["swap A", "reboot"])
        trial = json.load(open(self.i.TRIAL))
        self.assertEqual((trial["from"], trial["to"], trial["system"]), ("B", "A", "nebulaos"))
        self.assertFalse(os.listdir(self.i.WORK_PARENT))           # work dir cleaned

    def test_install_from_slot_a_writes_slot_b(self):
        self.cmdline("A")
        open(self.mounts, "w").write("/dev/mmcblk0p7 / squashfs ro 0 0\n")
        archive, kernel, _ = self.package()
        self.i.run_job("upload/nebula.img", self.i.sha256_file(archive))
        self.assertEqual(open(os.path.join(self.dev, "mmcblk0p6"), "rb").read(len(kernel)), kernel)
        self.assertIn("swap B", open(self.calls).read())

    def test_damaged_chunk_never_switches(self):
        archive, _, _ = self.package(corrupt=("rootfs.squashfs", 2))
        self.i.run_job("upload/nebula.img", self.i.sha256_file(archive))
        st = json.load(open(self.i.JOB_STATE))
        self.assertEqual((st["state"], st["error"]), ("failed", "INVALID_IMAGE"))
        self.assertFalse(os.path.exists(self.calls))                 # no swap, no reboot
        self.assertFalse(os.path.exists(self.i.TRIAL))

    def test_refusals_before_writing(self):
        archive, _, _ = self.package()
        sha = self.i.sha256_file(archive)
        self.i.run_job("upload/nebula.img", "0" * 64)                # file changed
        self.assertEqual(json.load(open(self.i.JOB_STATE))["error"], "FILE_CHANGED")
        open(os.path.join(self.sys, "mmcblk0p7", "uevent"), "w").write("PARTNAME=userdata\n")
        self.i.run_job("upload/nebula.img", sha)                     # wrong partition
        self.assertEqual(json.load(open(self.i.JOB_STATE))["error"], "PARTITION_MISMATCH")
        open(os.path.join(self.sys, "mmcblk0p7", "uevent"), "w").write("PARTNAME=rootfs\n")
        open(self.mounts, "a").write("/dev/mmcblk0p7 /mnt ext4 ro 0 0\n")
        self.i.run_job("upload/nebula.img", sha)                     # target mounted
        self.assertEqual(json.load(open(self.i.JOB_STATE))["error"], "TARGET_MOUNTED")
        open(os.environ["NEBULAOS_CMDLINE"], "w").write("root=/dev/sda1\n")
        self.i.run_job("upload/nebula.img", sha)                     # unknown slot
        self.assertEqual(json.load(open(self.i.JOB_STATE))["error"], "SLOT_UNKNOWN")
        self.assertFalse(os.path.exists(self.calls))
        self.assertEqual(open(os.path.join(self.dev, "mmcblk0p5"), "rb").read(16), b"\x00" * 16)

    def test_non_mips_kernel_refused(self):
        archive, _, _ = self.package(kernel=self.kernel(arch=2))
        self.i.run_job("upload/nebula.img", self.i.sha256_file(archive))
        self.assertIn("MIPS", json.load(open(self.i.JOB_STATE))["message"])

    def test_install_starts_worker_and_refuses_busy(self):
        archive, _, _ = self.package()
        started = []
        import subprocess as sp
        old = sp.Popen
        sp.Popen = lambda *a, **k: started.append(a[0])
        try:
            with self.assertRaises(self.e.common.OsConfigError):
                self.i.install("upload/nebula.img", "nothex")
            out = self.i.install("upload/nebula.img", self.i.sha256_file(archive))
            self.assertEqual(out["result"], "STARTED")
            self.assertEqual(started[0][1:3], ["image", "worker"])
            with self.assertRaises(self.e.common.OsConfigError) as cm:
                self.i.install("upload/nebula.img", self.i.sha256_file(archive))
            self.assertEqual(cm.exception.code, "BUSY")
        finally:
            sp.Popen = old

    def trial_file(self, frm="B", to="A"):
        json.dump({"from": frm, "to": to, "file": "upload/nebula.img", "version": "9.9",
                   "system": "nebulaos"}, open(self.i.TRIAL, "w"))

    def test_trial_confirmed(self):
        self.cmdline("A")
        self.trial_file()
        self.i._klipper_ready = lambda: True
        self.i._gui_running = lambda: True
        self.assertEqual(self.i.trial()["result"], "CONFIRMED")
        self.assertFalse(os.path.exists(self.i.TRIAL))
        self.assertEqual(self.i.status()["last"]["result"], "CONFIRMED")
        self.i.ack()
        self.assertIsNone(self.i.status()["last"])

    def test_trial_rolls_back_once(self):
        self.cmdline("A")
        self.trial_file()
        self.i.TRIAL_SECONDS, self.i.TRIAL_POLL = 0, 0
        self.i._klipper_ready = lambda: False
        self.i._gui_running = lambda: True
        self.assertEqual(self.i.trial()["result"], "ROLLED_BACK")
        self.assertEqual(open(self.calls).read().split(), ["swap", "B", "reboot"])
        self.assertFalse(os.path.exists(self.i.TRIAL))               # never a second time
        self.assertEqual(self.i.trial()["result"], "NO_TRIAL")
        self.assertEqual(json.load(open(self.i.LAST))["result"], "ROLLED_BACK")

    def test_trial_not_started(self):
        self.cmdline("B")                                            # still the old slot
        self.trial_file()
        self.assertEqual(self.i.trial()["result"], "NOT_STARTED")
        self.assertFalse(os.path.exists(self.calls))


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
            printf '%%s\\n' "$@" > "%(log)s"; echo "NEBULAOS_BOOT_UPLOAD_DIR=$NEBULAOS_BOOT_UPLOAD_DIR" >> "%(log)s"
            [ "$3" = --stdin ] && cat > "%(log)s.stdin"
            echo "$1 $2" >> "%(log)s.all"
            case "$1 $2" in
              "display set-brightness") echo '{"ok": false, "error": "INVALID_BRIGHTNESS", "message": "m"}'; exit 1 ;;
              "network set-ipv4") echo '{"ok": false, "error": "GATEWAY_UNREACHABLE_REVERTED", "message": "m"}'; exit 2 ;;
            esac
            echo '{"ok": true, "result": "APPLIED"}'
        """ % {"log": self.log})
        self.upload_dir = os.path.join(self.tmp, "boot-uploads")
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
            def register_directory(self, root, path, full_access=False):
                test.registered = (root, path, full_access)
                return True

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
                return {"file_manager": FM(), "machine": test.machine,
                        "klippy_apis": test.kapis}.get(name, default)

            def error(self, msg, code=400):
                return ServerError(msg, code)

        class Config(object):
            def get_server(self):
                return test.server

            def get(self, key, default=None):
                return {"helper": test.helper,
                        "boot_upload_dir": test.upload_dir}.get(key, default)

        class Provider(object):
            async def reboot(self):
                test.reboots += 1
                if test.reboot_fails:
                    raise RuntimeError("sudo failed")

        class Machine(object):
            def get_system_provider(self):
                return Provider()

        class KApis(object):
            async def query_objects(self, objects):
                if test.print_state is None:
                    raise RuntimeError("klippy not ready")
                return {"print_stats": {"state": test.print_state}}

        self.machine, self.kapis = Machine(), KApis()
        self.reboots, self.reboot_fails, self.print_state = 0, False, "standby"
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

    def calls(self):
        try:
            return open(self.log + ".all").read().splitlines()
        except OSError:
            return []

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
        self.assertIn("NEBULAOS_BOOT_UPLOAD_DIR=" + self.upload_dir, self.argv())
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

    def test_boot_upload_root_registered(self):
        self.assertEqual(self.registered, ("nebulaos_boot", self.upload_dir, True))
        self.assertTrue(os.path.isdir(self.upload_dir))
        self.call("/machine/nebulaos/boot_display/image", {"filename": "logo.png"})
        self.assertEqual(self.argv()[:4], ["boot-display", "set-image", "--file", "logo.png"])

    def test_invalid_maps_to_400(self):
        with self.assertRaises(Exception) as cm:
            self.call("/machine/nebulaos/display/brightness", {"level": 30})
        self.assertEqual(cm.exception.status_code, 400)

    def test_wifi_endpoints(self):
        for p in ("wifi/status", "wifi/scan", "wifi/connect", "wifi/forget",
                  "system/clean_reset", "system/swap_slot", "system/ack_clean_reset",
                  "image/list", "image/status", "image/check", "image/install", "image/ack"):
            self.assertIn("/machine/nebulaos/" + p, self.server.endpoints)
        self.call("/machine/nebulaos/wifi/connect", {"ssid": "Home", "password": "s3cret pw"})
        self.assertEqual(self.argv()[:3], ["wifi", "connect", "--stdin"])
        self.assertNotIn("s3cret pw", open(self.log).read())         # never in argv
        self.assertEqual(json.load(open(self.log + ".stdin")),
                         {"ssid": "Home", "password": "s3cret pw"})
        self.call("/machine/nebulaos/wifi/forget", {"ssid": "Old net"})
        self.assertEqual(self.argv()[:4], ["wifi", "forget", "--ssid", "Old net"])

    def test_clean_reset_and_swap_reboot(self):
        self.assertEqual(self.call("/machine/nebulaos/system/clean_reset"), {"result": "APPLIED"})
        self.call("/machine/nebulaos/system/swap_slot")
        self.assertEqual(self.reboots, 2)
        self.assertEqual(self.calls(), ["system clean-reset", "system swap-slot"])

    def test_refused_while_printing(self):
        for state in ("printing", "paused"):
            self.print_state = state
            for p in ("system/clean_reset", "system/swap_slot"):
                with self.assertRaises(Exception) as cm:
                    self.call("/machine/nebulaos/" + p)
                self.assertEqual(cm.exception.status_code, 409)
        self.assertEqual((self.reboots, self.calls()), (0, []))
        self.print_state = None          # Klipper down: allowed
        self.call("/machine/nebulaos/system/swap_slot")
        self.assertEqual(self.reboots, 1)

    def test_failed_reboot_disarms(self):
        self.reboot_fails = True
        for p, undo in (("system/clean_reset", "system cancel-clean-reset"),
                        ("system/swap_slot", "system keep-slot")):
            with self.assertRaises(Exception) as cm:
                self.call("/machine/nebulaos/" + p)
            self.assertIn("REBOOT_FAILED", str(cm.exception))
            self.assertEqual(self.calls()[-1], undo)

    def test_mcu_endpoints(self):
        self.assertEqual(self.call("/machine/nebulaos/mcu/files"), {"result": "APPLIED"})
        self.assertEqual(self.argv()[:2], ["mcu", "list"])
        self.call("/machine/nebulaos/mcu/status")
        self.assertEqual(self.argv()[:2], ["mcu", "status"])
        seen = {}
        real_exec = self.comp._exec

        async def spy(args, timeout, stdin=None):
            seen["timeout"] = timeout
            return await real_exec(args, timeout, stdin)
        self.comp._exec = spy
        self.call("/machine/nebulaos/mcu/flash", {"file": "usb/sda1/x.bin", "sha256": "ab" * 32})
        self.assertEqual(self.argv()[:6], ["mcu", "flash", "--file", "usb/sda1/x.bin",
                                           "--sha256", "ab" * 32])
        self.assertEqual(seen["timeout"], self.mod.MCU_FLASH_TIMEOUT)
        self.assertGreater(self.mod.MCU_FLASH_TIMEOUT, 600)    # outlives the helper's bound
        self.assertEqual(self.server.events[-1][1]["domain"], "mcu")

    def test_mcu_flash_refused_while_printing_or_busy(self):
        for state in ("printing", "paused"):
            self.print_state = state
            with self.assertRaises(Exception) as cm:
                self.call("/machine/nebulaos/mcu/flash", {"file": "upload/a.bin", "sha256": "0" * 64})
            self.assertEqual(cm.exception.status_code, 409)
        self.assertEqual(self.calls(), [])
        self.print_state = "standby"

        async def busy():
            lock = self.comp.write_locks.setdefault("mcu", asyncio.Lock())
            await lock.acquire()
            try:
                await self.server.endpoints["/machine/nebulaos/mcu/flash"][1](
                    self.Req({"file": "upload/a.bin", "sha256": "0" * 64}))
            finally:
                lock.release()
        with self.assertRaises(Exception) as cm:
            asyncio.run(busy())
        self.assertIn("BUSY", str(cm.exception))
        self.assertEqual(self.calls(), [])

    def test_ok_result_strips_ok(self):
        out = self.call("/machine/nebulaos/info")
        self.assertEqual(out, {"result": "APPLIED"})


if __name__ == "__main__":
    unittest.main()
