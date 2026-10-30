#!/bin/sh
#
# G82 stage 3: the update supervisor's "nebulascreen" component - a release
# downloaded by Moonraker's update_manager (type: zip) into
# apps/nebulascreen is checked (stage 1), activated only on an idle printer,
# health-checked (stage 2: runs from the bound binary + reported its
# version), and rolled back to the last-known-good release or to the image's
# own screen. Sandbox only: the real supervisor, the real
# /etc/nebulascreen-lib.sh and the real release check, against a fake S58
# (hard links stand in for the per-item binds, so "runs from the bound
# binary" is the same inode test as on the printer), a fake Moonraker (wget)
# and fake screen processes.
#
# Usage: sh tests/update-supervisor-nebulascreen-tests.sh
set -u
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OV="$REPO_ROOT/scripts/build/overlay"
SUP="$OV/etc/nebulaos-update-supervisor.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/update-supervisor-nebulascreen.XXXXXX") || exit 1
[ -n "$WORK" ] && [ -d "$WORK" ] || exit 1
cleanup() {
	[ -f "$WORK/pids" ] && while read -r p; do kill "$p" 2>/dev/null; done < "$WORK/pids"
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
PASS=0 FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }
t() { if eval "$2"; then pass; else fail "$1"; fi; }

# G91: the real shared busy check (fast shell variant); Klippy's pidfile and
# socket are the sandbox's (absent unless a test says so).
export BUSY_LIB="$OV/etc/nebulaos-busy.sh" NB_KLIPPY_PIDFILE="$WORK/klippy.pid" \
	NB_KLIPPY_SOCK="$WORK/klippy.sock"
export NEBULAOS_UPDATE_SUPERVISOR_NO_AUTORUN=1 \
	NEBULAOS_ROOT="$WORK/data/nebulaos" NEBULAOS_RUN_DIR="$WORK/run" \
	MOONRAKER_URL="http://moonraker.test" \
	NS_OPT_DIR="$WORK/opt/nebulascreen" NS_S58="$WORK/bin/S58nebulascreen" \
	NS_PIDFILE="$WORK/run/nebulascreen.pid" \
	NEBULASCREEN_LIB="$OV/etc/nebulascreen-lib.sh" \
	NS_RELEASE_CHECK="$OV/usr/libexec/nebulaos/nebulascreen-release-check" \
	NS_IMAGE_VERSION="$WORK/opt/nebulaos-version.json" \
	NS_SEED_INFO="$WORK/image/nebulascreen/release_info.json" \
	NS_SCREEN_LOG="$WORK/logs/nebulascreen.log" \
	NS_SETTLE_SECONDS=0 NS_HEALTH_TIMEOUT=600 REFRESH_PAUSE=0 REFRESH_TRIES=1 \
	NS_MOUNT="$WORK/bin/fakemount" NS_UMOUNT="$WORK/bin/fakeumount" \
	NS_MOUNTS="$WORK/mounts" NS_MOONRAKER_INCLUDE="$WORK/nebulaos.conf" WORK
APP="$NEBULAOS_ROOT/apps/nebulascreen"
STATE="$NEBULAOS_ROOT/updates/nebulascreen/state.json"
BACKUP="$NEBULAOS_ROOT/backups/nebulascreen/last-known-good"
REPORT="$NEBULAOS_RUN_DIR/nebulascreen-report.json"
export APP STATE REPORT
mkdir -p "$WORK/bin" "$WORK/image/nebulascreen" "$WORK/imagefiles" "$WORK/logs"
echo "screen log line" > "$NS_SCREEN_LOG"
# [update_manager nebulascreen] enabled (stage 4 include active) unless a
# test says otherwise.
configured() { echo '[include /etc/nebulaos/moonraker/nebulascreen-update.conf]' > "$NS_MOONRAKER_INCLUDE"; }
unconfigured() { echo '# [include /etc/nebulaos/moonraker/nebulascreen-update.conf]' > "$NS_MOONRAKER_INCLUDE"; }
configured

# --- fixtures ---------------------------------------------------------------
# A minimal ELF32 executable: MACHINE (8 = MIPS), DYNAMIC adds a PT_INTERP;
# the "screen" reports the VERSION= marker baked in after the headers.
mk_elf() { # FILE VERSION [MACHINE] [dynamic]
	python3 -I - "$@" <<'EOF'
import struct, sys
path, version = sys.argv[1], sys.argv[2]
machine = int(sys.argv[3]) if len(sys.argv) > 3 else 8
dynamic = len(sys.argv) > 4 and sys.argv[4] == "dynamic"
phnum = 2 if dynamic else 1
ident = b"\x7fELF" + bytes([1, 1, 1]) + bytes(9)
hdr = ident + struct.pack("<HHIIIIIHHHHHH", 2, machine, 1, 0x400000, 52, 0, 0,
                          52, 32, phnum, 40, 0, 0)
ph = struct.pack("<IIIIIIII", 1, 0, 0x400000, 0x400000, 0, 0, 5, 0x1000)
if dynamic:
    ph += struct.pack("<IIIIIIII", 3, 0, 0, 0, 0, 0, 4, 1)
with open(path, "wb") as fh:
    fh.write(hdr + ph + ("\nVERSION=%s\n" % version).encode())
EOF
	chmod 755 "$1"
}

