#!/bin/sh
#
# Offline tests for /etc/nebulaos-backlight.sh, the /usr/libexec/nebulaos/
# nebulaos-backlight CLI and the S98 GUI-sleep additions (GUI/service
# readiness mission, 2026-10-09).
#
# HONESTY NOTE: the kernel is a FAKE here - a few lines of shell following
# the rules of the controller's standard backlight device
# (nebulaos_backlight_final_controller.c, "STANDARD BACKLIGHT INTERFACE"):
# brightness 0..4 is kept, bl_power != 0 means off, actual_brightness = 0
# while off, else the selected level. What is proven is this library's
# sequencing and its "any failure: do nothing further" rule, not the driver.
#
# Usage: sh tests/nebulaos-backlight-tests.sh

set -u
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY="$REPO_ROOT/scripts/build/overlay"
LIB="$OVERLAY/etc/nebulaos-backlight.sh"
CLI="$OVERLAY/usr/libexec/nebulaos/nebulaos-backlight"
S98="$OVERLAY/etc/init.d/S98nebulaos-display-sleep-wake-controller"
SWC="$OVERLAY/etc/nebulaos-display-sleep-wake-controller.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
check() { if eval "$2"; then pass; else fail "$1"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/nbl-tests.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

# Fake device: three attribute files, kept consistent by fake_sync.
setup() {
	rm -rf "$T/c"; mkdir -p "$T/c/bl"
	export NBL_SYSFS="$T/c/bl"
	export NBL_ENV="$T/c/display.env"
	export NBL_WATCHER_PIDFILE="$T/c/watcher.pid"
	export NBL_S98="$T/c/s98"
	export NBL_WATCHER_START_TENTHS=3
	: > "$T/c/log"
	FK_BRIGHT=${1:-4}; FK_POWER=${2:-0}; FK_BROKEN=""; FK_STUCK=""
	fake_sync
	printf '#!/bin/sh\nexit 1\n' > "$NBL_S98"; chmod 755 "$NBL_S98"
}

fake_sync() {
	echo "$FK_BRIGHT" > "$NBL_SYSFS/brightness"
	echo "$FK_POWER" > "$NBL_SYSFS/bl_power"
	if [ "$FK_POWER" != 0 ]; then echo 0; else echo "$FK_BRIGHT"; fi > "$NBL_SYSFS/actual_brightness"
}

fake_swrite() {
	echo "$1=$2" >> "$T/c/log"
	case "$FK_BROKEN" in *" $1 "*) return 1 ;; esac
	case "$1" in
		brightness) case "$2" in [0-4]) FK_BRIGHT=$2 ;; *) return 1 ;; esac ;;
		bl_power) FK_POWER=$2 ;;
		*) return 1 ;;
	esac
	[ -n "$FK_STUCK" ] && return 0   # accepted, but the hardware never follows
	fake_sync
	return 0
}

load() {
	. "$LIB"
	nbl_swrite() { fake_swrite "$1" "$2"; }
	sleep() { :; }
}

writes() { tr '\n' ' ' < "$T/c/log" | sed 's/ $//'; }

# --- set level ---------------------------------------------------------------
setup; load
nbl_set_level 50; rc=$?
check "set 50 succeeds" '[ $rc -eq 0 ]'
check "set 50 = one brightness write" '[ "$(writes)" = "brightness=2" ] && [ "$(cat "$NBL_SYSFS/actual_brightness")" = 2 ]'
: > "$T/c/log"; nbl_set_level 50
check "same level again is a no-op" '[ -z "$(writes)" ]'
nbl_set_level 25
check "25 -> raw 1, single write (no pass through full)" '[ "$(writes)" = "brightness=1" ]'
: > "$T/c/log"; nbl_set_level 100
check "100 -> raw 4" '[ "$(writes)" = "brightness=4" ]'
for bad in 0 30 101 abc "" "50 x" "-1" 4; do
	: > "$T/c/log"; nbl_set_level "$bad"; rc=$?
	check "invalid level '$bad' rejected, nothing written" '[ $rc -eq 1 ] && [ -z "$(writes)" ]'
done

setup; load; FK_BROKEN=" brightness "
nbl_set_level 75; rc=$?
check "rejected write reports 2" '[ $rc -eq 2 ]'
setup; load; FK_STUCK=1
nbl_set_level 75; rc=$?
check "unconfirmed level reports 2" '[ $rc -eq 2 ]'

setup; load; rm -f "$NBL_SYSFS/brightness"
nbl_set_level 50; rc=$?
check "absent device: failed, no writes" '[ $rc -eq 2 ] && [ -z "$(writes)" ]'
check "status says unavailable" '[ "$(nbl_status_kv)" = "available=0" ]'

# --- sleep / wake --------------------------------------------------------------
setup; load
nbl_sleep; rc=$?
check "sleep refused without watcher (S98 watch fails)" '[ $rc -eq 4 ] && [ -z "$(writes)" ] && [ "$FK_POWER" = 0 ]'

setup; load
sh -c 'sleep 30' & WPID=$!
echo "$WPID" > "$NBL_WATCHER_PIDFILE"
nbl_set_level 50; : > "$T/c/log"
nbl_sleep; rc=$?
check "sleep with watcher: bl_power off, actual 0" '[ $rc -eq 0 ] && [ "$(writes)" = "bl_power=4" ] && [ "$(cat "$NBL_SYSFS/actual_brightness")" = 0 ]'
nbl_set_level 75; rc=$?
check "set while off: stored (3), stays off" '[ $rc -eq 3 ] && [ "$FK_BRIGHT" = 3 ] && [ "$(cat "$NBL_SYSFS/actual_brightness")" = 0 ]'
nbl_wake; rc=$?
check "wake restores the stored level" '[ $rc -eq 0 ] && [ "$(cat "$NBL_SYSFS/actual_brightness")" = 3 ]'
: > "$T/c/log"; nbl_wake
check "wake when on is a no-op" '[ -z "$(writes)" ]'
: > "$T/c/log"; FK_BRIGHT=0; FK_POWER=0; fake_sync; nbl_wake
check "wake from brightness 0 goes to full" '[ "$(cat "$NBL_SYSFS/actual_brightness")" = 4 ]'
kill "$WPID" 2>/dev/null

