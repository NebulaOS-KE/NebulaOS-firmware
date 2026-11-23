#!/bin/sh
#
# Offline tests for #27 test build 5: S06nebulaos-freeze-switches applies
# /usr/data/nebulaos/system/freeze-switches to the kernel switches at boot.
# Runs against a fake /sys tree.
#
# Usage: sh tests/freeze-switches-tests.sh

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
S06="$REPO_ROOT/scripts/build/overlay/etc/init.d/S06nebulaos-freeze-switches"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/freeze-switches-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
expect() { [ "$2" = "$3" ] && pass "$1" || fail "$1 (got '$2', want '$3')"; }

fake_sys() { # kernel defaults, as test build 5 boots
	rm -rf "$WORK/sys"
	P="$WORK/sys/module/nebulaos_freeze/parameters"
	mkdir -p "$P" "$WORK/sys/module/ingenic_fb_stage/parameters" "$WORK/sys/devices/system/cpu/cpu1"
	echo Y > "$P/l2_pre_iob"
	echo "1 (MSCR=0x00000000)" > "$P/l2_prefetch"
	echo 0 > "$P/idle_poll"
	echo 1200 > "$P/cpu_mhz"
	echo 1 > "$P/blackbox"
	echo 1 > "$WORK/sys/module/ingenic_fb_stage/parameters/fb_cca"
	echo 1 > "$WORK/sys/devices/system/cpu/cpu1/online"
}

run() { # settings-content|-
	if [ "$1" = - ]; then rm -f "$WORK/settings"; else printf '%s\n' "$1" > "$WORK/settings"; fi
	FZ_SETTINGS="$WORK/settings" FZ_STATE="$WORK/run/state" FZ_SYS="$WORK/sys" \
		FZ_KMSG="$WORK/kmsg" sh "$S06" start > "$WORK/out"
}
state() { sed -n "s/^$1=\([^ ]*\) .*/\1/p" "$WORK/run/state"; }
res() { sed -n "s/^$1=[^ ]* requested=[^ ]* \(.*\)/\1/p" "$WORK/run/state"; }

sh -n "$S06" && pass "S06 parses" || fail "S06 does not parse"
[ -x "$S06" ] && pass "S06 is executable" || fail "S06 is not executable"

fake_sys
run -
expect "no settings: CPU1 stays on" "$(cat "$WORK/sys/devices/system/cpu/cpu1/online")" 1
expect "no settings: threads=2 in state" "$(state threads)" 2
expect "no settings: nothing written (default)" "$(res cpu_mhz)" default
expect "no settings: l2_pre_iob read back as 1" "$(state l2_pre_iob)" 1
expect "no settings: kernel log line" "$(cat "$WORK/kmsg")" \
	"nebulaos-freeze-switches: threads=2 l2_pre_iob=1 l2_prefetch=1 idle_poll=0 cpu_mhz=1200 fb_cca=1 blackbox=1"

fake_sys
run "threads=1"
expect "threads=1 takes CPU1 offline" "$(cat "$WORK/sys/devices/system/cpu/cpu1/online")" 0
expect "threads=1 in state" "$(state threads)" 1
expect "threads=1 result ok" "$(res threads)" ok

fake_sys
run "$(printf '# test\ncpu_mhz = 750\nl2_prefetch=0   # off\nfb_cca=0\nidle_poll=1\nblackbox=0\nl2_pre_iob=0')"
expect "cpu_mhz=750 written" "$(cat "$WORK/sys/module/nebulaos_freeze/parameters/cpu_mhz")" 750
expect "l2_prefetch=0 written (comment ignored)" "$(cat "$WORK/sys/module/nebulaos_freeze/parameters/l2_prefetch")" 0
expect "fb_cca=0 written" "$(cat "$WORK/sys/module/ingenic_fb_stage/parameters/fb_cca")" 0
expect "idle_poll=1 written" "$(cat "$WORK/sys/module/nebulaos_freeze/parameters/idle_poll")" 1
expect "blackbox=0 written" "$(cat "$WORK/sys/module/nebulaos_freeze/parameters/blackbox")" 0
expect "l2_pre_iob=0 written" "$(cat "$WORK/sys/module/nebulaos_freeze/parameters/l2_pre_iob")" 0
expect "l2_pre_iob=0 read back" "$(state l2_pre_iob)" 0

fake_sys
run "$(printf 'cpu_mhz=900\nthreads=3\nfb_cca=7\nbanana=1\nidle_poll=yes')"
expect "bad cpu_mhz -> default, nothing written" "$(res cpu_mhz)" default
expect "bad threads -> CPU1 stays on" "$(cat "$WORK/sys/devices/system/cpu/cpu1/online")" 1
expect "bad fb_cca -> default" "$(state fb_cca)" 1
expect "bad idle_poll -> default" "$(state idle_poll)" 0

fake_sys
run "$(printf 'cpu_mhz=750\ncpu_mhz=1200')"
expect "the last line wins" "$(res cpu_mhz)" default

fake_sys
rm -rf "$WORK/sys/module/nebulaos_freeze"
run "cpu_mhz=750"
expect "kernel without the switches: error, boot goes on" "$(res cpu_mhz)" error
grep -q 'cpu_mhz=?(error)' "$WORK/kmsg" && pass "error shown in the kernel log" || fail "no error in the kernel log: $(cat "$WORK/kmsg")"

fake_sys
echo 0 > "$WORK/sys/devices/system/cpu/cpu1/online"
echo 750 > "$WORK/sys/module/nebulaos_freeze/parameters/cpu_mhz"
printf 'threads=2\ncpu_mhz=1200\n' > "$WORK/settings"
FZ_SETTINGS="$WORK/settings" FZ_STATE="$WORK/run/state" FZ_SYS="$WORK/sys" \
	FZ_KMSG="$WORK/kmsg" sh "$S06" apply > /dev/null
expect "apply brings CPU1 back" "$(cat "$WORK/sys/devices/system/cpu/cpu1/online")" 1
expect "apply writes defaults too (cpu back to 1200)" "$(cat "$WORK/sys/module/nebulaos_freeze/parameters/cpu_mhz")" 1200
expect "apply result ok" "$(res cpu_mhz)" ok

echo
echo "freeze-switches: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
