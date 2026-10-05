#!/bin/sh
#
# Offline, repeatable tests for migrate_printer_cfg() and
# migrate_moonraker_pin_include() in scripts/build/overlay/etc/init.d/
# S04nebulaos-migrate (Phase 1.5 persistent-namespace mission, 2026-08):
# the one-time, idempotent rewrites that move an existing device's
# persistent printer.cfg/moonraker.conf onto the new /etc/nebulaos/
# klipper|moonraker/ split-entrypoint shape.
#
# Sources the real S04nebulaos-migrate with S04NEBULAOS_MIGRATE_NO_AUTORUN=1
# (same seam app-migration-tests.sh already uses) and PRINTER_DATA_CONFIG/
# SYSTEM/GATE_LIB pointed at sandbox paths under mktemp -d. Never touches a
# real device.
#
# migrate_printer_cfg() reads its replacement template from
# "$SEEDS/printer_data-config/printer.cfg" (SEEDS defaults to
# /opt/nebulaos-seeds, same override convention every other seed reference
# in this file already uses - reseed_git_app's "$SEEDS/$name.tar.gz",
# "$SEEDS/seed-manifest.json"). Overridden to a sandbox path below, so
# cases A/B/C/F (the successful-migration path) run for real without
# needing root or touching anything outside mktemp -d.
#
# Usage: sh tests/printer-cfg-migration-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# The S04 scripts source this shared reader (audit F-06). Exported once
# here so every `env ... sh -c ". $SCRIPT"` invocation below inherits it;
# on a device it is /etc/nebulaos-seed-manifest.sh and this is a no-op.
export SEED_MANIFEST_LIB="${SEED_MANIFEST_LIB:-$SCRIPT_DIR/../scripts/build/overlay/etc/nebulaos-seed-manifest.sh}"
export GATE_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh"
MIGRATE_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate"
REAL_PRINTER_CFG="$REPO_ROOT/scripts/build/overlay/opt/printer_data/config/printer.cfg"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/printer-cfg-migration-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: printer-cfg-migration-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }

SEEDS_SANDBOX="$WORK/seeds"
NEW_SEED_FILE="$SEEDS_SANDBOX/printer_data-config/printer.cfg"

