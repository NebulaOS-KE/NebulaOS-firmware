#!/usr/bin/env bash
#
# Produce the full release artifact set from ONE already-built canonical core.
#
# BUILD ONCE, PACKAGE THREE WAYS
#
# This never compiles anything and never invokes build.sh. It takes a build
# workspace that has already been produced and attested, and emits:
#
#   artifacts/release/
#     xImage                             native, the canonical payload
#     rootfs.squashfs                    native, the canonical payload
#     build-manifest.txt                 native, the build's own manifest
#     NebulaOS-Ender3V3KE-<ver>.img      Creality F005 OTA package
#     NebulaOS-Ender3V3KE-<ver>.img.sha256
#     NebulaOS-Ender3V3KE-<ver>.img.manifest.txt
#     NebulaOS-Ender3V3KE-<ver>.ingenic  Ingenic Cloner recovery package
#     NebulaOS-Ender3V3KE-<ver>.ingenic.sha256
#     NebulaOS-Ender3V3KE-<ver>.ingenic.manifest.txt
#     release-manifest.txt               binds all three to one source generation
#
# Running it twice against the same canonical core is safe and is how the
# packaging reproducibility check works: the two delivery formats are
# deterministic, so a second run produces byte-identical output.
#
# WHY IT RUNS ON THE HOST, NOT IN THE BUILD CONTAINER
#
# The .ingenic is built by substituting into the official 124 MB vendor package,
# which is deliberately not vendored into this repository, and the .img needs 7z
# and an MD5-crypt implementation. None of that belongs inside the pinned build
# image, whose job is to compile the canonical core reproducibly. Keeping
# packaging outside also makes it re-runnable against a core that was built
# hours earlier, without a rebuild.
#
# EVERY FORMAT IS VALIDATED BEFORE THE RELEASE DIRECTORY IS DECLARED GOOD
#
# No artifact exists here merely because a packaging command returned 0. Both
# validators re-open what was written, reassemble or extract the payload, and
# require SHA-256 equality with the canonical core. A validator failure fails
# this script.
set -uo pipefail
export LC_ALL=C

die(){ printf 'PACKAGE_RELEASE=FAILED\nREASON: %s\n' "$1" >&2; exit 2; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FW=$(cd "$SCRIPT_DIR/../.." && pwd)

BUILD_RUN=""
TEMPLATE=""
OUT=""
OTA_VERSION=""
SLOT=b
RTOS2=nebulaos

while [ "$#" -gt 0 ]; do
  case "$1" in
    --build-run)      BUILD_RUN=${2:-}; shift 2 ;;
    --template)       TEMPLATE=${2:-}; shift 2 ;;
    --out)            OUT=${2:-}; shift 2 ;;
    --ota-version)    OTA_VERSION=${2:-}; shift 2 ;;
    --slot)           SLOT=${2:-}; shift 2 ;;
    --rtos2)          RTOS2=${2:-}; shift 2 ;;
    *) die "unknown option '$1'. Usage: package-release.sh --build-run <dir> --template <vendor.ingenic> --ota-version <v> [--out <dir>] [--slot a|b] [--rtos2 nebulaos|stock]" ;;
  esac
done

[ -n "$BUILD_RUN" ]   || die "--build-run is required (a workspace produced by tools/run-nebulaos-build.sh)"
[ -n "$TEMPLATE" ]    || die "--template is required (the official Ender-3_V3_KE .ingenic)"
[ -n "$OTA_VERSION" ] || die "--ota-version is required"
[ -d "$BUILD_RUN" ]   || die "build run directory does not exist: $BUILD_RUN"
[ -f "$TEMPLATE" ]    || die "ingenic template does not exist: $TEMPLATE"
case "$RTOS2" in nebulaos|stock) ;; *) die "--rtos2 must be nebulaos or stock" ;; esac

ART="$BUILD_RUN/artifacts/buildroot-halley5-v30-image"
XIMAGE="$ART/xImage"
ROOTFS="$ART/rootfs.squashfs"
MANIFEST="$ART/build-manifest.txt"
for f in "$XIMAGE" "$ROOTFS" "$MANIFEST"; do
  [ -f "$f" ] || die "canonical artifact missing: $f"
done

