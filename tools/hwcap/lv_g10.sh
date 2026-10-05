#!/bin/sh
# Live gap verification G10 (2026-10-05): S03 `enable` outside maintenance is
# reverted by memguard. Live: enable with the real S03, time memguard's
# defensive swapoff. Policy: the image's memguard functions sourced through
# their test seam (NEBULAOS_MEMGUARD_NO_AUTORUN=1) against a lock directory,
# fake /proc/swaps and fake swapon/swapoff in tmpfs - the maintenance-lock path
# is exercised without creating any lock in /usr/data/nebulaos/updates/locks.
L=/run/nebulaos-live-verify; mkdir -p $L
SW=/usr/data/nebulaos/system/swapfile
echo "real: locks=[$(ls -A /usr/data/nebulaos/updates/locks 2>/dev/null | tr '\n' ' ')] maintenance_marker=$(ls /run/nebulaos/maintenance-active 2>/dev/null || echo absent) swapfile_active=$(grep -c "^$SW " /proc/swaps)"
echo "== live: enable outside maintenance"
/etc/init.d/S03nebulaos-diskswap enable; t0=$(cut -d. -f1 /proc/uptime)
i=0; while grep -q "^$SW " /proc/swaps && [ $i -lt 60 ]; do sleep 1; i=$((i + 1)); done
echo "memguard_reverted_after_s=$i still_active=$(grep -c "^$SW " /proc/swaps)"; tail -n 3 /usr/data/nebulaos/logs/memguard.log
echo "== policy table (image memguard functions, sandboxed)"
S=$T/g10; mkdir -p $S/locks $S/proc $S/run $S/bin
: > $S/swapfile
for t in swapon swapoff; do printf '#!/bin/sh\necho "%s $*" >> %s/calls\n' $t $S > $S/bin/$t; chmod 755 $S/bin/$t; done
pol() { # label lock(none|file|dot) in_swaps(0|1) used state
	rm -f $S/calls $S/locks/* $S/locks/.[!.]* 2>/dev/null
	case $2 in file) : > $S/locks/update.lock ;; dot) : > $S/locks/.inprogress ;; esac
	printf 'Filename Type Size Used Priority\n' > $S/proc/swaps
	[ $3 = 1 ] && printf '%s file 131068 %s 10\n' $S/swapfile $4 >> $S/proc/swaps
	r=$(NEBULAOS_MEMGUARD_NO_AUTORUN=1 MG_PROC=$S/proc MG_RUN=$S/run MG_LOCKS=$S/locks MG_LOG=$S/mg.log \
		MG_MOONRAKER=http://127.0.0.1:9 MG_SWAPFILE=$S/swapfile MG_SWAPON=$S/bin/swapon MG_SWAPOFF=$S/bin/swapoff sh -c '
		. /usr/libexec/nebulaos-memguard; NOW=1000 PRINT=0 STATE='$5' MA=150000 ZU=0 ZL=50331648
		mg_poll_maint_state; mg_diskswap_reconcile; wait; echo "MAINT=$MAINT"' 2>&1 | tail -1)
	echo "POLICY $1 lock=$2 active=$3 used=$4 state=$5 -> $r calls=[$(cat $S/calls 2>/dev/null | tr "\n" " ")]"
}
pol idle-off none 0 0 NORMAL
pol idle-on-unused none 1 0 NORMAL
pol idle-on-used none 1 2048 NORMAL
pol idle-on-used-P2 none 1 2048 P2
pol lock-off file 0 0 NORMAL
pol dotlock-off dot 0 0 NORMAL
pol lock-on file 1 0 NORMAL
rm -rf $S
