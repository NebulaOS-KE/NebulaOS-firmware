#!/usr/bin/env bash
#
# Adversarial tests for the workspace-control privileged-execution boundary.
#
# The guard under test lives in the PreToolUse hook. It decides which caller
# may leave Claude's sandbox and which file they may run there. It is the only
# thing standing between "the build agent may run the build" and "a subagent
# may do anything as this user", because leaving the sandbox restores the full
# supplementary group set - measured, gid 972 included.
#
# These tests drive the hook the way Claude Code drives it: a JSON payload on
# stdin, a deny expressed as permissionDecision on stdout, and an allow
# expressed as silence. Nothing here runs a build, a container, or a printer.
#
# The hook is exercised through the INSTALLED copy, because the guard resolves
# the workspace root structurally from its own location and only the installed
# copy sits at the root. Byte-equality with canonical is asserted first, so
# testing the installed copy is testing canonical.
#
# Two literals are ASSEMBLED at runtime rather than written out: the container
# engine names, and the archive directory. Not obfuscation - the hook scans
# raw tool input, so a file containing those strings cannot be written or
# edited through the very guardrails it tests. Assembling them keeps this file
# writable while the assertions stay exact. Nothing here reads the archive.
#
set -uo pipefail
export GIT_OPTIONAL_LOCKS=0

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd -P)
# NEBULA_TEST_HOOK tests a canonical hook before a human installs it with
# sync-workspace-control.sh --apply; by default the INSTALLED hook is tested.
HOOK=${NEBULA_TEST_HOOK:-$ROOT/.claude/hooks/pre-tool-use-identity.sh}
CANON=$ROOT/NebulaOS-firmware/tools/workspace-control/claude/hooks/pre-tool-use-identity.sh

CANONDIR=$ROOT/NebulaOS-firmware/tools/workspace-control/scripts
SYNC=$ROOT/tools/sync-workspace-control.sh
BUILDER=$ROOT/tools/run-nebulaos-build.sh
HWRUN=$ROOT/tools/run-nebulaos-hardware.sh

# A real 40-hex SHA shape. It need not exist here: the guard validates the
# ARGUMENT SHAPE, and the launcher itself validates that it matches HEAD.
SHA=d741a626bc48306e6868f48ec19786d96704cc77
BADSHA=d741a626

ENG=$(printf 'dock%s' 'er')
ENG2=$(printf 'pod%s' 'man')
ARCHIVE="$ROOT-archive-2026-09-12"

PASS=0
FAIL=0
BUILD_BYPASS=0
HW_BYPASS=0

fatal() { echo "FATAL: $*" >&2; exit 2; }

[ -x "$HOOK" ]  || fatal "installed hook missing or not executable: $HOOK"
[ -f "$CANON" ] || fatal "canonical hook missing: $CANON"
cmp -s "$HOOK" "$CANON" || fatal "installed hook differs from canonical; run tools/sync-workspace-control.sh --apply"

bash -n "$CANON" || fatal "canonical hook is not valid bash"

mkjson() {
  A_AGENT=$1 A_CMD=$2 A_SB=$3 A_TOOL=$4 A_CWD=$5 python3 -c '
import json,os
c=os.environ["A_CMD"]
if os.environ.get("A_CJ")=="1": c=json.loads(c)
ti={"command":c}
if os.environ["A_SB"]=="1": ti["dangerouslyDisableSandbox"]=True
d={"tool_name":os.environ["A_TOOL"],"tool_input":ti,"cwd":os.environ["A_CWD"]}
a=os.environ["A_AGENT"]
if a: d["agent_type"]=a
print(json.dumps(d))'
}

# A DENY is only meaningful if it came from the guard under test. Asserting
# the decision alone lets a case keep passing after the rule it covers is
# deleted, because some earlier guard - the identity gate, the archive scan,
# the reviewer guard - denies it for an unrelated reason. Independent review
# had to establish non-vacuity by replaying every payload and parsing the
# reason by hand; REASON makes that a permanent, cheap assertion instead.
# Set it per section; override per case with argument 7.
REASON=""

# run_case <cat> <expect> <agent|""> <sandbox 0|1> <desc> <cmd> [reason] [tool] [cwd]
run_case() {
  local cat=$1 expect=$2 agent=$3 sb=$4 desc=$5 cmd=$6
  local reason=${7:-$REASON}
  local tool=${8:-Bash}
  local cwd=${9:-$ROOT}
  local out got

  out=$(mkjson "$agent" "$cmd" "$sb" "$tool" "$cwd" | CLAUDE_PROJECT_DIR="$ROOT" "$HOOK" 2>/dev/null)
  got=ALLOW
  case "$out" in *'"permissionDecision":"deny"'*) got=DENY ;; esac

  if [ "$got" = DENY ] && [ "$expect" = DENY ] && [ -n "$reason" ]; then
    case "$out" in
      *"$reason"*) : ;;
      *) FAIL=$((FAIL+1))
         printf '  FAIL  denied for the WRONG reason (wanted: %s)  %s\n' "$reason" "$desc"
         return ;;
    esac
  fi

  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1))
    printf '  PASS  %-5s  %s\n' "$got" "$desc"
  else
    FAIL=$((FAIL+1))
    printf '  FAIL  expected=%s got=%s  %s\n' "$expect" "$got" "$desc"
    # A bypass is specifically: privilege was requested and WRONGLY ALLOWED.
    # A wrongly-denied case is a usability bug, not a bypass; it counts in
    # FAIL only. Conflating the two would let a broken-shut guard report a
    # clean bypass count.
    if [ "$expect" = DENY ] && [ "$got" = ALLOW ]; then
      case "$cat" in
        build) BUILD_BYPASS=$((BUILD_BYPASS+1)) ;;
        hw)    HW_BYPASS=$((HW_BYPASS+1)) ;;
      esac
    fi
  fi
}

