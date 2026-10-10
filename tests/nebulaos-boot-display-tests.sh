#!/bin/sh
#
# Offline tests for nebulaos-boot-display, S01splash, the S58 handoff and the
# /usr/bin/sudo adapter (GUI/service readiness mission, 2026-10-09).
# Framebuffer, sysfs, vtconsole and tty are files in a temp tree; nothing
# touches the host's display.
#
# Usage: sh tests/nebulaos-boot-display-tests.sh

set -u
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY="$REPO_ROOT/scripts/build/overlay"
NBD="$OVERLAY/usr/libexec/nebulaos/nebulaos-boot-display"
SUDO="$OVERLAY/usr/bin/sudo"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
check() { if eval "$2"; then pass; else fail "$1"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/nbd-tests.XXXXXX") || exit 1
trap 'kill $(cat "$T"/pids 2>/dev/null) 2>/dev/null; rm -rf "$T"' EXIT

STRIDE=40; YRES=6; FRAMES=3
setup() {
	rm -rf "$T/b"; mkdir -p "$T/b/boot/cache" "$T/b/sys" "$T/b/vt/vtcon0" "$T/b/vt/vtcon1" "$T/b/run"
	export NBD_BOOT_DIR="$T/b/boot" NBD_FB="$T/b/fb" NBD_FB_SYSFS="$T/b/sys"
	export NBD_VTCON="$T/b/vt" NBD_TTY="$T/b/tty" NBD_RUN="$T/b/run" NBD_BOOTLOG="$T/b/bootlog"
	export NBD_FBCON_SYSFS="$T/b/fbcon" NBD_OSCONFIG="$T/b/none" NBD_MIRROR_SECONDS=30
	echo "10,$((YRES * FRAMES))" > "$NBD_FB_SYSFS/virtual_size"
	echo 32 > "$NBD_FB_SYSFS/bits_per_pixel"
	echo "$STRIDE" > "$NBD_FB_SYSFS/stride"
	echo "0,$YRES" > "$NBD_FB_SYSFS/pan"
	echo "U:10x${YRES}p-60" > "$NBD_FB_SYSFS/mode"
	head -c $((STRIDE * YRES * FRAMES)) /dev/zero | tr '\0' 'K' > "$NBD_FB"
	echo "dummy device" > "$T/b/vt/vtcon0/name"; echo 1 > "$T/b/vt/vtcon0/bind"
	echo "(M) frame buffer device" > "$T/b/vt/vtcon1/name"; echo 1 > "$T/b/vt/vtcon1/bind"
}

render() {   # a fake rendered image of 'R' bytes
	head -c $((STRIDE * YRES)) /dev/zero | tr '\0' 'R' > "$NBD_BOOT_DIR/cache/splash.raw"
	cat > "$NBD_BOOT_DIR/cache/splash.meta" <<-EOF
	BPP="32"
	KIND="custom"
	SIZE="$((STRIDE * YRES))"
	STRIDE="$STRIDE"
	XRES="10"
	YRES="$YRES"
	EOF
}

frame() { dd if="$NBD_FB" bs="$STRIDE" skip="$1" count="$YRES" 2>/dev/null | tr -d "$2" | wc -c; }

# --- logo -----------------------------------------------------------------------
setup; render
sh "$NBD" boot >/dev/null
check "logo drawn into the displayed frame (pan y=$YRES)" '[ "$(frame $YRES R)" -eq 0 ]'
check "other frames untouched" '[ "$(frame 0 K)" -eq 0 ] && [ "$(frame $((YRES * 2)) K)" -eq 0 ]'
check "fb size unchanged" '[ "$(wc -c < "$NBD_FB")" -eq $((STRIDE * YRES * FRAMES)) ]'

setup; sh "$NBD" boot >/dev/null
check "no render yet: nothing drawn" '[ "$(frame $YRES K)" -eq 0 ]'

setup; render; echo 16 > "$NBD_FB_SYSFS/bits_per_pixel"; sh "$NBD" boot >/dev/null
check "bpp mismatch: nothing drawn" '[ "$(frame $YRES K)" -eq 0 ]'
setup; render; echo 44 > "$NBD_FB_SYSFS/stride"; sh "$NBD" boot >/dev/null
check "stride mismatch: nothing drawn" '[ "$(frame $YRES K)" -eq 0 ]'
setup; render; echo X >> "$NBD_BOOT_DIR/cache/splash.raw"; sh "$NBD" boot >/dev/null
check "size mismatch: nothing drawn" '[ "$(frame $YRES K)" -eq 0 ]'
setup; render; sed -i 's/^YRES=.*/YRES="6;reboot"/' "$NBD_BOOT_DIR/cache/splash.meta"; sh "$NBD" boot >/dev/null
check "malformed meta: nothing drawn" '[ "$(frame $YRES K)" -eq 0 ]'
setup; render; echo "garbage" > "$NBD_FB_SYSFS/pan"; sh "$NBD" boot >/dev/null
check "unreadable pan: nothing drawn" '[ "$(cat "$NBD_FB" | tr -d K | wc -c)" -eq 0 ]'

# --- mode selection --------------------------------------------------------------
setup; render; : > "$NBD_FB_SYSFS/mode"; echo 'MODE="blank"' > "$NBD_BOOT_DIR/display.env"; sh "$NBD" boot >/dev/null
check "blank clears the displayed frame with an empty sysfs mode (KE)" '[ "$(frame $YRES "\000")" -eq 0 ]'
check "blank clears every buffer" '[ "$(cat "$NBD_FB" | tr -d "\000" | wc -c)" -eq 0 ]'
check "blank keeps the fb size" '[ "$(wc -c < "$NBD_FB")" -eq $((STRIDE * YRES * FRAMES)) ]'
setup; echo "garbage" > "$NBD_FB_SYSFS/virtual_size"; echo 'MODE="blank"' > "$NBD_BOOT_DIR/display.env"; sh "$NBD" boot >/dev/null
check "blank with unreadable geometry: nothing written" '[ "$(cat "$NBD_FB" | tr -d K | wc -c)" -eq 0 ]'
setup; render; echo 'MODE="$(reboot)"' > "$NBD_BOOT_DIR/display.env"; sh "$NBD" boot >/dev/null
check "invalid mode falls back to logo" '[ "$(frame $YRES R)" -eq 0 ]'

setup; echo 'MODE="console"' > "$NBD_BOOT_DIR/display.env"
sh "$NBD" boot >/dev/null
check "console without a tty: nothing, no failure" '[ "$(frame $YRES K)" -eq 0 ]'

# console with a fake tty: a FIFO-free stand-in (regular file) is not a char
# device, so emulate by pointing NBD_TTY at /dev/null-like char device check.
if [ -c /dev/null ]; then
	setup; echo 'MODE="console"' > "$NBD_BOOT_DIR/display.env"
	mkdir -p "$NBD_FBCON_SYSFS"; : > "$NBD_FBCON_SYSFS/rotate_all"
	echo "T=1 EV=begin" > "$NBD_BOOTLOG"
	NBD_TTY=/dev/null sh "$NBD" boot >/dev/null
	check "console: rotation requested" '[ "$(cat "$NBD_FBCON_SYSFS/rotate_all")" = 2 ]'
	check "console: mirror pid recorded" '[ -s "$NBD_RUN/mirror.pid" ] && kill -0 "$(cat "$NBD_RUN/mirror.pid")"'
	cat "$NBD_RUN/mirror.pid" >> "$T/pids"
	sh "$NBD" handoff >/dev/null
	check "handoff stops the mirror" '[ ! -e "$NBD_RUN/mirror.pid" ]'
fi

# --- handoff -------------------------------------------------------------------------
setup; sh "$NBD" handoff >/dev/null
check "handoff unbinds fbcon only" '[ "$(cat "$T/b/vt/vtcon1/bind")" = 0 ] && [ "$(cat "$T/b/vt/vtcon0/bind")" = 1 ]'
rm -rf "$T/b/vt"; sh "$NBD" handoff >/dev/null; rc=$?
check "handoff without vtconsole is fine" '[ $rc -eq 0 ]'
sh "$NBD" bogus >/dev/null 2>&1; rc=$?
check "usage 64" '[ $rc -eq 64 ]'

# --- init wiring ------------------------------------------------------------------------
check "S01splash calls boot" 'grep -q "\"\$NBD\" boot" "$OVERLAY/etc/init.d/S01splash"'
check "S01splash sorts after S01persistent-datastore and before S01wifi" \
	'[ "$(printf "%s\n" S01persistent-datastore S01splash S01wifi S01seedrng S01syslogd | LC_ALL=C sort | tr "\n" " ")" = "S01persistent-datastore S01seedrng S01splash S01syslogd S01wifi " ]'
check "S58 hands off before starting GuppyScreen" \
	'awk "/^start\\(\\)/{s=1} s&&/handoff/{h=NR} s&&/start-stop-daemon -S/{print (h&&h<NR)?\"ok\":\"bad\"; exit}" "$OVERLAY/etc/init.d/S58guppyscreen" | grep -qx ok'

# --- sudo adapter ------------------------------------------------------------------------
mkdir -p "$T/s/sbin" "$T/s/bin"
for a in reboot poweroff halt; do printf '#!/bin/sh\necho RAN-%s "$@"\n' "$a" > "$T/s/sbin/$a"; chmod 755 "$T/s/sbin/$a"; done
sed "s#/sbin/\$1#$T/s/sbin/\$1#" "$SUDO" > "$T/s/sudo"
printf '#!/bin/sh\necho 0\n' > "$T/s/bin/id"; chmod 755 "$T/s/bin/id"
printf '#!/bin/sh\nexit 0\n' > "$T/s/bin/logger"; chmod 755 "$T/s/bin/logger"
run_sudo() { PATH="$T/s/bin:$PATH" sh "$T/s/sudo" "$@" 2>/dev/null; }
check "sudo reboot execs reboot" '[ "$(run_sudo reboot)" = RAN-reboot ]'
check "sudo -n poweroff" '[ "$(run_sudo -n poweroff)" = RAN-poweroff ]'
check "sudo halt" '[ "$(run_sudo halt)" = RAN-halt ]'
for bad in "ls /root" "systemctl --version" "reboot now" "-S reboot" "sh -c reboot" "/sbin/reboot" ""; do
	# shellcheck disable=SC2086
	out=$(run_sudo $bad); rc=$?
	check "sudo refuses '$bad'" '[ $rc -eq 1 ] && [ -z "$out" ]'
done
printf '#!/bin/sh\necho 1000\n' > "$T/s/bin/id"
check "sudo refuses non-root callers" '! run_sudo reboot >/dev/null'
check "sudo adapter is not setuid in git" '[ "$(git -C "$REPO_ROOT" ls-files -s scripts/build/overlay/usr/bin/sudo | cut -c1-6)" != 104755 ]'

echo "nebulaos-boot-display-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
