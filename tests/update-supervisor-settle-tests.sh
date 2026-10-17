#!/bin/sh
# Run 10 test (2026-10-17, ke-dev): Moonraker v0.11 installed its requirements
# from the NebulaOS package index, restarted onto the new code - and the
# supervisor, already validating, took that restart (one klippy_state=
# 'startup' sample) for a failure and rolled back. wait_for_update_manager_done
# holds validation until update_manager is idle and Moonraker runs the new
# commit. Replays that sequence with a fake Moonraker.
set -u
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SUP="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-update-supervisor.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/update-supervisor-settle.XXXXXX") || exit 1
[ -n "$WORK" ] && [ -d "$WORK" ] || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM
PASS=0 FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

export NEBULAOS_UPDATE_SUPERVISOR_NO_AUTORUN=1 NEBULAOS_ROOT="$WORK/nebulaos" \
	NEBULAOS_RUN_DIR="$WORK/run" MOONRAKER_URL="http://127.0.0.1:9"
mkdir -p "$NEBULAOS_RUN_DIR" "$NEBULAOS_ROOT/updates/locks"
. "$SUP" >/dev/null 2>&1
log() { echo "LOG: $*" >> "$WORK/log"; }
sleep() { :; }
UPDATE_SETTLE_INTERVAL=0

# The fake Moonraker walks through: pip running (busy, old version) ->
# restarting (no answer) -> new version, idle. One step per status call.
wget() {
	url=""; for a in "$@"; do url=$a; done
	step=$(cat "$WORK/step" 2>/dev/null || echo 0)
	case "$url" in
		*/machine/update/status)
			echo $((step + 1)) > "$WORK/step"
			case "$step" in
				0|1|2) echo '{"result":{"busy":true}}' ;;      # installing requirements
				3|4) return 1 ;;                                 # restarting
				*) echo '{"result":{"busy":false}}' ;;
			esac ;;
		*/server/info)
			if [ "$step" -ge 7 ]; then   # idle once while the old version still runs
				echo '{"result":{"moonraker_version":"v0.11.0-0-g985c1d0b","klippy_state":"ready"}}'
			else
				echo '{"result":{"moonraker_version":"v0.10.0-31-gd5ee1712","klippy_state":"startup"}}'
			fi ;;
	esac
}

NEW=985c1d0bbeb90bc057d34a232c9dc3b05e0c6c8d
rm -f "$WORK/step" "$WORK/log"; UPDATE_SETTLE_TRIES=50
wait_for_update_manager_done moonraker "$NEW"
step=$(cat "$WORK/step")
[ "$step" -ge 7 ] && pass || fail "returned before Moonraker ran the new commit (status calls: $step)"
grep -q "did not settle" "$WORK/log" 2>/dev/null && fail "timed out instead of settling" || pass

# another component: idle is enough
rm -f "$WORK/step" "$WORK/log"
wait_for_update_manager_done klipper 0123456789abcdef
[ "$(cat "$WORK/step")" -eq 6 ] && pass || fail "klipper waited for $(cat "$WORK/step") status calls"

# never settles: bounded, logged, validation goes on
echo 0 > "$WORK/step"; rm -f "$WORK/log"
wget() { return 1; }
UPDATE_SETTLE_TRIES=4
wait_for_update_manager_done moonraker "$NEW" && pass || fail "did not return"
grep -q "did not settle on 985c1d0" "$WORK/log" && pass || fail "timeout not logged"

# wired in before stage1
grep -n 'wait_for_update_manager_done "$name" "$new_commit"' "$SUP" >/dev/null \
	&& [ "$(grep -n 'wait_for_update_manager_done "$name"' "$SUP" | cut -d: -f1)" -lt \
	     "$(grep -n 'HEALTHCHECK" stage1 "$name" "$path"; then' "$SUP" | head -1 | cut -d: -f1)" ] \
	&& pass || fail "not called before stage1 in validate_component"

echo "update-supervisor-settle-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
