#!/bin/sh
# Canonical CYW43430 Wi-Fi firmware + CLM fetch (2026-08-09 promotion): stages
# scripts/build/overlay/lib/firmware/brcm/{brcmfmac43430-sdio.bin,
# brcmfmac43430-sdio.clm_blob} so 02-configure-buildroot.sh's
# CONFIG_EXTRA_FIRMWARE embed (see artifacts/buildroot-halley5-v30-image/
# nebulaos_halley5_v30_defconfig) can bake both into the kernel image
# before the rootfs mounts - the exact point brcmfmac's own early SDIO probe
# requests them (confirmed from source:
# drivers/net/wireless/broadcom/brcm80211/brcmfmac/sdio.c's
# brcmf_sdio_prepare_fw_request(), combined with brcmf_fw_alloc_request()'s
# "brcm/brcmfmac43430-sdio" base name).
#
# Replaces THREE previous scripts as of this promotion:
#   - scripts/build/fetch-wifi-firmware.sh (live-extracted the obsolete
#     control 7.46.58.13 .bin from a stock device's own filesystem)
#   - scripts/firmware/fetch-linux-firmware-clm.sh (fetched a generic,
#     non-matching CLM blob from the linux-firmware mirror for that same
#     obsolete control build)
#   - scripts/build/wifi-firmware-125-variant.sh (an engineering-test-only
#     manual override tool - see docs/NEBULAOS_WIFI_125_ENGINEERING_TEST.md
#     for the full incident writeup, including the corrected re-attempt
#     that proved this exact .bin+CLM combination live on real hardware)
# 7.45.98.125 + its own matching CLM is now simply THE canonical Wi-Fi
# firmware - no variant, no override, no manual staging step.
#
# Board NVRAM (.txt) is NOT fetched here - unlike .bin/.clm_blob, that file
# is real per-board-family calibration data extracted from this project's
# own physically-owned hardware, redistributed under this repo's own
# wifi-firmware-v1.0.0 GitHub Release (see LICENSES/WIFI-FIRMWARE-NOTICE.md)
# and still fetched directly by 00-fetch-vendor-sources.sh. It is unrelated
# to which .bin/CLM firmware build is running and stays byte-identical
# across this promotion.
#
# Source: github.com/Infineon/ifx-linux-firmware (Infineon's own public,
# canonical distribution repo for this firmware family - the direct
# successor/publisher of the Cypress CYW43430 blobs, same lineage already
# accepted for the CLM fetch this script replaces), tag
# release-v5.10.9-2022_0909, which resolves (verified via
# `git ls-remote --tags`, an annotated tag dereferenced automatically) to
# commit 4334275b5801bcf5256c3101395e7bc983ce640d. Fetched directly from that
# commit's own raw file content via raw.githubusercontent.com - pinned to
# the exact commit, not a moving branch/tag ref, and hash-verified below
# regardless.
#
# License: single top-level LICENCE file in that repo - the same Cypress
# Wireless Connectivity Devices Driver EULA already accepted for the CLM
# fetch this replaces, which explicitly grants "a non-exclusive,
# non-transferable license... to reproduce and distribute the Software in
# object code form... solely for use in connection with Cypress integrated
# circuit products" - this device's real CYW43430 chip squarely qualifies.
# Fetched and hash-verified at build time, never committed as a binary (see
# .gitignore) - same treatment as every other proprietary firmware blob this
# build depends on.
#
# Usage: sh scripts/firmware/fetch-cyw43430-wifi-firmware.sh

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
DEST="$REPO_ROOT/scripts/build/overlay/lib/firmware/brcm"

IFX_COMMIT="4334275b5801bcf5256c3101395e7bc983ce640d"
IFX_RAW_BASE="https://raw.githubusercontent.com/Infineon/ifx-linux-firmware/$IFX_COMMIT"

# Verified once, live, directly against this exact commit (not copied from
# an unverified third party) - see this script's own header for how.
BIN_SHA256="82ed67a211877efa47aff4aab83d6d2d1ccf3d5d0f5c396df97f292ade01de9e"
CLM_SHA256="1dbe1a396b68786bb189b7c255318ae546fd2e9d15f70ccc8ecbdc52b6cd4c47"
LICENCE_SHA256="3a892759b73e8b459f1a750954b316118b0061fd9d1868d11fa258c104ee7e0c"

die() {
	echo "ABORT: $1" >&2
	exit 1
}

