#!/bin/sh
#
# Offline scenario tests for the pair-aware update supervisor
# (/etc/nebulaos-update-supervisor.sh). Phase 1 no-fork migration, Phase I.
#
# Walks the six update-ordering and failure scenarios the Phase 1 analysis
# identified, against the REAL script's real control flow - it is sourced
# through its NO_AUTORUN seam with fixture paths, a stubbed health check and
# a stubbed init script, so what is exercised is the shipped logic rather
# than a description of it.
#
#   1. extensions update arrives first, old Klipper still installed
#   2. Klipper update arrives first, old extensions remain
#   3. both updates land close together
#   4. Klipper update succeeds but the extensions update fails
#   5. extensions succeed but Klipper fails validation and rolls back
#   6. power loss between the two operations
#
# The invariant every one of them is really testing is the same: a known-good
# pair is never recorded until BOTH halves have passed, and any failure
# restores BOTH halves together. Never touches a device, a printer, or a
# network.
#
# Usage: sh tests/klipper-stack-update-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OVERLAY_ETC="$REPO_ROOT/scripts/build/overlay/etc"
SUPERVISOR="$OVERLAY_ETC/nebulaos-update-supervisor.sh"
COMPOSE_LIB="$OVERLAY_ETC/nebulaos-klipper-compose.sh"
CHELPER_LIB="$OVERLAY_ETC/nebulaos-chelper-preflight.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/klipper-stack-update.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: klipper-stack-update-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# --- harness --------------------------------------------------------------

ROOT="$WORK/root"
KDIR="$ROOT/apps/klipper"
EDIR="$ROOT/apps/nebulaos-klipper-extensions"
LOCKS="$ROOT/updates/locks"

# A stubbed health check whose verdict is whatever $WORK/health-verdict says.
# stage1 and stage2 are controlled independently, because the real script
# treats a stage1 failure and a stage2 failure as different paths.
cat > "$WORK/healthcheck.sh" <<'EOF'
#!/bin/sh
stage="$1"
case "$stage" in
	stage1) f=/dev/null; want=$(cat "$HEALTH_DIR/stage1" 2>/dev/null) ;;
	stage2) want=$(cat "$HEALTH_DIR/stage2" 2>/dev/null) ;;
	*)      want=ok ;;
esac
echo "healthcheck $stage -> ${want:-ok}" >> "$HEALTH_DIR/calls.log"
[ "${want:-ok}" = "ok" ]
EOF
chmod +x "$WORK/healthcheck.sh"

# A stubbed S55klipper that only records that it was asked to act. The real
# one starts a Python process against a real MCU; nothing here should ever
# launch a service.
mkdir -p "$WORK/init.d"
# Records WHICH commits were on disk at the moment it was asked to start.
# That is the property that actually matters: "was Klipper ever started
# against the rejected pair", not "was it started at all" - a rollback
# legitimately restarts it, against the restored pair, to re-validate.
cat > "$WORK/init.d/S55klipper" <<'EOF'
#!/bin/sh
k=$(git -C "$KLIPPER_FIXTURE" rev-parse HEAD 2>/dev/null)
e=$(git -C "$EXTENSIONS_FIXTURE" rev-parse HEAD 2>/dev/null)
echo "S55klipper $1 klipper=$k extensions=$e" >> "$HEALTH_DIR/restarts.log"
exit 0
EOF
chmod +x "$WORK/init.d/S55klipper"

export HEALTH_DIR="$WORK/health"
export KLIPPER_FIXTURE="$WORK/root/apps/klipper"
export EXTENSIONS_FIXTURE="$WORK/root/apps/nebulaos-klipper-extensions"

set_health() { mkdir -p "$HEALTH_DIR"; echo "$1" > "$HEALTH_DIR/stage1"; echo "$2" > "$HEALTH_DIR/stage2"; }
reset_logs() { mkdir -p "$HEALTH_DIR"; : > "$HEALTH_DIR/calls.log"; : > "$HEALTH_DIR/restarts.log"; }

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

# Fresh, bootstrapped stack: both halves at v1, recorded as the known-good
# pair exactly as the first poll of a healthy boot would.
setup_stack() {
	rm -rf "$ROOT"
	mkdir -p "$ROOT/apps" "$LOCKS" "$ROOT/updates" "$ROOT/backups/klipper" \
		"$ROOT/backups/nebulaos-klipper-extensions"
	make_klipper "$KDIR" v1
	make_extensions "$EDIR" v1
	set_health ok ok
	reset_logs
	sup poll_klipper_stack_once >/dev/null 2>&1
}

