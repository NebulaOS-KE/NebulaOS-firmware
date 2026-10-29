#!/usr/bin/env bash
#
# NebulaOS workspace identity gate.
#
# Purpose: prove, mechanically, that this workspace is the CURRENT canonical
# generation of NebulaOS source before any agent or human draws architectural
# conclusions from it.
#
# This exists because a previous audit inspected an obsolete firmware
# generation, never noticed, and still emitted a confident production verdict.
# Any disagreement between local source identity and canonical remote identity
# must invalidate the audit source BEFORE broad investigation begins.
#
# Usage:
#   tools/verify-workspace-identity.sh            # DEV (default): fast, offline
#   tools/verify-workspace-identity.sh --dev      # explicit DEV (--hook is an alias)
#   tools/verify-workspace-identity.sh --local    # strict audit checks, offline
#   tools/verify-workspace-identity.sh --release  # strict + canonical remotes (--full is an alias)
#
# The workspace is in DEV mode unless a human explicitly starts release work.
#
# --dev     fails only on what makes this the wrong WORKSPACE: a missing
#           canonical repo, an archive or legacy authority tree in the active
#           root, the root itself being a git repo. Branches, dirty trees,
#           unpushed commits, extra worktrees, _worktrees/ and _scratch/,
#           control-layer drift and sentinels are reported as WARN, never
#           FAIL. Each operation validates its OWN inputs (a build its source
#           commit and pins, an install its artifact and device).
# --local   the strict checks without the network: canonical branches, one
#           worktree, clean trees, no drift, sentinels.
# --release everything --local checks, plus every HEAD equal to the canonical
#           remote. Release preparation, freeze and qualification use this.
#
# Exit: 0 = valid, 1 = NO.
#
set -uo pipefail
export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0

OFFLINE=0
STRICT_CLEAN=1     # working-tree cleanliness is an audit property, not an identity property
DEV=0
case "${1:-}" in
  ""|--dev|--hook)   DEV=1; OFFLINE=1; STRICT_CLEAN=0 ;;
  --offline|--local) OFFLINE=1 ;;
  --full|--release)  OFFLINE=0 ;;
  *) echo "usage: $(basename "$0") [--dev|--local|--release]" >&2; exit 2 ;;
esac

# ---- Resolve workspace root canonically (never trust $PWD) -----------------
SELF=$(readlink -f "${BASH_SOURCE[0]}")
WORKSPACE_ROOT=$(cd "$(dirname "$SELF")/.." && pwd -P)

FAILURES=(); WARNINGS=()
fail(){ FAILURES+=("$1"); }
# strict: a FAIL for --local/--release, a WARN in DEV. Used for every property
# that is an audit or release concern rather than "is this the right workspace".
strict(){ if [ "$DEV" = 1 ]; then WARNINGS+=("$1"); else FAILURES+=("$1"); fi; }

GH=https://github.com/NebulaOS-KE

# ---- helpers ---------------------------------------------------------------
loc(){ git -C "$1" rev-parse HEAD 2>/dev/null || echo UNRESOLVED; }
brof(){ git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null || echo UNRESOLVED; }
rem(){ git -C "$1" remote get-url origin 2>/dev/null || echo UNRESOLVED; }
dirty(){ # full tree scan is the slow part; the hook gate does not need it
  # Fast mode reports NOT_CHECKED, never 0. Printing "0" for a check that was
  # deliberately skipped states a clean tree as a measured fact - the session
  # banner repeats that figure every session, and it read as evidence of
  # cleanliness while three files were modified. An unmeasured value has to
  # look unmeasured.
  if [ "$STRICT_CLEAN" = 0 ]; then echo NOT_CHECKED; return; fi
  local n; n=$(git -C "$1" status --porcelain 2>/dev/null | wc -l); echo "$n"; }