mk_info() { # FILE VERSION [UI_API] [PROJECT]
	python3 -I -c '
import json, sys
info = {"project_name": sys.argv[4], "project_owner": "NebulaOS-KE",
        "version": sys.argv[2], "nebulaos_ui_api": int(sys.argv[3])}
open(sys.argv[1], "w").write(json.dumps(info, indent=2, sort_keys=True) + "\n")
' "$1" "$2" "${3:-1}" "${4:-NebulaOS-nebulascreen}"
}

# A release as Moonraker extracts it. Options: api=N machine=N dynamic
# noreport (the screen never reports) incomplete symlink config extra=NAME
# token=VALUE
mk_release() { # DIR VERSION [OPTION...]
	_d="$1" _v="$2"
	shift 2
	_api=1 _mach=8 _dyn='' _rv="$_v"
	for _o in "$@"; do
		case "$_o" in
			api=*) _api=${_o#api=} ;;
			machine=*) _mach=${_o#machine=} ;;
			dynamic) _dyn=dynamic ;;
			noreport) _rv="NOREPORT" ;;
		esac
	done
	mkdir -p "$_d/themes"
	mk_elf "$_d/nebulascreen" "$_rv" "$_mach" $_dyn
	mk_elf "$_d/nebulabeep" "$_v" "$_mach"
	echo '{"name": "default"}' > "$_d/themes/default.json"
	mk_info "$_d/release_info.json" "$_v" "$_api"
	echo "GPL-3" > "$_d/LICENSE"
	echo "based on GuppyScreen" > "$_d/NOTICE"
	for _o in "$@"; do
		case "$_o" in
			incomplete) rm -f "$_d/nebulabeep" ;;
			truncated) head -c 60 "$_d/nebulascreen" > "$_d/x" && mv "$_d/x" "$_d/nebulascreen" && chmod 755 "$_d/nebulascreen" ;;
			nolicense) rm -f "$_d/LICENSE" ;;
			symlink) ln -s /etc/passwd "$_d/themes/link.json" ;;
			config) echo '{}' > "$_d/nebulascreen.json" ;;
			extra=*) echo x > "$_d/${_o#extra=}" ;;
			token=*) echo "${_o#token=}" > "$_d/.nebulaos-approved" ;;
		esac
	done
}

# Moonraker's update_manager: rmtree + extract, then restart the managed
# service nebulascreen (supervisorctl -> S58 restart).
moonraker_install() { # VERSION [OPTION...]
	rm -rf "$APP"
	mk_release "$APP" "$@"
	"$NS_S58" stop; "$NS_S58" start
}

# The image: its own screen v0.9.0 in /opt/nebulascreen, the seed record.
mk_elf "$WORK/imagefiles/nebulascreen" v0.9.0
mk_elf "$WORK/imagefiles/nebulabeep" v0.9.0
mk_info "$NS_SEED_INFO" v0.9.0
write_image_version() { # FIRMWARE_SHA [UI_API|none]
	{
		echo "{"
		echo "  \"version\": \"0.9.0\","
		echo "  \"build_date\": \"2026-10-20T10:00:00Z\","
		if [ "${2:-1}" = none ]; then
			echo "  \"firmware_sha\": \"$1\""
		else
			echo "  \"firmware_sha\": \"$1\","
			echo "  \"nebulaos_ui_api\": ${2:-1}"
		fi
		echo "}"
	} > "$NS_IMAGE_VERSION"
}

# Fake binds: a file "bind" is a hard link (same inode, like a bind), the
# unbind puts the image's own file back (a new inode, like the image's).
cat > "$WORK/bin/fakemount" <<'EOF'
#!/bin/sh
[ "$1" = --bind ] || exit 1
if [ -f "$2" ]; then ln -f "$2" "$3" || exit 1; fi
echo "fake $3 none bind 0 0" >> "$NS_MOUNTS"
EOF
cat > "$WORK/bin/fakeumount" <<'EOF'
#!/bin/sh
grep -v " $1 " "$NS_MOUNTS" > "$NS_MOUNTS.tmp" 2>/dev/null; mv -f "$NS_MOUNTS.tmp" "$NS_MOUNTS"
b=$(basename "$1")
if [ -f "$WORK/imagefiles/$b" ]; then rm -f "$1"; cp "$WORK/imagefiles/$b" "$1"; fi
exit 0
EOF
# S58nebulascreen, the real logic (image wins, approved-only activation,
# deactivate on stop) with a fake screen process: it reports the version of
# the binary that is in place, unless that build never reports.
cat > "$WORK/bin/S58nebulascreen" <<'EOF'
#!/bin/sh
. "$NEBULASCREEN_LIB"
ns_log() { echo "S58: $*" >> "$WORK/s58.log"; }
case "$1" in
start)
	echo start >> "$WORK/s58.calls"
	ns_image_wins "$APP" "$STATE" "$NS_IMAGE_VERSION" "$NS_SEED_INFO"
	ns_activate "$APP" "$NS_OPT_DIR" "$STATE"
	sleep 300 &
	echo $! > "$NS_PIDFILE"; echo $! >> "$WORK/pids"
	v=$(grep -a '^VERSION=' "$NS_OPT_DIR/nebulascreen" | head -1 | cut -d= -f2)
	if [ "$v" != NOREPORT ] && [ -z "${SCREEN_SILENT:-}" ]; then
		mkdir -p "$(dirname "$REPORT")"
		printf '{\n  "name": "nebulascreen",\n  "nebulaos_ui_api": 1,\n  "version": "%s"\n}\n' "$v" > "$REPORT"
	fi
	;;
