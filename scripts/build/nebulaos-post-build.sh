#!/bin/sh
# Buildroot BR2_ROOTFS_POST_BUILD_SCRIPT for NebulaOS.
#
# Runs with $1 = TARGET_DIR, after TARGET_FINALIZE_HOOKS and after the rootfs
# overlay copy (Buildroot's own Makefile order: hooks, then overlays, then this
# script). That ordering is why the root password is fixed here rather than in
# the overlay or in BR2_TARGET_GENERIC_ROOT_PASSWD.
#
# WHY NOT BR2_TARGET_GENERIC_ROOT_PASSWD. Buildroot only treats that value as
# an already-hashed password when it matches $1$/$5$/$6$ - but .config is
# INCLUDED BY MAKE, which expands `$5` and friends as variables before that
# match ever runs. Measured: the hash
#
#     $5$NebulaOSrootsalt$loBE3...
#
# arrives at the match as `ebulaOSrootsaltoBE3...`, fails it, and falls through
# to mkpasswd, which salts randomly - rewriting /etc/shadow on every build.
# Doubling or backslash-escaping the dollars does not survive either, because
# $(call qstrip,...) expands the value a second time.
#
# WHY NOT THE OVERLAY. /etc/shadow is mode 0600 in the image. Git records only
# 0644 or 0755, so shipping it through the overlay would publish a
# world-readable shadow file. That is a worse defect than the one being fixed.
#
# So: edit the line in place, here, preserving the file's existing mode and
# every other account. Same password as before - only the salt stops being
# random.
set -eu

TARGET_DIR=${1:?usage: nebulaos-post-build.sh <TARGET_DIR>}
SHADOW="$TARGET_DIR/etc/shadow"

# sha256-crypt of the project's existing root password, with a fixed salt.
# Regenerate with:  openssl passwd -5 -salt NebulaOSrootsalt <password>
ROOT_HASH='$5$NebulaOSrootsalt$loBE3SnC0VQEEc2oYlmeqfOM/8ttzKP9k6xuKkH25NB'

[ -f "$SHADOW" ] || {
	echo "FATAL: post-build: $SHADOW not found" >&2
	exit 1
}

grep -q '^root:' "$SHADOW" || {
	echo "FATAL: post-build: no root entry in $SHADOW" >&2
	exit 1
}

mode_before=$(stat -c %a "$SHADOW")

# Replace only the password field of the root line. Other accounts, and every
# other field, are left exactly as Buildroot produced them.
awk -v h="$ROOT_HASH" -F: 'BEGIN{OFS=":"} $1=="root"{$2=h} {print}' \
	"$SHADOW" > "$SHADOW.nebulaos-tmp"
mv -f "$SHADOW.nebulaos-tmp" "$SHADOW"
chmod "$mode_before" "$SHADOW"

grep -qF "$ROOT_HASH" "$SHADOW" || {
	echo "FATAL: post-build: deterministic root hash did not land in $SHADOW" >&2
	exit 1
}

mode_after=$(stat -c %a "$SHADOW")
[ "$mode_before" = "$mode_after" ] || {
	echo "FATAL: post-build: $SHADOW mode changed $mode_before -> $mode_after" >&2
	exit 1
}

echo "== post-build: /etc/shadow root hash pinned (mode $mode_after preserved) =="

# GuppyScreen "Reset GuppyScreen settings" (GUI readiness work, 2026-10-10):
# at runtime /opt/guppyscreen/guppyconfig.json is bind-mounted over by the
# persistent copy (S01persistent-datastore), so the shipped default is no
# longer readable there. Keep a read-only copy of the same file, made here so
# it can never drift from the seed source; GuppyScreen writes it back over
# the persistent config in place.
GUPPY_DEFAULT_SRC="$TARGET_DIR/opt/guppyscreen/guppyconfig.json"
GUPPY_DEFAULT_DST="$TARGET_DIR/usr/share/nebulaos/guppyscreen/guppyconfig.default.json"
[ -f "$GUPPY_DEFAULT_SRC" ] || {
	echo "FATAL: post-build: $GUPPY_DEFAULT_SRC missing" >&2
	exit 1
}
mkdir -p "$(dirname "$GUPPY_DEFAULT_DST")"
cp "$GUPPY_DEFAULT_SRC" "$GUPPY_DEFAULT_DST"
chmod 644 "$GUPPY_DEFAULT_DST"
cmp -s "$GUPPY_DEFAULT_SRC" "$GUPPY_DEFAULT_DST" || {
	echo "FATAL: post-build: GuppyScreen default config copy differs" >&2
	exit 1
}
echo "== post-build: GuppyScreen default config kept at /usr/share/nebulaos/guppyscreen =="

