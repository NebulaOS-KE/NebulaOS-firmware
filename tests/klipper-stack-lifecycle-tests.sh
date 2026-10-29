#!/bin/sh
#
# Offline, repeatable lifecycle tests for the Klipper stack as a PAIR
# (official Klipper + the NebulaOS extension set) across seeding, migration
# and activation. Phase 1 no-fork migration, Phase G.
#
# Same fixture convention as tests/factory-seed-git-tests.sh and
# tests/app-migration-tests.sh: real, locally-built git repositories under a
# temp directory, real seed archives built by the real make_seed_archive(),
# and the real init scripts sourced through their own NO_AUTORUN seams.
# Never touches GitHub, never touches a device.
#
# The load-bearing questions this file answers, none of which the existing
# suites cover:
#
#   * does the seeded Klipper checkout really end up with
#     origin = https://github.com/Klipper3d/klipper.git, and the extensions
#     checkout with its own real URL - verified, not assumed?
#   * is the pair genuinely atomic - does a half-seeded or half-migrated
#     stack leave the generation UNrecorded so the next boot retries?
#   * does migration replacing apps/klipper (which destroys the composed
#     symlinks living inside it) get automatically repaired by the S05 slot,
#     with the composition reflecting the NEW source rather than the old?
#   * does the shared klipper-stack lock actually hold activation off BOTH
#     halves?
#
# Usage: sh tests/klipper-stack-lifecycle-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# S04nebulaos-factory-seed and S05nebulaos-activate source the shared
# persistent-venv helpers. On the device that library is an absolute path
# (/usr/libexec/nebulaos-venv-lib.sh); here it lives in the overlay source
# tree, and these suites source the init script inside `sh -c`, where $0 gives
# the script no way to find it. Point at the real library so these tests
# exercise the real predicate rather than a stub.
NEBULAOS_VENV_LIB="$REPO_ROOT/scripts/build/overlay/usr/libexec/nebulaos-venv-lib.sh"
export NEBULAOS_VENV_LIB

# The S04 scripts source this shared reader (audit F-06). Exported once
# here so every `env ... sh -c ". $SCRIPT"` invocation below inherits it;
# on a device it is /etc/nebulaos-seed-manifest.sh and this is a no-op.
export SEED_MANIFEST_LIB="${SEED_MANIFEST_LIB:-$SCRIPT_DIR/../scripts/build/overlay/etc/nebulaos-seed-manifest.sh}"
OVERLAY_ETC="$REPO_ROOT/scripts/build/overlay/etc"
MAKE_ARCHIVE_LIB="$REPO_ROOT/scripts/build/lib/make-seed-archive.sh"
COMPOSE_LIB="$OVERLAY_ETC/nebulaos-klipper-compose.sh"
CHELPER_LIB="$OVERLAY_ETC/nebulaos-chelper-preflight.sh"
FACTORY_SEED_SCRIPT="$OVERLAY_ETC/init.d/S04nebulaos-factory-seed"
MIGRATE_SCRIPT="$OVERLAY_ETC/init.d/S04nebulaos-migrate"
ACTIVATE_SCRIPT="$OVERLAY_ETC/init.d/S05nebulaos-activate"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/klipper-stack-lifecycle.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: klipper-stack-lifecycle-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost

# The real production origins. These are not decoration: seed_git_app() and
# reseed_git_app() both verify the seeded checkout's baked-in origin against
# these exact strings and reject a mismatch, so using the real values is what
# makes "the device really is pointed at official Klipper" a tested property.
KLIPPER_ORIGIN="https://github.com/Klipper3d/klipper.git"
EXTENSIONS_ORIGIN="https://github.com/NebulaOS-KE/NebulaOS-klipper-extensions.git"

