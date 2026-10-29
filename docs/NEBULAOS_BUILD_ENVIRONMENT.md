# The NebulaOS build environment

This covers the unified build container (`ghcr.io/nebulaos-ke/nebulaos-build`) — why it exists,
what's actually in it, what deliberately isn't, and what has to pass before a new version of it
becomes the one everyone builds against.

## What does `nebulaos-build` contain?

Every host-level build tool `scripts/build/00-06` actually invokes — gcc/g++, make, cmake, python3,
git, the autotools family, `dtc`, `mksquashfs`, `e2fsprogs`, and so on — baked into the image at
build time instead of `apt-get install`'d mid-firmware-build. Also bundles GuppyScreen's exact
current Bootlin `mips32el-musl` cross-toolchain, kept on a non-default `PATH` entry
(`GUPPYSCREEN_TOOLCHAIN_BIN`) rather than the image's global `PATH` — see `build-env/Dockerfile`'s
own comment for why (its bundled `autoreconf` would otherwise shadow the system one v4l2-ctl's build
needs — a real bug found and fixed during this migration, see `build-env/verify-environment.sh`).

See `build-env/Dockerfile` and `build-env/versions.env` for the exact, current, authoritative list.

## What does it NOT contain?

- **Project source.** `NebulaOS-firmware`, `NebulaOS-kernel`, `NebulaOS-klipper`,
  `NebulaOS-guppyscreen`, Buildroot, Moonraker, kernel source — all fetched fresh by
  `00-fetch-vendor-sources.sh` at build time, pinned in `manifests/dependencies.conf`. The image is
  the factory; the manifest is the material list; unchanged by this migration.
- **The kernel/rootfs/native-app target compiler.** `mipsel-buildroot-linux-gnu-*` is Buildroot's own
  self-bootstrapped toolchain, built from source during Stage 03 from the project's pinned Buildroot
  revision. Bundling a pre-built copy would break the actual point of pinning Buildroot in the first
  place — this image supplies only the *host* compiler Buildroot itself needs to build it.

## Why is it pinned by digest, not a tag?

Because a floating tag (`:latest`, `:candidate`) can be silently repointed at different content later
— the exact bug this project already closed once for `pellcorp/k1-bash-build` (see
`manifests/dependencies.conf`'s own comment on that pin, Final Pre-Flash Audit mission, 2026-08-08).
A digest is content-addressed: `ghcr.io/nebulaos-ke/nebulaos-build@sha256:...` can only ever resolve to
the exact bytes that produced that hash. `manifests/dependencies.conf`'s `BUILD_IMAGE_DIGEST` is the
one place this is recorded; `build.sh` reads it directly, never a tag.

## Why does Buildroot still generate the target toolchain?

Because that's what makes the *kernel and rootfs* reproducible from the pinned Buildroot source —
baking a pre-built `mipsel-buildroot-linux-gnu-gcc` into the build image would mean the actual
compiler producing NebulaOS's kernel/rootfs/native-app binaries is no longer traceable to a pinned,
auditable source. The unified image changes *where the build runs*, not *what Buildroot itself
produces*.

## How do I build the OS?

Unchanged from before this migration:

```sh
git clone https://github.com/NebulaOS-KE/NebulaOS-firmware.git
cd NebulaOS-firmware
./build.sh
```

`build.sh` now pulls the pinned `nebulaos-build` image and runs the whole `00-06` pipeline inside it
directly — no more nested `pellcorp/k1-bash-build`/`guppydev` containers, no more
`/var/run/docker.sock` requirement, no more per-stage `apt-get`. Requires Docker or Podman on the
host and nothing else.

## How do I rebuild the build image?

```sh
docker build -t nebulaos-build:local build-env/
```

To publish a new **candidate** (never automatically canonical): push to a branch touching
`build-env/**`, or run `.github/workflows/build-environment.yml` via `workflow_dispatch`. It publishes
to `ghcr.io/nebulaos-ke/nebulaos-build` under a dated/short-SHA tag and prints the resulting digest —
promotion to canonical is always a separate, deliberate, human step (see below).

## How is a new build image promoted?

Only after **all** of:

1. The candidate image is built from tracked `build-env/Dockerfile` content and pushed to GHCR.
2. Its digest is known and recorded.
3. A fresh clone is rebuilt using **exactly** the source refs already accepted as the reference (same
   `KERNEL_PIN`/`KLIPPER_PIN`/`GUPPYSCREEN_PIN` — not newer `main`, not newer anything).
4. That rebuild's output is strictly compared against the accepted reference artifacts (hashes,
   `build-manifest.txt` fields, `06-verify.sh`'s full content checks) — see the Phase 11 final report
   for this project's own worked example of that comparison.
5. Every difference found is understood and explicitly classified (expected/deliberate, or a real
   regression to fix before promoting).

Only then does a human update `BUILD_IMAGE_DIGEST` in `manifests/dependencies.conf`, in its own
reviewed commit — never automated, never silent.

## Migration A vs. Migration B

- **Migration A** (this document, done): replace the two nested external containers with one
  NebulaOS-owned image, changing container ownership/structure only. GuppyScreen's compiler is
  preserved byte-for-byte.
- **Migration B** (investigated, not executed): converge GuppyScreen from its Bootlin musl toolchain
  onto Buildroot's own `mipsel-buildroot-linux-gnu-*` toolchain — a real product/ABI change (different
  libc: musl vs. glibc), not a packaging change, and deliberately kept out of Migration A's proof. See
  the Phase 11 final report's own Migration B section for the investigation and recommendation.

## Known reproducibility limits (be honest about these, don't paper over them)

- **`apt-get install` packages are not individually version-pinned.** Ubuntu's apt repositories serve
  whatever package versions are current when the image is *built*, not when the Dockerfile is
  *written*. This means rebuilding `build-env/Dockerfile` today vs. a year from now can resolve
  different `gcc`/`make`/etc. point releases — the Dockerfile itself is not perfectly bit-reproducible
  on rebuild. What *is* reproducible: the **published, digest-pinned image** is immutable once built —
  anyone pulling `ghcr.io/nebulaos-ke/nebulaos-build@sha256:...` gets the exact same bytes forever. The
  pin is on the resulting image, not on a promise that rebuilding the Dockerfile reproduces it
  identically. (`pellcorp/k1-bash-build`, the container this replaces, had the identical property and
  the identical limitation — this is not a regression, just now made explicit.)
- **The Bootlin GuppyScreen toolchain and the Ubuntu base image are both pinned** (URL + SHA256, and
  base image digest respectively) — those two layers *are* exactly reproducible.

## Retirement of the old containers

Done, as of the Final Closure mission (2026-08-15): this image is canonical, `manifests/
dependencies.conf`'s `PELLCORP_K1_BASH_BUILD_IMAGE` pin is removed, and no script in this repo
references `pellcorp/k1-bash-build` or `ghcr.io/coreflake1/guppydev` as a live dependency any
longer — see the Phase 11 report and the Final Closure report for the full evidence chain
(repeatability comparison, physical hardware qualification) behind that promotion.

`NebulaOS-guppyscreen`'s own separate CI (`.github/workflows/build.yml`) is a distinct, not-yet-
migrated dependency on `ghcr.io/coreflake1/guppydev:latest` in a different repository - out of
scope for this image's own promotion, tracked separately.