# Drive the real supervisor with fixture paths and fast timings.
sup() {
	env NEBULAOS_UPDATE_SUPERVISOR_NO_AUTORUN=1 \
		NEBULAOS_ROOT="$ROOT" LOCKDIR="$LOCKS" \
		HEALTHCHECK="$WORK/healthcheck.sh" \
		COMPOSE_LIB="$COMPOSE_LIB" CHELPER_LIB="$CHELPER_LIB" \
		HEALTH_DIR="$HEALTH_DIR" \
		KLIPPER_FIXTURE="$KDIR" EXTENSIONS_FIXTURE="$EDIR" \
		MOONRAKER_URL="http://127.0.0.1:9" \
		RESTART_GRACE_PERIOD=0 STABILIZE_SAMPLES=1 STABILIZE_INTERVAL=0 \
		READY_POLL_TRIES=1 READY_POLL_INTERVAL=0 PAIR_SETTLE_SECONDS=0 UPDATE_SETTLE_TRIES=1 UPDATE_SETTLE_INTERVAL=0 \
		sh -c "PATH=\"$WORK:\$PATH\"; . '$SUPERVISOR'; \
			component_info() { \
				case \"\$1\" in \
					klipper) echo '$KDIR|$WORK/init.d/S55klipper|$WORK/optklipper|' ;; \
					nebulaos-klipper-extensions) echo '$EDIR|$WORK/init.d/S55klipper|$WORK/optklipper|' ;; \
					moonraker) echo '$ROOT/apps/moonraker||$WORK/optmoonraker|' ;; \
				esac; }; \
			$*"
}

stack_field() {
	sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "$ROOT/updates/klipper-stack/state.json" 2>/dev/null | head -1
}

khead() { git -C "$KDIR" rev-parse HEAD 2>/dev/null; }
ehead() { git -C "$EDIR" rev-parse HEAD 2>/dev/null; }

bump_klipper() { printf '# moved %s\n' "$1" >> "$KDIR/klippy/klippy.py"; git -C "$KDIR" commit -qam "klipper $1"; }
bump_extensions() { printf '# moved %s\n' "$1" >> "$EDIR/extras/prtouch_v2.py"; git -C "$EDIR" commit -qam "extensions $1"; }

# --- bootstrap ------------------------------------------------------------

setup_stack
if [ "$(stack_field state)" = "healthy" ] && \
   [ "$(stack_field known_good_klipper_commit)" = "$(khead)" ] && \
   [ "$(stack_field known_good_extensions_commit)" = "$(ehead)" ]; then
	pass "bootstrap: the first observation records BOTH commits as one known-good pair"
else
	fail "bootstrap did not record a known-good pair (state=$(stack_field state))"
fi
if [ ! -e "$LOCKS/klipper.lock" ] && [ ! -e "$LOCKS/nebulaos-klipper-extensions.lock" ]; then
	pass "bootstrap: no per-component locks are created - the stack uses one shared lock"
else
	fail "per-component locks were created for the stack"
fi

# --- Scenario 1: extensions update arrives first --------------------------

setup_stack
kg_k=$(khead); kg_e=$(ehead)
bump_extensions v2
new_e=$(ehead)
reset_logs; set_health ok ok
sup poll_klipper_stack_once > "$WORK/s1.log" 2>&1

if [ "$(stack_field state)" = "healthy" ] && \
   [ "$(stack_field known_good_extensions_commit)" = "$new_e" ] && \
   [ "$(stack_field known_good_klipper_commit)" = "$kg_k" ]; then
	pass "scenario 1: an extensions-only update is validated as a pair with the installed Klipper and promoted"
else
	fail "scenario 1: pair not promoted (state=$(stack_field state))"; cat "$WORK/s1.log"
fi
if grep -q "S55klipper start" "$HEALTH_DIR/restarts.log"; then
	pass "scenario 1: Klipper is restarted for an extensions-only change (the extensions have no service of their own)"
else
	fail "scenario 1: Klipper was not restarted"
