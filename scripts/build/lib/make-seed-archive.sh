#!/bin/sh
#
# NebulaOS auto-updates-camera-complete mission (2026-07-28, see
# docs/NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md). Shared by
# scripts/build/04-cross-compile-app-stack.sh (real build - packages
# vendor/klipper and vendor/moonraker) and tests/factory-seed-git-tests.sh
# (offline fixture repos) - kept in its own file specifically so the tests
# exercise this exact function, not a second/parallel reimplementation of
# its validation rules.
#
# PRIOR APPROACH (removed): each vendor checkout was flattened into a
# single synthetic orphan commit ("NebulaOS factory seed snapshot of
# <branch> @ <true_commit>") before bundling, because a plain
# `git bundle create` of vendor/klipper's shallow clone (1-2 commits deep,
# 00-fetch-vendor-sources.sh's clone_pinned) produces a bundle that
# `git bundle verify` reports as fine but a real `git clone` of rejects
# with "Failed to traverse parents of commit ..." / "remote did not send
# all necessary objects" (confirmed again against git 2.55.0 - a genuine,
# still-present git limitation, not a syntax mistake). That synthetic
# commit had no shared ancestry with the real coreflake1/NebulaOS-klipper
# or Arksine/moonraker history on GitHub, which made Moonraker's own
# `git merge-base --is-ancestor HEAD origin/<branch>` check permanently
# fail (return code 1) on every freshly-seeded device - HEAD could never
# be an ancestor of a real remote branch it shared no history with. This
# set `diverged=true` -> `has_recoverable_errors()=true` ->
# `is_valid()=false` (vendor/moonraker/moonraker/components/update_manager/
# git_deploy.py) permanently, blocking every real Klipper/Moonraker update.
#
# FIX: stop bundling/flattening entirely. Archive each vendor checkout's
# REAL `.git` directory (shallow boundary, real branch, real commits) plus
# its working tree as a plain tar file, with the local branch renamed to
# match Moonraker's hardcoded reserved-slot expectation ("master" - see
# BASE_CONFIG in update_manager/common.py, not configurable) and origin
# rewritten to the real public remote. On-device seeding (S04) then
# extracts the tar directly into place - no `git clone` at all, which is
# also strictly cheaper on this 208MB device than the clone-from-bundle
# step it replaces (plain tar extraction does no object repacking).

# chelper_enforce_mtime() lives in the same overlay file the device itself
# uses at boot (/etc/nebulaos-chelper-preflight.sh), sourced here rather than
# reimplemented, so the build-time and boot-time definitions of the invariant
# cannot drift apart - the same reasoning that put make_seed_archive() itself
# in a shared file rather than duplicating it between the build and its tests.
# Only sourced if not already defined, so a caller that has already sourced it
# (04-cross-compile-app-stack.sh does) is unaffected.
if ! command -v chelper_enforce_mtime >/dev/null 2>&1; then
	_mksa_dir=$(cd "$(dirname "$0")" && pwd)
	for _cand in \
		"$_mksa_dir/overlay/etc/nebulaos-chelper-preflight.sh" \
		"$_mksa_dir/../scripts/build/overlay/etc/nebulaos-chelper-preflight.sh" \
		"$_mksa_dir/../build/overlay/etc/nebulaos-chelper-preflight.sh"; do
		if [ -f "$_cand" ]; then . "$_cand"; break; fi
	done
	unset _mksa_dir _cand
fi

