#!/bin/sh
# Live gap verification G5 (2026-10-05): S97's display gate reads the
# backlight driver's debugfs status, and debugfs is not mounted on the image.
# Mounts debugfs temporarily (the undo unmounts it again if this run mounted
# it), reads both display drivers' status, re-evaluates all four S97 gates and
# runs the image's S97 with a synthetic qualification_complete=1 config from
# tmpfs and ndq_apply_all stubbed (nothing is ever applied to the display).
L=/run/nebulaos-live-verify; mkdir -p $L
D=/sys/kernel/debug
echo "debugfs_mounted_before=$(grep -c " $D debugfs " /proc/mounts) owner_of_mounts=$(grep -l debugfs /etc/fstab /etc/inittab /etc/init.d/* 2>/dev/null | tr '\n' ' ')"
gates() {
	/etc/nebulaos-healthcheck.sh stage2 > /dev/null 2>&1 && echo -n "stack=ok " || echo -n "stack=fail "
	p=$(cat /var/run/guppyscreen.pid 2>/dev/null); [ -n "$p" ] && kill -0 $p 2>/dev/null && echo -n "guppyscreen=ok " || echo -n "guppyscreen=fail "
	ip -4 -o addr show scope global 2>/dev/null | grep -qv '^$' && echo -n "network=ok " || echo -n "network=fail "
	[ -r $D/nebulaos_backlight_final/status ] && cat $D/nebulaos_backlight_final/status > /dev/null 2>&1 && echo "display=ok" || echo "display=fail"
}
echo "GATES_BEFORE $(gates)"
if ! grep -q " $D debugfs " /proc/mounts; then
	mount -t debugfs -o ro,nosuid,nodev,noexec debugfs $D && { G5M=1; echo "mounted debugfs read-only (temporary)"; } || echo "MOUNT_FAILED rc=$?"
fi
echo "GATES_WITH_DEBUGFS $(gates)"
echo "== backlight status"; cat $D/nebulaos_backlight_final/status 2>&1 | head -30
echo "== touch dir"; ls $D/ns2009_final_qualification 2>&1; cat $D/ns2009_final_qualification/status 2>&1 | head -20
echo "== backlight dir"; ls -l $D/nebulaos_backlight_final 2>&1
echo "== display controllers"; ps | grep -E '[d]isplay-(sleep|qualified)' | head -3
cat /var/log/messages 2>/dev/null | grep -E 'S97|S98|display-qualified|sleep-wake' | tail -6
echo "== S97 (image) with a synthetic qualification_complete=1 config, apply stubbed, debugfs mounted"
printf '. /etc/nebulaos-display-qualified.sh\nndq_apply_all() { echo "STUB_APPLY_CALLED $1"; return 1; }\n' > $L/ndq-wrap-g5.sh
printf 'qualification_complete=1\n' > $L/g5-synthetic-qc1
t0=$(awk '{printf "%d", $1 * 1000}' /proc/uptime)
MARKER=$L/g5marker NDQ_LIB=$L/ndq-wrap-g5.sh NDQ_CONFIG_FILE=$L/g5-synthetic-qc1 HEALTH_RETRIES=5 HEALTH_DELAY=1 \
	sh /etc/init.d/S97nebulaos-display-qualified-apply start 2>&1 | sed 's/^/  /'
echo "  ms=$(( $(awk '{printf "%d", $1 * 1000}' /proc/uptime) - t0 ))"
rm -f $L/ndq-wrap-g5.sh $L/g5-synthetic-qc1 $L/g5marker
