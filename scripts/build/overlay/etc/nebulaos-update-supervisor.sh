#!/bin/sh
#
# NebulaOS mutable-runtime mission, Phase 8: rollback orchestration and
# transaction state machine (docs/NEBULAOS_UPDATE_AND_ROLLBACK_DESIGN.md).
#
# Real constraint found while implementing this (not present in the design
# draft): this Moonraker version's update_manager (git_deploy.py/
# app_deploy.py, confirmed directly against vendor/moonraker source) has NO
# pre/post-update command hook at all - it performs fetch, checkout,
# venv/requirement sync, and service restart entirely on its own the moment
# a user clicks "update" in Mainsail, with no way for external code to run
# in between "new version staged" and "new version activated". The design
# doc's Stage 1 (pre-activation) / Stage 2 (post-activation) split is
# therefore collapsed here into a single post-hoc validation that runs
# after Moonraker has already restarted the affected service - this script
# is an independent poller, not a Moonraker plugin, specifically so it
# keeps working even if a bad update breaks Moonraker itself.
#
# Detection: git's own HEAD commit is polled per component. A change from
# the last-recorded value means "an update just happened" (via Moonraker's
# own update flow, or a manual git operation - this script does not care
# which). Rollback restores the previous known-good commit via
# `git reset --hard`, which needs no separate pre-update backup step for
# the source tree itself - git's own history/reflog already holds it,
# which is why known_good_commit is tracked here rather than snapshotting
# whole directory copies.
#
# Restart safety: never restarts a service while a print is active/paused
# (read-only Moonraker query, checked immediately before every restart -
# same printer-safety invariant as every other disruptive action in this
# project) - a deferred restart just waits and rechecks rather than
# skipping validation outright.
#
# NebulaOS mutable-runtime closure mission (2026-07-27), Phase D: Moonraker
# source and virtualenv are now one versioned release unit, not two
# independently-rolled-back things. Real gap this closes: Moonraker's own
# app_deploy.py._update_python_requirements() installs into the EXISTING
# venv in place whenever a commit changes requirements.txt - a plain
# `git reset --hard` on the source alone does nothing to undo whatever pip
# already did to the venv. Rather than re-implementing Moonraker's own
# in-place venv update logic (real risk of fighting/duplicating it), this
# supervisor instead maintains its own full backup of the venv, refreshed
# every time a (source, venv) pairing is confirmed healthy together, and
# always restores BOTH halves together on rollback - since only one paired
# backup ever exists at a time and both halves are always reset in the same
# step, there is no code path that can produce a mismatched pair.

# NebulaOS Phase 1 no-fork migration (2026-08-17), Phase I: the validated,
# rollback-able unit for the Klipper side is now the PAIR
# (klipper_sha, extensions_sha), not Klipper alone.
#
# Why the pair has to be the unit, concretely. NebulaOS runs official,
# unmodified Klipper with its own modules composed in from a separately
# updatable repository, and Moonraker can update either half independently -
# it has no cross-component ordering, no dependency gate, and no post-update
# hook. Two failure modes follow directly:
#
#   * new Klipper + old extensions: a Klipper update that touches any file
#     in klippy/chelper/ makes the shipped cross-compiled c_helper.so older
#     than a source, so Klipper's own mtime check decides to rebuild it with
#     gcc - which this device does not have. Klippy does not start. An API
#     rename lands here too: mainline already renamed
#     MCU.register_response() to register_serial_response() once.
#   * new extensions + old Klipper: the extension set's own preflight
#     refuses to load against a Klipper it was not qualified against, which
#     is the designed behaviour, but leaves the printer down until something
#     puts the pair back together.
#
# So this file keeps ONE shared lock, ONE known-good record naming both
# commits, and ONE validation that either promotes both halves or rolls back
# both. A known-good pair is never recorded until both halves have actually
# passed - there is no code path that can record commit A paired with a
# snapshot belonging to a different commit, the same property
# moonraker_snapshot_env/moonraker_restore_env already give the Moonraker
# source+venv pairing below, and this is deliberately modelled on it rather
# than being a second, parallel transaction framework.
#
# Recomposition is part of the transaction, not a side effect: after any
# change to either half, the symlink set is rebuilt and re-verified BEFORE
# Klippy is restarted, which is also when the collision guard and the
# c_helper.so mtime invariant get re-run. A stale library is caught here and
# refused, instead of surfacing as a gcc crash part-way through boot.

# Paths and timings are overridable purely so the offline scenario tests in
# tests/klipper-stack-update-tests.sh can drive this file against fixture
# directories and stubbed services instead of a printer - the same seam
# convention S02/S04/S05 already use for SEEDS/APPS/SYSTEM/LOCKDIR/GATE_LIB.
# Real boot sets none of them, so every ":-" below resolves to the production
# value. The timings in particular exist because the real ones are measured
# against a printer that genuinely takes 15-25s to reconnect to its MCU, and
# a test suite cannot wait several minutes per scenario to learn that.
NEBULAOS_ROOT="${NEBULAOS_ROOT:-/usr/data/nebulaos}"
HEALTHCHECK="${HEALTHCHECK:-/etc/nebulaos-healthcheck.sh}"
COMPOSE_LIB="${COMPOSE_LIB:-/etc/nebulaos-klipper-compose.sh}"
CHELPER_LIB="${CHELPER_LIB:-/etc/nebulaos-chelper-preflight.sh}"
LOCKDIR="${LOCKDIR:-$NEBULAOS_ROOT/updates/locks}"
MOONRAKER_URL="${MOONRAKER_URL:-http://127.0.0.1:7125}"
MOONRAKER_ENV="$NEBULAOS_ROOT/envs/moonraker"
MOONRAKER_ENV_BACKUP="$NEBULAOS_ROOT/backups/moonraker/last-known-good-env"
GENERATION_FILE="${GENERATION_FILE:-$NEBULAOS_ROOT/system/app-generation.json}"
POLL_INTERVAL="${POLL_INTERVAL:-20}"
STABILIZE_SAMPLES="${STABILIZE_SAMPLES:-6}"
STABILIZE_INTERVAL="${STABILIZE_INTERVAL:-10}"
RESTART_GRACE_PERIOD="${RESTART_GRACE_PERIOD:-25}"
READY_POLL_TRIES="${READY_POLL_TRIES:-18}"
READY_POLL_INTERVAL="${READY_POLL_INTERVAL:-10}"

# The two halves of the Klipper stack, and the one lock and one state record
# that cover both. The lock name is shared with S05nebulaos-activate, which
# refuses to activate either half while it is held.
KLIPPER_APP="klipper"
EXTENSIONS_APP="nebulaos-klipper-extensions"
STACK_NAME="klipper-stack"

# Scenario 3 of the update-ordering analysis: both components updated close
# together. Moonraker serializes the update REQUESTS but nothing more, so two
# updates can land seconds apart. Validating the moment the first HEAD moves
# would mean restarting Klippy against a pair whose second half is still
# being written. Instead, re-read both HEADs after a short settle window and
# defer to the next poll if either is still moving - a deferral costs one
# poll interval, a torn pair costs a rollback cycle.
PAIR_SETTLE_SECONDS="${PAIR_SETTLE_SECONDS:-15}"

