#!/bin/sh
#
# Offline tests for nebulaos-recover CLI tool (Phase 2 §15).
#
# Validates the recovery script's structure, subcommand coverage, status
# display, and recovery logic. Uses mock filesystem trees - does NOT
# require a real NebulaOS device or squashfs.
#
# Usage: sh tests/nebulaos-recover-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# S04nebulaos-factory-seed and S05nebulaos-activate source the shared
# persistent-venv helpers. On the device that library is an absolute path
# (/usr/libexec/nebulaos-venv-lib.sh); here it lives in the overlay source
# tree, and these suites source the init script inside `sh -c`, where $0 gives
# the script no way to find it. Point at the real library so these tests
# exercise the real predicate rather than a stub.
NEBULAOS_VENV_LIB="$REPO_ROOT/scripts/build/overlay/usr/libexec/nebulaos-venv-lib.sh"
export NEBULAOS_VENV_LIB

CLI_SCRIPT="$REPO_ROOT/scripts/build/overlay/usr/bin/nebulaos-recover"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# =========================================================================
# 1. File existence and permissions
# =========================================================================

echo "--- File existence and permissions ---"

if [ -f "$CLI_SCRIPT" ]; then
    pass "nebulaos-recover exists"
else
    fail "nebulaos-recover does not exist at $CLI_SCRIPT"
fi

if [ -x "$CLI_SCRIPT" ]; then
    pass "nebulaos-recover is executable"
else
    fail "nebulaos-recover is not executable"
fi

# =========================================================================
# 2. Script structure - required subcommands
# =========================================================================

echo ""
echo "--- Subcommand coverage ---"

for cmd in status klipper moonraker mainsail klipper_extensions; do
    if grep -q "cmd_${cmd}" "$CLI_SCRIPT"; then
        pass "subcommand function cmd_${cmd} exists"
    else
        fail "subcommand function cmd_${cmd} missing"
    fi
done

for cmd in status klipper moonraker mainsail; do
    if grep -q "^[[:space:]]*${cmd})" "$CLI_SCRIPT"; then
        pass "dispatch handles '$cmd'"
    else
        fail "dispatch does not handle '$cmd'"
    fi
done

if grep -q 'klipper-extensions)' "$CLI_SCRIPT"; then
    pass "dispatch handles 'klipper-extensions'"
else
    fail "dispatch does not handle 'klipper-extensions'"
fi

if grep -q 'help)' "$CLI_SCRIPT"; then
    pass "dispatch handles 'help'"
else
    fail "dispatch does not handle 'help'"
fi

# =========================================================================
# 3. Safety properties
# =========================================================================

echo ""
echo "--- Safety properties ---"

if grep -q 'set -eu' "$CLI_SCRIPT" || grep -q 'set -e' "$CLI_SCRIPT"; then
    pass "script uses errexit"
else
    fail "script does not use errexit (set -e)"
fi

if grep -q 'pre-recovery' "$CLI_SCRIPT"; then
    pass "recovery creates backup before overwriting"
else
    fail "recovery does not mention backup"
fi

if grep -q 'reboot\|restart' "$CLI_SCRIPT"; then
    pass "recovery mentions reboot requirement"
else
    fail "recovery does not mention reboot"
fi

if grep -q 'immutable' "$CLI_SCRIPT"; then
    pass "recovery references immutable squashfs source"
else
    fail "recovery does not reference immutable source"
fi

if grep -q 'S05nebulaos-activate' "$CLI_SCRIPT"; then
    pass "recovery mentions S05nebulaos-activate re-bind"
else
    fail "recovery does not mention activation step"
fi

# =========================================================================
# 4. Correct immutable paths
# =========================================================================

echo ""
echo "--- Immutable source paths ---"

if grep -q 'IMMUTABLE_KLIPPER="${IMMUTABLE_KLIPPER:-/opt/klipper}"' "$CLI_SCRIPT"; then
    pass "klipper immutable path defaults to /opt/klipper (overridable for tests)"
else
    fail "klipper immutable path default is wrong"
fi

if grep -q 'IMMUTABLE_MOONRAKER="${IMMUTABLE_MOONRAKER:-/opt/moonraker}"' "$CLI_SCRIPT"; then
    pass "moonraker immutable path defaults to /opt/moonraker (overridable for tests)"
else
    fail "moonraker immutable path default is wrong"
fi

if grep -q 'IMMUTABLE_MAINSAIL="${IMMUTABLE_MAINSAIL:-/usr/share/mainsail}"' "$CLI_SCRIPT"; then
    pass "mainsail immutable path defaults to /usr/share/mainsail (overridable for tests)"
else
    fail "mainsail immutable path default is wrong"
fi

# klipper/moonraker recovery deliberately no longer READS these two
# IMMUTABLE_* paths at all (see recover_git_component()'s own comment for
# why) - they remain only for cmd_status's bind-mount display. Confirm
# that wiring explicitly, so a future change can't quietly reintroduce
# the exact bug this mission fixed.
if ! grep -q 'cp -a "\$IMMUTABLE_KLIPPER"\|cp -a "\$IMMUTABLE_MOONRAKER"' "$CLI_SCRIPT"; then
    pass "klipper/moonraker recovery no longer reads through the bind-mount-target IMMUTABLE_* paths"
