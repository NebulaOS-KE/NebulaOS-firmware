# NebulaOS Core Public API (RC2 closure)

Every user-facing macro, plus the sensors/heaters/fans/MCUs/probes most
relevant from the API/macro angle, as they actually ship in this worktree.
Built by reading the composed config chain (`printer.cfg` → `platform.cfg`,
`machine.cfg`, `prtouch.cfg`, `z_offset_probe.cfg`, `calibration.cfg`,
`homing.cfg`, `print.cfg`, `filament.cfg`, `camera.cfg`, `beeper.cfg`), the
Klipper extras behind each private `_NEBULAOS_*`/backend command
(`NebulaOS-klipper-extensions/extras/*.py`), and
`scripts/build/overlay/usr/libexec/nebulaos-seed-mainsail-macros`'s
`DEFAULT_GROUPS` dict (hyphenated IDs, current as of tonight's RC2 rename:
`nebulaos-calibration`, `nebulaos-input-shaper`, `nebulaos-extruder`,
`nebulaos-camera`, `nebulaos-maintenance`, `nebulaos-recovery`).

This document is macro/API-focused; full hardware/sensor detail (get_status
field lists, physical wiring) lives in `NEBULAOS_MAINSAIL_SENSOR_INVENTORY.md`
— §10 below cross-references it rather than repeating it.

Legend for STATUS: OK, DUPLICATE, STALE, BROKEN, INTERNAL_ONLY,
NOT_SUPPORTED_BY_MAINSAIL_UI.

---

## 1. Calibration group — `nebulaos-calibration`

| CANONICAL_NAME | OWNER | DATA_SOURCE | USER_SURFACE | MAINSAIL_GROUP/PANEL | STATE_RESTRICTIONS | STATUS |
|---|---|---|---|---|---|---|
| `NEBULAOS_AUTO_CALIBRATE` | NebulaOS | Public wrapper (calibration.cfg) → private `_NEBULAOS_AUTO_CALIBRATE` (`nebulaos_calibration.py`, `cmd_auto_calibrate`) — full guided preflight→home→PID→nozzle-clean→Z-offset→bed-mesh→one-`SAVE_CONFIG` sequence, backed by `nebulaos_calibration_journal.py`'s persistent transaction journal | Mainsail macro button | `nebulaos-calibration` ("Calibration"), pos 0 | standby only (default: showInStandby=True, showInPrinting=False, showInPause=False) | OK |
| `NEBULAOS_Z_OFFSET_CALIBRATE` | NebulaOS | Public wrapper → private `_NEBULAOS_Z_OFFSET_CALIBRATE` (`cmd_z_offset_calibrate`) — LOAD_CELL-only bounded-descent BLTouch/HX711 paired calibration (`nebulaos_probe_pair.py`); requires the probe's `contact_ready()` for this caller first (today: a load cell calibration, `NEBULAOS_LOAD_CELL_CALIBRATE` or `LOAD_CELL_CALIBRATE`; raw contact only with a qualified profile, none exists) | Mainsail macro button | `nebulaos-calibration`, pos 1 | standby only | OK |
| `NEBULAOS_LOAD_CELL_CALIBRATE` | NebulaOS | Public wrapper → private `_NEBULAOS_LOAD_CELL_CALIBRATE` (`nebulaos_load_cell_calibration.py`, G86) — guided known-weight (1.5 L bottle) load cell calibration with re-place/zero/previous-change checks; `GRAMS=`/`NEXT=1`/`MEASURE=1`/`ACCEPT=1` steps, cancel `_NEBULAOS_LOAD_CELL_CANCEL`; status object `nebulaos_load_cell_calibration` (incl. `change_warning`) drives the screen's Load Cell page (G90) | Mainsail macro button + action prompts; NebulaScreen page | `nebulaos-calibration`, pos 8 | standby only | OK |
| `NEBULAOS_BED_TRAM` | NebulaOS | Public wrapper → private `_NEBULAOS_BED_TRAM` (`nebulaos_bed_tram.py`, G87) — guided bed tramming, one corner instruction at a time; cancel `_NEBULAOS_BED_TRAM_CANCEL`; status object `nebulaos_bed_tram` drives the screen's Bed Tramming page (G89) | Mainsail macro button + action prompts; NebulaScreen page | `nebulaos-calibration`, pos 9 | standby only | OK |
| `AXIS_TWIST_X` | Upstream UI adapter (NebulaOS-authored one-line wrapper only) | `AXIS_TWIST_COMPENSATION_CALIBRATE AXIS=X` — pristine upstream `axis_twist_compensation.py`, not modified/forked/shadowed | Mainsail macro button | `nebulaos-calibration`, pos 2 | standby only | OK |
| `AXIS_TWIST_Y` | Upstream UI adapter | `AXIS_TWIST_COMPENSATION_CALIBRATE AXIS=Y` | Mainsail macro button | `nebulaos-calibration`, pos 3 | standby only | OK |
| `PID_BED` | Upstream UI adapter | `PID_CALIBRATE HEATER=heater_bed TARGET={65 default}` | Mainsail macro button | `nebulaos-calibration`, pos 4 | standby only | OK |
| `PID_HOTEND` | Upstream UI adapter | `PID_CALIBRATE HEATER=extruder TARGET={230 default}` | Mainsail macro button | `nebulaos-calibration`, pos 5 | standby only | OK |
| `NEBULAOS_NOZZLE_CLEAN` | NebulaOS | Public wrapper → private `_NEBULAOS_NOZZLE_CLEAN`, actually implemented in `z_compensate.py`'s `cmd_nozzle_clear` (not `nebulaos_calibration.py`) — nozzle wipe via `nebulaos_z_offset_probe.touch_probe()` and `nozzle_clear.clear_nozzle()` | Mainsail macro button | `nebulaos-calibration`, pos 6 | standby only | OK |

