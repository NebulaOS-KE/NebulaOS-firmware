#!/bin/sh
# Buildroot defconfig parity gate.
#
# The migration to official Buildroot 2025.02.18 replaced a 4258-line generated
# .config with an 84-line savedefconfig-derived defconfig. That is a large
# maintainability win and a real risk at the same time: savedefconfig records
# ONLY values that differ from the current upstream default, so a setting this
# product depends on can vanish from the defconfig simply because it happens to
# match today's upstream default - and then change silently when a future
# Buildroot moves that default.
#
# Concrete examples in this configuration, all of which are absent from the
# defconfig because they currently equal an upstream default, and all of which
# would be silent functional changes if that default moved:
#
#   BR2_MIPS_NAN_LEGACY / BR2_MIPS_FP32_MODE_XX / BR2_MIPS_OABI32
#       userspace ABI - a change here is a silently incompatible rootfs
#   BR2_GCC_VERSION_13_X / BR2_BINUTILS_VERSION_2_43_X
#       the qualified toolchain
#   BR2_TARGET_ROOTFS_EXT2_2r1 / _INODE_SIZE / _RESBLKS / _MKFS_OPTIONS
#       A/B partition layout assumptions
#
# So this gate does NOT diff the defconfig. It RESOLVES it the way a build does
# (defconfig -> olddefconfig) and then asserts the resulting .config by value,
# symbol by symbol. That is the only form that survives an upstream default
# move.
#
# Exit status: 0 = PASS, 1 = FAIL, 2 = SKIP (prerequisites absent). SKIP is
# reported explicitly and is NOT success - see mission rule "SKIP is not PASS".
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BUILDROOT_DIR=${NEBULAOS_BUILDROOT_DIR:-$REPO_ROOT/vendor/buildroot-x2000}
BR2_EXT=$REPO_ROOT/br2-external
DEFCONFIG=$BR2_EXT/configs/nebulaos_x2000_defconfig
PKGLIST=$SCRIPT_DIR/data/old-enabled-packages.txt

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }
skip() { printf 'SKIP: %s\n' "$1"; printf 'BUILDROOT_DEFCONFIG_PARITY=SKIP\n'; exit 2; }

[ -f "$DEFCONFIG" ] || skip "defconfig not found at $DEFCONFIG"
[ -f "$PKGLIST" ]   || skip "package assertion list not found at $PKGLIST"
# Run 12 (2026-10-18): the working tree's vendor/buildroot-x2000 can lag the
# pin (a build fetches the pinned tree into its own run directory), and
# resolving the defconfig against an older Buildroot reported gcc 12.3 /
# lost host-python3 - a false FAIL. Use a tree at BUILDROOT_PIN: the local
# one if it is at the pin, else the newest build run's.
BR_PIN=$(sed -n 's/^BUILDROOT_PIN=//p' "$REPO_ROOT/manifests/dependencies.conf" | head -1)
if [ -z "${NEBULAOS_BUILDROOT_DIR:-}" ] && [ -n "$BR_PIN" ] && \
   [ "$(git -C "$BUILDROOT_DIR" rev-parse HEAD 2>/dev/null)" != "$BR_PIN" ]; then
	_found=
	for _d in $(ls -dt /var/tmp/nebulaos-build/*/run-*/vendor/buildroot-x2000 2>/dev/null); do
		if [ "$(git -C "$_d" rev-parse HEAD 2>/dev/null)" = "$BR_PIN" ]; then _found=$_d; break; fi
	done
	[ -n "$_found" ] || skip "no Buildroot tree at the pinned $BR_PIN (local $BUILDROOT_DIR is at another commit; run a build or 00-fetch-vendor-sources.sh)"
	BUILDROOT_DIR=$_found
	printf 'NOTE: local Buildroot is not at the pin - using %s\n' "$BUILDROOT_DIR"
fi
[ -d "$BUILDROOT_DIR" ] || skip "Buildroot tree not present at $BUILDROOT_DIR (run scripts/build/00-fetch-vendor-sources.sh first)"
[ -f "$BUILDROOT_DIR/Makefile" ] || skip "$BUILDROOT_DIR is not a Buildroot tree"

# Resolve the defconfig in a scratch output dir so this never disturbs a real
# build tree (Buildroot supports out-of-tree output via O=).
WORK=$(mktemp -d 2>/dev/null) || skip "cannot create a temporary directory"
trap 'rm -rf "$WORK"' EXIT INT TERM

# Deliberately no staging into $BUILDROOT_DIR/configs/: Buildroot's %_defconfig
# rule searches every BR2_EXTERNAL tree, and writing into the upstream checkout
# is exactly what this migration is trying to stop. Running this suite must not
# dirty the Buildroot tree.

