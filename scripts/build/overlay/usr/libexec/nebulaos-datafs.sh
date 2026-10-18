# shellcheck shell=sh
#
# G9 phase 1 (2026-10-07): /usr/data (ext4, no journal, stock layout) boot
# check policy and clean shutdown. Sourced by S01persistent-datastore; every
# path and tool is overridable so tests/datafs-policy-tests.sh can run the
# same functions against disposable ext4 images and fake mount tools.
#
# Boot (ndf_precheck, before the mount):
#   superblock clean               -> mount rw, no fsck                CLEAN
#   not clean / with errors        -> bounded `e2fsck -p` (preen: only
#                                     the automatic safe repairs)
#       exit 0                     -> mount rw                         CHECKED_OK
#       exit 1|2 (corrected)       -> mount rw                         REPAIRED
#       exit has 4 or 8            -> bounded FULL repair `e2fsck -fy`:
#           no error left          -> mount rw                         AUTO_REPAIRED
#           exit has 4 again       -> mount READ-ONLY                  UNREPAIRED
#           exit has 8|16|32|128   -> mount READ-ONLY                  CHECK_FAILED
#       still running at the bound -> stopped, mount READ-ONLY         TIMEOUT
#   e2fsck/dumpe2fs missing        -> mount rw as before               TOOL_MISSING
# Never mkfs.
#
# G75 (Run 12, 2026-10-18): a journal on /usr/data. Pulling the power is how
# this printer is switched off; without a journal that can leave the
# filesystem's bookkeeping half-written (Run 11 on ke-dev: an unattached
# inode the preen pass could not fix). With a journal the kernel replays it
# at mount and the filesystem stays consistent - no check, no repair. So
# before a read-write mount, a filesystem without one gets it, once
# (`tune2fs -O has_journal`, NDF_JOURNAL_MB). Only on a filesystem that just
# checked or repaired clean (or was clean); a failure is logged and the boot
# goes on without a journal. The Creality slot mounts the same partition:
# has_journal is a "compatible" ext4 feature and every ext4 kernel has
# journal support (EXT4_FS selects JBD2), so its 4.4 kernel mounts it.
#
# Run 11 (2026-10-17, ke-dev): a power cut left one unattached inode that the
# preen pass may not fix ("RUN fsck MANUALLY"). The old policy then mounted
# /usr/data read-only and waited for a supervised repair - which a printer
# owner has no way to run, so the printer did not come up. The printer must
# always boot: the full repair (`-fy`) is what a supervised repair would do
# (orphans go to lost+found, bitmaps and counts are corrected). The preen
# output stays in $NDF_CHECK_OUT, the repair's in $NDF_CHECK_OUT.repair.
# Read-only remains only for what even the full repair cannot fix; the boot
# then still continues (rcS gives every script stdin from /dev/null, so
# nothing waits for a console answer). The result is in $NDF_STATE (tmpfs),
# on the console and in syslog, and - for writable mounts - appended to the
# persistent diagnostics log.
#
# Shutdown (ndf_shutdown, last in rcK): leftover users of the filesystem
# (services are already stopped in reverse order by rcK) get TERM, a bounded
# wait, then KILL; the eMMC swap tier is turned off; mounts living on or under
# the filesystem are unmounted deepest first; then /usr/data is unmounted, or
# at least remounted read-only. Either leaves the superblock clean, so the
# next boot needs no check. Result: CLEAN | CLEAN_RO | BUSY | FAILED.

