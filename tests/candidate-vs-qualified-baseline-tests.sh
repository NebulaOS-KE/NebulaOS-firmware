#!/bin/sh
#
# Offline tests for the Phase 1 overnight closure mission's Mission H fix:
# scripts/build/assert-baseline-config.sh's new `candidate-post-build` mode.
#
# Problem this closes: `post-build` mode's own QUALIFIED_BASELINE_TAG
# comparison is a strict "did anything at all change vs the last hardware-
# qualified artifact" gate - correct for reproducing an already-qualified
# baseline, but it ALWAYS and CORRECTLY fails for a legitimate candidate
# that contains new, not-yet-hardware-qualified source changes (exactly
# what every Phase 1.9 build is). `candidate-post-build` keeps every real
# per-variant Kconfig/DTS assertion (BUILD_VERIFIED) but reports the
# baseline diff as informational only, never as a gate - promoting
# QUALIFIED_BASELINE_TAG itself remains a separate, deliberate, manually
# reviewed action this mode never performs.
#
# Requires a real build's resolved artifacts (kernel.config, halley5_v30.dts)
# to already exist under artifacts/buildroot-halley5-v30-image/ - skips
# cleanly if they don't (this is exactly the situation before any build has
# run yet, e.g. a fresh checkout).
#
# Usage: sh tests/candidate-vs-qualified-baseline-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ASSERT_SCRIPT="$REPO_ROOT/scripts/build/assert-baseline-config.sh"
ARTIFACT_DIR="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

if command -v sh >/dev/null 2>&1 && sh -n "$ASSERT_SCRIPT"; then
    pass "assert-baseline-config.sh is syntactically valid"
else
    fail "assert-baseline-config.sh has a syntax error"
fi

if sh "$ASSERT_SCRIPT" nonexistent-mode >/dev/null 2>&1; then
    fail "an unknown mode should exit non-zero"
else
    pass "an unknown mode exits non-zero"
fi
if sh "$ASSERT_SCRIPT" nonexistent-mode 2>&1 | grep -q "candidate-post-build"; then
    pass "the unknown-mode error message mentions candidate-post-build"
else
    fail "the unknown-mode error message does not mention the new mode"
fi

# The checks also read the resolved kernel source (vendor/, a build's own
# checkout): without it (a fresh clone, CI) they cannot run.
if [ -f "$ARTIFACT_DIR/kernel.config" ] && [ -f "$ARTIFACT_DIR/halley5_v30.dts" ] \
   && [ -d "$REPO_ROOT/vendor/x2000_kernel_6.6/kernel/kernel-6.6" ]; then
    # Compared before/after, not against git: an unrelated uncommitted edit
    # of the manifest (normal in DEV) is not a side effect of this tool.
    DEPS_BEFORE=$(sha256sum "$REPO_ROOT/manifests/dependencies.conf" | cut -d' ' -f1)
    OUTPUT=$(sh "$ASSERT_SCRIPT" candidate-post-build 2>&1)
    RC=$?

    if [ "$RC" -eq 0 ]; then
        pass "candidate-post-build exits 0 against the real built artifacts"
    else
        fail "candidate-post-build exited $RC against the real built artifacts:\n$OUTPUT"
    fi

    if echo "$OUTPUT" | grep -q "BUILD_VERIFIED"; then
        pass "candidate-post-build reports BUILD_VERIFIED"
    else
        fail "candidate-post-build did not report BUILD_VERIFIED"
    fi

    if echo "$OUTPUT" | grep -q "^  FAIL:"; then
        fail "candidate-post-build reported a FAIL line - every accepted-variant check should pass against a real build's own artifacts"
    else
        pass "candidate-post-build reports zero per-variant FAIL lines"
    fi

    # The whole point of this mode: a real difference vs the last
    # hardware-qualified baseline must be VISIBLE (informational), but must
    # NEVER be able to set the exit code non-zero on its own.
    if echo "$OUTPUT" | grep -qi "differs from"; then
        pass "candidate-post-build's informational diff section is present (this candidate does differ from the last qualified baseline, as expected for real Phase 1.9 work)"
    else
        echo "SKIP: no 'differs from' line found - either QUALIFIED_BASELINE_TAG could not be resolved (also fine, reported as SKIPPED above) or this candidate happens to be byte-identical to it"
    fi

    # Never touches the promotion value itself.
    if [ "$(sha256sum "$REPO_ROOT/manifests/dependencies.conf" | cut -d' ' -f1)" = "$DEPS_BEFORE" ]; then
        pass "manifests/dependencies.conf is unmodified by running candidate-post-build (QUALIFIED_BASELINE_TAG promotion stays a separate, deliberate action)"
    else
        fail "manifests/dependencies.conf changed as a side effect of running candidate-post-build - this must never happen automatically"
    fi

    # The pre-existing, unmodified post-build (strict) mode must still
    # behave exactly as it always has - reproducing the same
    # QUALIFIED_BASELINE_TAG diff logic, but as a real FAILED gate. This is
    # not a regression to "fix" - it is post-build's entire purpose, and a
    # real Phase 1.9 candidate is EXPECTED to fail it.
    if sh "$ASSERT_SCRIPT" post-build >/dev/null 2>&1; then
        echo "SKIP: post-build (strict) unexpectedly passed - either QUALIFIED_BASELINE_TAG already points at this exact candidate, or the tag could not be resolved"
    else
        pass "post-build (strict) still correctly reports FAIL for a candidate that legitimately differs from the last hardware-qualified baseline - unchanged, by design"
    fi
else
    echo "SKIP: no built artifacts under $ARTIFACT_DIR or no vendor/x2000_kernel_6.6 yet - run the build pipeline first to exercise the artifact-dependent checks"
fi

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
