#!/bin/sh
#
# G9 phase 1 (2026-10-07): tests for /usr/libexec/nebulaos-datafs.sh and its
# use in S01persistent-datastore.
#
#   - boot policy on DISPOSABLE ext4 images (no journal, like the KE's
#     /usr/data) made with the host's e2fsprogs: clean (no fsck), unclean
#     (check, rw), repairable (preen repairs, rw), unrepairable (preen refuses,
#     read-only, files still there), checker missing, checker timeout,
#     every e2fsck exit-code class
#   - shutdown against a fake /proc/mounts and fake fuser/umount/mount/kill:
#     leftover users stopped TERM -> wait -> KILL, eMMC swap off, nested and
#     bind mounts unmounted deepest first, clean unmount, read-only fallback,
#     busy, not mounted
#   - S01persistent-datastore wiring and the image build integration
# The real /usr/data is never touched; nothing here needs root or a loop mount.
# Usage: sh tests/datafs-policy-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
LIB="$ROOT/scripts/build/overlay/usr/libexec/nebulaos-datafs.sh"
S01="$ROOT/scripts/build/overlay/etc/init.d/S01persistent-datastore"
W=$(mktemp -d "${TMPDIR:-/tmp}/datafs-tests.XXXXXX")
[ -n "${W:-}" ] && [ -e "$W" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$LIB" ] || { echo "FATAL: $LIB missing"; exit 1; }

# --- wiring -------------------------------------------------------------------
grep -q 'ndf_precheck' "$S01" && grep -q 'ndf_mount' "$S01" && grep -q 'ndf_record' "$S01" && pass || fail "S01 start does not use the boot policy"
sed -n '/^case "\$1" in/,/^esac/p' "$S01" | grep -q 'ndf_shutdown' && pass || fail "S01 stop does not run the clean shutdown"
grep -q 'mount -t ext4 /dev/mmcblk0p10 /usr/data' "$S01" && pass || fail "S01 lost its library-less fallback mount"
grep -v '^[[:space:]]*#' "$LIB" | grep -qE 'mkfs|tune2fs|has_journal' && fail "policy uses mkfs/tune2fs/journal" || pass
[ "$(grep -v '^[[:space:]]*#' "$LIB" | grep -c -- 'E2FSCK" -fy')" -eq 1 ] && pass || fail "the full repair -fy must appear exactly once (ndf_run_check repair)"
grep -q '< /dev/null$' "$ROOT/scripts/build/overlay/etc/init.d/rcS" && grep -q '"\$i" start < /dev/null' "$ROOT/scripts/build/overlay/etc/init.d/rcS" && pass || fail "rcS does not give boot scripts stdin from /dev/null"
grep -qx 'BR2_PACKAGE_E2FSPROGS=y' "$ROOT/br2-external/configs/nebulaos_x2000_defconfig" && pass || fail "defconfig does not ship e2fsprogs"
grep -q 'G9: e2fsck' "$ROOT/scripts/build/06-verify.sh" && pass || fail "06-verify has no G9 check"

# --- fake tools ---------------------------------------------------------------
B="$W/bin"; mkdir -p "$B"
cat > "$B/fmount" <<'EOF'
#!/bin/sh
echo "mount $*" >> "$CALLS"
case "$*" in *remount,ro*) [ -n "${FAIL_REMOUNT:-}" ] && exit 1 ;; esac
exit 0
EOF
cat > "$B/fumount" <<'EOF'
#!/bin/sh
echo "umount $*" >> "$CALLS"
[ -n "${BUSY_MNT:-}" ] && [ "$1" = "$BUSY_MNT" ] && exit 1
exit 0
EOF
cat > "$B/ffuser" <<'EOF'
#!/bin/sh
# holders are listed in $HOLDERS_FILE until they are "killed"
cat "$HOLDERS_FILE" 2>/dev/null
EOF
cat > "$B/fkill" <<'EOF'
#!/bin/sh
echo "kill $*" >> "$CALLS"
sig=$1; shift
case "$sig" in
-TERM) [ -n "${TERM_IGNORED:-}" ] || : > "$HOLDERS_FILE" ;;
-KILL) [ -n "${KILL_IGNORED:-}" ] || : > "$HOLDERS_FILE" ;;
esac
exit 0
EOF
cat > "$B/fswapoff" <<'EOF'
#!/bin/sh
echo "swapoff $*" >> "$CALLS"
EOF
cat > "$B/slow-e2fsck" <<'EOF'
#!/bin/sh
echo "e2fsck $*" >> "$CALLS"
sleep 30
EOF
cat > "$B/rc-e2fsck" <<'EOF'
#!/bin/sh
echo "e2fsck $*" >> "$CALLS"
case "$1" in -fy) exit "${FAKE_RC_FULL:-$FAKE_RC}" ;; esac
exit "$FAKE_RC"
EOF
chmod +x "$B"/*

# run one policy decision in a subshell; prints "RESULT MOUNT RC"
policy() { # dev [env...]
	_dev=$1; shift
	(
		for _a in "$@"; do export "$_a"; done
		NDF_DEV=$_dev NDF_MNT="$W/mnt" NDF_STATE="$W/state" NDF_CHECK_OUT="$W/e2fsck.out" CALLS="$W/calls"
		NDF_MOUNT="$B/fmount"
		export NDF_DEV NDF_MNT NDF_STATE NDF_CHECK_OUT CALLS NDF_MOUNT
		. "$LIB"
		ndf_precheck > "$W/log" 2>&1
		echo "$NDF_RESULT $NDF_MOUNT_OPTS ${NDF_RC:-none}"
	)
}

# --- boot policy on real disposable images --------------------------------------
if command -v mkfs.ext4 >/dev/null && command -v debugfs >/dev/null && command -v e2fsck >/dev/null && command -v dumpe2fs >/dev/null; then
	E2=$(command -v e2fsck); D2=$(command -v dumpe2fs)
	img() { # name -> a 16 MiB no-journal ext4 with a few files
		_i="$W/$1.img"
		mkfs.ext4 -q -F -O ^has_journal -b 1024 "$_i" 16M > /dev/null 2>&1
		printf 'printer.cfg contents\n' > "$W/f1"; printf 'moonraker data\n' > "$W/f2"
		debugfs -w -R "mkdir nebulaos" "$_i" > /dev/null 2>&1
		debugfs -w -R "write $W/f1 nebulaos/printer.cfg" "$_i" > /dev/null 2>&1
		debugfs -w -R "write $W/f2 nebulaos/data.db" "$_i" > /dev/null 2>&1
		echo "$_i"
	}
	files_ok() { debugfs -R "cat nebulaos/printer.cfg" "$1" 2>/dev/null | grep -q 'printer.cfg contents'; }
	e2() { # NDF_E2FSCK wrapper that records calls
		printf '#!/bin/sh\necho "e2fsck $*" >> "%s/calls"\nexec %s "$@"\n' "$W" "$E2" > "$B/rec-e2fsck"; chmod +x "$B/rec-e2fsck"
	}
	e2

	# clean: no check at all
	I=$(img clean); : > "$W/calls"
	r=$(policy "$I" NDF_E2FSCK="$B/rec-e2fsck" NDF_DUMPE2FS="$D2")
	[ "$r" = "CLEAN rw none" ] && pass || fail "clean image: got '$r'"
	grep -q e2fsck "$W/calls" && fail "clean image was fsck'd" || pass
	grep -q '^DATAFS_RESULT=CLEAN$' "$W/state" && grep -q '^DATAFS_MOUNT=rw$' "$W/state" && pass || fail "state file for clean: $(cat "$W/state")"
	grep -q "mount -t ext4 -o rw $I" "$W/calls" 2>/dev/null || { : > "$W/calls"; (NDF_DEV=$I NDF_MNT="$W/mnt" NDF_MOUNT="$B/fmount" CALLS="$W/calls" NDF_MOUNT_OPTS=rw; export CALLS; . "$LIB"; ndf_mount); }
	grep -q "mount -t ext4 -o rw $I $W/mnt" "$W/calls" && pass || fail "ndf_mount does not mount rw"

	# unclean (state flag only): checked, rw
	I=$(img unclean); debugfs -w -R "ssv state 0" "$I" > /dev/null 2>&1; : > "$W/calls"
	r=$(policy "$I" NDF_E2FSCK="$B/rec-e2fsck" NDF_DUMPE2FS="$D2")
	case "$r" in "CHECKED_OK rw 0"|"REPAIRED rw 1") pass ;; *) fail "unclean image: got '$r'" ;; esac
	grep -q "e2fsck -p $I" "$W/calls" && pass || fail "unclean image not checked with -p"
	[ "$(dumpe2fs -h "$I" 2>/dev/null | sed -n 's/^Filesystem state:[[:space:]]*//p')" = clean ] && pass || fail "unclean image not clean after the check"
	files_ok "$I" && pass || fail "unclean image lost data"

	# repairable: wrong free counts + unclean -> preen repairs, rw
	I=$(img repairable); debugfs -w -R "ssv free_blocks_count 3" "$I" > /dev/null 2>&1; debugfs -w -R "ssv state 0" "$I" > /dev/null 2>&1
	r=$(policy "$I" NDF_E2FSCK="$B/rec-e2fsck" NDF_DUMPE2FS="$D2")
	case "$r" in "REPAIRED rw 1"|"CHECKED_OK rw 0") pass ;; *) fail "repairable image: got '$r'" ;; esac
	"$E2" -fn "$I" > /dev/null 2>&1 && pass || fail "repairable image still inconsistent after preen"
	files_ok "$I" && pass || fail "repairable image lost data"

	# unrepairable for preen: two files claiming the same block ("RUN fsck MANUALLY")
	I="$W/broken.img"
	mkfs.ext4 -q -F -O ^has_journal,^extent,^64bit -b 1024 "$I" 16M > /dev/null 2>&1
	printf 'printer.cfg contents\n' > "$W/f1"; printf 'moonraker data\n' > "$W/f2"
	debugfs -w -R "mkdir nebulaos" "$I" > /dev/null 2>&1
	debugfs -w -R "write $W/f1 nebulaos/printer.cfg" "$I" > /dev/null 2>&1
	debugfs -w -R "write $W/f2 nebulaos/data.db" "$I" > /dev/null 2>&1
	blk=$(debugfs -R "blocks nebulaos/printer.cfg" "$I" 2>/dev/null | tr -d ' \n')
	debugfs -w -R "sif nebulaos/data.db block[0] $blk" "$I" > /dev/null 2>&1; debugfs -w -R "ssv state 0" "$I" > /dev/null 2>&1
	cp "$I" "$W/broken.before"
	: > "$W/calls"
	r=$(policy "$I" NDF_E2FSCK="$B/rec-e2fsck" NDF_DUMPE2FS="$D2")
	case "$r" in "AUTO_REPAIRED rw "*) pass ;; *) fail "preen-unrepairable image: got '$r' ($(tail -2 "$W/e2fsck.out.repair" 2>/dev/null))" ;; esac
	grep -q "e2fsck -p $I" "$W/calls" && grep -q "e2fsck -fy $I" "$W/calls" && pass || fail "full repair not run after the preen pass"
	grep -q '^DATAFS_MOUNT=rw$' "$W/state" && grep -q '^DATAFS_PREEN_RC=4$' "$W/state" && pass || fail "auto-repair state: $(cat "$W/state")"
	"$E2" -fn "$I" > /dev/null 2>&1 && pass || fail "image still inconsistent after the full repair"
	files_ok "$I" && pass || fail "full repair lost the surviving file"
