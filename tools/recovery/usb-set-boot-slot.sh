#!/bin/sh
# usb-set-boot-slot.sh A|B - point the OTA marker at boot slot A ("ota:kernel",
# kernel p5 / rootfs p7) or B ("ota:kernel2", kernel2 p6 / rootfs2 p8) over USB
# recovery, when no system on the printer can be reached. The procedure of
# docs/DEVELOPER_RECOVERY.md section 3, made idempotent and verified:
#
#   - reads the real marker bytes first and swaps only when they point at the
#     other slot (usbboot --swap-ota toggles; it cannot pick a side);
#   - verifies the bytes afterwards - --swap-ota's own printout has been seen
#     to be wrong, so it is never trusted;
#   - touches only the marker (offset 0x100000, the "ota" partition): no
#     kernel, rootfs, RTOS, bootloader or partition table.
#
# Before running: Pad in USB recovery mode (USB cable into the Pad's MicroUSB
# port; power off; hold both buttons next to the port 3 s, release reset
# first, power on; `lsusb` shows a108:eaef). Needs sudo (raw USB access) and
# ballaswag/ingenic-usbboot built (USBBOOT=..., default ~/ingenic-usbboot).
#
# 2026-10-14: the first version re-ran `usbboot --uboot` after the swap and
# stopped there - u-boot was still loaded, so a second upload fails although
# the swap had worked. u-boot is now loaded once and reused.
#
# exit 0 marker verified on the requested slot | 1 not verified (do not boot) | 64 usage
set -u
want="${1:-}"
case "$want" in
	A) want_marker="ota:kernel" ;;
	B) want_marker="ota:kernel2" ;;
	*) echo "usage: sudo sh $0 A|B   (A = slot A / Creality's original slot, B = slot B)" >&2; exit 64 ;;
esac
USBBOOT="${USBBOOT:-${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}/ingenic-usbboot/usbboot}"
[ -x "$USBBOOT" ] || { echo "usbboot not found at '$USBBOOT' (set USBBOOT=/path/to/usbboot)"; exit 1; }
cd "$(dirname "$USBBOOT")" || exit 1        # usbboot loads spl.bin/uboot.bin from here
OUT=$(mktemp -d) || exit 1
trap 'rm -rf "$OUT"' EXIT
UBOOT_LOADED=0

# Load u-boot once. Once it runs, the Pad no longer accepts a second upload,
# so a failure after a successful load is not an error.
load_uboot() {
	[ "$UBOOT_LOADED" = 1 ] && return 0
	if "$USBBOOT" --uboot > "$OUT/uboot.log" 2>&1; then
		UBOOT_LOADED=1
		sleep 1
		return 0
	fi
	echo "u-boot could not be loaded - is the Pad in USB recovery mode (lsusb: a108:eaef)?"
	sed 's/^/  /' "$OUT/uboot.log" | tail -n 5
	return 1
}

# Prints A, B or UNKNOWN from the real bytes of the marker.
read_marker() {
	rm -f "$OUT/ota.out"
	"$USBBOOT" -o 0x100000 -s 0x1000 --dump-partition "$OUT/ota.out" > "$OUT/dump.log" 2>&1 \
		&& [ -s "$OUT/ota.out" ] || { echo "UNREADABLE"; return 1; }
	line=$(head -c 64 "$OUT/ota.out" | tr -d '\000' | head -n 1)
	case "$line" in
		ota:kernel2) echo B ;;
		ota:kernel) echo A ;;
		*) echo UNKNOWN ;;
	esac
}

load_uboot || exit 1
now=$(read_marker) || { echo "the marker could not be read:"; sed 's/^/  /' "$OUT/dump.log" | tail -n 5; exit 1; }
echo "marker now: slot $now"
if [ "$now" = UNKNOWN ]; then
	head -c 64 "$OUT/ota.out" | xxd | head -n 2
	echo "RESULT=NOT_OK the marker holds neither ota:kernel nor ota:kernel2 - do not boot; nothing was changed"
	exit 1
fi
if [ "$now" != "$want" ]; then
	"$USBBOOT" --swap-ota > "$OUT/swap.log" 2>&1 || { echo "swap failed:"; sed 's/^/  /' "$OUT/swap.log" | tail -n 5; exit 1; }
	sleep 1
	now=$(read_marker) || { echo "the marker could not be read back after the swap:"; sed 's/^/  /' "$OUT/dump.log" | tail -n 5; exit 1; }
	echo "marker after swap: slot $now"
fi
head -c 32 "$OUT/ota.out" | xxd | head -n 2
if [ "$now" = "$want" ]; then
	echo "RESULT=OK marker is $want_marker (slot $want). Press reset or power-cycle once to boot it."
	exit 0
fi
echo "RESULT=NOT_OK marker reads slot $now, not $want - do not boot; run this again"
exit 1