# G49 (2026-10-15): pip starts its build-isolation helper by its .py path
# (pip/__pip-runner__.py). Buildroot installs Python modules as .pyc only, so
# the image had __pip-runner__.pyc alone and every source build on the
# printer failed ("can't open file .../__pip-runner__.py") - an app update
# whose dependencies need one could never install. Ship that one file.
PIP_BUILD_SRC=$(ls -d "${BUILD_DIR:-$(dirname "$TARGET_DIR")/build}"/python-pip-*/src/pip 2>/dev/null | head -1)
[ -n "$PIP_BUILD_SRC" ] && [ -f "$PIP_BUILD_SRC/__pip-runner__.py" ] || {
	echo "FATAL: post-build: pip's __pip-runner__.py not found in the Buildroot build tree" >&2
	exit 1
}
# 2026-10-15 (P15 repeat): __pip-runner__.py alone was not enough - pip also
# starts pip/_vendor/pyproject_hooks/_in_process/_in_process.py by path, and
# may start others. Ship pip's whole .py source next to the .pyc files.
for PIP_DIR in "$TARGET_DIR"/usr/lib/python3*/site-packages/pip; do
	[ -d "$PIP_DIR" ] || continue
	( cd "$PIP_BUILD_SRC" && find . -name '*.py' ) | while read -r PIP_PY; do
		mkdir -p "$PIP_DIR/$(dirname "$PIP_PY")"
		cp "$PIP_BUILD_SRC/$PIP_PY" "$PIP_DIR/$PIP_PY"
		chmod 644 "$PIP_DIR/$PIP_PY"
	done
	[ -f "$PIP_DIR/_vendor/pyproject_hooks/_in_process/_in_process.py" ] || {
		echo "FATAL: post-build: pip's _in_process.py did not arrive in ${PIP_DIR#$TARGET_DIR}" >&2
		exit 1
	}
	echo "== post-build: pip .py source shipped in ${PIP_DIR#$TARGET_DIR} =="
done

# G50 (2026-10-17): the image's Python ABI fingerprint and /etc/pip.conf.
# Derived ONCE, here, from this build's .config, sysroot and libc (see
# python-abi.sh); the SDK export and the package index CI copy the file.
POST_BUILD_DIR=$(cd "$(dirname "$0")" && pwd)
. "$POST_BUILD_DIR/python-abi.sh"
ABI_FILE="$TARGET_DIR/usr/share/nebulaos/python-abi"
mkdir -p "$(dirname "$ABI_FILE")"
python_abi_fingerprint "${BR2_CONFIG:?}" "$TARGET_DIR" "${STAGING_DIR:?}" > "$ABI_FILE.tmp" || {
	echo "FATAL: post-build: Python ABI fingerprint could not be derived" >&2
	exit 1
}
mv -f "$ABI_FILE.tmp" "$ABI_FILE"
chmod 644 "$ABI_FILE"
ABI_ID=$(sed -n 's/^id=//p' "$ABI_FILE")
INDEX_URL=$(cat "$POST_BUILD_DIR/package-index.url")
[ -n "$ABI_ID" ] && [ -n "$INDEX_URL" ] || { echo "FATAL: post-build: no ABI id or index URL" >&2; exit 1; }
python_abi_pip_conf "$INDEX_URL" "$ABI_ID" > "$TARGET_DIR/etc/pip.conf"
chmod 644 "$TARGET_DIR/etc/pip.conf"
echo "== post-build: Python ABI $ABI_ID; pip.conf -> $INDEX_URL/$ABI_ID/ (only-binary) =="
# G72: where the update supervisor finds c_helper.so for a Klipper update.
CHELPER_URL=$(cat "$POST_BUILD_DIR/chelper-index.url")
[ -n "$CHELPER_URL" ] || { echo "FATAL: post-build: no chelper index URL" >&2; exit 1; }
printf '%s\n' "$CHELPER_URL" > "$TARGET_DIR/usr/share/nebulaos/chelper-index.url"
chmod 644 "$TARGET_DIR/usr/share/nebulaos/chelper-index.url"

# G81 (2026-10-18): /etc/os-release names NebulaOS and its version, so
# Moonraker/Mainsail's system info shows "NebulaOS 0.9.0" instead of
# "Buildroot 2025.02.18". The version is NEBULAOS_VERSION from
# manifests/dependencies.conf, which 02-configure-buildroot.sh writes next to
# this script (like package-index.url) - the same value 04 writes into
# /opt/nebulaos-version.json. Not read from that file: the first Buildroot
# pass runs this script before 04 has written the overlay (measured, build
# ea3ad0f). The commit is added when the file is there; the final pass always
# has it, and 06-verify checks the finished image. Buildroot wrote
# usr/lib/os-release in target-finalize, before this script; /etc/os-release
# is its symlink.
NOS_VERSION=$(cat "$POST_BUILD_DIR/nebulaos-version" 2>/dev/null || true)
VERSION_JSON="$TARGET_DIR/opt/nebulaos-version.json"
NOS_SHA=$(sed -n 's/^ *"firmware_sha": *"\([0-9a-f]\{7\}\).*/\1/p' "$VERSION_JSON" 2>/dev/null | head -1)
printf '%s' "$NOS_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
	echo "FATAL: post-build: no semver version in $POST_BUILD_DIR/nebulaos-version" >&2
	exit 1
}
BR_VERSION=$(sed -n 's/^VERSION_ID=//p' "$TARGET_DIR/usr/lib/os-release" 2>/dev/null | head -1)
{
	echo "NAME=NebulaOS"
	echo "VERSION=\"$NOS_VERSION${NOS_SHA:+ ($NOS_SHA)}\""
	echo "ID=nebulaos"
	echo "ID_LIKE=buildroot"
	echo "VERSION_ID=$NOS_VERSION"
	echo "PRETTY_NAME=\"NebulaOS $NOS_VERSION\""
	[ -n "$BR_VERSION" ] && echo "BUILDROOT_VERSION=$BR_VERSION"
} > "$TARGET_DIR/usr/lib/os-release"
chmod 644 "$TARGET_DIR/usr/lib/os-release"
ln -sf ../usr/lib/os-release "$TARGET_DIR/etc/os-release"
echo "== post-build: /etc/os-release -> NebulaOS $NOS_VERSION =="
