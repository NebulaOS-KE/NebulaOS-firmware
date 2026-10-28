#!/bin/sh
# nebulaos-venv-lib.sh - shared persistent-venv compatibility helpers.
#
# Sourced by /etc/init.d/S04nebulaos-factory-seed (which owns creating and
# replacing these environments) and by /etc/init.d/S05nebulaos-activate (which
# only decides whether to bind-mount one). It deliberately lives in ONE place:
# two copies of an init-time predicate that must agree is the same hazard
# 02-configure-buildroot.sh documents at length for overlay files, where an
# older generation sorted first and silently won.
#
# Defines: venv_is_usable, recover_torn_venv, swap_venv_into_place,
# venv_validated_usable, venv_validation_key, venv_validation_reset.
#
# Callers may define log(); if they do not, a no-op stand-in is used so this
# file is safe to source from anywhere.
command -v log >/dev/null 2>&1 || log() { echo "nebulaos-venv: $1"; }

# NOTE ON VARIABLE NAMES: POSIX sh has no function-local scope, so every
# helper below uses its OWN distinct prefix (_vmp_, _rtv_, _svp_). This is not
# style. An earlier revision had all three using `_envdir`, so when
# recover_torn_venv() called venv_is_usable("$_envdir.old") the callee
# overwrote the caller's `_envdir`, and the subsequent `mv "$_envdir.old"`
# addressed "<env>.old.old" - silently failing to recover the one surviving
# copy of a user's environment. Caught by
# tests/venv-platform-migration-tests.sh, which is why that suite exercises
# these functions for real rather than reimplementing them.

# Buildroot 2025.02.18 / Python 3.12 migration (2026-09-27).
#
# Is this persistent venv actually USABLE?
#
# The old test was `[ -x "$envdir/bin/python3" ]`, which asks whether a file
# exists. That is not the same question, and it is the reason a half-created
# or torn environment was treated as finished: an interrupted provisioning run
# can leave bin/python3 in place while the environment behind it is
# incomplete, and the next boot would then skip provisioning entirely and hand
# the broken env to Klipper or Moonraker.
#
# This predicate requires the interpreter to exist, to be executable, to
# actually RUN, and the component's own imports to resolve. That is what makes
# provisioning idempotent (a finished env is detected as finished and left
# alone) and interruption-safe (an unfinished one is detected and redone).
#
# SCOPE NOTE - deliberately NOT a Python-version check.
#
# NebulaOS is unreleased and /usr/data/nebulaos is NebulaOS-owned; no deployed
# device carries a Python 3.11 venv that this image has to migrate, and stock
# firmware does not consume that path. So this release does not attempt
# 3.11 -> 3.12 migration and does not try to keep a venv working across an A/B
# pair with different interpreter minors.
#
# That WILL be needed at the first post-release Python ABI transition, because
# the storage lifetimes genuinely differ:
#
#   /usr/lib/python3.x    image-owned   per-slot     changes on firmware update
#   /usr/data/.../envs    persistent    slot-shared  survives update AND rollback
#
# A venv therefore outlives the interpreter it was built against, in both
# directions. The future requirement is recorded in
# docs/NEBULAOS_PLATFORM_APP_BOUNDARY.md; the hook for it is this function -
# comparing the venv's major.minor against the running /usr/bin/python3 here
# is sufficient, and the staging/swap/recovery machinery below already
# provides the safe replacement path it would need.
# G50 (2026-10-17): the image's Python ABI fingerprint (written by
# nebulaos-post-build.sh). Once update_manager installs ready-made packages
# from the NebulaOS package index into a venv, that venv holds compiled code
# for exactly this ABI - and the venv outlives the image (update AND
# rollback). A venv stamped for a different fingerprint is reprovisioned from
# the image seed; an unstamped one is stamped for the running image.
VENV_PYTHON_ABI="${VENV_PYTHON_ABI:-/usr/share/nebulaos/python-abi}"
venv_abi_id() {
	sed -n 's/^id=//p' "$VENV_PYTHON_ABI" 2>/dev/null | head -1
}

venv_is_usable() {
	_viu_dir="$1"; _viu_smoke="${2:-}"

	[ -d "$_viu_dir" ] || return 1
	[ -x "$_viu_dir/bin/python3" ] || return 1

	# A dangling symlink is not -x, but an env can also be torn in ways that
	# only surface on exec - so actually run it.
	"$_viu_dir/bin/python3" -c 'import sys' >/dev/null 2>&1 || {
		log "venv $_viu_dir has a bin/python3 that does not execute - reprovisioning"
		return 1
	}

	[ -f "$_viu_dir/pyvenv.cfg" ] || {
		log "venv $_viu_dir has no pyvenv.cfg - reprovisioning"
		return 1
	}

	_viu_abi=$(venv_abi_id)
	if [ -n "$_viu_abi" ] && [ -f "$_viu_dir/.nebulaos-abi" ]; then
		_viu_venv_abi=$(cat "$_viu_dir/.nebulaos-abi" 2>/dev/null)
		[ "$_viu_venv_abi" = "$_viu_abi" ] || {
			log "venv $_viu_dir was built for Python ABI '$_viu_venv_abi', this image is '$_viu_abi' - reprovisioning"
			return 1
		}
	fi

	if [ -n "$_viu_smoke" ]; then
		"$_viu_dir/bin/python3" -c "$_viu_smoke" >/dev/null 2>&1 || {
			log "venv $_viu_dir failed its import smoke test - reprovisioning"
			return 1
		}
	fi
	if [ -n "$_viu_abi" ] && [ ! -f "$_viu_dir/.nebulaos-abi" ]; then
		printf '%s\n' "$_viu_abi" > "$_viu_dir/.nebulaos-abi" 2>/dev/null \
			&& log "venv $_viu_dir stamped for Python ABI $_viu_abi"
	fi
	return 0
}

