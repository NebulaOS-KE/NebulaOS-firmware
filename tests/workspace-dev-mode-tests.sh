#!/usr/bin/env bash
#
# DEV-mode behaviour of the workspace-control layer, tested against a
# throwaway FIXTURE workspace - five real git repositories plus the canonical
# control layer from this checkout, installed by its own sync script. Nothing
# here touches the real workspace, the network on purpose, a container, or a
# printer.
#
# What is asserted is behaviour, not wording: exit codes of the identity gate,
# allow/deny decisions of the installed PreToolUse hook, the mode and clone
# source the build launcher resolves, and the product-input classifier's
# answer on real commits.
set -uo pipefail
export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
       GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

SRC_FW=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)
BASE=$(mktemp -d "${TMPDIR:-/tmp}/nebula-devmode.XXXXXX") || exit 2
# NEBULA_KEEP_FIXTURE=1 keeps the fixture (printed as FIXTURE_ROOT) so other
# control-layer suites can be run against an installed copy of THIS canonical.
[ "${NEBULA_KEEP_FIXTURE:-0}" = 1 ] || trap 'rm -rf "$BASE"' EXIT
R=$BASE/NebulaOS
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
ko(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect_rc(){ # <want 0|nonzero> <desc> <cmd...>
  local want=$1 desc=$2; shift 2
  "$@" >/dev/null 2>&1; local rc=$?
  if { [ "$want" = 0 ] && [ "$rc" -eq 0 ]; } || { [ "$want" != 0 ] && [ "$rc" -ne 0 ]; }; then ok "$desc"; else ko "$desc (rc=$rc)"; fi
}

# ---------------------------------------------------------------- fixture --
mkrepo(){ # name branch
  git init -q -b "$2" "$R/$1"
  git -C "$R/$1" remote add origin "https://github.com/NebulaOS-KE/$1.git"
  echo "$1" > "$R/$1/README.md"; git -C "$R/$1" add -A; git -C "$R/$1" commit -qm init
}
mkdir -p "$R"
for r in NebulaOS-klipper-extensions:main NebulaOS-klipper-mcu:main NebulaOS-kernel:openke NebulaOS-nebulascreen:main; do
  mkrepo "${r%%:*}" "${r##*:}"
done
mkrepo NebulaOS-firmware main
FW=$R/NebulaOS-firmware
MCU_C=$(git -C "$R/NebulaOS-klipper-mcu" rev-parse HEAD)
mkdir -p "$FW/manifests" "$FW/tools" "$FW/tests" "$FW/scripts/build" "$FW/tools/hardware" \
         "$FW/scripts/build/overlay/opt/nebulaos/mcu-candidates"
cat > "$FW/manifests/dependencies.conf" <<EOF
KLIPPER_REPO=https://github.com/Klipper3d/klipper.git
KLIPPER_PIN=58bd67db3ce1be1951c3e4a6d1156a79903d4edc
KLIPPER_EXTENSIONS_BRANCH=production
KLIPPER_EXTENSIONS_PIN=$(git -C "$R/NebulaOS-klipper-extensions" rev-parse HEAD)
KERNEL_PIN=$(git -C "$R/NebulaOS-kernel" rev-parse HEAD)
NEBULASCREEN_PIN=$(git -C "$R/NebulaOS-nebulascreen" rev-parse HEAD)
EOF
CAND=$FW/scripts/build/overlay/opt/nebulaos/mcu-candidates/candidate-001
echo mcu-binary > "$CAND.bin"
printf '{"mcu_repo_commit": "%s", "packaged_bin_sha256": "%s"}\n' "$MCU_C" "$(sha256sum "$CAND.bin" | cut -d' ' -f1)" > "$CAND.provenance.json"
# tracked + new files only (the working tree may hold sandbox mount placeholders)
( cd "$SRC_FW" && git ls-files -co --exclude-standard -z tools/workspace-control | xargs -0 tar cf - ) | tar xf - -C "$FW"
cp "$SRC_FW/tools/product-inputs.py" "$FW/tools/"
echo 'print(1)' > "$FW/tools/hardware/nebulaos_agent.py"
echo 'echo build' > "$FW/scripts/build/01.sh"
git -C "$FW" add -A; git -C "$FW" commit -qm fixture
echo state > "$R/CURRENT_STATE.md"; echo readme > "$R/README.md"
"$FW/tools/workspace-control/scripts/sync-workspace-control.sh" --apply >/dev/null 2>&1 \
  || { echo "FATAL: fixture sync failed"; exit 2; }
GATE=$R/tools/verify-workspace-identity.sh
HOOK=$R/.claude/hooks/pre-tool-use-identity.sh
FWSHA=$(git -C "$FW" rev-parse HEAD)

hook(){ # <agent|""> <tool> <sandbox 0|1> <command> -> ALLOW|DENY
  local p
  p=$(A=$1 T=$2 S=$3 C=$4 W=$R python3 -c '
import json,os
ti={"command":os.environ["C"]} if os.environ["T"]=="Bash" else {"file_path":os.environ["C"],"old_string":"a","new_string":"b"}
if os.environ["S"]=="1": ti["dangerouslyDisableSandbox"]=True
d={"tool_name":os.environ["T"],"tool_input":ti,"cwd":os.environ["W"]}
if os.environ["A"]: d["agent_type"]=os.environ["A"]
print(json.dumps(d))')
  case "$(printf '%s' "$p" | CLAUDE_PROJECT_DIR=$R "$HOOK" 2>/dev/null)" in
    *'"permissionDecision":"deny"'*) echo DENY ;; *) echo ALLOW ;;
  esac
}
expect_hook(){ # <want> <desc> <agent> <tool> <sb> <cmd>
  local got; got=$(hook "$3" "$4" "$5" "$6")
  [ "$got" = "$1" ] && ok "$2" || ko "$2 (got $got)"
}

