#!/bin/sh
#
# Offline, repeatable tests for scripts/build/overlay/etc/nebulaos-camera-
# idle-controller.sh (pre-qualification mission Phase A7, 2026-07-31).
# Sources the actual production library. Fakes `curl` on PATH and uses a
# synthetic /proc/net/tcp fixture, so no real ustreamer or network
# interface is needed. Covers the mission's own explicitly-enumerated
# scenario list.
#
# Usage: sh tests/nebulaos-camera-idle-controller-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LIB="$SCRIPT_DIR/../scripts/build/overlay/etc/nebulaos-camera-idle-controller.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nebulaos-camera-idle-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: nebulaos-camera-idle-controller-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0

fail() {
	echo "FAIL: $1"
	FAIL=$((FAIL + 1))
}

pass() {
	PASS=$((PASS + 1))
}

[ -f "$LIB" ] || { echo "FATAL: $LIB not found"; exit 1; }
# shellcheck disable=SC1090
. "$LIB"

# Fast, deterministic settings for every test below.
NEBULAOS_CAMERA_IDLE_GRACE_SAMPLES=3
NEBULAOS_CAMERA_IDLE_RESUME_RETRIES=2
NEBULAOS_CAMERA_IDLE_RESUME_BACKOFF_BASE=0

FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
FAKE_CURL_LOG="$WORK/curl.log"
FAKE_CURL_CODE_FILE="$WORK/curl-code"
echo "200" > "$FAKE_CURL_CODE_FILE"
cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >> "$FAKE_CURL_LOG"
if [ -f "$FAKE_CURL_CODE_FILE" ]; then
	code=$(cat "$FAKE_CURL_CODE_FILE")
else
	code=200
fi
printf '%s' "$code"
exit 0
EOF
chmod +x "$FAKE_BIN/curl"
export FAKE_CURL_LOG FAKE_CURL_CODE_FILE
PATH="$FAKE_BIN:$PATH"
export PATH

reset_curl_log() { : > "$FAKE_CURL_LOG"; echo "200" > "$FAKE_CURL_CODE_FILE"; }

# ============================================================
# Mode marker parsing
# ============================================================

# S3 (2026-10-05): idle auto-pause is the default. Only a marker containing
# exactly "C0" opts out; anything else (absent, C2, garbage, empty, a
# directory) is the product default C2.
for c in absent fresh c2 garbage empty dir c0; do
	m="$WORK/marker-$c"; rm -rf "$m"
	case $c in
	c0) printf 'C0\n' > "$m"; want=C0 ;;
	c2) printf 'C2\n' > "$m"; want=C2 ;;
	garbage) printf 'banana\n' > "$m"; want=C2 ;;
	empty) : > "$m"; want=C2 ;;
	dir) mkdir -p "$m"; want=C2 ;;
	*) want=C2 ;;
	esac
	if [ $c = fresh ]; then
		mode=$(NEBULAOS_CAMERA_IDLE_MARKER="$WORK/fresh/maintenance/camera-idle-mode" nebulaos_camera_idle_requested_mode)
	else
		mode=$(nebulaos_camera_idle_requested_mode "$m")
	fi
	[ "$mode" = "$want" ] && pass || fail "S3: marker '$c' produced '$mode', expected $want"
done
# a "C0" with trailing whitespace inside the line is not an opt-out (exact match, as C2 was before)
printf 'C0 \n' > "$WORK/marker-c0sp"
[ "$(nebulaos_camera_idle_requested_mode "$WORK/marker-c0sp")" = C2 ] && pass || fail "S3: 'C0 ' was treated as the opt-out"
# --- the image ships no marker (a shipped C0 would silently disable the default) ---
[ ! -e "$SCRIPT_DIR/../scripts/build/overlay/usr/data/nebulaos/maintenance/camera-idle-mode" ] && pass \
	|| fail "the overlay ships a camera-idle-mode marker"