[ -f "$COMPOSE_LIB" ] && . "$COMPOSE_LIB"
[ -f "$CHELPER_LIB" ] && . "$CHELPER_LIB"

log() {
	echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) nebulaos-update-supervisor: $1"
}

# Phase 1.5 generation-scoped rollback: the update supervisor's own
# known-good records must belong to the SAME image generation as the
# currently running system. A new image flash changes the factory pins
# (different migration_version), and the old persistent known-good commits
# are from a different generation's factory stack — rolling back to them
# would produce a pair the new image was never qualified against.
#
# This reads the same app-generation.json that S04nebulaos-migrate writes
# after every successful migration. If the file does not exist (first boot
# before S04 has run), returns empty — callers treat empty as "no
# generation recorded yet", which is correct: the bootstrap path will
# record the current generation once it runs.
current_generation() {
	[ -f "$GENERATION_FILE" ] || return 0
	sed -n 's/.*"migration_version": *"\([^"]*\)".*/\1/p' "$GENERATION_FILE" | head -1
}

# $1=component name -> echoes: path|init_script|opt_path|pidfile
component_info() {
	case "$1" in
		klipper)
			echo "$NEBULAOS_ROOT/apps/klipper|/etc/init.d/S55klipper|/opt/klipper|/var/run/klippy.pid"
			;;
		nebulaos-klipper-extensions)
			# Deliberately shares Klipper's init script, /opt path and
			# pidfile. The extension set has no service of its own - it is
			# code Klippy loads, so "restart the extensions" means "restart
			# Klippy", and "fall back to immutable" means unmounting the same
			# /opt/klipper bind (whose squashfs copy carries these modules as
			# real files precisely so that fallback is a complete install).
			echo "$NEBULAOS_ROOT/apps/nebulaos-klipper-extensions|/etc/init.d/S55klipper|/opt/klipper|/var/run/klippy.pid"
			;;
		moonraker)
			echo "$NEBULAOS_ROOT/apps/moonraker|/etc/init.d/S56moonraker|/opt/moonraker|/var/run/moonraker.pid"
			;;
		mainsail)
			echo "$NEBULAOS_ROOT/apps/mainsail||/usr/share/mainsail|"
			;;
	esac
}

state_file() {
	echo "$NEBULAOS_ROOT/updates/$1/state.json"
}

read_state_field() {
	# $1=component $2=field
	f=$(state_file "$1")
	[ -e "$f" ] || return 0
	sed -n "s/.*\"$2\": *\"\([^\"]*\)\".*/\1/p" "$f" | head -1
}

write_state() {
	# $1=component $2=known_good $3=last_seen $4=state $5=reason
	f=$(state_file "$1")
	tmp="$f.tmp.$$"
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	gen=$(current_generation)
	{
		echo "{"
		echo "  \"component\": \"$1\","
		echo "  \"generation_id\": \"${gen:-unknown}\","
		echo "  \"known_good_commit\": \"$2\","
		echo "  \"last_seen_commit\": \"$3\","
		echo "  \"state\": \"$4\","
		echo "  \"last_transition_at\": \"$now\","
		echo "  \"last_failure_reason\": \"$5\""
		echo "}"
	} > "$tmp"
	mv "$tmp" "$f"
}

# Read-only query, never combined with a restart in the same step - a
# printing/paused state means "wait", not "skip validation".
# Markers published by nebulaos-memguard (MEM-T12/T14). Absent means normal.
NEBULAOS_RUN_DIR="${NEBULAOS_RUN_DIR:-/run/nebulaos}"

print_is_active() {
	# MEM-T16: memguard's print state is sticky across a dead or restarting
	# Moonraker; trust it first, so an unreachable Moonraker never reads as
	# "not printing".
	[ -e "$NEBULAOS_RUN_DIR/print-active" ] && return 0
	stats=$(wget -q -O - --timeout=5 "$MOONRAKER_URL/printer/objects/query?print_stats=state" 2>/dev/null)
	case "$stats" in
		*'"state":"printing"'*|*'"state":"paused"'*) return 0 ;;
		*) return 1 ;;
	esac
}

# Waits (bounded) for any active print to finish before a disruptive
# restart - never forces a restart mid-print.
wait_for_print_idle() {
	tries=0
	while print_is_active; do
		tries=$((tries + 1))
		if [ "$tries" -ge 90 ]; then
			log "print still active after $((tries * 10))s - deferring restart, will re-check next poll cycle"
			return 1
		fi
		sleep 10
	done
	return 0
}

# Real bug found live (Moonraker paired-rollback test, 2026-07-27): a
# genuinely pre-existing race in this project's own init scripts -
# S55klipper/S56moonraker's own `restart() { stop; start; }` calls stop
# and start back-to-back with zero delay. BusyBox's start-stop-daemon's
# start step detects the OLD process (still genuinely mid-graceful-
# shutdown, not yet exited - confirmed live: "python3 is already
# running", moonraker down entirely for 3.5+ minutes afterward) and
# silently refuses to launch a new one. Using the combined "restart"
# action never gave this project's own fail-fast health checks anything
# to actually detect - not a false positive that time, a real missed
# restart. Splitting stop/start with an explicit wait for genuine process
# exit in between avoids the race entirely; not modifying
# S55klipper/S56moonraker's own frozen restart action itself, since
# normal (non-rollback, lower-I/O-contention) restarts elsewhere in this
# project have never hit this race in practice - only this supervisor's
# own restart calls need the fix.
safe_stop_start() {
	# $1=component
	info=$(component_info "$1")
	init_script=$(echo "$info" | cut -d'|' -f2)
	pidfile=$(echo "$info" | cut -d'|' -f4)
	"$init_script" stop
	if [ -n "$pidfile" ]; then
		tries=0
		while [ -f "$pidfile" ] && [ -d "/proc/$(cat "$pidfile" 2>/dev/null)" ] 2>/dev/null; do
			tries=$((tries + 1))
			if [ "$tries" -ge 20 ]; then
				log "$1: old process still not exited after ${tries}s - proceeding with start anyway"
				break
			fi
			sleep 1
		done
	fi
	"$init_script" start
}

restart_component() {
	# $1=component
	info=$(component_info "$1")
	init_script=$(echo "$info" | cut -d'|' -f2)
	# MEM-T16: under memory pressure memguard denies maintenance; defer.
	if [ -e "$NEBULAOS_RUN_DIR/memguard/deny-maintenance" ]; then
		log "$1: restart deferred - memguard reports memory pressure"
		return 1
	fi
	wait_for_print_idle || return 1
	log "$1: restarting via $init_script"
	safe_stop_start "$1"
	# Real bug found live (first rollback test, 2026-07-26): Klipper
	# legitimately takes 15-25s to reconnect to the MCU and reach
	# klippy_state=ready after a process restart (confirmed repeatedly
	# elsewhere in this project's own qualification logs) - sampling
	# stage2 immediately mistook "still connecting" for "broken" and
	# triggered a false-positive rollback failure straight into
	# factory-fallback. This grace period must elapse before the
	# caller's first stage2 sample.
	sleep "$RESTART_GRACE_PERIOD"
	return 0
}

