# NebulaOS / Ender-3 V3 KE: Weight-Free Load-Cell Contact Detection

> Stored 2026-10-18 for gap **G83b** (Tim supplied this brief; decision: split
> load-cell work into G83a = guided known-weight calibration + guard, next run,
> and G83b = this weight-free path, staged; stages A and B in the next run,
> C/D need Tim at the printer with a scale). Content below is the brief as
> supplied.

**Status:** Implementation-ready engineering brief; thresholds and unattended motion are NOT hardware-qualified.
**Investigation date:** 2026-10-18.
**Audience:** Coding agent / reviewer working across `NebulaOS-klipper-extensions` and `NebulaOS-firmware`.
**Objective:** Eliminate the per-user known-weight calibration requirement for *nozzle/bed contact detection*, while keeping measured force in grams a separate optional calibrated capability.

## 0. Copy/paste assignment for the coding agent

Implement an opt-in `raw_contact` backend for the Ender-3 V3 KE's existing under-bed HX711 and secondary nozzle-contact probe. Leave upstream Klipper pristine; use its pinned `hx71x`, `load_cell`, `MCU_trigger_analog`, `MCU_SosFilter`, and `LCBestFit` interfaces. Keep the existing calibrated-grams path exactly functional and the default. **Do not invent or ship numeric raw-contact force/safety thresholds, fake `counts_per_gram`, or enable unattended motion**. Stage work as separate reviews: (1) no-motion diagnostics and offline replay tests; (2) mode-aware raw ADC processing and MCU arming behind an explicit unqualified/disabled gate; (3) supervised hardware qualification using calibrated reference machines; (4) only after documented force and fault qualification, allow bounded single-point nozzle contact; (5) only after separate qualification, connect the legacy, nozzle-clean, and full-auto paths. Provide unit/regression tests, failure codes, a compatibility review, and a short hardware qualification report template. Follow the detailed contract below.

## 1. Baseline and verified facts

- `NebulaOS-firmware/manifests/dependencies.conf` pins upstream official Klipper to `58bd67db3ce1be1951c3e4a6d1156a79903d4edc` and extensions to `8f86925087bae8e3025be4553a6bb161618bb22a` at investigation time. Re-check pins before editing; validate against the *deployed pin*, not GitHub master.
- The KE's under-bed load cell is a single strain-gauge assembly at the **front-left** corner. It is an HX711 on MCU `DOUT=PC6`, `SCLK=PA4`. CR Touch remains the **only global Z endstop/probe** (G28 and bed mesh). NebulaOS HX711 is secondary, for nozzle-contact Z-offset work.
- Firmware `z_offset_probe.cfg` currently specifies `contact_speed: 2.0`, `retract_dist: 2.0`, `retract_speed: 10.0`, `trigger_force: 75` g, `force_safety_limit: 2000` g, `tare_time: 0.067`. These are for the existing calibrated mode; do not reuse them as raw-count values.
- Current single-point calibration reference: `nebulaos_calibration.reference_x: 20`, `reference_y: 25` (physical bed coordinates). Do not enable arbitrary X/Y in raw mode. Automatic load-cell axis-twist is intentionally unsupported due to a recorded hardware safety incident.
- `nebulaos_z_offset_probe.ZOffsetProbe` instantiates `hx71x`, upstream `load_cell.LoadCell`, `MCU_trigger_analog`, `MCU_SosFilter(..., 4)`, and `LCBestFit`. It already uses MCU `homing.probing_move` rather than polling Python to stop motors. `_tare_and_arm()` requires upstream `is_calibrated()`, and uses `counts_per_gram` both for trigger scaling and for the independent reference-tare-centered raw ADC safety window.
- The pinned upstream sensor collector produces `[time, grams_or_None, raw_adc_counts, tare_counts]`; on an uncalibrated `LoadCell`, `grams_or_None` is **None**, but raw ADC counts remain available. The current NebulaOS `_fit_contact_z()` uses the grams field for fitting AND `abs(grams)` for peak telemetry, so BOTH paths require mode-aware changes.
- `MCU_SosFilter.set_offset_scale(offset, scale)` can use an offset equal to `-tare_counts` and scale `+1.0` or `-1.0` to create signed **counts from tare**. `MCU_trigger_analog.set_trigger('gt', count_threshold)` can trigger on sign-normalized compression; `abs_ge` also exists. `set_raw_range(min_raw, max_raw)` enforces a separate ADC safety envelope. The actual MCU supports `abs_ge`, `gt`, `diff_peak_gt`, sensor timeout monitoring, raw-range cancellation, and overflow cancellation. No MCU code addition appears needed.
- Upstream `LCBestFit.find_best_fit(data)` takes (amplitude, Z) sample pairs; it does not require the amplitude to be in grams. Its objective is invariant (mathematically) under nonzero linear rescaling of amplitude. Numerical equivalence must be tested on real captured traces.
- Pinned upstream HX711 defaults to 80 configured samples/second, but **hardware determines 10 vs 80 SPS**. Verify measured actual rate by `LOAD_CELL_DIAGNOSTIC`; the configured 80 SPS alone proves nothing. Upstream advises probing HX711 slower than 2 mm/s. The current NebulaOS 2.0 mm/s setting is at, not below, that guidance.
- Historical 2026-08-09 *older PRTouch-path* non-motion test: no-load about -252,500 counts; static nozzle contact about -422,400; other hand/object loads changed signal. This proves a strong response on one machine, NOT an MCU trigger threshold, per-sample noise sigma, a gram calibration, a current upstream-HX711 equivalent, or unit-to-unit sensitivity.
- Existing later comments describe 22 established Z-offset runs/66 contacts with a calibrated sensor plus 6 simulated bootstrap contacts. This supports motion geometry and current quality gates, but does NOT validate an uncalibrated raw-count safety envelope or a genuine virgin unit.

