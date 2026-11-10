# Acknowledgements

NebulaOS is built on other people's work. The full, user-facing thank-you list - every project and
person, with what NebulaOS uses from them - is in the wiki:
**[Thank you](https://github.com/NebulaOS-KE/NebulaOS/wiki/Thank-You)**. It is built from the
source: file headers, `VENDORED.md` in the extensions repository, the pins in
`manifests/dependencies.conf`, kernel commits and our research notes.

What this repository itself takes from others, in short:

- **Pinned and fetched** (`manifests/dependencies.conf`): Buildroot 2025.02.18, Klipper (official,
  unmodified), Moonraker (one build-time patch, `moonraker-sqlite-nolock.patch`, on the overlay copy
  only), moonraker-timelapse, Mainsail, Infineon's CYW43430 Wi-Fi firmware, wireless-regdb,
  v4l-utils, pellcorp/k1-ustreamer (PiKVM µStreamer, plus the NebulaOS CAM-05 patch),
  ballaswag/ingenic-usbboot (plus a write-partition patch), the OpenKlipperEdition/Recovery
  `.ingenic` template, and pellcorp/creality (SimpleAF), which is pinned and verified as the
  provenance of derived macros - no file from it is copied into the image.
- **Derived configuration**: `print.cfg`, `filament.cfg` and `homing.cfg` start from SimpleAF's
  macros, which in turn carry KAMP's `_LINE_PURGE` / `_SMART_PARK` (kyleisah), fluidd-config's
  `_CLIENT_*` macros (Alex Zellner) and "Zero"'s `_WARP_STABILISE`. The nginx template is adapted
  from KIAUH.
- **Ported protocol**: `opt/nebulaos/tools/creality_flash.py` speaks Creality's mainboard bootloader
  protocol as worked out in CryoZ's `mcu_util.py`.
- **Kernel**: NebulaOS-kernel is a fork of Llixuma's mirror of Ingenic's X2000 Linux 6.6 SDK,
  rebased on linux-stable-rt, with Icenowy Zheng's NS2009 touch driver.
- **Touchscreen**: NebulaScreen is a fork of ballaswag's GuppyScreen, with work from probielodan and
  Preston Brown.

Corrections to earlier versions of this file: NebulaOS ships no BLTouch backend from
pellcorp/creality and no PRTouch stack (removed from the runtime); the build image does not carry
pellcorp/k1-bash-build's Ingenic toolchain (see `build-env/toolchains/README.md`); nginx comes from
Buildroot, not pellcorp/k1-nginx.

The licence terms are in [`LICENSES/`](LICENSES/) and in the file headers. This page is a thank-you,
not a licence.
