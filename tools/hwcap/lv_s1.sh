#!/bin/sh
# Live fix verification S1 (2026-10-05): S03nebulaos-diskswap sizes the
# swapfile from metadata (ls -ln) instead of reading it (wc -c). The image's
# BusyBox has no `stat -c` (first run: empty size, see the report). Runs the image's
# S03 and a patched copy in /run/nebulaos-live-verify side by side:
#   - sandbox: every validation edge case in a fake root under $T with fake
#     swapon/swapoff/mkswap; both copies must reach the same outcome
#   - real file: cold-cache `start` timing and data-partition reads, the
#     normal-boot result (swapfile left OFF), explicit enable/disable
# Nothing in the image is modified; the real swapfile is only validated.
O=/etc/init.d/S03nebulaos-diskswap
L=/run/nebulaos-live-verify; P=$L/S03-patched
mkdir -p $L
sed 's/actual_size=$(wc -c < "$SWAPFILE" 2>\/dev\/null)/actual_size=$(ls -ln "$SWAPFILE" 2>\/dev\/null | awk '"'"'{print $5}'"'"')/' $O > $P
chmod 755 $P
echo "patch: ls_lines=$(grep -c 'actual_size=$(ls -ln "$SWAPFILE"' $P) wc_lines_left=$(grep -c 'wc -c' $P) stat_applet=$(stat -c %s /proc/version >/dev/null 2>&1 && echo yes || echo no)"
diff $O $P | grep '^[<>]'

ms() { awk '{printf "%d", $1 * 1000}' /proc/uptime; }

# --- sandbox ---------------------------------------------------------------
S=$T/sb; mkdir -p $S/data/nebulaos/system $S/bin
printf 'Filesystem Type Size Used Priority\n' > $S/swaps
printf '/dev/x %s/data ext4 rw 0 0\n' $S > $S/mounts
for t in swapon swapoff mkswap; do printf '#!/bin/sh\necho "%s $*" >> %s/calls\n' $t $S > $S/bin/$t; chmod 755 $S/bin/$t; done
F=$S/data/nebulaos/system/swapfile
sbx() { # copy case
	rm -f $S/calls
	o=$(NEBULAOS_ROOT=$S/data/nebulaos DATA_MOUNT=$S/data PROC_SWAPS=$S/swaps PROC_MOUNTS=$S/mounts \
	SWAP_SIZE_BYTES=1048576 SWAPON=$S/bin/swapon SWAPOFF=$S/bin/swapoff MKSWAP=$S/bin/mkswap sh $1 enable 2>&1); r=$?
	printf '%s' "$o" | sed "s#$S#SB#g; s/^S03nebulaos-diskswap: //" | tr '\n' '|' > $S/log
	echo "rc=$r calls=$(sed "s#$S#SB#g" $S/calls 2>/dev/null | tr '\n' ',') result=$(ls -lnd $F 2>/dev/null | awk '{print $1,$3":"$4,$5}')"
}
setup() {
	rm -rf $F
	case $1 in
	absent) ;;
	valid) head -c 1048576 /dev/zero > $F; chmod 600 $F ;;
	short) head -c 524288 /dev/zero > $F; chmod 600 $F ;;
	long) head -c 2097152 /dev/zero > $F; chmod 600 $F ;;
	empty) : > $F; chmod 600 $F ;;
	perms) head -c 1048576 /dev/zero > $F; chmod 644 $F ;;
	owner) head -c 1048576 /dev/zero > $F; chmod 600 $F; chown 1:1 $F ;;
	sparse) rm -f $F; head -c 1 /dev/zero > $F; truncate -s 1048576 $F 2>/dev/null; chmod 600 $F ;;
	dir) mkdir $F ;;
	symlink) head -c 1048576 /dev/zero > $S/real; chmod 600 $S/real; ln -s $S/real $F ;;
	esac
}
same=0; diff_n=0
for c in absent valid short long empty perms owner sparse dir symlink; do
	setup $c; a=$(sbx $O); la=$(cat $S/log); setup $c; b=$(sbx $P); lb=$(cat $S/log)
	if [ "$a" = "$b" ]; then same=$((same + 1)); echo "SBX $c SAME_OUTCOME $b"
	else diff_n=$((diff_n + 1)); echo "SBX $c DIFFERENT_OUTCOME image: $a patched: $b"; fi
	echo "  log patched: $lb"; [ "$la" = "$lb" ] || echo "  log image:   $la"
	rm -rf $F $S/real
done
echo "SANDBOX_CASES same=$same different=$diff_n"
# the valid case must not rewrite the file (no "creating", mtime kept)
setup valid; m0=$(ls -l --full-time $F | awk '{print $6, $7}'); sleep 1; sbx $P > /dev/null
echo "valid_kept: creating_lines=$(grep -c creating $S/log) mtime_changed=$([ "$(ls -l --full-time $F | awk '{print $6, $7}')" = "$m0" ] && echo no || echo yes)"
rm -rf $S

# --- real file ---------------------------------------------------------------
# Only when every sandbox case matched: a wrong size check would delete the file.
if [ "$diff_n" != 0 ]; then echo "REAL_PHASE_SKIPPED (sandbox mismatch)"; else
SW0=/usr/data/nebulaos/system/swapfile
if [ ! -f $SW0 ]; then echo "swapfile absent - restoring it with the image's own S03 (start: create once, left OFF)"; $O start; fi
DEV=$(awk '$2=="/usr/data"{print $1}' /proc/mounts); DEV=${DEV#/dev/}
SW=/usr/data/nebulaos/system/swapfile
echo "data_dev=$DEV swapfile=$(ls -ln $SW | awk '{print $1, $3":"$4, $5}') swaps_before=$(grep -c swapfile /proc/swaps)"
rd() { awk -v d=$DEV '$3==d{print $6}' /proc/diskstats; }
for i in 1 2 3; do
	for v in image patched; do
		f=$O; [ $v = patched ] && f=$P
		sync; echo 3 > /proc/sys/vm/drop_caches; r0=$(rd); t0=$(ms)
		out=$($f start 2>&1 | tr '\n' '|'); t1=$(ms); r1=$(rd)
		echo "REAL $v run=$i ms=$((t1 - t0)) data_sectors_read=$((r1 - r0)) out=$out"
	done
done
echo "after_start: swapfile_in_swaps=$(grep -c swapfile /proc/swaps) (0 = left OFF, as a normal boot must)"
echo "warm: image_wc_ms=$(t0=$(ms); wc -c < $SW > /dev/null; echo $(( $(ms) - t0 ))) patched_stat_ms=$(t0=$(ms); stat -c %s $SW > /dev/null; echo $(( $(ms) - t0 )))"
echo "== explicit enable/disable with the patched copy"
$P enable; echo "enable_rc=$? status=$($P status)"; grep swapfile /proc/swaps
$P disable; echo "disable_rc=$?"; $P disable; echo "disable_again_rc=$? status=$($P status)"
grep -c swapfile /proc/swaps | sed 's/^/swapfile_in_swaps_end=/'
fi
