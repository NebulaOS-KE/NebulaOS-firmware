"""MCU candidate restoration - the ONLY module in this lifecycle package
that erases/writes the MCU, and only when mcu_lifecycle.decide() has
already returned RESTORE_AUTHORIZED (exact known-stock application identity
- see mcu_lifecycle.py's module docstring for why the hardware-identity
check now happens in HERE, after bootloader entry, rather than before
authorization).

Artifact provenance (wired into the build as of the Phase 1.8B integration
candidate - scripts/build/overlay/opt/nebulaos/mcu-candidates/candidate-001.bin,
copied byte-for-byte from the already-validated NebulaOS-klipper-mcu build
output, SHA256-verified identical at overlay-copy time and re-verified at
build-verify time in 06-verify.sh):
  - Source of truth for the candidate binary and its hash: NebulaOS-klipper-mcu
    (build-time provenance in phase1.8-candidate-001.txt: MCU_REPO_COMMIT
    3aefd286..., built via that repo's GitHub Actions pipeline; the identical
    file also ships as candidate-001.provenance.json alongside the binary in
    this repo's overlay). This module does not build or fetch the artifact
    itself - it only validates and flashes whatever the OS image's build
    process already packaged.
  - On-device install path: /opt/nebulaos/mcu-candidates/<name>.bin plus a
    co-located provenance JSON - see 02-configure-buildroot.sh's overlay copy
    step, which places overlay/ verbatim into the built rootfs. The
    arm-none-eabi-readelf-dependent ELF/target validation
    (creality_validator.py's validate_target()) already ran once, in
    NebulaOS-klipper-mcu's own CI - that binutils dependency is exactly why
    stage4_first_flash.py needed --skip-validator on-device; doing that
    validation once at build time, not on every boot, is what removes the
    on-device toolchain dependency entirely.
  - Runtime validation split:
      BUILD TIME (already done, once, in NebulaOS-klipper-mcu's CI):
        - creality_validator.validate_format() / validate_target()
          (ELF section placement, .config sanity, GD32F303-specific checks)
        - exact hash computed and pinned into mcu_known_identities.py
      RUNTIME (this module, every restore attempt):
        - SHA256 verification of the on-device artifact against the pinned
          hash (cheap, no toolchain needed) - BEFORE any bootloader-entry
          attempt (see "two-stage authorization" below).
        - bootloader entry, then hardware identity allow-list check.
        - flash-result verification (creality_flash.flash_image()'s own
          status-byte checking)
        - post-flash APPLICATION identity verification (re-run the pre-Klippy
          identify handshake and confirm it now reports exactly
          NATIVE_CANDIDATE_001_VERSION - not just "flash reported success")

BOOTLOADER ENTRY (Phase 1.8B Option C, 2026-08-28): candidate-001's hardware
qualification found that creality_flash.py's serial magic-sequence bootloader
entry (enter_bootloader()) does not work against genuinely stock Creality
firmware - confirmed live (five attempts all returned baud-misaligned
garbage) and already documented in stage4_first_flash.py's own docstring
from Phase 1.7 ("the stock firmware's bootloader_request() lacks the 12KB
bootloader branch"). The proven-working alternative for this exact
transition is what stage4_first_flash.py used: trigger the same generic MCU
restart Klipper's own FIRMWARE_RESTART sends (mcu_restart.py, "reset" or
"config_reset", looked up from the MCU's real command dictionary - see that
module's docstring for the full upstream trace), then retry a bootloader
handshake. mcu_restart.py replicates that operation directly via
serialhdl/msgproto/reactor, without needing Klippy or Moonraker running -
compatible with this guard's pre-Klippy execution model, which
stage4_first_flash.py's Moonraker-dependent approach was not.

TWO-STAGE AUTHORIZATION:
  Stage 1 (software gate, in mcu_lifecycle.decide()): the running
    application's identity must be an EXACT match for a known-stock version
    - this alone authorizes calling restore(), before anything hardware-
    level is touched.
  Stage 2 (hardware gate, in THIS module, restore()): the candidate artifact
    must hash-match BEFORE any restart/bootloader-entry is attempted ("bad
    candidate hash -> no reset, no flash" - see _validate_candidate() below),
    and after bootloader entry, the live hardware ID must match the
    supported allow-list BEFORE any erase/write is attempted. Only when both
    stages pass does an actual flash happen.

SAFETY CONTRACT:
  - Never called except when mcu_lifecycle.decide() returned RESTORE_AUTHORIZED.
  - Refuses to proceed - no restart request, no bootloader entry attempt at
    all - on any candidate hash mismatch or missing artifact.
  - Only ever requests a restart via mcu_restart.py's real command-dictionary
    lookup ("reset"/"config_reset") - never an invented/hardcoded packet. If
    the MCU's dictionary exposes neither, or the resulting handshake never
    succeeds, this falls back once to creality_flash.py's existing magic-
    sequence enter_bootloader() before giving up - still exactly one bounded
    restore() call, still zero new protocol implementations.
  - Verifies live hardware ID against the allow-list AFTER bootloader entry
    and BEFORE any erase/write - a hardware mismatch here means FLASH_FAILED,
    never a flash attempt.
  - Bounded: exactly one flash attempt per restore() call, no internal retry
    loop, no infinite retry. The caller (the init.d service) may choose to
    retry on a subsequent boot, but this module never loops on its own.
"""

