#!/bin/sh
# Phase 2 baseline assertions (baseline-canonicalization-and-z_compensate-
# deployment mission, 2026-08-06/07). Fails loudly and immediately if any
# qualified-baseline feature is missing - "do not accept script exit status
# as proof" (the mission's own words): apply-qualified-baseline.sh exiting
# 0 only means each variant script itself didn't error, not that the
# resulting *build* actually contains what it's supposed to. This script
# checks the real, resolved artifacts instead.
#
# Three modes:
#   sh scripts/build/assert-baseline-config.sh pre-build
#     Run AFTER apply-qualified-baseline.sh, BEFORE 02/03/05 - checks the
#     vendor kernel tree's source-level state (Kconfig symbols exist, DTS
#     nodes present) so a missing patch is caught before spending build time.
#     This is what "SOURCE_VERIFIED" means (see Phase 1 overnight closure
#     mission, Mission H): every accepted variant's source-level change is
#     actually present, nothing about whether it compiled or matches any
#     prior hardware-qualified state.
#   sh scripts/build/assert-baseline-config.sh post-build
#     Run AFTER 05-final-build.sh to REPRODUCE an ALREADY hardware-qualified
#     baseline byte/semantically-exactly (used by build-qualified-
#     baseline.sh's own wrapper, and for regression-testing a change against
#     a frozen, already-qualified reference). Any difference from
#     QUALIFIED_BASELINE_TAG is a FAILURE here, by design - this mode's
#     entire purpose is proving nothing drifted from what was already
#     qualified. Do NOT use this mode to evaluate a candidate that
#     legitimately contains new, not-yet-hardware-qualified source changes -
#     it will always and correctly report FAIL for those, since "identical
#     to the last qualified baseline" is precisely what a real candidate is
#     not yet.
#   sh scripts/build/assert-baseline-config.sh candidate-post-build
#     Added by the Phase 1 overnight closure mission (Mission H): the same
#     resolved-artifact Kconfig/DTS assertions as post-build (so a real
#     candidate is still proven to actually contain everything every
#     accepted variant is supposed to produce - this is "BUILD_VERIFIED"),
#     but the QUALIFIED_BASELINE_TAG comparison is reported as an
#     INFORMATIONAL diff, never a gate - a legitimate candidate is EXPECTED
#     to differ from the last hardware-qualified baseline (that's what
#     makes it a candidate). Nothing in this repository calls a build
#     "hardware-qualified" merely because this mode passes; promoting
#     QUALIFIED_BASELINE_TAG to a new value remains a separate, deliberate,
#     manually-reviewed edit to manifests/dependencies.conf made only after
#     real hardware qualification - this mode never touches that file.
#
# Usage: sh scripts/build/assert-baseline-config.sh <pre-build|post-build|candidate-post-build>

set -eu

MODE="${1:?usage: $0 <pre-build|post-build>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
ARTIFACT_DIR="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"

DEPS_MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
[ -f "$DEPS_MANIFEST" ] || { echo "FATAL: $DEPS_MANIFEST not found" >&2; exit 1; }
. "$DEPS_MANIFEST"

FAILED=0
# RC, and the `&& RC=0 || RC=$?` suffix on each assertion predicate below, exist because
# this script runs under `set -eu`. The previous idiom was a bare predicate
# followed by `check "..." $?`. Under errexit a FAILING predicate terminates the
# script AT THE PREDICATE, so the check never ran, no FAIL: line was ever
# printed, and every assertion after it was skipped. Observed directly: twelve
# PASS lines, zero FAIL lines, exit 1, with five assertions silently never
# evaluated - in a gate whose own header promises it "fails loudly and
# immediately". A release gate that exits non-zero with no diagnostic is one
# nobody can read under pressure.
#
# `&& RC=0 || RC=$?` is errexit-safe because the status is consumed by `||`,
# and it binds to a whole pipeline, which the `echo ... | grep -q` assertions
# need. Do NOT "simplify" it to `|| true`: that would make RC always 0 and turn
# every assertion into an unconditional PASS, which is far worse than the bug
# it replaced.
RC=0

check() {
	desc="$1"
	if [ "$2" = "0" ]; then
		echo "  PASS: $desc"
	else
		echo "  FAIL: $desc"
		FAILED=1
	fi
}

