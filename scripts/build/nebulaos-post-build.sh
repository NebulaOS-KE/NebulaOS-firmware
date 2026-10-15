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