echo "WORKSPACE DEV-MODE TESTS (fixture $R)"

echo "[ default mode ]"
out=$("$GATE" 2>&1); rc=$?
[ $rc -eq 0 ] && printf '%s\n' "$out" | grep -qx 'WORKSPACE_MODE=DEV' \
  && ok "no argument = DEV mode, passes on a pristine fixture" || ko "default mode is DEV (rc=$rc)"
expect_rc 0 "--local passes on a pristine fixture (baseline for the strict cases)" "$GATE" --local

echo "[ ordinary DEV state never blocks ]"
echo dirty >> "$R/NebulaOS-nebulascreen/README.md"
expect_rc 0       "dirty unrelated repo: DEV passes"            "$GATE" --dev
expect_rc nonzero "dirty unrelated repo: --local still strict"  "$GATE" --local
echo wip > "$FW/wip.txt"; git -C "$FW" add wip.txt; git -C "$FW" commit -qm "unpushed local work"
expect_rc 0       "unpushed local commit: DEV passes"           "$GATE" --dev
git -C "$FW" checkout -q -b feature/x
expect_rc 0       "feature branch checked out: DEV passes"      "$GATE" --dev
expect_rc nonzero "feature branch: --local still strict"        "$GATE" --local
mkdir -p "$R/_scratch" && echo x > "$R/_scratch/notes"
git -C "$FW" worktree add -q "$R/_worktrees/fw-exp" -b exp >/dev/null 2>&1
expect_rc 0       "_scratch/ + _worktrees/ with a live worktree: DEV passes" "$GATE" --dev
echo "# canonical edit" >> "$FW/tools/workspace-control/claude/hooks/session-start.sh"
out=$("$GATE" --dev 2>&1); rc=$?
[ $rc -eq 0 ] && printf '%s\n' "$out" | grep -q 'WARN: control: root files drifted' \
  && ok "control-layer drift: DEV passes with a WARN" || ko "control-layer drift is a WARN in DEV (rc=$rc)"
expect_hook ALLOW "hook: main agent Edit allowed with dirty/unpushed/branch/scratch/drift" "" Edit 0 "$FW/x.py"
expect_hook ALLOW "hook: ordinary sandboxed command allowed in the same state"           "" Bash 0 "python3 -m pytest -q tests"
expect_hook ALLOW "hook: local simulator command allowed (no remote access needed)"      "" Bash 0 "python3 tests/hardware-install-simulation-tests.py"

echo "[ structural problems still block ]"
mkdir "$R/_project"
expect_rc nonzero "legacy authority tree _project/: DEV fails"   "$GATE" --dev
expect_hook DENY  "hook: Edit denied while _project/ is present" "" Edit 0 "$FW/x.py"
rmdir "$R/_project"
expect_rc 0 "removing it restores DEV" "$GATE" --dev

echo "[ release stays strict when invoked ]"
expect_rc nonzero "--release refuses this fixture (unpushed, dirty, remote mismatch)" "$GATE" --release
expect_rc nonzero "--full is the same strict release gate"                           "$GATE" --full

echo "[ build launcher: DEV default, release explicit ]"
BL=$R/tools/run-nebulaos-build.sh
WIP=$(git -C "$FW" rev-parse HEAD)            # unpushed commit, dirty workspace
out=$("$BL" --plan "$WIP" 2>&1); rc=$?
[ $rc -eq 0 ] && printf '%s\n' "$out" | grep -qx 'BUILD_MODE=dev' && printf '%s\n' "$out" | grep -qx "CLONE_FROM=$FW" \
  && ok "no mode flag = DEV build of an unpushed commit, cloned from the local repo" || ko "default build mode is DEV from local (rc=$rc: $out)"
out=$("$BL" --plan --candidate "$WIP" 2>&1); rc=$?
[ $rc -ne 0 ] && printf '%s\n' "$out" | grep -q 'RUN_NEBULAOS_BUILD=REFUSED' \
  && ok "--candidate still demands the full release gate (refused here)" || ko "--candidate stays strict (rc=$rc)"
