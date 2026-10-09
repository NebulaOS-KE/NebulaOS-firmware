#!/bin/sh
#
# Offline tests for /etc/nebulaos-network.sh, nebulaos-netapply and their use
# in S01wifi (GUI/service readiness mission, 2026-10-09). No real interface,
# ifupdown or arping: those are fakes that record their argv. Proven: the
# boot.env re-validation (any doubt -> DHCP), the generated stanza, the static
# fallback, and the live apply/verify exit codes.
#
# Usage: sh tests/nebulaos-network-boot-tests.sh

set -u
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY="$REPO_ROOT/scripts/build/overlay"
LIB="$OVERLAY/etc/nebulaos-network.sh"
NETAPPLY="$OVERLAY/usr/libexec/nebulaos/nebulaos-netapply"
S01WIFI="$OVERLAY/etc/init.d/S01wifi"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
check() { if eval "$2"; then pass; else fail "$1"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/nnet-tests.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

setup() {
	rm -rf "$T/w"; mkdir -p "$T/w/bin"
	export NNET_ENV="$T/w/boot.env" NNET_RUN_DIR="$T/w/run"
	export NNET_IFACES="$T/w/run/interfaces" NNET_STATE="$T/w/run/boot-state"
	export NNET_RESOLV="$T/w/resolv.conf"
	for tool in hostname ifup ifdown; do
		printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit ${FAKE_%s_RC:-0}\n' "$tool" "$T/w/log" "$tool" > "$T/w/bin/$tool"
		chmod 755 "$T/w/bin/$tool"
	done
	printf '#!/bin/sh\necho "arping $*" >> "%s"\nexit ${FAKE_arping_RC:-0}\n' "$T/w/log" > "$T/w/bin/arping"
	chmod 755 "$T/w/bin/arping"
	printf '#!/bin/sh\n[ -n "${FAKE_NO_LEASE:-}" ] || echo "3: wlan0 inet 192.168.1.77/24"\n' > "$T/w/bin/ip"
	chmod 755 "$T/w/bin/ip"
	export NNET_IP="$T/w/bin/ip"
	export NNET_HOSTNAME_CMD="$T/w/bin/hostname" NNET_IFUP="$T/w/bin/ifup"
	export NNET_IFDOWN="$T/w/bin/ifdown" NNET_ARPING="$T/w/bin/arping"
	: > "$T/w/log"
}

env_static() {
	cat > "$NNET_ENV" <<-EOF
	NNET_HOSTNAME="ke-shop"
	NNET_MODE="static"
	NNET_ADDRESS="192.168.1.50"
	NNET_NETMASK="255.255.255.0"
	NNET_GATEWAY="192.168.1.1"
	NNET_DNS="192.168.1.1 1.1.1.1"
	EOF
}

# --- validators ------------------------------------------------------------
( . "$LIB"
  for h in a ke-shop x1 abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij123; do
	nnet_valid_hostname "$h" || { echo "valid hostname rejected: $h"; exit 1; }
  done
  for h in "" -a a- A_b a.b 123 "a b" 'a;b' "$(printf 'x%.0s' $(seq 64))"; do
	nnet_valid_hostname "$h" && { echo "invalid hostname accepted: $h"; exit 1; }
  done
  for a in 0.0.0.0 1.2.3.4 255.255.255.255 10.0.0.1; do
	nnet_valid_ipv4 "$a" || { echo "valid ip rejected: $a"; exit 1; }
  done
  for a in 1.2.3 1.2.3.4.5 256.1.1.1 01.2.3.4 1..2.3 .1.2.3 1.2.3.4. "1.2.3.4 " 'a.b.c.d' '1.2.3.4;x'; do
	nnet_valid_ipv4 "$a" && { echo "invalid ip accepted: $a"; exit 1; }
  done
  exit 0 ); rc=$?
check "hostname/IPv4 validators" '[ $rc -eq 0 ]'

# --- boot prepare --------------------------------------------------------------
setup
( . "$LIB"; nnet_boot_prepare ); rc=$?
check "no env: DHCP stanza ready" '[ $rc -eq 0 ] && grep -qx "iface wlan0 inet dhcp" "$NNET_IFACES"'
check "no env: default hostname nebulaos set and sent in DHCP" 'grep -qx "hostname nebulaos" "$T/w/log" && grep -qx "  hostname nebulaos" "$NNET_IFACES"'
check "no env: wait-delay kept" 'grep -qx "  wait-delay 15" "$NNET_IFACES"'
check "no env: state DHCP" '[ "$(cat "$NNET_STATE")" = DHCP ]'
check "lo stanza present" 'grep -qx "iface lo inet loopback" "$NNET_IFACES"'

setup; env_static
( . "$LIB"; nnet_boot_prepare )
check "static stanza" 'grep -qx "iface wlan0 inet static" "$NNET_IFACES" && grep -qx "  address 192.168.1.50" "$NNET_IFACES" && grep -qx "  gateway 192.168.1.1" "$NNET_IFACES"'
check "static resolv.conf" '[ "$(grep -c "^nameserver" "$NNET_RESOLV")" = 2 ]'
check "static state pending" '[ "$(cat "$NNET_STATE")" = STATIC_PENDING ]'
check "static hostname" 'grep -qx "hostname ke-shop" "$T/w/log"'

for bad in 'NNET_MODE="static"|NNET_ADDRESS="1.2.3"' 'NNET_MODE="static"|NNET_GATEWAY="$(reboot)"' \
           'NNET_MODE="bridge"' 'NNET_HOSTNAME="Bad_Name"' 'NNET_DNS="1.1.1.1 2.2.2.2 3.3.3.3 4.4.4.4"' \
           'NNET_DNS="1.1.1.1;reboot"'; do
	setup; env_static
	printf '%s\n' "$bad" | tr '|' '\n' >> "$NNET_ENV"
	( . "$LIB"; nnet_boot_prepare )
	check "invalid env ($bad) falls back to DHCP default" 'grep -qx "iface wlan0 inet dhcp" "$NNET_IFACES" && grep -qx "hostname nebulaos" "$T/w/log"'
done

setup; printf 'garbage\n\0\001\n' > "$NNET_ENV"
( . "$LIB"; nnet_boot_prepare )
check "garbage env: DHCP" 'grep -qx "iface wlan0 inet dhcp" "$NNET_IFACES"'

setup; mkdir -p "$T/w/ro"; chmod 500 "$T/w/ro"; export NNET_RUN_DIR="$T/w/ro/x" NNET_IFACES="$T/w/ro/x/interfaces"
( . "$LIB"; nnet_boot_prepare ); rc=$?
check "unwritable run dir: returns 1 (S01wifi uses stock interfaces)" '[ $rc -eq 1 ]'
chmod 700 "$T/w/ro"

# --- static probe ------------------------------------------------------------------
setup; env_static
( . "$LIB"; NNET_PROBE_SECONDS=3; nnet_boot_prepare; nnet_static_probe ); rc=$?
check "gateway answers: STATIC" '[ $rc -eq 0 ] && [ "$(cat "$NNET_STATE")" = STATIC ]'
setup; env_static
( . "$LIB"; NNET_PROBE_SECONDS=3; nnet_boot_prepare; FAKE_arping_RC=1; export FAKE_arping_RC; nnet_static_probe ); rc=$?
check "gateway silent: fallback" '[ $rc -eq 1 ] && [ "$(cat "$NNET_STATE")" = STATIC_FALLBACK_DHCP ]'
check "fallback re-ups DHCP" 'grep -qx "iface wlan0 inet dhcp" "$NNET_IFACES" && grep -q "^ifup -i $NNET_IFACES wlan0" "$T/w/log"'
check "probe bounded" '[ "$(grep -c "^arping" "$T/w/log")" = 3 ]'
check "persisted choice untouched" 'grep -q "NNET_MODE=\"static\"" "$NNET_ENV"'

# --- netapply --------------------------------------------------------------------
setup; env_static
NNET_LIB="$LIB" NNET_VERIFY_SECONDS=2 sh "$NETAPPLY" apply; rc=$?
check "netapply static verified: 0" '[ $rc -eq 0 ] && [ "$(cat "$NNET_STATE")" = STATIC ]'
check "netapply never touches wpa_supplicant" '! grep -q wpa "$T/w/log"'
setup; env_static
FAKE_arping_RC=1 NNET_LIB="$LIB" NNET_VERIFY_SECONDS=2 sh "$NETAPPLY" apply; rc=$?
check "netapply silent gateway: 4" '[ $rc -eq 4 ]'
setup
FAKE_ifup_RC=1 NNET_LIB="$LIB" sh "$NETAPPLY" apply; rc=$?
check "netapply ifup failure: 3" '[ $rc -eq 3 ]'
setup
NNET_LIB="$LIB" sh "$NETAPPLY" apply; rc=$?
check "netapply dhcp with a lease: 0" '[ $rc -eq 0 ] && [ "$(cat "$NNET_STATE")" = DHCP ]'
setup
FAKE_NO_LEASE=1 NNET_VERIFY_DHCP_TENTHS=10 NNET_LIB="$LIB" sh "$NETAPPLY" apply; rc=$?
check "netapply dhcp without a lease (udhcpc -b) is a failure: 3" '[ $rc -eq 3 ] && [ "$(cat "$NNET_STATE")" = APPLY_DHCP_NO_LEASE ]'
setup; env_static; mkdir -p "$NNET_RUN_DIR"; echo STATIC_FALLBACK_DHCP > "$NNET_STATE"
NNET_LIB="$LIB" sh "$NETAPPLY" hostname; rc=$?
check "hostname verb keeps the live DHCP fallback stanza and does not bounce" '[ $rc -eq 0 ] && grep -qx "iface wlan0 inet dhcp" "$NNET_IFACES" && ! grep -q "^if" "$T/w/log"'
NNET_LIB="$LIB" sh "$NETAPPLY" nope; rc=$?
check "netapply usage 64" '[ $rc -eq 64 ]'

# --- S01wifi wiring ---------------------------------------------------------------
check "S01wifi sources the network lib" 'grep -q "nnet_boot_prepare && NNET_READY=1" "$S01WIFI"'
check "S01wifi ifup -i generated file" 'grep -q "/sbin/ifup -i \"\$NNET_IFACES\" wlan0" "$S01WIFI"'
check "S01wifi falls back to stock ifup" 'grep -q "^		/sbin/ifup wlan0 2>/dev/null" "$S01WIFI"'
check "S01wifi probes static in background" 'grep -q "nnet_static_probe >/dev/null 2>&1 &" "$S01WIFI"'
check "stock interfaces file still DHCP" 'grep -qx "iface wlan0 inet dhcp" "$OVERLAY/etc/network/interfaces"'

echo "nebulaos-network-boot-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
