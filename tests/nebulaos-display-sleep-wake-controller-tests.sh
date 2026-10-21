#!/bin/sh
#
# Offline, repeatable tests for scripts/build/overlay/etc/nebulaos-display-
# sleep-wake-controller.sh (the touch-wake watcher daemon's own library) -
# same pattern as tests/nebulaos-camera-idle-controller-tests.sh: sources
# the actual production library, fakes the kernel's sysfs attributes
# (backlight class device, touch nebulaos_touch directory) as plain files
# in a temp tree, never a real kernel.
#
# HONESTY NOTE, same as tests/nebulaos-display-qualified-tests.sh's own:
# there is no running kernel and no live BusyBox init system available
# from this environment. What this file genuinely proves is the watcher's
# own tick/loop logic (state tracking across ticks, the asleep-detection
# gate, the touch_down_count baseline/comparison, the wake write, the
# config-gated no-op, and the TERM/INT safety-net wake) against fakes. It
# does NOT and cannot prove the real ns2009_final_qualification/nebulaos_
# backlight_final_controller kernel drivers behave as expected - only live
# hardware qualification can do that.
#
# Usage: sh tests/nebulaos-display-sleep-wake-controller-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-display-sleep-wake-controller.sh"
NDQ_LIB_REAL="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-display-qualified.sh"
INITD_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S98nebulaos-display-sleep-wake-controller"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nebulaos-display-sleep-wake-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: nebulaos-display-sleep-wake-controller-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$LIB" ] || { echo "FATAL: $LIB not found"; exit 1; }
[ -f "$NDQ_LIB_REAL" ] || { echo "FATAL: $NDQ_LIB_REAL not found"; exit 1; }
[ -f "$INITD_SCRIPT" ] || { echo "FATAL: $INITD_SCRIPT not found"; exit 1; }

# Fake sysfs tree - plain temp files, reset before each scenario.
# bl_power starts empty ("never written"), so a wake shows up as bl_power=0
# and "no wake" as bl_power still empty.
BL="$WORK/sys/class/backlight/nebulaos_backlight"
TOUCH="$WORK/sys/bus/i2c/devices/0-0048/nebulaos_touch"

reset_fake_kernel() {
	rm -rf "$WORK/sys"
	mkdir -p "$BL" "$TOUCH"
	: > "$BL/bl_power"
	printf '4\n' > "$BL/brightness"
	printf '4\n' > "$BL/actual_brightness"
	printf '0\n' > "$TOUCH/touch_down_count"
}
set_asleep() {
	printf '0\n' > "$BL/actual_brightness"
}
set_awake() {
	printf '4\n' > "$BL/actual_brightness"
}
set_touch_count() {
	printf '%s\n' "$1" > "$TOUCH/touch_down_count"
}
woke() {
	[ "$(cat "$BL/bl_power" 2>/dev/null)" = "0" ]
}
no_write() {
	[ ! -s "$BL/bl_power" ]
}

NDQ_LIB="$NDQ_LIB_REAL"
NDQ_BACKLIGHT_SYSFS="$BL"
NDQ_TOUCH_SYSFS="$TOUCH"
export NDQ_LIB NDQ_BACKLIGHT_SYSFS NDQ_TOUCH_SYSFS

reset_fake_kernel
# shellcheck disable=SC1090
. "$LIB"

echo "============================================================"
echo "ndq_swc_backlight_is_asleep"
echo "============================================================"

reset_fake_kernel
if ndq_swc_backlight_is_asleep; then
	fail "actual_brightness 4 was reported as asleep"
else
	pass
fi

set_asleep
if ndq_swc_backlight_is_asleep; then
	pass
else
	fail "actual_brightness 0 was not detected as asleep"
fi

rm -f "$BL/actual_brightness"
if ndq_swc_backlight_is_asleep; then
	fail "a missing actual_brightness was treated as asleep"
else
	pass
fi
reset_fake_kernel

echo "============================================================"
echo "ndq_swc_touch_down_count"
echo "============================================================"

set_touch_count 42
got=$(ndq_swc_touch_down_count)
[ "$got" = "42" ] && pass || fail "touch_down_count read '$got', expected 42"

rm -f "$TOUCH/touch_down_count"
got=$(ndq_swc_touch_down_count)
[ -z "$got" ] && pass || fail "a missing touch_down_count did not read back empty (got '$got')"

