#!/bin/sh
# Verify this project's kernel-source changes (touch DT wiring, the new
# display panel driver, the new Bluetooth H5 Broadcom vendor extension,
# WiFi/BT/display Kconfig, the ported NS2009 driver, the binder.h build fix)
# are present in the checked-out kernel tree.
#
# FIRMWARE.md sec 39: these changes used to be applied here at build time from
# patches/x2000_kernel_6.6-openke.patch. They're now real, reviewable commits
# on the `openke` branch of a genuine fork (github.com/coreflake1/NebulaOS-kernel,
# renamed 2026-08-14 from coreflake1/NebulaOS - forked from the original
# upstream Llixuma/ingenic-linux-kernel6.6-x2000-v1.0-20250221) -
# 00-fetch-vendor-sources.sh checks out that branch directly,
# so there's nothing left to apply here. This script stays as stage "01" (kept
# numbered/in-sequence on purpose, so existing docs/muscle-memory still work)
# purely as a sanity check that the fork's content actually landed correctly.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"

if [ ! -d "$KERNEL_DIR/.git" ]; then
	echo "vendor/x2000_kernel_6.6 not found - run 00-fetch-vendor-sources.sh first" >&2
	exit 1
fi

cd "$KERNEL_DIR"

# Phase 11 (2026-08-15): used to require `git rev-parse --abbrev-ref HEAD`
# == "openke" here - broke live during the Phase 9-vs-Phase-11 rebuild-and-
# compare test the moment 00-fetch-vendor-sources.sh was fixed (same
# mission) to check out $KERNEL_PIN directly instead of $KERNEL_BRANCH:
# checking out an exact commit SHA is normal, correct, DETACHED HEAD in
# git - `--abbrev-ref HEAD` reports the literal string "HEAD" there, not a
# branch name, so this check started failing a checkout that was actually
# exactly correct. Removed rather than special-cased: the pin check two
# lines below already independently verifies the real invariant that
# matters (are we at the exact accepted commit), with its own hardcoded
# constant, regardless of which branch (if any) that commit happens to be
# reachable from - being "on" a named branch was never actually load-
# bearing for anything this script does after this point.
#
# Defense in depth: 00-fetch-vendor-sources.sh already enforces the pin and
# fails loudly on drift; this script verifies it again independently, so a
# hand-run `git pull` inside this checkout between the two scripts is still
# caught. The pin is read from the manifest - the one place it is recorded -
# rather than a second hardcoded copy that every pin bump would have to edit.
. "$REPO_ROOT/manifests/dependencies.conf"
X2000_KERNEL_6_6_PIN="${KERNEL_PIN:?KERNEL_PIN not set in manifests/dependencies.conf}"
ACTUAL_SHA=$(git rev-parse HEAD)
if [ "$ACTUAL_SHA" != "$X2000_KERNEL_6_6_PIN" ]; then
	echo "vendor/x2000_kernel_6.6 HEAD is $ACTUAL_SHA, expected pinned commit $X2000_KERNEL_6_6_PIN - re-run 00-fetch-vendor-sources.sh (it will refuse to proceed and explain why)" >&2
	exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
	echo "vendor/x2000_kernel_6.6 has working-tree changes - the build must not modify the kernel checkout (every NebulaOS kernel change is a commit on NebulaOS-kernel):" >&2
	git status --porcelain >&2
	exit 1
fi
echo "PASS: kernel checkout unmodified"

echo "== confirming the openke branch's real changes are present =="
test -f kernel/kernel-6.6/drivers/input/touchscreen/ns2009.c
test -f kernel/kernel-6.6/module_drivers/drivers/video/fbdev/ingenic/displays/panel-openke-general-480x272.c
grep -q "openke,bcm4343x-bt" kernel/kernel-6.6/drivers/bluetooth/hci_h5.c
grep -q "ns2009@48" kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts
grep -qF '	gzip -nv9f $(obj)/vmlinux.bin' kernel/kernel-6.6/arch/mips/boot/zcompressed/Makefile
echo "== kernel source verified =="
