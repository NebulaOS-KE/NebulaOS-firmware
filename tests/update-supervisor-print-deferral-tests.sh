#!/bin/sh
#
# G91 C1 fix (step 3): the update supervisor never validates, rolls back,
# recomposes, unmounts or restarts the Klipper stack under a print, and every
# deferral is honoured (a state across polls, never a timed-out wait whose
# result is ignored). The real supervisor, the real shared busy check
# (/etc/nebulaos-busy.sh) and the real compose/chelper libraries, against a
# fake Moonraker (wget on PATH), a stubbed health check that behaves like the
# real stage 2 (exit 3 while a print runs) and a stubbed S55klipper.
#
#   S4   a print runs when the update lands: no validation, no restart;
#        validated after the print
#   S5   (C1) a print starts right after the validation restart: stage 2
#        "deferred", no rollback, no second restart; validated after the print
#   S28  "Update all" applied partly (extensions done, Klipper refused):
#        the pair is validated after the print
#   S29  checkout done, reset refused (HEAD on another consistent commit):
#        the delta is validated after the print
#   rollback: a failed pair while a print runs -> rollback-pending (no git
#        reset, no restart, lock kept), run on the first idle poll
#   N4:  a Moonraker restart is not gated by a print
#
# Usage: sh tests/update-supervisor-print-deferral-tests.sh
set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OVERLAY_ETC="$REPO_ROOT/scripts/build/overlay/etc"
SUPERVISOR="$OVERLAY_ETC/nebulaos-update-supervisor.sh"
COMPOSE_LIB="$OVERLAY_ETC/nebulaos-klipper-compose.sh"
CHELPER_LIB="$OVERLAY_ETC/nebulaos-chelper-preflight.sh"
BUSY_LIB="$OVERLAY_ETC/nebulaos-busy.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/update-supervisor-print.XXXXXX")
[ -n "${WORK:-}" ] && [ -d "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost
PASS=0 FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
t() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

ROOT="$WORK/root"
KDIR="$ROOT/apps/klipper"
EDIR="$ROOT/apps/nebulaos-klipper-extensions"
LOCKS="$ROOT/updates/locks"
export HEALTH_DIR="$WORK/health"
mkdir -p "$HEALTH_DIR" "$WORK/bin" "$WORK/run" "$WORK/init.d"
# A Klippy process exists (this shell): the busy check asks Moonraker.
echo $$ > "$WORK/klippy.pid"

# The fake Moonraker: Klippy ready, print state from $HEALTH_DIR/print_state.
cat > "$WORK/bin/wget" <<'EOS'
#!/bin/sh
for a in "$@"; do url=$a; done
ps=$(cat "$HEALTH_DIR/print_state" 2>/dev/null || echo standby)
case "$url" in
	*/server/info) printf '{"result": {"klippy_state": "ready", "klippy_connected": true}}' ;;
	*/printer/objects/query*) printf '{"result": {"status": {"print_stats": {"state": "%s"}, "idle_timeout": {"state": "Idle"}, "extruder": {"target": 0.0}, "heater_bed": {"target": 0.0}}}}' "$ps" ;;
	*/machine/update/status) printf '{"result": {"busy": false}}' ;;
	*) : ;;
esac
exit 0
EOS
chmod +x "$WORK/bin/wget"

# Stage 2 like the real one: a print running -> 3 (deferred); stage1 may
# start a print (a print started during the validation).
cat > "$WORK/healthcheck.sh" <<'EOS'
#!/bin/sh
case "$1" in
	stage1)
		[ -e "$HEALTH_DIR/print_on_stage1" ] && echo printing > "$HEALTH_DIR/print_state"
		want=$(cat "$HEALTH_DIR/stage1" 2>/dev/null) ;;
	stage2)
		case "$(cat "$HEALTH_DIR/print_state" 2>/dev/null)" in printing|paused) echo "healthcheck stage2 -> deferred" >> "$HEALTH_DIR/calls.log"; exit 3 ;; esac
		want=$(cat "$HEALTH_DIR/stage2" 2>/dev/null) ;;
esac
echo "healthcheck $1 -> ${want:-ok}" >> "$HEALTH_DIR/calls.log"
[ "${want:-ok}" = ok ]
EOS
chmod +x "$WORK/healthcheck.sh"

# S55klipper: records the pair on disk at each action; a print may start
# right after a start (S5).
cat > "$WORK/init.d/S55klipper" <<'EOS'
#!/bin/sh
k=$(git -C "$KLIPPER_FIXTURE" rev-parse HEAD 2>/dev/null)
e=$(git -C "$EXTENSIONS_FIXTURE" rev-parse HEAD 2>/dev/null)
echo "S55klipper $1 klipper=$k extensions=$e" >> "$HEALTH_DIR/restarts.log"
[ "$1" = start ] && [ -e "$HEALTH_DIR/print_after_start" ] && echo printing > "$HEALTH_DIR/print_state"
exit 0
EOS
chmod +x "$WORK/init.d/S55klipper"

