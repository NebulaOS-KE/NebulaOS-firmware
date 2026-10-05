#!/bin/sh
#
# BOOT-05 (2026-10-05): S56moonraker no longer holds rcS (and so S57/S58 and
# the screen) until Moonraker's /server/info answers. The first-start
# update_manager check runs in the background with the same decision logic.
# Exercises the real S56 start()/stop() with stubbed daemons against a local
# HTTP fixture standing in for /server/info.
#
# Usage: sh tests/moonraker-ui-startup-order-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
S56="$ROOT/scripts/build/overlay/etc/init.d/S56moonraker"
S58="$ROOT/scripts/build/overlay/etc/init.d/S58guppyscreen"
GUPPY="$ROOT/vendor/nebulaos-guppyscreen"
W=$(mktemp -d "${TMPDIR:-/tmp}/moonraker-ui-startup-order-tests.XXXXXX")
[ -n "${W:-}" ] && [ -e "$W" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
SERVER_PID=
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

# fixture: serves BODY on PORT after DELAY seconds (0 = at once)
fixture() { # port delay body
	python3 - "$1" "$2" "$3" > "$W/fixture.log" 2>&1 <<'PYEOF' &
import http.server, sys, time
port, delay, body = int(sys.argv[1]), float(sys.argv[2]), sys.argv[3].encode()
time.sleep(delay)
class H(http.server.BaseHTTPRequestHandler):
	def do_GET(self):
		self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
		self.wfile.write(body)
	def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF
	SERVER_PID=$!
}
stop_fixture() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=; }

FAILED_UM='{"result": {"klippy_connected": true, "failed_components": ["update_manager"]}}'
HEALTHY='{"result": {"klippy_connected": true, "failed_components": []}}'

