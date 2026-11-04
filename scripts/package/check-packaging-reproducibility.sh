#!/usr/bin/env bash
#
# Prove the two delivery formats are reproducible from one canonical core.
#
# Packages the same core twice and compares. The two formats get DIFFERENT
# standards, because one of them can meet byte identity and the other provably
# cannot:
#
#   .ingenic  BYTE-IDENTICAL required. It is a plain ZIP; every entry keeps the
#             vendor template's own metadata and the payloads are copied
#             verbatim, so there is nothing left to vary.
#
#   .img      CONTENT-IDENTICAL required, byte identity is IMPOSSIBLE. The
#             Creality envelope is an encrypted 7z (-mhe=on). AES uses a fresh
#             random salt and IV for every archive, so two archives over
#             identical plaintext differ in ~99.6% of their bytes by
#             construction. No 7z option pins the IV.
#
# The .img check is therefore: identical SIZE (which proves the compressed
# stream is deterministic - only the encryption differs), plus a bit-identical
# extracted tree. That is a real proof of reproducibility at the layer where
# reproducibility is meaningful, and it is deliberately not called byte
# identity.
#
# What this does NOT do is loosen the comparison until it passes. If the
# extracted trees differ by a single byte, or the sizes differ, this fails.
set -uo pipefail
export LC_ALL=C

die(){ printf 'PACKAGING_REPRODUCIBILITY=FAILED\nREASON: %s\n' "$1" >&2; exit 2; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# The envelope secret is DERIVED by the packager, not copied here. An earlier
# revision hardcoded a third copy of it - the exact duplication that build-img.py
# and validate-img.py already avoid, and which would let this script keep
# "verifying" packages after the derivation changed.
SECRET=$(python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('m', '$SCRIPT_DIR/build-img.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.stdout.write(m.derive_archive_secret())
") || die "cannot derive the OTA envelope secret"
[ -n "$SECRET" ] || die "the derived OTA envelope secret is empty"

BUILD_RUN_A=""; BUILD_RUN_B=""; TEMPLATE=""; OTA_VERSION="9.9.9.1"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --build-run-a) BUILD_RUN_A=${2:-}; shift 2 ;;
    --build-run-b) BUILD_RUN_B=${2:-}; shift 2 ;;
    --template)    TEMPLATE=${2:-}; shift 2 ;;
    --ota-version) OTA_VERSION=${2:-}; shift 2 ;;
    *) die "unknown option '$1'" ;;
  esac
done
[ -n "$BUILD_RUN_A" ] || die "--build-run-a is required"
[ -n "$TEMPLATE" ]    || die "--template is required"
# Packaging the SAME core twice proves the packager is deterministic. Passing a
# second, independently-built core additionally proves the whole pipeline is.
BUILD_RUN_B=${BUILD_RUN_B:-$BUILD_RUN_A}

art(){ echo "$1/artifacts/buildroot-halley5-v30-image"; }
epoch(){ grep -m1 '^SOURCE_DATE_EPOCH=' "$1/.nebulaos-build-verified" | cut -d= -f2; }
head_of(){ grep -m1 '^SOURCE_HEAD=' "$1/.nebulaos-build-verified" | cut -d= -f2; }

HEAD_A=$(head_of "$BUILD_RUN_A"); HEAD_B=$(head_of "$BUILD_RUN_B")
[ -n "$HEAD_A" ] || die "no attestation in $BUILD_RUN_A"
[ "$HEAD_A" = "$HEAD_B" ] || die "the two build runs are different commits ($HEAD_A vs $HEAD_B)"
EPOCH=$(epoch "$BUILD_RUN_A")

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nebulaos-pkg-repro.XXXXXX") || die "cannot create a work directory"
trap 'rm -rf "$WORK"' EXIT INT TERM

FAIL=0
printf 'PACKAGING_REPRODUCIBILITY=STARTING\nSOURCE_HEAD=%s\nRUN_A=%s\nRUN_B=%s\n\n' \
  "$HEAD_A" "$BUILD_RUN_A" "$BUILD_RUN_B"

# --- the two canonical cores must themselves be identical ------------------
CORE_IDENTICAL_XIMAGE=NO
CORE_IDENTICAL_ROOTFS=NO
for name in xImage rootfs.squashfs; do
  a=$(sha256sum "$(art "$BUILD_RUN_A")/$name" | cut -d' ' -f1)
  b=$(sha256sum "$(art "$BUILD_RUN_B")/$name" | cut -d' ' -f1)
  if [ "$a" = "$b" ]; then
    printf 'PASS  %s is byte-identical across the two builds (%s)\n' "$name" "$a"
    [ "$name" = xImage ] && CORE_IDENTICAL_XIMAGE=YES || CORE_IDENTICAL_ROOTFS=YES
  else
    printf 'FAIL  %s is byte-identical across the two builds\n       A=%s B=%s\n' "$name" "$a" "$b"
    FAIL=$((FAIL+1))
  fi
done

# --- .ingenic: byte identity -----------------------------------------------
echo
for R in A B; do
  eval "SRC=\$BUILD_RUN_$R"
  python3 "$SCRIPT_DIR/build-ingenic.py" --template "$TEMPLATE" \
    --ximage "$(art "$SRC")/xImage" --rootfs "$(art "$SRC")/rootfs.squashfs" \
    --manifest "$(art "$SRC")/build-manifest.txt" --out "$WORK/$R.ingenic" \
    --source-head "$HEAD_A" --source-date-epoch "$EPOCH" >/dev/null 2>&1 \
    || die ".ingenic packaging run $R failed"
done
if cmp -s "$WORK/A.ingenic" "$WORK/B.ingenic"; then
  printf 'PASS  .ingenic is BYTE-IDENTICAL across two packaging runs (%s)\n' \
    "$(sha256sum "$WORK/A.ingenic" | cut -d' ' -f1)"