set_health() { echo "$1" > "$HEALTH_DIR/stage1"; echo "$2" > "$HEALTH_DIR/stage2"; }
printing() { echo printing > "$HEALTH_DIR/print_state"; }
idle() { echo standby > "$HEALTH_DIR/print_state"; rm -f "$HEALTH_DIR/print_after_start" "$HEALTH_DIR/print_on_stage1"; }
reset_logs() { : > "$HEALTH_DIR/calls.log"; : > "$HEALTH_DIR/restarts.log"; }
restarts() { grep -c "S55klipper start" "$HEALTH_DIR/restarts.log"; }
make_klipper() {
	d="$1"; content="$2"
	rm -rf "$d"; mkdir -p "$d/klippy/extras" "$d/klippy/chelper"
	printf 'out\n*.so\n*.pyc\n' > "$d/.gitignore"
	printf '# klippy %s\n' "$content" > "$d/klippy/klippy.py"
	printf '# extras\n' > "$d/klippy/extras/__init__.py"
	printf '# chelper %s\n' "$content" > "$d/klippy/chelper/__init__.py"
	printf 'int main(void){return 0;}\n' > "$d/klippy/chelper/pyhelper.c"
	printf '#pragma once\n' > "$d/klippy/chelper/pyhelper.h"
	git -C "$d" init -q -b master; git -C "$d" add -A; git -C "$d" commit -q -m "klipper $content"
	printf 'prebuilt\n' > "$d/klippy/chelper/c_helper.so"
}

make_extensions() {
	d="$1"; content="$2"
	rm -rf "$d"; mkdir -p "$d/extras"
	for m in prtouch_v2 nebulaos_compat; do printf '# %s %s\n' "$m" "$content" > "$d/extras/$m.py"; done
	cat > "$d/nebulaos-extensions.json" <<EOF
{
  "compat_schema_version": 1,
  "extensions_version": "$content",
  "nebulaos_api_level": 1,
  "required_klipper_symbols": [],
  "composition": {
    "source_dir": "extras",
    "destination_dir": "klippy/extras",
    "exclude_file": ".git/info/exclude",
    "link_type": "symlink",
    "marker_file": ".nebulaos-composed",
    "require_symlink_resolving_inside_source": true
  },
  "modules": [
    {"path": "extras/prtouch_v2.py", "role": "runtime"},
    {"path": "extras/nebulaos_compat.py", "role": "runtime"}
  ],
  "chelper": {
    "enforced_by": "platform",
    "requirement": "prebuilt_so_mtime_newer_than_all_chelper_sources",
    "target": "klippy/chelper/c_helper.so",
    "source_dir": "klippy/chelper",
    "platform_result_file": ".nebulaos-chelper-verdict.json"
  }
}
EOF
	git -C "$d" init -q -b main; git -C "$d" add -A; git -C "$d" commit -q -m "extensions $content"
}

sup() {
	env NEBULAOS_UPDATE_SUPERVISOR_NO_AUTORUN=1 \
		NEBULAOS_ROOT="$ROOT" LOCKDIR="$LOCKS" NEBULAOS_RUN_DIR="$WORK/run" \
		HEALTHCHECK="$WORK/healthcheck.sh" BUSY_LIB="$BUSY_LIB" \
		NB_KLIPPY_PIDFILE="$WORK/klippy.pid" NB_KLIPPY_SOCK="$WORK/klippy.sock" \
		COMPOSE_LIB="$COMPOSE_LIB" CHELPER_LIB="$CHELPER_LIB" HEALTH_DIR="$HEALTH_DIR" \
		KLIPPER_FIXTURE="$KDIR" EXTENSIONS_FIXTURE="$EDIR" \
		MOONRAKER_URL="http://moonraker.test" REFRESH_TRIES=1 REFRESH_PAUSE=0 \
		RESTART_GRACE_PERIOD=0 STABILIZE_SAMPLES=1 STABILIZE_INTERVAL=0 \
		READY_POLL_TRIES=1 READY_POLL_INTERVAL=0 PAIR_SETTLE_SECONDS=0 UPDATE_SETTLE_TRIES=1 UPDATE_SETTLE_INTERVAL=0 \
		sh -c "PATH=\"$WORK/bin:\$PATH\"; . '$SUPERVISOR'; \
			component_info() { \
				case \"\$1\" in \
					klipper|nebulaos-klipper-extensions) echo '$KDIR|$WORK/init.d/S55klipper|$WORK/optklipper|' ;; \
					moonraker) echo '$ROOT/apps/moonraker|$WORK/init.d/S56moonraker|$WORK/optmoonraker|' ;; \
				esac; }; \
			$*"
}
field() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "$ROOT/updates/klipper-stack/state.json" 2>/dev/null | head -1; }
khead() { git -C "$KDIR" rev-parse HEAD; }
ehead() { git -C "$EDIR" rev-parse HEAD; }
bump_klipper() { printf '# moved %s\n' "$1" >> "$KDIR/klippy/klippy.py"; git -C "$KDIR" commit -qam "klipper $1"; }
bump_extensions() { printf '# moved %s\n' "$1" >> "$EDIR/extras/prtouch_v2.py"; git -C "$EDIR" commit -qam "extensions $1"; }
export KLIPPER_FIXTURE="$KDIR" EXTENSIONS_FIXTURE="$EDIR"

