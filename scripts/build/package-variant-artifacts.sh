#!/bin/sh
# Packages a completed build's artifacts (xImage, rootfs.squashfs,
# build-manifest.txt, and the DTS/Kconfig fragment used to produce it)
# into a clearly-labeled deployment package directory, for the later
# Mode B hardware qualification (pre-qualification mission Phase A12,
# 2026-07-31).
#
# This does NOT flash anything, does NOT touch the device, and does NOT
# duplicate scripts/flash-spare-slot.sh's own already-hardware-proven
# safety logic (real checksum verification, refusal to overwrite the
# live slot, --check-only support) - it only organizes build output into
# an unambiguous, labeled package so a later flash invocation can point
# at the exact right files without guessing which build produced them.
#
# Usage: sh scripts/build/package-variant-artifacts.sh <variant-label> [package-root]
#   <variant-label>  e.g. B0, B1, B2, B3, B4 - becomes the package
#                     directory name (with a date suffix, since more than
#                     one build of the same variant label may happen
#                     over time).
#   [package-root]    where packages are written (default:
#                      build-work/deploy-packages, gitignored - these are
#                      large binary artifacts, never committed).

set -eu

VARIANT_LABEL="${1:?usage: $0 <variant-label> [package-root]}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
PACKAGE_ROOT="${2:-$REPO_ROOT/build-work/deploy-packages}"
ARTIFACT_DIR="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"

for required in "$ARTIFACT_DIR/xImage" "$ARTIFACT_DIR/rootfs.squashfs" "$ARTIFACT_DIR/build-manifest.txt"; do
	[ -f "$required" ] || {
		echo "FATAL: $required not found - run the full 00-06 build pipeline first" >&2
		exit 1
	}
done

TS=$(date -u +%Y%m%dT%H%M%SZ)
PKG_DIR="$PACKAGE_ROOT/${VARIANT_LABEL}-${TS}"
mkdir -p "$PKG_DIR"

cp "$ARTIFACT_DIR/xImage" "$PKG_DIR/xImage"
cp "$ARTIFACT_DIR/rootfs.squashfs" "$PKG_DIR/rootfs.squashfs"
cp "$ARTIFACT_DIR/build-manifest.txt" "$PKG_DIR/build-manifest.txt"
cp "$ARTIFACT_DIR/halley5-nebulaos-fragment.config" "$PKG_DIR/halley5-nebulaos-fragment.config" 2>/dev/null || true
cp "$ARTIFACT_DIR/buildroot.config" "$PKG_DIR/buildroot.config" 2>/dev/null || true
cp "$ARTIFACT_DIR/kernel.config" "$PKG_DIR/kernel.config" 2>/dev/null || true
cp "$ARTIFACT_DIR/halley5_v30.dts" "$PKG_DIR/halley5_v30.dts" 2>/dev/null || true

. "$REPO_ROOT/manifests/dependencies.conf"

{
	echo "package_label=$VARIANT_LABEL"
	echo "packaged_at=$TS"
	echo "kernel_pin=$KERNEL_PIN"
	echo ""
	echo "Files in this package:"
	echo "  xImage - kernel image"
	echo "  rootfs.squashfs - production rootfs"
	echo "  build-manifest.txt - the real build's own recorded git commits/"
	echo "    hashes for every vendored source, this project's own source of"
	echo "    truth for provenance (see docs/NEBULAOS_RELEASE_ARTIFACT_"
	echo "    PROVENANCE.md and the reproducibility work in Phase A2)"
	echo "  halley5-nebulaos-fragment.config, buildroot.config, kernel.config,"
	echo "    halley5_v30.dts - the exact configuration that produced this"
	echo "    package, for later diffing against any other variant"
	echo ""
	echo "This package does not flash anything by itself. To deploy it, use"
	echo "scripts/flash-spare-slot.sh's own existing, hardware-proven"
	echo "sequence (read-only --check-only first, review, then a separate"
	echo "real-write invocation) - see docs/NEBULAOS_COMBINED_WIFI_CAMERA_RT_"
	echo "QUALIFICATION.md for the exact commands."
} > "$PKG_DIR/PACKAGE_INFO.txt"

echo "== packaged $VARIANT_LABEL -> $PKG_DIR =="
ls -la "$PKG_DIR"
