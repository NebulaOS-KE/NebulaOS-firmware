#!/bin/sh
#
# NebulaOS mutable-runtime mission, Phase 9: namespace-restricted,
# update-aware retention manager. Informed by SimpleAF's real, currently-
# shipping tools/cleanup-files.sh (pellcorp/creality, fetched 2026-07-26 -
# full findings in docs/NEBULAOS_RETENTION_POLICY.md sec 1) but NOT a
# literal port: normal cleanup here is restricted to an explicit allowlist
# under /usr/data/nebulaos, adds a real active-print/partial-upload check
# before any emergency gcode deletion (a real gap in SimpleAF's own
# reference script - it has no such check at all), and never touches USB
# mounts.
#
# Invoked by /etc/init.d/S45nebulaos-cleanup at boot (backgrounded, does
# not block boot - matches SimpleAF's own S45cleanup convention). Can also
# be invoked manually with --dry-run to preview without deleting anything.

# Overridable for tests, same convention as S04nebulaos-migrate/flash-
# spare-slot.sh (Phase 2 final software closure mission, 2026-09-09 -
# needed the first time this script grew a real offline test suite).
NEBULAOS_ROOT="${NEBULAOS_ROOT:-/usr/data/nebulaos}"
LOG="${LOG:-$NEBULAOS_ROOT/maintenance/retention.log}"
LOCKDIR="${LOCKDIR:-$NEBULAOS_ROOT/updates/locks}"
SHARED_GCODES="${SHARED_GCODES:-/usr/data/printer_data/gcodes}"

# Free-space floors on /usr/data, in MB - adapted from SimpleAF's single
# 1000MB threshold (docs/NEBULAOS_RETENTION_POLICY.md sec 1/2.3), split
# into two levels since this mission's own added footprint (~150-250MB per
# the architecture doc's measured storage budget) is smaller than what
# SimpleAF's own reference script was originally sized for.
CAUTION_FLOOR_MB=800
CRITICAL_FLOOR_MB=300

# Phase 0 safety/logging cleanup: klippy.log/moonraker.log/guppyscreen.log
# and (as of this same pass) the persistent nginx-access.log/nginx-error.log
# grow unbounded - clean_rotated_logs() below only ever age-sweeps files
# that are ALREADY rotated, and nothing anywhere ever produced a rotated
# copy of these five live logs in the first place. 5MB keeps each log's
# worst case (live + 2 rotated generations = 15MB/log, 75MB across all
# five) comfortably inside the ~150-250MB budget this script's own
# CAUTION/CRITICAL floors above were sized against.
LOG_ROTATE_MAX_BYTES=$((5 * 1024 * 1024))
# G66 (2026-10-16): uploaded system images (~130 MB each). An installed one is
# deleted by the image trial once its system is confirmed; any other goes
# after SYSTEM_IMAGE_MAX_DAYS. Not while an image job is running.
SYSTEM_IMAGE_DIR="${SYSTEM_IMAGE_DIR:-$NEBULAOS_ROOT/printer_data/config/uploads/system-image}"
SYSTEM_IMAGE_MAX_DAYS=30
IMAGE_JOB_STATE="${IMAGE_JOB_STATE:-/run/nebulaos/image-update/state.json}"
# G66: one run at a time - S45 at boot and the housekeeping loop every 30
# minutes. A lock older than an hour is from a run that died.
RETENTION_LOCK="${RETENTION_LOCK:-$NEBULAOS_ROOT/maintenance/retention.lock}"
MOONRAKER_PRINT_STATS="${MOONRAKER_PRINT_STATS:-http://127.0.0.1:7125/printer/objects/query?print_stats}"

dryrun=false
[ "$1" = "--dry-run" ] && dryrun=true

log() {
	echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1" >> "$LOG"
}

delete() {
	f="$1"; reason="$2"
	if [ "$dryrun" = "true" ]; then
		log "[DRY-RUN] would delete ($reason): $f"
		return 0
	fi
	# Real bug found live (Phase E, 2026-07-27): BusyBox's `rm -f` refuses
	# to remove a directory at all ("rm: 'x' is a directory", exit 1) -
	# every call this function ever made against the directory-based
	# per-component backups (klipper/moonraker/mainsail are all real
	# directories, not flat files) has silently done nothing while this
	# same function logged "deleting" as if it had succeeded. Only the
	# flat-file cases (rotated logs, config backups) were ever genuinely
	# removed. Confirmed live: a manual `rm -f` against a real populated
	# directory left it completely intact.
	if [ -d "$f" ]; then
		rm -rf "$f"
	else
		rm -f "$f"
	fi
	if [ -e "$f" ]; then
		log "FAILED to delete ($reason): $f (still present after rm)"
	else
		log "deleting ($reason): $f"
	fi
}

