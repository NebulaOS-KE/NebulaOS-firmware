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

# HWDP-MEM-5 locked-memory alert: resident Mlocked, never klippy's VmLck range
lockinfo() { # Mlocked line content, or "" for no line
	printf 'MemTotal:       249132 kB\nMemFree:         10000 kB\nMemAvailable:   150000 kB\nUnevictable:     31032 kB\n' > "$MG_PROC/meminfo"
	[ -n "$1" ] && printf 'Mlocked:        %s\n' "$1" >> "$MG_PROC/meminfo"
	printf 'SwapTotal:      131068 kB\n' >> "$MG_PROC/meminfo"
}
locked_alerts() { grep -c 'ALERT resident locked memory' "$MG_LOG" 2>/dev/null || true; }
# klippy as measured on ke-dev: VmLck 128280 kB (MCL_ONFAULT range), resident ~30 MiB
printf 'Name:\tpython3\nVmLck:\t128280 kB\nVmRSS:\t30368 kB\n' > "$MG_PROC/100/status"
MG_LOCKED_ALERTED=0
lockinfo "31032 kB"; mg_read_meminfo; mg_check_locked
expect "Mlocked parsed after MemAvailable" "$MLOCKED" 31032
expect "MemAvailable still parsed with Mlocked present" "$MA" 150000
expect "large VmLck + normal resident locked -> no alert" "$(locked_alerts)" 0
lockinfo "70000 kB"; mg_read_meminfo; mg_check_locked
expect "resident locked above 64 MiB -> alert" "$(locked_alerts)" 1
mg_check_locked
expect "alert logged once while still high" "$(locked_alerts)" 1
lockinfo "60000 kB"; mg_read_meminfo; mg_check_locked
expect "inside the re-arm margin -> still latched" "$MG_LOCKED_ALERTED" 1
lockinfo "50000 kB"; mg_read_meminfo; mg_check_locked
expect "below the re-arm margin -> re-armed" "$MG_LOCKED_ALERTED" 0
lockinfo "70000 kB"; mg_read_meminfo; mg_check_locked
expect "re-armed alert fires again" "$(locked_alerts)" 2
lockinfo ""; MG_LOCKED_ALERTED=0; mg_read_meminfo; mg_check_locked; rc=$?
expect "no Mlocked line -> unknown" "$MLOCKED" ""
expect "no Mlocked line -> check returns 0" "$rc" 0
expect "no Mlocked line -> no alert" "$(locked_alerts)" 2
expect "no Mlocked line -> MemAvailable still parsed" "$MA" 150000
lockinfo "abc kB"; mg_read_meminfo; mg_check_locked; rc=$?
expect "malformed Mlocked -> check returns 0" "$rc" 0
expect "malformed Mlocked -> no alert" "$(locked_alerts)" 2
lockinfo "-5 kB"; mg_read_meminfo; mg_check_locked; rc=$?
expect "negative Mlocked -> no alert, rc 0" "$rc:$(locked_alerts)" "0:2"
( MG_PROC="$WORK/noproc"; mg_read_meminfo 2>/dev/null; mg_check_locked ); rc=$?
expect "unreadable meminfo -> no crash" "$rc" 0
# the check reads no per-process file: it must not depend on /proc/<pid> at all
mv "$MG_PROC/100" "$MG_PROC/100.hidden"
lockinfo "70000 kB"; MG_LOCKED_ALERTED=0; mg_read_meminfo; mg_check_locked
expect "alert without any /proc/<pid> access" "$(locked_alerts)" 3
mv "$MG_PROC/100.hidden" "$MG_PROC/100"
meminfo 150000

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

