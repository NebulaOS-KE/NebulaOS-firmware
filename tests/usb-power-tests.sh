#!/bin/sh
#
# Offline tests for #27 test build 7: S05nebulaos-usb-power drives PC10
# (USB_P_EN2) as an output high. Runs against a fake devmem that models the
# Ingenic GPIO set/clear registers of port C.
#
# Usage: sh tests/usb-power-tests.sh

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
S05="$REPO_ROOT/scripts/build/overlay/etc/init.d/S05nebulaos-usb-power"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/usb-power-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
expect() { [ "$2" = "$3" ] && pass "$1" || fail "$1 (got '$2', want '$3')"; }

# fake devmem: base registers INT(0x10) MSK(0x20) PAT1(0x30) PAT0(0x40);
# +4 = set, +8 = clear. Logs every write. Reads print upper-case hex.
cat > "$WORK/devmem" <<'DM'
#!/bin/sh
[ -n "${FAKE_DEVMEM_FAIL:-}" ] && exit 1
d=$(dirname "$0")/mem
a=$(( $1 ))
off=$(( a - 0x10010200 ))
base=$(( off & ~0xf )); op=$(( off & 0xf ))
f="$d/$base"
if [ $# -ge 3 ]; then
	echo "$off" >> "$(dirname "$0")/writes"
	v=$(cat "$f"); w=$(( $3 ))
	case $op in
	4) v=$(( v | w )) ;;
	8) v=$(( v & ~w )) ;;
	*) v=$w ;;
	esac
	echo $v > "$f"
	# a low glitch: output mode with PAT0 = 0 at any point
	pin=$(( 1 << 10 ))
	i=$(cat "$d/16"); m=$(cat "$d/32"); p1=$(cat "$d/48"); p0=$(cat "$d/64")
	[ $(( i & pin )) = 0 ] && [ $(( m & pin )) != 0 ] && [ $(( p1 & pin )) = 0 ] && [ $(( p0 & pin )) = 0 ] \
		&& echo glitch >> "$(dirname "$0")/glitch"
	exit 0
else
	printf '0x%08X\n' "$(cat "$f")"
fi
DM
chmod +x "$WORK/devmem"

fake_mem() { # int msk pat1 pat0 (as found on ke-dev: PC10 input pulled up)
	rm -rf "$WORK/mem" "$WORK/writes" "$WORK/glitch"; mkdir -p "$WORK/mem"
	echo $(( $1 )) > "$WORK/mem/16"; echo $(( $2 )) > "$WORK/mem/32"
	echo $(( $3 )) > "$WORK/mem/48"; echo $(( $4 )) > "$WORK/mem/64"
}
run() {
	UP_DEVMEM="$WORK/devmem" UP_KMSG="$WORK/kmsg" UP_STATE="$WORK/run/usb-power" sh "$S05" start > "$WORK/out"
}
bit10() { echo $(( ($(cat "$WORK/mem/$1") >> 10) & 1 )); }

sh -n "$S05" && pass "S05 parses" || fail "S05 does not parse"
[ -x "$S05" ] && pass "S05 is executable" || fail "S05 is not executable"

# ke-dev live values 2026-11-24
fake_mem 0x00000000 0x1870FFF5 0x1810FDF4 0x07C00200
run
expect "PC10 PAT1 cleared (output)" "$(bit10 48)" 0
expect "PC10 PAT0 set (high)" "$(bit10 64)" 1
expect "PC10 MSK set (gpio)" "$(bit10 32)" 1
expect "PC10 INT clear" "$(bit10 16)" 0
expect "PC09 untouched (still output high)" "$(( ($(cat "$WORK/mem/48") >> 9) & 1 ))$(( ($(cat "$WORK/mem/64") >> 9) & 1 ))" 01
expect "other pins of port C untouched" "$(( $(cat "$WORK/mem/48") | 0x400 ))" "$(( 0x1810FDF4 ))"
[ -e "$WORK/glitch" ] && fail "pin went low on the way" || pass "no low glitch"
expect "PAT0 set before PAT1 cleared" "$(grep -n -e '^68$' -e '^56$' "$WORK/writes" | cut -d: -f2 | tr '\n' ' ')" "68 56 "
expect "state file" "$(cat "$WORK/run/usb-power")" "usb_p_en2=output-high ok"
expect "kernel log line" "$(cat "$WORK/kmsg")" "nebulaos-usb-power: usb_p_en2(PC10)=output-high ok"

# already output high (second run): stays so
run
expect "idempotent" "$(cat "$WORK/run/usb-power")" "usb_p_en2=output-high ok"

# devmem missing or failing: error logged, boot goes on
fake_mem 0x00000000 0x1870FFF5 0x1810FDF4 0x07C00200
FAKE_DEVMEM_FAIL=1 run; rc=$?
expect "devmem fails: exit 0" "$rc" 0
expect "devmem fails: error in log" "$(cat "$WORK/kmsg")" "nebulaos-usb-power: usb_p_en2(PC10)=? error"

echo
echo "usb-power: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