# Recover a torn replacement from a previous boot.
#
# The swap below is rename-based, so a power cut can leave "$envdir.old"
# holding the only real environment. The recovery trigger is deliberately NOT
# "$envdir is missing": S02nebulaos-namespace runs before this script and
# mkdir -p's envs/klipper and envs/moonraker, so $envdir is essentially always
# present - as an EMPTY directory after a torn swap. Testing for absence would
# therefore never fire, the old environment would sit in .old forever, and the
# component would fall back to bare /usr/bin/python3.
#
# So: recover when .old exists AND $envdir does not satisfy the platform
# predicate. An empty directory fails that trivially, as does a torn one.
recover_torn_venv() {
	_rtv_dir="$1"; _rtv_smoke="${2:-}"
	[ -d "$_rtv_dir.old" ] || return 0
	if venv_is_usable "$_rtv_dir" "$_rtv_smoke"; then
		# The swap completed; .old is just leftover garbage.
		rm -rf "$_rtv_dir.old" 2>/dev/null || true
		return 0
	fi
	if venv_is_usable "$_rtv_dir.old" "$_rtv_smoke"; then
		log "recovering $_rtv_dir from $_rtv_dir.old (previous replacement was interrupted)"
		rm -rf "$_rtv_dir" 2>/dev/null || true
		if mv "$_rtv_dir.old" "$_rtv_dir"; then
			log "recovered $_rtv_dir successfully"
		else
			log "ERROR: could not restore $_rtv_dir from $_rtv_dir.old - leaving .old in place for manual recovery"
		fi
	else
		log "$_rtv_dir.old exists but is not usable by this image either - discarding it and reseeding"
		rm -rf "$_rtv_dir.old" 2>/dev/null || true
	fi
}

# Swap a verified staging directory into place WITHOUT destroying the existing
# one first.
#
# This used to be `rm -rf "$envdir"; mv "$envdir.partial" "$envdir"`. Those two
# statements have a window between them in which the machine has NO
# environment at all, and a power cut there is unrecoverable - the old one is
# already gone and the new one is not yet in place. On a 3D printer that loses
# power mid-print this is a real failure mode, not a theoretical one.
#
# Rename the old one aside, move the new one in, then delete. Every
# intermediate state is recoverable by recover_torn_venv() above. The final
# delete is non-fatal on purpose: failing to remove a leftover directory must
# not fail a replacement that has already succeeded.
#
# DISK COST: none beyond what the previous implementation already paid. It is
# tempting to think holding <env>, <env>.old and <env>.partial at once needs a
# third copy's worth of space - it does not. All three are siblings in
# /usr/data/nebulaos/envs, so `mv` is a rename within one filesystem, not a
# copy. Peak usage is <env> plus <env>.partial, which is exactly what the old
# `rm -rf <env>; mv <env>.partial <env>` sequence also held at its peak, since
# .partial was fully populated before the rm. A venv here measures ~25MB
# (04-cross-compile-app-stack.sh records the figure), so this is ~50MB peak
# per component either way, unchanged by this fix.
swap_venv_into_place() {
	_svp_dir="$1"
	# BOOT-03: a replaced environment is never vouched for by an old stamp.
	rm -f "$VENV_VALIDATION_DIR/${_svp_dir##*/}.key" 2>/dev/null || true
	rm -rf "$_svp_dir.old" 2>/dev/null || true
	if [ -e "$_svp_dir" ]; then
		if ! mv "$_svp_dir" "$_svp_dir.old"; then
			log "ERROR: could not move $_svp_dir aside - refusing to replace it, leaving the existing environment untouched"
			rm -rf "$_svp_dir.partial" 2>/dev/null || true
			return 1
		fi
	fi
	if ! mv "$_svp_dir.partial" "$_svp_dir"; then
		log "ERROR: could not move $_svp_dir.partial into place - restoring the previous environment"
		[ -d "$_svp_dir.old" ] && mv "$_svp_dir.old" "$_svp_dir"
		return 1
	fi
	rm -rf "$_svp_dir.old" 2>/dev/null || true
	return 0
}


