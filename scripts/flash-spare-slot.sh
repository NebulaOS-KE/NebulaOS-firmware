#!/bin/sh
#
# Writes the custom xImage/rootfs.squashfs to this board's fixed custom-OS
# slot (kernel2/rootfs2, FIRMWARE.md sec 19/23) and verifies every write
# against a checksum before reporting success - deliberately never touches
# the stock slot (kernel/rootfs, p5/p7) and never flips the ota marker
# itself (that's a separate, deliberate step - see S00revert-safety for
# what happens once the custom image actually boots).
#
# Run this ON the device, e.g.:
#   scp flash-spare-slot.sh root@<printer-ip>:/tmp/
#   ssh root@<printer-ip> 'sh /tmp/flash-spare-slot.sh --check-only /path/to/xImage /path/to/rootfs.squashfs [/path/to/build-manifest.txt]'
#   ssh root@<printer-ip> 'sh /tmp/flash-spare-slot.sh /path/to/xImage /path/to/rootfs.squashfs [/path/to/build-manifest.txt]'
#
# Every check below aborts loudly rather than guessing or proceeding on a
# mismatch - this script is the one place where a silent mistake could
# overrun into a neighboring partition, so nothing here is allowed to be
# approximate.
#
# 2026-07-23: an optional 3rd argument (build-manifest.txt, produced by
# 05-final-build.sh) is checked against BEFORE writing anything, closing a
# real gap found live - a transfer truncated mid-flight once, leaving a
# bad file on the device that this script's own write-verify loop
# couldn't have caught on its own (it only proves the device matches
# whatever local file it was given, not that the local file matches what
# the build host actually produced).
#
# Final-seal mission (2026-07-27): full rewrite to close a real, live
# safety incident. The previous version's "refuse to write the currently
# booted root" check compared /proc/mounts' root source against the
# target partition - but on this device /proc/mounts reports the root
# source as the literal string "/dev/root", which doesn't even exist as a
# file, so that comparison could never match regardless of which
# partition was actually live. This went unnoticed for the entire prior
# mission because every earlier use happened to run while the device was
# genuinely booted from stock - the custom slot really was idle every
# time, by circumstance, not because the check caught otherwise. The
# first time this script ran again after the device had permanently moved
# to running custom as its steady state, nothing stopped it from writing
# directly onto the live, currently-executing rootfs - a cascade of
# segfaults across running processes (pages faulted in against a backing
# device being concurrently overwritten), requiring a manual power cycle
# to recover. The write itself completed and was verified byte-correct
# afterward (lucky, not safe).
#
# This rewrite: (1) resolves the live root from /proc/cmdline's own
# root= parameter, not /proc/mounts' aliased name; (2) models both real
# slots explicitly and verifies their partlabel symlinks and (where
# checkable) major:minor device identity, rather than trusting hardcoded
# paths blindly; (3) refuses a mixed/inconsistent target kernel+rootfs
# pair, not just a literal match against the live root; (4) provides a
# --check-only preflight mode that performs every destructive-safety
# check with zero writes, used both for standalone qualification and
# (unconditionally) a second time immediately before any real write, so a
# stale check-only pass is never treated as standing authorization; (5)
# fails closed - "unknown" is always a refusal, never "probably safe".
#
# The preflight/decision functions below are also exercised directly by
# tests/flash-spare-slot-preflight-tests.sh, using CMDLINE_PATH/DEV_PREFIX
# overrides to point at fixture files instead of real hardware - the
# exact same functions (and, for the --check-only path specifically, the
# exact same CLI entry point) run in both contexts, so there is only one
# implementation of this safety logic to keep correct. Two independent
# env vars control test behavior:
#   FLASH_SPARE_SLOT_TEST_MODE=1     relaxes is_real_device() to accept
#                                    any existing fixture path instead of
#                                    requiring a real block special file
#                                    (fixtures can't create those without
#                                    root) - safe to set for ANY test,
#                                    including full end-to-end CLI runs.
#   FLASH_SPARE_SLOT_NO_AUTORUN=1    suppresses the auto-call to main()
#                                    at the bottom, for tests that only
#                                    want to source the file and call an
#                                    individual function directly.
#
# 2026-10-14 (human decision: NebulaOS may occupy BOTH A/B slots): the
# target slot is selectable with --target-slot 1|2. The default is still
# slot 2, so every existing invocation means exactly what it meant before.
# Nothing else about the safety case changes: whichever slot is named,
# run_preflight() resolves the live slot from /proc/cmdline (twice, the
# second time immediately before the write) and refuses the slot the
# system is running from. The Hardware Agent passes --target-slot 1 only
# when NebulaOS runs from slot 2 and the human-owned device profile allows
# the other slot to be overwritten (docs/HARDWARE_AGENT.md).

