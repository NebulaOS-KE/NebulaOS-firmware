# NebulaOS known-good production baseline

Formal, permanent record of the completed USB, webcam, MCU-recovery, and
A/B-readiness work, frozen as a known-good baseline before the upcoming
GuppyScreen/OpenKE portability workstream begins. This document is not a
mission log - see `docs/USB_WEBCAM_MISSION_STATUS.md` for the full
narrative and per-mission 48/50/52-field reports this baseline draws on.

## 1. Baseline identity

- Date: 2026-07-26.
- NebulaOS repository: `~/Documents/ke-mainline-klipper`.
- NebulaOS branch: `master`.
- NebulaOS commit: `b5e2118` (the "MCU root-cause + 1080p30 qualification
  mission" final report commit - the last commit before this baseline
  document itself).
- Kernel commit: `f7ff80a8aa21886a32783dab167e451298c60a8d` (unchanged
  across every mission recorded in `USB_WEBCAM_MISSION_STATUS.md` - only
  the kernel *config fragment* changed, adding `CONFIG_EXFAT_FS=y`, never
  the kernel source tree itself).
- GuppyScreen repository: `~/Documents/guppyscreen`.
- GuppyScreen branch: `ke-next`.
- GuppyScreen commit: `90140caaa656e9e2da9d4ce821a5a1468ed574f1` ("Add
  ax88179 USB-Ethernet build recipe + modules (moved from
  ke-mainline-klipper)").
- GuppyScreen remotes: `origin` (`github.com/coreflake1/guppyscreen.git`),
  `nebulaos-guppyscreen` (`github.com/coreflake1/NebulaOS-guppyscreen.git`),
  `preston` (`github.com/prestonbrown/guppyscreen.git`).
- GuppyScreen submodules: `libhv` (`v1.3.1-54-ga1d8185`, dirty - see
  below), `lv_drivers` (`v8.3.0-2-g0406ccb`), `lvgl` (`v8.3.11`), `spdlog`
  (`v1.2.1-2349-gddce4215`, dirty - see below).

## 2. Source state

**NebulaOS: `BASELINE_SOURCE_DIRTY_DOCUMENTED`.** One untracked file
remains after this baseline commit:

- `docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md` - a complete, standalone,
  human-facing guide created earlier this project per direct user
  request ("create a document in the workspace for me, a noob. How to
  switch between stock and custom"). Understood, intentional, and
  finished, but **not** part of the validated USB/webcam/MCU mission
  work this baseline freezes - deliberately left out of the baseline
  commit rather than bundled in as an unrelated change. Not a generated
  artifact, not a stale temp file; safe to commit separately at any time
  under its own, unrelated commit message.

No other modified, staged, or otherwise dirty paths exist in the
NebulaOS repository as of this baseline.

**GuppyScreen: dirty, and deliberately left untouched (read-only
inspection only, per this mission's own scope).** This is the *starting
point* for the next, separate GuppyScreen/OpenKE portability mission,
not something this baseline resolves:

- `k1/scripts/guppy_cmd.cfg` - modified, not committed.
- `libhv` submodule - modified (dirty submodule working tree, `.MU`).
- `spdlog` submodule - modified (dirty submodule working tree, `..U`).
- Untracked: `14106288.png`, `docs hw/`, `docs/belts-shake-pluck-test-notes.md`,
  `docs/full-app-ux-review.md`, `gap analisys nebulaOS.md`,
  `k1/k1_mods/__pycache__/`,
  `k1/k1_mods/klipper_mods/adaptive_print_setup/__pycache__/`,
  `k1/k1_mods/webrtc-libpeer/`, `k1/scripts/__pycache__/`,
  `k1/scripts/pluck_test.py`, `se_tree.json`,
  `suggested fix plan nebulaOS.md`.

The two `.md` planning documents (`gap analisys nebulaOS.md`,
`suggested fix plan nebulaOS.md`) are clearly real, in-progress planning
material for the upcoming portability work - expected, not a defect in
this baseline.

## 3. Build artifacts

From `artifacts/buildroot-halley5-v30-image/build-manifest.txt`,
independently re-verified by a fresh `sha256sum` against the real files
on disk (matched exactly, byte for byte):

- `xImage_sha256`:
  `416cf2f656a8df2b8663fee66279eed6b741ff67f8a6e50126183a6d13ac712b`
- `rootfs_squashfs_sha256`:
  `86f1f5a03ab3df5d337bd70d63583ed467748cef6cee65c2cff971456684fd95`
- `built_at`: `2026-07-26T13:43:41Z`
- `git_commit_main`: `ed4e6f771cddbd6551c4018adf9709d372b55c79` (the
  "webcam: qualify and promote 1920x1080@30fps" commit - the last commit
  that actually changed anything baked into the image; `b5a0bd4` and
  `b5e2118` are the manifest-update and final-report commits that
  followed, both documentation/administrative and requiring no rebuild).
- `git_dirty_main`: `yes` (expected - `build-manifest.txt` itself had not
  yet been committed at the moment the build ran, matching this
  project's own established, repeatedly-used pattern).
- `git_commit_kernel`: `f7ff80a8aa21886a32783dab167e451298c60a8d`,
  `git_dirty_kernel`: `no`.

Independently confirmed present inside the real `rootfs.squashfs` (via
`unsquashfs -l` plus targeted extraction of file contents, not just
listing):

- `/etc/init.d/S50webcam` - contains `RESOLUTION=1920x1080`,
  `DESIRED_FPS=30`, and the dynamic UVC-node-discovery logic
  (`discover_uvc_device()`) unchanged.
- `/etc/init.d/S95mcu-boot-recovery` - contains the bounded poll loop
  (`POLL_RETRIES=15`), the exact known shutdown-message allowlist
  (`KNOWN_SHUTDOWN_MSG="Can not update MCU 'mcu' config as it is
  shutdown"`), and the defense-in-depth `"status"`-object check added
  in the second mission pass.
- `/etc/init.d/S99confirm-good` - contains the real-readiness
  `klippy_state` check (not merely `"result"` presence).
- `/etc/udev/rules.d/91-usb-gcode-media.rules` and
  `/etc/usb-gcode-media.sh` - present, correct permissions
  (`-rwxr-xr-x` on the script).
- `/usr/bin/ustreamer`, `/usr/bin/v4l2-ctl` - present.

**`BASELINE_ARTIFACTS_VERIFIED`.**

## 4. Running-device state

Collected read-only, each query executed and reviewed as its own
independent step (no query was ever combined with a state-changing
command):

- Device IP: `192.168.1.146` (DHCP-assigned; drifts between sessions,
  see the `reference-device-access` memory for rediscovery via `nmap`).
- Kernel version: `Linux buildroot 6.6.18-rt23 #8 SMP PREEMPT Sun Jul 26
  13:43:20 UTC 2026 mips GNU/Linux`.
- Boot slot: custom, `root=/dev/mmcblk0p8` (confirmed via
  `/proc/cmdline`).
- OTA marker: `ota:kernel2` (confirmed via a direct raw read of
  `/dev/mmcblk0p1`).
- Moonraker `/server/info`: `klippy_connected: true`, `klippy_state:
  ready`, `failed_components: []`, `warnings: []`.
- Printer objects: `extruder.target = 0.0`, `heater_bed.target = 0.0`,
  `toolhead.homed_axes = ""`, `print_stats.state = standby`.
- Webcam process: `ustreamer --device=/dev/video3 --format=MJPEG
  --encoder=HW --resolution=1920x1080 --desired-fps=30 --host=127.0.0.1
  --port=8080` - live, running, matching the qualified production mode.
- USB: `/dev/sda` mounted at `/opt/printer_data/gcodes/USB/sda`
  (exfat, rw).
- `S95mcu-boot-recovery` marker present (`/run/mcu-boot-recovery-
  attempted`) - this boot already ran through its own one-shot check.

**`LIVE_BASELINE_STATE_CONFIRMED`.**

## 5. Frozen functionality

The following are complete, validated, and must not be changed by any
future work (including the upcoming GuppyScreen/OpenKE portability
mission) without a proven direct dependency, its own regression plan,
and full revalidation afterward:

- Display and RGB565 scanout.
- Touch input.
- Wi-Fi.
- SSH.
- Printer MCU communication.
- Klipper.
- Moonraker.
- GuppyScreen base UI.
- Mainsail.
- nginx.
- Persistent printer data.
- A/B rollback (`S00revert-safety`, `S99confirm-good`, the OTA marker
  mechanism, `flash-spare-slot.sh`).
- USB mass storage.
- exFAT.
- USB udev hotplug (`91-usb-gcode-media.rules` / `usb-gcode-media.sh`).
- GuppyScreen USB file visibility (via Moonraker's own gcodes root -
  GuppyScreen itself has no USB-specific code).
- `pellcorp/k1-ustreamer`.
- Dynamic UVC node discovery.
- nginx `/webcam/`.
- Mainsail webcam.
- 1920x1080 @ 30fps webcam mode.
- `S95mcu-boot-recovery`.
- `S99confirm-good` printer-readiness gate.

## 6. Completed defect classifications

- `WEBCAM_1080P30_PRODUCTION_QUALIFIED`
- `USB_GUPPYSCREEN_INTEGRATION_COMPLETE`
- `MCU_BOOT_SHUTDOWN_OPERATIONALLY_MITIGATED`
- `MCU_BOOT_SHUTDOWN_TRIGGER_UNRESOLVED`
- `S99_PRINTER_READINESS_GATE_FUNCTIONAL`
- `KNOWN_GOOD_PRODUCTION_BASELINE`

## 7. MCU residual limitation

The MCU enters a genuine firmware-reported shutdown state during some
flash-triggering host reboots (confirmed via `mcu.py`'s own
`config_params['is_shutdown']` field - the MCU itself explicitly asserts
this state, it is not an inferred communication artifact).

The exact electrical or timing trigger has not been isolated. Real
narrowing was done (confirmed identical `[mcu]` printer.cfg between
stock and custom; confirmed stock's own graceful-shutdown mechanism,
`rcK`, is byte-for-byte identical on both systems and already stops
Klipper via `stop()` before any `reboot` completes on both; confirmed
stock's `mcu_reset()` helper only touches a separate, unrelated host-side
virtual MCU used for the accelerometer/`prtouch_v2`, not the real
toolhead MCU) but a definitive electrical/timing root cause would likely
require kernel/devicetree pinctrl-level investigation, which was judged
too risky to attempt without much stronger prior evidence.

`S95mcu-boot-recovery` handles only the exact known early-boot condition
(`state == "error"` AND the state_message is an exact match for the one
known string AND no `"status"` object is present in the response),
at most once per boot, enforced by both the plain start-once init.d
action and a `/run/`-tmpfs marker that cannot survive a real reboot.

Unknown and genuine printer faults (thermal, ADC, configuration,
stepper/endstop, or a shutdown occurring after the printer was already
ready) remain latched and are never automatically cleared.

## 8. Safety-process rule

Safety-state queries (heater targets, `homed_axes`, print state,
`klippy_state`, etc.) and any state-changing action (reboot, flash,
OTA-slot switch, `FIRMWARE_RESTART`, service restart) must never be
combined in the same command or remote SSH invocation.

The safety result must be returned, reviewed, and explicitly accepted
before any state-changing command is issued as its own, separate step.

This rule exists because of a real, disclosed incident during the
previous mission (recorded in `USB_WEBCAM_MISSION_STATUS.md`'s "closure
mission" final report, item 51(d)): a safety check and a reboot command
were batched together, and the safety check's own result (`homed_axes:
"xyz"`) was not actually read before the reboot was already in flight.
Assessed impact was zero (a Linux `reboot` issues no motion command, and
Klipper always requires re-homing after any restart regardless of prior
state - confirmed directly via a fresh boot's `homed_axes` correctly
resetting to `""`), but the process violation was real and is not
repeated in this baseline mission or any future one.

## 9. GuppyScreen portability freeze contract

The upcoming OpenKE/GuppyScreen portability work must not alter any
system listed in Section 5 unless:

- a direct dependency on that system is proven, not assumed;
- the change has its own regression plan;
- A/B rollback (`S00revert-safety`/`S99confirm-good`/OTA marker/
  `flash-spare-slot.sh`) is preserved and re-verified;
- USB, webcam, MCU boot-readiness (`S95`/`S99`), display, touch, Wi-Fi,
  and printer safety are all revalidated afterward, live, on real
  hardware - not assumed from source inspection alone.

## 10. Reproduction and rollback

- Build artifacts: `artifacts/buildroot-halley5-v30-image/{xImage,
  rootfs.squashfs,build-manifest.txt}` (hashes in Section 3).
- Flash procedure: `scripts/flash-spare-slot.sh`, run from stock
  (`root`/`Creality2023` over SSH), writing only `/dev/mmcblk0p6`
  (kernel2) and `/dev/mmcblk0p8` (rootfs2) - the script itself refuses
  to write to whatever is the currently-mounted root, so stock
  (`/dev/mmcblk0p5`/`/dev/mmcblk0p7`) can never be overwritten by it.
- OTA marker toggle: from custom, `. /etc/ota_marker.sh;
  write_ota_marker "ota:kernel"` (to stock) or `"ota:kernel2"` (to
  custom); from stock, `. /etc/ota_bin/ota_utils.sh; . /etc/ota_bin/
  ota_local_method.sh; local_set_next_boot_device` (a toggle, not an
  explicit target - read `mmc_read_str ota` first).
- Stock fallback state: untouched by any mission recorded here - stock
  remains a fully independent, unmodified slot at all times.
- Known-good OTA marker for this baseline: `ota:kernel2` (custom).
- Full narrative and evidence: `docs/USB_WEBCAM_MISSION_STATUS.md`
  (three chained final reports - 48, 50, and 52 fields respectively -
  covering the original USB/webcam/GuppyScreen-media mission, the
  closure-audit/MCU-recovery/webcam-resolution continuation, and the
  MCU-root-cause/1080p30-qualification closure mission).
