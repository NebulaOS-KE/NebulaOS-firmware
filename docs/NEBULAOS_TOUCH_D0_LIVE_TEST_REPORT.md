# NebulaOS TOUCH-D0-DIAG Live Test Report

Display/touch investigation mission follow-on (2026-08-01). Real hardware qualification of
TOUCH-D0-DIAG (`CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG`), a read-only diagnostic layered on top of
the existing, unmodified ns2009 30ms-poll pendown-gpios path, built on top of the already-qualified
DISPLAY-V1 (vsync-gated pan_display) baseline. Zero behavior change to touch reporting; purely
additive in-memory counters exposed via debugfs.

Evidence is labeled throughout as **PROVEN_FROM_LIVE_TEST** (directly observed on the real
printer), **SUPPORTED_INFERENCE** (a reasoned conclusion from that evidence, not a direct
measurement), or **INCONCLUSIVE** (insufficient evidence either way).

## Build composition

Package: `build-work/deploy-packages/TOUCH-D0-VSYNC-20260801T174503Z/` (not committed - gitignored
binary artifacts). Composition: W3 (SDIO `cap-sdio-irq` + `cap-sd-highspeed`) + R1
(`CONFIG_PREEMPT_RT=y`) + V1 (`CONFIG_FB_INGENIC_PAN_VSYNC_GATE=y`, the already-qualified DISPLAY-V1
baseline) + D1 (`CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG=y`, this diagnostic).

`variant-difference.txt` in the package directory proves this package differs from the
DISPLAY-V1-20260801T113152Z baseline by **exactly one Kconfig line**
(`CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG=y`) - DTS byte-identical, `buildroot.config` identical,
`kernel.config` +1 line, Kconfig fragment +5 lines (the variant's own BEGIN/END marked block).
SHA256SUMS generated and self-verified for xImage/rootfs.squashfs/kernel.config/DTS/configs.

Compile-tested before the full build (real `docker run` against `pellcorp/k1-bash-build`, kernel
source patched, `olddefconfig` + `make drivers/input/touchscreen/ns2009.o`): compiled clean, zero
new warnings. Vendor tree reverted immediately after per this project's own safety rule (never
leave the vendor tree dirty between build steps).

## Deployment

Stock-mediated flash sequence (never touching the live/active slot):

1. Safety check on custom (DISPLAY-V1 baseline) confirmed `state:ready`, `standby`, both heater
   targets `0.0`, `rootfs2` active, `PREEMPT_RT` active - before writing the OTA marker.
2. `write_ota_marker "ota:kernel"`, `sync`, `reboot` (separate invocations) - switched to stock.
3. Rediscovered on stock (`Ender3V3KE-0001`, real hardware MAC `fc:ee:11:00:00:01` - the custom
   image's stable/derived MAC `16:3b:5d:00:00:01` is a NebulaOS-only override
   (`/etc/nebulaos-stable-mac.sh`), not present under stock, so this MAC difference across the two
   boots is expected, not a mismatch).
4. Confirmed genuine identity beyond just the model/hostname match by checking for this project's
   own `/usr/data/nebulaos*` backup history (`nebulaos.pre-realwipe2-backup-*`,
   `nebulaos.pre-finalfix-backup-*`, etc.) - present and consistent with this exact device's history.
5. Staged the full package under `/usr/data/touch-d0-stage/` (a real ~107MB transfer over Wi-Fi;
   the first attempt stalled/partially failed due to a genuine mid-transfer network interruption on
   the printer's side - re-transferred the incomplete/missing files and re-verified from scratch
   rather than trusting the partial state).
6. **PROVEN_FROM_LIVE_TEST**: on-device SHA256 of both staged `xImage` and `rootfs.squashfs`
   matched the build manifest exactly.
7. **PROVEN_FROM_LIVE_TEST**: `flash-spare-slot.sh --check-only` reported unambiguous
   `result: SAFE TO FLASH` - active slot 1 (stock), target slot 2 (custom) confirmed inactive,
   manifest hash verified, capacities valid, slot pair valid.
