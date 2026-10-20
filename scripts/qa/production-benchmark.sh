#!/bin/sh
# NebulaOS production optimization mission, Phase 2 (2026-07-30).
# Extended pre-qualification mission Phase A9 (2026-07-31) with Wi-Fi,
# camera, boot-timing, and provenance metrics, plus the combined-variant
# result directory layout the later camera/Wi-Fi/RT A/B testing needs -
# see docs/NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md sec 15/18.18 for
# what each new section measures and why.
#
# Captures one consistent, repeatable resource-usage snapshot of the real
# running device, meant to be scp'd over and run directly ON the printer
# (BusyBox ash, not bash - no bashisms). Not part of the production
# rootfs overlay - this is a developer/QA tool for A/B-comparing
# optimization candidates, invoked over SSH like any other live-device
# check this project already does.
#
# Usage: production-benchmark.sh <label> [output-dir] [wifi-variant]
#                                 [camera-variant] [preempt-variant]
#                                 [run-number] [manifest-path]
#   <label>          free-text scenario tag, e.g. "idle-10min",
#                    "camera-1080p30", "usb-storage-inserted".
#   [output-dir]     base results directory (default:
#                    /usr/data/staging/benchmarks). The actual output
#                    lands under
#                    <output-dir>/<date>/<wifi-variant>/<camera-variant>/
#                    <preempt-variant>/run-<run-number>/<label>-<ts>.*
#                    per the mission's own required naming convention.
#   [wifi-variant]   e.g. W0/W1/W2/W3/P0/P1 - whatever's actually active
#                    (default: "unknown").
#   [camera-variant] e.g. C0/C1/C2 (default: "unknown").
#   [preempt-variant] e.g. R0/R1 (default: "unknown").
#   [run-number]     repetition counter for this exact combination
#                    (default: 1).
#   [manifest-path]  path to the build-manifest.txt that corresponds to
#                    whatever is actually flashed right now, if the
#                    operator has scp'd one over - copied verbatim into
#                    this run's own output directory as provenance,
#                    since a running device has no git/source tree of
#                    its own to derive this from (default: none, and the
#                    provenance file notes this honestly rather than
#                    fabricating a value).
#
# Rate-based metrics (CPU%, context-switch rate, interrupt rate) need two
# samples - this script takes them SAMPLE_INTERVAL_SECONDS apart itself,
# so a single invocation is a complete, self-contained snapshot. For a
# scenario like "idle for 10 minutes", start the scenario, wait out the
#10 minutes yourself, then invoke this once at the end - it is not itself
# a 10-minute-long capture.

SAMPLE_INTERVAL_SECONDS=5
LABEL="${1:?usage: production-benchmark.sh <label> [output-dir] [wifi-variant] [camera-variant] [preempt-variant] [run-number] [manifest-path]}"
OUTDIR_BASE="${2:-/usr/data/staging/benchmarks}"
WIFI_VARIANT="${3:-unknown}"
CAMERA_VARIANT="${4:-unknown}"
PREEMPT_VARIANT="${5:-unknown}"
RUN_NUMBER="${6:-1}"
MANIFEST_PATH="${7:-}"

TS=$(date -u +%Y%m%dT%H%M%SZ)
DATE_ONLY=$(date -u +%Y%m%d)
OUTDIR="$OUTDIR_BASE/$DATE_ONLY/$WIFI_VARIANT/$CAMERA_VARIANT/$PREEMPT_VARIANT/run-$RUN_NUMBER"
BASENAME="$OUTDIR/${LABEL}-${TS}"

mkdir -p "$OUTDIR"

# --- helpers -----------------------------------------------------------

# VmRSS (kB) for the first process whose command line matches $1 (a plain
# substring, not a regex - keeps this BusyBox-grep-safe).
rss_for() {
	pid=$(ps -o pid,args 2>/dev/null | grep -F "$1" | grep -v grep | head -1 | awk '{print $1}')
	[ -z "$pid" ] && { echo "0"; return; }
	awk '/^VmRSS:/{print $2; found=1} END{if(!found) print 0}' "/proc/$pid/status" 2>/dev/null || echo 0
}

