#!/bin/sh
# Stages regulatory.db/regulatory.db.p7s under scripts/build/overlay/lib/firmware/
# so CONFIG_EXTRA_FIRMWARE can bake them directly into the kernel image (see
# NebulaOS-kernel nebulaos_halley5_v30_defconfig) -
# cfg80211 requests these before the SquashFS rootfs is mounted, so having
# them correctly packaged in the rootfs alone (via Buildroot's own
# BR2_PACKAGE_WIRELESS_REGDB, already enabled) isn't sufficient; see
# docs/BOOT_WARNING_AUDIT.md's regulatory.db entry for the full trace.
#
# Deliberately mirrors the exact version Buildroot's own wireless-regdb
# package pins (vendor/buildroot-x2000/package/wireless-regdb/wireless-regdb.mk,
# WIRELESS_REGDB_VERSION), fetched from the same BR2_KERNEL_MIRROR-relative
# path, so the copy staged here and the copy Buildroot installs into the
# rootfs are byte-identical - not two independently-sourced regulatory
# databases that happen to agree today.
#
# Unlike the proprietary WiFi firmware fetch-cyw43430-wifi-firmware.sh
# handles, wireless-regdb is ISC-licensed and freely redistributable - but this is
# still a fetch-and-verify script, not a committed binary, so a version bump
# is a deliberate, reviewable diff to this script rather than a silent binary
# swap in git history.
#
# Usage: ./scripts/firmware/fetch-wireless-regdb.sh [cached-tarball-path]
# With no argument, downloads fresh. With an argument, verifies and uses that
# local file instead of hitting the network (offline-cache path) - still
# checked against the same pinned hash either way.

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
DEST="$REPO_ROOT/scripts/build/overlay/lib/firmware"

# Pinned to match vendor/buildroot-x2000/package/wireless-regdb/wireless-regdb.mk
# exactly - keep these two in sync if that package's version ever changes.
REGDB_VERSION="2023.09.01"
REGDB_MIRROR="https://cdn.kernel.org/pub/software/network/wireless-regdb"
REGDB_TARBALL="wireless-regdb-${REGDB_VERSION}.tar.xz"

# Fixed hashes for the exact upstream release - computed once, directly, from
# a real download of this exact URL (not copied from an unverified third
# party). A version bump means re-deriving these deliberately, not editing
# them to make a mismatch go away.
TARBALL_SHA256="26d4c2a727cc59239b84735aad856b7c7d0b04e30aa5c235c4f7f47f5f053491"
REGDB_SHA256="0a4abd7ae20d07bb70642937ccb2293a72a6504730eea45a698882599f586368"
REGDB_P7S_SHA256="bcd81aed039ea6b9b6f3726fbf26911a0caf4a5d894210e0fa2effb384d6b326"
LICENSE_SHA256="678b0df753c86198fc496d1f1033429bbd57f101472132ee7eaaf9f5e0a7fae1"

die() {
	echo "ABORT: $1" >&2
	exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

TARBALL_PATH="$WORK/$REGDB_TARBALL"

if [ -n "$1" ]; then
	echo "Using cached tarball: $1"
	[ -f "$1" ] || die "cached tarball $1 does not exist"
	cp "$1" "$TARBALL_PATH"
else
	echo "Fetching $REGDB_MIRROR/$REGDB_TARBALL ..."
	if command -v wget >/dev/null 2>&1; then
		wget -q -O "$TARBALL_PATH" "$REGDB_MIRROR/$REGDB_TARBALL" || die "download failed"
	elif command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "$TARBALL_PATH" "$REGDB_MIRROR/$REGDB_TARBALL" || die "download failed"
	else
		die "neither wget nor curl is available"
	fi
fi

ACTUAL_TARBALL_SHA256=$(sha256sum "$TARBALL_PATH" | awk '{print $1}')
[ "$ACTUAL_TARBALL_SHA256" = "$TARBALL_SHA256" ] || \
	die "tarball sha256 mismatch: got $ACTUAL_TARBALL_SHA256, expected $TARBALL_SHA256 - refusing to use an unverified/stale/tampered file"

tar xf "$TARBALL_PATH" -C "$WORK"
SRC="$WORK/wireless-regdb-$REGDB_VERSION"
[ -d "$SRC" ] || die "expected directory $SRC not found after extraction"

for pair in "regulatory.db:$REGDB_SHA256" "regulatory.db.p7s:$REGDB_P7S_SHA256" "LICENSE:$LICENSE_SHA256"; do
	f="${pair%%:*}"
	expect="${pair##*:}"
	[ -f "$SRC/$f" ] || die "$f missing from extracted tarball"
	actual=$(sha256sum "$SRC/$f" | awk '{print $1}')
	[ "$actual" = "$expect" ] || die "$f sha256 mismatch: got $actual, expected $expect"
done

mkdir -p "$DEST"
cp "$SRC/regulatory.db" "$DEST/regulatory.db"
cp "$SRC/regulatory.db.p7s" "$DEST/regulatory.db.p7s"
cp "$SRC/LICENSE" "$DEST/regulatory.db.LICENSE"

echo
echo "Staged (wireless-regdb $REGDB_VERSION, all hashes verified):"
sha256sum "$DEST/regulatory.db" "$DEST/regulatory.db.p7s"
echo
echo "These are gitignored (see .gitignore) - re-run this script after a fresh"
echo "checkout, or whenever CONFIG_EXTRA_FIRMWARE's staged copy needs refreshing,"
echo "rather than expecting them to already be present."