fi
if [ "$(readlink -f "$KDIR/klippy/extras/prtouch_v2.py")" = "$(readlink -f "$EDIR/extras/prtouch_v2.py")" ]; then
	pass "scenario 1: the composition was rebuilt against the new extensions tree"
else
	fail "scenario 1: composition does not point at the new extensions"
fi

# Now the incompatible case: the new extensions do not work with this Klipper.
setup_stack
kg_k=$(khead); kg_e=$(ehead)
bump_extensions bad
bad_e=$(ehead)
reset_logs; set_health ok fail
sup poll_klipper_stack_once > "$WORK/s1b.log" 2>&1
if [ "$(khead)" = "$kg_k" ] && [ "$(ehead)" = "$kg_e" ]; then
	pass "scenario 1 (incompatible): BOTH halves are restored to the last validated pair, not just the one that changed"
else
	fail "scenario 1 (incompatible): pair not restored (k=$(khead) want=$kg_k, e=$(ehead) want=$kg_e)"; cat "$WORK/s1b.log"
fi
if [ "$(stack_field known_good_extensions_commit)" = "$kg_e" ] && \
   [ "$(stack_field last_seen_extensions_commit)" = "$kg_e" ]; then
	pass "scenario 1 (incompatible): the rejected commit is NOT recorded as known-good, and last_seen matches what is really on disk"
else
	fail "scenario 1 (incompatible): state bookkeeping is out of sync with git"
fi
if [ -n "$(find "$ROOT/backups/nebulaos-klipper-extensions" -maxdepth 1 -name 'failed-*' 2>/dev/null)" ] && \
   [ -n "$(find "$ROOT/backups/klipper" -maxdepth 1 -name 'failed-*' 2>/dev/null)" ]; then
	pass "scenario 1 (incompatible): failure evidence is preserved for BOTH halves via the existing mechanism"
else
	fail "scenario 1 (incompatible): failure evidence missing for one or both halves"
fi

# --- Scenario 2: Klipper update arrives first -----------------------------

setup_stack
kg_k=$(khead); kg_e=$(ehead)
bump_klipper v2
new_k=$(khead)
reset_logs; set_health ok ok
sup poll_klipper_stack_once > "$WORK/s2.log" 2>&1
if [ "$(stack_field state)" = "healthy" ] && \
   [ "$(stack_field known_good_klipper_commit)" = "$new_k" ] && \
   [ "$(stack_field known_good_extensions_commit)" = "$kg_e" ]; then
	pass "scenario 2: a Klipper-only update is validated as a pair with the installed extensions and promoted"
else
	fail "scenario 2: pair not promoted"; cat "$WORK/s2.log"
fi

# The dangerous variant: the Klipper update touched a chelper source, so the
# shipped prebuilt library is now stale. This must be caught BEFORE Klippy is
# restarted - a rebuild attempt on a device with no toolchain does not start.
setup_stack
kg_k=$(khead); kg_e=$(ehead)
sleep 1
printf 'int extra(void){return 1;}\n' > "$KDIR/klippy/chelper/stepcompress.c"
git -C "$KDIR" add -A && git -C "$KDIR" commit -q -m "klipper touches chelper"
touch "$KDIR/klippy/chelper/stepcompress.c"
bad_k=$(khead)
reset_logs; set_health ok ok
sup poll_klipper_stack_once > "$WORK/s2b.log" 2>&1
if [ "$(khead)" = "$kg_k" ] && [ "$(ehead)" = "$kg_e" ]; then
	pass "scenario 2 (stale c_helper.so): the pair is rolled back to the last validated pair"
else
	fail "scenario 2 (stale c_helper.so): pair not rolled back"; cat "$WORK/s2b.log"
fi
if grep -q "c_helper.so mtime invariant does NOT hold" "$WORK/s2b.log"; then
	pass "scenario 2 (stale c_helper.so): rejected with a specific, named reason"
else
	fail "scenario 2 (stale c_helper.so): no named chelper rejection"; cat "$WORK/s2b.log"
fi
if ! grep -q "klipper=$bad_k" "$HEALTH_DIR/restarts.log" 2>/dev/null; then
	pass "scenario 2 (stale c_helper.so): Klipper is NEVER started against the rejected pair - nothing ever gets the chance to invoke gcc mid-boot (the only restarts recorded are against the restored pair)"