# The maintenance gate requires zram or NebulaOS's own /system/swapfile to be
# active in /proc/swaps. That is a real device property with its own coverage
# in tests/app-migration-tests.sh, and it is not what this file is testing -
# on a developer host it blocks every seeding path unconditionally. GATE_LIB
# is an explicit override seam for exactly this reason (see S04's own header),
# so point it at a stub that says plainly what it is.
cat > "$WORK/gate-stub.sh" <<'EOF'
# TEST STUB - not shipped. The real gate (scripts/build/overlay/etc/
# nebulaos-maintenance-gate.sh) refuses to proceed without an active print
# check, a resolved update lock, and memory-resilience swap. Its swap check
# cannot pass on a developer host. Covered for real in
# tests/app-migration-tests.sh; stubbed here so the pair-lifecycle behaviour
# under test is reachable.
maintenance_gate_ok() { return 0; }
EOF
export GATE_LIB="$WORK/gate-stub.sh"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

. "$MAKE_ARCHIVE_LIB"
. "$COMPOSE_LIB"
. "$CHELPER_LIB"

# --- fixtures -------------------------------------------------------------

# A Klipper-shaped checkout. The c_helper.so carries a genuine MIPS ELF
# header so make_seed_archive()'s own `file`-based wrong-architecture check
# reads it as a real target binary rather than discarding it.
make_klipper_repo() {
	d="$1"; content="$2"
	rm -rf "$d"
	mkdir -p "$d/klippy/extras" "$d/klippy/chelper"
	printf 'out\n*.so\n*.pyc\n' > "$d/.gitignore"
	printf '# klippy %s\n' "$content" > "$d/klippy/klippy.py"
	printf '# extras package\n' > "$d/klippy/extras/__init__.py"
	printf '# upstream heaters %s\n' "$content" > "$d/klippy/extras/heaters.py"
	printf '# chelper %s\n' "$content" > "$d/klippy/chelper/__init__.py"
	printf 'int main(void){return 0;}\n' > "$d/klippy/chelper/pyhelper.c"
	printf '#pragma once\n' > "$d/klippy/chelper/pyhelper.h"
	git -C "$d" init -q -b master
	git -C "$d" add -A
	git -C "$d" commit -q -m "klipper $content"
	printf '%b' '\0177ELF\001\001\001\0\0\0\0\0\0\0\0\0\003\0\010\0\001\0\0\0' \
		> "$d/klippy/chelper/c_helper.so"
	printf 'nebulaos test padding' >> "$d/klippy/chelper/c_helper.so"
}

make_extensions_repo() {
	d="$1"; content="$2"
	rm -rf "$d"
	mkdir -p "$d/extras"
	for m in prtouch_v2 z_compensate nebulaos_compat; do
		printf '# %s (%s)\n' "$m" "$content" > "$d/extras/$m.py"
	done
	cat > "$d/nebulaos-extensions.json" <<EOF
{
  "compat_schema_version": 1,
  "extensions_version": "$content",
  "nebulaos_api_level": 1,
  "required_klipper_symbols": [],
  "composition": {
    "source_dir": "extras",
    "destination_dir": "klippy/extras",
    "exclude_file": ".git/info/exclude",
    "link_type": "symlink",
    "marker_file": ".nebulaos-composed",
    "require_symlink_resolving_inside_source": true
  },
  "modules": [
    {"path": "extras/prtouch_v2.py", "role": "runtime"},
    {"path": "extras/z_compensate.py", "role": "runtime"},
    {"path": "extras/nebulaos_compat.py", "role": "runtime"}
  ],
  "chelper": {
    "enforced_by": "platform",
    "requirement": "prebuilt_so_mtime_newer_than_all_chelper_sources",
    "target": "klippy/chelper/c_helper.so",
    "source_dir": "klippy/chelper",
    "platform_result_file": ".nebulaos-chelper-verdict.json"
  }
}
EOF
	git -C "$d" init -q -b main
	git -C "$d" add -A
	git -C "$d" commit -q -m "extensions $content"
}

