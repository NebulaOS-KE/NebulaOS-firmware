#!/bin/sh
# G82 stage 4: [update_manager nebulascreen] (type: zip) - image-owned,
# consistent with S58, the shim, moonraker.asvc and the update supervisor,
# and ACTIVE since Run 19 (2026-10-24): the screen repository is renamed and
# has a stable release, so nebulaos.conf includes it (it was dormant before).
#
#   - the section's options, and that "repo" is the owner/project every
#     release_info.json names (Moonraker queries that one for a valid install)
#   - path == S58's and the supervisor's app dir; managed_services is a
#     service the supervisorctl shim maps onto S58nebulascreen, with S58's
#     pidfile, and S56 allows it in moonraker.asvc
#   - active: exactly one include (in nebulaos.conf), no commented-out copy,
#     no second [update_manager nebulascreen|guppyscreen] in the chain
#   - the pinned Moonraker facts the activation rests on are still true
#   - the pinned Moonraker's parser accepts the shipped chain as it is
#
# Usage: sh tests/moonraker-nebulascreen-update-config-tests.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OV="$ROOT/scripts/build/overlay"
UCONF="$OV/etc/nebulaos/moonraker/nebulascreen-update.conf"
NCONF="$OV/etc/nebulaos/moonraker/nebulaos.conf"
PIN="$OV/etc/nebulaos/moonraker/klipper-pin.conf"
MCONF="$OV/opt/printer_data/config/moonraker.conf"
S58="$OV/etc/init.d/S58nebulascreen"
SUP="$OV/etc/nebulaos-update-supervisor.sh"
CHECK="$OV/usr/libexec/nebulaos/nebulascreen-release-check"
MR="$ROOT/vendor/moonraker"
W=$(mktemp -d "${TMPDIR:-/tmp}/ns-update-config.XXXXXX")
[ -n "$W" ] && [ -d "$W" ] || { echo "FATAL: mktemp failed"; exit 1; }
trap 'rm -rf "$W"' EXIT INT TERM
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
t() { if eval "$2"; then pass; else fail "$1"; fi; }

opts=$(python3 -I - "$UCONF" <<'EOF'
import configparser, sys
cp = configparser.ConfigParser()
cp.read(sys.argv[1])
print(" ".join(cp.sections()))
for k, v in sorted(cp["update_manager nebulascreen"].items()):
    print("%s=%s" % (k, v))
EOF
)
t "the file holds exactly [update_manager nebulascreen]" \
	'[ "$(echo "$opts" | head -1)" = "update_manager nebulascreen" ]'
t "options: type zip, channel stable, path, managed_services" \
	'[ "$(echo "$opts" | tail -n +2 | tr "\n" " ")" = "channel=stable managed_services=nebulascreen path=/usr/data/nebulaos/apps/nebulascreen repo=NebulaOS-KE/NebulaOS-nebulascreen type=zip " ]'
owner=$(sed -n 's/^PROJECT_OWNER = "\(.*\)"/\1/p' "$CHECK")
project=$(sed -n 's/^PROJECT_NAME = "\(.*\)"/\1/p' "$CHECK")
t "repo is the owner/project every release_info.json names" \
	'echo "$opts" | grep -qx "repo=$owner/$project"'
t "path is S58's app dir" 'grep -qx "NS_APP=/usr/data/nebulaos/apps/nebulascreen" "$S58"'
t "path is the supervisor's app dir" \
	'grep -q "NS_APP_DIR=\"\${NS_APP_DIR:-\$NEBULAOS_ROOT/apps/nebulascreen}\"" "$SUP" && grep -q "NEBULAOS_ROOT=\"\${NEBULAOS_ROOT:-/usr/data/nebulaos}\"" "$SUP"'
t "the shim maps service nebulascreen onto S58nebulascreen" \
	'[ -f "$OV/etc/init.d/S58nebulascreen" ] && grep -q "S\[0-9\]\[0-9\]\${service}" "$OV/usr/bin/supervisorctl"'
t "the shim's pidfile is S58's" \
	'grep -q "pid_file=\"/var/run/\$service.pid\"" "$OV/usr/bin/supervisorctl" && grep -qx "PIDFILE=/var/run/nebulascreen.pid" "$S58"'
t "S56 allows nebulascreen in moonraker.asvc" \
	'grep -q "allow_moonraker_service \"\$DATAPATH\" nebulascreen" "$OV/etc/init.d/S56moonraker"'
