# Canonical repository + baseline deployment qualification

2026-08-07. Deploys the image built from `NebulaOS-KE/NebulaOS-firmware`
commit `d8a5515c7073023c9209a99d61a6e2aaaa6b37e8` (a fresh clean-room clone,
`./build.sh` end to end, zero manual copies) to the real printer via the
established stock-mediated inactive-slot process, then live-qualifies it.

## Deployment sequence (all steps executed, all verified)

1. Confirmed printer idle before touching anything: `print_stats.state ==
   "standby"`, `heater_bed.target == 0`, `extruder.target == 0`,
   `toolhead.homed_axes == ""`.
2. Packaged the build (`scripts/build/package-deployment.sh`) - all 7
   `SHA256SUMS` entries verified locally before transfer.
3. Transferred `xImage`/`rootfs.squashfs`/`build-manifest.txt` to
   `/usr/data/deploy-staging/` - re-verified against `SHA256SUMS` on-device
   after transfer (all `OK`).
4. Device was already booted from the custom slot (`root=/dev/mmcblk0p8`)
   at mission start - `flash-spare-slot.sh`'s target is permanently fixed
   to that same slot, so it correctly refused to write until the device
   cycled to stock. Set the OTA marker to `ota:kernel` and rebooted -
   confirmed genuine stock boot (`Linux ... 4.4.94`, `root=/dev/mmcblk0p7`).
5. `flash-spare-slot.sh --check-only` - `SAFE TO FLASH` (all preflight
   checks passed: slot mapping, active-slot identification, live-target
   collision check, image sizes, manifest hash verification).
6. Real flash - both `xImage` and `rootfs.squashfs` written and
   byte-verified via read-back md5 comparison.
7. Set OTA marker to `ota:kernel2`, rebooted.
8. Confirmed boot into the new image: kernel build timestamp `Fri Aug 7
   17:47:57 UTC 2026` (matches this build), `root=/dev/mmcblk0p8`.
   `S00revert-safety`'s safety net was not triggered (OTA marker still
   read `ota:kernel2` after boot, meaning `S99confirm-good` completed
   successfully without needing to fall back).

## Live qualification results

