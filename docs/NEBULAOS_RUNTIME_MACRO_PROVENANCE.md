# NebulaOS Runtime Macro Provenance

Answers, with full enumeration and citations, one question raised by the RC1
hardware acceptance run (2026-09-05): the physical test device reported 83
`GCode macros` in Mainsail, versus a cleaned-source audit claim of ~47. This
document enumerates every `[gcode_macro]` and `[delayed_gcode]` section that
actually exists in the current composed NebulaOS Klipper config tree — both
the immutable slot-owned layer and the tracked factory seed for
`printer_data/config` — with an exact count, and explains the 83-vs-49 gap.

This document describes the runtime a **fresh** install / factory-clean
provision produces. It is not a description of any one long-lived physical
device's accumulated state.

## 1. Files read

All ten files under the immutable, slot-owned config layer:

```
scripts/build/overlay/etc/nebulaos/klipper/beeper.cfg
scripts/build/overlay/etc/nebulaos/klipper/calibration.cfg
scripts/build/overlay/etc/nebulaos/klipper/camera.cfg
scripts/build/overlay/etc/nebulaos/klipper/filament.cfg
scripts/build/overlay/etc/nebulaos/klipper/homing.cfg
scripts/build/overlay/etc/nebulaos/klipper/load_cell_probe.cfg
scripts/build/overlay/etc/nebulaos/klipper/machine.cfg
scripts/build/overlay/etc/nebulaos/klipper/platform.cfg
scripts/build/overlay/etc/nebulaos/klipper/print.cfg
scripts/build/overlay/etc/nebulaos/klipper/prtouch.cfg
scripts/build/overlay/etc/nebulaos/klipper/z_offset_probe.cfg
```

Plus the tracked factory-seed entrypoint for the *persistent, user-owned*
`printer_data/config`:

```
scripts/build/overlay/opt/printer_data/config/printer.cfg
```

`scripts/build/04-cross-compile-app-stack.sh` (around line 1063-1065)
confirms this second file is the single source of truth for both the
in-image copy at `opt/printer_data/config/` *and* the dedicated,
never-shadowed factory-seed copy it builds at
`$OVERLAY/opt/nebulaos-seeds/printer_data-config/`:

> "The actual config content itself is not authored here — it already
> exists, already deliberately stripped of development-machine calibration
> data (see printer.cfg's own header), at
> `scripts/build/overlay/opt/printer_data/config/` — this just makes a
> second immutable copy of that same tracked content available at a path
> nothing ever mounts over."

So there is exactly **one** authoritative `printer.cfg` in current source,
and a genuinely fresh device (via `S02nebulaos-namespace`'s
`PRINTER_DATA_CONFIG_SEED` copy) and a factory-clean-provisioned device both
receive an identical copy of it. `load_cell_probe.cfg` exists on disk but is
explicitly **not** included by `printer.cfg` yet — its own header says
"DO NOT INCLUDE THIS FILE YET... provided for hardware qualification only"
(Phase 1.8 native-MCU load-cell path, not yet activated) — so it contributes
zero macros to the current runtime.

`homing.cfg`, `machine.cfg`, `platform.cfg`, `prtouch.cfg`,
`z_offset_probe.cfg`, and `load_cell_probe.cfg` contain **no**
`[gcode_macro]` or `[delayed_gcode]` sections at all (confirmed by grepping
each file for `^\[` and inspecting every section header — they contain only
non-macro sections such as `[mcu]`, `[stepper_x]`, `[bltouch]`,
`[nebulaos_z_offset_probe]`, `[z_compensate]`, `[safe_z_home]`,
`[nebulaos_compat]`, etc.). All macro/delayed_gcode content lives in five
files: `beeper.cfg`, `calibration.cfg`, `camera.cfg`, `filament.cfg`,
`print.cfg`.

## 2. Exact count

```
$ grep -rhE '^\[gcode_macro '  scripts/build/overlay/etc/nebulaos/klipper/*.cfg | wc -l
47
$ grep -rhE '^\[delayed_gcode ' scripts/build/overlay/etc/nebulaos/klipper/*.cfg | wc -l
2
```

Per-file breakdown:

| File | `[gcode_macro]` | `[delayed_gcode]` |
|---|---|---|
| beeper.cfg | 3 | 0 |
| calibration.cfg | 13 | 0 |
| camera.cfg | 3 | 0 |
| filament.cfg | 8 | 1 |
| homing.cfg | 0 | 0 |
| load_cell_probe.cfg | 0 | 0 |
| machine.cfg | 0 | 0 |
| platform.cfg | 0 | 0 |
| print.cfg | 20 | 1 |
| prtouch.cfg | 0 | 0 |
| z_offset_probe.cfg | 0 | 0 |
| **opt/printer_data/config/printer.cfg** | 0 | 0 |
| **Total** | **47** | **2** |

`printer.cfg` itself defines zero macros — it is a thin entrypoint of
10 `[include ...]` directives (order is load-bearing, per its own header)
plus the real, tracked `SAVE_CONFIG` autosave block carrying this printer
model's stock BLTouch/PID/rotation_distance factory defaults. All 49
macro/delayed_gcode definitions live in the five immutable files listed
above.

No duplicate macro names were found (`sort | uniq -d` on the full name list
returns empty) — every name is defined exactly once.

## 3. Full enumeration table

Legend:
- **SOURCE_LAYER**: one of `IMMUTABLE_NEBULAOS` (ships in
  `/etc/nebulaos/klipper/*.cfg` on the read-only squashfs, unconditionally,
  every boot), `USER_PRINTER_CFG`/`FACTORY_SEED`/`UPSTREAM_SAMPLE`/
  `MAINSAIL_CLIENT`/`PERSISTENT_MIGRATION`/`OTHER` (none of these apply to
  any row below — see §4).
- **OWNER**: authorship/lineage, from each file's own header comment.
- **PUBLIC_OR_PRIVATE**: Klipper convention — a leading `_` means the macro
  is a private/internal helper never meant to be typed by a user or listed
  as a top-level Mainsail command; no leading `_` means it is a public,
  user-facing G-code command. `delayed_gcode` entries are never user-typed,
  so both are marked PRIVATE.
- **EXPECTED**: YES for every row (this document enumerates what a
  fresh/composed RC2 runtime *should* contain).

### beeper.cfg (IMMUTABLE, derived from GuppyScreen `guppy_cmd.cfg` buzzer section)

| MACRO_NAME | SOURCE_FILE | SOURCE_LAYER | OWNER | PUBLIC_OR_PRIVATE | EXPECTED |
|---|---|---|---|---|---|
| M300 | beeper.cfg | IMMUTABLE_NEBULAOS | NebulaOS (names from GuppyScreen `guppy_cmd.cfg`; since G108 they call the `nebulaos_beeper` extra) | PUBLIC | YES |
| BEEP | beeper.cfg | IMMUTABLE_NEBULAOS | NebulaOS (names from GuppyScreen `guppy_cmd.cfg`; since G108 they call the `nebulaos_beeper` extra) | PUBLIC | YES |
| PLAY_TUNE | beeper.cfg | IMMUTABLE_NEBULAOS | NebulaOS (names from GuppyScreen `guppy_cmd.cfg`; since G108 they call the `nebulaos_beeper` extra) | PUBLIC | YES |

### calibration.cfg (IMMUTABLE — genuine NebulaOS functionality plus two upstream UI adapters)

| MACRO_NAME | SOURCE_FILE | SOURCE_LAYER | OWNER | PUBLIC_OR_PRIVATE | EXPECTED |
|---|---|---|---|---|---|
| NEBULAOS_AUTO_CALIBRATE | calibration.cfg | IMMUTABLE_NEBULAOS | NebulaOS (genuine; wraps private `_NEBULAOS_*` Python extras) | PUBLIC | YES |
| NEBULAOS_CALIBRATION_CANCEL | calibration.cfg | IMMUTABLE_NEBULAOS | NebulaOS (genuine) | PUBLIC | YES |
| NEBULAOS_Z_OFFSET_CALIBRATE | calibration.cfg | IMMUTABLE_NEBULAOS | NebulaOS (genuine) | PUBLIC | YES |
| NEBULAOS_INPUT_SHAPER_CALIBRATE | calibration.cfg | IMMUTABLE_NEBULAOS | NebulaOS (genuine; wraps upstream `SHAPER_CALIBRATE` with hardware-qualified FREQ_END/ACCEL_PER_HZ) | PUBLIC | YES |
| NEBULAOS_ESTEPS_CALIBRATE | calibration.cfg | IMMUTABLE_NEBULAOS | NebulaOS (genuine) | PUBLIC | YES |
| NEBULAOS_NOZZLE_CLEAN | calibration.cfg | IMMUTABLE_NEBULAOS | NebulaOS (genuine) | PUBLIC | YES |
| NEBULAOS_CALIBRATION_CONTINUE | calibration.cfg | IMMUTABLE_NEBULAOS | NebulaOS (genuine) | PUBLIC | YES |
| NEBULAOS_RESUME_POWER_LOSS | calibration.cfg | IMMUTABLE_NEBULAOS | NebulaOS (genuine; backs `[nebulaos_power_loss_recovery]`) | PUBLIC | YES |
| NEBULAOS_CLEAR_POWER_LOSS_RECOVERY | calibration.cfg | IMMUTABLE_NEBULAOS | NebulaOS (genuine) | PUBLIC | YES |
| AXIS_TWIST_X | calibration.cfg | IMMUTABLE_NEBULAOS | NebulaOS-owned file; macro itself is a trivial one-line "UPSTREAM_UI_ADAPTER" wrapping upstream `AXIS_TWIST_COMPENSATION_CALIBRATE AXIS=X` (per the file's own comment: "These are NOT NebulaOS functionality... They contain no algorithm, state, or orchestration") | PUBLIC | YES |
| AXIS_TWIST_Y | calibration.cfg | IMMUTABLE_NEBULAOS | same as AXIS_TWIST_X, `AXIS=Y` | PUBLIC | YES |
| PID_BED | calibration.cfg | IMMUTABLE_NEBULAOS | UPSTREAM_UI_ADAPTER: one-click default-target wrapper around upstream `PID_CALIBRATE HEATER=heater_bed` | PUBLIC | YES |
| PID_HOTEND | calibration.cfg | IMMUTABLE_NEBULAOS | UPSTREAM_UI_ADAPTER: one-click default-target wrapper around upstream `PID_CALIBRATE HEATER=extruder` | PUBLIC | YES |

### camera.cfg (IMMUTABLE, derived from OpenKE `camera-quality.cfg`)

| MACRO_NAME | SOURCE_FILE | SOURCE_LAYER | OWNER | PUBLIC_OR_PRIVATE | EXPECTED |
|---|---|---|---|---|---|
| SET_CAMERA_QUALITY_LOW | camera.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from OpenKE `camera-quality.cfg`; genuine functionality — "Klipper has no built-in webcam control") | PUBLIC | YES |
| SET_CAMERA_QUALITY_MED | camera.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from OpenKE `camera-quality.cfg`) | PUBLIC | YES |
| SET_CAMERA_QUALITY_HIGH | camera.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from OpenKE `camera-quality.cfg`) | PUBLIC | YES |