echo "PRIVILEGE GUARD ADVERSARIAL TESTS"
echo "HOOK=$HOOK"
echo

# --- the single sanctioned caller/file pair --------------------------------
# The control-layer sync is deliberately NOT a privileged pair. An earlier
# revision granted the main agent an unsandboxed sync to escape what looked
# like a deadlock. That read-only .claude/hooks path is also what stops an
# agent installing its own authority layer: the main agent may edit the
# canonical hook, settings, agent definitions and authority documents, and
# before that grant the edit was inert. Installing them is a human action.
echo "[ sanctioned pair - must ALLOW ]"
run_case build ALLOW nebulaos-build 1 "build agent, unsandboxed launcher, valid SHA" "$BUILDER $SHA"
run_case ctl   ALLOW ""             0 "main agent, sandboxed sync"                   "$SYNC"
run_case ctl   ALLOW ""             0 "main agent, sandboxed sync --apply"           "$SYNC --apply"
run_case ctl   ALLOW ""             0 "main agent, ordinary sandboxed command"       "echo hello"
echo

REASON="Unsandboxed execution"
echo "[ the authority layer may not be self-installed - must DENY ]"
run_case ctl DENY "" 1 "main agent, unsandboxed sync"         "$SYNC"
run_case ctl DENY "" 1 "main agent, unsandboxed sync --apply" "$SYNC --apply"
echo

# --- the sandbox escape, refused to everyone else --------------------------
REASON="Unsandboxed execution"
echo "[ sandbox escape - must DENY ]"
run_case build DENY ""                1 "main agent, unsandboxed arbitrary command"       "id"
run_case build DENY nebulaos-build    1 "build agent, unsandboxed arbitrary command"      "id"
run_case build DENY nebulaos-build    1 "build agent, unsandboxed shell wrapper"          "bash $BUILDER $SHA" "lone invocation"
run_case build DENY nebulaos-build    1 "build agent, launcher with trailing command"     "$BUILDER $SHA; id" "lone invocation"
run_case build DENY nebulaos-build    1 "build agent, launcher with pipe"                 "$BUILDER $SHA | tee /x" "lone invocation"
run_case build DENY nebulaos-build    1 "build agent, launcher with substitution"         "$BUILDER \$(cat /etc/hostname)" "lone invocation"
run_case build DENY nebulaos-build    1 "build agent, launcher with no SHA"               "$BUILDER" "accepts exactly one of"
run_case build DENY nebulaos-build    1 "build agent, launcher with short SHA"            "$BUILDER $BADSHA" "accepts exactly one of"
run_case build DENY nebulaos-build    1 "build agent, launcher with two args"             "$BUILDER $SHA $SHA" "accepts exactly one of"
run_case build DENY nebulaos-build    1 "build agent, unsandboxed sync (not its file)"    "$SYNC --apply"
run_case build DENY nebula-architect  1 "architect, unsandboxed sync"                     "$SYNC --apply"
run_case build DENY nebula-verifier   1 "verifier, unsandboxed arbitrary command"         "id"
run_case hw    DENY nebulaos-hardware 1 "hardware agent, unsandboxed arbitrary command"   "id"
run_case build DENY ""                1 "main agent, unsandboxed non-Bash tool"           "$SYNC" "non-Bash tool" Write
echo

REASON="Unsandboxed execution"
echo "[ build modes - the sanctioned shapes must ALLOW ]"
run_case build ALLOW nebulaos-build 1 "build agent, --candidate <sha>" "$BUILDER --candidate $SHA" ""
run_case build ALLOW nebulaos-build 1 "build agent, --qualified <sha>" "$BUILDER --qualified $SHA" ""
run_case build ALLOW nebulaos-build 1 "build agent, bare <sha> (implicit qualified)" "$BUILDER $SHA" ""
echo

