# shellcheck shell=sh
#
# NebulaOS backlight runtime control (GUI/service readiness mission,
# 2026-10-09). The ONE place that drives the kernel backlight controller
# (CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER, nebulaos_backlight_final_
# controller.c) at runtime. Used by:
#   - /usr/libexec/nebulaos/nebulaos-backlight (CLI; nebulaos-osconfig's
#     display domain calls it - that is how GUI brightness/sleep/wake land)
#   - S98nebulaos-display-sleep-wake-controller start (boot brightness restore)
#
# OWNERSHIP. The kernel controller's state machine is the single source of
# truth for what the backlight is doing (boot-preserve / safe-on /
# pwm-committed / asleep). The only userspace writers are this library
# (level, sleep, wake) and the S98 touch-wake watcher, which only ever writes
# "wake" and only while the controller reports "asleep". The persisted level
# (/usr/data/nebulaos/display/display.env) belongs to nebulaos-osconfig.
#
# KNOWN LIMITATION (G5 stays open): the controller exposes NO
# /sys/class/backlight device - only a debugfs command whitelist. This is the
# only control the kernel offers, so this library uses it and mounts debugfs
# (mode 0700, root only) when it is not mounted. A stable sysfs interface
# needs a kernel change (a backlight_device in the controller) that this
# mission may not make.
#
# Levels are the controller's own: 25/50/75 (PWM, held by commit-pwm) and
# 100 (safe-on: GPC0 driven high, the verified-lit state). A PWM level can
# only be entered from safe-on, so changing between PWM levels passes through
# safe-on for a moment (a brief full-brightness flash) - a driver property.
#
# SAFETY RULE (same as /etc/nebulaos-display-qualified.sh): nothing here may
# leave the display worse than the kernel's boot-safe default. Every failure
# stops and does nothing further; the controller itself converges every
# failed/timed-out transition to safe-on (lit). Sleep is refused unless an
# independent touch-wake path (the S98 watcher) is running.

NBL_DEBUGFS="${NBL_DEBUGFS:-/sys/kernel/debug}"
NBL_DIR="${NBL_DIR:-$NBL_DEBUGFS/nebulaos_backlight_final}"
NBL_CMD="${NBL_CMD:-$NBL_DIR/command}"
NBL_STATUS="${NBL_STATUS:-$NBL_DIR/status}"
NBL_ENV="${NBL_ENV:-/usr/data/nebulaos/display/display.env}"
NBL_WATCHER_PIDFILE="${NBL_WATCHER_PIDFILE:-/var/run/nebulaos-display-sleep-wake-controller.pid}"
NBL_PROC_MOUNTS="${NBL_PROC_MOUNTS:-/proc/mounts}"
NBL_LEVELS="25 50 75 100"

nbl_log() {
	echo "nebulaos-backlight: $*" >&2
	command -v logger >/dev/null 2>&1 && logger -t nebulaos-backlight -- "$*" 2>/dev/null
	return 0
}

# debugfs is not mounted on this image (found by the G5 investigation).
nbl_ensure_debugfs() {
	grep -q " $NBL_DEBUGFS debugfs " "$NBL_PROC_MOUNTS" 2>/dev/null && return 0
	mount -t debugfs -o mode=0700,nosuid,nodev,noexec debugfs "$NBL_DEBUGFS" 2>/dev/null \
		|| { nbl_log "could not mount debugfs at $NBL_DEBUGFS"; return 1; }
	return 0
}

# Writes one whitelisted command. Tests replace this function.
nbl_kwrite() {
	printf '%s' "$1" > "$NBL_CMD" 2>/dev/null
}

nbl_field() {
	sed -n "s/^$1: //p" "$NBL_STATUS" 2>/dev/null | head -n1
}

nbl_state() { nbl_field state; }

nbl_available() {
	[ -w "$NBL_CMD" ] && [ -r "$NBL_STATUS" ]
}

nbl_watcher_running() {
	_p=$(cat "$NBL_WATCHER_PIDFILE" 2>/dev/null)
	[ -n "$_p" ] && kill -0 "$_p" 2>/dev/null
}

nbl_valid_level() {
	case " $NBL_LEVELS " in
		*" $1 "*) return 0 ;;
	esac
	return 1
}

# Current effective level: 100 in safe-on/boot-preserve, the duty when
# PWM-committed, 0 while asleep, "" when unknown.
nbl_current_level() {
	case "$(nbl_state)" in
		safe-on|boot-preserve) echo 100 ;;
		pwm-committed) nbl_field pwm_duty_pct ;;
		asleep) echo 0 ;;
		*) echo "" ;;
	esac
}

nbl_status_kv() {
	if ! nbl_available; then
		echo "available=0"
		return 0
	fi
	echo "available=1"
	echo "state=$(nbl_state)"
	echo "level=$(nbl_current_level)"
	echo "asleep=$(nbl_field asleep)"
	echo "wake_target=$(nbl_field wake_target)"
	echo "safe_on_verified=$(nbl_field safe_on_verified)"
	echo "op_failure_count=$(nbl_field op_failure_count)"
	echo "wake_failure_count=$(nbl_field wake_failure_count)"
	if nbl_watcher_running; then echo "touch_wake=1"; else echo "touch_wake=0"; fi
}

