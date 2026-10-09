#!/bin/sh
#
# Offline tests for /etc/nebulaos-backlight.sh, the /usr/libexec/nebulaos/
# nebulaos-backlight CLI and the S98 GUI-sleep additions (GUI/service
# readiness mission, 2026-10-09).
#
# HONESTY NOTE: the kernel controller is a FAKE here - a few lines of shell
# that follow the transition rules read from nebulaos_backlight_final_
# controller.c (enter-safe-on from any state; pwm-active-N only from safe-on;
# commit-pwm only from pwm-active; sleep only from safe-on/pwm-committed;
# wake only from asleep, back to the saved target). What is proven is this
# library's sequencing and its "any failure: do nothing further" rule, not the
# real driver.
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

# Fake controller: state file -> status file, commands via nbl_kwrite.
setup() {
	rm -rf "$T/c"; mkdir -p "$T/c/dbg/nebulaos_backlight_final"
	export NBL_DEBUGFS="$T/c/dbg"
	export NBL_DIR="$NBL_DEBUGFS/nebulaos_backlight_final"
	export NBL_CMD="$NBL_DIR/command" NBL_STATUS="$NBL_DIR/status"
	export NBL_ENV="$T/c/display.env"
	export NBL_WATCHER_PIDFILE="$T/c/watcher.pid"
	export NBL_S98="$T/c/s98"
	export NBL_WATCHER_START_TENTHS=3
	echo " $NBL_DEBUGFS debugfs rw 0 0" > "$T/c/mounts"
	export NBL_PROC_MOUNTS="$T/c/mounts"
	: > "$NBL_CMD"; : > "$T/c/log"
	FAKE_STATE=${1:-boot-preserve}; FAKE_DUTY=0; FAKE_TARGET=n/a; FAKE_BROKEN=""
	fake_status
	printf '#!/bin/sh\nexit 1\n' > "$NBL_S98"; chmod 755 "$NBL_S98"
}

fake_status() {
	_v=0; [ "$FAKE_STATE" = safe-on ] && _v=1
	_a=0; [ "$FAKE_STATE" = asleep ] && _a=1
	{
		echo "state: $FAKE_STATE"
		echo "pwm_duty_pct: $FAKE_DUTY"
		echo "asleep: $_a"
		echo "wake_target: $FAKE_TARGET"
		echo "safe_on_verified: $_v"
		echo "op_failure_count: 0"
		echo "wake_failure_count: 0"
	} > "$NBL_STATUS"
}

fake_kwrite() {
	echo "$1" >> "$T/c/log"
	case "$FAKE_BROKEN" in *" $1 "*) return 1 ;; esac
	case "$1" in
		enter-safe-on) FAKE_STATE=safe-on; FAKE_DUTY=0 ;;
		pwm-active-25|pwm-active-50|pwm-active-75)
			[ "$FAKE_STATE" = safe-on ] || return 1
			FAKE_STATE=pwm-active; FAKE_DUTY=${1#pwm-active-} ;;
		commit-pwm) [ "$FAKE_STATE" = pwm-active ] || return 1; FAKE_STATE=pwm-committed ;;
		sleep)
			case "$FAKE_STATE" in
				safe-on) FAKE_TARGET=safe-on ;;
				pwm-committed) FAKE_TARGET="pwm-committed-$FAKE_DUTY" ;;
				*) return 1 ;;
			esac
			FAKE_STATE=asleep ;;
		wake)
			[ "$FAKE_STATE" = asleep ] || return 1
			case "$FAKE_TARGET" in
				safe-on) FAKE_STATE=safe-on ;;
				*) FAKE_STATE=pwm-committed; FAKE_DUTY=${FAKE_TARGET#pwm-committed-} ;;
			esac ;;
		*) return 1 ;;
	esac
	fake_status
	return 0
}

load() {
	. "$LIB"
	nbl_kwrite() { fake_kwrite "$1"; }
	sleep() { :; }
}

cmds() { tr '\n' ' ' < "$T/c/log" | sed 's/ $//'; }

# --- set level ---------------------------------------------------------------
setup; load
nbl_set_level 50; rc=$?
check "set 50 from boot-preserve succeeds" '[ $rc -eq 0 ]'
check "set 50 sequence" '[ "$(cmds)" = "enter-safe-on pwm-active-50 commit-pwm" ]'
check "state pwm-committed 50" '[ "$FAKE_STATE" = pwm-committed ] && [ "$FAKE_DUTY" = 50 ]'
: > "$T/c/log"; nbl_set_level 50
check "same level again is a no-op" '[ -z "$(cmds)" ]'
nbl_set_level 25
check "level change passes through safe-on" '[ "$(cmds)" = "enter-safe-on pwm-active-25 commit-pwm" ] && [ "$FAKE_DUTY" = 25 ]'
: > "$T/c/log"; nbl_set_level 100
check "100 is safe-on only" '[ "$(cmds)" = "enter-safe-on" ] && [ "$FAKE_STATE" = safe-on ]'
for bad in 0 30 101 abc "" "50 x" "-1"; do
	: > "$T/c/log"; nbl_set_level "$bad"; rc=$?
	check "invalid level '$bad' rejected, nothing written" '[ $rc -eq 1 ] && [ -z "$(cmds)" ]'
done

# commit failure: no further commands; controller (fake) left in bounded test
setup safe-on; load; FAKE_BROKEN=" commit-pwm "
nbl_set_level 75; rc=$?
check "commit failure reports 2" '[ $rc -eq 2 ]'
check "commit failure: nothing after the failing command" '[ "$(cmds)" = "enter-safe-on pwm-active-75 commit-pwm" ]'

