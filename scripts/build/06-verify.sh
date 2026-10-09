#!/bin/sh
# Confirm every piece actually landed in the built rootfs.ext2, the same way
# this whole project verified things without real hardware: debugfs presence
# checks plus readelf/file architecture checks on anything compiled. This is
# NOT a substitute for the real boot test (needs the user present) - it only
# proves the image contains what it's supposed to.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
IMAGES="$REPO_ROOT/vendor/buildroot-x2000/output/images"
KERNEL_CONFIG="$REPO_ROOT/vendor/buildroot-x2000/output/build/linux-custom/.config"
MANIFEST_FILE="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/build-manifest.txt"

# 2026-08-07: source the same manifests/dependencies.conf every other pin-
# aware script reads, instead of a second, independently-hardcoded copy of
# each SHA - real bug found by this mission's own clean-room test: the
# Klipper pin here still said d839d037... after 00-fetch-vendor-sources.sh
# had long since moved to 0e5785dac..., so this script silently reported a
# false "pin drift" MISS against a checkout that was actually correct.
DEPS_MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
[ -f "$DEPS_MANIFEST" ] || { echo "FATAL: $DEPS_MANIFEST not found" >&2; exit 1; }
. "$DEPS_MANIFEST"

if [ ! -f "$IMAGES/rootfs.ext2" ]; then
	echo "rootfs.ext2 not found - run 05-final-build.sh first" >&2
	exit 1
fi

# Vendor pin drift check (SimpleAF backend integration, 2026-07-29, see docs/
# NEBULAOS_SIMPLEAF_BACKEND_INTEGRATION.md) - 00-fetch-vendor-sources.sh only
# clones+checks-out a pin the FIRST time a vendor/ dir is absent; nothing
# previously re-verified that an already-present checkout's HEAD still
# matches its recorded pin (e.g. after a stray `git pull` run by hand inside
# vendor/, or a stale checkout left over from before a pin was bumped). Keep
# these SHAs in sync with 00-fetch-vendor-sources.sh's own clone_pinned calls
# - duplicated here deliberately (same convention as blank_required_option's
# two copies below) rather than sourcing the fetch script, which also
# performs real network clones and shouldn't be pulled into a read-only
# verify pass.
echo "=== vendor source pin drift ==="
# Extended 2026-07-31 (NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md's vendor-pin
# audit): now also verifies the origin remote URL (catches a checkout quietly
# repointed at a fork/mirror) and working-tree cleanliness against an
# explicit per-repo allowlist of paths this project's own build scripts
# deterministically modify (e.g. buildroot-x2000's vendor-patches copy-in) -
# an allowed path showing as different is NOT silently ignored as "fine
# either way", it's explicitly named so a reader knows exactly why it's
# expected, same convention as the rest of this project's "corrected in
# place with a note" pattern.
check_vendor_pin() {
	vp_name="$1"
	vp_expected="$2"
	vp_expected_url="$3"
	vp_bulk_dirty_expected="$4"
	shift 4
	vp_dir="$REPO_ROOT/vendor/$vp_name"
	if [ ! -d "$vp_dir/.git" ]; then
		echo "MISS vendor/$vp_name is not a git checkout - cannot verify its pin"
		return
	fi
	vp_actual=$(git -C "$vp_dir" rev-parse HEAD 2>/dev/null || echo "unknown")
	if [ "$vp_actual" = "$vp_expected" ]; then
		echo "OK   vendor/$vp_name HEAD matches its pinned commit ($vp_expected)"
	else
		echo "MISS vendor/$vp_name HEAD is $vp_actual, expected pinned commit $vp_expected"
	fi
	if [ -n "$vp_expected_url" ]; then
		vp_remotes=$(git -C "$vp_dir" remote -v 2>/dev/null)
		if printf '%s\n' "$vp_remotes" | grep -qF "$vp_expected_url"; then
			echo "OK   vendor/$vp_name has a remote matching $vp_expected_url"
		else
			echo "MISS vendor/$vp_name has no remote matching expected URL $vp_expected_url"
		fi
	fi
	vp_dirty=$(git -C "$vp_dir" status --porcelain -uall 2>/dev/null)
	for vp_allow in "$@"; do
		vp_dirty=$(printf '%s\n' "$vp_dirty" | grep -v -F "$vp_allow" || true)
	done
	vp_dirty=$(printf '%s\n' "$vp_dirty" | sed '/^$/d')
	if [ -z "$vp_dirty" ]; then
		echo "OK   vendor/$vp_name working tree has no unexplained changes"
	elif [ "$vp_bulk_dirty_expected" = "1" ]; then
		echo "OK   vendor/$vp_name working tree is dirty, as expected once apply-qualified-baseline.sh has run - see assert-baseline-config.sh for the real content-level check of this checkout's variant patches (too many individual paths across 8 variants to allowlist here without this list silently going stale again):"
		printf '%s\n' "$vp_dirty" | sed 's/^/     /'
	else
		echo "MISS vendor/$vp_name has unexplained working-tree changes:"
		printf '%s\n' "$vp_dirty" | sed 's/^/     /'
	fi
}
# klipper: pin bumped 2026-07-31 to d839d0375 in 00-fetch-vendor-sources.sh
# (previously stuck one real, already-shipped commit behind - see that
# script's own comment). `klippy/chelper/c_helper.so` is expected to differ
# (the correctly cross-compiled MIPS binary vs. whatever's tracked in git -
# same allowlisted-path convention as make-seed-archive.sh's own dirty-tree
# guard fix).
check_vendor_pin klipper "$KLIPPER_PIN" \
	"$KLIPPER_REPO" 0 \
	klippy/chelper/c_helper.so
check_vendor_pin moonraker "$MOONRAKER_PIN" \
	"$MOONRAKER_REPO" 0
check_vendor_pin pellcorp-creality "$PELLCORP_CREALITY_PIN" \
	"$PELLCORP_CREALITY_REPO" 0
# buildroot-x2000: the .mk change and board/halley5-nebulaos-* files are
# deterministically copied in by 02-configure-buildroot.sh from tracked
# sources in this repo (scripts/build/vendor-patches/, this project's own
# config layer) - expected every time, not accidental drift.
# board/nebulaos-post-build.sh is the same thing: copied in by
# 02-configure-buildroot.sh from the tracked scripts/build/nebulaos-post-build.sh
# Buildroot 2025.02.18 migration (2026-09-27): this allowlist IS the
# acceptance test for "official Buildroot stays pristine", and it is now down
# to a single entry.
#
# It previously permitted nine expected modifications. Seven of them were
# NebulaOS content injected into the upstream tree
# (board/halley5-nebulaos-{fragment,busybox-fragment}.config,
# board/nebulaos-post-build.sh, board/halley5-nebulaos-overlay/,
# board/halley5-nebulaos-wheels/) or outright edits to upstream package files
# (package/python-matplotlib/python-matplotlib.mk overwritten wholesale,
# package/squashfs/squashfs.{mk,hash} sed-patched). All seven are gone: the
# NebulaOS content moved to br2-external/, matplotlib and numpy come from
# upstream packages, and the squashfs fix is already upstream in 2025.02.18.
#
# local.mk is the only survivor, and it is structural rather than incidental:
# it carries LINUX_OVERRIDE_SRCDIR, which Buildroot only reads from
# $(TOPDIR)/local.mk, so it genuinely has nowhere else to live.
#
# Anything else appearing here is an UNMET migration goal, not something to
# add to this list. NebulaOS changes to Buildroot packages go through
# br2-external/patches/<package>/<version>/ (BR2_GLOBAL_PATCH_DIR, NG1), never
# through edits of this tree.
check_vendor_pin buildroot-x2000 "$BUILDROOT_PIN" \
	"$BUILDROOT_REPO" 0 \
	local.mk
check_vendor_pin k1-ustreamer "$K1_USTREAMER_PIN" \
	"$K1_USTREAMER_REPO" 0
# k1-ustreamer's own real git submodules (jpeg-9d, ustreamer) - pinned via
# the parent commit's own recorded submodule SHAs, so a plain `git status`
# on the parent won't show submodule drift; `submodule status` is the real
# check (a leading '+' means checked out at a different SHA than recorded,
# '-' means not initialized).
if [ -d "$REPO_ROOT/vendor/k1-ustreamer/.git" ]; then
	ku_submodules=$(git -C "$REPO_ROOT/vendor/k1-ustreamer" submodule status 2>/dev/null)
	if printf '%s\n' "$ku_submodules" | grep -qE '^[+-]'; then
		echo "MISS vendor/k1-ustreamer submodules are not at their pinned commits:"
		printf '%s\n' "$ku_submodules" | sed 's/^/     /'
	else
		echo "OK   vendor/k1-ustreamer submodules (jpeg-9d, ustreamer) match their pinned commits"
	fi
fi
# v4l-utils: pinned to the exact commit v4l-utils-1.20.0 resolves to (not the
# tag name) as of the 2026-07-31 pin audit; messages.mo is a harmless
# untracked compiled gettext artifact.
#
# Phase 1 overnight closure mission (2026-08-30): the remaining five paths
# below were a REAL gap in this allowlist, found live by running a
# genuinely fresh (from-network, not reused) build and seeing them appear
# even there - proving they are not stale/reused-checkout drift but a
# deterministic, always-reproducible side effect of 04-cross-compile-
# app-stack.sh's own v4l2-ctl build step, which deliberately runs
# `autoreconf -fiv` plus a manual autopoint workaround on this exact
# checkout every single build (see that script's own "USB/webcam
# stock-parity mission, FIRMWARE.md sec 60" comment for why: the pinned
# v4l-utils-1.20.0 release uses two non-default-named gettext catalogs,
# and this build image's autoreconf can't regenerate their Makefile.in.in
# files without it). `configure.ac` itself is touched by autoreconf's own
# timestamp/regeneration bookkeeping, not a real content change.
check_vendor_pin v4l-utils "$V4L_UTILS_PIN" \
	"$V4L_UTILS_REPO" 0 \
	messages.mo \
	configure.ac \
	po/Makefile.in.in \
	po/Makevars.template \
	libdvbv5-/po/Makefile.in.in \
	v4l-utils-/po/Makefile.in.in
# x2000_kernel_6.6: same pin source as 00-fetch-vendor-sources.sh's own
# KERNEL_PIN and 01-apply-kernel-patches.sh's independent check - all three
# now read manifests/dependencies.conf directly rather than keeping
# independent hardcoded copies that can (and did - see this file's own
# 2026-08-07 header comment) drift out of sync.
# Remote name is "nebulaos" here, not "origin" - check_vendor_pin's URL check
# greps all remotes, so this is remote-name-agnostic.
#
# bulk_dirty_expected=0: every NebulaOS kernel change is a commit on
# NebulaOS-kernel and the production config is the kernel-owned
# nebulaos_halley5_v30_defconfig, so the build modifies nothing in this
# checkout. Any working-tree change is unexplained and a MISS. (SOT-30)
check_vendor_pin x2000_kernel_6.6 "$KERNEL_PIN" \
	"$KERNEL_REPO" 0
# GuppyScreen: added 2026-08-07 - previously not pin-checked here at all
# (it was still a manually-copied binary with no vendor checkout to check
# when this script was last touched). `submodule status` confirms all four
# submodules stay pinned at their exact recorded commits (no +/- marker) -
# the three allowlisted below show as modified in the PARENT's own status
# only because of real, expected in-place content changes: 00-fetch-
# vendor-sources.sh's two submodule patches (spdlog, lvgl), and libhv's own
# working-tree state after scripts/build-mips.sh's native/MIPS library
# swap-and-restore (04-cross-compile-app-stack.sh). Verified empirically
# against a real build, not assumed.
check_vendor_pin nebulaos-guppyscreen "$GUPPYSCREEN_PIN" \
	"$GUPPYSCREEN_REPO" 0 \
	libhv \
	lvgl \
	spdlog

echo "=== release artifact provenance (docs/NEBULAOS_RELEASE_ARTIFACT_PROVENANCE.md) ==="
check_artifact_sha256() {
	ca_path="$REPO_ROOT/$1"
	ca_expected="$2"
	if [ ! -f "$ca_path" ]; then
		echo "MISS $1 does not exist - cannot verify its hash"
		return
	fi
	ca_actual=$(sha256sum "$ca_path" | awk '{print $1}')
	if [ "$ca_actual" = "$ca_expected" ]; then
		echo "OK   $1 sha256 matches recorded provenance ($ca_expected)"
	else
		echo "MISS $1 sha256 is $ca_actual, expected recorded provenance $ca_expected"
	fi
}
check_artifact_sha256 vendor/mainsail-dist/mainsail.zip \
	df2ba7c301f7bfc8ac9f122741a6ba08356d679ecfa1f62f898d0337802d5de5

# 2026-08-07: GuppyScreen is no longer a fixed prebuilt binary (see
# manifests/dependencies.conf's GUPPYSCREEN_PIN and
# 04-cross-compile-app-stack.sh) - it is rebuilt from pinned source every run,
# so a fixed expected hash here would have to be re-derived on every pin bump.
# Check self-consistency against THIS run's own build-manifest.txt instead
# (already-recorded guppyscreen_sha256/guppybeep_sha256, right next to the
# source pin git_commit_guppyscreen that actually determines correctness) plus
# a real MIPS-ELF sanity check.
#
# CORRECTED 2026-09-24. This comment used to justify the approach by asserting
# that the bytes are "NOT deterministic across builds (the toolchain embeds a
# build timestamp), even from byte-identical source". That was wrong in two
# ways. It was also not the only place it had been written down - successive
# passes each believed they had found the last copy and each was wrong, so no
# count is asserted here. The canonical retraction is docs/REPRODUCIBILITY.md,
# in this repository, so it is reachable from a plain clone; if you find another
# copy, correct it and point it there rather than re-counting.
#   - The cause was specific, not "the toolchain": libhv expands __DATE__ and
#     __TIME__ (libhv/base/htime.c hv_compile_datetime). Stage 04 now pins
#     SOURCE_DATE_EPOCH to the GuppyScreen commit date and verifies the
#     expected date is embedded, so guppyscreen is no longer expected to
#     change with the calendar.
#   - It was never true of guppybeep at all. guppybeep does not link libhv and
#     embeds no date string, and it has reproduced byte-for-byte across builds.
#     A guppybeep hash change is therefore a REAL finding, not a known-benign
#     rebuild artifact - see baseline-difference-gate.sh, which no longer lists
#     it as an expected difference.
# The self-consistency check below is unchanged and is still the right check;
# only the reasoning attached to it was wrong.
check_guppyscreen_binary() {
	gb_path="$REPO_ROOT/$1"
	gb_manifest_key="$2"
	if [ ! -f "$gb_path" ]; then
		echo "MISS $1 does not exist"
		return
	fi
	if ! file "$gb_path" 2>/dev/null | grep -q "MIPS.*statically linked"; then
		echo "MISS $1 is not a statically-linked MIPS ELF binary ($(file "$gb_path" 2>/dev/null))"
		return
	fi
	gb_recorded=$(grep "^${gb_manifest_key}=" "$MANIFEST_FILE" 2>/dev/null | cut -d= -f2)
	gb_actual=$(sha256sum "$gb_path" | awk '{print $1}')
	if [ -z "$gb_recorded" ]; then
		echo "MISS $1 - no $gb_manifest_key recorded in $MANIFEST_FILE (05-final-build.sh should have written one)"
	elif [ "$gb_actual" = "$gb_recorded" ]; then
		echo "OK   $1 sha256 matches this build's own manifest record ($gb_actual) - source pinned separately via git_commit_guppyscreen"
	else
		echo "MISS $1 sha256 is $gb_actual, this build's manifest recorded $gb_recorded - manifest is stale or binary was replaced after the build"
	fi
}
check_guppyscreen_binary artifacts/guppyscreen-mips/guppyscreen guppyscreen_sha256
check_guppyscreen_binary artifacts/guppyscreen-mips/guppybeep guppybeep_sha256

check_artifact_sha256 scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.bin \
	82ed67a211877efa47aff4aab83d6d2d1ccf3d5d0f5c396df97f292ade01de9e
