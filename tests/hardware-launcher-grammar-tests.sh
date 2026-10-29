#!/usr/bin/env bash
#
# The Hardware Agent launcher's grammar, exercised against the real script.
#
# WHY A FAKE WORKSPACE ROOT
#
# The launcher's first act is a structural check that it is sitting inside a
# real NebulaOS workspace - which is correct, and which also means the grammar
# below it can never be reached from a test directory. So this builds a minimal
# fake root with a passing gate stub and an agent stub that echoes what it was
# handed. The code under test is the REAL launcher, byte for byte; only its
# surroundings are stubbed, and the stubs are the two things the grammar does
# not depend on.
#
# WHAT IS BEING ASSERTED
#
# That the removed surface is genuinely gone. The old launcher accepted
# `--host <private-ipv4>` and six implementation-level subcommands including
# `flash`, `marker` and `reboot`. The new one accepts an enrolled device id, a
# control commit, and four semantic operations - and every one of the old
# spellings must now be refused, or the surface was not actually removed.
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FW=$(cd "$SCRIPT_DIR/.." && pwd)
LAUNCHER_SRC="$FW/tools/workspace-control/scripts/run-nebulaos-hardware.sh"
[ -f "$LAUNCHER_SRC" ] || { echo "FATAL: $LAUNCHER_SRC not found" >&2; exit 1; }

