#!/usr/bin/env bash
#
# Source-level regression assertions for image reproducibility.
#
# These do not build. They assert that the *inputs* found to be
# nondeterministic stay fixed, so a regression surfaces in seconds rather than
# as a hash mismatch two builds later.
#
# The measured causes are recorded in docs/REPRODUCIBILITY.md.
#
set -uo pipefail
ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
have() { grep -qF "$2" "$ROOT/$1" 2>/dev/null; }

S04=scripts/build/04-cross-compile-app-stack.sh
BRC=artifacts/buildroot-halley5-v30-image/buildroot.config
CH=scripts/build/overlay/etc/nebulaos-chelper-preflight.sh

echo "REPRODUCIBILITY SOURCE ASSERTIONS"
echo
echo "[ SOURCE_DATE_EPOCH ]"
if grep -q 'SOURCE_DATE_EPOCH=$(git -C "$SCRIPT_DIR" show -s --format=%ct HEAD' "$ROOT/build.sh"; then
  ok "build.sh derives SOURCE_DATE_EPOCH from the firmware commit"
else
  bad "build.sh no longer derives SOURCE_DATE_EPOCH from the commit"
fi

if grep -q 'FATAL: cannot derive SOURCE_DATE_EPOCH' "$ROOT/build.sh"; then
  ok "build.sh fails closed when the epoch cannot be derived"
else
  bad "build.sh no longer fails closed on an underivable epoch"
fi

if have build.sh '-e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH"'; then
  ok "SOURCE_DATE_EPOCH is propagated into the build container"
else
  bad "SOURCE_DATE_EPOCH is NOT propagated into the container"
fi

echo
echo "[ Buildroot ]"
if have "$BRC" 'BR2_REPRODUCIBLE=y'; then
  ok "BR2_REPRODUCIBLE=y (normalises mtimes, bytecode and archive metadata)"
else
  bad "BR2_REPRODUCIBLE is not enabled"
fi

# BR2_TARGET_GENERIC_ROOT_PASSWD stays PLAINTEXT on purpose. A pre-computed
# hash cannot survive Kconfig -> make: .config is included by make, which
# expands `$5` before Buildroot's already-hashed test can match it (measured).
# Determinism is supplied by the post-build script instead, and plaintext here
# remains a working fallback. The assertion is therefore that the post-build
# script carries the fixed hash - not that this value is hashed.
if have scripts/build/nebulaos-post-build.sh "ROOT_HASH='\$5\$"; then
  ok "the post-build script pins a fixed-salt root hash"
else
  bad "the post-build script no longer carries a fixed root hash - /etc/shadow will vary"
fi

echo
echo "[ generated metadata ]"
if grep -q 'build_date=$(date -u -d "@${SOURCE_DATE_EPOCH' "$ROOT/$S04"; then
  ok "build_date is derived from SOURCE_DATE_EPOCH"
else
  bad "build_date is not epoch-derived"
fi

if grep -qE '^build_date=\$\(date -u \+' "$ROOT/$S04"; then
  bad "a bare wall-clock build_date assignment is back in stage 04"
else
  ok "no bare wall-clock build_date assignment in stage 04"
fi

if have "$CH" 'if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then'; then
  ok "chelper preflight uses the epoch at build time, the wall clock at boot"
else
  bad "chelper preflight writes a wall-clock checked_at into the image"
fi

echo
echo "[ deterministic archives ]"
DET='--sort=name'
if grep -q -- "$DET" "$ROOT/scripts/build/lib/make-seed-archive.sh"; then
  ok "seed archive tar is sorted, epoch-stamped and numeric-owner"
else
  bad "seed archive tar is not deterministic - member order and mtimes will vary"
fi
if grep -q -- "$DET" "$ROOT/$S04"; then
  ok "venv seed tar is deterministic"
else
  bad "venv seed tar is not deterministic"
fi

# Grepping for a tar flag cannot prove the archive is reproducible. Build a
# real repo twice and compare the bytes. This also guards the chelper mtime
# invariant, which the flattened --mtime must not break: both Klipper's
# check_build_code() and chelper_check_mtime() are strictly-greater, so equal
# mtimes are safe - but a future change to either would surface here.
W=$(mktemp -d "${TMPDIR:-/tmp}/repro-seed.XXXXXX" 2>/dev/null) || W=""
case "$W" in
  */repro-seed.*) : ;;
  *) W="" ;;
esac
if [ -z "$W" ]; then
  bad "could not create a temp dir - the seed-archive determinism test did not run"