# --- S51 init script: default starts the controller, C2 does, C0 does not, restart stops with a resume. ---
S51="$SCRIPT_DIR/../scripts/build/overlay/etc/init.d/S51nebulaos-camera-idle-controller"
SSD_LOG="$WORK/ssd.log"
cat > "$FAKE_BIN/start-stop-daemon" <<'EOF'
#!/bin/sh
echo "ssd $*" >> "$SSD_LOG"
exit 0
EOF
chmod +x "$FAKE_BIN/start-stop-daemon"
export SSD_LOG
run_s51() { # marker action
	( NEBULAOS_CAMERA_IDLE_MARKER="$1"; set -- "$2"; . "$S51" ) >/dev/null 2>&1
}
: > "$SSD_LOG"; reset_curl_log
run_s51 "$WORK/marker-absent" start
grep -q '^ssd -S .* __run' "$SSD_LOG" && pass || fail "S3: S51 start with no marker did not launch the controller (default C2)"
: > "$SSD_LOG"
run_s51 "$WORK/marker-c2" start
grep -q '^ssd -S .* __run' "$SSD_LOG" && pass || fail "S51 start with a C2 marker did not launch the controller (opt-in)"
: > "$SSD_LOG"
run_s51 "$WORK/marker-c0" start
[ ! -s "$SSD_LOG" ] && pass || fail "S51 start with a C0 marker launched the controller"
: > "$SSD_LOG"; reset_curl_log
run_s51 "$WORK/marker-c2" restart
if grep -q '^ssd -K' "$SSD_LOG" && grep -q '^ssd -S .* __run' "$SSD_LOG" && grep -q '/resume' "$FAKE_CURL_LOG"; then
	pass
else
	fail "S51 restart must stop (with a resume) and start the controller again"
fi
reset_curl_log

# --- S4 (2026-10-05): stop waits for the loop, resumes, then clears the state ---
# Fake loop: on TERM it finishes its "tick" 1.5 s later and writes "paused"
# (the race the old stop() lost), then exits. ssd -K sends it TERM.
cat > "$FAKE_BIN/start-stop-daemon" <<'EOF2'
#!/bin/sh
echo "ssd $*" >> "$SSD_LOG"
case " $* " in *" -K "*) p=; prev=; for a; do [ "$prev" = -p ] && p=$a; prev=$a; done
	[ -n "$p" ] && [ -f "$p" ] && kill -TERM "$(cat "$p")" 2>/dev/null ;; esac
