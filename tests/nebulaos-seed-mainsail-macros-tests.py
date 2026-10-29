#!/usr/bin/env python3
#
# Offline, repeatable tests for
# scripts/build/overlay/usr/libexec/nebulaos-seed-mainsail-macros (Phase 2
# macro-cleanup/Mainsail-grouping mission, 2026-09-04; extended 2026-09-06,
# RC2 overnight closure, for the hyphenated-ID rename, the legacy-ID
# migration, and the macros.mode=expert fresh-install default). Imports the
# actual production module directly (no parallel copy of the logic) and
# exercises run() with fake get_status/post/delete/sleep callables and a
# temp-directory marker path - no real Moonraker, no real device, no real
# network, ever.
#
# Mirrors tests/nebulaos-seed-camera-tests.py's own structure deliberately -
# same idempotence/never-overwrite/verify-after-write properties, same
# fake-transport pattern, adapted for a per-key database check instead of
# a single-list webcam check.
#
# Usage: python3 tests/nebulaos-seed-mainsail-macros-tests.py

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import shutil
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MODULE_PATH = os.path.join(
    SCRIPT_DIR, "..", "scripts", "build", "overlay", "usr", "libexec",
    "nebulaos-seed-mainsail-macros",
)


def _load_module():
    loader = importlib.machinery.SourceFileLoader("nebulaos_seed_mainsail_macros", MODULE_PATH)
    spec = importlib.util.spec_from_loader("nebulaos_seed_mainsail_macros", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


seed = _load_module()

PASS = 0
FAIL = 0


def check(desc, condition, detail=""):
    global PASS, FAIL
    if condition:
        print(f"PASS: {desc}")
        PASS += 1
    else:
        print(f"FAIL: {desc}" + (f" ({detail})" if detail else ""))
        FAIL += 1


class FakeMoonrakerDb:
    """A tiny, deterministic stand-in for Moonraker's real
    /server/database/item GET/POST/DELETE API - a flat dict of
    {key: value} under the mainsail namespace (any key shape, not just
    macros.macrogroups.<id> - the production module also uses
    macros.mode), plus counters so tests can assert exactly how many
    times each verb was called."""

    def __init__(self, existing=None, available=True):
        self.store = dict(existing or {})
        self.available = available
        self.get_calls = 0
        self.post_calls = 0
        self.delete_calls = 0

    def _key_from_path(self, path):
        assert "namespace=mainsail&key=" in path
        return path.split("key=", 1)[1]

    def get_status(self, path):
        self.get_calls += 1
        if not self.available:
            raise ConnectionError("moonraker not reachable")
        if path == "/server/database/list":
            return 200, json.dumps({"result": {"namespaces": ["mainsail"]}})
        key = self._key_from_path(path)
        if key not in self.store:
            return 404, None
        return 200, json.dumps({
            "result": {"namespace": "mainsail", "key": key, "value": self.store[key]}
        })

    def post(self, path, payload):
        self.post_calls += 1
        assert path == "/server/database/item"
        assert payload["namespace"] == "mainsail"
        key = payload["key"]
        self.store[key] = payload["value"]
        return json.dumps({"result": {"namespace": "mainsail", "key": key, "value": payload["value"]}})

    def delete(self, path):
        self.delete_calls += 1
        key = self._key_from_path(path)
        if key not in self.store:
            return 404, None
        value = self.store.pop(key)
        return 200, json.dumps({"result": {"namespace": "mainsail", "key": key, "value": value}})


def group_key(group_id):
    return f"macros.macrogroups.{group_id}"


TWO_GROUPS = {
    "group_a": {"name": "Group A", "macros": [{"pos": 0, "name": "RUN_A"}]},
    "group_b": {"name": "Group B", "macros": [{"pos": 0, "name": "RUN_B"}]},
}


def with_marker_dir(fn):
    d = tempfile.mkdtemp(prefix="mainsail-macros-seed-test-")
    try:
        return fn(os.path.join(d, "system", "default-mainsail-macros-seeded.json"))
    finally:
        shutil.rmtree(d, ignore_errors=True)


# --- Test 1: Moonraker unavailable - bounded retry, no marker, safe exit ---
def test_moonraker_unavailable():
    def body(marker_path):
        moon = FakeMoonrakerDb(available=False)
        rc, logs = run_seed(marker_path, moon, retry_attempts=3, retry_delay=0)
        check("unavailable: rc==1", rc == 1)
        check("unavailable: attempted exactly retry_attempts GETs",
              moon.get_calls == 3, f"got {moon.get_calls}")
        check("unavailable: no POST calls", moon.post_calls == 0)
        check("unavailable: no marker written", not os.path.exists(marker_path))
        check("unavailable: failure logged",
              any("unavailable" in line or "never became available" in line for line in logs))

    with_marker_dir(body)


# --- Test 2: fresh install, neither group exists - both created and verified ---
def test_fresh_install_creates_both_groups():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={})
        rc, logs = run_seed(marker_path, moon)
        check("fresh install: rc==0", rc == 0)
        check("fresh install: exactly two group POSTs plus one mode POST",
              moon.post_calls == 3, f"got {moon.post_calls}")
        check("fresh install: both groups now in store",
              set(moon.store.keys()) == {group_key("group_a"), group_key("group_b"), seed.MODE_KEY})
        check("fresh install: group content matches exactly",
              moon.store[group_key("group_a")] == TWO_GROUPS["group_a"]
              and moon.store[group_key("group_b")] == TWO_GROUPS["group_b"])
        check("fresh install: macros.mode defaulted to expert",
              moon.store[seed.MODE_KEY] == "expert")
        with open(marker_path) as f:
            marker = json.load(f)
        check("fresh install: marker records both as created",
              set(marker.get("created", [])) == {"group_a", "group_b"})
        check("fresh install: marker has no failed entries", marker.get("failed") == [])
        check("fresh install: marker records mode_default=seeded",
              marker.get("mode_default") == "seeded")

    with_marker_dir(body)


# --- Test 3: one group already present (e.g. user-edited) - never overwritten ---
def test_existing_group_never_overwritten():
    def body(marker_path):
        user_customized = {"name": "My Custom Group", "macros": [{"pos": 0, "name": "SOMETHING_ELSE"}]}
        moon = FakeMoonrakerDb(existing={group_key("group_a"): user_customized})
        rc, logs = run_seed(marker_path, moon)
        check("existing group: rc==0", rc == 0)
        check("existing group: only one group POST (for group_b) plus mode POST",
              moon.post_calls == 2, f"got {moon.post_calls}")
        check("existing group: group_a completely unchanged",
              moon.store[group_key("group_a")] == user_customized)
        check("existing group: group_b created",
              moon.store[group_key("group_b")] == TWO_GROUPS["group_b"])
        with open(marker_path) as f:
            marker = json.load(f)
        check("existing group: marker lists group_a as already_present",
              "group_a" in marker.get("already_present", []))
        check("existing group: marker lists group_b as created",
              "group_b" in marker.get("created", []))

    with_marker_dir(body)


# --- Test 4: second run after a first successful run - fully idempotent, zero POSTs ---
def test_repeated_invocation_is_idempotent():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={})
        rc1, _ = run_seed(marker_path, moon)
        check("idempotent: first run rc==0", rc1 == 0)
        check("idempotent: first run posts (2 groups + mode)", moon.post_calls == 3)

        rc2, logs2 = run_seed(marker_path, moon)
        check("idempotent: second run rc==0", rc2 == 0)
        check("idempotent: second run makes zero additional POSTs",
              moon.post_calls == 3, f"got {moon.post_calls}")
        already_present_lines = [line for line in logs2 if "already present" in line]
        check("idempotent: second run logs both groups as already present",
              len(already_present_lines) == 2, f"got {already_present_lines}")
        check("idempotent: second run leaves macros.mode untouched",
              any("already set to" in line for line in logs2))

    with_marker_dir(body)


# --- Test 5: a NEW group introduced by a later firmware version seeds into an
#     existing, already-seeded install without touching the old ones ---
def test_new_group_added_later_seeds_into_existing_install():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={})
        run_seed(marker_path, moon)  # first boot: only group_a/group_b exist

        three_groups = dict(TWO_GROUPS)
        three_groups["group_c"] = {"name": "Group C", "macros": [{"pos": 0, "name": "RUN_C"}]}
        rc, logs = run_seed(marker_path, moon, groups=three_groups)
        check("new group later: rc==0", rc == 0)
        check("new group later: exactly one new group POST (group_c only)",
              moon.post_calls == 4, f"got {moon.post_calls}")
        check("new group later: group_c now present", group_key("group_c") in moon.store)
        check("new group later: group_a/group_b untouched",
              moon.store[group_key("group_a")] == TWO_GROUPS["group_a"]
              and moon.store[group_key("group_b")] == TWO_GROUPS["group_b"])

    with_marker_dir(body)