wtcount(){ git -C "$1" worktree list 2>/dev/null | wc -l; }
lsr(){ # repo branch -> remote sha
  [ "$OFFLINE" = 1 ] && { echo UNRESOLVED_OFFLINE; return; }
  local s; s=$(timeout 60 git ls-remote "$GH/$1.git" "refs/heads/$2" 2>/dev/null | awk '{print $1}')
  [ -n "$s" ] && echo "$s" || echo UNRESOLVED
}
# normalize a remote URL to owner/repo for comparison (.git, ssh, trailing /)
norm(){ printf '%s' "$1" | sed -E 's#^git@github\.com:#https://github.com/#; s#/+$##; s#\.git$##'; }
is_anc(){ git -C "$1" merge-base --is-ancestor "$2" "$3" 2>/dev/null; }

manifest(){ # var -> value from the AUTHORITATIVE shipping manifest
  local f="$WORKSPACE_ROOT/NebulaOS-firmware/manifests/dependencies.conf"
  [ -f "$f" ] || { echo UNRESOLVED; return; }
  local v; v=$(grep -E "^$1=" "$f" | tail -1 | cut -d= -f2-)
  [ -n "$v" ] && echo "$v" || echo UNRESOLVED
}

echo "WORKSPACE_ROOT=$WORKSPACE_ROOT"
if   [ "$DEV" = 1 ];          then echo "MODE=DEV"
elif [ "$OFFLINE" = 1 ];      then echo "MODE=LOCAL_FAST"
else                               echo "MODE=FULL_ONLINE"; fi
echo

# ============================ FIRMWARE ======================================
FW=$WORKSPACE_ROOT/NebulaOS-firmware
FIRMWARE_REMOTE_MAIN=$(lsr NebulaOS-firmware main)
echo "FIRMWARE_PATH=$FW"
echo "FIRMWARE_REMOTE=$(rem "$FW")"
echo "FIRMWARE_BRANCH=$(brof "$FW")"
echo "FIRMWARE_HEAD=$(loc "$FW")"
echo "FIRMWARE_REMOTE_MAIN=$FIRMWARE_REMOTE_MAIN"
echo "FIRMWARE_DIRTY_FILES=$(dirty "$FW")"
echo "FIRMWARE_WORKTREES=$(wtcount "$FW")"
[ -d "$FW/.git" ]                                          || fail "firmware: not a git repository at canonical path"
[ "$(norm "$(rem "$FW")")" = "$(norm "$GH/NebulaOS-firmware")" ] || strict "firmware: remote is not NebulaOS-KE/NebulaOS-firmware"
[ "$(brof "$FW")" = "main" ]                               || strict "firmware: active branch is not main"
[ "$(dirty "$FW")" = "0" ]                                 || [ "$STRICT_CLEAN" = 0 ] || fail "firmware: working tree is not clean"
[ "$(wtcount "$FW")" = "1" ]                               || strict "firmware: more than one working tree"
if [ "$OFFLINE" = 0 ]; then
  [ "$FIRMWARE_REMOTE_MAIN" != UNRESOLVED ]                || fail "firmware: canonical remote main could not be resolved"
  [ "$(loc "$FW")" = "$FIRMWARE_REMOTE_MAIN" ]             || fail "firmware: HEAD != canonical remote main (STALE SOURCE GENERATION)"
fi
echo

