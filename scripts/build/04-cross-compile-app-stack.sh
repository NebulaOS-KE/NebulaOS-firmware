#!/bin/sh
# Cross-compile the handful of things that need the Buildroot-built
# toolchain directly (Klipper's chelper C extension, Moonraker's
# streaming-form-data C extension, ustreamer itself), download the
# pure-Python wheels with no Buildroot package, and assemble the full
# app-stack overlay - Klipper/Moonraker source, Mainsail's static build,
# and everything above - on top of the hand-written files stage 2 already
# put in place.
#
# Must run after 03-build-kernel-and-rootfs.sh - needs the Buildroot
# toolchain and target Python headers to already be built.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

# 2026-08-07: GUPPYSCREEN_VERSION/GUPPYSCREEN_THEME (section 6, below) come
# from the same authoritative pin manifest 00-fetch-vendor-sources.sh
# already sources - see that script/manifests/dependencies.conf's own
# header for why pins live in one file instead of being hardcoded per-script.
MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
[ -f "$MANIFEST" ] || {
	echo "FATAL: $MANIFEST not found - this is the one authoritative dependency pin file, required to build at all" >&2
	exit 1
}
. "$MANIFEST"

# 2026-07-23: see 02-configure-buildroot.sh for why this lock exists.
exec 9>"$REPO_ROOT/.nebulaos-build.lock"
flock -n 9 || { echo "another build stage already owns $REPO_ROOT/.nebulaos-build.lock" >&2; exit 1; }

# Phase 11 (2026-08-15): the orphaned-container-cleanup loop and per-call
# `--label openke-build-pid=$$` that used to live here are gone - nothing in
# this script spawns a nested container of its own any more to leak (see
# 02-configure-buildroot.sh's own Phase 11 note for the full rationale).
VENDOR="$REPO_ROOT/vendor"
BUILDROOT_DIR="$VENDOR/buildroot-x2000"
# The rootfs overlay staging directory. Buildroot 2025.02.18 migration: this
# moved out of the upstream Buildroot checkout
# ($BUILDROOT_DIR/board/halley5-nebulaos-overlay) and into the NebulaOS
# BR2_EXTERNAL tree, so that nothing under vendor/buildroot-x2000 is written
# except local.mk.
#
# It MUST stay identical to the path 02-configure-buildroot.sh populates and
# to BR2_ROOTFS_OVERLAY in br2-external/configs/nebulaos_x2000_defconfig. A
# mismatch is silent and expensive: stage 04 writes the entire application
# payload (Klipper, Moonraker, Mainsail, GuppyScreen) into a directory
# Buildroot never reads, and stage 05 then produces a rootfs that builds
# cleanly and simply has no application stack in it. That exact mismatch
# happened when the overlay was first relocated - 04 kept the old literal and
# only failed later, on a missing config directory, several hundred lines
# after the real divergence.
#
# tests/overlay-path-consistency-tests.sh asserts the three agree.
OVERLAY="$REPO_ROOT/br2-external/board/nebulaos-x2000/overlay"
TOOLCHAIN_HOST="$BUILDROOT_DIR/output/host"
SYSROOT="$TOOLCHAIN_HOST/mipsel-buildroot-linux-gnu/sysroot"
WORK="$REPO_ROOT/build-work/app-stack-extras"

if [ ! -x "$TOOLCHAIN_HOST/bin/mipsel-buildroot-linux-gnu-gcc" ]; then
	echo "Buildroot toolchain not built - run 03-build-kernel-and-rootfs.sh first" >&2
	exit 1
fi

# Production optimization mission, Phase 4 (2026-07-30): Buildroot's own
# HOST-built python3 - identical CPython 3.11 version/build to the target,
# so bytecode magic numbers match exactly, the same tool
# BR2_PACKAGE_PYTHON3_PYC_ONLY already uses for system packages (see
# vendor/buildroot-x2000/package/python3/python3.mk). Used below to
# precompile Klipper/Moonraker's own Python source, which - unlike system
# Buildroot packages - was never routed through that mechanism. Degrade to
# source-only (no precompiled .pyc) rather than failing the build if
# missing for any reason, exactly like every other optional step here.
HOST_PYTHON3="$TOOLCHAIN_HOST/bin/python3"
if [ ! -x "$HOST_PYTHON3" ]; then
	echo "WARNING: $HOST_PYTHON3 not found - Klipper/Moonraker will ship without precompiled bytecode" >&2
	HOST_PYTHON3=""
fi

mkdir -p "$WORK"

# The c_helper.so mtime invariant, defined once in the same file the device
# sources at boot rather than reimplemented here - see that file's header for
# why an mtime comparison decides whether this printer boots at all.
. "$SCRIPT_DIR/overlay/etc/nebulaos-chelper-preflight.sh"

### 1. Klipper: klippy/ source + a freshly cross-compiled chelper.so.
###    Phase 1 no-fork migration: vendor/klipper is now official, unmodified
###    Klipper3d/klipper, which ships no c_helper.so at all (*.so is in its
###    own .gitignore) - so this is the only place the artifact comes from,
###    and the mtime enforcement below is what keeps Klippy from trying to
###    rebuild it with a gcc this device does not have.
# Phase 1 no-fork migration, Phase L (2026-08-17): this used to be
# `make clean && make CC=...`. Official Klipper ships NO Makefile in
# klippy/chelper/ - the retired fork had one, inherited from pellcorp/klipper,
# which the analysis mission classified MOVE_TO_FIRMWARE (section 4.3) and
# which nothing actually moved. The first real full build against official
# upstream therefore died here with "make: *** No rule to make target
# 'clean'", after the entire kernel and rootfs had already been built.
#
# The recipe (upstream's own SOURCE_FILES/COMPILE_ARGS read out of
# klippy/chelper/__init__.py, the cross gcc, --strip-unneeded) lives in ONE
# place, lib/build-chelper.sh: the SDK carries the same script and the
# package index CI builds the helpers for Klipper updates with it (G72).
echo "== cross-compiling Klipper's chelper C extension =="
mkdir -p "$WORK/debug-symbols"
sh "$SCRIPT_DIR/lib/build-chelper.sh" "$VENDOR/klipper/klippy/chelper" \
	"$BUILDROOT_DIR/output/host/bin/mipsel-buildroot-linux-gnu-" \
	"$WORK/debug-symbols/c_helper.so.debug" || exit 1

### 1a. klipper_mcu: upstream Klipper's own MACH_LINUX build target, compiled
###    as a native MIPS Linux program (not cross-compiled embedded firmware
###    in the flashing sense - it links and runs like any other userspace
###    binary on the target, just built with the target's own cross
###    toolchain instead of the host's). This is the Phase 1.9A host-MCU
###    restoration: it serves [mcu rpi] over a Unix socket for the physical
###    ADXL345 accelerometer and BL24C16F EEPROM, both wired directly to the
###    SoC rather than to the GD32F303 stepper-driver MCU that
###    S50nebulaos-mcu-guard/creality_flash.py manage - zero interaction
###    with that subsystem.
###
### test/configs/linuxprocess.config is upstream's own reference Kconfig for
### this target; CROSS_PREFIX is the only variable this Makefile needs to
### produce a MIPS binary instead of a host-native one (CC/AS/LD/OBJCOPY all
### derive from it - see vendor/klipper/Makefile). Phase 1.9A's own build-
### blocker investigation (see docs/ and
### _project/missions/phase1.9-host-mcu-accelerometer-plr-analysis.md)
### directly demonstrated that Make's mtime-based staleness tracking cannot
### detect a CROSS_PREFIX/toolchain change across two builds sharing the
### same out/ directory - it silently keeps stale, wrong-architecture
### objects instead of recompiling them. The rm -rf below is not
### defensive-for-its-own-sake; it is the one proven fix for that exact
### failure mode, and cheap enough to always pay for since this out/ is
### local to a single build-work invocation.
echo "== cross-compiling Klipper's host MCU (MACH_LINUX / klipper_mcu) =="
(
	cd "$VENDOR/klipper"
	rm -rf out .config .config.old
	cp test/configs/linuxprocess.config .config
	export PATH="$BUILDROOT_DIR/output/host/bin:$PATH"
	make olddefconfig
	make CROSS_PREFIX=mipsel-buildroot-linux-gnu- || {
		echo "FATAL: cross-compiling klipper_mcu (MACH_LINUX) failed" >&2
		exit 1
	}
	[ -f out/klipper.elf ] || {
		echo "FATAL: out/klipper.elf was not produced" >&2
		exit 1
	}
) || exit 1

# Debug-symbol preservation mirrors c_helper.so/ustreamer/v4l2-ctl above -
# TARGET_FINALIZE's blanket strip pass never reaches this file since it is
# copied into the overlay directly by this script, after that pass runs.
cp "$VENDOR/klipper/out/klipper.elf" "$WORK/debug-symbols/klipper_mcu.debug"
(
	cd "$VENDOR/klipper"
	export PATH="$BUILDROOT_DIR/output/host/bin:$PATH"
	mipsel-buildroot-linux-gnu-strip --strip-unneeded out/klipper.elf
)
mkdir -p "$OVERLAY/usr/bin"
cp "$VENDOR/klipper/out/klipper.elf" "$OVERLAY/usr/bin/klipper_mcu"
chmod 755 "$OVERLAY/usr/bin/klipper_mcu"
# Leave vendor/klipper's top-level tree exactly as it was before this step -
# out/.config are build-local scratch state, not shipped inputs, and the
# klippy/ copy below is taken from the source tree, not this build's out/.
rm -rf "$VENDOR/klipper/out" "$VENDOR/klipper/.config" "$VENDOR/klipper/.config.old"

mkdir -p "$OVERLAY/opt/klipper"
rm -rf "$OVERLAY/opt/klipper/klippy"

