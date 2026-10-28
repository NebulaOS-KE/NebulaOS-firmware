#!/bin/sh
#
# Offline, repeatable tests for:
#   - scripts/build/overlay/etc/nebulaos-display-qualified.sh (the config
#     format, atomic writer, validator, and sysfs-apply logic, including
#     the touch_wake_mode field and the sleep/touch-wake watcher-starting
#     logic in ndq_apply_deferred_fields())
#   - scripts/build/overlay/etc/init.d/S97nebulaos-display-qualified-apply
#     (the health-gated boot-time wrapper around it, including the display-
#     itself health gate)
#   - scripts/build/overlay/usr/libexec/nebulaos-display-qualified-write
#     (the human-operator manual-write helper)
#
# The touch-wake watcher daemon's OWN tick/loop logic (nebulaos-display-
# sleep-wake-controller.sh / S98nebulaos-display-sleep-wake-controller) has
# its own, separate test file:
# tests/nebulaos-display-sleep-wake-controller-tests.sh - kept apart the
# same way tests/nebulaos-camera-idle-controller-tests.sh is kept apart
# from this file, rather than growing this already-large suite further.
#
# HONESTY NOTE (read before trusting a green run here as more than it is):
# there is no running kernel and no live BusyBox init system available
# from this environment. Every sysfs interaction below is a fake file
# tree, not a real ns2009_final_qualification/nebulaos_backlight_final_
# controller kernel driver - what these tests genuinely prove is this
# project's own userspace logic (parsing, checksum, validation ordering,
# the atomic-write durability sequence, the apply script's health-gating
# and abort-on-first-failure sequencing, and its real position in the
# init.d boot order). They do NOT and cannot prove the real kernel
# drivers behave as their patches document - only live hardware
# qualification can do that.
#
# Usage: sh tests/nebulaos-display-qualified-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-display-qualified.sh"
HEALTHCHECK_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-healthcheck.sh"
APPLY_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S97nebulaos-display-qualified-apply"
WRITE_HELPER="$REPO_ROOT/scripts/build/overlay/usr/libexec/nebulaos-display-qualified-write"
INITD_DIR="$REPO_ROOT/scripts/build/overlay/etc/init.d"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nebulaos-display-qualified-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: nebulaos-display-qualified-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

# G103 P4: S97 backgrounds its health wait + apply on a real boot; the
# scenarios below check its result right after it returns.
export NDQ_APPLY_FOREGROUND=1
export NBL_LIB="$WORK/no-backlight-lib"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$LIB" ] || { echo "FATAL: $LIB not found"; exit 1; }
[ -f "$HEALTHCHECK_LIB" ] || { echo "FATAL: $HEALTHCHECK_LIB not found"; exit 1; }
[ -f "$APPLY_SCRIPT" ] || { echo "FATAL: $APPLY_SCRIPT not found"; exit 1; }
[ -f "$WRITE_HELPER" ] || { echo "FATAL: $WRITE_HELPER not found"; exit 1; }

# ============================================================
# Fake sysfs tree - reset before each scenario that needs one.
# ============================================================
# Plain files stand in for the kernel attributes: a write lands as written
# and reads back as written. actual_brightness starts at 4 (the kernel
# reports boot-preserve as full); bl_power/brightness start empty so a test
# can tell "never written" apart from a write.
FAKE_KERNEL="$WORK/fakekernel"

reset_fake_kernel() {
	rm -rf "$FAKE_KERNEL"
	mkdir -p "$FAKE_KERNEL/i2c/0-0048/nebulaos_touch" "$FAKE_KERNEL/backlight"
	printf 'poll-only\n' > "$FAKE_KERNEL/i2c/0-0048/nebulaos_touch/mode"
	printf '0\n' > "$FAKE_KERNEL/i2c/0-0048/nebulaos_touch/touch_down_count"
	: > "$FAKE_KERNEL/backlight/bl_power"
	: > "$FAKE_KERNEL/backlight/brightness"
	printf '4\n' > "$FAKE_KERNEL/backlight/actual_brightness"
	NDQ_TOUCH_SYSFS="$FAKE_KERNEL/i2c/0-0048/nebulaos_touch"
	NDQ_BACKLIGHT_SYSFS="$FAKE_KERNEL/backlight"
	export NDQ_TOUCH_SYSFS NDQ_BACKLIGHT_SYSFS
}

# True when neither driver was written: touch mode still poll-only, no
# backlight write.
fake_untouched() {
	[ "$(cat "$NDQ_TOUCH_SYSFS/mode" 2>/dev/null)" = "poll-only" ] \
		&& [ ! -s "$NDQ_BACKLIGHT_SYSFS/bl_power" ] && [ ! -s "$NDQ_BACKLIGHT_SYSFS/brightness" ]
}

NDQ_CONFIG_DIR="$WORK/data/nebulaos"
NDQ_CONFIG_FILE="$NDQ_CONFIG_DIR/display-qualified.conf"
export NDQ_CONFIG_DIR NDQ_CONFIG_FILE
mkdir -p "$NDQ_CONFIG_DIR"

reset_fake_kernel
# shellcheck disable=SC1090
. "$LIB"

echo "============================================================"
echo "Config rendering / validation round-trips"
echo "============================================================"

# --- a minimal, valid, not-yet-qualified file (the real factory-shipped
# starting state: qualification_complete=0, everything else UNQUALIFIED
# or its inert default) validates structurally but reports "nothing to
# apply". ---
ndq_render_config > "$WORK/unqualified.conf"
if ndq_validate "$WORK/unqualified.conf" 2>/dev/null; then
	fail "an unqualified (qualification_complete=0) file was accepted as ready-to-apply"
else
	pass
fi
qc=$(ndq_get_field "$WORK/unqualified.conf" qualification_complete)
[ "$qc" = "0" ] && pass || fail "default-rendered qualification_complete was '$qc', expected 0"

# --- a fully valid, qualified poll-only + fixed-safe-on file. ---
ndq_render_config \
	qualification_complete=1 \
	touch_mode=poll-only touch_trigger=poll \
	release_stable_samples=3 idle_safety_poll_ms=250 touch_fallback_enabled=1 \
	backlight_mode=fixed-safe-on \
	qualified_at_utc=2026-08-02T00:00:00Z \
	> "$WORK/valid-pollonly-safeon.conf"
if ndq_validate "$WORK/valid-pollonly-safeon.conf"; then
	pass
else
	fail "a genuinely valid poll-only/fixed-safe-on config was rejected"