# ============================ EXTENSIONS ====================================
EX=$WORKSPACE_ROOT/NebulaOS-klipper-extensions
EXTENSIONS_REMOTE_MAIN=$(lsr NebulaOS-klipper-extensions main)
EXTENSIONS_REMOTE_PRODUCTION=$(lsr NebulaOS-klipper-extensions production)
EXTENSIONS_SHIPPING_BRANCH=$(manifest KLIPPER_EXTENSIONS_BRANCH)
EXTENSIONS_SHIPPING_PIN=$(manifest KLIPPER_EXTENSIONS_PIN)
echo "EXTENSIONS_PATH=$EX"
echo "EXTENSIONS_REMOTE=$(rem "$EX")"
echo "EXTENSIONS_BRANCH=$(brof "$EX")"
echo "EXTENSIONS_HEAD=$(loc "$EX")"
echo "EXTENSIONS_REMOTE_MAIN=$EXTENSIONS_REMOTE_MAIN"
echo "EXTENSIONS_REMOTE_PRODUCTION=$EXTENSIONS_REMOTE_PRODUCTION"
echo "EXTENSIONS_SHIPPING_BRANCH=$EXTENSIONS_SHIPPING_BRANCH"
echo "EXTENSIONS_SHIPPING_PIN=$EXTENSIONS_SHIPPING_PIN"
echo "EXTENSIONS_DIRTY_FILES=$(dirty "$EX")"
[ -d "$EX/.git" ]                                          || fail "extensions: not a git repository at canonical path"
[ "$(norm "$(rem "$EX")")" = "$(norm "$GH/NebulaOS-klipper-extensions")" ] || strict "extensions: remote is not NebulaOS-KE/NebulaOS-klipper-extensions"
[ "$(brof "$EX")" = "main" ]                               || strict "extensions: active branch is not main"
[ "$(dirty "$EX")" = "0" ]                                 || [ "$STRICT_CLEAN" = 0 ] || fail "extensions: working tree is not clean"
[ "$(wtcount "$EX")" = "1" ]                               || strict "extensions: more than one working tree"
# The firmware manifest, not this checkout, decides what actually ships.
[ "$EXTENSIONS_SHIPPING_BRANCH" = "production" ]           || strict "extensions: firmware manifest runtime branch is not 'production' (got '$EXTENSIONS_SHIPPING_BRANCH')"
if [ "$OFFLINE" = 0 ]; then
  [ "$EXTENSIONS_REMOTE_MAIN" != UNRESOLVED ]              || fail "extensions: canonical remote main could not be resolved"
  [ "$(loc "$EX")" = "$EXTENSIONS_REMOTE_MAIN" ]           || fail "extensions: HEAD != canonical remote main (STALE SOURCE GENERATION)"
  [ "$EXTENSIONS_REMOTE_PRODUCTION" != UNRESOLVED ]        || fail "extensions: canonical remote production branch could not be resolved"
  # NOTE: main == production is NOT required. The shipping pin must match the
  # production branch tip; main may legitimately advance ahead of production.
  [ "$EXTENSIONS_SHIPPING_PIN" = "$EXTENSIONS_REMOTE_PRODUCTION" ] \
    || fail "extensions: shipping pin != remote production HEAD (manifest=$EXTENSIONS_SHIPPING_PIN remote=$EXTENSIONS_REMOTE_PRODUCTION)"
fi
echo

# ============================ MCU ===========================================
MC=$WORKSPACE_ROOT/NebulaOS-klipper-mcu
MCU_REMOTE_MAIN=$(lsr NebulaOS-klipper-mcu main)
PROV=$FW/scripts/build/overlay/opt/nebulaos/mcu-candidates/candidate-001.provenance.json
MCU_INTEGRATION_COMMIT=UNRESOLVED; MCU_BIN_SHA_OK=UNRESOLVED
if [ -f "$PROV" ]; then
  MCU_INTEGRATION_COMMIT=$(grep -o '"mcu_repo_commit"[[:space:]]*:[[:space:]]*"[0-9a-f]*"' "$PROV" | grep -o '[0-9a-f]\{40\}')
  want=$(grep -o '"packaged_bin_sha256"[[:space:]]*:[[:space:]]*"[0-9a-f]*"' "$PROV" | grep -o '[0-9a-f]\{64\}')
  got=$(sha256sum "${PROV%.provenance.json}.bin" 2>/dev/null | awk '{print $1}')
  [ -n "$want" ] && [ "$want" = "$got" ] && MCU_BIN_SHA_OK=YES || MCU_BIN_SHA_OK=NO