# NebulaOS mutable-runtime closure mission (2026-07-27): empty mount-point
# baked into the squashfs so S05nebulaos-activate can bind-mount the real,
# persistent Klipper venv ($NEBULAOS_ROOT/envs/klipper) onto it at boot.
# Required specifically because Moonraker's update_manager hardcodes
# "~/klippy-env/bin/python" as its bootstrap default for the klipper slot
# (klippy_connection.py's own __init__, used synchronously at Moonraker
# startup, before Klippy's real identify handshake has a chance to report
# its actual executable) - with no config override available for this
# slot (confirmed live: path/env/virtualenv aren't in update_manager's own
# OPTION_OVERRIDES), the only way to make update_manager succeed on the
# very first Moonraker start (not just self-heal after a lucky second
# restart once Klippy's real path gets persisted to Moonraker's own db)
# is to make that exact hardcoded default path real. /root is part of the
# read-only squashfs, so this directory must exist here at build time -
# mkdir at runtime would fail (read-only filesystem).
mkdir -p "$OVERLAY/root/klippy-env"
cp -r "$VENDOR/klipper/klippy" "$OVERLAY/opt/klipper/"
find "$OVERLAY/opt/klipper" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
# Production optimization mission, Phase 4 (2026-07-30): this squashfs
# copy is the immutable fallback used if persistent storage/the real bind-
# mounted seed is ever unavailable - precompile it too, not just the seed
# archive below, so that fallback path benefits as well. See the seed
# archive's own Phase 4 comment for why $HOST_PYTHON3 is the right tool.
if [ -n "$HOST_PYTHON3" ]; then
	PYTHONPATH="" "$HOST_PYTHON3" -m compileall -q \
		-s "$OVERLAY/opt/klipper" -p "/opt/klipper" \
		"$OVERLAY/opt/klipper/klippy" \
		|| echo "WARNING: bytecode precompilation failed for the klipper squashfs copy - shipping source-only" >&2
