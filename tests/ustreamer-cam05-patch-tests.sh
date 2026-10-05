#!/bin/sh
#
# CAM-05 (2026-10-05): tests for scripts/build/patches/ustreamer-cam05-
# paused-blank-cache.patch and its application in 04-cross-compile-app-stack.sh.
#
#   - applies with zero fuzz to the exact pinned ustreamer source
#   - touches only the blank cache and the offline wait; the live path is untouched
#   - the patched blank.c encodes once per text/size instead of once per second
#     (host harness: tests/ustreamer-blank-cache-harness.c, real blank.c,
#     stubbed encoder), and the pristine one is shown to encode every second
#   - a resumed stream leaves the offline wait at once
#   - the build applies it fail-closed and ships the binary built from it
#
# Needs vendor/k1-ustreamer (fetched by the build); skips cleanly without it.
# Usage: sh tests/ustreamer-cam05-patch-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PATCH="$ROOT/scripts/build/patches/ustreamer-cam05-paused-blank-cache.patch"
BUILD="$ROOT/scripts/build/04-cross-compile-app-stack.sh"
HARNESS="$SCRIPT_DIR/ustreamer-blank-cache-harness.c"
K1="$ROOT/vendor/k1-ustreamer"
W=$(mktemp -d "${TMPDIR:-/tmp}/ustreamer-cam05-tests.XXXXXX")
[ -n "${W:-}" ] && [ -e "$W" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$PATCH" ] || { echo "FATAL: $PATCH missing"; exit 1; }

# --- build integration (no vendor tree needed) ---
grep -q 'patch -p1 --fuzz=0 --dry-run -d "$USRC" < "$CAM05_PATCH"' "$BUILD" && pass || fail "build does not dry-run the patch with --fuzz=0"
grep -q 'FATAL: CAM-05 ustreamer patch does not apply cleanly' "$BUILD" && pass || fail "build does not fail closed on a mismatched patch"
grep -q 'FATAL: CAM-05 patch effect not present' "$BUILD" && pass || fail "build has no effect assertion"
grep -q 'cp "$VENDOR/k1-ustreamer/build/ustreamer-src/src/ustreamer.bin" "$OVERLAY/usr/bin/ustreamer"' "$BUILD" && pass \
	|| fail "build does not ship the binary built from the patched copy"
grep -q 'git -C "$SRC/ustreamer" archive --format=tar HEAD' "$BUILD" && pass || fail "patched copy is not the pinned committed content"

# --- scope: only blank.c, blank.h and the offline wait in stream.c ---
files=$(grep '^+++ ' "$PATCH" | sed 's#^+++ b/##' | sort | tr '\n' ' ')
[ "$files" = "src/ustreamer/blank.c src/ustreamer/blank.h src/ustreamer/stream.c " ] && pass || fail "patch touches unexpected files: $files"
grep -E '^-[^-]' "$PATCH" | grep -q . && fail "patch removes upstream lines (should only add)" || pass
# stream.c: exactly the four offline-wait lines are added, nothing else
added=$(awk '/^\+\+\+ b\/src\/ustreamer\/stream.c/{s=1; next} /^diff --git/{s=0} s && /^\+/' "$PATCH" | sed 's/^+[[:space:]]*//')
expected='const bool offline_paused = atomic_load(&stream->paused);
if (offline_paused && !atomic_load(&stream->paused)) {
break; // Resumed: reopen the device now, not after the delay
}'
[ "$added" = "$expected" ] && pass || fail "stream.c additions are not exactly the offline-wait lines: $added"
grep -qE '^\+.*(us_capture_open|_jpeg_thread|_raw_thread|_h264_thread|us_encoder_compress|hwbuf)' "$PATCH" && fail "patch touches the live capture/encode path" || pass

if [ ! -d "$K1/ustreamer" ] || ! git -C "$K1/ustreamer" rev-parse HEAD >/dev/null 2>&1; then
	echo "NOTE: vendor/k1-ustreamer not fetched - source/harness checks skipped"
	echo "ustreamer-cam05-patch-tests: PASS=$PASS FAIL=$FAIL"
	[ "$FAIL" -eq 0 ]; exit
fi

# --- pin: vendor tree is the manifest's pin, submodule is the commit the patch targets ---
PIN=$(sed -n 's/^K1_USTREAMER_PIN=//p' "$ROOT/manifests/dependencies.conf")
[ "$(git -C "$K1" rev-parse HEAD)" = "$PIN" ] && pass || fail "vendor/k1-ustreamer is not at K1_USTREAMER_PIN"
SUB=$(git -C "$K1/ustreamer" rev-parse HEAD)
case "$SUB" in 7fe8c87*) pass ;; *) fail "ustreamer submodule is $SUB, patch was written against 7fe8c87" ;; esac