stop)
	echo stop >> "$WORK/s58.calls"
	kill "$(cat "$NS_PIDFILE" 2>/dev/null)" 2>/dev/null; rm -f "$NS_PIDFILE"
	ns_deactivate "$NS_OPT_DIR"
	;;
esac
exit 0
EOF
chmod +x "$WORK/bin/"*

# A fresh printer on this image: boot runs S58 start.
setup() {
	[ -f "$WORK/pids" ] && while read -r p; do kill "$p" 2>/dev/null; done < "$WORK/pids"
	rm -rf "$NEBULAOS_ROOT" "$NEBULAOS_RUN_DIR" "$WORK/opt" "$WORK/s58.calls" "$WORK/log" \
		"$WORK/wget.calls" "$WORK/pids"
	mkdir -p "$NEBULAOS_RUN_DIR/memguard" "$NEBULAOS_RUN_DIR/shed" "$NS_OPT_DIR/themes" "$APP"
	cp "$WORK/imagefiles/nebulascreen" "$WORK/imagefiles/nebulabeep" "$NS_OPT_DIR/"
	: > "$NS_MOUNTS"
	write_image_version d4f9b38 "${1:-1}"
	PRINT_STATE=standby UM_BUSY=false MR_DOWN=
	"$NS_S58" start
}
restarts() { grep -c '^start' "$WORK/s58.calls" 2>/dev/null || echo 0; }
reported() { sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$REPORT" 2>/dev/null; }
field() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "$STATE" 2>/dev/null | head -1; }
waitfor() { _i=0; while [ "$_i" -lt 50 ] && ! grep -q "$2" "$1" 2>/dev/null; do sleep 0.1; _i=$((_i + 1)); done; }

# shellcheck disable=SC1090
. "$SUP" >/dev/null 2>&1
log() { echo "LOG: $*" >> "$WORK/log"; }
# The fake Moonraker.
wget() {
	for _a in "$@"; do _url="$_a"; done
	echo "$_url" >> "$WORK/wget.calls"
	[ -z "${MR_DOWN:-}" ] || return 1
	case "$_url" in
		*/server/info)
			[ -z "${SERVER_INFO_DOWN:-}" ] || return 1
			printf '{"result":{"klippy_state":"%s","klippy_connected":true}}' "${KLIPPY_STATE:-ready}" ;;
		*/printer/objects/query*)
			printf '{"result":{"eventtime":1.0,"status":{"print_stats":{"state":"%s"},"idle_timeout":{"state":"Idle"},"extruder":{"target":%s},"heater_bed":{"target":0.0}}}}' \
				"$PRINT_STATE" "${EXTRUDER_TARGET:-0.0}" ;;
		*/machine/update/status) printf '{"result":{"busy":%s}}' "$UM_BUSY" ;;
		*/machine/update/refresh?name=nebulascreen)
			# Moonraker without the section: no such updater
			grep -qx '\[include /etc/nebulaos/moonraker/nebulascreen-update.conf\]' "$NS_MOONRAKER_INCLUDE" \
				|| { echo "No updater registered for nebulascreen" >&2; return 1; }
			echo "$_url" >> "$WORK/refreshes" ;;
		*/machine/update/refresh*) echo "$_url" >> "$WORK/refreshes" ;;
	esac
	return 0
}

# --- the image's screen, bootstrap ------------------------------------------
setup
t "boot: the image's screen runs and reports" '[ "$(reported)" = v0.9.0 ]'
t "boot: S58 stamped the image identity" '[ "$(field image_identity)" = "d4f9b38@2026-10-20T10:00:00Z" ]'
mkdir -p "$BACKUP"; echo stale > "$BACKUP/release_info.json"
rm -f "$WORK/refreshes"
poll_nebulascreen_once
t "bootstrap: image's screen is known-good" \
	'[ "$(field state)" = healthy ] && [ "$(field known_good_version)" = v0.9.0 ] && [ "$(field known_good_source)" = image ]'