pid_for() {
	ps -o pid,args 2>/dev/null | grep -F "$1" | grep -v grep | head -1 | awk '{print $1}'
}

# Sum of the "otg"/dwc2 interrupt line(s) in /proc/interrupts (both CPU
# columns), the largest single concrete finding in the original audit.
otg_interrupt_total() {
	awk '/otg|dwc2/{s=0; for(i=2;i<=NF;i++){if($i ~ /^[0-9]+$/) s+=$i}; total+=s} END{print total+0}' /proc/interrupts
}

ctxt_total() {
	awk '/^ctxt/{print $2}' /proc/stat
}

# Aggregate CPU busy ticks + total ticks from the first "cpu " line.
cpu_ticks() {
	awk '/^cpu /{busy=0; for(i=2;i<=NF;i++){if(i!=5) busy+=$i}; total=busy+$5; print busy" "total}' /proc/stat
}

# --- sample 1 ------------------------------------------------------------

T1=$(date +%s)
OTG1=$(otg_interrupt_total)
CTXT1=$(ctxt_total)
CPU1=$(cpu_ticks)
CPU1_BUSY=${CPU1% *}
CPU1_TOTAL=${CPU1#* }

sleep "$SAMPLE_INTERVAL_SECONDS"

# --- sample 2 + instantaneous metrics -------------------------------------

T2=$(date +%s)
OTG2=$(otg_interrupt_total)
CTXT2=$(ctxt_total)
CPU2=$(cpu_ticks)
CPU2_BUSY=${CPU2% *}
CPU2_TOTAL=${CPU2#* }

ELAPSED=$((T2 - T1))
[ "$ELAPSED" -le 0 ] && ELAPSED=1

OTG_RATE=$(( (OTG2 - OTG1) / ELAPSED ))
CTXT_RATE=$(( (CTXT2 - CTXT1) / ELAPSED ))
CPU_BUSY_DELTA=$((CPU2_BUSY - CPU1_BUSY))
CPU_TOTAL_DELTA=$((CPU2_TOTAL - CPU1_TOTAL))
[ "$CPU_TOTAL_DELTA" -le 0 ] && CPU_TOTAL_DELTA=1
CPU_PCT=$(( (CPU_BUSY_DELTA * 100) / CPU_TOTAL_DELTA ))

UPTIME_S=$(awk '{print int($1)}' /proc/uptime)
LOAD1=$(awk '{print $1}' /proc/loadavg)
LOAD5=$(awk '{print $2}' /proc/loadavg)
LOAD15=$(awk '{print $3}' /proc/loadavg)
THREAD_COUNT=$(awk '{print $4}' /proc/loadavg | cut -d/ -f2)

# Plain pipe, not <(...) - process substitution isn't BusyBox-ash-safe.
MEM_LINE=$(free -m | awk '/^Mem:/{print $2, $3, $4, $6, $7}')
MEM_TOTAL=$(echo "$MEM_LINE" | awk '{print $1}')
MEM_USED=$(echo "$MEM_LINE" | awk '{print $2}')
MEM_FREE=$(echo "$MEM_LINE" | awk '{print $3}')
MEM_BUFFCACHE=$(echo "$MEM_LINE" | awk '{print $4}')
MEM_AVAILABLE=$(echo "$MEM_LINE" | awk '{print $5}')
SWAP_LINE=$(free -m | awk '/^Swap:/{print $2, $3}')
SWAP_TOTAL=$(echo "$SWAP_LINE" | awk '{print $1}')
SWAP_USED=$(echo "$SWAP_LINE" | awk '{print $2}')

SOCKET_COUNT=$(ss -tln 2>/dev/null | tail -n +2 | wc -l)

KLIPPY_RSS=$(rss_for "klippy.py")
MOONRAKER_RSS=$(rss_for "moonraker.py")
GUPPYSCREEN_RSS=$(rss_for "/opt/nebulascreen/nebulascreen")
USTREAMER_RSS=$(rss_for "ustreamer")
NGINX_RSS=$(rss_for "nginx: master")
DROPBEAR_RSS=$(rss_for "/usr/sbin/dropbear -R")
MODEMMANAGER_RSS=$(rss_for "ModemManager")
DBUS_RSS=$(rss_for "dbus-daemon")

USTREAMER_PID=$(pid_for "ustreamer")
if [ -n "$USTREAMER_PID" ]; then
	USTREAMER_CPU_STAT=$(awk '{print $14+$15}' "/proc/$USTREAMER_PID/stat" 2>/dev/null)
else
	USTREAMER_CPU_STAT=""
fi

MOONRAKER_INFO=$(curl -s --max-time 3 "http://127.0.0.1:7125/server/info" 2>/dev/null)
PRINTER_STATE=$(curl -s --max-time 3 "http://127.0.0.1:7125/printer/objects/query?webhooks" 2>/dev/null)

USB_TOPOLOGY=$(lsusb -t 2>/dev/null)

# --- system metrics gaps (Phase A9) -------------------------------------

KERNEL_VERSION=$(uname -r 2>/dev/null)
KERNEL_FULL=$(uname -a 2>/dev/null)
# CONFIG_PREEMPT_RT/CONFIG_PREEMPT aren't in /proc/version text - the
# most reliable live signal without needing /proc/config.gz (not every
# kernel build enables CONFIG_IKCONFIG_PROC) is /sys/kernel/realtime,
# which only exists at all on a genuine PREEMPT_RT kernel.
if [ -f /sys/kernel/realtime ]; then
	PREEMPT_MODEL="PREEMPT_RT"
elif [ -f /proc/config.gz ]; then
	PREEMPT_MODEL=$(zcat /proc/config.gz 2>/dev/null | grep -E '^CONFIG_PREEMPT(_RT|_VOLUNTARY|_NONE)?=y$' | head -1 | cut -d= -f1 | sed 's/^CONFIG_//')
else
	PREEMPT_MODEL="unknown"
fi
[ -n "$PREEMPT_MODEL" ] || PREEMPT_MODEL="unknown"

# Active rootfs/kernel slot - derived from the real root= kernel cmdline
# argument this project's own A/B scheme already relies on (mmcblk0p7/p8
# = stock kernel/rootfs slot pair, mmcblk0p5/p6... see docs/HOW_TO_SWITCH_
# STOCK_AND_CUSTOM.md for the authoritative pXX mapping - this just
# reports the raw device node, not a guessed label, to avoid this script
# silently going stale if that mapping is ever revisited).
ROOT_DEVICE=$(sed -n 's/.*root=\([^ ]*\).*/\1/p' /proc/cmdline 2>/dev/null)

INTERRUPTS_TOTAL_SNAPSHOT=$(awk '{for(i=2;i<=NF;i++){if($i ~ /^[0-9]+$/) s+=$i}} END{print s+0}' /proc/interrupts)

# --- Wi-Fi metrics (Phase A9, sec 18) ------------------------------------

WIFI_IFACE=wlan0
WIFI_MAC=$(cat "/sys/class/net/$WIFI_IFACE/address" 2>/dev/null)
WIFI_IP=$(ip -4 -o addr show "$WIFI_IFACE" 2>/dev/null | awk '{print $4}')
WIFI_DRIVER=$(basename "$(readlink -f "/sys/class/net/$WIFI_IFACE/device/driver" 2>/dev/null)" 2>/dev/null)
WIFI_POWER_SAVE=$(iw dev "$WIFI_IFACE" get power_save 2>/dev/null | sed -n 's/.*Power save: //p')
WIFI_REGDOM=$(iw reg get 2>/dev/null | awk '/^country/{print $2; exit}')
WPA_STATUS=$(wpa_cli -i "$WIFI_IFACE" status 2>/dev/null)
WIFI_ASSOC_STATE=$(echo "$WPA_STATUS" | sed -n 's/^wpa_state=//p')
WIFI_SSID=$(echo "$WPA_STATUS" | sed -n 's/^ssid=//p')
WIFI_BSSID=$(echo "$WPA_STATUS" | sed -n 's/^bssid=//p')
WIFI_LINK=$(iw dev "$WIFI_IFACE" link 2>/dev/null)
WIFI_RSSI=$(echo "$WIFI_LINK" | sed -n 's/.*signal: \(-\?[0-9]*\).*/\1/p')
WIFI_TX_BITRATE=$(echo "$WIFI_LINK" | sed -n 's/.*tx bitrate: \([0-9.]* [A-Za-z\/]*\).*/\1/p')
WIFI_RX_BITRATE=$(echo "$WIFI_LINK" | sed -n 's/.*rx bitrate: \([0-9.]* [A-Za-z\/]*\).*/\1/p')
WIFI_STATION_DUMP=$(iw dev "$WIFI_IFACE" station dump 2>/dev/null)
WIFI_TX_RETRIES=$(echo "$WIFI_STATION_DUMP" | sed -n 's/.*tx retries:[[:space:]]*//p')
WIFI_TX_FAILED=$(echo "$WIFI_STATION_DUMP" | sed -n 's/.*tx failed:[[:space:]]*//p')
# SDIO host controller (msc1) interrupt line - board-specific naming, so
# this greps loosely for msc/mmc/sdio rather than a single fixed string.
WIFI_SDIO_IRQ_TOTAL=$(awk '/msc|mmc|sdio/{for(i=2;i<=NF;i++){if($i ~ /^[0-9]+$/) s+=$i}} END{print s+0}' /proc/interrupts)
WIFI_DMESG_ERRORS=$(dmesg 2>/dev/null | grep -iE 'brcmf.*(error|bus.?down|reset|fail)' | tail -20)

# --- camera metrics (Phase A9, sec 18.16) --------------------------------

# Camera quality presets mission (2026-08-04): the old fps-only
# camera-fps-mode/C1 marker was replaced by camera-quality-mode
# (LOW/MED/HIGH - see S50webcam's own header comment and
# camera-quality.cfg's SET_CAMERA_QUALITY_LOW/MED/HIGH macros). Mirrors
# that script's exact resolution/fps mapping so this benchmark reports
# what's actually configured rather than always assuming the old default.
CAMERA_QUALITY_MARKER=/usr/data/nebulaos/maintenance/camera-quality-mode
case "$(cat "$CAMERA_QUALITY_MARKER" 2>/dev/null)" in
	LOW)
		CAMERA_RESOLUTION="640x480"
		CAMERA_CONFIGURED_FPS="uncapped"
		;;
	MED)
		CAMERA_RESOLUTION="1280x720"
		CAMERA_CONFIGURED_FPS="uncapped"
		;;
	*)
		# HIGH, or marker missing/unrecognized - the qualified default.
		CAMERA_RESOLUTION="1920x1080"
		CAMERA_CONFIGURED_FPS=30
		;;
