#!/bin/sh
# Live fix verification S2 (2026-10-05): S97 exits at once when there is no
# qualified display configuration. Runs the image's S97 and a patched copy
# from /run/nebulaos-live-verify with a temporary MARKER and synthetic configs
# in tmpfs. The NDQ library is the image's, wrapped so ndq_apply_all only
# reports that it would have been called: nothing is ever applied, and the
# real marker and /usr/data/nebulaos/display-qualified.conf are not touched.
O=/etc/init.d/S97nebulaos-display-qualified-apply
L=/run/nebulaos-live-verify; P=$L/S97-patched; W=$L/ndq-wrap.sh; C=$L/s2conf
mkdir -p $L $C
cat > $L/s2-insert <<'S2_INSERT'
	# S2 (G3): nothing to apply without a qualified configuration - do not
	# wait for the health gates at all.
	if [ ! -f "$NDQ_CONFIG_FILE" ]; then
		log "no display-qualified configuration ($NDQ_CONFIG_FILE) - nothing to apply"
		exit 0
	fi
	if [ "$(ndq_get_field "$NDQ_CONFIG_FILE" qualification_complete 2>/dev/null)" != "1" ]; then
		log "$NDQ_CONFIG_FILE is not qualification_complete=1 - nothing to apply"
		exit 0
	fi
S2_INSERT
awk -v ins=$L/s2-insert '{print} /^\ttouch "\$MARKER"$/ {while ((getline l < ins) > 0) print l}' $O > $P
chmod 755 $P
echo "patch: inserted_lines=$(( $(wc -l < $P) - $(wc -l < $O) ))"; diff $O $P | grep -c '^>' | sed 's/^/diff_added=/'
printf '. /etc/nebulaos-display-qualified.sh\nndq_apply_all() { echo "STUB_APPLY_CALLED $1"; return 1; }\n' > $W
echo "real_config=$(ls /usr/data/nebulaos/display-qualified.conf 2>&1) real_marker=$(ls /run/nebulaos-display-qualified-apply-attempted 2>&1)"
echo "debugfs=$(grep -c ' /sys/kernel/debug debugfs ' /proc/mounts)"

ms() { awk '{printf "%d", $1 * 1000}' /proc/uptime; }
n=0
run() { # script config-file [env...]
	f=$1; cf=$2; shift 2; n=$((n + 1))
	t0=$(ms)
	o=$(env MARKER=$L/s2marker.$n NDQ_LIB=$W NDQ_CONFIG_FILE=$cf "$@" sh $f start 2>&1); r=$?
	t1=$(ms)
	echo "  rc=$r ms=$((t1 - t0)) apply_called=$(printf '%s\n' "$o" | grep -c STUB_APPLY_CALLED) out=$(printf '%s' "$o" | sed 's/^S97nebulaos-display-qualified-apply: //' | tr '\n' '|' | cut -c1-240)"
}
printf 'qualification_complete=0\nformat_version=1\n' > $C/qc0
printf 'this is not a config\n\001\002\n' > $C/malformed
printf 'qualification_complete=\n' > $C/qcempty
printf 'qualification_complete=1\nqualification_complete=0\n' > $C/qclast0
printf 'qualification_complete=0\nqualification_complete=1\n' > $C/synthetic-qc1
: > $C/empty
for c in absent qc0 malformed qcempty qclast0 empty; do
	echo "PATCHED case=$c"; run $P $C/$c
done
echo "PATCHED case=synthetic-qc1 (must still reach the health gates; HEALTH_RETRIES=2 HEALTH_DELAY=1)"
run $P $C/synthetic-qc1 HEALTH_RETRIES=2 HEALTH_DELAY=1
echo "PATCHED case=marker-rerun"
t0=$(ms); o=$(env MARKER=$L/s2marker.$n NDQ_LIB=$W NDQ_CONFIG_FILE=$C/absent sh $P start 2>&1); echo "  ms=$(( $(ms) - t0 )) out=$o"
echo "IMAGE case=absent, image defaults (the measured boot cost)"
run $O $C/absent
echo "IMAGE case=synthetic-qc1 HEALTH_RETRIES=2 HEALTH_DELAY=1"
run $O $C/synthetic-qc1 HEALTH_RETRIES=2 HEALTH_DELAY=1
echo "real_marker_after=$(ls /run/nebulaos-display-qualified-apply-attempted 2>&1) real_config_after=$(ls /usr/data/nebulaos/display-qualified.conf 2>&1)"
echo "debugfs_after=$(grep -c ' /sys/kernel/debug debugfs ' /proc/mounts)"
