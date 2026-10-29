#!/usr/bin/env bash
#
# Every host-side test in tests/ (no printer, no build), one line per test,
# as CI runs them (Run 23). Exit 1 when any test fails.
#
#   tests/run-all.sh [pattern]      e.g. tests/run-all.sh 'image*'
set -uo pipefail
cd "$(dirname "$0")/.."
LOGS=${NEBULAOS_TEST_LOGS:-$(mktemp -d)}
mkdir -p "$LOGS"
pass=0; fail=0
for t in tests/${1:-*}.py tests/${1:-*}.sh; do
  [ -f "$t" ] || continue
  case "$t" in tests/run-all.sh) continue ;; esac
  n=$(basename "$t"); t0=$(date +%s)
  case "$t" in
    *.py) timeout 900 python3 "$t" > "$LOGS/$n.log" 2>&1 ;;
    *)    timeout 900 bash "$t" > "$LOGS/$n.log" 2>&1 ;;
  esac
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass=$((pass + 1)); printf 'PASS %4ss %s\n' "$(( $(date +%s) - t0 ))" "$n"
  else
    fail=$((fail + 1)); printf 'FAIL %4ss %s (exit %s)\n' "$(( $(date +%s) - t0 ))" "$n" "$rc"
    tail -25 "$LOGS/$n.log" | sed 's/^/    /'
  fi
done
printf 'TESTS_PASS=%s TESTS_FAIL=%s LOGS=%s\n' "$pass" "$fail" "$LOGS"
[ "$fail" -eq 0 ]
