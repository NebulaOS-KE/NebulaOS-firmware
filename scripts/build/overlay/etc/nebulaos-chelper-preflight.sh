#!/bin/sh
#
# NebulaOS Phase 1 no-fork migration: the c_helper.so mtime invariant.
#
# WHY THIS EXISTS
# ---------------
# Klipper decides whether to rebuild its C library by comparing MTIMES, not
# hashes. From official klippy/chelper/__init__.py at the qualified commit:
#
#     def check_build_code(sources, target):
#         src_times = get_mtimes(sources)
#         obj_times = get_mtimes([target])
#         return not obj_times or max(src_times) > min(obj_times)
#
#     def check_build_c_library():
#         srcdir  = os.path.dirname(os.path.realpath(__file__))
#         ...
#         if not check_build_code(srcfiles+ofiles+[__file__], destlib):
#             # Code already built
#             return destlib
#         ...
#         do_build_code(cmd % (tempdestlib, ' '.join(srcfiles)))
#
# where sources = SOURCE_FILES (*.c) + OTHER_FILES (*.h) + __init__.py, all
# inside klippy/chelper/, and target = klippy/chelper/c_helper.so.
#
# If ANY of those is newer than the prebuilt .so, mainline shells out to
# gcc. This device has no toolchain, so do_build_code() raises and Klippy
# does not start - a total printer outage produced by a file timestamp.
# That is the whole reason NebulaOS does not need (and deliberately does not
# carry) the old fork's patch to this file: it is a firmware packaging
# problem, and packaging is where it is solved.
#
# TWO HALVES, BOTH REQUIRED
# -------------------------
#  1. Build time - scripts/build/04-cross-compile-app-stack.sh calls
#     chelper_enforce_mtime() as the LAST step over every staged copy of the
#     Klipper tree, then chelper_check_mtime() as a hard gate. The build
#     fails rather than shipping an image that will not boot. This is
#     deliberate belt-and-braces: relying on "the .so happens to be built
#     after the sources were checked out" is exactly the build-order luck
#     that a `cp -r` (which does not preserve mtimes) or a later
#     `git read-tree -mu` can quietly invert.
#
#  2. Boot time - S05nebulaos-activate calls chelper_write_verdict() after
#     composition and before Klipper starts. Packaging correctness at build
#     time does not survive everything the device can do afterwards: a
#     Moonraker-driven `git pull` that touches a chelper source, a
#     `git reset --hard` during rollback, a restored backup. So the
#     invariant is re-checked against the tree that is actually about to
#     run, and the verdict is written where the extension set's own preflight
#     (extras/nebulaos_compat.py, via the manifest's
#     chelper.platform_result_file) will read it.
#
# The verdict file therefore makes a stale .so surface as a named,
# fail-closed preflight error at config load - "the platform reported the
# chelper prebuilt-library invariant as NOT satisfied" - instead of as a gcc
# crash part way through boot, or worse, a slow successful on-device
# compile that masks a real packaging bug.
#
# WHY find -newer AND NOT stat
# ----------------------------
# BusyBox on this device has no `stat` applet at all (confirmed live
# elsewhere in this project - see S05nebulaos-activate's own `ls -ldn`
# workaround). `find -newer` performs precisely the comparison Klipper's own
# check performs, is present in BusyBox find, and needs no arithmetic on
# timestamps. The glob below (*.c, *.h, __init__.py) is a strict SUPERSET of
# SOURCE_FILES+OTHER_FILES+__file__, so this check can only ever be stricter
# than Klipper's, never laxer.
#
# POSIX sh only - BusyBox ash. Sourced by S05nebulaos-activate,
# nebulaos-update-supervisor.sh, and 04-cross-compile-app-stack.sh.

NEBULAOS_CHELPER_VERDICT_NAME=".nebulaos-chelper-verdict.json"
NEBULAOS_CHELPER_SUBDIR="klippy/chelper"
NEBULAOS_CHELPER_TARGET="klippy/chelper/c_helper.so"

# Progress goes to stderr, deliberately, and this is not a style choice.
# chelper_enforce_mtime() is called from inside make_seed_archive(), whose
# stdout IS its return value - the packaged commit SHA, captured by the build
# as `klipper_seed_commit=$(make_seed_archive ...)`. A log line on stdout
# there does not look like a logging mistake, it silently corrupts the seed
# manifest and the migration_version hash derived from it. Found by
# tests/klipper-stack-lifecycle-tests.sh, which compares migrated commits
# against the values make_seed_archive reported.
chelper_log() {
	echo "nebulaos-chelper-preflight: $1" >&2
}