NDF_DEV="${NDF_DEV:-/dev/mmcblk0p10}"
NDF_MNT="${NDF_MNT:-/usr/data}"
NDF_STATE="${NDF_STATE:-/run/nebulaos/data-fs.state}"
NDF_DIAG_LOG_REL="${NDF_DIAG_LOG_REL:-nebulaos/system/diagnostics/data-fs.log}"
NDF_CHECK_TIMEOUT="${NDF_CHECK_TIMEOUT:-300}"
NDF_STOP_WAIT="${NDF_STOP_WAIT:-8}"
NDF_PROC_MOUNTS="${NDF_PROC_MOUNTS:-/proc/mounts}"
NDF_PROC_SWAPS="${NDF_PROC_SWAPS:-/proc/swaps}"
NDF_SWAPFILE="${NDF_SWAPFILE:-$NDF_MNT/nebulaos/system/swapfile}"
NDF_PATH="${NDF_PATH:-/sbin:/usr/sbin:/bin:/usr/bin}"
NDF_E2FSCK="${NDF_E2FSCK:-$(PATH=$NDF_PATH command -v e2fsck 2>/dev/null)}"
NDF_DUMPE2FS="${NDF_DUMPE2FS:-$(PATH=$NDF_PATH command -v dumpe2fs 2>/dev/null)}"
NDF_TUNE2FS="${NDF_TUNE2FS:-$(PATH=$NDF_PATH command -v tune2fs 2>/dev/null)}"
NDF_JOURNAL_MB="${NDF_JOURNAL_MB:-16}"
NDF_MOUNT="${NDF_MOUNT:-mount}"
NDF_UMOUNT="${NDF_UMOUNT:-umount}"
NDF_FUSER="${NDF_FUSER:-fuser}"
NDF_SWAPOFF="${NDF_SWAPOFF:-swapoff}"
NDF_KILL="${NDF_KILL:-kill}"

# The boot check runs before syslogd (S01syslogd) starts, so `logger` alone
# reached nothing at boot: every line also goes to the kernel log, which
# klogd/syslogd pick up later and `dmesg` always shows (2026-10-15).
NDF_KMSG="${NDF_KMSG:-/dev/kmsg}"
ndf_log() {
	echo "nebulaos-datafs: $*"
	# G67: kmsg lines without a <N> prefix land at warning level; routine
	# lines are info (<6>), only failures stay warnings (<4>).
	case "$*" in *FAIL*|*fail*|*RECOVERY*|*READ-ONLY*|*"could not"*|*"still holding"*|*"left mounted"*) _ndf_pri="<4>" ;; *) _ndf_pri="<6>" ;; esac
	[ -n "$NDF_KMSG" ] && { echo "${_ndf_pri}nebulaos-datafs: $*" >> "$NDF_KMSG"; } 2>/dev/null
	command -v logger >/dev/null 2>&1 && logger -t nebulaos-datafs -- "$*" 2>/dev/null
	return 0
}

ndf_now() { cut -d' ' -f1 /proc/uptime 2>/dev/null; }

# G75: has_journal in the superblock features? (0 = yes)
ndf_has_journal() {
	"$NDF_DUMPE2FS" -h "$NDF_DEV" 2>/dev/null | grep -q '^Filesystem features:.*has_journal'
}

# G75: add the journal once, before a read-write mount. Sets NDF_JOURNAL
# (present | added | failed | skipped).
ndf_ensure_journal() {
	NDF_JOURNAL=skipped
	[ -n "$NDF_DUMPE2FS" ] && [ -n "$NDF_TUNE2FS" ] && [ -x "$NDF_TUNE2FS" ] || return 0
	if ndf_has_journal; then
		NDF_JOURNAL=present
		return 0
	fi
	if "$NDF_TUNE2FS" -O has_journal -J size="$NDF_JOURNAL_MB" "$NDF_DEV" > /dev/null 2>&1 < /dev/null \
		&& ndf_has_journal; then
		NDF_JOURNAL=added
		ndf_log "added a ${NDF_JOURNAL_MB} MB journal to $NDF_DEV - a power cut no longer needs a repair"
	else
		NDF_JOURNAL=failed
		ndf_log "could not add a journal to $NDF_DEV - continuing without one"
	fi
}

# "clean", "not clean", "clean with errors", "not clean with errors", or "".
ndf_fs_state() {
	[ -n "$NDF_DUMPE2FS" ] || return 0
	"$NDF_DUMPE2FS" -h "$NDF_DEV" 2>/dev/null | sed -n 's/^Filesystem state:[[:space:]]*//p' | head -1
}