make_seed_archive() {
	src="$1"; active_branch="$2"; origin_url="$3"; out="$4"; sparse_exclude="${5:-}"
	# Production optimization mission, Phase 4 (2026-07-30): both optional,
	# trailing so every existing 5-arg call site (including
	# tests/factory-seed-git-tests.sh's offline fixtures, which have no
	# real target Python toolchain to test against) is unaffected and
	# simply skips precompilation. python3_bin must be a HOST-architecture
	# build of the *same* CPython version/build that runs on the target
	# (Buildroot's own output/host/bin/python3, exactly what
	# BR2_PACKAGE_PYTHON3_PYC_ONLY already uses for system packages) -
	# Python bytecode itself is not CPU-architecture-specific, only
	# CPython-version-specific, so this produces byte-identical .pyc
	# output to what the target interpreter would compile natively,
	# without needing target emulation. mount_path is the real absolute
	# path this tree runs from on the device (e.g. /opt/klipper) - used
	# only to make embedded tracebacks show real device paths instead of
	# this function's own mktemp staging path; purely cosmetic, no
	# functional effect on bytecode validity.
	python3_bin="${6:-}"; mount_path="${7:-}"
	# Fail closed. This was an unchecked `tmp=$(mktemp -d)`, and the failure
	# mode is not theoretical: with an unwritable TMPDIR, mktemp fails, $tmp
	# is EMPTY, and every `git -C "$tmp" ..." below silently becomes
	# `git -C ""`, which git treats as a no-op rather than an error - so the
	# commands run against whatever repository the caller happens to be in.
	# That is exactly how `git -C "$tmp" checkout -q -B "$active_branch"`
	# switched the real firmware checkout onto a `master` branch during this
	# mission. `cp -r "$src/." ""` and `rm -rf ""` are the same hazard.
	tmp=$(mktemp -d) || {
		echo "ERROR: refusing to package $src - could not create a temporary staging directory" >&2
		return 1
	}
	[ -n "$tmp" ] && [ -d "$tmp" ] || {
		echo "ERROR: refusing to package $src - mktemp produced an unusable staging path ('$tmp')" >&2
		return 1
	}
	cp -r "$src/." "$tmp/"
	# Ensure the archived copy is checked out on the branch Moonraker's
	# reserved slot actually expects, without disturbing $src itself.
	#
	# Phase 1.8 candidate-001 root cause: the old code did a plain
	# `git checkout "$active_branch"` which, when $src had a DETACHED HEAD
	# at the pinned commit (the normal state after clone_pinned's non-shallow
	# path does `git checkout "$ref"`), switched to the local branch at its
	# ORIGINAL position (the clone's default HEAD, e.g. main at 448b59c)
	# instead of staying at the pinned commit (e.g. 7260389). The archive
	# then contained the wrong content. `checkout -B` forces the local
	# branch to the current HEAD position, which is always correct: if HEAD
	# is detached at the pin, the branch moves there; if HEAD is already on
	# the branch (shallow-clone path), it stays.
	git -C "$tmp" checkout -q -B "$active_branch"

	# Real bug found live (first full first-boot qualification, 2026-07-28):
	# a plain `tar -xzf` of vendor/klipper's real working tree still has to
	# write out its ~226MB of real files (mostly its own vendored MCU HAL/
	# SDK sources under lib/, needed only to compile MCU firmware - never
	# read by Klippy's own host-side runtime) - measured live at 1m51s on
	# the real device, on top of both venv creations and moonraker's own
	# seeding. The device was hard-rebooted twice by an impatient human
	# before that ever finished, leaving klipper/moonraker's app
	# directories seeded empty (no .git at all) - not a WiFi bug, a
	# too-slow factory seed. Fixed with git's own sparse-checkout: the
	# excluded path's blobs stay fully present in .git/objects (real,
	# complete history - the mission's core requirement - is untouched),
	# only the WORKING TREE omits it, and git treats that as intentional
	# sparsity, not a modification/deletion (confirmed live: `git status`
	# reports "in a sparse checkout", never a dirty/deleted lib/). Cut
	# klipper's real device extraction from 1m51s to a few seconds.
	if [ -n "$sparse_exclude" ]; then
		git -C "$tmp" sparse-checkout init --no-cone
		printf '/*\n!%s\n' "$sparse_exclude" > "$tmp/.git/info/sparse-checkout"
		git -C "$tmp" read-tree -mu HEAD
	fi
	# Reset ALL remotes to exactly one "origin" with the standard
	# wildcard fetch refspec. Real bug found while validating this
	# against the actual coreflake1/NebulaOS-klipper remote: vendor/
	# klipper's own "origin" remote (00-fetch-vendor-sources.sh's
	# clone_pinned) is scoped to a narrow `+refs/heads/jun2025:
	# refs/remotes/origin/jun2025` fetch refspec, left over from its
	# original single-branch clone. Archiving that config as-is would
	# make a later plain `git fetch origin` (exactly what Moonraker's
	# own GitDeploy refresh runs) silently fail to populate
	# refs/remotes/origin/master at all, reproducing the very
	# `merge-base --is-ancestor HEAD origin/master` failure
	# (diverged=true) this whole mission exists to fix - confirmed by
	# reproducing it locally before this fix. Removing every remote and
	# re-adding a single "origin" with git's normal wildcard refspec is
	# what a real `git clone` would have produced, and is what this
	# archive must reproduce without ever running a clone.
	for r in $(git -C "$tmp" remote); do
		git -C "$tmp" remote remove "$r"
	done
	# `git remote remove` does not always clean up a leftover
	# refs/remotes/<name>/HEAD symref (a known git quirk - HEAD is a
	# symbolic ref, not a plain remote-tracking branch); left in place it
	# points at nothing and makes `git fsck` print a spurious "invalid
	# sha1 pointer" error. Harmless to the actual ancestry check but real
	# noise in build logs, so clear the whole refs/remotes tree outright.
	rm -rf "$tmp/.git/refs/remotes"
	git -C "$tmp" remote add origin "$origin_url"
	git -C "$tmp" config "remote.origin.fetch" "+refs/heads/*:refs/remotes/origin/*"
	# Real, critical bug found live during the first genuinely successful
	# fresh-boot qualification: `branch --set-upstream-to` requires the
	# target remote-tracking ref (origin/<branch>) to already exist
	# locally, which it never does in an offline-built archive (no fetch
	# has ever happened against this freshly-added "origin" remote) - so
	# this silently failed every single time, swallowed by its own
	# `|| true`. Without it, the branch has no `branch.<name>.remote`
	# config at all, which is exactly what Moonraker's own GitDeploy reads
	# to populate `git_remote` (git_deploy.py's `config_get(f"branch.
	# {branch}.remote")`) - with that unset, git_remote is "?", and
	# is_valid()'s own `"?" not in (git_branch, git_remote,
	# upstream_commit)` check fails it directly, independent of and in
	# addition to the diverged/dirty/detached checks this mission already
	# fixed. Confirmed live: `is_valid` stayed false with a real, correctly
	# ancestor-reachable, non-diverged, non-dirty repo until this exact
	# config was set. Setting the two config keys directly (not via
	# `--set-upstream-to`) needs no pre-existing remote-tracking ref at
	# all - confirmed live this alone was sufficient to make Moonraker
	# report is_valid=true for both klipper and moonraker.
	git -C "$tmp" config "branch.$active_branch.remote" origin
	git -C "$tmp" config "branch.$active_branch.merge" "refs/heads/$active_branch"

	# Seed a remote-tracking ref so Moonraker's check_diverged()
	# succeeds. Without this, no refs/remotes/origin/$branch exists,
	# and `merge-base --is-ancestor HEAD origin/master` fails.
	mkdir -p "$tmp/.git/refs/remotes/origin"
	git -C "$tmp" rev-parse HEAD > "$tmp/.git/refs/remotes/origin/$active_branch"

	# clone_pinned leaves TWO entries in .git/shallow: the original
	# clone HEAD and the pinned commit fetch. The stale entry's
	# commit object references a parent that was never fetched
	# (beyond the original shallow boundary), so simply removing
	# the entry from .git/shallow makes git try to traverse past it
	# into a missing parent — breaking fsck, gc, and merge-base.
	# Fix: (1) rewrite .git/shallow to HEAD only, (2) clear reflogs
	# that reference the stale commit, (3) repack with only objects
	# reachable from current refs to physically remove the orphan.
	head_sha=$(git -C "$tmp" rev-parse HEAD)
	if [ -f "$tmp/.git/shallow" ]; then
		# `|| echo 0` APPENDS, it does not substitute. grep -c prints its
		# count (0) AND exits 1 when nothing matches, so the substitution
		# captured both and stale_count became the two-line string "0\n0",
		# which `[ -gt ]` rejects with "Illegal number: 0" - visible in every
		# build log. It was harmless only by accident: the malformed value
		# arises exactly when the count is zero, and a failing `[` makes the
		# branch false, which is the correct action for a zero count. Relying
		# on an error path to land on the right branch is not a check.
		#
		# G56 (2026-10-15): keep boundary entries that are ancestors of HEAD.
		# A seed deepened back to its last release tag (Klipper: so that
		# `git describe` - and Moonraker's version - works) has exactly one
		# such boundary, below the tag; cutting it to HEAD threw that history
		# away again. Only entries off HEAD's history are stale.
		_keep=""
		for _s in $(cat "$tmp/.git/shallow"); do
			if [ "$_s" = "$head_sha" ] || git -C "$tmp" merge-base --is-ancestor "$_s" HEAD 2>/dev/null; then
				_keep="$_keep $_s"
			fi
		done
		[ -n "$_keep" ] || _keep=$head_sha
		printf '%s\n' $_keep > "$tmp/.git/shallow"
	fi

	# Drop the reflogs BEFORE repacking, and unconditionally.
	#
	# The repack below packs only objects reachable from REFS and then deletes
	# the pack the clone came with. A reflog entry can name an object that no
	# ref reaches - `checkout -B` above moves a branch and leaves its previous
	# tip behind in exactly that state - so after the repack that entry points
	# at an object the repository no longer has, and `git fsck` (run further
	# down, and load-bearing) reports "invalid reflog entry" and the build
	# refuses to package. Measured on the real moonraker clone:
	#
	#   error: refs/heads/master: invalid reflog entry 1cfb0c41e468...
	#   ERROR: refusing to package .../vendor/moonraker - git fsck reported
	#          repository damage
	#
	# The shallow path used to delete the reflogs just before repacking, which
	# is why klipper never hit this and moonraker did the moment the repack
	# became unconditional. Reflogs are purely local history, they are dropped
	# later anyway so the archive is deterministic, and git recreates them on
	# the device at the next ref update - so dropping them here costs nothing
	# and keeps the object store and the refs consistent with each other.
	rm -rf "$tmp/.git/logs"

	# Repack ALWAYS, not only on the shallow-fix path.
	#
	# A clone's pack is whatever the REMOTE SERVER chose to send. It is not a
	# function of the repository's content, and GitHub does not send identical
	# bytes every time. Measured, and the control is exact: klipper HAS
	# .git/shallow, so the old code repacked it here and klipper came out
	# byte-identical; moonraker has NO .git/shallow, so it shipped the
	# server's pack verbatim and alternated between pack-3fc0a98c... and
	# pack-d117e011... across builds. Same 12310 objects, same 9144/3166
	# delta/base split - only the delta CHOICES differed, so it was never a
	# content difference.
	#
	# Packing locally from the reachable object list makes the pack a function
	# of the objects alone, for every seed rather than for the shallow ones by
	# accident. --threads=1 because delta search is multithreaded by default
	# and the result then depends on how work lands on threads.
	_reachable=$(mktemp) || {
		echo "ERROR: refusing to package $src - could not create a temporary object list" >&2
		rm -rf "$tmp"
		return 1
	}
	git -C "$tmp" rev-list --objects --all > "$_reachable"
	# --no-reuse-delta --no-reuse-object are the load-bearing flags, and
	# --threads=1 alone was NOT enough. By default pack-objects REUSES the
	# deltas and compressed object data it finds in the existing pack - and
	# that pack came from the remote server, so its bytes leak straight into
	# the "locally built" one. Measured on the two real moonraker clones:
	# repacking each with reuse allowed reproduced the shipped mismatch
	# exactly (pack-c473fcc2... vs pack-6c404824...), while repacking the
	# same two with reuse disabled converged both to pack-6ad84128... These
	# flags force every delta to be recomputed, which is what makes the pack
	# a function of the objects rather than of whatever a server once sent.
	_pack_hash=$(git -C "$tmp" pack-objects --threads=1 --no-reuse-delta --no-reuse-object "$tmp/.git/objects/pack/pack" < "$_reachable")
	rm -f "$_reachable"
	if [ -z "$_pack_hash" ]; then
		echo "ERROR: refusing to package $src - deterministic repack produced no pack" >&2
		rm -rf "$tmp"
		return 1
	fi
	for _p in "$tmp"/.git/objects/pack/pack-*.pack; do
		_bn=$(basename "$_p" .pack)
		[ "$_bn" != "pack-$_pack_hash" ] && rm -f "$_p" "${_p%.pack}.idx" "${_p%.pack}.rev"
	done
	# Indexes over the packs just deleted. git >= 2.4x writes a
	# multi-pack-index (and commit-graph) during a fetch's automatic
	# maintenance; left in place it names the removed packs and every object
	# lookup fails ("failed to load pack entry"). Found with G56's deepened
	# Klipper clone (three fetches). git rebuilds them on demand.
	rm -f "$tmp"/.git/objects/pack/multi-pack-index*
	rm -rf "$tmp/.git/objects/info/commit-graph" "$tmp/.git/objects/info/commit-graphs"
	# Loose objects are now redundant with the pack and are written by
	# whatever ran before this point; drop them so the object store is exactly
	# one pack. `prune-packed` only removes objects that the pack already
	# contains, so nothing reachable can be lost.
	git -C "$tmp" prune-packed 2>/dev/null || true
	# prune-packed only drops loose objects the pack already contains. Objects
	# no ref reaches are in neither - `checkout -B` above strands the previous
	# branch tip exactly this way - so they would ship as loose cruft whose
	# presence depends on what the clone happened to carry. Now that the
	# reflogs are gone, they are genuinely unreachable and `git prune` removes
	# them, leaving the object store as exactly one pack. Verified safe on a
	# shallow clone: .git/shallow survives, fsck stays clean, the repo remains
	# usable.
	git -C "$tmp" prune --expire=now 2>/dev/null || true

	# Discard a wrong-architecture klippy/chelper/c_helper.so before
	# packaging (e.g. a host-recompiled x86 .so left over from a
	# developer running `make` locally, outside this project's own
	# cross-compile pipeline - must never ship to the MIPS target). Real
	# bug found while writing this function's own tests: an earlier
	# version did a blanket `git checkout -- .`, which discards ANY
	# tracked-file modification - that silently defeated the dirty-tree
	# rejection below for every tracked file, not just this one binary
	# (confirmed live: a deliberately dirtied source file was wiped clean
	# before the check ever ran, so "reject a dirty tree" never actually
	# fired). Only ever discard this specific, known-safe path; anything
	# else dirty must still fail the check below.
	#
	# Final Baseline Closure mission (2026-08-08): c_helper.so is no
	# longer git-tracked at all as of KLIPPER_PIN 845396f0 (it is a
	# generated build artifact, not source - see that pin's own commit
	# message and docs/NEBULAOS_C_HELPER_DIRTY_STATE_FIX.md), so there is
	# no longer a committed "known good" version for `git checkout` to
	# restore - that call would now fail every time (pathspec unknown to
	# git) and silently no-op behind its own `|| true`. A plain `rm -f`
	# achieves the same real safety property (never package a
	# wrong-architecture binary) more directly: a missing c_helper.so
	# fails loudly downstream (Klippy's own get_ffi() has no on-device
	# build fallback - see NebulaOS-klipper's klippy/chelper/__init__.py)
	# rather than silently shipping a binary that would have failed just
	# as loudly, just less predictably.
	if [ -e "$tmp/klippy/chelper/c_helper.so" ] \
		&& ! file -b "$tmp/klippy/chelper/c_helper.so" | grep -qi "MIPS"; then
		rm -f "$tmp/klippy/chelper/c_helper.so"
	fi

	# Defense in depth: this archive must contain zero synthetic history
	# and a genuinely clean, valid repo before it is ever packaged.
	if git -C "$tmp" log --all --format=%s 2>/dev/null | grep -q "NebulaOS factory seed snapshot"; then
		echo "ERROR: refusing to package $src - synthetic wrapper commit detected in history" >&2
		rm -rf "$tmp"
		return 1
	fi
	# Production optimization mission, Phase 9 (2026-07-30): real bug found
	# live - the properly cross-compiled, correctly stripped MIPS
	# klippy/chelper/c_helper.so built by the real pipeline is legitimately
	# ALWAYS different from whatever is tracked in git for this path (an
	# untrusted upstream binary, never intended to ship as-is - see the
	# comment on the check above this one), so this dirty-tree guard would
	# otherwise reject every real build. Exclude just this one, already-
	# understood, expected-to-differ path from the clean-tree check -
	# anything else dirty must still fail it.
	if [ -n "$(git -C "$tmp" status --porcelain -- . ':!klippy/chelper/c_helper.so')" ]; then
		echo "ERROR: refusing to package $src - working tree is not clean" >&2
		rm -rf "$tmp"
		return 1
	fi
	if ! git -C "$tmp" fsck --no-dangling >/dev/null; then
		echo "ERROR: refusing to package $src - git fsck reported repository damage" >&2
		rm -rf "$tmp"
		return 1
	fi

	# Precompile to .pyc, deliberately AFTER the clean-tree check above,
	# not before: __pycache__ directories are untracked, and the dirty-
	# tree guard would otherwise refuse to package a tree that compiled
	# cleanly. A failure here is non-fatal - it just means this seed
	# ships without precompiled bytecode and pays the normal one-time
	# compile-on-first-import cost instead, same as before this feature
	# existed; it must never block the whole build.
	#
	# Excludes top-level scripts/ as well as .git/: real failure found
	# live - Klipper's own scripts/stepstats.py is a Python-2-only dev
	# tool (a bare `print "..." %` statement) that Klippy's own runtime
	# never imports, but compileall's walk still reaches it and returns
	# non-zero for the whole tree over that one irrelevant file (Moonraker
	# has a handful of similarly never-imported scripts/*.py of its own -
	# losing bytecode for these purely host-side dev/release tools, never
	# run on the target, is a non-issue).
	# Drop any __pycache__ copied in from the vendor checkout BEFORE compiling.
	#
	# Measured: two builds of this commit differed by exactly one file,
	# lib/kconfiglib/__pycache__/kconfiglib.cpython-311.pyc, 2 bytes apart -
	# a PEP 552 TIMESTAMP-based header (flag word 0) carrying the source
	# mtime, 1790315597 vs 1790320525. Every other .pyc in the archive was
	# hash-based (flag word 3) and identical, because compileall below runs
	# with SOURCE_DATE_EPOCH set and CPython then emits CHECKED_HASH.
	#
	# That one file was never compiled by us. It arrived via `cp -r` from the
	# vendor tree, where something had imported kconfiglib during the build,
	# and it survived because __pycache__ is UNTRACKED: the sparse checkout
	# removes tracked files under the excluded path, but not untracked ones.
	# So klipper shipped a .pyc whose .py source is deliberately absent - a
	# stale build artifact leaking into a release seed, and a per-build
	# timestamp with it.
	#
	# Removing them is safe: bytecode is a cache. compileall regenerates what
	# is still there, deterministically, and a sparse-excluded path correctly
	# gets no bytecode because it ships no source either. Done unconditionally
	# so a caller with no python3_bin does not ship them either.
	#
	# `git clean`, NOT `rm -rf`: this must remove only UNTRACKED bytecode. A
	# blanket rm also deletes a __pycache__ that a repository legitimately
	# tracks, and the clean-tree guard below then refuses to package the tree
	# (measured - a test fixture did exactly that). Untracked leakage is the
	# defect; tracked content is content.
	git -C "$tmp" clean -fdx -- '*__pycache__*' >/dev/null 2>&1 || true

	if [ -n "$python3_bin" ]; then
		if [ -n "$mount_path" ]; then
			PYTHONPATH="" "$python3_bin" -m compileall -q \
				-x '(^|/)(\.git|scripts)($|/)' -s "$tmp" -p "$mount_path" "$tmp" \
				|| echo "WARNING: bytecode precompilation failed for $src - shipping source-only, as before" >&2
		else
			PYTHONPATH="" "$python3_bin" -m compileall -q \
				-x '(^|/)(\.git|scripts)($|/)' "$tmp" \
				|| echo "WARNING: bytecode precompilation failed for $src - shipping source-only, as before" >&2
		fi
	fi

	# Phase 1 no-fork migration: re-establish the c_helper.so mtime
	# invariant as the LAST thing before packaging, and fail the build if
	# it cannot be established.
	#
	# This is not belt-and-braces, it is load-bearing. Klipper decides
	# whether to shell out to gcc by comparing mtimes, and this function
	# has already done three separate things that rewrite them in
	# nondeterministic order: `cp -r "$src/." "$tmp/"` does NOT preserve
	# mtimes (no -p, no -a), `git checkout` can rewrite working-tree files,
	# and the sparse-checkout `read-tree -mu HEAD` rewrites them again.
	# After all that, whether the prebuilt library ends up newer than
	# klippy/chelper/*.c is decided by directory-walk order - which is to
	# say, by luck. On a bad roll the device gets an image whose Klippy
	# tries to invoke a compiler that does not exist and never starts.
	#
	# Deliberately guarded on the directory existing so this stays a shared
	# function: only the Klipper tree has a chelper, and moonraker (and the
	# offline fixture repos in tests/factory-seed-git-tests.sh) must pass
	# straight through.
	if [ -d "$tmp/klippy/chelper" ]; then
		if ! chelper_enforce_mtime "$tmp"; then
			echo "ERROR: refusing to package $src - could not establish the c_helper.so mtime invariant" >&2
			rm -rf "$tmp"
			return 1
		fi
	fi

	# The archived .git carries two files that are written by the BUILD, not
	# by the content, and both differed between two runs of the same commit
	# (measured - they were the only differing members):
	#
	#   .git/index      records per-file stat data (mtime, ctime, ino, dev)
	#                   for the working tree. $tmp is a fresh copy every run,
	#                   so every one of those fields is new every run.
	#   .git/logs/HEAD  the reflog, whose every entry carries the wall-clock
	#                   time of the ref update this function just performed.
	#
	# Deterministic tar flags cannot fix either: the variation is inside the
	# member contents, not in the tar headers.
	#
	# The reflog is purely local history - nothing in the update path reads
	# it, and git recreates it on the device at the next ref update - so it
	# is removed. The index is rebuilt from HEAD with `read-tree` (no -u),
	# which writes the entries with ZEROED stat data and does not touch the
	# working tree. It still honours core.sparseCheckout, so the
	# skip-worktree bits from the sparse path above are preserved.
	#
	# This removes build-time noise; it hides nothing. Both files are still
	# present-or-absent identically in every build and are fully compared.
	rm -rf "$tmp/.git/logs"
	rm -f "$tmp/.git/index"
	if ! git -C "$tmp" read-tree HEAD; then
		echo "ERROR: refusing to package $src - could not rebuild a deterministic .git/index" >&2
		rm -rf "$tmp"
		return 1
	fi
	# A plain `read-tree HEAD` does NOT re-apply skip-worktree bits (sparse
	# handling lives in the -m/--reset paths), so on the sparse path the
	# freshly rebuilt index lists the excluded paths as present while they
	# are deliberately absent on disk - git then reports them as deleted.
	# Re-mark exactly the tracked-but-absent files. `update-index
	# --skip-worktree` only sets the flag bit; it does not stat the file, so
	# the zeroed stat data (and with it determinism) survives.
	#
	# Deliberately guarded on $sparse_exclude: only there is an absent
	# tracked file EXPECTED. Outside the sparse path a missing file is a real
	# defect and must keep failing the clean-tree check below rather than
	# being quietly marked as intentional.
	#
	# `git ls-files --deleted` IS that set - tracked entries with no file on
	# disk - so git computes it and no shell loop is needed. The first
	# version of this did the walk in shell with `read -r -d ''`, which is a
	# BASHISM: this file is #!/bin/sh and build.sh runs the pipeline with
	# `sh`, which is dash in the container. dash's read has no -d, the loop
	# body never ran, no bits were re-applied, and the guard below then saw
	# the entire klipper tree as deleted and refused to package it. It failed
	# closed, but it failed a real build - hence no shell loop here.
	if [ -n "$sparse_exclude" ]; then
		git -C "$tmp" ls-files --deleted -z \
			| xargs -0 -r git -C "$tmp" update-index --skip-worktree -- || {
			echo "ERROR: refusing to package $src - could not re-apply sparse skip-worktree bits" >&2
			rm -rf "$tmp"
			return 1
		}
	fi
	# --no-optional-locks so this check does not itself refresh (and rewrite)
	# the index it is verifying. c_helper.so is excluded for the same reason
	# as the clean-tree guard above: it is a prebuilt artifact, not content.
	if [ -n "$(git --no-optional-locks -C "$tmp" status --porcelain -- . ':!klippy/chelper/c_helper.so')" ]; then
		echo "ERROR: refusing to package $src - the rebuilt index does not match the working tree" >&2
		git --no-optional-locks -C "$tmp" status --porcelain -- . ':!klippy/chelper/c_helper.so' >&2
		rm -rf "$tmp"
		return 1
	fi

	# gzip, not a plain tar: real bug found at the first full build after
	# this archive format landed - a plain tar of vendor/klipper's real
	# working tree (~226MB uncommitted source, mostly its own vendored
	# MCU HAL/SDK libraries under lib/) on top of the ALREADY-shipped
	# plain copy at /opt/klipper overflowed the fixed 400M rootfs.ext2
	# ("Could not allocate block in ext2 filesystem"). The old flattened-
	# commit bundle never hit this because git's own pack compression
	# made it ~11.5MB; gzip here brings a real tar back down to a
	# comparable order of magnitude (~40MB measured) while still
	# preserving real, non-synthetic history.
	# Deterministic tar: without --sort the member order follows readdir, and
	# without --mtime/--owner the member headers carry build-time mtimes and
	# the builder uid/gid. All three differed between two builds of the same
	# commit. The gzip header itself was already clean (tar -z compresses a
	# stream, so no filename or mtime is stored).
	#
	# The mtime comes from the archived tree's OWN HEAD commit date, not from
	# SOURCE_DATE_EPOCH. This function is shared - the tests and the offline
	# fixtures call it directly - so requiring a build-time variable would
	# break every caller outside build.sh (measured: it did). The commit date
	# is also the more honest value: the archive *is* that commit, and it is
	# fixed for a given pin, so two builds of the same pin agree.
	seed_epoch=$(git -C "$tmp" show -s --format=%ct HEAD 2>/dev/null || echo "")
	case "$seed_epoch" in
		''|*[!0-9]*) seed_epoch=${SOURCE_DATE_EPOCH:-} ;;
	esac
	case "$seed_epoch" in
		''|*[!0-9]*)
			echo "ERROR: refusing to package $src - no deterministic archive mtime available (no readable HEAD commit date and no SOURCE_DATE_EPOCH)" >&2
			rm -rf "$tmp"
			return 1
			;;
	esac
	# Flattening every member to one mtime is safe for the chelper invariant
	# enforced above: both Klipper's check_build_code() (max(src) > min(obj))
	# and chelper_check_mtime()'s `find -newer` are STRICTLY greater, so equal
	# mtimes do not trigger a gcc rebuild. Verified against
	# vendor/klipper/klippy/chelper/__init__.py.
	tar -C "$tmp" --sort=name --mtime="@$seed_epoch" --owner=0 --group=0 --numeric-owner -czf "$out" .
	git -C "$tmp" rev-parse HEAD
	rm -rf "$tmp"
}
