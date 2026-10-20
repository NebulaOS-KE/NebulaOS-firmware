#!/usr/bin/env bash
#
# NebulaOS architecture invariant verification.
#
# This is NOT the identity gate. They answer different questions:
#
#   identity     -> am I looking at the right source generation?
#   architecture -> does this source still satisfy the frozen NebulaOS architecture?
#
# Every invariant below is derived MECHANICALLY from current source. Where an
# invariant cannot be checked honestly, it is reported DOCUMENTED_ONLY rather
# than given a test that would pass for the wrong reason. A green test that
# proves nothing is worse than an honest gap.
#
# Usage:
#   tools/verify-architecture.sh            # full
#   tools/verify-architecture.sh --quick    # skip the slower tree scans
#
# Exit: 0 = ARCHITECTURE_INVARIANTS_VALID=YES, 1 = NO.
#
set -uo pipefail
export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0

QUICK=0; [ "${1:-}" = "--quick" ] && QUICK=1

SELF=$(readlink -f "${BASH_SOURCE[0]}")
WORKSPACE_ROOT=$(cd "$(dirname "$SELF")/.." && pwd -P)
FW=$WORKSPACE_ROOT/NebulaOS-firmware
EX=$WORKSPACE_ROOT/NebulaOS-klipper-extensions
MC=$WORKSPACE_ROOT/NebulaOS-klipper-mcu
DEPS=$FW/manifests/dependencies.conf

PASS=0; FAILN=0; DOCONLY=0
FAILURES=()

ok(){   PASS=$((PASS+1));       printf 'INV %-46s PASS   %s\n' "$1" "${2:-}"; }
bad(){  FAILN=$((FAILN+1)); FAILURES+=("$1: $2"); printf 'INV %-46s FAIL   %s\n' "$1" "$2"; }
doc(){  DOCONLY=$((DOCONLY+1)); printf 'INV %-46s DOCUMENTED_ONLY  %s\n' "$1" "${2:-}"; }

man(){ local v; v=$(grep -E "^$1=" "$DEPS" 2>/dev/null | tail -1 | cut -d= -f2-); echo "${v:-UNRESOLVED}"; }

echo "ARCHITECTURE_VERIFICATION"
echo "WORKSPACE_ROOT=$WORKSPACE_ROOT"
echo "SOURCE_OF_TRUTH=$DEPS"
echo "MODE=$([ "$QUICK" = 1 ] && echo quick || echo full)"
echo

[ -f "$DEPS" ] || { echo "FATAL: dependency manifest not found"; echo "ARCHITECTURE_INVARIANTS_VALID=NO"; exit 1; }

# --- 1. Host Klipper is official upstream ----------------------------------
KREPO=$(man KLIPPER_REPO); KPIN=$(man KLIPPER_PIN)
case "$KREPO" in
  *Klipper3d/klipper*) ok "host-klipper-is-official-upstream" "$KREPO";;
  *) bad "host-klipper-is-official-upstream" "manifest points at '$KREPO', not Klipper3d/klipper";;
esac
[ "$KPIN" != UNRESOLVED ] && ok "host-klipper-pinned" "$KPIN" \
                          || bad "host-klipper-pinned" "no KLIPPER_PIN in manifest"

# --- 2. Zero host Klipper core patches -------------------------------------
# Mechanically: the build must not apply any patch to the Klipper checkout.
# Look for a klipper patch directory with content, and for any patch/apply
# step aimed at the klipper vendor tree.
KPATCH_FILES=0
[ -d "$FW/patches" ] && KPATCH_FILES=$(find "$FW/patches" -iname '*klipper*' -type f 2>/dev/null | grep -vi 'mcu\|extensions' | wc -l)
KPATCH_APPLY=$(grep -rnE '(git +apply|patch +-p[0-9])' "$FW/scripts/build/"*.sh 2>/dev/null \
               | grep -i 'klipper' | grep -viE 'mcu|extension|^\s*#' | wc -l)