# Runs `e2fsck -p` (or, with $1 = repair, `e2fsck -fy`) with a watchdog. Sets
# NDF_RC (124 = stopped at the bound) and leaves the checker's output in
# NDF_CHECK_OUT (the repair's in NDF_CHECK_OUT.repair).
ndf_run_check() {
	NDF_CHECK_OUT="${NDF_CHECK_OUT:-/run/nebulaos/data-fs.e2fsck.log}"
	mkdir -p "$(dirname "$NDF_CHECK_OUT")" 2>/dev/null
	if [ "${1:-}" = repair ]; then
		"$NDF_E2FSCK" -fy "$NDF_DEV" > "$NDF_CHECK_OUT.repair" 2>&1 < /dev/null &
	else
		"$NDF_E2FSCK" -p "$NDF_DEV" > "$NDF_CHECK_OUT" 2>&1 < /dev/null &
	fi
	_pid=$!
	_i=0
	while kill -0 "$_pid" 2>/dev/null && [ "$_i" -lt "$NDF_CHECK_TIMEOUT" ]; do
		sleep 1
		_i=$((_i + 1))
	done
	if kill -0 "$_pid" 2>/dev/null; then
		"$NDF_KILL" -TERM "$_pid" 2>/dev/null
		sleep 2
		kill -0 "$_pid" 2>/dev/null && "$NDF_KILL" -KILL "$_pid" 2>/dev/null
		wait "$_pid" 2>/dev/null
		NDF_RC=124
		return 0
	fi
	wait "$_pid"
	NDF_RC=$?
}

# Decides how to mount. Sets NDF_RESULT and NDF_MOUNT_OPTS (rw|ro) and writes
# $NDF_STATE. Never modifies the filesystem except through e2fsck.
ndf_precheck() {
	NDF_RC=
	NDF_PREEN_RC=
	NDF_T0=$(ndf_now)
	NDF_FS_STATE_BEFORE=
	if [ -z "$NDF_E2FSCK" ] || [ -z "$NDF_DUMPE2FS" ] || [ ! -x "$NDF_E2FSCK" ] || [ ! -x "$NDF_DUMPE2FS" ]; then
		NDF_RESULT=TOOL_MISSING NDF_MOUNT_OPTS=rw
	else
		NDF_FS_STATE_BEFORE=$(ndf_fs_state)
		if [ "$NDF_FS_STATE_BEFORE" = clean ]; then
			NDF_RESULT=CLEAN NDF_MOUNT_OPTS=rw
		else
			ndf_log "filesystem state '${NDF_FS_STATE_BEFORE:-unreadable}' on $NDF_DEV - running e2fsck -p (bound ${NDF_CHECK_TIMEOUT}s)"
			ndf_run_check
			if [ "$NDF_RC" != 124 ] && [ $((NDF_RC & 12)) -ne 0 ]; then
				NDF_PREEN_RC=$NDF_RC
				ndf_log "e2fsck -p could not repair $NDF_DEV (rc=$NDF_RC) - running the full repair e2fsck -fy (bound ${NDF_CHECK_TIMEOUT}s)"
				ndf_run_check repair
			fi
			if [ "$NDF_RC" = 124 ]; then
				NDF_RESULT=TIMEOUT NDF_MOUNT_OPTS=ro
			elif [ $((NDF_RC & 4)) -ne 0 ]; then
				NDF_RESULT=UNREPAIRED NDF_MOUNT_OPTS=ro
			elif [ $((NDF_RC & 248)) -ne 0 ]; then
				NDF_RESULT=CHECK_FAILED NDF_MOUNT_OPTS=ro
			elif [ -n "$NDF_PREEN_RC" ]; then
				NDF_RESULT=AUTO_REPAIRED NDF_MOUNT_OPTS=rw
			elif [ $((NDF_RC & 3)) -ne 0 ]; then
				NDF_RESULT=REPAIRED NDF_MOUNT_OPTS=rw
			else
				NDF_RESULT=CHECKED_OK NDF_MOUNT_OPTS=rw
			fi
		fi
	fi
	NDF_JOURNAL=
	[ "$NDF_MOUNT_OPTS" = rw ] && [ "$NDF_RESULT" != TOOL_MISSING ] && ndf_ensure_journal
	NDF_T1=$(ndf_now)
	mkdir -p "$(dirname "$NDF_STATE")" 2>/dev/null
	{
		echo "DATAFS_RESULT=$NDF_RESULT"
		echo "DATAFS_MOUNT=$NDF_MOUNT_OPTS"
		echo "DATAFS_STATE_BEFORE='${NDF_FS_STATE_BEFORE}'"
		echo "DATAFS_E2FSCK_RC=${NDF_RC}"
		[ -n "$NDF_PREEN_RC" ] && echo "DATAFS_PREEN_RC=$NDF_PREEN_RC"
		[ -n "$NDF_JOURNAL" ] && echo "DATAFS_JOURNAL=$NDF_JOURNAL"
		echo "DATAFS_CHECK_SECONDS=$(awk -v a="$NDF_T0" -v b="$NDF_T1" 'BEGIN{printf "%.2f", b-a}')"
	} > "$NDF_STATE" 2>/dev/null
	if [ "$NDF_MOUNT_OPTS" = ro ]; then
		ndf_log "RECOVERY REQUIRED: $NDF_DEV $NDF_RESULT (e2fsck rc=$NDF_RC${NDF_PREEN_RC:+, after the full repair}) - mounting $NDF_MNT READ-ONLY to preserve the data (see $NDF_STATE)"
	else
		ndf_log "$NDF_DEV $NDF_RESULT (state before '${NDF_FS_STATE_BEFORE}', e2fsck rc=${NDF_RC:-none}) - mounting read-write"
	fi
}