else
	echo "NOTE: host e2fsprogs missing - disposable image tests skipped"
fi

# --- exit-code classes, missing tool, timeout -----------------------------------
DUMP_NC="$W/dump-nc"; printf '#!/bin/sh\necho "Filesystem state:         not clean"\n' > "$DUMP_NC"; chmod +x "$DUMP_NC"
for c in "0 CHECKED_OK rw" "1 REPAIRED rw" "2 REPAIRED rw" "3 REPAIRED rw" "4 UNREPAIRED ro" "5 UNREPAIRED ro" "6 UNREPAIRED ro" \
	"8 CHECK_FAILED ro" "12 UNREPAIRED ro" "16 CHECK_FAILED ro" "32 CHECK_FAILED ro" "128 CHECK_FAILED ro"; do
	set -- $c
	r=$(policy /dev/fake NDF_E2FSCK="$B/rc-e2fsck" NDF_DUMPE2FS="$DUMP_NC" FAKE_RC="$1")
	[ "$r" = "$2 $3 $1" ] && pass || fail "e2fsck rc=$1: got '$r', expected '$2 $3 $1'"
done
# preen fails, the full repair fixes it -> rw; the full repair fails too -> ro
for c in "4 1 AUTO_REPAIRED rw" "4 0 AUTO_REPAIRED rw" "8 1 AUTO_REPAIRED rw" "4 4 UNREPAIRED ro" "4 8 CHECK_FAILED ro" "12 12 UNREPAIRED ro"; do
	set -- $c
	r=$(policy /dev/fake NDF_E2FSCK="$B/rc-e2fsck" NDF_DUMPE2FS="$DUMP_NC" FAKE_RC="$1" FAKE_RC_FULL="$2")
	[ "$r" = "$3 $4 $2" ] && pass || fail "preen rc=$1, full rc=$2: got '$r', expected '$3 $4 $2'"
