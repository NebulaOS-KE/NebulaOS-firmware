#!/bin/sh
#
# NebulaOS display-qualification config: shared library for the persistent
# /usr/data/nebulaos/display-qualified.conf format, its atomic writer, its
# validator, and the apply logic for the two kernel-owned drivers this
# mission qualifies, through their sysfs interfaces:
#
#   - CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION
#     (ns2009_final_qualification.c): /sys/bus/i2c/devices/<bus>-<addr>/
#     nebulaos_touch/{mode,touch_down_count}, created at the driver's first
#     poll, before any init script runs.
#   - CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER
#     (nebulaos_backlight_final_controller.c): the standard backlight class
#     device /sys/class/backlight/nebulaos_backlight/.
#
# Kernel and rootfs ship together in one image, so there is no debugfs
# fallback; debugfs stays in the kernel for manual diagnostics only and the
# image never mounts it.
#
# Sourced by three callers: the boot-time apply script
# (etc/init.d/S97nebulaos-display-qualified-apply), the human-operator
# write helper (usr/libexec/nebulaos-display-qualified-write) that a real
# live-qualification session drives by hand over SSH, and this project's
# own offline test suite (tests/nebulaos-display-qualified-tests.sh) - one
# implementation, three consumers, so a fix or a field-list change only
# ever needs to happen in one place.
#
# Config format: plain "key=value" lines, one per line - NOT JSON. Same
# reasoning S05nebulaos-activate's own header already documents for its
# own working file: this is a BusyBox ash environment with no JSON-aware
# tool confirmed present, so a JSON writer/parser would mean either
# hand-rolling one (a real bug surface for a file this safety-critical) or
# taking a new build dependency. Plain key=value lines are trivially
# parsed with sed/grep/case, which are already relied on everywhere else
# in this codebase (S99confirm-good, nebulaos-healthcheck.sh, etc).
#
# SAFETY DEFAULT this whole file is built around: any parse/validate
# failure means "treat the file as absent" - the caller must then do
# nothing, leaving both kernel drivers in their own independently-safe
# boot defaults (touch poll-only, backlight boot-preserve). This library
# itself never applies a partial result - see ndq_validate()'s own
# all-fields-up-front design and ndq_apply_all()'s abort-on-first-failure
# sequencing.

NDQ_FORMAT_VERSION=1

: "${NDQ_CONFIG_DIR:=/usr/data/nebulaos}"
: "${NDQ_CONFIG_FILE:=$NDQ_CONFIG_DIR/display-qualified.conf}"