out=$("$BL" --plan 0123456789abcdef0123456789abcdef01234567 2>&1); rc=$?
[ $rc -ne 0 ] && ok "DEV build of a commit that does not exist locally is refused" || ko "unknown commit refused"

echo "[ privilege boundary unchanged ]"
expect_hook ALLOW "main agent may run the build launcher unsandboxed (content-bound)" "" Bash 1 "$BL $FWSHA"
expect_hook ALLOW "main agent may run the build launcher --dev"                       "" Bash 1 "$BL --dev $FWSHA"
expect_hook DENY  "main agent unsandboxed arbitrary command"                          "" Bash 1 "id"
expect_hook DENY  "main agent unsandboxed ssh"                                        "" Bash 1 "ssh root@192.168.0.242"
expect_hook DENY  "main agent unsandboxed dd to a block device"                       "" Bash 1 "dd if=x of=/dev/mmcblk0p8"
expect_hook DENY  "main agent unsandboxed sync of the control layer"                  "" Bash 1 "$R/tools/sync-workspace-control.sh --apply"
expect_hook DENY  "hardware agent ssh (sandboxed)"                                    nebulaos-hardware Bash 0 "ssh root@192.168.0.242"
expect_hook DENY  "hardware agent scp (sandboxed)"                                    nebulaos-hardware Bash 0 "scp -O x root@h:/tmp"
expect_hook DENY  "hardware agent dd (sandboxed)"                                     nebulaos-hardware Bash 0 "dd if=x of=/dev/mmcblk0p6"
expect_hook DENY  "reviewer may not run the build launcher"                           nebula-verifier Bash 1 "$BL $FWSHA"
expect_hook DENY  "launcher chained with another command"                             "" Bash 1 "$BL $FWSHA; id"
expect_hook DENY  "build.sh option passthrough"                                       "" Bash 1 "$BL --dev $FWSHA --no-cache"
ENG=$(printf 'pod%s' 'man')
expect_hook DENY  "container engine directly, main agent"                            "" Bash 0 "$ENG ps"
cp "$BL" "$BASE/bl.bak"; echo "id" >> "$BL"
expect_hook DENY  "altered launcher bytes refused even by path"                       "" Bash 1 "$BL $FWSHA"
cp "$BASE/bl.bak" "$BL"

echo "[ hardware launcher: no workspace-wide gate in DEV ]"
out=$("$R/tools/run-nebulaos-hardware.sh" --device no-such-dev --control "$FWSHA" status 2>&1)
printf '%s\n' "$out" | grep -q 'identity gate' \
  && ko "hardware launcher still gates on the workspace (dirty/unpushed fixture)" \
  || ok "hardware launcher reaches the agent with dirty/unpushed work (no global gate)"

echo "[ PRODUCT vs CONTROL ]"
PI=$FW/tools/product-inputs.py
git -C "$FW" checkout -q main
P0=$(git -C "$FW" rev-parse HEAD)
echo 'print(2)' > "$FW/tools/hardware/nebulaos_agent.py"; git -C "$FW" commit -qam "host-side agent change"
echo doc > "$FW/tests/t.sh"; git -C "$FW" add -A; git -C "$FW" commit -qm "test change"
python3 "$PI" changed "$P0" HEAD | grep -qx 'PRODUCT_INPUTS_CHANGED=NO' \
  && ok "Hardware Agent + test commits do not change product inputs" || ko "host change misclassified"
mkdir -p "$BASE/builds/$P0/run-1"
printf 'BUILD_VERIFIED=YES\nSOURCE_HEAD=%s\nBUILD_MODE=dev\nATTESTED_AT=2026-01-01T00:00:00Z\n' "$P0" > "$BASE/builds/$P0/run-1/.nebulaos-build-verified"
NEBULAOS_BUILD_BASE=$BASE/builds python3 "$PI" current-build HEAD | grep -qx 'PRODUCT_BUILD_CURRENT=YES' \
  && ok "the existing build stays current after host-side commits" || ko "host-side commit invalidated the product build"
echo 'echo build2' > "$FW/scripts/build/01.sh"; git -C "$FW" commit -qam "build input change"
python3 "$PI" changed "$P0" HEAD | grep -qx 'PRODUCT_INPUTS_CHANGED=YES' \
  && ok "a scripts/build change is a product-input change" || ko "build input change missed"
NEBULAOS_BUILD_BASE=$BASE/builds python3 "$PI" current-build HEAD | grep -qx 'PRODUCT_BUILD_CURRENT=NO' \
  && ok "and then no existing build is current" || ko "stale build reported current"
python3 "$PI" classify brand-new-dir/x | grep -q '^PRODUCT' \
  && ok "an unknown path is treated as a product input (fail-safe)" || ko "unknown path not product"

echo
[ "${NEBULA_KEEP_FIXTURE:-0}" = 1 ] && echo "FIXTURE_ROOT=$R"
echo "TESTS_PASS=$PASS"
echo "TESTS_FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
