# Build scripts - reproduce the full custom firmware/OS build from scratch

These scripts reproduce everything documented in `FIRMWARE.md` §8-14: a custom Linux 6.6.18-rt23
kernel + Buildroot rootfs for the Ender 3 V3 KE's Nebula Pad (Ingenic X2000), with touch, display,
WiFi, Bluetooth, camera, and a full Klipper/Moonraker/nginx/Mainsail/GuppyScreen app stack (Stage 04
fetches, cross-compiles, and installs GuppyScreen automatically - it was deliberately deferred/manual
early in this project's history, but that gap was closed 2026-08-07, see `manifests/dependencies.conf`'s
own `GUPPYSCREEN_PIN` history) - everything except the real-hardware boot test itself (needs the user
present, not something a script can do).

**Read this before running anything**: these scripts encode the *correct*, clean sequence -  not a
literal replay of every trial-and-error step taken while first discovering it (several real bugs
were hit and fixed along the way; the fixes are baked in here rather than reproduced as separate
steps). If you hit an error these scripts don't anticipate, check `FIRMWARE.md`'s relevant section
first - the real bugs already found (Buildroot's kernel-config stamp-tracking gap, the
`/src`-vs-`/br` Docker mount RUNPATH issue, the internal-toolchain C++ rebuild requirement, the
rootfs-overlay deletion gotcha) are all documented there with root causes, not just workarounds.

## Prerequisites

- Docker or Podman - `./build.sh` pulls the single, digest-pinned
  `ghcr.io/nebulaos-ke/nebulaos-build` image (`manifests/dependencies.conf`'s own
  `BUILD_IMAGE_REPO`/`BUILD_IMAGE_DIGEST`, never a mutable `:latest` tag) and runs the whole
  `00`-`06` pipeline inside it. That image already contains every host build tool these scripts
  need (see `build-env/Dockerfile`) - no separate `apt-get install`, no nested container, no
  `/var/run/docker.sock` requirement. The Buildroot-generated `mipsel-buildroot-linux-gnu-*`
  toolchain that actually builds the kernel/rootfs/native app stack is unrelated to this image -
  Buildroot builds that itself, from source, during Stage 03 (see `docs/
  NEBULAOS_BUILD_ENVIRONMENT.md` for the full "what's in/out of the image and why" breakdown).
  This replaces the old `pellcorp/k1-bash-build` + `ghcr.io/coreflake1/guppydev` nested-container
  setup (Migration A + Final Closure mission, 2026-08-15) - retained for history in `FIRMWARE.md`,
  no longer how a build actually runs.
- ~15GB free disk (kernel source, Buildroot's own internal toolchain build, and the final images
  add up) and a few hours of build time on a reasonably modern machine.
