<!-- Hand-written. Unlike the generated reference pages in this wiki (Moonraker API,
     OSConfig helpers, Boot services, Runtime helpers, Build scripts and host tools),
     this page explains, and explanation cannot be extracted. Every factual claim
     names the file it came from so it can be re-checked. -->

# Architecture: two slots and how a printer starts

How a NebulaOS printer is laid out and how it starts. Written against `NebulaOS-firmware` at
`b95b156`. The shipping release is **1.0.2**, firmware `3bdf3ff` (tag `v1.0.2`); `main` has
moved on since, so read `manifests/dependencies.conf`, not this branch, for what a printer is
running.

The rest of the architecture is on its own pages: [Image install and the trial](Image-Install-And-Trial),
[Recovery](Recovery), [The black box](Black-Box), [Printer configuration](Printer-Configuration)
and [Building from source](Building-From-Source). For the exhaustive lists see
[Boot services](Boot-Services) and the [Moonraker API](Moonraker-API). This page is the part
those cannot give you: the reasoning, and one decision that is the opposite of what you would
expect.

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

36 services run in numeric order, and the order is the design. The full list is in
[Boot services](Boot-Services); the shape is:

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

## No automatic rollback to stock - and why that is not a brick

`S00revert-safety` used to write `ota:kernel` - the stock slot - on *every* boot, so that any
failure before the health check would land the next reboot on stock automatically.

It was **removed** in Phase 1.8B and the script is now an explicit no-op. Its header gives the
reason: booting the stock Creality slot auto-flashes the MCU with Creality's own firmware,
replacing the native GD32F303 build. An automatic fallback would have converted a software
failure - Klipper not starting - into an MCU firmware change nobody asked for.

**That is a reason to remove the automatic fallback. It is not a reason to call stock a
one-way door, and current code makes that clear.**

`S50nebulaos-mcu-guard` runs before Klipper and delegates to `mcu_lifecycle.py`, which
classifies the application the MCU is actually running:

| Classification | What happens |
|---|---|
| `NATIVE_CANDIDATE_001` | Healthy native build. Klipper starts; nothing is reflashed. |
| `KNOWN_STOCK` | `SUPPORTED_HW_KNOWN_STOCK_APP` → `RESTORE_AUTHORIZED`. `mcu_restore.py` reinstalls the built-in native firmware automatically. |
| `UNKNOWN_APPLICATION` | **Never auto-flashed.** Whatever is there is kept. |

So the symmetry is the point: **stock reinstalls its MCU firmware at a cold boot, and NebulaOS
reinstalls its own at boot too.** Each system restores what it needs, and moving between them is
self-correcting in both directions.

`mcu_restore.py` is bounded rather than best-effort: a single attempt, SHA256 verification of
the on-device artifact against a pinned value, and a hardware identity allow-list checked both
before any erase or write and again after bootloader entry.

The `UNKNOWN_APPLICATION` branch is the considered part. A firmware the user installed
deliberately - through NebulaScreen's own MCU page, from a Mainsail upload or a USB stick - is
not recognised as stock, so it is left alone. The automation only undoes the one thing it can
identify as not-ours.

### What this means for documentation

Older documents in this repository predate `mcu_restore.py` and describe the Phase 1.8B
situation, where a stock boot genuinely left the MCU mismatched until someone intervened. Where
they conflict with the behaviour above, **the code wins.** `docs/DEVELOPER_RECOVERY.md` and
`docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md` carry corrections to that effect.

The genuine remaining caution is the ordinary one: **do not cut power while an MCU flash is in
progress.** NebulaScreen says so on screen while it runs one.

### The health check that remains

`S99confirm-good` still runs, and no longer writes the marker on any path. It is kept for
diagnostics, and its history is instructive.

The original version asked Moonraker's `/server/info` for *any* result - which is true the
instant Moonraker's HTTP listener is up, **regardless of whether Klipper ever connected to the
MCU**. That gap was found live. It now checks the `klippy_state` field, which returns `ready`
only once Klipper has loaded its config and connected the MCU.

A good reminder that "the service started" and "the service works" are different questions, and
that a health check answering the first one while claiming the second is worse than no check.


## What this page does not cover

- **Hardware behaviour.** Nothing here was observed on a printer; it is read from source.
- **Buildroot internals and the kernel.** The kernel's own changes are in
  [NebulaOS-kernel's wiki](https://github.com/NebulaOS-KE/NebulaOS-kernel/wiki).
- **The 58 runtime helpers** outside `/etc/init.d` are listed in
  [Runtime helpers](Runtime-Helpers); this page covers only the ones that matter to boot and
  slots.
