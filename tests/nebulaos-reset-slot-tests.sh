#!/bin/sh
#
# Offline tests for the boot half of the clean NebulaOS reset
# (nebulaos-clean-reset, S2) and the boot slot swap (nebulaos-slot-swap, S3),
# 2026-10-11. /usr/data and the OTA marker are files in a temp tree.
#
# Usage: sh tests/nebulaos-reset-slot-tests.sh

set -u
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY="$REPO_ROOT/scripts/build/overlay"
NCR="$OVERLAY/usr/libexec/nebulaos/nebulaos-clean-reset"
SWAP="$OVERLAY/usr/libexec/nebulaos/nebulaos-slot-swap"
OTA_LIB="$OVERLAY/etc/ota_marker.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
check() { if eval "$2"; then pass; else fail "$1"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/reset-slot-tests.XXXXXX") || exit 1
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

setup() {
	rm -rf "$T/d"; mkdir -p "$T/d/nebulaos/printer_data/config" "$T/d/nebulaos/system" \
		"$T/d/printer_data/gcodes" "$T/d/creality"
	echo "[printer]" > "$T/d/nebulaos/printer_data/config/printer.cfg"
	echo "root:hash:" > "$T/d/nebulaos/system/shadow"
	echo "02:aa:bb:cc:dd:ee" > "$T/d/nebulaos/wifi-mac-seed"
	echo "benchy" > "$T/d/printer_data/gcodes/benchy.gcode"
	echo "theirs" > "$T/d/creality/file"
	export NCR_DATA="$T/d"
}
run_ncr() { ( . "$NCR" && ncr_run ); }

# --- clean reset -------------------------------------------------------------
setup; run_ncr >/dev/null
check "no flag: nothing changes" '[ -f "$T/d/nebulaos/printer_data/config/printer.cfg" ]'

setup; echo "requested=x" > "$T/d/.nebulaos-clean-reset"; out=$(run_ncr)
check "flag: namespace wiped" '[ ! -e "$T/d/nebulaos/printer_data" ] && [ ! -e "$T/d/nebulaos/system" ]'
check "flag: MAC seed kept" '[ "$(cat "$T/d/nebulaos/wifi-mac-seed")" = "02:aa:bb:cc:dd:ee" ]'
check "flag: only the MAC seed is left" '[ "$(ls -A "$T/d/nebulaos")" = wifi-mac-seed ]'
check "flag removed" '[ ! -e "$T/d/.nebulaos-clean-reset" ]'
check "G-code folder untouched" '[ "$(cat "$T/d/printer_data/gcodes/benchy.gcode")" = benchy ]'
check "other slot's files untouched" '[ "$(cat "$T/d/creality/file")" = theirs ]'
check "no wipe directory left" '! ls -d "$T"/d/.nebulaos-wiping-* >/dev/null 2>&1'
check "logged" 'echo "$out" | grep -q "data wiped"'

setup; mkdir -p "$T/d/.nebulaos-wiping-1-1/apps"; echo x > "$T/d/.nebulaos-wiping-1-1/apps/f"
run_ncr >/dev/null
check "interrupted wipe finished on the next boot" '[ ! -e "$T/d/.nebulaos-wiping-1-1" ]'
check "and the live namespace kept" '[ -f "$T/d/nebulaos/printer_data/config/printer.cfg" ]'

setup; rm -rf "$T/d/nebulaos"; echo "requested=x" > "$T/d/.nebulaos-clean-reset"; run_ncr >/dev/null
check "flag without a namespace: flag cleared, nothing else" '[ ! -e "$T/d/.nebulaos-clean-reset" ] && [ ! -e "$T/d/nebulaos" ]'

if [ "$(id -u)" != 0 ]; then
	setup; echo "requested=x" > "$T/d/.nebulaos-clean-reset"; chmod a-w "$T/d"
	out=$(run_ncr)
	chmod u+w "$T/d"
	check "read-only /usr/data: postponed, nothing wiped" \
		'[ -f "$T/d/nebulaos/printer_data/config/printer.cfg" ] && [ -f "$T/d/.nebulaos-clean-reset" ] && echo "$out" | grep -q postponed'
fi

check "S01persistent-datastore runs it before seeding" \
	'awk "/ncr_run/{r=NR} /seed_once \/opt\/printer_data/{s=NR} END{exit !(r && s && r < s)}" "$OVERLAY/etc/init.d/S01persistent-datastore"'

# --- slot swap ------------------------------------------------------------------
# The real ota_marker.sh, pointed at a 512-byte file instead of mmcblk0p1.
mkdir -p "$T/ota"
sed "s#/dev/mmcblk0p1#$T/ota/p1#g; s#/opt/nebulaos/tools/plr_tombstone.py#$T/ota/tombstone.py#g" "$OTA_LIB" > "$T/ota/lib.sh"
fresh_marker() { printf 'ota:kernel2\n\n' > "$T/ota/p1"; head -c 499 /dev/zero >> "$T/ota/p1"; }
swap() { OTA_MARKER_LIB="$T/ota/lib.sh" OTA_MARKER_DEV="$T/ota/p1" sh "$SWAP" "$@"; }

fresh_marker; swap other >/dev/null; rc=$?
check "other: exit 0" '[ $rc -eq 0 ]'
check "other: exact marker bytes" '[ "$(head -c 12 "$T/ota/p1" | od -An -tx1 | tr -d " \n")" = "6f74613a6b65726e656c0a0a" ]'
check "other: rest zeroed, size kept" '[ "$(tail -c 500 "$T/ota/p1" | tr -d "\000" | wc -c)" -eq 0 ] && [ "$(wc -c < "$T/ota/p1")" -eq 512 ]'
swap nebulaos >/dev/null; rc=$?
check "nebulaos: back to ota:kernel2" '[ $rc -eq 0 ] && [ "$(head -n1 "$T/ota/p1")" = ota:kernel2 ]'
swap "ota:kernel" >/dev/null 2>&1; rc=$?
check "raw marker values refused (usage 64)" '[ $rc -eq 64 ] && [ "$(head -n1 "$T/ota/p1")" = ota:kernel2 ]'
swap >/dev/null 2>&1; rc=$?
check "no argument: usage 64" '[ $rc -eq 64 ]'
printf 'write_ota_marker() { :; }\n' > "$T/ota/broken.sh"
fresh_marker; OTA_MARKER_LIB="$T/ota/broken.sh" OTA_MARKER_DEV="$T/ota/p1" sh "$SWAP" other >/dev/null 2>&1; rc=$?
check "write not landing: read-back fails (exit 2)" '[ $rc -eq 2 ]'

echo "nebulaos-reset-slot-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
