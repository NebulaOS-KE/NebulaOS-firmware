#!/bin/sh
# Wi-Fi diagnosis (Q3 API, 2026-10-11), READ ONLY: NebulaOS's view of
# wpa_supplicant (GET wifi/status), the saved networks with every key
# redacted, the network apply state, and the log lines around wlan0, DHCP and
# the machine.nebulaos.wifi.* requests. Changes nothing.
U=http://127.0.0.1:7125
echo "uptime=$(cut -d' ' -f1 /proc/uptime) now=$(date -u +%H:%M:%S)"
echo "== wifi/status"
curl -s -m 25 "$U/machine/nebulaos/wifi/status" | head -c 3000; echo
echo "== saved networks (keys redacted)"
sed -E 's/^([[:space:]]*(psk|password|wep_key[0-9]|sae_password)=).*/\1<redacted>/' \
	/usr/data/nebulaos/network/wpa_supplicant.conf 2>/dev/null
echo "== network state"
echo "boot_state=$(cat /run/nebulaos/network/boot-state 2>/dev/null)"
ip -4 -o addr show dev wlan0; ip -4 route show default
ls -la /usr/data/nebulaos/network/ 2>/dev/null
echo "== moonraker wifi requests"
grep -E 'nebulaos/wifi|wifi\.(connect|scan|forget)' /opt/printer_data/logs/moonraker.log 2>/dev/null | tail -20 | cut -c1-220
echo "== system log (wlan0, dhcp, netapply)"
grep -aE 'wlan0|udhcpc|netapply|nebulaos-network|nnet|wpa' /var/log/messages 2>/dev/null | tail -40 | cut -c1-220
echo "== kernel (wifi)"
dmesg | grep -iE 'wlan0|brcmf|ieee80211|cfg80211|link (is )?(up|down)' | tail -25 | cut -c1-200
echo "== processes"
for d in /proc/[0-9]*; do c=$(tr '\0' ' ' < $d/cmdline 2>/dev/null); case "$c" in *wpa_supplicant*|udhcpc*) echo "$c";; esac; done
