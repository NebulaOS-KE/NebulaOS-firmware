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

# G63 (2026-10-16): the G62 root printer_data/uploads and a logo Mainsail
# put in config/boot-logo move into config/uploads.
CFG2="$W/pd2/config"; UP2="$CFG2/uploads"; G62="$W/pd2/uploads"
mkdir -p "$G62/boot-logo" "$G62/system-image" "$G62/mainboard-firmware" "$CFG2/boot-logo"
echo uuid > "$CFG2/boot-logo/80eb706d-36c6.png"
echo a > "$G62/boot-logo/a.png"; echo i > "$G62/system-image/x.img"
run2() {
	(GATE_LIB="$ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh" SEED_MANIFEST_LIB="$ROOT/scripts/build/overlay/etc/nebulaos-seed-manifest.sh" S04NEBULAOS_MIGRATE_NO_AUTORUN=1 PRINTER_DATA_CONFIG="$CFG2" UPLOADS_ROOT="$UP2" G62_UPLOADS_ROOT="$G62" OLD_BOOT_UPLOADS="$W/none" \
	 SYSTEM="$W/system2" sh -c ". '$S04' >/dev/null 2>&1; log() { echo \"\$*\" >> '$W/log'; }; $1")
}
run2 migrate_user_uploads
[ "$(cat "$UP2/boot-logo/80eb706d-36c6.png" 2>/dev/null)" = uuid ] && [ "$(cat "$UP2/boot-logo/a.png" 2>/dev/null)" = a ] \
	&& [ "$(cat "$UP2/system-image/x.img" 2>/dev/null)" = i ] && pass || fail "G63 move: $(find "$W/pd2" -type f)"
[ ! -e "$G62" ] && [ ! -e "$CFG2/boot-logo" ] && pass || fail "G62 root / config/boot-logo not removed when empty"

# G63: retired config leftovers - static_ip*.json moved away (never deleted),
# GuppyScreen/scripts/static_ip.py removed only when it is a shipped version.
mkdir -p "$CFG2/GuppyScreen/scripts"
echo '{}' > "$CFG2/static_ip.json"; echo '{"x":1}' > "$CFG2/static_ip_dhcp_snapshot.json"
git -C "$ROOT" show 96fd2be:scripts/build/overlay/opt/printer_data/config/GuppyScreen/scripts/static_ip.py > "$CFG2/GuppyScreen/scripts/static_ip.py" 2>/dev/null
run2 retire_config_leftovers
[ ! -e "$CFG2/static_ip.json" ] && [ ! -e "$CFG2/static_ip_dhcp_snapshot.json" ] \
	&& [ "$(ls "$W/system2/migration-backups/retired-config" | wc -l)" -eq 2 ] && pass || fail "static_ip json not retired"
[ ! -e "$CFG2/GuppyScreen" ] && pass || fail "shipped static_ip.py / GuppyScreen folder not removed"
mkdir -p "$CFG2/GuppyScreen/scripts"; echo "# my own" > "$CFG2/GuppyScreen/scripts/static_ip.py"
run2 retire_config_leftovers
[ -f "$CFG2/GuppyScreen/scripts/static_ip.py" ] && pass || fail "a user's own static_ip.py was removed"

# G65: the settings snapshot runs once per new system image (seed manifest
# changes, including a downgrade), before every other migration step.
mkdir -p "$W/seeds" "$W/bin2"
echo '{"firmware_head":"aaa"}' > "$W/seeds/seed-manifest.json"
printf '#!/bin/sh\necho "$*" >> "%s/osconfig-calls"\n' "$W" > "$W/bin2/osconfig"; chmod +x "$W/bin2/osconfig"
run3() {
	(GATE_LIB="$ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh" SEED_MANIFEST_LIB="$ROOT/scripts/build/overlay/etc/nebulaos-seed-manifest.sh" S04NEBULAOS_MIGRATE_NO_AUTORUN=1 \
	 SEEDS="$W/seeds" OSCONFIG="$W/bin2/osconfig" SYSTEM="$W/system3" sh -c ". '$S04' >/dev/null 2>&1; log() { :; }; settings_snapshot_on_new_system")
}
run3; run3
[ "$(grep -c 'settings snapshot --reason new-system --db file' "$W/osconfig-calls" 2>/dev/null)" = 1 ] && pass || fail "snapshot not taken exactly once"
echo '{"firmware_head":"older"}' > "$W/seeds/seed-manifest.json"; run3
[ "$(grep -c 'new-system' "$W/osconfig-calls")" = 2 ] && pass || fail "rolled-back system got no snapshot"
_first=$(grep -n '^	[a-z_]*$' "$S04" | grep -A1 'settings_snapshot_on_new_system' | head -1 | cut -d: -f1)
_pin=$(grep -n '^	migrate_moonraker_pin_include$' "$S04" | cut -d: -f1)
[ -n "$_first" ] && [ -n "$_pin" ] && [ "$_first" -lt "$_pin" ] && pass || fail "snapshot does not run before migrate_moonraker_pin_include"

echo "user-uploads-migration-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
