#!/bin/sh
# Live gap verification G9 (2026-10-05): /usr/data (ext4) mounted "unchecked"
# on every boot. Read-only: the mount and its kernel messages, the ext4
# superblock fields (read from the block device, nothing written), the ext4
# error counters, the shutdown path (inittab, rcK) and which processes hold
# files on /usr/data open - what a clean unmount at shutdown would have to stop.
DEV=$(awk '$2=="/usr/data"{print $1}' /proc/mounts); B=${DEV#/dev/}
echo "== mount"; grep " /usr/data " /proc/mounts; cat /proc/fs/ext4/$B/options 2>/dev/null | tr '\n' ' '; echo
echo "== kernel"; dmesg | grep -E "EXT4-fs \($B\)" | head -5
echo "== sysfs"; for f in errors_count first_error_time last_error_time lifetime_write_kbytes; do echo "$f=$(cat /sys/fs/ext4/$B/$f 2>/dev/null)"; done
echo "== superblock"
python3 - $DEV <<'G9_PY'
import struct, sys, time
with open(sys.argv[1], "rb") as fh:
    fh.seek(1024)
    sb = fh.read(1024)
u16 = lambda o: struct.unpack_from("<H", sb, o)[0]
u32 = lambda o: struct.unpack_from("<I", sb, o)[0]
ts = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t)) if t else "never"
st = u16(0x3A)
print("magic=%#x state=%#x valid_fs=%d error_fs=%d errors_behavior=%d" % (u16(0x38), st, st & 1, (st >> 1) & 1, u16(0x3C)))
print("mnt_count=%d max_mnt_count=%d lastcheck=%s checkinterval=%d mtime=%s wtime=%s"
      % (u16(0x34), struct.unpack_from("<h", sb, 0x36)[0], ts(u32(0x40)), u32(0x44), ts(u32(0x2C)), ts(u32(0x30))))
fc, fi, fr = u32(0x5C), u32(0x60), u32(0x64)
print("has_journal=%d feature_compat=%#x incompat=%#x ro_compat=%#x metadata_csum=%d"
      % (fc & 4 and 1, fc, fi, fr, (fr >> 10) & 1))
print("error_count=%d first_error_time=%s last_error_time=%s" % (u32(0x194), ts(u32(0x198)), ts(u32(0x1CC))))
G9_PY
echo "== tools"; for t in fsck e2fsck fsck.ext4 tune2fs dumpe2fs; do echo "$t=$(command -v $t || echo absent)"; done
busybox --list 2>/dev/null | grep -iE '^(fsck|e2fsck|tune2fs|fsck\..*)$' | tr '\n' ' '; echo
echo "== shutdown path"; grep -v '^#' /etc/inittab | grep -E 'shutdown|ctrlaltdel|restart'; ls -l /etc/init.d/rcK 2>&1
grep -vE '^\s*#|^\s*$' /etc/init.d/rcK 2>/dev/null | head -20
grep -l 'stop)' /etc/init.d/S01persistent-datastore >/dev/null 2>&1 && echo "S01persistent-datastore: has stop" || echo "S01persistent-datastore: no stop handler"
echo "== processes with files open on /usr/data or its bind mounts"
for p in /proc/[0-9]*; do
	n=$(ls -l $p/fd 2>/dev/null | grep -cE '/usr/data|/opt/printer_data|/opt/klipper|/opt/moonraker|klippy-env|guppyconfig')
	[ "$n" -gt 0 ] && echo "$(cat $p/comm 2>/dev/null) pid=${p#/proc/} fds=$n"
done | sort | head -30