PASS=0; FAIL=0
ok(){   PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad(){  FAIL=$((FAIL+1)); printf 'FAIL  %s\n       %s\n' "$1" "${2:-}"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nebulaos-launcher-grammar.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

ROOT="$WORK/root"
mkdir -p "$ROOT/tools" \
         "$ROOT/NebulaOS-firmware/tools/workspace-control/scripts" \
         "$ROOT/NebulaOS-firmware/tools/hardware" \
         "$ROOT/NebulaOS-firmware/.git"
touch "$ROOT/NebulaOS-firmware/tools/workspace-control/MANIFEST"
cp "$LAUNCHER_SRC" "$ROOT/NebulaOS-firmware/tools/workspace-control/scripts/"
LAUNCHER="$ROOT/NebulaOS-firmware/tools/workspace-control/scripts/run-nebulaos-hardware.sh"
chmod 755 "$LAUNCHER"

# A gate that passes, so a refusal below is the grammar's and not the gate's.
printf '#!/bin/sh\nexit 0\n' > "$ROOT/tools/verify-workspace-identity.sh"
chmod 755 "$ROOT/tools/verify-workspace-identity.sh"
# An agent that echoes, so an acceptance is visible as what got through.
printf '#!/usr/bin/env python3\nimport sys\nprint("AGENT_RECEIVED=" + " ".join(sys.argv[1:]))\n' \
  > "$ROOT/NebulaOS-firmware/tools/hardware/nebulaos_agent.py"

SHA=$(printf 'a%.0s' $(seq 40))
S256=$(printf 'b%.0s' $(seq 64))

refuse(){
  local why=$1; shift
  local out; out=$(bash "$LAUNCHER" "$@" 2>&1 | head -1)
  if printf '%s' "$out" | grep -q 'RUN_NEBULAOS_HARDWARE=REFUSED'; then
    ok "refused: $why"
  else
    bad "refused: $why" "got: ${out:0:120}"
  fi
}

accept(){
  local why=$1; shift
  local out; out=$(bash "$LAUNCHER" "$@" 2>&1 | head -1)
  if printf '%s' "$out" | grep -q '^AGENT_RECEIVED='; then
    ok "accepted: $why"
  else
    bad "accepted: $why" "got: ${out:0:120}"
  fi
}

echo "=== the removed surface must be gone ==="
refuse "--host, the old target argument"            --host 192.168.0.98 inspect
refuse "--password"                                  --device p1 --password hunter2 inspect
refuse "--command"                                   --device p1 --command "rm -rf /" inspect
refuse "the old 'flash' subcommand"                  --device p1 --control "$SHA" flash
refuse "the old 'marker' subcommand"                 --device p1 --control "$SHA" marker
refuse "the old 'reboot' subcommand"                 --device p1 --control "$SHA" reboot
refuse "the old 'preflight' subcommand"              --device p1 --control "$SHA" preflight
refuse "the old 'inventory' subcommand"              --device p1 --control "$SHA" inventory

echo
echo "=== malformed arguments ==="
refuse "a device id containing a path traversal"     --device "../evil" --control "$SHA" inspect
refuse "a device id with a slash"                    --device "a/b" --control "$SHA" inspect
refuse "an empty device id"                          --device "" --control "$SHA" inspect
refuse "a short control commit"                      --device p1 --control abc inspect
refuse "an uppercase control commit"                 --device p1 --control "$(printf 'A%.0s' $(seq 40))" inspect
refuse "no --control at all"                         --device p1 inspect
refuse "no --device at all"                          --control "$SHA" inspect
refuse "an abbreviated source head"                  --device p1 --control "$SHA" install deadbeef "$S256" "$S256"
refuse "a short artifact digest"                     --device p1 --control "$SHA" install "$SHA" bbbb "$S256"
refuse "install missing an argument"                 --device p1 --control "$SHA" install "$SHA" "$S256"
refuse "inspect with a stray argument"               --device p1 --control "$SHA" inspect extra
refuse "an unknown operation"                        --device p1 --control "$SHA" frobnicate

echo
echo "=== the four semantic operations ==="
accept "inspect"  --device p1 --control "$SHA" inspect
accept "status"   --device p1 --control "$SHA" status
accept "verify"   --device p1 --control "$SHA" verify  "$SHA" "$S256" "$S256"
accept "install"  --device p1 --control "$SHA" install "$SHA" "$S256" "$S256"
accept "reboot back into NebulaOS (confirmed)" --device p1 --control "$SHA" reboot REBOOT_CONFIRM=NEBULAOS
refuse "reboot confirming another target"     --device p1 --control "$SHA" reboot REBOOT_CONFIRM=STOCK
refuse "reboot with an extra argument"        --device p1 --control "$SHA" reboot REBOOT_CONFIRM=NEBULAOS now
accept "rtos-logo (confirmed)"                 --device p1 --control "$SHA" rtos-logo RTOS_LOGO_CONFIRM=RTOS2
refuse "rtos-logo without confirmation"        --device p1 --control "$SHA" rtos-logo
refuse "rtos-logo confirming rtos (p3)"        --device p1 --control "$SHA" rtos-logo RTOS_LOGO_CONFIRM=RTOS
refuse "rtos-logo with a path argument"        --device p1 --control "$SHA" rtos-logo /tmp/zero.bin RTOS_LOGO_CONFIRM=RTOS2
accept "stage-stock-update (confirmed)"        --device p1 --control "$SHA" stage-stock-update "$S256" STOCK_UPDATE_CONFIRM=SLOT1
refuse "stage-stock-update without a word"     --device p1 --control "$SHA" stage-stock-update "$S256"
refuse "stage-stock-update with a path"        --device p1 --control "$SHA" stage-stock-update /tmp/x.img STOCK_UPDATE_CONFIRM=SLOT1
refuse "stage-stock-update with another word"  --device p1 --control "$SHA" stage-stock-update "$S256" REBOOT_CONFIRM=NEBULAOS
refuse "stage-stock-update with an extra arg"  --device p1 --control "$SHA" stage-stock-update "$S256" STOCK_UPDATE_CONFIRM=SLOT1 now
accept "rtos-logo-restore (confirmed)"         --device p1 --control "$SHA" rtos-logo-restore "$S256" RTOS_RESTORE_CONFIRM=RTOS2
refuse "rtos-logo-restore with a short sha"    --device p1 --control "$SHA" rtos-logo-restore bbbb RTOS_RESTORE_CONFIRM=RTOS2
refuse "rtos-logo-restore with a path"         --device p1 --control "$SHA" rtos-logo-restore /tmp/x.bin RTOS_RESTORE_CONFIRM=RTOS2
refuse "rtos-logo-restore with the logo word"  --device p1 --control "$SHA" rtos-logo-restore "$S256" RTOS_LOGO_CONFIRM=RTOS2
refuse "rtos-logo-restore without a word"      --device p1 --control "$SHA" rtos-logo-restore "$S256"
accept "a device id using the full permitted character set" \
        --device printer_01-a --control "$SHA" status

echo
echo "=== the launcher must not INVOKE a raw transport ==="
# Greps the real script, not the stub - but only its EXECUTABLE lines. An
# earlier version grepped the whole file and failed on its own documentation:
# the header says "no ssh/scp/dd/raw usbboot" and "the hook refuses
# ssh/scp/sftp/ping/nc/socat", which are explanations that these are absent, not
# invocations of them. A test that cannot tell a comment from a command would
# have to be satisfied by deleting the comment, which is the wrong fix.
CODE="$WORK/launcher-code-only.sh"
sed 's/[[:space:]]*#.*$//' "$LAUNCHER_SRC" | grep -v '^[[:space:]]*$' > "$CODE"
for banned in 'sshpass' 'scp ' 'dd if=' 'usbboot' 'nc ' 'socat' 'ssh '; do
  if grep -qF "$banned" "$CODE"; then
    bad "the launcher body does not invoke '$banned'" \
        "$(grep -nF "$banned" "$CODE" | head -1 | cut -c1-100)"
  else
    ok "the launcher body does not invoke '$banned'"
  fi
done

# The positive form of the same claim: exactly one external program is executed.
EXECS=$(grep -cE '^[[:space:]]*exec ' "$CODE")
if [ "$EXECS" -eq 1 ] && grep -qE '^[[:space:]]*exec python3 "\$AGENT"' "$CODE"; then
  ok "the launcher execs exactly one program: the agent entrypoint"
else
  bad "the launcher execs exactly one program: the agent entrypoint" "exec count=$EXECS"
fi

echo
printf 'HARDWARE_LAUNCHER_GRAMMAR_PASS=%d\nHARDWARE_LAUNCHER_GRAMMAR_FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