# --- MEM-T14: pressure levels P1..P4 ------------------------------------------
printf '#!/bin/sh\necho "S56 $*" >> %s/svc.calls\n' "$WORK" > "$WORK/S56"
printf '#!/bin/sh\necho "S58 $*" >> %s/svc.calls\n' "$WORK" > "$WORK/S58"
chmod +x "$WORK/S56" "$WORK/S58"
MG_S56="$WORK/S56" MG_S58="$WORK/S58"
ZU=0 ZL=50000000 SOME10=0 FULL10=0 PRINT=1
fresh() { LEVEL=0 ENTER_CNT=0 EXIT_SINCE= LAST_ESCALATE=-1000 P4_SINCE= EXHAUSTED_LOGGED=0 STATE=NORMAL; rm -f "$WORK/svc.calls" "$MG_RUN"/shed/* "$MG_RUN"/memguard/deny-maintenance; }
run() { # seconds MA_MiB -> evaluate once per second, record level changes
	_n=$1
	while [ "$_n" -gt 0 ]; do
		NOW=$((NOW + 1)); MA=$(($2 * 1024)); _old=$LEVEL
		mg_evaluate
		[ "$LEVEL" != "$_old" ] && TRANS="$TRANS P$LEVEL@$NOW"
		_n=$((_n - 1))
	done
}
# (g) scripted MA series enters P1..P4 with >= 10 s spacing
fresh; NOW=10000; TRANS=""
fakeproc 102 python3 -400 30000; echo 102 > "$MG_PIDDIR/moonraker.pid"
run 20 80; run 15 50; run 15 35; run 15 28; run 15 20
expect "(g) transitions" "$TRANS" " P1@10022 P2@10037 P3@10052 P4@10067"
expect "(g) state P4" "$STATE" P4
[ -e "$MG_RUN/memguard/deny-maintenance" ] && pass "(g) P1 denies maintenance" || fail "(g) no deny-maintenance"
[ -e "$MG_RUN/shed/camera" ] && pass "(g) P2 sheds the camera (also while printing)" || fail "(g) camera not shed"
[ -e "$MG_RUN/shed/guppyscreen" ] && grep -q 'S58 stop' "$WORK/svc.calls" && pass "(g) P3 stops GuppyScreen" || fail "(g) GuppyScreen not stopped"
# fast drop: escalation is still one level per 10 s
fresh; NOW=20000; TRANS=""; run 40 10
expect "(g) a sudden drop still escalates one level per 10 s" "$TRANS" " P1@20002 P2@20012 P3@20022 P4@20032"
# (h) recovery: each level held 60 s
TRANS=""; run 241 100
expect "(h) de-escalation one level per 60 s dwell" "$TRANS" " P3@20101 P2@20161 P1@20221 P0@20281"
expect "(h) back to NORMAL" "$STATE" NORMAL
[ ! -e "$MG_RUN/shed/camera" ] && [ ! -e "$MG_RUN/shed/guppyscreen" ] && [ ! -e "$MG_RUN/memguard/deny-maintenance" ] \
	&& pass "(h) every marker removed" || fail "(h) markers left: $(ls "$MG_RUN/shed" "$MG_RUN/memguard")"
grep -q 'S58 start' "$WORK/svc.calls" && pass "(h) GuppyScreen restarted on leaving P3" || fail "(h) GuppyScreen not restarted"
# (i) P4 with Moonraker RSS 40 MiB -> no restart
fresh; NOW=30000; fakeproc 102 python3 -400 40960; run 40 10
grep -q 'S56' "$WORK/svc.calls" 2>/dev/null && fail "(i) Moonraker restarted at 40 MiB" || pass "(i) P4 with Moonraker at 40 MiB: no restart"
# P4 with a bloated Moonraker -> one restart
fresh; NOW=40000; MG_LAST_MR_RESTART=; fakeproc 102 python3 -400 80000; run 40 10; wait 2>/dev/null
grep -q 'S56 stop' "$WORK/svc.calls" && grep -q 'S56 start' "$WORK/svc.calls" && pass "P4 with Moonraker at 78 MiB: restarted" || fail "bloated Moonraker not restarted"
[ ! -e "$MG_RUN/shed/moonraker-restarting" ] && pass "moonraker-restarting marker removed afterwards" || fail "moonraker-restarting marker left"
# (j) a second P4 within 1800 s -> no restart
rm -f "$WORK/svc.calls"; LEVEL=3 ENTER_CNT=0 LAST_ESCALATE=-1000; NOW=40600; run 5 10; wait 2>/dev/null
grep -q 'S56' "$WORK/svc.calls" 2>/dev/null && fail "(j) second restart within 1800 s" || pass "(j) second P4 within 1800 s: no restart"
# P4_EXHAUSTED after 120 s
fresh; NOW=50000; fakeproc 102 python3 -400 30000; run 200 10
expect "P4 held 120 s -> P4_EXHAUSTED" "$STATE" P4_EXHAUSTED
[ "$(grep -c 'SUPPORTED WORKLOAD EXCEEDED' "$MG_LOG")" = 1 ] && pass "exhaustion logged once" || fail "exhaustion log count wrong"
# (k) PSI-only escalation
fresh; NOW=60000; TRANS=""; FULL10=25; run 40 200; FULL10=0
expect "(k) PSI full avg10 25 alone reaches P4" "$STATE" P4
# zram nearly full alone reaches P2 but no further
fresh; NOW=70000; ZU=46000000; run 60 200; ZU=0
expect "zram >= 90% of mem_limit alone -> P2" "$STATE" P2
# tracker-only mode
fresh; NOW=80000; MG_ACTIONS=0; run 40 10; MG_ACTIONS=1
[ ! -e "$MG_RUN/shed/camera" ] && [ ! -e "$WORK/svc.calls" ] && pass "MG_ACTIONS=0: tracks without acting" || fail "MG_ACTIONS=0 acted"
expect "MG_ACTIONS=0 still reports the level" "$STATE" P4
# a restarted memguard clears a previous instance's sheds
fresh; : > "$MG_RUN/shed/guppyscreen"; : > "$MG_RUN/shed/camera"
mg_reset_markers
[ ! -e "$MG_RUN/shed/guppyscreen" ] && [ ! -e "$MG_RUN/shed/camera" ] && grep -q 'S58 start' "$WORK/svc.calls" \
	&& pass "restart clears stale sheds and restarts GuppyScreen" || fail "stale sheds not cleared"

echo "nebulaos-memguard-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
