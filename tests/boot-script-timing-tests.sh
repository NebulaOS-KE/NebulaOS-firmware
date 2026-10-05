#!/bin/sh
#
# BOOT-09 (2026-10-05): offline tests for the NebulaOS rcS per-script timing
# and scripts/qa/parse-boot-script-timing.py. Runs the real rcS against a
# sandbox init.d. NEBULAOS_TEST_SH selects the shell (the device runs BusyBox
# ash; a host BusyBox built from the same 1.37.0 source is the best stand-in).
#
# Usage: sh tests/boot-script-timing-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
RCS="$SCRIPT_DIR/../scripts/build/overlay/etc/init.d/rcS"
PARSER="$SCRIPT_DIR/../scripts/qa/parse-boot-script-timing.py"
TSH="${NEBULAOS_TEST_SH:-sh}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/boot-script-timing-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$RCS" ] || { echo "FATAL: $RCS not found"; exit 1; }

mk_initd() {
	D="$WORK/$1/init.d"; mkdir -p "$D"
	printf '#!/bin/sh\necho "$0 $1" >> %s/ran\nsleep 0.3\n' "$WORK/$1" > "$D/S01first"
	printf '#!/bin/sh\necho "$0 $1" >> %s/ran\nexit 7\n' "$WORK/$1" > "$D/S02fails"
	printf 'echo "sourced $1" >> %s/ran\n' "$WORK/$1" > "$D/S03lib.sh"
	printf '#!/bin/sh\necho "$0 $1" >> %s/ran\n( sleep 0.5; echo bg-done >> %s/ran ) &\n' "$WORK/$1" "$WORK/$1" > "$D/S04background"
	ln -s "$D/does-not-exist" "$D/S05dangling"
	chmod +x "$D/S01first" "$D/S02fails" "$D/S04background"
}
run_rcs() { # case log [uptime-src]
	env INIT_DIR="$WORK/$1/init.d" NEBULAOS_BOOT_SCRIPTS_LOG="$2" UPTIME_SRC="${3:-/proc/uptime}" \
		$TSH "$RCS" > "$WORK/$1/out" 2>&1
}

# 1. normal run: order, rc, sourcing, every script logged, parseable
mk_initd normal; L="$WORK/normal/log"; echo "stale line from the previous boot" > "$L"
run_rcs normal "$L"; rc=$?
[ $rc -eq 0 ] && pass || fail "rcS exited $rc"
[ "$(grep -c '' "$WORK/normal/ran" 2>/dev/null)" -ge 4 ] && pass || fail "not every script ran ($(cat "$WORK/normal/ran" 2>/dev/null))"
grep -q 'S01first start' "$WORK/normal/ran" && grep -q 'sourced start' "$WORK/normal/ran" && pass || fail "start argument / sourcing broken"
grep -q 'stale line' "$L" && fail "log not fresh (previous content kept)" || pass
head -1 "$L" | grep -qE '^T=[0-9]+\.[0-9]+ EV=begin BOOT_ID=' && pass || fail "begin line malformed: $(head -1 "$L")"
tail -1 "$L" | grep -qE '^T=[0-9.]+ EV=done$' && pass || fail "done line missing"
for s in S01first S02fails S03lib.sh S04background; do
	grep -qE "EV=start S=$s\$" "$L" && grep -qE "EV=end S=$s RC=-?[0-9]+ DUR=[0-9]+\.[0-9]{2}\$" "$L" && pass || fail "$s start/end not logged"
done
grep -q 'S05dangling' "$L" && fail "dangling symlink was logged/run" || pass
grep -q 'EV=end S=S02fails RC=7 ' "$L" && pass || fail "exit status not recorded"
grep -q 'EV=end S=S01first RC=0 DUR=0\.[2-9]' "$L" && pass || fail "S01first duration not ~0.3 s: $(grep 'end S=S01first' "$L")"
# order preserved
order=$(grep 'EV=start' "$L" | sed 's/.*S=//' | tr '\n' ' ')
[ "$order" = "S01first S02fails S03lib.sh S04background " ] && pass || fail "order changed: $order"
# monotonic
awk -F'[ =]' '{ t=$2+0; if (NR > 1 && t < p) bad=1; p=t } END { exit bad }' "$L" && pass || fail "timestamps not monotonic"
# parser reconstructs start/end/dur/rc and gaps, no anomalies
python3 "$PARSER" "$L" --json > "$WORK/normal/json" && pass || fail "parser failed"
python3 - "$WORK/normal/json" <<'EOF' && pass || fail "parsed table wrong"
import json, sys
r = json.load(open(sys.argv[1]))
s = {x["script"]: x for x in r["scripts"]}
assert list(s) == ["S01first", "S02fails", "S03lib.sh", "S04background"], list(s)
assert s["S02fails"]["rc"] == 7 and s["S01first"]["rc"] == 0
assert 0.2 <= s["S01first"]["dur"] <= 1.5
assert all(x["gap_before"] is not None and x["gap_before"] >= 0 for x in r["scripts"])
assert r["done"] >= r["begin"] and not r["anomalies"], r["anomalies"]
EOF
# background work outlives its script's END line (documented behaviour)
sleep 1; grep -q bg-done "$WORK/normal/ran" && pass || fail "background child did not complete"