t "S58 restart = stop (unbind) + start (approved-only bind)" \
	'grep -A3 "^	restart)" "$S58" | grep -q stop && grep -q "ns_activate \"\$NS_APP\" \"\$NS_DIR\" \"\$NS_UPDATE_STATE\"" "$S58"'

# Active (G82 stage 4, Run 19): the include is live exactly once, in the
# image-owned nebulaos.conf - never in the user-owned moonraker.conf.
t "nebulaos.conf includes it (active, exactly once)" \
	'[ "$(grep -cx "\[include /etc/nebulaos/moonraker/nebulascreen-update.conf\]" "$NCONF")" = 1 ]'
t "no commented-out copy of the include is left behind" \
	'! grep -qE "^#.*\[include /etc/nebulaos/moonraker/nebulascreen-update.conf\]" "$NCONF"'
t "the include is nowhere else in the chain (user-owned moonraker.conf, klipper-pin.conf)" \
	'! grep -hx "\[include /etc/nebulaos/moonraker/nebulascreen-update.conf\]" "$PIN" "$MCONF" | grep -q .'
t "no other [update_manager nebulascreen|guppyscreen] in the chain" \
	'! grep -hEx "\[update_manager (nebulascreen|guppyscreen)\]" "$NCONF" "$PIN" "$MCONF" | grep -q .'
t "klipper-pin.conf includes nebulaos.conf (so the section reaches every device)" \
	'grep -qx "\[include /etc/nebulaos/moonraker/nebulaos.conf\]" "$PIN"'
t "the update supervisor sees the include as active (nebulascreen refresh on)" \
	'grep -q "NS_MOONRAKER_INCLUDE:-/etc/nebulaos/moonraker/nebulaos.conf" "$SUP" && grep -q "grep -qx .\\\\\[include /etc/nebulaos/moonraker/nebulascreen-update.conf\\\\\]." "$SUP"'

if [ -d "$MR/moonraker/components/update_manager" ]; then
	UM="$MR/moonraker/components/update_manager"
	t "pinned Moonraker: no release -> update() raises" \
		'grep -q "Unable to locate update" "$UM/net_deploy.py"'
	t "pinned Moonraker: the full update stops at the first failing client" \
		'sed -n "/def _handle_full_update_request/,/def _handle_status_request/p" "$UM/update_manager.py" | grep -q "await updater.update()"'
	t "pinned Moonraker: a valid zip install queries release_info's repo" \
		'grep -q "self.repo = detected_repo" "$UM/net_deploy.py"'
	t "pinned Moonraker: refresh errors stay per component" \
		'sed -n "/    async def refresh(self) -> None:/,/_save_state/p" "$UM/net_deploy.py" | grep -q "except Exception"'
	t "pinned Moonraker: type zip may manage its own service" \
		'grep -q "svc_choices = \[self.name, \"klipper\", \"moonraker\"\]" "$UM/app_deploy.py"'

	# The parser on the shipped chain (absolute paths redirected into a
	# temp tree).
	mkdir -p "$W/etc/nebulaos/moonraker" "$W/cfg"
	cp "$NCONF" "$PIN" "$UCONF" "$W/etc/nebulaos/moonraker/"
	sed -i "s#/etc/nebulaos/moonraker/#$W/etc/nebulaos/moonraker/#" \
		"$W/etc/nebulaos/moonraker/klipper-pin.conf" "$W/etc/nebulaos/moonraker/nebulaos.conf"
	sed "s#/etc/nebulaos/moonraker/#$W/etc/nebulaos/moonraker/#" "$MCONF" > "$W/cfg/moonraker.conf"
	out=$(cd "$MR" && python3 - "$W/cfg/moonraker.conf" <<'PYEOF' 2>&1
import sys, importlib.metadata
sys.path.insert(0, ".")
sys.modules.setdefault("importlib_metadata", importlib.metadata)
from moonraker import confighelper
class _Srv:
    def get_app_args(self): return {}
w = confighelper.FileSourceWrapper(_Srv())
w.read_file(__import__("pathlib").Path(sys.argv[1]))
cp = w.get_parser()
print("SECTIONS", "|".join(sorted(cp.sections())))
print("TYPE", cp.get("update_manager nebulascreen", "type"))
PYEOF
)
	t "pinned Moonraker parses the shipped chain with the section active" \
		'echo "$out" | grep -q "^TYPE zip$" && echo "$out" | grep -q "update_manager mainsail"'
	[ "$FAIL" -eq 0 ] || echo "$out" | tail -5
else
	echo "NOTE: vendor/moonraker not present - pinned-Moonraker checks skipped"
fi

echo "moonraker-nebulascreen-update-config-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