# Real bug found live (Moonraker paired-rollback test, 2026-07-27): even
# with restart_component's fixed grace period, a restart immediately
# following a venv restore (real extra disk I/O from cp -a on top of the
# git reset) sometimes needed longer than the grace period + first sample
# to reach ready - moonraker.log showed a completely clean startup and
# "Klippy ready" moments after the poller had already given up and gone to
# factory-fallback. A fixed grace period can't account for variable extra
# load from whatever the rollback itself just did. Splits stabilization
# into two phases: first, tolerantly POLL (not fail-fast) for the system
# to become ready at all within a generous bound; only once it has been
# seen ready at least once do subsequent samples fail fast - a check
# failing AFTER a prior success is a real, new problem (e.g. crashed right
# after starting), not startup variance, and should still be caught
# quickly.
wait_for_initial_ready() {
	tries=0
	max_tries="$READY_POLL_TRIES"
	while [ "$tries" -lt "$max_tries" ]; do
		"$HEALTHCHECK" stage2 && return 0
		tries=$((tries + 1))
		sleep "$READY_POLL_INTERVAL"
	done
	return 1
}

# Confirms health STAYS true for a short window after first becoming
# ready - fails fast on any bad sample here, since by this point the
# system has already proven it can start; a failure now is a real
# regression, not startup timing.
stabilized_stage2() {
	wait_for_initial_ready || return 1
	i=0
	while [ "$i" -lt "$STABILIZE_SAMPLES" ]; do
		sleep "$STABILIZE_INTERVAL"
		if ! "$HEALTHCHECK" stage2; then
			return 1
		fi
		i=$((i + 1))
	done
	return 0
}

# Preserves the failed commit + relevant logs under backups/<name>/failed-*
# per the mission's own "never silently discard evidence" requirement -
# never overwrites a previous failed-<timestamp> directory.
preserve_failure_evidence() {
	# $1=component $2=failed_commit $3=reason
	name="$1"; failed_commit="$2"; reason="$3"
	ts=$(date -u +%Y%m%dT%H%M%SZ)
	dir="$NEBULAOS_ROOT/backups/$name/failed-$ts"
	mkdir -p "$dir"
	{
		echo "failed_commit=$failed_commit"
		echo "reason=$reason"
		echo "detected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	} > "$dir/metadata.txt"
	case "$name" in
		klipper) cp /opt/printer_data/logs/klippy.log "$dir/" 2>/dev/null ;;
		moonraker) cp /opt/printer_data/logs/moonraker.log "$dir/" 2>/dev/null ;;
		mainsail)
			cp /var/log/nginx/mainsail-error.log "$dir/" 2>/dev/null
			cp "$NEBULAOS_ROOT/apps/mainsail/release_info.json" "$dir/" 2>/dev/null
			;;
	esac
	log "$name: failure evidence preserved at $dir"
}

# Removes the bind mount, exposing the pristine immutable /opt/<app> copy
# underneath for the rest of this boot, and leaves the update lock in place
# so S05nebulaos-activate stays on immutable on every future boot too, until
# a human clears it - never silently re-attempts the same broken version.
factory_fallback() {
	# $1=component
	info=$(component_info "$1")
	opt_path=$(echo "$info" | cut -d'|' -f3)
	log "$1: falling back to factory/immutable copy at $opt_path (both new and previous versions failed validation)"
	if awk -v t="$opt_path" '$2==t {found=1} END{exit !found}' /proc/mounts; then
		umount "$opt_path" 2>/dev/null
	fi
	init_script=$(echo "$info" | cut -d'|' -f2)
	# Mainsail has no managed service (static files served directly by
	# nginx, no restart needed for the fallback content to take effect) -
	# component_info's mainsail entry deliberately leaves this field empty.
	[ -n "$init_script" ] || return 0
	wait_for_print_idle
	safe_stop_start "$1"
}

# NebulaOS mutable-runtime closure mission (2026-07-27), Phase C: Mainsail
# rollback. Real constraint confirmed against vendor/moonraker's own
# net_deploy.py: unlike git (where history/reflog gives a "previous version"
# for free), NetDeploy._extract_release() does `shutil.rmtree(self.path)`
# on every update with NO backup of its own - the previous release's files
# are simply gone once Moonraker's update() runs. This supervisor must
# therefore maintain its own independent snapshot of the last-known-healthy
# release, taken proactively (whenever a version is confirmed healthy), so
# there is something real to restore from after the fact - not reactively
# after detecting a bad update, by which point the old files no longer
# exist on disk at all.
#
# Detection uses release_info.json's own "version" field (written by
# Moonraker's net_deploy for a real update) rather than a git commit -
# falls back to a content hash of index.html for the offline factory seed,
# which ships without a release_info.json at all.
#
# No service restart is needed for activation/rollback - nginx serves
# whatever static files are currently on disk, so a directory swap alone is
# the entire "restart" for this component.

MAINSAIL_BACKUP="$NEBULAOS_ROOT/backups/mainsail/last-known-good"

mainsail_version() {
	path="$1"
	if [ -f "$path/release_info.json" ]; then
		sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$path/release_info.json" | head -1
	else
		sha256sum "$path/index.html" 2>/dev/null | cut -d' ' -f1
	fi
}

# Discards any leftover .staging/.old directories from an interrupted
# snapshot/restore (device power-loss or reboot mid-operation) - both names
# are, by construction, never the live/active copy, so removing them on
# supervisor startup is always safe. Mirrors the mission's own required
# "discard incomplete staging" boot-recovery behavior. Covers both Mainsail
# and the Moonraker paired-venv backup, since both use the same
# atomic_directory_replace() staging/old naming convention.
cleanup_stale_staging() {
	rm -rf "$NEBULAOS_ROOT/apps/mainsail.staging" "$NEBULAOS_ROOT/apps/mainsail.old" \
		"$MAINSAIL_BACKUP.staging" "$MAINSAIL_BACKUP.old" \
		"$MOONRAKER_ENV.staging" "$MOONRAKER_ENV.old" \
		"$MOONRAKER_ENV_BACKUP.staging" "$MOONRAKER_ENV_BACKUP.old"
}

# Atomic-ish swap: build the full copy in a .staging sibling first, then
# two directory renames (each a single, near-instant syscall) to cut over -
# a process killed at any point before the first rename leaves the
# original completely untouched; killed between the two renames leaves the
# original moved aside as .old (recoverable) with the new copy already live.
# Not a true atomic transaction (a reader could observe a brief window with
# neither name present between the two renames), an accepted, documented
# tradeoff for a local dev-printer UI, not a highly concurrent service.
atomic_directory_replace() {
	# $1=new content source dir  $2=final target dir
	src="$1"; dst="$2"
	staging="$dst.staging"
	old="$dst.old"
	rm -rf "$staging" "$old"
	mkdir -p "$(dirname "$staging")"
	cp -a "$src" "$staging"
	if [ -e "$dst" ]; then
		mv "$dst" "$old"
	fi
	mv "$staging" "$dst"
	rm -rf "$old"
}

