#!/usr/bin/env bash
#
# Two independent release builds of one commit (the release workflow's build A
# and build B, separate runners) must be byte-identical:
#
#   scripts/release/compare-builds.sh <dir A> <dir B>
#
# Each dir holds what ci-build.sh produced: xImage, rootfs.squashfs,
# build-manifest.txt and .nebulaos-build-verified. xImage and rootfs.squashfs
# are compared byte for byte; the manifests must agree on every line except
# built_at (the wall clock of the build, not part of any artifact).
set -uo pipefail
export LC_ALL=C

A=${1:-}; B=${2:-}
[ -d "$A" ] && [ -d "$B" ] || { echo "usage: compare-builds.sh <dir A> <dir B>" >&2; exit 2; }

fail=0
for f in xImage rootfs.squashfs build-manifest.txt .nebulaos-build-verified; do
  for d in "$A" "$B"; do
    [ -f "$d/$f" ] || { echo "MISSING $d/$f"; fail=1; }
  done
done
[ "$fail" -eq 0 ] || { echo "BUILD_COMPARE=FAIL"; exit 1; }

for f in xImage rootfs.squashfs; do
  ha=$(sha256sum "$A/$f" | cut -d' ' -f1); hb=$(sha256sum "$B/$f" | cut -d' ' -f1)
  if [ "$ha" = "$hb" ]; then
    echo "SAME     $f $ha"
  else
    echo "DIFFERS  $f A=$ha B=$hb"; fail=1
  fi
done
if diff <(grep -v '^built_at=' "$A/build-manifest.txt") <(grep -v '^built_at=' "$B/build-manifest.txt"); then
  echo "SAME     build-manifest.txt (except built_at)"
else
  echo "DIFFERS  build-manifest.txt"; fail=1
fi
for k in SOURCE_HEAD BUILDER_DIGEST SOURCE_DATE_EPOCH; do
  va=$(grep -m1 "^$k=" "$A/.nebulaos-build-verified" | cut -d= -f2-)
  vb=$(grep -m1 "^$k=" "$B/.nebulaos-build-verified" | cut -d= -f2-)
  [ -n "$va" ] && [ "$va" = "$vb" ] || { echo "DIFFERS  attestation $k A=$va B=$vb"; fail=1; }
done
[ "$fail" -eq 0 ] && echo "BUILD_COMPARE=IDENTICAL" || echo "BUILD_COMPARE=FAIL"
exit "$fail"
