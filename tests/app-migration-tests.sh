#!/bin/sh
#
# Offline, repeatable tests for S04nebulaos-migrate (Clean-Update + Virgin
# Baseline mission, Phase 3). Same fixture convention as
# tests/factory-seed-git-tests.sh: real, locally-built git repositories
# under a temp directory, never touching GitHub or a real device. Sources
# S04nebulaos-migrate with S04NEBULAOS_MIGRATE_NO_AUTORUN=1 (same seam
# pattern as S04's own NO_AUTORUN convention) and SEEDS/APPS/SYSTEM/
# LOCKDIR pointed at fixture directories.
#
# Usage: sh tests/app-migration-tests.sh

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

# The S04 scripts source this shared reader (audit F-06). Exported once
# here so every `env ... sh -c ". $SCRIPT"` invocation below inherits it;
# on a device it is /etc/nebulaos-seed-manifest.sh and this is a no-op.
export SEED_MANIFEST_LIB="${SEED_MANIFEST_LIB:-$SCRIPT_DIR/../scripts/build/overlay/etc/nebulaos-seed-manifest.sh}"
# Points every sourced init script's own GATE_LIB override at the real,
# tracked shared gate (not the real device path /etc/nebulaos-
# maintenance-gate.sh, which does not exist on a dev machine) - exported
# once so every `env ... sh -c` call below inherits it automatically.
export GATE_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh"
MAKE_ARCHIVE_LIB="$REPO_ROOT/scripts/build/lib/make-seed-archive.sh"
MIGRATE_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate"
FACTORY_SEED_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-factory-seed"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/app-migration-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: app-migration-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

build_real_repo() {
	dir="$1"; branch="$2"; origin_bare="$3"; msg="${4:-commit}"
	rm -rf "$dir"
	mkdir -p "$dir"
	git -C "$dir" init -q -b "$branch"
	echo "$msg" > "$dir/file.txt"
	git -C "$dir" add -A
	git -C "$dir" commit -q -m "$msg"
	[ -n "$origin_bare" ] && git -C "$dir" remote add origin "$origin_bare"
}

build_bare_remote() {
	bare="$1"; src="$2"
	rm -rf "$bare"
	git clone -q --bare "$src" "$bare"
}

. "$MAKE_ARCHIVE_LIB"

# --- fixtures shared by several tests -----------------------------------

# Must match the origin reseed_git_app() in S04nebulaos-migrate itself
# hardcodes for klipper - the archive's baked-in origin is checked
# against this exact string, independent of where its objects actually
# came from (make_seed_archive sets remote.origin.url directly; it is
# never fetched from during a real device seed).
#
# Phase 1 no-fork migration (2026-08-17): official Klipper3d/klipper. Not a
# cosmetic string change - reseed_git_app() genuinely verifies the seeded
# checkout's baked-in origin against this exact value and rejects a
# mismatch, so this constant is what makes "the device really did end up
# pointed at official Klipper" a tested property rather than a claim.
KLIPPER_PROD_ORIGIN="https://github.com/Klipper3d/klipper.git"
EXTENSIONS_PROD_ORIGIN="https://github.com/NebulaOS-KE/NebulaOS-klipper-extensions.git"

setup_seeds() {
	seeds_dir="$1"
	src_repo="$WORK/src-repo"
	ext_repo="$WORK/src-ext-repo"
	bare="$WORK/bare-origin.git"
	mkdir -p "$seeds_dir"
	build_real_repo "$src_repo" master "" "v2-content"
	build_bare_remote "$bare" "$src_repo"
	make_seed_archive "$src_repo" master "$KLIPPER_PROD_ORIGIN" "$seeds_dir/klipper.tar.gz" > "$WORK/seed-commit.txt"
	seed_commit=$(cat "$WORK/seed-commit.txt")

	# The extension set is an ordinary third image-owned component, so every
	# migration fixture needs one - a device with Klipper but no extensions
	# is exactly the incomplete pair the migration path refuses to promote.
	build_real_repo "$ext_repo" main "" "extensions-v2"
	make_seed_archive "$ext_repo" main "$EXTENSIONS_PROD_ORIGIN" \
		"$seeds_dir/nebulaos-klipper-extensions.tar.gz" > "$WORK/ext-seed-commit.txt"
	ext_seed_commit=$(cat "$WORK/ext-seed-commit.txt")

	cat > "$seeds_dir/seed-manifest.json" <<EOF
{
  "migration_version": "gen-v2",
  "seeds": {
    "klipper": {"seed_commit": "$seed_commit"},
    "nebulaos-klipper-extensions": {"branch": "main", "seed_commit": "$ext_seed_commit"}
  }
}
EOF
	echo "$bare"
}

