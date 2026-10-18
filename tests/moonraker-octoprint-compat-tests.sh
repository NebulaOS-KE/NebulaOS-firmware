#!/bin/sh
# G84 (Run 13, 2026-10-18): [octoprint_compat] is on by default, from the
# image-owned include, so OctoPrint-style uploads (OrcaSlicer "Octo/Klipper")
# work at http://<printer> without editing moonraker.conf.
#
#   - nebulaos.conf has [octoprint_compat]; the include chain reaches it
#     (moonraker.conf -> klipper-pin.conf -> nebulaos.conf)
#   - the pinned Moonraker's own config parser accepts the composed config,
#     also when the user's moonraker.conf has its own [octoprint_compat]
#   - nginx on port 80 forwards /api to Moonraker
#
# Usage: sh tests/moonraker-octoprint-compat-tests.sh
set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OV="$ROOT/scripts/build/overlay"
NCONF="$OV/etc/nebulaos/moonraker/nebulaos.conf"
PIN="$OV/etc/nebulaos/moonraker/klipper-pin.conf"
MCONF="$OV/opt/printer_data/config/moonraker.conf"
NGINX="$OV/etc/nginx/nginx.conf"
MR="$ROOT/vendor/moonraker"
W=$(mktemp -d "${TMPDIR:-/tmp}/octocompat.XXXXXX")
[ -n "$W" ] && [ -d "$W" ] || { echo "FATAL: mktemp failed"; exit 1; }
trap 'rm -rf "$W"' EXIT INT TERM
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

grep -qx '\[octoprint_compat\]' "$NCONF" && pass || fail "nebulaos.conf has no [octoprint_compat]"
grep -qx '\[include /etc/nebulaos/moonraker/nebulaos.conf\]' "$PIN" && pass || fail "klipper-pin.conf does not include nebulaos.conf"
grep -qx '\[include /etc/nebulaos/moonraker/klipper-pin.conf\]' "$MCONF" && pass || fail "moonraker.conf does not include klipper-pin.conf"
grep -q 'location ~ \^/(printer|api|access|machine|server)/' "$NGINX" && pass || fail "nginx does not forward /api to Moonraker"

# The pinned Moonraker's parser on the composed config (absolute include
# paths redirected into a temp tree).
if [ -f "$MR/moonraker/confighelper.py" ]; then
	mkdir -p "$W/etc/nebulaos/moonraker" "$W/cfg"
	cp "$NCONF" "$PIN" "$W/etc/nebulaos/moonraker/"
	sed -i "s#/etc/nebulaos/moonraker/#$W/etc/nebulaos/moonraker/#" "$W/etc/nebulaos/moonraker/klipper-pin.conf"
	sed "s#/etc/nebulaos/moonraker/#$W/etc/nebulaos/moonraker/#" "$MCONF" > "$W/cfg/moonraker.conf"
	cp "$W/cfg/moonraker.conf" "$W/cfg/moonraker-user-octo.conf"
	printf '\n[octoprint_compat]\nenable_ufp: False\n' >> "$W/cfg/moonraker-user-octo.conf"
	for c in moonraker.conf moonraker-user-octo.conf; do
		out=$(cd "$MR" && python3 - "$W/cfg/$c" <<'PYEOF' 2>&1
import sys, importlib.metadata
sys.path.insert(0, ".")
# Moonraker's venv has the importlib_metadata backport; the stdlib module
# has the same API for what confighelper's imports need.
sys.modules.setdefault("importlib_metadata", importlib.metadata)
from moonraker import confighelper
# Moonraker's own file source: the same include/duplicate rules as at runtime.
class _Srv:
    def get_app_args(self): return {}
w = confighelper.FileSourceWrapper(_Srv())
w.read_file(__import__("pathlib").Path(sys.argv[1]))
cp = w.get_parser()
print("SECTIONS", " ".join(sorted(cp.sections())))
if cp.has_section("octoprint_compat"):
    print("ENABLE_UFP", cp.get("octoprint_compat", "enable_ufp", fallback="default"))
PYEOF
)
		case "$out" in
			*SECTIONS*octoprint_compat*) pass ;;
			*) fail "pinned Moonraker parser rejects $c"; echo "$out" | tail -5 ;;
		esac
		if [ "$c" = moonraker-user-octo.conf ]; then
			echo "$out" | grep -q '^ENABLE_UFP False' && pass || fail "a user's own [octoprint_compat] option is not honoured: $(echo "$out" | tail -2)"
		fi
	done
else
	echo "NOTE: vendor/moonraker not present - parser check skipped"
fi

echo "moonraker-octoprint-compat-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