for v in pristine patched; do
	mkdir -p "$W/$v"; git -C "$K1/ustreamer" archive --format=tar HEAD | tar -x -C "$W/$v"
done
patch -p1 --fuzz=0 --dry-run -d "$W/patched" < "$PATCH" > /dev/null && pass || fail "patch does not apply with zero fuzz to the pinned source"
patch -p1 --fuzz=0 -s -d "$W/patched" < "$PATCH" || fail "patch failed to apply"
patch -p1 --fuzz=0 --dry-run -d "$W/patched" < "$PATCH" > /dev/null 2>&1 && fail "patch would apply twice (no fail-closed on an already patched tree)" || pass

B="$W/patched/src/ustreamer/blank.c"; S="$W/patched/src/ustreamer/stream.c"
# the early return sits before the encoder call inside us_blank_draw
awk '/^void us_blank_draw/{f=1} f&&/return;/{r=NR} f&&/us_cpu_encoder_compress/{c=NR; exit} END{exit !(r && c && r < c)}' "$B" && pass \
	|| fail "us_blank_draw does not return before the encoder on a cache hit"
grep -q 'US_DELETE(blank->jpeg_text, free);' "$B" && [ "$(grep -c 'US_DELETE(blank->jpeg_text, free);' "$B")" = 2 ] && pass \
	|| fail "cached text not freed on change and on destroy"
grep -q 'if (offline_paused && !atomic_load(&stream->paused))' "$S" && pass || fail "offline wait does not end on resume"
# live path identical: stream.c differs from the pristine copy only by those lines
extra=$(diff "$W/pristine/src/ustreamer/stream.c" "$W/patched/src/ustreamer/stream.c" | grep '^[<>]' | sed 's/^[<>][[:space:]]*//' \
	| grep -vxF 'const bool offline_paused = atomic_load(&stream->paused);' \
	| grep -vxF 'if (offline_paused && !atomic_load(&stream->paused)) {' \
	| grep -vxF 'break; // Resumed: reopen the device now, not after the delay' | grep -vx '}')
[ -z "$extra" ] && pass || fail "stream.c differs beyond the offline wait: $extra"

# --- behaviour: host harness against the real blank.c, pristine and patched ---
CC=${CC:-cc}
if command -v "$CC" >/dev/null 2>&1; then
	for v in pristine patched; do
		e=0; [ $v = patched ] && e=1
		if "$CC" -std=gnu17 -O1 -Wall -DEXPECT_CACHED=$e -I "$W/$v/src/ustreamer" -I "$W/$v/src" \
			"$W/$v/src/ustreamer/blank.c" "$HARNESS" -o "$W/h-$v" > "$W/cc-$v.log" 2>&1; then
			"$W/h-$v" > "$W/run-$v.log" 2>&1 && pass || fail "$v harness: $(grep FAIL "$W/run-$v.log")"
		else
			fail "$v harness did not compile: $(head -5 "$W/cc-$v.log")"
		fi
	done
	grep -q 'pristine: draws=62 encodes=62' "$W/run-pristine.log" && pass || fail "pristine baseline not reproduced: $(tail -1 "$W/run-pristine.log")"
	grep -q '60 s paused: no further encodes' "$W/run-patched.log" && pass || fail "patched blank re-encodes while paused"
else
	echo "NOTE: no host C compiler - harness skipped"
fi

echo "ustreamer-cam05-patch-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