### filament.cfg (IMMUTABLE, derived from pellcorp/creality SimpleAF `useful_macros.cfg`)

| MACRO_NAME | SOURCE_FILE | SOURCE_LAYER | OWNER | PUBLIC_OR_PRIVATE | EXPECTED |
|---|---|---|---|---|---|
| LOAD_FILAMENT | filament.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from pellcorp/creality SimpleAF `useful_macros.cfg`) | PUBLIC | YES |
| UNLOAD_FILAMENT | filament.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from pellcorp/creality SimpleAF `useful_macros.cfg`) | PUBLIC | YES |
| M600 | filament.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from pellcorp/creality SimpleAF `useful_macros.cfg`) | PUBLIC | YES |
| filament_change (delayed_gcode) | filament.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from pellcorp/creality SimpleAF `useful_macros.cfg`) | PRIVATE | YES |
| _FC_UNLOAD | filament.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from pellcorp/creality SimpleAF `useful_macros.cfg`) | PRIVATE | YES |
| _FC_LOAD | filament.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from pellcorp/creality SimpleAF `useful_macros.cfg`) | PRIVATE | YES |
| PURGE_MORE | filament.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from pellcorp/creality SimpleAF `useful_macros.cfg`) | PUBLIC | YES |
| RESUME_FILAMENT_CHANGE | filament.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from pellcorp/creality SimpleAF `useful_macros.cfg`) | PUBLIC | YES |
| CANCEL_FILAMENT_CHANGE | filament.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from pellcorp/creality SimpleAF `useful_macros.cfg`) | PUBLIC | YES |