esac
CAMERA_IDLE_STATE_FILE=/var/run/nebulaos-camera-idle-state
if [ -f "$CAMERA_IDLE_STATE_FILE" ]; then
	CAMERA_STATE=$(cat "$CAMERA_IDLE_STATE_FILE" 2>/dev/null)
else
	CAMERA_STATE="active"
fi
CAMERA_HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:8080/" 2>/dev/null)
SNAPSHOT_T0=$(date +%s%N 2>/dev/null)
curl -s -o /dev/null --max-time 5 "http://127.0.0.1:8080/snapshot" 2>/dev/null
SNAPSHOT_T1=$(date +%s%N 2>/dev/null)
if [ -n "$SNAPSHOT_T0" ] && [ -n "$SNAPSHOT_T1" ] && [ "$SNAPSHOT_T1" -gt "$SNAPSHOT_T0" ] 2>/dev/null; then
	CAMERA_SNAPSHOT_LATENCY_MS=$(( (SNAPSHOT_T1 - SNAPSHOT_T0) / 1000000 ))
else
	CAMERA_SNAPSHOT_LATENCY_MS="n/a"
fi
CAMERA_REOPEN_FAILURES=$(dmesg 2>/dev/null | grep -ic "uvcvideo.*fail\|ustreamer.*fail")

