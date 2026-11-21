#!/bin/sh
#
# Offline tests for #27 test build 2: klippy pinned to CPU1
# (/usr/libexec/nebulaos/run-on-cpus, wired in S55klipper).
#
# Usage: sh tests/klippy-cpu-pinning-tests.sh

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
W="$REPO_ROOT/scripts/build/overlay/usr/libexec/nebulaos/run-on-cpus"
S55="$REPO_ROOT/scripts/build/overlay/etc/init.d/S55klipper"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cpu-pin-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
expect() { [ "$2" = "$3" ] && pass "$1" || fail "$1 (got '$2', want '$3')"; }

PY=$(command -v python3)
NCPU=$("$PY" -c 'import os; print(len(os.sched_getaffinity(0)))')
ALL=$("$PY" -c 'import os; print(",".join(str(c) for c in sorted(os.sched_getaffinity(0))))')
FIRST=${ALL%%,*}
SHOW='import os,sys; print(",".join(str(c) for c in sorted(os.sched_getaffinity(0))), os.getpid(), sys.argv[1:])'

run() { # setting-content|-  -> prints the child's affinity, pid, args
	if [ "$1" = - ]; then rm -f "$WORK/setting"; else printf '%s\n' "$1" > "$WORK/setting"; fi
	rm -f "$WORK/state"
	"$PY" -I "$W" "$WORK/setting" "$WORK/state" "$PY" -c "$SHOW" a b
}

"$PY" -c "import ast; ast.parse(open('$W').read())" && pass "run-on-cpus parses" || fail "run-on-cpus does not parse"
sh -n "$S55" && pass "S55klipper parses" || fail "S55klipper does not parse"

if [ "$NCPU" -ge 2 ]; then
	SECOND=$(echo "$ALL" | cut -d, -f2)
	out=$(run "$SECOND")
	expect "setting '$SECOND' pins to that CPU" "${out%% *}" "$SECOND"
	expect "state says applied" "$(cat "$WORK/state")" "requested=$SECOND applied=$SECOND"
	case "$out" in *"['a', 'b']") pass "arguments passed through" ;; *) fail "arguments lost: $out" ;; esac
	out=$(run "$FIRST,$SECOND")
	expect "a list pins to all of it" "${out%% *}" "$FIRST,$SECOND"
else
	echo "SKIP: one CPU on this host"
fi

out=$(run none)
expect "'none' leaves the affinity alone" "${out%% *}" "$ALL"
expect "state says none" "$(cat "$WORK/state")" "requested=none applied=none"

out=$(run banana)
expect "a bad setting still starts the program, unpinned" "${out%% *}" "$ALL"
expect "state names the bad setting" "$(cat "$WORK/state")" "requested=banana applied=none error=bad-setting"

out=$(run 63)
expect "a CPU that does not exist: unpinned" "${out%% *}" "$ALL"
expect "state says cpu-not-present" "$(cat "$WORK/state")" "requested=63 applied=none error=cpu-not-present"

# missing setting = the default, CPU 1 (when the host has it)
out=$(run -)
case ",$ALL," in
*,1,*) expect "no setting file -> CPU 1" "${out%% *}" "1" ;;
*) expect "no setting file, no CPU 1 here -> unpinned" "${out%% *}" "$ALL" ;;
esac

# exec, not a child: the program keeps the wrapper's pid
out=$(printf '1\n' > "$WORK/setting"; "$PY" -I "$W" "$WORK/setting" "$WORK/state" "$PY" -c \
	'import os; print(os.getpid(), os.getppid())' & echo "bgpid $!"; wait)
pid_line=$(echo "$out" | grep -v bgpid)
bg=$(echo "$out" | sed -n 's/^bgpid //p')
expect "exec keeps the pid" "${pid_line%% *}" "$bg"

# an unwritable state file never stops the start
out=$("$PY" -I "$W" "$WORK/setting" /proc/nonexistent/state "$PY" -c 'print("started")')
expect "unwritable state file: still starts" "$out" "started"

# S55klipper: the wrapper sits between the interpreter and klippy.py
grep -q 'RUN_ON_CPUS="${RUN_ON_CPUS:-/usr/libexec/nebulaos/run-on-cpus}"' "$S55" \
	&& pass "S55 uses run-on-cpus" || fail "S55 does not reference run-on-cpus"
grep -q -- '-x "$PYTHON3" -- $PIN \\' "$S55" && pass "S55 passes the wrapper before klippy.py" \
	|| fail "S55 start line not wired"
grep -q 'KLIPPY_CPUS_SETTING="${KLIPPY_CPUS_SETTING:-/usr/data/nebulaos/system/klippy-cpus}"' "$S55" \
	&& pass "S55 setting file on the data partition (A/B switch)" || fail "S55 setting path"

echo "klippy-cpu-pinning-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