fi

# --- a fully valid, qualified irq-assist + pwm file. ---
ndq_render_config \
	qualification_complete=1 \
	touch_mode=irq-assist touch_trigger=pendown-gpio-edge \
	release_stable_samples=3 idle_safety_poll_ms=250 touch_fallback_enabled=1 \
	backlight_mode=pwm pwm_channel=0 pwm_period_ns=20000 pwm_polarity=normal \
	safe_brightness=50 minimum_brightness=25 off_value=0 \
	pc22_usage=unused \
	qualified_at_utc=2026-08-02T00:00:00Z \
	> "$WORK/valid-irqassist-pwm.conf"
if ndq_validate "$WORK/valid-irqassist-pwm.conf"; then
	pass
else
	fail "a genuinely valid irq-assist/pwm config was rejected"
fi

echo "============================================================"
echo "Checksum tamper rejection"
echo "============================================================"

cp "$WORK/valid-pollonly-safeon.conf" "$WORK/tampered.conf"
sed -i 's/backlight_mode=fixed-safe-on/backlight_mode=pwm/' "$WORK/tampered.conf"
if ndq_validate "$WORK/tampered.conf" 2>/dev/null; then
	fail "a config with a field edited after the checksum was computed was accepted"
else
	pass
fi

# A tampered checksum LINE itself (not just a data line) must also be
# rejected, not silently treated as "unset".
cp "$WORK/valid-pollonly-safeon.conf" "$WORK/badchecksum.conf"
sed -i 's/^checksum=.*/checksum=deadbeef/' "$WORK/badchecksum.conf"
if ndq_validate "$WORK/badchecksum.conf" 2>/dev/null; then
	fail "a config with an obviously-truncated checksum line was accepted"
else
	pass
fi

echo "============================================================"
echo "Version mismatch rejection"
echo "============================================================"

# Self-consistent (checksum matches its own content) but a format_version
# this system's validator does not understand - must be rejected on that
# basis specifically, not accidentally accepted just because the checksum
# happens to line up.
ndq_render_config format_version=2 qualification_complete=1 \
	touch_mode=poll-only touch_trigger=poll \
	release_stable_samples=3 idle_safety_poll_ms=250 touch_fallback_enabled=1 \
	backlight_mode=fixed-safe-on \
	> "$WORK/futureversion.conf"
if ndq_validate "$WORK/futureversion.conf" 2>/dev/null; then
	fail "a self-consistent but future-format_version config was accepted"
else
	pass
fi

echo "============================================================"
echo "Missing qualification_complete field -> safe default (not complete)"
echo "============================================================"

# Hand-build a self-consistent file that OMITS the qualification_complete
# line entirely (not just a wrong value) - a genuinely different failure
# mode from "field present but malformed", and the one the mission spec
# explicitly calls out.
{
	echo "format_version=1"
	echo "touch_mode=poll-only"
	echo "backlight_mode=fixed-safe-on"
	echo "sleep_enabled=0"
	echo "touch_wake_enabled=0"
	echo "first_touch_policy=not-implemented"
} > "$WORK/no-qc-body.txt"
csum=$(sha256sum "$WORK/no-qc-body.txt" | cut -d' ' -f1)
cat "$WORK/no-qc-body.txt" > "$WORK/no-qc.conf"
echo "checksum=$csum" >> "$WORK/no-qc.conf"

if ndq_validate "$WORK/no-qc.conf" 2>/dev/null; then
	fail "a config with no qualification_complete field at all was accepted"
else
	pass
fi
qc=$(ndq_get_field "$WORK/no-qc.conf" qualification_complete)
[ -z "$qc" ] && pass || fail "expected an absent qualification_complete field to read back empty, got '$qc'"

echo "============================================================"
echo "qualification_complete=1 but an actually-gating field left UNQUALIFIED"
echo "============================================================"

# touch_mode omitted (defaults to UNQUALIFIED) while claiming
# qualification_complete=1 - must never be accepted, this is exactly the
# "never persist/trust a value that wasn't actually tested" rule.
ndq_render_config qualification_complete=1 backlight_mode=fixed-safe-on \
	> "$WORK/claimed-but-untested-touch.conf"
if ndq_validate "$WORK/claimed-but-untested-touch.conf" 2>/dev/null; then
	fail "qualification_complete=1 with touch_mode left UNQUALIFIED was accepted"
else
	pass
fi

# backlight_mode=pwm claimed but safe_brightness left UNQUALIFIED.
ndq_render_config qualification_complete=1 \
	touch_mode=poll-only touch_trigger=poll \
	release_stable_samples=3 idle_safety_poll_ms=250 touch_fallback_enabled=1 \
	backlight_mode=pwm pwm_channel=0 pwm_period_ns=20000 pwm_polarity=normal \
	> "$WORK/claimed-pwm-no-brightness.conf"
if ndq_validate "$WORK/claimed-pwm-no-brightness.conf" 2>/dev/null; then
	fail "backlight_mode=pwm with safe_brightness left UNQUALIFIED was accepted"
else
	pass
fi

# A safe_brightness outside {25,50,75} (the only duty values the real
# driver's commands accept) must also be rejected.
ndq_render_config qualification_complete=1 \
	touch_mode=poll-only touch_trigger=poll \
	release_stable_samples=3 idle_safety_poll_ms=250 touch_fallback_enabled=1 \
	backlight_mode=pwm pwm_channel=0 pwm_period_ns=20000 pwm_polarity=normal \
	safe_brightness=60 \
	> "$WORK/bad-brightness.conf"
if ndq_validate "$WORK/bad-brightness.conf" 2>/dev/null; then
	fail "safe_brightness=60 (not one of 25/50/75) was accepted"
else
	pass
fi

echo "============================================================"
echo "touch_wake_mode field validation"
echo "============================================================"

# --- default-rendered file: touch_wake_mode=disabled, touch_wake_enabled=0
# - consistent, structurally valid (even though qualification_complete=0
# means "nothing to apply" is still the overall verdict). ---
ndq_render_config > "$WORK/twm-default.conf"
twm=$(ndq_get_field "$WORK/twm-default.conf" touch_wake_mode)
[ "$twm" = "disabled" ] && pass || fail "default-rendered touch_wake_mode was '$twm', expected disabled"

