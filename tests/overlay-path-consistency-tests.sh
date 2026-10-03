#!/bin/sh
# The rootfs overlay path must mean the same thing in all three places that
# name it.
#
# WHY THIS EXISTS. Relocating the overlay out of the upstream Buildroot
# checkout into br2-external/ required changing it in three independent files.
# One was missed - scripts/build/04-cross-compile-app-stack.sh kept the old
# literal - and the failure mode was genuinely nasty:
#
#   - stage 02 populated the NEW overlay directory
#   - stage 04 wrote the ENTIRE application payload (Klipper, Moonraker,
#     Mainsail, GuppyScreen) into the OLD one, which Buildroot never reads
#   - stage 05 would have produced a rootfs that built perfectly cleanly and
#     simply contained no application stack at all
#
# It happened to fail instead, but only ~1400 lines later on an unrelated
# missing directory, which points nowhere near the real divergence. A silent
# success would have been worse: an image that boots to no printer software.
#
# So this asserts agreement directly, cheaply, with no build required.
#
# Exit: 0 PASS, 1 FAIL, 2 SKIP.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

CONFIGURE=$ROOT/scripts/build/02-configure-buildroot.sh
APPSTACK=$ROOT/scripts/build/04-cross-compile-app-stack.sh
DEFCONFIG=$ROOT/br2-external/configs/nebulaos_x2000_defconfig

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$1"; }

for f in "$CONFIGURE" "$APPSTACK" "$DEFCONFIG"; do
	[ -f "$f" ] || { printf 'SKIP: %s not found\n' "$f"; printf 'OVERLAY_PATH_CONSISTENCY=SKIP\n'; exit 2; }
done

# The canonical relative location, expressed once here.
REL="br2-external/board/nebulaos-x2000/overlay"

# 1. the defconfig must point at it via $(BR2_EXTERNAL_NEBULAOS_PATH)
want_dc='BR2_ROOTFS_OVERLAY="$(BR2_EXTERNAL_NEBULAOS_PATH)/board/nebulaos-x2000/overlay"'
if grep -Fxq "$want_dc" "$DEFCONFIG"; then
	ok "defconfig BR2_ROOTFS_OVERLAY points at board/nebulaos-x2000/overlay"
else
	bad "defconfig BR2_ROOTFS_OVERLAY is not '$want_dc' (got: $(grep -F 'BR2_ROOTFS_OVERLAY=' "$DEFCONFIG" || echo '<absent>'))"
fi

# 2. 02-configure must populate exactly that directory
if grep -q 'BR2_EXT_BOARD="\$BR2_EXT/board/nebulaos-x2000"' "$CONFIGURE" \
   && grep -q 'cp -r "\$REPO_ROOT/scripts/build/overlay/\." "\$BR2_EXT_BOARD/overlay/"' "$CONFIGURE"; then
	ok "02-configure-buildroot.sh populates \$BR2_EXT_BOARD/overlay"
else
	bad "02-configure-buildroot.sh no longer populates \$BR2_EXT_BOARD/overlay in the expected way"
fi

# 3. 04 must write the application payload into the SAME directory
if grep -Fq "OVERLAY=\"\$REPO_ROOT/$REL\"" "$APPSTACK"; then
	ok "04-cross-compile-app-stack.sh OVERLAY resolves to \$REPO_ROOT/$REL"
else
	bad "04-cross-compile-app-stack.sh OVERLAY is not \$REPO_ROOT/$REL (got: $(grep -m1 '^OVERLAY=' "$APPSTACK" || echo '<absent>'))"
fi

# 4. nothing may write the overlay back inside the upstream Buildroot checkout
if grep -rn 'BUILDROOT_DIR/board/halley5-nebulaos-overlay' "$ROOT/scripts" 2>/dev/null \
   | grep -vE ':[[:space:]]*#' | grep -q .; then
	bad "a script still references the OLD in-tree overlay path:"
	grep -rn 'BUILDROOT_DIR/board/halley5-nebulaos-overlay' "$ROOT/scripts" | grep -vE ':[[:space:]]*#' | sed 's/^/      /'
else
	ok "no script writes the overlay inside the upstream Buildroot checkout"
fi

# 5. the build-environment kernel fragment's CONFIG_EXTRA_FIRMWARE_DIR must
#    target the same overlay, or CONFIG_EXTRA_FIRMWARE will point at firmware
#    that is not there and the kernel build fails in
#    drivers/base/firmware_loader. (Since SOT-21 stage 02 writes it into
#    nebulaos-kernel-buildenv.config; the kernel config itself is the
#    kernel-owned nebulaos_halley5_v30_defconfig.)
if grep -q "printf 'CONFIG_EXTRA_FIRMWARE_DIR=\"%s\"\\\\n' \"\$BR2_EXT_BOARD/overlay/lib/firmware\"" "$CONFIGURE"; then
	ok "CONFIG_EXTRA_FIRMWARE_DIR is written as \$BR2_EXT_BOARD/overlay/lib/firmware"
else
	bad "02-configure-buildroot.sh no longer writes CONFIG_EXTRA_FIRMWARE_DIR=\$BR2_EXT_BOARD/overlay/lib/firmware"
fi

printf '\nOVERLAY_PATH_PASS=%s\nOVERLAY_PATH_FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { printf 'OVERLAY_PATH_CONSISTENCY=PASS\n'; exit 0; }
printf 'OVERLAY_PATH_CONSISTENCY=FAIL\n'; exit 1
