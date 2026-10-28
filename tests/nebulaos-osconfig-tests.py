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
import time
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
            "NEBULAOS_BOOT_SHIPPED_DIR": os.path.join(self.tmp, "shipped-logos"),
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
            # G91 busy check: never the host's Moonraker, Klippy or pidfile.
            "NEBULAOS_MOONRAKER_BASE": "http://127.0.0.1:9",
            "NEBULAOS_KLIPPY_PIDFILE": os.path.join(self.tmp, "klippy.pid"),
            "NEBULAOS_KLIPPY_SOCK": os.path.join(self.tmp, "klippy.sock"),
            # S34 reboot grace: never the host's printer.cfg or /proc
            "NEBULAOS_PRINTER_CFG": os.path.join(self.tmp, "printer.cfg"),
            "NEBULAOS_PROC_DIR": os.path.join(self.tmp, "proc"),
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


def fake_busy(common, reasons):
    """Make common.busy_state answer from a list (one item per call, the
    last one repeats): None = not busy, else a reason. Returns the call log
    (profile, holder)."""
    calls = []
    seq = list(reasons)

    def busy_state(profile, holder=None, facts=None):
        calls.append((profile, holder))
        reason = seq.pop(0) if len(seq) > 1 else seq[0]
        return common.busy_result(profile, reason)
    common.busy_state = busy_state
    return calls


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
        # The power-on logo (RTOS) side is PowerOnLogoTests' subject; here it
        # always takes the logo.
        p = importlib.import_module("nebulaos_osconfig.poweronlogo")
        self.written = []
        p.check_writable = lambda: "B"
        p.write_slot = lambda data: self.written.append(data) or {"result": "WRITTEN", "slot": "B"}

    def tearDown(self):
        self.e.cleanup()

    def _png(self, name, size=(64, 32), colour=(255, 0, 0)):
        path = os.path.join(self.e.config_root, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.Image.new("RGB", size, colour).save(path, "PNG")
        return path

    def test_modes(self):
        self.assertEqual(self.b.set_mode("logo")["config"]["mode"], "logo")
        self.assertIn('MODE="logo"', open(self.b.ENV).read())
        with self.assertRaises(self.e.common.OsConfigError):
            self.b.set_mode("splash; reboot")
        self.assertEqual(self.b.status()["modes"], ["logo"])

    def test_blank_retired(self):
        # G58 (2026-10-15): there is always a boot logo; a saved "blank" is logo.
        with self.assertRaises(self.e.common.OsConfigError):
            self.b.set_mode("blank")
        self.e.common.atomic_write_json(self.b.CONFIG, {"schema": 1, "mode": "blank",
                                                         "image": "builtin"})
        self.assertEqual(self.b.load_config(), ({"schema": 1, "mode": "logo", "image": "builtin"}, None))

    def test_console_retired(self):
        # D10 (2026-10-11): console can no longer be chosen; a saved one is logo.
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.b.set_mode("console")
        self.assertEqual(cm.exception.code, "INVALID_MODE")
        self.e.common.atomic_write_json(self.b.CONFIG, {"schema": 1, "mode": "console",
                                                         "image": "builtin"})
        cfg, error = self.b.load_config()
        self.assertEqual((cfg["mode"], error), ("logo", None))

    def test_boot_logo_page(self):
        # G61 (2026-10-16): dropdown shows the chosen upload; add from USB, delete, preview
        b = self.b
        os.makedirs(b.UPLOAD_DIR, exist_ok=True)
        b.USB_DIR = os.path.join(self.e.tmp, "usbroot")
        stick = os.path.join(b.USB_DIR, "sda1", "pics")
        os.makedirs(stick)
        self.Image.new("RGB", (800, 600), (0, 90, 200)).save(os.path.join(stick, "My Logo, final.PNG"), "PNG")
        self.Image.new("RGB", (64, 64)).save(os.path.join(stick, "notes.gif"), "GIF")
        b.PREVIEW_DIR = os.path.join(self.e.tmp, "preview")
        lst = b.list_images()
        self.assertEqual((lst["images"], lst["selected"]), ([], ""))
        self.assertEqual([u["name"] for u in lst["usb"]], ["My Logo, final.PNG"])   # images only
        imp = b.import_usb(lst["usb"][0]["id"])
        self.assertEqual((imp["name"], imp["existing"]), ("My Logo, final.PNG", False))
        self.assertTrue(b.import_usb(lst["usb"][0]["id"])["existing"])            # same file again
        self.Image.new("RGB", (10, 10), (1, 1, 1)).save(os.path.join(stick, "My Logo, final.PNG"), "PNG")
        self.assertEqual(b.import_usb(lst["usb"][0]["id"])["name"], "My Logo, final (2).PNG")
        out = b.set_image("My Logo, final.PNG")                                   # spaces and a comma
        self.assertEqual(out["result"], "APPLIED")
        lst = b.list_images()
        self.assertEqual(lst["selected"], "My Logo, final.PNG")
        self.assertEqual([i["name"] for i in lst["images"]], ["My Logo, final (2).PNG", "My Logo, final.PNG"])
        pv = b.preview("My Logo, final.PNG")
        self.assertEqual(self.Image.open(pv["path"]).size, (240, 136))
        self.assertEqual(b.preview("")["result"], "OK")
        self.assertEqual(len(os.listdir(b.PREVIEW_DIR)), 1)                       # old previews dropped
        b.delete_image("My Logo, final.PNG")
        self.assertEqual(b.list_images()["selected"], "")                         # gone from the list
        b.reset_image()
        self.assertNotIn("source", b.load_config()[0])
        for bad in ("../x.png", "a/b.png", ".hidden.png", "x\nfile.png", ""):
            with self.assertRaises(self.e.common.OsConfigError):
                b.resolve_upload(bad)
        for bad in ("usb/../etc/passwd", "usb/sda1/../../x", "gcodes/x.png"):
            with self.assertRaises(self.e.common.OsConfigError):
                b.import_usb(bad)

    def _shipped(self, name, colour=(0, 0, 255)):
        os.makedirs(self.b.SHIPPED_DIR, exist_ok=True)
        path = os.path.join(self.b.SHIPPED_DIR, name)
        self.Image.new("RGB", (480, 272), colour).save(path, "JPEG")
        return path

    def test_shipped_logos(self):
        # G116 (Run 21): the shipped logos are listed first, can be applied and
        # previewed, never deleted; an upload with the same name wins
        b = self.b
        b.PREVIEW_DIR = os.path.join(self.e.tmp, "preview")
        self._shipped("NebulaOS Deep Space.jpg")
        self._shipped(b.FRESH_DEFAULT)
        self._png("mine.png")
        lst = b.list_images()
        self.assertEqual([(i["name"], i.get("shipped", False)) for i in lst["images"]],
                         [("NebulaOS Deep Space.jpg", True), (b.FRESH_DEFAULT, True),
                          ("mine.png", False)])
        out = b.set_image("NebulaOS Deep Space.jpg")
        self.assertEqual(out["result"], "APPLIED")
        self.assertEqual(len(self.written), 1)                                   # power-on logo too
        self.assertEqual(b.list_images()["selected"], "NebulaOS Deep Space.jpg")
        self.assertEqual(b.custom_path(), os.path.join(b.BOOT_DIR, "custom.jpg"))
        self.assertEqual(b.preview("NebulaOS Deep Space.jpg")["result"], "OK")
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            b.delete_image("NebulaOS Deep Space.jpg")
        self.assertEqual(cm.exception.code, "SHIPPED_IMAGE")
        self.assertTrue(os.path.isfile(os.path.join(b.SHIPPED_DIR, "NebulaOS Deep Space.jpg")))
        # an upload of the same name shadows the shipped one (and can be deleted)
        self._png("NebulaOS Deep Space.jpg")
        names = [i["name"] for i in b.list_images()["images"]]
        self.assertEqual(names.count("NebulaOS Deep Space.jpg"), 1)
        self.assertEqual(b.resolve_image("NebulaOS Deep Space.jpg"),
                         os.path.join(os.path.realpath(b.UPLOAD_DIR), "NebulaOS Deep Space.jpg"))
        b.delete_image("NebulaOS Deep Space.jpg")
        self.assertEqual(b.resolve_image("NebulaOS Deep Space.jpg"),
                         os.path.join(os.path.realpath(b.SHIPPED_DIR), "NebulaOS Deep Space.jpg"))
        for bad in ("../x.jpg", "a/b.jpg", ".hidden.jpg"):
            with self.assertRaises(self.e.common.OsConfigError):
                b.resolve_image(bad)

    def test_fresh_install_default(self):
        # G116: the first seed selects Blueprint for the boot screen only (the
        # packaged power-on logo is that picture already)
        b = self.b
        self.assertEqual(b.fresh_install_default()["result"], "UNCHANGED")       # nothing shipped
        self.assertFalse(os.path.exists(b.CONFIG))
        self._shipped(b.FRESH_DEFAULT)
        out = b.fresh_install_default()
        self.assertEqual(out["result"], "APPLIED")
        self.assertEqual(b.load_config()[0], {"schema": 1, "mode": "logo", "image": "custom",
                                              "source": b.FRESH_DEFAULT})
        self.assertEqual(b.list_images()["selected"], b.FRESH_DEFAULT)
        self.assertEqual(open(b.custom_path(), "rb").read(),
                         open(os.path.join(b.SHIPPED_DIR, b.FRESH_DEFAULT), "rb").read())
        self.assertEqual(self.written, [])                                      # RTOS untouched
        # an existing setting is never changed: the built-in choice stays
        b.reset_image()
        self.assertEqual(b.fresh_install_default()["result"], "UNCHANGED")
        self.assertEqual(b.load_config()[0]["image"], "builtin")

    def test_upload_name_confinement(self):
        # G61 (2026-10-16): ordinary names with spaces etc. are allowed (the
        # helper never uses a shell); folders, traversal, hidden and control
        # characters are not
        for bad in ("/etc/passwd", "../x.png", "a/b.png", "sub/../x.png", ".hidden.png",
                    "", None, "x" * 201, "a\x01b.png", "a\nb.png"):
            with self.assertRaises(self.e.common.OsConfigError, msg=repr(bad)) as cm:
                self.b.resolve_upload(bad)
            self.assertEqual(cm.exception.code, "INVALID_FILENAME")
        os.symlink("/etc/hostname", os.path.join(self.e.config_root, "evil.png"))
        with self.assertRaises(self.e.common.OsConfigError):
            self.b.resolve_upload("evil.png")
        for ok in ("a b.png", "Logo, final (2).PNG", "a;reboot.png"):
            self.assertTrue(self.b.resolve_upload(ok).endswith(ok))
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
        self.assertEqual(cm.exception.code, "IMAGE_INVALID")      # a damaged JPEG
        self.assertIn("damaged", str(cm.exception))
        # 2026-10-15: real JPEGs (phone photos) are accepted; other formats get a plain message
        real = os.path.join(self.e.config_root, "photo.jpg")
        self.Image.new("RGB", (640, 480), (1, 2, 3)).save(real, "JPEG")
        self.assertEqual(self.b.validate_image_file(real)[0], "JPEG")
        gif = os.path.join(self.e.config_root, "a.gif")
        self.Image.new("RGB", (8, 8)).save(gif, "GIF")
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.b.validate_image_file(gif)
        self.assertEqual(str(cm.exception), "this file is not a PNG, BMP or JPEG image")
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
        self.nets[nid] = {"ssid": b"", "psk": None, "key_mgmt": "WPA-PSK", "disabled": False,
                          "priority": 0}
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
            if len(parts) > 2 and parts[2] == "priority":
                return "%d" % self.nets[int(parts[1])]["priority"], None
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
            elif parts[2] == "priority":
                n["priority"] = int(parts[3])
            elif parts[2] == "scan_ssid":
                n["scan_ssid"] = parts[3]
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
            return "OK\n", self._scan_done
        if verb == "SCAN_RESULTS":
            lines = ["bssid / frequency / signal level / flags / ssid"]
            for i, (ssid, sig, flags) in enumerate(self.scan):
                lines.append("aa:bb:cc:dd:ee:%02x\t2412\t%d\t%s\t%s" % (i, sig, flags, ssid))
            return "\n".join(lines) + "\n", None
        if verb == "SAVE_CONFIG":
            self.saves.append({nid: dict(n) for nid, n in self.nets.items()})
            return "OK\n", None
        return "UNKNOWN COMMAND\n", None

    def _scan_done(self):
        """Like wpa_supplicant after scan results: pick the enabled saved
        network in range with the highest priority, the strongest signal
        breaking a tie, and move there if it is not the current one (the
        fallback seen on ke-dev 2026-10-15, P9)."""
        self._event("<3>CTRL-EVENT-SCAN-RESULTS ")
        signal_of = {}
        for ssid, sig, _ in self.scan:              # the strongest BSS per network
            signal_of[ssid] = max(sig, signal_of.get(ssid, sig))
        best = None
        for nid, n in self.nets.items():
            ssid = n["ssid"].decode("utf-8", "replace")
            if n["disabled"] or ssid not in signal_of or ssid not in self.passwords:
                continue
            key = (n["priority"], signal_of[ssid])
            if best is None or key > best[0]:
                best = (key, nid)
        if best is not None and best[1] != self.current:
            self._event("<3>CTRL-EVENT-DISCONNECTED bssid=aa:bb reason=3 locally_generated=1")
            self._try(best[1])

    def _try(self, nid):
        n = self.nets[nid]
        ssid = n["ssid"].decode("utf-8", "replace")
        if ssid not in self.passwords:
            return                                  # not in range: no event
        if ssid in getattr(self, "hidden", ()) and n.get("scan_ssid") != "1":
            return                                  # hidden: only found when probed for
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

    def test_hidden_network(self):
        """G10: a network that is not in the scan, typed in with "hidden"."""
        wpa = self.fake({"Home": "secret123", "Attic": "atticpass1"}, saved=[("Home", "secret123")])
        wpa.hidden = {"Attic"}
        with self.assertRaises(self.e.common.OsConfigError):
            self.w.connect({"ssid": "Attic", "password": "atticpass1"})   # not probed: times out
        out = self.w.connect({"ssid": "Attic", "password": "atticpass1", "hidden": True})
        self.assertEqual(out["ssid"], "Attic")
        attic = [n for n in wpa.saves[-1].values() if n["ssid"] == b"Attic"][0]
        self.assertEqual(attic.get("scan_ssid"), "1")

    def test_wpa3_only_network_explained(self):
        self.SCAN = self.SCAN + [("Modern", -45, "[WPA2-SAE-CCMP][ESS]"),
                                 ("Mixed", -46, "[WPA2-PSK+SAE-CCMP][ESS]")]
        self.fake({"Modern": "longpassword", "Mixed": "longpassword"})
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.w.connect({"ssid": "Modern", "password": "longpassword"})
        self.assertIn("WPA2/WPA3", cm.exception.message)
        self.assertEqual(self.w.connect({"ssid": "Mixed", "password": "longpassword"})["ssid"], "Mixed")

    def test_chosen_network_survives_the_next_scan(self):
        # P9 on ke-dev (2026-10-15): connected to fsociety, the screen then
        # scanned, and wpa_supplicant picked the stronger saved network
        # (Office) again - all saved networks had the same priority. The
        # network the user chose last must win every later selection.
        wpa = self.fake({"Home": "secret123", "Cafe": None}, saved=[("Home", "secret123")])
        out = self.w.connect({"ssid": "Cafe"})
        self.assertEqual(out["ssid"], "Cafe")
        self.w.scan()                                  # what the screen does next
        self.assertEqual(self.w.status()["status"]["ssid"], "Cafe")
        prio = {n["ssid"]: n["priority"] for n in wpa.saves[-1].values()}
        self.assertEqual(prio, {b"Home": 0, b"Cafe": 1})     # persisted for the next boot
        # and back: choosing Home again makes Home the preferred one
        self.w.connect({"ssid": "Home"})
        self.w.scan()
        self.assertEqual(self.w.status()["status"]["ssid"], "Home")
        prio = {n["ssid"]: n["priority"] for n in wpa.saves[-1].values()}
        self.assertEqual(prio, {b"Home": 1, b"Cafe": 0})

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


class MaintenanceGateTests(unittest.TestCase):
    """G91 v2.7 step 6 / S34: every remaining disruptive osconfig action holds
    the maintenance lock and is refused (exit 3) while busy; reboot-type
    actions wait out the grace after a Klippy (re)start or SAVE_CONFIG."""

    def setUp(self):
        self.e = Env()
        self.c = self.e.common
        self.cleanup = importlib.import_module("nebulaos_osconfig.cleanup")
        write_exe(os.environ["NEBULAOS_SLOT_SWAP"], "exit 0\n")
        open(os.environ["NEBULAOS_CMDLINE"], "w").write("root=/dev/mmcblk0p8\n")

    def tearDown(self):
        self.e.cleanup()

    def actions(self):
        return [("set_image", lambda: self.e.bootdisplay.set_image("x.png")),
                ("reset_image", self.e.bootdisplay.reset_image),
                ("restore_original_logo", self.e.bootdisplay.restore_original_logo),
                ("clean_creality", lambda: self.cleanup.clean_creality(False)),
                ("request_clean_reset", self.e.system.request_clean_reset),
                ("swap_slot", self.e.system.swap_slot),
                ("mcu_flash", lambda: self.e.mcu.flash("upload/x.bin", "0" * 64))]

    def test_refused_while_busy_nothing_changed(self):
        self.e.image.slot_bootable = lambda slot: True
        for reason in ("PRINTING", "PAUSED", "ACTIVE", "CALIBRATING", "LOW_MEMORY", "UNKNOWN"):
            calls = fake_busy(self.c, [reason])
            for name, action in self.actions():
                del calls[:]
                with self.assertRaises(self.c.Refused, msg=name) as cm:
                    action()
                self.assertEqual(cm.exception.code, reason, name)
                self.assertEqual(calls[0][0], "request", name)
                self.assertTrue(calls[0][1], name)               # own lock excluded
                self.assertIsNone(self.c.lock_holder(self.c.MAINTENANCE_LOCK), name)
        self.assertFalse(os.path.exists(self.e.system.CLEAN_RESET_FLAG))
        self.assertFalse(os.path.exists(self.e.image.TRIAL))

    def test_refusal_is_exit_3_through_the_cli(self):
        fake_busy(self.c, ["PRINTING"])
        for argv in (["boot-display", "reset-image"], ["system", "cleanup-creality"],
                     ["system", "clean-reset"], ["boot-display", "restore-original-logo"]):
            out, old = io.StringIO(), sys.stdout
            sys.stdout = out
            try:
                rc = self.e.cli.main(argv)
            finally:
                sys.stdout = old
            reply = json.loads(out.getvalue())
            self.assertEqual((rc, reply["error"], reply["refused"]), (3, "PRINTING", True), argv)

    def test_second_action_refused_by_the_lock(self):
        # the real check: Klippy gone (not busy) but another holder -> UPDATING
        self.e.image.slot_bootable = lambda slot: True
        other = self.c.MaintenanceLock("image-1").acquire()
        try:
            for name, action in self.actions():
                with self.assertRaises(self.c.Refused, msg=name) as cm:
                    action()
                self.assertEqual(cm.exception.code, "UPDATING", name)
        finally:
            other.release()

    def test_lock_held_while_the_action_runs(self):
        seen = {}
        real = self.e.system._arm_clean_reset

        def arm():
            seen["holder"] = self.c.lock_holder(self.c.MAINTENANCE_LOCK)
            return real()
        self.e.system._arm_clean_reset = arm
        self.assertEqual(self.e.system.request_clean_reset()["result"], "SCHEDULED")
        self.assertTrue(seen["holder"].startswith("clean-reset-"))
        self.assertIsNone(self.c.lock_holder(self.c.MAINTENANCE_LOCK))

    def test_mcu_flash_hands_its_token_to_the_cli_and_maps_its_refusal(self):
        m = self.e.mcu
        os.makedirs(m.UPLOAD_DIR, exist_ok=True)
        data = candidate_bytes()
        with open(os.path.join(m.UPLOAD_DIR, "ok.bin"), "wb") as fh:
            fh.write(data)
        sha = m._image_module().sha256(data)
        log = os.path.join(self.e.tmp, "cli.env")
        write_exe(os.environ["NEBULAOS_MCU_CLI"], """
            echo "$NEBULAOS_MAINTENANCE_HOLDER" > "%s"
            echo "NebulaOS refused: Not possible while a print is running. (PRINTING)" >&2
            exit 3
        """ % log)
        with self.assertRaises(self.c.Refused) as cm:
            m.flash("upload/ok.bin", sha)
        self.assertEqual(cm.exception.code, "PRINTING")
        self.assertTrue(open(log).read().strip().startswith("mcu-flash-"))
        self.assertEqual([f for f in os.listdir(m.STAGE_DIR) if f.endswith(".bin")], [])

    def test_mcu_flash_is_not_refused_by_its_own_locks(self):
        """Run 18 architect finding 1: the CLI's real busy check, run while
        mcu.flash holds BOTH locks, must not see them as another update."""
        m = self.e.mcu
        os.makedirs(m.UPLOAD_DIR, exist_ok=True)
        data = candidate_bytes()
        with open(os.path.join(m.UPLOAD_DIR, "ok.bin"), "wb") as fh:
            fh.write(data)
        sha = m._image_module().sha256(data)
        out = os.path.join(self.e.tmp, "busy.out")
        libdir = os.path.dirname(os.path.dirname(os.path.abspath(self.c.__file__)))
        write_exe(os.environ["NEBULAOS_MCU_CLI"], """
            python3 -c 'import os, sys; sys.path.insert(0, sys.argv[1])
from nebulaos_osconfig import common
r = common.busy_state("point_of_no_return", os.environ["NEBULAOS_MAINTENANCE_HOLDER"], {"klippy": "not_ready"})
print(r["busy"], r.get("reason"))' "%s" > "%s"
            exit 0
        """ % (libdir, out))
        try:
            m.flash("upload/ok.bin", sha)
        except Exception:
            pass        # later steps of the fake flash may fail; the check is what matters
        self.assertEqual(open(out).read().split()[0], "False", open(out).read())

    def test_s34_reboot_grace(self):
        import time
        slept = []
        cfg = os.environ["NEBULAOS_PRINTER_CFG"]
        self.assertEqual(self.c.reboot_grace(slept.append), 0.0)    # nothing known
        open(cfg, "w").close()                                     # SAVE_CONFIG just now
        waited = self.c.reboot_grace(slept.append)
        self.assertTrue(2.0 < waited <= 3.0, waited)
        os.utime(cfg, (time.time() - 10, time.time() - 10))
        self.assertEqual(self.c.reboot_grace(slept.append), 0.0)
        # a Klippy process started 1 s ago (FIRMWARE_RESTART / service restart)
        proc = os.environ["NEBULAOS_PROC_DIR"]
        os.makedirs(os.path.join(proc, "4242"))
        open(os.environ["NEBULAOS_KLIPPY_PIDFILE"], "w").write("4242\n")
        tck = os.sysconf("SC_CLK_TCK")
        fields = ["S"] + ["0"] * 18 + [str(99 * tck)] + ["0"] * 10
        open(os.path.join(proc, "4242", "stat"), "w").write("4242 (python3) " + " ".join(fields))
        open(os.path.join(proc, "uptime"), "w").write("100.00 50.00\n")
        waited = self.c.reboot_grace(slept.append)
        self.assertAlmostEqual(waited, 2.0, places=3)
        self.assertEqual(len(slept), 2)

    def test_s34_reboot_actions_wait_first(self):
        order = []
        self.c.reboot_grace = lambda sleep=None: order.append("grace")
        fake = fake_busy(self.c, [None])
        real = self.c.busy_state
        self.c.busy_state = lambda *a, **k: (order.append("busy"), real(*a, **k))[1]
        self.e.system.request_clean_reset()
        self.e.image.slot_bootable = lambda slot: True
        self.e.system.swap_slot()
        self.assertEqual(order, ["grace", "busy", "grace", "busy"])
        self.assertEqual(len(fake), 2)


class RollbackSchemaTests(unittest.TestCase):
    """G91 rollback audit (S15/S18): an older image reads the keys it knows
    from a NEWER settings file (higher schema, extra keys) instead of falling
    back to the defaults; a malformed schema still falls back."""

    def setUp(self):
        self.e = Env()

    def tearDown(self):
        self.e.cleanup()

    def put(self, mod, obj):
        os.makedirs(os.path.dirname(mod.CONFIG), exist_ok=True)
        with open(mod.CONFIG, "w") as fh:
            json.dump(obj, fh)

    def test_newer_schema_known_keys_read(self):
        n = self.e.network
        self.put(n, {"schema": 2, "hostname": "attic-ke", "future": {"x": 1},
                     "ipv4": {"mode": "static", "address": "10.0.0.5", "prefix": 24,
                              "gateway": "10.0.0.1", "dns": ["10.0.0.1"]}})
        cfg, err = n.load_config()
        self.assertIsNone(err)
        self.assertEqual((cfg["hostname"], cfg["ipv4"]["address"]), ("attic-ke", "10.0.0.5"))
        d = self.e.display
        self.put(d, {"schema": 3, "brightness": d.LEVELS[0], "touch_wake": False, "new": 1})
        cfg, err = d.load_config()
        self.assertEqual((err, cfg["brightness"], cfg["touch_wake"]), (None, d.LEVELS[0], False))
        b = self.e.bootdisplay
        self.put(b, {"schema": 2, "mode": "logo", "image": "custom", "source": "a.png", "z": 0})
        cfg, err = b.load_config()
        self.assertEqual((err, cfg["image"], cfg["source"]), (None, "custom", "a.png"))

    def test_malformed_or_older_schema_falls_back(self):
        for bad in (0, "1", True, None, 1.5):
            self.put(self.e.network, {"schema": bad, "hostname": "x"})
            cfg, err = self.e.network.load_config()
            self.assertTrue(err, bad)
            self.assertEqual(cfg, self.e.network.default_config())


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

    def test_reboot_pending_until_the_reboot(self):
        # G102: armed -> busy (UPDATING) until the reboot, though the lock is gone
        c = self.e.common
        self.s.request_clean_reset()
        self.assertTrue(c.reboot_pending())
        state = c.busy_state("request", facts={"klippy": "ready", "status": {}})
        self.assertEqual((state["reason"], state["message"]), ("UPDATING", c.REBOOT_PENDING_MESSAGE))
        with self.assertRaises(c.Refused):
            self.s.request_clean_reset()
        self.s.cancel_clean_reset()          # the reboot could not be started
        self.assertFalse(c.reboot_pending())
        self.s.request_clean_reset()
        old = time.time() - c.REBOOT_PENDING_SECONDS - 1
        os.utime(c.REBOOT_PENDING, (old, old))
        self.assertFalse(c.reboot_pending())  # a reboot that never came stops counting
        self.s.cancel_clean_reset()
        self.cmdline("/dev/mmcblk0p8")
        self.s.swap_slot()
        self.assertTrue(c.reboot_pending())
        self.s.keep_slot()
        self.assertFalse(c.reboot_pending())

    def test_swap_either_slot(self):
        # 2026-10-14: NebulaOS may run from either slot; swap goes to the other.
        self.cmdline("/dev/mmcblk0p8")
        self.assertEqual(self.s.swap_slot()["next_boot"], "A")
        self.s.keep_slot()
        self.cmdline("/dev/mmcblk0p7")
        self.assertEqual(self.s.swap_slot()["next_boot"], "B")
        self.assertEqual(open(self.log).read().split(), ["A", "B", "B"])
        self.e.common.clear_reboot_pending()     # (the reboot would follow)
        # (the switch into the unconfirmed slot B left a trial; booted into
        # B it would run - here it is simply cleared)
        os.unlink(self.e.image.TRIAL)
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
            bytes(bad_crc): "damaged", bytes(other_board): "another mainboard",
            bytes(no_header): "no vendor header", bytes(wrong_slot): "mainboard",
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
        self.assertIn("no vendor header", junk["problem"])
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
            # G91: the MCU flash lock is part of the shared check (UPDATING)
            self.assertEqual((cm.exception.code, cm.exception.refused), ("UPDATING", True))
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
        # G35: Creality's own MCU firmware is accepted, with a plain warning.
        stock = dict(ok, klipper_version="38d96adc-dirty-20231016_135251-longer-virtual-machine")
        self.assertIn("the original MCU firmware", note(stock, "v0.13.0-742-g01a9c2f92"))
        other = dict(ok, klipper_version="12345678-20240101_000000-longer-virtual-machine")
        self.assertIn("the original MCU firmware", note(other, "v0.13.0-742-g01a9c2f92"))


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
    sys.stdout.buffer.write(open(os.path.join(root, rest[1]), "rb").read())
else:
    for f in files:
        if any(fnmatch.fnmatch(f, pat) for pat in rest[1:]):
            dst = os.path.join(outdir, f)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(os.path.join(root, f), dst)
"""


class LogsTests(unittest.TestCase):
    """G60 (2026-10-16): general log level, status file, "Save logs to USB"."""

    def setUp(self):
        self.e = Env()
        self.l = importlib.import_module("nebulaos_osconfig.logs")
        t = self.e.tmp
        self.l.LEVEL_FILE = os.path.join(t, "log-level")
        self.l.DEBUG_SINCE_FILE = self.l.LEVEL_FILE + ".debug-since"
        self.calls = os.path.join(t, "calls")
        self.l.SYSLOGD_INIT = os.path.join(self.e.bin, "S01syslogd")
        write_exe(self.l.SYSLOGD_INIT, 'echo "syslogd $1" >> "%s"\n' % self.calls)
        self.l.LOGS_DIR = os.path.join(t, "logs")
        self.l.STATE_FILE = os.path.join(self.l.LOGS_DIR, "nebulaos-state.txt")
        self.l.USB_DIR = os.path.join(t, "usb")
        self.l.CONFIG_DIR = os.path.join(t, "config")
        self.l.EXTRA_LOG_DIRS = [os.path.join(t, "nlogs")]
        self.l.RUN_FILES = ()
        self.l.EXTRA_FILES = [os.path.join(t, "retention.log")]
        os.makedirs(self.l.LOGS_DIR)
        os.makedirs(os.path.join(self.l.CONFIG_DIR, "backups"))
        os.makedirs(self.l.EXTRA_LOG_DIRS[0])

    def tearDown(self):
        self.e.cleanup()

    def test_level(self):
        self.assertEqual(self.l.get_level(), "info")
        out = self.l.set_level("debug")
        self.assertEqual((out["level"], out["system_log"]), ("debug", "applied"))
        self.assertEqual(open(self.l.LEVEL_FILE).read(), "debug\n")   # one word: shell readers
        self.assertEqual(self.l.get_level(), "debug")
        self.assertIn("syslogd restart", open(self.calls).read())
        with self.assertRaises(self.e.common.OsConfigError):
            self.l.set_level("trace")
        self.assertEqual(self.l.status()["levels"], ["info", "warning", "debug"])

    def test_debug_expires_after_24_hours(self):
        """G69: a forgotten Debug never stays on; a level set before the
        clock was valid starts its 24 hours once the clock is right."""
        now = 1792100000
        open(self.l.LEVEL_FILE, "w").write("debug\n")             # set before the clock
        self.assertEqual(self.l.expire_debug(now=1583020800)["result"], "UNCHANGED")
        self.assertEqual(self.l.expire_debug(now=now)["result"], "UNCHANGED")
        self.assertEqual(open(self.l.LEVEL_FILE).read(), "debug\n")
        self.assertEqual(open(self.l.DEBUG_SINCE_FILE).read().strip(), str(now))
        self.assertEqual(self.l.status()["debug_until"], now + 86400)
        self.assertEqual(self.l.expire_debug(now=now + 86399)["level"], "debug")
        out = self.l.expire_debug(now=now + 86400)
        self.assertEqual((out["result"], self.l.get_level()), ("EXPIRED", "info"))
        self.assertNotIn("debug_until", self.l.status())
        self.assertFalse(os.path.exists(self.l.DEBUG_SINCE_FILE))
        open(self.l.LEVEL_FILE, "w").write("warning\n")
        self.assertEqual(self.l.expire_debug(now=now + 10 ** 6)["level"], "warning")

    def test_redact(self):
        r = self.l.redact
        self.assertEqual(r("psk=hunter2"), "psk=[redacted]")
        self.assertEqual(r('  password: "x y"'), "  password: [redacted]")
        self.assertEqual(r("api_key = abc"), "api_key = [redacted]")
        for keep in ("bypass: 3", "PASS  install check 17/17", "authorization component loaded",
                     "Klipper state: ready", "tokenizer loaded"):
            self.assertEqual(r(keep), keep)

    def test_state_file_and_zip(self):
        open(os.path.join(self.l.LOGS_DIR, "klippy.log"), "w").write("start\npsk=secret1\nready\n")
        open(os.path.join(self.l.LOGS_DIR, "system.log.0"), "w").write("old line\n")
        open(os.path.join(self.l.EXTRA_LOG_DIRS[0], "memguard.log"), "w").write("mg\n")
        open(os.path.join(self.l.CONFIG_DIR, "printer.cfg"), "w").write("[printer]\n")
        open(os.path.join(self.l.CONFIG_DIR, "moonraker.conf"), "w").write("[authorization]\napi_key: k3y\n")
        open(os.path.join(self.l.CONFIG_DIR, "backups", "printer-1.cfg"), "w").write("x\n")
        open(self.l.EXTRA_FILES[0], "w").write("retention ran\n")
        os.utime(os.path.join(self.l.LOGS_DIR, "klippy.log"), (1792100000, 1792100000))
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.l.save_logs()
        self.assertEqual(cm.exception.code, "NO_USB")
        os.makedirs(os.path.join(self.l.USB_DIR, "sda1"))
        out = self.l.save_logs()
        self.assertEqual(out["result"], "SAVED")
        self.assertTrue(out["safe_to_remove"])
        self.assertTrue(os.path.isfile(self.l.STATE_FILE))
        import zipfile
        z = zipfile.ZipFile(os.path.join(self.l.USB_DIR, "sda1", out["file"]))
        names = z.namelist()
        for want in ("logs/klippy.log", "logs/system.log.0", "logs/nebulaos-state.txt",
                     "nebulaos/nlogs/memguard.log", "config/printer.cfg", "config/moonraker.conf", "run/dmesg.txt"):
            self.assertIn(want, names)
        self.assertTrue(any(n.endswith("retention.log") for n in names))
        # G68: the file's own date, not 1980
        self.assertEqual(z.getinfo("logs/klippy.log").date_time[:3], (2026, 10, 15))
        self.assertNotIn("config/backups/printer-1.cfg", names)
        self.assertNotIn(b"secret1", z.read("logs/klippy.log"))
        self.assertIn(b"psk=[redacted]", z.read("logs/klippy.log"))
        self.assertNotIn(b"k3y", z.read("config/moonraker.conf"))
        self.assertEqual([n for n in os.listdir(os.path.join(self.l.USB_DIR, "sda1")) if n.endswith(".part")], [])
        state = open(self.l.STATE_FILE).read()
        for section in ("== system ==", "== slots ==", "== mcu ==", "== log level ==",
                        "== network ==", "== wi-fi ==", "== processes =="):
            self.assertIn(section, state)


class SettingsSnapshotTests(unittest.TestCase):
    """G65 (2026-10-16): copies of the user's settings in config/backups; the
    Moonraker database copy never under config."""

    def setUp(self):
        self.e = Env()
        self.s = importlib.import_module("nebulaos_osconfig.snapshot")
        t = self.e.tmp
        self.pdata = os.path.join(t, "pd")
        self.s.CONFIG_DIR = os.path.join(self.pdata, "config")
        self.s.BACKUPS_DIR = os.path.join(self.s.CONFIG_DIR, "backups")
        self.s.CALIBRATION_DIR = os.path.join(self.pdata, "calibration")
        self.s.DATABASE_DIR = os.path.join(self.pdata, "database")
        self.s.API_BACKUP_DIR = os.path.join(self.pdata, "backup", "database")
        self.s.DB_FILE_DIR = os.path.join(t, "data", "system", "settings-db")
        self.s.GUPPY_CONFIG = os.path.join(t, "guppy.json")
        self.s.MOONRAKER = "http://127.0.0.1:9"          # nothing listens
        for d in ("config/macros", "calibration", "database"):
            os.makedirs(os.path.join(self.pdata, d))
        self.w("config/printer.cfg", "[printer]\n#*# [bed_mesh default]\n#*# points = 0.1\n")
        self.w("config/moonraker.conf", "[server]\n")
        self.w("config/macros/mine.cfg", "[gcode_macro HI]\n")
        self.w("calibration/journal.json", "{}\n")
        self.w("database/moonraker-sql.db", "SQLITE")
        self.w("database/moonraker-sql.db-wal", "WAL")
        with open(self.s.GUPPY_CONFIG, "w") as h:
            h.write("{}")

    def w(self, rel, text):
        with open(os.path.join(self.pdata, rel), "w") as h:
            h.write(text)

    def tearDown(self):
        self.e.cleanup()

    def test_new_system_snapshot_with_database_file(self):
        out = self.s.take("new-system", db="file", now=1792100000)
        self.assertEqual(out["result"], "TAKEN")
        snap = os.path.join(self.s.BACKUPS_DIR, out["name"])
        for rel in ("printer.cfg", "moonraker.conf", "macros/mine.cfg", "calibration/journal.json",
                    "nebulascreen/nebulascreen.json", "SNAPSHOT.txt"):
            self.assertTrue(os.path.isfile(os.path.join(snap, rel)), rel)
        self.assertIn("#*# points = 0.1", open(os.path.join(snap, "printer.cfg")).read())
        # the database (login data, API keys) never goes under config
        for root, _, names in os.walk(self.s.CONFIG_DIR):
            self.assertFalse([n for n in names if "sql" in n], root)
        db = os.path.join(self.s.DB_FILE_DIR, out["name"])
        self.assertEqual(sorted(os.listdir(db)), ["moonraker-sql.db", "moonraker-sql.db-wal"])
        self.assertIn("database: " + db, open(os.path.join(snap, "SNAPSHOT.txt")).read())

    def test_if_changed_and_keep_newest(self):
        first = self.s.take("changed", db="none", if_changed=True, now=1792100000)
        self.assertEqual(first["result"], "TAKEN")
        self.assertEqual(self.s.take("changed", db="none", if_changed=True, now=1792100100)["result"],
                         "UNCHANGED")
        for i in range(7):
            self.w("config/printer.cfg", "[printer]\n# %d\n" % i)
            self.s.take("changed", db="none", if_changed=True, now=1792100200 + i * 60)
        names = self.s.snapshots()
        self.assertEqual(len(names), self.s.KEEP)
        self.assertNotIn(first["name"], names)
        self.assertIn("# 6", open(os.path.join(self.s.BACKUPS_DIR, names[-1], "printer.cfg")).read())

    def test_new_system_snapshot_outlives_later_changes(self):
        first = self.s.take("new-system", db="none", now=1792000000)["name"]
        for i in range(8):
            self.w("config/printer.cfg", "[printer]\n# %d\n" % i)
            self.s.take("changed", db="none", if_changed=True, now=1792100000 + i * 60)
        names = self.s.snapshots()
        self.assertIn(first, names)
        self.assertEqual(len(names), self.s.KEEP + 1)

    def test_api_backup_unreachable_is_recorded(self):
        out = self.s.take("manual", db="api", now=1792100000)
        self.assertEqual(out["result"], "TAKEN")
        self.assertTrue(out["database"].startswith("skipped"))
        with self.assertRaises(self.e.common.OsConfigError):
            self.s.take("whenever")


class NoticeTests(unittest.TestCase):
    """G65: one-line notices for the screen; ids never reach outside the folder."""

    def setUp(self):
        self.e = Env()
        self.sy = importlib.import_module("nebulaos_osconfig.system")
        self.sy.NOTICES_DIR = os.path.join(self.e.tmp, "notices")
        os.makedirs(self.sy.NOTICES_DIR)

    def tearDown(self):
        self.e.cleanup()

    def test_list_and_ack(self):
        with open(os.path.join(self.sy.NOTICES_DIR, "config-edits.txt"), "w") as h:
            h.write("Your changes to machine.cfg were replaced.\n")
        with open(os.path.join(self.sy.NOTICES_DIR, "Bad Name.txt"), "w") as h:
            h.write("x")
        self.assertEqual(self.sy.notices(), [{"id": "config-edits",
                                              "text": "Your changes to machine.cfg were replaced."}])
        self.assertEqual(self.sy.ack_notice("config-edits")["result"], "ACKNOWLEDGED")
        self.assertEqual(self.sy.notices(), [])
        self.assertEqual(self.sy.ack_notice("config-edits")["result"], "ACKNOWLEDGED")   # idempotent
        victim = os.path.join(self.e.tmp, "x.txt")
        open(victim, "w").write("keep")
        for bad in ("../x", "A", "", None, "a/b"):
            with self.assertRaises(self.e.common.OsConfigError):
                self.sy.ack_notice(bad)
        self.assertTrue(os.path.exists(victim))


class CrealityCleanupTests(unittest.TestCase):
    """G66 (2026-10-16): "Clean up Creality files" removes a fixed list from
    the data drive - never the print files, never into a mount, a busy swap
    file or a symlink target, never NebulaOS or the device's own files."""

    def setUp(self):
        self.e = Env()
        self.c = importlib.import_module("nebulaos_osconfig.cleanup")
        t = self.e.tmp
        self.d = os.path.join(t, "usrdata")
        self.c.DATA = self.d
        self.c.NEBULAOS_ROOT = os.path.join(self.d, "nebulaos")
        self.c.PROC_MOUNTS = os.path.join(t, "mounts")
        self.c.PROC_SWAPS = os.path.join(t, "swaps")
        self.c.other_slot_system = lambda: "creality"
        files = ["creality/userdata/config/system_config.json", "creality/userdata/delay_image/video/1.mp4",
                 "creality/upgrade/old.img", "opt/bin/gcc", "helper-script/x.sh", "swap",
                 "printer_data/config/printer.cfg", "printer_data/logs/klippy.log",
                 "printer_data/gcodes/benchy.gcode", "printer_data/gcodes/USB/stick.gcode",
                 "nebulaos/printer_data/config/printer.cfg", "macaddr.txt", "wpa_supplicant.conf",
                 "factory_test_result", ".nebulaos-clean-reset.log", "mainsail/index.html",
                 "elsewhere/secret.txt"]
        for rel in files:
            path = os.path.join(self.d, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as h:
                h.write("x" * 5000)
        os.symlink(os.path.join(self.d, "elsewhere"), os.path.join(self.d, "moonraker"))
        with open(self.c.PROC_MOUNTS, "w") as h:
            h.write("/dev/sda1 %s vfat rw 0 0\n" % os.path.join(self.d, "printer_data/gcodes/USB"))
        with open(self.c.PROC_SWAPS, "w") as h:
            h.write("Filename Type Size Used Priority\n")

    def tearDown(self):
        self.e.cleanup()

    def exists(self, rel):
        return os.path.lexists(os.path.join(self.d, rel))

    def test_plan_then_clean(self):
        plan = self.c.plan()
        self.assertEqual(plan["other_slot"], "creality")
        self.assertGreater(plan["bytes"], 0)
        self.assertGreater(plan["videos_bytes"], 0)
        paths = [i["path"] for i in plan["items"]]
        self.assertNotIn(os.path.join(self.d, "printer_data/gcodes"), paths)
        with_videos = self.c.plan(include_videos=True)["bytes"]
        self.assertGreater(with_videos, plan["bytes"])
        out = self.c.clean_creality()
        self.assertEqual(out["result"], "CLEANED")
        for gone in ("creality/userdata/config", "creality/upgrade", "opt", "helper-script", "swap",
                     "printer_data/config", "printer_data/logs", "mainsail", "moonraker"):
            self.assertFalse(self.exists(gone), gone)
        for kept in ("printer_data/gcodes/benchy.gcode", "printer_data/gcodes/USB/stick.gcode",
                     "nebulaos/printer_data/config/printer.cfg", "macaddr.txt", "wpa_supplicant.conf",
                     "factory_test_result", ".nebulaos-clean-reset.log",
                     "creality/userdata/delay_image/video/1.mp4",     # videos only when asked
                     "elsewhere/secret.txt"):                        # symlink target untouched
            self.assertTrue(self.exists(kept), kept)
        self.c.clean_creality(include_videos=True)
        self.assertFalse(self.exists("creality"))

    def test_busy_swap_and_mount_are_kept(self):
        with open(self.c.PROC_SWAPS, "a") as h:
            h.write("%s file 1000 0 -2\n" % os.path.join(self.d, "swap"))
        with open(self.c.PROC_MOUNTS, "a") as h:
            h.write("/dev/x %s ext4 rw 0 0\n" % os.path.join(self.d, "opt/mnt"))
        out = self.c.clean_creality()
        why = {os.path.basename(k["path"]): k["why"] for k in out["kept"]}
        self.assertEqual(why.get("swap"), "in use as swap")
        self.assertEqual(why.get("opt"), "a drive is mounted there")
        self.assertTrue(self.exists("swap") and self.exists("opt/bin/gcc"))

    def test_swap_inside_a_folder_is_kept(self):
        os.makedirs(os.path.join(self.d, "creality/sw"))
        with open(os.path.join(self.d, "creality/sw/swapfile"), "w") as h:
            h.write("s")
        with open(self.c.PROC_SWAPS, "a") as h:
            h.write("%s file 1000 0 -2\n" % os.path.join(self.d, "creality/sw/swapfile"))
        out = self.c.clean_creality()
        why = {os.path.basename(k["path"]): k["why"] for k in out["kept"]}
        self.assertEqual(why.get("creality"), "in use as swap")
        self.assertTrue(self.exists("creality/sw/swapfile"))

    def test_storage_overview(self):
        out = self.c.storage()
        labels = [p["label"] for p in out["parts"]]
        self.assertEqual(labels, ["Print files", "Logs", "Uploads", "Backups", "NebulaOS", "Creality files"])
        self.assertGreater(out["parts"][-1]["bytes"], 0)


class PowerOnLogoTests(unittest.TestCase):
    """G58/G40 (2026-10-15): the power-on logo in the running slot's RTOS -
    against fake rtos/rtos2 partitions holding a synthetic image (the real
    zero.bin is the vendor's and stays out of the repository); the two pins
    are set to that image's values."""

    def setUp(self):
        import hashlib
        from PIL import Image
        self.Image = Image
        self.e = Env()
        self.p = importlib.import_module("nebulaos_osconfig.poweronlogo")
        self.b = self.e.bootdisplay
        p, t = self.p, self.e.tmp
        self.dev, self.sys = os.path.join(t, "dev"), os.path.join(t, "sys")
        os.makedirs(self.dev)
        # synthetic image: random code around an "original" 480x272 JPEG
        buf = io.BytesIO()
        Image.new("RGB", (480, 272), (200, 30, 30)).save(buf, "JPEG", quality=60, subsampling=2)
        orig = buf.getvalue()
        self.assertLessEqual(len(orig), p.SIZE)
        self.orig_slot = orig + b"\0" * (p.SIZE - len(orig))
        body = bytearray(os.urandom(p.IMAGE_SIZE))
        body[p.OFFSET:p.OFFSET + p.SIZE] = self.orig_slot
        self.image = bytes(body)
        p.FRAME_SHA256 = hashlib.sha256(body[:p.OFFSET] + b"\0" * p.SIZE + body[p.OFFSET + p.SIZE:]).hexdigest()
        p.ORIGINAL_LOGO_SHA256 = hashlib.sha256(self.orig_slot).hexdigest()
        for part, name in (("mmcblk0p3", "rtos"), ("mmcblk0p4", "rtos2")):
            open(os.path.join(self.dev, part), "wb").write(self.image + b"\0" * 4096)
            os.makedirs(os.path.join(self.sys, part))
            open(os.path.join(self.sys, part, "uevent"), "w").write("PARTNAME=%s\n" % name)
        p.DEV_DIR, p.SYS_BLOCK = self.dev, self.sys
        p.BACKUP = os.path.join(t, "data", "rtos-logo", "original.jpg")
        self.slot("B")

    def tearDown(self):
        self.e.cleanup()

    def slot(self, s):
        open(os.environ["NEBULAOS_CMDLINE"], "w").write(
            "root=%s rootfstype=squashfs\n" % {"A": "/dev/mmcblk0p7", "B": "/dev/mmcblk0p8"}[s])

    def part(self, name):
        return open(os.path.join(self.dev, name), "rb").read()

    def upload(self, name, colour=(20, 200, 90), size=(800, 600)):
        os.makedirs(self.b.UPLOAD_DIR, exist_ok=True)
        path = os.path.join(self.b.UPLOAD_DIR, name)
        self.Image.new("RGB", size, colour).save(path, "PNG")
        return name

    def test_status_and_nebulaos_logo(self):
        st = self.p.status()
        self.assertEqual((st["slot"], st["logo"], st["writable"], st["original_available"]),
                         ("B", "original", True, True))
        out = self.p.set_nebulaos()
        self.assertEqual((out["result"], out["slot"], out["logo"]), ("WRITTEN", "B", "nebulaos"))
        after = self.part("mmcblk0p4")
        p = self.p
        # only the logo slot changed; the original was kept first; rtos (A) untouched
        self.assertEqual(after[:p.OFFSET], self.image[:p.OFFSET])
        self.assertEqual(after[p.OFFSET + p.SIZE:p.IMAGE_SIZE], self.image[p.OFFSET + p.SIZE:])
        self.assertEqual(open(p.BACKUP, "rb").read(), self.orig_slot)
        self.assertEqual(self.part("mmcblk0p3")[:p.IMAGE_SIZE], self.image)
        self.assertEqual(self.p.set_nebulaos()["result"], "UNCHANGED")

    def test_custom_then_restore(self):
        out = self.b.set_image(self.upload("mine.png"))
        self.assertEqual(out["config"]["image"], "custom")                  # Linux boot screen
        self.assertEqual((out["power_on"]["result"], out["power_on"]["logo"]), ("WRITTEN", "custom"))
        slot = self.part("mmcblk0p4")[self.p.OFFSET:self.p.OFFSET + self.p.SIZE]
        info = self.p.rtos_logo.parse_jpeg(slot)
        self.assertEqual((info.width, info.height, info.baseline()), (480, 272, True))
        self.assertEqual(self.p.restore_original()["logo"], "original")
        self.assertEqual(self.part("mmcblk0p4")[:self.p.IMAGE_SIZE], self.image)
        # reset-image: builtin splash and the NebulaOS power-on logo
        out = self.b.reset_image()
        self.assertEqual((out["config"]["image"], out["power_on"]["logo"]), ("builtin", "nebulaos"))

    def test_phone_jpeg_with_exif_rotation(self):
        os.makedirs(self.b.UPLOAD_DIR, exist_ok=True)
        path = os.path.join(self.b.UPLOAD_DIR, "photo.jpg")
        exif = self.Image.Exif()
        exif[0x0112] = 6                       # "rotate 90" as phones store it
        self.Image.new("RGB", (400, 300), (10, 200, 10)).save(path, "JPEG", exif=exif)
        out = self.b.set_image("photo.jpg")
        self.assertEqual((out["result"], out["image"]["format"]), ("APPLIED", "JPEG"))
        self.assertTrue(os.path.exists(os.path.join(self.b.BOOT_DIR, "custom.jpg")))
        self.assertEqual(out["power_on"]["result"], "WRITTEN")
        img = self.b._fit(self.Image.open(path), 480, 272)
        # turned upright: 300 wide x 400 high fitted into 480x272 -> black side bars
        self.assertEqual(img.getpixel((5, 136)), (0, 0, 0))

    def test_slot_a_running_writes_rtos(self):
        # G40: from slot A the rtos partition (p3) gets the logo, rtos2 stays
        self.slot("A")
        self.assertEqual(self.p.set_nebulaos()["slot"], "A")
        self.assertEqual(self.p.classify(self.part("mmcblk0p3")[:self.p.IMAGE_SIZE]), "nebulaos")
        self.assertEqual(self.part("mmcblk0p4")[:self.p.IMAGE_SIZE], self.image)

    def test_unknown_rtos_is_never_written(self):
        bad = bytearray(self.image)
        bad[100] ^= 0xFF
        open(os.path.join(self.dev, "mmcblk0p4"), "wb").write(bytes(bad))
        self.assertEqual((self.p.status()["logo"], self.p.status()["writable"]), ("unknown", False))
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.p.set_nebulaos()
        self.assertEqual(cm.exception.code, "RTOS_UNKNOWN")
        self.assertEqual(self.part("mmcblk0p4"), bytes(bad))
        # Run 10 rule: Apply changes both logos or neither - the boot screen
        # stays as it was when the power-on logo cannot be written.
        before = self.b.load_config()[0]
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.b.set_image(self.upload("x.png"))
        self.assertEqual(cm.exception.code, "RTOS_UNKNOWN")
        self.assertEqual(self.b.load_config()[0], before)
        self.assertIsNone(self.b.custom_path())

    def test_failed_power_on_write_restores_the_boot_screen(self):
        """Both or neither: a write that fails after the boot screen changed
        puts the boot screen back."""
        self.b.set_image(self.upload("first.png"))
        before = (self.b.load_config()[0], open(self.b.custom_path(), "rb").read())
        real = self.p._write
        def broken(data):
            raise self.e.common.OsConfigError("WRITE_FAILED", "did not read back")
        self.p.write_slot = broken
        try:
            with self.assertRaises(self.e.common.OsConfigError) as cm:
                self.b.set_image(self.upload("second.png"))
        finally:
            self.p.write_slot = lambda data: real(data)
        self.assertIn("nothing was changed", cm.exception.message)
        self.assertEqual((self.b.load_config()[0], open(self.b.custom_path(), "rb").read()), before)

    def test_restore_from_the_other_slot(self):
        # no backup on this printer, but slot A's RTOS still has the original
        nebula = bytearray(self.image)
        nebula[self.p.OFFSET:self.p.OFFSET + self.p.SIZE] = self.p._nebulaos_slot()
        open(os.path.join(self.dev, "mmcblk0p4"), "wb").write(bytes(nebula))
        self.assertTrue(self.p.status()["original_available"])
        self.assertEqual(self.p.restore_original()["logo"], "original")
        open(os.path.join(self.dev, "mmcblk0p3"), "wb").write(bytes(nebula))
        open(os.path.join(self.dev, "mmcblk0p4"), "wb").write(bytes(nebula))
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.p.restore_original()
        self.assertEqual(cm.exception.code, "NO_ORIGINAL")

    def test_detailed_image_is_compressed_to_fit(self):
        os.makedirs(self.b.UPLOAD_DIR, exist_ok=True)
        path = os.path.join(self.b.UPLOAD_DIR, "noise.png")
        self.Image.frombytes("RGB", (480, 272), os.urandom(480 * 272 * 3)).save(path, "PNG")
        # Run 11 test: every image must fit - pure noise (the worst case)
        # at 480x272 and at 1024x1024 included; softened when it must be.
        data, quality = self.p.convert(path)
        self.assertEqual(len(data), self.p.SIZE)
        self.assertIn("softened", str(quality))
        big = os.path.join(self.b.UPLOAD_DIR, "noise-big.png")
        self.Image.frombytes("RGB", (1024, 1024), os.urandom(1024 * 1024 * 3)).save(big, "PNG")
        data, quality = self.p.convert(big)
        self.assertEqual(len(data), self.p.SIZE)
        photo = os.path.join(self.b.UPLOAD_DIR, "gradient.png")
        img = self.Image.new("RGB", (480, 272))
        img.putdata([(x % 256, (x * y) % 256, y % 256) for y in range(272) for x in range(480)])
        img.save(photo, "PNG")
        data, quality = self.p.convert(photo)
        self.assertEqual(len(data), self.p.SIZE)

    def test_shipped_copies_match_the_packager(self):
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        lib = os.path.join(here, "scripts", "build", "overlay", "usr", "lib", "nebulaos", "python")
        for a, b in (("rtos_logo.py", "rtos_logo.py"),
                     (os.path.join("assets", "nebulaos-rtos-logo.jpg"),
                      os.path.join("assets", "nebulaos-rtos-logo.jpg"))):
            self.assertEqual(open(os.path.join(lib, a), "rb").read(),
                             open(os.path.join(here, "scripts", "package", b), "rb").read(), a)


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
        self.e.common.IMAGE_TRIAL = m.TRIAL
        m.LAST = os.path.join(t, "last.json")
        m.CONFIRMED_DIR = os.path.join(t, "confirmed")
        m.SHED_SCREEN = os.path.join(t, "shed-nebulascreen")
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
                    # T3: flip the byte. Writing b"X" left the chunk intact
                    # whenever the random data already started with "X"
                    # (1 in 256), and the "damaged" image then installed.
                    chunk = bytes([chunk[0] ^ 0xFF]) + chunk[1:]
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
        self.assertEqual((c["system"], c["kernel"]), ("nebulaos", "Linux-6.6.157-rt79"))
        self.assertEqual(len(c["sha256"]), 64)

    def rootfs(self, part, tree_files, mkfs=1):
        """A fake squashfs superblock in a partition plus the tree a fake
        mount of it shows."""
        sb = bytearray(48)
        sb[:4] = b"hsqs"
        struct.pack_into("<I", sb, 8, mkfs)
        open(os.path.join(self.dev, part), "r+b").write(bytes(sb))
        tree = os.path.join(self.dev, part + ".tree")
        shutil.rmtree(tree, ignore_errors=True)
        for rel, text in tree_files.items():
            os.makedirs(os.path.dirname(os.path.join(tree, rel)), exist_ok=True)
            open(os.path.join(tree, rel), "w").write(text)
        return tree

    def fake_mount(self):
        log = os.path.join(self.e.tmp, "mount.calls")
        write_exe(os.path.join(self.e.bin, "mount"),
                  'echo "mount $*" >> "%s"; for a; do :; done; cp -a "$5.tree/." "$6/"\n' % log)
        write_exe(os.path.join(self.e.bin, "umount"),
                  'echo "umount $*" >> "%s"; rm -rf "$1"/*\n' % log)
        self.i.MOUNT, self.i.UMOUNT = os.path.join(self.e.bin, "mount"), os.path.join(self.e.bin, "umount")
        return log

    def test_slot_identity(self):
        # G46/G48: running slot from its own root, the other by a read-only mount
        log = self.fake_mount()
        own = self.rootfs("mmcblk0p8", {})
        self.i.ROOT_DIR = os.path.join(self.e.tmp, "root")
        os.makedirs(os.path.join(self.i.ROOT_DIR, "opt", "nebulaos-seeds"))
        open(os.path.join(self.i.ROOT_DIR, "opt", "nebulaos-seeds", "seed-manifest.json"), "w").write(
            json.dumps({"firmware_head": "14a9280" + "0" * 33, "build_date": "2026-10-15T08:00:00Z",
                        "nebulaos_version": "0.9.0"}))
        self.rootfs("mmcblk0p7", {"etc/ota_info": "board=F005\nota_version=1.1.0.12\n"})
        s = self.i.slots_info()
        self.assertEqual((s["B"]["build"], s["B"]["date"]), ("14a9280", "2026-10-15"))
        self.assertEqual(s["B"]["nebulaos_version"], "0.9.0")
        self.assertNotIn("version", s["A"])                       # status never mounts
        self.assertFalse(os.path.exists(log))
        s = self.i.list_files()["slots"]
        self.assertEqual(s["A"]["version"], "1.1.0.12")
        self.assertEqual(open(log).read().count("mount -t squashfs -o ro"), 1)
        self.i.list_files()                                       # cached
        self.assertEqual(open(log).read().count("mount -t squashfs -o ro"), 1)
        self.assertEqual(self.i.slots_info()["A"]["version"], "1.1.0.12")
        # a new image in slot A (new superblock): read again - but not while an install runs
        self.rootfs("mmcblk0p7", {"opt/nebulaos-seeds/seed-manifest.json":
                                  json.dumps({"firmware_head": "abcdef1234", "build_date": "2026-10-16"})}, mkfs=2)
        os.makedirs(self.i.JOB_DIR, exist_ok=True)
        json.dump({"state": "running"}, open(self.i.JOB_STATE, "w"))
        self.assertEqual(self.i.list_files()["slots"]["A"].get("build"), None)
        os.unlink(self.i.JOB_STATE)
        self.assertEqual(self.i.list_files()["slots"]["A"]["build"], "abcdef1")
        self.assertIn("umount", open(log).read())

    def test_file_identity(self):
        # G48: the list shows each .img's version and NebulaOS build record
        archive, _, _ = self.package()
        inner = os.path.join(open(archive).read(), "Ender-3_V3_KE_F005_ota_img_V9.9", "ota_v9.9")
        open(os.path.join(inner, "nebulaos-build.json"), "w").write(
            json.dumps({"firmware_head": "14a9280" + "1" * 33, "build_date": "2026-10-15T09:00:00Z"}))
        f = self.i.list_files()["files"][0]
        self.assertEqual((f["version"], f["build"], f["date"]), ("9.9", "14a9280", "2026-10-15"))
        c = self.i.check("upload/nebula.img")
        self.assertEqual((c["build"], c["date"]), ("14a9280", "2026-10-15"))
        self.package("other.img")
        g = [x for x in self.i.list_files()["files"] if x["name"] == "other.img"][0]
        self.assertEqual((g["version"], g.get("build")), ("9.9", None))
        open(os.path.join(self.upload, "junk.img"), "w").write("not an archive")
        j = [x for x in self.i.list_files()["files"] if x["name"] == "junk.img"][0]
        self.assertNotIn("version", j)

    def test_cli_entry_point(self):
        # ke-dev 2026-10-15: cli.py never imported the image module, so every
        # machine.nebulaos.image.* call failed with NameError on the printer
        # while the module-level tests passed. Go through the real entry point.
        self.package()
        out = io.StringIO()
        old = sys.stdout
        for argv, key in ((["image", "list"], "files"), (["image", "status"], "slots"),
                          (["image", "check", "--file", "upload/nebula.img"], "sha256")):
            sys.stdout = out = io.StringIO()
            try:
                rc = self.e.cli.main(argv)
            finally:
                sys.stdout = old
            reply = json.loads(out.getvalue().splitlines()[-1])
            self.assertEqual(rc, 0, out.getvalue())
            self.assertTrue(reply.get("ok"), reply)
            self.assertIn(key, reply)

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

    # -- G91 step 5: refuse at the request, stop at the points of no return ----

    def test_install_refused_while_busy(self):
        # S1/S2: printing or paused -> refused at once, nothing started,
        # the maintenance lock released again.
        archive, _, _ = self.package()
        sha = self.i.sha256_file(archive)
        import subprocess as sp
        started, old = [], sp.Popen
        sp.Popen = lambda *a, **k: started.append(a[0])
        try:
            for reason in ("PRINTING", "PAUSED", "ACTIVE", "CALIBRATING", "LOW_MEMORY", "UNKNOWN"):
                calls = fake_busy(self.e.common, [reason])
                with self.assertRaises(self.e.common.Refused) as cm:
                    self.i.install("upload/nebula.img", sha)
                self.assertEqual(cm.exception.code, reason)
                self.assertEqual(calls[0][0], "request")
                self.assertIsNone(self.e.common.lock_holder(self.e.common.MAINTENANCE_LOCK))
            self.assertEqual(started, [])
            self.assertFalse(os.path.exists(self.i.JOB_STATE))
        finally:
            sp.Popen = old

    def test_install_refusal_through_the_cli_is_exit_3(self):
        archive, _, _ = self.package()
        fake_busy(self.e.common, ["PRINTING"])
        out, old = io.StringIO(), sys.stdout
        sys.stdout = out
        try:
            rc = self.e.cli.main(["image", "install", "--file", "upload/nebula.img",
                                  "--sha256", self.i.sha256_file(archive)])
        finally:
            sys.stdout = old
        reply = json.loads(out.getvalue())
        self.assertEqual(rc, 3)
        self.assertEqual((reply["error"], reply["refused"]), ("PRINTING", True))
        self.assertEqual(reply["message"], "Not possible while a print is running.")

    def test_double_tap_refused_by_the_maintenance_lock(self):
        # S6: a second install (or an MCU flash, a second screen/Mainsail
        # tab) while the maintenance lock is held: UPDATING, nothing started.
        archive, _, _ = self.package()
        import subprocess as sp
        started, old = [], sp.Popen
        holder = self.e.common.MaintenanceLock("other-job").acquire()
        sp.Popen = lambda *a, **k: started.append((a[0], k.get("pass_fds")))
        try:
            with self.assertRaises(self.e.common.Refused) as cm:
                self.i.install("upload/nebula.img", self.i.sha256_file(archive))
            self.assertEqual(cm.exception.code, "UPDATING")
            self.assertEqual(cm.exception.message, "Another update is running.")
            holder.release()
            fake_busy(self.e.common, [None])
            self.i.install("upload/nebula.img", self.i.sha256_file(archive))
            argv, fds = started[0]
            self.assertEqual(argv[1:3], ["image", "worker"])
            self.assertEqual(argv[-2], "--holder")
            self.assertTrue(argv[-1].startswith("image-"))
            self.assertEqual(len(fds), 1)                # the lock handed to the worker
        finally:
            sp.Popen = old
            holder.release()

    def test_maintenance_lock_holder_is_excluded(self):
        # R1: the job's own lock never makes its own checks busy.
        c = self.e.common
        lock = c.MaintenanceLock("image-1").acquire()
        try:
            facts = {"klippy": "not_ready", "update_manager_busy": False}
            self.assertFalse(c.busy_state("point_of_no_return", "image-1", facts)["busy"])
            self.assertEqual(c.busy_state("point_of_no_return", "image-2", facts)["reason"],
                             "UPDATING")
            self.assertEqual(c.busy_state("request", None, facts)["reason"], "UPDATING")
            self.assertFalse(c.busy_state("recovery", None, facts)["busy"])   # never a lock
        finally:
            lock.release()
        self.assertIsNone(c.lock_holder(c.MAINTENANCE_LOCK))

    def test_stop_point_1_print_started_during_the_write(self):
        # S3: a print started from Mainsail while the image was written: stop
        # before the marker write, the written slot blanked, no switch, no
        # reboot, no trial; the check excludes the job's own lock.
        archive, _, _ = self.package()
        calls = fake_busy(self.e.common, ["PRINTING"])
        self.i.run_job("upload/nebula.img", self.i.sha256_file(archive), "image-7")
        st = json.load(open(self.i.JOB_STATE))
        self.assertEqual((st["state"], st["phase"], st["error"]), ("failed", "stopped_print", "PRINTING"))
        self.assertTrue(st["stopped"] and st["target_cleared"])
        self.assertIn("Nothing was changed on the running system", st["message"])
        self.assertEqual(calls, [("point_of_no_return", "image-7")])
        self.assertFalse(os.path.exists(self.calls))                 # no swap, no reboot
        self.assertFalse(os.path.exists(self.i.TRIAL))
        self.assertEqual(open(os.path.join(self.dev, "mmcblk0p5"), "rb").read(64), b"\x00" * 64)
        self.assertFalse(self.i.slot_bootable("A"))
        self.assertNotIn("waiting_for_print", open(self.i.__file__).read())   # G88 phase gone

    def test_stop_point_2_marker_put_back(self):
        # Busy after the marker write: marker back to the running slot (read
        # back by the swap tool), TRIAL deleted, written slot blanked.
        archive, _, _ = self.package()
        fake_busy(self.e.common, [None, "PAUSED"])
        self.i.run_job("upload/nebula.img", self.i.sha256_file(archive), "image-7")
        st = json.load(open(self.i.JOB_STATE))
        self.assertEqual((st["state"], st["phase"], st["error"]), ("failed", "stopped_print", "PAUSED"))
        self.assertEqual(open(self.calls).read().split(), ["swap", "A", "swap", "B"])   # no reboot
        self.assertFalse(os.path.exists(self.i.TRIAL))
        self.assertFalse(self.i.slot_bootable("A"))

    def test_stop_point_2_marker_cannot_be_put_back(self):
        # The swap back fails: keep marker + TRIAL, no reboot, no blanking -
        # the new system starts at the next power-on, protected by the trial.
        archive, kernel, _ = self.package()
        write_exe(os.path.join(self.e.bin, "swap"),
                  'echo "swap $1" >> "%s"\n[ "$1" = B ] && exit 2\nexit 0\n' % self.calls)
        fake_busy(self.e.common, [None, "PRINTING"])
        self.i.run_job("upload/nebula.img", self.i.sha256_file(archive), "image-7")
        st = json.load(open(self.i.JOB_STATE))
        self.assertEqual((st["state"], st["phase"]), ("finished", "next_power_on"))
        self.assertIn("next power-on", st["message"])
        self.assertNotIn("reboot", open(self.calls).read())
        self.assertEqual(json.load(open(self.i.TRIAL))["to"], "A")
        self.assertEqual(open(os.path.join(self.dev, "mmcblk0p5"), "rb").read(len(kernel)), kernel)

    def test_writing_a_slot_drops_its_confirmation(self):
        # v3.3: the record goes as soon as the install writes the slot; a
        # passed trial records the slot's header (name + CRCs + superblock).
        archive, _, _ = self.package()
        open(os.path.join(self.dev, "mmcblk0p5"), "r+b").write(self.kernel()[:64])
        self.assertTrue(self.i.confirm_slot("A"))
        self.assertTrue(self.i.slot_confirmed("A"))
        fake_busy(self.e.common, ["PRINTING"])        # stops after writing
        self.i.run_job("upload/nebula.img", self.i.sha256_file(archive), "image-7")
        self.assertFalse(os.path.exists(os.path.join(self.i.CONFIRMED_DIR, "slot-confirmed-A")))
        fake_busy(self.e.common, [None])
        self.i.run_job("upload/nebula.img", self.i.sha256_file(archive), "image-7")
        self.assertFalse(self.i.slot_confirmed("A"))
        self.cmdline("A")
        self.i._klipper_ready = lambda: True
        self.i._gui_running = lambda: True
        self.assertEqual(self.i.trial()["result"], "CONFIRMED")
        rec = json.load(open(os.path.join(self.i.CONFIRMED_DIR, "slot-confirmed-A")))
        self.assertEqual(rec["kernel_name"], "Linux-6.6.157-rt79")
        self.assertTrue(self.i.slot_confirmed("A"))

    def test_slot_rewritten_outside_image_py_is_unconfirmed(self):
        # S37: flash-spare-slot.sh / the hardware tool / USB recovery rewrote
        # the slot: the header no longer matches the record.
        open(os.path.join(self.dev, "mmcblk0p5"), "r+b").write(self.kernel()[:64])
        self.i.confirm_slot("A")
        self.assertTrue(self.i.slot_confirmed("A"))
        head = bytearray(self.kernel()[:64])
        head[4:8] = b"\x12\x34\x56\x78"                          # another header CRC
        open(os.path.join(self.dev, "mmcblk0p5"), "r+b").write(bytes(head))
        self.assertFalse(self.i.slot_confirmed("A"))
        self.i.confirm_slot("A")
        self.rootfs("mmcblk0p7", {}, mkfs=9)                      # rootfs rewritten alone
        self.assertFalse(self.i.slot_confirmed("A"))
        fake_busy(self.e.common, [None])
        write_exe(os.environ["NEBULAOS_SLOT_SWAP"], 'echo "swap $1" >> "%s"\n' % self.calls)
        self.e.system.SLOT_SWAP = os.environ["NEBULAOS_SLOT_SWAP"]
        out = self.e.system.swap_slot()
        self.assertTrue(out["trial"])
        t = json.load(open(self.i.TRIAL))
        self.assertEqual((t["from"], t["to"], t["reason"]), ("B", "A", "slot_switch"))

    def test_switch_into_unconfirmed_slot_writes_trial(self):
        # S30: a manual switch into a slot that never confirmed itself.
        write_exe(os.environ["NEBULAOS_SLOT_SWAP"], 'echo "swap $1" >> "%s"\n' % self.calls)
        self.e.system.SLOT_SWAP = os.environ["NEBULAOS_SLOT_SWAP"]
        open(os.path.join(self.dev, "mmcblk0p5"), "r+b").write(self.kernel()[:64])
        fake_busy(self.e.common, [None])
        self.assertTrue(self.e.system.swap_slot()["trial"])
        self.assertEqual(json.load(open(self.i.TRIAL))["to"], "A")
        self.e.system.keep_slot()                                 # undone: trial gone
        self.assertFalse(os.path.exists(self.i.TRIAL))
        self.i.confirm_slot("A")                                  # confirmed: no trial
        self.assertFalse(self.e.system.swap_slot()["trial"])
        self.assertFalse(os.path.exists(self.i.TRIAL))
        self.e.system.keep_slot()
        # a Creality slot never runs the check: no trial
        self.i.unconfirm_slot("A")
        open(os.path.join(self.dev, "mmcblk0p5"), "r+b").write(self.kernel("Linux-4.4.94")[:64])
        self.assertFalse(self.e.system.swap_slot()["trial"])

    def test_pending_trial_refuses_install_and_switch(self):
        # S36 / v3.2: while the running slot is on trial (or its verdict
        # waits for a print) an install and a slot switch are refused.
        archive, _, _ = self.package()
        self.cmdline("A")
        open(self.mounts, "w").write("/dev/mmcblk0p7 / squashfs ro 0 0\n")
        open(os.path.join(self.dev, "mmcblk0p6"), "r+b").write(self.kernel()[:64])
        self.trial_file(frm="B", to="A")
        facts = {"klippy": "ready", "status": {}, "update_manager_busy": False}
        real = self.e.common.busy_state
        self.e.common.klippy_facts = lambda timeout=None: facts
        st = real("request")
        self.assertEqual((st["reason"], st["message"]),
                         ("UPDATING", self.e.common.TRIAL_MESSAGE))
        self.assertFalse(real("point_of_no_return")["busy"])     # only the request profile
        t = json.load(open(self.i.TRIAL))
        t["postponed"] = True
        json.dump(t, open(self.i.TRIAL, "w"))
        self.assertEqual(real("request")["message"], self.e.common.TRIAL_POSTPONED_MESSAGE)
        with self.assertRaises(self.e.common.Refused) as cm:
            self.i.install("upload/nebula.img", self.i.sha256_file(archive))
        self.assertEqual(cm.exception.code, "UPDATING")
        with self.assertRaises(self.e.common.Refused):
            self.e.system.swap_slot()
        self.cmdline("B")                      # a trial for the OTHER slot is not pending here
        self.assertFalse(real("request")["busy"])

    def test_creality_image_arms_no_trial(self):
        # Creality's firmware never runs the fallback check: no trial, and a
        # stale one from earlier is removed.
        open(self.i.TRIAL, "w").write("{}")
        archive, kernel, _ = self.package(kernel=self.kernel("Linux-4.4.94"))
        self.assertEqual(self.i.check("upload/nebula.img")["system"], "creality")
        self.i.run_job("upload/nebula.img", self.i.sha256_file(archive))
        st = json.load(open(self.i.JOB_STATE))
        self.assertEqual((st["state"], st["system"]), ("restarting", "creality"))
        self.assertEqual(open(os.path.join(self.dev, "mmcblk0p5"), "rb").read(len(kernel)), kernel)
        self.assertFalse(os.path.exists(self.i.TRIAL))

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
        # The kernel was already written: it is blanked, and swap refuses the slot.
        self.assertTrue(st["target_cleared"])
        self.assertEqual(open(os.path.join(self.dev, "mmcblk0p5"), "rb").read(64), b"\x00" * 64)
        self.assertFalse(self.i.slot_bootable("A"))
        with self.assertRaises(self.e.common.OsConfigError) as cm:
            self.e.system.swap_slot()
        self.assertEqual(cm.exception.code, "SLOT_EMPTY")
        open(os.path.join(self.dev, "mmcblk0p5"), "r+b").write(self.kernel()[:64])
        self.assertTrue(self.i.slot_bootable("A"))

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
        self.assertFalse(json.load(open(self.i.JOB_STATE))["target_cleared"])   # nothing written
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

    def test_trial_confirmed_removes_the_installed_upload(self):
        """G66: the ~130 MB upload goes once its system is confirmed - only
        the exact installed file, only from the upload folder."""
        import hashlib
        self.cmdline("A")
        os.makedirs(self.i.UPLOAD_DIR, exist_ok=True)
        img = os.path.join(self.i.UPLOAD_DIR, "nebula.img")
        open(img, "wb").write(b"IMAGE")
        good = hashlib.sha256(b"IMAGE").hexdigest()
        self.i._klipper_ready = lambda: True
        self.i._gui_running = lambda: True
        json.dump({"from": "B", "to": "A", "file": "upload/nebula.img", "sha256": "0" * 64,
                   "version": "9.9", "system": "nebulaos"}, open(self.i.TRIAL, "w"))
        self.assertFalse(self.i.trial()["removed_upload"])           # a different file now
        self.assertTrue(os.path.exists(img))
        json.dump({"from": "B", "to": "A", "file": "upload/nebula.img", "sha256": good,
                   "version": "9.9", "system": "nebulaos"}, open(self.i.TRIAL, "w"))
        self.assertTrue(self.i.trial()["removed_upload"])
        self.assertFalse(os.path.exists(img))
        json.dump({"from": "B", "to": "A", "file": "usb/sda1/nebula.img", "sha256": good,
                   "version": "9.9", "system": "nebulaos"}, open(self.i.TRIAL, "w"))
        self.assertFalse(self.i.trial()["removed_upload"])           # never the USB stick

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

    def test_trial_verdict_postponed_while_printing(self):
        # S8 + v2.3: Klipper never came up in time, but a print runs (the
        # recovery check says so): no switch, no reboot until it ends; TRIAL
        # stays (marked postponed) meanwhile; then judged again.
        self.cmdline("A")
        self.trial_file()
        self.i.TRIAL_SECONDS, self.i.TRIAL_POLL = 0, 0
        ready = []
        self.i._klipper_ready = lambda: bool(ready)
        self.i._gui_running = lambda: True
        seen = []

        def busy_state(profile, holder=None, facts=None):
            seen.append((profile, os.path.exists(self.i.TRIAL),
                         json.load(open(self.i.TRIAL)).get("postponed")))
            self.assertFalse(os.path.exists(self.calls))          # nothing switched yet
            return self.e.common.busy_result(profile, "PRINTING" if len(seen) < 3 else None)
        self.e.common.busy_state = busy_state
        self.assertEqual(self.i.trial()["result"], "ROLLED_BACK")
        self.assertEqual([x[0] for x in seen], ["recovery"] * 3)
        self.assertTrue(seen[1][1] and seen[1][2])                 # TRIAL kept, postponed
        self.assertEqual(open(self.calls).read().split(), ["swap", "B", "reboot"])

    def test_trial_postponed_then_confirmed(self):
        self.cmdline("A")
        self.trial_file()
        self.i.TRIAL_SECONDS, self.i.TRIAL_POLL = 0, 0
        state = {"n": 0}
        self.i._klipper_ready = lambda: state["n"] >= 2
        self.i._gui_running = lambda: True

        def busy_state(profile, holder=None, facts=None):
            state["n"] += 1
            return self.e.common.busy_result(profile, "PAUSED" if state["n"] < 2 else None)
        self.e.common.busy_state = busy_state
        self.assertEqual(self.i.trial()["result"], "CONFIRMED")
        self.assertFalse(os.path.exists(self.calls))
        self.assertFalse(os.path.exists(self.i.TRIAL))

    def test_trial_counts_a_shed_screen_as_up(self):
        # S7: Klipper ready, the screen stopped by memguard for memory.
        self.cmdline("A")
        self.trial_file()
        self.i._klipper_ready = lambda: True
        self.i._gui_running = lambda: False
        open(self.i.SHED_SCREEN, "w").close()
        self.assertEqual(self.i.trial()["result"], "CONFIRMED")
        self.assertIn("memguard", json.load(open(self.i.LAST))["note"])

    def test_trial_fallback_never_without_busy_check(self):
        # S26: a new image whose Moonraker never starts: Klipper not ready via
        # Moonraker, the recovery check (Klippy socket) says not printing ->
        # fallback once.
        self.cmdline("A")
        self.trial_file()
        self.i.TRIAL_SECONDS, self.i.TRIAL_POLL = 0, 0
        self.i._klipper_ready = lambda: False
        self.i._gui_running = lambda: False
        calls = fake_busy(self.e.common, [None])
        self.assertEqual(self.i.trial()["result"], "ROLLED_BACK")
        self.assertEqual(calls, [("recovery", None)])


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

    def test_every_read_only_verb_reaches_its_own_function(self):
        """Run 9 test on ke-dev: boot-display list-images fell through to the
        domain's status (no "images" - the Boot logo page saw nothing), as
        logs status once fell into a KeyError. Every read-only verb, through
        the CLI the way the screen calls it."""
        cli = self.e.cli
        for domain, verb in sorted(cli.READ_ONLY):
            rc, out = self.run_cli(domain, verb)
            self.assertNotIn(out.get("error"), ("USAGE", "INTERNAL"), (domain, verb, out))
        bd = importlib.import_module("nebulaos_osconfig.bootdisplay")
        os.makedirs(bd.UPLOAD_DIR, exist_ok=True)
        open(os.path.join(bd.UPLOAD_DIR, "logo.png"), "wb").write(b"x")
        rc, out = self.run_cli("boot-display", "list-images")
        self.assertTrue(out["ok"], out)
        self.assertEqual([i["name"] for i in out["images"]], ["logo.png"])
        self.assertIn("usb", out)
        rc, out = self.run_cli("boot-display", "preview", "--file", "logo.png")
        self.assertNotEqual(out.get("error"), "USAGE", out)

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
        json.dump({"firmware_head": "f" * 40, "build_date": "x", "nebulaos_version": "0.9.0",
                   "seeds": {"klipper": {"seed_commit": "k"}}},
                  open(os.environ["NEBULAOS_SEED_MANIFEST"], "w"))
        open(os.environ["NEBULAOS_DATA_FS_STATE"], "w").write(
            "DATAFS_RESULT=CLEAN\nDATAFS_MOUNT=rw\nDATAFS_STATE_BEFORE='clean'\n")
        rc, out = self.run_cli("system", "info")
        self.assertEqual(rc, 0)
        self.assertEqual(out["build"]["klipper"], "k")
        self.assertEqual(out["build"]["nebulaos_version"], "0.9.0")
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
              "system busy")
                # G91: the busy check (file: the reason, absent = not busy)
                r=$(cat "%(log)s.busy" 2>/dev/null)
                if [ -n "$r" ]; then
                  printf '{"ok": true, "busy": true, "reason": "%%s", "message": "text for %%s", "profile": "%%s"}\n' "$r" "$r" "$4"
                else
                  printf '{"ok": true, "busy": false, "reason": null, "message": "", "profile": "%%s"}\n' "$4"
                fi
                exit 0 ;;
              "image install"|"system swap-slot")
                # verbs that refuse themselves: exit 3
                r=$(cat "%(log)s.busy" 2>/dev/null)
                [ -n "$r" ] && { printf '{"ok": false, "error": "%%s", "message": "text for %%s", "refused": true}\n' "$r" "$r"; exit 3; } ;;
              "display set-brightness") echo '{"ok": false, "error": "INVALID_BRIGHTNESS", "message": "m"}'; exit 1 ;;
              "network set-ipv4") echo '{"ok": false, "error": "GATEWAY_UNREACHABLE_REVERTED", "message": "m"}'; exit 2 ;;
            esac
            echo '{"ok": true, "result": "APPLIED"}'
        """ % {"log": self.log})
        self.upload_dir = os.path.join(self.tmp, "uploads")          # G62: the "uploads" root
        self.screen_report = os.path.join(self.tmp, "run", "nebulascreen-report.json")
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
                self.endpoints, self.events, self.warnings = {}, [], {}

            def register_endpoint(self, path, rtype, cb):
                self.endpoints[path] = (rtype, cb)

            def register_notification(self, name):
                pass

            def send_event(self, name, data):
                self.events.append((name, data))

            def add_warning(self, msg, warn_id=None, log=True):
                self.warnings[warn_id] = msg

            def remove_warning(self, warn_id):
                self.warnings.pop(warn_id, None)

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
                        "uploads_dir": test.upload_dir,
                        "screen_report": test.screen_report}.get(key, default)

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

        def get_boolean(self, key, default=None):
            return bool(self.args.get(key, default))

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

    # G82 stage 3: the screen's version report, read by the update supervisor.
    def test_screen_report_recorded(self):
        self.assertEqual(self.server.endpoints["/machine/nebulaos/screen/report"][0], 2)
        res = self.call("/machine/nebulaos/screen/report",
                        {"name": "nebulascreen", "version": "v0.9.1", "nebulaos_ui_api": 1})
        self.assertEqual(res, {"result": "RECORDED"})
        with open(self.screen_report) as fh:
            text = fh.read()
        rep = json.loads(text)
        self.assertEqual((rep["name"], rep["version"], rep["nebulaos_ui_api"]),
                         ("nebulascreen", "v0.9.1", 1))
        self.assertIsInstance(rep["reported_at"], int)
        # one key per line: the supervisor reads it with sed
        self.assertIn('\n  "version": "v0.9.1"\n', text)
        self.assertFalse(os.path.exists(self.screen_report + ".tmp"))
        self.assertEqual(self.calls(), [])          # no helper involved

    def test_screen_report_rejects_malformed(self):
        for args in ({"name": "guppyscreen", "version": "v0.9.1", "nebulaos_ui_api": 1},
                     {"name": "nebulascreen", "version": "v0.9.1\"; x", "nebulaos_ui_api": 1},
                     {"name": "nebulascreen", "version": "", "nebulaos_ui_api": 1},
                     {"name": "nebulascreen", "version": "v" * 80, "nebulaos_ui_api": 1}):
            with self.assertRaises(Exception) as cm:
                self.call("/machine/nebulaos/screen/report", args)
            self.assertEqual(cm.exception.status_code, 400)
        self.assertFalse(os.path.exists(self.screen_report))

    def test_screen_report_replaces_previous(self):
        for v in ("v0.9.0", "v0.9.1"):
            self.call("/machine/nebulaos/screen/report",
                      {"name": "nebulascreen", "version": v, "nebulaos_ui_api": 1})
        with open(self.screen_report) as fh:
            self.assertEqual(json.load(fh)["version"], "v0.9.1")

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
        self.assertIn("NEBULAOS_BOOT_UPLOAD_DIR=" + os.path.join(self.upload_dir, "boot-logo"), self.argv())
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

    def test_no_upload_root_registered(self):
        # G63: uploads live inside the config root (Mainsail only uploads into
        # config); a root of their own would overlap it.
        self.assertFalse(hasattr(self, "registered"))
        for sub in ("boot-logo", "mainboard-firmware", "system-image"):
            self.assertTrue(os.path.isdir(os.path.join(self.upload_dir, sub)))
        self.call("/machine/nebulaos/boot_display/image", {"filename": "logo.png"})
        self.assertEqual(self.argv()[:4], ["boot-display", "set-image", "--file", "logo.png"])

    def test_hidden_and_cleanup_arguments(self):
        self.call("/machine/nebulaos/wifi/connect", {"ssid": "Attic", "password": "x" * 8, "hidden": True})
        self.call("/machine/nebulaos/cleanup/plan", {"videos": True})
        self.assertEqual(self.argv()[:3], ["system", "cleanup-plan", "--videos"])
        self.call("/machine/nebulaos/cleanup/plan", {})
        self.assertEqual(self.argv()[:2], ["system", "cleanup-plan"])
        self.assertNotIn("--videos", self.argv())

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
        # clean reset: the shared busy check first; swap-slot checks itself
        self.assertEqual(self.calls(), ["system busy", "system clean-reset", "system swap-slot"])

    def set_busy(self, reason):
        if reason:
            open(self.log + ".busy", "w").write(reason)
        elif os.path.exists(self.log + ".busy"):
            os.unlink(self.log + ".busy")

    def test_refused_while_printing(self):
        # G91: every refusal comes from the shared check (async helper call,
        # or the verb's own exit 3): HTTP 409 with the reason, and a
        # "!! NebulaOS refused:" line for Mainsail's console/toast.
        for reason in ("PRINTING", "PAUSED", "ACTIVE", "UPDATING"):
            self.set_busy(reason)
            for p in ("system/clean_reset", "system/swap_slot", "image/install",
                      "boot_display/image", "cleanup/creality"):
                self.server.events.clear()
                with self.assertRaises(Exception) as cm:
                    self.call("/machine/nebulaos/" + p, {"file": "upload/x.img", "sha256": "0" * 64,
                                                         "filename": "a.png"})
                self.assertEqual(cm.exception.status_code, 409, p)
                self.assertTrue(str(cm.exception).startswith(reason + ":"), str(cm.exception))
                self.assertEqual(self.server.events,
                                 [("server:gcode_response", "!! NebulaOS refused: text for " + reason)])
        self.assertEqual(self.reboots, 0)
        self.assertEqual(sorted(set(self.calls())), ["image install", "system busy", "system swap-slot"])
        self.set_busy(None)              # e.g. Klipper down: not busy, allowed
        self.call("/machine/nebulaos/system/swap_slot")
        self.assertEqual(self.reboots, 1)

    def test_g98_busy_endpoint(self):
        # G98: the screen asks before its own Restart Klipper / Restart MCU
        self.assertEqual(self.server.endpoints["/machine/nebulaos/system/busy"][0], 1)
        self.set_busy("PRINTING")
        res = self.call("/machine/nebulaos/system/busy", {"profile": "restart"})
        self.assertEqual((res["busy"], res["reason"], res["message"], res["profile"]),
                         (True, "PRINTING", "text for PRINTING", "restart"))
        self.assertIn("klippy", res)
        self.assertEqual(self.argv()[:4], ["system", "busy", "--profile", "restart"])
        self.assertEqual(self.server.events, [])          # a question, not a refusal
        self.set_busy(None)
        res = self.call("/machine/nebulaos/system/busy", {"profile": "request"})
        self.assertEqual((res["busy"], res["reason"]), (False, None))
        with self.assertRaises(Exception) as cm:
            self.call("/machine/nebulaos/system/busy", {"profile": "git"})
        self.assertEqual(cm.exception.status_code, 400)
        # the check itself fails: restart = allowed (G95), request = fail closed
        real_exec = self.comp._exec

        async def broken(args, timeout, stdin=None):
            raise self.server.error("nebulaos-osconfig system busy timed out", 504)
        self.comp._exec = broken
        self.assertFalse(self.call("/machine/nebulaos/system/busy",
                                   {"profile": "restart"})["busy"])
        res = self.call("/machine/nebulaos/system/busy", {"profile": "request"})
        self.assertEqual((res["busy"], res["reason"]), (True, "UNKNOWN"))
        self.comp._exec = real_exec
        import inspect
        self.assertTrue(inspect.iscoroutinefunction(self.comp._system_busy))

    def test_g98_notify_refused_console_line(self):
        res = self.call("/machine/nebulaos/system/notify_refused",
                        {"message": "restart klipper - Not possible while a print is running."})
        self.assertEqual(res, {"result": "SENT"})
        self.assertEqual(self.server.events, [(
            "server:gcode_response",
            "!! NebulaOS refused: restart klipper - Not possible while a print is running.")])
        self.server.events.clear()
        self.call("/machine/nebulaos/system/notify_refused",
                  {"message": "NebulaOS refused: x\n!! y\x1b" + "z" * 300})
        line = self.server.events[0][1]
        self.assertTrue(line.startswith("!! NebulaOS refused: x !! y"), line)
        self.assertNotIn("\n", line)
        self.assertLessEqual(len(line), len(self.mod.REFUSAL_PREFIX) + self.mod.NOTIFY_MAX)
        with self.assertRaises(Exception) as cm:
            self.call("/machine/nebulaos/system/notify_refused", {"message": " \n "})
        self.assertEqual(cm.exception.status_code, 400)
        self.assertEqual(self.calls(), [])                # no helper involved

    def test_busy_check_is_async_and_request_profile(self):
        # review 10: never block Moonraker's event loop - the check is the
        # helper run through asyncio's subprocess API.
        import inspect
        self.assertTrue(inspect.iscoroutinefunction(self.comp._refuse_if_busy))
        src = inspect.getsource(self.mod.NebulaOS._refuse_if_busy)
        self.assertIn('"system", "busy", "--profile", profile', src)
        self.assertNotIn("subprocess.run", open(COMPONENT).read())
        self.call("/machine/nebulaos/boot_display/reset_image")
        self.assertEqual(self.calls()[0], "system busy")
        self.assertEqual(inspect.signature(self.comp._refuse_if_busy).parameters["profile"].default,
                         "request")

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
        for reason in ("PRINTING", "PAUSED"):
            self.set_busy(reason)
            with self.assertRaises(Exception) as cm:
                self.call("/machine/nebulaos/mcu/flash", {"file": "upload/a.bin", "sha256": "0" * 64})
            self.assertEqual(cm.exception.status_code, 409)
        self.assertEqual(set(self.calls()), {"system busy"})
        self.set_busy(None)
        os.unlink(self.log + ".all")

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


class UpdateReadinessTests(unittest.TestCase):
    """G73: is a pending Klipper/Moonraker update installable? Moonraker,
    pip and the index are faked; git and the chelper library are real."""

    def setUp(self):
        self.e = Env()
        self.u = importlib.import_module("nebulaos_osconfig.updates")
        root = self.e.root
        self.git_env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@l",
                            GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@l")
        self.mr = os.path.join(root, "apps", "moonraker")
        self.kl = os.path.join(root, "apps", "klipper")
        self.mr_cur, self.mr_new = self.make_repo(self.mr, "scripts/moonraker-requirements.txt",
                                                  {}, {})
        self.kl_cur, self.kl_new = self.make_repo(
            self.kl, "scripts/klippy-requirements.txt",
            {"klippy/chelper/__init__.py": "init", "klippy/chelper/a.c": "one"},
            {"klippy/chelper/a.c": "two"})
        # The venvs' python: records argv and env, answers per mode file.
        self.pylog = os.path.join(self.e.tmp, "pip.log")
        self.pymode = os.path.join(self.e.tmp, "pip.mode")
        for env in ("moonraker", "klipper"):
            d = os.path.join(root, "envs", env, "bin")
            os.makedirs(d)
            write_exe(os.path.join(d, "python"), """
                echo "%(env)s TMPDIR=$TMPDIR $*" >> "%(log)s"
                [ "$(cat "%(mode)s" 2>/dev/null)" = missing ] || exit 0
                echo "ERROR: Could not find a version that satisfies the requirement foo" >&2
                echo "ERROR: No matching distribution found for foo" >&2
                exit 1
            """ % {"env": env, "log": self.pylog, "mode": self.pymode})
        pipconf = os.path.join(self.e.tmp, "pip.conf")
        with open(pipconf, "w") as handle:
            handle.write("[global]\nindex-url = https://idx.invalid/simple/abc/\nonly-binary = :all:\n")
        self.u.PIP_CONF = pipconf
        # c_helper.so: the real library, a file:// index.
        self.site = os.path.join(self.e.tmp, "site")
        os.makedirs(os.path.join(self.site, "abc"))
        with open(os.path.join(self.e.tmp, "abi"), "w") as handle:
            handle.write("id=abc\n")
        with open(os.path.join(self.e.tmp, "chelper.url"), "w") as handle:
            handle.write("file://%s\n" % self.site)
        os.environ.update({"NEBULAOS_PYTHON_ABI_FILE": os.path.join(self.e.tmp, "abi")})
        self.u.CHELPER_LIB = os.path.join(OVERLAY, "etc", "nebulaos-chelper-preflight.sh")
        self.u.CHELPER_URL_FILE = os.path.join(self.e.tmp, "chelper.url")
        self.busy, self.state = False, "standby"
        self.remote = {"moonraker": self.mr_new, "klipper": None}

        def fake_get(path, timeout=10):
            if path.startswith("/printer/objects/query"):
                return {"status": {"print_stats": {"state": self.state}}}
            info = {}
            for name, cur in (("moonraker", self.mr_cur), ("klipper", self.kl_cur)):
                info[name] = {"current_hash": cur, "remote_hash": self.remote[name] or cur}
            return {"busy": self.busy, "version_info": info}
        self.u._get = fake_get

    def tearDown(self):
        os.environ.pop("NEBULAOS_PYTHON_ABI_FILE", None)
        self.e.cleanup()

    def git(self, repo, *args):
        import subprocess
        return subprocess.run(["git", "-C", repo] + list(args), check=True, env=self.git_env,
                              capture_output=True, text=True).stdout.strip()

    def make_repo(self, repo, req, files, changes):
        os.makedirs(repo)
        self.git(repo, "init", "-q")
        for path, text in dict(files, **{req: "foo>=1\n--find-links=python_wheels\n"}).items():
            os.makedirs(os.path.dirname(os.path.join(repo, path)), exist_ok=True)
            with open(os.path.join(repo, path), "w") as handle:
                handle.write(text)
        self.git(repo, "add", "-A")
        self.git(repo, "commit", "-qm", "current")
        cur = self.git(repo, "rev-parse", "HEAD")
        for path, text in dict(changes, **{req: "foo>=2\n"}).items():
            with open(os.path.join(repo, path), "w") as handle:
                handle.write(text)
        self.git(repo, "commit", "-qam", "new")
        new = self.git(repo, "rev-parse", "HEAD")
        self.git(repo, "reset", "-q", "--hard", cur)
        return cur, new

    def pip_calls(self):
        try:
            return open(self.pylog).read().splitlines()
        except OSError:
            return []

    def test_busy_or_printing_runs_nothing(self):
        self.busy = True
        self.assertEqual(self.u.check()["result"], "BUSY")
        self.busy, self.state = False, "printing"
        self.assertEqual(self.u.check()["result"], "PRINTING")
        self.assertEqual(self.pip_calls(), [])
        self.assertFalse(os.path.exists(self.u.STATE))

    def test_ready_dry_run_as_moonraker_runs_it(self):
        out = self.u.check()
        self.assertEqual(out["result"], "READY", out)
        self.assertEqual(out["apps"]["moonraker"]["target"], self.mr_new)
        call, = self.pip_calls()
        self.assertTrue(call.startswith("moonraker TMPDIR=%s/tmp/readiness-" % self.e.root), call)
        for arg in ("-m pip install --dry-run", "--only-binary=:all:",
                    "--index-url https://idx.invalid/simple/abc/", "-U -r"):
            self.assertIn(arg, call)
        self.assertEqual(self.u.readiness()["result"], "READY")
        # Moonraker owns fetching: nothing written to the app repository.
        self.assertEqual(self.git(self.mr, "rev-parse", "HEAD"), self.mr_cur)
        self.assertFalse(os.path.exists(os.path.join(self.mr, ".git", "FETCH_HEAD")))
        self.assertEqual(self.git(self.mr, "status", "--porcelain"), "")
        self.assertEqual(os.listdir(os.path.join(self.e.root, "tmp")), [])

    def test_missing_packages_not_ready(self):
        with open(self.pymode, "w") as handle:
            handle.write("missing")
        out = self.u.check()
        self.assertEqual(out["result"], "NOT_READY", out)
        self.assertEqual(out["apps"]["moonraker"]["packages"], "missing")
        self.assertIn("Moonraker update", out["message"])
        # Not a clear yes: --if-changed checks again (the index may have caught up).
        os.unlink(self.pymode)
        self.assertEqual(self.u.check(if_changed=True)["result"], "READY")

    def test_if_changed_skips_same_targets(self):
        self.u.check()
        self.assertEqual(self.u.check(if_changed=True)["result"], "UNCHANGED")
        self.assertEqual(len(self.pip_calls()), 1)
        # A result older than RECHECK_SECONDS is checked again.
        state = json.load(open(self.u.STATE))
        state["checked_epoch"] -= self.u.RECHECK_SECONDS + 1
        self.e.common.atomic_write_json(self.u.STATE, state)
        self.assertEqual(self.u.check(if_changed=True)["result"], "READY")
        self.assertEqual(len(self.pip_calls()), 2)
        self.remote["moonraker"] = None
        self.assertEqual(self.u.check(if_changed=True)["result"], "NO_UPDATES")

    def test_klipper_helper(self):
        self.remote = {"moonraker": None, "klipper": self.kl_new}
        out = self.u.check()
        self.assertEqual(out["result"], "UNKNOWN", out)      # no index file yet
        self.assertEqual(out["apps"]["klipper"]["helper"], "unknown")
        with open(os.path.join(self.site, "abc", "index"), "w") as handle:
            handle.write("0000 1111 5\n")
        out = self.u.check()
        self.assertEqual((out["result"], out["apps"]["klipper"]["helper"]), ("NOT_READY", "missing"), out)
        self.assertIn("Klipper update", out["message"])
        want = out["apps"]["klipper"]["helper_source_hash"]
        with open(os.path.join(self.site, "abc", "index"), "a") as handle:
            handle.write("%s 2222 5\n" % want)
        out = self.u.check()
        self.assertEqual((out["result"], out["apps"]["klipper"]["helper"]), ("READY", "available"), out)
        self.assertEqual(self.git(self.kl, "rev-parse", "HEAD"), self.kl_cur)

    def test_component_warning(self):
        comp_tests = ComponentTests("test_ok_result_strips_ok")
        comp_tests.setUp()
        try:
            comp = comp_tests.comp
            comp._sync_readiness_warning({"result": "NOT_READY", "message": "m"})
            self.assertEqual(comp_tests.server.warnings, {"nebulaos_update_readiness": "NebulaOS: m"})
            comp._sync_readiness_warning({"result": "BUSY"})
            self.assertIn("nebulaos_update_readiness", comp_tests.server.warnings)
            comp._sync_readiness_warning({"result": "READY"})
            self.assertEqual(comp_tests.server.warnings, {})
            out = comp_tests.call("/machine/nebulaos/updates/check_readiness", {"if_changed": True})
            self.assertEqual(out, {"result": "APPLIED"})
            self.assertEqual(comp_tests.argv()[:3], ["updates", "check-readiness", "--if-changed"])
        finally:
            comp_tests.tearDown()


if __name__ == "__main__":
    unittest.main()