# --- touch_wake_mode=polling with the consistent touch_wake_enabled=1,
# folded into an otherwise-fully-qualified config, is accepted end to end
# (proves the consistency check doesn't block a genuinely valid file). ---
ndq_render_config \
	qualification_complete=1 \
	touch_mode=poll-only touch_trigger=poll \
	release_stable_samples=3 idle_safety_poll_ms=250 touch_fallback_enabled=1 \
	backlight_mode=fixed-safe-on \
	touch_wake_mode=polling touch_wake_enabled=1 sleep_enabled=1 \
	> "$WORK/twm-polling-consistent.conf"
if ndq_validate "$WORK/twm-polling-consistent.conf"; then
	pass
else
	fail "a fully valid, qualified file with touch_wake_mode=polling/touch_wake_enabled=1 was rejected"
fi

# --- touch_wake_mode=disabled with touch_wake_enabled=0 (the default
# pairing), likewise folded into a fully-qualified config, is accepted. ---
ndq_render_config \
	qualification_complete=1 \
	touch_mode=poll-only touch_trigger=poll \
	release_stable_samples=3 idle_safety_poll_ms=250 touch_fallback_enabled=1 \
	backlight_mode=fixed-safe-on \
	touch_wake_mode=disabled touch_wake_enabled=0 \
	> "$WORK/twm-disabled-consistent.conf"
if ndq_validate "$WORK/twm-disabled-consistent.conf"; then
	pass
else
	fail "a fully valid, qualified file with touch_wake_mode=disabled/touch_wake_enabled=0 was rejected"
fi

# --- an unrecognized touch_wake_mode value is rejected outright. ---
ndq_render_config touch_wake_mode=always-on touch_wake_enabled=1 \
	> "$WORK/twm-garbage.conf"
if ndq_validate "$WORK/twm-garbage.conf" 2>/dev/null; then
	fail "touch_wake_mode=always-on (not polling/disabled) was accepted"
else
	pass
fi

# --- touch_wake_mode=polling but touch_wake_enabled left at its default
# (0) - the two fields disagree, must be rejected. ---
ndq_render_config touch_wake_mode=polling > "$WORK/twm-polling-inconsistent.conf"
if ndq_validate "$WORK/twm-polling-inconsistent.conf" 2>/dev/null; then
	fail "touch_wake_mode=polling with touch_wake_enabled=0 (disagreeing fields) was accepted"
else
	pass
fi

# --- touch_wake_mode=disabled but touch_wake_enabled=1 - also disagreeing,
# also rejected. ---
ndq_render_config touch_wake_mode=disabled touch_wake_enabled=1 \
	> "$WORK/twm-disabled-inconsistent.conf"
if ndq_validate "$WORK/twm-disabled-inconsistent.conf" 2>/dev/null; then
	fail "touch_wake_mode=disabled with touch_wake_enabled=1 (disagreeing fields) was accepted"
else
	pass
fi

echo "============================================================"
echo "off_value stays legitimately UNQUALIFIED even with sleep_enabled=1"
echo "============================================================"

# Sleep in this system is GPC0-GPIO-off, not a PWM duty (see
# docs/NEBULAOS_ONE_FLASH_DISPLAY_FINAL_REPORT.md) - a fully valid,
# qualified config with sleep_enabled=1 and off_value left at its
# UNQUALIFIED default must validate successfully; off_value must never be
# required just because sleep_enabled=1.
ndq_render_config \
	qualification_complete=1 \
	touch_mode=poll-only touch_trigger=poll \
	release_stable_samples=3 idle_safety_poll_ms=250 touch_fallback_enabled=1 \
	backlight_mode=fixed-safe-on \
	sleep_enabled=1 touch_wake_enabled=1 touch_wake_mode=polling \
	qualified_at_utc=2026-08-02T00:00:00Z \
	> "$WORK/sleep-enabled-off-value-unqualified.conf"
if ndq_validate "$WORK/sleep-enabled-off-value-unqualified.conf"; then
	pass
else
	fail "a fully valid config with sleep_enabled=1 and off_value left UNQUALIFIED was rejected"
fi
ov=$(ndq_get_field "$WORK/sleep-enabled-off-value-unqualified.conf" off_value)
[ "$ov" = "UNQUALIFIED" ] && pass || fail "off_value was '$ov', expected UNQUALIFIED to have round-tripped unchanged"

echo "============================================================"
echo "ndq_apply_deferred_fields - starts the sleep/wake watcher"
echo "============================================================"

FAKE_INITD_LOG="$WORK/sleep-wake-initd-invocations.log"
FAKE_INITD="$WORK/fake-s98"
cat > "$FAKE_INITD" <<EOF
#!/bin/sh
echo "\$*" >> "$FAKE_INITD_LOG"
exit 0
EOF
chmod +x "$FAKE_INITD"

# --- sleep_enabled=1 + touch_wake_mode=polling -> the watcher's init.d
# script IS invoked with "start". ---
: > "$FAKE_INITD_LOG"
NDQ_SLEEP_WAKE_INITD="$FAKE_INITD" ndq_apply_deferred_fields 1 1 polling not-implemented >/dev/null 2>&1
if [ -s "$FAKE_INITD_LOG" ] && grep -q '^start$' "$FAKE_INITD_LOG"; then
	pass
else
	fail "sleep_enabled=1/touch_wake_mode=polling did not invoke the watcher's init.d script with 'start' (log: $(cat "$FAKE_INITD_LOG" 2>/dev/null))"
fi

# --- sleep_enabled=0 -> the watcher must NOT be started, regardless of
# touch_wake_mode. ---
: > "$FAKE_INITD_LOG"
NDQ_SLEEP_WAKE_INITD="$FAKE_INITD" ndq_apply_deferred_fields 0 1 polling not-implemented >/dev/null 2>&1
[ ! -s "$FAKE_INITD_LOG" ] && pass \
	|| fail "sleep_enabled=0 still invoked the watcher's init.d script (log: $(cat "$FAKE_INITD_LOG" 2>/dev/null))"

# --- sleep_enabled=1 but touch_wake_mode=disabled -> also must NOT start
# (sleep available, but touch-wake specifically is not). ---
: > "$FAKE_INITD_LOG"
NDQ_SLEEP_WAKE_INITD="$FAKE_INITD" ndq_apply_deferred_fields 1 0 disabled not-implemented >/dev/null 2>&1
[ ! -s "$FAKE_INITD_LOG" ] && pass \
	|| fail "sleep_enabled=1/touch_wake_mode=disabled still invoked the watcher's init.d script (log: $(cat "$FAKE_INITD_LOG" 2>/dev/null))"