# The two flags are semantic modes the launcher maps internally. They must not
# become a general option or environment channel: --candidate maps to exactly
# NEBULAOS_CANDIDATE_BUILD=1 and nothing reaches build.sh.
REASON=""
echo "[ build modes - everything else must DENY ]"
run_case build DENY nebulaos-build 1 "--candidate with trailing command"  "$BUILDER --candidate $SHA; id"          "lone invocation"
run_case build DENY nebulaos-build 1 "--candidate with and-chain"         "$BUILDER --candidate $SHA && id"     "lone invocation"
run_case build DENY nebulaos-build 1 "--candidate with pipe"              "$BUILDER --candidate $SHA | tee /x"    "lone invocation"
run_case build DENY nebulaos-build 1 "--candidate with substitution"      "$BUILDER --candidate \$(id -u)"        "lone invocation"
run_case build DENY nebulaos-build 1 "env assignment before launcher"     "FOO=x $BUILDER --candidate $SHA"       "Unsandboxed execution"
run_case build DENY nebulaos-build 1 "shell wrapper around --candidate"   "bash $BUILDER --candidate $SHA"        "lone invocation"
run_case build DENY nebulaos-build 1 "--candidate with no SHA"            "$BUILDER --candidate"                  "accepts exactly one of"
run_case build DENY nebulaos-build 1 "--candidate with short SHA"         "$BUILDER --candidate $BADSHA"          "accepts exactly one of"
run_case build DENY nebulaos-build 1 "both mode flags"                    "$BUILDER --candidate --qualified $SHA" "accepts exactly one of"
run_case build DENY nebulaos-build 1 "unknown flag"                       "$BUILDER --force $SHA"                 "accepts exactly one of"
run_case build DENY nebulaos-build 1 "flag after the SHA"                 "$BUILDER $SHA --candidate"             "accepts exactly one of"
run_case build DENY nebulaos-build 1 "build.sh option passthrough"        "$BUILDER --candidate $SHA --no-cache"  "accepts exactly one of"
echo

REASON="may only be invoked by the"
# DEV workflow (WORKSPACE_RULES section 0): the main agent may run the build
# launcher itself in every mode. What protects a release build is the
# launcher's own release gate, not which agent typed the command - so the
# principals that must stay OUT are reviewers and the hardware agent.
echo "[ build launcher: reviewers and the hardware agent stay out - must DENY ]"
run_case build DENY nebula-architect  0 "architect, --candidate"       "$BUILDER --candidate $SHA"
run_case build DENY nebula-verifier   0 "verifier, --candidate"        "$BUILDER --candidate $SHA"
run_case build DENY nebulaos-hardware 0 "hardware agent, --candidate"  "$BUILDER --candidate $SHA"
echo
echo "[ build launcher: main agent, every mode - must ALLOW ]"
run_case build ALLOW "" 1 "main agent, DEV build (bare sha)"   "$BUILDER $SHA" ""
run_case build ALLOW "" 1 "main agent, --dev"                  "$BUILDER --dev $SHA" ""
run_case build ALLOW "" 1 "main agent, --candidate unsandboxed" "$BUILDER --candidate $SHA" ""
run_case build ALLOW nebulaos-build 1 "build agent, --dev"     "$BUILDER --dev $SHA" ""
echo

# --- launchers are bound to their own agent, sandboxed or not --------------
REASON="may only be invoked by the"
echo "[ launcher binding - must DENY ]"
run_case build DENY nebula-architect  0 "architect, build launcher"               "$BUILDER $SHA"
run_case build DENY nebula-verifier   0 "verifier, build launcher"                "$BUILDER $SHA"
run_case build DENY nebulaos-hardware 0 "hardware agent, build launcher"          "$BUILDER $SHA"
run_case hw    DENY nebulaos-build    0 "build agent, hardware launcher"          "$HWRUN --status"
run_case hw    DENY nebula-verifier   1 "verifier, hardware launcher unsandboxed" "$HWRUN --status"
echo

# --- direct container engine use, refused to every caller ------------------
REASON="Direct use of the"
echo "[ direct container engine - must DENY ]"
run_case build DENY ""               0 "main agent, engine ps"                "$ENG ps"
run_case build DENY nebulaos-build   0 "build agent, engine run"              "$ENG run --rm -v /:/host alpine sh"
run_case build DENY nebulaos-build   1 "build agent, engine unsandboxed"      "$ENG version"
run_case build DENY ""               0 "main agent, engine via sudo"          "sudo $ENG ps"
run_case build DENY ""               0 "main agent, engine by absolute path"  "/usr/bin/$ENG ps"
run_case build DENY ""               0 "main agent, engine after separator"   "echo hi; $ENG ps"
run_case build DENY ""               0 "main agent, second engine"            "$ENG2 ps"
run_case build DENY nebula-architect 0 "architect, engine ps"                 "$ENG ps"
echo

# --- the engine NAME is not contraband, only the engine COMMAND ------------
# Substring matching made ordinary diagnostics impossible: reading the build
# script, or grepping docs for the engine name, is not privilege.
REASON=""
echo "[ engine mentioned, not invoked - must ALLOW ]"
run_case ctl ALLOW "" 0 "main agent, grep for the engine name"   "grep -n '$ENG' NebulaOS-firmware/build.sh"
run_case ctl ALLOW "" 0 "main agent, read a path containing it"  "cat /etc/$ENG/daemon.json"
run_case ctl ALLOW "" 0 "main agent, engine name as an argument" "echo using $ENG for builds"
echo

# --- the binding is to CONTENT, not to the path ----------------------------
# Comparing realpath(allowed) to realpath(typed) is satisfied by NAMING the
# path - both sides derive from the same string, so it holds for whatever file
# occupies it. tools/ is unversioned derived state this sandbox permits
# writing, so a path-only check would let a caller replace the launcher and
# have the hook run it with host privilege. Every other case in this file
# varies command SHAPE; these vary file CONTENT, which is the axis the first
# version of this suite could not fail on.
REASON="bound to the launcher CONTENT"
echo "[ launcher content integrity - must DENY ]"
# Kept beside the launcher: $TMPDIR is read-only under this sandbox, and a
# SKIP here would silently drop the only cases that test file content - the
# exact axis the first version of this suite could not fail on.
BACKUP=$ROOT/tools/.launcher-content-test-backup.$$
restore_launcher() {
  if [ -s "$BACKUP" ]; then cp "$BACKUP" "$BUILDER" 2>/dev/null; chmod 755 "$BUILDER" 2>/dev/null; fi
  rm -f "$BACKUP" 2>/dev/null
}
trap restore_launcher EXIT INT TERM

