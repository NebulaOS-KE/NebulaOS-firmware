#!/bin/sh
#
# D-01 regression: a persistent deterministic reseed failure must NOT create
# boot-proportional backup growth.
#
# This is the suite that would have caught the amplifier. Before the fix, a
# deterministic failure produced one $BACKUP_ROOT/<UTC timestamp> directory per
# boot, forever, holding a full klipper+moonraker tree each - a real device
# reached ~1.6GB / 95% of a 5.9GB /usr/data. Retention reclaims nothing for
# seven days (nebulaos-retention.sh:279 filters -mtime +7 BEFORE the keep
# count), and emergency_gcode_cleanup deletes the user's print files rather
# than migration backups, so "retention will handle it" was never true.
#
# Every case here drives the REAL S04nebulaos-migrate start() against throwaway
# fixtures. Nothing touches the canonical checkout.
set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
MIGRATE="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate"
MANIFEST_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-seed-manifest.sh"
GATE_LIB_SRC="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh"
MAKE_SEED="$REPO_ROOT/scripts/build/lib/make-seed-archive.sh"

export GIT_AUTHOR_NAME=backup-growth GIT_AUTHOR_EMAIL=bg@nebulaos.invalid
export GIT_COMMITTER_NAME=backup-growth GIT_COMMITTER_EMAIL=bg@nebulaos.invalid

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

W=$(mktemp -d "${TMPDIR:-/tmp}/migration-backup-growth.XXXXXX") || exit 1
[ -n "$W" ] || { echo "FATAL: mktemp gave no path"; exit 1; }
trap 'rm -rf "$W"' EXIT

. "$MAKE_SEED"

KLIPPER_ORIGIN="https://github.com/Klipper3d/klipper.git"
MOONRAKER_ORIGIN="https://github.com/Arksine/moonraker.git"
EXT_ORIGIN="https://github.com/NebulaOS-KE/NebulaOS-klipper-extensions.git"

