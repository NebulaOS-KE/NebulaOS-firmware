#!/bin/sh
# Early SSH and host keys when the data partition is missing or read-only
# (2026-10-15: ke-dev booted without /usr/data mounted read-write and could
# not be reached). The Hardware Agent pins the device's own host keys
# strictly, so every case that can present them must.
#   writable    -> persistent keys in place
#   read-only   -> persistent keys in place, nothing generated
#   not mounted -> keys copied from a read-only mount of the data partition
#   unreadable  -> boot-local keys generated (the old fallback)
# Plus the wiring: S02nebulaos-early-ssh runs after S01wifi and starts the same
# daemon with the same keys.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
INIT="$ROOT/scripts/build/overlay/etc/init.d"
S46="$INIT/S46nebulaos-dropbear-keys"
EARLY="$INIT/S02nebulaos-early-ssh"
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

W=$(mktemp -d "${TMPDIR:-/tmp}/early-ssh.XXXXXX") || exit 1
[ -n "$W" ] && [ -d "$W" ] || exit 1
trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
B="$W/bin"; mkdir -p "$B"
cat > "$B/dropbearkey" <<'EOF'
#!/bin/sh
# dropbearkey -t TYPE -f FILE
while [ $# -gt 0 ]; do [ "$1" = -f ] && { echo "generated" > "$2"; }; shift; done
echo "dropbearkey" >> "$CALLS"
EOF
cat > "$B/fmount" <<'EOF'
#!/bin/sh
echo "mount $*" >> "$CALLS"
[ -n "${MOUNT_FAILS:-}" ] && exit 32
for a; do last=$a; done
cp -a "$PARTITION/." "$last/"
EOF
cat > "$B/fumount" <<'EOF'
#!/bin/sh
echo "umount $*" >> "$CALLS"
rm -rf "$1"/*
EOF
chmod +x "$B"/*

run46() { # -> runs S46 start in a fresh layout
	(PATH="$B:$PATH"; CALLS="$W/calls"; export CALLS PATH
	 NEBULAOS_ROOT="$W/data/nebulaos" NEBULAOS_DROPBEAR_FALLBACK_DIR="$W/fallback" \
	 NEBULAOS_DROPBEAR_ENV_FILE="$W/dropbear.conf" NEBULAOS_KEYS_RO_MNT="$W/keys-ro" \
	 NEBULAOS_DROPBEAR_RUN_DIR="$W/run" \
	 NEBULAOS_MOUNT="$B/fmount" NEBULAOS_UMOUNT="$B/fumount" NEBULAOS_DATA_DEV=/dev/fake \
	 sh "$S46" start >/dev/null 2>&1)
}
reset() {
	chmod -R u+w "$W/data" 2>/dev/null
	rm -rf "$W/data" "$W/fallback" "$W/keys-ro" "$W/partition" "$W/dropbear.conf" "$W/calls" "$W/run"
	: > "$W/calls"
}
device_keys() { # dir
	mkdir -p "$1"
	echo device-rsa > "$1/dropbear_rsa_host_key"
	echo device-ed25519 > "$1/dropbear_ed25519_host_key"
}

# writable: persistent keys in place, untouched
reset; device_keys "$W/data/nebulaos/system/dropbear"; run46
grep -q "$W/run/dropbear_ed25519_host_key" "$W/dropbear.conf" 2>/dev/null \
	&& [ "$(cat "$W/data/nebulaos/system/dropbear/dropbear_rsa_host_key")" = device-rsa ] \
	&& [ "$(cat "$W/run/dropbear_rsa_host_key")" = device-rsa ] \
	&& ! grep -q dropbearkey "$W/calls" && pass || fail "writable: $(cat "$W/dropbear.conf" 2>&1)"
# G77: the key dropbear reads survives /usr/data going away mid-boot
rm -rf "$W/data/nebulaos/system/dropbear"
[ "$(cat "$W/run/dropbear_ed25519_host_key" 2>/dev/null)" = device-ed25519 ] && [ "$(stat -c %a "$W/run/dropbear_rsa_host_key")" = 600 ] \
	&& pass || fail "G77: RAM copy of the host key missing or wrong mode"

# read-only (as non-root: the directory is not writable): keys used in place
reset; device_keys "$W/data/nebulaos/system/dropbear"; chmod -R a-w "$W/data"; run46
if [ "$(id -u)" = 0 ]; then
	pass   # root writes anyway; this case is covered on the device
else
	grep -q "$W/run/dropbear_rsa_host_key" "$W/dropbear.conf" 2>/dev/null \
		&& ! grep -q dropbearkey "$W/calls" && ! grep -q '^mount' "$W/calls" && pass \
		|| fail "read-only: $(cat "$W/dropbear.conf" 2>&1) / $(cat "$W/calls")"
fi

# not mounted: copied from a read-only mount of the data partition
reset; mkdir -p "$W/data"; device_keys "$W/partition/nebulaos/system/dropbear"
(PARTITION="$W/partition"; export PARTITION; run46)
[ "$(cat "$W/fallback/dropbear_ed25519_host_key" 2>/dev/null)" = device-ed25519 ] \
	&& grep -q "$W/run/dropbear_rsa_host_key" "$W/dropbear.conf" \
	&& grep -q 'mount -t ext4 -o ro /dev/fake' "$W/calls" && grep -q '^umount' "$W/calls" \
	&& ! grep -q dropbearkey "$W/calls" && pass || fail "not mounted: $(cat "$W/calls")"
perm=$(stat -c %a "$W/fallback/dropbear_rsa_host_key" 2>/dev/null)
[ "$perm" = 600 ] && pass || fail "copied key mode is $perm, not 600"

# unreadable everywhere: the old boot-local fallback
reset; mkdir -p "$W/data"
(MOUNT_FAILS=1; export MOUNT_FAILS; run46)
[ "$(cat "$W/fallback/dropbear_rsa_host_key" 2>/dev/null)" = generated ] \
	&& grep -q "$W/run/dropbear_ed25519_host_key" "$W/dropbear.conf" && pass \
	|| fail "fallback: $(cat "$W/calls")"

# wiring
[ -x "$EARLY" ] && pass || fail "S02nebulaos-early-ssh missing or not executable"
first=$(cd "$INIT" && ls | grep -n -x -e S01wifi -e S02nebulaos-early-ssh -e S02nebulaos-namespace | cut -d: -f2 | tr '\n' ' ')
[ "$first" = "S01wifi S02nebulaos-early-ssh S02nebulaos-namespace " ] && pass || fail "order: $first"
grep -q 'S46nebulaos-dropbear-keys' "$EARLY" && grep -q 'S50dropbear' "$EARLY" && pass || fail "early ssh does not use the same keys and daemon"
# the early start runs both scripts with "start"
cat > "$B/k" <<EOF
#!/bin/sh
echo "keys \$1" >> "$W/calls"
EOF
cat > "$B/d" <<EOF
#!/bin/sh
echo "sshd \$1" >> "$W/calls"
EOF
chmod +x "$B/k" "$B/d"; : > "$W/calls"
NEBULAOS_EARLY_SSH_KEYS_INIT="$B/k" NEBULAOS_EARLY_SSH_INIT="$B/d" sh "$EARLY" start >/dev/null 2>&1
[ "$(cat "$W/calls" | tr '\n' ' ')" = "keys start sshd start " ] && pass || fail "early start: $(cat "$W/calls")"

echo "early-ssh-keys-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