exit 0
EOF2
chmod +x "$FAKE_BIN/start-stop-daemon"
S4PID="$WORK/s4.pid"; S4SF="$WORK/s4-state"
s4_loop() { # writes $S4PID
	sh -c 'trap "sleep 1.5; printf paused > \"$1\"; exit 0" TERM; while :; do sleep 0.1; done' s4 "$S4SF" &
	echo $! > "$S4PID"; sleep 0.3
}
s4_stop() {
	_t0=$(date +%s)
	( NEBULAOS_CAMERA_IDLE_MARKER="$WORK/marker-absent" NEBULAOS_CAMERA_IDLE_PIDFILE="$S4PID" \
	  NEBULAOS_CAMERA_IDLE_STATE_FILE="$S4SF"; set -- stop; . "$S51" ) >/dev/null 2>&1
	S4_SECS=$(( $(date +%s) - _t0 ))
}
# paused stop, resume OK -> state cleared after the loop exited, pidfile gone, no orphan
printf paused > "$S4SF"; s4_loop; lp=$(cat "$S4PID"); reset_curl_log
s4_stop
[ ! -e "$S4SF" ] && pass || fail "S4: state after stop while paused is '$(cat "$S4SF" 2>/dev/null)', expected cleared"
[ ! -e "$S4PID" ] && pass || fail "S4: pidfile left behind"
kill -0 "$lp" 2>/dev/null && fail "S4: controller loop still running after stop" || pass
grep -q '/resume' "$FAKE_CURL_LOG" && pass || fail "S4: stop did not resume the camera"
[ "$S4_SECS" -le 4 ] && pass || fail "S4: stop took ${S4_SECS}s"
# active stop -> cleared as well
printf active > "$S4SF"; s4_loop; reset_curl_log; s4_stop
[ ! -e "$S4SF" ] && pass || fail "S4: state after stop while active is '$(cat "$S4SF" 2>/dev/null)', expected cleared"
# resume fails -> truthful state kept
printf paused > "$S4SF"; s4_loop; reset_curl_log; echo 500 > "$FAKE_CURL_CODE_FILE"; s4_stop
[ "$(cat "$S4SF" 2>/dev/null)" = paused ] && pass || fail "S4: failed resume did not keep the truthful 'paused' state"
reset_curl_log
# a loop that ignores TERM: stop is bounded (~10 s) and still resumes
sh -c 'trap "" TERM; while :; do sleep 0.1; done' & hung=$!; echo $hung > "$S4PID"; printf paused > "$S4SF"
s4_stop; kill -9 $hung 2>/dev/null
[ "$S4_SECS" -ge 9 ] && [ "$S4_SECS" -le 13 ] && [ ! -e "$S4SF" ] && pass || fail "S4: stop with a stuck loop took ${S4_SECS}s / state '$(cat "$S4SF" 2>/dev/null)'"
# no pidfile at all (controller never started, C0): stop is immediate and harmless
rm -f "$S4PID" "$S4SF"; s4_stop
[ "$S4_SECS" -le 1 ] && pass || fail "S4: stop without a controller took ${S4_SECS}s"
# after stop, the next run starts from "active" (grace honoured), not a stale "paused"
[ "$(NEBULAOS_CAMERA_IDLE_STATE_FILE="$S4SF" nebulaos_camera_idle_read_state)" = active ] && pass || fail "S4: next start would not begin active"
reset_curl_log

# --- no camera-idle code path opens the video node to detect the camera. ---
if grep -v '^[[:space:]]*#' "$LIB" "$S51" | grep -q '/dev/video'; then
	fail "camera idle controller references /dev/video* outside comments"
else
	pass
fi

# ============================================================
# Connection detection (/proc/net/tcp parsing)
# ============================================================

# port 8080 = 1F90 hex
cat > "$WORK/proc-net-tcp-one" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1F90 0100007F:8B2E 01 00000000:00000000 00:00000000 00000000     0        0 12345 1 0000000000000000 100 0 0 10 0
EOF
if nebulaos_camera_has_established_connection 8080 "$WORK/proc-net-tcp-one"; then
	pass
else
	fail "a single ESTABLISHED connection on port 8080 was not detected"
fi

cat > "$WORK/proc-net-tcp-multi" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1F90 0100007F:8B2E 01 00000000:00000000 00:00000000 00000000     0        0 12345 1 0000000000000000 100 0 0 10 0
   1: 0100007F:1F90 0100007F:9A11 01 00000000:00000000 00:00000000 00000000     0        0 12346 1 0000000000000000 100 0 0 10 0
EOF
if nebulaos_camera_has_established_connection 8080 "$WORK/proc-net-tcp-multi"; then
	pass
else
	fail "multiple simultaneous ESTABLISHED connections on port 8080 were not detected"
fi

cat > "$WORK/proc-net-tcp-none" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:0050 0100007F:8B2E 01 00000000:00000000 00:00000000 00000000     0        0 12345 1 0000000000000000 100 0 0 10 0
   1: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12346 1 0000000000000000 100 0 0 10 0
EOF
if nebulaos_camera_has_established_connection 8080 "$WORK/proc-net-tcp-none"; then
	fail "a LISTEN-state (not ESTABLISHED) row on port 8080 was incorrectly treated as an active viewer"
else
	pass
fi

if nebulaos_camera_has_established_connection 8080 "$WORK/nonexistent-proc-file" >/dev/null 2>&1; then
	fail "an unreadable /proc/net/tcp path was treated as having a connection"
else
	pass
fi

