# Board Capability Matrix

The functional production baseline's capability disposition for the Nebula Pad / Ender-3 V3 KE
custom Linux 6.6.18-rt23 image, as of the "functional production-baseline mission"
(2026-07-23). This is a snapshot of what's *supported*, *not supported*, or *unpopulated* -
not a manufacturing reliability or security-hardening statement (see the classification note
at the bottom).

| Capability | Status | Notes |
|---|---|---|
| eMMC storage | supported | `msc0` (`13450000.msc`), all 10 partitions enumerate, OTA A/B slots both proven |
| Wi-Fi | supported | `msc1` (`13460000.msc`), BCM43430/1, firmware 7.46.58.13, byte-identical to stock's own; scan/association/DHCP all proven live |
| Bluetooth | not supported in this baseline | `uart3` (the real transport pins) guaranteed-conflicts with `i2c4`/touch and is disabled (Path A); a real transport needs stock's dynamic pin hand-off mechanism - separate, future mission |
| Display | supported | DPU (`13050000.dpu`), confirmed live, GuppyScreen renders |
| Backlight | partially supported | **Corrected 2026-08-16 (Phase 0 doc-drift pass)** - this row previously read "supported / PWM0-driven, confirmed live", which `NEBULAOS_DISPLAY_OS_HARDWARE_ANALYSIS.md` §6 had already flagged as stale/unbacked-by-evidence but never corrected. Real current state: the qualified `nebulaos,backlight-final-controller` kernel driver (`nebulaos_backlight_final_controller.c`) is bound and controllable only via its own debugfs interface (`/sys/kernel/debug/nebulaos_backlight_final/`), which supports just a bounded, hard-watchdog-capped ~2-second auto-reverting demonstration pulse - not sustained adjustable brightness. It never populates the standard `/sys/class/backlight/` interface, so GuppyScreen's on-screen brightness control (which only targets that standard path) is dead on real hardware: the brightness dropdown is hidden by construction and idle-dim is a silent no-op. See `NEBULAOS_DISPLAY_OS_HARDWARE_ANALYSIS.md` §6, `docs/NEBULAOS_CANONICAL_DEPLOYMENT_QUALIFICATION.md`, and `scripts/build/overlay/etc/nebulaos-display-qualified.sh`. |
| Touchscreen | supported | `i2c4`, `ns2009_ts`, confirmed live |
| PWM beeper | supported | GPC-3/PWM channel 3 as a kernel PWM channel (`/sys/class/pwm/pwmchip0/pwm3`, DTS `&pwm` pinctrl `pwm3_pc`), owned by Klipper's `nebulaos_beeper` extra (G108, kernel openke 5ba3d3a = KERNEL_PIN since Run 19); formerly `guppybeep` via direct `/dev/mem` MMIO. Independent of ALSA, unaffected by the audio-graph disable below |
| ALSA/PCM audio | intentionally disabled | stock's own dmesg says "No soundcards found," `/proc/asound` is empty, and stock's real production stack (Klipper/GuppyScreen) has zero consumer for it - the whole graph (as-platform, as-virtual-fe, as-fmtcov, as-dsp, as-baic, as-dmic, as-mixer, as-spdif, icodec, the machine-driver `sound` node) is disabled; see `docs/BOOT_WARNING_AUDIT.md` |
| USB | supported | `dwc2` OTG - **correction, 2026-07-26**: this row's original "proven live" wording (2026-07-23) meant driver registration in `dmesg` only, not a real external device ever enumerating - a real, contradictory finding from an earlier session (FIRMWARE.md §42: no external USB device, on stock or custom, ever enumerated on this physical unit) was never resolved before this row was written. Genuinely proven live now: a real USB flash drive (`usb-storage`→SCSI→`/dev/sda`, real capacity) and a real USB UVC webcam (`uvcvideo`) both enumerate correctly with real hardware physically attached - see FIRMWARE.md §60 |
| Camera | supported | USB UVC webcam via `ustreamer` - **correction, 2026-07-26**: not actually functional before this date despite the original wording here - a real MIPS ABI/toolchain mismatch meant the `ustreamer` binary could never execute at all (see FIRMWARE.md §60 for the root cause and fix). Genuinely confirmed live now: real MJPEG capture from `/dev/video3` (the real UVC capture node - `/dev/video0-2` are this SoC's own rotation/encode/decode blocks, not the camera), served correctly over HTTP |
| Rotation | supported | `/dev/video0`, confirmed live |
| H.264 encoder | supported | `/dev/video1`, confirmed live |
| H.264 decoder | supported | `/dev/video2`, confirmed live |
| MScaler (ISP scaler) | unused | `v4l2_subdev`-only, zero userspace consumer, disabled |
| Ethernet | not populated | no RJ45 on this product; `mac1` disabled (real GPIO conflict with `lcd_rst` besides) |
| Extra MMC (MSC2) | not populated | reference-board-only controller, no product storage device, disabled |
| SFC flash | not populated | no MTD device on stock or custom, no consumer, disabled |
| DMIC | not present / not used | no product microphone array; already disabled for a real `GPC-21`/`uart1` conflict, additionally covered by the full audio-graph disable now |
| eFuse | disabled | no production consumer, avoids OTP write risk |
| RTC | supported | confirmed live |
| Watchdog | supported | confirmed live |
| Klipper | supported | confirmed live, connects to MCU over `uart1` |
| Moonraker | supported | confirmed live, `/server/info` responds |
| GuppyScreen | supported | confirmed live |
| A/B OTA fallback | supported | `S00revert-safety`/`S99confirm-good`, proven across many real reboot cycles this project |

## Classification

This baseline is: **`FUNCTIONAL_PRODUCTION_BASELINE`**

It is explicitly **not**:

- manufacturing qualified
- long-term reliability validated
- security hardened
- Bluetooth complete

Those are separate, later milestones - see `FIRMWARE.md`'s own running log for the mission that
produced each capability's disposition, and `docs/BOOT_WARNING_AUDIT.md` for the full per-message
boot-log audit trail behind every "supported"/"not supported"/"unused" verdict above.
