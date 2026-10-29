#!/bin/sh
# The one documented command to reproduce the current qualified NebulaOS
# baseline from a fresh clone:
#
#   git clone https://github.com/NebulaOS-KE/NebulaOS-firmware.git
#   cd NebulaOS-firmware
#   ./build.sh
#
# Fetches every pinned dependency (kernel, Klipper, GuppyScreen, Moonraker,
# Buildroot, ustreamer, Mainsail, wireless-regdb, WiFi firmware - see
# manifests/dependencies.conf), composes all 8 accepted baseline variants,
# builds the kernel/rootfs/app-stack, and verifies the result against the
# accepted-baseline assertions - scripts/build/build-qualified-baseline.sh
# does the actual sequencing; this is a thin, host-dependency-aware wrapper
# around it, not a reimplementation.
#
# Phase 11 (2026-08-15, unified-build-environment migration): this used to
# have two modes - run directly on a host with git/curl/etc already
# installed, or `--containerized` to get those from a thin wrapper image
# that then launched TWO MORE nested containers (pellcorp/k1-bash-build,
# ghcr.io/coreflake1/guppydev) via the host's own Docker socket for the
# actual work. That nested-container design is gone. There is now exactly
# ONE container, pinned by digest in manifests/dependencies.conf
# (BUILD_IMAGE_REPO/BUILD_IMAGE_DIGEST) - it already contains every host
# build tool the 00-06 pipeline needs (see build-env/Dockerfile), so
# nothing here or inside those stages ever calls `docker`/`apt-get` again.
#
# Requires on the host: Docker or Podman, and nothing else - not even git,
# since the container itself is what clones/builds everything once it's
# running with this checkout mounted in.
#
# Does NOT reuse any existing vendor/, build-work/, or artifacts/ state by
# itself - run this against a genuinely fresh clone for a real clean-room
# result (an already-populated vendor/ is convenient for iteration but
# defeats the point of using this script to prove reproducibility).
#
# Exits non-zero if any pin fails to resolve, any variant fails to apply,
# either baseline assertion fails, or any build stage fails - this script
# propagates the container's real exit status, it does not swallow it.

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MANIFEST="$SCRIPT_DIR/manifests/dependencies.conf"
[ -f "$MANIFEST" ] || { echo "FATAL: $MANIFEST not found" >&2; exit 1; }
. "$MANIFEST"

: "${BUILD_IMAGE_REPO:?FATAL: BUILD_IMAGE_REPO not set in $MANIFEST}"
: "${BUILD_IMAGE_DIGEST:?FATAL: BUILD_IMAGE_DIGEST not set in $MANIFEST}"
IMAGE_REF="${BUILD_IMAGE_REPO}@${BUILD_IMAGE_DIGEST}"

# --- BUILD MODE: dev by default, release when it matters -------------------
# Two modes, and the DEFAULT IS THE SAFE-TO-BE-SLOW ONE only in the sense that
# release never silently inherits a dev shortcut:
#
#   dev      (default)  ./build.sh            - reuse what is provably safe to
#                       reuse so that edit -> rebuild -> test is not a
#                       from-scratch build every time
#   release  ./build.sh --release             - fresh output, ccache OFF,
#                       exact pins. What a candidate/qualification build runs.
#
# RELEASE IS STICKY AND CANNOT BE DOWNGRADED. It is entered by --release, by
# NEBULAOS_RELEASE_BUILD=1, or by NEBULAOS_CANDIDATE_BUILD=1 - the last of
# these is what the privileged build launcher already sets, so every existing
# candidate build becomes release-grade without the launcher asking for it.
# That direction is the important one: a forgotten flag must never turn a
# qualification build into an accelerated one.
NEBULAOS_BUILD_MODE=dev
for arg in "$@"; do
	case "$arg" in
		--release) NEBULAOS_BUILD_MODE=release ;;
		--dev)     NEBULAOS_BUILD_MODE=dev ;;
		*) echo "FATAL: unknown option '$arg'. build.sh accepts --release or --dev." >&2; exit 1 ;;
	esac
done
if [ "${NEBULAOS_CANDIDATE_BUILD:-}" = "1" ] || [ "${NEBULAOS_RELEASE_BUILD:-}" = "1" ]; then
	NEBULAOS_BUILD_MODE=release
