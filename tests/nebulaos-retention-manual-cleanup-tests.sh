#!/bin/sh
#
# Offline tests for /etc/nebulaos-retention.sh --manual, the Storage page's
# "Free up space" (Run 23, Tim): NebulaOS's own leftovers go regardless of
# age; print files, configuration, calibration, PLR state, settings, the
# update supervisor's last-known-good and Creality's data stay. --dry-run
# changes nothing and lists what would go.
#
# Usage: sh tests/nebulaos-retention-manual-cleanup-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
RETENTION_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-retention.sh"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/retention-manual-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: mktemp did not produce a usable path" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

# fixture DIR - a small data drive: leftovers (all recent) and keepers.
fixture() {
	d="$1"; R="$d/nebulaos"
	mkdir -p "$R/printer_data/logs" "$R/printer_data/config/uploads/system-image" \
		"$R/system/migration-backups" "$R/updates/staging/old-job" \
		"$R/updates/locks" "$R/backups/klipper/last-known-good" "$R/maintenance" \
		"$d/printer_data/gcodes" "$d/creality/userdata" "$d/pip-cache/x"
	echo log > "$R/printer_data/logs/klippy.log"
	echo old > "$R/printer_data/logs/klippy.log.1"
	echo old > "$R/printer_data/logs/moonraker.log.2"
	echo sys > "$R/printer_data/logs/system.log.0"
	for e in 20261029T100000Z 20261030T100000Z 20261031T100000Z; do
		mkdir -p "$R/system/migration-backups/$e"; echo b > "$R/system/migration-backups/$e/klipper.tar"
	done
	echo s > "$R/updates/staging/old-job/payload"
	echo img > "$R/printer_data/config/uploads/system-image/NebulaOS.img"
	echo cfg > "$R/printer_data/config/printer.cfg"
	echo cal > "$R/printer_data/config/printer-20261030_120000.cfg"
	echo lkg > "$R/backups/klipper/last-known-good/klippy.py"
	echo g > "$d/printer_data/gcodes/benchy.gcode"
	echo c > "$d/creality/userdata/config.json"
	echo p > "$d/pip-cache/x/wheel"
}

run_manual() {
	d="$1"; shift
	env NEBULAOS_ROOT="$d/nebulaos" LOG="$d/nebulaos/maintenance/retention.log" \
		LOCKDIR="$d/nebulaos/updates/locks" SHARED_GCODES="$d/printer_data/gcodes" \
		RETENTION_LOCK="$d/nebulaos/maintenance/retention.lock" PIP_CACHE="$d/pip-cache" \
		IMAGE_JOB_STATE="$d/no-job.json" MOONRAKER_PRINT_STATS="${FAKE_PRINT_STATS:-http://127.0.0.1:9/none}" \
		sh "$RETENTION_SCRIPT" --manual "$@"
}

# --- dry run: lists, changes nothing --------------------------------------------
D="$WORK/dry"; fixture "$D"; R="$D/nebulaos"
out=$(run_manual "$D" --dry-run); rc=$?
check "dry run exits 0" '[ $rc -eq 0 ]'
check "dry run deletes nothing" '[ -f "$R/printer_data/logs/klippy.log.1" ] && [ -d "$R/system/migration-backups/20261029T100000Z" ] && [ -d "$D/pip-cache" ]'
L="$R/maintenance/retention.log"
check "dry run lists a rotated log" 'grep -q "would delete (rotated-log): $R/printer_data/logs/klippy.log.1" "$L"'
check "dry run lists the older migration events" '[ "$(grep "would delete (old-migration-backup)" "$L" | sort -u | wc -l)" -eq 2 ]'
check "dry run lists the pip cache" 'grep -q "would delete (pip-cache): $D/pip-cache" "$L"'

# --- real run ----------------------------------------------------------------------
D="$WORK/real"; fixture "$D"; R="$D/nebulaos"
run_manual "$D" >/dev/null; rc=$?
check "manual run exits 0" '[ $rc -eq 0 ]'
check "rotated logs go, regardless of age" '[ ! -e "$R/printer_data/logs/klippy.log.1" ] && [ ! -e "$R/printer_data/logs/moonraker.log.2" ]'
check "system.log.0 stays syslogd's" '[ -f "$R/printer_data/logs/system.log.0" ]'
check "the live log stays" '[ -f "$R/printer_data/logs/klippy.log" ]'
check "migration backups: only the newest event stays" '[ "$(ls "$R/system/migration-backups")" = 20261031T100000Z ]'
check "unlocked staging goes" '[ ! -e "$R/updates/staging/old-job" ]'
check "uploaded system image goes" '[ ! -e "$R/printer_data/config/uploads/system-image/NebulaOS.img" ]'
check "pip cache goes" '[ ! -e "$D/pip-cache" ]'
check "printer.cfg stays" '[ -f "$R/printer_data/config/printer.cfg" ]'
check "SAVE_CONFIG backup (calibration) stays (normal rule: moved to config/backups)" '[ -f "$R/printer_data/config/backups/printer-20261030_120000.cfg" ]'
check "last-known-good stays" '[ -f "$R/backups/klipper/last-known-good/klippy.py" ]'
check "print files stay" '[ -f "$D/printer_data/gcodes/benchy.gcode" ]'
check "Creality data stays" '[ -f "$D/creality/userdata/config.json" ]'

# --- refusals ------------------------------------------------------------------
D="$WORK/busy"; fixture "$D"; R="$D/nebulaos"
mkdir -p "$R/maintenance/retention.lock"
out=$(run_manual "$D"); rc=$?
check "another retention run busy: BUSY, exit 4" '[ $rc -eq 4 ] && [ "$out" = BUSY ]'
check "busy: nothing deleted" '[ -f "$R/printer_data/logs/klippy.log.1" ]'
rmdir "$R/maintenance/retention.lock"
out=$(env NEBULAOS_RETENTION_NO_AUTORUN=1 NEBULAOS_ROOT="$R" LOG="$R/maintenance/retention.log" \
	sh -c ". '$RETENTION_SCRIPT'; print_active() { return 0; }; manual_cleanup"); rc=$?
check "printing: PRINTING, exit 3" '[ $rc -eq 3 ] && [ "$out" = PRINTING ]'
: > "$R/updates/locks/klipper.lock"
out=$(env NEBULAOS_RETENTION_NO_AUTORUN=1 NEBULAOS_ROOT="$R" LOG="$R/maintenance/retention.log" \
	LOCKDIR="$R/updates/locks" sh -c ". '$RETENTION_SCRIPT'; print_active() { return 1; }; manual_cleanup"); rc=$?
check "update lock present (an update running): UPDATING, exit 3" '[ $rc -eq 3 ] && [ "$out" = UPDATING ]'
check "refused: nothing deleted" '[ -f "$R/printer_data/logs/klippy.log.1" ]'

echo "nebulaos-retention-manual-cleanup-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
