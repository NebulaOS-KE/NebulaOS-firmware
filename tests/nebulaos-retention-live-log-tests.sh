#!/bin/sh
#
# G45 (2026-10-15): the retention sweep deletes only rotated log copies, never
# a live log - system.log written before NTP carries a 2020 mtime and was
# deleted right after the clock jump, taking every boot line with it.
#
# Usage: sh tests/nebulaos-retention-live-log-tests.sh
set -u
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
RETENTION_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-retention.sh"
PASS=0 FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/retention-live-log.XXXXXX") || exit 1
[ -n "$WORK" ] && [ -d "$WORK" ] || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

L="$WORK/printer_data/logs"
mkdir -p "$L" "$WORK/maintenance/logs"
for f in system.log system.log.0 system.log.1 boot-timing.log klippy.log moonraker.log \
         wifi.log klippy.log.1 moonraker.log.2026-01-01 "$WORK/maintenance/logs/old.log.1"; do
	case "$f" in /*) p=$f ;; *) p="$L/$f" ;; esac
	echo x > "$p"
	touch -d "2020-01-01 00:00:00" "$p"      # pre-NTP mtime
done
echo x > "$L/klippy.log.2"                     # rotated but recent

env NEBULAOS_RETENTION_NO_AUTORUN=1 NEBULAOS_ROOT="$WORK" LOG="$WORK/maintenance/retention.log" \
	LOCKDIR="$WORK/updates/locks" SHARED_GCODES="$WORK/printer_data/gcodes" \
	sh -c ". '$RETENTION_SCRIPT'; clean_rotated_logs"

for f in system.log system.log.0 system.log.1 boot-timing.log klippy.log moonraker.log wifi.log klippy.log.2; do
	[ -e "$L/$f" ] && pass || fail "$f was deleted"
done
for f in "$L/klippy.log.1" "$L/moonraker.log.2026-01-01" "$WORK/maintenance/logs/old.log.1"; do
	[ -e "$f" ] && fail "old rotated copy kept: $f" || pass
done

# G60: small append-only NebulaOS logs are bounded
mkdir -p "$WORK/maintenance/logs" "$WORK/system/diagnostics"
seq 1 100000 > "$WORK/maintenance/logs/camera-seed.log"
seq 1 10 > "$WORK/system/diagnostics/data-fs.log"
seq 1 100000 > "$WORK/maintenance/retention.log"
env NEBULAOS_RETENTION_NO_AUTORUN=1 NEBULAOS_ROOT="$WORK" LOG="$WORK/maintenance/retention.log" \
	LOCKDIR="$WORK/updates/locks" SHARED_GCODES="$WORK/printer_data/gcodes" \
	sh -c ". '$RETENTION_SCRIPT'; trim_small_logs"
[ "$(wc -l < "$WORK/maintenance/logs/camera-seed.log")" -eq 2000 ] && [ "$(tail -n 1 "$WORK/maintenance/logs/camera-seed.log")" = 100000 ] && pass || fail "seed log not trimmed to its last 2000 lines"
[ "$(wc -l < "$WORK/system/diagnostics/data-fs.log")" -eq 10 ] && pass || fail "small log touched"
[ "$(wc -l < "$WORK/maintenance/retention.log")" -le 2010 ] && pass || fail "retention.log not trimmed"
grep -q "trim_small_logs" "$RETENTION_SCRIPT" && [ "$(grep -c '^	trim_small_logs$\|^		trim_small_logs$' "$RETENTION_SCRIPT")" -eq 2 ] && pass || fail "not run in both paths"

echo "nebulaos-retention-live-log-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
