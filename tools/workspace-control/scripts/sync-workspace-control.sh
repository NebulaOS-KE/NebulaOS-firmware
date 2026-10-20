#!/usr/bin/env bash
#
# Install the NebulaOS workspace control layer from its version-controlled
# canonical source into the (deliberately non-git) workspace root.
#
#   tools/sync-workspace-control.sh            # DRY RUN - show what would change
#   tools/sync-workspace-control.sh --apply    # actually install
#
# This is the ONE explicit command that is allowed to overwrite root authority
# and .claude/ state. Ordinary verification never repairs drift: silently
# healing a modified root would destroy the evidence that something changed it.
#
# It also installs the machine-local launch sentinels into each active repo and
# git-excludes them, so they never dirty a repository and are never committed.
#
set -uo pipefail
export GIT_OPTIONAL_LOCKS=0

APPLY=0
case "${1:-}" in
  --apply) APPLY=1 ;;
  ""|--dry-run) APPLY=0 ;;
  *) echo "usage: $(basename "$0") [--apply]" >&2; exit 2 ;;
esac

SELF=$(readlink -f "${BASH_SOURCE[0]}")
# Canonical source is resolved from THIS script's real location, so running the
# installed copy at tools/ and the canonical copy in the repo behave identically.
if [ -f "$(dirname "$SELF")/../MANIFEST" ]; then
  CANON=$(cd "$(dirname "$SELF")/.." && pwd -P)                       # canonical copy
  WORKSPACE_ROOT=$(cd "$CANON/../../.." && pwd -P)
else
  WORKSPACE_ROOT=$(cd "$(dirname "$SELF")/.." && pwd -P)              # installed copy at tools/
  CANON=$WORKSPACE_ROOT/NebulaOS-firmware/tools/workspace-control
fi
MANIFEST=$CANON/MANIFEST

echo "CANONICAL_SOURCE=$CANON"
echo "WORKSPACE_ROOT=$WORKSPACE_ROOT"
echo "MODE=$([ "$APPLY" = 1 ] && echo APPLY || echo DRY_RUN)"
echo

[ -f "$MANIFEST" ] || { echo "FATAL: MANIFEST not found at $MANIFEST"; exit 1; }
[ -d "$WORKSPACE_ROOT/NebulaOS-firmware" ] || { echo "FATAL: not a NebulaOS workspace root: $WORKSPACE_ROOT"; exit 1; }

CHANGED=0; SAME=0; FAILED=0
while read -r src dst mode; do
  case "$src" in ''|\#*) continue;; esac
  [ -n "${dst:-}" ] || continue
  s=$CANON/$src; d=$WORKSPACE_ROOT/$dst
  if [ ! -f "$s" ]; then echo "  MISSING_CANONICAL  $src"; CHANGED=$((CHANGED+1)); continue; fi
  if [ -f "$d" ] && cmp -s "$s" "$d"; then
    SAME=$((SAME+1))
    # mode can drift independently of content
    cur=$(stat -c %a "$d"); [ "$cur" = "$mode" ] || { echo "  CHMOD   $dst ($cur -> $mode)"; CHANGED=$((CHANGED+1)); [ "$APPLY" = 1 ] && { chmod "$mode" "$d" 2>/dev/null || { echo "  INSTALL_FAILED  $dst (mode)"; FAILED=$((FAILED+1)); }; }; }
    continue
  fi
  if [ -f "$d" ]; then echo "  UPDATE  $dst"; else echo "  CREATE  $dst"; fi
  CHANGED=$((CHANGED+1))
  if [ "$APPLY" = 1 ]; then
    # An installer that prints APPLIED while cp failed is worse than one that
    # fails: it hides drift behind a success line. Claude's sandbox makes
    # .claude/hooks read-only, so this path DOES fail in normal operation.
    # Install through a temp file and rename, NEVER by writing the
    # destination in place. This script is itself one of the files it
    # installs: bash reads a script lazily by byte offset, so overwriting the
    # live file makes the running shell continue at a stale offset into new
    # content. Observed directly - it produced a bogus "unbound variable" on
    # a line the running version had never reached. rename() swaps the
    # directory entry while the running shell keeps its original inode.
    tmp=$d.sync-tmp.$$
    if ! mkdir -p "$(dirname "$d")" 2>/dev/null \
    || ! cp "$s" "$tmp" 2>/dev/null \
    || ! chmod "$mode" "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$d" 2>/dev/null; then
      echo "  INSTALL_FAILED  $dst"
      FAILED=$((FAILED+1))
      rm -f "$tmp" 2>/dev/null
    fi
  fi
done < "$MANIFEST"

# --- machine-local launch sentinels ----------------------------------------
SENTINEL_SRC=$CANON/sentinel/settings.local.json
echo
if [ -f "$SENTINEL_SRC" ]; then
  for e in NebulaOS-firmware NebulaOS-klipper-extensions NebulaOS-klipper-mcu NebulaOS-kernel NebulaOS-nebulascreen NebulaOS-guppyscreen; do
    repo=$WORKSPACE_ROOT/$e
    [ -d "$repo/.git" ] || continue
    t=$repo/.claude/settings.local.json
    if [ -f "$t" ] && cmp -s "$SENTINEL_SRC" "$t"; then :; else
      echo "  SENTINEL $e/.claude/settings.local.json"
      CHANGED=$((CHANGED+1))
      if [ "$APPLY" = 1 ]; then
        if ! mkdir -p "$repo/.claude" 2>/dev/null \
        || ! cp "$SENTINEL_SRC" "$t" 2>/dev/null \
        || ! chmod 644 "$t" 2>/dev/null; then
          echo "  INSTALL_FAILED  $e/.claude/settings.local.json"
          FAILED=$((FAILED+1))
        fi
      fi
    fi
    # git-exclude machine-local tool state so the repo never goes dirty and it
    # is never committed. .mcp.json is written by the editor's MCP integration
    # at whatever depth it is opened, so the pattern is intentionally
    # unanchored. These files are not ours and must not enter history, but a
    # dirty tree blocks the build launcher's clean-source precondition.
    exc=$repo/.git/info/exclude
    for pat in '.claude/' '.mcp.json'; do
      if ! grep -qxF "$pat" "$exc" 2>/dev/null; then
        echo "  GIT_EXCLUDE $e/.git/info/exclude += $pat"
        CHANGED=$((CHANGED+1))
        if [ "$APPLY" = 1 ]; then mkdir -p "$(dirname "$exc")"; printf '%s\n' "$pat" >> "$exc"; fi
      fi
    done
  done
else
  echo "  (no sentinel template at $SENTINEL_SRC)"
fi

echo
echo "UNCHANGED=$SAME"
echo "CHANGED=$CHANGED"
echo "INSTALL_FAILURES=$FAILED"
if [ "$APPLY" = 1 ]; then
  if [ "$FAILED" -gt 0 ]; then
    echo "SYNC=FAILED"
    echo "$FAILED file(s) could not be installed. The root is NOT in sync, and the"
    echo "identity gate will keep reporting drift until they are."
    echo
    echo "If the failure is 'Read-only file system' under .claude/, Claude's own Bash"
    echo "sandbox denies that path. Re-run this exact command outside the sandbox."
    exit 1
  fi
  echo "SYNC=APPLIED"
  echo "Next: tools/verify-workspace-identity.sh"
else
  echo "SYNC=DRY_RUN"
  [ "$CHANGED" -gt 0 ] && echo "Re-run with --apply to install." || echo "Root is already in sync with canonical."
fi
exit 0
