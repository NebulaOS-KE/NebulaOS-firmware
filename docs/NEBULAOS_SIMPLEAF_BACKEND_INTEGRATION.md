# NebulaOS SimpleAF Backend Integration

2026-07-29 mission: deliver a functional SimpleAF-aligned Klipper backend for
the Ender-3 V3 KE, using the standard BLTouch-compatible probe, while
preserving NebulaOS's own OS/build/service/update architecture unchanged.
Continues from the prior analysis-only audit (memory record
`project_simpleaf_backend_analysis`); this document records what was actually
built.

Scope boundary for this pass: **BLTouch-only**. Load-cell (`prtouch_v2`/
`z_compensate`) activation and GuppyScreen backend adaptation are deliberately
deferred to separate future missions - see "Deferred" below.

## 1. SimpleAF baseline, now actually vendored

"SimpleAF" in this project's own vocabulary means `pellcorp/creality` - see
`README.md:307`. That repo was, until this mission, only ever referenced via
live WebFetch/GitHub-API lookups, never vendored. It is now:

- Cloned to `vendor/pellcorp-creality` (gitignored, same as every other
  vendor tree in this project), pinned via `scripts/build/00-fetch-vendor-sources.sh`
  to `d18d354456a89c20507e574feaa34d6389e679ca` (branch `main`, resolved at
  fetch time 2026-07-29 - not a moving branch).
- Confirmed, via `readme.md`'s own title, to explicitly support "Ender 3 V3
  KE" - this project's own hardware. Its own `k1/installer.sh` names this
  printer model `F005`/`NEBULA` internally (`k1/fan_control.f005.cfg`:
  "Ender 3 V3 KE (F005) Fan Control").
- **No LICENSE/COPYING file anywhere in the repo; GitHub API reports
  `"license": null`.** Vendored anyway per an explicit, recorded user
  decision (memory record `feedback_simpleaf_license_risk_accepted.md`) -
  not a default assumption of redistribution rights. Flag this plainly in
  any future release notes as a knowingly-accepted risk.

The Klipper *engine* (`pellcorp/klipper`, vendored via the `coreflake1/
NebulaOS-klipper` fork) was already correctly vendored before this mission
and needed no change - both repos independently confirm the same base commit
(`386fde4`).

## 2. What "SimpleAF" actually turned out to mean

`pellcorp/creality`'s real structure, confirmed by reading the source
directly (not assumed from documentation):