# --- boot timing (Phase A9, from /etc/init.d/S02nebulaos-boot-timing) ----

BOOT_TIMING_LOG=/var/run/nebulaos-boot-timing.log
if [ -f "$BOOT_TIMING_LOG" ]; then
	BOOT_TIMING_CONTENTS=$(cat "$BOOT_TIMING_LOG")
else
	BOOT_TIMING_CONTENTS="(not present - S02nebulaos-boot-timing has not run yet this boot, or this image predates it)"
fi

# --- write TSV row (one line, easy to diff/append across runs) ---------

TSV="$BASENAME.tsv"
if [ ! -e "$OUTDIR/summary.tsv" ]; then
	printf 'timestamp\tlabel\tuptime_s\tload1\tload5\tload15\tthreads\tmem_total_mb\tmem_used_mb\tmem_free_mb\tmem_buffcache_mb\tmem_available_mb\tswap_total_mb\tswap_used_mb\tcpu_pct\tctxt_per_sec\totg_irq_per_sec\tsocket_count\tklippy_rss_kb\tmoonraker_rss_kb\tguppyscreen_rss_kb\tustreamer_rss_kb\tnginx_rss_kb\tdropbear_rss_kb\tmodemmanager_rss_kb\tdbus_rss_kb\tustreamer_cpu_ticks\n' \
		> "$OUTDIR/summary.tsv"