chelper_err() {
	echo "nebulaos-chelper-preflight: ERROR: $1" >&2
}

# Every input Klipper's own check_build_code() considers, plus a margin.
# $1=klipper checkout
chelper_sources() {
	find "$1/$NEBULAOS_CHELPER_SUBDIR" -maxdepth 1 -type f \
		\( -name '*.c' -o -name '*.h' -o -name '__init__.py' \) 2>/dev/null
}

# Returns 0 when the invariant holds (no source is newer than the target).
# Echoes the offending file list on failure so the caller can report it.
# $1=klipper checkout
chelper_check_mtime() {
	kdir="$1"
	target="$kdir/$NEBULAOS_CHELPER_TARGET"
	srcdir="$kdir/$NEBULAOS_CHELPER_SUBDIR"

	if [ ! -d "$srcdir" ]; then
		chelper_err "$srcdir does not exist - not a Klipper checkout"
		return 2
	fi
	if [ ! -f "$target" ]; then
		chelper_err "prebuilt $NEBULAOS_CHELPER_TARGET is MISSING from $kdir. Klipper would invoke gcc to build it, and this device has no toolchain."
		return 3
	fi

	newer=$(find "$srcdir" -maxdepth 1 -type f \
		\( -name '*.c' -o -name '*.h' -o -name '__init__.py' \) \
		-newer "$target" 2>/dev/null)
	if [ -n "$newer" ]; then
		chelper_err "the following chelper source(s) are NEWER than $NEBULAOS_CHELPER_TARGET, so Klipper's check_build_code() would trigger a gcc rebuild:"
		printf '%s\n' "$newer" >&2
		return 1
	fi
	return 0
}

# Make the invariant true, deterministically, rather than hoping build order
# produced it. Called at build time only - never on the device, where
# touching the .so forward would paper over a real staleness problem that
# the verdict file is meant to expose. (The device installs a MATCHING
# library instead - chelper_make_ready() below - never a blind touch.)
# $1=klipper checkout
chelper_enforce_mtime() {
	kdir="$1"
	target="$kdir/$NEBULAOS_CHELPER_TARGET"
	if [ ! -f "$target" ]; then
		chelper_err "cannot enforce the mtime invariant: $target does not exist"
		return 1
	fi
	# `touch` with no -r/-d sets the file to now, which is >= the mtime of
	# every file already on disk. The verification immediately afterwards is
	# what makes this a guarantee rather than an assumption - if anything
	# writes a source file in the same second (or later), the build fails
	# loudly here instead of the printer failing to boot later.
	touch "$target" || return 1
	chelper_check_mtime "$kdir" || {
		chelper_err "the mtime invariant STILL does not hold for $kdir after touching $NEBULAOS_CHELPER_TARGET - something is rewriting chelper sources after this step; fix the step ordering rather than retrying"
		return 1
	}
	chelper_log "mtime invariant enforced and verified for $kdir"
	return 0
}

# Write the platform's verdict where extras/nebulaos_compat.py reads it.
# Always writes a file - a failing verdict is information the extension
# preflight needs, and its absence is treated by that code as its own
# distinct (also fail-closed) error.
# $1=klipper checkout
# Returns 0 only when the verdict is "ok".
chelper_write_verdict() {
	kdir="$1"
	out="$kdir/$NEBULAOS_CHELPER_VERDICT_NAME"
	# This script runs BOTH at build time (writing into the image) and at boot on
	# the device. When SOURCE_DATE_EPOCH is set, this is the build; use it, so the
	# verdict file does not carry a fresh wall-clock stamp into every image. When
	# it is unset, this is a real boot and the wall clock is the right answer -
	# which is what the checked_at_caveat below is about.
	if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
		now=$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
	else
		now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	fi

	chelper_check_mtime "$kdir"
	rc=$?

	case "$rc" in
		0) status="ok";      detail="prebuilt c_helper.so is newer than every chelper source; Klipper will not invoke gcc" ;;
		1) status="stale";   detail="one or more chelper sources are newer than the prebuilt c_helper.so; Klipper would attempt a gcc rebuild and this device has no toolchain" ;;
		3) status="missing"; detail="the prebuilt c_helper.so is absent from the Klipper checkout" ;;
		*) status="invalid"; detail="the Klipper checkout has no klippy/chelper directory" ;;
	esac

	kc=$(git -C "$kdir" rev-parse HEAD 2>/dev/null || echo "nogit")
	srch=$(chelper_source_hash "$kdir" 2>/dev/null || echo "unknown")
	tmp="$out.tmp.$$"
	cat > "$tmp" <<EOF
{
  "schema": 1,
  "status": "$status",
  "detail": "$detail",
  "requirement": "prebuilt_so_mtime_newer_than_all_chelper_sources",
  "target": "$NEBULAOS_CHELPER_TARGET",
  "source_dir": "$NEBULAOS_CHELPER_SUBDIR",
  "klipper_commit": "$kc",
  "source_hash": "$srch",
  "library_from": "${CHELPER_INSTALLED_FROM:-in_tree}",
  "checked_at": "$now",
  "checked_at_caveat": "may read as an early-epoch date if this boot occurred before NTP sync",
  "checked_by": "/etc/nebulaos-chelper-preflight.sh"
}
EOF
	mv "$tmp" "$out"

	if [ "$status" = "ok" ]; then
		chelper_log "verdict ok - wrote $out"
		return 0
	fi
	chelper_err "verdict '$status' - wrote $out; Klipper must NOT be started against this tree"
	return 1
}