### Hard constraints

1. Upstream `Klipper3d/klipper` checkout remains pristine: no edits, shadowed upstream module filenames, monkeypatching, changes to `src/`, or changed upstream `load_cell.is_calibrated` behavior. No new MCU binary requirement unless separately authorized and proved necessary (not expected).
2. Preserve CR Touch as the global probe and Z virtual endstop. Do not replace G28 or bed mesh; do not resurrect the retired PRTouch runtime stack or automatic axis twist.
3. Preserve existing calibrated-force behavior, including `LOAD_CELL_CALIBRATE`, all current safety defaults, and force telemetry in grams.
4. **Never claim a raw sensor is calibrated in grams.** Add separate raw-contact readiness/status; do not set fake `counts_per_gram` or `reference_tare_counts` simply to bypass Klipper.
5. A mode selected in configuration is not by itself a hardware-safety qualification. Reject nozzle motion until a validated, versioned hardware profile and per-unit health checks are present.
6. No new default trigger or safety-count values without documented measured-force qualification. If qualification evidence is missing, diagnostics may run, but probing fails closed.

## 2. Source locations to inspect

### `coreflake1/NebulaOS-klipper-extensions`

- `extras/nebulaos_z_offset_probe.py`: `_get_safety_range`, `_get_grams_per_count`, `_tare_and_arm`, `_fit_contact_z`, `touch_probe`, `get_status`.
- `extras/nebulaos_probe_pair.py`: `measure_probe_nozzle_pair`, established versus bootstrap descent envelopes, quality and repeatability checks, `ContactSample` telemetry.
- `extras/nebulaos_calibration.py`: `cmd_z_offset_calibrate` (currently checks `is_calibrated()` near line 576); full `NEBULAOS_AUTO_CALIBRATE` preflight (near line 895), where nozzle cleaning follows; transaction journal and single `SAVE_CONFIG` behavior.
- `extras/z_compensate.py`: legacy `Z_OFFSET_CALIBRATION` and per-print adjustment. Current `touch_probe()` call near line 438 supplies no extra per-contact `minimum_allowed_z`; investigate this before *any* raw-mode legacy exposure.
- `extras/nozzle_clear.py`: uses `touch_probe()` during the wiping routine. Do not silently enable raw mode here.
- `extras/test_z_offset_probe_safety.py`, `extras/test_nebulaos_probe_pair.py`, `extras/test_nebulaos_calibration.py`, `extras/test_z_compensate_*`: retain/add tests.
- `nebulaos-extensions.json` and `docs/COMPATIBILITY.md`: new Klipper API dependencies and manifest/composition assumptions. The old global `qualified_commit` manifest gate was retired; use current symbol checks, not old documentation.