# --- Overridable for offline testing - real use never sets these ---
CMDLINE_PATH="${CMDLINE_PATH:-/proc/cmdline}"
DEV_PREFIX="${DEV_PREFIX:-}"

die() {
	echo "ABORT: $1" 1>&2
	exit 1
}

# Known, verified slot pairs (FIRMWARE.md sec 19/23). This board's A/B
# layout is two FIXED physical slots, not a generic rotating pair: slot 1
# is Creality's own stock kernel/rootfs (p5/p7), slot 2 is this project's
# own permanent custom-OS home (p6/p8 - confirmed live via
# S00revert-safety's own header comment: "this image's own home", not a
# rotating spare that alternates on every update). This table is verified
# against real partlabel symlinks in verify_slot_labels(), not just
# assumed correct because it was correct once.
SLOT1_KERNEL="$DEV_PREFIX/dev/mmcblk0p5"
SLOT1_ROOTFS="$DEV_PREFIX/dev/mmcblk0p7"
SLOT1_MARKER="ota:kernel"
SLOT1_KERNEL_LABEL="$DEV_PREFIX/dev/disk/by-partlabel/kernel"
SLOT1_ROOTFS_LABEL="$DEV_PREFIX/dev/disk/by-partlabel/rootfs"

SLOT2_KERNEL="$DEV_PREFIX/dev/mmcblk0p6"
SLOT2_ROOTFS="$DEV_PREFIX/dev/mmcblk0p8"
SLOT2_MARKER="ota:kernel2"
SLOT2_KERNEL_LABEL="$DEV_PREFIX/dev/disk/by-partlabel/kernel2"
SLOT2_ROOTFS_LABEL="$DEV_PREFIX/dev/disk/by-partlabel/rootfs2"

# Real, confirmed partition capacities (FIRMWARE.md sec 4b/19) - not
# recomputed from /proc/partitions at runtime, so a corrupted or
# unexpected partition table can't silently change what this script
# considers "safe".
# Which slot to write. 2 unless --target-slot says otherwise; never read
# from the environment, so an inherited variable cannot retarget a write.
TARGET_SLOT=2

KERNEL_PART_BYTES=8388608
ROOTFS_PART_BYTES=524288000

# Resolves a path to its canonical form. Falls back to the literal input
# if readlink can't resolve it (e.g. a PARTUUID=/LABEL= cmdline value
# with no matching symlink) - callers must treat a fallback result that
# isn't a real device (is_real_device below) as UNRESOLVED, not "safe by
# omission".
canon() {
	readlink -f "$1" 2>/dev/null || echo "$1"
}

# Real hardware requires an actual block special file. Test mode (fixture
# files/symlinks standing in for real /dev nodes, which can't be created
# without root) only requires the path to exist - the fixture's job is to
# exercise the resolution/decision logic, not to re-prove that BusyBox's
# block-device layer works.
is_real_device() {
	if [ -n "$FLASH_SPARE_SLOT_TEST_MODE" ]; then
		[ -e "$1" ]
	else
		[ -b "$1" ]
	fi
}

# major:minor, only meaningful for real block special files - a no-op
# (empty string) for anything else, so this check is naturally inert
# during fixture testing (which never uses real device nodes) and fully
# active against real hardware.
#
# Real bug found live during Phase E qualification (2026-07-27): `-b`
# follows symlinks (so `[ -b "$kernel_label" ]` correctly says "yes, this
# ultimately points at a block device"), but plain `ls -ldn` does NOT
# dereference symlinks - given a partlabel symlink path it printed the
# symlink's OWN metadata (mode "l...", "size" = target string length),
# not the resolved device's real major:minor, causing a false refusal
# ("does not match its own label symlink (15:Mar)" - that "15:Mar" was
# the symlink's link-target length and month field, not a device number).
# `-L` makes ls stat the resolved target instead - a no-op for the
# non-symlink case (kernel_dev/rootfs_dev), correct for the label-symlink
# case.
dev_id() {
	[ -b "$1" ] || return 0
	ls -ldnL "$1" 2>/dev/null | awk '{gsub(",",""); print $5":"$6}'
}