# Build a complete seed set (both archives + manifest) for one generation.
build_seed_set() {
	seeds="$1"; gen="$2"; content="$3"
	rm -rf "$seeds"; mkdir -p "$seeds"
	make_klipper_repo "$WORK/src-klipper-$gen" "$content"
	make_extensions_repo "$WORK/src-ext-$gen" "$content"
	kc=$(make_seed_archive "$WORK/src-klipper-$gen" master "$KLIPPER_ORIGIN" \
		"$seeds/klipper.tar.gz")
	ec=$(make_seed_archive "$WORK/src-ext-$gen" main "$EXTENSIONS_ORIGIN" \
		"$seeds/nebulaos-klipper-extensions.tar.gz")
	cat > "$seeds/seed-manifest.json" <<EOF
{
  "migration_version": "$gen",
  "seeds": {
    "klipper": {"seed_commit": "$kc"},
    "nebulaos-klipper-extensions": {"branch": "main", "seed_commit": "$ec"}
  }
}
EOF
	printf '%s %s\n' "$kc" "$ec"
}

run_seed() {
	# $1=seeds $2=apps $3=system  -> runs factory-seed's two git components
	env S04NEBULAOS_FACTORY_SEED_NO_AUTORUN=1 \
		SEEDS="$1" APPS="$2" SYSTEM="$3" LOCKDIR="$WORK/nolock" \
		sh -c ". '$FACTORY_SEED_SCRIPT'; \
			seed_git_app klipper master '$KLIPPER_ORIGIN'; \
			seed_git_app nebulaos-klipper-extensions main '$EXTENSIONS_ORIGIN'; \
			record_known_good; record_initial_generation"
}

run_migrate() {
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 \
		SEEDS="$1" APPS="$2" SYSTEM="$3" LOCKDIR="${4:-$WORK/nolock}" \
		sh -c ". '$MIGRATE_SCRIPT'; start"
}

# --- 1. seeding: real origins, verified ----------------------------------

S1="$WORK/g1-seeds"; A1="$WORK/g1-apps"; Y1="$WORK/g1-system"
mkdir -p "$A1" "$Y1"
build_seed_set "$S1" gen-v1 v1 > "$WORK/g1.txt"
run_seed "$S1" "$A1" "$Y1" > "$WORK/seed1.log" 2>&1

if [ -d "$A1/klipper/.git" ] && [ -d "$A1/nebulaos-klipper-extensions/.git" ]; then
	pass "both Klipper and the extension set seed into the namespace"
else
	fail "seeding did not produce both checkouts"; cat "$WORK/seed1.log"
fi

k_origin=$(git -C "$A1/klipper" remote get-url origin 2>/dev/null)
if [ "$k_origin" = "$KLIPPER_ORIGIN" ]; then
	pass "the seeded Klipper checkout's origin really is $KLIPPER_ORIGIN (official upstream, not a NebulaOS fork)"
else
	fail "seeded Klipper origin is '$k_origin', expected '$KLIPPER_ORIGIN'"
fi
e_origin=$(git -C "$A1/nebulaos-klipper-extensions" remote get-url origin 2>/dev/null)
if [ "$e_origin" = "$EXTENSIONS_ORIGIN" ]; then
	pass "the seeded extensions checkout's origin really is $EXTENSIONS_ORIGIN"
else
	fail "seeded extensions origin is '$e_origin', expected '$EXTENSIONS_ORIGIN'"
fi
if [ "$(git -C "$A1/klipper" symbolic-ref --short HEAD)" = "master" ] && \
   [ "$(git -C "$A1/nebulaos-klipper-extensions" symbolic-ref --short HEAD)" = "main" ]; then
	pass "each checkout is on the branch its own remote actually uses (klipper master, extensions main)"
else
	fail "seeded checkouts are on unexpected branches"