else
  printf 'FAIL  .ingenic is BYTE-IDENTICAL across two packaging runs\n'
  FAIL=$((FAIL+1))
fi

# --- .img: content identity, with the difference characterised -------------
echo
# The .img's top directory is its file name (G115: Creality's updater looks in
# <file>/), so both runs package under the same name, in their own directory.
IMG_NAME=NebulaOS-Ender3V3KE-$OTA_VERSION.img
for R in A B; do
  eval "SRC=\$BUILD_RUN_$R"
  mkdir -p "$WORK/$R"
  python3 "$SCRIPT_DIR/build-img.py" \
    --ximage "$(art "$SRC")/xImage" --rootfs "$(art "$SRC")/rootfs.squashfs" \
    --manifest "$(art "$SRC")/build-manifest.txt" --out "$WORK/$R/$IMG_NAME" \
    --source-head "$HEAD_A" --source-date-epoch "$EPOCH" --ota-version "$OTA_VERSION" \
    >/dev/null 2>&1 || die ".img packaging run $R failed"
done

# The compressed DATA stream must be the same size. The whole archive need not:
# with -mhe=on the header carries the random AES IV and is itself compressed
# before it is encrypted, so its length varies in 16-byte steps from run to
# run (measured, Run 23: headers 4114 vs 4082 bytes over identical data
# streams). That was the "intermittent" FAIL of this check.
data_size() { # IMG -> physical size minus header size
  7z l -slt -p"$SECRET" "$1" 2>/dev/null | awk -F' = ' '
    /^Physical Size = /{p=$2} /^Headers Size = /{h=$2} END{if (p && h) print p - h}'
}
SIZE_A=$(stat -c %s "$WORK/A/$IMG_NAME"); SIZE_B=$(stat -c %s "$WORK/B/$IMG_NAME")
DATA_A=$(data_size "$WORK/A/$IMG_NAME"); DATA_B=$(data_size "$WORK/B/$IMG_NAME")
if [ -n "$DATA_A" ] && [ "$DATA_A" = "$DATA_B" ]; then
  printf 'PASS  .img compressed data streams are the same size (%s bytes) - the compression is deterministic\n' "$DATA_A"
else
  printf 'FAIL  .img compressed data streams are the same size\n       A=%s B=%s\n' "${DATA_A:-unread}" "${DATA_B:-unread}"
  FAIL=$((FAIL+1))
fi
[ "$SIZE_A" = "$SIZE_B" ] || printf 'INFO  .img archives differ by %s bytes, all in the encrypted header (random IV)\n' \
  "$((SIZE_A - SIZE_B))"

for R in A B; do
  mkdir -p "$WORK/x$R"
  7z x -y -p"$SECRET" -o"$WORK/x$R" "$WORK/$R/$IMG_NAME" >/dev/null 2>&1 \
    || die "cannot extract $WORK/$R/$IMG_NAME"
done
TREE_A=$(cd "$WORK/xA" && find . -type f | sort | xargs sha256sum | sha256sum | cut -d' ' -f1)
TREE_B=$(cd "$WORK/xB" && find . -type f | sort | xargs sha256sum | sha256sum | cut -d' ' -f1)
if [ "$TREE_A" = "$TREE_B" ]; then
  printf 'PASS  .img extracted content trees are BIT-IDENTICAL (%s)\n' "$TREE_A"
else
  printf 'FAIL  .img extracted content trees are BIT-IDENTICAL\n       A=%s B=%s\n' "$TREE_A" "$TREE_B"
  FAIL=$((FAIL+1))
  diff -r "$WORK/xA" "$WORK/xB" | head -10
fi

# Characterise the byte difference precisely rather than hand-waving at it.
DIFFPCT=$(python3 - "$WORK/A/$IMG_NAME" "$WORK/B/$IMG_NAME" <<'PY'
import sys
a=open(sys.argv[1],'rb').read(); b=open(sys.argv[2],'rb').read()
n=min(len(a),len(b))
d=sum(1 for i in range(n) if a[i]!=b[i])
first=next((i for i in range(n) if a[i]!=b[i]), -1)
print("%.2f %d" % (100*d/n, first))
PY
)
set -- $DIFFPCT
printf 'INFO  .img differs in %s%% of bytes from offset %s - the encrypted 7z envelope\n' "$1" "$2"
printf '      uses a fresh random AES salt/IV per archive. No 7z option pins it, so byte\n'
printf '      identity is impossible here and is NOT claimed. Content identity above is\n'
printf '      the real reproducibility proof.\n'

echo
# Derived from the comparison, never printed unconditionally. An earlier revision
# asserted YES here even when the loop above had just proven otherwise - and
# these lines are this script's machine-readable output contract.
printf 'XIMAGE_BYTE_IDENTICAL=%s\nROOTFS_SQUASHFS_BYTE_IDENTICAL=%s\n' \
  "$CORE_IDENTICAL_XIMAGE" "$CORE_IDENTICAL_ROOTFS"
printf 'INGENIC_BYTE_IDENTICAL=%s\n' "$(cmp -s "$WORK/A.ingenic" "$WORK/B.ingenic" && echo YES || echo NO)"
printf 'IMG_BYTE_IDENTICAL=NO\nIMG_BYTE_IDENTICAL_REASON=encrypted-7z-random-aes-iv\n'
printf 'IMG_CONTENT_IDENTICAL=%s\n' "$([ "$TREE_A" = "$TREE_B" ] && echo YES || echo NO)"
printf 'PACKAGING_REPRODUCIBILITY=%s\n' "$([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)"
[ "$FAIL" -eq 0 ] || exit 1
