# Recovering a NebulaOS printer

If a development build goes sideways, don't jump straight to USB recovery — there are a few easier
ways back, roughly in order of how bad things have to get before you need them.

## 1. Automatic stock fallback is DISABLED (Phase 1.8B)

**This section describes behavior that has been intentionally removed.** The old automatic stock
fallback (S00revert-safety writing "ota:kernel" on every boot, S99confirm-good flipping it forward
only on success) was removed in Phase 1.8B because a genuine power cycle while booted into the
stock Creality slot lets it auto-flash the MCU with old Creality firmware, destroying the qualified
native GD32F303 MCU build. The risk of silently bricking the MCU outweighs the convenience of
automatic rollback. (Hardware evidence gathered after this decision - 2026-08-28 and 2026-08-31,
see `_project/missions/phase1.8b-candidate-002-rebuild-hardware-qualification-report.md` and
`_evidence/phase2-axis-twist-qualification-20260831-203913/stock-baseline/` - shows a plain soft
`reboot` into stock does NOT actually trigger the auto-flash on its own, since stock's flasher can't
reset the still-running MCU without a real power cycle; this doesn't change the decision here, since
S00revert-safety's own fallback path was never verified to guarantee no power cycle occurs, but it
is worth knowing before anyone considers re-enabling automatic fallback in the future.)

**Current behavior:** if a NebulaOS boot fails (Klipper doesn't start, Moonraker is unreachable,
etc.), the device stays on NebulaOS. The boot health check (S99confirm-good) still runs and logs
whether Klipper reached "ready" state, but it no longer touches the OTA marker on any code path.
Recovery from a failed boot requires manual intervention — see sections 2 and 3 below.

The `write_ota_marker` function is still available in `/etc/ota_marker.sh` for manual use.

## 2. Switch slots over SSH

If the currently-running OS still has working SSH, this takes about two minutes and no tools.

From custom — this sets an EXACT state, and you say which one:
```sh
. /etc/ota_marker.sh
write_ota_marker "ota:kernel"    # or "ota:kernel2" to go the other way
reboot
```

From stock — **this is a toggle, not a set**:
```sh
. /etc/ota_bin/ota_local_method.sh
local_set_next_boot_device
```

`local_set_next_boot_device` takes no argument. It flips the marker to whatever
it currently is not. That means you cannot ask it for a particular slot, and you
cannot tell from the command succeeding which slot you are now pointed at.

**Read the marker back before you reboot.** Do not trust the command's own
output, and do not assume the toggle went the way you wanted:

```sh
dd if=/dev/mmcblk0p1 bs=512 count=1 2>/dev/null | head -c 32 | xxd
```

You want to see `ota:kernel` for stock or `ota:kernel2` for custom. If it is not
what you intended, run the toggle again and re-check. Only reboot once the bytes
say what you want.

If the read shows anything else — an empty block, a truncated string, or a value
you do not recognise — **do not reboot**. An indeterminate marker is the one
state from which you cannot predict which slot comes up, and a power cycle into
stock has its own consequences (see §1 above on the MCU).

This doesn't erase anything on either side — see the persistence table below.

## 3. USB recovery — the panic button

This is what you reach for when networking is dead and you can't get to the custom slot any other
way. It's specifically a way to force the device back to stock, not a general-purpose installer, so
don't expect it to do anything fancier than that.

