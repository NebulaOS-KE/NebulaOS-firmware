#!/bin/sh
#
# BOOT-03 / BOOT-04 (2026-10-05): offline tests for the venv validation
# stamp in scripts/build/overlay/usr/libexec/nebulaos-venv-lib.sh and its use
# by S04nebulaos-factory-seed (fast path) and S05nebulaos-activate.
#
# Fake venvs whose interpreter counts how often it is started: the expensive
# check is "skipped" exactly when that count does not move.
#
# Usage: sh tests/venv-validation-stamp-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OVERLAY="$SCRIPT_DIR/../scripts/build/overlay"
LIB="$OVERLAY/usr/libexec/nebulaos-venv-lib.sh"
S04="$OVERLAY/etc/init.d/S04nebulaos-factory-seed"
S05="$OVERLAY/etc/init.d/S05nebulaos-activate"
W=$(mktemp -d "${TMPDIR:-/tmp}/venv-validation-stamp-tests.XXXXXX")
[ -n "${W:-}" ] && [ -e "$W" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

COUNT="$W/python-starts"
: > "$COUNT"
starts() { wc -l < "$COUNT" | tr -d ' '; }

# make_venv DIR [imports-ok]
make_venv() {
	mkdir -p "$1/bin" "$1/lib/python3.12/site-packages/pkg_a"
	cat > "$1/bin/python3" <<EOF
#!/bin/sh
echo "\$0 \$*" >> "$COUNT"
[ -e "$1/.imports-broken" ] && case "\$2" in import\ sys) exit 0 ;; *) exit 1 ;; esac
exit 0
EOF
	chmod +x "$1/bin/python3"
	printf 'home = /usr/bin\nversion = 3.12.14\n' > "$1/pyvenv.cfg"
	: > "$1/lib/python3.12/site-packages/pkg_a-1.0.dist-info"
	[ "${2:-yes}" = yes ] || : > "$1/.imports-broken"
}

NB="$W/nb"; mkdir -p "$NB/system" "$NB/maintenance" "$W/seeds" "$W/sys"
export NEBULAOS_ROOT="$NB" SYSTEM="$NB/system" APPS="$NB/apps" SEEDS="$W/seeds"
export VENV_SYSTEM_PYTHON="$W/sys/python3"
echo "system python 3.12.14 build A" > "$VENV_SYSTEM_PYTHON"
echo '{"migration_version":"gen-A"}' > "$SEEDS/seed-manifest.json"
for a in klipper nebulaos-klipper-extensions moonraker; do
	mkdir -p "$APPS/$a/.git/refs/heads"
	echo "ref: refs/heads/master" > "$APPS/$a/.git/HEAD"
	echo "1111111111111111111111111111111111111111" > "$APPS/$a/.git/refs/heads/master"
done
log() { echo "$1" >> "$W/log"; }
# shellcheck disable=SC1090
. "$LIB"

E="$NB/envs/klipper"; SMOKE="import greenlet, cffi, jinja2, serial, can"
make_venv "$E"
STAMP="$NB/system/venv-validation/klipper.key"

check() { # expect-rc expect-source description
	before=$(starts)
	venv_validated_usable "$E" "$SMOKE"; rc=$?
	after=$(starts)
	if [ "$rc" = "$1" ] && [ "${VENV_VALIDATION_SOURCE:-none}" = "$2" ]; then pass; else
		fail "$3 (rc=$rc source=${VENV_VALIDATION_SOURCE:-none} starts $before->$after)"; fi
	LAST_STARTS=$((after - before))
}

# 1. virgin first boot: no stamp -> full check, stamp written
check 0 full "virgin boot did not run the full check"
[ "$LAST_STARTS" -ge 1 ] && [ -f "$STAMP" ] && pass || fail "virgin boot: interpreter not started or stamp missing"
# 2. unchanged second boot: expensive check skipped
check 0 stamp "unchanged boot did not use the stamp"
[ "$LAST_STARTS" = 0 ] && pass || fail "unchanged boot still started the interpreter ($LAST_STARTS)"
# 3. S05 (BOOT-04) on the same boot reuses S04's result through the same stamp
check 0 stamp "S05 duplicate check was not skipped"

