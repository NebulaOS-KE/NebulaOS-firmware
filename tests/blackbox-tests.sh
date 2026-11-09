#!/bin/sh
#
# Run 24 black box: /usr/libexec/nebulaos-blackbox (why the last boot ended,
# kept evidence, notice, heartbeat line) and S03nebulaos-blackbox. Fake
# pstore, watchdog parameters, /proc and log folders under a temp dir.
#
# Usage: sh tests/blackbox-tests.sh

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OV="$REPO_ROOT/scripts/build/overlay"
BB="$OV/usr/libexec/nebulaos-blackbox"
INIT="$OV/etc/init.d/S03nebulaos-blackbox"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/blackbox-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM
PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: got '$2', want '$3'"; fi; }

[ -x "$BB" ] && pass "nebulaos-blackbox is executable" || fail "nebulaos-blackbox not executable"
[ -x "$INIT" ] && pass "S03nebulaos-blackbox is executable" || fail "S03nebulaos-blackbox not executable"
sh -n "$BB" && pass "nebulaos-blackbox parses" || fail "nebulaos-blackbox does not parse"
sh -n "$INIT" && pass "S03nebulaos-blackbox parses" || fail "S03nebulaos-blackbox does not parse"

# --- reason <console> <dump> <rsr> -------------------------------------------
C="$WORK/console"
printf '[ 100.0] normal line\n[ 101.0] reboot: Restarting system\n' > "$C.restart"
printf '[ 100.0] normal line\n[ 101.0] reboot: Power down\n' > "$C.off"
printf '[ 100.0] normal line\n[ 4147.0] still printing\n' > "$C.freeze"
M="$WORK/pmsg"
printf 'hb 2026-11-06T13:46:30Z up=4136\nhb 2026-11-06T13:46:40Z up=4146\n' > "$M.hb"
printf 'hb 2026-11-06T13:46:30Z up=4136\nshutdown clean 2026-11-06T13:46:41Z up=4147\n' > "$M.clean"
printf 'shutdown clean 2026-11-06T13:40:00Z up=10\nhb 2026-11-06T13:46:40Z up=4146\n' > "$M.later"
check "a panic dump is a CRASH, whatever else" "$(sh "$BB" reason "$C.freeze" 1 2 13621 "$M.clean")" CRASH
check "heartbeat log ending in 'shutdown clean' is a RESTART (rcK)" "$(sh "$BB" reason "$C.freeze" 0 2 0 "$M.clean")" RESTART
check "the reboot signature 0x3535 is a RESTART (also reboot -f; printk lost)" "$(sh "$BB" reason "$C.freeze" 0 2 13621 "$M.hb")" RESTART
check "a 'shutdown clean' followed by heartbeats is not a restart" "$(sh "$BB" reason "$C.freeze" 0 2 0 "$M.later")" FREEZE
check "kernel log ending in 'Restarting system' is a RESTART (secondary)" "$(sh "$BB" reason "$C.restart" 0 2 0 "")" RESTART
check "kernel log ending in 'Power down' is POWER_OFF" "$(sh "$BB" reason "$C.off" 0 4 0 "")" POWER_OFF
check "kernel log that just stops + watchdog reset + no signature is a FREEZE" "$(sh "$BB" reason "$C.freeze" 0 2 0 "$M.hb")" FREEZE
check "no reset status from the kernel (old image) is UNKNOWN, not FREEZE" "$(sh "$BB" reason "$C.freeze" 0 "" "" "")" UNKNOWN
check "kernel log that just stops + reset pin is UNKNOWN" "$(sh "$BB" reason "$C.freeze" 0 1 0 "")" UNKNOWN
check "no pstore + power-on reset is POWER_ON" "$(sh "$BB" reason "" 0 4 0 "")" POWER_ON
check "no pstore + RSR_PR (0x1, switched on) is POWER_ON" "$(sh "$BB" reason "" 0 1 0 "")" POWER_ON
check "no pstore + RSR_PR|WR (0x3) is UNKNOWN, not POWER_ON" "$(sh "$BB" reason "" 0 3 0 "")" UNKNOWN
check "no pstore + no reset status is UNKNOWN" "$(sh "$BB" reason "" 0 "" "" "")" UNKNOWN
check "no pstore + watchdog reset is UNKNOWN (RAM lost)" "$(sh "$BB" reason "" 0 2 0 "")" UNKNOWN

