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

# The screen reads the level through the CLI (read-only path); found broken on
# the printer (KeyError 'logs', 2026-10-16).
printf 'debug\n' > "$W/level"
out=$(cd "$O/usr/lib/nebulaos/python" && NEBULAOS_LOG_LEVEL_FILE="$W/level" python3 -I -c \
	"import sys; sys.path.insert(0, '.'); from nebulaos_osconfig import cli; sys.exit(cli.main(['logs', 'status']))" 2>&1)
case "$out" in *'"level": "debug"'*'"ok": true'*) pass ;; *) fail "logs status via the CLI: $out" ;; esac

# G67: S01persistent-datastore restores the clock right after mounting /usr/data,
# before it creates anything or the data-partition check logs its result.
S01P="$O/etc/init.d/S01persistent-datastore"
_r=$(grep -n '^		restore_saved_clock$' "$S01P" | head -1 | cut -d: -f1)
_rec=$(grep -n '^		ndf_record$' "$S01P" | head -1 | cut -d: -f1)
_seed=$(grep -n 'seed_once /opt/printer_data' "$S01P" | head -1 | cut -d: -f1)
[ -n "$_r" ] && [ -n "$_rec" ] && [ -n "$_seed" ] && [ "$_r" -lt "$_rec" ] && [ "$_r" -lt "$_seed" ] \
	&& pass || fail "clock not restored before the data-partition record / first folders"
grep -q 'broken_system_clock = 1' "$O/etc/e2fsck.conf" && pass || fail "e2fsck.conf broken_system_clock"

# G68: the saved host name is set before syslogd starts (only that block of the
# defaults file is run here - the rest touches /var/log).
sed -n '/^# G68/,$p' "$O/etc/default/syslogd" > "$W/hostblock"
printf '#!/bin/sh\necho "$1" > "%s/hostname-set"\n' "$W" > "$W/bin/hostname"; chmod +x "$W/bin/hostname"
printf 'NNET_HOSTNAME=kitchen-ke\nNNET_MODE=dhcp\n' > "$W/boot.env"
PATH="$W/bin:$PATH" NNET_ENV="$W/boot.env" NEBULAOS_NETWORK_LIB="$O/etc/nebulaos-network.sh" sh "$W/hostblock"
[ "$(cat "$W/hostname-set" 2>/dev/null)" = kitchen-ke ] && pass || fail "saved host name not set before syslogd"
rm -f "$W/boot.env" "$W/hostname-set"
PATH="$W/bin:$PATH" NNET_ENV="$W/boot.env" NEBULAOS_NETWORK_LIB="$O/etc/nebulaos-network.sh" sh "$W/hostblock"
[ "$(cat "$W/hostname-set" 2>/dev/null)" = nebulaos ] && pass || fail "default host name not set before syslogd"

echo "log-level-and-clock-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