t "bootstrap: a backup from before is dropped" '[ ! -e "$BACKUP" ]'
t "bootstrap: image_identity kept" '[ "$(field image_identity)" = "d4f9b38@2026-10-20T10:00:00Z" ]'
waitfor "$WORK/refreshes" "name=nebulascreen"
t "bootstrap: Moonraker's view refreshed" 'grep -q "name=nebulascreen" "$WORK/refreshes"'
n=$(restarts); poll_nebulascreen_once
t "image mode: a quiet poll restarts nothing" '[ "$(restarts)" = "$n" ] && [ "$(field state)" = healthy ]'

# --- a good release activates -------------------------------------------------
moonraker_install v0.9.1
t "Moonraker's restart: an unchecked release is NOT bound" \
	'[ "$(reported)" = v0.9.0 ] && [ ! -s "$NS_MOUNTS" ]'
n=$(restarts)
poll_nebulascreen_once
t "good release: activated by one restart" '[ "$(restarts)" = $((n + 1)) ]'
t "good release: runs and reported v0.9.1" '[ "$(reported)" = v0.9.1 ]'
t "good release: bound per item" '[ "$(grep -c " bind " "$NS_MOUNTS")" = 3 ]'
t "good release: recorded as known-good" \
	'[ "$(field state)" = healthy ] && [ "$(field known_good_version)" = v0.9.1 ] && [ "$(field known_good_source)" = release ]'
t "good release: last-known-good backup taken" '[ "$(ns_release_version "$BACKUP")" = v0.9.1 ] && [ -x "$BACKUP/nebulascreen" ]'
t "good release: approval token in app dir and state" \
	'[ -n "$(field approved_token)" ] && [ "$(cat "$APP/.nebulaos-approved")" = "$(field approved_token)" ]'
t "state.json keys preserved (image_identity)" '[ "$(field image_identity)" = "d4f9b38@2026-10-20T10:00:00Z" ]'
n=$(restarts); poll_nebulascreen_once
t "healthy release: next poll does nothing" '[ "$(restarts)" = "$n" ]'
"$NS_S58" stop; "$NS_S58" start
t "reboot: S58 binds the approved release again" '[ "$(reported)" = v0.9.1 ]'

# A foreign key survives every merge.
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["foo"]="bar"; json.dump(d, open(sys.argv[1], "w"), indent=2)' "$STATE"

# --- wrong ui_api: refused, last-known-good restored --------------------------
rm -f "$WORK/refreshes"
moonraker_install v0.9.2 api=2
n=$(restarts)
poll_nebulascreen_once
t "ui_api 2 on a ui_api 1 image: refused, v0.9.1 restored" \
	'[ "$(ns_release_version "$APP")" = v0.9.1 ] && [ "$(reported)" = v0.9.1 ]'
t "refused release: rolled back (one restart, idle)" '[ "$(field state)" = rolled-back ] && [ "$(restarts)" = $((n + 1)) ]'
t "refused release: reason recorded" 'field last_failure_reason | grep -q "^stage1_failed:v0.9.2"'
t "refused release: evidence kept" 'grep -q "nebulaos_ui_api 2" "$NEBULAOS_ROOT"/backups/nebulascreen/failed-*/stage1-problems.txt'
waitfor "$WORK/refreshes" "name=nebulascreen"
t "rollback: Moonraker's update manager refreshed" 'grep -q "name=nebulascreen" "$WORK/refreshes"'
t "merge kept a foreign key and the stamp" '[ "$(field foo)" = bar ] && [ -n "$(field image_identity)" ]'

