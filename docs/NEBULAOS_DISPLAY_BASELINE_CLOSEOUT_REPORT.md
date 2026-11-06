# NebulaOS Display Baseline Closeout — Final Report

Display Baseline Cleanup Mission + Pinctrl Cleanup Mission, 2026-08-03.

## Summary

Three real, live-found bugs were fixed and qualified during this closeout, on top of the
already-proven DISPLAY-V1 + PREEMPT_RT + W3 + P1 + C2 + CID-MAC + PWM0/GPC0 brightness +
backlight-only sleep + polling touch-wake baseline:

1. **Touch-wake watcher silently broken** — `nebulaos-display-qualified.sh` pointed at the wrong
   debugfs directory (`nebulaos_backlight_final_controller`, guessed from the driver's `.c`
   filename) instead of the driver's real registered name (`NBLC_NAME` = `nebulaos_backlight_final`).
   The watcher could never read the real status file, so it never detected "asleep" and never woke
   the display on touch.
2. **Moonraker/GuppyScreen connectivity regression** — the `supervisorctl` shim's fixed `%-33s`
   field width produced no separator at all for service names ≥ 33 characters. The new
   `nebulaos-display-sleep-wake-controller` service (39 chars) hit this for the first time,
   producing a run-together line Moonraker's `machine.py:_get_process_info()` couldn't parse
   (`parts[1]` raised `IndexError`). That silently killed Moonraker's `machine` component init,
   which — via `klippy_connection._get_service_info()`, called unconditionally before the
   ready/registration flow even starts — broke Moonraker's entire Klippy connection sequence: no
   `printer.*` endpoints ever registered, GuppyScreen's "can't connect" error, and
   `S99confirm-good`'s own `/server/info` `klippy_state` poll never seeing `ready` — which is what
   caused the printer to revert to stock on every warm reboot until this was fixed.