# Build one complete, valid fixture: apps at "old", seeds at "new".
# $1 = instance name, $2 = extensions branch to put in the manifest ("" = omit)
build_fixture() {
	# NOTE: use ${2-...} (no colon) so an explicitly EMPTY second argument
	# means "omit the branch key", rather than silently falling back to the
	# default the way ${2:-...} would.
	_n="$1"; _extbranch="${2-production}"
	A="$W/$_n-apps"; S="$W/$_n-sys"; SD="$W/$_n-seeds"
	rm -rf "$A" "$S" "$SD"; mkdir -p "$A" "$S" "$SD"
	for spec in "klipper:master:$KLIPPER_ORIGIN" \
	            "nebulaos-klipper-extensions:production:$EXT_ORIGIN" \
	            "moonraker:master:$MOONRAKER_ORIGIN"; do
		c=${spec%%:*}; rest=${spec#*:}; br=${rest%%:*}; org=${rest#*:}
		git init -q -b "$br" "$A/$c" >/dev/null 2>&1
		printf 'old\n' > "$A/$c/f"
		git -C "$A/$c" add -A; git -C "$A/$c" commit -q -m pre
		git -C "$A/$c" remote add origin "$org" 2>/dev/null || \
			git -C "$A/$c" remote set-url origin "$org"
		src="$W/$_n-src-$c"
		rm -rf "$src"; git init -q -b "$br" "$src"
		printf 'new\n' > "$src/f"
		git -C "$src" add -A; git -C "$src" commit -q -m new
		git -C "$src" remote add origin "$org"
		make_seed_archive "$src" "$br" "$org" "$SD/$c.tar.gz" "" >/dev/null 2>&1
	done
	if [ -n "$_extbranch" ]; then
		_extline='"branch": "'"$_extbranch"'", '
	else
		_extline=''
	fi
	cat > "$SD/seed-manifest.json" <<J
{
  "migration_version": "gen-target",
  "components": {
    "klipper": { "branch": "master", "seed_commit": "a" },
    "nebulaos-klipper-extensions": { ${_extline}"seed_commit": "b" },
    "moonraker": { "branch": "master", "seed_commit": "c" }
  }
}
J
}

# Run one simulated boot against a fixture. $1 = instance, $2 = manifest lib
boot() {
	_n="$1"; _lib="${2:-$MANIFEST_LIB}"
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 \
		SEEDS="$W/$_n-seeds" APPS="$W/$_n-apps" SYSTEM="$W/$_n-sys" \
		LOCKDIR="$W/$_n-locks" GATE_LIB="$GATE_LIB_SRC" \
		SEED_MANIFEST_LIB="$_lib" \
		sh -c '. "$0"; start' "$MIGRATE" 2>&1
}

backups() { find "$W/$1-sys/migration-backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l; }

# NOTE on what a pre-fix run looks like: the OLD BACKUP_DIR name had
# per-second UTC granularity, so a fast test loop lands several boots in the
# same second and shares one directory - against pre-fix code this suite sees
# ~3 directories for 20 boots, not 20. That understates the real device, where
# boots are minutes apart and every one gets its own. The assertions therefore
# test PROPORTIONALITY (case 5: does the count change with the boot count?)
# rather than an absolute number, which is the property that actually matters.
N=20

echo "=== Case 1: persistent PRECONDITION failure (no derivable branch) x $N boots ==="
build_fixture c1 ""            # manifest omits the extensions branch
i=0; while [ "$i" -lt "$N" ]; do boot c1 >/dev/null 2>&1; i=$((i+1)); done
n1=$(backups c1)
if [ "$n1" -eq 0 ]; then
	pass "precondition failure x $N boots created ZERO backup directories (storage-neutral)"
else
	fail "precondition failure x $N boots created $n1 backup directories (expected 0)"
fi
if [ ! -f "$W/c1-sys/app-generation.json" ]; then
	pass "precondition failure never records a generation (retries forever, safely)"
else
	fail "precondition failure recorded a generation"
fi
if [ "$(cat "$W/c1-apps/klipper/f" 2>/dev/null)" = "old" ]; then
	pass "precondition failure mutated nothing (klipper still pre-migration)"
else
	fail "precondition failure mutated the klipper tree"
fi

echo ""
echo "=== Case 2: persistent MISSING-LIBRARY failure x $N boots ==="
build_fixture c2 production
i=0; while [ "$i" -lt "$N" ]; do boot c2 "$W/no-such-lib.sh" >/dev/null 2>&1; i=$((i+1)); done
n2=$(backups c2)
if [ "$n2" -eq 0 ]; then
	pass "missing seed-manifest library x $N boots created ZERO backup directories"
else
	fail "missing seed-manifest library x $N boots created $n2 backup directories (expected 0)"
fi

echo ""
echo "=== Case 3: persistent POST-CUTOVER failure x $N boots ==="
# A corrupt moonraker archive passes the zero-write preconditions (the file
# exists) and fails at extraction - AFTER klipper has already been cut over.
# This is the failure class the precondition gate cannot cover, and the one
# the attempt record exists to bound.
build_fixture c3 production
printf 'not a gzip stream\n' > "$W/c3-seeds/moonraker.tar.gz"
i=0; while [ "$i" -lt "$N" ]; do boot c3 >/dev/null 2>&1; i=$((i+1)); done
n3=$(backups c3)
if [ "$n3" -le 1 ]; then
	pass "post-cutover failure x $N boots created $n3 backup director(y/ies) - BOUNDED, not boot-proportional"
else
	fail "post-cutover failure x $N boots created $n3 backup directories - growth is boot-proportional (the amplifier)"
fi
if [ ! -f "$W/c3-sys/app-generation.json" ]; then
	pass "post-cutover failure never records a generation (no silent mixed-generation commit)"
else
	fail "post-cutover failure recorded a generation despite an incomplete stack"
fi
# The genuine pre-migration tree must survive all 20 retries.
if [ "$(cat "$W/c3-sys/migration-backups"/*/klipper/f 2>/dev/null | head -1)" = "old" ]; then
	pass "the FIRST backup still holds the genuine pre-migration klipper tree after $N retries"
else
	fail "the preserved backup no longer holds the pre-migration tree - recovery value was destroyed"
fi

echo ""
echo "=== Case 4: successful migration ==="
build_fixture c4 production
out4=$(boot c4)
n4=$(backups c4)
if [ "$n4" -eq 1 ]; then
	pass "successful migration creates exactly one backup directory"
else
	fail "successful migration created $n4 backup directories (expected 1): $out4"
fi
if [ "$(cat "$W/c4-sys/migration-backups"/*/klipper/f 2>/dev/null)" = "old" ]; then
	pass "the backup holds the pre-migration klipper tree (recovery value preserved)"
else
	fail "the backup does not hold the pre-migration klipper tree"
fi
if [ -f "$W/c4-sys/app-generation.json" ]; then
	pass "successful migration records the generation"
else
	fail "successful migration did not record a generation: $out4"
fi
if [ ! -f "$W/c4-sys/migration-attempt.json" ]; then
	pass "the attempt record is cleared once the generation is recorded"
else
	fail "the attempt record survived a successful migration - the next migration would reuse this backup dir"
fi
# Second boot must be a no-op.
out4b=$(boot c4)
n4b=$(backups c4)
if [ "$n4b" -eq "$n4" ]; then
	pass "a second boot after success creates no additional backup (version-match short-circuit)"
else
	fail "a second boot after success grew backups $n4 -> $n4b"
fi
case "$out4b" in
	*version_match*|*"already matches"*) pass "the second boot reports the version-match short-circuit" ;;
	*) fail "the second boot did not short-circuit: $out4b" ;;
