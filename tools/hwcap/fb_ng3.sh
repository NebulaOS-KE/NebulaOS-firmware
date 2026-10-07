#!/bin/sh
# Final blockers NG3 (2026-10-07): the guard -> Klippy serial handoff, as at
# boot. Each cycle: Klippy stopped, the MCU left running (it keeps streaming
# whatever the last session configured), the guard's own application identify
# (identify handshake only), then Klippy started at once - odd cycles alone,
# even cycles with two CPU hogs (boot-like contention). Per cycle: Klippy's own
# connect timeouts, time to ready, uart1 counters, stream rate while closed.
# Nothing but the identify handshake and Klippy's normal connect reaches the MCU.
L=/opt/printer_data/logs/klippy.log
uart() { awk '/^1: uart:/{for(i=1;i<=NF;i++){split($i,a,":"); if(a[1]=="rx"||a[1]=="fe"||a[1]=="oe") printf "%s=%s ", a[1], a[2]}}' /proc/tty/driver/* 2>/dev/null; }
ready() { wget -q -T 2 -O - http://127.0.0.1:7125/printer/info 2>/dev/null | sed -n 's/.*"state": *"\([a-z]*\)".*/\1/p'; }
H=
for c in 1 2 3 4 5 6 7 8 9 10; do
	/etc/init.d/S55klipper stop > /dev/null 2>&1
	i=0; while [ -n "$(python3 $T/lv_m1.py holders)" ] && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
	r0=$(awk '/^1: uart:/{for(i=1;i<=NF;i++){split($i,a,":"); if(a[1]=="rx") print a[2]}}' /proc/tty/driver/*); sleep 3
	r1=$(awk '/^1: uart:/{for(i=1;i<=NF;i++){split($i,a,":"); if(a[1]=="rx") print a[2]}}' /proc/tty/driver/*)
	sync; echo 3 > /proc/sys/vm/drop_caches
	g0=$(cut -d' ' -f1 /proc/uptime)
	gid=$(/usr/bin/python3 /etc/nebulaos/mcu_application_identify.py 2>&1 | tr '\n' ' ' | cut -c1-60)
	g1=$(cut -d' ' -f1 /proc/uptime)
	H=; if [ $((c % 2)) = 0 ]; then yes > /dev/null & H="$!"; yes > /dev/null & H="$H $!"; fi
	n0=$(wc -l < $L); t0=$(cut -d' ' -f1 /proc/uptime)
	/etc/init.d/S55klipper start > /dev/null 2>&1
	s=; k=0; while [ $k -lt 120 ]; do s=$(ready); [ "$s" = ready ] && break; sleep 1; k=$((k + 1)); done
	t1=$(cut -d' ' -f1 /proc/uptime); [ -n "$H" ] && kill $H 2>/dev/null; H=
	to=$(tail -n +$n0 $L | grep -c 'Timeout on connect')
	echo "NG3 cycle=$c hogs=$([ $((c % 2)) = 0 ] && echo 2 || echo 0) stream_rx_Bps=$(( (r1 - r0) / 3 )) guard_s=$(awk -v a=$g0 -v b=$g1 'BEGIN{printf "%.1f", b-a}') guard='$gid' klippy_ready_s=$(awk -v a=$t0 -v b=$t1 'BEGIN{printf "%.1f", b-a}') state=$s connect_timeouts=$to $(uart)"
	sleep 5
done