# --- Test 6: POST "succeeds" but verification finds different content - failure, group not marked created ---
def test_creation_reports_success_but_verification_mismatches():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={})

        def post_but_store_wrong_value(path, payload):
            moon.post_calls += 1
            key = payload["key"]
            if key.startswith("macros.macrogroups."):
                moon.store[key] = {"name": "WRONG", "macros": []}
            else:
                moon.store[key] = payload["value"]
            return json.dumps({"result": {}})

        logs = []
        rc = seed.run(
            get_status=moon.get_status,
            post=post_but_store_wrong_value,
            delete=moon.delete,
            marker_path=marker_path,
            log=logs.append,
            groups=TWO_GROUPS,
            legacy_map={},
            retry_attempts=3,
            retry_delay=0,
            sleep=lambda _s: None,
        )
        check("verification mismatch: rc==1", rc == 1)
        check("verification mismatch: marker still written (records the failure)",
              os.path.exists(marker_path))
        with open(marker_path) as f:
            marker = json.load(f)
        check("verification mismatch: both groups recorded as failed",
              set(marker.get("failed", [])) == {"group_a", "group_b"})
        check("verification mismatch: neither recorded as created",
              marker.get("created") == [])

    with_marker_dir(body)


# --- Test 7: transport error mid-check for one group doesn't block the other ---
def test_one_group_transport_error_does_not_block_the_other():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={})
        real_get = moon.get_status

        def flaky_get(path):
            if "group_a" in path:
                raise ConnectionError("flaky")
            return real_get(path)

        logs = []
        rc = seed.run(
            get_status=flaky_get,
            post=moon.post,
            delete=moon.delete,
            marker_path=marker_path,
            log=logs.append,
            groups=TWO_GROUPS,
            legacy_map={},
            retry_attempts=3,
            retry_delay=0,
            sleep=lambda _s: None,
        )
        check("flaky group: rc==1 (group_a failed)", rc == 1)
        check("flaky group: group_b still created",
              moon.store.get(group_key("group_b")) == TWO_GROUPS["group_b"])
        with open(marker_path) as f:
            marker = json.load(f)
        check("flaky group: group_a recorded as failed", "group_a" in marker.get("failed", []))
        check("flaky group: group_b recorded as created", "group_b" in marker.get("created", []))

    with_marker_dir(body)


# --- Test 8: real production DEFAULT_GROUPS is well-formed (every macro name
#     a plain non-empty string, every pos unique per group, every group has
#     a name and at least one macro, every group carries its required
#     metadata, and no NebulaOS-managed group ID contains "_" - mission
#     requirement) - catches a typo/duplicate/regression before it ever
#     reaches a real device. ---
def test_default_groups_are_well_formed():
    for group_id, definition in seed.DEFAULT_GROUPS.items():
        check(f"{group_id}: has a non-empty name",
              isinstance(definition.get("name"), str) and definition["name"])
        check(f"{group_id}: contains no underscore (Mainsail's Dashboard.vue "
              "parses a panel name as name.split('_')[1] - an id with a "
              "further underscore breaks that lookup)",
              "_" not in group_id, f"group_id={group_id!r}")
        check(f"{group_id}: has group-level color metadata",
              definition.get("color") == "primary")
        for flag in ("showInStandby", "showInPause", "showInPrinting"):
            check(f"{group_id}: has group-level {flag} (bool)",
                  isinstance(definition.get(flag), bool),
                  f"{flag}={definition.get(flag)!r}")
        macros = definition.get("macros")
        check(f"{group_id}: has at least one macro",
              isinstance(macros, list) and len(macros) > 0)
        positions = [m.get("pos") for m in macros]
        check(f"{group_id}: macro positions are unique",
              len(positions) == len(set(positions)), f"positions={positions}")
        for m in macros:
            check(f"{group_id}: macro {m.get('name')!r} has a non-empty string name",
                  isinstance(m.get("name"), str) and m["name"])


# --- Test 9: LEGACY_GROUP_ID_MAP itself is well-formed: every value is a
#     real key in DEFAULT_GROUPS, every key is the exact pre-2026-09-06
#     underscore form, and no accidental self-mapping. ---
def test_legacy_group_id_map_is_well_formed():
    valid_targets = set(seed.DEFAULT_GROUPS.keys()) | set(seed.RC3_GROUPS.keys())
    for old_id, new_id in seed.LEGACY_GROUP_ID_MAP.items():
        check(f"legacy map: {old_id!r} -> {new_id!r} target exists in DEFAULT_GROUPS or RC3_GROUPS",
              new_id in valid_targets)
        check(f"legacy map: {old_id!r} is a real underscore id (differs from its target)",
              old_id != new_id)


# --- Test 10: a fresh install with no legacy groups at all - migration is a
#     complete no-op, and every legacy id is reported "not_present" ---
def test_migration_noop_on_fresh_install():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={})
        legacy_map = {"nebulaos_calibration": "nebulaos-calibration"}
        rc, logs = run_seed(marker_path, moon,
                             groups={"nebulaos-calibration": {"name": "Calibration", "macros": [{"pos": 0, "name": "X"}]}},
                             legacy_map=legacy_map)
        check("migration noop: rc==0", rc == 0)
        check("migration noop: no DELETE calls", moon.delete_calls == 0)
        with open(marker_path) as f:
            marker = json.load(f)
        check("migration noop: legacy id reported not_present",
              marker.get("migration", {}).get("nebulaos_calibration") == "not_present")

    with_marker_dir(body)


# --- Test 11: the real migration case - an existing install has the old
#     underscore group (possibly user-edited) and nothing under the new
#     hyphenated id yet. Migration must rename it (preserving content
#     exactly, including any user edits), delete the old key, and the
#     default-seed step must then see the new id as already present (never
#     re-seed a fresh default over the user's real data). ---
def test_migration_renames_legacy_group_preserving_user_edits():
    def body(marker_path):
        user_customized = {"name": "My Calibration", "macros": [{"pos": 0, "name": "MY_MACRO"}]}
        moon = FakeMoonrakerDb(existing={"macros.macrogroups.nebulaos_calibration": user_customized})
        legacy_map = {"nebulaos_calibration": "nebulaos-calibration"}
        fresh_default = {"name": "Calibration", "macros": [{"pos": 0, "name": "NEBULAOS_AUTO_CALIBRATE"}]}
        rc, logs = run_seed(marker_path, moon,
                             groups={"nebulaos-calibration": fresh_default},
                             legacy_map=legacy_map)
        check("migration rename: rc==0", rc == 0)
        check("migration rename: old underscore key is gone",
              "macros.macrogroups.nebulaos_calibration" not in moon.store)
        check("migration rename: new hyphenated key holds the USER's exact old content, "
              "not the fresh default",
              moon.store.get("macros.macrogroups.nebulaos-calibration") == user_customized)
        with open(marker_path) as f:
            marker = json.load(f)
        check("migration rename: marker records migrated",
              marker.get("migration", {}).get("nebulaos_calibration") == "migrated")
        check("migration rename: the default-seed step treated the migrated group as "
              "already present (did not overwrite it with the fresh default)",
              "nebulaos-calibration" in marker.get("already_present", []))

    with_marker_dir(body)


# --- Test 12: running migration twice makes no further change (idempotent) ---
def test_migration_is_idempotent_across_two_runs():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={"macros.macrogroups.nebulaos_calibration": {"name": "C", "macros": [{"pos": 0, "name": "X"}]}})
        legacy_map = {"nebulaos_calibration": "nebulaos-calibration"}
        groups = {"nebulaos-calibration": {"name": "Calibration", "macros": [{"pos": 0, "name": "NEBULAOS_AUTO_CALIBRATE"}]}}

        rc1, _ = run_seed(marker_path, moon, groups=groups, legacy_map=legacy_map)
        check("migration idempotent: first run rc==0", rc1 == 0)
        state_after_first = dict(moon.store)

        rc2, logs2 = run_seed(marker_path, moon, groups=groups, legacy_map=legacy_map)
        check("migration idempotent: second run rc==0", rc2 == 0)
        check("migration idempotent: second run makes zero further store changes",
              moon.store == state_after_first)
        check("migration idempotent: second run reports the legacy id as not_present "
              "(already migrated, nothing left to do)",
              any("not_present" in line or "already present" in line for line in logs2))

    with_marker_dir(body)