fi
if [ -z "$(git -C "$A1/klipper" status --porcelain)" ] && \
   [ -z "$(git -C "$A1/nebulaos-klipper-extensions" status --porcelain)" ]; then
	pass "both seeded checkouts are pristine (the prebuilt c_helper.so is covered by upstream's own *.so gitignore, so no dirty_exclude is needed any more)"
else
	fail "a seeded checkout is dirty straight out of the archive"
fi

# --- 2. origin verification is real, not decorative ----------------------

BADSEED="$WORK/badseed"; mkdir -p "$BADSEED"
make_extensions_repo "$WORK/src-ext-bad" bad
make_seed_archive "$WORK/src-ext-bad" main "https://example.invalid/wrong.git" \
	"$BADSEED/nebulaos-klipper-extensions.tar.gz" >/dev/null
A2="$WORK/g2-apps"; mkdir -p "$A2"
env S04NEBULAOS_FACTORY_SEED_NO_AUTORUN=1 SEEDS="$BADSEED" APPS="$A2" SYSTEM="$WORK/g2-system" LOCKDIR="$WORK/nolock" \
	sh -c ". '$FACTORY_SEED_SCRIPT'; seed_git_app nebulaos-klipper-extensions main '$EXTENSIONS_ORIGIN'" \
	> "$WORK/badseed.log" 2>&1
if [ ! -e "$A2/nebulaos-klipper-extensions/.git" ] && grep -q "origin" "$WORK/badseed.log"; then
	pass "an extensions archive carrying the wrong origin is REJECTED, leaving no partial state"
else
	fail "a wrong-origin extensions archive was accepted"; cat "$WORK/badseed.log"
fi

# --- 3. known-good and generation records cover all three components -----

if grep -q '"klipper_stack"' "$Y1/known-good.json" && \
   grep -q '"extensions_commit"' "$Y1/known-good.json"; then
	pass "known-good.json records the Klipper stack as a pair, not two unrelated components"
else
	fail "known-good.json does not record the pair"; cat "$Y1/known-good.json" 2>/dev/null
fi
if grep -q '"extensions_commit"' "$Y1/app-generation.json"; then
	pass "app-generation.json records the extensions commit alongside klipper and moonraker"
else
	fail "app-generation.json is missing extensions_commit"; cat "$Y1/app-generation.json" 2>/dev/null
fi

# --- 4. the pair is atomic: a half-seeded stack records no generation ----

S4="$WORK/g4-seeds"; A4="$WORK/g4-apps"; Y4="$WORK/g4-system"
mkdir -p "$A4" "$Y4"
build_seed_set "$S4" gen-v1 v1 >/dev/null
rm -f "$S4/nebulaos-klipper-extensions.tar.gz"
env S04NEBULAOS_FACTORY_SEED_NO_AUTORUN=1 SEEDS="$S4" APPS="$A4" SYSTEM="$Y4" LOCKDIR="$WORK/nolock" \
	sh -c ". '$FACTORY_SEED_SCRIPT'; \
		seed_git_app klipper master '$KLIPPER_ORIGIN'; k=\$?; \
		seed_git_app nebulaos-klipper-extensions main '$EXTENSIONS_ORIGIN'; e=\$?; \
		if [ \"\$k\" = 0 ] && [ \"\$e\" = 0 ]; then record_initial_generation; \
		else echo 'PAIR_INCOMPLETE_NO_GENERATION'; fi" \
	> "$WORK/half.log" 2>&1
if grep -q "PAIR_INCOMPLETE_NO_GENERATION" "$WORK/half.log" && [ ! -e "$Y4/app-generation.json" ]; then
	pass "a half-seeded stack (klipper ok, extensions archive missing) records NO generation, so the next boot retries"
else
	fail "a half-seeded stack recorded a generation"; cat "$WORK/half.log"
fi

# --- 5. migration old -> new, both halves together -----------------------

