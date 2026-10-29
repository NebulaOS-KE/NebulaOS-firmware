#!/bin/sh
#
# The Extensions branch contract, tested under DIVERGENCE (audit finding F-06).
#
# THE DEFECT. The build archives the extension set with its local branch
# forced to $KLIPPER_EXTENSIONS_BRANCH ("production" - the deployed-runtime
# branch). Three on-device call sites asserted the literal "main" - the
# DEVELOPMENT branch. seed_git_app()/reseed_git_app()/seed_missing_extensions()
# treat that argument as an ASSERTION on the extracted checkout's branch NAME,
# not as a checkout target, so every production archive was rejected and
# deleted: the extensions app directory was never created, no app generation
# was ever recorded, and every later boot re-ran a full migration.
#
# WHY THIS SUITE EXISTS AND WHY IT FORCES DIVERGENCE. main and production
# currently point at the same commit, so any test run against the real repo
# would pass whether or not the bug were fixed - commit equality is irrelevant
# to a branch-NAME comparison. Every fixture below therefore pins
#   production = commit A   (the shipping pin)
#   main       = commit B   (development, ahead)
# so that a path silently using "main" resolves to different CONTENT and is
# caught, not merely a different string.
#
# Everything runs in temporary bare/working repositories. No canonical
# repository is read for mutation or written to.
#
# Usage: sh tests/extensions-branch-contract-tests.sh

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

FACTORY_SEED="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-factory-seed"
MIGRATE="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate"
MANIFEST_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-seed-manifest.sh"
GATE_LIB_SRC="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh"
MAKE_SEED="$REPO_ROOT/scripts/build/lib/make-seed-archive.sh"
DEPS="$REPO_ROOT/manifests/dependencies.conf"

for f in "$FACTORY_SEED" "$MIGRATE" "$MANIFEST_LIB" "$MAKE_SEED" "$DEPS"; do
	[ -f "$f" ] || { echo "SKIP: $f not present"; exit 0; }
done

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

W=$(mktemp -d "${TMPDIR:-/tmp}/extensions-branch-contract.XXXXXX") \
	|| { echo "FAIL: could not create a temporary directory"; exit 1; }
[ -n "${W:-}" ] && [ -d "$W" ] || { echo "FAIL: mktemp produced an unusable path"; exit 1; }
cleanup() { [ -n "${W:-}" ] && [ -d "$W" ] && rm -rf "$W"; return 0; }
trap cleanup EXIT INT TERM

export GIT_AUTHOR_NAME=branch-contract GIT_AUTHOR_EMAIL=bc@nebulaos.invalid
export GIT_COMMITTER_NAME=branch-contract GIT_COMMITTER_EMAIL=bc@nebulaos.invalid

EXT_ORIGIN="https://github.com/NebulaOS-KE/NebulaOS-klipper-extensions.git"

. "$MANIFEST_LIB"

# ======================================================================
# Section A: the block-scoped manifest reader
# ======================================================================
# The single most likely way to get this change wrong is a FLAT key lookup:
# S04nebulaos-migrate's own json_get() greps the whole file and takes
# `head -1`, which for "branch" returns klipper's "master" no matter which
# component was asked about. Assert the collision directly.

cat > "$W/manifest-real-shape.json" <<'J'
{
  "migration_version": "gen-test",
  "components": {
    "klipper": {
      "format": "git_repo_archive_real_history",
      "branch": "master",
      "seed_commit": "aaaa"
    },
    "nebulaos-klipper-extensions": {
      "format": "git_repo_archive_real_history",
      "branch": "production",
      "seed_commit": "bbbb"
    },
    "moonraker": {
      "branch": "master"
    }
  }
}
J

v=$(seed_manifest_branch "$W/manifest-real-shape.json" nebulaos-klipper-extensions)
if [ "$v" = "production" ]; then
	pass "reader: extensions resolves to 'production', not klipper's 'master' (flat-grep collision avoided)"
else
	fail "reader: extensions resolved to '$v', expected 'production'"
fi
v=$(seed_manifest_branch "$W/manifest-real-shape.json" klipper)
[ "$v" = "master" ] && pass "reader: klipper still resolves to 'master'" \
                    || fail "reader: klipper resolved to '$v', expected 'master'"