# Verifies one slot's own two partlabel symlinks resolve to exactly the
# device nodes this script hardcodes for that slot, and (on real
# hardware) that the device nodes' major:minor actually matches what
# those symlinks point at - if the GPT ever changes, this must fail
# loudly rather than silently target the wrong partition. Checked for
# BOTH slots (not just the target) so an unexpected GPT is caught
# regardless of which slot it affects.
verify_slot_labels() {
	slot_name="$1"; kernel_dev="$2"; rootfs_dev="$3"; kernel_label="$4"; rootfs_label="$5"

	[ -e "$kernel_label" ] || die "$slot_name: kernel partlabel symlink $kernel_label does not exist - cannot verify slot mapping, refusing"
	[ -e "$rootfs_label" ] || die "$slot_name: rootfs partlabel symlink $rootfs_label does not exist - cannot verify slot mapping, refusing"
	is_real_device "$kernel_dev" || die "$slot_name: $kernel_dev is not a real block device - refusing"
	is_real_device "$rootfs_dev" || die "$slot_name: $rootfs_dev is not a real block device - refusing"

	resolved_kernel=$(canon "$kernel_label")
	resolved_rootfs=$(canon "$rootfs_label")
	[ "$resolved_kernel" = "$(canon "$kernel_dev")" ] || \
		die "$slot_name: kernel label $kernel_label resolves to $resolved_kernel, expected $kernel_dev - refusing (possible GPT change)"
	[ "$resolved_rootfs" = "$(canon "$rootfs_dev")" ] || \
		die "$slot_name: rootfs label $rootfs_label resolves to $resolved_rootfs, expected $rootfs_dev - refusing (possible GPT change)"

	kid=$(dev_id "$kernel_dev"); klid=$(dev_id "$kernel_label")
	[ -z "$kid" ] || [ -z "$klid" ] || [ "$kid" = "$klid" ] || \
		die "$slot_name: kernel device $kernel_dev major:minor ($kid) does not match its own label symlink ($klid) - refusing (unexpected device mapping)"
	rid=$(dev_id "$rootfs_dev"); rlid=$(dev_id "$rootfs_label")
	[ -z "$rid" ] || [ -z "$rlid" ] || [ "$rid" = "$rlid" ] || \
		die "$slot_name: rootfs device $rootfs_dev major:minor ($rid) does not match its own label symlink ($rlid) - refusing (unexpected device mapping)"
}

# Resolves the live root device from the kernel's own reported command
# line - the one source of truth that isn't an aliased/legacy name (see
# the /proc/mounts "/dev/root" bug this replaced). Understands the
# standard root=/dev/..., root=PARTUUID=..., root=LABEL=..., and
# root=UUID=... forms. Fails closed if root= can't be parsed or doesn't
# resolve to a real device - "unknown" must never be treated as
# "probably safe".
resolve_active_rootfs() {
	[ -e "$CMDLINE_PATH" ] || die "cannot read $CMDLINE_PATH - refusing to proceed without this safety check"
	root_cmdline=$(sed -n 's/.*\broot=\(\S*\).*/\1/p' "$CMDLINE_PATH")
	[ -n "$root_cmdline" ] || die "no root= parameter found in $CMDLINE_PATH - refusing to proceed without this safety check"

	case "$root_cmdline" in
		PARTUUID=*) root_path="$DEV_PREFIX/dev/disk/by-partuuid/${root_cmdline#PARTUUID=}" ;;
		LABEL=*)    root_path="$DEV_PREFIX/dev/disk/by-label/${root_cmdline#LABEL=}" ;;
		UUID=*)     root_path="$DEV_PREFIX/dev/disk/by-uuid/${root_cmdline#UUID=}" ;;
		*)          root_path="$root_cmdline" ;;
	esac

	root_resolved=$(canon "$root_path")
	is_real_device "$root_resolved" || \
		die "root= value '$root_cmdline' (resolved: $root_resolved) is not a real block device - cannot verify the live slot, refusing to proceed"
	echo "$root_resolved"
}

# Identifies which known slot (1 or 2) a canonicalized rootfs device
# belongs to. Echoes "1" or "2" and returns 0, or returns 1 (no output)
# for unknown/no-match - callers must treat that as a refusal, never a
# default/guessed slot.
identify_slot_by_rootfs() {
	target="$1"
	s1=$(canon "$SLOT1_ROOTFS"); s2=$(canon "$SLOT2_ROOTFS")
	if [ "$target" = "$s1" ]; then echo 1; return 0; fi
	if [ "$target" = "$s2" ]; then echo 2; return 0; fi
	return 1
}

