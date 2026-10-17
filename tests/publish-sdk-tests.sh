#!/bin/sh
# G71 (2026-10-17): tools/sdk/publish-sdk.sh against a fake gh, a fake
# export and a local git remote - never touches GitHub.
#
#   - a complete release: PRESENT, nothing exported or uploaded
#   - a partial release (one asset): completed (REPAIRED)
#   - no release, source on origin/main: PUBLISHED, workflow started
#   - no release, source not on origin/main: SKIPPED_UNPUBLISHED_SOURCE
#   - every failure still exits 0 and leaves the run untouched
#
# Usage: sh tests/publish-sdk-tests.sh
set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PUBLISH="$SCRIPT_DIR/../tools/sdk/publish-sdk.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/publish-sdk-tests.XXXXXX")
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Source repository with a remote; HEAD~ is published, HEAD is not.
git init -q --bare "$WORK/remote.git"
git init -q -b main "$WORK/src"
git -C "$WORK/src" commit -q --allow-empty -m one
git -C "$WORK/src" remote add origin "$WORK/remote.git"
git -C "$WORK/src" push -q origin main
PUBLISHED=$(git -C "$WORK/src" rev-parse HEAD)
git -C "$WORK/src" commit -q --allow-empty -m two
UNPUBLISHED=$(git -C "$WORK/src" rev-parse HEAD)

mkrun() { # $1=source head
	rm -rf "$WORK/run"
	mkdir -p "$WORK/run/vendor/buildroot-x2000/output/target/usr/share/nebulaos"
	printf 'id=abc123\n' > "$WORK/run/vendor/buildroot-x2000/output/target/usr/share/nebulaos/python-abi"
	printf 'BUILD_VERIFIED=YES\nSOURCE_HEAD=%s\n' "$1" > "$WORK/run/.nebulaos-build-verified"
	( cd "$WORK/run" && find . -type f | sort | xargs sha256sum ) > "$WORK/run.sum"
}

# Fake gh: release state in $WORK/gh/assets (one asset name per line;
# absent file = no release). Every call is logged.
mkdir -p "$WORK/bin" "$WORK/gh"
cat > "$WORK/bin/gh" <<FAKE
#!/bin/sh
echo "\$*" >> "$WORK/gh/calls"
case "\$1 \$2" in
	"auth status") exit 0 ;;
	"release view")
		[ -f "$WORK/gh/assets" ] || exit 1
		case "\$*" in *--json*) cat "$WORK/gh/assets" ;; esac
		exit 0 ;;
	"release create") for a in "\$@"; do case "\$a" in *.tar.xz|*.sha256) basename "\$a" >> "$WORK/gh/assets" ;; esac; done; exit 0 ;;
	"release upload") for a in "\$@"; do case "\$a" in *.tar.xz|*.sha256) basename "\$a" >> "$WORK/gh/assets" ;; esac; done; exit 0 ;;
	"workflow run") exit 0 ;;
esac
exit 1
FAKE
chmod 755 "$WORK/bin/gh"
cat > "$WORK/fake-export.sh" <<'FAKE'
#!/bin/sh
echo export >> "$(dirname "$0")/gh/calls"
printf 'sdk' > "$2/nebulaos-sdk-abc123.tar.xz"
printf 'sum' > "$2/nebulaos-sdk-abc123.tar.xz.sha256"
FAKE

publish() {
	: > "$WORK/gh/calls"
	GH="$WORK/bin/gh" EXPORT_SDK="$WORK/fake-export.sh" PUBLISH_SDK_REPO="$WORK/src" \
		PUBLISH_SDK_INDEX_URL="file://$WORK/no-index" sh "$PUBLISH" "$WORK/run" > "$WORK/out" 2>&1
	echo $? > "$WORK/rc"
}
unchanged() { ( cd "$WORK/run" && find . -type f | sort | xargs sha256sum ) | cmp -s - "$WORK/run.sum"; }

mkrun "$PUBLISHED"
printf 'nebulaos-sdk-abc123.tar.xz\nnebulaos-sdk-abc123.tar.xz.sha256\n' > "$WORK/gh/assets"
publish
grep -q '^SDK_PUBLISH=PRESENT' "$WORK/out" && ! grep -q 'export\|upload\|create' "$WORK/gh/calls" \
	&& pass "complete release: PRESENT, nothing exported or uploaded" || { fail "complete release"; cat "$WORK/out" "$WORK/gh/calls"; }
grep -qx 'SDK_INDEX_READY=NO' "$WORK/out" && pass "index readiness is reported" || fail "no SDK_INDEX_READY line"

printf 'nebulaos-sdk-abc123.tar.xz\n' > "$WORK/gh/assets"
publish
grep -q '^SDK_PUBLISH=REPAIRED' "$WORK/out" && grep -q 'release upload' "$WORK/gh/calls" \
	&& pass "partial release: completed, not skipped" || { fail "partial release"; cat "$WORK/out" "$WORK/gh/calls"; }

rm -f "$WORK/gh/assets"
publish
grep -q '^SDK_PUBLISH=PUBLISHED' "$WORK/out" && grep -q 'release create' "$WORK/gh/calls" && grep -q 'workflow run' "$WORK/gh/calls" \
	&& pass "no release, published source: release created and the index workflow started" || { fail "publish"; cat "$WORK/out" "$WORK/gh/calls"; }

rm -f "$WORK/gh/assets"
mkrun "$UNPUBLISHED"
publish
grep -q '^SDK_PUBLISH=SKIPPED_UNPUBLISHED_SOURCE' "$WORK/out" && ! grep -q 'export\|create' "$WORK/gh/calls" \
	&& pass "unpublished source: skipped, nothing exported or uploaded" || { fail "unpublished source"; cat "$WORK/out" "$WORK/gh/calls"; }

rm -f "$WORK/gh/assets"
mkrun "$PUBLISHED"
printf '#!/bin/sh\nexit 1\n' > "$WORK/fail-export.sh"
: > "$WORK/gh/calls"
GH="$WORK/bin/gh" EXPORT_SDK="$WORK/fail-export.sh" PUBLISH_SDK_REPO="$WORK/src" \
	PUBLISH_SDK_INDEX_URL="file://$WORK/no-index" sh "$PUBLISH" "$WORK/run" > "$WORK/out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && grep -q '^SDK_PUBLISH=FAILED' "$WORK/out" && ! grep -q 'create' "$WORK/gh/calls" \
	&& pass "a failing export: FAILED, exit 0, nothing uploaded" || { fail "failing export (rc=$rc)"; cat "$WORK/out"; }
unchanged && pass "the build run is never modified" || fail "the run changed"

rm -f "$WORK/run/.nebulaos-build-verified"
publish
[ "$(cat "$WORK/rc")" -eq 0 ] && grep -q '^SDK_PUBLISH=FAILED (the run has no verified build attestation)' "$WORK/out" \
	&& pass "an unattested run is refused" || { fail "unattested run"; cat "$WORK/out"; }

echo "publish-sdk-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