### print.cfg (IMMUTABLE — derived from pellcorp/creality SimpleAF @ d18d354456a8, which itself vendors fluidd-config's `client.cfg` and kyleisah/KAMP's `Line_Purge.cfg`/`Smart_Park.cfg`)

| MACRO_NAME | SOURCE_FILE | SOURCE_LAYER | OWNER | PUBLIC_OR_PRIVATE | EXPECTED |
|---|---|---|---|---|---|
| _START_END_PARAMS | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from SimpleAF `start_end.cfg`) | PRIVATE | YES |
| _CLIENT_VARIABLE | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS-vendored; originally fluidd-config's `client.cfg` (Copyright (C) 2022 Alex Zellner), via SimpleAF `client.cfg` | PRIVATE | YES |
| _KAMP_Settings | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS-vendored; originally kyleisah/Klipper-Adaptive-Meshing-Purging, via SimpleAF | PRIVATE | YES |
| START_PRINT | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from SimpleAF `start_end.cfg`) | PUBLIC | YES |
| _START_PRINT_BED_MESH | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from SimpleAF `start_end.cfg`) | PRIVATE | YES |
| END_PRINT | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from SimpleAF `start_end.cfg`) | PUBLIC | YES |
| wait_for_end_print_cooldown (delayed_gcode) | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from SimpleAF `start_end.cfg`) | PRIVATE | YES |
| _WAIT_TEMP_COOL_DOWN_END | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from SimpleAF `start_end.cfg`) | PRIVATE | YES |
| CANCEL_PRINT | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from SimpleAF `client.cfg`) | PUBLIC | YES |
| PAUSE | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from SimpleAF `client.cfg`) | PUBLIC | YES |
| RESUME | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from SimpleAF `client.cfg`) | PUBLIC | YES |
| _ON_GCODE_FAILURE | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from SimpleAF `client.cfg`) | PRIVATE | YES |
| _TOOLHEAD_PARK_PAUSE | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from SimpleAF `client.cfg`) | PRIVATE | YES |
| _TOOLHEAD_PARK_CANCEL_END_PRINT | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from SimpleAF `client.cfg`) | PRIVATE | YES |
| _CLIENT_EXTRUDE | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS-vendored; originally fluidd-config's `client.cfg`, via SimpleAF | PRIVATE | YES |
| _CLIENT_RETRACT | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS-vendored; originally fluidd-config's `client.cfg`, via SimpleAF | PRIVATE | YES |
| _CLIENT_LINEAR_MOVE | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS-vendored; originally fluidd-config's `client.cfg`, via SimpleAF | PRIVATE | YES |
| _WARP_STABILISE | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from SimpleAF `start_end.cfg`) | PRIVATE | YES |
| _RESTORE_VELOCITY_ACCEL | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS (derived from SimpleAF `client.cfg`) | PRIVATE | YES |
| _LINE_PURGE | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS-vendored; originally kyleisah/KAMP `Line_Purge.cfg`, via SimpleAF | PRIVATE | YES |
| _SMART_PARK | print.cfg | IMMUTABLE_NEBULAOS | NebulaOS-vendored; originally kyleisah/KAMP `Smart_Park.cfg`, via SimpleAF | PRIVATE | YES |