check_artifact_sha256 scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.clm_blob \
	1dbe1a396b68786bb189b7c255318ae546fd2e9d15f70ccc8ecbdc52b6cd4c47
check_artifact_sha256 scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.txt \
	78fee458ab69c0a66ea462f6d6769e15b36f73582693f4dbb5a0e8e8be3cfb0a
check_artifact_sha256 scripts/build/overlay/lib/firmware/regulatory.db \
	0a4abd7ae20d07bb70642937ccb2293a72a6504730eea45a698882599f586368
check_artifact_sha256 scripts/build/overlay/lib/firmware/regulatory.db.p7s \
	bcd81aed039ea6b9b6f3726fbf26911a0caf4a5d894210e0fa2effb384d6b326

# ns2009, the display panel, brcmfmac and the RNG are all built statically
# into vmlinux (=y, not =m) - see the retired halley5-nebulaos-fragment.config's (firmware history before SOT-21) own
# comments for why each one was switched. A built-in driver produces no
# separate .ko file under /lib/modules at all, so these are checked against
# the actual built kernel .config instead of debugfs'd out of rootfs.ext2 -
# checking for a .ko file here would silently and permanently report MISS
# for correctly-working built-in support.
echo "=== built-in kernel drivers (not loadable modules) ==="
if [ -f "$KERNEL_CONFIG" ]; then
	check_builtin() {
		sym="$1"
		if grep -q "^${sym}=y$" "$KERNEL_CONFIG"; then
			echo "OK   $sym=y (built-in)"
		else
			echo "MISS $sym"
		fi
	}
	check_builtin CONFIG_TOUCHSCREEN_NS2009
	check_builtin CONFIG_STAGE_OPENKE_GENERAL_480X272
	check_builtin CONFIG_BRCMFMAC
	check_builtin CONFIG_INGENIC_HW_RANDOM
	# NebulaOS Memory Resilience Gate: real bug this catches if regressed -
	# the original OOM/no-swap incident happened precisely because these
	# were silently absent from the kernel; a plain rootfs file check
	# can't see kernel config at all, so this is the only place a clean
	# build can catch this specific regression.
	check_builtin CONFIG_SWAP
	# Kernel configuration profile (SOT-51); gated in assert-baseline-config.sh.
	case "${KERNEL_CONFIG_PROFILE:-}" in
	production)
		grep -qx '# CONFIG_FTRACE is not set' "$KERNEL_CONFIG" && echo "OK   production kernel: CONFIG_FTRACE not set" || echo "MISS production kernel has CONFIG_FTRACE"
		grep -qx 'CONFIG_LOCALVERSION=""' "$KERNEL_CONFIG" && echo "OK   production kernel: empty LOCALVERSION" || echo "MISS production kernel LOCALVERSION is not empty"
		;;
	diagnostic)
		for sym in $(grep '^CONFIG_' "$REPO_ROOT/vendor/x2000_kernel_6.6/kernel/kernel-6.6/arch/mips/configs/nebulaos_halley5_v30_diagnostic.config"); do
			grep -qxF "$sym" "$KERNEL_CONFIG" && echo "OK   diagnostic kernel: $sym" || echo "MISS diagnostic kernel lacks $sym"
		done
		;;
	esac
	check_builtin CONFIG_ZRAM
	check_builtin CONFIG_CRYPTO_LZ4
	# Two competing WiFi drivers were a real, previously-hit bug (FIRMWARE.md
	# sec 24/36) - confirm the vendor's out-of-tree one stays disabled.
	if grep -q "^CONFIG_BCMDHD=y$" "$KERNEL_CONFIG"; then
		echo "MISS CONFIG_BCMDHD is set - conflicts with CONFIG_BRCMFMAC for the same SDIO chip"
	else
		echo "OK   CONFIG_BCMDHD not set (brcmfmac is the only WiFi driver)"
	fi
	# FIRMWARE.md sec 53: CONFIG_BRCMFMAC=y means brcmfmac's own firmware
	# request happens before the real rootfs is mounted - embedding the
	# firmware in the kernel image itself is what actually makes WiFi work,
	# not just having the files present in rootfs.ext2 (checked separately
	# below - both need to be true).
	if grep -q '^CONFIG_EXTRA_FIRMWARE="brcm/brcmfmac43430-sdio\.bin brcm/brcmfmac43430-sdio\.txt' "$KERNEL_CONFIG"; then
		echo "OK   CONFIG_EXTRA_FIRMWARE set (WiFi firmware embedded in the kernel image)"
	else
		echo "MISS CONFIG_EXTRA_FIRMWARE not set as expected - did fetch-cyw43430-wifi-firmware.sh run before 02-configure-buildroot.sh?"
	fi
	# FIRMWARE.md sec 23 (2026-07-23): the base vendor defconfig has this off
	# (a kernel-size trim, not deliberate for this project) - without it,
	# flock()/fcntl locking fail kernel-wide (ENOSYS/EACCES on a brand new,
	# uncontended file, confirmed on real hardware), which broke Moonraker
	# with sqlite3.OperationalError: database is locked on its very first
	# database open. Affects anything using file locks, not just sqlite.
	check_builtin CONFIG_FILE_LOCKING
	# Phase 1.9A/1.9B: ADXL345's bit-banged SPI bus and the physical
	# BL24C16F EEPROM's real production driver (at24/nvmem, NOT
	# [bl24c16f]/i2c-chardev - see accelerometer-eeprom-bus-enable-
	# variant.sh and machine.cfg's own Phase 1.9B history).
	check_builtin CONFIG_SPI_GPIO
	check_builtin CONFIG_EEPROM_AT24
	if grep -q "^CONFIG_I2C_CHARDEV=y$" "$KERNEL_CONFIG"; then
		echo "MISS CONFIG_I2C_CHARDEV is set - Phase 1.9B retired its only consumer ([bl24c16f]/klipper_mcu i2c.c); it should no longer be needed"
	else
		echo "OK   CONFIG_I2C_CHARDEV not set (retired, Phase 1.9B - at24 is a real kernel driver, no /dev/i2c-* chardev needed)"
	fi
else
	echo "MISS $KERNEL_CONFIG not found - run 03-build-kernel-and-rootfs.sh first"
fi

# Functional production-baseline mission, Phase 4: assert the packaged, real,
# fully-resolved production DTB (not the layered .dts source, which would
# need this script to reimplement override-precedence itself) keeps every
# intentionally-disabled reference-design block disabled, and every required
# product device enabled. Decompiles with the dtc host tool Buildroot already
# builds (output/host/bin/dtc) - no Docker/network needed for this check.
DTB="$REPO_ROOT/vendor/buildroot-x2000/output/build/linux-custom/module_drivers/dts/x2000/halley5_v30.dtb"
DTC="$REPO_ROOT/vendor/buildroot-x2000/output/host/bin/dtc"
echo "=== production DTB capability assertions ==="
if [ -f "$DTB" ] && [ -x "$DTC" ]; then
	DECOMPILED=$(mktemp)
	"$DTC" -I dtb -O dts "$DTB" 2>/dev/null > "$DECOMPILED"

	# Prints the "status" value of the first node whose header line matches
	# $1, scoped to that node's own body only (stops descending into the
	# first child node it hits). No explicit status property = "okay" (the
	# devicetree spec default).
	node_status() {
		awk -v pat="$1" '
			BEGIN { found = 0; depth = 0; status = "okay" }
			found && depth >= 1 {
				if (match($0, /status = "[a-z]+"/)) {
					s = substr($0, RSTART, RLENGTH)
					gsub(/status = "|"/, "", s)
					status = s
					found = 2
				}
			}
			$0 ~ pat && /\{[ \t]*$/ && found == 0 { found = 1 }
			found >= 1 {
				o = gsub(/\{/, "{"); c = gsub(/\}/, "}")
				depth += o - c
				if (found == 1 && depth == 0) { found = 3 }
				else if (depth <= 0) { exit }
			}
			END { print status }
		' "$DECOMPILED"
	}

	assert_status() {
		name="$1"; pat="$2"; want="$3"
		got=$(node_status "$pat")
		case "$want" in
			enabled)
				if [ "$got" = "okay" ] || [ "$got" = "ok" ]; then
					echo "OK   $name enabled (status=$got)"
				else
					echo "MISS $name expected enabled, got status=$got"
				fi
				;;
			disabled)
				if [ "$got" = "disabled" ] || [ "$got" = "disable" ]; then
					echo "OK   $name disabled (status=$got)"
				else
					echo "MISS $name expected disabled, got status=$got"
				fi
				;;
		esac
	}

	echo "--- must stay disabled (unused reference-design blocks) ---"
	assert_status "mac1 (unpopulated Ethernet)"      'mac@134a0000 {'      disabled
	assert_status "msc2 (unused MMC controller)"      'msc@13490000 {'      disabled
	assert_status "sfc (unpopulated SPI-NOR/NAND)"    'sfc@13440000 {'      disabled
	assert_status "mscaler0 (unused v4l2_subdev)"     'mscaler@13702300 {'  disabled
	assert_status "mscaler1 (unused v4l2_subdev)"     'mscaler@13802300 {'  disabled
	assert_status "uart3 (guaranteed pin conflict)"   'serial@10033000 {'   disabled
	assert_status "as-dmic (no product mic array)"    'as-dmic {'           disabled
	assert_status "as-baic (BAIC0/4, no stock ALSA use)" 'as-baic {'        disabled
	assert_status "as-platform (ALSA DMA frontend)"   'as-platform {'       disabled
	assert_status "as-fmtcov (ALSA format conv)"      'as-fmtcov {'         disabled
	assert_status "as-dsp (ALSA DSP/LO_MUX)"          'as-dsp {'            disabled
	assert_status "as-mixer (ALSA aux mixer)"         'as-mixer {'          disabled
	assert_status "as-spdif (ALSA SPDIF)"             'as-spdif {'          disabled
	assert_status "icodec (on-chip audio codec)"      'icodec@10020000 {'   disabled

	echo "--- must stay enabled (required product devices) ---"
	assert_status "msc0/eMMC"           'msc@13450000 {'   enabled
	assert_status "msc1/WiFi SDIO"      'msc@13460000 {'   enabled
	assert_status "uart1 (printer MCU link)" 'serial@10031000 {' enabled
	assert_status "uart4 (console)"     'serial@10034000 {' enabled
	assert_status "i2c4 (touchscreen)"  'i2c@10054000 {'    enabled
	assert_status "i2c2 (BL24C16F EEPROM bus)" 'i2c@10052000 {' enabled
	assert_status "dpu (display)"       'dpu@[0-9a-fx]+ {'  enabled
	assert_status "pwm (beeper channel)" 'pwm@134c0000 {'   enabled
	assert_status "otg (USB)"           'otg@13500000 {'    enabled
	assert_status "rtc"                 'rtc@10003000 {'    enabled
	assert_status "watchdog"            'watchdog@10002000 {' enabled

	echo "--- Phase 1.9A/1.9B accelerometer/EEPROM node content ---"
	if grep -q 'spi_gpio_adxl345 {' "$DECOMPILED" && grep -q 'spi2 = "/spi_gpio_adxl345"' "$DECOMPILED"; then
		echo "OK   spi_gpio_adxl345 node and spi2 alias present"
	else
		echo "MISS spi_gpio_adxl345 node or spi2 alias missing"
	fi
	if grep -A8 'eeprom@50 {' "$DECOMPILED" | grep -q 'compatible = "atmel,24c16"'; then
		echo "OK   eeprom@50 node present with compatible = \"atmel,24c16\""
	else
		echo "MISS eeprom@50 node missing or wrong compatible string"
	fi
	if grep -A8 'eeprom@50 {' "$DECOMPILED" | grep -q 'reg = <0x50>'; then
		echo "OK   eeprom@50 reg = <0x50>"
	else
		echo "MISS eeprom@50 reg is not <0x50>"
	fi
	EEPROM_BODY=$(awk '/eeprom@50 \{/,/^\t+\};/' "$DECOMPILED")
	if echo "$EEPROM_BODY" | grep -q 'pagesize = <0x10>' \
		&& echo "$EEPROM_BODY" | grep -q 'size = <0x800>' \
		&& echo "$EEPROM_BODY" | grep -qE 'address-width = <0x0?8>' \
		&& echo "$EEPROM_BODY" | grep -qE 'num-addresses = <0x0?8>'; then
		echo "OK   eeprom@50 geometry matches BL24C16F exactly (pagesize=16, size=2048, address-width=8, num-addresses=8)"
	else
		echo "MISS eeprom@50 geometry does not match the expected BL24C16F values (dtc's own decompiled output, hex - actual body: $EEPROM_BODY)"
	fi

	rm -f "$DECOMPILED"
else
	echo "MISS DTB or dtc not found ($DTB / $DTC) - run 03-build-kernel-and-rootfs.sh first"
fi


# Two deliberately different semantics.
#
# check()          - REPORTING. Prints OK/MISS and gates nothing. This is what
#                    almost every call site here wants: many paths are produced
#                    by a specific build stage, and the documented partial
#                    pipelines (docs/BUILD_FROM_SOURCE.md) legitimately run a
#                    subset of 00-06, so a MISS is often "you skipped a stage",
#                    not a defect.
# check_required() - RELEASE-BLOCKING. Same probe, but a MISS increments
#                    MISS_REQUIRED and the script exits non-zero at the end.
#
# The bar for check_required is deliberately high, and every member needs a
# written reason: the path must be one whose absence leaves a SHIPPED image
# permanently unable to perform a core lifecycle function, AND it must be a
# path that cannot legitimately be absent from a partial build - otherwise
# making it fatal breaks a documented flow. Adding a member without meeting
# both halves is how this becomes "all 91 checks are fatal", which would be a
# different defect, not a fix.
#
# Aggregate, never `return 1` from check_required: this script runs under
# `set -e` (:7), so a failing check would abort here and destroy the ~120
# remaining diagnostic lines, which are the whole point of running it.
MISS_REQUIRED=0

check() {
	path="$1"
	if debugfs -R "stat $path" ${IMAGES}/rootfs.ext2 2>&1 | grep -q "Inode:"; then
		echo "OK   $path"
	else
		echo "MISS $path"
	fi
}

# Buildroot 2025.02.18 / Python 3.12 migration: the target Python version is
# DISCOVERED from the image, never spelled here.
#
# These checks used to say /usr/lib/python3.11/... and /usr/bin/python3.11
# literally. A hardcoded version in a PRESENCE check is the good case - it
# fails loudly after a bump - but it still has to be hand-edited in several
# places, and mission rule 10 is that a future minor bump must not require
# repeating this cleanup. Discovering it also lets the gate assert something
# the literals could not: that there is EXACTLY ONE target python, so a
# half-migrated image carrying both 3.11 and 3.12 trees is a hard failure
# rather than a passing check against whichever one was named.
discover_target_python() {
	_found=$(debugfs -R "ls -l /usr/lib" ${IMAGES}/rootfs.ext2 2>/dev/null \
		| tr -s ' ' '\n' | grep -oE '^python3\.[0-9]+$' | sort -u)
	_n=$(printf '%s\n' "$_found" | grep -c .)
	if [ "$_n" -eq 0 ]; then
		echo "FATAL: no /usr/lib/python3.* directory found in rootfs.ext2 - the target Python is missing entirely" >&2
		exit 1
	fi
	if [ "$_n" -gt 1 ]; then
		echo "FATAL: rootfs.ext2 contains MORE THAN ONE target Python tree: $(printf '%s ' $_found)" >&2
		echo "       That is a half-migrated image. Exactly one is expected." >&2
		exit 1
	fi
	printf '%s' "$_found"
}

check_required() {
	path="$1"; why="${2:-}"
	if debugfs -R "stat $path" ${IMAGES}/rootfs.ext2 2>&1 | grep -q "Inode:"; then
		echo "OK   $path"
	else
		echo "MISS $path   <== REQUIRED${why:+ - $why}"
		MISS_REQUIRED=$((MISS_REQUIRED + 1))
	fi
}

check_absent() {
	path="$1"
	if debugfs -R "stat $path" ${IMAGES}/rootfs.ext2 2>&1 | grep -q "Inode:"; then
		echo "MISS $path is present but should have been removed as obsolete"
	else
		echo "OK   $path is absent"
	fi
}

