# Acknowledgements

NebulaOS doesn't exist in a vacuum. It's built on top of a lot of other people's work — some of it
vendored directly, some of it just a reference we leaned on to get something right. This page tries
to give credit where it's actually due, based on what's really in the repo and its history, not a
generic thank-you list.

## Pellcorp

A meaningful amount of the groundwork for this project's build and firmware work traces back to
[Pellcorp's](https://github.com/pellcorp) Creality K1/K1-family tooling. Specifically:

- **[`pellcorp/creality`](https://github.com/pellcorp/creality)** (the SimpleAF project) — NebulaOS's
  BLTouch probe backend is vendored from here (`PELLCORP_CREALITY_REPO`/`PELLCORP_CREALITY_PIN` in
  `manifests/dependencies.conf`). This is real vendored logic, not just inspiration.
- **[`pellcorp/klipper`](https://github.com/pellcorp/klipper)** — used as a reference to verify the
  sign convention in our own probe/Z-compensation code while building `z_compensate.py`, and — more
  substantially — the actual base of the Klipper fork NebulaOS shipped until 2026-08-17.
  `coreflake1/NebulaOS-klipper` diverged from `pellcorp/klipper`'s `jun2025` branch at
  `386fde4f` (2026-05-02, Jason Pell), and everything in that fork outside `klippy/extras/` was
  inherited from there, not written here. See the Klipper section below for where that ended up.
- **[`pellcorp/k1-ustreamer`](https://github.com/pellcorp/k1-ustreamer)** — NebulaOS's camera
  pipeline is a real port of this project (`K1_USTREAMER_REPO`/`K1_USTREAMER_PIN`).
- **`pellcorp/k1-bash-build`** — for a long time, this was the actual MIPS cross-compile toolchain
  container this project's build (and GuppyScreen's) ran inside. As of the unified build environment
  work (2026-08-15), both now use NebulaOS's own build image instead — but that image bundles the
  same toolchain this container provided, and its build recipe was faithfully reconstructed from the
  original image rather than replaced with something different. We're not still using the container,
  but the groundwork it represents is still part of how this builds.
- **[`pellcorp/k1-nginx`](https://github.com/pellcorp/k1-nginx)** — GuppyScreen's vendoring scripts
  use this project's build recipe to cross-compile nginx for the K1 platform.

If you're coming from the Pellcorp/K1 side of the Creality modding world, a good chunk of what made
this project possible started there.

## Klipper — and why there is no longer a NebulaOS Klipper fork

[Klipper](https://github.com/Klipper3d/klipper) is Kevin O'Connor's work and the printer firmware
this entire project runs on. As of the Phase 1 no-fork migration (2026-08-17) NebulaOS runs
**official, unmodified `Klipper3d/klipper`** at a pinned, qualified commit, with **zero core file
patches**. Everything this project actually wrote — the PRTouch load-cell probe stack, Z
compensation, the TMC status object, the GD32 die-temperature sensor — lives in
[`NebulaOS-KE/NebulaOS-klipper-extensions`](https://github.com/NebulaOS-KE/NebulaOS-klipper-extensions)
and is composed alongside an ordinary Klipper checkout at boot. See
[`docs/NEBULAOS_KLIPPER_COMPOSITION.md`](docs/NEBULAOS_KLIPPER_COMPOSITION.md).

That is a change in packaging, not a rewriting of history, and the credit does not move with it:

- **`coreflake1/NebulaOS-klipper` still exists**, on `master`, untouched and not archived. It is the
  historical record of the fork this project shipped from 2026-07-26 to 2026-08-17, and it is where
  the pre-migration commit SHAs remain resolvable. The extensions repository was seeded from it with
  `git filter-repo`, so `git log` and `git blame` for every file that moved came along — but those
  commits carry rewritten SHAs, and only the original repository can resolve the old ones.
- **The fork's non-`klippy/extras/` content was Pellcorp's, not ours.** 25 core files differed from
  mainline; every one of them was inherited from `pellcorp/klipper`'s `jun2025` branch rather than
  authored here. Retiring the fork retired those inherited differences — it did not replace anyone's
  work with our own.
- **Community modules keep their own authors.** `gcode_shell_command.py` (Eric Callahan),
  `virtual_pins.py` (Pedro Lamas), `calibrate_shaper_config.py`, `guppy_config_helper.py` and
  `guppy_module_loader.py` (GuppyScreen's `k1_mods`) are vendored, not written here. Each keeps its
  original copyright header, and the extensions repository's `VENDORED.md` records the per-file
  author, licence, upstream source, and any NebulaOS-side delta.

## GuppyScreen lineage

NebulaOS's touchscreen UI builds on:

- [`ballaswag/guppyscreen`](https://github.com/ballaswag/guppyscreen) — the original GuppyScreen project
- [`probielodan/guppyscreen`](https://github.com/probielodan/guppyscreen)
- [`prestonbrown/guppyscreen`](https://github.com/prestonbrown/guppyscreen) — source of the interactive 3D bed mesh
- [`pellcorp/grumpyscreen`](https://github.com/pellcorp/grumpyscreen) — bug fixes and improvements

## Recovery tooling

The USB recovery path documented in `docs/DEVELOPER_RECOVERY.md` and
`docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md` only exists because of
[`ballaswag/ingenic-usbboot`](https://github.com/ballaswag/ingenic-usbboot) — genuinely couldn't
do that recovery path without it.

## The rest of the stack

- [Moonraker](https://github.com/Arksine/moonraker) — the API server, official upstream at a pinned
  commit. The `vendor/moonraker` checkout is never touched. One reviewed NebulaOS compatibility
  patch (`moonraker-sqlite-nolock.patch`) is applied at build time to the overlay copy only; it is
  documented as a removal candidate in `scripts/build/04-cross-compile-app-stack.sh` and is the
  only permitted Moonraker modification. (Klipper has its own section above)
- [Mainsail](https://github.com/mainsail-crew/mainsail) — the web UI
- [Buildroot](https://buildroot.org/) — the base of our whole build system
- The Linux kernel, and the Ingenic X2000 SDK/BSP this board's kernel support is built from
- Creality, for the original K1/KE hardware and SDK source this project builds on top of

## License note

This page is informational — it doesn't replace or override any actual license or copyright notice.
See [`LICENSES/`](LICENSES/) for the real license terms covering this project's own code and
everything it vendors or fetches.