You'll need:
- A Linux computer (this is the only platform these commands are documented against)
- A USB cable into the Nebula Pad's MicroUSB port
- Possibly opening the case to reach two small buttons next to that port
- `sudo` (plain USB access without it just fails with a permissions error)
- [`ballaswag/ingenic-usbboot`](https://github.com/ballaswag/ingenic-usbboot), built from source — credit to that project for making this recovery path possible at all:
  ```sh
  git clone https://github.com/ballaswag/ingenic-usbboot
  cd ingenic-usbboot
  make
  ```
  The compiled binary ends up named `usbboot`, not `ingenic-usbboot` — that's just the repo's name.

  The repository and this project's own patch are now recorded in
  `manifests/dependencies.conf` (`INGENIC_USBBOOT_REPO`,
  `INGENIC_USBBOOT_PATCH`, `INGENIC_USBBOOT_PATCH_SHA256`). An earlier version of
  this document said we don't pin a version, which meant "the recovery path"
  named whatever upstream happened to be that day. `patches/ingenic-usbboot-write-partition.patch`
  adds `mmc_write_partition()` — a chunked write with an immediate read-back
  verification of every chunk — plus libusb control-transfer retry for the
  post-write `LIBUSB_ERROR_TIMEOUT` seen on real hardware.

Here's the actual procedure, including a couple of gotchas we hit doing this for real:

1. Power off. Hold both buttons for 3 seconds, release the reset button first, then boot. This puts
   the board into mask-ROM USB recovery mode — nothing's running yet, it's just waiting for
   instructions.
2. Optional sanity check: `lsusb`, look for `ID a108:eaef Ingenic Semiconductor Co.,Ltd Ingenic USB
   BOOT DEVICE`.
**Shortcut (2026-10-14):** steps 3 and 4 are scripted, idempotent and verified in
`tools/recovery/usb-set-boot-slot.sh` - `sudo sh tools/recovery/usb-set-boot-slot.sh A` (or `B`). It
reads the real marker bytes, swaps only when needed, reads them back, and ends with `RESULT=OK` or
`RESULT=NOT_OK`. Note: once u-boot is loaded, a second `usbboot --uboot` fails until the next power
cycle; that is not an error.

3. **Load u-boot before you try to swap the marker** — the raw mask-ROM stage doesn't support that
   request at all, and running it first just fails with `Could not open USB device` or a transfer
   error.
   ```sh
   sudo ./usbboot --uboot
   sudo ./usbboot --swap-ota
   ```
   There's no `--force-swap-ota` flag — `--swap-ota` toggles between the two, it doesn't let you
   pick a side. It prints the state before and after, but see the next step: that output has been
   observed to be wrong, so treat it as a hint and never as confirmation.
4. **Don't trust that printed output on its own.** We saw two consecutive runs both print the exact
   same "before/after" text despite actually starting from different states — the raw USB-boot
   session doesn't reliably remember what happened in a previous invocation. Check the real bytes
   instead:
   ```sh
   sudo ./usbboot --uboot
   sudo ./usbboot -o 0x100000 -s 0x1000 --dump-partition ./ota.out
   xxd ./ota.out | head -3
   ```
   You want to see `ota:kernel` (stock) in there. If it still says `ota:kernel2`, run `--swap-ota`
   again and re-check until the actual bytes confirm you're on stock.
5. Power-cycle normally (or hit reset) to leave recovery mode and boot for real. It'll come up on
   stock.

This only touches the OTA marker partition — it doesn't flash a kernel or rootfs, and it doesn't
touch the bootloader or partition table.

### RTOS logo: restoring rtos2

The Hardware Agent's `rtos-logo` operation writes rtos2 (p4, offset `0x700000`, 4 MiB): the RTOS
image SPL loads before Linux whenever the marker is `ota:kernel2`. If that image is broken,
NebulaOS stops in SPL before Linux, so neither SSH nor `rtos-logo-restore` can reach it. Stock still
boots (it loads rtos, p3, which the agent never writes), but getting there needs the marker swap
above, and a power cycle into stock is what lets its updater reflash the MCU (§1). The direct fix
is to write the backup back over USB.

`rtos-logo` takes that backup before it writes anything:
`~/.local/state/nebulaos-hardware/rtos-backups/<device>/rtos2-<time>-<sha16>.bin` (the complete
4 MiB partition), next to a `.txt` with its sha256. Copy it to the recovery computer.

**Rehearse this with the user before the first `rtos-logo` write**, while rtos2 is still stock and
nothing is at stake:

1. Run `capture rtos-hashes` (read-only) and note `p4_sha256_full`, the sha256 of the whole rtos2.
2. Enter mask-ROM mode and load u-boot (§3 steps 1-3: buttons, `lsusb`, `sudo ./usbboot --uboot`).
   Use the pinned, patched `usbboot` (`INGENIC_USBBOOT_*` in `manifests/dependencies.conf`).
3. Read rtos2 over USB and compare it with the capture:
   ```sh
   sudo ./usbboot -o 0x700000 -s 0x400000 --dump-partition ./rtos2.usb
   sha256sum ./rtos2.usb      # must equal p4_sha256_full
   ```
   A match proves the offset, the size and the tool before anything is written.
4. Write that dump back. Its bytes equal what is there, so the rehearsal changes nothing:
   ```sh
   sudo ./usbboot --uboot
   sudo ./usbboot -o 0x700000 -s 0x400000 --write-partition ./rtos2.usb
   ```
   The patched tool reads back every chunk and prints `write complete and verified`.
5. Dump again (step 3), compare once more, then reset. NebulaOS must boot normally and
   `capture rtos-hashes` must report the same `p4_sha256_full`.

For a real recovery, run steps 2 to 5 with the agent's backup (taken before the failed write) in
place of `./rtos2.usb`, and compare against the sha256 in its `.txt`. **Check the
offset twice:** `0x700000` is rtos2. `0x300000` is stock's rtos, and `0x200000` is `sn_mac`, the
per-unit identity that cannot be regenerated. Never write either one.

## 4. Manual repair over SSH

If you can still SSH into either slot, you've got ordinary root access and normal shell tooling —
but there's no dedicated "repair script" beyond what's already covered above. We haven't built one,
and this doc isn't going to pretend one exists.

## 5. Full factory restore

Creality has its own official recovery images and USB flashing tooling that reinstalls everything —
bootloader, kernel, rootfs, the works — back to a genuinely factory-fresh state, using the same USB
mask-ROM mode as step 3 above. That's Creality's own tooling, though, not something NebulaOS
provides, pins, or has actually run as part of any of our own testing. If you need it, treat it as
Creality's procedure, not a documented NebulaOS recovery path.

## What actually survives a slot switch

| Data | What happens |
|---|---|
| `printer.cfg`, macros, `moonraker.conf` | Survives — lives in a dedicated directory this whole mechanism never touches |
| Z offset / calibration, bed mesh | Survives — saved into `printer.cfg` via `SAVE_CONFIG`, though we haven't specifically re-tested this exact scenario |
| NebulaOS's own WiFi credentials | Survives — confirmed on real hardware during a full persistent-state reset |
| Moonraker config/state | Survives — confirmed on real hardware |
| GuppyScreen config/theme | Survives — confirmed across a real flash during the Final Closure testing |
| G-code uploads | Survives — confirmed as part of a real backup |
| Logs | Don't survive, but that's expected — they rotate out every 7 days anyway |
| Mainsail config | Honestly not sure — haven't specifically checked this one |
| Camera config, timelapses | Same — not verified either way |

Stock keeps its own config in a separate area of the same shared `/usr/data` partition, so switching
to stock never touches NebulaOS's data and vice versa — see `A_B_SLOT_MODEL.md` for how that's
arranged.

## Related docs

- `docs/A_B_SLOT_MODEL.md` — the partition/marker mechanics behind all of this
- `docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md` — steps 2 and 3 above, written for a less technical reader
- `docs/DEVELOPER_UPDATE.md` — what to do instead if the device is healthy and you just want a newer version