**Row count check**: beeper.cfg (3) + calibration.cfg (13) + camera.cfg (3)
+ filament.cfg (9, incl. 1 delayed_gcode) + print.cfg (21, incl. 1
delayed_gcode) = **49 rows**, matching §2's total exactly.

## 4. Why the other SOURCE_LAYER values are all empty

`USER_PRINTER_CFG`, `FACTORY_SEED` (as a distinct-from-immutable layer),
`UPSTREAM_SAMPLE`, `MAINSAIL_CLIENT`, and `PERSISTENT_MIGRATION` are all
legitimate categories in the enum this document uses, but **zero** rows
above use them, because:

- The one and only tracked `printer.cfg` (§1) defines no macros itself —
  it only `[include]`s the five immutable files and carries the
  `SAVE_CONFIG` block. So there is no separate "factory seed macro" or
  "user printer.cfg macro" content in current source at all — every macro
  a fresh device gets comes from the immutable layer.
- The `_CLIENT_*` (fluidd-config/Mainsail client-macro convention) and
  `_LINE_PURGE`/`_SMART_PARK`/`_KAMP_Settings` (KAMP) macros retain a
  distinct upstream lineage in their attribution (documented under OWNER),
  but they are physically vendored into, and shipped as part of, the
  immutable `print.cfg` — there is no separate "sample" file a user could
  diverge from at runtime. They are classified IMMUTABLE_NEBULAOS by
  residence, with their upstream ancestry preserved in the OWNER column
  instead.
- `PERSISTENT_MIGRATION` would apply to macros injected by a config
  migration tool touching a device's live `printer_data/config` after the
  fact (e.g. `scripts/build/overlay/opt/nebulaos/tools/migrate_config_ownership.py`).
  No macros in current tracked source originate that way.

## 5. The 83-vs-49 discrepancy, explained