else
	fail "scenario 2 (stale c_helper.so): Klipper was started against the rejected commit $bad_k"
	cat "$HEALTH_DIR/restarts.log"
fi
if [ "$(stack_field last_failure_reason)" != "" ]; then
	pass "scenario 2 (stale c_helper.so): the failure reason is recorded in the pair state"
else
	fail "scenario 2 (stale c_helper.so): no failure reason recorded"
fi

# The collision guard, on the same path: a Klipper update that starts
# shipping a file at a managed path.
setup_stack
kg_k=$(khead); kg_e=$(ehead)
printf '# upstream adopts this\n' > "$KDIR/klippy/extras/prtouch_v2.py"
git -C "$KDIR" add -A && git -C "$KDIR" commit -q -m "upstream adopts prtouch_v2"
reset_logs; set_health ok ok
sup poll_klipper_stack_once > "$WORK/s2c.log" 2>&1
if [ "$(khead)" = "$kg_k" ] && grep -q "COLLISION" "$WORK/s2c.log"; then
	pass "scenario 2 (upstream collision): a Klipper update shadowing a managed module is caught and the pair rolled back"
else
	fail "scenario 2 (upstream collision): collision not caught"; cat "$WORK/s2c.log"
fi

# --- Scenario 3: both updates land close together -------------------------

setup_stack
kg_k=$(khead); kg_e=$(ehead)
bump_klipper v2; bump_extensions v2
new_k=$(khead); new_e=$(ehead)
reset_logs; set_health ok ok
sup poll_klipper_stack_once > "$WORK/s3.log" 2>&1
if [ "$(stack_field known_good_klipper_commit)" = "$new_k" ] && \
   [ "$(stack_field known_good_extensions_commit)" = "$new_e" ]; then
	pass "scenario 3: both halves changing together are validated in ONE transaction, not two racing ones"
else
	fail "scenario 3: pair not promoted together"; cat "$WORK/s3.log"
fi
restart_count=$(grep -c "S55klipper start " "$HEALTH_DIR/restarts.log" 2>/dev/null || echo 0)
if [ "$restart_count" -eq 1 ]; then
	pass "scenario 3: exactly one Klipper restart for the combined update, not one per component"
else
	fail "scenario 3: expected 1 restart, got $restart_count"
fi

# The settle window: a second update landing while the first is settling must
# defer rather than validate a torn pair.
setup_stack
bump_klipper v2
reset_logs; set_health ok ok
env PAIR_SETTLE_SECONDS=2 sh -c "sleep 1; cd '$EDIR' && printf '# late\n' >> extras/prtouch_v2.py && git commit -qam 'extensions land late'" &
LATE_PID=$!
env NEBULAOS_UPDATE_SUPERVISOR_NO_AUTORUN=1 NEBULAOS_ROOT="$ROOT" LOCKDIR="$LOCKS" \
	HEALTHCHECK="$WORK/healthcheck.sh" COMPOSE_LIB="$COMPOSE_LIB" CHELPER_LIB="$CHELPER_LIB" \
	HEALTH_DIR="$HEALTH_DIR" KLIPPER_FIXTURE="$KDIR" EXTENSIONS_FIXTURE="$EDIR" \
	MOONRAKER_URL="http://127.0.0.1:9" \
	RESTART_GRACE_PERIOD=0 STABILIZE_SAMPLES=1 STABILIZE_INTERVAL=0 \
	READY_POLL_TRIES=1 READY_POLL_INTERVAL=0 PAIR_SETTLE_SECONDS=3 UPDATE_SETTLE_TRIES=1 UPDATE_SETTLE_INTERVAL=0 \
	sh -c ". '$SUPERVISOR'; \
		component_info() { case \"\$1\" in klipper) echo '$KDIR|$WORK/init.d/S55klipper|$WORK/optklipper|' ;; nebulaos-klipper-extensions) echo '$EDIR|$WORK/init.d/S55klipper|$WORK/optklipper|' ;; esac; }; \
		poll_klipper_stack_once" > "$WORK/s3b.log" 2>&1
wait $LATE_PID 2>/dev/null
if grep -q "still moving" "$WORK/s3b.log"; then
	pass "scenario 3 (settle window): a second update landing mid-settle defers validation instead of restarting into a torn pair"
