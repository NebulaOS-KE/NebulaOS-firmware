#!/usr/bin/env bash
#
# Offline adversarial tests for tools/attest/nebulaos-attest.py.
#
# The point of these is not that signing works - that is one assertion. It is
# that every way of NOT having a valid attestation is refused, and refused for
# the RIGHT REASON. A forged attestation that gets rejected because of an
# unrelated missing field is a test that would keep passing after the MAC check
# was removed, so each negative case here asserts on the reason text too.
#
# Uses a throwaway key under a temp directory. It never reads, writes, creates
# or requires the real key at ~/.config/nebulaos-attest/attest.key - that key is
# human-created and deliberately out of reach of anything automated, including
# this suite.
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ATTEST="$SCRIPT_DIR/../tools/attest/nebulaos-attest.py"
[ -f "$ATTEST" ] || { echo "FATAL: $ATTEST not found" >&2; exit 1; }

PASS=0; FAIL=0
ok(){   PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad(){  FAIL=$((FAIL+1)); printf 'FAIL  %s\n       %s\n' "$1" "${2:-}"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nebulaos-attest-tests.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

KEYDIR="$WORK/keys"
mkdir -p -m 0700 "$KEYDIR"
KEY="$KEYDIR/attest.key"
head -c 64 /dev/urandom > "$KEY"
chmod 0600 "$KEY"

OTHERDIR="$WORK/otherkeys"
mkdir -p -m 0700 "$OTHERDIR"
OTHERKEY="$OTHERDIR/attest.key"
head -c 64 /dev/urandom > "$OTHERKEY"
chmod 0600 "$OTHERKEY"

attest(){ NEBULAOS_ATTEST_KEY="$KEY" python3 "$ATTEST" "$@"; }
attest_other(){ NEBULAOS_ATTEST_KEY="$OTHERKEY" python3 "$ATTEST" "$@"; }

X_SHA=$(printf 'ximage'  | sha256sum | cut -d' ' -f1)
R_SHA=$(printf 'rootfs'  | sha256sum | cut -d' ' -f1)
M_SHA=$(printf 'manifest'| sha256sum | cut -d' ' -f1)
L_SHA=$(printf 'buildlog'| sha256sum | cut -d' ' -f1)
HEAD_SHA=fd4a365e9cc2b7dd478547bde00a272decee220e

# A complete, well-formed v2 field set. Individual tests copy this and break
# exactly one thing, so a refusal can only be attributed to that one change.
mkfields(){
  cat <<EOF
ATTESTATION_VERSION=2
SOURCE_HEAD=$HEAD_SHA
SOURCE_REPO=https://github.com/NebulaOS-KE/NebulaOS-firmware.git
SOURCE_PUBLISHED_TIP=$HEAD_SHA
BUILD_LAUNCHER_BLOB=$(printf 'launcher' | sha256sum | cut -d' ' -f1)
BUILD_MODE=candidate
BUILD_PROFILE=release
CCACHE=disabled
BUILD_LOG_SHA256=$L_SHA
XIMAGE_SHA256=$X_SHA
XIMAGE_SIZE=5509184
ROOTFS_SQUASHFS_SHA256=$R_SHA
ROOTFS_SQUASHFS_SIZE=99758080
MANIFEST_SHA256=$M_SHA
BUILDER_DIGEST=sha256:a6ba57c69fa1ea630b037a1d1f55cf0c044a7f5a403bde9b155ea54bca1cceba
SOURCE_DATE_EPOCH=1790442459
BUILD_RUN=/var/tmp/nebulaos-build/$HEAD_SHA/run-20260926T173241Z-1106934
ATTESTED_AT=2026-09-28T00:00:00Z
EOF
}

echo "=== nebulaos-attest v2: adversarial suite ==="
echo

# --- 1. the happy path ------------------------------------------------------
GOOD="$WORK/good.att"
if mkfields | attest sign --out "$GOOD" 2>/dev/null; then
  ok "sign produces an attestation from a complete v2 field set"
else
  bad "sign produces an attestation from a complete v2 field set" "sign failed"
fi

if grep -q '^MAC=[0-9a-f]\{64\}$' "$GOOD" 2>/dev/null; then
  ok "the signed attestation carries a 64-hex MAC"
else
  bad "the signed attestation carries a 64-hex MAC" "$(cat "$GOOD" 2>/dev/null | tail -2)"
fi

if attest verify --in "$GOOD" >/dev/null 2>&1; then
  ok "verify accepts an unmodified attestation"
else
  bad "verify accepts an unmodified attestation" "$(attest verify --in "$GOOD" 2>&1 | tail -3)"
fi

# The MAC must be deterministic for the same fields and key, or two runs of the
# same build could not be compared.
S1=$(mkfields | attest sign 2>/dev/null | grep '^MAC=')
S2=$(mkfields | attest sign 2>/dev/null | grep '^MAC=')
if [ -n "$S1" ] && [ "$S1" = "$S2" ]; then
  ok "the MAC is deterministic for identical fields and key"
else
  bad "the MAC is deterministic for identical fields and key" "$S1 vs $S2"
fi

# Field ORDER must not change the MAC - the MAC covers a canonical form, and a
# reformatted attestation is still the same attestation.
SHUF=$(mkfields | sort -r | attest sign 2>/dev/null | grep '^MAC=')
if [ "$SHUF" = "$S1" ]; then
  ok "the MAC is independent of field order (canonicalisation works)"
else
  bad "the MAC is independent of field order (canonicalisation works)" "$SHUF vs $S1"
fi

# --- 2. forgery: every field is covered -------------------------------------
# Tampering with ANY covered field must fail verification with a MAC mismatch,
# not with some incidental complaint.
tamper_case(){
  local name=$1 sed_expr=$2
  local f="$WORK/t.att"
  sed "$sed_expr" "$GOOD" > "$f"
  local out rc
  out=$(attest verify --in "$f" 2>&1); rc=$?
  if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'MAC mismatch'; then
    ok "tampering with $name is refused as a MAC mismatch"
  else
    bad "tampering with $name is refused as a MAC mismatch" "rc=$rc out=$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
  fi
}

tamper_case "XIMAGE_SHA256"         "s|^XIMAGE_SHA256=.*|XIMAGE_SHA256=$(printf 'evil' | sha256sum | cut -d' ' -f1)|"
tamper_case "ROOTFS_SQUASHFS_SHA256" "s|^ROOTFS_SQUASHFS_SHA256=.*|ROOTFS_SQUASHFS_SHA256=$(printf 'evil' | sha256sum | cut -d' ' -f1)|"
tamper_case "SOURCE_HEAD"           "s|^SOURCE_HEAD=.*|SOURCE_HEAD=0000000000000000000000000000000000000000|"
tamper_case "BUILD_PROFILE"         "s|^BUILD_PROFILE=.*|BUILD_PROFILE=release-ish|"
tamper_case "BUILD_MODE"            "s|^BUILD_MODE=.*|BUILD_MODE=qualified|"
tamper_case "CCACHE"                "s|^CCACHE=.*|CCACHE=enabled|"
tamper_case "BUILDER_DIGEST"        "s|^BUILDER_DIGEST=.*|BUILDER_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000|"
tamper_case "SOURCE_DATE_EPOCH"     "s|^SOURCE_DATE_EPOCH=.*|SOURCE_DATE_EPOCH=1|"
tamper_case "MANIFEST_SHA256"       "s|^MANIFEST_SHA256=.*|MANIFEST_SHA256=$(printf 'evil' | sha256sum | cut -d' ' -f1)|"
tamper_case "XIMAGE_SIZE"           "s|^XIMAGE_SIZE=.*|XIMAGE_SIZE=1|"

# Adding an extra field must also break the MAC: the canonical form covers
# every field present, not just the ones in the required list, so a forger
# cannot smuggle in an unsigned rider.
EXTRA="$WORK/extra.att"
{ grep -v '^MAC=' "$GOOD"; echo "SMUGGLED=whatever"; grep '^MAC=' "$GOOD"; } > "$EXTRA"
out=$(attest verify --in "$EXTRA" 2>&1); rc=$?
if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'MAC mismatch'; then
  ok "appending an unsigned extra field is refused as a MAC mismatch"
else
  bad "appending an unsigned extra field is refused as a MAC mismatch" "rc=$rc"
fi

# Removing a field likewise.
DROP="$WORK/drop.att"
grep -v '^BUILD_RUN=' "$GOOD" > "$DROP"
out=$(attest verify --in "$DROP" 2>&1); rc=$?
if [ "$rc" -eq 3 ]; then
  ok "removing a covered field fails verification"
else
  bad "removing a covered field fails verification" "rc=$rc"
fi

# --- 3. wrong key -----------------------------------------------------------
out=$(attest_other verify --in "$GOOD" 2>&1); rc=$?
if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'MAC mismatch'; then
  ok "an attestation does not verify under a different key"
else
  bad "an attestation does not verify under a different key" "rc=$rc"
fi

KID_A=$(attest keyid 2>/dev/null | grep '^KEY_ID=')
KID_B=$(attest_other keyid 2>/dev/null | grep '^KEY_ID=')
if [ -n "$KID_A" ] && [ -n "$KID_B" ] && [ "$KID_A" != "$KID_B" ]; then
  ok "different keys have different KEY_IDs"
else
  bad "different keys have different KEY_IDs" "$KID_A / $KID_B"
fi

# KEY_ID must not leak the key. A 16-hex tag cannot contain 64 bytes of key,
# but assert the obvious containment anyway.
if ! attest keyid 2>/dev/null | grep -qF "$(head -c 16 "$KEY" | od -An -tx1 | tr -d ' \n')"; then
  ok "keyid output does not contain raw key material"
else
  bad "keyid output does not contain raw key material" "key bytes appear in output"
fi

# --- 4. no re-signing -------------------------------------------------------
out=$(attest sign --in "$GOOD" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'already carries a MAC'; then
  ok "re-signing an already-signed attestation is refused"
else
  bad "re-signing an already-signed attestation is refused" "rc=$rc"
fi

# A forger must not be able to launder a tampered record by re-signing it.
LAUNDER="$WORK/launder.att"
sed "s|^XIMAGE_SHA256=.*|XIMAGE_SHA256=$(printf 'evil' | sha256sum | cut -d' ' -f1)|" "$GOOD" > "$LAUNDER"
out=$(attest sign --in "$LAUNDER" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then
  ok "a tampered attestation cannot be laundered by re-signing"
else
  bad "a tampered attestation cannot be laundered by re-signing" "rc=$rc"
fi

# --- 5. v1 is never silently upgraded ---------------------------------------
# This is the specific regression the mission calls out. A v1 record is
# unauthenticated; feeding it to verify must fail, and feeding it to sign must
# refuse rather than quietly minting a v2 MAC over v1 content.
V1="$WORK/v1.att"
cat > "$V1" <<EOF
BUILD_VERIFIED=YES
SOURCE_HEAD=$HEAD_SHA
BUILD_MODE=candidate
BUILD_RUN=/var/tmp/nebulaos-build/$HEAD_SHA/run-x
XIMAGE_SHA256=$X_SHA
XIMAGE_SIZE=5509184
ROOTFS_SQUASHFS_SHA256=$R_SHA
ROOTFS_SQUASHFS_SIZE=99758080
BUILDER_DIGEST=sha256:a6ba57c69fa1ea630b037a1d1f55cf0c044a7f5a403bde9b155ea54bca1cceba
SOURCE_DATE_EPOCH=1790442459
ATTESTED_AT=2026-09-26T18:07:29Z
EOF
out=$(attest verify --in "$V1" 2>&1); rc=$?
if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'no MAC'; then
  ok "a v1 attestation does not verify as v2 (no MAC)"
else
  bad "a v1 attestation does not verify as v2 (no MAC)" "rc=$rc out=$(printf '%s' "$out" | head -1)"
fi

out=$(attest sign --in "$V1" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'does not state ATTESTATION_VERSION'; then
  ok "signing a v1 field set is refused for stating no version (no silent upgrade)"
else
  bad "signing a v1 field set is refused for stating no version (no silent upgrade)" "rc=$rc out=$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
fi

out=$(mkfields | grep -v '^ATTESTATION_VERSION=' | attest sign 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'does not state ATTESTATION_VERSION'; then
  ok "signing refuses to infer a missing ATTESTATION_VERSION"
else
  bad "signing refuses to infer a missing ATTESTATION_VERSION" "rc=$rc"
fi

# An explicit wrong version is refused too.
out=$(mkfields | sed 's|^ATTESTATION_VERSION=2|ATTESTATION_VERSION=1|' | attest sign 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'ATTESTATION_VERSION'; then
  ok "signing with ATTESTATION_VERSION=1 is refused"
else
  bad "signing with ATTESTATION_VERSION=1 is refused" "rc=$rc"
fi

# --- 6. hollow / malformed field sets ---------------------------------------
mk_missing(){ mkfields | grep -v "^$1="; }
mk_empty(){   mkfields | sed "s|^$1=.*|$1=|"; }

for f in SOURCE_REPO BUILD_LAUNCHER_BLOB BUILD_LOG_SHA256 MANIFEST_SHA256 SOURCE_PUBLISHED_TIP; do
  out=$(mk_missing "$f" | NEBULAOS_ATTEST_KEY="$KEY" python3 "$ATTEST" sign 2>&1); rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "missing required v2 field(s): .*$f"; then
    ok "signing without $f is refused as a missing required field"
  else
    bad "signing without $f is refused as a missing required field" "rc=$rc out=$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
  fi
done

for f in SOURCE_REPO BUILD_RUN ATTESTED_AT; do
  out=$(mk_empty "$f" | NEBULAOS_ATTEST_KEY="$KEY" python3 "$ATTEST" sign 2>&1); rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'present but empty'; then
    ok "signing with an empty $f is refused (no hollow attestation)"
  else
    bad "signing with an empty $f is refused (no hollow attestation)" "rc=$rc"
  fi
done

out=$(mkfields | sed 's|^XIMAGE_SHA256=.*|XIMAGE_SHA256=nothex|' | attest sign 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'not a 64-character lowercase hex'; then
  ok "a non-hex XIMAGE_SHA256 is refused"
else
  bad "a non-hex XIMAGE_SHA256 is refused" "rc=$rc out=$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
fi

out=$(mkfields | sed 's|^SOURCE_HEAD=.*|SOURCE_HEAD=fd4a365|' | attest sign 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'SOURCE_HEAD is not a full 40-character'; then
  ok "an abbreviated SOURCE_HEAD is refused"
else
  bad "an abbreviated SOURCE_HEAD is refused" "rc=$rc"
fi

out=$(mkfields | sed 's|^XIMAGE_SIZE=.*|XIMAGE_SIZE=lots|' | attest sign 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'must be a decimal integer'; then
  ok "a non-numeric XIMAGE_SIZE is refused"
else
  bad "a non-numeric XIMAGE_SIZE is refused" "rc=$rc"
fi

# release + ccache is a contradiction and must be unattestable.
out=$(mkfields | sed 's|^CCACHE=.*|CCACHE=enabled|' | attest sign 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'ccache disabled'; then
  ok "BUILD_PROFILE=release with CCACHE=enabled is refused at signing time"
else
  bad "BUILD_PROFILE=release with CCACHE=enabled is refused at signing time" "rc=$rc"
fi

# An installable profile needs a clean build: enforced in the SIGNER, not only
# in the attest-build-run wrapper (which reads an unauthenticated record).
for prof in release candidate; do
  out=$(mkfields | sed "s|^BUILD_PROFILE=.*|BUILD_PROFILE=$prof|; s|^BUILD_MODE=.*|BUILD_MODE=dev|" \
        | attest sign 2>&1); rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'Only a candidate or qualified build'; then
    ok "BUILD_PROFILE=$prof with BUILD_MODE=dev is refused at signing time"
  else
    bad "BUILD_PROFILE=$prof with BUILD_MODE=dev is refused at signing time" "rc=$rc out=$out"
  fi
done
out=$(mkfields | sed 's|^BUILD_PROFILE=.*|BUILD_PROFILE=candidate|; s|^CCACHE=.*|CCACHE=enabled|' \
      | attest sign 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'ccache disabled'; then
  ok "BUILD_PROFILE=candidate with CCACHE=enabled is refused at signing time"
else
  bad "BUILD_PROFILE=candidate with CCACHE=enabled is refused at signing time" "rc=$rc out=$out"
fi

# Duplicate keys must be refused, not silently resolved.
out=$( { mkfields; echo "BUILD_PROFILE=dev"; } | attest sign 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'appears more than once'; then
  ok "a duplicated field is refused rather than last-one-wins"
else
  bad "a duplicated field is refused rather than last-one-wins" "rc=$rc"
fi

# A caller must not be able to assert someone else's KEY_ID.
out=$(mkfields | sed '1i KEY_ID=deadbeefdeadbeef' | attest sign 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'KEY_ID'; then
  ok "an input that claims a foreign KEY_ID is refused"
else
  bad "an input that claims a foreign KEY_ID is refused" "rc=$rc"
fi

# --- 7. key hygiene ---------------------------------------------------------
# Every one of these is a real way a key stops being a key.
BADDIR="$WORK/badperm"
mkdir -p -m 0700 "$BADDIR"
BADKEY="$BADDIR/attest.key"
head -c 64 /dev/urandom > "$BADKEY"

chmod 0644 "$BADKEY"
out=$(NEBULAOS_ATTEST_KEY="$BADKEY" python3 "$ATTEST" keyid 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'mode 0644, expected exactly 0600'; then
  ok "a world-readable key is refused"
else
  bad "a world-readable key is refused" "rc=$rc out=$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
fi
chmod 0600 "$BADKEY"

chmod 0755 "$BADDIR"
out=$(NEBULAOS_ATTEST_KEY="$BADKEY" python3 "$ATTEST" keyid 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'key directory .* mode 0755'; then
  ok "a key in a world-readable directory is refused"
else
  bad "a key in a world-readable directory is refused" "rc=$rc"
fi
chmod 0700 "$BADDIR"

LINKDIR="$WORK/linkdir"
mkdir -p -m 0700 "$LINKDIR"
ln -s "$KEY" "$LINKDIR/attest.key"
out=$(NEBULAOS_ATTEST_KEY="$LINKDIR/attest.key" python3 "$ATTEST" keyid 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'symlink'; then
  ok "a symlinked key path is refused rather than followed"
else
  bad "a symlinked key path is refused rather than followed" "rc=$rc out=$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
fi

SHORTDIR="$WORK/shortdir"
mkdir -p -m 0700 "$SHORTDIR"
printf 'tooshort' > "$SHORTDIR/attest.key"
chmod 0600 "$SHORTDIR/attest.key"
out=$(NEBULAOS_ATTEST_KEY="$SHORTDIR/attest.key" python3 "$ATTEST" keyid 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'at least 32'; then
  ok "an undersized key is refused"
else
  bad "an undersized key is refused" "rc=$rc"
fi

out=$(NEBULAOS_ATTEST_KEY="$WORK/nope/attest.key" python3 "$ATTEST" keyid 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'no attestation key at'; then
  ok "a missing key is refused with instructions to create it by hand"
else
  bad "a missing key is refused with instructions to create it by hand" "rc=$rc"
fi

DIRKEY="$WORK/dirkey"
mkdir -p -m 0700 "$DIRKEY"
mkdir -p -m 0600 "$DIRKEY/attest.key"
out=$(NEBULAOS_ATTEST_KEY="$DIRKEY/attest.key" python3 "$ATTEST" keyid 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'not a regular file'; then
  ok "a directory in the key's place is refused"
else
  bad "a directory in the key's place is refused" "rc=$rc"
fi

# --- 8. the key never appears in argv ---------------------------------------
# The tool takes no --key-material option at all, which is the structural
# guarantee. Assert that no accepted option carries key bytes.
if ! python3 "$ATTEST" sign --help 2>&1 | grep -qiE 'key[- ]?material|--secret|--hmac-key'; then
  ok "no command-line option accepts key material (key cannot reach argv)"
else
  bad "no command-line option accepts key material (key cannot reach argv)" "an option exposes the key"
fi

# --- 9. --require policy constraints ---------------------------------------
if attest verify --in "$GOOD" --require BUILD_PROFILE=release >/dev/null 2>&1; then
  ok "--require accepts a constraint the attestation satisfies"
else
  bad "--require accepts a constraint the attestation satisfies" "unexpected refusal"
fi

out=$(attest verify --in "$GOOD" --require BUILD_PROFILE=dev 2>&1); rc=$?
if [ "$rc" -eq 3 ] && printf '%s' "$out" | grep -q 'required BUILD_PROFILE=dev'; then
  ok "--require rejects a constraint the attestation does not satisfy"
else
  bad "--require rejects a constraint the attestation does not satisfy" "rc=$rc"
fi

out=$(attest verify --in "$GOOD" --require SOURCE_HEAD=0000000000000000000000000000000000000000 2>&1); rc=$?
if [ "$rc" -eq 3 ]; then
  ok "--require can pin SOURCE_HEAD and rejects a mismatch"
else
  bad "--require can pin SOURCE_HEAD and rejects a mismatch" "rc=$rc"
fi

# --- 10. exit codes are distinguishable ------------------------------------
# "could not check" and "checked and it was forged" must never be conflated.
attest verify --in "$WORK/does-not-exist" >/dev/null 2>&1; rc_missing=$?
sed 's|^MAC=.*|MAC=0000000000000000000000000000000000000000000000000000000000000000|' "$GOOD" > "$WORK/forged.att"
attest verify --in "$WORK/forged.att" >/dev/null 2>&1; rc_forged=$?
if [ "$rc_missing" -eq 2 ] && [ "$rc_forged" -eq 3 ]; then
  ok "refusal (2) and verification failure (3) are distinct exit codes"
else
  bad "refusal (2) and verification failure (3) are distinct exit codes" "missing=$rc_missing forged=$rc_forged"
fi

# --- 11. atomic, private output --------------------------------------------
OUTF="$WORK/perm.att"
mkfields | attest sign --out "$OUTF" >/dev/null 2>&1
m=$(stat -c %a "$OUTF" 2>/dev/null)
if [ "$m" = "600" ]; then
  ok "a written attestation is mode 0600"
else
  bad "a written attestation is mode 0600" "mode=$m"
fi
if [ -z "$(find "$WORK" -maxdepth 1 -name 'perm.att.tmp.*' 2>/dev/null)" ]; then
  ok "signing leaves no temporary file behind"
else
  bad "signing leaves no temporary file behind" "tmp file remains"
fi

# --- attest-build-run.sh: the build's own recorded mode outranks --profile ---
#
# A dev build (ccache, reused incremental output) must never be attested with
# an installable profile. The wrapper refuses offline, before it touches the
# network, so this runs without one.
BRUN="$SCRIPT_DIR/../tools/attest/attest-build-run.sh"
mkrun(){ # dir mode
  art="$1/artifacts/buildroot-halley5-v30-image"; mkdir -p "$art"
  printf 'ximage' > "$art/xImage"; printf 'rootfs' > "$art/rootfs.squashfs"; printf 'manifest' > "$art/build-manifest.txt"
  cat > "$1/.nebulaos-build-verified" <<EOF
BUILD_VERIFIED=YES
SOURCE_HEAD=$HEAD_SHA
BUILD_MODE=$2
BUILDER_DIGEST=sha256:$(printf 'builder' | sha256sum | cut -d' ' -f1)
XIMAGE_SHA256=$X_SHA
ROOTFS_SQUASHFS_SHA256=$R_SHA
SOURCE_DATE_EPOCH=1790680624
EOF
}
mkrun "$WORK/devrun" dev
for prof in candidate release; do
  out=$(NEBULAOS_ATTEST_KEY="$KEY" sh "$BRUN" --build-run "$WORK/devrun" --profile "$prof" \
        --out "$WORK/devrun.$prof.att" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "refusing to attest BUILD_PROFILE=$prof" \
     && [ ! -e "$WORK/devrun.$prof.att" ]; then
    ok "attest-build-run refuses --profile $prof for a BUILD_MODE=dev build (no file written)"
  else
    bad "attest-build-run refuses --profile $prof for a BUILD_MODE=dev build (no file written)" "rc=$rc out=$out"
  fi
done
out=$(NEBULAOS_ATTEST_KEY="$KEY" sh "$BRUN" --build-run "$WORK/devrun" --profile bogus 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "unknown --profile 'bogus'"; then
  ok "attest-build-run refuses an unknown --profile"
else
  bad "attest-build-run refuses an unknown --profile" "rc=$rc out=$out"
fi

echo
printf 'ATTESTATION_V2_TESTS_PASS=%d\nATTESTATION_V2_TESTS_FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