done
r=$(policy /dev/fake NDF_E2FSCK="$W/no-such-e2fsck" NDF_DUMPE2FS="$DUMP_NC")
[ "$r" = "TOOL_MISSING rw none" ] && pass || fail "missing e2fsck: got '$r'"
r=$(policy /dev/fake NDF_E2FSCK="$B/rc-e2fsck" NDF_DUMPE2FS="$W/no-such-dumpe2fs" FAKE_RC=0)
[ "$r" = "TOOL_MISSING rw none" ] && pass || fail "missing dumpe2fs: got '$r'"
DUMP_CE="$W/dump-ce"; printf '#!/bin/sh\necho "Filesystem state:         clean with errors"\n' > "$DUMP_CE"; chmod +x "$DUMP_CE"
r=$(policy /dev/fake NDF_E2FSCK="$B/rc-e2fsck" NDF_DUMPE2FS="$DUMP_CE" FAKE_RC=1)
[ "$r" = "REPAIRED rw 1" ] && pass || fail "'clean with errors' must be checked: got '$r'"
DUMP_NONE="$W/dump-none"; printf '#!/bin/sh\nexit 1\n' > "$DUMP_NONE"; chmod +x "$DUMP_NONE"
r=$(policy /dev/fake NDF_E2FSCK="$B/rc-e2fsck" NDF_DUMPE2FS="$DUMP_NONE" FAKE_RC=8)
[ "$r" = "CHECK_FAILED ro 8" ] && pass || fail "unreadable superblock: got '$r'"
t0=$(date +%s)
r=$(policy /dev/fake NDF_E2FSCK="$B/slow-e2fsck" NDF_DUMPE2FS="$DUMP_NC" NDF_CHECK_TIMEOUT=2)
t1=$(date +%s)
[ "$r" = "TIMEOUT ro 124" ] && pass || fail "timeout: got '$r'"
[ $((t1 - t0)) -le 8 ] && pass || fail "timeout not bounded ($((t1 - t0))s)"
sleep 1; pgrep -f "$B/slow-e2fsck" > /dev/null && fail "timed-out checker left running" || pass