# The mount itself, with the decided options.
# A failed mount is retried once after a short pause and always reported:
# on 2026-10-14 ke-dev booted without its data partition mounted read-write
# and nothing said why (2026-10-15).
NDF_MOUNT_RETRY_DELAY="${NDF_MOUNT_RETRY_DELAY:-2}"
ndf_mount() {
	_err=$("$NDF_MOUNT" -t ext4 -o "$NDF_MOUNT_OPTS" "$NDF_DEV" "$NDF_MNT" 2>&1) && {
		ndf_log "mounted $NDF_DEV on $NDF_MNT ($NDF_MOUNT_OPTS)"
		return 0
	}
	ndf_log "mount of $NDF_DEV on $NDF_MNT ($NDF_MOUNT_OPTS) failed: ${_err:-no message} - retrying in ${NDF_MOUNT_RETRY_DELAY}s"
	sleep "$NDF_MOUNT_RETRY_DELAY"
	_err=$("$NDF_MOUNT" -t ext4 -o "$NDF_MOUNT_OPTS" "$NDF_DEV" "$NDF_MNT" 2>&1) && {
		ndf_log "mounted $NDF_DEV on $NDF_MNT ($NDF_MOUNT_OPTS) on the second attempt"
		return 0
	}
	ndf_log "MOUNT FAILED: $NDF_DEV on $NDF_MNT ($NDF_MOUNT_OPTS): ${_err:-no message} - NebulaOS runs without its data this boot"
	echo "DATAFS_MOUNT_FAILED=1" >> "$NDF_STATE" 2>/dev/null
	return 1
}

# After a writable mount: the persistent record of this boot's decision.
ndf_record() {
	[ "$NDF_MOUNT_OPTS" = rw ] || return 0
	_log="$NDF_MNT/$NDF_DIAG_LOG_REL"
	mkdir -p "$(dirname "$_log")" 2>/dev/null || return 0
	{
		printf '%s boot: %s (state before %s, e2fsck rc %s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			"$NDF_RESULT" "'${NDF_FS_STATE_BEFORE}'" "${NDF_RC:-none}"
		[ -n "${NDF_RC:-}" ] && [ -s "${NDF_CHECK_OUT:-/nonexistent}" ] && sed 's/^/    e2fsck: /' "$NDF_CHECK_OUT" | tail -n 20
	} >> "$_log" 2>/dev/null
	return 0
}

# Mount points on the filesystem (its device) and anything mounted beneath
# them, deepest first - excluding $NDF_MNT itself.
ndf_dependent_mounts() {
	awk -v dev="$NDF_DEV" -v mnt="$NDF_MNT" '
		{ src[NR] = $1; mp[NR] = $2 }
		END {
			n = 0
			for (i = 1; i <= NR; i++) if (src[i] == dev && mp[i] != mnt) roots[++n] = mp[i]
			for (i = 1; i <= NR; i++) {
				if (mp[i] == mnt) continue
				keep = (src[i] == dev)
				for (j = 1; j <= n && !keep; j++) if (index(mp[i], roots[j] "/") == 1) keep = 1
				if (index(mp[i], mnt "/") == 1) keep = 1
				if (keep) print length(mp[i]) " " mp[i]
			}
		}' "$NDF_PROC_MOUNTS" | sort -rn | cut -d' ' -f2- | awk '!seen[$0]++'
}

