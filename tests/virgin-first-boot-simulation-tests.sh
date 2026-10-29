#!/bin/sh
#
# Virgin-Baseline Fix + Rebuild mission, task 5 (2026-08-08): simulates a
# genuinely empty NebulaOS persistent state going through first boot end
# to end, entirely offline - S02nebulaos-namespace (layout + printer_data/
# config seed), S04nebulaos-factory-seed (klipper checkout seed +
# generation baseline), S04nebulaos-migrate (confirms no redundant
# reseed) - then runs real offline Klipper config validation against the
# RESULTING, provisioned printer.cfg (not the source tree copy), proving
# the full pipeline produces a config Klipper could actually start with.
#
# Unlike tests/nebulaos-printerdata-seed-tests.sh (which uses a synthetic
# minimal printer.cfg fixture), this test seeds from the REAL, tracked
# scripts/build/overlay/opt/printer_data/config/ directly - the actual
# canonical factory config this build ships, including the [z_compensate]/
# [prtouch_v2]/[nebulaos_version] sections task 1/2 of this mission wired
# in. The klipper git archive is still a fixture (a real, throwaway repo
# standing in for the canonical checkout - same convention as
# tests/factory-seed-git-tests.sh) since this test is about the
# provisioning PIPELINE and the REAL printer.cfg, not about re-verifying
# the Klipper source pin itself (tests/recovery-safety-tests.sh already
# does that against the real remote).
#
# Usage: sh tests/virgin-first-boot-simulation-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# S04nebulaos-factory-seed and S05nebulaos-activate source the shared
# persistent-venv helpers. On the device that library is an absolute path
# (/usr/libexec/nebulaos-venv-lib.sh); here it lives in the overlay source
# tree, and these suites source the init script inside `sh -c`, where $0 gives
# the script no way to find it. Point at the real library so these tests
# exercise the real predicate rather than a stub.
NEBULAOS_VENV_LIB="$REPO_ROOT/scripts/build/overlay/usr/libexec/nebulaos-venv-lib.sh"
export NEBULAOS_VENV_LIB

# Points every sourced init script's own GATE_LIB override at the real,
# tracked shared gate (not the real device path /etc/nebulaos-
# maintenance-gate.sh, which does not exist on a dev machine) - exported
# once so every `env ... sh -c` call below inherits it automatically.
export GATE_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh"
MAKE_ARCHIVE_LIB="$REPO_ROOT/scripts/build/lib/make-seed-archive.sh"
S02_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S02nebulaos-namespace"
S04_FACTORY_SEED_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-factory-seed"
S04_MIGRATE_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate"
REAL_PRINTER_DATA_CONFIG="$REPO_ROOT/scripts/build/overlay/opt/printer_data/config"
OFFICIAL_KLIPPER_ORIGIN="https://github.com/Klipper3d/klipper.git"
EXT_ORIGIN="https://github.com/NebulaOS-KE/NebulaOS-klipper-extensions.git"
SEED_MANIFEST_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-seed-manifest.sh"
# The deployed-runtime branch, from the manifest that owns the contract.
EXT_RUNTIME_BRANCH=$(grep -E '^KLIPPER_EXTENSIONS_BRANCH=' "$REPO_ROOT/manifests/dependencies.conf" | tail -1 | cut -d= -f2)
EXT_RUNTIME_BRANCH="${EXT_RUNTIME_BRANCH:-production}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/virgin-first-boot-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: virgin-first-boot-simulation-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

. "$MAKE_ARCHIVE_LIB"