# --- shutdown -------------------------------------------------------------------
M="$W/m"
mk_mounts() {
	cat > "$W/mounts" <<EOF
/dev/root / squashfs ro 0 0
/dev/mmcblk0p10 /usr/data ext4 rw,relatime 0 0
/dev/mmcblk0p10 /opt/printer_data ext4 rw,relatime 0 0
/dev/mmcblk0p10 /opt/guppyscreen/guppyconfig.json ext4 rw,relatime 0 0
/dev/mmcblk0p10 /opt/klipper ext4 rw,relatime 0 0
/dev/mmcblk0p10 /opt/printer_data/gcodes ext4 rw,relatime 0 0
/dev/sda1 /opt/printer_data/gcodes/USB/sda vfat rw 0 0
tmpfs /run tmpfs rw 0 0
/dev/sdb1 /usr/data/stick vfat rw 0 0
EOF
}
shut() { # [env...] -> prints NDF_SHUTDOWN_RESULT
	(
		for _a in "$@"; do export "$_a"; done
		NDF_DEV=/dev/mmcblk0p10 NDF_MNT=/usr/data NDF_PROC_MOUNTS="$W/mounts" NDF_PROC_SWAPS="$W/swaps"
		NDF_FUSER="$B/ffuser" NDF_UMOUNT="$B/fumount" NDF_MOUNT="$B/fmount" NDF_KILL="$B/fkill" NDF_SWAPOFF="$B/fswapoff"
		NDF_DIAG_LOG_REL=../../nonexistent-dir/x CALLS="$W/calls" HOLDERS_FILE="$W/holders" NDF_STOP_WAIT=2
		export NDF_DEV NDF_MNT NDF_PROC_MOUNTS NDF_PROC_SWAPS NDF_FUSER NDF_UMOUNT NDF_MOUNT NDF_KILL NDF_SWAPOFF CALLS HOLDERS_FILE NDF_STOP_WAIT
		. "$LIB"
		ndf_shutdown > "$W/slog" 2>&1
		echo "$NDF_SHUTDOWN_RESULT"
	)
}
# clean: holders stop on TERM, swap on -> off, mounts deepest first, /usr/data unmounted
mk_mounts; printf 'Filename Type\n/usr/data/nebulaos/system/swapfile file 1 0 10\n' > "$W/swaps"
echo "1234 5678" > "$W/holders"; : > "$W/calls"
r=$(shut)
[ "$r" = CLEAN ] && pass || fail "shutdown clean path: $r ($(cat "$W/slog"))"
grep -q '^kill -TERM 1234 5678' "$W/calls" && pass || fail "holders not TERMed: $(cat "$W/calls")"
grep -q '^kill -KILL' "$W/calls" && fail "holders KILLed although they stopped on TERM" || pass
grep -q '^swapoff /usr/data/nebulaos/system/swapfile' "$W/calls" && pass || fail "eMMC swap not turned off"
order=$(grep '^umount' "$W/calls" | cut -d' ' -f2 | tr '\n' ' ')
pos() { echo "$order" | tr ' ' '\n' | grep -nx "$1" | cut -d: -f1; }
[ "$(pos /opt/printer_data/gcodes/USB/sda)" -lt "$(pos /opt/printer_data/gcodes)" ] && [ "$(pos /opt/printer_data/gcodes)" -lt "$(pos /opt/printer_data)" ] \
	&& [ "$(pos /usr/data/stick)" -lt "$(pos /usr/data)" ] && pass || fail "a mount was unmounted before one nested inside it: $order"
