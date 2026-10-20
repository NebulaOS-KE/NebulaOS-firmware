#!/bin/sh
#
# G51 (2026-10-15): after a rollback the update manager's information is
# refreshed - retried until Moonraker answers (a Moonraker rollback restarts
# it), and again at start-up for every component whose last outcome was a
# rollback.
#
# Usage: sh tests/update-supervisor-refresh-tests.sh
set -u
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SUP="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-update-supervisor.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/update-supervisor-refresh.XXXXXX") || exit 1
[ -n "$WORK" ] && [ -d "$WORK" ] || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM
PASS=0 FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

export NEBULAOS_UPDATE_SUPERVISOR_NO_AUTORUN=1 NEBULAOS_ROOT="$WORK/nebulaos" \
	NEBULAOS_RUN_DIR="$WORK/run" MOONRAKER_URL="http://127.0.0.1:9" REFRESH_PAUSE=0
mkdir -p "$NEBULAOS_RUN_DIR" "$NEBULAOS_ROOT/updates/locks"
# shellcheck disable=SC1090
. "$SUP" >/dev/null 2>&1
log() { echo "LOG: $*" >> "$WORK/log"; }
# wget fails the first $FAILS calls (Moonraker restarting), then succeeds
wget() {
	echo "wget $*" >> "$WORK/wget.calls"
	n=$(wc -l < "$WORK/wget.calls")
	[ "$n" -gt "${FAILS:-0}" ]
}
settle() { i=0; while [ "$i" -lt 50 ] && ! grep -q "$1" "$WORK/log" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done; }

# retried until Moonraker answers
rm -f "$WORK/wget.calls" "$WORK/log"; FAILS=3
refresh_update_info moonraker; settle "refreshed (attempt"
[ "$(grep -c 'machine/update/refresh?name=moonraker' "$WORK/wget.calls" 2>/dev/null)" = 4 ] && pass || fail "attempts: $(cat "$WORK/wget.calls" 2>&1)"
grep -q "moonraker: Moonraker's update manager refreshed (attempt 4)" "$WORK/log" && pass || fail "log: $(cat "$WORK/log")"

# gives up after REFRESH_TRIES
rm -f "$WORK/wget.calls" "$WORK/log"; FAILS=99; REFRESH_TRIES=3
refresh_update_info mainsail; settle "could not be refreshed"
[ "$(wc -l < "$WORK/wget.calls")" = 3 ] && pass || fail "give-up attempts: $(wc -l < "$WORK/wget.calls")"
REFRESH_TRIES=12

# start-up: only rolled-back components are refreshed
rm -f "$WORK/wget.calls" "$WORK/log"; FAILS=0
read_state_field() { case "$1" in moonraker) echo rolled-back ;; mainsail) echo healthy ;; esac; }
read_stack_field() { echo rolled-back; }
reconcile_update_info_on_boot; settle "klipper: Moonraker's update manager refreshed"; settle "moonraker: Moonraker's update manager refreshed"
calls=$(sed 's/.*name=//' "$WORK/wget.calls" | sort | tr '\n' ' ')
[ "$calls" = "klipper moonraker " ] && pass || fail "boot refreshes: $calls"
rm -f "$WORK/wget.calls"
read_state_field() { echo healthy; }
read_stack_field() { echo healthy; }
reconcile_update_info_on_boot; sleep 0.3
[ ! -e "$WORK/wget.calls" ] && pass || fail "healthy components refreshed: $(cat "$WORK/wget.calls")"
# G85: after this boot's image migration, all three app trees are refreshed
# once (the marker is consumed), whatever their last update outcome was
rm -f "$WORK/wget.calls" "$WORK/log"
: > "$NEBULAOS_RUN_DIR/apps-migrated"
reconcile_update_info_on_boot
settle "nebulaos_klipper_extensions: Moonraker's update manager refreshed"
settle "klipper: Moonraker's update manager refreshed"; settle "moonraker: Moonraker's update manager refreshed"
calls=$(sed 's/.*name=//' "$WORK/wget.calls" | sort | tr '\n' ' ')
[ "$calls" = "klipper moonraker nebulaos_klipper_extensions " ] && pass || fail "after migration: $calls"
[ ! -e "$NEBULAOS_RUN_DIR/apps-migrated" ] && pass || fail "marker not consumed"
rm -f "$WORK/wget.calls"
reconcile_update_info_on_boot; sleep 0.3
[ ! -e "$WORK/wget.calls" ] && pass || fail "refreshed twice: $(cat "$WORK/wget.calls")"
grep -q 'apps-migrated' "$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate" && pass || fail "S04 does not leave the marker"

grep -q "reconcile_update_info_on_boot" "$SUP" && sed -n '/^loop() {/,/^}/p' "$SUP" | grep -q reconcile_update_info_on_boot && pass || fail "not called from loop()"

echo "update-supervisor-refresh-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