# --- ndq_apply_all end-to-end: a fully valid, fully qualified config with
# sleep_enabled=1/touch_wake_mode=polling actually starts the watcher as
# part of a real apply_all run, without affecting apply_all's own success. ---
reset_fake_kernel
: > "$FAKE_INITD_LOG"
ndq_render_config qualification_complete=1 touch_mode=irq-assist touch_trigger=pendown-gpio-edge \
	release_stable_samples=3 idle_safety_poll_ms=250 touch_fallback_enabled=1 \
	backlight_mode=fixed-safe-on \
	sleep_enabled=1 touch_wake_enabled=1 touch_wake_mode=polling \
	> "$NDQ_CONFIG_FILE"
if NDQ_SLEEP_WAKE_INITD="$FAKE_INITD" ndq_apply_all "$NDQ_CONFIG_FILE"; then
	pass
else
	fail "apply_all failed against a valid sleep-enabled config with a working fake watcher starter"
fi
grep -q '^start$' "$FAKE_INITD_LOG" 2>/dev/null && pass \
	|| fail "apply_all (via apply_deferred_fields) did not start the watcher end-to-end (log: $(cat "$FAKE_INITD_LOG" 2>/dev/null))"

echo "============================================================"
echo "Atomic write - normal case"
echo "============================================================"

TARGET="$WORK/atomic/target.conf"
mkdir -p "$(dirname "$TARGET")"
ndq_render_config qualification_complete=0 | ndq_atomic_write "$TARGET"
if [ -f "$TARGET" ] && grep -q '^qualification_complete=0$' "$TARGET"; then
	pass
else
	fail "atomic write did not produce the expected target file content"
fi
# No stray temp files should be left behind after a clean write.
leftover=$(find "$(dirname "$TARGET")" -maxdepth 1 -name '.tmp.*' 2>/dev/null)
[ -z "$leftover" ] && pass || fail "a temp file was left behind after a successful atomic write: $leftover"

echo "============================================================"
echo "Atomic write - simulated interruption never leaves a torn file"
echo "============================================================"

# Seed a real "previous" file first, so we can prove a killed write
# leaves it EXACTLY as it was (not just "leaves something").
PREV_TARGET="$WORK/atomic/interrupt-target.conf"
ndq_render_config qualification_complete=0 touch_mode=poll-only > "$PREV_TARGET"
prev_content=$(cat "$PREV_TARGET")
prev_sum=$(sha256sum "$PREV_TARGET" | cut -d' ' -f1)

# A fake `dd` that sleeps long enough for the test to kill it mid-write,
# after having already written SOME bytes to the temp file - the
# realistic "killed partway through" scenario, not just "killed before
# anything happened".
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/dd" <<'EOF'
#!/bin/sh
of=""
for arg in "$@"; do
	case "$arg" in
		of=*) of="${arg#of=}" ;;
	esac
done
# Write a deliberately truncated, WRONG prefix (never the real new
# content in full) then hang, so a kill -9 here can never race a
# legitimate fast completion - the test's assertion is meaningful only if
# the process is still not done when killed.
printf 'THIS-IS-A-TORN-PARTIAL-WRITE-NEVER-A-VALID-CONFIG' > "$of"
sleep 5
EOF
chmod +x "$FAKE_BIN/dd"

(
	PATH="$FAKE_BIN:$PATH"
	export PATH
	ndq_render_config qualification_complete=1 touch_mode=irq-assist touch_trigger=pendown-gpio-edge \
		release_stable_samples=3 idle_safety_poll_ms=250 touch_fallback_enabled=1 \
		backlight_mode=fixed-safe-on | ndq_atomic_write "$PREV_TARGET"
) &
writer_pid=$!

# Give the fake dd time to start and write its partial content, then kill
# the whole writer subshell tree before it ever reaches `mv`.
sleep 1
kill -9 "$writer_pid" 2>/dev/null
# Also kill any fake-dd child directly (subshell kill doesn't always take
# its children with it) - belt and suspenders so this test can't pass by
# accident of timing.
pkill -9 -f "$FAKE_BIN/dd" 2>/dev/null
wait "$writer_pid" 2>/dev/null

new_sum=$(sha256sum "$PREV_TARGET" | cut -d' ' -f1)
new_content=$(cat "$PREV_TARGET")
if [ "$new_sum" = "$prev_sum" ] && [ "$new_content" = "$prev_content" ]; then
	pass
else
	fail "the real target file changed after the writer was killed mid-write (expected it untouched) - got: $new_content"
fi
case "$new_content" in
	*TORN-PARTIAL-WRITE*)
		fail "the target file was left containing the torn partial write - atomicity was violated"
		;;
	*) pass ;;
esac

echo "============================================================"
echo "ndq_apply_touch"
echo "============================================================"

reset_fake_kernel
if ndq_apply_touch poll-only; then
	pass
else
	fail "touch_mode=poll-only (the boot default) should always succeed as a no-op"
fi
fake_untouched && pass || fail "touch_mode=poll-only wrote something to the mode file when it should have been a pure no-op"

reset_fake_kernel
if ndq_apply_touch irq-assist; then
	pass
else
	fail "irq-assist apply failed even though the sysfs mode file reads back irq-assist"
fi
[ "$(cat "$NDQ_TOUCH_SYSFS/mode")" = "irq-assist" ] && pass || fail "wrong bytes written to the touch sysfs mode file"

# Readback mismatch: the write is accepted but the mode file does not read
# back "irq-assist" (here: /dev/null, which reads back empty) -> failure.
reset_fake_kernel
ln -sf /dev/null "$NDQ_TOUCH_SYSFS/mode"
if ndq_apply_touch irq-assist 2>/dev/null; then
	fail "irq-assist apply reported success even though the mode file never read back irq-assist"
else
	pass
fi

reset_fake_kernel
rm -f "$NDQ_TOUCH_SYSFS/mode"
if ndq_apply_touch irq-assist 2>/dev/null; then
	fail "irq-assist apply reported success when the sysfs mode file does not exist at all"
else
	pass
fi

# No nebulaos_touch directory found at all (NDQ_TOUCH_SYSFS empty).
reset_fake_kernel
if NDQ_TOUCH_SYSFS="" ndq_apply_touch irq-assist 2>/dev/null; then
	fail "irq-assist apply reported success with no touch sysfs directory"
else
	pass
fi

echo "============================================================"
echo "ndq_apply_backlight"
echo "============================================================"

reset_fake_kernel
if ndq_apply_backlight fixed-safe-on UNQUALIFIED; then
	pass