# --- the build must have been attested ------------------------------------
# A release is not assembled from artifacts that merely exist. The build
# launcher writes .nebulaos-build-verified only when build.sh exited zero AND
# the canonical workspace was still clean afterwards; without it, these bytes
# are self-consistent but nothing says a build ever passed.
ATT="$BUILD_RUN/.nebulaos-build-verified"
[ -f "$ATT" ] || die "no build attestation at $ATT - refusing to package an unattested build"
att_get(){ grep -m1 "^$1=" "$ATT" 2>/dev/null | cut -d= -f2-; }
[ "$(att_get BUILD_VERIFIED)" = YES ] || die "the build attestation does not say BUILD_VERIFIED=YES"

SOURCE_HEAD=$(att_get SOURCE_HEAD)
BUILD_MODE=$(att_get BUILD_MODE)
BUILDER_DIGEST=$(att_get BUILDER_DIGEST)
SOURCE_DATE_EPOCH=$(att_get SOURCE_DATE_EPOCH)
[ -n "$SOURCE_HEAD" ] && [ -n "$SOURCE_DATE_EPOCH" ] || die "the build attestation is missing SOURCE_HEAD or SOURCE_DATE_EPOCH"

X_SHA=$(sha256sum "$XIMAGE" | cut -d' ' -f1)
R_SHA=$(sha256sum "$ROOTFS"  | cut -d' ' -f1)
[ "$(att_get XIMAGE_SHA256)" = "$X_SHA" ] || die "xImage does not match the build attestation"
[ "$(att_get ROOTFS_SQUASHFS_SHA256)" = "$R_SHA" ] || die "rootfs.squashfs does not match the build attestation"

OUT=${OUT:-$FW/artifacts/release}
mkdir -p "$OUT" || die "cannot create $OUT"

BASE="NebulaOS-Ender3V3KE-$OTA_VERSION"
IMG="$OUT/$BASE.img"
ING="$OUT/$BASE.ingenic"

printf 'PACKAGE_RELEASE=STARTING\nSOURCE_HEAD=%s\nBUILD_MODE=%s\nBUILD_RUN=%s\nOUT=%s\n\n' \
  "$SOURCE_HEAD" "$BUILD_MODE" "$BUILD_RUN" "$OUT"

# --- A. native -------------------------------------------------------------
# Copied, not symlinked: a release directory must stand on its own once the
# disposable build workspace is pruned.
echo "== native artifacts =="
cp -f "$XIMAGE" "$ROOTFS" "$MANIFEST" "$OUT/" || die "cannot copy the canonical core into $OUT"
[ "$(sha256sum "$OUT/xImage" | cut -d' ' -f1)" = "$X_SHA" ] || die "xImage changed while being copied"
[ "$(sha256sum "$OUT/rootfs.squashfs" | cut -d' ' -f1)" = "$R_SHA" ] || die "rootfs.squashfs changed while being copied"
echo "  xImage          $X_SHA"
echo "  rootfs.squashfs $R_SHA"

# --- the RTOS ---------------------------------------------------------------
# The real vendor ota_update.in lists THREE payloads - kernel, rootfs and
# rtos/zero.bin (FIRMWARE.md, recorded from extracting Creality's own V1.1.0.12
# package). The only genuine copy this project has of zero.bin is inside the
# official .ingenic template. NebulaOS changes one thing in it: the boot-logo
# JPEG (rtos_logo.py: pinned input, pinned output, every other byte stock).
# That image goes into the .img, which installs the NebulaOS slot set, and into
# the .ingenic as zero2.bin; slot A of the .ingenic keeps the untouched stock
# zero.bin. --rtos2 stock ships the stock RTOS everywhere.
STOCK_RTOS="$OUT/.zero.bin"
rm -f "$STOCK_RTOS" "$OUT/.zero2.bin"
python3 - "$TEMPLATE" "$STOCK_RTOS" <<'PY' || die "cannot extract zero.bin from the template"
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    with z.open("images/zero.bin") as src, open(sys.argv[2], "wb") as dst:
        dst.write(src.read())
