#!/bin/sh
# G71 (2026-10-17): make sure the NebulaOS package index can build for a
# firmware build's Python ABI - run after every attested build.
#
#   tools/sdk/publish-sdk.sh <build run dir>
#
# A separate host step, run once the build launcher printed
# BUILD_ATTESTATION=WRITTEN - never part of the build, so it cannot change a
# build's result or attestation, and GitHub credentials never reach the
# launcher or the build container (architecture review 2026-10-17).
#
# 1. The build's ABI id (the fingerprint the image carries).
# 2. Release sdk-<id> in the index repository with BOTH assets (.tar.xz and
#    .sha256) = done. That release, not the Pages index, is the idempotency
#    key: the index only appears after a green CI run.
# 3. Only SDKs built from published source: the build's SOURCE_HEAD must be
#    on origin/main of the firmware repository. Releases are first-wins per
#    ABI id (every wheel for that id is built against that SDK).
# 4. Otherwise export-sdk.sh on the run (it only reads the run), create the
#    release or complete a partial one, and start the index workflow, with
#    the PC's own GitHub login (gh).
#
# Output, always exit 0:
#   SDK_PUBLISH=PRESENT|PUBLISHED|REPAIRED|SKIPPED_UNPUBLISHED_SOURCE|FAILED (reason)
#   SDK_INDEX_READY=YES|NO   (the index already serves this ABI)
set -u
RUN=${1:?usage: publish-sdk.sh <build run dir>}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
. "$REPO_ROOT/manifests/dependencies.conf" 2>/dev/null
INDEX_URL=${PUBLISH_SDK_INDEX_URL:-${NEBULAOS_PACKAGE_INDEX_URL:-}}
# The repository behind the index. Kept here, not in the manifest: it is
# not a product input (a change must not make builds stale).
INDEX_REPO=${NEBULAOS_PACKAGE_INDEX_REPO:-coreflake1/nebulaos-packages}
GH=${GH:-gh}
GIT_REMOTE=${PUBLISH_SDK_REMOTE:-origin}
SRC_REPO=${PUBLISH_SDK_REPO:-$REPO_ROOT}
EXPORT_SDK=${EXPORT_SDK:-$HERE/export-sdk.sh}
ABI="$RUN/vendor/buildroot-x2000/output/target/usr/share/nebulaos/python-abi"
ATTEST="$RUN/.nebulaos-build-verified"

READY=NO
result() { echo "SDK_PUBLISH=$1${2:+ ($2)}"; echo "SDK_INDEX_READY=$READY"; exit 0; }

[ -f "$ATTEST" ] && grep -q '^BUILD_VERIFIED=YES' "$ATTEST" || result FAILED "the run has no verified build attestation"
[ -f "$ABI" ] || result FAILED "the build has no Python ABI fingerprint"
ID=$(sed -n 's/^id=//p' "$ABI")
[ -n "$ID" ] || result FAILED "no id in $ABI"
if [ -n "$INDEX_URL" ] && curl -fsS -o /dev/null --max-time 20 --retry 3 --retry-delay 5 "${INDEX_URL%/}/$ID/python-abi" 2>/dev/null; then
	READY=YES
fi

command -v "$GH" >/dev/null 2>&1 || result FAILED "gh is not installed"
"$GH" auth status >/dev/null 2>&1 || result FAILED "gh is not logged in"

# Which assets release sdk-<id> already has (empty: no release).
ASSETS=$("$GH" release view "sdk-$ID" --repo "$INDEX_REPO" --json assets -q '.assets[].name' 2>/dev/null)
HAVE_TAR=no; HAVE_SUM=no
echo "$ASSETS" | grep -qxF "nebulaos-sdk-$ID.tar.xz" && HAVE_TAR=yes
echo "$ASSETS" | grep -qxF "nebulaos-sdk-$ID.tar.xz.sha256" && HAVE_SUM=yes
[ "$HAVE_TAR" = yes ] && [ "$HAVE_SUM" = yes ] && result PRESENT "release sdk-$ID is complete"

SOURCE_HEAD=$(sed -n 's/^SOURCE_HEAD=//p' "$ATTEST")
[ -n "$SOURCE_HEAD" ] || result FAILED "the attestation names no SOURCE_HEAD"
git -C "$SRC_REPO" fetch -q "$GIT_REMOTE" main 2>/dev/null || result FAILED "could not fetch $GIT_REMOTE/main"
git -C "$SRC_REPO" merge-base --is-ancestor "$SOURCE_HEAD" "$GIT_REMOTE/main" 2>/dev/null || \
	result SKIPPED_UNPUBLISHED_SOURCE "build source $SOURCE_HEAD is not on $GIT_REMOTE/main - push it, then run this again"

OUT=$(mktemp -d "${TMPDIR:-/tmp}/publish-sdk.XXXXXX") || result FAILED "mktemp failed"
[ -n "$OUT" ] && [ -d "$OUT" ] || result FAILED "mktemp failed"
trap 'rm -rf "$OUT"' EXIT
sh "$EXPORT_SDK" "$RUN" "$OUT" > "$OUT/export.log" 2>&1 || { tail -5 "$OUT/export.log" >&2; result FAILED "export-sdk.sh failed"; }
SDK="$OUT/nebulaos-sdk-$ID.tar.xz"
[ -f "$SDK" ] && [ -f "$SDK.sha256" ] || result FAILED "export produced no $SDK"

if [ -n "$ASSETS" ] || "$GH" release view "sdk-$ID" --repo "$INDEX_REPO" >/dev/null 2>&1; then
	# A partial release (an upload that died): complete it. --clobber keeps
	# the pair consistent - a .sha256 always describes the uploaded .tar.xz.
	"$GH" release upload "sdk-$ID" --repo "$INDEX_REPO" --clobber "$SDK" "$SDK.sha256" >/dev/null 2>&1 \
		|| result FAILED "completing release sdk-$ID failed"
	STATE=REPAIRED
else
	NOTES=$(printf 'Cross-compilation SDK for Python ABI %s, exported automatically from an attested NebulaOS firmware build (tools/sdk/publish-sdk.sh).\n\n```\n%s\n```\n' \
		"$ID" "$(tar -xJOf "$SDK" "nebulaos-sdk-$ID/sdk-info" 2>/dev/null)")
	if ! "$GH" release create "sdk-$ID" --repo "$INDEX_REPO" --title "SDK for Python ABI $ID" --notes "$NOTES" \
		"$SDK" "$SDK.sha256" >/dev/null 2>&1; then
		# Created concurrently by another run: that one is as good.
		"$GH" release view "sdk-$ID" --repo "$INDEX_REPO" >/dev/null 2>&1 || result FAILED "creating release sdk-$ID failed"
	fi
	STATE=PUBLISHED
fi
"$GH" workflow run index.yml --repo "$INDEX_REPO" >/dev/null 2>&1 || result "$STATE" "release sdk-$ID ready; starting the index workflow failed - the daily run will pick it up"
result "$STATE" "release sdk-$ID ready; index workflow started"
