#!/usr/bin/env python3
"""M1 (2026-10-05): the MCU guard's application-identify budget is 15 s.

- default and MCU_APP_IDENTIFY_TIMEOUT override (invalid values fall back)
- get_application_identity() passes the budget to run_connected(); an explicit
  timeout still wins; mcu_restart's run_connected() default is untouched
- mcu_lifecycle.decide() calls identify_fn(port, baud) with no timeout, so the
  real guard path gets the 15 s budget; a timeout still leads to the
  unchanged bootloader-level fallback and a mismatch still fails closed
- real Klipper reactor + SerialReader (only connect_uart's wire side faked):
  a connect that completes after 7 s (a slow first session, as seen live at
  8.86 s) succeeds with the default budget and fails with the old 5 s, and
  the failure stays bounded; disconnect runs on every path

Run: python3 tests/mcu-identify-budget-tests.py
"""

import os
import sys
import time
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
HELPER_DIR = os.path.join(ROOT, "scripts", "build", "overlay", "etc", "nebulaos")
KLIPPY_DIR = os.path.join(ROOT, "vendor", "klipper", "klippy")
sys.path.insert(0, HELPER_DIR)

import mcu_application_identify as app  # noqa: E402
import mcu_known_identities as known  # noqa: E402
import mcu_lifecycle as lifecycle  # noqa: E402

# A path nobody holds open (run_connected refuses a port another process has
# open, and /dev/null is open in most test environments).
FAKE_PORT = "/nonexistent/nebulaos-test-mcu-port"


class BudgetValueTests(unittest.TestCase):
    def test_default_is_15(self):
        self.assertEqual(app.DEFAULT_APP_IDENTIFY_TIMEOUT, 15.0)
        self.assertEqual(app.app_identify_timeout({}), 15.0)

    def test_override(self):
        self.assertEqual(app.app_identify_timeout({"MCU_APP_IDENTIFY_TIMEOUT": "20"}), 20.0)
        self.assertEqual(app.app_identify_timeout({"MCU_APP_IDENTIFY_TIMEOUT": "2.5"}), 2.5)

    def test_invalid_override_falls_back(self):
        for bad in ("", "abc", "0", "-3", "1000", "nan"):
            self.assertEqual(app.app_identify_timeout({"MCU_APP_IDENTIFY_TIMEOUT": bad}), 15.0, bad)

    def test_run_connected_default_unchanged(self):
        import inspect
        self.assertEqual(inspect.signature(app.run_connected).parameters["timeout"].default, 5.0)


class PassThroughTests(unittest.TestCase):
    def setUp(self):
        self.seen = []
        self.orig = app.run_connected

        def fake_run_connected(port, baud, action_fn, timeout=5.0, klippy_lib_path=None, error_cls=None):
            self.seen.append(timeout)

            class MP:
                def get_version_info(self_inner):
                    return known.NATIVE_CANDIDATE_001_VERSION, {}

            class SR:
                def get_msgparser(self_inner):
                    return MP()
            return action_fn(SR())
        app.run_connected = fake_run_connected

    def tearDown(self):
        app.run_connected = self.orig
        os.environ.pop("MCU_APP_IDENTIFY_TIMEOUT", None)

    def test_default_reaches_run_connected(self):
        app.get_application_identity(FAKE_PORT, 230400)
        self.assertEqual(self.seen, [15.0])

    def test_explicit_timeout_wins(self):
        app.get_application_identity(FAKE_PORT, 230400, timeout=3.0)
        self.assertEqual(self.seen, [3.0])

    def test_env_reaches_run_connected(self):
        os.environ["MCU_APP_IDENTIFY_TIMEOUT"] = "9"
        app.get_application_identity(FAKE_PORT, 230400)
        self.assertEqual(self.seen, [9.0])

    def test_decide_uses_the_budget(self):
        d = lifecycle.decide(port=FAKE_PORT, baud=230400)
        self.assertEqual(self.seen, [15.0])
        self.assertEqual(d.application_class, known.NATIVE_CANDIDATE_001)


