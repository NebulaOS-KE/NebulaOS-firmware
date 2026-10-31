#!/usr/bin/env python3
# Timelapse defaults, set once (2026-10-31): nebulaos-seed-timelapse switches
# upstream moonraker-timelapse off through its own settings API, once per
# printer, and never touches a user's later choice.
# Usage: python3 tests/nebulaos-seed-timelapse-tests.py
from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import tempfile
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPT = os.path.join(REPO, "scripts", "build", "overlay", "usr", "libexec",
                      "nebulaos-seed-timelapse")
INIT = os.path.join(REPO, "scripts", "build", "overlay", "etc", "init.d",
                    "S57nebulaos-timelapse-seed")


def load():
    loader = importlib.machinery.SourceFileLoader("seed_timelapse", SCRIPT)
    spec = importlib.util.spec_from_loader("seed_timelapse", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class SeedTests(unittest.TestCase):
    def setUp(self):
        self.mod = load()
        self.dir = tempfile.mkdtemp()
        self.marker = os.path.join(self.dir, "system", "seeded.json")
        self.posts = []
        self.logs = []

    def run_seed(self, statuses, post_status=200):
        statuses = list(statuses)

        def get_status(path):
            return statuses.pop(0) if statuses else 200

        def post(path, query):
            self.posts.append((path, dict(query)))
            return post_status

        return self.mod.run(get_status=get_status, post=post, marker_path=self.marker,
                            log=self.logs.append, sleep=lambda s: None, attempts=3, delay=0)

    def test_sets_off_once_and_writes_the_marker(self):
        self.run_seed([0, 200])
        self.assertEqual(self.posts, [("/machine/timelapse/settings",
                                       {"enabled": "false", "parkhead": "false",
                                        "extraoutputparams": "-preset ultrafast"})])
        with open(self.marker) as f:
            self.assertEqual(json.load(f)["defaults"]["enabled"], "false")

    def test_never_again_after_the_marker(self):
        self.run_seed([200])
        self.run_seed([200])
        self.assertEqual(len(self.posts), 1)

    def test_no_marker_when_moonraker_never_answers(self):
        self.assertEqual(self.run_seed([0, 0, 0]), 0)
        self.assertEqual(self.posts, [])
        self.assertFalse(os.path.exists(self.marker))

    def test_no_marker_when_the_post_fails(self):
        self.run_seed([200], post_status=500)
        self.assertFalse(os.path.exists(self.marker))

    def test_init_script_starts_it_in_the_background(self):
        with open(INIT) as f:
            text = f.read()
        self.assertIn("/usr/libexec/nebulaos-seed-timelapse", text)
        self.assertIn("2>&1 &", text)


if __name__ == "__main__":
    unittest.main(verbosity=1)
