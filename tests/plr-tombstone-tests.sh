#!/bin/sh
#
# Offline tests for Phase 1.9B's stock-switch PLR tombstone hook:
# scripts/build/overlay/opt/nebulaos/tools/plr_tombstone.py and its
# integration into scripts/build/overlay/etc/ota_marker.sh's
# write_ota_marker(). Static analysis plus one real functional test of
# plr_tombstone.py itself against a temp file standing in for the EEPROM
# and a real copy of nebulaos_plr_journal.py from a sibling
# NebulaOS-klipper-extensions checkout, when available - no Klipper,
# hardware, or a real build required.
#
# Usage: sh tests/plr-tombstone-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
TOOL="$REPO_ROOT/scripts/build/overlay/opt/nebulaos/tools/plr_tombstone.py"
OTA_MARKER="$REPO_ROOT/scripts/build/overlay/etc/ota_marker.sh"
BRANCH_DIR=$(basename "$REPO_ROOT")

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# =========================================================================
# 1. plr_tombstone.py exists and is syntactically valid
# =========================================================================

echo "--- plr_tombstone.py ---"

if [ -f "$TOOL" ]; then
    pass "plr_tombstone.py exists"
    if command -v python3 >/dev/null 2>&1; then
        if python3 -m py_compile "$TOOL" 2>"${TMPDIR:-/tmp}/plr-tombstone-pycompile-err.txt"; then
            pass "plr_tombstone.py is syntactically valid Python"
        else
            fail "plr_tombstone.py has a syntax error: $(cat "${TMPDIR:-/tmp}/plr-tombstone-pycompile-err.txt")"
        fi
        rm -f "${TMPDIR:-/tmp}/plr-tombstone-pycompile-err.txt"
    else
        echo "SKIP: python3 not available to syntax-check plr_tombstone.py"
    fi
else
    fail "plr_tombstone.py is missing"
fi

if grep -q "never fails the stock switch" "$TOOL" 2>/dev/null || grep -q "Never fails the stock switch" "$TOOL" 2>/dev/null; then
    pass "plr_tombstone.py documents its own non-fatal contract"
else
    fail "plr_tombstone.py does not document the non-fatal contract ota_marker.sh depends on"
fi

if grep -q "import nebulaos_plr_journal\|spec_from_file_location" "$TOOL" 2>/dev/null; then
    pass "plr_tombstone.py imports the composed nebulaos_plr_journal.py rather than embedding its own copy of the codec"
else
    fail "plr_tombstone.py does not reference the composed nebulaos_plr_journal.py"
fi

# =========================================================================
# 2. ota_marker.sh integration
# =========================================================================

echo "--- ota_marker.sh integration ---"

if [ -f "$OTA_MARKER" ]; then
    if grep -q 'plr_tombstone.py' "$OTA_MARKER"; then
        pass "write_ota_marker() references plr_tombstone.py"
    else
        fail "write_ota_marker() does not reference plr_tombstone.py"
    fi

    if grep -B1 'plr_tombstone.py' "$OTA_MARKER" | grep -q '! ota_slot_holds_nebulaos "\$1"'; then
        pass "plr_tombstone.py is only invoked when the selected slot does not hold NebulaOS (G39)"
    else
        fail "plr_tombstone.py invocation is not gated on the selected slot's system"
    fi

    # G39 functional: the real helper against fake marker/kernel partitions
    G=$(mktemp -d "${TMPDIR:-/tmp}/g39.XXXXXX")
    sed "s#/dev/mmcblk0p1#$G/p1#g; s#/opt/nebulaos/tools/plr_tombstone.py#$G/tomb.py#g; s#-x /usr/bin/python3#-x /bin/sh#g; s#/usr/bin/python3 #sh #g" \
        "$OTA_MARKER" > "$G/lib.sh"
    echo "echo fired >> $G/fired" > "$G/tomb.py"
    kernel() { head -c 32 /dev/zero > "$1"; printf '%s' "$2" >> "$1"; head -c 64 /dev/zero >> "$1"; }
    g39() { rm -f "$G/fired"; head -c 512 /dev/zero > "$G/p1"
        (OTA_KERNEL_A_DEV="$G/kA" OTA_KERNEL_B_DEV="$G/kB"; export OTA_KERNEL_A_DEV OTA_KERNEL_B_DEV
         . "$G/lib.sh"; write_ota_marker "$1"); [ -e "$G/fired" ]; }
    kernel "$G/kA" "Linux-4.4.94"; kernel "$G/kB" "Linux-6.6.157-rt79"
    g39 ota:kernel && pass "G39: switch to slot A holding the other system tombstones" || fail "G39: no tombstone towards the other system"
    g39 ota:kernel2 && fail "G39: switch to NebulaOS slot B tombstoned" || pass "G39: switch to NebulaOS slot B keeps the journal"
    kernel "$G/kA" "Linux-6.6.157-rt79"
    g39 ota:kernel && fail "G39: switch to NebulaOS slot A tombstoned" || pass "G39: switch to NebulaOS slot A keeps the journal"
    [ "$(head -c 12 "$G/p1" | od -An -c | tr -d ' ')" = 'ota:kernel\n\n' ] && pass "G39: marker still written" || fail "G39: marker bytes wrong"
    rm -f "$G/kA"
    g39 ota:kernel && pass "G39: unreadable kernel counts as not NebulaOS (tombstone)" || fail "G39: unreadable kernel skipped the tombstone"
    rm -rf "$G"

    if grep -A1 'plr_tombstone.py' "$OTA_MARKER" | grep -q '||'; then
        pass "plr_tombstone.py invocation has a non-fatal (||) fallback - a tombstone failure cannot block the stock switch"
    else
        fail "plr_tombstone.py invocation has no non-fatal fallback - a failure here could block the stock switch"
    fi

    if grep -q '/usr/bin/python3 /opt/nebulaos/tools/plr_tombstone.py' "$OTA_MARKER"; then
        pass "invoked via the system python3, not the klipper venv (must work even if that venv is broken/missing)"
    else
        fail "plr_tombstone.py is not invoked via the bare system python3"
    fi
