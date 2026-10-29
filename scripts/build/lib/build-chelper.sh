#!/bin/sh
# Klipper's compiled helper (klippy/chelper -> c_helper.so), cross-compiled.
# The ONE implementation of this recipe (G72, 2026-10-17): stage 04 builds
# the image's copy with it, export-sdk.sh puts it into the SDK, and the
# package index CI (NebulaOS-KE/nebulaos-packages) runs the SDK's copy to
# build the helpers for Klipper updates - so a helper from the index is
# built exactly like the one the image ships.
#
#   build-chelper.sh <klippy/chelper dir> <cross prefix> [<debug copy>]
#
# <cross prefix> e.g. /path/host/bin/mipsel-buildroot-linux-gnu- (gcc and
# strip are <prefix>gcc, <prefix>strip). Writes c_helper.so in the chelper
# directory; with <debug copy>, the unstripped library is copied there first.
#
# Upstream builds this library from klippy/chelper/__init__.py's own
# check_build_c_library(), with a hardcoded gcc invocation. So do exactly
# that, with the cross compiler substituted for `gcc` - and read SOURCE_FILES
# and COMPILE_ARGS OUT OF THAT FILE rather than restating them here. That is
# the whole point: a hardcoded list in the firmware would silently miss the
# next file upstream adds, and upstream has already added one (steppersync.c,
# flagged as unknown 5 in the analysis mission's section 27). If the list ever
# stops parsing, the build fails loudly instead of linking a library with a
# missing translation unit.
#
# SSE_FLAGS is deliberately not passed: upstream only adds it when
# check_gcc_option() says the compiler accepts it, and a mipsel cross compiler
# does not. Everything else - the -flto -fwhole-program link, -fPIC, -O2 - is
# byte-for-byte upstream's own recipe.
#
# Production optimization mission, Phase 6 (2026-07-30): the library is
# stripped with --strip-unneeded - Buildroot's own TARGET_FINALIZE strip pass
# never reaches it (it is not a Buildroot package).
#
# Needs a host python3 (for the ast read of the recipe).
set -eu
DIR=${1:?usage: build-chelper.sh <klippy/chelper dir> <cross prefix> [<debug copy>]}
PREFIX=${2:?usage: build-chelper.sh <klippy/chelper dir> <cross prefix> [<debug copy>]}
DEBUG_COPY=${3:-}

cd "$DIR"
rm -f c_helper.so _temp_c_helper.so

gcc_args=$(python3 - <<'PYEOF'
import ast, sys
tree = ast.parse(open('__init__.py').read())
found = {}
for node in tree.body:
    if (isinstance(node, ast.Assign) and len(node.targets) == 1
            and isinstance(node.targets[0], ast.Name)
            and node.targets[0].id in ('SOURCE_FILES', 'COMPILE_ARGS', 'DEST_LIB')):
        found[node.targets[0].id] = ast.literal_eval(node.value)
missing = {'SOURCE_FILES', 'COMPILE_ARGS', 'DEST_LIB'} - set(found)
if missing:
    sys.stderr.write("chelper/__init__.py no longer defines: %s\n"
                     % (', '.join(sorted(missing)),))
    raise SystemExit(1)
if found['DEST_LIB'] != 'c_helper.so':
    sys.stderr.write("chelper/__init__.py builds %s, not c_helper.so\n" % found['DEST_LIB'])
    raise SystemExit(1)
sys.stderr.write("   recipe from upstream: %s <- %d source files\n"
                 % (found['DEST_LIB'], len(found['SOURCE_FILES'])))
print(found['COMPILE_ARGS'] % (found['DEST_LIB'], ' '.join(found['SOURCE_FILES'])))
PYEOF
) || {
	echo "FATAL: could not read the chelper build recipe out of official Klipper's own klippy/chelper/__init__.py - upstream changed its shape and this step must be re-derived, not guessed" >&2
	exit 1
}

# shellcheck disable=SC2086  # gcc_args is upstream's own recipe, deliberately word-split
"${PREFIX}gcc" $gcc_args || {
	echo "FATAL: cross-compiling c_helper.so failed" >&2
	exit 1
}
[ -f c_helper.so ] || {
	echo "FATAL: c_helper.so was not produced" >&2
	exit 1
}
if [ -n "$DEBUG_COPY" ]; then
	mkdir -p "$(dirname "$DEBUG_COPY")"
	cp c_helper.so "$DEBUG_COPY"
fi
"${PREFIX}strip" --strip-unneeded c_helper.so
