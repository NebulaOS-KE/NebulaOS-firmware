#!/bin/sh
#
# Phase 1.8B boot safety tests. Verifies the critical property: neither
# S00revert-safety nor S99confirm-good calls write_ota_marker on any code
# path. The automatic stock fallback was removed because booting the stock
# Creality slot auto-flashes the MCU with old firmware, destroying the
# qualified native GD32F303 MCU build.
#
# These tests are static (grep-based) and simulation-based — they do not
# require a running printer, Moonraker, or real /dev/mmcblk0p1.
#
# Usage: sh tests/boot-safety-no-auto-stock-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

S00="$REPO_ROOT/scripts/build/overlay/etc/init.d/S00revert-safety"
S99="$REPO_ROOT/scripts/build/overlay/etc/init.d/S99confirm-good"
OTA_MARKER="$REPO_ROOT/scripts/build/overlay/etc/ota_marker.sh"
DOC_RECOVERY="$REPO_ROOT/docs/DEVELOPER_RECOVERY.md"
DOC_SWITCH="$REPO_ROOT/docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md"

PASS=0
FAIL=0
SKIP=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

echo "=== Phase 1.8B boot safety: no automatic stock fallback ==="

# ---------------------------------------------------------------------------
# Test 1: S00revert-safety does NOT call write_ota_marker
# ---------------------------------------------------------------------------
test_s00_no_marker_write() {
	if [ ! -f "$S00" ]; then
		fail "S00revert-safety not found at $S00"
		return
	fi
	# Exclude comment lines (lines starting with optional whitespace then #)
	if grep -v '^\s*#' "$S00" | grep -q 'write_ota_marker'; then
		fail "S00revert-safety calls write_ota_marker in executable code — automatic stock fallback not removed"
	else
		pass "S00revert-safety does NOT call write_ota_marker in any executable code path"
	fi
}

# ---------------------------------------------------------------------------
# Test 2: S99confirm-good does NOT call write_ota_marker on ANY path
# ---------------------------------------------------------------------------
test_s99_no_marker_write() {
	if [ ! -f "$S99" ]; then
		fail "S99confirm-good not found at $S99"
		return
	fi
	if grep -v '^\s*#' "$S99" | grep -q 'write_ota_marker'; then
		fail "S99confirm-good calls write_ota_marker in executable code — marker write not removed"
	else
		pass "S99confirm-good does NOT call write_ota_marker in any executable code path (success or failure)"
	fi
}

# ---------------------------------------------------------------------------
# Test 3: ota_marker.sh still exists and exports write_ota_marker
# ---------------------------------------------------------------------------
test_ota_marker_library_intact() {
	if [ ! -f "$OTA_MARKER" ]; then
		fail "ota_marker.sh not found at $OTA_MARKER — manual recovery library missing"
		return
	fi
	if grep -q 'write_ota_marker()' "$OTA_MARKER"; then
		pass "ota_marker.sh exists and defines write_ota_marker() — manual recovery preserved"
	else
		fail "ota_marker.sh exists but does not define write_ota_marker() — manual recovery broken"
	fi
}

# ---------------------------------------------------------------------------
# Test 4: S00revert-safety still sources ota_marker.sh
# ---------------------------------------------------------------------------
test_s00_sources_ota_marker() {
	if grep -q '^\. /etc/ota_marker\.sh' "$S00"; then
		pass "S00revert-safety still sources /etc/ota_marker.sh (library remains available)"
	else
		fail "S00revert-safety no longer sources /etc/ota_marker.sh — library not available in boot environment"
	fi
}

# ---------------------------------------------------------------------------
# Test 5: S99confirm-good still sources ota_marker.sh
# ---------------------------------------------------------------------------
test_s99_sources_ota_marker() {
	if grep -q '^\. /etc/ota_marker\.sh' "$S99"; then
		pass "S99confirm-good still sources /etc/ota_marker.sh (library remains available)"
	else
		fail "S99confirm-good no longer sources /etc/ota_marker.sh"
	fi
}

# ---------------------------------------------------------------------------
# Test 6: Manual recovery documentation still references write_ota_marker
# ---------------------------------------------------------------------------
test_docs_reference_manual_recovery() {
	missing=""
	for doc in "$DOC_RECOVERY" "$DOC_SWITCH"; do
		if [ ! -f "$doc" ]; then
			missing="$missing $(basename "$doc")"
			continue
		fi
		if ! grep -q 'write_ota_marker' "$doc"; then
			missing="$missing $(basename "$doc")"
		fi
	done
	if [ -z "$missing" ]; then
		pass "both recovery docs (DEVELOPER_RECOVERY.md, HOW_TO_SWITCH_STOCK_AND_CUSTOM.md) reference write_ota_marker for manual recovery"
	else
		fail "manual recovery docs missing write_ota_marker reference:$missing"
	fi
}