printf '{ "components": { "nebulaos-klipper-extensions": { "seed_commit": "x" } } }\n' > "$W/m-nobranch.json"
printf 'this is not json at all\n' > "$W/m-malformed.json"
for case in "absent:$W/does-not-exist.json" "no-branch-field:$W/m-nobranch.json" "malformed:$W/m-malformed.json"; do
	label=${case%%:*}; file=${case#*:}
	out=$(seed_manifest_branch "$file" nebulaos-klipper-extensions); rc=$?
	if [ $rc -ne 0 ] && [ -z "$out" ]; then
		pass "reader fails closed on a $label manifest (no value, non-zero)"
	else
		fail "reader on a $label manifest returned '$out' rc=$rc - must fail closed"
	fi
done

# ======================================================================
# Section B: divergence fixture - production=A, main=B
# ======================================================================
SRC="$W/ext-src"
git init -q -b production "$SRC"
mkdir -p "$SRC/extras"
printf 'A\n' > "$SRC/extras/marker.py"
git -C "$SRC" add -A
git -C "$SRC" commit -q -m "A - the shipping pin, production points here"
COMMIT_A=$(git -C "$SRC" rev-parse HEAD)
git -C "$SRC" checkout -q -b main
printf 'B\n' > "$SRC/extras/marker.py"
git -C "$SRC" add -A
git -C "$SRC" commit -q -m "B - development moved on"
COMMIT_B=$(git -C "$SRC" rev-parse HEAD)
git -C "$SRC" checkout -q production
git -C "$SRC" remote add origin "$EXT_ORIGIN"

if [ "$COMMIT_A" != "$COMMIT_B" ]; then
	pass "fixture: production ($(echo "$COMMIT_A" | cut -c1-8)) and main ($(echo "$COMMIT_B" | cut -c1-8)) genuinely diverge"
else
	fail "fixture: production and main are the same commit - the whole suite would be vacuous"
fi

SEEDS="$W/seeds"; mkdir -p "$SEEDS"
. "$MAKE_SEED"
make_seed_archive "$SRC" "production" "$EXT_ORIGIN" \
	"$SEEDS/nebulaos-klipper-extensions.tar.gz" "" >/dev/null 2>&1

mkdir -p "$W/peek"
gzip -dc "$SEEDS/nebulaos-klipper-extensions.tar.gz" | tar -xo -C "$W/peek"
arch_branch=$(git -C "$W/peek" symbolic-ref --short HEAD 2>/dev/null)
arch_head=$(git -C "$W/peek" rev-parse HEAD 2>/dev/null)
[ "$arch_branch" = "production" ] && pass "archive: local branch is 'production' (what the build produces)" \
                                  || fail "archive: local branch is '$arch_branch', expected 'production'"
[ "$arch_head" = "$COMMIT_A" ] && pass "archive: content is commit A (the pin), not main's B" \
                               || fail "archive: HEAD is $arch_head, expected A=$COMMIT_A"

write_manifest() {
	cat > "$SEEDS/seed-manifest.json" <<J
{
  "migration_version": "gen-test",
  "components": {
    "klipper": { "branch": "master", "seed_commit": "aaaa" },
    "nebulaos-klipper-extensions": { "branch": "$1", "seed_commit": "$COMMIT_A" },
    "moonraker": { "branch": "master", "seed_commit": "cccc" }
  }
}
J
}
write_manifest production

# Drive the REAL factory-seed call path, with the real functions.
run_factory_seed() {
	_apps="$1"
	env S04NEBULAOS_FACTORY_SEED_NO_AUTORUN=1 SEEDS="$SEEDS" APPS="$_apps" \
		SYSTEM="$W/system" GATE_LIB="$GATE_LIB_SRC" \
		SEED_MANIFEST_LIB="$MANIFEST_LIB" \
		sh -c '
			. "$0"
			b=$(seed_manifest_branch "$SEEDS/seed-manifest.json" nebulaos-klipper-extensions)
			[ -n "$b" ] || { echo "NO_BRANCH"; exit 9; }
			seed_git_app nebulaos-klipper-extensions "$b" "$1"
		' "$FACTORY_SEED" "$EXT_ORIGIN" 2>&1
}

A1="$W/apps1"; mkdir -p "$A1"
out=$(run_factory_seed "$A1"); rc=$?
if [ $rc -eq 0 ] && [ -e "$A1/nebulaos-klipper-extensions/.git" ]; then
	pass "factory seed ACCEPTS the production archive (F-06: previously rejected as 'expected main')"
else
	fail "factory seed rejected the production archive (rc=$rc): $out"
fi
dep_head=$(git -C "$A1/nebulaos-klipper-extensions" rev-parse HEAD 2>/dev/null)
dep_branch=$(git -C "$A1/nebulaos-klipper-extensions" symbolic-ref --short HEAD 2>/dev/null)
[ "$dep_head" = "$COMMIT_A" ] && pass "deployed copy resolves to commit A (the pin), not main's B" \
                              || fail "deployed HEAD is $dep_head, expected A=$COMMIT_A"
[ "$dep_branch" = "production" ] && pass "deployed copy is on branch 'production'" \
                                 || fail "deployed copy is on '$dep_branch', expected 'production'"

# Advancing main must not change deployed state.
git -C "$SRC" checkout -q main
printf 'B2\n' > "$SRC/extras/marker.py"
git -C "$SRC" add -A
git -C "$SRC" commit -q -m "main advances again"
git -C "$SRC" checkout -q production
after_head=$(git -C "$A1/nebulaos-klipper-extensions" rev-parse HEAD 2>/dev/null)
[ "$after_head" = "$COMMIT_A" ] && pass "advancing main leaves the deployed copy untouched at A" \
                                || fail "deployed copy moved to $after_head after main advanced"

# A genuine branch mismatch must still fail closed.
BAD="$W/bad-src"
git init -q -b somethingelse "$BAD"; printf 'x\n' > "$BAD/f"; git -C "$BAD" add -A
git -C "$BAD" commit -q -m x; git -C "$BAD" remote add origin "$EXT_ORIGIN"
mkdir -p "$W/seeds-bad"
SEEDS_KEEP=$SEEDS; SEEDS="$W/seeds-bad"
make_seed_archive "$BAD" "somethingelse" "$EXT_ORIGIN" \
	"$SEEDS/nebulaos-klipper-extensions.tar.gz" "" >/dev/null 2>&1
write_manifest production
A2="$W/apps2"; mkdir -p "$A2"
out=$(run_factory_seed "$A2"); rc=$?
if [ $rc -ne 0 ] && [ ! -e "$A2/nebulaos-klipper-extensions/.git" ]; then
	pass "a genuine branch mismatch still FAILS CLOSED and leaves no partial checkout"
else
	fail "branch mismatch was accepted (rc=$rc) - the assertion has been weakened"
fi
SEEDS=$SEEDS_KEEP

# A wrong origin must still fail closed (the origin is deliberately NOT derived).
WRONG="$W/wrong-origin-src"
git init -q -b production "$WRONG"; printf 'x\n' > "$WRONG/f"; git -C "$WRONG" add -A
git -C "$WRONG" commit -q -m x
git -C "$WRONG" remote add origin "https://github.com/someone-else/not-our-extensions.git"
mkdir -p "$W/seeds-wrong"
SEEDS_KEEP=$SEEDS; SEEDS="$W/seeds-wrong"
make_seed_archive "$WRONG" "production" \
	"https://github.com/someone-else/not-our-extensions.git" \
	"$SEEDS/nebulaos-klipper-extensions.tar.gz" "" >/dev/null 2>&1
write_manifest production
A3="$W/apps3"; mkdir -p "$A3"
out=$(run_factory_seed "$A3"); rc=$?
if [ $rc -ne 0 ] && [ ! -e "$A3/nebulaos-klipper-extensions/.git" ]; then
	pass "right branch + WRONG ORIGIN still fails closed (origin stays a literal on purpose)"
else
	fail "a wrong-origin archive was accepted (rc=$rc)"
fi
SEEDS=$SEEDS_KEEP

# Manifest fail-closed at the real call site, not just in the reader.
for bad in absent no-branch; do
	case $bad in
		absent)    mv "$SEEDS/seed-manifest.json" "$SEEDS/seed-manifest.json.off" ;;
		no-branch) printf '{ "components": { "nebulaos-klipper-extensions": { "seed_commit": "x" } } }\n' \
		             > "$SEEDS/seed-manifest.json" ;;
	esac
	AX="$W/apps-$bad"; mkdir -p "$AX"
	out=$(run_factory_seed "$AX"); rc=$?
	if [ $rc -ne 0 ] && [ ! -e "$AX/nebulaos-klipper-extensions/.git" ]; then
		pass "call site refuses to seed when the manifest is $bad (no guessed branch, no partial checkout)"
	else
		fail "call site seeded with a $bad manifest (rc=$rc) - it guessed a branch"
	fi
	[ "$bad" = absent ] && mv "$SEEDS/seed-manifest.json.off" "$SEEDS/seed-manifest.json"
