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
PROC_ROOT="$WORK/proc"
SHED_MARKER="$WORK/shed-camera"
mkdir -p "$PROC_ROOT"
NOW=1000
settime() { NOW=$1; echo "$1.00 0.00" > "$PROC_ROOT/uptime"; }
settime 1000

uvc_node() { # name index driver [bus: usb|platform]
	d="$SYSFS_ROOT/class/video4linux/$1"
	if [ "${4:-usb}" = usb ]; then t="$WORK/devices/usb1/1-$1/1-$1:1.0"; else t="$WORK/devices/platform/$1"; fi
	mkdir -p "$d" "$t" "$WORK/drivers/$3"
	echo "$2" > "$d/index"
	ln -sfn "$t" "$d/device"
	ln -sfn "$WORK/drivers/$3" "$t/driver"
}
DISCOVER=0 STARTS=0 RUNNING=""
# runs inside $(...), so it counts through a file
discover_webcam() { echo x >> "$WORK/discover.calls"; [ -n "${DEV_PRESENT:-}" ] && echo "$DEV_PRESENT"; }
dcount() { DISCOVER=$(cat "$WORK/discover.calls" 2>/dev/null | wc -l); DISCOVER=$((DISCOVER + 0)); }
ustreamer_running_on() { [ -n "$RUNNING" ] && [ "$RUNNING" = "$1" ]; }
start_ustreamer() { STARTS=$((STARTS + 1)); RUNNING=$1; echo 4242 > "$USTREAMER_PIDFILE"; mkdir -p "$PROC_ROOT/4242"; }
stop_ustreamer() { RUNNING=""; rm -f "$USTREAMER_PIDFILE"; rm -rf "$PROC_ROOT/4242"; }
crash() { RUNNING=""; rm -rf "$PROC_ROOT/4242"; }   # process gone, pidfile left behind

# G121: the camera-settings apply is recorded, never run
OSCONFIG="$WORK/osconfig"
printf '#!/bin/sh\necho "$*" >> %s/apply.calls\n' "$WORK" > "$OSCONFIG"; chmod +x "$OSCONFIG"
applies() { n=$(cat "$WORK/apply.calls" 2>/dev/null | wc -l); echo $((n + 0)); }
usbid() { echo "$2" > "$WORK/devices/usb1/1-$1/busnum"; echo "$3" > "$WORK/devices/usb1/1-$1/devnum"; }

uvc_node video0 0 uvcvideo
uvc_node video1 1 uvcvideo
uvc_node video8 0 gspca_zc3xx
uvc_node video9 0 ingenic-rot platform

usb_capture_node /dev/video0 && pass "index-0 uvcvideo node is present" || fail "video0 not detected"
usb_capture_node /dev/video1 && fail "metadata node (index 1) accepted" || pass "metadata node (index 1) rejected"
usb_capture_node /dev/video8 && pass "non-UVC USB webcam (gspca) accepted" || fail "gspca webcam rejected"
usb_capture_node /dev/video9 && fail "SoC (non-USB) node accepted" || pass "SoC (non-USB) node rejected"
usb_capture_node /dev/video7 && fail "absent node accepted" || pass "absent node rejected"

# --- any webcam: the stream format from what the camera offers ---
REAL_V4L2CTL=$V4L2CTL
V4L2CTL="$WORK/v4l2-ctl"
printf '#!/bin/sh\nprintf "%%s\\n" "$FAKE_FORMATS"\n' > "$V4L2CTL"; chmod +x "$V4L2CTL"
fmt_of() { FAKE_FORMATS="$1" webcam_format /dev/video0 || echo none; }
expect "MJPEG camera (Nebula Camera)" "$(fmt_of "[0]: 'YUYV' (YUYV 4:2:2)
[1]: 'MJPG' (Motion-JPEG, compressed)")" MJPEG
expect "JPEG-only camera (gspca zc3xx)" "$(fmt_of "[0]: 'JPEG' (JFIF JPEG, compressed)")" JPEG
expect "raw-only camera" "$(fmt_of "[0]: 'YUYV' (YUYV 4:2:2)")" YUYV
expect "YUV 4:2:0 camera" "$(fmt_of "[0]: 'YU12' (Planar YUV 4:2:0)")" YUV420
expect "no streamable format" "$(fmt_of "[0]: 'BA81' (8-bit Bayer BGBG/GRGR)")" none
V4L2CTL=$REAL_V4L2CTL

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

# --- MEM-T15: memory shed marker ---------------------------------------------
: > "$SHED_MARKER"
supervise_tick
expect "shed marker stops ustreamer" "${RUNNING:-none}" none
S0=$STARTS
supervise_tick; supervise_tick
expect "nothing starts while the marker exists" "$STARTS" "$S0"
rm -f "$SHED_MARKER"
supervise_tick
expect "marker removed: ustreamer back on the next tick" "$RUNNING" /dev/video2

# --- MEM-T15: crash-loop backoff 10, 20, 40 ... 300 ----------------------------
backoff=0 hold_until=0
seq=""
t=2000
settime $t; stop_ustreamer; started_at=; supervise_tick     # fresh start at t
for i in 1 2 3 4 5 6 7; do
	t=$((t + 5)); settime $t; crash; supervise_tick          # dies 5 s after start
	seq="$seq $backoff"
	S0=$STARTS
	settime $((t + backoff - 1)); supervise_tick
	[ "$STARTS" = "$S0" ] || fail "restarted before the backoff expired (step $i)"
	t=$((t + backoff)); settime $t; supervise_tick           # restart once it expires
	[ "$STARTS" -gt "$S0" ] || fail "no restart after the backoff (step $i)"
done
expect "backoff sequence" "$seq" " 10 20 40 80 160 300 300"
t=$((t + 300)); settime $t; supervise_tick
expect "300 s of continuous running resets the backoff" "$backoff" 0
t=$((t + 120)); settime $t; crash; supervise_tick
expect "a crash after the window does not back off" "$backoff" 0

# --- G121: saved camera settings applied once per USB device ---
applied_id=; RUNNING=""; rm -f "$USTREAMER_PIDFILE" "$WORK/apply.calls"; hold_until=0; started_at=
uvc_node video5 0 uvcvideo
usbid video5 1 7
DEV_PRESENT=/dev/video5; last_dev=
supervise_tick
sleep 0.2
expect "start applies the saved camera settings once" "$(applies)" 1
supervise_tick; supervise_tick
sleep 0.2
expect "same USB device: no second apply" "$(applies)" 1
usbid video5 1 8                                   # camera reset / re-enumerated, same /dev name
supervise_tick
sleep 0.2
expect "same node, new USB device: applied again" "$(applies)" 2
grep -q -- "camera apply --device /dev/video5" "$WORK/apply.calls" \
	&& pass "apply names the device" || fail "apply args: $(cat "$WORK/apply.calls")"

echo "webcam-supervisor-discovery-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