# Overridable so the offline test suite can point these at a fake sysfs
# tree instead of a real kernel. NDQ_TOUCH_SYSFS defaults to the first
# <bus>-<addr>/nebulaos_touch directory under NDQ_I2C_DEVICES (empty if the
# touch driver has not created one); NDQ_BACKLIGHT_SYSFS is the backlight
# class device registered by the controller.
: "${NDQ_I2C_DEVICES:=/sys/bus/i2c/devices}"
ndq_find_touch_sysfs() {
	for _ndq_d in "$NDQ_I2C_DEVICES"/*/nebulaos_touch; do
		[ -d "$_ndq_d" ] && { printf '%s' "$_ndq_d"; return 0; }
	done
	return 1
}
: "${NDQ_TOUCH_SYSFS:=$(ndq_find_touch_sysfs)}"
: "${NDQ_BACKLIGHT_SYSFS:=/sys/class/backlight/nebulaos_backlight}"

# The touch-wake watcher's own init.d script, invoked (not sourced) by
# ndq_apply_deferred_fields() below when sleep_enabled=1 and
# touch_wake_mode=polling. Overridable so the offline test suite can point
# this at a fake stand-in script instead of a real init.d entry - same
# reasoning as every other overridable path in this file. Its own start()
# is idempotent (start-stop-daemon's pidfile check), so invoking it here in
# addition to it also running in the normal S* boot sequence is always
# safe, never a double-start.
: "${NDQ_SLEEP_WAKE_INITD:=/etc/init.d/S98nebulaos-display-sleep-wake-controller}"

# Sentinel for "this field was never live-qualified." Never treated as a
# valid value for any field that gates an actual apply step - see
# ndq_validate(). Deliberately not "0", "none", or an empty string: those
# could plausibly be typo'd/omitted-field defaults that mean something
# else for a couple of fields (e.g. sleep_enabled=0 is a REAL, meaningful,
# intentionally-set value, not "untested").
NDQ_UNQUALIFIED="UNQUALIFIED"

# The complete, ordered field list this format writes/reads. Order matters
# only for the writer (it defines the canonical on-disk layout the
# checksum covers) - the reader/validator looks fields up by name, not
# position.
NDQ_FIELDS="format_version qualification_complete touch_mode touch_trigger \
release_stable_samples idle_safety_poll_ms touch_fallback_enabled \
backlight_mode pwm_channel pwm_period_ns pwm_polarity pc22_usage \
pc22_active_level safe_brightness minimum_brightness off_value \
sleep_enabled touch_wake_enabled touch_wake_mode first_touch_policy \
qualified_at_utc"

ndq_log() {
	echo "nebulaos-display-qualified: $1"
}

# ============================================================
# Small POSIX-ash helpers (no bashisms - this runs under BusyBox ash)
# ============================================================

ndq_is_uint() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

# ndq_in_set VALUE candidate1 candidate2 ...
ndq_in_set() {
	val="$1"
	shift
	for cand in "$@"; do
		[ "$val" = "$cand" ] && return 0
	done
	return 1
}

# ============================================================
# Parsing
# ============================================================

# ndq_get_field FILE KEY - prints the value of the LAST "key=value" line
# matching KEY exactly (anchored), empty output if absent. KEY is always
# one of this file's own fixed field names (alnum+underscore), never
# attacker/user-controlled input, so a plain sed anchor is safe here - no
# shell eval, no sourcing the config file as code, ever.
ndq_get_field() {
	file="$1"
	key="$2"
	sed -n "s/^${key}=//p" "$file" 2>/dev/null | tail -n1
}

# ============================================================
# Checksum
# ============================================================

ndq_sha256_of_file() {
	sha256sum "$1" 2>/dev/null | cut -d' ' -f1
}

# The checksum line is always written as the LAST line of the file (see
# ndq_render_config()). The expected checksum covers every byte of every
# OTHER line, in on-disk order, including comments if any were ever added -
# tampering with anything above the last line invalidates it.
ndq_compute_expected_checksum() {
	file="$1"
	total=$(wc -l < "$file" 2>/dev/null)
	total=${total:-0}
	if [ "$total" -lt 1 ]; then
		return 1
	fi
	head -n "$((total - 1))" "$file" | sha256sum | cut -d' ' -f1
}

# ============================================================
# Atomic write
# ============================================================
#
# Contract: write to a temp file in the SAME directory as the target
# (guarantees the final rename is on the same filesystem, so it is a
# genuine atomic rename(2), not a cross-filesystem copy), fsync the temp
# file's data, rename() it over the target, then make the rename itself
# durable.
#
# File-content fsync: BusyBox's `dd conv=fsync` (CONFIG_DD=y, confirmed in
# vendor/buildroot-x2000/package/busybox/busybox.config) calls fsync() on
# its output file before exiting - already the established idiom in this
# codebase for exactly this (S03nebulaos-diskswap uses `dd ... conv=fsync`
# to durably write the swapfile). Reused here rather than inventing a new
# mechanism.
#
# Directory-entry fsync (durability of the rename itself, not just the
# file content): BusyBox ships no applet that fsyncs a directory file
# descriptor directly (no `flock`-style fd-holding primitive exposed to
# shell, and no dedicated "syncdir" tool) - the only two real options from
# a POSIX ash script are (a) a small compiled C helper that open()s the
# directory and calls fsync() on it, or (b) BusyBox's own `sync` applet,
# which calls the global sync(2) and flushes every dirty buffer in the
# system, directory metadata included. This project already uses plain
# `sync` for exactly this "make a just-completed on-disk change durable"
# purpose (S04nebulaos-factory-seed, twice, after its own seed-copy
# writes) - reusing that established, already-proven idiom instead of
# adding a new compiled helper binary to the image is the simpler, lower-
# risk choice for a config file this small that is written at most once
# per live-qualification session (a rare, human-operator-driven action,
# never a hot path) - the cost of a full sync() is irrelevant here.
#
# ndq_atomic_write TARGET_FILE < content-on-stdin
ndq_atomic_write() {
	target="$1"
	dir=$(dirname "$target")

	mkdir -p "$dir" 2>/dev/null || {
		ndq_log "atomic write: failed to create directory $dir"
		return 1
	}

	tmp=$(mktemp "$dir/.tmp.$(basename "$target").XXXXXX" 2>/dev/null) || {
		ndq_log "atomic write: mktemp failed in $dir"
		return 1
	}

	# Stage the content into the temp file and fsync its data - a kill
	# between here and the mv below leaves ONLY the temp file in a
	# possibly-torn state; the real target is never touched, so a reader
	# of $target always sees either the previous complete file or (on a
	# first-ever write) nothing at all - never a truncated new one.
	if ! dd of="$tmp" conv=fsync >/dev/null 2>&1; then
		ndq_log "atomic write: dd write/fsync to $tmp failed"
		rm -f "$tmp"
		return 1
	fi

	chmod 0644 "$tmp" 2>/dev/null

	# Same-directory rename - atomic on any real filesystem (single
	# rename(2) syscall under the hood; BusyBox `mv` takes the fast-path
	# rename() rather than copy+unlink when source and destination are on
	# the same filesystem).
	if ! mv -f "$tmp" "$target"; then
		ndq_log "atomic write: rename of $tmp to $target failed"
		rm -f "$tmp"
		return 1
	fi

	# Durability of the rename/directory-entry itself - see the file
	# header above for why this is a plain global `sync` rather than a
	# targeted directory fsync.
	sync

	return 0
}

# ============================================================
# Canonical config rendering (used by the write helper, not the apply
# path - the apply path only ever reads).
# ============================================================
#
# ndq_render_config KEY=VALUE [KEY=VALUE ...]
# Prints a complete, checksummed config document to stdout in the fixed
# field order (NDQ_FIELDS), followed by the checksum line. Any field in
# NDQ_FIELDS not supplied on the command line is rendered as
# NDQ_UNQUALIFIED (or, for the three deferred sleep/wake fields, their own
# documented inert defaults - see ndq_default_for_field()) - this is what
# makes "never persist a value that wasn't actually live-qualified" the
# structural default rather than something the caller has to remember.
ndq_default_for_field() {
	case "$1" in
		format_version) echo "$NDQ_FORMAT_VERSION" ;;
		qualification_complete) echo "0" ;;
		sleep_enabled) echo "0" ;;
		touch_wake_enabled) echo "0" ;;
		touch_wake_mode) echo "disabled" ;;
		first_touch_policy) echo "not-implemented" ;;
		qualified_at_utc) echo "never" ;;
		*) echo "$NDQ_UNQUALIFIED" ;;
	esac
}

ndq_render_config() {
	# Collect overrides into a small lookup via case/for - ash has no
	# associative arrays, so this walks NDQ_FIELDS and, for each field,
	# scans the supplied KEY=VALUE args for a match. Field count is small
	# (20) and this only ever runs for a human-operator-driven write, so
	# the O(n*m) scan is irrelevant.
	body=""
	for field in $NDQ_FIELDS; do
		val=""
		found=0
		for kv in "$@"; do
			k=${kv%%=*}
			v=${kv#*=}
			if [ "$k" = "$field" ]; then
				val="$v"
				found=1
			fi
		done
		if [ "$found" -eq 0 ]; then
			val=$(ndq_default_for_field "$field")
		fi
		body="${body}${field}=${val}
"
	done
	checksum=$(printf '%s' "$body" | sha256sum | cut -d' ' -f1)
	printf '%s' "$body"
	printf 'checksum=%s\n' "$checksum"
}

# ============================================================
# Validation
# ============================================================
#
# ndq_validate FILE - validates structure, checksum, version, and (only if
# qualification_complete=1) every field that actually gates a hardware
# apply step. On success, prints nothing and returns 0, and every field's
# value is available afterward via ndq_get_field. On failure, logs the
# SPECIFIC reason and returns 1. Deliberately validates the ENTIRE file in
# one pass before the caller does ANYTHING with it - this is what makes
# "corrupt file -> zero mutations, not a partial apply" possible: the
# apply path (ndq_apply_all) never even starts touching hardware unless
# this whole function already returned success.
ndq_validate() {
	file="$1"

	if [ ! -f "$file" ]; then
		ndq_log "validate: $file does not exist - treating as not-qualified (safe default)"
		return 1
	fi
	if [ ! -s "$file" ]; then
		ndq_log "validate: $file is empty - refusing to trust it"
		return 1
	fi

	lines=$(wc -l < "$file" 2>/dev/null)
	lines=${lines:-0}
	if [ "$lines" -lt 2 ]; then
		ndq_log "validate: $file has too few lines ($lines) to contain every required field plus a checksum"
		return 1
	fi

	last_line=$(tail -n1 "$file")
	case "$last_line" in
		checksum=*) ;;
		*)
			ndq_log "validate: last line of $file is not a checksum= line - refusing to trust it"
			return 1
			;;
	esac
	stored_checksum=${last_line#checksum=}
	# A plain length+charset check (rather than 64 hand-chained
	# [0-9a-f] glob groups, which is exactly the kind of thing that's
	# trivially one-off-by-one and easy to get wrong silently) - ash
	# supports POSIX ${#var} string length.
	if [ "${#stored_checksum}" -ne 64 ]; then
		ndq_log "validate: checksum line in $file is not 64 characters long"
		return 1
	fi
	case "$stored_checksum" in
		*[!0-9a-f]*)
			ndq_log "validate: checksum line in $file contains non-hex/non-lowercase characters"
			return 1
			;;
	esac

	expected_checksum=$(ndq_compute_expected_checksum "$file")
	if [ -z "$expected_checksum" ] || [ "$expected_checksum" != "$stored_checksum" ]; then
		ndq_log "validate: checksum mismatch in $file (stored=$stored_checksum expected=$expected_checksum) - file is corrupt or was tampered with, refusing to trust it"
		return 1
	fi

	fmt=$(ndq_get_field "$file" format_version)
	if [ "$fmt" != "$NDQ_FORMAT_VERSION" ]; then
		ndq_log "validate: format_version='$fmt' in $file does not match the version this system understands ($NDQ_FORMAT_VERSION) - refusing to trust it"
		return 1
	fi

	qc=$(ndq_get_field "$file" qualification_complete)
	if [ "$qc" != "0" ] && [ "$qc" != "1" ]; then
		ndq_log "validate: qualification_complete='$qc' in $file is neither 0 nor 1 - malformed, refusing to trust it"
		return 1
	fi

	# The three deferred sleep/touch-wake fields are validated
	# unconditionally (they must always be well-formed, forward-
	# compatible with a future real implementation), but never gate
	# qualification_complete and are never applied - see
	# ndq_apply_deferred_fields().
	sleep_enabled=$(ndq_get_field "$file" sleep_enabled)
	if [ "$sleep_enabled" != "0" ] && [ "$sleep_enabled" != "1" ]; then
		ndq_log "validate: sleep_enabled='$sleep_enabled' in $file is neither 0 nor 1"
		return 1
	fi
	touch_wake_enabled=$(ndq_get_field "$file" touch_wake_enabled)
	if [ "$touch_wake_enabled" != "0" ] && [ "$touch_wake_enabled" != "1" ]; then
		ndq_log "validate: touch_wake_enabled='$touch_wake_enabled' in $file is neither 0 nor 1"
		return 1
	fi
	# touch_wake_mode is the mission-spec-verbatim field (touch_wake_mode=
	# polling). touch_wake_enabled predates it (a plain boolean, kept for
	# backward compatibility with any config already written against the
	# original field list) - rather than letting the two fields silently
	# disagree about the same underlying capability, they are required to
	# always agree: touch_wake_mode=polling <-> touch_wake_enabled=1, and
	# touch_wake_mode=disabled <-> touch_wake_enabled=0. A config that sets
	# one without the consistent other is malformed and rejected, same as
	# any other field here - see ndq_apply_deferred_fields() for how
	# touch_wake_mode actually gates starting the sleep/wake watcher.
	touch_wake_mode=$(ndq_get_field "$file" touch_wake_mode)
	if ! ndq_in_set "$touch_wake_mode" polling disabled; then
		ndq_log "validate: touch_wake_mode='$touch_wake_mode' in $file is not polling/disabled"
		return 1
	fi
	if [ "$touch_wake_mode" = "polling" ] && [ "$touch_wake_enabled" != "1" ]; then
		ndq_log "validate: touch_wake_mode=polling but touch_wake_enabled='$touch_wake_enabled' (expected 1) - the two fields disagree about whether touch-wake is enabled"
		return 1
	fi
	if [ "$touch_wake_mode" = "disabled" ] && [ "$touch_wake_enabled" != "0" ]; then
		ndq_log "validate: touch_wake_mode=disabled but touch_wake_enabled='$touch_wake_enabled' (expected 0) - the two fields disagree about whether touch-wake is enabled"
		return 1
	fi
	first_touch_policy=$(ndq_get_field "$file" first_touch_policy)
	if ! ndq_in_set "$first_touch_policy" not-implemented wake-only wake-and-pass-through ignore; then
		ndq_log "validate: first_touch_policy='$first_touch_policy' in $file is not a recognized value"
		return 1
	fi

	if [ "$qc" != "1" ]; then
		ndq_log "validate: $file is structurally valid but qualification_complete=0 - nothing to apply (this is the expected, safe pre-qualification state)"
		return 1
	fi

	# --- Everything below only runs when qualification_complete=1 - a
	# field that gates a real hardware apply step must never be
	# UNQUALIFIED at this point. ---

	touch_mode=$(ndq_get_field "$file" touch_mode)
	if ! ndq_in_set "$touch_mode" poll-only irq-assist; then
		ndq_log "validate: touch_mode='$touch_mode' is not poll-only/irq-assist (qualification_complete=1 requires a real, tested value)"
		return 1
	fi

	touch_trigger=$(ndq_get_field "$file" touch_trigger)
	case "$touch_mode" in
		poll-only)
			if [ "$touch_trigger" != "poll" ]; then
				ndq_log "validate: touch_trigger='$touch_trigger' is inconsistent with touch_mode=poll-only (expected 'poll')"
				return 1
			fi
			;;
		irq-assist)
			if [ "$touch_trigger" != "pendown-gpio-edge" ]; then
				ndq_log "validate: touch_trigger='$touch_trigger' is inconsistent with touch_mode=irq-assist (expected 'pendown-gpio-edge', the driver's real hard-IRQ trigger source on the pendown GPIO)"
				return 1
			fi
			;;
	esac

	# release_stable_samples / idle_safety_poll_ms / touch_fallback_enabled
	# are NOT runtime-configurable in this driver (no sysfs or debugfs knob
	# for any of them - see ns2009_final_qualification.c's own
	# NS2009_NFQ_RELEASE_CONFIRM_POLLS / NS2009_NFQ_SAFETY_POLL_INTERVAL_MS
	# compile-time constants). Recording anything other than the actual
	# compiled-in constants here would misrepresent what was really
	# qualified, so these are validated against the exact constant values
	# rather than an open range. Purely informational/audit fields - never
	# applied at boot (there is nothing to write). If the driver is ever
	# revised to change these constants, update the expected values below
	# to match.
	release_stable_samples=$(ndq_get_field "$file" release_stable_samples)
	if [ "$release_stable_samples" != "3" ]; then
		ndq_log "validate: release_stable_samples='$release_stable_samples' does not match the driver's compiled-in NS2009_NFQ_RELEASE_CONFIRM_POLLS (3) - not a value this kernel can actually exhibit"
		return 1
	fi
	idle_safety_poll_ms=$(ndq_get_field "$file" idle_safety_poll_ms)
	if [ "$idle_safety_poll_ms" != "250" ]; then
		ndq_log "validate: idle_safety_poll_ms='$idle_safety_poll_ms' does not match the driver's compiled-in NS2009_NFQ_SAFETY_POLL_INTERVAL_MS (250)"
		return 1
	fi
	touch_fallback_enabled=$(ndq_get_field "$file" touch_fallback_enabled)
	if [ "$touch_fallback_enabled" != "1" ]; then
		ndq_log "validate: touch_fallback_enabled='$touch_fallback_enabled' - the storm/timeout permanent fallback-to-poll-only safety net is hardcoded always-on in this driver, so anything other than 1 misrepresents reality"
		return 1
	fi

	backlight_mode=$(ndq_get_field "$file" backlight_mode)
	if ! ndq_in_set "$backlight_mode" fixed-safe-on pwm; then
		ndq_log "validate: backlight_mode='$backlight_mode' is not fixed-safe-on/pwm (qualification_complete=1 requires a real, tested value)"
		return 1
	fi

	if [ "$backlight_mode" = "pwm" ]; then
		pwm_channel=$(ndq_get_field "$file" pwm_channel)
		if [ "$pwm_channel" != "0" ]; then
			ndq_log "validate: pwm_channel='$pwm_channel' - the DT node wires this driver to PWM channel 0 only, no other channel is reachable"
			return 1
		fi
		pwm_period_ns=$(ndq_get_field "$file" pwm_period_ns)
		if [ "$pwm_period_ns" != "20000" ]; then
			ndq_log "validate: pwm_period_ns='$pwm_period_ns' - the driver applies a fixed compiled-in NBLC_PWM_PERIOD_NS (20000) for every pwm-active-* command, no other period is reachable"
			return 1
		fi
		pwm_polarity=$(ndq_get_field "$file" pwm_polarity)
		if [ "$pwm_polarity" != "normal" ]; then
			ndq_log "validate: pwm_polarity='$pwm_polarity' - the driver always applies PWM_POLARITY_NORMAL, no other polarity is reachable"
			return 1
		fi
		safe_brightness=$(ndq_get_field "$file" safe_brightness)
		if ! ndq_in_set "$safe_brightness" 25 50 75; then
			ndq_log "validate: safe_brightness='$safe_brightness' - backlight_mode=pwm requires one of 25/50/75 (the only duty values the driver's pwm-active-25/50/75 commands accept)"
			return 1
		fi
	fi

	# minimum_brightness/off_value/pc22_usage/pc22_active_level are
	# informational-only (see the apply function for why none of them are
	# ever written to a driver) - validated loosely, never gate anything.
	minimum_brightness=$(ndq_get_field "$file" minimum_brightness)
	if [ "$minimum_brightness" != "$NDQ_UNQUALIFIED" ]; then
		if ! ndq_is_uint "$minimum_brightness" || [ "$minimum_brightness" -gt 100 ]; then
			ndq_log "validate: minimum_brightness='$minimum_brightness' is not UNQUALIFIED or an integer 0-100"
			return 1
		fi
	fi
	# off_value is deliberately allowed to remain UNQUALIFIED even when
	# sleep_enabled=1 - this project never proved a 0% PWM duty value (see
	# docs/NEBULAOS_ONE_FLASH_DISPLAY_FINAL_REPORT.md's own account of why
	# that was never tested), and "never persist a value that wasn't
	# actually live-qualified" means this validator must not require one.
	# Sleep in this system is defined as GPC0-GPIO-off (see the same
	# report), a hardware mechanism entirely independent of PWM duty - the
	# sleep/wake watcher (nebulaos-display-sleep-wake-controller.sh) never
	# reads or needs off_value at all. This field stays purely an
	# informational/audit record of a PWM off-duty IF one is ever actually
	# qualified in the future.
	off_value=$(ndq_get_field "$file" off_value)
	if [ "$off_value" != "$NDQ_UNQUALIFIED" ]; then
		if ! ndq_is_uint "$off_value" || [ "$off_value" -gt 100 ]; then
			ndq_log "validate: off_value='$off_value' is not UNQUALIFIED or an integer 0-100"
			return 1
		fi
	fi
	pc22_usage=$(ndq_get_field "$file" pc22_usage)
	if [ "$pc22_usage" != "$NDQ_UNQUALIFIED" ] && ! ndq_in_set "$pc22_usage" unused enable-active-high enable-active-low; then
		ndq_log "validate: pc22_usage='$pc22_usage' is not UNQUALIFIED/unused/enable-active-high/enable-active-low"
		return 1
	fi
	pc22_active_level=$(ndq_get_field "$file" pc22_active_level)
	if [ "$pc22_active_level" != "$NDQ_UNQUALIFIED" ] && [ "$pc22_active_level" != "0" ] && [ "$pc22_active_level" != "1" ]; then
		ndq_log "validate: pc22_active_level='$pc22_active_level' is not UNQUALIFIED/0/1"
		return 1
	fi

	return 0
}

# ============================================================
# Apply - touch
# ============================================================
#
# Only ever called after ndq_validate succeeded. touch_mode=poll-only is
# always a no-op (poll-only IS the kernel's own boot default - see
# ns2009_final_qualification.c's probe(), nfq->mode =
# NS2009_NFQ_MODE_POLL_ONLY unconditionally). touch_mode=irq-assist writes
# exactly "irq-assist" to $NDQ_TOUCH_SYSFS/mode (the driver's
# ns2009_nfq_mode_command() parser rejects anything else) and requires the
# mode file to read back exactly "irq-assist". Any failure leaves touch at
# poll-only.
ndq_apply_touch() {
	touch_mode="$1"

	if [ "$touch_mode" = "poll-only" ]; then
		ndq_log "apply-touch: touch_mode=poll-only, already the kernel boot default - no write needed"
		return 0
	fi

	mode_file="$NDQ_TOUCH_SYSFS/mode"
	if [ -z "$NDQ_TOUCH_SYSFS" ] || [ ! -w "$mode_file" ]; then
		ndq_log "apply-touch: touch sysfs mode file ('$mode_file') not present or not writable - kernel driver not loaded as expected, refusing to guess, leaving touch at poll-only"
		return 1
	fi

	if ! printf '%s' "irq-assist" > "$mode_file" 2>/dev/null; then
		ndq_log "apply-touch: write of 'irq-assist' to $mode_file failed"
		return 1
	fi

	readback=$(cat "$mode_file" 2>/dev/null)
	if [ "$readback" != "irq-assist" ]; then
		ndq_log "apply-touch: wrote irq-assist but $mode_file reads back '$readback' - treating as a failure"
		return 1
	fi
	ndq_log "apply-touch: confirmed mode=irq-assist via $mode_file"
	return 0
}

# ============================================================
# Apply - backlight
# ============================================================
#
# Only ever called after ndq_validate succeeded. Converges the backlight
# to full (safe-on) through the class device, regardless of
# backlight_mode: bl_power=0, brightness=4 (the kernel enters safe-on and
# verifies the GPC0 readback), then actual_brightness must read 4. Any
# failure stops here; nothing further is tried (the kernel converges its
# own failures to safe-on or reports a fault).
#
# backlight_mode=pwm does not change what is written at boot: the
# qualified pwm_* / safe_brightness fields are an audit record of what was
# qualified. The user's persisted brightness level is restored afterwards
# by S98 (nebulaos-backlight, nbl_boot_restore).
ndq_apply_backlight() {
	backlight_mode="$1"
	safe_brightness="$2"

	if [ ! -w "$NDQ_BACKLIGHT_SYSFS/bl_power" ] || [ ! -w "$NDQ_BACKLIGHT_SYSFS/brightness" ]; then
		ndq_log "apply-backlight: $NDQ_BACKLIGHT_SYSFS/{bl_power,brightness} not present or not writable - kernel driver not loaded as expected, refusing to guess, leaving backlight at boot-preserve (already safe)"
		return 1
	fi

	if ! printf '0' > "$NDQ_BACKLIGHT_SYSFS/bl_power" 2>/dev/null; then
		ndq_log "apply-backlight: write of 0 to $NDQ_BACKLIGHT_SYSFS/bl_power failed"
		return 1
	fi
	if ! printf '4' > "$NDQ_BACKLIGHT_SYSFS/brightness" 2>/dev/null; then
		ndq_log "apply-backlight: write of 4 (safe-on) to $NDQ_BACKLIGHT_SYSFS/brightness failed"
		return 1
	fi

	actual=$(cat "$NDQ_BACKLIGHT_SYSFS/actual_brightness" 2>/dev/null)
	if [ "$actual" != "4" ]; then
		ndq_log "apply-backlight: wrote brightness 4 but $NDQ_BACKLIGHT_SYSFS/actual_brightness reads '$actual' - safe-on not confirmed, stopping here"
		return 1
	fi
	ndq_log "apply-backlight: confirmed safe-on (actual_brightness 4) via $NDQ_BACKLIGHT_SYSFS"

	if [ "$backlight_mode" = "pwm" ]; then
		ndq_log "apply-backlight: backlight_mode=pwm (qualified safe_brightness=$safe_brightness) - the user's persisted level is restored later by S98 (nebulaos-backlight)"
	else
		ndq_log "apply-backlight: backlight_mode=fixed-safe-on, done"
	fi
	return 0
}

# ============================================================
# Deferred fields (sleep / touch-wake)
# ============================================================
#
# ndq_apply_deferred_fields SLEEP_ENABLED TOUCH_WAKE_ENABLED TOUCH_WAKE_MODE
#                            FIRST_TOUCH_POLICY
#
# sleep_enabled=1 does NOT put the display to sleep here - that would be a
# strange thing for a boot-time apply step to do unprompted (a human or
# GuppyScreen's own idle timer decides WHEN to sleep; that mechanism is out
# of scope for this mission - see this file's own header and the mission
# spec). What sleep_enabled=1 actually gates is starting the touch-wake
# watcher daemon (nebulaos-display-sleep-wake-controller.sh via its
# S98 init.d script) so that IF the display is later put to sleep by
# whatever future mechanism triggers it, the watcher is already running
# and ready to wake it on the next real touch. If sleep_enabled=0 (or, in
# principle, anything other than the validated "1"), the watcher is never
# started - no persistent process is left running for a capability the
# config says is not available.
#
# first_touch_policy is read/validated but still has no real consumer -
# genuinely not yet implemented, same as before this change.
ndq_apply_deferred_fields() {
	sleep_enabled="$1"
	touch_wake_enabled="$2"
	touch_wake_mode="$3"
	first_touch_policy="$4"

	if [ "$sleep_enabled" != "1" ]; then
		ndq_log "apply-deferred: sleep_enabled=$sleep_enabled - sleep capability not available, not starting the touch-wake watcher"
		return 0
	fi

	if [ "$touch_wake_mode" != "polling" ]; then
		ndq_log "apply-deferred: sleep_enabled=1 but touch_wake_mode=$touch_wake_mode (not polling) - sleep is available but touch-wake is not, not starting the watcher"
		return 0
	fi

	if [ ! -x "$NDQ_SLEEP_WAKE_INITD" ]; then
		ndq_log "apply-deferred: sleep_enabled=1 touch_wake_mode=polling but $NDQ_SLEEP_WAKE_INITD is not present/executable - cannot start the touch-wake watcher"
		return 1
	fi

	if "$NDQ_SLEEP_WAKE_INITD" start; then
		ndq_log "apply-deferred: sleep_enabled=1 touch_wake_mode=polling - touch-wake watcher start requested via $NDQ_SLEEP_WAKE_INITD (first_touch_policy=$first_touch_policy)"
		return 0
	fi

	ndq_log "apply-deferred: $NDQ_SLEEP_WAKE_INITD start failed"
	return 1
}

# ============================================================
# Top-level orchestration
# ============================================================
#
# ndq_apply_all FILE - validates the whole file, and ONLY if that
# succeeds, applies touch then backlight, aborting the remaining sequence
# immediately on the first hardware-apply failure (never a partial/best-
# guess application). Returns 0 only if every step that was supposed to
# run actually succeeded. Any non-zero return means "stop, do nothing
# further" - the caller (the init.d script) must not retry or work around
# a failure here, both drivers' own boot defaults are already safe.
ndq_apply_all() {
	file="$1"

	if ! ndq_validate "$file"; then
		return 1
	fi

	touch_mode=$(ndq_get_field "$file" touch_mode)
	backlight_mode=$(ndq_get_field "$file" backlight_mode)
	safe_brightness=$(ndq_get_field "$file" safe_brightness)
	sleep_enabled=$(ndq_get_field "$file" sleep_enabled)
	touch_wake_enabled=$(ndq_get_field "$file" touch_wake_enabled)
	touch_wake_mode=$(ndq_get_field "$file" touch_wake_mode)
	first_touch_policy=$(ndq_get_field "$file" first_touch_policy)

	if ! ndq_apply_touch "$touch_mode"; then
		ndq_log "apply-all: touch apply failed - stopping here, backlight left untouched (boot-preserve, already safe)"
		return 1
	fi

	if ! ndq_apply_backlight "$backlight_mode" "$safe_brightness"; then
		ndq_log "apply-all: backlight apply failed"
		return 1
	fi

	# Deliberately NOT gating ndq_apply_all's own return value on this
	# call's result: by this point touch and backlight - the two things
	# that actually matter for "is the screen safely lit right now" - have
	# already succeeded. A failure to start the touch-wake watcher is a
	# degraded-capability condition (sleep/wake just won't be available
	# this boot), not a display-safety failure, and must never be conflated
	# with the "nothing was applied, defaults stand" meaning ndq_apply_all
	# returning non-zero has everywhere else in this file.
	ndq_apply_deferred_fields "$sleep_enabled" "$touch_wake_enabled" "$touch_wake_mode" "$first_touch_policy"

	ndq_log "apply-all: qualified display configuration applied successfully"
	return 0
}
