#!/usr/bin/env bash
#
# Every host-side test in tests/ (no printer, no build), one line per test,
# as CI runs them (Run 23). Exit 1 when any test fails. A test that reports
# "...=SKIP" as its last line (a missing optional input, e.g. no Buildroot
# tree) counts as skipped.
#
#   tests/run-all.sh [pattern]      e.g. tests/run-all.sh 'image*'
#
# NEBULAOS_TEST_SKIP: space-separated test file names not to run (CI: the
# tests that need an installed NebulaOS workspace around the repository).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
LOGS=${NEBULAOS_TEST_LOGS:-$(mktemp -d)}
mkdir -p "$LOGS"
pass=0; fail=0; skip=0
for t in tests/${1:-*}.py tests/${1:-*}.sh; do
  [ -f "$t" ] || continue
  case "$t" in tests/run-all.sh) continue ;; esac
  n=$(basename "$t"); t0=$(date +%s)
  case " ${NEBULAOS_TEST_SKIP:-} " in *" $n "*) skip=$((skip + 1)); printf 'SKIP       %s\n' "$n"; continue ;; esac
  case "$t" in
    *.py) timeout 900 python3 "$t" > "$LOGS/$n.log" 2>&1 ;;
    *)    timeout 900 bash "$t" > "$LOGS/$n.log" 2>&1 ;;
  esac
  rc=$?
  if [ "$rc" -ne 0 ] && tail -1 "$LOGS/$n.log" | grep -q '=SKIP$'; then
    skip=$((skip + 1)); printf 'SKIP %4ss %s (%s)\n' "$(( $(date +%s) - t0 ))" "$n" "$(tail -1 "$LOGS/$n.log")"
  elif [ "$rc" -eq 0 ]; then
    pass=$((pass + 1)); printf 'PASS %4ss %s\n' "$(( $(date +%s) - t0 ))" "$n"
  else
    fail=$((fail + 1)); printf 'FAIL %4ss %s (exit %s)\n' "$(( $(date +%s) - t0 ))" "$n" "$rc"
    tail -25 "$LOGS/$n.log" | sed 's/^/    /'
  fi
done
printf 'TESTS_PASS=%s TESTS_FAIL=%s TESTS_SKIP=%s LOGS=%s\n' "$pass" "$fail" "$skip" "$LOGS"
[ "$fail" -eq 0 ]
