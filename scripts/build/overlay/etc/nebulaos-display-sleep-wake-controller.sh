#!/bin/sh
#
# NebulaOS display sleep/wake touch watcher - the persistent background
# daemon side of the deferred sleep/touch-wake fields in
# /etc/nebulaos-display-qualified.sh (see that file's own
# ndq_apply_deferred_fields() for how/when this gets started, and this
# mission's own scope: this file builds the WAKE side only - polling the
# already-qualified touch driver's touch_down_count and issuing the
# backlight driver's "wake" command when a real touch is observed while
# asleep. It never triggers sleep itself; whatever future mechanism
# decides WHEN to sleep the display is explicitly out of scope here.
#
# ==========================================================================
# IMPORTANT ASSUMPTION - READ THIS BEFORE TRUSTING THIS FILE ON REAL
# HARDWARE, FIX HERE IF WRONG:
#
# The backlight driver's debugfs status file gaining a "sleep"/"wake"-
# capable asleep state is being added CONCURRENTLY by a different agent
# working in vendor/x2000_kernel_6.6, not yet visible from this checkout.
# This file was written against the command names `sleep`/`wake` and
# assumes the status file reports the asleep condition as the literal line
#     state: asleep
# (matching this exact driver's own existing convention of reporting
# other states the same way - e.g. "state: safe-on", "state: pwm-
# committed" - see ndq_apply_backlight()'s own grep pattern in
# /etc/nebulaos-display-qualified.sh for the precedent this follows).
#
# If the real, merged driver ends up using a different string for this
# state, the ONLY thing that needs to change is the pattern inside
# ndq_swc_backlight_is_asleep() below - nothing else in this file, or in
# S98nebulaos-display-sleep-wake-controller, or in the tests, depends on
# the exact string. That function is deliberately the single, isolated
# place this assumption lives.
# ==========================================================================
#
# Sourced by S98nebulaos-display-sleep-wake-controller. Also sourced
# directly by tests/nebulaos-display-sleep-wake-controller-tests.sh so
# there is exactly one copy of this logic, never a second one to drift out
# of sync - the same one-implementation-multiple-consumers pattern
# /etc/nebulaos-display-qualified.sh and /etc/nebulaos-camera-idle-
# controller.sh already both use.

# Sources the display-qualified library for ndq_get_field/ndq_is_uint/
# NDQ_CONFIG_FILE/NDQ_BACKLIGHT_STATUS_FILE/NDQ_BACKLIGHT_CMD_FILE/
# NDQ_TOUCH_STATUS_FILE - reused rather than re-parsing the config or
# re-declaring the debugfs paths a second time. Overridable so the offline
# test suite can point this at a fake library the same way every other
# caller of NDQ_LIB in this codebase already does.
: "${NDQ_LIB:=/etc/nebulaos-display-qualified.sh}"
# shellcheck disable=SC1090
[ -f "$NDQ_LIB" ] && . "$NDQ_LIB"

# Poll interval, in (possibly fractional) seconds - this image's BusyBox
# `sleep` is built with CONFIG_FLOAT_DURATION=y (see
# vendor/buildroot-x2000/package/busybox/busybox.config), so a sub-second
# value is safe to pass directly. 0.2s (200ms) is the chosen value: fast
# enough that a human touching the screen while it is asleep perceives the
# wake as immediate (a few hundred ms is well under the threshold where a
# human notices input lag), while staying far from a busy-loop - this is a
# real-time printer control system sharing the same CPU, and this daemon
# only ever does meaningful work (a debugfs read, occasionally a debugfs
# write) once every tick, the rest is sleeping. Named/overridable the same
# way NEBULAOS_CAMERA_IDLE_POLL_INTERVAL already is in this codebase's
# other background polling controller.
NEBULAOS_DISPLAY_SLEEP_WAKE_POLL_INTERVAL="${NEBULAOS_DISPLAY_SLEEP_WAKE_POLL_INTERVAL:-0.2}"