# safe-on not confirmed: stop before any PWM command
setup; load
nbl_kwrite() { echo "$1" >> "$T/c/log"; return 0; }   # accepted, status never changes
nbl_set_level 50; rc=$?
check "unconfirmed safe-on stops" '[ $rc -eq 2 ] && [ "$(cmds)" = "enter-safe-on" ]'

# controller absent: nothing done
setup; load; rm -f "$NBL_CMD" "$NBL_STATUS"
nbl_set_level 50; rc=$?
check "absent controller: failed, no commands" '[ $rc -eq 2 ] && [ -z "$(cmds)" ]'
check "status says unavailable" '[ "$(nbl_status_kv)" = "available=0" ]'

# --- sleep / wake --------------------------------------------------------------
setup safe-on; load
nbl_sleep; rc=$?
check "sleep refused without watcher (S98 watch fails)" '[ $rc -eq 4 ] && [ -z "$(cmds)" ] && [ "$FAKE_STATE" = safe-on ]'

setup safe-on; load
sh -c 'sleep 30' & WPID=$!
echo "$WPID" > "$NBL_WATCHER_PIDFILE"
nbl_set_level 50; : > "$T/c/log"
nbl_sleep; rc=$?
check "sleep with watcher" '[ $rc -eq 0 ] && [ "$FAKE_STATE" = asleep ] && [ "$(cmds)" = sleep ]'
nbl_set_level 75; rc=$?
check "set while asleep: 3, nothing written" '[ $rc -eq 3 ] && [ "$(cmds)" = sleep ]'
nbl_wake; rc=$?
check "wake restores pwm target" '[ $rc -eq 0 ] && [ "$FAKE_STATE" = pwm-committed ] && [ "$FAKE_DUTY" = 50 ]'
: > "$T/c/log"; nbl_wake
check "wake when awake is a no-op" '[ -z "$(cmds)" ]'
setup boot-preserve; load; echo "$WPID" > "$NBL_WATCHER_PIDFILE"
nbl_sleep
check "sleep from boot-preserve goes through safe-on" '[ "$(cmds)" = "enter-safe-on sleep" ] && [ "$FAKE_STATE" = asleep ]'
kill "$WPID" 2>/dev/null

# on-demand watcher start
setup safe-on; load
cat > "$NBL_S98" <<EOF
#!/bin/sh
[ "\$1" = watch ] || exit 1
sh -c 'sleep 30' >/dev/null 2>&1 &
echo \$! > "$NBL_WATCHER_PIDFILE"
EOF
chmod 755 "$NBL_S98"
nbl_sleep; rc=$?
check "sleep starts the watcher on demand" '[ $rc -eq 0 ] && nbl_watcher_running && [ "$FAKE_STATE" = asleep ]'
kill "$(cat "$NBL_WATCHER_PIDFILE")" 2>/dev/null

# --- boot restore ----------------------------------------------------------------
setup; load
nbl_boot_restore; rc=$?
check "no display.env: nothing at all" '[ $rc -eq 0 ] && [ -z "$(cmds)" ] && [ "$FAKE_STATE" = boot-preserve ]'
printf 'BRIGHTNESS="100"\nTOUCH_WAKE="1"\n' > "$NBL_ENV"
nbl_boot_restore
check "100 persisted: nothing at all" '[ -z "$(cmds)" ] && [ "$FAKE_STATE" = boot-preserve ]'
for junk in 'BRIGHTNESS="60"' 'BRIGHTNESS="50; reboot"' 'BRIGHTNESS=' 'garbage'; do
	printf '%s\n' "$junk" > "$NBL_ENV"
	nbl_boot_restore
	check "invalid persisted ($junk): nothing" '[ -z "$(cmds)" ] && [ "$FAKE_STATE" = boot-preserve ]'
done
printf 'BRIGHTNESS="25"\nTOUCH_WAKE="1"\n' > "$NBL_ENV"
nbl_boot_restore; rc=$?
check "25 persisted: applied" '[ $rc -eq 0 ] && [ "$FAKE_STATE" = pwm-committed ] && [ "$FAKE_DUTY" = 25 ]'

# debugfs mount attempt only when not mounted (mount itself is not exercised)
setup; load; : > "$NBL_PROC_MOUNTS"
mount() { echo "mount $*" >> "$T/c/log"; return 0; }
nbl_ensure_debugfs
check "mounts debugfs root-only when absent" 'grep -q "mount -t debugfs -o mode=0700,nosuid,nodev,noexec debugfs $NBL_DEBUGFS" "$T/c/log"'
: > "$T/c/log"; nbl_boot_restore
check "boot restore mounts debugfs even with nothing persisted, no controller command" '[ "$(cmds)" = "mount -t debugfs -o mode=0700,nosuid,nodev,noexec debugfs $NBL_DEBUGFS" ]'
echo " $NBL_DEBUGFS debugfs rw 0 0" > "$NBL_PROC_MOUNTS"; : > "$T/c/log"; nbl_ensure_debugfs
check "already mounted: no mount" '[ -z "$(cmds)" ]'
unset -f mount

# --- CLI ------------------------------------------------------------------------
setup; out=$(NBL_LIB="$LIB" sh "$CLI" bogus 2>/dev/null); rc=$?
check "CLI usage exit 64" '[ $rc -eq 64 ]'
out=$(NBL_LIB="$LIB" sh "$CLI" status)
check "CLI status reports state" 'echo "$out" | grep -qx "state=boot-preserve" && echo "$out" | grep -qx "level=100"'

# --- S98 / watcher gate -----------------------------------------------------------
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

echo "nebulaos-backlight-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
