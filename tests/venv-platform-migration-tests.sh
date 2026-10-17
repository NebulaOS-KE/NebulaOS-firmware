#!/bin/sh
# Persistent-venv platform-compatibility migration tests.
#
# Exercises the REAL helpers in
# scripts/build/overlay/usr/libexec/nebulaos-venv-lib.sh by sourcing that file
# - not a reimplementation of them - against fake venvs on disk.
#
# What is being protected (mission section 15):
#   - a usable venv is KEPT, untouched (provisioning is idempotent)
#   - a torn or non-functional venv is REPROVISIONED, including the shape the
#     old `[ -x bin/python3 ]` guard got wrong: interpreter present, env not
#     actually usable
#   - a corrupt venv is replaced
#   - a failed replacement does NOT destroy the existing environment
#   - an interrupted rename-swap is recoverable on the next boot
#   - repeated runs are idempotent
#
# The fake interpreter is a shell script: the predicate only ever execs it and
# runs an import smoke test, both of which a script can answer
# deterministically, so the suite does not depend on the host's python.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
LIB=$ROOT/scripts/build/overlay/usr/libexec/nebulaos-venv-lib.sh

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

[ -r "$LIB" ] || { printf 'SKIP: %s not found\n' "$LIB"; printf 'VENV_PLATFORM_MIGRATION=SKIP\n'; exit 2; }

SYS_MM=$(/usr/bin/python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)
[ -n "$SYS_MM" ] || { printf 'SKIP: no working /usr/bin/python3 to compare against\n'; printf 'VENV_PLATFORM_MIGRATION=SKIP\n'; exit 2; }

W=$(mktemp -d) || { printf 'SKIP: cannot create a temporary directory\n'; printf 'VENV_PLATFORM_MIGRATION=SKIP\n'; exit 2; }
trap 'rm -rf "$W"' EXIT INT TERM

LOGFILE=$W/log
log() { echo "$1" >> "$LOGFILE"; }
. "$LIB"

# make_venv <dir> <majmin> <imports-ok:yes|no>
make_venv() {
	_d=$1; _mm=$2; _imp=$3
	mkdir -p "$_d/bin"
	cat > "$_d/bin/python3" <<PYEOF
#!/bin/sh
# fake interpreter reporting $_mm
for a in "\$@"; do
  case "\$a" in
    *version_info*) echo "$_mm"; exit 0 ;;
    import*) [ "$_imp" = yes ] && exit 0 || exit 1 ;;
  esac
done
exit 0
PYEOF
	chmod 755 "$_d/bin/python3"
	printf 'home = /usr/bin\nversion = %s\n' "$_mm" > "$_d/pyvenv.cfg"
}

SMOKE="import greenlet, cffi"

# ---- 1. a venv matching the running image is accepted ----------------------
E=$W/case1; make_venv "$E" "$SYS_MM" yes
if venv_is_usable "$E" "$SMOKE"; then ok "current-version venv is accepted"; else bad "current-version venv was rejected"; fi

# ---- 2. an interpreter that exists but does not RUN is rejected ------------
# The torn-provisioning shape: bin/python3 present (so the old `-x` guard said
# "done") but the environment behind it is not actually functional.
E=$W/case2; make_venv "$E" "$SYS_MM" yes
cat > "$E/bin/python3" <<'BROKEN'
#!/bin/sh
exit 1
BROKEN
chmod 755 "$E/bin/python3"
if venv_is_usable "$E" "$SMOKE"; then bad "non-executing interpreter was accepted"; else ok "interpreter that exists but does not run is rejected"; fi

# ---- 3. NOT IN SCOPE: interpreter-version migration ------------------------
# NebulaOS is unreleased and /usr/data/nebulaos is NebulaOS-owned, so no
# deployed device carries a Python 3.11 venv for this image to migrate. This
# release therefore does NOT compare the venv's python version against the
# running image, and a venv reporting a different minor is NOT rejected on
# that basis alone. Asserted explicitly so that the day someone adds version
# awareness (the first post-release Python ABI transition - see
# docs/NEBULAOS_PLATFORM_APP_BOUNDARY.md) this test fails and forces the
# scope decision to be revisited deliberately rather than silently.
E=$W/case3; make_venv "$E" "3.11" yes
if venv_is_usable "$E" "$SMOKE"; then
	ok "version mismatch alone does NOT reject (documented out of scope for this release)"
else
	bad "a version check has been added - revisit scope and update docs/NEBULAOS_PLATFORM_APP_BOUNDARY.md"
fi

# ---- 4. bin/python3 present but not executable -> rejected -----------------
E=$W/case4; make_venv "$E" "$SYS_MM" yes; chmod 644 "$E/bin/python3"
if venv_is_usable "$E" "$SMOKE"; then bad "non-executable interpreter was accepted"; else ok "non-executable interpreter is rejected"; fi

# ---- 5. dangling symlink (the real post-OTA shape) -> rejected -------------
E=$W/case5; mkdir -p "$E/bin"; ln -s /usr/bin/python3.11 "$E/bin/python3"
printf 'home = /usr/bin\nversion = 3.11.6\n' > "$E/pyvenv.cfg"
if venv_is_usable "$E" "$SMOKE"; then bad "dangling interpreter symlink was accepted"; else ok "dangling interpreter symlink is rejected"; fi

# ---- 6. missing pyvenv.cfg -> rejected -------------------------------------
E=$W/case6; make_venv "$E" "$SYS_MM" yes; rm -f "$E/pyvenv.cfg"
if venv_is_usable "$E" "$SMOKE"; then bad "venv without pyvenv.cfg was accepted"; else ok "venv without pyvenv.cfg is rejected"; fi