echo "=== kernel modules (still loadable, not built-in) ==="
# Production optimization mission, Phase 9 (2026-07-30): Bluetooth HCI UART
# transport is now removed entirely (CONFIG_BT is not set - uart3, its only
# wired transport, is permanently disabled in this board own DTS due to a
# real pin conflict with the NS2009 touch controller i2c4 bus, so it could
# never actually attach regardless). These modules are now expected
# ABSENT, not present - inverted from the check this section used before.
# The module directory is named after the built kernel release (it was
# hardcoded as 6.6.18-rt23, which would pass vacuously on any other kernel).
KREL=$(cat "$REPO_ROOT/vendor/buildroot-x2000/output/build/linux-custom/include/config/kernel.release" 2>/dev/null)
if [ -n "$KREL" ]; then
	echo "OK   kernel release $KREL"
	check_absent "/lib/modules/$KREL/kernel/drivers/bluetooth/hci_uart.ko"
	check_absent "/lib/modules/$KREL/kernel/drivers/bluetooth/btbcm.ko"
else
	echo "MISS kernel release unknown (include/config/kernel.release not found)"
fi

echo "=== WiFi firmware (FIRMWARE.md sec 53 - proprietary, not committed, staged by fetch-cyw43430-wifi-firmware.sh) ==="
check /lib/firmware/brcm/brcmfmac43430-sdio.bin
check /lib/firmware/brcm/brcmfmac43430-sdio.clm_blob
check /lib/firmware/brcm/brcmfmac43430-sdio.txt

echo "=== camera ==="
check /usr/bin/ustreamer
check /etc/init.d/S50webcam
check /etc/nebulaos-camera-idle-controller.sh
check /etc/init.d/S51nebulaos-camera-idle-controller

echo "=== app stack ==="
# FIRMWARE.md sec 23 (2026-07-23): real, previously-silent bug - the
# gcc-final packages INSTALL_TARGET_CMDS step (copies libstdc++.so* into
# the rootfs) is gated on a Buildroot package stamp that does not get
# invalidated just because BR2_INSTALL_LIBSTDCPP became load-bearing
# later - a stale stamp from the very first build meant this was
# silently missing from every build for days while Klipper (needs it via
# greenlet) died instantly with no log line at all.
# 03-build-kernel-and-rootfs.sh now forces gcc-final-reinstall; this
# check is the permanent guard against that regressing silently again.
check /usr/lib/libstdc++.so.6
# FIRMWARE.md sec 23 (2026-07-23): real, previously-silent bug found right
# after the libstdc++ fix above let Moonraker actually import far enough to
# hit it - importlib_metadata (a real Moonraker dependency) imports zipp at
# runtime, but 04-cross-compile-app-stack.sh downloaded it with --no-deps,
# so zipp itself was never fetched. Moonraker died with
# ModuleNotFoundError: No module named zipp, before opening its own log.
TARGET_PY=$(discover_target_python)
echo "OK   target python discovered from the image: $TARGET_PY"

# --- native Python extension ABI gate --------------------------------------
#
# Every CPython extension in the image must be named with THIS target's ABI
# tag. A wrong tag is not a cosmetic problem: CPython's importlib only
# considers its own suffixes (.cpython-<ver>-mipsel-linux-gnu.so, .abi3.so,
# .so), so a differently-tagged file is invisible to `import` even when the
# object inside it is a perfectly good MIPS shared library.
#
# This gate exists because that exact thing happened, and NOTHING else caught
# it. Buildroot 2025.02.18's package/python-contourpy/python-contourpy.mk uses
# $(eval $(meson-package)) but, unlike python-matplotlib and python-numpy, sets
# no CONF_ENV exporting _PYTHON_SYSCONFIGDATA_NAME - so meson-python read the
# HOST interpreter's sysconfigdata and emitted
# _contourpy.cpython-312-x86_64-linux-gnu.so. Correct MIPS32 rel2 object,
# unusable filename. The build was green, `file` on the target reported zero
# x86-64 binaries, and matplotlib - which hard-depends on contourpy - would
# have failed on the printer at first import, taking NebulaOS's calibration and
# graphing paths with it.
#
# So: assert every tag is identical AND is the expected one. Derived from the
# discovered interpreter version, never written out, so a Python minor bump
# needs no edit here.
TARGET_PY_XY=$(printf '%s' "$TARGET_PY" | sed 's/^python//; s/\.//')
EXPECTED_ABI="cpython-${TARGET_PY_XY}-mipsel-linux-gnu"
if command -v unsquashfs >/dev/null 2>&1 && [ -f "$IMAGES/rootfs.squashfs" ]; then
	ABI_TAGS=$(unsquashfs -l "$IMAGES/rootfs.squashfs" 2>/dev/null \
		| grep -oE 'cpython-[0-9]+[A-Za-z0-9_-]*\.so$' \
		| sed 's/\.so$//' | sort -u)
	if [ -z "$ABI_TAGS" ]; then
		echo "MISS no CPython extension modules found in rootfs.squashfs at all - expected many"
	else
		_bad=0
		for t in $ABI_TAGS; do
			if [ "$t" != "$EXPECTED_ABI" ]; then
				echo "FATAL native Python extension ABI tag '$t' != expected '$EXPECTED_ABI'"
				unsquashfs -l "$IMAGES/rootfs.squashfs" 2>/dev/null | grep -E "$t\.so$" | sed 's/^/        /'
				_bad=1
			fi
		done
		if [ "$_bad" = 0 ]; then
			echo "OK   every CPython extension in the image uses $EXPECTED_ABI ($(unsquashfs -l "$IMAGES/rootfs.squashfs" 2>/dev/null | grep -cE 'cpython-[0-9]+[A-Za-z0-9_-]*\.so$') modules)"
		else
			echo "FATAL a differently-tagged extension is INVISIBLE to import on the target, even though the object inside it may be valid MIPS - see 02-configure-buildroot.sh's local.mk note"
		fi
	fi
else
	echo "MISS unsquashfs unavailable or rootfs.squashfs absent - native extension ABI gate NOT RUN (this is a SKIP, not a pass)"
fi
check /usr/lib/$TARGET_PY/site-packages/zipp
# FIRMWARE.md sec 23 (2026-07-23): numpy is a soft/lazy Klipper dependency -
# shaper_calibrate.py only raises a clean, user-facing error if it is
# missing (not a crash), and only when a user actually runs resonance
# testing. Not launch-blocking, but a real completeness gap for a near-
# universal Klipper workflow, and available as a ready Buildroot package
# (BR2_PACKAGE_PYTHON_NUMPY), so enabled rather than left missing.
check /usr/lib/$TARGET_PY/site-packages/numpy
check /usr/bin/$TARGET_PY
check /opt/klipper/klippy/klippy.py
check /opt/klipper/klippy/chelper/c_helper.so
# Clean-Update + Virgin Baseline mission, Phase 6: nebulaos_version.py
# ships from the forks own klippy/extras/ directory (the earlier cp -r
# klippy step already carries it, same as z_compensate.py and
# prtouch_*.py) - this is what catches a forgotten fork sync before the
# image ever reaches a device, rather than a printer.cfg [nebulaos_version]
# section that fails to load at boot.
check /opt/klipper/klippy/extras/nebulaos_version.py
check /opt/nebulaos-version.json
check /opt/moonraker/moonraker/server.py

# Moonraker sqlite-nolock patch: SECOND-LAYER effect assertion, read out of
# the ACTUAL shipped rootfs rather than the overlay staging tree. The
# load-bearing gate is at the point of patching in
# 04-cross-compile-app-stack.sh (which also stops wrong bytecode being
# precompiled); this one exists because that script and this one can be run
# independently, and because a rootfs check is the last thing between a
# silently-unpatched Moonraker and a device.
#
# The failure being caught: the patch step used to end in `|| true`, so if
# MOONRAKER_PIN moved or upstream refactored database.py, the hunks would
# stop applying, the build would still report success, and the image would
# ship stock database.py with nothing in the log to say so. Two materially
# different Moonraker payloads from the same firmware commit and the same
# pins. See FIRMWARE.md sec 23 for why the patch exists and why it is a
# removal candidate.
#
# Comment lines are stripped before counting: the patch's own explanatory
# comment contains the literal strings "sqlite3.connect()" and "nolock=1",
# so raw counts are 2 and a gate built on them would never pass.
MOONRAKER_DB_CONTENT=$(debugfs -R "cat /opt/moonraker/moonraker/components/database.py" ${IMAGES}/rootfs.ext2 2>/dev/null)
if [ -z "$MOONRAKER_DB_CONTENT" ]; then
	echo "MISS /opt/moonraker/moonraker/components/database.py could not be read from the rootfs"
else
	MDB_CODE=$(echo "$MOONRAKER_DB_CONTENT" | grep -v '^[[:space:]]*#')
	mdb_defs=$(echo "$MOONRAKER_DB_CONTENT" | grep -c '^def connect_sqlite_nolock(')
	mdb_refs=$(echo "$MDB_CODE" | grep -c 'connect_sqlite_nolock(')
	mdb_raw=$(echo "$MDB_CODE" | grep -c 'sqlite3\.connect(')
	mdb_calls=$((mdb_refs - mdb_defs))
	if [ "$mdb_defs" = 1 ] && [ "$mdb_calls" = 4 ] && [ "$mdb_raw" = 1 ]; then
		echo "OK   moonraker-sqlite-nolock.patch is present in the SHIPPED database.py ($mdb_calls call sites through the nolock helper)"
	else
		echo "MISS moonraker-sqlite-nolock.patch did NOT reach the shipped database.py (helper defs=$mdb_defs, call sites=$mdb_calls expected 4, raw sqlite3.connect(=$mdb_raw expected 1) - the image would ship stock Moonraker database code"
	fi
fi
check /usr/lib/$TARGET_PY/site-packages/streaming_form_data
check_required /usr/lib/$TARGET_PY/site-packages/smart_open "streaming_form_data imports it at module load; without it Moonraker dies at import"

# --- Python distribution metadata closure ----------------------------------
#
# Every installed distribution's declared runtime requirements must be
# installed too. Buildroot packages a distribution without its Requires-Dist,
# so nothing else in the build notices a missing one - and an import test is
# not possible here, because the image is MIPS.
#
# This gate exists because that happened. streaming-form-data 1.19.1 declares
# smart-open>=7.0.5 and imports it at module load. The first Buildroot
# 2025.02.18 image shipped without smart_open; the ELF and ABI-tag gates above
# passed, because the missing piece was a pure-Python module that simply was
# not there. Moonraker died at import on the printer, and its own pip recovery
# could not fix it. The metadata said exactly what was needed.
#
# Only the METADATA files are extracted. Requirements behind an `extra` are
# optional and are not checked. Release-blocking.
#
# Run with Buildroot's own host python (the output/host/bin/dtc pattern
# above), which always has `packaging`: host-python-setuptools-scm depends on
# host-python-packaging. The build machine's python3 is only a fallback.
echo "=== Python distribution metadata closure ==="
CLOSURE_PY="$REPO_ROOT/vendor/buildroot-x2000/output/host/bin/python3"
[ -x "$CLOSURE_PY" ] || CLOSURE_PY=python3
CLOSURE_SITE="/usr/lib/$TARGET_PY/site-packages"
CLOSURE_DIR="$(mktemp -d)"
for d in $(debugfs -R "ls -p $CLOSURE_SITE" ${IMAGES}/rootfs.ext2 2>/dev/null \
		| awk -F/ '$6 ~ /\.dist-info$/ {print $6}'); do
	mkdir -p "$CLOSURE_DIR/$d"
	debugfs -R "dump $CLOSURE_SITE/$d/METADATA $CLOSURE_DIR/$d/METADATA" ${IMAGES}/rootfs.ext2 >/dev/null 2>&1 || true
done
if CLOSURE_OUT=$("$CLOSURE_PY" "$SCRIPT_DIR/lib/check-python-dist-closure.py" "$CLOSURE_DIR" "${TARGET_PY#python}" 2>&1); then
	echo "$CLOSURE_OUT"
else
	echo "$CLOSURE_OUT" | sed 's/^UNMET \(.*\)$/MISS \1   <== REQUIRED/'
	MISS_REQUIRED=$((MISS_REQUIRED + 1))
fi
rm -rf "$CLOSURE_DIR"
check /usr/sbin/nginx
check /usr/share/mainsail/index.html
check /etc/init.d/S55klipper
check /etc/init.d/S56moonraker
check /etc/init.d/S50nginx
check /opt/printer_data/config/printer.cfg
check /opt/printer_data/config/moonraker.conf
check /usr/libexec/nebulaos-set-camera-quality

echo "=== Phase 2: image-owned config under /etc/nebulaos/klipper/ ==="
check /etc/nebulaos/klipper/platform.cfg
check /etc/nebulaos/klipper/machine.cfg
check /etc/nebulaos/klipper/prtouch.cfg
check /etc/nebulaos/klipper/z_offset_probe.cfg
check /etc/nebulaos/klipper/calibration.cfg
check /etc/nebulaos/klipper/homing.cfg
check /etc/nebulaos/klipper/print.cfg
check /etc/nebulaos/klipper/filament.cfg
check /etc/nebulaos/klipper/camera.cfg
check /etc/nebulaos/klipper/beeper.cfg
# Final pre-hardware closure (2026-09-06): load_cell_probe.cfg was a
# never-included Phase 1.8 design artifact (the abandoned "replace BLTouch
# entirely with the load cell" direction) that still shipped on the
# read-only rootfs despite being permanently inactive - a stale production
# artifact per the Phase 2 sensor audit. Removed from source entirely;
# historical design rationale remains in git history (commit 6b170dc) and
# this project's own commit messages, not as a live config file on disk.
check_absent /etc/nebulaos/klipper/load_cell_probe.cfg

echo "=== Phase 1.9A: host MCU (klipper_mcu) / ADXL345 / BL24C16F ==="
# klipper_mcu is Klipper's own MACH_LINUX build target, compiled as a native
# MIPS Linux program with the project's mipsel-buildroot-linux-gnu-
# toolchain (04-cross-compile-app-stack.sh) - serves [mcu rpi] for the
# physical accelerometer and EEPROM, both wired directly to the SoC. No
# interaction with the separate GD32F303 stepper-driver MCU S50nebulaos-
# mcu-guard manages. See
# _project/missions/phase1.9-host-mcu-accelerometer-plr-analysis.md for
# the full architecture.
check /usr/bin/klipper_mcu
check /etc/init.d/S54nebulaos-host-mcu
# bl24c16f.py stays composed for provenance (Phase 1.9A) but is retired from
# production use as of Phase 1.9B - see the machine.cfg [bl24c16f]-absence
# check and the [nebulaos_power_loss_recovery] presence check below.
check /opt/klipper/klippy/extras/bl24c16f.py
check /opt/klipper/klippy/extras/nebulaos_plr_journal.py
check /opt/klipper/klippy/extras/nebulaos_power_loss_recovery.py

MACHINE_CFG_CONTENT=$(debugfs -R "cat /etc/nebulaos/klipper/machine.cfg" ${IMAGES}/rootfs.ext2 2>/dev/null)
S54_CONTENT=$(debugfs -R "cat /etc/init.d/S54nebulaos-host-mcu" ${IMAGES}/rootfs.ext2 2>/dev/null)
if echo "$MACHINE_CFG_CONTENT" | grep -qE "^\[mcu rpi\]$"; then
	echo "OK   machine.cfg declares [mcu rpi]"
else
	echo "MISS machine.cfg does not declare [mcu rpi]"
fi
if echo "$MACHINE_CFG_CONTENT" | grep -qE "^\[adxl345\]$"; then
	echo "OK   machine.cfg declares [adxl345]"
else
	echo "MISS machine.cfg does not declare [adxl345]"
fi
if echo "$MACHINE_CFG_CONTENT" | grep -qE "^\[resonance_tester\]$"; then
	echo "OK   machine.cfg declares [resonance_tester]"
else
	echo "MISS machine.cfg does not declare [resonance_tester]"
