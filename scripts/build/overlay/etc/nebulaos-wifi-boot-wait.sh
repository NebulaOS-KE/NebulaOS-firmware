#!/bin/sh
# NebulaOS Wi-Fi boot-association-wait qualification mode (pre-
# qualification mission Phase A6, 2026-07-31 - see docs/NEBULAOS_CAMERA_
# USB_RT_SOURCE_ANALYSIS.md sec 18.11/18.17 for the source-grounded
# rationale).
#
# S01wifi's current, real, already-hardware-proven behavior is a fixed
# `sleep 2` between launching wpa_supplicant and bringing the interface
# up for DHCP. The source analysis found this plausible-but-unverified -
# not proven load-bearing, not proven arbitrary either - so this is an
# EXPERIMENTAL alternative for later A/B testing, not a replacement:
# every build still defaults to the exact original fixed-sleep behavior
# unless an explicit marker opts into the event-driven path.
#
# Variants:
#   fixed (default/marker absent) - today's real, hardware-proven
#       `sleep 2` behavior, byte-for-byte unchanged.
#   event-driven - polls wpa_cli's own status for wpa_state=COMPLETED,
#       up to a bounded timeout, so a fast association doesn't wait the
#       full fixed delay and a slow one doesn't get cut short at 2s.
#
# Never depends on internet reachability (only queries wpa_supplicant's
# own local control socket via wpa_cli). Never starts a second
# wpa_supplicant or udhcpc - this only affects how long S01wifi waits
# before its own existing single `ifup wlan0` call, which itself remains
# completely unchanged either way.

# BOOT-02 (2026-10-05): the selector is ONE-SHOT. The marker is deleted
# before its content is acted on, so the next boot is always back on the
# fixed path; a marker that cannot be deleted is never honoured (it would
# otherwise be sticky). The event-driven path is bounded and falls back to
# the fixed path's own next step (the unchanged `ifup wlan0`) on timeout or
# when wpa_cli is missing. Each boot writes what happened to
# $NEBULAOS_WIFI_BOOT_WAIT_RESULT (tmpfs) for the hardware test to read:
#   MODE=fixed|event-driven  OUTCOME=fixed|associated|timeout-fallback|
#   no-wpa_cli-fallback  WAIT_START= WAIT_END= (uptime s)  ASSOC_AFTER=<s>
#   IFUP_RC= IFUP_END=  and IFUP=failed-reported when ifup returned non-zero.

NEBULAOS_WIFI_BOOT_WAIT_MARKER="${NEBULAOS_WIFI_BOOT_WAIT_MARKER:-/usr/data/nebulaos/maintenance/wifi-boot-wait-mode}"
NEBULAOS_WIFI_BOOT_WAIT_TIMEOUT="${NEBULAOS_WIFI_BOOT_WAIT_TIMEOUT:-10}"
NEBULAOS_WIFI_BOOT_WAIT_MIN="${NEBULAOS_WIFI_BOOT_WAIT_MIN:-1}"
NEBULAOS_WIFI_BOOT_WAIT_FIXED_SLEEP="${NEBULAOS_WIFI_BOOT_WAIT_FIXED_SLEEP:-2}"
NEBULAOS_WIFI_BOOT_WAIT_RESULT="${NEBULAOS_WIFI_BOOT_WAIT_RESULT:-/run/nebulaos-wifi-boot-wait.result}"
NEBULAOS_WIFI_UPTIME_SRC="${NEBULAOS_WIFI_UPTIME_SRC:-/proc/uptime}"

# Prints the requested mode ("fixed" or "event-driven") without consuming
# anything - fails safe to "fixed" if the marker is absent or contains
# anything unrecognized.
nebulaos_wifi_boot_wait_requested_mode() {
	marker="${1:-$NEBULAOS_WIFI_BOOT_WAIT_MARKER}"
	if [ -f "$marker" ]; then
		mode=$(cat "$marker" 2>/dev/null)
		case "$mode" in
			event-driven) printf 'event-driven'; return 0 ;;
		esac
	fi
	printf 'fixed'
}

# One-shot: prints the mode for THIS boot and consumes the marker first.
# A marker that cannot be removed (read-only or odd filesystem state) is
# never honoured - honouring it would make event-driven sticky.
nebulaos_wifi_boot_wait_take_mode() {
	marker="${1:-$NEBULAOS_WIFI_BOOT_WAIT_MARKER}"
	[ -e "$marker" ] || { printf 'fixed'; return 0; }
	mode=$(nebulaos_wifi_boot_wait_requested_mode "$marker")
	rm -f "$marker" 2>/dev/null
	if [ -e "$marker" ]; then
		echo "nebulaos-wifi-boot-wait: could not consume $marker - ignoring it (fixed path)" >&2
		printf 'fixed'
		return 0
	fi
	sync 2>/dev/null
	printf '%s' "$mode"
}

