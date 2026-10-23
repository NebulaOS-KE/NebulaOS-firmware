#!/bin/sh
#
# Shared reader for /opt/nebulaos-seeds/seed-manifest.json, sourced by both
# S04nebulaos-factory-seed and S04nebulaos-migrate.
#
# WHY THIS EXISTS. The seed archives are produced by the build with each
# component's local branch forced to a specific name
# (scripts/build/lib/make-seed-archive.sh: `git checkout -q -B "$active_branch"`),
# and the on-device seeding functions then ASSERT that name before accepting
# the extracted checkout. For the extension set that name is
# $KLIPPER_EXTENSIONS_BRANCH - "production", the deployed-runtime branch -
# while the three on-device call sites hardcoded the literal "main", which is
# the DEVELOPMENT branch. The assertion compares branch NAMES, so commit
# equality between main and production never masked it: every seed was
# rejected, the extensions app directory was never created, no app generation
# was ever recorded, and every subsequent boot re-ran a full migration.
# (Audit finding F-06.)
#
# The fix is not to re-hardcode the currently-correct literal in three places.
# That is the same drift class, re-armed. The image already ships the
# authoritative answer as DATA: 04-cross-compile-app-stack.sh writes
# "branch": "$KLIPPER_EXTENSIONS_BRANCH" into the per-component object of
# seed-manifest.json, from the same variable that drives make_seed_archive, in
# the same build run, into the same immutable /opt/nebulaos-seeds directory as
# the archive itself. Manifest/archive drift is therefore structurally
# impossible, and the branch assertion keeps doing its real job: proving the
# extraction produced the archive that shipped, not proving which branch the
# build chose.
#
# The build's branch CHOICE is asserted separately and at the right layer, in
# source, by tests/extensions-updater-branch-strategy-tests.sh and
# tests/recovery-safety-tests.sh - not on a device after shipping.
#
# Extracted into a shared file rather than duplicated, for the same reason
# maintenance_gate_ok() was (see $GATE_LIB): the identical logic living in two
# places in these two scripts is exactly how a real bug ended up needing the
# identical fix twice.

# Print the "branch" value from one component object of a seed manifest.
#
# Deliberately BLOCK-SCOPED. A flat key grep (S04nebulaos-migrate's own
# json_get(), which takes `head -1`) would return the FIRST "branch" in the
# file - klipper's "master" - for every component asked about. That collision
# is the most likely way to get this wrong, so it is tested directly in
# tests/extensions-branch-contract-tests.sh.
#
# Usage: seed_manifest_branch <manifest-path> <component-name>
# Prints the branch on success; prints nothing and returns 1 on any failure.
seed_manifest_branch() {
	seed_manifest_field "$1" "$2" branch
}

# The same block-scoped read for any flat string key of one component
# (G91 S05 boot guard: "seed_commit", the image's pin).
# Usage: seed_manifest_field <manifest-path> <component-name> <key>
seed_manifest_field() {
	_smb_file="$1"
	_smb_component="$2"
	_smb_key="$3"
	[ -n "$_smb_file" ] && [ -f "$_smb_file" ] || return 1
	[ -n "$_smb_component" ] && [ -n "$_smb_key" ] || return 1

	_smb_value=$(awk -v want="$_smb_component" -v key="$_smb_key" '
		{
			line = $0
			if (depth == 0) {
				# Not inside the component object yet. Enter only on the
				# line that both names it and opens its object, and drop
				# everything up to that brace so a single-line object is
				# handled by exactly the same rules as a multi-line one.
				if (index(line, "\"" want "\"") == 0) next
				b = index(line, "{")
				if (b == 0) next
				depth = 1
				line = substr(line, b + 1)
			}
			if (match(line, "\"" key "\"[ \t]*:[ \t]*\"[^\"]*\"")) {
				found = substr(line, RSTART, RLENGTH)
				sub("^\"" key "\"[ \t]*:[ \t]*\"", "", found)
				sub(/".*/, "", found)
				print found
				exit
			}
			# Closing brace before the key: this component has none.
			if (index(line, "}")) exit
		}
	' "$_smb_file" 2>/dev/null)

	[ -n "$_smb_value" ] || return 1
	printf '%s\n' "$_smb_value"
}