# --- Test 13: both old and new ids already present with IDENTICAL content
#     (an interrupted prior migration that created the new key but failed
#     before deleting the old one) - migration must finish the cleanup by
#     deleting the now-redundant old key, without touching the new one. ---
def test_migration_finishes_an_interrupted_prior_run():
    def body(marker_path):
        same_value = {"name": "Calibration", "macros": [{"pos": 0, "name": "NEBULAOS_AUTO_CALIBRATE"}]}
        moon = FakeMoonrakerDb(existing={
            "macros.macrogroups.nebulaos_calibration": same_value,
            "macros.macrogroups.nebulaos-calibration": same_value,
        })
        legacy_map = {"nebulaos_calibration": "nebulaos-calibration"}
        rc, logs = run_seed(marker_path, moon,
                             groups={"nebulaos-calibration": same_value},
                             legacy_map=legacy_map)
        check("interrupted migration: rc==0", rc == 0)
        check("interrupted migration: old key finally deleted",
              "macros.macrogroups.nebulaos_calibration" not in moon.store)
        check("interrupted migration: new key untouched",
              moon.store["macros.macrogroups.nebulaos-calibration"] == same_value)
        with open(marker_path) as f:
            marker = json.load(f)
        check("interrupted migration: marker records finished_interrupted",
              marker.get("migration", {}).get("nebulaos_calibration") == "finished_interrupted")

    with_marker_dir(body)


# --- Test 14: both old and new ids present with DIFFERENT content - a real
#     collision this script cannot safely resolve on its own. Must leave
#     BOTH untouched and flag it, never guess which one is "right". ---
def test_migration_leaves_a_genuine_collision_untouched():
    def body(marker_path):
        old_value = {"name": "Old Calibration", "macros": [{"pos": 0, "name": "OLD_MACRO"}]}
        new_value = {"name": "Someone else's group", "macros": [{"pos": 0, "name": "DIFFERENT_MACRO"}]}
        moon = FakeMoonrakerDb(existing={
            "macros.macrogroups.nebulaos_calibration": old_value,
            "macros.macrogroups.nebulaos-calibration": new_value,
        })
        legacy_map = {"nebulaos_calibration": "nebulaos-calibration"}
        rc, logs = run_seed(marker_path, moon,
                             groups={"nebulaos-calibration": {"name": "Calibration", "macros": [{"pos": 0, "name": "NEBULAOS_AUTO_CALIBRATE"}]}},
                             legacy_map=legacy_map)
        check("migration collision: rc==1 (flagged, not silently resolved)", rc == 1)
        check("migration collision: old key left exactly as-is",
              moon.store["macros.macrogroups.nebulaos_calibration"] == old_value)
        check("migration collision: new key left exactly as-is",
              moon.store["macros.macrogroups.nebulaos-calibration"] == new_value)
        check("migration collision: no DELETE was attempted",
              moon.delete_calls == 0)
        with open(marker_path) as f:
            marker = json.load(f)
        check("migration collision: marker records ambiguous_left_untouched",
              marker.get("migration", {}).get("nebulaos_calibration") == "ambiguous_left_untouched")

    with_marker_dir(body)


# --- Test 15: macros.mode is never overwritten once any value is present,
#     including an explicit user choice of "simple" - the fresh-install
#     Expert default must never become a persistent "force expert". ---
def test_mode_default_never_overwrites_existing_value():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={seed.MODE_KEY: "simple"})
        rc, logs = run_seed(marker_path, moon)
        check("mode preserved: rc==0", rc == 0)
        check("mode preserved: macros.mode is still 'simple'",
              moon.store[seed.MODE_KEY] == "simple")
        check("mode preserved: logged as already set, never re-posted",
              any("already set to" in line for line in logs))
        with open(marker_path) as f:
            marker = json.load(f)
        check("mode preserved: marker records mode_default=already_set",
              marker.get("mode_default") == "already_set")

    with_marker_dir(body)


# --- Test 16: mode-default seeding failing transport-wise is reported but
#     does not block group seeding from completing. ---
def test_mode_default_transport_failure_does_not_block_groups():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={})
        real_get = moon.get_status

        def flaky_get(path):
            if "macros.mode" in path:
                raise ConnectionError("flaky")
            return real_get(path)

        logs = []
        rc = seed.run(
            get_status=flaky_get,
            post=moon.post,
            delete=moon.delete,
            marker_path=marker_path,
            log=logs.append,
            groups=TWO_GROUPS,
            legacy_map={},
            retry_attempts=3,
            retry_delay=0,
            sleep=lambda _s: None,
        )
        check("mode transport failure: rc==1 (mode failed)", rc == 1)
        check("mode transport failure: both groups still created",
              moon.store.get(group_key("group_a")) == TWO_GROUPS["group_a"]
              and moon.store.get(group_key("group_b")) == TWO_GROUPS["group_b"])
        with open(marker_path) as f:
            marker = json.load(f)
        check("mode transport failure: marker records mode_default=failed",
              marker.get("mode_default") == "failed")

    with_marker_dir(body)


# --- Test 17: final product has exactly five groups ---
def test_final_product_has_exactly_five_groups():
    check("final group count is exactly 5",
          len(seed.DEFAULT_GROUPS) == 5,
          f"got {len(seed.DEFAULT_GROUPS)}: {list(seed.DEFAULT_GROUPS.keys())}")
    expected_ids = {"nebulaos-calibration", "nebulaos-extruder", "nebulaos-recovery",
                    "nebulaos-maintenance", "nebulaos-camera"}
    check("final group IDs match spec",
          set(seed.DEFAULT_GROUPS.keys()) == expected_ids,
          f"got {set(seed.DEFAULT_GROUPS.keys())}")
    check("no Input Shaper standalone group",
          "nebulaos-input-shaper" not in seed.DEFAULT_GROUPS)


# --- Test 18: Input Shaper macro is in Calibration group ---
def test_input_shaper_in_calibration_group():
    cal = seed.DEFAULT_GROUPS["nebulaos-calibration"]
    macro_names = [m["name"] for m in cal["macros"]]
    check("NEBULAOS_INPUT_SHAPER_CALIBRATE in Calibration group",
          "NEBULAOS_INPUT_SHAPER_CALIBRATE" in macro_names)
    check("NEBULAOS_CALIBRATION_CONTINUE not in any group",
          not any("NEBULAOS_CALIBRATION_CONTINUE" in [m["name"] for m in g["macros"]]
                  for g in seed.DEFAULT_GROUPS.values()))
    check("NEBULAOS_CALIBRATION_CANCEL not in any group",
          not any("NEBULAOS_CALIBRATION_CANCEL" in [m["name"] for m in g["macros"]]
                  for g in seed.DEFAULT_GROUPS.values()))


# --- Test 19: no workflow helper macros in any dashboard group ---
def test_no_workflow_helpers_in_dashboard():
    forbidden = {"PURGE_MORE", "RESUME_FILAMENT_CHANGE", "CANCEL_FILAMENT_CHANGE"}
    for group_id, definition in seed.DEFAULT_GROUPS.items():
        macro_names = {m["name"] for m in definition["macros"]}
        overlap = macro_names & forbidden
        check(f"{group_id}: no workflow helpers in dashboard",
              len(overlap) == 0, f"found {overlap}")


# --- Test 20: group visibility flags match spec ---
def test_group_visibility_flags():
    spec = {
        "nebulaos-calibration": (True, False, False),
        "nebulaos-extruder": (True, True, False),
        "nebulaos-recovery": (True, False, False),
        "nebulaos-maintenance": (True, True, True),
        "nebulaos-camera": (True, True, True),
    }
    for group_id, (standby, printing, pause) in spec.items():
        g = seed.DEFAULT_GROUPS[group_id]
        check(f"{group_id}: showInStandby={standby}", g["showInStandby"] == standby)
        check(f"{group_id}: showInPrinting={printing}", g["showInPrinting"] == printing)
        check(f"{group_id}: showInPause={pause}", g["showInPause"] == pause)


# --- Test 21: M600 macro visibility (standby=NO, printing=YES) ---
def test_m600_macro_visibility():
    ext = seed.DEFAULT_GROUPS["nebulaos-extruder"]
    m600 = next(m for m in ext["macros"] if m["name"] == "M600")
    check("M600: showInStandby=False", m600["showInStandby"] is False)
    check("M600: showInPrinting=True", m600["showInPrinting"] is True)
    check("M600: showInPause=False", m600["showInPause"] is False)