ndq_swc_log() {
	echo "nebulaos-display-sleep-wake-controller: $1" >&2
}

# ============================================================
# Config
# ============================================================

# Prints "polling" or "disabled" - reads touch_wake_mode from the
# persisted config via the shared library's own ndq_get_field(), never a
# second parser. Fails safe to "disabled" on anything missing/malformed -
# this watcher must never start its real loop work on a guess.
ndq_swc_requested_mode() {
	file="${1:-$NDQ_CONFIG_FILE}"
	mode=$(ndq_get_field "$file" touch_wake_mode 2>/dev/null)
	case "$mode" in
		polling) printf 'polling' ;;
		*) printf 'disabled' ;;
	esac
}

# GUI/service readiness mission (2026-10-09): the GUI sleep path (the
# display domain of nebulaos-osconfig, through /etc/nebulaos-backlight.sh)
# also needs this watcher, independently of the display-qualification config:
# it is the touch-wake path that keeps a GUI-initiated sleep recoverable when
# GuppyScreen or Moonraker is not responding. The display domain persists
# TOUCH_WAKE="1" in display.env; a missing file means not allowed.
: "${NDQ_DISPLAY_ENV:=/usr/data/nebulaos/display/display.env}"

ndq_swc_touch_wake_allowed() {
	[ "$(ndq_swc_requested_mode)" = "polling" ] && return 0
	grep -qx 'TOUCH_WAKE="1"' "$NDQ_DISPLAY_ENV" 2>/dev/null
}

# ============================================================
# Driver reads
# ============================================================

# See the IMPORTANT ASSUMPTION block at the top of this file - this is the
# ONE place the exact "asleep" status-line spelling is checked. Returns 0
# (true, asleep) only on a confirmed match; returns 1 (false, treat as
# "not asleep" / "unknown, do nothing") on anything else, including an
# unreadable status file - the safe direction on any doubt, matching this
# whole mission's own stated philosophy.
ndq_swc_backlight_is_asleep() {
	status_file="${1:-$NDQ_BACKLIGHT_STATUS_FILE}"
	[ -r "$status_file" ] || return 1
	grep -q '^state: asleep$' "$status_file" 2>/dev/null
}

# Prints the touch driver's touch_down_count (from its own already-
# qualified, already-deployed status file - see
# ns2009_final_qualification's own debugfs status, unchanged by this
# mission), or nothing if the file is unreadable/the field is absent.
ndq_swc_touch_down_count() {
	status_file="${1:-$NDQ_TOUCH_STATUS_FILE}"
	[ -r "$status_file" ] || return 1
	sed -n 's/^touch_down_count: //p' "$status_file" 2>/dev/null | tail -n1
}

# Writes "wake" to the backlight driver's command file - the one and only
# write this watcher ever issues. Command spelling matches exactly what
# was requested of the concurrent backlight-driver work (see this file's
# own header assumption block); if the merged driver ever uses a different
# spelling, this is the second (and only other) place to fix, right next
# to ndq_swc_backlight_is_asleep() above.
ndq_swc_wake() {
	if [ ! -w "$NDQ_BACKLIGHT_CMD_FILE" ]; then
		ndq_swc_log "wake: $NDQ_BACKLIGHT_CMD_FILE not present or not writable - cannot wake"
		return 1
	fi
	if printf '%s' "wake" > "$NDQ_BACKLIGHT_CMD_FILE" 2>/dev/null; then
		ndq_swc_log "wake: issued 'wake' to $NDQ_BACKLIGHT_CMD_FILE"
		return 0
	fi
	ndq_swc_log "wake: write of 'wake' to $NDQ_BACKLIGHT_CMD_FILE failed"
	return 1
}

