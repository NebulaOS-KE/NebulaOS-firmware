#!/usr/bin/env python3
"""Issue #21 (2026-11-16): the [nebulaos] Moonraker component says why the
Update page shows klipper / nebulaos_klipper_extensions as INVALID "?".

When S05nebulaos-activate keeps Klipper on the image's built-in copy (no
.git), Moonraker cannot read a version. The component reads the activation
state S05 wrote and adds a Moonraker warning (Mainsail shows it) that says
why and what to do - and removes it when Klipper runs from the persistent
copy again.
"""
import importlib.util
import json
import os
import sys
import tempfile
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
COMPONENT = os.path.join(HERE, "..", "scripts", "build", "overlay", "usr", "lib",
                         "nebulaos", "moonraker", "nebulaos.py")


def load_component():
    # nebulaos.py is a Moonraker component: `from ..common import RequestType`.
    pkg = types.ModuleType("mr")
    pkg.__path__ = []
    comps = types.ModuleType("mr.components")
    comps.__path__ = []
    common = types.ModuleType("mr.common")

    class RequestType:
        GET = 1
        POST = 2
        DELETE = 4
    common.RequestType = RequestType
    sys.modules.update({"mr": pkg, "mr.components": comps, "mr.common": common})
    spec = importlib.util.spec_from_file_location("mr.components.nebulaos", COMPONENT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


NB = load_component()


class FakeServer:
    def __init__(self):
        self.warnings = {}

    def add_warning(self, msg, warn_id=None, log=True):
        self.warnings[warn_id] = msg

    def remove_warning(self, warn_id):
        self.warnings.pop(warn_id, None)


def state(bind, **decisions):
    return {"klipper_bind_active": bind, "decisions": decisions}


class WarningText(unittest.TestCase):
    def test_persistent_copy_no_warning(self):
        self.assertIsNone(NB.klipper_source_warning(
            state("yes", klipper="persistent", klipper_stack="persistent")))

    def test_update_being_checked_says_wait(self):
        msg = NB.klipper_source_warning(
            state("no", klipper="immutable:stack_update_in_progress"))
        self.assertIn("being checked", msg)
        self.assertIn("Nothing to do", msg)
        self.assertNotIn("Hard recovery", msg)

    def test_damaged_copy_says_how_to_repair(self):
        for reason in ("immutable:not_present", "immutable:incomplete_or_invalid",
                       "immutable:extensions_older_than_image"):
            msg = NB.klipper_source_warning(state("no", klipper_stack=reason))
            self.assertIn("built-in copy (" + reason.split(":")[1].replace("_", " ") + ")", msg)
            self.assertIn("Hard recovery", msg)
            self.assertIn("INVALID", msg)

    def test_stack_reason_wins_over_klipper(self):
        msg = NB.klipper_source_warning(
            state("no", klipper="persistent", klipper_stack="immutable:composition_failed"))
        self.assertIn("composition failed", msg)

    def test_garbage_is_no_warning(self):
        for bad in (None, [], "x", {}, {"decisions": None}):
            self.assertIsNone(NB.klipper_source_warning(bad))


class SyncWarning(unittest.TestCase):
    def make(self, content):
        fd, path = tempfile.mkstemp()
        with os.fdopen(fd, "w") as fh:
            fh.write(content)
        self.addCleanup(os.unlink, path)
        comp = NB.NebulaOS.__new__(NB.NebulaOS)
        comp.server = FakeServer()
        comp.activation_state = path
        return comp

    def test_added_then_removed(self):
        comp = self.make(json.dumps(state("no", klipper_stack="immutable:not_present")))
        comp._sync_klipper_source_warning()
        self.assertIn(NB.KLIPPER_SOURCE_WARNING, comp.server.warnings)
        with open(comp.activation_state, "w") as fh:
            json.dump(state("yes", klipper="persistent"), fh)
        comp._sync_klipper_source_warning()
        self.assertNotIn(NB.KLIPPER_SOURCE_WARNING, comp.server.warnings)

    def test_unreadable_state_changes_nothing(self):
        comp = self.make("{not json")
        comp._sync_klipper_source_warning()
        self.assertEqual(comp.server.warnings, {})


if __name__ == "__main__":
    unittest.main(verbosity=2)