## 2. Input Shaper group — `nebulaos-input-shaper`

| CANONICAL_NAME | OWNER | DATA_SOURCE | USER_SURFACE | MAINSAIL_GROUP/PANEL | STATE_RESTRICTIONS | STATUS |
|---|---|---|---|---|---|---|
| `NEBULAOS_INPUT_SHAPER_CALIBRATE` | NebulaOS | Public wrapper → private `_NEBULAOS_INPUT_SHAPER_CALIBRATE` — 3-call guided relocate-between-axes workflow, owns explicit `FREQ_END`/`ACCEL_PER_HZ` (from `[nebulaos_calibration]`'s `shaper_freq_end: 80`/`shaper_accel_per_hz: 50`, the hardware-qualified 80Hz/50mm/s²/Hz envelope), drives upstream `SHAPER_CALIBRATE` against the real `adxl345`/`resonance_tester` | Mainsail macro button | `nebulaos-input-shaper` ("Input Shaper"), pos 0 | standby only | OK |
| `NEBULAOS_CALIBRATION_CONTINUE` | NebulaOS | calibration.cfg macro body itself (no backend command) — reads `printer.nebulaos_calibration.input_shaper_state`/`esteps_state` and dispatches `_NEBULAOS_INPUT_SHAPER_CALIBRATE CONTINUE=1` or `_NEBULAOS_ESTEPS_CALIBRATE CONTINUE=1` | Mainsail macro button (single button that works for whichever guided workflow is active) | `nebulaos-input-shaper`, pos 1 | standby only | OK |
| `NEBULAOS_CALIBRATION_CANCEL` | NebulaOS | Public wrapper → private `_NEBULAOS_CALIBRATION_CANCEL` (`cmd_calibration_cancel`) — cancels any in-progress guided calibration at the next stage boundary | Mainsail macro button | `nebulaos-input-shaper`, pos 2 | standby only | OK |
| `SAVE_INPUT_SHAPER` | Upstream-style helper, NebulaOS-vendored (`calibrate_shaper_config.py`, registers `SAVE_INPUT_SHAPER` directly, no gcode_macro wrapper) | Persists `SHAPER_CALIBRATE` results into `[input_shaper]` via `SAVE_CONFIG`-style rewrite | Console/API only, invoked after a manual `SHAPER_CALIBRATE` run — same pattern as upstream `SAVE_CONFIG`/`PROBE_CALIBRATE`'s `ACCEPT` | None (not in any `DEFAULT_GROUPS` entry) | n/a (no macro, so no state gating) | OK — intentionally not a button, same category as `SAVE_CONFIG` itself; not a gap |

## 3. Extruder group — `nebulaos-extruder`

| CANONICAL_NAME | OWNER | DATA_SOURCE | USER_SURFACE | MAINSAIL_GROUP/PANEL | STATE_RESTRICTIONS | STATUS |
|---|---|---|---|---|---|---|
| `NEBULAOS_ESTEPS_CALIBRATE` | NebulaOS | Public wrapper → private `_NEBULAOS_ESTEPS_CALIBRATE` (`cmd_esteps_calibrate`) — guided extruder rotation_distance calibration, `CONTINUE=1` to advance | Mainsail macro button | `nebulaos-extruder` ("Extruder"), pos 0 | standby only | OK |
| `LOAD_FILAMENT` | SimpleAF-derived (filament.cfg, `useful_macros.cfg` lineage) | Heats to `EXTRUDER_TEMP` (default 230), extrudes `EXTRUDE_LEN` (default 90mm) via `_CLIENT_LINEAR_MOVE`, then `SET_STEPPER_ENABLE ... 0` + `BEEP` | Mainsail macro button; guarded (`printer.print_stats.state != "printing"`) | `nebulaos-extruder`, pos 1 | standby only | OK |
| `UNLOAD_FILAMENT` | SimpleAF-derived | Multi-stage retract (extrude tip, initial retract, final retract) for clean filament removal, same printing-guard as LOAD_FILAMENT | Mainsail macro button | `nebulaos-extruder`, pos 2 | standby only | OK |
| `M600` | SimpleAF-derived | `PAUSE RESTORE=0` + delayed_gcode `filament_change` → `_FC_UNLOAD`, then a Mainsail/Fluidd prompt dialog (LOAD/PURGE/RESUME/CANCEL buttons) | Mainsail macro button + standard slicer `M600` gcode + prompt dialog | `nebulaos-extruder`, pos 3 | **standby AND printing** (`show_in_printing=True` — the only calibration/extruder macro visible mid-print, correctly so: this is the filament-change trigger) | OK |
| `PURGE_MORE` | SimpleAF-derived | Calls `LOAD_FILAMENT EXTRUDER_TEMP=... EXTRUDE_LEN=10`, reads saved temp from `RESUME`'s `last_extruder_temp` variable | Mainsail macro button + M600 prompt dialog secondary button | `nebulaos-extruder`, pos 4 | standby AND **pause** (`show_in_pause=True`) — correct, only meaningful mid-filament-change | OK |
| `RESUME_FILAMENT_CHANGE` | SimpleAF-derived | `RESPOND ... action:prompt_end` + `RESUME` | Mainsail macro button + M600 prompt dialog primary button | `nebulaos-extruder`, pos 5 | standby AND pause | OK |
| `CANCEL_FILAMENT_CHANGE` | SimpleAF-derived | `RESPOND ... action:prompt_end` + `CANCEL_PRINT` | Mainsail macro button + M600 prompt dialog footer button | `nebulaos-extruder`, pos 6 | standby AND pause | OK |

## 4. Camera group — `nebulaos-camera`

| CANONICAL_NAME | OWNER | DATA_SOURCE | USER_SURFACE | MAINSAIL_GROUP/PANEL | STATE_RESTRICTIONS | STATUS |
|---|---|---|---|---|---|---|
| `SET_CAMERA_QUALITY_LOW` | NebulaOS (derived from OpenKE `camera-quality.cfg`) | `RUN_SHELL_COMMAND CMD=set_camera_quality PARAMS=LOW` → `/usr/libexec/nebulaos-set-camera-quality` (640x480, uncapped fps) | Mainsail macro button | `nebulaos-camera` ("Camera"), pos 0 | standby only | OK |
| `SET_CAMERA_QUALITY_MED` | NebulaOS | Same shell command, `PARAMS=MED` (1280x720, uncapped fps) | Mainsail macro button | `nebulaos-camera`, pos 1 | standby only | OK |
| `SET_CAMERA_QUALITY_HIGH` | NebulaOS | Same shell command, `PARAMS=HIGH` (1920x1080@30fps, qualified factory default) | Mainsail macro button | `nebulaos-camera`, pos 2 | standby only | OK |

## 5. Maintenance group — `nebulaos-maintenance`

| CANONICAL_NAME | OWNER | DATA_SOURCE | USER_SURFACE | MAINSAIL_GROUP/PANEL | STATE_RESTRICTIONS | STATUS |
|---|---|---|---|---|---|---|
| `BEEP` | GuppyScreen-derived (`guppy_cmd.cfg` lineage) | `M300 S2000 P120` → `guppybeep` shell binary → real hardware PWM buzzer on PC03 | Mainsail macro button | `nebulaos-maintenance` ("Maintenance"), pos 0 | standby only | OK |
| `PLAY_TUNE` | GuppyScreen-derived | `SONG=<name>` (from `songs.conf`) or inline `RTTTL=<string>` → `guppybeep` | Mainsail macro button | `nebulaos-maintenance`, pos 1 | standby only | OK |
| `M300` | GuppyScreen-derived | Standard slicer/gcode beep command (`S`=frequency Hz, `P`=duration ms), same `guppybeep` backend as `BEEP` | Console/slicer gcode only | **None** (not in any `DEFAULT_GROUPS` entry) | n/a | OK — correctly excluded: `M300` is the raw slicer-compatible primitive, `BEEP` is its one-click Mainsail-friendly wrapper; both existing is not a duplicate, it's primitive-vs-convenience, same relationship as `PID_CALIBRATE`/`PID_BED` |

## 6. Recovery group — `nebulaos-recovery`

| CANONICAL_NAME | OWNER | DATA_SOURCE | USER_SURFACE | MAINSAIL_GROUP/PANEL | STATE_RESTRICTIONS | STATUS |
|---|---|---|---|---|---|---|
| `NEBULAOS_RESUME_POWER_LOSS` | NebulaOS | Public wrapper (calibration.cfg) → `NEBULAOS_PLR_RESUME` (`nebulaos_power_loss_recovery.py`, `cmd_NEBULAOS_PLR_RESUME`) | Mainsail macro button | `nebulaos-recovery` ("Recovery"), pos 0 | standby only | OK |
| `NEBULAOS_CLEAR_POWER_LOSS_RECOVERY` | NebulaOS | Public wrapper → `NEBULAOS_PLR_DISCARD` (`cmd_NEBULAOS_PLR_DISCARD`) | Mainsail macro button | `nebulaos-recovery`, pos 1 | standby only | OK |
| `NEBULAOS_PLR_STATUS` | NebulaOS | Raw registered command (`nebulaos_power_loss_recovery.py`, `cmd_NEBULAOS_PLR_STATUS`) — no `[gcode_macro]` wrapper exists for it in calibration.cfg or anywhere else | Console/API only (`printer.objects.query?nebulaos_power_loss_recovery` covers the same ground via `get_status()`) | **None** — cannot appear in any Mainsail macro group because there is no macro to place | n/a | OK — a read-only status query naturally has no need for a clickable button; the same information is already the `nebulaos_power_loss_recovery` status object surfaced via the API |

## 7. Print-workflow macros (slicer-invoked / native-toolbar-wired, not manual buttons)

| CANONICAL_NAME | OWNER | DATA_SOURCE | USER_SURFACE | MAINSAIL_GROUP/PANEL | STATE_RESTRICTIONS | STATUS |
|---|---|---|---|---|---|---|
| `START_PRINT` | SimpleAF-derived (`start_end.cfg` lineage) | Bed-warp stabilisation wait, adaptive bed-mesh dispatch (`_START_PRINT_BED_MESH`), `_SMART_PARK`, `_LINE_PURGE` (KAMP-derived) | Slicer "start gcode" (not a manual button) | Not in any `DEFAULT_GROUPS` entry | n/a | OK — correctly excluded; a print is already running by the time this could be clicked |
| `END_PRINT` | SimpleAF-derived | Cooldown routine, park, `_RESTORE_VELOCITY_ACCEL`, `BED_MESH_CLEAR` | Slicer "end gcode" | Not in any group | n/a | OK |
| `PAUSE` | SimpleAF-derived (`rename_existing: PAUSE_BASE`) | Saves extruder temp/idle_timeout, calls `_TOOLHEAD_PARK_PAUSE` | Mainsail's **native** pause toolbar button (built-in Klipper macro-override convention — Mainsail doesn't need this in a macro group to find it) | Not in any group (by design — native surface, not a group-listed macro) | n/a | OK |
| `RESUME` | SimpleAF-derived (`rename_existing: RESUME_BASE`) | Restores extruder temp/idle_timeout, filament-sensor/can-extrude gating, `_CLIENT_EXTRUDE` | Mainsail's native resume toolbar button | Not in any group | n/a | OK |
| `CANCEL_PRINT` | SimpleAF-derived (`rename_existing: CANCEL_PRINT_BASE`) | Restores idle_timeout, parks, retracts, `TURN_OFF_HEATERS`, `BED_MESH_CLEAR` | Mainsail's native cancel toolbar button | Not in any group | n/a | OK |