else
	fail "scenario 3 (settle window): the still-moving pair was not deferred"; cat "$WORK/s3b.log"
fi

# --- Scenario 4: Klipper succeeds, the extensions update fails ------------
#
# Moonraker aborts the failed component's update, so the device is left with
# new Klipper and old extensions - which from this supervisor's point of view
# IS scenario 2, and must be handled by the same single path rather than a
# special case.

setup_stack
kg_k=$(khead); kg_e=$(ehead)
bump_klipper v2
new_k=$(khead)
reset_logs; set_health ok fail
sup poll_klipper_stack_once > "$WORK/s4.log" 2>&1
if [ "$(khead)" = "$kg_k" ] && [ "$(ehead)" = "$kg_e" ]; then
	pass "scenario 4: new Klipper + unchanged extensions failing validation restores the whole pair"
else
	fail "scenario 4: pair not restored"; cat "$WORK/s4.log"
fi
if [ "$(stack_field known_good_klipper_commit)" = "$kg_k" ]; then
	pass "scenario 4: the new Klipper commit is never recorded as known-good on a failed pair"
else
	fail "scenario 4: a failed commit was recorded as known-good"
fi

# --- Scenario 5: extensions fine, Klipper fails and rolls back ------------

setup_stack
kg_k=$(khead); kg_e=$(ehead)
bump_extensions v2; bump_klipper bad
reset_logs; set_health fail ok
sup poll_klipper_stack_once > "$WORK/s5.log" 2>&1
if [ "$(ehead)" = "$kg_e" ]; then
	pass "scenario 5: the extensions are rolled back TOGETHER with Klipper - they are never left ahead of it"
else
	fail "scenario 5: extensions were left ahead of a rolled-back Klipper (e=$(ehead) want=$kg_e)"; cat "$WORK/s5.log"
fi
if [ "$(khead)" = "$kg_k" ]; then
	pass "scenario 5: Klipper is restored to its known-good commit"
else
	fail "scenario 5: Klipper not restored"
fi
if [ "$(readlink -f "$KDIR/klippy/extras/prtouch_v2.py")" = "$(readlink -f "$EDIR/extras/prtouch_v2.py")" ] && \
   [ -z "$(git -C "$KDIR" status --porcelain)" ]; then
	pass "scenario 5: the composition is rebuilt and re-verified after the rollback, with the checkout still pristine"
else
	fail "scenario 5: composition not correctly rebuilt after rollback"
fi

# --- Scenario 6: power loss between the two operations --------------------

setup_stack
kg_k=$(khead); kg_e=$(ehead)
bump_klipper v2
# Simulate a supervisor killed mid-transaction: the state file is left saying
# "validating" and the shared lock is still held, which is exactly what a
# power cut during validate_klipper_stack leaves behind.
mkdir -p "$ROOT/updates/klipper-stack"
cat > "$ROOT/updates/klipper-stack/state.json" <<EOF
{
  "component": "klipper-stack",
  "known_good_klipper_commit": "$kg_k",
  "known_good_extensions_commit": "$kg_e",
  "last_seen_klipper_commit": "$(khead)",
  "last_seen_extensions_commit": "$kg_e",
  "state": "validating",
  "last_failure_reason": ""
}
EOF
: > "$LOCKS/klipper-stack.lock"
# ...and a half-composed tree from the same crash.
rm -f "$KDIR/.nebulaos-composed" "$KDIR/klippy/extras/nebulaos_compat.py"

reset_logs; set_health ok ok
sup reconcile_klipper_stack_on_boot > "$WORK/s6.log" 2>&1
if [ "$(stack_field state)" = "interrupted" ] && [ ! -e "$LOCKS/klipper-stack.lock" ]; then
	pass "scenario 6: an interrupted transaction is detected on supervisor start, the stale lock cleared, and nothing unvalidated is accepted as current"
else
	fail "scenario 6: interrupted transaction not reconciled (state=$(stack_field state))"; cat "$WORK/s6.log"
fi
if [ "$(stack_field last_seen_klipper_commit)" = "$kg_k" ]; then
	pass "scenario 6: last_seen is reset to the known-good pair, so the next poll sees a delta and re-validates rather than silently trusting the pair on disk"
else
	fail "scenario 6: last_seen was not reset to the known-good pair"