setup_stack() {
	rm -rf "$ROOT"
	mkdir -p "$ROOT/apps" "$LOCKS" "$ROOT/updates" "$ROOT/backups/klipper" "$ROOT/backups/nebulaos-klipper-extensions"
	make_klipper "$KDIR" v1
	make_extensions "$EDIR" v1
	set_health ok ok; idle; reset_logs
	sup poll_klipper_stack_once >/dev/null 2>&1
	KG_K=$(khead) KG_E=$(ehead)
}

# --- S4: a print runs when the update lands ----------------------------------
setup_stack
bump_klipper v2; NEW_K=$(khead)
printing; reset_logs
sup "poll_klipper_stack_once; poll_klipper_stack_once" > "$WORK/s4.log" 2>&1   # one process, as the loop
t "S4: no restart while printing" '[ "$(restarts)" = 0 ] && [ ! -s "$HEALTH_DIR/restarts.log" ]'
t "S4: nothing validated or recorded (state healthy, last_seen the old pair)" \
	'[ "$(field state)" = healthy ] && [ "$(field last_seen_klipper_commit)" = "$KG_K" ] && [ ! -e "$LOCKS/klipper-stack.lock" ]'
t "S4: the deferral is logged once, with the reason" '[ "$(grep -c "validation deferred (PRINTING)" "$WORK/s4.log")" = 1 ]'
t "S4: the new code stays on disk, untouched" '[ "$(khead)" = "$NEW_K" ]'
idle; reset_logs
sup poll_klipper_stack_once > "$WORK/s4b.log" 2>&1
t "S4: after the print the pair is validated and promoted" \
	'[ "$(field state)" = healthy ] && [ "$(field known_good_klipper_commit)" = "$NEW_K" ] && [ "$(restarts)" = 1 ]'

# --- S5 (C1): a print starts right after the validation restart ---------------
setup_stack
bump_klipper v2; NEW_K=$(khead)
: > "$HEALTH_DIR/print_after_start"; reset_logs
sup poll_klipper_stack_once > "$WORK/s5.log" 2>&1
t "S5: stage 2 saw the print and was deferred, not failed" 'grep -q "stage2 -> deferred" "$HEALTH_DIR/calls.log"'
t "S5: no rollback - the new pair stays on disk" '[ "$(khead)" = "$NEW_K" ] && [ "$(ehead)" = "$KG_E" ] && [ -z "$(find "$ROOT/backups/klipper" -name "failed-*")" ]'
t "S5: exactly one restart (the validation's), none under the print" '[ "$(restarts)" = 1 ]'
t "S5: state deferred, last_seen back on the known-good pair, lock released" \
	'[ "$(field state)" = deferred ] && [ "$(field last_seen_klipper_commit)" = "$KG_K" ] && [ "$(field known_good_klipper_commit)" = "$KG_K" ] && [ ! -e "$LOCKS/klipper-stack.lock" ]'
reset_logs
sup poll_klipper_stack_once >> "$WORK/s5.log" 2>&1
t "S5: later polls during the print: still no restart" '[ "$(restarts)" = 0 ]'
idle; reset_logs
sup poll_klipper_stack_once >> "$WORK/s5.log" 2>&1
t "S5: after the print: validated and promoted" \
	'[ "$(field state)" = healthy ] && [ "$(field known_good_klipper_commit)" = "$NEW_K" ] && [ "$(restarts)" = 1 ]'

# --- S28: "Update all" partly applied (extensions only) during a print --------
setup_stack
bump_extensions v2; NEW_E=$(ehead)
printing; reset_logs
sup poll_klipper_stack_once > "$WORK/s28.log" 2>&1
t "S28: no restart while printing" '[ "$(restarts)" = 0 ]'
idle
sup poll_klipper_stack_once >> "$WORK/s28.log" 2>&1
t "S28: after the print the pair (new extensions + installed Klipper) is validated" \
	'[ "$(field state)" = healthy ] && [ "$(field known_good_extensions_commit)" = "$NEW_E" ] && [ "$(field known_good_klipper_commit)" = "$KG_K" ]'