case "$MODE" in
pre-build)
	echo "== Phase 2 pre-build assertions (source-level) =="

	# Kconfig symbol definitions must exist somewhere in the patched kernel
	# tree - if a patch failed to apply, the symbol simply won't be defined
	# anywhere, and later feeding it into a fragment would just be silently
	# dropped by `make olddefconfig` (exactly the 2026-08-06 regression).
	grep -rlq "NEBULAOS_BACKLIGHT_FINAL_CONTROLLER" "$KERNEL_DIR" 2>/dev/null && RC=0 || RC=$?
	check "backlight-final-controller Kconfig symbol defined in kernel tree" "$RC"

	grep -rlq "TOUCHSCREEN_NS2009_FINAL_QUALIFICATION" "$KERNEL_DIR" 2>/dev/null && RC=0 || RC=$?
	check "touch-final-qualification Kconfig symbol defined in kernel tree" "$RC"

	grep -rlq "PWM_INGENIC_V2_GET_STATE" "$KERNEL_DIR" 2>/dev/null && RC=0 || RC=$?
	check "pwm-state-readback Kconfig symbol defined in kernel tree" "$RC"

	grep -rlq "FB_INGENIC_PAN_VSYNC_GATE" "$KERNEL_DIR" 2>/dev/null && RC=0 || RC=$?
	check "display-vsync (DISPLAY-V1) Kconfig symbol defined in kernel tree" "$RC"

	[ -f "$KERNEL_DIR/kernel/kernel-6.6/module_drivers/drivers/misc/nebulaos_backlight_final_controller.c" ] && RC=0 || RC=$?
	check "nebulaos_backlight_final_controller.c driver file present" "$RC"

	[ -f "$KERNEL_DIR/kernel/kernel-6.6/drivers/input/touchscreen/ns2009_final_qualification.c" ] && RC=0 || RC=$?
	check "ns2009_final_qualification.c driver file present" "$RC"

	grep -q "nebulaos_backlight_final:" "$KERNEL_DIR/kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts" 2>/dev/null && RC=0 || RC=$?
	check "nebulaos_backlight_final DT node present" "$RC"

	# Command substitution needs the same errexit treatment as the predicates:
	# a non-zero sed here would abort the script at the ASSIGNMENT, skipping
	# every remaining assertion with no diagnostic. Demonstrated with the DTS
	# absent: 10 of 17 assertions silently skipped, exit 2. pre-build has no
	# prior existence check on the DTS, so this path is genuinely reachable.
	msc1_block=$(sed -n '/^&msc1 {/,/^};/p' "$KERNEL_DIR/kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts" 2>/dev/null) || msc1_block=""
	echo "$msc1_block" | grep -q 'cap-sd-highspeed;' && RC=0 || RC=$?
	check "W3 cap-sd-highspeed present in &msc1" "$RC"
	echo "$msc1_block" | grep -q 'cap-sdio-irq;' && RC=0 || RC=$?
	check "W3 cap-sdio-irq present in &msc1" "$RC"

	# No build-time kernel mutation (SOT-30): the kernel checkout must be
	# exactly the pinned commit. Every NebulaOS kernel change is a commit.
	[ -z "$(git -C "$KERNEL_DIR" status --porcelain 2>/dev/null)" ] && RC=0 || RC=$?
	check "kernel checkout unmodified" "$RC"

	# The production kernel configuration is owned by NebulaOS-kernel.
	FRAGMENT="$KERNEL_DIR/kernel/kernel-6.6/arch/mips/configs/nebulaos_halley5_v30_defconfig"
	[ -f "$FRAGMENT" ] && RC=0 || RC=$?
	check "kernel-owned production defconfig nebulaos_halley5_v30_defconfig present" "$RC"
	grep -q "CONFIG_PREEMPT_RT=y" "$FRAGMENT" 2>/dev/null && RC=0 || RC=$?
	check "CONFIG_PREEMPT_RT=y present in the production defconfig" "$RC"

	# 2026-08-07: wifi-roamoff-disable-variant.sh ROAMOFF1 - not a Kconfig
	# symbol (see that script's own header), so the only real source-level
	# proof is the patched module_param default itself.
	grep -qF "static int brcmf_roamoff = 1;" \
		"$KERNEL_DIR/kernel/kernel-6.6/drivers/net/wireless/broadcom/brcm80211/brcmfmac/common.c" 2>/dev/null && RC=0 || RC=$?
	check "wifi-roamoff-disable (ROAMOFF1) patch applied to brcmfmac common.c" "$RC"

	# Accelerometer/EEPROM bus (Phase 1.9B): spi-gpio ADXL345 and the at24
	# EEPROM driver, in the production defconfig, with I2C_CHARDEV retired.
	grep -q "CONFIG_SPI_GPIO=y" "$FRAGMENT" 2>/dev/null && RC=0 || RC=$?
	check "CONFIG_SPI_GPIO=y present in the production defconfig (accelerometer/EEPROM)" "$RC"
	grep -q "CONFIG_EEPROM_AT24=y" "$FRAGMENT" 2>/dev/null && RC=0 || RC=$?
	check "CONFIG_EEPROM_AT24=y present in the production defconfig (accelerometer/EEPROM)" "$RC"
	if grep -q "^CONFIG_I2C_CHARDEV=y$" "$FRAGMENT" 2>/dev/null; then
		echo "  FAIL: CONFIG_I2C_CHARDEV=y present in the production defconfig - Phase 1.9B retired this (no consumer remains, see machine.cfg)"
		FAILED=1
	else
		echo "  PASS: CONFIG_I2C_CHARDEV not set in the production defconfig (retired, Phase 1.9B)"
	fi
	grep -q 'eeprom@50 {' "$KERNEL_DIR/kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts" 2>/dev/null && RC=0 || RC=$?
	check "eeprom@50 (at24) DT node present" "$RC"
	grep -q 'spi_gpio_adxl345 {' "$KERNEL_DIR/kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts" 2>/dev/null && RC=0 || RC=$?
	check "spi_gpio_adxl345 DT node present" "$RC"
	;;