esac

echo ""
echo "=== Case 5: the bound is a CONSTANT, not a function of boot count ==="
# Same deterministic post-cutover failure, half the boots. If growth were
# boot-proportional the two counts would differ.
build_fixture c5 production
printf 'not a gzip stream\n' > "$W/c5-seeds/moonraker.tar.gz"
i=0; while [ "$i" -lt 10 ]; do boot c5 >/dev/null 2>&1; i=$((i+1)); done
n5=$(backups c5)
if [ "$n5" -eq "$n3" ]; then
	pass "10 boots and $N boots of the same failure yield the same backup count ($n5) - constant, not proportional"
else
	fail "10 boots gave $n5 backups but $N boots gave $n3 - growth is boot-proportional"
fi

echo ""
echo "=== Case 6: a diverged live tree is PRESERVED, not discarded ==="
# The retry path reuses the first attempt's backup directory, so the tree on
# disk cannot simply be moved on top of it. It used to be discarded outright,
# on the assumption it was always the previous attempt's own replacement and
# therefore reproducible from the seed. That assumption is false: the
# extensions checkout is a Moonraker update_manager git_repo and klipper is a
# channel-dev slot, so a user can legitimately commit there between a failed
# attempt and its retry - and that work exists in no backup.
build_fixture c6 production
printf 'not a gzip stream\n' > "$W/c6-seeds/moonraker.tar.gz"   # deterministic post-cutover failure
boot c6 >/dev/null 2>&1                                          # boot 1: klipper cuts over, moonraker fails
# Simulate what Mainsail's update manager (or the user) does between boots.
printf 'user work\n' > "$W/c6-apps/nebulaos-klipper-extensions/user_module.py"
git -C "$W/c6-apps/nebulaos-klipper-extensions" add -A
git -C "$W/c6-apps/nebulaos-klipper-extensions" commit -q -m "user commit between attempts"
_user_head=$(git -C "$W/c6-apps/nebulaos-klipper-extensions" rev-parse HEAD)
boot c6 >/dev/null 2>&1                                          # boot 2: the retry
if find "$W/c6-sys/migration-backups" -name user_module.py 2>/dev/null | grep -q .; then
	pass "a user commit made between attempts survives the retry (preserved in a backup)"
else
	fail "a user commit made between attempts was DESTROYED by the retry - it exists nowhere"
fi
if find "$W/c6-sys/migration-backups" -maxdepth 2 -name '*.diverged-*' -type d 2>/dev/null | grep -q .; then
	pass "the diverged tree is preserved under an explicit .diverged-<timestamp> name"
else
	fail "no .diverged-* preservation directory was created"
fi
n6=$(backups c6)
if [ "$n6" -le 1 ]; then
	pass "preserving the diverged tree did not create a second backup directory ($n6)"
else
	fail "preserving the diverged tree broke the bound: $n6 directories"
fi
# And a repeat of the same divergence must not accumulate copies.
boot c6 >/dev/null 2>&1
d6=$(find "$W/c6-sys/migration-backups" -maxdepth 2 -name '*.diverged-*' -type d 2>/dev/null | wc -l)
if [ "$d6" -le 1 ]; then
	pass "repeating the same divergence does not accumulate duplicate preserved copies ($d6)"
else
	fail "duplicate preserved copies accumulated: $d6"
fi

echo ""
echo "=== Case 7: absent extensions + underivable branch is caught by the gate ==="
# A pre-Phase-1 device has no extensions checkout; the migration PROVISIONS it.
# The precondition gate used to skip both its archive check and its branch
# check when the checkout was absent, so this device bypassed the gate
# entirely and cut klipper over against extensions that could never arrive.
build_fixture c7 ""
rm -rf "$W/c7-apps/nebulaos-klipper-extensions"
i=0; while [ "$i" -lt 5 ]; do boot c7 >/dev/null 2>&1; i=$((i+1)); done
n7=$(backups c7)
if [ "$n7" -eq 0 ]; then
	pass "absent extensions + underivable branch creates ZERO backup directories"
else
	fail "absent extensions + underivable branch created $n7 backup directories - the gate was bypassed"
fi
if [ "$(cat "$W/c7-apps/klipper/f" 2>/dev/null)" = "old" ]; then
	pass "absent extensions + underivable branch does not cut klipper over"
else
	fail "klipper was cut over on a device whose extensions could never be provisioned"
fi

echo ""
echo "=== Case 8: the attempt record self-heals and stays bounded ==="
build_fixture c8 production
printf 'not a gzip stream\n' > "$W/c8-seeds/moonraker.tar.gz"
boot c8 >/dev/null 2>&1
printf 'this is not json' > "$W/c8-sys/migration-attempt.json"    # corrupt it
i=0; while [ "$i" -lt 5 ]; do boot c8 >/dev/null 2>&1; i=$((i+1)); done
n8=$(backups c8)
if [ "$n8" -le 2 ]; then
	pass "a corrupt attempt record self-heals and growth stays bounded ($n8)"
