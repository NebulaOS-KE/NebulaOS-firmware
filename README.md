# NebulaOS Firmware

> Part of [NebulaOS](https://github.com/NebulaOS-KE/NebulaOS): open firmware for the Creality Ender-3 V3 KE. The project map, releases and downloads are there.

NebulaOS is custom firmware for the Creality Ender-3 V3 KE. This repository builds it: it pins
every input, fetches them, and produces the kernel and root filesystem that go onto the printer.

Current version: **0.9.0** (`NEBULAOS_VERSION` in
[`manifests/dependencies.conf`](manifests/dependencies.conf)).

## What ships in the image

| Component | Source | Notes |
|---|---|---|
| Base system | [Buildroot](https://github.com/buildroot/buildroot) 2025.02 (tag 2025.02.18, pinned by commit) | NebulaOS configuration lives in [`br2-external/`](br2-external/) |
| Kernel | [`NebulaOS-KE/NebulaOS-kernel`](https://github.com/NebulaOS-KE/NebulaOS-kernel), branch `openke` | Linux 6.6 with PREEMPT_RT. Every kernel change is a commit in that repository; nothing is patched at build time |
| Klipper (host) | [`Klipper3d/klipper`](https://github.com/Klipper3d/klipper) | Pristine upstream, pinned by commit, zero core patches |
| Klipper extensions | [`NebulaOS-KE/NebulaOS-klipper-extensions`](https://github.com/NebulaOS-KE/NebulaOS-klipper-extensions), branch `production` | NebulaOS's own Klipper extras, composed into Klipper at boot by symlink (see below) |
| Moonraker | [`Arksine/moonraker`](https://github.com/Arksine/moonraker) | Upstream, plus one allowlisted build-time patch (`scripts/build/patches/moonraker-sqlite-nolock.patch`) applied to the image copy only |
| Mainsail | Release `v2.18.2` | Checksum-pinned release archive |
| Screen app | [`NebulaOS-KE/NebulaOS-nebulascreen`](https://github.com/NebulaOS-KE/NebulaOS-nebulascreen) | NebulaScreen, the touchscreen app (based on GuppyScreen; repo renamed from `NebulaOS-guppyscreen` 2026-10-24, the old URL redirects). Built into the image from `NEBULASCREEN_PIN`, and updatable on its own from its stable GitHub releases through Moonraker (`[update_manager nebulascreen]`, type `zip`) |
| MCU firmware | `NebulaOS-KE/NebulaOS-klipper-mcu` | Native Klipper build for the mainboard's GD32F303, vendored as a binary with a provenance sidecar in `scripts/build/overlay/opt/nebulaos/mcu-candidates/` |

The exact commit, tag or digest of every input — including the build container, Wi-Fi firmware
and the tools used for USB recovery — is in `manifests/dependencies.conf`. That file is the only
place pins live. `REPOSITORY_HEAD != SHIPPING_PIN`: the image ships what the manifest pins, not
whatever the tip of each repository happens to be.

### No Klipper fork

The host runs an unmodified `Klipper3d/klipper` checkout. At boot,
`/etc/nebulaos-klipper-compose.sh` symlinks each module listed in the extensions repository's
`nebulaos-extensions.json` into `klippy/extras/` and lists the links in the Klipper clone's
`.git/info/exclude`, so both checkouts stay clean in `git status` and Moonraker sees a normal
upstream repository. A regular file at a managed path (for example, upstream adopting a module of
the same name) is a hard error, not something to overwrite. `[nebulaos_compat]` then checks the
manifest and the required Klipper symbols inside Klippy and refuses to start if they don't match.
Details: [`docs/NEBULAOS_KLIPPER_COMPOSITION.md`](docs/NEBULAOS_KLIPPER_COMPOSITION.md).

The old `coreflake1/NebulaOS-klipper` fork is retired. It is not a build input or a dependency.

## A/B slots

The KE's eMMC has two fixed system slots (kernel + rootfs each) and one shared boot marker:

```
slot A: mmcblk0p5 kernel   + mmcblk0p7 rootfs
slot B: mmcblk0p6 kernel2  + mmcblk0p8 rootfs2
mmcblk0p1  OTA boot marker (selects the slot)
mmcblk0p9  rootfs_data     (shared)
mmcblk0p10 userdata, mounted at /usr/data (shared, persistent)
```

The usual setup is NebulaOS in one slot and Creality's stock firmware kept in the other as the
way back. Since 2026-10-14 NebulaOS may also occupy both slots: an install always writes the slot
that is **not** running and then points the marker at it, so nothing may assume which slot holds
what. The rootfs is a read-only squashfs. NebulaOS never switches to stock automatically,
because booting Creality's firmware reflashes the mainboard with Creality's MCU firmware
(`S00revert-safety`). Details: [`docs/A_B_SLOT_MODEL.md`](docs/A_B_SLOT_MODEL.md),
[`docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md`](docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md).

## Persistent data

`/usr/data` is one ext4 partition shared by both slots and by stock. NebulaOS writes only under
its own namespace, `/usr/data/nebulaos/`:

- `apps/` — Klipper, the extensions and Moonraker as git checkouts, plus Mainsail's web files
  (seeded on first boot from the image, then updatable), with `envs/` holding the Python
  virtualenvs
- `printer_data/` — config, logs, database (bind-mounted at `/opt/printer_data`)
- `system/`, `updates/`, `backups/` — state, update staging/locks and rollback copies

The one shared exception is `/usr/data/printer_data/gcodes/`, the stock G-code location, so print
files are visible from both systems. Machine/platform configuration is image-owned (under
`/etc/nebulaos/` on the rootfs), so it always matches the slot that booted. Boot is a sequence of
`S*` init scripts in `scripts/build/overlay/etc/init.d/` (persistent datastore, namespace,
first-boot seed and migration, activation/composition, MCU guard, Klipper, Moonraker, the screen
app, the update supervisor). Details:
[`docs/NEBULAOS_PERSISTENT_NAMESPACE.md`](docs/NEBULAOS_PERSISTENT_NAMESPACE.md).

## Updates

**Klipper, Moonraker, Mainsail and the extensions** update through Moonraker's `update_manager`
(the Update page in Mainsail). Klipper and the extensions are validated together as a pair.
`/etc/nebulaos-update-supervisor.sh` (`S59nebulaos-update-supervisor`) notices a changed commit,
recomposes the extensions, health-checks the result and rolls back to the last known-good commit
(including Moonraker's virtualenv) if it fails. It never restarts a service during a print.
Details: [`docs/NEBULAOS_UPDATE_OWNERSHIP.md`](docs/NEBULAOS_UPDATE_OWNERSHIP.md).

**System images** (kernel, OS, screen app) are installed on the printer from the screen's
**System image** page, using `nebulaos-osconfig image`. The `.img` file can come from a USB stick
or be uploaded through Mainsail (`config/uploads/system-image`). The install checks the package's
integrity, writes the inactive slot, reads it back and switches the marker. The new slot then
boots as a trial: `S99nebulaos-image-trial` confirms it once Klipper and the screen are up, or
switches back once. A kernel that doesn't start at all needs USB recovery
(`tools/recovery/nebulaos-usb.py`, or the `.ingenic` package via the Ingenic Cloner).
Details: [`docs/RELEASE_ARTIFACTS.md`](docs/RELEASE_ARTIFACTS.md),
[`docs/DEVELOPER_RECOVERY.md`](docs/DEVELOPER_RECOVERY.md).

**Over the internet** (G79): System image > Online asks the latest release of
[`NebulaOS-KE/NebulaOS`](https://github.com/NebulaOS-KE/NebulaOS/releases) for a newer version
(`nebulaos-osconfig ota check`), downloads the `.img` over HTTPS from github.com only and keeps it
when its size and sha256 match the release record (`ota download`); it is then installed like any
other image (source `ota/`). There is no signing key: trust is GitHub's HTTPS plus the checksum.
Releases are built by that repository's release workflow from `scripts/release/` here.

## Building

In the NebulaOS workspace, use the build launcher with the full 40-character firmware commit:

```sh
tools/run-nebulaos-build.sh <sha>               # DEV build (default)
tools/run-nebulaos-build.sh --candidate <sha>   # release-grade, explicit only
NebulaOS-firmware/tools/product-inputs.py current-build   # is an existing build still current?
```

The launcher clones the commit into a separate build workspace, runs `build.sh` there and writes
the build record (`.nebulaos-build-verified`) that the Hardware Agent installs from.

`build.sh` on its own works from a plain clone. It needs only Docker or Podman. It runs the whole
pipeline in one digest-pinned build container (`BUILD_IMAGE_DIGEST`), using
`scripts/build/build-qualified-baseline.sh` to run these steps in order:

```
00-fetch-vendor-sources.sh     fetch every pinned source, fail on any unresolvable pin
assert-baseline-config.sh      pre-build check of the kernel checkout
01-apply-kernel-patches.sh     verify the kernel changes are present (nothing is applied)
02-configure-buildroot.sh      Buildroot config, br2-external, rootfs overlay
03-build-kernel-and-rootfs.sh  kernel + base rootfs
04-cross-compile-app-stack.sh  chelper, Moonraker, ustreamer, Mainsail, screen app, wheels
05-final-build.sh              final rootfs.squashfs + build-manifest.txt
06-verify.sh                   check the image contents and architecture against the pins
assert-baseline-config.sh      post-build check of the resolved artifacts
```

`./build.sh` is a DEV build: it reuses the download cache and ccache. `./build.sh --release` turns
ccache off. `SOURCE_DATE_EPOCH` comes from the firmware commit. Outputs land in
`artifacts/buildroot-halley5-v30-image/`. `scripts/package/package-release.sh` then packages one
built core three ways: the native `xImage` + `rootfs.squashfs`, a Creality-format `.img` and an
Ingenic Cloner `.ingenic`.

Reproducibility and attestation: the root causes of image non-determinism have been found and
fixed, but byte-identical images from two clean builds of the same HEAD are **not yet claimed**
here — see [`docs/REPRODUCIBILITY.md`](docs/REPRODUCIBILITY.md) for what is and isn't established.
`tools/attest/attest-build-run.sh` adds an HMAC-authenticated (v2) attestation to a finished build.
[`docs/BUILD_PROVENANCE.md`](docs/BUILD_PROVENANCE.md) explains how to identify what produced an
image.

Building the kernel, extensions or screen-app repository on its own does not produce a printer
image; only this repository puts them together.

## Repository layout

```
build.sh            entry point (runs the pipeline in the pinned container)
manifests/          dependencies.conf - the one pin manifest
scripts/build/      pipeline stages 00-06, baseline assertions, rootfs overlay (overlay/)
scripts/package/    .img / .ingenic packaging and validation
scripts/            also: firmware fetchers, parity/QA helpers, release.sh, flash-spare-slot.sh
br2-external/       Buildroot external tree (defconfig, board files, packages)
build-env/          Dockerfile of the build container
tools/              hardware agent, attestation, eMMC layout, USB recovery, SDK, qualification,
                    workspace-control (canonical copies of the workspace's AGENTS.md, launchers)
tests/              offline test suites
docs/               design and operations docs (see below)
artifacts/          tracked build reference files (configs, manifests); build output lands here
reference/          reference sources from the stock firmware, kept for analysis
patches/            patch for the pinned ingenic-usbboot tool
LICENSES/           third-party notices (Wi-Fi firmware)
```

`vendor/`, `vendor-downloads/` and `build-work/` are created by the build and are not tracked.

## Tests

`tests/` holds offline suites: around a hundred POSIX shell scripts and a set of Python ones. They
use temporary fixtures and fakes, and never touch a printer or the network. Run one from the
repository root:

```sh
sh tests/klipper-composition-tests.sh
python3 tests/nebulaos-osconfig-tests.py
```

Each suite's header says what it covers. There is no single aggregate runner. The workspace's
`tools/verify-architecture.sh` checks the architecture invariants (pristine upstream Klipper,
production-branch extensions, pin resolvability, etc.).

## Docs that match the current code

- [`docs/A_B_SLOT_MODEL.md`](docs/A_B_SLOT_MODEL.md) — slots, marker, partitions
- [`docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md`](docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md) — switching between slots
- [`docs/DEVELOPER_RECOVERY.md`](docs/DEVELOPER_RECOVERY.md) — recovery
- [`docs/HARDWARE_AGENT.md`](docs/HARDWARE_AGENT.md) — developer installs onto an enrolled printer
- [`docs/NEBULAOS_KLIPPER_COMPOSITION.md`](docs/NEBULAOS_KLIPPER_COMPOSITION.md) — pristine Klipper + extensions at runtime
- [`docs/NEBULAOS_EXTENSIONS_BRANCH_STRATEGY.md`](docs/NEBULAOS_EXTENSIONS_BRANCH_STRATEGY.md) — `main` vs `production`
- [`docs/NEBULAOS_UPDATE_OWNERSHIP.md`](docs/NEBULAOS_UPDATE_OWNERSHIP.md) — who updates what
- [`docs/NEBULAOS_PERSISTENT_NAMESPACE.md`](docs/NEBULAOS_PERSISTENT_NAMESPACE.md) — `/usr/data` ownership
- [`docs/RELEASE_ARTIFACTS.md`](docs/RELEASE_ARTIFACTS.md) — native, `.img` and `.ingenic` packages
- [`docs/REPRODUCIBILITY.md`](docs/REPRODUCIBILITY.md), [`docs/BUILD_PROVENANCE.md`](docs/BUILD_PROVENANCE.md)
- [`docs/BASELINE-MANIFEST.txt`](docs/BASELINE-MANIFEST.txt) — current development baseline
- [`ACKNOWLEDGEMENTS.md`](ACKNOWLEDGEMENTS.md) — upstream projects this builds on

Much of `docs/` and the long-form files at the root (`FIRMWARE.md`, `ANALYSIS.md`, `DESIGN.md`,
`docs/HISTORY.md`) are dated mission reports and history. Where they disagree with the manifest,
the build scripts or `tools/verify-architecture.sh`, the code wins.

## License

Third-party components keep their own licences. [`LICENSES/`](LICENSES/) holds the Wi-Fi
firmware notice, and [`ACKNOWLEDGEMENTS.md`](ACKNOWLEDGEMENTS.md) lists upstream projects.