else
	fail "fixed-safe-on apply failed even though actual_brightness confirms 4"
fi
[ "$(cat "$NDQ_BACKLIGHT_SYSFS/bl_power")" = "0" ] && [ "$(cat "$NDQ_BACKLIGHT_SYSFS/brightness")" = "4" ] && pass \
	|| fail "fixed-safe-on apply did not write bl_power=0 and brightness=4"

# Readback failure: the kernel does not report full -> failure.
reset_fake_kernel
printf '0\n' > "$NDQ_BACKLIGHT_SYSFS/actual_brightness"
if ndq_apply_backlight fixed-safe-on UNQUALIFIED 2>/dev/null; then
	fail "fixed-safe-on apply reported success even though actual_brightness reads 0"
else
	pass
fi
reset_fake_kernel
rm -f "$NDQ_BACKLIGHT_SYSFS/actual_brightness"
if ndq_apply_backlight pwm 50 2>/dev/null; then
	fail "pwm apply reported success even though actual_brightness is unreadable"
else
	pass
fi

# Missing class device -> failure, nothing written anywhere.
reset_fake_kernel
rm -rf "$NDQ_BACKLIGHT_SYSFS"
if ndq_apply_backlight fixed-safe-on UNQUALIFIED 2>/dev/null; then
	fail "backlight apply reported success with no backlight class device"
else
	pass
fi
[ ! -e "$NDQ_BACKLIGHT_SYSFS" ] && pass || fail "backlight apply created files although the class device is missing"

# pwm mode: same safe-on convergence, no demo pulse, never a value other
# than 4 written to brightness.
reset_fake_kernel
if ndq_apply_backlight pwm 50 > "$WORK/apply-pwm.out" 2>&1; then
	pass
else
	fail "pwm apply at 50% failed even though actual_brightness confirms 4"
fi
[ "$(cat "$NDQ_BACKLIGHT_SYSFS/brightness")" = "4" ] && pass || fail "pwm apply wrote brightness '$(cat "$NDQ_BACKLIGHT_SYSFS/brightness")', expected 4"
grep -q 'restored later by S98' "$WORK/apply-pwm.out" && ! grep -q 'pwm-active' "$WORK/apply-pwm.out" && pass \
	|| fail "pwm apply did not log the S98 restore hand-off, or still mentions a pwm-active pulse: $(cat "$WORK/apply-pwm.out")"

echo "============================================================"
echo "ndq_apply_all - end-to-end against the fake sysfs tree"
echo "============================================================"

# --- missing config file -> no mutation at all. ---
reset_fake_kernel
rm -f "$NDQ_CONFIG_FILE"
if ndq_apply_all "$NDQ_CONFIG_FILE" 2>/dev/null; then
	fail "apply_all reported success with no config file present"
else
	pass
fi
fake_untouched && pass \
	|| fail "apply_all mutated a sysfs file even though the config file was entirely missing"

# --- corrupt (tampered checksum) config file -> no mutation at all. ---
reset_fake_kernel
ndq_render_config qualification_complete=1 touch_mode=irq-assist touch_trigger=pendown-gpio-edge \
	release_stable_samples=3 idle_safety_poll_ms=250 touch_fallback_enabled=1 \
	backlight_mode=fixed-safe-on > "$NDQ_CONFIG_FILE"
sed -i 's/touch_mode=irq-assist/touch_mode=poll-only/' "$NDQ_CONFIG_FILE"
if ndq_apply_all "$NDQ_CONFIG_FILE" 2>/dev/null; then
	fail "apply_all reported success against a checksum-tampered config file"
else
	pass
fi
fake_untouched && pass \
	|| fail "apply_all mutated a sysfs file even though the config file was corrupt"

# --- valid config, but the touch sysfs mode file is missing (simulating a
# kernel build without the qualification driver) -> touch fails, and
# critically the backlight must be left ENTIRELY untouched too (this
# script's own abort-on-first-failure design - see ndq_apply_all's own
# comment for why partial application across the two drivers is refused
# even though each driver's OWN boot default is independently safe). ---
reset_fake_kernel
rm -f "$NDQ_TOUCH_SYSFS/mode"
ndq_render_config qualification_complete=1 touch_mode=irq-assist touch_trigger=pendown-gpio-edge \
	release_stable_samples=3 idle_safety_poll_ms=250 touch_fallback_enabled=1 \
	backlight_mode=fixed-safe-on > "$NDQ_CONFIG_FILE"
if ndq_apply_all "$NDQ_CONFIG_FILE" 2>/dev/null; then
	fail "apply_all reported success even though the touch sysfs mode file does not exist"
else
	pass
fi
[ ! -s "$NDQ_BACKLIGHT_SYSFS/bl_power" ] && [ ! -s "$NDQ_BACKLIGHT_SYSFS/brightness" ] && pass \
	|| fail "backlight was mutated even though the earlier touch apply step failed - abort-on-first-failure ordering was violated"

# --- fully valid config, fully healthy fake driver tree -> full success,
# both drivers actually mutated as expected. ---
reset_fake_kernel
ndq_render_config qualification_complete=1 touch_mode=irq-assist touch_trigger=pendown-gpio-edge \
	release_stable_samples=3 idle_safety_poll_ms=250 touch_fallback_enabled=1 \
	backlight_mode=pwm pwm_channel=0 pwm_period_ns=20000 pwm_polarity=normal safe_brightness=75 \
	> "$NDQ_CONFIG_FILE"
if ndq_apply_all "$NDQ_CONFIG_FILE"; then
	pass
else
	fail "apply_all failed against a fully valid config and a fully healthy fake driver tree"
fi
[ "$(cat "$NDQ_TOUCH_SYSFS/mode")" = "irq-assist" ] && pass || fail "end-to-end apply_all did not write irq-assist to the touch mode file"
[ "$(cat "$NDQ_BACKLIGHT_SYSFS/brightness")" = "4" ] && [ "$(cat "$NDQ_BACKLIGHT_SYSFS/bl_power")" = "0" ] && pass \
	|| fail "end-to-end apply_all did not converge the backlight to bl_power=0 brightness=4"

echo "============================================================"
echo "Write helper (usr/libexec/nebulaos-display-qualified-write)"
echo "============================================================"

rm -f "$NDQ_CONFIG_FILE"
if NDQ_LIB="$LIB" sh "$WRITE_HELPER" \
	qualification_complete=1 \
	touch_mode=poll-only touch_trigger=poll \
	release_stable_samples=3 idle_safety_poll_ms=250 touch_fallback_enabled=1 \
	backlight_mode=fixed-safe-on >/dev/null 2>&1