# --- collect -------------------------------------------------------------------
setup() {
	rm -rf "$WORK/ps" "$WORK/wdt" "$WORK/root" "$WORK/run" "$WORK/proc"
	mkdir -p "$WORK/ps" "$WORK/wdt" "$WORK/root" "$WORK/run" "$WORK/proc"
	echo "123.45 100.00" > "$WORK/proc/uptime"
	echo "$1" > "$WORK/wdt/nebulaos_reset_rsr"
	echo "0" > "$WORK/wdt/nebulaos_reset_cppsr"
}
collect() {
	NEBULAOS_PSTORE_ERASE=1 NEBULAOS_PSTORE_DIR="$WORK/ps" NEBULAOS_WDT_PARAMS="$WORK/wdt" NEBULAOS_ROOT="$WORK/root" \
		NEBULAOS_BLACKBOX_RUN_DIR="$WORK/run" NEBULAOS_PROC="$WORK/proc" sh "$BB" collect >/dev/null 2>&1
}
L="$WORK/root/logs"
N="$WORK/root/system/notices/printer-restarted.txt"

setup 2
cp "$C.freeze" "$WORK/ps/console-ramoops-0"
printf 'hb 2026-11-06T13:46:30Z up=4136 load=2.1 2.0 1.9 run=2 memavail=130000 top=klippy/2063/o0:31%%\nhb 2026-11-06T13:46:40Z up=4146 load=2.1 2.0 1.9 run=2 memavail=130000 top=klippy/2063/o0:30%%\n' > "$WORK/ps/pmsg-ramoops-0"
collect
grep -q '^REASON=FREEZE$' "$WORK/run/last-reset" && pass "freeze: REASON=FREEZE in last-reset" || fail "freeze: $(cat "$WORK/run/last-reset" 2>&1)"
grep -q '^RESET_STATUS=0x00000002$' "$WORK/run/last-reset" && pass "freeze: reset status written as hex" || fail "freeze: no RESET_STATUS"
grep -q '^LAST_HEARTBEAT=hb 2026-11-06T13:46:40Z' "$WORK/run/last-reset" && pass "freeze: the last heartbeat is named" || fail "freeze: LAST_HEARTBEAT missing"
grep -q 'boot after FREEZE reset_status=0x00000002 last_heartbeat=2026-11-06T13:46:40Z' "$L/reset-history.log" \
	&& pass "freeze: reset-history line with the last heartbeat" || fail "freeze history: $(cat "$L/reset-history.log" 2>&1)"
[ "$(ls "$L/crash" | grep -c -- '-FREEZE-')" = 2 ] && pass "freeze: kernel log and heartbeat kept in logs/crash" || fail "freeze crash dir: $(ls "$L/crash" 2>&1)"
cmp -s "$C.freeze" "$L/previous-boot-kernel.log" && pass "freeze: previous-boot-kernel.log written" || fail "previous-boot-kernel.log"
grep -q '^hb 2026-11-06T13:46:40Z' "$L/previous-boot-heartbeat.log" 2>/dev/null && pass "previous-boot-heartbeat.log written" || fail "previous-boot-heartbeat.log missing"
[ -s "$N" ] && grep -q 'Report a problem' "$N" && pass "freeze: notice for the screen" || fail "freeze: no notice"
[ -e "$WORK/ps/console-ramoops-0" ] && pass "freeze: the console record is not erased (that would wipe this boot's log)" || fail "freeze: console record erased"
[ ! -e "$WORK/ps/pmsg-ramoops-0" ] && pass "freeze: the old heartbeat log is erased after reading" || fail "freeze: pmsg not erased"

setup 2
rm -f "$N"
cp "$C.restart" "$WORK/ps/console-ramoops-0"
collect
grep -q '^REASON=RESTART$' "$WORK/run/last-reset" && pass "restart: REASON=RESTART" || fail "restart: $(cat "$WORK/run/last-reset" 2>&1)"
[ ! -e "$N" ] && pass "restart: no notice" || fail "restart: notice written"
[ "$(ls "$L/crash" | grep -c -- '-RESTART-')" = 0 ] && pass "restart: nothing kept as a crash" || fail "restart kept a crash"
cmp -s "$C.restart" "$L/previous-boot-kernel.log" && pass "restart: previous-boot-kernel.log replaced" || fail "restart previous-boot"

setup 4
collect
grep -q '^REASON=POWER_ON$' "$WORK/run/last-reset" && pass "power on: REASON=POWER_ON" || fail "power on: $(cat "$WORK/run/last-reset" 2>&1)"
[ ! -e "$L/previous-boot-kernel.log" ] && pass "power on: no stale previous-boot-kernel.log" || fail "stale previous-boot log kept"
grep -q '^PSTORE_CONSOLE=no$' "$WORK/run/last-reset" && pass "power on: PSTORE_CONSOLE=no" || fail "power on pstore flag"