fi
echo "MCU_PATH=$MC"
echo "MCU_REMOTE=$(rem "$MC")"
echo "MCU_BRANCH=$(brof "$MC")"
echo "MCU_HEAD=$(loc "$MC")"
echo "MCU_REMOTE_MAIN=$MCU_REMOTE_MAIN"
# The MCU is NOT fetched by pin at build time. The firmware vendors a prebuilt
# binary plus a provenance sidecar; that sidecar is the integration authority.
echo "MCU_INTEGRATION_PROVENANCE=VENDORED_PREBUILT_BINARY(candidate-001.bin)@${MCU_INTEGRATION_COMMIT}"
echo "MCU_INTEGRATION_BINARY_SHA256_MATCHES_SIDECAR=$MCU_BIN_SHA_OK"
echo "MCU_DIRTY_FILES=$(dirty "$MC")"
[ -d "$MC/.git" ]                                          || fail "mcu: not a git repository at canonical path"
[ "$(norm "$(rem "$MC")")" = "$(norm "$GH/NebulaOS-klipper-mcu")" ] || strict "mcu: remote is not NebulaOS-KE/NebulaOS-klipper-mcu"
[ "$(brof "$MC")" = "main" ]                               || strict "mcu: active branch is not main"
[ "$(dirty "$MC")" = "0" ]                                 || [ "$STRICT_CLEAN" = 0 ] || fail "mcu: working tree is not clean"
[ "$(wtcount "$MC")" = "1" ]                               || strict "mcu: more than one working tree"
[ "$MCU_BIN_SHA_OK" = YES ]                                || strict "mcu: vendored candidate binary does not match its provenance sidecar sha256"
if [ -n "$MCU_INTEGRATION_COMMIT" ] && [ "$MCU_INTEGRATION_COMMIT" != UNRESOLVED ]; then
  git -C "$MC" cat-file -e "${MCU_INTEGRATION_COMMIT}^{commit}" 2>/dev/null \
    || strict "mcu: integration provenance commit $MCU_INTEGRATION_COMMIT not present in the MCU repository"
fi
if [ "$OFFLINE" = 0 ]; then
  [ "$MCU_REMOTE_MAIN" != UNRESOLVED ]                     || fail "mcu: canonical remote main could not be resolved"
  [ "$(loc "$MC")" = "$MCU_REMOTE_MAIN" ]                  || fail "mcu: HEAD != canonical remote main (STALE SOURCE GENERATION)"
fi
echo

# ============================ KERNEL ========================================
KE=$WORKSPACE_ROOT/NebulaOS-kernel
KERNEL_REMOTE_OPENKE=$(lsr NebulaOS-kernel openke)
KERNEL_SHIPPING_PIN=$(manifest KERNEL_PIN)
echo "KERNEL_PATH=$KE"
echo "KERNEL_REMOTE=$(rem "$KE")"
echo "KERNEL_BRANCH=$(brof "$KE")"
echo "KERNEL_HEAD=$(loc "$KE")"
echo "KERNEL_REMOTE_OPENKE=$KERNEL_REMOTE_OPENKE"
echo "KERNEL_SHIPPING_PIN=$KERNEL_SHIPPING_PIN"
echo "KERNEL_DIRTY_FILES=$(dirty "$KE")"
[ -d "$KE/.git" ]                                          || fail "kernel: not a git repository at canonical path"
[ "$(norm "$(rem "$KE")")" = "$(norm "$GH/NebulaOS-kernel")" ] || strict "kernel: remote is not NebulaOS-KE/NebulaOS-kernel"
[ "$(brof "$KE")" = "openke" ]                             || strict "kernel: active branch is not openke"
[ "$(dirty "$KE")" = "0" ]                                 || [ "$STRICT_CLEAN" = 0 ] || fail "kernel: working tree is not clean"
[ "$(wtcount "$KE")" = "1" ]                               || strict "kernel: more than one working tree"
# The shipping pin is derived from the firmware manifest and MAY legitimately
# be older than the repository HEAD. It must still be a real ancestor.
if [ "$KERNEL_SHIPPING_PIN" != UNRESOLVED ]; then
  if git -C "$KE" cat-file -e "${KERNEL_SHIPPING_PIN}^{commit}" 2>/dev/null; then
    is_anc "$KE" "$KERNEL_SHIPPING_PIN" HEAD || strict "kernel: shipping pin is not an ancestor of the active openke checkout"
  else
    strict "kernel: shipping pin $KERNEL_SHIPPING_PIN not present in the kernel repository"
  fi
fi
if [ "$OFFLINE" = 0 ]; then
  [ "$KERNEL_REMOTE_OPENKE" != UNRESOLVED ]                || fail "kernel: canonical remote openke could not be resolved"
  [ "$(loc "$KE")" = "$KERNEL_REMOTE_OPENKE" ]             || fail "kernel: HEAD != canonical remote openke (STALE SOURCE GENERATION)"
fi
echo