# run_start CASE PORT TIMEOUT : runs S56 start with stubbed daemons; the
# stub start_daemon writes a fresh fake pid each call.
run_start() {
	C="$W/$1"; mkdir -p "$C"; : > "$C/calls"
	env S56MOONRAKER_NO_AUTORUN=1 MOONRAKER_PIDFILE="$C/moonraker.pid" MOONRAKER_RECOVERY_PIDFILE="$C/recovery.pid" \
		MOONRAKER_INFO_URL="http://127.0.0.1:$2/server/info" MOONRAKER_INFO_POLL_TIMEOUT="$3" MOONRAKER_INFO_POLL_INTERVAL=1 \
		sh -c ". '$S56'
			n=0
			start_daemon() { n=\$((n + 1)); echo start_daemon >> '$C/calls'; echo \$((40000 + n + \$\$ % 1000)) > '$C/moonraker.pid'; }
			stop() { cancel_pending_recovery; echo stop >> '$C/calls'; }
			t0=\$(date +%s%N 2>/dev/null || date +%s)
			start
			t1=\$(date +%s%N 2>/dev/null || date +%s)
			echo \$(( (t1 - t0) / 1000000 )) > '$C/start-ms'
			$4" > "$C/out" 2>&1
}
wait_recovery_done() { # case max-seconds
	i=0; while [ $i -lt $(( $2 * 10 )) ]; do
		[ -e "$W/$1/recovery.pid" ] || return 0
		p=$(cat "$W/$1/recovery.pid" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null || return 0
		sleep 0.1; i=$((i + 1)); done
	return 1
}

# 1. Moonraker already ready + healthy: start returns at once, no restart
fixture 18801 0 "$HEALTHY"; sleep 0.5
run_start ready 18801 5 ""
[ "$(cat "$W/ready/start-ms")" -lt 1000 ] && pass || fail "start() blocked $(cat "$W/ready/start-ms") ms with Moonraker ready"
wait_recovery_done ready 8 && pass || fail "background check did not finish"
[ "$(grep -c '' "$W/ready/calls")" = 1 ] && pass || fail "healthy start restarted Moonraker: $(cat "$W/ready/calls")"
stop_fixture

# 2. Moonraker delayed (answers after 2 s, update_manager failed): start
#    returns at once; the background check restarts exactly once
fixture 18802 2 "$FAILED_UM"
run_start delayed 18802 8 ""
[ "$(cat "$W/delayed/start-ms")" -lt 1000 ] && pass || fail "start() blocked $(cat "$W/delayed/start-ms") ms on a delayed Moonraker"
wait_recovery_done delayed 12 && pass || fail "delayed: background check did not finish"
[ "$(cat "$W/delayed/calls" | tr '\n' ' ')" = "start_daemon stop start_daemon " ] && pass \
	|| fail "delayed: expected one restart, got: $(cat "$W/delayed/calls" | tr '\n' ' ')"
stop_fixture

# 3. Moonraker very delayed / failed (never answers within the bound): no
#    restart, no loop, start still immediate
run_start never 18803 2 ""
[ "$(cat "$W/never/start-ms")" -lt 1000 ] && pass || fail "start() blocked on a dead Moonraker"
wait_recovery_done never 6 && pass || fail "never: background check not bounded"
[ "$(grep -c '' "$W/never/calls")" = 1 ] && grep -q 'did not respond' "$W/never/out" && pass \
	|| fail "never: unexpected calls $(cat "$W/never/calls" | tr '\n' ' ') / $(cat "$W/never/out")"

# 4. explicit stop while the check is pending cancels it: no later restart
fixture 18804 3 "$FAILED_UM"
run_start cancelled 18804 8 "stop"
sleep 5
grep -q 'cancelled the pending' "$W/cancelled/out" && pass || fail "stop did not cancel the pending check ($(cat "$W/cancelled/out"))"
[ "$(cat "$W/cancelled/calls" | tr '\n' ' ')" = "start_daemon stop " ] && pass \
	|| fail "a cancelled check still restarted Moonraker: $(cat "$W/cancelled/calls" | tr '\n' ' ')"
stop_fixture

# 5. Moonraker restarted by someone else meanwhile (pid changed): leave it
fixture 18805 2 "$FAILED_UM"
run_start replaced 18805 8 "echo 99999 > '$W/replaced/moonraker.pid'"
wait_recovery_done replaced 12
grep -q 'restarted meanwhile' "$W/replaced/out" && [ "$(grep -c '' "$W/replaced/calls")" = 1 ] && pass \
	|| fail "replaced instance was restarted again: $(cat "$W/replaced/calls" | tr '\n' ' ') / $(cat "$W/replaced/out")"
stop_fixture

# 6. a stale recovery pid that is not S56 is never killed
C="$W/stale"; mkdir -p "$C"; sleep 30 & SL=$!; echo $SL > "$C/recovery.pid"
env S56MOONRAKER_NO_AUTORUN=1 MOONRAKER_RECOVERY_PIDFILE="$C/recovery.pid" sh -c ". '$S56'; cancel_pending_recovery" > "$C/out" 2>&1
kill -0 $SL 2>/dev/null && [ ! -e "$C/recovery.pid" ] && pass || fail "cancel killed an unrelated process or kept the pidfile"
kill $SL 2>/dev/null

# 7. S58 has no dependency on Moonraker being ready
grep -v '^[[:space:]]*#' "$S58" | grep -qE 'wget|curl|7125|server/info|sleep' && fail "S58 waits on Moonraker" || pass

# 8. GuppyScreen (pinned source) tolerates a backend that is not up yet
if [ -f "$GUPPY/src/websocket_client.cpp" ]; then
	grep -q 'reconn.min_delay = 200;' "$GUPPY/src/websocket_client.cpp" && grep -q 'reconn.max_delay = 2000;' "$GUPPY/src/websocket_client.cpp" \
		&& pass || fail "GuppyScreen reconnect backoff changed (no longer 200 ms - 2 s)"
	grep -q 'setReconnect(&reconn);' "$GUPPY/src/websocket_client.cpp" && pass || fail "GuppyScreen no longer reconnects"
	grep -q 'init_panel.disconnected(ws)' "$GUPPY/src/guppyscreen.cpp" && pass || fail "GuppyScreen no longer shows the init overlay on disconnect"
	H=$(find "$GUPPY/libhv" -name hloop.h -path '*include/hv/*' 2>/dev/null | head -1)
	[ -n "$H" ] && grep -q 'define DEFAULT_RECONNECT_MAX_RETRY_CNT INFINITE' "$H" && pass || fail "libhv retry count is not infinite"
else
	echo "NOTE: vendor/nebulaos-guppyscreen not fetched - GuppyScreen source checks skipped"
fi

echo "moonraker-ui-startup-order-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
