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
#   SDK_PUBLISH=PRESENT|PUBLISHED|REPAIRED|TOOLS_ADDED|SKIPPED_UNPUBLISHED_SOURCE|FAILED (reason)
#   SDK_INDEX_READY=YES|NO   (the index already serves this ABI)
set -u
RUN=${1:?usage: publish-sdk.sh <build run dir>}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
. "$REPO_ROOT/manifests/dependencies.conf" 2>/dev/null
INDEX_URL=${PUBLISH_SDK_INDEX_URL:-${NEBULAOS_PACKAGE_INDEX_URL:-}}
# The repository behind the index. Kept here, not in the manifest: it is
# not a product input (a change must not make builds stale).
INDEX_REPO=${NEBULAOS_PACKAGE_INDEX_REPO:-NebulaOS-KE/nebulaos-packages}
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
HAVE_TAR=no; HAVE_SUM=no; HAVE_TOOLS=no
TOOLS_NAME="nebulaos-chelper-tools-$ID.tar.gz"
echo "$ASSETS" | grep -qxF "nebulaos-sdk-$ID.tar.xz" && HAVE_TAR=yes
echo "$ASSETS" | grep -qxF "nebulaos-sdk-$ID.tar.xz.sha256" && HAVE_SUM=yes
echo "$ASSETS" | grep -qxF "$TOOLS_NAME" && HAVE_TOOLS=yes
[ "$HAVE_TAR" = yes ] && [ "$HAVE_SUM" = yes ] && [ "$HAVE_TOOLS" = yes ] && result PRESENT "release sdk-$ID is complete"
# The .tar.xz is first-wins: never replaced to add a missing .sha256 (that
# would swap the SDK every wheel of this ABI was built with).
[ "$HAVE_TAR" = yes ] && [ "$HAVE_SUM" = no ] && \
	result FAILED "release sdk-$ID has the SDK but no .sha256 - add it by hand or delete the release to republish"

SOURCE_HEAD=$(sed -n 's/^SOURCE_HEAD=//p' "$ATTEST")
[ -n "$SOURCE_HEAD" ] || result FAILED "the attestation names no SOURCE_HEAD"
git -C "$SRC_REPO" fetch -q "$GIT_REMOTE" main 2>/dev/null || result FAILED "could not fetch $GIT_REMOTE/main"
git -C "$SRC_REPO" merge-base --is-ancestor "$SOURCE_HEAD" "$GIT_REMOTE/main" 2>/dev/null || \
	result SKIPPED_UNPUBLISHED_SOURCE "build source $SOURCE_HEAD is not on $GIT_REMOTE/main - push it, then run this again"

OUT=$(mktemp -d "${TMPDIR:-/tmp}/publish-sdk.XXXXXX") || result FAILED "mktemp failed"
[ -n "$OUT" ] && [ -d "$OUT" ] || result FAILED "mktemp failed"
trap 'rm -rf "$OUT"' EXIT

# G72: the chelper recipe, source hash and the image library's record as a
# small asset of its own, so an ABI whose SDK was published before the
# recipe travelled in the SDK still gets Klipper helpers (ci-all.sh uses it
# when the SDK has no nebulaos/ directory).
mkdir -p "$OUT/tools/nebulaos"
cp "$RUN/scripts/build/lib/build-chelper.sh" "$RUN/scripts/build/overlay/etc/nebulaos-chelper-preflight.sh" \
	"$OUT/tools/nebulaos/" 2>/dev/null || result FAILED "the run has no chelper recipe (built before G72)"
cp "$RUN/vendor/buildroot-x2000/output/target/usr/share/nebulaos/chelper" "$OUT/tools/nebulaos/image-chelper" 2>/dev/null \
	|| result FAILED "the image has no chelper record"
tar -C "$OUT/tools" -czf "$OUT/$TOOLS_NAME" nebulaos || result FAILED "packing $TOOLS_NAME failed"

if [ "$HAVE_TAR" = yes ]; then
	"$GH" release upload "sdk-$ID" --repo "$INDEX_REPO" "$OUT/$TOOLS_NAME" >/dev/null 2>&1 \
		|| result FAILED "adding $TOOLS_NAME to release sdk-$ID failed"
	STATE=TOOLS_ADDED
else
	sh "$EXPORT_SDK" "$RUN" "$OUT" > "$OUT/export.log" 2>&1 || { tail -5 "$OUT/export.log" >&2; result FAILED "export-sdk.sh failed"; }
	SDK="$OUT/nebulaos-sdk-$ID.tar.xz"
	[ -f "$SDK" ] && [ -f "$SDK.sha256" ] || result FAILED "export produced no $SDK"
	if [ -n "$ASSETS" ] || "$GH" release view "sdk-$ID" --repo "$INDEX_REPO" >/dev/null 2>&1; then
		# A partial release without the SDK (an upload that died): complete it.
		"$GH" release upload "sdk-$ID" --repo "$INDEX_REPO" --clobber "$SDK" "$SDK.sha256" "$OUT/$TOOLS_NAME" >/dev/null 2>&1 \
			|| result FAILED "completing release sdk-$ID failed"
		STATE=REPAIRED
	else
		NOTES=$(printf 'Cross-compilation SDK for Python ABI %s, exported automatically from an attested NebulaOS firmware build (tools/sdk/publish-sdk.sh).\n\n```\n%s\n```\n' \
			"$ID" "$(tar -xJOf "$SDK" "nebulaos-sdk-$ID/sdk-info" 2>/dev/null)")
		if ! "$GH" release create "sdk-$ID" --repo "$INDEX_REPO" --title "SDK for Python ABI $ID" --notes "$NOTES" \
			"$SDK" "$SDK.sha256" "$OUT/$TOOLS_NAME" >/dev/null 2>&1; then
			# Created concurrently by another run: that one is as good.
			"$GH" release view "sdk-$ID" --repo "$INDEX_REPO" >/dev/null 2>&1 || result FAILED "creating release sdk-$ID failed"
		fi
		STATE=PUBLISHED
	fi
fi
"$GH" workflow run index.yml --repo "$INDEX_REPO" >/dev/null 2>&1 || result "$STATE" "release sdk-$ID ready; starting the index workflow failed - the daily run will pick it up"
result "$STATE" "release sdk-$ID ready; index workflow started"
