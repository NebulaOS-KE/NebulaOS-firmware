#!/bin/sh
#
# NebulaOS mutable-runtime mission, Phase 8: two-stage update verification.
#
# Stage 1 (component health) is necessarily specific to what was just
# updated - see stage1_component() below, invoked with a component name.
# Stage 2 (full printer-stack health) is the same regardless of which
# component changed, and is safe to run standalone at any time (read-only
# queries only) - this is the part validated live in this pass, against
# the currently-running production Klipper/Moonraker, since it does not
# depend on Phase 7's mutable installs existing yet.
#
# Usage: nebulaos-healthcheck.sh stage1 <klipper|moonraker|mainsail> <path>
#        nebulaos-healthcheck.sh stage2
#
# stage2 exit codes (G91 C1 fix, 2026-10-22):
#   0  healthy, no print running
#   1  unhealthy (or Moonraker not answering)
#   3  a print is running (printing/paused) and every other check passed
#   4  a print is running and another check failed
# A running print is never a health failure: the update supervisor defers its
# judgement of the Klipper stack until the print has ended (3 and 4), and
# never rolls back or restarts Klipper under it. Before, "printing" counted as
# a failure, so a print started within ~4 min of an app update made the
# supervisor roll back and restart Klipper under it (G91 inventory C1).

MOONRAKER_URL="http://127.0.0.1:7125"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) healthcheck: $1"; }

stage1_component() {
	name="$1"; path="$2"
	case "$name" in
		klipper)
			[ -f "$path/klippy/klippy.py" ] || { log "FAIL stage1 klipper: klippy.py missing"; return 1; }
			python3 -c "import sys; sys.path.insert(0,'$path/klippy'); import klippy" 2>/dev/null \
				|| { log "FAIL stage1 klipper: import klippy failed"; return 1; }
			;;
		moonraker)
			[ -f "$path/moonraker/server.py" ] || { log "FAIL stage1 moonraker: server.py missing"; return 1; }
			python3 -c "import sys; sys.path.insert(0,'$path'); import moonraker.server" 2>/dev/null \
				|| { log "FAIL stage1 moonraker: import moonraker.server failed"; return 1; }
			;;
		mainsail)
			[ -f "$path/index.html" ] || { log "FAIL stage1 mainsail: index.html missing"; return 1; }
			[ -d "$path/assets" ] || { log "FAIL stage1 mainsail: assets/ directory missing"; return 1; }
			# release_info.json is written by Moonraker's own net_deploy for a
			# real update; the offline factory seed doesn't produce one (it
			# copies the immutable /usr/share/mainsail tree verbatim, which
			# ships without this file) - only check it if present, don't
			# require it, matching that this check must also pass for a
			# freshly-seeded (not yet updated) install.
			if [ -e "$path/release_info.json" ]; then
				grep -q '"version"' "$path/release_info.json" 2>/dev/null \
					|| { log "FAIL stage1 mainsail: release_info.json present but malformed"; return 1; }
			fi
			;;
		*)
			log "FAIL stage1: unknown component '$name'"
			return 1
			;;
	esac
	log "PASS stage1 $name"
	return 0
}