# --- Test 22: RC3 migration — input-shaper exact match is removed ---
def test_rc3_input_shaper_exact_match_removed():
    def body(marker_path):
        rc3_is = seed.RC3_GROUPS["nebulaos-input-shaper"]
        moon = FakeMoonrakerDb(existing={
            group_key("nebulaos-input-shaper"): rc3_is,
        })
        rc, logs = run_seed(marker_path, moon, groups={},
                            rc3_groups={"nebulaos-input-shaper": rc3_is})
        check("rc3 input-shaper exact: group removed from store",
              group_key("nebulaos-input-shaper") not in moon.store)
        with open(marker_path) as f:
            marker = json.load(f)
        check("rc3 input-shaper exact: marker records removed",
              marker.get("rc3_migration", {}).get("nebulaos-input-shaper") == "removed")

    with_marker_dir(body)


# --- Test 23: RC3 migration — user-modified input-shaper left untouched ---
def test_rc3_input_shaper_user_modified_left_untouched():
    def body(marker_path):
        user_modified = {"name": "My Input Shaper", "macros": [{"pos": 0, "name": "CUSTOM"}]}
        rc3_is = seed.RC3_GROUPS["nebulaos-input-shaper"]
        moon = FakeMoonrakerDb(existing={
            group_key("nebulaos-input-shaper"): user_modified,
        })
        rc, logs = run_seed(marker_path, moon, groups={},
                            rc3_groups={"nebulaos-input-shaper": rc3_is})
        check("rc3 input-shaper user-modified: group still in store",
              group_key("nebulaos-input-shaper") in moon.store)
        check("rc3 input-shaper user-modified: content unchanged",
              moon.store[group_key("nebulaos-input-shaper")] == user_modified)
        with open(marker_path) as f:
            marker = json.load(f)
        check("rc3 input-shaper user-modified: marker records user_modified_left_untouched",
              marker.get("rc3_migration", {}).get("nebulaos-input-shaper") == "user_modified_left_untouched")

    with_marker_dir(body)


# --- Test 24: RC3 migration — input-shaper not present is a no-op ---
def test_rc3_input_shaper_not_present():
    def body(marker_path):
        rc3_is = seed.RC3_GROUPS["nebulaos-input-shaper"]
        moon = FakeMoonrakerDb(existing={})
        rc, logs = run_seed(marker_path, moon, groups={},
                            rc3_groups={"nebulaos-input-shaper": rc3_is})
        check("rc3 input-shaper not present: rc==0", rc == 0)
        with open(marker_path) as f:
            marker = json.load(f)
        check("rc3 input-shaper not present: marker records not_present",
              marker.get("rc3_migration", {}).get("nebulaos-input-shaper") == "not_present")

    with_marker_dir(body)


# --- Test 25: RC3 migration — calibration group updated from RC3 to final ---
def test_rc3_calibration_migrated_to_final():
    def body(marker_path):
        rc3_cal = seed.RC3_GROUPS["nebulaos-calibration"]
        final_cal = seed.DEFAULT_GROUPS["nebulaos-calibration"]
        moon = FakeMoonrakerDb(existing={
            group_key("nebulaos-calibration"): rc3_cal,
        })
        rc, logs = run_seed(marker_path, moon,
                            groups={"nebulaos-calibration": final_cal},
                            rc3_groups={"nebulaos-calibration": rc3_cal})
        check("rc3 cal migrated: rc==0", rc == 0)
        check("rc3 cal migrated: group now matches final",
              moon.store[group_key("nebulaos-calibration")] == final_cal)
        check("rc3 cal migrated: final has 11 macros (including INPUT_SHAPER, LOAD_CELL + mode buttons, BED_TRAM; no AXIS_TWIST_Y)",
              len(final_cal["macros"]) == 11)
        with open(marker_path) as f:
            marker = json.load(f)
        check("rc3 cal migrated: marker records migrated",
              marker.get("rc3_migration", {}).get("nebulaos-calibration") == "migrated")

    with_marker_dir(body)


# --- Test 26: RC3 migration — extruder group updated (helpers removed) ---
def test_rc3_extruder_migrated_to_final():
    def body(marker_path):
        rc3_ext = seed.RC3_GROUPS["nebulaos-extruder"]
        final_ext = seed.DEFAULT_GROUPS["nebulaos-extruder"]
        moon = FakeMoonrakerDb(existing={
            group_key("nebulaos-extruder"): rc3_ext,
        })
        rc, logs = run_seed(marker_path, moon,
                            groups={"nebulaos-extruder": final_ext},
                            rc3_groups={"nebulaos-extruder": rc3_ext})
        check("rc3 ext migrated: rc==0", rc == 0)
        check("rc3 ext migrated: group now matches final",
              moon.store[group_key("nebulaos-extruder")] == final_ext)
        check("rc3 ext migrated: final has 4 macros (no helpers)",
              len(final_ext["macros"]) == 4)
        with open(marker_path) as f:
            marker = json.load(f)
        check("rc3 ext migrated: marker records migrated",
              marker.get("rc3_migration", {}).get("nebulaos-extruder") == "migrated")

    with_marker_dir(body)


# --- Test 27: RC3 migration — recovery group visibility updated ---
def test_rc3_recovery_migrated_to_final():
    def body(marker_path):
        rc3_rec = seed.RC3_GROUPS["nebulaos-recovery"]
        final_rec = seed.DEFAULT_GROUPS["nebulaos-recovery"]
        moon = FakeMoonrakerDb(existing={
            group_key("nebulaos-recovery"): rc3_rec,
        })
        rc, logs = run_seed(marker_path, moon,
                            groups={"nebulaos-recovery": final_rec},
                            rc3_groups={"nebulaos-recovery": rc3_rec})
        check("rc3 rec migrated: rc==0", rc == 0)
        check("rc3 rec migrated: group now matches final",
              moon.store[group_key("nebulaos-recovery")] == final_rec)
        check("rc3 rec migrated: printing=False in final",
              final_rec["showInPrinting"] is False)
        with open(marker_path) as f:
            marker = json.load(f)
        check("rc3 rec migrated: marker records migrated",
              marker.get("rc3_migration", {}).get("nebulaos-recovery") == "migrated")

    with_marker_dir(body)


# --- Test 28: RC3 migration — user-modified calibration left alone ---
def test_rc3_user_modified_calibration_left_alone():
    def body(marker_path):
        rc3_cal = seed.RC3_GROUPS["nebulaos-calibration"]
        final_cal = seed.DEFAULT_GROUPS["nebulaos-calibration"]
        user_cal = {"name": "My Calibration", "macros": [{"pos": 0, "name": "CUSTOM"}]}
        moon = FakeMoonrakerDb(existing={
            group_key("nebulaos-calibration"): user_cal,
        })
        rc, logs = run_seed(marker_path, moon,
                            groups={"nebulaos-calibration": final_cal},
                            rc3_groups={"nebulaos-calibration": rc3_cal})
        check("rc3 user cal: group unchanged",
              moon.store[group_key("nebulaos-calibration")] == user_cal)
        with open(marker_path) as f:
            marker = json.load(f)
        check("rc3 user cal: marker records user_modified_left_untouched",
              marker.get("rc3_migration", {}).get("nebulaos-calibration") == "user_modified_left_untouched")

    with_marker_dir(body)


# --- Test 29: RC3 migration — already-final group is recognized ---
def test_rc3_already_final_is_recognized():
    def body(marker_path):
        rc3_cal = seed.RC3_GROUPS["nebulaos-calibration"]
        final_cal = seed.DEFAULT_GROUPS["nebulaos-calibration"]
        moon = FakeMoonrakerDb(existing={
            group_key("nebulaos-calibration"): final_cal,
        })
        rc, logs = run_seed(marker_path, moon,
                            groups={"nebulaos-calibration": final_cal},
                            rc3_groups={"nebulaos-calibration": rc3_cal})
        check("rc3 already final: rc==0", rc == 0)
        check("rc3 already final: group unchanged",
              moon.store[group_key("nebulaos-calibration")] == final_cal)
        with open(marker_path) as f:
            marker = json.load(f)
        check("rc3 already final: marker records already_final",
              marker.get("rc3_migration", {}).get("nebulaos-calibration") == "already_final")

    with_marker_dir(body)


# --- Test 30: RC3 migration — unchanged groups (camera, maintenance) are skipped ---
def test_rc3_unchanged_groups_skipped():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={})
        rc, logs = run_seed(marker_path, moon,
                            groups=seed.DEFAULT_GROUPS,
                            rc3_groups=seed.RC3_GROUPS)
        with open(marker_path) as f:
            marker = json.load(f)
        rc3_mig = marker.get("rc3_migration", {})
        # Run 23: the Camera group changed (Nebula Camera macros), so it is
        # no longer "unchanged since RC3"; on an empty database it is simply
        # not there yet (and is seeded new).
        check("rc3 unchanged: camera now differs from RC3, absent here",
              rc3_mig.get("nebulaos-camera") == "not_present")
        check("rc3 unchanged: maintenance skipped",
              rc3_mig.get("nebulaos-maintenance") == "unchanged")

    with_marker_dir(body)


