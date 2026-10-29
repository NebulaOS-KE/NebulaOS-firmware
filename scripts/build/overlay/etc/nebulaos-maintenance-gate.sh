#!/bin/sh
#
# Shared maintenance-safety gate for S04nebulaos-factory-seed and
# S04nebulaos-migrate - both perform the exact same memory/IO-heavy work
# that must never run while a print is active, concurrently with a real
# update, or without memory-resilience swap active, and previously
# duplicated the identical gate logic independently in each script.
#
# Final Baseline Closure mission (2026-08-08): extracted into one shared
# file specifically because a real bug was found live in the duplicated
# logic - fixing it once here, rather than needing the identical fix
# applied twice (and risking the two copies drifting apart, exactly the
# failure class this project's own conventions exist to avoid - see
# scripts/build/lib/make-seed-archive.sh's own header for the same
# reasoning applied to a build-time shared function).
#
# Real bug found live during the Virgin Flash + Verification mission
# (2026-08-08): a stale update-transaction lock file, left over from
# BEFORE a persistent-state reset (an off-device backup + reset to
# simulate a virgin install), silently blocked every subsequent boot's
# factory-seed/migrate forever - neither script, nor anything else, ever
# cleared a stale lock, so the block was permanent until someone noticed
# and deleted it by hand.
#
# Fix is deliberately narrow. On a genuinely UNSEEDED namespace
# ($APPS/klipper/.git absent - i.e. seed_git_app has never once
# completed here), an update-transaction lock is PROVABLY irrelevant:
# this project's real update mechanism (/etc/nebulaos-update-
# supervisor.sh) only ever creates a lock while updating an app that has
# ALREADY been seeded - if the app has never been seeded at all, no real
# update could ever have legitimately created this lock, so it can only
# be leftover debris and is safe to clear automatically. On an
# ALREADY-seeded namespace, a lock is left exactly as blocking as
# before - that case can genuinely mean a real, recent, failed update
# that nebulaos-update-supervisor.sh's own comments document as
# deliberately needing human review before retrying ("a human must clear
# $LOCKDIR/$name.lock") - this fix must never bypass that case, and does
# not.
#
# Callers must already have their own log() function defined and their
# own $APPS/$LOCKDIR variables set before sourcing this file - this gate
# calls log() and reads those variables directly rather than taking them
# as parameters, so every existing log line keeps its own script's
# established "S04nebulaos-factory-seed: ..." / "S04nebulaos-migrate: ..."
# prefix unchanged.
#
# Phase 1.5 hardware closure (2026-08-19): a lock left behind by a
# supervisor process that died mid-validate_component()/mid-
# validate_klipper_stack() - state.json still says "validating", nothing on
# disk it was validating has ever been proven - blocked BOTH this gate
# (every boot, forever, via the ALREADY-seeded branch below) AND S05nebulaos-
# activate's own validate_app() lock check. nebulaos-update-supervisor.sh
# already has its own boot-time reconcile for exactly this
# (reconcile_klipper_stack_on_boot/reconcile_stale_component_locks_on_boot),
# but that is a separate, LATER-started daemon - this gate runs from S04,
# early in boot, and cannot wait for it. Clearing a lock whose own
# state.json says "validating" here, before the blocking check below ever
# runs, is what actually unblocks S04/S05 on the SAME boot the interruption
# is discovered, rather than only on the boot after next.
#
# Clears locks whose sibling state.json is in a TERMINAL state — one where
# no active update process is running and the supervisor itself cannot
# recover without a new boot-time pass. Only the LOCK FILE is removed;
# state.json is left for the supervisor to reconcile on its own later pass.
#
# Terminal states cleared:
#   "validating"      — supervisor died mid-validate (Phase 1.5 closure bug)
#   "interrupted"     — supervisor restarted mid-transaction
#   "factory-fallback" — supervisor explicitly gave up (restore failed)
#
# Phase 1.8 hardware qualification (2026-08-23): factory-fallback and
# interrupted locks blocked image migration on EVERY boot of candidate-001
# AND candidate-002. The gate's original design preserved factory-fallback
# for "human must clear" semantics, but this created a permanent deadlock
# for image migrations — S04 runs before services, so no supervisor or
# human intervention can occur before the gate check. An image migration
# replaces the entire checkout, making any stale update state irrelevant.
# A malformed/missing/unreadable state file, or a state not in the terminal
# list, still leaves the lock exactly as blocking as before.
_maintenance_gate_reconcile_stale_locks() {
	[ -d "$LOCKDIR" ] || return 0
	updates_root=$(dirname "$LOCKDIR")
	for lockfile in "$LOCKDIR"/*.lock; do
		[ -e "$lockfile" ] || continue
		name=$(basename "$lockfile" .lock)
		state_file="$updates_root/$name/state.json"
		[ -f "$state_file" ] || continue
		state=$(grep -o '"state"[[:space:]]*:[[:space:]]*"[^"]*"' "$state_file" 2>/dev/null | \
			sed -E 's/.*"([^"]*)"$/\1/' | head -1)
		case "$state" in
			validating|interrupted|factory-fallback)
				log "found a stale update lock ($name, state=$state) from a previous boot — clearing so migration/activation are not permanently blocked; nebulaos-update-supervisor.sh will reconcile $name's state.json on its own next pass"
				rm -f "$lockfile"
				;;
		esac
	done
}

maintenance_gate_ok() {
	_maintenance_gate_reconcile_stale_locks

	active=$(wget -q -O - --timeout=3 'http://127.0.0.1:7125/printer/objects/query?print_stats' 2>/dev/null)
	case "$active" in
		*'"state":"printing"'*|*'"state":"paused"'*)
			log "BLOCKED: a print is active - refusing this boot (will retry next boot)"
			return 1
			;;
	esac

	if [ -d "$LOCKDIR" ] && [ -n "$(ls -A "$LOCKDIR" 2>/dev/null)" ]; then
		if [ ! -e "$APPS/klipper/.git" ]; then
			log "found an update-transaction lock, but $APPS/klipper has never been seeded (no .git present) - no real update could ever have legitimately created this lock for an app that has never existed here. Clearing it as leftover debris, not a real in-flight or failed update."
			rm -rf "$LOCKDIR"
			mkdir -p "$LOCKDIR"
		else
			log "BLOCKED: an update transaction lock is present - refusing to run concurrently with an update"
			return 1
		fi
	fi

	if ! grep -qE '^(/dev/zram0|.*/system/swapfile) ' "${NEBULAOS_PROC_SWAPS:-/proc/swaps}" 2>/dev/null; then
		log "BLOCKED: no memory-resilience swap active (neither zram nor the NebulaOS disk swap file) - refusing to proceed"
		return 1
	fi

	return 0
}