# --- non-MIPS / dynamic / other refusals, no backup -> image's screen ---------
for bad in "machine=62:not MIPS" "dynamic:dynamically linked" "symlink:symlink in the release" \
		"config:settings file" "extra=install.sh:unexpected entry" \
		"truncated:is truncated" "nolicense:missing LICENSE"; do
	opt=${bad%%:*} why=${bad#*:}
	setup; poll_nebulascreen_once
	moonraker_install v0.9.1 "$opt"
	n=$(restarts)
	poll_nebulascreen_once
	t "$opt: refused" 'grep -rq "$why" "$NEBULAOS_ROOT"/backups/nebulascreen/failed-*/stage1-problems.txt'
	t "$opt: no backup -> app dir reset to the image seed" \
		'[ "$(ls -A "$APP")" = release_info.json ] && cmp -s "$APP/release_info.json" "$NS_SEED_INFO"'
	t "$opt: image's screen, factory-fallback" \
		'[ "$(field state)" = factory-fallback ] && [ "$(reported)" = v0.9.0 ] && [ ! -s "$NS_MOUNTS" ]'
	t "$opt: never activated" '! grep -q "v0.9.1 passed stage 1" "$WORK/log"'
done
n=$(restarts); poll_nebulascreen_once
t "after the fallback: no loop" '[ "$(restarts)" = "$n" ] && [ "$(field state)" = factory-fallback ]'

# An image without nebulaos_ui_api never accepts a release.
setup none; poll_nebulascreen_once
moonraker_install v0.9.1
poll_nebulascreen_once
t "image without nebulaos_ui_api: release refused" \
	'grep -q "states no nebulaos_ui_api" "$NEBULAOS_ROOT"/backups/nebulascreen/failed-*/stage1-problems.txt && [ "$(reported)" = v0.9.0 ]'

# --- incomplete release -------------------------------------------------------
setup; poll_nebulascreen_once
UM_BUSY=true
moonraker_install v0.9.1 incomplete
st=$(cat "$STATE"); n=$(restarts)
poll_nebulascreen_once
t "incomplete while Moonraker is busy: ignored (no change, no restart)" \
	'[ "$(cat "$STATE")" = "$st" ] && [ "$(restarts)" = "$n" ] && [ -e "$APP/nebulascreen" ]'
t "incomplete: S58 never bound it" '[ ! -s "$NS_MOUNTS" ] && [ "$(reported)" = v0.9.0 ]'
UM_BUSY=false
poll_nebulascreen_once
t "incomplete after Moonraker finished: refused, image seed restored" \
	'[ "$(ls -A "$APP")" = release_info.json ] && field last_failure_reason | grep -q "^incomplete_release"'
MR_DOWN=1
moonraker_install v0.9.1
st=$(cat "$STATE"); n=$(restarts)
poll_nebulascreen_once
t "Moonraker unreachable: a download is not judged" '[ "$(cat "$STATE")" = "$st" ] && [ "$(restarts)" = "$n" ]'
MR_DOWN=

# --- printing: activation deferred, never a restart --------------------------
setup; poll_nebulascreen_once
moonraker_install v0.9.1
for busy in "PAUSED:" "PRINTING:print-active" "LOW_MEMORY:memguard/deny-maintenance" \
		"LOW_MEMORY:shed/nebulascreen" "UNKNOWN:"; do
	why=${busy%%:*} marker=${busy#*:}
	# UNKNOWN: Moonraker's server/info does not answer (fail-closed)
	case "$why" in
		PAUSED) PRINT_STATE=paused ;;
		UNKNOWN) SERVER_INFO_DOWN=1 ;;
		*) : > "$NEBULAOS_RUN_DIR/$marker" ;;
	esac
	n=$(restarts)
	poll_nebulascreen_once; poll_nebulascreen_once
	t "$why: activation deferred, no restart" \
		'[ "$(restarts)" = "$n" ] && [ "$(field state)" = pending ] && [ "$(field busy_reason)" = "$why" ]'
	t "$why: nothing approved, image's screen" '[ -z "$(field approved_token)" ] && [ "$(reported)" = v0.9.0 ]'
	PRINT_STATE=standby SERVER_INFO_DOWN=
	[ -n "$marker" ] && rm -f "$NEBULAOS_RUN_DIR/$marker"
done
t "deferral logged once per reason, not every poll" \
	'[ "$(grep -c "activation of v0.9.1 deferred (PAUSED)\|v0.9.1 passed stage 1 - activation deferred (PAUSED)" "$WORK/log")" = 1 ]'
n=$(restarts)
poll_nebulascreen_once
t "print over: activated on the next poll" \
	'[ "$(restarts)" = $((n + 1)) ] && [ "$(field state)" = healthy ] && [ "$(reported)" = v0.9.1 ]'

# The real busy check reads Moonraker: paused counts, Klippy not ready does not.
PRINT_STATE=paused; t "busy: paused" '[ "$(ns_busy_reason)" = PAUSED ]'
PRINT_STATE=printing; t "busy: printing" '[ "$(ns_busy_reason)" = PRINTING ]'
PRINT_STATE=standby; t "idle: standby" '! ns_busy_reason >/dev/null'
MR_DOWN=1; t "busy: Moonraker unreachable (fail-closed)" '[ "$(ns_busy_reason)" = UNKNOWN ]'; MR_DOWN=
# G91: the shared check - heating counts, a Klippy that is not ready does not
# (even with memguard's sticky marker, R3), an unreadable live Klippy does.
EXTRUDER_TARGET=210.0; t "busy: heating (ACTIVE)" '[ "$(ns_busy_reason)" = ACTIVE ]'; EXTRUDER_TARGET=
: > "$NEBULAOS_RUN_DIR/print-active"
t "busy: print-active marker with a ready Klippy" '[ "$(ns_busy_reason)" = PRINTING ]'
KLIPPY_STATE=shutdown; t "idle: Klippy shut down overrides the marker" '! ns_busy_reason >/dev/null'
rm -f "$NEBULAOS_RUN_DIR/print-active"; KLIPPY_STATE=

# --- the screen never reports: rollback, but never under a print -------------
rm -f "$WORK/refreshes"
moonraker_install v0.9.2 noreport
poll_nebulascreen_once
t "silent release: on trial (validating)" '[ "$(field state)" = validating ] && [ "$(field trial_version)" = v0.9.2 ]'
NS_HEALTH_TIMEOUT=0
PRINT_STATE=printing; n=$(restarts)
poll_nebulascreen_once
t "health timeout during a print: no rollback, no restart" \
	'[ "$(field state)" = validating ] && [ "$(restarts)" = "$n" ] && [ "$(field busy_reason)" = PRINTING ]'
