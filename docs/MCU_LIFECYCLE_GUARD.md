# MCU Lifecycle Guard

Phase 1.8B Workstream B: boot-time MCU identity verification (and, as of
this offline pre-build review, bounded automatic restoration) for the
GD32F303RET6 on Creality Ender-3 V3 KE.

**Revision note (offline pre-build review, same Phase 1.8B):** this
document originally described a bootloader-hardware-ID-only identity check,
with automatic flash restoration deferred to a future phase pending
hardware qualification. An offline review found that design conflated two
distinct identities: the bootloader hardware ID has been observed identical
whether candidate-001 or stock Creality firmware is installed (compare
`_evidence/phase1.8-candidate/identity-query-result.txt`, taken with
candidate-001 flashed, against `_evidence/phase1.8-candidate/phase1.8-os-candidate-004.txt`,
taken moments after the stock slot had just auto-flashed stock firmware back
on - both report `mcu0_001_G32`). A bootloader-only PASS could never
actually prove candidate-001 was running. This document now describes the
corrected design: two separately-checked identities, and restoration
implemented (behind mocks, never run against real hardware in this review)
rather than left deferred.

**Revision note (candidate-002 MCU fix, 2026-08-28):** candidate-001's live
hardware qualification found three real bugs, none of which the mocked test
suite above could catch (see
`_project/missions/phase1.8b-candidate-001-hardware-qualification-summary.md`
for the full incident): `creality_flash.py`/`creality_validator.py` were
never actually deployed to `/opt/nebulaos/tools/`; `mcu_application_identify.py`
called `reactor.pause()` before ever calling `reactor.run()`, which silently
never dispatches (always timed out, regardless of MCU state); and, most
significantly, `_check_hardware_identity()`'s serial magic-sequence
bootloader entry (`creality_flash.enter_bootloader()`) does not work against
genuinely stock Creality firmware at all - confirmed live. This document is
updated for the fix to all three - see "Bootloader entry mechanism (Option
C)" below for the architectural change, and `mcu_restart.py`'s own module
docstring for the full upstream trace proving the replacement mechanism.

## Problem

Booting the stock Creality OS slot automatically overwrites the MCU with
old firmware. NebulaOS needs a boot-time guard that verifies MCU identity
BEFORE Klipper starts, so that:

- A correct native MCU application is confirmed and Klipper starts normally.
- A stock-clobbered MCU is detected and, only in that specific case,
  restoration is authorized.
- A hardware mismatch or unresponsive MCU is caught before Klipper
  attempts communication with a misconfigured or absent MCU.
- An application that's neither the known candidate nor known stock is
  never auto-flashed, on the assumption that guessing wrong is worse than
  asking a human.

## Two identities, checked separately

- **APPLICATION identity** (`mcu_application_identify.py`): which firmware
  is currently running. Read via Klipper's own MCU IDENTIFY protocol - the
  exact same handshake Klipper performs on every normal connect - without
  starting full Klippy (no Printer, no config, no toolhead). This follows
  the pattern already shipped in upstream Klipper's own `scripts/dump_mcu.py`
  (present in `58bd67db3ce1be1951c3e4a6d1156a79903d4edc`, the exact commit
  candidate-001 is built from): a bare `reactor.Reactor()` +
  `serialhdl.SerialReader()`, `connect_uart()`, then
  `get_msgparser().get_version_info()`. This is non-invasive - it doesn't
  require entering the bootloader, so a healthy native-app connection is
  never disturbed.