mainsail_snapshot_to_backup() {
	path="$NEBULAOS_ROOT/apps/mainsail"
	[ -d "$path" ] || return 0
	atomic_directory_replace "$path" "$MAINSAIL_BACKUP"
}

# Real bug found live (Mainsail rollback retest, 2026-07-27): restoring the
# backup INTO $NEBULAOS_ROOT/apps/mainsail via atomic_directory_replace
# renames that directory away and creates a new one at the same name - but
# S05nebulaos-activate's bind mount (/usr/share/mainsail) was established
# against the ORIGINAL directory's inode, which Linux keeps valid at its
# new (renamed-away) location rather than "following" the name back to
# whatever now occupies the old path. nginx kept serving the stale,
# now-unlinked old content the whole time, while direct inspection of the
# path by name showed the freshly-restored good content - stage2-mainsail's
# real HTTP check correctly saw broken/stale content and correctly failed,
# it was atomic_directory_replace's rename semantics that were wrong for a
# path with an active bind mount sourced from it. Klipper/Moonraker's own
# git reset --hard never hits this because it rewrites file content INSIDE
# the same directory/inode, never renaming the directory itself - only
# Mainsail's restore path (the only user of atomic_directory_replace on an
# actively bind-mounted source) needed this fix.
remount_mainsail_bind() {
	target=/usr/share/mainsail
	if awk -v t="$target" '$2==t {found=1} END{exit !found}' /proc/mounts; then
		umount "$target" 2>/dev/null
	fi
	mount --bind "$NEBULAOS_ROOT/apps/mainsail" "$target"
}

# A first live test looked like a transient WiFi-blip false positive
# (single failed wget sample right after an atomic directory swap) - the
# real cause, found on a second reproduction, was the bind-mount desync
# documented above at remount_mainsail_bind(), now fixed at the source.
# Kept as a real, if now mostly redundant, defense: nginx serves static
# files with no restart/reload needed, so a few quick retries cost nothing
# if an actual transient hiccup ever does occur.
stabilized_stage2_mainsail() {
	i=0
	while [ "$i" -lt 3 ]; do
		"$HEALTHCHECK" stage2-mainsail && return 0
		sleep 3
		i=$((i + 1))
	done
	return 1
}

validate_mainsail() {
	name="mainsail"
	path="$NEBULAOS_ROOT/apps/mainsail"
	new_version=$(mainsail_version "$path")
	known_good=$(read_state_field "$name" known_good_commit)

	mkdir -p "$LOCKDIR"
	: > "$LOCKDIR/$name.lock"
	write_state "$name" "$known_good" "$new_version" "validating" ""

	log "$name: new version detected ($new_version) - validating"

	# Real bug found live (2026-07-27): this same desync also affects a
	# genuine Mainsail update via Moonraker's own net_deploy.py, which does
	# the same shutil.rmtree()+mkdir() on this bind-mount's source
	# directory - a Linux bind mount stays pinned to the original inode
	# regardless of what happens to the path used to create it, so nginx
	# would otherwise keep serving stale pre-update content indefinitely
	# (invisible to any HTTP-based health check, since the check itself
	# would only ever see the OLD content) until a reboot happened to
	# re-run S05nebulaos-activate. Remounting here, on every detected
	# version change and before any health check runs, makes the check
	# actually test what was just installed - not what used to be there.
	remount_mainsail_bind

	stage1_ok=true
	"$HEALTHCHECK" stage1 "$name" "$path" || stage1_ok=false

	if [ "$stage1_ok" = "true" ] && stabilized_stage2_mainsail; then
		log "$name: new version $new_version passed full validation - recording as known-good"
		write_state "$name" "$new_version" "$new_version" "healthy" ""
		mainsail_snapshot_to_backup
		rm -f "$LOCKDIR/$name.lock"
		return
	fi

	reason="stage2_failed"
	[ "$stage1_ok" = "true" ] || reason="stage1_failed"
	log "$name: $reason on new version $new_version - restoring from last-known-good backup"
	preserve_failure_evidence "$name" "$new_version" "$reason"

	if [ ! -d "$MAINSAIL_BACKUP" ]; then
		log "$name: no backup exists yet (first-ever validation failed) - going straight to factory-fallback"
		preserve_failure_evidence "$name" "$known_good" "no_backup_available"
		factory_fallback "$name"
		write_state "$name" "$known_good" "$known_good" "factory-fallback" "${reason}:$new_version;no_backup_available"
		return
	fi

	atomic_directory_replace "$MAINSAIL_BACKUP" "$path"
	remount_mainsail_bind
	if "$HEALTHCHECK" stage1 "$name" "$path" && stabilized_stage2_mainsail; then
		log "$name: restored backup re-validated healthy"
		write_state "$name" "$known_good" "$known_good" "rolled-back" "${reason}:$new_version"
		rm -f "$LOCKDIR/$name.lock"
	else
		preserve_failure_evidence "$name" "$known_good" "stage2_failed_after_restore"
		factory_fallback "$name"
		write_state "$name" "$known_good" "$known_good" "factory-fallback" "${reason}:$new_version;previous_also_unhealthy"
	fi
}

poll_mainsail_once() {
	name="mainsail"
	path="$NEBULAOS_ROOT/apps/mainsail"
	[ -f "$path/index.html" ] || return 0

	current=$(mainsail_version "$path")
	[ -z "$current" ] && return 0

	last_seen=$(read_state_field "$name" last_seen_commit)

	# Phase 1.5 generation-scoped rollback (mainsail).
	gen=$(current_generation)
	if [ -n "$last_seen" ] && [ -n "$gen" ]; then
		state_gen=$(read_state_field "$name" generation_id)
		if [ -n "$state_gen" ] && [ "$state_gen" != "$gen" ]; then
			log "$name: cross-generation state detected (state generation '$state_gen', current '$gen') - discarding old known-good and re-bootstrapping"
			write_state "$name" "$current" "$current" "healthy" "cross_generation_rebootstrap:$state_gen"
			mainsail_snapshot_to_backup
			return 0
		fi
	fi

	if [ -z "$last_seen" ]; then
		# First observation this boot - bootstrap state and take the first
		# backup snapshot, matching the moonraker/Klipper-stack bootstrap
		# behavior (whatever is running now was already proven at boot).
		write_state "$name" "$current" "$current" "healthy" ""
		mainsail_snapshot_to_backup
		log "$name: bootstrapped state at $current"
		return 0
	fi

	state=$(read_state_field "$name" state)
	if [ -e "$LOCKDIR/$name.lock" ] && [ "$state" = "factory-fallback" ]; then
		return 0
	fi
	if [ "$current" != "$last_seen" ] && [ "$state" != "validating" ]; then
		validate_mainsail
	fi
}

# Snapshots the current Moonraker venv as the new last-known-good pairing
# partner. Only called immediately after the SOURCE at this same commit has
# already passed full validation, so "the venv currently on disk" is by
# definition the one that was just proven to work with this exact source.
moonraker_snapshot_env() {
	[ -d "$MOONRAKER_ENV" ] || return 0
	atomic_directory_replace "$MOONRAKER_ENV" "$MOONRAKER_ENV_BACKUP"
}

