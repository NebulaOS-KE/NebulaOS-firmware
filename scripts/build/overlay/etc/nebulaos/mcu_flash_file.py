#!/usr/bin/env python3
"""Flash an arbitrary firmware file to the MCU via creality_flash.

Called by `nebulaos-mcu flash <file>`. Unlike mcu_restore.py (which validates
candidate-001 hash and verifies post-flash identity), this module accepts any
firmware file built for this mainboard and does not check post-flash identity — the user is flashing
firmware they chose, not the pinned native candidate.

Safety contract:
  - The file must be firmware for this mainboard BEFORE the MCU is touched
    at all (mcu_image.prepare(): a packed Creality "mcu0" image, or a raw
    NebulaOS-klipper-mcu build, which is packed here; size, CRC, vector
    table). Anything else exits 1 with nothing restarted (run 4, 2026-10-11).
  - Verifies hardware identity BEFORE any erase/write (same allow-list as
    mcu_restore.py, via creality_flash.check_identity()).
  - Uses creality_flash backend only — never touches bootloader, only
    writes application firmware.
  - Bounded: exactly one flash attempt, no retry loop.
  - Always calls app_start() after a successful flash.

Usage: python3 mcu_flash_file.py <firmware.bin>
Exit 0 on success, 1 on failure (with diagnostic output).
"""

import os
import sys
import time

MCU_SERIAL_PORT = os.environ.get("MCU_SERIAL_PORT", "/dev/ttyS1")
MCU_APP_BAUD = int(os.environ.get("MCU_APP_BAUD", "230400"))
MCU_BOOTLOADER_BAUD = int(os.environ.get("MCU_BOOTLOADER_BAUD", "115200"))
CREALITY_FLASH_PATH = os.environ.get("CREALITY_FLASH_PATH", "/opt/nebulaos/tools")

POST_RESTART_SETTLE_S = 0.5
BOOTLOADER_HANDSHAKE_ATTEMPTS = 10
BOOTLOADER_HANDSHAKE_RETRY_DELAY_S = 0.5


def main():
    if len(sys.argv) < 2:
        print("Usage: mcu_flash_file.py <firmware.bin>", file=sys.stderr)
        return 1

    firmware_path = sys.argv[1]
    if not os.path.isfile(firmware_path):
        print(f"Firmware file not found: {firmware_path}", file=sys.stderr)
        return 1

    with open(firmware_path, "rb") as f:
        image = f.read()

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    sys.path.insert(0, CREALITY_FLASH_PATH)

    try:
        import mcu_image
    except ImportError as e:
        print(f"Could not import mcu_image: {e}", file=sys.stderr)
        return 1
    try:
        kind, image = mcu_image.prepare(image)
    except mcu_image.ImageError as e:
        print(f"REFUSED: {firmware_path}: {e.reason}", file=sys.stderr)
        return 1
    print(f"Image: {kind}, {len(image)} bytes, sha256 {mcu_image.sha256(image)}")

    try:
        import creality_flash
    except ImportError:
        print(f"Could not import creality_flash from {CREALITY_FLASH_PATH}",
              file=sys.stderr)
        return 1

    try:
        import mcu_restart
    except ImportError:
        print("Could not import mcu_restart", file=sys.stderr)
        return 1

    def make_transport():
        return creality_flash.SerialTransport(
            MCU_SERIAL_PORT, baud=MCU_BOOTLOADER_BAUD, timeout=2.0)

    transport = None
    entry_detail = ""

    try:
        restart_detail = mcu_restart.request_generic_restart(
            MCU_SERIAL_PORT, MCU_APP_BAUD)
        time.sleep(POST_RESTART_SETTLE_S)
        for _ in range(BOOTLOADER_HANDSHAKE_ATTEMPTS):
            try:
                transport = make_transport()
                if creality_flash.handshake(transport):
                    entry_detail = f"restart_command={restart_detail}"
                    break
            except Exception:
                pass
            time.sleep(BOOTLOADER_HANDSHAKE_RETRY_DELAY_S)
    except Exception as e:
        entry_detail = f"restart_command_failed: {e}"

    if transport is None:
        try:
            transport = make_transport()
            version_string = creality_flash.identify(transport)
            entry_detail = f"magic_sequence (hw={version_string})"
        except Exception as e:
            print(f"Could not enter bootloader: {e}", file=sys.stderr)
            return 1

    try:
        version_string = creality_flash.get_version(transport)
    except Exception as e:
        print(f"Could not read hardware identity: {e}", file=sys.stderr)
        return 1

    if not creality_flash.check_identity(version_string):
        print(f"Hardware identity mismatch: {version_string!r}", file=sys.stderr)
        print(f"Allowed: {creality_flash.DEFAULT_ALLOWED_HW_IDS!r}", file=sys.stderr)
        return 1

    print(f"Hardware identity verified: {version_string}")
    print(f"Bootloader entry: {entry_detail}")
    print(f"Flashing {len(image)} bytes...")

    try:
        sector_size = creality_flash.get_sector_size(transport)
        if not creality_flash.flash_image(transport, image, sector_size):
            print("Flash transfer did not report completion", file=sys.stderr)
            return 1
        if not creality_flash.app_start(transport):
            print("Application failed to start after flash", file=sys.stderr)
            return 1
    except Exception as e:
        print(f"Flash error: {e}", file=sys.stderr)
        return 1

    print("Flash complete, application started.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