# Real directories under a real namespace root - not symlinks. validate_app()
# resolves each app path and REJECTS anything landing outside $NEBULAOS_ROOT
# (its traversal/escaping-symlink guard), so a fixture built out of symlinks
# would be testing the guard rather than the lock.
S5="$WORK/g5-seeds"; R5="$WORK/g5-root"; A5="$R5/apps"; Y5="$R5/system"
mkdir -p "$A5" "$Y5"
build_seed_set "$S5" gen-v1 v1 >/dev/null
run_seed "$S5" "$A5" "$Y5" >/dev/null 2>&1
old_k=$(git -C "$A5/klipper" rev-parse HEAD)
old_e=$(git -C "$A5/nebulaos-klipper-extensions" rev-parse HEAD)

# Compose the stack as S05 would, so the migration genuinely destroys a real
# composed link set rather than an imagined one.
compose_ensure "$A5/klipper" "$A5/nebulaos-klipper-extensions" >/dev/null 2>&1
links_before=$(find "$A5/klipper/klippy/extras" -maxdepth 1 -type l | wc -l)
sig_before=$(compose_marker_signature "$A5/klipper/.nebulaos-composed")

new_pins=$(build_seed_set "$S5" gen-v2 v2)
new_k=$(printf '%s' "$new_pins" | awk '{print $1}')
new_e=$(printf '%s' "$new_pins" | awk '{print $2}')
run_migrate "$S5" "$A5" "$Y5" > "$WORK/mig.log" 2>&1

got_k=$(git -C "$A5/klipper" rev-parse HEAD 2>/dev/null)
got_e=$(git -C "$A5/nebulaos-klipper-extensions" rev-parse HEAD 2>/dev/null)
if [ "$got_k" = "$new_k" ] && [ "$got_e" = "$new_e" ] && \
   [ "$got_k" != "$old_k" ] && [ "$got_e" != "$old_e" ]; then
	pass "migration advances BOTH halves of the pair to the new image's pins"
else
	fail "migration did not advance both halves (k=$got_k want=$new_k, e=$got_e want=$new_e)"; cat "$WORK/mig.log"
fi
if grep -q '"migration_version": "gen-v2"' "$Y5/app-generation.json" && \
   grep -q "\"extensions_commit\": \"$new_e\"" "$Y5/app-generation.json"; then
	pass "the recorded generation names the new extensions commit, not just klipper's"
else
	fail "generation record is wrong"; cat "$Y5/app-generation.json"
fi
bdir=$(find "$Y5/migration-backups" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)
if [ -n "$bdir" ] && \
   [ "$(git -C "$bdir/klipper" rev-parse HEAD 2>/dev/null)" = "$old_k" ] && \
   [ "$(git -C "$bdir/nebulaos-klipper-extensions" rev-parse HEAD 2>/dev/null)" = "$old_e" ]; then
	pass "the migration backup holds BOTH pre-migration checkouts - a real rollback source for the pair"
else
	fail "migration backup does not contain both old checkouts"
fi

# --- 6. migration destroys the composition; the S05 slot rebuilds it -----
#
# This is the ordering property Phase 1's analysis called out as newly
# load-bearing: S04 replaces apps/klipper wholesale, which takes the composed
# symlinks with it, and S55klipper must not start before S05 has put them back.

links_after_migrate=$(find "$A5/klipper/klippy/extras" -maxdepth 1 -type l 2>/dev/null | wc -l)
if [ "$links_before" -gt 0 ] && [ "$links_after_migrate" -eq 0 ]; then
	pass "migration really does destroy the composed symlinks (replacing apps/klipper takes them with it)"
else
	fail "expected the composition to be destroyed by migration (before=$links_before after=$links_after_migrate)"
fi

env S05NEBULAOS_ACTIVATE_NO_AUTORUN=1 NEBULAOS_ROOT="$R5" \
	COMPOSE_LIB="$COMPOSE_LIB" CHELPER_LIB="$CHELPER_LIB" LOCKDIR="$WORK/g5-locks" \
	sh -c "mkdir -p '$WORK/g5-locks'; . '$ACTIVATE_SCRIPT'; activate_klipper_stack" \
	> "$WORK/act.log" 2>&1
