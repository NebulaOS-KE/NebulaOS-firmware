#!/bin/sh
#
# Offline, repeatable tests for the migration-backup pruning extension to
# /etc/nebulaos-retention.sh (Phase 2 final software closure mission,
# 2026-09-09, section 2D).
#
# A real device found live had accumulated ~1.6GB under
# $NEBULAOS_ROOT/system/migration-backups (95% of a 5.9GB /usr/data
# partition, 260MB free) - almost entirely from S04nebulaos-migrate's
# reseed_git_app() writing a full klipper+moonraker+nebulaos-klipper-
# extensions checkout backup into a new BACKUP_ROOT/<ISO8601-timestamp>/
# directory on every migration run, forever, with no pruning at all. This
# extends the EXISTING retention mechanism (clean_old_config_backups()/
# clean_obsolete_versions()'s already-established "age +7 days, keep
# newest N" policy) rather than inventing a second one.
#
# Usage: sh tests/nebulaos-retention-migration-backup-pruning-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
RETENTION_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-retention.sh"

[ -f "$RETENTION_SCRIPT" ] || { echo "SKIP: $RETENTION_SCRIPT not present"; exit 0; }

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/retention-migration-backup-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: nebulaos-retention-migration-backup-pruning-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
cleanup() { chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# age_days_ago N PATH - sets PATH's mtime to N days in the past, portable
# (this repo's other tests rely on GNU touch -d being available in the dev
# environment; the device itself uses BusyBox touch, exercised only live).
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
# Test 1: timestamp-directory shape - 5 old backup events, keep newest 2
# =========================================================================

t1="$WORK/t1"
mkdir -p "$t1/system/migration-backups"
i=0
for ts in 20260101T000000Z 20260102T000000Z 20260103T000000Z 20260104T000000Z 20260105T000000Z; do
	i=$((i + 1))
	d="$t1/system/migration-backups/$ts"
	mkdir -p "$d/klipper" "$d/moonraker" "$d/nebulaos-klipper-extensions"
	echo "checkout content $i" > "$d/klipper/HEAD"
	age_days_ago 30 "$d"
done
run_fn "$t1" "clean_migration_backups" >/dev/null 2>&1
remaining=$(find "$t1/system/migration-backups" -mindepth 1 -maxdepth 1 -type d | sort)
count=$(echo "$remaining" | grep -c .)
if [ "$count" = "2" ]; then
	pass "test 1: exactly 2 timestamp-directory backups remain out of 5"
else
	fail "test 1: expected 2 remaining, got $count ($remaining)"
fi
if echo "$remaining" | grep -q "20260105T000000Z" && echo "$remaining" | grep -q "20260104T000000Z"; then
	pass "test 1: the 2 newest timestamp directories were the ones kept"
else
	fail "test 1: the newest directories were not the ones retained ($remaining)"
fi

# =========================================================================
# Test 2: named-category shape - printer-cfg-migration/ with 5 old files
# =========================================================================

t2="$WORK/t2"
mkdir -p "$t2/system/migration-backups/printer-cfg-migration"
for n in 1 2 3 4 5; do
	f="$t2/system/migration-backups/printer-cfg-migration/printer.cfg.pre-migration.2026010${n}T000000Z"
	echo "backup $n" > "$f"
	age_days_ago 30 "$f"
done
run_fn "$t2" "clean_migration_backups" >/dev/null 2>&1
remaining2=$(find "$t2/system/migration-backups/printer-cfg-migration" -mindepth 1 -maxdepth 1 -type f | wc -l)
if [ "$remaining2" = "2" ]; then
	pass "test 2: exactly 2 files remain in the printer-cfg-migration category out of 5"
else
	fail "test 2: expected 2 remaining, got $remaining2"
fi

# =========================================================================
# Test 3 (Run 23): backup events are pruned by count, not age - six recent
#     ones (one install a day) leave the newest 2 by name, so a printer that
#     is updated often cannot fill /usr/data with them
# =========================================================================

t3="$WORK/t3"
mkdir -p "$t3/system/migration-backups"
for n in 1 2 3 4 5 6; do
	d="$t3/system/migration-backups/2026020${n}T000000Z"
	mkdir -p "$d/klipper"
	age_days_ago 1 "$d"
done
recent_file="$t3/system/migration-backups/printer.cfg.pre-something.20260201T000000Z"
echo cfg > "$recent_file"
run_fn "$t3" "clean_migration_backups" >/dev/null 2>&1
remaining3=$(cd "$t3/system/migration-backups" && find . -mindepth 1 -maxdepth 1 -type d | sort | tr '\n' ' ')
if [ "$remaining3" = "./20260205T000000Z ./20260206T000000Z " ]; then
	pass "test 3: of 6 recent backup events, the newest 2 remain"
else
	fail "test 3: expected the newest 2 recent backup events, got: $remaining3"
fi
[ -f "$recent_file" ] && pass "test 3: a recent loose backup file stays (small files keep the 7-day rule)" \
	|| fail "test 3: a recent loose backup file was deleted"

# =========================================================================
# Test 3b (Run 23): under critical disk pressure our backups go before the
#     user's print files - down to the newest one
# =========================================================================

t3b="$WORK/t3b"
mkdir -p "$t3b/system/migration-backups"
for n in 1 2 3; do
	mkdir -p "$t3b/system/migration-backups/2026020${n}T000000Z/klipper"
done
run_fn "$t3b" "prune_migration_events 1" >/dev/null 2>&1
remaining3b=$(ls "$t3b/system/migration-backups" | tr '\n' ' ')
[ "$remaining3b" = "20260203T000000Z " ] && pass "test 3b: prune_migration_events 1 keeps only the newest event" \
	|| fail "test 3b: expected only the newest event, got: $remaining3b"
crit=$(sed -n '/-lt "\$CRITICAL_FLOOR_MB"/,/emergency_gcode_cleanup$/p' "$RETENTION_SCRIPT")
case "$crit" in
	*"prune_migration_events 1"*emergency_gcode_cleanup*) pass "test 3b: the critical path prunes backups before print files" ;;
	*) fail "test 3b: the critical path does not prune backups before print files" ;;