identify_slot_by_kernel() {
	target="$1"
	s1=$(canon "$SLOT1_KERNEL"); s2=$(canon "$SLOT2_KERNEL")
	if [ "$target" = "$s1" ]; then echo 1; return 0; fi
	if [ "$target" = "$s2" ]; then echo 2; return 0; fi
	return 1
}

# The one preflight, run identically whether invoked as --check-only or
# immediately before a real write - no second implementation to drift out
# of sync with this one. Dies (exit 1) on any refusal; on success, sets
# PREFLIGHT_TARGET_KERNEL/PREFLIGHT_TARGET_ROOTFS/PREFLIGHT_KERNEL_SIZE/
# PREFLIGHT_ROOTFS_SIZE for the caller.
run_preflight() {
	kernel_img="$1"; rootfs_img="$2"; manifest="$3"

	[ -n "$kernel_img" ] && [ -n "$rootfs_img" ] || \
		die "usage: $0 [--check-only] <xImage> <rootfs.squashfs> [build-manifest.txt]"
	[ -f "$kernel_img" ] || die "$kernel_img does not exist"
	[ -f "$rootfs_img" ] || die "$rootfs_img does not exist"

	echo "=== Preflight: slot mapping ==="
	verify_slot_labels "slot1"  "$SLOT1_KERNEL" "$SLOT1_ROOTFS" "$SLOT1_KERNEL_LABEL" "$SLOT1_ROOTFS_LABEL"
	verify_slot_labels "slot2" "$SLOT2_KERNEL" "$SLOT2_ROOTFS" "$SLOT2_KERNEL_LABEL" "$SLOT2_ROOTFS_LABEL"
	# A slot table where both slots somehow resolve to the same real
	# device is a corrupted/ambiguous mapping in its own right, distinct
	# from any single symlink mismatch caught above.
	[ "$(canon "$SLOT1_ROOTFS")" != "$(canon "$SLOT2_ROOTFS")" ] || \
		die "slot1 and slot2 rootfs partitions resolve to the same device - refusing (ambiguous/corrupted slot mapping)"
	[ "$(canon "$SLOT1_KERNEL")" != "$(canon "$SLOT2_KERNEL")" ] || \
		die "slot1 and slot2 kernel partitions resolve to the same device - refusing (ambiguous/corrupted slot mapping)"
	echo "  slot1: kernel=$SLOT1_KERNEL rootfs=$SLOT1_ROOTFS marker=$SLOT1_MARKER - verified"
	echo "  slot2: kernel=$SLOT2_KERNEL rootfs=$SLOT2_ROOTFS marker=$SLOT2_MARKER - verified"

	echo "=== Preflight: active slot ==="
	active_rootfs=$(resolve_active_rootfs)
	active_slot=$(identify_slot_by_rootfs "$active_rootfs") || \
		die "live root device ($active_rootfs) does not match either known slot's rootfs partition - refusing (unknown/ambiguous active slot)"
	echo "  live root device: $active_rootfs"
	echo "  active slot: $active_slot"

	echo "=== Preflight: target slot ==="
	# The target is slot 2 unless --target-slot 1 was given - verify the
	# two target devices actually form one genuine, matching slot pair
	# rather than assuming it just because the constants have always
	# agreed before.
	case "$TARGET_SLOT" in
		1) target_kernel_canon=$(canon "$SLOT1_KERNEL"); target_rootfs_canon=$(canon "$SLOT1_ROOTFS") ;;
		2) target_kernel_canon=$(canon "$SLOT2_KERNEL"); target_rootfs_canon=$(canon "$SLOT2_ROOTFS") ;;
		*) die "target slot '$TARGET_SLOT' is not 1 or 2 - refusing" ;;
	esac
	target_kernel_slot=$(identify_slot_by_kernel "$target_kernel_canon") || \
		die "target kernel device ($target_kernel_canon) does not match any known slot's kernel partition - refusing"
	target_rootfs_slot=$(identify_slot_by_rootfs "$target_rootfs_canon") || \
		die "target rootfs device ($target_rootfs_canon) does not match any known slot's rootfs partition - refusing"
	[ "$target_kernel_slot" = "$target_rootfs_slot" ] || \
		die "target kernel belongs to slot $target_kernel_slot but target rootfs belongs to slot $target_rootfs_slot - refusing (mixed/invalid slot pair)"
	[ "$target_kernel_slot" = "$TARGET_SLOT" ] || \
		die "the requested target slot is $TARGET_SLOT but its devices belong to slot $target_kernel_slot - refusing"
	target_slot="$target_kernel_slot"
	echo "  target kernel: $target_kernel_canon (slot $target_kernel_slot)"
	echo "  target rootfs: $target_rootfs_canon (slot $target_rootfs_slot)"
	echo "  target slot: $target_slot (matched pair, confirmed)"

	echo "=== Preflight: live-target collision ==="
	if [ "$active_slot" = 1 ]; then active_kernel_for_slot=$(canon "$SLOT1_KERNEL"); else active_kernel_for_slot=$(canon "$SLOT2_KERNEL"); fi
	[ "$target_rootfs_canon" != "$active_rootfs" ] || \
		die "target rootfs ($target_rootfs_canon) is the currently active/live root device - refusing to overwrite the running system. Boot the other slot first, confirm this slot is genuinely idle, then retry."
	[ "$target_kernel_canon" != "$active_kernel_for_slot" ] || \
		die "target kernel ($target_kernel_canon) belongs to the currently active slot's kernel partition - refusing to overwrite the running system. Boot the other slot first, confirm this slot is genuinely idle, then retry."
	[ "$target_slot" != "$active_slot" ] || \
		die "target slot ($target_slot) is the currently active slot - refusing to overwrite the running system. Boot the other slot first, confirm this slot is genuinely idle, then retry."
	echo "  target slot $target_slot is INACTIVE (active slot is $active_slot) - safe to target"

	echo "=== Preflight: image sizes ==="
	kernel_size=$(wc -c < "$kernel_img")
	rootfs_size=$(wc -c < "$rootfs_img")
	[ "$kernel_size" -gt 0 ] || die "$kernel_img is empty"
	[ "$rootfs_size" -gt 0 ] || die "$rootfs_img is empty"
	[ "$kernel_size" -le "$KERNEL_PART_BYTES" ] || \
		die "xImage is $kernel_size bytes, exceeds kernel partition capacity of $KERNEL_PART_BYTES bytes"
	[ "$rootfs_size" -le "$ROOTFS_PART_BYTES" ] || \
		die "rootfs.squashfs is $rootfs_size bytes, exceeds rootfs partition capacity of $ROOTFS_PART_BYTES bytes"
	echo "  xImage:          $kernel_size / $KERNEL_PART_BYTES bytes ($(( kernel_size * 100 / KERNEL_PART_BYTES ))% full)"
	echo "  rootfs.squashfs: $rootfs_size / $ROOTFS_PART_BYTES bytes ($(( rootfs_size * 100 / ROOTFS_PART_BYTES ))% full)"

	echo "=== Preflight: manifest hash verification ==="
	if [ -n "$manifest" ]; then
		[ -f "$manifest" ] || die "manifest $manifest does not exist"
		get_field() { grep "^$1=" "$manifest" | cut -d= -f2-; }

		expect_kernel_size=$(get_field xImage_size)
		expect_kernel_sha256=$(get_field xImage_sha256)
		expect_rootfs_size=$(get_field rootfs_squashfs_size)
		expect_rootfs_sha256=$(get_field rootfs_squashfs_sha256)

		[ -n "$expect_kernel_size" ] && [ -n "$expect_kernel_sha256" ] || \
			die "manifest $manifest missing xImage_size/xImage_sha256"
		[ -n "$expect_rootfs_size" ] && [ -n "$expect_rootfs_sha256" ] || \
			die "manifest $manifest missing rootfs_squashfs_size/rootfs_squashfs_sha256"

		[ "$kernel_size" = "$expect_kernel_size" ] || \
			die "xImage size $kernel_size does not match manifest ($expect_kernel_size) - transfer likely truncated or wrong file"
		[ "$rootfs_size" = "$expect_rootfs_size" ] || \
			die "rootfs.squashfs size $rootfs_size does not match manifest ($expect_rootfs_size) - transfer likely truncated or wrong file"

		actual_kernel_sha256=$(sha256sum "$kernel_img" | awk '{print $1}')
		actual_rootfs_sha256=$(sha256sum "$rootfs_img" | awk '{print $1}')
		[ "$actual_kernel_sha256" = "$expect_kernel_sha256" ] || \
			die "xImage sha256 $actual_kernel_sha256 does not match manifest ($expect_kernel_sha256)"
		[ "$actual_rootfs_sha256" = "$expect_rootfs_sha256" ] || \
			die "rootfs.squashfs sha256 $actual_rootfs_sha256 does not match manifest ($expect_rootfs_sha256)"

		echo "  manifest verified OK: both files match $manifest exactly (size + sha256)"
	else
		echo "  WARNING: no build manifest given - skipping transfer-integrity verification against the build host" >&2
	fi

	echo "=== PREFLIGHT SUMMARY ==="
	echo "  active slot:   $active_slot"
	echo "  target slot:   $target_slot"
	echo "  target kernel: inactive, verified"
	echo "  target rootfs: inactive, verified"
	if [ -n "$manifest" ]; then echo "  manifest:      valid"; else echo "  manifest:      not provided"; fi
	echo "  capacities:    valid"
	echo "  slot pair:     valid"
	echo "  result:        SAFE TO FLASH"

	PREFLIGHT_TARGET_KERNEL="$target_kernel_canon"
	PREFLIGHT_TARGET_ROOTFS="$target_rootfs_canon"
	PREFLIGHT_KERNEL_SIZE="$kernel_size"
	PREFLIGHT_ROOTFS_SIZE="$rootfs_size"
}

