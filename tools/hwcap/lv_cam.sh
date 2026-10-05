#!/bin/sh
# Live fix verification S3 + S4 (2026-10-05). Patched copies in
# /run/nebulaos-live-verify of the camera idle library (S3: no marker -> C2,
# only an explicit C0 marker opts out) and of S51 (sources that library; S4:
# stop() waits for the loop to finish, resumes, then clears the state file).
# The real marker file is never written; the undo stops the patched
# controller, resumes ustreamer and restores the previous state file.
L=/run/nebulaos-live-verify; mkdir -p $L
LIB=$L/cam-lib.sh; S51=$L/S51-patched; SF=/var/run/nebulaos-camera-idle-state
M=/usr/data/nebulaos/maintenance/camera-idle-mode
awk '/^nebulaos_camera_idle_requested_mode\(\) \{/ {print; print "\tmarker=\"${1:-$NEBULAOS_CAMERA_IDLE_MARKER}\""; print "\tif [ -f \"$marker\" ] && [ \"$(cat \"$marker\" 2>/dev/null)\" = \"C0\" ]; then"; print "\t\tprintf '"'"'C0'"'"'"; print "\telse"; print "\t\tprintf '"'"'C2'"'"'"; print "\tfi"; skip=1; next}
	skip && /^\}/ {skip=0} !skip {print}' /etc/nebulaos-camera-idle-controller.sh > $LIB
cat > $L/s4-stop <<'S4_STOP'
stop() {
	echo "Stopping S51nebulaos-camera-idle-controller"
	pid=$(cat "$PIDFILE" 2>/dev/null)
	start-stop-daemon -K -p "$PIDFILE" 2>/dev/null
	# S4 (G4): the loop runs its TERM trap only after its current poll sleep;
	# wait for it so it cannot write a state after the reset below.
	i=0
	while [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do
		sleep 0.5
		i=$((i + 1))
	done
	rm -f "$PIDFILE"
	# Always try to resume on the way out, so stopping this controller
	# (or a production disable via marker removal) never leaves the
	# camera stuck paused. Once resumed, no stale "paused" belief remains.
	if command -v nebulaos_camera_resume_with_retry >/dev/null 2>&1 && nebulaos_camera_resume_with_retry >/dev/null 2>&1; then
		rm -f "${NEBULAOS_CAMERA_IDLE_STATE_FILE:-/var/run/nebulaos-camera-idle-state}"
	fi
	:
}
S4_STOP
awk -v lib=$LIB -v ins=$L/s4-stop '{gsub("/etc/nebulaos-camera-idle-controller.sh", lib)}
	/^stop\(\) \{/ {while ((getline l < ins) > 0) print l; skip=1; next} skip && /^\}/ {skip=0; next} !skip {print}' \
	/etc/init.d/S51nebulaos-camera-idle-controller > $S51
chmod 755 $S51
echo "== patch"; sed -n '/^nebulaos_camera_idle_requested_mode/,/^}/p' $LIB; grep -c "$LIB" $S51 | sed 's/^/S51_sources_patched_lib=/'
SF0=$(cat $SF 2>/dev/null || echo absent); CAMLV=1
echo "before: marker=$(cat $M 2>/dev/null || echo absent) state=$SF0 (image S51 stop leaves its last state: G4) controller_pidfile=$(cat /var/run/nebulaos-camera-idle-controller.pid 2>/dev/null || echo absent)"

echo "== S3 mode table (image lib | patched lib)"
for c in absent C0 C2 garbage empty; do
	f=$L/mk-$c; rm -f $f; case $c in absent) ;; empty) : > $f ;; *) echo $c > $f ;; esac
	a=$(sh -c ". /etc/nebulaos-camera-idle-controller.sh; nebulaos_camera_idle_requested_mode $f")
	b=$(sh -c ". $LIB; nebulaos_camera_idle_requested_mode $f"); echo "MODE marker=$c image=$a patched=$b"; rm -f $f
done

ms() { awk '{printf "%d", $1 * 1000}' /proc/uptime; }
ust() { p=$(cat /var/run/ustreamer.pid); a=$(awk '{print $14+$15}' /proc/$p/stat); sleep 20; b=$(awk '{print $14+$15}' /proc/$p/stat)
	awk -v d=$((b - a)) -v l=$1 'BEGIN{printf "CPU %s ustreamer=%.2f%% (20 s)\n", l, d/20}'; }
online() { curl -s --max-time 2 http://127.0.0.1:8080/state | tr -d ' \n' | grep -o '"online":[a-z]*' | head -1; }
waitstate() { i=0; while [ "$(cat $SF 2>/dev/null)" != "$1" ] && [ $i -lt $2 ]; do sleep 1; i=$((i + 1)); done; echo "state=$(cat $SF 2>/dev/null || echo absent) after_s=$i"; }
# controller loops by exact argv ("sh <script> __run"); never matches this script itself
nctl() { for c in /proc/[0-9]*/cmdline; do tr '\0' ' ' < $c 2>/dev/null; echo; done | grep -cE '(idle-controller|S51-patched) __run $'; }
show() { echo "  $1: state=$(cat $SF 2>/dev/null || echo absent) $(online) controllers=$(nctl)"; }

echo "== S3 live: default start (no marker)"; $S51 start; show started; waitstate paused 150; sleep 3; ust paused; show paused
for c in 1 2; do
	t0=$(ms); curl -s --max-time 20 -o /dev/null -w "  stream_bytes=%{size_download}\n" http://127.0.0.1:8080/stream & V=$!
	k=0; until online | grep -q true || [ $k -ge 200 ]; do sleep 0.1; k=$((k + 1)); done
	echo "  viewer $c resume_ms=$(( $(ms) - t0 )) $(online)"; wait $V; V=; waitstate paused 150
done
echo "== S4: stop while paused"; t0=$(ms); $S51 stop > /dev/null; show "stopped (stop_ms=$(( $(ms) - t0 )))"
sleep 6; show "6 s after stop"
echo "== S4: start again (fresh state), stop while active"; $S51 start > /dev/null; sleep 2; show restarted
t0=$(ms); $S51 stop > /dev/null; show "stopped while active (stop_ms=$(( $(ms) - t0 )))"
echo "== S4: restart cycle from paused"; $S51 start > /dev/null; waitstate paused 150
t0=$(ms); $S51 restart > /dev/null; show "restart (ms=$(( $(ms) - t0 )))"; waitstate paused 150; show "paused again"
t0=$(ms); $S51 stop > /dev/null; show "final stop (stop_ms=$(( $(ms) - t0 )))"
echo "orphans=$(nctl) pidfile=$(cat /var/run/nebulaos-camera-idle-controller.pid 2>/dev/null || echo absent)"
