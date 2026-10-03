#!/bin/sh
#
# Offline tests for /usr/libexec/nebulaos-memguard (MEM-T12..T14).
# The daemon is sourced through NEBULAOS_MEMGUARD_NO_AUTORUN with every path
# (MG_PROC, MG_SYS, MG_RUN, MG_PIDDIR, MG_LOCKS, MG_LOG) pointed at fixtures,
# and the Moonraker query (mg_http) and service actions stubbed.
#
# Usage: sh tests/nebulaos-memguard-tests.sh

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MG="$REPO_ROOT/scripts/build/overlay/usr/libexec/nebulaos-memguard"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/memguard-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
expect() { [ "$2" = "$3" ] && pass "$1" || fail "$1 (got '$2', want '$3')"; }

sh -n "$MG" && pass "memguard parses" || fail "memguard does not parse"

export MG_PROC="$WORK/proc" MG_SYS="$WORK/sys" MG_RUN="$WORK/run" MG_PIDDIR="$WORK/varrun" \
	MG_LOCKS="$WORK/locks" MG_LOG="$WORK/log/memguard.log" \
	NEBULAOS_OOM_POLICY="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-oom-policy.sh"
mkdir -p "$MG_PROC" "$MG_SYS/block/zram0" "$MG_RUN/memguard" "$MG_RUN/shed" "$MG_PIDDIR" "$MG_LOCKS"

meminfo() { printf 'MemTotal:       245000 kB\nMemFree:         10000 kB\nMemAvailable:   %s kB\n' "$1" > "$MG_PROC/meminfo"; }
uptime() { echo "$1.00 1.00" > "$MG_PROC/uptime"; }
mmstat() { echo "100 50 $1 $2 0 0 0 0" > "$MG_SYS/block/zram0/mm_stat"; }
fakeproc() { # pid comm adj [rss_kb]
	mkdir -p "$MG_PROC/$1"
	echo "$2" > "$MG_PROC/$1/comm"
	echo "$3" > "$MG_PROC/$1/oom_score_adj"
	printf 'Name:\t%s\nVmRSS:\t%s kB\n' "$2" "${4:-1000}" > "$MG_PROC/$1/status"
}
meminfo 150000; uptime 100; mmstat 0 50000000

NEBULAOS_MEMGUARD_NO_AUTORUN=1
# shellcheck disable=SC1090
. "$MG"
HTTP_REPLY=""
mg_http() { [ -n "$HTTP_REPLY" ] && { printf '%s' "$HTTP_REPLY"; return 0; }; return 1; }

# --- (a) print state is sticky across a failed Moonraker query --------------
PRINT=0
HTTP_REPLY='{"result":{"status":{"print_stats":{"state":"printing"}}}}'
mg_poll_print_state; expect "printing -> PRINT=1" "$PRINT" 1
HTTP_REPLY=""
mg_poll_print_state; expect "failed query keeps PRINT=1 (sticky)" "$PRINT" 1
HTTP_REPLY='{"result": {"status": {"print_stats": {"state": "paused"}}}}'
mg_poll_print_state; expect "paused (spaced JSON) -> PRINT=1" "$PRINT" 1
HTTP_REPLY='{"result":{"status":{"print_stats":{"state":"standby"}}}}'
mg_poll_print_state; expect "successful standby clears PRINT" "$PRINT" 0
HTTP_REPLY=""
mg_poll_print_state; expect "failed query keeps PRINT=0" "$PRINT" 0

# maintenance: a lock file, or Moonraker busy while not printing
mg_poll_maint_state; expect "no lock, no answer -> MAINT=0" "$MAINT" 0
: > "$MG_LOCKS/klipper.lock"
mg_poll_maint_state; expect "update lock -> MAINT=1" "$MAINT" 1
rm -f "$MG_LOCKS/klipper.lock"
HTTP_REPLY='{"result":{"busy":true,"version_info":{}}}'
mg_poll_maint_state; expect "update_manager busy -> MAINT=1" "$MAINT" 1
PRINT=1
mg_poll_maint_state; expect "busy is not queried while printing" "$MAINT" 0
PRINT=0; HTTP_REPLY=""