## 8. Raw registered commands with NO `[gcode_macro]` wrapper at all

These are real, callable Klipper commands (`self.gcode.register_command(...)`
in a Python extra) that have **no** `[gcode_macro]` section anywhere in the
composed config. Mainsail's macro panel lists `gcode_macro` objects, so none
of these can ever appear as a clickable button or be placed in any
`DEFAULT_GROUPS` entry, regardless of the seed script — the only way to
reach them is the console or a direct API/gcode call.

| CANONICAL_NAME | OWNER | DATA_SOURCE | USER_SURFACE | MAINSAIL_GROUP/PANEL | STATE_RESTRICTIONS | STATUS |
|---|---|---|---|---|---|---|
| `Z_OFFSET_CALIBRATION` | NebulaOS (`z_compensate.py`, `cmd_z_offset_calibration`) | Per-print, live Z gcode-offset correction: touch-probes at the BLTouch-homed point via `nebulaos_z_offset_probe.touch_probe()`, applies the delta as a live `SET_GCODE_OFFSET`-equivalent for the current print only (not a permanent `z_offset` rewrite) | **NebulaOS-guppyscreen's `recalibration_wizard_panel.cpp`**, confirmed by reading that repo's source directly (`ws.gcode_script("Z_OFFSET_CALIBRATION", ...)`) — not the composed config, which is why the earlier RC2 pass mischaracterized this as unreferenced; GuppyScreen calls it over the Moonraker websocket, bypassing the printer.cfg macro layer entirely | None (not a macro; deliberately console-visible for GuppyScreen's own diagnostics, not end-user discovery) | n/a | **PUBLIC_REQUIRED** — see §"Z_OFFSET_CALIBRATION resolution" below |
| `NEBULAOS_CALIBRATION_STATUS` | NebulaOS (`nebulaos_calibration.py`, `cmd_calibration_status`) | Reports the coordinator's Z-offset/auto-calibrate/e-steps/input-shaper state | Console/API only; same data is also the `nebulaos_calibration` status object (`printer.objects.query`/`subscribe`) | None (not a macro) | n/a | OK — a status query, not an action; no user-facing need for a button when the same data is already a subscribable object |
| `NEBULAOS_LOAD_CELL_READ` | NebulaOS (`nebulaos_load_cell_calibration.py`) | Read-only: the force on the front-left corner in grams from the current calibration | Console/API only | None | n/a | OK (measurement aid, G86) |
| `NEBULAOS_RAW_CONTACT_DIAGNOSTIC` | NebulaOS (`nebulaos_z_offset_probe.py`) | No-motion raw ADC health window (rate, noise, drift) | Console/API only | None | n/a | OK (diagnostic, G83b) |
| `NEBULAOS_RAW_CONTACT_REFERENCE` | NebulaOS (`nebulaos_z_offset_probe.py`) | No motion: captures the unloaded raw reference into the SAVE_CONFIG autosave block (applies after `SAVE_CONFIG`); refused on an unhealthy sensor | Console/API only | None | n/a | OK (G83b-auto, locked: no qualified profile) |
| `NEBULAOS_RAW_CONTACT_COMPARE` | NebulaOS (`nebulaos_calibration.py`) | Supervised (`SUPERVISED=1` required) comparison of calibrated vs raw-count contact at the Z-offset point; moves the printer, saves nothing | Console only, operator at the printer | None | standby only | OK (qualification tool, G83b-auto) |
| `NEBULAOS_PLR_STATUS` | NebulaOS (`nebulaos_power_loss_recovery.py`) | See §6 above | Console/API only | None | n/a | OK (status query, same reasoning) |
| `LOAD_CELL_READ` / `LOAD_CELL_TARE` / `LOAD_CELL_CALIBRATE` / `LOAD_CELL_DIAGNOSTIC` | Upstream Klipper (`load_cell.py`'s `LoadCell` wrapper, instantiated by `[nebulaos_z_offset_probe]`) | Zero-motion HX711 sensor qualification/calibration (sets `counts_per_gram`/`reference_tare_counts` via `SAVE_CONFIG`) | Console/API only, by design (per the mission's own instruction: the load cell needs a correct config object + a working calibration path, not a permanent Mainsail graph) | None | n/a | OK |
| `_GUPPY_LOAD_MODULE` / `_GUPPY_UNLOAD_MODULE` | NebulaOS (`guppy_module_loader.py`) | Runtime enable/disable of printer objects (used to lazily load `[tmcstatus]` for GuppyScreen's own TMC panel) | GuppyScreen-internal only | None | n/a | INTERNAL_ONLY (leading underscore = private by this project's own convention) |
| `_GUPPY_SAVE_CONFIG` / `_GUPPY_DELETE_CONFIG` | NebulaOS (`guppy_config_helper.py`) | GuppyScreen config-section save/delete helper | GuppyScreen-internal only | None | n/a | INTERNAL_ONLY |
| `RUN_SHELL_COMMAND` | Upstream-style helper, NebulaOS-vendored (`gcode_shell_command.py`) | Generic `CMD=<name>` dispatcher backing `SET_CAMERA_QUALITY_*`, `BEEP`, `PLAY_TUNE` | Called only from inside other macros, never directly by a user | None | n/a | INTERNAL_ONLY |

## 9. Confirmed removed / never shipped (no dangling reference found anywhere)

Cross-checked against `docs/NEBULAOS_CALIBRATION_PUBLIC_API.md` (an older,
now partially-stale document that itself flags "needs a full refresh") and
against a full grep of the composed config and extras tree:

- `NEBULAOS_PID_CALIBRATE_BED` / `NEBULAOS_PID_CALIBRATE_HOTEND` — removed
  2026-09-04 in favor of `PID_BED`/`PID_HOTEND` (SimpleAF-vendored, no
  printing-guard duplication). No trace found in the composed config or
  extras — confirmed genuinely gone, not merely unwired.
- `NEBULAOS_BED_MESH_CALIBRATE` — removed; upstream `BED_MESH_CALIBRATE
  PROFILE=<name>` alone is the exact equivalent (confirmed against pinned
  `bed_mesh.py`). No `[gcode_macro NEBULAOS_BED_MESH_CALIBRATE]` exists.
- `NEBULAOS_AXIS_TWIST_CALIBRATE` — final product decision to NOT support
  automatic (load-cell) Axis Twist calibration on this hardware at all
  (documented at length in `nebulaos_calibration.py`'s own header, citing the
  real safety incident in
  `_evidence/overnight-hx711-investigation-20260831-233518/`). Manual
  `AXIS_TWIST_X`/`AXIS_TWIST_Y` (upstream passthrough) remain the only
  supported path. Confirmed absent from every `.py`/`.cfg` file read.
- `CRTENSE_NOZZLE_CLEAR` — removed in the Phase 2 RC per its own commit
  (`7f62767`); `NEBULAOS_NOZZLE_CLEAN` is now the sole canonical name.
  Confirmed absent from the composed config.

## 10. Cross-reference to the sensor inventory (not duplicated here)

For full get_status()-level detail, physical wiring, and Mainsail native
panels, see `NEBULAOS_MAINSAIL_SENSOR_INVENTORY.md`:

- **MCUs**: `mcu` (real GD32F303), `mcu rpi` (host-side virtual MCU serving
  `adxl345`) — both real, both correctly listed in Mainsail's Machine panel.
- **Probes**: `bltouch` (global Z probe, native Mainsail Z-Calibrate panel),
  `nebulaos_z_offset_probe` (HX711 nozzle load cell, console/API only by
  design, backs `NEBULAOS_Z_OFFSET_CALIBRATE` and `Z_OFFSET_CALIBRATION`
  above).
- **Heaters**: `extruder`, `heater_bed` — native Mainsail temperature
  graphs/controls, backing `PID_HOTEND`/`PID_BED` above.
- **Fans**: `fan` (part cooling), `heater_fan nozzle_fan` — native Mainsail
  fan panel.
- **Accelerometer**: `adxl345` — real hardware on `mcu rpi`, console/API
  only (`ACCELEROMETER_QUERY`/`TEST_RESONANCES`), backing
  `NEBULAOS_INPUT_SHAPER_CALIBRATE` above; no live graph, by design.

---

## Z_OFFSET_CALIBRATION resolution (final pre-hardware closure, 2026-09-06)

RC2's audit flagged `Z_OFFSET_CALIBRATION` as an apparent orphan: no
`[gcode_macro]` wrapper, no caller anywhere in this project's own composed
config, and a name one word away from the canonical
`NEBULAOS_Z_OFFSET_CALIBRATE` — a real risk of operator confusion for
anyone reading raw command names off a console history. That analysis
missed one thing: **the "no composed-config caller" heuristic cannot see a
caller living in a sibling repository's compiled UI binary.** Reading
`NebulaOS-guppyscreen/src/recalibration_wizard_panel.cpp` directly (not
inferred) shows a real, active call —
`ws.gcode_script("Z_OFFSET_CALIBRATION", ...)` — made over the Moonraker
websocket every time a user runs GuppyScreen's own recalibration wizard.

**Classification: `PUBLIC_REQUIRED`.** This is not a stale alias, a dead
surface, or a duplicate of `NEBULAOS_Z_OFFSET_CALIBRATE` — it is a
different implementation (a single raw load-cell touch reading, vs.
`NEBULAOS_Z_OFFSET_CALIBRATE`'s guided, `nebulaos_probe_pair.py`-mediated
BLTouch/HX711 reconciliation) serving a different, currently-shipped
consumer. Per this mission's own architecture rule ("GuppyScreen adapts to
the final NebulaOS API; NebulaOS core does not preserve legacy backend
architecture merely to satisfy the current GuppyScreen binary" — but also
"binary remains shipped" and functional testing is *deferred*, not
*removed*), renaming or removing this command now would silently break a
real, currently-shipped GuppyScreen feature with no compensating benefit,
since GuppyScreen's own binary is pinned and cannot pick up a renamed
command without its own rebuild — out of scope for a core-only closure
mission.

