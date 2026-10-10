#!/bin/sh
# GUI/service readiness acceptance T4 (2026-10-10): human-observed backlight
# exercise through the same path the GUI uses (nebulaos-osconfig display ...).
# Steps through 25/50/75/100 % (6 s each, for a person to compare by eye),
# then switches the backlight off with `display sleep` (which starts the
# touch-wake watcher) and waits up to 90 s for a person to touch the screen;
# the watcher, not this script, must bring the backlight back. The profile's
# undo wakes the display if it is still off and restores the recorded raw
# brightness and display files.
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
GS_STARTED=1
for lvl in 25 50 75 100; do
	echo "== LOOK: brightness $lvl % for 6 s"; $O display set-brightness --level $lvl >/dev/null; echo "rc=$?"
	sleep 6; bl
done
echo "== sleep"; $O display sleep; echo "rc=$?"; bl
case "$(cat $B/bl_power)" in
	0) echo "SLEEP_RESULT=REFUSED_OR_NOT_OFF"; exit 0 ;;
esac
echo "SLEEP_RESULT=OFF"
echo "== TOUCH THE SCREEN NOW (waiting up to 90 s)"
i=0
while [ $i -lt 450 ]; do
	[ "$(cat $B/bl_power)" = 0 ] && break
	sleep 0.2; i=$((i + 1))
done
if [ "$(cat $B/bl_power)" = 0 ]; then
	echo "WAKE_RESULT=WOKEN_BY_TOUCH after $((i / 5)) s"
else
	echo "WAKE_RESULT=NOT_WOKEN within 90 s (undo wakes it)"
fi
bl
echo "== status via helper"; $O display status
