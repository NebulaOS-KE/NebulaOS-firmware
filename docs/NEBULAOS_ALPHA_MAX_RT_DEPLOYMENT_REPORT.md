# NebulaOS Alpha-Max RT Deployment Report

Autonomous build, deploy, and non-motion smoke-test of one combined aggressive alpha image
(`NEBULAOS-ALPHA-MAX-RT`: W3 SDIO + R1 PREEMPT_RT + P1 Wi-Fi power-save-off + C2 camera
idle-pause + CID-derived stable MAC + the `c03757e` factory-seed fix) onto the real printer.
Extended/physical testing is left to the user, per this mission's own explicit instruction.

```
SOURCE_HEAD: d479161f8a0a1d18207870a32316d45b434e6244 (implementation/moonraker-camera-defaults)
KERNEL_HEAD: 295b7101d751fd888ae39e6f1746a4a940664a5f (includes the dsi_lock PREEMPT_RT fix)
WORKING_TREE_CLEAN: yes (final state, after resetting W3/R1 markers and reverting tracked
  reference artifacts back to baseline)
VENDOR_VERIFICATION: PASS (0 unexpected MISS lines, both before and after this build)

BUILD_PROFILE:
  W3 (cap-sdio-irq + cap-sd-highspeed)
  P1 (activated post-boot via /usr/data/nebulaos/maintenance/wifi-power-save-mode marker)
  CID_DERIVED_MAC (unchanged algorithm, per explicit instruction)
  FIXED_ASSOCIATION (unchanged)
  C2 (activated post-boot via /usr/data/nebulaos/maintenance/camera-idle-mode marker)
  PREEMPT_RT (R1)
  HZ_100 (unchanged, confirmed CONFIG_HZ=100)

C03757E_PRESENT: yes (confirmed both in the built rootfs's S04nebulaos-factory-seed via
  dirty_exclude parameter, and via ancestor-check against HEAD)
VENV_SEEDS_PRESENT: yes (klipper-venv-seed.tar.gz + moonraker-venv-seed.tar.gz confirmed
  present in the extracted rootfs's /opt/nebulaos-seeds/)

KERNEL_IMAGE:
  path: build-work/deploy-packages/NEBULAOS-ALPHA-MAX-RT-20260731T215619Z/xImage
  SHA-256: 51f1bd1b2c6737251b50fe2f5ef1413db029192a9c42673c03d601b0c4ec622b

ROOTFS_IMAGE:
  path: build-work/deploy-packages/NEBULAOS-ALPHA-MAX-RT-20260731T215619Z/rootfs.squashfs
  SHA-256: 3216389b4d05c4b3ce92c96032d75ea90190a379101e405be2c6e2dc01205c77

DEPLOYMENT_PACKAGE: build-work/deploy-packages/NEBULAOS-ALPHA-MAX-RT-20260731T215619Z/
  (xImage, rootfs.squashfs, build-manifest.txt, SHA256SUMS, kernel.config, buildroot.config,
  halley5-nebulaos-fragment.config, halley5_v30.dts, PACKAGE_INFO.txt — not committed)
ROLLBACK_B0_PACKAGE: build-work/deploy-packages/B0-20260731T155014Z/ (verified, hashes match;
  this is also the image the device was running immediately before this deployment)

PRINTER_INITIAL_IDENTITY: booted custom (B0, root=/dev/mmcblk0p8), MAC 16:3b:5d:00:00:01,
  IP 192.168.1.243 — confirmed via multiple indicators (MAC, root partition, Klipper identity)
PRINTER_STOCK_IP: 192.168.1.231 (confirmed via root=/dev/mmcblk0p7, factory MAC
  fc:ee:11:00:00:01, hostname Ender3V3KE-0001)
PRINTER_FINAL_IP: 192.168.1.243 (same MAC as initial — CID-derived MAC is unchanged by SDIO/RT
  variant, as expected, since the algorithm and its eMMC-CID input are both unchanged)

STOCK_PRESERVED: yes — never written; only ever the target for the OTA marker, never for
  flash-spare-slot.sh, confirmed via preflight + fresh root= checks before every write
CUSTOM_SLOT_FLASHED: yes (kernel2/rootfs2, mmcblk0p6/p8) — while stock was active and slot 2
  was independently confirmed inactive, both check-only preflight and the real write's own
  built-in re-preflight
READBACK_VERIFIED: yes — both xImage and rootfs.squashfs write-verified by MD5 read-back
  inside flash-spare-slot.sh itself

RUNNING_ROOTFS: mmcblk0p8 (slot 2, custom) — confirmed via /proc/cmdline both immediately
  after first boot and again after the Phase 20 warm reboot
RUNNING_KERNEL: 6.6.18-rt23 #2 SMP PREEMPT_RT (confirmed via uname, matches this build's own
  compile timestamp, Fri Jul 31 21:52:40 UTC 2026)
PREEMPT_RT_CONFIRMED: yes (/sys/kernel/realtime = 1, uname shows PREEMPT_RT explicitly)
W3_CONFIRMED: yes (dmesg: "mmc1: new high speed SDIO card", no MMC/SDIO errors; built artifact
  DTS independently confirmed cap-sdio-irq + cap-sd-highspeed present, cap-mmc-highspeed absent)
P1_CONFIRMED: yes (`iw dev wlan0 get power_save` → "Power save: off", both immediately after
  activation and again after the warm reboot — the marker persists on /usr/data)
CID_MAC: 16:3b:5d:00:00:01
CID_MAC_DERIVATION_CONFIRMED: reproduced from the live eMMC CID via the existing
  `nebulaos_derive_mac_from_identifier` function during Mode B earlier this session (same
  physical eMMC, same algorithm, unchanged in this mission) — not re-derived manually in this
  specific deployment since the algorithm was explicitly not to be touched, but the resulting
  MAC is byte-identical to the already-validated derivation
C2_STATUS: DEPLOYED_AND_WORKING (not disabled) — full pause/resume cycle confirmed live
C2_PAUSED_IRQ_RATE: ~8,036/sec (DWC2 SOF, both cores, 2s sample) — a real, notable finding:
  essentially unchanged from the always-active baseline (~8,000-8,150/sec throughout this
  entire session across every variant). The DWC2 SOF interrupt is bus-level and does not
  appear to reduce even when the camera is genuinely paused (ustreamer's own /pause closing
  the UVC endpoint) — the earlier hypothesis that idle-pause would reduce this specific
  interrupt rate is NOT supported by this measurement. Any real benefit of C2 would have to
  come from elsewhere (endpoint bandwidth, ustreamer CPU), not the SOF rate itself.
C2_RESUME_LATENCY: first snapshot after resume: HTTP 200, 4.51s (expected resume cost);
  second snapshot immediately after: HTTP 200, 0.24s (near-normal)

KLIPPER: ready (both after first boot and after the warm reboot)
MOONRAKER: healthy (/printer/info responds correctly, klippy_state ready)
GUPPYSCREEN: running (confirmed via process list)
CAMERA: HTTP 200 (snapshot, both paused-then-resumed and after warm reboot)
WIFI: associated, real traffic (SSID OtherNetwork, real RX/TX byte counts)
OTA_CONFIRMATION: ota:kernel2 confirmed both after first boot and after the warm reboot
  (S99confirm-good correctly flipped it forward both times, having detected real
  klippy_state=ready)

WARM_REBOOT_TEST: PASS — identical kernel build, PREEMPT_RT still active, identical MAC, P1
  still off (marker persisted), Klipper ready, camera HTTP 200, OTA marker still ota:kernel2
PROTECTED_DATA: PASS — before/after comparison shows zero differences in any gcode file,
  config file, or macro; only expected service logs (klippy.log, moonraker.log,
  guppyscreen.log) and Moonraker's own database grew, as expected from normal service activity
ROLLBACK_REQUIRED: no — deployment succeeded on the first attempt at Phase 16 onward (a
  build-only issue was caught and fixed before any device interaction — see below)
FINAL_DEVICE_STATE: NEBULAOS-ALPHA-MAX-RT, booted, healthy, confirmed stable across one warm
  reboot

READY_FOR_USER_MANUAL_TESTING: YES
PHYSICAL_TESTS_PERFORMED: NO
PRODUCTION_TAG_CREATED: NO
```