setup; load; FK_STUCK=1
sh -c 'sleep 30' & WPID=$!; echo "$WPID" > "$NBL_WATCHER_PIDFILE"
nbl_sleep; rc=$?
check "unconfirmed sleep reports 2" '[ $rc -eq 2 ]'
kill "$WPID" 2>/dev/null

# on-demand watcher start (no mount of any kind)
setup; load
mount() { echo "mount $*" >> "$T/c/log"; return 0; }
cat > "$NBL_S98" <<EOF
#!/bin/sh
[ "\$1" = watch ] || exit 1
sh -c 'sleep 30' >/dev/null 2>&1 &
echo \$! > "$NBL_WATCHER_PIDFILE"
EOF
chmod 755 "$NBL_S98"
nbl_sleep; rc=$?
check "sleep starts the watcher on demand" '[ $rc -eq 0 ] && nbl_watcher_running && [ "$FK_POWER" = 4 ]'
check "watcher start mounts nothing (no debugfs)" '! grep -q "^mount" "$T/c/log"'
unset -f mount
kill "$(cat "$NBL_WATCHER_PIDFILE")" 2>/dev/null

# --- boot restore ----------------------------------------------------------------
setup; load
nbl_boot_restore; rc=$?
check "no display.env: nothing written" '[ $rc -eq 0 ] && [ -z "$(writes)" ]'
printf 'BRIGHTNESS="100"\nTOUCH_WAKE="1"\n' > "$NBL_ENV"
nbl_boot_restore
check "100 persisted: nothing written" '[ -z "$(writes)" ]'
for junk in 'BRIGHTNESS="60"' 'BRIGHTNESS="50; reboot"' 'BRIGHTNESS=' 'garbage'; do
	printf '%s\n' "$junk" > "$NBL_ENV"
	nbl_boot_restore
	check "invalid persisted ($junk): nothing" '[ -z "$(writes)" ]'
done
printf 'BRIGHTNESS="25"\nTOUCH_WAKE="1"\n' > "$NBL_ENV"
nbl_boot_restore; rc=$?
check "25 persisted: applied" '[ $rc -eq 0 ] && [ "$(cat "$NBL_SYSFS/actual_brightness")" = 1 ]'
check "boot restore mounts nothing" '! grep -q mount "$T/c/log"'

# --- CLI ------------------------------------------------------------------------
setup; NBL_LIB="$LIB" sh "$CLI" bogus >/dev/null 2>&1; rc=$?
check "CLI usage exit 64" '[ $rc -eq 64 ]'
out=$(NBL_LIB="$LIB" sh "$CLI" status)
check "CLI status reports sysfs, level and selected" 'echo "$out" | grep -qx "interface=sysfs" && echo "$out" | grep -qx "level=100" && echo "$out" | grep -qx "asleep=0"'

# --- S98 / watcher ------------------------------------------------------------------
check "S98 has the watch verb" 'grep -q "^	watch)" "$S98"'
(
	NDQ_LIB=/nonexistent; NDQ_CONFIG_FILE="$T/none.conf"; NDQ_DISPLAY_ENV="$T/c/denv"
	ndq_get_field() { return 1; }
	. "$SWC"
	ndq_get_field() { return 1; }
	: > "$NDQ_DISPLAY_ENV"
	ndq_swc_touch_wake_allowed && exit 1
	echo 'TOUCH_WAKE="1"' > "$NDQ_DISPLAY_ENV"
	ndq_swc_touch_wake_allowed || exit 2
	echo 'TOUCH_WAKE="0"' > "$NDQ_DISPLAY_ENV"
	ndq_swc_touch_wake_allowed && exit 3
	exit 0
); rc=$?
check "watcher gate follows display.env TOUCH_WAKE (rc=$rc)" '[ $rc -eq 0 ]'
setup
(
	NDQ_LIB=/nonexistent; NDQ_BACKLIGHT_SYSFS="$NBL_SYSFS"
	. "$SWC"
	ndq_swc_backlight_is_asleep && exit 1
	echo 4 > "$NBL_SYSFS/bl_power"; echo 0 > "$NBL_SYSFS/actual_brightness"
	ndq_swc_backlight_is_asleep || exit 2
	ndq_swc_wake 2>/dev/null || exit 3
	[ "$(cat "$NBL_SYSFS/bl_power")" = 0 ] || exit 4
	exit 0
); rc=$?
check "watcher uses sysfs: asleep detection and wake via bl_power (rc=$rc)" '[ $rc -eq 0 ]'

# --- G5 gate: no overlay script mounts or reads debugfs ---------------------------
# Executable lines only (comments stripped): debugfs stays in the kernel for
# manual diagnostics, the image never mounts it and no service uses it.
_g5_hits=$(grep -rnE 'mount[[:space:]]+-t[[:space:]]+debugfs|/sys/kernel/debug' "$OVERLAY" 2>/dev/null \
	| grep -vE '^[^:]*:[0-9]+:[[:space:]]*#')
check "no overlay script mounts debugfs or uses /sys/kernel/debug: ${_g5_hits:-none}" '[ -z "$_g5_hits" ]'

echo "nebulaos-backlight-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