### `coreflake1/NebulaOS-firmware`

- `scripts/build/overlay/etc/nebulaos/klipper/z_offset_probe.cfg`: image-owned static config; existing load cell section.
- `scripts/build/overlay/etc/nebulaos/klipper/calibration.cfg`: fixed physical reference X=20,Y=25 and public calibration aliases.
- `scripts/build/overlay/etc/nebulaos/klipper/machine.cfg`: CR Touch and Z mechanical limits.
- `docs/NEBULAOS_CALIBRATION_CONFIG_OWNERSHIP.md`: `SAVE_CONFIG` rejects calibration results with conflicting literal values in included config; per-unit values must remain persistable in the user-owned autosave block or via a separately justified state format.
- `docs/NEBULAOS_LOADCELL_FIRST_HARDWARE_TEST.md`: old sensor raw readings and warnings.
- `tests/klipper-config-load-smoke-tests.py`: production composed-config validation.
- `manifests/dependencies.conf`: actual paired dependency pins. Update/review pins through normal paired validation and promotion.

### Pinned upstream Klipper

- `klippy/extras/load_cell.py`: `LoadCell._sensor_data_event`, `LoadCellSampleCollector`, `counts_to_grams`, `is_calibrated`.
- `klippy/extras/load_cell_probe.py`: `LCBestFit`, `_lookup_z_pos`, fit semantics, reference tare/force safety example.
- `klippy/extras/trigger_analog.py`: `MCU_SosFilter.set_offset_scale`, `MCU_trigger_analog.set_trigger` / `set_raw_range` / home lifecycle.
- `klippy/extras/hx71x.py`: real ADC range, hardware sample rate, error reporting.
- `src/trigger_analog.c` and `src/sos_filter.c`: exact fixed-point scaling and MCU stop/error behavior.

## 3. Why naive auto-thresholding is not safety calibration

The unknown relation is `ADC_delta = sensitivity_counts_per_newton * transmitted_load_newtons`, where sensitivity depends on the sensor, mounting/preload, load transfer from the nozzle, bed support, geometry, thermal state, and electronics. Idle noise can reveal a signal threshold with low false-positive probability; **it cannot bound the mechanical force required to exceed that threshold**. A weak or mechanically decoupled sensor can have a perfectly quiet baseline and still require dangerous nozzle force before triggering.

Therefore distinguish:

- **User-facing goal:** no known-weight operation on each customer printer.
- **Engineering prerequisite:** qualify a conservative model-specific counts-versus-force envelope on representative reference printers with independent physical force instrumentation, including worst-case mounts, locations, and temperatures.
- **Per-unit checks:** validate that each customer's sensor resembles qualified sensors enough to use that profile. A no-motion hand-tap checks whether the signal is alive and its polarity; it does *not* establish actual force sensitivity because hand force is unknown.
- **Impossible assertion:** 'Noise-only auto threshold guarantees safe force on an arbitrary uncalibrated sensor.' Do not make it.

Sensor safety errors must not be recoverable by automatically re-taring an already compressed bed. Upstream keeps `reference_tare_counts` distinct from its per-contact tare precisely to limit accumulating force under repeated probe cycles. Preserve that principle in raw mode.

## 4. Proposed architecture and data contract

### Two independent modes

- `calibrated_force` (default): byte-for-byte-equivalent operational semantics. `LoadCell.is_calibrated()` and force-in-grams safety; existing `abs_ge` trigger and measured-grams telemetry.
- `raw_contact` (opt in): uses raw ADC and a **qualified** KE-specific sensor profile, independent unloaded reference and per-contact tare; does not provide grams unless the sensor separately has a true force calibration.

