#!/bin/sh
# GUI/service readiness acceptance (2026-10-09): self-undoing backlight
# brightness exercise through the same path the GUI uses (nebulaos-osconfig
# display ...) over the standard backlight device. Records the persisted
# display files and the sysfs brightness/bl_power, sets 50 then 25 (each read
# back, and again after 3 s to prove the level holds past the controller's
# 2 s bounded window), then the profile's undo restores the recorded raw
# values and files. Never switches the backlight off.
# B0, P0, HAD_*, GS_STARTED are read by the profile's undo (nebulaos_capture.py).
# shellcheck disable=SC2034
O=/usr/libexec/nebulaos/nebulaos-osconfig
DD=/usr/data/nebulaos/display
B=/sys/class/backlight/nebulaos_backlight
bl() { echo "brightness=$(cat $B/brightness) actual=$(cat $B/actual_brightness) bl_power=$(cat $B/bl_power)"; }
[ -w $B/brightness ] || { echo "NO_BACKLIGHT_DEVICE"; exit 3; }
B0=$(cat $B/brightness); P0=$(cat $B/bl_power)
HAD_J=0; HAD_E=0
[ -f $DD/display.json ] && { cp $DD/display.json $T/display.json; HAD_J=1; }
[ -f $DD/display.env ] && { cp $DD/display.env $T/display.env; HAD_E=1; }
echo "start: had_json=$HAD_J had_env=$HAD_E"; bl
[ "$P0" = 0 ] || { echo "BACKLIGHT_OFF_AT_START"; exit 3; }
# From here on the profile's undo restores the recorded state.
GS_STARTED=1
for lvl in 50 25; do
	echo "== set $lvl"; $O display set-brightness --level $lvl; echo "rc=$?"
	printf "now:       "; bl
	sleep 3
	printf "after 3 s: "; bl
done
echo "== status via helper"; $O display status