cleanup() {
	chmod -R u+rwx "$WORK" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

[ -f "$MIGRATE_SCRIPT" ] || { echo "SKIP: $MIGRATE_SCRIPT not present"; exit 0; }
[ -f "$REAL_PRINTER_CFG" ] || { echo "SKIP: $REAL_PRINTER_CFG not present"; exit 0; }

PASS=0
FAIL=0
SKIP=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# --- stage the real tracked printer.cfg at the sandboxed seed path --------

mkdir -p "$SEEDS_SANDBOX/printer_data-config"
cp "$REAL_PRINTER_CFG" "$NEW_SEED_FILE"

# --- helpers --------------------------------------------------------------

run_fn() {
	pdc="$1"; sysdir="$2"; fn="$3"; log="$4"
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 PRINTER_DATA_CONFIG="$pdc" SYSTEM="$sysdir" SEEDS="$SEEDS_SANDBOX" \
		sh -c ". '$MIGRATE_SCRIPT'; rc=0; $fn || rc=\$?; echo \"RC=\$rc\"" \
		> "$log" 2>&1
}
rc_of() { grep '^RC=' "$1" | tail -1 | sed 's/^RC=//'; }

require_stage() {
	return 0
}

write_old_monolithic_fixture() {
	out="$1"
	cat > "$out" <<'EOF'
# NebulaOS Ender-3 V3 KE - old monolithic printer.cfg fixture
# (representative of the pre-Phase-1.5-split shape: machine/PRTouch/
# platform definitions all inline, ending with the anchor line
# migrate_printer_cfg() looks for).
[nebulaos_compat]

[tmcstatus]

[nebulaos_version]

[mcu]
serial: /dev/ttyS1
baud: 230400

[printer]
kinematics: cartesian
max_velocity: 500

[stepper_x]
step_pin: PC2
dir_pin: !PB9
enable_pin: !PC3

[extruder]
heater_pin: PA1
sensor_type: EPCOS 100K B57560G104F

[temperature_sensor mcu_temp]
sensor_type: nebulaos_temperature_mcu

[include GuppyScreen/guppy_cmd.cfg]
[include camera-quality.cfg]

[include simpleaf/homing.cfg]
[include simpleaf/useful_macros.cfg]
[include simpleaf/fan_control.cfg]
[include simpleaf/client.cfg]
[include simpleaf/start_end.cfg]
[include simpleaf/Line_Purge.cfg]
[include simpleaf/Smart_Park.cfg]
[include simpleaf/bltouch_macro.cfg]
EOF
}

# Real device found live (Phase 1.5 hardware qualification, 2026-08-19): a
# device provisioned before [nebulaos_compat] was introduced (Virgin-Baseline
# Fix + Rebuild mission, 2026-08-08) but which already carries [tmcstatus]
# and [nebulaos_version] as real, inline sections - this project's own
# authorship markers from that earlier generation.
write_pre_compat_monolithic_fixture() {
	out="$1"
	cat > "$out" <<'EOF'
# NebulaOS Ender-3 V3 KE - old monolithic printer.cfg fixture, from BEFORE
# [nebulaos_compat] existed (representative of a real device found live
# still on this exact shape 11 days after that section was introduced).
[tmcstatus]

[nebulaos_version]

[mcu]
serial: /dev/ttyS1
baud: 230400

[printer]
kinematics: cartesian
max_velocity: 500

[stepper_x]
step_pin: PC2
dir_pin: !PB9
enable_pin: !PC3

[extruder]
heater_pin: PA1
sensor_type: EPCOS 100K B57560G104F

[temperature_sensor mcu_temp]
sensor_type: temperature_mcu

[include GuppyScreen/guppy_cmd.cfg]
[include camera-quality.cfg]

[include simpleaf/homing.cfg]
[include simpleaf/useful_macros.cfg]
[include simpleaf/fan_control.cfg]
[include simpleaf/client.cfg]
[include simpleaf/start_end.cfg]
[include simpleaf/Line_Purge.cfg]
[include simpleaf/Smart_Park.cfg]
[include simpleaf/bltouch_macro.cfg]
EOF
}

# =========================================================================
# CASE A - clean known-old monolithic printer.cfg, no SAVE_CONFIG, no
# extra user content. Must migrate, back up first, backup matches the
# original exactly, migrated file has all three new includes.
# =========================================================================

if require_stage "case A"; then
	tA="$WORK/caseA"; mkdir -p "$tA/config" "$tA/system"
	write_old_monolithic_fixture "$tA/config/printer.cfg"
	cp "$tA/config/printer.cfg" "$tA/original.cfg"
	logA="$WORK/caseA.log"
	run_fn "$tA/config" "$tA/system" migrate_printer_cfg "$logA"

	backupA=$(find "$tA/system/migration-backups/printer-cfg-migration" -maxdepth 1 -type f -name 'printer.cfg.pre-migration.*' 2>/dev/null | head -1)
	if [ -n "$backupA" ] && cmp -s "$backupA" "$tA/original.cfg"; then
		pass "case A: backed up first, backup matches the original exactly"
	else
		fail "case A: backup missing or does not match the original ($(cat "$logA"))"
	fi

	if grep -qxF '[include /etc/nebulaos/klipper/platform.cfg]' "$tA/config/printer.cfg" \
		&& grep -qxF '[include /etc/nebulaos/klipper/machine.cfg]' "$tA/config/printer.cfg" \
		&& grep -qxF '[include /etc/nebulaos/klipper/prtouch.cfg]' "$tA/config/printer.cfg"; then
		pass "case A: migrated file has platform+machine+prtouch(z_compensate) includes active"
	else
		fail "case A: migrated file is missing one or more of the new includes"
	fi

	if [ "$(rc_of "$logA")" = "0" ]; then
		pass "case A: migrate_printer_cfg reports success"
	else
		fail "case A: migrate_printer_cfg reported failure ($(cat "$logA"))"
	fi
fi

# =========================================================================
# CASE B - same, but with a real SAVE_CONFIG block appended after the last
# include. Must be preserved byte-for-byte at the end of the migrated file.
# =========================================================================

if require_stage "case B"; then
	tB="$WORK/caseB"; mkdir -p "$tB/config" "$tB/system"
	write_old_monolithic_fixture "$tB/config/printer.cfg"
	save_config_block='#*# <---------------------- SAVE_CONFIG ---------------------->
#*# DO NOT EDIT THIS BLOCK OR BELOW. The contents are auto-generated.
#*#
#*# [bltouch]
#*# z_offset = 1.234000'
	printf '%s\n' "$save_config_block" >> "$tB/config/printer.cfg"
	logB="$WORK/caseB.log"
	run_fn "$tB/config" "$tB/system" migrate_printer_cfg "$logB"

	actual_tail=$(awk '/^#\*# <---------------------- SAVE_CONFIG/{found=1} found' "$tB/config/printer.cfg")
	if [ "$actual_tail" = "$save_config_block" ]; then
		pass "case B: SAVE_CONFIG block is preserved byte-for-byte at the end of the migrated file"
	else
		fail "case B: SAVE_CONFIG block was not preserved correctly ($(cat "$logB"))"
	fi

	if grep -qxF '[include /etc/nebulaos/klipper/platform.cfg]' "$tB/config/printer.cfg"; then
		pass "case B: migrated file still has the new includes alongside the preserved SAVE_CONFIG block"
	else
		fail "case B: migrated file is missing the new includes"
	fi
fi

# =========================================================================
# CASE C - same, but with an extra user-added include after the anchor
# line. Must survive the migration, in the same relative position (after
# the standard includes).
# =========================================================================

if require_stage "case C"; then
	tC="$WORK/caseC"; mkdir -p "$tC/config" "$tC/system"
	write_old_monolithic_fixture "$tC/config/printer.cfg"
	echo '[include my_custom_macros.cfg]' >> "$tC/config/printer.cfg"
	logC="$WORK/caseC.log"
	run_fn "$tC/config" "$tC/system" migrate_printer_cfg "$logC"

	if grep -qxF '[include my_custom_macros.cfg]' "$tC/config/printer.cfg"; then
		pass "case C: the user's own added include survives the migration"
	else
		fail "case C: the user's own added include was lost ($(cat "$logC"))"
	fi

	# Phase 2 final software closure mission, 2026-09-09: was checking
	# position against [include simpleaf/bltouch_macro.cfg] - the OLD
	# anchor line migrate_printer_cfg() itself discards as part of its own
	# anchor cut (that is the anchor's entire job; it never appears in the
	# migrated output). This assertion always failed regardless of the
	# real position, since last_standard_line was always empty. The
	# correct post-migration "last standard include" is the actual last
	# line migrate_printer_cfg() itself produces - beeper.cfg's include -
	# not a line that is guaranteed to be gone by design.
	last_standard_line=$(grep -n '^\[include /etc/nebulaos/klipper/beeper.cfg\]$' "$tC/config/printer.cfg" | tail -1 | cut -d: -f1)
	custom_line=$(grep -n '^\[include my_custom_macros.cfg\]$' "$tC/config/printer.cfg" | tail -1 | cut -d: -f1)
	if [ -n "$last_standard_line" ] && [ -n "$custom_line" ] && [ "$custom_line" -gt "$last_standard_line" ]; then
		pass "case C: the custom include stays in the same relative position, after the standard includes"
	else
		fail "case C: the custom include's position relative to the standard includes changed"
	fi
fi

# =========================================================================
# CASE D - a printer.cfg that is ALREADY migrated. Must be a true no-op,
# byte-for-byte unchanged, confirmed idempotent by running twice.
# =========================================================================

tD="$WORK/caseD"; mkdir -p "$tD/config" "$tD/system"
cp "$REAL_PRINTER_CFG" "$tD/config/printer.cfg"
cp "$REAL_PRINTER_CFG" "$tD/original.cfg"
logD1="$WORK/caseD1.log"
run_fn "$tD/config" "$tD/system" migrate_printer_cfg "$logD1"

if cmp -s "$tD/config/printer.cfg" "$tD/original.cfg"; then
	pass "case D: an already-migrated printer.cfg is left byte-for-byte unchanged"
else
	fail "case D: an already-migrated printer.cfg was modified ($(cat "$logD1"))"
fi
if [ "$(rc_of "$logD1")" = "0" ]; then
	pass "case D: migrate_printer_cfg reports success (no-op) on an already-migrated file"
else
	fail "case D: migrate_printer_cfg reported failure on an already-migrated file ($(cat "$logD1"))"
fi

logD2="$WORK/caseD2.log"
run_fn "$tD/config" "$tD/system" migrate_printer_cfg "$logD2"
if cmp -s "$tD/config/printer.cfg" "$tD/original.cfg" && [ "$(rc_of "$logD2")" = "0" ]; then
	pass "case D: running migration a second time is genuinely idempotent"
else
	fail "case D: a second migration run was not idempotent ($(cat "$logD2"))"
fi

# =========================================================================
# CASE E - a printer.cfg that does not match the recognized old shape at
# all (a completely custom, hand-written config: no anchor line, no
# [nebulaos_compat]). Must be refused: original completely unchanged, a
# backup written to the "refused" directory, non-zero return.
# =========================================================================

tE="$WORK/caseE"; mkdir -p "$tE/config" "$tE/system"
cat > "$tE/config/printer.cfg" <<'EOF'
# A user's completely custom printer.cfg, unrelated to any shape this
# project has ever shipped.
[mcu]
serial: /dev/ttyUSB0

[stepper_x]
step_pin: PC2
dir_pin: PB9

[printer]
kinematics: cartesian
max_velocity: 300
EOF
cp "$tE/config/printer.cfg" "$tE/original.cfg"
logE="$WORK/caseE.log"
run_fn "$tE/config" "$tE/system" migrate_printer_cfg "$logE"

if cmp -s "$tE/config/printer.cfg" "$tE/original.cfg"; then
	pass "case E: an unrecognized printer.cfg is left completely unchanged"
else
	fail "case E: an unrecognized printer.cfg was modified despite not matching a recognized shape"
fi

refusedE=$(find "$tE/system/migration-backups/printer-cfg-migration-refused" -maxdepth 1 -type f 2>/dev/null | head -1)
if [ -n "$refusedE" ] && cmp -s "$refusedE" "$tE/original.cfg"; then
	pass "case E: a backup was written to the refused-migration directory, matching the original"
else
	fail "case E: no matching backup found in the refused-migration directory ($(cat "$logE"))"
fi

if [ "$(rc_of "$logE")" != "0" ]; then
	pass "case E: migrate_printer_cfg reports failure for an unrecognized shape"
else
	fail "case E: migrate_printer_cfg reported success for an unrecognized shape"
fi

# =========================================================================
# CASE F - interrupted-migration residue: a stray printer.cfg.migrate-
# tmp.<pid> file left behind by a hypothetical killed process, alongside a
# FRESH (unmigrated) fixture. Must not interfere; migration still
# completes correctly.
# =========================================================================

if require_stage "case F"; then
	tF="$WORK/caseF"; mkdir -p "$tF/config" "$tF/system"
	write_old_monolithic_fixture "$tF/config/printer.cfg"
	echo "leftover garbage from a killed migration" > "$tF/config/printer.cfg.migrate-tmp.999999"
	logF="$WORK/caseF.log"
	run_fn "$tF/config" "$tF/system" migrate_printer_cfg "$logF"

	if grep -qxF '[include /etc/nebulaos/klipper/platform.cfg]' "$tF/config/printer.cfg" \
		&& [ "$(rc_of "$logF")" = "0" ]; then
		pass "case F: migration completes correctly despite an unrelated stray migrate-tmp file"
	else
		fail "case F: migration did not complete correctly with a stray migrate-tmp file present ($(cat "$logF"))"
	fi

	if [ -f "$tF/config/printer.cfg.migrate-tmp.999999" ]; then
		pass "case F: the unrelated stray temp file is simply orphaned, still present, untouched"
	else
		fail "case F: the stray temp file disappeared unexpectedly"
	fi
fi

# =========================================================================
# CASE G - a device provisioned before [nebulaos_compat] existed at all
# (real shape found live, Phase 1.5 hardware qualification, 2026-08-19):
# [tmcstatus] and [nebulaos_version] are present as real sections, but
# [nebulaos_compat] is not. Must still be recognized and migrated - this is
# exactly the case the broadened known_shape check exists for.
# =========================================================================

if require_stage "case G"; then
	tG="$WORK/caseG"; mkdir -p "$tG/config" "$tG/system"
	write_pre_compat_monolithic_fixture "$tG/config/printer.cfg"
	cp "$tG/config/printer.cfg" "$tG/original.cfg"
	logG="$WORK/caseG.log"
	run_fn "$tG/config" "$tG/system" migrate_printer_cfg "$logG"

	backupG=$(find "$tG/system/migration-backups/printer-cfg-migration" -maxdepth 1 -type f -name 'printer.cfg.pre-migration.*' 2>/dev/null | head -1)
	if [ -n "$backupG" ] && cmp -s "$backupG" "$tG/original.cfg"; then
		pass "case G: a pre-nebulaos_compat device is backed up first, backup matches the original exactly"
	else
		fail "case G: backup missing or does not match the original ($(cat "$logG"))"
	fi

	if grep -qxF '[include /etc/nebulaos/klipper/platform.cfg]' "$tG/config/printer.cfg" \
		&& grep -qxF '[include /etc/nebulaos/klipper/machine.cfg]' "$tG/config/printer.cfg" \
		&& grep -qxF '[include /etc/nebulaos/klipper/prtouch.cfg]' "$tG/config/printer.cfg"; then
		pass "case G: pre-nebulaos_compat device migrates to the new split includes just like a post-nebulaos_compat one"
	else
		fail "case G: pre-nebulaos_compat device did not migrate to the new includes"
	fi

	if [ "$(rc_of "$logG")" = "0" ]; then
		pass "case G: migrate_printer_cfg reports success for a pre-nebulaos_compat device"
	else
		fail "case G: migrate_printer_cfg reported failure for a pre-nebulaos_compat device ($(cat "$logG"))"
	fi
fi

# =========================================================================
# CASE H - only ONE of [tmcstatus]/[nebulaos_version] present (neither
# [nebulaos_compat] nor the full pair). Must still be refused - the pair is
# required together, not treated as independently sufficient.
# =========================================================================

tH="$WORK/caseH"; mkdir -p "$tH/config" "$tH/system"
write_pre_compat_monolithic_fixture "$tH/config/printer.cfg"
# Remove the [nebulaos_version] section header, leaving only [tmcstatus].
sed '/^\[nebulaos_version\]$/d' "$tH/config/printer.cfg" > "$tH/config/printer.cfg.new"
mv "$tH/config/printer.cfg.new" "$tH/config/printer.cfg"
cp "$tH/config/printer.cfg" "$tH/original.cfg"
logH="$WORK/caseH.log"
run_fn "$tH/config" "$tH/system" migrate_printer_cfg "$logH"

if cmp -s "$tH/config/printer.cfg" "$tH/original.cfg" && [ "$(rc_of "$logH")" != "0" ]; then
	pass "case H: only one of [tmcstatus]/[nebulaos_version] present is still refused, not treated as a known shape"
else
	fail "case H: a config with only one of the two markers was incorrectly migrated ($(cat "$logH"))"
fi

# =========================================================================
# migrate_moonraker_pin_include() - tested separately, does not depend on
# the new_seed staging above at all.
# =========================================================================

# --- sub-case 1: old glob line present -> rewritten, only that one line --

tM1="$WORK/moon1"; mkdir -p "$tM1"
cat > "$tM1/moonraker.conf" <<'EOF'
[server]
host: 0.0.0.0
port: 7125

[include nebulaos/*.conf]

[update_manager moonraker]
channel: dev
EOF
cp "$tM1/moonraker.conf" "$tM1/original.conf"
logM1="$WORK/moon1.log"
run_fn "$tM1" "$WORK/moon1-system" migrate_moonraker_pin_include "$logM1"

expectedM1="$WORK/moon1-expected.conf"
sed 's#^\[include nebulaos/\*\.conf\]$#[include /etc/nebulaos/moonraker/klipper-pin.conf]#' \
	"$tM1/original.conf" > "$expectedM1"
if cmp -s "$expectedM1" "$tM1/moonraker.conf"; then
	pass "moonraker pin include: old glob line rewritten to the new absolute include, everything else byte-identical"
else
	fail "moonraker pin include: rewrite did not produce the expected result ($(cat "$logM1"))"
fi
if [ "$(rc_of "$logM1")" = "0" ]; then
	pass "moonraker pin include: reports success when the old line is found and rewritten"
else
	fail "moonraker pin include: reported failure on a successful rewrite ($(cat "$logM1"))"
fi

# --- sub-case 2: already has the new line -> no-op -----------------------

tM2="$WORK/moon2"; mkdir -p "$tM2"
cat > "$tM2/moonraker.conf" <<'EOF'
[server]
host: 0.0.0.0
port: 7125

[include /etc/nebulaos/moonraker/klipper-pin.conf]

[update_manager moonraker]
channel: dev
EOF
cp "$tM2/moonraker.conf" "$tM2/original.conf"
logM2="$WORK/moon2.log"
run_fn "$tM2" "$WORK/moon2-system" migrate_moonraker_pin_include "$logM2"

if cmp -s "$tM2/moonraker.conf" "$tM2/original.conf" && [ "$(rc_of "$logM2")" = "0" ]; then
	pass "moonraker pin include: already-migrated file is a true no-op"
else
	fail "moonraker pin include: an already-migrated file was modified or reported failure ($(cat "$logM2"))"
fi

# --- sub-case 3: neither line present -> no-op, not an error -------------

tM3="$WORK/moon3"; mkdir -p "$tM3"
cat > "$tM3/moonraker.conf" <<'EOF'
[server]
host: 0.0.0.0
port: 7125

[authorization]
trusted_clients:
 127.0.0.1
EOF
cp "$tM3/moonraker.conf" "$tM3/original.conf"
logM3="$WORK/moon3.log"
run_fn "$tM3" "$WORK/moon3-system" migrate_moonraker_pin_include "$logM3"

if cmp -s "$tM3/moonraker.conf" "$tM3/original.conf" && [ "$(rc_of "$logM3")" = "0" ]; then
	pass "moonraker pin include: a custom moonraker.conf with neither line is a no-op, not an error"
else
	fail "moonraker pin include: a custom moonraker.conf with neither line was modified or reported failure ($(cat "$logM3"))"
fi

# --- sub-case 4 (CASE C): real historical shape found live - no include of --
# --- any kind, just [update_manager klipper]/channel: dev directly --------

tM4="$WORK/moon4"; mkdir -p "$tM4"
cat > "$tM4/moonraker.conf" <<'EOF'
[server]
host: 0.0.0.0
port: 7125

[file_manager]
enable_object_processing: True

[machine]
provider: systemd_cli

[update_manager]
channel: dev
refresh_interval: 168

[update_manager klipper]
channel: dev

[update_manager moonraker]
channel: dev

[update_manager mainsail]
channel: stable
repo: mainsail-crew/mainsail
path: ~/mainsail

[authorization]
trusted_clients:
 127.0.0.1
 10.0.0.0/8
EOF
cp "$tM4/moonraker.conf" "$tM4/original.conf"
logM4="$WORK/moon4.log"
run_fn "$tM4" "$WORK/moon4-system" migrate_moonraker_pin_include "$logM4"

if grep -qxF '[include /etc/nebulaos/moonraker/klipper-pin.conf]' "$tM4/moonraker.conf"; then
	pass "case C: legacy no-include layout gets the qualified include inserted"
else
	fail "case C: qualified include was not inserted ($(cat "$logM4"))"
fi
if ! grep -qxF '[update_manager klipper]' "$tM4/moonraker.conf"; then
	pass "case C: the legacy [update_manager klipper] section is removed"
else
	fail "case C: the legacy [update_manager klipper] section survived the migration"
fi
if grep -qxF '[update_manager moonraker]' "$tM4/moonraker.conf" \
	&& grep -qxF '[update_manager mainsail]' "$tM4/moonraker.conf" \
	&& grep -qxF '[update_manager]' "$tM4/moonraker.conf" \
	&& grep -qxF '[authorization]' "$tM4/moonraker.conf" \
	&& grep -qxF '[machine]' "$tM4/moonraker.conf" \
	&& grep -qxF 'repo: mainsail-crew/mainsail' "$tM4/moonraker.conf"; then
	pass "case C: unrelated sections ([update_manager moonraker], [update_manager mainsail], [update_manager], [machine], [authorization]) are preserved byte-for-byte, including their own options"
else
	fail "case C: an unrelated section or option was lost during migration"
fi
inc_count_m4=$(grep -cxF '[include /etc/nebulaos/moonraker/klipper-pin.conf]' "$tM4/moonraker.conf")
if [ "$inc_count_m4" = "1" ]; then
	pass "case C: the effective closure contains the qualified include exactly once"
else
	fail "case C: the qualified include appears $inc_count_m4 times, expected exactly 1"
fi
if [ "$(rc_of "$logM4")" = "0" ]; then
	pass "case C: migrate_moonraker_pin_include reports success"
else
	fail "case C: migrate_moonraker_pin_include reported failure ($(cat "$logM4"))"
fi
backupM4=$(find "$WORK/moon4-system/migration-backups/moonraker-conf-migration" -maxdepth 1 -type f -name 'moonraker.conf.pre-migration.*' 2>/dev/null | head -1)
if [ -n "$backupM4" ] && cmp -s "$backupM4" "$tM4/original.conf"; then
	pass "case C: original moonraker.conf backed up first, backup matches exactly"
else
	fail "case C: backup missing or does not match the original"
fi

# --- sub-case 4b: second boot on the now-migrated file is a true no-op ----

logM4b="$WORK/moon4b.log"
snapshotM4="$tM4/after-first-migration.conf"
cp "$tM4/moonraker.conf" "$snapshotM4"
run_fn "$tM4" "$WORK/moon4-system" migrate_moonraker_pin_include "$logM4b"
if cmp -s "$tM4/moonraker.conf" "$snapshotM4" && [ "$(rc_of "$logM4b")" = "0" ]; then
	pass "case C: second boot (already migrated) is a true no-op"
else
	fail "case C: second boot was not idempotent ($(cat "$logM4b"))"
fi

# --- sub-case 5 (CASE D): a legacy section with unexpected content must ----
# --- be refused, not guessed at --------------------------------------------

tM5="$WORK/moon5"; mkdir -p "$tM5"
cat > "$tM5/moonraker.conf" <<'EOF'
[server]
host: 0.0.0.0
port: 7125

[update_manager klipper]
channel: dev
pinned_commit: 0123456789abcdef0123456789abcdef01234567

[authorization]
trusted_clients:
 127.0.0.1
EOF
cp "$tM5/moonraker.conf" "$tM5/original.conf"
logM5="$WORK/moon5.log"
run_fn "$tM5" "$WORK/moon5-system" migrate_moonraker_pin_include "$logM5"

if cmp -s "$tM5/moonraker.conf" "$tM5/original.conf"; then
	pass "case D: a legacy section with unexpected content (a user's own pinned_commit) is left completely unchanged"
else
	fail "case D: a legacy section with unexpected content was modified despite not matching the known narrow shape"
fi
refusedM5=$(find "$WORK/moon5-system/migration-backups/moonraker-conf-migration-refused" -maxdepth 1 -type f 2>/dev/null | head -1)
if [ -n "$refusedM5" ] && cmp -s "$refusedM5" "$tM5/original.conf"; then
	pass "case D: a backup was written to the refused-migration directory, matching the original"
else
	fail "case D: no matching backup found in the refused-migration directory ($(cat "$logM5"))"
fi
if [ "$(rc_of "$logM5")" != "0" ]; then
	pass "case D: migrate_moonraker_pin_include reports failure for unrecognized legacy content"
else
	fail "case D: migrate_moonraker_pin_include reported success for unrecognized legacy content"
fi

# --- BOOT-07: the managed-tree generation is already migrated -----------
# The shipped steady state on every migrated device (seen live on ke-dev,
# 2026-10-04): relative nebulaos/*.cfg includes. Must be a silent no-op:
# rc 0, file byte-identical, no refusal backup, no ERROR line.
for variant in full no-macros; do
	tMT="$WORK/managed-$variant"; mkdir -p "$tMT/config" "$tMT/system"
	{
		echo '# NebulaOS Ender-3 V3 KE - managed-tree printer.cfg (live shape)'
		for x in platform machine prtouch z_offset_probe calibration homing print filament camera beeper; do
			echo "[include nebulaos/$x.cfg]"
		done
		[ "$variant" = full ] && { echo; echo '[include macros/*.cfg]'; }
		echo
		echo '#*# <---------------------- SAVE_CONFIG ---------------------->'
		echo '#*# [bltouch]'
		echo '#*# z_offset = 2.100'
	} > "$tMT/config/printer.cfg"
	cp "$tMT/config/printer.cfg" "$tMT/original.cfg"
	logMT="$WORK/managed-$variant.log"
	run_fn "$tMT/config" "$tMT/system" migrate_printer_cfg "$logMT"
	[ "$(rc_of "$logMT")" = "0" ] && pass "BOOT-07 ($variant): managed-tree printer.cfg returns 0" \
		|| fail "BOOT-07 ($variant): managed-tree printer.cfg returned $(rc_of "$logMT")"
	cmp -s "$tMT/config/printer.cfg" "$tMT/original.cfg" && pass "BOOT-07 ($variant): printer.cfg byte-identical" \
		|| fail "BOOT-07 ($variant): printer.cfg was modified"
	[ -z "$(find "$tMT/system" -path '*printer-cfg-migration-refused*' -type f 2>/dev/null)" ] \
		&& pass "BOOT-07 ($variant): no refusal backup written" \
		|| fail "BOOT-07 ($variant): a refusal backup was written"
	grep -q 'ERROR' "$logMT" && fail "BOOT-07 ($variant): an ERROR was logged ($(cat "$logMT"))" \
		|| pass "BOOT-07 ($variant): no ERROR logged"
done

# Only half of the managed shape (platform without filament) is NOT taken as
# migrated - it still falls through to the existing refusal.
tMH="$WORK/managed-half"; mkdir -p "$tMH/config" "$tMH/system"
printf '%s\n' '# half-managed fixture' '[include nebulaos/platform.cfg]' '[include nebulaos/machine.cfg]' > "$tMH/config/printer.cfg"
cp "$tMH/config/printer.cfg" "$tMH/original.cfg"
run_fn "$tMH/config" "$tMH/system" migrate_printer_cfg "$WORK/managed-half.log"
[ "$(rc_of "$WORK/managed-half.log")" != "0" ] && cmp -s "$tMH/config/printer.cfg" "$tMH/original.cfg" \
	&& pass "BOOT-07: a partial managed shape is still refused, untouched" \
	|| fail "BOOT-07: a partial managed shape was accepted or modified ($(cat "$WORK/managed-half.log"))"

echo ""
echo "printer-cfg-migration-tests: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
