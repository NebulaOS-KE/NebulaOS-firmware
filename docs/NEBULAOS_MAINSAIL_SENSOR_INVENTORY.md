# NebulaOS Mainsail Sensor Inventory (RC2 closure)

Full hardware/sensor inventory of the composed Klipper config for the
Ender-3 V3 KE, as it actually ships in this worktree — not from memory of
similar projects. Built by reading, in this order:

- `scripts/build/overlay/opt/printer_data/config/printer.cfg` (the persistent
  entrypoint and its `[include ...]` chain)
- `scripts/build/overlay/etc/nebulaos/klipper/{platform,machine,prtouch,
  z_offset_probe,calibration,homing,print,filament,camera,beeper}.cfg`
- `scripts/build/overlay/etc/nebulaos/klipper/load_cell_probe.cfg` (present on
  disk but **not** in printer.cfg's include list — see its own entry below)
- `NebulaOS-klipper-extensions/extras/*.py` — every module's real
  `get_status()` return dict was read directly from source, not guessed
- `NebulaOS-klipper-extensions/nebulaos-extensions.json` (the composition
  manifest — confirms which extras are actually composed into
  `klippy/extras/` vs. merely vendored)

printer.cfg's real include order (load-bearing, per its own header comment):
`platform.cfg → machine.cfg → prtouch.cfg → z_offset_probe.cfg →
calibration.cfg → homing.cfg → print.cfg → filament.cfg → camera.cfg →
beeper.cfg`, followed by a real, live `SAVE_CONFIG` autosave block (bltouch
z_offset, extruder PID + rotation_distance, heater_bed PID).

A full `find` across `scripts/build/overlay` for `*.cfg` turned up exactly
these 11 files plus `load_cell_probe.cfg` at RC2 time — there is no other
`.cfg` anywhere in the overlay tree, so there is no hidden duplicate
sensor/heater/fan/MCU section outside what's inventoried below.
**Update, final pre-hardware closure (2026-09-06): `load_cell_probe.cfg` has
since been removed from the overlay entirely — see its entry in §3 and the
STATUS totals below, both updated to reflect its removal.**

Legend for STATUS: OK, DUPLICATE, STALE, BROKEN, INTERNAL_ONLY,
NOT_SUPPORTED_BY_MAINSAIL_UI.

---

## 1. Motion / stepper MCU

| OBJECT_NAME | CONFIG_SECTION | PHYSICAL_HARDWARE | OWNER | DATA_SOURCE | EXPECTED_KLIPPER_STATUS_FIELDS | MAINSAIL_NATIVE_SURFACE | EXPECTED_USER_VISIBLE_NAME | SHOULD_BE_VISIBLE | SHOULD_BE_INTERNAL | STATUS |
|---|---|---|---|---|---|---|---|---|---|---|
| `mcu` | `[mcu]` (machine.cfg) | Real GD32F303 stepper MCU, `/dev/ttyS1`, 230400 baud | Upstream Klipper | Serial handshake with the GD32F303 firmware | `mcu_version`, `mcu_build_versions`, `mcu_constants`, `last_stats` (via `printer.mcu`) | Mainsail's Machine panel "MCU(s)" list, plus the firmware-restart/shutdown reason surface | "MCU" | Yes | No | OK |
| `mcu rpi` | `[mcu rpi]` (machine.cfg) | Same physical SoC as the main board, running Klipper's own `klipper_mcu` (MACH_LINUX target) over a Unix socket at `/tmp/klipper_host_mcu` — **not** the GD32F303, no relation to `[mcu]` above | Upstream Klipper (`klipper_mcu`), integrated by NebulaOS Phase 1.9A | Unix-socket handshake with the host-side virtual MCU process | Same shape as any `mcu` object | Mainsail Machine panel lists it as a second MCU entry, labelled "rpi" | "MCU rpi" | Yes | No | OK — by design a second, real (virtual) MCU; the two-MCU listing in Mainsail's machine panel accurately reflects the real Phase 1.9A architecture, not a bug |
| `stepper_x` / `stepper_y` / `stepper_z` | `[stepper_x]`/`[stepper_y]`/`[stepper_z]` (machine.cfg) | Real X/Y/Z stepper motors + physical X/Y endstops, Z uses `probe:z_virtual_endstop` | Upstream Klipper | GD32F303 step/dir/enable pins + endstop pins | Standard stepper status (position, endstop state) | Not surfaced individually; feeds the toolhead position readout | n/a (motion, not a discrete sensor) | n/a | n/a | OK |
| `tmc2208 stepper_x` / `_y` / `_z` | `[tmc2208 stepper_x/y/z]` (machine.cfg) | Real TMC2208 UART drivers on the GD32F303 | Upstream Klipper | UART register reads (current, microsteps, stealthchop) | `run_current`, `hold_current`, driver register fields (via `tmcstatus`, see §5) | No dedicated Mainsail TMC panel; current/microstep values are visible only in the raw config, not as a live widget | n/a | n/a | n/a | OK |

## 2. Heaters, temperature sensors, fans

| OBJECT_NAME | CONFIG_SECTION | PHYSICAL_HARDWARE | OWNER | DATA_SOURCE | EXPECTED_KLIPPER_STATUS_FIELDS | MAINSAIL_NATIVE_SURFACE | EXPECTED_USER_VISIBLE_NAME | SHOULD_BE_VISIBLE | SHOULD_BE_INTERNAL | STATUS |
|---|---|---|---|---|---|---|---|---|---|---|
| `extruder` | `[extruder]` (machine.cfg) | Real hotend heater (PA1) + EPCOS 100K thermistor (PC5) | Upstream Klipper | ADC + PWM on the GD32F303 | `temperature`, `target`, `power`, `pressure_advance`, `smooth_time` | Native Mainsail temperature graph + heater control panel | "Extruder" | Yes | No | OK |
| `heater_bed` | `[heater_bed]` (machine.cfg) | Real heated bed (PB2) + EPCOS 100K thermistor (PC4) | Upstream Klipper | ADC + PWM on the GD32F303 | `temperature`, `target`, `power` | Native Mainsail temperature graph + heater control panel | "Heater Bed" | Yes | No | OK |
| `temperature_sensor mcu_temp` | `[temperature_sensor mcu_temp]` (machine.cfg) | Real GD32F303 on-die temperature sensor | NebulaOS (`nebulaos_temperature_mcu.py`, subclass of upstream `temperature_mcu.PrinterTemperatureMCU` — only chip-curve dispatch (`GD32_CURVES`) is NebulaOS code; ADC setup, min/max checking and status reporting are inherited unchanged from upstream) | Internal MCU ADC read via the GD32 die-temp curve | `temperature`, `measured_min_temp`, `measured_max_temp` (inherited upstream shape — nothing custom) | Native Mainsail temperature-sensor graph (auto-appears for any `[temperature_sensor ...]`) | "mcu_temp" | Yes | No | OK |
| `verify_heater extruder` / `verify_heater heater_bed` | `[verify_heater extruder]` / `[verify_heater heater_bed]` (machine.cfg) | Not a separate physical sensor — a watchdog over the two heaters above (`check_gain_time`, `heating_gain`, `hysteresis`) | Upstream Klipper | Derived from the heater objects it watches | No independent `get_status()` surface of note; only fires a shutdown if heating stalls | None — Klipper's own safety mechanism, invisible until it trips | n/a | No | Yes | INTERNAL_ONLY |
| `fan` | `[fan]` (machine.cfg, PA0) | Real part-cooling fan | Upstream Klipper | PWM on the GD32F303 | `speed`, `rpm` (rpm null, no tach pin configured) | Native Mainsail fan slider (part-cooling fan) | "Part Fan" | Yes | No | OK — replaced stock's patched-Klipper `[output_pin fan0]`+`SET_PIN` (confirmed removed; comment in machine.cfg documents the mission and no `fan0` output_pin exists anywhere in the overlay) |
| `heater_fan nozzle_fan` | `[heater_fan nozzle_fan]` (machine.cfg, PC1) | Real hotend cooling fan, thermally gated to `extruder` at 60°C | Upstream Klipper | PWM on the GD32F303 | `speed` | Native Mainsail "Fans" list, shown as an auto/status-only fan (not user-adjustable, matches its `heater_fan` semantics) | "nozzle_fan" | Yes | No | OK |
| `output_pin MainBoardFan` | `[output_pin MainBoardFan]` (machine.cfg, PB1) | Real mainboard/PSU cooling fan, always-on digital pin | Upstream Klipper | Digital pin on the GD32F303 | `value` | Mainsail "Miscellaneous" generic pin toggle | "MainBoardFan" | Yes | No | OK |

## 3. Z probing (BLTouch global probe + HX711 nozzle load cell)

| OBJECT_NAME | CONFIG_SECTION | PHYSICAL_HARDWARE | OWNER | DATA_SOURCE | EXPECTED_KLIPPER_STATUS_FIELDS | MAINSAIL_NATIVE_SURFACE | EXPECTED_USER_VISIBLE_NAME | SHOULD_BE_VISIBLE | SHOULD_BE_INTERNAL | STATUS |
|---|---|---|---|---|---|---|---|---|---|---|
| `bltouch` (registers Klipper's global `probe`) | `[bltouch]` (machine.cfg; `z_offset` supplied only via printer.cfg's `SAVE_CONFIG` block, deliberately not in machine.cfg — see that file's own comment and `NEBULAOS_CALIBRATION_CONFIG_OWNERSHIP.md`) | Real BLTouch on PC14 (sensor)/PC13 (control) | Upstream Klipper | Touch-mode probing on the GD32F303 | `z_offset`, `last_query`, `last_z_result` | Native Mainsail Z-Calibrate / probe panel | "BLTouch" | Yes | No | OK — remains the sole global Z-homing/bed-mesh probe, exactly as documented |
| `nebulaos_z_offset_probe` | `[nebulaos_z_offset_probe]` (z_offset_probe.cfg) | Real HX711 nozzle load cell, DOUT=PC6, SCLK=PA4 | NebulaOS (`nebulaos_z_offset_probe.py`) | HX711 ADC over the GD32F303's `hx71x`/SOS-trigger MCU commands; wraps upstream `load_cell.LoadCell` + `trigger_analog` | `last_trigger_time`, `is_calibrated`, `last_raw_trigger_z`, `last_fitted_contact_z`, `last_fit_delta`, `last_peak_force_g`, `last_peak_force_time`, `last_force_at_trigger_g`, `last_tare_counts`, `trigger_force`, `force_safety_limit`, `contact_speed` (all read directly from `get_status()`, line 334) | **None, by design.** Does not call `printer.add_object('probe', ...)`, so it never appears in Mainsail's probe/Z-Calibrate panel. Per the mission's own instruction, this is correct — it needs a working config object + console/API path (`LOAD_CELL_READ`/`LOAD_CELL_TARE`/`LOAD_CELL_CALIBRATE`/`LOAD_CELL_DIAGNOSTIC`, upstream `load_cell.LoadCell` commands; plus `NEBULAOS_Z_OFFSET_CALIBRATE`), not a permanent live graph | "Load Cell" (console/API only) | No (not a UI widget) — Yes (as an object queryable over the API) | Partially — console-facing by design, not dashboard-facing | OK |
| `load_cell_probe` (upstream `[load_cell_probe]`) | `load_cell_probe.cfg` — **file exists on disk but is NOT in printer.cfg's include list** | Same physical HX711 wiring (DOUT=PC6, SCLK=PA4) as `nebulaos_z_offset_probe` above | Upstream Klipper (`hx71x.py` + `load_cell_probe.py`) | Would be HX711 ADC over the same MCU commands, if ever included | n/a — never instantiated | n/a — never instantiated | n/a | No | No | **STALE** — this file is an abandoned earlier design (using upstream `load_cell_probe` *as the global Z probe*, replacing BLTouch entirely) that was superseded by the shipped architecture (BLTouch stays global probe; `nebulaos_z_offset_probe` uses the same HX711 wiring only for per-print Z-offset fine-tuning). The file's own header says "DO NOT INCLUDE THIS FILE YET / provided for hardware qualification only," so it is not live and not a runtime bug, but it is a dead, superseded design artifact still shipping on the read-only rootfs with no current qualification path forward — worth deleting or clearly marking historical/archived rather than leaving as a live-looking config file that could be hand-included by a future maintainer onto hardware whose canonical Z-offset path has moved on |
| `z_compensate` | `prtouch.cfg` (file kept at its historical path/name; its old `[prtouch_v2]` section is fully removed — confirmed by reading the file: it now contains only `[z_compensate]`) | No new physical hardware of its own — orchestrates the BLTouch + `nebulaos_z_offset_probe` HX711 pairing above | NebulaOS (`z_compensate.py`) | Combines `bltouch`/`probe` position with `nebulaos_z_offset_probe` touch results | `calibration_id`, `calibration_state`, `calibration_z_offset`, `calibration_error` (`get_status()`, line 338) | No dedicated panel; queryable via API, invoked via macros (see `NEBULAOS_CORE_PUBLIC_API.md`) | n/a | No | Yes (status object backing macros, not a standalone dashboard widget) | OK |
| Old "prtouch" sensor objects | — | — | — | — | — | — | — | — | — | **OK (absent)** — `prtouch.cfg` was read directly: no `[prtouch_v2]`, no `prtouch_mcu`/`prtouch_probe`/`prtouch_nozzle` reference anywhere in it or in `z_compensate.py` (confirmed by the file's own header, which documents the Phase 1.8B PRTouch removal). No stale PRTouch sensor object exists in the composed config. `prtouch_test_support.py` remains in the extensions manifest (`role: runtime`) but backs no `[prtouch...]` config section — see Deliverable 2 / manifest note. |

## 4. Accelerometer (resonance testing / Input Shaper)

| OBJECT_NAME | CONFIG_SECTION | PHYSICAL_HARDWARE | OWNER | DATA_SOURCE | EXPECTED_KLIPPER_STATUS_FIELDS | MAINSAIL_NATIVE_SURFACE | EXPECTED_USER_VISIBLE_NAME | SHOULD_BE_VISIBLE | SHOULD_BE_INTERNAL | STATUS |
|---|---|---|---|---|---|---|---|---|---|---|
| `adxl345` | `[adxl345]` (machine.cfg) | Real ADXL345 wired directly to the SoC's SPI bus (`spidev2.0`), served through `mcu rpi` — not the GD32F303 | Upstream Klipper (unmodified `klippy/extras/adxl345.py`) | Real SPI accelerometer reads via the host MCU | Standard `adxl345` status (last measurement values on query); no continuous polling in normal operation | **None, intentionally.** Mainsail has no native accelerometer live-graph; per the mission's own instruction, this only needs a correct config object + a working `ACCELEROMETER_QUERY`/`TEST_RESONANCES`/`SHAPER_CALIBRATE` console path — not a permanent dashboard graph, and none was invented here | "adxl345" (console/API only) | No (no live widget) | No (real hardware, just not dashboard-surfaced) | OK |
| `resonance_tester` | `[resonance_tester]` (machine.cfg) | No hardware of its own — drives `adxl345` above during `TEST_RESONANCES`/`SHAPER_CALIBRATE` | Upstream Klipper | Configured envelope: `accel_per_hz: 50`, `probe_points: 117.5,117.5,100`, `max_freq: 80` (hardware-qualified Phase 2 §6 values, confirmed in the file's own comment) | n/a (command-driven, not a polled status object) | None (console/API only) | n/a | No | No | OK |
| `input_shaper` | `[input_shaper]` (machine.cfg, empty section — just enables the object) | No hardware of its own | Upstream Klipper | Populated by `SAVE_INPUT_SHAPER` (see `calibrate_shaper_config.py`, Deliverable 2) after a `SHAPER_CALIBRATE` run | `shaper_type_x`, `shaper_freq_x`, `shaper_type_y`, `shaper_freq_y` | No dedicated Mainsail panel/graph; values readable via API only | n/a | No | No | OK |

## 5. TMC driver status (GuppyScreen-only)

| OBJECT_NAME | CONFIG_SECTION | PHYSICAL_HARDWARE | OWNER | DATA_SOURCE | EXPECTED_KLIPPER_STATUS_FIELDS | MAINSAIL_NATIVE_SURFACE | EXPECTED_USER_VISIBLE_NAME | SHOULD_BE_VISIBLE | SHOULD_BE_INTERNAL | STATUS |
|---|---|---|---|---|---|---|---|---|---|---|
| `tmcstatus` | `[tmcstatus]` (platform.cfg) | Real TMC2208 driver registers (DRV_STATUS, stallguard/current fields) for X/Y/Z | NebulaOS (`tmcstatus.py`) | Cached register reads (2026-08 reactor-crash fix: `get_status()` returns only a pre-collected cache, never a synchronous register read) | `drv_status`, `hstrt`, `hend`, `pwm_autoscale`, `pwm_autograd`, `pwm_grad`, `pwm_ofs`, `pwm_reg`, `pwm_lim`, `tpwmthrs`, `en_spreadcycle`, `tbl`, `toff`, `tcoolthrs`, `semin`, `semax`, `seup`, `sedn`, `seimin`, optionally `sg_result`, `i_rms`, `en_pwm_mode` (per-driver dict, `get_status()` line 83) | **None in Mainsail.** By design: platform.cfg's own comment says this is "dynamically loaded on demand by GuppyScreen's TMC status panel via `_GUPPY_LOAD_MODULE SECTION=tmcstatus`" — a touchscreen-firmware consumer, not a Mainsail one | n/a (GuppyScreen only) | No | Yes | INTERNAL_ONLY — correct, not a gap |

## 6. NebulaOS platform/version/compat status objects

| OBJECT_NAME | CONFIG_SECTION | PHYSICAL_HARDWARE | OWNER | DATA_SOURCE | EXPECTED_KLIPPER_STATUS_FIELDS | MAINSAIL_NATIVE_SURFACE | EXPECTED_USER_VISIBLE_NAME | SHOULD_BE_VISIBLE | SHOULD_BE_INTERNAL | STATUS |
|---|---|---|---|---|---|---|---|---|---|---|
| `nebulaos_compat` | `[nebulaos_compat]` (platform.cfg, must load first) | No hardware — a fail-closed preflight gate (manifest/module/API/chelper verification) | NebulaOS (`nebulaos_compat.py`) | Reads `nebulaos-extensions.json` + Klipper git state at boot | `extensions_version`, `nebulaos_api_level`, `compat_schema_version`, `qualified_klipper_commit`, `installed_klipper_commit`, `managed_module_count`, `verified_composed_modules`, `registered_sensor_types`, `composition`, `chelper`, `status` (`get_status()`, line 548, wraps `run_preflight()`'s return dict) | None — diagnostic-only, not meant for a live dashboard | n/a | No | Yes | INTERNAL_ONLY |
| `nebulaos_version` | `[nebulaos_version]` (platform.cfg) | No hardware — reads `/opt/nebulaos-version.json`, `app-generation.json`, and live git state | NebulaOS (`nebulaos_version.py`) | Static, cached once at Klippy load (`_collect()`, not re-read per poll) | `firmware_tag`, `firmware_sha`, `kernel_sha`, `guppyscreen_sha`, `build_date`, `klipper_sha`, `klipper_dirty`, `app_generation`, `generation_recorded_at` | None currently — queryable via `/printer/objects/query?nebulaos_version`, no Mainsail widget consumes it yet | n/a | No (no current UI) | Yes (diagnostic, by its own docstring: "no control-loop role") | INTERNAL_ONLY |
| `nebulaos_power_loss_recovery` | `[nebulaos_power_loss_recovery]` (machine.cfg; `eeprom_path: /sys/bus/i2c/devices/2-0050/eeprom`) | Real BL24C16F EEPROM, now owned by the Linux 6.6 in-tree `at24`/`nvmem` driver (not `[bl24c16f]`/`i2c_mcu:rpi`, which owned it in Phase 1.9A and is deliberately not instantiated — see machine.cfg's own comment) | NebulaOS (`nebulaos_power_loss_recovery.py`) | Sysfs EEPROM reads + print-state tracking | `active_session`, `resume_in_progress`, `candidate_pending` (`get_status()`, line 802) | None as a live dashboard widget; exposed via `NEBULAOS_PLR_STATUS`/`NEBULAOS_PLR_RESUME`/`NEBULAOS_PLR_DISCARD` commands and the `nebulaos-recovery` Mainsail macro group (buttons only) | n/a | No (no status widget) | No (real recovery feature, console/macro-driven by design) | OK |
| `bl24c16f` (Python module) | Not instantiated by any config section (no `[bl24c16f]` anywhere in the composed tree) | Same physical BL24C16F EEPROM, but no longer this module's concern | NebulaOS (vendored, `extras/bl24c16f.py`) | n/a — dead code path in config terms | n/a | n/a | n/a | No | No | OK (retired by design) — machine.cfg's own comment states the module "stays vendored... for provenance only" after ownership moved to the kernel `at24`/`nvmem` driver; it is still listed with `"role": "runtime"` in `nebulaos-extensions.json`'s manifest (meaning the compat gate still requires the *file* to be composed into `klippy/extras/`), but backs no live printer object. Not a bug, but worth noting the manifest's "runtime" role label is slightly misleading for a module with zero active config sections — a documentation nit, not a functional defect |

## 7. Print-state / infrastructure objects (real Klipper status objects, not physical sensors)

| OBJECT_NAME | CONFIG_SECTION | PHYSICAL_HARDWARE | OWNER | DATA_SOURCE | EXPECTED_KLIPPER_STATUS_FIELDS | MAINSAIL_NATIVE_SURFACE | EXPECTED_USER_VISIBLE_NAME | SHOULD_BE_VISIBLE | SHOULD_BE_INTERNAL | STATUS |
|---|---|---|---|---|---|---|---|---|---|---|
| `exclude_object` | `[exclude_object]` (machine.cfg) | None — software object, populated by Moonraker's `[file_manager] enable_object_processing: True` (confirmed set in moonraker.conf) from sliced-gcode per-object polygons | Upstream Klipper | Slicer metadata via Moonraker | `objects`, `current_object`, `excluded_objects` | Native Mainsail "Exclude Object" panel | "Exclude Object" | Yes | No | OK |
| `bed_mesh` | `[bed_mesh]` (machine.cfg) | None directly — built from real BLTouch probe points (`probe_count: 9,9`) | Upstream Klipper | BLTouch probing | `profile_name`, `mesh_min`, `mesh_max`, `probed_matrix`, `profiles` | Native Mainsail Bed Mesh panel/graph | "Bed Mesh" | Yes | No | OK |
| `skew_correction` | `[skew_correction]` (machine.cfg, empty section) | None — software transform, unconfigured (no `xy_skew`/etc. values set) | Upstream Klipper | n/a until a user runs a skew calibration | Standard skew status fields, all defaults | No dedicated Mainsail panel | n/a | No | No | OK (feature present but dormant, not a gap) |
| `firmware_retraction` | `[firmware_retraction]` (machine.cfg) | None — G10/G11 retraction state | Upstream Klipper | Static config values | `retract_length`, `retract_speed`, `unretract_extra_length`, `unretract_speed` | No dedicated panel (used implicitly by slicer G10/G11 gcode) | n/a | No | Yes | INTERNAL_ONLY |
| `virtual_pins` | `[virtual_pins]` (print.cfg) | None — software pin abstraction | NebulaOS/vendored (`virtual_pins.py`) | Internal state only | `{pin_name: pin.get_status(eventtime)}` for each declared virtual pin (`get_status()`, line 88) | None directly | n/a | No | Yes | INTERNAL_ONLY |
| `output_pin Bed_Warp_Stabilisation` | `[output_pin Bed_Warp_Stabilisation]` (print.cfg) | **No physical pin at all** — `pin: virtual_pin:BED_WARP_STABILISE_pin`, a software flag consumed by `_WARP_STABILISE` in START_PRINT | Upstream Klipper `output_pin` object, backed by NebulaOS's `virtual_pins.py` | Internal flag, defaults `value: 0` (off; G112 Run 20 - `START_PRINT BED_SOAK=1` soaks per print) | `value` | Mainsail's generic "Miscellaneous" output-pin toggle would show this as if it were a real, user-toggleable GPIO — it is not real hardware | "Bed_Warp_Stabilisation" (misleading if surfaced as a hardware pin) | **Should be visible as a *setting* (whether bed-warp stabilisation is enabled), not as a generic hardware output-pin toggle** | Effectively yes — a config-level feature flag masquerading as an `output_pin` | INTERNAL_ONLY — flagged, not a broken object, but a naming/surface risk: a Mainsail user browsing the generic pin-toggle UI could mistake this for real hardware and toggle it not understanding it changes print-time bed-warp-wait behavior, not a physical pin |
| `virtual_sdcard`, `pause_resume`, `display_status`, `respond`, `idle_timeout` | print.cfg | None — Klipper core infrastructure | Upstream Klipper | n/a | Standard upstream fields | Native Mainsail print-progress / pause-resume / console surfaces | n/a | Yes (as part of core UI, not standalone) | No | OK |

## 8. Filament sensors

No `[filament_switch_sensor ...]` or `[filament_motion_sensor ...]` section
exists anywhere in the composed config (confirmed absent from filament.cfg,
machine.cfg, and every other included file). print.cfg's `_CLIENT_VARIABLE`
carries `variable_runout_sensor: ""` (blank/disabled by default) and all
runout-sensor logic in START_PRINT/END_PRINT/RESUME is written to degrade
gracefully (`if runout_sensor != ""`) when none is configured. **STATUS: OK
(absent)** — this printer genuinely has no filament runout sensor wired up;
this is not a missing-config bug, it is the correct state for hardware that
doesn't have one.

## 9. Camera

No Klipper-side sensor object — the webcam is a Moonraker/`crowsnest`-managed
device with quality controlled by three shell-backed macros
(`SET_CAMERA_QUALITY_LOW/MED/HIGH`, see `camera.cfg` and Deliverable 2); no
`[webcam ...]` section exists in moonraker.conf by design (the default camera
is seeded once into Moonraker's own database by `nebulaos-camera-seed`, not
config-defined — moonraker.conf's own comment explains why a config-defined
webcam would be undeletable). Not a Klipper sensor object, so out of scope
for this table beyond this note; covered from the macro/API angle in
Deliverable 2.

---

## Summary of things explicitly searched for and NOT found (STATUS = OK/absent)

- Stock Creality sensor definitions (e.g. patched-Klipper `[output_pin fan0]`
  + `SET_PIN`): absent, confirmed replaced by upstream `[fan]`.
- Old PRTouch sensor objects (`[prtouch_v2]`, `prtouch_mcu`, `prtouch_probe`,
  `prtouch_nozzle`): absent from every composed file.
- SimpleAF sensor helpers: none found beyond the macro-level SimpleAF
  provenance already documented in print.cfg/filament.cfg (KAMP purge/park,
  client macros) — no SimpleAF-specific sensor/status object exists.
- GuppyScreen-only status objects: exactly one, `tmcstatus` — correctly
  internal, by design, not a leftover.
- Duplicate temperature/fan/MCU objects: none — a full-tree grep for
  `temperature_sensor`/`[fan]`/`[heater_bed]`/`[extruder]`/`[mcu`/`[probe]`/
  `[bltouch]`/`[adxl345]`/`load_cell` across every `.cfg` in the overlay
  confirms each section is defined exactly once, in exactly one of the 11
  live cfg files.
- Retired load-cell aliases: none live. The one true stale artifact this
  project shipped, the **uncomposed** `load_cell_probe.cfg` file (§3 above),
  was removed from `scripts/build/overlay/etc/nebulaos/klipper/` entirely
  during the final pre-hardware closure (2026-09-06) — confirmed no active
  include, migration reference, test dependency, or doc requirement existed
  first (see `historical-reconciliation.md` §7). Its historical design
  rationale remains in git history (commit `6b170dc`), not as a live config
  file. `06-verify.sh` now asserts its absence from the built rootfs.
- ADXL345 defined but not really wired to `[mcu rpi]`: not the case — the
  single `[adxl345]` section is genuinely wired to `mcu rpi`'s SPI bus
  (`cs_pin: rpi:None`, `spi_bus: spidev2.0`), confirmed by direct read.

## STATUS bucket totals (this deliverable)

| STATUS | Count | Objects |
|---|---|---|
| OK | 24 | mcu, mcu rpi, stepper_x/y/z + tmc2208 x/y/z (counted as 1 row group), extruder, heater_bed, temperature_sensor mcu_temp, fan, heater_fan nozzle_fan, output_pin MainBoardFan, bltouch, nebulaos_z_offset_probe, z_compensate, prtouch (absent, OK), adxl345, resonance_tester, input_shaper, bl24c16f (retired by design), nebulaos_power_loss_recovery, exclude_object, bed_mesh, skew_correction, virtual_sdcard/pause_resume/display_status/respond/idle_timeout (1 group), filament sensor (absent, OK) |
| INTERNAL_ONLY | 8 | verify_heater extruder/heater_bed, tmcstatus, nebulaos_compat, nebulaos_version, firmware_retraction, virtual_pins, output_pin Bed_Warp_Stabilisation |
| STALE | 0 | `load_cell_probe.cfg` removed from the production overlay tonight (final pre-hardware closure, 2026-09-06) — no longer present to classify |
| DUPLICATE | 0 | none found |
| BROKEN | 0 | none found |
| NOT_SUPPORTED_BY_MAINSAIL_UI | 0 | none — every gap found (HX711, ADXL345, tmcstatus) is an intentional console/API-only surface per the mission's own instruction, not a Mainsail limitation being worked around |

Total objects inventoried: 32 (33 at RC2 time, minus the removed
`load_cell_probe.cfg` row; rows above group 2-4 physically
identical stepper/driver sections for brevity).
