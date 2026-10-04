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

# --- no marker -> C2 (idle pause ON, the default since HWDP-DWC-4/6). ---
mode=$(nebulaos_camera_idle_requested_mode "$WORK/marker-absent")
[ "$mode" = "C2" ] && pass || fail "no marker produced '$mode', expected C2 (default on)"

# --- fresh image: the shipped default marker path is absent -> C2. ---
mode=$(NEBULAOS_CAMERA_IDLE_MARKER="$WORK/fresh/maintenance/camera-idle-mode" nebulaos_camera_idle_requested_mode)
[ "$mode" = "C2" ] && pass || fail "fresh image (no marker at the default path) produced '$mode', expected C2"

# --- marker containing C0 -> C0 (explicit opt-out). ---
printf 'C0\n' > "$WORK/marker-c0"
mode=$(nebulaos_camera_idle_requested_mode "$WORK/marker-c0")
[ "$mode" = "C0" ] && pass || fail "a C0 marker produced '$mode', expected C0 (opt-out)"

# --- marker containing C2 -> C2 (explicit opt-in still honoured). ---
printf 'C2\n' > "$WORK/marker-c2"
mode=$(nebulaos_camera_idle_requested_mode "$WORK/marker-c2")
[ "$mode" = "C2" ] && pass || fail "a C2 marker produced '$mode', expected C2"

# --- unrecognized marker content fails safe to C0. ---
printf 'banana\n' > "$WORK/marker-garbage"
mode=$(nebulaos_camera_idle_requested_mode "$WORK/marker-garbage")
[ "$mode" = "C0" ] && pass || fail "a garbage marker produced '$mode', expected C0 (fail-safe)"

# --- empty marker file fails safe to C0. ---
: > "$WORK/marker-empty"
mode=$(nebulaos_camera_idle_requested_mode "$WORK/marker-empty")
[ "$mode" = "C0" ] && pass || fail "an empty marker produced '$mode', expected C0 (fail-safe)"

# --- a marker path that exists but is not a readable file fails safe to C0. ---
mkdir -p "$WORK/marker-dir"
mode=$(nebulaos_camera_idle_requested_mode "$WORK/marker-dir")
[ "$mode" = "C0" ] && pass || fail "a directory at the marker path produced '$mode', expected C0 (fail-safe)"

# --- S51 init script: default starts the controller, C0 does not, stop resumes. ---
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
grep -q '^ssd -S .* __run' "$SSD_LOG" && pass || fail "S51 start with no marker did not launch the controller"
: > "$SSD_LOG"
run_s51 "$WORK/marker-c0" start
[ ! -s "$SSD_LOG" ] && pass || fail "S51 start with a C0 marker launched the controller"
: > "$SSD_LOG"; reset_curl_log
run_s51 "$WORK/marker-absent" restart
if grep -q '^ssd -K' "$SSD_LOG" && grep -q '^ssd -S .* __run' "$SSD_LOG" && grep -q '/resume' "$FAKE_CURL_LOG"; then
	pass
else
	fail "S51 restart must stop (with a resume) and start the controller again"
fi
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