# Restores the paired venv backup. Returns 1 (without restoring anything)
# if no backup exists yet - caller must treat this the same as Mainsail's
# "no backup available" case and go straight to factory-fallback rather
# than restart Moonraker against a half-reset pairing.
moonraker_restore_env() {
	[ -d "$MOONRAKER_ENV_BACKUP" ] || return 1
	atomic_directory_replace "$MOONRAKER_ENV_BACKUP" "$MOONRAKER_ENV"
	return 0
}

# ==========================================================================
# Klipper stack: the (klipper, extensions) pair as one transactional unit
# ==========================================================================

stack_head() {
	# $1=app name -> current HEAD, or empty if the checkout is unusable
	git -C "$NEBULAOS_ROOT/apps/$1" rev-parse HEAD 2>/dev/null
}

stack_state_file() {
	echo "$NEBULAOS_ROOT/updates/$STACK_NAME/state.json"
}

read_stack_field() {
	f=$(stack_state_file)
	[ -e "$f" ] || return 0
	sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "$f" | head -1
}

# Both commits always travel together, in one file, written atomically. A
# known-good pair is only ever written by a caller that has just seen BOTH
# halves pass, which is what makes a mismatched record unrepresentable rather
# than merely unlikely.
write_stack_state() {
	# $1=kg_klipper $2=kg_extensions $3=seen_klipper $4=seen_extensions
	# $5=state $6=reason
	f=$(stack_state_file)
	mkdir -p "$(dirname "$f")"
	tmp="$f.tmp.$$"
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	gen=$(current_generation)
	{
		echo "{"
		echo "  \"component\": \"$STACK_NAME\","
		echo "  \"generation_id\": \"${gen:-unknown}\","
		echo "  \"members\": [\"$KLIPPER_APP\", \"$EXTENSIONS_APP\"],"
		echo "  \"known_good_klipper_commit\": \"$1\","
		echo "  \"known_good_extensions_commit\": \"$2\","
		echo "  \"last_seen_klipper_commit\": \"$3\","
		echo "  \"last_seen_extensions_commit\": \"$4\","
		echo "  \"state\": \"$5\","
		echo "  \"last_transition_at\": \"$now\","
		echo "  \"last_failure_reason\": \"$6\""
		echo "}"
	} > "$tmp"
	mv "$tmp" "$f"
}

# Rebuild the symlink composition and re-run both pre-restart gates.
# Called before every Klippy restart this file performs on the stack, because
# every one of them follows a change to one half or the other.
recompose_klipper_stack() {
	kdir="$NEBULAOS_ROOT/apps/$KLIPPER_APP"
	edir="$NEBULAOS_ROOT/apps/$EXTENSIONS_APP"

	if ! command -v compose_ensure >/dev/null 2>&1; then
		log "$STACK_NAME: $COMPOSE_LIB is not available - cannot verify the composition, refusing to restart Klipper into an unverified stack"
		return 1
	fi
	if ! compose_ensure "$kdir" "$edir"; then
		log "$STACK_NAME: recomposition FAILED - either upstream Klipper now ships a file at a path this extension set manages (the collision guard), or a managed link no longer resolves into the extensions tree"
		return 1
	fi
	if ! command -v chelper_write_verdict >/dev/null 2>&1; then
		log "$STACK_NAME: $CHELPER_LIB is not available - cannot verify the c_helper.so mtime invariant, refusing"
		return 1
	fi
	if ! chelper_write_verdict "$kdir"; then
		log "$STACK_NAME: the c_helper.so mtime invariant does NOT hold for this pair. This is the classic new-Klipper/old-prebuilt-library failure: Klippy would shell out to gcc, which this device does not have, and would not start. Refusing to restart into it."
		return 1
	fi
	return 0
}

# Put both halves back on the last validated pair, recompose, and prove it.
# Never resets one half without the other - that is the whole point.
restore_known_good_pair() {
	# $1=kg_klipper $2=kg_extensions
	kg_k="$1"; kg_e="$2"
	if [ -z "$kg_k" ] || [ -z "$kg_e" ]; then
		log "$STACK_NAME: no complete known-good pair on record - cannot restore"
		return 1
	fi
	log "$STACK_NAME: restoring the last validated pair (klipper $kg_k, extensions $kg_e)"
	git -C "$NEBULAOS_ROOT/apps/$KLIPPER_APP" reset --hard "$kg_k" >/dev/null 2>&1
	git -C "$NEBULAOS_ROOT/apps/$EXTENSIONS_APP" reset --hard "$kg_e" >/dev/null 2>&1
	# git reset --hard leaves the composed symlinks intact (they are
	# excluded, so `clean` ignores them and `reset` has no tracked entry to
	# overwrite), but the SOURCE they point into has just changed content and
	# the pair generation has moved - so recompose and re-verify rather than
	# assuming the old link set still describes reality.
	recompose_klipper_stack
}

# The pair validation. Structurally the same shape as validate_component()
# above - lock, mark validating, stage1, stabilized stage2, promote or roll
# back, preserve evidence, factory-fallback if the previous pair is also
# unhealthy - with the single difference that every step operates on two
# commits instead of one.
validate_klipper_stack() {
	new_k=$(stack_head "$KLIPPER_APP")
	new_e=$(stack_head "$EXTENSIONS_APP")
	kg_k=$(read_stack_field known_good_klipper_commit)
	kg_e=$(read_stack_field known_good_extensions_commit)

	mkdir -p "$LOCKDIR"
	# One lock for the whole stack. S05nebulaos-activate honours this same
	# name and will not activate either half while it is held, so a reboot
	# in the middle of this transaction cannot bring the printer up on a
	# half-validated pair.
	: > "$LOCKDIR/$STACK_NAME.lock"
	write_stack_state "$kg_k" "$kg_e" "$new_k" "$new_e" "validating" ""

	log "$STACK_NAME: new pair detected (klipper $new_k, extensions $new_e) - validating as one unit"

	# Pre-restart gates. These run BEFORE Klippy is touched, which is what
	# turns "Klippy crashed on boot" into "the pair was refused and rolled
	# back with the printer still running the old one".
	if ! recompose_klipper_stack; then
		log "$STACK_NAME: pre-restart validation FAILED on the new pair - rolling back to (klipper $kg_k, extensions $kg_e) without restarting Klipper"
		preserve_failure_evidence "$KLIPPER_APP" "$new_k" "stack_precheck_failed"
		preserve_failure_evidence "$EXTENSIONS_APP" "$new_e" "stack_precheck_failed"
		stack_roll_back "$kg_k" "$kg_e" "precheck_failed:$new_k+$new_e"
		return
	fi

	stage1_ok=true
	"$HEALTHCHECK" stage1 "$KLIPPER_APP" "$NEBULAOS_ROOT/apps/$KLIPPER_APP" || stage1_ok=false

	if [ "$stage1_ok" = "true" ]; then
		restart_component "$KLIPPER_APP" || {
			log "$STACK_NAME: restart deferred (print active) - will re-check next poll cycle"
			write_stack_state "$kg_k" "$kg_e" "$new_k" "$new_e" "validating" "restart_deferred"
			return
		}
		if stabilized_stage2; then
			# BOTH halves have now passed together. Only here is a pair
			# recorded as known-good.
			log "$STACK_NAME: the new pair (klipper $new_k, extensions $new_e) passed full validation - recording as the known-good pair"
			write_stack_state "$new_k" "$new_e" "$new_k" "$new_e" "healthy" ""
			rm -f "$LOCKDIR/$STACK_NAME.lock"
			return
		fi
		reason="stage2_failed"
	else
		reason="stage1_failed"
	fi

	log "$STACK_NAME: $reason on the new pair - reverting BOTH halves to the last validated pair"
	preserve_failure_evidence "$KLIPPER_APP" "$new_k" "$reason"
	preserve_failure_evidence "$EXTENSIONS_APP" "$new_e" "$reason"
	stack_roll_back "$kg_k" "$kg_e" "$reason:$new_k+$new_e"
}