Recommend one low-level mode selector in `[nebulaos_z_offset_probe]` rather than a duplicate global probe. Keep the same object, existing `touch_probe()` signature, same MCU dispatch and same paired CR Touch calibration. Do not create a second HX711 instance on the same pins.

### Suggested parameters (names subject to code review)

- `contact_detection_mode: calibrated_force|raw_contact` (default `calibrated_force`)
- `raw_contact_profile_id`: a versioned **pre-qualified hardware profile** (e.g. a particular sensor/board/mount revision). Missing profile => no raw motion.
- `raw_reference_tare_counts`: separate verified unloaded ADC reference, per-unit and persistent. Do not overwrite it at each touch.
- `raw_polarity: positive|negative`: positive change after sign normalization is compression. Determine only via safe no-motion response test and qualify it.
- `raw_trigger_counts`, `raw_max_reference_drift_counts`, `raw_adc_safety_window_counts`, acceptable noise/drift/sample-rate bounds, slope and fit-quality limits: all must be part of the hardware-qualified profile. **No proposed numeric production values in this brief.**
- Any `raw_contact_enabled` or `raw_profile_qualified` flag should be controlled through a reviewed platform/profile activation path, not an unverified user-editable boolean that bypasses safety.

Avoid exposing per-unit mutable config values as literals in immutable `z_offset_probe.cfg` if they must later be saved via upstream `SAVE_CONFIG`. Verify the persistence design against the pinned `ConfigAutoSave._disallow_include_conflicts` contract. A profile schema needs an explicit version and compatibility gate; on changed hardware/firmware, fail closed until reviewed.

### Readiness/status fields

Keep `is_calibrated` **only** for true grams calibration. Add a separate status contract, e.g.:

```
contact_detection_mode
contact_qualified             # reflects profile AND current validated state
raw_profile_id
raw_tare_counts
raw_unloaded_reference_counts
raw_idle_noise_counts
raw_idle_drift_counts
raw_trigger_threshold_counts
raw_peak_delta_counts
raw_at_trigger_delta_counts
last_fitted_contact_z
last_fit_delta
last_contact_rejection_reason
sensor_sample_rate_measured
```

When operating in raw mode without a weight calibration, legacy force keys such as `last_peak_force_g` and `last_force_at_trigger_g` must be `None`, never fake grams. Maintain compatibility for `nebulaos_probe_pair.ContactSample` (add new optional fields carefully, or provide a new diagnostics object); avoid silently changing Moonraker/GuppyScreen consumers.

## 5. Implementation algorithm (candidate, not safety-qualified)

### 5.1 No-motion diagnostics and reference capture

1. Require no print / no queued probing move; ensure nozzle is at a verified clear hover determined via the existing CR Touch path. Do not silently treat 'printer idle' as 'bed unloaded'.
2. Collect a long enough raw HX711 window for statistics (a full second or more for initial investigation, not just the current ~6-sample touch tare). Record raw count/timestamp pairs, sensor error increments, overflows, actual SPS and clipped samples.
3. Compute robust center (median), robust scatter (MAD converted to sigma), peak-to-peak, slope/drift, uniqueness/stuck detection, sample interval checks, and sign response from a **separate** no-motion tap/press qualification when requested.
4. Reject missing samples, saturation, stuck-at values, implausible SPS, sensor errors, unstable baseline and profile mismatch. A quiet, stuck-at sensor must not appear 'healthy'.
5. Only in a known physically unloaded state, and under a separately approved profile initialization workflow, record a persistent unloaded reference `R`. Do not auto-rebaseline after a contact failure or a large drift.
6. Expose `NEBULAOS_RAW_CONTACT_DIAGNOSTIC` (no moves) and optionally `NEBULAOS_RAW_CONTACT_TEST_TAP` (arms MCU trigger but **never commands steppers**), following upstream's `LoadCellProbingMove.probing_test()` pattern. Make these explicit separate commands with clear rejection codes.

