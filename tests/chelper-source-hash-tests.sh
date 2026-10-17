#!/bin/sh
# G72 (2026-10-17): the c_helper.so source hash and the matching-library
# install (etc/nebulaos-chelper-preflight.sh).
#
#   - the hash over the files on disk equals the hash from git objects
#   - a rename, and content moving between files, change it
#   - files outside the set (README, *.so, subdirectories) do not
#   - an install sets the library's mtime from the newest source, so it holds
#     even when the clock is behind the sources (before NTP)
#   - a damaged cache entry is removed, never installed
# Runs under BusyBox sh too when busybox is installed (the device shell).
#
# Usage: sh tests/chelper-source-hash-tests.sh
set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LIB="$SCRIPT_DIR/../scripts/build/overlay/etc/nebulaos-chelper-preflight.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/chelper-hash.XXXXXX")
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

SHELLS="sh"
command -v busybox >/dev/null 2>&1 && SHELLS="sh busybox-sh"
run() { # $1=shell, rest = script
	_s=$1; shift
	if [ "$_s" = busybox-sh ]; then busybox sh -c ". '$LIB'; $*"; else sh -c ". '$LIB'; $*"; fi
}

mk() { # $1=dir, then name=content pairs
	_d=$1; shift
	rm -rf "$_d"; mkdir -p "$_d/klippy/chelper/sub"
	printf '*.so\n' > "$_d/.gitignore"
	for _p in "$@"; do printf '%s' "${_p#*=}" > "$_d/klippy/chelper/${_p%%=*}"; done
	git -C "$_d" init -q; git -C "$_d" add -A; git -C "$_d" commit -qm init
}

for SH in $SHELLS; do
	K="$WORK/k"
	mk "$K" "__init__.py=init" "a.c=xy" "b.c=z" "c.h=hdr"
	H=$(run "$SH" "chelper_source_hash '$K'")
	G=$(run "$SH" "chelper_source_hash_git '$K' HEAD")
	[ ${#H} -eq 64 ] && [ "$H" = "$G" ] && pass "$SH: worktree hash = git-object hash" || fail "$SH: worktree $H, git $G"

	printf 'readme' > "$K/klippy/chelper/README"
	printf 'lib' > "$K/klippy/chelper/c_helper.so"
	printf 'x' > "$K/klippy/chelper/sub/d.c"
	[ "$(run "$SH" "chelper_source_hash '$K'")" = "$H" ] && pass "$SH: files outside the set do not count" || fail "$SH: an unrelated file changed the hash"
	rm -rf "$K/klippy/chelper/README" "$K/klippy/chelper/sub"

	mk "$WORK/k2" "__init__.py=init" "a.c=x" "b.c=yz" "c.h=hdr"
	[ "$(run "$SH" "chelper_source_hash '$WORK/k2'")" != "$H" ] && pass "$SH: content moving between files changes the hash" || fail "$SH: boundary shift collides"
	mk "$WORK/k3" "__init__.py=init" "a2.c=xy" "b.c=z" "c.h=hdr"
	[ "$(run "$SH" "chelper_source_hash '$WORK/k3'")" != "$H" ] && pass "$SH: a rename changes the hash" || fail "$SH: rename collides"

	# Dirty tree: the files on disk decide, not HEAD.
	printf 'changed' > "$K/klippy/chelper/a.c"
	[ "$(run "$SH" "chelper_source_hash '$K'")" != "$H" ] && pass "$SH: a dirty worktree is hashed as it is on disk" || fail "$SH: dirty change not seen"
	git -C "$K" checkout -q -- klippy/chelper/a.c

	# Install with the sources in the future (clock before NTP).
	touch -d '2035-01-01 00:00:00' "$K/klippy/chelper/a.c"
	printf 'new lib' > "$WORK/lib.so"
	if run "$SH" "chelper_install_file '$K' '$WORK/lib.so'" 2>/dev/null && \
	   [ "$(cat "$K/klippy/chelper/c_helper.so")" = "new lib" ] && \
	   run "$SH" "chelper_check_mtime '$K'" 2>/dev/null; then
		pass "$SH: an installed library satisfies the mtime rule even when the sources are newer than the clock"
	else
		fail "$SH: install with future source mtimes"
	fi
	[ -z "$(git -C "$K" status --porcelain)" ] && pass "$SH: the install leaves the Klipper tree clean" || fail "$SH: tree dirty after install"

	# Cache: damaged entries are removed, good ones installed.
	printf 'id=t\n' > "$WORK/abi"
	C="$WORK/cache"; rm -rf "$C"
	touch "$K/klippy/chelper/b.c"
	H=$(run "$SH" "chelper_source_hash '$K'")
	mkdir -p "$C/t/$H"; printf 'cached' > "$C/t/$H/c_helper.so"; echo bad > "$C/t/$H/sha256"
	if ! NEBULAOS_CHELPER_CACHE="$C" NEBULAOS_PYTHON_ABI_FILE="$WORK/abi" run "$SH" "chelper_install_matching '$K'" 2>/dev/null && \
	   [ ! -e "$C/t/$H" ] && [ "$(cat "$K/klippy/chelper/c_helper.so")" = "new lib" ]; then
		pass "$SH: a damaged cache entry is removed and nothing is installed"
	else
		fail "$SH: damaged cache entry handling"
	fi
	if NEBULAOS_CHELPER_CACHE="$C" NEBULAOS_PYTHON_ABI_FILE="$WORK/abi" run "$SH" "chelper_cache_put t '$H' '$WORK/lib.so' && chelper_install_matching '$K'" 2>/dev/null && \
	   run "$SH" "chelper_check_mtime '$K'" 2>/dev/null; then
		pass "$SH: a cached library for the current sources is installed"
	else
		fail "$SH: cache install"
	fi
	# Bounded cache.
	for i in 1 2 3 4 5 6 7 8 9 10; do
		NEBULAOS_CHELPER_CACHE="$C" run "$SH" "chelper_cache_put t h$i '$WORK/lib.so'" 2>/dev/null
	done
	[ "$(ls "$C/t" | wc -l)" -eq 8 ] && pass "$SH: the cache keeps at most 8 libraries per ABI" || fail "$SH: cache has $(ls "$C/t" | wc -l) entries"
done

echo "chelper-source-hash-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
