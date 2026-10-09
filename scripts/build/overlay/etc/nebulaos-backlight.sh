# shellcheck shell=sh
#
# NebulaOS backlight runtime control (GUI/service readiness mission,
# 2026-10-09). The ONE userspace writer of the display backlight. Used by:
#   - /usr/libexec/nebulaos/nebulaos-backlight (CLI; nebulaos-osconfig's
#     display domain calls it - that is how GUI brightness/sleep/wake land)
#   - S98nebulaos-display-sleep-wake-controller start (boot brightness restore)
#
# INTERFACE: the kernel controller's standard backlight class device
# (nebulaos_backlight_final_controller.c, "STANDARD BACKLIGHT INTERFACE"):
#   /sys/class/backlight/nebulaos_backlight/
#     brightness 0..4   0 off, 1/2/3 = 25/50/75 %, 4 = full (safe-on)
#     bl_power          0 on, 4 (FB_BLANK_POWERDOWN) off; the brightness
#                       value is kept while off, so wake restores it
#     actual_brightness derived by the kernel from its state machine
# This closes G5: no debugfs for the backlight. (debugfs is still mounted at
# boot for the touch-wake watcher, which reads the touch driver's
# touch_down_count - a touch-side diagnostic interface, not the backlight.)
#
# OWNERSHIP. The kernel controller's state machine is the single source of
# truth; it verifies every transition and converges failures to safe-on
# (lit). The only userspace writers are this library and the S98 touch-wake
# watcher, which only clears bl_power, only while the backlight is off. The
# persisted level (/usr/data/nebulaos/display/display.env) belongs to
# nebulaos-osconfig.
#
# SAFETY RULE: nothing here may leave the display worse than the kernel's
# boot-safe default; any failure stops and does nothing further. Sleep is
# refused unless an independent touch-wake path (the S98 watcher) is running.

NBL_SYSFS="${NBL_SYSFS:-/sys/class/backlight/nebulaos_backlight}"
NBL_DEBUGFS="${NBL_DEBUGFS:-/sys/kernel/debug}"
NBL_ENV="${NBL_ENV:-/usr/data/nebulaos/display/display.env}"
NBL_WATCHER_PIDFILE="${NBL_WATCHER_PIDFILE:-/var/run/nebulaos-display-sleep-wake-controller.pid}"
NBL_PROC_MOUNTS="${NBL_PROC_MOUNTS:-/proc/mounts}"
NBL_LEVELS="25 50 75 100"
NBL_POWER_OFF=4

nbl_log() {
	echo "nebulaos-backlight: $*" >&2
	command -v logger >/dev/null 2>&1 && logger -t nebulaos-backlight -- "$*" 2>/dev/null
	return 0
}

# For the touch-wake watcher only (touch_down_count lives in debugfs).
nbl_ensure_debugfs() {
	grep -q " $NBL_DEBUGFS debugfs " "$NBL_PROC_MOUNTS" 2>/dev/null && return 0
	mount -t debugfs -o mode=0700,nosuid,nodev,noexec debugfs "$NBL_DEBUGFS" 2>/dev/null \
		|| { nbl_log "could not mount debugfs at $NBL_DEBUGFS"; return 1; }
	return 0
}

# Writes one sysfs attribute. Tests replace this function.
nbl_swrite() {
	printf '%s' "$2" > "$NBL_SYSFS/$1" 2>/dev/null
}

nbl_sread() {
	cat "$NBL_SYSFS/$1" 2>/dev/null
}

nbl_available() {
	[ -w "$NBL_SYSFS/brightness" ] && [ -w "$NBL_SYSFS/bl_power" ] \
		&& [ -r "$NBL_SYSFS/actual_brightness" ]
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

nbl_pct_raw() {
	case "$1" in 25) echo 1 ;; 50) echo 2 ;; 75) echo 3 ;; 100) echo 4 ;; esac
}

nbl_raw_pct() {
	case "$1" in 0) echo 0 ;; 1) echo 25 ;; 2) echo 50 ;; 3) echo 75 ;; 4) echo 100 ;; *) echo "" ;; esac
}

nbl_asleep() {
	[ "$(nbl_sread bl_power)" != 0 ] || [ "$(nbl_sread actual_brightness)" = 0 ]
}

# Effective level in percent: 0 while off, "" when unknown (fault).
nbl_current_level() {
	nbl_raw_pct "$(nbl_sread actual_brightness)"
}

