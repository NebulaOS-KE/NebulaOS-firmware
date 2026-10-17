#!/bin/sh
# Wire up Buildroot's configuration: the real, already-verified .config this
# project produced (artifacts/buildroot-halley5-v30-image/buildroot.config),
# the kernel config fragment (FIRMWARE.md sec 10-12's additions on top of
# the vendor x2000_halley5_v30_linux defconfig), the LINUX_OVERRIDE_SRCDIR
# pointer, and this repo's own hand-written overlay content.
#
# Reusing the exact verified .config here (rather than re-deriving every
# BR2_PACKAGE_* option from scratch) is deliberate: several of those options
# hit a real class of bug this session where a naive `echo "X=y" >> .config`
# landed on a duplicate line that a later `make olddefconfig` pass then lost
# to the file's *other*, unedited copy of the same symbol (see FIRMWARE.md
# sec 14) - copying the known-good, already-normalized file sidesteps that
# whole class of mistake rather than risking reintroducing it.
#
# IMPORTANT: always re-run this script after ANY change to scripts/build/overlay/
# or the kernel fragment/buildroot.config artifacts, and before 03/05 - a real
# bug this session (FIRMWARE.md sec 24): editing the git-tracked overlay
# template alone does nothing, since Buildroot only ever reads from
# vendor/buildroot-x2000/board/halley5-nebulaos-overlay/ (gitignored), which
# this script is what syncs the template into. A rebuild after only touching
# the template, without re-running this first, silently uses whatever this
# script last copied there.
#
# IMPORTANT: renaming or deleting a file from scripts/build/overlay/ does NOT
# remove it from a real build - a genuinely separate bug from the one above,
# found for real deleting S01tmpfs-datastore in favor of
# S01persistent-datastore (the GuppyScreen persistent-storage work): this
# script re-syncs the overlay TEMPLATE cleanly every time (the rm -rf above),
# but Buildroot's own output/target/ staging directory only ever gets files
# ADDED or OVERWRITTEN by the rootfs-overlay step, never removed, and
# accumulates across every build since the last full clean. Both
# S01tmpfs-datastore (deleted from the overlay days earlier) and
# S01persistent-datastore (its replacement) ended up in the same built image
# at once - actively dangerous here specifically, since the stale script
# re-mounted tmpfs right after the new one finished setting up real
# persistent storage, silently undoing it. Buildroot has no cheap way to
# selectively re-sync output/target/ (its package install stamps live
# elsewhere and do not get invalidated by removing target files directly, so
# deleting output/target/ alone leaves it mostly empty instead of clean) - a
# renamed or deleted overlay file must also be removed by hand from
# vendor/buildroot-x2000/output/target/ before the next 05-final-build.sh, or
# the build needs a full clean. 06-verify.sh also cannot catch this on its
# own: it only inspects rootfs.ext2, and both rootfs.ext2 and rootfs.squashfs
# are built from this same stale output/target/, so a leftover file is wrong
# in both images identically - checking the actual packaged rootfs.squashfs
# directly (e.g. via unsquashfs) is the only real way to confirm a removed
# file is genuinely gone.
#
# Phase 11 (2026-08-15, unified-build-environment migration): this script
# used to wrap every step in `docker run pellcorp/k1-bash-build ...`,
# crossing a container boundary that meant paths differed between the host
# view (/repo/vendor/...) and the container's own view (/repo/... mounted
# from the host root). Now that the whole 00-06 pipeline already runs
# inside ONE unified nebulaos-build container (or directly on a host that
# has build-env/'s tools installed), there is no second boundary to cross -
# every path below is just the real filesystem path, and the root/non-root
# chown dance that used to follow every docker --user root call is gone
# because there's no longer a second UID entering the picture. The
# per-container `--label openke-build-pid=$$` / orphan-container-cleanup
# logic is gone for the same reason: nothing here spawns a container of its
# own to leak.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

DEPS_MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
[ -f "$DEPS_MANIFEST" ] || { echo "FATAL: $DEPS_MANIFEST not found" >&2; exit 1; }
. "$DEPS_MANIFEST"

# 2026-07-23: this and the other numbered build stages all write into the
# same shared vendor/buildroot-x2000 tree - running two of these at once
# (e.g. from two terminals) would silently interleave writes. Cheap
# insurance: a single exclusive lock file, held for the whole script.
exec 9>"$REPO_ROOT/.nebulaos-build.lock"
flock -n 9 || { echo "another build stage already owns $REPO_ROOT/.nebulaos-build.lock" >&2; exit 1; }

