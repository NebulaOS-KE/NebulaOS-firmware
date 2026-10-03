# NebulaOS OOM priority policy (MEM-T07). Sourced by the service init scripts.
#
# Each service gets its oom_score_adj at process birth: the value is written to
# a subshell's own /proc/self/oom_score_adj and start-stop-daemon is exec'd from
# it, so the daemon and every child inherit it. The previous pattern wrote
# /proc/$(cat pidfile)/oom_score_adj after start-stop-daemon -b returned, which
# raced the fork and, with a stale pidfile, could adjust an unrelated process.
#
# Printer-critical processes are protected, optional UI/camera/update work is
# expendable. klipper_mcu is tiny and must never be the victim (-1000); klippy
# stays killable as a last resort (-900) so the kernel always has a sensible
# victim. nginx, dropbear and wpa_supplicant are Buildroot-owned scripts and are
# enforced by nebulaos-memguard's adj scan instead.
NEBULAOS_ADJ_KLIPPER_MCU=-1000
NEBULAOS_ADJ_KLIPPY=-900
NEBULAOS_ADJ_MEMGUARD=-900
NEBULAOS_ADJ_MOONRAKER=-400
NEBULAOS_ADJ_GUPPYSCREEN=0
NEBULAOS_ADJ_USTREAMER=300
NEBULAOS_ADJ_UPDATE_SUPERVISOR=500

# nebulaos_start_with_adj <adj> <command...>: run command with oom_score_adj set
# before it starts.
nebulaos_start_with_adj() {
	_nebulaos_adj="$1"
	shift
	( echo "$_nebulaos_adj" > /proc/self/oom_score_adj 2>/dev/null; exec "$@" )
}
