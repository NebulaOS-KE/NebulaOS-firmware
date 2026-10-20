#!/usr/bin/env bash
#
# SessionStart hook - inject a SMALL, current identity summary.
#
# Purpose: architectural identity must be present in context from the first
# token, and must survive compaction. This deliberately injects facts only -
# no project history, no narrative. Pages of history are what caused agents to
# reason from stale prose in the first place.
#
#   session-start.sh             startup | resume | clear
#   session-start.sh --compact   after compaction
#
# Both use the DEV gate: fast and offline. The online canonical-remote check is
# a RELEASE concern (tools/verify-workspace-identity.sh --release).
#
# Never blocks a session: a hook that hard-fails on startup would make the
# workspace unusable offline. It reports status; PreToolUse is what fails closed.
#
set -uo pipefail
export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0

COMPACT=0; [ "${1:-}" = "--compact" ] && COMPACT=1
ROOT=${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd -P)}
cd "$ROOT" 2>/dev/null || exit 0

man(){ local v; v=$(grep -E "^$1=" "$ROOT/NebulaOS-firmware/manifests/dependencies.conf" 2>/dev/null | tail -1 | cut -d= -f2-); echo "${v:-UNRESOLVED}"; }
head_of(){ git -C "$ROOT/$1" rev-parse HEAD 2>/dev/null || echo UNRESOLVED; }
br_of(){ git -C "$ROOT/$1" rev-parse --abbrev-ref HEAD 2>/dev/null || echo UNRESOLVED; }

GATE=$("$ROOT/tools/verify-workspace-identity.sh" --dev 2>&1)
if [ "$COMPACT" = 1 ]; then MODE="post-compaction re-injection"; else MODE="session start"; fi
IDENT=$(printf '%s\n' "$GATE" | grep -E '^(DEV_IDENTITY_VALID)=' | tail -1)
WARNS=$(printf '%s\n' "$GATE" | grep -E '^\s+WARN:' | head -6)
CTRL=$(printf '%s\n' "$GATE" | grep -E '^WORKSPACE_CONTROL_VALID=' | tail -1)
SENT=$(printf '%s\n' "$GATE" | grep -E '^LAUNCH_SENTINELS_OK=' | tail -1)

ARCH=$("$ROOT/tools/verify-architecture.sh" --quick 2>&1 | grep -E '^(ARCHITECTURE_INVARIANTS_VALID|INVARIANTS_(PASS|FAIL|DOCUMENTED_ONLY))=' | tr '\n' ' ')

# --- build / qualification status, DERIVED ---------------------------------
# These two lines used to be hard-coded NO. A constant is not a status: it kept
# reporting NO after a build had in fact been verified, and would have kept
# reporting NO forever, which trains a reader to ignore the line entirely.
#
# CURRENT_HEAD_BUILD_VERIFIED is now answered by the build launcher's own
# attestation (.nebulaos-build-verified, written only on a clean successful
# build) for the CURRENT firmware HEAD. A build of some earlier generation is
# deliberately not evidence about this one - the whole point of the field is to
# say whether THIS source has been built.
#
# Bounded on purpose: a plain glob over one directory, no find, no du, no
# network. This runs at session start and must stay cheap.
FW_HEAD=$(head_of NebulaOS-firmware)
# A build is current when its PRODUCT inputs equal HEAD's - a tooling-only
# commit (Hardware Agent, tests, docs) does not make the last build stale.
PB=$(python3 "$ROOT/NebulaOS-firmware/tools/product-inputs.py" current-build HEAD 2>/dev/null)
pbget(){ printf '%s\n' "$PB" | grep -m1 "^$1=" | cut -d= -f2-; }
if [ "$(pbget PRODUCT_BUILD_CURRENT)" = YES ]; then
  BUILD_LINE="PRODUCT_BUILD_CURRENT=YES (built $(pbget BUILD_SOURCE_HEAD | cut -c1-12), mode=$(pbget BUILD_MODE), $(pbget BUILD_RUN))"
else
  BUILD_LINE="PRODUCT_BUILD_CURRENT=NO (no build whose product inputs equal HEAD's)"
fi

HW_QUALIFIED=NO
[ "$FW_HEAD" != UNRESOLVED ] \
  && [ -f "$ROOT/evidence/hardware-qualification/$FW_HEAD/QUALIFIED" ] \
  && HW_QUALIFIED=YES

CAND=$ROOT/NebulaOS-firmware/scripts/build/overlay/opt/nebulaos/mcu-candidates/candidate-001.bin
MCUPROV=UNRESOLVED
if [ -f "$CAND" ]; then
  w=$(grep -o '"packaged_bin_sha256"[[:space:]]*:[[:space:]]*"[0-9a-f]*"' "${CAND%.bin}.provenance.json" 2>/dev/null | grep -o '[0-9a-f]\{64\}')
  g=$(sha256sum "$CAND" 2>/dev/null | awk '{print $1}')
  [ -n "$w" ] && [ "$w" = "$g" ] && MCUPROV="VENDORED_ARTIFACT_SHA_OK" || MCUPROV="SHA_MISMATCH"
fi

cat <<EOF
NEBULAOS WORKSPACE - $MODE

WORKSPACE_MODE=DEV   (RELEASE only when the human explicitly starts release work)
${IDENT:-DEV_IDENTITY_VALID=UNRESOLVED}
${CTRL:-WORKSPACE_CONTROL_VALID=UNRESOLVED}
${SENT:-LAUNCH_SENTINELS_OK=UNRESOLVED}
$ARCH

firmware        $(br_of NebulaOS-firmware) $(head_of NebulaOS-firmware)
extensions main $(head_of NebulaOS-klipper-extensions)
extensions ship branch=$(man KLIPPER_EXTENSIONS_BRANCH) pin=$(man KLIPPER_EXTENSIONS_PIN)
host klipper    $(man KLIPPER_REPO) pin=$(man KLIPPER_PIN)
kernel          HEAD=$(head_of NebulaOS-kernel) pin=$(man KERNEL_PIN)
screen          HEAD=$(if [ -d "$ROOT/NebulaOS-nebulascreen/.git" ]; then head_of NebulaOS-nebulascreen; else head_of NebulaOS-guppyscreen; fi) pin=$(p=$(man NEBULASCREEN_PIN); [ "$p" = UNRESOLVED ] && p=$(man GUPPYSCREEN_PIN); echo "$p")
mcu             HEAD=$(head_of NebulaOS-klipper-mcu) provenance=$MCUPROV

$BUILD_LINE
HARDWARE_QUALIFIED=$HW_QUALIFIED
${WARNS:+
DEV warnings (informational, never blocking):
$WARNS}

Rules: architecture is not memory - derive it from source, the firmware
manifest and tools/verify-architecture.sh. REPOSITORY_HEAD != SHIPPING_PIN.
DEV: edit, test, commit freely. Strict only at the printer, the privilege
boundary, and explicitly requested RELEASE work. The archive is blocked.
EOF
exit 0
