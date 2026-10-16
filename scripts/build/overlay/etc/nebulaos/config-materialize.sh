#!/bin/sh
#
# NebulaOS config materialization - shared library (Phase 2 final software
# closure mission, 2026-09-09; see docs/NEBULAOS_CONFIG_MATERIALIZATION.md
# for the full architecture writeup).
#
# The immutable /etc/nebulaos/klipper/*.cfg tree (platform.cfg, machine.cfg,
# ..., beeper.cfg) is the canonical source this image ships, read-only,
# slot-owned. Klipper does NOT include it directly any more - it reads a
# MATERIALIZED, persistent copy at $PRINTER_DATA_CONFIG/nebulaos/, so that
# a device's active config always lives on the same writable storage as
# printer.cfg itself, browsable and (in principle) inspectable through
# Mainsail's ordinary Config Files view, the same way macros/, guppyscreen/
# and firmware/mcu/ already are.
#
# materialize_config_tree() is the one function both boot-time migration
# (S04nebulaos-migrate) and the explicit `nebulaos-recover config` command
# call - never duplicated, so both code paths get backup/verify/atomic-
# replace/generation-marker behavior identically.
#
# Sourced, not executed - defines functions and reads the following
# variables from the caller's environment, all overridable for tests, same
# convention as every other shared lib in this project (see GATE_LIB):
#   NEBULAOS_KLIPPER_CFG_DIR   - immutable source (default /etc/nebulaos/klipper)
#   PRINTER_DATA_CONFIG        - persistent user config root
#   SYSTEM                     - persistent NebulaOS system state root
#   BACKUP_ROOT                - $SYSTEM/migration-backups by convention
#   log                        - a log() function the caller already defines

NEBULAOS_KLIPPER_CFG_DIR="${NEBULAOS_KLIPPER_CFG_DIR:-/etc/nebulaos/klipper}"
CONFIG_GENERATION_FILE="${CONFIG_GENERATION_FILE:-$SYSTEM/config-generation.json}"

# Same minimal, dependency-free regex accessor S04nebulaos-migrate's own
# json_get() already uses - correct here too because every key this
# function reads (generation, and each "<file>.cfg" entry in the
# manifest's flat files map) is unique within its file, regardless of
# nesting depth.
_cm_json_get() {
	file="$1"; key="$2"
	grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null | \
		sed -E "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"/\1/" | head -1
}

# 0 if the currently-booted image's manifest generation differs from (or
# there is no) recorded config-generation.json - i.e. materialization is
# needed. 1 if they already match (ordinary reboot, nothing to do).
config_materialization_needed() {
	manifest="$NEBULAOS_KLIPPER_CFG_DIR/.manifest.json"
	[ -f "$manifest" ] || { log "ERROR: $manifest missing - cannot determine config generation"; return 0; }
	image_generation=$(_cm_json_get "$manifest" generation)
	[ -n "$image_generation" ] || { log "ERROR: $manifest has no generation field"; return 0; }

	[ -f "$CONFIG_GENERATION_FILE" ] || return 0
	recorded_generation=$(_cm_json_get "$CONFIG_GENERATION_FILE" generation)
	[ "$recorded_generation" = "$image_generation" ] && return 1
	return 0
}

