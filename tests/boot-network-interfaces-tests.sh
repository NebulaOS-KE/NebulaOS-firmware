#!/bin/sh
#
# BOOT-01 (2026-10-05): offline tests for scripts/build/overlay/etc/network/
# interfaces. The KE has no Ethernet; an eth0 stanza made S40network's
# `ifup -a` wait 15 s on every boot for an interface that never appears.
#
# Usage: sh tests/boot-network-interfaces-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT="$SCRIPT_DIR/.."
IF="$ROOT/scripts/build/overlay/etc/network/interfaces"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$IF" ] || { echo "FATAL: $IF not found"; exit 1; }

# Only non-comment lines count.
body=$(grep -v '^[[:space:]]*#' "$IF")

echo "$body" | grep -qw 'eth0' && fail "an eth0 line is still present" || pass
echo "$body" | grep -qE '^auto[[:space:]]+eth' && fail "an 'auto eth*' line is still present" || pass
echo "$body" | grep -q 'nfs_check' && fail "the eth0 nfs_check pre-up hook is still present" || pass

echo "$body" | grep -qxE 'auto lo' && pass || fail "auto lo missing"
echo "$body" | grep -qxE 'iface lo inet loopback' && pass || fail "lo loopback stanza missing"
echo "$body" | grep -qxE 'auto wlan0' && pass || fail "auto wlan0 missing"
echo "$body" | grep -qxE 'iface wlan0 inet dhcp' && pass || fail "wlan0 dhcp stanza missing"

# Every auto interface must be one the KE actually has (lo, wlan0).
for i in $(echo "$body" | awk '$1 == "auto" { for (n = 2; n <= NF; n++) print $n }'); do
	case "$i" in
		lo|wlan0) pass ;;
		*) fail "auto interface '$i' is not hardware the KE has" ;;
	esac
done

# The only wait-delay left belongs to wlan0, which exists by the time
# S40network runs (S01wifi brings it up first).
stanza=""
echo "$body" | while read -r k v _; do
	case "$k" in
		iface) stanza="$v" ;;
		wait-delay) [ "$stanza" = "wlan0" ] || echo "BAD $stanza" ;;
	esac
done | grep -q BAD && fail "a wait-delay belongs to an interface other than wlan0" || pass

echo "boot-network-interfaces-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
