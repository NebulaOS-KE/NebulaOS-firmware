#!/bin/sh
#
# CAM-01: S50webcam's supervisor must not re-open the video node every poll
# while ustreamer is serving it (that resumes the camera and defeats USB
# autosuspend). Sources S50webcam through S50WEBCAM_NO_AUTORUN with a fake
# sysfs tree and stubs for discovery (the only path that opens /dev/video*)
# and for the ustreamer start/stop/running checks.
#
# Usage: sh tests/webcam-supervisor-discovery-tests.sh

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
TARGET="$REPO_ROOT/scripts/build/overlay/etc/init.d/S50webcam"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/webcam-discovery-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM
PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
expect() { [ "$2" = "$3" ] && pass "$1" || fail "$1 (got '$2', want '$3')"; }

S50WEBCAM_NO_AUTORUN=1
NEBULAOS_OOM_POLICY="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-oom-policy.sh"
# shellcheck disable=SC1090
. "$TARGET"
SYSFS_ROOT="$WORK/sys"
USTREAMER_PIDFILE="$WORK/ustreamer.pid"

uvc_node() { # name index driver
	d="$SYSFS_ROOT/class/video4linux/$1"
	mkdir -p "$d/device" "$WORK/drivers/$3"
	echo "$2" > "$d/index"
	ln -sfn "$WORK/drivers/$3" "$d/device/driver"
}
DISCOVER=0 STARTS=0 RUNNING=""
# runs inside $(...), so it counts through a file
discover_uvc_device() { echo x >> "$WORK/discover.calls"; [ -n "${DEV_PRESENT:-}" ] && echo "$DEV_PRESENT"; }
dcount() { DISCOVER=$(cat "$WORK/discover.calls" 2>/dev/null | wc -l); DISCOVER=$((DISCOVER + 0)); }
ustreamer_running_on() { [ -n "$RUNNING" ] && [ "$RUNNING" = "$1" ]; }
start_ustreamer() { STARTS=$((STARTS + 1)); RUNNING=$1; : > "$USTREAMER_PIDFILE"; }
stop_ustreamer() { RUNNING=""; rm -f "$USTREAMER_PIDFILE"; }

uvc_node video0 0 uvcvideo
uvc_node video1 1 uvcvideo
uvc_node video9 0 other

uvc_node_still_present /dev/video0 && pass "index-0 uvcvideo node is present" || fail "video0 not detected"
uvc_node_still_present /dev/video1 && fail "metadata node (index 1) accepted" || pass "metadata node (index 1) rejected"
uvc_node_still_present /dev/video9 && fail "non-uvc driver accepted" || pass "non-uvc driver rejected"
uvc_node_still_present /dev/video7 && fail "absent node accepted" || pass "absent node rejected"

last_dev=
DEV_PRESENT=/dev/video0
supervise_tick
dcount; expect "first tick discovers" "$DISCOVER" 1
expect "first tick starts ustreamer" "$STARTS" 1
supervise_tick; supervise_tick; supervise_tick
dcount; expect "no discovery (no device open) over 3 ticks while running" "$DISCOVER" 1
expect "no restart while running" "$STARTS" 1

# the node vanishes (unplug): discovery runs again, ustreamer is stopped
rm -rf "$SYSFS_ROOT/class/video4linux/video0"
DEV_PRESENT=""
supervise_tick
dcount; expect "vanished node triggers discovery" "$DISCOVER" 2
expect "ustreamer stopped when no device" "${RUNNING:-none}" none
# replug, renumbered
uvc_node video2 0 uvcvideo
DEV_PRESENT=/dev/video2
supervise_tick
expect "renumbered node restarts ustreamer" "$RUNNING" /dev/video2
supervise_tick
dcount; expect "steady again: no further discovery" "$DISCOVER" 3

echo "webcam-supervisor-discovery-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