done
write_manifest production

# ======================================================================
# Section C: seed_missing_extensions, on its REAL trigger
# ======================================================================
# S04nebulaos-migrate:1242 reaches this function only when the extensions
# .git is absent - the pre-no-fork upgrade path. Test it there, not in
# isolation.
A4="$W/apps4"; mkdir -p "$A4/klipper"
out=$(env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$SEEDS" APPS="$A4" \
	SYSTEM="$W/system4" GATE_LIB="$GATE_LIB_SRC" SEED_MANIFEST_LIB="$MANIFEST_LIB" \
	sh -c '. "$0"; seed_missing_extensions' "$MIGRATE" 2>&1); rc=$?
if [ $rc -eq 0 ] && [ -e "$A4/nebulaos-klipper-extensions/.git" ]; then
	pass "seed_missing_extensions provisions from the production archive"
else
	fail "seed_missing_extensions failed on a valid production archive (rc=$rc): $out"
fi
smx_head=$(git -C "$A4/nebulaos-klipper-extensions" rev-parse HEAD 2>/dev/null)
[ "$smx_head" = "$COMMIT_A" ] && pass "seed_missing_extensions lands on commit A (the pin)" \
                              || fail "seed_missing_extensions HEAD is $smx_head, expected A"

# ======================================================================
# Section D: no unnecessary reseed once a generation is recorded
# ======================================================================
# The F-06 consequence was that a rejected seed meant no app generation was
# ever recorded, so every boot re-ran a full migration - creating a new
# timestamped backup of klipper and moonraker each time. With seeding fixed,
# a matching generation must short-circuit before any backup is created.
A5="$W/apps5"; S5="$W/system5"; mkdir -p "$A5" "$S5"
for c in klipper nebulaos-klipper-extensions moonraker; do
	git init -q -b master "$A5/$c" >/dev/null 2>&1
	printf 'x\n' > "$A5/$c/f"; git -C "$A5/$c" add -A
	git -C "$A5/$c" commit -q -m seed
done
cat > "$S5/app-generation.json" <<J
{ "migration_version": "gen-test", "recorded_at": "now" }
J
out=$(env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$SEEDS" APPS="$A5" SYSTEM="$S5" \
	LOCKDIR="$W/locks5" GATE_LIB="$GATE_LIB_SRC" SEED_MANIFEST_LIB="$MANIFEST_LIB" \
	sh -c '. "$0"; start' "$MIGRATE" 2>&1)
backups=$(find "$S5/migration-backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
if [ "$backups" -eq 0 ]; then
	pass "a matching generation short-circuits migration: no backup directory created"
else
	fail "migration created $backups backup directory/ies despite a matching generation"
fi
case "$out" in
	*version_match*|*"already matches"*) pass "migration reports the version-match short-circuit" ;;
	*) fail "migration did not take the version-match path: $out" ;;
esac

# ======================================================================
# Section E: the migrate RESEED site must fail CLOSED too
# ======================================================================
# Section B covers the factory-seed site. The migrate reseed site
# (S04nebulaos-migrate, the "extensions .git already exists" branch) is a
# different code path with its own state, and it is the one that got this
# wrong: an early version of the F-06 fix logged an error and ran a bare
# `false` whose status nothing consumed, so extensions_ok stayed 1, the
# pair guard never fired, record_generation ran, and the boot reported
# "completed" while the extensions half had never been reseeded. The next
# boot then took the version-match early return and never retried - a
# silent, permanent new-Klipper-against-old-extensions divergence.
#
# The assertion that catches that is NOT the exit status. It is that no
# app-generation.json gets written.
A6="$W/apps6"; S6="$W/system6"; mkdir -p "$A6" "$S6"
for c in klipper nebulaos-klipper-extensions moonraker; do
	git init -q -b master "$A6/$c" >/dev/null 2>&1
	printf 'old\n' > "$A6/$c/f"
	git -C "$A6/$c" add -A
	git -C "$A6/$c" commit -q -m "pre-migration"
done

# Real archives for the two halves that MUST succeed, so the only thing that
# can fail is the extensions branch derivation. The origins have to be the
# exact literals S04nebulaos-migrate passes to reseed_git_app, otherwise
# those halves fail their own origin assertion, klipper_ok goes to 0, and no
# generation is recorded for a reason that has nothing to do with what this
# section is testing - which would make every assertion below pass
# vacuously. (It did, on the first attempt.)
KLIPPER_ORIGIN6="https://github.com/Klipper3d/klipper.git"
MOONRAKER_ORIGIN6="https://github.com/Arksine/moonraker.git"
SEEDS6="$W/seeds6"; mkdir -p "$SEEDS6"
for spec in "klipper:$KLIPPER_ORIGIN6" "moonraker:$MOONRAKER_ORIGIN6"; do
	c=${spec%%:*}; o=${spec#*:}
	src="$W/${c}-src6"
	git init -q -b master "$src"; printf 'new\n' > "$src/f"
	git -C "$src" add -A; git -C "$src" commit -q -m new
	git -C "$src" remote add origin "$o"
	make_seed_archive "$src" master "$o" "$SEEDS6/$c.tar.gz" "" >/dev/null 2>&1
	# The on-disk pre-migration checkout must carry the same origin, or
	# reseed_git_app rejects it before the extensions half is even reached.
	git -C "$A6/$c" remote add origin "$o" 2>/dev/null || \
		git -C "$A6/$c" remote set-url origin "$o"
done
cp "$SEEDS/nebulaos-klipper-extensions.tar.gz" "$SEEDS6/"

# Sanity: the fixture must be capable of recording a generation at all.
# Without this, "no generation recorded" proves nothing.
cat > "$SEEDS6/seed-manifest.json" <<'J'
{
  "migration_version": "gen-test-e",
  "components": {
    "klipper": { "branch": "master", "seed_commit": "a" },
    "nebulaos-klipper-extensions": { "branch": "production", "seed_commit": "b" },
    "moonraker": { "branch": "master", "seed_commit": "c" }
  }
}
J
rm -f "$S6/app-generation.json"
_ctl=$(env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$SEEDS6" APPS="$A6" SYSTEM="$S6" \
	LOCKDIR="$W/locks6" GATE_LIB="$GATE_LIB_SRC" SEED_MANIFEST_LIB="$MANIFEST_LIB" \
	sh -c '. "$0"; start' "$MIGRATE" 2>&1)
if [ -f "$S6/app-generation.json" ]; then
	pass "control: with a complete manifest this fixture DOES record a generation (the checks below are not vacuous)"
else
	fail "control: this fixture cannot record a generation even when everything is valid, so the fail-closed assertions below would pass for the wrong reason: $_ctl"
fi

# $1 overrides SEED_MANIFEST_LIB so the lib-absent case can point it at a
# path that does not exist - the scripts source it tolerantly on purpose, so
# this is a REACHABLE production state, not a synthetic one.
run_migrate6() {
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$SEEDS6" APPS="$A6" SYSTEM="$S6" \
		LOCKDIR="$W/locks6" GATE_LIB="$GATE_LIB_SRC" \
		SEED_MANIFEST_LIB="${1:-$MANIFEST_LIB}" \
		sh -c '. "$0"; start' "$MIGRATE" 2>&1
}

# The three cases are NOT equivalent, and only two of them reach the reseed
# site. Spelled out because a previous version of this section passed for the
# wrong reason and the difference is invisible from the assertion text:
#
#   no-branch  - manifest present and well formed, extensions object simply
#                has no "branch" key. Reaches the reseed site; branch empty.
#   lib-absent - manifest fully valid, but /etc/nebulaos-seed-manifest.sh is
#                missing, so seed_manifest_branch() is never defined. Reaches
#                the reseed site; branch empty. This is the one that actually
#                happens in the field if the library is dropped from the
#                overlay, and it is why 06-verify.sh checks for the file.
#   absent     - no manifest at all. Does NOT reach the reseed site: start()
#                returns at the `[ ! -f "$SEEDS/seed-manifest.json" ]` guard
#                (S04nebulaos-migrate:1247) with action skipped:no_manifest.
#                Kept because "no manifest must never record a generation" is
#                still worth pinning - but it proves nothing about the reseed
#                site, so the reseed-specific assertions below skip it.
for bad in no-branch lib-absent absent; do
	rm -f "$S6/app-generation.json"
	case $bad in
		no-branch) cat > "$SEEDS6/seed-manifest.json" <<'J'
{
  "migration_version": "gen-test-e",
  "components": {
    "klipper": { "branch": "master", "seed_commit": "a" },
    "nebulaos-klipper-extensions": { "seed_commit": "b" },
    "moonraker": { "branch": "master", "seed_commit": "c" }
  }
}
J
		;;
		lib-absent) cat > "$SEEDS6/seed-manifest.json" <<'J'
{
  "migration_version": "gen-test-e",
  "components": {
    "klipper": { "branch": "master", "seed_commit": "a" },
    "nebulaos-klipper-extensions": { "branch": "production", "seed_commit": "b" },
    "moonraker": { "branch": "master", "seed_commit": "c" }
  }
}
J
		;;
		absent) rm -f "$SEEDS6/seed-manifest.json" ;;
	esac
	rm -f "$S6/diagnostics/migration-state.json"
	# The control run above performs a REAL successful migration, so the
	# fixture already has one backup directory and an already-cut-over
	# klipper. Measure the DELTA this failing run causes, not absolutes.
	_pre_backups=$(find "$S6/migration-backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
	_pre_klipper=$(cat "$A6/klipper/f" 2>/dev/null)
	if [ "$bad" = lib-absent ]; then
		out=$(run_migrate6 "$W/no-such-seed-manifest-lib.sh")
	else
		out=$(run_migrate6)
	fi
	if [ -f "$S6/app-generation.json" ]; then
		fail "migrate reseed with a $bad manifest RECORDED A GENERATION - it reported success while the extensions half was never reseeded"
	else
		pass "migrate reseed with a $bad manifest records no generation (fails closed, will retry)"
	fi
	if [ "$bad" != absent ]; then
		# D-01: these two cases are now caught by the ZERO-WRITE precondition
		# gate, before any component is touched. That is strictly stronger
		# than the previous behaviour, where klipper was already cut over by
		# the time the extensions branch was found to be underivable. The
		# assertions below therefore pin "nothing happened at all", not just
		# "the pair was reported incomplete".
		case "$out" in
			*"migration NOT STARTED"*|*"PRECONDITION FAILED"*)
				pass "migrate with a $bad manifest refuses to start (precondition gate, before any mutation)" ;;
			*) fail "migrate with a $bad manifest did not refuse at the precondition gate: $out" ;;
		esac
		_ds="$S6/diagnostics/migration-state.json"
		if grep -q '"migration_action": "incomplete:preconditions"' "$_ds" 2>/dev/null; then
			pass "migrate with a $bad manifest records migration_action=incomplete:preconditions"
		else
			fail "migrate with a $bad manifest did not record incomplete:preconditions: $(cat "$_ds" 2>/dev/null)"
		fi
		# THE amplifier assertion: a deterministic failure must cost zero
		# storage. No backup directory may exist at all.
		_nb=$(find "$S6/migration-backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
		if [ "$_nb" -eq "$_pre_backups" ]; then
			pass "migrate with a $bad manifest created NO new backup directory (storage-neutral retry)"
		else
			fail "migrate with a $bad manifest grew backups $_pre_backups -> $_nb - the amplifier is back"
		fi
		# And nothing was cut over this run.
		if [ "$(cat "$A6/klipper/f" 2>/dev/null)" = "$_pre_klipper" ]; then
			pass "migrate with a $bad manifest left klipper untouched (no half-migrated stack)"
		else
			fail "migrate with a $bad manifest cut klipper over despite an unsatisfiable precondition"
		fi
	fi
done
write_manifest production

# KNOWN LIMITATION, deliberately not asserted here, and made MORE reachable by
# the fail-closed fix above - stated plainly rather than buried.
#
# S04nebulaos-migrate:1301 creates BACKUP_DIR before any component is
# attempted, and the generation is not advanced on failure, with no failure
# counter and no backoff. reseed_git_app() moves the previous checkout into
# that directory as it cuts each component over, so every boot that fails
# part-way leaves a full copy of whatever DID succeed behind.
# nebulaos-retention.sh:203 only ever considers entries older than -mtime +7
# (MIGRATION_BACKUP_KEEP=2 at :240 applies within that set), so nothing is
# reclaimed for the first seven days.
#
# branch_undeterminable is a deterministic, image-wide condition: if the
# manifest or the library is wrong in an image, it is wrong on every boot of
# every device flashed with it. The pre-fix fail-OPEN bug recorded a
# generation and so stopped after one boot - wrong, but self-limiting on
# disk. Failing closed is correct and unbounded. A real device has already
# been observed at ~1.6GB/95% of 5.9GB from this amplifier.
#
# RESOLVED 2026-09-23 (D-01). The amplifier described above is fixed: a
# zero-write precondition gate runs before anything is touched, BACKUP_DIR is
# created lazily at the first real cutover, and a persisted attempt record
# makes a retry reuse that directory instead of minting a new one. Growth is
# now bounded at one directory per target migration version rather than one
# per boot. See tests/migration-backup-growth-tests.sh, which drives 20
# simulated boots per failure class and asserts the bound is constant.

echo ""
echo "extensions-branch-contract-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
