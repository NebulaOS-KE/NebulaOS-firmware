#!/bin/sh
# G108: the image beeper config is owned by Klipper's nebulaos_beeper extra:
# no shell command, no nebulabeep, macro names kept, extra section present.
set -u
cd "$(dirname "$0")/.." || exit 1
f=scripts/build/overlay/etc/nebulaos/klipper/beeper.cfg
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

grep -qx '\[nebulaos_beeper\]' "$f" && pass "[nebulaos_beeper] section" || fail "[nebulaos_beeper] section missing"
for m in M300 BEEP PLAY_TUNE; do
	grep -qx "\[gcode_macro $m\]" "$f" && pass "macro $m kept" || fail "macro $m missing"
done
if grep -v '^#' "$f" | grep -qE 'gcode_shell_command|RUN_SHELL_COMMAND|nebulabeep|guppybeep|/dev/mem'; then
	fail "beeper.cfg still uses a shell command / nebulabeep"
else
	pass "no shell command, no nebulabeep"
fi
grep -q 'NEBULAOS_BEEP FREQ={s} DURATION={p}' "$f" && pass "M300 -> NEBULAOS_BEEP" || fail "M300 does not call NEBULAOS_BEEP"
grep -q 'NEBULAOS_PLAY_TUNE RTTTL=' "$f" && grep -q 'NEBULAOS_PLAY_TUNE SONG=' "$f" \
	&& pass "PLAY_TUNE -> NEBULAOS_PLAY_TUNE" || fail "PLAY_TUNE does not call NEBULAOS_PLAY_TUNE"
# no G4 dwell: a beep must not hold the G-code queue
grep -v '^#' "$f" | grep -qE '^\s*G4\b' && fail "beeper.cfg dwells (G4)" || pass "no dwell"
# the remaining shell-command user is camera.cfg; gcode_shell_command stays composed for it
grep -q '^\[gcode_shell_command set_camera_quality\]' scripts/build/overlay/etc/nebulaos/klipper/camera.cfg \
	&& pass "camera.cfg still the gcode_shell_command user (module kept)" || pass "camera.cfg no longer uses gcode_shell_command"

[ "$fails" -eq 0 ] || exit 1
echo "beeper-cfg-tests: all pass"