BUILDROOT_DIR="$REPO_ROOT/vendor/buildroot-x2000"
ARTIFACTS="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"
# The NebulaOS BR2_EXTERNAL tree. Everything this project adds to Buildroot
# lives here; nothing under $BUILDROOT_DIR is written except local.mk (which
# carries LINUX_OVERRIDE_SRCDIR and has nowhere else to go). That property is
# the acceptance test for the migration - 06-verify.sh's check_vendor_pin()
# allowlist encodes it.
BR2_EXT="$REPO_ROOT/br2-external"
BR2_EXT_BOARD="$BR2_EXT/board/nebulaos-x2000"
export BR2_EXTERNAL="$BR2_EXT"
KERNEL_SRCDIR="$REPO_ROOT/vendor/x2000_kernel_6.6/kernel/kernel-6.6"

if [ ! -d "$BUILDROOT_DIR/.git" ]; then
	echo "vendor/buildroot-x2000 not found - run 00-fetch-vendor-sources.sh first" >&2
	exit 1
fi

# NG1 (2026-10-05): BR2_GLOBAL_PATCH_DIR points at br2-external/patches. Every
# patch there lives in <package>/<version>/, and Buildroot silently falls back
# to <package>/ (empty) when the package version changes - the patch would just
# stop being applied. Refuse that instead: each version directory must equal
# the pinned Buildroot's <PKG>_VERSION, and no patch may sit unversioned.
nebulaos_check_global_patch_versions() {
	_pd="$BR2_EXT/patches"
	[ -d "$_pd" ] || return 0
	_loose=$(find "$_pd" -mindepth 1 -maxdepth 2 -type f -name '*.patch')
	if [ -n "$_loose" ]; then
		echo "FATAL: unversioned patch(es) in $_pd (must be <package>/<version>/*.patch): $_loose" >&2
		return 1
	fi
	for _vd in "$_pd"/*/*/; do
		[ -d "$_vd" ] || continue
		_pkg=$(basename "$(dirname "$_vd")"); _ver=$(basename "$_vd")
		_var=$(printf '%s' "$_pkg" | tr 'a-z-' 'A-Z_')_VERSION
		_have=$(sed -n "s/^${_var}[[:space:]]*=[[:space:]]*//p" "$BUILDROOT_DIR/package/$_pkg/$_pkg.mk" 2>/dev/null | head -1)
		if [ "$_have" != "$_ver" ]; then
			echo "FATAL: stale NebulaOS patch dir br2-external/patches/$_pkg/$_ver: Buildroot's $_pkg is '${_have:-absent}' - re-evaluate or remove the patch" >&2
			return 1
		fi
		echo "OK   br2-external/patches/$_pkg/$_ver matches $_var"
	done
}
nebulaos_check_global_patch_versions || exit 1

# Buildroot 2025.02.18 migration (2026-09-27): the configuration is now
# produced by Buildroot's own defconfig workflow from a minimal, maintainable
# input, instead of copying a 4258-line frozen .config over the tree.
#
#   br2-external/configs/nebulaos_x2000_defconfig   <- INPUT  (84 lines, tracked)
#   artifacts/buildroot-halley5-v30-image/buildroot.config <- OUTPUT (written below)
#
# Both are kept deliberately. The defconfig is what a human edits; the full
# resolved .config is still written back to artifacts/ at the end of this
# script because it is a GATED artifact, not merely a build input -
# baseline-difference-gate.sh and assert-baseline-config.sh diff it verbatim
# against the qualified baseline tag, and a savedefconfig shares almost no
# lines with a full .config, so substituting one for the other would make
# those diffs 100% noise WITHOUT any gate failing. That silence is the danger.
#
# The old duplicate-line hazard this script used to guard against (appending
# "X=y" onto a .config that already had another copy of X, which a later
# olddefconfig then resolved from the OTHER copy) is gone by construction:
# nothing appends to .config any more. `make <defconfig>` writes it from
# scratch every time.
mkdir -p "$BR2_EXT_BOARD"
# BR2_ROOTFS_POST_BUILD_SCRIPT now names this through
# $(BR2_EXTERNAL_NEBULAOS_PATH), so it no longer has to live inside the
# Buildroot tree. It pins the /etc/shadow root hash after the finalize hooks
# and the overlay have run - see the script itself for why neither
# BR2_TARGET_GENERIC_ROOT_PASSWD nor the overlay can do it.
cp "$SCRIPT_DIR/nebulaos-post-build.sh" "$BR2_EXT_BOARD/post-build.sh"
chmod 755 "$BR2_EXT_BOARD/post-build.sh"
# G50: post-build derives the Python ABI fingerprint (lib/python-abi.sh, the
# one place it is derived) and /etc/pip.conf from the manifest's index URL.
cp "$SCRIPT_DIR/lib/python-abi.sh" "$BR2_EXT_BOARD/python-abi.sh"
[ -n "${NEBULAOS_PACKAGE_INDEX_URL:-}" ] || { echo "FATAL: NEBULAOS_PACKAGE_INDEX_URL missing from $DEPS_MANIFEST" >&2; exit 1; }
printf '%s\n' "$NEBULAOS_PACKAGE_INDEX_URL" > "$BR2_EXT_BOARD/package-index.url"
cp "$ARTIFACTS/halley5-nebulaos-busybox-fragment.config" "$BR2_EXT_BOARD/halley5-nebulaos-busybox-fragment.config"
# The kernel configuration is owned by NebulaOS-kernel
# (arch/mips/configs/nebulaos_halley5_v30_defconfig, selected through
# BR2_LINUX_KERNEL_DEFCONFIG). The only kernel setting the firmware build
# supplies is the one that depends on where this build runs: the directory
# CONFIG_EXTRA_FIRMWARE embeds the Wi-Fi firmware and regulatory database from,
# which is the overlay populated below.
printf 'CONFIG_EXTRA_FIRMWARE_DIR="%s"\n' "$BR2_EXT_BOARD/overlay/lib/firmware" \
	> "$BR2_EXT_BOARD/nebulaos-kernel-buildenv.config"