# --- S29: checkout done, reset refused: HEAD on another consistent commit -----
setup_stack
git -C "$KDIR" checkout -q -b other
bump_klipper other; OTHER_K=$(khead)
printing; reset_logs
sup poll_klipper_stack_once > "$WORK/s29.log" 2>&1
t "S29: no restart while printing" '[ "$(restarts)" = 0 ]'
idle
sup poll_klipper_stack_once >> "$WORK/s29.log" 2>&1
t "S29: the delta is reconciled (validated) after the print" \
	'[ "$(field state)" = healthy ] && [ "$(field known_good_klipper_commit)" = "$OTHER_K" ]'

# --- the whole rollback transaction is deferred under a print ------------------
setup_stack
bump_klipper bad; BAD_K=$(khead)
set_health fail ok; : > "$HEALTH_DIR/print_on_stage1"; reset_logs
sup poll_klipper_stack_once > "$WORK/rb.log" 2>&1
t "rollback: stage 1 failed while a print started -> rollback-pending" '[ "$(field state)" = rollback-pending ]'
t "rollback: nothing reset (no git reset under the print)" '[ "$(khead)" = "$BAD_K" ]'
t "rollback: nothing restarted" '[ "$(restarts)" = 0 ] && ! grep -q "S55klipper stop" "$HEALTH_DIR/restarts.log"'
t "rollback: the lock stays (a reboot keeps the immutable copy)" '[ -e "$LOCKS/klipper-stack.lock" ]'
t "rollback: the known-good pair is kept on record" '[ "$(field known_good_klipper_commit)" = "$KG_K" ]'
rm -f "$HEALTH_DIR/print_on_stage1"; reset_logs
sup "poll_klipper_stack_once; poll_klipper_stack_once" > "$WORK/rb1.log" 2>&1
t "rollback: still printing on later polls -> still pending, nothing touched" \
	'[ "$(field state)" = rollback-pending ] && [ "$(khead)" = "$BAD_K" ] && [ "$(restarts)" = 0 ]'
t "rollback: the deferral is logged once per loop process" '[ "$(grep -c "rollback deferred (PRINTING)" "$WORK/rb1.log")" = 1 ]'
idle; set_health ok ok; reset_logs
sup poll_klipper_stack_once >> "$WORK/rb.log" 2>&1
t "rollback: first idle poll restores BOTH halves and restarts once" \
	'[ "$(khead)" = "$KG_K" ] && [ "$(ehead)" = "$KG_E" ] && [ "$(restarts)" = 1 ]'
t "rollback: rolled-back, lock released, the failed commit not recorded" \
	'[ "$(field state)" = rolled-back ] && [ ! -e "$LOCKS/klipper-stack.lock" ] && [ "$(field known_good_klipper_commit)" = "$KG_K" ] && grep -q "\"last_failure_reason\": \"stage1_failed:" "$ROOT/updates/klipper-stack/state.json"'

# --- factory fallback is refused under a print ---------------------------------
sup "echo printing > \"$HEALTH_DIR/print_state\"; if factory_fallback klipper; then echo RAN; else echo DEFERRED; fi" > "$WORK/ff.log" 2>&1
t "factory_fallback klipper: deferred under a print, nothing unmounted or restarted" \
	'grep -q DEFERRED "$WORK/ff.log" && grep -q "factory fallback deferred (PRINTING)" "$WORK/ff.log"'
idle

# --- N4: Moonraker restarts are not gated by a print; Klipper's are -------------
printf '#!/bin/sh\necho "S56moonraker $1" >> "%s/restarts.log"\n' "$HEALTH_DIR" > "$WORK/init.d/S56moonraker"
chmod +x "$WORK/init.d/S56moonraker"
printing; reset_logs
sup "restart_component moonraker && echo MR-OK; restart_component klipper || echo KL-DEFERRED" > "$WORK/n4.log" 2>&1
t "N4: Moonraker restarted during a print" 'grep -q MR-OK "$WORK/n4.log" && grep -q "S56moonraker start" "$HEALTH_DIR/restarts.log"'
t "N4: Klipper restart deferred during the same print" 'grep -q KL-DEFERRED "$WORK/n4.log" && ! grep -q S55klipper "$HEALTH_DIR/restarts.log"'
idle

# --- no blocking waits left -----------------------------------------------------
t "no bounded print wait whose result could be ignored" '! grep -q "wait_for_print_idle" "$SUPERVISOR"'

echo
echo "update-supervisor-print-deferral-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
