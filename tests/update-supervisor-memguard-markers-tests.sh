#!/bin/sh
#
# MEM-T16: the update supervisor respects nebulaos-memguard's markers.
#   print-active                 -> print_is_active is true without asking Moonraker
#   memguard/deny-maintenance    -> restart_component defers (returns 1, no restart)
#   shed/moonraker-restarting    -> ensure_moonraker_alive does nothing
#
# Usage: sh tests/update-supervisor-memguard-markers-tests.sh

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
SUP="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-update-supervisor.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/update-supervisor-markers.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM
PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

export NEBULAOS_UPDATE_SUPERVISOR_NO_AUTORUN=1 NEBULAOS_ROOT="$WORK/nebulaos" \
	NEBULAOS_RUN_DIR="$WORK/run" MOONRAKER_URL="http://127.0.0.1:9" RESTART_GRACE_PERIOD=0
mkdir -p "$NEBULAOS_RUN_DIR/memguard" "$NEBULAOS_RUN_DIR/shed" "$NEBULAOS_ROOT/updates/locks"
# shellcheck disable=SC1090
. "$SUP" >/dev/null 2>&1
log() { echo "LOG: $*" >> "$WORK/log"; }
wget() { echo "wget $*" >> "$WORK/wget.calls"; return 1; }   # Moonraker unreachable

# print-active
if print_is_active; then fail "no marker, Moonraker down: reads as printing"; else pass "no marker, Moonraker down: not printing"; fi
: > "$NEBULAOS_RUN_DIR/print-active"
rm -f "$WORK/wget.calls"
if print_is_active; then pass "print-active marker: printing"; else fail "print-active marker ignored"; fi
[ ! -e "$WORK/wget.calls" ] && pass "marker short-circuits the Moonraker query" || fail "Moonraker still queried"
rm -f "$NEBULAOS_RUN_DIR/print-active"

# deny-maintenance
component_info() { echo "x|$WORK/fake-init|x|$WORK/x.pid"; }
safe_stop_start() { echo restarted >> "$WORK/restarts"; }
: > "$NEBULAOS_RUN_DIR/memguard/deny-maintenance"
if restart_component moonraker; then fail "restart not deferred under deny-maintenance"; else pass "restart deferred under deny-maintenance"; fi
[ ! -e "$WORK/restarts" ] && pass "no restart happened" || fail "a restart happened"
grep -q 'deferred - memguard' "$WORK/log" && pass "deferral logged" || fail "deferral not logged"
rm -f "$NEBULAOS_RUN_DIR/memguard/deny-maintenance"
if restart_component moonraker; then pass "restart proceeds without the marker"; else fail "restart refused without the marker"; fi

# moonraker-restarting
printf '#!/bin/sh\necho "$@" >> %s/init.calls\n' "$WORK" > "$WORK/fake-init"; chmod +x "$WORK/fake-init"
: > "$NEBULAOS_RUN_DIR/shed/moonraker-restarting"
ensure_moonraker_alive
[ ! -e "$WORK/init.calls" ] && pass "no Moonraker start while memguard restarts it" || fail "supervisor raced memguard's restart"
rm -f "$NEBULAOS_RUN_DIR/shed/moonraker-restarting"
ensure_moonraker_alive
grep -q start "$WORK/init.calls" 2>/dev/null && pass "without the marker a dead Moonraker is started" || fail "dead Moonraker not started"

echo "update-supervisor-memguard-markers-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