# local.mk is Buildroot's own package-override file
# (BR2_PACKAGE_OVERRIDE_FILE defaults to "$(CONFIG_DIR)/local.mk"). The
# Makefile `-include`s it at line 547, immediately BEFORE
# `include $(sort $(wildcard package/*/*.mk))` at line 550, so variables set
# here are visible to every package .mk as it is evaluated. It is the one
# supported way to influence a package without editing upstream files, and it
# is the single entry on 06-verify.sh's pristineness allowlist.
cat > "$BUILDROOT_DIR/local.mk" <<EOF
LINUX_OVERRIDE_SRCDIR = $KERNEL_SRCDIR

# --- upstream bug workaround: python-contourpy names its extension for the
# --- HOST, not the target.
#
# Found by inspecting a real built rootfs, not by a build failure - the build
# SUCCEEDS and produces a correctly cross-compiled MIPS32 rel2 object. It is
# only the FILENAME that is wrong:
#
#   site-packages/contourpy/_contourpy.cpython-312-x86_64-linux-gnu.so
#
# CPython looks for exactly its own importlib extension suffixes
# (.cpython-312-mipsel-linux-gnu.so, .abi3.so, .so). That name matches none of
# them, so 'import contourpy' fails at runtime - and contourpy is a hard
# dependency of matplotlib, so NebulaOS's calibration and graphing paths break
# with a green build. Exactly the failure mode that makes "it compiled" an
# unsafe proxy for "it works".
#
# Cause: package/python-contourpy/python-contourpy.mk uses \$(eval
# \$(meson-package)) but, unlike its siblings python-matplotlib and
# python-numpy, sets no CONF_ENV. Those two export
# _PYTHON_SYSCONFIGDATA_NAME so the build-time interpreter reads the TARGET's
# sysconfigdata and meson-python derives the correct EXT_SUFFIX. contourpy
# reads the host's instead.
#
# The fix below is byte-for-byte what python-matplotlib and python-numpy
# already do, applied through the override file so no upstream file is
# touched. Recursive (=) assignment, not :=, because PKG_PYTHON_* and
# PYTHON3_PATH are defined later in package/pkg-python.mk and
# package/python3/python3.mk.
#
# Worth reporting upstream; remove this when a Buildroot release carries the
# CONF_ENV in the package itself. 06-verify.sh now fails the build if ANY
# target extension carries a foreign ABI tag, so a regression here cannot go
# unnoticed again.
PYTHON_CONTOURPY_CONF_ENV += \\
	_PYTHON_SYSCONFIGDATA_NAME=\$(PKG_PYTHON_SYSCONFIGDATA_NAME) \\
	PYTHONPATH=\$(PYTHON3_PATH)
EOF
rm -rf "$BR2_EXT_BOARD/overlay"
mkdir -p "$BR2_EXT_BOARD/overlay"
cp -r "$REPO_ROOT/scripts/build/overlay/." "$BR2_EXT_BOARD/overlay/"
mkdir -p "$BR2_EXT_BOARD/overlay/opt/printer_data/comms" \
         "$BR2_EXT_BOARD/overlay/opt/printer_data/logs" \
         "$BR2_EXT_BOARD/overlay/opt/printer_data/gcodes"
