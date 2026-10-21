#!/bin/sh
#
# G82 verifier note (Run 16): S01persistent-datastore itself, run end to end
# in a sandbox against a real pre-rename GuppyScreen settings file - the
# library is tested on its own in nebulascreen-lib-tests.sh; this proves the
# boot script sources it, copies at the right moment, binds the new file to
# its three places in the right order and removes the old empty Mainsail
# placeholder, and that a second boot copies nothing.
#
# The script runs as a copy whose absolute paths are moved under a temp root;
# mount/umount are fakes on PATH that only record their arguments.
#
# Usage: sh tests/nebulascreen-s01-migration-scenario-tests.sh
set -u
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OVERLAY="$REPO_ROOT/scripts/build/overlay"
S01="$OVERLAY/etc/init.d/S01persistent-datastore"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ns-s01-scenario.XXXXXX") || exit 1
[ -n "$WORK" ] && [ -d "$WORK" ] || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM
PASS=0 FAIL=0
t() { if eval "$2"; then PASS=$((PASS + 1)); else echo "FAIL: $1"; FAIL=$((FAIL + 1)); fi; }

R="$WORK/root"
mkdir -p "$WORK/bin"
for c in mount umount; do
	printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$c" "$WORK" > "$WORK/bin/$c"
	chmod +x "$WORK/bin/$c"
done

# The script with its absolute paths under $R (comments included - harmless).
sed -e "s#/usr/data#$R/usr/data#g" -e "s#/opt/#$R/opt/#g" "$S01" > "$WORK/S01"

# Image side: the default screen config and a minimal printer_data seed.
mkdir -p "$R/opt/nebulascreen" "$R/opt/printer_data/config"
echo '{"display_rotate": 0, "image_default": true}' > "$R/opt/nebulascreen/nebulascreen.json"
echo '[printer]' > "$R/opt/printer_data/config/printer.cfg"

# Device side, as left by the GuppyScreen image: real settings and the empty
# Mainsail placeholder it bound them onto.
OLD="$R/usr/data/nebulaos/guppyscreen/guppyconfig.json"
NEW="$R/usr/data/nebulaos/nebulascreen/nebulascreen.json"
mkdir -p "$(dirname "$OLD")" "$R/usr/data/nebulaos/printer_data/config/guppyscreen"
cat > "$OLD" <<'EOF'
{
  "display_rotate": 2,
  "touch_calibrated": true,
  "touch_calibration_coeff": [0.13, 0.0, -18.5, 0.0, 0.14, -12.2],
  "guppy_init_script": "/etc/init.d/S58guppyscreen",
  "log_path": "/opt/printer_data/logs/guppyscreen.log",
  "theme": "green"
}
EOF
touch -d '2026-10-01 12:00' "$OLD"
: > "$R/usr/data/nebulaos/printer_data/config/guppyscreen/guppyconfig.json"
OLD_SHA=$(sha256sum "$OLD" | cut -d' ' -f1)
OLD_MTIME=$(stat -c %Y "$OLD")

boot() {
	rm -f "$WORK/calls"
	PATH="$WORK/bin:$PATH" \
	NEBULASCREEN_LIB="$OVERLAY/etc/nebulascreen-lib.sh" \
	NEBULAOS_DATAFS_LIB="$WORK/none" NEBULAOS_RESTORE_CLOCK="$WORK/none" \
	NEBULAOS_CLEAN_RESET_LIB="$WORK/none" NEBULAOS_SHADOW_LIB="$WORK/none" \
	NEBULAOS_BOOT_DISPLAY="$WORK/none" \
		sh "$WORK/S01" start > "$WORK/out" 2>&1
}

# --- first boot of the NebulaScreen image -------------------------------
boot; rc=$?
t "S01 exits 0" '[ "$rc" = 0 ]'
t "the settings were copied byte for byte" 'cmp -s "$NEW" "$OLD"'
t "touch calibration carried over" 'grep -q "\"touch_calibrated\": true" "$NEW"'
t "old file content unchanged" '[ "$(sha256sum "$OLD" | cut -d" " -f1)" = "$OLD_SHA" ]'
t "old file mtime unchanged" '[ "$(stat -c %Y "$OLD")" = "$OLD_MTIME" ]'
t "old empty Mainsail placeholder and folder removed" \
	'[ ! -e "$R/usr/data/nebulaos/printer_data/config/guppyscreen" ]'
t "new Mainsail mount point exists" \
	'[ -f "$R/usr/data/nebulaos/printer_data/config/nebulascreen/nebulascreen.json" ]'
t "thumbnail dir created" '[ -d "$R/usr/data/nebulaos/nebulascreen/thumbnails" ]'
for target in "$R/opt/nebulascreen/nebulascreen.json" \
	"$R/usr/data/nebulaos/printer_data/config/nebulascreen/nebulascreen.json" \
	"$R/opt/printer_data/config/nebulascreen/nebulascreen.json"; do
	t "bound: $target" 'grep -qxF "mount --bind $NEW $target" "$WORK/calls"'
done
t "exactly three binds of the new file" '[ "$(grep -c -F -- "--bind $NEW " "$WORK/calls")" = 3 ]'
t "the /opt/printer_data view is bound before its file bind" \
	'[ "$(grep -n -- "--bind $R/usr/data/nebulaos/printer_data $R/opt/printer_data\$" "$WORK/calls" | cut -d: -f1)" -lt "$(grep -n -- "$R/opt/printer_data/config/nebulascreen/nebulascreen.json\$" "$WORK/calls" | cut -d: -f1)" ]'
t "nothing binds the old file anywhere" '! grep -q "guppyconfig.json" "$WORK/calls"'
t "no whole-directory bind of /opt/nebulascreen" '! grep -q -- "--bind .* $R/opt/nebulascreen\$" "$WORK/calls"'

# --- the user changes a setting, then a second boot -----------------------
sed -i 's/"theme": "green"/"theme": "red"/' "$NEW"
boot
t "second boot copies nothing (user's change kept)" 'grep -q "\"theme\": \"red\"" "$NEW"'
t "old file still unchanged after two boots" '[ "$(sha256sum "$OLD" | cut -d" " -f1)" = "$OLD_SHA" ]'

# --- a fresh device (never ran GuppyScreen) --------------------------------
rm -rf "$R/usr/data"
boot
t "fresh device: the image default is seeded" 'cmp -s "$NEW" "$R/opt/nebulascreen/nebulascreen.json"'
t "fresh device: no guppyscreen folder is created" '[ ! -e "$R/usr/data/nebulaos/guppyscreen" ]'

echo "nebulascreen-s01-migration-scenario-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
