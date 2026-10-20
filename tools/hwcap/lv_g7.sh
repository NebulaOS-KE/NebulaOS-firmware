#!/bin/sh
# Live gap verification G7 (2026-10-05): Klippy start -> ready time alone vs
# in the boot burst. Klippy is restarted (service restart only) warm, with the
# page cache dropped, and with the page cache dropped while Moonraker and
# GuppyScreen restart at the same moment (as at boot). Ready is read from
# Klippy's own API socket (a new pid answering state=ready), so a Moonraker
# restart does not disturb the measurement. Seeders are not re-run.
L=/run/nebulaos-live-verify; mkdir -p $L
cat > $L/g7poll.py <<'G7_PY'
import json, os, socket, sys, time
sock, oldpid, t0, limit = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
def up():
    return float(open("/proc/uptime").read().split()[0])
st, first_new = "down", None
while up() - t0 < limit:
    try:
        pid = open("/var/run/klippy.pid").read().strip()
    except OSError:
        pid = ""
    if pid and pid != oldpid:
        first_new = first_new or up()
        try:
            s = socket.socket(socket.AF_UNIX); s.settimeout(1); s.connect(sock)
            s.sendall(json.dumps({"id": 1, "method": "info", "params": {}}).encode() + b"\x03")
            buf = b""
            while not buf.endswith(b"\x03"):
                d = s.recv(4096)
                if not d:
                    break
                buf += d
            s.close()
            st = json.loads(buf.rstrip(b"\x03"))["result"]["state"]
            if st == "ready":
                break
        except Exception:
            st = "noapi"
    time.sleep(0.2)
pid = open("/var/run/klippy.pid").read().strip()
cpu = sum(int(x) for x in open("/proc/%s/stat" % pid).read().rsplit(")", 1)[1].split()[11:13]) / os.sysconf("SC_CLK_TCK")
print("ready_s=%.1f state=%s new_pid_after_s=%.1f klippy_cpu_s=%.1f" % (up() - t0, st, (first_new or up()) - t0, cpu))
G7_PY
KP=$(cat /var/run/klippy.pid); SOCK=$(tr '\0' '\n' < /proc/$KP/cmdline | sed -n '/^-a$/{n;p}')
echo "klippy_socket=$SOCK"
one() { # label burst(0/1) cold(0/1)
	[ $3 = 1 ] && { sync; echo 3 > /proc/sys/vm/drop_caches; }
	old=$(cat /var/run/klippy.pid); l0=$(cut -d' ' -f1 /proc/loadavg); t0=$(cut -d' ' -f1 /proc/uptime)
	/etc/init.d/S55klipper restart > /dev/null 2>&1 &
	if [ $2 = 1 ]; then /etc/init.d/S56moonraker restart > /dev/null 2>&1 & for s in /etc/init.d/S58nebulascreen /etc/init.d/S58guppyscreen; do [ -x "$s" ] && "$s" restart > /dev/null 2>&1 & done; fi
	r=$(python3 $L/g7poll.py "$SOCK" "$old" $t0 120); wait
	echo "G7 $1 $r load_before=$l0 load_after=$(cut -d' ' -f1 /proc/loadavg) cpu_psi=$(sed -n 's/^some avg10=\([0-9.]*\).*/\1/p' /proc/pressure/cpu)"
	i=0; until wget -q -T 3 -O - http://127.0.0.1:7125/server/info 2>/dev/null | grep -q '"klippy_state": *"ready"' || [ $i -ge 90 ]; do sleep 2; i=$((i + 2)); done
	sleep 20
}
for k in 1 2; do one warm-alone 0 0; one cold-alone 0 1; one cold-burst 1 1; done
echo "== klippy.log phases of the last start"
grep -nE 'Start printer at|Loaded MCU|Configured MCU|Starting Klippy' /opt/printer_data/logs/klippy.log | tail -6 | cut -c1-160
rm -f $L/g7poll.py
