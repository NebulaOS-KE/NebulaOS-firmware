#!/bin/sh
#
# Offline, repeatable tests for the print-control config closure validator
# (mainline print-controls mission, 2026-07-29, see
# docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md). This is the build gate that
# must fail the image build if the factory printer_data/config seed is
# missing, or has duplicate definitions of, virtual_sdcard/pause_resume/
# display_status/PAUSE/RESUME/CANCEL_PRINT.
#
# Sources scripts/build/lib/validate-frontend-controls.sh directly - the
# exact functions scripts/build/04-cross-compile-app-stack.sh calls against
# the real overlay source - so these tests exercise the actual build gate,
# not a second/parallel reimplementation of its rules (same convention as
# tests/factory-seed-git-tests.sh and scripts/build/lib/make-seed-archive.sh).
# Never touches a real device or /usr/data.
#
# Usage: sh tests/nebulaos-frontend-controls-validation-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
LIB="$REPO_ROOT/scripts/build/lib/validate-frontend-controls.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/frontend-controls-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: nebulaos-frontend-controls-validation-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

# shellcheck disable=SC1090
. "$LIB"

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

EXPECTED_PATH="/opt/printer_data/gcodes"

# Runs the real resolve+validate pipeline against a fixture dir and
# compares the outcome to what the test expects.
# $1=label $2=fixture dir $3=entry file $4=expect_resolve_ok(0/1)
# $5=expect_validate_ok(0/1, ignored if $4=1)
check_scenario() {
	label="$1"; dir="$2"; entry="$3"; expect_resolve="$4"; expect_validate="$5"
	closure="$WORK/closure-$$.txt"
	if frontend_controls_resolve_closure "$dir" "$entry" "$closure" >"$WORK/log-$$.txt" 2>&1; then
		resolve_ok=0
	else
		resolve_ok=1
	fi
	if [ "$resolve_ok" != "$expect_resolve" ]; then
		fail "$label: resolve returned $resolve_ok, expected $expect_resolve ($(cat "$WORK/log-$$.txt"))"
		rm -f "$closure" "$WORK/log-$$.txt"
		return
	fi
	if [ "$expect_resolve" = "1" ]; then
		pass "$label: include resolution correctly failed"
		rm -f "$closure" "$WORK/log-$$.txt"
		return
	fi
	if frontend_controls_validate_closure "$closure" "$EXPECTED_PATH" >"$WORK/vlog-$$.txt" 2>&1; then
		validate_ok=0
	else
		validate_ok=1
	fi
	if [ "$validate_ok" = "$expect_validate" ]; then
		pass "$label"
	else
		fail "$label: validate returned $validate_ok, expected $expect_validate ($(cat "$WORK/vlog-$$.txt"))"
	fi
	rm -f "$closure" "$WORK/log-$$.txt" "$WORK/vlog-$$.txt"
}

# --- fixture builders ---------------------------------------------------

write_clean_fixture() {
	dir="$1"
	rm -rf "$dir"
	mkdir -p "$dir/GuppyScreen"
	cat > "$dir/printer.cfg" <<'EOF'
[include frontend-controls.cfg]
[include GuppyScreen/guppy_cmd.cfg]

[printer]
kinematics: cartesian
EOF
	cat > "$dir/frontend-controls.cfg" <<EOF
[virtual_sdcard]
path: $EXPECTED_PATH
on_error_gcode: CANCEL_PRINT

[pause_resume]

[display_status]

[gcode_macro PAUSE]
rename_existing: BASE_PAUSE
gcode:
  BASE_PAUSE

[gcode_macro RESUME]
rename_existing: BASE_RESUME
gcode:
  BASE_RESUME

[gcode_macro CANCEL_PRINT]
rename_existing: BASE_CANCEL_PRINT
gcode:
  BASE_CANCEL_PRINT
EOF
	echo "[respond]" > "$dir/GuppyScreen/guppy_cmd.cfg"
}

# --- Scenario 1: clean valid config passes -----------------------------

d="$WORK/s1"; write_clean_fixture "$d"
check_scenario "clean valid config passes" "$d" printer.cfg 0 0

# --- Scenario 2: missing frontend-controls include ---------------------