setup 2
cp "$C.freeze" "$WORK/ps/console-ramoops-0"
printf 'Panic#1 Part1\nKernel panic - not syncing: softlockup: hung tasks\n' > "$WORK/ps/dmesg-ramoops-0"
collect
grep -q '^REASON=CRASH$' "$WORK/run/last-reset" && pass "crash: REASON=CRASH" || fail "crash: $(cat "$WORK/run/last-reset" 2>&1)"
ls "$L/crash" | grep -q -- '-CRASH-dmesg-ramoops-0.txt$' && pass "crash: the panic dump is kept" || fail "crash dump not kept"

# 1.0.2: a panic from the watchdog pre-timeout handler is a FREEZE whose
# state was dumped - kept, and named FREEZE, not CRASH.
setup 2
cp "$C.freeze" "$WORK/ps/console-ramoops-0"
printf 'Panic#1 Part1\nnebulaos-freeze: watchdog not fed for 40 s (cpu0, jiffies 1)\nKernel panic - not syncing: nebulaos-freeze: watchdog pre-timeout\n' > "$WORK/ps/dmesg-ramoops-0"
collect
grep -q '^REASON=FREEZE$' "$WORK/run/last-reset" && pass "caught freeze: REASON=FREEZE" || fail "caught freeze: $(cat "$WORK/run/last-reset" 2>&1)"
ls "$L/crash" | grep -q -- '-FREEZE-dmesg-ramoops-0.txt$' && pass "caught freeze: the state dump is kept" || fail "caught freeze dump not kept"
grep -q '^PSTORE_DUMP=freeze$' "$WORK/run/last-reset" && pass "caught freeze: PSTORE_DUMP=freeze in last-reset" || fail "caught freeze PSTORE_DUMP: $(grep PSTORE_DUMP "$WORK/run/last-reset")"
check "a pre-timeout dump is a FREEZE, whatever else" "$(sh "$BB" reason "$C.freeze" 2 2 13621 "$M.clean")" FREEZE

# collect runs once per boot: a second run keeps this boot's verdict.
setup 2
cp "$C.freeze" "$WORK/ps/console-ramoops-0"
collect
rm -f "$WORK/ps/console-ramoops-0"
h=$(wc -l < "$L/reset-history.log")
collect
grep -q '^REASON=FREEZE$' "$WORK/run/last-reset" && pass "second collect keeps the verdict" || fail "second collect changed it: $(cat "$WORK/run/last-reset")"
check "second collect adds no history line" "$(wc -l < "$L/reset-history.log")" "$h"
[ -s "$L/previous-boot-kernel.log" ] && pass "second collect keeps previous-boot-kernel.log" || fail "second collect removed previous-boot-kernel.log"
awk '/^\trestart\)/' "$INIT" | grep -q 'collect\|shutdown' && fail "restart re-runs collect or marks a shutdown" || pass "restart touches only the heartbeat"

# Only the newest 5 crashes are kept (one crash = several files, one stamp).
setup 2
mkdir -p "$L/crash"
for i in 1 2 3 4 5 6 7; do
	: > "$L/crash/2026110${i}T000000Z-FREEZE-console-ramoops-0.txt"
	: > "$L/crash/2026110${i}T000000Z-FREEZE-pmsg-ramoops-0.txt"
done
cp "$C.freeze" "$WORK/ps/console-ramoops-0"
collect
n=$(ls "$L/crash" | sed 's/-FREEZE-.*//' | sort -u | wc -l)
check "only the newest 5 crashes are kept" "$n" 5
ls "$L/crash" | grep -q '^20261101T' && fail "the oldest crash was not removed" || pass "the oldest crashes go first"

# History is bounded.
setup 4
mkdir -p "$L"
for i in $(seq 1 150); do echo "old $i"; done > "$L/reset-history.log"
collect
check "reset-history keeps 100 lines" "$(wc -l < "$L/reset-history.log")" 100

