#!/bin/sh
# Repository + Canonical Baseline Repair mission, Phase 7 (2026-08-07): the
# single documented command that reproduces the current qualified NebulaOS
# production baseline (tag nebulaos-wifi-camera-irq-fix-2026-08-04, plus the
# non-tagged accepted work since it - GuppyScreen/z_compensate, see
# docs/NEBULAOS_QUALIFIED_BASELINE_VARIANT_AUDIT.md) from nothing but this
# checkout, the pinned manifest, and the network.
#
# Deliberately the smallest thing that fits this repo's existing conventions
# - it just sequences the pipeline stages already used individually all
# along, in the order they must run, with the baseline-composition and
# assertion steps at the points that actually matter:
#
#   00-fetch-vendor-sources.sh    fetch every pinned source (fails loudly on
#                                  any unpushed/unresolvable pin - see
#                                  manifests/dependencies.conf)
#   assert-baseline-config.sh pre-build   fail fast, before spending build
#                                  time, if the pinned kernel checkout is
#                                  modified or lacks an accepted change (every
#                                  kernel change is a NebulaOS-kernel commit;
#                                  nothing is applied at build time)
#   01 -> 06                      the existing numbered pipeline, unchanged
#   assert-baseline-config.sh post-build  prove the resolved artifact
#                                  actually contains the accepted changes
#
# This does NOT reuse any existing vendor/, build-work/, or artifacts/
# state - run it against a genuinely fresh clone (a dirty/reused checkout
# defeats the entire point of a clean-room build; 00-fetch-vendor-sources.sh
# will happily reuse an already-present vendor/ directory if one exists,
# which is convenient for iteration but not what this script is for).
#
# Usage: sh scripts/build/build-qualified-baseline.sh
#
# Exits non-zero if any pin fails to resolve,
# either assertion fails, or any build stage fails.

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# --- stage timing ----------------------------------------------------------
# Measurement only. `stage` runs exactly what the unwrapped line ran, in the
# same order, and propagates the same exit status under `set -e`; it adds a
# clock around it and nothing else. Timings go to stderr as they happen so a
# build that dies halfway still shows where the time went, and the summary is
# reprinted at the end for a build that finishes.
#
# Seconds, via `date +%s`: %N is a GNU extension and this runs under whatever
# /bin/sh the pinned image provides. A build stage measured in seconds does not
# need nanoseconds.
BUILD_T0=$(date +%s)
STAGE_TIMES=""

stage() {
	_label=$1; shift
	_t0=$(date +%s)
	echo "=== build-qualified-baseline: $_label ==="
	"$@"
	_t1=$(date +%s)
	_d=$((_t1 - _t0))
	STAGE_TIMES="$STAGE_TIMES$_label|$_d
"
	echo "--- stage '$_label' took ${_d}s ---" >&2
}

fmt_hms() { # seconds -> Hh MMm SSs, readable at a glance for a multi-hour build
	_s=$1
	printf '%dh %02dm %02ds' $((_s/3600)) $(((_s%3600)/60)) $((_s%60))
}

stage "fetching every pinned source"                sh "$SCRIPT_DIR/00-fetch-vendor-sources.sh"
stage "pre-build assertions (source-level)"         sh "$SCRIPT_DIR/assert-baseline-config.sh" pre-build
stage "01 kernel patches"                           sh "$SCRIPT_DIR/01-apply-kernel-patches.sh"
stage "02 buildroot config"                         sh "$SCRIPT_DIR/02-configure-buildroot.sh"
stage "03 kernel and rootfs"                        sh "$SCRIPT_DIR/03-build-kernel-and-rootfs.sh"
stage "04 app stack"                                sh "$SCRIPT_DIR/04-cross-compile-app-stack.sh"
stage "05 final image"                              sh "$SCRIPT_DIR/05-final-build.sh"
stage "06 verify"                                   sh "$SCRIPT_DIR/06-verify.sh"

# The candidate and qualified post-build assertions are NOT interchangeable and
# are deliberately not merged: candidate-post-build keeps the resolved-artifact
# checks but treats the comparison against the qualified baseline as
# informational, which is the only correct mode for source that legitimately
# contains not-yet-qualified changes. Collapsing them would silently turn every
# candidate into a failed reproduction, or worse, turn a real reproduction
# failure into a pass.
# A DEV build gets the same resolved-artifact assertions as a candidate. The
# strict baseline-reproduction gate (post-build) answers "is this identical to
# QUALIFIED_BASELINE_TAG", which only a --qualified reproduction build asks;
# applied to a DEV build it fails on every legitimate change and no DEV build
# could ever be attested.
if [ "${NEBULAOS_CANDIDATE_BUILD:-}" = "1" ] || [ "${NEBULAOS_BUILD_MODE:-}" = "dev" ]; then
	stage "post-build assertions (candidate)" sh "$SCRIPT_DIR/assert-baseline-config.sh" candidate-post-build
else
	stage "post-build assertions (qualified)" sh "$SCRIPT_DIR/assert-baseline-config.sh" post-build
fi

BUILD_T1=$(date +%s)
BUILD_TOTAL=$((BUILD_T1 - BUILD_T0))

echo
echo "=== build-qualified-baseline: stage timings ==="
printf '%s' "$STAGE_TIMES" | while IFS='|' read -r _l _d; do
	[ -n "$_l" ] || continue
	printf '  %-42s %8ss  (%s)\n' "$_l" "$_d" "$(fmt_hms "$_d")"
done
printf '  %-42s %8ss  (%s)\n' "TOTAL" "$BUILD_TOTAL" "$(fmt_hms "$BUILD_TOTAL")"

# --- cache accounting ------------------------------------------------------
# Reported, never inferred. Each line says what the build was actually given,
# so a surprising timing can be explained without guessing.
echo
echo "=== build-qualified-baseline: cache status ==="
if [ -n "${BR2_DL_DIR:-}" ] && [ -d "${BR2_DL_DIR:-}" ]; then
	_n=$(find "$BR2_DL_DIR" -maxdepth 2 -type f 2>/dev/null | wc -l)
	_sz=$(du -sh "$BR2_DL_DIR" 2>/dev/null | cut -f1)
	if [ "${NEBULAOS_DL_CACHE_WAS_EMPTY:-0}" = "1" ]; then _st=MISS; else _st=HIT; fi
	echo "  download cache   $_st  dir=$BR2_DL_DIR files=$_n size=${_sz:-unknown}"
else
	echo "  download cache   DISABLED"
fi
if [ "${NEBULAOS_CCACHE:-0}" = "1" ] && command -v ccache >/dev/null 2>&1; then
	echo "  compiler ccache  ENABLED  dir=${CCACHE_DIR:-unset} max=${CCACHE_MAXSIZE:-unset}"
	ccache --show-stats 2>/dev/null | sed 's/^/    /' || true
else
	# OFF is the correct and required state for candidate/release builds:
	# qualification must not depend on compiler-cache correctness.
	echo "  compiler ccache  DISABLED  (required for candidate/release builds)"
fi

echo
echo "=== build-qualified-baseline: complete and composition-verified ==="
echo "Package it with: sh scripts/build/package-deployment.sh"