else
  (
    set -e
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    git init -q -b master "$W/src"
    mkdir -p "$W/src/klippy/chelper"
    printf 'int main(void){return 0;}\n' > "$W/src/klippy/chelper/pyhelper.c"
    printf 'x\n' > "$W/src/klippy/chelper/__init__.py"
    # lib/ exists so the sparse path below has something to exclude - this is
    # the shape the real klipper seed uses (sparse_exclude "/lib/").
    mkdir -p "$W/src/lib/vendored"
    printf 'blob\n' > "$W/src/lib/vendored/big.bin"
    # Real repos gitignore __pycache__, so `git status --porcelain` never
    # reports it and the clean-tree guard does not see it - which is exactly
    # why a stale .pyc could ride along into a release seed unnoticed. The
    # fixture must reproduce that, or it tests a situation that cannot occur.
    printf '__pycache__/\n' > "$W/src/.gitignore"
    # A minimal but genuine MIPS ELF header (e_type=DYN, e_machine=EM_MIPS),
    # so make_seed_archive's `file`-based wrong-architecture check accepts it,
    # exactly as tests/factory-seed-git-tests.sh builds its own fixture.
    printf '%b' '\0177ELF\001\001\001\0\0\0\0\0\0\0\0\0\003\0\010\0\001\0\0\0' \
      > "$W/src/klippy/chelper/c_helper.so"
    printf 'nebulaos determinism fixture padding' >> "$W/src/klippy/chelper/c_helper.so"
    git -C "$W/src" add -A
    git -C "$W/src" -c user.email=t@e -c user.name=t \
      -c commit.gpgsign=false commit -q -m seed
    # Leave a reflog entry pointing at an object NO REF REACHES. A throwaway
    # commit followed by `reset --hard` is the same state `checkout -B`
    # produces on a real vendor clone. The repack packs only ref-reachable
    # objects and deletes the clone's pack, so without dropping the reflogs
    # first that entry dangles and `git fsck` refuses the whole package -
    # measured on the real moonraker clone ("invalid reflog entry").
    printf 'throwaway\n' > "$W/src/throwaway.txt"
    git -C "$W/src" add -A
    git -C "$W/src" -c user.email=t@e -c user.name=t \
      -c commit.gpgsign=false commit -q -m throwaway
    git -C "$W/src" -c user.email=t@e -c user.name=t reset -q --hard HEAD~1

    # Created AFTER the commit, so it is UNTRACKED - exactly how a vendor
    # build leaves it behind. A sparse checkout removes tracked files under
    # the excluded path but not untracked ones, which is how a stale,
    # TIMESTAMP-based .pyc (PEP 552 flag word 0, carrying a per-build source
    # mtime) reached a release seed. It must not survive into the archive.
    # The ABI tag is derived, not written as "cpython-311". The invariant
    # under test is "a stale, untracked, timestamp-based .pyc must not reach
    # the archive", and that is independent of the interpreter version - but
    # a hardcoded tag makes the fixture progressively less representative of
    # what a real build actually leaves behind, and unlike a hardcoded tag in
    # a PRESENCE check, a stale tag here fails SILENTLY: the test still
    # passes while no longer exercising a realistic filename.
    mkdir -p "$W/src/lib/vendored/__pycache__"
    _abi=$(python3 -c 'import sys; print("cpython-%d%d" % sys.version_info[:2])' 2>/dev/null)
    [ -n "$_abi" ] || _abi=cpython-312
    printf '%b' '\0247\015\015\012\0\0\0\0\336\255\276\357\1\0\0\0' \
      > "$W/src/lib/vendored/__pycache__/stale.$_abi.pyc"
  ) >/dev/null 2>&1
  if [ ! -d "$W/src/.git" ]; then
    bad "could not build the seed-archive fixture - determinism test did not run"
  else
    # Deliberately run with SOURCE_DATE_EPOCH UNSET: this function is shared
    # with callers that have no build-time epoch, and requiring one broke all
    # of them. The second run also touches a source file first, so a
    # build-time mtime leaking into the archive would show up as a difference.
    (
      unset SOURCE_DATE_EPOCH
      . "$ROOT/scripts/build/lib/make-seed-archive.sh"
      make_seed_archive "$W/src" master "https://example.invalid/s.git" "$W/a.tar.gz"
      sleep 1
      touch "$W/src/klippy/chelper/pyhelper.c"
      make_seed_archive "$W/src" master "https://example.invalid/s.git" "$W/b.tar.gz"
    ) > "$W/mksa.log" 2>&1
    if [ ! -f "$W/a.tar.gz" ] || [ ! -f "$W/b.tar.gz" ]; then
      bad "make_seed_archive did not produce both archives without SOURCE_DATE_EPOCH: $(tail -2 "$W/mksa.log" | tr '\n' ' ')"
    elif cmp -s "$W/a.tar.gz" "$W/b.tar.gz"; then
      ok "two make_seed_archive runs of one commit are byte-identical"
    else
      bad "make_seed_archive is not reproducible - two runs of the same commit differ"
    fi
    # The sparse path is a DIFFERENT code path (skip-worktree bits have to be
    # re-applied after the index is rebuilt) and it is the one the real
    # klipper seed uses, so it gets its own determinism check.
    (
      unset SOURCE_DATE_EPOCH
      . "$ROOT/scripts/build/lib/make-seed-archive.sh"
      make_seed_archive "$W/src" master "https://example.invalid/s.git" "$W/sa.tar.gz" "/lib/"
      sleep 1
      make_seed_archive "$W/src" master "https://example.invalid/s.git" "$W/sb.tar.gz" "/lib/"
    ) > "$W/mksa-sparse.log" 2>&1
    if [ ! -f "$W/sa.tar.gz" ] || [ ! -f "$W/sb.tar.gz" ]; then
      bad "sparse make_seed_archive did not produce both archives: $(tail -2 "$W/mksa-sparse.log" | tr '\n' ' ')"
    elif cmp -s "$W/sa.tar.gz" "$W/sb.tar.gz"; then
      ok "two sparse make_seed_archive runs are byte-identical (the klipper seed's path)"
    else
      bad "the sparse make_seed_archive path is not reproducible - two runs differ"
    fi

    if [ -f "$W/a.tar.gz" ]; then
      mkdir -p "$W/pyc" && tar -C "$W/pyc" -xzf "$W/a.tar.gz" 2>/dev/null
      # The archived object store must be exactly ONE locally-built pack with
      # no loose objects. A clone's pack is whatever the remote server chose
      # to send and is not a function of the content, so if the repack is ever
      # made conditional again (it used to run only for shallow clones), a
      # seed would ship the server's bytes and vary between builds.
      npack=$(find "$W/pyc/.git/objects/pack" -name '*.pack' 2>/dev/null | wc -l)
      nloose=$(find "$W/pyc/.git/objects" -mindepth 2 -maxdepth 2 -type f \
                 -path '*/??/*' 2>/dev/null | wc -l)
      if [ "$npack" = "1" ] && [ "$nloose" = "0" ]; then
        ok "the archived git object store is exactly one locally-built pack, no loose objects"
      else
        bad "the archived object store is $npack pack(s) and $nloose loose object(s) - the deterministic repack did not run"
      fi
      if find "$W/pyc" -name '__pycache__' -type d 2>/dev/null | grep -q .; then
        bad "a stale __pycache__ survived into the seed archive - its .pyc header carries a per-build source mtime"
      else
        ok "stale __pycache__ does not survive into the seed archive"
      fi
    fi
    if [ -f "$W/a.tar.gz" ]; then
      mkdir -p "$W/x" && tar -C "$W/x" -xzf "$W/a.tar.gz" 2>/dev/null
      if [ ! -f "$W/x/klippy/chelper/c_helper.so" ]; then
        bad "the extracted seed archive has no c_helper.so - cannot check the mtime invariant"
      elif [ -z "$(find "$W/x/klippy/chelper" -maxdepth 1 -type f \
             \( -name '*.c' -o -name '*.h' -o -name '__init__.py' \) \
             -newer "$W/x/klippy/chelper/c_helper.so" 2>/dev/null)" ]; then
        ok "no chelper source is newer than c_helper.so in the archive (no gcc rebuild on device)"
      else
        bad "a chelper source is NEWER than c_helper.so in the archive - Klippy would invoke a gcc the device does not have"
      fi
    fi
  fi
  rm -rf "$W"
