#!/usr/bin/env python3
"""NebulaOS Creality serial-bootloader flash tool (GD32F303 / KE target).

Protocol ported from the reference implementation at
vendor/pellcorp-creality/k1/mcu_util.py (CryoZ, v0.2) - see the Phase 1.7
mission doc for the full protocol table (magic entry -> handshake ->
version -> sector size -> flash chunks -> app start). The 8-bit
sum-and-complement checksum used on the wire here is a SEPARATE mechanism
from the 16-bit CRC-16/XMODEM in the image's own metadata header (see
creality_packer.py/creality_validator.py) - one protects the serial
transfer, the other the flashed image at rest.

SAFETY: the default CLI has no flashing side effect. "flash" is a
distinct, explicit subcommand, and even that subcommand refuses to
proceed unless:
  1. the target image independently passes creality_validator's format
     and target checks, and
  2. the bootloader's reported hardware identity exactly matches the
     configured allow-list (default: exactly "mcu0_001_G32" - see the
     Phase 1.7 mission's F005 identity policy).
There is no --force flag that bypasses either check.

This module is written against an injectable Transport so its protocol
logic can be exercised by tests/test_creality_flash.py without any serial
hardware. Per the Phase 1.7 mission (section 48), this tool must NOT be
executed against real hardware during this mission - mock/unit-test only.
"""

import argparse
import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import creality_validator as validator  # noqa: E402

MAGIC = (b'\x20\x1c\x20\x52\x65\x71\x75\x65\x73\x74\x20\x53\x65\x72\x69\x61\x6c'
         b'\x20\x42\x6f\x6f\x74\x6c\x6f\x61\x64\x65\x72\x21\x21\x20\x7e')

# The Phase 1.7 mission's first-hardware identity contract: the KE's
# golden-printer bootloader must report exactly this hardware id before
# any erase/write is authorized. Additional legitimate revisions must be
# added explicitly here, never matched with a wildcard.
DEFAULT_ALLOWED_HW_IDS = ("mcu0_001_G32",)


class FlashError(Exception):
    pass


def crc8_sum_complement(data: bytes) -> int:
    x = 0
    for b in data:
        x = (x + b) & 0xFF
    return x ^ 0xFF


class Transport:
    """Minimal serial-like interface so tests can inject a fake."""
    def write(self, data: bytes) -> int:
        raise NotImplementedError
    def read(self, n: int) -> bytes:
        raise NotImplementedError
    def set_baudrate(self, baud: int):
        raise NotImplementedError
    def close(self):
        pass


class SerialTransport(Transport):
    """Real transport - only ever constructed by the CLI, never by tests."""
    def __init__(self, port: str, baud: int, timeout: float = 2.0):
        import serial  # imported lazily: not a dependency of the test suite
        # dtr=False, rts=False (Phase 2 overnight convergence mission,
        # 2026-09-09): pyserial's Serial() constructor form opens the
        # device immediately, and on many UART/USB-serial combinations the
        # underlying open() asserts DTR/RTS high as a termios side effect
        # unless told not to - a well-known cause of unwanted resets on
        # boards that wire a reset/bootloader-entry pin to one of those
        # lines (this project's own Klipper serialhdl.py uses exactly that
        # DTR-toggle technique deliberately elsewhere, over this same
        # class of port).
        #
        # pyserial 3.5 has no dtr=/rts= constructor arguments: Serial(...,
        # dtr=False, rts=False) raises "ValueError: unexpected keyword
        # arguments", so the MCU guard's hardware-identity fallback could
        # never open the port (seen on ke-dev, 2026-10-03). The supported
        # sequence is an unopened Serial with the line states set as
        # attributes; open() then drives DTR/RTS low right after the
        # OS-level open. write_timeout bounds a stuck write the same way
        # timeout bounds a read.
        s = serial.Serial()
        s.port = port
        s.baudrate = baud
        s.timeout = timeout
        s.write_timeout = timeout
        s.dtr = False
        s.rts = False
        s.open()
        self._serial = s

    def write(self, data: bytes) -> int:
        return self._serial.write(data)

    def read(self, n: int) -> bytes:
        return self._serial.read(n)

    def set_baudrate(self, baud: int):
        self._serial.baudrate = baud

    def close(self):
        self._serial.close()


