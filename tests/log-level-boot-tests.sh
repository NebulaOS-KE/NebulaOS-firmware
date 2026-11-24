#!/bin/sh
#
# Offline tests for the 1.0.5 log levels at boot: S03nebulaos-blackbox turns
# the kernel recorder's detail level on at Debug and Verbose (also when Debug
# is only the image's default), and the shell readers of the level
# (syslogd defaults, S56moonraker) know Verbose.
#
# Usage: sh tests/log-level-boot-tests.sh

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OV="$REPO_ROOT/scripts/build/overlay"
S03="$OV/etc/init.d/S03nebulaos-blackbox"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/log-level-boot-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
expect() { [ "$2" = "$3" ] && pass "$1" || fail "$1 (got '$2', want '$3')"; }

detail() { # level-file-content (or -) default-content (or -) -> what the recorder got
	rm -f "$WORK/level" "$WORK/default" "$WORK/ctl"
	[ "$1" = - ] || echo "$1" > "$WORK/level"
	[ "$2" = - ] || echo "$2" > "$WORK/default"
	: > "$WORK/ctl"
	NEBULAOS_LOG_LEVEL_FILE="$WORK/level" NEBULAOS_LOG_LEVEL_DEFAULT_FILE="$WORK/default" \
		NEBULAOS_FLIGHTREC_CTL="$WORK/ctl" sh "$S03" detail > "$WORK/out" 2>&1
	cat "$WORK/ctl"
}

sh -n "$S03" && pass "S03 parses" || fail "S03 does not parse"
expect "info: recorder untouched" "$(detail info info)" ""
expect "warning: recorder untouched" "$(detail warning info)" ""
expect "debug: detail on" "$(detail debug info)" "detail=1"
expect "verbose: detail on" "$(detail verbose info)" "detail=1"
expect "no level, default info: untouched" "$(detail - info)" ""
expect "no level, test build default debug: detail on" "$(detail - debug)" "detail=1"
expect "broken level, default debug: detail on" "$(detail loud debug)" "detail=1"
expect "chosen info beats a debug default" "$(detail info debug)" ""
expect "no level, no default file: untouched" "$(detail - -)" ""
detail debug info > /dev/null
expect "boot line" "$(cat "$WORK/out")" "nebulaos-blackbox: recorder detail on (log level debug)"
rm -f "$WORK/ctl"
NEBULAOS_LOG_LEVEL_FILE="$WORK/level" NEBULAOS_FLIGHTREC_CTL="$WORK/ctl" sh "$S03" detail > "$WORK/out" 2>&1
expect "no recorder: says so, no file created" "$(cat "$WORK/out"; [ -e "$WORK/ctl" ] && echo created)" \
	"nebulaos-blackbox: recorder detail not available"

expect "image default is info in a release" "$(cat "$OV/etc/nebulaos/log-level-default")" "info"
grep -q '= verbose ] && MOONRAKER_VERBOSE=-v' "$OV/etc/init.d/S56moonraker" \
	&& pass "Moonraker -v only at verbose" || fail "S56moonraker: -v not tied to verbose"
grep -q '= debug ] && MOONRAKER_VERBOSE' "$OV/etc/init.d/S56moonraker" \
	&& fail "S56moonraker still turns -v on at debug" || pass "no Moonraker -v at debug"
grep -q 'debug|verbose) NEBULAOS_SYSLOG_L=8' "$OV/etc/default/syslogd" \
	&& pass "syslogd: verbose logs like debug" || fail "syslogd: verbose not handled"
grep -q 'log-level-default' "$OV/etc/default/syslogd" \
	&& pass "syslogd: falls back to the image default" || fail "syslogd: no image default"

echo
echo "log-level-boot: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