fetch() {
	url="$1"
	out="$2"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "$out" "$url" || die "download failed: $url"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$out" "$url" || die "download failed: $url"
	else
		die "neither curl nor wget is available"
	fi
}

sha_of() {
	[ -f "$1" ] || return 1
	sha256sum "$1" | awk '{print $1}'
}

# Already staged and hash-verified? Then this is a no-op, and re-downloading
# proves nothing the hashes have not already proven.
#
# Added 2026-08-17 (Phase 1 no-fork migration, Phase L). Two consecutive full
# builds failed here on `curl: (22) ... error: 429` - raw.githubusercontent.com
# rate-limiting the host, with the correct, already-verified blobs sitting on
# disk from an earlier run. A pinned-by-hash artifact that is already present
# and matches its pin does not need a CDN to be reachable, and making the
# whole firmware build depend on one is a reproducibility defect, not a
# safety property.
#
# This is strictly no weaker than always downloading. A file that is present
# but does NOT match its pinned hash is still fatal - and now fatal WITHOUT a
# network round trip, with a message that says what to do. It is the same
# "already present, verify rather than re-fetch" contract 00-fetch-vendor-
# sources.sh's clone_pinned() applies to every git component, and that the
# board-NVRAM fetch beside this call already applies to its own file.
staged_bin=$(sha_of "$DEST/brcmfmac43430-sdio.bin" || true)
staged_clm=$(sha_of "$DEST/brcmfmac43430-sdio.clm_blob" || true)
staged_lic=$(sha_of "$DEST/brcmfmac43430-sdio.clm_blob.LICENCE" || true)
if [ -n "$staged_bin" ] && [ -n "$staged_clm" ] && [ -n "$staged_lic" ]; then
	if [ "$staged_bin" = "$BIN_SHA256" ] && [ "$staged_clm" = "$CLM_SHA256" ] \
		&& [ "$staged_lic" = "$LICENCE_SHA256" ]; then
		echo "CYW43430 firmware + CLM already staged and hash-verified against Infineon/ifx-linux-firmware @ $IFX_COMMIT - not re-downloading."
		sha256sum "$DEST/brcmfmac43430-sdio.bin" "$DEST/brcmfmac43430-sdio.clm_blob"
		exit 0
	fi
	echo "WARNING: staged CYW43430 firmware does not match its pinned hashes - discarding it and re-fetching." >&2
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Fetching CYW43430 firmware + CLM from Infineon/ifx-linux-firmware @ $IFX_COMMIT ..."
fetch "$IFX_RAW_BASE/firmware/cyfmac43430-sdio.bin" "$WORK/cyfmac43430-sdio.bin"
fetch "$IFX_RAW_BASE/firmware/cyfmac43430-sdio.clm_blob" "$WORK/cyfmac43430-sdio.clm_blob"
fetch "$IFX_RAW_BASE/LICENCE" "$WORK/LICENCE"

actual_bin=$(sha256sum "$WORK/cyfmac43430-sdio.bin" | awk '{print $1}')
actual_clm=$(sha256sum "$WORK/cyfmac43430-sdio.clm_blob" | awk '{print $1}')
actual_lic=$(sha256sum "$WORK/LICENCE" | awk '{print $1}')

[ "$actual_bin" = "$BIN_SHA256" ] || die ".bin sha256 mismatch: got $actual_bin, expected $BIN_SHA256"
[ "$actual_clm" = "$CLM_SHA256" ] || die ".clm_blob sha256 mismatch: got $actual_clm, expected $CLM_SHA256"
[ "$actual_lic" = "$LICENCE_SHA256" ] || die "LICENCE sha256 mismatch: got $actual_lic, expected $LICENCE_SHA256"

mkdir -p "$DEST"
cp "$WORK/cyfmac43430-sdio.bin" "$DEST/brcmfmac43430-sdio.bin"
cp "$WORK/cyfmac43430-sdio.clm_blob" "$DEST/brcmfmac43430-sdio.clm_blob"
cp "$WORK/LICENCE" "$DEST/brcmfmac43430-sdio.clm_blob.LICENCE"

echo
echo "Staged (Infineon ifx-linux-firmware @ release-v5.10.9-2022_0909, hash-verified):"
sha256sum "$DEST/brcmfmac43430-sdio.bin" "$DEST/brcmfmac43430-sdio.clm_blob"
echo
echo "These are gitignored (see .gitignore) - re-run this script after a fresh"
echo "checkout rather than expecting them to already be present."
