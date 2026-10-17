#!/bin/sh
# G50 (2026-10-17): the Python ABI fingerprint (scripts/build/lib/python-abi.sh)
# and the pip.conf built from it. Fake .config, target and staging trees.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/scripts/build/lib/python-abi.sh"
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
W=$(mktemp -d "${TMPDIR:-/tmp}/python-abi.XXXXXX") || exit 1
[ -n "$W" ] && [ -d "$W" ] || exit 1
trap 'rm -rf "$W"' EXIT

mk() { # DIR FP NAN
	mkdir -p "$1/target/lib" "$1/target/usr/lib" "$1/staging/usr/lib/python3.12"
	cat > "$1/.config" <<EOF
BR2_ARCH="mipsel"
BR2_ENDIAN="LITTLE"
BR2_GCC_VERSION="13.4.0"
BR2_GCC_TARGET_ARCH="mips32r2"
BR2_GCC_TARGET_ABI="32"
BR2_GCC_TARGET_FP32_MODE="$2"
BR2_GCC_TARGET_NAN="$3"
EOF
	printf 'xx GNU C Library (Buildroot) stable release version 2.41.\nyy' > "$1/target/lib/libc.so.6"
	cat > "$1/staging/usr/lib/python3.12/_sysconfigdata__linux_mipsel-linux-gnu.py" <<'EOF'
build_time_vars = {'ABIFLAGS': '',
 'SOABI': 'cpython-312-mipsel-linux-gnu',
 'VERSION': '3.12',
}
EOF
	: > "$1/target/usr/lib/libz.so.1"; : > "$1/target/usr/lib/libffi.so.8"
}
fp() { sh -c ". '$LIB'; python_abi_fingerprint '$1/.config' '$1/target' '$1/staging'"; }

mk "$W/a" xx legacy
out=$(fp "$W/a")
for want in "python=3.12" "soabi=cpython-312-mipsel-linux-gnu" "platform_tag=linux_mips" "glibc=2.41" \
	"gcc=13.4.0" "arch=mips32r2" "abi=32" "fp32_mode=xx" "nan=legacy" "endian=little" "linkable=libz.so.1 libffi.so.8"; do
	echo "$out" | grep -qxF "$want" && pass || fail "missing '$want' in: $out"
done
id_a=$(echo "$out" | sed -n 's/^id=//p')
[ "${#id_a}" -eq 16 ] && pass || fail "id '$id_a'"
[ "$(fp "$W/a" | sed -n 's/^id=//p')" = "$id_a" ] && pass || fail "id not stable"

# every ABI-relevant change gives another id
mk "$W/b" 64 legacy; [ "$(fp "$W/b" | sed -n 's/^id=//p')" != "$id_a" ] && pass || fail "FP mode not in the id"
mk "$W/c" xx 2008; [ "$(fp "$W/c" | sed -n 's/^id=//p')" != "$id_a" ] && pass || fail "NaN not in the id"
mk "$W/d" xx legacy; : > "$W/d/target/usr/lib/libsodium.so.26"
[ "$(fp "$W/d" | sed -n 's/^id=//p')" != "$id_a" ] && pass || fail "linkable set not in the id"

# incomplete input fails instead of guessing
mk "$W/e" xx legacy; rm -f "$W/e/target/lib/libc.so.6"
fp "$W/e" >/dev/null 2>&1 && fail "no libc accepted" || pass
mk "$W/f" xx legacy; sed -i 's/mipsel/arm/' "$W/f/.config"
fp "$W/f" >/dev/null 2>&1 && fail "unknown arch accepted" || pass

conf=$(sh -c ". '$LIB'; python_abi_pip_conf https://example.org/simple/ $id_a")
echo "$conf" | grep -qxF "index-url = https://example.org/simple/$id_a/" && pass || fail "index-url: $conf"
echo "$conf" | grep -qx 'only-binary = :all:' && pass || fail "only-binary"
echo "$conf" | grep -qi 'extra-index-url' && fail "extra index" || pass

# the build wires it: manifest URL, stage 02 copies, post-build writes both files
grep -q '^NEBULAOS_PACKAGE_INDEX_URL=https://' "$ROOT/manifests/dependencies.conf" && pass || fail "manifest URL"
grep -q 'python-abi.sh" "$BR2_EXT_BOARD/python-abi.sh"' "$ROOT/scripts/build/02-configure-buildroot.sh" && pass || fail "02 copy"
grep -q 'etc/pip.conf' "$ROOT/scripts/build/nebulaos-post-build.sh" && grep -q 'usr/share/nebulaos/python-abi' "$ROOT/scripts/build/nebulaos-post-build.sh" \
	&& pass || fail "post-build"

echo "python-abi-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
