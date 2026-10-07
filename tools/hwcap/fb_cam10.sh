#!/bin/sh
# Final blockers NG5 (2026-10-07): 10 normal pause -> wake -> stream -> pause
# cycles through the product path (the installed C2 controller, no marker, a
# real viewer on the stream). Per cycle: pause reached, runtime-PM state, wake
# latency, first frames, 1080p30, new USB/UVC kernel messages, re-pause.
SF=/var/run/nebulaos-camera-idle-state
ms() { awk '{printf "%d", $1 * 1000}' /proc/uptime; }
st() { curl -s --max-time 2 http://127.0.0.1:8080/state | tr -d ' \n'; }
pm() { cat /sys/bus/usb/devices/1-1.1/power/runtime_status 2>/dev/null; }
loops() { for c in /proc/[0-9]*/cmdline; do tr '\0' ' ' < $c 2>/dev/null; echo; done | grep -cE 'idle-controller __run $'; }
waitpaused() { i=0; while [ "$(cat $SF 2>/dev/null)" != paused ] && [ $i -lt 150 ]; do sleep 1; i=$((i + 1)); done; echo $i; }
kmsg() { dmesg | grep -cE 'usb 1-1|uvcvideo|dwc2.*(error|fail)'; }
echo "start: loops=$(loops) state=$(cat $SF 2>/dev/null) pm=$(pm) ustreamer_pid=$(cat /var/run/ustreamer.pid)"
k0=$(kmsg); fail=0
for c in 1 2 3 4 5 6 7 8 9 10; do
	pw=$(waitpaused); sleep 5; p_pm=$(pm)
	ka=$(kmsg); t0=$(ms)
	curl -s --max-time 18 -o $T/s$c -w '%{size_download}' http://127.0.0.1:8080/stream > $T/b$c 2>/dev/null & V=$!
	k=0; until st | grep -q '"online":true' || [ $k -ge 300 ]; do sleep 0.1; k=$((k + 1)); done; t1=$(ms)
	sleep 10; fps=$(st | grep -o '"captured_fps":[0-9]*' | cut -d: -f2); res=$(st | grep -o '"width":[0-9]*,"height":[0-9]*')
	wait $V; V=; kb=$(cat $T/b$c 2>/dev/null); rm -f $T/s$c $T/b$c
	kd=$(( $(kmsg) - ka ))
	ok=yes; [ "$fps" -ge 25 ] 2>/dev/null || ok=no; [ "$k" -lt 300 ] || ok=no
	rp=$(waitpaused); [ "$rp" -lt 150 ] || ok=no; [ $ok = yes ] || fail=$((fail + 1))
	echo "CAM cycle=$c paused_after_s=$pw pm_paused=$p_pm wake_ms=$((t1 - t0)) fps=$fps $res stream_bytes=$kb new_usb_uvc_kmsgs=$kd repaused_after_s=$rp recovered=$ok"
	[ "$kd" -gt 0 ] && dmesg | grep -E 'usb 1-1|uvcvideo|dwc2' | tail -n "$kd" | sed 's/^/    /'
done
echo "end: unrecovered=$fail loops=$(loops) ustreamer_pid=$(cat /var/run/ustreamer.pid) usb_uvc_kmsgs_total_new=$(( $(kmsg) - k0 )) state=$(cat $SF 2>/dev/null)"