if [ "$KPATCH_FILES" = 0 ] && [ "$KPATCH_APPLY" = 0 ]; then
  ok "host-klipper-zero-core-patches" "no klipper patch files, no apply steps"
else
  bad "host-klipper-zero-core-patches" "patch_files=$KPATCH_FILES apply_steps=$KPATCH_APPLY"
fi

# --- 3. Retired NebulaOS-klipper fork is not active ------------------------
# Only an ACTIVE reference counts. Every current mention of the retired fork in
# this repo is explanatory prose ("migrated away from ...") - counting comments
# would fail the invariant for documenting the very thing it asserts.
RET_TOP=0; [ -e "$WORKSPACE_ROOT/NebulaOS-klipper" ] && RET_TOP=1
# a) no manifest variable resolves to it
# NOTE: 'NebulaOS-klipper\b' would also match NebulaOS-klipper-extensions,
# because '-' is a word boundary. Exclude the legitimate siblings explicitly.
RET_PIN=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$DEPS" 2>/dev/null \
          | grep -iE 'NebulaOS-klipper(\.git|/|$|[^-])' \
          | grep -viE 'NebulaOS-klipper-(extensions|mcu)' | wc -l)
# b) no script clones/fetches it outside a comment
RET_FETCH=$(grep -rhE '(git +(clone|fetch|remote)|_REPO=)[^#]*NebulaOS-klipper' "$FW/scripts/build/" 2>/dev/null \
            | grep -vE '^\s*#' | grep -viE 'NebulaOS-klipper-(extensions|mcu)' | wc -l)
RET_PROSE=$(grep -rlE 'coreflake1/NebulaOS-klipper' "$FW/scripts/build/" "$DEPS" 2>/dev/null | wc -l)
if [ "$RET_TOP" = 0 ] && [ "$RET_PIN" = 0 ] && [ "$RET_FETCH" = 0 ]; then
  ok "retired-nebulaos-klipper-not-active" "no checkout, no pin, no fetch (${RET_PROSE} files mention it in prose only)"
else
  bad "retired-nebulaos-klipper-not-active" "checkout=$RET_TOP manifest_pin=$RET_PIN fetch_refs=$RET_FETCH"
fi

# --- 4. Extensions are the host customization layer ------------------------
EREPO=$(man KLIPPER_EXTENSIONS_REPO); EBRANCH=$(man KLIPPER_EXTENSIONS_BRANCH); EPIN=$(man KLIPPER_EXTENSIONS_PIN)
case "$EREPO" in
  *coreflake1/NebulaOS-klipper-extensions*) ok "extensions-are-host-customization-layer" "$EREPO";;
  *) bad "extensions-are-host-customization-layer" "unexpected repo '$EREPO'";;
esac
# Composition manifest must exist and be the module authority.
if [ -f "$EX/nebulaos-extensions.json" ]; then
  NMOD=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(len(d.get("modules",[])))' "$EX/nebulaos-extensions.json" 2>/dev/null || echo 0)
  NRUN=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(sum(1 for m in d.get("modules",[]) if m.get("role")=="runtime"))' "$EX/nebulaos-extensions.json" 2>/dev/null || echo 0)
  APIL=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("nebulaos_api_level","?"))' "$EX/nebulaos-extensions.json" 2>/dev/null || echo '?')
  if [ "$NMOD" -gt 0 ]; then
    ok "extensions-composition-manifest-present" "${NMOD} modules (${NRUN} runtime), api_level=${APIL}"
  else
    bad "extensions-composition-manifest-present" "manifest parsed but declares no modules"
  fi
else
  bad "extensions-composition-manifest-present" "nebulaos-extensions.json missing"
fi

# --- 5. Extensions production branch/pin semantics -------------------------
if [ "$EBRANCH" = production ]; then
  ok "extensions-runtime-branch-is-production" "KLIPPER_EXTENSIONS_BRANCH=production"
else
  bad "extensions-runtime-branch-is-production" "manifest says '$EBRANCH'"