# Real bug found live on 2026-07-28: this rm -rf/cp only cleans the BOARD
# overlay staging dir (above), not output/target/ or
# output/build/buildroot-fs/ext2/target/ - per the IMPORTANT comment near
# the top of this file, those two are additive-only and keep every
# renamed-away overlay file forever unless a full clean is done. This has
# now bitten three separate renames (S01tmpfs-datastore ->
# S01persistent-datastore; S39wifi -> S01wifi; S03nebulaos-factory-seed/
# S04nebulaos-activate -> S04nebulaos-factory-seed/S05nebulaos-activate),
# and the last two shipped together on a real flashed device: BOTH old and
# new init.d scripts were present in the same booted squashfs, and because
# the new activate scripts bind_if_not_already() no-ops when its target
# is already mounted, the OLD (pre-fix, less-validated) activation script -
# which sorts earlier and ran first - was the one actually deciding every
# real bind-mount, silently shadowing the fix. Clean every historically
# renamed/removed overlay-relative path from both real output copies here;
# add to this list whenever an overlay file is renamed or deleted, the same
# way dcf7060 does for the seed archives in 04-cross-compile-app-stack.sh.
for obsolete_rel in \
	"etc/init.d/S01tmpfs-datastore" \
	"etc/init.d/S39wifi" \
	"etc/init.d/S03nebulaos-factory-seed" \
	"etc/init.d/S04nebulaos-activate"; do
	rm -f "$BUILDROOT_DIR/output/target/$obsolete_rel" \
	      "$BUILDROOT_DIR/output/build/buildroot-fs/ext2/target/$obsolete_rel" 2>/dev/null || true
done
# Buildroot 2025.02.18 migration: two edits to UPSTREAM Buildroot files used to
# happen here and are both gone.
#
#   1. package/python-matplotlib/python-matplotlib.mk was overwritten wholesale
#      with a vendored copy pinned to matplotlib 3.4.3 and pointed at a local
#      wheel directory (board/halley5-nebulaos-wheels/, carrying a prebuilt
#      numpy cp311 mipsel wheel). That workaround existed because matplotlib
#      3.4.3 built via setup.py, whose legacy setup_requires/fetch_build_eggs
#      path ran a nested pip that inherited _PYTHON_HOST_PLATFORM=linux-mipsel
#      and tried to resolve host build dependencies as target ones.
#      2025.02.18 ships python-matplotlib 3.10.0 and python-numpy 1.25.0 as
#      ordinary packages, and 3.10.0 builds through meson-python - the
#      setup_requires mechanism that caused the problem does not exist in that
#      path at all. Stock packages are used now; the vendored .mk and the
#      cp311 wheel are deleted.
#
#   2. package/squashfs/squashfs.{mk,hash} were sed-patched to switch from
#      GitHub's mutable auto-generated tag archive to the immutable release
#      asset. That was a backport of an upstream fix; 2025.02.18 already sets
#      SQUASHFS_SITE to the releases/download URL and already hashes
#      squashfs-tools-4.6.1.tar.gz. The sed was verified to be a no-op there
#      (its `call github,plougher` precondition is false), so it is deleted
#      rather than left as dead code guarding nothing.
#
# The rule this encodes: NO file under $BUILDROOT_DIR is modified by this
# project. A package Buildroot does not provide goes in br2-external/package/,
# never as a cp over package/.

# NOTE: the defconfig is deliberately NOT copied into $BUILDROOT_DIR/configs/.
#
# Buildroot's %_defconfig rule already searches every BR2_EXTERNAL tree -
# Makefile line 1056-1060 iterates $(call reverse,$(TOPDIR) $(BR2_EXTERNAL_DIRS))
# - so `make BR2_EXTERNAL=... nebulaos_x2000_defconfig` resolves it straight out
# of br2-external/configs/ with no staging at all. Verified against a pristine
# 2025.02.18 checkout: the defconfig resolves, GCC comes out 13.4.0, and
# `git status --porcelain -uall` on the Buildroot tree stays completely empty.
#
# An earlier revision did copy it "so the name resolves identically whether or
# not BR2_EXTERNAL is exported". That was unnecessary, and it cost real ground:
# it left configs/nebulaos_x2000_defconfig as an untracked file inside the
# upstream checkout, which 06-verify.sh correctly reported as an unexplained
# working-tree change. The whole point of the BR2_EXTERNAL move is that nothing
# but local.mk is written there.