else
	fail "a corrupt attempt record resumed unbounded growth: $n8 directories"
fi
# Now delete the directory the record names, as retention eventually would.
rm -rf "$W/c8-sys/migration-backups"/*
i=0; while [ "$i" -lt 5 ]; do boot c8 >/dev/null 2>&1; i=$((i+1)); done
n8b=$(backups c8)
if [ "$n8b" -le 1 ]; then
	pass "a pruned attempt directory is re-minted once, not once per boot ($n8b)"
else
	fail "a pruned attempt directory resumed unbounded growth: $n8b"
fi

echo ""
echo "=== Case 9: a new target version does not disturb the old backup ==="
build_fixture c9 production
printf 'not a gzip stream\n' > "$W/c9-seeds/moonraker.tar.gz"
boot c9 >/dev/null 2>&1
_a_dir=$(find "$W/c9-sys/migration-backups" -mindepth 1 -maxdepth 1 -type d | head -1)
_a_klipper=$(cat "$_a_dir/klipper/f" 2>/dev/null)
sed -i 's/"gen-target"/"gen-target-2"/' "$W/c9-seeds/seed-manifest.json"
# The backup directory name has per-second UTC granularity, so two boots
# inside the same second would share one directory and make this assertion
# meaningless. Real devices boot minutes apart; the test has to wait.
sleep 1.1
boot c9 >/dev/null 2>&1
if [ -d "$_a_dir" ] && [ "$(cat "$_a_dir/klipper/f" 2>/dev/null)" = "$_a_klipper" ]; then
	pass "the previous version's backup survives a target-version change untouched"
else
	fail "a target-version change disturbed the previous version's backup"
fi
n9=$(backups c9)
if [ "$n9" -eq 2 ]; then
	pass "a new target version creates exactly one additional backup directory ($n9 total)"
else
	fail "a new target version produced $n9 backup directories (expected 2)"
fi

echo ""
echo "=== Case 10: the duplicate branch honours clean AND identifiable ==="
# The dedup arm ends in rm -rf, so it must apply the same two-part proof the
# discard arm does. Keying on HEAD alone would destroy uncommitted edits
# sitting on an already-preserved commit - and would make the promise in
# docs/NEBULAOS_UPDATE_OWNERSHIP.md ("only removed when provably identical to
# the incoming seed AND clean") false. Reaching this branch needs the SAME
# HEAD to recur, so the commit is replayed with fixed author/committer dates.
build_fixture c10 production
printf 'not a gzip stream\n' > "$W/c10-seeds/moonraker.tar.gz"
boot c10 >/dev/null 2>&1
_ext10="$W/c10-apps/nebulaos-klipper-extensions"
replay_commit() {
	printf 'user work\n' > "$_ext10/replayed.py"
	git -C "$_ext10" add -A
	GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" \
		git -C "$_ext10" commit -q -m "replayed user commit"
	git -C "$_ext10" rev-parse HEAD
}
_h1=$(replay_commit)
boot c10 >/dev/null 2>&1              # preserves the diverged tree
_h2=$(replay_commit)                  # same content+dates => same SHA
if [ "$_h1" = "$_h2" ]; then
	pass "the fixture reproduces an identical HEAD across retries (the dedup branch is reachable)"
else
	fail "could not reproduce an identical HEAD ($_h1 vs $_h2) - the dedup branch would not be exercised"
fi
# Now make it DIRTY at that already-preserved HEAD. The dedup arm must refuse.
printf 'uncommitted edit that exists nowhere else\n' > "$_ext10/uncommitted.txt"
boot c10 >/dev/null 2>&1
if find "$W/c10-sys/migration-backups" -name uncommitted.txt 2>/dev/null | grep -q .; then
	pass "a DIRTY tree at an already-preserved HEAD is preserved, not deduped away"
else
	fail "a dirty tree at an already-preserved HEAD was destroyed - the dedup branch ignores dirtiness"
fi
n10=$(backups c10)
if [ "$n10" -le 1 ]; then
	pass "honouring dirtiness in the dedup branch did not break the bound ($n10)"
else
	fail "the bound broke: $n10 backup directories"
fi
# A non-git $dest must not be treated as a duplicate of another non-git copy.
rm -rf "$_ext10/.git"
boot c10 >/dev/null 2>&1
if [ "$(backups c10)" -le 1 ]; then
	pass "an unidentifiable (non-git) tree does not resurrect unbounded growth"
else
	fail "an unidentifiable tree broke the bound"
fi

echo ""
echo "migration-backup-growth-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
