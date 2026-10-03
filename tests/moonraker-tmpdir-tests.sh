#!/bin/sh
#
# MEM-T04: offline coverage for S56moonraker's prepare_tmpdir(), which moves
# Moonraker's temporary files (uploads) from the RAM-backed /tmp to eMMC.
# Sources the init script through its S56MOONRAKER_NO_AUTORUN seam and drives
# prepare_tmpdir() against throwaway directories.
#
# Usage: sh tests/moonraker-tmpdir-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MOONRAKER_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S56moonraker"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/moonraker-tmpdir-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: mktemp did not produce a usable path" >&2; exit 1; }
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; [ -n "${SLEEPER:-}" ] && kill "$SLEEPER" 2>/dev/null' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

ORIG_TMPDIR=${TMPDIR:-}
S56MOONRAKER_NO_AUTORUN=1
MOONRAKER_TMPDIR="$WORK/tmp/moonraker"
PIDFILE="$WORK/moonraker.pid"
# shellcheck disable=SC1090
. "$MOONRAKER_SCRIPT"
# the script assigns PIDFILE unconditionally; point it back at the fixture
PIDFILE="$WORK/moonraker.pid"

# 1. no instance alive: directory created, leftovers wiped, TMPDIR exported
mkdir -p "$MOONRAKER_TMPDIR/stale-dir"
: > "$MOONRAKER_TMPDIR/moonraker.upload-1.mru"
rm -f "$PIDFILE"
TMPDIR=$ORIG_TMPDIR
prepare_tmpdir
[ "${TMPDIR:-}" = "$MOONRAKER_TMPDIR" ] && pass "TMPDIR exported when the directory is writable" || fail "TMPDIR not exported (got '${TMPDIR:-}')"
[ -z "$(ls -A "$MOONRAKER_TMPDIR")" ] && pass "leftovers wiped when no instance is alive" || fail "leftovers survived: $(ls -A "$MOONRAKER_TMPDIR")"

# 2. a live instance: nothing wiped, TMPDIR still exported
sleep 300 &
SLEEPER=$!
echo "$SLEEPER" > "$PIDFILE"
: > "$MOONRAKER_TMPDIR/moonraker.upload-2.mru"
TMPDIR=$ORIG_TMPDIR
prepare_tmpdir
[ -e "$MOONRAKER_TMPDIR/moonraker.upload-2.mru" ] && pass "never wipes under a live instance" || fail "wiped a live instance's upload"
[ "${TMPDIR:-}" = "$MOONRAKER_TMPDIR" ] && pass "TMPDIR exported even while the old instance is still exiting" || fail "TMPDIR not exported with a live pidfile"
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null; SLEEPER=

# 3. stale pidfile (process gone): wiped
echo 999999 > "$PIDFILE"
TMPDIR=$ORIG_TMPDIR
prepare_tmpdir
[ -z "$(ls -A "$MOONRAKER_TMPDIR")" ] && pass "a stale pidfile does not block the wipe" || fail "stale pidfile blocked the wipe"

# 4. unwritable: falls back (TMPDIR untouched), still succeeds
if [ "$(id -u)" != 0 ]; then
	chmod a-w "$MOONRAKER_TMPDIR"
	TMPDIR=$ORIG_TMPDIR
	out=$(prepare_tmpdir 2>&1); rc=$?
	[ "$rc" = 0 ] && pass "unwritable directory is not fatal" || fail "prepare_tmpdir failed (rc=$rc)"
	echo "$out" | grep -q 'falls back to RAM /tmp' && pass "fallback is logged" || fail "fallback not logged: $out"
	TMPDIR=$ORIG_TMPDIR
	prepare_tmpdir >/dev/null 2>&1
	[ "${TMPDIR:-}" = "$ORIG_TMPDIR" ] && pass "TMPDIR left unchanged on fallback" || fail "TMPDIR changed on fallback"
	chmod u+w "$MOONRAKER_TMPDIR"
fi
TMPDIR=$ORIG_TMPDIR

# 5. start_daemon calls prepare_tmpdir before start-stop-daemon
body=$(sed -n '/^start_daemon() {/,/^}/p' "$MOONRAKER_SCRIPT")
first=$(printf '%s\n' "$body" | sed -n 2p)
case "$first" in *prepare_tmpdir*) pass "start_daemon prepares TMPDIR first" ;; *) fail "start_daemon does not call prepare_tmpdir first" ;; esac

echo "moonraker-tmpdir-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