# Same rationale as SimpleAF's own script (docs/NEBULAOS_RETENTION_POLICY.md
# sec 1/2.6): this board has no RTC, so time reads as an early-2020-ish
# epoch until NTP finishes syncing after boot. Any mtime-based decision
# below is wrong until the clock has visibly jumped forward.
wait_for_clock_sync() {
	start=$(date +%s)
	# 2026-07-23 00:00:00 UTC - this project's own earliest possible boot,
	# used the same way SimpleAF's script uses its own fixed reference date.
	if [ "$start" -lt 1784851200 ]; then
		log "clock not yet synced (epoch $start) - waiting for NTP jump"
		i=0
		while [ "$i" -lt 60 ]; do
			now=$(date +%s)
			[ "$((now - start))" -gt 1200 ] && break
			sleep 5
			i=$((i + 1))
		done
	fi
}

# Rejects '..' traversal and any path that resolves (following symlinks)
# outside $NEBULAOS_ROOT. Never deletes anything under a target this
# rejects.
path_is_namespace_safe() {
	case "$1" in
		*..*) return 1 ;;
	esac
	resolved=$(readlink -f "$1" 2>/dev/null) || return 1
	case "$resolved" in
		"$NEBULAOS_ROOT"/*) return 0 ;;
		*) return 1 ;;
	esac
}

# True if an update transaction lock exists for any component - normal
# cleanup should not race an in-flight update's own file operations.
update_in_progress() {
	[ -d "$LOCKDIR" ] || return 1
	[ -n "$(ls -A "$LOCKDIR" 2>/dev/null)" ]
}

# --- Normal, namespace-restricted cleanup ---

# Only rotated copies (name.log.N, name.log.YYYY-...), never a live *.log.
# G45 (2026-10-15): the old pattern "*.log*" also matched live logs not on the
# skip list - system.log, boot-timing.log. Everything written before NTP has a
# 2020 mtime, so right after the clock jump the whole system.log (this boot's
# Wi-Fi/DHCP/data-partition lines and every earlier boot) was "older than 7
# days" and deleted; syslogd then created a fresh one. system.log.0/.1 are
# left to syslogd itself (-b 2), which bounds them without trusting mtimes.
clean_rotated_logs() {
	find "$NEBULAOS_ROOT/printer_data/logs" "$NEBULAOS_ROOT/maintenance/logs" \
		-maxdepth 1 -type f -name "*.log.*" -mtime +7 2>/dev/null | while read -r f; do
		base=$(basename "$f")
		case "$base" in
			system.log.*) continue ;;
		esac
		path_is_namespace_safe "$f" && delete "$f" "rotated-log"
	done
}

# rotate_if_oversized FILE MAX_BYTES
#
# Copy-truncate, not rename-and-recreate: klippy/moonraker/guppyscreen/nginx
# all hold their log file open for the life of the process and never reopen
# it on SIGHUP - renaming $f out from under them would leave their fd
# writing into an ever-growing, now-unreachable-by-name copy forever, with
# a freshly-created $f staying empty until the next restart, which defeats
# the point of rotating at all. Truncating the SAME inode in place keeps
# the running process's fd valid; its next write lands right after the
# truncation point. The standard copy-truncate tradeoff applies (a few
# lines written between the cp and the truncate below can be lost) - that
# is accepted here in exchange for never needing to signal or restart a
# live service just to rotate its log.
#
# Safe if $f doesn't exist yet (first boot, e.g. before a service has ever
# started) and safe under low disk space - if the copy fails, rotation is
# skipped entirely for this run and the live file is left untouched, never
# truncated without a backup existing first.
rotate_if_oversized() {
	f="$1"
	max_bytes="$2"

	[ -e "$f" ] || return 0
	path_is_namespace_safe "$f" || return 0

	size=$(wc -c < "$f" 2>/dev/null)
	[ -z "$size" ] && return 0
	[ "$size" -le "$max_bytes" ] && return 0

	# Keep exactly 2 rotated generations - same bound this script already
	# uses for failed-* backup retention (clean_obsolete_versions).
	[ -e "$f.2" ] && rm -f "$f.2" 2>/dev/null
	[ -e "$f.1" ] && mv -f "$f.1" "$f.2" 2>/dev/null

	if cp -a "$f" "$f.1" 2>/dev/null; then
		if : > "$f" 2>/dev/null; then
			log "rotated (oversized, ${size}B): $f -> $f.1"
		else
			log "WARNING: rotate of $f: truncate failed after copy (possible low disk space) - $f.1 is a safe copy, live file left untouched"
		fi
	else
		log "WARNING: rotate of $f: copy to $f.1 failed (possible low disk space) - skipping rotation this run, live file untouched"
	fi
}

rotate_platform_logs() {
	rotate_if_oversized "$NEBULAOS_ROOT/printer_data/logs/klippy.log" "$LOG_ROTATE_MAX_BYTES"
	rotate_if_oversized "$NEBULAOS_ROOT/printer_data/logs/moonraker.log" "$LOG_ROTATE_MAX_BYTES"
	rotate_if_oversized "$NEBULAOS_ROOT/printer_data/logs/guppyscreen.log" "$LOG_ROTATE_MAX_BYTES"
	rotate_if_oversized "$NEBULAOS_ROOT/printer_data/logs/nginx-access.log" "$LOG_ROTATE_MAX_BYTES"
	rotate_if_oversized "$NEBULAOS_ROOT/printer_data/logs/nginx-error.log" "$LOG_ROTATE_MAX_BYTES"
}

# G60 (2026-10-16): NebulaOS's own small append-only logs - this script's own
# retention.log, the seed logs in maintenance/logs and the data-partition
# diagnostics - were never bounded. Past SMALL_LOG_MAX they keep their last
# SMALL_LOG_LINES lines (the same way rcS bounds boot-timing.log).
SMALL_LOG_MAX=$((512 * 1024))
SMALL_LOG_LINES=2000

trim_small_logs() {
	for f in "$LOG" "$NEBULAOS_ROOT"/maintenance/logs/*.log "$NEBULAOS_ROOT"/system/diagnostics/*.log; do
		[ -f "$f" ] || continue
		path_is_namespace_safe "$f" || continue
		size=$(wc -c < "$f" 2>/dev/null)
		[ -n "$size" ] && [ "$size" -gt "$SMALL_LOG_MAX" ] || continue
		if [ "$dryrun" = "true" ]; then
			log "[DRY-RUN] would trim (${size}B): $f"
			continue
		fi
		tail -n "$SMALL_LOG_LINES" "$f" > "$f.trim" 2>/dev/null && mv -f "$f.trim" "$f" \
			&& log "trimmed to the last $SMALL_LOG_LINES lines (${size}B): $f"
		rm -f "$f.trim" 2>/dev/null
	done
}

clean_old_config_backups() {
	find "$NEBULAOS_ROOT/backups/printer_config" -maxdepth 1 -type f -mtime +7 2>/dev/null | \
		sort -r | tail -n +2 | while read -r f; do
		path_is_namespace_safe "$f" && delete "$f" "old-config-backup"
	done
}

# prune_backup_dir DIR KEEP REASON
#
# Same policy as clean_old_config_backups()/clean_obsolete_versions() above,
# factored out so migration-backups' several distinct backup shapes (see
# clean_migration_backups() below) can all share it: entries older than 7
# days are candidates, newest-first; the newest KEEP of those candidates
# are still protected, so there is always at least KEEP real backups to
# fall back to regardless of age. Never touches anything within the last 7
# days at all, no matter how many entries exist.
prune_backup_dir() {
	dir="$1"; keep="$2"; reason="$3"
	[ -d "$dir" ] || return 0
	find "$dir" -mindepth 1 -maxdepth 1 -mtime +7 2>/dev/null | sort -r | tail -n "+$((keep + 1))" | \
		while read -r f; do
			path_is_namespace_safe "$f" && delete "$f" "$reason"
		done
}

# Phase 2 final software closure mission, 2026-09-09: migration-backups had
# no pruning at all - a real device accumulated ~1.6GB there (95% of a
# 5.9GB /usr/data partition, 260MB free), almost entirely from
# reseed_git_app()'s own per-boot BACKUP_DIR="$BACKUP_ROOT/<timestamp>"
# full klipper+moonraker+nebulaos-klipper-extensions checkout backups
# (S04nebulaos-migrate) - up to several hundred MB each, one per migration
# run, forever. Extends this existing script rather than adding a second
# mechanism, per this project's own standing "one cleanup path" rule.
#
# Three distinct shapes under migration-backups/, all handled the same way
# (age +7 days, keep newest 2 - same KEEP as clean_obsolete_versions()'s
# failed-* retention above, for consistency):
#   1. Timestamp-named directories (BACKUP_ROOT/<ISO8601>/) - each one IS a
#      single backup event covering whichever of klipper/moonraker/
#      extensions were reseeded that run; pruned as one atomic unit by its
#      own name.
#   2. Named-category subdirectories (printer-cfg-migration/,
#      printer-cfg-migration-refused/, moonraker-conf-migration/,
#      moonraker-conf-migration-refused/, and any future migration adds) -
#      each one holds individual timestamped backup FILES; pruned
#      per-file, per-category, independently.
#   3. Loose files sitting directly at migration-backups/ root (e.g.
#      migrate_config_ownership()'s own printer.cfg.pre-config-ownership-
#      migration.<ts> - an existing minor inconsistency in where that one
#      migration writes its backup, not something this pass changes) -
#      pruned individually, as their own single-file "category".
#
# Never touches active config, printer.cfg, current SAVE_CONFIG, PLR
# state, MCU state, user macros, or anything else outside
# $NEBULAOS_ROOT/system/migration-backups itself - this function's only
# input is that one directory tree.
MIGRATION_BACKUP_KEEP=2

clean_migration_backups() {
	root="$NEBULAOS_ROOT/system/migration-backups"
	[ -d "$root" ] || return 0

	find "$root" -mindepth 1 -maxdepth 1 2>/dev/null | while read -r entry; do
		base=$(basename "$entry")
		if [ -d "$entry" ]; then
			case "$base" in
				[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z)
					# Shape 1: the directory itself is one timestamped
					# backup event - handled by the per-entry mtime+count
					# pass over $root below, not here (a per-directory
					# recursive prune here would instead delete individual
					# component subdirectories out of a single backup
					# event, which is never what we want - klipper/
					# moonraker/extensions from the SAME event must be
					# pruned or kept together).
					;;
				*)
					# Shape 2: a named category - prune its own files
					# independently.
					prune_backup_dir "$entry" "$MIGRATION_BACKUP_KEEP" "old-migration-backup-$base"
					;;
			esac
		fi
	done

	# Shape 1 (timestamp directories) and shape 3 (loose root files) are
	# both direct children of $root with no further category grouping -
	# prune them together as one pool, newest N protected regardless of
	# whether that "newest" happens to be a directory or a loose file.
	# Named-category subdirectories (shape 2) are excluded here because
	# they were already handled, per-category, above - counting them
	# against the shape-1/3 pool would let an old, low-value loose file
	# use up a "keep" slot that should protect a real per-boot backup, or
	# vice versa.
	tmp_list=$(mktemp "${TMPDIR:-/tmp}/migration-backup-prune.XXXXXX" 2>/dev/null) || return 0
	find "$root" -mindepth 1 -maxdepth 1 -mtime +7 2>/dev/null | while read -r entry; do
		base=$(basename "$entry")
		case "$base" in
			[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) echo "$entry" ;;
			printer-cfg-migration|printer-cfg-migration-refused|moonraker-conf-migration|moonraker-conf-migration-refused) ;;
			*) [ -f "$entry" ] && echo "$entry" ;;
		esac
	done | sort -r > "$tmp_list"
	tail -n "+$((MIGRATION_BACKUP_KEEP + 1))" "$tmp_list" | while read -r f; do
		path_is_namespace_safe "$f" && delete "$f" "old-migration-backup"
	done
	rm -f "$tmp_list"
}

# A separate top-level directory from migration-backups/ (see
# mainsail_backup_namespace() in nebulaos-recover) - kept as its own
# function, not folded into clean_migration_backups() above, specifically
# so it is never accidentally gated behind migration-backups/ existing;
# the two are independent and either can exist without the other.
clean_mainsail_namespace_backups() {
	prune_backup_dir "$NEBULAOS_ROOT/system/mainsail-namespace-backups" "$MIGRATION_BACKUP_KEEP" "old-mainsail-namespace-backup"
}

# Historical stray backup files this project's own earlier tooling left
# directly at $NEBULAOS_ROOT (not under system/migration-backups at all) -
# mechanically recognized by the exact "printer.cfg.pre-*.bak" naming
# convention every real NebulaOS backup mechanism already uses elsewhere
# in this file, never a broad "*.bak" glob (which could just as easily
# match something a user or a different tool created). Age+count floor
# applies here too - never deletes the single newest one, never touches
# anything less than 7 days old.
clean_stray_bak_files() {
	find "$NEBULAOS_ROOT" -mindepth 1 -maxdepth 1 -type f -name 'printer.cfg.pre-*.bak' -mtime +7 2>/dev/null | \
		sort -r | tail -n +2 | while read -r f; do
		path_is_namespace_safe "$f" && delete "$f" "stray-legacy-config-backup"
	done
}

# Clean Mainsail config root mission (2026-09-10): Klipper's own SAVE_CONFIG
# mechanism writes a fresh printer-YYYYMMDD_HHMMSS.cfg backup directly into
# printer_data/config/ (upstream Klipper behavior, printer.py's
# save_config() - not something this project patches or controls) every
# time a calibration macro runs SAVE_CONFIG. Left unmanaged, this directory
# accumulates one small text file per calibration run forever - unlike
# clean_old_config_backups()/clean_migration_backups() above, these are not
# duplicated debris this project's own tooling created, they are Klipper's
# own real, user-meaningful configuration history (the same content
# 06-verify.sh/config-materialize.sh treat as first-class elsewhere), so a
# more generous KEEP than the 2-copy floor used for multi-hundred-MB
# migration backups is used here. Name-pattern-filtered (not a whole-
# directory prune like prune_backup_dir()) because printer_data/config also
# holds the live printer.cfg, nebulaos/, macros/, etc. that must never be
# touched by retention.
SAVE_CONFIG_BACKUP_KEEP=10

# G62 (2026-10-16): Klipper writes printer-YYYYMMDD_HHMMSS.cfg next to
# printer.cfg on every SAVE_CONFIG and never reads them back
# (klippy/configfile.py). They are moved into config/backups/ (mtime kept)
# so the config folder shows only what Klipper reads; pruning works there.
move_save_config_backups() {
	src="$NEBULAOS_ROOT/printer_data/config"
	dst="$src/backups"
	[ -d "$src" ] || return 0
	find "$src" -maxdepth 1 -type f -name 'printer-[0-9]*_[0-9]*.cfg' 2>/dev/null | while read -r f; do
		path_is_namespace_safe "$f" || continue
		mkdir -p "$dst" 2>/dev/null
		[ -e "$dst/$(basename "$f")" ] && continue
		if [ "$dryrun" = "true" ]; then
			log "[DRY-RUN] would move to config/backups: $f"
		else
			mv "$f" "$dst/" && log "moved to config/backups: $f"
		fi
	done
}

clean_old_save_config_backups() {
	move_save_config_backups
	dir="$NEBULAOS_ROOT/printer_data/config/backups"
	[ -d "$dir" ] || return 0
	find "$dir" -maxdepth 1 -type f -name 'printer-[0-9]*_[0-9]*.cfg' -mtime +7 2>/dev/null | \
		sort -r | tail -n "+$((SAVE_CONFIG_BACKUP_KEEP + 1))" | while read -r f; do
		path_is_namespace_safe "$f" && delete "$f" "old-save-config-backup"
	done
}

clean_abandoned_staging() {
	find "$NEBULAOS_ROOT/updates/staging" -mindepth 1 -maxdepth 1 -mtime +1 2>/dev/null | while read -r f; do
		name=$(basename "$f")
		[ -e "$LOCKDIR/$name.lock" ] && continue
		path_is_namespace_safe "$f" && delete "$f" "abandoned-staging"
	done
}

clean_obsolete_versions() {
	# Keeps the newest 2 *failure-evidence* directories (failed-<ts>) per
	# component - never deletes the only remaining copy. BusyBox find has
	# no -printf (found live: "unrecognized: -printf") - `ls -1t` (BusyBox
	# ls extension, newest-first) is the portable alternative to sorting
	# by mtime.
	#
	# Real bug found live (Phase E, 2026-07-27): this used to sort and
	# prune EVERYTHING under backups/$comp mixed together, including
	# last-known-good/last-known-good-env - the single, continuously-
	# updated backup the Phase C/D update-supervisor's own rollback
	# mechanism depends on to restore from, not an "old version" to
	# rotate away. Confirmed live via the real retention log: this ran
	# repeatedly across multiple boots and genuinely tried to delete it
	# every time (masked only by a separate bug - see delete() - that
	# made the rm itself silently fail on directories). Explicitly
	# excluded now: only failed-* evidence directories are ever
	# candidates, the paired backup is never touched by this script at
	# all (it's the supervisor's own responsibility, not retention's).
	for comp in klipper moonraker mainsail; do
		dir="$NEBULAOS_ROOT/backups/$comp"
		[ -d "$dir" ] || continue
		count=$(find "$dir" -mindepth 1 -maxdepth 1 -name 'failed-*' 2>/dev/null | wc -l)
		[ "$count" -le 2 ] && continue
		( cd "$dir" && ls -1td failed-* 2>/dev/null ) | tail -n "+3" | while read -r name; do
			f="$dir/$name"
			path_is_namespace_safe "$f" && delete "$f" "obsolete-version-$comp"
		done
	done
}

clean_pip_cache() {
	[ -d /root/.cache ] && [ "$dryrun" != "true" ] && rm -rf /root/.cache
}

# --- Disk-pressure handling ---

free_mb() {
	df -m /usr/data 2>/dev/null | tail -1 | awk '{print $4}'
}

# Never deletes: the active print's own file, a partial/in-progress
# upload, anything under a USB mount, or anything with ambiguous state -
# per the mission's own explicit requirement. This is a real, deliberate
# improvement over SimpleAF's own reference script, which has no such
# check at all (docs/NEBULAOS_RETENTION_POLICY.md sec 1).
gcode_is_protected() {
	f="$1"
	# USB-mounted content lives under $SHARED_GCODES/USB - excluded by the
	# emergency loop's own -maxdepth 1 below, checked again here for
	# defense in depth.
	case "$f" in
		"$SHARED_GCODES"/USB/*) return 0 ;;
	esac
	# Confirmed live against a real Moonraker instance (2026-07-26): its
	# JSON output is compact, no space after ':' - e.g.
	# {"result":{"status":{"print_stats":{"filename":"","state":"standby"...
	active=$(wget -q -O - --timeout=3 "http://127.0.0.1:7125/printer/objects/query?print_stats" 2>/dev/null)
	case "$active" in
		*'"state":"printing"'*|*'"state":"paused"'*)
			current=$(echo "$active" | sed -n 's/.*"filename":"\([^"]*\)".*/\1/p')
			[ -n "$current" ] && [ "$(basename "$f")" = "$(basename "$current")" ] && return 0
			;;
	esac
	# A file still growing (modified within the last minute) is treated as
	# a possible in-progress upload - ambiguous, so protected. BusyBox
	# find's -mmin (confirmed live, unlike -printf) is the portable check.
	if [ -n "$(find "$f" -maxdepth 0 -mmin -1 2>/dev/null)" ]; then
		return 0
	fi
	return 1
}