PY
echo "  stock RTOS: $(sha256sum "$STOCK_RTOS" | cut -d' ' -f1) ($(stat -c %s "$STOCK_RTOS") bytes, from the template)"
if [ "$RTOS2" = nebulaos ]; then
  RTOS="$OUT/.zero2.bin"
  python3 "$SCRIPT_DIR/rtos_logo.py" patch --stock "$STOCK_RTOS" --out "$RTOS" --require-pinned >/dev/null \
    || die "cannot build the NebulaOS RTOS image (rtos_logo.py patch --require-pinned)"
  echo "  NebulaOS RTOS: $(sha256sum "$RTOS" | cut -d' ' -f1) (stock + the NebulaOS boot logo)"
else
  RTOS="$STOCK_RTOS"
fi

# --- B. Creality F005 OTA .img --------------------------------------------
echo
echo "== .img (Creality F005 OTA package) =="
python3 "$SCRIPT_DIR/build-img.py" \
  --ximage "$XIMAGE" --rootfs "$ROOTFS" --manifest "$MANIFEST" --rtos "$RTOS" \
  --out "$IMG" --source-head "$SOURCE_HEAD" \
  --source-date-epoch "$SOURCE_DATE_EPOCH" --ota-version "$OTA_VERSION" \
  || die ".img packaging failed"

python3 "$SCRIPT_DIR/validate-img.py" --img "$IMG" --ximage "$XIMAGE" --rootfs "$ROOTFS" --rtos "$RTOS" \
  > "$OUT/$BASE.img.validation.txt" 2>&1 \
  || { tail -20 "$OUT/$BASE.img.validation.txt" >&2; die ".img validation failed - see $OUT/$BASE.img.validation.txt"; }
echo "  validation: $(grep '^IMG_VALIDATED=' "$OUT/$BASE.img.validation.txt")"

# --- C. Ingenic Cloner .ingenic -------------------------------------------
echo
echo "== .ingenic (Ingenic Cloner recovery package) =="
python3 "$SCRIPT_DIR/build-ingenic.py" \
  --template "$TEMPLATE" --ximage "$XIMAGE" --rootfs "$ROOTFS" --manifest "$MANIFEST" \
  --out "$ING" --source-head "$SOURCE_HEAD" \
  --source-date-epoch "$SOURCE_DATE_EPOCH" --slot "$SLOT" --rtos2 "$RTOS2" \
  || die ".ingenic packaging failed"

python3 "$SCRIPT_DIR/validate-ingenic.py" --package "$ING" --template "$TEMPLATE" \
  --ximage "$XIMAGE" --rootfs "$ROOTFS" --slot "$SLOT" --rtos2 "$RTOS2" \
  > "$OUT/$BASE.ingenic.validation.txt" 2>&1 \
  || { tail -20 "$OUT/$BASE.ingenic.validation.txt" >&2; die ".ingenic validation failed - see $OUT/$BASE.ingenic.validation.txt"; }
echo "  validation: $(grep '^INGENIC_VALIDATED=' "$OUT/$BASE.ingenic.validation.txt")"

# --- the canonical inputs must be untouched -------------------------------
# The whole architecture rests on packaging being byte-preserving with respect
# to the qualified payloads, so it is checked rather than assumed.
[ "$(sha256sum "$XIMAGE" | cut -d' ' -f1)" = "$X_SHA" ] \
  && [ "$(sha256sum "$ROOTFS" | cut -d' ' -f1)" = "$R_SHA" ] \
  || die "packaging modified the qualified input artifacts"

# --- release manifest ------------------------------------------------------
# Binds every delivery format to the SAME source generation and the same two
# payload digests. This is the file a later investigation reads to answer "were
# these three artifacts the same release?".
IMG_SHA=$(sha256sum "$IMG" | cut -d' ' -f1)
ING_SHA=$(sha256sum "$ING" | cut -d' ' -f1)
PKG_COMMIT=$(git -C "$FW" rev-parse HEAD 2>/dev/null || echo unknown)

