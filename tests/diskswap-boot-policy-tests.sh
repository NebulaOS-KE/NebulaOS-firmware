#!/bin/sh
#
# BOOT-08 (2026-10-05): offline tests for S03nebulaos-diskswap's
# maintenance-only eMMC swap tier. Runs the real script against a sandbox
# namespace with fake /proc/swaps, /proc/mounts and fake swapon/swapoff/
# mkswap, so nothing touches real swap.
#
# Usage: sh tests/diskswap-boot-policy-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OVERLAY="$SCRIPT_DIR/../scripts/build/overlay"
S03="$OVERLAY/etc/init.d/S03nebulaos-diskswap"
S00="$OVERLAY/etc/init.d/S00zram-swap"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/diskswap-boot-policy-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$S03" ] || { echo "FATAL: $S03 not found"; exit 1; }

# fake swap tools: record calls, maintain the fake /proc/swaps
mkdir -p "$WORK/bin"
cat > "$WORK/bin/fswapon" <<'EOF'
#!/bin/sh
f=; for a; do f=$a; done
echo "swapon $*" >> "$CALLS"
[ -n "${FAIL_SWAPON:-}" ] && exit 1
printf '%s file 1024 0 10\n' "$f" >> "$PROC_SWAPS"
EOF
cat > "$WORK/bin/fswapoff" <<'EOF'
#!/bin/sh
echo "swapoff $*" >> "$CALLS"
[ -n "${FAIL_SWAPOFF:-}" ] && exit 1
grep -v "^$1 " "$PROC_SWAPS" > "$PROC_SWAPS.tmp"; mv "$PROC_SWAPS.tmp" "$PROC_SWAPS"
EOF
cat > "$WORK/bin/fmkswap" <<'EOF'
#!/bin/sh
echo "mkswap $*" >> "$CALLS"
EOF
chmod +x "$WORK/bin/"*

OWNER="$(id -u):$(id -g)"

# new_case NAME -> fresh fully-seeded normal-boot namespace
new_case() {
	C="$WORK/$1"; mkdir -p "$C/data" "$C/seeds"
	NB="$C/data/nebulaos"
	mkdir -p "$NB/system" "$NB/maintenance"
	for a in klipper nebulaos-klipper-extensions moonraker; do mkdir -p "$NB/apps/$a/.git"; done
	mkdir -p "$NB/apps/mainsail"; : > "$NB/apps/mainsail/index.html"
	for e in klipper moonraker; do mkdir -p "$NB/envs/$e/bin"; printf '#!/bin/sh\n' > "$NB/envs/$e/bin/python3"; chmod +x "$NB/envs/$e/bin/python3"; done
	echo '{ "migration_version": "gen-A" }' > "$C/seeds/seed-manifest.json"
	echo '{ "migration_version": "gen-A" }' > "$NB/system/app-generation.json"
	echo "/dev/mmcblk0p10 $C/data ext4 rw 0 0" > "$C/mounts"
	printf 'Filename Type Size Used Priority\n/dev/zram0 partition 131068 0 100\n' > "$C/swaps"
	: > "$C/calls"
}

run() { # args...
	env NEBULAOS_ROOT="$NB" DATA_MOUNT="$C/data" SEEDS="$C/seeds" PROC_SWAPS="$C/swaps" PROC_MOUNTS="$C/mounts" \
		SWAP_SIZE_BYTES=1048576 SWAP_OWNER="$OWNER" SWAPON="$WORK/bin/fswapon" SWAPOFF="$WORK/bin/fswapoff" \
		MKSWAP="$WORK/bin/fmkswap" CALLS="$C/calls" \
		sh "$S03" "$@" > "$C/out" 2>&1
}
active() { grep -q "^$NB/system/swapfile " "$C/swaps"; }
calls() { grep -c "^$1 " "$C/calls"; }

# 1. normal boot: file prepared, not activated, zram untouched
new_case normal; run start; rc=$?
[ $rc -eq 0 ] && pass || fail "normal boot rc=$rc"
active && fail "normal boot activated the eMMC swapfile" || pass
[ "$(calls swapon)" = 0 ] && pass || fail "normal boot called swapon"
[ -f "$NB/system/swapfile" ] && [ "$(wc -c < "$NB/system/swapfile")" = 1048576 ] && pass || fail "normal boot did not prepare the swapfile"
grep -q '^/dev/zram0 ' "$C/swaps" && pass || fail "zram entry disappeared"
grep -q 'left OFF' "$C/out" && pass || fail "normal boot did not log the zram-only decision ($(cat "$C/out"))"

# 2. second normal boot with a valid existing file: no recreate, still off
run start
[ "$(calls mkswap)" = 1 ] && pass || fail "valid swapfile was recreated on the second boot"
active && fail "second normal boot activated swap" || pass