fi
ROW=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
	"$TS" "$LABEL" "$UPTIME_S" "$LOAD1" "$LOAD5" "$LOAD15" "$THREAD_COUNT" \
	"$MEM_TOTAL" "$MEM_USED" "$MEM_FREE" "$MEM_BUFFCACHE" "$MEM_AVAILABLE" \
	"$SWAP_TOTAL" "$SWAP_USED" "$CPU_PCT" "$CTXT_RATE" "$OTG_RATE" "$SOCKET_COUNT" \
	"$KLIPPY_RSS" "$MOONRAKER_RSS" "$GUPPYSCREEN_RSS" "$USTREAMER_RSS" "$NGINX_RSS" \
	"$DROPBEAR_RSS" "$MODEMMANAGER_RSS" "$DBUS_RSS" "${USTREAMER_CPU_STAT:-0}")
printf '%s\n' "$ROW" >> "$OUTDIR/summary.tsv"
printf '%s\n' "$ROW" > "$TSV"

# --- write readable summary ---------------------------------------------

SUMMARY="$BASENAME.txt"
{
	echo "NebulaOS production benchmark - $LABEL ($TS)"
	echo "sample interval: ${ELAPSED}s"
	echo
	echo "uptime: ${UPTIME_S}s   load: $LOAD1 $LOAD5 $LOAD15   threads: $THREAD_COUNT"
	echo "memory: total=${MEM_TOTAL}MB used=${MEM_USED}MB free=${MEM_FREE}MB buff/cache=${MEM_BUFFCACHE}MB available=${MEM_AVAILABLE}MB"
	echo "swap: total=${SWAP_TOTAL}MB used=${SWAP_USED}MB"
	echo "cpu: ${CPU_PCT}% aggregate busy over sample window"
	echo "context switches: ${CTXT_RATE}/sec"
	echo "USB OTG interrupts: ${OTG_RATE}/sec"
	echo "total interrupts (all lines): ${INTERRUPTS_TOTAL_SNAPSHOT} (cumulative since boot, not a rate)"
	echo "listening sockets: $SOCKET_COUNT"
	echo "kernel: $KERNEL_VERSION ($KERNEL_FULL)"
	echo "preemption model: $PREEMPT_MODEL"
	echo "root device (active slot): ${ROOT_DEVICE:-unknown}"
	echo
	echo "RSS (kB): klippy=$KLIPPY_RSS moonraker=$MOONRAKER_RSS nebulascreen=$GUPPYSCREEN_RSS ustreamer=$USTREAMER_RSS nginx=$NGINX_RSS dropbear=$DROPBEAR_RSS modemmanager=$MODEMMANAGER_RSS dbus=$DBUS_RSS"
	echo "ustreamer cumulative cpu ticks (utime+stime): ${USTREAMER_CPU_STAT:-n/a}"
	echo
	echo "=== Wi-Fi ==="
	echo "interface: $WIFI_IFACE   mac: ${WIFI_MAC:-unknown}   driver: ${WIFI_DRIVER:-unknown}"
	echo "ip: ${WIFI_IP:-none}   association: ${WIFI_ASSOC_STATE:-unknown}   ssid: ${WIFI_SSID:-none}   bssid: ${WIFI_BSSID:-none}"
	echo "power_save: ${WIFI_POWER_SAVE:-unknown}   regulatory domain: ${WIFI_REGDOM:-unknown}"
	echo "rssi: ${WIFI_RSSI:-n/a} dBm   tx bitrate: ${WIFI_TX_BITRATE:-n/a}   rx bitrate: ${WIFI_RX_BITRATE:-n/a}"
	echo "tx retries: ${WIFI_TX_RETRIES:-n/a}   tx failed: ${WIFI_TX_FAILED:-n/a}"
	echo "SDIO/MMC interrupt total (cumulative, not a rate): $WIFI_SDIO_IRQ_TOTAL"
	echo "recent brcmfmac error/reset dmesg lines (if any):"
	echo "${WIFI_DMESG_ERRORS:-  (none found)}"
	echo
	echo "=== Camera ==="
	echo "configured: ${CAMERA_RESOLUTION}@${CAMERA_CONFIGURED_FPS}fps   idle-controller state: $CAMERA_STATE"
	echo "ustreamer HTTP root response code: ${CAMERA_HTTP_CODE:-none}"
	echo "snapshot latency: ${CAMERA_SNAPSHOT_LATENCY_MS} ms"
	echo "reopen-looking dmesg lines (uvcvideo/ustreamer failures, count): $CAMERA_REOPEN_FAILURES"
	echo
	echo "=== Boot timing (this boot only - see /var/run/nebulaos-boot-timing.log) ==="
	echo "$BOOT_TIMING_CONTENTS"
	echo
	echo "USB topology:"
	echo "$USB_TOPOLOGY"
	echo
	echo "Moonraker /server/info:"
	echo "$MOONRAKER_INFO"
	echo
	echo "Printer webhooks state:"
	echo "$PRINTER_STATE"
} > "$SUMMARY"

