#!/bin/sh
#
# Phase 1.5 persistent-namespace mission (2026-08). Namespace-architecture
# guard: a lightweight lint over the tracked overlay source that makes the
# exact class of regression this mission fixed (a top-level compatibility
# symlink silently aliasing NebulaOS's own private state under a
# stock-shared path, or NebulaOS-specific state landing on the shared
# credentials path) visible in CI/build validation instead of needing a
# human to notice it again.
#
# Deliberately NOT a naive "grep for /usr/data and flag every hit" - that
# would flag the one legitimate exception (the shared gcode path) along
# with everything else. The allowlist below is small and each entry is
# commented with why it is allowed, per this mission's own governing brief.
#
# Usage: sh tests/nebulaos-namespace-ownership-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OVERLAY="$REPO_ROOT/scripts/build/overlay"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# --- Guard 1: no active code creates or relies on the two retired ---------
# --- top-level compatibility aliases --------------------------------------
#
# /usr/data/printer_data (bare, NOT /usr/data/printer_data/gcodes) and
# /usr/data/guppyscreen used to be whole-directory symlinks into NebulaOS's
# own private /opt/printer_data and /opt/guppyscreen trees - removed this
# mission because they silently aliased NebulaOS's ENTIRE private state
# under a stock-shared path (or, on a device with real prior stock content
# there, silently did nothing and let NebulaOS's own writes land inside
# stock's directory instead). Any new occurrence of either bare path in
# active code is exactly this regression coming back.
#
# Allowlist (each entry named, not a blanket exemption):
#   - Comment lines (# ...) anywhere: this mission's own commit left
#     deliberate forensic-history comments (S01persistent-datastore's
#     incident record, explanatory notes in the files it fixed) that name
#     the old paths in prose. A comment cannot execute, so it cannot
#     reintroduce the namespace-ownership bug - only a live path literal
#     in real code can.
#   - (retired G63, 2026-10-16) S04nebulaos-migrate's migrate_static_ip_state() (audit F-11): a
#     migration that moves state OUT of the retired alias has to name the
#     alias it is moving out of. It only ever reads and `mv`s away from
#     that path and never writes into it, which is the opposite of the
#     regression this guard exists to catch. Named here specifically, not
#     blanket-exempted: any OTHER live reference in that file still fails.
check_no_bare_printer_data_or_guppyscreen_alias() {
	hits=$(grep -rn '/usr/data/printer_data\b\|/usr/data/guppyscreen\b' \
		"$OVERLAY/etc" "$OVERLAY/opt" 2>/dev/null \
		| grep -v '/usr/data/printer_data/gcodes' \
		| awk -F: '{
			content = $0
			sub(/^[^:]*:[^:]*:/, "", content)
			sub(/^[[:space:]]*/, "", content)
			if (content !~ /^#/) print
		}' \
		| grep -v '^[^:]*/S04nebulaos-migrate:[0-9]*:[[:space:]]*_msis_old_dir="/usr/data/printer_data/config"$')

	if [ -z "$hits" ]; then
		pass "no active-code reference to the retired /usr/data/printer_data or /usr/data/guppyscreen top-level aliases (outside the documented gcodes exception and S01persistent-datastore's own forensic history comments)"
	else
		fail "found a reference to a retired top-level namespace alias outside the allowlist - this is the exact class of bug this mission fixed:
$hits"
	fi
}

# --- Guard 2: the old Wi-Fi path is never treated as authoritative --------
# outside the migration script and S01wifi's own comments. In particular,
# nothing should ever WRITE to /usr/data/nebulaos/wpa_supplicant.conf as a
# plain file target outside nebulaos-wifi-migrate.sh - if it does, that is
# the exact split-brain hazard ("wpa_supplicant reads NEW while something
# else writes OLD as a separate regular file") the governing brief named.
check_old_wifi_path_not_authoritative_elsewhere() {
	hits=$(grep -rln '/usr/data/nebulaos/wpa_supplicant\.conf' "$OVERLAY/etc" "$OVERLAY/opt" 2>/dev/null)
	unexpected=""
	for f in $hits; do
		case "$f" in
			"$OVERLAY/etc/nebulaos-wifi-migrate.sh") ;;
			"$OVERLAY/etc/init.d/S01wifi") ;;
			*) unexpected="$unexpected $f" ;;
		esac
	done
	if [ -z "$unexpected" ]; then
		pass "the old Wi-Fi path (/usr/data/nebulaos/wpa_supplicant.conf) is referenced only in the migration script and S01wifi, nowhere else claims it as authoritative"
	else
		fail "the old Wi-Fi path is referenced outside the migration script/S01wifi - possible split-brain hazard:$unexpected"
	fi
}