d="$WORK/s2"; write_clean_fixture "$d"
cat > "$d/printer.cfg" <<'EOF'
[include GuppyScreen/guppy_cmd.cfg]

[printer]
kinematics: cartesian
EOF
check_scenario "missing frontend-controls include is rejected" "$d" printer.cfg 0 1

# --- Scenario 3: missing included file (referenced but absent) ---------

d="$WORK/s3"; write_clean_fixture "$d"
rm -f "$d/frontend-controls.cfg"
check_scenario "missing included file is rejected" "$d" printer.cfg 1 0

# --- Scenario 4: missing virtual_sdcard ---------------------------------

d="$WORK/s4"; write_clean_fixture "$d"
cat > "$d/frontend-controls.cfg" <<'EOF'
[pause_resume]

[display_status]
EOF
check_scenario "missing virtual_sdcard is rejected" "$d" printer.cfg 0 1

# --- Scenario 5: wrong gcode path ----------------------------------------

d="$WORK/s5"; write_clean_fixture "$d"
cat > "$d/frontend-controls.cfg" <<'EOF'
[virtual_sdcard]
path: /home/pi/printer_data/gcodes
on_error_gcode: CANCEL_PRINT

[pause_resume]

[display_status]
EOF
check_scenario "wrong gcode path is rejected" "$d" printer.cfg 0 1

# --- Scenario 6: missing pause_resume --------------------------------

d="$WORK/s6"; write_clean_fixture "$d"
cat > "$d/frontend-controls.cfg" <<EOF
[virtual_sdcard]
path: $EXPECTED_PATH
on_error_gcode: CANCEL_PRINT

[display_status]
EOF
check_scenario "missing pause_resume is rejected" "$d" printer.cfg 0 1

# --- Scenario 7: missing display_status ---------------------------------

d="$WORK/s7"; write_clean_fixture "$d"
cat > "$d/frontend-controls.cfg" <<EOF
[virtual_sdcard]
path: $EXPECTED_PATH
on_error_gcode: CANCEL_PRINT

[pause_resume]
EOF
check_scenario "missing display_status is rejected" "$d" printer.cfg 0 1

# --- Scenario 7b: pause_resume present but the gcode_macro PAUSE/RESUME/ --
# --- CANCEL_PRINT wrapper macros are missing - the real bug reported live --
# --- (2026-07-29): Mainsail's frontend checks configfile.settings for ------
# --- these literal macro sections directly, regardless of whether the ------
# --- commands already work at runtime via pause_resume.py ------------------

d="$WORK/s7b"; write_clean_fixture "$d"
cat > "$d/frontend-controls.cfg" <<EOF
[virtual_sdcard]
path: $EXPECTED_PATH
on_error_gcode: CANCEL_PRINT

[pause_resume]

[display_status]
EOF
check_scenario "missing gcode_macro PAUSE/RESUME/CANCEL_PRINT wrappers is rejected even with pause_resume present" "$d" printer.cfg 0 1

# --- Scenario 8: duplicate PAUSE macro -----------------------------------

d="$WORK/s8"; write_clean_fixture "$d"
cat >> "$d/frontend-controls.cfg" <<'EOF'

[gcode_macro PAUSE]
rename_existing: BASE_PAUSE
gcode:
  BASE_PAUSE
EOF
echo "" >> "$d/GuppyScreen/guppy_cmd.cfg"
cat >> "$d/printer.cfg" <<'EOF'

[gcode_macro PAUSE]
rename_existing: BASE_PAUSE_2
gcode:
  BASE_PAUSE_2
EOF
check_scenario "duplicate PAUSE macro is rejected" "$d" printer.cfg 0 1

# --- Scenario 9: recursive rename_existing chain ------------------------

d="$WORK/s9"; write_clean_fixture "$d"
cat > "$d/frontend-controls.cfg" <<EOF
[virtual_sdcard]
path: $EXPECTED_PATH
on_error_gcode: CANCEL_PRINT

[pause_resume]

[display_status]

[gcode_macro PAUSE]
rename_existing: BASE_PAUSE
gcode:
  BASE_PAUSE