import hashlib
import os
import time

import mcu_application_identify as app_identify
import mcu_known_identities as known
import mcu_restart

CANDIDATE_PATH = os.environ.get(
    "MCU_CANDIDATE_PATH", "/opt/nebulaos/mcu-candidates/candidate-001.bin")
MCU_SERIAL_PORT = os.environ.get("MCU_SERIAL_PORT", "/dev/ttyS1")
MCU_APP_BAUD = int(os.environ.get("MCU_APP_BAUD", "230400"))
MCU_BOOTLOADER_BAUD = int(os.environ.get("MCU_BOOTLOADER_BAUD", "115200"))

# How long to let the MCU actually reboot before the first handshake
# attempt, and how many/how-spaced the handshake retries are. Mirrors
# stage4_first_flash.py's enter_bootloader_via_firmware_restart() (0.5s
# post-restart settle there was implicit in its own kill_klipper_process()
# sequencing; here there is no Klippy to kill, so the settle delay is
# explicit) - same total bound (~5s), same retry cadence.
POST_RESTART_SETTLE_S = 0.5
BOOTLOADER_HANDSHAKE_ATTEMPTS = 10
BOOTLOADER_HANDSHAKE_RETRY_DELAY_S = 0.5

CANDIDATE_ARTIFACT_MISSING = "CANDIDATE_ARTIFACT_MISSING"
CANDIDATE_HASH_BAD = "CANDIDATE_HASH_BAD"
FLASH_FAILED = "FLASH_FAILED"
RESTORED_AND_VERIFIED = "RESTORED_AND_VERIFIED"


class RestoreResult:
    def __init__(self, state, detail=""):
        self.state = state
        self.detail = detail

    def as_dict(self):
        return {"MCU_RESTORE_RESULT": self.state, "MCU_RESTORE_DETAIL": self.detail}


def _sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def _validate_candidate(candidate_path, expected_sha256, exists_fn, sha_fn):
    """Stage 2's first check: the candidate artifact must exist and hash-
    match BEFORE anything hardware-level is attempted. Returns a
    RestoreResult on failure, or None if the candidate is valid."""
    if not exists_fn(candidate_path):
        return RestoreResult(
            CANDIDATE_ARTIFACT_MISSING, f"not_found: {candidate_path}")
    actual_hash = sha_fn(candidate_path)
    if actual_hash != expected_sha256:
        return RestoreResult(
            CANDIDATE_HASH_BAD,
            f"expected={expected_sha256} actual={actual_hash}")
    return None


def _close_quietly(transport):
    """Close a bootloader transport, never raising. Run 23 (ke-dev,
    2026-11-05): restore() kept the bootloader transport open while the
    post-flash identify ran; that identify refuses a port any process holds
    (find_process_holding_port, our own pid included), so every successful
    flash was reported as FLASH_FAILED (post_flash_identify_failed)."""
    if transport is None:
        return
    try:
        transport.close()
    except Exception:
        pass