# ============================================================
# One tick of the watch loop - pure enough to unit test: real side effects
# (the wake write) only happen via ndq_swc_wake, and the ONLY real-world
# read this performs is via ndq_swc_backlight_is_asleep/
# ndq_swc_touch_down_count, both of which read from overridable file-path
# variables - so tests can fake the entire kernel-facing surface with
# plain files on a temp path, the same convention
# tests/nebulaos-display-qualified-tests.sh already established for these
# exact two debugfs status files.
#
# ndq_swc_tick PREV_ASLEEP LAST_TOUCH_COUNT
#   PREV_ASLEEP: "yes" if the display was believed asleep as of the
#     previous tick, "no" otherwise (or on the very first tick ever).
#   LAST_TOUCH_COUNT: the touch_down_count observed the last time this
#     loop found the display asleep, or "-" if there is no baseline yet
#     (i.e. the previous tick was not asleep) - "-" is a sentinel, never a
#     real touch_down_count, which is always a plain non-negative integer.
#
# Prints "NEW_ASLEEP NEW_LAST_TOUCH_COUNT" (space-separated, same
# two-field convention as nebulaos_camera_idle_tick's own result) for the
# caller to carry into the next tick.
ndq_swc_tick() {
	prev_asleep="$1"
	last_count="$2"

	if ! ndq_swc_backlight_is_asleep; then
		# Awake (or the backlight status is unreadable/uncertain, in which
		# case "do nothing" is the only safe choice anyway) - no need to
		# poll touch at all while awake, that is GuppyScreen's/the
		# backlight driver's own concern, not this watcher's. Always
		# reset the baseline here so a stale pre-sleep touch count can
		# never survive into the next asleep period and cause an instant
		# false wake.
		printf 'no -'
		return 0
	fi

	current_count=$(ndq_swc_touch_down_count)
	[ -n "$current_count" ] || current_count="-"

	if [ "$prev_asleep" != "yes" ]; then
		# Just transitioned into asleep (or this is the very first tick
		# this loop has ever observed the display asleep) - establish the
		# baseline WITHOUT waking. A touch that happened before or during
		# the transition into sleep must never be mistaken for a NEW
		# touch that should wake it back up.
		printf 'yes %s' "$current_count"
		return 0
	fi

	# Already asleep as of the previous tick too - a real increase in
	# touch_down_count since then is a genuine new touch-down while
	# asleep, and is the one and only condition that wakes the display.
	if [ "$current_count" != "-" ] && [ "$last_count" != "-" ] \
		&& ndq_is_uint "$current_count" && ndq_is_uint "$last_count" \
		&& [ "$current_count" -gt "$last_count" ]; then
		ndq_swc_wake
	fi
	printf 'yes %s' "$current_count"
}

# ============================================================
# The real, long-running loop.
# ============================================================
#
# No-op by construction whenever touch_wake_mode is not "polling" in the
# persisted config - checked once at loop entry (the same config this
# process would have been started under; if the config changes later, the
# next boot/apply picks that up, matching every other config-gated
# controller in this codebase, none of which hot-reload their own
# config).
#
# On TERM/INT (graceful stop, e.g. S98's own stop(), or a normal shutdown)
# - if currently believed asleep, wakes the display once as a safety net
# before exiting, so the display's state never depends on this watcher
# process continuing to run. Mirrors nebulaos_camera_idle_run_loop's own
# already-established "always resume/wake on the way out" trap - SIGKILL
# cannot be trapped, an already-accepted, already-documented limitation of
# that same existing pattern.
ndq_swc_run_loop() {
	if ! ndq_swc_touch_wake_allowed; then
		ndq_swc_log "touch_wake_mode is not 'polling' in the persisted config and display.env does not allow touch-wake - nothing to watch, exiting"
		return 0
	fi

	asleep="no"
	last_count="-"

	trap '
		if [ "$asleep" = "yes" ]; then
			ndq_swc_log "stopping - display currently believed asleep, waking as a safety net so display state never depends on this watcher continuing to run"
			ndq_swc_wake || true
		fi
		exit 0
	' TERM INT

	while true; do
		result=$(ndq_swc_tick "$asleep" "$last_count")
		asleep=${result%% *}
		last_count=${result##* }
		sleep "$NEBULAOS_DISPLAY_SLEEP_WAKE_POLL_INTERVAL"
	done
}
