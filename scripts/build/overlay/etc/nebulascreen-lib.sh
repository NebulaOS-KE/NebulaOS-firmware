#!/bin/sh
# NebulaScreen (GuppyScreen renamed, Run 15) - boot-time helpers, sourced.
#
# Stage 2a of the G82 + rename plan (_scratch/run15/G82-rename-architecture-
# review.md), wired into S01/S58 by stage 2b and used by the update
# supervisor (stage 3). Every function is best-effort: it logs and returns,
# it never makes a boot fail.
#
# The A/B slots share /usr/data. The old image keeps using its own
# /usr/data/nebulaos/guppyscreen/guppyconfig.json, so the settings move by
# COPY, never by move or edit: a slot switch back finds its file untouched.
#
# This file may be distributed under the terms of the GNU GPLv3 license.

NS_MOUNT="${NS_MOUNT:-mount}"
NS_UMOUNT="${NS_UMOUNT:-umount}"
NS_MOUNTS="${NS_MOUNTS:-/proc/self/mounts}"
NS_PYTHON="${NS_PYTHON:-python3}"
# The binaries and data of a NebulaScreen release (G82 per-item binds: a
# whole-directory bind would hide the config file's own bind).
NS_ITEMS="${NS_ITEMS:-nebulascreen nebulabeep themes}"

ns_log() {
	echo "nebulascreen: $*"
	command -v logger >/dev/null 2>&1 && logger -t nebulascreen "$*" 2>/dev/null
	return 0
}

# A config file worth copying: non-empty and valid JSON (python3 when
# present, else at least a JSON object's first byte).
ns_json_ok() { # FILE
	[ -s "$1" ] || return 1
	if command -v "$NS_PYTHON" >/dev/null 2>&1; then
		"$NS_PYTHON" -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" \
			>/dev/null 2>&1
		return $?
	fi
	[ "$(head -c 1 "$1" 2>/dev/null)" = "{" ]
}

# The user's settings for the new name, once: copy the old GuppyScreen file
# when it is valid, else seed the image default. tmp + sync + rename, so a
# power cut leaves either nothing (redone next boot) or the whole file. An
# existing new file is never replaced.
ns_migrate_config() { # OLD NEW SEED
	_ns_old="$1" _ns_new="$2" _ns_seed="$3"
	[ -s "$_ns_new" ] && return 0
	mkdir -p "$(dirname "$_ns_new")" 2>/dev/null || {
		ns_log "cannot create $(dirname "$_ns_new") - the image default is used"
		return 0
	}
	rm -f "$_ns_new.tmp" 2>/dev/null
	if ns_json_ok "$_ns_old"; then
		_ns_src="$_ns_old" _ns_how="copied the GuppyScreen settings"
	else
		_ns_src="$_ns_seed" _ns_how="seeded the image default"
	fi
	if cp "$_ns_src" "$_ns_new.tmp" 2>/dev/null && sync \
			&& mv -f "$_ns_new.tmp" "$_ns_new" 2>/dev/null; then
		ns_log "$_ns_how into $_ns_new"
	else
		rm -f "$_ns_new.tmp" 2>/dev/null
		ns_log "could not write $_ns_new - the image default is used"
	fi
	return 0
}

# The old image's empty Mainsail placeholder (config/guppyscreen/
# guppyconfig.json): removed only when zero-length, the folder only when
# empty. The old image recreates it after a slot switch back.
ns_remove_empty_placeholder() { # FILE
	[ -f "$1" ] && [ ! -s "$1" ] && rm -f "$1" 2>/dev/null
	rmdir "$(dirname "$1")" 2>/dev/null
	return 0
}

# A complete release in APP_DIR (G82): release_info.json plus every item.
ns_release_complete() { # APP_DIR
	[ -s "$1/release_info.json" ] || return 1
	for _ns_i in $NS_ITEMS; do
		[ -e "$1/$_ns_i" ] || return 1
	done
	return 0
}

# The version a release directory states (release_info.json), or nothing.
ns_release_version() { # APP_DIR
	sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$1/release_info.json" 2>/dev/null | head -1
}

# G82 stage 3: the release the update supervisor checked (health stage 1)
# and allows S58 to bind. The supervisor writes a random token into the app
# dir (.nebulaos-approved) and into the screen's update state, next to the
# image-wins stamp. Moonraker's update_manager replaces the whole app dir on
# every download, so any new download - even of the same version - carries
# no valid token until the supervisor has checked it; a zip cannot guess it.
NS_APPROVAL_FILE=".nebulaos-approved"

ns_state_value() { # STATE_FILE KEY
	sed -n "s/^ *\"$2\": *\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -1
}

ns_release_approved() { # APP_DIR STATE_FILE
	_ns_tok=$(ns_state_value "$2" approved_token)
	[ -n "$_ns_tok" ] || return 1
	[ "$(cat "$1/$NS_APPROVAL_FILE" 2>/dev/null)" = "$_ns_tok" ] || return 1
	_ns_ver=$(ns_release_version "$1")
	[ -n "$_ns_ver" ] && [ "$_ns_ver" = "$(ns_state_value "$2" approved_version)" ]
}