fi
export NEBULAOS_BUILD_MODE
echo "== build.sh: NEBULAOS_BUILD_MODE=$NEBULAOS_BUILD_MODE =="

# --- persistent download cache (BOTH modes) --------------------------------
# Shared by dev and release on purpose. A downloaded tarball is not build
# output: 00-fetch-vendor-sources.sh resolves every source by an exact pin and
# Buildroot verifies each archive against its own hash file before using it, so
# a cache hit is indistinguishable from a fresh fetch except in wall time.
# Reusing downloads therefore costs nothing in reproducibility while removing
# the single largest fixed cost of a from-scratch build.
#
# It is NEVER treated as generated output: nothing here writes build products
# into it, and the release path's "fresh output" rule does not extend to it.
NEBULAOS_DL_CACHE=${NEBULAOS_DL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/nebulaos/buildroot-dl}
if mkdir -p "$NEBULAOS_DL_CACHE" 2>/dev/null; then
	if [ -z "$(ls -A "$NEBULAOS_DL_CACHE" 2>/dev/null)" ]; then
		NEBULAOS_DL_CACHE_WAS_EMPTY=1
	else
		NEBULAOS_DL_CACHE_WAS_EMPTY=0
	fi
	echo "== build.sh: download cache $NEBULAOS_DL_CACHE (was_empty=$NEBULAOS_DL_CACHE_WAS_EMPTY) =="
else
	echo "== build.sh: WARNING: cannot create download cache $NEBULAOS_DL_CACHE - continuing without it ==" >&2
	NEBULAOS_DL_CACHE=""
	NEBULAOS_DL_CACHE_WAS_EMPTY=1
fi

# --- compiler ccache (DEV ONLY) --------------------------------------------
# Hard rule: OFF for release. Qualification must not depend on the correctness
# of a compiler cache. This is not a tunable - there is no flag that turns it
# on in release mode, because "prove these bytes are reproducible" and "trust a
# cache to have returned the right object file" are not compatible claims.
NEBULAOS_CCACHE_DIR=${NEBULAOS_CCACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/nebulaos/ccache}
NEBULAOS_CCACHE_MAXSIZE=${NEBULAOS_CCACHE_MAXSIZE:-8G}
NEBULAOS_CCACHE=0
if [ "$NEBULAOS_BUILD_MODE" = dev ]; then
	if mkdir -p "$NEBULAOS_CCACHE_DIR" 2>/dev/null; then
		NEBULAOS_CCACHE=1
		echo "== build.sh: ccache ENABLED (dev) $NEBULAOS_CCACHE_DIR max=$NEBULAOS_CCACHE_MAXSIZE =="
	else
		echo "== build.sh: WARNING: cannot create ccache dir $NEBULAOS_CCACHE_DIR - building without ccache ==" >&2
	fi
else
	echo "== build.sh: ccache DISABLED (release/candidate build) =="
fi

ENGINE=""
for candidate in docker podman; do
	command -v "$candidate" >/dev/null 2>&1 && { ENGINE="$candidate"; break; }
done
[ -n "$ENGINE" ] || {
	echo "FATAL: neither docker nor podman found on this host - one of them is required to run the pinned build environment ($IMAGE_REF)." >&2
	exit 1
}

echo "== build.sh: pulling pinned build environment $IMAGE_REF (engine: $ENGINE) =="
"$ENGINE" pull "$IMAGE_REF"

# NEBULAOS_REPO_ROOT: fixed container-internal mount point, deliberately
# NOT the host's own checkout path.
#
# Final Closure mission, Phase C (2026-08-15): this used to mount the
# checkout at the SAME absolute path inside the container as outside it
# (-v "$SCRIPT_DIR:$SCRIPT_DIR"), reasoned at the time as avoiding a path
# boundary crossing. That reasoning missed a real consequence, found by
# the Phase 9 vs Phase 11 artifact comparison: the host's own checkout
# path (which varies - different developers, different clone locations,
# even the same developer's own repeated test directories in this
# session) leaks straight into the build. CONFIG_EXTRA_FIRMWARE_DIR
# embedded it directly; GuppyScreen's binary carried ~770KB of diff
# traced to embedded absolute build-path strings, purely because the
# container saw a different host path on every separate clone. Two
# builds of byte-identical source, in the byte-identical image, produced
# different output for a reason that has nothing to do with the product.
#
# Mounting at one fixed internal path instead - regardless of where the
# user actually cloned this repo on the host - means every build sees the
# identical internal path, so anything that embeds it (Kconfig strings,
# __FILE__/assert() macros, debug info) embeds the same bytes every time.
# Every script under scripts/build/ already derives its own location via
# `SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)` rather than a hardcoded
# path, so this needs no changes anywhere else - they'll all resolve to
# NEBULAOS_REPO_ROOT automatically once the working directory is set here.
# Output files stay on the host exactly as before: a bind mount is a
# transparent, two-way passthrough regardless of which internal path it's
# mounted at, so anything the container writes under NEBULAOS_REPO_ROOT
# still lands at $SCRIPT_DIR on the host.
NEBULAOS_REPO_ROOT=/workspace/NebulaOS-firmware