echo "$order" | grep -q '/opt/klipper' && echo "$order" | grep -q '/usr/data/stick' && pass || fail "a dependent mount was missed: $order"
last=$(echo "$order" | awk '{print $NF}')
[ "$last" = /usr/data ] && pass || fail "/usr/data not unmounted last: $order"
echo "$order" | grep -q ' / \|^/ ' && fail "root filesystem unmounted" || pass
echo "$order" | grep -q '/run' && fail "unrelated tmpfs unmounted" || pass
# a holder that ignores TERM is killed after the bound
mk_mounts; : > "$W/swaps"; echo 4321 > "$W/holders"; : > "$W/calls"
t0=$(date +%s); r=$(shut TERM_IGNORED=1); t1=$(date +%s)
[ "$r" = CLEAN ] && grep -q '^kill -KILL 4321' "$W/calls" && pass || fail "stubborn holder not killed: $r $(cat "$W/calls")"
[ $((t1 - t0)) -le 6 ] && pass || fail "holder wait not bounded ($((t1 - t0))s)"
grep -q swapoff "$W/calls" && fail "swapoff called with no swap active" || pass
# busy unmount -> read-only remount
mk_mounts; : > "$W/holders"; : > "$W/calls"
r=$(shut BUSY_MNT=/usr/data)
[ "$r" = CLEAN_RO ] && grep -q 'mount -o remount,ro /usr/data' "$W/calls" && pass || fail "busy unmount did not fall back to ro: $r"
# busy and remount fails, holders remain -> BUSY; no holders -> FAILED
mk_mounts; echo 999 > "$W/holders"; : > "$W/calls"
r=$(shut BUSY_MNT=/usr/data FAIL_REMOUNT=1 TERM_IGNORED=1 KILL_IGNORED=1)
[ "$r" = BUSY ] && grep -q 'BUSY' "$W/slog" && pass || fail "busy case: $r"
mk_mounts; : > "$W/holders"; : > "$W/calls"
r=$(shut BUSY_MNT=/usr/data FAIL_REMOUNT=1)
[ "$r" = FAILED ] && pass || fail "failed case: $r"
# not mounted
grep -v ' /usr/data ext4' "$W/mounts" > "$W/m2"; mv "$W/m2" "$W/mounts"; : > "$W/calls"
r=$(shut)
[ "$r" = NOT_MOUNTED ] && [ ! -s "$W/calls" ] && pass || fail "not-mounted case: $r $(cat "$W/calls")"