ns_is_mounted() { # PATH - a mount point (a file bind counts)
	awk -v p="$1" '$2 == p { found = 1 } END { exit !found }' "$NS_MOUNTS" 2>/dev/null
}

# Per-item binds of a downloaded release over the image's copies in OPT_DIR.
# All or nothing: an incomplete release leaves the image's own files in use.
# Only from a clean state: when any item is still bound (a second start while
# the screen runs - a bound running binary cannot be unmounted) nothing is
# done, so binds never stack or mix two releases. ns_deactivate (S58 stop,
# after the process ended) clears them; restart activates afresh.
#
# With STATE_FILE (G82 stage 3, S58): only the release the update supervisor
# approved is bound. Moonraker's update_manager restarts the screen right
# after it extracted a download; until the supervisor has checked that
# download, the image's own screen runs instead of an unchecked release.
ns_activate() { # APP_DIR OPT_DIR [STATE_FILE]
	ns_release_complete "$1" || return 0
	if [ -n "${3:-}" ] && ! ns_release_approved "$1" "$3"; then
		ns_log "release $(ns_release_version "$1") in $1 is not checked yet - the image's screen runs until the update supervisor activates it"
		return 0
	fi
	for _ns_i in $NS_ITEMS; do
		[ -e "$2/$_ns_i" ] || {
			ns_log "the image has no $2/$_ns_i - release not activated"
			return 0
		}
		if ns_is_mounted "$2/$_ns_i"; then
			ns_log "$2/$_ns_i is already bound - release left as it is until the screen is restarted"
			return 0
		fi
	done
	for _ns_i in $NS_ITEMS; do
		"$NS_MOUNT" --bind "$1/$_ns_i" "$2/$_ns_i" 2>/dev/null \
			|| ns_log "bind of $1/$_ns_i failed"
	done
	ns_log "release from $1 active"
	return 0
}

# Removes the per-item binds (S58 stop, once the screen has exited), so the
# next start shows the image's files or binds the current release afresh.
ns_deactivate() { # OPT_DIR
	for _ns_i in $NS_ITEMS; do
		ns_is_mounted "$1/$_ns_i" || continue
		"$NS_UMOUNT" "$1/$_ns_i" 2>/dev/null || ns_log "could not unbind $1/$_ns_i"
	done
	return 0
}

# The image wins after a system image install (G82): when this image's
# identity (firmware_sha + build_date of /opt/nebulaos-version.json) differs
# from the one stamped at the last boot, the downloaded release is dropped
# and APP_DIR is reset to the image seed (only the image's release_info.json,
# so the image's own binaries run). The stamp lives OUTSIDE the app dir.
ns_image_identity() { # VERSION_JSON
	_ns_sha=$(sed -n 's/^ *"firmware_sha": *"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1)
	_ns_date=$(sed -n 's/^ *"build_date": *"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1)
	[ -n "$_ns_sha" ] && echo "$_ns_sha@$_ns_date"
}

# APP_DIR back to the image seed: only the image's release_info.json, so the
# image's own binaries run (also the update supervisor's factory fallback).
ns_reset_to_image() { # APP_DIR SEED_RELEASE_INFO
	case "$1" in
	*/apps/nebulascreen) ;;
	*) ns_log "refusing to reset unexpected app dir '$1'"; return 1 ;;
	esac
	mkdir -p "$1" 2>/dev/null || return 1
	find "$1" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
	cp "$2" "$1/release_info.json" 2>/dev/null || {
		ns_log "no seed release_info at $2"
		return 1
	}
	return 0
}

ns_image_wins() { # APP_DIR STATE_FILE VERSION_JSON SEED_RELEASE_INFO
	_ns_app="$1" _ns_state="$2"
	case "$_ns_app" in
	*/apps/nebulascreen) ;;
	*) ns_log "refusing to reset unexpected app dir '$_ns_app'"; return 0 ;;
	esac
	_ns_id=$(ns_image_identity "$3")
	[ -n "$_ns_id" ] || { ns_log "no image identity in $3"; return 0; }
	_ns_old_id=$(sed -n 's/^ *"image_identity": *"\([^"]*\)".*/\1/p' "$_ns_state" 2>/dev/null | head -1)
	[ "$_ns_old_id" = "$_ns_id" ] && return 0
	mkdir -p "$_ns_app" "$(dirname "$_ns_state")" 2>/dev/null || return 0
	ns_reset_to_image "$_ns_app" "$4"
	printf '{\n  "image_identity": "%s"\n}\n' "$_ns_id" > "$_ns_state.tmp" 2>/dev/null \
		&& mv -f "$_ns_state.tmp" "$_ns_state" 2>/dev/null
	ns_log "image changed (${_ns_old_id:-none} -> $_ns_id): the screen app was reset to the image's version"
	return 0
}
