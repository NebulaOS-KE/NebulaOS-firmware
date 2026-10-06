#!/bin/sh
# Pre-final acceptance S3 + S4 (2026-10-07): the INSTALLED camera idle policy,
# using the image's own S51 and library - nothing patched, no marker written.
#   S3: default boot (no marker) -> C2 controller running, paused after the
#       grace, low paused CPU, DWC2 IRQ rate, runtime suspend, viewer resume
#       at 1080p30, re-pause, repeated cycles
#   S4: stop while paused -> resumed + state cleared; restart -> fresh active,
#       grace honoured, paused again; no orphan loop
# The undo leaves the product default running (S51 start).
S51=/etc/init.d/S51nebulaos-camera-idle-controller; SF=/var/run/nebulaos-camera-idle-state
M=/usr/data/nebulaos/maintenance/camera-idle-mode
ms() { awk '{printf "%d", $1 * 1000}' /proc/uptime; }
loops() { for c in /proc/[0-9]*/cmdline; do tr '\0' ' ' < $c 2>/dev/null; echo; done | grep -cE 'idle-controller __run $'; }
online() { curl -s --max-time 2 http://127.0.0.1:8080/state | tr -d ' \n' | grep -o '"online":[a-z]*' | head -1; }
fps() { curl -s --max-time 2 http://127.0.0.1:8080/state | tr -d ' \n' | grep -o '"captured_fps":[0-9]*' | head -1; }
res() { curl -s --max-time 2 http://127.0.0.1:8080/state | tr -d ' \n' | grep -o '"resolution":{[^}]*}' | head -1; }
pm() { for d in usb1 1-1 1-1.1 1-1.2; do printf '%s=%s ' $d "$(cat /sys/bus/usb/devices/$d/power/runtime_status 2>/dev/null)"; done; echo; }
irq() { a=$(awk '$1=="9:"{print $2+$3}' /proc/interrupts); sleep 10; b=$(awk '$1=="9:"{print $2+$3}' /proc/interrupts); echo "irq9_per_s=$(( (b - a) / 10 ))"; }
cpu() { p=$(cat /var/run/ustreamer.pid); a=$(awk '{print $14+$15}' /proc/$p/stat)
	w=$(for q in /proc/[0-9]*; do case "$(cat $q/comm 2>/dev/null)" in irq/9-*) awk '{print $14+$15}' $q/stat;; esac; done | awk '{s+=$1} END{print s+0}')
	sleep 20; b=$(awk '{print $14+$15}' /proc/$p/stat)
	x=$(for q in /proc/[0-9]*; do case "$(cat $q/comm 2>/dev/null)" in irq/9-*) awk '{print $14+$15}' $q/stat;; esac; done | awk '{s+=$1} END{print s+0}')
	awk -v d=$((b - a)) -v w=$((x - w)) -v l="$1" 'BEGIN{printf "CPU %s ustreamer=%.2f%% dwc2_irq_thread=%.2f%% (20 s)\n", l, d/20, w/20}'; }
waitstate() { i=0; while [ "$(cat $SF 2>/dev/null)" != "$1" ] && [ $i -lt $2 ]; do sleep 1; i=$((i + 1)); done; echo "state=$(cat $SF 2>/dev/null || echo absent) after_s=$i"; }
viewer() { # label
	t0=$(ms); curl -s --max-time 20 -o /dev/null -w "  $1 stream_bytes=%{size_download} Bps=%{speed_download}\n" http://127.0.0.1:8080/stream & V=$!
	k=0; until online | grep -q true || [ $k -ge 200 ]; do sleep 0.1; k=$((k + 1)); done
	echo "  $1 resume_ms=$(( $(ms) - t0 ))"; sleep 12; echo "  $1 $(fps) $(res) state=$(cat $SF 2>/dev/null)"; wait $V; V=
}
echo "== S3 boot default"
echo "marker=$(cat $M 2>/dev/null || echo absent) mode=$(sh -c '. /etc/nebulaos-camera-idle-controller.sh; nebulaos_camera_idle_requested_mode') loops=$(loops) state=$(cat $SF 2>/dev/null || echo absent) $(online)"
grep -h 'S51nebulaos-camera-idle' /var/log/messages 2>/dev/null | tail -2
waitstate paused 150; sleep 3
echo "paused: $(online) $(pm)"; cpu paused; irq
for c in 1 2 3; do echo "== viewer cycle $c"; viewer c$c; waitstate paused 150; done
cpu paused-after-cycles
echo "== S4 stop while paused"
t0=$(ms); $S51 stop > /dev/null 2>&1; echo "stop_ms=$(( $(ms) - t0 )) state=$(cat $SF 2>/dev/null || echo absent) loops=$(loops) $(online)"
sleep 6; echo "6s after stop: state=$(cat $SF 2>/dev/null || echo absent) $(online) $(fps)"
echo "== S4 restart: grace honoured"
t0=$(cut -d. -f1 /proc/uptime); $S51 start > /dev/null 2>&1; sleep 2; echo "started: state=$(cat $SF 2>/dev/null) loops=$(loops)"
waitstate paused 150; echo "pause_after_s=$(( $(cut -d. -f1 /proc/uptime) - t0 )) (grace 12 x 5 s)"
echo "== S4 restart cycle from paused"
t0=$(ms); $S51 restart > /dev/null 2>&1; echo "restart_ms=$(( $(ms) - t0 )) state=$(cat $SF 2>/dev/null) loops=$(loops)"
waitstate paused 150; echo "end: loops=$(loops) $(online)"
dmesg | tail -60 | grep -ciE 'usb .*disconnect|uvc.*error' | sed 's/^/usb_errors_tail=/'