## Real issue found and fixed during this mission (build-only, caught before any flash)

**Test suites for `wifi-sdio-variant.sh` and `preempt-variant.sh` mutate the real, tracked
vendor DTS and fragment config files directly (not isolated fixtures), and leave them at their
own baseline test case (W0/R0) when they finish.** Phase 3 (apply W3+R1) was followed by Phase
4 (run all relevant test suites, including these two) before Phase 5 (build) — the test suites
silently reset the variant state back to baseline in between, and the *first* Alpha-Max-RT
build attempt (`alpha-max-rt-build.log`) produced a plain W0/R0 image despite Phase 3 having
correctly applied W3/R1 beforehand. Caught by directly inspecting the built artifact's
`kernel_config_sha256`/`device_tree_sha256`/live `CONFIG_PREEMPT_RT`/DTS content rather than
trusting exit 0 — this project's own established discipline, applied again, caught a real
process-ordering mistake. Fixed by re-applying W3+R1 *immediately* before relaunching the build
with no intervening steps, and re-verifying the applied state was embedded directly in the new
build log for anyone auditing it later. The corrected retry build was independently confirmed
byte-consistent with the already-known-correct B3 (`device_tree_sha256`) and B4
(`kernel_config_sha256`) hashes from earlier in this session's Mode B testing — strong
independent evidence the fix actually worked, not just that the immediate check passed.

**Process learning, not yet fixed in source**: any future variant-build mission should apply
W3/R1 (or run any repo-mutating test suite) as the *last* step before invoking the real build,
or the test suites should be changed to operate against isolated fixture copies instead of the
live tracked files. Neither fix was made in this session (out of this mission's explicit scope,
and the workaround — reordering operations — was sufficient to complete safely).

## Repository state after this mission

Both variant markers (SDIO, PREEMPT) were reset back to baseline (W0/R0) after packaging, and
the tracked reference-artifact files (`build-manifest.txt`, `halley5_v30.dts`, `kernel.config`
under `artifacts/buildroot-halley5-v30-image/`) were reverted to their last-committed state via
`git checkout --` — the same established precedent from every prior variant build this session
(the deployment package under `build-work/deploy-packages/` is where this build's real,
non-reverted artifacts live; the tracked reference files are meant to reflect the production
default, not any one experimental variant). Final `06-verify.sh` run clean, 0 unexpected MISS
lines. No production tag was created. No production selections were committed.