nbl_enter_safe_on() {
	nbl_kwrite enter-safe-on || { nbl_log "enter-safe-on rejected"; return 1; }
	if [ "$(nbl_state)" != safe-on ] || [ "$(nbl_field safe_on_verified)" != 1 ]; then
		nbl_log "enter-safe-on not confirmed by status - stopping"
		return 1
	fi
	return 0
}

# nbl_set_level 25|50|75|100. Exit: 0 applied, 1 invalid, 2 failed (the
# controller converges failures to safe-on), 3 asleep (nothing done; the level
# is applied on wake by the caller).
nbl_set_level() {
	nbl_valid_level "$1" || { nbl_log "invalid level '$1'"; return 1; }
	nbl_available || { nbl_log "controller not available"; return 2; }
	_st=$(nbl_state)
	[ "$_st" = asleep ] && return 3
	if [ "$1" = 100 ]; then
		[ "$_st" = safe-on ] && return 0
		nbl_enter_safe_on || return 2
		return 0
	fi
	if [ "$_st" = pwm-committed ] && [ "$(nbl_field pwm_duty_pct)" = "$1" ]; then
		return 0
	fi
	nbl_enter_safe_on || return 2
	nbl_kwrite "pwm-active-$1" || { nbl_log "pwm-active-$1 rejected (backlight stays safe-on)"; return 2; }
	# commit-pwm must follow inside the controller's 2 s bounded window,
	# otherwise its watchdog reverts to safe-on (lit) - never dark.
	nbl_kwrite commit-pwm || { nbl_log "commit-pwm rejected (controller reverts to safe-on)"; return 2; }
	if [ "$(nbl_state)" != pwm-committed ] || [ "$(nbl_field pwm_duty_pct)" != "$1" ]; then
		nbl_log "level $1 not confirmed by status"
		return 2
	fi
	return 0
}

# Exit: 0 asleep, 2 failed, 4 refused (no independent touch-wake path).
NBL_S98="${NBL_S98:-/etc/init.d/S98nebulaos-display-sleep-wake-controller}"
NBL_WATCHER_START_TENTHS="${NBL_WATCHER_START_TENTHS:-20}"

# Starts the touch-wake watcher if it is not running (allowed only when
# display.env says TOUCH_WAKE="1"), waiting briefly for its pidfile.
nbl_ensure_watcher() {
	nbl_watcher_running && return 0
	"$NBL_S98" watch >/dev/null 2>&1 || return 1
	_t=0
	while [ "$_t" -lt "$NBL_WATCHER_START_TENTHS" ]; do
		nbl_watcher_running && return 0
		sleep 0.1
		_t=$((_t + 1))
	done
	return 1
}

nbl_sleep() {
	nbl_available || return 2
	nbl_ensure_watcher || { nbl_log "sleep refused: no touch-wake watcher running"; return 4; }
	case "$(nbl_state)" in
		asleep) return 0 ;;
		boot-preserve) nbl_enter_safe_on || return 2 ;;
	esac
	nbl_kwrite sleep || { nbl_log "sleep rejected"; return 2; }
	[ "$(nbl_state)" = asleep ] || { nbl_log "sleep not confirmed"; return 2; }
	return 0
}

# Exit: 0 awake (or already awake), 2 failed.
nbl_wake() {
	nbl_available || return 2
	[ "$(nbl_state)" = asleep ] || return 0
	nbl_kwrite wake || { nbl_log "wake rejected"; return 2; }
	[ "$(nbl_state)" != asleep ] || { nbl_log "wake not confirmed"; return 2; }
	return 0
}

# Persisted level, re-validated; "" when absent/invalid.
nbl_persisted_level() {
	_lvl=$(sed -n 's/^BRIGHTNESS="\{0,1\}\([0-9]*\)"\{0,1\}$/\1/p' "$NBL_ENV" 2>/dev/null | head -n1)
	nbl_valid_level "$_lvl" && echo "$_lvl"
}

nbl_persisted_touch_wake() {
	_tw=$(sed -n 's/^TOUCH_WAKE="\{0,1\}\([01]\)"\{0,1\}$/\1/p' "$NBL_ENV" 2>/dev/null | head -n1)
	echo "${_tw:-1}"
}

# Boot: after the kernel's boot-safe default, apply a persisted level below
# 100. Nothing persisted, 100, or anything invalid: no controller command at
# all (the backlight stays exactly as the bootloader/kernel left it).
nbl_boot_restore() {
	# debugfs is mounted at boot once (root only), so status reads - from the
	# GUI or a read-only diagnostic capture - never have to change state.
	nbl_ensure_debugfs
	_lvl=$(nbl_persisted_level)
	if [ -z "$_lvl" ] || [ "$_lvl" = 100 ]; then
		return 0
	fi
	nbl_available || { nbl_log "boot restore: controller not available"; return 1; }
	nbl_set_level "$_lvl"
	_rc=$?
	[ "$_rc" -eq 0 ] && nbl_log "boot restore: level $_lvl"
	return "$_rc"
}
