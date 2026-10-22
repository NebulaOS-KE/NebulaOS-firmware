#!/bin/sh
#
# nebulaos-busy.sh - the fast shell variant of the G91 shared busy check
# (design _scratch/run16/G91-update-design.md v2.1, v3.1, v3.6), sourced by
# the supervisorctl shim, the update supervisor and its NebulaScreen
# component. It answers the two profiles that may need an answer without a
# Python start-up:
#
#   restart    supervisorctl restart/stop of klipper (v3.1: < 2 s, runs before
#              `stop`): PRINTING PAUSED ACTIVE, and UNKNOWN (a failed query
#              against a live, ready Klippy - a hung query never lets a
#              Klipper restart through, N3)
#   recovery   the supervisor's validation restarts and rollback transaction:
#              PRINTING PAUSED ACTIVE only; UNKNOWN counts only together with
#              the print-active marker (N3); never a lock (a rollback outranks
#              an update)
#
# Every other profile (request, point_of_no_return, git) and the lock /
# memory / trial reasons live in nebulaos_osconfig.common.busy_state, CLI
# /usr/libexec/nebulaos/nebulaos-busy. Both read the same facts the same way;
# tests/nebulaos-busy-tests.sh holds them to the same answers.
#
#   nebulaos_busy_fast PROFILE   echoes the reason and returns 0 when busy,
#                                returns 1 (nothing echoed) when not busy
#
# Order (v3.6 note 1):
#   1. Moonraker's /server/info klippy_state.
#        ready            -> query print_stats, idle_timeout, heater targets,
#                            PLR resume_in_progress in one request
#        error, shutdown  -> not ready (Moonraker talks to Klippy: positive)
#        disconnected, startup, no answer -> the Klippy pid: not alive -> not
#                            ready; alive -> ask Klippy's API socket (N1)
#   2. Klippy not ready: no print can run - not busy, whatever the memguard
#      markers say (R3: a crashed Klippy can always be restarted, S19/S27).
#   3. Otherwise the print state, activity, and the memguard markers
#      print-active / klipper-active (they only ever add busy).
#
# BusyBox ash; wget is BusyBox's (-T timeout). Python only on the rare
# Klippy-socket path (Moonraker down or not connected while Klippy runs).

NB_RUN_DIR="${NEBULAOS_RUN_DIR:-/run/nebulaos}"
NB_MOONRAKER="${NB_MOONRAKER:-${MOONRAKER_URL:-http://127.0.0.1:7125}}"
NB_KLIPPY_PIDFILE="${NB_KLIPPY_PIDFILE:-/var/run/klippy.pid}"
NB_KLIPPY_SOCK="${NB_KLIPPY_SOCK:-/opt/printer_data/comms/klippy.sock}"
NB_TIMEOUT="${NB_TIMEOUT:-2}"
NB_SOCKET_TIMEOUT="${NB_SOCKET_TIMEOUT:-$NB_TIMEOUT}"
NB_PYTHON="${NB_PYTHON:-python3}"
NB_QUERY="print_stats=state&idle_timeout=state&extruder=target&heater_bed=target&nebulaos_power_loss_recovery=resume_in_progress"

nb_http() { # PATH -> body on stdout; rc != 0 when Moonraker did not answer
	wget -q -T "$NB_TIMEOUT" -O - "$NB_MOONRAKER$1" 2>/dev/null
}

nb_klippy_alive() {
	_nbp=
	[ -r "$NB_KLIPPY_PIDFILE" ] && read -r _nbp < "$NB_KLIPPY_PIDFILE" 2>/dev/null
	[ -n "$_nbp" ] && [ -d "/proc/$_nbp" ]
}

# Klippy's own API socket: prints NOT_READY, UNKNOWN, or the status as
# {"result":{"status":{...}}} (the shape Moonraker returns).
nb_klippy_socket() {
	"$NB_PYTHON" -I -S -c '
import json, socket, sys
path, timeout = sys.argv[1], float(sys.argv[2])
objects = {"print_stats": ["state"], "idle_timeout": ["state"], "extruder": ["target"],
           "heater_bed": ["target"], "nebulaos_power_loss_recovery": ["resume_in_progress"]}
def req(method, params):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        try:
            s.connect(path)
        except OSError:
            raise LookupError("nothing listens")
        s.sendall(json.dumps({"id": 1, "method": method, "params": params}).encode() + b"\x03")
        data = b""
        while b"\x03" not in data:
            block = s.recv(65536)
            if not block:
                raise ValueError("closed")
            data += block
    finally:
        s.close()
    return json.loads(data.split(b"\x03", 1)[0].decode("utf-8", "replace"))["result"]
try:
    info = req("info", {})
except LookupError:
    print("NOT_READY"); sys.exit(0)
except Exception:
    print("UNKNOWN"); sys.exit(0)
if info.get("state") != "ready":
    print("NOT_READY"); sys.exit(0)
try:
    status = req("objects/query", {"objects": objects})["status"]
except Exception:
    print("UNKNOWN"); sys.exit(0)
print(json.dumps({"result": {"status": status}}, separators=(",", ":")))
' "$NB_KLIPPY_SOCK" "$NB_SOCKET_TIMEOUT" 2>/dev/null || echo UNKNOWN
}

