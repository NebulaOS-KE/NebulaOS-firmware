#!/usr/bin/env python3
"""MCU lifecycle check + restore entry point for S50nebulaos-mcu-guard.

Corrected in Phase 1.8B (offline pre-build review): the original version of
this file only ever performed a bootloader-level hardware-ID check
(creality_flash.identify()/check_identity()) and reported PASS whenever the
bootloader answered with the expected hardware ID - regardless of which
application firmware was actually running. That hardware ID has been
observed identical whether candidate-001 or stock Creality firmware is
installed, so it could never actually prove candidate-001 was running (see
mcu_lifecycle.py's module docstring for the exact evidence).

This entry point now delegates to mcu_lifecycle.decide() (which correctly
separates application identity from hardware identity) and, only when that
decision explicitly authorizes it, to mcu_restore.restore(). It never
performs any bootloader or flash interaction directly - all of that lives
in mcu_lifecycle.py/mcu_restore.py so it can be exercised by tests with
injected mocks instead of real hardware.

SAFETY CONTRACT (unchanged from the original file, still enforced):
  - No erase/write occurs anywhere except inside mcu_restore.restore(),
    and only when mcu_lifecycle.decide() returned RESTORE_AUTHORIZED.
  - Every bootloader interaction always calls app_start() before this
    process exits (enforced inside mcu_lifecycle._check_hardware_identity
    and mcu_restore.restore()'s use of creality_flash.flash(), which itself
    calls app_start() after a successful write).
  - Never writes to /dev/mmcblk0p1 or any block device - this file and its
    two collaborators only ever touch the MCU serial port and (in
    mcu_restore.py only) the MCU's own flash via the existing, separately
    hardware-identity-gated creality_flash.flash() function.
"""

import os
import sys

import mcu_known_identities
import mcu_lifecycle
import mcu_restore

MCU_MANAGED_FLAG = os.environ.get(
    "MCU_MANAGED_FLAG", "/usr/data/nebulaos/mcu/managed")


def _is_managed():
    try:
        with open(MCU_MANAGED_FLAG, "r") as f:
            return f.read().strip() != "false"
    except (IOError, OSError):
        return True


def emit(fields):
    for key, value in fields.items():
        print(f"{key}={value}")


def main():
    decision = mcu_lifecycle.decide()
    fields = decision.as_dict()

    if decision.action == mcu_lifecycle.RESTORE_AUTHORIZED:
        # Known stock ALWAYS restores — the managed flag only prevents
        # the boot guard from interfering with unknown (user-flashed)
        # applications. Stock Creality recovery to native is never skipped.
        restore_result = mcu_restore.restore()
        fields.update(restore_result.as_dict())
        if restore_result.state == mcu_restore.RESTORED_AND_VERIFIED:
            # Run 23: report what the board runs now, not the stock firmware
            # it ran before the restore (restore() verified this identity).
            fields["MCU_APPLICATION_IDENTITY"] = mcu_known_identities.NATIVE_CANDIDATE_001_VERSION
            fields["MCU_APPLICATION_CLASS"] = mcu_known_identities.NATIVE_CANDIDATE_001
            fields["MCU_HW_ID_STATUS"] = "MATCH"
            emit(fields)
            print("MCU_GUARD_RESULT=PASS")
            sys.exit(0)
        else:
            # CANDIDATE_ARTIFACT_MISSING / CANDIDATE_HASH_BAD / FLASH_FAILED:
            # bounded failure, no stock fallback, preserve diagnostics, do
            # not let Klipper start against a partially-restored/unknown MCU.
            emit(fields)
            print("MCU_GUARD_RESULT=FAIL")
            sys.exit(1)

    emit(fields)

    if decision.action == mcu_lifecycle.ALLOW_KLIPPER_START:
        print("MCU_GUARD_RESULT=PASS")
        sys.exit(0)
    elif decision.action == mcu_lifecycle.ALLOW_KLIPPER_START_WARN:
        print("MCU_GUARD_RESULT=WARN")
        sys.exit(0)
    else:  # BLOCK_KLIPPER_START
        print("MCU_GUARD_RESULT=FAIL")
        sys.exit(1)


if __name__ == "__main__":
    main()
