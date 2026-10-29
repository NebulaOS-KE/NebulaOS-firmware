#!/usr/bin/env python3
"""G54/G44 (2026-10-15): the Hardware Agent waits for the end of the boot
(rcS "EV=done") before it verifies. Fake clock and sessions - no printer.

Run: python3 tests/hardware-boot-wait-tests.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "tools", "hardware"))
import nebulaos_device as device  # noqa: E402


class Clock:
    def __init__(self):
        self.t = 0.0

    def now(self):
        return self.t

    def sleep(self, s):
        self.t += s


class Session:
    def __init__(self, seq):
        self.seq, self.calls = list(seq), 0

    def boot_progress(self):
        self.calls += 1
        item = self.seq.pop(0) if len(self.seq) > 1 else self.seq[0]
        if isinstance(item, Exception):
            raise item
        return item


class BootWaitTests(unittest.TestCase):
    def run_wait(self, seq, timeout=device.BOOT_DONE_TIMEOUT):
        c, lines = Clock(), []
        s = Session(seq)
        r = device.wait_for_boot_done(s, lines.append, c.sleep, c.now, timeout=timeout)
        return r, lines, c.t, s.calls

    def test_waits_until_done(self):
        r, lines, t, calls = self.run_wait([("running", 22.0), ("running", 27.0),
                                            device.DeviceError("cut"), ("done", 38.0)])
        self.assertEqual(r, "done")
        self.assertEqual(calls, 4)
        self.assertEqual(t, 15)
        self.assertEqual(lines, ["BOOT_FINISHED=YES uptime=38"])

    def test_already_done_returns_at_once(self):
        r, lines, t, _ = self.run_wait([("done", 500.0)])
        self.assertEqual((r, t), ("done", 0))

    def test_no_log_settles_on_uptime(self):
        r, lines, _, _ = self.run_wait([("nolog", 60.0), ("nolog", 125.0)])
        self.assertEqual(r, "settled")
        self.assertIn("BOOT_FINISHED=ASSUMED", lines[0])

    def test_timeout_reports_and_goes_on(self):
        r, lines, t, _ = self.run_wait([("running", 30.0)], timeout=20)
        self.assertEqual(r, "timeout")
        self.assertTrue(lines[0].startswith("BOOT_FINISHED=TIMEOUT"))
        self.assertGreaterEqual(t, 20)

    def test_default_session_is_done(self):
        class S(device.DeviceSession):
            pass
        self.assertEqual(device.DeviceSession.boot_progress(object()), ("done", None))

    def test_callers_wait(self):
        here = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools", "hardware")
        install = open(os.path.join(here, "nebulaos_install.py")).read()
        agent = open(os.path.join(here, "nebulaos_agent.py")).read()
        i = install.index('self._advance(journal.NEBULAOS_RUNNING, "rediscovered as NebulaOS")')
        self.assertLess(i, install.index("device.wait_for_boot_done", i))
        self.assertLess(install.index("device.wait_for_boot_done", i), install.index("verify.part1_verify", i))
        self.assertEqual(agent.count("device.wait_for_boot_done("), 2)

    def test_verify_proves_the_address_before_waiting(self):
        # Run 22: a stale enrolled address must not cost the 300 s boot wait,
        # and the slot-state retry (time.sleep) needs time at module level.
        here = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools", "hardware")
        agent = open(os.path.join(here, "nebulaos_agent.py")).read()
        self.assertIn("\nimport time\n", agent)
        i = agent.index("def op_verify(")
        self.assertLess(agent.index("session.probe_identity()", i),
                        agent.index("device.wait_for_boot_done(", i))


if __name__ == "__main__":
    unittest.main()