### 5.2 Before each permitted raw contact

Pseudocode (do NOT execute on hardware until a profile is qualified):

```python
assert self.mode == 'raw_contact'
profile = require_validated_profile_for_this_hardware()
assert profile.approved_for_physical_contact
assert current_xy == validated_front_left_reference_point
assert machine_has_required_homing_and_clear_hover_state()

samples = collect_idle_samples_and_check_errors()
assert validate_sample_rate_noise_drift_saturation(samples, profile)
tare = robust_center(raw_counts(samples))
R = require_separately_recorded_unloaded_reference()
assert abs(tare - R) <= profile.max_reference_drift_counts

# A noise-driven threshold can only be used within a physically qualified band.
T = max(profile.min_trigger_counts,
        profile.noise_multiplier * measured_noise_in_same_signal_domain)
assert T <= profile.max_trigger_counts
assert T < profile.raw_adc_safety_window_counts
assert predicted_contact_and_z_floor_are_validated_for_this_probe()

# 'polarity' is +1 if compression raises ADC raw values, else -1.
sos_filter.set_offset_scale(-int(tare), profile.polarity)
analog_trigger.set_trigger('gt', int(T))
analog_trigger.set_raw_range(
    int(R - profile.raw_adc_safety_window_counts),
    int(R + profile.raw_adc_safety_window_counts))
# Ensure both bounds are STRICTLY inside the signed 24-bit HX711 ADC range.
# Existing homing.probing_move() performs MCU-monitored slow bounded descent.
```

The trigger uses a **directional, normalized positive compression signal**. The historical raw response was negative-going, but validate polarity on the current upstream-HX711 data path before setting `polarity=-1`. `abs_ge` is a fallback only after considering opposite-sign noise; `diff_peak_gt` exists but is not the recommended first implementation. An upstream eddy-current sensor's use of `diff_peak_gt` does NOT make it automatically appropriate for a strain gauge.

The current NebulaOS `MCU_SosFilter` has a maximum of four sections but no explicit filter design installed, so confirm on the pinned version that raw mode is a pass-through apart from offset/scale. If adding a filter, qualify noise and latency in the **MCU filtered domain**, not a different host sample domain. Check MCU signed 32-bit fixed-point scaling and overflow boundaries.

### 5.3 Contact Z interpolation

The current `LCBestFit` gets `(grams, z)` pairs from ascending-motion data. In raw mode supply `(normalized_compression_counts, z)` pairs:

```python
# Each collected sample: (time, grams_or_none, raw_counts, tare_counts)
if mode == 'calibrated_force':
    magnitude = sample[1]  # already calibrated grams, unchanged
else:
    magnitude = profile.polarity * (sample[2] - sample[3])
z_at_sample = _lookup_z_pos(toolhead, sample[0])
fit_data.append((magnitude, z_at_sample))
```

Update peak and trigger telemetry to avoid `abs(None)` on uncalibrated gram values. Preserve all ascent-window/error/point-count checks (upstream `FIT_MIN_POINTS=3` on each side and `ASCENT_DATA_WINDOW_SECONDS=0.3`). Add raw-specific fit quality: expected slope sign, material signal/noise separation, sufficient compression and release, plausible raw-to-fitted-Z delta, and full return toward baseline after lift. A threshold too low might stop safely but leave insufficient compression for a trustworthy ascent fit; that is a **failed calibration**, not a reason to keep pushing automatically.

### 5.4 Independent motion gates

All of these must hold before descent:

- Qualified profile; independent unloaded reference; sensor health check and current self-check; no stale/invalid profile; supported polarity and actual sampling rate.
- Existing CR Touch Z-home/physical XY pairing, bed mesh state and known clear hover; for the first release, raw mode allowed only at fixed physical `(20, 25)`.
- Existing `nebulaos_probe_pair` *established* or *bootstrap* Z-floor logic, clamped to machine `position_min` and a validated envelope. DO NOT treat historical `bootstrap_contact_envelope_mm: 8.0` as proof of safe raw-mode force; existing bootstrap tests used a calibrated sensor.
- No trigger by the allowed floor means **error, retract safely if possible, NO deeper retry, NO `SAVE_CONFIG`, NO live offset change**.
- MCU sensor timeout/overflow/range errors are fatal for this contact, not recoverable via a new tare.
- Reject repeated probes that start before full bed release / baseline recovery.