echo "== generating .config from nebulaos_x2000_defconfig =="
( cd "$BUILDROOT_DIR" && make BR2_EXTERNAL="$BR2_EXT" nebulaos_x2000_defconfig )
# Kernel configuration profile (SOT-51): production uses the kernel-owned
# defconfig plus the build-environment fragment; diagnostic also merges the
# kernel-owned diagnostic delta. Selected only by the committed manifest.
case "$KERNEL_CONFIG_PROFILE" in
	production) FRAGS='$(BR2_EXTERNAL_NEBULAOS_PATH)/board/nebulaos-x2000/nebulaos-kernel-buildenv.config' ;;
	diagnostic) FRAGS="\$(BR2_EXTERNAL_NEBULAOS_PATH)/board/nebulaos-x2000/nebulaos-kernel-buildenv.config $KERNEL_SRCDIR/arch/mips/configs/nebulaos_halley5_v30_diagnostic.config" ;;
	*) echo "FATAL: KERNEL_CONFIG_PROFILE must be production|diagnostic (got '$KERNEL_CONFIG_PROFILE')" >&2; exit 1 ;;
esac
sed -i "s#^BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES=.*#BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES=\"$FRAGS\"#" "$BUILDROOT_DIR/.config"
echo "== kernel config profile: $KERNEL_CONFIG_PROFILE =="

echo "== normalizing .config (resolves any derived Kconfig selects) =="
( cd "$BUILDROOT_DIR" && make BR2_EXTERNAL="$BR2_EXT" olddefconfig )

# A configuration that still selects options Buildroot has REMOVED sets
# BR2_LEGACY, and Buildroot refuses to build in that state. Catch it here with
# a clear message rather than several minutes into `make`.
if grep -qE '^BR2_LEGACY=y$' "$BUILDROOT_DIR/.config"; then
	echo "FATAL: the resolved .config sets BR2_LEGACY=y - it still selects options that" >&2
	echo "Buildroot 2025.02.18 has removed. Resolve them in" >&2
	echo "br2-external/configs/nebulaos_x2000_defconfig; do not mask them." >&2
	grep -B2 'BR2_LEGACY' "$BUILDROOT_DIR/.config" | head -20 >&2
	exit 1
fi

# Write the fully resolved .config back to the tracked artifact. This is NOT a
# convenience copy: artifacts/buildroot-halley5-v30-image/buildroot.config is a
# GATED baseline artifact. baseline-difference-gate.sh and
# assert-baseline-config.sh diff it verbatim against QUALIFIED_BASELINE_TAG,
# and lib/baseline-config-compare.sh carries filters written specifically for
# a full .config's shape. Keeping the defconfig as the human-edited INPUT and
# this file as the generated OUTPUT is what lets the minimal defconfig exist
# without silently disarming those gates.
cp "$BUILDROOT_DIR/.config" "$ARTIFACTS/buildroot.config"
echo "== resolved .config written back to artifacts/buildroot-halley5-v30-image/buildroot.config =="

# Reproducibility fix (2026-07-26, NebulaOS mutable-runtime mission): a real
# bug found by directly inspecting the built rootfs.squashfs with unsquashfs
# instead of trusting 05-final-build.sh's exit code - enabling
# BR2_PACKAGE_LIBOPENSSL_BIN=y (the openssl CLI) above did NOT get the
# openssl binary into the image, because libopenssl had already been built
# once before (as a transitive dependency of git/python3-ssl/curl) with that
# suboption off, and Buildroot's own per-package build stamps
# (output/build/<pkg>/.stamp_*) are not invalidated by a suboption-only
# .config change - only by the package's own source/patch/version changing.
# This is a general Buildroot limitation, not specific to openssl: ANY
# suboption added to an already-built package needs an explicit dirclean, or
# it silently keeps the old build. Forcing it here (rather than relying on
# whoever runs this script next to remember to do it by hand, which is
# exactly how this was first missed) makes the fix part of the tracked
# pipeline instead of a one-off manual step - dirclean is a safe no-op if
# the package was never built yet (e.g. on a genuinely fresh output/ tree).
(
	cd "$BUILDROOT_DIR"
	make libopenssl-dirclean 2>/dev/null || true
	# Same class of bug, found again (Memory Resilience Gate, 2026-07-26):
	# adding CONFIG_FEATURE_SWAPON_PRI via the busybox config fragment had
	# no effect on an already-built busybox (confirmed live on a flashed
	# image: swapon rejected the priority option outright) - same
	# stale-stamp mechanism as the libopenssl case above.
	make busybox-dirclean 2>/dev/null || true
)

echo "== buildroot configured =="