- **HARDWARE identity** (`creality_flash.py`'s bootloader protocol): is this
  a supported physical KE MCU. Requires deliberately entering the
  bootloader. As of candidate-002 (2026-08-28), this check's ROLE differs by
  application class:
  - **Known stock**: `mcu_lifecycle.decide()` no longer performs this check
    at all before authorizing - see "Bootloader entry mechanism (Option C)"
    below. The hardware check happens inside `mcu_restore.restore()`
    itself, after bootloader entry via the new mechanism, immediately
    before any erase/write.
  - **Unknown/unreadable application**: `mcu_lifecycle.py`'s
    `_check_hardware_identity()` (the original magic-sequence method) is
    still used here, unchanged, purely for diagnostic context - neither of
    these paths ever authorizes a flash, so the magic-sequence method
    (proven NOT to work for a first stock-to-native transition, but not
    otherwise known to be broken) remains an acceptable best-effort probe.

`mcu_known_identities.py` holds the exact, non-invented values already on
file in this repo's own build evidence:
- `NATIVE_CANDIDATE_001_VERSION = "v0.13.0-742-g01a9c2f92"` - from
  `_evidence/phase1.8-candidate/klipper.dict`'s own `version` field.
- `KNOWN_STOCK_VERSIONS = ("38d96adc-dirty-20231016_135251-longer-virtual-machine",)`
  - observed identically on 2026-08-22 and 2026-08-28. This is a
  single-sample observation of one hardware unit's one firmware build, not
  a verified family/pattern - only an exact match authorizes a restore.

## State matrix

| State | Meaning | Action |
|---|---|---|
| `SUPPORTED_HW_NATIVE_APP` | Application identity exactly matches candidate-001 | `ALLOW_KLIPPER_START` - no flash, bootloader never entered |
| `SUPPORTED_HW_KNOWN_STOCK_APP` | Application identity exactly matches the known stock string (Stage 1, software gate only - see Option C below; hardware is NOT yet checked at this point) | `RESTORE_AUTHORIZED` - the only state that may flash. `restore()` itself performs Stage 2 (candidate hash, then bootloader entry, then hardware-ID check) before any erase/write. |
| `SUPPORTED_HW_UNKNOWN_APP` | Application identity present but unrecognized, OR application identify failed but hardware checks out | `ALLOW_KLIPPER_START_WARN` - never auto-flash, diagnostics preserved |
| `UNSUPPORTED_HW` | Bootloader hw-id reachable but does not match the allow-list | `BLOCK_KLIPPER_START` - never flash, regardless of application class |
| `MCU_UNREACHABLE` | Neither application identify nor the bootloader check could reach the MCU | `ALLOW_KLIPPER_START_WARN` - bounded (one attempt), no stock fallback, let Klipper's own retry logic try |

Design decision worth stating explicitly: `SUPPORTED_HW_UNKNOWN_APP` allows
Klipper to attempt to start rather than blocking outright. Application
identify succeeding via Klipper's real protocol means the MCU is genuinely
running *some* Klipper-compatible firmware, not something alien - Klipper's
own config/pin validation is the second safety net for that case. Blocking
startup entirely would make an unrecognized-but-valid firmware update look
like total device failure. The only thing this state forbids is automatic
restoration.

## Bootloader entry mechanism (Option C, candidate-002, 2026-08-28)

Candidate-001's hardware qualification found that `creality_flash.py`'s
serial magic-sequence bootloader entry (`enter_bootloader()`) does not work
against genuinely stock Creality firmware - confirmed live (five attempts
all returned baud-misaligned garbage, not a bootloader response), and
already documented in `NebulaOS-klipper-mcu/tools/stage4_first_flash.py`'s
own docstring from Phase 1.7 ("the stock firmware's `bootloader_request()`
lacks the 12KB bootloader branch"). The magic sequence is a feature the
NebulaOS candidate patch itself adds to the *application* firmware
(recognizing the byte pattern and voluntarily jumping to the bootloader) -
it was never present in Creality's own, separately-compiled stock
application, so it can never work for the very first stock-to-native
transition.

Three architectural options were considered (see
`_project/missions/phase1.8b-candidate-001-hardware-qualification-summary.md`
§3 for the original framing):
- (a) detect this case and defer to a documented manual operator step
- (b) move the restore decision to run after Klipper starts, so it can use
  Moonraker's `FIRMWARE_RESTART`
- (c) replicate exactly what Klipper's own `FIRMWARE_RESTART` sends,
  directly, pre-Klippy, without needing Klipper or Moonraker running

**Option (c) was chosen and implemented as `mcu_restart.py`.** Traced from
upstream Klipper `58bd67db3ce1be1951c3e4a6d1156a79903d4edc`'s
`klippy/mcu.py`: when `restart_method: command` (this project's own
configured value - see `machine.cfg`'s `[mcu]` section), a `FIRMWARE_RESTART`
looks up `"reset"`, falling back to `"config_reset"`, in the MCU's own real
command dictionary (`msgparser.lookup_command()` - never raises out, a
missing command is simply not found) and sends whichever exists via a
fire-and-forget `raw_send()` - no ACK is expected, since the MCU reboots
before it could reply. Both are standard, zero-argument, generic Klipper
commands (`src/generic/armcm_reset.c`'s `command_reset` /
`src/linux/main.c`'s `command_config_reset`), not anything specific to this
project's own patches.

`mcu_restart.request_generic_restart()` replicates exactly this operation
using the same pre-Klippy `reactor`/`serialhdl` machinery
`mcu_application_identify.py` already uses (via a shared `run_connected()`
helper) - no Moonraker, no Klippy, no invented/hardcoded packet. **Empirical
evidence this works against genuinely stock firmware**: the 2026-08-28
hardware qualification session's `stage4_first_flash.py` run triggered
exactly this operation via Moonraker's `/printer/firmware_restart` (Klippy's
own `FIRMWARE_RESTART` handling) against the printer while it was running
genuinely stock firmware, and the subsequent bootloader handshake succeeded
- see `gate1-manual-remediation-and-restore.txt` in that mission's evidence
directory.

If the MCU's dictionary exposes neither command (`RestartRequestRefused`),
or the resulting handshake never succeeds after bounded retries, `restore()`
falls back once to the original magic-sequence `enter_bootloader()` before
giving up - still exactly one bounded `restore()` call, still zero new
protocol implementations invented.

## Restoration (`mcu_restore.py`)

The only module that erases/writes the MCU, and only when
`mcu_lifecycle.decide()` already returned `RESTORE_AUTHORIZED`.

**Two-stage authorization** (candidate-002): Stage 1 (software gate, in
`mcu_lifecycle.decide()`) is an exact known-stock application identity match
- non-invasive, authorizes calling `restore()` without touching the
bootloader. Stage 2 (hardware gate, entirely inside `restore()`): the
candidate artifact must hash-match BEFORE any restart/bootloader-entry is
attempted ("bad candidate hash -> no reset, no flash"), then bootloader
entry via the mechanism above, then the live hardware ID must match the
allow-list BEFORE any erase/write ("unsupported HW -> never flash," now
enforced here rather than in `decide()`).

- **Artifact provenance**: a NEW proposed convention (no prior on-device
  deployment path existed before this review) - the build pipeline is
  responsible for placing the exact GitHub-Actions-built candidate-001
  binary at `/opt/nebulaos/mcu-candidates/candidate-001.bin` (path
  overridable via `MCU_CANDIDATE_PATH`). Source of truth remains
  `NebulaOS-klipper-mcu` (build-time provenance in
  `_evidence/phase1.8-candidate/phase1.8-candidate-001.txt`).
- **Build-time validation** (already done, once, in `NebulaOS-klipper-mcu`'s
  CI): `creality_validator.py`'s `validate_format()`/`validate_target()`
  (ELF section placement, `.config` sanity, GD32F303-specific checks) -
  this is the step that needs `arm-none-eabi-readelf`, which is why
  `stage4_first_flash.py` needed `--skip-validator` on-device. Doing this
  once at build time, rather than on every boot, removes the on-device
  toolchain dependency entirely.
- **Runtime validation** (`mcu_restore.py`, every restore attempt):
  SHA256 verification against the pinned hash BEFORE any bootloader
  interaction (cheap, no toolchain), bootloader entry via `mcu_restart.py`
  (falling back to the magic-sequence method if refused/unreachable), the
  hardware allow-list checked directly via `creality_flash.get_version()`/
  `check_identity()` immediately after entry and before any erase/write,
  flash-result verification (status-byte checking already in
  `flash_image()`), and **post-flash application identity verification** -
  re-running the identify handshake and confirming it now reports exactly
  `NATIVE_CANDIDATE_001_VERSION`, not merely "flash reported success."
- **Bounded**: exactly one flash attempt per `restore()` call, no internal
  retry loop.

## Architecture

### Boot sequence position

```
S05nebulaos-activate
  |
S40nebulaos-ntpsync
  |
S45nebulaos-cleanup
  |
S50nebulaos-mcu-guard  <-- lifecycle decision (+ restore, if authorized) here
S50webcam
  |
S55klipper             <-- Klipper starts here (only if guard passed)
S56moonraker
  ...
S95mcu-boot-recovery   <-- handles post-Klipper MCU transients
```

S50nebulaos-mcu-guard runs before S55klipper by init.d sort order
(same S50 prefix as S50webcam; alphabetical sort: `nebulaos-mcu-guard`
< `webcam`).

### Components

- **S50nebulaos-mcu-guard** (shell, init.d service): calls
  `mcu_identity_check.py`, parses its `MCU_GUARD_RESULT=PASS|WARN|FAIL`
  line plus the diagnostic fields, writes the state file, exits 0 (allow
  Klipper) or 1 (block Klipper).
- **mcu_identity_check.py**: thin orchestrator. Calls
  `mcu_lifecycle.decide()`; if it returns `RESTORE_AUTHORIZED`, calls
  `mcu_restore.restore()` and folds its result into the final PASS/FAIL.
  Performs no serial/bootloader interaction itself.
- **mcu_lifecycle.py**: the state-machine decision (application identity
  first, bootloader hw-id only when needed).
- **mcu_application_identify.py**: the pre-Klippy Klipper-protocol
  identify handshake.
- **mcu_known_identities.py**: the pinned candidate-001/known-stock
  version strings and classification.
- **mcu_restart.py** (candidate-002): sends Klipper's own generic
  `"reset"`/`"config_reset"` restart command via real `msgproto`/`serialhdl`
  - see "Bootloader entry mechanism (Option C)" above.
- **mcu_restore.py**: the bounded, gated flash-restore path - candidate
  validation, bootloader entry (via `mcu_restart.py`, falling back to the
  magic-sequence method), hardware-ID verification, flash, post-verify.

All hardware/filesystem interaction points in `mcu_lifecycle.py` and
`mcu_restore.py` are injectable (`creality_flash_module`,
`transport_factory`, `application_identify_fn`, `restart_fn`,
`file_exists_fn`, `hash_fn`, `read_bytes_fn`, `sleep_fn`) specifically so
`tests/mcu-lifecycle-decision-tests.py` can exercise every state and
CASE 1-11 from the pre-build review mission with mocks - no real serial
hardware. `tests/mcu-real-reactor-msgproto-tests.py` (candidate-002)
separately exercises real (unmocked) `reactor.py`/`serialhdl.py`/
`msgproto.py` - see "Test coverage" below.

### State file

Written to `/run/nebulaos-mcu-guard.state` (tmpfs, lost on reboot):

```
MCU_GUARD_RESULT=PASS|WARN|FAIL
MCU_IDENTITY=<application identity string>
MCU_GUARD_DETAIL=<human-readable detail>
MCU_GUARD_TIMESTAMP=<ISO 8601 UTC>
MCU_GUARD_EXPECTED=mcu0_001_G32
MCU_LIFECYCLE_STATE=<one of the 5 states above>
MCU_APPLICATION_IDENTITY=<application identify string, or "unknown">
MCU_APPLICATION_CLASS=NATIVE_CANDIDATE_001|KNOWN_STOCK|UNKNOWN_APPLICATION|unknown
MCU_HW_ID_STATUS=MATCH|MISMATCH|UNREACHABLE|not_checked_not_needed
MCU_RESTORE_RESULT=RESTORED_AND_VERIFIED|CANDIDATE_ARTIFACT_MISSING|CANDIDATE_HASH_BAD|FLASH_FAILED|not_attempted
MCU_RESTORE_DETAIL=<why the restore ended as it did, single-quoted; empty when not attempted>
```

After `RESTORED_AND_VERIFIED` the identity, class and lifecycle fields describe the board as it
is now (native); `MCU_LIFECYCLE_DETAIL` names the stock firmware it replaced (Run 23). On
`FLASH_FAILED` the guard leaves the power-cycle notice unless the reason is one a power cycle
cannot fix (`hardware_identity_mismatch`, `candidate_validation_error`).

## Hardware configuration

| Parameter | Value |
|-----------|-------|
| MCU | GD32F303RET6 |
| Serial port | /dev/ttyS1 |
| Application baud | 230400 |
| Bootloader baud | 115200 |
| Expected hardware ID | mcu0_001_G32 |
| Candidate-001 application identity | v0.13.0-742-g01a9c2f92 |
| Candidate-001 SHA256 | c2db4f34586c5df88b0d8d40e1d2d1c0f3bea90ab879c7c3a1ccc3a64f91db0c |
| Known stock application identity | 38d96adc-dirty-20231016_135251-longer-virtual-machine |
| On-device candidate path | /opt/nebulaos/mcu-candidates/candidate-001.bin (wired into the build overlay as of the Phase 1.8B integration candidate; SHA256-verified at 06-verify.sh time) |

## Test coverage

- `tests/mcu-guard-tests.sh`: structural/plumbing checks (file existence,
  init.d ordering, no flash/erase strings in the wrong places, state file
  location, mocked shell-level PASS/WARN/FAIL dispatch).
- `tests/mcu-lifecycle-decision-tests.py`: real behavioral tests against
  `mcu_lifecycle.decide()`/`mcu_restore.restore()` with mocked
  application-identify and creality_flash collaborators - covers CASE 1-11
  from the pre-build review mission, including two explicit regression
  tests for the original hardware-ID/application-ID conflation bug, plus
  (candidate-002) explicit coverage of the restart-command mechanism: used
  when it succeeds, falls back to the magic-sequence method when refused,
  fails closed when both fail, never flashes on a post-entry hardware
  mismatch, and never lets an unexpected exception from an injected
  `restart_fn` escape `restore()` uncaught. Also includes
  `RealCrealityFlashImportTests`, which calls `decide()` completely
  unmocked to prove the real `creality_flash` import path resolves.
- `tests/mcu-real-reactor-msgproto-tests.py` (candidate-002): uses Klipper's
  own real `reactor.py`/`serialhdl.py`/`msgproto.py` - no mocks of
  Klipper's own code. Directly proves (a) the exact reactor dispatch bug
  class is fixed, by demonstrating the OLD pattern (register + bare
  top-level `pause()`) never dispatches while the NEW pattern (nested
  inside a `run()`-dispatched callback) does; (b) `mcu_restart.py`'s
  `"reset"` command lookup/encoding against this project's own real,
  vendored candidate-001 dictionary (`tests/fixtures/candidate-001.klipper.dict`);
  and (c) `run_connected()` fails within a bounded time against a
  nonexistent serial port, using the real `connect_uart()` call path. A
  full pty-based simulation of the wire-level IDENTIFY handshake itself was
  considered and deliberately not attempted - see that test file's own
  module docstring for the scoping rationale.

## Hardware test plan (still required before real deployment)

**Status update (candidate-002, 2026-08-28)**: items 1, 2, 4, and 5 below
were exercised live during candidate-001's hardware qualification (fixing
the two bugs this document's candidate-002 revision addresses along the
way) - see `_evidence/qualification-logs/phase1.8b-candidate-001-2026-08-28/`.
Item 3, the restore path, was NOT exercised via the guard's own
`mcu_restore.restore()` at all in that session - the actual MCU restore was
performed using `NebulaOS-klipper-mcu/tools/stage4_first_flash.py` directly,
manually, bypassing this module's decision logic entirely (because at the
time, the bootloader-entry mechanism this document now describes as Option
C did not exist yet - it is candidate-002's own fix). **The new
`mcu_restart.py`-based restore path in this revision has only been
exercised against mocks (`tests/mcu-lifecycle-decision-tests.py`) and real-
but-hardware-less Klipper modules (`tests/mcu-real-reactor-msgproto-tests.py`)
- it has never been run against the real GD32F303 MCU.** A real build,
reflash, and a genuine known-stock-to-native restore attempt through the
actual `S50nebulaos-mcu-guard` -> `mcu_identity_check.py` ->
`mcu_lifecycle.decide()` -> `mcu_restore.restore()` chain (not a manual
`stage4_first_flash.py` invocation) is still required before this can be
called hardware-qualified.

1. **Cold boot identity check**: DONE (candidate-001 qualification, once
   the reactor bug fixed in this revision is included in a real build) -
   `mcu_application_identify.py`'s pre-Klippy handshake was confirmed live
   against the real MCU.
2. **Timing validation**: measure guard-start to Klipper-start time with
   the new two-stage (application-first, bootloader-conditional) design,
   including the new restart-command settle/retry delays
   (`mcu_restore.py`'s `POST_RESTART_SETTLE_S`/`BOOTLOADER_HANDSHAKE_*`
   constants) on a real boot.
3. **Restore path via the actual guard, once authorized on purpose**: verify
   `mcu_restore.restore()` itself - not a manual bypass tool - actually
   enters the bootloader via `mcu_restart.py`, flashes, and post-verifies
   correctly from a real init.d context (serial timing, no competing
   serial users, S55klipper not yet started). **Not yet done** - this is
   the single most important remaining hardware test for candidate-002.
4. **Artifact deployment**: DONE -
   `/opt/nebulaos/mcu-candidates/candidate-001.bin` is wired into the build
   overlay and was confirmed present/correct on the real device during
   candidate-001's qualification.
5. **Failure modes**: DONE (candidate-001 qualification exercised
   `MCU_UNREACHABLE`-adjacent conditions) - still worth re-confirming after
   a real build of this revision: disconnect the MCU serial cable and boot;
   verify `MCU_UNREACHABLE` is reported and Klipper is still allowed to
   attempt its own connection.

## Safety rules

1. No erase/write occurs anywhere except inside `mcu_restore.restore()`,
   and only when `mcu_lifecycle.decide()` returned `RESTORE_AUTHORIZED`.
2. The service NEVER writes to `/dev/mmcblk0p1` or any block device.
3. Every bootloader interaction always calls `app_start()` before the
   guard process exits.
4. `UNSUPPORTED_HW` and `SUPPORTED_HW_UNKNOWN_APP` never authorize a flash,
   regardless of what the other identity looked like.
5. `mcu_restore.restore()` makes exactly one bounded attempt per call - no
   internal retry loop, no infinite retry.
6. A Klipper-only runtime failure (after S50 has already run and Klipper
   has already started) has no code path back into this guard or into
   `mcu_restore.py` - restoration is decided once, at boot, before
   S55klipper, never re-triggered by a later application-level failure.
7. (candidate-002) `mcu_restart.py` only ever sends `"reset"` or
   `"config_reset"` - both looked up from the MCU's own real command
   dictionary at connect time via `msgparser.lookup_command()` - never a
   hardcoded/invented raw byte sequence. If neither exists in the
   dictionary, it raises `RestartRequestRefused` and sends nothing; it
   never attempts an alternate/invented command.
8. (candidate-002) `mcu_restore.restore()` never raises - any unexpected
   exception from the bootloader-entry step (including from an injected
   `restart_fn`, or a bug in it) is caught and converted into a
   `RestoreResult(FLASH_FAILED, ...)` via the magic-sequence fallback path,
   so an unhandled exception can never silently choose the safety outcome
   by crashing this function instead of returning a result the caller can
   act on.
9. S50 releases `/dev/ttyS1` before S55 starts by construction, not by
   explicit `close()` calls: `do_check()`'s python3 invocation is a
   synchronous command substitution (never backgrounded), so init cannot
   proceed to S55 until that process has fully exited - at which point the
   kernel has already closed every file descriptor it held, regardless of
   what the Python code itself did.