## 6. Incremental implementation plan (separate PRs)

### PR A - Evidence and no-motion tools (safe to merge without motion)

1. Add sample-domain pure helpers (raw baseline statistics, sensor validation, polarity normalization, fixture replay).
2. Add an explicitly no-motion diagnostics G-code/status output, and optionally no-motion MCU tap test using existing trigger_analog facilities.
3. Add replay fixture parser for **current pinned Klipper's** `[time, grams, counts, tare]` logs, not only 2026-08 older PRTouch `READ_PRES` output.
4. Demonstrate `LCBestFit` on grams vs raw counts from the **same calibrated captured samples**: near-identical contact Z, meaningful direction-normalized slope. Record numeric differences; do not assume exact mathematical invariance ensures identical floating-point behavior.
5. Add offline tests for no motor calls, no config changes, timeout, ADC errors, stuck/saturated sensor, sample-rate mismatch, missing grams, sign inversion and bad data.

### PR B - Opt-in raw-mode backend, fail-closed on motion

1. Add `calibrated_force|raw_contact` configuration parsing, default calibrated.
2. Branch `_tare_and_arm()` safely; create raw safety/reference handling and count-domain MCU trigger setup.
3. Branch `_fit_contact_z()` and telemetry; no `abs(None)` errors; no misleading gram values.
4. Add profile schema/version checks, status and explicit raw rejection reasons.
5. Until qualification evidence exists, **raw mode reports not motion-qualified** and all nozzle-contact motion commands reject. Only diagnostics and off-printer replay work.
6. Update tests that currently hard-code 'any uncalibrated sensor always forbidden' to express the new rule: 'no weight calibration required only for explicitly hardware-qualified raw mode'; default remains forbidden.

### PR C - Supervised on-machine validation (requires separate human go-ahead)

1. Start on a reference KE with **already calibrated known-force** load cell to measure actual grams and compare raw-count behavior; do not test first on an uncharacterized virgin unit.
2. Verify current native HX711 sample rate, same-MCU trigger handling, hardware polarity, electrical interference (heaters/fans/steppers), hot/cold drift and the true fixed-point trigger domain.
3. Derive candidate count threshold(s) from **measured contact force and peak overshoot**, not idle noise alone. At 80 SPS, one nominal sample period is 12.5 ms; at 2 mm/s, 0.025 mm of motion occurs in one period, before additional stopping delay. Use suitably slower *supervised* test speeds; do not turn these illustrations into safety values.
4. Compare stop latency, force-at-trigger, peak force, fitted Z, repeatability, and release on known-good existing calibrated touches versus the new raw path.
5. Investigate shape-sensitive differences between bare PEI bed contact and nozzle-clean pad/wipe contact; qualify separately.
6. Verify no accidental movement or persistent offsets on every rejection and a normal safe retract path for failures.

### PR D - Physical safety qualification across units

1. Build a profile from a representative sample of real KE units and hardware revisions, with independent load/force measurement and documented safe maximum force for bed/sensor/toolhead.
2. Include deliberately degraded sensor coupling, loosened/uneven bed spacers, disconnected/shorted/stuck HX711 data, incorrect gain or SPS, wrong polarity, thermal drift, nonuniform bed support, and noise transients while probing. Confirm all faults fail closed before harmful load; if not, redesign or require per-unit assisted qualification.
3. Define allowed `raw_trigger_counts` band, independent `R` drift window, raw MCU safety ADC window, health metrics, and user-facing error conditions with confidence bounds.
4. On a genuinely virgin printer (no grams calibration and `bltouch.z_offset=0`), verify the bootstrap physical geometry AND measured peak contact force. Previous `SIMULATE_BOOTSTRAP=1` is not a substitute.
5. Promote only if failed/weak sensors are reliably rejected. Otherwise maintain the conventional weight-calibration fallback or a deliberate user-assisted, no-known-weight sensitivity test.