_nebulaos_wifi_now() {
	_wt=; read -r _wt _ < "$NEBULAOS_WIFI_UPTIME_SRC" 2>/dev/null || _wt='?'
	case "$_wt" in ''|*[!0-9.]*) _wt='?' ;; esac
	printf '%s' "$_wt"
}

_nebulaos_wifi_result() {
	echo "$1" >> "$NEBULAOS_WIFI_BOOT_WAIT_RESULT" 2>/dev/null || true
}

# Polls `wpa_cli -i <iface> status` for wpa_state=COMPLETED, once per
# second, for up to NEBULAOS_WIFI_BOOT_WAIT_TIMEOUT seconds total,
# always waiting at least NEBULAOS_WIFI_BOOT_WAIT_MIN seconds first
# (mirrors the fixed path's own minimum settle time before DHCP is even
# attempted). Returns 0 as soon as association completes (ASSOC_AFTER is
# set), 1 if the timeout is reached without ever seeing COMPLETED - either
# way the caller proceeds to `ifup` immediately afterward, exactly like the
# fixed path already does today.
nebulaos_wifi_wait_for_association_event_driven() {
	iface="${1:-wlan0}"
	elapsed=0
	ASSOC_AFTER=
	while [ "$elapsed" -lt "$NEBULAOS_WIFI_BOOT_WAIT_MIN" ]; do
		sleep 1
		elapsed=$((elapsed + 1))
	done
	while [ "$elapsed" -lt "$NEBULAOS_WIFI_BOOT_WAIT_TIMEOUT" ]; do
		status=$(wpa_cli -i "$iface" status 2>/dev/null)
		case "$status" in
			*wpa_state=COMPLETED*)
				ASSOC_AFTER=$elapsed
				echo "nebulaos-wifi-boot-wait: association completed after ${elapsed}s"
				return 0
				;;
		esac
		sleep 1
		elapsed=$((elapsed + 1))
	done
	echo "nebulaos-wifi-boot-wait: association not confirmed within ${NEBULAOS_WIFI_BOOT_WAIT_TIMEOUT}s, proceeding to ifup anyway" >&2
	return 1
}

# Orchestration: consumes the one-shot selector and waits using the mode it
# names. Callers always proceed to their own next step (ifup) regardless of
# this function's return value, exactly matching the fixed path's own
# unconditional behavior.
nebulaos_wifi_boot_wait() {
	iface="${1:-wlan0}"
	{ true > "$NEBULAOS_WIFI_BOOT_WAIT_RESULT"; } 2>/dev/null
	requested=$(nebulaos_wifi_boot_wait_take_mode)
	_nebulaos_wifi_result "MODE=$requested"
	_nebulaos_wifi_result "WAIT_START=$(_nebulaos_wifi_now)"
	case "$requested" in
		event-driven)
			if ! command -v wpa_cli >/dev/null 2>&1; then
				echo "nebulaos-wifi-boot-wait: wpa_cli not available - falling back to the fixed wait" >&2
				sleep "$NEBULAOS_WIFI_BOOT_WAIT_FIXED_SLEEP"
				_nebulaos_wifi_result "OUTCOME=no-wpa_cli-fallback"
			elif nebulaos_wifi_wait_for_association_event_driven "$iface"; then
				_nebulaos_wifi_result "OUTCOME=associated"
				_nebulaos_wifi_result "ASSOC_AFTER=$ASSOC_AFTER"
			else
				# Fallback: the fixed path's next step. Its 2 s settle has
				# already elapsed inside the bounded wait.
				_nebulaos_wifi_result "OUTCOME=timeout-fallback"
			fi
			;;
		*)
			sleep "$NEBULAOS_WIFI_BOOT_WAIT_FIXED_SLEEP"
			_nebulaos_wifi_result "OUTCOME=fixed"
			;;
	esac
	_nebulaos_wifi_result "WAIT_END=$(_nebulaos_wifi_now)"
	return 0
}

# Records the result of the caller's ifup. A failure is reported, never
# acted on: udhcpc keeps retrying in the background (-b), the printer stays
# usable locally, and nothing here reboots or retries in a loop.
nebulaos_wifi_boot_wait_record_ifup() {
	_nebulaos_wifi_result "IFUP_RC=${1:-?}"
	_nebulaos_wifi_result "IFUP_END=$(_nebulaos_wifi_now)"
	if [ "${1:-1}" != 0 ]; then
		_nebulaos_wifi_result "IFUP=failed-reported"
		echo "nebulaos-wifi-boot-wait: ifup wlan0 returned ${1:-?} - continuing boot, DHCP keeps retrying in the background" >&2
	fi
	return 0
}