[gcode_macro RESUME]
rename_existing: BASE_RESUME
gcode:
  BASE_RESUME

[gcode_macro CANCEL_PRINT]
rename_existing: CANCEL_PRINT
gcode:
  CANCEL_PRINT
EOF
check_scenario "recursive rename_existing chain is rejected" "$d" printer.cfg 0 1

# --- Scenario 10: clean valid config supplies exactly what GuppyScreen ---
# --- actually calls (strings-confirmed against the real guppyscreen ------
# --- binary in docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md sec 4 Level 3) ---

d="$WORK/s10"; write_clean_fixture "$d"
closure="$WORK/s10-closure.txt"
frontend_controls_resolve_closure "$d" printer.cfg "$closure" >/dev/null 2>&1
guppy_needs_ok=1
for pattern in "virtual_sdcard" "pause_resume" "display_status"; do
	if ! grep -q -i -E "^\[[[:space:]]*$pattern([[:space:]]|\])" "$closure"; then
		guppy_needs_ok=0
	fi
done
if [ "$guppy_needs_ok" = "1" ]; then
	pass "clean config supplies every object GuppyScreen's binary references (virtual_sdcard/pause_resume/display_status)"
else
	fail "clean config is missing an object GuppyScreen's binary references"
fi

# --- Scenario 11: no Creality/OpenKE-specific fallback was added --------
# --- (decision record concluded Level 4 is not needed at all - this is ---
# --- a regression guard against one being added silently later) --------

REAL_SRC="$REPO_ROOT/scripts/build/overlay/opt/printer_data/config"
if [ -f "$REAL_SRC/frontend-controls.cfg" ]; then
	fail "frontend-controls.cfg still exists in the tracked overlay (removed in Phase 2 upstream-first refactor)"
else
	pass "frontend-controls.cfg correctly absent from tracked overlay (Phase 2: all macros in /etc/nebulaos/klipper/)"
fi

# --- Scenario 12: the real, tracked overlay config passes end-to-end ---
#
# Phase 1.5 persistent-namespace mission (2026-08): printer.cfg now also
# includes the immutable /etc/nebulaos/klipper/*.cfg files with ABSOLUTE
# paths, so this call must pass the same 4th overlay_root argument the
# real build call site (scripts/build/04-cross-compile-app-stack.sh) does
# - without it, resolution correctly FATALs (see scenario 15 below), which
# is exactly why this scenario needs updating rather than left as-is.

# Timelapse (2026-10-31): the build adds upstream moonraker-timelapse's
# timelapse.cfg (pinned) next to the tracked files and resolves against that
# generated overlay ($OVERLAY) - so this does the same: the tracked overlay
# plus timelapse.cfg from the pinned checkout (a stub when it is not fetched).
REAL_OVERLAY_ROOT="$WORK/real-overlay"
mkdir -p "$REAL_OVERLAY_ROOT"
cp -a "$REPO_ROOT/scripts/build/overlay/." "$REAL_OVERLAY_ROOT/"
if [ -f "$REPO_ROOT/vendor/moonraker-timelapse/klipper_macro/timelapse.cfg" ]; then
	cp "$REPO_ROOT/vendor/moonraker-timelapse/klipper_macro/timelapse.cfg" "$REAL_OVERLAY_ROOT/etc/nebulaos/klipper/"
else
	printf '[gcode_macro TIMELAPSE_TAKE_FRAME]\ngcode:\n' > "$REAL_OVERLAY_ROOT/etc/nebulaos/klipper/timelapse.cfg"
fi

if [ -f "$REAL_SRC/printer.cfg" ]; then
	real_closure="$WORK/real-closure.txt"
	if frontend_controls_resolve_closure "$REAL_SRC" printer.cfg "$real_closure" "$REAL_OVERLAY_ROOT" >"$WORK/real-log.txt" 2>&1; then
		if frontend_controls_validate_closure "$real_closure" "$EXPECTED_PATH" >"$WORK/real-vlog.txt" 2>&1; then
			pass "the real tracked overlay printer.cfg closure passes validation end-to-end"
		else
			fail "the real tracked overlay printer.cfg closure failed validation ($(cat "$WORK/real-vlog.txt"))"
		fi
	else
		fail "the real tracked overlay printer.cfg closure failed to resolve ($(cat "$WORK/real-log.txt"))"
	fi