fi
if echo "$MACHINE_CFG_CONTENT" | grep -qE "^\[bl24c16f\]$"; then
	echo "MISS machine.cfg declares [bl24c16f] - Phase 1.9B retired this as the production EEPROM owner (should be [nebulaos_power_loss_recovery] over at24 instead)"
else
	echo "OK   machine.cfg does not declare [bl24c16f] (retired, Phase 1.9B)"
fi
if echo "$MACHINE_CFG_CONTENT" | grep -qE "^\[nebulaos_power_loss_recovery\]$"; then
	echo "OK   machine.cfg declares [nebulaos_power_loss_recovery]"
else
	echo "MISS machine.cfg does not declare [nebulaos_power_loss_recovery]"
fi
if echo "$MACHINE_CFG_CONTENT" | grep -A2 "^\[nebulaos_power_loss_recovery\]$" | grep -qF "eeprom_path: /sys/bus/i2c/devices/2-0050/eeprom"; then
	echo "OK   [nebulaos_power_loss_recovery]'s eeprom_path matches the at24 eeprom@50 DT node's sysfs path"
else
	echo "MISS [nebulaos_power_loss_recovery]'s eeprom_path does not match the expected at24 sysfs path"
fi
if echo "$S54_CONTENT" | grep -qF -- '--exec "$KLIPPER_HOST_MCU" -- -r -I "$SOCKET"'; then
	echo "OK   S54nebulaos-host-mcu starts /usr/bin/klipper_mcu with -r -I \$SOCKET (explicit socket path)"
else
	echo "MISS S54nebulaos-host-mcu does not start klipper_mcu with an explicit -I socket path"
fi
S54_SOCKET=$(echo "$S54_CONTENT" | grep -oE "^SOCKET=.*" | cut -d= -f2)
if [ -n "$S54_SOCKET" ] && echo "$MACHINE_CFG_CONTENT" | grep -A1 "^\[mcu rpi\]$" | grep -qF "serial: $S54_SOCKET"; then
	echo "OK   S54nebulaos-host-mcu's \$SOCKET ($S54_SOCKET) exactly matches [mcu rpi]'s serial: in machine.cfg"
else
	echo "MISS S54nebulaos-host-mcu's \$SOCKET does not match [mcu rpi]'s serial: in machine.cfg"
fi

echo "=== process launch arguments and config-path consistency (mainline print-controls mission addendum, 2026-07-29) ==="
# A newly reported Mainsail "Config Files -> config folder appears empty"
# report required proving Klipper, Moonraker, and Mainsail all resolve to
# the exact same canonical config directory - not inferring it from any
# one of them alone. Live investigation against the real device found the
# architecture already correct end to end (same inode on both the
# persistent and bind-mounted runtime path, Moonrakers own
# /server/files/roots reporting the canonical path with rw, a full
# create/read/edit/delete cycle through the real file-manager API); these
# checks exist to keep it that way, catching a future regression at build
# time rather than live on a real printer.
S55_CONTENT=$(debugfs -R "cat /etc/init.d/S55klipper" ${IMAGES}/rootfs.ext2 2>/dev/null)
S56_CONTENT=$(debugfs -R "cat /etc/init.d/S56moonraker" ${IMAGES}/rootfs.ext2 2>/dev/null)
S01_CONTENT=$(debugfs -R "cat /etc/init.d/S01persistent-datastore" ${IMAGES}/rootfs.ext2 2>/dev/null)
if echo "$S55_CONTENT" | grep -qE "^CONFIG=/opt/printer_data/config/printer.cfg$"; then
	echo "OK   S55klipper launches Klipper against the canonical /opt/printer_data/config/printer.cfg"
else
	echo "MISS S55klipper does not launch Klipper against the canonical printer.cfg path"
fi
if echo "$S56_CONTENT" | grep -qE "^DATAPATH=/opt/printer_data$"; then
	echo "OK   S56moonraker launches Moonraker with the canonical -d /opt/printer_data data path"
else
	echo "MISS S56moonraker does not launch Moonraker with the canonical data path"
fi
if echo "$S56_CONTENT" | grep -qE "^CONFIG=/opt/printer_data/config/moonraker.conf$"; then
	echo "OK   S56moonraker launches Moonraker against the canonical moonraker.conf"
else
	echo "MISS S56moonraker does not launch Moonraker against the canonical moonraker.conf path"
fi
if echo "$S55_CONTENT" | grep -qi "/usr/data/openke\|/opt/openke" || echo "$S56_CONTENT" | grep -qi "/usr/data/openke\|/opt/openke"; then
	echo "MISS S55klipper or S56moonraker still references an obsolete openke path"
else
	echo "OK   S55klipper and S56moonraker contain no obsolete openke path reference (comment mentions of the historical OpenKE project name are fine)"
fi
if echo "$S01_CONTENT" | grep -qE "mount --bind ..PDATA. /opt/printer_data"; then
	echo "OK   S01persistent-datastore bind-mounts the persistent printer_data tree onto /opt/printer_data"
else
	echo "MISS S01persistent-datastore does not bind-mount printer_data onto /opt/printer_data as expected"
fi
if echo "$S01_CONTENT" | grep -qE "^DATA_ROOT=/usr/data/nebulaos$"; then
	echo "OK   S01persistent-datastore uses the canonical persistent backing root /usr/data/nebulaos"
else
	echo "MISS S01persistent-datastore does not use /usr/data/nebulaos as the persistent backing root"
fi

echo "=== Moonraker update_manager / camera / Mainsail macro seeding ==="
check /usr/libexec/nebulaos-seed-camera
check /etc/init.d/S57nebulaos-camera-seed
check /usr/libexec/nebulaos-seed-mainsail-macros
check /etc/init.d/S57nebulaos-mainsail-macros-seed

# RC2 overnight closure (2026-09-06): the Mainsail macro-group ID bug -
# Mainsail's own pinned v2.18.2 Dashboard.vue lineage parses a dashboard
# panel name as `"macrogroup_" + name.split("_")[1]`, so a further
# underscore in a group's own stable ID resolves to the wrong id. Verified
# straight from the actual seed script shipped in this built image, not
# from source alone - a build that composed a stale/pre-migration copy of
# the script would fail this even if the source tree looks correct.
#
# Scoped to the DEFAULT_GROUPS assignment only (real fresh-install/seed
# group IDs) - LEGACY_GROUP_ID_MAP's own KEYS are deliberately the old
# underscore IDs (that is what the migration maps FROM), so a whole-file
# grep for the underscore pattern produces a false MISS against a
# perfectly correct script. Found live against the first real RC2 build
# tonight - the whole-file version of this check was wrong, not the
# script.
SEED_MAINSAIL_MACROS_CONTENT=$(debugfs -R "cat /usr/libexec/nebulaos-seed-mainsail-macros" ${IMAGES}/rootfs.ext2 2>/dev/null)
DEFAULT_GROUPS_BLOCK=$(echo "$SEED_MAINSAIL_MACROS_CONTENT" | awk '/^DEFAULT_GROUPS = \{/{grab=1} grab{print} grab && /^\}$/{exit}')
if [ -n "$SEED_MAINSAIL_MACROS_CONTENT" ]; then
	if echo "$DEFAULT_GROUPS_BLOCK" | grep -qE '"nebulaos_(calibration|input_shaper|extruder|camera|maintenance|recovery)"'; then
		echo "MISS nebulaos-seed-mainsail-macros's DEFAULT_GROUPS still declares an underscore-style managed group ID"
	else
		echo "OK   nebulaos-seed-mainsail-macros's DEFAULT_GROUPS declares no underscore-style managed group ID"
	fi
	if echo "$SEED_MAINSAIL_MACROS_CONTENT" | grep -qE '"nebulaos-(calibration|input-shaper|extruder|camera|maintenance|recovery)"'; then
		echo "OK   nebulaos-seed-mainsail-macros declares the expected hyphenated managed group IDs"
	else
		echo "MISS nebulaos-seed-mainsail-macros is missing one or more expected hyphenated group IDs"
	fi
	if echo "$SEED_MAINSAIL_MACROS_CONTENT" | grep -q "LEGACY_GROUP_ID_MAP"; then
		echo "OK   nebulaos-seed-mainsail-macros ships the legacy underscore->hyphen migration map"
	else
		echo "MISS nebulaos-seed-mainsail-macros has no legacy-ID migration logic"
	fi
	if echo "$SEED_MAINSAIL_MACROS_CONTENT" | grep -qE 'DEFAULT_MODE = "expert"'; then
		echo "OK   nebulaos-seed-mainsail-macros defaults a genuinely untouched macros.mode to \"expert\""
	else
		echo "MISS nebulaos-seed-mainsail-macros does not default macros.mode to \"expert\""
	fi
else
	echo "MISS could not read /usr/libexec/nebulaos-seed-mainsail-macros from the built image"
fi

# Content checks against the actual shipped moonraker.conf, not just its
# presence - the whole point of this mission was that a real, previously
# undetected content-level defect (unsupported options under the reserved
# klipper/moonraker update_manager sections; an active, permanently
# un-editable config-sourced default camera) shipped in a build that
# passed every existence-only check that came before it. debugfs extracts
# the real file content from the built image itself, not from the source
# tree, so a build where the overlay sync silently dropped or mismatched
# the edit will not pass this check.
#
# NOTE for future edits to this section: everything in this file from the
# earlier "docker run ... bash -c" line through its own matching close
# further below is one single-quoted string as far as the real, top-level
# shell running this script is concerned - a literal single-quote
# character anywhere in this region (even inside a # comment) would
# terminate that outer quoting early and corrupt the rest of the file.
# Use double quotes for every string/pattern added below instead - none
# of them need a literal dollar sign or backtick, so double-quoting is
# always safe here.
MOONRAKER_CONF_CONTENT=$(debugfs -R "cat /opt/printer_data/config/moonraker.conf" ${IMAGES}/rootfs.ext2 2>/dev/null)

# Phase 1.5 persistent-namespace mission (2026-08): the reserved
# [update_manager klipper]/[update_manager nebulaos_klipper_extensions]
# sections moved out of the persistent moonraker.conf entirely, into the
# image-owned /etc/nebulaos/moonraker/klipper-pin.conf, included from
# moonraker.conf with a single absolute-path line. Checking
# MOONRAKER_CONF_CONTENT alone for those sections is therefore no longer
# meaningful on its own - this used to produce a false MISS on a genuinely
# correct image (recorded in the Phase 0+1 closeout report as a known,
# deferred defect: "not include-aware"). RESOLVED_MOONRAKER_CONTENT below
# is what an include-aware reader would actually see: the content of
# moonraker.conf plus the image-owned pin file it includes, concatenated in
# include order - not a general Moonraker include-glob implementation, just
# enough to check the one real include this config actually uses.
KLIPPER_PIN_CONF_CONTENT=$(debugfs -R "cat /etc/nebulaos/moonraker/klipper-pin.conf" ${IMAGES}/rootfs.ext2 2>/dev/null)
RESOLVED_MOONRAKER_CONTENT="$MOONRAKER_CONF_CONTENT
$KLIPPER_PIN_CONF_CONTENT"

if echo "$MOONRAKER_CONF_CONTENT" | grep -qxF "[include /etc/nebulaos/moonraker/klipper-pin.conf]"; then
	echo "OK   moonraker.conf includes the image-owned /etc/nebulaos/moonraker/klipper-pin.conf"
else
	echo "MISS moonraker.conf does not include /etc/nebulaos/moonraker/klipper-pin.conf"
fi
if [ -n "$KLIPPER_PIN_CONF_CONTENT" ]; then
	echo "OK   /etc/nebulaos/moonraker/klipper-pin.conf is present in the built image"
else
	echo "MISS /etc/nebulaos/moonraker/klipper-pin.conf is missing or empty in the built image"
fi