write_and_verify() {
	src="$1"; dev="$2"; size="$3"; name="$4"

	src_sum=$(md5sum "$src" | awk '{print $1}')

	echo "Writing $name ($size bytes) to $dev ..."
	dd if="$src" of="$dev" bs=1M conv=fsync 2>/dev/null

	# Read back exactly $size bytes (never the whole partition -
	# deliberate, so this comparison can never be fooled by leftover
	# trailing data from a previous, larger image) and compare checksums.
	dev_sum=$(dd if="$dev" bs=1M count=$(( (size + 1048575) / 1048576 )) 2>/dev/null | \
		head -c "$size" | md5sum | awk '{print $1}')

	[ "$src_sum" = "$dev_sum" ] || \
		die "$name write verification FAILED: source md5 $src_sum != device md5 $dev_sum"

	echo "$name write verified OK (md5 $src_sum)"
}

main() {
	check_only=false
	while :; do
		case "${1:-}" in
			--check-only) check_only=true; shift ;;
			--target-slot)
				case "${2:-}" in
					1|2) TARGET_SLOT="$2"; shift 2 ;;
					*) die "--target-slot takes 1 or 2, got '${2:-}'" ;;
				esac ;;
			--*) die "unknown option: $1 (usage: $0 [--check-only] [--target-slot 1|2] <xImage> <rootfs.squashfs> [build-manifest.txt])" ;;
			*) break ;;
		esac
	done
	[ "$#" -le 3 ] || die "unexpected extra arguments: $* (usage: $0 [--check-only] [--target-slot 1|2] <xImage> <rootfs.squashfs> [build-manifest.txt])"
	kernel_img="$1"; rootfs_img="$2"; manifest="$3"

	run_preflight "$kernel_img" "$rootfs_img" "$manifest"

	if [ "$check_only" = "true" ]; then
		echo
		echo "Check-only mode: no write attempted."
		exit 0
	fi

	# Repeat the full preflight immediately before writing - a check-only
	# pass (or an earlier point in this same invocation) is never treated
	# as standing authorization that remains valid indefinitely. Nothing
	# is assumed to still be true; it's re-verified.
	echo
	echo "Re-running preflight immediately before write (no time-of-check/time-of-use gap)..."
	run_preflight "$kernel_img" "$rootfs_img" "$manifest"

	write_and_verify "$kernel_img" "$PREFLIGHT_TARGET_KERNEL" "$PREFLIGHT_KERNEL_SIZE" "xImage"
	write_and_verify "$rootfs_img" "$PREFLIGHT_TARGET_ROOTFS" "$PREFLIGHT_ROOTFS_SIZE" "rootfs.squashfs"

	echo
	echo "Both images written and verified. The ota marker has NOT been touched -"
	echo "the device will still boot the current active slot on the next reboot."
	echo "Flipping the marker to actually attempt the new image is a separate,"
	echo "deliberate step."
}

if [ -z "$FLASH_SPARE_SLOT_NO_AUTORUN" ]; then
	set -e
	main "$@"
fi