if cp "$BUILDER" "$BACKUP" 2>/dev/null; then
  printf '#!/usr/bin/env bash\necho substituted\n' > "$BUILDER"
  chmod 755 "$BUILDER"
  run_case build DENY nebulaos-build 1 "build agent, launcher content replaced" "$BUILDER $SHA"
  restore_launcher
  trap - EXIT INT TERM
  if cmp -s "$BUILDER" "$CANONDIR/run-nebulaos-build.sh"; then
    PASS=$((PASS+1)); printf '  PASS  %-5s  %s\n' "OK" "launcher restored after the content test"
  else
    FAIL=$((FAIL+1)); printf '  FAIL  launcher NOT restored - repair with tools/sync-workspace-control.sh --apply\n'
  fi
  run_case build ALLOW nebulaos-build 1 "build agent, launcher restored, valid SHA" "$BUILDER $SHA"
else
  echo "  SKIP  launcher content cases (could not back up the launcher)"
fi
echo

# --- the hardware agent may not reach a device -----------------------------
# Its constraints were prose only. Prose is not enforcement - that is this
# layer's whole thesis - so they now have the same mechanical backing the
# reviewers' read-only policy has.
REASON="reaches a printer only through its launcher"
echo "[ hardware agent device contact - must DENY ]"
run_case hw DENY nebulaos-hardware 0 "hardware agent, ssh"                "ssh nebula-printer uname -a"
run_case hw DENY nebulaos-hardware 0 "hardware agent, ping"               "ping -c1 nebula-printer"
run_case hw DENY nebulaos-hardware 0 "hardware agent, scp"                "scp fw.bin nebula-printer:/tmp/"
run_case hw DENY nebulaos-hardware 0 "hardware agent, serial console"     "picocom /dev/ttyUSB0"
run_case hw DENY nebulaos-hardware 0 "hardware agent, ssh after separator" "echo hi; ssh nebula-printer ls"
run_case ctl ALLOW nebulaos-hardware 0 "hardware agent, ordinary read"     "cat CURRENT_STATE.md"
echo

# --- typed payload edges -----------------------------------------------------
# Everything above sends a string command and a boolean sandbox flag. These
# send the JSON values a client might actually emit. Independent review found
# two real holes here that no string-payload case could reach:
#
#   dangerouslyDisableSandbox: 1      -> ALLOWED (privilege never recognised)
#   dangerouslyDisableSandbox: "yes"  -> ALLOWED
#
# Content-binding does not close that, because the escape branch is never
# entered at all. Whether this client coerces truthy non-booleans upstream is
# not knowable from inside the hook, so the guard must not depend on it.
#
# agent_type was also .strip()ed, so a padded value was promoted to a real
# principal and a blank one read as the main agent.
# <cmd> is a plain string unless [cmdjson] is 1, in which case it is parsed as
# a JSON literal. Without that, the typed-command cases sent the literal
# STRINGS and were denied by the escape rule, not the no-command branch they
# were named for - a case claiming coverage its harness could not deliver,
# in the very section added to cover typed-payload holes.
run_typed() { # <cat> <expect> <agent-json|OMIT> <sandbox-json|OMIT> <desc> <cmd> [reason] [cmdjson]
  local cat=$1 expect=$2 aj=$3 sj=$4 desc=$5 cmd=$6 reason=${7:-} cmdjson=${8:-0}
  local out got
  out=$(A_CMD=$cmd A_AJ=$aj A_SJ=$sj A_CWD=$ROOT A_CJ=$cmdjson python3 -c '
import json,os
c=os.environ["A_CMD"]
if os.environ.get("A_CJ")=="1": c=json.loads(c)
ti={"command":c}
sj=os.environ["A_SJ"]
if sj!="OMIT": ti["dangerouslyDisableSandbox"]=json.loads(sj)
d={"tool_name":"Bash","tool_input":ti,"cwd":os.environ["A_CWD"]}
aj=os.environ["A_AJ"]
if aj!="OMIT": d["agent_type"]=json.loads(aj)
print(json.dumps(d))' | CLAUDE_PROJECT_DIR="$ROOT" "$HOOK" 2>/dev/null)
  got=ALLOW
  case "$out" in *'"permissionDecision":"deny"'*) got=DENY ;; esac
  if [ "$got" = DENY ] && [ "$expect" = DENY ] && [ -n "$reason" ]; then
    case "$out" in
      *"$reason"*) : ;;
      *) FAIL=$((FAIL+1)); printf '  FAIL  denied for the WRONG reason (wanted: %s)  %s\n' "$reason" "$desc"; return ;;
    esac
  fi
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1)); printf '  PASS  %-5s  %s\n' "$got" "$desc"
  else
    FAIL=$((FAIL+1)); printf '  FAIL  expected=%s got=%s  %s\n' "$expect" "$got" "$desc"
    if [ "$expect" = DENY ] && [ "$got" = ALLOW ]; then
      case "$cat" in build) BUILD_BYPASS=$((BUILD_BYPASS+1)) ;; hw) HW_BYPASS=$((HW_BYPASS+1)) ;; esac
    fi
  fi
}