# --- Test 31: full RC3 six-to-five migration scenario ---
def test_full_rc3_six_to_five_migration():
    """Simulates an RC3 install with all six RC3 groups. After migration:
    input-shaper removed, calibration/extruder/recovery updated to final,
    camera/maintenance unchanged, all five final groups present."""
    def body(marker_path):
        existing = {}
        for gid, gdef in seed.RC3_GROUPS.items():
            existing[group_key(gid)] = gdef
        existing[seed.MODE_KEY] = "expert"

        moon = FakeMoonrakerDb(existing=existing)
        rc, logs = run_seed(marker_path, moon,
                            groups=seed.DEFAULT_GROUPS,
                            rc3_groups=seed.RC3_GROUPS)
        check("full rc3 migration: rc==0", rc == 0)
        check("full rc3 migration: input-shaper removed",
              group_key("nebulaos-input-shaper") not in moon.store)
        check("full rc3 migration: all five final groups present",
              all(group_key(gid) in moon.store for gid in seed.DEFAULT_GROUPS))
        check("full rc3 migration: calibration matches final",
              moon.store[group_key("nebulaos-calibration")] == seed.DEFAULT_GROUPS["nebulaos-calibration"])
        check("full rc3 migration: extruder matches final",
              moon.store[group_key("nebulaos-extruder")] == seed.DEFAULT_GROUPS["nebulaos-extruder"])
        check("full rc3 migration: recovery matches final",
              moon.store[group_key("nebulaos-recovery")] == seed.DEFAULT_GROUPS["nebulaos-recovery"])
        check("full rc3 migration: mode still expert",
              moon.store[seed.MODE_KEY] == "expert")
        with open(marker_path) as f:
            marker = json.load(f)
        check("full rc3 migration: schema_version present",
              marker.get("schema_version") == seed.SCHEMA_VERSION)

    with_marker_dir(body)


# --- Test 32: schema_version is in marker on fresh install ---
def test_schema_version_in_marker():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={})
        rc, logs = run_seed(marker_path, moon)
        with open(marker_path) as f:
            marker = json.load(f)
        check("schema version: present in marker",
              marker.get("schema_version") == seed.SCHEMA_VERSION)
        check("schema version: is integer 2",
              marker.get("schema_version") == 2)

    with_marker_dir(body)


# --- Test 33: RC3_GROUPS has exactly 6 groups ---
def test_rc3_groups_has_six_groups():
    check("RC3_GROUPS count is exactly 6",
          len(seed.RC3_GROUPS) == 6,
          f"got {len(seed.RC3_GROUPS)}: {list(seed.RC3_GROUPS.keys())}")
    expected_ids = {"nebulaos-calibration", "nebulaos-input-shaper", "nebulaos-extruder",
                    "nebulaos-recovery", "nebulaos-maintenance", "nebulaos-camera"}
    check("RC3_GROUPS IDs match historical RC3",
          set(seed.RC3_GROUPS.keys()) == expected_ids)


# --- Test 34: RC3 calibration has 7 macros, final has 9 ---
def test_rc3_vs_final_calibration_macro_counts():
    rc3_cal = seed.RC3_GROUPS["nebulaos-calibration"]
    final_cal = seed.DEFAULT_GROUPS["nebulaos-calibration"]
    check("RC3 calibration has 7 macros", len(rc3_cal["macros"]) == 7)
    check("final calibration has 9 macros", len(final_cal["macros"]) == 11)
    rc3_names = {m["name"] for m in rc3_cal["macros"]}
    final_names = {m["name"] for m in final_cal["macros"]}
    check("INPUT_SHAPER_CALIBRATE added in final",
          "NEBULAOS_INPUT_SHAPER_CALIBRATE" in final_names - rc3_names)


# --- Test 35: RC3 extruder has 7 macros, final has 4 ---
def test_rc3_vs_final_extruder_macro_counts():
    rc3_ext = seed.RC3_GROUPS["nebulaos-extruder"]
    final_ext = seed.DEFAULT_GROUPS["nebulaos-extruder"]
    check("RC3 extruder has 7 macros", len(rc3_ext["macros"]) == 7)
    check("final extruder has 4 macros", len(final_ext["macros"]) == 4)
    removed = {m["name"] for m in rc3_ext["macros"]} - {m["name"] for m in final_ext["macros"]}
    check("PURGE_MORE removed in final", "PURGE_MORE" in removed)
    check("RESUME_FILAMENT_CHANGE removed in final", "RESUME_FILAMENT_CHANGE" in removed)
    check("CANCEL_FILAMENT_CHANGE removed in final", "CANCEL_FILAMENT_CHANGE" in removed)


# --- reset_to_defaults() tests (Phase 2 final live convergence mission,
#     2026-09-09): the explicit, user-invoked counterpart to run() above.
#     run() never overwrites; reset_to_defaults() always overwrites the
#     five canonical groups and mode_key, and nothing else. ------------

def run_reset(moon, groups=None, obsolete_ids=None):
    logs = []
    result = seed.reset_to_defaults(
        get_status=moon.get_status,
        post=moon.post,
        delete=moon.delete,
        log=logs.append,
        groups=groups if groups is not None else seed.DEFAULT_GROUPS,
        obsolete_ids=obsolete_ids if obsolete_ids is not None else set(),
    )
    return result, logs


def test_reset_six_group_custom_state_produces_exact_five():
    custom_six = {
        group_key("nebulaos-calibration"): {"name": "My Calibration", "macros": [{"pos": 0, "name": "SOMETHING_CUSTOM"}]},
        group_key("nebulaos-extruder"): {"name": "Extruder", "macros": []},
        group_key("nebulaos-input-shaper"): {"name": "Input Shaper", "macros": [{"pos": 0, "name": "NEBULAOS_INPUT_SHAPER_CALIBRATE"}]},
        group_key("nebulaos-recovery"): {"name": "Recovery", "macros": []},
        group_key("nebulaos-maintenance"): {"name": "Maintenance", "macros": []},
        group_key("nebulaos-camera"): {"name": "Camera reordered", "macros": []},
        "macros.mode": "simple",
    }
    moon = FakeMoonrakerDb(existing=custom_six)
    result, logs = run_reset(moon, obsolete_ids={"nebulaos-input-shaper"})

    remaining_group_keys = [k for k in moon.store if k.startswith("macros.macrogroups.")]
    check("reset: exactly five groups remain after resetting a customized six-group state",
          sorted(remaining_group_keys) == sorted(group_key(g) for g in seed.DEFAULT_GROUPS),
          f"got {sorted(remaining_group_keys)}")
    check("reset: standalone Input Shaper group is gone",
          group_key("nebulaos-input-shaper") not in moon.store)
    check("reset: reports success for all five canonical groups",
          all(v == "reset" for v in result["groups"].values()), result["groups"])


def test_reset_produces_exact_canonical_contents():
    moon = FakeMoonrakerDb(existing={
        group_key("nebulaos-calibration"): {"name": "custom", "macros": []},
    })
    result, logs = run_reset(moon)
    for group_id, definition in seed.DEFAULT_GROUPS.items():
        check(f"reset: {group_id!r} content matches canonical definition exactly",
              moon.store[group_key(group_id)] == definition)


def test_reset_produces_exact_visibility_metadata():
    moon = FakeMoonrakerDb()
    run_reset(moon)
    calib = moon.store[group_key("nebulaos-calibration")]
    check("reset: Calibration group visibility (standby only)",
          (calib["showInStandby"], calib["showInPrinting"], calib["showInPause"]) == (True, False, False))
    extruder = moon.store[group_key("nebulaos-extruder")]
    check("reset: Extruder group visibility (standby + printing)",
          (extruder["showInStandby"], extruder["showInPrinting"], extruder["showInPause"]) == (True, True, False))
    recovery = moon.store[group_key("nebulaos-recovery")]
    check("reset: Recovery group visibility (standby only)",
          (recovery["showInStandby"], recovery["showInPrinting"], recovery["showInPause"]) == (True, False, False))
    for gid in ("nebulaos-maintenance", "nebulaos-camera"):
        g = moon.store[group_key(gid)]
        check(f"reset: {gid!r} visibility (all states)",
              (g["showInStandby"], g["showInPrinting"], g["showInPause"]) == (True, True, True))
    m600 = next(m for m in extruder["macros"] if m["name"] == "M600")
    check("reset: M600 individual visibility (printing only)",
          (m600["showInStandby"], m600["showInPrinting"], m600["showInPause"]) == (False, True, False))
    esteps = next(m for m in extruder["macros"] if m["name"] == "NEBULAOS_ESTEPS_CALIBRATE")
    check("reset: E-Steps individual visibility (standby only)",
          (esteps["showInStandby"], esteps["showInPrinting"], esteps["showInPause"]) == (True, False, False))


