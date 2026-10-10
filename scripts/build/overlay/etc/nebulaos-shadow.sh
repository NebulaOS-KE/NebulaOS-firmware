# shellcheck shell=sh
#
# Persistent root password (decision D7, 2026-10-10). The image's /etc/shadow
# is on the read-only rootfs and carries the default password every NebulaOS
# printer ships with; BusyBox passwd cannot change it (it writes /etc/shadow+
# and renames it over). At boot S01persistent-datastore seeds a persistent copy
# once and bind-mounts it over /etc/shadow; nebulaos-passwd (and the passwd
# wrapper) rewrite that copy in place, so the change survives reboots and
# image updates. Sourced by S01persistent-datastore and nebulaos-passwd.

NSH_IMAGE="${NSH_IMAGE:-/etc/shadow}"
NSH_FILE="${NSH_FILE:-/usr/data/nebulaos/system/shadow}"
NSH_MOUNTS="${NSH_MOUNTS:-/proc/mounts}"
NSH_MOUNT_CMD="${NSH_MOUNT_CMD:-mount}"
NSH_MKPASSWD="${NSH_MKPASSWD:-mkpasswd}"

nsh_log() { echo "nebulaos-shadow: $*"; }

# A usable shadow file: has a root entry with a non-empty password field.
nsh_valid() {
	awk -F: '$1 == "root" && $2 != "" { ok = 1 } END { exit !ok }' "$1" 2>/dev/null
}

# Boot: seed once, then bind over the image's file. Never fails its caller;
# on any doubt the image's /etc/shadow (default password) stays in effect.
nsh_boot() {
	if [ ! -s "$NSH_FILE" ]; then
		mkdir -p "$(dirname "$NSH_FILE")" 2>/dev/null
		( umask 077; cp "$NSH_IMAGE" "$NSH_FILE.tmp" ) 2>/dev/null \
			&& chmod 600 "$NSH_FILE.tmp" && mv -f "$NSH_FILE.tmp" "$NSH_FILE" \
			|| { rm -f "$NSH_FILE.tmp"; nsh_log "could not seed $NSH_FILE"; return 0; }
	fi
	if ! nsh_valid "$NSH_FILE"; then
		nsh_log "$NSH_FILE has no usable root entry - keeping the image's password"
		return 0
	fi
	grep -q " $NSH_IMAGE " "$NSH_MOUNTS" 2>/dev/null && return 0
	"$NSH_MOUNT_CMD" --bind "$NSH_FILE" "$NSH_IMAGE" 2>/dev/null \
		|| nsh_log "could not bind $NSH_FILE over $NSH_IMAGE"
	return 0
}

# Sets root's password from stdin (one line). Rewrites $NSH_FILE in place (same
# inode, so the bind mount shows it) and keeps the previous file as .prev.
# 0 ok, 1 refused (empty password / no persistent file), 2 failed.
nsh_set_root_password() {
	IFS= read -r _nsh_pw || true
	[ -n "$_nsh_pw" ] || { nsh_log "empty password refused"; return 1; }
	nsh_valid "$NSH_FILE" || { nsh_log "$NSH_FILE missing or invalid - reboot once, then retry"; return 1; }
	_nsh_hash=$(printf '%s\n' "$_nsh_pw" | "$NSH_MKPASSWD" -m sha256 2>/dev/null)
	unset _nsh_pw
	case "$_nsh_hash" in
		'$5$'*) ;;
		*) nsh_log "hashing failed"; return 2 ;;
	esac
	( umask 077; cp "$NSH_FILE" "$NSH_FILE.prev" ) 2>/dev/null
	_nsh_tmp="$NSH_FILE.new.$$"
	( umask 077; awk -F: -v h="$_nsh_hash" 'BEGIN { OFS = ":" } $1 == "root" { $2 = h } { print }' \
		"$NSH_FILE" > "$_nsh_tmp" ) 2>/dev/null || { rm -f "$_nsh_tmp"; return 2; }
	nsh_valid "$_nsh_tmp" && grep -qF "$_nsh_hash" "$_nsh_tmp" || { rm -f "$_nsh_tmp"; return 2; }
	cat "$_nsh_tmp" > "$NSH_FILE" || { rm -f "$_nsh_tmp"; return 2; }
	rm -f "$_nsh_tmp"
	sync
	return 0
}