nbl_status_kv() {
	if ! nbl_available; then
		echo "available=0"
		return 0
	fi
	echo "available=1"
	echo "interface=sysfs"
	echo "level=$(nbl_current_level)"
	echo "selected=$(nbl_raw_pct "$(nbl_sread brightness)")"
	if nbl_asleep; then echo "asleep=1"; else echo "asleep=0"; fi
	echo "bl_power=$(nbl_sread bl_power)"
	if nbl_watcher_running; then echo "touch_wake=1"; else echo "touch_wake=0"; fi
}

# nbl_set_level 25|50|75|100. Exit: 0 applied, 1 invalid, 2 failed (the
# kernel converges failures to safe-on), 3 off (stored; the kernel applies it
# on wake).
nbl_set_level() {
	nbl_valid_level "$1" || { nbl_log "invalid level '$1'"; return 1; }
	nbl_available || { nbl_log "backlight device not available"; return 2; }
	_raw=$(nbl_pct_raw "$1")
	if nbl_asleep; then
		nbl_swrite brightness "$_raw" || { nbl_log "brightness $_raw rejected"; return 2; }
		return 3
	fi
	[ "$(nbl_sread actual_brightness)" = "$_raw" ] && [ "$(nbl_sread brightness)" = "$_raw" ] && return 0
	nbl_swrite brightness "$_raw" || { nbl_log "brightness $_raw rejected (backlight stays lit)"; return 2; }
	[ "$(nbl_sread actual_brightness)" = "$_raw" ] || { nbl_log "level $1 not confirmed"; return 2; }
	return 0
}

NBL_S98="${NBL_S98:-/etc/init.d/S98nebulaos-display-sleep-wake-controller}"
NBL_WATCHER_START_TENTHS="${NBL_WATCHER_START_TENTHS:-20}"

# Starts the touch-wake watcher if it is not running (allowed only when
# display.env says TOUCH_WAKE="1"), waiting briefly for its pidfile.
nbl_ensure_watcher() {
	nbl_watcher_running && return 0
	nbl_ensure_debugfs || return 1
	"$NBL_S98" watch >/dev/null 2>&1 || return 1
	_t=0
	while [ "$_t" -lt "$NBL_WATCHER_START_TENTHS" ]; do
		nbl_watcher_running && return 0
		sleep 0.1
		_t=$((_t + 1))
	done
	return 1
}

# Exit: 0 off, 2 failed, 4 refused (no touch-wake path).
nbl_sleep() {
	nbl_available || return 2
	nbl_asleep && return 0
	nbl_ensure_watcher || { nbl_log "sleep refused: no touch-wake watcher running"; return 4; }
	nbl_swrite bl_power "$NBL_POWER_OFF" || { nbl_log "bl_power off rejected"; return 2; }
	[ "$(nbl_sread actual_brightness)" = 0 ] || { nbl_log "sleep not confirmed"; return 2; }
	return 0
}

# Exit: 0 on (or already on), 2 failed.
nbl_wake() {
	nbl_available || return 2
	nbl_asleep || return 0
	nbl_swrite bl_power 0 || { nbl_log "bl_power on rejected"; return 2; }
	# A brightness of 0 written by someone else would keep it dark: full.
	[ "$(nbl_sread brightness)" = 0 ] && nbl_swrite brightness 4
	[ "$(nbl_sread actual_brightness)" != 0 ] || { nbl_log "wake not confirmed"; return 2; }
	return 0
}

# Persisted level, re-validated; "" when absent/invalid.
nbl_persisted_level() {
	_lvl=$(sed -n 's/^BRIGHTNESS="\{0,1\}\([0-9]*\)"\{0,1\}$/\1/p' "$NBL_ENV" 2>/dev/null | head -n1)
	nbl_valid_level "$_lvl" && echo "$_lvl"
}

# Boot: after the kernel's boot-safe default, apply a persisted level below
# 100. Nothing persisted, 100, or anything invalid: nothing is written (the
# backlight stays exactly as the bootloader/kernel left it).
nbl_boot_restore() {
	_lvl=$(nbl_persisted_level)
	if [ -z "$_lvl" ] || [ "$_lvl" = 100 ]; then
		return 0
	fi
	nbl_available || { nbl_log "boot restore: backlight device not available"; return 1; }
	nbl_set_level "$_lvl"
	_rc=$?
	[ "$_rc" -eq 0 ] && nbl_log "boot restore: level $_lvl"
	return "$_rc"
}