act_rc=$?

links_after_activate=$(find "$A5/klipper/klippy/extras" -maxdepth 1 -type l 2>/dev/null | wc -l)
sig_after=$(compose_marker_signature "$A5/klipper/.nebulaos-composed")
if [ "$act_rc" -eq 0 ] && [ "$links_after_activate" -eq 3 ]; then
	pass "S05's activate_klipper_stack automatically rebuilds the composition after a migration"
else
	fail "S05 did not rebuild the composition after migration (rc=$act_rc links=$links_after_activate)"; cat "$WORK/act.log"
fi
if [ -n "$sig_after" ] && [ "$sig_after" != "$sig_before" ] && \
   printf '%s' "$sig_after" | grep -q "$new_k" && \
   printf '%s' "$sig_after" | grep -q "$new_e"; then
	pass "the rebuilt composition reflects the NEW pair's commits, not the pre-migration ones"
else
	fail "rebuilt composition signature does not name the new pair (before='$sig_before' after='$sig_after')"
fi
target=$(readlink -f "$A5/klipper/klippy/extras/prtouch_v2.py" 2>/dev/null)
if [ -n "$target" ] && grep -q "v2" "$target" 2>/dev/null; then
	pass "a composed module resolves to the NEW extensions tree's content"
else
	fail "a composed module does not resolve to the new content ($target)"
fi
if [ -f "$A5/klipper/.nebulaos-chelper-verdict.json" ] && \
   grep -q '"status": "ok"' "$A5/klipper/.nebulaos-chelper-verdict.json"; then
	pass "activation publishes a passing chelper verdict for the migrated Klipper tree"
else
	fail "no passing chelper verdict after activation"
fi
if [ -z "$(git -C "$A5/klipper" status --porcelain)" ] && \
   [ -z "$(git -C "$A5/nebulaos-klipper-extensions" status --porcelain)" ]; then
	pass "both checkouts are still pristine after migrate-then-recompose"
else
	fail "a checkout is dirty after migrate-then-recompose"
	git -C "$A5/klipper" status --porcelain
fi

# --- 7. a pre-Phase-1 device gains the extensions component --------------

S7="$WORK/g7-seeds"; A7="$WORK/g7-apps"; Y7="$WORK/g7-system"
mkdir -p "$A7" "$Y7"
build_seed_set "$S7" gen-v2 v2 >/dev/null
# An already-provisioned device from before the no-fork architecture: it has
# klipper, at an older commit, and no extensions checkout at all.
make_klipper_repo "$A7/klipper" old
git -C "$A7/klipper" remote add origin "$KLIPPER_ORIGIN"
echo '{"migration_version": "gen-v1"}' > "$Y7/app-generation.json"
run_migrate "$S7" "$A7" "$Y7" > "$WORK/mig7.log" 2>&1
if [ -d "$A7/nebulaos-klipper-extensions/.git" ] && \
   [ "$(git -C "$A7/nebulaos-klipper-extensions" remote get-url origin)" = "$EXTENSIONS_ORIGIN" ] && \
   grep -q '"migration_version": "gen-v2"' "$Y7/app-generation.json"; then
	pass "a device provisioned before the no-fork architecture gains the extensions component through ordinary migration"
else
	fail "pre-Phase-1 upgrade path did not provision the extensions component"; cat "$WORK/mig7.log"
fi

# --- 8. a failed half blocks the generation -----------------------------