fi
if [ "$EPIN" != UNRESOLVED ] && git -C "$EX" cat-file -e "${EPIN}^{commit}" 2>/dev/null; then
  ok "extensions-shipping-pin-resolvable" "$EPIN"
else
  bad "extensions-shipping-pin-resolvable" "pin '$EPIN' not a commit in the extensions repo"
fi

# --- 6. Moonraker: official upstream + allowlisted patches only ------------
# NebulaOS ships OFFICIAL upstream Moonraker and never touches the
# vendor/moonraker checkout - but it DOES apply exactly one reviewed,
# named, build-time patch to the OVERLAY COPY. The invariant that used to
# live here was called "moonraker-unmodified" and reported PASS while that
# patch was applied on every build, because it was blind three separate
# ways: the regex required `-p<digit>` immediately after `patch` (the real
# call is `patch -N -p1`), the glob was non-recursive so scripts/build/lib/
# was never scanned, and the `grep -vE '^\s*#'` comment filter could never
# match because `grep -rn` prefixes every line with `file:lineno:`.
#
# This is NOT general permission to patch or fork Moonraker. The allowlist
# below has exactly one entry, pinned by sha256; any other Moonraker patch
# fails this invariant. The allowlisted patch is itself a REMOVAL_CANDIDATE
# - see scripts/build/04-cross-compile-app-stack.sh for the root cause
# (CONFIG_FILE_LOCKING, long since fixed) and the retirement experiment.
MREPO=$(man MOONRAKER_REPO); MPIN=$(man MOONRAKER_PIN)
case "$MREPO" in
  *Arksine/moonraker*) ok "moonraker-is-official-upstream" "$MREPO @ ${MPIN:0:12}";;
  *) bad "moonraker-is-official-upstream" "unexpected repo '$MREPO'";;
esac

MOON_ALLOW_NAME=moonraker-sqlite-nolock.patch
MOON_ALLOW_SHA=831abda453dc83f024e32daf6b8702b00bfbdb8ea57bac2519abd98ce0c35cb1
moon_problems=()

# (a) FILE SET - exactly the allowlisted moonraker patch file may exist.
moon_named=$(ls -1 "$FW/scripts/build/patches" 2>/dev/null | grep -i moonraker | sort | tr '\n' ' ')
moon_named=${moon_named% }
[ "$moon_named" = "$MOON_ALLOW_NAME" ] || \
  moon_problems+=("moonraker patch file set is '${moon_named:-<none>}', expected exactly '$MOON_ALLOW_NAME'")

# (b) CONTENT PIN - the allowlisted patch must be the exact reviewed bytes,
#     so allowlisting by filename cannot be used to smuggle in new content.
if [ -f "$FW/scripts/build/patches/$MOON_ALLOW_NAME" ]; then
  moon_sha=$(sha256sum "$FW/scripts/build/patches/$MOON_ALLOW_NAME" | cut -d' ' -f1)
  [ "$moon_sha" = "$MOON_ALLOW_SHA" ] || \
    moon_problems+=("$MOON_ALLOW_NAME content changed (sha256 ${moon_sha:0:12} != ${MOON_ALLOW_SHA:0:12}) - re-review, then update MOON_ALLOW_SHA")
else
  moon_problems+=("$MOON_ALLOW_NAME is missing from scripts/build/patches/")
fi

# (c) CONTENT SWEEP - catches a Moonraker patch hiding under an innocuous
#     filename, and any apply step that reaches one through a shell variable.
#     What a diff TOUCHES cannot be disguised by how it is invoked.
while IFS= read -r pf; do
  [ -n "$pf" ] || continue
  [ "$(basename "$pf")" = "$MOON_ALLOW_NAME" ] && continue
  if grep -qE '^(diff --git|---|\+\+\+).*moonraker' "$pf" 2>/dev/null; then
    moon_problems+=("$(basename "$pf") diffs a moonraker path but is not allowlisted")
  fi
done < <(find "$FW/scripts/build/patches" -type f 2>/dev/null | sort)