# Phase 1.5 persistent-namespace mission (2026-08): 06-verify.sh (and any
# other in-container script that shells out to `git` against the checkout)
# used to hard-fail with "fatal: not a git repository" whenever $SCRIPT_DIR
# is a git WORKTREE rather than a normal clone. A worktree's own .git is a
# FILE containing "gitdir: <host-absolute-path>/.git/worktrees/<name>" -
# that path is real on the host but does not exist inside the container,
# so any git command that walks up from $NEBULAOS_REPO_ROOT to resolve it
# fails outright, aborting the whole build under `set -e`.
#
# Fix: if that's a worktree, bind-mount the real git-common-dir it points
# at, AT THE SAME HOST-ABSOLUTE PATH, read-only, so the pointer resolves
# inside the container exactly like it does on the host. This is the one
# deliberate exception to the "container never sees a host path" rule
# above (Final Closure mission, Phase C) - that rule exists because a host
# path embedded in $NEBULAOS_REPO_ROOT can leak into compiled artifacts
# (Kconfig strings, debug info); a read-only mount used only for `git`
# metadata queries never touches compiled output, so it does not
# reintroduce that problem. A normal clone (.git is a real directory) needs
# no extra mount - it already resolves entirely inside $SCRIPT_DIR, which
# is already bind-mounted above.
HOST_GIT_COMMON_DIR=""
if [ -f "$SCRIPT_DIR/.git" ]; then
	# git rev-parse --git-common-dir is not guaranteed absolute across git
	# versions/invocation contexts - cd into whatever it prints and take
	# `pwd` to get a real, canonical absolute path regardless.
	GIT_COMMON_DIR_RAW=$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null || true)
	if [ -n "$GIT_COMMON_DIR_RAW" ]; then
		# GIT_COMMON_DIR_RAW may be relative - if so it is relative to
		# $SCRIPT_DIR (where the git command ran via -C), not to this
		# script's own cwd, so resolve it from there explicitly.
		HOST_GIT_COMMON_DIR=$(cd "$SCRIPT_DIR" && cd "$GIT_COMMON_DIR_RAW" 2>/dev/null && pwd)
	fi
	if [ -n "$HOST_GIT_COMMON_DIR" ] && [ -d "$HOST_GIT_COMMON_DIR" ]; then
		echo "== build.sh: $SCRIPT_DIR is a git worktree - bind-mounting its common git dir ($HOST_GIT_COMMON_DIR) read-only so in-container git commands can resolve it =="
	else
		HOST_GIT_COMMON_DIR=""
		echo "== build.sh: WARNING: $SCRIPT_DIR looks like a git worktree but its common git dir could not be resolved on the host - in-container git metadata (git_commit_main, 06-verify.sh's pin checks) will report 'absent'/fail rather than guess ==" >&2
	fi
fi

