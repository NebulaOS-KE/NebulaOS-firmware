#!/bin/sh
# G62 (2026-10-16): S04's migrate_user_uploads moves files from the old upload
# places into printer_data/uploads - never overwriting, idempotent, old
# folders removed only when empty, no symlinks left behind.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
S04="$ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate"
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
W=$(mktemp -d "${TMPDIR:-/tmp}/uploads-mig.XXXXXX") || exit 1
[ -n "$W" ] && [ -d "$W" ] || exit 1
trap 'rm -rf "$W"' EXIT

CFG="$W/pd/config"; UP="$W/pd/uploads"; OLDBOOT="$W/boot/uploads"
mkdir -p "$CFG/firmware/mcu" "$CFG/firmware/os" "$OLDBOOT" "$UP/system-image"
echo bin1 > "$CFG/firmware/mcu/klipper.bin"
echo img-old > "$CFG/firmware/os/NebulaOS.img"
echo img-new > "$UP/system-image/NebulaOS.img"          # a different file with the same name
echo logo > "$OLDBOOT/My logo.png"
cp "$OLDBOOT/My logo.png" "$W/same.png"
mkdir -p "$UP/boot-logo"; cp "$W/same.png" "$UP/boot-logo/My logo.png"   # identical already there
echo keep > "$OLDBOOT/other.jpg"
ln -s /etc/passwd "$CFG/firmware/mcu/link.bin"

run() {
	(GATE_LIB="$ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh" SEED_MANIFEST_LIB="$ROOT/scripts/build/overlay/etc/nebulaos-seed-manifest.sh" S04NEBULAOS_MIGRATE_NO_AUTORUN=1 PRINTER_DATA_CONFIG="$CFG" UPLOADS_ROOT="$UP" OLD_BOOT_UPLOADS="$OLDBOOT" \
	 SYSTEM="$W/system" sh -c ". '$S04' >/dev/null 2>&1; log() { echo \"\$*\" >> '$W/log'; }; migrate_user_uploads")
}
run
[ "$(cat "$UP/mainboard-firmware/klipper.bin" 2>/dev/null)" = bin1 ] && pass || fail "mcu .bin not moved"
[ "$(cat "$UP/system-image/NebulaOS.img")" = img-new ] && [ "$(cat "$UP/system-image/NebulaOS (2).img" 2>/dev/null)" = img-old ] \
	&& pass || fail "name clash: $(ls "$UP/system-image")"
[ "$(ls "$UP/boot-logo" | wc -l)" -eq 2 ] && [ "$(cat "$UP/boot-logo/other.jpg")" = keep ] && pass || fail "boot logos: $(ls "$UP/boot-logo")"
[ ! -e "$CFG/firmware/os" ] && [ ! -e "$OLDBOOT" ] && pass || fail "empty old folders not removed"
[ -d "$CFG/firmware/mcu" ] && [ -L "$CFG/firmware/mcu/link.bin" ] && [ ! -e "$UP/mainboard-firmware/link.bin" ] \
	&& pass || fail "symlink moved or folder with it removed"
[ -z "$(find "$CFG" "$UP" -type l ! -name link.bin)" ] && pass || fail "a symlink was created"
run   # again: nothing changes
[ "$(ls "$UP/system-image" | wc -l)" -eq 2 ] && pass || fail "second run changed things"
grep -q "^	migrate_user_uploads$" "$S04" && pass || fail "not called from start()"

echo "user-uploads-migration-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
