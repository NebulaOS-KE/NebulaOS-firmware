#!/bin/sh
# GUI/service readiness acceptance (2026-10-09), READ ONLY: the [nebulaos]
# Moonraker component, network/hostname/mDNS, SFTP, the sudo adapter's
# refusals, PLR status, boot display and backlight state. Changes nothing:
# GET requests only, no helper write verb, no mount (S98 mounts debugfs at
# boot), the SFTP probe is one INIT/VERSION exchange with a local sftp-server
# process over a pipe, the sudo probe only exercises refusals.
U=http://127.0.0.1:7125
echo "uptime=$(cut -d' ' -f1 /proc/uptime)"
echo "== boot scripts (new/changed)"
grep -E 'S01(splash|wifi)|S05nebulaos-activate|S56moonraker|S58guppyscreen|S9[78]' /run/nebulaos-boot-scripts.log 2>/dev/null
grep -E 'EV=(begin|done)' /run/nebulaos-boot-scripts.log 2>/dev/null
echo "== component endpoints"
for e in info network/status boot_display/status display/status; do
	echo "-- /machine/nebulaos/$e"
	curl -s -m 25 -w '\nhttp=%{http_code} seconds=%{time_total}\n' "$U/machine/nebulaos/$e" | head -c 4000
done
echo "== moonraker components"
curl -s -m 5 "$U/server/info" | grep -oE '"(components|failed_components|warnings)": *\[[^]]*\]' | head -c 3000; echo
grep -nE 'nebulaos|zeroconf|Unable to load component' /opt/printer_data/logs/moonraker.log 2>/dev/null | tail -20 | cut -c1-240
echo "== composition"
ls -l /opt/moonraker/moonraker/components/nebulaos.py /usr/data/nebulaos/apps/moonraker/moonraker/components/nebulaos.py 2>&1
grep -n nebulaos /usr/data/nebulaos/apps/moonraker/.git/info/exclude 2>/dev/null
echo "moonraker_untracked=$(git -C /usr/data/nebulaos/apps/moonraker ls-files --others --exclude-standard 2>/dev/null | wc -l)"
grep -n 'include' /etc/nebulaos/moonraker/klipper-pin.conf
echo "== network"
echo "hostname=$(hostname) boot_state=$(cat /run/nebulaos/network/boot-state 2>/dev/null)"
cat /run/nebulaos/network/interfaces 2>/dev/null
ip -4 -o addr show dev wlan0; ip -4 route show default; cat /etc/resolv.conf
for d in /proc/[0-9]*; do c=$(tr '\0' ' ' < $d/cmdline 2>/dev/null); case "$c" in udhcpc*) echo "udhcpc: $c";; esac; done
ls -la /usr/data/nebulaos/network/ 2>/dev/null
echo "== mdns (python-zeroconf, from the device itself)"
python3 - "$(hostname)" <<'PY' 2>&1 | tail -6
import sys
try:
    import zeroconf
    zc = zeroconf.Zeroconf()
    try:
        print("service_types", sorted(zeroconf.ZeroconfServiceTypes.find(zc=zc, timeout=3)))
        name = sys.argv[1] + ".local."
        resolver = getattr(zeroconf, "AddressResolver", None)
        if resolver is not None:
            r = resolver(name)
            ok = r.request(zc, 3000)
            print("resolve", name, ok, r.parsed_addresses() if ok else [])
        else:
            print("resolve unsupported by this python-zeroconf")
    finally:
        zc.close()
except Exception as exc:
    print("mdns_probe_error", type(exc).__name__, exc)
PY
echo "== sftp"
ls -l /usr/libexec/sftp-server /usr/libexec/gesftpserver 2>&1
r=$(printf '\000\000\000\005\001\000\000\000\003' | /usr/libexec/sftp-server 2>/dev/null | head -c 9 | od -An -tx1 | tr -s ' ')
echo "sftp_init_reply=$r (expect ... 02 = SSH_FXP_VERSION)"
pidof dropbear >/dev/null && echo dropbear=running || echo dropbear=absent
echo "== sudo adapter refusals"
ls -l /usr/bin/sudo
for c in "ls /root" "systemctl --version"; do
	# shellcheck disable=SC2086
	/usr/bin/sudo $c > /dev/null 2>&1; echo "sudo $c -> rc=$?"
done
echo "== plr"
curl -s -m 5 "$U/printer/objects/query?nebulaos_power_loss_recovery" | head -c 2000; echo
grep -n 'nebulaos_power_loss_recovery' /opt/printer_data/logs/klippy.log 2>/dev/null | tail -8 | cut -c1-240
echo "== boot display"
ls -la /usr/data/nebulaos/boot /usr/data/nebulaos/boot/cache 2>/dev/null
cat /usr/data/nebulaos/boot/display.env /usr/data/nebulaos/boot/cache/splash.meta 2>/dev/null
F=/sys/class/graphics/fb0
echo "fb: virtual_size=$(cat $F/virtual_size) bpp=$(cat $F/bits_per_pixel) stride=$(cat $F/stride) pan=$(cat $F/pan) mode=$(cat $F/mode 2>/dev/null)"
for v in /sys/class/vtconsole/vtcon*; do echo "$v: $(cat $v/name) bind=$(cat $v/bind)"; done
echo "fbcon_rotate=$(cat /sys/class/graphics/fbcon/rotate 2>/dev/null)"
dmesg | grep -iE 'fbcon|Console: switching|frame buffer device' | tail -5
grep -aE 'nebulaos-boot-display' /var/log/messages 2>/dev/null | tail -6 | cut -c1-200
echo "== backlight"
grep -c ' /sys/kernel/debug debugfs ' /proc/mounts | sed 's/^/debugfs_mounts=/'
cat /sys/kernel/debug/nebulaos_backlight_final/status 2>/dev/null | grep -E '^(state|pwm_duty_pct|asleep|wake_target|safe_on_verified|op_failure_count|last_restore_reason):'
cat /usr/data/nebulaos/display/display.env 2>/dev/null
grep -aE 'nebulaos-backlight|sleep-wake-controller' /var/log/messages 2>/dev/null | tail -6 | cut -c1-200
p=$(cat /var/run/nebulaos-display-sleep-wake-controller.pid 2>/dev/null); echo "touch_wake_watcher=${p:-none}"
echo "== touch"
grep -E '^(mode|touch_down_count):' /sys/kernel/debug/ns2009_final_qualification/status 2>/dev/null
echo "== health"
curl -s -m 5 "$U/server/info" | grep -oE '"klippy_state": *"[a-z]*"'
dmesg | grep -cE 'BUG:|WARNING:|Oops' | sed 's/^/kernel_warnings=/'
grep -cE 'Timer too close|MCU .* shutdown|Lost communication' /opt/printer_data/logs/klippy.log 2>/dev/null | sed 's/^/klippy_faults=/'
