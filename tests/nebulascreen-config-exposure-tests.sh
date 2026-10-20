#!/bin/sh
#
# Offline, structural tests for S01persistent-datastore's new second bind
# mount of nebulascreen.json onto printer_data/config/nebulascreen/ (Phase 2
# final software closure mission, 2026-09-09, section 8).
#
# S01persistent-datastore does real `mount`/`mount --bind` calls requiring
# root and a real block device - it has no existing offline test harness at
# all (a pre-existing gap this mission does not fully close). This file
# proves the SOURCE is structurally correct (both bind mounts target the
# exact same real file, the new mount point is created before being bound
# onto, nothing else under nebulascreen/ - binaries, themes/ - is exposed);
# full functional proof (the file really is visible and editable through
# Mainsail after a real boot) happens live during first-boot acceptance.
#
# Usage: sh tests/nebulascreen-config-exposure-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
S01_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S01persistent-datastore"

[ -f "$S01_SCRIPT" ] || { echo "SKIP: $S01_SCRIPT not present"; exit 0; }

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

sh -n "$S01_SCRIPT" && pass "S01persistent-datastore has valid shell syntax" \
	|| fail "S01persistent-datastore has a shell syntax error"

if grep -qF 'mount --bind "$NS_STATE/nebulascreen.json" "$PDATA/config/nebulascreen/nebulascreen.json"' "$S01_SCRIPT"; then
	pass "a bind mount from \$NS_STATE/nebulascreen.json onto printer_data/config/nebulascreen/nebulascreen.json exists"
else
	fail "the expected new bind mount line is missing"
fi

original_bind_count=$(grep -cF 'mount --bind "$NS_STATE/nebulascreen.json"' "$S01_SCRIPT")
if [ "$original_bind_count" = "3" ]; then
	pass "exactly three bind mounts of the same real \$NS_STATE/nebulascreen.json source exist (the screen's own path, \$PDATA/config and the /opt view - G63)"
else
	fail "expected exactly 3 bind mounts of \$NS_STATE/nebulascreen.json, found $original_bind_count"
fi

# G63 (2026-10-16): the /opt/printer_data view (Mainsail, SFTP, log zip) must
# get the file too, AFTER the non-recursive "$PDATA -> /opt/printer_data" bind
# - before this, Mainsail showed an empty nebulascreen.json.
opt_tree_line=$(grep -n 'mount --bind "\$PDATA" /opt/printer_data' "$S01_SCRIPT" | head -1 | cut -d: -f1)
opt_file_line=$(grep -n 'mount --bind "\$NS_STATE/nebulascreen.json" /opt/printer_data/config/nebulascreen/nebulascreen.json' "$S01_SCRIPT" | cut -d: -f1)
if [ -n "$opt_tree_line" ] && [ -n "$opt_file_line" ] && [ "$opt_tree_line" -lt "$opt_file_line" ]; then
	pass "nebulascreen.json is bound into the /opt/printer_data view after that view exists"
else
	fail "nebulascreen.json is not bound into /opt/printer_data after the tree bind (tree=$opt_tree_line file=$opt_file_line)"
fi

# The new mount point must be created (mkdir + touch) before the bind
# mount line that targets it - bind-mounting a file onto a path that does
# not exist yet fails outright.
new_bind_line=$(grep -n 'mount --bind "\$NS_STATE/nebulascreen.json" "\$PDATA/config/nebulascreen/nebulascreen.json"' "$S01_SCRIPT" | cut -d: -f1)
mkdir_line=$(grep -n 'mkdir -p "\$PDATA/config/nebulascreen"' "$S01_SCRIPT" | cut -d: -f1)
touch_line=$(grep -n 'touch "\$PDATA/config/nebulascreen/nebulascreen.json"' "$S01_SCRIPT" | cut -d: -f1)
if [ -n "$mkdir_line" ] && [ -n "$touch_line" ] && [ -n "$new_bind_line" ] \
	&& [ "$mkdir_line" -lt "$new_bind_line" ] && [ "$touch_line" -lt "$new_bind_line" ]; then
	pass "the mount point (directory + placeholder file) is created before the bind mount that targets it"
else
	fail "the mount point is not correctly created before the bind mount (mkdir=$mkdir_line touch=$touch_line bind=$new_bind_line)"
fi

# Only nebulascreen.json - never the binaries or themes/ - may be exposed
# under printer_data/config/nebulascreen/.
if grep -qE '(cp|mount).*(nebulascreen"|nebulabeep|themes)[^.].*config/nebulascreen' "$S01_SCRIPT"; then
	fail "something other than nebulascreen.json appears to be exposed under config/nebulascreen/ - binaries/themes/ must never be copied there"
else
	pass "nothing besides nebulascreen.json is exposed under config/nebulascreen/ (no binaries, no themes/)"
fi

# The placeholder-touch must be idempotent (never overwrite an existing
# file with an empty one on a later boot - the bind mount source is what
# actually matters, but the placeholder guard itself must stay a no-op
# once real content is bound over it).
if grep -qF '[ -e "$PDATA/config/nebulascreen/nebulascreen.json" ] ||' "$S01_SCRIPT"; then
	pass "the placeholder file creation is guarded (only touches if not already present)"
else
	fail "the placeholder file creation is not guarded against overwriting existing content"
fi

# Section 9: the upload area - config/uploads/ since G63 (2026-10-16): inside
# the config root, because Mainsail only uploads there. No own root.
if grep -qF 'mkdir -p "$PDATA/config/uploads/boot-logo" "$PDATA/config/uploads/mainboard-firmware"' "$S01_SCRIPT" \
	&& grep -qF '"$PDATA/config/uploads/system-image"' "$S01_SCRIPT"; then
	pass "config/uploads/{boot-logo,mainboard-firmware,system-image} are created at boot"
else
	fail "config/uploads/ creation lines are missing"
fi
if grep -q 'printer_data/uploads/' "$(dirname "$S01_SCRIPT")/S02nebulaos-namespace"; then
	fail "S02 still creates the retired printer_data/uploads/ (S04 would move it again every boot)"
else
	pass "S02 no longer creates the retired printer_data/uploads/"
fi

echo ""
echo "nebulascreen-config-exposure-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