then
	pass
else
	fail "write helper refused a genuinely valid set of fields"
fi
[ -f "$NDQ_CONFIG_FILE" ] && ndq_validate "$NDQ_CONFIG_FILE" && pass \
	|| fail "write helper did not leave a validate-able config file behind"

# An invalid set of fields must be refused, and must NOT clobber a
# previously-good file.
good_content=$(cat "$NDQ_CONFIG_FILE")
if NDQ_LIB="$LIB" sh "$WRITE_HELPER" qualification_complete=1 backlight_mode=pwm >/dev/null 2>&1; then
	fail "write helper accepted an invalid set of fields (backlight_mode=pwm with no safe_brightness)"
else
	pass
fi
[ "$(cat "$NDQ_CONFIG_FILE")" = "$good_content" ] && pass \
	|| fail "a failed write helper invocation clobbered the previously-good config file"

echo "============================================================"
echo "init.d dependency ordering (a real test, not eyeballing)"
echo "============================================================"

# BusyBox's own init runs /etc/init.d/S* in plain lexicographic (string)
# order - reproduce that exact ordering here and assert this script's
# real position relative to Klipper/Moonraker/GuppyScreen and the two
# existing terminal gates.
sorted=$(cd "$INITD_DIR" && ls -1 | sort)
index_of() {
	printf '%s\n' "$sorted" | grep -n "^$1\$" | cut -d: -f1
}
i_klipper=$(index_of S55klipper)
i_moonraker=$(index_of S56moonraker)
i_guppy=$(index_of S58nebulascreen)
i_mcurecovery=$(index_of S95mcu-boot-recovery)
i_ours=$(index_of S97nebulaos-display-qualified-apply)
i_sleepwake=$(index_of S98nebulaos-display-sleep-wake-controller)
i_confirmgood=$(index_of S99confirm-good)

for name_idx in "i_klipper:$i_klipper" "i_moonraker:$i_moonraker" "i_guppy:$i_guppy" \
	"i_mcurecovery:$i_mcurecovery" "i_ours:$i_ours" "i_sleepwake:$i_sleepwake" "i_confirmgood:$i_confirmgood"; do
	val=${name_idx#*:}
	if [ -z "$val" ]; then
		fail "could not find expected init.d script for $name_idx - has the tree changed?"
	fi
done

if [ -n "$i_klipper" ] && [ -n "$i_moonraker" ] && [ -n "$i_guppy" ] && [ -n "$i_ours" ] && [ -n "$i_confirmgood" ]; then
	if [ "$i_ours" -gt "$i_klipper" ] && [ "$i_ours" -gt "$i_moonraker" ] && [ "$i_ours" -gt "$i_guppy" ]; then
		pass
	else
		fail "S97nebulaos-display-qualified-apply does not sort strictly after S55klipper/S56moonraker/S58nebulascreen"
	fi
	if [ -n "$i_mcurecovery" ] && [ "$i_ours" -gt "$i_mcurecovery" ]; then
		pass
	else
		fail "S97nebulaos-display-qualified-apply does not sort strictly after S95mcu-boot-recovery"
	fi
	if [ "$i_ours" -lt "$i_confirmgood" ]; then
		pass
	else
		fail "S97nebulaos-display-qualified-apply does not sort strictly before S99confirm-good"
	fi
fi

if [ -n "$i_ours" ] && [ -n "$i_sleepwake" ] && [ -n "$i_confirmgood" ]; then
	if [ "$i_sleepwake" -gt "$i_ours" ]; then
		pass
	else
		fail "S98nebulaos-display-sleep-wake-controller does not sort strictly after S97nebulaos-display-qualified-apply"
	fi
	if [ "$i_sleepwake" -lt "$i_confirmgood" ]; then
		pass
	else
		fail "S98nebulaos-display-sleep-wake-controller does not sort strictly before S99confirm-good"
	fi
fi

echo "============================================================"
echo "S97 script end-to-end (faked wget/ip/PATH, faked PIDFILE, faked marker)"
echo "============================================================"

FAKE_ETC="$WORK/fake-etc-bin"
mkdir -p "$FAKE_ETC"

cat > "$FAKE_ETC/wget" <<'EOF'
#!/bin/sh
# Minimal fake of BusyBox wget, just enough for
# nebulaos-healthcheck.sh's stage2_stack() to see a fully healthy stack.
for arg in "$@"; do
	case "$arg" in
		*/server/info)
			echo '{"result":{"klippy_state":"ready","klippy_connected":true,"failed_components":[]}}'
			exit 0
			;;
		*/printer/info)
			echo '{"result":{"state_message":"Printer is ready"}}'
			exit 0
			;;
		*/printer/objects/query*)
			echo '{"result":{"status":{"heater_bed":{"target":0.0},"extruder":{"target":0.0},"print_stats":{"state":"standby"}}}}'
			exit 0
			;;
	esac
done
exit 1
EOF
chmod +x "$FAKE_ETC/wget"

cat > "$FAKE_ETC/ip" <<'EOF'
#!/bin/sh
# Minimal fake of the real iproute2 `ip` this image ships. Only the exact
# invocation S97 itself uses is implemented.
case "$*" in
	"-4 -o addr show scope global")
		echo '2: eth0    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0'
		;;
esac
exit 0
EOF
chmod +x "$FAKE_ETC/ip"

GUPPY_PIDFILE="$WORK/guppyscreen.pid"
echo $$ > "$GUPPY_PIDFILE"	# our own test process - guaranteed to exist

reset_fake_kernel
ndq_render_config qualification_complete=1 touch_mode=irq-assist touch_trigger=pendown-gpio-edge \
	release_stable_samples=3 idle_safety_poll_ms=250 touch_fallback_enabled=1 \
	backlight_mode=fixed-safe-on > "$NDQ_CONFIG_FILE"

