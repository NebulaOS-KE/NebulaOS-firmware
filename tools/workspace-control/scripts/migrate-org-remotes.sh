#!/bin/sh
# Run 23 (2026-10-29): the repositories moved from github.com/coreflake1 to the
# NebulaOS-KE organisation. Run ONCE by Tim (git config and .gitmodules are
# write-protected for the agent on purpose):
#
#   1. every workspace repository's origin -> https://github.com/NebulaOS-KE/<name>
#   2. NebulaOS-nebulascreen/.gitmodules: lv_drivers -> NebulaOS-KE (+ submodule sync)
#   3. install the workspace control (apply-workspace-control.sh), which verifies
#      the identity against the new remotes
#
# Idempotent: a remote or URL that already points at NebulaOS-KE is left alone.
set -eu

WS=$(cd "$(dirname "$0")/../../../.." && pwd)
OLD=https://github.com/coreflake1/
NEW=https://github.com/NebulaOS-KE/

echo "WORKSPACE_ROOT=$WS"
for r in NebulaOS-firmware NebulaOS-kernel NebulaOS-klipper-extensions NebulaOS-klipper-mcu NebulaOS-nebulascreen; do
  [ -d "$WS/$r/.git" ] || { echo "SKIP $r (not here)"; continue; }
  url=$(git -C "$WS/$r" remote get-url origin)
  case "$url" in
    "$NEW"*) echo "OK   $r $url" ;;
    "$OLD"*) new="$NEW${url#"$OLD"}"
             git -C "$WS/$r" remote set-url origin "$new"
             echo "SET  $r $new" ;;
    *)       echo "FAIL $r: unexpected origin $url" >&2; exit 1 ;;
  esac
  git -C "$WS/$r" ls-remote --exit-code origin HEAD >/dev/null \
    || { echo "FAIL $r: $(git -C "$WS/$r" remote get-url origin) does not answer" >&2; exit 1; }
done

GM="$WS/NebulaOS-nebulascreen/.gitmodules"
if grep -q "github.com/coreflake1/lv_drivers" "$GM"; then
  sed -i 's#https://github.com/coreflake1/lv_drivers#https://github.com/NebulaOS-KE/lv_drivers#' "$GM"
  git -C "$WS/NebulaOS-nebulascreen" submodule sync --quiet
  echo "SET  .gitmodules lv_drivers -> NebulaOS-KE (the agent commits it)"
else
  echo "OK   .gitmodules lv_drivers"
fi

echo
sh "$WS/NebulaOS-firmware/tools/workspace-control/scripts/apply-workspace-control.sh"
echo "MIGRATE_ORG_REMOTES=PASS"