fi
rm -f "$OVERLAY/opt/klipper/klippy/chelper"/*.o "$OVERLAY/opt/klipper/klippy/chelper"/*.a

# Phase 1 no-fork migration: the immutable squashfs copy of Klipper carries
# the extension modules as REAL FILES, not symlinks.
#
# This copy is not a git checkout and never will be - it is the emergency
# fallback nebulaos-update-supervisor.sh's factory_fallback() exposes by
# unmounting the bind mount when both a new version and the previous
# known-good one have failed validation. The pristine-git requirement that
# drives the symlink architecture applies to the two PERSISTENT checkouts,
# where Moonraker looks and where updates happen. It does not apply here,
# and pretending it did would mean shipping an emergency copy that is
# missing every module the shipped printer.cfg references.
#
# Known, deliberate limitation, stated here rather than discovered later:
# extras/nebulaos_compat.py identifies the running Klipper with
# `git -C <checkout> rev-parse HEAD`, which cannot answer for a tree with no
# .git. So in factory-fallback Klippy will refuse to start with that
# module's own precise message rather than run unverified. That is the
# behaviour the compatibility contract asks for ("did not start, and said
# exactly why" over "started, but the probe is subtly wrong"), and
# factory-fallback is already a terminal state that holds an update lock
# until a human clears it - but it IS a change from the pre-Phase-1 fork
# build, where the fallback copy would have started. Flagged for an explicit
# owner decision; see docs/NEBULAOS_KLIPPER_COMPOSITION.md.
EXT_SRC="$VENDOR/nebulaos-klipper-extensions"
if [ -d "$EXT_SRC/extras" ]; then
	echo "== staging NebulaOS Klipper extension modules into the immutable /opt/klipper copy =="
	cp "$EXT_SRC"/extras/*.py "$OVERLAY/opt/klipper/klippy/extras/"
	# nebulaos_compat.py derives its repository root as
	# dirname(dirname(realpath(__file__))). Through a composed symlink that
	# resolves to the extensions repo root; for these flattened real files it
	# resolves to klippy/, so the manifest has to sit there for the immutable
	# copy to be self-describing at all.
	cp "$EXT_SRC/nebulaos-extensions.json" "$OVERLAY/opt/klipper/klippy/"
else
	echo "FATAL: $EXT_SRC/extras not found - 00-fetch-vendor-sources.sh must fetch the extension repository before this stage" >&2
	exit 1
fi

# LAST, after every step that writes into klippy/ above (the cp -r, the
# compileall pass, the .o/.a removal, the extension staging). Ordering is the
# whole point: enforcing this earlier would be enforcing it against a tree
# that later steps go on to modify.
chelper_enforce_mtime "$OVERLAY/opt/klipper" || {
	echo "FATAL: could not establish the c_helper.so mtime invariant for the immutable /opt/klipper copy" >&2
	exit 1
}

# The immutable copy lives on a read-only squashfs, so nothing can write its
# chelper verdict at boot the way S05nebulaos-activate does for the
# persistent checkout. Bake it in here instead: without it,
# extras/nebulaos_compat.py would refuse to start on the fallback path
# purely because the platform had published no verdict, which is a
# different (and much less useful) failure than the one it is meant to
# report.
chelper_write_verdict "$OVERLAY/opt/klipper" || {
	echo "FATAL: the immutable /opt/klipper copy failed its own chelper verdict immediately after enforcement" >&2
	exit 1
}

# G72: the image's library under its source hash - the device seeds its
# c_helper.so cache with it (chelper_cache_seed_image), so a rollback to the
# shipped Klipper never needs the network.
mkdir -p "$OVERLAY/usr/share/nebulaos"
{
	echo "source_hash=$(chelper_source_hash "$OVERLAY/opt/klipper")"
	echo "sha256=$(chelper_sha256 "$OVERLAY/opt/klipper/klippy/chelper/c_helper.so")"
	echo "klipper_commit=$(git -C "$VENDOR/klipper" rev-parse HEAD)"
} > "$OVERLAY/usr/share/nebulaos/chelper"
grep -qE '^source_hash=[0-9a-f]{64}$' "$OVERLAY/usr/share/nebulaos/chelper" && \
grep -qE '^sha256=[0-9a-f]{64}$' "$OVERLAY/usr/share/nebulaos/chelper" || {
	echo "FATAL: could not record the image's c_helper.so source hash" >&2
	exit 1
}

# Stock-parity fix (FIRMWARE.md sec 13): only klippy/ was ever staged here,
# so Moonraker's file_manager always registered "config_examples" ->
# /opt/klipper/config and "docs" -> /opt/klipper/docs (its own unconditional
# behavior, not custom-specific), and both warned "invalid path" every boot
# since neither existed. Stock's real Klipper install (/usr/share/klipper)
# ships the full upstream checkout, config/ and docs/ included, which is
# why stock never showed this warning - not a different Moonraker behavior,
# just real content actually being present. Our own vendor/klipper is a
# full checkout too; it was just never copied. Packaging the exact same
# revision's reference content here, not fabricated placeholder content.
rm -rf "$OVERLAY/opt/klipper/config" "$OVERLAY/opt/klipper/docs"
cp -r "$VENDOR/klipper/config" "$OVERLAY/opt/klipper/"
cp -r "$VENDOR/klipper/docs" "$OVERLAY/opt/klipper/"

# NebulaOS extension modules (z_compensate.py, nozzle_clear.py,
# nebulaos_*.py, the vendored community extras) are NOT copied here, and
# this repository does not hold a copy of them.
#
# They are owned by NebulaOS-KE/NebulaOS-klipper-extensions, fetched at
# KLIPPER_EXTENSIONS_PIN by 00-fetch-vendor-sources.sh, and composed into
# host Klipper's klippy/extras/ as SYMLINKS driven by that repository's own
# nebulaos-extensions.json manifest - see
# scripts/build/overlay/etc/nebulaos-klipper-compose.sh, which resolves the
# manifest, rejects path traversal and hard-fails on a collision with an
# upstream file of the same name. Host Klipper itself stays official
# upstream (Klipper3d/klipper) with zero core patches.
#
# This comment block used to say something different and wrong: that
# vendor/klipper tracked coreflake1/NebulaOS-klipper's `nebulaos` branch and
# that developers should edit this repository's own klippy_extras/ mirror
# and "re-commit into the fork". That fork is retired, KLIPPER_REPO points
# at Klipper3d/klipper, and the mirror has been deleted - it had drifted
# from what actually ships, so following those instructions edited code that
# reached no image. Edit the extensions repository, then advance
# KLIPPER_EXTENSIONS_PIN.

### 2. Moonraker: source + its Python dependency chain
echo "== copying Moonraker source =="
mkdir -p "$OVERLAY/opt/moonraker"
rm -rf "$OVERLAY/opt/moonraker/moonraker"
cp -r "$VENDOR/moonraker/moonraker" "$OVERLAY/opt/moonraker/"
find "$OVERLAY/opt/moonraker" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

# Moonraker is OFFICIAL upstream (Arksine/moonraker @ MOONRAKER_PIN) and
# vendor/moonraker is never touched - 00-fetch-vendor-sources.sh re-fetches it
# fresh every run, so a patch applied there would silently vanish. This patch
# is applied to the OVERLAY COPY only, i.e. to the bytes that actually ship.
#
# STATUS: UNVALIDATED_LEGACY_WORKAROUND / REMOVAL_CANDIDATE.
#
# What this patch does: replaces database.py's sqlite3.connect() call sites
# with SQLite's "nolock=1" URI parameter, which makes SQLite skip its file
# locking protocol entirely. It is NOT an extra layer of protection on top of
# working locks - it is a SUBSTITUTE for them, and the two are mutually
# exclusive by construction.
#
# Why it is a removal candidate. It was written on 2026-07-23 against the
# theory that this kernel's tmpfs had broken POSIX advisory locking (strace
# showed fcntl64(F_SETLK64, PENDING_BYTE) = -1 EACCES). That theory is wrong,
# and the real root cause was found the same day and fixed in the same commit
# (44e48b4): the base x2000_halley5_v30_linux vendor defconfig shipped with
# CONFIG_FILE_LOCKING off. With that option off the kernel compiles out
# fs/locks.c entirely (fs/Makefile: obj-$(CONFIG_FILE_LOCKING) += locks.o), so
# flock() returns ENOSYS and fcntl_setlk64() is an inline stub that returns
# -EACCES unconditionally (include/linux/filelock.h) - which is exactly, and
# only, the failure that was observed. It was never filesystem-specific: tmpfs
# defines no .lock file_operation at all, so it uses the generic
# posix_lock_file() path like everything else. See FIRMWARE.md sec 23.
# nebulaos_halley5_v30_defconfig (NebulaOS-kernel) sets CONFIG_FILE_LOCKING=y and
# 06-verify.sh asserts it on every build, so the mechanism this patch works
# around cannot occur in the shipping kernel configuration.
#
# Why it is still here anyway. The patch and the kernel fix landed in the SAME
# commit, so no build has ever existed with the kernel fix and stock Moonraker.
# The sufficiency of the kernel fix alone is therefore deduced, never observed.
# Deleting a boot-critical compatibility fix on deduction alone is not worth it.
#
# THE EXPERIMENT THAT RETIRES THIS PATCH (needs a build + a real boot, which is
# why it has not been done here): disable this step, build, flash, and confirm
# Moonraker's first database open succeeds with CONFIG_FILE_LOCKING=y. If it
# does, delete the patch, this block, and the allowlist entry in
# tools/workspace-control/scripts/verify-architecture.sh, and restore a plain
# "Moonraker is unmodified" invariant.
#
# Current safety basis, stated honestly. The patch's own comment claims nolock
# is safe because the database is "private to a single Moonraker process on a
# private tmpfs mount". BOTH halves of that are false today: since 2026-07-25
# (S01persistent-datastore) /opt/printer_data is a bind mount of
# /usr/data/nebulaos/printer_data on the ext4 partition /dev/mmcblk0p10, which
# is physically shared with stock firmware and persists across reboots. What
# actually makes nolock tolerable now is that the NebulaOS namespace
# /usr/data/nebulaos is single-writer - only this image's Moonraker opens that
# database. Note the patch also converts the backup and restore connections,
# which operate on USER-SUPPLIED paths; that is the widest part of its blast
# radius and the strongest argument for retiring it.
#
# -N: the overlay copy is a fresh rm -rf + cp -r from vendor/moonraker every
# run, so the file should always be pristine and apply cleanly - but patch's
# own "already applied" detection has triggered here in practice. -N makes it
# skip already-applied hunks instead of erroring.
#
# The exit status is deliberately NOT the gate. GNU patch -N exits 1 when it
# skips an already-applied hunk, and exits 0 when a hunk applies with fuzz, so
# rc is unreliable in both directions - which is why this used to end in
# `|| true`, discarding the status entirely and letting a silently-unpatched
# Moonraker ship. The EFFECT is the gate instead, asserted immediately below.
patch -N -p1 -d "$OVERLAY/opt/moonraker" \
	< "$SCRIPT_DIR/patches/moonraker-sqlite-nolock.patch" || true

# Fail-closed effect assertion. This is the real gate: it does not care how
# patch exited, only whether the shipped bytes are the ones intended. It runs
# HERE rather than only in 06-verify.sh because the bytecode precompilation
# step immediately below bakes this file's content into .pyc, and because a
# failure 4000 lines later is a far worse signal. 06-verify.sh repeats the
# presence check as a second layer.
MOONRAKER_DB_PY=$OVERLAY/opt/moonraker/moonraker/components/database.py
if [ ! -f "$MOONRAKER_DB_PY" ]; then
	echo "FATAL: $MOONRAKER_DB_PY not found - the moonraker overlay copy is missing or upstream moved database.py" >&2
	exit 1
fi
# Expected end state: the helper is defined once, all FOUR original call sites
# now go through it, and the ONLY remaining raw sqlite3.connect( is the single
# nolock URI call inside the helper itself.
#
# Counting is deliberately CODE-ONLY (comment lines stripped first). The patch's
# own explanatory comment contains the literal strings "sqlite3.connect()" and
# "nolock=1", so a naive grep -c sees 2 of each and a gate built on those raw
# counts would hard-fail every single build. Verified against a reconstructed
# pre-patch database.py with the patch actually applied.
db_code() { grep -v '^[[:space:]]*#' "$MOONRAKER_DB_PY" | grep -c "$1" || true; }
db_helper_defs=$(grep -c '^def connect_sqlite_nolock(' "$MOONRAKER_DB_PY" || true)
db_raw_connects=$(db_code 'sqlite3\.connect(')
db_nolock=$(db_code 'nolock=1')
db_helper_refs=$(db_code 'connect_sqlite_nolock(')
db_call_sites=$((db_helper_refs - db_helper_defs))
if [ "$db_helper_defs" != 1 ] || [ "$db_raw_connects" != 1 ] \
   || [ "$db_nolock" != 1 ] || [ "$db_call_sites" != 4 ]; then
	echo "FATAL: moonraker-sqlite-nolock.patch did not take effect on the overlay copy." >&2
	echo "       $MOONRAKER_DB_PY" >&2
	echo "       connect_sqlite_nolock definitions: $db_helper_defs (expected 1)" >&2
	echo "       connect_sqlite_nolock call sites: $db_call_sites (expected 4)" >&2
	echo "       remaining raw sqlite3.connect( calls: $db_raw_connects (expected 1, the one inside the helper)" >&2
	echo "       nolock=1 occurrences: $db_nolock (expected 1)" >&2
	echo "       This is the exact silent divergence the patch step used to allow: two materially" >&2
	echo "       different Moonraker payloads from the same firmware commit and the same pins." >&2
	echo "       If MOONRAKER_PIN was just bumped, re-base the patch against the new database.py" >&2
	echo "       (or run the retirement experiment documented above and delete it)." >&2
	exit 1
fi
echo "OK   moonraker-sqlite-nolock.patch verified applied to the overlay copy ($db_call_sites call sites through the nolock helper, $db_raw_connects raw sqlite3.connect( left)"

# Production optimization mission, Phase 4 (2026-07-30): precompile after
# the patch above, not before, so bytecode reflects the final patched
# content rather than needing that one file recompiled on first import.
# Same immutable-fallback reasoning as the klipper copy above.
if [ -n "$HOST_PYTHON3" ]; then
	PYTHONPATH="" "$HOST_PYTHON3" -m compileall -q \
		-s "$OVERLAY/opt/moonraker" -p "/opt/moonraker" \
		"$OVERLAY/opt/moonraker/moonraker" \
		|| echo "WARNING: bytecode precompilation failed for the moonraker squashfs copy - shipping source-only" >&2
fi

# GUI/service readiness mission (2026-10-09): the NebulaOS OS-settings
# component ([nebulaos], /usr/lib/nebulaos/moonraker/nebulaos.py on the rootfs)
# must also be importable when Moonraker runs from this immutable fallback
# copy. Same symlink S05nebulaos-activate composes into the persistent
# checkout. Created after compileall on purpose: the target only exists on
# the device, and the component is byte-compiled where it lives.
ln -sfn /usr/lib/nebulaos/moonraker/nebulaos.py \
	"$OVERLAY/opt/moonraker/moonraker/components/nebulaos.py"

# Buildroot 2025.02.18 migration (2026-09-27): Moonraker's Python dependency
# chain is no longer assembled here.
#
# What used to happen: `pip3 download` fetched nine distributions from PyPI at
# build time with --no-deps, unpacked the wheels straight into
# $OVERLAY/usr/lib/python3.11/site-packages, then hand-cross-compiled
# streaming-form-data's one C extension and hand-named the result
# _parser.cpython-311-mipsel-linux-gnu.so.
#
# Three things were wrong with that, and all three are fixed by construction
# now rather than by being more careful:
#
#   1. It was an UNCONTROLLED network fetch inside the firmware build. No
#      hashes, no recorded provenance, resolution depending on what PyPI
#      served that day, and --no-deps meaning a transitively-required package
#      could simply be absent. That is not hypothetical here: the comment this
#      block replaces existed because zipp went missing exactly that way and
#      Moonraker died with ModuleNotFoundError on real hardware before it
#      could even open its log.
#   2. The ABI tag was hand-written. `cpython-311-mipsel-linux-gnu` is a
#      string that has to be kept in sync with the interpreter by hand, and a
#      Python minor bump silently produces a .so the interpreter will not load.
#   3. Wheels unpacked directly into the overlay bypassed Buildroot's staging,
#      stripping and license collection entirely.
#
# All ten distributions are now ordinary Buildroot packages, built against the
# target sysroot with the correct ABI and recorded in legal-info:
#
#   from upstream Buildroot 2025.02.18 : python-pyasn1
#   from br2-external/package/         : python-apprise, python-importlib-metadata,
#                                        python-inotify-simple, python-ldap3,
#                                        python-libnacl, python-preprocess-cancellation,
#                                        python-streaming-form-data, python-wheel-target,
#                                        python-zipp
#
# Since added: br2-external python-smart-open. Every streaming-form-data release
# from 1.16.0 on declares smart-open as a runtime dependency (1.19.1:
# smart-open>=7.0.5) and imports it at module load. The migration did not
# package it, and the first Buildroot 2025.02.18 image shipped without it.
#
# streaming-form-data's _parser extension is built by its Buildroot package
# from the pre-generated _parser.c in its sdist, so Buildroot names the .so
# using the target interpreter's real EXT_SUFFIX. Nothing in this pipeline
# spells a CPython ABI tag by hand any more.

### 3. ustreamer (camera pipeline)
#
# OpenKE fix (USB/webcam stock-parity mission, FIRMWARE.md sec 60): this
# used to build via pellcorp's own `pellcorp/k1-camera-build` docker image,
# which bundles Ingenic's stock vendor toolchain
# (/opt/toolchains/mips-gcc720-glibc229, glibc 2.29). That toolchain's
# glibc uses a DIFFERENT MIPS ABI than this project's own Buildroot-built
# target glibc (2.38, confirmed via /lib/libc.so.6's own banner:
# "libc ABIs: MIPS_PLT UNIQUE MIPS_O32_FP64 ABSOLUTE MIPS_XHASH") - the
# resulting ustreamer.bin's own dynamic-linker request
# (`readelf -l` -> "Requesting program interpreter:
# /lib/ld-linux-mipsn8.so.1") never matched this rootfs's real interpreter
# (plain /lib/ld.so.1), so the binary could never actually execute here -
# busybox ash reports this as a confusing "not found" (it's really the
# missing interpreter, not the file itself; confirmed real files/libs were
# all present and correctly staged). This was never caught before because
# no prior session had a real UVC webcam physically attached to test with.
#
# Fix: build the *exact same*, untouched pellcorp/k1-ustreamer source
# (still vendor/k1-ustreamer at its pinned commit, submodules unchanged)
# with this project's own internal Buildroot toolchain instead - the same
# one already used for Klipper's chelper and Moonraker's streaming-form-
# data above, guaranteeing ABI consistency with the rest of the rootfs.
# Mirrors docker.sh's own real, proven build steps (jpeg-9d, libevent,
# libmd, libbsd, then ustreamer itself) with the toolchain swapped.
echo "== cross-compiling ustreamer (this project's own Buildroot toolchain, not pellcorp/k1-camera-build's incompatible one) =="
rm -rf "$VENDOR/k1-ustreamer/build"
(
	set -e
	SRC="$VENDOR/k1-ustreamer"
	# Append, not prepend: Buildroot's own host/bin dir also carries its own
	# internal automake-1.16/autoconf wrappers (built for its own package
	# builds), which are broken when found ahead of the real system
	# automake/autoconf - they hardcode paths only valid inside the
	# Buildroot build tree itself. Appending still finds the uniquely-named
	# mipsel-buildroot-linux-gnu-* cross tools (no name collision with
	# anything already on PATH) without shadowing them.
	export PATH="$PATH:$TOOLCHAIN_HOST/bin"
	export BUILD_PREFIX="$SRC/build/ustreamer-deps"
	export CC=mipsel-buildroot-linux-gnu-gcc
	export AR=mipsel-buildroot-linux-gnu-gcc-ar
	export LD=mipsel-buildroot-linux-gnu-ld
	export STRIP=mipsel-buildroot-linux-gnu-strip
	export CFLAGS="-I$BUILD_PREFIX/include/"
	export LDFLAGS="-L$BUILD_PREFIX/lib/"
	mkdir -p "$SRC/build"

	cd "$SRC/jpeg-9d" && git clean -xdf
	cd "$SRC/ustreamer" && make clean PKG_CONFIG=true

	cd "$SRC/build"
	tar xf ../libevent-2.1.12-stable.tar.gz && cd libevent-2.1.12-stable
	./configure --host=mipsel-buildroot-linux-gnu --prefix="$BUILD_PREFIX" \
		--disable-openssl --disable-samples --disable-libevent-regress
	make && make install

	cd "$SRC/build"
	tar xf ../libmd-1.1.0.tar.xz && cd libmd-1.1.0
	./configure --host=mipsel-buildroot-linux-gnu --prefix="$BUILD_PREFIX"
	make && make install

	cd "$SRC/build"
	tar xf ../libbsd-0.11.7.tar.xz && cd libbsd-0.11.7
	./configure --host=mipsel-buildroot-linux-gnu --prefix="$BUILD_PREFIX"
	make && make install

	cd "$SRC/jpeg-9d"
	./configure --host=mipsel-buildroot-linux-gnu --build=x86_64-pc-linux-gnu --prefix="$BUILD_PREFIX"
	make && make install

	# CAM-05: build from a patched copy of the pinned ustreamer tree, never
	# the vendor checkout itself (06-verify's pin/drift check stays clean).
	# The copy is the submodule's exact committed content; the patch must
	# apply with zero fuzz or the build stops.
	USRC="$SRC/build/ustreamer-src"
	CAM05_PATCH="$SCRIPT_DIR/patches/ustreamer-cam05-paused-blank-cache.patch"
	rm -rf "$USRC" && mkdir -p "$USRC"
	git -C "$SRC/ustreamer" archive --format=tar HEAD | tar -x -C "$USRC"
	if ! patch -p1 --fuzz=0 --dry-run -d "$USRC" < "$CAM05_PATCH" > /dev/null; then
		echo "FATAL: CAM-05 ustreamer patch does not apply cleanly to the pinned source - refusing to build an unpatched or misapplied ustreamer" >&2
		exit 1
	fi
	patch -p1 --fuzz=0 -s -d "$USRC" < "$CAM05_PATCH"
	grep -q 'blank->jpeg_text' "$USRC/src/ustreamer/blank.c" && grep -q 'offline_paused' "$USRC/src/ustreamer/stream.c" || {
		echo "FATAL: CAM-05 patch effect not present in $USRC" >&2
		exit 1
	}
	echo "CAM-05 ustreamer patch applied (sha256 $(sha256sum "$CAM05_PATCH" | cut -d' ' -f1))"

	cd "$USRC"
	export CFLAGS="$CFLAGS -Os -march=mips32r2 -ffunction-sections -fdata-sections"
	export LDFLAGS="$LDFLAGS -Wl,--gc-sections -s"
	make PKG_CONFIG=true WITH_PTHREAD_NP=0 WITH_SETPROCTITLE=0
	mipsel-buildroot-linux-gnu-strip --strip-unneeded src/ustreamer.bin
)
mkdir -p "$OVERLAY/usr/bin" "$OVERLAY/usr/lib"
cp "$VENDOR/k1-ustreamer/build/ustreamer-src/src/ustreamer.bin" "$OVERLAY/usr/bin/ustreamer"
chmod 755 "$OVERLAY/usr/bin/ustreamer"
cp "$VENDOR"/k1-ustreamer/build/ustreamer-deps/lib/*.so* "$OVERLAY/usr/lib/"
# re-create the SONAME symlinks the binary actually needs - verified fresh
# against this rebuilt binary via `readelf -d ustreamer | grep NEEDED`,
# not assumed from the old pellcorp-toolchain build.
( cd "$OVERLAY/usr/lib" && \
  ln -sf libjpeg.so.9.4.0 libjpeg.so.9 && \
  ln -sf libevent-2.1.so.7.0.1 libevent-2.1.so.7 && \
  ln -sf libevent_core-2.1.so.7.0.1 libevent_core-2.1.so.7 && \
  ln -sf libevent_extra-2.1.so.7.0.1 libevent_extra-2.1.so.7 && \
  ln -sf libevent_pthreads-2.1.so.7.0.1 libevent_pthreads-2.1.so.7 && \
  ln -sf libmd.so.0.1.0 libmd.so.0 && \
  ln -sf libbsd.so.0.11.7 libbsd.so.0 )

### 4. v4l2-ctl (USB/webcam stock-parity mission, FIRMWARE.md sec 60)
#
# The camera-macro warning found in an earlier (Mainsail-warnings) mission
# ("v4l2-ctl: command not found") was a genuinely unresolved gap: this
# project's vendored Buildroot tree (a trimmed BSP subset) has no
# package/v4l-utils at all. S50webcam's own dynamic UVC-node discovery (see
# its own header comment) also depends on a real v4l2-ctl being present, not
# just the camera macro. Built from the real upstream source pinned in
# 00-fetch-vendor-sources.sh (v4l-utils-1.20.0, the last autotools release
# before the 1.22 meson migration - this build container has no python3/
# meson/ninja). Only utils/v4l2-ctl is built, not the whole suite; static
# libv4l2 is skipped entirely (--disable-v4l2-ctl-libv4l means v4l2-ctl uses
# raw ioctls directly, so it doesn't need libv4l2's own broken .la ordering
# fixed) - same minimal-footprint approach as ustreamer above, same
# toolchain, same reasoning for appending (not prepending) buildroot-host/
# bin to PATH.
echo "== cross-compiling v4l2-ctl (this project's own Buildroot toolchain) =="
(
	set -e
	cd "$VENDOR/v4l-utils"
	export PATH="$PATH:$TOOLCHAIN_HOST/bin"
	export CC=mipsel-buildroot-linux-gnu-gcc
	export AR=mipsel-buildroot-linux-gnu-gcc-ar
	export LD=mipsel-buildroot-linux-gnu-ld
	export STRIP=mipsel-buildroot-linux-gnu-strip

	# Phase 11 (2026-08-15): plain `autoreconf -fiv` alone is not enough on
	# this image - v4l-utils uses two non-default-named gettext catalogs
	# (SUBDIRS = v4l-utils-po libdvbv5-po, not the default "po"), and this
	# image's gettext package (Ubuntu 22.04, 0.21-4ubuntu4) does not ship
	# /usr/bin/autopoint at all (only gettextize) - confirmed via `dpkg -L
	# gettext`. autoreconf's own internal "running: autopoint --force" step
	# is then a silent no-op (no autopoint binary to run, no error printed
	# either), so v4l-utils-po/Makefile.in.in never gets generated and
	# configure fails outright ("cannot find input file"). v4l-utils ships
	# its own bootstrap.sh precisely for this - it touches placeholder
	# Makefile.in.in files, runs autoreconf, then explicitly runs
	# `gettextize --po-dir=v4l-utils-po` / `--po-dir=libdvbv5-po` (gettextize
	# IS present here). Running upstream's own bootstrap rather than
	# hand-reimplementing its gettextize/sed steps here.
	bash bootstrap.sh
	./configure --host=mipsel-buildroot-linux-gnu \
		--disable-libdvbv5 --disable-qv4l2 --disable-qvidcap \
		--disable-gconv --disable-bpf --disable-v4l2-ctl-libv4l \
		--disable-shared --enable-static --without-jpeg

	make -C lib/libv4lconvert
	make -C utils/v4l2-ctl
	mipsel-buildroot-linux-gnu-strip --strip-unneeded utils/v4l2-ctl/v4l2-ctl
)
cp "$VENDOR/v4l-utils/utils/v4l2-ctl/v4l2-ctl" "$OVERLAY/usr/bin/v4l2-ctl"
chmod 755 "$OVERLAY/usr/bin/v4l2-ctl"

### 5. Mainsail static build (already unpacked by 00-fetch-vendor-sources.sh)
echo "== copying Mainsail static build =="
mkdir -p "$OVERLAY/usr/share/mainsail"
cp -r "$VENDOR"/mainsail-dist/dist/* "$OVERLAY/usr/share/mainsail/"

### 6. GuppyScreen (project-specific frontend; consumes the z_compensate
# structured status contract - see docs/z_compensate_status_api.md)
#
# 2026-08-07 baseline-repair mission: this used to be built by hand in a
# separate checkout (nebulaos-guppyscreen/, outside this repo) and its two
# binaries `cp`'d in manually - done twice across the earlier baseline-
# repair/canonicalization mission, with no record of which source commit
# produced the binary actually running on the printer (see
# manifests/dependencies.conf's own GUPPYSCREEN_PIN comment for that
# history, and docs/NEBULAOS_QUALIFIED_BASELINE_VARIANT_AUDIT.md). Fetched
# and pinned by 00-fetch-vendor-sources.sh; built here with the exact
# toolchain image and script this fork's own docs use
# (wiki/Building-from-Source.md's "4b. Cross-compile for the Ender-3 V3 KE
# (MIPS)" section, scripts/build-mips.sh) rather than reinventing the build
# steps - GUPPY_SMALL_SCREEN=1 is already hardcoded inside that script, not
# passed in from here.
NEBULASCREEN_SRC="$VENDOR/nebulaos-nebulascreen"
if [ ! -d "$NEBULASCREEN_SRC" ]; then
	echo "FATAL: $NEBULASCREEN_SRC not found - run 00-fetch-vendor-sources.sh first" >&2
	exit 1
fi
echo "== cross-compiling NebulaScreen (Bootlin mips32el-musl toolchain, baked into this image - see build-env/versions.env) =="

# The embedded build date is the pinned commit's date, never the wall clock:
# SOURCE_DATE_EPOCH comes from the pin, and the build refuses a checkout that
# is not exactly the pin.
if [ -z "${NEBULASCREEN_PIN:-}" ]; then
	echo "FATAL: NEBULASCREEN_PIN is unset or empty - refusing to anchor the NebulaScreen build date to an unpinned checkout" >&2
	exit 1
fi
NS_HEAD=$(git -C "$NEBULASCREEN_SRC" rev-parse HEAD 2>/dev/null || echo "")
if [ "$NS_HEAD" != "$NEBULASCREEN_PIN" ]; then
	echo "FATAL: NebulaScreen checkout is at $NS_HEAD but the manifest pins $NEBULASCREEN_PIN - refusing to build a binary that is not a function of the pin" >&2
	exit 1
fi
NS_EPOCH=$(git -C "$NEBULASCREEN_SRC" show -s --format=%ct "$NEBULASCREEN_PIN" 2>/dev/null || echo "")
case "$NS_EPOCH" in
	''|*[!0-9]*)
		echo "FATAL: cannot derive SOURCE_DATE_EPOCH from the pinned NebulaScreen commit ($NEBULASCREEN_PIN)" >&2
		exit 1 ;;
esac
echo "== NebulaScreen SOURCE_DATE_EPOCH=$NS_EPOCH =="

# G82 (Run 15): ONE build recipe for the image and for stand-alone releases -
# the screen repo's own scripts/build-release.sh (host libhv/spdlog, the MIPS
# build, strip, the commit-date check, then the release zip and its check).
# The toolchain is put on PATH only for this subshell - see build-env/
# Dockerfile's comment on GUPPYSCREEN_TOOLCHAIN_BIN (its bundled autotools
# would shadow the system ones v4l2-ctl needs if put on PATH globally).
(
	set -e
	cd "$NEBULASCREEN_SRC"
	export SOURCE_DATE_EPOCH="$NS_EPOCH"
	export NEBULASCREEN_THEME="$NEBULASCREEN_THEME"
	export CROSS_COMPILE=mipsel-linux-
	if [ -n "${GUPPYSCREEN_TOOLCHAIN_BIN:-}" ]; then
		export PATH="$GUPPYSCREEN_TOOLCHAIN_BIN:$PATH"
	fi
	bash scripts/build-release.sh "$NEBULASCREEN_VERSION"
)

NS_BIN="$NEBULASCREEN_SRC/build/bin/nebulascreen"
NS_BEEP="$NEBULASCREEN_SRC/build/bin/nebulabeep"
NS_ZIP="$NEBULASCREEN_SRC/dist/nebulascreen-$NEBULASCREEN_VERSION.zip"
for bin in "$NS_BIN" "$NS_BEEP"; do
	[ -s "$bin" ] || { echo "FATAL: $bin missing or empty after build" >&2; exit 1; }
	file "$bin" | grep -q "MIPS" || { echo "FATAL: $bin is not a MIPS binary (got: $(file "$bin"))" >&2; exit 1; }
	file "$bin" | grep -q "statically linked" || {
		echo "FATAL: $bin is not statically linked - this rootfs has no dynamic linker entry for it" >&2
		exit 1
	}
done
[ -s "$NS_ZIP" ] || { echo "FATAL: release zip $NS_ZIP missing" >&2; exit 1; }
echo "== NebulaScreen build verified: $(file "$NS_BIN") =="

mkdir -p "$OVERLAY/opt/nebulascreen" "$REPO_ROOT/artifacts/nebulascreen-mips" \
	"$OVERLAY/usr/share/nebulaos/nebulascreen"
cp "$NS_BIN" "$OVERLAY/opt/nebulascreen/nebulascreen"
cp "$NS_BEEP" "$OVERLAY/opt/nebulascreen/nebulabeep"
cp "$NS_BIN" "$REPO_ROOT/artifacts/nebulascreen-mips/nebulascreen"
cp "$NS_BEEP" "$REPO_ROOT/artifacts/nebulascreen-mips/nebulabeep"
chmod 755 "$OVERLAY/opt/nebulascreen/nebulascreen" "$OVERLAY/opt/nebulascreen/nebulabeep"
# G82: the image's own release record - the seed "the image wins" resets a
# downloaded release to (S58nebulascreen, /etc/nebulascreen-lib.sh).
python3 -c 'import sys, zipfile; sys.stdout.buffer.write(zipfile.ZipFile(sys.argv[1]).read("release_info.json"))' \
	"$NS_ZIP" > "$OVERLAY/usr/share/nebulaos/nebulascreen/release_info.json"
chmod 644 "$OVERLAY/usr/share/nebulaos/nebulascreen/release_info.json"
echo "== NebulaScreen release record: $(tr -d '\n' < "$OVERLAY/usr/share/nebulaos/nebulascreen/release_info.json") =="

### 7. NebulaOS mutable-runtime mission, Phase 4 (revised - real-history
# repair mission, see docs/NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md
# and the auto-updates-camera-complete mission): immutable offline factory
# seeds for Klipper and Moonraker, baked into the read-only squashfs so
# first-boot namespace seeding (S04nebulaos-factory-seed) never depends on
# GitHub, PyPI, or DNS being reachable. Mainsail needs no seed archive - it
# is already a plain static release tree, not a git repo, so the existing
# /usr/share/mainsail copy above IS its own offline seed; first-boot
# seeding just cp -a's it.
#
# PRIOR APPROACH (removed): each vendor checkout was flattened into a
# single synthetic orphan commit ("NebulaOS factory seed snapshot of
# <branch> @ <true_commit>") before bundling, because a plain
# `git bundle create` of vendor/klipper's shallow clone (1-2 commits deep,
# 00-fetch-vendor-sources.sh's clone_pinned) produces a bundle that
# `git bundle verify` reports as fine but a real `git clone` of rejects
# with "Failed to traverse parents of commit ..." / "remote did not send all
# necessary objects" (confirmed again against git 2.55.0 - a genuine,
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
# vendor/klipper's real "nebulaos" branch commit
# (b3d5ab2b9484f1558586c3a2ea43d46ff9a473a7) is confirmed genuinely
# present on GitHub (`git ls-remote nebulaos`) and was additionally pushed
# as a real "master" branch on the same coreflake1/NebulaOS-klipper fork
# (see the mission's Phase C) - so after this seed's origin fetch,
# origin/master is a real ref whose tip HEAD is trivially an ancestor of
# (currently: identical to). "nebulaos" remains a real branch too, kept as
# the development/source branch this project keeps building from.
# vendor/moonraker is already a full (non-shallow) clone of the official
# Arksine/moonraker repo with HEAD == origin/master, so it needs no branch
# surgery at all - only the same archive-instead-of-bundle treatment.
#
# make_seed_archive() itself lives in scripts/build/lib/make-seed-archive.sh,
# shared verbatim with tests/factory-seed-git-tests.sh so the tests exercise
# this exact function rather than a parallel reimplementation of its rules.
. "$SCRIPT_DIR/lib/make-seed-archive.sh"

echo "== creating offline factory-seed archives (Klipper, extensions, Moonraker) =="
# Real bug found live: $OVERLAY/opt/nebulaos-seeds/ is created directly by
# this script, not by 02-configure-buildroot.sh's tracked-template resync
# (which only mirrors scripts/build/overlay/) - so it is never cleaned
# between runs. A stale, now-uncompressed-format klipper.tar/moonraker.tar
# left over from before the .tar.gz switch sat alongside the new files and
# would have doubled the seed footprint in the packaged image. Always
# start from a clean directory here.
rm -rf "$OVERLAY/opt/nebulaos-seeds"
mkdir -p "$OVERLAY/opt/nebulaos-seeds"
# Second, separate real bug found live, one layer deeper: Buildroot's own
# rootfs-overlay copy step (board overlay -> output/target/, and again
# into output/build/buildroot-fs/ext2/target/) is additive-only - it never
# deletes a file that existed in a PREVIOUS run's overlay but is absent
# from the current one. The rm -rf above only cleans the tracked-adjacent
# source; every earlier format this seed ever shipped (klipper.bundle/
# moonraker.bundle from the original synthetic-commit design, then the
# short-lived uncompressed klipper.tar/moonraker.tar) was still sitting in
# BOTH of Buildroot's own output copies, discovered only because the
# packaged rootfs.ext2 (fixed at 400M) failed to build with "Could not
# allocate block" despite the tracked overlay source alone being a
# reasonable ~46MB. Clean every one of this seed's known-historical
# filenames from both real Buildroot output locations here too, not just
# the tracked overlay - this is the actual root cause location, and must
# be revisited again if this seed's filenames ever change in the future.
for stale_dir in "$BUILDROOT_DIR/output/target/opt/nebulaos-seeds" \
                 "$BUILDROOT_DIR/output/build/buildroot-fs/ext2/target/opt/nebulaos-seeds"; do
	# The .bundle/.tar names are retired formats. The .tar.gz names are the
	# CURRENT ones, and leaving those out was a real defect, found by this
	# branch's own build history (Phase 1 no-fork migration, Phase L).
	#
	# Buildroot's target trees persist across runs, and stage 03 builds a
	# rootfs image BEFORE stage 04 regenerates these archives. So a seed left
	# by a previous run is baked into that intermediate image at its OLD
	# size. That is not hypothetical: a 256MB klipper.tar.gz from a run made
	# before Klipper was cloned shallow survived here and overflowed
	# BR2_TARGET_ROOTFS_EXT2_SIZE on the NEXT build, whose own freshly
	# generated seed was only 15MB. The failure pointed at the filesystem
	# size, which was not the problem, and the shrink that should have fixed
	# it appeared not to work.
	#
	# Remove the current names too, so a seed that gets smaller - or is
	# dropped entirely - cannot leave its previous self behind.
	rm -f "$stale_dir/klipper.bundle" "$stale_dir/moonraker.bundle" \
	      "$stale_dir/klipper.tar" "$stale_dir/moonraker.tar" \
	      "$stale_dir/nebulaos-klipper-extensions.tar" \
	      "$stale_dir/klipper.tar.gz" "$stale_dir/moonraker.tar.gz" \
	      "$stale_dir/nebulaos-klipper-extensions.tar.gz" 2>/dev/null || true
done
klipper_origin="https://github.com/Klipper3d/klipper.git"
klipper_seed_commit=$(make_seed_archive "$VENDOR/klipper" master \
	"$klipper_origin" "$OVERLAY/opt/nebulaos-seeds/klipper.tar.gz" "/lib/" \
	"$HOST_PYTHON3" "/opt/klipper")
klipper_is_shallow=$(git -C "$VENDOR/klipper" rev-parse --is-shallow-repository)

# Phase 1 no-fork migration: the third image-owned source component. Seeded
# PRISTINE - the archive is the extension repository exactly as published,
# with no symlinks and nothing from Klipper in it. Composition is a boot-time
# act performed by S05nebulaos-activate against the two independently-seeded
# checkouts, not something baked into either archive: baking it in would put
# NebulaOS-owned pointers inside a tree that has to stay byte-identical to
# what Moonraker fetches from GitHub, and would make the archive's own
# clean-tree check meaningless.
#
# No sparse_exclude and no bytecode precompilation mount_path juggling: this
# repository is about thirty small Python files, so neither the extraction
# time nor the footprint that motivated Klipper's "/lib/" exclusion applies.
extensions_origin="https://github.com/NebulaOS-KE/NebulaOS-klipper-extensions.git"
# Phase 2 final software closure mission, 2026-09-09: was a hardcoded
# "main" literal here - completely separate from, and overriding, the
# clone_pinned() fix in 00-fetch-vendor-sources.sh that correctly attaches
# vendor/nebulaos-klipper-extensions to $KLIPPER_EXTENSIONS_BRANCH
# ("production") during the clone. make_seed_archive()'s own
# `git checkout -B "$active_branch"` (see that function's own comment)
# unconditionally force-renames the LOCAL branch in the archived copy to
# whatever this argument says, regardless of what branch the source
# checkout was already on - so this literal silently undid that fix,
# shipping a seed archive on branch "main" again. Confirmed live: a real
# build with the clone_pinned() fix in place still failed 06-verify's
# check_seed_archive() ("archive is on branch \"main\", expected
# production"). Unlike klipper/moonraker just below (which correctly stay
# hardcoded to "master" - a Moonraker-RESERVED slot per BASE_CONFIG in
# update_manager/common.py, not configurable at all), extensions is "an
# ordinary, non-reserved git_repo section" (klipper-pin.conf's own words) -
# its branch is exactly $KLIPPER_EXTENSIONS_BRANCH, never a second,
# independently-hardcoded literal.
extensions_seed_commit=$(make_seed_archive "$VENDOR/nebulaos-klipper-extensions" "$KLIPPER_EXTENSIONS_BRANCH" \
	"$extensions_origin" "$OVERLAY/opt/nebulaos-seeds/nebulaos-klipper-extensions.tar.gz" "" \
	"$HOST_PYTHON3" "/usr/data/nebulaos/apps/nebulaos-klipper-extensions")
extensions_is_shallow=$(git -C "$VENDOR/nebulaos-klipper-extensions" rev-parse --is-shallow-repository)

moonraker_origin="https://github.com/Arksine/moonraker.git"
moonraker_seed_commit=$(make_seed_archive "$VENDOR/moonraker" master \
	"$moonraker_origin" "$OVERLAY/opt/nebulaos-seeds/moonraker.tar.gz" "" \
	"$HOST_PYTHON3" "/opt/moonraker")
moonraker_is_shallow=$(git -C "$VENDOR/moonraker" rev-parse --is-shallow-repository)
mainsail_version=$(cat "$VENDOR/mainsail-dist/dist/.version" 2>/dev/null || echo "unknown")
# Derived from SOURCE_DATE_EPOCH so the same source yields the same image.
# This is release IDENTITY and stays meaningful - it is the commit date, not a
# fabricated constant - but it must not be the wall clock, which put a fresh
# timestamp into four shipped JSON files on every build.
build_date=$(date -u -d "@${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set by build.sh}" +%Y-%m-%dT%H:%M:%SZ)

# --- Build-integrity assertions (Phase 1.8 candidate-002) ---
# Candidate-001 shipped the wrong extensions because make_seed_archive switched
# to the local branch (448b59c) instead of the pinned commit (7260389). These
# assertions catch that class of bug at build time, before an image is ever
# created. Every seed archive's actual Git HEAD must match the dependency pin
# that 00-fetch-vendor-sources.sh verified — if make_seed_archive silently
# switches to a different commit, the build fails here instead of producing an
# image that deploys the wrong code.
echo "== verifying seed archive integrity against dependency pins =="
_assert_seed_matches_pin() {
	name="$1"; archive="$2"; expected_pin="$3"
	_assert_tmp=$(mktemp -d)
	sh -c "gzip -dc '$archive' | tar -xo -C '$_assert_tmp'" 2>/dev/null
	actual_head=$(git -C "$_assert_tmp" rev-parse HEAD 2>/dev/null)
	rm -rf "$_assert_tmp"
	if [ "$actual_head" != "$expected_pin" ]; then
		echo "FATAL: $name seed archive HEAD ($actual_head) does not match dependency pin ($expected_pin)" >&2
		echo "The archive was built from the wrong commit. This is the exact bug that produced candidate-001's wrong extension seed." >&2
		exit 1
	fi
	echo "  $name: archive HEAD matches pin ($expected_pin)"
}
_assert_seed_matches_pin klipper \
	"$OVERLAY/opt/nebulaos-seeds/klipper.tar.gz" "$KLIPPER_PIN"
_assert_seed_matches_pin nebulaos-klipper-extensions \
	"$OVERLAY/opt/nebulaos-seeds/nebulaos-klipper-extensions.tar.gz" "$KLIPPER_EXTENSIONS_PIN"
_assert_seed_matches_pin moonraker \
	"$OVERLAY/opt/nebulaos-seeds/moonraker.tar.gz" "$MOONRAKER_PIN"
_ext_manifest="$VENDOR/nebulaos-klipper-extensions/nebulaos-extensions.json"
if grep -q '"qualified_commit"' "$_ext_manifest" 2>/dev/null; then
	echo "FATAL: extensions manifest still contains qualified_commit (removed: Klipper and extensions are independently updateable)" >&2
	exit 1
fi
if grep -q '"allow_unqualified"' "$_ext_manifest" 2>/dev/null; then
	echo "FATAL: extensions manifest still contains allow_unqualified (removed: Klipper and extensions are independently updateable)" >&2
	exit 1
fi
echo "  extensions manifest: no global Klipper version gate (correct)"
echo "== seed archive integrity verified =="

# Verify seed_commit output from make_seed_archive matches the pin as well.
# This is the value that goes into seed-manifest.json.
if [ "$klipper_seed_commit" != "$KLIPPER_PIN" ]; then
	echo "FATAL: klipper_seed_commit ($klipper_seed_commit) != KLIPPER_PIN ($KLIPPER_PIN)" >&2
	exit 1
fi
if [ "$extensions_seed_commit" != "$KLIPPER_EXTENSIONS_PIN" ]; then
	echo "FATAL: extensions_seed_commit ($extensions_seed_commit) != KLIPPER_EXTENSIONS_PIN ($KLIPPER_EXTENSIONS_PIN)" >&2
	exit 1
fi
if [ "$moonraker_seed_commit" != "$MOONRAKER_PIN" ]; then
	echo "FATAL: moonraker_seed_commit ($moonraker_seed_commit) != MOONRAKER_PIN ($MOONRAKER_PIN)" >&2
	exit 1
fi

# 2026-08-08 (Clean-Update + Virgin Baseline mission, Phase 3): a derived,
# not manually-maintained, migration identifier - see
# docs/NEBULAOS_PERSISTENT_LIFECYCLE.md for the full design. Deliberately
# a content-derived hash, not a hand-incremented counter: a counter can be
# forgotten to bump (exactly the class of drift this whole mission exists
# to close), while this changes automatically and exactly when any
# component's expected persistent-app version actually changes, and
# compares with plain string equality on-device with no history lookup
# needed. Not a security hash - just a stable, cheap "does the installed
# generation match what THIS image expects" fingerprint.
#
# Phase 1 no-fork migration: the extensions seed commit joins the hash. This
# is exactly why the design is a content-derived hash rather than a
# hand-incremented counter - adding a third component to the identity is a
# one-line change that cannot be forgotten to bump, and a device whose
# extensions pin moved but whose Klipper pin did not still migrates.
migration_version=$(printf '%s' "${klipper_seed_commit}:${extensions_seed_commit}:${moonraker_seed_commit}:${NEBULASCREEN_PIN:-unknown}" | sha256sum | cut -c1-16)
firmware_head=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")

cat > "$OVERLAY/opt/nebulaos-seeds/seed-manifest.json" <<EOF
{
  "schema_version": 2,
  "nebulaos_version": "${NEBULAOS_VERSION:?NEBULAOS_VERSION missing from manifests/dependencies.conf}",
  "build_date": "$build_date",
  "migration_version": "$migration_version",
  "firmware_head": "$firmware_head",
  "nebulascreen_pin": "${NEBULASCREEN_PIN:-unknown}",
  "guppyscreen_pin": "${NEBULASCREEN_PIN:-unknown}",
  "seeds": {
    "klipper": {
      "format": "git_repo_archive_real_history",
      "file": "klipper.tar.gz",
      "repository": "$klipper_origin",
      "branch": "master",
      "seed_commit": "$klipper_seed_commit",
      "is_shallow": $klipper_is_shallow,
      "sha256": "$(sha256sum "$OVERLAY/opt/nebulaos-seeds/klipper.tar.gz" | cut -d' ' -f1)",
      "compatibility_level": 3,
      "note": "OFFICIAL, unmodified Klipper3d/klipper - NebulaOS hosts no Klipper fork. Zero core file patches. Everything this project owns lives in nebulaos-klipper-extensions and is composed in at boot by symlink activation, leaving this checkout content-pristine at runtime."
    },
    "nebulaos-klipper-extensions": {
      "format": "git_repo_archive_real_history",
      "file": "nebulaos-klipper-extensions.tar.gz",
      "repository": "$extensions_origin",
      "branch": "$KLIPPER_EXTENSIONS_BRANCH",
      "seed_commit": "$extensions_seed_commit",
      "is_shallow": $extensions_is_shallow,
      "sha256": "$(sha256sum "$OVERLAY/opt/nebulaos-seeds/nebulaos-klipper-extensions.tar.gz" | cut -d' ' -f1)",
      "compatibility_level": 3,
      "paired_with": "klipper",
      "note": "seeded pristine; composed into the Klipper checkout at boot by S05nebulaos-activate. Validated, updated and rolled back as one pair with klipper - never independently."
    },
    "moonraker": {
      "format": "git_repo_archive_real_history",
      "file": "moonraker.tar.gz",
      "repository": "$moonraker_origin",
      "branch": "master",
      "seed_commit": "$moonraker_seed_commit",
      "is_shallow": $moonraker_is_shallow,
      "sha256": "$(sha256sum "$OVERLAY/opt/nebulaos-seeds/moonraker.tar.gz" | cut -d' ' -f1)",
      "compatibility_level": 2,
      "note": "full, non-shallow real history; HEAD equals official Arksine/moonraker origin/master at build time"
    },
    "mainsail": {
      "format": "directory_copy",
      "source_path": "/usr/share/mainsail",
      "version": "$mainsail_version",
      "compatibility_level": 2
    }
  }
}
EOF
echo "== factory seeds created: $(ls -la "$OVERLAY/opt/nebulaos-seeds/") =="

# Clean-Update + Virgin Baseline mission, Phase 6 (2026-08-08): a single,
# immutable, squashfs-resident record of exactly what this image IS -
# firmware tag/SHA, kernel/GuppyScreen pins - read at runtime by
# nebulaos_version.py, owned by NebulaOS-klipper-extensions (see
# docs/NEBULAOS_PERSISTENT_LIFECYCLE.md
# and docs/NEBULAOS_UPDATE_OWNERSHIP.md) and combined there with the
# LIVE Klipper checkout's own git state plus $SYSTEM/app-generation.json,
# so "what's actually running" is always queryable in one place rather
# than scattered across Moonraker's update_manager, this file, and manual
# SSH commands. firmware_tag intentionally allows an unclean git describe
# (e.g. "...-5-gdc241c8") - that just means this build is N commits past
# the last tag, a normal and honest thing to report, not an error.
#
# Virgin-Baseline Fix + Rebuild mission (2026-08-08): --match 'nebulaos-*'
# is required, not cosmetic - real bug found live in this mission's own
# fresh-build output: a vendor-dependency-archive release tag
# (v4l-utils-vendor-src-3b22ab0, created to carry a downloadable pinned
# source asset, not to mark a NebulaOS release) sits on this same linear
# main-branch history and is chronologically newer than every real
# baseline tag, so a plain `git describe --tags` picked IT as the
# "nearest" tag and reported a firmware_tag that looks like a dependency
# archive version, not a NebulaOS baseline. Every real baseline tag this
# project creates is named nebulaos-*; every asset-carrier tag (this one,
# wifi-firmware-v1.0.0) is not - restricting the match pattern is what
# actually fixes this, not a coincidence of current tag names.
firmware_tag=$(git -C "$REPO_ROOT" describe --tags --match 'nebulaos-*' 2>/dev/null || echo "unknown")
cat > "$OVERLAY/opt/nebulaos-version.json" <<EOF
{
  "version": "${NEBULAOS_VERSION:?NEBULAOS_VERSION missing from manifests/dependencies.conf}",
  "build_date": "$build_date",
  "firmware_tag": "$firmware_tag",
  "firmware_sha": "$firmware_head",
  "kernel_sha": "${KERNEL_PIN:-unknown}",
  "nebulascreen_sha": "${NEBULASCREEN_PIN:-unknown}",
  "guppyscreen_sha": "${NEBULASCREEN_PIN:-unknown}",
  "nebulaos_ui_api": ${NEBULAOS_UI_API:?NEBULAOS_UI_API missing from manifests/dependencies.conf}
}
EOF
echo "== wrote /opt/nebulaos-version.json: $(cat "$OVERLAY/opt/nebulaos-version.json") =="

# Production optimization mission, Phase 11 (2026-07-30): pre-built venv
# seeds, so S04nebulaos-factory-seed can extract a ready-made virtualenv
# on first boot instead of running `python3 -m venv` live on this
# underpowered target (confirmed live: ~59s per venv, ~118s combined,
# the single largest first-boot cost this project has ever measured).
#
# Root cause found live: neither setup_klipper_env() nor
# setup_moonraker_env() passes --without-pip, so every venv creation also
# runs ensurepip - confirmed by inspecting a real, already-created venv on
# the device: lib/python3.11/site-packages/ contains ONLY pip, setuptools,
# and pkg_resources (nothing else - --system-site-packages correctly makes
# every real dependency invisible from that directory, inherited instead
# via the site-packages .pth mechanism), and that alone accounts for the
# entire venv's 25.5MB footprint. ensurepip's own wheel-unpack-and-install
# work is almost certainly the dominant cost of the ~59s, not the venv
# module's own (otherwise tiny) scaffolding.
#
# A venv's own files are not architecture-specific - pyvenv.cfg is plain
# text, activate* scripts are plain shell/text, and bin/python3 is just a
# symlink to an external interpreter, never a copied binary - so the same
# reasoning Phase 4 already used for bytecode precompilation applies here:
# $HOST_PYTHON3 (Buildroot's own host-built python3.11.6 - see below) can
# build the whole skeleton, which then only needs its symlinks/pyvenv.cfg/
# activate scripts repointed from this build's own paths to the real,
# fixed, always-identical target absolute paths (Buildroot always installs
# to the same /usr/bin/python3.11 on this product), not literally
# recreated per-architecture.
if [ -n "$HOST_PYTHON3" ]; then
	# Buildroot 2025.02.18 migration: DERIVED, never hardcoded.
	#
	# These were literals ("3.11.6", "/usr/bin/python3.11"). A Python minor
	# bump then silently produced a venv seed whose bin/python3 pointed at an
	# interpreter that no longer exists, and whose pyvenv.cfg advertised the
	# wrong version - a dangling symlink that S55klipper/S56moonraker quietly
	# fall back from, re-triggering the Moonraker update_manager ConfigError
	# documented in S04nebulaos-factory-seed. Deriving them means the next
	# minor bump needs no edit here at all.
	#
	# $HOST_PYTHON3 is Buildroot's own host interpreter, built from the same
	# python3 package and therefore at the same version as the target's.
	TARGET_PY_VERSION=$("$HOST_PYTHON3" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')
	TARGET_PY_MAJMIN=$("$HOST_PYTHON3" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
	if [ -z "$TARGET_PY_VERSION" ] || [ -z "$TARGET_PY_MAJMIN" ]; then
		echo "FATAL: could not determine the Python version from $HOST_PYTHON3" >&2
		exit 1
	fi
	TARGET_PY_ABS="/usr/bin/python$TARGET_PY_MAJMIN"
	# Fail closed on host/target skew. The assumption above (host and target
	# python are the same version) is true by construction in Buildroot, but
	# it is cheap to verify against what was ACTUALLY staged into the rootfs,
	# and expensive to debug if it is ever false.
	if [ -d "$OVERLAY/usr/lib" ]; then
		staged=$(ls -d "$OVERLAY"/usr/lib/python3.* 2>/dev/null | head -1)
		if [ -n "$staged" ]; then
			staged_majmin=$(basename "$staged" | sed 's/^python//')
			if [ "$staged_majmin" != "$TARGET_PY_MAJMIN" ]; then
				echo "FATAL: host python is $TARGET_PY_MAJMIN but the staged target rootfs has python$staged_majmin." >&2
				echo "       A venv seed built against the wrong interpreter version is a boot-time failure." >&2
				exit 1
			fi
		fi
	fi
	echo "== venv seeds will target python $TARGET_PY_VERSION at $TARGET_PY_ABS =="
	build_venv_seed() {
		envname="$1"; envdir="$2"; seed_out="$3"
		rm -rf "$WORK/venv-seed-$envname"
		if ! "$HOST_PYTHON3" -m venv --system-site-packages --without-pip \
			"$WORK/venv-seed-$envname" >/tmp/venv-seed-$envname.log 2>&1; then
			echo "WARNING: could not build $envname venv seed - S04nebulaos-factory-seed will fall back to on-device venv creation" >&2
			return 1
		fi
		vdir="$WORK/venv-seed-$envname"
		# Real target paths, not this build's own host-side paths.
		cat > "$vdir/pyvenv.cfg" <<PYVENVCFG
home = /usr/bin
include-system-site-packages = true
version = $TARGET_PY_VERSION
executable = $TARGET_PY_ABS
command = $TARGET_PY_ABS -m venv --system-site-packages --without-pip $envdir
PYVENVCFG
		rm -f "$vdir/bin/python" "$vdir/bin/python3" "$vdir/bin/python$TARGET_PY_MAJMIN"
		ln -s "$TARGET_PY_ABS" "$vdir/bin/python$TARGET_PY_MAJMIN"
		ln -s "python$TARGET_PY_MAJMIN" "$vdir/bin/python3"
		ln -s python3 "$vdir/bin/python"
		# The activate* scripts embed the venv's own absolute path -
		# rewrite from this build's throwaway $vdir to the real,
		# fixed target envdir these seeds will actually be extracted
		# into. Unused by this project's own S55klipper/S56moonraker
		# (which invoke bin/python3 directly, never source activate),
		# kept anyway for parity/manual debugging convenience since
		# they cost nothing extra to include.
		for af in activate activate.csh activate.fish; do
			[ -f "$vdir/bin/$af" ] && sed -i "s#$vdir#$envdir#g" "$vdir/bin/$af"
		done
		[ -f "$vdir/pyvenv.cfg" ] || return 1
		# Deterministic tar - see lib/make-seed-archive.sh for the measured cause.
		tar -C "$vdir" --sort=name --mtime="@${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set by build.sh}" --owner=0 --group=0 --numeric-owner -czf "$seed_out" .
	}
	if build_venv_seed klipper /usr/data/nebulaos/envs/klipper "$OVERLAY/opt/nebulaos-seeds/klipper-venv-seed.tar.gz"; then
		echo "== klipper venv seed created: $(ls -la "$OVERLAY/opt/nebulaos-seeds/klipper-venv-seed.tar.gz") =="
	fi
	if build_venv_seed moonraker /usr/data/nebulaos/envs/moonraker "$OVERLAY/opt/nebulaos-seeds/moonraker-venv-seed.tar.gz"; then
		echo "== moonraker venv seed created: $(ls -la "$OVERLAY/opt/nebulaos-seeds/moonraker-venv-seed.tar.gz") =="
	fi
else
	echo "WARNING: HOST_PYTHON3 not available - shipping without venv seeds, S04nebulaos-factory-seed will use its existing on-device venv creation path" >&2
fi

# Real bug found live (auto-updates-camera-complete mission addendum,
# 2026-07-28): S01persistent-datastore bind-mounts $NEBULAOS_ROOT/printer_data
# over /opt/printer_data unconditionally, very early in boot - so by the time
# any later boot stage could try to read /opt/printer_data/config as "the
# immutable default", it is already looking at the (possibly empty)
# persistent copy, not the real immutable content. The one thing that ever
# populated printer.cfg/moonraker.conf into a fresh persistent copy was a
# migration from a legacy /usr/data/openke path, deleted as part of an
# earlier closure mission on the belief no fresh device would ever need it
# again - leaving genuinely no code path that seeds these files at all.
# Reproduced live: a truly wiped /usr/data/nebulaos/printer_data/config
# left Klipper and Moonraker crash-looping forever on FileNotFoundError.
#
# Fixed the same way klipper.tar.gz/moonraker.tar.gz already solve the
# identical shadowing problem: ship a second, dedicated immutable copy
# under /opt/nebulaos-seeds/ (never subject to any bind mount) that
# S02nebulaos-namespace can copy from into the real persistent location
# whenever it is missing. The actual config content itself is not
# authored here - it already exists, already deliberately stripped of
# development-machine calibration data (see printer.cfg's own header),
# at scripts/build/overlay/opt/printer_data/config/ - this just makes a
# second immutable copy of that same tracked content available at a path
# nothing ever mounts over.
echo "== creating printer_data config seed (Ender-3 V3 KE factory defaults) =="
PRINTER_DATA_CONFIG_SRC="$SCRIPT_DIR/overlay/opt/printer_data/config"
PRINTER_DATA_SEED_DEST="$OVERLAY/opt/nebulaos-seeds/printer_data-config"
if [ ! -f "$PRINTER_DATA_CONFIG_SRC/printer.cfg" ] || [ ! -f "$PRINTER_DATA_CONFIG_SRC/moonraker.conf" ]; then
	echo "FATAL: $PRINTER_DATA_CONFIG_SRC is missing printer.cfg or moonraker.conf - refusing to build a factory seed that would ship without them" >&2
	exit 1
fi
# SimpleAF backend integration (2026-07-29, see docs/
# NEBULAOS_SIMPLEAF_BACKEND_INTEGRATION.md): frontend-controls.cfg is no
# longer required to exist or be included - simpleaf/client.cfg + simpleaf/
# start_end.cfg (vendored from pellcorp/creality) now provide the standard
# virtual_sdcard/pause_resume/display_status/PAUSE/RESUME/CANCEL_PRINT
# objects instead. There is deliberately no hardcoded "must include file X"
# check here any more for exactly that reason - the generic closure
# validator below (frontend_controls_resolve_closure/_validate_closure)
# already checks that those SECTIONS exist exactly once in the real
# resolved closure, regardless of which file(s) provide them, so a
# hardcoded per-filename check here would just be a second, narrower, and
# now-wrong copy of the same rule.
# Lightweight sanity checks on the tracked source, not a full Klipper
# config parser - catches the two concrete regressions this mission has
# actually hit: a real device's carried-over SAVE_CONFIG calibration block,
# and a required option left syntactically blank (confirmed live to hard-
# fail Klipper's config parser outright, see printer.cfg's own z_offset
# history).
#
# Phase 2 calibration-framework mission, Task 1 (config-ownership fix):
# printer.cfg's tracked seed now deliberately ships a real, pre-baked
# SAVE_CONFIG autosave block carrying known factory-default values (see
# docs/NEBULAOS_CALIBRATION_CONFIG_OWNERSHIP.md and
# migrate_config_ownership.py's own module docstring) - a blanket "any
# SAVE_CONFIG block at all is forbidden" check (the old form of this
# guard) would reject that legitimate content as a false positive. This
# calls the same tool's --verify-factory-seed mode instead, which still
# refuses a real, non-factory SAVE_CONFIG block (any section/value outside
# the known factory defaults), just no longer refuses the seed's own
# tracked content.
MIGRATE_CONFIG_OWNERSHIP_TOOL="$SCRIPT_DIR/overlay/opt/nebulaos/tools/migrate_config_ownership.py"
if ! python3 "$MIGRATE_CONFIG_OWNERSHIP_TOOL" --verify-factory-seed "$PRINTER_DATA_CONFIG_SRC/printer.cfg"; then
	exit 1
fi
# A bare "key:" is only actually blank if nothing indented follows it on
# the next line - both printer.cfg/moonraker.conf's own INI-style parsers
# support multi-line list values this way (moonraker.conf's own
# trusted_clients/cors_domains use exactly this, confirmed live: a naive
# single-line grep for "key:$" flagged them as false positives the first
# time this check ran for real).
blank_required_option() {
	# "gcode:" is explicitly excluded - gcode_macro's own gcode option is
	# genuinely allowed to be blank (a variable-only macro with no action),
	# confirmed against vendor/klipper/klippy/extras/gcode_macro.py's
	# load_template(). Every other option name is still caught.
	awk '
		{
			if (pending != "") {
				if ($0 !~ /^[ \t]/) { print pending; exit 1 }
				pending = ""
			}
			if ($0 ~ /^[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$/ && $0 !~ /^gcode:[[:space:]]*$/) { pending = $0 }
		}
		END { if (pending != "") { print pending; exit 1 } }
	' "$1"
}
for f in "$PRINTER_DATA_CONFIG_SRC/printer.cfg" "$PRINTER_DATA_CONFIG_SRC/moonraker.conf"; do
	[ -f "$f" ] || continue
	if ! blank_required_option "$f" >/dev/null; then
		echo "FATAL: $f has an option present but syntactically blank (not a multi-line list value) - refusing to ship a factory default that fails to parse" >&2
		exit 1
	fi
done

# Print-control config closure validation (mainline print-controls mission,
# 2026-07-29 - see docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md). Shared with
# tests/nebulaos-frontend-controls-validation-tests.sh via
# scripts/build/lib/validate-frontend-controls.sh, so the tests exercise
# this exact function rather than a parallel reimplementation.
. "$SCRIPT_DIR/lib/validate-frontend-controls.sh"
PRINTER_DATA_CONFIG_CLOSURE="$WORK/printer-data-config-closure.txt"
if ! frontend_controls_resolve_closure "$PRINTER_DATA_CONFIG_SRC" printer.cfg "$PRINTER_DATA_CONFIG_CLOSURE" "$SCRIPT_DIR/overlay"; then
	echo "FATAL: could not resolve the printer_data config include closure" >&2
	exit 1
fi
if ! frontend_controls_validate_closure "$PRINTER_DATA_CONFIG_CLOSURE" /opt/printer_data/gcodes; then
	echo "FATAL: print-control config closure failed validation - see docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md" >&2
	exit 1
fi
echo "== print-control config closure validated: virtual_sdcard/pause_resume/display_status each defined exactly once, path correct, no duplicate or circular macros =="
for stale_dir in "$BUILDROOT_DIR/output/target/opt/nebulaos-seeds" \
                 "$BUILDROOT_DIR/output/build/buildroot-fs/ext2/target/opt/nebulaos-seeds"; do
	rm -rf "$stale_dir/printer_data-config" 2>/dev/null || true
done
rm -rf "$PRINTER_DATA_SEED_DEST"
mkdir -p "$PRINTER_DATA_SEED_DEST"
cp -a "$PRINTER_DATA_CONFIG_SRC/." "$PRINTER_DATA_SEED_DEST/"
cat > "$PRINTER_DATA_SEED_DEST/../printer-data-config-manifest.json" <<EOF
{
  "schema_version": 1,
  "printer": "Creality Ender-3 V3 KE",
  "build_date": "$build_date",
  "files": {
    "printer.cfg": "$(sha256sum "$PRINTER_DATA_SEED_DEST/printer.cfg" | cut -d' ' -f1)",
    "moonraker.conf": "$(sha256sum "$PRINTER_DATA_SEED_DEST/moonraker.conf" | cut -d' ' -f1)"
  }
}
EOF
echo "== printer_data config seed created: $(ls -la "$PRINTER_DATA_SEED_DEST/") =="

# Phase 2 final software closure mission, 2026-09-09: the config
# materialization architecture (see docs/NEBULAOS_CONFIG_MATERIALIZATION.md)
# needs a way to tell "the immutable /etc/nebulaos/klipper/ tree this image
# ships" apart from "the tree an older or newer image shipped", without
# using the firmware's own git SHA (which changes on every commit, even
# ones that never touch these 10 files - that would force a rematerialize/
# backup cycle on every single build regardless of whether the config tree
# itself actually changed). A dedicated manifest, generated here from the
# exact files this build is about to ship, keyed by their own content:
# same 10 files' content -> same generation hash, byte-for-byte, across
# any number of otherwise-unrelated firmware commits; any real change to
# any one of them -> a new hash. Per-file hashes let a live device verify
# (or later diagnose - see nebulaos-recover config) individual files
# against this exact manifest, not just an opaque aggregate.
NEBULAOS_KLIPPER_CFG_DIR_BUILD="$OVERLAY/etc/nebulaos/klipper"
if [ -d "$NEBULAOS_KLIPPER_CFG_DIR_BUILD" ]; then
	_cfg_manifest_files_json=""
	_cfg_manifest_hash_input=""
	for _cfg_f in $(cd "$NEBULAOS_KLIPPER_CFG_DIR_BUILD" && ls -1 *.cfg | sort); do
		_cfg_sha=$(sha256sum "$NEBULAOS_KLIPPER_CFG_DIR_BUILD/$_cfg_f" | cut -d' ' -f1)
		_cfg_manifest_files_json="$_cfg_manifest_files_json    \"$_cfg_f\": \"$_cfg_sha\",
"
		_cfg_manifest_hash_input="$_cfg_manifest_hash_input$_cfg_f:$_cfg_sha
"
	done
	_cfg_manifest_files_json=$(printf '%s' "$_cfg_manifest_files_json" | sed '$ s/,$//')
	_cfg_generation=$(printf '%s' "$_cfg_manifest_hash_input" | sha256sum | cut -d' ' -f1)
	cat > "$NEBULAOS_KLIPPER_CFG_DIR_BUILD/.manifest.json" <<EOF
{
  "schema_version": 1,
  "generation": "$_cfg_generation",
  "build_date": "$build_date",
  "files": {
$_cfg_manifest_files_json
  }
}
EOF
	echo "== /etc/nebulaos/klipper/.manifest.json generation=$_cfg_generation =="
else
	echo "FATAL: $NEBULAOS_KLIPPER_CFG_DIR_BUILD missing - cannot generate the config materialization manifest" >&2
	exit 1
fi

echo "== app-stack overlay assembled at $OVERLAY =="