# ============================ GUPPYSCREEN ===================================
# Run 15: GuppyScreen is being renamed NebulaScreen - the checkout, the
# GitHub repo and the manifest variable may carry either name until the
# rename is complete; the output keys stay GUPPYSCREEN_* for compatibility.
GS_NAME=NebulaOS-nebulascreen
[ -d "$WORKSPACE_ROOT/$GS_NAME/.git" ] || GS_NAME=NebulaOS-guppyscreen
GS=$WORKSPACE_ROOT/$GS_NAME
GUPPYSCREEN_REMOTE_MAIN=$(lsr "$GS_NAME" main)
GUPPYSCREEN_SHIPPING_PIN=$(manifest NEBULASCREEN_PIN)
[ "$GUPPYSCREEN_SHIPPING_PIN" = UNRESOLVED ] && GUPPYSCREEN_SHIPPING_PIN=$(manifest GUPPYSCREEN_PIN)
echo "GUPPYSCREEN_PATH=$GS"
echo "GUPPYSCREEN_REMOTE=$(rem "$GS")"
echo "GUPPYSCREEN_BRANCH=$(brof "$GS")"
echo "GUPPYSCREEN_HEAD=$(loc "$GS")"
echo "GUPPYSCREEN_REMOTE_MAIN=$GUPPYSCREEN_REMOTE_MAIN"
echo "GUPPYSCREEN_SHIPPING_PIN=$GUPPYSCREEN_SHIPPING_PIN"
echo "GUPPYSCREEN_DIRTY_FILES=$(dirty "$GS")"
[ -d "$GS/.git" ]                                          || fail "guppyscreen: not a git repository at canonical path"
case "$(norm "$(rem "$GS")")" in
  "$(norm "$GH/NebulaOS-nebulascreen")"|"$(norm "$GH/NebulaOS-guppyscreen")") ;;
  *) strict "guppyscreen: remote is not NebulaOS-KE/NebulaOS-nebulascreen (or -guppyscreen)" ;;
esac
[ "$(brof "$GS")" = "main" ]                               || strict "guppyscreen: active branch is not main"
[ "$(dirty "$GS")" = "0" ]                                 || [ "$STRICT_CLEAN" = 0 ] || fail "guppyscreen: working tree is not clean"
[ "$(wtcount "$GS")" = "1" ]                               || strict "guppyscreen: more than one working tree"
if [ "$GUPPYSCREEN_SHIPPING_PIN" != UNRESOLVED ]; then
  if git -C "$GS" cat-file -e "${GUPPYSCREEN_SHIPPING_PIN}^{commit}" 2>/dev/null; then
    is_anc "$GS" "$GUPPYSCREEN_SHIPPING_PIN" HEAD || strict "guppyscreen: shipping pin is not an ancestor of the active main checkout"
  else
    strict "guppyscreen: shipping pin $GUPPYSCREEN_SHIPPING_PIN not present in the repository"
  fi
fi
if [ "$OFFLINE" = 0 ]; then
  [ "$GUPPYSCREEN_REMOTE_MAIN" != UNRESOLVED ]             || fail "guppyscreen: canonical remote main could not be resolved"
  [ "$(loc "$GS")" = "$GUPPYSCREEN_REMOTE_MAIN" ]          || fail "guppyscreen: HEAD != canonical remote main (STALE SOURCE GENERATION)"
fi
echo

# ============================ HOST KLIPPER ==================================
# Host Klipper is official upstream, owned by the firmware build, never a
# top-level workspace clone, and never the retired NebulaOS-klipper fork.
HOST_KLIPPER_REPO=$(manifest KLIPPER_REPO)
HOST_KLIPPER_PIN=$(manifest KLIPPER_PIN)
echo "HOST_KLIPPER_REPO=$HOST_KLIPPER_REPO"
echo "HOST_KLIPPER_PIN=$HOST_KLIPPER_PIN"
case "$HOST_KLIPPER_REPO" in
  *Klipper3d/klipper*) ;;
  *) fail "host klipper: manifest does not point at official upstream Klipper3d/klipper (got '$HOST_KLIPPER_REPO')";;
esac
[ "$HOST_KLIPPER_PIN" != UNRESOLVED ]                      || fail "host klipper: no shipping pin in the firmware manifest"
echo