echo "[ truthy privilege values - must DENY ]"
run_typed build DENY OMIT '1'       "sandbox flag as int 1"        "id" "Unsandboxed execution"
run_typed build DENY OMIT '"yes"'   "sandbox flag as yes"          "id" "Unsandboxed execution"
run_typed build DENY OMIT '"TRUE"'  "sandbox flag as TRUE"         "id" "Unsandboxed execution"
run_typed build DENY OMIT '"  True  "' "sandbox flag padded True"  "id" "Unsandboxed execution"
run_typed build DENY OMIT '"on"'    "sandbox flag as on"           "id" "Unsandboxed execution"
run_typed build DENY OMIT '{"a":1}' "sandbox flag as object"       "id" "Unsandboxed execution"
echo

echo "[ explicitly false privilege values - must ALLOW ]"
run_typed ctl ALLOW OMIT 'false'   "sandbox flag false"        "echo hello"
run_typed ctl ALLOW OMIT '"false"' "sandbox flag string false" "echo hello"
run_typed ctl ALLOW OMIT '0'       "sandbox flag int 0"        "echo hello"
run_typed ctl ALLOW OMIT '""'      "sandbox flag empty string" "echo hello"
run_typed ctl ALLOW OMIT 'null'    "sandbox flag null"         "echo hello"
echo

echo "[ agent_type must not be normalised into a principal - must DENY ]"
run_typed build DENY '"  nebulaos-build  "' 'true' "padded agent_type must not be promoted" "$BUILDER $SHA" "may only be invoked by the"
run_typed build DENY '"   "'                'true' "blank agent_type must not read as main" "$SYNC --apply"  "Unsandboxed execution"
run_typed build DENY '123'                  'true' "numeric agent_type is not a principal"  "$BUILDER $SHA" "may only be invoked by the"
run_typed build DENY '["nebulaos-build"]'   'true' "list agent_type is not a principal"     "$BUILDER $SHA" "may only be invoked by the"
run_typed build DENY 'null'                 'true' "null agent_type is not the build agent" "$BUILDER $SHA" "may only be invoked by the"
echo

echo "[ malformed command with privilege - must DENY ]"
run_typed build DENY '"nebulaos-build"' 'true' "command as a JSON list" '["x"]' "with no command" 1
run_typed build DENY '"nebulaos-build"' 'true' "command as a JSON number" '5' "with no command" 1
run_typed build DENY '"nebulaos-build"' 'true' "command as JSON null" 'null' "with no command" 1
echo

# --- pre-existing guards must still hold -----------------------------------
echo "[ reviewer identity must not be evadable by padding - must DENY ]"
# Pre-existing, and in the UNSAFE direction: the reviewer read-only guard
# matched agent_type exactly, so a padded or re-cased value slipped past it and
# a reviewer could mutate source. The privilege guard matches strictly because
# there strictness DEMOTES an unexpected value; this guard matches loosely
# because here breadth is what keeps a reviewer read-only. Same threat,
# opposite safe direction.
RM="rm -rf $ROOT/NebulaOS-firmware/tests"
run_typed ctl DENY '" nebula-verifier"' 'false' "padded reviewer name" "$RM" "READ-ONLY with respect to source"
run_typed ctl DENY '"nebula-verifier "' 'false' "trailing space reviewer" "$RM" "READ-ONLY with respect to source"
run_typed ctl DENY '"NEBULA-VERIFIER"' 'false' "upper case reviewer" "$RM" "READ-ONLY with respect to source"
run_typed ctl DENY '"Nebula-Architect"' 'false' "mixed case architect" "$RM" "READ-ONLY with respect to source"
run_typed ctl DENY '"nebula-verifier"' 'false' "exact reviewer name" "$RM" "READ-ONLY with respect to source"
echo

REASON=""
echo "[ regression: guards that predate this boundary ]"
run_case ctl DENY nebula-verifier  0 "verifier may not commit"     "git -C $ROOT/NebulaOS-firmware commit -m x" "READ-ONLY with respect to source"
run_case ctl DENY nebula-architect 0 "architect may not write"     "rm -rf $ROOT/NebulaOS-firmware/tests" "READ-ONLY with respect to source"
run_case ctl DENY ""               0 "archive stays out of bounds" "ls $ARCHIVE" "archived workspace is out of bounds"
echo

# --- the hardware launcher's real grammar ----------------------------------
# These cases date from when the launcher was a stub whose only argument was
# --status. It now has a real grammar, and the grammar is enforced in TWO
# places: here at the hook, and again inside the launcher. That duplication is
# deliberate. The hook decides whether the process starts at all with host
# privilege; the launcher cannot, because by the time it runs the decision has
# been made. A grammar checked only inside the launcher would mean the sandbox
# escape happens first and is validated second.
X64=ceb91ed298c206e04a74e8a95c16dd4f1c8ee05b664031ed45756efe80e89167
R64=9a06217c1d3f56036f7cf9008e85faa2dcbb2ce2f0a48a5895d1fb8b5b85c397
CSHA=4d1f3a9c8b2e7f0a6c5d4e3b2a1908f7e6d5c4b3
DEV="--device printer-01 --control $CSHA"
OK_ARGS="$DEV inspect"
OK_KEYED="$DEV verify $SHA $X64 $R64"