emergency_gcode_cleanup() {
	log "CRITICAL disk pressure - running emergency shared-gcode cleanup (verified stock pattern, docs/NEBULAOS_RETENTION_POLICY.md sec 2.4)"
	find "$SHARED_GCODES" -maxdepth 1 -name "*.gcode" -type f -mtime +7 2>/dev/null | \
		sort | while read -r f; do
		[ "$(free_mb)" -gt "$CRITICAL_FLOOR_MB" ] && break
		if gcode_is_protected "$f"; then
			log "SKIPPED (protected - active print/partial upload/ambiguous): $f"
			continue
		fi
		delete "$f" "emergency-gcode-disk-pressure"
	done
}

print_active() {
	case "$(wget -q -O - --timeout=3 "$MOONRAKER_PRINT_STATS" 2>/dev/null)" in
		*'"state":"printing"'*|*'"state":"paused"'*) return 0 ;;
	esac
	return 1
}

clean_old_system_images() {
	[ -d "$SYSTEM_IMAGE_DIR" ] || return 0
	path_is_namespace_safe "$SYSTEM_IMAGE_DIR" || return 0
	if grep -qE '"state": *"(running|restarting)"' "$IMAGE_JOB_STATE" 2>/dev/null; then
		log "system image install running - old uploaded images left alone this run"
		return 0
	fi
	find "$SYSTEM_IMAGE_DIR" -maxdepth 1 -type f -mtime +"$SYSTEM_IMAGE_MAX_DAYS" 2>/dev/null | \
		while read -r f; do
		path_is_namespace_safe "$f" || continue
		delete "$f" "uploaded-system-image-older-than-${SYSTEM_IMAGE_MAX_DAYS}d"
	done
}

