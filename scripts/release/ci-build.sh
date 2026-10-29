#!/usr/bin/env bash
#
# The release build on a GitHub-hosted runner (Run 23, Tim 2026-10-29: the
# whole build runs on GitHub, free runners only). Called by the NebulaOS
# repository's release workflow in a fresh clone of this repository checked
# out at the commit being released:
#
#   scripts/release/ci-build.sh <40-hex commit>
#
# Runs ./build.sh as a CANDIDATE (release-grade: fresh output, no ccache,
# exact pins - the same invocation tools/run-nebulaos-build.sh --candidate
# makes), then writes .nebulaos-build-verified in the launcher's format, so
# scripts/package/package-release.sh accepts the result. The attestation is
# withheld unless the bytes, the build's own manifest and the requested commit
# all agree.
set -uo pipefail
export LC_ALL=C

die(){ printf 'CI_BUILD=FAILED\nREASON: %s\n' "$1" >&2; exit 2; }

EXPECT=${1:-}
case "$EXPECT" in *[!0-9a-f]*|'') die "usage: ci-build.sh <40-hex commit>" ;; esac
[ "${#EXPECT}" -eq 40 ] || die "usage: ci-build.sh <40-hex commit>"

FW=$(cd "$(dirname "$0")/../.." && pwd)
GOT=$(git -C "$FW" rev-parse HEAD 2>/dev/null) || die "$FW is not a git checkout"
[ "$GOT" = "$EXPECT" ] || die "checkout HEAD $GOT != requested $EXPECT"
[ -z "$(git -C "$FW" status --porcelain 2>/dev/null)" ] || die "the checkout is not clean"

printf 'CI_BUILD=STARTING\nSOURCE_HEAD=%s\nSTARTED_AT=%s\n' "$EXPECT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
( cd "$FW" && NEBULAOS_CANDIDATE_BUILD=1 ./build.sh --release )
RC=$?
[ "$RC" -eq 0 ] || die "build.sh exited $RC"

ART="$FW/artifacts/buildroot-halley5-v30-image"
ATT="$FW/.nebulaos-build-verified"
rm -f "$ATT"
for f in xImage rootfs.squashfs build-manifest.txt; do
  [ -f "$ART/$f" ] || die "artifact missing: $ART/$f"
done
mget(){ grep -m1 "^$1=" "$ART/build-manifest.txt" 2>/dev/null | cut -d= -f2-; }
A_X=$(sha256sum "$ART/xImage" | cut -d' ' -f1)
A_R=$(sha256sum "$ART/rootfs.squashfs" | cut -d' ' -f1)
A_EPOCH=$(git -C "$FW" show -s --format=%ct "$EXPECT")
case "${A_EPOCH:-}" in ''|*[!0-9]*) die "cannot derive SOURCE_DATE_EPOCH from $EXPECT" ;; esac
[ "$A_X" = "$(mget xImage_sha256)" ] || die "xImage does not match build-manifest.txt"
[ "$A_R" = "$(mget rootfs_squashfs_sha256)" ] || die "rootfs.squashfs does not match build-manifest.txt"
[ "$(mget git_commit_main)" = "$EXPECT" ] || die "build-manifest.txt names another commit"

{
  printf 'BUILD_VERIFIED=YES\n'
  printf 'SOURCE_HEAD=%s\n' "$EXPECT"
  printf 'BUILD_MODE=candidate\n'
  printf 'BUILD_RUN=%s\n' "$FW"
  printf 'XIMAGE_SHA256=%s\n' "$A_X"
  printf 'XIMAGE_SIZE=%s\n' "$(stat -c %s "$ART/xImage")"
  printf 'ROOTFS_SQUASHFS_SHA256=%s\n' "$A_R"
  printf 'ROOTFS_SQUASHFS_SIZE=%s\n' "$(stat -c %s "$ART/rootfs.squashfs")"
  printf 'BUILDER_DIGEST=%s\n' "$(mget build_image_digest)"
  printf 'SOURCE_DATE_EPOCH=%s\n' "$A_EPOCH"
  printf 'BUILT_ON=github-actions %s\n' "${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
  printf 'ATTESTED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$ATT"
printf 'CI_BUILD=PASS\nXIMAGE_SHA256=%s\nROOTFS_SQUASHFS_SHA256=%s\nBUILD_ATTESTATION_PATH=%s\n' "$A_X" "$A_R" "$ATT"