def _enter_bootloader_via_restart_command(
        port, app_baud, transport_factory, restart_fn, creality_flash_module,
        sleep_fn=time.sleep, attempts=BOOTLOADER_HANDSHAKE_ATTEMPTS,
        retry_delay=BOOTLOADER_HANDSHAKE_RETRY_DELAY_S,
        settle_delay=POST_RESTART_SETTLE_S):
    """Phase 1.8B Option C entry path. Sends Klipper's own generic restart
    command (mcu_restart.request_generic_restart), then retries a bootloader
    handshake (creality_flash.handshake(), via transport_factory - the same
    bootloader-level primitive stage4_first_flash.py's own retry loop uses).
    creality_flash_module.handshake() is the only creality_flash call here -
    deliberately not identify()/enter_bootloader(), which would attempt their
    own redundant magic-sequence entry on top of the restart this function
    already performed.

    Returns (transport, detail_str) on success. Raises whatever restart_fn
    itself raises (mcu_restart.RestartRequestError/RestartRequestRefused) if
    the restart could not even be requested, or RuntimeError if the
    bootloader never became reachable afterward - the caller is expected to
    fall back to the existing magic-sequence method in either case, not
    retry this path again. A transport-construction or handshake-write
    failure on a given attempt (e.g. a transient serial error) counts as
    that attempt failing, not as a fatal error - only exhausting all
    `attempts` raises."""
    restart_detail = restart_fn(port, app_baud)  # may raise; caller handles
    sleep_fn(settle_delay)
    last_error = None
    for _ in range(attempts):
        transport = None
        try:
            transport = transport_factory()
            if creality_flash_module.handshake(transport):
                return transport, f"restart_command={restart_detail}"
            last_error = "handshake_not_acknowledged"
        except creality_flash_module.FlashError as e:
            last_error = f"handshake_error: {e}"
        except Exception as e:
            last_error = f"transport_error: {e}"
        _close_quietly(transport)
        sleep_fn(retry_delay)
    raise RuntimeError(
        f"bootloader_unreachable_after_restart_command "
        f"(restart_command={restart_detail}, last_error={last_error})")