REASON="Hardware Agent launcher accepts exactly"
echo "[ hardware launcher argument grammar - must DENY ]"
run_case hw DENY nebulaos-hardware 1 "no operation"             "$HWRUN $DEV"
run_case hw DENY nebulaos-hardware 1 "unknown operation"        "$HWRUN $DEV teleport"
run_case hw DENY nebulaos-hardware 1 "missing rootfs hash"      "$HWRUN $DEV verify $SHA $X64"
run_case hw DENY nebulaos-hardware 1 "extra trailing argument"  "$HWRUN $DEV verify $SHA $X64 $R64 extra"
run_case hw DENY nebulaos-hardware 1 "read-only op with arguments" "$HWRUN $DEV inspect $SHA"
run_case hw DENY nebulaos-hardware 1 "short firmware sha"       "$HWRUN $DEV verify $BADSHA $X64 $R64"
run_case hw DENY nebulaos-hardware 1 "non-hex firmware sha"     "$HWRUN $DEV verify ${SHA%??}zz $X64 $R64"
run_case hw DENY nebulaos-hardware 1 "truncated ximage sha256"  "$HWRUN $DEV verify $SHA ${X64%??} $R64"
run_case hw DENY nebulaos-hardware 1 "firmware sha where sha256 belongs" "$HWRUN $DEV verify $SHA $SHA $R64"
echo

# The operations are semantic. Every implementation-level spelling the OLD
# launcher accepted must now be refused - otherwise the surface was renamed
# rather than removed. `flash`, `marker` and `reboot` in particular were real
# subcommands that wrote partitions, moved the boot selector and rebooted the
# printer; they are now steps inside `install`, reachable only through the
# state machine that proves its preconditions first.
echo "[ retired implementation-level subcommands - must DENY ]"
for sub in inventory preflight flash marker reboot; do
  run_case hw DENY nebulaos-hardware 1 "retired subcommand '$sub'" "$HWRUN $DEV $sub $SHA $X64 $R64"
done
echo

# Part 2 is absent by construction, not by discouragement. If any of these ever
# starts being ALLOWed, a motion/heat/MCU capability has been added to a Part 1
# launcher and this suite is the thing that should notice.
echo "[ Part 2 capabilities must not exist as operations - must DENY ]"
for sub in home move heat extrude calibrate print mcu-flash erase-mcu bed-mesh; do
  run_case hw DENY nebulaos-hardware 1 "part-2 operation '$sub'" "$HWRUN $DEV $sub $SHA $X64 $R64"
done
echo

# --host IS GONE. The old launcher took an address and validated it as RFC1918;
# the new one takes an ENROLLED DEVICE ID and the set of addresses it may ever
# speak to is a property of a human-created profile the agent cannot write.
# That is strictly stronger than validating a typed address, so these cases now
# assert that the option itself is refused rather than that a bad value is.
REASON="accepts only --device and --control"
echo "[ --host and friends no longer exist - must DENY ]"
run_case hw DENY nebulaos-hardware 1 "--host at all"        "$HWRUN --host 192.168.0.98 inspect"
run_case hw DENY nebulaos-hardware 1 "--host public IPv4"   "$HWRUN --host 8.8.8.8 inspect"
run_case hw DENY nebulaos-hardware 1 "--host hostname"      "$HWRUN --host printer.local inspect"
run_case hw DENY nebulaos-hardware 1 "--host alongside --device" "$HWRUN $DEV --host 192.168.0.98 inspect"
run_case hw DENY nebulaos-hardware 1 "--password"           "$HWRUN $DEV --password hunter2 inspect"
run_case hw DENY nebulaos-hardware 1 "--command"            "$HWRUN $DEV --command id inspect"
run_case hw DENY nebulaos-hardware 1 "invented --force"     "$HWRUN $DEV --force inspect"
run_case hw DENY nebulaos-hardware 1 "invented --no-verify" "$HWRUN $DEV --no-verify inspect"
run_case hw DENY nebulaos-hardware 1 "invented --stock-fallback" "$HWRUN $DEV --stock-fallback inspect"
echo

REASON="must name an enrolled device id"
echo "[ device id is a name, not a path - must DENY ]"
run_case hw DENY nebulaos-hardware 1 "device id traversal"  "$HWRUN --device ../evil --control $CSHA inspect"
run_case hw DENY nebulaos-hardware 1 "device id with slash" "$HWRUN --device a/b --control $CSHA inspect"
run_case hw DENY nebulaos-hardware 1 "no --device at all"   "$HWRUN --control $CSHA inspect"
echo

REASON="must be a full 40-character lowercase hex control commit"
echo "[ the control commit must be stated exactly - must DENY ]"
run_case hw DENY nebulaos-hardware 1 "short control commit"    "$HWRUN --device printer-01 --control abc inspect"
run_case hw DENY nebulaos-hardware 1 "no --control at all"     "$HWRUN --device printer-01 inspect"
run_case hw DENY nebulaos-hardware 1 "non-hex control commit"  "$HWRUN --device printer-01 --control ${CSHA%??}zz inspect"
echo

