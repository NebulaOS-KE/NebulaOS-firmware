<!-- Hand-written. Unlike MOONRAKER-API.md and BOOT-SERVICES.md in this directory,
     this page is not generated - it explains, and explanation cannot be extracted.
     Every factual claim names the file it came from so it can be re-checked. -->

# Boot, slots, updates and recovery

How a NebulaOS printer starts, how it updates itself, and what happens when that goes wrong.
Written against `NebulaOS-firmware` at `832314d`.

For the exhaustive lists see [BOOT-SERVICES.md](BOOT-SERVICES.md) and
[MOONRAKER-API.md](MOONRAKER-API.md). This page is the part those cannot give you: the
reasoning, and one decision that is the opposite of what you would expect.

## Two slots and a marker

The printer's eMMC holds **two complete systems**:

| Slot | Kernel | Root filesystem | Marker value |
|---|---|---|---|
| A | `p5` | `p7` | `ota:kernel` |
| B | `p6` | `p8` | `ota:kernel2` |

Which one starts is decided by a **marker written into the OTA partition** - not by a
bootloader menu or a config file. `nebulaos-slot-swap` writes it and reads it back, exiting
non-zero if the read-back does not match.

A third area, the data partition, holds your configuration, calibration and print files and
belongs to neither slot. That is what makes switching systems non-destructive.

### The marker's exact bytes matter

`/etc/ota_marker.sh` writes `"ota:kernel\n\n"` into a zeroed 512-byte buffer, and the comment
explains why that precise form:

- Creality's own stock `ota_utils.sh` writes it that way.
- `ballaswag/ingenic-usbboot`'s `swap_ota_partition()` writes it that way.
- usbboot's read-check is `strncmp(ota, "ota:kernel\n", 11)`.

So a bare `echo -n "ota:kernel"` - ten bytes, no trailing newline - would **not** match, and
usbboot would treat the marker as an unexpected value unless forced. The script exists
specifically to avoid that mismatch, and its output was verified byte-for-byte against a live
device's raw partition dump.

The lesson generalises past this one file: NebulaOS has to interoperate with two other tools
that already write this marker, so "a string in a partition" is really a three-way wire format.

### Telling which system a slot holds

`ota_slot_holds_nebulaos()` reads the slot's kernel uImage name: a 6.x kernel is NebulaOS, and
the other system's is 4.4. Unreadable, or anything else, counts as not NebulaOS. That is how
the screen can tell you what is in the other slot before you switch into it.

## Starting up

35 services run in numeric order, and the order is the design. The full list is in
[BOOT-SERVICES.md](BOOT-SERVICES.md); the shape is:

| Stage | What happens |
|---|---|
| `S00` | Marker policy, zram swap |
| `S01` | Persistent datastore mounted, clock restored, Wi-Fi, splash |
| `S02`-`S05` | Namespace, watchdog, early SSH, migration, factory seed, **activation** |
| `S4x`-`S5x` | Cleanup, memory guard, MCU guard, Klipper, Moonraker, NebulaScreen |
| `S9x` | Display controllers, update supervisor, image trial, housekeeping, health check |

Three of those deserve attention.

**`S01persistent-datastore`** comes up early because almost everything later needs somewhere
writable. The image's root filesystem is read-only.

**`S05nebulaos-activate`** composes the NebulaOS Klipper extensions into the Klipper checkout
as excluded symlinks, and does the same for the `nebulaos.py` Moonraker component. If a printer
shows no OS settings, or Klipper reports a missing module, this is the service to suspect -
before suspecting the file.

**`S01restore-clock`** exists because the KE has no battery-backed clock. Until NTP answers,
every boot would start at 2020-03-01, so early log lines and files would carry a 2020 date.
It restores the last saved time, in the manner of `fake-hwclock`. Worth knowing before
debugging a timestamp.

## The decision that is the opposite of what you expect

**There is no automatic rollback to the stock system, and that is deliberate.**

`S00revert-safety` used to write `ota:kernel` - the stock slot - on *every* boot, so that any
failure before the health check would land the next reboot on stock automatically. Classic
watchdog-style safety.

It was **removed** in Phase 1.8B, and the script is now an explicit no-op. The reason, from its
own header: *booting the stock Creality slot auto-flashes the MCU with old Creality firmware,
destroying the qualified native GD32F303 MCU build.*

So the automatic safety net was itself the larger hazard. Falling back to stock would have
turned a software failure - Klipper not starting - into a hardware one, needing the MCU
reflashed. The risk of silently bricking the MCU outweighed the convenience of automatic
rollback.