MARKER_HEALTHY="$WORK/marker-healthy"
(
	PATH="$FAKE_ETC:$PATH"
	export PATH
	NDQ_LIB="$LIB" NDQ_HEALTHCHECK_LIB="$HEALTHCHECK_LIB" \
	MARKER="$MARKER_HEALTHY" NEBULASCREEN_PIDFILE="$GUPPY_PIDFILE" \
	HEALTH_RETRIES=2 HEALTH_DELAY=0 \
	NDQ_CONFIG_FILE="$NDQ_CONFIG_FILE" \
	NDQ_TOUCH_SYSFS="$NDQ_TOUCH_SYSFS" NDQ_BACKLIGHT_SYSFS="$NDQ_BACKLIGHT_SYSFS" \
	sh "$APPLY_SCRIPT" start
)
rc=$?
[ "$rc" -eq 0 ] && pass || fail "S97 start (healthy path) exited $rc, expected 0"
[ "$(cat "$NDQ_BACKLIGHT_SYSFS/brightness")" = "4" ] && [ "$(cat "$NDQ_TOUCH_SYSFS/mode")" = "irq-assist" ] && pass \
	|| fail "S97 end-to-end healthy run did not actually apply the qualified display config"
[ -f "$MARKER_HEALTHY" ] && pass || fail "S97 did not create its once-per-boot marker"

# G103 P4: on a real boot S97 runs in the background and S98 has already
# restored the user's brightness, so after its apply S97 restores it again
# (ndq_apply_backlight leaves safe-on); by default start returns at once.
printf 'nbl_boot_restore() { echo restored > "%s/restored"; echo 2 > "%s/brightness"; }\n' \
	"$WORK" "$NDQ_BACKLIGHT_SYSFS" > "$WORK/fake-backlight-lib"
reset_fake_kernel
rm -f "$WORK/restored" "$WORK/marker-bg"
s0=$(date +%s)
(
	PATH="$FAKE_ETC:$PATH"
	export PATH
	NDQ_APPLY_FOREGROUND=0 NBL_LIB="$WORK/fake-backlight-lib" \
	NDQ_LIB="$LIB" NDQ_HEALTHCHECK_LIB="$HEALTHCHECK_LIB" \
	MARKER="$WORK/marker-bg" NEBULASCREEN_PIDFILE="$GUPPY_PIDFILE" \
	HEALTH_RETRIES=2 HEALTH_DELAY=0 \
	NDQ_CONFIG_FILE="$NDQ_CONFIG_FILE" \
	NDQ_TOUCH_SYSFS="$NDQ_TOUCH_SYSFS" NDQ_BACKLIGHT_SYSFS="$NDQ_BACKLIGHT_SYSFS" \
	sh "$APPLY_SCRIPT" start >/dev/null 2>&1
)
rc=$?; s1=$(date +%s)
[ "$rc" -eq 0 ] && [ $((s1 - s0)) -le 2 ] && pass || fail "S97 default start did not return at once (rc=$rc)"
n=0; while [ ! -f "$WORK/restored" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
[ -f "$WORK/restored" ] && [ "$(cat "$NDQ_BACKLIGHT_SYSFS/brightness")" = "2" ] && pass \
	|| fail "S97 background apply did not restore the user's brightness after safe-on"

# Second invocation with the marker already present must be a pure no-op
# (skips even the health poll) - overwrite brightness with a sentinel
# first so we can prove nothing touched it again.
echo "SENTINEL-UNTOUCHED" > "$NDQ_BACKLIGHT_SYSFS/brightness"
(
	PATH="$FAKE_ETC:$PATH"
	export PATH
	NDQ_LIB="$LIB" NDQ_HEALTHCHECK_LIB="$HEALTHCHECK_LIB" \
	MARKER="$MARKER_HEALTHY" NEBULASCREEN_PIDFILE="$GUPPY_PIDFILE" \
	HEALTH_RETRIES=2 HEALTH_DELAY=0 \
	NDQ_CONFIG_FILE="$NDQ_CONFIG_FILE" \
	NDQ_TOUCH_SYSFS="$NDQ_TOUCH_SYSFS" NDQ_BACKLIGHT_SYSFS="$NDQ_BACKLIGHT_SYSFS" \
	sh "$APPLY_SCRIPT" start
)
[ "$(cat "$NDQ_BACKLIGHT_SYSFS/brightness")" = "SENTINEL-UNTOUCHED" ] && pass \
	|| fail "S97's once-per-boot marker did not prevent a second apply attempt"

# --- unhealthy path: GuppyScreen "not running" (a PID that doesn't
# exist) -> S97 must exit 0 and must NOT touch either driver. ---
reset_fake_kernel
echo 999999999 > "$GUPPY_PIDFILE"	# almost certainly not a real PID
MARKER_UNHEALTHY="$WORK/marker-unhealthy"
(
	PATH="$FAKE_ETC:$PATH"
	export PATH
	NDQ_LIB="$LIB" NDQ_HEALTHCHECK_LIB="$HEALTHCHECK_LIB" \
	MARKER="$MARKER_UNHEALTHY" NEBULASCREEN_PIDFILE="$GUPPY_PIDFILE" \
	HEALTH_RETRIES=1 HEALTH_DELAY=0 \
	NDQ_CONFIG_FILE="$NDQ_CONFIG_FILE" \
	NDQ_TOUCH_SYSFS="$NDQ_TOUCH_SYSFS" NDQ_BACKLIGHT_SYSFS="$NDQ_BACKLIGHT_SYSFS" \
	sh "$APPLY_SCRIPT" start
)
rc=$?
[ "$rc" -eq 0 ] && pass || fail "S97 start (unhealthy GuppyScreen) exited $rc, expected 0 (fail-safe, not a boot-halting error)"
fake_untouched && pass \
	|| fail "S97 mutated a sysfs file even though NebulaScreen was never confirmed running"

# --- unhealthy path: the display itself never confirms healthy (backlight
# actual_brightness missing entirely, e.g. a kernel build without the
# driver) - S97 must exit 0 and must NOT touch either driver, even
# though Klipper/Moonraker/GuppyScreen/networking are all otherwise fully
# healthy. ---
reset_fake_kernel
echo $$ > "$GUPPY_PIDFILE"
rm -f "$NDQ_BACKLIGHT_SYSFS/actual_brightness"
MARKER_NODISPLAY="$WORK/marker-nodisplay"
(
	PATH="$FAKE_ETC:$PATH"
	export PATH
	NDQ_LIB="$LIB" NDQ_HEALTHCHECK_LIB="$HEALTHCHECK_LIB" \
	MARKER="$MARKER_NODISPLAY" NEBULASCREEN_PIDFILE="$GUPPY_PIDFILE" \
	HEALTH_RETRIES=1 HEALTH_DELAY=0 \
	NDQ_CONFIG_FILE="$NDQ_CONFIG_FILE" \
	NDQ_TOUCH_SYSFS="$NDQ_TOUCH_SYSFS" NDQ_BACKLIGHT_SYSFS="$NDQ_BACKLIGHT_SYSFS" \
	sh "$APPLY_SCRIPT" start
)
rc=$?
[ "$rc" -eq 0 ] && pass || fail "S97 start (missing actual_brightness) exited $rc, expected 0 (fail-safe, not a boot-halting error)"
fake_untouched && pass \
	|| fail "S97 mutated a sysfs file even though the display's own actual_brightness was never confirmed readable"

# --- S2 (2026-10-05): no qualification_complete=1 config -> S97 exits at
# once, before the health wait (65 s per boot on ke-dev before), touching
# nothing. Health is made to fail and the real 20 x 3 s budget is kept, so a
# case that wrongly reaches wait_for_health would take 60 s, not < 2 s. ---
reset_fake_kernel
echo 999999999 > "$GUPPY_PIDFILE"
S2_CONF="$WORK/s2-display-qualified.conf"
s2_run() { # marker -> rc; elapsed seconds in S2_SECS
	_t0=$(date +%s)
	(
		PATH="$FAKE_ETC:$PATH"
		export PATH
		NDQ_LIB="$LIB" NDQ_HEALTHCHECK_LIB="$HEALTHCHECK_LIB" \
		MARKER="$1" NEBULASCREEN_PIDFILE="$GUPPY_PIDFILE" \
		HEALTH_RETRIES="${S2_RETRIES:-20}" HEALTH_DELAY="${S2_DELAY:-3}" \
		NDQ_CONFIG_FILE="$S2_CONF" \
		NDQ_TOUCH_SYSFS="$NDQ_TOUCH_SYSFS" NDQ_BACKLIGHT_SYSFS="$NDQ_BACKLIGHT_SYSFS" \
		sh "$APPLY_SCRIPT" start
	) > "$WORK/s2.out" 2>&1
	_rc=$?
	S2_SECS=$(( $(date +%s) - _t0 ))
	return $_rc
}
for c in absent qc0 malformed emptyvalue emptyfile last0; do
	rm -f "$S2_CONF"
	case $c in
	absent) ;;
	qc0) ndq_render_config qualification_complete=0 > "$S2_CONF" ;;
	malformed) printf 'this is not a config\n\001\002\n' > "$S2_CONF" ;;
	emptyvalue) printf 'qualification_complete=\n' > "$S2_CONF" ;;
	emptyfile) : > "$S2_CONF" ;;
	last0) printf 'qualification_complete=1\nqualification_complete=0\n' > "$S2_CONF" ;;
	esac
	s2_run "$WORK/s2-marker-$c"; rc=$?
	[ "$rc" -eq 0 ] && [ "$S2_SECS" -le 2 ] && pass || fail "S2 $c: rc=$rc took ${S2_SECS}s (expected immediate exit 0)"
	grep -q 'nothing to apply' "$WORK/s2.out" && ! grep -q 'never confirmed healthy' "$WORK/s2.out" && pass \
		|| fail "S2 $c: did not take the fast exit: $(cat "$WORK/s2.out")"
	fake_untouched && pass || fail "S2 $c: a display sysfs file was written"
	[ -f "$WORK/s2-marker-$c" ] && pass || fail "S2 $c: once-per-boot marker not created"