# ---------------------------------------------------------------------
# Protocol primitives (transport-agnostic, unit-testable)
# ---------------------------------------------------------------------

def send_magic(t: Transport):
    if t.write(MAGIC) != len(MAGIC):
        raise FlashError("failed to write bootloader-request magic")


def handshake(t: Transport) -> bool:
    if t.write(bytes([0x75])) == 0:
        raise FlashError("failed to write handshake byte")
    r = t.read(1)
    return len(r) == 1 and r[0] == 0x75


def get_version(t: Transport) -> str:
    if t.write(bytes([0x00, 0xFF])) == 0:
        raise FlashError("failed to write version request")
    r = t.read(26)
    if len(r) != 26:
        raise FlashError(f"version response short read: {len(r)} bytes")
    if r[25] != crc8_sum_complement(r[:-1]):
        raise FlashError("version response failed checksum")
    return r[:-1].decode("latin1")


def get_sector_size(t: Transport) -> int:
    if t.write(bytes([0x03, 0xFC])) == 0:
        raise FlashError("failed to write sector-size request")
    r = t.read(2)
    if len(r) != 2 or r[-1] != crc8_sum_complement(r[:-1]):
        raise FlashError("sector-size response failed checksum")
    return r[0]


def app_start(t: Transport) -> bool:
    if t.write(bytes([0x02, 0xFD])) == 0:
        raise FlashError("failed to write app-start request")
    r = t.read(2)
    return len(r) == 2 and r[0] == 0x75 and r[-1] == crc8_sum_complement(r[:-1])


def flash_image(t: Transport, image: bytes, sector_size: int) -> bool:
    """Transfer `image` in sector_size*1024-byte chunks. Returns True on a
    final 0x20 ("flash completed") status."""
    if t.write(bytes([0x01, 0xFE])) == 0:
        raise FlashError("failed to write update-request")
    r = t.read(2)
    if len(r) != 2 or r[0] != 0x75 or r[-1] != crc8_sum_complement(r[:-1]):
        raise FlashError("update-request not acknowledged")

    size_bytes = len(image).to_bytes(4, "little")
    payload = size_bytes + bytes([crc8_sum_complement(size_bytes)])
    if t.write(payload) != len(payload):
        raise FlashError("failed to write firmware size")
    r = t.read(2)
    if len(r) != 2 or r[0] != 0x75 or r[-1] != crc8_sum_complement(r[:-1]):
        raise FlashError("firmware size not acknowledged")

    chunk_size = sector_size * 1024
    offset = 0
    while offset < len(image):
        chunk = image[offset:offset + chunk_size]
        payload = chunk + bytes([crc8_sum_complement(chunk)])
        if t.write(payload) != len(payload):
            raise FlashError(f"failed to write chunk at offset {offset}")
        r = t.read(2)
        if len(r) != 2 or r[-1] != crc8_sum_complement(r[:-1]):
            raise FlashError(f"chunk at offset {offset} failed checksum")
        status = r[0]
        offset += len(chunk)
        if status == 0x75:
            continue  # chunk ok, more to send
        if status == 0x20:
            return offset >= len(image)  # flash completed
        if status == 0x21:
            raise FlashError("flash write error reported by bootloader")
        if status == 0x1F:
            raise FlashError(f"bad CRC reported by bootloader at offset {offset}")
        raise FlashError(f"unexpected chunk status 0x{status:02X}")
    return True


# ---------------------------------------------------------------------
# High-level, identity-gated operations
# ---------------------------------------------------------------------

def enter_bootloader(t: Transport, app_baud: int = 230400, attempts: int = 5) -> bool:
    for _ in range(attempts):
        t.set_baudrate(app_baud)
        send_magic(t)
        time.sleep(1)
        t.set_baudrate(115200)
        if handshake(t):
            return True
    return False


