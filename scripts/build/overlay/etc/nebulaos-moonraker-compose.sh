# shellcheck shell=sh
#
# Compose the NebulaOS [nebulaos] Moonraker component (and, since 2026-10-31,
# upstream's [timelapse]) into a Moonraker
# checkout (GUI/service readiness mission, 2026-10-09). Sourced by
# S05nebulaos-activate and S56moonraker.
#
# The component lives on the read-only rootfs (/usr/lib/nebulaos/moonraker/
# nebulaos.py). Moonraker only imports components from its own package, so the
# persistent checkout gets a symlink moonraker/components/nebulaos.py listed in
# that clone's .git/info/exclude - the same no-fork mechanism as the Klipper
# extras: Moonraker's update_manager still sees a pristine repository.
#
# Why S56 runs it too: update_manager's update (git pull), rollback and soft
# recover (reset --hard / checkout) leave an excluded untracked file alone,
# but a HARD recover deletes the checkout and re-clones it - symlink and
# exclude entry gone. Every one of those paths ends in a Moonraker restart
# through /etc/init.d/S56moonraker (supervisorctl shim, the update
# supervisor's rollback and liveness restarts), so composing in S56 start()
# restores the component before Moonraker imports it. tests/
# moonraker-component-survival-tests.sh replays those git operations.
#
# Idempotent. An upstream file of the same name is never replaced (logged;
# the component is then unavailable). Never fails its caller: Moonraker loads
# [nebulaos] as an optional component.

NEBULAOS_MOONRAKER_COMPONENT="${NEBULAOS_MOONRAKER_COMPONENT:-/usr/lib/nebulaos/moonraker/nebulaos.py}"
# Timelapse (2026-10-31): upstream moonraker-timelapse's component, shipped
# on the rootfs by the image and composed the same way.
NEBULAOS_TIMELAPSE_COMPONENT="${NEBULAOS_TIMELAPSE_COMPONENT:-/usr/lib/nebulaos/moonraker/timelapse.py}"

compose_moonraker_component() {
	for _src in "$NEBULAOS_MOONRAKER_COMPONENT" "$NEBULAOS_TIMELAPSE_COMPONENT"; do
		_compose_one_component "$1" "$_src"
	done
	return 0
}

_compose_one_component() {
	_mr="$1"
	_src="$2"
	_name=$(basename "$_src")
	_dst="$_mr/moonraker/components/$_name"
	_excl="$_mr/.git/info/exclude"
	_rel="/moonraker/components/$_name"
	[ -d "$_mr/moonraker/components" ] || return 0
	[ -f "$_src" ] || { echo "moonraker-compose: $_src missing - not composing $_name"; return 0; }
	if [ -e "$_dst" ] && [ ! -L "$_dst" ]; then
		echo "moonraker-compose: $_dst is a real file (upstream collision?) - not replacing it, $_name unavailable"
		return 0
	fi
	if [ "$(readlink "$_dst" 2>/dev/null)" != "$_src" ]; then
		ln -sfn "$_src" "$_dst" 2>/dev/null \
			|| { echo "moonraker-compose: could not compose $_name"; return 0; }
	fi
	if [ -d "$_mr/.git" ]; then
		mkdir -p "$_mr/.git/info" 2>/dev/null
		grep -qxF "$_rel" "$_excl" 2>/dev/null || echo "$_rel" >> "$_excl" 2>/dev/null
	fi
	return 0
}

# Lets Moonraker's machine.services.* act on a NebulaOS service (GuppyScreen's
# "Restart GuppyScreen" uses machine.services.restart). Moonraker only manages
# services listed in <data path>/moonraker.asvc, and reads it once at start.
# Adds the name when missing (creates the file when absent - Moonraker's own
# default list names services this image does not have); never removes
# anything a user added. Idempotent, never fails its caller.
allow_moonraker_service() {
	_asvc="$1/moonraker.asvc"
	_svc="$2"
	[ -d "$1" ] || return 0
	grep -qxF "$_svc" "$_asvc" 2>/dev/null && return 0
	if [ -s "$_asvc" ] && [ -n "$(tail -c 1 "$_asvc" 2>/dev/null)" ]; then
		echo >> "$_asvc" 2>/dev/null
	fi
	echo "$_svc" >> "$_asvc" 2>/dev/null \
		|| echo "moonraker-compose: could not allow service $_svc in $_asvc"
	return 0
}