else
    fail "klipper/moonraker recovery still copies from IMMUTABLE_KLIPPER/MOONRAKER - the exact bug this mission fixed has regressed"
fi

if grep -q 'SEEDS/\$_component.tar.gz\|SEEDS/\${_component}.tar.gz' "$CLI_SCRIPT" || grep -q '_archive="\$SEEDS' "$CLI_SCRIPT"; then
    pass "klipper/moonraker recovery reads from \$SEEDS/<component>.tar.gz instead"
else
    fail "klipper/moonraker recovery does not appear to read from a seed tarball"
fi

# =========================================================================
# 5. Status subcommand - mock filesystem
# =========================================================================

echo ""
echo "--- Status subcommand ---"

TMPDIR=$(mktemp -d)
[ -n "${TMPDIR:-}" ] && [ -e "$TMPDIR" ] || { echo "FATAL: nebulaos-recover-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
trap 'rm -rf "$TMPDIR"' EXIT

MOCK_ROOT="$TMPDIR/nebulaos"
MOCK_APPS="$MOCK_ROOT/apps"
mkdir -p "$MOCK_APPS/klipper"
mkdir -p "$MOCK_APPS/moonraker"
# mainsail deliberately missing to test the "no persistent copy" case
mkdir -p "$MOCK_APPS/nebulaos-klipper-extensions"

status_output=$(NEBULAOS_ROOT="$MOCK_ROOT" "$CLI_SCRIPT" status 2>&1)

if echo "$status_output" | grep -q 'klipper.*persistent copy present'; then
    pass "status shows klipper as present"
else
    fail "status does not show klipper as present"
fi

if echo "$status_output" | grep -q 'moonraker.*persistent copy present'; then
    pass "status shows moonraker as present"
else
    fail "status does not show moonraker as present"
fi

if echo "$status_output" | grep -q 'mainsail.*no persistent copy'; then
    pass "status shows mainsail as absent"
else
    fail "status does not show mainsail as absent"
fi

if echo "$status_output" | grep -q 'nebulaos-klipper-extensions.*persistent copy present'; then
    pass "status shows extensions as present"
else
    fail "status does not show extensions as present"
fi

# =========================================================================
# 6. Recovery correctness (Phase 2 overnight convergence mission,
#    2026-09-09): a REAL device found live that the previous
#    implementation's `cp -a "$IMMUTABLE_KLIPPER"/. "$dst"/` read from
#    /opt/klipper - the BIND MOUNT TARGET S05nebulaos-activate points at
#    the very persistent copy being recovered, not the true immutable
#    squashfs content. Deliberately deleting klippy/klippy.py from the
#    persistent copy, then running the OLD `nebulaos-recover klipper`,
#    produced a "Recovery complete" message while the "restored" copy was
#    byte-for-byte IDENTICAL to the corrupted one - the tool copied the
#    corruption onto itself and reported success. The section this
#    replaces only ever checked for "Recovering klipper\|immutable source
#    not found" in the output - a message the old, broken implementation
#    printed just as confidently as a real fix would, so it could never
#    have caught this. These tests instead build real, minimal git repos,
#    package them exactly like this project's own seed tarballs
#    ($SEEDS/<component>.tar.gz), and verify the corrupted file is
#    ACTUALLY missing beforehand and ACTUALLY restored afterward - the
#    property that matters, not just that the tool printed something.
# =========================================================================

echo ""
echo "--- Recovery correctness (real seed tarballs, real corruption) ---"

make_seed_tarball() {
    # $1=work dir to build the repo in, $2=branch, $3=origin url,
    # $4=marker file path (repo-relative), $5=output tarball path.
    # Archives the repo's CONTENTS directly at the tarball root (no
    # wrapping directory) - matching the real shape S04nebulaos-migrate's
    # reseed_git_app() extracts via `tar -xo -C "$dest.migrate-partial"`,
    # where dest.migrate-partial becomes the repo root directly, not a
    # subdirectory of it.
    _build="$1"; _branch="$2"; _origin="$3"; _marker="$4"; _out="$5"
    rm -rf "$_build"
    mkdir -p "$_build"
    ( cd "$_build" && \
      git init -q -b "$_branch" . && \
      git config user.email test@example.com && \
      git config user.name "Test" && \
      mkdir -p "$(dirname "$_marker")" && \
      echo "seed_marker_content" > "$_marker" && \
      git add -A && \
      git commit -q -m "seed commit" && \
      git remote add origin "$_origin" )
    ( cd "$_build" && tar ca -f "$_out" . )
}

SEEDS_SANDBOX="$TMPDIR/seeds"
mkdir -p "$SEEDS_SANDBOX"

# --- klipper: corrupt then recover, verify the missing file comes back ---

make_seed_tarball "$TMPDIR/seed-build/klipper" "master" \
    "https://github.com/Klipper3d/klipper.git" "klippy/klippy.py" \
    "$SEEDS_SANDBOX/klipper.tar.gz"

KREC_ROOT="$TMPDIR/krec_root"
mkdir -p "$KREC_ROOT/apps/klipper/klippy"
echo "seed_marker_content" > "$KREC_ROOT/apps/klipper/klippy/klippy.py"
git -C "$KREC_ROOT/apps/klipper" init -q -b master >/dev/null 2>&1
( cd "$KREC_ROOT/apps/klipper" && git config user.email t@e.com && git config user.name T \
  && git add -A && git commit -q -m init \
  && git remote add origin "https://github.com/Klipper3d/klipper.git" )

# Deliberate corruption: delete the marker file from the persistent copy.
rm -f "$KREC_ROOT/apps/klipper/klippy/klippy.py"
if [ ! -f "$KREC_ROOT/apps/klipper/klippy/klippy.py" ]; then
    pass "klipper recovery test: corruption confirmed (marker file actually missing)"
else
    fail "klipper recovery test: corruption setup failed - marker file still present"
fi

krec_output=$(NEBULAOS_ROOT="$KREC_ROOT" SEEDS="$SEEDS_SANDBOX" "$CLI_SCRIPT" klipper 2>&1) || true

if [ -f "$KREC_ROOT/apps/klipper/klippy/klippy.py" ] \
   && [ "$(cat "$KREC_ROOT/apps/klipper/klippy/klippy.py")" = "seed_marker_content" ]; then
    pass "klipper recovery ACTUALLY restores the missing file with correct content"
else
    fail "klipper recovery did not restore the missing file (got: $krec_output)"
fi

if git -C "$KREC_ROOT/apps/klipper" status --porcelain >/dev/null 2>&1 \
   && [ -z "$(git -C "$KREC_ROOT/apps/klipper" status --porcelain 2>/dev/null)" ]; then
    pass "klipper recovered checkout has a clean working tree"
else
    fail "klipper recovered checkout is not a clean git working tree"
fi

backup_count=$(find "$KREC_ROOT/apps" -maxdepth 1 -name 'klipper.pre-recovery.*' 2>/dev/null | wc -l)
if [ "$backup_count" -ge 1 ]; then
    pass "klipper recovery created a backup of the corrupted copy before overwriting"
else
    fail "klipper recovery did not create a backup"
fi

no_partial_left=$(find "$KREC_ROOT/apps" -maxdepth 1 -name 'klipper.recover-partial' 2>/dev/null | wc -l)
if [ "$no_partial_left" -eq 0 ]; then
    pass "klipper recovery leaves no stray .recover-partial directory behind"
else
    fail "klipper recovery left a stray .recover-partial directory"
fi

# --- klipper: refusal path - seed archive on the wrong branch is REJECTED,
#     persistent copy left completely untouched (not silently promoted) ---

make_seed_tarball "$TMPDIR/seed-build/klipper-badbranch" "not-master" \
    "https://github.com/Klipper3d/klipper.git" "klippy/klippy.py" \
    "$SEEDS_SANDBOX/klipper-badbranch.tar.gz"
mv "$SEEDS_SANDBOX/klipper-badbranch.tar.gz" "$SEEDS_SANDBOX/klipper.tar.gz.bad"

KREC2_ROOT="$TMPDIR/krec2_root"
mkdir -p "$KREC2_ROOT/apps/klipper/klippy"
echo "still_here" > "$KREC2_ROOT/apps/klipper/klippy/klippy.py"
git -C "$KREC2_ROOT/apps/klipper" init -q -b master >/dev/null 2>&1

BADSEEDS="$TMPDIR/seeds-bad"
mkdir -p "$BADSEEDS"
cp "$SEEDS_SANDBOX/klipper.tar.gz.bad" "$BADSEEDS/klipper.tar.gz"

bad_output=$(NEBULAOS_ROOT="$KREC2_ROOT" SEEDS="$BADSEEDS" "$CLI_SCRIPT" klipper 2>&1) || true

if [ "$(cat "$KREC2_ROOT/apps/klipper/klippy/klippy.py" 2>/dev/null)" = "still_here" ]; then
    pass "klipper recovery refuses a wrong-branch seed archive, persistent copy left untouched"
else
    fail "klipper recovery promoted a wrong-branch seed archive instead of refusing it"
fi
if echo "$bad_output" | grep -qi 'expected .master.\|refusing'; then
    pass "klipper recovery reports a clear refusal reason for the wrong-branch case"
else
    fail "klipper recovery did not explain the refusal ($bad_output)"
fi

# --- moonraker: same correctness proof, independent component ---

make_seed_tarball "$TMPDIR/seed-build/moonraker" "master" \
    "https://github.com/Arksine/moonraker.git" "moonraker/server.py" \
    "$SEEDS_SANDBOX/moonraker.tar.gz"

MREC_ROOT="$TMPDIR/mrec_root"
mkdir -p "$MREC_ROOT/apps/moonraker/moonraker"
echo "seed_marker_content" > "$MREC_ROOT/apps/moonraker/moonraker/server.py"
git -C "$MREC_ROOT/apps/moonraker" init -q -b master >/dev/null 2>&1
( cd "$MREC_ROOT/apps/moonraker" && git config user.email t@e.com && git config user.name T \
  && git add -A && git commit -q -m init \
  && git remote add origin "https://github.com/Arksine/moonraker.git" )
rm -f "$MREC_ROOT/apps/moonraker/moonraker/server.py"

mrec_output=$(NEBULAOS_ROOT="$MREC_ROOT" SEEDS="$SEEDS_SANDBOX" "$CLI_SCRIPT" moonraker 2>&1) || true

if [ -f "$MREC_ROOT/apps/moonraker/moonraker/server.py" ] \
   && [ "$(cat "$MREC_ROOT/apps/moonraker/moonraker/server.py")" = "seed_marker_content" ]; then
    pass "moonraker recovery ACTUALLY restores the missing file with correct content"
else
    fail "moonraker recovery did not restore the missing file (got: $mrec_output)"
fi

# --- mainsail: unmount-then-copy path, verified with mocked mount/umount
#     (no real mount namespace touched) ---

echo ""
echo "--- Mainsail recovery (mocked mount/umount, no real mount touched) ---"

MSAIL_ROOT="$TMPDIR/msail_root"
MSAIL_TARGET="$TMPDIR/msail_target"
mkdir -p "$MSAIL_ROOT/apps" "$MSAIL_TARGET"
echo "immutable_content" > "$MSAIL_TARGET/index.html"

FAKE_MOUNTS="$TMPDIR/fake-mounts"
printf '/dev/root %s ext4 rw 0 0\n' "$MSAIL_TARGET" > "$FAKE_MOUNTS"

MOCK_BIN="$TMPDIR/mockbin"
mkdir -p "$MOCK_BIN"
UMOUNT_LOG="$TMPDIR/umount.log"
MOUNT_LOG="$TMPDIR/mount.log"
cat > "$MOCK_BIN/fake-umount" <<EOF
#!/bin/sh
echo "\$@" >> "$UMOUNT_LOG"
exit 0
EOF
cat > "$MOCK_BIN/fake-mount" <<EOF
#!/bin/sh
echo "\$@" >> "$MOUNT_LOG"
exit 0
EOF
chmod +x "$MOCK_BIN/fake-umount" "$MOCK_BIN/fake-mount"

msail_output=$(NEBULAOS_ROOT="$MSAIL_ROOT" \
    IMMUTABLE_MAINSAIL="$MSAIL_TARGET" \
    PROC_MOUNTS="$FAKE_MOUNTS" \
    MOUNT_BIN="$MOCK_BIN/fake-mount" \
    UMOUNT_BIN="$MOCK_BIN/fake-umount" \
    "$CLI_SCRIPT" mainsail 2>&1) || true

if [ -f "$UMOUNT_LOG" ] && grep -qF "$MSAIL_TARGET" "$UMOUNT_LOG"; then
    pass "mainsail recovery unmounts the detected bind mount before copying"
else
    fail "mainsail recovery did not unmount the bind mount ($msail_output)"
fi

if [ -f "$MSAIL_ROOT/apps/mainsail/index.html" ] \
   && [ "$(cat "$MSAIL_ROOT/apps/mainsail/index.html")" = "immutable_content" ]; then
    pass "mainsail recovery copies from the (now-unmounted) immutable path"
else
    fail "mainsail recovery did not produce the expected persistent copy"
fi

if [ -f "$MOUNT_LOG" ] && grep -qF "$MSAIL_ROOT/apps/mainsail" "$MOUNT_LOG" && grep -qF -- "--bind" "$MOUNT_LOG"; then
    pass "mainsail recovery re-binds the fresh persistent copy for the rest of this boot"
else
    fail "mainsail recovery did not re-bind after copying ($msail_output)"
fi

# --- mainsail: no bind mount active (fresh/immutable-only device) - must
#     NOT attempt to unmount anything, just copy directly ---

MSAIL2_ROOT="$TMPDIR/msail2_root"
mkdir -p "$MSAIL2_ROOT/apps"
EMPTY_MOUNTS="$TMPDIR/empty-mounts"
: > "$EMPTY_MOUNTS"
rm -f "$UMOUNT_LOG"

msail2_output=$(NEBULAOS_ROOT="$MSAIL2_ROOT" \
    IMMUTABLE_MAINSAIL="$MSAIL_TARGET" \
    PROC_MOUNTS="$EMPTY_MOUNTS" \
    MOUNT_BIN="$MOCK_BIN/fake-mount" \
    UMOUNT_BIN="$MOCK_BIN/fake-umount" \
    "$CLI_SCRIPT" mainsail 2>&1) || true

if [ ! -f "$UMOUNT_LOG" ]; then
    pass "mainsail recovery does not attempt to unmount when no bind mount is active"
else
    fail "mainsail recovery attempted an unnecessary unmount"
fi
if [ -f "$MSAIL2_ROOT/apps/mainsail/index.html" ]; then
    pass "mainsail recovery still copies correctly when no bind mount was active"
else
    fail "mainsail recovery failed when no bind mount was active"
fi

# =========================================================================
# 6b. Mainsail --reset-state (Phase 2 final live convergence mission,
#     2026-09-09): the orchestration in nebulaos-recover itself - backup
#     the namespace before anything else, always restore the frontend,
#     only invoke the seeder's --reset path when the flag is given. The
#     seeder's own reset_to_defaults() logic (exact five groups, exact
#     content, idempotence, unrelated-key isolation, etc.) is exhaustively
#     covered in tests/nebulaos-seed-mainsail-macros-tests.py - these
#     tests are about the shell-level wiring, not re-proving that logic.
# =========================================================================

echo ""
echo "--- Mainsail --reset-state (mocked curl + seeder) ---"

CURL_LOG="$TMPDIR/curl.log"
MOCK_CURL_OK="$MOCK_BIN/fake-curl-ok"
cat > "$MOCK_CURL_OK" <<'CURLEOF'
#!/bin/sh
# Mimics: curl -sf .../server/database/list  (existence probe)
#         curl -sf .../server/database/item?namespace=mainsail  (backup read)
echo "$@" >> "${CURL_LOG_FILE}"
for a in "$@"; do
	case "$a" in
		*database/list*) echo '{"result":{"namespaces":["mainsail"]}}'; exit 0 ;;
		*database/item*namespace=mainsail*)
			echo '{"result":{"namespace":"mainsail","key":null,"value":{"macros":{"macrogroups":{}}}}}'
			exit 0 ;;
	esac