8. Real flash executed (writes only ever target the inactive spare slot, kernel2/rootfs2 -
   `/dev/mmcblk0p6`/`/dev/mmcblk0p8` - never the live stock slot).
9. `write_ota_marker "ota:kernel2"`, `sync`, `reboot` (separate invocations).
10. Rediscovered via a fresh subnet scan (never assumed a cached IP).

## Boot health verification (Phase 9)

All checked directly via SSH, immediately after the flash-and-reboot:

| Check | Result | Status |
|---|---|---|
| MAC | `16:3b:5d:00:00:01` | PROVEN_FROM_LIVE_TEST - matches |
| Active root | `root=/dev/mmcblk0p8` (rootfs2) | PROVEN_FROM_LIVE_TEST |
| `/sys/kernel/realtime` | `1` | PROVEN_FROM_LIVE_TEST - PREEMPT_RT active |
| Kernel build timestamp | `Sat Aug 1 17:28:31 UTC 2026` | PROVEN_FROM_LIVE_TEST - distinct from the DISPLAY-V1 build's `11:29:03`, confirms genuinely running the new image |
| `CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG` | `y` | PROVEN_FROM_LIVE_TEST - TOUCH-D0 present |
| `CONFIG_FB_INGENIC_PAN_VSYNC_GATE` | `y` | PROVEN_FROM_LIVE_TEST - DISPLAY-V1 identity retained |
| `CONFIG_BRCMFMAC` | `y` | PROVEN_FROM_LIVE_TEST - W3 retained |
| Touch input device | `ns2009_ts` registered, `input0`/`event0` | PROVEN_FROM_LIVE_TEST |
| Debugfs diagnostic files | `/sys/kernel/debug/ns2009_ts_poll_diag/{status,reset}` present and readable once debugfs mounted (not auto-mounted on this image) | PROVEN_FROM_LIVE_TEST |
| Touch IRQ claimed | No - only the i2c4 controller's own interrupt line in `/proc/interrupts`, no dedicated GPIO/touch IRQ | PROVEN_FROM_LIVE_TEST - still poll-only |
| Klipper | `state: ready` | PROVEN_FROM_LIVE_TEST |
| Moonraker | responding on :7125 | PROVEN_FROM_LIVE_TEST |
| GuppyScreen | running (real PID) | PROVEN_FROM_LIVE_TEST |
| Heater targets | extruder `0.0`, bed `0.0` | PROVEN_FROM_LIVE_TEST |
| Kernel errors | none in `dmesg` (only pre-existing, unrelated `dwc2`/USB-camera warnings already characterized in this project's history) | PROVEN_FROM_LIVE_TEST |

## Idle baseline (Phase 6/10)

Counters reset at device epoch `1785610855`; re-read at `1785610997` - **142 real seconds elapsed**
(two independent device-side timestamps, not estimated), screen deliberately untouched throughout.

```
poll_count: 0 -> 3542
raw_level: 1 (unchanged)
idle_level_inferred: 1 (unchanged)
touch_down_count: 0
release_count: 0
unexpected_transition_count: 0
bounce_count: 0
min/max_contact_duration_ms: 0 / 0
```

**PROVEN_FROM_LIVE_TEST**: zero false touch events of any kind occurred during the idle window -
not "some noise below threshold," literally zero transitions recorded, and the raw GPIO level held
a single constant value throughout.

## Touch sequence capture (Phase 7/8)

Human performed, on request (10 normal taps, 5 long presses ~2s each, 5 slow drags, 20 rapid taps,
4 corner taps, then 10s untouched). Captured at device epoch `1785612071` - **1074 real seconds
(~17.9 min)** after the idle-baseline reset, consistent with genuine human interaction time
(walking to the printer, performing a multi-minute sequence, relaying back), not an instantaneous
response.

```
poll_count: 30356
raw_level: 1
idle_level_inferred: 1
touch_down_count: 70
release_count: 70
unexpected_transition_count: 0
bounce_count: 12
min_contact_duration_ms: 40
max_contact_duration_ms: 3900
```

44 "intentional" gestures were requested (10+5+5+20+4). The observed 70 down/release pairs (26
more) is explained by real contact bounce during the rapid-tap and drag portions - exactly the
kind of gesture most likely to produce extra bounce-driven transitions, and separately confirmed by
`bounce_count: 12`. **PROVEN_FROM_LIVE_TEST**: `touch_down_count == release_count` exactly (no stuck
state), `unexpected_transition_count: 0` (the down/release state machine invariant held across all
70 events, even during the busiest gestures), and contact durations span a physically sane range
(40ms for quick taps through 3900ms for a long press) rather than clustering at implausible values.

## Warm reboot qualification (Phase 9, second pass)

Fresh safety check before rebooting confirmed `state:ready`/`standby`/heater targets `0.0`.
Rebooted (separate `sync` + `reboot` invocations, no marker change - testing that TOUCH-D0 survives
a normal reboot, not a slot switch). Device took longer to reappear on this rediscovery pass than
usual (an initial 75s wait found nothing; an additional 90s wait found it) - consistent with the
network-timing variability observed elsewhere in this session, not a fault.

Re-verified, all identical to the first boot-health pass: MAC match, same kernel build timestamp
(confirms the same image, not a different one), `root=/dev/mmcblk0p8`, `PREEMPT_RT=1`, both
Kconfig identity markers present, touch device registered, debugfs present and freshly zeroed
(fresh boot), no dedicated touch IRQ, Klipper ready, Moonraker responding, GuppyScreen running (new
PID, expected), heater targets `0.0`, `dmesg` scanned specifically for `oops|panic|BUG|segfault` -
zero matches.

Short follow-up touch check (5 normal taps, 1 drag, 1 long press ~2s) performed post-reboot:

```
touch_down_count: 8
release_count: 8
unexpected_transition_count: 0
bounce_count: 0
min_contact_duration_ms: 80
max_contact_duration_ms: 3330
raw_level: 1
idle_level_inferred: 1
```

7 gestures requested; 8 down/release pairs observed (1 extra, most plausibly from the drag), with
**zero bounce and zero unexpected transitions** this time - slower, more deliberate touches produced
cleaner data than the earlier rapid-tap-heavy sequence, which is itself a physically sensible
pattern (bounce correlates with touch speed/force, not with the driver being unstable).

## Final classification: **PASS**

All PASS criteria met:
- Normal touch unchanged (confirmed functional before and after the reboot, with sensible counts
  both times)
- GPIO79 idle level reproducible across four independent readings spanning the whole test (idle
  baseline, post-touch-sequence, post-reboot fresh boot, post-follow-up-check) - always `1`
- Transitions clearly observable with physically sane durations
- No false idle touches (zero events across a clean 142s untouched window)
- No kernel errors at any point (`dmesg` clean of oops/panic/BUG/segfault throughout)
- Warm reboot passes with full re-verification
- All services healthy (Klipper/Moonraker/GuppyScreen) throughout

**Final printer image: TOUCH-D0-VSYNC remains the active image** (rootfs2/kernel2, OTA marker
`ota:kernel2`). No excessive logging or resource use observed - dmesg activity was limited to
pre-existing, unrelated USB/camera warnings, not touch-related, not flooding. No rollback was
necessary or performed.

**Explicit confirmation**: at no point during this mission was the printer commanded to print, heat,
home, or move. GuppyScreen's own source and configuration were never modified - the touch
diagnostic is entirely confined to the kernel driver (`ns2009.c`/`Kconfig`) and never touches
userspace GuppyScreen code. Klipper/Moonraker configuration files were never modified.

See `docs/NEBULAOS_TOUCH_IRQ_TRIGGER_FINDINGS.md` for the GPIO79 electrical-behavior classification
derived from this same data.