check_conf_absent() {
	pattern="$1"; desc="$2"
	if echo "$MOONRAKER_CONF_CONTENT" | grep -qE "$pattern"; then
		echo "MISS moonraker.conf still contains: $desc"
	else
		echo "OK   moonraker.conf does not contain: $desc"
	fi
}
check_conf_present() {
	pattern="$1"; desc="$2"
	if echo "$MOONRAKER_CONF_CONTENT" | grep -qE "$pattern"; then
		echo "OK   moonraker.conf contains: $desc"
	else
		echo "MISS moonraker.conf missing: $desc"
	fi
}
# SimpleAF backend integration (2026-07-29) needs a real, non-empty
# [file_manager] section (enable_object_processing: True, required for
# exclude_object polygon data) - this check used to forbid the whole
# section outright, which conflicts with that legitimate need. The real
# original worry was narrower: vendor/moonraker/moonraker/components/
# file_manager/file_manager.py only reads two deprecated path-override
# options from this section, config_path and log_path (config.get(...,
# deprecate=True) for both) - anything else here, including
# enable_object_processing, cannot divert the config root away from
# -d /opt/printer_data. Scope the check to just those two options,
# the same way the update_manager section check below scopes to its own
# reserved-option list rather than forbidding the section itself.
FILE_MANAGER_SECTION_BODY=$(echo "$MOONRAKER_CONF_CONTENT" | awk "
	/^\[file_manager\]\$/ { grab=1; next }
	/^\[/ { grab=0 }
	grab { print }
")
if echo "$FILE_MANAGER_SECTION_BODY" | grep -qE "^(config_path|log_path): "; then
	echo "MISS [file_manager] contains a deprecated config_path/log_path override (the config root must keep deriving from -d /opt/printer_data by default, not an override that could diverge from the printer.cfg path Klipper actually reads)"
else
	echo "OK   [file_manager] contains no config_path/log_path override"
fi
# Extracts just the [update_manager klipper] and [update_manager moonraker]
# sections own body (up to the next [section] header) - scoped
# deliberately, since path/type ARE legitimate, needed options under the
# DIFFERENT (generic, type: web) [update_manager mainsail] section; a
# whole-file check would wrongly flag those as a regression.
# Phase 1.5: read from RESOLVED_MOONRAKER_CONTENT (moonraker.conf +
# klipper-pin.conf, concatenated) rather than MOONRAKER_CONF_CONTENT alone
# - [update_manager klipper] now lives entirely in the included file.
RESERVED_SECTIONS_BODY=$(echo "$RESOLVED_MOONRAKER_CONTENT" | awk "
	/^\[update_manager klipper\]\$/ || /^\[update_manager moonraker\]\$/ { grab=1; next }
	/^\[/ { grab=0 }
	grab { print }
")

check_conf_absent "^\[webcam " "an active [webcam ...] section"
if echo "$RESERVED_SECTIONS_BODY" | grep -qE "^(type|path|origin|primary_branch|managed_services|virtualenv|requirements): "; then
	echo "MISS [update_manager klipper]/[update_manager moonraker] still contain unsupported options (type/path/origin/primary_branch/managed_services/virtualenv/requirements) - these are reserved slots, see docs/NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md"
else
	echo "OK   [update_manager klipper]/[update_manager moonraker] contain no unsupported options"
fi
if echo "$RESOLVED_MOONRAKER_CONTENT" | grep -qE "^\[update_manager klipper\]\$"; then
	echo "OK   resolved moonraker config contains: the reserved [update_manager klipper] section"
else
	echo "MISS resolved moonraker config missing: the reserved [update_manager klipper] section"
fi
check_conf_present "^\[update_manager moonraker\]\$" "the reserved [update_manager moonraker] section"
check_conf_present "^\[update_manager mainsail\]\$" "the Mainsail web updater section"
if echo "$RESERVED_SECTIONS_BODY" | grep -qE "^channel: dev\$"; then
	echo "OK   [update_manager klipper]/[update_manager moonraker] set channel: dev"
else
	echo "MISS [update_manager klipper]/[update_manager moonraker] missing channel: dev"
fi

echo "=== factory-seed git archives (auto-updates-camera-complete mission, 2026-07-28) ==="
# Real bug this whole mission exists to fix: the OLD flattened-synthetic-
# commit seed made every freshly-seeded klipper/moonraker checkout
# diverged=true, is_valid=false, permanently blocking real updates - see
# docs/NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md. Existence-only
# checks cannot see this - it needs the actual archive content dumped out
# of the built image and inspected with real git commands, the same way
# the moonraker.conf content checks above go beyond existence-only.
# Real bug found live: the extracted archive keeps the UID it was tarred
# with on the build host, which does not match this containers root user
# - git refuses to operate on it at all ("detected dubious ownership"),
# silently making every symbolic-ref/remote/status command below return
# empty instead of erroring, which made every check misreport a MISS.
# Harmless here (a throwaway verification container, not a real trust
# boundary) - exempt the one fixed extraction path used below.
git config --global --add safe.directory /tmp/seed-check
check_seed_archive() {
	archive_path="$1"; expected_branch="$2"; expected_origin="$3"; label="$4"
	rm -rf /tmp/seed-check
	mkdir -p /tmp/seed-check
	if ! debugfs -R "dump $archive_path /tmp/seed-check.tar" ${IMAGES}/rootfs.ext2 >/dev/null 2>&1; then
		echo "MISS $label archive could not be dumped from the image ($archive_path)"
		return
	fi
	if ! tar -xzf /tmp/seed-check.tar -C /tmp/seed-check 2>/dev/null; then
		echo "MISS $label archive is not a valid tar file"
		return
	fi
	if git -C /tmp/seed-check log --all --format=%s 2>/dev/null | grep -q "NebulaOS factory seed snapshot"; then
		echo "MISS $label archive still contains a synthetic factory-seed wrapper commit"
	else
		echo "OK   $label archive contains no synthetic wrapper commit"
	fi
	actual_branch=$(git -C /tmp/seed-check symbolic-ref --short HEAD 2>/dev/null)
	if [ "$actual_branch" = "$expected_branch" ]; then
		echo "OK   $label archive is on branch $expected_branch"
	else
		echo "MISS $label archive is on branch \"$actual_branch\", expected $expected_branch"
	fi
	actual_origin=$(git -C /tmp/seed-check remote get-url origin 2>/dev/null)
	if [ "$actual_origin" = "$expected_origin" ]; then
		echo "OK   $label archive origin is $expected_origin"
	else
		echo "MISS $label archive origin is \"$actual_origin\", expected $expected_origin"
	fi
	actual_refspec=$(git -C /tmp/seed-check config --get remote.origin.fetch 2>/dev/null)
	if [ "$actual_refspec" = "+refs/heads/*:refs/remotes/origin/*" ]; then
		echo "OK   $label archive origin has the full wildcard fetch refspec"
	else
		echo "MISS $label archive origin fetch refspec is \"$actual_refspec\", expected the full wildcard form (a narrow refspec silently breaks a later git fetch origin from populating origin/$expected_branch, reproducing diverged=true)"
	fi
	# Production optimization mission, Phase 9 (2026-07-30): same pathspec
	# exclusion as the internal clean-tree guard in make-seed-archive.sh -
	# the klipper build own properly cross-compiled+stripped c_helper.so is
	# legitimately, always different from whatever is tracked in git for
	# that path (an untrusted upstream binary). Moonraker has no such
	# path, so this exclusion is a no-op there. Double quotes, not single
	# quotes, around the pathspec magic below - a literal single quote
	# here would close the outer docker bash -c string early exactly like
	# the apostrophe bugs elsewhere in this same file.
	if [ -z "$(git -C /tmp/seed-check status --porcelain -- . ":!klippy/chelper/c_helper.so" 2>/dev/null)" ]; then
		echo "OK   $label archive has a clean working tree"
	else
		echo "MISS $label archive has a dirty working tree"
	fi
	rm -rf /tmp/seed-check /tmp/seed-check.tar
}
# Phase 1.5 closure mission (2026-08-19): the klipper check below used to
# hardcode the RETIRED forks origin, coreflake1/NebulaOS-klipper.git - a
# stale leftover from before the Phase 1 no-fork migration, producing a
# permanent false MISS against a genuinely correct image (the seeded
# checkout is deliberately official, unmodified Klipper3d/klipper now).
# Sourced from $KLIPPER_REPO (manifests/dependencies.conf, already loaded
# above) instead of a second hardcoded copy, so this can never drift from
# the pin actually used again - and so reintroducing the retired fork
# origin in the manifest would make this check genuinely, correctly FAIL,
# which a hardcoded string could never do.
check_seed_archive /opt/nebulaos-seeds/klipper.tar.gz "$KLIPPER_BRANCH" "$KLIPPER_REPO" "klipper"
check_seed_archive /opt/nebulaos-seeds/moonraker.tar.gz master "https://github.com/Arksine/moonraker.git" "moonraker"
# Phase 1.5 closure mission (2026-08-19): the extensions seed archive origin
# was never checked here at all - added to close the same class of gap,
# using the same manifest-sourced pattern.
check_seed_archive /opt/nebulaos-seeds/nebulaos-klipper-extensions.tar.gz "$KLIPPER_EXTENSIONS_BRANCH" "$KLIPPER_EXTENSIONS_REPO" "nebulaos-klipper-extensions"

# Real bug this catches if regressed: the c_helper.so committed inside
# vendor/klippers own git history (an upstream binary) is incompatible
# with this image and hangs Klipper indefinitely with no on-device
# compiler to fall back on - only this projects own cross-compiled copy,
# already baked into the immutable /opt/klipper baseline, actually loads.
# Confirms the seed archives copy (the one the persistent, git-updatable
# checkout actually ships) is byte-identical to the proven-working
# immutable one, not silently reverted to the incompatible upstream blob.
rm -rf /tmp/chelper-check
mkdir -p /tmp/chelper-check
debugfs -R "dump /opt/nebulaos-seeds/klipper.tar.gz /tmp/chelper-check.tar.gz" ${IMAGES}/rootfs.ext2 >/dev/null 2>&1
if tar -xzf /tmp/chelper-check.tar.gz -C /tmp/chelper-check ./klippy/chelper/c_helper.so 2>/dev/null; then
	SEED_CHELPER_SHA=$(sha256sum /tmp/chelper-check/klippy/chelper/c_helper.so 2>/dev/null | cut -d" " -f1)
	BASELINE_CHELPER_SHA=$(debugfs -R "cat /opt/klipper/klippy/chelper/c_helper.so" ${IMAGES}/rootfs.ext2 2>/dev/null | sha256sum | cut -d" " -f1)
	if [ -n "$SEED_CHELPER_SHA" ] && [ "$SEED_CHELPER_SHA" = "$BASELINE_CHELPER_SHA" ]; then
		echo "OK   klipper seed archives c_helper.so matches the proven-working immutable baseline"
	else
		echo "MISS klipper seed archives c_helper.so ($SEED_CHELPER_SHA) does not match the immutable baseline ($BASELINE_CHELPER_SHA) - it may be the incompatible upstream binary"
	fi
else
	echo "MISS could not extract klippy/chelper/c_helper.so from the klipper seed archive for comparison"
fi
rm -rf /tmp/chelper-check /tmp/chelper-check.tar.gz
SEED_MANIFEST_CONTENT=$(debugfs -R "cat /opt/nebulaos-seeds/seed-manifest.json" ${IMAGES}/rootfs.ext2 2>/dev/null)
if echo "$SEED_MANIFEST_CONTENT" | grep -q "git_bundle_flattened"; then
	echo "MISS seed-manifest.json still references the removed git_bundle_flattened format"
else
	echo "OK   seed-manifest.json does not reference the removed git_bundle_flattened format"
fi
if echo "$SEED_MANIFEST_CONTENT" | grep -q "git_repo_archive_real_history"; then
	echo "OK   seed-manifest.json records the real-history archive format"
else
	echo "MISS seed-manifest.json missing the real-history archive format record"
fi

echo "=== printer_data config factory seed ==="
# A genuinely wiped printer_data/config leaves Klipper and Moonraker
# crash-looping - the immutable seed at /opt/nebulaos-seeds/printer_data-
# config/ is what S02nebulaos-namespace restores from. Phase 2: seed
# contains printer.cfg, moonraker.conf, songs.conf, and
# GuppyScreen/scripts/static_ip.py (see below); all workflow macros live
# in /etc/nebulaos/klipper/*.cfg (image-owned, included via absolute
# paths).
check /opt/nebulaos-seeds/printer_data-config/printer.cfg
check /opt/nebulaos-seeds/printer_data-config/moonraker.conf
# These files belonged to the old SimpleAF/GuppyScreen architecture and
# must NOT be present in the Phase 2 seed.
check_absent /opt/nebulaos-seeds/printer_data-config/frontend-controls.cfg
check_absent /opt/nebulaos-seeds/printer_data-config/camera-quality.cfg
check_absent /opt/nebulaos-seeds/printer_data-config/GuppyScreen/scripts/set_camera_quality.py
check_absent /opt/nebulaos-seeds/printer_data-config/GuppyScreen/guppy_cmd.cfg
check_absent /opt/nebulaos-seeds/printer_data-config/simpleaf/homing.cfg
# Clean Mainsail config root mission (2026-09-10): static_ip.py is the one
# exception to "the old GuppyScreen deps are gone" - the compiled
# /opt/guppyscreen/guppyscreen binary has
# /opt/printer_data/config/GuppyScreen/scripts/static_ip.py hardcoded as a
# literal path (confirmed via `strings` against a real device's binary),
# so a fresh device built without this file would silently ship a broken
# touchscreen static-IP feature. The 2026-08 "remove SimpleAF/GuppyScreen
# deps" refactor deleted it along with the genuinely dead scripts in the
# same directory without checking for this dependency.
#
# Audit F-11 (2026-09-22): that restore was taken "byte-identical from a
# live, already-qualified device" (sha256 c131017c...), and the device
# predated GUPPYSCREEN_PIN 5f1911ac's own fix - so it silently reverted
# static_ip.py's state paths back onto the retired /usr/data/printer_data
# alias, which overlaps stock's shared tree. This file is OWNED by
# NebulaOS-guppyscreen (k1/scripts/static_ip.py); the copy here exists only
# because the compiled binary hardcodes the runtime path. It is now
# byte-identical to that owner at GUPPYSCREEN_PIN (sha256
# b3e7a0dae3f86343a4d205effed240b971ff6e2977ded547f39767fe0da6aa72), and
# tests/guppyscreen-owned-files-tests.sh asserts that mechanically. Do not
# hand-edit it or restore it from a device - update the owning repository,
# advance the pin, then re-sync.
check /opt/nebulaos-seeds/printer_data-config/GuppyScreen/scripts/static_ip.py

rm -rf /tmp/printerdata-check
mkdir -p /tmp/printerdata-check
debugfs -R "dump /opt/nebulaos-seeds/printer_data-config/printer.cfg /tmp/printerdata-check/printer.cfg" ${IMAGES}/rootfs.ext2 >/dev/null 2>&1
debugfs -R "dump /opt/nebulaos-seeds/printer_data-config/moonraker.conf /tmp/printerdata-check/moonraker.conf" ${IMAGES}/rootfs.ext2 >/dev/null 2>&1

# printer.cfg must include platform.cfg (carries [nebulaos_version]).
if [ -s /tmp/printerdata-check/printer.cfg ] && grep -qF "[include /etc/nebulaos/klipper/platform.cfg]" /tmp/printerdata-check/printer.cfg 2>/dev/null; then
	echo "OK   packaged printer.cfg seed includes platform.cfg"
else
	echo "MISS packaged printer.cfg seed does not include platform.cfg"
fi
PLATFORM_CFG_CONTENT=$(debugfs -R "cat /etc/nebulaos/klipper/platform.cfg" ${IMAGES}/rootfs.ext2 2>/dev/null)
if echo "$PLATFORM_CFG_CONTENT" | grep -q "^\[nebulaos_version\]$"; then
	echo "OK   packaged platform.cfg declares [nebulaos_version] (loads at boot via printer.cfg's include)"
else
	echo "MISS packaged platform.cfg does not declare [nebulaos_version]"
fi
# printer.cfg must include print.cfg (carries the print workflow).
if [ -s /tmp/printerdata-check/printer.cfg ] && grep -qF "[include /etc/nebulaos/klipper/print.cfg]" /tmp/printerdata-check/printer.cfg 2>/dev/null; then
	echo "OK   packaged printer.cfg seed includes print.cfg"
else
	echo "MISS packaged printer.cfg seed does not include print.cfg"
fi
# printer.cfg must NOT include any SimpleAF/GuppyScreen files.
if [ -s /tmp/printerdata-check/printer.cfg ]; then
	if grep -qE "^\[include (simpleaf/|GuppyScreen/|frontend-controls|camera-quality)" /tmp/printerdata-check/printer.cfg 2>/dev/null; then
		echo "MISS packaged printer.cfg seed still includes SimpleAF/GuppyScreen files"
	else
		echo "OK   packaged printer.cfg seed contains no SimpleAF/GuppyScreen includes"
	fi
fi
# Blank-option check on the seed's printer.cfg and moonraker.conf.
# "gcode:" is excluded - gcode_macro's gcode option is allowed to be blank
# (a variable-only macro). Keep in sync with 04-cross-compile-app-stack.sh.
cat > /tmp/blank-required-option.awk <<'AWKPROG'
{
	if (pending != "") {
		if ($0 !~ /^[ \t]/) { print pending; exit 1 }
		pending = ""
	}
	if ($0 ~ /^[a-zA-Z_][a-zA-Z0-9_]*:[[:space:]]*$/ && $0 !~ /^gcode:[[:space:]]*$/) { pending = $0 }
}
END { if (pending != "") { print pending; exit 1 } }
AWKPROG
blank_required_option() {
	awk -f /tmp/blank-required-option.awk "$1"
}
blank_found=0
for f in /tmp/printerdata-check/printer.cfg /tmp/printerdata-check/moonraker.conf; do
	[ -s "$f" ] || continue
	if ! blank_required_option "$f" >/dev/null; then
		blank_found=1
	fi
done
if [ "$blank_found" = "1" ]; then
	echo "MISS packaged printer.cfg/moonraker.conf seed has an option present but syntactically blank"
else
	echo "OK   packaged printer.cfg/moonraker.conf seed has no syntactically blank options"
fi

# Print-control config closure validation against the actual packaged
# image. Phase 2: all 10 included configs live at /etc/nebulaos/klipper/
# (absolute includes resolved against the rootfs). Concatenate them to
# verify the closure has exactly one of each required section.
if [ -s /tmp/printerdata-check/printer.cfg ]; then
	: > /tmp/printerdata-check/closure.txt
	cat /tmp/printerdata-check/printer.cfg >> /tmp/printerdata-check/closure.txt
	for cfg_name in platform.cfg machine.cfg prtouch.cfg z_offset_probe.cfg calibration.cfg homing.cfg print.cfg filament.cfg camera.cfg beeper.cfg; do
		debugfs -R "cat /etc/nebulaos/klipper/$cfg_name" ${IMAGES}/rootfs.ext2 2>/dev/null >> /tmp/printerdata-check/closure.txt
	done
	vsd_count=$(grep -c -i -E "^\[[[:space:]]*virtual_sdcard[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	pr_count=$(grep -c -i -E "^\[[[:space:]]*pause_resume[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	ds_count=$(grep -c -i -E "^\[[[:space:]]*display_status[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	pause_macro_count=$(grep -c -i -E "^\[[[:space:]]*gcode_macro[[:space:]]+pause[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	resume_macro_count=$(grep -c -i -E "^\[[[:space:]]*gcode_macro[[:space:]]+resume[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	cancel_macro_count=$(grep -c -i -E "^\[[[:space:]]*gcode_macro[[:space:]]+cancel_print[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	closure_ok=1
	if [ "$vsd_count" != "1" ]; then echo "MISS packaged config closure has $vsd_count [virtual_sdcard] sections, need exactly 1"; closure_ok=0; fi
	if [ "$pr_count" != "1" ]; then echo "MISS packaged config closure has $pr_count [pause_resume] sections, need exactly 1"; closure_ok=0; fi
	if [ "$ds_count" != "1" ]; then echo "MISS packaged config closure has $ds_count [display_status] sections, need exactly 1"; closure_ok=0; fi
	if [ "$pause_macro_count" != "1" ]; then echo "MISS packaged config closure has $pause_macro_count [gcode_macro PAUSE] sections, need exactly 1"; closure_ok=0; fi
	if [ "$resume_macro_count" != "1" ]; then echo "MISS packaged config closure has $resume_macro_count [gcode_macro RESUME] sections, need exactly 1"; closure_ok=0; fi
	if [ "$cancel_macro_count" != "1" ]; then echo "MISS packaged config closure has $cancel_macro_count [gcode_macro CANCEL_PRINT] sections, need exactly 1"; closure_ok=0; fi
	if [ "$closure_ok" = "1" ]; then
		echo "OK   packaged config closure has exactly one each of virtual_sdcard/pause_resume/display_status/gcode_macro PAUSE/gcode_macro RESUME/gcode_macro CANCEL_PRINT"
	fi
	cat > /tmp/vsd-path-extract.awk <<'AWKPROG2'
/^\[[[:space:]]*virtual_sdcard[[:space:]]*\]/ { in_vsd = 1; next }
/^\[/ { in_vsd = 0 }
in_vsd && /^[[:space:]]*path[[:space:]]*:/ {
	sub(/^[[:space:]]*path[[:space:]]*:[[:space:]]*/, "")
	gsub(/[[:space:]]+$/, "")
	print
	exit
}
AWKPROG2
	vsd_path=$(awk -f /tmp/vsd-path-extract.awk /tmp/printerdata-check/closure.txt)
	if [ "$vsd_path" = "/opt/printer_data/gcodes" ]; then
		echo "OK   packaged [virtual_sdcard] path is the canonical /opt/printer_data/gcodes"
	else
		echo "MISS packaged [virtual_sdcard] path is $vsd_path, expected /opt/printer_data/gcodes"
	fi
	# Phase 2 RC architecture checks against the built config closure.
	fan_count=$(grep -c -i -E "^\[[[:space:]]*fan[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	output_pin_fan0=$(grep -c -i -E "^\[[[:space:]]*output_pin[[:space:]]+fan0[[:space:]]*\]" /tmp/printerdata-check/closure.txt || true)
	if [ "$fan_count" = "1" ] && [ "$output_pin_fan0" = "0" ]; then
		echo "OK   upstream [fan] section present, no [output_pin fan0]"
	else
		echo "MISS fan config: [fan]=$fan_count [output_pin fan0]=$output_pin_fan0 (expect 1/0)"
	fi
	if grep -qE "shaper_freq_end:[[:space:]]*80" /tmp/printerdata-check/closure.txt \
	   && grep -qE "shaper_accel_per_hz:[[:space:]]*50" /tmp/printerdata-check/closure.txt; then
		echo "OK   Input Shaper envelope 80/50 present in calibration config"
	else
		echo "MISS Input Shaper envelope 80/50 not found in config closure"
	fi
	custom_m109=$(grep -c -i -E "^\[[[:space:]]*gcode_macro[[:space:]]+m109[[:space:]]*\]" /tmp/printerdata-check/closure.txt || true)
	custom_m190=$(grep -c -i -E "^\[[[:space:]]*gcode_macro[[:space:]]+m190[[:space:]]*\]" /tmp/printerdata-check/closure.txt || true)
	_filament_cfg_m109=0; _filament_cfg_m190=0
	_filament_src="$REPO_ROOT/scripts/build/overlay/etc/nebulaos/klipper/filament.cfg"
	if [ -f "$_filament_src" ]; then
		_filament_cfg_m109=$(grep -c -i -E "^\[[[:space:]]*gcode_macro[[:space:]]+m109[[:space:]]*\]" "$_filament_src" || true)
		_filament_cfg_m190=$(grep -c -i -E "^\[[[:space:]]*gcode_macro[[:space:]]+m190[[:space:]]*\]" "$_filament_src" || true)
	fi
	if [ "$custom_m109" = "1" ] && [ "$custom_m190" = "1" ] \
	   && [ "$_filament_cfg_m109" = "1" ] && [ "$_filament_cfg_m190" = "1" ] \
	   && grep -qi "rename_existing.*m109" "$_filament_src" 2>/dev/null \
	   && grep -qi "rename_existing.*m190" "$_filament_src" 2>/dev/null \
	   && grep -qi "TEMPERATURE_WAIT" "$_filament_src" 2>/dev/null; then
		echo "OK   NebulaOS M109/M190 fast-wait overrides: exactly 1/1 in filament.cfg (rename_existing + TEMPERATURE_WAIT)"
	elif [ "$custom_m109" = "0" ] && [ "$custom_m190" = "0" ]; then
		echo "MISS M109/M190 fast-wait overrides missing from config closure (expect 1/1 in filament.cfg)"
	else
		echo "MISS M109=$custom_m109 M190=$custom_m190 overrides: unexpected count or source (expect exactly 1/1 from filament.cfg with rename_existing + TEMPERATURE_WAIT)"
	fi
	if grep -q "^\[nebulaos_calibration\]" /tmp/printerdata-check/closure.txt; then
		echo "OK   [nebulaos_calibration] section present"
	else
		echo "MISS [nebulaos_calibration] section not found in config closure"
	fi
	nebulaos_plr=$(grep -c -i -E "^\[[[:space:]]*nebulaos_power_loss_recovery[[:space:]]*\]" /tmp/printerdata-check/closure.txt)
	if [ "$nebulaos_plr" = "1" ]; then
		echo "OK   [nebulaos_power_loss_recovery] section present"
	else
		echo "MISS [nebulaos_power_loss_recovery] not found in config closure"
	fi
else
	echo "MISS packaged printer.cfg could not be dumped from rootfs.ext2 - cannot validate print-control closure"
fi
rm -rf /tmp/printerdata-check
# Confirms the actual fix logic landed in the packaged init scripts, not
# just the seed content sitting there unused.
S02_CONTENT=$(debugfs -R "cat /etc/init.d/S02nebulaos-namespace" ${IMAGES}/rootfs.ext2 2>/dev/null)
if echo "$S02_CONTENT" | grep -q "seed_printer_data_config"; then
	echo "OK   S02nebulaos-namespace contains the printer_data config seeding logic"
else
	echo "MISS S02nebulaos-namespace is missing the printer_data config seeding logic"
fi
S05_CONTENT=$(debugfs -R "cat /etc/init.d/S05nebulaos-activate" ${IMAGES}/rootfs.ext2 2>/dev/null)
if echo "$S05_CONTENT" | grep -q "config/printer.cfg"; then
	echo "OK   S05nebulaos-activate validates printer_data against the real required files, not just the config directory"
else
	echo "MISS S05nebulaos-activate still validates printer_data against only the config directory - a wiped copy would pass validation empty"
fi

echo "=== obsolete overlay files (must be absent - Buildroots output/target copy is additive-only, see 02-configure-buildroot.sh) ==="
# Real bug found live 2026-07-28: a renamed overlay file (e.g.
# S03nebulaos-factory-seed/S04nebulaos-activate -> S04nebulaos-factory-seed/
# S05nebulaos-activate) leaves the OLD file sitting in Buildroots own
# output/target/ forever unless explicitly cleaned - and it ships in the
# real rootfs right alongside the new one. This is not cosmetic: the old,
# pre-fix activation script sorts earlier and silently wins over the new
# one whenever both are present. rootfs.ext2 and rootfs.squashfs are built
# from the same stale output/target/, so debugfs against rootfs.ext2 here
# does catch a real leftover, not just the tracked overlay source.
# check_absent() is defined once, earlier, right after check() (both used
# from the very first section in this docker block).
check_absent /etc/init.d/S01tmpfs-datastore
check_absent /etc/init.d/S39wifi
check_absent /etc/init.d/S03nebulaos-factory-seed
check_absent /etc/init.d/S04nebulaos-activate

echo "=== SSH/console/recovery (FIRMWARE.md sec 18/21/22/24) ==="
check /usr/sbin/dropbear
check /usr/sbin/wpa_cli
check /etc/init.d/S00revert-safety
check /etc/init.d/S01persistent-datastore
check /etc/init.d/S01wifi
check /etc/nebulaos-stable-mac.sh
check /etc/nebulaos-wifi-power-save.sh
check /usr/libexec/nebulaos-wifi-power-save
check /etc/nebulaos-wifi-boot-wait.sh
check /etc/init.d/S99confirm-good
check /etc/ota_marker.sh
# RESTORED 2026-09-24 after architecture review. This was `check` until
# 8889ef0e (2026-09-05) flipped it in place, in the same commit that wrongly
# deleted the file - so the check_absent never guarded anything on its own, it
# mirrored a deletion that was itself the bug. 40a9ff61 (2026-09-10) restored
# the file and added the seeds-side assertion above, but missed flipping this
# line back.
#
# The image copy is NOT stale pre-population: S01persistent-datastore runs
# seed_once /opt/printer_data BEFORE its bind mount, so this file is the actual
# first-boot materialization source, and stage 04 copies this same overlay tree
# to build /opt/nebulaos-seeds. Asserting absence here and presence there is
# unsatisfiable by construction. Restored as `check` rather than deleted,
# because the seeds-side assertion alone would leave the more load-bearing copy
# unasserted.
check /opt/printer_data/config/GuppyScreen/scripts/static_ip.py

echo "=== NebulaOS memory resilience (docs/NEBULAOS_MEMORY_RESILIENCE.md) ==="
check /sbin/mkswap
check /sbin/swapon
check /sbin/swapoff
check /usr/bin/free
check /etc/init.d/S00zram-swap
check /etc/init.d/S03nebulaos-diskswap
check /etc/init.d/S02nebulaos-namespace
check /etc/init.d/S02nebulaos-boot-timing
check /etc/init.d/S04nebulaos-factory-seed
check /etc/init.d/S05nebulaos-activate
check /etc/init.d/S45nebulaos-cleanup
check /etc/nebulaos-retention.sh
check /etc/nebulaos-healthcheck.sh
check /opt/nebulaos-seeds/klipper.tar.gz
check /opt/nebulaos-seeds/moonraker.tar.gz
# The seed manifest is only useful if the reader that parses it also ships:
# S04nebulaos-factory-seed and S04nebulaos-migrate source this library to
# derive the extensions branch assertion (audit F-06), and they source it
# TOLERANTLY so a missing library cannot abort four unrelated migrations.
#
# Until 2026-09-23 the comment here claimed that tolerance "is only safe if
# 'missing from the image' is impossible, which is what this check makes
# true". It made nothing true: check() printed MISS and set nothing, and this
# script had no aggregation and no non-zero exit. That was a false claim in
# tracked source, and it is D-02.
#
# It is check_required now, and it is the one path that meets both halves of
# that bar. Absence is permanent and invisible: the library is what defines
# seed_manifest_branch(), so without it the extensions branch is underivable
# on every boot forever, and the device silently stops updating extensions.
# And it cannot legitimately be missing from a partial build - it is a tracked
# overlay file that 02-configure-buildroot.sh:112 copies wholesale, so it is
# present in any image that has an overlay at all.
check_required /etc/nebulaos-seed-manifest.sh "seed_manifest_branch() lives here; without it the extensions branch is underivable on every boot (S04nebulaos-migrate:186-194)"
# Deliberately NOT required: seed-manifest.json is generated by stage 04
# (04-cross-compile-app-stack.sh:984), so a 03-only verify legitimately lacks
# it. Promoting it would break a documented partial pipeline. Its absence is
# also handled fail-closed at runtime by the migration precondition gate.
check /opt/nebulaos-seeds/seed-manifest.json
check /usr/sbin/ntpd
check /etc/init.d/S40nebulaos-ntpsync
check /etc/nebulaos-update-supervisor.sh
check /etc/init.d/S59nebulaos-update-supervisor

# Phase 7 live qualification: Moonraker machine.py needs real iproute2
# JSON output (`ip -json -det address`), which BusyBox ip cannot produce
# at all (confirmed live). /sbin/ip must be the real iproute2 ELF binary,
# not still the busybox multi-call symlink - debugfs stat prints
# "Fast link dest" only for symlinks, so its presence (and pointing at
# busybox) is what would indicate the fix did not take.
check /sbin/ip
stat_out=$(debugfs -R "stat /sbin/ip" ${IMAGES}/rootfs.ext2 2>&1)
case "$stat_out" in
	*"Fast link dest"*busybox*)
		echo "MISS /sbin/ip is still the busybox applet symlink"
		;;
	*)
		echo "OK   /sbin/ip is a real binary, not the busybox symlink"
		;;
esac

echo "=== architecture spot-checks (host objdump has no MIPS backend - a future check here would use the Buildroot-generated mipsel-buildroot-linux-gnu-objdump, per Phase 11's unified-container migration; pellcorp/k1-bash-build is retired) ==="
# Production optimization mission, Phase 9 (2026-07-30): this used to spot-
# check hci_uart.ko's architecture - the only loadable kernel module this
# image ever shipped. Bluetooth is now removed entirely (CONFIG_BT is not
# set - see the kernel-modules section above), and nothing else in this
# kernel is built as a loadable module (confirmed live: `lsmod` on the real
# device shows nothing loaded), so there is currently nothing left here to
# spot-check. Left as an empty, documented section rather than deleted
# outright, so a future loadable module addition has an obvious place to
# add its own check back.

echo "== xImage/uImage terminology check =="
# FIRMWARE.md sec 31 ("REAL BOOT SUCCESS..."): this project's kernel image
# was called "uImage" in early docs/scripts by convention/habit, but the
# real built file is (and has always been) named xImage, and its header
# does NOT match a standard U-Boot legacy "uImage" (compressed vmlinux.bin)
# layout - see FIRMWARE.md sec 29-31's root-cause trace and the "Correction"
# note. scripts/build/README.md had a genuinely stale "uImage" reference
# from before that correction, found and fixed 2026-08-14/15. This check
# exists so a future doc/script edit that reintroduces "uImage" as the name
# of the actual build artifact gets caught here rather than silently
# drifting back out of sync with what 05-final-build.sh actually produces
# (xImage, see IMAGES/xImage and artifacts/buildroot-halley5-v30-image/
# xImage above).
if [ -f "$IMAGES/xImage" ]; then
	echo "PASS $IMAGES/xImage exists (correct artifact name)"
else
	echo "MISS $IMAGES/xImage not found - run 05-final-build.sh first"
fi
if [ -f "$IMAGES/uImage" ]; then
	echo "MISS $IMAGES/uImage exists - this project's kernel image is xImage, not uImage (see FIRMWARE.md sec 29-31); a stray uImage here means something built the wrong target"
fi
# Deliberately not grepping docs/ for stray "uImage" text here: docs/HISTORY.md
# and FIRMWARE.md are append-only dated journals that correctly say "uImage"
# in entries written before the sec 29-31 naming correction - a mechanical
# grep can't tell historical record from stale current claim, and got this
# wrong on a first pass (flagged docs/HISTORY.md's legitimate history as a
# MISS). That distinction needs a human read, which is how scripts/build/
# README.md's real stale reference was actually found and fixed
# (2026-08-14/15) - not something to re-attempt here.

echo "=== MCU restore candidate artifact (Phase 1.8B, docs/MCU_LIFECYCLE_GUARD.md) ==="
# mcu_restore.py's default MCU_CANDIDATE_PATH. Build-time validation per
# MCU_LIFECYCLE_GUARD.md's "runtime validation split": the on-device
# arm-none-eabi-readelf-dependent ELF/target validation already happened
# once, in NebulaOS-klipper-mcu's CI (candidate-001.txt's
# OFFLINE_VALIDATOR_TARGET_RECHECK=PASS) - this check only re-confirms the
# packaged artifact that actually landed in this rootfs is byte-identical
# to that already-validated one, via SHA256, so mcu_restore.py never needs
# the toolchain on-device.
check /opt/nebulaos/mcu-candidates/candidate-001.bin
MCU_CANDIDATE_EXPECTED_SHA256="c2db4f34586c5df88b0d8d40e1d2d1c0f3bea90ab879c7c3a1ccc3a64f91db0c"
MCU_CANDIDATE_EXTRACT="$(mktemp)"
if debugfs -R "dump /opt/nebulaos/mcu-candidates/candidate-001.bin ${MCU_CANDIDATE_EXTRACT}" ${IMAGES}/rootfs.ext2 >/dev/null 2>&1; then
	MCU_CANDIDATE_ACTUAL_SHA256=$(sha256sum "${MCU_CANDIDATE_EXTRACT}" | cut -d' ' -f1)
	if [ "$MCU_CANDIDATE_ACTUAL_SHA256" = "$MCU_CANDIDATE_EXPECTED_SHA256" ]; then
		echo "OK   candidate-001.bin SHA256 matches pinned value ($MCU_CANDIDATE_EXPECTED_SHA256)"
	else
		echo "MISS candidate-001.bin SHA256 mismatch: expected $MCU_CANDIDATE_EXPECTED_SHA256, got $MCU_CANDIDATE_ACTUAL_SHA256"
	fi
else
	echo "MISS could not extract /opt/nebulaos/mcu-candidates/candidate-001.bin from rootfs.ext2 for hash verification"
fi
rm -f "${MCU_CANDIDATE_EXTRACT}"
check /etc/nebulaos/mcu_lifecycle.py
check /etc/nebulaos/mcu_restore.py
check /etc/nebulaos/mcu_application_identify.py
check /etc/nebulaos/mcu_known_identities.py
check /etc/nebulaos/mcu_restart.py
check /etc/init.d/S50nebulaos-mcu-guard

# CREALITY_FLASH_PATH runtime dependency (Phase 1.8B hardware qualification,
# Gate 1 failure, 2026-08-28): mcu_lifecycle.decide()/mcu_restore.restore()'s
# fallback branches (used whenever no mock is injected - i.e. always, in
# production) do `import creality_flash` after inserting CREALITY_FLASH_PATH
# (default /opt/nebulaos/tools) onto sys.path. This file previously was not
# part of the overlay at all - the guard crashed with ModuleNotFoundError on
# its very first real boot, before ever classifying the MCU or attempting a
# restore, because every offline unit test always injects a mock
# creality_flash_module and so never exercises this real import path. A
# presence check alone would not have caught a future path/API drift, so this
# also does a real import of the extracted files below.
check /opt/nebulaos/tools/creality_flash.py
check /opt/nebulaos/tools/creality_validator.py

# Phase 1.9B: plr_tombstone.py (stock-switch PLR journal tombstone, invoked
# from ota_marker.sh's write_ota_marker()) - real execution smoke test
# against a temp-file EEPROM standing in for the real device, extracting
# both this tool and the composed nebulaos_plr_journal.py it imports at
# runtime from the built image (not the source checkout) so this check
# actually validates what will run on real hardware.
check /opt/nebulaos/tools/plr_tombstone.py
PLR_SMOKE_DIR="$(mktemp -d)"
if debugfs -R "dump /opt/nebulaos/tools/plr_tombstone.py ${PLR_SMOKE_DIR}/plr_tombstone.py" ${IMAGES}/rootfs.ext2 >/dev/null 2>&1 \
	&& debugfs -R "dump /opt/klipper/klippy/extras/nebulaos_plr_journal.py ${PLR_SMOKE_DIR}/nebulaos_plr_journal.py" ${IMAGES}/rootfs.ext2 >/dev/null 2>&1; then
	PLR_SMOKE_RESULT=$(python3 - "$PLR_SMOKE_DIR" <<'PYEOF'
import sys, os, importlib.util
d = sys.argv[1]
spec = importlib.util.spec_from_file_location("plr_tombstone", os.path.join(d, "plr_tombstone.py"))
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)
tool._JOURNAL_MODULE_CANDIDATES = [os.path.join(d, "nebulaos_plr_journal.py")]
journal = tool._load_journal_module()
if journal is None:
	print("FAIL: could not load composed nebulaos_plr_journal.py")
	sys.exit(0)
eeprom_path = os.path.join(d, "eeprom")
with open(eeprom_path, "wb") as f:
	f.write(bytes([0xFF]) * journal.EEPROM_TOTAL_SIZE)
with open(eeprom_path, "r+b") as f:
	journal.commit_checkpoint(f, 1)
rc = tool.main(["--eeprom-path", eeprom_path])
with open(eeprom_path, "r+b") as f:
	recovery = journal.read_recovery_state(f)
print("RESULT=OK" if rc == 0 and recovery is None else "RESULT=FAIL rc=%r recovery=%r" % (rc, recovery))
PYEOF
)
	# tool.main() prints its own progress lines (e.g. "committed
	# TOMBSTONE...") to stdout before this script's own RESULT= line, so
	# match on that specific marker rather than the whole captured
	# output.
	if echo "$PLR_SMOKE_RESULT" | grep -q "^RESULT=OK$"; then
		echo "OK   plr_tombstone.py real execution smoke test (extracted from built image, temp-file EEPROM)"
	else
		echo "MISS plr_tombstone.py smoke test failed: $PLR_SMOKE_RESULT"
	fi
else
	echo "MISS could not extract plr_tombstone.py / nebulaos_plr_journal.py from the built image for the smoke test"
fi
rm -rf "$PLR_SMOKE_DIR"

# GUI/service readiness mission (2026-10-09): the OS-settings layer behind
# Moonraker's [nebulaos] component, mDNS, SFTP, Moonraker reboot/shutdown,
# userspace boot display and runtime backlight control. Reporting checks: a
# MISS means a GUI-facing OS feature is unavailable, not that the printer
# cannot boot, print or update - below the check_required bar above.
echo "=== GUI/service readiness: OS settings layer ==="
check /usr/bin/sudo
check /usr/libexec/sftp-server
check /usr/libexec/gesftpserver
check /usr/libexec/nebulaos/nebulaos-osconfig
check /usr/libexec/nebulaos/nebulaos-netapply
check /usr/libexec/nebulaos/nebulaos-backlight
check /usr/libexec/nebulaos/nebulaos-boot-display
check /usr/lib/nebulaos/python/nebulaos_osconfig/cli.py
check /usr/lib/nebulaos/python/nebulaos_osconfig/network.py
check /usr/lib/nebulaos/python/nebulaos_osconfig/display.py
check /usr/lib/nebulaos/python/nebulaos_osconfig/bootdisplay.py
check /usr/lib/nebulaos/moonraker/nebulaos.py
check /opt/moonraker/moonraker/components/nebulaos.py
check /etc/nebulaos/moonraker/nebulaos.conf
check /etc/nebulaos-network.sh
check /etc/nebulaos-backlight.sh
check /etc/init.d/S01splash
if debugfs -R "cat /etc/nebulaos/moonraker/klipper-pin.conf" ${IMAGES}/rootfs.ext2 2>/dev/null \
	| grep -qx '\[include /etc/nebulaos/moonraker/nebulaos.conf\]'; then
	echo "OK   klipper-pin.conf chains the nebulaos.conf include"
else
	echo "MISS klipper-pin.conf does not include /etc/nebulaos/moonraker/nebulaos.conf ([nebulaos]/[zeroconf] not loaded)"
fi

echo "=== MCU lifecycle import-chain smoke test (extracted files, real import, no mocks) ==="
MCU_SMOKE_DIR="$(mktemp -d)"
MCU_SMOKE_OK=1
for f in mcu_lifecycle.py:/etc/nebulaos/mcu_lifecycle.py \
         mcu_restore.py:/etc/nebulaos/mcu_restore.py \
         mcu_application_identify.py:/etc/nebulaos/mcu_application_identify.py \
         mcu_known_identities.py:/etc/nebulaos/mcu_known_identities.py \
         mcu_restart.py:/etc/nebulaos/mcu_restart.py \
         creality_flash.py:/opt/nebulaos/tools/creality_flash.py \
         creality_validator.py:/opt/nebulaos/tools/creality_validator.py; do
	dest_name="${f%%:*}"
	rootfs_path="${f#*:}"
	if ! debugfs -R "dump $rootfs_path ${MCU_SMOKE_DIR}/${dest_name}" ${IMAGES}/rootfs.ext2 >/dev/null 2>&1; then
		echo "MISS could not extract $rootfs_path for import smoke test"
		MCU_SMOKE_OK=0
	fi
done
if [ "$MCU_SMOKE_OK" -eq 1 ]; then
	# Plain `import mcu_lifecycle` would NOT catch this class of bug: the
	# `import creality_flash` line is deferred inside decide()'s fallback
	# branch (taken whenever no mock is injected - i.e. always, in
	# production), not at module load time. So this actually calls
	# decide() with no mocks, exactly as the init.d guard does, using a
	# stubbed application_identify_fn so no real serial hardware/MCU is
	# needed on the x86 build host - the point is to force execution
	# through the real `import creality_flash` line and the real
	# SerialTransport construction (which fails closed to UNREACHABLE on
	# a build host with no /dev/ttyS1, exactly like a genuinely
	# disconnected MCU would). mcu_restore.restore() has an identical
	# lazy-import block for the same module, so a successful decide()
	# call here is direct evidence that pattern resolves correctly too.
	if python3 -c "
import sys
sys.path.insert(0, '${MCU_SMOKE_DIR}')
import mcu_lifecycle
import mcu_restart

def fake_identify(port, baud):
    raise RuntimeError('no MCU on build host - expected, forces the fallback path')

decision = mcu_lifecycle.decide(application_identify_fn=fake_identify)
assert decision.state == mcu_lifecycle.MCU_UNREACHABLE, decision.state

# Phase 1.8B Option C (candidate-002): mcu_restart.request_generic_restart()
# must also import and run cleanly with no real hardware present - it
# should fail closed with RestartRequestError (no /dev/ttyS1 on the build
# host), never raise an unrelated/unexpected exception or hang.
try:
    mcu_restart.request_generic_restart('/dev/ttyS1', 230400, timeout=1.0)
    raise SystemExit('expected RestartRequestError on a build host with no MCU')
except mcu_restart.RestartRequestError:
    pass

print('IMPORT_CHAIN_OK')
" 2>&1 | tee "${MCU_SMOKE_DIR}/smoke.log" | grep -q "IMPORT_CHAIN_OK"; then
		echo "OK   mcu_lifecycle.decide()/mcu_restart.request_generic_restart()'s real (non-mocked) import paths resolve cleanly"
	else
		echo "MISS import chain failed - see detail below (this is exactly the failure mode that crashed the guard on first real boot before this check existed)"
		cat "${MCU_SMOKE_DIR}/smoke.log"
	fi
fi
rm -rf "${MCU_SMOKE_DIR}"

echo "=== Phase 2 final software closure (2026-09-09) ==="

# --- Guppy-only backend adapters absent (section 2A) ---------------------
CALIBRATION_CFG_CONTENT=$(debugfs -R "cat /etc/nebulaos/klipper/calibration.cfg" ${IMAGES}/rootfs.ext2 2>/dev/null)
if [ -n "$CALIBRATION_CFG_CONTENT" ]; then
	if echo "$CALIBRATION_CFG_CONTENT" | grep -qxF '[gcode_macro Z_OFFSET_CALIBRATION]' \
		|| echo "$CALIBRATION_CFG_CONTENT" | grep -qxF '[gcode_macro CRTENSE_NOZZLE_CLEAR]'; then
		echo "MISS calibration.cfg still contains a GuppyScreen-only backend adapter (Z_OFFSET_CALIBRATION or CRTENSE_NOZZLE_CLEAR)"
	else
		echo "OK   no GuppyScreen-only backend adapters in calibration.cfg"
	fi
	if echo "$CALIBRATION_CFG_CONTENT" | grep -qxF '[gcode_macro NEBULAOS_Z_OFFSET_CALIBRATE]' \
		&& echo "$CALIBRATION_CFG_CONTENT" | grep -qxF '[gcode_macro NEBULAOS_NOZZLE_CLEAN]'; then
		echo "OK   canonical NEBULAOS_Z_OFFSET_CALIBRATE/NEBULAOS_NOZZLE_CLEAN present"
	else
		echo "MISS canonical NEBULAOS_Z_OFFSET_CALIBRATE/NEBULAOS_NOZZLE_CLEAN missing from calibration.cfg"
	fi
else
	echo "MISS could not read /etc/nebulaos/klipper/calibration.cfg from the built image"
fi

# --- Extensions updater configured validly (section 2B) -------------------
if [ -n "$KLIPPER_PIN_CONF_CONTENT" ]; then
	if echo "$KLIPPER_PIN_CONF_CONTENT" | grep -qxF 'primary_branch: production'; then
		echo "OK   klipper-pin.conf: nebulaos_klipper_extensions primary_branch is 'production', not 'main'"
	else
		echo "MISS klipper-pin.conf: nebulaos_klipper_extensions primary_branch is not 'production'"
	fi
else
	echo "MISS could not read klipper-pin.conf from the built image"
fi

# --- Backup cleanup installed (section 2D) --------------------------------
RETENTION_CONTENT=$(debugfs -R "cat /etc/nebulaos-retention.sh" ${IMAGES}/rootfs.ext2 2>/dev/null)
if [ -n "$RETENTION_CONTENT" ]; then
	for fn in clean_migration_backups clean_mainsail_namespace_backups clean_stray_bak_files; do
		if echo "$RETENTION_CONTENT" | grep -q "^${fn}()"; then
			echo "OK   nebulaos-retention.sh defines $fn"
		else
			echo "MISS nebulaos-retention.sh is missing $fn"
		fi
	done
else
	echo "MISS could not read /etc/nebulaos-retention.sh from the built image"
fi

# --- Config materialization machinery installed (sections 3-6) -----------
check /etc/nebulaos/config-materialize.sh
CONFIG_MANIFEST_CONTENT=$(debugfs -R "cat /etc/nebulaos/klipper/.manifest.json" ${IMAGES}/rootfs.ext2 2>/dev/null)
if [ -n "$CONFIG_MANIFEST_CONTENT" ] && echo "$CONFIG_MANIFEST_CONTENT" | grep -q '"generation"[[:space:]]*:[[:space:]]*"[0-9a-f]\{64\}"'; then
	echo "OK   /etc/nebulaos/klipper/.manifest.json has a valid generation hash"
else
	echo "MISS /etc/nebulaos/klipper/.manifest.json missing or has no valid generation hash"
fi
if [ -n "$CONFIG_MANIFEST_CONTENT" ]; then
	_manifest_files_ok=1
	for cfg_name in platform.cfg machine.cfg prtouch.cfg z_offset_probe.cfg calibration.cfg homing.cfg print.cfg filament.cfg camera.cfg beeper.cfg; do
		echo "$CONFIG_MANIFEST_CONTENT" | grep -q "\"$cfg_name\"" || _manifest_files_ok=0
	done
	if [ "$_manifest_files_ok" = "1" ]; then
		echo "OK   /etc/nebulaos/klipper/.manifest.json lists all ten managed config files"
	else
		echo "MISS /etc/nebulaos/klipper/.manifest.json is missing one or more of the ten managed config files"
	fi
fi

S04_MIGRATE_CONTENT=$(debugfs -R "cat /etc/init.d/S04nebulaos-migrate" ${IMAGES}/rootfs.ext2 2>/dev/null)
if [ -n "$S04_MIGRATE_CONTENT" ]; then
	for fn in materialize_active_config migrate_printer_cfg_to_managed_tree; do
		if echo "$S04_MIGRATE_CONTENT" | grep -q "^${fn}()"; then
			echo "OK   S04nebulaos-migrate defines $fn"
		else
			echo "MISS S04nebulaos-migrate is missing $fn"
		fi
	done
	if echo "$S04_MIGRATE_CONTENT" | grep -qF 'materialize_active_config' \
		&& echo "$S04_MIGRATE_CONTENT" | grep -qF 'migrate_printer_cfg_to_managed_tree'; then
		_materialize_line=$(echo "$S04_MIGRATE_CONTENT" | grep -n '^	materialize_active_config$' | head -1 | cut -d: -f1)
		_managed_tree_line=$(echo "$S04_MIGRATE_CONTENT" | grep -n '^	migrate_printer_cfg_to_managed_tree$' | head -1 | cut -d: -f1)
		if [ -n "$_materialize_line" ] && [ -n "$_managed_tree_line" ] && [ "$_materialize_line" -lt "$_managed_tree_line" ]; then
			echo "OK   S04nebulaos-migrate calls materialize_active_config before migrate_printer_cfg_to_managed_tree"
		else
			echo "MISS S04nebulaos-migrate does not call materialize_active_config before migrate_printer_cfg_to_managed_tree"
		fi
	fi
	if echo "$S04_MIGRATE_CONTENT" | grep -qF 'mkdir -p "$PRINTER_DATA_CONFIG/macros"'; then
		echo "OK   migrate_printer_cfg_to_managed_tree creates the macros/ directory"
	else
		echo "MISS migrate_printer_cfg_to_managed_tree does not create the macros/ directory"
	fi
else
	echo "MISS could not read /etc/init.d/S04nebulaos-migrate from the built image"
fi

# --- nebulaos-recover config installed (section 12) -----------------------
RECOVER_CONTENT=$(debugfs -R "cat /usr/bin/nebulaos-recover" ${IMAGES}/rootfs.ext2 2>/dev/null)
if [ -n "$RECOVER_CONTENT" ]; then
	if echo "$RECOVER_CONTENT" | grep -q "^cmd_config()" && echo "$RECOVER_CONTENT" | grep -qE '^[[:space:]]*config\)'; then
		echo "OK   nebulaos-recover has a working 'config' subcommand"
	else
		echo "MISS nebulaos-recover is missing the 'config' subcommand"
	fi
else
	echo "MISS could not read /usr/bin/nebulaos-recover from the built image"
fi

# --- macros/ and guppyscreen/ and firmware/mcu/ (sections 7-9) -----------
if [ -n "$S01_CONTENT" ]; then
	if echo "$S01_CONTENT" | grep -qF 'mount --bind "$GUPPY_STATE/guppyconfig.json" "$PDATA/config/guppyscreen/guppyconfig.json"'; then
		echo "OK   S01persistent-datastore exposes guppyconfig.json under printer_data/config/guppyscreen/"
	else
		echo "MISS S01persistent-datastore does not expose guppyconfig.json under printer_data/config/guppyscreen/"
	fi
	if echo "$S01_CONTENT" | grep -qF 'mkdir -p "$PDATA/config/firmware/mcu"'; then
		echo "OK   S01persistent-datastore creates printer_data/config/firmware/mcu/"
	else
		echo "MISS S01persistent-datastore does not create printer_data/config/firmware/mcu/"
	fi
else
	echo "MISS could not read /etc/init.d/S01persistent-datastore from the built image"
fi

NEBULAOS_MCU_CONTENT=$(debugfs -R "cat /usr/bin/nebulaos-mcu" ${IMAGES}/rootfs.ext2 2>/dev/null)
if [ -n "$NEBULAOS_MCU_CONTENT" ]; then
	if echo "$NEBULAOS_MCU_CONTENT" | grep -qF 'MCU_UPLOAD_DIR="${MCU_UPLOAD_DIR:-/opt/printer_data/config/firmware/mcu}"'; then
		echo "OK   nebulaos-mcu flash resolves bare filenames against printer_data/config/firmware/mcu/"
	else
		echo "MISS nebulaos-mcu flash does not resolve bare filenames against printer_data/config/firmware/mcu/"
	fi
else
	echo "MISS could not read /usr/bin/nebulaos-mcu from the built image"
fi

# --- canonical calibrate_end_y = 190 (physical safety) --------------------
if [ -n "$MACHINE_CFG_CONTENT" ]; then
	if echo "$MACHINE_CFG_CONTENT" | grep -qE '^calibrate_end_y:[[:space:]]*190([[:space:]]|$)'; then
		echo "OK   machine.cfg's own axis_twist_compensation default is the safety-qualified calibrate_end_y=190"
	else
		echo "MISS machine.cfg's axis_twist_compensation calibrate_end_y is not 190"
	fi
else
	echo "MISS could not read machine.cfg from the built image"
fi

# --- canonical filament sensor = filament_sensor / !PC15 ------------------
FILAMENT_CFG_CONTENT=$(debugfs -R "cat /etc/nebulaos/klipper/filament.cfg" ${IMAGES}/rootfs.ext2 2>/dev/null)
if [ -n "$FILAMENT_CFG_CONTENT" ]; then
	_fss_count=$(echo "$FILAMENT_CFG_CONTENT" | grep -c '^\[filament_switch_sensor filament_sensor\]')
	if [ "$_fss_count" = "1" ] && echo "$FILAMENT_CFG_CONTENT" | grep -qE '^switch_pin:[[:space:]]*!PC15[[:space:]]*$'; then
		echo "OK   canonical [filament_switch_sensor filament_sensor] with switch_pin !PC15, exactly once"
	else
		echo "MISS canonical filament_sensor (switch_pin !PC15) not found exactly once (count=$_fss_count)"
	fi
else
	echo "MISS could not read filament.cfg from the built image"
fi

# --- Mainsail 5-group seeder (final schema, no obsolete input-shaper) -----
if [ -n "$SEED_MAINSAIL_MACROS_CONTENT" ]; then
	_5group_ok=1
	for g in nebulaos-calibration nebulaos-extruder nebulaos-recovery nebulaos-maintenance nebulaos-camera; do
		echo "$DEFAULT_GROUPS_BLOCK" | grep -q "\"$g\":" || _5group_ok=0
	done
	if echo "$DEFAULT_GROUPS_BLOCK" | grep -q '"nebulaos-input-shaper":'; then
		_5group_ok=0
	fi
	if [ "$_5group_ok" = "1" ]; then
		echo "OK   nebulaos-seed-mainsail-macros DEFAULT_GROUPS declares exactly the five canonical groups (no obsolete nebulaos-input-shaper)"
	else
		echo "MISS nebulaos-seed-mainsail-macros DEFAULT_GROUPS does not declare exactly the five canonical groups"
	fi
	if echo "$SEED_MAINSAIL_MACROS_CONTENT" | grep -q "^def reset_to_defaults" \
		&& echo "$SEED_MAINSAIL_MACROS_CONTENT" | grep -q "^def run_reset"; then
		echo "OK   nebulaos-seed-mainsail-macros ships reset_to_defaults/run_reset (--reset-state support)"
	else
		echo "MISS nebulaos-seed-mainsail-macros is missing reset_to_defaults/run_reset"
	fi
fi

# --- Boot/camera optimization test build (2026-10-05): read back from the image ---
echo "=== BOOT-01..09 / CAM-05 / M1 / S1-S4 in the built rootfs ==="
_img_cat() { debugfs -R "cat $1" ${IMAGES}/rootfs.ext2 2>/dev/null; }
_img_has() { # label path fixed-string [absent]
	if _img_cat "$2" | grep -qF -- "$3"; then
		[ "${4:-}" = absent ] && echo "MISS $1" || echo "OK   $1"
	else
		[ "${4:-}" = absent ] && echo "OK   $1" || echo "MISS $1"
	fi
}
if _img_cat /etc/network/interfaces | grep -v '^[[:space:]]*#' | grep -qw eth0; then
	echo "MISS BOOT-01: /etc/network/interfaces still configures eth0"
else
	echo "OK   BOOT-01: /etc/network/interfaces has no eth0 stanza"
fi
_img_has "BOOT-01: wlan0 stanza present" /etc/network/interfaces "iface wlan0 inet dhcp"
_img_has "BOOT-02: one-shot Wi-Fi selector (take_mode)" /etc/nebulaos-wifi-boot-wait.sh "nebulaos_wifi_boot_wait_take_mode()"
_img_has "BOOT-02: S01wifi records the ifup result" /etc/init.d/S01wifi "nebulaos_wifi_boot_wait_record_ifup"
_img_has "BOOT-06: S01wifi waits for wlan0" /etc/init.d/S01wifi "NEBULAOS_WLAN_WAIT_TENTHS"
_img_has "BOOT-03: venv validation stamp in the venv lib" /usr/libexec/nebulaos-venv-lib.sh "venv_validated_usable()"
_img_has "BOOT-03: S04 factory-seed fast path uses the stamp" /etc/init.d/S04nebulaos-factory-seed 'venv_validated_usable "$ENVS/klipper"'
_img_has "BOOT-04: S05 activate uses the shared stamp" /etc/init.d/S05nebulaos-activate 'venv_validated_usable "$NEBULAOS_ROOT/envs/klipper"'
_img_has "BOOT-05: S56 runs the update_manager check in the background" /etc/init.d/S56moonraker "_IN_RECOVERY=1"
_img_has "BOOT-07: migrate accepts the managed-tree printer.cfg" /etc/init.d/S04nebulaos-migrate "grep -qxF '[include nebulaos/platform.cfg]' \"\$f\" \\"
_img_has "BOOT-08: S03 enables the eMMC swap only for maintenance boots" /etc/init.d/S03nebulaos-diskswap "boot_maintenance_reason()"
_img_has "BOOT-09: rcS writes per-script timing" /etc/init.d/rcS "/run/nebulaos-boot-scripts.log"
# S3 (2026-10-05): run the shipped mode function itself - no marker must
# give C2, a "C0" marker C0.
_s3_fn=$(_img_cat /etc/nebulaos-camera-idle-controller.sh | sed -n '/^nebulaos_camera_idle_requested_mode()/,/^}/p')
_s3_tmp=$(mktemp -d)
printf 'C0\n' > "$_s3_tmp/c0"
_s3_none=$(sh -c "$_s3_fn"'
nebulaos_camera_idle_requested_mode "$1"' s3 "$_s3_tmp/absent" 2>/dev/null)
_s3_c0=$(sh -c "$_s3_fn"'
nebulaos_camera_idle_requested_mode "$1"' s3 "$_s3_tmp/c0" 2>/dev/null)
rm -rf "$_s3_tmp"
if [ "$_s3_none" = C2 ] && [ "$_s3_c0" = C0 ]; then
	echo "OK   S3: camera idle auto-pause is the default (no marker -> C2, C0 marker -> C0)"
else
	echo "MISS S3: camera idle default wrong (no marker -> '$_s3_none', C0 marker -> '$_s3_c0')"
fi
_img_has "S4: S51 stop waits for the controller loop" /etc/init.d/S51nebulaos-camera-idle-controller 'while [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do'
_img_has "S4: S51 stop clears the idle state after a successful resume" /etc/init.d/S51nebulaos-camera-idle-controller 'rm -f "${NEBULAOS_CAMERA_IDLE_STATE_FILE:-/var/run/nebulaos-camera-idle-state}"'
_img_has "M1: MCU identify budget default 15 s" /etc/nebulaos/mcu_application_identify.py "DEFAULT_APP_IDENTIFY_TIMEOUT = 15.0"
_img_has "M1: get_application_identity uses the budget" /etc/nebulaos/mcu_application_identify.py "def get_application_identity(port, baud, timeout=None, klippy_lib_path=None):"
_img_has "S1: S03 sizes the swapfile with ls -ln" /etc/init.d/S03nebulaos-diskswap 'actual_size=$(ls -ln "$SWAPFILE" 2>/dev/null | awk '"'"'{print $5}'"'"')'
_img_has "S1: S03 never reads the swapfile with wc -c" /etc/init.d/S03nebulaos-diskswap 'wc -c < "$SWAPFILE"' absent
_img_has "S2: S97 exits without a qualification_complete=1 config" /etc/init.d/S97nebulaos-display-qualified-apply 'is not qualification_complete=1 - nothing to apply'
_cam05_img=$(debugfs -R "cat /usr/bin/ustreamer" ${IMAGES}/rootfs.ext2 2>/dev/null | sha256sum | cut -d' ' -f1)
_cam05_built="$REPO_ROOT/vendor/k1-ustreamer/build/ustreamer-src/src/ustreamer.bin"
if [ -f "$_cam05_built" ] && [ "$_cam05_img" = "$(sha256sum "$_cam05_built" | cut -d' ' -f1)" ] \
	&& grep -q 'blank->jpeg_text' "$REPO_ROOT/vendor/k1-ustreamer/build/ustreamer-src/src/ustreamer/blank.c"; then
	echo "OK   CAM-05: /usr/bin/ustreamer is the binary built from the patched source ($_cam05_img)"
else
	echo "MISS CAM-05: /usr/bin/ustreamer does not match the CAM-05 patched build"
fi

# G9 phase 1 (2026-10-07): /usr/data boot check and clean shutdown. REQUIRED:
# the checker tools exist in the image, S01 runs the policy and the shutdown.
echo "=== G9 /usr/data policy ==="
_g9_ok=1
for _g9_t in e2fsck fsck.ext4 dumpe2fs; do
	_g9_found=
	for _g9_d in /sbin /usr/sbin; do debugfs -R "stat $_g9_d/$_g9_t" ${IMAGES}/rootfs.ext2 2>/dev/null | grep -q '^Inode:' && _g9_found=1; done
	[ -n "$_g9_found" ] || { echo "MISS G9: $_g9_t not in /sbin or /usr/sbin"; _g9_ok=0; }
done
_img_cat /usr/libexec/nebulaos-datafs.sh | grep -q '^ndf_precheck()' || _g9_ok=0
_img_cat /etc/init.d/S01persistent-datastore | grep -q 'ndf_shutdown' || _g9_ok=0
_img_cat /etc/init.d/S01persistent-datastore | grep -q 'ndf_precheck' || _g9_ok=0
if [ "$_g9_ok" = 1 ]; then
	echo "OK   G9: e2fsck, fsck.ext4 and dumpe2fs present; S01 runs the boot check policy and the clean shutdown"
else
	echo "MISS G9: e2fsck tools or the S01 boot check/shutdown missing from the image   <== REQUIRED"
	MISS_REQUIRED=$((MISS_REQUIRED + 1))
fi

# NG1 (2026-10-05): Buildroot's python-tornado 6.4.2 CVE-2025-67724 backport
# needs httputil._ABNF; without NebulaOS's 0004 patch every Moonraker HTTP
# error with a reason never reaches the client. REQUIRED: the patch was
# applied by Buildroot (global patch dir), the built source defines
# _ABNF.reason_phrase, the validation in web.py is still there, and the
# shipped bytecode carries both.
echo "=== NG1 python-tornado _ABNF ==="
_ng1_bd=$(ls -d "$REPO_ROOT"/vendor/buildroot-x2000/output/build/python-tornado-* 2>/dev/null | head -1)
_ng1_ok=1
grep -q '/0004-httputil-add-_ABNF-reason_phrase-for-CVE-2025-67724-backport.patch$' "$_ng1_bd/.applied_patches_list" 2>/dev/null || _ng1_ok=0
grep -q '^class _ABNF:' "$_ng1_bd/tornado/httputil.py" 2>/dev/null || _ng1_ok=0
grep -q '^    reason_phrase = re.compile(' "$_ng1_bd/tornado/httputil.py" 2>/dev/null || _ng1_ok=0
grep -q '_ABNF.reason_phrase.fullmatch' "$_ng1_bd/tornado/web.py" 2>/dev/null || _ng1_ok=0
# marshalled names carry a trailing type byte (e.g. "_ABNFz"), so match the
# name as a prefix of a strings line, not the whole line; the class docstring
# from 0004 is matched exactly.
_ng1_pyc=$(_img_cat /usr/lib/python3.12/site-packages/tornado/httputil.pyc | strings)
printf '%s\n' "$_ng1_pyc" | grep -q '^_ABNF' || _ng1_ok=0
printf '%s\n' "$_ng1_pyc" | grep -q '^reason_phrase' || _ng1_ok=0
printf '%s\n' "$_ng1_pyc" | grep -qF 'reason-phrase validation (CVE-2025-67724 backport) uses' || _ng1_ok=0
_img_cat /usr/lib/python3.12/site-packages/tornado/web.pyc | strings | grep -q '^reason_phrase' || _ng1_ok=0
if [ "$_ng1_ok" = 1 ]; then
	echo "OK   NG1: python-tornado 0004 applied; _ABNF.reason_phrase in the built source and the shipped bytecode; web.py validation intact"
else
	echo "MISS NG1: python-tornado 0004 _ABNF fix not verified in $_ng1_bd / the image   <== REQUIRED"
	MISS_REQUIRED=$((MISS_REQUIRED + 1))
fi

if [ "$MISS_REQUIRED" -gt 0 ]; then
	echo "== verification FAILED - $MISS_REQUIRED REQUIRED path(s) missing from the image (see the '<== REQUIRED' lines above). Other MISS lines are reporting only. =="
	exit 1
fi

echo "== verification complete - review any MISS lines above (no REQUIRED path is missing) =="
