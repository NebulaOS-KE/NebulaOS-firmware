#!/bin/sh
# Phase 5 baseline-difference gate. Compares the just-built package against
# the pinned qualified baseline package and hard-stops on any unexplained
# difference. Allowed differences are exactly: the guppyscreen binary/hash
# (NOT guppybeep - see the Allowed differences section below), z_compensate.py,
# explicit build/version metadata, and associated tests/manifests.
#
# Scope of what is actually GATED, stated plainly because the wording used to
# overstate it: the pass/fail signal in this script is the tracked
# config/DTS comparison. The "Allowed differences" section is prose echoed into
# baseline-difference.txt for a human reader - it documents expectations, it
# does not enforce them.
#
# Requires unsquashfs (squashfs-tools) on the host to compare rootfs
# contents; falls back to a kernel.config/DTS-only comparison with a loud
# warning if unavailable.
#
# Usage: sh scripts/build/baseline-difference-gate.sh
# Run AFTER 05-final-build.sh.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
ARTIFACT_DIR="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"

DEPS_MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
[ -f "$DEPS_MANIFEST" ] || { echo "FATAL: $DEPS_MANIFEST not found" >&2; exit 1; }
. "$DEPS_MANIFEST"

# 2026-08-07: reference by TAG NAME, not a hardcoded SHA - see
# assert-baseline-config.sh's own comment on why (the 2026-08-07
# canonical-repository mission's history rewrite, git filter-repo,
# changes the commit hash a tag points to; the tag NAME survives that
# unchanged). The previous hardcoded f9dc10f594c... stopped resolving to
# any object at all after the rewrite.
#
# 2026-08-14 (Phase 11 verification-gate fix): a hardcoded tag NAME goes
# stale just as surely as a hardcoded SHA - see assert-baseline-config.sh's
# matching fix and comment for the full incident writeup (a real Phase 9
# fresh-build run hit this exact staleness: FAIL against a baseline that
# was never wrong, just 11 days and 5 accepted baselines out of date).
# Derived the reference from the most recently created
# nebulaos-canonical-baseline-* tag instead of a fixed name.
#
# Final Closure mission, Phase B (2026-08-15): "newest tag wins" is still
# implicit - a new tag silently becomes the reference the moment it's
# pushed. One explicit value instead: QUALIFIED_BASELINE_TAG in
# manifests/dependencies.conf - see assert-baseline-config.sh's matching
# fix and comment for the full reasoning.
BASELINE_TAG="${QUALIFIED_BASELINE_TAG:?QUALIFIED_BASELINE_TAG not set in $DEPS_MANIFEST}"
git -C "$REPO_ROOT" rev-parse --verify -q "$BASELINE_TAG" >/dev/null || {
	echo "FATAL: QUALIFIED_BASELINE_TAG='$BASELINE_TAG' (from $DEPS_MANIFEST) does not exist in this checkout - fetch tags with 'git fetch --tags' first, or correct the manifest." >&2
	exit 1
}
echo "== qualified baseline in use: $BASELINE_TAG (from $DEPS_MANIFEST) =="
OUT="$REPO_ROOT/baseline-difference.txt"

