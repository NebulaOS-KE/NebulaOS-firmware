#!/usr/bin/env bash
#
# Offline tests for the release packaging path.
#
# Two delivery formats, both built from an already-built canonical core and
# neither permitted to compile anything:
#
#   .img      the Creality F005 OTA package the STOCK updater consumes
#   .ingenic  the Ingenic Cloner recovery package, built by substituting into
#             the official vendor template
#
# Most of this runs on small synthetic payloads so it is cheap enough to run on
# every change, and it exercises the failure paths a real core cannot easily
# produce: a broken chunk chain, a tampered payload, an erase policy that would
# destroy the printer's factory identity, an oversized image.
#
# Several cases here are REGRESSION tests for specific defects an independent
# review found and reproduced. Each is marked. They exist because the original
# implementations passed their own tests while being wrong.
#
# The .ingenic cases need the official vendor package, which is 124 MB and is
# deliberately NOT committed here. Point NEBULAOS_INGENIC_TEMPLATE at a local
# copy to run them; without it those cases SKIP loudly rather than passing
# vacuously, because a silent skip is how a format stops being tested.
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FW=$(cd "$SCRIPT_DIR/.." && pwd)
PKG="$FW/scripts/package"
EMMC="$FW/tools/emmc"

PASS=0; FAIL=0; SKIP=0
ok(){   PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad(){  FAIL=$((FAIL+1)); printf 'FAIL  %s\n       %s\n' "$1" "${2:-}"; }
skip(){ SKIP=$((SKIP+1)); printf 'SKIP  %s\n       %s\n' "$1" "${2:-}"; }

command -v 7z >/dev/null 2>&1 || { echo "FATAL: 7z is required by these tests" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nebulaos-packaging-tests.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

# --- synthetic canonical core ----------------------------------------------
XIMAGE="$WORK/xImage"
ROOTFS="$WORK/rootfs.squashfs"
RTOS="$WORK/zero.bin"
MANIFEST="$WORK/build-manifest.txt"
HEAD_SHA=fd4a365e9cc2b7dd478547bde00a272decee220e

head -c 2621440 /dev/urandom > "$XIMAGE"      # 2.5 MiB -> 3 chunks
head -c 5242880 /dev/urandom > "$ROOTFS"      # 5   MiB -> 5 chunks
head -c  432824 /dev/urandom > "$RTOS"        # same size as the real zero.bin
X_SHA=$(sha256sum "$XIMAGE" | cut -d' ' -f1)
R_SHA=$(sha256sum "$ROOTFS"  | cut -d' ' -f1)
cat > "$MANIFEST" <<EOF
built_at=2026-09-28T00:00:00Z
git_commit_main=$HEAD_SHA
xImage_sha256=$X_SHA
xImage_size=$(stat -c %s "$XIMAGE")
rootfs_squashfs_sha256=$R_SHA
rootfs_squashfs_size=$(stat -c %s "$ROOTFS")
build_image_digest=sha256:a6ba57c69fa1ea630b037a1d1f55cf0c044a7f5a403bde9b155ea54bca1cceba
EOF

SECRET='$1$cxswfile$ZFd0RWFYkJQugbtKVGL9y0'

mkimg(){ python3 "$PKG/build-img.py" --ximage "$1" --rootfs "$2" --manifest "$3" --out "$4" \
           --rtos "$RTOS" --source-head "${5:-$HEAD_SHA}" --source-date-epoch 1790442459 \
           --ota-version "${6:-9.9.9.1}"; }
vimg(){ python3 "$PKG/validate-img.py" --img "$1" --ximage "${2:-$XIMAGE}" --rootfs "${3:-$ROOTFS}" --rtos "$RTOS"; }

echo "=== release packaging: offline suite ==="
echo

# --- 1. eMMC layout facts ---------------------------------------------------
# The geometry comes from the vendor Cloner profile. The module re-derives its
# agreement with flash-spare-slot.sh from that script's own text, so the two
# copies cannot drift apart silently.
out=$(cd "$EMMC" && python3 -c "
import nebulaos_layout as L
for n in L.assert_agrees_with_flash_script(): print(n)
print('kernel', L.KERNEL_PART_BYTES)
print('rootfs', L.ROOTFS_PART_BYTES)
print('sn_mac_off', hex(L.partition_offset('sn_mac')))
" 2>&1)
if printf '%s' "$out" | grep -q '^kernel 8388608$' \
&& printf '%s' "$out" | grep -q '^rootfs 524288000$' \
&& printf '%s' "$out" | grep -q 'KERNEL_PART_BYTES=8388608 agrees'; then
  ok "vendor cloner offsets re-derive flash-spare-slot.sh's capacities from its own text"
else
  bad "vendor cloner offsets re-derive flash-spare-slot.sh's capacities" "$out"
fi

if printf '%s' "$out" | grep -q '^sn_mac_off 0x200000$'; then
  ok "sn_mac is recorded at its vendor offset 0x200000"
else
  bad "sn_mac is recorded at its vendor offset 0x200000" "$out"
fi

# The single most consequential safety property in the packaging path. It must
# FAIL CLOSED on anything it cannot parse.
out=$(cd "$EMMC" && python3 -c "
import nebulaos_layout as L
for name, val in [('vendor', L.VENDOR_ERASE_LIST), ('fullwipe','0x0,0xffffffff;'),
                  ('straddle','0x0,0x1fffff;0x250000,0xffffffff;'),
                  ('nocomma','0x0 0xffffffff;'), ('emptyend','0x0,;'),
                  ('garbage','not,a,range;'), ('empty','')]:
    print(name, L.erase_list_preserves_sn_mac(val))
" 2>&1)
if printf '%s' "$out" | grep -q '^vendor True$' \
&& printf '%s' "$out" | grep -q '^fullwipe False$' \
&& printf '%s' "$out" | grep -q '^straddle False$' \
&& printf '%s' "$out" | grep -q '^nocomma False$' \
&& printf '%s' "$out" | grep -q '^emptyend False$' \
&& printf '%s' "$out" | grep -q '^garbage False$'; then
  ok "the sn_mac check accepts the vendor erase list and fails closed on every malformed form"
else
  bad "the sn_mac check fails closed on malformed input" "$out"
fi

# REGRESSION: a deleted module must stay deleted. tools/emmc/nebulaos_gpt.py was
# written for a raw-disk-image approach the project abandoned, then sat
# referenced by nothing while documenting behaviour that no longer existed.
if [ ! -e "$EMMC/nebulaos_gpt.py" ]; then
  ok "the abandoned GPT module is gone (regression: dead code documenting a rejected design)"
else
  bad "the abandoned GPT module is gone" "$EMMC/nebulaos_gpt.py exists again"
fi

# --- 2. .img: the Creality F005 OTA package --------------------------------
IMG="$WORK/test.img"
if mkimg "$XIMAGE" "$ROOTFS" "$MANIFEST" "$IMG" >/dev/null 2>&1; then
  ok ".img packaging succeeds against a synthetic canonical core"
else
  bad ".img packaging succeeds against a synthetic canonical core" \
      "$(mkimg "$XIMAGE" "$ROOTFS" "$MANIFEST" "$IMG" 2>&1 | tail -3 | tr '\n' ' ')"
fi

if vimg "$IMG" >/dev/null 2>&1; then
  ok ".img validation passes, including the reassemble-and-compare gate"
else
  bad ".img validation passes, including the reassemble-and-compare gate" \
      "$(vimg "$IMG" 2>&1 | grep '^FAIL' | head -3 | tr '\n' ' ')"
fi

# REGRESSION: the vendor ota_update.in lists THREE payloads (FIRMWARE.md, from
# extracting Creality's real V1.1.0.12 package). An earlier version emitted two
# and its validator asserted "exactly the two expected images" - builder and
# validator agreeing with each other and with nothing else.
if grep -q '^RTOS_INCLUDED=YES$' "$IMG.manifest.txt"; then
  ok ".img carries the rtos/zero.bin record the real vendor package has"
else
  bad ".img carries the rtos/zero.bin record the real vendor package has"
fi

NORTOS="$WORK/nortos.img"
python3 "$PKG/build-img.py" --ximage "$XIMAGE" --rootfs "$ROOTFS" --manifest "$MANIFEST" \
  --out "$NORTOS" --source-head "$HEAD_SHA" --source-date-epoch 1790442459 \
  --ota-version 9.9.9.1 >/dev/null 2>&1
if ! python3 "$PKG/validate-img.py" --img "$NORTOS" --ximage "$XIMAGE" --rootfs "$ROOTFS" \
       --rtos "$RTOS" >/dev/null 2>&1; then
  ok ".img validation rejects a two-record package when an rtos record is expected"
else
  bad ".img validation rejects a two-record package when an rtos record is expected"
fi

# The envelope secret is derived, not pasted.
out=$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('m', '$PKG/build-img.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.derive_archive_secret())" 2>&1)
if [ "$out" = "$SECRET" ]; then
  ok "the OTA envelope secret derives to the known-good MD5-crypt value"
else
  bad "the OTA envelope secret derives to the known-good MD5-crypt value" "got $out"
fi

# REGRESSION: the validator must not keep its own copy of the chunk size while
# claiming to share it. A divergence would be "checked" by a validator that had
# already agreed with the wrong value.
if ! grep -qE '^\s*CHUNK_BYTES\s*=' "$PKG/validate-img.py" \
   && grep -q 'packer.CHUNK_BYTES' "$PKG/validate-img.py"; then
  ok "the .img validator imports the chunk size from the packager rather than redefining it"
else
  bad "the .img validator imports the chunk size from the packager rather than redefining it"
fi

if ! 7z t -p"wrong-secret" "$IMG" >/dev/null 2>&1; then
  ok ".img does not open with a wrong secret (header encryption is on)"
else
  bad ".img does not open with a wrong secret (header encryption is on)"
fi

# Break exactly one link in the chunk chain and require the validator to notice.
BROKEN="$WORK/broken-chain"; mkdir -p "$BROKEN"
7z x -y -p"$SECRET" -o"$BROKEN" "$IMG" >/dev/null 2>&1
PDIR=$(find "$BROKEN" -type d -name 'ota_v*' | head -1)
SECOND=$(ls "$PDIR" | grep -E '^xImage\.0001\.' | head -1)
if [ -n "$SECOND" ]; then
  mv "$PDIR/$SECOND" "$PDIR/xImage.0001.$(printf 'wrong' | md5sum | cut -d' ' -f1)"
  REPACK="$WORK/broken.img"
  ( cd "$BROKEN" && 7z a -t7z -mhe=on -p"$SECRET" "$REPACK" . >/dev/null 2>&1 )
  if ! vimg "$REPACK" >/dev/null 2>&1; then
    ok ".img validation catches a broken link in the chunk chain"
  else
    bad ".img validation catches a broken link in the chunk chain"
  fi
else
  bad ".img validation catches a broken link in the chunk chain" "could not locate chunk 0001"
fi

if ! vimg "$IMG" "$ROOTFS" "$XIMAGE" >/dev/null 2>&1; then
  ok ".img validation rejects a package checked against the wrong canonical core"
else
  bad ".img validation rejects a package checked against the wrong canonical core"
fi

BADMAN="$WORK/bad-manifest.txt"
sed "s/^xImage_sha256=.*/xImage_sha256=$(printf 'evil' | sha256sum | cut -d' ' -f1)/" "$MANIFEST" > "$BADMAN"
if ! mkimg "$XIMAGE" "$ROOTFS" "$BADMAN" "$WORK/nope.img" >/dev/null 2>&1; then
  ok ".img packaging refuses a core that disagrees with its own build manifest"
else
  bad ".img packaging refuses a core that disagrees with its own build manifest"
fi

if ! mkimg "$XIMAGE" "$ROOTFS" "$MANIFEST" "$WORK/nope2.img" 0000000000000000000000000000000000000000 >/dev/null 2>&1; then
  ok ".img packaging refuses a source head the build manifest does not name"
else
  bad ".img packaging refuses a source head the build manifest does not name"
fi

BIGX="$WORK/big-xImage"
head -c $((8388608 + 4096)) /dev/urandom > "$BIGX"
BIGMAN="$WORK/big-manifest.txt"
sed -e "s/^xImage_sha256=.*/xImage_sha256=$(sha256sum "$BIGX" | cut -d' ' -f1)/" \
    -e "s/^xImage_size=.*/xImage_size=$(stat -c %s "$BIGX")/" "$MANIFEST" > "$BIGMAN"
if ! mkimg "$BIGX" "$ROOTFS" "$BIGMAN" "$WORK/nope3.img" >/dev/null 2>&1; then
  ok ".img packaging refuses an xImage larger than the kernel partition"
else
  bad ".img packaging refuses an xImage larger than the kernel partition"
fi

if grep -q 'INACTIVE' "$IMG.manifest.txt" && grep -q 'overwrites the STOCK slot' "$IMG.manifest.txt"; then
  ok ".img manifest states that it writes the inactive slot, which may be stock"
else
  bad ".img manifest states that it writes the inactive slot, which may be stock"
fi

if [ "$(sha256sum "$XIMAGE" | cut -d' ' -f1)" = "$X_SHA" ] \
&& [ "$(sha256sum "$ROOTFS" | cut -d' ' -f1)" = "$R_SHA" ]; then
  ok "packaging left the canonical xImage and rootfs byte-identical"
else
  bad "packaging left the canonical xImage and rootfs byte-identical"
fi

# --- 2b. the RTOS logo patcher (rtos_logo.py) ---------------------------------
# Synthetic stock image: random bytes, the RTOS tag, and a 480x272 baseline
# JPEG padded with a COM segment to exactly the 10899-byte slot at 0x5e50c.
# The real image is covered in section 3 when the template is available.
RL="$PKG/rtos_logo.py"
DEPS="$FW/manifests/dependencies.conf"
SYN="$WORK/rtos-syn"; mkdir -p "$SYN"
python3 - "$SYN" "$PKG" <<'PY' || bad "the synthetic RTOS fixtures could be built"
import io, os, sys
from PIL import Image
out, pkg = sys.argv[1], sys.argv[2]
sys.path.insert(0, pkg)
import rtos_logo as R

def jpeg(size=(480, 272), **kw):
    buf = io.BytesIO()
    Image.new("RGB", size, (40, 50, 60)).save(buf, "JPEG", quality=90, subsampling=2, **kw)
    return buf.getvalue()

def pad_to(data, n):
    # insert one COM segment after SOI so the JPEG is exactly n bytes
    extra = n - len(data) - 4
    assert 0 <= extra <= 65533
    return data[:2] + b"\xff\xfe" + (extra + 2).to_bytes(2, "big") + b"\x00" * extra + data[2:]

stock = bytearray(os.urandom(R.STOCK_ZERO_SIZE).replace(b"\xff", b"\x7f"))
stock[8:12] = b"RTOS"
slot = pad_to(jpeg(), R.LOGO_SLOT_SIZE)
stock[R.LOGO_SLOT_OFFSET:R.LOGO_SLOT_OFFSET + R.LOGO_SLOT_SIZE] = slot
files = {
    "stock.bin": bytes(stock),
    "logo.jpg": jpeg(),
    "progressive.jpg": jpeg(progressive=True),
    "small.jpg": jpeg((320, 240)),
    "big.jpg": pad_to(jpeg(), R.LOGO_SLOT_SIZE + 1),
    "trailing.jpg": jpeg() + b"junk",
    "s444.jpg": (lambda b: (Image.new("RGB", (480, 272)).save(b, "JPEG", subsampling=0), b.getvalue())[1])(io.BytesIO()),
}
for name, data in files.items():
    with open(os.path.join(out, name), "wb") as fh:
        fh.write(data)
PY

out=$(python3 - "$PKG" "$DEPS" <<'PY' 2>&1
import sys
sys.path.insert(0, sys.argv[1])
import rtos_logo as R
conf = dict(l.strip().split("=", 1) for l in open(sys.argv[2]) if l.startswith("RTOS_"))
pairs = [("RTOS_STOCK_ZERO_SHA256", R.STOCK_ZERO_SHA256), ("RTOS_STOCK_ZERO_SIZE", str(R.STOCK_ZERO_SIZE)),
         ("RTOS_NEBULAOS_LOGO_SHA256", R.NEBULAOS_LOGO_SHA256), ("RTOS_NEBULAOS_ZERO_SHA256", R.NEBULAOS_ZERO_SHA256)]
bad = ["%s manifest=%s code=%s" % (k, conf.get(k), v) for k, v in pairs if conf.get(k) != v]
print("MISMATCH " + "; ".join(bad) if bad else "AGREE")
PY
)
if [ "$out" = AGREE ]; then
  ok "the RTOS pins in rtos_logo.py equal the ones in manifests/dependencies.conf"
else
  bad "the RTOS pins in rtos_logo.py equal the ones in manifests/dependencies.conf" "$out"
fi

out=$(python3 - "$PKG" <<'PY' 2>&1
import sys
sys.path.insert(0, sys.argv[1])
import rtos_logo as R
data = open(R.LOGO_ASSET, "rb").read()
i = R.parse_jpeg(data)
print(R.sha256(data) == R.NEBULAOS_LOGO_SHA256, i.length == len(data), i.baseline(),
      (i.width, i.height), [(h, v) for _, h, v in i.components], len(data) <= R.LOGO_SLOT_SIZE)
PY
)
if [ "$out" = "True True True (480, 272) [(2, 2), (1, 1), (1, 1)] True" ]; then
  ok "the committed NebulaOS logo is the pinned, complete, baseline 480x272 4:2:0 JPEG and fits the slot"
else
  bad "the committed NebulaOS logo is the pinned baseline 480x272 4:2:0 JPEG" "$out"
fi

S_SHA=$(sha256sum "$SYN/stock.bin" | cut -d' ' -f1)
if python3 "$RL" patch --stock "$SYN/stock.bin" --logo "$SYN/logo.jpg" --out "$SYN/p.bin" \
     --allow-unpinned-stock > "$SYN/p.out" 2>&1 \
   && python3 "$RL" verify --stock "$SYN/stock.bin" --patched "$SYN/p.bin" --logo "$SYN/logo.jpg" \
     --allow-unpinned-stock >/dev/null 2>&1 \
   && [ "$(stat -c %s "$SYN/p.bin")" = 432824 ] \
   && [ "$(sha256sum "$SYN/stock.bin" | cut -d' ' -f1)" = "$S_SHA" ] \
   && [ "$(cmp -l "$SYN/stock.bin" "$SYN/p.bin" | awk '$1-1 < 386316 || $1-1 >= 386316+10899' | wc -l)" = 0 ]; then
  ok "patch: same size, input untouched, zero bytes differ outside the logo slot (cmp, independently)"
else
  bad "patch: same size, input untouched, zero bytes differ outside the logo slot" "$(tail -3 "$SYN/p.out")"
fi

refuse(){  # <label> <expected reason substring> <args...>
  local label=$1 want=$2; shift 2
  local o; o=$(python3 "$RL" "$@" 2>&1)
  if [ $? -ne 0 ] && printf '%s' "$o" | grep -q -- "$want"; then ok "patch refuses $label"
  else bad "patch refuses $label" "$o"; fi
}
refuse "unpinned stock without --allow-unpinned-stock" "expected the pinned" \
  patch --stock "$SYN/stock.bin" --logo "$SYN/logo.jpg" --out "$SYN/r1.bin"
refuse "a progressive JPEG" "baseline" \
  patch --stock "$SYN/stock.bin" --logo "$SYN/progressive.jpg" --out "$SYN/r2.bin" --allow-unpinned-stock
refuse "a JPEG of the wrong size" "320x240" \
  patch --stock "$SYN/stock.bin" --logo "$SYN/small.jpg" --out "$SYN/r3.bin" --allow-unpinned-stock
refuse "a JPEG larger than the slot" "the slot holds" \
  patch --stock "$SYN/stock.bin" --logo "$SYN/big.jpg" --out "$SYN/r4.bin" --allow-unpinned-stock
refuse "bytes after the logo's EOI" "after its EOI" \
  patch --stock "$SYN/stock.bin" --logo "$SYN/trailing.jpg" --out "$SYN/r5.bin" --allow-unpinned-stock
refuse "a different chroma sampling than the stock logo" "sampling" \
  patch --stock "$SYN/stock.bin" --logo "$SYN/s444.jpg" --out "$SYN/r6.bin" --allow-unpinned-stock
refuse "an existing output" "refusing to overwrite" \
  patch --stock "$SYN/stock.bin" --logo "$SYN/logo.jpg" --out "$SYN/p.bin" --allow-unpinned-stock
refuse "--require-pinned with an unpinned logo" "require-pinned" \
  patch --stock "$SYN/stock.bin" --logo "$SYN/logo.jpg" --out "$SYN/r7.bin" --allow-unpinned-stock --require-pinned
for f in r1 r2 r3 r4 r5 r6 r7; do [ -e "$SYN/$f.bin" ] && bad "a refused patch leaves no output" "$f.bin exists"; done

python3 - "$SYN/p.bin" "$SYN/stock.bin" "$SYN/t.bin" "$SYN/moved.bin" <<'PY'
import sys
p = bytearray(open(sys.argv[1], "rb").read())
p[100] ^= 1
open(sys.argv[3], "wb").write(p)
s = bytearray(open(sys.argv[2], "rb").read())
s[0x5e50c:0x5e50c + 2] = b"\x00\x00"           # no JPEG at the pinned slot offset
open(sys.argv[4], "wb").write(s)
PY
o=$(python3 "$RL" verify --stock "$SYN/stock.bin" --patched "$SYN/t.bin" --logo "$SYN/logo.jpg" --allow-unpinned-stock 2>&1)
if [ $? -ne 0 ] && printf '%s' "$o" | grep -q '1 byte(s) outside the logo slot differ'; then
  ok "verify catches one flipped byte outside the logo slot"
else
  bad "verify catches one flipped byte outside the logo slot" "$o"
fi
refuse "an image whose logo slot is not where the pin says" "no JPEG at the logo slot" \
  patch --stock "$SYN/moved.bin" --logo "$SYN/logo.jpg" --out "$SYN/r8.bin" --allow-unpinned-stock

# --- 3. .ingenic: the Ingenic Cloner recovery package -----------------------
TEMPLATE=${NEBULAOS_INGENIC_TEMPLATE:-}
if [ -z "$TEMPLATE" ] || [ ! -f "$TEMPLATE" ]; then
  skip ".ingenic packaging and validation" \
       "set NEBULAOS_INGENIC_TEMPLATE to the official Ender-3_V3_KE_1.1.0.12.ingenic (124 MB, not committed)"
else
  ING="$WORK/test.ingenic"
  mking(){ python3 "$PKG/build-ingenic.py" --template "${1:-$TEMPLATE}" --ximage "$XIMAGE" \
             --rootfs "$ROOTFS" --manifest "$MANIFEST" --out "$2" --source-head "$HEAD_SHA" \
             --source-date-epoch 1790442459 --slot "${3:-b}" ${4:-}; }

  if mking "$TEMPLATE" "$ING" >/dev/null 2>&1; then
    ok ".ingenic packaging succeeds against the vendor template"
  else
    bad ".ingenic packaging succeeds against the vendor template"
  fi

  if python3 "$PKG/validate-ingenic.py" --package "$ING" --template "$TEMPLATE" \
       --ximage "$XIMAGE" --rootfs "$ROOTFS" >/dev/null 2>&1; then
    ok ".ingenic validation passes (payload round-trip + vendor entries unchanged)"
  else
    bad ".ingenic validation passes (payload round-trip + vendor entries unchanged)" \
        "$(python3 "$PKG/validate-ingenic.py" --package "$ING" --template "$TEMPLATE" --ximage "$XIMAGE" --rootfs "$ROOTFS" 2>&1 | grep '^FAIL' | head -3 | tr '\n' ' ')"
  fi

  # ---- the RTOS images: slot A stock, slot B stock + the NebulaOS logo -------
  RT="$WORK/rtos-real"; mkdir -p "$RT"
  python3 - "$TEMPLATE" "$ING" "$RT" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as t:
    open(sys.argv[3] + "/tpl-zero.bin", "wb").write(t.read("images/zero.bin"))
with zipfile.ZipFile(sys.argv[2]) as p:
    open(sys.argv[3] + "/pkg-zero.bin", "wb").write(p.read("images/zero.bin"))
    open(sys.argv[3] + "/pkg-zero2.bin", "wb").write(p.read("images/zero2.bin"))
PY
  STOCK_PIN=$(grep -m1 '^RTOS_STOCK_ZERO_SHA256=' "$DEPS" | cut -d= -f2)
  NEB_PIN=$(grep -m1 '^RTOS_NEBULAOS_ZERO_SHA256=' "$DEPS" | cut -d= -f2)
  if [ "$(sha256sum "$RT/tpl-zero.bin" | cut -d' ' -f1)" = "$STOCK_PIN" ] \
  && [ "$(sha256sum "$RT/pkg-zero.bin" | cut -d' ' -f1)" = "$STOCK_PIN" ]; then
    ok ".ingenic slot A zero.bin is the byte-exact pinned stock RTOS"
  else
    bad ".ingenic slot A zero.bin is the byte-exact pinned stock RTOS"
  fi
  if [ "$(sha256sum "$RT/pkg-zero2.bin" | cut -d' ' -f1)" = "$NEB_PIN" ] \
  && python3 "$RL" verify --stock "$RT/tpl-zero.bin" --patched "$RT/pkg-zero2.bin" >/dev/null 2>&1 \
  && grep -q '^INGENIC_RTOS2=nebulaos$' "$ING.manifest.txt"; then
    ok ".ingenic slot B zero2.bin is the pinned NebulaOS RTOS: stock except the logo slot"
  else
    bad ".ingenic slot B zero2.bin is the pinned NebulaOS RTOS: stock except the logo slot"
  fi
  if python3 "$RL" patch --stock "$RT/tpl-zero.bin" --out "$RT/fresh.bin" --require-pinned >/dev/null 2>&1 \
  && cmp -s "$RT/fresh.bin" "$RT/pkg-zero2.bin"; then
    ok "rtos_logo.py patch --require-pinned on the real stock image reproduces the pinned zero2.bin"
  else
    bad "rtos_logo.py patch --require-pinned on the real stock image reproduces the pinned zero2.bin"
  fi

  ING_S="$WORK/stock-rtos2.ingenic"
  mking "$TEMPLATE" "$ING_S" b "--rtos2 stock" >/dev/null 2>&1
  if python3 "$PKG/validate-ingenic.py" --package "$ING_S" --template "$TEMPLATE" \
       --ximage "$XIMAGE" --rootfs "$ROOTFS" --rtos2 stock >/dev/null 2>&1 \
  && ! python3 "$PKG/validate-ingenic.py" --package "$ING_S" --template "$TEMPLATE" \
       --ximage "$XIMAGE" --rootfs "$ROOTFS" >/dev/null 2>&1; then
    ok "--rtos2 stock ships a stock zero2.bin, and the default validator rejects it"
  else
    bad "--rtos2 stock ships a stock zero2.bin, and the default validator rejects it"
  fi

  # A zero2.bin that differs from stock by one byte OUTSIDE the logo slot.
  TAMP="$WORK/tampered-rtos2.ingenic"
  python3 - "$ING" "$TAMP" <<'PY' >/dev/null 2>&1
import sys, zipfile, copy, shutil
with zipfile.ZipFile(sys.argv[1]) as z, zipfile.ZipFile(sys.argv[2], "w", allowZip64=True) as o:
    for i in z.infolist():
        if i.filename == "images/zero2.bin":
            d = bytearray(z.read(i)); d[0x1000] ^= 0x01
            o.writestr(copy.copy(i), bytes(d))
        else:
            with z.open(i) as a, o.open(copy.copy(i), "w") as b:
                shutil.copyfileobj(a, b, 1 << 20)
PY
  out=$(python3 "$PKG/validate-ingenic.py" --package "$TAMP" --template "$TEMPLATE" \
          --ximage "$XIMAGE" --rootfs "$ROOTFS" 2>&1)
  if [ $? -ne 0 ] && printf '%s' "$out" | grep -q '1 byte(s) outside the logo slot differ'; then
    ok "the validator rejects a zero2.bin with one changed byte outside the logo slot"
  else
    bad "the validator rejects a zero2.bin with one changed byte outside the logo slot" \
        "$(printf '%s' "$out" | grep '^FAIL' | head -3 | tr '\n' ' ')"
  fi

  IMGN="$WORK/neb-rtos.img"
  if python3 "$PKG/build-img.py" --ximage "$XIMAGE" --rootfs "$ROOTFS" --manifest "$MANIFEST" \
       --out "$IMGN" --rtos "$RT/pkg-zero2.bin" --source-head "$HEAD_SHA" \
       --source-date-epoch 1790442459 --ota-version 9.9.9.1 >/dev/null 2>&1 \
  && python3 "$PKG/validate-img.py" --img "$IMGN" --ximage "$XIMAGE" --rootfs "$ROOTFS" \
       --rtos "$RT/pkg-zero2.bin" >/dev/null 2>&1 \
  && grep -q '^RTOS_PROVENANCE=stock zero.bin with the NebulaOS boot logo' "$IMGN.manifest.txt" \
  && grep -q "^RTOS_SHA256=$NEB_PIN$" "$IMGN.manifest.txt" \
  && grep -q '^RTOS_PROVENANCE=UNPINNED' "$IMG.manifest.txt"; then
    ok ".img carries the NebulaOS RTOS and names it from the pins (a random RTOS reads UNPINNED)"
  else
    bad ".img carries the NebulaOS RTOS and names it from the pins" \
        "$(grep '^RTOS_' "$IMGN.manifest.txt" "$IMG.manifest.txt" 2>&1 | tr '\n' ' ')"
  fi

  ING2="$WORK/test2.ingenic"
  mking "$TEMPLATE" "$ING2" >/dev/null 2>&1
  if cmp -s "$ING" "$ING2"; then
    ok ".ingenic packaging is deterministic (two runs are byte-identical)"
  else
    bad ".ingenic packaging is deterministic (two runs are byte-identical)"
  fi

  FAKE="$WORK/fake-template.ingenic"; cp "$TEMPLATE" "$FAKE"; printf 'x' >> "$FAKE"
  if ! mking "$FAKE" "$WORK/nope.ingenic" >/dev/null 2>&1; then
    ok ".ingenic packaging refuses a template that is not the pinned vendor package"
  else
    bad ".ingenic packaging refuses a template that is not the pinned vendor package"
  fi

  # ---- REGRESSION: sn_mac destruction via --slot a --------------------------
  # An independent review reproduced this: the erase check sat inside
  # `if slot_b:` while INGENIC_SN_MAC_PRESERVED=YES was written unconditionally,
  # so a --slot a package carrying a full-device erase_list was produced with
  # exit 0 and a manifest asserting the property it had just violated.
  HOSTILE="$WORK/hostile.ingenic"
  python3 - "$TEMPLATE" "$HOSTILE" <<'PY' >/dev/null 2>&1
import sys, zipfile, copy, shutil
P = "configs/x2000/x2000e_mmc0_lpddr2_linux.cfg"
with zipfile.ZipFile(sys.argv[1]) as z, zipfile.ZipFile(sys.argv[2], "w", allowZip64=True) as o:
    for i in z.infolist():
        if i.filename == P:
            o.writestr(copy.copy(i), z.read(P).replace(
                b'erase_list="0x0,0x1fffff;0x300000,0xffffffff;"',
                b'erase_list="0x0,0xffffffff;"'))
        else:
            with z.open(i) as a, o.open(copy.copy(i), "w") as b:
                shutil.copyfileobj(a, b, 1 << 20)
PY
  # The two slot modes relate to the template's erase list DIFFERENTLY, and the
  # test has to assert each one's real contract rather than a uniform "refuse":
  #
  #   slot a  INHERITS the template's profile untouched, so a hostile erase_list
  #           would ship. It must refuse.
  #   slot b  REWRITES the profile via configure_dual_slot(), which sets
  #           erase_list from the vendor constant, so a hostile template is
  #           sanitised. It must succeed AND the shipped erase list must be the
  #           safe one - asserted below, not assumed.
  if ! mking "$HOSTILE" "$WORK/bad-a.ingenic" a --allow-unpinned-template >/dev/null 2>&1 \
     && [ ! -f "$WORK/bad-a.ingenic" ]; then
    ok "REGRESSION: --slot a refuses a template whose erase_list would destroy sn_mac"
  else
    bad "REGRESSION: --slot a refuses a template whose erase_list would destroy sn_mac" \
        "an artifact was produced"
  fi

  if mking "$HOSTILE" "$WORK/sanitised.ingenic" b --allow-unpinned-template >/dev/null 2>&1; then
    got=$(python3 - "$WORK/sanitised.ingenic" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
for line in z.read("configs/x2000/x2000e_mmc0_lpddr2_linux.cfg").splitlines():
    if line.strip().startswith(b"erase_list="):
        print(line.split(b"=", 1)[1].decode()); break
PY
)
    if [ "$got" = '"0x0,0x1fffff;0x300000,0xffffffff;"' ]; then
      ok "REGRESSION: --slot b sanitises a hostile erase_list to the vendor one"
    else
      bad "REGRESSION: --slot b sanitises a hostile erase_list to the vendor one" "shipped $got"
    fi
  else
    bad "REGRESSION: --slot b sanitises a hostile erase_list to the vendor one" "packaging failed"
  fi

  # And the validator must catch it independently, on a package built by hand.
  BADA="$WORK/bad-slota.ingenic"
  python3 - "$HOSTILE" "$BADA" "$XIMAGE" "$ROOTFS" <<'PY' >/dev/null 2>&1
import sys, zipfile, copy, shutil
rep = {"images/xImage": sys.argv[3], "images/rootfs.squashfs": sys.argv[4]}
with zipfile.ZipFile(sys.argv[1]) as z, zipfile.ZipFile(sys.argv[2], "w", allowZip64=True) as o:
    for i in z.infolist():
        if i.filename in rep:
            with open(rep[i.filename], "rb") as a, o.open(copy.copy(i), "w") as b:
                shutil.copyfileobj(a, b, 1 << 20)
        else:
            with z.open(i) as a, o.open(copy.copy(i), "w") as b:
                shutil.copyfileobj(a, b, 1 << 20)
PY
  if ! python3 "$PKG/validate-ingenic.py" --package "$BADA" --template "$HOSTILE" \
         --ximage "$XIMAGE" --rootfs "$ROOTFS" --slot a >/dev/null 2>&1; then
    ok "REGRESSION: the validator catches a destroyed-sn_mac erase policy on --slot a"
  else
    bad "REGRESSION: the validator catches a destroyed-sn_mac erase policy on --slot a"
  fi

  # ---- REGRESSION: a for/else that always fired -----------------------------
  # The offset loop printed "every partition offset is unchanged" directly
  # beneath its own FAIL line. The verdict was right; the output lied.
  MOVED="$WORK/moved-offset.ingenic"
  python3 - "$ING" "$MOVED" <<'PY' >/dev/null 2>&1
import sys, zipfile, copy, shutil
P = "configs/x2000/x2000e_mmc0_lpddr2_linux.cfg"
with zipfile.ZipFile(sys.argv[1]) as z, zipfile.ZipFile(sys.argv[2], "w", allowZip64=True) as o:
    for i in z.infolist():
        if i.filename == P:
            o.writestr(copy.copy(i), z.read(P).replace(b"offset=0x1300000", b"offset=0x1400000"))
        else:
            with z.open(i) as a, o.open(copy.copy(i), "w") as b:
                shutil.copyfileobj(a, b, 1 << 20)
PY
  out=$(python3 "$PKG/validate-ingenic.py" --package "$MOVED" --template "$TEMPLATE" \
          --ximage "$XIMAGE" --rootfs "$ROOTFS" 2>&1)
  if printf '%s' "$out" | grep -q '^FAIL.*offset is unchanged' \
  && ! printf '%s' "$out" | grep -q '^PASS  every partition offset'; then
    ok "REGRESSION: a moved partition offset fails without also printing a contradicting PASS"
  else
    bad "REGRESSION: a moved offset must not print a contradicting PASS" \
        "$(printf '%s' "$out" | grep -E '^(PASS  every partition|FAIL.*offset)' | tr '\n' ' ')"
  fi

  if grep -q '^INGENIC_SN_MAC_PRESERVED=YES$' "$ING.manifest.txt" \
  && grep -q '^INGENIC_ERASE_LIST=0x0,0x1fffff;0x300000,0xffffffff;$' "$ING.manifest.txt"; then
    ok ".ingenic manifest reports the erase list actually in the package"
  else
    bad ".ingenic manifest reports the erase list actually in the package" \
        "$(grep -E '^INGENIC_(SN_MAC|ERASE)' "$ING.manifest.txt" | tr '\n' ' ')"
  fi

  if grep -q '^KEEP_STOCK_SPL_UBOOT_GPT=YES$' "$ING.manifest.txt"; then
    ok ".ingenic manifest records that vendor SPL/U-Boot/GPT is kept"
  else
    bad ".ingenic manifest records that vendor SPL/U-Boot/GPT is kept"
  fi

  IMG_X=$(grep '^XIMAGE_SHA256=' "$IMG.manifest.txt" | cut -d= -f2)
  ING_X=$(grep '^XIMAGE_SHA256=' "$ING.manifest.txt" | cut -d= -f2)
  IMG_R=$(grep '^ROOTFS_SQUASHFS_SHA256=' "$IMG.manifest.txt" | cut -d= -f2)
  ING_R=$(grep '^ROOTFS_SQUASHFS_SHA256=' "$ING.manifest.txt" | cut -d= -f2)
  if [ "$IMG_X" = "$X_SHA" ] && [ "$ING_X" = "$X_SHA" ] \
  && [ "$IMG_R" = "$R_SHA" ] && [ "$ING_R" = "$R_SHA" ]; then
    ok "both formats record the identical canonical xImage and rootfs hashes"
  else
    bad "both formats record the identical canonical xImage and rootfs hashes" \
        "img=$IMG_X/$IMG_R ingenic=$ING_X/$ING_R canonical=$X_SHA/$R_SHA"
  fi
fi

# --- 4. the reproducibility checker's own output contract -------------------
# REGRESSION: it printed XIMAGE_BYTE_IDENTICAL=YES unconditionally, including
# when the comparison it had just run proved otherwise.
if ! grep -q "XIMAGE_BYTE_IDENTICAL=YES.nROOTFS" "$PKG/check-packaging-reproducibility.sh" \
   && grep -q 'CORE_IDENTICAL_XIMAGE' "$PKG/check-packaging-reproducibility.sh"; then
  ok "the reproducibility checker derives its byte-identity verdict from the comparison"
else
  bad "the reproducibility checker derives its byte-identity verdict from the comparison"
fi

if ! grep -qE "^SECRET='\\\$1\\\$cxswfile" "$PKG/check-packaging-reproducibility.sh"; then
  ok "the reproducibility checker derives the envelope secret instead of hardcoding a third copy"
else
  bad "the reproducibility checker derives the envelope secret instead of hardcoding a third copy"
fi

echo
printf 'RELEASE_PACKAGING_TESTS_PASS=%d\nRELEASE_PACKAGING_TESTS_FAIL=%d\nRELEASE_PACKAGING_TESTS_SKIP=%d\n' \
  "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