fi

reset_logs; set_health ok ok
sup poll_klipper_stack_once > "$WORK/s6b.log" 2>&1
if [ "$(stack_field state)" = "healthy" ] && [ "$(stack_field known_good_klipper_commit)" = "$(khead)" ]; then
	pass "scenario 6: the following poll re-validates the pair from scratch and promotes it"
else
	fail "scenario 6: re-validation after the interruption did not complete"; cat "$WORK/s6b.log"
fi
n_links=$(find "$KDIR/klippy/extras" -maxdepth 1 -type l | wc -l)
if [ "$n_links" -eq 2 ] && [ -z "$(git -C "$KDIR" status --porcelain)" ] && \
   [ -z "$(sort "$KDIR/.git/info/exclude" | uniq -d)" ]; then
	pass "scenario 6: the half-composed tree left by the crash is fully rebuilt, with no duplicate exclude lines and a pristine checkout"
else
	fail "scenario 6: half-composed tree not repaired (links=$n_links)"
fi

# --- terminal state -------------------------------------------------------

setup_stack
kg_k=$(khead); kg_e=$(ehead)
bump_klipper bad
reset_logs; set_health fail fail
sup poll_klipper_stack_once > "$WORK/s7.log" 2>&1
if [ "$(stack_field state)" = "factory-fallback" ] && [ -e "$LOCKS/klipper-stack.lock" ]; then
	pass "terminal state: when the restored pair is ALSO unhealthy, the stack goes to factory-fallback and keeps the lock held for a human"
else
	fail "terminal state: expected factory-fallback with the lock held (state=$(stack_field state))"; cat "$WORK/s7.log"
fi
reset_logs
sup poll_klipper_stack_once > "$WORK/s7b.log" 2>&1
if [ "$(stack_field state)" = "factory-fallback" ] && [ ! -s "$HEALTH_DIR/restarts.log" ]; then
	pass "terminal state: factory-fallback is genuinely terminal - a later poll never silently re-attempts the degraded pair"
else
	fail "terminal state: factory-fallback was re-attempted"; cat "$WORK/s7b.log"
fi

# --- cross-generation rollback (Phase 1.5) --------------------------------
#
# The exact hardware incident: a device carries state.json from a previous
# image generation whose known_good_commit points to a DIFFERENT factory
# stack. A new image is flashed, changing the migration_version. The
# supervisor must discard the old generation's known_good and bootstrap
# fresh from the current running pair, not roll back to the old
# generation's commits.

setup_stack
old_k=$(khead); old_e=$(ehead)

# Simulate state from a previous generation by writing a generation_id
# that does not match the current one.
mkdir -p "$ROOT/system" "$ROOT/updates/klipper-stack"
echo '{"migration_version": "gen-old-image"}' > "$ROOT/system/app-generation.json"
cat > "$ROOT/updates/klipper-stack/state.json" <<EOF
{
  "component": "klipper-stack",
  "generation_id": "gen-previous-image",
  "known_good_klipper_commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "known_good_extensions_commit": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "last_seen_klipper_commit": "$old_k",
  "last_seen_extensions_commit": "$old_e",
  "state": "healthy",
  "last_failure_reason": ""
}
EOF

reset_logs; set_health ok ok
sup_gen() {
	env NEBULAOS_UPDATE_SUPERVISOR_NO_AUTORUN=1 \
		NEBULAOS_ROOT="$ROOT" LOCKDIR="$LOCKS" \
		HEALTHCHECK="$WORK/healthcheck.sh" \
		COMPOSE_LIB="$COMPOSE_LIB" CHELPER_LIB="$CHELPER_LIB" \
		HEALTH_DIR="$HEALTH_DIR" \
		GENERATION_FILE="$ROOT/system/app-generation.json" \
		KLIPPER_FIXTURE="$KDIR" EXTENSIONS_FIXTURE="$EDIR" \
		MOONRAKER_URL="http://127.0.0.1:9" \
		RESTART_GRACE_PERIOD=0 STABILIZE_SAMPLES=1 STABILIZE_INTERVAL=0 \
		READY_POLL_TRIES=1 READY_POLL_INTERVAL=0 PAIR_SETTLE_SECONDS=0 UPDATE_SETTLE_TRIES=1 UPDATE_SETTLE_INTERVAL=0 \
		sh -c "PATH=\"$WORK:\$PATH\"; . '$SUPERVISOR'; \
			component_info() { \
				case \"\$1\" in \
					klipper) echo '$KDIR|$WORK/init.d/S55klipper|$WORK/optklipper|' ;; \
					nebulaos-klipper-extensions) echo '$EDIR|$WORK/init.d/S55klipper|$WORK/optklipper|' ;; \
					moonraker) echo '$ROOT/apps/moonraker||$WORK/optmoonraker|' ;; \
				esac; }; \
			$*"
}
sup_gen poll_klipper_stack_once > "$WORK/gen.log" 2>&1

