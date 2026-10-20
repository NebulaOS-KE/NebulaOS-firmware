#!/usr/bin/env python3
"""Static, fast, offline verification of the "pristine mainline Klipper"
invariant (Phase 2 calibration-framework mission, Axis Twist slice).

nebulaos-klipper-compose.sh's own compose_verify()/compose_verify_pristine()
already enforce this at REAL composition time (a regular-file collision
aborts the build; git status --porcelain must be empty on both checkouts
after composition) - see that script's own header comment and
tests/klipper-composition-tests.sh's "collision guard" section for the
mechanism-level proof, exercised there against synthetic fixtures.

This script is the missing REAL-DATA check the mission's "hard project
invariant" section asks for explicitly: does this repo's actual extras
manifest, as committed right now, collide with the ACTUAL current pinned
upstream Klipper's ACTUAL file list? Runs in milliseconds, no build
container needed, so it can run on every commit rather than only at build
time.

Also asserts the three filenames the mission calls out by name
(axis_twist_compensation.py, probe.py, manual_probe.py) are genuinely
absent from NebulaOS-klipper-extensions - the direct, named check requested
- not merely "presumed covered" by the general collision scan.

Usage: python3 tests/klipper-extras-collision-tests.py
(Locates the pinned Klipper checkout the same way
klipper-config-load-smoke-tests.py does: KLIPPER_SRC env var, then
vendor/klipper, then the workspace's _scratch/ref-klipper-mainline.
Locates the extensions checkout the same way: KLIPPER_EXTENSIONS_SRC env
var, then vendor/nebulaos-klipper-extensions, then the workspace's
NebulaOS-klipper-extensions, then this session's own worktree.)
"""
import json
import os
import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKSPACE = REPO_ROOT.parent.parent.parent
MANIFEST = REPO_ROOT / "manifests/dependencies.conf"

PASS = FAIL = SKIP = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"PASS: {msg}")


def bad(msg):
    global FAIL
    FAIL += 1
    print(f"FAIL: {msg}")


def skip(msg):
    global SKIP
    SKIP += 1
    print(f"SKIP: {msg}")


def check(cond, good_msg, bad_msg):
    ok(good_msg) if cond else bad(bad_msg)


def manifest_value(key):
    for line in MANIFEST.read_text().splitlines():
        line = line.strip()
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip()
    return None


def find_source(env_name, candidates, marker):
    env = os.environ.get(env_name)
    paths = [pathlib.Path(env)] if env else []
    paths += candidates
    for c in paths:
        if (c / marker).exists():
            return c
    return None


# Explicitly named by the mission - checked by exact name, not only via the
# general collision scan below, so a reader can see these three were
# individually considered.
NAMED_FORBIDDEN_FILENAMES = (
    "axis_twist_compensation.py",
    "probe.py",
    "manual_probe.py",
)