{
  echo "# NebulaOS release manifest"
  echo "# Every delivery format below was packaged from ONE canonical core."
  echo "# Nothing here was compiled by the packaging step."
  echo "RELEASE_MANIFEST_VERSION=1"
  echo "RELEASE_VERSION=$OTA_VERSION"
  echo "SOURCE_HEAD=$SOURCE_HEAD"
  echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
  echo "BUILD_MODE=$BUILD_MODE"
  echo "BUILDER_DIGEST=$BUILDER_DIGEST"
  echo "BUILD_RUN=$BUILD_RUN"
  echo "PACKAGING_TOOL_COMMIT=$PKG_COMMIT"
  echo "PACKAGED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "# --- the one canonical core ---"
  echo "XIMAGE_SHA256=$X_SHA"
  echo "XIMAGE_SIZE=$(stat -c %s "$XIMAGE")"
  echo "ROOTFS_SQUASHFS_SHA256=$R_SHA"
  echo "ROOTFS_SQUASHFS_SIZE=$(stat -c %s "$ROOTFS")"
  echo "BUILD_MANIFEST_SHA256=$(sha256sum "$MANIFEST" | cut -d' ' -f1)"
  echo
  echo "# --- A. native ---"
  echo "NATIVE_XIMAGE=xImage"
  echo "NATIVE_ROOTFS=rootfs.squashfs"
  echo "NATIVE_BUILD_MANIFEST=build-manifest.txt"
  echo
  echo "# --- B. Creality F005 OTA package (stock updater) ---"
  echo "IMG_ARTIFACT=$BASE.img"
  echo "IMG_SHA256=$IMG_SHA"
  echo "IMG_SIZE=$(stat -c %s "$IMG")"
  echo "IMG_VALIDATED=$(grep -m1 '^IMG_VALIDATED=' "$OUT/$BASE.img.validation.txt" | cut -d= -f2)"
  echo "IMG_CONSUMER=stock Creality updater (USB / touchscreen / local_ota_update.sh)"
  echo "IMG_INSTALL_TARGET=whichever A/B slot is INACTIVE at apply time"
  echo "IMG_RTOS_SHA256=$(sha256sum "$RTOS" | cut -d' ' -f1)"
  echo "IMG_RTOS_PROVENANCE=$(grep -m1 '^RTOS_PROVENANCE=' "$IMG.manifest.txt" | cut -d= -f2-)"
  echo "RTOS_STOCK_SHA256=$(sha256sum "$STOCK_RTOS" | cut -d' ' -f1)"
  echo
  echo "# --- C. Ingenic Cloner recovery package ---"
  echo "INGENIC_ARTIFACT=$BASE.ingenic"
  echo "INGENIC_SHA256=$ING_SHA"
  echo "INGENIC_SIZE=$(stat -c %s "$ING")"
  echo "INGENIC_VALIDATED=$(grep -m1 '^INGENIC_VALIDATED=' "$OUT/$BASE.ingenic.validation.txt" | cut -d= -f2)"
  echo "INGENIC_SLOT=$SLOT"
  echo "INGENIC_RTOS2=$(grep -m1 '^INGENIC_RTOS2=' "$ING.manifest.txt" | cut -d= -f2)"
  echo "INGENIC_RTOS2_SHA256=$(grep -m1 '^INGENIC_RTOS2_SHA256=' "$ING.manifest.txt" | cut -d= -f2)"
  echo "INGENIC_TEMPLATE_SHA256=$(sha256sum "$TEMPLATE" | cut -d' ' -f1)"
  echo "INGENIC_CONSUMER=Ingenic USB Cloner in X2000E USB-boot (mask-ROM) mode"
  echo "INGENIC_SN_MAC_PRESERVED=YES"
  echo
  echo "# --- invariants asserted by this run ---"
  echo "ALL_FORMATS_SAME_CANONICAL_CORE=YES"
  echo "QUALIFIED_INPUT_ARTIFACTS_MODIFIED=NO"
  echo "PACKAGING_RECOMPILED_ANYTHING=NO"
} > "$OUT/release-manifest.txt"

rm -f "$STOCK_RTOS" "$OUT/.zero2.bin"

( cd "$OUT" && sha256sum "$BASE.img" "$BASE.ingenic" xImage rootfs.squashfs build-manifest.txt \
    > SHA256SUMS ) || die "cannot write SHA256SUMS"

echo
printf 'PACKAGE_RELEASE=COMPLETE\nRELEASE_DIR=%s\nSOURCE_HEAD=%s\nXIMAGE_SHA256=%s\nROOTFS_SQUASHFS_SHA256=%s\nIMG_SHA256=%s\nINGENIC_SHA256=%s\nALL_FORMATS_SAME_CANONICAL_CORE=YES\n' \
  "$OUT" "$SOURCE_HEAD" "$X_SHA" "$R_SHA" "$IMG_SHA" "$ING_SHA"
