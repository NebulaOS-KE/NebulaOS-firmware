#!/bin/sh
#
# NG1 (2026-10-05): tests for br2-external/patches/python-tornado/6.4.2/0004-...
# (Buildroot's CVE-2025-67724 backport references httputil._ABNF, which
# Tornado 6.4.2 lacks; without it every HTTPError with a reason phrase - all
# of Moonraker's API errors - never reaches the client).
#
#   - wiring: the defconfig points BR2_GLOBAL_PATCH_DIR at br2-external/patches,
#     every patch sits in a <package>/<version>/ dir, and that version equals
#     the pinned Buildroot's <PKG>_VERSION (a version bump fails here and in
#     02-configure-buildroot.sh instead of silently dropping the patch)
#   - the patch applies with zero fuzz after Buildroot's own 0001-0003 on the
#     pristine 6.4.2 tarball, and refuses to apply twice
#   - behaviour, real Tornado on a loopback port: as Buildroot ships it, a 404
#     with a reason gets no response; with 0004, a prompt 404 carrying the
#     reason; an invalid reason is still replaced (validation intact); a plain
#     404 works
#
# Needs a Buildroot tree at BUILDROOT_PIN (BUILDROOT_DIR, default the newest
# /var/tmp/nebulaos-build run, else vendor/buildroot-x2000) and the tornado
# tarball in the Buildroot download cache; the source/behaviour part skips
# cleanly without them.
# Usage: sh tests/python-tornado-abnf-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
DEFCONFIG="$ROOT/br2-external/configs/nebulaos_x2000_defconfig"
PDIR="$ROOT/br2-external/patches"
PATCH="$PDIR/python-tornado/6.4.2/0004-httputil-add-_ABNF-reason_phrase-for-CVE-2025-67724-backport.patch"
W=$(mktemp -d "${TMPDIR:-/tmp}/tornado-abnf-tests.XXXXXX")
[ -n "${W:-}" ] && [ -e "$W" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$PATCH" ] || { echo "FATAL: $PATCH missing"; exit 1; }

# --- wiring (no Buildroot tree needed) ---
grep -qx 'BR2_GLOBAL_PATCH_DIR="$(BR2_EXTERNAL_NEBULAOS_PATH)/patches"' "$DEFCONFIG" && pass \
	|| fail "defconfig does not set BR2_GLOBAL_PATCH_DIR to the br2-external patches dir"
loose=$(find "$PDIR" -mindepth 2 -maxdepth 2 -name '*.patch' 2>/dev/null)
[ -z "$loose" ] && pass || fail "patches outside a <package>/<version>/ dir: $loose"
grep -q '^+class _ABNF:' "$PATCH" && grep -q '^+    reason_phrase = re.compile(' "$PATCH" && pass || fail "patch does not define _ABNF.reason_phrase"
[ "$(grep '^+++ ' "$PATCH" | sed 's#^+++ b/##')" = "tornado/httputil.py" ] && pass || fail "patch touches more than tornado/httputil.py"
grep -E '^-[^-]' "$PATCH" | grep -q . && fail "patch removes upstream lines" || pass
grep "^[+-]" "$PATCH" | grep -qi moonraker && fail "patch touches Moonraker" || pass
grep -q 'nebulaos_check_global_patch_versions' "$ROOT/scripts/build/02-configure-buildroot.sh" && pass \
	|| fail "02-configure-buildroot.sh does not check the patch version dirs"
grep -q 'NG1: python-tornado 0004' "$ROOT/scripts/build/06-verify.sh" && pass || fail "06-verify has no NG1 check"

# --- Buildroot tree at the pin ---
PIN=$(sed -n 's/^BUILDROOT_PIN=//p' "$ROOT/manifests/dependencies.conf")
BR=${BUILDROOT_DIR:-}
if [ -z "$BR" ]; then
	for d in $(ls -dt /var/tmp/nebulaos-build/*/run-*/vendor/buildroot-x2000 2>/dev/null) "$ROOT/vendor/buildroot-x2000"; do
		[ "$(git -C "$d" rev-parse HEAD 2>/dev/null)" = "$PIN" ] && { BR=$d; break; }
	done
fi
if [ -z "$BR" ] || [ ! -f "$BR/package/python-tornado/python-tornado.mk" ]; then
	echo "NOTE: no Buildroot tree at BUILDROOT_PIN - source/behaviour checks skipped"
	echo "python-tornado-abnf-tests: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]; exit
fi
for vd in "$PDIR"/*/*/; do
	pkg=$(basename "$(dirname "$vd")"); ver=$(basename "$vd")
	mk="$BR/package/$pkg/$pkg.mk"; var=$(echo "$pkg" | tr 'a-z-' 'A-Z_')_VERSION
	have=$(sed -n "s/^$var[[:space:]]*=[[:space:]]*//p" "$mk" 2>/dev/null | head -1)
	[ "$have" = "$ver" ] && pass || fail "patch dir $pkg/$ver but Buildroot has $pkg '$have' - stale, re-evaluate or remove"
done
TARBALL=
for d in "${BR2_DL_DIR:-}" "$HOME/.cache/nebulaos/buildroot-dl" "$BR/dl"; do
	[ -n "$d" ] && [ -f "$d/python-tornado/tornado-6.4.2.tar.gz" ] && { TARBALL="$d/python-tornado/tornado-6.4.2.tar.gz"; break; }
done
if [ -z "$TARBALL" ]; then
	echo "NOTE: tornado-6.4.2.tar.gz not in the download cache - behaviour checks skipped"
	echo "python-tornado-abnf-tests: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]; exit
fi
echo "92bad5b4746e9879fd7bf1eb21dce4e3fc5128d71601f80005afa39237ad620b  $TARBALL" | sha256sum -c --quiet - && pass \
	|| fail "tornado tarball hash differs from Buildroot's python-tornado.hash"

for v in shipped fixed; do
	mkdir -p "$W/$v"; tar -xzf "$TARBALL" -C "$W/$v"
	S="$W/$v/tornado-6.4.2"
	for p in "$BR"/package/python-tornado/0*.patch; do
		patch -p1 --fuzz=0 -s -d "$S" < "$p" || fail "Buildroot patch $(basename "$p") did not apply"
	done
done
S="$W/fixed/tornado-6.4.2"
patch -p1 --fuzz=0 --dry-run -s -d "$S" < "$PATCH" > /dev/null && pass || fail "0004 does not apply with zero fuzz after Buildroot's patches"
patch -p1 --fuzz=0 -s -d "$S" < "$PATCH" || fail "0004 failed to apply"
patch -p1 --fuzz=0 --dry-run -s -d "$S" < "$PATCH" > /dev/null 2>&1 && fail "0004 would apply twice" || pass
grep -q '_ABNF.reason_phrase.fullmatch' "$S/tornado/web.py" && pass || fail "the CVE-2025-67724 validation is no longer in web.py"

cat > "$W/serve.py" <<'EOF'
import socket, sys, threading, time, urllib.error, urllib.request
sys.path.insert(0, sys.argv[1])
import asyncio
import tornado.web
from tornado.httputil import __file__ as hfile


class Missing(tornado.web.RequestHandler):
    def get(self):
        raise tornado.web.HTTPError(404, reason="Key 'x' in namespace 'y' not found")


class Bad(tornado.web.RequestHandler):
    def get(self):
        raise tornado.web.HTTPError(400, reason="evil\r\nX-Injected: 1")


class Plain(tornado.web.RequestHandler):
    def get(self):
        raise tornado.web.HTTPError(404)


s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
box = {}


def serve():
    loop = asyncio.new_event_loop(); asyncio.set_event_loop(loop)
    app = tornado.web.Application([(r"/missing", Missing), (r"/bad", Bad), (r"/plain", Plain)])
    app.listen(port, "127.0.0.1"); box["loop"] = loop; loop.run_forever()


threading.Thread(target=serve, daemon=True).start()
time.sleep(0.8)
import tornado.httputil
print("HAS_ABNF=%s file=%s" % (hasattr(tornado.httputil, "_ABNF"), hfile))
for path in ("/missing", "/bad", "/plain"):
    t = time.monotonic()
    try:
        urllib.request.urlopen("http://127.0.0.1:%d%s" % (port, path), timeout=4)
        r = "200"
    except urllib.error.HTTPError as e:
        r = "%d|%s" % (e.code, e.reason)
    except Exception as e:
        r = "NORESPONSE"
    print("GET %s -> %s secs=%.1f" % (path, r, time.monotonic() - t), flush=True)
box["loop"].call_soon_threadsafe(box["loop"].stop)
EOF
if python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>/dev/null; then
	python3 "$W/serve.py" "$W/shipped/tornado-6.4.2" > "$W/shipped.out" 2> "$W/shipped.err"
	python3 "$W/serve.py" "$S" > "$W/fixed.out" 2> "$W/fixed.err"
	grep -q '^GET /missing -> NORESPONSE' "$W/shipped.out" && grep -q "_ABNF" "$W/shipped.err" && pass \
		|| fail "baseline not reproduced (shipped tornado answered the reason 404): $(cat "$W/shipped.out")"
	grep -q '^HAS_ABNF=True' "$W/fixed.out" && pass || fail "patched tornado has no _ABNF"
	grep -q "^GET /missing -> 404|Key 'x' in namespace 'y' not found secs=0" "$W/fixed.out" && pass \
		|| fail "patched: reason 404 not returned promptly: $(grep /missing "$W/fixed.out")"
	grep -q '^GET /bad -> 400|Unknown ' "$W/fixed.out" && pass || fail "patched: invalid reason phrase not replaced: $(grep /bad "$W/fixed.out")"
	grep -q '^GET /plain -> 404|Not Found ' "$W/fixed.out" && pass || fail "patched: plain 404 broken: $(grep /plain "$W/fixed.out")"
	grep -q "AttributeError" "$W/fixed.err" && fail "patched: AttributeError traceback: $(grep -m1 AttributeError "$W/fixed.err")" || pass
else
	echo "NOTE: no python3 - behaviour checks skipped"
fi

echo "python-tornado-abnf-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
