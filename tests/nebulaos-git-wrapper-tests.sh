#!/bin/sh
#
# MEM-T08 / MEM-T17: the git wrapper on Moonraker's PATH. A fake real git
# (NEBULAOS_GIT_REAL) records invocations; NEBULAOS_RUN_DIR holds the memguard
# markers. Covers the exact command shape Moonraker's git_deploy.fetch() runs:
# git -C <repo> fetch origin --prune --progress.
#
# Usage: sh tests/nebulaos-git-wrapper-tests.sh

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
WRAP="$REPO_ROOT/scripts/build/overlay/usr/libexec/nebulaos/bin/git"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/git-wrapper-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM
PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

printf '#!/bin/sh\necho "$*" >> %s/real.calls\necho adj=$(cat /proc/self/oom_score_adj) >> %s/real.calls\nexit 0\n' "$WORK" "$WORK" > "$WORK/realgit"
chmod +x "$WORK/realgit"
export NEBULAOS_GIT_REAL="$WORK/realgit" NEBULAOS_RUN_DIR="$WORK/run"
mkdir -p "$NEBULAOS_RUN_DIR/memguard"
calls() { cat "$WORK/real.calls" 2>/dev/null | grep -vc '^adj='; }
reset() { rm -f "$WORK/real.calls"; }

[ -x "$WRAP" ] && pass "wrapper is executable" || fail "wrapper not executable"
sh -n "$WRAP" && pass "wrapper parses" || fail "wrapper does not parse"

# idle: everything passes through, at adj 800
reset; sh "$WRAP" -C /x fetch origin --prune --progress; rc=$?
[ "$rc" = 0 ] && [ "$(calls)" = 1 ] && pass "idle: fetch passes through" || fail "idle fetch did not reach git (rc=$rc)"
grep -q 'adj=800' "$WORK/real.calls" && pass "git runs at oom_score_adj 800" || fail "adj not 800: $(cat "$WORK/real.calls")"

# printing
: > "$NEBULAOS_RUN_DIR/print-active"
reset; sh "$WRAP" -C /x fetch origin --prune --progress; rc=$?
[ "$rc" = 0 ] && [ "$(calls)" = 0 ] && pass "printing: Moonraker's fetch shape is a no-op success" || fail "printing fetch: rc=$rc calls=$(calls)"
reset; sh "$WRAP" -C /x -c core.quotepath=false fetch origin; rc=$?
[ "$rc" = 0 ] && [ "$(calls)" = 0 ] && pass "printing: -c k=v before fetch still detected" || fail "-c k=v not parsed (rc=$rc calls=$(calls))"
reset; sh "$WRAP" -C /x pull; rc=$?
[ "$rc" != 0 ] && [ "$(calls)" = 0 ] && pass "printing: pull refused" || fail "printing pull: rc=$rc calls=$(calls)"
reset; sh "$WRAP" clone https://example.invalid/r.git /y; rc=$?
[ "$rc" != 0 ] && [ "$(calls)" = 0 ] && pass "printing: clone refused" || fail "printing clone: rc=$rc"
reset; sh "$WRAP" -C /x status --porcelain; rc=$?
[ "$rc" = 0 ] && [ "$(calls)" = 1 ] && pass "printing: status passes through" || fail "printing status blocked"
reset; sh "$WRAP" -C /fetch rev-parse HEAD; rc=$?
[ "$(calls)" = 1 ] && pass "a path named 'fetch' after -C is not the subcommand" || fail "-C fetch mis-parsed"
rm -f "$NEBULAOS_RUN_DIR/print-active"

# memory pressure
: > "$NEBULAOS_RUN_DIR/memguard/deny-maintenance"
reset; sh "$WRAP" -C /x fetch origin; rc=$?
[ "$rc" != 0 ] && [ "$(calls)" = 0 ] && pass "pressure: fetch refused" || fail "pressure fetch: rc=$rc"
reset; sh "$WRAP" -C /x log -1; rc=$?
[ "$(calls)" = 1 ] && pass "pressure: local commands pass through" || fail "pressure blocked a local command"
rm -f "$NEBULAOS_RUN_DIR/memguard/deny-maintenance"

grep -q 'export PATH="/usr/libexec/nebulaos/bin:$PATH"' "$REPO_ROOT/scripts/build/overlay/etc/init.d/S56moonraker" \
	&& pass "S56moonraker puts the wrapper first on Moonraker's PATH" || fail "S56moonraker PATH export missing"

echo "nebulaos-git-wrapper-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