def test_reset_restores_expert_mode_default():
    moon = FakeMoonrakerDb(existing={"macros.mode": "simple"})
    result, logs = run_reset(moon)
    check("reset: macros.mode reset to expert", moon.store.get("macros.mode") == "expert")
    check("reset: mode result reported as 'reset'", result["mode"] == "reset")


def test_reset_from_hidden_reordered_state_produces_exact_default():
    reordered = {
        group_key("nebulaos-camera"): {"name": "Camera", "color": "primary", "macros": [
            {"pos": 2, "name": "SET_CAMERA_QUALITY_HIGH", "color": "", "showInStandby": True, "showInPrinting": True, "showInPause": True},
        ], "showInStandby": False, "showInPrinting": True, "showInPause": True},  # hidden in standby by user
    }
    moon = FakeMoonrakerDb(existing=reordered)
    run_reset(moon)
    check("reset: hidden/reordered Camera group restored to exact canonical default",
          moon.store[group_key("nebulaos-camera")] == seed.DEFAULT_GROUPS["nebulaos-camera"])


def test_reset_is_idempotent():
    moon = FakeMoonrakerDb()
    result1, _ = run_reset(moon)
    snapshot1 = dict(moon.store)
    result2, _ = run_reset(moon)
    check("reset: repeated invocation produces identical final state",
          moon.store == snapshot1)
    check("reset: repeated invocation reports success both times",
          all(v == "reset" for v in result1["groups"].values()) and
          all(v == "reset" for v in result2["groups"].values()))


def test_reset_transport_failure_on_one_group_is_reported_failed():
    moon = FakeMoonrakerDb()
    real_post = moon.post
    def flaky_post(path, payload):
        if "nebulaos-extruder" in payload.get("key", ""):
            raise ConnectionError("simulated transport failure")
        return real_post(path, payload)
    logs = []
    result = seed.reset_to_defaults(
        get_status=moon.get_status, post=flaky_post, delete=moon.delete,
        log=logs.append, groups=seed.DEFAULT_GROUPS, obsolete_ids=set(),
    )
    check("reset: the failing group is reported failed",
          result["groups"]["nebulaos-extruder"] == "failed")
    check("reset: other groups still succeed despite one failure",
          result["groups"]["nebulaos-calibration"] == "reset")
    check("reset: a failed group is deleted but not left with stale content",
          group_key("nebulaos-extruder") not in moon.store)


def test_reset_never_touches_unrelated_namespace_keys():
    moon = FakeMoonrakerDb(existing={
        "dashboard": {"nonExpandPanels": []},
        "view": {"configfiles": {"showHiddenFiles": False}},
        "gcodeViewer": {"someSetting": True},
        "initVersion": "2.18.2",
    })
    run_reset(moon)
    for key in ("dashboard", "view", "gcodeViewer", "initVersion"):
        check(f"reset: unrelated mainsail-namespace key {key!r} is untouched",
              moon.store.get(key) == {"dashboard": {"nonExpandPanels": []},
                                       "view": {"configfiles": {"showHiddenFiles": False}},
                                       "gcodeViewer": {"someSetting": True},
                                       "initVersion": "2.18.2"}[key])


def test_reset_never_touches_a_users_own_extra_group():
    moon = FakeMoonrakerDb(existing={
        group_key("my-own-shortcuts"): {"name": "My Shortcuts", "macros": []},
    })
    run_reset(moon)
    check("reset: a user's own non-NebulaOS group id survives untouched",
          moon.store.get(group_key("my-own-shortcuts")) == {"name": "My Shortcuts", "macros": []})


def test_run_reset_cli_entry_point_matches_reset_to_defaults():
    """Phase 2 final live convergence mission (2026-09-09): every test
    above calls this file's own local run_reset() helper, which invokes
    seed.reset_to_defaults() directly with keyword arguments - it never
    exercises the real seed.run_reset() CLI entry point (the one
    `nebulaos-seed-mainsail-macros --reset` / `__main__` actually calls).
    A real device found live: seed.run_reset() called
    reset_to_defaults(get_status, post, delete, log, groups, mode_key,
    default_mode) POSITIONALLY, but reset_to_defaults()'s real parameter
    order is (..., groups, obsolete_ids, mode_key, default_mode) - this
    silently passed mode_key ("macros.mode") into the obsolete_ids slot
    (iterated character-by-character: 'm','a','c','r','o','s','.', ...,
    each treated as a real obsolete group id to delete) and default_mode
    ("expert") into the mode_key slot (silently writing/checking a
    bogus top-level "expert" key instead of the real "macros.mode" key -
    the real mode key was never touched at all). The five canonical
    groups themselves still got reset correctly (groups was the 5th
    positional arg in both signatures, so it landed right by accident) -
    only obsolete-id cleanup and the mode key were affected, which is
    exactly why the local reset_to_defaults()-only tests above never
    caught it: none of them call through run_reset() itself."""
    moon = FakeMoonrakerDb(existing={
        group_key("nebulaos-calibration"): {"name": "old", "macros": []},
        group_key("nebulaos-extruder"): {"name": "old", "macros": []},
        group_key("nebulaos-recovery"): {"name": "old", "macros": []},
        group_key("nebulaos-maintenance"): {"name": "old", "macros": []},
        group_key("nebulaos-camera"): {"name": "old", "macros": []},
        group_key("nebulaos-input-shaper"): {"name": "Input Shaper", "macros": []},
        "macros.mode": "simple",
    })
    logs = []
    rc = seed.run_reset(
        get_status=moon.get_status,
        post=moon.post,
        delete=moon.delete,
        log=logs.append,
        retry_attempts=1,
        retry_delay=0,
        sleep=lambda _s: None,
    )
    check("run_reset(): returns 0 on success", rc == 0, f"logs={logs}")
    check("run_reset(): the real obsolete Input Shaper group is deleted",
          group_key("nebulaos-input-shaper") not in moon.store, sorted(moon.store))
    check("run_reset(): exactly the five canonical group keys remain",
          sorted(k for k in moon.store if k.startswith("macros.macrogroups.")) ==
          sorted(group_key(g) for g in seed.DEFAULT_GROUPS),
          sorted(moon.store))
    check("run_reset(): the real macros.mode key is reset to 'expert'",
          moon.store.get("macros.mode") == "expert", moon.store.get("macros.mode"))
    check("run_reset(): no stray single-character keys were created (the exact live bug)",
          not any(len(k) == 1 for k in moon.store),
          sorted(moon.store))
    check("run_reset(): no stray 'expert' key was created outside macros.mode",
          "expert" not in moon.store, sorted(moon.store))


def test_reset_then_normal_seed_run_does_not_reset_again():
    """After a reset, run() (normal boot-time seeding) must treat the
    freshly-reset canonical groups as already-present and leave them
    alone - proving reset-state and ordinary seeding compose correctly
    and a later boot never silently re-resets a user's post-reset edit."""
    moon = FakeMoonrakerDb()
    run_reset(moon)
    moon.store[group_key("nebulaos-camera")]["name"] = "User renamed this after reset"
    with_marker_dir(lambda marker: run_seed(marker, moon, groups=seed.DEFAULT_GROUPS))
    check("reset: a user edit made after reset survives a normal seed run",
          moon.store[group_key("nebulaos-camera")]["name"] == "User renamed this after reset")


def run_seed(marker_path, moon, groups=None, legacy_map=None,
             rc3_groups=None, retry_attempts=3, retry_delay=0):
    logs = []
    rc = seed.run(
        get_status=moon.get_status,
        post=moon.post,
        delete=moon.delete,
        marker_path=marker_path,
        log=logs.append,
        groups=groups if groups is not None else TWO_GROUPS,
        legacy_map=legacy_map if legacy_map is not None else {},
        rc3_groups=rc3_groups if rc3_groups is not None else {},
        retry_attempts=retry_attempts,
        retry_delay=retry_delay,
        sleep=lambda _s: None,
    )
    return rc, logs