def restore(creality_flash_module=None, transport_factory=None,
            application_identify_fn=None, restart_fn=None,
            candidate_path=None, expected_sha256=None, port=None, baud=None,
            bootloader_baud=None, file_exists_fn=None, hash_fn=None,
            read_bytes_fn=None, sleep_fn=None):
    """Perform exactly one bounded restore attempt. All hardware/filesystem
    interaction points are injectable for testing with mocks."""
    candidate_path = candidate_path or CANDIDATE_PATH
    expected_sha256 = expected_sha256 or known.NATIVE_CANDIDATE_001_SHA256
    port = port or MCU_SERIAL_PORT
    baud = baud or MCU_APP_BAUD
    bootloader_baud = bootloader_baud or MCU_BOOTLOADER_BAUD
    exists_fn = file_exists_fn or os.path.isfile
    sha_fn = hash_fn or _sha256_file
    read_bytes = read_bytes_fn or _read_bytes
    identify_fn = application_identify_fn or app_identify.get_application_identity
    restart_request_fn = restart_fn or mcu_restart.request_generic_restart
    sleep = sleep_fn or time.sleep

    # Stage 2, part 1: candidate must be valid BEFORE any restart/bootloader
    # attempt - "bad candidate hash -> no reset, no flash". Wrapped broadly
    # for the same reason as the bootloader-entry step below: an unexpected
    # exception from exists_fn/sha_fn (e.g. a permissions error reading the
    # candidate file) must become a returned FLASH_FAILED, never escape
    # restore() uncaught.
    try:
        bad_candidate = _validate_candidate(
            candidate_path, expected_sha256, exists_fn, sha_fn)
    except Exception as e:
        return RestoreResult(FLASH_FAILED, f"candidate_validation_error: {e}")
    if bad_candidate is not None:
        return bad_candidate

    if creality_flash_module is None or transport_factory is None:
        import sys as _sys
        _sys.path.insert(0, os.environ.get("CREALITY_FLASH_PATH", "/opt/nebulaos/tools"))
        import creality_flash as creality_flash_module  # noqa: F811

        def transport_factory():
            return creality_flash_module.SerialTransport(
                port, baud=bootloader_baud, timeout=2.0)

    entry_detail = "unknown"
    transport = None
    try:
        transport, entry_detail = _enter_bootloader_via_restart_command(
            port, baud, transport_factory, restart_request_fn,
            creality_flash_module, sleep_fn=sleep)
    except Exception as e:
        # Deliberately broad: restore() must always return a RestoreResult,
        # never raise - an unhandled exception here must not be able to
        # silently pick the safety outcome by crashing this function instead
        # of returning FLASH_FAILED (the caller, mcu_identity_check.py, has
        # no way to distinguish "restore() correctly determined failure"
        # from "restore() itself crashed" if this propagated out). Expected
        # cases are mcu_restart.RestartRequestError/RestartRequestRefused
        # (restart could not even be requested) and RuntimeError (bootloader
        # never became reachable) - any other exception type here is itself
        # a bug, but even then, falling back rather than crashing is the
        # safe choice. Fall back once to the existing magic-sequence method
        # - still exactly one bounded restore() call, still zero new
        # protocol implementations (creality_flash.identify() already
        # exists and is unmodified). This covers a device already running
        # native firmware that somehow reports KNOWN_STOCK (should not
        # normally happen, decide() already gated on application identity)
        # and any future MCU revision whose dictionary genuinely lacks
        # reset/config_reset.
        try:
            transport = transport_factory()
            version_string = creality_flash_module.identify(transport)
            entry_detail = (
                f"restart_command_path_failed ({e}); "
                f"fallback_magic_sequence_succeeded (hw={version_string})")
        except Exception as fallback_e:
            return RestoreResult(
                FLASH_FAILED,
                f"could_not_enter_bootloader: restart_command_path=({e}) "
                f"magic_sequence_fallback=({fallback_e})")

    try:
        # Stage 2, part 2: hardware identity must match the allow-list BEFORE
        # any erase/write - "unsupported HW -> never flash". Uses
        # creality_flash's low-level get_version()/check_identity() directly
        # (not the identify()/flash() wrappers, which would attempt their own
        # redundant magic-sequence bootloader entry - we are already in the
        # bootloader from the step above).
        try:
            version_string = creality_flash_module.get_version(transport)
        except creality_flash_module.FlashError as e:
            return RestoreResult(FLASH_FAILED, f"hw_id_query_failed: {e}")
        if not creality_flash_module.check_identity(version_string):
            return RestoreResult(
                FLASH_FAILED,
                f"hardware_identity_mismatch: got={version_string!r} "
                f"allowed={creality_flash_module.DEFAULT_ALLOWED_HW_IDS!r}")

        try:
            sector_size = creality_flash_module.get_sector_size(transport)
            image = read_bytes(candidate_path)
            if not creality_flash_module.flash_image(transport, image, sector_size):
                return RestoreResult(
                    FLASH_FAILED, "flash transfer did not report completion")
            if not creality_flash_module.app_start(transport):
                return RestoreResult(
                    FLASH_FAILED, "application failed to start after flash")
        except creality_flash_module.FlashError as e:
            return RestoreResult(FLASH_FAILED, f"flash_error: {e}")
        except Exception as e:
            return RestoreResult(FLASH_FAILED, f"unexpected_error: {e}")
    finally:
        # The port must be free before the post-flash identify below opens
        # it again (it refuses a port that is still held, by anyone).
        _close_quietly(transport)

    # Post-flash verification: the flash reporting success is not sufficient
    # proof - confirm the application identity now actually matches
    # candidate-001, via the same pre-Klippy identify handshake used for the
    # original decision.
    try:
        version, _build_versions = identify_fn(port, baud)
    except Exception as e:
        return RestoreResult(
            FLASH_FAILED, f"post_flash_identify_failed: {e}")

    if known.classify_application_identity(version) != known.NATIVE_CANDIDATE_001:
        return RestoreResult(
            FLASH_FAILED,
            f"post_flash_identity_mismatch: got={version!r} "
            f"expected={known.NATIVE_CANDIDATE_001_VERSION!r}")

    return RestoreResult(
        RESTORED_AND_VERIFIED,
        f"application_identity={version}; bootloader_entry=({entry_detail})")