### PR E - Product integration (only after PR D qualifies)

1. Allow `NEBULAOS_Z_OFFSET_CALIBRATE` to use an explicit `contact_ready` predicate (grams calibrated OR approved raw-contact mode with live health check). Preserve its existing paired probe math, repeatability and `SAVE_CONFIG` transaction semantics.
2. Keep `NEBULAOS_AUTO_CALIBRATE` blocked for raw mode until **nozzle cleaning** is separately qualified or the raw-mode workflow has a safe alternate cleaning strategy; current preflight starts cleaning before Z-offset.
3. Keep legacy `Z_OFFSET_CALIBRATION` blocked until its path derives the same bounded floor as the canonical paired-calibration path. Do not allow raw mode to bypass `_tare_and_arm` on legacy calls.
4. Keep `nozzle_clear.py` blocked for unqualified raw contact on wipe pad until separately validated.
5. Add GuppyScreen/Mainsail UI status and a recovery/fallback route (e.g. use existing guided known-weight calibration, or manual stock `PROBE_CALIBRATE`), without implying grams accuracy.
6. Roll out behind an explicit device/profile qualification gate, with fault reporting, rollback and release notes.

## 7. Acceptance tests the agent must implement

### Software and unit tests

- Unmodified calibrated-force default: existing fixture assertions (75 g/2000 g conversions) and test suite remain passing.
- Raw sensor with `grams=None` can collect and fit using raw counts; no null arithmetic or false gram telemetry.
- Gram-space and raw-count-space `LCBestFit` produce comparable Z on identical logged traces (define tolerance based on offline empirical replay and numerical stability).
- Negative signal orientation normalized correctly; wrong/unqualified orientation blocks motion.
- Same normalized contact curve multiplied by varying positive gains retains correct fit Z; weaker/noisier gains may fail profile health checks.
- Independent reference `R` remains unchanged across dynamic tare operations; repeated contact with residual preload causes rejection.
- `raw_trigger_counts < raw_adc_safety_window_counts`; all windows strictly inside signed 24-bit sensor bounds; correct MCU setup order for current pinned source.
- Missing profile, missing `R`, wrong model, stale/invalid version, unstable/noisy/stuck/saturated sensor, sample-rate mismatch, data errors and MCU timeout all reject before unsafe motion.
- Failed/ascent-insufficient/unphysical fit and repeatability violations never stage a new Z offset, change live offsets, or call `SAVE_CONFIG`.
- No raw contact at arbitrary XY, during axis-twist calibration, without CR Touch/home safety, via legacy path, or during an unqualified nozzle-clean cycle.
- Test that `NEBULAOS_RAW_CONTACT_DIAGNOSTIC` **never** invokes `probing_move`, `manual_move`, raw step commands, `SAVE_CONFIG` or offset application.
- Test data collected across hot/cold and motor-on/off modes; expose useful rejection telemetry rather than a generic error.

### Hardware acceptance matrix

For each reference hardware revision, measure **actual peak force** (not just ADC counts), MCU trigger timing, fitted Z, sensor return-to-baseline, and failure outcome across:

- cold bed/nozzle; warm bed; cooled-after-warm; normal 150 C nozzle contact reference; ordinary heater/fan/stepper state changes;
- repeated real front-left taps, high/low acceptable ADC sensitivity, known wiring/gain faults and intentional sensor disconnects;
- virgin `bltouch.z_offset=0` / previous established value / stale or corrupt reference / power cut during validation;
- false-early-trigger, no-trigger-before-floor, no samples, overflow, sensor reset, clipping, ADC sign inversion and residual compressed-bed start;
- no-motion diagnostics, manually supervised single touch, eventual normal canonical calibration, *separate* later legacy/wipe/full-auto integrations.

**Ship gate:** measured peak force remains within a documented mechanically safe envelope in all **qualified** scenarios; bad sensors and out-of-envelope cases are rejected without dangerous motion. No invented numerical acceptance bound; derive it with hardware measurements and documented owners.