fi

MSA=scripts/build/lib/make-seed-archive.sh
if have "$MSA" "clean -fdx -- '*__pycache__*'"; then
  ok "stale __pycache__ is cleared before compileall"
else
  bad "stale __pycache__ is no longer cleared - a vendor-built .pyc with a per-build mtime can ship"
fi
PACKLINE='^[[:space:]]*_pack_hash=.*pack-objects'
if grep -qE "$PACKLINE .*--threads=1" "$ROOT/$MSA"; then
  ok "git pack-objects is single-threaded (packing is not timing-dependent)"
else
  bad "git pack-objects is multithreaded again - pack bytes become timing-dependent"
fi
# Threads alone were NOT enough. Delta/object reuse pulls bytes out of the
# pack the REMOTE SERVER sent, so the "local" pack inherits them.
if grep -qE "$PACKLINE .*--no-reuse-delta .*--no-reuse-object" "$ROOT/$MSA"; then
  ok "pack-objects recomputes deltas (no reuse of the server's pack bytes)"
else
  bad "pack-objects reuses deltas from the fetched pack - the seed inherits whatever the server sent"
fi

echo
echo "[ POSIX sh compatibility of the build scripts ]"
# This section exists because of a real build failure, not as a style rule.
# A `read -r -d ''` added to lib/make-seed-archive.sh passed every test here
# and then broke a full build: these scripts are #!/bin/sh and build.sh runs
# the pipeline with `sh`, which is dash in the container. The tests source
# the library into BASH, where `read -d` works, so the suite was green while
# the build was not. bash -n cannot see this class of defect either.
#
# shellcheck -s sh is the closest available proxy - neither dash nor busybox
# is installed on this host (tests/overlay-shell-lint-tests.sh documents the
# same constraint for the shipped init scripts).
#
# SC3043 (`local` is undefined in POSIX sh) is deliberately EXCLUDED: dash,
# busybox ash and bash all implement `local`, this codebase uses it widely on
# purpose, and it has never failed a build. Everything else in the SC3xxx
# family - read -d, [[ ]], arrays, <<< - genuinely does not exist in dash and
# fails at runtime. This is a scoped exclusion of one checked, benign code,
# not a blanket relaxation to obtain a PASS.
if ! command -v shellcheck >/dev/null 2>&1; then
  bad "shellcheck is unavailable - POSIX compatibility of the build scripts is unchecked"