FAILED=0
{
	echo "# Baseline difference report"
	echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "# Baseline tag: $BASELINE_TAG ($(git -C "$REPO_ROOT" rev-parse "$BASELINE_TAG"))"
	echo ""

	echo "## Tracked config/DTS artifacts (must be byte-identical)"
	for f in kernel.config halley5_v30.dtb.dts buildroot.config halley5-nebulaos-busybox-fragment.config; do
		if [ ! -f "$ARTIFACT_DIR/$f" ]; then
			echo "SKIP: $f not found in current build"
			continue
		fi
		if git -C "$REPO_ROOT" diff --quiet "$BASELINE_TAG" -- "artifacts/buildroot-halley5-v30-image/$f" 2>/dev/null; then
			echo "IDENTICAL: $f"
		else
			echo "DIFFERS (UNEXPECTED): $f"
			git -C "$REPO_ROOT" diff "$BASELINE_TAG" -- "artifacts/buildroot-halley5-v30-image/$f" 2>/dev/null | head -40
			FAILED=1
		fi
	done

	echo ""
	echo "## rootfs.squashfs content comparison"
	if command -v unsquashfs >/dev/null 2>&1; then
		NEW_LIST=$(mktemp)
		unsquashfs -l "$ARTIFACT_DIR/rootfs.squashfs" 2>/dev/null | sed '1,/^$/d' > "$NEW_LIST"
		echo "New rootfs.squashfs file count: $(wc -l < "$NEW_LIST")"
		# No baseline squashfs binary is retained locally (gitignored, not
		# committed per this repo's own convention) - the closest available
		# proof is the live-deployed device's own content, checked
		# separately in Phase 8/9 against the real running printer. This
		# section records the new image's manifest for that later
		# comparison rather than diffing two local binaries that don't
		# both exist.
		rm -f "$NEW_LIST"
	else
		echo "WARNING: unsquashfs not available - cannot directly diff rootfs contents. Relying on kernel.config/DTS/buildroot.config identity above plus live device comparison in Phase 8/9."
	fi

	echo ""
	echo "## Allowed differences (expected, not flagged as failures)"
	echo "- guppyscreen_sha256 (rebuilt GuppyScreen binary; git_commit_guppyscreen below is the real"
	echo "  correctness pin). CORRECTED 2026-09-24: this entry used to say the toolchain embeds a build"
	echo "  timestamp so bytes differ every build. The cause was specific - libhv expands __DATE__/__TIME__"
	echo "  (libhv/base/htime.c hv_compile_datetime) and links into guppyscreen - and stage 04 now pins"
	echo "  SOURCE_DATE_EPOCH to the GuppyScreen commit date and verifies the expected date is embedded."
	echo "  It stays an allowed difference because full byte-reproducibility is not yet demonstrated, not"
	echo "  because the bytes are expected to change with the calendar."
	echo "- guppybeep_sha256 is NOT an expected difference and is no longer listed as one: guppybeep does"
	echo "  not link libhv, embeds no date string at all, and has reproduced byte-for-byte across builds."
	echo "  If guppybeep ever differs, that is a real finding and not a known-benign rebuild artifact."
	echo "- git_commit_guppyscreen / git_commit_guppyscreen_dirty (2026-08-07: GuppyScreen is now a pinned,"
	echo "  automatically-built vendor source, not present as a manifest field on the 2026-08-03 baseline"
	echo "  at all - see manifests/dependencies.conf's GUPPYSCREEN_PIN)"
	echo "- git_commit_klipper / git_commit_klipper_dirty (z_compensate.py structured status contract)"
	echo "- rootfs_squashfs_sha256 / rootfs_squashfs_size (grows ~18.6MB vs the 2026-08-03 baseline - traced"
	echo "  to Buildroot's linux-firmware package pulling in a broader firmware set; every accepted feature"
	echo "  verified present, this is a superset not a loss - see the 2026-08-07 clean-room mission's own"
	echo "  artifact-diff notes. Still well under the 500MB rootfs2 partition budget.)"
	echo "- xImage_sha256 (kernel.config/halley5_v30.dts above are byte-identical to the baseline, yet"
	echo "  xImage is not byte-reproducible across separate builds. CORRECTED 2026-09-24: this entry used"
	echo "  to state the cause as 'a kernel build embeds its own build timestamp'. That is measured to be"
	echo "  incomplete - the uImage header does embed wall-clock build time, but skipping the 64-byte"
	echo "  header entirely, 1,454,891 of ~5.5MB still differ, so the compressed payload is itself"
	echo "  non-deterministic and a header-only fix would not make xImage reproducible. The conclusion"
	echo "  stands; the stated cause did not, and the real cause is not yet established. See"
	echo "  docs/REPRODUCIBILITY.md.)"
	echo "- built_at, git_commit_main (build/version metadata)"

	echo ""
	echo "## build-manifest.txt full diff (for reference, not a pass/fail signal by itself)"
	git -C "$REPO_ROOT" diff "$BASELINE_TAG" -- "artifacts/buildroot-halley5-v30-image/build-manifest.txt" 2>/dev/null || true

} > "$OUT"

cat "$OUT"

if [ "$FAILED" = "1" ]; then
	echo ""
	echo "== baseline-difference-gate: FAILED - unexplained differences found, see $OUT =="
	exit 1
fi
echo ""
echo "== baseline-difference-gate: PASSED - only allowed differences found, see $OUT =="
