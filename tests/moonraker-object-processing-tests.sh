#!/bin/sh
# G110 (Run 20, Tim 2026-10-25): exclude objects stays on. Moonraker's
# [file_manager] enable_object_processing: True gives Klipper the object
# outlines of every print - Exclude Object, START_PRINT's adaptive mesh and
# the purge line next to the print depend on it. This checks the shipped
# moonraker.conf seed and that 06-verify.sh refuses an image without it.
#
# Usage: sh tests/moonraker-object-processing-tests.sh
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
CONF="$REPO/scripts/build/overlay/opt/printer_data/config/moonraker.conf"
VERIFY="$REPO/scripts/build/06-verify.sh"
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# the same section extraction + pattern as 06-verify.sh
has_object_processing() {
	awk '/^\[file_manager\]$/ { grab=1; next } /^\[/ { grab=0 } grab { print }' "$1" \
		| grep -qE "^enable_object_processing:[[:space:]]*[Tt]rue[[:space:]]*$"
}

if has_object_processing "$CONF"; then
	pass "shipped moonraker.conf has [file_manager] enable_object_processing: True"
else
	fail "shipped moonraker.conf lacks [file_manager] enable_object_processing: True"
fi

if grep -qF 'MISS [file_manager] enable_object_processing: True is missing' "$VERIFY" \
	&& grep -qF 'grep -qE "^enable_object_processing:[[:space:]]*[Tt]rue[[:space:]]*$"' "$VERIFY"; then
	pass "06-verify.sh checks enable_object_processing with the same pattern"
else
	fail "06-verify.sh has no enable_object_processing check (or a different pattern)"
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/moonraker-objproc.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
printf '[server]\nport: 7125\n\n[file_manager]\nenable_object_processing: False\n' > "$T/off.conf"
printf '[server]\nport: 7125\n\n[machine]\nenable_object_processing: True\n' > "$T/wrong-section.conf"
printf '[server]\nport: 7125\n\n[file_manager]\n# enable_object_processing: True\n' > "$T/commented.conf"
for f in off wrong-section commented; do
	if has_object_processing "$T/$f.conf"; then
		fail "check accepts a moonraker.conf with object processing $f"
	else
		pass "check refuses a moonraker.conf with object processing $f"
	fi
done

echo "MOONRAKER_OBJECT_PROCESSING_TESTS pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