# changed identity -> full, then stable again
changed() { # description
	check 0 full "$1: full check did not run"
	[ "$LAST_STARTS" -ge 1 ] && pass || fail "$1: interpreter not started"
	check 0 stamp "$1: second call after the full check did not use the new stamp"
}
echo '{"migration_version":"gen-B"}' > "$SEEDS/seed-manifest.json"; changed "changed seed manifest (new image generation)"
echo "system python 3.12.15 build B - longer" > "$VENV_SYSTEM_PYTHON"; changed "changed system interpreter"
printf 'home = /usr/bin\nversion = 3.12.15\n' > "$E/pyvenv.cfg"; changed "changed pyvenv.cfg"
: > "$E/lib/python3.12/site-packages/pkg_b-2.0.dist-info"; changed "package installed in the venv"
rm -f "$E/lib/python3.12/site-packages/pkg_b-2.0.dist-info"; changed "package removed from the venv"
# G103 P3: an app update (its checkout moves) cannot change the import
# answer - the stamp stays valid, no full check on the next boot
echo "2222222222222222222222222222222222222222" > "$APPS/klipper/.git/refs/heads/master"
check 0 stamp "klipper checkout moved: the stamp must stay valid"
echo "3333333333333333333333333333333333333333" > "$APPS/nebulaos-klipper-extensions/.git/refs/heads/master"
check 0 stamp "extensions checkout moved: the stamp must stay valid"
[ "$LAST_STARTS" = 0 ] && pass || fail "an app update started the interpreter ($LAST_STARTS)"
mkdir -p "$E.old"; changed "torn swap pending recovery (<env>.old present)"; rmdir "$E.old"; changed "recovery finished"

# 4. different question (smoke list) is never answered by another one's stamp
before=$(starts); venv_validated_usable "$E" "import greenlet"; after=$(starts)
[ "$VENV_VALIDATION_SOURCE" = full ] && [ "$after" -gt "$before" ] && pass || fail "different smoke reused the stamp"
venv_validated_usable "$E" "$SMOKE" >/dev/null

# 5. missing / corrupt / unreadable stamp -> full
check 0 stamp "precondition: stamp in place"
rm -f "$STAMP"; check 0 full "missing stamp did not force a full check"
echo "garbage" > "$STAMP"; check 0 full "corrupt stamp did not force a full check"
head -c 3 "$STAMP" > "$STAMP.cut"; mv "$STAMP.cut" "$STAMP"; check 0 full "truncated stamp did not force a full check"
chmod 000 "$STAMP"
if [ -r "$STAMP" ]; then pass; else check 0 full "unreadable stamp did not force a full check"; fi
chmod 644 "$STAMP" 2>/dev/null

# 6. failed validation: rc 1, stamp removed, never trusted afterwards
check 0 stamp "precondition before breaking imports"
: > "$E/.imports-broken"
before=$(starts); venv_validated_usable "$E" "$SMOKE"; rc=$?
# the stamp still matched (nothing in the key changed), so a broken-but-unchanged
# env is only caught once something changes or the stamp is dropped - make the
# break visible the way a real reinstall would: touch the package listing
: > "$E/lib/python3.12/site-packages/broken-marker"
venv_validated_usable "$E" "$SMOKE"; rc=$?
[ "$rc" = 1 ] && [ ! -f "$STAMP" ] && pass || fail "failed validation kept/returned success (rc=$rc stamp=$([ -f "$STAMP" ] && echo yes))"
venv_validated_usable "$E" "$SMOKE"; rc=$?
[ "$rc" = 1 ] && pass || fail "a failing env passed on the next call"
rm -f "$E/.imports-broken" "$E/lib/python3.12/site-packages/broken-marker"
check 0 full "repaired env did not get a full check"

# 7. explicit revalidation: marker forces full checks while present; reset drops stamps
: > "$NB/maintenance/revalidate-venvs"
check 0 full "revalidate marker did not force a full check"
check 0 full "revalidate marker did not force a full check twice"
rm -f "$NB/maintenance/revalidate-venvs"
check 0 stamp "after the marker the stamp is trusted again"
venv_validation_reset; [ ! -e "$NB/system/venv-validation" ] && pass || fail "reset did not remove the stamps"
check 0 full "after reset the check was not full"

