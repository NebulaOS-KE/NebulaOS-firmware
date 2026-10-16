#!/bin/sh
# G60 (2026-10-16): the general log level reaches syslogd (-l), Moonraker's
# start picks -v at debug, memguard's routine lines are debug priority, and
# the saved clock is restored at boot (never backwards) and saved on stop.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
O="$ROOT/scripts/build/overlay"
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
W=$(mktemp -d "${TMPDIR:-/tmp}/loglevel.XXXXXX") || exit 1
[ -n "$W" ] && [ -d "$W" ] || exit 1
trap 'rm -rf "$W"' EXIT

for pair in "info:-l 7" "warning:-l 5" "debug:-l 8" ":-l 7" "nonsense:-l 7"; do
	lvl=${pair%%:*}; want=${pair#*:}
	printf '%s\n' "$lvl" > "$W/level"
	args=$(NEBULAOS_LOG_LEVEL_FILE="$W/level" sh -c ". '$O/etc/default/syslogd' 2>/dev/null; echo \"\$SYSLOGD_ARGS\"")
	case "$args" in *"$want") pass ;; *) fail "level '$lvl' gave '$args'" ;; esac
done
grep -q 'log-level 2>/dev/null)" = debug ] && MOONRAKER_VERBOSE=-v' "$O/etc/init.d/S56moonraker" && pass || fail "moonraker -v at debug"
grep -q 'mg_debug "adj ' "$O/usr/libexec/nebulaos-memguard" && grep -q 'logger -t memguard -p user.debug' "$O/usr/libexec/nebulaos-memguard" \
	&& pass || fail "memguard adj lines not at debug priority"

# clock: fake date records what it was asked to set
mkdir -p "$W/bin"
cat > "$W/bin/date" <<EOT
#!/bin/sh
case "\$*" in
	"-u +%s") cat "$W/now" ;;
	"-u -s @"*) echo "\${3#@}" > "$W/set" ;;
	*) echo "date \$*" ;;
esac
EOT
chmod +x "$W/bin/date"
clock() { PATH="$W/bin:$PATH" NEBULAOS_CLOCK_FILE="$W/saved" sh "$O/etc/init.d/S01restore-clock" "$@" >/dev/null 2>&1; }
echo 1583020800 > "$W/now"; echo 1792100000 > "$W/saved"; rm -f "$W/set"
clock start; [ "$(cat "$W/set" 2>/dev/null)" = 1792100000 ] && pass || fail "saved time not restored"
echo 1792200000 > "$W/now"; rm -f "$W/set"
clock start; [ ! -e "$W/set" ] && pass || fail "clock set backwards"
clock stop; [ "$(cat "$W/saved")" = 1792200000 ] && pass || fail "stop did not save"
echo garbage > "$W/saved"; echo 1583020800 > "$W/now"; rm -f "$W/set"
clock start; [ ! -e "$W/set" ] && pass || fail "garbage saved time used"
# rcS runs S??* in C sort order; S01syslogd comes from Buildroot's busybox package
[ "$(printf '%s\n' S01syslogd S01restore-clock S01persistent-datastore | LC_ALL=C sort | tr '\n' ' ')" \
	= "S01persistent-datastore S01restore-clock S01syslogd " ] && [ -x "$O/etc/init.d/S01restore-clock" ] \
	&& pass || fail "S01restore-clock must run after the data partition, before syslogd"

echo "log-level-and-clock-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