# G65 (2026-10-16): before config/nebulaos is replaced, keep any file the user
# edited where they can see it - config/backups/nebulaos-changes-<UTC>/ - and
# leave a notice for the screen. A file counts as edited when it differs from
# the sha256 recorded at the previous materialization. Without a record (a
# device materialized by an older image) every file that differs from this
# image's version is kept, without a notice: an older shipped version cannot
# be told from an edit.
NOTICES_DIR="${NOTICES_DIR:-$SYSTEM/notices}"
_cm_save_user_edits() {
	_cse_dest="$1"
	[ -d "$_cse_dest" ] || return 0
	_cse_out="$PRINTER_DATA_CONFIG/backups/nebulaos-changes-$(date -u +%Y%m%dT%H%M%SZ)"
	_cse_edited=""
	_cse_kept=""
	for _cse_f in "$_cse_dest"/*.cfg; do
		[ -f "$_cse_f" ] && [ ! -L "$_cse_f" ] || continue
		_cse_name=$(basename "$_cse_f")
		_cse_cur=$(sha256sum "$_cse_f" | cut -d' ' -f1)
		_cse_rec=$(_cm_json_get "$CONFIG_GENERATION_FILE" "file_sha256.$_cse_name")
		if [ -n "$_cse_rec" ]; then
			[ "$_cse_cur" = "$_cse_rec" ] && continue
			_cse_edited="$_cse_edited $_cse_name"
		else
			_cse_new=$(_cm_json_get "$NEBULAOS_KLIPPER_CFG_DIR/.manifest.json" "$_cse_name")
			[ "$_cse_cur" = "$_cse_new" ] && continue
		fi
		mkdir -p "$_cse_out" && cp -a "$_cse_f" "$_cse_out/$_cse_name" && _cse_kept="$_cse_kept $_cse_name"
	done
	[ -n "$_cse_kept" ] || return 0
	log "materialize_config_tree: kept the previous version of:$_cse_kept in $_cse_out"
	if [ -n "$_cse_edited" ]; then
		cat > "$_cse_out/WHAT-HAPPENED.txt" <<EOT
NebulaOS was updated and replaced its own settings in config/nebulaos/.
You had changed these files there:$_cse_edited
Your versions are in this folder. To keep a change, copy the section or
option into printer.cfg (or a file in macros/) - settings there override
NebulaOS's and survive every update.
EOT
		mkdir -p "$NOTICES_DIR" 2>/dev/null
		printf 'Your changes to%s were replaced by the update. Your versions are in config/backups/%s.\n' \
			"$_cse_edited" "$(basename "$_cse_out")" > "$NOTICES_DIR/config-edits.txt"
	fi
	return 0
}

# Backs up the current $PRINTER_DATA_CONFIG/nebulaos/ (if present) to
# $BACKUP_ROOT/config-materialization/<timestamp>/, atomically replaces it
# with a fresh copy of $NEBULAOS_KLIPPER_CFG_DIR's own current content
# (verified file-by-file against its own .manifest.json before ever being
# promoted into place), and records the new generation. Never touches
# printer.cfg, moonraker.conf, macros/, guppyscreen/, firmware/, or
# anything else under $PRINTER_DATA_CONFIG - its only inputs and outputs
# are $NEBULAOS_KLIPPER_CFG_DIR (read-only) and $PRINTER_DATA_CONFIG/
# nebulaos (the only thing it ever writes).
#
# Returns 0 on success, 1 on any failure (nothing promoted, existing tree
# left untouched, clearly logged). $3 (source_label) is recorded in
# config-generation.json purely for diagnostics (e.g. "boot-materialization"
# vs "recover-config").
materialize_config_tree() {
	source_label="${1:-materialize}"

	manifest="$NEBULAOS_KLIPPER_CFG_DIR/.manifest.json"
	if [ ! -f "$manifest" ]; then
		log "ERROR: materialize_config_tree: $manifest missing - refusing to materialize with no manifest to verify against"
		return 1
	fi
	image_generation=$(_cm_json_get "$manifest" generation)
	if [ -z "$image_generation" ]; then
		log "ERROR: materialize_config_tree: $manifest has no generation field - refusing to materialize"
		return 1
	fi

	cfg_files=$(cd "$NEBULAOS_KLIPPER_CFG_DIR" 2>/dev/null && ls -1 *.cfg 2>/dev/null | sort)
	if [ -z "$cfg_files" ]; then
		log "ERROR: materialize_config_tree: no *.cfg files found under $NEBULAOS_KLIPPER_CFG_DIR - refusing to materialize"
		return 1
	fi

	tmp="$PRINTER_DATA_CONFIG/nebulaos.materialize-tmp.$$"
	rm -rf "$tmp"
	mkdir -p "$tmp" || { log "ERROR: materialize_config_tree: could not create staging dir $tmp"; return 1; }
	# mkdir's resulting mode depends on the caller's umask (boot-time init
	# contexts may run under a restrictive umask), which would otherwise
	# leave the promoted $dest directory inconsistent with its siblings in
	# $PRINTER_DATA_CONFIG. Force the standard, Moonraker-file-API-readable
	# mode regardless of caller umask.
	chmod 0755 "$tmp" || { log "ERROR: materialize_config_tree: could not set standard permissions on staging dir $tmp"; rm -rf "$tmp"; return 1; }

	for f in $cfg_files; do
		if ! cp -a "$NEBULAOS_KLIPPER_CFG_DIR/$f" "$tmp/$f"; then
			log "ERROR: materialize_config_tree: could not copy $f into staging - aborting, nothing promoted"
			rm -rf "$tmp"
			return 1
		fi
		expected_sha=$(_cm_json_get "$manifest" "$f")
		if [ -z "$expected_sha" ]; then
			log "ERROR: materialize_config_tree: manifest has no entry for $f - aborting, nothing promoted"
			rm -rf "$tmp"
			return 1
		fi
		actual_sha=$(sha256sum "$tmp/$f" | cut -d' ' -f1)
		if [ "$actual_sha" != "$expected_sha" ]; then
			log "ERROR: materialize_config_tree: $f staged content does not match manifest (expected $expected_sha, got $actual_sha) - aborting, nothing promoted"
			rm -rf "$tmp"
			return 1
		fi
	done

	# G63: what this folder is, for anyone browsing it in Mainsail. Written into
	# the staged tree, since the whole folder is replaced at every generation.
	cat > "$tmp/README.txt" <<'README'
NebulaOS's own Klipper settings - please do not edit these files.

They are replaced every time NebulaOS is updated. To change a setting, put
the section or option in printer.cfg (or a file in macros/): a setting
there overrides the one here and survives every update.

If you did edit a file here, the update keeps your version in
config/backups/nebulaos-changes-<date>/ and the screen tells you.
README

	dest="$PRINTER_DATA_CONFIG/nebulaos"
	_cm_save_user_edits "$dest"
	if [ -d "$dest" ]; then
		ts=$(date -u +%Y%m%dT%H%M%SZ)
		backup_dir="$BACKUP_ROOT/config-materialization/$ts"
		mkdir -p "$(dirname "$backup_dir")"
		if ! mv "$dest" "$backup_dir"; then
			log "ERROR: materialize_config_tree: could not back up existing $dest to $backup_dir - aborting, existing tree left in place"
			rm -rf "$tmp"
			return 1
		fi
		log "materialize_config_tree: existing $dest backed up to $backup_dir before replacement"
	fi

	if ! mv "$tmp" "$dest"; then
		log "ERROR: materialize_config_tree: could not promote staged tree to $dest - THIS IS A PARTIAL-FAILURE STATE, check $tmp and $backup_dir manually"
		return 1
	fi

	mkdir -p "$(dirname "$CONFIG_GENERATION_FILE")"
	# G65: written atomically; flat per-file keys (the manifest's own sha256,
	# never a nested "generation") so the next materialization can tell a
	# user's edit from the shipped file.
	{
		printf '{\n  "schema_version": 1,\n  "generation": "%s",\n' "$image_generation"
		printf '  "materialized_at": "%s",\n  "source": "%s"' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$source_label"
		for f in $cfg_files; do
			printf ',\n  "file_sha256.%s": "%s"' "$f" "$(_cm_json_get "$manifest" "$f")"
		done
		printf '\n}\n'
	} > "$CONFIG_GENERATION_FILE.tmp" && mv -f "$CONFIG_GENERATION_FILE.tmp" "$CONFIG_GENERATION_FILE"
	log "materialize_config_tree: materialized $dest at generation $image_generation (source: $source_label)"
	return 0
}