# --- provenance (Phase A9) ------------------------------------------------
#
# A running device has no git/source tree of its own - the only honest
# way to record which exact build this is is either (a) the operator
# supplying the build-manifest.txt that corresponds to whatever was just
# flashed (copied here verbatim), or (b) noting plainly that no manifest
# was supplied, never fabricating a value.

PROVENANCE="$BASENAME-provenance.txt"
{
	echo "run_timestamp=$TS"
	echo "label=$LABEL"
	echo "wifi_variant=$WIFI_VARIANT"
	echo "camera_variant=$CAMERA_VARIANT"
	echo "preempt_variant=$PREEMPT_VARIANT"
	echo "run_number=$RUN_NUMBER"
	echo "kernel_version=$KERNEL_VERSION"
	echo "preemption_model=$PREEMPT_MODEL"
	echo "root_device=${ROOT_DEVICE:-unknown}"
	echo "wifi_power_save_state=${WIFI_POWER_SAVE:-unknown}"
	echo "camera_idle_controller_state=$CAMERA_STATE"
	if [ -n "$MANIFEST_PATH" ] && [ -f "$MANIFEST_PATH" ]; then
		echo "build_manifest_source=$MANIFEST_PATH"
		echo "--- build-manifest.txt contents ---"
		cat "$MANIFEST_PATH"
	else
		echo "build_manifest_source=NONE_SUPPLIED"
		echo "# No build-manifest.txt path was supplied to this run. The exact"
		echo "# git/kernel/vendor commit and artifact hashes this device was"
		echo "# flashed from are therefore NOT recorded here - re-run with the"
		echo "# manifest-path argument pointing at the real build-manifest.txt"
		echo "# used for this flash if that provenance is needed later."
	fi
} > "$PROVENANCE"

echo "wrote $TSV"
echo "wrote $SUMMARY"
echo "wrote $PROVENANCE"
echo "appended $OUTDIR/summary.tsv"
