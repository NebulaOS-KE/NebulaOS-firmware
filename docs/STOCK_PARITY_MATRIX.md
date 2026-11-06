# Stock Functional Parity Matrix

Part of the Nebula Pad stock-parity / board-port audit (see `FIRMWARE.md`). Compares the working
stock firmware (Linux 4.4.94) against the custom firmware (Linux 6.6.18-rt23) at a comparable boot
stage, using the read-only captures in `artifacts/parity/stock/` and `artifacts/parity/custom/`
(produced by `scripts/parity/capture-state.sh`).

**Status: in progress.** This is Phase 1 of the audit - the first pass through the raw captures,
covering driver/module parity and the platform-device inventory. Later phases (pin ownership map,
live pinctrl/GPIO register comparison, per-subsystem deep audits) will extend this table, not
replace it.

The printer mainboard is physically disconnected for this whole audit. Every printer-mainboard-
dependent row is `BLOCKED_MAINBOARD_NOT_CONNECTED`, not a pass - configuration/pinmux correctness
was checked, real MCU communication was not.

## Classifications used

- `PARITY_CONFIRMED` - same real capability present and working on both, verified with live evidence.
- `EXPECTED_DIFFERENCE` - the two systems are legitimately different by design (e.g. built-in vs.
  loadable-module drivers, different DT node names for the same real hardware, mainline brcmfmac vs.
  stock's out-of-tree cywdhd for the same WiFi chip) and this has already been investigated/documented
  elsewhere in this project.
- `CUSTOM_REGRESSION` - stock has a real, working capability that custom is missing and has no
  built-in equivalent for.
- `UNKNOWN_NEEDS_MEASUREMENT` - a real difference was found in the raw capture but not yet chased down
  to a root cause.
- `BLOCKED_MAINBOARD_NOT_CONNECTED` - cannot be tested until the printer mainboard is reconnected.

## Boot and core system

| Feature | Stock evidence | Custom evidence | Status | Notes |
|---|---|---|---|---|
| Boot to userspace | `artifacts/parity/stock/01-uname.txt` | `artifacts/parity/custom/01-uname.txt` | PARITY_CONFIRMED | Linux 4.4.94 vs. 6.6.18-rt23, both boot to a working shell. |
| OTA A/B slot + automatic fallback | Not applicable (stock is the fallback target) | `S00revert-safety`/`S99confirm-good`, verified this session: `ota:kernel2` committed automatically after a real reboot | SUPERSEDED — see note | See `FIRMWARE.md` sec 21-23, 54. **Note (Phase 1.8B):** automatic marker-writing on both the arm-on-boot and confirm-good paths was removed in `phase1.8b/boot-safety` (booting stock auto-flashes and destroys the qualified MCU firmware, so an automatic fallback was a hardware-safety risk, not a convenience worth keeping). This row documents what was true when originally captured; current behavior is in `docs/A_B_SLOT_MODEL.md`. |
| Root filesystem | `/dev/root /rom squashfs ro` + `overlayfs` writable layer on `mmcblk0p9`, `/usr/data` on `mmcblk0p10` (both real, persistent ext4) | `/dev/root / squashfs ro` + `tmpfs` on `/opt/printer_data` and `/usr/data` | EXPECTED_DIFFERENCE | Deliberate, documented tradeoff for an unproven test image (`FIRMWARE.md` sec 24) - custom has no persistent writable storage of its own yet; a real, separate follow-up. |

## Driver / kernel-module parity (stock `lsmod` vs. custom kernel config)

Stock loads every real hardware driver as a `.ko` module (see `artifacts/parity/stock/10-lsmod.txt`).
Custom's `lsmod` is empty by design - everything is compiled `=y` into `vmlinux` instead of `=m`
(`FIRMWARE.md`, `06-verify.sh`'s own "built-in kernel drivers" section). Each stock module was
cross-checked against custom's real `kernel.config` symbol (not guessed - resolved against this
project's actual kernel source tree, since the vendor's own Kconfig option names don't follow
upstream naming, e.g. `INGENIC_WDT` not `*_WATCHDOG*`, `PWM_INGENIC_V2` not `PWM_JZ*`).

| Stock module | Real capability | Custom kernel config symbol | Status | Notes |
|---|---|---|---|---|
| `soc_watchdog` | Hardware watchdog | `CONFIG_INGENIC_WDT=y` | PARITY_CONFIRMED | Built-in on custom. |
| `soc_efuse` | eFuse/OTP read | `CONFIG_INGENIC_EFUSE_X2000` **is not set** | **CUSTOM_REGRESSION** (bounded follow-up done, see below) | Real gap - the exact driver exists in this kernel tree (`module_drivers/drivers/misc/ingenic_efuse_x2000.c`) but isn't enabled. `CONFIG_INGENIC_EFUSE_WRITABLE` is a *separate* option and must stay off (OTP writes are irreversible - see safety rules). |

### eFuse bounded follow-up (real interface confirmed, exact consumer not identified)

On the real, running stock device: `/sys/class/misc/efuse-string-version` is a real `misc_register()`
device (`/dev/efuse-string-version`, major 10 minor 50, `crw------- root root`), not a plain sysfs
attribute file - it exposes only the standard misc-device boilerplate (`dev`, `power`, `subsystem`,
`uevent`), no custom readable attribute. A plain `cat`/read on `/dev/efuse-string-version` returns
`EINVAL` ("Invalid argument"), meaning the driver expects a structured `ioctl()` call, not a simple
`read()` - a genuine, purpose-built interface, not something opened casually by a shell script.
`Modules linked in: ... soc_efuse(O) ...` confirms the module is loaded (tainted, out-of-tree, as
expected for all of stock's vendor modules). No consumer *binary* was positively identified in this
bounded pass - a broader userspace `grep -r` repeatedly hit this device's own SSH session timeout and
did not complete (inconclusive, not negative evidence).

**Classification: real interface exists and behaves like a genuine production consumer would use it
(ioctl-gated, root-only, named for a specific purpose - a version string), but the exact consumer
binary is not confirmed.** This is stronger evidence for a real consumer than "interface merely
exists" and weaker than "consumer binary found and inspected". Default action holds:
`CONFIG_INGENIC_EFUSE_X2000` stays disabled on custom - the mission's own default conclusion
("leave disabled unless a real required consumer is proven") is the correct call given what's
confirmed versus what remains open.
| `ns2009_touch` | NS2009 resistive touch | `CONFIG_TOUCHSCREEN_NS2009=y` | PARITY_CONFIRMED | |
| `lcd_general_480x272` | Display panel | `CONFIG_STAGE_OPENKE_GENERAL_480X272=y`, `CONFIG_FB_INGENIC=y` | PARITY_CONFIRMED | |
| `hci_uart_h5_kernel_4_4_94` | Bluetooth H5 transport | custom's own `openke,bcm4343x-bt` H5 driver (`drivers/bluetooth/hci_h5.c`, this project's addition) | EXPECTED_DIFFERENCE | Different driver, same real transport/chip. BT itself is a documented, real, unfixed hardware pin-conflict with touch (`i2c4` vs. `uart3` share the same two physical pins) - see the kernel fork's `uart3` DTS comment, commit `095970ba2`. |
| `cywdhd` | Broadcom WiFi/BT combo driver | mainline `brcmfmac` (built-in) | EXPECTED_DIFFERENCE | Deliberate architecture choice, extensively documented across `FIRMWARE.md` - this is the whole WiFi bring-up story. WiFi itself is PARITY_CONFIRMED (real DHCP lease, verified this session). |
| `soc_dtrng` | Hardware TRNG | `CONFIG_INGENIC_HW_RANDOM=y` | PARITY_CONFIRMED | |
| `soc_msc` | eMMC/SD/SDIO controller | `CONFIG_MMC_SDHCI_INGENIC=y` | PARITY_CONFIRMED | |
| `soc_fb`, `soc_fb_layer_mixer`, `soc_rotator` | Display pipeline | `CONFIG_FB_INGENIC*=y` | PARITY_CONFIRMED | |
| `pwm_backlight` | Backlight PWM | `CONFIG_BACKLIGHT_PWM=y` | PARITY_CONFIRMED | |
| `soc_pwm` | PWM controller | `CONFIG_PWM_INGENIC_V2=y` | PARITY_CONFIRMED | |
| `soc_gpio` | GPIO controller | `CONFIG_PINCTRL_INGENIC=y`, `CONFIG_PINCTRL_INGENIC_V2=y` | PARITY_CONFIRMED | |
| `soc_i2c` | I2C controller | `CONFIG_I2C_INGENIC=y` | PARITY_CONFIRMED | |

## `/proc/devices` (character/block major differences)

| Item | Stock | Custom | Status | Notes |
|---|---|---|---|---|
| `i2c` (major 89, i2c-dev chardev) | Present | **Absent** | UNKNOWN_NEEDS_MEASUREMENT | Kernel-space I2C drivers (touch) don't need this, but its absence means no `/dev/i2c-N` for userspace tools (`i2cdetect`, etc.) on custom - confirmed by `custom/23-i2cdetect-list.txt` being empty. Need to check `CONFIG_I2C_CHARDEV` in kernel.config; if genuinely off, this blocks safe, read-only I2C bus inventory work in later phases without a kernel config change. |
| `ttyACM`, `ttyUSB` | Present | Absent | UNKNOWN_NEEDS_MEASUREMENT | No `CONFIG_USB_ACM`/`CONFIG_USB_SERIAL` built-in on custom - relevant to the Phase 4 USB audit (USB-serial adapters wouldn't get a `/dev/ttyUSBx` node). Not currently needed for anything working; noted as a gap for future USB-serial use. |
| `ptp`, `pps` | Present | Absent | EXPECTED_DIFFERENCE (probable) | Hardware timestamping / pulse-per-second - no known use case on this board; likely just default kernel config difference, not investigated further. |
| `mtdblock_bbt_ro` | Present | Absent | UNKNOWN_NEEDS_MEASUREMENT | Suggests stock's kernel config includes MTD/NAND support (bad-block-table read-only block device). Worth checking against the Phase 4 SPI/QSPI audit - is there a SPI-NOR/NAND boot flash this represents, and does custom need equivalent read access? |
| `rpmb`, `gpiochip` | Absent | Present | EXPECTED_DIFFERENCE | Newer kernel exposing eMMC RPMB and the modern GPIO character-device ABI - both are additions, not regressions. |
| `ttyprintk` | Absent | Present | EXPECTED_DIFFERENCE | Kernel debug console feature, harmless. |

## Platform device inventory (`/sys/bus/platform/devices`)

Full raw lists: `artifacts/parity/stock/13-platform-devices.txt`,
`artifacts/parity/custom/13-platform-devices.txt`.

| Item | Stock | Custom | Status | Notes |
|---|---|---|---|---|
| USB OTG controller | `13500000.otg_new`, `10000000.otg_new_phy` | `13500000.otg` (different DT node name) | PARITY_CONFIRMED | **Checked, not assumed**: custom's `dmesg` shows `dwc2 13500000.otg: DWC OTG Controller`, `new USB bus registered`, hub found, `usb-storage`/`uvcvideo`/`usbkbd`/`usbmouse` interface drivers all registered. Real, working USB host. The platform-device name mismatch is a DT node-naming difference only. |
| `uart0` (`10030000.serial`) | Present, active | Absent | EXPECTED_DIFFERENCE | Intentional - disabled this session, real pin conflict with `msc0`/eMMC, unused by anything. Kernel fork commit `095970ba2`. |
| `uart2` (`10032000.serial`) | Present | Absent | EXPECTED_DIFFERENCE | Custom DTS explicitly sets `status = "disable"`; not used by anything in this project. |
| `uart5`, `uart6`, `uart7` (`10035000`/`10036000`/`10037000`.serial) | Present | Absent | UNKNOWN_NEEDS_MEASUREMENT | Not yet determined what stock uses these for, if anything real (could be enabled-but-idle defaults). Needs the DTB diff (Phase 2) and a check of what physically connects to these pins before deciding whether custom is missing something real. |
| `i2c0` (`10050000.i2c`) | Present | Absent (custom has `i2c3`/`10053000.i2c` and `i2c4`/`10054000.i2c` instead) | UNKNOWN_NEEDS_MEASUREMENT | Stock enables a different I2C controller instance than custom. Touch is confirmed on `i2c4` on both (prior investigation, `/sys/bus/i2c/devices/4-0048/name`), so this isn't the touch bus - what stock puts on `i2c0` isn't yet identified. Needs the Phase 2 DTB diff to resolve. |
| `134da000.as-dmic` (audio DMIC) | Present, real device node | Absent | EXPECTED_DIFFERENCE | Already-documented, real, unfixed gap - `FIRMWARE.md`'s audio investigation. Confirms stock genuinely has a populated DMIC; custom's `snd_soc_register_card failed -517` deferred-probe loop is the DAI never registering because this node/driver isn't present. Classified `AVAILABLE_DISABLED` pending the Phase 4 audio feasibility study (do not restore without checking for a pin conflict with touch/eMMC/BT/printer UART first, per the mission's explicit instruction). |
| `spi_gpio` | Present | Absent | UNKNOWN_NEEDS_MEASUREMENT | Stock has a bit-banged GPIO SPI bus. What it drives isn't yet identified - Phase 4 SPI/QSPI audit item. Do not probe/enable until the connected device is identified (safety rule: no transactions to an unidentified SPI device). |
| `13490000.msc` (MSC2) | Absent | Present | UNKNOWN_NEEDS_MEASUREMENT | Custom registers an MSC2 platform device stock doesn't show. Prior project history found stock's *real* DTB has MSC2 disabled (it's actually an SD-slot definition, not eMMC) - `FIRMWARE.md` sec 31/32. Needs the Phase 2 DTB diff plus a physical check of whether this board has a populated microSD slot before this is investigated further; do not drive any power-enable pin on it until then. |
| `134a0000.mac` (onboard GMAC) | Absent | Present | EXPECTED_DIFFERENCE (probable regression risk: none) | Custom's kernel registers the SoC's Ethernet MAC as a platform device; stock does not expose it at all. Prior `dmesg` evidence (both systems) shows "no PHY found"/"MII Probe failed" - no PHY is physically populated on this board either way, so this is inert either way. Candidate for explicit `status = "disabled"` in the DTS to match stock's approach exactly, tracked as a Phase 7 capability-matrix item, not urgent. |
| `ingenic-aux.0`-`.5` (ADC channels) | Absent | Present | UNKNOWN_NEEDS_MEASUREMENT | 6 ADC channels registered on custom that stock doesn't expose as platform devices. Phase 4 ADC audit item - what stock does with the same physical ADC hardware (different driver/registration path, or genuinely unused) isn't resolved yet. Read-only sampling only, once voltage ranges are confirmed safe (safety rules). |
| `gpio_keys` | Absent | Present | UNKNOWN_NEEDS_MEASUREMENT | Custom has a `gpio_keys` input device stock doesn't show under this name. Needs the DTB diff to see what buttons/pins this maps to and whether stock handles the same physical buttons under a different driver. |

## WiFi / Bluetooth

| Feature | Stock evidence | Custom evidence | Status | Notes |
|---|---|---|---|---|
| WiFi association + DHCP | Working (this is the reference stock behavior the whole WiFi investigation targeted) | `wpa_state=COMPLETED`, real DHCP lease `192.168.1.146`, reachable by `ping`/`ssh` - re-verified this session | PARITY_CONFIRMED | |
| Bluetooth | `hci_uart_h5_kernel_4_4_94` loaded, real BT UART pins claimed | `uart3` pin claim fails - `i2c4` (touch) already owns the same two physical pins | **CUSTOM_REGRESSION** (known, documented, not fixed) | Real hardware pin-sharing constraint, not a driver bug - see kernel fork commit `095970ba2`'s `uart3` DTS comment. Fixing this needs stock's own dynamic pin hand-off behavior (`bt_enable_bsa.sh` releases `i2c4` before claiming `uart3`), not a static DT change. Touch is the higher-priority, confirmed-working peripheral; this stays a known limitation pending a real runtime pin-switching implementation. |

## App stack (custom-only, no stock equivalent)

| Feature | Evidence | Status |
|---|---|---|
| Moonraker | `/server/info` returns full healthy `"result"`, `klippy_connected: true` | PARITY_CONFIRMED (custom-only feature, working as intended) |
| Klipper | Parses `printer.cfg`, stops at a real `bltouch` `z_offset` value only the physical owner can provide | BLOCKED_MAINBOARD_NOT_CONNECTED for anything beyond config parsing |
| GuppyScreen | Running (`ps` confirms process alive) | PARITY_CONFIRMED |
| SQLite (Moonraker's database) | N/A | PARITY_CONFIRMED - `PRAGMA integrity_check` returns `ok` |

## Printer-mainboard-dependent (all blocked this audit)

| Feature | Status |
|---|---|
| Printer MCU serial link (`uart1`, per `printer.cfg`'s `/dev/ttyS1`) | BLOCKED_MAINBOARD_NOT_CONNECTED for real communication - but SoC-side software equivalence now `CONNECTION_GATE_PASS_SOFTWARE_EQUIVALENCE` (2026-07-23): pinmux, register semantics, clock/IRQ/MMIO, voltage domain, and protocol identity all confirmed matching stock via `S13mcu_update`/`mcu_util`. See `docs/PRINTER_MAINBOARD_PRECONNECTION_CHECKLIST.md`. |
| Heaters | BLOCKED_MAINBOARD_NOT_CONNECTED |
| Thermistors / ADC-based temperature sensing | BLOCKED_MAINBOARD_NOT_CONNECTED |
| Steppers | BLOCKED_MAINBOARD_NOT_CONNECTED |
| Fans (mainboard-controlled) | BLOCKED_MAINBOARD_NOT_CONNECTED |
| Endstops | BLOCKED_MAINBOARD_NOT_CONNECTED |
| BLTouch | BLOCKED_MAINBOARD_NOT_CONNECTED - Klipper's own config parsing gets as far as requiring `z_offset`, a real physical calibration value |

## Open items for the next pass

1. **Done**: `i2c0`, `uart5`/`6`/`7`, `spi_gpio`, and `MSC2` all resolved via the Phase 2 DTB diff and
   follow-up bounded investigations - see `docs/DTB_PARITY_REPORT.md` and
   `docs/PIN_OWNERSHIP_MAP.md`. `MSC2` fixed and verified (`72236226a`).
2. **Confirmed**: `CONFIG_I2C_CHARDEV` is off (`# CONFIG_I2C_CHARDEV is not set`). This is a
   zero-risk, non-hardware-behavior kernel config change (adds `/dev/i2c-N` chardev nodes only,
   touches no pins/timing/drivers) worth enabling before the Phase 4 I2C bus audit, since that audit
   explicitly prefers device-tree/driver inventory over generic bus probing, but still needs
   `/dev/i2c-N` to exist for known-address reads. Not yet done.
3. `gpio_keys` and `ingenic-aux.*` need the full pin ownership map (Phase 3B, not yet done - only the
   dispute-specific pins from Phase 3A are mapped so far).
4. The one confirmed regression (`CONFIG_INGENIC_EFUSE_X2000` off) had its bounded consumer follow-up
   completed - see the eFuse section above. Default action (leave disabled) holds; a future,
   narrowly-scoped enablement remains a candidate but isn't justified by what's confirmed so far.
5. **New from this pass**: `uart1` (printer MCU link) and its real, active conflict with `lcd_vdd_en`
   - fixed and verified, `970bd6b83`. `bt_reg_on` (`GPD-5`) classified `BT_POWER_REQUIRED` (high
   confidence) but not implemented on custom.