# --- G72 (2026-10-17): a matching c_helper.so after a Klipper update -------
#
# A Klipper update that changes a chelper source needs a library built from
# THOSE sources. The device has no compiler, so it uses one built elsewhere,
# chosen by the source hash below - never by touching the old library:
#
#   1. the local cache   $NEBULAOS_ROOT/cache/chelper/<abi id>/<hash>/
#      seeded with the image's own library (/usr/share/nebulaos/chelper
#      records its hash and sha256), plus every library a known-good pair
#      ran with, plus every verified download. This is also what makes a
#      rollback work offline: `git reset --hard` brings back sources whose
#      library is already here.
#   2. the NebulaOS package index (supervisor only - never at boot, S05 runs
#      before Wi-Fi/DNS/NTP): <chelper url>/<abi id>/index lists
#      "<source hash> <sha256> <size>", the library is <hash>/c_helper.so,
#      built by the index CI with the SDK's lib/build-chelper.sh.
#
# Same trust as the wheels: HTTPS + sha256 from the index, not a signature.
# Nothing in the Klipper tree is written except c_helper.so (git-ignored by
# upstream's *.so rule). Any mismatch or error leaves the tree unchanged, so
# the fail-closed verdict above still decides.

NEBULAOS_CHELPER_CACHE="${NEBULAOS_CHELPER_CACHE:-${NEBULAOS_ROOT:-/usr/data/nebulaos}/cache/chelper}"
NEBULAOS_CHELPER_IMAGE_RECORD="${NEBULAOS_CHELPER_IMAGE_RECORD:-/usr/share/nebulaos/chelper}"
NEBULAOS_CHELPER_IMAGE_SO="${NEBULAOS_CHELPER_IMAGE_SO:-/opt/klipper/klippy/chelper/c_helper.so}"
NEBULAOS_CHELPER_URL_FILE="${NEBULAOS_CHELPER_URL_FILE:-/usr/share/nebulaos/chelper-index.url}"
NEBULAOS_PYTHON_ABI_FILE="${NEBULAOS_PYTHON_ABI_FILE:-/usr/share/nebulaos/python-abi}"
NEBULAOS_CHELPER_CACHE_KEEP="${NEBULAOS_CHELPER_CACHE_KEEP:-8}"

chelper_sha256() {
	sha256sum "$1" 2>/dev/null | cut -d' ' -f1
}

# The source hash: sha256 over "<name> <sha256 of content>\n" for every
# *.c, *.h and __init__.py directly in klippy/chelper (the same set as the
# mtime check), sorted by name in the C locale. Name and content are both
# framed, so a rename or content moving between files changes it.
# ONE definition: the device, the image build (04) and the index CI (via
# the SDK's copy of this file) all use these two functions.
# $1=klipper checkout (the files as they are on disk - also when dirty)
chelper_source_hash() {
	[ -d "$1/$NEBULAOS_CHELPER_SUBDIR" ] || return 1
	(
		cd "$1/$NEBULAOS_CHELPER_SUBDIR" || exit 1
		find . -maxdepth 1 -type f \( -name '*.c' -o -name '*.h' -o -name '__init__.py' \) \
			| sed 's#^\./##' | LC_ALL=C sort | while read -r n; do
			printf '%s %s\n' "$n" "$(sha256sum < "$n" | cut -d' ' -f1)"
		done
	) | sha256sum | cut -d' ' -f1
}

