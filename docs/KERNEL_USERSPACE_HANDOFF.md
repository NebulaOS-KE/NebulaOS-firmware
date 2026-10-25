# Kernel → Userspace Handoff

Kernel work on the Nebula Pad / Ender-3 V3 KE custom Linux 6.6.18-rt23 image ends here. This
document is the single, concise handoff record for whoever picks up userspace work next.

**Classification: `FUNCTIONAL_PRODUCTION_BASELINE`, `KERNEL_HANDOFF_READY`.** Not manufacturing
qualified, not reliability validated, not security hardened, not Bluetooth complete - those are
separate, later milestones.

## Kernel baseline

| | |
|---|---|
| Kernel tag (both repos) | `functional-production-baseline-2026-07-23` |
| Kernel fork commit | `e123bb14fd8e3fd03a5550cf187a5a9f64faf281` |
| Main repo commit (tagged) | `a8c2fbd2cc9b8e13a44da62d6e512a1408294365` |
| Main repo commit (current, post-handoff-audit doc fix) | `8d5b48a` - documentation-only, zero effect on kernel/DTB/rootfs content, all hashes below unchanged |
| Kernel config SHA-256 | `30a78c5e2600a3e5e4f586f6a3291c6942d73af15b00be8a76eeb3d67c0df7d6` |
| Buildroot config SHA-256 | `a167f6ea07bf4c11a6d6995020a985cb8cb984a5ddc2009e7dd2e1e8108e3b1a` |
| Packaged DTB SHA-256 | `5b4859256397c28bc689a1fe07fd8440919878d55e7ddb6f8be530b328eb1d03` |
| Final rootfs (squashfs) SHA-256 | `3c4516cdfeeee7db3d94f0f444c53ee4daf1fcf0d09969b9be8e8d782e60f96f` |
| Final kernel image (xImage) SHA-256 | `fe770b7b2b0b84c8d5810f783e2195b578bddf7a65eb641d7ef8c9dd6cdd2711` |
| Build manifest | `artifacts/buildroot-halley5-v30-image/build-manifest.txt` |
| Authoritative boot log | `artifacts/parity/baseline-2026-07-23-boot-cleanup/dmesg-functional-production-baseline-final.txt` |
| Capability matrix | `docs/BOARD_CAPABILITY_MATRIX.md` |
| Full boot-message audit trail | `docs/BOOT_WARNING_AUDIT.md` |

## Supported product hardware

eMMC · Wi-Fi (BCM43430/1, firmware 7.46.58.13) · display · backlight · touchscreen (`ns2009_ts`) ·
USB · PWM beeper (GPC-3/PWM channel 3, kernel PWM sysfs channel `pwmchip0/pwm3`, owned by Klipper `nebulaos_beeper` since G108) · RTC · watchdog ·
rotation (`/dev/video0`) · H.264 encoder (`/dev/video1`) · H.264 decoder (`/dev/video2`) · UART1
printer link (software-equivalent to stock, see `docs/PRINTER_MAINBOARD_PRECONNECTION_CHECKLIST.md`
for the remaining physical-connection sign-off).

## Intentionally unsupported or disabled

| Item | Why |
|---|---|
| Bluetooth | `uart3` (the real transport pins) guaranteed-conflicts with `i2c4`/touch; needs stock's dynamic pin hand-off mechanism, a separate future mission |
| Ethernet (`mac1`) | Not populated on this product; also had a real GPIO conflict with `lcd_rst` |
| Extra MMC (`msc2`) | Reference-board-only controller, no product storage device |
| SFC flash | No MTD device on stock or custom, no consumer |
| MScaler 0/1 | `v4l2_subdev`-only, zero userspace consumer, unrelated to the real camera/rotation/encode/decode path |
| ALSA/PCM audio (whole graph: `as-platform`, `as-virtual-fe`, `as-fmtcov`, `as-dsp`, `as-baic`, `as-dmic`, `as-mixer`, `as-spdif`, `icodec`, `sound`) | Stock itself never registers a sound card (`ALSA device list: No soundcards found.`, confirmed by booting stock directly); the beeper needs none of it |
| DMIC | No product microphone array; subsumed by the full audio-graph disable |
| BAIC4/SCO | Bluetooth voice backend; subsumed by the full audio-graph disable |
| eFuse | No production consumer, avoids OTP write risk |

## Items transferred to userspace work

- BusyBox executable-stack hardening (`process '/bin/busybox' started with executable stack`) -
  userspace security-hardening item, not a kernel functional blocker.
- Service startup and supervision (init.d ordering, restart policy).
- Application permissions and privilege boundaries.
- `/dev/mem`: the beeper no longer uses it (G108). The legacy `/opt/nebulascreen/nebulabeep`
  binary still ships (the screen release format requires it) but nothing in the image calls it.
- Network-service exposure (dropbear, nginx, Moonraker's `trusted_clients`).
- Logging policy and log rotation.
- RTC/NTP policy (RTC currently boots to a fixed epoch until NTP updates it - `S49ntp`).
- OTA user-facing behavior and update UX.
- Configuration migration for existing installs upgrading from stock.
- GUI (GuppyScreen) and Klipper integration/config beyond what's already proven working.

## Kernel limitations retained (accepted, documented, not blockers)

- `IRQ pdmam not found` - optional secondary DMA-MCU interrupt, primary DMA works throughout boot.
- `no trigger-mode IRQ (optional, not used by this board)` (TCU) - severity already corrected to
  `dev_info`; optional second IRQ genuinely unused.
- `vusb_d`/`vusb_a` dummy regulators (USB) - standard-optional names, no board supply defined, rails
  almost certainly fixed/always-on; USB fully functional.
- Static GPIO base allocation deprecation warnings - vendor-kernel-generation characteristic, no
  functional effect.
- `irq_chip XBurst2-irqchip did not update eff. affinity mask` - architecture limitation, both CPUs
  online and functional.
- `Alternate GPT is invalid, using primary GPT.` - confirmed present verbatim on stock too; primary
  GPT and all 10 partitions valid.
- `mmc1: Failed to initialize a non-removable card` - known, benign pre-power-sequencing scan; the
  controlled `WL_REG_ON` sequence immediately after always succeeds.
- CLM/TxCap blobs missing - confirmed genuinely absent from stock's own shipped rootfs (not merely
  unfound); no unproven blob installed.
- `This architecture does not have kernel memory protection.` - real, mainline MIPS port gap, not a
  configuration choice this project can fix.
- Jitterentropy self-test result - timing-dependent (measures live CPU jitter), varies boot to boot;
  hardware TRNG makes the outcome moot either way. See `docs/BOOT_WARNING_AUDIT.md` for the full
  reconciliation of this specific item found during the kernel handoff audit.

## Verification

`scripts/build/06-verify.sh` checks all of the above automatically against the packaged production
DTB (via `dtc`, decompiling the real compiled artifact) and the built rootfs/kernel config - re-run
it after any future kernel change before considering a new baseline handoff-ready.
