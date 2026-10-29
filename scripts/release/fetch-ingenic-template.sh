#!/usr/bin/env bash
#
# Download the pinned vendor .ingenic template (manifests/dependencies.conf
# INGENIC_TEMPLATE_*; a Git LFS object on GitHub) and verify size and sha256:
#
#   scripts/release/fetch-ingenic-template.sh <out dir>
#
# Prints INGENIC_TEMPLATE=<path> when the file is the pinned one.
set -euo pipefail

OUT=${1:?usage: fetch-ingenic-template.sh <out dir>}
FW=$(cd "$(dirname "$0")/../.." && pwd)
. "$FW/manifests/dependencies.conf"

repo=${INGENIC_TEMPLATE_REPO%.git}
case "$repo" in https://github.com/*) ;; *) echo "FATAL: template repo is not on github.com: $repo" >&2; exit 2 ;; esac
mkdir -p "$OUT"
dest="$OUT/$INGENIC_TEMPLATE_NAME"
if [ ! -f "$dest" ] || [ "$(sha256sum "$dest" | cut -d' ' -f1)" != "$INGENIC_TEMPLATE_SHA256" ]; then
  curl -fsSL --retry 3 -o "$dest.part" "$repo/raw/HEAD/$INGENIC_TEMPLATE_PATH"
  mv "$dest.part" "$dest"
fi
size=$(stat -c %s "$dest"); sum=$(sha256sum "$dest" | cut -d' ' -f1)
[ "$size" = "$INGENIC_TEMPLATE_SIZE" ] && [ "$sum" = "$INGENIC_TEMPLATE_SHA256" ] || {
  echo "FATAL: $dest is not the pinned template (size $size, sha256 $sum)" >&2; exit 1; }
echo "INGENIC_TEMPLATE=$dest"