# PIDs still using the filesystem (never 1, never this shell).
ndf_holders() {
	"$NDF_FUSER" -m "$NDF_MNT" 2>/dev/null | tr -s ' \t' '\n' | grep -E '^[0-9]+$' | grep -vxE "1|$$" | tr '\n' ' '
}

ndf_shutdown() {
	if ! awk -v m="$NDF_MNT" '$2==m {f=1} END {exit !f}' "$NDF_PROC_MOUNTS" 2>/dev/null; then
		ndf_log "shutdown: $NDF_MNT not mounted - nothing to do"
		NDF_SHUTDOWN_RESULT=NOT_MOUNTED
		return 0
	fi
	_log="$NDF_MNT/$NDF_DIAG_LOG_REL"
	printf '%s shutdown: begin\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$_log" 2>/dev/null
	_h=$(ndf_holders)
	if [ -n "$_h" ]; then
		ndf_log "shutdown: stopping leftover users of $NDF_MNT: $_h"
		# shellcheck disable=SC2086
		"$NDF_KILL" -TERM $_h 2>/dev/null
		_i=0
		while [ -n "$(ndf_holders)" ] && [ "$_i" -lt "$NDF_STOP_WAIT" ]; do
			sleep 1
			_i=$((_i + 1))
		done
		_h=$(ndf_holders)
		if [ -n "$_h" ]; then
			ndf_log "shutdown: still holding $NDF_MNT after ${NDF_STOP_WAIT}s, killing: $_h"
			# shellcheck disable=SC2086
			"$NDF_KILL" -KILL $_h 2>/dev/null
			sleep 1
		fi
	fi
	if grep -q "^$NDF_SWAPFILE " "$NDF_PROC_SWAPS" 2>/dev/null; then
		"$NDF_SWAPOFF" "$NDF_SWAPFILE" 2>/dev/null && ndf_log "shutdown: eMMC swap tier off" \
			|| ndf_log "shutdown: swapoff $NDF_SWAPFILE failed"
	fi
	sync
	_failed_mounts=""
	for _m in $(ndf_dependent_mounts); do
		"$NDF_UMOUNT" "$_m" 2>/dev/null || { ndf_log "shutdown: could not unmount $_m"; _failed_mounts="$_failed_mounts $_m"; }
	done
	# G4 (2026-10-12): the persistent record of what still holds the
	# filesystem right before the final unmount. The system log is already
	# stopped at this point (and was in RAM before G24), so without this the
	# reason for a "not clean" next boot was never visible anywhere.
	_hold=$(ndf_holders)
	_names=""
	for _p in $_hold; do _names="$_names $_p:$(cat "/proc/$_p/comm" 2>/dev/null)"; done
	printf '%s shutdown: before unmount - holders:%s; mounts left:%s\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${_names:- none}" "${_failed_mounts:- none}" >> "$_log" 2>/dev/null
	sync
	if "$NDF_UMOUNT" "$NDF_MNT" 2>/dev/null; then
		NDF_SHUTDOWN_RESULT=CLEAN
	elif "$NDF_MOUNT" -o remount,ro "$NDF_MNT" 2>/dev/null; then
		NDF_SHUTDOWN_RESULT=CLEAN_RO
	elif [ -n "$(ndf_holders)" ]; then
		NDF_SHUTDOWN_RESULT=BUSY
	else
		NDF_SHUTDOWN_RESULT=FAILED
	fi
	case "$NDF_SHUTDOWN_RESULT" in
		CLEAN|CLEAN_RO) ndf_log "shutdown: $NDF_MNT $NDF_SHUTDOWN_RESULT" ;;
		*)
			ndf_log "shutdown: $NDF_MNT $NDF_SHUTDOWN_RESULT - left mounted read-write (holders: $(ndf_holders))"
			# Still writable, so the outcome can go into the persistent record.
			_names=""
			for _p in $(ndf_holders); do _names="$_names $_p:$(cat "/proc/$_p/comm" 2>/dev/null)"; done
			printf '%s shutdown: %s - left read-write; holders:%s; open for writing: %s\n' \
				"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NDF_SHUTDOWN_RESULT" "${_names:- none}" \
				"$(ls -l /proc/[0-9]*/fd 2>/dev/null | grep -c "$NDF_MNT")" >> "$_log" 2>/dev/null
			sync
			;;
	esac
	return 0
}