class NestedFakeDb:
    """Moonraker's real shape: dotted keys address a nested namespace; a GET
    without a key returns the whole namespace (404 when it does not exist).
    Counts every 404 it answers - each is a warning in Moonraker's log."""

    def __init__(self, data=None):
        self.data = data
        self.not_found = 0

    def _walk(self, key, create=False):
        node = self.data
        parts = key.split(".")
        for part in parts[:-1]:
            if create:
                node = node.setdefault(part, {})
            elif not isinstance(node, dict) or part not in node:
                return None, parts[-1]
            else:
                node = node[part]
        return node, parts[-1]

    def get_status(self, path):
        if path == "/server/database/list":
            return 200, json.dumps({"result": {"namespaces": ["mainsail"] if self.data is not None else []}})
        if path == "/server/database/item?namespace=mainsail":
            if self.data is None:
                self.not_found += 1
                return 404, None
            return 200, json.dumps({"result": {"namespace": "mainsail", "value": self.data}})
        key = path.split("key=", 1)[1]
        node, last = self._walk(key) if self.data is not None else (None, None)
        if not isinstance(node, dict) or last not in node:
            self.not_found += 1
            return 404, None
        return 200, json.dumps({"result": {"namespace": "mainsail", "key": key, "value": node[last]}})

    def post(self, path, payload):
        if self.data is None:
            self.data = {}
        node, last = self._walk(payload["key"], create=True)
        node[last] = payload["value"]
        return json.dumps({"result": {"value": payload["value"]}})

    def delete(self, path):
        key = path.split("key=", 1)[1]
        node, last = self._walk(key) if self.data is not None else (None, None)
        if not isinstance(node, dict) or last not in node:
            self.not_found += 1
            return 404, None
        node.pop(last)
        return 200, json.dumps({"result": {}})


def test_snapshot_transport_makes_no_404s():
    # G16 (2026-10-15): a fresh install and a legacy migration through the
    # snapshot transport give the same database, with no 404 at Moonraker.
    for start in (None, {"macros": {"macrogroups": {"group_a": {"name": "mine"}}}}):
        results = []
        for snapshot in (False, True):
            db = NestedFakeDb(json.loads(json.dumps(start)) if start is not None else None)
            t = seed.NamespaceSnapshot(db.get_status, db.post, db.delete) if snapshot else db
            d = tempfile.mkdtemp(prefix="mainsail-macros-snap-")
            try:
                rc = seed.run(get_status=t.get_status, post=t.post, delete=t.delete,
                              marker_path=os.path.join(d, "m.json"), log=lambda m: None,
                              groups=TWO_GROUPS, legacy_map={"old_x": "group_b"}, rc3_groups={},
                              retry_attempts=1, retry_delay=0, sleep=lambda s: None)
            finally:
                shutil.rmtree(d, ignore_errors=True)
            results.append((rc, json.dumps(db.data, sort_keys=True), db.not_found))
        label = "fresh" if start is None else "existing"
        check("snapshot (%s): same outcome as per-key requests" % label,
              results[0][:2] == results[1][:2], "%s vs %s" % (results[0][:2], results[1][:2]))
        check("snapshot (%s): per-key requests did make 404s (the noise)" % label, results[0][2] > 0)
        check("snapshot (%s): no 404 at Moonraker" % label, results[1][2] == 0, str(results[1][2]))
    check("entry point wires the snapshot transport",
          "NamespaceSnapshot(real_http_get_status" in open(MODULE_PATH).read())



# --- G83a: the load cell button reaches installs with the previous default ---
def test_g83a_previous_calibration_group_gets_load_cell_button():
    def body(marker_path):
        prev = seed.PRE_G83A_GROUPS["nebulaos-calibration"]
        final_cal = seed.DEFAULT_GROUPS["nebulaos-calibration"]
        moon = FakeMoonrakerDb(existing={group_key("nebulaos-calibration"): prev})
        rc, logs = run_seed(marker_path, moon, groups=seed.DEFAULT_GROUPS)
        check("g83a: rc==0", rc == 0)
        check("g83a: previous default upgraded to the new default",
              moon.store[group_key("nebulaos-calibration")] == final_cal)
        check("g83a: new default has the load cell button",
              any(m["name"] == "NEBULAOS_LOAD_CELL_CALIBRATE"
                  for m in final_cal["macros"]))
    with_marker_dir(body)


def test_g83a_user_modified_calibration_group_untouched():
    def body(marker_path):
        custom = json.loads(json.dumps(seed.PRE_G83A_GROUPS["nebulaos-calibration"]))
        custom["name"] = "My calibration"
        moon = FakeMoonrakerDb(existing={group_key("nebulaos-calibration"): custom})
        rc, logs = run_seed(marker_path, moon, groups=seed.DEFAULT_GROUPS)
        check("g83a user-modified: rc==0", rc == 0)
        check("g83a user-modified: left untouched",
              moon.store[group_key("nebulaos-calibration")] == custom)
    with_marker_dir(body)

# --- G87: the bed tramming button reaches installs with the G83a default ---
def test_g87_previous_calibration_group_gets_bed_tram_button():
    def body(marker_path):
        prev = seed.PRE_G87_GROUPS["nebulaos-calibration"]
        final_cal = seed.DEFAULT_GROUPS["nebulaos-calibration"]
        moon = FakeMoonrakerDb(existing={group_key("nebulaos-calibration"): prev})
        rc, logs = run_seed(marker_path, moon, groups=seed.DEFAULT_GROUPS)
        check("g87: rc==0", rc == 0)
        check("g87: G83a default upgraded to the new default",
              moon.store[group_key("nebulaos-calibration")] == final_cal)
        check("g87: new default has the bed tramming button",
              any(m["name"] == "NEBULAOS_BED_TRAM" for m in final_cal["macros"]))
    with_marker_dir(body)


def test_g87_pre_g83a_group_goes_straight_to_the_newest_default():
    def body(marker_path):
        prev = seed.PRE_G83A_GROUPS["nebulaos-calibration"]
        moon = FakeMoonrakerDb(existing={group_key("nebulaos-calibration"): prev})
        rc, logs = run_seed(marker_path, moon, groups=seed.DEFAULT_GROUPS)
        check("g87 from pre-g83a: rc==0", rc == 0)
        check("g87 from pre-g83a: newest default",
              moon.store[group_key("nebulaos-calibration")]
              == seed.DEFAULT_GROUPS["nebulaos-calibration"])
    with_marker_dir(body)


def test_g87_user_modified_calibration_group_untouched():
    def body(marker_path):
        custom = json.loads(json.dumps(seed.PRE_G87_GROUPS["nebulaos-calibration"]))
        custom["name"] = "My calibration"
        moon = FakeMoonrakerDb(existing={group_key("nebulaos-calibration"): custom})
        rc, logs = run_seed(marker_path, moon, groups=seed.DEFAULT_GROUPS)
        check("g87 user-modified: rc==0", rc == 0)
        check("g87 user-modified: left untouched",
              moon.store[group_key("nebulaos-calibration")] == custom)
    with_marker_dir(body)

# --- Run 21: AXIS_TWIST_Y leaves installs with the G87 default -------------
def test_run21_previous_calibration_group_loses_axis_twist_y():
    def body(marker_path):
        prev = seed.PRE_RUN21_GROUPS["nebulaos-calibration"]
        final_cal = seed.DEFAULT_GROUPS["nebulaos-calibration"]
        moon = FakeMoonrakerDb(existing={group_key("nebulaos-calibration"): prev})
        rc, logs = run_seed(marker_path, moon, groups=seed.DEFAULT_GROUPS)
        check("run21: rc==0", rc == 0)
        check("run21: G87 default upgraded to the new default",
              moon.store[group_key("nebulaos-calibration")] == final_cal)
        names = [m["name"] for m in final_cal["macros"]]
        check("run21: no AXIS_TWIST_Y, AXIS_TWIST_X kept",
              "AXIS_TWIST_Y" not in names and "AXIS_TWIST_X" in names)
        check("run21: positions 0..n-1",
              [m["pos"] for m in final_cal["macros"]] == list(range(len(names))))
    with_marker_dir(body)


def test_run21_user_modified_calibration_group_untouched():
    def body(marker_path):
        custom = json.loads(json.dumps(seed.PRE_RUN21_GROUPS["nebulaos-calibration"]))
        custom["name"] = "My calibration"
        moon = FakeMoonrakerDb(existing={group_key("nebulaos-calibration"): custom})
        rc, logs = run_seed(marker_path, moon, groups=seed.DEFAULT_GROUPS)
        check("run21 user-modified: left untouched",
              moon.store[group_key("nebulaos-calibration")] == custom)
    with_marker_dir(body)