if ! ( cd "$BUILDROOT_DIR" && make O="$WORK" BR2_EXTERNAL="$BR2_EXT" nebulaos_x2000_defconfig ) >"$WORK/defconfig.log" 2>&1; then
	printf 'FAIL: `make nebulaos_x2000_defconfig` did not succeed\n'
	tail -20 "$WORK/defconfig.log"
	printf 'BUILDROOT_DEFCONFIG_PARITY=FAIL\n'; exit 1
fi
if ! ( cd "$BUILDROOT_DIR" && make O="$WORK" BR2_EXTERNAL="$BR2_EXT" olddefconfig ) >"$WORK/olddefconfig.log" 2>&1; then
	printf 'FAIL: `make olddefconfig` did not succeed\n'
	tail -20 "$WORK/olddefconfig.log"
	printf 'BUILDROOT_DEFCONFIG_PARITY=FAIL\n'; exit 1
fi
CFG=$WORK/.config
[ -f "$CFG" ] || { printf 'FAIL: no .config produced\n'; printf 'BUILDROOT_DEFCONFIG_PARITY=FAIL\n'; exit 1; }

# assert_val <symbol> <expected-exact-rhs>
assert_val() {
	_got=$(grep -E "^$1=" "$CFG" | head -1 | cut -d= -f2-)
	if [ "$_got" = "$2" ]; then ok; else bad "$1 is '${_got:-<unset>}', expected '$2'"; fi
}
# assert_unset_or_empty <symbol>  - for string symbols deliberately dropped
assert_empty() {
	_got=$(grep -E "^$1=" "$CFG" | head -1 | cut -d= -f2-)
	if [ -z "$_got" ] || [ "$_got" = '""' ]; then ok; else bad "$1 is '$_got', expected empty/unset"; fi
}

# ---- architecture / ABI (mission section 4) --------------------------------
assert_val BR2_mipsel y
assert_val BR2_mips_xburst y
assert_val BR2_MIPS_CPU_MIPS32R2 y
assert_val BR2_MIPS_FP32_MODE_XX y
assert_val BR2_MIPS_NAN_LEGACY y
assert_val BR2_MIPS_OABI32 y
assert_val BR2_GCC_TARGET_ARCH '"mips32r2"'
assert_val BR2_GCC_TARGET_ABI '"32"'
assert_val BR2_GCC_TARGET_NAN '"legacy"'
assert_val BR2_GCC_TARGET_FP32_MODE '"xx"'

# ---- toolchain (mission section 8) -----------------------------------------
assert_val BR2_GCC_VERSION '"13.4.0"'
assert_val BR2_GCC_VERSION_13_X y
assert_val BR2_BINUTILS_VERSION '"2.43.1"'
assert_val BR2_TOOLCHAIN_BUILDROOT_GLIBC y
assert_val BR2_TOOLCHAIN_BUILDROOT_CXX y
assert_val BR2_KERNEL_HEADERS_AS_KERNEL y
assert_val BR2_TOOLCHAIN_HEADERS_AT_LEAST '"6.6"'
# -Os, NOT -O2/-O3/-Ofast. Mission section 8 is explicit that this must not
# drift. Note this is Buildroot's own target optimization only; the app-stack
# cross-compile sets its own -Os independently in
# scripts/build/04-cross-compile-app-stack.sh and is asserted there, not here.
assert_val BR2_OPTIMIZE_S y
# LTO must stay off for this migration.
assert_empty BR2_GCC_ENABLE_LTO

# ---- reproducibility and supply chain --------------------------------------
assert_val BR2_REPRODUCIBLE y
# BR2_DOWNLOAD_FORCE_CHECK_HASHES is deliberately OFF, and asserted off so the
# decision is recorded rather than drifting.
#
# Mission section 26 asks for strict hash checking "when practical". It is not
# practical here yet, for a specific reason. Its help text: Buildroot already
# checks hashes for every download EXCEPT packages using a custom version;
# turning this on extends checking to those too, and the documented way to
# supply the missing hashes is to place hash files in BR2_GLOBAL_PATCH_DIR.
#
# This product's kernel IS such a package - BR2_LINUX_KERNEL_CUSTOM_GIT at a
# pinned SHA - and BR2_GLOBAL_PATCH_DIR was removed by this migration after
# being proven inert. Measured against the real configuration: of 236 download
# artifacts, exactly 2 have no hash, and both are the kernel tarball (linux and
# linux-headers). Everything else, including all nine br2-external packages, is
# hashed.
#
# The kernel's provenance is enforced by a different mechanism rather than left
# unchecked: KERNEL_REPO/KERNEL_PIN in manifests/dependencies.conf, re-verified
# on every run by 00-fetch-vendor-sources.sh (including the origin-URL check
# added by this migration), plus the workspace identity gate. The kernel is also
# rsynced from that pinned checkout via LINUX_OVERRIDE_SRCDIR rather than
# downloaded.
#
# Enabling it is a follow-up item, not a silent omission. See
# docs/BUILDROOT_2025_MIGRATION_PARITY.md.
assert_empty BR2_DOWNLOAD_FORCE_CHECK_HASHES