# G65/G66: config/backups/nebulaos-changes-* (a user's edits of
# config/nebulaos kept by an update) - the newest NEBULAOS_CHANGES_KEEP stay.
NEBULAOS_CHANGES_KEEP=5
clean_old_nebulaos_changes() {
	_dir="$NEBULAOS_ROOT/printer_data/config/backups"
	[ -d "$_dir" ] && path_is_namespace_safe "$_dir" || return 0
	ls -1d "$_dir"/nebulaos-changes-* 2>/dev/null | sort -r | tail -n "+$((NEBULAOS_CHANGES_KEEP + 1))" | \
		while read -r d; do
		path_is_namespace_safe "$d" && delete "$d" "old-nebulaos-changes"
	done
}

retention_lock() {
	mkdir -p "$(dirname "$RETENTION_LOCK")" 2>/dev/null
	mkdir "$RETENTION_LOCK" 2>/dev/null && return 0
	if [ -n "$(find "$RETENTION_LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
		rmdir "$RETENTION_LOCK" 2>/dev/null
		mkdir "$RETENTION_LOCK" 2>/dev/null && { log "removed a stale retention lock"; return 0; }
	fi
	return 1
}

start() {
	mkdir -p "$NEBULAOS_ROOT/maintenance"
	retention_lock || return 0           # another run is busy - it does the work
	trap 'rmdir "$RETENTION_LOCK" 2>/dev/null' EXIT
	[ -n "${NEBULAOS_RETENTION_SKIP_CLOCK_WAIT:-}" ] || wait_for_clock_sync
	# G66: the periodic run (housekeeping, every 30 min) never competes with a
	# print for the eMMC.
	if [ -n "${NEBULAOS_RETENTION_PERIODIC:-}" ] && print_active; then
		return 0
	fi

	if update_in_progress; then
		log "update transaction in progress - restricting to backup/log-only rotation this run"
		rotate_platform_logs
		clean_rotated_logs
		trim_small_logs
		return 0
	fi

	rotate_platform_logs
	clean_rotated_logs
	trim_small_logs
	clean_old_config_backups
	clean_old_save_config_backups
	clean_abandoned_staging
	clean_obsolete_versions
	clean_migration_backups
	clean_mainsail_namespace_backups
	clean_stray_bak_files
	clean_old_nebulaos_changes
	# Age rules need a real clock (none before NTP or the saved clock).
	[ "$(date +%s)" -ge 1784851200 ] && clean_old_system_images

	free=$(free_mb)
	if [ -z "$free" ]; then
		log "could not determine free space on /usr/data - skipping pressure-based actions"
		return 0
	fi

	if [ "$free" -lt "$CRITICAL_FLOOR_MB" ]; then
		log "CRITICAL: ${free}MB free (floor ${CRITICAL_FLOOR_MB}MB)"
		clean_pip_cache
		# G66: deleting the user's print files stays a once-per-boot last
		# resort (S45), never every 30 minutes from the housekeeping loop.
		if [ -n "${NEBULAOS_RETENTION_PERIODIC:-}" ]; then
			log "CRITICAL: print files are only cleaned at boot - not in the periodic run"
		else
			emergency_gcode_cleanup
		fi
	elif [ "$free" -lt "$CAUTION_FLOOR_MB" ]; then
		log "CAUTION: ${free}MB free (floor ${CAUTION_FLOOR_MB}MB) - new updates should be blocked until this clears (Phase 8's own concern, not this script's)"
	fi
}

# Sourcing seam for offline tests (same convention as S04nebulaos-migrate's
# S04NEBULAOS_MIGRATE_NO_AUTORUN) - lets a test `. ` this file to reach its
# individual functions (clean_migration_backups, prune_backup_dir, etc.)
# with fake NEBULAOS_ROOT/LOG paths, without start() running immediately
# and without waiting on wait_for_clock_sync's real clock check.
if [ -z "${NEBULAOS_RETENTION_NO_AUTORUN:-}" ]; then
	start
fi