# --- G101: the load cell mode buttons reach installs with the Run 21 default --
def test_g101_previous_calibration_group_gets_load_cell_mode_buttons():
    def body(marker_path):
        prev = seed.PRE_G101_GROUPS["nebulaos-calibration"]
        final_cal = seed.DEFAULT_GROUPS["nebulaos-calibration"]
        moon = FakeMoonrakerDb(existing={group_key("nebulaos-calibration"): prev})
        rc, logs = run_seed(marker_path, moon, groups=seed.DEFAULT_GROUPS)
        check("g101: rc==0", rc == 0)
        check("g101: Run 21 default upgraded to the new default",
              moon.store[group_key("nebulaos-calibration")] == final_cal)
        names = [m["name"] for m in final_cal["macros"]]
        check("g101: both mode buttons, after the load cell calibration",
              names.index("LOAD_CELL_AUTOMATIC") == names.index("NEBULAOS_LOAD_CELL_CALIBRATE") + 1
              and names.index("LOAD_CELL_MANUAL") == names.index("LOAD_CELL_AUTOMATIC") + 1)
    with_marker_dir(body)


def test_g101_older_defaults_go_straight_to_the_newest():
    def body(marker_path):
        for fixture in (seed.PRE_RUN21_GROUPS, seed.PRE_G87_GROUPS):
            moon = FakeMoonrakerDb(existing={group_key("nebulaos-calibration"):
                                             fixture["nebulaos-calibration"]})
            rc, logs = run_seed(marker_path, moon, groups=seed.DEFAULT_GROUPS)
            check("g101 from an older default: newest",
                  moon.store[group_key("nebulaos-calibration")]
                  == seed.DEFAULT_GROUPS["nebulaos-calibration"])
    with_marker_dir(body)


def test_g101_user_modified_calibration_group_untouched():
    def body(marker_path):
        custom = json.loads(json.dumps(seed.PRE_G101_GROUPS["nebulaos-calibration"]))
        custom["name"] = "My calibration"
        moon = FakeMoonrakerDb(existing={group_key("nebulaos-calibration"): custom})
        rc, logs = run_seed(marker_path, moon, groups=seed.DEFAULT_GROUPS)
        check("g101 user-modified: left untouched",
              moon.store[group_key("nebulaos-calibration")] == custom)
    with_marker_dir(body)


# --- Run 23: the Nebula Camera macros reach installs with the old Camera group --
def test_nebula_camera_macros_reach_the_default_camera_group():
    def body(marker_path):
        prev = seed.PRE_NEBULA_CAMERA_GROUPS["nebulaos-camera"]
        final = seed.DEFAULT_GROUPS["nebulaos-camera"]
        moon = FakeMoonrakerDb(existing={group_key("nebulaos-camera"): prev})
        rc, logs = run_seed(marker_path, moon, groups=seed.DEFAULT_GROUPS)
        check("nebula camera: rc==0", rc == 0)
        check("nebula camera: old default upgraded",
              moon.store[group_key("nebulaos-camera")] == final)
        names = [m["name"] for m in final["macros"]]
        check("nebula camera: quality presets first, then the four Nebula Camera macros",
              names[:3] == ["SET_CAMERA_QUALITY_LOW", "SET_CAMERA_QUALITY_MED",
                            "SET_CAMERA_QUALITY_HIGH"]
              and names[3:] == ["NEBULA_CAMERA_NIGHT_MODE", "NEBULA_CAMERA_ANTI_FLICKER",
                                "NEBULA_CAMERA_RESTART", "NEBULA_CAMERA_DEFAULTS"])
        custom = json.loads(json.dumps(prev))
        custom["name"] = "My camera"
        moon = FakeMoonrakerDb(existing={group_key("nebulaos-camera"): custom})
        run_seed(marker_path, moon, groups=seed.DEFAULT_GROUPS)
        check("nebula camera: a user-changed group is left untouched",
              moon.store[group_key("nebulaos-camera")] == custom)
    with_marker_dir(body)


def test_nebula_camera_macros_exist_in_camera_cfg():
    cfg = open(os.path.join(os.path.dirname(MODULE_PATH), "..", "..", "etc", "nebulaos",
                            "klipper", "camera.cfg")).read()
    for name in ("NEBULA_CAMERA_NIGHT_MODE", "NEBULA_CAMERA_ANTI_FLICKER",
                 "NEBULA_CAMERA_RESTART", "NEBULA_CAMERA_DEFAULTS"):
        check("camera.cfg defines %s" % name, "[gcode_macro %s]" % name in cfg)
    check("camera.cfg: nebula_camera runs the helper",
          "command: /usr/libexec/nebulaos-nebula-camera" in cfg)


def test_g101_wrappers_call_the_mode_command():
    cfg = open(os.path.join(os.path.dirname(MODULE_PATH), "..", "..", "etc", "nebulaos",
                            "klipper", "calibration.cfg")).read()
    check("g101: LOAD_CELL_AUTOMATIC -> MODE=auto",
          "[gcode_macro LOAD_CELL_AUTOMATIC]" in cfg and "NEBULAOS_LOAD_CELL_MODE MODE=auto" in cfg)
    check("g101: LOAD_CELL_MANUAL -> MODE=manual",
          "[gcode_macro LOAD_CELL_MANUAL]" in cfg and "NEBULAOS_LOAD_CELL_MODE MODE=manual" in cfg)

def main():
    test_moonraker_unavailable()
    test_fresh_install_creates_both_groups()
    test_existing_group_never_overwritten()
    test_repeated_invocation_is_idempotent()
    test_new_group_added_later_seeds_into_existing_install()
    test_creation_reports_success_but_verification_mismatches()
    test_one_group_transport_error_does_not_block_the_other()
    test_default_groups_are_well_formed()
    test_legacy_group_id_map_is_well_formed()
    test_migration_noop_on_fresh_install()
    test_migration_renames_legacy_group_preserving_user_edits()
    test_migration_is_idempotent_across_two_runs()
    test_migration_finishes_an_interrupted_prior_run()
    test_migration_leaves_a_genuine_collision_untouched()
    test_mode_default_never_overwrites_existing_value()
    test_mode_default_transport_failure_does_not_block_groups()
    test_final_product_has_exactly_five_groups()
    test_input_shaper_in_calibration_group()
    test_no_workflow_helpers_in_dashboard()
    test_group_visibility_flags()
    test_m600_macro_visibility()
    test_rc3_input_shaper_exact_match_removed()
    test_rc3_input_shaper_user_modified_left_untouched()
    test_rc3_input_shaper_not_present()
    test_rc3_calibration_migrated_to_final()
    test_rc3_extruder_migrated_to_final()
    test_rc3_recovery_migrated_to_final()
    test_rc3_user_modified_calibration_left_alone()
    test_rc3_already_final_is_recognized()
    test_rc3_unchanged_groups_skipped()
    test_full_rc3_six_to_five_migration()
    test_schema_version_in_marker()
    test_rc3_groups_has_six_groups()
    test_rc3_vs_final_calibration_macro_counts()
    test_g83a_previous_calibration_group_gets_load_cell_button()
    test_g83a_user_modified_calibration_group_untouched()
    test_g87_previous_calibration_group_gets_bed_tram_button()
    test_g87_pre_g83a_group_goes_straight_to_the_newest_default()
    test_g87_user_modified_calibration_group_untouched()
    test_run21_previous_calibration_group_loses_axis_twist_y()
    test_run21_user_modified_calibration_group_untouched()
    test_g101_previous_calibration_group_gets_load_cell_mode_buttons()
    test_g101_older_defaults_go_straight_to_the_newest()
    test_g101_user_modified_calibration_group_untouched()
    test_g101_wrappers_call_the_mode_command()
    test_nebula_camera_macros_reach_the_default_camera_group()
    test_nebula_camera_macros_exist_in_camera_cfg()
    test_rc3_vs_final_extruder_macro_counts()

    test_reset_six_group_custom_state_produces_exact_five()
    test_reset_produces_exact_canonical_contents()
    test_reset_produces_exact_visibility_metadata()
    test_reset_restores_expert_mode_default()
    test_reset_from_hidden_reordered_state_produces_exact_default()
    test_reset_is_idempotent()
    test_reset_transport_failure_on_one_group_is_reported_failed()
    test_reset_never_touches_unrelated_namespace_keys()
    test_reset_never_touches_a_users_own_extra_group()
    test_run_reset_cli_entry_point_matches_reset_to_defaults()
    test_reset_then_normal_seed_run_does_not_reset_again()
    test_snapshot_transport_makes_no_404s()

    print()
    print(f"=== {PASS} passed, {FAIL} failed ===")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