- Internet access for the `git clone`/`curl` steps in `00-fetch-vendor-sources.sh` - this project's
  `vendor/` directory is gitignored on purpose (large, mixed-provenance sources, see the main
  README), so nothing under `vendor/` is checked into this repo. The kernel is the one exception to
  "gitignored, nothing checked in": this project's kernel changes live as real commits on the
  `openke` branch of a real fork, [`NebulaOS-KE/NebulaOS-kernel`](https://github.com/NebulaOS-KE/NebulaOS-kernel)
  (renamed 2026-08-14 from `NebulaOS-KE/NebulaOS`; forked from the original upstream,
  `Llixuma/ingenic-linux-kernel6.6-x2000-v1.0-20250221`) -
  `00-fetch-vendor-sources.sh` clones that branch directly, so the kernel changes travel with their
  own real git history instead of a patch file. What else *is* checked into this repo: the small set
  of files this project actually wrote by hand (`scripts/build/overlay/` - init scripts and configs,
  not the third-party source/binaries those scripts launch).
- **Network access** for `00-fetch-vendor-sources.sh` to fetch the WiFi firmware/CLM/NVRAM - no
  real device or manual staging step required (see below). WiFi firmware (`.bin`/`.clm_blob`) is
  fetched directly from Infineon's own upstream repo; NVRAM (`.txt`) from this repo's own
  `wifi-firmware-v1.0.0` GitHub Release - both proprietary Cypress/Broadcom-format binaries, never
  committed to this repo (see `.gitignore` and `LICENSES/WIFI-FIRMWARE-NOTICE.md`).

## Running the whole thing

```sh
cd scripts/build
./00-fetch-vendor-sources.sh
./01-apply-kernel-patches.sh
./02-configure-buildroot.sh
./03-build-kernel-and-rootfs.sh
./04-cross-compile-app-stack.sh
./05-final-build.sh
./06-verify.sh
```

Each script is idempotent (safe to re-run) and checks its own prerequisites before doing anything.
Run them in order the first time; after that, re-running just the stage you're iterating on is
fine as long as its inputs (the previous stages' outputs) are still in place.

`00-fetch-vendor-sources.sh` fetches and hash-verifies the WiFi firmware/CLM/NVRAM automatically
(`scripts/firmware/fetch-cyw43430-wifi-firmware.sh` for the firmware+CLM, an inline step for the
NVRAM) before `02-configure-buildroot.sh` runs (which is what actually copies
`scripts/build/overlay/` - including everything staged under `overlay/lib/firmware/brcm/` - into
Buildroot's own overlay dir). No manual step, no real device required.

## What each stage does

1. **`00-fetch-vendor-sources.sh`** - clones/downloads every third-party source this build needs
   into `vendor/` at the exact refs this project used: the X2000 kernel SDK, this project's own
   fork's `openke` branch (`NebulaOS-KE/NebulaOS-kernel`, forked from `Llixuma/ingenic-linux-kernel6.6-
   x2000-v1.0-20250221`), the Buildroot config (`lone0/buildroot-x2000`), Klipper
   (`coreflake1/NebulaOS-klipper`), GuppyScreen (`coreflake1/NebulaOS-guppyscreen`), Moonraker
   (`Arksine/moonraker`, official), `pellcorp/k1-ustreamer`, and Mainsail's latest prebuilt release.
   - **`scripts/firmware/fetch-cyw43430-wifi-firmware.sh`** - fetches the canonical 7.45.98.125
     WiFi firmware + its own matching CLM blob directly from Infineon's own upstream repo
     (`Infineon/ifx-linux-firmware`, pinned commit, hash-verified) and stages them as
     `brcmfmac43430-sdio.bin`/`.clm_blob` under `scripts/build/overlay/lib/firmware/brcm/`, the
     filenames/path mainline `brcmfmac` actually requests. The board NVRAM (`.txt`) is fetched
     inline in this same stage from this repo's own release asset instead (real per-device
     calibration data, unrelated to which firmware build is running). See `FIRMWARE.md` §53 and
     `docs/NEBULAOS_WIFI_125_ENGINEERING_TEST.md` for how these exact files/paths were determined
     and why they're fetched rather than committed (proprietary binaries).
2. **`01-apply-kernel-patches.sh`** - no longer applies anything (this project's kernel changes -
   touch DT wiring, the new display panel driver, the new Bluetooth H5 Broadcom vendor extension,
   WiFi/BT/display Kconfig changes, the real ported NS2009 driver, and the upstream `binder.h`
   build-fix - are already real commits on the fork's `openke` branch, checked out by stage 0). Just
   verifies they're actually present, kept as stage "01" so the numbered sequence stays stable.
3. **`02-configure-buildroot.sh`** - writes the real Buildroot `.config` (base `x2000_halley5_v30_
   linux` defconfig plus every option this project added - WiFi/BT/touch/display/RNG/Python3/
   nginx/etc, using a helper that finds-and-replaces each option's *real* existing line rather than
   blindly appending, which is what caused a real class of bugs this session - see `FIRMWARE.md`
   §14), the kernel config fragment file (`halley5-nebulaos-fragment.config` - includes
   `CONFIG_EXTRA_FIRMWARE`, which embeds the WiFi firmware directly into the kernel image rather
   than relying on the rootfs being mounted yet - `brcmfmac` is built-in and probes for it earlier
   in boot than the real root filesystem mounts, see `FIRMWARE.md` §53), `local.mk` (the
   `LINUX_OVERRIDE_SRCDIR` pointer), and copies this repo's own hand-written overlay content
   (`scripts/build/overlay/`, including whatever `fetch-cyw43430-wifi-firmware.sh` staged) into
   `board/halley5-nebulaos-overlay/`.
4. **`03-build-kernel-and-rootfs.sh`** - the main kernel + rootfs build (`make`) - touch, display,
   WiFi, Bluetooth, camera-kernel-side, and Core SoC infra all come from this one pass, since
   they're all just kernel config + device-tree, no cross-compiled userspace extras needed yet.
5. **`04-cross-compile-app-stack.sh`** - cross-compiles the handful of things that need the
   Buildroot-built toolchain directly rather than going through a Buildroot package (Klipper's
   `chelper` C extension, Moonraker's `streaming-form-data` C extension, and `ustreamer` itself),
   and assembles the full app-stack overlay (Klipper/Moonraker source trees, Mainsail's static
   build, this repo's own init scripts/configs already in place from stage 2).
6. **`05-final-build.sh`** - the final full `make` that bakes everything from stage 4 into the
   actual `rootfs.ext2`/`xImage`, and copies the resolved artifacts (`xImage`, `rootfs.ext2`,
   `rootfs.squashfs`, `build-manifest.txt`, `kernel.config`) into `artifacts/buildroot-halley5-v30-image/`.
7. **`06-verify.sh`** - the same `debugfs`-based presence checks and `readelf`/`file` architecture
   checks used throughout this project to confirm each piece actually landed in the image and is
   real MIPS32 little-endian code, without needing real hardware.

## Output

`vendor/buildroot-x2000/output/images/{xImage,rootfs.ext2,rootfs.squashfs}` (this stage's own
`05-final-build.sh` already copies these into `artifacts/buildroot-halley5-v30-image/` for you -
confirmed against a real fresh-clone build 2026-08-14; this section previously said `uImage`, which
does not match this project's actual output filename)
(sha256 sums won't match exactly build-to-build for the image artifacts - `xImage` and
`rootfs.squashfs` are not byte-reproducible - but the same real code should be present; that's
what `06-verify.sh` checks for. Corrected 2026-09-24: "timestamps and build-path strings end up
embedded in a few places" was a plausible guess presented as the explanation, and it is not
established. What IS measured: the uImage header embeds wall-clock build time, and 1,454,891 of
~5.5MB still differ beyond that header. Note this does NOT apply to `guppyscreen`, which is now
reproducible for a fixed pin. See `docs/REPRODUCIBILITY.md`.)