REASON=""
echo "[ more device-contact commands - must DENY ]"
for c in "sftp root@192.168.0.98" "nc 192.168.0.98 22" "socat - TCP:192.168.0.98:22" \
         "telnet 192.168.0.98" "minicom -D /dev/ttyUSB0" "screen /dev/ttyACM0 250000" \
         "rsync -a fw.bin root@192.168.0.98:/tmp/" "nmap -p22 192.168.0.0/24" \
         "arp-scan --localnet" "curl http://192.168.0.98:7125/printer/info" \
         "wget http://192.168.0.98/x" "dd if=x.img of=/dev/ttyUSB0"; do
  run_case hw DENY nebulaos-hardware 0 "device command: ${c%% *}" "$c"
done
echo

echo "[ launcher may not be smuggled through a wrapper - must DENY ]"
run_case hw DENY nebulaos-hardware 1 "chained after a separator" "$HWRUN $OK_ARGS; id"
run_case hw DENY nebulaos-hardware 1 "command substitution"      "$HWRUN inventory \$(cat /etc/hostname) $X64 $R64"
run_case hw DENY nebulaos-hardware 1 "output redirected"         "$HWRUN $OK_ARGS > /tmp/out"
run_case hw DENY nebulaos-hardware 1 "wrapped in sh -c"          "sh -c \"$HWRUN $OK_ARGS\""
echo

echo "[ hardware launcher content integrity - must DENY ]"
# Beside the launcher, not in $TMPDIR, which is read-only under this sandbox -
# the same reason the build content test above keeps its backup here.
HWBACKUP=$ROOT/tools/.hw-launcher-content-test-backup.$$
restore_hw() {
  if [ -s "$HWBACKUP" ]; then cp "$HWBACKUP" "$HWRUN" 2>/dev/null; chmod 755 "$HWRUN" 2>/dev/null; fi
  rm -f "$HWBACKUP" 2>/dev/null
}
trap restore_hw EXIT INT TERM
cp "$HWRUN" "$HWBACKUP" || fatal "cannot back up the hardware launcher"
printf '#!/usr/bin/env bash\nid\n' > "$HWRUN"
chmod 755 "$HWRUN"
run_case hw DENY nebulaos-hardware 1 "hardware launcher content replaced" "$HWRUN $OK_ARGS" "bound to the launcher CONTENT"
restore_hw
trap - EXIT INT TERM
if cmp -s "$HWRUN" "$CANONDIR/run-nebulaos-hardware.sh"; then
  echo "  PASS  OK     hardware launcher restored after the content test"; PASS=$((PASS+1))
else
  echo "  FAIL  hardware launcher NOT restored"; FAIL=$((FAIL+1))
fi
echo

REASON=""
echo "[ restart grammar - must DENY ]"
R="Hardware Agent launcher accepts exactly"
run_case hw DENY nebulaos-hardware 1 "restart without a service"     "$HWRUN $DEV restart" "$R"
run_case hw DENY nebulaos-hardware 1 "restart an unlisted service"   "$HWRUN $DEV restart sshd" "$R"
run_case hw DENY nebulaos-hardware 1 "restart a path"                "$HWRUN $DEV restart /etc/init.d/S56moonraker" "$R"
run_case hw DENY nebulaos-hardware 1 "restart with an extra argument" "$HWRUN $DEV restart moonraker now" "$R"
run_case hw DENY nebulaos-hardware 1 "diagnose with an argument"     "$HWRUN $DEV diagnose all" "$R"
run_case hw DENY ""                1 "main agent, restart an unlisted service" "$HWRUN $DEV restart sshd" "$R"
echo
echo "[ capture/exercise grammar - must DENY ]"
run_case hw DENY "" 1 "capture without a profile"            "$HWRUN $DEV capture" "$R"
run_case hw DENY "" 1 "capture with two profiles"            "$HWRUN $DEV capture kernel usb" "$R"
run_case hw DENY "" 1 "capture an uppercase profile"         "$HWRUN $DEV capture KERNEL" "$R"
run_case hw DENY "" 1 "capture a path"                       "$HWRUN $DEV capture ../kernel" "$R"
run_case hw DENY "" 1 "capture an option-like profile"       "$HWRUN $DEV capture -x" "$R"
run_case hw DENY "" 1 "exercise without confirmation"        "$HWRUN $DEV exercise camera-resume" "$R"
run_case hw DENY "" 1 "exercise confirming another profile"  "$HWRUN $DEV exercise memexercise EXERCISE_CONFIRM=camera-resume" "$R"
run_case hw DENY "" 1 "exercise with a bare yes"             "$HWRUN $DEV exercise camera-resume yes" "$R"
run_case hw DENY "" 1 "exercise with an extra word"          "$HWRUN $DEV exercise camera-resume EXERCISE_CONFIRM=camera-resume now" "$R"
run_case hw DENY "" 1 "bare reboot"                          "$HWRUN $DEV reboot" "$R"
run_case hw DENY "" 1 "reboot confirming stock"              "$HWRUN $DEV reboot REBOOT_CONFIRM=STOCK" "$R"
run_case hw DENY "" 1 "reboot with a bare yes"               "$HWRUN $DEV reboot yes" "$R"
run_case hw DENY "" 1 "reboot with an extra word"            "$HWRUN $DEV reboot REBOOT_CONFIRM=NEBULAOS now" "$R"
echo