PRINT_STATE=standby
poll_nebulascreen_once
t "after the print: rolled back to v0.9.1" \
	'[ "$(field state)" = rolled-back ] && [ "$(reported)" = v0.9.1 ] && [ "$(ns_release_version "$APP")" = v0.9.1 ]'
t "stage-2 failure evidence kept" 'grep -lq "reason=stage2_failed" "$NEBULAOS_ROOT"/backups/nebulascreen/failed-*/metadata.txt && ls "$NEBULAOS_ROOT"/backups/nebulascreen/failed-*/nebulascreen.log >/dev/null'
waitfor "$WORK/refreshes" "name=nebulascreen"
t "stage-2 rollback: Moonraker refreshed" 'grep -q "name=nebulascreen" "$WORK/refreshes"'
NS_HEALTH_TIMEOUT=600

# Re-download of the SAME version (Moonraker recover): checked again, not
# bound on the strength of the version string.
moonraker_install v0.9.1
t "same-version re-download: not bound before the check" '[ "$(reported)" = v0.9.0 ]'
poll_nebulascreen_once
t "same-version re-download: checked and activated" '[ "$(field state)" = healthy ] && [ "$(reported)" = v0.9.1 ]'
moonraker_install v0.9.3 token=guessed
t "a zip carrying an approval file is not bound" '[ "$(reported)" = v0.9.0 ]'
poll_nebulascreen_once
t "...and is checked like any download" '[ "$(field state)" = healthy ] && [ "$(reported)" = v0.9.3 ]'

# --- rollback target missing / unhealthy -> the image's screen ----------------
rm -rf "$BACKUP"
moonraker_install v0.9.4 noreport
poll_nebulascreen_once; NS_HEALTH_TIMEOUT=0
poll_nebulascreen_once
t "no last-known-good: image's screen" \
	'[ "$(field state)" = factory-fallback ] && [ "$(reported)" = v0.9.0 ] && [ ! -s "$NS_MOUNTS" ] && [ "$(ls -A "$APP")" = release_info.json ]'
NS_HEALTH_TIMEOUT=600
moonraker_install v0.9.1; poll_nebulascreen_once
mk_elf "$BACKUP/nebulascreen" NOREPORT          # the backup no longer reports
moonraker_install v0.9.2 noreport
poll_nebulascreen_once; NS_HEALTH_TIMEOUT=0
poll_nebulascreen_once
t "rollback target restored and tried" 'grep -q "restoring the last-known-good release v0.9.1" "$WORK/log"'
t "rollback target unhealthy too: image's screen" \
	'[ "$(field state)" = factory-fallback ] && field last_failure_reason | grep -q "^previous_also_unhealthy" && [ "$(reported)" = v0.9.0 ]'
NS_HEALTH_TIMEOUT=600

# A refusal while a print is paused (Moonraker does not refuse updates while
# paused): the last-known-good files are restored and approved at once, the
# screen restart waits for the print.
setup; poll_nebulascreen_once
moonraker_install v0.9.1; poll_nebulascreen_once
PRINT_STATE=paused
moonraker_install v0.9.2 api=2
n=$(restarts)
poll_nebulascreen_once
t "refusal during a paused print: files restored + approved, no restart" \
	'[ "$(field state)" = rolling-back ] && [ "$(field restart_pending)" = 1 ] && [ "$(restarts)" = "$n" ] && [ "$(ns_release_version "$APP")" = v0.9.1 ] && [ "$(field approved_version)" = v0.9.1 ]'
poll_nebulascreen_once
t "still paused: still no restart" '[ "$(restarts)" = "$n" ]'
PRINT_STATE=standby
poll_nebulascreen_once
t "print over: the pending restart runs, rollback completes" \
	'[ "$(restarts)" = $((n + 1)) ] && [ "$(field state)" = rolled-back ] && [ "$(reported)" = v0.9.1 ] && [ "$(field restart_pending)" = 0 ]'

# --- an image install still wins ---------------------------------------------
t "before the image install: a release and its backup" '[ -d "$BACKUP" ] && [ "$(reported)" = v0.9.1 ]'
write_image_version abc1234
"$NS_S58" stop; "$NS_S58" start                  # boot of the new image
t "new image: app dir reset to the seed, image's screen" \
	'[ "$(ls -A "$APP")" = release_info.json ] && [ "$(reported)" = v0.9.0 ] && [ ! -s "$NS_MOUNTS" ]'
t "new image: state.json is the new stamp only" '[ "$(field image_identity)" = "abc1234@2026-10-20T10:00:00Z" ] && [ -z "$(field state)" ]'
poll_nebulascreen_once
t "new image: re-bootstrapped, old backup dropped" \
	'[ "$(field state)" = healthy ] && [ "$(field known_good_source)" = image ] && [ ! -e "$BACKUP" ] && [ "$(field image_identity)" = "abc1234@2026-10-20T10:00:00Z" ]'