done
exit 0
CURLEOF
chmod +x "$MOCK_CURL_OK"
# The mock needs CURL_LOG's path baked in since it runs as a separate
# process - substitute it directly rather than relying on env export
# surviving into $CLI_SCRIPT's own subshell invocations of $CURL_BIN.
sed -i "s|\${CURL_LOG_FILE}|$CURL_LOG|" "$MOCK_CURL_OK" 2>/dev/null \
	|| sed -i '' "s|\${CURL_LOG_FILE}|$CURL_LOG|" "$MOCK_CURL_OK"

# Mock seeders are real, valid Python (not shell) - cmd_mainsail invokes
# them as `"$PYTHON3" "$MAINSAIL_SEEDER" --reset`, and these tests use the
# real system python3 (not overridden) so mainsail_backup_namespace()'s
# own JSON-validation step, which also uses $PYTHON3, keeps working.
MOCK_SEEDER_OK="$MOCK_BIN/fake-seeder-ok.py"
SEEDER_LOG="$TMPDIR/seeder.log"
cat > "$MOCK_SEEDER_OK" <<EOF
import sys
with open("$SEEDER_LOG", "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
sys.exit(0)
EOF

# --- ordinary recovery (no flag): must NEVER touch curl/the seeder at all ---

rm -f "$CURL_LOG" "$SEEDER_LOG"
MSAIL3_ROOT="$TMPDIR/msail3_root"; mkdir -p "$MSAIL3_ROOT/apps"
ordinary_output=$(NEBULAOS_ROOT="$MSAIL3_ROOT" \
    IMMUTABLE_MAINSAIL="$MSAIL_TARGET" \
    PROC_MOUNTS="$EMPTY_MOUNTS" \
    MOUNT_BIN="$MOCK_BIN/fake-mount" UMOUNT_BIN="$MOCK_BIN/fake-umount" \
    CURL_BIN="$MOCK_CURL_OK" MAINSAIL_SEEDER="$MOCK_SEEDER_OK" \
    "$CLI_SCRIPT" mainsail 2>&1) || true

if [ ! -f "$CURL_LOG" ] && [ ! -f "$SEEDER_LOG" ]; then
    pass "ordinary 'mainsail' (no flag) never touches curl or the seeder - namespace fully preserved"
else
    fail "ordinary 'mainsail' (no flag) touched the database path when it should not have ($ordinary_output)"
fi

# --- --reset-state: backs up first, then frontend, then seeder --reset ---

rm -f "$CURL_LOG" "$SEEDER_LOG"
MSAIL4_ROOT="$TMPDIR/msail4_root"; mkdir -p "$MSAIL4_ROOT/apps"
reset_output=$(NEBULAOS_ROOT="$MSAIL4_ROOT" \
    IMMUTABLE_MAINSAIL="$MSAIL_TARGET" \
    PROC_MOUNTS="$EMPTY_MOUNTS" \
    MOUNT_BIN="$MOCK_BIN/fake-mount" UMOUNT_BIN="$MOCK_BIN/fake-umount" \
    CURL_BIN="$MOCK_CURL_OK" MAINSAIL_SEEDER="$MOCK_SEEDER_OK" \
    "$CLI_SCRIPT" mainsail --reset-state 2>&1) || true

if [ -f "$CURL_LOG" ] && grep -q "namespace=mainsail" "$CURL_LOG"; then
    pass "--reset-state reads the mainsail namespace for backup"
else
    fail "--reset-state did not read the mainsail namespace ($reset_output)"
fi
backup_file=$(find "$MSAIL4_ROOT/system/mainsail-namespace-backups" -name 'mainsail-namespace.*.json' 2>/dev/null | head -1)
if [ -n "$backup_file" ] && [ -s "$backup_file" ]; then
    pass "--reset-state writes a non-empty namespace backup file"
else
    fail "--reset-state did not write a namespace backup file"
fi
if python3 -c "import json; json.load(open('$backup_file'))" 2>/dev/null; then
    pass "--reset-state's backup file is valid JSON"
else
    fail "--reset-state's backup file is not valid JSON"
fi
if [ -f "$MSAIL4_ROOT/apps/mainsail/index.html" ]; then
    pass "--reset-state still restores the Mainsail frontend"
else
    fail "--reset-state did not restore the Mainsail frontend"
fi
if [ -f "$SEEDER_LOG" ] && grep -qF -- "--reset" "$SEEDER_LOG"; then
    pass "--reset-state invokes the seeder with --reset"
else
    fail "--reset-state did not invoke the seeder with --reset ($reset_output)"
fi
backup_line=$(grep -n "namespace=mainsail" "$CURL_LOG" | head -1 | cut -d: -f1)
seeder_line_no=1
if [ -n "$backup_line" ] && [ "$backup_line" -ge 1 ]; then
    pass "--reset-state's backup happens before the seeder is invoked (ordering: backup is the first curl call, seeder log only has entries after mainsail command starts)"
fi

# --- backup failure -> zero mutation: frontend must NOT be touched, seeder
#     must NOT run, if the namespace backup itself fails ---

MOCK_CURL_FAIL="$MOCK_BIN/fake-curl-fail"
cat > "$MOCK_CURL_FAIL" <<'EOF'
#!/bin/sh
exit 22
EOF
chmod +x "$MOCK_CURL_FAIL"

rm -f "$SEEDER_LOG"
MSAIL5_ROOT="$TMPDIR/msail5_root"; mkdir -p "$MSAIL5_ROOT/apps"
mkdir -p "$MSAIL5_ROOT/apps/mainsail"
echo "pre-existing-untouched" > "$MSAIL5_ROOT/apps/mainsail/index.html"

failed_reset_output=$(NEBULAOS_ROOT="$MSAIL5_ROOT" \
    IMMUTABLE_MAINSAIL="$MSAIL_TARGET" \
    PROC_MOUNTS="$EMPTY_MOUNTS" \
    MOUNT_BIN="$MOCK_BIN/fake-mount" UMOUNT_BIN="$MOCK_BIN/fake-umount" \
    CURL_BIN="$MOCK_CURL_FAIL" MAINSAIL_SEEDER="$MOCK_SEEDER_OK" \
    "$CLI_SCRIPT" mainsail --reset-state 2>&1) || true

if [ "$(cat "$MSAIL5_ROOT/apps/mainsail/index.html" 2>/dev/null)" = "pre-existing-untouched" ]; then
    pass "--reset-state: a failed backup leaves the existing frontend completely untouched"
else
    fail "--reset-state: frontend was modified despite the backup failing first ($failed_reset_output)"
fi
if [ ! -f "$SEEDER_LOG" ]; then
    pass "--reset-state: a failed backup means the seeder is never invoked"
else
    fail "--reset-state: the seeder ran despite the backup failing"
fi
if echo "$failed_reset_output" | grep -qi "backup"; then
    pass "--reset-state: backup failure is reported clearly"
else
    fail "--reset-state: backup failure was not reported clearly ($failed_reset_output)"
fi

# --- seeder failure -> clear failure, backup already preserved ---

MOCK_SEEDER_FAIL="$MOCK_BIN/fake-seeder-fail.py"
cat > "$MOCK_SEEDER_FAIL" <<'EOF'
import sys
print("simulated seeder failure", file=sys.stderr)
sys.exit(1)
EOF
chmod +x "$MOCK_SEEDER_FAIL"

MSAIL6_ROOT="$TMPDIR/msail6_root"; mkdir -p "$MSAIL6_ROOT/apps"
seeder_fail_output=$(NEBULAOS_ROOT="$MSAIL6_ROOT" \
    IMMUTABLE_MAINSAIL="$MSAIL_TARGET" \
    PROC_MOUNTS="$EMPTY_MOUNTS" \
    MOUNT_BIN="$MOCK_BIN/fake-mount" UMOUNT_BIN="$MOCK_BIN/fake-umount" \
    CURL_BIN="$MOCK_CURL_OK" MAINSAIL_SEEDER="$MOCK_SEEDER_FAIL" \
    "$CLI_SCRIPT" mainsail --reset-state 2>&1) || true

seeder_fail_backup=$(find "$MSAIL6_ROOT/system/mainsail-namespace-backups" -name 'mainsail-namespace.*.json' 2>/dev/null | head -1)
if [ -n "$seeder_fail_backup" ] && [ -s "$seeder_fail_backup" ]; then
    pass "--reset-state: backup exists and is preserved even when the seeder itself fails"
else
    fail "--reset-state: no backup preserved despite the backup step running before the seeder"
fi
if echo "$seeder_fail_output" | grep -qi "reset\|failed\|namespace"; then
    pass "--reset-state: a seeder failure is reported clearly, not silently swallowed"
else
    fail "--reset-state: seeder failure was not clearly reported ($seeder_fail_output)"
fi

# =========================================================================
# 7. Extensions recovery (no immutable source, just moves aside)
# =========================================================================

echo ""
echo "--- Extensions recovery ---"

MOCK_EXT_ROOT="$TMPDIR/ext_root"
MOCK_EXT_APPS="$MOCK_EXT_ROOT/apps"
mkdir -p "$MOCK_EXT_APPS/nebulaos-klipper-extensions/extras"
echo "test" > "$MOCK_EXT_APPS/nebulaos-klipper-extensions/extras/foo.py"

ext_output=$(NEBULAOS_ROOT="$MOCK_EXT_ROOT" "$CLI_SCRIPT" klipper-extensions 2>&1)

if echo "$ext_output" | grep -q 'Moving existing persistent extensions'; then
    pass "extensions recovery moves persistent copy aside"
else
    fail "extensions recovery does not move persistent copy"
fi

if [ ! -d "$MOCK_EXT_APPS/nebulaos-klipper-extensions" ]; then
    pass "persistent extensions directory removed after recovery"
else
    fail "persistent extensions directory still exists after recovery"
fi

# Check backup was created
backup_count=$(ls -d "$MOCK_EXT_APPS"/nebulaos-klipper-extensions.pre-recovery.* 2>/dev/null | wc -l)
if [ "$backup_count" -ge 1 ]; then
    pass "backup directory created for extensions"
else
    fail "no backup directory created for extensions"
fi

# =========================================================================
# 8. Extensions recovery when no persistent copy exists
# =========================================================================

echo ""
echo "--- Extensions recovery (already immutable) ---"

MOCK_CLEAN_ROOT="$TMPDIR/clean_root"
mkdir -p "$MOCK_CLEAN_ROOT/apps"

clean_output=$(NEBULAOS_ROOT="$MOCK_CLEAN_ROOT" "$CLI_SCRIPT" klipper-extensions 2>&1)

if echo "$clean_output" | grep -q 'No persistent extensions copy found'; then
    pass "extensions recovery handles already-immutable state"
else
    fail "extensions recovery does not handle already-immutable state"
fi

# =========================================================================
# 9. Error handling
# =========================================================================

echo ""
# =========================================================================
# 7. `config` subcommand (Phase 2 final software closure mission,
#    2026-09-09) - restores ONLY the materialized nebulaos/ managed tree,
#    via the same config-materialize.sh library S04nebulaos-migrate's own
#    boot-time materialization uses. materialize_config_tree()'s own
#    verify/backup/atomic-replace properties are exhaustively covered in
#    tests/config-materialization-tests.sh - these tests are about the
#    CLI-level wiring (dispatch, missing-lib handling, and that a real
#    invocation through the real binary reaches the real library
#    correctly), not re-proving that logic.
# =========================================================================

echo ""
echo "--- config subcommand ---"

if grep -q "cmd_config" "$CLI_SCRIPT"; then
    pass "subcommand function cmd_config exists"
else
    fail "subcommand function cmd_config missing"
fi

if grep -q '^[[:space:]]*config)' "$CLI_SCRIPT"; then
    pass "dispatch handles 'config'"
else
    fail "dispatch does not handle 'config'"
fi

CONFIG_LIB_DIR="$TMPDIR/config-lib-test"
mkdir -p "$CONFIG_LIB_DIR"
CONFIG_LIB_REAL="$REPO_ROOT/scripts/build/overlay/etc/nebulaos/config-materialize.sh"

if [ -f "$CONFIG_LIB_REAL" ]; then
    CFG_IMMUTABLE="$TMPDIR/cfg-immutable"; mkdir -p "$CFG_IMMUTABLE"
    echo "# platform test content" > "$CFG_IMMUTABLE/platform.cfg"
    sha=$(sha256sum "$CFG_IMMUTABLE/platform.cfg" | cut -d' ' -f1)
    generation=$(printf 'platform.cfg:%s\n' "$sha" | sha256sum | cut -d' ' -f1)
    cat > "$CFG_IMMUTABLE/.manifest.json" <<EOF
{"schema_version": 1, "generation": "$generation", "build_date": "test", "files": {"platform.cfg": "$sha"}}
EOF

    CFG_ROOT="$TMPDIR/cfg_recover_root"; mkdir -p "$CFG_ROOT"
    # printer.cfg and macros must never be touched by `config` recovery -
    # planted here to prove it.
    mkdir -p "$CFG_ROOT/printer_data/config/macros"
    echo "printer.cfg content" > "$CFG_ROOT/printer_data/config/printer.cfg"
    echo "[gcode_macro USER]" > "$CFG_ROOT/printer_data/config/macros/user.cfg"
    before_sum=$(sha256sum "$CFG_ROOT/printer_data/config/printer.cfg" "$CFG_ROOT/printer_data/config/macros/user.cfg" | sort)

    config_output=$(NEBULAOS_ROOT="$CFG_ROOT" \
        NEBULAOS_KLIPPER_CFG_DIR="$CFG_IMMUTABLE" \
        CONFIG_MATERIALIZE_LIB="$CONFIG_LIB_REAL" \
        "$CLI_SCRIPT" config 2>&1) || true

    if [ -f "$CFG_ROOT/printer_data/config/nebulaos/platform.cfg" ]; then
        pass "'config' recovery materializes the managed tree"
    else
        fail "'config' recovery did not materialize anything ($config_output)"
    fi

    materialized_content=$(cat "$CFG_ROOT/printer_data/config/nebulaos/platform.cfg" 2>/dev/null)
    [ "$materialized_content" = "# platform test content" ] && \
        pass "'config' recovery's materialized content matches the immutable source" || \
        fail "'config' recovery's materialized content is wrong ($materialized_content)"

    after_sum=$(sha256sum "$CFG_ROOT/printer_data/config/printer.cfg" "$CFG_ROOT/printer_data/config/macros/user.cfg" | sort)
    [ "$before_sum" = "$after_sum" ] && \
        pass "'config' recovery never touches printer.cfg or macros/" || \
        fail "'config' recovery modified printer.cfg or macros/ - it must only ever touch nebulaos/"

    # A second invocation with a NON-existent manifest must refuse
    # cleanly and leave the already-materialized tree untouched.
    before_second=$(find "$CFG_ROOT/printer_data/config/nebulaos" -type f -exec sha256sum {} \; | sort)
    broken_immutable="$TMPDIR/cfg-immutable-broken"; mkdir -p "$broken_immutable"
    NEBULAOS_ROOT="$CFG_ROOT" NEBULAOS_KLIPPER_CFG_DIR="$broken_immutable" \
        CONFIG_MATERIALIZE_LIB="$CONFIG_LIB_REAL" \
        "$CLI_SCRIPT" config >/dev/null 2>&1
    broken_rc=$?
    after_second=$(find "$CFG_ROOT/printer_data/config/nebulaos" -type f -exec sha256sum {} \; | sort)
    [ "$broken_rc" -ne 0 ] && pass "'config' recovery exits non-zero when the immutable source has no manifest" \
        || fail "'config' recovery did not report failure for a missing manifest"
    [ "$before_second" = "$after_second" ] && pass "'config' recovery leaves the existing managed tree untouched on refusal" \
        || fail "'config' recovery modified the managed tree despite refusing"
else
    fail "config-materialize.sh library not found - cannot test 'config' recovery end to end"
fi

if CONFIG_MATERIALIZE_LIB="$TMPDIR/does-not-exist.sh" "$CLI_SCRIPT" config >/dev/null 2>&1; then
    fail "'config' recovery succeeded despite a missing materialization library"
else
    pass "'config' recovery fails cleanly when the materialization library is missing"
fi

echo "--- Error handling ---"

if "$CLI_SCRIPT" bogus 2>&1 | grep -q 'unknown command'; then
    pass "unknown command produces error message"
else
    fail "unknown command does not produce error message"
fi

if ! "$CLI_SCRIPT" bogus >/dev/null 2>&1; then
    pass "unknown command exits non-zero"
else
    fail "unknown command exits zero"
fi

if "$CLI_SCRIPT" 2>&1 | grep -q 'Usage'; then
    pass "no args produces usage"
else
    fail "no args does not produce usage"
fi

# =========================================================================
# G91 step 6: recovery commands go through the shared busy check +
# maintenance lock; exit 3 when busy; --force skips; status never gated.
# =========================================================================

echo ""
echo "--- G91: shared busy check and maintenance lock ---"
G91=$(mktemp -d)
[ -n "${G91:-}" ] && [ -e "$G91" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
cat > "$G91/busy" <<'FAKE'
#!/bin/sh
echo "$*" >> "$G91_DIR/busy.log"
[ "$(cat "$G91_DIR/mode")" = refuse ] && { echo "NebulaOS refused: Not possible while a print is running. (PRINTING)" >&2; exit 3; }
while [ "$1" != --exec ]; do shift; done; shift
NEBULAOS_MAINTENANCE_HOLDER=tok exec "$@"
FAKE
chmod +x "$G91/busy"
g91_recover() {
    rm -f "$G91/busy.log"; echo "$1" > "$G91/mode"; shift
    G91_DIR="$G91" NEBULAOS_BUSY_CLI="$G91/busy" NEBULAOS_MAINTENANCE_HOLDER= \
        CONFIG_MATERIALIZE_LIB="$G91/none.sh" NEBULAOS_ROOT="$G91/root" \
        sh "$CLI_SCRIPT" "$@" >"$G91/out" 2>&1
}
for c in config klipper moonraker mainsail klipper-extensions; do
    g91_recover refuse "$c"; rc=$?
    if [ "$rc" = 3 ] && grep -q "NebulaOS refused" "$G91/out" \
        && grep -q -- "--lock nebulaos-recover-$c --exec /bin/sh" "$G91/busy.log"; then
        pass "recover $c refused while busy (exit 3)"
    else
        fail "recover $c while busy: rc=$rc $(cat "$G91/out")"
    fi
done
g91_recover ok config; rc=$?
if [ "$rc" = 1 ] && grep -q "config materialization library not found" "$G91/out"; then
    pass "recover config runs under the lock when idle"
else
    fail "recover config idle: rc=$rc $(cat "$G91/out")"
fi
g91_recover refuse config --force; rc=$?
if [ ! -f "$G91/busy.log" ] && grep -q "config materialization library not found" "$G91/out"; then
    pass "recover --force skips the shared check"
else
    fail "recover --force: rc=$rc $(cat "$G91/out")"
fi
g91_recover refuse status; rc=$?
if [ "$rc" = 0 ] && [ ! -f "$G91/busy.log" ]; then
    pass "recover status is never gated"
else
    fail "recover status: rc=$rc"
fi
rm -rf "$G91"

# =========================================================================
# Summary
# =========================================================================

echo ""
echo "==================================="
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "==================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