| Item | Result |
|---|---|
| PREEMPT_RT | `/sys/kernel/realtime` = `1`, `CONFIG_PREEMPT_RT=y` |
| CONFIG_HZ | `100` (unchanged, per R1) |
| ROAMOFF1 | `/sys/module/brcmfmac/parameters/roamoff` = `1` |
| WiFi SDIO IRQ priority | `chrt -p` on `irq/44-mmc1`: `SCHED_FIFO`, priority `60` (matches `a233317`'s fix exactly) |
| CID-derived MAC | `wlan0` active MAC (`16:3b:...`) differs from `permaddr` (`20:0b:...`), locally-administered bit set - structurally consistent with `nebulaos-stable-mac.sh`'s design |
| TCP_NODELAY | live `ustreamer` process command line includes `--tcp-nodelay` |
| Camera presets | `camera-quality.cfg` present, `set_camera_quality.py` present at its real seeded path |
| DISPLAY-V1 | `CONFIG_FB_INGENIC_PAN_VSYNC_GATE=y` in the running kernel's resolved config |
| pinctrl / PWM brightness | `nebulaos_backlight_final` driver bound; dmesg shows its own deliberate "boot-preserve" message (zero hardware claimed at boot, bootloader's GPC0 config untouched, activated via an explicit `command` write) - **not** registered under `/sys/class/backlight/`, which is why GuppyScreen logs "brightness control disabled": GuppyScreen's generic slider only knows the standard backlight class, not this project's purpose-built controller. `nebulaos-display-sleep-wake-controller` (a dedicated service, confirmed `RUNNING`) is the actual consumer of this driver's real control path. Not a regression - this is the documented post-incident redesign (`FINAL1`) working as intended. |
| Polling touch wake | `ns2009_ts` present in `/proc/bus/input/devices`, `CONFIG_TOUCHSCREEN_NS2009=y`, `CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION` absent (poll-only, not the IRQ-based prototype) |
| pinctrl / kernel errors | Zero pinctrl-specific errors. Four other `dmesg` lines matched a generic error/fail grep; all four cross-checked against `docs/BOOT_WARNING_AUDIT.md` and confirmed pre-existing, already-classified, zero-functional-impact (`pdmam` optional IRQ, a known benign WiFi manual-insert race, an optional TCU IRQ, and the already-`STOCK_EQUIVALENT_ACCEPTED` CLM blob absence) - none are new regressions from this deployment. |
| Klipper | `state: "ready"`, `"Printer is ready"` |
| Moonraker | responding, serving Klipper's state correctly |
| GuppyScreen | `v1.5.0-OpenKE`, connected to Moonraker, "loaded calibration coefficients" |
| S99confirm-good | Confirmed executed successfully (OTA marker survived at `ota:kernel2` post-boot, not reverted by `S00revert-safety`) |
| `z_compensate` HTTP structured status | `GET /printer/objects/query?z_compensate` returns `{calibration_id, calibration_state, calibration_z_offset, calibration_error}` - correct idle shape |
| `z_compensate` WebSocket structured status | `printer.objects.subscribe` over a raw WS connection returns the identical structured shape |
| GuppyScreen baseline calibration ID | Live query confirms a real (non-null) `calibration_id: 0` is being served, matching what `RecalibrationWizardPanel`/`z_compensate_status.cpp`'s own already-passing offline test suite (`test_subscription_baseline_ordering`) proves the ordering guarantee against |
| Calibration not triggered | No calibration command issued at any point, per mission scope |
| Warm reboot | Second reboot (not the flash reboot) - same image persisted (`root=/dev/mmcblk0p8`, same kernel build timestamp), all services `RUNNING` |
| Short soak | ~3.5 minutes post-warm-reboot: `state: "ready"`, `z_compensate` still correct, zero segfault/OOM/panic/BUG lines, stable process counts (no restart loops) |

## Real finding: persistent-data Klipper/prtouch content was not touched by this reflash - and that's correct

`/opt/klipper` is a bind-mount from `/dev/mmcblk0p10` (`/usr/data`, the
persistent partition) - kernel2/rootfs2 flashing never touches it. Klipper
self-reports `software_version: "d839d03-dirty"` (the *old* pinned commit,
pre-dating this mission's `0e5785d` bump) because this already-provisioned
device's persistent copy was never re-fetched from the new squashfs's
factory-seed archive (`/opt/nebulaos-seeds/klipper.tar.gz`) - first-boot
seeding is a deliberate one-time event, by design, so an already-set-up
device's own local runtime state is never silently overwritten by a later
image.

This is **not a functional regression**: live hash comparison confirms
`z_compensate.py`/`prtouch_v2.py`/`prtouch_nozzle.py`/`prtouch_probe.py`/
`prtouch_mcu.py` on this device are byte-identical to this session's own
pre-mission backup snapshot - the exact content commit `0e5785d` was
created *from* (see that commit's own message: "sync z_compensate +
prtouch_* to the live, accepted baseline"). The live structured-status
tests above prove this directly. The `"-dirty"` suffix in the version
string is Klipper's own `git describe` reporting real, already-present
local changes relative to the old base commit, not stale/broken code.

**What this means going forward, worth flagging explicitly**: a future
Klipper/Moonraker source change that reaches the pinned manifest and the
squashfs's factory-seed archive will **not** automatically reach an
already-provisioned device's running copy via a kernel2/rootfs2-only
reflash - that requires either a genuinely fresh namespace (first real
boot) or an explicit, separate re-seed/update step, which is out of this
mission's scope to design. GuppyScreen does not have this gap - its binary
lives directly in the read-only squashfs (`/opt/guppyscreen`, not
persistent-data-backed), confirmed correctly updated by this exact
deployment (new build timestamp in `guppyscreen.log`, fresh binary hash).