# markers
STATE=NORMAL PRINT=1 MAINT=0
mg_publish
[ -e "$MG_RUN/print-active" ] && pass "print-active marker written" || fail "print-active marker missing"
[ ! -e "$MG_RUN/maintenance-active" ] && pass "no maintenance marker" || fail "maintenance marker present"
expect "state file" "$(cat "$MG_RUN/memguard/state")" NORMAL
PRINT=0; mg_publish
[ ! -e "$MG_RUN/print-active" ] && pass "print-active removed" || fail "print-active not removed"

# --- (b) adj enforcement ------------------------------------------------------
fakeproc 100 python3 -700;      echo 100 > "$MG_PIDDIR/klippy.pid"
fakeproc 101 klipper_mcu 0;     echo 101 > "$MG_PIDDIR/klipper_mcu.pid"
fakeproc 102 python3 -400;      echo 102 > "$MG_PIDDIR/moonraker.pid"
fakeproc 200 python3 -400       # a Moonraker subprocess that inherited -400
fakeproc 201 nginx 0            # nginx worker
fakeproc 202 dropbear 0
fakeproc 203 udevd -1000        # udevd keeps its own value
fakeproc 204 sh 0               # untouched
fakeproc 205 ustreamer 300;     echo 999 > "$MG_PIDDIR/ustreamer.pid"   # stale pidfile
mg_enforce_adj
expect "klippy re-asserted to -900" "$(cat "$MG_PROC/100/oom_score_adj")" -900
expect "klipper_mcu re-asserted to -1000" "$(cat "$MG_PROC/101/oom_score_adj")" -1000
expect "moonraker keeps -400" "$(cat "$MG_PROC/102/oom_score_adj")" -400
expect "unlisted negative adj reset to 500" "$(cat "$MG_PROC/200/oom_score_adj")" 500
expect "nginx by comm -> -300" "$(cat "$MG_PROC/201/oom_score_adj")" -300
expect "dropbear by comm -> -300" "$(cat "$MG_PROC/202/oom_score_adj")" -300
expect "udevd untouched" "$(cat "$MG_PROC/203/oom_score_adj")" -1000
expect "non-negative unlisted untouched" "$(cat "$MG_PROC/204/oom_score_adj")" 0
expect "stale pidfile does not protect the old pid's value" "$(cat "$MG_PROC/205/oom_score_adj")" 300

# klipper_mcu RSS alert
fakeproc 101 klipper_mcu -1000 9000
mg_check_mcu_rss
grep -q 'ALERT klipper_mcu VmRSS 9000' "$MG_LOG" && pass "klipper_mcu RSS alert logged" || fail "no klipper_mcu RSS alert"

# --- (c) absent PSI reads as zero; present PSI parses ---------------------------
mg_read_psi; expect "absent PSI: SOME10=0" "$SOME10" 0; expect "absent PSI: FULL10=0" "$FULL10" 0
mkdir -p "$MG_PROC/pressure"
printf 'some avg10=12.34 avg60=1.00 avg300=0.00 total=1\nfull avg10=5.67 avg60=0.00 avg300=0.00 total=1\n' > "$MG_PROC/pressure/memory"
mg_read_psi; expect "PSI some avg10" "$SOME10" 12; expect "PSI full avg10" "$FULL10" 5
rm -rf "$MG_PROC/pressure"

mg_read_meminfo; expect "MemAvailable parsed" "$MA" 150000
mg_read_zram; expect "zram mem_used" "$ZU" 0; expect "zram mem_limit" "$ZL" 50000000

# --- ticks: slow work runs every 5 s by elapsed time, not by modulo ---------
CALLS=0
mg_poll_print_state() { CALLS=$((CALLS + 1)); }
MG_LAST_SLOW= MG_LAST_SNAPSHOT=
for t in 100 101 103 104 105 107 111; do uptime $t; mg_tick; done
expect "slow work ran at t=100,105,111" "$CALLS" 3

