#!/bin/sh
#
# G82 (Run 15 stage 2b) grep gate: the image is NebulaScreen. No build script
# or overlay file may use a GuppyScreen path or init script again, except the
# few lines that exist precisely to migrate away from the old image, to
# prove it is gone, or to refuse an old settings file inside a downloaded
# release (the allow-list below - each entry is file + exact text).
# Comments are ignored. Host tools (tools/hardware, tools/hwcap) are
# deliberately dual-name - they talk to printers on older images - and are
# not scanned.
#
# Usage: sh tests/nebulascreen-legacy-name-gate-tests.sh
set -u
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO_ROOT" || exit 1
PASS=0 FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

LEGACY='/opt/guppyscreen|S58guppyscreen|guppyscreen-mips|guppyconfig\.json|/usr/data/guppyscreen|nebulaos/guppyscreen|nebulaos-guppyscreen|GUPPYSCREEN_(PIN|REPO|BRANCH|VERSION|THEME)'

# file<TAB>exact text that may stay
ALLOW=$(printf '%s\t%s\n' \
	scripts/build/06-verify.sh 'check_absent /etc/init.d/S58guppyscreen' \
	scripts/build/06-verify.sh 'check_absent /opt/guppyscreen/guppyscreen' \
	scripts/build/overlay/etc/init.d/S01persistent-datastore 'ns_migrate_config "$OLD_GUPPY_STATE/guppyconfig.json"' \
	scripts/build/overlay/etc/init.d/S01persistent-datastore 'ns_remove_empty_placeholder "$PDATA/config/guppyscreen/guppyconfig.json"' \
	scripts/build/overlay/usr/libexec/nebulaos/nebulascreen-release-check 'FORBIDDEN_NAMES = ("nebulascreen.json", "guppyconfig.json")')

hits=$(grep -rnE --exclude="*.md" --exclude="*.txt" "$LEGACY" scripts build.sh manifests 2>/dev/null \
	| grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
bad=""
OLDIFS=$IFS
IFS='
'
for hit in $hits; do
	file=${hit%%:*}
	text=${hit#*:}; text=${text#*:}
	allowed=0
	for entry in $ALLOW; do
		afile=$(printf '%s' "$entry" | cut -f1)
		atext=$(printf '%s' "$entry" | cut -f2-)
		if [ "$file" = "$afile" ]; then
			case "$text" in *"$atext"*) allowed=1 ;; esac
		fi
	done
	[ "$allowed" = 1 ] || bad="$bad
  $hit"
done
IFS=$OLDIFS

if [ -z "$bad" ]; then
	pass "no GuppyScreen path, init script or manifest key outside the migration allow-list"
else
	fail "legacy GuppyScreen names in build or image code:$bad"
fi

# The allow-list must not go stale: every entry still matches a real line.
stale=""
IFS='
'
for entry in $ALLOW; do
	afile=$(printf '%s' "$entry" | cut -f1)
	atext=$(printf '%s' "$entry" | cut -f2-)
	grep -qF "$atext" "$afile" 2>/dev/null || stale="$stale
  $afile: $atext"
done
IFS=$OLDIFS
if [ -z "$stale" ]; then
	pass "every allow-list entry still matches a line"
else
	fail "stale allow-list entries (remove them):$stale"
fi

[ ! -e scripts/build/overlay/etc/init.d/S58guppyscreen ] \
	&& pass "no S58guppyscreen in the overlay" || fail "S58guppyscreen is back in the overlay"
[ ! -e scripts/build/overlay/opt/guppyscreen ] && [ ! -L scripts/build/overlay/opt/guppyscreen ] \
	&& pass "no /opt/guppyscreen in the overlay" || fail "/opt/guppyscreen is back in the overlay"

echo "nebulascreen-legacy-name-gate-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
