#!/bin/sh
#
# G91 S05 boot guard: S05nebulaos-activate never activates a persistent
# extensions checkout older than (or diverged from) the image's pin
# (seed-manifest.json nebulaos-klipper-extensions.seed_commit); the immutable
# stack runs instead. Offline: a real git repo, a fixture manifest.
#
# Usage: sh tests/s05-extensions-pin-guard-tests.sh

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OV="$REPO_ROOT/scripts/build/overlay"
ACTIVATE="$OV/etc/init.d/S05nebulaos-activate"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/s05-pin.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM
PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

E="$WORK/ext"
git init -q -b production "$E"
g() { git -C "$E" -c user.name=t -c user.email=t@l "$@"; }
for n in 1 2 3; do echo "$n" > "$E/f"; g add f; g commit -q -m "c$n"; done
C1=$(g rev-parse HEAD~2); C2=$(g rev-parse HEAD~1); C3=$(g rev-parse HEAD)
mkdir -p "$WORK/seeds"
manifest() {
	cat > "$WORK/seeds/seed-manifest.json" <<EOF
{
  "seeds": {
    "klipper": {
      "branch": "master",
      "seed_commit": "1111111111111111111111111111111111111111"
    },
    "nebulaos-klipper-extensions": {
      "branch": "production",
      "seed_commit": "$1"
    }
  }
}
EOF
}
mkdir -p "$WORK/root/system/diagnostics"
guard() { # -> rc; the decision file
	rm -f "$WORK/root/system/.activation-decisions"
	env S05NEBULAOS_ACTIVATE_NO_AUTORUN=1 NEBULAOS_ROOT="$WORK/root" SEEDS="$WORK/seeds" \
		SEED_MANIFEST_LIB="$OV/etc/nebulaos-seed-manifest.sh" \
		sh -c ". '$ACTIVATE'; extensions_not_older_than_pin '$E'" >"$WORK/out" 2>&1
}

manifest "$C2"
g checkout -q "$C1"; guard; rc=$?
if [ "$rc" != 0 ] && grep -q "immutable:extensions_older_than_image" "$WORK/root/system/.activation-decisions" \
	&& grep -q "do not contain this image's pin $C2" "$WORK/out"; then
	pass "an extensions checkout older than the image's pin is not activated (logged, recorded)"
else
	fail "older checkout: rc=$rc $(cat "$WORK/out")"
fi
g checkout -q "$C2"; guard; rc=$?
[ "$rc" = 0 ] && pass "HEAD at the pin is activated" || fail "pin itself refused: $(cat "$WORK/out")"
g checkout -q "$C3"; guard; rc=$?
[ "$rc" = 0 ] && pass "HEAD newer than the pin (an update) is activated" || fail "newer refused"
g checkout -q -b side "$C1"; echo x > "$E/f"; g commit -q -am side; guard; rc=$?
[ "$rc" != 0 ] && pass "a diverged checkout (pin not in its history) is not activated" || fail "diverged activated"
manifest "abcdefabcdefabcdefabcdefabcdefabcdefabcd"
g checkout -q "$C3"; guard; rc=$?
[ "$rc" != 0 ] && pass "a pin unknown to the checkout (cannot be newer) is not activated" || fail "unknown pin activated"
rm -f "$WORK/seeds/seed-manifest.json"; guard; rc=$?
[ "$rc" = 0 ] && grep -q "pin is unknown" "$WORK/out" && pass "no manifest (not a release image): not checked, logged" || fail "no manifest: rc=$rc"
grep -q 'extensions_not_older_than_pin "$edir" || return 1' "$ACTIVATE" \
	&& pass "activate_klipper_stack runs the guard before composing" || fail "guard not wired"

echo "s05-extensions-pin-guard-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