# One flat field of one status object from compact JSON (spaces removed):
# _nbv = the value without quotes, empty when absent.
nb_field() { # JSON OBJECT KEY
	_nbv=
	_nbo=${1#*\""$2"\":\{}
	[ "$_nbo" = "$1" ] && return 0
	_nbo=${_nbo%%\}*}
	_nbv=${_nbo#*\""$3"\":}
	[ "$_nbv" = "$_nbo" ] && { _nbv=; return 0; }
	_nbv=${_nbv%%,*}
	_nbv=${_nbv#\"}
	_nbv=${_nbv%\"}
}

# The Klippy facts: _nb_klippy = ready | not_ready | unknown, _nb_json = the
# status reply without spaces (ready only).
nb_klippy_facts() {
	_nb_klippy=unknown _nb_json=
	_nbinfo=$(nb_http /server/info)
	_nbinfo=$(printf '%s' "$_nbinfo" | tr -d ' \n\r\t')
	_nbks=
	case "$_nbinfo" in
		*'"klippy_state":"'*)
			_nbks=${_nbinfo#*\"klippy_state\":\"}
			_nbks=${_nbks%%\"*} ;;
	esac
	case "$_nbks" in
		ready)
			_nb_json=$(nb_http "/printer/objects/query?$NB_QUERY" | tr -d ' \n\r\t')
			case "$_nb_json" in
				*'"status":{'*) _nb_klippy=ready ;;
				*) _nb_klippy=unknown _nb_json= ;;
			esac
			return 0 ;;
		error|shutdown) _nb_klippy=not_ready; return 0 ;;
	esac
	# Moonraker down, or not (yet) connected: Klippy decides (N1).
	if ! nb_klippy_alive; then
		_nb_klippy=not_ready
		return 0
	fi
	_nb_json=$(nb_klippy_socket)
	case "$_nb_json" in
		NOT_READY) _nb_klippy=not_ready _nb_json= ;;
		*'"status":{'*) _nb_klippy=ready ;;
		*) _nb_klippy=unknown _nb_json= ;;
	esac
}

# Reasons the status says, in table order (space separated, in _nb_reasons).
nb_status_reasons() {
	_nb_reasons=
	nb_field "$_nb_json" print_stats state
	case "$_nbv" in
		printing) _nb_reasons="PRINTING" ;;
		paused) _nb_reasons="PAUSED" ;;
	esac
	_nbact=
	nb_field "$_nb_json" idle_timeout state
	[ "$_nbv" = Printing ] && _nbact=1
	for _nbh in extruder heater_bed; do
		nb_field "$_nb_json" "$_nbh" target
		case "$_nbv" in *[1-9]*) _nbact=1 ;; esac
	done
	nb_field "$_nb_json" nebulaos_power_loss_recovery resume_in_progress
	[ "$_nbv" = true ] && _nbact=1
	[ -n "$_nbact" ] && _nb_reasons="$_nb_reasons ACTIVE"
	return 0
}

nebulaos_busy_fast() { # PROFILE -> echo REASON, rc 0 busy / 1 not busy
	case "$1" in
		restart) _nbcount="PRINTING PAUSED ACTIVE UNKNOWN" ;;
		recovery) _nbcount="PRINTING PAUSED ACTIVE" ;;
		*) echo "nebulaos_busy_fast: unknown profile '$1'" >&2; echo UNKNOWN; return 0 ;;
	esac
	nb_klippy_facts
	[ "$_nb_klippy" = not_ready ] && return 1
	_nb_reasons=
	[ "$_nb_klippy" = ready ] && nb_status_reasons
	case " $_nb_reasons " in *" PAUSED "*) ;; *)
		[ -e "$NB_RUN_DIR/print-active" ] && _nb_reasons="PRINTING $_nb_reasons" ;;
	esac
	[ -e "$NB_RUN_DIR/klipper-active" ] && _nb_reasons="$_nb_reasons ACTIVE"
	[ "$_nb_klippy" = unknown ] && _nb_reasons="$_nb_reasons UNKNOWN"
	for _nbr in PRINTING PAUSED ACTIVE UNKNOWN; do
		case " $_nb_reasons " in *" $_nbr "*) ;; *) continue ;; esac
		case " $_nbcount " in *" $_nbr "*) echo "$_nbr"; return 0 ;; esac
	done
	return 1
}
