#!/bin/sh
#
# Offline, repeatable tests for:
#   - scripts/build/overlay/etc/nebulaos-display-qualified.sh (the config
#     format, atomic writer, validator, and debugfs-apply logic, including
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
# from this environment. Every debugfs interaction below is a fake file
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

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$LIB" ] || { echo "FATAL: $LIB not found"; exit 1; }
[ -f "$HEALTHCHECK_LIB" ] || { echo "FATAL: $HEALTHCHECK_LIB not found"; exit 1; }
[ -f "$APPLY_SCRIPT" ] || { echo "FATAL: $APPLY_SCRIPT not found"; exit 1; }
[ -f "$WRITE_HELPER" ] || { echo "FATAL: $WRITE_HELPER not found"; exit 1; }

# ============================================================
# Fake debugfs tree - reset before each scenario that needs one.
# ============================================================
FAKE_KERNEL="$WORK/fakekernel"

reset_fake_kernel() {
	rm -rf "$FAKE_KERNEL"
	mkdir -p "$FAKE_KERNEL/touch" "$FAKE_KERNEL/backlight"
	: > "$FAKE_KERNEL/touch/mode"
	printf 'mode: poll-only\npersistent_mode: poll-only\n' > "$FAKE_KERNEL/touch/status"
	: > "$FAKE_KERNEL/backlight/command"
	printf 'state: boot-preserve\n' > "$FAKE_KERNEL/backlight/status"
	NDQ_TOUCH_MODE_FILE="$FAKE_KERNEL/touch/mode"
	NDQ_TOUCH_STATUS_FILE="$FAKE_KERNEL/touch/status"
	NDQ_BACKLIGHT_CMD_FILE="$FAKE_KERNEL/backlight/command"
	NDQ_BACKLIGHT_STATUS_FILE="$FAKE_KERNEL/backlight/status"
	export NDQ_TOUCH_MODE_FILE NDQ_TOUCH_STATUS_FILE NDQ_BACKLIGHT_CMD_FILE NDQ_BACKLIGHT_STATUS_FILE
}