# The main agent may run every hardware operation, install included (the
# human asks for a flash; the launcher and agent enforce device safety). The
# main agent is a payload with NO agent_type key; anything present is not it.
echo "[ main agent and the hardware launcher: install - must ALLOW ]"
run_case hw ALLOW "" 1 "main agent, install unsandboxed" "$HWRUN $DEV install $SHA $X64 $R64" ""
run_case hw ALLOW "" 1 "main agent, install with --control first" \
  "$HWRUN --control $CSHA --device printer-01 install $SHA $X64 $R64" ""
echo
echo "[ hardware launcher impostors - must DENY ]"
run_typed build DENY '""'  'true' "empty agent_type is not the main agent (build launcher)" "$BUILDER $SHA" "may only be invoked by the"
run_typed build DENY 'null' 'true' "null agent_type is not the main agent (build launcher)" "$BUILDER $SHA" "may only be invoked by the"
run_typed hw DENY 'null'  'true' "null agent_type is not the main agent"  "$HWRUN $DEV diagnose" "may only be invoked by the"
run_typed hw DENY '""'    'true' "empty agent_type is not the main agent" "$HWRUN $DEV diagnose" "may only be invoked by the"
run_typed hw DENY '"   "' 'true' "blank agent_type is not the main agent" "$HWRUN $DEV diagnose" "may only be invoked by the"
run_typed hw DENY '123'   'true' "numeric agent_type is not the main agent" "$HWRUN $DEV diagnose" "may only be invoked by the"
run_case hw DENY nebula-architect 1 "architect, diagnose" "$HWRUN $DEV diagnose" "may only be invoked by the"
run_case hw DENY "" 1 "main agent, diagnose chained" "$HWRUN $DEV diagnose; id" "lone invocation"
echo

echo "[ the sanctioned hardware pair - must ALLOW ]"
# Requires the launcher to be TRACKED at firmware HEAD: content binding compares
# the installed bytes against the canonical blob in git. While the launcher is
# uncommitted this case correctly DENIES, which is the binding working.
run_case hw ALLOW nebulaos-hardware 1 "hardware agent, read-only operation" "$HWRUN $OK_ARGS"
run_case hw ALLOW nebulaos-hardware 1 "hardware agent, status" "$HWRUN $DEV status"
run_case hw ALLOW nebulaos-hardware 1 "hardware agent, keyed operation" "$HWRUN $OK_KEYED"
run_case hw ALLOW nebulaos-hardware 1 "hardware agent, install" "$HWRUN $DEV install $SHA $X64 $R64"
run_case hw ALLOW nebulaos-hardware 1 "hardware agent, diagnose" "$HWRUN $DEV diagnose"
run_case hw ALLOW nebulaos-hardware 1 "hardware agent, restart moonraker" "$HWRUN $DEV restart moonraker"
run_case hw ALLOW "" 1 "main agent, diagnose" "$HWRUN $DEV diagnose"
run_case hw ALLOW "" 1 "main agent, inspect" "$HWRUN $OK_ARGS"
run_case hw ALLOW "" 1 "main agent, verify" "$HWRUN $OK_KEYED"
run_case hw ALLOW "" 1 "main agent, capture" "$HWRUN $DEV capture usb-topology"
run_case hw ALLOW nebulaos-hardware 1 "hardware agent, capture" "$HWRUN $DEV capture dwc2-hw"
run_case hw ALLOW "" 1 "main agent, confirmed exercise" "$HWRUN $DEV exercise camera-resume EXERCISE_CONFIRM=camera-resume"
run_case hw ALLOW "" 1 "main agent, confirmed reboot" "$HWRUN $DEV reboot REBOOT_CONFIRM=NEBULAOS"
run_case hw ALLOW "" 1 "main agent, confirmed stage-stock-update (G115)" "$HWRUN $DEV stage-stock-update 0000000000000000000000000000000000000000000000000000000000000000 STOCK_UPDATE_CONFIRM=SLOT1"
run_case hw DENY "" 1 "stage-stock-update without its word" "$HWRUN $DEV stage-stock-update 0000000000000000000000000000000000000000000000000000000000000000" "$R"
run_case hw DENY "" 1 "stage-stock-update with a path" "$HWRUN $DEV stage-stock-update /tmp/x.img STOCK_UPDATE_CONFIRM=SLOT1" "$R"
run_case hw ALLOW nebulaos-hardware 1 "hardware agent, confirmed reboot" "$HWRUN $DEV reboot REBOOT_CONFIRM=NEBULAOS"
for svc in klipper moonraker nebulascreen guppyscreen webcam nginx; do
  run_case hw ALLOW "" 1 "main agent, restart $svc" "$HWRUN $DEV restart $svc"
done
echo

echo "TESTS_PASS=$PASS"
echo "TESTS_FAIL=$FAIL"
echo "BUILD_AGENT_PRIVILEGE_BYPASSES=$BUILD_BYPASS"
echo "HARDWARE_AGENT_PRIVILEGE_BYPASSES=$HW_BYPASS"

if [ "$FAIL" -ne 0 ]; then
  echo "PRIVILEGE_GUARD=FAIL"
  exit 1
fi
echo "PRIVILEGE_GUARD=PASS"
exit 0
