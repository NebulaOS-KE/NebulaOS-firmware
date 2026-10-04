"""MCU lifecycle state-machine orchestrator.

Corrects a conflation in the original Phase 1.8B guard design: that design's
PASS result meant only "the bootloader responded with hardware ID
mcu0_001_G32" - a HARDWARE presence check - and never actually consulted
which APPLICATION firmware is running. The bootloader hardware ID has been
observed identical whether candidate-001 or stock Creality firmware is
installed (compare the 2026-08-22 identity-query-result.txt, taken with
candidate-001 flashed, against the 2026-08-24 candidate-004 evidence, taken
moments after the stock slot had just auto-flashed stock firmware back on -
both report mcu0_001_G32), so a bootloader-only check can never distinguish
"candidate-001 is running" from "stock just clobbered the MCU."

This module separates the two identities explicitly:
  - APPLICATION identity: mcu_application_identify.py, a pre-Klippy read of
    Klipper's own IDENTIFY dictionary `version` field. Tells you which
    firmware is running. Does not require entering the bootloader.
  - HARDWARE identity: creality_flash.py's bootloader protocol. Tells you
    whether this is a supported physical KE MCU. Requires deliberately
    entering the bootloader (disrupts any live application connection),
    so it is only invoked when application identity alone can't produce a
    safe decision (known-stock, needing a restore-safety gate; or the
    application handshake itself failed).

Ordering rationale: application identify is tried FIRST and is non-invasive
(it's the same handshake Klipper does normally, on whatever mode the MCU is
already booted into). The bootloader check is only performed when actually
needed, so a healthy NATIVE_CANDIDATE_001 boot never has its running
connection disturbed by a bootloader-entry attempt it doesn't need.

TWO-STAGE AUTHORIZATION (Phase 1.8B Option C, 2026-08-28): candidate-001's
hardware qualification found that this module's OLD hardware-identity check
(_check_hardware_identity(), via creality_flash.py's serial magic-sequence
enter_bootloader()) does not work against genuinely stock Creality firmware
- see mcu_restore.py's module docstring for the full trace and the proven-
working replacement (mcu_restart.py's Klipper-own-command restart, used
inside restore() itself, after this module authorizes the attempt).

This means an EXACT known-stock application identity now authorizes
RESTORE_AUTHORIZED directly - this is Stage 1, the software gate, and it is
non-invasive (no bootloader entry, no MCU disruption). Stage 2, the hardware
gate (candidate hash validation, then bootloader entry via the new
mechanism, then live hardware-ID verification), happens entirely inside
mcu_restore.restore() - see that module's docstring. decide() no longer
calls _check_hardware_identity() for the KNOWN_STOCK case at all.

_check_hardware_identity() (the OLD magic-sequence check) is kept, UNCHANGED,
for exactly one remaining purpose: diagnostic-only hardware identity
context when the application identity itself is unreadable or unrecognized
(MCU_UNREACHABLE / SUPPORTED_HW_UNKNOWN_APP / UNSUPPORTED_HW below) - none of
those paths ever authorize a flash, so using the old bootloader-entry method
there is a diagnostic convenience, not a safety-relevant choice. It is
deliberately NOT invoked for KNOWN_STOCK.
"""

import os

import mcu_application_identify as app_identify
import mcu_known_identities as known

MCU_SERIAL_PORT = os.environ.get("MCU_SERIAL_PORT", "/dev/ttyS1")
MCU_APP_BAUD = int(os.environ.get("MCU_APP_BAUD", "230400"))
MCU_BOOTLOADER_BAUD = int(os.environ.get("MCU_BOOTLOADER_BAUD", "115200"))
MCU_EXPECTED_HW_ID = os.environ.get("MCU_EXPECTED_HW_ID", "mcu0_001_G32")

# States (section 9 of the mission design)
SUPPORTED_HW_NATIVE_APP = "SUPPORTED_HW_NATIVE_APP"
SUPPORTED_HW_KNOWN_STOCK_APP = "SUPPORTED_HW_KNOWN_STOCK_APP"
SUPPORTED_HW_UNKNOWN_APP = "SUPPORTED_HW_UNKNOWN_APP"
UNSUPPORTED_HW = "UNSUPPORTED_HW"
MCU_UNREACHABLE = "MCU_UNREACHABLE"