**Resolution applied**: no removal, no rename. `z_compensate.py`'s
registration site now carries an explicit comment naming the real caller,
so a future audit never re-flags this as an orphan; the command's own
`desc=` help text was rewritten to name both its real purpose (the
GuppyScreen wizard primitive) and the canonical alternative
(`NEBULAOS_Z_OFFSET_CALIBRATE`) a console user actually wants, resolving
the operator-confusion risk without touching either command's behavior.
Three new tests (`extras/test_z_compensate_reentrancy_guard.py`'s
`PublicAPISurfaceTest`, in the extensions repo) prove the two commands are
genuinely independent implementations, registered separately, never
aliasing one another.

## STATUS bucket totals (this deliverable)

| STATUS | Count | Notes |
|---|---|---|
| OK | 30 | All group-seeded macros (22), `SAVE_INPUT_SHAPER`, `M300`, `START_PRINT`/`END_PRINT`/`PAUSE`/`RESUME`/`CANCEL_PRINT` (5), `NEBULAOS_CALIBRATION_STATUS`, `NEBULAOS_PLR_STATUS`, `LOAD_CELL_*` (1 group) |
| INTERNAL_ONLY | 3 | `_GUPPY_LOAD_MODULE`/`_GUPPY_UNLOAD_MODULE` (1 group), `_GUPPY_SAVE_CONFIG`/`_GUPPY_DELETE_CONFIG` (1 group), `RUN_SHELL_COMMAND` |
| PUBLIC_REQUIRED (console-only, GuppyScreen-facing) | 1 | `Z_OFFSET_CALIBRATION` — see "Z_OFFSET_CALIBRATION resolution" above |
| STALE | 0 | the one stale item this project shipped, `load_cell_probe.cfg`, was removed from the production overlay entirely tonight (see `historical-reconciliation.md` §7) — no longer present to classify |
| DUPLICATE | 0 | `M300`/`BEEP` and `SAVE_INPUT_SHAPER` were checked closely and are primitive-vs-convenience pairs, not duplicates |
| BROKEN | 0 | none found |

