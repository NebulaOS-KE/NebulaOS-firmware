#!/bin/sh
#
# Offline, repeatable tests for the SAVE_CONFIG backup pruning extension to
# /etc/nebulaos-retention.sh (Clean Mainsail config root mission,
# 2026-09-10, section 6).
#
# Klipper's own upstream SAVE_CONFIG mechanism (printer.py's save_config(),
# not something this project patches) writes a fresh
# printer-YYYYMMDD_HHMMSS.cfg directly into printer_data/config/ every time
# a calibration macro runs SAVE_CONFIG. A real device accumulated 8 of
# these with no pruning at all. Unlike clean_migration_backups()'s targets,
# these are Klipper's own real, user-meaningful configuration history, not
# this project's own duplicated debris - hence the more generous
# SAVE_CONFIG_BACKUP_KEEP=10 floor instead of the 2-copy floor used
# elsewhere in this script.
#
# Usage: sh tests/nebulaos-retention-save-config-backup-pruning-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
RETENTION_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-retention.sh"

[ -f "$RETENTION_SCRIPT" ] || { echo "SKIP: $RETENTION_SCRIPT not present"; exit 0; }

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/retention-save-config-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: nebulaos-retention-save-config-backup-pruning-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
cleanup() { chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

age_days_ago() {
	days="$1"; path="$2"
	touch -d "@$(( $(date +%s) - days * 86400 - 3600 ))" "$path"
}

run_fn() {
	sandbox="$1"; fn="$2"
	env NEBULAOS_RETENTION_NO_AUTORUN=1 NEBULAOS_ROOT="$sandbox" \
		LOG="$sandbox/maintenance/retention.log" \
		LOCKDIR="$sandbox/updates/locks" \
		SHARED_GCODES="$sandbox/printer_data/gcodes" \
		sh -c "mkdir -p '$sandbox/maintenance'; . '$RETENTION_SCRIPT'; $fn"
}

# =========================================================================
# Test 1: 14 old SAVE_CONFIG backups, keep newest 10
# =========================================================================

t1="$WORK/t1"
mkdir -p "$t1/printer_data/config"
i=0
for ts in 20260101_000000 20260102_000000 20260103_000000 20260104_000000 \
          20260105_000000 20260106_000000 20260107_000000 20260108_000000 \
          20260109_000000 20260110_000000 20260111_000000 20260112_000000 \
          20260113_000000 20260114_000000; do
	i=$((i + 1))
	f="$t1/printer_data/config/printer-${ts}.cfg"
	echo "SAVE_CONFIG snapshot $i" > "$f"
	age_days_ago 30 "$f"
done
run_fn "$t1" "clean_old_save_config_backups" >/dev/null 2>&1
remaining=$(find "$t1/printer_data/config/backups" -maxdepth 1 -type f -name 'printer-*.cfg' | wc -l)
if [ "$remaining" = "10" ]; then
	pass "test 1: exactly 10 SAVE_CONFIG backups remain out of 14"
else
	fail "test 1: expected 10 remaining, got $remaining"
fi
[ -f "$t1/printer_data/config/backups/printer-20260114_000000.cfg" ] \
	&& [ -f "$t1/printer_data/config/backups/printer-20260105_000000.cfg" ] \
	&& [ ! -f "$t1/printer_data/config/backups/printer-20260101_000000.cfg" ] \
	&& pass "test 1: the 10 newest backups were kept, oldest were pruned" \
	|| fail "test 1: wrong set of backups retained"

# =========================================================================
# Test 2: recent entries (< 7 days) are never touched, regardless of count
# =========================================================================

t2="$WORK/t2"
mkdir -p "$t2/printer_data/config"
for day in 01 02 03 04 05 06 07 08 09 10 11 12; do
	f="$t2/printer_data/config/printer-202602${day}_000000.cfg"
	echo "recent snapshot $day" > "$f"
	age_days_ago 2 "$f"
done
run_fn "$t2" "clean_old_save_config_backups" >/dev/null 2>&1
remaining2=$(find "$t2/printer_data/config/backups" -maxdepth 1 -type f -name 'printer-*.cfg' | wc -l)
if [ "$remaining2" = "12" ]; then
	pass "test 2: all 12 recent (<7 day) SAVE_CONFIG backups survive untouched, even beyond keep=10"
else
	fail "test 2: expected all 12 recent backups to survive, got $remaining2 remaining"
fi

# =========================================================================
# Test 3: unrelated files (live printer.cfg, named .bak backups, macros)
#     in the same directory are never touched
# =========================================================================

t3="$WORK/t3"
mkdir -p "$t3/printer_data/config/macros" "$t3/printer_data/config/nebulaos"
for day in 01 02 03 04 05 06 07 08 09 10 11 12; do
	f="$t3/printer_data/config/printer-202603${day}_000000.cfg"
	echo "old snapshot $day" > "$f"
	age_days_ago 30 "$f"
done
printer_cfg="$t3/printer_data/config/printer.cfg"
echo "[include nebulaos/machine.cfg]" > "$printer_cfg"
age_days_ago 400 "$printer_cfg"
named_bak="$t3/printer_data/config/printer.cfg.pre-phase18-flash"
echo "named ad-hoc backup" > "$named_bak"
age_days_ago 400 "$named_bak"
macro_file="$t3/printer_data/config/macros/my_macros.cfg"
echo "[gcode_macro MY_MACRO]" > "$macro_file"
age_days_ago 400 "$macro_file"
managed_file="$t3/printer_data/config/nebulaos/beeper.cfg"
echo "[gcode_macro PLAY_TUNE]" > "$managed_file"
age_days_ago 400 "$managed_file"

run_fn "$t3" "clean_old_save_config_backups" >/dev/null 2>&1
[ -f "$printer_cfg" ] && [ -f "$named_bak" ] && [ -f "$macro_file" ] && [ -f "$managed_file" ] \
	&& pass "test 3: live printer.cfg, named ad-hoc backups, macros, and the managed nebulaos/ tree are never touched" \
	|| fail "test 3: a file outside the printer-YYYYMMDD_HHMMSS.cfg pattern was deleted"
remaining3=$(find "$t3/printer_data/config/backups" -maxdepth 1 -type f -name 'printer-*_*.cfg' | wc -l)
[ "$remaining3" = "10" ] && pass "test 3: SAVE_CONFIG pruning among the mixed directory still kept exactly 10" \
	|| fail "test 3: expected 10 SAVE_CONFIG backups remaining among mixed content, got $remaining3"

# G62: the backups leave config/ for config/backups/; printer.cfg stays
[ -z "$(find "$t3/printer_data/config" -maxdepth 1 -type f -name 'printer-*_*.cfg')" ] && [ -f "$printer_cfg" ] \
	&& pass "G62: no SAVE_CONFIG backups left next to printer.cfg" \
	|| fail "G62: SAVE_CONFIG backups still in config/"

# =========================================================================
# Test 4: idempotent - running twice produces the same final state
# =========================================================================

t4="$WORK/t4"
mkdir -p "$t4/printer_data/config"
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
	f="$t4/printer_data/config/printer-2026040${n}_000000.cfg"
	echo "snapshot $n" > "$f"
	age_days_ago 30 "$f"
done
run_fn "$t4" "clean_old_save_config_backups" >/dev/null 2>&1
after_first=$(find "$t4/printer_data/config/backups" -maxdepth 1 -type f -name 'printer-*.cfg' | sort)
run_fn "$t4" "clean_old_save_config_backups" >/dev/null 2>&1
after_second=$(find "$t4/printer_data/config/backups" -maxdepth 1 -type f -name 'printer-*.cfg' | sort)
if [ "$after_first" = "$after_second" ]; then
	pass "test 4: second run is a true no-op (idempotent)"
else
	fail "test 4: second run changed the result"
fi

# =========================================================================
# Test 5: no disk-pressure gating - runs unconditionally, same as the
#     other backup-pruning functions in this script
# =========================================================================

if grep -A15 '^clean_old_save_config_backups()' "$RETENTION_SCRIPT" | grep -q 'free_mb\|CRITICAL_FLOOR\|CAUTION_FLOOR'; then
	fail "test 5: clean_old_save_config_backups references disk-pressure state - it must run unconditionally"
else
	pass "test 5: clean_old_save_config_backups has no disk-pressure gating - runs unconditionally"
fi

echo ""
echo "nebulaos-retention-save-config-backup-pruning-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
