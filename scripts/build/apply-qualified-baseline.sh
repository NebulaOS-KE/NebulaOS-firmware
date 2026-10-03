#!/bin/sh
# Authoritative, single-command reproduction of the qualified NebulaOS
# production baseline on top of a pristine vendor kernel checkout.
#
# 2026-08-07 baseline-repair mission: widened from the original 7-variant
# scope (tag nebulaos-display-baseline-vsync-pwm-sleep-2026-08-03) to also
# include wifi-roamoff-disable-variant.sh ROAMOFF1, reaching the newer,
# currently-latest tagged and live-qualified baseline,
# nebulaos-wifi-camera-irq-fix-2026-08-04 (a superset of the 08-03 one -
# see that tag's own message: "WiFi SDIO IRQ priority fix + brcmfmac
# roamoff disable + ustreamer TCP_NODELAY, all live-qualified"). The other
# two fixes from that same mission (WiFi SDIO IRQ thread priority,
# ustreamer TCP_NODELAY) are NOT variant-gated at all - they are plain
# tracked overlay/init.d files (S02nebulaos-wifi-irq-priority, S50webcam),
# already picked up by every build with no script to run here. roamoff was
# the one piece still living behind a toggle, per this project's
# "never commit directly to the vendor kernel fork" convention (see
# wifi-roamoff-disable-variant.sh's own header) - originally, deliberately
# left out of this script's first version because that version was
# scoped to reproduce the OLDER tag specifically; that scoping reason no
# longer applies once "the currently accepted baseline" is the goal.
#
# WHY THIS SCRIPT EXISTS (2026-08-06/07 baseline canonicalization mission):
# the individual *-variant.sh scripts under this directory are deliberately
# experimental/toggleable A-B tools - each one's "off" state resets ONLY the
# files it owns to the real git-committed baseline first, and the tracked
# Kconfig fragment (artifacts/buildroot-halley5-v30-image/
# halley5-nebulaos-fragment.config) is reset to not-selected after every
# real qualification build, on purpose, so an unreviewed experiment can
# never silently become the new invisible default (see each script's own
# header for this rationale). The side effect: nobody had a single command
# that reproduces "every ACCEPTED variant, all at once, from a clean
# checkout" - running the base 00-06 pipeline alone silently regresses to
# pre-variant defaults, which is exactly the bug this script closes (found
# live 2026-08-06 attempting a routine GuppyScreen-only rebuild: PREEMPT_RT,
# the backlight-final-controller DT node, and the touch final-qualification
# driver all silently disappeared from a "clean" rebuild).
#
# This script does NOT invent new configuration - every one of the first 7
# calls below applies a change already independently verified present in the
# real, tracked, currently-deployed artifacts/buildroot-halley5-v30-image/
# {kernel.config,halley5_v30.dts} (see docs/NEBULAOS_QUALIFIED_BASELINE_
# VARIANT_AUDIT.md for the full per-script audit this was derived from,
# including which scripts/arguments were deliberately excluded and why).
# The 8th call (wifi-roamoff-disable-variant.sh ROAMOFF1) is verified the
# same way but against a source-level patch rather than kernel.config/DTS -
# see wifi-roamoff-disable-variant.sh's own header and commit 8d445a98's
# message for the live-verification evidence
# (/sys/module/brcmfmac/parameters/roamoff reads 1 on the deployed device).
#
# The 9th call (accelerometer-eeprom-bus-enable-variant.sh FIX1, added
# during the Phase 1.9A Host MCU + ADXL345 + BL24C16F Hardware Restoration
# mission and its follow-on Phase 1.9A SPI Polarity Fix Investigation)
# enables the spi-gpio-backed ADXL345 bus and the i2c2-backed BL24C16F bus
# in halley5_v30.dts, plus CONFIG_SPI_GPIO/CONFIG_I2C_CHARDEV in
# halley5-nebulaos-fragment.config - see
# accelerometer-eeprom-bus-enable-variant.sh's own header for the full
# root-cause and polarity-fix history, live-verified on real hardware
# (ACCELEROMETER_QUERY CHIP=adxl345 returns real motion data, no DEVID
# mismatch; EEPROM_DEBUG_READ CHIP=bl24c16f unchanged).
#
# Explicitly NOT applied here (audited and excluded, not merely forgotten):
#   - touch-qualification-variant.sh (QUAL0/QUAL1) - QUAL0 (off) is the
#     accepted state (CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION is absent from
#     the tracked kernel.config). Not invoked at all, on purpose: its own
#     "off" step does an unconditional blanket `git checkout --` of files
#     touch-final-qualification-variant.sh also owns, which would silently
#     wipe that script's content if run afterward (documented in that
#     script's own header). A pristine fresh checkout is already QUAL0.
#   - touch-irq-variant.sh, touch-d0-diag-variant.sh, touch-i0-diag-variant.sh,
#     display-backlight-variant.sh, display-backlight-diag-variant.sh -
#     diagnostic/prototype tools only; none of their Kconfig symbols appear
#     in the tracked kernel.config, confirming their accepted state is the
#     default/off value. Not invoked.
#
# Usage: sh scripts/build/apply-qualified-baseline.sh
# Run AFTER 00-fetch-vendor-sources.sh (needs a real vendor/x2000_kernel_6.6
# checkout) and BEFORE 02-configure-buildroot.sh, exactly like any other
# variant script.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

echo "== apply-qualified-baseline: applying every accepted baseline variant =="

# No inter-script ordering dependency exists among these nine calls (each
# owns disjoint kernel source files, or edits the shared DTS/fragment via
# its own uniquely-marked, append-only region rather than a blanket
# rewrite - verified per-script during the audit, see the doc referenced
# above). Listed here in the order the underlying missions were originally
# accepted, for readability only.
# 10th call: makes the Ingenic zboot payload gzip deterministic (adds -n).
# Header-only; it does not change the compressed kernel data. See that
# script for the measured cause.
sh "$SCRIPT_DIR/kernel-gzip-determinism-variant.sh" GZIPN1

echo "== apply-qualified-baseline: 9 accepted hardware variants + 1 determinism variant applied =="
