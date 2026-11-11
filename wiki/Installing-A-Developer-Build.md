# Installing a developer build

Which route to use to get an image onto a printer, and what each one proves. Read against
`NebulaOS-firmware` at `b95b156`.

Nothing on this page was run on a printer by its author - this documentation session has no
printer access. It is read from `docs/INSTALL_FROM_STOCK.md`, `docs/HARDWARE_AGENT.md`,
`scripts/flash-spare-slot.sh` and `tools/`.

## Three routes, and which one is current

| Route | Use it for | Status |
|---|---|---|
| **Creality's own updater** | A release `.img`, from stock Creality firmware or OpenKE | Current, and what users do |
| **The Hardware Agent launcher** | A build you just made, onto an enrolled development printer | Current, for developers |
| **`scripts/flash-spare-slot.sh` by hand over SSH** | The mechanism underneath both | Kept, but the manual sequence around it is superseded |

The two **superseded** tracked documents are still in the repository on purpose, marked as
history: `docs/DEVELOPER_INSTALL_FROM_STOCK.md` and `docs/DEVELOPER_UPDATE.md`. Their mechanics
are still accurate; the surrounding claims ("no download-and-install button yet", an MCU left
mismatched until someone intervenes) are not. If you are following one of them, read
[Architecture](Architecture) and [Image install and the trial](Image-Install-And-Trial) first.

## Route 1: a release image, with Creality's updater

The procedure is in `docs/INSTALL_FROM_STOCK.md`, and the end-user version with screenshots is
in the [NebulaOS manual](https://github.com/NebulaOS-KE/NebulaOS/wiki/Installing-NebulaOS). The
three things that catch people:

- **Keep the release file's name.** The updater finds the parts inside it by file name; a
  renamed file stops with `failed to get .../ota_config.in`.
- **Restart with a soft reboot** (`reboot`), not the power switch. A stock system that starts
  from power-on can flash old Creality firmware into the mainboard MCU.
- `sh: 1.1.0.15: bad number` in the updater's output is normal - it is the updater's own version
  check and stops nothing.

This route writes NebulaOS into the slot that is not running and leaves your current system in
the other one. It has **no trial**: the trial in
[Image install and the trial](Image-Install-And-Trial) applies to installs started from
NebulaScreen.

## Route 2: the Hardware Agent, for a build

For an enrolled development printer, `tools/run-nebulaos-hardware.sh` performs the whole
install and then proves what landed, rather than assuming it:

```sh
run-nebulaos-hardware.sh --device <id> --control <C> inspect
run-nebulaos-hardware.sh --device <id> --control <C> verify  <X> <ximage-sha256> <rootfs-sha256>
run-nebulaos-hardware.sh --device <id> --control <C> install <X> <ximage-sha256> <rootfs-sha256>
```

It reads the printer's slot state first and takes one of two paths - `PRESERVE_STOCK` when
Creality's system is in slot 1 and is to be kept, `INACTIVE_SLOT` when NebulaOS is in both slots
- and in either case it re-reads the live root from `/proc/cmdline`, writes the slot that is
**not** running, verifies the written bytes, selects the new slot, reboots in software and then
verifies the exact build that came up. The outcome is one flag:
`PART1_INSTALL_VERIFIED=YES|NO`.

Two properties worth knowing before reading the full document:

- **`install` is a privileged operation** with its own authorisation: read-only operations
  (`inspect`, `status`, `diagnose`, `verify`) and the single repair (`restart <service>`, from a
  closed list) are open to any principal allowed near a printer, and `install` is not.
- **A pass requires that no MCU restore was needed.** `MCU_RESTORE_RESULT` is observed, and any
  restore fails the check - so "it installed and the MCU had to be rescued" never reads as a
  clean install.

Full detail, including the identity checks and the MCU cost of booting Creality's slot:
`docs/HARDWARE_AGENT.md`.

## Route 3: the mechanism, `scripts/flash-spare-slot.sh`

Worth understanding even if you never run it by hand, because both routes above end up here and
because its refusals are the safety model.

- **`--check-only` writes nothing.** It resolves the partition labels, reads the *live* boot
  device out of `/proc/cmdline`'s `root=` (not `/proc/mounts`, which cannot tell the two slots
  apart), checks the image sizes against the partitions' real capacities, and verifies both
  files against `build-manifest.txt` if you pass one. The real flash runs that same check again
  immediately before writing, so an earlier pass is never a stale green light.
- **It refuses to write the slot it is booted from.** That check exists because an earlier
  version got it wrong once and wrote the live root filesystem.
- **It writes, then reads back exactly the bytes it wrote** - not the whole partition, so a
  smaller new image cannot be compared against leftovers from a bigger old one - and checks
  that read-back against the source file.
- **It does not flip the boot marker.** Writing an image and deciding to boot it are two
  separate steps on purpose, so a bad flash is never booted by accident.

Only `kernel2` and `rootfs2` (or the inactive pair, by label) are written. The data partition is
not touched by any of this, which is why your configuration, calibration and print files survive
an install.

Stage files in `/usr/data`, not `/tmp`: `/tmp` is a small tmpfs and `rootfs.squashfs` alone is
well over 100 MB.

## Going back

The other slot still holds what was there before. From the screen: **Settings > Reset > Swap
boot slot**. The routes in order of severity are on [Recovery](Recovery).
