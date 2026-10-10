#!/bin/sh
#
# Offline tests for the persistent root password (decision D7, 2026-10-10):
# /etc/nebulaos-shadow.sh, nebulaos-passwd and the passwd wrapper. Fake mount
# and mkpasswd; no real /etc/shadow is touched.
#
# Usage: sh tests/nebulaos-shadow-tests.sh

set -u
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY="$REPO_ROOT/scripts/build/overlay"
LIB="$OVERLAY/etc/nebulaos-shadow.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
check() { if eval "$2"; then pass; else fail "$1"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/nsh-tests.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

setup() {
	rm -rf "$T/w"; mkdir -p "$T/w/bin" "$T/w/etc"
	printf 'root:$5$NebulaOSrootsalt$DEFAULT:19000:0:99999:7:::\ndaemon:*:10933:0:99999:7:::\n' > "$T/w/etc/shadow"
	chmod 600 "$T/w/etc/shadow"
	printf '#!/bin/sh\necho "mount $*" >> "%s"\n' "$T/w/log" > "$T/w/bin/mount"
	# fake BusyBox mkpasswd: "-m sha256", password on stdin
	printf '#!/bin/sh\n[ "$1 $2" = "-m sha256" ] || exit 1\nread -r p\necho "\\$5\\$salt\\$hash-of-$p"\n' > "$T/w/bin/mkpasswd"
	chmod 755 "$T/w/bin/mount" "$T/w/bin/mkpasswd"
	echo "/dev/root / squashfs ro 0 0" > "$T/w/mounts"
	export NSH_IMAGE="$T/w/etc/shadow" NSH_FILE="$T/w/data/system/shadow" NSH_MOUNTS="$T/w/mounts"
	export NSH_MOUNT_CMD="$T/w/bin/mount" NSH_MKPASSWD="$T/w/bin/mkpasswd"
	: > "$T/w/log"
}

# --- boot ---------------------------------------------------------------------
setup; ( . "$LIB"; nsh_boot ) >/dev/null
check "boot: seeds the persistent copy from the image" 'cmp -s "$NSH_IMAGE" "$NSH_FILE"'
check "boot: persistent copy is mode 600" '[ "$(stat -c %a "$NSH_FILE")" = 600 ]'
check "boot: binds it over /etc/shadow" 'grep -qx "mount --bind $NSH_FILE $NSH_IMAGE" "$T/w/log"'

setup; mkdir -p "$(dirname "$NSH_FILE")"; printf 'root:$5$user$CHANGED:1:0:99999:7:::\n' > "$NSH_FILE"
( . "$LIB"; nsh_boot ) >/dev/null
check "boot: an existing (changed) password is never re-seeded" 'grep -q CHANGED "$NSH_FILE"'

setup; echo "$NSH_FILE $NSH_IMAGE ext4 rw 0 0" > "$T/w/mounts"; ( . "$LIB"; nsh_boot ) >/dev/null
check "boot: not bound twice" '! grep -q "^mount" "$T/w/log"'

setup; mkdir -p "$(dirname "$NSH_FILE")"; printf 'daemon:*:1:0:99999:7:::\n' > "$NSH_FILE"
( . "$LIB"; nsh_boot ) >/dev/null
check "boot: a copy without a root entry is not bound (default password stays)" '! grep -q "^mount" "$T/w/log"'

# --- password change ----------------------------------------------------------
setup; ( . "$LIB"; nsh_boot ) >/dev/null
ino=$(ls -i "$NSH_FILE" | cut -d" " -f1)
echo "s3cret" | ( . "$LIB"; nsh_set_root_password ) >/dev/null; rc=$?
check "change: rc 0" '[ $rc -eq 0 ]'
check "change: root hash replaced" 'grep -q "^root:\$5\$salt\$hash-of-s3cret:19000:" "$NSH_FILE"'
check "change: other accounts untouched" 'grep -qx "daemon:\*:10933:0:99999:7:::" "$NSH_FILE"'
check "change: rewritten in place (same inode, bind mount sees it)" '[ "$(ls -i "$NSH_FILE" | cut -d" " -f1)" = "$ino" ]'
check "change: previous file kept" 'grep -q DEFAULT "$NSH_FILE.prev"'
check "change: still mode 600" '[ "$(stat -c %a "$NSH_FILE")" = 600 ]'
check "change: image file untouched" 'grep -q DEFAULT "$NSH_IMAGE"'

setup; ( . "$LIB"; nsh_boot ) >/dev/null
echo "" | ( . "$LIB"; nsh_set_root_password ) >/dev/null; rc=$?
check "change: empty password refused" '[ $rc -eq 1 ] && grep -q DEFAULT "$NSH_FILE"'

setup; ( . "$LIB"; nsh_boot ) >/dev/null
printf '#!/bin/sh\necho garbage\n' > "$T/w/bin/mkpasswd"
echo "x" | ( . "$LIB"; nsh_set_root_password ) >/dev/null; rc=$?
check "change: bad hash refused, file untouched" '[ $rc -eq 2 ] && grep -q DEFAULT "$NSH_FILE"'

setup
echo "x" | ( . "$LIB"; nsh_set_root_password ) >/dev/null; rc=$?
check "change: no persistent copy yet -> refused" '[ $rc -eq 1 ]'

# --- wiring -------------------------------------------------------------------
check "S01persistent-datastore runs nsh_boot" 'grep -q "nsh_boot" "$OVERLAY/etc/init.d/S01persistent-datastore"'
check "passwd wrapper routes root to nebulaos-passwd" 'grep -q "exec /usr/sbin/nebulaos-passwd" "$OVERLAY/usr/bin/passwd"'
check "passwd wrapper keeps BusyBox for everything else" 'grep -q "exec busybox passwd" "$OVERLAY/usr/bin/passwd"'
check "commands are executable" '[ -x "$OVERLAY/usr/sbin/nebulaos-passwd" ] && [ -x "$OVERLAY/usr/bin/passwd" ]'

echo "nebulaos-shadow-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