S8="$WORK/g8-seeds"; A8="$WORK/g8-apps"; Y8="$WORK/g8-system"
mkdir -p "$A8" "$Y8"
build_seed_set "$S8" gen-v1 v1 >/dev/null
run_seed "$S8" "$A8" "$Y8" >/dev/null 2>&1
build_seed_set "$S8" gen-v2 v2 >/dev/null
# The extensions archive is corrupt: klipper will migrate, extensions will not.
printf 'not a gzip stream' > "$S8/nebulaos-klipper-extensions.tar.gz"
run_migrate "$S8" "$A8" "$Y8" > "$WORK/mig8.log" 2>&1
recorded8=$(grep -o '"migration_version": "[^"]*"' "$Y8/app-generation.json" 2>/dev/null)
if [ "$recorded8" = '"migration_version": "gen-v1"' ]; then
	pass "when one half of the pair fails to migrate, the generation is NOT advanced (the whole migration retries next boot)"
else
	fail "generation was advanced despite a failed half: $recorded8"; cat "$WORK/mig8.log"
fi
if grep -q "did not migrate as a complete pair" "$WORK/mig8.log"; then
	pass "the partial-pair failure is reported as one pair failure, not two unrelated component lines"
else
	fail "no pair-level failure message"; cat "$WORK/mig8.log"
fi

# --- 9. the shared stack lock holds activation off BOTH halves ----------

# Reuses the real namespace root from the migration test above, so the paths
# validate_app() resolves genuinely live inside $NEBULAOS_ROOT.
L9="$WORK/g9-locks"; R9="$R5"
mkdir -p "$L9"

check_validate() {
	# $1=component $2=path $3=marker -> echoes the recorded decision
	# Fixture directories cannot be root-owned on a developer host, and
	# validate_app checks ownership before it reaches the lock check. The
	# override exists for exactly this and defaults to 0:0 on a real device.
	env S05NEBULAOS_ACTIVATE_NO_AUTORUN=1 NEBULAOS_ROOT="$R9" LOCKDIR="$L9" \
		EXPECTED_APP_OWNER="$(ls -ldn "$R9" | awk '{print $3":"$4}')" \
		COMPOSE_LIB="$COMPOSE_LIB" CHELPER_LIB="$CHELPER_LIB" \
		sh -c ". '$ACTIVATE_SCRIPT'; \
			rm -f '$R9/system/.activation-decisions'; \
			validate_app '$1' '$2' '$3' klipper-stack >/dev/null 2>&1; \
			cat '$R9/system/.activation-decisions' 2>/dev/null"
}

: > "$L9/klipper-stack.lock"
d_k=$(check_validate klipper "$R9/apps/klipper" "klippy/klippy.py")
d_e=$(check_validate nebulaos-klipper-extensions "$R9/apps/nebulaos-klipper-extensions" "nebulaos-extensions.json")
case "$d_k$d_e" in
	*stack_update_in_progress*stack_update_in_progress*)
		pass "the shared klipper-stack lock holds activation off BOTH halves of the pair"
		;;
	*)
		fail "the shared stack lock did not block both halves (klipper='$d_k' extensions='$d_e')"
		;;
esac
rm -f "$L9/klipper-stack.lock"
d_k=$(check_validate klipper "$R9/apps/klipper" "klippy/klippy.py")
if printf '%s' "$d_k" | grep -q "persistent"; then
	pass "clearing the shared lock re-enables activation"
else
	fail "activation stayed blocked after the shared lock was cleared: '$d_k'"
fi

# The extensions marker must be a real required FILE. A directory-only marker
# is the exact bug that let an empty printer_data/config activate over the
# real defaults and leave Klipper crash-looping.
mkdir -p "$R9/apps/empty-ext/extras"
d_e=$(check_validate nebulaos-klipper-extensions "$R9/apps/empty-ext" "nebulaos-extensions.json extras")
if printf '%s' "$d_e" | grep -q "incomplete_or_invalid"; then
	pass "an extensions tree with the directory but no manifest is rejected (the marker is a real required file, not a directory)"
else
	fail "an empty extensions tree was accepted: '$d_e'"
fi

# --- summary --------------------------------------------------------------

echo
echo "klipper-stack-lifecycle-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
