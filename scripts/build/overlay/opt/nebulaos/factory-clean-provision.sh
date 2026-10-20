#!/bin/sh
#
# NebulaOS Clean-Update + Virgin Baseline mission, Phase 4 (2026-08-08):
# on-demand factory-clean provisioning. Archives (never destroys)
# NebulaOS-owned persistent state, then leaves the namespace exactly as a
# genuinely new device's would be - S04nebulaos-factory-seed re-seeds
# everything fresh from THIS image's own archives on the very next boot.
#
# Deliberately lives under /opt (squashfs-resident, immutable) rather than
# under $NEBULAOS_ROOT itself - it must remain available and correct even
# if the persistent application tree it operates on is damaged or absent.
#
# Scope, using the classification in docs/NEBULAOS_PERSISTENT_LIFECYCLE.md:
#   ARCHIVED + RESET : apps/{klipper,moonraker,mainsail,guppyscreen}
#                       (IMAGE OWNED), envs/{klipper,moonraker} (GENERATED,
#                       cheaper to reseed than to hand-classify), system/*
#                       (NebulaOS's own generation/known-good/activation
#                       metadata - itself neither user data nor printer
#                       output)
#   NEVER TOUCHED     : printer_data/config (USER OWNED - printer.cfg,
#                       macros, moonraker.conf), printer_data/{gcodes,logs,
#                       database} (GENERATED, but the user's own print
#                       history/output, not this mission's concern),
#                       updates/backups/maintenance directories, and every
#                       stock partition (mmcblk0p5/p7) - this script never
#                       issues a single write to /dev/mmcblk0* of any kind,
#                       structurally, by only ever operating on paths under
#                       $NEBULAOS_ROOT.
#
# Usage:
#   factory-clean-provision.sh --archive-and-reset
#
# Without that exact flag, prints this usage and does nothing - there is
# no accidental/implicit destructive path.

NEBULAOS_ROOT="${NEBULAOS_ROOT:-/usr/data/nebulaos}"
APPS="$NEBULAOS_ROOT/apps"
ENVS="$NEBULAOS_ROOT/envs"
SYSTEM="$NEBULAOS_ROOT/system"
LOCKDIR="$NEBULAOS_ROOT/updates/locks"
BACKUP_ROOT="$NEBULAOS_ROOT/factory-clean-backups"
# Overridable for tests/factory-clean-provision-tests.sh, same convention
# as SEEDS/APPS/SYSTEM elsewhere in this project - real boot never sets
# this, so ":=" always resolves to the real init-script path.
NAMESPACE_SCRIPT="${NAMESPACE_SCRIPT:-/etc/init.d/S02nebulaos-namespace}"

log() {
	echo "factory-clean-provision: $1"
}

usage() {
	cat <<'EOF'
factory-clean-provision.sh --archive-and-reset

Archives (does not delete) the current apps/, envs/, and system/ trees
under /usr/data/nebulaos to a timestamped backup directory, then recreates
an empty namespace so the next boot re-seeds everything fresh from this
image's own archives - exactly as a genuinely new device would.

printer_data/config (your printer.cfg, macros, moonraker.conf) and
printer_data/{gcodes,logs,database} are never touched. No stock partition
is ever written by this script.

Refuses to run while a print is active or an update transaction is in
flight. Requires a reboot afterward to actually take effect.
EOF
}

maintenance_gate_ok() {
	active=$(wget -q -O - --timeout=3 'http://127.0.0.1:7125/printer/objects/query?print_stats' 2>/dev/null)
	case "$active" in
		*'"state":"printing"'*|*'"state":"paused"'*)
			log "REFUSED: a print is active - this cannot run while the printer is in use"
			return 1
			;;
	esac
	if [ -d "$LOCKDIR" ] && [ -n "$(ls -A "$LOCKDIR" 2>/dev/null)" ]; then
		log "REFUSED: an update transaction lock is present - cannot run concurrently with an update"
		return 1
	fi
	return 0
}

stop_services() {
	log "stopping services that hold the application tree open"
	/etc/init.d/S58nebulascreen stop 2>/dev/null
	/etc/init.d/S50webcam stop 2>/dev/null
	/etc/init.d/S56moonraker stop 2>/dev/null
	/etc/init.d/S55klipper stop 2>/dev/null
}

archive_and_reset() {
	stamp=$(date -u +%Y%m%dT%H%M%SZ)
	backup_dir="$BACKUP_ROOT/$stamp"
	mkdir -p "$backup_dir"
	log "archiving current NebulaOS-owned state to $backup_dir"

	for tree in apps envs system; do
		src="$NEBULAOS_ROOT/$tree"
		if [ -e "$src" ]; then
			mv "$src" "$backup_dir/$tree"
			log "moved $src -> $backup_dir/$tree"
		else
			log "$src did not exist - nothing to archive for $tree"
		fi
	done

	sync

	if [ ! -x "$NAMESPACE_SCRIPT" ]; then
		log "ERROR: $NAMESPACE_SCRIPT not found or not executable - cannot recreate an empty namespace. Your previous state is safe at $backup_dir, but apps/envs/system are now MISSING until this is corrected by hand."
		return 1
	fi
	log "recreating empty namespace layout (printer_data/config and your gcodes/logs/database are untouched by this step)"
	"$NAMESPACE_SCRIPT" start

	if [ ! -d "$APPS" ] || [ ! -d "$ENVS" ] || [ ! -d "$SYSTEM" ]; then
		log "ERROR: namespace recreation looks incomplete - check $NAMESPACE_SCRIPT output above. Your previous state is still fully intact at $backup_dir."
		return 1
	fi

	log "done. Previous state fully preserved at $backup_dir (not deleted - remove by hand once you've confirmed the fresh install is good)."
	log "REBOOT NOW to actually provision fresh: S04nebulaos-factory-seed will re-seed klipper/moonraker/mainsail from this image's own archives, S04nebulaos-migrate will record the new baseline generation, and services will start clean."
}

case "${1:-}" in
	--archive-and-reset)
		maintenance_gate_ok || exit 1
		stop_services
		archive_and_reset
		;;
	*)
		usage
		exit 1
		;;
esac
