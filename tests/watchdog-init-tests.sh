#!/bin/sh
#
# G117(b): S02nebulaos-watchdog. A fake start-stop-daemon records its
# arguments; /dev/null stands in for the watchdog character device.
#
# Usage: sh tests/watchdog-init-tests.sh

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OV="$REPO_ROOT/scripts/build/overlay"
INIT="$OV/etc/init.d/S02nebulaos-watchdog"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/watchdog-init-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM
PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

mkdir -p "$WORK/bin" "$WORK/system"
printf '#!/bin/sh\necho "cwd=$(pwd) $*" >> %s/ssd.calls\nexit 0\n' "$WORK" > "$WORK/bin/start-stop-daemon"
chmod +x "$WORK/bin/start-stop-daemon"
export PATH="$WORK/bin:$PATH" NEBULAOS_SYSTEM_DIR="$WORK/system" NEBULAOS_WATCHDOG_DEVICE=/dev/null \
	NEBULAOS_WATCHDOG_PIDFILE="$WORK/wd.pid" NEBULAOS_OOM_POLICY="$OV/etc/nebulaos-oom-policy.sh"
run() { rm -f "$WORK/ssd.calls"; out=$(sh "$INIT" "$@" 2>&1); rc=$?; }
calls() { cat "$WORK/ssd.calls" 2>/dev/null; }

[ -x "$INIT" ] && pass "init script is executable" || fail "init script not executable"
sh -n "$INIT" && pass "init script parses" || fail "init script does not parse"

run start
c=$(calls)
[ "$rc" = 0 ] && case "$c" in *"-S -b -m -p $WORK/wd.pid -N -20 -x /sbin/watchdog -- -F -T 60 -t 10 /dev/null"*) true ;; *) false ;; esac \
	&& pass "on by default (Run 22): watchdog -F -T 60 -t 10 under start-stop-daemon -b -m, nice -20" || fail "default: rc=$rc calls=$c"
grep -q 'watchdog.enable' "$INIT" && fail "watchdog.enable is still required" || pass "no watchdog.enable switch any more"
case "$c" in "cwd=/ "*) pass "the daemon starts from / (no cwd on /usr/data)" ;; *) fail "cwd: $c" ;; esac
grep -q 'chrt\|SCHED_FIFO -f\|-f 99' "$INIT" && fail "a real-time priority is used" || pass "no real-time priority (starves with userspace)"

: > "$WORK/system/watchdog.disable"
run start
[ "$rc" = 0 ] && [ -z "$(calls)" ] && pass "watchdog.disable switches it off" || fail "disable: rc=$rc calls=$(calls)"
rm -f "$WORK/system/watchdog.disable"

NEBULAOS_WATCHDOG_DEVICE="$WORK/none" run start
[ "$rc" = 0 ] && [ -z "$(calls)" ] && pass "missing /dev/watchdog -> not armed, exit 0" || fail "no device: rc=$rc calls=$(calls)"

run stop
[ "$rc" = 0 ] && [ -z "$(calls)" ] && pass "stop without a pidfile does nothing" || fail "stop no pid: $(calls)"
echo 4242 > "$WORK/wd.pid"
run stop
case "$(calls)" in *"-K -s TERM -p $WORK/wd.pid"*) pass "stop sends TERM (magic close), never KILL" ;; *) fail "stop: $(calls)" ;; esac
[ ! -e "$WORK/wd.pid" ] && pass "stop removes the pidfile" || fail "pidfile left"

# Run 22 review: a pending trial is counted before arming; after 3 starts no arming
printf '#!/bin/sh\necho "$*" >> %s/osc.calls\ncat %s/osc.out 2>/dev/null\n' "$WORK" "$WORK" > "$WORK/osconfig"
chmod +x "$WORK/osconfig"
export NEBULAOS_OSCONFIG="$WORK/osconfig" NEBULAOS_IMAGE_TRIAL="$WORK/trial.json"
run start
[ ! -e "$WORK/osc.calls" ] && pass "no trial: no trial-count call" || fail "trial-count without a trial"
: > "$WORK/trial.json"
echo '{"ok": true, "result": "COUNTED", "attempts": 2, "arm": true}' > "$WORK/osc.out"
run start
grep -q "image trial-count" "$WORK/osc.calls" && [ -n "$(calls)" ] \
	&& pass "trial pending: counted, then armed" || fail "trial arm: $(cat "$WORK/osc.calls" 2>/dev/null) / $(calls)"
echo '{"ok": true, "result": "COUNTED", "attempts": 4, "arm": false}' > "$WORK/osc.out"
run start
[ -z "$(calls)" ] && case "$out" in *"not armed"*) true ;; *) false ;; esac \
	&& pass "4th unconfirmed start: not armed" || fail "not-armed: calls=$(calls) out=$out"
rm -f "$WORK/trial.json"

V="$REPO_ROOT/scripts/build/06-verify.sh"
grep -q 'check_required /etc/init.d/S02nebulaos-watchdog' "$V" && grep -q 'check_required /sbin/watchdog' "$V" \
	&& pass "06-verify requires the feeder and /sbin/watchdog (build fails without)" || fail "06-verify does not require the feeder"
grep -A3 'stat /etc/init.d/S15watchdog' "$V" | grep -q 'MISS_REQUIRED=' \
	&& pass "06-verify fails the build on a second feeder (Buildroot S15watchdog)" || fail "06-verify S15watchdog check does not fail the build"

echo "watchdog-init-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
