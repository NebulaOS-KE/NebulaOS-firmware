#!/bin/sh
# /usr/libexec/nebulaos-nebula-camera (camera.cfg's Nebula Camera macros,
# Run 23): each macro value maps to exactly one nebulaos-osconfig camera call,
# anything else is refused before osconfig runs, and the console line says
# what happened.
set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 2
HELPER="$SCRIPT_DIR/../scripts/build/overlay/usr/libexec/nebulaos-nebula-camera"
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

cat > "$T/osconfig" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS"
case "$2" in
  reset) echo '{"ok": false, "error": "PRINTING", "message": "a print is running", "refused": true}'; exit 3 ;;
  *)     echo '{"ok": true, "result": "APPLIED", "config": {}}' ;;
esac
FAKE
chmod +x "$T/osconfig"
export NEBULAOS_OSCONFIG="$T/osconfig" CALLS="$T/calls"

expect() {  # args... -> wanted osconfig call, wanted output fragment, wanted rc
	want_call=$1 want_out=$2 want_rc=$3; shift 3
	: > "$CALLS"
	out=$(sh "$HELPER" "$@"); rc=$?
	call=$(cat "$CALLS")
	[ "$call" = "$want_call" ] && ok || bad "$*: osconfig got '$call', wanted '$want_call'"
	case "$out" in *"$want_out"*) ok ;; *) bad "$*: output '$out' lacks '$want_out'" ;; esac
	[ "$rc" = "$want_rc" ] && ok || bad "$*: rc $rc, wanted $want_rc"
}
expect 'camera set --json {"ir_mode": "color"}' 'Nebula Camera: done' 0 night COLOR
expect 'camera set --json {"ir_mode": "bw"}' 'done' 0 night bw
expect 'camera set --json {"ir_mode": "auto"}' 'done' 0 night auto
expect 'camera set --json {"power_line": "50"}' 'done' 0 flicker 50
expect 'camera set --json {"power_line": "off"}' 'done' 0 flicker OFF
expect 'camera defaults' 'done' 0 defaults
expect 'camera reset' 'not changed - a print is running' 3 reset
expect '' 'unknown setting' 1 night purple
expect '' 'unknown setting' 1 flicker '50; reboot'
expect '' 'unknown setting' 1 reboot

echo "nebula-camera-macro-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