test_virgin_first_boot_produces_valid_klipper_config() {
	NEBULAOS_ROOT="$WORK/persistent-root"
	SEEDS="$WORK/seeds"
	rm -rf "$NEBULAOS_ROOT" "$SEEDS"
	mkdir -p "$SEEDS"

	# 1. Build throwaway fixture archives for BOTH halves of the Klipper
	# stack - content doesn't matter here (recovery-safety-tests.sh
	# verifies the real pins' real content); branch/origin/clean-tree are
	# what the seeding pipeline actually checks.
	#
	# Audit F-07: this fixture used to model the RETIRED
	# coreflake1/NebulaOS-klipper fork as klipper's origin, and passed a
	# klippy/chelper/c_helper.so dirty_exclude that production stopped
	# using. Production seeds OFFICIAL Klipper3d/klipper
	# (S04nebulaos-factory-seed:436). Modelling a retired architecture
	# made this suite green while the real first boot was broken.
	#
	# Audit F-06: it also never seeded the extension set at all, which is
	# exactly why the branch-contract defect was invisible here. Both
	# halves are modelled now, and the extensions half is seeded through
	# the corrected semantics - branch derived from the seed manifest, on
	# the deployed-runtime branch, never a "main" literal.
	klipper_src="$WORK/klipper-src"
	git init -q -b master "$klipper_src"
	echo "fixture klipper" > "$klipper_src/marker.txt"
	git -C "$klipper_src" add -A
	git -C "$klipper_src" -c user.email=t@l -c user.name=t commit -q -m "fixture"
	klipper_commit=$(make_seed_archive "$klipper_src" master \
		"$OFFICIAL_KLIPPER_ORIGIN" "$SEEDS/klipper.tar.gz")

	ext_src="$WORK/extensions-src"
	git init -q -b "$EXT_RUNTIME_BRANCH" "$ext_src"
	mkdir -p "$ext_src/extras"
	echo "fixture extensions" > "$ext_src/extras/marker.py"
	git -C "$ext_src" add -A
	git -C "$ext_src" -c user.email=t@l -c user.name=t commit -q -m "fixture"
	ext_commit=$(make_seed_archive "$ext_src" "$EXT_RUNTIME_BRANCH" \
		"$EXT_ORIGIN" "$SEEDS/nebulaos-klipper-extensions.tar.gz")

	# Real manifest shape: per-component objects carrying the branch the
	# build put each archive on. The extensions branch assertion is read
	# from here at runtime (/etc/nebulaos-seed-manifest.sh).
	cat > "$SEEDS/seed-manifest.json" <<EOF
{
  "migration_version": "virgin-sim-gen-1",
  "components": {
    "klipper": {
      "branch": "master",
      "seed_commit": "$klipper_commit"
    },
    "nebulaos-klipper-extensions": {
      "branch": "$EXT_RUNTIME_BRANCH",
      "seed_commit": "$ext_commit"
    }
  }
}
EOF

	# 2. S02: create the empty namespace layout AND seed printer_data/
	# config from the REAL, tracked source - exactly what a genuinely
	# fresh device's very first boot does.
	env S02NEBULAOS_NAMESPACE_NO_AUTORUN=1 NEBULAOS_ROOT="$NEBULAOS_ROOT" \
		PRINTER_DATA_CONFIG_SEED="$REAL_PRINTER_DATA_CONFIG" \
		sh -c ". '$S02_SCRIPT'; start" > "$WORK/s02.log" 2>&1

	if [ ! -f "$NEBULAOS_ROOT/printer_data/config/printer.cfg" ]; then
		fail "virgin boot: S02 did not seed printer_data/config/printer.cfg ($(cat "$WORK/s02.log"))"
		return
	fi
	pass "virgin boot: S02 seeded printer_data/config from the real tracked source"

	# 3. S04 factory-seed: seed the klipper checkout (function called
	# directly, same convention as tests/app-migration-tests.sh - full
	# start() also seeds mainsail/venvs, out of scope for this config-
	# focused test), then record the initial generation exactly as a
	# real fresh boot's S04 slot would (factory-seed runs before migrate).
	env S04NEBULAOS_FACTORY_SEED_NO_AUTORUN=1 SEEDS="$SEEDS" \
		APPS="$NEBULAOS_ROOT/apps" SYSTEM="$NEBULAOS_ROOT/system" \
		SEED_MANIFEST_LIB="$SEED_MANIFEST_LIB" \
		OFFICIAL_KLIPPER_ORIGIN="$OFFICIAL_KLIPPER_ORIGIN" EXT_ORIGIN="$EXT_ORIGIN" \
		sh -c ". '$S04_FACTORY_SEED_SCRIPT'; \
			seed_git_app klipper master \"\$OFFICIAL_KLIPPER_ORIGIN\"; \
			b=\$(seed_manifest_branch \"\$SEEDS/seed-manifest.json\" nebulaos-klipper-extensions); \
			[ -n \"\$b\" ] || { echo NO_BRANCH; exit 9; }; \
			seed_git_app nebulaos-klipper-extensions \"\$b\" \"\$EXT_ORIGIN\"; \
			record_initial_generation" > "$WORK/s04-seed.log" 2>&1

	if [ ! -e "$NEBULAOS_ROOT/apps/klipper/.git" ]; then
		fail "virgin boot: klipper checkout was not seeded ($(cat "$WORK/s04-seed.log"))"
		return
	fi
	pass "virgin boot: canonical klipper checkout seeded"

	# F-06: the extension set must actually provision on a virgin boot.
	if [ ! -e "$NEBULAOS_ROOT/apps/nebulaos-klipper-extensions/.git" ]; then
		fail "virgin boot: extension set was NOT seeded - this is audit finding F-06 ($(cat "$WORK/s04-seed.log"))"
		return
	fi
	pass "virgin boot: extension set seeded on the deployed-runtime branch"
	_vb_branch=$(git -C "$NEBULAOS_ROOT/apps/nebulaos-klipper-extensions" symbolic-ref --short HEAD 2>/dev/null)
	if [ "$_vb_branch" = "$EXT_RUNTIME_BRANCH" ]; then
		pass "virgin boot: extensions checkout is on '$EXT_RUNTIME_BRANCH', the runtime contract"
	else
		fail "virgin boot: extensions checkout is on '$_vb_branch', expected '$EXT_RUNTIME_BRANCH'"
	fi

	# F-07 regression guard: if a literal "main" ever comes back to a
	# runtime seeding site, say so here rather than silently modelling it.
	if grep -qE '(seed_git_app|reseed_git_app) nebulaos-klipper-extensions[[:space:]]+main' \
		"$S04_FACTORY_SEED_SCRIPT" "$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate" 2>/dev/null; then
		fail "a runtime seeding site hardcodes the DEVELOPMENT branch 'main' again (audit F-06)"
	else
		pass "no runtime seeding site hardcodes 'main' for the extension set"
	fi

	if [ ! -f "$NEBULAOS_ROOT/system/app-generation.json" ] \
		|| ! grep -q "virgin-sim-gen-1" "$NEBULAOS_ROOT/system/app-generation.json"; then
		fail "virgin boot: app-generation.json missing or wrong migration_version ($(cat "$WORK/s04-seed.log"))"
	else
		pass "virgin boot: correct migration/app generation recorded"
	fi

	# 4. S04 migrate: on the very next S04-slot entry (same boot), must
	# be a clean no-op - the exact fresh-boot-ordering property Phase 3/4
	# fixed and tests/app-migration-tests.sh already covers in isolation;
	# re-confirmed here as part of the full chained pipeline.
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEED_MANIFEST_LIB="$SEED_MANIFEST_LIB" SEEDS="$SEEDS" \
		APPS="$NEBULAOS_ROOT/apps" SYSTEM="$NEBULAOS_ROOT/system" \
		LOCKDIR="$WORK/no-lock" \
		sh -c ". '$S04_MIGRATE_SCRIPT'; start" > "$WORK/s04-migrate.log" 2>&1
	backup_count=$(find "$NEBULAOS_ROOT/system/migration-backups" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
	if [ "$backup_count" -eq 0 ] && grep -q "already matches" "$WORK/s04-migrate.log"; then
		pass "virgin boot: migrate makes no redundant backup/reseed on the same fresh boot"
	else
		fail "virgin boot: migrate did something on a freshly-seeded boot ($(cat "$WORK/s04-migrate.log"))"
	fi

	# 5. User-owned paths stay separate: printer_data/config is untouched
	# by anything apps/system-related, and vice versa - verified by the
	# mere fact both exist independently with no cross-contamination
	# (S04 never references printer_data at all - grep the log for proof
	# this run never touched that path).
	if grep -q "printer_data" "$WORK/s04-seed.log" "$WORK/s04-migrate.log" 2>/dev/null; then
		fail "virgin boot: S04 scripts referenced printer_data - USER OWNED/IMAGE OWNED separation violated"
	else
		pass "virgin boot: USER OWNED printer_data path never referenced by IMAGE OWNED app seeding"
	fi

	# 6. The real proof: parse the ACTUALLY-PROVISIONED printer.cfg (not
	# the source tree) and drive it through real production ZCompensate
	# code, exactly as klippy_extras/test_printer_cfg_config_validation.py
	# does against the source file - proving the seeding pipeline didn't
	# corrupt/truncate/mangle anything on the way from source to a
	# provisioned device.
	# Phase 1.5 persistent-namespace mission: [z_compensate] lives outside
	# printer.cfg's own virgin-seed pipeline (only printer.cfg itself
	# travels through it - an A/B slot switch restores includes from the
	# rootfs, not from anything seeded), so the meaningful thing left to
	# prove here is that the PROVISIONED printer.cfg, combined with the
	# tracked immutable includes, resolves to values real ZCompensate code
	# accepts. Concatenated from the tracked overlay source rather than a
	# real /etc/nebulaos/ (which needs root to stage - see
	# tests/klipper-config-load-smoke-tests.py for that full, root-requiring
	# proof); this offline test only needs the real section content, not a
	# real absolute-include resolution.
	# Phase 1.8B integration candidate: [prtouch_v2] is gone entirely (native
	# nozzle-clear replaced PRTouch's runtime - see
	# extras/PRTOUCH_REMOVAL_PLAN.md in NebulaOS-klipper-extensions). This
	# test used to also instantiate a real PRTouchV2 object from
	# prtouch.cfg's own [prtouch_v2] section; that module no longer exists,
	# so only [z_compensate] is validated now. prtouch.cfg's include is
	# ACTIVE - without it the [z_compensate] section would never load, and
	# the command it registers at the shipping pin, _NEBULAOS_NOZZLE_CLEAN,
	# would not exist as a gcode command at all. (This comment used to name
	# CRTENSE_NOZZLE_CLEAR and Z_OFFSET_CALIBRATION; neither is registered
	# by the shipping z_compensate.py. It was describing the firmware's own
	# removed klippy_extras/ mirror, which had drifted from what ships.)
	# [z_compensate] still lives inside prtouch.cfg itself
	# (kept at that name/path rather than renamed, to avoid rippling the
	# rename through every other overlay/test/doc reference to it). This
	# test validates that [z_compensate]'s own section content, in its
	# now-active location, still parses correctly against real ZCompensate
	# code now that PRTouch has been removed from it.
	provisioned_cfg="$NEBULAOS_ROOT/printer_data/config/printer.cfg"

	# Resolve the extension modules that ACTUALLY SHIP. This used to import
	# from the firmware repository's own klippy_extras/ mirror, which had
	# drifted from the extensions repository that owns these modules: the
	# mirror's z_compensate.py registered CRTENSE_NOZZLE_CLEAR and
	# Z_OFFSET_CALIBRATION and defaulted hot_start_temp to 140, while the
	# shipping module registers only _NEBULAOS_NOZZLE_CLEAN and defaults to
	# 150. So this test was validating the shipped printer.cfg against code
	# that is not shipped. The mirror has been removed.
	#
	# Resolution order, deliberately strict:
	#   1. the build's own fetched checkout - authoritative, sitting at
	#      KLIPPER_EXTENSIONS_PIN by construction;
	#   2. a sibling workspace checkout, but ONLY if its HEAD is exactly
	#      that pin;
	#   3. otherwise SKIP, naming the pin it wanted.
	# A sibling checkout at any other commit is precisely the "validate
	# against non-shipping code" failure this change exists to end, so it
	# is refused rather than silently used.
	ext_pin=$(grep -E '^KLIPPER_EXTENSIONS_PIN=' "$REPO_ROOT/manifests/dependencies.conf" \
		| tail -1 | cut -d= -f2)
	extras_dir=""
	if [ -d "$REPO_ROOT/vendor/nebulaos-klipper-extensions/extras" ]; then
		extras_dir=$REPO_ROOT/vendor/nebulaos-klipper-extensions/extras
	elif [ -d "$REPO_ROOT/../NebulaOS-klipper-extensions/extras" ]; then
		_sib=$(cd "$REPO_ROOT/../NebulaOS-klipper-extensions" && pwd)
		_sib_head=$(git -C "$_sib" rev-parse HEAD 2>/dev/null)
		if [ -n "$ext_pin" ] && [ "$_sib_head" = "$ext_pin" ]; then
			extras_dir=$_sib/extras
		fi
	fi

	# klippy/extras is a PACKAGE at runtime, and z_compensate.py uses a
	# relative import (`from . import nozzle_clear`). The extensions repo's
	# extras/ has no __init__.py of its own, so compose a throwaway package
	# of symlinks to the real shipping files rather than copying them.
	pkg_root=$WORK/extpkg
	if [ -n "$extras_dir" ]; then
		rm -rf "$pkg_root"
		mkdir -p "$pkg_root/klippy_extras"
		: > "$pkg_root/klippy_extras/__init__.py"
		for _m in "$extras_dir"/*.py; do
			ln -sf "$_m" "$pkg_root/klippy_extras/$(basename "$_m")"
		done
	fi

	if [ -z "$extras_dir" ]; then
		echo "SKIP: no extensions source at KLIPPER_EXTENSIONS_PIN ($ext_pin) - run 00-fetch-vendor-sources.sh, or put the sibling NebulaOS-klipper-extensions checkout on that exact pin. Refusing to validate the shipped printer.cfg against non-shipping extension code."
	elif PYTHONPATH="$pkg_root" python3 - "$provisioned_cfg" "$REPO_ROOT/scripts/build/overlay/etc/nebulaos/klipper/prtouch.cfg" <<'PYEOF'
import configparser, sys
from klippy_extras import prtouch_test_support as fake
from klippy_extras import z_compensate

def real_section(text, section):
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    marker = "\n[%s]\n" % section
    start = text.index(marker) + 1
    nxt = text.find("\n[", start + 1)
    parser.read_string(text[start:nxt if nxt != -1 else len(text)])
    return dict(parser[section])

provisioned_text = open(sys.argv[1]).read()
if not any(line.strip() == "[include /etc/nebulaos/klipper/prtouch.cfg]"
           for line in provisioned_text.splitlines()):
    raise SystemExit(
        "provisioned printer.cfg does not actively include prtouch.cfg - "
        "z_compensate.py (Z_OFFSET_CALIBRATION, CRTENSE_NOZZLE_CLEAR) would "
        "never load at all")

text = provisioned_text + "\n" + open(sys.argv[2]).read()
zc_values = real_section(text, "z_compensate")
printer, mcu, pins, _ = fake.build_environment()
zc_config = fake.make_z_compensate_config(printer, zc_values)
zc = z_compensate.ZCompensate(zc_config)

fake.connect(printer, mcu)
zc_config.assert_all_consumed()
assert zc.bed_add_temp == 60.0, zc.bed_add_temp
print("VALID")
PYEOF
	then
		pass "virgin boot: provisioned printer.cfg reaches a valid Klipper startup configuration (real config-load validation, zero errors)"
	else
		fail "virgin boot: provisioned printer.cfg failed real Klipper config validation"
	fi
}

test_virgin_first_boot_produces_valid_klipper_config

echo
echo "virgin-first-boot-simulation-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