# --- Test 1: json_get() extracts flat fields correctly -------------------

test_json_get() {
	f="$WORK/sample.json"
	cat > "$f" <<'EOF'
{
  "migration_version": "abc123",
  "build_date": "2026-08-08T00:00:00Z"
}
EOF
	result=$(env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 sh -c ". '$MIGRATE_SCRIPT'; json_get '$f' migration_version")
	if [ "$result" = "abc123" ]; then
		pass "json_get extracts migration_version correctly"
	else
		fail "json_get expected 'abc123', got '$result'"
	fi
}

# --- Test 2: fresh namespace (no existing klipper) - baseline only, no reseed ---

test_fresh_namespace() {
	SEEDS_DIR="$WORK/t2-seeds"; APPS_DIR="$WORK/t2-apps"; SYSTEM_DIR="$WORK/t2-system"
	rm -rf "$SEEDS_DIR" "$APPS_DIR" "$SYSTEM_DIR"
	mkdir -p "$APPS_DIR" "$SYSTEM_DIR"
	setup_seeds "$SEEDS_DIR" > /dev/null
	# No $APPS_DIR/klipper/.git - simulates factory-seed not having run
	# yet, or a namespace this script has never touched.
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$SEEDS_DIR" APPS="$APPS_DIR" SYSTEM="$SYSTEM_DIR" LOCKDIR="$WORK/no-lock" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/t2.log" 2>&1

	if [ -f "$SYSTEM_DIR/app-generation.json" ] && [ ! -d "$APPS_DIR/klipper" ]; then
		pass "fresh namespace: records baseline generation without attempting a reseed"
	else
		fail "fresh namespace: expected generation file written and no klipper dir created ($(cat "$WORK/t2.log"))"
	fi
}

# --- Test 3: matching generation - no-op, existing checkout untouched ---

test_matching_generation_noop() {
	SEEDS_DIR="$WORK/t3-seeds"; APPS_DIR="$WORK/t3-apps"; SYSTEM_DIR="$WORK/t3-system"
	rm -rf "$SEEDS_DIR" "$APPS_DIR" "$SYSTEM_DIR"
	mkdir -p "$APPS_DIR" "$SYSTEM_DIR"
	setup_seeds "$SEEDS_DIR" > /dev/null
	build_real_repo "$APPS_DIR/klipper" master "" "existing-content"
	echo '{"migration_version": "gen-v2"}' > "$SYSTEM_DIR/app-generation.json"
	before_hash=$(git -C "$APPS_DIR/klipper" rev-parse HEAD)

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$SEEDS_DIR" APPS="$APPS_DIR" SYSTEM="$SYSTEM_DIR" LOCKDIR="$WORK/no-lock" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/t3.log" 2>&1

	after_hash=$(git -C "$APPS_DIR/klipper" rev-parse HEAD)
	if [ "$before_hash" = "$after_hash" ] && grep -q "already matches" "$WORK/t3.log"; then
		pass "matching generation: no-op, existing checkout left untouched"
	else
		fail "matching generation: expected no-op ($(cat "$WORK/t3.log"))"
	fi
}

# --- Test 4: mismatched generation - real migration happens -------------