def identify(t: Transport) -> str:
    """READ-ONLY: enter bootloader and query hardware identity. No erase,
    no write. This is the entire Phase 1.8 first-hardware step."""
    if not enter_bootloader(t):
        raise FlashError("could not enter Creality serial bootloader")
    return get_version(t)


def check_identity(version_string: str, allowed: tuple = DEFAULT_ALLOWED_HW_IDS) -> bool:
    hw_part = version_string.split("-")[0] if "-" in version_string else version_string
    return hw_part in allowed


def validate_image_file(image_path: str, elf_path: str = None, config_path: str = None) -> list:
    with open(image_path, "rb") as f:
        data = f.read()
    fails = validator.validate_format(data, expect_type="mcu0")
    if elf_path and config_path:
        fails += validator.validate_target(image_path, elf_path, config_path)
    return fails


def flash(t: Transport, image_path: str, elf_path: str = None, config_path: str = None,
          allowed_hw_ids: tuple = DEFAULT_ALLOWED_HW_IDS) -> None:
    """The only function in this module that writes to the MCU. Refuses to
    proceed unless the image independently validates AND the live
    hardware identity matches the allow-list exactly."""
    fails = validate_image_file(image_path, elf_path, config_path)
    if fails:
        raise FlashError("image failed offline validation, refusing to flash:\n  " +
                          "\n  ".join(fails))

    version_string = identify(t)
    if not check_identity(version_string, allowed_hw_ids):
        raise FlashError(
            f"hardware identity {version_string!r} not in allow-list "
            f"{allowed_hw_ids} - refusing to erase or write")

    sector_size = get_sector_size(t)
    with open(image_path, "rb") as f:
        image = f.read()
    if not flash_image(t, image, sector_size):
        raise FlashError("flash transfer did not report completion")
    if not app_start(t):
        raise FlashError("application failed to start after flash")


# ---------------------------------------------------------------------
# CLI - safe by default (see module docstring)
# ---------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_id = sub.add_parser("identify", help="READ-ONLY: query hardware identity")
    p_id.add_argument("port")

    p_val = sub.add_parser("validate", help="offline-only: validate an image file")
    p_val.add_argument("image")
    p_val.add_argument("--elf")
    p_val.add_argument("--config")

    p_insp = sub.add_parser("inspect", help="offline-only: print image header fields")
    p_insp.add_argument("image")

    p_fl = sub.add_parser("flash", help="validate + identity-check + flash + app-start")
    p_fl.add_argument("port")
    p_fl.add_argument("image")
    p_fl.add_argument("--elf")
    p_fl.add_argument("--config")
    p_fl.add_argument("--allow-hw-id", action="append", dest="allowed",
                       help="additional allowed hardware id (repeatable); "
                            f"default allow-list is {DEFAULT_ALLOWED_HW_IDS}")

    args = ap.parse_args()

    if args.cmd == "validate":
        fails = validate_image_file(args.image, args.elf, args.config)
        if fails:
            print("VALIDATION FAILED:")
            for f in fails:
                print(f"  - {f}")
            sys.exit(1)
        print("VALIDATION PASSED")
        return

    if args.cmd == "inspect":
        with open(args.image, "rb") as f:
            data = f.read()
        h = data[validator.METADATA_OFFSET:validator.METADATA_OFFSET + validator.METADATA_SIZE]
        crc, length = struct.unpack_from("<HH", h, 0x0C)
        print(f"type={h[0:4]!r} version={h[5:8]!r} reserved={h[9:12]!r} "
              f"crc=0x{crc:04X} length={length} file_size={len(data)}")
        return

    if args.cmd == "identify":
        t = SerialTransport(args.port, baud=115200)
        print(identify(t))
        return

    if args.cmd == "flash":
        allowed = DEFAULT_ALLOWED_HW_IDS + tuple(args.allowed or ())
        t = SerialTransport(args.port, baud=230400)
        flash(t, args.image, args.elf, args.config, allowed)
        print("Flash and app-start completed successfully")
        return


if __name__ == "__main__":
    main()
