# The printer configuration the image ships

Which repository owns Klipper's configuration values, and the two 1.0.2 changes most likely to
explain a print behaving differently from an older document. Read against `NebulaOS-firmware`
at `b95b156`. `print.cfg`, `machine.cfg` and `calibration.cfg` are byte-identical between that
commit and the 1.0.2 release `3bdf3ff`, so everything below is what a 1.0.2 printer runs.

Klipper's configuration is **firmware-owned**, not user-owned: ten files in
`scripts/build/overlay/etc/nebulaos/klipper/` (`machine.cfg`, `print.cfg`, `calibration.cfg`,
`prtouch.cfg`, `homing.cfg`, `filament.cfg`, `platform.cfg`, `camera.cfg`, `beeper.cfg`,
`z_offset_probe.cfg`). They ship in the image, which is why a change here is a firmware change
and not a settings change, and why the Klipper extensions repository documents the *commands*
while this repository owns the *values* they run with.

Two of those values changed for 1.0.2 and are worth knowing when a print behaves differently
from the documents:

**`START_PRINT` resets speed and flow, and takes the slicer's firmware retraction.**
`print.cfg` now issues `M220 S100` and `M221 S100` at the start of every print, so a tune left
over from the previous print cannot carry over and the slicer's start G-code needs nothing but
the `START_PRINT` line. It also reads four optional parameters - `RETRACT_LENGTH`,
`RETRACT_SPEED`, `UNRETRACT_SPEED`, `UNRETRACT_EXTRA_LENGTH` - and passes them to
`SET_RETRACTION`, so a slicer with *Use firmware retraction* on drives `G10`/`G11` with its own
numbers. The rules, all in the macro: a parameter that is not passed keeps the current value
(`[firmware_retraction]` in `machine.cfg` after a restart, or what the screen set); a speed
below Klipper's 1 mm/s minimum is not sent; an unretract speed of `0` is the slicer's "same as
retraction" and takes `RETRACT_SPEED`; lengths are clamped at `0`. The values actually applied
are echoed with `RESPOND`, which is what to ask for in a support thread. `SET_RETRACTION` is
only issued when `firmware_retraction` is present in `printer`. Covered by eight cases in
`tests/print-start-end-macro-tests.py`.

**The input shaper test envelope is stock again: 90 Hz, 70 mm/s² per Hz.** `max_freq: 90` and
`accel_per_hz: 70` in `[resonance_tester]` (`machine.cfg`), with the same pair as
`shaper_freq_end` / `shaper_accel_per_hz` in `[nebulaos_calibration]` (`calibration.cfg`) for
the guided workflow. The narrower 80/50 envelope was a workaround for *Timer too close* near
80 Hz on the PREEMPT_RT kernel; with 1.0.2 on `CONFIG_PREEMPT` that workaround is no longer
needed, and the values match Creality's own stock `printer.cfg`. **A direct
`SHAPER_CALIBRATE` / `TEST_RESONANCES` uses the `[resonance_tester]` pair; the guided
calibration passes the `[nebulaos_calibration]` pair** - they are kept identical, and a reader
comparing one document against the other should check both.


The *commands* these files configure are documented in the Klipper extensions wiki:
[NebulaOS-klipper-extensions](https://github.com/NebulaOS-KE/NebulaOS-klipper-extensions/wiki).
This repository owns the values they run with.