# --- Guard 3: the new canonical Wi-Fi path is the one CONF actually used --
check_new_wifi_path_is_canonical() {
	if grep -q 'NEBULAOS_WIFI_NEW:-/usr/data/nebulaos/network/wpa_supplicant\.conf' \
		"$OVERLAY/etc/nebulaos-wifi-migrate.sh" 2>/dev/null; then
		pass "the canonical Wi-Fi path default is /usr/data/nebulaos/network/wpa_supplicant.conf"
	else
		fail "could not confirm the canonical Wi-Fi path default in nebulaos-wifi-migrate.sh"
	fi
}

# --- Guard 4: image-owned Klipper/Moonraker config lives under ------------
# /etc/nebulaos/, never under the persistent printer_data tree
check_no_klipper_pin_conf_in_persistent_tree() {
	if [ -e "$OVERLAY/opt/printer_data/config/nebulaos" ]; then
		fail "scripts/build/overlay/opt/printer_data/config/nebulaos/ still exists - the qualified Klipper-stack pins belong at /etc/nebulaos/moonraker/klipper-pin.conf (image-owned), not in the persistent printer_data tree"
	else
		pass "no persistent-tree printer_data/config/nebulaos/ island (retired - pins are image-owned now)"
	fi
	for f in machine.cfg prtouch.cfg platform.cfg; do
		if [ -f "$OVERLAY/etc/nebulaos/klipper/$f" ]; then
			pass "/etc/nebulaos/klipper/$f is present in the tracked overlay"
		else
			fail "/etc/nebulaos/klipper/$f is missing from the tracked overlay"
		fi
	done
	if [ -f "$OVERLAY/etc/nebulaos/moonraker/klipper-pin.conf" ]; then
		pass "/etc/nebulaos/moonraker/klipper-pin.conf is present in the tracked overlay"
	else
		fail "/etc/nebulaos/moonraker/klipper-pin.conf is missing from the tracked overlay"
	fi
}

# --- Guard 5: the persistent printer.cfg/moonraker.conf entrypoints -------
# reference the immutable config via absolute /etc/nebulaos/... includes
check_persistent_entrypoints_include_immutable_config() {
	pcfg="$OVERLAY/opt/printer_data/config/printer.cfg"
	mcfg="$OVERLAY/opt/printer_data/config/moonraker.conf"
	if grep -qxF '[include /etc/nebulaos/klipper/platform.cfg]' "$pcfg" 2>/dev/null; then
		pass "persistent printer.cfg includes /etc/nebulaos/klipper/platform.cfg"
	else
		fail "persistent printer.cfg does not include /etc/nebulaos/klipper/platform.cfg"
	fi
	if grep -qxF '[include /etc/nebulaos/moonraker/klipper-pin.conf]' "$mcfg" 2>/dev/null; then
		pass "persistent moonraker.conf includes /etc/nebulaos/moonraker/klipper-pin.conf"
	else
		fail "persistent moonraker.conf does not include /etc/nebulaos/moonraker/klipper-pin.conf"
	fi
}

echo "=== NebulaOS persistent-namespace ownership guard ==="
check_no_bare_printer_data_or_guppyscreen_alias
check_old_wifi_path_not_authoritative_elsewhere
check_new_wifi_path_is_canonical
check_no_klipper_pin_conf_in_persistent_tree
check_persistent_entrypoints_include_immutable_config

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
