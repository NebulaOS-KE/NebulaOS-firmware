#!/bin/sh
# G50 (2026-10-17): export the cross-compilation SDK of a finished, attested
# firmware build for the NebulaOS package index (coreflake1/nebulaos-packages).
#
#   tools/sdk/export-sdk.sh <build run dir> <output dir>
#
# Host tooling only - the firmware build is not changed. Rules from the
# architecture review (2026-10-17):
#   - the run is only READ: Buildroot's output/host is copied out and every
#     change (relocation marker, metadata) happens on the copy
#   - the Python ABI fingerprint is COPIED from the image the build produced
#     (target/usr/share/nebulaos/python-abi), never derived again
#   - the metadata records where it came from: firmware commit, run, attested
#     xImage/rootfs sha256, build image digest, Buildroot pin
#
# Output: <output dir>/nebulaos-sdk-<abi id>.tar.xz and .sha256. After
# extracting, run ./relocate-sdk.sh once (Buildroot's own script) - the tools
# carry the build container's paths until then.
set -eu

RUN=${1:?usage: export-sdk.sh <build run dir> <output dir>}
OUT=${2:?usage: export-sdk.sh <build run dir> <output dir>}
RUN=$(cd "$RUN" && pwd)
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BR="$RUN/vendor/buildroot-x2000"
HOST="$BR/output/host"
ATTEST="$RUN/.nebulaos-build-verified"
ABI="$BR/output/target/usr/share/nebulaos/python-abi"
# Where output/host lived inside the build container - the path every
# absolute reference in the tools points at.
CONTAINER_HOST=/workspace/NebulaOS-firmware/vendor/buildroot-x2000/output/host

[ -f "$ATTEST" ] || { echo "export-sdk: $RUN has no build attestation (.nebulaos-build-verified)" >&2; exit 1; }
grep -q '^BUILD_VERIFIED=YES' "$ATTEST" || { echo "export-sdk: the build in $RUN is not verified" >&2; exit 1; }
[ -d "$HOST/bin" ] || { echo "export-sdk: no Buildroot output/host in $RUN" >&2; exit 1; }
[ -f "$ABI" ] || { echo "export-sdk: $ABI missing - this build predates G50 (no fingerprint)" >&2; exit 1; }
ABI_ID=$(sed -n 's/^id=//p' "$ABI")
[ -n "$ABI_ID" ] || { echo "export-sdk: no id in $ABI" >&2; exit 1; }

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
NAME="nebulaos-sdk-$ABI_ID"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/export-sdk.XXXXXX")
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "export-sdk: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

echo "== copying output/host (the run is not modified)"
cp -a "$HOST" "$WORK/$NAME"
SDK="$WORK/$NAME"
# Documentation and manuals are not needed to cross-build wheels.
rm -rf "$SDK/share/doc" "$SDK/share/man" "$SDK/share/info" "$SDK/share/gtk-doc"

# Buildroot's own relocation script and its marker (what `make sdk` would
# write) - on the copy.
cp "$BR/support/misc/relocate-sdk.sh" "$SDK/relocate-sdk.sh"
chmod 755 "$SDK/relocate-sdk.sh"
mkdir -p "$SDK/share/buildroot"
printf '%s\n' "$CONTAINER_HOST" > "$SDK/share/buildroot/sdk-location"

cp "$ABI" "$SDK/python-abi"
{
	echo "sdk=$NAME"
	echo "python_abi_id=$ABI_ID"
	grep -E '^(SOURCE_HEAD|BUILD_MODE|XIMAGE_SHA256|ROOTFS_SQUASHFS_SHA256|BUILDER_DIGEST|ATTESTED_AT)=' "$ATTEST"
	echo "run=${RUN##*/}"
	grep -E '^(BUILD_IMAGE_REPO|BUILD_IMAGE_DIGEST|BUILDROOT_PIN)=' "$REPO_ROOT/manifests/dependencies.conf"
	echo "exported_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$SDK/sdk-info"

echo "== packing $NAME.tar.xz"
tar -C "$WORK" -cf - "$NAME" | xz -T0 -6 > "$OUT/$NAME.tar.xz"
( cd "$OUT" && sha256sum "$NAME.tar.xz" > "$NAME.tar.xz.sha256" )
echo "SDK=$OUT/$NAME.tar.xz"
echo "SDK_SHA256=$(cut -d' ' -f1 "$OUT/$NAME.tar.xz.sha256")"
echo "PYTHON_ABI_ID=$ABI_ID"