# -e HOME=/tmp: an arbitrary host UID has no /etc/passwd entry inside the
# container, so HOME defaults to "/" (not writable by this UID) - confirmed
# live this would break any tool that wants to write a cache/config file
# (pip's download cache, git's config lookup). /tmp is writable by anyone
# and doesn't need to persist across runs.
# No -it: found live running this in the background (nohup, no attached
# terminal) - `-t` fails outright ("cannot attach stdin to a TTY-enabled
# container because stdin is not a terminal") when there's no real TTY, and
# this build never actually needs interactive stdin either way. Plain `-i`
# without `-t` would still block waiting on stdin in a backgrounded/piped
# invocation with none available - dropping both is correct for a batch
# build, not just a workaround.
# POSIX sh has no arrays, so the optional extra mount is built as
# positional parameters instead of a conditionally-included string (unsafe
# with paths containing spaces).
# REPRODUCIBILITY. One deterministic SOURCE_DATE_EPOCH for the whole build,
# derived from the committer date of the firmware commit being built. Every
# consumer that honours it - Buildroot under BR2_REPRODUCIBLE, mkimage, gzip,
# mksquashfs, Python bytecode - then stops reading the wall clock.
#
# Derived, never hardcoded: it follows the commit. A build from a dirty or
# non-git tree has no defensible epoch, so it fails rather than silently
# falling back to `date +%s` and producing an unreproducible image.
#
# NOTE this is the IMAGE epoch. scripts/build/04 separately derives a
# NebulaScreen epoch from NEBULASCREEN_PIN, scoped to that subshell, because that
# binary should track its pin rather than the firmware commit. Two epochs, two
# deliberate scopes.
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
	SOURCE_DATE_EPOCH=$(git -C "$SCRIPT_DIR" show -s --format=%ct HEAD 2>/dev/null || echo "")
fi
case "${SOURCE_DATE_EPOCH:-}" in
	''|*[!0-9]*)
		echo "FATAL: cannot derive SOURCE_DATE_EPOCH from the firmware commit - refusing to produce an image whose bytes depend on the wall clock" >&2
		exit 1 ;;
esac
export SOURCE_DATE_EPOCH
echo "== build.sh: SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH ($(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')) =="

set -- "$ENGINE" run --rm \
	--user "$(id -u):$(id -g)" \
	-e HOME=/tmp \
	-e NEBULAOS_REPO_ROOT="$NEBULAOS_REPO_ROOT" \
	-e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
	-v "$SCRIPT_DIR:$NEBULAOS_REPO_ROOT"
# Phase 1.5 closure mission (2026-08-19): forwarded from the host
# environment so `NEBULAOS_REQUIRE_CLEAN_TREE=1 ./build.sh` actually reaches
# 05-final-build.sh's existing opt-in gate - previously unreachable through
# this entrypoint at all, since nothing passed it into the container. Unset
# by default, so ordinary iterative builds are unaffected.
if [ -n "${NEBULAOS_REQUIRE_CLEAN_TREE:-}" ]; then
	set -- "$@" -e "NEBULAOS_REQUIRE_CLEAN_TREE=$NEBULAOS_REQUIRE_CLEAN_TREE"
fi
if [ "${NEBULAOS_CANDIDATE_BUILD:-}" = "1" ]; then
	set -- "$@" -e "NEBULAOS_CANDIDATE_BUILD=1"
fi
# Mode is forwarded so the stages can report it; the caches are forwarded as a
# mount plus the env var that names its CONTAINER-INTERNAL path. The internal
# path is fixed and independent of where the cache lives on the host, for the
# same reason the checkout is mounted at a fixed internal path: a host path
# that varies per machine must not reach anything that might embed it.
set -- "$@" -e "NEBULAOS_BUILD_MODE=$NEBULAOS_BUILD_MODE"
if [ -n "$NEBULAOS_DL_CACHE" ]; then
	set -- "$@" -v "$NEBULAOS_DL_CACHE:/nebulaos-cache/dl" \
		-e "BR2_DL_DIR=/nebulaos-cache/dl" \
		-e "NEBULAOS_DL_CACHE_WAS_EMPTY=$NEBULAOS_DL_CACHE_WAS_EMPTY"
fi
if [ "$NEBULAOS_CCACHE" = "1" ]; then
	set -- "$@" -v "$NEBULAOS_CCACHE_DIR:/nebulaos-cache/ccache" \
		-e "CCACHE_DIR=/nebulaos-cache/ccache" \
		-e "CCACHE_MAXSIZE=$NEBULAOS_CCACHE_MAXSIZE" \
		-e "NEBULAOS_CCACHE=1"
fi
if [ -n "$HOST_GIT_COMMON_DIR" ]; then
	set -- "$@" -v "$HOST_GIT_COMMON_DIR:$HOST_GIT_COMMON_DIR:ro"
fi
set -- "$@" -w "$NEBULAOS_REPO_ROOT" "$IMAGE_REF" "sh scripts/build/build-qualified-baseline.sh"
exec "$@"