**What happens now:** if Klipper fails to reach ready, the printer stays on NebulaOS and waits
for manual recovery. Nothing is undone for you.

This is also the root of the warning users see throughout the manual - *never power-cycle a
printer running the stock Creality system*. Same mechanism: a stock power-on reflashes the MCU.
One hardware behaviour, two consequences, and they are worth recognising as the same fact.

### The health check that remains

`S99confirm-good` still runs, and no longer writes the marker on any path. It is kept for
diagnostics, and its history is instructive.

The original version asked Moonraker's `/server/info` for *any* result - which is true the
instant Moonraker's HTTP listener is up, **regardless of whether Klipper ever connected to the
MCU**. That gap was found live. It now checks the `klippy_state` field, which returns `ready`
only once Klipper has loaded its config and connected the MCU.

A good reminder that "the service started" and "the service works" are different questions, and
that a health check answering the first one while claiming the second is worse than no check.

## Installing a system image

A system image is written into the slot that is **not** running, so the running system is never
touched. Then the printer restarts into it.

The API path is `machine.nebulaos.image.*` - `list`, `status`, `check`, `install`, `ack` - and
the work happens in `nebulaos_osconfig/image.py`. Images can come from a USB stick, a Mainsail
upload, or an online download (`machine.nebulaos.ota.*`).

### The trial, and why it is bounded two ways

After an install from the screen, the new slot starts **on trial**. From
`nebulaos_osconfig/image.py`:

- `TRIAL_SECONDS = 300` - five minutes to come up.
- `TRIAL_ATTEMPTS = 3` - three starts that never confirm.

Either bound exhausting switches back to the previous slot, once, automatically.

Two bounds rather than one, because there are two distinct failure shapes. A system that hangs
needs a timeout. A system that crashes and reboots cleanly would reset a timeout forever, so it
needs an attempt count instead. One without the other leaves a gap.

A screen shed by the memory guard counts as a successful start, and a power cut during the trial
makes the trial run again on the next boot.

**This trial applies only to installs from the screen.** An install through Creality's own
updater has no trial at all, which is worth knowing when comparing the two routes.

Note how this coexists with the previous section: there is no automatic fallback to *stock*,
but there *is* an automatic fallback between two NebulaOS slots. The difference is that
switching between NebulaOS slots does not touch the MCU.

## Recovery, in order of severity

1. **The automatic trial** - nothing to do; covered above.
2. **Swap the boot slot from the screen** - `machine.nebulaos.system.swap_slot`, which calls
   `nebulaos-slot-swap`. Blocked while printing.
3. **SSH** - both NebulaOS and stock accept `root`. Steps are in
   `docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md`.
4. **USB recovery** - the SoC's mask ROM, which works when no system starts at all. Two very
   different operations live here: `tools/recovery/usb-set-boot-slot.sh` rewrites only the
   marker and erases nothing, while writing a full `.ingenic` image rewrites the printer and
   **erases the data partition**. See `docs/DEVELOPER_RECOVERY.md`.

Only the last of those loses data. The manual presents them in this order for that reason.

## Building an image

14 numbered scripts in `scripts/build/`, run in order:

| Script | Stage |
|---|---|
| `00-fetch-vendor-sources.sh` | Fetch pinned sources |
| `01-apply-kernel-patches.sh` | Patch the kernel |
| `02-configure-buildroot.sh` | Configure Buildroot |
| `03-build-kernel-and-rootfs.sh` | Build kernel and root filesystem |
| `04-cross-compile-app-stack.sh` | Cross-compile the application stack |
| `05-final-build.sh` | Assemble |
| `06-verify.sh` | Verify the result |

Plus `package-deployment.sh`, `package-variant-artifacts.sh`, `generate-sbom.sh`,
`assert-baseline-config.sh`, `baseline-difference-gate.sh`, `build-qualified-baseline.sh` and
`nebulaos-post-build.sh`.

What each component is pinned to lives in `manifests/dependencies.conf`, and **that file is the
shipping authority**. A component repository's tip is not what ships; the pin is. The two
differ routinely, and confusing them is the easiest way to document a feature that no printer
has.

## Things not covered here

- **Hardware behaviour.** Nothing on this page was observed on a printer.
- **Buildroot internals and the kernel.** See the kernel repository.
- **Response shapes for the API.** Produced by the `nebulaos-osconfig` helper at runtime;
  `nebulaos_osconfig/` and `tests/nebulaos-osconfig-tests.py` are the places to read them.
- **The 56 runtime helpers** in the overlay outside `init.d`, individually.