# ---- 7. right version, failing imports -> rejected -------------------------
E=$W/case7; make_venv "$E" "$SYS_MM" no
if venv_is_usable "$E" "$SMOKE"; then bad "venv failing its import smoke test was accepted"; else ok "venv failing its import smoke test is rejected"; fi

# ---- 8. empty directory (what S02nebulaos-namespace leaves) -> rejected ----
E=$W/case8; mkdir -p "$E"
if venv_is_usable "$E" "$SMOKE"; then bad "empty env directory was accepted"; else ok "empty env directory is rejected"; fi

# ---- 9. swap does not destroy the old env on failure -----------------------
# .partial absent => mv fails => the existing environment must survive.
E=$W/case9; make_venv "$E" "$SYS_MM" yes
if swap_venv_into_place "$E"; then bad "swap reported success with no .partial staged"
else
	if venv_is_usable "$E" "$SMOKE"; then ok "failed swap left the existing environment intact and usable"
	else bad "failed swap destroyed or corrupted the existing environment"; fi
fi

# ---- 10. successful swap replaces and cleans up ----------------------------
E=$W/case10; make_venv "$E" "3.11" yes; make_venv "$E.partial" "$SYS_MM" yes
if swap_venv_into_place "$E" && venv_is_usable "$E" "$SMOKE"; then
	[ ! -e "$E.old" ] && [ ! -e "$E.partial" ] \
		&& ok "successful swap replaced the env and removed .old/.partial" \
		|| bad "successful swap left .old or .partial behind"
else bad "successful swap did not produce a usable environment"; fi

# ---- 11. interrupted swap is recovered on the next boot --------------------
# Simulate a power cut between `mv env env.old` and `mv env.partial env`, THEN
# let S02nebulaos-namespace recreate an empty env dir - which is why the
# recovery trigger must not be "env is missing".
E=$W/case11; make_venv "$E.old" "$SYS_MM" yes; mkdir -p "$E"
recover_torn_venv "$E" "$SMOKE"
if venv_is_usable "$E" "$SMOKE" && [ ! -e "$E.old" ]; then
	ok "interrupted swap recovered from .old even though S02 recreated an empty env dir"
else bad "interrupted swap was NOT recovered (this is the trigger that must not test for absence)"; fi

# ---- 12. .old that is itself unusable is discarded, not restored -----------
E=$W/case12; make_venv "$E.old" "$SYS_MM" no; mkdir -p "$E"
recover_torn_venv "$E" "$SMOKE"
if [ ! -e "$E.old" ]; then ok "an unusable .old is discarded rather than restored"
else bad "an unusable .old was left in place"; fi

# ---- 13. idempotence: recovery over a good env is a no-op ------------------
E=$W/case13; make_venv "$E" "$SYS_MM" yes
recover_torn_venv "$E" "$SMOKE"; recover_torn_venv "$E" "$SMOKE"
if venv_is_usable "$E" "$SMOKE"; then ok "repeated recovery over a good env is idempotent"
else bad "repeated recovery damaged a good env"; fi

# ---- 14. stale .old alongside a GOOD env is cleaned up ---------------------
E=$W/case14; make_venv "$E" "$SYS_MM" yes; make_venv "$E.old" "$SYS_MM" yes
recover_torn_venv "$E" "$SMOKE"
if venv_is_usable "$E" "$SMOKE" && [ ! -e "$E.old" ]; then
	ok "leftover .old beside a good env is cleaned up"
else bad "leftover .old beside a good env was mishandled"; fi

# ---- G50: Python ABI stamp --------------------------------------------------
# Once venvs hold compiled packages from the NebulaOS package index, a venv is
# tied to one image ABI fingerprint; it outlives the image (update/rollback).
printf 'scheme=1\nid=abc123\n' > "$W/python-abi"
VENV_PYTHON_ABI=$W/python-abi
E=$W/abi1; make_venv "$E" "$SYS_MM" yes
if venv_is_usable "$E" "$SMOKE" && [ "$(cat "$E/.nebulaos-abi" 2>/dev/null)" = abc123 ]; then
	ok "an unstamped venv is accepted and stamped for the running image"
else bad "unstamped venv not stamped"; fi
if venv_is_usable "$E" "$SMOKE"; then ok "a venv stamped for this image is accepted"; else bad "matching stamp rejected"; fi
printf 'scheme=1\nid=def456\n' > "$W/python-abi"
if venv_is_usable "$E" "$SMOKE"; then bad "a venv built for another ABI was accepted"
else ok "a venv built for another ABI is reprovisioned"; fi
k1=$(venv_validation_key "$E" "$SMOKE"); printf 'scheme=1\nid=abc123\n' > "$W/python-abi"; k2=$(venv_validation_key "$E" "$SMOKE")
[ "$k1" != "$k2" ] && ok "the ABI is part of the validation key" || bad "ABI not in validation key"
E=$W/abi2; make_venv "$E" "$SYS_MM" no
if venv_is_usable "$E" "$SMOKE" || [ -f "$E/.nebulaos-abi" ]; then bad "a broken venv was stamped"; else ok "a broken venv is not stamped"; fi
VENV_PYTHON_ABI=$W/none
E=$W/abi3; make_venv "$E" "$SYS_MM" yes
if venv_is_usable "$E" "$SMOKE" && [ ! -f "$E/.nebulaos-abi" ]; then ok "no image fingerprint: behaviour unchanged"; else bad "stamp without fingerprint"; fi

printf '\nVENV_TESTS_PASS=%s\nVENV_TESTS_FAIL=%s\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then printf 'VENV_PLATFORM_MIGRATION=PASS\n'; exit 0; fi
printf 'VENV_PLATFORM_MIGRATION=FAIL\n'; exit 1