else
  scanned=0
  offenders=""
  for f in $(grep -rl '^#!/bin/sh' "$ROOT/scripts/build" --include='*.sh' 2>/dev/null | sort); do
    scanned=$((scanned+1))
    hits=$(shellcheck -s sh "$f" 2>/dev/null \
      | grep -oE 'SC3[0-9]{3}' | grep -v '^SC3043$' | sort -u | tr '\n' ',')
    [ -n "$hits" ] && offenders="$offenders
    ${f#$ROOT/} -> ${hits%,}"
  done
  if [ "$scanned" -eq 0 ]; then
    bad "found no #!/bin/sh scripts under scripts/build - the scan is not doing anything"
  elif [ -z "$offenders" ]; then
    ok "all $scanned #!/bin/sh build scripts are free of non-POSIX constructs (bar 'local')"
  else
    bad "non-POSIX constructs in #!/bin/sh build scripts - these run under dash and will fail:$offenders"
  fi
fi

# BR2_REPRODUCIBLE clamps target mtimes to SOURCE_DATE_EPOCH, which flattens
# chelper sources and c_helper.so to the SAME timestamp. That is safe only
# because both rebuild checks are STRICTLY greater-than, so equal mtimes do
# not trigger a rebuild. The margin chelper_enforce_mtime's bare `touch` used
# to provide is gone, and this now holds by exact equality. If upstream
# Klipper ever changes `>` to `>=`, every device would try to invoke a gcc it
# does not have, at boot. Assert both halves of the inequality.
KCH=vendor/klipper/klippy/chelper/__init__.py
if [ ! -f "$ROOT/$KCH" ]; then
  ok "vendor klipper not fetched - chelper rebuild-check comparison not verifiable here (skipped)"
elif grep -qF 'return not obj_times or max(src_times) > min(obj_times)' "$ROOT/$KCH"; then
  ok "Klipper's check_build_code is strictly > (equal mtimes do not trigger a gcc rebuild)"
else
  bad "Klipper's check_build_code comparison changed - equal mtimes under BR2_REPRODUCIBLE may now force a gcc rebuild on a device with no toolchain"
fi
if grep -q -- '-newer "\$target"' "$ROOT/$CH"; then
  ok "chelper_check_mtime uses -newer (strict), so flattened mtimes stay safe"
else
  bad "chelper_check_mtime no longer uses a strict -newer test"
fi

echo
echo "[ kernel payload gzip ]"
if have scripts/build/01-apply-kernel-patches.sh 'gzip -nv9f $(obj)/vmlinux.bin'; then
  ok "01-apply-kernel-patches.sh checks the kernel zboot payload uses gzip -n (committed in NebulaOS-kernel)"
else
  bad "01-apply-kernel-patches.sh no longer checks gzip -nv9f in the kernel zboot Makefile"
fi

echo
echo "[ root password determinism ]"
if grep -qxF 'BR2_ROOTFS_POST_BUILD_SCRIPT="$(BR2_EXTERNAL_NEBULAOS_PATH)/board/nebulaos-x2000/post-build.sh"' "$ROOT/$BRC"; then
  ok "the post-build script is wired into Buildroot"
else
  bad "BR2_ROOTFS_POST_BUILD_SCRIPT is not set to the NebulaOS post-build script"
fi
if have scripts/build/nebulaos-post-build.sh 'chmod "$mode_before"'; then
  ok "the post-build script preserves the /etc/shadow mode (0600, not git-expressible)"
else
  bad "the post-build script no longer preserves the /etc/shadow mode"
fi
if have scripts/build/02-configure-buildroot.sh 'cp "$SCRIPT_DIR/nebulaos-post-build.sh"'; then
  ok "stage 02 installs the post-build script into the buildroot tree"
else
  bad "stage 02 no longer installs the post-build script - Buildroot would fail to find it"
fi

# The post-build script overwrites the root password field unconditionally, so
# editing BR2_TARGET_GENERIC_ROOT_PASSWD alone would be silently ineffective.
# Assert the two agree: the pinned hash must be sha256-crypt of the configured
# plaintext under the fixed salt. Changing the password means changing both.
PW=$(sed -n 's/^BR2_TARGET_GENERIC_ROOT_PASSWD="\(.*\)"$/\1/p' "$ROOT/$BRC")
PINNED=$(sed -n "s/^ROOT_HASH='\(.*\)'$/\1/p" "$ROOT/scripts/build/nebulaos-post-build.sh")
SALT=$(printf '%s' "$PINNED" | cut -d'$' -f3)
if ! command -v openssl >/dev/null 2>&1; then
  bad "openssl is unavailable - cannot verify the pinned hash matches the configured password"
elif [ -z "$PW" ] || [ -z "$PINNED" ] || [ -z "$SALT" ]; then
  bad "could not read the root password, the pinned hash or its salt"
elif [ "$(openssl passwd -5 -salt "$SALT" "$PW")" = "$PINNED" ]; then
  ok "the pinned hash is the configured root password under a fixed salt (same password)"
else
  bad "the pinned hash does not match BR2_TARGET_GENERIC_ROOT_PASSWD - one was changed without the other"
fi

echo
echo "[ NebulaScreen (closed previously, must stay closed) ]"
if grep -q 'NS_EPOCH=$(git -C "$NEBULASCREEN_SRC" show -s --format=%ct "$NEBULASCREEN_PIN"' "$ROOT/$S04" \
    && have "$S04" 'if [ "$NS_HEAD" != "$NEBULASCREEN_PIN" ]; then'; then
  ok "NebulaScreen epoch is still anchored to NEBULASCREEN_PIN, and the checkout must be the pin"
else
  bad "NebulaScreen epoch anchoring regressed"
fi

if have "$S04" 'FATAL: NEBULASCREEN_PIN is unset or empty'; then
  ok "an unset NEBULASCREEN_PIN is still fatal"
else
  bad "an unset NEBULASCREEN_PIN no longer fails the build"
fi

# G82 (Run 15): the image builds through the screen repo's own release
# recipe, which clears the libhv/spdlog cross-build trees itself.
if have "$S04" 'bash scripts/build-release.sh "$NEBULASCREEN_VERSION"'; then
  ok "the image builds NebulaScreen through the screen repo's scripts/build-release.sh"
else
  bad "04 no longer builds NebulaScreen through scripts/build-release.sh"
fi
NS_SIBLING="$ROOT/../NebulaOS-guppyscreen"
[ -d "$ROOT/../NebulaOS-nebulascreen/.git" ] && NS_SIBLING="$ROOT/../NebulaOS-nebulascreen"
if [ -f "$NS_SIBLING/scripts/build-release.sh" ]; then
  if grep -qF 'rm -rf build libhv/build-mips spdlog/build-mips' "$NS_SIBLING/scripts/build-release.sh"; then
    ok "libhv/spdlog cross-build trees are still cleared (screen checkout's build-release.sh)"
  else
    bad "the libhv/spdlog cross-build clean regressed - the epoch would be a no-op"
  fi
else
  echo "  SKIP  no NebulaScreen checkout beside this repo - recipe clean not checked here"
fi

echo
echo "TESTS_PASS=$PASS"
echo "TESTS_FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then echo "REPRODUCIBILITY_ASSERTIONS=FAIL"; exit 1; fi
echo "REPRODUCIBILITY_ASSERTIONS=PASS"
exit 0