else
    fail "ota_marker.sh is missing"
fi

# =========================================================================
# 3. Real functional test against a temp file EEPROM + the real journal
#    codec (when NebulaOS-klipper-extensions is checked out alongside this
#    repo, same sibling-worktree resolution as host-mcu-tests.sh)
# =========================================================================

echo "--- functional test (real journal codec, temp-file EEPROM) ---"

JOURNAL_CANDIDATE=""
for cand in "$REPO_ROOT/vendor/nebulaos-klipper-extensions/extras/nebulaos_plr_journal.py" \
            "$REPO_ROOT/../../NebulaOS-klipper-extensions/$BRANCH_DIR/extras/nebulaos_plr_journal.py" \
            "$REPO_ROOT/../../../NebulaOS-klipper-extensions/extras/nebulaos_plr_journal.py"; do
    [ -f "$cand" ] && { JOURNAL_CANDIDATE="$cand"; break; }
done

if [ -n "$JOURNAL_CANDIDATE" ] && command -v python3 >/dev/null 2>&1; then
    RESULT=$(python3 - "$TOOL" "$JOURNAL_CANDIDATE" <<'PYEOF'
import sys, os, tempfile, importlib.util

tool_path, journal_path = sys.argv[1], sys.argv[2]

spec = importlib.util.spec_from_file_location("plr_tombstone", tool_path)
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)
tool._JOURNAL_MODULE_CANDIDATES = [journal_path]

journal = tool._load_journal_module()
if journal is None:
    print("FAIL: could not load journal module")
    sys.exit(0)

d = tempfile.mkdtemp()
eeprom_path = os.path.join(d, "eeprom")
with open(eeprom_path, "wb") as f:
    f.write(bytes([0xFF]) * journal.EEPROM_TOTAL_SIZE)
    # Simulate stock's own page 0 content, to prove it survives untouched.
    f.seek(0)
    f.write(bytes([0x03, 0x01]) + bytes(14))

with open(eeprom_path, "r+b") as f:
    journal.commit_checkpoint(f, 42)

rc = tool.main(["--eeprom-path", eeprom_path])
if rc != 0:
    print("FAIL: plr_tombstone.main() exited %d" % rc)
    sys.exit(0)

with open(eeprom_path, "r+b") as f:
    recovery = journal.read_recovery_state(f)
    f.seek(0)
    stock_page = f.read(16)

if recovery is not None:
    print("FAIL: recovery state still available after tombstone")
elif stock_page != bytes([0x03, 0x01]) + bytes(14):
    print("FAIL: stock page 0 was disturbed by the tombstone operation")
else:
    print("OK")

# Absent-device path must exit 0, not fail the caller.
rc2 = tool.main(["--eeprom-path", "/nonexistent/path/for/this/test/eeprom"])
if rc2 != 0:
    print("FAIL: absent-EEPROM path exited %d, expected 0 (must not fail the switch)" % rc2)
else:
    print("OK_ABSENT")
PYEOF
)
    if echo "$RESULT" | grep -q "^OK$"; then
        pass "plr_tombstone.py commits a verified tombstone and leaves stock's page 0 byte-for-byte untouched"
    else
        fail "tombstone functional test failed: $RESULT"
    fi
    if echo "$RESULT" | grep -q "^OK_ABSENT$"; then
        pass "plr_tombstone.py exits 0 when the EEPROM device is absent (never blocks the stock switch)"
    else
        fail "absent-EEPROM behavior failed: $RESULT"
    fi
else
    echo "SKIP: NebulaOS-klipper-extensions not found alongside this checkout (or python3 missing) - cannot run the functional test"
fi

# =========================================================================
# Summary
# =========================================================================

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
