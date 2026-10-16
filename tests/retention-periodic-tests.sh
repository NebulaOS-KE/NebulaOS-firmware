#!/bin/sh
# G66 (2026-10-16): the retention job also runs from the housekeeping loop -
# one run at a time (lock, stale after an hour), skipped while printing in
# that periodic mode, and uploaded system images older than 30 days go
# (never during an image install); print files are only an emergency at
# boot; old nebulaos-changes-* folders pruned.
set -u
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
RETENTION_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-retention.sh"
PASS=0 FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/retention-periodic.XXXXXX") || exit 1
[ -n "$WORK" ] && [ -d "$WORK" ] || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

IMG="$WORK/printer_data/config/uploads/system-image"
mkdir -p "$IMG" "$WORK/maintenance" "$WORK/bin" "$WORK/run"
echo old > "$IMG/old.img"; touch -d "2026-08-01 00:00:00" "$IMG/old.img"
echo new > "$IMG/new.img"
# wget stand-in: what Moonraker reports about the print
cat > "$WORK/bin/wget" <<EOF
#!/bin/sh
cat "$WORK/print_stats" 2>/dev/null
EOF
chmod +x "$WORK/bin/wget"

run() { # FUNCTION... - extra env via the caller
	env PATH="$WORK/bin:$PATH" NEBULAOS_RETENTION_NO_AUTORUN=1 NEBULAOS_ROOT="$WORK" \
		LOG="$WORK/maintenance/retention.log" LOCKDIR="$WORK/updates/locks" \
		SHARED_GCODES="$WORK/printer_data/gcodes" IMAGE_JOB_STATE="$WORK/run/state.json" \
		NEBULAOS_RETENTION_SKIP_CLOCK_WAIT=1 "$@"
}

# an install is running: nothing goes
printf '{"state": "running"}' > "$WORK/run/state.json"
run sh -c ". '$RETENTION_SCRIPT'; clean_old_system_images"
[ -e "$IMG/old.img" ] && pass || fail "image deleted during an install"
rm -f "$WORK/run/state.json"
run sh -c ". '$RETENTION_SCRIPT'; clean_old_system_images"
[ ! -e "$IMG/old.img" ] && [ -e "$IMG/new.img" ] && pass || fail "30-day rule: $(ls "$IMG")"

# periodic run while printing does nothing (a rotatable log stays as it is)
mkdir -p "$WORK/printer_data/logs"
head -c 6000000 /dev/zero > "$WORK/printer_data/logs/guppyscreen.log"
echo '{"result":{"status":{"print_stats":{"filename":"a.gcode","state":"printing"}}}}' > "$WORK/print_stats"
run NEBULAOS_RETENTION_PERIODIC=1 sh -c ". '$RETENTION_SCRIPT'; start"
[ "$(wc -c < "$WORK/printer_data/logs/guppyscreen.log")" -eq 6000000 ] && pass || fail "periodic run worked during a print"
[ ! -d "$WORK/maintenance/retention.lock" ] && pass || fail "lock left behind after a skipped run"
echo '{"result":{"status":{"print_stats":{"filename":"","state":"standby"}}}}' > "$WORK/print_stats"
run NEBULAOS_RETENTION_PERIODIC=1 sh -c ". '$RETENTION_SCRIPT'; start"
[ "$(wc -c < "$WORK/printer_data/logs/guppyscreen.log")" -lt 6000000 ] && pass || fail "periodic run did not rotate when idle"

# a second run while one holds the lock does nothing; a stale lock is taken over
head -c 6000000 /dev/zero > "$WORK/printer_data/logs/guppyscreen.log"
mkdir "$WORK/maintenance/retention.lock"
run sh -c ". '$RETENTION_SCRIPT'; start"
[ "$(wc -c < "$WORK/printer_data/logs/guppyscreen.log")" -eq 6000000 ] && pass || fail "ran despite a held lock"
touch -d "2 hours ago" "$WORK/maintenance/retention.lock"
run sh -c ". '$RETENTION_SCRIPT'; start"
[ "$(wc -c < "$WORK/printer_data/logs/guppyscreen.log")" -lt 6000000 ] && [ ! -d "$WORK/maintenance/retention.lock" ] \
	&& pass || fail "stale lock not taken over"

# print files: the emergency deletion stays boot-only (S45), never periodic
mkdir -p "$WORK/printer_data/gcodes"; echo g > "$WORK/printer_data/gcodes/old.gcode"
touch -d "2026-08-01 00:00:00" "$WORK/printer_data/gcodes/old.gcode"
printf '#!/bin/sh\necho "Filesystem 1M-blocks Used Available Use%% Mounted"; echo "/dev/x 6000 5900 100 99%% /usr/data"\n' > "$WORK/bin/df"; chmod +x "$WORK/bin/df"
run NEBULAOS_RETENTION_PERIODIC=1 sh -c ". '$RETENTION_SCRIPT'; start"
[ -e "$WORK/printer_data/gcodes/old.gcode" ] && pass || fail "periodic run deleted a print file"
grep -q "only cleaned at boot" "$WORK/maintenance/retention.log" && pass || fail "periodic critical not logged"
run sh -c ". '$RETENTION_SCRIPT'; start"
[ ! -e "$WORK/printer_data/gcodes/old.gcode" ] && pass || fail "boot run did not do the emergency cleanup"
rm -f "$WORK/bin/df"

# config/backups/nebulaos-changes-*: newest 5 kept
B="$WORK/printer_data/config/backups"; mkdir -p "$B"
for i in 1 2 3 4 5 6 7; do mkdir -p "$B/nebulaos-changes-2026100${i}T000000Z"; done
run sh -c ". '$RETENTION_SCRIPT'; clean_old_nebulaos_changes"
[ "$(ls -d "$B"/nebulaos-changes-* | wc -l)" -eq 5 ] && [ ! -e "$B/nebulaos-changes-20261001T000000Z" ] \
	&& pass || fail "nebulaos-changes pruning: $(ls "$B")"

# the update supervisor's log lines go to a file (start-stop-daemon -b drops stdout)
grep -q 'loop >> "$SUPERVISOR_LOG" 2>&1' "$REPO_ROOT/scripts/build/overlay/etc/nebulaos-update-supervisor.sh" \
	&& pass || fail "update supervisor log not redirected"

# the housekeeping loop calls it in periodic mode without the clock wait
HK="$REPO_ROOT/scripts/build/overlay/etc/init.d/S99nebulaos-housekeeping"
grep -q 'NEBULAOS_RETENTION_SKIP_CLOCK_WAIT=1 NEBULAOS_RETENTION_PERIODIC=1 nice -n 10 /etc/nebulaos-retention.sh' "$HK" \
	&& pass || fail "housekeeping does not run the retention job"

echo "retention-periodic-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