# --- MEM-T13: eMMC swap only during maintenance ---------------------------------
SWF="$WORK/swapfile"; : > "$SWF"
MG_SWAPFILE=$SWF MG_SWAPON="$WORK/swapon" MG_SWAPOFF="$WORK/swapoff"
printf '#!/bin/sh\necho "swapon $*" >> %s/swap.calls\n' "$WORK" > "$WORK/swapon"
printf '#!/bin/sh\necho "swapoff $*" >> %s/swap.calls\n' "$WORK" > "$WORK/swapoff"
chmod +x "$WORK/swapon" "$WORK/swapoff"
swaps() { # used_kB or "" for inactive
	printf 'Filename\tType\tSize\tUsed\tPriority\n/dev/zram0 partition 131068 0 100\n' > "$MG_PROC/swaps"
	[ -n "$1" ] && printf '%s file 131068 %s 10\n' "$SWF" "$1" >> "$MG_PROC/swaps"
}
NOW=5000 STATE=NORMAL
# (d) maintenance and the swapfile inactive -> swapon
rm -f "$WORK/swap.calls"; swaps ""; MAINT=1
mg_diskswap_reconcile
grep -q "swapon -p 10 $SWF" "$WORK/swap.calls" 2>/dev/null && pass "(d) MAINT=1 -> swapon" || fail "(d) no swapon"
# (e) idle, used 0 -> swapoff
rm -f "$WORK/swap.calls"; swaps 0; MAINT=0; MA=150000 ZU=0 ZL=50000000
mg_diskswap_reconcile; wait 2>/dev/null
grep -q "swapoff $SWF" "$WORK/swap.calls" 2>/dev/null && pass "(e) used 0 -> swapoff" || fail "(e) no swapoff"
NOW=5005; mg_diskswap_reconcile   # reaps the finished swapoff
# (f) used 100 MiB with MA 120 MiB -> deferred
rm -f "$WORK/swap.calls"; swaps 102400; MA=122880 ZU=0 ZL=50000000; MG_DEFER_LOGGED=
NOW=5010; mg_diskswap_reconcile
[ ! -e "$WORK/swap.calls" ] && pass "(f) used 100 MiB, MA 120 MiB -> deferred" || fail "(f) swapoff not deferred"
grep -q DISKSWAP_OFF_DEFERRED "$MG_LOG" && pass "(f) deferral logged" || fail "(f) deferral not logged"
# never at P2+
swaps 0; MA=150000; STATE=P2
NOW=5015; mg_diskswap_reconcile
[ ! -e "$WORK/swap.calls" ] && pass "no swapoff at P2" || fail "swapoff at P2"
STATE=NORMAL
# rollback policy
MG_DISKSWAP_POLICY=always; NOW=5020; mg_diskswap_reconcile
[ ! -e "$WORK/swap.calls" ] && pass "MG_DISKSWAP_POLICY=always leaves the tier alone" || fail "policy=always acted"
MG_DISKSWAP_POLICY=maintenance
# watchdog: a hanging swapoff is aborted after 120 s
printf '#!/bin/sh\nexec sleep 300\n' > "$WORK/swapoff"
swaps 0; NOW=6000; MG_SWAPOFF_HOLD=0
mg_diskswap_reconcile
[ -n "${MG_SWAPOFF_PID:-}" ] && pass "swapoff runs in the background" || fail "swapoff not backgrounded"
NOW=6121; mg_diskswap_reconcile
grep -q DISKSWAP_OFF_TIMEOUT "$MG_LOG" && pass "a swapoff over 120 s is aborted and logged" || fail "no swapoff watchdog"
[ "$MG_SWAPOFF_HOLD" = $((6121 + 600)) ] && pass "cooldown after an aborted swapoff" || fail "no cooldown ($MG_SWAPOFF_HOLD)"
rm -f "$MG_PROC/swaps"

# --- MEM-T14 section is appended below by that task ----------------------------

echo "nebulaos-memguard-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