# Shared rollback tail for every failure path above.
stack_roll_back() {
	kg_k="$1"; kg_e="$2"; reason="$3"

	if [ -z "$kg_k" ] || [ -z "$kg_e" ]; then
		log "$STACK_NAME: no complete known-good pair exists yet (first-ever validation failed) - going straight to factory-fallback rather than restore a half-known pair"
		preserve_failure_evidence "$KLIPPER_APP" "$kg_k" "no_known_good_pair"
		factory_fallback "$KLIPPER_APP"
		write_stack_state "$kg_k" "$kg_e" "$kg_k" "$kg_e" "factory-fallback" "$reason;no_known_good_pair"
		return
	fi

	if ! restore_known_good_pair "$kg_k" "$kg_e"; then
		log "$STACK_NAME: the known-good pair could not be restored and recomposed - falling back to the immutable copy"
		preserve_failure_evidence "$KLIPPER_APP" "$kg_k" "restore_or_recompose_failed"
		factory_fallback "$KLIPPER_APP"
		write_stack_state "$kg_k" "$kg_e" "$kg_k" "$kg_e" "factory-fallback" "$reason;restore_failed"
		return
	fi

	restart_component "$KLIPPER_APP"
	if stabilized_stage2; then
		log "$STACK_NAME: the restored pair re-validated healthy"
		# last_seen must reflect what is ACTUALLY on disk now (the restored
		# pair), not the rejected commits - recording the rejected ones here
		# is the exact bug validate_component() documents: the next poll
		# would see current != last_seen, mistake an already-failed-over
		# state for a fresh update, and re-trigger validation.
		write_stack_state "$kg_k" "$kg_e" "$kg_k" "$kg_e" "rolled-back" "$reason"
		rm -f "$LOCKDIR/$STACK_NAME.lock"
	else
		preserve_failure_evidence "$KLIPPER_APP" "$kg_k" "stage2_failed_after_pair_rollback"
		factory_fallback "$KLIPPER_APP"
		write_stack_state "$kg_k" "$kg_e" "$kg_k" "$kg_e" "factory-fallback" "$reason;previous_pair_also_unhealthy"
	fi
}

# Scenario 6: power loss part-way through a pair transaction. A state of
# "validating" that survives into a new supervisor process means this
# process's predecessor died mid-transaction, so nothing about the pair
# currently on disk has been proven. Clear the marker and let the normal
# delta detection below re-validate from scratch; the composition rebuild is
# idempotent and the exclude writes are grep-before-append, so a torn
# half-composed tree from the same crash heals on the next compose.
reconcile_klipper_stack_on_boot() {
	state=$(read_stack_field state)
	[ "$state" = "validating" ] || return 0
	log "$STACK_NAME: found an interrupted pair transaction from a previous supervisor process (state=validating) - nothing on disk has been validated, so it will be re-validated from scratch"
	kg_k=$(read_stack_field known_good_klipper_commit)
	kg_e=$(read_stack_field known_good_extensions_commit)
	# last_seen is deliberately reset to the known-good pair, not to what is
	# on disk: that is what makes the next poll see a delta and re-validate,
	# rather than silently accepting an unvalidated pair as current.
	write_stack_state "$kg_k" "$kg_e" "$kg_k" "$kg_e" "interrupted" "supervisor_restarted_mid_transaction"
	rm -f "$LOCKDIR/$STACK_NAME.lock"
}