# --- supervisor restart mid-trial ---------------------------------------------
moonraker_install v0.9.1 noreport; poll_nebulascreen_once
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["trial_started"]="1"; json.dump(d, open(sys.argv[1], "w"), indent=2)' "$STATE"
reconcile_stale_component_locks_on_boot
t "generic stale-lock reconcile leaves the screen's trial alone" '[ "$(field state)" = validating ] && [ -n "$(field image_identity)" ]'
ns_reconcile_on_boot
t "boot reconcile: the trial gets a fresh health window" '[ "$(field trial_started)" -gt 1 ]'

# --- interrupted restore into the app dir -------------------------------------
setup; poll_nebulascreen_once
mv "$APP" "$APP.old"; mkdir -p "$APP.staging"
cleanup_stale_staging
t "interrupted restore: the app dir is put back" '[ -f "$APP/release_info.json" ] && [ ! -e "$APP.old" ] && [ ! -e "$APP.staging" ]'

# --- review F1: a failed copy is never swapped in ------------------------------
mkdir -p "$WORK/adr/src" "$WORK/adr/dst"; echo keep > "$WORK/adr/dst/f"
echo secret > "$WORK/adr/src/f"; chmod 000 "$WORK/adr/src/f"
if [ "$(id -u)" != 0 ]; then
	atomic_directory_replace "$WORK/adr/src" "$WORK/adr/dst" 2>/dev/null; rc=$?
	t "atomic replace: cp failure -> non-zero, target untouched, no staging" \
		'[ "$rc" != 0 ] && [ "$(cat "$WORK/adr/dst/f")" = keep ] && [ ! -e "$WORK/adr/dst.staging" ] && [ ! -e "$WORK/adr/dst.old" ]'
	setup; poll_nebulascreen_once
	moonraker_install v0.9.1; poll_nebulascreen_once
	chmod 000 "$BACKUP/themes/default.json"
	moonraker_install v0.9.2 api=2; poll_nebulascreen_once
	t "rollback whose restore copy fails: image's screen, not a partial copy" \
		'[ "$(field state)" = factory-fallback ] && field last_failure_reason | grep -q "restore_copy_failed" && [ "$(reported)" = v0.9.0 ]'
	chmod 644 "$BACKUP/themes/default.json" 2>/dev/null
fi
chmod 644 "$WORK/adr/src/f"
atomic_directory_replace "$WORK/adr/src" "$WORK/adr/dst"; rc=$?
t "atomic replace: success -> 0, new content" '[ "$rc" = 0 ] && [ "$(cat "$WORK/adr/dst/f")" = secret ]'
t "mainsail/venv callers check the result" \
	'grep -q "if ! atomic_directory_replace \"\$MAINSAIL_BACKUP\" \"\$path\"" "$SUP" && sed -n "/^moonraker_restore_env() {/,/^}/p" "$SUP" | tail -2 | grep -q "atomic_directory_replace"'
# The restored copy is checked again (whole files) before it is approved.
setup; poll_nebulascreen_once
moonraker_install v0.9.1; poll_nebulascreen_once
atomic_directory_replace() {
	rm -rf "$2"; cp -a "$1" "$2"
	if [ "$2" = "$APP" ]; then head -c 60 "$1/nebulascreen" > "$2/nebulascreen"; fi
	return 0
}
moonraker_install v0.9.2 api=2; poll_nebulascreen_once
t "restored copy that fails stage 1: not approved, image's screen" \
	'[ "$(field state)" = factory-fallback ] && field last_failure_reason | grep -q "restored_copy_invalid" && [ "$(reported)" = v0.9.0 ]'
unset -f atomic_directory_replace; . "$SUP" >/dev/null 2>&1
log() { echo "LOG: $*" >> "$WORK/log"; }

# --- review F2: changed after stage 1 -> not approved ---------------------------
setup; poll_nebulascreen_once
moonraker_install v0.9.1
ns_busy_reason() { echo late > "$APP/themes/late.json"; return 1; }
poll_nebulascreen_once
t "changed between stage 1 and approval: not activated" \
	'[ -z "$(field approved_token)" ] && [ "$(reported)" = v0.9.0 ] && grep -q "changed after stage 1" "$WORK/log"'
unset -f ns_busy_reason; . "$SUP" >/dev/null 2>&1
log() { echo "LOG: $*" >> "$WORK/log"; }
poll_nebulascreen_once
t "...checked again and activated on the next poll" '[ "$(field state)" = healthy ] && [ "$(reported)" = v0.9.1 ]'

# --- review F4: same-version re-download during a print is remembered -----------
PRINT_STATE=printing
moonraker_install v0.9.2; poll_nebulascreen_once
moonraker_install v0.9.2; poll_nebulascreen_once
t "same-version re-download while busy: its fingerprint is recorded" \
	'[ "$(field state)" = pending ] && [ "$(field pending_fingerprint)" = "$(ns_fingerprint)" ]'
