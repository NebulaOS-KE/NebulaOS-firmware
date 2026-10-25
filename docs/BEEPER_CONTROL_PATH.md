# Beeper Control Path

> **Superseded by G108 (Run 19, 2026-10-24).** The kernel now muxes GPC3 to PWM channel 3
> (`/sys/class/pwm/pwmchip0/pwm3`); Klipper's `nebulaos_beeper` extra (NebulaOS-klipper-extensions)
> is its only owner. M300/BEEP/PLAY_TUNE (`etc/nebulaos/klipper/beeper.cfg`) call that extra and never
> hold the G-code queue; the screen's touch click is a request to the Klippy API endpoint
> `nebulaos_beeper/click`. No `gcode_shell_command`, no `/dev/mem`. The trace below is the
> pre-G108 path, kept as history.

Part of the "Nebula Pad beeper and audio-pin conflict investigation" (2026-07-23). Traces the
complete, real control path for the hardware buzzer from GuppyScreen/Klipper source down to the
physical pin, and proves - via source reading plus live register/IRQ verification on real hardware,
not inference - that it is entirely independent of the ASoC sound card, BAIC4, and DMIC.

## Complete call chain

```
GuppyScreen touch event (LV_EVENT_CLICKED on any clickable widget)
  -> TouchBeep::feedback_cb()          [src/touch_beep.cpp:60]
     - gated on s_enabled (opt-in, /touch_beep config key, off by default)
     - 120ms debounce (DEBOUNCE_MS)
  -> TouchBeep::beep()                 [src/touch_beep.cpp:37]
     - double-fork so the UI thread never blocks on the buzzer pulse
  -> execl("/usr/data/guppyscreen/guppybeep", "guppybeep", "click")
  -> guppybeep click [freq] [ms] [duty%]   (defaults: 260 Hz, 4 ms, 2% duty)

Klipper M300/BEEP gcode macro                      [k1/scripts/guppy_cmd.cfg]
  -> RUN_SHELL_COMMAND CMD=guppybeep PARAMS="m300 S<freq> P<ms>"
  -> Moonraker gcode_shell_command
  -> /usr/data/guppyscreen/guppybeep m300 S<freq> P<ms>

Both converge on the same binary:
  guppybeep (k1/k1_mods/buzzer/guppybeep.c)
  -> open("/dev/mem") + mmap() on two fixed physical addresses:
       PWM_BASE = 0x134c0000   (the SoC's real PWM controller, channel 3)
       GPC_PAGE = 0x10010000, offset 0x200  (GPIO Port C controller)
  -> direct register writes:
       - GPIO Port C: mux pin 3 (PC03) to its PWM device function (func0),
         saving the pin's original GPIO state first and restoring it on
         exit/signal (SIGINT/SIGTERM handled) so /usr/bin/beep still works
         afterward
       - PWM controller: program PWMCCFG0 (prescale), PWMWCFG(3) (high/low
         cycle counts for the requested frequency+duty), PWMLVL, PWMOEN,
         PWMENS, PWMUPDATE - entirely hand-rolled, not through any kernel
         PWM API
  -> physical PC03 pin toggles at the programmed frequency -> piezo buzzer
```

**Why guppybeep bypasses the kernel PWM/pinctrl frameworks entirely** (from the source's own header
comment): "the vendor `/dev/jz_pwm` driver fails to [mux PC03 to its PWM device-function] - so we
program the GPIO port-C controller directly." This is a deliberate, documented workaround for a real
vendor-driver limitation, not an oversight.

## Real bug found and fixed along the way

Both trigger paths hardcode `/usr/data/guppyscreen/guppybeep` (the real stock filesystem's actual
install path) - but this project's own Buildroot overlay stages GuppyScreen under `/opt/guppyscreen`
instead, and `/usr/data` is fresh tmpfs every boot (`S01tmpfs-datastore`), so nothing ever bridged the
two paths. **Both the touch-feedback beep and the M300/BEEP gcode macros were silently failing on
every custom boot** until this investigation found it - confirmed live: `/usr/data/guppyscreen`
didn't exist at all before the fix. Fixed by adding `ln -sf /opt/guppyscreen /usr/data/guppyscreen`
to `S01tmpfs-datastore`, immediately after the tmpfs seeding it depends on.

## Live verification on real hardware (not just source reading)

| Check | Result |
|---|---|
| `/sys/bus/platform/devices/134c0000.pwm` exists | Yes - same physical address `guppybeep.c` targets directly, confirming it's the real hardware PWM controller |
| `dmesg`: `ingenic-pwm 134c0000.pwm: ... Probe of pwm success!` | Confirmed |
| `/sys/class/pwm/pwmchip0/npwm` | `16` channels total; channel 3 (`CH` in guppybeep.c) is the one used |
| Any channel exported via `/sys/class/pwm/pwmchip0/pwmN`? | No - nothing uses the kernel's own PWM sysfs interface, consistent with guppybeep's direct-`/dev/mem` approach |
| `GPC-3` (pin 67) pinctrl/GPIO ownership, before running guppybeep | `(MUX UNCLAIMED) (GPIO UNCLAIMED)` - not claimed by anything |
| `GPC-3` ownership, immediately after `guppybeep tone 1000 300` | **Still `(MUX UNCLAIMED) (GPIO UNCLAIMED)`** - guppybeep's raw register writes are entirely invisible to kernel pinctrl/gpiolib bookkeeping, exactly as its own source comments describe |
| `as-dma` IRQ counter (`/proc/interrupts`), before | `0` / `0` |
| `as-dma` IRQ counter, immediately after `guppybeep tone 1000 300` | **`0` / `0` - unchanged** |
| `/proc/asound/cards`, at any point | `--- no soundcards ---` - no ALSA card is registered on this build at all (see the DMIC section of `docs/BOOT_WARNING_AUDIT.md` / `docs/BAIC4_AUDIO_INVESTIGATION.md`) |
| Open file descriptors on `/dev/pwm*`/`/dev/snd*`/`/dev/mem` across all processes, after the beep | None held open - `guppybeep` is a short-lived process, exits immediately after the pulse |
| `guppybeep tone 1000 300` exit code | `0` (success) |

## Conclusion

**Proven, not assumed**: the beeper's entire control path - both GuppyScreen's touch-feedback tick
and Klipper's M300/BEEP macros - runs through `guppybeep`, which drives `GPC-3`/PWM-channel-3 via
direct physical-memory register access, entirely bypassing the kernel's PWM subsystem, ALSA, ASoC,
BAIC, and DMIC. `GPC-3` (GPIO Port **C**, offset 3) is a different physical bank from `GPD-2`
through `GPD-5` (GPIO Port **D**), which is what BAIC4's `baic4_pd` pinctrl group and
`wlan_reg_on`/`bt_reg_on` actually contend over - the beeper was never a candidate for that conflict
in the first place. This closes the "working hypothesis" stated in the mission brief with direct,
live, real-hardware evidence rather than inference.