# ---------------------------------------------------------------------------
# Test 7: S00revert-safety script structure intact (start/stop/restart case)
# ---------------------------------------------------------------------------
test_s00_script_structure() {
	if grep -q 'case "\$1"' "$S00" && grep -q 'start)' "$S00" && grep -q 'exit 0' "$S00"; then
		pass "S00revert-safety retains init.d script structure (case/start/exit)"
	else
		fail "S00revert-safety script structure broken — missing case/start/exit pattern"
	fi
}

# ---------------------------------------------------------------------------
# Test 8: S99confirm-good retains the health check (check_moonraker)
# ---------------------------------------------------------------------------
test_s99_retains_health_check() {
	if grep -q 'check_moonraker' "$S99" && grep -q 'klippy_state' "$S99"; then
		pass "S99confirm-good retains Moonraker health check (check_moonraker + klippy_state)"
	else
		fail "S99confirm-good lost the health check — diagnostic value removed"
	fi
}

# ---------------------------------------------------------------------------
# Test 9: S99confirm-good retains retry/timeout structure
# ---------------------------------------------------------------------------
test_s99_retains_retry_structure() {
	if grep -q 'RETRIES=' "$S99" && grep -q 'DELAY=' "$S99" && grep -q 'while \[' "$S99"; then
		pass "S99confirm-good retains retry/timeout loop structure"
	else
		fail "S99confirm-good lost retry/timeout structure"
	fi
}

# ---------------------------------------------------------------------------
# Test 10: S00revert-safety logs the policy change reason
# ---------------------------------------------------------------------------
test_s00_logs_policy() {
	if grep -v '^\s*#' "$S00" | grep -qi 'MCU'; then
		pass "S00revert-safety logs MCU safety as the reason for disabling automatic fallback"
	else
		fail "S00revert-safety does not mention MCU safety in its runtime log output"
	fi
}