# 2. missing / malformed /proc/uptime: boot continues, T=?, no arithmetic abort
for src in missing garbage twodots leadingzero empty; do
	mk_initd "up-$src"; U="$WORK/up-$src/uptime"
	case $src in
		missing) U="$WORK/up-$src/no-such-file" ;;
		garbage) echo "abc def" > "$U" ;;
		twodots) echo "1.2.3 4" > "$U" ;;
		leadingzero) echo "08.50 1" > "$U" ;;
		empty) : > "$U" ;;
	esac
	run_rcs "up-$src" "$WORK/up-$src/log" "$U"; rc=$?
	[ $rc -eq 0 ] && [ "$(grep -c '' "$WORK/up-$src/ran")" -ge 4 ] && pass || fail "uptime=$src: boot broken (rc=$rc, $(cat "$WORK/up-$src/out"))"
	grep -q 'EV=end S=S04background RC=0 DUR=?' "$WORK/up-$src/log" && pass || fail "uptime=$src: no T=?/DUR=? fallback"
	grep -qi 'arithmetic\|syntax error' "$WORK/up-$src/out" && fail "uptime=$src: shell error printed" || pass
done

# 3. logging failure is non-fatal: log path is a directory / in a read-only dir / empty
mk_initd logdir; mkdir -p "$WORK/logdir/log-is-dir"
run_rcs logdir "$WORK/logdir/log-is-dir"; rc=$?
[ $rc -eq 0 ] && [ "$(grep -c '' "$WORK/logdir/ran")" -ge 4 ] && pass || fail "log path = directory broke the boot"
mk_initd ro; mkdir -p "$WORK/ro/rodir"; chmod 555 "$WORK/ro/rodir"
run_rcs ro "$WORK/ro/rodir/log"; rc=$?
[ $rc -eq 0 ] && [ "$(grep -c '' "$WORK/ro/ran")" -ge 4 ] && pass || fail "unwritable log dir broke the boot"
mk_initd nolog; run_rcs nolog ""; rc=$?
[ $rc -eq 0 ] && [ "$(grep -c '' "$WORK/nolog/ran")" -ge 4 ] && pass || fail "empty log path broke the boot"

# 4. bounded: many scripts never push the log past the line cap
D="$WORK/many/init.d"; mkdir -p "$D"
i=0; while [ $i -lt 400 ]; do n=$(printf '%03d' $i); printf '#!/bin/sh\n:\n' > "$D/S$n"; chmod +x "$D/S$n"; i=$((i + 1)); done
mv "$D/S000" "$D/S00x"; for f in "$D"/S[0-9][0-9][0-9]; do b=${f##*/}; mv "$f" "$D/S${b#S}x"; done 2>/dev/null
run_rcs many "$WORK/many/log"; rc=$?
lines=$(grep -c '' "$WORK/many/log")
[ $rc -eq 0 ] && [ "$lines" -le 512 ] && [ "$lines" -ge 500 ] && pass || fail "line cap not enforced (rc=$rc lines=$lines)"

# 5. parser flags a script that never ended and a clock going backwards
printf 'T=1.00 EV=begin BOOT_ID=x\nT=2.00 EV=start S=S01a\nT=1.50 EV=end S=S01a RC=0 DUR=0.00\nT=3.00 EV=start S=S02hang\n' > "$WORK/bad.log"
out=$(python3 "$PARSER" "$WORK/bad.log")
echo "$out" | grep -q 'ANOMALY S02hang started but never ended' && pass || fail "hung script not flagged"
echo "$out" | grep -q 'went backwards' && pass || fail "backwards clock not flagged"

# 6. the shipped rcS keeps Buildroot's loop semantics
grep -q 'for i in "$INIT_DIR"/S??\*; do' "$RCS" && pass || fail "S??* loop changed"
grep -q '"$i" start' "$RCS" && pass || fail "scripts no longer started with 'start'"
grep -q 'INIT_DIR="${INIT_DIR:-/etc/init.d}"' "$RCS" && pass || fail "default init dir changed"
grep -q '/run/nebulaos-boot-scripts.log' "$RCS" && pass || fail "default log path is not on /run (tmpfs)"

echo "boot-script-timing-tests ($TSH): PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