if [ "$(stack_field known_good_klipper_commit)" = "$old_k" ] && \
   [ "$(stack_field known_good_extensions_commit)" = "$old_e" ]; then
	pass "cross-generation: old generation's known_good is DISCARDED - the current running pair becomes the new known-good"
else
	fail "cross-generation: old generation's known_good was NOT discarded (kg_k=$(stack_field known_good_klipper_commit) want=$old_k)"; cat "$WORK/gen.log"
fi
if [ "$(stack_field generation_id)" = "gen-old-image" ]; then
	pass "cross-generation: the new state records the CURRENT generation_id"
else
	fail "cross-generation: generation_id not updated (got=$(stack_field generation_id) want=gen-old-image)"; cat "$WORK/gen.log"
fi
if [ "$(stack_field state)" = "healthy" ]; then
	pass "cross-generation: state is healthy after re-bootstrap (not rolled-back or factory-fallback)"
else
	fail "cross-generation: state is not healthy (got=$(stack_field state))"
fi
if grep -q 'cross-generation state detected' "$WORK/gen.log"; then
	pass "cross-generation: the log explicitly names the cross-generation detection"
else
	fail "cross-generation: no cross-generation log message"; cat "$WORK/gen.log"
fi

# --- G72: a matching c_helper.so from the cache or the package index --------
#
# The update changes an EXISTING chelper source (the case `git reset --hard`
# turns into a stale tree on rollback). A stub fetcher serves a fake index
# site from $WORK/site; $WORK/net-down simulates no network.

cat > "$WORK/fakefetch" <<FAKE
#!/bin/sh
[ -e "$WORK/net-down" ] && exit 1
echo "\$2" >> "$WORK/fetches.log"
p=\${2#https://idx.invalid/chelper/}
[ -f "$WORK/site/\$p" ] || exit 22
cp "$WORK/site/\$p" "\$1"
FAKE
chmod 755 "$WORK/fakefetch"
printf 'id=testabi\n' > "$WORK/python-abi"
printf 'https://idx.invalid/chelper\n' > "$WORK/chelper-url"
export NEBULAOS_PYTHON_ABI_FILE="$WORK/python-abi" NEBULAOS_CHELPER_URL_FILE="$WORK/chelper-url" \
	NEBULAOS_CHELPER_FETCH="$WORK/fakefetch" NEBULAOS_CHELPER_IMAGE_RECORD="$WORK/no-image-record"
khash() { ( . "$CHELPER_LIB"; chelper_source_hash "$KDIR" ); }
sha() { sha256sum "$1" | cut -d' ' -f1; }

g72_update() { # $1 = what the index serves: ok | badsha | none | down
	setup_stack
	g_kg_k=$(khead)
	rm -rf "$WORK/site" "$WORK/net-down"; : > "$WORK/fetches.log"
	sleep 1
	printf 'int main(void){return 2;}\n' > "$KDIR/klippy/chelper/pyhelper.c"
	git -C "$KDIR" commit -qam "klipper changes a chelper source"
	g_new_k=$(khead); g_h=$(khash)
	mkdir -p "$WORK/site/testabi/$g_h"
	printf 'built for v2\n' > "$WORK/site/testabi/$g_h/c_helper.so"
	g_sum=$(sha "$WORK/site/testabi/$g_h/c_helper.so")
	case "$1" in
		ok) echo "$g_h $g_sum 13" > "$WORK/site/testabi/index" ;;
		badsha) echo "$g_h 0000000000000000000000000000000000000000000000000000000000000000 13" > "$WORK/site/testabi/index" ;;
		none) echo "ffff $g_sum 13" > "$WORK/site/testabi/index" ;;
		down) : > "$WORK/net-down" ;;
	esac
	reset_logs; set_health ok ok
	sup poll_klipper_stack_once > "$WORK/g72-$1.log" 2>&1
}

