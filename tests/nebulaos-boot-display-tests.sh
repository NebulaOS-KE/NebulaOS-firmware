#!/bin/sh
#
# Offline tests for nebulaos-boot-display, S01splash and the /usr/bin/sudo
# adapter (GUI/service readiness mission, 2026-10-09). Framebuffer and sysfs
# are files in a temp tree; nothing touches the host's display.
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
trap 'rm -rf "$T"' EXIT

STRIDE=40; YRES=6; FRAMES=3
setup() {
	rm -rf "$T/b"; mkdir -p "$T/b/boot/cache" "$T/b/sys"
	export NBD_BOOT_DIR="$T/b/boot" NBD_FB="$T/b/fb" NBD_FB_SYSFS="$T/b/sys" NBD_OSCONFIG="$T/b/none"
	echo "10,$((YRES * FRAMES))" > "$NBD_FB_SYSFS/virtual_size"
	echo 32 > "$NBD_FB_SYSFS/bits_per_pixel"
	echo "$STRIDE" > "$NBD_FB_SYSFS/stride"
	echo "0,$YRES" > "$NBD_FB_SYSFS/pan"
	echo "U:10x${YRES}p-60" > "$NBD_FB_SYSFS/mode"
	head -c $((STRIDE * YRES * FRAMES)) /dev/zero | tr '\0' 'K' > "$NBD_FB"
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

# --- console mode retired (D10, 2026-10-11) ---------------------------------------
setup; render; echo 'MODE="console"' > "$NBD_BOOT_DIR/display.env"; sh "$NBD" boot >/dev/null
check "saved console mode shows the logo" '[ "$(frame $YRES R)" -eq 0 ]'
check "no console, tty or fbcon code left" '! grep -q "tty\|fbcon\|vtcon\|KD_\|0x4B3A\|mirror" "$NBD"'
sh "$NBD" handoff >/dev/null 2>&1; rc=$?
check "handoff verb removed (usage 64)" '[ $rc -eq 64 ]'
sh "$NBD" bogus >/dev/null 2>&1; rc=$?
check "usage 64" '[ $rc -eq 64 ]'

# --- init wiring ------------------------------------------------------------------------
check "S01splash calls boot" 'grep -q "\"\$NBD\" boot" "$OVERLAY/etc/init.d/S01splash"'
check "S01splash sorts after S01persistent-datastore and before S01wifi" \
	'[ "$(printf "%s\n" S01persistent-datastore S01splash S01wifi S01seedrng S01syslogd | LC_ALL=C sort | tr "\n" " ")" = "S01persistent-datastore S01seedrng S01splash S01syslogd S01wifi " ]'
check "S58 no longer calls the boot display" '! grep -q "boot-display" "$OVERLAY/etc/init.d/S58guppyscreen"'

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