# Actions
ALLOW_KLIPPER_START = "ALLOW_KLIPPER_START"
ALLOW_KLIPPER_START_WARN = "ALLOW_KLIPPER_START_WARN"
BLOCK_KLIPPER_START = "BLOCK_KLIPPER_START"
RESTORE_AUTHORIZED = "RESTORE_AUTHORIZED"


class LifecycleDecision:
    def __init__(self, state, action, application_identity=None,
                 application_class=None, hw_id=None, hw_id_status=None,
                 detail=""):
        self.state = state
        self.action = action
        self.application_identity = application_identity
        self.application_class = application_class
        self.hw_id = hw_id
        self.hw_id_status = hw_id_status
        self.detail = detail

    def as_dict(self):
        return {
            "MCU_LIFECYCLE_STATE": self.state,
            "MCU_LIFECYCLE_ACTION": self.action,
            "MCU_APPLICATION_IDENTITY": self.application_identity or "unknown",
            "MCU_APPLICATION_CLASS": self.application_class or "unknown",
            "MCU_HW_ID": self.hw_id or "unknown",
            "MCU_HW_ID_STATUS": self.hw_id_status or "not_checked",
            "MCU_LIFECYCLE_DETAIL": self.detail,
        }


def _check_hardware_identity(creality_flash_module, transport_factory):
    """Runs the bootloader-level hardware-ID check via creality_flash.py.
    Always calls app_start() to return the MCU to its application, exactly
    like the original guard's contract. Returns (status, hw_id, detail)
    where status is one of "MATCH", "MISMATCH", "UNREACHABLE"."""
    try:
        transport = transport_factory()
    except Exception as e:
        return "UNREACHABLE", None, f"serial_open_failed: {e}"
    # The port is released on every path: S55klipper opens it exclusively
    # right after this guard.
    try:
        return _hardware_identity_on(creality_flash_module, transport)
    finally:
        try:
            transport.close()
        except Exception:
            pass


def _hardware_identity_on(creality_flash_module, transport):
    version_string = None
    bootloader_entered = False
    try:
        version_string = creality_flash_module.identify(transport)
        bootloader_entered = True
    except creality_flash_module.FlashError as e:
        if "could not enter" in str(e).lower():
            return "UNREACHABLE", None, f"bootloader_entry_failed: {e}"
        bootloader_entered = True
        detail = f"version_query_failed: {e}"
        version_string = None
    except Exception as e:
        return "UNREACHABLE", None, f"unexpected_error: {e}"

    if bootloader_entered:
        # Two independent best-effort steps: a failure in the baud switch
        # must not prevent attempting app_start (and vice versa) - leaving
        # the MCU stuck in the bootloader is the one outcome this function
        # must never cause. Worst case if both fail: the bootloader's own
        # ~15s window times out and it returns to the application on its
        # own, exactly as the original guard's comment already assumed -
        # but we still want to actually try app_start rather than skip it
        # because an unrelated baud-switch error happened first.
        try:
            transport.set_baudrate(MCU_BOOTLOADER_BAUD)
        except Exception:
            pass
        try:
            creality_flash_module.app_start(transport)
        except Exception:
            pass

    if version_string is None:
        return "UNREACHABLE", None, "version_query_failed_after_bootloader_entry"

    if creality_flash_module.check_identity(version_string, (MCU_EXPECTED_HW_ID,)):
        return "MATCH", version_string, "identity_verified"
    return "MISMATCH", version_string, f"expected={MCU_EXPECTED_HW_ID}"


