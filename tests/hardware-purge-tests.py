#!/usr/bin/env python3
"""purge-dev-leftovers (2026-10-15): the fixed list and its shell, run against
a scratch tree standing in for /usr/data - never a printer.

Run: python3 tests/hardware-purge-tests.py
"""
import os, shutil, subprocess, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools", "hardware"))
import nebulaos_device as device  # noqa: E402

KEEP = ("/usr/data/creality", "/usr/data/printer_data", "/usr/data/helper-script", "/usr/data/opt",
        "/usr/data/moonraker", "/usr/data/mainsail", "/usr/data/guppyscreen", "/usr/data/swap",
        "/usr/data/wpa_supplicant.conf", "/usr/data/nebulaos-hwagent", "/usr/data/nebulaos/apps/klipper",
        "/usr/data/nebulaos/apps/moonraker", "/usr/data/nebulaos/apps/mainsail", "/usr/data/nebulaos/envs",
        "/usr/data/nebulaos/system", "/usr/data/nebulaos/printer_data/config/printer.cfg")


class PurgeTests(unittest.TestCase):
    def test_list_never_names_a_kept_path(self):
        for p in device.DEV_LEFTOVERS:
            self.assertTrue(p.startswith("/usr/data/"), p)
            for k in KEEP:
                self.assertFalse(k == p or k.startswith(p + "/") or p == "/usr/data", (p, k))
        self.assertEqual(len(set(device.DEV_LEFTOVERS)), len(device.DEV_LEFTOVERS))

    def test_script_removes_exactly_the_list(self):
        root = tempfile.mkdtemp(prefix="purge.")
        try:
            data = os.path.join(root, "usr", "data")
            for p in device.DEV_LEFTOVERS[:-3] + KEEP:
                full = data + p[len("/usr/data"):]
                os.makedirs(os.path.dirname(full), exist_ok=True)
                if p.endswith((".tar", ".log", ".cfg", ".png", ".conf")) or "printer.cfg." in p:
                    open(full, "w").write("x")
                else:
                    os.makedirs(full, exist_ok=True)
                    open(os.path.join(full, "f"), "w").write("x")
            # one listed path is a link that points OUTSIDE the data tree
            outside = os.path.join(root, "outside")
            os.makedirs(outside)
            link = data + device.DEV_LEFTOVERS[-3][len("/usr/data"):]
            os.symlink(outside, link)
            script = device.purge_script(device.DEV_LEFTOVERS).replace("/usr/data", data)
            out = subprocess.run(["sh", "-c", script], capture_output=True, text=True).stdout
            for p in device.DEV_LEFTOVERS[:-3]:
                self.assertFalse(os.path.exists(data + p[len("/usr/data"):]), p)
                self.assertIn("REMOVED", [l for l in out.splitlines() if l.endswith(p.split("/")[-1])][0])
            for k in KEEP:
                self.assertTrue(os.path.exists(data + k[len("/usr/data"):]), k)
            self.assertTrue(os.path.isdir(outside))
            self.assertIn("SKIPPED_OUTSIDE", out)
            self.assertIn("ABSENT", out)
            self.assertIn("DF_BEFORE_KB=", out)
            self.assertIn("DF_AFTER_KB=", out)
        finally:
            shutil.rmtree(root, ignore_errors=True)

    def test_script_fits_the_ssh_command_limit(self):
        # dropbear MAX_CMD_LEN is 9000; the first version was ~15 KB and was cut off
        self.assertLess(len(device.purge_script(device.DEV_LEFTOVERS)), 8000)

    def test_launcher_and_agent_agree(self):
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        launcher = open(os.path.join(here, "tools", "workspace-control", "scripts", "run-nebulaos-hardware.sh")).read()
        agent = open(os.path.join(here, "tools", "hardware", "nebulaos_agent.py")).read()
        self.assertIn('"PURGE_CONFIRM=DEV-LEFTOVERS"', launcher)
        self.assertIn('PURGE_CONFIRM_WORD = "PURGE_CONFIRM=DEV-LEFTOVERS"', agent)


if __name__ == "__main__":
    unittest.main()