done
# qualification_complete=1 (last value wins) still goes through the health gates
printf 'qualification_complete=0\n' > "$S2_CONF"
ndq_render_config qualification_complete=1 touch_mode=irq-assist touch_trigger=pendown-gpio-edge \
	release_stable_samples=3 idle_safety_poll_ms=250 touch_fallback_enabled=1 \
	backlight_mode=fixed-safe-on >> "$S2_CONF"
S2_RETRIES=2 S2_DELAY=1 s2_run "$WORK/s2-marker-qc1"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'never confirmed healthy' "$WORK/s2.out" && [ "$S2_SECS" -ge 2 ] && pass \
	|| fail "S2 qc=1: did not reach the health gates (${S2_SECS}s): $(cat "$WORK/s2.out")"
fake_untouched && pass || fail "S2 qc=1 unhealthy: a display sysfs file was written"
# marker rerun stays a skip even with a qualified config
s2_run "$WORK/s2-marker-qc1"; grep -q 'already ran this boot' "$WORK/s2.out" && [ "$S2_SECS" -le 2 ] && pass \
	|| fail "S2 marker rerun is not a skip"
echo $$ > "$GUPPY_PIDFILE"

# --- the REAL defaults, with no override, exactly as a real boot sources
# this library: the backlight class device path, and NDQ_TOUCH_SYSFS
# resolved by the glob under NDQ_I2C_DEVICES (first <bus>-<addr> that has a
# nebulaos_touch directory; empty when none has). ---
REAL_BL=$(
	unset NDQ_BACKLIGHT_SYSFS
	# shellcheck disable=SC1090
	. "$LIB"
	printf '%s' "$NDQ_BACKLIGHT_SYSFS"
)
[ "$REAL_BL" = "/sys/class/backlight/nebulaos_backlight" ] && pass \
	|| fail "NDQ_BACKLIGHT_SYSFS default is '$REAL_BL', expected /sys/class/backlight/nebulaos_backlight"

I2C_FAKE="$WORK/i2c-devices"
mkdir -p "$I2C_FAKE/0-0010" "$I2C_FAKE/1-0048/nebulaos_touch" "$I2C_FAKE/i2c-1"
RESOLVED=$(
	unset NDQ_TOUCH_SYSFS
	NDQ_I2C_DEVICES="$I2C_FAKE"
	# shellcheck disable=SC1090
	. "$LIB"
	printf '%s' "$NDQ_TOUCH_SYSFS"
)
[ "$RESOLVED" = "$I2C_FAKE/1-0048/nebulaos_touch" ] && pass \
	|| fail "NDQ_TOUCH_SYSFS default resolved to '$RESOLVED', expected $I2C_FAKE/1-0048/nebulaos_touch"
rm -rf "$I2C_FAKE/1-0048"
RESOLVED=$(
	unset NDQ_TOUCH_SYSFS
	NDQ_I2C_DEVICES="$I2C_FAKE"
	# shellcheck disable=SC1090
	. "$LIB"
	printf '%s' "$NDQ_TOUCH_SYSFS"
)
[ -z "$RESOLVED" ] && pass || fail "NDQ_TOUCH_SYSFS default is '$RESOLVED' with no nebulaos_touch directory, expected empty"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
