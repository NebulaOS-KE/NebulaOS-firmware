#!/bin/sh
# T2 (Run 13, 2026-10-18): tools/hardware/CONTROL_MANIFEST must pin exactly
# the current bytes of every privileged file.
#
# Run 12: G75 changed scripts/build/overlay/usr/libexec/nebulaos-datafs.sh -
# an on-device Hardware Agent helper - without regenerating the manifest, and
# every Hardware Agent operation (install included) refused until fabb7c0.
# This test fails at that moment instead, with the command that fixes it.
#
#   - every manifest entry's sha256 equals the file's current sha256
#   - every file listed in regen-control-manifest.sh is in the manifest
#   - the manifest names no file the regen script does not list
#
# Usage: sh tests/control-manifest-current-tests.sh
set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MANIFEST="$ROOT/tools/hardware/CONTROL_MANIFEST"
REGEN="$ROOT/tools/hardware/regen-control-manifest.sh"
FIX="sh tools/hardware/regen-control-manifest.sh, then commit tools/hardware/CONTROL_MANIFEST with the change"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

[ -f "$MANIFEST" ] || { echo "FATAL: $MANIFEST missing"; exit 1; }
[ -f "$REGEN" ] || { echo "FATAL: $REGEN missing"; exit 1; }

# 1. pinned bytes = current bytes
stale=""
while read -r sum kind path; do
	case "$sum" in ''|'#'*) continue ;; esac
	if [ ! -f "$ROOT/$path" ]; then
		fail "manifest pins $path ($kind), which does not exist"
		continue
	fi
	now=$(sha256sum "$ROOT/$path" | cut -d' ' -f1)
	if [ "$now" = "$sum" ]; then
		pass
	else
		stale="$stale $path"
		fail "$path changed but CONTROL_MANIFEST still pins ${sum%"${sum#????????????}"}... (now ${now%"${now#????????????}"}...)"
	fi
done < "$MANIFEST"

# 2. the regen script's lists and the manifest name the same files
listed=$(sed -n '/^ON_DEVICE=(/,/^)/p; /^HOST=(/,/^)/p' "$REGEN" | grep -E '^[[:space:]]+[A-Za-z0-9_./-]+$' | tr -d ' \t' | sort -u)
pinned=$(grep -E '^[0-9a-f]{64}  ' "$MANIFEST" | awk '{print $3}' | sort -u)
for f in $listed; do
	echo "$pinned" | grep -qxF "$f" && pass || fail "$f is listed in regen-control-manifest.sh but not pinned in CONTROL_MANIFEST"
done
for f in $pinned; do
	echo "$listed" | grep -qxF "$f" && pass || fail "CONTROL_MANIFEST pins $f, which regen-control-manifest.sh no longer lists"
done
[ -n "$listed" ] && pass || fail "could not read the file lists from regen-control-manifest.sh"

[ "$FAIL" -eq 0 ] || echo "Fix: $FIX"
echo "control-manifest-current-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
