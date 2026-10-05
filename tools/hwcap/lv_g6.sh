#!/bin/sh
# Live gap verification G6 (2026-10-05): udhcpc's first DHCP try at boot.
# Read-only evidence (udhcpc arguments, interfaces, boot-wait result, link
# state), then query-only DHCP exchanges on the associated link: a separate
# udhcpc with -q -n and a logging script that configures nothing (no -R, so
# no release). The running udhcpc, the address and the routes are untouched.
L=/run/nebulaos-live-verify; mkdir -p $L
echo "== udhcpc"; ps | grep '[u]dhcpc'
echo "== interfaces"; grep -v '^#' /etc/network/interfaces | grep -v '^$'
echo "== boot wait result"; cat /run/nebulaos-wifi-boot-wait.result 2>&1
echo "== link"; wpa_cli -i wlan0 status 2>/dev/null | grep -E '^(wpa_state|key_mgmt|pairwise_cipher|freq|ip_address)='
ip -4 -o addr show wlan0; ip route | head -3
echo "lease_script=$(ls -l /usr/share/udhcpc/default.script 2>&1)"
grep -nE 'deconfig|renew|bound|route|flush' /usr/share/udhcpc/default.script 2>/dev/null | head -12
echo "== kernel link events this boot"; dmesg | grep -iE 'wlan0|brcmf.*(connect|link|assoc)|IPv6: ADDRCONF' | head -8
cat > $L/g6script <<'G6_SCRIPT'
#!/bin/sh
read u _ < /proc/uptime
echo "SCRIPT $1 t=$u ip=$ip server=$serverid lease=$lease" >> /run/nebulaos-live-verify/g6.log
G6_SCRIPT
chmod 755 $L/g6script
q() { # label udhcpc-args
	l=$1; shift; rm -f $L/g6.log; t0=$(cut -d' ' -f1 /proc/uptime)
	udhcpc -i wlan0 -f -q -n -s $L/g6script "$@" > $L/g6.err 2>&1; rc=$?
	t1=$(cut -d' ' -f1 /proc/uptime)
	echo "DHCPQ $l rc=$rc seconds=$(awk -v a=$t0 -v b=$t1 'BEGIN{printf "%.2f", b-a}') discovers=$(grep -c 'sending discover' $L/g6.err) selects=$(grep -c 'sending select' $L/g6.err)"
	sed 's/^/  /' $L/g6.log $L/g6.err | head -8
}
for i in 1 2 3; do q "retry-1s-$i" -t 6 -T 1 -A 1; sleep 2; done
q boot-args-without-b -t 1 -T 3 -A 3
echo "after: $(ip -4 -o addr show wlan0 | awk '{print $4}') route=$(ip route | grep -c default) udhcpc_main=$(ps | grep -c '[u]dhcpc -t1')"
rm -f $L/g6script $L/g6.log $L/g6.err