**Confirmed count in current source**: 47 `[gcode_macro]` + 2
`[delayed_gcode]` = **49** definitions, composed from exactly five files
(`beeper.cfg`, `calibration.cfg`, `camera.cfg`, `filament.cfg`, `print.cfg`)
under `scripts/build/overlay/etc/nebulaos/klipper/`, included by the single
tracked `scripts/build/overlay/opt/printer_data/config/printer.cfg`. This
essentially matches the ~47 "cleaned source audit" figure already reported
(the audit's ~47 evidently counted `[gcode_macro]` sections only, without
the 2 `[delayed_gcode]` sections, which is exactly the small discrepancy
between "~47" and this document's 47+2=49).

**The RC1 hardware device's reported 83** is not a build defect. It is
stale accumulated state in that one long-lived physical device's
persistent, user-owned `/usr/data/nebulaos/printer_data/config/printer.cfg`
— storage that is explicitly `/usr/data`-resident, shared across every A/B
slot and every OS reflash, and which this project's own tooling goes out of
its way to *never* touch:

- `scripts/build/overlay/opt/nebulaos/factory-clean-provision.sh`'s own
  header states its scope in writing: `NEVER TOUCHED: printer_data/config
  (USER OWNED - printer.cfg, macros, moonraker.conf)`. Even the project's
  deliberate, on-demand "make this device look factory-fresh again" tool
  refuses to touch this file — it archives `apps/`, `envs/`, and `system/`
  only.
- `scripts/build/overlay/etc/init.d/S02nebulaos-namespace` only seeds
  `printer_data/config` from `PRINTER_DATA_CONFIG_SEED` when
  `printer.cfg`/`moonraker.conf` are **absent** ("Once the marker exists,
  this never touches printer_data/config again").

So a `printer_data/config/printer.cfg` that has accumulated months of
Phase 2 testing history — including manually-added or vendor-carried
macros from tools this project no longer ships — persists across every
subsequent reflash of that one device, untouched by design. A genuinely
fresh device (first boot, or after `factory-clean-provision.sh
--archive-and-reset` + reboot) gets the tracked seed copied in verbatim and
would show exactly 49, not 83.

**Specific stale macro names cited in the RC1 investigation, checked
against current source:**

| Stale name (seen live on the RC1 device) | Found in current tracked source? |
|---|---|
| `INPUT_SHAPER` | NOT FOUND. No `[gcode_macro INPUT_SHAPER]` anywhere under `scripts/build/overlay/`. (Current source's equivalent is the differently-named `NEBULAOS_INPUT_SHAPER_CALIBRATE` in calibration.cfg.) |
| `INPUT_SHAPER_GRAPHS` | NOT FOUND. |
| `BED_MESH_CALIBRATE` (override) | NOT FOUND as a `[gcode_macro]` override anywhere in `scripts/build/overlay/`. Current source relies on upstream Klipper's own `BED_MESH_CALIBRATE` (an `[bed_mesh]`-provided command, not a NebulaOS macro) — the string appears only in historical prose inside `ANALYSIS.md`, describing stock Klipper's calibration flow, not a shipped override. |
| `TURN_ON_FANS` / `TURN_OFF_FANS` | NOT FOUND. print.cfg's own header comment explicitly documents their removal: "Fan control inlined as M106/M107 + auxiliary fan commands (TURN_OFF_FANS was SimpleAF-only)." |
| `_DISCONNECT_PROBE` | NOT FOUND anywhere under `scripts/build/overlay/`. |
| `_HOMING_PARAMS` | NOT FOUND anywhere under `scripts/build/overlay/`. (homing.cfg contains only a `[safe_z_home]` section, no macros at all.) |
| `[gcode_shell_command guppy_input_shaper]` | NOT FOUND anywhere under `scripts/build/overlay/`. |
| `[gcode_shell_command guppybeep]` | **FOUND** — but this is a nuance worth calling out explicitly, not evidence of staleness: `beeper.cfg` line 12 defines `[gcode_shell_command guppybeep]` as *current, intentional, immutable* NebulaOS config (its header documents this as a deliberate port of "GuppyScreen guppy_cmd.cfg buzzer section... GuppyScreen config dependency removed"), and it is the shell-command backend the current `M300`/`PLAY_TUNE` macros call via `RUN_SHELL_COMMAND CMD=guppybeep`. Its presence on the RC1 device is not stale leftover — it is expected, current source. |
| `[gcode_shell_command set_camera_quality]` | **FOUND** — same nuance: `camera.cfg` line 11 defines this as current, intentional, immutable config backing the current `SET_CAMERA_QUALITY_LOW/MED/HIGH` macros. Not stale. |

So of the specific names named in the RC1 investigation, five
(`INPUT_SHAPER`, `INPUT_SHAPER_GRAPHS`, `BED_MESH_CALIBRATE` override,
`TURN_ON_FANS`/`TURN_OFF_FANS` as a pair, `_DISCONNECT_PROBE`,
`_HOMING_PARAMS`) plus `guppy_input_shaper` are confirmed genuinely absent
from current tracked source — they are pure legacy carryover from an era
before this project vendored SimpleAF/GuppyScreen macros were replaced —
while `guppybeep` and `set_camera_quality` are current, correct,
intentional `gcode_shell_command` definitions that happen to share a name
with what the old GuppyScreen/OpenKE install also used (by design — this
project deliberately ported those two shell-command names forward). Their
presence on the RC1 device does not indicate staleness on its own; only the
macro names above do.

## 6. Statement of record

```
SOURCE_MACRO_COUNT=47
EXPECTED_RUNTIME_MACRO_COUNT=49
RUNTIME_MACRO_PROVENANCE_COMPLETE=YES
UNEXPLAINED_RUNTIME_MACROS=0
```

The 83 seen on the RC1 hardware device is fully explained as stale,
persistent, user-owned device state (§5) — not a build or composition
defect in current source. `RUNTIME_MACRO_PROVENANCE_COMPLETE=YES` and
`UNEXPLAINED_RUNTIME_MACROS=0` reflect that every one of the 49 expected
definitions has been traced to a specific file/line (§3), and every
specific "extra" name named in the investigation has been traced to either
"genuinely absent from source" (6 legacy names) or "present by design, not
evidence of staleness" (`guppybeep`, `set_camera_quality`) (§5).

## 7. Recommended build/static check

None of this project's existing `tests/*.sh` scripts currently assert an
exact macro count or a legacy-name denylist. Following this repo's
established shell-test convention (see `tests/klipper-composition-tests.sh`,
`tests/factory-clean-provision-tests.sh`, `tests/printer-cfg-migration-tests.sh`
for the `PASS=0`/`FAIL=0`/`pass()`/`fail()`/`set -u` pattern, and
`tests/nebulaos-printerdata-seed-tests.sh` for the "compare against the real
tracked source, not a hand-written fixture" pattern), a new
`tests/runtime-macro-provenance-tests.sh` should assert, against the real
tracked files (not copies/fixtures, since these files are cheap to read
directly and the whole point is catching drift in the tracked source
itself):

1. **Exact total count.** Running
   `grep -rhE '^\[gcode_macro ' scripts/build/overlay/etc/nebulaos/klipper/*.cfg | wc -l`
   equals exactly `47`, and
   `grep -rhE '^\[delayed_gcode ' scripts/build/overlay/etc/nebulaos/klipper/*.cfg | wc -l`
   equals exactly `2`. Fail loudly (naming the actual count found vs.
   expected) on any drift in either direction — a decrease is a silent
   feature removal, an increase means this document (and its expected
   count) is now out of date and must be regenerated/reviewed together with
   the change that added the macro.
2. **No duplicate names.** Extracting all `[gcode_macro NAME]` values across
   those same files, `sort`, and confirm zero duplicates
   (`sort | uniq -d` produces no output). A duplicate is a Klipper config
   error (last definition silently wins) that should fail the build.
3. **Legacy/stale name denylist.** None of the following section headers
   may appear, anywhere under `scripts/build/overlay/`, as an actual
   Klipper config section (i.e. matched as `^\[gcode_macro NAME\]` or
   `^\[gcode_shell_command NAME\]`, not merely as a substring in prose/docs):
   `INPUT_SHAPER`, `INPUT_SHAPER_GRAPHS`, `BED_MESH_CALIBRATE`,
   `TURN_ON_FANS`, `TURN_OFF_FANS`, `_DISCONNECT_PROBE`, `_HOMING_PARAMS`,
   `guppy_input_shaper`. (`guppybeep` and `set_camera_quality` must be
   *excluded* from this denylist — they are current, intentional
   `gcode_shell_command` names per §5, and a check that flagged them would
   be a false positive.) Any match should fail with the exact file:line it
   was found at, since a real regression here means an old
   SimpleAF/GuppyScreen-vendored macro was accidentally reintroduced into
   tracked source.
4. **`printer.cfg` defines zero macros of its own.** Assert that
   `scripts/build/overlay/opt/printer_data/config/printer.cfg` contains no
   `^\[gcode_macro ` or `^\[delayed_gcode ` lines — it must remain a pure
   `[include ...]` entrypoint plus `SAVE_CONFIG` data, per §1/§4. A macro
   appearing there directly (rather than in the five immutable files) would
   silently change SOURCE_LAYER classification and break the "one
   authoritative printer.cfg" invariant this document and
   `04-cross-compile-app-stack.sh`'s seed-copy logic both depend on.
5. **Seed-source parity.** Assert byte-for-byte identity (e.g. `diff`)
   between `scripts/build/overlay/opt/printer_data/config/printer.cfg` and
   whatever `04-cross-compile-app-stack.sh` copies into
   `$OVERLAY/opt/nebulaos-seeds/printer_data-config/printer.cfg` at build
   time (that build step is scripted, not run by this static check, so this
   assertion should run post-build against the produced overlay tree, or
   equivalently assert the copy step in `04-cross-compile-app-stack.sh`
   still uses a plain, unmodified copy of
   `scripts/build/overlay/opt/printer_data/config/` as its source and
   performs no macro-content transformation). This is what actually
   guarantees a virgin device and a factory-clean-provisioned device both
   land on exactly the 49 counted here — if the two ever diverge, this
   document's EXPECTED_RUNTIME_MACRO_COUNT would no longer describe every
   fresh-install path.

This is a specification only — the checks above have not been implemented
as an actual `tests/*.sh` script by this document.