# ============================ TOPOLOGY ======================================
EXPECTED=(NebulaOS-firmware NebulaOS-klipper-extensions NebulaOS-klipper-mcu NebulaOS-kernel NebulaOS-nebulascreen NebulaOS-guppyscreen)
ACTIVE_REPO_COUNT=0; UNEXPECTED=()
for d in "$WORKSPACE_ROOT"/*/; do
  name=$(basename "$d")
  [ -e "$d/.git" ] || continue
  keep=0; for e in "${EXPECTED[@]}"; do [ "$name" = "$e" ] && keep=1; done
  if [ "$keep" = 1 ]; then ACTIVE_REPO_COUNT=$((ACTIVE_REPO_COUNT+1)); else UNEXPECTED+=("$name"); fi
done
# A build-generated dependency checkout lives INSIDE NebulaOS-firmware/vendor/
# (gitignored) and is deliberately NOT counted here: it is a build output, not
# a workspace source repository.
echo "ACTIVE_REPO_COUNT=$ACTIVE_REPO_COUNT"
echo "UNEXPECTED_TOPLEVEL_GIT_REPOS=${#UNEXPECTED[@]}${UNEXPECTED[*]:+ (${UNEXPECTED[*]})}"
[ "$ACTIVE_REPO_COUNT" = 5 ]     || fail "topology: expected exactly 5 active source repositories, found $ACTIVE_REPO_COUNT"
[ "${#UNEXPECTED[@]}" = 0 ]      || fail "topology: unexpected top-level git repositories: ${UNEXPECTED[*]}"
# The workspace root itself must not be a repository - that is how historical
# _project/_evidence trees previously re-entered the active workspace.
[ -e "$WORKSPACE_ROOT/.git" ]    && fail "topology: workspace root is itself a git repository"

# _worktrees/ and _scratch/ are SANCTIONED development space (WORKSPACE_RULES
# section 2): they never hold canonical source, so their presence is fine.
FORBIDDEN=(_project _evidence NebulaOS-klipper NebulaOS roadmap \
           RC2-MANIFEST.txt FINAL-PREHW-RC-MANIFEST.txt PROJECT_CONTEXT.md)
HITS=()
for f in "${FORBIDDEN[@]}"; do [ -e "$WORKSPACE_ROOT/$f" ] && HITS+=("$f"); done
echo "FORBIDDEN_ACTIVE_PATHS=${#HITS[@]}${HITS[*]:+ (${HITS[*]})}"
[ "${#HITS[@]}" = 0 ]            || fail "topology: legacy/authoritative-looking paths present in active root: ${HITS[*]}"

# Archived workspaces must never be reachable as active source.
ARCH=$(find "$WORKSPACE_ROOT" -maxdepth 1 -name 'NebulaOS-archive-*' 2>/dev/null | wc -l)
echo "ARCHIVE_DIRS_INSIDE_ACTIVE_ROOT=$ARCH"
[ "$ARCH" = 0 ]                  || fail "topology: an archive directory is nested inside the active workspace"

REQUIRED=(AGENTS.md CLAUDE.md CURRENT_STATE.md WORKSPACE_RULES.md README.md)
MISSING=()
for f in "${REQUIRED[@]}"; do [ -f "$WORKSPACE_ROOT/$f" ] || MISSING+=("$f"); done
echo "MISSING_ROOT_AUTHORITY_FILES=${#MISSING[@]}${MISSING[*]:+ (${MISSING[*]})}"
[ "${#MISSING[@]}" = 0 ]         || fail "root: missing authority files: ${MISSING[*]}"

# ==================== WORKSPACE CONTROL LAYER =============================
# Root authority files and .claude/ are DERIVED STATE installed from the
# version-controlled canonical source in NebulaOS-firmware. Drift here is how
# an unreviewed authority island would form at a root that is not a git repo.
CANON=$WORKSPACE_ROOT/NebulaOS-firmware/tools/workspace-control
MANIFEST=$CANON/MANIFEST
WORKSPACE_CONTROL_VALID=YES
CONTROL_DRIFTED=(); CONTROL_MISSING=(); CONTROL_CHECKED=0

if [ ! -f "$MANIFEST" ]; then
  WORKSPACE_CONTROL_VALID=NO
  fail "control: canonical MANIFEST missing at $MANIFEST"
else
  # Collect first, hash once. This loop used to fork sha256sum+awk per side per
  # manifest line - 60 processes for 15 files, ~60ms, on a gate the PreToolUse
  # hook runs before EVERY Bash/Edit/Write. The comparison below is byte for
  # byte the same SHA-256 over the same files; only the process count changed.
  CAN_PATHS=(); INS_PATHS=(); INS_NAMES=()
  while read -r src dst mode; do
    case "$src" in ''|\#*) continue;; esac
    [ -n "${dst:-}" ] || continue
    CONTROL_CHECKED=$((CONTROL_CHECKED+1))
    if [ ! -f "$WORKSPACE_ROOT/$dst" ]; then
      CONTROL_MISSING+=("$dst"); WORKSPACE_CONTROL_VALID=NO; continue
    fi
    CAN_PATHS+=("$CANON/$src"); INS_PATHS+=("$WORKSPACE_ROOT/$dst"); INS_NAMES+=("$dst")
  done < "$MANIFEST"

  if [ "${#CAN_PATHS[@]}" -gt 0 ]; then
    # sha256sum emits one line per argument, in argument order.
    mapfile -t CAN_H < <(sha256sum "${CAN_PATHS[@]}" 2>/dev/null | cut -d' ' -f1)
    mapfile -t INS_H < <(sha256sum "${INS_PATHS[@]}" 2>/dev/null | cut -d' ' -f1)
    # FAIL CLOSED: a short read means some file could not be hashed. Do not
    # guess which one - refuse the whole layer rather than silently checking
    # fewer files than the manifest lists.
    if [ "${#CAN_H[@]}" -ne "${#CAN_PATHS[@]}" ] || [ "${#INS_H[@]}" -ne "${#INS_PATHS[@]}" ]; then
      WORKSPACE_CONTROL_VALID=NO
      CONTROL_DRIFTED+=("(unhashable: canonical=${#CAN_H[@]}/${#CAN_PATHS[@]} installed=${#INS_H[@]}/${#INS_PATHS[@]})")
    else
      for i in "${!CAN_PATHS[@]}"; do
        if [ -z "${CAN_H[$i]}" ] || [ "${CAN_H[$i]}" != "${INS_H[$i]}" ]; then
          CONTROL_DRIFTED+=("${INS_NAMES[$i]}"); WORKSPACE_CONTROL_VALID=NO
        fi
      done
    fi
  fi
fi

echo "CONTROL_FILES_CHECKED=$CONTROL_CHECKED"
echo "CONTROL_FILES_DRIFTED=${#CONTROL_DRIFTED[@]}${CONTROL_DRIFTED[*]:+ (${CONTROL_DRIFTED[*]})}"
echo "CONTROL_FILES_MISSING=${#CONTROL_MISSING[@]}${CONTROL_MISSING[*]:+ (${CONTROL_MISSING[*]})}"
echo "WORKSPACE_CONTROL_VALID=$WORKSPACE_CONTROL_VALID"
if [ "$WORKSPACE_CONTROL_VALID" = NO ]; then
  [ "${#CONTROL_DRIFTED[@]}" -gt 0 ] && strict "control: root files drifted from canonical: ${CONTROL_DRIFTED[*]}"
  [ "${#CONTROL_MISSING[@]}" -gt 0 ] && strict "control: root files missing: ${CONTROL_MISSING[*]}"
  echo "  -> repair deliberately with: tools/sync-workspace-control.sh --apply"
fi
echo

# ==================== LAUNCH SENTINELS ====================================
# Each active repo carries a machine-local sentinel so that launching Claude
# with the repo (not the workspace root) as primary project cannot silently
# bypass the root guardrails. Machine-local by design: git-excluded, never
# committed, reproduced by the sync script.
SENTINEL_SRC=$CANON/sentinel/settings.local.json
SENTINELS_OK=0; SENTINELS_BAD=()
for e in NebulaOS-firmware NebulaOS-klipper-extensions NebulaOS-klipper-mcu NebulaOS-kernel "$GS_NAME"; do
  t=$WORKSPACE_ROOT/$e/.claude/settings.local.json
  if [ ! -f "$t" ]; then SENTINELS_BAD+=("$e:missing"); continue; fi
  if [ -f "$SENTINEL_SRC" ] && ! cmp -s "$SENTINEL_SRC" "$t"; then SENTINELS_BAD+=("$e:drifted"); continue; fi
  # must be git-excluded so it never dirties the repository
  if ! grep -qx '\.claude/' "$WORKSPACE_ROOT/$e/.git/info/exclude" 2>/dev/null; then
    SENTINELS_BAD+=("$e:not-git-excluded"); continue
  fi
  SENTINELS_OK=$((SENTINELS_OK+1))
done
echo "LAUNCH_SENTINELS_OK=$SENTINELS_OK/5"
echo "LAUNCH_SENTINELS_BAD=${#SENTINELS_BAD[@]}${SENTINELS_BAD[*]:+ (${SENTINELS_BAD[*]})}"
[ "${#SENTINELS_BAD[@]}" = 0 ] || strict "sentinels: ${SENTINELS_BAD[*]}"
echo
if [ "$STRICT_CLEAN" = 0 ]; then
  echo "DIRTY_ACTIVE_REPOS=NOT_CHECKED"
else
  DIRTY_ACTIVE_REPOS=0
  for e in "${EXPECTED[@]}"; do
    [ -d "$WORKSPACE_ROOT/$e/.git" ] || continue
    [ "$(dirty "$WORKSPACE_ROOT/$e")" = "0" ] || DIRTY_ACTIVE_REPOS=$((DIRTY_ACTIVE_REPOS+1))
  done
  echo "DIRTY_ACTIVE_REPOS=$DIRTY_ACTIVE_REPOS"
fi
# Dirty trees are normal mid-development. They matter for an audit, never for
# deciding whether this is the right source generation - so the PreToolUse
# gate must not block edits just because an edit already happened.
echo

# ============================ VERDICT =======================================
echo "WORKSPACE_MODE=$([ "$DEV" = 1 ] && echo DEV || { [ "$OFFLINE" = 1 ] && echo LOCAL_AUDIT || echo RELEASE; })"
if [ "${#WARNINGS[@]}" -gt 0 ]; then
  echo "WARNINGS=${#WARNINGS[@]}"
  for w in "${WARNINGS[@]}"; do echo "  WARN: $w"; done
fi
if [ "${#FAILURES[@]}" -eq 0 ]; then
  if [ "$DEV" = 1 ]; then
    echo "DEV_IDENTITY_VALID=YES"
    echo "WORKSPACE_IDENTITY_VALID=DEV"
    echo "AUDIT_VERDICT=DEV_WORKSPACE_OK_NOT_AN_AUDIT"
    exit 0
  fi
  if [ "$OFFLINE" = 1 ]; then
    # A local run proves what it checked and does not overclaim.
    echo "LOCAL_IDENTITY_VALID=YES"
    echo "WORKSPACE_IDENTITY_VALID=LOCAL_ONLY"
    echo "AUDIT_VERDICT=LOCAL_CHECKS_PASSED_NETWORK_NOT_CHECKED"
    exit 0
  fi
  echo "LOCAL_IDENTITY_VALID=YES"
  echo "WORKSPACE_IDENTITY_VALID=YES"
  echo "AUDIT_SOURCE_IDENTITY_VALID=YES"
  echo "AUDIT_VERDICT=VALID_SOURCE_GENERATION"
  exit 0
fi
[ "$DEV" = 1 ] && echo "DEV_IDENTITY_VALID=NO"
echo "IDENTITY_FAILURES=${#FAILURES[@]}"
for f in "${FAILURES[@]}"; do echo "  FAIL: $f"; done
echo "LOCAL_IDENTITY_VALID=NO"
echo "WORKSPACE_IDENTITY_VALID=NO"
echo "AUDIT_SOURCE_IDENTITY_VALID=NO"
echo "AUDIT_VERDICT=INVALID"
echo
echo "STOP. Do not audit, and do not draw architectural conclusions from this"
echo "workspace. Do not switch to another local checkout, and do not rationalize"
echo "the contradiction. Resolve source identity first."
exit 1
