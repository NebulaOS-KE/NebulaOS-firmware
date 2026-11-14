#!/bin/sh
# Freeze provocation (2026-11-14): every bus master and interrupt source a
# print keeps busy, pushed far harder, on an IDLE printer - no motion, no
# heater, no MCU write except read-only queries. Args: seconds, loads
# (comma list of cpu,emmc,wifi,cam,klipper or "all"). Each minute a status
# line, and the minute number as a MARK in /proc/nebulaos_flightrec.
S=${1:-21600}; L=${2:-all}; T=${T:-/tmp}; F=/usr/data/.nebulaos-provoke
GW=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
P=
on() { case ",$L," in *,all,*|*,$1,*) return 0 ;; esac; return 1; }
stop() { trap - EXIT INT TERM HUP; for p in $P; do pkill -P $p 2>/dev/null; kill $p 2>/dev/null; done; rm -f $F; }
trap stop EXIT; trap 'exit 130' INT TERM HUP
echo "provoke: seconds=$S loads=$L gateway=$GW boot_id=$(cat /proc/sys/kernel/random/boot_id)"
if on cpu; then for c in 0 1; do
	taskset -c $c nice -n 10 python3 -c 'while 1: pass' & P="$P $!"
	taskset -c $c python3 -c 'import time
while 1: time.sleep(0.0005)' & P="$P $!"
done; fi
if on emmc; then ( while :; do head -c 4194304 /dev/urandom > $F; sync; cat $F > /dev/null
	echo 1 > /proc/sys/vm/drop_caches; done ) 2>/dev/null & P="$P $!"; fi
if on wifi && [ -n "$GW" ]; then for i in 1 2 3 4; do
	ping -q -s 1400 -i 0.01 -w $S $GW > $T/ping$i.txt 2>&1 & P="$P $!"; done; fi
if on cam && [ -x /etc/init.d/S50webcam ]; then ( while :; do
	curl -s --max-time 290 -o /dev/null http://127.0.0.1:8080/stream
	/etc/init.d/S50webcam stop >/dev/null 2>&1; sleep 3; /etc/init.d/S50webcam start >/dev/null 2>&1; sleep 5
	done ) & P="$P $!"; fi
if on klipper; then python3 - > $T/kl.txt 2>&1 <<'PYEOF' &
import json, socket, threading, time
K = "/opt/printer_data/comms/klippy.sock"
n = {"accel_msgs": 0, "tmc_ok": 0, "tmc_err": 0, "err": ""}
def conn():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(K); return s
def accel():
    while True:
        try:
            s = conn()
            s.sendall(json.dumps({"id": 1, "method": "adxl345/dump_adxl345",
                                  "params": {"sensor": "adxl345", "response_template": {}}}).encode() + b"\x03")
            while True:
                d = s.recv(65536)
                if not d: break
                n["accel_msgs"] += d.count(b"\x03")
        except Exception as e:
            n["err"] = "accel: %s" % e
        time.sleep(5)
def tmc():
    i = 0
    while True:
        try:
            s = conn(); s.settimeout(10); buf = b""
            while True:
                i += 1
                st = ("stepper_x", "stepper_y", "stepper_z")[i % 3]
                s.sendall(json.dumps({"id": i, "method": "gcode/script",
                                      "params": {"script": "DUMP_TMC STEPPER=" + st}}).encode() + b"\x03")
                while b"\x03" not in buf:
                    d = s.recv(65536)
                    if not d: raise OSError("closed")
                    buf += d
                m, buf = buf.split(b"\x03", 1)
                n["tmc_ok" if b'"result"' in m else "tmc_err"] += 1
                time.sleep(0.05)
        except Exception as e:
            n["err"] = "tmc: %s" % e
        time.sleep(5)
threading.Thread(target=accel, daemon=True).start()
threading.Thread(target=tmc, daemon=True).start()
while True:
    time.sleep(60); print(json.dumps(n), flush=True)
PYEOF
P="$P $!"; fi
echo "loads started:$P"
m=0; end=$(($(cut -d. -f1 /proc/uptime) + S))
while r=$((end - $(cut -d. -f1 /proc/uptime))); [ $r -gt 0 ]; do
	[ $r -gt 60 ] && r=60; sleep $r; m=$((m + 1)); { echo $m > /proc/nebulaos_flightrec; } 2>/dev/null
	echo "== m=$m up=$(cut -d' ' -f1 /proc/uptime) load=$(cut -d' ' -f1-3 /proc/loadavg) memavail=$(awk '/MemAvailable/{print $2}' /proc/meminfo) $(tail -n 1 $T/kl.txt 2>/dev/null)"
	grep -E 'tcu|ost|otg|mmc|uart|i2c|dpu|spi|IPI' /proc/interrupts | awk '{s=$1; for(i=2;i<=3;i++) s=s" "$i; print s, $NF}' | tr '\n' ';'; echo
	for f in /proc/[0-9]*/stat; do [ "$(cut -d' ' -f3 $f 2>/dev/null)" = D ] && echo "D: $(cut -d' ' -f1-2 $f)"; done
	dmesg | tail -n 8 | grep -iE 'error|timeout|fail|brcmf|dwc2|mmc|uvc|spi' | cut -c1-200
done
cat $T/ping*.txt 2>/dev/null | grep -E 'transmitted|round-trip'
echo PROVOKE_RESULT=SURVIVED
