#!/bin/sh
#
# Does the [nebulaos] Moonraker component survive Moonraker's own update
# manager? (GUI/service readiness mission, 2026-10-09)
#
# Replays, on a REAL clone of the pinned Moonraker repository (vendor/
# moonraker, local - no network), the exact git operations
# update_manager/git_deploy.py performs:
#   update        git pull                          (GitDeploy.update -> pull)
#   rollback      git reset --hard <previous>       (GitRepo.rollback -> reset)
#   soft recover  git checkout -- . ; checkout <branch> ; reset --hard
#   clean         git clean -d -f                   (GitRepo.clean)
#   hard recover  clone into a backup dir, rm -rf the checkout, move the
#                 clone into place                  (GitRepo.clone)
# After each: the component symlink must be there, and `git status
# --porcelain -b` (what Moonraker parses for dirty/untracked state) must show
# nothing but the branch line - so update_manager still sees a pristine repo.
# Every one of these paths ends in a Moonraker restart through S56moonraker,
# whose start_daemon re-composes; the hard recover is the case that needs it.
#
# Usage: sh tests/moonraker-component-survival-tests.sh

set -u
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-moonraker-compose.sh"
S56="$REPO_ROOT/scripts/build/overlay/etc/init.d/S56moonraker"
S05="$REPO_ROOT/scripts/build/overlay/etc/init.d/S05nebulaos-activate"
VENDOR="$REPO_ROOT/vendor/moonraker"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
check() { if eval "$2"; then pass; else fail "$1"; fi; }

if [ ! -d "$VENDOR/.git" ]; then
	echo "SKIP: $VENDOR is not a git checkout (run 00-fetch-vendor-sources.sh)"
	exit 0
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/mr-survival.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"; mkdir -p "$HOME"
git config --global user.email t@t; git config --global user.name t
git config --global advice.detachedHead false

git clone -q --no-local "$VENDOR" "$T/origin" || { echo "FATAL: clone failed"; exit 1; }
BR=master
git -C "$T/origin" checkout -q -B "$BR"   # vendor checkout is a detached pin
NEW=$(git -C "$T/origin" rev-parse HEAD)
OLD=$(git -C "$T/origin" rev-parse HEAD~5)
APP="$T/apps/moonraker"
git clone -q "$T/origin" "$APP"
git -C "$APP" reset -q --hard "$OLD"

echo "# fake component" > "$T/nebulaos.py"
export NEBULAOS_MOONRAKER_COMPONENT="$T/nebulaos.py"
. "$LIB"

pristine() {
	[ "$(git -C "$APP" status --porcelain -b | grep -vc '^##')" = 0 ]
}
present() {
	[ -L "$APP/moonraker/components/nebulaos.py" ] && \
	[ "$(readlink "$APP/moonraker/components/nebulaos.py")" = "$T/nebulaos.py" ]
}
# What S56moonraker start_daemon does before every Moonraker start.
restart_moonraker() { compose_moonraker_component "$APP" >/dev/null; }

compose_moonraker_component "$APP" >/dev/null
check "composed: symlink present" present
check "composed: repo pristine to Moonraker (excluded)" pristine
check "composed: exclude entry recorded once" '[ "$(grep -cx /moonraker/components/nebulaos.py "$APP/.git/info/exclude")" = 1 ]'
compose_moonraker_component "$APP" >/dev/null
check "compose is idempotent (no duplicate exclude)" '[ "$(grep -cx /moonraker/components/nebulaos.py "$APP/.git/info/exclude")" = 1 ]'

git -C "$APP" pull -q origin "$BR" 2>/dev/null
check "update (pull) to $NEW: reached" '[ "$(git -C "$APP" rev-parse HEAD)" = "$NEW" ]'
check "update: component survives without recompose" present
check "update: repo pristine" pristine

git -C "$APP" reset -q --hard "$OLD"
check "rollback (reset --hard): component survives" present
check "rollback: repo pristine" pristine

git -C "$APP" checkout -q -- . ; git -C "$APP" checkout -q "$BR"; git -C "$APP" reset -q --hard "origin/$BR"
check "soft recover: component survives" present
check "soft recover: repo pristine" pristine

git -C "$APP" clean -q -d -f
check "git clean -d -f: excluded component survives" present

git clone -q --branch "$BR" --filter=blob:none "$T/origin" "$T/apps/.moonraker_repo_backup" 2>/dev/null \
	|| git clone -q --branch "$BR" "$T/origin" "$T/apps/.moonraker_repo_backup"
rm -rf "$APP"; mv "$T/apps/.moonraker_repo_backup" "$APP"
check "hard recover (re-clone): component gone before restart (expected)" '! present'
restart_moonraker
check "hard recover + S56 start: component back" present
check "hard recover + S56 start: repo pristine" pristine

# Upstream collision: a real file is never replaced.
rm -f "$APP/moonraker/components/nebulaos.py"; echo upstream > "$APP/moonraker/components/nebulaos.py"
compose_moonraker_component "$APP" >/dev/null
check "upstream file of the same name is not replaced" '[ ! -L "$APP/moonraker/components/nebulaos.py" ] && grep -qx upstream "$APP/moonraker/components/nebulaos.py"'

# Wiring.
check "S56 start_daemon composes before starting" \
	'awk "/^start_daemon\\(\\)/{s=1} s&&/compose_component/{c=NR} s&&/start-stop-daemon -S/{print (c&&c<NR)?\"ok\":\"bad\"; exit}" "$S56" | grep -qx ok'
check "S05 composes before the bind mount" \
	'awk "/compose_moonraker_component \"\\\$NEBULAOS_ROOT\\/apps\\/moonraker\"/{c=NR} /bind_if_not_already \"\\\$NEBULAOS_ROOT\\/apps\\/moonraker\"/{print (c&&c<NR)?\"ok\":\"bad\"; exit}" "$S05" | grep -qx ok'

echo "moonraker-component-survival-tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
