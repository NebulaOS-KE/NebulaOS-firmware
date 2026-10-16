#!/bin/sh
# G66 (2026-10-16): "Clean up Creality files" deletes a fixed list of
# /usr/data entries. Nothing NebulaOS ships (overlay, screen) may use one of
# them - except printer_data/gcodes, which the cleanup never touches.
# The Hardware Agent may READ printer_data for diagnostics (captures, a log
# fallback); it never relies on it.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLEANUP="$ROOT/scripts/build/overlay/usr/lib/nebulaos/python/nebulaos_osconfig/cleanup.py"
GUPPY="$ROOT/../NebulaOS-guppyscreen/src"
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

names=$(sed -n 's/^    ("\([^"]*\)", ".*/\1/p' "$CLEANUP")
[ "$(echo "$names" | wc -w)" -ge 10 ] && pass || fail "could not read the delete list from cleanup.py"
for keep in nebulaos nebulaos-hwagent macaddr.txt wpa_supplicant.conf factory_test_result .keep \
	.nebulaos-clean-reset printer_data; do
	echo "$names" | grep -qx "$keep" && fail "$keep is on the delete list" || pass
done

refs() { # NAME - live (non-comment) references in what the image and screen ship
	grep -rnE "/usr/data/$1([/\"' ]|$)" "$ROOT/scripts/build/overlay" "$GUPPY" 2>/dev/null \
		| grep -v "/nebulaos_osconfig/cleanup.py:" \
		| grep -vE "^[^:]+:[0-9]+:[[:space:]]*(#|//|\*)"
}
for n in $names; do
	r=$(refs "$n")
	[ -z "$r" ] && pass || fail "/usr/data/$n is on the delete list but used: $r"
done
# printer_data: only its gcodes folder may be used
r=$(refs printer_data | grep -v "/usr/data/printer_data/gcodes")
[ -z "$r" ] && pass || fail "printer_data used beyond gcodes: $r"
grep -q 'KEEP_IN_PRINTER_DATA = ("gcodes",)' "$CLEANUP" && pass || fail "gcodes not kept"

echo "creality-cleanup-list-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