test_migration_happens() {
	SEEDS_DIR="$WORK/t4-seeds"; APPS_DIR="$WORK/t4-apps"; SYSTEM_DIR="$WORK/t4-system"
	rm -rf "$SEEDS_DIR" "$APPS_DIR" "$SYSTEM_DIR"
	mkdir -p "$APPS_DIR" "$SYSTEM_DIR"
	setup_seeds "$SEEDS_DIR" > /dev/null
	# Existing installed checkout: same real production origin as the new
	# seed, but an OLDER commit - a real stand-in for "an
	# already-provisioned device, one generation behind."
	build_real_repo "$APPS_DIR/klipper" master "$KLIPPER_PROD_ORIGIN" "old-content"
	echo '{"migration_version": "gen-v1"}' > "$SYSTEM_DIR/app-generation.json"
	old_hash=$(git -C "$APPS_DIR/klipper" rev-parse HEAD)
	expected_new_hash=$(git -C "$SEEDS_DIR/../src-repo" rev-parse HEAD 2>/dev/null || \
		grep -o '"seed_commit": "[^"]*"' "$SEEDS_DIR/seed-manifest.json" | sed 's/.*"\([a-f0-9]*\)"$/\1/')

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$SEEDS_DIR" APPS="$APPS_DIR" SYSTEM="$SYSTEM_DIR" LOCKDIR="$WORK/no-lock" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/t4.log" 2>&1

	new_hash=$(git -C "$APPS_DIR/klipper" rev-parse HEAD 2>/dev/null)
	backup_count=$(find "$SYSTEM_DIR/migration-backups" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
	recorded=$(grep -o '"migration_version": "[^"]*"' "$SYSTEM_DIR/app-generation.json" 2>/dev/null)

	if [ "$new_hash" != "$old_hash" ] && [ "$new_hash" = "$expected_new_hash" ] && \
		[ "$backup_count" -ge 1 ] && [ "$recorded" = '"migration_version": "gen-v2"' ]; then
		pass "migration: old checkout backed up, new checkout matches the seed archive's real commit, generation recorded"
	else
		fail "migration: old=$old_hash new=$new_hash expected=$expected_new_hash backups=$backup_count recorded='$recorded' ($(cat "$WORK/t4.log"))"
	fi

	# The backup must contain the OLD content, not the new - a real
	# rollback source, not just an empty marker directory.
	backup_dir=$(find "$SYSTEM_DIR/migration-backups" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)
	if [ -n "$backup_dir" ] && [ "$(git -C "$backup_dir/klipper" rev-parse HEAD 2>/dev/null)" = "$old_hash" ]; then
		pass "migration: backup directory contains the real pre-migration checkout"
	else
		fail "migration: backup directory missing or does not contain the old checkout"
	fi
}

# --- Test 5: failure path - missing archive leaves existing untouched ---

test_failure_leaves_existing_untouched() {
	SEEDS_DIR="$WORK/t5-seeds"; APPS_DIR="$WORK/t5-apps"; SYSTEM_DIR="$WORK/t5-system"
	rm -rf "$SEEDS_DIR" "$APPS_DIR" "$SYSTEM_DIR"
	mkdir -p "$APPS_DIR" "$SYSTEM_DIR"
	setup_seeds "$SEEDS_DIR" > /dev/null
	rm -f "$SEEDS_DIR/klipper.tar.gz"
	build_real_repo "$APPS_DIR/klipper" master "" "old-content"
	echo '{"migration_version": "gen-v1"}' > "$SYSTEM_DIR/app-generation.json"
	old_hash=$(git -C "$APPS_DIR/klipper" rev-parse HEAD)

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$SEEDS_DIR" APPS="$APPS_DIR" SYSTEM="$SYSTEM_DIR" LOCKDIR="$WORK/no-lock" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/t5.log" 2>&1

	new_hash=$(git -C "$APPS_DIR/klipper" rev-parse HEAD 2>/dev/null)
	recorded=$(grep -o '"migration_version": "[^"]*"' "$SYSTEM_DIR/app-generation.json" 2>/dev/null)
	if [ "$new_hash" = "$old_hash" ] && [ "$recorded" = '"migration_version": "gen-v1"' ]; then
		pass "failure path: missing archive leaves the existing checkout and generation record untouched (will retry next boot)"
	else
		fail "failure path: existing installation was modified despite the archive being missing ($(cat "$WORK/t5.log"))"
	fi
}

# --- Test 6: boot-sequence integration - factory-seed then migrate must ---
# --- NOT redundantly re-back-up/re-reseed what factory-seed just seeded ---

test_no_redundant_reseed_after_fresh_factory_seed() {
	SEEDS_DIR="$WORK/t6-seeds"; APPS_DIR="$WORK/t6-apps"; SYSTEM_DIR="$WORK/t6-system"
	rm -rf "$SEEDS_DIR" "$APPS_DIR" "$SYSTEM_DIR"
	mkdir -p "$APPS_DIR" "$SYSTEM_DIR"
	setup_seeds "$SEEDS_DIR" > /dev/null

	# Same S04nebulaos-factory-seed function real boot uses to seed klipper
	# into a fresh namespace - sourced directly (NO_AUTORUN), same
	# convention tests/factory-seed-git-tests.sh already uses.
	env S04NEBULAOS_FACTORY_SEED_NO_AUTORUN=1 SEEDS="$SEEDS_DIR" APPS="$APPS_DIR" SYSTEM="$SYSTEM_DIR" \
		sh -c ". '$FACTORY_SEED_SCRIPT'; seed_git_app klipper master '$KLIPPER_PROD_ORIGIN'; seed_git_app nebulaos-klipper-extensions main '$EXTENSIONS_PROD_ORIGIN'; record_initial_generation" \
		> "$WORK/t6-seed.log" 2>&1
	seeded_hash=$(git -C "$APPS_DIR/klipper" rev-parse HEAD 2>/dev/null)

	if [ ! -f "$SYSTEM_DIR/app-generation.json" ]; then
		fail "boot sequence: record_initial_generation did not write a generation file after a fresh seed ($(cat "$WORK/t6-seed.log"))"
		return
	fi

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$SEEDS_DIR" APPS="$APPS_DIR" SYSTEM="$SYSTEM_DIR" LOCKDIR="$WORK/no-lock" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/t6-migrate.log" 2>&1

	after_hash=$(git -C "$APPS_DIR/klipper" rev-parse HEAD 2>/dev/null)
	backup_count=$(find "$SYSTEM_DIR/migration-backups" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)

	if [ "$after_hash" = "$seeded_hash" ] && [ "$backup_count" -eq 0 ] && grep -q "already matches" "$WORK/t6-migrate.log"; then
		pass "boot sequence: migrate makes no redundant backup/reseed of content factory-seed just installed"
	else
		fail "boot sequence: expected a clean no-op, got backups=$backup_count seeded=$seeded_hash after=$after_hash ($(cat "$WORK/t6-migrate.log"))"
	fi
}

# --- Test 7: a stale update-transaction lock must not permanently block ---
# --- a genuinely virgin first boot's provisioning ----------------------

test_stale_lock_does_not_block_virgin_first_boot() {
	SEEDS_DIR="$WORK/t7-seeds"; APPS_DIR="$WORK/t7-apps"; SYSTEM_DIR="$WORK/t7-system"
	LOCKDIR="$WORK/t7-locks"
	rm -rf "$SEEDS_DIR" "$APPS_DIR" "$SYSTEM_DIR" "$LOCKDIR"
	mkdir -p "$APPS_DIR" "$SYSTEM_DIR" "$LOCKDIR"
	setup_seeds "$SEEDS_DIR" > /dev/null

	# The exact real-world incident this test exists to prevent
	# recurring: a leftover lock from BEFORE this namespace's own
	# apps/klipper was ever seeded (found live, Virgin Flash +
	# Verification mission, 2026-08-08 - a lock that survived an
	# off-device persistent-state reset because the reset's own scope
	# missed updates/locks/). Deliberately a real, non-empty file (an
	# empty klipper.lock is exactly what nebulaos-update-supervisor.sh
	# itself creates), not a directory placeholder.
	echo -n "" > "$LOCKDIR/klipper.lock"

	# maintenance_gate_ok() is what real boot calls before ever
	# attempting to seed - test it exactly as S04nebulaos-factory-seed's
	# own start() does: gate first, only seed if it returns success.
	env SEEDS="$SEEDS_DIR" APPS="$APPS_DIR" SYSTEM="$SYSTEM_DIR" LOCKDIR="$LOCKDIR" \
		S04NEBULAOS_FACTORY_SEED_NO_AUTORUN=1 \
		sh -c ". '$FACTORY_SEED_SCRIPT'; \
			if maintenance_gate_ok; then \
				echo GATE_PASSED; \
				seed_git_app klipper master '$KLIPPER_PROD_ORIGIN'; \
				seed_git_app nebulaos-klipper-extensions main '$EXTENSIONS_PROD_ORIGIN'; \
				record_initial_generation; \
			else \
				echo GATE_BLOCKED; \
			fi" \
		> "$WORK/t7.log" 2>&1

	if ! grep -q "GATE_PASSED" "$WORK/t7.log"; then
		fail "stale lock: virgin first boot's own maintenance gate refused to proceed despite an unseeded namespace ($(cat "$WORK/t7.log"))"
		return
	fi
	pass "stale lock: virgin first boot's gate correctly distinguishes a stale lock (unseeded namespace) from a real one"

	if [ ! -e "$APPS_DIR/klipper/.git" ]; then
		fail "stale lock: provisioning did not complete - apps/klipper was never seeded ($(cat "$WORK/t7.log"))"
	else
		pass "stale lock: provisioning completed with zero manual intervention (no test code ever removed the lock itself)"
	fi

	if [ -f "$SYSTEM_DIR/app-generation.json" ]; then
		pass "stale lock: generation still recorded correctly despite the stale lock's presence"
	else
		fail "stale lock: app-generation.json missing after otherwise-successful provisioning"
	fi
}

# --- Test 8: the SAME stale-lock scenario, but on an ALREADY-seeded ------
# --- namespace, must still block exactly as before - the fix is narrow --

test_stale_lock_still_blocks_when_namespace_already_seeded() {
	SEEDS_DIR="$WORK/t8-seeds"; APPS_DIR="$WORK/t8-apps"; SYSTEM_DIR="$WORK/t8-system"
	LOCKDIR="$WORK/t8-locks"
	rm -rf "$SEEDS_DIR" "$APPS_DIR" "$SYSTEM_DIR" "$LOCKDIR"
	mkdir -p "$SYSTEM_DIR" "$LOCKDIR"
	setup_seeds "$SEEDS_DIR" > /dev/null
	build_real_repo "$APPS_DIR/klipper" master "$KLIPPER_PROD_ORIGIN" "already-seeded-content"
	echo -n "" > "$LOCKDIR/klipper.lock"

	env SEEDS="$SEEDS_DIR" APPS="$APPS_DIR" SYSTEM="$SYSTEM_DIR" LOCKDIR="$LOCKDIR" \
		S04NEBULAOS_FACTORY_SEED_NO_AUTORUN=1 \
		sh -c ". '$FACTORY_SEED_SCRIPT'; \
			if maintenance_gate_ok; then echo GATE_PASSED; else echo GATE_BLOCKED; fi" \
		> "$WORK/t8.log" 2>&1

	if grep -q "GATE_BLOCKED" "$WORK/t8.log" && [ -e "$LOCKDIR/klipper.lock" ]; then
		pass "stale lock: an ALREADY-seeded namespace's lock is still correctly treated as a real, blocking, human-review-needed lock - the fix stays narrow"
	else
		fail "stale lock: an already-seeded namespace's lock was incorrectly bypassed - this would silently defeat nebulaos-update-supervisor.sh's own deliberate 'needs human review' failed-update safety property ($(cat "$WORK/t8.log"))"
	fi
}

test_json_get
test_fresh_namespace
test_matching_generation_noop
test_migration_happens
test_failure_leaves_existing_untouched
test_no_redundant_reseed_after_fresh_factory_seed
test_stale_lock_does_not_block_virgin_first_boot
test_stale_lock_still_blocks_when_namespace_already_seeded

echo
echo "app-migration-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