# (d) APPLY STEPS - flag-order-proof, RECURSIVE (the old glob was
#     scripts/build/*.sh, so scripts/build/lib/ was never scanned), honestly
#     comment-filtered, and CONTINUATION-AWARE: shell line continuations are
#     joined first, so splitting an invocation across lines cannot hide the
#     patch filename on the second line from a line-at-a-time scan.
moon_logical=$(find "$FW/scripts/build" -name '*.sh' -type f 2>/dev/null | sort \
  | while IFS= read -r f; do
      awk -v F="$f" '
        { if (acc == "") startln = NR
          l = $0
          if (sub(/[[:space:]]*\\$/, "", l)) { acc = acc l " "; next }
          acc = acc l
          print F ":" startln ":" acc
          acc = ""
        }
        END { if (acc != "") print F ":" startln ":" acc }
      ' "$f"
    done)
moon_steps=$(printf '%s\n' "$moon_logical" \
  | awk '{ body=$0; sub(/^[^:]+:[0-9]+:/, "", body);
           if (body ~ /^[[:space:]]*#/) next;
           if (tolower(body) !~ /moonraker/) next;
           if (body ~ /git[[:space:]]+apply/ \
               || body ~ /(^|[^[:alnum:]_.\/-])patch([[:space:]]+-|[[:space:]]*<)/) print }')
MOON_STEP_COUNT=0
while IFS= read -r step; do
  [ -n "$step" ] || continue
  MOON_STEP_COUNT=$((MOON_STEP_COUNT+1))
  case "$step" in
    *"$MOON_ALLOW_NAME"*) : ;;
    *) moon_problems+=("un-allowlisted moonraker patch/apply step: ${step#"$FW/"}") ;;
  esac
done <<< "$moon_steps"

if [ "${#moon_problems[@]}" -eq 0 ]; then
  ok "moonraker-official-upstream-allowlisted-patches-only" \
     "official upstream + $MOON_STEP_COUNT allowlisted build-time patch (${MOON_ALLOW_NAME}, sha256 ${MOON_ALLOW_SHA:0:12}); applied to the overlay copy only, vendor/moonraker untouched"
else
  bad "moonraker-official-upstream-allowlisted-patches-only" "$(printf '%s; ' "${moon_problems[@]}")"
fi

# --- 7. Mainsail official / unmodified -------------------------------------
MSTAG=$(man MAINSAIL_TAG); MSSHA=$(man MAINSAIL_SHA256)
if [ "$MSTAG" != UNRESOLVED ] && [ "$MSSHA" != UNRESOLVED ]; then
  ok "mainsail-pinned-release-with-checksum" "$MSTAG sha256=${MSSHA:0:12}"
else
  bad "mainsail-pinned-release-with-checksum" "tag='$MSTAG' sha='$MSSHA'"
fi

