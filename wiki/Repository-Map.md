# Repository map

Which repository holds what, and what is upstream rather than ours. Every pin below is read from
`manifests/dependencies.conf` at the 1.0.2 release commit `3bdf3ff`.

## NebulaOS's own repositories

| Repository | Role | At 1.0.2 |
|---|---|---|
| [NebulaOS](https://github.com/NebulaOS-KE/NebulaOS) | Releases, downloads and the end-user manual (its wiki). Not a source tree | tag `v1.0.2` |
| **NebulaOS-firmware** (this one) | Pins every component and builds the complete image. The architecture, the OS settings API and the boot sequence live here | `3bdf3ff` |
| [NebulaOS-kernel](https://github.com/NebulaOS-KE/NebulaOS-kernel) | Linux 6.6 for the Ingenic X2000, on branch `openke`. Mostly a vendor SDK; NebulaOS's own changes are real commits, not build-time patches | `KERNEL_PIN=95d0321e` |
| [NebulaOS-klipper-extensions](https://github.com/NebulaOS-KE/NebulaOS-klipper-extensions) | The Klipper modules NebulaOS composes into an unmodified upstream Klipper - calibration, load-cell probing, power-loss recovery, the beeper | `KLIPPER_EXTENSIONS_PIN=178a0c2`, branch `production` |
| [NebulaOS-nebulascreen](https://github.com/NebulaOS-KE/NebulaOS-nebulascreen) | The touchscreen application, built into the image. Based on GuppyScreen | `NEBULASCREEN_PIN=fd47cb6`, `v1.0.1` |
| [NebulaOS-klipper-mcu](https://github.com/NebulaOS-KE/NebulaOS-klipper-mcu) | The native GD32F303 mainboard firmware, built from the same upstream Klipper commit the host runs | vendored as `scripts/build/overlay/opt/nebulaos/mcu-candidates/candidate-001.bin` |
| [nebulaos-packages](https://github.com/NebulaOS-KE/nebulaos-packages) | A package index of ready-made Python wheels for this image's ABI, so a printer never builds anything and never talks to PyPI | `NEBULAOS_PACKAGE_INDEX_URL`, ABI scheme 1 |
| [lv_drivers](https://github.com/NebulaOS-KE/lv_drivers) | A fork of LVGL's driver layer, consumed by NebulaScreen as a submodule - two commits on top of upstream, one of them live | pinned through NebulaScreen |

## What is upstream, and stays upstream

| Component | Where it comes from | At 1.0.2 |
|---|---|---|
| Klipper | `Klipper3d/klipper`, **unmodified** | `KLIPPER_PIN=58bd67db` |
| Moonraker | `Arksine/moonraker` | `MOONRAKER_PIN=d5ee1712` |
| Moonraker-timelapse | `mainsail-crew/moonraker-timelapse` | `c7fff11e` |
| Mainsail | `mainsail-crew/mainsail` release zip | `MAINSAIL_TAG=v2.18.2` |
| Buildroot | `buildroot/buildroot` | `BUILDROOT_PIN=d030e36b` |
| Wi-Fi firmware | Infineon's `ifx-linux-firmware`, republished as a release asset | `release-v5.10.9-2022_0909` |
| USB recovery tool | `ballaswag/ingenic-usbboot`, plus one patch in `patches/` | `c65eaa33` |

**Klipper is not forked.** NebulaOS runs official Klipper and composes its own modules in at
boot (`S05nebulaos-activate`, excluded symlinks); the retired `NebulaOS-klipper` fork is not
part of the project any more. That is the single most important thing to know before reading an
older document: a fork is where the extensions repository is now.

## And one name that is not us

**OpenKE** is a separate, independently released project that shares an author and some history
with NebulaOS. The kernel repository's branch is still called `openke` for historical reasons;
that is a leftover name, not a live connection. Do not read OpenKE's own documentation as
describing NebulaOS.

## Where the developer documentation lives

Each repository documents its own part in its own wiki:

- [NebulaOS-firmware wiki](https://github.com/NebulaOS-KE/NebulaOS-firmware/wiki) - this one:
  boot, slots, updates, recovery, the API, the build
- [NebulaOS-kernel wiki](https://github.com/NebulaOS-KE/NebulaOS-kernel/wiki) - which parts of
  the kernel are NebulaOS, and the freeze-diagnosis layer
- [NebulaOS-klipper-extensions wiki](https://github.com/NebulaOS-KE/NebulaOS-klipper-extensions/wiki)
  - the commands, their parameters and the configuration options
- [NebulaOS-nebulascreen wiki](https://github.com/NebulaOS-KE/NebulaOS-nebulascreen/wiki) - the
  screen application, and the user-facing screen reference
- [NebulaOS-klipper-mcu wiki](https://github.com/NebulaOS-KE/NebulaOS-klipper-mcu/wiki) - the
  mainboard firmware's lifecycle on a printer
- [nebulaos-packages wiki](https://github.com/NebulaOS-KE/nebulaos-packages/wiki) - the index,
  the ABI fingerprint and the invariants
- [lv_drivers wiki](https://github.com/NebulaOS-KE/lv_drivers/wiki) - which parts of the fork are
  NebulaOS

Cross-repository subjects - flashing, slots, recovery - live here, and the others link back
rather than keeping their own copies.
