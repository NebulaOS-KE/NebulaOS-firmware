#!/bin/sh
#
# Files this repository ships but ANOTHER repository owns must not drift.
#
# Audit finding F-11. scripts/build/overlay/opt/printer_data/config/
# GuppyScreen/scripts/static_ip.py is owned by NebulaOS-guppyscreen
# (k1/scripts/static_ip.py). The firmware repo carries a copy because the
# compiled guppyscreen binary hardcodes the runtime path
# /opt/printer_data/config/GuppyScreen/scripts/static_ip.py
# (NebulaOS-guppyscreen/src/static_ip_panel.cpp:12), so the file must be
# present in the shipped printer_data config tree.
#
# That copy silently reverted a fix that had already landed upstream of it.
# NEBULASCREEN_PIN 5f1911ac - subject "fix(paths): route NebulaOS-owned state
# through /opt bind mounts, not /usr/data top-level aliases" - moved
# static_ip.py's state off the retired /usr/data/printer_data alias, which
# overlaps stock's shared tree. A later firmware commit restored the file
# "byte-identical from a live, already-qualified device", and the device it
# was taken from predated that fix, so the two reverted lines came back. The
# copy had no mechanical link to the canonical version, so nothing noticed.
#
# This test is that link. It is deliberately a byte-for-byte comparison
# against the OWNING repository at the exact NEBULASCREEN_PIN the firmware
# manifest ships - not a spot-check of the two lines that happened to drift
# last time.
#
# Usage: sh tests/guppyscreen-owned-files-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
DEPS="$REPO_ROOT/manifests/dependencies.conf"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

[ -f "$DEPS" ] || { echo "SKIP: $DEPS not present"; exit 0; }
PIN=$(grep -E '^NEBULASCREEN_PIN=' "$DEPS" | tail -1 | cut -d= -f2)
[ -n "$PIN" ] || { echo "SKIP: NEBULASCREEN_PIN not set in the manifest"; exit 0; }

# Resolve the OWNING repository at exactly the shipping pin. A checkout at
# any other commit is not evidence about what ships, so it is refused rather
# than silently used - the same rule tests/virgin-first-boot-simulation-
# tests.sh applies to the extensions checkout.
GUPPY_REPO=""
if [ -d "$REPO_ROOT/vendor/nebulaos-nebulascreen/.git" ]; then
	GUPPY_REPO="$REPO_ROOT/vendor/nebulaos-nebulascreen"
elif [ -d "$REPO_ROOT/../NebulaOS-nebulascreen/.git" ]; then
	GUPPY_REPO=$(cd "$REPO_ROOT/../NebulaOS-nebulascreen" && pwd)
elif [ -d "$REPO_ROOT/../NebulaOS-guppyscreen/.git" ]; then
	GUPPY_REPO=$(cd "$REPO_ROOT/../NebulaOS-guppyscreen" && pwd)
fi
if [ -z "$GUPPY_REPO" ]; then
	echo "SKIP: no NebulaOS-nebulascreen (or old NebulaOS-guppyscreen) checkout found (run 00-fetch-vendor-sources.sh, or place the sibling checkout beside this repo)"
	exit 0
fi
if ! git -C "$GUPPY_REPO" cat-file -e "${PIN}^{commit}" 2>/dev/null; then
	echo "SKIP: $GUPPY_REPO does not contain NEBULASCREEN_PIN $PIN - refusing to compare against a checkout that is not what ships"
	exit 0
fi

# owned path in NebulaOS-guppyscreen : path in this repo's overlay. Empty since
# the GUI readiness work (2026-10-10): static_ip.py was the only entry, and the
# static IP panel now uses machine.nebulaos.network.* instead.
OWNED_FILES=""

for spec in $OWNED_FILES; do
	src=${spec%%:*}
	dst=${spec#*:}
	local_copy="$REPO_ROOT/$dst"
	if [ ! -f "$local_copy" ]; then
		fail "$dst is missing from this repository, but the guppyscreen binary needs it"
		continue
	fi
	if ! git -C "$GUPPY_REPO" cat-file -e "$PIN:$src" 2>/dev/null; then
		fail "$src does not exist in NebulaOS-guppyscreen at $PIN - the ownership mapping is stale"
		continue
	fi
	if git -C "$GUPPY_REPO" show "$PIN:$src" | cmp -s - "$local_copy"; then
		pass "$dst is byte-identical to NebulaOS-guppyscreen@${PIN%%??????????????????????????????}...:$src"
	else
		fail "$dst has DRIFTED from its owner (NebulaOS-guppyscreen@$PIN:$src). Do not hand-edit this copy - update the owning repository, advance NEBULASCREEN_PIN, then re-sync. Diff:
$(git -C "$GUPPY_REPO" show "$PIN:$src" | diff - "$local_copy" | head -20)"
	fi
done

# static_ip.py retired: the shipped GuppyScreen must not depend on it, and the
# image must not ship a copy that nothing calls.
STATIC_IP_REL="scripts/build/overlay/opt/printer_data/config/GuppyScreen/scripts/static_ip.py"
if git -C "$GUPPY_REPO" grep -q "static_ip\.py" "$PIN" -- src 2>/dev/null; then
	fail "NebulaOS-guppyscreen@$PIN still references static_ip.py in src/ - the firmware copy cannot be dropped yet"
else
	pass "NebulaOS-guppyscreen@${PIN%%??????????????????????????????}... does not use static_ip.py"
fi
if [ -e "$REPO_ROOT/$STATIC_IP_REL" ]; then
	fail "$STATIC_IP_REL is still shipped although nothing calls it"
else
	pass "static_ip.py is not shipped"
fi

echo ""
echo "guppyscreen-owned-files-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