# ============================================================
# Scenario 1: zero viewers -> grace timer -> pause
# ============================================================
reset_curl_log
state=active; idle=0
i=1
while [ "$i" -le "$NEBULAOS_CAMERA_IDLE_GRACE_SAMPLES" ]; do
	result=$(nebulaos_camera_idle_tick "$state" "$idle" no)
	state=${result%% *}; idle=${result##* }
	i=$((i + 1))
done
if [ "$state" = "paused" ] && grep -q "/pause" "$FAKE_CURL_LOG"; then
	pass
else
	fail "state after $NEBULAOS_CAMERA_IDLE_GRACE_SAMPLES idle ticks was '$state', expected paused (log: $(cat "$FAKE_CURL_LOG"))"
fi

# ============================================================
# Scenario 2: new viewer during grace -> cancel pause
# ============================================================
reset_curl_log
state=active; idle=0
result=$(nebulaos_camera_idle_tick "$state" "$idle" no)
state=${result%% *}; idle=${result##* }
result=$(nebulaos_camera_idle_tick "$state" "$idle" yes)
state=${result%% *}; idle=${result##* }
if [ "$state" = "active" ] && [ "$idle" = "0" ] && ! grep -q "/pause" "$FAKE_CURL_LOG"; then
	pass
else
	fail "a viewer appearing mid-grace did not cancel the pending pause (state=$state idle=$idle log: $(cat "$FAKE_CURL_LOG"))"
fi

# ============================================================
# Scenario 3: new viewer while paused -> resume
# ============================================================
reset_curl_log
result=$(nebulaos_camera_idle_tick paused 0 yes)
state=${result%% *}
if [ "$state" = "active" ] && grep -q "/resume" "$FAKE_CURL_LOG"; then
	pass
else
	fail "a viewer appearing while paused did not trigger a resume (state=$state log: $(cat "$FAKE_CURL_LOG"))"
fi

# ============================================================
# Scenario 4: multiple viewers -> remain active (no spurious pause)
# ============================================================
reset_curl_log
state=active; idle=0
i=1
while [ "$i" -le 5 ]; do
	result=$(nebulaos_camera_idle_tick "$state" "$idle" yes)
	state=${result%% *}; idle=${result##* }
	i=$((i + 1))
done
if [ "$state" = "active" ] && [ "$idle" = "0" ] && ! grep -q "/pause" "$FAKE_CURL_LOG"; then
	pass
else
	fail "sustained viewer presence incorrectly led to a pause (state=$state idle=$idle log: $(cat "$FAKE_CURL_LOG"))"
fi

# ============================================================
# Scenario 5: viewer disconnect -> grace timer starts
# ============================================================
reset_curl_log
result=$(nebulaos_camera_idle_tick active 0 yes)
state=${result%% *}; idle=${result##* }
result=$(nebulaos_camera_idle_tick "$state" "$idle" no)
state=${result%% *}; idle=${result##* }
if [ "$state" = "active" ] && [ "$idle" = "1" ]; then
	pass
else
	fail "a viewer disconnecting did not start the grace countdown (state=$state idle=$idle)"
fi

# ============================================================
# Scenario 6/7: camera unplug (ustreamer HTTP endpoint disappears) -
# curl fails outright, both while active (pause attempt fails) and
# while paused (resume attempt fails) - state must not silently
# advance on either failure, and nothing here may crash the tick.
# ============================================================
reset_curl_log
echo "" > "$FAKE_CURL_CODE_FILE"
state=active; idle=$((NEBULAOS_CAMERA_IDLE_GRACE_SAMPLES - 1))
result=$(nebulaos_camera_idle_tick "$state" "$idle" no)
state=${result%% *}
if [ "$state" = "active" ]; then
	pass
else
	fail "state incorrectly advanced to '$state' after a failed pause attempt (camera unplugged while active)"
fi

result=$(nebulaos_camera_idle_tick paused 0 yes)
state=${result%% *}
if [ "$state" = "paused" ]; then
	pass
else
	fail "state incorrectly advanced to '$state' after a failed resume attempt (camera unplugged while paused)"
fi
reset_curl_log

# ============================================================
# Scenario 8: ustreamer restart - a fresh ustreamer process always
# starts unpaused. CAM-02: with a "paused" belief and still no viewer, the
# tick re-asserts exactly one idempotent /pause, so a restarted ustreamer
# cannot keep streaming to nobody; the state stays paused.
# ============================================================
result=$(nebulaos_camera_idle_tick paused 0 no)
state=${result%% *}
pause_calls=$(grep -c "/pause" "$FAKE_CURL_LOG" 2>/dev/null)
if [ "$state" = "paused" ] && [ "$pause_calls" = "1" ] && ! grep -q "/resume" "$FAKE_CURL_LOG"; then
	pass
else
	fail "paused+no-viewer tick should re-assert exactly one /pause and stay paused (state=$state pause_calls=$pause_calls)"
fi

# ============================================================
# Scenario 9: controller restart - state recovery from a persisted
# state file, defaulting to "active" on anything missing/corrupt.
# ============================================================
STATE_FILE="$WORK/state-active"
printf 'active' > "$STATE_FILE"
recovered=$(nebulaos_camera_idle_read_state "$STATE_FILE")
[ "$recovered" = "active" ] && pass || fail "failed to recover a persisted 'active' state (got '$recovered')"

STATE_FILE="$WORK/state-paused"
printf 'paused' > "$STATE_FILE"
recovered=$(nebulaos_camera_idle_read_state "$STATE_FILE")
[ "$recovered" = "paused" ] && pass || fail "failed to recover a persisted 'paused' state (got '$recovered')"

recovered=$(nebulaos_camera_idle_read_state "$WORK/state-missing")
[ "$recovered" = "active" ] && pass || fail "a missing state file did not default to 'active' (got '$recovered')"

STATE_FILE="$WORK/state-corrupt"
printf 'garbage-value' > "$STATE_FILE"
recovered=$(nebulaos_camera_idle_read_state "$STATE_FILE")
[ "$recovered" = "active" ] && pass || fail "a corrupt state file did not fail safe to 'active' (got '$recovered')"

# ============================================================
# Scenario 10: invalid local endpoint response - pause/resume must
# report failure (not false success) on a non-200 response.
# ============================================================
echo "500" > "$FAKE_CURL_CODE_FILE"
if nebulaos_camera_pause >/dev/null 2>&1; then
	fail "pause() reported success on an HTTP 500 response"
else
	pass
fi
if nebulaos_camera_resume_with_retry >/dev/null 2>&1; then
	fail "resume_with_retry() reported success on a persistent HTTP 500 response"
else
	pass
fi
reset_curl_log

# ============================================================
# Scenario 11: bounded re-assertion - once paused, each no-viewer tick
# re-asserts at most one /pause (CAM-02, bounded to one per poll interval)
# and never resumes; once active, further yes-viewer ticks must not call
# /resume again.
# ============================================================
reset_curl_log
state=paused
i=1
while [ "$i" -le 5 ]; do
	result=$(nebulaos_camera_idle_tick "$state" 0 no)
	state=${result%% *}
	i=$((i + 1))
done
pause_calls=$(grep -c "/pause" "$FAKE_CURL_LOG" 2>/dev/null)
if [ "$state" = "paused" ] && [ "$pause_calls" = "5" ] && ! grep -q "/resume" "$FAKE_CURL_LOG"; then
	pass
else
	fail "5 no-viewer ticks while paused made $pause_calls /pause calls (want exactly 5, one per tick) or resumed"
fi

reset_curl_log
state=active
i=1
while [ "$i" -le 5 ]; do
	result=$(nebulaos_camera_idle_tick "$state" 0 yes)
	state=${result%% *}
	i=$((i + 1))
done
resume_calls=$(grep -c "/resume" "$FAKE_CURL_LOG" 2>/dev/null)
if [ "$state" = "active" ] && [ "$resume_calls" = "0" ]; then
	pass
else
	fail "repeated viewer-present ticks while already active made $resume_calls redundant /resume calls"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