# BOOT-03/BOOT-04 (2026-10-05): validation stamp.
#
# venv_is_usable() starts the venv's interpreter and imports the component's
# packages: 5.4 s (moonraker) + 3.1 s (klipper) cold on the X2000, and S05
# repeated the klipper one (2.6 s) - about 11 s of every normal boot spent
# re-proving an environment nothing has touched. venv_validated_usable()
# runs that full check only when something that could change its answer has
# changed since the last check that PASSED:
#
#   the image          seed-manifest.json checksum (a new image is a new
#                      generation) and the system interpreter's identity
#   the environment    pyvenv.cfg checksum, the bin/python3 link, the
#                      site-packages listing (installs, removals, upgrades
#                      change dist-info entries, sizes or times), and whether
#                      a torn-swap "<env>.old" exists (recovery pending)
#   the question       the smoke-test import list itself
#
# Not the app checkouts (G103 P3, Run 21): the check runs the venv's own
# interpreter on a fixed import list, so an app's git HEAD cannot change its
# answer, and whatever an app update installs shows in the site-packages
# listing. With the HEADs in the key, every Klipper/extensions/Moonraker
# update cost the next boot both full checks (4.8-7.5 s on ke-dev).
#
# The key is written to the stamp only after venv_is_usable() succeeded, and
# the stamp is deleted when it fails, so a stamp can never vouch for an
# environment that last failed. A missing, unreadable or different stamp
# means the full check. Deleting the stamp directory (factory reset wipes it
# with the namespace; venv_validation_reset() and the one-shot
# maintenance/revalidate-venvs marker do it explicitly) forces full checks.
# The key is built from cat/ls/cksum only: no interpreter start.
#
# One stamp per environment, shared by S04 (factory seed) and S05 (activate):
# whichever runs the full check first records it, the other reuses it.
VENV_VALIDATION_DIR="${VENV_VALIDATION_DIR:-${SYSTEM:-${NEBULAOS_ROOT:-/usr/data/nebulaos}/system}/venv-validation}"
VENV_REVALIDATE_MARKER="${VENV_REVALIDATE_MARKER:-${NEBULAOS_ROOT:-/usr/data/nebulaos}/maintenance/revalidate-venvs}"
VENV_SYSTEM_PYTHON="${VENV_SYSTEM_PYTHON:-/usr/bin/python3}"
VENV_IMAGE_MANIFEST="${VENV_IMAGE_MANIFEST:-${SEEDS:-/opt/nebulaos-seeds}/seed-manifest.json}"

# The identity key for <envdir> <smoke> on stdout.
venv_validation_key() {
	_vvk_d="$1"
	echo "v2"
	echo "smoke=$2"
	echo "image=$(cksum < "$VENV_IMAGE_MANIFEST" 2>/dev/null)"
	echo "python=$(ls -lnL "$VENV_SYSTEM_PYTHON" 2>/dev/null)"
	echo "env=$_vvk_d"
	echo "bin=$(ls -ln "$_vvk_d/bin/python3" 2>/dev/null)"
	echo "cfg=$(cksum < "$_vvk_d/pyvenv.cfg" 2>/dev/null)"
	echo "abi=$(venv_abi_id) venv=$(cat "$_vvk_d/.nebulaos-abi" 2>/dev/null)"
	for _vvk_sp in "$_vvk_d"/lib/python*/site-packages; do
		[ -d "$_vvk_sp" ] || continue
		echo "sp=$_vvk_sp $(ls -lna "$_vvk_sp" 2>/dev/null | cksum)"
	done
	[ -e "$_vvk_d.old" ] && echo "old=present"
}

_venv_stamp_path() {
	echo "$VENV_VALIDATION_DIR/${1##*/}.key"
}

# Forget every stamp: the next check of every environment is a full one.
venv_validation_reset() {
	rm -rf "$VENV_VALIDATION_DIR" 2>/dev/null || true
}

# venv_is_usable() with a trusted fast path; same arguments, same meaning.
# VENV_VALIDATION_SOURCE is set to "stamp" or "full" on success.
venv_validated_usable() {
	_vvu_d="$1"; _vvu_s="${2:-}"
	VENV_VALIDATION_SOURCE=
	[ -d "$_vvu_d" ] || return 1
	_vvu_stamp=$(_venv_stamp_path "$_vvu_d")
	_vvu_key=$(venv_validation_key "$_vvu_d" "$_vvu_s")
	if [ ! -e "$VENV_REVALIDATE_MARKER" ] && [ -f "$_vvu_stamp" ] \
		&& [ "$(cat "$_vvu_stamp" 2>/dev/null)" = "$_vvu_key" ]; then
		VENV_VALIDATION_SOURCE=stamp
		log "venv $_vvu_d unchanged since its last full validation - import check skipped"
		return 0
	fi
	if venv_is_usable "$_vvu_d" "$_vvu_s"; then
		VENV_VALIDATION_SOURCE=full
		if mkdir -p "$VENV_VALIDATION_DIR" 2>/dev/null \
			&& printf '%s\n' "$_vvu_key" > "$_vvu_stamp.tmp" 2>/dev/null \
			&& mv -f "$_vvu_stamp.tmp" "$_vvu_stamp" 2>/dev/null; then
			:
		else
			rm -f "$_vvu_stamp.tmp" 2>/dev/null
		fi
		return 0
	fi
	rm -f "$_vvu_stamp" "$_vvu_stamp.tmp" 2>/dev/null
	return 1
}