def main():
    klipper_pin = manifest_value("KLIPPER_PIN")
    check(bool(klipper_pin), f"read KLIPPER_PIN from dependencies.conf: {klipper_pin}",
          "could not read KLIPPER_PIN from manifests/dependencies.conf")
    if not klipper_pin:
        report()
        return

    klipper_src = find_source("KLIPPER_SRC",
                              [REPO_ROOT / "vendor/klipper",
                               WORKSPACE / "_scratch/ref-klipper-mainline"],
                              "klippy/klippy.py")
    ext_src = find_source("KLIPPER_EXTENSIONS_SRC",
                          [REPO_ROOT / "vendor/nebulaos-klipper-extensions",
                           WORKSPACE / "NebulaOS-klipper-extensions",
                           WORKSPACE / "_worktrees/NebulaOS-klipper-extensions"
                                       "/phase2-calibration-framework"],
                          "nebulaos-extensions.json")
    if klipper_src is None or ext_src is None:
        skip("no Klipper and/or extensions checkout found - set KLIPPER_SRC "
             "and KLIPPER_EXTENSIONS_SRC")
        report()
        return
    ok(f"located Klipper source at {klipper_src}")
    ok(f"located extensions source at {ext_src}")

    # Pin freshness: this check is only meaningful against the EXACT pinned
    # commit, not "whatever happens to be checked out" - refuse to draw a
    # false-negative conclusion from a stale/unrelated checkout.
    import subprocess
    actual_commit = subprocess.run(
        ["git", "-C", str(klipper_src), "rev-parse", "HEAD"],
        stdout=subprocess.PIPE, text=True).stdout.strip()
    check(actual_commit == klipper_pin,
          f"Klipper checkout is at the pinned commit ({klipper_pin[:12]}...)",
          f"Klipper checkout is at {actual_commit[:12]}..., not the pinned "
          f"{klipper_pin[:12]}... - collision results below are NOT "
          "meaningful against a different commit")
    if actual_commit != klipper_pin:
        report()
        return

    upstream_extras_dir = klipper_src / "klippy" / "extras"
    upstream_names = {p.name for p in upstream_extras_dir.glob("*.py")}
    check(len(upstream_names) > 50,
          f"read {len(upstream_names)} real upstream extras filenames from {upstream_extras_dir}",
          f"suspiciously few upstream extras files found ({len(upstream_names)}) - "
          "wrong directory, or upstream tree is damaged")

    # Run 15 (Run 14 verifier note 1): read the extensions AT THE PIN from
    # git, whatever is checked out - a stale vendor/ checkout used to pass
    # here while testing the wrong module list.
    ext_pin = manifest_value("KLIPPER_EXTENSIONS_PIN")

    def has_pin(src):
        return subprocess.run(
            ["git", "-C", str(src), "cat-file", "-e", f"{ext_pin}^{{commit}}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    have_pin = has_pin(ext_src)
    if not have_pin and not os.environ.get("KLIPPER_EXTENSIONS_SRC"):
        # vendor/ lags the pin between builds: use a workspace checkout
        # that has it rather than testing an old module list
        for cand in (REPO_ROOT.parent / "NebulaOS-klipper-extensions",):
            if (cand / "nebulaos-extensions.json").exists() and has_pin(cand):
                ok(f"vendor checkout lacks the pin - using {cand}")
                ext_src, have_pin = cand, True
                break
    check(have_pin,
          f"extensions source contains KLIPPER_EXTENSIONS_PIN {ext_pin[:12]}...",
          f"extensions source {ext_src} does not contain the pinned commit "
          f"{ext_pin} - fetch it, or set KLIPPER_EXTENSIONS_SRC to a checkout "
          "that has it")
    if not have_pin:
        report()
        return
    manifest = json.loads(subprocess.run(
        ["git", "-C", str(ext_src), "show", f"{ext_pin}:nebulaos-extensions.json"],
        stdout=subprocess.PIPE, text=True, check=True).stdout)
    pinned_extras = set(subprocess.run(
        ["git", "-C", str(ext_src), "ls-tree", "--name-only", ext_pin, "extras/"],
        stdout=subprocess.PIPE, text=True, check=True).stdout.split())
    declared = [m["path"] for m in manifest.get("modules", [])
                if m.get("role") == "runtime"]
    check(len(declared) > 0,
          f"manifest declares {len(declared)} runtime module(s)",
          "manifest declares zero runtime modules")

    declared_names = []
    for p in declared:
        if not p.startswith("extras/"):
            bad(f"manifest module path '{p}' does not live under extras/ - "
                "this script only checked extras/, treat as unverified")
            continue
        declared_names.append(pathlib.Path(p).name)
    ok(f"{len(declared_names)} runtime module basename(s) extracted from the manifest")

    # The real-data collision scan: every declared NebulaOS runtime module,
    # checked by basename against the ACTUAL current pinned upstream file
    # list - the exact check the mission's own rules ask for, run here
    # instead of only at build time.
    collisions = sorted(set(declared_names) & upstream_names)
    check(not collisions,
          f"zero filename collisions between {len(declared_names)} NebulaOS "
          f"runtime modules and {len(upstream_names)} real pinned upstream "
          "extras files",
          f"COLLISION: the following NebulaOS module name(s) collide with "
          f"real upstream Klipper extras filenames at the pinned commit: "
          f"{collisions} - this would shadow or be shadowed by upstream, "
          "and nebulaos-klipper-compose.sh would refuse to compose. Rename "
          "the NebulaOS module(s).")

    # The three names the mission calls out explicitly, by exact name -
    # confirmed absent from the extensions repo's own extras/ directory
    # (not merely "not declared in the manifest", which a stray untracked
    # file could still slip past).
    for name in NAMED_FORBIDDEN_FILENAMES:
        exists_upstream = name in upstream_names
        exists_in_extensions = f"extras/{name}" in pinned_extras
        check(exists_upstream and not exists_in_extensions,
              f"{name}: confirmed real upstream file, confirmed absent from "
              f"NebulaOS-klipper-extensions/extras/ (no shadow module)",
              f"{name}: exists_upstream={exists_upstream} "
              f"exists_in_extensions={exists_in_extensions} - expected "
              "(True, False); this is exactly the collision the mission's "
              "own rules forbid")

    # Pristine-tree check, static half: nothing in the CURRENT extensions
    # repo's tracked source directly edits a file under the pinned Klipper
    # checkout's own directory structure (the dynamic half - actually
    # composing and running `git status --porcelain` on both checkouts -
    # is nebulaos-klipper-compose.sh's own compose_verify_pristine(),
    # already exercised in tests/klipper-composition-tests.sh; this script
    # only adds the static, real-filename-data layer that mechanism-only
    # test cannot provide).
    import subprocess as sp
    dirty = sp.run(["git", "-C", str(klipper_src), "status", "--porcelain"],
                    stdout=sp.PIPE, text=True).stdout.strip()
    check(dirty == "",
          "pinned upstream Klipper checkout is git-pristine (git status --porcelain empty)",
          f"pinned upstream Klipper checkout is NOT pristine:\n{dirty}")

    report()


def report():
    total = PASS + FAIL
    print(f"\nklipper-extras-collision-tests: {PASS} passed, {FAIL} failed, {SKIP} skipped")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