# ---------------------------------------------------------------------------
# Test 11: Simulated boot — Klipper fails, verify marker NEVER written
# ---------------------------------------------------------------------------
# This creates a fake environment where S00 and S99 are sourced/analyzed
# to prove write_ota_marker is never invoked, regardless of Klipper state.
test_simulation_klipper_fails() {
	WORK=$(mktemp -d "${TMPDIR:-/tmp}/boot-safety-sim.XXXXXX")
	[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: boot-safety-no-auto-stock-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
	trap_cleanup="rm -rf $WORK"

	# Create a mock ota_marker.sh that records any calls to write_ota_marker
	cat > "$WORK/ota_marker.sh" <<-'MOCKEOF'
	write_ota_marker() {
		echo "MARKER_WRITTEN:$1" >> /tmp/_boot_safety_test_marker_log
	}
	MOCKEOF

	MARKER_LOG="$WORK/marker_log"
	rm -f "$MARKER_LOG"

	# Simulate S00 start: source the script content in a subshell
	# We extract the start) case body and run it with our mock
	(
		export PATH="/bin:/usr/bin"
		# Override the marker log location
		cat > "$WORK/mock_ota_marker.sh" <<-INNEREOF
		write_ota_marker() {
			echo "MARKER_WRITTEN:\$1" >> "$MARKER_LOG"
		}
		INNEREOF
		# Build a modified S00 that sources our mock instead
		sed "s|^\. /etc/ota_marker\.sh|. $WORK/mock_ota_marker.sh|" "$S00" > "$WORK/s00_sim.sh"
		chmod +x "$WORK/s00_sim.sh"
		sh "$WORK/s00_sim.sh" start </dev/null >/dev/null 2>&1
	)

	# Simulate S99 start with a Moonraker that never responds (Klipper fails).
	# We override RETRIES and DELAY to make it fast, and wget to always fail.
	(
		cat > "$WORK/mock_ota_marker.sh" <<-INNEREOF
		write_ota_marker() {
			echo "MARKER_WRITTEN:\$1" >> "$MARKER_LOG"
		}
		INNEREOF
		# Build a modified S99 that:
		# - sources our mock ota_marker
		# - uses RETRIES=1, DELAY=0 for speed
		# - has a wget that always fails (simulating Klipper not starting)
		sed "s|^\. /etc/ota_marker\.sh|. $WORK/mock_ota_marker.sh|" "$S99" \
			| sed 's/^RETRIES=.*/RETRIES=1/' \
			| sed 's/^DELAY=.*/DELAY=0/' \
			| sed 's|wget -q -O -|false #|' \
			> "$WORK/s99_sim.sh"
		chmod +x "$WORK/s99_sim.sh"
		sh "$WORK/s99_sim.sh" start </dev/null >/dev/null 2>&1 || true
	)

	if [ -f "$MARKER_LOG" ]; then
		fail "simulation (Klipper fails): write_ota_marker was called — contents: $(cat "$MARKER_LOG")"
	else
		pass "simulation (Klipper fails): S00 + S99 full boot sequence completed, write_ota_marker NEVER called"
	fi

	rm -rf "$WORK"
}

# ---------------------------------------------------------------------------
# Test 12: Simulated boot — Klipper starts OK, verify marker NEVER written
# ---------------------------------------------------------------------------
test_simulation_klipper_ok() {
	WORK=$(mktemp -d "${TMPDIR:-/tmp}/boot-safety-sim-ok.XXXXXX")
	[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: boot-safety-no-auto-stock-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
	MARKER_LOG="$WORK/marker_log"
	rm -f "$MARKER_LOG"

	# Simulate S00 start
	(
		cat > "$WORK/mock_ota_marker.sh" <<-INNEREOF
		write_ota_marker() {
			echo "MARKER_WRITTEN:\$1" >> "$MARKER_LOG"
		}
		INNEREOF
		sed "s|^\. /etc/ota_marker\.sh|. $WORK/mock_ota_marker.sh|" "$S00" > "$WORK/s00_sim.sh"
		chmod +x "$WORK/s00_sim.sh"
		sh "$WORK/s00_sim.sh" start </dev/null >/dev/null 2>&1
	)

	# Simulate S99 start with a Moonraker that IS healthy (klippy_state=ready).
	# We make check_moonraker always succeed by replacing the wget call.
	(
		cat > "$WORK/mock_ota_marker.sh" <<-INNEREOF
		write_ota_marker() {
			echo "MARKER_WRITTEN:\$1" >> "$MARKER_LOG"
		}
		INNEREOF
		# Replace the wget-based check with one that always returns "ready"
		sed "s|^\. /etc/ota_marker\.sh|. $WORK/mock_ota_marker.sh|" "$S99" \
			| sed 's/^RETRIES=.*/RETRIES=1/' \
			| sed 's/^DELAY=.*/DELAY=0/' \
			| sed '/^check_moonraker()/,/^}/c\
check_moonraker() { return 0; }' \
			> "$WORK/s99_sim.sh"
		chmod +x "$WORK/s99_sim.sh"
		sh "$WORK/s99_sim.sh" start </dev/null >/dev/null 2>&1 || true
	)

	if [ -f "$MARKER_LOG" ]; then
		fail "simulation (Klipper OK): write_ota_marker was called — contents: $(cat "$MARKER_LOG")"
	else
		pass "simulation (Klipper OK): S00 + S99 full boot sequence completed, write_ota_marker NEVER called even on healthy boot"
	fi

	rm -rf "$WORK"
}

# ---------------------------------------------------------------------------
# Test 13: Documentation notes automatic fallback removal
# ---------------------------------------------------------------------------
test_docs_note_removal() {
	noted=""
	for doc in "$DOC_RECOVERY" "$DOC_SWITCH"; do
		if [ -f "$doc" ] && grep -qi 'auto.*fallback.*removed\|auto.*stock.*fallback.*disabled\|automatic.*stock.*fallback.*removed\|automatic.*fallback.*removed' "$doc"; then
			noted="$noted $(basename "$doc")"
		fi
	done
	if [ -n "$noted" ]; then
		pass "recovery documentation notes that automatic stock fallback has been removed:$noted"
	else
		fail "no recovery documentation mentions the removal of automatic stock fallback"
	fi
}

# --- Run all tests ---
test_s00_no_marker_write
test_s99_no_marker_write
test_ota_marker_library_intact
test_s00_sources_ota_marker
test_s99_sources_ota_marker
test_docs_reference_manual_recovery
test_s00_script_structure
test_s99_retains_health_check
test_s99_retains_retry_structure
test_s00_logs_policy
test_simulation_klipper_fails
test_simulation_klipper_ok
test_docs_note_removal

echo
echo "boot-safety-no-auto-stock-tests: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
