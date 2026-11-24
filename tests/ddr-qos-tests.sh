#!/bin/sh
#
# Offline tests for S06nebulaos-ddr-qos (#27, 1.0.5): the stock DDR port
# settings written at every boot, and the test builds' switch settings file
# removed. Runs against a fake devmem.
#
# Usage: sh tests/ddr-qos-tests.sh

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
S06="$REPO_ROOT/scripts/build/overlay/etc/init.d/S06nebulaos-ddr-qos"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ddr-qos-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
expect() { [ "$2" = "$3" ] && pass "$1" || fail "$1 (got '$2', want '$3')"; }

# fake devmem: one file per address; reads print upper-case hex like BusyBox.
cat > "$WORK/devmem" <<'DM'
#!/bin/sh
[ -n "${FAKE_DEVMEM_FAIL:-}" ] && exit 1
f="$(dirname "$0")/mem/$(printf '%x' $(( $1 )))"
if [ $# -ge 3 ]; then
	[ -n "${FAKE_DEVMEM_IGNORE_WRITES:-}" ] && exit 0
	printf '%d\n' $(( $3 )) > "$f"
	exit 0
fi
printf '0x%08X\n' "$(cat "$f")"
DM
chmod +x "$WORK/devmem"

fresh() {
	rm -rf "$WORK/mem" "$WORK/run" "$WORK/kmsg" "$WORK/settings"
	mkdir -p "$WORK/mem"
	printf '%d\n' $(( 0x88404000 )) > "$WORK/mem/13012038"
	printf '%d\n' $(( 0x88404000 )) > "$WORK/mem/1301202c"
}
run() {
	DQ_DEVMEM="$WORK/devmem" DQ_KMSG="$WORK/kmsg" DQ_STATE="$WORK/run/ddr-qos" \
		DQ_OLD_SETTINGS="$WORK/settings" sh "$S06" start > "$WORK/out"
}
hex() { printf '0x%08x' "$(cat "$WORK/mem/$1")"; }

sh -n "$S06" && pass "S06 parses" || fail "S06 does not parse"
[ -x "$S06" ] && pass "S06 is executable" || fail "S06 is not executable"
[ ! -e "$REPO_ROOT/scripts/build/overlay/etc/init.d/S06nebulaos-freeze-switches" ] \
	&& pass "test-build switch script gone" || fail "S06nebulaos-freeze-switches still in the overlay"

# boot from the bootloader values
fresh
run; rc=$?
expect "exit 0" "$rc" 0
expect "CPU port CCHC6 = stock" "$(hex 13012038)" 0x884040c0
expect "DPU port CCHC3 = stock" "$(hex 1301202c)" 0x88404001
expect "state file" "$(cat "$WORK/run/ddr-qos")" "ddr_qos=stock cpu=0x884040c0 dpu=0x88404001 ok"
expect "kernel log line" "$(cat "$WORK/kmsg")" "nebulaos-ddr-qos: ddr_qos=stock ok"

# second run: same result
run
expect "idempotent" "$(cat "$WORK/run/ddr-qos")" "ddr_qos=stock cpu=0x884040c0 dpu=0x88404001 ok"

# a test build's settings file is removed, whatever it says
fresh
printf 'ddr_qos=default\nfb_cca=0\n' > "$WORK/settings"
run
[ -e "$WORK/settings" ] && fail "old settings file still there" || pass "old settings file removed"
expect "values stock even with ddr_qos=default in the old file" "$(hex 13012038) $(hex 1301202c)" "0x884040c0 0x88404001"
expect "kernel log says it was removed" "$(cat "$WORK/kmsg")" \
	"nebulaos-ddr-qos: ddr_qos=stock ok (test-build switch settings removed)"

# write does not stick: error, boot goes on
fresh
FAKE_DEVMEM_IGNORE_WRITES=1 run; rc=$?
expect "write ignored: exit 0" "$rc" 0
expect "write ignored: error" "$(cat "$WORK/kmsg")" "nebulaos-ddr-qos: ddr_qos=? error"

# devmem fails entirely: error, boot goes on
fresh
FAKE_DEVMEM_FAIL=1 run; rc=$?
expect "devmem fails: exit 0" "$rc" 0
expect "devmem fails: state" "$(cat "$WORK/run/ddr-qos")" "ddr_qos=? cpu=? dpu=? error"

echo
echo "ddr-qos: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
