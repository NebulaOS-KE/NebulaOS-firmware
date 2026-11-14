#!/usr/bin/env python3
"""The factory-fallback Klipper tree passes the extensions' own startup check.

Issue #15 (2026-11-13/14): the immutable /opt/klipper copy - what the update
supervisor falls back to when an update and its rollback both fail - must be
a tree Klippy actually starts on. nebulaos_compat refuses to start unless
every manifest module is present AND (when the manifest asks for it) every
module is a symlink into an extensions checkout. The fallback copy holds real
files, so 04-cross-compile-app-stack.sh switches that composition check off in
the copy's manifest. Before this test, the fallback halted first on a missing
extras/motor_database.cfg and then, once that was copied, on the symlink check.

This test runs 04's own staging block (extracted from the script, not a
re-implementation) against the pinned extensions, writes the chelper verdict
the build bakes in, and runs nebulaos_compat's checks the way Klippy does
(run_preflight, from the staged copy of nebulaos_compat.py). It also checks
the negative: the unmodified manifest is refused as "SHADOWED".

Needs vendor/nebulaos-klipper-extensions at KLIPPER_EXTENSIONS_PIN and
vendor/klipper (for the required-symbol probe); prints ...=SKIP otherwise.
Run: python3 tests/factory-fallback-compat-tests.py
"""
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
BUILD = os.path.join(ROOT, "scripts", "build")
VENDOR = os.path.join(ROOT, "vendor")
EXT = os.path.join(VENDOR, "nebulaos-klipper-extensions")
KLIPPY = os.path.join(VENDOR, "klipper", "klippy")


def pin():
    with open(os.path.join(ROOT, "manifests", "dependencies.conf")) as f:
        m = re.search(r"^KLIPPER_EXTENSIONS_PIN=([0-9a-f]{40})$", f.read(), re.M)
    return m.group(1)


def staging_block():
    """04's extension staging, from EXT_SRC= to the matching fi."""
    with open(os.path.join(BUILD, "04-cross-compile-app-stack.sh")) as f:
        lines = f.read().split("\n")
    start = next(i for i, l in enumerate(lines)
                 if l.startswith('EXT_SRC="$VENDOR/nebulaos-klipper-extensions"'))
    end = next(i for i in range(start, len(lines)) if lines[i] == "fi")
    return "\n".join(lines[start:end + 1])


def skip(why):
    print(why)
    print("FACTORY_FALLBACK_COMPAT=SKIP")
    sys.exit(2)


class FactoryFallbackCompatTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="ffb-")
        cls.overlay = os.path.join(cls.tmp, "overlay")
        cls.klipper = os.path.join(cls.overlay, "opt", "klipper")
        os.makedirs(os.path.join(cls.klipper, "klippy", "extras"))
        script = "set -e\nSCRIPT_DIR=%s\nVENDOR=%s\nOVERLAY=%s\n%s\n" % (
            BUILD, VENDOR, cls.overlay, staging_block())
        out = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
        if out.returncode != 0:
            raise AssertionError("04's staging block failed:\n" + out.stdout + out.stderr)
        cls.klippy = os.path.join(cls.klipper, "klippy")
        cls.manifest_path = os.path.join(cls.klippy, "nebulaos-extensions.json")
        with open(cls.manifest_path) as f:
            cls.manifest = json.load(f)
        # The verdict the build bakes in (chelper_write_verdict after
        # chelper_enforce_mtime); its own correctness is the build's check.
        result = cls.manifest["chelper"]["platform_result_file"]
        path = result if os.path.isabs(result) else os.path.join(cls.klipper, result)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump({"status": "ok"}, f)
        # nebulaos_compat as Klippy imports it: from the staged tree.
        sys.path.insert(0, KLIPPY)
        spec = importlib.util.spec_from_file_location(
            "staged_nebulaos_compat", os.path.join(cls.klippy, "extras", "nebulaos_compat.py"))
        cls.compat = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.compat)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_every_manifest_module_is_a_real_file(self):
        paths = [m["path"] for m in self.manifest["modules"]]
        self.assertIn("extras/motor_database.cfg", paths)
        for p in paths:
            f = os.path.join(self.klippy, "extras", os.path.basename(p))
            self.assertTrue(os.path.isfile(f) and not os.path.islink(f), p)

    def test_composition_check_is_off_in_the_fallback_manifest(self):
        self.assertIs(self.manifest["composition"]["require_symlink_resolving_inside_source"], False)

    def test_run_preflight_passes_on_the_fallback_tree(self):
        status = self.compat.run_preflight(self.manifest_path, self.klipper)
        self.assertEqual(status["status"], "ok")
        self.assertIsNone(status["verified_composed_modules"])

    def test_the_unmodified_manifest_would_be_refused(self):
        with open(os.path.join(EXT, "nebulaos-extensions.json")) as f:
            original = json.load(f)
        self.assertIs(original["composition"]["require_symlink_resolving_inside_source"], True)
        with self.assertRaises(self.compat.CompatibilityError) as cm:
            self.compat.check_composition_integrity(original, self.klipper, self.klippy)
        self.assertIn("SHADOWED", str(cm.exception))


if __name__ == "__main__":
    if not os.path.isdir(os.path.join(EXT, ".git")) and not os.path.isfile(os.path.join(EXT, "nebulaos-extensions.json")):
        skip("vendor/nebulaos-klipper-extensions not present")
    if not os.path.isdir(KLIPPY):
        skip("vendor/klipper not present")
    head = subprocess.run(["git", "-C", EXT, "rev-parse", "HEAD"],
                          capture_output=True, text=True).stdout.strip()
    if head != pin():
        skip("vendor/nebulaos-klipper-extensions is at %s, not the pin %s" % (head[:12], pin()[:12]))
    unittest.main()