## 8. Specific hazards and review findings

1. `is_calibrated=False` must remain true when no known-force calibration was done. Design a distinct `contact_ready` API instead of faking state.
2. `LoadCellSampleCollector` continues to supply raw values when grams is `None`. `_fit_contact_z` must select sample column 2 and update *both* fit and peak stats.
3. Existing per-contact tare is insufficient as the only safety baseline. Prevent runaway accumulation: anchor MCU raw safety to a separately verified unloaded reference.
4. The historical PRTouch raw signal magnitudes cannot be used as production trigger thresholds: different firmware/filtering, static loads of unknown force, different sensor units, and sample vs aggregate differences.
5. `LCBestFit` alone does not prove a valid touch: low threshold may yield noise-only fit, insufficient below-contact samples, or late high-force contact. Apply raw signal, slope, delta and repeatability gates; never increase threshold automatically after a failed touch unless a separately reviewed qualified procedure allows it.
6. There is **no motor-current force measurement** in this architecture. Z travel/reaction-time mathematics helps constrain risk but does not calibrate physical force.
7. `NebulaOS-firmware/docs/NEBULAOS_CALIBRATION_CONFIG_OWNERSHIP.md` documents `SAVE_CONFIG` conflicts from literal values in included image-owned config. Persist mutable reference/profile state correctly and test this path.
8. Qualifying raw contact at the fixed front-left gauge point does not qualify a bed-wide scan, axis-twist load-cell measurement, or wiping pad.
9. Review the 2026-08-31 real hardware safety incident linked in the header of `extras/nebulaos_calibration.py`; do not generalize geometry or ignore the existing blocked axis-twist decision.
10. Platform's current compatibility manifest uses symbol checks and independent updates, not a global upstream commit gate; validate and document any new imports/API expectations.

## 9. Required code-agent deliverables

- A **risk-neutral PR A** with no-motion diagnostics, offline replay tests and a short analysis of real traces.
- A separate **PR B** implementing raw-mode branches but refusing to move without a qualified hardware profile.
- All added tests, including complete default-mode regressions, config smoke tests against the actual composed pinned Klipper, and meaningful error/status messages.
- A hardware qualification plan/report that lists the precise measured-force evidence required to choose numeric thresholds and enable motion.
- A dependency/API compatibility note stating exactly which upstream symbols are used and how the current firmware+extensions pins are validated.
- Explicitly state what cannot be decided from repository inspection: safe count threshold, worst-case sensor sensitivity, peak overshoot force, behavior on virgin/unusual bed assemblies, and whether a no-weight per-unit health test can reliably reject poorly coupled sensors.

## 10. Primary source URLs

- Extensions HEAD at investigation: https://github.com/coreflake1/NebulaOS-klipper-extensions/tree/8f86925087bae8e3025be4553a6bb161618bb22a
- Firmware: https://github.com/coreflake1/NebulaOS-firmware
- Pinned upstream `load_cell.py`: https://github.com/Klipper3d/klipper/blob/58bd67db3ce1be1951c3e4a6d1156a79903d4edc/klippy/extras/load_cell.py
- Pinned upstream `load_cell_probe.py`: https://github.com/Klipper3d/klipper/blob/58bd67db3ce1be1951c3e4a6d1156a79903d4edc/klippy/extras/load_cell_probe.py
- Pinned upstream `trigger_analog.py`: https://github.com/Klipper3d/klipper/blob/58bd67db3ce1be1951c3e4a6d1156a79903d4edc/klippy/extras/trigger_analog.py
- Klipper upstream documentation (load cells): https://www.klipper3d.org/Load_Cell.html

**Bottom line:** The signal processing and MCU trigger are feasible on the KE without grams. The unknown physical force transfer function is a real limitation, so implementation should be split from *safety qualification*. A model-qualified, weight-free customer experience is plausible; an unrestricted auto-threshold derived only from idle noise is not a justified safe replacement for reference-force calibration.
