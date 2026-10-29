# Where the pieces we don't build ourselves come from

This tracks every prebuilt or downloaded binary the build pulls in that isn't compiled from source
in this repo — things like Mainsail's release zip or the WiFi firmware blobs. For each one, you'll
find the exact path, size, SHA-256, where it actually comes from, and — where we can't fully
reconstruct it from upstream — an honest "here's the limitation" instead of pretending it's more
verifiable than it is.

## Mainsail release archive

| Field | Value |
|---|---|
| Path | `vendor/mainsail-dist/mainsail.zip` (gitignored, fetched by `scripts/build/00-fetch-vendor-sources.sh`) |
| Size | 3,133,520 bytes |
| SHA-256 | `df2ba7c301f7bfc8ac9f122741a6ba08356d679ecfa1f62f898d0337802d5de5` |
| Version | `v2.18.2` (confirmed from the archive's own internal `.version` file, not assumed) |
| Origin | `https://github.com/mainsail-crew/mainsail/releases/download/v2.18.2/mainsail.zip` — a real, official GitHub release asset from the `mainsail-crew/mainsail` project |
| Reconstruction | Fully reconstructable — download the same tagged release asset from the URL above and verify the SHA-256 matches. **This was previously not pinned at all** — the fetch script downloaded from `.../releases/latest/...`, a URL that silently follows whatever GitHub considers "latest" at fetch time. Fixed 2026-07-31 to pin the exact tag and verify the downloaded archive's hash, failing loudly on either a wrong tag or a byte-different artifact under that tag. |

## GuppyScreen binaries

| Field | Value |
|---|---|
| Path | `artifacts/guppyscreen-mips/guppyscreen`, `artifacts/guppyscreen-mips/guppybeep` (git-tracked, but now a build-time-overwritten snapshot, not the source of truth) |
| Origin (pre-2026-08-07) | Prebuilt MIPS binaries with no fetch-script entry, no declared source commit, no download URL anywhere in this repo. |
| Origin (2026-08-07+) | **Fixed.** `GUPPYSCREEN_REPO`/`GUPPYSCREEN_PIN` in `manifests/dependencies.conf` pin the exact source commit (`coreflake1/NebulaOS-guppyscreen`); `00-fetch-vendor-sources.sh` clones and pin-verifies it, `04-cross-compile-app-stack.sh` cross-builds it for MIPS and overwrites these two tracked files with the freshly-built, freshly-stripped result every build. The old hashes above are a historical snapshot only — a real build produces different (but source-traceable) bytes; `05-final-build.sh`'s manifest records both the source commit (`git_commit_guppyscreen`) and the resulting binary hash (`guppyscreen_sha256`/`guppybeep_sha256`) so the two are never ambiguous. |
| Toolchain (pre-2026-08-15) | Built via the standalone `ghcr.io/coreflake1/guppydev` container. |
| Toolchain (2026-08-15+) | Now builds inside the same unified, digest-pinned `ghcr.io/nebulaos-ke/nebulaos-build` image every other build stage uses (`manifests/dependencies.conf`'s `BUILD_IMAGE_REPO`/`BUILD_IMAGE_DIGEST`) — it's the same Bootlin `mips32el--musl` toolchain `guppydev` provided, just living on a non-default `PATH` entry (`GUPPYSCREEN_TOOLCHAIN_BIN`) instead of a separate container. See `docs/NEBULAOS_BUILD_ENVIRONMENT.md`. |
| Reconstruction | Fully reconstructable from source as of 2026-08-07 — no longer the least-reproducible artifact in the build. |

## Wi-Fi firmware and calibration

| Field | Value |
|---|---|
| Path | `scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.bin` (gitignored — see `.gitignore`) |
| Size | 406,602 bytes |
| SHA-256 | `60dbb5b77b2c232e513322e0ff4350ab5dab5a9fcad0e26e80a2f089e652d720` |
| Path | `scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.txt` (gitignored; NVRAM/board-calibration override) |
| Size | 962 bytes |
| SHA-256 | `78fee458ab69c0a66ea462f6d6769e15b36f73582693f4dbb5a0e8e8be3cfb0a` |
| Origin | Confirmed (`docs/NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md` §18.3, citing FIRMWARE.md §57) SHA-256-identical to the real stock device's own board-calibrated firmware (`cyw43438-7.46.58.13.bin`) and NVRAM (`nvram_azw372.txt`, board id `BCM943430WLSELG`), extracted directly from the physical printer and renamed to mainline `brcmfmac`'s own naming convention. Real, board-specific, not a generic/mismatched file. |
| Reconstruction | Fully reconstructable — 2026-08-07: redistribution explicitly authorized (see `LICENSES/WIFI-FIRMWARE-NOTICE.md`), published as the `wifi-firmware-v1.0.0` GitHub Release asset on this repo, downloaded and hash-verified automatically by `00-fetch-vendor-sources.sh`. No manual per-machine extraction needed (the live-extraction tool that originally produced this file has since been removed - see `LICENSES/WIFI-FIRMWARE-NOTICE.md`'s "History" section). Unrelated to which WiFi `.bin`/CLM firmware is running - see the entry below for that. |

## CYW43430 WiFi firmware + CLM (7.45.98.125)

| Field | Value |
|---|---|
| Path | `scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.bin` / `brcmfmac43430-sdio.clm_blob` (both gitignored) |
| SHA-256 | `.bin`: `82ed67a211877efa47aff4aab83d6d2d1ccf3d5d0f5c396df97f292ade01de9e` · `.clm_blob`: `1dbe1a396b68786bb189b7c255318ae546fd2e9d15f70ccc8ecbdc52b6cd4c47` |
| Origin | Infineon's own public upstream repo (`github.com/Infineon/ifx-linux-firmware`, tag `release-v5.10.9-2022_0909`), not this project's own hardware - promoted 2026-08-09 after hardware qualification (see `docs/NEBULAOS_WIFI_125_ENGINEERING_TEST.md`), replacing the previous, device-extracted `7.46.58.13` control firmware. |
| Reconstruction | Fully reconstructable, automatically — `scripts/firmware/fetch-cyw43430-wifi-firmware.sh` fetches and hash-verifies both files directly from the pinned upstream commit on every build. See `LICENSES/WIFI-FIRMWARE-NOTICE.md` for the license basis. |

## Regulatory database

| Field | Value |
|---|---|
| Path | `scripts/build/overlay/lib/firmware/regulatory.db` (gitignored — see `.gitignore`) |
| Size | 4,896 bytes |
| SHA-256 | `0a4abd7ae20d07bb70642937ccb2293a72a6504730eea45a698882599f586368` |
| Path | `scripts/build/overlay/lib/firmware/regulatory.db.p7s` (gitignored, detached signature) |
| Size | 1,182 bytes |
| SHA-256 | `bcd81aed039ea6b9b6f3726fbf26911a0caf4a5d894210e0fa2effb384d6b326` |
| Origin | `wireless-regdb` project's signed regulatory database, baked into the kernel image via `CONFIG_EXTRA_FIRMWARE` (see `halley5-nebulaos-fragment.config`'s own dated comment for why — a rootfs-not-yet-mounted boot timing fix). |
| Reconstruction | Fully reconstructable — fetched and hash-verified automatically by `scripts/firmware/fetch-wireless-regdb.sh` (called from `00-fetch-vendor-sources.sh` since 2026-08-07), not committed directly for the same reviewable-diff-not-binary-swap reasoning as the WiFi firmware above. `wireless-regdb` is itself an actively-maintained public project if a newer database is ever needed. |

## Verification

Every hash above is checked by `scripts/build/06-verify.sh`'s
`check_artifact_sha256()` gate (added alongside the existing
`check_vendor_pin()` vendor-source gate), so a drifted or substituted
artifact shows as an explicit `MISS` line in a build's verification output,
not a silent difference only this document would reveal.

## Orphaned vendor tree resolution (2026-07-31)

Two gitignored `vendor/` trees had no fetch-script provenance and were
flagged as candidates for either removal or documented retention:

- **`vendor/x2000_kernel`** (Jubian540/x2000_kernel, the real stock 4.4.94
  kernel SDK, distinct from the custom image's `x2000_kernel_6.6`) —
  **retained**. Confirmed via `README.md:176`, `FIRMWARE.md` (multiple
  sections, e.g. line 120, 251-287, 377, 578), and
  `docs/PIN_OWNERSHIP_MAP.md:221` that this tree has real, ongoing reference
  value: it was used to cross-compile a real stock-vermagic-matching kernel
  module (`ax88179_178a`/USB Ethernet), to confirm the exact stock kernel
  version (`4.4.94`), and as a generic reference-tree search target during
  pin-conflict investigations. Not consumed by the numbered `00`-`06` build
  pipeline for the custom image, but genuinely useful and already documented
  elsewhere — correcting this project's own earlier, too-hasty
  characterization of it as "likely a stale leftover" in
  `NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md`'s original vendor-pin audit.
- **`vendor/mainsail`** (a plain git clone of `mainsail-crew/mainsail`,
  distinct from the actually-used `mainsail-dist/mainsail.zip` release
  archive) — **removed**. Confirmed via a repo-wide grep that nothing
  anywhere (build scripts or documentation) ever referenced this tree by
  path; it was a clean, unmodified, trivially re-clonable mirror (8.9 MB,
  zero local changes) with no unique content. Deleted 2026-07-31; re-clone
  from `https://github.com/mainsail-crew/mainsail` if a source-level Mainsail
  reference is ever genuinely needed again.