esac

# =========================================================================
# Test 4: unrelated files (active config, SAVE_CONFIG, PLR/MCU state,
#     user macros) are never touched
# =========================================================================

t4="$WORK/t4"
mkdir -p "$t4/system/migration-backups" "$t4/printer_data/config/macros" "$t4/mcu"
for n in 1 2 3 4 5; do
	d="$t4/system/migration-backups/2026030${n}T000000Z"
	mkdir -p "$d/klipper"
	age_days_ago 30 "$d"
done
printer_cfg="$t4/printer_data/config/printer.cfg"
{
	echo "[include nebulaos/machine.cfg]"
	echo "#*# <---------------------- SAVE_CONFIG ---------------------->"
	echo "#*# [bltouch]"
	echo "#*# z_offset = 1.755"
} > "$printer_cfg"
age_days_ago 400 "$printer_cfg"
macro_file="$t4/printer_data/config/macros/my_macros.cfg"
echo "[gcode_macro MY_MACRO]" > "$macro_file"
age_days_ago 400 "$macro_file"
mcu_state="$t4/mcu/lifecycle-state.json"
echo '{"state": "SUPPORTED_HW_NATIVE_APP"}' > "$mcu_state"
age_days_ago 400 "$mcu_state"

sum_before=$(cd "$t4" && find printer_data mcu -type f -exec sha256sum {} \; | sort)
run_fn "$t4" "clean_migration_backups; clean_stray_bak_files" >/dev/null 2>&1
sum_after=$(cd "$t4" && find printer_data mcu -type f -exec sha256sum {} \; | sort)
if [ "$sum_before" = "$sum_after" ]; then
	pass "test 4: printer.cfg (with real SAVE_CONFIG), user macros, and MCU state are byte-identical after pruning"
else
	fail "test 4: an unrelated file outside migration-backups was modified"
fi
[ -f "$printer_cfg" ] && [ -f "$macro_file" ] && [ -f "$mcu_state" ] \
	&& pass "test 4: all unrelated files still exist" \
	|| fail "test 4: an unrelated file was deleted"

# =========================================================================
# Test 5: idempotent - running twice produces the same final state
# =========================================================================

t5="$WORK/t5"
mkdir -p "$t5/system/migration-backups"
for n in 1 2 3 4 5 6 7; do
	d="$t5/system/migration-backups/2026040${n}T000000Z"
	mkdir -p "$d/klipper"
	age_days_ago 30 "$d"
done
run_fn "$t5" "clean_migration_backups" >/dev/null 2>&1
after_first=$(find "$t5/system/migration-backups" -mindepth 1 -maxdepth 1 | sort)
run_fn "$t5" "clean_migration_backups" >/dev/null 2>&1
after_second=$(find "$t5/system/migration-backups" -mindepth 1 -maxdepth 1 | sort)
if [ "$after_first" = "$after_second" ]; then
	pass "test 5: second run is a true no-op (idempotent)"
