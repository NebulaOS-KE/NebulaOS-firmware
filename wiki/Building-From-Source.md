# Building from source

Everything needed to turn this repository into a flashable image, and what the build does with
the pins. Read against `NebulaOS-firmware` at `b95b156`, with the artifact names and the
pipeline checked against the 1.0.2 release commit `3bdf3ff`.

Nothing on this page was built by its author - this documentation session does not build
firmware. Every statement is read from `build.sh`, `scripts/build/` and
`manifests/dependencies.conf`. The exhaustive, per-script list is
[Build scripts and host tools](Build-Scripts-And-Host-Tools).

## The whole build

```sh
git clone https://github.com/NebulaOS-KE/NebulaOS-firmware.git
cd NebulaOS-firmware
./build.sh
```

`build.sh` pulls one build container and runs the whole pipeline inside it. Docker or Podman on
the host is the only requirement: the container image already carries every host build tool the
stages invoke, so there is no `apt-get install` beforehand, no nested containers and no
`/var/run/docker.sock`.

Budget **~15 GB of disk and a few hours**, and network access throughout - every dependency is
fetched fresh and hash-checked as it goes.

## The seven stages

`scripts/build/` holds seven numbered scripts, run in order (the rest of the directory is
gates, packaging and supply-chain steps invoked around them):

| Stage | What it does |
|---|---|
| `00-fetch-vendor-sources.sh` | Fetches every pinned dependency, hash-verified |
| `01-apply-kernel-patches.sh` | **Applies nothing.** Verifies that the kernel fork's changes are present in the checked-out tree. The number is kept so older documents and habits still work |
| `02-configure-buildroot.sh` | Wires up `buildroot.config`, the kernel fragment and the overlay |
| `03-build-kernel-and-rootfs.sh` | Builds the kernel and the base root filesystem |
| `04-cross-compile-app-stack.sh` | Cross-compiles the application stack - Klipper extras, NebulaScreen, v4l-utils |
| `05-final-build.sh` | Assembles `rootfs.ext2` / `rootfs.squashfs`, writes `build-manifest.txt` |
| `06-verify.sh` | Checks the real output: architecture, artifact naming, pins |

Output lands in `artifacts/buildroot-halley5-v30-image/` - `xImage`, `rootfs.ext2`,
`rootfs.squashfs`, plus `build-manifest.txt` and `kernel.config`. The screen binaries land
separately in **`artifacts/nebulascreen-mips/`** (`nebulascreen`, `nebulabeep`).

Two naming traps, both worth knowing before reading an older document:

- The kernel artifact is **`xImage`**, not `uImage`; `06-verify.sh` checks this directly.
- The *manifest field names* for the screen binaries are still `guppyscreen_sha256` and
  `guppybeep_sha256` (`05-final-build.sh`), while the *paths* are `nebulascreen-mips/`. The
  field names are the older ones and were not renamed with the app.

`06-verify.sh` confirms the output is real, correctly architected MIPS32 code. It does **not**
claim two builds come out byte-for-byte identical - see [Build provenance](Build-Provenance).

## The build container

`ghcr.io/nebulaos-ke/nebulaos-build`, pinned **by digest** in `manifests/dependencies.conf`
(`BUILD_IMAGE_DIGEST`), which `build.sh` reads directly - never a tag. A floating tag can be
repointed at different content later; a digest is content-addressed and can only ever resolve to
the bytes that produced that hash.

What the container image contains: the host-level build tools stages 00-06 invoke (gcc/g++,
make, cmake, python3, git, autotools, `dtc`, `mksquashfs`, `e2fsprogs`), plus NebulaScreen's
exact Bootlin `mips32el-musl` cross-toolchain kept on a non-default `PATH` entry, because its
bundled `autoreconf` would otherwise shadow the one v4l-utils' build needs.
`build-env/Dockerfile` and `build-env/versions.env` are the authoritative list.

What it deliberately does **not** contain: any project source (all fetched fresh and pinned),
and the target compiler - `mipsel-buildroot-linux-gnu-*` is Buildroot's own self-bootstrapped
toolchain, built from the pinned Buildroot revision during stage 03. The container image is the
factory; the manifest is the material list.

Rebuilding the container from `build-env/` produces a *candidate*, never the canonical image.
Promotion is a deliberate human step with its own reviewed commit, after a fresh clone rebuilt
at the same source pins is compared artifact by artifact against the accepted reference. The
honest limit: the apt packages inside it are not individually version-pinned, so rebuilding the
Dockerfile a year from now can resolve different point releases. What *is* reproducible is the
published, digest-pinned image. Full detail: `docs/NEBULAOS_BUILD_ENVIRONMENT.md`.

## Where the pins live

`manifests/dependencies.conf` pins everything - kernel, Klipper, the Klipper extensions,
NebulaScreen, Buildroot, Moonraker, Mainsail, Wi-Fi firmware, the package index and the build
image - each by exact commit, tag or digest with a hash checked on every run. **That file is the
shipping authority.** A component repository's tip is not what ships; the pin is. The two differ
routinely, and confusing them is the easiest way to document a feature no printer has.

At the 1.0.2 release commit `3bdf3ff` the pins are kernel `95d0321e` (branch `openke`),
extensions `178a0c2` (branch `production`), NebulaScreen `fd47cb6`
(`NEBULASCREEN_VERSION=v1.0.1`) and upstream Klipper `58bd67db`. Read that file's own comments
before touching a pin; most of them exist because of something that went wrong once.

Every NebulaOS kernel change is a real commit on the kernel fork's `openke` branch, pinned by
`KERNEL_PIN` - **nothing is patched at build time**. The production configuration is that
repository's `nebulaos_halley5_v30_defconfig`, which selects `CONFIG_PREEMPT`, not
`CONFIG_PREEMPT_RT`, since 1.0.2. See
[NebulaOS-kernel's wiki](https://github.com/NebulaOS-KE/NebulaOS-kernel/wiki).

The build always fetches fresh: a local checkout of the kernel, the extensions or NebulaScreen
sitting next to this repository is not used, even if it is there.

## Iterating

There is no separate fast dev loop. Re-running `build.sh` reuses whatever is already in
`vendor/`, `build-work/` and `artifacts/`, so a second run does not re-fetch everything. To
prove reproducibility rather than to iterate, use a fresh clone - a populated `vendor/` is
convenient day to day and defeats the point of a clean-room test.

Related tracked docs: `docs/BUILD_FROM_SOURCE.md`, `docs/NEBULAOS_BUILD_ENVIRONMENT.md`,
`scripts/build/README.md`.