# Real device found live (Phase 1.5 hardware qualification, 2026-08-19): the
# Scenario 6 crash reconcile_klipper_stack_on_boot() exists for was never
# generalized past the klipper_stack pair. A device's supervisor died
# mid-validate_component("klipper") on 2026-08-09 (back when klipper was
# still in the generic per-component loop, before the no-fork migration
# removed it), leaving updates/locks/klipper.lock + state=validating behind.
# Nothing ever reconciled it - poll_once's per-component loop treats
# state="validating" as "already in flight, skip" forever (there is no
# boot-time check equivalent to this one) - so it stayed stuck for 10 days
# and untold boots. Independently, S04nebulaos-migrate's own maintenance
# gate refuses to run migration on an already-seeded device with any lock
# present (by design - see that file's own header), and
# S05nebulaos-activate's validate_app() stays on the immutable copy for the
# same lock, on every boot. Nothing anywhere ever surfaced why.
#
# Generalizes the exact same fix: any component whose state file still says
# "validating" when a NEW supervisor process starts up did not survive its
# own transaction - nothing on disk it was validating has been proven - so
# it is safe to treat as interrupted and let normal delta detection
# re-validate from scratch, exactly like Scenario 6 already does for the
# pair. Covers moonraker and mainsail today, and any legacy single-component
# lock (like the klipper.lock above) a device may still be carrying from
# before the no-fork migration. $STACK_NAME is excluded - reconcile_klipper_
# stack_on_boot already owns it and runs separately (see loop() below).
#
# Phase 1.5 hardware closure (2026-08-19): iterates state.json files, NOT
# lock files - nebulaos-maintenance-gate.sh's own
# _maintenance_gate_reconcile_stale_locks() now runs earlier in boot
# (from S04, before this supervisor daemon even starts) and may have already
# removed the lock file for exactly this reason, to unblock S04/S05 on the
# same boot. If this function only looked for a lock file, a device the gate
# already cleared would have NO lock left for this loop to find, state.json
# would stay "validating" forever, and poll_once()'s own delta-detection
# would then treat that as "already in flight, skip" permanently - the exact
# same silent-forever-stuck failure this function exists to close, just
# moved to a different trigger. Keying off state.json instead makes this
# correct regardless of which one (this function, or the gate) runs first,
# or whether the lock file is present at all.
reconcile_stale_component_locks_on_boot() {
	[ -d "$NEBULAOS_ROOT/updates" ] || return 0
	for state_file_path in "$NEBULAOS_ROOT"/updates/*/state.json; do
		[ -e "$state_file_path" ] || continue
		name=$(basename "$(dirname "$state_file_path")")
		[ "$name" = "$STACK_NAME" ] && continue
		state=$(read_state_field "$name" state)
		[ "$state" = "validating" ] || continue
		log "$name: found an interrupted transaction from a previous supervisor process (state=validating) - nothing on disk has been validated, so it will be re-validated from scratch"
		known_good=$(read_state_field "$name" known_good_commit)
		write_state "$name" "$known_good" "$known_good" "interrupted" "supervisor_restarted_mid_transaction"
		rm -f "$LOCKDIR/$name.lock"
	done
}

poll_klipper_stack_once() {
	kdir="$NEBULAOS_ROOT/apps/$KLIPPER_APP"
	edir="$NEBULAOS_ROOT/apps/$EXTENSIONS_APP"
	[ -d "$kdir/.git" ] || return 0
	[ -d "$edir/.git" ] || return 0

	cur_k=$(stack_head "$KLIPPER_APP")
	cur_e=$(stack_head "$EXTENSIONS_APP")
	[ -n "$cur_k" ] && [ -n "$cur_e" ] || return 0

	seen_k=$(read_stack_field last_seen_klipper_commit)
	seen_e=$(read_stack_field last_seen_extensions_commit)

	# Phase 1.5 generation-scoped rollback: if state exists from a previous
	# image generation, its known_good pair belongs to that generation's
	# factory stack and must not override the new generation's own pair.
	# Discard the old state and re-bootstrap — the current running pair (just
	# proven at boot by S05/S99) becomes this generation's first known-good.
	gen=$(current_generation)
	if [ -n "$seen_k" ] && [ -n "$seen_e" ] && [ -n "$gen" ]; then
		state_gen=$(read_stack_field generation_id)
		if [ -n "$state_gen" ] && [ "$state_gen" != "$gen" ]; then
			log "$STACK_NAME: cross-generation state detected (state generation '$state_gen', current '$gen') - discarding old known-good pair and re-bootstrapping for the new image generation"
			write_stack_state "$cur_k" "$cur_e" "$cur_k" "$cur_e" "healthy" "cross_generation_rebootstrap:$state_gen"
			return 0
		fi
	fi

	if [ -z "$seen_k" ] || [ -z "$seen_e" ]; then
		# First observation this boot. Whatever is running now was already
		# proven at boot - S05nebulaos-activate composed and verified it and
		# S99confirm-good passed - so it becomes the known-good pair without
		# a validation cycle, exactly as the per-component bootstrap below
		# does.
		write_stack_state "$cur_k" "$cur_e" "$cur_k" "$cur_e" "healthy" ""
		log "$STACK_NAME: bootstrapped pair state at klipper $cur_k, extensions $cur_e"
		return 0
	fi

	state=$(read_stack_field state)
	# factory-fallback is a deliberate terminal state: a human must clear the
	# lock and re-run S05nebulaos-activate (or reboot) before the persistent
	# pair is trusted again. Never silently re-attempt a degraded config.
	if [ -e "$LOCKDIR/$STACK_NAME.lock" ] && [ "$state" = "factory-fallback" ]; then
		return 0
	fi
	[ "$state" = "validating" ] && return 0

	if [ "$cur_k" = "$seen_k" ] && [ "$cur_e" = "$seen_e" ]; then
		return 0
	fi

	# Scenario 3: let a burst of updates settle before validating, so a pair
	# that is still being written is not restarted into.
	log "$STACK_NAME: change detected (klipper $seen_k -> $cur_k, extensions $seen_e -> $cur_e) - waiting ${PAIR_SETTLE_SECONDS}s for the pair to settle"
	sleep "$PAIR_SETTLE_SECONDS"
	settled_k=$(stack_head "$KLIPPER_APP")
	settled_e=$(stack_head "$EXTENSIONS_APP")
	if [ "$settled_k" != "$cur_k" ] || [ "$settled_e" != "$cur_e" ]; then
		log "$STACK_NAME: the pair is still moving (a second update landed during the settle window) - deferring validation to the next poll cycle"
		return 0
	fi

	validate_klipper_stack
}

validate_component() {
	# $1=component. Runs after a HEAD change was already detected.
	name="$1"
	info=$(component_info "$name")
	path=$(echo "$info" | cut -d'|' -f1)
	new_commit=$(git -C "$path" rev-parse HEAD 2>/dev/null)
	known_good=$(read_state_field "$name" known_good_commit)

	mkdir -p "$LOCKDIR"
	: > "$LOCKDIR/$name.lock"
	write_state "$name" "$known_good" "$new_commit" "validating" ""

	log "$name: new commit detected ($new_commit) - validating"

	if ! "$HEALTHCHECK" stage1 "$name" "$path"; then
		log "$name: stage1 FAILED on new commit $new_commit - reverting to $known_good"
		preserve_failure_evidence "$name" "$new_commit" "stage1_failed"
		if [ "$name" = "moonraker" ] && ! moonraker_restore_env; then
			log "$name: no paired venv backup exists yet - going straight to factory-fallback rather than restore a mismatched pair"
			preserve_failure_evidence "$name" "$known_good" "no_env_backup_available"
			factory_fallback "$name"
			write_state "$name" "$known_good" "$known_good" "factory-fallback" "stage1_failed:$new_commit;no_env_backup_available"
			return
		fi
		git -C "$path" reset --hard "$known_good" >/dev/null 2>&1
		restart_component "$name"
		if stabilized_stage2; then
			log "$name: reverted version re-validated healthy"
			write_state "$name" "$known_good" "$known_good" "rolled-back" "stage1_failed:$new_commit"
			rm -f "$LOCKDIR/$name.lock"
		else
			preserve_failure_evidence "$name" "$known_good" "stage2_failed_after_stage1_rollback"
			factory_fallback "$name"
			# last_seen_commit must reflect the persistent repo's ACTUAL
			# current HEAD (known_good, since it was reset above), not
			# new_commit - real bug found live: recording new_commit here
			# left state.json out of sync with git's real state, so the
			# very next poll saw current(known_good) != last_seen(new_commit)
			# and mistook the already-failed-over state for a fresh update,
			# re-triggering validation and eventually overwriting this
			# factory-fallback state with a false "healthy" while /opt/klipper
			# was still the unmounted immutable copy, not the persistent one.
			write_state "$name" "$known_good" "$known_good" "factory-fallback" "stage1_failed:$new_commit;previous_also_unhealthy"
		fi
		return
	fi

	if stabilized_stage2; then
		log "$name: new commit $new_commit passed full validation - recording as known-good"
		write_state "$name" "$new_commit" "$new_commit" "healthy" ""
		# Snapshot the venv as the new paired backup ONLY after the source
		# at this exact commit has already been proven healthy together
		# with whatever is currently on disk in the venv - this is what
		# makes the pairing atomic: both halves are always captured (and
		# later restored) as a single unit, so there is no code path that
		# can record source commit A paired with a venv snapshot that
		# actually belongs to a different commit.
		[ "$name" = "moonraker" ] && moonraker_snapshot_env
		rm -f "$LOCKDIR/$name.lock"
		return
	fi

	log "$name: stage2 FAILED on new commit $new_commit - reverting to $known_good"
	preserve_failure_evidence "$name" "$new_commit" "stage2_failed"
	if [ "$name" = "moonraker" ] && ! moonraker_restore_env; then
		log "$name: no paired venv backup exists yet - going straight to factory-fallback rather than restore a mismatched pair"
		preserve_failure_evidence "$name" "$known_good" "no_env_backup_available"
		factory_fallback "$name"
		write_state "$name" "$known_good" "$known_good" "factory-fallback" "stage2_failed:$new_commit;no_env_backup_available"
		return
	fi
	git -C "$path" reset --hard "$known_good" >/dev/null 2>&1
	restart_component "$name"
	if stabilized_stage2; then
		log "$name: reverted version re-validated healthy"
		write_state "$name" "$known_good" "$known_good" "rolled-back" "stage2_failed:$new_commit"
		rm -f "$LOCKDIR/$name.lock"
	else
		preserve_failure_evidence "$name" "$known_good" "stage2_failed_after_stage2_rollback"
		factory_fallback "$name"
		write_state "$name" "$known_good" "$known_good" "factory-fallback" "stage2_failed:$new_commit;previous_also_unhealthy"
	fi
}

# Real bug found live 2026-07-28: Moonraker's own machine.py
# restart_moonraker_service() is how Moonraker "restarts itself" for its
# own reserved update_manager slot (used by both a real self-update and
# Recover) - it calls do_service_action("restart", "moonraker") and
# swallows any exception (`except Exception: pass`, confirmed directly
# against vendor/moonraker's own source). moonraker.conf's [machine]
# section sets `provider: supervisord_cli`, but this Buildroot image has
# no supervisord daemon at all (no binary running, no config, nothing in
# any init.d script) - BusyBox init + this project's own S## scripts are
# used instead. `supervisorctl restart moonraker` therefore always fails,
# silently, and moonraker stays dead. The git-HEAD-delta detection below
# is this supervisor's only other restart trigger, and a Recover that
# fixes a dirty tree without moving HEAD (an entirely normal case) never
# produces a delta - live-reproduced exactly this way: Moonraker stayed
# dead for the rest of the boot with nothing left to notice. This is an
# independent liveness check with no git dependency at all, specifically
# to close that gap.
ensure_moonraker_alive() {
	# MEM-T16: memguard is restarting Moonraker itself (P4); do not race it.
	[ -e "$NEBULAOS_RUN_DIR/shed/moonraker-restarting" ] && return 0
	if [ -e "$LOCKDIR/moonraker.lock" ]; then
		# A validation/rollback for moonraker is already in flight and will
		# handle its own restart - restarting it out from under that logic
		# here would race with it.
		return 0
	fi
	info=$(component_info moonraker)
	pidfile=$(echo "$info" | cut -d'|' -f4)
	if [ -f "$pidfile" ] && [ -d "/proc/$(cat "$pidfile" 2>/dev/null)" ] 2>/dev/null; then
		return 0
	fi
	log "moonraker: process not running (pidfile stale or missing) - restarting independent of any git change"
	wait_for_print_idle || return 0
	init_script=$(echo "$info" | cut -d'|' -f2)
	"$init_script" start
}

poll_once() {
	ensure_moonraker_alive

	# Klipper is deliberately NOT in the per-component loop below any more.
	# It is validated as half of the (klipper, extensions) pair, and running
	# both paths would mean two transactions racing for the same service.
	poll_klipper_stack_once

	for name in moonraker; do
		info=$(component_info "$name")
		path=$(echo "$info" | cut -d'|' -f1)
		[ -d "$path/.git" ] || continue

		current=$(git -C "$path" rev-parse HEAD 2>/dev/null)
		[ -z "$current" ] && continue

		last_seen=$(read_state_field "$name" last_seen_commit)

		# Phase 1.5 generation-scoped rollback (per-component).
		gen=$(current_generation)
		if [ -n "$last_seen" ] && [ -n "$gen" ]; then
			state_gen=$(read_state_field "$name" generation_id)
			if [ -n "$state_gen" ] && [ "$state_gen" != "$gen" ]; then
				log "$name: cross-generation state detected (state generation '$state_gen', current '$gen') - discarding old known-good and re-bootstrapping"
				write_state "$name" "$current" "$current" "healthy" "cross_generation_rebootstrap:$state_gen"
				[ "$name" = "moonraker" ] && moonraker_snapshot_env
				continue
			fi
		fi

		if [ -z "$last_seen" ]; then
			# First observation this boot - bootstrap state without
			# triggering validation. Whatever is running now was already
			# proven at boot by S99confirm-good/the existing readiness
			# checks; there is no legitimate "known good" reference to
			# compare against yet other than this.
			write_state "$name" "$current" "$current" "healthy" ""
			[ "$name" = "moonraker" ] && moonraker_snapshot_env
			log "$name: bootstrapped state at $current"
			continue
		fi

		state=$(read_state_field "$name" state)
		# factory-fallback is a deliberate terminal state (design doc sec
		# 3.1 step 5: "never silently succeed on a degraded configuration")
		# - belt-and-suspenders against ever re-triggering validation here
		# even if state.json's commit bookkeeping were ever wrong again:
		# a human must clear $LOCKDIR/$name.lock (and re-run
		# S05nebulaos-activate or reboot) to re-enable the persistent copy.
		if [ -e "$LOCKDIR/$name.lock" ] && [ "$state" = "factory-fallback" ]; then
			continue
		fi

		# Real gap found live (2026-07-27): on a device whose moonraker
		# state.json already existed from before this paired-venv backup
		# mechanism shipped, last_seen_commit was never empty, so the
		# bootstrap branch above (which is the only other place
		# moonraker_snapshot_env() is called outside a successful
		# validation) never ran even once - leaving the paired backup
		# permanently missing until the next real commit change. Self-heal
		# opportunistically: if healthy with no pending change, take the
		# snapshot now rather than waiting indefinitely for one.
		if [ "$name" = "moonraker" ] && [ "$state" = "healthy" ] && [ ! -d "$MOONRAKER_ENV_BACKUP" ]; then
			log "$name: no paired venv backup yet on an already-healthy install - snapshotting now"
			moonraker_snapshot_env
		fi

		if [ "$current" != "$last_seen" ] && [ "$state" != "validating" ]; then
			validate_component "$name"
		fi
	done

	poll_mainsail_once
}

loop() {
	log "starting (poll interval ${POLL_INTERVAL}s)"
	cleanup_stale_staging
	reconcile_stale_component_locks_on_boot
	reconcile_klipper_stack_on_boot
	while true; do
		poll_once
		sleep "$POLL_INTERVAL"
	done
}

# NEBULAOS_UPDATE_SUPERVISOR_NO_AUTORUN=1 lets the offline scenario tests
# source this file to call validate_klipper_stack()/poll_klipper_stack_once()
# directly - the same seam convention as S04's own NO_AUTORUN variables.
if [ -z "${NEBULAOS_UPDATE_SUPERVISOR_NO_AUTORUN:-}" ]; then
	case "$1" in
		loop)
			loop
			;;
		poll-once)
			poll_once
			;;
		*)
			echo "usage: $0 loop|poll-once" >&2
			exit 2
			;;
	esac
fi
