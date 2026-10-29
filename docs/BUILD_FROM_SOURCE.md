# Building NebulaOS from source

If you're just trying to build the whole OS, this is all you need:

```sh
git clone https://github.com/NebulaOS-KE/NebulaOS-firmware.git
cd NebulaOS-firmware
./build.sh
```

This exact command, from a genuinely fresh clone, is what we actually ran and hardware-qualified
during Final Closure — it's not aspirational, it's what we use ourselves.

## What it's doing

`build.sh` pulls one build image (`ghcr.io/nebulaos-ke/nebulaos-build`, pinned by digest in
`manifests/dependencies.conf`) and runs the whole pipeline inside it. You need Docker or Podman and
nothing else — the image already has every build tool the pipeline needs, so there's no
`apt-get install` beforehand, no nested containers, no messing with `/var/run/docker.sock`. See
`docs/NEBULAOS_BUILD_ENVIRONMENT.md` if you want the details on what's actually in that image.

A normal build today doesn't need `pellcorp/k1-bash-build`, `ghcr.io/coreflake1/guppydev`, nested
Docker, or a host-side `apt-get` — those were all part of the old build setup, retired as of
2026-08-15. If you run across a doc anywhere that still describes those as required, that page is
out of date; this one is current.

Under the hood, inside that container, `build.sh` runs these stages in order (see
`scripts/build/README.md` for what each one actually does):

```sh
cd scripts/build
./00-fetch-vendor-sources.sh      # fetches every pinned dependency, hash-verified
./01-apply-kernel-patches.sh      # verifies the openke fork's changes landed
./02-configure-buildroot.sh       # wires up buildroot.config, kernel fragment, overlay
./03-build-kernel-and-rootfs.sh   # builds the kernel + base rootfs
./04-cross-compile-app-stack.sh   # cross-compiles Klipper extras, GuppyScreen, v4l-utils, etc.
./05-final-build.sh               # final rootfs.ext2/rootfs.squashfs, writes build-manifest.txt
./06-verify.sh                    # sanity-checks the real output (architecture, artifact naming, etc.)
```

When it's done you'll have `xImage`, `rootfs.ext2`, and `rootfs.squashfs` in
`artifacts/buildroot-halley5-v30-image/`, along with `build-manifest.txt` and `kernel.config`.
GuppyScreen's compiled binary lands separately, in `artifacts/guppyscreen-mips/`. Quick note since
it trips people up: the kernel artifact is `xImage`, not `uImage` — `06-verify.sh` checks this
directly. `docs/BUILD_PROVENANCE.md` explains what `xImage` actually is if you're curious.

That last stage confirms the output is real, correctly-architected MIPS32 code — it doesn't claim
two separate builds will come out byte-for-byte identical (some timestamps and build-path strings
genuinely vary, that's just how the toolchain works, not a bug).

Budget ~15GB of disk and a few hours on a reasonably modern machine. It needs network access
throughout, since every dependency gets fetched fresh and hash-checked as it goes.

## Where every pin actually lives

`manifests/dependencies.conf` is the one file that pins everything — kernel, Klipper, GuppyScreen,
Buildroot, Moonraker, k1-ustreamer, v4l-utils, Mainsail, WiFi firmware, and the build image itself —
each by exact commit/tag/digest plus a SHA-256, checked on every run. Worth reading that file's own
comments before touching a pin; most of them exist because of something real that went wrong once.

The 8 kernel variants on top of stock upstream (PREEMPT_RT, a WiFi SDIO IRQ priority fix, VSYNC-
gated display panning, a pinctrl fix, the final backlight controller, PWM state readback, the final
touch driver, and disabling WiFi roaming) live as small scripts under `scripts/build/`, applied by
`scripts/build/apply-qualified-baseline.sh`.

The build always fetches fresh — it won't use a local checkout of the kernel, Klipper, or
GuppyScreen repo sitting next to it, even if you have one. And don't try building those three repos
on their own expecting a working printer image; none of them produce one by themselves.

## Iterating on a change

There's no separate fast dev-loop build today — just re-running `build.sh` reuses whatever's
already in `vendor/`, `build-work/`, and `artifacts/` if you don't delete them, so a second run
doesn't have to re-fetch everything. If you actually want to prove reproducibility rather than just
iterate quickly, use a fresh clone instead — a populated `vendor/` is convenient day to day, but it
defeats the point of a clean-room test.

## Related docs

- `docs/NEBULAOS_BUILD_ENVIRONMENT.md` — what's in the build image and how a new one gets promoted
- `docs/BUILD_PROVENANCE.md` — figuring out exactly which build produced a given artifact
- `scripts/build/README.md` — what each of the `00`-`06` stages does
- `docs/A_B_SLOT_MODEL.md` / `docs/DEVELOPER_INSTALL_FROM_STOCK.md` — what to actually do with the artifacts this produces