def decide(creality_flash_module=None, transport_factory=None,
           application_identify_fn=None, port=None, baud=None):
    """Run the full decision. `creality_flash_module`/`transport_factory`
    and `application_identify_fn` are injectable for testing with mocks -
    production callers can leave them as None to use the real modules."""
    port = port or MCU_SERIAL_PORT
    baud = baud or MCU_APP_BAUD
    identify_fn = application_identify_fn or app_identify.get_application_identity

    # Step 1: application identity, non-invasive, tried first.
    try:
        version, _build_versions = identify_fn(port, baud)
        app_class = known.classify_application_identity(version)
    except Exception as e:
        version, app_class = None, None
        app_identify_error = str(e)
    else:
        app_identify_error = None

    if app_class == known.NATIVE_CANDIDATE_001:
        # Healthy, expected state. Do NOT also enter the bootloader - no
        # reason to disturb a connection that's already known-good.
        return LifecycleDecision(
            SUPPORTED_HW_NATIVE_APP, ALLOW_KLIPPER_START,
            application_identity=version, application_class=app_class,
            hw_id_status="not_checked_not_needed",
            detail="native_candidate_001_confirmed_via_application_identity")

    if app_class == known.KNOWN_STOCK:
        # Stage 1 (software gate) only: an EXACT known-stock application
        # identity authorizes calling restore() directly - non-invasive, no
        # bootloader entry here. Stage 2 (candidate hash validation, then
        # bootloader entry via mcu_restart.py's Klipper-own-command restart,
        # then live hardware-ID verification) happens entirely inside
        # mcu_restore.restore() - see that module's docstring. This is why
        # hw_id_status is "not_checked_pending_restore", not "not_checked" -
        # it WILL be checked, just later, and only as part of an actual
        # restore attempt rather than as a separate disruptive probe here.
        return LifecycleDecision(
            SUPPORTED_HW_KNOWN_STOCK_APP, RESTORE_AUTHORIZED,
            application_identity=version, application_class=app_class,
            hw_id_status="not_checked_pending_restore",
            detail="known_stock_application_identity_confirmed_exact_match")

    # Every remaining path (application identify failed outright, or
    # returned something not recognized as native/known-stock) needs the
    # OLD bootloader-level hardware check for diagnostic context only -
    # neither path below ever authorizes a flash, so the (here, harmless)
    # magic-sequence bootloader-entry method is still fine to use as a
    # best-effort diagnostic probe.
    if creality_flash_module is None or transport_factory is None:
        import sys as _sys
        _sys.path.insert(0, os.environ.get("CREALITY_FLASH_PATH", "/opt/nebulaos/tools"))
        import creality_flash as creality_flash_module  # noqa: F811

        def transport_factory():
            return creality_flash_module.SerialTransport(port, baud=baud, timeout=2.0)

    hw_status, hw_id, hw_detail = _check_hardware_identity(
        creality_flash_module, transport_factory)

    if hw_status == "UNREACHABLE":
        if app_class is None:
            # Neither application nor bootloader responded at all.
            return LifecycleDecision(
                MCU_UNREACHABLE, ALLOW_KLIPPER_START_WARN,
                hw_id_status=hw_status,
                detail=f"application_identify_failed ({app_identify_error}); "
                       f"hardware_check_also_unreachable ({hw_detail})")
        # Application spoke but wasn't a class we recognize, and the
        # bootloader is now unreachable too (e.g. serial contention) -
        # still treat as unreachable-hardware, not a hardware mismatch.
        return LifecycleDecision(
            MCU_UNREACHABLE, ALLOW_KLIPPER_START_WARN,
            application_identity=version, application_class=app_class,
            hw_id_status=hw_status, detail=hw_detail)

    if hw_status == "MISMATCH":
        # Hardware itself doesn't match, regardless of what the application
        # looked like - this is a genuine hardware-swap scenario. Never
        # flash, never let Klipper proceed against unverified hardware.
        return LifecycleDecision(
            UNSUPPORTED_HW, BLOCK_KLIPPER_START,
            application_identity=version, application_class=app_class,
            hw_id=hw_id, hw_id_status=hw_status, detail=hw_detail)

    # hw_status == "MATCH" from here on: hardware is confirmed supported,
    # but app_class is UNKNOWN_APPLICATION (or None, if identify itself
    # failed) - never auto-flash an unrecognized application.
    return LifecycleDecision(
        SUPPORTED_HW_UNKNOWN_APP, ALLOW_KLIPPER_START_WARN,
        application_identity=version, application_class=app_class,
        hw_id=hw_id, hw_id_status=hw_status,
        detail=(f"application_identify_failed: {app_identify_error}"
                if app_class is None else
                "application_identity_not_recognized_no_auto_restore"))