setup_stack
if [ -f "$ROOT/cache/chelper/testabi/$(khash)/c_helper.so" ]; then
	pass "G72: the known-good pair's library is cached under its source hash"
else
	fail "G72: the known-good pair's library was not cached"; ls -R "$ROOT/cache" 2>&1 | head
fi

g72_update ok
if [ "$(stack_field state)" = "healthy" ] && [ "$(stack_field known_good_klipper_commit)" = "$g_new_k" ] && \
   [ "$(cat "$KDIR/klippy/chelper/c_helper.so")" = "built for v2" ]; then
	pass "G72: an update that changes a chelper source gets the matching library from the index and is promoted"
else
	fail "G72: index library not installed (state=$(stack_field state))"; cat "$WORK/g72-ok.log"
fi
if grep -q '"library_from": "index"' "$KDIR/.nebulaos-chelper-verdict.json" && \
   grep -q "\"source_hash\": \"$g_h\"" "$KDIR/.nebulaos-chelper-verdict.json"; then
	pass "G72: the verdict names the library's origin and source hash"
else
	fail "G72: verdict lacks library_from/source_hash"; cat "$KDIR/.nebulaos-chelper-verdict.json"
fi
if [ -f "$ROOT/cache/chelper/testabi/$g_h/c_helper.so" ] && [ -z "$(git -C "$KDIR" status --porcelain)" ]; then
	pass "G72: the download is cached, and the Klipper tree stays clean (only the ignored *.so changed)"
else
	fail "G72: download not cached or Klipper tree dirty"; git -C "$KDIR" status --porcelain
fi
if grep -q "update manager did not settle" "$WORK/g72-ok.log"; then
	pass "G72: the stack path waits for update_manager to finish (pip) before validating"
else
	fail "G72: the stack path did not wait for update_manager"; cat "$WORK/g72-ok.log"
fi

for mode in badsha none down; do
	g72_update "$mode"
	if [ "$(khead)" = "$g_kg_k" ] && [ "$(stack_field state)" = "rolled-back" ] && \
	   [ "$(cat "$KDIR/klippy/chelper/c_helper.so")" = "prebuilt" ] && \
	   ! grep -q "klipper=$g_new_k" "$HEALTH_DIR/restarts.log" 2>/dev/null; then
		pass "G72 ($mode): no matching library - refused before restart, rolled back, and the restored pair gets its library from the cache (no factory fallback)"
	else
		fail "G72 ($mode): state=$(stack_field state) so=$(cat "$KDIR/klippy/chelper/c_helper.so")"; cat "$WORK/g72-$mode.log"
	fi
	if [ -z "$(find "$KDIR/klippy/chelper" -name '.nebulaos-install.*')" ] && \
	   [ -z "$(find "$ROOT/cache/chelper/testabi" -name '.dl.*' -o -name '.put.*')" ]; then
		pass "G72 ($mode): no temporary files left behind"
	else
		fail "G72 ($mode): temporary files left behind"
	fi
done
if grep -q "refusing" "$WORK/g72-badsha.log"; then
	pass "G72 (badsha): a library whose sha256 does not match the index is refused by name"
else
	fail "G72 (badsha): no refusal message"; cat "$WORK/g72-badsha.log"
fi

# S05 runs before Wi-Fi/DNS/NTP: it must never reach the index.
S05="$REPO_ROOT/scripts/build/overlay/etc/init.d/S05nebulaos-activate"
if ! grep -q 'chelper_fetch_index\|chelper_make_ready "$kdir" network\|NEBULAOS_CHELPER_FETCH' "$S05" && \
   grep -q 'chelper_make_ready "$kdir" cache' "$S05"; then
	pass "G72: S05 installs from the local cache only - never the network"
else
	fail "G72: S05 may reach the network for c_helper.so"
fi

unset NEBULAOS_PYTHON_ABI_FILE NEBULAOS_CHELPER_URL_FILE NEBULAOS_CHELPER_FETCH NEBULAOS_CHELPER_IMAGE_RECORD

# --- summary --------------------------------------------------------------

echo
echo "klipper-stack-update-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