def _decision_fakes():
    """The fakes of tests/mcu-lifecycle-decision-tests.py (one source of truth)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "lifecycle_decision_tests", os.path.join(ROOT, "tests", "mcu-lifecycle-decision-tests.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class DecisionUnchangedTests(unittest.TestCase):
    """The failure branches of decide() are the same as before M1."""

    def setUp(self):
        self.f = _decision_fakes()

    def _timeout(self, port, baud):
        raise app.ApplicationIdentifyError("identify_handshake_timeout")

    def test_timeout_falls_back_to_bootloader_identity(self):
        cf = self.f.FakeCrealityFlash()
        d = lifecycle.decide(creality_flash_module=cf, transport_factory=self.f.transport_factory_stub,
                             application_identify_fn=self._timeout)
        self.assertEqual(d.state, lifecycle.SUPPORTED_HW_UNKNOWN_APP)
        self.assertEqual(d.action, lifecycle.ALLOW_KLIPPER_START_WARN)
        self.assertEqual(d.hw_id_status, "MATCH")
        self.assertIn("identify_handshake_timeout", d.detail)
        self.assertEqual(cf.flash_calls, [])

    def test_timeout_with_wrong_hardware_still_blocks(self):
        cf = self.f.FakeCrealityFlash(hw_id=self.f.BAD_HW_ID)
        d = lifecycle.decide(creality_flash_module=cf, transport_factory=self.f.transport_factory_stub,
                             application_identify_fn=self._timeout)
        self.assertEqual(d.state, lifecycle.UNSUPPORTED_HW)
        self.assertEqual(d.action, lifecycle.BLOCK_KLIPPER_START)

    def test_timeout_and_no_bootloader_warns(self):
        cf = self.f.FakeCrealityFlash(bootloader_reachable=False)
        d = lifecycle.decide(creality_flash_module=cf, transport_factory=self.f.transport_factory_stub,
                             application_identify_fn=self._timeout)
        self.assertEqual(d.state, lifecycle.MCU_UNREACHABLE)
        self.assertEqual(d.action, lifecycle.ALLOW_KLIPPER_START_WARN)


@unittest.skipUnless(os.path.isfile(os.path.join(KLIPPY_DIR, "reactor.py")), "vendor/klipper not fetched")
class RealReactorLateSessionTests(unittest.TestCase):
    """Real reactor.py/serialhdl.py; only connect_uart's wire exchange is
    replaced by a reactor pause of CONNECT_S (a slow first identify session
    plus a successful second one)."""
    CONNECT_S = 7.0

    def setUp(self):
        sys.path.insert(0, KLIPPY_DIR)
        import serialhdl
        self.serialhdl = serialhdl
        self.orig = (serialhdl.SerialReader.connect_uart, serialhdl.SerialReader.get_msgparser,
                     serialhdl.SerialReader.disconnect)
        self.disconnects = 0
        test = self

        def connect_uart(self_sr, port, baud, rts=True):
            self_sr.reactor.pause(self_sr.reactor.monotonic() + test.CONNECT_S)

        class MP:
            def get_version_info(self_inner):
                return known.NATIVE_CANDIDATE_001_VERSION, {}

        def disconnect(self_sr):
            test.disconnects += 1
        serialhdl.SerialReader.connect_uart = connect_uart
        serialhdl.SerialReader.get_msgparser = lambda self_sr: MP()
        serialhdl.SerialReader.disconnect = disconnect

    def tearDown(self):
        (self.serialhdl.SerialReader.connect_uart, self.serialhdl.SerialReader.get_msgparser,
         self.serialhdl.SerialReader.disconnect) = self.orig

    def test_late_session_succeeds_with_default_budget(self):
        t = time.monotonic()
        version, _ = app.get_application_identity(FAKE_PORT, 230400, klippy_lib_path=KLIPPY_DIR)
        self.assertEqual(version, known.NATIVE_CANDIDATE_001_VERSION)
        self.assertLess(time.monotonic() - t, 12)
        self.assertEqual(self.disconnects, 1)

    def test_late_session_fails_with_old_budget_and_is_bounded(self):
        t = time.monotonic()
        with self.assertRaises(app.ApplicationIdentifyError) as cm:
            app.get_application_identity(FAKE_PORT, 230400, timeout=5.0, klippy_lib_path=KLIPPY_DIR)
        self.assertIn("identify_handshake_timeout", str(cm.exception))
        self.assertLess(time.monotonic() - t, 10)
        self.assertEqual(self.disconnects, 1)


if __name__ == "__main__":
    unittest.main()