# --- 2026-10-15: a failed mount is retried once and reported ------------------
cat > "$B/flaky-mount" <<'EOF'
#!/bin/sh
echo "mount $*" >> "$CALLS"
n=$(cat "$COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$COUNT"
[ "$n" -le "${FAILS:-0}" ] && { echo "mount: Device or resource busy" >&2; exit 1; }
exit 0
EOF
chmod +x "$B/flaky-mount"
mount_try() { # FAILS -> prints rc, mount calls, kmsg lines
	: > "$W/calls"; : > "$W/kmsg"; rm -f "$W/count"
	(FAILS=$1 COUNT="$W/count" CALLS="$W/calls" NDF_DEV=/dev/x NDF_MNT="$W/mnt" NDF_MOUNT="$B/flaky-mount" \
	 NDF_MOUNT_OPTS=rw NDF_MOUNT_RETRY_DELAY=0 NDF_KMSG="$W/kmsg" NDF_STATE="$W/state"; \
	 export FAILS COUNT CALLS; . "$LIB"; ndf_mount >/dev/null; echo "rc=$?")
}
r=$(mount_try 0)
[ "$r" = rc=0 ] && [ "$(grep -c '^mount' "$W/calls")" = 1 ] && grep -q 'mounted /dev/x' "$W/kmsg" && pass || fail "first-time mount: $r"
r=$(mount_try 1)
[ "$r" = rc=0 ] && [ "$(grep -c '^mount' "$W/calls")" = 2 ] && grep -q 'second attempt' "$W/kmsg" && grep -q 'Device or resource busy' "$W/kmsg" && pass || fail "retried mount: $r"
: > "$W/state"
r=$(mount_try 2)
[ "$r" = rc=1 ] && [ "$(grep -c '^mount' "$W/calls")" = 2 ] && grep -q 'MOUNT FAILED' "$W/kmsg" && grep -q DATAFS_MOUNT_FAILED=1 "$W/state" && pass || fail "failed mount not reported: $r"
# G67: routine kmsg lines are info (<6>), failures stay warnings (<4>)
grep -q '^<4>nebulaos-datafs: MOUNT FAILED' "$W/kmsg" && grep -q '^<4>nebulaos-datafs: mount of /dev/x.*failed' "$W/kmsg" && pass || fail "failure kmsg lines not at warning priority"
r=$(mount_try 0)
grep -q '^<6>nebulaos-datafs: mounted /dev/x' "$W/kmsg" && pass || fail "routine kmsg line not at info priority"

echo "datafs-policy-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
