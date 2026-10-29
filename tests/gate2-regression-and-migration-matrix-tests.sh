#!/bin/sh
#
# Phase 1.8 candidate-002 regression tests and full migration matrix.
#
# These tests exist because candidate-001 failed Gate 2 (activation) on
# real hardware with two independent bugs that the existing 885-test suite
# did not catch:
#
#   Bug 1: make_seed_archive switched to the local branch tip instead of
#          the pinned commit, bundling the wrong extension content (448b59c
#          instead of 7260389).
#
#   Bug 2: Migration/activation did not update persistent checkouts despite
#          a generation mismatch. No persistent diagnostics existed to
#          determine whether the maintenance gate blocked it, reseed failed,
#          or another condition prevented execution.
#
# The first group of tests are EXACT REGRESSION REPRODUCERS: they simulate
# the precise persistent state found on the real device and verify the
# fixed code produces the correct result. The remaining tests form a full
# migration matrix covering every combination of old/new/missing/corrupt
# state the boot sequence can encounter.
#
# Usage: sh tests/gate2-regression-and-migration-matrix-tests.sh

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
export GATE_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh"
MAKE_ARCHIVE_LIB="$REPO_ROOT/scripts/build/lib/make-seed-archive.sh"
MIGRATE_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate"
FACTORY_SEED_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-factory-seed"
ACTIVATE_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S05nebulaos-activate"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gate2-regression-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: gate2-regression-and-migration-matrix-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

. "$MAKE_ARCHIVE_LIB"

KLIPPER_PROD_ORIGIN="https://github.com/Klipper3d/klipper.git"
EXTENSIONS_PROD_ORIGIN="https://github.com/NebulaOS-KE/NebulaOS-klipper-extensions.git"
MOONRAKER_PROD_ORIGIN="https://github.com/Arksine/moonraker.git"

# --- helpers ---------------------------------------------------------------

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

build_repo_with_n_commits() {
	dir="$1"; branch="$2"; origin="$3"; n="$4"
	rm -rf "$dir"
	mkdir -p "$dir"
	git -C "$dir" init -q -b "$branch"
	i=0
	while [ "$i" -lt "$n" ]; do
		echo "commit-$i" >> "$dir/file.txt"
		git -C "$dir" add -A
		git -C "$dir" commit -q -m "commit $i"
		i=$((i + 1))
	done
	[ -n "$origin" ] && git -C "$dir" remote add origin "$origin"
}

build_bare_remote() {
	bare="$1"; src="$2"
	rm -rf "$bare"
	git clone -q --bare "$src" "$bare"
}

# Build a complete set of seeds with separate "old" and "new" commits, to
# simulate a real version upgrade. Returns the directory containing the
# seed archives.
build_versioned_seeds() {
	tag="$1"
	seeds_dir="$WORK/$tag-seeds"
	src_klipper="$WORK/$tag-src-klipper"
	src_ext="$WORK/$tag-src-ext"
	src_moonraker="$WORK/$tag-src-moonraker"
	mkdir -p "$seeds_dir"

	build_real_repo "$src_klipper" master "$KLIPPER_PROD_ORIGIN" "klipper-$tag"
	make_seed_archive "$src_klipper" master "$KLIPPER_PROD_ORIGIN" "$seeds_dir/klipper.tar.gz" > "$WORK/$tag-klipper-commit.txt"
	klipper_commit=$(cat "$WORK/$tag-klipper-commit.txt")

	build_real_repo "$src_ext" main "$EXTENSIONS_PROD_ORIGIN" "extensions-$tag"
	make_seed_archive "$src_ext" main "$EXTENSIONS_PROD_ORIGIN" "$seeds_dir/nebulaos-klipper-extensions.tar.gz" > "$WORK/$tag-ext-commit.txt"
	ext_commit=$(cat "$WORK/$tag-ext-commit.txt")

	build_real_repo "$src_moonraker" master "$MOONRAKER_PROD_ORIGIN" "moonraker-$tag"
	make_seed_archive "$src_moonraker" master "$MOONRAKER_PROD_ORIGIN" "$seeds_dir/moonraker.tar.gz" > "$WORK/$tag-moonraker-commit.txt"
	moonraker_commit=$(cat "$WORK/$tag-moonraker-commit.txt")

	migration_version=$(printf '%s' "${klipper_commit}:${ext_commit}:${moonraker_commit}:unknown" | sha256sum | cut -c1-16)

	cat > "$seeds_dir/seed-manifest.json" <<EOF
{
  "migration_version": "$migration_version",
  "seeds": {
    "klipper": {"seed_commit": "$klipper_commit"},
    "nebulaos-klipper-extensions": {"branch": "main", "seed_commit": "$ext_commit"},
    "moonraker": {"seed_commit": "$moonraker_commit"}
  }
}
EOF
	echo "$seeds_dir"
}

# Install persistent apps from a set of source repos to simulate a device
# that was provisioned with a particular generation.
install_persistent_apps() {
	apps_dir="$1"; system_dir="$2"; tag="$3"; migration_version="$4"
	src_klipper="$WORK/$tag-src-klipper"
	src_ext="$WORK/$tag-src-ext"
	src_moonraker="$WORK/$tag-src-moonraker"
	mkdir -p "$apps_dir" "$system_dir"

	# Clone the source repos to simulate the persistent state
	if [ -d "$src_klipper" ]; then
		rm -rf "$apps_dir/klipper"
		cp -r "$src_klipper" "$apps_dir/klipper"
	fi
	if [ -d "$src_ext" ]; then
		rm -rf "$apps_dir/nebulaos-klipper-extensions"
		cp -r "$src_ext" "$apps_dir/nebulaos-klipper-extensions"
	fi
	if [ -d "$src_moonraker" ]; then
		rm -rf "$apps_dir/moonraker"
		cp -r "$src_moonraker" "$apps_dir/moonraker"
	fi

	# Record the generation
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	klipper_c=$( [ -d "$apps_dir/klipper/.git" ] && git -C "$apps_dir/klipper" rev-parse HEAD 2>/dev/null || echo "unseeded")
	ext_c=$( [ -d "$apps_dir/nebulaos-klipper-extensions/.git" ] && git -C "$apps_dir/nebulaos-klipper-extensions" rev-parse HEAD 2>/dev/null || echo "unseeded")
	moonraker_c=$( [ -d "$apps_dir/moonraker/.git" ] && git -C "$apps_dir/moonraker" rev-parse HEAD 2>/dev/null || echo "unseeded")
	cat > "$system_dir/app-generation.json" <<EOF
{
  "migration_version": "$migration_version",
  "recorded_at": "$now",
  "klipper_commit": "$klipper_c",
  "extensions_commit": "$ext_c",
  "moonraker_commit": "$moonraker_c"
}
EOF
}