# NDQ_TOUCH_SYSFS empty (no directory when the library was sourced): the
# directory is found by the glob under NDQ_I2C_DEVICES once it exists.
reset_fake_kernel
set_touch_count 7
got=$(NDQ_TOUCH_SYSFS="" NDQ_I2C_DEVICES="$WORK/sys/bus/i2c/devices" ndq_swc_touch_down_count)
[ "$got" = "7" ] && pass || fail "empty NDQ_TOUCH_SYSFS was not re-resolved by the glob (got '$got')"
got=$(NDQ_TOUCH_SYSFS="" NDQ_I2C_DEVICES="$WORK/none" ndq_swc_touch_down_count)
[ -z "$got" ] && pass || fail "no touch directory at all did not read back empty (got '$got')"
reset_fake_kernel

echo "============================================================"
echo "ndq_swc_tick - awake: never touches touch count, never wakes"
echo "============================================================"

reset_fake_kernel
set_awake
set_touch_count 99
result=$(ndq_swc_tick no -)
state=${result%% *}; lc=${result##* }
if [ "$state" = "no" ] && [ "$lc" = "-" ]; then
	pass
else
	fail "awake tick did not return 'no -' (got '$result')"
fi
no_write && pass || fail "awake tick wrote bl_power: $(cat "$BL/bl_power")"

# Also true even if the loop's own PREV state claims it was asleep -
# reality (actual_brightness) always wins.
result=$(ndq_swc_tick yes 10)
state=${result%% *}
[ "$state" = "no" ] && pass || fail "awake tick with prev_asleep=yes did not correct to 'no' (got '$state')"
no_write && pass || fail "awake tick (correcting stale prev=yes) wrote bl_power"

echo "============================================================"
echo "ndq_swc_tick - asleep+no touch increment -> no wake"
echo "============================================================"

reset_fake_kernel
set_asleep
set_touch_count 5
result=$(ndq_swc_tick yes 5)
state=${result%% *}; lc=${result##* }
if [ "$state" = "yes" ] && [ "$lc" = "5" ]; then
	pass
else
	fail "asleep/no-increment tick did not return 'yes 5' (got '$result')"
fi
no_write && pass || fail "asleep/no-increment tick incorrectly wrote bl_power: $(cat "$BL/bl_power")"

echo "============================================================"
echo "ndq_swc_tick - asleep+touch increment -> wake"
echo "============================================================"

reset_fake_kernel
set_asleep
set_touch_count 6
result=$(ndq_swc_tick yes 5)
state=${result%% *}; lc=${result##* }
if [ "$state" = "yes" ] && [ "$lc" = "6" ]; then
	pass
else
	fail "asleep/increment tick did not return 'yes 6' (got '$result')"
fi
woke && pass || fail "asleep/increment tick did not write bl_power=0 (got '$(cat "$BL/bl_power")')"
[ "$(cat "$BL/brightness")" = "4" ] && pass || fail "wake changed a non-zero brightness (got '$(cat "$BL/brightness")')"

echo "============================================================"
echo "ndq_swc_wake - brightness 0 is raised to full, missing bl_power fails"
echo "============================================================"

reset_fake_kernel
set_asleep
printf '0\n' > "$BL/brightness"
ndq_swc_wake 2>/dev/null && woke && [ "$(cat "$BL/brightness")" = "4" ] && pass \
	|| fail "wake with brightness 0 did not write bl_power=0 and brightness=4"

reset_fake_kernel
rm -f "$BL/bl_power"
if ndq_swc_wake 2>/dev/null; then
	fail "wake reported success with no bl_power attribute"
else
	pass
fi
[ ! -e "$BL/bl_power" ] && pass || fail "wake created bl_power although it was missing"

echo "============================================================"
echo "ndq_swc_tick - fresh transition into asleep never wakes on a stale count"
echo "============================================================"

# The touch driver already shows a HIGH count (accumulated while awake,
# well before sleep) at the exact moment the display transitions to
# asleep - a naive comparison against a leftover/garbage baseline must not
# fire. Baseline must be established fresh here, no wake this tick.
reset_fake_kernel
set_asleep
set_touch_count 500
result=$(ndq_swc_tick no -)
state=${result%% *}; lc=${result##* }
if [ "$state" = "yes" ] && [ "$lc" = "500" ]; then
	pass
else
	fail "fresh transition into asleep did not baseline to the current count (got '$result')"
fi
no_write && pass || fail "fresh transition into asleep incorrectly wrote bl_power"

# The very next tick, still no real new touch (count unchanged) -> still
# no wake.
result=$(ndq_swc_tick "$state" "$lc")
state2=${result%% *}
[ "$state2" = "yes" ] && pass || fail "expected to remain asleep with no new touch"
no_write && pass || fail "no-new-touch follow-up tick incorrectly wrote bl_power"

echo "============================================================"
echo "ndq_swc_tick - awake -> asleep -> awake -> asleep resets baseline each time"
echo "============================================================"

reset_fake_kernel
set_awake
set_touch_count 10
result=$(ndq_swc_tick no -)   # awake, tick 1
state=${result%% *}; lc=${result##* }
[ "$state" = "no" ] && [ "$lc" = "-" ] && pass || fail "expected awake/no-baseline, got '$result'"

set_asleep
result=$(ndq_swc_tick "$state" "$lc")  # transitions to asleep, baseline=10
state=${result%% *}; lc=${result##* }
[ "$state" = "yes" ] && [ "$lc" = "10" ] && pass || fail "expected fresh asleep baseline of 10, got '$result'"

set_awake
result=$(ndq_swc_tick "$state" "$lc")  # wakes on its own (e.g. some other mechanism), baseline reset
state=${result%% *}; lc=${result##* }
[ "$state" = "no" ] && [ "$lc" = "-" ] && pass || fail "expected baseline reset on return to awake, got '$result'"

# Touches accumulate while awake (not our concern) then it goes back to
# sleep - the OLD baseline of 10 must never be reused; the new baseline
# must be whatever the count is NOW.
set_touch_count 250
set_asleep
result=$(ndq_swc_tick "$state" "$lc")
state=${result%% *}; lc=${result##* }
[ "$state" = "yes" ] && [ "$lc" = "250" ] && pass || fail "expected a fresh baseline of 250 on the second sleep, got '$result'"
no_write && pass || fail "re-entering sleep with a fresh baseline incorrectly wrote bl_power"

echo "============================================================"
echo "ndq_swc_requested_mode"
echo "============================================================"

CONF="$WORK/display-qualified.conf"

# No touch_wake_mode field at all -> disabled (fail-safe default).
: > "$CONF"
mode=$(ndq_swc_requested_mode "$CONF")
[ "$mode" = "disabled" ] && pass || fail "an empty config produced '$mode', expected disabled"

printf 'touch_wake_mode=polling\n' > "$CONF"
mode=$(ndq_swc_requested_mode "$CONF")
[ "$mode" = "polling" ] && pass || fail "touch_wake_mode=polling produced '$mode', expected polling"

printf 'touch_wake_mode=disabled\n' > "$CONF"
mode=$(ndq_swc_requested_mode "$CONF")
[ "$mode" = "disabled" ] && pass || fail "touch_wake_mode=disabled produced '$mode', expected disabled"

printf 'touch_wake_mode=garbage\n' > "$CONF"
mode=$(ndq_swc_requested_mode "$CONF")
[ "$mode" = "disabled" ] && pass || fail "an unrecognized touch_wake_mode value did not fail safe to disabled (got '$mode')"

mode=$(ndq_swc_requested_mode "$WORK/does-not-exist.conf")
[ "$mode" = "disabled" ] && pass || fail "a missing config file did not fail safe to disabled (got '$mode')"

echo "============================================================"
echo "ndq_swc_run_loop - no-op when touch_wake_mode is not polling"
echo "============================================================"

# The run loop must exit immediately (not hang) when disabled - proven by
# running it with a short timeout via a background job + wait, rather than
# just trusting it "should" return quickly.
reset_fake_kernel
printf 'touch_wake_mode=disabled\n' > "$CONF"
(
	NDQ_CONFIG_FILE="$CONF"
	export NDQ_CONFIG_FILE
	ndq_swc_run_loop
) &
loop_pid=$!
i=0
while [ "$i" -lt 50 ] && kill -0 "$loop_pid" 2>/dev/null; do
	i=$((i + 1))
	sleep 0.1
done
if kill -0 "$loop_pid" 2>/dev/null; then
	fail "ndq_swc_run_loop did not exit promptly when touch_wake_mode != polling (still running after 5s)"
	kill -9 "$loop_pid" 2>/dev/null
else
	pass
fi
wait "$loop_pid" 2>/dev/null

echo "============================================================"
echo "ndq_swc_run_loop - TERM while asleep wakes as a safety net"
echo "============================================================"

reset_fake_kernel
set_asleep
set_touch_count 1
printf 'touch_wake_mode=polling\n' > "$CONF"
(
	NDQ_CONFIG_FILE="$CONF"
	NEBULAOS_DISPLAY_SLEEP_WAKE_POLL_INTERVAL=0.1
	export NDQ_CONFIG_FILE NEBULAOS_DISPLAY_SLEEP_WAKE_POLL_INTERVAL
	ndq_swc_run_loop
) &
loop_pid=$!
# Give it a couple of ticks to observe "asleep" and establish its baseline.
sleep 0.5
kill -TERM "$loop_pid" 2>/dev/null
wait "$loop_pid" 2>/dev/null
if woke; then
	pass
else
	fail "TERM while the loop believed the display asleep did not issue a safety-net wake (bl_power: '$(cat "$BL/bl_power" 2>/dev/null)')"
fi

echo "============================================================"
echo "ndq_swc_run_loop - TERM while awake does not spuriously wake"
echo "============================================================"

reset_fake_kernel
set_awake
printf 'touch_wake_mode=polling\n' > "$CONF"
(
	NDQ_CONFIG_FILE="$CONF"
	NEBULAOS_DISPLAY_SLEEP_WAKE_POLL_INTERVAL=0.1
	export NDQ_CONFIG_FILE NEBULAOS_DISPLAY_SLEEP_WAKE_POLL_INTERVAL
	ndq_swc_run_loop
) &
loop_pid=$!
sleep 0.5
kill -TERM "$loop_pid" 2>/dev/null
wait "$loop_pid" 2>/dev/null
if no_write; then
	pass
else
	fail "TERM while awake wrote bl_power unexpectedly: '$(cat "$BL/bl_power")'"
fi

echo "============================================================"
echo "S98 init.d script - structural checks"
echo "============================================================"

# start() must be a genuine no-op (never even attempts to background the
# daemon) when touch_wake_mode != polling - verified with a fake
# start-stop-daemon on PATH that logs every invocation, the same
# fake-command-on-PATH convention this project's other test suites already
# use (e.g. the faked wget/ip in tests/nebulaos-display-qualified-tests.sh).
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
SSD_LOG="$WORK/start-stop-daemon.log"
cat > "$FAKE_BIN/start-stop-daemon" <<EOF
#!/bin/sh
echo "start-stop-daemon \$*" >> "$SSD_LOG"
exit 0
EOF
chmod +x "$FAKE_BIN/start-stop-daemon"

reset_fake_kernel
printf 'touch_wake_mode=disabled\n' > "$CONF"
: > "$SSD_LOG"
(
	PATH="$FAKE_BIN:$PATH"
	export PATH
	NDQ_SLEEP_WAKE_LIB="$LIB" NDQ_CONFIG_FILE="$CONF" \
	NDQ_BACKLIGHT_SYSFS="$BL" NDQ_TOUCH_SYSFS="$TOUCH" \
	sh "$INITD_SCRIPT" start
) >/dev/null 2>&1
[ ! -s "$SSD_LOG" ] && pass || fail "S98 start() invoked start-stop-daemon even though touch_wake_mode != polling: $(cat "$SSD_LOG")"

# The mirror case: touch_wake_mode=polling must actually attempt to start
# the daemon (start-stop-daemon -S ... invoked at least once).
reset_fake_kernel
printf 'touch_wake_mode=polling\n' > "$CONF"
: > "$SSD_LOG"
(
	PATH="$FAKE_BIN:$PATH"
	export PATH
	NDQ_SLEEP_WAKE_LIB="$LIB" NDQ_CONFIG_FILE="$CONF" \
	NDQ_BACKLIGHT_SYSFS="$BL" NDQ_TOUCH_SYSFS="$TOUCH" \
	sh "$INITD_SCRIPT" start
) >/dev/null 2>&1
grep -q '^start-stop-daemon -S' "$SSD_LOG" 2>/dev/null && pass \
	|| fail "S98 start() did not invoke start-stop-daemon -S even though touch_wake_mode=polling (log: $(cat "$SSD_LOG" 2>/dev/null))"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