ns_stage1() { echo "stage1 ran" >> "$WORK/stage1.calls"; return 1; }
poll_nebulascreen_once
t "...so the next poll does not redo the settle + stage 1" '[ ! -e "$WORK/stage1.calls" ] && [ "$(field state)" = pending ]'
unset -f ns_stage1; . "$SUP" >/dev/null 2>&1
log() { echo "LOG: $*" >> "$WORK/log"; }
PRINT_STATE=standby

# --- review F6: missing / empty app dir -> the seed, not a failed download -------
setup; poll_nebulascreen_once
rm -rf "$APP"
poll_nebulascreen_once
t "missing app dir: seed recreated, no failure recorded" \
	'cmp -s "$APP/release_info.json" "$NS_SEED_INFO" && [ "$(field state)" = healthy ] && ! ls "$NEBULAOS_ROOT"/backups/nebulascreen/failed-* >/dev/null 2>&1'
moonraker_install v0.9.1; poll_nebulascreen_once
find "$APP" -mindepth 1 -delete
poll_nebulascreen_once
t "emptied app dir of an active release: image's screen" \
	'[ "$(field state)" = factory-fallback ] && cmp -s "$APP/release_info.json" "$NS_SEED_INFO"'

# --- review F3: no refresh while the updater is not configured -----------------
unconfigured
setup; rm -f "$WORK/refreshes"
poll_nebulascreen_once
moonraker_install v0.9.1 api=2; poll_nebulascreen_once
reconcile_update_info_on_boot; sleep 0.3
t "not configured: Moonraker is never asked to refresh nebulascreen" \
	'[ "$(field state)" = factory-fallback ] && ! grep -q "refresh?name=nebulascreen" "$WORK/wget.calls"'
configured
ns_refresh_update_info "first poll on this image"
t "refresh log names the real reason" 'grep -q "refresh (first poll on this image)" "$WORK/log"'

# --- a crashed screen is started again (2026-10-30) ---------------------------
crash() { kill "$(cat "$NS_PIDFILE")" 2>/dev/null; sleep 0.2; }
setup; poll_nebulascreen_once; rm -f "$WORK/s58.calls"
ns_revive_crashed
t "running screen: no restart" '[ "$(restarts)" = 0 ]'
crash; ns_revive_crashed
t "crashed screen: started again" \
	'[ "$(restarts)" = 1 ] && [ -d "/proc/$(cat "$NS_PIDFILE")" ] && grep -q "ended without a stop" "$WORK/log"'
t "crashed screen: its log kept" '[ -s "$NEBULAOS_ROOT/maintenance/logs/nebulascreen-last-crash.log" ]'
"$NS_S58" stop; rm -f "$WORK/s58.calls"; ns_revive_crashed
t "stopped screen (S58 stop): left stopped" '[ "$(restarts)" = 0 ]'
"$NS_S58" start; : > "$NEBULAOS_RUN_DIR/shed/nebulascreen"; crash; rm -f "$WORK/s58.calls"
ns_revive_crashed
t "shed by memguard: left stopped" '[ "$(restarts)" = 0 ]'
rm -f "$NEBULAOS_RUN_DIR/shed/nebulascreen"
ns_set state=validating; ns_revive_crashed
t "during a release trial: left to the trial" '[ "$(restarts)" = 0 ]'
ns_set state=healthy
setup; poll_nebulascreen_once; rm -f "$WORK/s58.calls" "$WORK/log"
for _i in 1 2 3 4 5 6 7; do crash; ns_revive_crashed; done
t "at most NS_REVIVE_MAX restarts per boot" \
	'[ "$(restarts)" = "$NS_REVIVE_MAX" ] && [ "$(grep -c "crashed $NS_REVIVE_MAX times" "$WORK/log")" = 1 ]'
t "poll_once revives the screen" \
	'sed -n "/^poll_once() {/,/^}/p" "$SUP" | grep -q ns_revive_crashed'

# --- wiring -------------------------------------------------------------------
t "poll_once runs the nebulascreen component" \
	'sed -n "/^poll_once() {/,/^}/p" "$SUP" | grep -q poll_nebulascreen_once'
t "loop() reconciles the screen trial at start" \
	'sed -n "/^loop() {/,/^}/p" "$SUP" | grep -q ns_reconcile_on_boot'
t "S58 activates only an approved release" \
	'grep -q "ns_activate \"\$NS_APP\" \"\$NS_DIR\" \"\$NS_UPDATE_STATE\"" "$OV/etc/init.d/S58nebulascreen"'
t "the release check is executable on the image" '[ -x "$NS_RELEASE_CHECK" ]'
t "the screen restart never uses Klipper's or Moonraker's init scripts" \
	'! sed -n "/^ns_restart_screen() {/,/^}/p" "$SUP" | grep -q "S55\|S56"'

echo "update-supervisor-nebulascreen-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
