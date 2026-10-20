#!/bin/sh
#
# NebulaScreen boot helpers (Run 15 stage 2a, scripts/build/overlay/etc/
# nebulascreen-lib.sh): the copy-not-move settings migration, the empty
# placeholder cleanup, the per-item release activation and "the image wins".
# Sandbox only - fake mount/umount record their arguments.
#
# Usage: sh tests/nebulascreen-lib-tests.sh
set -u
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulascreen-lib.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nebulascreen-lib.XXXXXX") || exit 1
[ -n "$WORK" ] && [ -d "$WORK" ] || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM
PASS=0 FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }
t() { if eval "$2"; then pass; else fail "$1"; fi; }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/fakemount" <<'EOF'
#!/bin/sh
echo "mount $*" >> "$NS_CALLS"
EOF
cat > "$WORK/bin/fakeumount" <<'EOF'
#!/bin/sh
echo "umount $*" >> "$NS_CALLS"
exit 1
EOF
chmod +x "$WORK/bin/fakemount" "$WORK/bin/fakeumount"
export NS_MOUNT="$WORK/bin/fakemount" NS_UMOUNT="$WORK/bin/fakeumount" \
	NS_CALLS="$WORK/calls"
# shellcheck disable=SC1090
. "$LIB"
ns_log() { echo "$*" >> "$WORK/log"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

D="$WORK/data"
OLD="$D/guppyscreen/guppyconfig.json"
NEW="$D/nebulascreen/nebulascreen.json"
SEED="$WORK/image/nebulascreen.default.json"
mkdir -p "$D/guppyscreen" "$WORK/image"
echo '{"display_rotate": 0, "default": true}' > "$SEED"
reset() { rm -rf "$D/nebulascreen" "$WORK/log"; }

# --- settings migration ---------------------------------------------------
reset; rm -f "$OLD"
ns_migrate_config "$OLD" "$NEW" "$SEED"
t "fresh device is seeded" 'cmp -s "$NEW" "$SEED"'

reset
echo '{"display_rotate": 2, "guppy_init_script": "/etc/init.d/S58guppyscreen"}' > "$OLD"
touch -d '2026-10-01 12:00' "$OLD"
before=$(sha "$OLD"); mtime=$(stat -c %Y "$OLD")
ns_migrate_config "$OLD" "$NEW" "$SEED"
t "old settings copied byte for byte" 'cmp -s "$NEW" "$OLD"'
t "old file content unchanged" '[ "$(sha "$OLD")" = "$before" ]'
t "old file mtime unchanged" '[ "$(stat -c %Y "$OLD")" = "$mtime" ]'
t "no temp file left" '[ ! -e "$NEW.tmp" ]'

echo '{"display_rotate": 1}' > "$NEW"
ns_migrate_config "$OLD" "$NEW" "$SEED"
t "second boot never copies again" 'grep -q "\"display_rotate\": 1" "$NEW"'

reset; echo '{"display_rotate": 2' > "$OLD"          # truncated by a power cut
ns_migrate_config "$OLD" "$NEW" "$SEED"
t "truncated old file -> image default" 'cmp -s "$NEW" "$SEED"'
reset; : > "$OLD"
ns_migrate_config "$OLD" "$NEW" "$SEED"
t "empty old file -> image default" 'cmp -s "$NEW" "$SEED"'

reset; echo '{"display_rotate": 2}' > "$OLD"
mkdir -p "$D/nebulascreen"; echo 'partial' > "$NEW.tmp"; : > "$NEW"
ns_migrate_config "$OLD" "$NEW" "$SEED"
t "power cut mid-copy is redone" 'cmp -s "$NEW" "$OLD" && [ ! -e "$NEW.tmp" ]'

reset; mkdir -p "$WORK/ro"; chmod 555 "$WORK/ro"
ns_migrate_config "$OLD" "$WORK/ro/sub/nebulascreen.json" "$SEED"; rc=$?
t "read-only data: rc 0, nothing written" '[ "$rc" = 0 ] && [ ! -e "$WORK/ro/sub" ]'
chmod 755 "$WORK/ro"

# --- empty placeholder ----------------------------------------------------
P="$WORK/pdata/config/guppyscreen/guppyconfig.json"
mkdir -p "$(dirname "$P")"; : > "$P"
ns_remove_empty_placeholder "$P"
t "empty placeholder and folder removed" '[ ! -e "$(dirname "$P")" ]'
mkdir -p "$(dirname "$P")"; echo '{"x":1}' > "$P"
ns_remove_empty_placeholder "$P"
t "a placeholder with content stays" '[ -s "$P" ]'

# --- per-item activation --------------------------------------------------
APP="$WORK/apps/nebulascreen"; OPT="$WORK/opt/nebulascreen"
mkdir -p "$APP" "$OPT/themes"; touch "$OPT/nebulascreen" "$OPT/nebulabeep"
rm -f "$NS_CALLS"
ns_activate "$APP" "$OPT"
t "empty app dir: nothing bound" '[ ! -e "$NS_CALLS" ]'
echo '{}' > "$APP/release_info.json"; touch "$APP/nebulascreen"
ns_activate "$APP" "$OPT"
t "incomplete release: nothing bound" '[ ! -e "$NS_CALLS" ]'
touch "$APP/nebulabeep"; mkdir -p "$APP/themes"
ns_activate "$APP" "$OPT"
t "complete release: one bind per item" \
	'[ "$(grep -c "^mount --bind" "$NS_CALLS")" = 3 ]'
t "never a whole-directory bind" '! grep -q "mount --bind $APP $OPT\$" "$NS_CALLS"'
t "stale bind replaced (umount before mount)" \
	'[ "$(sed -n 1p "$NS_CALLS")" = "umount $OPT/nebulascreen" ]'

# --- the image wins -------------------------------------------------------
VJ="$WORK/opt/nebulaos-version.json"
SEEDINFO="$WORK/image/release_info.json"
STATE="$D/updates/nebulascreen/state.json"
echo '{"project_name":"NebulaOS-nebulascreen","version":"v0.9.0"}' > "$SEEDINFO"
printf '{\n  "version": "0.9.0",\n  "build_date": "2026-10-19T22:07:01Z",\n  "firmware_sha": "d4f9b38"\n}\n' > "$VJ"
ns_image_wins "$APP" "$STATE" "$VJ" "$SEEDINFO"
t "first boot of an image: app reset to the seed" \
	'[ "$(ls -A "$APP")" = "release_info.json" ] && cmp -s "$APP/release_info.json" "$SEEDINFO"'
t "identity stamped outside the app dir" 'grep -q "d4f9b38@2026-10-19T22:07:01Z" "$STATE"'
touch "$APP/nebulascreen" "$APP/nebulabeep"
ns_image_wins "$APP" "$STATE" "$VJ" "$SEEDINFO"
t "same image: a downloaded release stays" '[ -e "$APP/nebulascreen" ]'
sed -i 's/d4f9b38/abc1234/' "$VJ"
ns_image_wins "$APP" "$STATE" "$VJ" "$SEEDINFO"
t "new image: the downloaded release is dropped" \
	'[ ! -e "$APP/nebulascreen" ] && grep -q "abc1234@" "$STATE"'
mkdir -p "$WORK/other"; touch "$WORK/other/keep"
ns_image_wins "$WORK/other" "$STATE.x" "$VJ" "$SEEDINFO"
t "refuses an unexpected directory" '[ -e "$WORK/other/keep" ]'

# --- the library is inert in this stage --------------------------------
t "not wired into any init script yet" \
	'! grep -rl "nebulascreen-lib.sh" "$REPO_ROOT/scripts/build/overlay/etc/init.d" >/dev/null 2>&1'

echo "nebulascreen-lib-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