# ---- init / device management ----------------------------------------------
assert_val BR2_ROOTFS_DEVICE_CREATION_DYNAMIC_EUDEV y

# ---- filesystem / A-B layout (architect finding 12) ------------------------
assert_val BR2_TARGET_ROOTFS_EXT2 y
assert_val BR2_TARGET_ROOTFS_EXT2_2r1 y
assert_val BR2_TARGET_ROOTFS_EXT2_SIZE '"400M"'
assert_val BR2_TARGET_ROOTFS_EXT2_INODE_SIZE 256
assert_val BR2_TARGET_ROOTFS_EXT2_RESBLKS 5
assert_val BR2_TARGET_ROOTFS_EXT2_MKFS_OPTIONS '"-O ^64bit"'
assert_val BR2_TARGET_ROOTFS_EXT2_LABEL '"rootfs"'
assert_val BR2_TARGET_ROOTFS_SQUASHFS y
assert_val BR2_TARGET_ROOTFS_SQUASHFS_BS_128K y
assert_val BR2_TARGET_ROOTFS_SQUASHFS_PAD y
assert_val BR2_TARGET_ROOTFS_SQUASHFS4_ZSTD y

# ---- kernel image ----------------------------------------------------------
assert_val BR2_LINUX_KERNEL y
assert_val BR2_LINUX_KERNEL_DEFCONFIG '"nebulaos_halley5_v30"'
assert_val BR2_LINUX_KERNEL_IMAGE_TARGET_NAME '"xImage"'
assert_val BR2_LINUX_KERNEL_LZO y

# ---- BR2_EXTERNAL path settings (architect required change 2) --------------
# A wrong overlay path produces a SUCCESSFUL build with no NebulaOS content in
# the image, which nothing else catches directly - so these are asserted by
# exact value, not merely for non-emptiness.
X='$(BR2_EXTERNAL_NEBULAOS_PATH)/board/nebulaos-x2000'
assert_val BR2_ROOTFS_OVERLAY "\"$X/overlay\""
assert_val BR2_ROOTFS_POST_BUILD_SCRIPT "\"$X/post-build.sh\""
assert_val BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES "\"$X/nebulaos-kernel-buildenv.config\""
assert_val BR2_PACKAGE_BUSYBOX_CONFIG_FRAGMENT_FILES "\"$X/halley5-nebulaos-busybox-fragment.config\""
# NG1 (2026-10-05): the global patch dir is back, scoped to br2-external and
# carrying only version-scoped NebulaOS package patches (python-tornado/6.4.2:
# the missing _ABNF of Buildroot's CVE-2025-67724 backport). 02-configure
# refuses a version directory that no longer matches the package.
# G9 phase 1 (2026-10-07): e2fsck/dumpe2fs for the /usr/data boot check
# (S01persistent-datastore); the e2fsprogs fsck wrapper stays off (BusyBox fsck).
assert_val BR2_PACKAGE_E2FSPROGS y
assert_empty BR2_PACKAGE_E2FSPROGS_FSCK
assert_val BR2_GLOBAL_PATCH_DIR '"$(BR2_EXTERNAL_NEBULAOS_PATH)/patches"'
# Deliberately dropped by the migration - asserted so their removal is a tested
# fact rather than an edit that can regress.
assert_empty BR2_ROOTFS_POST_IMAGE_SCRIPT
assert_empty BR2_ROOTFS_POST_SCRIPT_ARGS

# ---- no deprecated options -------------------------------------------------
if grep -qE '^BR2_LEGACY=y$' "$CFG"; then
	bad "BR2_LEGACY=y - the configuration still selects options Buildroot has removed; Buildroot refuses to build in this state"
else ok; fi

# ---- memory resilience prerequisites (mission section 9) -------------------
# zram/swap are kernel config, asserted by the kernel fragment gate, but the
# userspace tools that S00zram-swap and S03nebulaos-diskswap depend on are
# Buildroot packages and are asserted here.
assert_val BR2_PACKAGE_BUSYBOX y

# ---- every package that was enabled before must still be enabled -----------
# mission section 3: nothing currently working may disappear silently.
MISSING=0
while IFS= read -r sym; do
	[ -n "$sym" ] || continue
	if grep -qE "^$sym=y$" "$CFG"; then ok; else bad "package lost: $sym"; MISSING=$((MISSING+1)); fi
done < "$PKGLIST"

printf '\n'
printf 'PACKAGES_ASSERTED=%s\n' "$(grep -c . "$PKGLIST")"
printf 'PACKAGES_MISSING=%s\n' "$MISSING"
printf 'ASSERTIONS_PASS=%s\n' "$PASS"
printf 'ASSERTIONS_FAIL=%s\n' "$FAIL"
if [ "$FAIL" -eq 0 ]; then
	printf 'BUILDROOT_DEFCONFIG_PARITY=PASS\n'; exit 0
fi
printf 'BUILDROOT_DEFCONFIG_PARITY=FAIL\n'; exit 1