else
	fail "test 5: second run changed the result ($after_first) vs ($after_second)"
fi

# =========================================================================
# Test 6: stray .bak files - narrow pattern, keep newest, age-gated
# =========================================================================

t6="$WORK/t6"
mkdir -p "$t6"
for n in 1 2 3; do
	f="$t6/printer.cfg.pre-legacy-test-${n}.bak"
	echo "legacy backup $n" > "$f"
	age_days_ago 30 "$f"
done
recent_bak="$t6/printer.cfg.pre-legacy-test-recent.bak"
echo "recent legacy backup" > "$recent_bak"
age_days_ago 1 "$recent_bak"
# A file that looks similar but does NOT match the narrow pattern - must
# never be touched (proves this is not a broad "*.bak" glob).
other_bak="$t6/some_users_own_file.bak"
echo "not ours" > "$other_bak"
age_days_ago 400 "$other_bak"

run_fn "$t6" "clean_stray_bak_files" >/dev/null 2>&1
remaining_legacy=$(find "$t6" -maxdepth 1 -name 'printer.cfg.pre-legacy-test-*.bak' | wc -l)
if [ "$remaining_legacy" = "2" ]; then
	pass "test 6: exactly 2 stray legacy .bak files remain (1 newest-of-old kept + 1 recent, both protected)"
else
	fail "test 6: expected 2 remaining stray .bak files, got $remaining_legacy"
fi
[ -f "$recent_bak" ] && pass "test 6: the recent (<7 day) legacy .bak file was never touched" \
	|| fail "test 6: the recent legacy .bak file was deleted"
[ -f "$other_bak" ] && pass "test 6: a non-matching .bak file (not this project's own naming convention) was never touched - no broad glob" \
	|| fail "test 6: a file outside the narrow printer.cfg.pre-*.bak pattern was deleted"

# =========================================================================
# Test 7: mainsail-namespace-backups pruned with the same keep=2 policy
# =========================================================================

t7="$WORK/t7"
mkdir -p "$t7/system/mainsail-namespace-backups"
for n in 1 2 3 4; do
	f="$t7/system/mainsail-namespace-backups/mainsail-namespace.2026050${n}T000000Z.json"
	echo '{"result": {"value": {}}}' > "$f"
	age_days_ago 30 "$f"
done
run_fn "$t7" "clean_mainsail_namespace_backups" >/dev/null 2>&1
remaining7=$(find "$t7/system/mainsail-namespace-backups" -mindepth 1 -maxdepth 1 -type f | wc -l)
if [ "$remaining7" = "2" ]; then
	pass "test 7: exactly 2 mainsail-namespace-backups remain out of 4"
else
	fail "test 7: expected 2 remaining, got $remaining7"
fi

# =========================================================================
# Test 8: pruning runs (and helps) even under simulated low free space -
#     never gated on disk pressure, since freeing space is always safe
# =========================================================================

t8="$WORK/t8"
mkdir -p "$t8/system/migration-backups"
for n in 1 2 3 4 5; do
	d="$t8/system/migration-backups/2026060${n}T000000Z"
	mkdir -p "$d/klipper"
	age_days_ago 30 "$d"
done
# free_mb() shells out to `df -m` against the real filesystem the sandbox
# lives on - this test does not need to fake that low-disk output itself,
# it only needs to prove clean_migration_backups() takes no free_mb/
# CRITICAL_FLOOR/CAUTION_FLOOR input at all, so it cannot be silently
# skipped by a disk-pressure branch the way emergency_gcode_cleanup() is
# deliberately gated. Grep the function body itself for that.
if grep -A40 '^clean_migration_backups()' "$RETENTION_SCRIPT" | grep -q 'free_mb\|CRITICAL_FLOOR\|CAUTION_FLOOR'; then
	fail "test 8: clean_migration_backups references disk-pressure state - it must run unconditionally, freeing space is always safe"
else
	pass "test 8: clean_migration_backups has no disk-pressure gating - runs unconditionally"
fi
run_fn "$t8" "clean_migration_backups" >/dev/null 2>&1
remaining8=$(find "$t8/system/migration-backups" -mindepth 1 -maxdepth 1 -type d | wc -l)
if [ "$remaining8" = "2" ]; then
	pass "test 8: pruning still completed correctly (2 remaining) with no disk-pressure input"
else
	fail "test 8: expected 2 remaining, got $remaining8"
fi

echo ""
echo "nebulaos-retention-migration-backup-pruning-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