# 3. maintenance boots: each reason enables the tier
for why in app env gen nogen request; do
	new_case "maint-$why"
	case "$why" in
		app) rm -rf "$NB/apps/moonraker/.git" ;;
		env) rm -f "$NB/envs/klipper/bin/python3" ;;
		gen) echo '{ "migration_version": "gen-B" }' > "$C/seeds/seed-manifest.json" ;;
		nogen) rm -f "$NB/system/app-generation.json" ;;
		request) : > "$NB/maintenance/diskswap-next-boot" ;;
	esac
	run start; rc=$?
	[ $rc -eq 0 ] && active && pass || fail "maintenance boot ($why) did not enable the tier ($(cat "$C/out"))"
	grep -q 'maintenance boot:' "$C/out" && pass || fail "maintenance boot ($why) not logged"
done
# one-shot request is consumed before use; the next boot is normal again
[ -e "$NB/maintenance/diskswap-next-boot" ] && fail "one-shot request was not consumed" || pass
CALLS="$C/calls" PROC_SWAPS="$C/swaps" "$WORK/bin/fswapoff" "$NB/system/swapfile"
run start
active && fail "boot after a consumed request enabled swap again" || pass

# 4. a failing swapon never fails the boot, and a request is still consumed
new_case swapon-fails; : > "$NB/maintenance/diskswap-next-boot"
env FAIL_SWAPON=1 NEBULAOS_ROOT="$NB" DATA_MOUNT="$C/data" SEEDS="$C/seeds" PROC_SWAPS="$C/swaps" PROC_MOUNTS="$C/mounts" \
	SWAP_SIZE_BYTES=1048576 SWAP_OWNER="$OWNER" SWAPON="$WORK/bin/fswapon" SWAPOFF="$WORK/bin/fswapoff" \
	MKSWAP="$WORK/bin/fmkswap" CALLS="$C/calls" sh "$S03" start > "$C/out" 2>&1; rc=$?
[ $rc -eq 0 ] && pass || fail "swapon failure failed the boot (rc=$rc)"
[ -e "$NB/maintenance/diskswap-next-boot" ] && fail "request survived a failed attempt (sticky)" || pass

# 5. explicit enable/disable, idempotent
new_case explicit
run enable; [ $? -eq 0 ] && active && pass || fail "enable did not activate"
run enable; [ "$(calls swapon)" = 1 ] && pass || fail "second enable called swapon again"
run status; grep -qx active "$C/out" && pass || fail "status did not report active"
run disable; [ $? -eq 0 ] && ! active && pass || fail "disable did not deactivate"
run disable; [ $? -eq 0 ] && [ "$(calls swapoff)" = 1 ] && pass || fail "second disable was not a no-op"
run status; grep -qx inactive "$C/out" && pass || fail "status did not report inactive"
# disable failure (pages do not fit back) is reported, swap left active
run enable
env FAIL_SWAPOFF=1 NEBULAOS_ROOT="$NB" PROC_SWAPS="$C/swaps" SWAPOFF="$WORK/bin/fswapoff" CALLS="$C/calls" sh "$S03" disable > "$C/out" 2>&1
[ $? -ne 0 ] && active && pass || fail "a failing swapoff was not reported"

# 6. normal boot with the tier already active (e.g. a hot restart) leaves it to memguard
new_case already; run enable; run start
grep -q "leaving it to memguard" "$C/out" && active && pass || fail "already-active case not handled ($(cat "$C/out"))"

# 7. missing / invalid / non-regular swapfile
new_case invalid; head -c 4096 /dev/zero > "$NB/system/swapfile"; chmod 600 "$NB/system/swapfile"
run start
[ "$(wc -c < "$NB/system/swapfile")" = 1048576 ] && grep -q 'failed validation' "$C/out" && pass || fail "invalid swapfile not recreated"
new_case wrongperm; run start; chmod 644 "$NB/system/swapfile"; : > "$C/calls"; run start
[ "$(calls mkswap)" = 1 ] && pass || fail "world-readable swapfile was trusted"
new_case notfile; mkdir -p "$NB/system/swapfile"; : > "$NB/maintenance/diskswap-next-boot"; run start; rc=$?
[ $rc -eq 0 ] && ! active && [ -d "$NB/system/swapfile" ] && pass || fail "non-regular swapfile path was touched or activated"

# 8. /usr/data not mounted: nothing created, nothing activated
new_case unmounted; : > "$C/mounts"; : > "$NB/maintenance/diskswap-next-boot"; run start; rc=$?
[ $rc -eq 0 ] && ! active && [ ! -e "$NB/system/swapfile" ] && pass || fail "unmounted data partition not handled"

# 9. zram policy itself is untouched (qualified: lz4, 128 MiB, 20 % limit)
grep -q 'lz4' "$S00" && pass || fail "S00zram-swap no longer selects lz4"
grep -qE '128' "$S00" && pass || fail "S00zram-swap no longer sizes 128 MiB"
grep -qE '20' "$S00" && pass || fail "S00zram-swap no longer sets the 20 % limit"

# 10. memguard keeps its defensive maintenance policy
MG="$OVERLAY/usr/libexec/nebulaos-memguard"
grep -q 'MG_DISKSWAP_POLICY="${MG_DISKSWAP_POLICY:-maintenance}"' "$MG" && pass || fail "memguard default diskswap policy changed"
grep -q 'mg_diskswap_reconcile' "$MG" && pass || fail "memguard reconcile removed"

echo "diskswap-boot-policy-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
