#!/bin/sh
#
# Phase 1.5 closure mission (2026-08-19). Semantic (not byte-identical)
# comparison of a resolved build artifact against the qualified baseline tag,
# for the narrow, named, PROVEN non-behavioral fields below only. Everything
# else in the file is still compared byte-for-byte - this is deliberately
# not a general "ignore version strings" or "ignore paths" filter, which
# would weaken the safety gate this exists to be. See
# _project/missions/2026-08-phase1.5-persistent-namespace.md's closure
# section for the full root-cause investigation behind each entry below.
#
# kernel.config:
#   CONFIG_CC_VERSION_TEXT - the cross-compiler's own self-identification
#     banner string, baked in at TOOLCHAIN BUILD time from Buildroot's
#     BR2_VERSION_FULL. Proven non-behavioral: it does not affect what code
#     the compiler generates, and /etc/os-release's PRETTY_NAME (Buildroot's
#     Makefile line ~766) uses the separate, always-static $(BR2_VERSION)
#     directly, confirming this field is purely cosmetic self-description,
#     not a real version gate anything else depends on.
#   CONFIG_EXTRA_FIRMWARE_DIR - the build CONTAINER's internal mount path
#     for firmware source files (build.sh's own $NEBULAOS_REPO_ROOT, changed
#     2026-08-15 by the unrelated Final Closure mission specifically to stop
#     host-path leakage into artifacts - this field is exactly that leakage,
#     just relocated to a fixed, still-non-behavioral internal path). Only
#     read during the kernel BUILD to locate firmware blobs to embed; the
#     actual embedded firmware content is identical either way (both build
#     from the same pinned, hash-verified blobs - see 00-fetch-vendor-
#     sources.sh) and this string does not appear anywhere in the running
#     kernel's actual behavior.
#
# buildroot.config:
#   The "# Buildroot <version> Configuration" auto-generated header comment
#     - same BR2_VERSION_FULL string as CONFIG_CC_VERSION_TEXT above, same
#     reasoning, same conclusion.
#   BR2_HOST_GCC_AT_LEAST_* - Buildroot's own auto-detection of the BUILD
#     CONTAINER's installed host gcc version (Config.in probes the host
#     compiler directly), which is newer in the current unified build image
#     than whatever produced the baseline. Checked, not assumed: grepped the
#     entire vendored Buildroot tree for every real Config.in reference to
#     BR2_HOST_GCC_AT_LEAST_10/11 - the ONLY package in the whole tree that
#     conditions anything on them is nodejs's own Config.in, and
#     BR2_PACKAGE_NODEJS is not set anywhere in this project's
#     buildroot.config (confirmed directly, not assumed) - so these two
#     extra flags being set changes the resolved configuration of zero
#     packages this project actually builds.
#
# All of the above trace to ONE underlying event, not three unrelated ones:
# this qualified baseline tag is dated 2026-08-14, one day BEFORE the
# unrelated Final Closure mission (2026-08-15) promoted the current unified
# build image (ghcr.io/nebulaos-ke/nebulaos-build) to canonical and retired
# the previous pellcorp/k1-bash-build + guppydev container pair. The
# baseline's own build-manifest.txt (read directly via `git show
# nebulaos-canonical-baseline-2026-08-14-prtouch-qualified:artifacts/.../
# build-manifest.txt`) has no build_image_repo/build_image_digest fields at
# all - that tracking was added BY the Final Closure mission - confirming
# the baseline predates the current pinned build image and was never
# re-captured after the switch. Classification: BASELINE_CAPTURE_DEFECT at
# the root (a legitimate, already-completed, unrelated infrastructure
# migration whose baseline was never refreshed), producing symptoms that
# are each individually proven EXPECTED_AND_NON_BEHAVIORAL above.
#
# Both root causes trace to the SAME underlying, already-existing, already-
# intentional fact, independently confirmed from Buildroot's own source
# (vendor/buildroot-x2000/support/scripts/setlocalversion, borrowed
# unmodified from the Linux kernel's identical convention): BR2_VERSION_FULL
# only falls back to the clean, static "2023.11.1" when Buildroot's own
# setlocalversion script produces empty output, which requires EITHER no
# .git directory in the checkout, OR (with .git present) both a reachable
# git tag AND a fully clean tree. The pinned fork
# (https://github.com/lone0/buildroot-x2000.git) has zero tags anywhere in
# its history (`git tag | wc -l` = 0, checked directly) - so this string can
# NEVER be a clean tag name for ANY build from this pin, only ever
# "-g<shortsha>[-dirty]". The tree is also deterministically "dirty" on
# every single build for a second, independently-confirmed, already-
# documented reason: 02-configure-buildroot.sh intentionally overwrites
# package/python-matplotlib/python-matplotlib.mk with a tracked NebulaOS fix
# for a real cross-compilation bug (numpy build-isolation poisoning under
# _PYTHON_HOST_PLATFORM overrides) on every build - already allowlisted as
# "expected every time, not accidental drift" in this same script's own
# check_vendor_pin call for buildroot-x2000, just never connected to this
# separate baseline comparison until now.
#
# Usage: baseline_config_semantic_diff <file-relpath-under-artifact-dir> <current-file> <baseline-ref> <repo-root>
# Returns 0 if semantically identical (after stripping only the field(s)
# named for that file above), 1 and prints a diff otherwise.
baseline_config_semantic_diff() {
	bcsd_relpath="$1"
	bcsd_current="$2"
	bcsd_baseline_ref="$3"
	bcsd_repo_root="$4"

	case "$bcsd_relpath" in
		kernel.config)
			bcsd_filter='/^CONFIG_CC_VERSION_TEXT=/d; /^CONFIG_EXTRA_FIRMWARE_DIR=/d'
			;;
		buildroot.config)
			bcsd_filter='/^# Buildroot .* Configuration$/d; /^BR2_HOST_GCC_AT_LEAST_[0-9]*=y$/d'
			;;
		*)
			bcsd_filter=''
			;;
	esac

	# No RETURN trap here (not POSIX, and /bin/sh may be dash) - both exit
	# paths below explicitly clean up their own temp files instead.
	# Fail closed: an empty path here would silently retarget the writes
	# below at the caller's own working directory (see make-seed-archive.sh
	# for the same hazard, and what it actually did to a real checkout).
	bcsd_tmp_baseline=$(mktemp) || return 1
	bcsd_tmp_current=$(mktemp) || { rm -f "$bcsd_tmp_baseline"; return 1; }
	[ -n "$bcsd_tmp_baseline" ] && [ -n "$bcsd_tmp_current" ] || {
		rm -f "$bcsd_tmp_baseline" "$bcsd_tmp_current"
		return 1
	}

	if ! git -C "$bcsd_repo_root" show "$bcsd_baseline_ref:artifacts/buildroot-halley5-v30-image/$bcsd_relpath" > "$bcsd_tmp_baseline" 2>/dev/null; then
		rm -f "$bcsd_tmp_baseline" "$bcsd_tmp_current"
		echo "FATAL: could not read artifacts/buildroot-halley5-v30-image/$bcsd_relpath from $bcsd_baseline_ref" >&2
		return 2
	fi
	cp "$bcsd_current" "$bcsd_tmp_current"

	if [ -n "$bcsd_filter" ]; then
		sed -i "$bcsd_filter" "$bcsd_tmp_baseline" "$bcsd_tmp_current"
	fi

	if diff -u "$bcsd_tmp_baseline" "$bcsd_tmp_current" > "$bcsd_tmp_current.diff" 2>&1; then
		rm -f "$bcsd_tmp_baseline" "$bcsd_tmp_current" "$bcsd_tmp_current.diff"
		return 0
	else
		cat "$bcsd_tmp_current.diff" >&2
		rm -f "$bcsd_tmp_baseline" "$bcsd_tmp_current" "$bcsd_tmp_current.diff"
		return 1
	fi
}