22 macros are seeded into the six `DEFAULT_GROUPS` panels; 5 more are
native-toolbar/slicer-wired by design; 6 are raw commands with no macro
wrapper (5 of those are plain console/API-only status/primitive commands;
1, `Z_OFFSET_CALIBRATION`, is deliberately console-visible because its real
consumer — GuppyScreen — is another compiled binary, not a Mainsail macro).

## Mission classification mapping (PUBLIC_PRODUCT_API / UPSTREAM_NATIVE / PRIVATE_INTERNAL)

| This doc's STATUS | Mission classification |
|---|---|
| OK, entries with `NebulaOS` as OWNER | `PUBLIC_PRODUCT_API` |
| OK, entries with an "Upstream ..." OWNER (e.g. `AXIS_TWIST_X`, `PID_BED`) | `UPSTREAM_NATIVE` |
| INTERNAL_ONLY | `PRIVATE_INTERNAL` |
| `Z_OFFSET_CALIBRATION` (PUBLIC_REQUIRED) | `PUBLIC_PRODUCT_API` — real, currently-consumed API, its consumer is GuppyScreen rather than Mainsail |

```
PUBLIC_API_AMBIGUITIES = 0
Z_OFFSET_CALIBRATION_CLASSIFICATION = PUBLIC_REQUIRED
Z_OFFSET_CALIBRATION_PUBLIC_AMBIGUITY_RESOLVED = YES
```