# --- heartbeat line --------------------------------------------------------------
P="$WORK/fproc"; rm -rf "$P"; mkdir -p "$P/1" "$P/2063" "$P/2056"
stat_line() { # pid comm utime stime rtprio policy - proc(5) fields 1..44
	f="S 0 0 0 0 -1 0 0 0 0 0 $3 $4 0 0 20 0 1"          # fields 3..20
	i=21; while [ $i -le 39 ]; do f="$f 0"; i=$((i + 1)); done   # 21..39
	echo "$1 ($2) $f $5 $6 0 0 0"                          # 40 rt_priority, 41 policy
}
stat_line 1 init 10 10 0 0 > "$P/1/stat"
stat_line 2063 "python3 klippy" 1000 200 0 0 > "$P/2063/stat"
stat_line 2056 klipper_mcu 500 100 49 1 > "$P/2056/stat"
NEBULAOS_PROC="$P" sh "$BB" heartbeat-line /nonexistent "$WORK/hb.prev" 10 >/dev/null
stat_line 2063 "python3 klippy" 1200 250 0 0 > "$P/2063/stat"
stat_line 2056 klipper_mcu 1400 100 49 1 > "$P/2056/stat"
out=$(NEBULAOS_PROC="$P" sh "$BB" heartbeat-line "$WORK/hb.prev" "$WORK/hb.next" 10)
check "heartbeat names the busiest first, with policy and RT priority" "$out" "klipper_mcu/2056/f49:90%,python3 klippy/2063/o0:25% blocked=0"
mkdir -p "$P/3"; stat_line 3 gone 1 1 0 0 > "$P/3/stat"; chmod 000 "$P/3/stat"
NEBULAOS_PROC="$P" sh "$BB" heartbeat-line /nonexistent "$WORK/hb.p2" 10 >/dev/null
stat_line 2056 klipper_mcu 1500 100 49 1 > "$P/2056/stat"
out=$(NEBULAOS_PROC="$P" sh "$BB" heartbeat-line "$WORK/hb.p2" "$WORK/hb.n2" 10)
chmod 644 "$P/3/stat"
case "$out" in klipper_mcu/2056/*) pass "an unreadable/vanished process does not empty the heartbeat line" ;; *) fail "unreadable stat broke the line: '$out'" ;; esac
grep -q '^2056 1500$' "$WORK/hb.next" && pass "heartbeat keeps the new sample" || fail "heartbeat sample: $(cat "$WORK/hb.next" 2>&1)"

# Blocked (D state) tasks are counted and named.
mkdir -p "$P/77"; echo "77 (dropbear) D 1 1 1 0 -1 0 0 0 0 0 5 5 0 0 20 0 1 $(printf '0 %.0s' $(seq 21 39)) 0 0 0 0 0" > "$P/77/stat"
out=$(NEBULAOS_PROC="$P" sh "$BB" heartbeat-line /nonexistent "$WORK/hb.p3" 10)
case "$out" in *" blocked=1:dropbear/77") pass "heartbeat names a task blocked in D state" ;; *) fail "blocked: '$out'" ;; esac
rm -rf "$P/77"
grep -q 'previous-boot-heartbeat.log' "$BB" && pass "the previous heartbeat is always kept" || fail "previous heartbeat not kept"

# --- init script ------------------------------------------------------------------
grep -q 'chrt' "$INIT" && fail "heartbeat uses a real-time priority" || pass "heartbeat is not real-time (never above klipper_mcu/IRQ threads)"
grep -q -- '-N 19 ' "$INIT" && pass "heartbeat at nice 19, never above Klipper" || fail "heartbeat nice"
grep -q 'sleep "$INTERVAL" || exit 1' "$BB" && pass "a failing sleep ends the heartbeat instead of spinning" || fail "heartbeat can spin"
NEBULAOS_PMSG="$WORK/pm" NEBULAOS_PROC="$WORK/proc" sh "$BB" shutdown
grep -q '^shutdown clean .* up=123.45$' "$WORK/pm" && pass "shutdown writes 'shutdown clean' into pmsg" || fail "shutdown mark: $(cat "$WORK/pm" 2>&1)"
grep -q '"$BB" shutdown' "$INIT" && pass "stop (rcK) writes the shutdown mark" || fail "stop does not mark"
grep -q '/dev/pmsg0' "$INIT" && pass "heartbeat only starts when /dev/pmsg0 exists" || fail "pmsg guard"

# --- wifi= in the heartbeat ---------------------------------------------------
WP="$WORK/wproc"; mkdir -p "$WP/net"
printf 'Inter-| sta-|   Quality        |   Discarded packets               | Missed | WE\n face | tus | link level noise |  nwid  crypt   frag  retry   misc | beacon | 22\n wlan0: 0000   70.  -30.  -256        0      0      0      0      0        3\n' > "$WP/net/wireless"
check "wifi state: signal and missed beacons" "$(NEBULAOS_PROC="$WP" sh "$BB" wifi-state)" "-30/b3"
printf 'Inter-| sta-|   Quality\n face | tus | link level noise\n' > "$WP/net/wireless"
check "wifi state: no associated interface is none" "$(NEBULAOS_PROC="$WP" sh "$BB" wifi-state)" "none"
rm -f "$WP/net/wireless"
check "wifi state: no /proc/net/wireless is none" "$(NEBULAOS_PROC="$WP" sh "$BB" wifi-state)" "none"
grep -q 'memavail=$mem wifi=$wifi top=' "$BB" && pass "heartbeat line carries wifi=" || fail "heartbeat line without wifi="

echo
echo "blackbox-tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
