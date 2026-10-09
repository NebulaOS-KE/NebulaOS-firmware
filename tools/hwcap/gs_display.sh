#!/bin/sh
# GUI/service readiness acceptance (2026-10-09): self-undoing backlight
# brightness exercise through the same path the GUI uses (nebulaos-osconfig
# display ...). Records the persisted display files and the controller state,
# sets 50 then 25 (each read back, and re-read after the controller's 2 s
# bounded window to prove the commit holds), then the profile's undo restores
# everything: level 100, the original files (or none), and boot-preserve via
# "disarm" if that was the starting state. Never sleeps the backlight.
O=/usr/libexec/nebulaos/nebulaos-osconfig
DD=/usr/data/nebulaos/display
ST=/sys/kernel/debug/nebulaos_backlight_final/status
bl() { grep -E '^(state|pwm_duty_pct|asleep|safe_on_verified|op_failure_count):' $ST 2>/dev/null | tr '\n' ' '; echo; }
S0=$(sed -n 's/^state: //p' $ST 2>/dev/null)
HAD_J=0; HAD_E=0
[ -f $DD/display.json ] && { cp $DD/display.json $T/display.json; HAD_J=1; }
[ -f $DD/display.env ] && { cp $DD/display.env $T/display.env; HAD_E=1; }
echo "start: state=$S0 had_json=$HAD_J had_env=$HAD_E"; bl
case "$S0" in boot-preserve|safe-on|pwm-committed) ;; *) echo "UNEXPECTED_START_STATE"; exit 3 ;; esac
# From here on the profile's undo restores the recorded state.
GS_STARTED=1
for lvl in 50 25; do
	echo "== set $lvl"; $O display set-brightness --level $lvl; echo "rc=$?"
	printf "now:   "; bl
	sleep 3
	printf "after 3 s: "; bl
done
echo "== status via helper"; $O display status