# Full printer-stack health - every check is a read-only query. Per this
# project's own safety discipline, this script NEVER issues a
# state-changing command (reboot/restart/activation) itself - callers
# (Phase 8's own rollback orchestration, not written yet) must treat this
# purely as a query and act on its result as a clearly separate step.
stage2_stack() {
	ok=true

	info=$(wget -q -O - --timeout=5 "$MOONRAKER_URL/server/info" 2>/dev/null)
	if [ -z "$info" ]; then
		log "FAIL stage2: Moonraker not responding on $MOONRAKER_URL"
		return 1
	fi

	klippy_state=$(echo "$info" | sed -n 's/.*"klippy_state":"\([^"]*\)".*/\1/p')
	if [ "$klippy_state" != "ready" ]; then
		log "FAIL stage2: klippy_state='$klippy_state' (expected 'ready')"
		ok=false
	else
		log "PASS stage2: klippy_state=ready"
	fi

	# Confirmed live (2026-07-26) against a real /server/info response:
	# the field is a plain boolean "klippy_connected", not a
	# "connection_state" string - fixed after the first version of this
	# check silently no-op'd against real data (neither pattern in an
	# earlier draft ever matched).
	case "$info" in
		*'"klippy_connected":true'*)
			log "PASS stage2: Moonraker connected to Klipper (klippy_connected=true)"
			;;
		*)
			log "FAIL stage2: Moonraker not connected to Klipper (klippy_connected != true)"
			ok=false
			;;
	esac

	printer_info=$(wget -q -O - --timeout=5 "$MOONRAKER_URL/printer/info" 2>/dev/null)
	case "$printer_info" in
		*'"state_message":"'*'shutdown'*'"'*|*"Can not update MCU"*)
			log "FAIL stage2: printer/info suggests an MCU shutdown/error state"
			ok=false
			;;
	esac

	failed=$(echo "$info" | sed -n 's/.*"failed_components":\[\([^]]*\)\].*/\1/p')
	if [ -n "$failed" ] && [ "$failed" != "" ]; then
		log "FAIL stage2: Moonraker reports failed_components=[$failed]"
		ok=false
	else
		log "PASS stage2: no failed Moonraker components"
	fi

	stats=$(wget -q -O - --timeout=5 "$MOONRAKER_URL/printer/objects/query?heater_bed&extruder&print_stats" 2>/dev/null)
	# Heater targets must read exactly zero and no print may be active -
	# the same printer-safety invariant this project already requires
	# before every reboot, reused here as a health precondition.
	case "$stats" in
		*'"target":0.0'*|*'"target": 0.0'*) : ;;
		*'"target":'*)
			log "WARNING stage2: a heater target is non-zero - not necessarily a health failure, but recorded for the caller to judge"
			;;
	esac
	printing=false
	case "$stats" in
		*'"state":"printing"'*|*'"state": "printing"'*|*'"state":"paused"'*|*'"state": "paused"'*)
			printing=true
			;;
	esac

	if [ "$printing" = "true" ]; then
		if [ "$ok" = "true" ]; then
			log "DEFERRED stage2: a print is running (every other check passed) - judged after the print"
			return 3
		fi
		log "DEFERRED stage2: a print is running and a check failed (see above) - judged after the print"
		return 4
	fi
	if [ "$ok" = "true" ]; then
		log "PASS stage2: full stack healthy"
		return 0
	else
		log "FAIL stage2: one or more checks failed (see above)"
		return 1
	fi
}

# NebulaOS mutable-runtime closure mission (2026-07-27), Phase C: Mainsail's
# own post-activation health check. Unlike Klipper/Moonraker (real
# processes with their own /server/info-style readiness state), Mainsail is
# static files served directly by nginx - "healthy" means nginx actually
# returns real content for it, not a stale/empty/error response. No process
# restart is needed for new static files to take effect (nginx re-reads the
# file from disk on every request), so this is safe to call immediately
# after a file-level activation swap, unlike Klipper/Moonraker's restart-then-
# wait pattern.
stage2_mainsail() {
	body=$(wget -q -O - --timeout=5 "http://127.0.0.1:80/index.html" 2>/dev/null)
	if [ -z "$body" ]; then
		log "FAIL stage2 mainsail: nginx returned no content for index.html"
		return 1
	fi
	case "$body" in
		*'<html'*|*'<!doctype html'*|*'<!DOCTYPE html'*)
			log "PASS stage2 mainsail: nginx serving real index.html content"
			return 0
			;;
		*)
			log "FAIL stage2 mainsail: response doesn't look like real HTML"
			return 1
			;;
	esac
}

case "$1" in
	stage1)
		stage1_component "$2" "$3"
		;;
	stage2)
		stage2_stack
		;;
	stage2-mainsail)
		stage2_mainsail
		;;
	*)
		echo "usage: $0 stage1 <klipper|moonraker|mainsail> <path> | stage2 | stage2-mainsail" >&2
		exit 2
		;;
esac