# "the touch driver confirmed" step of the fake tree - a real driver
# updates its own status file the instant a mode write is accepted; this
# helper stands in for that so tests can exercise the apply function's
# confirm-via-status gate without a real kernel.
fake_touch_confirm_irq_assist() {
	printf 'mode: irq-assist\npersistent_mode: poll-only\n' > "$FAKE_KERNEL/touch/status"
}
fake_backlight_confirm_safe_on() {
	printf 'state: safe-on\nsafe_on_verified: 1\n' > "$FAKE_KERNEL/backlight/status"
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
fake_touch_confirm_irq_assist
fake_backlight_confirm_safe_on
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
[ ! -s "$NDQ_TOUCH_MODE_FILE" ] && pass || fail "touch_mode=poll-only wrote something to the mode file when it should have been a pure no-op"

reset_fake_kernel
# Status never confirms -> must fail, not silently "succeed".
if ndq_apply_touch irq-assist 2>/dev/null; then
	fail "irq-assist apply reported success even though the fake status file never confirmed it"
else
	pass
fi

reset_fake_kernel
fake_touch_confirm_irq_assist
if ndq_apply_touch irq-assist; then
	pass
else
	fail "irq-assist apply failed even though the fake status file confirms mode: irq-assist"
fi
[ "$(cat "$NDQ_TOUCH_MODE_FILE")" = "irq-assist" ] && pass || fail "wrong bytes written to the touch mode debugfs file"

reset_fake_kernel
rm -f "$NDQ_TOUCH_MODE_FILE"
if ndq_apply_touch irq-assist 2>/dev/null; then
	fail "irq-assist apply reported success when the debugfs mode file does not exist at all"
else
	pass
fi

echo "============================================================"
echo "ndq_apply_backlight"
echo "============================================================"

reset_fake_kernel
if ndq_apply_backlight fixed-safe-on UNQUALIFIED 2>/dev/null; then
	fail "fixed-safe-on apply reported success even though status never confirmed safe-on"
else
	pass
fi

reset_fake_kernel
fake_backlight_confirm_safe_on
if ndq_apply_backlight fixed-safe-on UNQUALIFIED; then
	pass
else
	fail "fixed-safe-on apply failed even though status confirms safe-on"
fi
[ "$(cat "$NDQ_BACKLIGHT_CMD_FILE")" = "enter-safe-on" ] && pass || fail "fixed-safe-on apply did not issue exactly enter-safe-on"

# pwm mode: enter-safe-on must be issued and confirmed BEFORE pwm-active-N
# is ever attempted - verified here by construction: with the fake status
# never updated past boot-preserve, the pwm-active write must never
# happen (the command file must still show enter-safe-on, not pwm-active-*).
reset_fake_kernel
ndq_apply_backlight pwm 50 2>/dev/null
if [ "$(cat "$NDQ_BACKLIGHT_CMD_FILE")" = "enter-safe-on" ]; then
	pass
else
	fail "pwm-active-50 appears to have been issued even though safe-on was never confirmed - ordering violated: got '$(cat "$NDQ_BACKLIGHT_CMD_FILE")'"
fi

reset_fake_kernel
fake_backlight_confirm_safe_on
if ndq_apply_backlight pwm 50; then
	pass
else
	fail "pwm apply at 50% failed even though safe-on was confirmed"
fi
[ "$(cat "$NDQ_BACKLIGHT_CMD_FILE")" = "pwm-active-50" ] && pass || fail "pwm apply did not issue pwm-active-50 as its final command"

echo "============================================================"
echo "ndq_apply_all - end-to-end against the fake debugfs tree"
echo "============================================================"

# --- missing config file -> no mutation at all. ---
reset_fake_kernel
rm -f "$NDQ_CONFIG_FILE"
if ndq_apply_all "$NDQ_CONFIG_FILE" 2>/dev/null; then
	fail "apply_all reported success with no config file present"
else
	pass
fi
[ ! -s "$NDQ_TOUCH_MODE_FILE" ] && [ ! -s "$NDQ_BACKLIGHT_CMD_FILE" ] && pass \
	|| fail "apply_all mutated a debugfs file even though the config file was entirely missing"

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
[ ! -s "$NDQ_TOUCH_MODE_FILE" ] && [ ! -s "$NDQ_BACKLIGHT_CMD_FILE" ] && pass \
	|| fail "apply_all mutated a debugfs file even though the config file was corrupt"

# --- valid config, but the touch debugfs file is missing (simulating a
# kernel build without the qualification driver) -> touch fails, and
# critically the backlight must be left ENTIRELY untouched too (this
# script's own abort-on-first-failure design - see ndq_apply_all's own
# comment for why partial application across the two drivers is refused
# even though each driver's OWN boot default is independently safe). ---
reset_fake_kernel
rm -f "$NDQ_TOUCH_MODE_FILE"
ndq_render_config qualification_complete=1 touch_mode=irq-assist touch_trigger=pendown-gpio-edge \
	release_stable_samples=3 idle_safety_poll_ms=250 touch_fallback_enabled=1 \
	backlight_mode=fixed-safe-on > "$NDQ_CONFIG_FILE"
if ndq_apply_all "$NDQ_CONFIG_FILE" 2>/dev/null; then
	fail "apply_all reported success even though the touch debugfs mode file does not exist"
else
	pass
fi
[ ! -s "$NDQ_BACKLIGHT_CMD_FILE" ] && pass \
	|| fail "backlight was mutated even though the earlier touch apply step failed - abort-on-first-failure ordering was violated"

# --- fully valid config, fully healthy fake driver tree -> full success,
# both drivers actually mutated as expected. ---
reset_fake_kernel
fake_touch_confirm_irq_assist
fake_backlight_confirm_safe_on
ndq_render_config qualification_complete=1 touch_mode=irq-assist touch_trigger=pendown-gpio-edge \
	release_stable_samples=3 idle_safety_poll_ms=250 touch_fallback_enabled=1 \
	backlight_mode=pwm pwm_channel=0 pwm_period_ns=20000 pwm_polarity=normal safe_brightness=75 \
	> "$NDQ_CONFIG_FILE"
if ndq_apply_all "$NDQ_CONFIG_FILE"; then
	pass
else
	fail "apply_all failed against a fully valid config and a fully healthy fake driver tree"
fi
[ "$(cat "$NDQ_TOUCH_MODE_FILE")" = "irq-assist" ] && pass || fail "end-to-end apply_all did not write irq-assist to the touch mode file"
[ "$(cat "$NDQ_BACKLIGHT_CMD_FILE")" = "pwm-active-75" ] && pass || fail "end-to-end apply_all did not finish with pwm-active-75 on the backlight command file"

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
i_guppy=$(index_of S58guppyscreen)
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
		fail "S97nebulaos-display-qualified-apply does not sort strictly after S55klipper/S56moonraker/S58guppyscreen"
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
fake_touch_confirm_irq_assist
fake_backlight_confirm_safe_on
ndq_render_config qualification_complete=1 touch_mode=irq-assist touch_trigger=pendown-gpio-edge \
	release_stable_samples=3 idle_safety_poll_ms=250 touch_fallback_enabled=1 \
	backlight_mode=fixed-safe-on > "$NDQ_CONFIG_FILE"

MARKER_HEALTHY="$WORK/marker-healthy"
(
	PATH="$FAKE_ETC:$PATH"
	export PATH
	NDQ_LIB="$LIB" NDQ_HEALTHCHECK_LIB="$HEALTHCHECK_LIB" \
	MARKER="$MARKER_HEALTHY" GUPPYSCREEN_PIDFILE="$GUPPY_PIDFILE" \
	HEALTH_RETRIES=2 HEALTH_DELAY=0 \
	NDQ_CONFIG_FILE="$NDQ_CONFIG_FILE" \
	NDQ_TOUCH_MODE_FILE="$NDQ_TOUCH_MODE_FILE" NDQ_TOUCH_STATUS_FILE="$NDQ_TOUCH_STATUS_FILE" \
	NDQ_BACKLIGHT_CMD_FILE="$NDQ_BACKLIGHT_CMD_FILE" NDQ_BACKLIGHT_STATUS_FILE="$NDQ_BACKLIGHT_STATUS_FILE" \
	sh "$APPLY_SCRIPT" start
)
rc=$?
[ "$rc" -eq 0 ] && pass || fail "S97 start (healthy path) exited $rc, expected 0"
[ "$(cat "$NDQ_BACKLIGHT_CMD_FILE")" = "enter-safe-on" ] && pass \
	|| fail "S97 end-to-end healthy run did not actually apply the qualified backlight config"
[ -f "$MARKER_HEALTHY" ] && pass || fail "S97 did not create its once-per-boot marker"

# Second invocation with the marker already present must be a pure no-op
# (skips even the health poll) - overwrite the command file with a
# sentinel first so we can prove nothing touched it again.
echo "SENTINEL-UNTOUCHED" > "$NDQ_BACKLIGHT_CMD_FILE"
(
	PATH="$FAKE_ETC:$PATH"
	export PATH
	NDQ_LIB="$LIB" NDQ_HEALTHCHECK_LIB="$HEALTHCHECK_LIB" \
	MARKER="$MARKER_HEALTHY" GUPPYSCREEN_PIDFILE="$GUPPY_PIDFILE" \
	HEALTH_RETRIES=2 HEALTH_DELAY=0 \
	NDQ_CONFIG_FILE="$NDQ_CONFIG_FILE" \
	NDQ_TOUCH_MODE_FILE="$NDQ_TOUCH_MODE_FILE" NDQ_TOUCH_STATUS_FILE="$NDQ_TOUCH_STATUS_FILE" \
	NDQ_BACKLIGHT_CMD_FILE="$NDQ_BACKLIGHT_CMD_FILE" NDQ_BACKLIGHT_STATUS_FILE="$NDQ_BACKLIGHT_STATUS_FILE" \
	sh "$APPLY_SCRIPT" start
)
[ "$(cat "$NDQ_BACKLIGHT_CMD_FILE")" = "SENTINEL-UNTOUCHED" ] && pass \
	|| fail "S97's once-per-boot marker did not prevent a second apply attempt"

# --- unhealthy path: GuppyScreen "not running" (a PID that doesn't
# exist) -> S97 must exit 0 and must NOT touch either debugfs file. ---
reset_fake_kernel
echo 999999999 > "$GUPPY_PIDFILE"	# almost certainly not a real PID
MARKER_UNHEALTHY="$WORK/marker-unhealthy"
(
	PATH="$FAKE_ETC:$PATH"
	export PATH
	NDQ_LIB="$LIB" NDQ_HEALTHCHECK_LIB="$HEALTHCHECK_LIB" \
	MARKER="$MARKER_UNHEALTHY" GUPPYSCREEN_PIDFILE="$GUPPY_PIDFILE" \
	HEALTH_RETRIES=1 HEALTH_DELAY=0 \
	NDQ_CONFIG_FILE="$NDQ_CONFIG_FILE" \
	NDQ_TOUCH_MODE_FILE="$NDQ_TOUCH_MODE_FILE" NDQ_TOUCH_STATUS_FILE="$NDQ_TOUCH_STATUS_FILE" \
	NDQ_BACKLIGHT_CMD_FILE="$NDQ_BACKLIGHT_CMD_FILE" NDQ_BACKLIGHT_STATUS_FILE="$NDQ_BACKLIGHT_STATUS_FILE" \
	sh "$APPLY_SCRIPT" start
)
rc=$?
[ "$rc" -eq 0 ] && pass || fail "S97 start (unhealthy GuppyScreen) exited $rc, expected 0 (fail-safe, not a boot-halting error)"
[ ! -s "$NDQ_TOUCH_MODE_FILE" ] && [ ! -s "$NDQ_BACKLIGHT_CMD_FILE" ] && pass \
	|| fail "S97 mutated a debugfs file even though GuppyScreen was never confirmed running"

# --- unhealthy path: the display itself never confirms healthy (backlight
# status debugfs file missing entirely, e.g. a kernel build without the
# driver) - S97 must exit 0 and must NOT touch either debugfs file, even
# though Klipper/Moonraker/GuppyScreen/networking are all otherwise fully
# healthy. ---
reset_fake_kernel
echo $$ > "$GUPPY_PIDFILE"
rm -f "$NDQ_BACKLIGHT_STATUS_FILE"
MARKER_NODISPLAY="$WORK/marker-nodisplay"
(
	PATH="$FAKE_ETC:$PATH"
	export PATH
	NDQ_LIB="$LIB" NDQ_HEALTHCHECK_LIB="$HEALTHCHECK_LIB" \
	MARKER="$MARKER_NODISPLAY" GUPPYSCREEN_PIDFILE="$GUPPY_PIDFILE" \
	HEALTH_RETRIES=1 HEALTH_DELAY=0 \
	NDQ_CONFIG_FILE="$NDQ_CONFIG_FILE" \
	NDQ_TOUCH_MODE_FILE="$NDQ_TOUCH_MODE_FILE" NDQ_TOUCH_STATUS_FILE="$NDQ_TOUCH_STATUS_FILE" \
	NDQ_BACKLIGHT_CMD_FILE="$NDQ_BACKLIGHT_CMD_FILE" NDQ_BACKLIGHT_STATUS_FILE="$NDQ_BACKLIGHT_STATUS_FILE" \
	sh "$APPLY_SCRIPT" start
)
rc=$?
[ "$rc" -eq 0 ] && pass || fail "S97 start (missing display status file) exited $rc, expected 0 (fail-safe, not a boot-halting error)"
[ ! -s "$NDQ_TOUCH_MODE_FILE" ] && [ ! -s "$NDQ_BACKLIGHT_CMD_FILE" ] && pass \
	|| fail "S97 mutated a debugfs file even though the display's own backlight status file was never confirmed readable"

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
		MARKER="$1" GUPPYSCREEN_PIDFILE="$GUPPY_PIDFILE" \
		HEALTH_RETRIES="${S2_RETRIES:-20}" HEALTH_DELAY="${S2_DELAY:-3}" \
		NDQ_CONFIG_FILE="$S2_CONF" \
		NDQ_TOUCH_MODE_FILE="$NDQ_TOUCH_MODE_FILE" NDQ_TOUCH_STATUS_FILE="$NDQ_TOUCH_STATUS_FILE" \
		NDQ_BACKLIGHT_CMD_FILE="$NDQ_BACKLIGHT_CMD_FILE" NDQ_BACKLIGHT_STATUS_FILE="$NDQ_BACKLIGHT_STATUS_FILE" \
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
	[ ! -s "$NDQ_TOUCH_MODE_FILE" ] && [ ! -s "$NDQ_BACKLIGHT_CMD_FILE" ] && pass || fail "S2 $c: a display command file was written"
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
[ ! -s "$NDQ_TOUCH_MODE_FILE" ] && [ ! -s "$NDQ_BACKLIGHT_CMD_FILE" ] && pass || fail "S2 qc=1 unhealthy: a display command file was written"
# marker rerun stays a skip even with a qualified config
s2_run "$WORK/s2-marker-qc1"; grep -q 'already ran this boot' "$WORK/s2.out" && [ "$S2_SECS" -le 2 ] && pass \
	|| fail "S2 marker rerun is not a skip"
echo $$ > "$GUPPY_PIDFILE"

# --- regression test (Pinctrl/Display Baseline Closeout Mission,
# 2026-08-03): the REAL default value of NDQ_BACKLIGHT_CMD_FILE/
# NDQ_BACKLIGHT_STATUS_FILE - with NO override, exactly as a real boot
# would source this library - must match the backlight driver's actual
# registered debugfs directory name (NBLC_NAME in the patch), not a
# guess at the driver's .c filename. This is the exact class of bug that
# shipped live: every other test in this file overrides these two
# variables to a fake path, so none of them would ever have caught a
# wrong DEFAULT - this test deliberately does not override anything. ---
BACKLIGHT_PATCH="$REPO_ROOT/scripts/build/patches/backlight-final-controller.patch"
if [ -f "$BACKLIGHT_PATCH" ]; then
	NBLC_NAME=$(sed -n 's/^+#define NBLC_NAME[[:space:]]*"\([^"]*\)".*/\1/p' "$BACKLIGHT_PATCH" | head -1)
	if [ -z "$NBLC_NAME" ]; then
		fail "could not extract NBLC_NAME from $BACKLIGHT_PATCH - test itself is broken, fix the sed pattern"
	else
		REAL_DEFAULTS=$(
			unset NDQ_BACKLIGHT_CMD_FILE NDQ_BACKLIGHT_STATUS_FILE
			# shellcheck disable=SC1090
			. "$LIB"
			printf '%s\n%s\n' "$NDQ_BACKLIGHT_CMD_FILE" "$NDQ_BACKLIGHT_STATUS_FILE"
		)
		EXPECTED_CMD="/sys/kernel/debug/$NBLC_NAME/command"
		EXPECTED_STATUS="/sys/kernel/debug/$NBLC_NAME/status"
		ACTUAL_CMD=$(echo "$REAL_DEFAULTS" | sed -n '1p')
		ACTUAL_STATUS=$(echo "$REAL_DEFAULTS" | sed -n '2p')
		if [ "$ACTUAL_CMD" = "$EXPECTED_CMD" ] && [ "$ACTUAL_STATUS" = "$EXPECTED_STATUS" ]; then
			pass
		else
			fail "NDQ_BACKLIGHT_CMD_FILE/STATUS_FILE default(s) do not match the real driver's NBLC_NAME ('$NBLC_NAME'): got cmd='$ACTUAL_CMD' status='$ACTUAL_STATUS', expected cmd='$EXPECTED_CMD' status='$EXPECTED_STATUS'"
		fi
	fi
else
	echo "SKIP: $BACKLIGHT_PATCH not present"
fi

# --- regression test: the touch-wake watcher's own asleep-detection,
# exercised through the SAME real, unoverridden NDQ_BACKLIGHT_STATUS_FILE
# default this mission's live bug broke - proves ndq_swc_backlight_is_asleep()
# reads the exact path a real boot would use, and that a real "state: asleep"
# line at that path is correctly detected. ---
SWC_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-display-sleep-wake-controller.sh"
if [ -f "$SWC_LIB" ] && [ -n "${NBLC_NAME:-}" ]; then
	REAL_STATUS_PATH="/sys/kernel/debug/$NBLC_NAME/status"
	FAKE_REAL_STATUS_DIR="$WORK/real-path-sim/sys/kernel/debug/$NBLC_NAME"
	mkdir -p "$FAKE_REAL_STATUS_DIR"
	printf 'state: asleep\n' > "$FAKE_REAL_STATUS_DIR/status"
	DETECTED=$(
		unset NDQ_BACKLIGHT_STATUS_FILE
		NDQ_BACKLIGHT_STATUS_FILE="$FAKE_REAL_STATUS_DIR/status"
		export NDQ_BACKLIGHT_STATUS_FILE
		# shellcheck disable=SC1090
		. "$SWC_LIB"
		ndq_swc_backlight_is_asleep && echo yes || echo no
	)
	[ "$DETECTED" = "yes" ] && pass \
		|| fail "ndq_swc_backlight_is_asleep() did not detect 'state: asleep' at the real default-shaped path $REAL_STATUS_PATH"
else
	echo "SKIP: $SWC_LIB or NBLC_NAME not available"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