- `k1/installer.sh` (2592 lines) is an imperative, interactive **installer
  script** that patches an already-existing Creality-stock `printer.cfg` in
  place via a `CONFIG_HELPER` tool and `cp`+`sed` operations - it does not
  ship a standalone, ready-to-include config tree. Per this mission's own
  explicit instruction ("Do not run SimpleAF installer scripts on the
  printer"), this script was read for reference only, never executed.
- The actual **portable, board-agnostic macro/workflow layer** lives in
  `config/*.cfg` (not `k1/*.cfg`, which is Creality-installer/OS-specific)
  - `start_end.cfg`, `client.cfg`, `homing.cfg`, `useful_macros.cfg`,
  `Line_Purge.cfg`, `Smart_Park.cfg`, `bltouch_macro.cfg` (+ sibling files
  for beacon/btteddy/cartographer/cartotouch/klicky/microprobe, none of which
  apply here). Every branch not relevant to this printer (sensorless
  homing, alternate probes, camera stop/start) is already guarded by a
  `printer.configfile.settings`/variable check and safely no-ops - this
  design let almost all of it be vendored close to byte-for-byte.
- `k1/internal_macros.cfg` is **deliberately NOT vendored at all**. Every
  command in it targets Creality-installer-only paths
  (`/usr/data/pellcorp/tools/*.sh`), `systemctl` (no systemd on this
  Buildroot image), or a camera architecture completely different from
  NebulaOS's own database-seeded one (`S57nebulaos-camera-seed`). Nothing
  in the vendored workflow chain has a hard (unguarded) dependency on it -
  the one real collision it would have caused (`[gcode_macro BEEP]`,
  targeting a nonexistent `/usr/bin/beep`) is avoided entirely by skipping it,
  and this project's own `GuppyScreen/guppy_cmd.cfg` already provides a
  correct `BEEP` pointed at the real `/usr/data/guppyscreen/guppybeep` binary.

## 3. What was vendored, where, and why

New directory: `scripts/build/overlay/opt/printer_data/config/simpleaf/`

| File | Source | Modification |
|---|---|---|
| `homing.cfg` | `pellcorp/creality` `config/homing.cfg` | None (byte-for-byte) |
| `useful_macros.cfg` | `pellcorp/creality` `config/useful_macros.cfg` | None (byte-for-byte) |
| `start_end.cfg` | `pellcorp/creality` `config/start_end.cfg` | None (byte-for-byte) |
| `Line_Purge.cfg` | `pellcorp/creality` `config/Line_Purge.cfg` | None (byte-for-byte) |
| `Smart_Park.cfg` | `pellcorp/creality` `config/Smart_Park.cfg` | None (byte-for-byte) |
| `bltouch_macro.cfg` | `pellcorp/creality` `config/bltouch_macro.cfg` | None (byte-for-byte) |
| `client.cfg` | `pellcorp/creality` `config/client.cfg` | Two patches: `[virtual_sdcard]` path changed to this project's canonical `/opt/printer_data/gcodes`; `[respond]` section removed (already provided by `GuppyScreen/guppy_cmd.cfg` - defining it twice is a hard Klipper config error) |
| `fan_control.cfg` | NebulaOS-authored (not vendored) | New - only `TURN_OFF_FANS`/`TURN_ON_FANS`, since this project's own `[fan]`/`[heater_fan]` hardware sections already exist and shouldn't be duplicated |

Deliberately **not** vendored: `config/bltouch.cfg` (its `[bltouch]`/
`[bed_mesh]`/`[screws_tilt_adjust]`/`[axis_twist_compensation]` sections
contain unfilled installer template placeholders - literal `999,999` values
meant for `sed` substitution at install time, not real hardware values).
This project's own `printer.cfg` already has the real, physically-qualified
`[bltouch]`/`[bed_mesh]` sections for this exact printer (fetched from the
real device) - only the macro wrapper (`bltouch_macro.cfg`) was needed.

## 4. Real conflicts found and resolved

Three genuine duplicate-definition collisions were found by cross-checking
every vendored section against the existing config closure, before they
could break Klipper's config parser:

1. **`[respond]`**: both `client.cfg` and the existing `GuppyScreen/
   guppy_cmd.cfg` define it. Dropped from the vendored `client.cfg` copy.
2. **`[force_move]`**: both `homing.cfg` and this project's own `printer.cfg`
   defined it identically. Removed the standalone one from `printer.cfg`
   (homing.cfg's copy now supersedes it).
3. **`virtual_sdcard`/`pause_resume`/`display_status`/`PAUSE`/`RESUME`/
   `CANCEL_PRINT`**: both the existing `frontend-controls.cfg` (from the
   2026-07-29 mainline print-controls mission) and the new `client.cfg` +
   `start_end.cfg` define these. `frontend-controls.cfg`'s `[include]` was
   removed from `printer.cfg` - the file itself is kept on disk, unincluded,
   as a fallback reference, with a header note added explaining this.

A fourth issue was a missing dependency, not a duplicate: `start_end.cfg`'s
adaptive bed-mesh logic and `Smart_Park.cfg`/`Line_Purge.cfg` unconditionally
read `printer.exclude_object.objects` - without a `[exclude_object]` section
anywhere in the config, this raises a Jinja `UndefinedError` and `START_PRINT`
would fail immediately. Added `[exclude_object]` to `printer.cfg`'s hardware
section.

## 5. Include-order dependency (a real correctness issue found and fixed)

`pellcorp/creality`'s own `k1/installer.sh` copies files in the order
`homing.cfg → internal_macros.cfg → useful_macros.cfg → start_end.cfg →
Line_Purge.cfg → Smart_Park.cfg → client.cfg → bltouch.cfg → bltouch_macro.cfg`
- but that is the order of **install-script actions**, not necessarily the
resulting `[include ...]` order in an assembled `printer.cfg` (the actual
insertion position is whatever `CONFIG_HELPER --add-include` does, which
wasn't available to inspect).

Reasoning from first principles instead: `start_end.cfg`'s `[gcode_macro
CANCEL_PRINT] rename_existing: CANCEL_PRINT_BASE` requires a real, already-
registered native `CANCEL_PRINT` command at Klipper config-load time.
Checked directly against `vendor/klipper/klippy/extras/pause_resume.py:24` -
**`pause_resume.py`, not `virtual_sdcard.py`, registers the native
PAUSE/RESUME/CANCEL_PRINT commands**, and it only does so once `client.cfg`'s
`[pause_resume]` section loads. So `client.cfg` must be included **before**
`start_end.cfg` - the reverse of the installer script's own chronological
action order. `printer.cfg`'s final include order (below the hardware
section, so `bltouch_macro.cfg`'s `BED_MESH_CALIBRATE` rename also finds a
real, already-loaded `[bed_mesh]`):

```
[include simpleaf/homing.cfg]
[include simpleaf/useful_macros.cfg]
[include simpleaf/fan_control.cfg]
[include simpleaf/client.cfg]
[include simpleaf/start_end.cfg]
[include simpleaf/Line_Purge.cfg]
[include simpleaf/Smart_Park.cfg]
[include simpleaf/bltouch_macro.cfg]
```

Verified locally: concatenating the real tracked `printer.cfg` +
`GuppyScreen/guppy_cmd.cfg` + all `simpleaf/*.cfg` files and counting section
occurrences gives exactly 1 each for `virtual_sdcard`, `pause_resume`,
`display_status`, `[gcode_macro PAUSE]`, `[gcode_macro RESUME]`,
`[gcode_macro CANCEL_PRINT]`, `[respond]`, and `[force_move]` - no
duplicates, no gaps.

## 6. Moonraker alignment (Phase 9)

Compared this project's `moonraker.conf` against SimpleAF's real `k1/
moonraker.conf` (now locally readable, not just remembered from an earlier
live fetch) section by section:

| SimpleAF | NebulaOS | Decision |
|---|---|---|
| `provider: supervisord_cli`, `validate_service/config: False` | Identical already | KEEP |
| `enable_auto_refresh/enable_system_updates: False` | Identical already | KEEP |
| `[update_manager klipper/moonraker]` reduced to `channel` only | Identical shape already | KEEP |
| Klipper/Moonraker `pinned_commit` | NebulaOS deliberately unpinned (health-check/rollback design instead) | REJECT (already a documented, deliberate divergence) |
| `[webcam ...]` config section | NebulaOS uses database-seeded camera instead | REJECT (config-defined webcams are permanently undeletable via Moonraker's API - confirmed against `webcam.py` source) |
| `[file_manager] enable_object_processing: True` | Was absent | **ADAPT - added.** Without it, `exclude_object.objects` never gets real per-object polygons from sliced gcode, so the new adaptive-mesh/Smart-Park/Line-Purge macros silently fall back to their already-safe empty-list defaults (full bed mesh, park/purge at bed origin) instead of real print-area-aware behavior |

`[octoprint_compat]`/`[secrets]`/`[history]`/`spoolman`/`timelapse` sections
present in SimpleAF's real config were left for a future pass - not evaluated
feature-by-feature against Mainsail's actual detection contract this time
(same "detection ≠ functionality" caution as the PAUSE/RESUME/CANCEL_PRINT
regression).

## 7. Existing build-gate bugs found and fixed (not part of the SimpleAF work itself, but blocking it)

1. **`scripts/build/lib/validate-frontend-controls.sh`**: its recursive
   include-closure resolver used a plain (non-`local`) shell variable
   (`rc_dirname`) shared across recursive calls. Adding a second nested-
   directory include (`simpleaf/`) after the existing `GuppyScreen/`
   one exposed this immediately - every top-level include *after*
   `GuppyScreen/guppy_cmd.cfg` got silently misresolved as
   `GuppyScreen/<name>`. Invisible before only because `guppy_cmd.cfg` was
   always the last multi-level include. Fixed by making the per-call state
   `local`. All 13 cases in `tests/nebulaos-frontend-controls-validation-tests.sh`
   pass after the fix (including against the real tracked overlay source).
2. **`scripts/build/04-cross-compile-app-stack.sh`** and
   **`scripts/build/06-verify.sh`**: both had a *second*, hardcoded
   (non-generic) check requiring `printer.cfg` to literally contain
   `[include frontend-controls.cfg]`, plus `06-verify.sh` built its own
   closure by concatenating only `printer.cfg` + `frontend-controls.cfg` +
   `guppy_cmd.cfg`. Updated both to reflect the new architecture
   (`simpleaf/client.cfg` + `simpleaf/start_end.cfg` now provide the same
   sections; `06-verify.sh`'s closure now also dumps and concatenates the
   8 `simpleaf/*.cfg` files from the packaged image).
3. **Blank-required-option false positive** (both scripts' own
   `blank_required_option` awk check, duplicated in each): a bare `gcode:`
   with nothing indented after it was flagged as a syntactically-blank
   required option - but this is genuinely valid Klipper syntax for a
   variable-only `gcode_macro` (e.g. `_HOMING_PARAMS`), confirmed directly
   against `vendor/klipper/klippy/extras/gcode_macro.py`'s
   `load_template()`, which happily wraps an empty string. Excluded `gcode:`
   specifically from the check in both copies - every other option name is
   still caught (this is the exact check that historically caught the real
   `[bltouch] z_offset:` bug).
4. Added a **vendor pin drift check** to `06-verify.sh` (previously did not
   exist at all) comparing `vendor/klipper`, `vendor/moonraker`, and the new
   `vendor/pellcorp-creality`'s actual `git rev-parse HEAD` against the pins
   recorded in `00-fetch-vendor-sources.sh`. This immediately surfaced a
   real, pre-existing, unrelated drift: `vendor/klipper`'s checkout is one
   real commit (`d839d03`, a genuine already-shipped chelper fix) ahead of
   the pin the fetch script still records (`b3d5ab2`) - flagged in the
   script's own comment as a known gap to close separately, not silently
   "fixed" by changing the expected value to match whatever's currently
   checked out.

## 8. Factory seed (Phase 13)

No script changes were needed here: `S04nebulaos-factory-seed`'s seed step
already does `cp -a "$PRINTER_DATA_CONFIG_SEED/." "$dest/"` (a full recursive
tree copy), so the new `simpleaf/` subdirectory is automatically included.
Verified `tests/nebulaos-printerdata-seed-tests.sh` still passes unchanged.

## 9a. Slicer contract (Phase 10)

Now that `START_PRINT`/`END_PRINT` actually exist (they didn't before this
mission), their real parameter contract, read directly from
`simpleaf/start_end.cfg`:

- `START_PRINT BED_TEMP=<float, default 65> EXTRUDER_TEMP=<float, default 230> [BED_SOAK=0|1]`
  - Both optional - slicer can omit either and get a safe default.
  - Owns, in order: pre-heat nozzle to a non-oozing 150°C, start bed
    heating, home (only if not already homed), wait for bed temp (with a
    "bed warp stabilisation" soak only when asked - off by default since
    Run 20 (G112): `START_PRINT ... BED_SOAK=1` soaks (8 s per degree C to
    heat), `BED_SOAK=0` skips, without `BED_SOAK` the
    `Bed_Warp_Stabilisation` output pin decides, which starts at `value: 0`),
    clear any stale bed mesh, adaptive `BED_MESH_CALIBRATE`, smart-park
    near the print area, wait for nozzle temp, line purge. **The slicer
    must NOT also home, heat, or mesh-calibrate in its own start gcode** -
    `START_PRINT` owns the entire sequence.
- `END_PRINT` - no parameters. Restores velocity/accel limits, clears bed
  mesh, retracts, parks at X2 Y218 (G111; in front of the aux fan while a cooldown runs),
  turns off heaters/fans (or runs a nozzle cooldown-and-park sequence first,
  if `end_print_cool_down` is enabled, which it is by default). **The
  slicer's own end gcode should be empty or minimal** - do not have the
  slicer turn off heaters/fans itself, `END_PRINT` already owns that.
- `CHAMBER_TEMP`/`PRINT_AREA`/material-type parameters: not part of this
  vendored contract at all - not supported, would be silently ignored if a
  slicer profile sent them.
- Canonical slicer start/end gcode (OrcaSlicer/PrusaSlicer/Cura, all
  equivalent): start gcode should be exactly
  `START_PRINT BED_TEMP=[bed_temperature] EXTRUDER_TEMP=[nozzle_temperature]`;
  end gcode should be exactly `END_PRINT`. Proposed only - not deployed to
  any slicer profile in this pass, and not yet qualified against a real
  print (see §10).

## 9. Deferred (explicitly out of scope this pass)

- **Load-cell (`prtouch_v2`/`z_compensate`) activation.** The klippy_extras/
  code remains present but unwired - no `[prtouch_v2]`/`[z_compensate]`
  section exists in the active config. Nothing in this pass's vendored
  SimpleAF macros references load-cell-specific commands.
- **GuppyScreen backend adaptation.** `GuppyScreen/guppy_cmd.cfg`'s own
  pre-existing dangling references (`resonance_tester`/`adxl345`/
  `save_variables`, documented in the prior analysis mission) were left
  exactly as they were - not ported into the SimpleAF workflow, not faked
  with placeholder sections, not removed. GuppyScreen's basic functions
  (BEEP, camera reload, WiFi panel, backup/restore) are unaffected and keep
  working as before.
- **Live-device qualification.** Nothing in this pass touched the physical
  printer, the device's persistent config, or performed any build/flash.
  Everything above is source-only, offline, and reversible via git.

## 10. What's proven vs. what still needs physical qualification

Proven by offline static checks (this pass): the config closure resolves
with no missing includes, no duplicate sections, no circular renames, exactly
one definition each of every print-control object Mainsail/GuppyScreen are
known to check, and the canonical gcode path is correct.

**Not yet proven**: that this configuration actually parses successfully
under a real (or simulated) Klipper process, that `START_PRINT`/`END_PRINT`/
homing/bed-mesh/pause-resume-cancel/material-load-unload actually execute
correctly against real MCU firmware, and that a real test print completes.
That requires the live-device and physical qualification phases (this
mission's own Phases 14-20), which were deliberately not started in this
pass and require the user's explicit go-ahead given the real, physical, and
in some cases hard-to-reverse risk involved (homing, heating, extrusion, a
firmware flash to the device's A/B slots).

## 11. Live physical qualification (2026-07-30, real device 192.168.0.128)

Two real bugs were found and fixed during actual homing qualification -
full detail in memory record `project_simpleaf_bltouch_qualification`:

1. **`simpleaf/homing.cfg`'s `_PRE_HOME_Z`** unconditionally read
   `printer["gcode_macro START_CAMERA"].started`, which only exists via
   `pellcorp/creality`'s own (deliberately not vendored)
   `k1/internal_macros.cfg`. Confirmed deterministic - crashed `G28 Z`
   with a Jinja `UndefinedError` on every single attempt (reproduced 3
   times by the user via touchscreen/Mainsail, once via direct API call).
   Fixed with a one-line `!= null` guard, matching the pattern already used
   safely everywhere else in this file.
2. **`_HOMING_PARAMS`' `home_x`/`home_y: 150` and `safe_z: 3`** are
   `pellcorp/creality`'s own generic reference-printer defaults, not this
   printer's values - caught live by the user noticing the post-home park
   position wasn't this bed's center. SimpleAF's real installer always
   computes `home_x`/`home_y` from `stepper_x/y.position_max / 2`
   (integer division) at install time rather than shipping a separate
   `homing.cfg` per printer model, and bumps `safe_z` to `5` specifically
   for BLTouch installs (a real probe-deploy-clearance fix, not
   cosmetic). Since this project deliberately doesn't run that installer,
   vendoring `homing.cfg` byte-for-byte silently kept the generic values.
   Fixed using this printer's own real `printer.cfg` values
   (`stepper_x.position_max: 221` -> `home_x: 110`,
   `stepper_y.position_max: 223` -> `home_y: 111`).

Verified live after both fixes: a clean `G28` parks at `(110, 111, 10)`
exactly as expected, `homed_axes: "xyz"`, zero errors in the gcode store.
Basic XY homing and BLTouch Z homing (qualification Stages 2-3) both pass.