# --- 8. No SimpleAF production dependency ----------------------------------
# The checkable claim is that NO SHIPPED KLIPPER CONFIG activates a SimpleAF
# config namespace. Grepping for the word "simpleaf" is not that test: every
# current hit is either provenance prose ("derived from pellcorp/creality
# SimpleAF ...") or a literal legacy-include string that S04nebulaos-migrate
# uses to RECOGNISE AND REMOVE old config - i.e. evidence for the invariant.
SAF_ACTIVE=0
for cfg in "$FW/scripts/build/overlay/opt/printer_data/config/printer.cfg" \
           "$FW"/scripts/build/overlay/etc/nebulaos/klipper/*.cfg; do
  [ -f "$cfg" ] || continue
  n=$(grep -cE '^[[:space:]]*\[include[[:space:]]+simpleaf/' "$cfg" 2>/dev/null || true)
  SAF_ACTIVE=$((SAF_ACTIVE + n))
done
if [ "$SAF_ACTIVE" = 0 ]; then
  ok "no-simpleaf-config-namespace-shipped" "no active [include simpleaf/...] in any shipped klipper config"
else
  bad "no-simpleaf-config-namespace-shipped" "$SAF_ACTIVE active simpleaf include(s) in shipped config"
fi
# pellcorp/creality (SimpleAF's repo) IS pinned, deliberately, as a source of
# derived config fragments. Whether that constitutes a "production dependency"
# is a definitional question a grep cannot settle honestly.
doc "no-simpleaf-production-dependency" "pellcorp/creality pinned as config-fragment provenance ($(man PELLCORP_CREALITY_PIN | cut -c1-12)); scope is definitional"

# --- 9. No old PRTouch runtime stack ---------------------------------------
# The production modules were deleted in Phase 1.8B. Residual planning docs and
# a test-support shim are expected and are NOT runtime.
# What makes PRTouch "present" is a loaded module or an active config SECTION -
# not a filename. etc/nebulaos/klipper/prtouch.cfg still exists but contains
# only [z_compensate]; its own header records that the name was kept to avoid
# rippling a rename. Failing on the filename would be a misleading test.
PRT_RUNTIME=$(ls "$EX/extras" 2>/dev/null | grep -E '^prtouch_.*\.py$' | grep -v 'test_support' | wc -l)
PRT_SECTION=$(grep -rc '^[[:space:]]*\[prtouch' "$FW/scripts/build/overlay" 2>/dev/null | awk -F: '{t+=$2} END{print t+0}')
if [ "$PRT_RUNTIME" = 0 ] && [ "$PRT_SECTION" = 0 ]; then
  ok "no-prtouch-runtime-stack" "no prtouch_*.py runtime modules, no [prtouch*] config sections shipped"
else
  bad "no-prtouch-runtime-stack" "runtime_modules=$PRT_RUNTIME config_sections=$PRT_SECTION"
fi
if [ -f "$FW/scripts/build/overlay/etc/nebulaos/klipper/prtouch.cfg" ]; then
  doc "prtouch-cfg-filename-is-legacy" "file ships but contains only [z_compensate]; cosmetic rename candidate"
fi

# --- 10. MCU provenance model ----------------------------------------------
# The MCU is NOT fetched by pin. A prebuilt binary + provenance sidecar is
# vendored. Verify the model holds AND the artifact matches its sidecar.
if grep -qE '^MCU_PIN=' "$DEPS" 2>/dev/null; then
  bad "mcu-provenance-model-is-vendored-artifact" "unexpected MCU_PIN in manifest - integration model changed"
else
  CAND=$FW/scripts/build/overlay/opt/nebulaos/mcu-candidates/candidate-001.bin
  SIDE=${CAND%.bin}.provenance.json
  if [ -f "$CAND" ] && [ -f "$SIDE" ]; then
    want=$(grep -o '"packaged_bin_sha256"[[:space:]]*:[[:space:]]*"[0-9a-f]*"' "$SIDE" | grep -o '[0-9a-f]\{64\}')
    got=$(sha256sum "$CAND" | awk '{print $1}')
    mcom=$(grep -o '"mcu_repo_commit"[[:space:]]*:[[:space:]]*"[0-9a-f]*"' "$SIDE" | grep -o '[0-9a-f]\{40\}')
    if [ -n "$want" ] && [ "$want" = "$got" ]; then
      if git -C "$MC" cat-file -e "${mcom}^{commit}" 2>/dev/null; then
        ok "mcu-provenance-model-is-vendored-artifact" "sha matches sidecar; commit ${mcom:0:12} present"
      else
        bad "mcu-provenance-model-is-vendored-artifact" "provenance commit $mcom absent from MCU repo"
      fi
    else
      bad "mcu-provenance-model-is-vendored-artifact" "binary sha256 does not match sidecar"
    fi
  else
    bad "mcu-provenance-model-is-vendored-artifact" "candidate binary or sidecar missing"
  fi
fi

# --- 11. repo HEAD vs shipping pin distinction is real ---------------------
# Prove the two concepts are genuinely tracked separately: each pin that has a
# corresponding local repo must resolve, and being BEHIND HEAD must be normal.
BEHIND=0; PINCHK=0
chk_pin(){ # repo_path pin label
  local r=$1 pin=$2 label=$3
  [ "$pin" = UNRESOLVED ] && { bad "shipping-pin-resolves:$label" "no pin"; return; }
  PINCHK=$((PINCHK+1))
  if ! git -C "$r" cat-file -e "${pin}^{commit}" 2>/dev/null; then
    bad "shipping-pin-resolves:$label" "pin $pin not in repo"; return
  fi
  if git -C "$r" merge-base --is-ancestor "$pin" HEAD 2>/dev/null; then
    local n; n=$(git -C "$r" rev-list --count "$pin"..HEAD 2>/dev/null)
    [ "$n" -gt 0 ] && BEHIND=$((BEHIND+1))
    ok "shipping-pin-resolves:$label" "ancestor of HEAD, ${n} commit(s) behind"
  else
    bad "shipping-pin-resolves:$label" "pin is not an ancestor of the active checkout"
  fi
}
chk_pin "$WORKSPACE_ROOT/NebulaOS-kernel"      "$(man KERNEL_PIN)"      "kernel"
# Run 15: the screen app (GuppyScreen renamed NebulaScreen) - either checkout
# name and either manifest variable, until the rename is complete everywhere.
SCREEN_REPO=$WORKSPACE_ROOT/NebulaOS-nebulascreen
[ -d "$SCREEN_REPO/.git" ] || SCREEN_REPO=$WORKSPACE_ROOT/NebulaOS-guppyscreen
SCREEN_PIN=$(man NEBULASCREEN_PIN); [ "$SCREEN_PIN" = UNRESOLVED ] && SCREEN_PIN=$(man GUPPYSCREEN_PIN)
chk_pin "$SCREEN_REPO" "$SCREEN_PIN" "screen"
chk_pin "$EX"                                  "$EPIN"                  "extensions"
echo "  (pins checked=$PINCHK, legitimately behind HEAD=$BEHIND - trailing pins are normal, not defects)"

# --- 12. Probe architecture ------------------------------------------------
# BLTouch/CR-Touch global probe role and load-cell secondary role are config
# and behavioral properties spread across shipped printer configs and extras.
# A grep here would assert a shape it cannot actually prove.
doc "bltouch-crtouch-global-probe-role" "requires runtime config semantics; see docs/architecture"
doc "load-cell-secondary-contact-role"  "requires runtime config semantics; see docs/architecture"

# --- 13. PLR architecture --------------------------------------------------
PLR_MODS=$(ls "$EX/extras" 2>/dev/null | grep -cE '^nebulaos_(power_loss_recovery|plr_journal)\.py$')
if [ "$PLR_MODS" -ge 2 ]; then
  ok "plr-architecture-present" "nebulaos_power_loss_recovery.py + nebulaos_plr_journal.py"
else
  bad "plr-architecture-present" "expected PLR modules missing (found $PLR_MODS/2)"
fi

# --- 14. Calibration architecture ------------------------------------------
CAL_MODS=$(ls "$EX/extras" 2>/dev/null | grep -cE '^nebulaos_(calibration|calibration_journal|probe_pair|z_offset_probe)\.py$')
if [ "$CAL_MODS" -ge 4 ]; then
  ok "calibration-architecture-present" "$CAL_MODS canonical calibration modules"
else
  bad "calibration-architecture-present" "expected >=4 calibration modules, found $CAL_MODS"
fi

# --- summary ---------------------------------------------------------------
echo
echo "INVARIANTS_PASS=$PASS"
echo "INVARIANTS_FAIL=$FAILN"
echo "INVARIANTS_DOCUMENTED_ONLY=$DOCONLY"
if [ "$FAILN" -eq 0 ]; then
  echo "ARCHITECTURE_INVARIANTS_VALID=YES"
  exit 0
fi
for f in "${FAILURES[@]}"; do echo "  FAIL: $f"; done
echo "ARCHITECTURE_INVARIANTS_VALID=NO"
exit 1