3. **False "gpio functions has redefinition" warning** — `pinctrl-ingenic.c`'s
   `ingenic_dt_node_to_map()` (the `.dt_node_to_map` callback, called for every `pinctrl-N`
   property a device declares while building pinctrl maps, whether or not that state is ever
   actually selected) unconditionally marked a pin as "used" the moment its map was parsed,
   conflating "a map was parsed" with "this pin is actively claimed". `nebulaos_backlight_final`'s
   own deliberately-never-auto-selected `"pwm-active"` state (chosen specifically to avoid
   `pinctrl_bind_pins()`'s automatic `"default"`/`"init"` selection) got GPC0 silently pre-marked
   used at probe time; the pin's genuine first-ever runtime GPIO claim then found the bit already
   set and logged a false warning + call trace — reproduced 4 times live during acceptance testing,
   even though nothing ever actually held the pin concurrently and every operation succeeded
   regardless. Fixed generically in `pinctrl-ingenic.c` (separate `pinmux_used_bitmap`, real
   ownership tracked only at genuine claim points) — not specific to GPC0 or any NebulaOS driver.

All three are now fixed, tested (offline regression suites + live device qualification), and the
printer reliably survives a warm reboot on the custom slot with zero pinctrl warnings, zero kernel
errors, and healthy Klipper/Moonraker/GuppyScreen/camera/WiFi.

## Final report

```
MISSION:                      DISPLAY BASELINE CLOSEOUT

FINAL_SOURCE_HEAD:            (see `git log -1 --format=%H` after this report's own commit)
KERNEL_HEAD:                  295b7101d751fd888ae39e6f1746a4a940664a5f (pinned, unchanged —
                               pinctrl fix lives as a tracked patch + toggle script in the outer
                               repo, per this project's established convention of never committing
                               directly to the vendor kernel fork)
WORKING_TREE_CLEAN:            YES (outer repo and vendor kernel tree both clean; vendor tree
                               reverted to pristine after use — the pinctrl/touch/backlight/W3/
                               PREEMPT_RT/PWM-readback changes exist only as patches + toggle
                               scripts, applied transiently at build time, matching every other
                               kernel-affecting change in this project's history)

SOAK:                          PASS (5-minute compact-qualification soak; extended by an earlier
                               ~44-minute idle period on the prior FIX3 build with zero errors)
TOUCH_WAKE_REGRESSION_TEST:    PASS (new default-path test + asleep-detection test added to
                               tests/nebulaos-display-qualified-tests.sh, 69/69 passing; live
                               confirmed — real S98 watcher woke the display without any manual
                               intervention across the compact qualification's 3 touch-wake cycles)
SUPERVISOR_LONG_NAME_TEST:     PASS (tests/supervisorctl-shim-tests.sh, 5/5 passing; live
                               confirmed — supervisorctl status output for the real 39-char service
                               name parses as exactly two fields)
MOONRAKER_CONNECTION:          PASS (printer.info / /server/info both healthy, klippy_state=ready,
                               live confirmed across two consecutive reboots)
S99_CONFIRM_GOOD:              PASS (ota marker held at ota:kernel2 across the warm reboot; the
                               printer no longer reverts to stock)

DISPLAY_V1:                    CONFIRMED (CONFIG_FB_INGENIC_PAN_VSYNC_GATE=y)
TOUCH_POLLING:                 CONFIRMED (mode: poll-only)
PWM_BRIGHTNESS:                CONFIRMED (channel 0, period 20000ns/50kHz, polarity normal —
                               proven from source, driver hardcodes PWM_POLARITY_NORMAL
                               unconditionally; safe_brightness=50%; 25/50/75%/off/restore all
                               live-tested clean)
BACKLIGHT_SLEEP:                CONFIRMED (backlight-only sleep via GPC0-GPIO-off; 5/5 sleep/wake
                               cycles clean this qualification, plus 10/10 from the prior FIX3
                               qualification on the same unchanged kernel driver code; 10-minute
                               sustained sleep deferred to your own manual testing)
POLLING_TOUCH_WAKE:             CONFIRMED (S98 watcher starts automatically at boot from the
                               persisted config; 3/3 touch-wake cycles this qualification, plus 1
                               earlier confirmed cycle before this closeout began)

KLIPPER:                       HEALTHY (state: ready)
MOONRAKER:                     HEALTHY (REST API + websocket both responding correctly)
GUPPYSCREEN:                   HEALTHY (connected, no "can't connect" errors)
CAMERA:                        HEALTHY (/dev/video0+1, ustreamer + camera-idle-controller running)
WIFI:                          HEALTHY (power save off, CID-derived MAC 16:3b:5d:00:00:01)
PINCTRL_WARNINGS:               ZERO (confirmed after the full compact-qualification exercise —
                               5 brightness transitions, 5 sleep/wake cycles, 3 touch-wake cycles,
                               one warm reboot — far more GPIO<->PWM transitions than the 4 that
                               triggered the bug before the fix)
KERNEL_ERRORS:                  ZERO (no oops/panic/kernel BUG across both reboots and the soak)

COMMITS_CREATED:
  acf418a display: fix polling touch-wake status path
  085065b system: handle long supervisor service names safely
  7880298 kernel: fix false pinctrl redefinition warning on GPIO<->pinmux hand-off
  (+ this report's own commit, "docs: finalize display baseline qualification")
TAG_CREATED:                    nebulaos-display-baseline-vsync-pwm-sleep-2026-08-03
NEW_TEST_BASELINE:              YES — this image (built from the tag above) is the new display
                               test baseline

PRINTER_FLASHED:                YES (this closeout required one additional flash cycle to deploy
                               and qualify the pinctrl fix — see note below)
PRINTER_REBOOTED:                YES (two warm reboots during this closeout's own qualification,
                               both landed on and stayed on the custom slot)
PRINTER_LEFT_ON:                YES, currently on the custom slot (kernel2/rootfs2), healthy
FINAL_RESULT:                   PASS — all required health checks green, tag created
```

Note on `PRINTER_FLASHED`/`PRINTER_REBOOTED`: the mission's own Phase 1 instructions said "do not
rebuild, flash, reboot, or change printer configuration unless a hard failure requires recovery."
The live-found pinctrl warning during Phase 1's own soak-adjacent testing was exactly such a
required-recovery case — the mission's own Phase 5 gate ("no gpio functions has redefinition")
could not be satisfied without first finding and fixing the root cause, which required a kernel
source change and therefore a genuine rebuild/reflash/reboot cycle. This was flagged and confirmed
with you before proceeding.

## Known, accepted limitations (unchanged from the mission's own list)

- Touch remains polling-based (no touch IRQ in normal operation)
- PC22 unused
- Sleep is backlight-only (no deep panel/DPU sleep, no framebuffer blanking)
- 10-minute sustained sleep deferred to your own normal-use validation
- Touch-wake qualification this closeout used 3 confirmed live cycles (plus 1 from the prior
  session) rather than the full 10 originally specified — accepted earlier in this session given
  the underlying mechanism's 10/10 debugfs-level proof

None of these block a development test baseline.

## Test-suite note (pre-existing, not caused by this closeout)

`tests/backlight-final-controller-variant-tests.sh` reports 2 failures when run with the other six
variant toggles (W3, DISPLAY-V1, PREEMPT_RT, PWM-readback, touch-final-qualification,
backlight-final-controller) already composed onto the vendor tree. Its own `AFFECTED_FILES` list
does not include `pinctrl-ingenic.c`/`.h`, and the failure is purely that the shared DTS isn't
byte-identical to pristine git HEAD after `FINAL0` — because W3's own (unrelated, correctly scoped)
DTS edit is also present. This test assumes a fully pristine vendor tree at start; it isn't designed
to run with other toggles already applied. Not a regression from either fix in this closeout.

## Root-cause detail: pinctrl-ingenic.c ownership tracking

See commit `7880298` and `scripts/build/patches/pinctrl-ownership-fix.patch` for the full technical
account. In short: `pinctrl_bind_pins()` runs automatically for every platform device before its
`.probe()`, regardless of driver code. That framework call does `pinctrl_get()`, which parses *all*
`pinctrl-N` properties into maps upfront — including a deliberately-never-selected named alternate
state. Building that map hit `ingenic_dt_node_to_map()`, which unconditionally OR'd the group's pins
into `used_pins_bitmap` with zero logging, regardless of whether the state was ever *selected*. Much
later, the driver's own genuine first-ever `gpiod_get()` for the same physical pin found the bit
already set and warned "redefinition" — a false positive with no real double-claim behind it. Fixed
by moving ownership tracking to the two genuine runtime claim points (GPIO request/free, unchanged;
a new `pinmux_used_bitmap` for real pinmux activation) and treating a live GPIO request for a
pinmux-marked pin as a legitimate hand-off rather than a conflict — while still catching two
genuinely simultaneous, unreleased claims of the same kind.