else
	fail "real overlay printer.cfg not found at $REAL_SRC - repository layout has changed"
fi

# --- Scenario 13: an absolute /etc/nebulaos/... include resolves --------
# --- correctly against overlay_root (Phase 1.5 persistent-namespace ------
# --- mission, item 3) ----------------------------------------------------

d="$WORK/s13"; write_clean_fixture "$d"
overlay13="$WORK/s13-overlay"
mkdir -p "$overlay13/etc/nebulaos/klipper"
cat > "$overlay13/etc/nebulaos/klipper/machine.cfg" <<'EOF'
[some_slot_owned_section]
value: 1
EOF
cat > "$d/printer.cfg" <<'EOF'
[include frontend-controls.cfg]
[include GuppyScreen/guppy_cmd.cfg]
[include /etc/nebulaos/klipper/machine.cfg]

[printer]
kinematics: cartesian
EOF
closure13="$WORK/s13-closure.txt"
if frontend_controls_resolve_closure "$d" printer.cfg "$closure13" "$overlay13" >"$WORK/s13-log.txt" 2>&1; then
	if grep -q "\[some_slot_owned_section\]" "$closure13"; then
		pass "an absolute /etc/nebulaos/... include resolves correctly against overlay_root"
	else
		fail "absolute /etc/nebulaos/... include resolved but the closure is missing its content"
	fi
else
	fail "absolute /etc/nebulaos/... include unexpectedly failed to resolve ($(cat "$WORK/s13-log.txt"))"
fi

# --- Scenario 14: an absolute include OUTSIDE /etc/nebulaos/ is refused --
# --- (item 3's other required case) - any other absolute path is FATAL, --
# --- never silently followed, even when overlay_root is given and the ----
# --- file genuinely exists there -----------------------------------------

d="$WORK/s14"; write_clean_fixture "$d"
overlay14="$WORK/s14-overlay"
mkdir -p "$overlay14/etc/other"
echo "[respond]" > "$overlay14/etc/other/evil.cfg"
cat > "$d/printer.cfg" <<'EOF'
[include frontend-controls.cfg]
[include GuppyScreen/guppy_cmd.cfg]
[include /etc/other/evil.cfg]

[printer]
kinematics: cartesian
EOF
closure14="$WORK/s14-closure.txt"
if frontend_controls_resolve_closure "$d" printer.cfg "$closure14" "$overlay14" >"$WORK/s14-log.txt" 2>&1; then
	fail "absolute include outside /etc/nebulaos/ was incorrectly allowed to resolve"
else
	if grep -q "outside the recognized /etc/nebulaos/" "$WORK/s14-log.txt"; then
		pass "absolute include outside /etc/nebulaos/ is correctly refused, even though overlay_root was given and the file exists there"
	else
		fail "absolute include outside /etc/nebulaos/ failed, but not for the expected reason ($(cat "$WORK/s14-log.txt"))"
	fi
fi

# --- Scenario 15: an absolute /etc/nebulaos/... include with NO -----------
# --- overlay_root given at all is refused too, not silently ignored -------

d="$WORK/s15"; write_clean_fixture "$d"
cat > "$d/printer.cfg" <<'EOF'
[include frontend-controls.cfg]
[include GuppyScreen/guppy_cmd.cfg]
[include /etc/nebulaos/klipper/machine.cfg]

[printer]
kinematics: cartesian
EOF
closure15="$WORK/s15-closure.txt"
if frontend_controls_resolve_closure "$d" printer.cfg "$closure15" >"$WORK/s15-log.txt" 2>&1; then
	fail "absolute /etc/nebulaos/... include resolved despite no overlay_root being given"
else
	if grep -q "no overlay_root was given" "$WORK/s15-log.txt"; then
		pass "absolute /etc/nebulaos/... include is correctly refused when no overlay_root is given at all"
	else
		fail "missing-overlay_root case failed, but not for the expected reason ($(cat "$WORK/s15-log.txt"))"
	fi
fi

echo ""
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
