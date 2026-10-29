# NebulaOS build environment

Source definition for `ghcr.io/nebulaos-ke/nebulaos-build`, the single container `build.sh` runs the
whole `scripts/build/00-06` pipeline inside.

## What's in here

```
build-env/
├── Dockerfile           the image itself
├── versions.env         every pinned identity (base image digest, GuppyScreen toolchain)
├── verify-environment.sh   run inside a built image to sanity-check its tooling
└── toolchains/README.md    what toolchain(s) this image bundles and why
```

## What this image contains

Every host-level build tool `scripts/build/*.sh` actually invokes (gcc/g++, make, cmake, python3,
git, bison/flex, autotools, `dtc`, `mksquashfs`, `e2fsprogs`, ...) — see the Dockerfile's own
comment block for the exact package list and which stage script needs each one. Also bundles
GuppyScreen's Bootlin mips32el-musl cross-toolchain directly (Migration A — see below).

## What this image does NOT contain

- **Project source.** `NebulaOS-firmware`, `NebulaOS-kernel`, `NebulaOS-klipper`,
  `NebulaOS-guppyscreen`, Buildroot, Moonraker — all fetched fresh by
  `00-fetch-vendor-sources.sh` at build time, pinned in `manifests/dependencies.conf`, exactly as
  before this migration. The image is the factory; `dependencies.conf` is the material list.
- **The kernel/rootfs/native-app target compiler.** That's Buildroot's own
  `mipsel-buildroot-linux-gnu-*` toolchain, self-bootstrapped from source during Stage 03 from this
  project's pinned Buildroot revision. This image supplies the *host* tools Buildroot needs to build
  that toolchain, not the toolchain itself.

## Migration A vs. Migration B

This image is **Migration A**: replace the two nested containers
(`pellcorp/k1-bash-build`, `ghcr.io/coreflake1/guppydev`) with one NebulaOS-owned image, while
changing as little else as possible. GuppyScreen's exact current compiler (Bootlin
`mips32el--musl--stable-2024.02-1`, pinned by the same SHA256 as
`NebulaOS-guppyscreen/docker/Dockerfile`) is preserved unchanged here on purpose — converging it onto
Buildroot's own target toolchain is a separate, larger, not-yet-executed experiment (**Migration B**,
see `docs/NEBULAOS_BUILD_ENVIRONMENT.md`), deliberately not folded into this one.

## Building it yourself

```sh
docker build -t nebulaos-build:local build-env/
```

## Why Ubuntu 22.04, not 20.04 (pellcorp's base)

Nothing in the actual build scripts is 20.04-specific — the packages baked in here (Task 2's
inventory) are all available, at compatible-enough versions, on 22.04. Standardizing on 22.04 means
one fewer variable while proving Migration A: it's already the exact base
`ghcr.io/coreflake1/guppydev` used, so this image's GuppyScreen toolchain section needed zero
adaptation from that already-working, already-audited Dockerfile.