# The same hash from git objects, without a checkout (G73: what an update
# to <rev> would need). $1=git repo $2=rev
chelper_source_hash_git() {
	git -C "$1" rev-parse -q --verify "$2^{commit}" >/dev/null 2>&1 || return 1
	git -C "$1" ls-tree "$2" "$NEBULAOS_CHELPER_SUBDIR/" 2>/dev/null \
		| awk '$1 != "120000" && $2 == "blob" { sub(/^[^\t]*\t/, ""); print }' \
		| sed 's#^.*/##' | grep -E '\.(c|h)$|^__init__\.py$' | LC_ALL=C sort \
		| while read -r n; do
			printf '%s %s\n' "$n" "$(git -C "$1" cat-file blob "$2:$NEBULAOS_CHELPER_SUBDIR/$n" | sha256sum | cut -d' ' -f1)"
		done | sha256sum | cut -d' ' -f1
}

chelper_abi_id() {
	sed -n 's/^id=//p' "$NEBULAOS_PYTHON_ABI_FILE" 2>/dev/null | head -1
}

# Put a library into the cache under <hash>, atomically. With $4 (expected
# sha256) a mismatch is refused. $1=abi id $2=source hash $3=file [$4=sha256]
chelper_cache_put() {
	_cid="$1"; _ch="$2"; _cf="$3"; _cexp="${4:-}"
	[ -n "$_cid" ] && [ -n "$_ch" ] && [ -f "$_cf" ] || return 1
	_csum=$(chelper_sha256 "$_cf")
	if [ -n "$_cexp" ] && [ "$_csum" != "$_cexp" ]; then
		chelper_err "refusing $_cf for the cache: sha256 $_csum, expected $_cexp"
		return 1
	fi
	_cdir="$NEBULAOS_CHELPER_CACHE/$_cid/$_ch"
	if [ -f "$_cdir/c_helper.so" ] && [ "$(cat "$_cdir/sha256" 2>/dev/null)" = "$_csum" ]; then
		touch "$_cdir" 2>/dev/null
		return 0
	fi
	mkdir -p "$NEBULAOS_CHELPER_CACHE/$_cid" || return 1
	_ctmp="$NEBULAOS_CHELPER_CACHE/$_cid/.put.$$"
	rm -rf "$_ctmp"
	mkdir -p "$_ctmp" && cp "$_cf" "$_ctmp/c_helper.so" && echo "$_csum" > "$_ctmp/sha256" || {
		rm -rf "$_ctmp"; return 1
	}
	rm -rf "$_cdir"
	mv "$_ctmp" "$_cdir" || { rm -rf "$_ctmp"; return 1; }
	# Bounded: keep the most recently used entries for this ABI.
	ls -1dt "$NEBULAOS_CHELPER_CACHE/$_cid"/* 2>/dev/null \
		| tail -n +"$((NEBULAOS_CHELPER_CACHE_KEEP + 1))" | while read -r _old; do
		rm -rf "$_old"
	done
	chelper_log "cached c_helper.so for source hash $_ch"
	return 0
}

# The image's own library, under the hash recorded at build time. Only when
# the file still has the recorded sha256 (after activation /opt/klipper is
# the persistent checkout, whose library may be another one).
chelper_cache_seed_image() {
	[ -f "$NEBULAOS_CHELPER_IMAGE_RECORD" ] || return 0
	_sh=$(sed -n 's/^source_hash=//p' "$NEBULAOS_CHELPER_IMAGE_RECORD")
	_ss=$(sed -n 's/^sha256=//p' "$NEBULAOS_CHELPER_IMAGE_RECORD")
	_sid=$(chelper_abi_id)
	[ -n "$_sh" ] && [ -n "$_ss" ] && [ -n "$_sid" ] || return 0
	[ -f "$NEBULAOS_CHELPER_CACHE/$_sid/$_sh/c_helper.so" ] && return 0
	[ "$(chelper_sha256 "$NEBULAOS_CHELPER_IMAGE_SO")" = "$_ss" ] || return 0
	chelper_cache_put "$_sid" "$_sh" "$NEBULAOS_CHELPER_IMAGE_SO" "$_ss"
}

# The library a tree runs with right now, when it satisfies the invariant
# (called once a pair is known-good, and after an ok boot verdict).
# $1=klipper checkout
chelper_cache_current() {
	chelper_check_mtime "$1" 2>/dev/null || return 0
	_kh=$(chelper_source_hash "$1") || return 0
	chelper_cache_put "$(chelper_abi_id)" "$_kh" "$1/$NEBULAOS_CHELPER_TARGET"
}

# Install a library as the tree's c_helper.so: a temporary *.so next to it
# (git-ignored), mtime copied from the newest source (never "now" - the
# clock may be before NTP), atomic rename, then the invariant re-checked.
# $1=klipper checkout $2=library
chelper_install_file() {
	_kd="$1"; _src="$2"
	_newest=$(ls -1t $(chelper_sources "$_kd") 2>/dev/null | head -1)
	[ -n "$_newest" ] || return 1
	_tmp="$_kd/$NEBULAOS_CHELPER_SUBDIR/.nebulaos-install.$$.so"
	cp "$_src" "$_tmp" && touch -r "$_newest" "$_tmp" && mv "$_tmp" "$_kd/$NEBULAOS_CHELPER_TARGET" || {
		rm -f "$_tmp"; return 1
	}
	chelper_check_mtime "$_kd"
}

# From the cache only (no network - safe at boot). $1=klipper checkout
chelper_install_matching() {
	_kd="$1"
	_mh=$(chelper_source_hash "$_kd") || return 1
	_mid=$(chelper_abi_id)
	_md="$NEBULAOS_CHELPER_CACHE/$_mid/$_mh"
	[ -n "$_mid" ] && [ -f "$_md/c_helper.so" ] || return 1
	if [ "$(chelper_sha256 "$_md/c_helper.so")" != "$(cat "$_md/sha256" 2>/dev/null)" ]; then
		chelper_err "cached library for $_mh is damaged - removing it"
		rm -rf "$_md"
		return 1
	fi
	chelper_install_file "$_kd" "$_md/c_helper.so" || return 1
	touch "$_md" 2>/dev/null
	CHELPER_INSTALLED_FROM=cache
	chelper_log "installed the cached c_helper.so for source hash $_mh"
	return 0
}

chelper_curl() {
	# $1=output $2=url
	curl -fsSL --max-time 120 --retry 2 --retry-delay 5 -o "$1" "$2"
}

# From the package index into the cache, then installed. Supervisor only.
# $1=klipper checkout
chelper_fetch_index() {
	_kd="$1"
	_fh=$(chelper_source_hash "$_kd") || return 1
	_fid=$(chelper_abi_id)
	_furl=$(cat "$NEBULAOS_CHELPER_URL_FILE" 2>/dev/null)
	[ -n "$_fid" ] && [ -n "$_furl" ] || { chelper_err "no package index configured for c_helper.so"; return 1; }
	_fetch="${NEBULAOS_CHELPER_FETCH:-chelper_curl}"
	mkdir -p "$NEBULAOS_CHELPER_CACHE/$_fid" || return 1
	_fw="$NEBULAOS_CHELPER_CACHE/$_fid/.dl.$$"
	rm -rf "$_fw"; mkdir -p "$_fw" || return 1
	_ok=1
	if ! "$_fetch" "$_fw/index" "${_furl%/}/$_fid/index"; then
		chelper_err "could not read the c_helper.so index ${_furl%/}/$_fid/index"
	else
		_fsum=$(awk -v h="$_fh" '$1 == h { print $2; exit }' "$_fw/index")
		if [ -z "$_fsum" ]; then
			chelper_err "the package index has no c_helper.so for source hash $_fh (yet - the index builds daily)"
		elif ! "$_fetch" "$_fw/c_helper.so" "${_furl%/}/$_fid/$_fh/c_helper.so"; then
			chelper_err "downloading c_helper.so for $_fh failed"
		elif chelper_cache_put "$_fid" "$_fh" "$_fw/c_helper.so" "$_fsum"; then
			_ok=0
		fi
	fi
	rm -rf "$_fw"
	[ "$_ok" = 0 ] || return 1
	chelper_install_matching "$_kd" || return 1
	CHELPER_INSTALLED_FROM=index
	return 0
}

# Make the tree's library match its sources, if it does not already.
# $1=klipper checkout $2=cache|network ("network" only from the supervisor)
chelper_make_ready() {
	CHELPER_INSTALLED_FROM=
	chelper_check_mtime "$1" 2>/dev/null && return 0
	[ -d "$1/$NEBULAOS_CHELPER_SUBDIR" ] || return 1
	chelper_cache_seed_image
	chelper_install_matching "$1" && return 0
	[ "${2:-cache}" = network ] || return 1
	chelper_fetch_index "$1"
}