post-build|candidate-post-build)
	if [ "$MODE" = "post-build" ]; then
		echo "== Phase 2 post-build assertions (resolved artifacts, strict baseline-reproduction gate) =="
	else
		echo "== Phase 2 candidate-post-build assertions (resolved artifacts, BUILD_VERIFIED - no baseline-reproduction gate) =="
	fi
	KCONFIG="$ARTIFACT_DIR/kernel.config"
	DTS="$ARTIFACT_DIR/halley5_v30.dts"

	[ -f "$KCONFIG" ] || { echo "FATAL: $KCONFIG not found - run 05-final-build.sh first" >&2; exit 1; }
	[ -f "$DTS" ] || { echo "FATAL: $DTS not found - run 05-final-build.sh first" >&2; exit 1; }

	grep -q "^CONFIG_PREEMPT_RT=y$" "$KCONFIG" && RC=0 || RC=$?
	check "CONFIG_PREEMPT_RT=y" "$RC"

	grep -q "^CONFIG_HZ=100$" "$KCONFIG" && RC=0 || RC=$?
	check "CONFIG_HZ=100" "$RC"

	grep -q "^CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER=y$" "$KCONFIG" && RC=0 || RC=$?
	check "CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER=y (qualified backlight/PWM controller)" "$RC"

	grep -q "^CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION=y$" "$KCONFIG" && RC=0 || RC=$?
	check "CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION=y" "$RC"

	grep -q "^CONFIG_TOUCHSCREEN_NS2009=y$" "$KCONFIG" && RC=0 || RC=$?
	check "CONFIG_TOUCHSCREEN_NS2009=y (base driver present - polling touch retained)" "$RC"

	# Touch must remain polling-based: the OLDER, rejected IRQ-based
	# touch-irq-variant.sh/touch-qualification-variant.sh symbols must NOT
	# be present (would mean an unintended variant got mixed in).
	if grep -q "^CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION=y$" "$KCONFIG" 2>/dev/null; then
		echo "  FAIL: CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION=y present - unexpected IRQ-based touch variant, baseline should be poll-only"
		FAILED=1
	else
		echo "  PASS: CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION absent (touch remains polling-based)"
	fi

	grep -q "^CONFIG_PWM_INGENIC_V2_GET_STATE=y$" "$KCONFIG" && RC=0 || RC=$?
	check "CONFIG_PWM_INGENIC_V2_GET_STATE=y (PWM brightness readback)" "$RC"

	grep -q "^CONFIG_FB_INGENIC_PAN_VSYNC_GATE=y$" "$KCONFIG" && RC=0 || RC=$?
	check "CONFIG_FB_INGENIC_PAN_VSYNC_GATE=y (DISPLAY-V1)" "$RC"

	grep -q "nebulaos_backlight_final:" "$DTS" && RC=0 || RC=$?
	check "nebulaos_backlight_final DT node present in resolved DTS" "$RC"

	# Same errexit treatment as line ~116. Lower risk here because the FATAL
	# existence check above already guarantees $DTS is readable, but an
	# assignment that can abort the run is not worth leaving asymmetric.
	msc1_block=$(sed -n '/^&msc1 {/,/^};/p' "$DTS") || msc1_block=""
	echo "$msc1_block" | grep -q 'cap-sd-highspeed;' && RC=0 || RC=$?
	check "W3 cap-sd-highspeed present in resolved &msc1" "$RC"
	echo "$msc1_block" | grep -q 'cap-sdio-irq;' && RC=0 || RC=$?
	check "W3 cap-sdio-irq present in resolved &msc1" "$RC"

	# 2026-08-07: wifi-roamoff-disable (ROAMOFF1) - not a Kconfig symbol,
	# so kernel.config can't prove it. vendor/x2000_kernel_6.6 is not
	# deleted by the build, so the same source-level check from pre-build
	# still applies and is the only real proof available short of
	# extracting strings from the compiled kernel image.
	grep -qF "static int brcmf_roamoff = 1;" \
		"$KERNEL_DIR/kernel/kernel-6.6/drivers/net/wireless/broadcom/brcm80211/brcmfmac/common.c" 2>/dev/null && RC=0 || RC=$?
	check "wifi-roamoff-disable (ROAMOFF1) patch present in source tree used for this build" "$RC"

	# 9th accepted variant (Phase 1.9A/1.9B) - resolved-artifact equivalents
	# of the pre-build checks above.
	grep -q "^CONFIG_SPI_GPIO=y$" "$KCONFIG" && RC=0 || RC=$?
	check "CONFIG_SPI_GPIO=y (resolved kernel.config)" "$RC"
	grep -q "^CONFIG_EEPROM_AT24=y$" "$KCONFIG" && RC=0 || RC=$?
	check "CONFIG_EEPROM_AT24=y (resolved kernel.config)" "$RC"
	if grep -q "^CONFIG_I2C_CHARDEV=y$" "$KCONFIG" 2>/dev/null; then
		echo "  FAIL: CONFIG_I2C_CHARDEV=y present in resolved kernel.config - Phase 1.9B retired this"
		FAILED=1
	else
		echo "  PASS: CONFIG_I2C_CHARDEV not set in resolved kernel.config (retired, Phase 1.9B)"
	fi
	grep -q 'eeprom@50 {' "$DTS" && RC=0 || RC=$?
	check "eeprom@50 (at24) DT node present in resolved DTS" "$RC"
	grep -q 'spi_gpio_adxl345 {' "$DTS" && RC=0 || RC=$?
	check "spi_gpio_adxl345 DT node present in resolved DTS" "$RC"

	# Kernel configuration profile (SOT-51). The resolved kernel must match
	# the profile the manifest selected; a diagnostic kernel must never pass
	# the strict (qualified) gate.
	PROFILE=$(grep -m1 '^kernel_config_profile=' "$ARTIFACT_DIR/build-manifest.txt" 2>/dev/null | cut -d= -f2)
	echo "  KERNEL_CONFIG_PROFILE=${PROFILE:-unknown}"
	case "$PROFILE" in
	production)
		grep -qx '# CONFIG_FTRACE is not set' "$KCONFIG" && RC=0 || RC=$?
		check "production kernel: CONFIG_FTRACE not set" "$RC"
		grep -qx 'CONFIG_LOCALVERSION=""' "$KCONFIG" && RC=0 || RC=$?
		check "production kernel: empty CONFIG_LOCALVERSION" "$RC"
		;;
	diagnostic)
		DIAG="$KERNEL_DIR/kernel/kernel-6.6/arch/mips/configs/nebulaos_halley5_v30_diagnostic.config"
		for sym in $(grep '^CONFIG_' "$DIAG"); do
			grep -qxF "$sym" "$KCONFIG" && RC=0 || RC=$?
			check "diagnostic kernel: $sym" "$RC"
		done
		if [ "$MODE" = "post-build" ]; then
			echo "  FAIL: a diagnostic kernel can never reproduce a qualified baseline"
			FAILED=1
		fi
		;;
	*)
		echo "  FAIL: build-manifest.txt records no valid kernel_config_profile"
		FAILED=1
		;;
	esac

	if [ "$MODE" = "candidate-post-build" ]; then
		# BUILD_VERIFIED stops here - every accepted variant (1-9) is proven
		# present in the actual resolved artifact. Deliberately does NOT run
		# the strict baseline-tag reproduction gate below: a legitimate
		# candidate differing from the last hardware-qualified baseline is
		# expected, not a defect. That comparison is still run, but only as
		# an informational report (see below), never as part of $FAILED.
		BASELINE_REF="${QUALIFIED_BASELINE_TAG:-}"
		if [ -z "$BASELINE_REF" ] || ! git -C "$REPO_ROOT" rev-parse --verify -q "$BASELINE_REF" >/dev/null 2>&1; then
			echo "  == candidate-vs-last-qualified-baseline diff: SKIPPED (QUALIFIED_BASELINE_TAG unset or unresolvable) =="
		else
			echo "  == candidate differences vs last hardware-qualified baseline $BASELINE_REF (informational only - NOT a gate) =="
			. "$SCRIPT_DIR/lib/baseline-config-compare.sh"
			for f in kernel.config halley5_v30.dtb.dts buildroot.config; do
				artifact_path="$ARTIFACT_DIR/$f"
				[ -f "$artifact_path" ] || continue
				diff_rc=0
				diff_output=$(baseline_config_semantic_diff "$f" "$artifact_path" "$BASELINE_REF" "$REPO_ROOT" 2>&1) || diff_rc=$?
				if [ "$diff_rc" -eq 0 ]; then
					echo "     $f: identical to $BASELINE_REF"
				elif [ "$diff_rc" -eq 1 ]; then
					echo "     $f: differs from $BASELINE_REF (expected for a real candidate - review, do not silence):"
					echo "$diff_output" | sed "s/^/       /"
				else
					echo "     $f: could not compare against $BASELINE_REF: $diff_output"
				fi
			done
		fi
		if [ "$FAILED" = "1" ]; then
			echo "== candidate-post-build assertions: FAILED - a required accepted-variant check did not pass =="
			exit 1
		fi
		echo "== candidate-post-build assertions: BUILD_VERIFIED (every accepted variant present in the resolved artifact; see the informational diff above for exactly how this candidate differs from the last hardware-qualified baseline) =="
		exit 0
	fi

	# post-build only, from here on: strict, byte/semantic-identical proof
	# against the pinned baseline tag's own tracked
	# copies - the strongest assertion available: not "does it look right",
	# but "is it identical to what was actually qualified".
	#
	# 2026-08-07: reference by TAG NAME, not a hardcoded SHA - the 2026-08-07
	# canonical-repository mission rewrote this repo's early history to strip
	# oversized generated blobs (git filter-repo), which changes the commit
	# hash of every commit downstream of the earliest one touched, including
	# this baseline tag's own target. A hardcoded SHA silently breaks across
	# any such rewrite (hit for real: the previous hardcoded f9dc10f594c...
	# stopped resolving to any object at all in the rewritten repo, and this
	# whole check failed with a confusing FAIL instead of a clear "commit not
	# found" error). The tag name itself is stable across the rewrite - git
	# filter-repo updates what it points to, not its name.
	#
	# 2026-08-14 (Phase 11 verification-gate fix): a hardcoded tag NAME goes
	# stale just as surely as a hardcoded SHA - this check silently compared
	# against nebulaos-display-baseline-vsync-pwm-sleep-2026-08-03 (2026-08-03)
	# for 11 days while five newer nebulaos-canonical-baseline-* tags were
	# accepted (through 2026-08-14-prtouch-qualified), so kernel.config's PASS
	# broke the moment any later-accepted variant touched it - a real Phase 9
	# fresh-build run hit exactly this, correctly reporting FAIL against a
	# baseline that was never wrong, just outdated. Every individual Kconfig
	# assertion in this same script still passed; only this byte-identical
	# check against a manually-bumped reference broke.
	#
	# Fix (2026-08-14): derived the reference from the most recently created
	# nebulaos-canonical-baseline-* tag instead of one fixed name, so this
	# check never needed a manual bump as new baselines were accepted - see
	# this same comment history in baseline-difference-gate.sh.
	#
	# Final Closure mission, Phase B (2026-08-15): "newest tag wins" is
	# better than a stale hardcoded name, but still implicit - a new
	# nebulaos-canonical-baseline-* tag silently becomes this check's
	# reference the moment it's pushed, with no deliberate promotion step
	# and no record in this script's own output of which tag a given run
	# actually verified against. One explicit value instead, in
	# manifests/dependencies.conf: QUALIFIED_BASELINE_TAG. Advancing the
	# qualified baseline is now a deliberate edit to that file, in its own
	# reviewed commit - not just pushing a tag.
	BASELINE_REF="${QUALIFIED_BASELINE_TAG:?QUALIFIED_BASELINE_TAG not set in $DEPS_MANIFEST}"
	git -C "$REPO_ROOT" rev-parse --verify -q "$BASELINE_REF" >/dev/null || {
		echo "FATAL: QUALIFIED_BASELINE_TAG='$BASELINE_REF' (from $DEPS_MANIFEST) does not exist in this checkout - fetch tags with 'git fetch --tags' first, or correct the manifest." >&2
		exit 1
	}
	echo "  == qualified baseline in use: $BASELINE_REF (from $DEPS_MANIFEST) =="
	# Phase 1.5 closure mission (2026-08-19): semantic, not byte-identical,
	# comparison for kernel.config/buildroot.config - see
	# scripts/build/lib/baseline-config-compare.sh's own header for the full
	# root-cause investigation. halley5_v30.dts gets no filter at all (still
	# strictly byte-identical) since nothing about it was ever found to be
	# provenance-only.
	. "$SCRIPT_DIR/lib/baseline-config-compare.sh"
	for f in kernel.config halley5_v30.dtb.dts buildroot.config; do
		artifact_path="$ARTIFACT_DIR/$f"
		if [ ! -f "$artifact_path" ]; then
			echo "  FAIL: $f is missing from $ARTIFACT_DIR - cannot compare"
			FAILED=1
			continue
		fi
		# set -eu is active in this script - a plain assignment from a
		# non-zero command substitution would abort immediately, so the
		# exit status is captured explicitly instead of relied on via $?.
		diff_rc=0
		diff_output=$(baseline_config_semantic_diff "$f" "$artifact_path" "$BASELINE_REF" "$REPO_ROOT" 2>&1) || diff_rc=$?
		if [ "$diff_rc" -eq 0 ]; then
			echo "  PASS: $f matches pinned baseline tag $BASELINE_REF (semantically - see scripts/build/lib/baseline-config-compare.sh for the narrow, named fields excluded from this comparison, if any)"
		elif [ "$diff_rc" -eq 1 ]; then
			echo "  FAIL: $f differs from pinned baseline tag $BASELINE_REF (real difference, not one of the named provenance-only fields):"
			echo "$diff_output" | sed "s/^/    /"
			FAILED=1
		else
			echo "  FAIL: could not compare $f against $BASELINE_REF: $diff_output"
			FAILED=1
		fi
	done
	# Recorded per section 8's own requirement: excluding a field from the
	# strict comparison must not make its current value disappear. Both are
	# also already independently recorded in build-manifest.txt's
	# kernel_config_sha256 (the FULL, unfiltered file hash, which still
	# changes with these fields and so still detects any tampering even
	# though it isn't used as a gate here).
	if [ -f "$ARTIFACT_DIR/kernel.config" ]; then
		echo "  == excluded-from-comparison field values (for the record, not gated) =="
		grep -E "^CONFIG_CC_VERSION_TEXT=|^CONFIG_EXTRA_FIRMWARE_DIR=" "$ARTIFACT_DIR/kernel.config" | sed "s/^/     /"
	fi
	if [ -f "$ARTIFACT_DIR/buildroot.config" ]; then
		grep -E "^# Buildroot .* Configuration\$|^BR2_HOST_GCC_AT_LEAST_[0-9]*=y\$" "$ARTIFACT_DIR/buildroot.config" | sed "s/^/     /"
	fi
	;;
*)
	echo "unknown mode '$MODE' - must be pre-build, post-build, or candidate-post-build" >&2
	exit 1
	;;
esac

if [ "$FAILED" = "1" ]; then
	echo "== Phase 2 assertions: FAILED - refusing to proceed =="
	exit 1
fi
echo "== Phase 2 assertions: all PASSED =="
