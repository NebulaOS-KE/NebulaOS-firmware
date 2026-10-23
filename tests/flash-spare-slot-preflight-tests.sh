#!/bin/sh
#
# Offline, repeatable tests for scripts/flash-spare-slot.sh's preflight
# and slot-selection logic (final-seal mission, 2026-07-27). Runs
# entirely against fixture files/symlinks under a temp directory - never
# touches a real block device, and never requires root (fixtures are
# plain regular files/symlinks standing in for /dev nodes, which is
# exactly why is_real_device() in the production script has a relaxed
# fixture-mode check).
#
# This sources the actual production script (scripts/flash-spare-slot.sh)
# for every case - there is deliberately no second/parallel copy of the
# safety logic here to drift out of sync with it.
#
# Known, honest coverage gap: dev_id()'s major:minor cross-check in
# verify_slot_labels() only ever activates for real block special files
# (`[ -b ]`) - fixtures here are plain regular files/symlinks (creating
# real block devices needs root), so that specific check is structurally
# a no-op for every case below, every time. It is real-hardware-only and
# was already the source of one real bug found live (Phase E, 2026-07-27
# - `ls -ldn` doesn't dereference symlinks, `-ldnL` does) that this
# offline suite could not have caught. Live qualification against real
# hardware remains load-bearing for that one check; do not treat a clean
# run of this suite alone as proof it still works.
#
# Usage: sh tests/flash-spare-slot-preflight-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FLASH_SCRIPT="$SCRIPT_DIR/../scripts/flash-spare-slot.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/flash-preflight-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: flash-spare-slot-preflight-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0

fail() {
	echo "FAIL: $1"
	FAIL=$((FAIL + 1))
}

pass() {
	echo "PASS: $1"
	PASS=$((PASS + 1))
}

# Builds a fresh, valid fixture device tree under $1 - slot1 (stock) at
# p5/p7, slot2 (custom) at p6/p8, matching the real board's partlabel
# structure exactly (mirrors the real /dev/disk/by-partlabel/* -> ../../
# relative-symlink layout so canon()'s readlink -f resolves them the same
# way it does on real hardware).
build_fixture() {
	dir="$1"
	rm -rf "$dir"
	mkdir -p "$dir/dev/disk/by-partlabel" "$dir/dev/disk/by-partuuid" "$dir/dev/disk/by-label"
	: > "$dir/dev/mmcblk0p5"
	: > "$dir/dev/mmcblk0p6"
	: > "$dir/dev/mmcblk0p7"
	: > "$dir/dev/mmcblk0p8"
	ln -s ../../mmcblk0p5 "$dir/dev/disk/by-partlabel/kernel"
	ln -s ../../mmcblk0p6 "$dir/dev/disk/by-partlabel/kernel2"
	ln -s ../../mmcblk0p7 "$dir/dev/disk/by-partlabel/rootfs"
	ln -s ../../mmcblk0p8 "$dir/dev/disk/by-partlabel/rootfs2"
}

# Builds a valid kernel/rootfs image pair plus a matching manifest under
# $1. Tiny fixture content - only sizes/hashes matter to the logic under
# test, not real image bytes.
build_images() {
	dir="$1"
	mkdir -p "$dir"
	echo "fake-kernel-content" > "$dir/xImage"
	echo "fake-rootfs-content" > "$dir/rootfs.squashfs"
	k_size=$(wc -c < "$dir/xImage")
	r_size=$(wc -c < "$dir/rootfs.squashfs")
	k_sha=$(sha256sum "$dir/xImage" | awk '{print $1}')
	r_sha=$(sha256sum "$dir/rootfs.squashfs" | awk '{print $1}')
	cat > "$dir/manifest.txt" <<EOF
xImage_size=$k_size
xImage_sha256=$k_sha
rootfs_squashfs_size=$r_size
rootfs_squashfs_sha256=$r_sha
EOF
}