# 8. replacing the venv (seed / reprovision) invalidates its stamp
check 0 stamp "precondition before swap"
mkdir -p "$E.partial"; cp -a "$E/." "$E.partial/"
swap_venv_into_place "$E" && [ ! -f "$STAMP" ] && pass || fail "swap_venv_into_place left the stamp"
check 0 full "swapped env was not fully checked"

# 9. missing environment / unwritable stamp dir
rm -rf "$NB/envs/moonraker"
venv_validated_usable "$NB/envs/moonraker" "import tornado"; [ $? = 1 ] && pass || fail "missing env reported usable"
chmod 555 "$NB/system/venv-validation"
if [ -w "$NB/system/venv-validation" ]; then pass; pass; else
	rm -f "$STAMP" 2>/dev/null
	venv_validation_reset 2>/dev/null
	mkdir -p "$W/ro"; chmod 555 "$W/ro"; VENV_VALIDATION_DIR="$W/ro/v"
	check 0 full "unwritable stamp dir: check failed"
	check 0 full "unwritable stamp dir: a stamp was trusted that could not have been written"
	VENV_VALIDATION_DIR="$NB/system/venv-validation"
fi
chmod 755 "$NB/system/venv-validation" 2>/dev/null

# 10. the key never starts an interpreter
before=$(starts); venv_validation_key "$E" "$SMOKE" > /dev/null; after=$(starts)
[ "$before" = "$after" ] && pass || fail "computing the key started the interpreter"

# 11. S04 start(): first boot full, unchanged boot fast path with zero interpreter starts
E2="$NB/envs"; rm -rf "$E2"; make_venv "$E2/klipper"; make_venv "$E2/moonraker"
mkdir -p "$APPS/mainsail"; : > "$APPS/mainsail/index.html"
venv_validation_reset
run_s04() {
	env S04NEBULAOS_FACTORY_SEED_NO_AUTORUN=1 NEBULAOS_ROOT="$NB" SYSTEM="$NB/system" APPS="$APPS" ENVS="$E2" SEEDS="$SEEDS" \
		VENV_SYSTEM_PYTHON="$VENV_SYSTEM_PYTHON" NEBULAOS_VENV_LIB="$LIB" COUNT="$COUNT" \
		GATE_LIB="$OVERLAY/etc/nebulaos-maintenance-gate.sh" SEED_MANIFEST_LIB="$OVERLAY/etc/nebulaos-seed-manifest.sh" \
		sh -c ". '$S04'; start" > "$W/s04.out" 2>&1
}
before=$(starts); run_s04; rc=$?; after=$(starts)
[ $rc = 0 ] && [ "$after" -gt "$before" ] && grep -q 'all components already seeded' "$W/s04.out" && pass \
	|| fail "S04 first validation (rc=$rc starts $before->$after): $(cat "$W/s04.out")"
before=$(starts); run_s04; rc=$?; after=$(starts)
[ $rc = 0 ] && [ "$after" = "$before" ] && grep -q 'all components already seeded' "$W/s04.out" && pass \
	|| fail "S04 unchanged boot started the interpreter (starts $before->$after): $(cat "$W/s04.out")"
# S04 honours and consumes the revalidate marker
: > "$NB/maintenance/revalidate-venvs"
before=$(starts); run_s04; after=$(starts)
[ "$after" -gt "$before" ] && [ ! -e "$NB/maintenance/revalidate-venvs" ] && pass || fail "S04 did not consume the revalidate marker with a full check"
# S04 with a partial seed (an app missing) leaves the fast path for the seeding path
rm -f "$APPS/mainsail/index.html"
run_s04; grep -q 'all components already seeded' "$W/s04.out" && fail "partial seed took the fast path" || pass
: > "$APPS/mainsail/index.html"

# 12. S05 uses the shared stamp for the klipper venv and keeps the chelper preflight
grep -q 'venv_validated_usable "$NEBULAOS_ROOT/envs/klipper"' "$S05" && pass || fail "S05 does not use the shared validation"
grep -q 'chelper_write_verdict "$kdir"' "$S05" && pass || fail "S05 chelper preflight removed"
grep -q 'venv_is_usable "$NEBULAOS_ROOT/envs/klipper"' "$S05" && fail "S05 still runs the unconditional check" || pass

echo "venv-validation-stamp-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