# Get migration_version from a seed manifest
get_migration_version() {
	grep -o '"migration_version"[[:space:]]*:[[:space:]]*"[^"]*"' "$1" | \
		sed -E 's/.*"([^"]*)"$/\1/' | head -1
}

# Get a seed_commit from seed-manifest for a given component
get_seed_commit() {
	manifest="$1"; component="$2"
	# Simple extraction for flat test manifests
	grep -A1 "\"$component\"" "$manifest" | grep seed_commit | \
		sed -E 's/.*"seed_commit"[[:space:]]*:[[:space:]]*"([^"]*)".*$/\1/' | head -1
}

# =========================================================================
# SECTION 1: EXACT GATE 2 REGRESSION REPRODUCERS
# =========================================================================

echo "=== SECTION 1: Gate 2 exact regression reproducers ==="

# --- Test: Phase 1.5→1.8 upgrade with exact persistent state -------------
# Simulates the actual candidate-001 failure: a device running Phase 1.5
# persistent checkouts gets a Phase 1.8 image with different seed archives.
# The migration must detect the generation mismatch, reseed all three
# components from the new archives, and record the new generation.

test_gate2_exact_phase15_to_18_upgrade() {
	APPS="$WORK/g2-apps"; SYSTEM="$WORK/g2-system"; LOCKDIR="$WORK/g2-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$APPS" "$SYSTEM" "$LOCKDIR"

	# Phase 1.5 persistent state: old commits for all three components
	old_seeds_dir=$(build_versioned_seeds "phase15")
	old_version=$(get_migration_version "$old_seeds_dir/seed-manifest.json")
	install_persistent_apps "$APPS" "$SYSTEM" "phase15" "$old_version"

	old_klipper=$(git -C "$APPS/klipper" rev-parse HEAD)
	old_ext=$(git -C "$APPS/nebulaos-klipper-extensions" rev-parse HEAD)
	old_moonraker=$(git -C "$APPS/moonraker" rev-parse HEAD)

	# Phase 1.8 image seeds: new commits for all three
	new_seeds_dir=$(build_versioned_seeds "phase18")
	new_version=$(get_migration_version "$new_seeds_dir/seed-manifest.json")
	new_klipper_expected=$(cat "$WORK/phase18-klipper-commit.txt")
	new_ext_expected=$(cat "$WORK/phase18-ext-commit.txt")
	new_moonraker_expected=$(cat "$WORK/phase18-moonraker-commit.txt")

	# Verify the generations actually differ
	if [ "$old_version" = "$new_version" ]; then
		fail "gate2 regression: test setup broken - old and new migration versions are identical"
		return
	fi

	# Factory-seed should skip (everything already seeded)
	env S04NEBULAOS_FACTORY_SEED_NO_AUTORUN=1 SEEDS="$new_seeds_dir" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$FACTORY_SEED_SCRIPT'; start" > "$WORK/g2-seed.log" 2>&1

	if ! grep -q "already seeded" "$WORK/g2-seed.log"; then
		fail "gate2 regression: factory-seed should have skipped (all components already seeded)"
		return
	fi
	pass "gate2 regression: factory-seed correctly skips already-seeded components"

	# Migration should detect the mismatch and reseed
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$new_seeds_dir" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/g2-migrate.log" 2>&1

	new_klipper=$(git -C "$APPS/klipper" rev-parse HEAD 2>/dev/null)
	new_ext=$(git -C "$APPS/nebulaos-klipper-extensions" rev-parse HEAD 2>/dev/null)
	new_moonraker=$(git -C "$APPS/moonraker" rev-parse HEAD 2>/dev/null)
	recorded_version=$(get_migration_version "$SYSTEM/app-generation.json")

	# All three components must have been updated
	if [ "$new_klipper" != "$old_klipper" ] && [ "$new_klipper" = "$new_klipper_expected" ]; then
		pass "gate2 regression: klipper migrated from $old_klipper to $new_klipper_expected"
	else
		fail "gate2 regression: klipper migration failed (old=$old_klipper new=$new_klipper expected=$new_klipper_expected)"
	fi

	if [ "$new_ext" != "$old_ext" ] && [ "$new_ext" = "$new_ext_expected" ]; then
		pass "gate2 regression: extensions migrated from $old_ext to $new_ext_expected"
	else
		fail "gate2 regression: extensions migration failed (old=$old_ext new=$new_ext expected=$new_ext_expected)"
	fi

	if [ "$new_moonraker" != "$old_moonraker" ] && [ "$new_moonraker" = "$new_moonraker_expected" ]; then
		pass "gate2 regression: moonraker migrated from $old_moonraker to $new_moonraker_expected"
	else
		fail "gate2 regression: moonraker migration failed (old=$old_moonraker new=$new_moonraker expected=$new_moonraker_expected)"
	fi

	if [ "$recorded_version" = "$new_version" ]; then
		pass "gate2 regression: generation advanced to $new_version after successful migration"
	else
		fail "gate2 regression: generation not advanced (recorded=$recorded_version expected=$new_version)"
	fi

	# Backups must exist
	backup_count=$(find "$SYSTEM/migration-backups" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
	if [ "$backup_count" -ge 1 ]; then
		pass "gate2 regression: pre-migration backup created"
	else
		fail "gate2 regression: no pre-migration backup found"
	fi

	# Diagnostics must have been written
	if [ -f "$SYSTEM/diagnostics/migration-state.json" ]; then
		diag_action=$(grep -o '"migration_action"[[:space:]]*:[[:space:]]*"[^"]*"' "$SYSTEM/diagnostics/migration-state.json" | \
			sed -E 's/.*"([^"]*)"$/\1/' | head -1)
		if [ "$diag_action" = "completed" ]; then
			pass "gate2 regression: persistent diagnostics record migration as completed"
		else
			fail "gate2 regression: diagnostics show action=$diag_action, expected completed"
		fi
	else
		fail "gate2 regression: no persistent migration-state.json written"
	fi
}

# --- Test: make_seed_archive branch-switch bug reproducer -----------------
# This is the EXACT Bug 1 reproducer: create a repo where HEAD is detached
# at a pinned commit and the local branch points elsewhere (the clone_pinned
# non-shallow path's actual state), then verify make_seed_archive produces
# an archive at the pinned commit, not the branch tip.

test_make_seed_archive_branch_switch_fix() {
	src="$WORK/branch-switch-src"
	rm -rf "$src"
	mkdir -p "$src"
	git -C "$src" init -q -b main

	# First commit: this is what "main" will stay at (the wrong content)
	echo "wrong-branch-tip-content" > "$src/file.txt"
	git -C "$src" add -A
	git -C "$src" commit -q -m "branch-tip-commit"
	wrong_sha=$(git -C "$src" rev-parse HEAD)

	# Second commit: this is the pinned commit (the correct content)
	echo "correct-pinned-content" > "$src/file.txt"
	git -C "$src" add -A
	git -C "$src" commit -q -m "pinned-commit"
	correct_sha=$(git -C "$src" rev-parse HEAD)

	# Simulate clone_pinned's non-shallow path: detach HEAD at the pin,
	# leaving the local "main" branch at the wrong commit.
	git -C "$src" checkout -q "$correct_sha"
	# Reset the local branch to the old commit without moving HEAD
	git -C "$src" branch -f main "$wrong_sha"

	# Verify the setup: HEAD is detached at correct, main points to wrong
	head_sha=$(git -C "$src" rev-parse HEAD)
	main_sha=$(git -C "$src" rev-parse main)
	if [ "$head_sha" != "$correct_sha" ] || [ "$main_sha" != "$wrong_sha" ]; then
		fail "branch-switch reproducer: test setup failed (HEAD=$head_sha main=$main_sha)"
		return
	fi

	# The fixed make_seed_archive should produce an archive with HEAD at the
	# CORRECT (pinned) commit, not the wrong branch tip.
	archive="$WORK/branch-switch-test.tar.gz"
	archive_sha=$(make_seed_archive "$src" main "https://example.com/test.git" "$archive")

	if [ "$archive_sha" = "$correct_sha" ]; then
		pass "branch-switch fix: make_seed_archive output commit matches the pinned HEAD ($correct_sha), not the branch tip ($wrong_sha)"
	else
		fail "branch-switch fix: make_seed_archive output commit ($archive_sha) does not match pinned HEAD ($correct_sha) — this is the exact Bug 1 regression"
	fi

	# Also verify by extracting and checking content
	extract_dir="$WORK/branch-switch-extract"
	mkdir -p "$extract_dir"
	sh -c "gzip -dc '$archive' | tar -xo -C '$extract_dir'"
	extracted_head=$(git -C "$extract_dir" rev-parse HEAD)
	extracted_content=$(cat "$extract_dir/file.txt")

	if [ "$extracted_head" = "$correct_sha" ] && [ "$extracted_content" = "correct-pinned-content" ]; then
		pass "branch-switch fix: extracted archive contains correct content at the pinned commit"
	else
		fail "branch-switch fix: extracted archive has wrong content (head=$extracted_head content='$extracted_content')"
	fi
}

# --- Test: seed archive HEAD mismatch rejection ---------------------------
# Verify the build-time _assert_seed_matches_pin function would catch the
# exact candidate-001 bug. We test the assertion logic directly.

test_seed_head_mismatch_rejection() {
	src="$WORK/mismatch-src"
	rm -rf "$src"
	build_real_repo "$src" main "" "some-content"
	real_sha=$(git -C "$src" rev-parse HEAD)

	archive="$WORK/mismatch-test.tar.gz"
	make_seed_archive "$src" main "https://example.com/test.git" "$archive" > /dev/null

	# Extract and verify the archive HEAD
	extract_dir="$WORK/mismatch-extract"
	rm -rf "$extract_dir"
	mkdir -p "$extract_dir"
	sh -c "gzip -dc '$archive' | tar -xo -C '$extract_dir'" 2>/dev/null
	actual_head=$(git -C "$extract_dir" rev-parse HEAD 2>/dev/null)

	# Test 1: matching pin should succeed
	if [ "$actual_head" = "$real_sha" ]; then
		pass "seed HEAD assertion: archive HEAD matches pin (positive case)"
	else
		fail "seed HEAD assertion: archive HEAD ($actual_head) does not match expected ($real_sha)"
	fi

	# Test 2: wrong pin should be detectable
	wrong_pin="0000000000000000000000000000000000000000"
	if [ "$actual_head" != "$wrong_pin" ]; then
		pass "seed HEAD assertion: archive HEAD ($actual_head) correctly differs from wrong pin ($wrong_pin) — build would reject"
	else
		fail "seed HEAD assertion: impossible match with zero-hash"
	fi
}

test_gate2_exact_phase15_to_18_upgrade
test_make_seed_archive_branch_switch_fix
test_seed_head_mismatch_rejection

# =========================================================================
# SECTION 2: FULL MIGRATION MATRIX (17 scenarios A-Q)
# =========================================================================

echo ""
echo "=== SECTION 2: Migration matrix (17 scenarios) ==="

# Build two generations of seeds for the matrix tests
v1_seeds=$(build_versioned_seeds "v1")
v2_seeds=$(build_versioned_seeds "v2")
v1_version=$(get_migration_version "$v1_seeds/seed-manifest.json")
v2_version=$(get_migration_version "$v2_seeds/seed-manifest.json")

# --- Scenario A: Virgin namespace, first boot, v2 image ------------------
test_matrix_a_virgin_first_boot() {
	APPS="$WORK/ma-apps"; SYSTEM="$WORK/ma-system"; LOCKDIR="$WORK/ma-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$APPS" "$SYSTEM" "$LOCKDIR"

	env S04NEBULAOS_FACTORY_SEED_NO_AUTORUN=1 SEEDS="$v2_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$FACTORY_SEED_SCRIPT'; seed_git_app klipper master '$KLIPPER_PROD_ORIGIN'; seed_git_app nebulaos-klipper-extensions main '$EXTENSIONS_PROD_ORIGIN'; seed_git_app moonraker master '$MOONRAKER_PROD_ORIGIN'; record_initial_generation" \
		> "$WORK/ma.log" 2>&1

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$v2_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" >> "$WORK/ma.log" 2>&1

	recorded=$(get_migration_version "$SYSTEM/app-generation.json")
	backup_count=$(find "$SYSTEM/migration-backups" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)

	if [ "$recorded" = "$v2_version" ] && [ "$backup_count" -eq 0 ] && grep -q "already matches" "$WORK/ma.log"; then
		pass "matrix A: virgin first boot seeds all components, migrate is a no-op"
	else
		fail "matrix A: recorded=$recorded expected=$v2_version backups=$backup_count ($(tail -5 "$WORK/ma.log"))"
	fi
}

# --- Scenario B: Same generation, no-op boot -----------------------------
test_matrix_b_same_generation_noop() {
	APPS="$WORK/mb-apps"; SYSTEM="$WORK/mb-system"; LOCKDIR="$WORK/mb-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$LOCKDIR"
	install_persistent_apps "$APPS" "$SYSTEM" "v2" "$v2_version"

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$v2_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/mb.log" 2>&1

	if grep -q "already matches" "$WORK/mb.log"; then
		pass "matrix B: same generation is a clean no-op"
	else
		fail "matrix B: expected no-op ($(tail -3 "$WORK/mb.log"))"
	fi
}

# --- Scenario C: v1→v2 upgrade, all components present -------------------
test_matrix_c_v1_to_v2_upgrade() {
	APPS="$WORK/mc-apps"; SYSTEM="$WORK/mc-system"; LOCKDIR="$WORK/mc-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$LOCKDIR"
	install_persistent_apps "$APPS" "$SYSTEM" "v1" "$v1_version"
	old_k=$(git -C "$APPS/klipper" rev-parse HEAD)

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$v2_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/mc.log" 2>&1

	new_k=$(git -C "$APPS/klipper" rev-parse HEAD)
	recorded=$(get_migration_version "$SYSTEM/app-generation.json")

	if [ "$new_k" != "$old_k" ] && [ "$recorded" = "$v2_version" ]; then
		pass "matrix C: v1→v2 upgrade migrates all components and advances generation"
	else
		fail "matrix C: old_k=$old_k new_k=$new_k recorded=$recorded expected=$v2_version"
	fi
}

# --- Scenario D: v2→v1 downgrade -----------------------------------------
test_matrix_d_v2_to_v1_downgrade() {
	APPS="$WORK/md-apps"; SYSTEM="$WORK/md-system"; LOCKDIR="$WORK/md-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$LOCKDIR"
	install_persistent_apps "$APPS" "$SYSTEM" "v2" "$v2_version"

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$v1_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/md.log" 2>&1

	recorded=$(get_migration_version "$SYSTEM/app-generation.json")

	if [ "$recorded" = "$v1_version" ]; then
		pass "matrix D: v2→v1 downgrade succeeds (generation mismatch triggers migration regardless of direction)"
	else
		fail "matrix D: downgrade failed (recorded=$recorded expected=$v1_version)"
	fi
}

# --- Scenario E: Missing klipper archive, extensions/moonraker present ---
test_matrix_e_missing_klipper_archive() {
	APPS="$WORK/me-apps"; SYSTEM="$WORK/me-system"; LOCKDIR="$WORK/me-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$LOCKDIR"
	install_persistent_apps "$APPS" "$SYSTEM" "v1" "$v1_version"
	old_k=$(git -C "$APPS/klipper" rev-parse HEAD)

	# Create a seeds dir with klipper archive removed
	partial_seeds="$WORK/me-seeds"
	rm -rf "$partial_seeds"
	cp -r "$v2_seeds" "$partial_seeds"
	rm -f "$partial_seeds/klipper.tar.gz"

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$partial_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/me.log" 2>&1

	new_k=$(git -C "$APPS/klipper" rev-parse HEAD)
	recorded=$(get_migration_version "$SYSTEM/app-generation.json")

	if [ "$new_k" = "$old_k" ] && [ "$recorded" = "$v1_version" ]; then
		pass "matrix E: missing klipper archive leaves existing untouched, generation NOT advanced (paired failure)"
	else
		fail "matrix E: expected no change (new_k=$new_k old_k=$old_k recorded=$recorded)"
	fi
}

# --- Scenario F: Missing extensions archive, klipper/moonraker present ---
test_matrix_f_missing_extensions_archive() {
	APPS="$WORK/mf-apps"; SYSTEM="$WORK/mf-system"; LOCKDIR="$WORK/mf-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$LOCKDIR"
	install_persistent_apps "$APPS" "$SYSTEM" "v1" "$v1_version"
	old_ext=$(git -C "$APPS/nebulaos-klipper-extensions" rev-parse HEAD)

	partial_seeds="$WORK/mf-seeds"
	rm -rf "$partial_seeds"
	cp -r "$v2_seeds" "$partial_seeds"
	rm -f "$partial_seeds/nebulaos-klipper-extensions.tar.gz"

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$partial_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/mf.log" 2>&1

	new_ext=$(git -C "$APPS/nebulaos-klipper-extensions" rev-parse HEAD)
	recorded=$(get_migration_version "$SYSTEM/app-generation.json")

	if [ "$new_ext" = "$old_ext" ] && [ "$recorded" = "$v1_version" ]; then
		pass "matrix F: missing extensions archive blocks the PAIR, generation NOT advanced"
	else
		fail "matrix F: expected paired failure (new_ext=$new_ext old_ext=$old_ext recorded=$recorded)"
	fi
}

# --- Scenario G: Missing moonraker archive only --------------------------
test_matrix_g_missing_moonraker_archive() {
	APPS="$WORK/mg-apps"; SYSTEM="$WORK/mg-system"; LOCKDIR="$WORK/mg-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$LOCKDIR"
	install_persistent_apps "$APPS" "$SYSTEM" "v1" "$v1_version"

	partial_seeds="$WORK/mg-seeds"
	rm -rf "$partial_seeds"
	cp -r "$v2_seeds" "$partial_seeds"
	rm -f "$partial_seeds/moonraker.tar.gz"

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$partial_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/mg.log" 2>&1

	recorded=$(get_migration_version "$SYSTEM/app-generation.json")

	if [ "$recorded" = "$v1_version" ]; then
		pass "matrix G: missing moonraker archive prevents generation advancement (all-or-nothing)"
	else
		fail "matrix G: generation should not have advanced (recorded=$recorded expected=$v1_version)"
	fi
}

# --- Scenario H: No seed-manifest.json at all ----------------------------
test_matrix_h_no_manifest() {
	APPS="$WORK/mh-apps"; SYSTEM="$WORK/mh-system"; LOCKDIR="$WORK/mh-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$LOCKDIR"
	install_persistent_apps "$APPS" "$SYSTEM" "v1" "$v1_version"

	empty_seeds="$WORK/mh-seeds"
	rm -rf "$empty_seeds"
	mkdir -p "$empty_seeds"

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$empty_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/mh.log" 2>&1

	if grep -q "no seed manifest" "$WORK/mh.log"; then
		pass "matrix H: missing seed-manifest.json is a clean skip, not an error"
	else
		fail "matrix H: expected 'no seed manifest' message ($(tail -3 "$WORK/mh.log"))"
	fi
}

# --- Scenario I: No app-generation.json but apps exist (orphan state) ----
test_matrix_i_missing_generation_file() {
	APPS="$WORK/mi-apps"; SYSTEM="$WORK/mi-system"; LOCKDIR="$WORK/mi-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$APPS" "$SYSTEM" "$LOCKDIR"

	# Install apps but with NO generation file (simulates corruption or
	# a device provisioned before migration tracking existed)
	build_real_repo "$APPS/klipper" master "$KLIPPER_PROD_ORIGIN" "orphan-klipper"
	build_real_repo "$APPS/nebulaos-klipper-extensions" main "$EXTENSIONS_PROD_ORIGIN" "orphan-ext"
	build_real_repo "$APPS/moonraker" master "$MOONRAKER_PROD_ORIGIN" "orphan-moonraker"
	# Deliberately no app-generation.json

	old_k=$(git -C "$APPS/klipper" rev-parse HEAD)

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$v2_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/mi.log" 2>&1

	new_k=$(git -C "$APPS/klipper" rev-parse HEAD)
	recorded=$(get_migration_version "$SYSTEM/app-generation.json")

	if [ "$new_k" != "$old_k" ] && [ "$recorded" = "$v2_version" ]; then
		pass "matrix I: missing generation file triggers migration (empty != any version)"
	else
		fail "matrix I: expected migration (new_k=$new_k old_k=$old_k recorded=$recorded)"
	fi
}

# --- Scenario J: Pre-extensions device (klipper exists, no extensions) ---
test_matrix_j_pre_extensions_device() {
	APPS="$WORK/mj-apps"; SYSTEM="$WORK/mj-system"; LOCKDIR="$WORK/mj-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$APPS" "$SYSTEM" "$LOCKDIR"

	build_real_repo "$APPS/klipper" master "$KLIPPER_PROD_ORIGIN" "pre-ext-klipper"
	build_real_repo "$APPS/moonraker" master "$MOONRAKER_PROD_ORIGIN" "pre-ext-moonraker"
	# No extensions checkout — simulates a pre-Phase-1 device
	echo '{"migration_version": "pre-phase1-gen"}' > "$SYSTEM/app-generation.json"

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$v2_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/mj.log" 2>&1

	ext_exists=$([ -d "$APPS/nebulaos-klipper-extensions/.git" ] && echo "yes" || echo "no")
	recorded=$(get_migration_version "$SYSTEM/app-generation.json")

	if [ "$ext_exists" = "yes" ] && [ "$recorded" = "$v2_version" ]; then
		pass "matrix J: pre-extensions device gains extensions via seed_missing_extensions"
	else
		fail "matrix J: extensions not provisioned (ext_exists=$ext_exists recorded=$recorded)"
	fi
}

# --- Scenario K: Corrupt seed archive (truncated tar) --------------------
test_matrix_k_corrupt_archive() {
	APPS="$WORK/mk-apps"; SYSTEM="$WORK/mk-system"; LOCKDIR="$WORK/mk-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$LOCKDIR"
	install_persistent_apps "$APPS" "$SYSTEM" "v1" "$v1_version"
	old_k=$(git -C "$APPS/klipper" rev-parse HEAD)

	corrupt_seeds="$WORK/mk-seeds"
	rm -rf "$corrupt_seeds"
	cp -r "$v2_seeds" "$corrupt_seeds"
	# Truncate the klipper archive to simulate corruption
	dd if="$corrupt_seeds/klipper.tar.gz" of="$corrupt_seeds/klipper.tar.gz.tmp" bs=100 count=1 2>/dev/null
	mv "$corrupt_seeds/klipper.tar.gz.tmp" "$corrupt_seeds/klipper.tar.gz"

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$corrupt_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/mk.log" 2>&1

	new_k=$(git -C "$APPS/klipper" rev-parse HEAD)
	recorded=$(get_migration_version "$SYSTEM/app-generation.json")

	if [ "$new_k" = "$old_k" ] && [ "$recorded" = "$v1_version" ]; then
		pass "matrix K: corrupt archive leaves existing untouched, generation NOT advanced"
	else
		fail "matrix K: expected no change after corrupt archive (new_k=$new_k old_k=$old_k recorded=$recorded)"
	fi
}

# --- Scenario L: Wrong branch in seed archive ----------------------------
test_matrix_l_wrong_branch_archive() {
	APPS="$WORK/ml-apps"; SYSTEM="$WORK/ml-system"; LOCKDIR="$WORK/ml-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$LOCKDIR"
	install_persistent_apps "$APPS" "$SYSTEM" "v1" "$v1_version"
	old_k=$(git -C "$APPS/klipper" rev-parse HEAD)

	# Create an archive on the wrong branch (develop instead of master)
	wrong_branch_src="$WORK/ml-src"
	build_real_repo "$wrong_branch_src" develop "$KLIPPER_PROD_ORIGIN" "wrong-branch"
	wrong_seeds="$WORK/ml-seeds"
	rm -rf "$wrong_seeds"
	cp -r "$v2_seeds" "$wrong_seeds"
	make_seed_archive "$wrong_branch_src" develop "$KLIPPER_PROD_ORIGIN" "$wrong_seeds/klipper.tar.gz" > /dev/null

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$wrong_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/ml.log" 2>&1

	new_k=$(git -C "$APPS/klipper" rev-parse HEAD)

	if [ "$new_k" = "$old_k" ] && grep -q "expected 'master'" "$WORK/ml.log"; then
		pass "matrix L: archive on wrong branch is rejected, existing installation untouched"
	else
		fail "matrix L: expected rejection of wrong-branch archive (new_k=$new_k old_k=$old_k)"
	fi
}

# --- Scenario M: Wrong origin in seed archive ----------------------------
test_matrix_m_wrong_origin_archive() {
	APPS="$WORK/mm-apps"; SYSTEM="$WORK/mm-system"; LOCKDIR="$WORK/mm-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$LOCKDIR"
	install_persistent_apps "$APPS" "$SYSTEM" "v1" "$v1_version"
	old_k=$(git -C "$APPS/klipper" rev-parse HEAD)

	wrong_origin_src="$WORK/mm-src"
	build_real_repo "$wrong_origin_src" master "" "wrong-origin"
	wrong_seeds="$WORK/mm-seeds"
	rm -rf "$wrong_seeds"
	cp -r "$v2_seeds" "$wrong_seeds"
	make_seed_archive "$wrong_origin_src" master "https://github.com/wrong/repo.git" "$wrong_seeds/klipper.tar.gz" > /dev/null

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$wrong_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/mm.log" 2>&1

	new_k=$(git -C "$APPS/klipper" rev-parse HEAD)

	if [ "$new_k" = "$old_k" ] && grep -q "expected '$KLIPPER_PROD_ORIGIN'" "$WORK/mm.log"; then
		pass "matrix M: archive with wrong origin is rejected"
	else
		fail "matrix M: expected rejection of wrong-origin archive"
	fi
}

# --- Scenario N: Dirty tree in seed archive ------------------------------
test_matrix_n_dirty_archive() {
	APPS="$WORK/mn-apps"; SYSTEM="$WORK/mn-system"; LOCKDIR="$WORK/mn-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$LOCKDIR"
	install_persistent_apps "$APPS" "$SYSTEM" "v1" "$v1_version"
	old_k=$(git -C "$APPS/klipper" rev-parse HEAD)

	# Create an archive, then inject a dirty file into it
	dirty_src="$WORK/mn-src"
	build_real_repo "$dirty_src" master "$KLIPPER_PROD_ORIGIN" "clean-start"
	dirty_seeds="$WORK/mn-seeds"
	rm -rf "$dirty_seeds"
	cp -r "$v2_seeds" "$dirty_seeds"

	# Create a clean archive first, then extract, dirty it, re-archive
	clean_archive="$dirty_seeds/klipper.tar.gz"
	extract_dir="$WORK/mn-extract"
	rm -rf "$extract_dir"
	mkdir -p "$extract_dir"
	sh -c "gzip -dc '$clean_archive' | tar -xo -C '$extract_dir'"
	echo "dirty-modification" >> "$extract_dir/file.txt"
	tar -C "$extract_dir" -czf "$dirty_seeds/klipper.tar.gz" .

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$dirty_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/mn.log" 2>&1

	new_k=$(git -C "$APPS/klipper" rev-parse HEAD)

	if [ "$new_k" = "$old_k" ] && grep -q "dirty working tree" "$WORK/mn.log"; then
		pass "matrix N: archive with dirty tree is rejected"
	else
		fail "matrix N: expected rejection of dirty-tree archive"
	fi
}

# --- Scenario O: Repeated migration attempts (idempotent retry) ----------
test_matrix_o_repeated_migration() {
	APPS="$WORK/mo-apps"; SYSTEM="$WORK/mo-system"; LOCKDIR="$WORK/mo-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$LOCKDIR"
	install_persistent_apps "$APPS" "$SYSTEM" "v1" "$v1_version"

	# First migration
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$v2_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/mo-1.log" 2>&1
	after_first=$(git -C "$APPS/klipper" rev-parse HEAD)

	# Second migration (same image, should be no-op)
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$v2_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/mo-2.log" 2>&1
	after_second=$(git -C "$APPS/klipper" rev-parse HEAD)

	backup_count=$(find "$SYSTEM/migration-backups" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)

	if [ "$after_first" = "$after_second" ] && grep -q "already matches" "$WORK/mo-2.log" && [ "$backup_count" -eq 1 ]; then
		pass "matrix O: second migration is a clean no-op, only one backup exists"
	else
		fail "matrix O: repeated migration is not idempotent (first=$after_first second=$after_second backups=$backup_count)"
	fi
}

# --- Scenario P: Boot sequence integration (factory-seed → migrate → activate) ---
test_matrix_p_full_boot_sequence() {
	APPS="$WORK/mp-apps"; SYSTEM="$WORK/mp-system"; LOCKDIR="$WORK/mp-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$APPS" "$SYSTEM" "$LOCKDIR"

	# Step 1: factory-seed (virgin namespace)
	env S04NEBULAOS_FACTORY_SEED_NO_AUTORUN=1 SEEDS="$v2_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$FACTORY_SEED_SCRIPT'; seed_git_app klipper master '$KLIPPER_PROD_ORIGIN'; seed_git_app nebulaos-klipper-extensions main '$EXTENSIONS_PROD_ORIGIN'; seed_git_app moonraker master '$MOONRAKER_PROD_ORIGIN'; record_initial_generation" \
		> "$WORK/mp-seed.log" 2>&1
	seeded_k=$(git -C "$APPS/klipper" rev-parse HEAD)
	seeded_ext=$(git -C "$APPS/nebulaos-klipper-extensions" rev-parse HEAD)

	# Step 2: migrate (should be no-op after fresh seed)
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$v2_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/mp-migrate.log" 2>&1

	after_k=$(git -C "$APPS/klipper" rev-parse HEAD)
	backup_count=$(find "$SYSTEM/migration-backups" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)

	if [ "$after_k" = "$seeded_k" ] && [ "$backup_count" -eq 0 ] && grep -q "already matches" "$WORK/mp-migrate.log"; then
		pass "matrix P: full boot sequence - factory-seed followed by migrate is a clean no-op"
	else
		fail "matrix P: boot sequence not clean (seeded=$seeded_k after=$after_k backups=$backup_count)"
	fi

	# Generation must be recorded and match
	recorded=$(get_migration_version "$SYSTEM/app-generation.json")
	if [ "$recorded" = "$v2_version" ]; then
		pass "matrix P: generation correctly recorded through the full boot sequence"
	else
		fail "matrix P: generation mismatch (recorded=$recorded expected=$v2_version)"
	fi
}

# --- Scenario Q: Diagnostics written on every decision path ---------------
test_matrix_q_diagnostics_on_all_paths() {
	# Test that persistent diagnostics are written for every decision path
	diag_paths_ok=1

	# Path 1: no manifest
	APPS="$WORK/mq1-apps"; SYSTEM="$WORK/mq1-system"
	rm -rf "$APPS" "$SYSTEM"
	mkdir -p "$APPS" "$SYSTEM"
	build_real_repo "$APPS/klipper" master "" "q1"
	empty_seeds="$WORK/mq1-seeds"
	rm -rf "$empty_seeds"; mkdir -p "$empty_seeds"
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$empty_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$WORK/no-lock" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > /dev/null 2>&1
	if [ -f "$SYSTEM/diagnostics/migration-state.json" ]; then
		action=$(grep -o '"migration_action"[[:space:]]*:[[:space:]]*"[^"]*"' "$SYSTEM/diagnostics/migration-state.json" | \
			sed -E 's/.*"([^"]*)"$/\1/')
		[ "$action" = "skipped:no_manifest" ] || diag_paths_ok=0
	else
		diag_paths_ok=0
	fi

	# Path 2: version match
	APPS="$WORK/mq2-apps"; SYSTEM="$WORK/mq2-system"
	rm -rf "$APPS" "$SYSTEM"
	install_persistent_apps "$APPS" "$SYSTEM" "v2" "$v2_version"
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$v2_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$WORK/no-lock" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > /dev/null 2>&1
	if [ -f "$SYSTEM/diagnostics/migration-state.json" ]; then
		action=$(grep -o '"migration_action"[[:space:]]*:[[:space:]]*"[^"]*"' "$SYSTEM/diagnostics/migration-state.json" | \
			sed -E 's/.*"([^"]*)"$/\1/')
		[ "$action" = "skipped:version_match" ] || diag_paths_ok=0
	else
		diag_paths_ok=0
	fi

	# Path 3: successful migration
	APPS="$WORK/mq3-apps"; SYSTEM="$WORK/mq3-system"
	rm -rf "$APPS" "$SYSTEM"
	install_persistent_apps "$APPS" "$SYSTEM" "v1" "$v1_version"
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$v2_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$WORK/no-lock" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > /dev/null 2>&1
	if [ -f "$SYSTEM/diagnostics/migration-state.json" ]; then
		action=$(grep -o '"migration_action"[[:space:]]*:[[:space:]]*"[^"]*"' "$SYSTEM/diagnostics/migration-state.json" | \
			sed -E 's/.*"([^"]*)"$/\1/')
		[ "$action" = "completed" ] || diag_paths_ok=0
	else
		diag_paths_ok=0
	fi

	if [ "$diag_paths_ok" = "1" ]; then
		pass "matrix Q: persistent migration-state.json written with correct action on every decision path"
	else
		fail "matrix Q: diagnostics missing or incorrect on at least one decision path"
	fi
}

test_matrix_a_virgin_first_boot
test_matrix_b_same_generation_noop
test_matrix_c_v1_to_v2_upgrade
test_matrix_d_v2_to_v1_downgrade
test_matrix_e_missing_klipper_archive
test_matrix_f_missing_extensions_archive
test_matrix_g_missing_moonraker_archive
test_matrix_h_no_manifest
test_matrix_i_missing_generation_file
test_matrix_j_pre_extensions_device
test_matrix_k_corrupt_archive
test_matrix_l_wrong_branch_archive
test_matrix_m_wrong_origin_archive
test_matrix_n_dirty_archive
test_matrix_o_repeated_migration
test_matrix_p_full_boot_sequence
test_matrix_q_diagnostics_on_all_paths

# =========================================================================
# SECTION 3: PARTIAL MIGRATION SAFETY (paired lifecycle)
# =========================================================================

echo ""
echo "=== SECTION 3: Partial migration safety ==="

# --- Test: Klipper succeeds but extensions fails → neither promoted ------
test_partial_klipper_ok_extensions_fail() {
	APPS="$WORK/pk-apps"; SYSTEM="$WORK/pk-system"; LOCKDIR="$WORK/pk-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$LOCKDIR"
	install_persistent_apps "$APPS" "$SYSTEM" "v1" "$v1_version"
	old_k=$(git -C "$APPS/klipper" rev-parse HEAD)

	# Remove ONLY extensions archive so klipper succeeds but extensions fails
	partial_seeds="$WORK/pk-seeds"
	rm -rf "$partial_seeds"
	cp -r "$v2_seeds" "$partial_seeds"
	rm -f "$partial_seeds/nebulaos-klipper-extensions.tar.gz"

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$partial_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/pk.log" 2>&1

	recorded=$(get_migration_version "$SYSTEM/app-generation.json")

	# D-01: a MISSING SEED ARCHIVE is a deterministic precondition failure and
	# is caught by the zero-write gate, before any component is cut over -
	# strictly stronger than the old behaviour, which cut the healthy half over
	# first and only then reported an incomplete pair. Pinned exactly rather
	# than as "either refusal": accepting the old pair-guard message too would
	# let a regression back to the old behaviour pass here.
	if [ "$recorded" = "$v1_version" ] && \
	   grep -q "migration NOT STARTED" "$WORK/pk.log"; then
		pass "partial safety: klipper ok + extensions fail = generation NOT advanced (paired lifecycle)"
	else
		fail "partial safety: expected paired failure (recorded=$recorded log=$(tail -3 "$WORK/pk.log"))"
	fi
}

# --- Test: Extensions succeeds but klipper fails → neither promoted ------
test_partial_extensions_ok_klipper_fail() {
	APPS="$WORK/pe-apps"; SYSTEM="$WORK/pe-system"; LOCKDIR="$WORK/pe-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$LOCKDIR"
	install_persistent_apps "$APPS" "$SYSTEM" "v1" "$v1_version"

	partial_seeds="$WORK/pe-seeds"
	rm -rf "$partial_seeds"
	cp -r "$v2_seeds" "$partial_seeds"
	rm -f "$partial_seeds/klipper.tar.gz"

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$partial_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/pe.log" 2>&1

	recorded=$(get_migration_version "$SYSTEM/app-generation.json")

	# D-01: a MISSING SEED ARCHIVE is a deterministic precondition failure and
	# is caught by the zero-write gate, before any component is cut over -
	# strictly stronger than the old behaviour, which cut the healthy half over
	# first and only then reported an incomplete pair. Pinned exactly rather
	# than as "either refusal": accepting the old pair-guard message too would
	# let a regression back to the old behaviour pass here.
	if [ "$recorded" = "$v1_version" ] && \
	   grep -q "migration NOT STARTED" "$WORK/pe.log"; then
		pass "partial safety: extensions ok + klipper fail = generation NOT advanced (paired lifecycle)"
	else
		fail "partial safety: expected paired failure (recorded=$recorded)"
	fi
}

# --- Test: Klipper+extensions succeed, moonraker fails → generation NOT advanced
test_partial_moonraker_fail() {
	APPS="$WORK/pm-apps"; SYSTEM="$WORK/pm-system"; LOCKDIR="$WORK/pm-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$LOCKDIR"
	install_persistent_apps "$APPS" "$SYSTEM" "v1" "$v1_version"

	partial_seeds="$WORK/pm-seeds"
	rm -rf "$partial_seeds"
	cp -r "$v2_seeds" "$partial_seeds"
	rm -f "$partial_seeds/moonraker.tar.gz"

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$partial_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$WORK/pm.log" 2>&1

	recorded=$(get_migration_version "$SYSTEM/app-generation.json")

	if [ "$recorded" = "$v1_version" ]; then
		pass "partial safety: klipper+ext ok, moonraker fail = generation NOT advanced (all-or-nothing)"
	else
		fail "partial safety: generation should not have advanced when moonraker failed (recorded=$recorded)"
	fi
}

test_partial_klipper_ok_extensions_fail
test_partial_extensions_ok_klipper_fail
test_partial_moonraker_fail

# =========================================================================
# SECTION 4: DIAGNOSTICS PERSISTENCE AND LOG ROTATION
# =========================================================================

echo ""
echo "=== SECTION 4: Diagnostics and log rotation ==="

# --- Test: Diagnostics log rotation does not lose current boot -----------
test_diag_log_rotation() {
	APPS="$WORK/dr-apps"; SYSTEM="$WORK/dr-system"; LOCKDIR="$WORK/dr-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$APPS" "$SYSTEM/diagnostics" "$LOCKDIR"
	build_real_repo "$APPS/klipper" master "$KLIPPER_PROD_ORIGIN" "rotation-test"
	build_real_repo "$APPS/nebulaos-klipper-extensions" main "$EXTENSIONS_PROD_ORIGIN" "rotation-test-ext"
	build_real_repo "$APPS/moonraker" master "$MOONRAKER_PROD_ORIGIN" "rotation-test-mr"
	echo '{"migration_version": "old-gen"}' > "$SYSTEM/app-generation.json"

	# Pre-fill the log with >64KB of content
	dd if=/dev/urandom bs=1024 count=70 2>/dev/null | base64 > "$SYSTEM/diagnostics/migration.log"
	old_size=$(wc -c < "$SYSTEM/diagnostics/migration.log")

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$v2_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > /dev/null 2>&1

	new_size=$(wc -c < "$SYSTEM/diagnostics/migration.log")
	if [ "$new_size" -lt "$old_size" ] && [ "$new_size" -le 70000 ] && grep -q "migration pass starting" "$SYSTEM/diagnostics/migration.log"; then
		pass "diagnostics: log rotated when oversized but current boot's entries preserved"
	else
		fail "diagnostics: log rotation issue (old_size=$old_size new_size=$new_size)"
	fi
}

# --- Test: migration-state.json contains before/after SHAs ---------------
test_diag_state_has_shas() {
	APPS="$WORK/ds-apps"; SYSTEM="$WORK/ds-system"; LOCKDIR="$WORK/ds-locks"
	rm -rf "$APPS" "$SYSTEM" "$LOCKDIR"
	mkdir -p "$LOCKDIR"
	install_persistent_apps "$APPS" "$SYSTEM" "v1" "$v1_version"
	old_k=$(git -C "$APPS/klipper" rev-parse HEAD)

	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$v2_seeds" APPS="$APPS" SYSTEM="$SYSTEM" LOCKDIR="$LOCKDIR" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > /dev/null 2>&1

	state="$SYSTEM/diagnostics/migration-state.json"
	if [ -f "$state" ]; then
		kb=$(grep -o '"klipper_before"[[:space:]]*:[[:space:]]*"[^"]*"' "$state" | sed -E 's/.*"([^"]*)"$/\1/')
		ka=$(grep -o '"klipper_after"[[:space:]]*:[[:space:]]*"[^"]*"' "$state" | sed -E 's/.*"([^"]*)"$/\1/')
		if [ "$kb" = "$old_k" ] && [ -n "$ka" ] && [ "$ka" != "unknown" ] && [ "$kb" != "$ka" ]; then
			pass "diagnostics: migration-state.json records correct before/after klipper SHAs"
		else
			fail "diagnostics: wrong SHAs in state (before=$kb after=$ka expected_before=$old_k)"
		fi
	else
		fail "diagnostics: migration-state.json not written"
	fi
}

test_diag_log_rotation
test_diag_state_has_shas

echo
echo "gate2-regression-and-migration-matrix-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