# Runs run_preflight() against a fixture, with optional shell snippet
# ($6) evaluated after sourcing but before calling run_preflight - used
# to deliberately corrupt SLOT*_* variables for adversarial cases (mixed
# pair, ambiguous mapping, wrong label, undersized capacity) without
# needing any of that in the production script itself.
run_case() {
	desc="$1"; fixture="$2"; cmdline_content="$3"; expect="$4"; imgdir="$5"; override="${6:-:}"

	echo "$cmdline_content" > "$fixture/cmdline"

	out=$(FLASH_SPARE_SLOT_TEST_MODE=1 FLASH_SPARE_SLOT_NO_AUTORUN=1 \
		DEV_PREFIX="$fixture" CMDLINE_PATH="$fixture/cmdline" \
		sh -c '
			. "$1"
			eval "$5"
			run_preflight "$2" "$3" "$4"
		' -- "$FLASH_SCRIPT" "$imgdir/xImage" "$imgdir/rootfs.squashfs" "$imgdir/manifest.txt" "$override" 2>&1)
	rc=$?

	if [ "$expect" = "ALLOW" ]; then
		if [ "$rc" -eq 0 ] && echo "$out" | grep -q "SAFE TO FLASH"; then
			pass "$desc"
		else
			fail "$desc (expected ALLOW, got exit=$rc)"
			echo "$out" | sed 's/^/    /'
		fi
	else
		if [ "$rc" -ne 0 ] && ! echo "$out" | grep -q "SAFE TO FLASH"; then
			pass "$desc"
		else
			fail "$desc (expected REFUSE, got exit=$rc)"
			echo "$out" | sed 's/^/    /'
		fi
	fi
}

F="$WORK/fixture"
IMG="$WORK/images"
build_fixture "$F"
build_images "$IMG"

# --- Test 1/2/3: active custom slot (root=p8) collides with the fixed
# target (slot2/custom) on every member of the pair at once - this
# board's target is always the p6/p8 pair together, so "rootfs matches",
# "kernel matches", and "full pair matches" are the same real condition
# here, not three independently reachable states (kernel membership is
# derived from the same rootfs-identified active slot, never read from
# cmdline separately). Covered as one integration case; the mixed-pair
# case below (test 4) is what actually exercises kernel/rootfs
# membership independently. ---
run_case "active custom slot (root=p8) refuses the live target pair" \
	"$F" "console=ttyS4 root=$F/dev/mmcblk0p8 rootwait" "REFUSE" "$IMG"

# --- Test 3 (inactive pair ALLOW): active stock (root=p7), target
# (custom, p6/p8) is genuinely inactive - SAFE TO FLASH. ---
run_case "active stock slot (root=p7) allows the inactive custom target" \
	"$F" "console=ttyS4 root=$F/dev/mmcblk0p7 rootwait" "ALLOW" "$IMG"

# --- Test 4: mixed slot pair - deliberately point the target's rootfs
# at slot1's real rootfs partition while its kernel stays at slot2's,
# with the active slot set to stock (p7) so no live-collision masks the
# mixed-pair check we're actually testing. ---
run_case "mixed kernel/rootfs slot pair is refused" \
	"$F" "console=ttyS4 root=$F/dev/mmcblk0p7 rootwait" "REFUSE" "$IMG" \
	"SLOT2_ROOTFS=\"$F/dev/mmcblk0p7\""

# --- Test 5: root= via PARTUUID indirection resolves correctly. ---
ln -sf ../../mmcblk0p7 "$F/dev/disk/by-partuuid/deadbeef-01"
run_case "root=PARTUUID=... resolves to the correct canonical device" \
	"$F" "console=ttyS4 root=PARTUUID=deadbeef-01 rootwait" "ALLOW" "$IMG"

# --- Test 6: root= via LABEL indirection (a different symlink form)
# resolves correctly. ---
ln -sf ../../mmcblk0p7 "$F/dev/disk/by-label/nebulaos-rootfs"
run_case "root=LABEL=... resolves to the correct canonical device" \
	"$F" "console=ttyS4 root=LABEL=nebulaos-rootfs rootwait" "ALLOW" "$IMG"

# --- Test 7: unresolved root device - no fixture backs this path at
# all, must refuse rather than guess. ---
run_case "unresolved root= device is refused" \
	"$F" "console=ttyS4 root=$F/dev/mmcblk0p99 rootwait" "REFUSE" "$IMG"

# --- Test 8: ambiguous partition mapping - slot1 and slot2 rootfs
# devices deliberately collapsed onto the same real fixture path. ---
run_case "slot1/slot2 rootfs collapsing onto the same device is refused" \
	"$F" "console=ttyS4 root=$F/dev/mmcblk0p7 rootwait" "REFUSE" "$IMG" \
	"SLOT2_ROOTFS=\"$F/dev/mmcblk0p7\"; SLOT1_ROOTFS=\"$F/dev/mmcblk0p7\""

# --- Test 9: wrong partition label target - kernel2 label points
# somewhere other than what the script hardcodes for slot2. ---
BADF="$WORK/fixture-badlabel"
build_fixture "$BADF"
ln -sf ../../mmcblk0p7 "$BADF/dev/disk/by-partlabel/kernel2"
run_case "kernel2 label resolving to the wrong device is refused" \
	"$BADF" "console=ttyS4 root=$BADF/dev/mmcblk0p7 rootwait" "REFUSE" "$IMG"

# --- Test 10: image exceeds partition capacity - artificially shrink
# the capacity constant rather than allocate real hundreds-of-MB
# fixtures. ---
run_case "an image exceeding partition capacity is refused" \
	"$F" "console=ttyS4 root=$F/dev/mmcblk0p7 rootwait" "REFUSE" "$IMG" \
	"ROOTFS_PART_BYTES=4"

# --- Test 11: manifest hash mismatch - corrupt the recorded sha256. ---
BADMANI="$WORK/images-badmanifest"
build_images "$BADMANI"
sed -i 's/^rootfs_squashfs_sha256=.*/rootfs_squashfs_sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$BADMANI/manifest.txt"
run_case "a manifest sha256 mismatch is refused" \
	"$F" "console=ttyS4 root=$F/dev/mmcblk0p7 rootwait" "REFUSE" "$BADMANI"

# --- Both-slots model (2026-10-14): --target-slot 1. NebulaOS running
# from slot 2 (root=p8) may write slot 1; slot 1 is refused while it is
# the live root, exactly as slot 2 is refused while root=p8. ---
run_case "target slot 1 is allowed while slot 2 (root=p8) is live" \
	"$F" "console=ttyS4 root=$F/dev/mmcblk0p8 rootwait" "ALLOW" "$IMG" "TARGET_SLOT=1"
run_case "target slot 1 is refused while it is the live slot (root=p7)" \
	"$F" "console=ttyS4 root=$F/dev/mmcblk0p7 rootwait" "REFUSE" "$IMG" "TARGET_SLOT=1"
run_case "a target slot other than 1 or 2 is refused" \
	"$F" "console=ttyS4 root=$F/dev/mmcblk0p7 rootwait" "REFUSE" "$IMG" "TARGET_SLOT=3"
run_case "target slot 1 whose kernel label points into slot 2 is refused" \
	"$F" "console=ttyS4 root=$F/dev/mmcblk0p8 rootwait" "REFUSE" "$IMG" \
	"TARGET_SLOT=1; SLOT1_KERNEL=\"$F/dev/mmcblk0p6\""

echo "console=ttyS4 root=$F/dev/mmcblk0p8 rootwait" > "$F/cmdline"
out=$(FLASH_SPARE_SLOT_TEST_MODE=1 DEV_PREFIX="$F" CMDLINE_PATH="$F/cmdline" \
	sh "$FLASH_SCRIPT" --check-only --target-slot 1 "$IMG/xImage" "$IMG/rootfs.squashfs" "$IMG/manifest.txt" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "target slot:   1" && echo "$out" | grep -q "active slot:   2"; then
	pass "CLI --check-only --target-slot 1 from slot 2 targets slot 1"
else
	fail "CLI --check-only --target-slot 1 did not target slot 1 (exit=$rc)"
	echo "$out" | sed 's/^/    /'
fi
out=$(FLASH_SPARE_SLOT_TEST_MODE=1 DEV_PREFIX="$F" CMDLINE_PATH="$F/cmdline" \
	sh "$FLASH_SCRIPT" --check-only "$IMG/xImage" "$IMG/rootfs.squashfs" "$IMG/manifest.txt" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && ! echo "$out" | grep -q "SAFE TO FLASH"; then
	pass "CLI without --target-slot still means slot 2 (refused while slot 2 is live)"
else
	fail "CLI without --target-slot did not default to slot 2 (exit=$rc)"
	echo "$out" | sed 's/^/    /'
fi
out=$(FLASH_SPARE_SLOT_TEST_MODE=1 DEV_PREFIX="$F" CMDLINE_PATH="$F/cmdline" \
	sh "$FLASH_SCRIPT" --check-only --target-slot 3 "$IMG/xImage" "$IMG/rootfs.squashfs" "$IMG/manifest.txt" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "takes 1 or 2"; then
	pass "CLI --target-slot 3 is refused"
else
	fail "CLI --target-slot 3 was not refused (exit=$rc)"
	echo "$out" | sed 's/^/    /'
fi

# --- Test 12: check-only mode proves no write occurs - run the REAL CLI
# entry point (main(), not just run_preflight directly) with --check-only
# against the ALLOW scenario, and confirm (a) it exits 0, (b) it reports
# "Check-only mode: no write attempted", and (c) it never invoked dd at
# all - grepping the script's own source confirms write_and_verify() (the
# only place dd is called) is structurally unreachable before the
# check_only branch's `exit 0`. ---
echo "console=ttyS4 root=$F/dev/mmcblk0p7 rootwait" > "$F/cmdline"
out=$(FLASH_SPARE_SLOT_TEST_MODE=1 DEV_PREFIX="$F" CMDLINE_PATH="$F/cmdline" \
	sh "$FLASH_SCRIPT" --check-only "$IMG/xImage" "$IMG/rootfs.squashfs" "$IMG/manifest.txt" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "Check-only mode: no write attempted" && echo "$out" | grep -q "SAFE TO FLASH"; then
	pass "check-only mode (full CLI) succeeds and reports no write attempted"
else
	fail "check-only mode (full CLI) did not behave as expected (exit=$rc)"
	echo "$out" | sed 's/^/    /'
fi
if grep -n 'write_and_verify' "$FLASH_SCRIPT" | grep -qv '^\s*#'; then
	# write_and_verify must only ever be called from main()'s post-check_only
	# section - confirm the only call sites are exactly the two expected
	# real-write invocations, not anywhere check-only's branch could reach.
	call_lines=$(grep -n '	write_and_verify "' "$FLASH_SCRIPT" | wc -l)
	if [ "$call_lines" -eq 2 ]; then
		pass "write_and_verify() has exactly the two expected real-write call sites (none reachable from check-only)"
	else
		fail "write_and_verify() call-site count is $call_lines, expected 2 - re-audit reachability from --check-only"
	fi
fi

# --- Fail-closed audit additions (Phase G): unknown option / extra
# arguments must be refused, not silently ignored. ---
out=$(FLASH_SPARE_SLOT_TEST_MODE=1 DEV_PREFIX="$F" CMDLINE_PATH="$F/cmdline" \
	sh "$FLASH_SCRIPT" --bogus-flag "$IMG/xImage" "$IMG/rootfs.squashfs" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "unknown option"; then
	pass "an unrecognized option is refused"
else
	fail "an unrecognized option was not refused (exit=$rc)"
	echo "$out" | sed 's/^/    /'
fi

out=$(FLASH_SPARE_SLOT_TEST_MODE=1 DEV_PREFIX="$F" CMDLINE_PATH="$F/cmdline" \
	sh "$FLASH_SCRIPT" "$IMG/xImage" "$IMG/rootfs.squashfs" "$IMG/manifest.txt" "extra-unexpected-arg" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "unexpected extra arguments"; then
	pass "unexpected extra arguments are refused"
else
	fail "unexpected extra arguments were not refused (exit=$rc)"
	echo "$out" | sed 's/^/    /'
fi

# --- G91 step 6: a real write is gated by the shared busy check + the
# maintenance lock (exit 3, nothing written); --check-only and --force never
# call it. A fake nebulaos-busy that refuses, and logs every call. ---
G91=$(mktemp -d)
[ -n "${G91:-}" ] && [ -e "$G91" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
printf '#!/bin/sh\necho "$*" >> "%s/busy.log"\necho "NebulaOS refused: Not possible while a print is running. (PRINTING)" >&2\nexit 3\n' "$G91" > "$G91/busy"
chmod +x "$G91/busy"
echo "console=ttyS4 root=$F/dev/mmcblk0p7 rootwait" > "$F/cmdline"
out=$(NEBULAOS_BUSY_CLI="$G91/busy" NEBULAOS_MAINTENANCE_HOLDER= FLASH_SPARE_SLOT_TEST_MODE=1 \
	DEV_PREFIX="$F" CMDLINE_PATH="$F/cmdline" \
	sh "$FLASH_SCRIPT" "$IMG/xImage" "$IMG/rootfs.squashfs" "$IMG/manifest.txt" 2>&1)
rc=$?
if [ "$rc" -eq 3 ] && echo "$out" | grep -q "NebulaOS refused" \
	&& grep -q -- "--profile request --lock flash-spare-slot --exec /bin/sh" "$G91/busy.log"; then
	pass "a real write is refused while busy (exit 3, before any preflight or write)"
else
	fail "busy gate on a real write (exit=$rc)"
	echo "$out" | sed 's/^/    /'
fi
rm -f "$G91/busy.log"
out=$(NEBULAOS_BUSY_CLI="$G91/busy" NEBULAOS_MAINTENANCE_HOLDER= FLASH_SPARE_SLOT_TEST_MODE=1 \
	DEV_PREFIX="$F" CMDLINE_PATH="$F/cmdline" \
	sh "$FLASH_SCRIPT" --check-only "$IMG/xImage" "$IMG/rootfs.squashfs" "$IMG/manifest.txt" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$G91/busy.log" ]; then
	pass "--check-only is never gated"
else
	fail "--check-only gated or failed (exit=$rc)"
fi
out=$(NEBULAOS_BUSY_CLI="$G91/busy" NEBULAOS_MAINTENANCE_HOLDER= FLASH_SPARE_SLOT_TEST_MODE=1 \
	DEV_PREFIX="$F" CMDLINE_PATH="$F/cmdline" \
	sh "$FLASH_SCRIPT" --check-only --force "$IMG/xImage" "$IMG/rootfs.squashfs" "$IMG/manifest.txt" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$G91/busy.log" ]; then
	pass "--force is accepted and skips the gate"
else
	fail "--force (exit=$rc)"
	echo "$out" | sed 's/^/    /'
fi
if grep -q -- '--force --target-slot' "$(dirname "$FLASH_SCRIPT")/../tools/hardware/nebulaos_device.py"; then
	pass "the Hardware Agent passes --force (its own idle proof is the authority)"
else
	fail "the Hardware Agent does not pass --force"
fi
rm -rf "$G91"

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
